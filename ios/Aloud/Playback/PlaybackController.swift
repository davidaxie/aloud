import AVFoundation
import Combine
import Foundation
import os

enum PlayerStatus: String, Sendable {
    case idle, buffering, playing, paused, ended, error
}

/// A queued sentence's end, for the sleep timer's landing (R19).
struct SentenceEnd: Equatable, Sendable {
    let sentence: Int
    let secondsFromNow: TimeInterval
}

/// What the controller says about an Undo jump offer (R15, R1-39).
enum UndoJumpCopy {
    /// Announced, queued behind the scrub's new value, when an offer opens.
    static let available = "Undo jump available"
}

/// An output monitor that can claim its output off the main actor: the
/// iPhone's audio session (R4-33), whose activation can take long enough
/// to freeze the busy ring. A cold Play claims through it while its first
/// clip is made. The Mac's monitor has no session and claims in place.
@MainActor
protocol AudioOutputClaiming: AnyObject {
    /// Activates the output off the main actor, ordered behind any release
    /// already asked for; throws `AudioOutputHeldElsewhere` when a call or
    /// a higher-priority app holds it.
    func claim() async throws
}

/// The app's heart. Drives an AVAudioEngine → player → time-pitch graph with
/// gapless look-ahead scheduling. Sentences are the atom of playback: clips are
/// synthesized at 1×, speed applied by the time-pitch unit, and every async
/// continuation is guarded by a monotonic play token.
@MainActor
final class PlaybackController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var status: PlayerStatus = .idle {
        didSet {
            settleFirstAudio()   // M19's first-audio signpost
            wordTimingStatusChanged(status)   // M3 karaoke frame ticker
            let wasActive = oldValue == .playing || oldValue == .buffering
            if !wasActive, isActive {
                // Playing or synthesizing ahead: a hidden window's look-ahead
                // isn't throttled (S13; nothing to hold on an iPhone).
                activity = PlatformActivity.begin(reason: "Reading aloud")
                didEnterActivePlayback()
            }
            if wasActive, !isActive {
                PlatformActivity.end(activity)
                activity = nil
                // Every transition out of active playback (pause, stop, error,
                // interruption, route-change pause, end of book) anchors the
                // resume-rewind clock and ends the live session.
                stampResumeAnchor()
                stopStore.clearLive()
                // Only a pause's own ramp plays on past here. Any other (a
                // sleep fade) would ride into the next hard start, such as
                // an audition, and fade it to silence.
                if isRampingVolume, !isRampingToPause { cancelVolumeRamp() }
            }
            // M19: out of playback the engine stops after the platform's
            // idle delay, and any way back in (Play, a seek that plays, a
            // voice sample, buffering) calls that off. Re-armed at every
            // change, so a seek while paused starts the wait again.
            if isActive { cancelIdleEngineStop() } else { armIdleEngineStop() }
            placeStatusChanged(from: oldValue)   // "Where you stopped"
        }
    }
    @Published private(set) var currentSentence: Int = -1 {
        didSet {
            currentWord = -1   // a stale word highlight never bleeds into a new sentence
            // Moving off the sentence a book finished at is the listener's
            // choice: from there on progress is plain position again.
            if let cue = finishedCue, cue.sentence != currentSentence { finishedCue = nil }
            reportProgress()
            if isActive { markLiveSession() }
        }
    }
    /// Active word (token index into `tokenizeSentence` of the current
    /// sentence), driven by PlaybackController+WordTiming.swift; -1 = none.
    @Published private(set) var currentWord: Int = -1
    @Published var rate: Double = 1.0 {
        didSet {
            let clamped = Self.clampedRate(rate)
            if clamped != rate { rate = clamped; return }
            applyTimePitchRate()
        }
    }

    /// How much shorter than 1x the clips playing now are
    /// (`SynthesizedAudio.nativeSpeed`): Kokoro spoke that part of the
    /// listener's speed itself, so the time-pitch unit plays only the rest.
    private var playingCompression: Double = 1.0
    /// The compression of the last clip handed to the node; nil before a
    /// schedule's first. A clip of another one is switched to as it starts
    /// (`scheduleBoundaryMarker`).
    private var lastScheduledCompression: Double?

    /// What the time-pitch unit is playing at now, whether it is bypassed,
    /// and how much faster than 1x the clips now playing were made (tests).
    var timePitchRate: Float { timePitch.rate }
    var isTimePitchBypassed: Bool { timePitch.bypass }
    var playingSpeedUp: Double { playingCompression }

    /// The time-pitch unit's share of the listener's speed: nothing, and
    /// bypassed, once each clip is stretched to the speed in the time domain
    /// (`SpeechStretcher`); a slider move plays the small difference until
    /// the clips at the new speed arrive. A share within 1% plays at exactly
    /// 1x, which the unit passes through untouched. The bypass switches only
    /// at a clip boundary (`atBoundary`: the marker the render reaches
    /// ahead of each clip) or with the node still: switched mid-render, the unit
    /// drops or restarts its buffered audio mid-word. So a slider tick while
    /// audio plays changes only the rate, and a bypassed unit takes the new
    /// share up at the next boundary.
    private func applyTimePitchRate(atBoundary: Bool = false) {
        let residual = rate / max(playingCompression, 0.1)
        let nothingLeft = abs(residual - 1) < 0.01
        timePitch.rate = nothingLeft ? 1 : Float(residual)
        guard atBoundary || !player.isPlaying, timePitch.bypass != nothingLeft else { return }
        timePitch.bypass = nothingLeft
    }

    /// `clip` sped up to the listener's speed in the time domain, off the
    /// main thread: no phase-vocoder ring. What it achieved rides on the clip.
    nonisolated private static func stretchedToSpeed(_ clip: SynthesizedAudio, rate: Double) async -> SynthesizedAudio {
        let speed = rate / max(clip.nativeSpeed, 0.1)
        guard abs(speed - 1) > 0.01 else { return clip }
        return await Task.detached(priority: .userInitiated) {
            SpeechStretcher.stretch(clip, speed: speed)
        }.value
    }

    /// The pace Kokoro is asked for at the current speed (`NativeSpeed`);
    /// the System voice keeps its own.
    private func nativePace(for voice: TtsVoice) -> Double {
        NativeSpeed.tier(for: rate, engine: voice.engine)
    }

    /// The speed range the time-pitch unit is driven at (`SpeedScale.range`).
    /// Static so a stored speed read before it reaches `rate` (launch restore,
    /// the R7 migration) is clamped by exactly the same rule.
    nonisolated static func clampedRate(_ rate: Double) -> Double {
        min(max(rate, SpeedScale.range.lowerBound), SpeedScale.range.upperBound)
    }
    /// Any assignment but `setVoiceQuietly` restarts the current sentence in
    /// the new voice and cancels a pending R5 handoff: a deliberate pick, a
    /// model removal or a fallback always wins over the install switch.
    @Published var voice: TtsVoice {
        didSet {
            guard oldValue != voice, !isSettingVoiceQuietly else { return }
            handoff = nil
            applyVoiceOrSkipChange()
        }
    }
    /// Deliberate speed picks, app-wide (R7): preset chips and slider release,
    /// via `selectRate`. Programmatic changes — launch restore, every
    /// intermediate step of a live slider drag — set `rate` directly and never
    /// emit here (AppModel persists from this subject, not `$rate`).
    let rateSelections = PassthroughSubject<Double, Never>()
    /// Deliberate voice picks, app-wide (R7): picker taps that change the
    /// voice, via `selectVoice`. Programmatic changes — the pre-install system
    /// stand-in, `fallBackToSystemVoice()`, the R5 install switch — set
    /// `voice` directly and never emit here, so a temporary voice can't
    /// overwrite the stored preference (AppModel persists from this subject).
    let voiceSelections = PassthroughSubject<TtsVoice, Never>()
    @Published var skipBrackets: Bool = true {
        didSet {
            guard oldValue != skipBrackets else { return }
            applyVoiceOrSkipChange()
        }
    }
    @Published private(set) var skippedSentences: Set<Int> = []
    @Published private(set) var document: LibraryDocument?
    /// True while the neural engine is loading its model ("Preparing voice…").
    @Published private(set) var isPreparingVoice = false

    /// Every write goes through here: a publish that changes nothing still
    /// re-renders every view watching playback.
    private func setPreparingVoice(_ preparing: Bool) {
        if isPreparingVoice != preparing { isPreparingVoice = preparing }
    }
    /// Bumped when the USER starts playback from a non-active state (play
    /// button, lock-screen play, restart after the end) — never on internal
    /// status flips, buffering blips, or interruption auto-resume. The reader
    /// resumes following the voice on it (R16).
    @Published private(set) var userPlayAction = 0
    /// A change the listener didn't make, for the chapter line: set for
    /// `PlaybackNotice.displaySeconds`, announced once (`postNotice`).
    @Published private(set) var notice: PlaybackNotice?
    /// R11: the stop the listener didn't ask for, app-wide in one slot and
    /// persisted (`stopStore`), until the next transition into playback.
    @Published private(set) var stopped: PlaybackStop?
    /// R15: non-nil while the reader offers "Undo jump".
    @Published private(set) var undoableJump: UndoableJump?
    /// Bumped by every jump and undo: the reader's "deliberate move, follow
    /// it" signal (R15/R16).
    @Published private(set) var jumpSerial = 0
    /// Bumped when the book plays to its own end under the listener (R24),
    /// however that playback began: the sleep timer's cue that nothing is
    /// left to sleep through. Never by Undo back to the end, a voice sample
    /// over it or a reopen there, which reach `.ended` without playing to it.
    @Published private(set) var bookEndSerial = 0
    /// Bumped when a sleep-timer stop is recorded (R19): the timer's cue that
    /// its stop landed. Never by any other way into `.paused`, a voice sample
    /// handed back over that stop included.
    @Published private(set) var sleepStopSerial = 0

    /// Speaks to VoiceOver. Tests replace it.
    var announce: (String) -> Void = { _ in }

    /// Plays a transport haptic: R24's `.finished` at a book's own end, the
    /// one haptic the controller emits. Tests replace it.
    var emitHaptic: @MainActor (TransportHaptic) -> Void = { _ in }

    /// Whether VoiceOver can hear an announcement now; a stop recorded in the
    /// background waits for `sceneDidBecomeActive`. Tests replace it.
    var isAppActive: () -> Bool = { PlatformApp.isActive }

    /// Whether the device is under strain now: Low Power Mode, or `.serious`
    /// heat or hotter (`isHot || isLowPower`, AppModel's `strain`). The
    /// speculative work stops while it holds: skip warm-ups and the cold
    /// natural-voice load on return. AppModel answers through ThermalGuard;
    /// tests set it.
    var isUnderStrain: @MainActor () -> Bool = { false }
    /// `.serious` heat or hotter: the look-ahead keeps the platform's
    /// strained cap (`PlatformPlaybackTuning.lookAheadUnderStrain`), so the
    /// cooling handoff lands within a few sentences (R4-34). AppModel
    /// answers through ThermalGuard; tests set it.
    var isHot: @MainActor () -> Bool = { false }
    /// Low Power Mode: the look-ahead stays time-based over the platform's
    /// shorter range (`lookAheadSentencesUnderLowPower`), unless hot too.
    var isLowPower: @MainActor () -> Bool = { false }
    /// C4: whether the open reader's page follows the voice
    /// (`ReaderFollowEngine.isFollowing`), as the iPhone and Mac columns
    /// report it; true with no reader open. Scrolled away, a tap elsewhere
    /// is likelier, so the look-ahead and warm-ups that would take long to
    /// make are made in clause pieces (`backgroundPlan`), and a tap waits
    /// behind one piece of them rather than a whole sentence.
    var readerIsFollowing = true

    /// How long an "Undo jump" offer stays up. Tests shorten it.
    var undoJumpLifetime: TimeInterval = UndoableJump.displaySeconds
    /// How long the offer stays up while VoiceOver or Switch Control runs:
    /// reaching the chip takes longer than a glance. Tests shorten it.
    var assistiveUndoJumpLifetime: TimeInterval = 30
    /// Whether VoiceOver or Switch Control is running now
    /// (`PlatformAccessibility.assistiveTechRunning`; never on the Mac,
    /// whose offer keeps its 10 s). Tests replace it.
    var assistiveTechRunning: () -> Bool = { PlatformAccessibility.assistiveTechRunning }
    /// Whether a new offer is announced (`PlatformAccessibility.announcesUndoOffer`:
    /// the iPhone's R1-39; the Mac says nothing new). Tests set it.
    var announcesUndoOffer = PlatformAccessibility.announcesUndoOffer

    /// M19: how long the engine runs on once nothing plays before it stops
    /// (`PlatformTuning.idleEngineStopDelay`); nil keeps it running. Tests
    /// set it.
    var idleEngineStopDelay: TimeInterval? = PlatformTuning.idleEngineStopDelay
    /// Runs the idle stop: `fire` on the main actor after `delay` seconds,
    /// unless the returned item is cancelled first. Tests pass a fake clock.
    var scheduleIdleEngineStop: (_ delay: TimeInterval,
                                 _ fire: @escaping @MainActor @Sendable () -> Void) -> DispatchWorkItem
        = PlaybackController.afterDelayOnMain

    /// Queued, so an announcement never cuts off what VoiceOver is already
    /// saying. A muted controller (UI tests) only records it, so a test can
    /// assert what VoiceOver would have heard.
    static func postAnnouncement(_ text: String, muted: Bool) {
        #if DEBUG
        UITestAnnouncementLog.shared.record(text)
        #endif
        guard !muted else { return }
        A11yAnnounce.post(text)
    }

    /// Unit-test seam: every buffer handed to the player node, and every
    /// flush of it. Sentence -1 is the no-book sample line. Nil in production.
    enum AudioScheduleEvent: Equatable {
        case scheduled(sentence: Int, voiceID: String)
        case stopped
    }
    var onAudioScheduleEvent: ((AudioScheduleEvent) -> Void)?

    /// Unit-test seam for the audio edges (R19/R20): every level written
    /// through `setOutputVolume` (the REQUESTED level, before the mute) and
    /// every node pause and resume. Nil in production.
    enum AudioEdgeEvent: Equatable {
        case volume(Float)
        case nodePaused
        case nodeResumed
    }
    var onAudioEdge: ((AudioEdgeEvent) -> Void)?

    /// R8: "Aloud reads to you, naturally." — what a voice pick says when no
    /// book is loaded, through the same graph as every sentence.
    static let sampleLine = "Aloud reads to you, naturally."

    /// Zero when this controller was built muted (UI tests, hosted unit
    /// tests, previews, ALOUD_MUTE=1). Fixed for the controller's lifetime.
    let isOutputMuted: Bool
    /// A muted controller in `.manualRendering` has no output device: the
    /// engine renders offline, paced in real time by `MutedRenderPump`, and
    /// the mixer still sits at zero. Fixed for the controller's lifetime.
    /// Always false in Release, where a mute is the device at zero.
    let rendersOffline: Bool
    /// True in a UI-test launch without `-uitest-allow-autoplay`.
    let isAutoplaySuppressed: Bool

    /// The main mixer's volume as the hardware sees it (for tests). Before
    /// the graph is connected nothing can sound and the mixer doesn't exist
    /// yet: this reports the level connecting will write, without building it.
    var mixerOutputVolume: Float {
        guard graphFormat != nil else {
            return Self.effectiveOutputVolume(requestedOutputVolume, muted: isOutputMuted)
        }
        return audioEngine.mainMixerNode.outputVolume
    }

    /// For tests: whether the engine has built its mixer (and with it the
    /// output unit). A controller that has never played hasn't.
    var hasBuiltAudioOutput: Bool { audioEngine.attachedNodes.contains { $0 is AVAudioMixerNode } }

    /// The level last asked of the mixer, before the mute. Ramps start from it.
    private(set) var requestedOutputVolume: Float = 1

    nonisolated static func effectiveOutputVolume(_ requested: Float, muted: Bool) -> Float {
        muted ? 0 : requested
    }

    /// True while audio is playing or buffering — "playback is intended".
    /// The single definition every surface (player bar, reader, sleep timer)
    /// consults, so a future status case is classified once.
    var isActive: Bool { status == .playing || status == .buffering }

    /// R8: an audition is a voice sample spoken over a pause (or the end),
    /// never playback. Transport decisions (a jump's keep-play rule, Undo's
    /// state, a skip, Play) read the state the listener left, not the sample's.
    private var listenerStatus: PlayerStatus { audition?.restore ?? status }
    /// R24's one "at the end" state: a natural end, a reopened Finished book
    /// (`reopensAtItsEnd`) and Undo back to the end. The reader shows the
    /// colophon and Play reads Listen again. A voice sample over the end does not leave it,
    /// and nothing persists it: the record's progress says Finished.
    var isAtEnd: Bool { listenerStatus == .ended }
    /// Playing as far as the listener is concerned: active, and not a voice
    /// sample. A surface deciding whether a tap is a Play (its haptic, a
    /// "play unless playing" guard) asks this, not `isActive`.
    var isListenerPlaying: Bool { audition == nil && isActive }
    /// R8 with no book loaded: a voice sample is being made or heard
    /// (`speakSample`; status stays `.idle`). A remote Pause cuts it.
    private(set) var isSpeakingSample = false

    /// Mirrored from the word-highlight pref (AppModel). The karaoke frame
    /// ticker runs at 30 fps only while this is on, to feed the reader's
    /// word tint; off, it ticks a few times a second, so `currentWord` still
    /// tells the reader's follow where the voice is in a sentence taller
    /// than the band. Word windows are still recorded at schedule time, so
    /// flipping the pref on mid-sentence lights up immediately.
    var wordHighlightEnabled = false {
        didSet {
            guard oldValue != wordHighlightEnabled else { return }
            wordTimingStatusChanged(status)
            if !wordHighlightEnabled {
                wordTiming.lastPublished = (-1, -1)
                updateCurrentWord(-1)
            }
        }
    }

    private(set) var content: DocContent?
    /// The language the System voice reads `content` in, nil for English
    /// (`AVSpeechEngine.readingLanguage`). Found once per book.
    private(set) var systemVoiceLanguage: String?
    /// Words before each sentence of `content`, the same sums the reader's
    /// time left counts (`NavigationIndex.wordsBefore`): one entry more than
    /// there are sentences, the last the book's total. Built once per load,
    /// so each progress write is one division.
    private var wordsBefore: [Int] = []
    /// The sentences of `content` that open a chapter, where a bare numeral
    /// is said as a chapter (`synthesisText`). Found once per load.
    private var chapterOpeners: Set<Int> = []

    /// Resume-rewind anchor: where and when playback last left an active
    /// state. Production writes go through `stampResumeAnchor` /
    /// `clearResumeAnchor`, which keep the persisted copy in step; the
    /// property is internal — not private — only so unit tests can simulate
    /// elapsed rest time.
    var resumeAnchor: ResumeAnchor?

    /// Progress sink — wire to `DocumentStore.saveProgress` with a weak capture:
    /// `playback.onProgress = { [weak store] in store?.saveProgress(id: $0, sentence: $1, fraction: $2) }`.
    /// `fraction` is the share of the book's words before the sentence
    /// (`positionFraction`), 1.0 at the end, so the card's time left counts
    /// the words the reader's does.
    var onProgress: ((_ documentID: UUID, _ sentence: Int, _ fraction: Double) -> Void)?

    /// "Where you stopped" sink: every end of a listening session, however
    /// short (PlaybackController+PlaceHistory.swift). Nil by default, like
    /// `onProgress`, so no test controller writes anywhere.
    var onPlaceStop: ((PlaceStop) -> Void)?
    /// The session being timed, and the last stop reported; owned by
    /// PlaybackController+PlaceHistory.swift.
    var placeSession: PlaceSession?
    var lastPlaceStop: PlaceStop?
    /// The session iOS ended at the last launch, until AppModel takes it.
    var recoveredPlaceStop: PlaceStop?
    /// The sentence iOS ended the app on, from the live marker: the book
    /// reopens there, not at the last progress write (throttled to 2 s).
    /// Applied once, by the first load of that book.
    private var recoveredLiveSession: LiveSession?

    // MARK: - Dependencies & graph

    private let engine: any TtsEngine
    private let kokoro: (any WarmableTtsEngine)?
    private let fallbackVoice: TtsVoice
    private let scheduler: SynthesisScheduler
    private let cache: AudioClipCache
    private let audioOutput: any AudioOutputMonitoring
    private let anchorStore: ResumeAnchorStore
    private let stopStore: PlaybackStopStore

    /// Made anew only after a media-services reset (`mediaServicesWereReset`).
    private var audioEngine = PlaybackController.makeAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    /// S7b: the observer of `audioEngine`'s own output changes.
    private var engineConfigurationObserver: NSObjectProtocol?
    private var graphFormat: AVAudioFormat?
    /// When a scheduled clip counts as finished: once heard through the
    /// device, or, rendering offline with no device to present it, once
    /// rendered (`.dataPlayedBack` never fires there). Release never
    /// renders offline.
    private var completionCallbackType: AVAudioPlayerNodeCompletionCallbackType {
        rendersOffline ? .dataRendered : .dataPlayedBack
    }
    #if DEBUG
    /// Pulls the offline render along in real time (`rendersOffline`).
    private var renderPump: MutedRenderPump?
    /// Every real-time `audioEngine.start()`: one that renders offline
    /// never makes any.
    private(set) var realtimeEngineStarts = 0
    #endif

    /// Held while active (`PlatformActivity`).
    private var activity: PlatformActivity.Token?
    /// The armed idle stop (M19), while one is.
    private var idleEngineStopItem: DispatchWorkItem?
    /// M19's first-audio interval: open from Play while the status buffers.
    private var firstAudio: BudgetSignposts.Interval?
    /// C1: a seek that plays (a sentence tap, a pick while playing, a
    /// skip) to its first buffer on the started node; open while it buffers.
    private var tapAudio: BudgetSignposts.Interval?
    /// C5: the warm-up a Mac click's hold started (`warmJumpTarget`), until
    /// the click plays (any seek) or gives way (`dropJumpWarmUp`).
    private var heldWarmUpKey: String?
    /// Open while reading has run dry: a sentence ended before the next
    /// one's clip was on the node. Status shows `.buffering` meanwhile.
    private var catchingUp: BudgetSignposts.Interval?
    /// M19's budget signposts. Tests replace it.
    var budgetSignposts = BudgetSignposts.live
    /// The engine-configuration and system-sleep observers, with the
    /// center each was added to.
    private var systemObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    // MARK: - Scheduling state

    /// M3 word karaoke: clip windows + frame ticker (PlaybackController+WordTiming.swift).
    let wordTiming = WordKaraokeState()

    private var playToken: UInt64 = 0
    private var scheduleTask: Task<Void, Never>?
    private var lastScheduled = -1
    private var hasActiveSchedule = false
    private var consecutiveFailures = 0
    /// The sentences skipped since the last clip that synthesized, in order.
    /// Each was skipped as one bad sentence; a run that reaches the stop
    /// threshold was the voice failing, so the stop hands them back
    /// (`withdrawFailedRunSkips`).
    private var failedRunSkips: [Int] = []
    /// Set only by an interruption that stopped playback. Every user
    /// transport and every later stop clears it, so `.ended(shouldResume:)`
    /// brings back that stop and nothing the listener paused since.
    private var resumeAfterInterruption = false
    /// Aloud claimed the audio session and hasn't given it back: iOS tells
    /// only such a session when an interruption begins and ends. The idle
    /// stop's release, an interruption's end and a media-services reset
    /// leave it unclaimed until the next Play claims it.
    private var holdsAudioSession = false
    /// An interruption began: iOS took the session's activation, though
    /// Aloud still holds it for the end. The next start claims it again
    /// even where the engine (a test host's) kept running.
    private var sessionClaimLapsed = false
    /// A cold live start's claim, made off the main actor while its first
    /// clip is fetched or made (R4-33), and the play token it serves.
    private var pendingClaim: (token: UInt64, task: Task<Void, Error>)?
    /// The play token whose claim has landed: its first clip's hardware
    /// start activates nothing more.
    private var claimedToken: UInt64?
    /// Claims the output off the main actor (`AudioOutputClaiming`, the
    /// iPhone's session); nil claims in place at the hardware start
    /// (`audioOutput.activate()`), as the Mac, whose claim is a no-op, and
    /// the test rig's monitor do. Tests set it.
    var claimAudioOutput: (@MainActor () async throws -> Void)?
    private var noticeTask: Task<Void, Never>?
    /// True for the length of a document switch, so the `.paused` cue of the
    /// INCOMING book can't be mistaken for the outgoing book's stop.
    private var isSwitchingDocument = false
    /// A Finished book's stored progress, held while the playhead stays on
    /// the sentence it finished at. Re-cueing that sentence (opening the
    /// book, an audition, the outgoing-book flush) would otherwise report
    /// the words before it, below `LibraryDocument.finishedThreshold` for any
    /// book whose last sentence is over 1% of it, and the next open would
    /// autoplay (R4). It
    /// also keeps a fraction short of 1.0 that the Finished rule's slack
    /// accepts (0.995 of an article) exactly as stored.
    private var finishedCue: (sentence: Int, fraction: Double)?

    /// A stop recorded while VoiceOver couldn't hear it (backgrounded, or an
    /// interruption that may still give the audio back), announced by
    /// `sceneDidBecomeActive` if it is still the current stop.
    private var pendingStopAnnouncement: StopReason?
    /// R19: the queue never schedules past this sentence, and playback stops
    /// cued after it when it finishes.
    private var sleepStopAfter: Int?
    private var undoTask: Task<Void, Never>?

    // MARK: - Volume automation state (R19/R20)

    private var rampTask: Task<Void, Never>?
    private var rampCompletion: (@MainActor (Bool) -> Void)?
    /// Bumped by every cancel, so a superseded ramp's last wake-up is inert.
    private var rampGeneration: UInt64 = 0
    /// A user pause's ramp is in flight: the node is still playing out the
    /// last 120 ms while `status` already reads `.paused`.
    private var isRampingToPause = false
    /// The fade the next cold start ramps in over: set by a user play, an
    /// autoplay or a seek-and-play, never by auditions, voice reloads or
    /// seeks while active.
    private var pendingFadeIn: TimeInterval?

    /// The elapsed time a pause froze, so a skip measured while paused
    /// counts from where the audio stopped. Internal: a test seam.
    var frozenSentenceElapsed: TimeInterval?

    /// R8: a voice picked while not playing speaks the current sentence once
    /// (`stopAfter`), then returns to `restore`. Scheduling never looks past
    /// `stopAfter`, and the audition never touches the resume anchor, the
    /// play counter or a recorded stop. Any transport action ends it.
    private struct Audition {
        let stopAfter: Int
        let restore: PlayerStatus
    }
    private var audition: Audition?

    /// R5: the voice the install switch is moving to. `spliceAt` is nil while
    /// the engine warms; once fixed, sentences from it on are synthesized and
    /// queued in `voice` behind the clips already on the node. `notice` is
    /// what the commit shows (R11's cooling switch passes its own).
    /// `landingWithin`: the most sentences past the playhead the splice may
    /// sit (R11's cooling switch on an iPhone), nil for no limit.
    /// `outgoingThrough`: set when the queue was deeper than that, so the
    /// splice sits at the next boundary with the outgoing voice's clips
    /// still queued through this sentence; they are dropped there
    /// (`sentenceFinished`).
    private struct VoiceHandoff {
        let voice: TtsVoice
        let notice: PlaybackNotice?
        var spliceAt: Int?
        var landingWithin: Int? = nil
        var outgoingThrough: Int? = nil
    }
    private var handoff: VoiceHandoff? {
        // A cut no longer pending never silences the render side.
        didSet { if handoff?.outgoingThrough == nil { cutSplice.disarm() } }
    }
    /// P009: the render side of a splice cut short (`CutSpliceSilencer`).
    private let cutSplice = CutSpliceSilencer()
    private var isSettingVoiceQuietly = false
    /// The voice a pending switch is moving to, still on its way in behind
    /// `voice` (its engine warming, or its first clips queued past the
    /// splice); nil with none. Heat reads it (`ThermalGuard`).
    var incomingVoice: TtsVoice? { handoff?.voice }

    nonisolated private static let lookAhead = 2
    /// Spoken seconds of a sentence at 1x, from its characters: Kokoro's
    /// measured fit (0.94 s + 50.4 ms per character).
    nonisolated static func estimatedSeconds(characters: Int) -> TimeInterval {
        0.94 + 0.0504 * Double(max(characters, 0))
    }
    private static let synthesisAttempts = 3   // 1 try + 2 retries per sentence
    /// How long the top-up waits before asking again when the prefetch lane
    /// refuses a sentence (`SynthesisSchedulerError.backlogFull`).
    private static let backlogRetryNanoseconds: UInt64 = 200_000_000
    private static let skippedClipDuration = 0.05

    // MARK: - Init

    /// `audioSession` is the platform's output monitor
    /// (`PlatformAudioOutput.makeMonitor()`), labelled as before the Mac.
    /// A muted controller stays silent the platform's way
    /// (`mutedOutputMode`). `lifecycle` is where the system-sleep event and
    /// an iPhone's media-services reset arrive: the platform's centers, or a
    /// private one in tests.
    init(engine: any TtsEngine,
         kokoro: (any WarmableTtsEngine)? = nil,
         defaultVoice: TtsVoice,
         scheduler: SynthesisScheduler,
         cache: AudioClipCache,
         audioSession audioOutput: any AudioOutputMonitoring,
         anchorStore: ResumeAnchorStore = ResumeAnchorStore(),
         stopStore: PlaybackStopStore = PlaybackStopStore(),
         outputMuted: Bool = UITestHooks.muteAudio,
         mutedOutputMode: MutedOutputMode = PlatformAudio.mutedOutputMode,
         autoplaySuppressed: Bool = UITestHooks.suppressAutoplay,
         lifecycle: NotificationCenter? = nil) {
        self.engine = engine
        self.kokoro = kokoro
        self.fallbackVoice = defaultVoice
        self.scheduler = scheduler
        self.cache = cache
        self.audioOutput = audioOutput
        if let claimer = audioOutput as? AudioOutputClaiming {
            self.claimAudioOutput = { try await claimer.claim() }
        }
        self.anchorStore = anchorStore
        self.stopStore = stopStore
        self.isOutputMuted = outputMuted
        #if DEBUG
        self.rendersOffline = outputMuted && mutedOutputMode == .manualRendering
        #else
        self.rendersOffline = false
        #endif
        self.isAutoplaySuppressed = autoplaySuppressed
        self.voice = defaultVoice

        // The level is only remembered here: connecting the graph writes it.
        // Touching mainMixerNode builds the output unit, an audio-server round
        // trip that aborted launch when it timed out.
        assembleAudioGraph()

        announce = { PlaybackController.postAnnouncement($0, muted: outputMuted) }
        emitHaptic = { TransportHaptics.emit($0) }

        // R11: a live-session marker that outlived its launch means iOS
        // closed Aloud while it was speaking (willTerminate and every orderly
        // stop clear it). The listener gets the reason, and the next Play
        // rewinds from that sentence after the real rest.
        if let live = stopStore.takeLiveSession() {
            stopStore.save(PlaybackStop(reason: .closedByIOS, documentID: live.documentID))
            anchorStore.save(ResumeAnchor(documentID: live.documentID,
                                          sentenceIndex: live.sentenceIndex,
                                          wallClock: live.wallClock,
                                          monotonic: nil))
            pendingStopAnnouncement = .closedByIOS
            recoveredPlaceStop = PlaceStop.recovered(from: live)
            recoveredLiveSession = live
        }
        stopped = stopStore.load()

        audioOutput.onInterruption = { [weak self] event in
            self?.handleInterruption(event)
        }
        audioOutput.onRouteRequiresPause = { [weak self] in
            self?.stop(because: .headphonesDisconnected)
        }
        // S11: synchronous, on the main thread that posts it, so the stop is
        // recorded before the machine sleeps. An iPhone never posts it.
        let sleepCenter = lifecycle ?? PlatformLifecycle.center(for: .systemWillSleep)
        systemObservers.append((sleepCenter, PlatformLifecycle.observe(.systemWillSleep, in: sleepCenter) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }))
        // The media server restarted under the app (an iPhone's; a Mac has
        // none). Posted on whichever thread noticed it.
        if let reset = PlatformAudio.mediaServicesReset {
            let sessionCenter = lifecycle ?? NotificationCenter.default
            systemObservers.append((sessionCenter, sessionCenter.addObserver(
                forName: reset, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.mediaServicesWereReset() }
            }))
        }
        configureWordTiming()
    }

    deinit {
        for observer in systemObservers {
            observer.center.removeObserver(observer.token)
        }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
        PlatformActivity.end(activity)
        idleEngineStopItem?.cancel()
    }

    // MARK: - Word-timing hooks (implementation in PlaybackController+WordTiming.swift)

    /// Playhead position in 1× media seconds since the player's last stop.
    /// `playerTime` counts source frames, so the time-pitch rate is already
    /// folded in — word windows laid out at natural duration map directly.
    var playerMediaSeconds: TimeInterval? {
        // A render time with neither clock valid (offline rendering before its
        // first pull) makes playerTime(forNodeTime:) raise, not return nil.
        guard let nodeTime = player.lastRenderTime,
              nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let time = player.playerTime(forNodeTime: nodeTime),
              time.sampleRate > 0, time.sampleTime >= 0 else { return nil }
        return Double(time.sampleTime) / time.sampleRate
    }

    /// What the output has still to present behind the render clock above
    /// (wall seconds: the time-pitch, mixer and device downstream of the
    /// player; zero rendering offline), and the time-pitch rate the render
    /// pulls media at. The word tint subtracts the lag they make. A bypassed
    /// unit passes media 1:1, whatever rate a speed picked mid-sentence has
    /// already set on it for the next boundary (`applyTimePitchRate`).
    var outputLag: (latency: TimeInterval, timePitchRate: Double) {
        (player.outputPresentationLatency, timePitch.bypass ? 1 : Double(timePitch.rate))
    }

    /// The end of the clip rendering at media time `now` while the bypassed
    /// time-pitch unit holds a speed picked mid-sentence for the next
    /// boundary: up to there the media passes 1:1, not at the share the
    /// clip's compression implies. Nil when the unit plays that share.
    private func pendingSpeedBoundary(at now: TimeInterval) -> TimeInterval? {
        guard timePitch.bypass, timePitch.rate != 1 else { return nil }
        return wordTiming.clips.values
            .first { $0.start <= now && now < $0.start + $0.duration }
            .map { $0.start + $0.duration }
    }

    /// Where a clip handed to the node now starts if the queue has run dry
    /// (synthesis slower than speech): a running node, playing or ramping
    /// out a pause, has moved on through silence to its live playhead; a
    /// paused one resumes from where it stopped. Nil for a schedule's first
    /// clip, which starts the node at 0. A clip never starts before the end
    /// of the queue (`WordKaraokeState.appendScheduled`).
    var schedulingPlayhead: TimeInterval? {
        guard hasActiveSchedule else { return nil }
        // Running dry counts as playing here: the node runs on in silence,
        // so the clip that ends it starts at the playhead.
        if status == .playing || isRampingToPause || catchingUp != nil { return playerMediaSeconds }
        return wordTiming.pausedPlayhead
    }

    /// Publishes `currentWord` on change only (called by the frame ticker).
    func updateCurrentWord(_ index: Int) {
        if currentWord != index { currentWord = index }
    }

    // MARK: - Loading

    /// Loads a document, cueing at its saved position (a Finished book at its
    /// end, `.ended`, R24: `reopensAtItsEnd`). Reloading the document already
    /// playing is a no-op so re-entering the reader never restarts audio.
    func load(document: LibraryDocument, content: DocContent) {
        if self.document?.id == document.id,
           self.content?.contentHash == content.contentHash {
            self.document = document
            return
        }
        // R4: opening B while A plays saves the sentence A was speaking,
        // while `self.document` still names A.
        reportProgress()
        // The outgoing book's rest starts now: anchor it while `self.document`
        // still names it, and hold the stamp off for the rest of the switch so
        // the incoming book can never be handed a stop that isn't its own.
        // (Mid-audition the stamp is a no-op: that rest began at the pause.)
        if isActive { stampResumeAnchor() }
        endPlaceSession()   // the outgoing book's place, while `document` names it
        audition = nil
        // The outgoing book's notice (a rewind or a skip line) is never the
        // incoming book's line. Before the flush: a splice it commits names
        // the voice this book reads in.
        clearNotice()
        // An interruption's end never starts a book the listener switched to.
        resumeAfterInterruption = false
        isSwitchingDocument = true
        defer { isSwitchingDocument = false }

        invalidateSchedule()
        cache.removeAll()   // clips from the previous document can never replay
        self.document = document
        self.content = content
        systemVoiceLanguage = AVSpeechEngine.readingLanguage(of: content.sentences.lazy.map(\.text))
        let navigation = content.navigationIndex()
        wordsBefore = navigation.wordsBefore   // before the cue's progress write
        chapterOpeners = content.chapterOpenerSentences(kind: document.kind, chapters: navigation.chapters)
        skippedSentences = []
        consecutiveFailures = 0
        failedRunSkips = []
        finishedCue = nil   // after the flush above, which used the outgoing book's
        sleepStopAfter = nil
        pendingFadeIn = nil
        clearUndoableJump()

        if content.sentences.isEmpty {
            status = .idle
            currentSentence = -1
        } else {
            status = .paused   // the outgoing book's stop, before the cue
            // R24: a Finished book reopens at its end, cued on its last
            // sentence, holding its stored fraction while the playhead stays
            // put (`finishedCue`), so neither the words before that sentence
            // nor the cue un-finish it. Any other book, a long classic 0.99
            // of the way through with half an hour left or one left Finished
            // by an unattended stop (R11), keeps its saved sentence.
            let last = content.sentences.count - 1
            let atEnd = Self.reopensAtItsEnd(document, stop: stopReason(for: document.id))
            let saved = min(max(document.progressSentence, 0), last)
            // iOS ended the app mid-speech: the marker knows the sentence the
            // last progress write (at most 2 s old) may not have reached.
            var recovered: Int?
            if let live = recoveredLiveSession, live.documentID == document.id {
                recovered = min(max(live.sentenceIndex, 0), last)
                recoveredLiveSession = nil
            }
            let cue = atEnd ? last : max(saved, recovered ?? saved)
            if atEnd { finishedCue = (cue, document.progressFraction) }
            currentSentence = cue
            if atEnd { status = .ended }
        }
        restoreResumeAnchor(for: document)
        if !content.sentences.isEmpty {
            // Play from the end starts at the top (Listen again): warm that.
            // Either way the outgoing book's queued warm-ups are dropped
            // first, so they never hold up this book's first Play.
            if status == .ended {
                cuePrefetch(from: 0, through: 1, voice: voice, replacingWarmUps: true)
            } else {
                cuePrefetch(moved: true)
            }
        }
    }

    /// Whether a book opens at its end (R24): when it is Finished, with one
    /// exception. The rule's time slack (`LibraryDocument.finishedSlackSeconds`)
    /// is what keeps a stop well short of the end (a sleep timer on a long
    /// classic, 0.99 with half an hour left) at the listener's place.
    /// The exception: a book short of a stored 1.0 that still has an
    /// unattended `stop` (R11, any reason) reopens paused at its saved
    /// sentence, because the stop's line promises one tap resumes there (or
    /// at its rewind target); the colophon's Play would start it over. Its
    /// card still reads Finished, so it never autoplays (`opensPlaying`). A
    /// stored 1.0 (a natural end, Mark as finished) always opens at the end.
    nonisolated static func reopensAtItsEnd(_ document: LibraryDocument, stop: StopReason?) -> Bool {
        document.isFinished && (document.progressFraction >= 1 || stop == nil)
    }

    func unload() {
        // The book keeps the rest that starts here (on disk), so reopening it
        // still rewinds; the in-memory slot belongs to no document now.
        if isActive { stampResumeAnchor() }
        endPlaceSession()
        if let document { discardStop(for: document.id) }
        audition = nil
        invalidateSchedule()
        // The closed book's queued warm-ups go too: nothing will read them.
        Task { [scheduler, voice] in
            await scheduler.prefetch([], voice: voice, replacingWarmUps: true)
        }
        document = nil
        content = nil
        systemVoiceLanguage = nil
        wordsBefore = []
        chapterOpeners = []
        skippedSentences = []
        sleepStopAfter = nil
        pendingFadeIn = nil
        clearUndoableJump()
        clearNotice()   // the book's own: no other book inherits it
        currentSentence = -1
        status = .idle
        resumeAnchor = nil
    }

    // MARK: - Transport

    /// `userInitiated` marks a deliberate start (button, remote command) as
    /// opposed to programmatic resumes like interruption recovery; only the
    /// former bumps `userPlayAction` and may rewind. `fadeIn` is the ramp the
    /// audio comes up over (R20): 120 ms for a resume, 300 ms for autoplay.
    func play(userInitiated: Bool = true, fadeIn: TimeInterval = AudioEdge.resumeRamp) {
        // The listener took over: an interruption's later end resumes nothing.
        if userInitiated { resumeAfterInterruption = false }
        guard let content, !content.sentences.isEmpty else { return }
        // M19: Play to the first buffer on the started node; cold when the
        // neural model loads first. A path that leaves the status as it was
        // (a sample already speaking) settles on the way out.
        budgetSignposts.end(&firstAudio, gaveUp: true)
        firstAudio = budgetSignposts.begin(.firstAudio,
                                           voice.engine == .kokoro && kokoro?.isWarm == false ? .cold : .warm)
        defer { settleFirstAudio() }
        // Resume rewind: a USER play after a real break backs up a couple of
        // sentences to rebuild context. Programmatic resumes (interruption
        // end, route-change recovery) never rewind. Read from the listener's
        // pause, so a voice sample over it doesn't hide the break.
        let rewindTarget = userInitiated ? resumeRewindTarget() : nil
        // R8: Play over a speaking sample is Play from where the listener
        // is. From a pause the sample carries on as the book; from the end,
        // or with a rewind due, it starts the way it would have anyway.
        if audition != nil, isActive, listenerStatus == .paused, rewindTarget == nil {
            continueAuditionAsPlayback(userInitiated: userInitiated, fadeIn: fadeIn)
            return
        }
        pendingFadeIn = fadeIn
        if let target = rewindTarget {
            let from = currentSentence
            clearResumeAnchor()   // applied once — in this launch and the next
            // Through `seek` (which also ends a sample as a start from the
            // pause), so the play token, cache and `userPlayAction` agree.
            seek(to: target, andPlay: true)
            postNotice(.backedUp(sentences: from - target))
            return
        }
        if userInitiated, !isListenerPlaying { userPlayAction &+= 1 }
        let auditionWasSpeaking = audition != nil && isActive
        let fromEnd = listenerStatus == .ended
        audition = nil
        if fromEnd {
            startPlayback(at: 0)
            // A sample was already active, so `status.didSet` saw no entry.
            if auditionWasSpeaking { didEnterActivePlayback() }
            return
        }
        // The system stopped the engine under the pause (an interruption, an
        // output change): the node let its queue go with it, as at the idle
        // stop, so Play reads on from the same sentence's start.
        if status == .paused, hasActiveSchedule, !audioEngine.isRunning {
            invalidateSchedule()
        }
        if status == .paused, hasActiveSchedule {
            do { try startAudioHardware() } catch { audioHardwareFailed(error); return }
            pendingFadeIn = nil
            frozenSentenceElapsed = nil
            if isRampingToPause {
                // Turnaround: the pause's ramp is still running, so the node
                // never paused; the ramp below reverses it from where it is.
                isRampingToPause = false
            } else {
                resumeNode()
            }
            status = .playing
            rampOutputVolume(to: 1, over: fadeIn)
            return
        }
        startPlayback(at: max(currentSentence, 0))
    }

    /// Ends the first-audio interval once the status leaves `.buffering`:
    /// `.playing` is the first buffer on the started node (a warm resume's
    /// included), any other status a start that gave up.
    private func settleFirstAudio() {
        guard status != .buffering else { return }
        budgetSignposts.end(&firstAudio, gaveUp: status != .playing)
        budgetSignposts.end(&tapAudio, gaveUp: status != .playing)
        #if DEBUG
        TapAudioProbe.shared.settled(playing: status == .playing)
        #endif
        // A dry spell ends however buffering does: its clip landed
        // (`.playing`), or a pause, seek or stop took it over.
        budgetSignposts.end(&catchingUp, gaveUp: status != .playing)
    }

    /// A user pause (R20): `.paused` publishes at once — chrome, Now Playing
    /// rate 0, the resume anchor — while the audio ramps out over 120 ms and
    /// only then pauses the node. `rampsOut: false` cuts at once and leaves
    /// the level at 0, so the next resume ramps in. Over a voice sample of a
    /// Finished book it hands back the end instead (`returnAuditionToTheEnd`).
    func pause(rampsOut: Bool = true) {
        // A pause is the last word: no interruption's end resumes past it.
        // (`.began` sets the flag after its own stop has paused.)
        resumeAfterInterruption = false
        // Paused before the first clip: the claim on its way goes, and the
        // session with it (R4-33).
        cancelPendingClaim()
        // No book: the only audio is a voice sample (status stays `.idle`),
        // and a Pause cuts it, heard or still being made.
        if content == nil {
            if isSpeakingSample { invalidateSchedule() }
            return
        }
        // R8: the listener was at the end, not paused on the last sentence.
        if isActive, audition?.restore == .ended {
            returnAuditionToTheEnd(rampsOut: rampsOut)
            return
        }
        switch status {
        case .playing:
            frozenSentenceElapsed = nil
            frozenSentenceElapsed = currentSentenceElapsed   // before the status leaves .playing
            pendingFadeIn = nil
            let pausedAt = currentSentence
            status = .paused
            if audition != nil {
                // Paused mid-audition: this is now an ordinary pause, so fill
                // the look-ahead the audition held back and Play is gapless.
                audition = nil
                chainTopUp(token: playToken)
            }
            if rampsOut {
                rampOutputVolume(to: 0, over: AudioEdge.pauseRamp) { [weak self] finished in
                    guard finished, let self, self.isRampingToPause else { return }
                    self.isRampingToPause = false
                    self.pauseNode()
                    // A boundary inside the ramp moved the playhead after the
                    // pause stamped it.
                    if self.currentSentence != pausedAt {
                        self.stampResumeAnchor()
                        self.placeStopMovedByPauseRamp()
                    }
                }
                // After the call: the ramp's own cancel of the one before must
                // not pause the node.
                isRampingToPause = true
            } else {
                pauseNode()
                cancelVolumeRamp()
                setOutputVolume(0)   // silent (the node is paused), so the resume ramps in
            }
        case .buffering:
            pendingFadeIn = nil
            invalidateSchedule()
            status = .paused
            audition = nil
            cuePrefetch()
            if !rampsOut {
                cancelVolumeRamp()
                setOutputVolume(0)
            }
        default:
            break
        }
    }

    /// A pause or stop during a voice sample over a Finished book: back to
    /// `.ended`, the way the sample's own finish returns there
    /// (`finishAudition`), so the book stays Finished and Play starts it
    /// over. Never a pause on the last sentence, which Play would
    /// warm-resume and end again. `audition` is still set while the status
    /// changes, so no resume anchor is stamped. A heard sample with
    /// `rampsOut` plays out its 120 ms ramp, then the node pauses and the
    /// schedule is dropped; otherwise that happens at once, and
    /// `rampsOut: false` leaves the level at 0 like any cut.
    private func returnAuditionToTheEnd(rampsOut: Bool) {
        pendingFadeIn = nil
        if status == .playing, rampsOut {
            status = .ended
            audition = nil
            rampOutputVolume(to: 0, over: AudioEdge.pauseRamp) { [weak self] finished in
                guard finished, let self, self.isRampingToPause else { return }
                self.isRampingToPause = false
                self.pauseNode()
                // Nothing here is ever resumed: Play from the end starts over.
                self.invalidateSchedule()
            }
            // Set after the call, as in `pause`. As a pause's ramp it ends at
            // any restart before it finishes (`invalidateSchedule`), so it
            // never fades out the next start.
            isRampingToPause = true
        } else {
            if status == .playing { pauseNode() }   // a cut (`rampsOut: false`), as in `pause`
            invalidateSchedule()
            status = .ended
            audition = nil
            if !rampsOut {
                cancelVolumeRamp()
                setOutputVolume(0)
            }
        }
        cuePrefetch()
    }

    /// R4: the reader calls this once per open; `opensPlaying` is the policy.
    /// R20's 300 ms fade-in lives here (the haptic belongs to the tap that
    /// opened the book, never to autoplay).
    func startAutoplay() {
        guard let document, opensPlaying(document) else { return }
        play(fadeIn: AudioEdge.autoplayFadeIn)
    }

    /// Whether opening `document` starts it speaking: never in a UI-test
    /// launch without -uitest-allow-autoplay, never for a Finished book
    /// (which opens at its end, R24, or paused at the sentence an
    /// unattended stop left: `reopensAtItsEnd`), and never for the book already
    /// speaking (continue, never restart).
    func opensPlaying(_ document: LibraryDocument) -> Bool {
        // A voice sample over the book's pause isn't it speaking: opening
        // it plays on, the same as once the sample has ended.
        !isAutoplaySuppressed
            && !document.isFinished
            && !(self.document?.id == document.id && isListenerPlaying)
    }

    func togglePlayPause() {
        if isActive {
            pause()
        } else {
            play()
        }
    }

    /// Sentence-granular seek. Playing keeps playing from the target; paused
    /// cues the target (and warms synthesis) without starting audio. During
    /// an audition the listener is paused (R8): the seek cues, unless it
    /// plays, which turns the sample into real playback.
    func seek(to sentence: Int, andPlay: Bool) {
        resumeAfterInterruption = false   // the listener chose where to be
        let auditioning = audition != nil
        let playing = isListenerPlaying
        guard let content, !content.sentences.isEmpty else { audition = nil; return }
        let target = min(max(sentence, 0), content.sentences.count - 1)
        skippedSentences.remove(target)   // an explicit seek gives it another chance
        // Tap-to-seek, scrub, chapter row, search match, remote skip: the user
        // has just chosen where to start, and the resume rewind must never
        // second-guess that choice by backing up from an older rest.
        clearResumeAnchor()
        // A move past the sleep timer's landing leaves it behind; the timer
        // re-aims from the new position.
        if let stopAfter = sleepStopAfter, target > stopAfter { sleepStopAfter = nil }

        if andPlay, !playing {
            userPlayAction &+= 1   // e.g. restart after .ended, or over an audition
            if pendingFadeIn == nil { pendingFadeIn = AudioEdge.resumeRamp }
        }
        heldWarmUpKey = nil   // a held click's warm-up is this start's, or no longer wanted ahead
        if andPlay || playing {
            // C1: the seek to its first buffer on the started node; a seek
            // before the last one sounded ends that one, given up.
            let cold = voice.engine == .kokoro && kokoro?.isWarm == false
            budgetSignposts.end(&tapAudio, gaveUp: true)
            tapAudio = budgetSignposts.begin(.tapAudio, cold ? .cold : .warm)
            #if DEBUG
            TapAudioProbe.shared.tapBegan(cold: cold)
            #endif
            let wasActive = isActive
            audition = nil
            startPlayback(at: target)
            // An audition was already active, so `status.didSet` saw no
            // entry: this is where its stop clears and the session goes live.
            if auditioning, wasActive { didEnterActivePlayback() }
            settleFirstAudio()   // a start that left the status as it was
        } else {
            invalidateSchedule()
            status = .paused   // `audition` still set: a sample stamps no resume anchor
            audition = nil
            currentSentence = target
            cuePrefetch(moved: true)   // the old cue's warm-ups never hold up Play here
        }
    }

    /// Play over an audition from a pause. Status never left active, so this
    /// is the entry `status.didSet` can't see.
    /// - Heard already: the sample becomes playback in place, at its own
    ///   level, with no restart. A look-ahead clip that lands late is placed
    ///   at the playhead (`wordTimingRecordScheduled`), so word timing, skips
    ///   and the sleep timer stay true across the wait.
    /// - Not heard yet (buffering, or a voice still warming): an ordinary
    ///   start from the cue, fading in. Its schedule may be stale (a warm-up
    ///   flushed it), and nothing audible is lost.
    /// A sample whose voice is still warming from a pause isn't active, so
    /// Play takes the ordinary path; `prepareNeuralVoice` has already dropped
    /// the paused schedule, so that too is a fading start in the new voice.
    private func continueAuditionAsPlayback(userInitiated: Bool, fadeIn: TimeInterval) {
        audition = nil
        if userInitiated { userPlayAction &+= 1 }
        if hasActiveSchedule {
            pendingFadeIn = nil
            chainTopUp(token: playToken)   // the look-ahead the audition held back
        } else {
            pendingFadeIn = fadeIn
            startPlayback(at: max(currentSentence, 0))
        }
        didEnterActivePlayback()
    }

    // MARK: - Stops (R11)

    /// An unattended stop: route loss, an interruption, heat, the sleep
    /// timer. The audio cuts at once (never ramped), then the reason is
    /// recorded and announced. An audition just ends, recording nothing.
    func stop(because reason: StopReason) {
        // Any later stop (headphones gone mid-call, heat) outranks an earlier
        // interruption's resume, even while already paused.
        let interruptionWouldResume = resumeAfterInterruption
        resumeAfterInterruption = false
        // A claim still on its way goes; the session goes with it, except
        // to an interruption, whose end comes only to a held session.
        cancelPendingClaim(releasing: reason != .interrupted)
        // No book: the only audio is a voice sample (status stays `.idle`).
        // It is cut too, heard or still being made, so it never carries on
        // from the speaker once the headphones are gone.
        if content == nil { invalidateSchedule(); return }
        guard isActive else {
            // Paused by an interruption that would have resumed: this later
            // stop is now why the book stays paused when it ends, so it
            // replaces the interruption's reason and its pending line.
            if interruptionWouldResume, let document,
               stopped == PlaybackStop(reason: .interrupted, documentID: document.id) {
                record(reason)
            }
            return
        }
        let auditioning = audition != nil
        pause(rampsOut: false)
        guard !auditioning else { return }
        record(reason)
    }

    func stopReason(for documentID: UUID) -> StopReason? {
        stopped?.documentID == documentID ? stopped?.reason : nil
    }

    /// Forgets the stop (and its pending announcement) when it names
    /// `documentID`: the book was deleted or unloaded.
    func discardStop(for documentID: UUID) {
        guard stopped?.documentID == documentID else { return }
        clearStop()
    }

    /// The app came to the front. Paused, the cue is warmed again: a rest
    /// that crossed the 5 or 30 minute mark in the background now rewinds
    /// further than the warm-up made at the pause (clips still cached cost
    /// nothing). Never when that means loading a cold natural voice under
    /// strain (Low Power Mode or `.serious` heat), the load NeuralPrewarm
    /// skips there too (M19): the new target misses the cache by
    /// definition, and the idle engine was freed a minute after the pause,
    /// so Play pays that load, as it always has. Then a stop VoiceOver
    /// couldn't hear is announced.
    func sceneDidBecomeActive() {
        if content != nil, status == .paused,
           voice.engine != .kokoro || kokoro?.isWarm == true || !isUnderStrain() {
            cuePrefetch()
        }
        announceHeldBackStop()
    }

    /// Announces a stop recorded while VoiceOver couldn't hear it, once, if
    /// it is still the current stop.
    private func announceHeldBackStop() {
        guard let pending = pendingStopAnnouncement else { return }
        pendingStopAnnouncement = nil
        guard stopped?.reason == pending else { return }
        announce(pending.spokenText)
    }

    /// The process is going away in order: whatever was playing gets its
    /// rest anchored, and no closed-by-iOS reason is reported next launch.
    func applicationWillTerminate() {
        if isActive { stampResumeAnchor() }
        endPlaceSession()
        stopStore.clearLive()
    }

    /// R19's "Back 5 min": rewinds to the sentence start nearest 5 minutes
    /// earlier and plays, in one tap. Never `skip(seconds:)`: no 3 s restart
    /// rule. The seek clears the resume anchor, so rewinds never stack.
    func backFiveMinutes() {
        guard let content, !content.sentences.isEmpty else { return }
        let target = Self.skipTarget(from: max(currentSentence, 0),
                                     seconds: -Self.sleepRewindSeconds,
                                     sentenceCount: content.sentences.count,
                                     wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate,
                                     words: { content.sentences[$0].wordCount })
        seek(to: target, andPlay: true)
    }

    nonisolated static let sleepRewindSeconds: TimeInterval = 300

    private func record(_ reason: StopReason) {
        guard let document else { return }
        let stop = PlaybackStop(reason: reason, documentID: document.id)
        stopped = stop
        stopStore.save(stop)
        if reason == .sleepTimer { sleepStopSerial &+= 1 }
        // An interruption may still give the audio back; it is announced
        // only if it never does.
        if reason != .interrupted, isAppActive() {
            pendingStopAnnouncement = nil
            announce(reason.spokenText)
        } else {
            pendingStopAnnouncement = reason
        }
    }

    private func clearStop() {
        pendingStopAnnouncement = nil
        guard stopped != nil else { return }
        stopped = nil
        stopStore.clear()
    }

    /// Every way into playback lands here. A stop clears on it (Play,
    /// seek-and-play, tap-to-play, interruption auto-resume, Back 5 min),
    /// except during an audition, which isn't the listener resuming. An
    /// audition that becomes playback (Play or a seek-and-play over it) calls
    /// it directly, since `status` never left active.
    private func didEnterActivePlayback() {
        guard audition == nil else { return }
        clearStop()
        beginPlaceSession()
        markLiveSession()
    }

    /// While audio plays, the marker says where; an audition is not a session.
    private func markLiveSession() {
        guard audition == nil, let document, currentSentence >= 0 else { return }
        stopStore.markLive(LiveSession(documentID: document.id,
                                       sentenceIndex: currentSentence,
                                       wallClock: Date(),
                                       startedAt: placeSession?.startedAt,
                                       startSentence: placeSession?.startSentence,
                                       movedAway: placeSession?.movedAway))
    }

    // MARK: - Sleep-stop mechanics (R19)

    /// The queue never schedules past `sentence`; when that sentence finishes
    /// (and it is not the book's last) playback pauses cued at `sentence + 1`
    /// and records `.sleepTimer`.
    func scheduleStop(afterSentence sentence: Int) {
        sleepStopAfter = sentence
        if isActive { chainTopUp(token: playToken) }   // a raised cap resumes the top-up
    }

    func cancelScheduledStop() {
        guard sleepStopAfter != nil else { return }
        sleepStopAfter = nil
        if isActive { chainTopUp(token: playToken) }
    }

    var scheduledStopSentence: Int? { sleepStopAfter }

    /// The ends of the sentences already on the node, from the current one
    /// on, in seconds of wall time at the current rate. Only while audio is
    /// actually playing; [] otherwise.
    func queuedSentenceEnds() -> [SentenceEnd] {
        guard status == .playing, currentSentence >= 0, let now = playerMediaSeconds else { return [] }
        return wordTiming.clips
            .filter { $0.key >= currentSentence }
            .map { sentenceEnd($0.key, clip: $0.value, now: now) }
            .sorted { $0.sentence < $1.sentence }
    }

    func secondsUntilEnd(ofSentence sentence: Int) -> TimeInterval? {
        guard status == .playing, sentence >= currentSentence,
              let clip = wordTiming.clip(for: sentence),
              let now = playerMediaSeconds else { return nil }
        return sentenceEnd(sentence, clip: clip, now: now).secondsFromNow
    }

    private func sentenceEnd(_ sentence: Int, clip: WordKaraokeState.Clip, now: TimeInterval) -> SentenceEnd {
        SentenceEnd(sentence: sentence,
                    secondsFromNow: wordTiming.wallSeconds(from: now, to: clip.start + clip.duration, rate: rate,
                                                           gapCompression: playingCompression,
                                                           passThroughUntil: pendingSpeedBoundary(at: now)))
    }

    /// The sleep timer's landing: the sentence it aimed at has been heard,
    /// so stop at its end, cued at the next one, the audio cut silent.
    private func finishSleepStop(cueing next: Int) {
        sleepStopAfter = nil
        invalidateSchedule()
        currentSentence = next
        status = .paused
        cuePrefetch()
        record(.sleepTimer)
        cancelVolumeRamp()
        setOutputVolume(0)
    }

    // MARK: - Skip (R14)

    /// The one skip unit, 15 s, for the in-app buttons, the lock-screen skip
    /// commands and headphone next/previous alike.
    nonisolated static let skipInterval: TimeInterval = 15
    /// Back restarts the current sentence once MORE than this much of it has
    /// played.
    nonisolated static let restartThreshold: TimeInterval = 3

    /// THE skip: lands on the sentence start nearest `|seconds|` from the
    /// playhead at the current rate (back restarts the current sentence when
    /// more than 3 s of it has played), always moving at least one sentence,
    /// and keeps the play/pause state. Returns the landed sentence; nil with
    /// no book.
    @discardableResult
    func skip(seconds: TimeInterval) -> Int? {
        guard let content, !content.sentences.isEmpty else { return nil }
        let elapsed = currentSentenceElapsed
        let target = Self.skipTarget(from: max(currentSentence, 0),
                                     seconds: seconds,
                                     elapsed: elapsed,
                                     sentenceCount: content.sentences.count,
                                     wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate,
                                     words: { content.sentences[$0].wordCount })
        let restarts = seconds < 0 && elapsed > Self.restartThreshold
        guard target != currentSentence || restarts else { return currentSentence }
        seek(to: target, andPlay: false)
        return currentSentence
    }

    /// The sentence start nearest to `|seconds|` of speech at
    /// `wordsPerMinute` from the playhead, which is `elapsed` seconds into
    /// `current`. Back with more than `restartThreshold` heard is `current`'s
    /// own start. Otherwise the walk starts at `current`'s start with the
    /// heard words folded into the goal: forward `span + heard`, back
    /// `span - heard`. Forward counts the words of the sentences passed over
    /// (including `current`); back counts the words of the sentences
    /// re-entered. Zero-word sentences never end the walk; ties keep the
    /// nearer sentence; the result always moves at least one sentence.
    /// `elapsed` 0 is Phase 2's rule. Pure for unit tests.
    nonisolated static func skipTarget(from current: Int,
                                       seconds: TimeInterval,
                                       elapsed: TimeInterval = 0,
                                       sentenceCount: Int,
                                       wordsPerMinute: Double,
                                       words: (Int) -> Int) -> Int {
        guard sentenceCount > 0 else { return 0 }
        let start = min(max(current, 0), sentenceCount - 1)
        guard seconds != 0 else { return start }
        let forward = seconds > 0
        if !forward, elapsed > restartThreshold { return start }
        if forward ? start == sentenceCount - 1 : start == 0 { return start }

        let span = abs(seconds) / 60 * wordsPerMinute
        let heard = min(max(elapsed, 0) / 60 * wordsPerMinute, Double(words(start)))
        let goal = forward ? span + heard : max(span - heard, 0)

        // Lazy, so a skip in a long book never walks (or allocates) past the goal.
        let candidates = forward
            ? stride(from: start + 1, to: sentenceCount, by: 1)
            : stride(from: start - 1, to: -1, by: -1)
        var offset = 0
        var best = forward ? start + 1 : start - 1
        var bestDiff = Double.infinity
        for candidate in candidates {
            // Forward, reaching `candidate` passes over the sentence before it;
            // back, it re-enters `candidate` itself.
            offset += words(forward ? candidate - 1 : candidate)
            let diff = abs(Double(offset) - goal)
            if diff < bestDiff {
                best = candidate
                bestDiff = diff
            } else if Double(offset) > goal {
                break
            }
        }
        return best
    }

    /// Seconds of the current sentence heard: at the end, the whole last
    /// sentence (165 wpm × rate); otherwise frozen at a pause; while
    /// playing, the playhead's distance into the sentence's clip at the
    /// current rate.
    var currentSentenceElapsed: TimeInterval {
        // First: a book that ends inside a pause's ramp still holds that
        // pause's frozen time, which no longer describes the playhead.
        if status == .ended {
            guard let content, content.sentences.indices.contains(currentSentence) else { return 0 }
            return Double(content.sentences[currentSentence].wordCount)
                / (LibraryDocument.spokenWordsPerMinute * rate) * 60
        }
        if let frozenSentenceElapsed { return frozenSentenceElapsed }
        guard status == .playing,
              let now = playerMediaSeconds,
              let clip = wordTiming.clip(for: currentSentence) else { return 0 }
        return max(0, now - clip.start) * clip.compression / rate
    }

    // MARK: - Jumps and Undo jump (R15)

    /// A deliberate move: a sentence tap plays from the target in any state;
    /// a chapter, search or scrub pick keeps play or pause. A move far enough
    /// to lose one's place offers "Undo jump" (`offersUndo`); consecutive
    /// jumps with nothing heard between keep the first origin.
    func jump(to sentence: Int, origin: JumpOrigin) {
        guard let document, let content, !content.sentences.isEmpty else { return }
        let target = min(max(sentence, 0), content.sentences.count - 1)
        let from = max(currentSentence, 0)
        jumpSerial &+= 1
        if Self.offersUndo(origin: origin, from: from, to: target) {
            // "Where you stopped": the place left is a stop of its own, so
            // the furthest point reached outlives the Undo offer. Listening
            // on from the target opens a new session when it plays.
            if isListenerPlaying { endPlaceSession() }
            if let live = undoableJump, live.documentID == document.id, currentSentence == live.toSentence {
                undoableJump = UndoableJump(documentID: live.documentID,
                                            fromSentence: live.fromSentence,
                                            fromStatus: live.fromStatus,
                                            toSentence: target,
                                            serial: jumpSerial)
            } else {
                // Mid-audition the listener was paused (or finished): Undo
                // returns there, never to playback they didn't have.
                undoableJump = UndoableJump(documentID: document.id,
                                            fromSentence: from,
                                            fromStatus: listenerStatus,
                                            toSentence: target,
                                            serial: jumpSerial)
                // A new place to go back to, said once (queued, after the
                // scrub's new value); a jump that only extends the offer
                // says nothing more. The iPhone's alone (R1-39).
                if announcesUndoOffer { announce(UndoJumpCopy.available) }
            }
            restartUndoTimer()
        }
        // A pick of where the playhead already is just scrolls to it.
        if target == currentSentence, !origin.startsPlayback { return }
        seek(to: target, andPlay: origin.startsPlayback || isListenerPlaying)
    }

    /// Restores the sentence and play state the offer was made from.
    func undoJump() {
        guard let offer = undoableJump else { return }
        clearUndoableJump()
        guard offer.documentID == document?.id else { return }
        // The listener's move: an interruption's end never resumes past it
        // (the .ended path below never goes through `seek`).
        resumeAfterInterruption = false
        jumpSerial &+= 1
        switch offer.fromStatus {
        case .playing, .buffering:
            // The jump's few seconds at the target close as their own
            // session, so the one reopening at the place left continues
            // that sitting (PlaceHistory's same-place rule folds it in).
            if isListenerPlaying { endPlaceSession() }
            seek(to: offer.fromSentence, andPlay: true)
        case .ended:
            restoreEnded(at: offer.fromSentence)
        default:
            // The jump may have started playback (a sentence tap); the
            // listener was paused there, so the undo is too.
            if isActive { pause(rampsOut: false) }
            seek(to: offer.fromSentence, andPlay: false)
        }
    }

    nonisolated static func offersUndo(origin: JumpOrigin, from: Int, to: Int) -> Bool {
        from != to && (origin == .sentence ? abs(to - from) > UndoableJump.tapThreshold : true)
    }

    private func restoreEnded(at sentence: Int) {
        guard let content, !content.sentences.isEmpty else { return }
        audition = nil
        invalidateSchedule()
        currentSentence = min(max(sentence, 0), content.sentences.count - 1)
        status = .ended
        finishedCue = (currentSentence, 1.0)
        reportProgress()
    }

    private func restartUndoTimer() {
        undoTask?.cancel()
        let lifetime = max(assistiveTechRunning() ? assistiveUndoJumpLifetime : undoJumpLifetime, 0)
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.undoableJump = nil
        }
    }

    private func clearUndoableJump() {
        undoTask?.cancel()
        undoTask = nil
        undoableJump = nil
    }

    // MARK: - Resume rewind

    /// Rewind distance for a user resume after `elapsed` seconds of rest:
    /// under 5 minutes reads on from where it stopped; a longer break backs
    /// up 2 sentences, and over 30 minutes 4. Pure for the unit-test table.
    nonisolated static func resumeRewindSentences(elapsed: TimeInterval) -> Int {
        if elapsed > 30 * 60 { return 4 }
        if elapsed > 5 * 60 { return 2 }
        return 0
    }

    /// The rewound resume target, or nil when no rewind applies: only from a
    /// cued pause of the SAME document (a voice sample over it included),
    /// only while the playhead still sits where that pause left it, never
    /// when the position is within the first two sentences, always clamped
    /// to the document start.
    private func resumeRewindTarget() -> Int? {
        guard listenerStatus == .paused,
              let anchor = resumeAnchor,
              let document,
              anchor.documentID == document.id,
              currentSentence <= anchor.sentenceIndex,
              currentSentence >= 2 else { return nil }
        let rewind = Self.resumeRewindSentences(elapsed: anchor.elapsed())
        guard rewind > 0 else { return nil }
        return max(currentSentence - rewind, 0)
    }

    /// Anchors the rest that starts now — this document, this sentence, on the
    /// monotonic clock — and mirrors it to disk, so the flagship break (pause
    /// at night, iOS jettisons the app, resume in the morning) still rewinds.
    /// Suppressed mid-switch: the anchor belongs to the book that was playing.
    /// Suppressed for an audition too: the rest began at the pause before it.
    private func stampResumeAnchor() {
        guard audition == nil else { return }
        guard !isSwitchingDocument, let document, currentSentence >= 0 else { return }
        let anchor = ResumeAnchor(documentID: document.id, sentenceIndex: currentSentence)
        resumeAnchor = anchor
        anchorStore.save(anchor)
    }

    /// Drops the anchor for good — a consumed rewind, or a navigation the
    /// rewind must not second-guess. The persisted copy goes with it, so a
    /// relaunch can't resurrect a rest the user already answered. Only the
    /// loaded document's rest is ours to drop: an empty slot means the stored
    /// anchor (if any) belongs to another book, which keeps it.
    private func clearResumeAnchor() {
        guard resumeAnchor != nil else { return }
        resumeAnchor = nil
        anchorStore.clear()
    }

    /// Hands the anchor slot to a freshly loaded document. The in-memory
    /// anchor belongs to the book being left; the persisted one applies only
    /// when the SAME book is reopened (a relaunch has only its wall clock to
    /// go on). A stored anchor for another book is left where it is — that
    /// book keeps its rest until something else stops.
    private func restoreResumeAnchor(for document: LibraryDocument) {
        resumeAnchor = nil
        guard let stored = anchorStore.load(), stored.documentID == document.id else { return }
        resumeAnchor = stored
    }

    // MARK: - Playback core

    /// `keepingPlaying`: a cut-short splice whose first clip is ready
    /// (`landCutShortSplice`) restarts with the status left playing, so the
    /// busy ring never flashes for a voice switch.
    private func startPlayback(at index: Int, keepingPlaying: Bool = false) {
        guard let content, !content.sentences.isEmpty else { return }
        let target = min(max(index, 0), content.sentences.count - 1)
        // A restart while the last start still claims (a seek before its
        // first clip) carries that claim on rather than giving it back.
        let claimInFlight = pendingClaim?.task
        pendingClaim = nil
        invalidateSchedule()
        if !(keepingPlaying && status == .playing) { status = .buffering }
        if voice.engine == .kokoro, let kokoro, !kokoro.isWarm {
            setPreparingVoice(true)   // first synthesis pays the model load
        }
        currentSentence = target
        lastScheduled = target - 1
        consecutiveFailures = 0
        failedRunSkips = []
        chainTopUp(token: playToken)
        beginClaim(carrying: claimInFlight)
    }

    /// R4-33: a cold live start claims the output now, off the main actor,
    /// while `topUpSchedule` fetches or makes its first clip, so the busy
    /// ring keeps turning and the claim costs no time of its own. Only a
    /// start that will play and holds no claim (after the idle stop's
    /// release, or an interruption's lapse); never offline, and never where
    /// the platform has no claim to make off the main actor (the Mac, whose
    /// claim is a no-op). The first clip awaits it (`awaitPendingClaim`).
    private func beginClaim(carrying inFlight: Task<Void, Error>?) {
        guard let claim = claimAudioOutput, !rendersOffline,
              !holdsAudioSession || sessionClaimLapsed,
              status == .buffering || status == .playing else {
            if let inFlight {
                pendingClaim = (playToken, inFlight)
                cancelPendingClaim()
            }
            return
        }
        let task = inFlight ?? Task { @MainActor in
            // Cancelled before it ran (a pause at once): nothing claimed,
            // so the release queued by `cancelPendingClaim` ends nothing.
            try Task.checkCancellation()
            let interval = Self.audioStartSignposter.beginInterval("activate")
            defer { Self.audioStartSignposter.endInterval("activate", interval) }
            try await claim()
        }
        pendingClaim = (playToken, task)
    }

    /// The first clip's wait for its start's claim (R4-33). True to go on
    /// and schedule; false when the start moved on meanwhile (a pause, a
    /// seek, a stop) or a call held the audio, which pauses as interrupted
    /// (`audioHardwareFailed`). With no claim pending, only the token
    /// counts.
    private func awaitPendingClaim(token: UInt64) async -> Bool {
        guard !hasActiveSchedule, let pending = pendingClaim, pending.token == token else {
            return token == playToken
        }
        let result = await pending.task.result
        guard token == playToken, pendingClaim?.token == token,
              status == .buffering || status == .playing else { return false }
        pendingClaim = nil
        switch result {
        case .success:
            holdsAudioSession = true
            sessionClaimLapsed = false
            claimedToken = token
        case .failure(let error) where error is AudioOutputHeldElsewhere:
            audioHardwareFailed(error)
            return false
        case .failure:
            // As a claim in place: any other session failure alone
            // shouldn't block simulator playback. The claim still counts as
            // made (the session not held), so the engine's start uses its
            // result and never blocks the main actor on a second
            // activation that has just failed.
            claimedToken = token
        }
        return true
    }

    /// A claim its start no longer needs (a pause, a stop, a start that
    /// moved on): cancelled, and the session given back behind it on the
    /// session's queue, so a pause before the first clip never keeps Music
    /// interrupted. Never under a running engine (iOS refuses), nor for an
    /// interruption's stop (`releasing` false), whose end comes only to a
    /// session still held.
    private func cancelPendingClaim(releasing: Bool = true) {
        guard let pending = pendingClaim else { return }
        pendingClaim = nil
        pending.task.cancel()
        guard releasing, !rendersOffline, !audioEngine.isRunning else { return }
        audioOutput.deactivate(notifyingOthers: false)
        holdsAudioSession = false
    }

    /// Serializes top-up runs by chaining on the previous task, so two loops
    /// can never double-schedule a sentence.
    private func chainTopUp(token: UInt64) {
        let previous = scheduleTask
        scheduleTask = Task { [weak self] in
            _ = await previous?.value
            await self?.topUpSchedule(token: token)
        }
    }

    /// How many sentences past the playhead stay queued: the platform's
    /// listening time at `rate`, within its sentence range
    /// (`PlatformPlaybackTuning`), or a fixed `lookAhead` where it has none.
    /// `strainedCap`: the platform's smaller count at `.serious` heat or
    /// hotter (`PlatformPlaybackTuning.lookAheadUnderStrain`), nil otherwise.
    nonisolated static func lookAheadCount(characterCounts: [Int], rate: Double,
                                           seconds: TimeInterval?, range: ClosedRange<Int>,
                                           strainedCap: Int? = nil) -> Int {
        if let strainedCap {
            return min(lookAheadCount(characterCounts: characterCounts, rate: rate, seconds: seconds, range: range),
                       max(strainedCap, 1))
        }
        guard let seconds else { return lookAhead }
        let speed = max(rate, 0.1)
        var queued: TimeInterval = 0
        var count = 0
        for characters in characterCounts where count < range.upperBound {
            if queued >= seconds, count >= range.lowerBound { break }
            queued += estimatedSeconds(characters: characters) / speed
            count += 1
        }
        return min(max(count, range.lowerBound), range.upperBound)
    }

    /// The look-ahead's sentence range and cap now (R4-34). Heat keeps the
    /// platform's strained cap, which ThermalGuard's cooling handoff
    /// counts on; Low Power Mode alone keeps a time-based queue over the
    /// platform's shorter range; otherwise the platform's own range.
    nonisolated static func lookAheadBounds(hot: Bool, lowPower: Bool)
        -> (range: ClosedRange<Int>, strainedCap: Int?) {
        if hot, let cap = PlatformPlaybackTuning.lookAheadUnderStrain {
            return (PlatformPlaybackTuning.lookAheadSentences, cap)
        }
        if lowPower, !hot, let shorter = PlatformPlaybackTuning.lookAheadSentencesUnderLowPower {
            return (shorter, nil)
        }
        return (PlatformPlaybackTuning.lookAheadSentences, nil)
    }

    /// The last sentence the node should hold now.
    private func lookAheadHorizon(in content: DocContent) -> Int {
        let bounds = Self.lookAheadBounds(hot: isHot(), lowPower: isLowPower())
        let ahead = content.sentences.dropFirst(currentSentence + 1).prefix(bounds.range.upperBound)
            .map(\.text.count)
        return currentSentence + Self.lookAheadCount(characterCounts: ahead, rate: rate,
                                                     seconds: PlatformPlaybackTuning.lookAheadSeconds,
                                                     range: bounds.range, strainedCap: bounds.strainedCap)
    }

    /// The most sentences past the look-ahead `warmSkipTargets` warms: with
    /// the current sentence and an iPhone's six queued, a cache of
    /// `AudioClipCache.defaultCapacity` still holds the clips behind the
    /// playhead that Back 15 lands on.
    nonisolated static let skipWarmUpLimit = 3

    /// Forward 15 lands about 15 s past the playhead, beyond the look-ahead
    /// on prose of short sentences, where every press would synthesize
    /// cold. So once the look-ahead is full, the sentences past `horizon`
    /// it can land on before the next sentence change are warmed in the
    /// cache (`skipTarget` from the current sentence with all of it heard;
    /// the top-up runs again at each change, so this follows the
    /// playhead): at most `skipWarmUpLimit`, never past a sleep stop, an
    /// audition's sentence or the end. Never onto the node: the
    /// look-ahead's own requests go ahead of these and any `now` request
    /// drops them, so the R5 splice and R11's cooling depth stay as they
    /// are. The natural voice only (the System voice is quick), never
    /// under strain, never with a handoff pending.
    /// Known limit: a second press in a row (+30 s) still lands cold,
    /// though a long sentence there starts on a lead clause (R3-07,
    /// `scheduleColdLead`) rather than after all of it is made.
    private func warmSkipTargets(after horizon: Int, in content: DocContent) async {
        guard handoff == nil, !isUnderStrain(),
              content.sentences.indices.contains(currentSentence) else { return }
        let lastIndex = content.sentences.count - 1
        let wordsPerMinute = LibraryDocument.spokenWordsPerMinute * rate
        let wholeSentence = Double(content.sentences[currentSentence].wordCount) / wordsPerMinute * 60
        let furthest = Self.skipTarget(from: currentSentence, seconds: Self.skipInterval,
                                       elapsed: wholeSentence, sentenceCount: content.sentences.count,
                                       wordsPerMinute: wordsPerMinute,
                                       words: { content.sentences[$0].wordCount })
        let last = min(furthest, horizon + Self.skipWarmUpLimit, lastIndex,
                       audition?.stopAfter ?? lastIndex, sleepStopAfter ?? lastIndex)
        guard horizon < last else { return }
        // No handoff: every sentence is queued in the active voice.
        let warmVoice = voiceForSentence(horizon + 1)
        guard warmVoice.engine == .kokoro else { return }
        let pace = nativePace(for: warmVoice)
        var warmUps: [(text: String, key: String)] = []
        var plans: [String: ColdLeadPlan] = [:]
        for index in (horizon + 1)...last where !skippedSentences.contains(index) {
            let spoken = synthesisText(at: index, voice: warmVoice)
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = AudioClipCache.key(voice: warmVoice, skipBrackets: skipBrackets,
                                         contentHash: content.contentHash, nativeSpeed: pace, sentenceID: index)
            warmUps.append((text: spoken, key: key))
            plans[key] = backgroundPlan(forSentence: index, voice: warmVoice, pace: pace, spoken: spoken)
        }
        guard !warmUps.isEmpty else { return }
        await scheduler.prefetch(warmUps, voice: AVSpeechEngine.voice(warmVoice, reading: systemVoiceLanguage),
                                 speed: pace, replacingWarmUps: false, plans: plans)
    }

    /// Keeps the player node loaded past the playhead (`lookAheadHorizon`).
    /// The current sentence rides the `now` lane; look-ahead uses `prefetch`.
    private func topUpSchedule(token: UInt64) async {
        while token == playToken, let content {
            let lastIndex = content.sentences.count - 1
            // An audition speaks its one sentence and nothing after it; a
            // sleep stop's sentence is the last one queued.
            let horizon = min(lookAheadHorizon(in: content), lastIndex,
                              audition?.stopAfter ?? lastIndex,
                              max(sleepStopAfter ?? lastIndex, currentSentence))
            guard lastScheduled < horizon else {
                await warmSkipTargets(after: horizon, in: content)
                return
            }

            let next = lastScheduled + 1
            let clipVoice = voiceForSentence(next)
            let spoken = synthesisText(at: next, voice: clipVoice)
            let clip: SynthesizedAudio
            // C4: a clip made in pieces, scheduled piece by piece.
            var madePieces: [MadePiece]?
            if skippedSentences.contains(next)
                || spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Citation-only / aside-only sentences (spokenText == "" with
                // skip-brackets on) ride this branch: a beat of silence whose
                // completion callback advances to the next sentence.
                clip = .silence(duration: Self.skippedClipDuration, nativeSpeed: compressionForSilence)
            } else {
                let pace = nativePace(for: clipVoice)
                let key = AudioClipCache.key(voice: clipVoice, skipBrackets: skipBrackets,
                                             contentHash: content.contentHash, nativeSpeed: pace,
                                             sentenceID: next)
                let priority: SynthesisPriority = next == currentSentence ? .now : .prefetch
                #if DEBUG
                if priority == .now, cache.clip(forKey: key) != nil { TapAudioProbe.shared.notePath("hit") }
                #endif
                // R3-07: a cold start on a long sentence speaks a lead
                // clause first, the rest following it on the node.
                if priority == .now,
                   let plan = coldLeadPlan(forSentence: next, voice: clipVoice, pace: pace, key: key,
                                           spoken: spoken) {
                    switch await scheduleColdLead(plan, sentence: next, voice: clipVoice, pace: pace,
                                                  key: key, token: token) {
                    case .scheduled, .voiceChanged: continue
                    case .abandoned: return
                    case .nothingLanded: break   // made whole below, with its retries
                    }
                }
                // C4: look-ahead past the playhead, with the reader away,
                // is made in clause pieces a tap waits behind one of.
                let background = priority == .prefetch
                    ? backgroundPlan(forSentence: next, voice: clipVoice, pace: pace, spoken: spoken) : nil
                do {
                    let made = try await synthesizeWithRetry(spoken, voice: clipVoice, speed: pace, key: key,
                                                             priority: priority, token: token, plan: background)
                    guard token == playToken else { return }
                    #if DEBUG
                    if priority == .now { TapAudioProbe.shared.notePath("whole") }
                    #endif
                    if background != nil, let pieces = await scheduler.madePieces(forKey: key),
                       pieces.count > 1, pieces.reduce(0, { $0 + $1.frames }) == made.samples.count {
                        madePieces = pieces
                    }
                    guard token == playToken else { return }
                    clip = await Self.stretchedToSpeed(made, rate: rate)
                    guard token == playToken else { return }
                    // The splice was fixed while this clip was synthesizing:
                    // the old voice never reaches the node at or past it.
                    guard clipVoice == voiceForSentence(next) else { continue }
                    consecutiveFailures = 0
                    failedRunSkips = []   // the skips before it stand: the voice reads
                } catch is CancellationError {
                    return
                } catch SynthesisSchedulerError.backlogFull {
                    // Not now, never a failed sentence (F016): the prefetch
                    // lane is full of earlier work. Nothing is skipped or
                    // counted toward the fallback, and a pending handoff
                    // stands; the loop asks again after a beat, by when the
                    // lane has room or this sentence is current and rides
                    // the `now` lane, which clears it.
                    do {
                        try await Task.sleep(nanoseconds: Self.backlogRetryNanoseconds)
                    } catch {
                        return
                    }
                    continue
                } catch {
                    guard token == playToken else { return }
                    // Asked of a switch dropped while it synthesized (a
                    // removed model's clip): no failure of the voice that
                    // reads this sentence now, so it asks that voice.
                    guard clipVoice == voiceForSentence(next) else { continue }
                    // The incoming voice can't read: drop the handoff, and the
                    // current voice reads this sentence and keeps going. As
                    // any cancel: with the splice's clip in the incoming voice
                    // already on the node (this sentence lies past it), the
                    // current sentence reloads in this voice, so that clip
                    // never plays under its chip.
                    if let pending = handoff, clipVoice == pending.voice {
                        postNotice(.fellBackToSystem)
                        cancelVoiceHandoff()
                        guard token == playToken else { return }   // reloaded
                        continue
                    }
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        // Three in a row is the voice, not three bad
                        // sentences: the run's skips (look-ahead it failed
                        // on its way here) go back to being read, from the
                        // first one the listener never heard.
                        withdrawFailedRunSkips()
                        // A neural engine that fails globally degrades to the
                        // system voice instead of erroring out.
                        if voice.engine == .kokoro {
                            fallBackToSystemVoice()
                        } else {
                            failPlayback()
                        }
                        return
                    }
                    // Skip-and-continue: one bad sentence never stops the book.
                    skippedSentences.insert(next)
                    failedRunSkips.append(next)
                    postNotice(.skippedSentence)
                    scheduleSilence(forSentence: next, voice: voiceForSentence(next), token: token)
                    continue
                }
            }
            guard token == playToken else { return }
            // A cold start's claim, begun with the start, lands before the
            // first clip starts the hardware (R4-33).
            guard await awaitPendingClaim(token: token) else { return }
            guard let madePieces else {
                scheduleClip(clip, forSentence: next, voice: clipVoice, token: token)
                continue
            }
            // As a cold lead's chain (`scheduleColdLead`): one sentence on
            // the node, each piece laying out its own tokens' word timing.
            for (index, part) in Self.slices(of: clip, into: madePieces).enumerated() {
                scheduleClip(part.clip, forSentence: next, voice: clipVoice, token: token,
                             part: SentencePart(isFirst: index == 0, isLast: index == madePieces.count - 1,
                                                tokens: part.tokens))
            }
        }
    }

    /// C4: `clip` (a joined clip, stretched) cut back into the pieces it
    /// was made in, each at its share of the frames: a stretch keeps their
    /// proportions, and every cut falls in a seam's quiet. The last takes
    /// what rounding leaves.
    nonisolated static func slices(of clip: SynthesizedAudio,
                                   into pieces: [MadePiece]) -> [(clip: SynthesizedAudio, tokens: Range<Int>)] {
        let total = pieces.reduce(0) { $0 + $1.frames }
        guard total > 0, !clip.samples.isEmpty else { return [] }
        let scale = Double(clip.samples.count) / Double(total)
        var out: [(clip: SynthesizedAudio, tokens: Range<Int>)] = []
        var start = 0
        var madeSoFar = 0
        for (index, piece) in pieces.enumerated() {
            madeSoFar += piece.frames
            let end = index == pieces.count - 1
                ? clip.samples.count : min(clip.samples.count, Int((Double(madeSoFar) * scale).rounded()))
            out.append((clip: SynthesizedAudio(samples: Array(clip.samples[start..<max(start, end)]),
                                               sampleRate: clip.sampleRate, nativeSpeed: clip.nativeSpeed),
                        tokens: piece.tokens))
            start = max(start, end)
        }
        return out
    }

    /// C4: how a look-ahead sentence or warm-up past the playhead is made
    /// while the reader is away from the voice and the device under no
    /// strain: in clause pieces of about `backgroundPieceSeconds` of
    /// making (`ColdLeadPlan.background`), or nil to make it whole (the
    /// page following the voice, strain, the System voice, a sentence
    /// quick to make or said otherwise than written).
    private func backgroundPlan(forSentence index: Int, voice clipVoice: TtsVoice, pace: Double,
                                spoken: String) -> ColdLeadPlan? {
        guard !readerIsFollowing, !isUnderStrain(), clipVoice.engine == .kokoro, let content,
              content.sentences.indices.contains(index),
              let measured = kokoro?.measuredSynthesisSpeed else { return nil }
        let text = content.sentences[index].text
        guard spoken == SentenceSegmenter.spokenText(text, skipBrackets: skipBrackets) else { return nil }
        return ColdLeadPlan.background(tokens: SentenceSegmenter.tokenizeSentence(text), skipBrackets: skipBrackets,
                                       wordsPerMinute: LibraryDocument.spokenWordsPerMinute, rate: rate,
                                       nativeSpeed: pace, synthesisSpeed: measured * ColdLeadPlan.headroom,
                                       pieceSeconds: PlatformPlaybackTuning.backgroundPieceSeconds)
    }

    /// C5 (the Mac's held click): starts making sentence `index` while a
    /// click waits out the double-click interval, so the jump it ends in
    /// finds it made or being made (`SynthesisScheduler.admitLead` follows
    /// a job in flight and takes over a queued one): its cold lead plan,
    /// else the whole sentence, as a warm-up ahead of the other warm-ups
    /// no one waits on, never in the `now` lane, so a double-click never
    /// cancels the look-ahead's requests. Nothing else changes: no Undo
    /// offer, transport stamp, status or claim. The natural voice only,
    /// once its model is loaded (the System voice is quick, and a click
    /// that turns into a selection never loads a model).
    func warmJumpTarget(sentence index: Int) {
        guard let content, content.sentences.indices.contains(index), !skippedSentences.contains(index),
              let kokoro, kokoro.isWarm else { return }
        let clipVoice = voiceForSentence(index)
        guard clipVoice.engine == .kokoro else { return }
        let spoken = synthesisText(at: index, voice: clipVoice)
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pace = nativePace(for: clipVoice)
        let key = AudioClipCache.key(voice: clipVoice, skipBrackets: skipBrackets, contentHash: content.contentHash,
                                     nativeSpeed: pace, sentenceID: index)
        guard cache.clip(forKey: key) == nil else { return }
        let plan = coldLeadPlan(forSentence: index, voice: clipVoice, pace: pace, key: key, spoken: spoken)
        let readingVoice = AVSpeechEngine.voice(clipVoice, reading: systemVoiceLanguage)
        let previous = heldWarmUpKey
        heldWarmUpKey = key
        // One task: a drop of the last click's warm-up never lands after this one.
        Task { [scheduler] in
            if let previous, previous != key { await scheduler.dropWarmUp(key: previous) }
            await scheduler.prefetch(spoken, voice: readingVoice, speed: pace, key: key, plan: plan,
                                     aheadOfWarmUps: true)
        }
    }

    /// C5: the held click gave way (a second click, a selection, a key):
    /// its warm-up stops at its next piece unless someone waits on it.
    func dropJumpWarmUp() {
        guard let key = heldWarmUpKey else { return }
        heldWarmUpKey = nil
        Task { [scheduler] in await scheduler.dropWarmUp(key: key) }
    }

    /// What became of a cold lead (`scheduleColdLead`).
    private enum ColdLeadOutcome {
        /// The whole sentence is on the node, its last piece ending it.
        case scheduled
        /// The splice was fixed at it while the lead was being made.
        case voiceChanged
        /// Nothing landed (the engine failed): it is made whole instead.
        case nothingLanded
        /// A restart took the schedule over.
        case abandoned
    }

    /// R3-07: how a `now` start that misses the cache speaks sentence
    /// `index` in `clipVoice`: in pieces from a lead clause (`ColdLeadPlan`),
    /// or nil to make it whole. Whole for a voice with no measured speed
    /// (the System voice), a platform with no budget, a sentence quick
    /// enough to make whole or with no clause mark to cut at, and one said
    /// otherwise than written (a numeral heading, never long). The plan
    /// counts on `ColdLeadPlan.headroom` of the engine's measured speed.
    private func coldLeadPlan(forSentence index: Int, voice clipVoice: TtsVoice, pace: Double,
                              key: String, spoken: String) -> ColdLeadPlan? {
        guard clipVoice.engine == .kokoro, let content, content.sentences.indices.contains(index),
              let measured = kokoro?.measuredSynthesisSpeed,
              cache.clip(forKey: key) == nil else { return nil }
        let text = content.sentences[index].text
        guard spoken == SentenceSegmenter.spokenText(text, skipBrackets: skipBrackets) else { return nil }
        return ColdLeadPlan.make(tokens: SentenceSegmenter.tokenizeSentence(text), skipBrackets: skipBrackets,
                                 wordsPerMinute: LibraryDocument.spokenWordsPerMinute, rate: rate,
                                 nativeSpeed: pace, synthesisSpeed: measured * ColdLeadPlan.headroom,
                                 firstAudioBudget: PlatformPlaybackTuning.coldLeadFirstAudioBudget)
    }

    /// R3-07: sentence `index` spoken in `plan`'s pieces, each on the node
    /// as it lands (`SynthesisScheduler.synthesizeLead`), gaplessly, as one
    /// sentence (`SentencePart`): the lead starts the audio and reports the
    /// sentence scheduled, so `lastScheduled` (and with it the R5 splice,
    /// which lands after the last queued sentence) never falls between two
    /// pieces; only the last piece's completion moves `currentSentence` on;
    /// the word timing covers the whole sentence, each piece's words offset
    /// by the pieces before it, so a pause, a resume and Back 15's
    /// elapsed-in-sentence read one clip. No boundary marker between pieces,
    /// so a cut-short splice can never land inside the sentence. Every piece
    /// is stretched at the speed the lead was, so the clip plays at one
    /// compression. The joined clip is cached once all have landed. Cut
    /// short after the lead was queued (the engine failed), a beat of
    /// silence ends the sentence and the book reads on.
    private func scheduleColdLead(_ plan: ColdLeadPlan, sentence index: Int, voice clipVoice: TtsVoice,
                                  pace: Double, key: String, token: UInt64) async -> ColdLeadOutcome {
        let pieces = await scheduler.synthesizeLead(plan,
                                                    voice: AVSpeechEngine.voice(clipVoice, reading: systemVoiceLanguage),
                                                    speed: pace, key: key)
        let leadRate = rate
        var landed = 0
        do {
            for try await landing in pieces {
                guard token == playToken else { return .abandoned }
                let clip = await Self.stretchedToSpeed(landing.clip, rate: leadRate)
                guard token == playToken else { return .abandoned }
                if landed == 0 {
                    #if DEBUG
                    TapAudioProbe.shared.notePath(landing.piece.map { $0.endsAtPhrase ? "phrase" : "lead" } ?? "whole")
                    #endif
                    // A cold start's claim lands before its first clip
                    // starts the hardware (R4-33).
                    guard await awaitPendingClaim(token: token) else { return .abandoned }
                    // The splice was fixed while the lead was being made:
                    // the old voice never reaches the node at or past it.
                    guard clipVoice == voiceForSentence(index) else { return .voiceChanged }
                    consecutiveFailures = 0
                    failedRunSkips = []
                }
                scheduleClip(clip, forSentence: index, voice: clipVoice, token: token,
                             part: SentencePart(isFirst: landed == 0, isLast: landing.isLast,
                                                tokens: landing.piece?.tokens))
                landed += 1
                if landing.isLast { return .scheduled }
            }
        } catch {
            // Below: nothing landed is made whole; a lead on the node ends on silence.
        }
        guard token == playToken, !Task.isCancelled else { return .abandoned }
        guard landed > 0 else { return .nothingLanded }
        scheduleClip(.silence(duration: Self.skippedClipDuration,
                              nativeSpeed: lastScheduledCompression ?? playingCompression),
                     forSentence: index, voice: clipVoice, token: token,
                     part: SentencePart(isFirst: false, isLast: true, tokens: 0..<0))
        return .scheduled
    }

    /// A failure run ends in the stop (or the System voice): its skips were
    /// never bad sentences, so they leave `skippedSentences`, and a playhead
    /// already on one of their beats of silence goes back to the first. The
    /// run is consecutive sentences with nothing heard from its first on, so
    /// that is where the listener stopped hearing the book, and where Try
    /// again (R11) or the fallback voice reads from. Before the stop's
    /// status change, so the resume anchor and the stop share it.
    private func withdrawFailedRunSkips() {
        guard let first = failedRunSkips.first else { return }
        skippedSentences.subtract(failedRunSkips)
        failedRunSkips = []
        if currentSentence > first { currentSentence = first }
    }

    /// A sentence skipped as unreadable failed in one voice with one bracket
    /// setting: another voice, or the brackets read or skipped, reads it
    /// again from any way back to it, not only a tap on it.
    private func forgetSkips() {
        skippedSentences = []
        failedRunSkips = []
    }

    /// The text synthesis is handed for sentence `index` in `voice` (by
    /// default the voice it is queued in): the sentence as read
    /// (`SentenceSegmenter.spokenText`), with a bare numeral heading said
    /// as a number (`SpokenNumerals.bareHeading`), as a chapter where one
    /// opens. Kokoro speaks English only; the System voice gets the rule
    /// only for an English book. Speech alone: the display text, sentence
    /// ranges, word timing and clip keys never change. "" for no sentence.
    func synthesisText(at index: Int, voice: TtsVoice? = nil) -> String {
        guard let content, content.sentences.indices.contains(index) else { return "" }
        let spoken = SentenceSegmenter.spokenText(content.sentences[index].text, skipBrackets: skipBrackets)
        let reading = voice ?? voiceForSentence(index)
        guard reading.engine == .kokoro || systemVoiceLanguage == nil else { return spoken }
        return SpokenNumerals.bareHeading(spoken, opensChapter: chapterOpeners.contains(index))
    }

    /// The voice sentence `index` is queued in: the handoff's from its splice
    /// on, otherwise the active voice.
    private func voiceForSentence(_ index: Int) -> TtsVoice {
        if let pending = handoff, let splice = pending.spliceAt, index >= splice {
            return pending.voice
        }
        return voice
    }

    private func synthesizeWithRetry(_ text: String,
                                     voice: TtsVoice,
                                     speed: Double,
                                     key: String,
                                     priority: SynthesisPriority,
                                     token: UInt64,
                                     plan: ColdLeadPlan? = nil) async throws -> SynthesizedAudio {
        var lastError: Error = TtsError.emptyAudio
        // The System voice reads a book in another language in that language's voice.
        let voice = AVSpeechEngine.voice(voice, reading: systemVoiceLanguage)
        for _ in 0..<Self.synthesisAttempts {
            guard token == playToken else { throw CancellationError() }
            do {
                return try await scheduler.synthesize(text, voice: voice, speed: speed, key: key,
                                                      priority: priority, plan: plan)
            } catch is CancellationError {
                throw CancellationError()
            } catch SynthesisSchedulerError.backlogFull {
                // A refusal, not a failure: the same full lane would refuse
                // a retry at once too. The top-up asks again later.
                throw SynthesisSchedulerError.backlogFull
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func scheduleSilence(forSentence index: Int, voice: TtsVoice, token: UInt64) {
        scheduleClip(.silence(duration: Self.skippedClipDuration, nativeSpeed: compressionForSilence),
                     forSentence: index, voice: voice, token: token)
    }

    /// A beat of silence keeps the compression already playing, so it never
    /// switches the time-pitch unit by itself.
    private var compressionForSilence: Double { lastScheduledCompression ?? playingCompression }

    /// A one-frame marker ahead of every clip after a schedule's first
    /// switches the time-pitch unit as the node renders it, in the quiet
    /// between two sentences: to the clip's compression when that changes (a
    /// voice handoff, or a speed pick that changed Kokoro's pace), and to a
    /// speed picked mid-sentence, which a bypassed unit takes up only at a
    /// boundary. `.dataRendered`, never the sentence's `.dataPlayedBack` end:
    /// that comes one output latency later (a Bluetooth route's ~0.2 s), with
    /// the unit already inside the next sentence's first word. The clips
    /// already queued keep playing at the right speed. The same marker
    /// times a splice cut short (`sentence`, the clip it precedes): the
    /// mixer goes to zero on the audio thread as it renders, before the hop
    /// (`CutSpliceSilencer`), and the cut lands from there
    /// (`cutSpliceRendered`).
    private func scheduleBoundaryMarker(compression: Double, in format: AVAudioFormat,
                                        sentence: Int, token: UInt64) {
        guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1),
              let channels = marker.floatChannelData else {
            playingCompression = compression
            applyTimePitchRate()
            return
        }
        marker.frameLength = 1
        for channel in 0..<Int(format.channelCount) { channels[channel][0] = 0 }
        let silencer = cutSplice
        player.scheduleBuffer(marker, at: nil, options: [], completionCallbackType: .dataRendered) { [weak self] _ in
            let cut = silencer.markerRendered(sentence, token: token)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if cut { self.cutSpliceRendered(at: sentence, token: token) }
                guard token == self.playToken else { return }
                self.playingCompression = compression
                self.applyTimePitchRate(atBoundary: true)
            }
        }
        wordTiming.appendGap(1 / format.sampleRate)
    }

    /// `part`: the whole sentence, or one piece of a cold lead's chain
    /// (R3-07, `scheduleColdLead`). Only a sentence's first clip switches
    /// the time-pitch unit (its marker) and reports it scheduled; only its
    /// last clip's completion ends it.
    private func scheduleClip(_ clip: SynthesizedAudio, forSentence index: Int,
                              voice: TtsVoice, token: UInt64, part: SentencePart = .whole) {
        if graphFormat == nil || (!hasActiveSchedule && graphFormat?.sampleRate != clip.sampleRate) {
            connectGraph(sampleRate: clip.sampleRate)
        }
        guard let format = graphFormat,
              let buffer = Self.pcmBuffer(from: clip, in: format) else {
            lastScheduled = index   // unplayable clip: bookkeeping moves on
            // A chain's last piece still ends its sentence, on a beat of silence.
            if !part.isFirst, part.isLast, part.tokens?.isEmpty == false, graphFormat != nil {
                scheduleClip(.silence(duration: Self.skippedClipDuration,
                                      nativeSpeed: lastScheduledCompression ?? playingCompression),
                             forSentence: index, voice: voice, token: token,
                             part: SentencePart(isFirst: false, isLast: true, tokens: 0..<0))
            }
            return
        }

        let compression = clip.nativeSpeed > 0 ? clip.nativeSpeed : 1
        if part.isFirst {
            if lastScheduledCompression != nil {
                scheduleBoundaryMarker(compression: compression, in: format, sentence: index, token: token)
            } else {
                // A schedule's first clip: the node is stopped, so the unit
                // switches at once.
                playingCompression = compression
                applyTimePitchRate(atBoundary: true)
            }
            lastScheduledCompression = compression
        }

        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: completionCallbackType) { [weak self] _ in
            // A chain's earlier pieces end nothing: its last ends the sentence.
            guard part.isLast else { return }
            Task { @MainActor [weak self] in
                self?.sentenceFinished(index, token: token)
            }
        }
        if part.isFirst { onAudioScheduleEvent?(.scheduled(sentence: index, voiceID: voice.id)) }
        lastScheduled = index
        wordTimingRecordScheduled(sentence: index,
                                  frameLength: buffer.frameLength,
                                  sampleRate: format.sampleRate,
                                  compression: compression,
                                  part: part)
        setPreparingVoice(false)   // first clip through means the engine is warm

        if !hasActiveSchedule {
            // Only a live start may start the hardware: a clip landing after a
            // pause (or any non-playing state) must never make sound.
            guard status == .buffering || status == .playing else { return }
            let fadeIn = applyColdStartLevel()
            do { try startAudioHardware() } catch { audioHardwareFailed(error); return }
            player.play()
            hasActiveSchedule = true
            if status == .buffering { status = .playing }
            if let fadeIn { rampOutputVolume(to: 1, over: fadeIn) }
        } else if catchingUp != nil, status == .buffering, index >= currentSentence {
            // The sentence reading waited for is on the node: the voice
            // goes on (the node never stopped, so no fade and no restart).
            status = .playing
        }
    }

    private func sentenceFinished(_ index: Int, token: UInt64) {
        // A boundary inside a pause's 120 ms ramp still counts: the audio
        // really did reach it.
        guard token == playToken, isActive || isRampingToPause, let content else { return }
        // An engine that stopped itself (an output change, an interruption)
        // flushed its queue and called every completion at once: nobody
        // heard those clips, so the place stays where it is.
        guard audioEngine.isRunning else { return }
        // A sample handed back to the end (`returnAuditionToTheEnd`) is
        // there already: its clip ending inside the ramp is no second end
        // (no haptic, announcement or progress write), and the ramp's own
        // completion drops the schedule.
        if status == .ended { return }
        // Before the end-of-book check: an audition of the last sentence
        // returns to its own restore status.
        if let audition, index >= audition.stopAfter {
            finishAudition()
            return
        }
        // The sleep timer's landing (never the book's own end, which is the
        // stop). A pause the listener made first is theirs, not the timer's.
        if isActive, let stopAfter = sleepStopAfter,
           index >= stopAfter, index < content.sentences.count - 1 {
            finishSleepStop(cueing: index + 1)
            return
        }

        if index >= content.sentences.count - 1 {
            // R24: heard to the end, at full level. Before the status
            // changes; false inside a pause's 120 ms ramp and under the sleep
            // timer's End-of-book fade, which both stop short of it.
            let heardTheEnd = isActive && requestedOutputVolume >= 1
            // Before the status too, so the sleep timer hears the end first.
            // Not inside a pause's ramp: the listener had stopped already.
            if isActive { bookEndSerial &+= 1 }
            hasActiveSchedule = false
            status = .ended
            finishedCue = (currentSentence, 1.0)   // an audition from here can't un-finish it
            reportProgress()
            player.stop()
            // A splice fixed past the end: the old voice read every sentence
            // that was left, so the switch (and its notice) lands now that
            // it has finished, never over it.
            if handoff?.spliceAt != nil { commitHandoff() }
            // The one unattended event with a haptic, and only where it can
            // be felt and heard. Never from Undo (`restoreEnded`), a sample
            // (`finishAudition`) or a reopen (`load`).
            if heardTheEnd, isAppActive() {
                emitHaptic(.finished)
                announce(ColophonCopy.theEnd)
            }
            return
        }
        currentSentence = index + 1
        // A boundary inside a pause's ramp: the frozen time was the sentence
        // just finished; of this one, at most the ramp's tail was heard.
        if frozenSentenceElapsed != nil { frozenSentenceElapsed = 0 }
        // The frame ticker prunes only while the word tint is on.
        wordTiming.prune(before: currentSentence)
        if handoff?.outgoingThrough != nil {
            // A splice cut short lands from the render side, as the marker
            // ahead of it renders (`cutSpliceRendered`); here only when that
            // marker can no longer do it. Nothing is topped up meanwhile:
            // the queue runs past the splice, where it is dropped, and the
            // restart there queues afresh.
            if !cutSplice.isTaking(currentSentence, token: token) { _ = landCutShortSplice() }
            return
        }
        // The first clip in the incoming voice is now the one playing.
        if let splice = handoff?.spliceAt, currentSentence >= splice { commitHandoff() }
        // Synthesis fell behind: this sentence's clip isn't on the node, so
        // the voice is silent. Say so (the busy ring) rather than show it
        // reading; `scheduleClip` resumes `.playing` when the clip lands.
        if status == .playing, lastScheduled < currentSentence {
            catchingUp = budgetSignposts.begin(.catchingUp)
            status = .buffering
        }
        chainTopUp(token: token)
    }

    /// The auditioned sentence has been heard: back to the status the pick
    /// was made from, cued at the same sentence. `audition` is still set
    /// while the status changes, so the stop stamps no resume anchor.
    private func finishAudition() {
        guard let restore = audition?.restore else { return }
        invalidateSchedule()
        status = restore
        audition = nil
        // No progress write: the audition never left its sentence, so
        // `finishedCue` kept a Finished book at its stored fraction.
        cuePrefetch()
    }

    /// A splice cut short (R11's cooling switch on a deep queue), reached:
    /// the outgoing voice's clips still queued from here on are dropped, and
    /// the incoming voice reads on from this sentence, its first clip
    /// already warmed (`primeHandoff`), so the status stays playing. Inside a
    /// pause's ramp too: the node would otherwise keep those clips for the
    /// resume. The ramp ends here (pausing the node), so the next Play
    /// starts afresh from this sentence; the pause's own place moves here
    /// with it. False before the splice.
    private func landCutShortSplice() -> Bool {
        guard let pending = handoff, pending.outgoingThrough != nil,
              let splice = pending.spliceAt, currentSentence >= splice else { return false }
        commitHandoff()
        if isActive {
            startPlayback(at: currentSentence, keepingPlaying: isClipReady(at: currentSentence, in: voice))
        } else {
            invalidateSchedule()
            stampResumeAnchor()
            placeStopMovedByPauseRamp()
            cuePrefetch()
        }
        return true
    }

    /// P009: the marker ahead of a cut-short splice rendered, and the
    /// outgoing voice's clip there is rendering silent (`CutSpliceSilencer`).
    /// The cut lands now, one output latency (a Bluetooth route's ~0.2 s)
    /// before the sentence ahead of it reports itself heard: that sentence's
    /// ending plays out of the output's own buffer, and nothing of the
    /// dropped clip is heard. The level comes back once the queue is flushed
    /// (`invalidateSchedule`), or here when nothing lands.
    private func cutSpliceRendered(at sentence: Int, token: UInt64) {
        cutSplice.land(sentence, token: token)
        // Not a flush (the system stopping the engine calls every completion
        // at once) and no restart since.
        if token == playToken, audioEngine.isRunning {
            if currentSentence < sentence, isActive || isRampingToPause {
                // Rendered to its end: the sentence before ends here, and
                // its own callback finds the restart's token.
                sentenceFinished(sentence - 1, token: token)
            } else {
                // Already past the sentence before, or paused with the
                // silenced clip still on the node (the pause's ramp ended
                // first): the place moves to it, as a ramp crossing it would.
                currentSentence = max(currentSentence, sentence)
                _ = landCutShortSplice()
            }
            // The switch dropped meanwhile (a pick of the voice reading):
            // the silenced clip's opening went unheard, so it starts again.
            if cutSplice.isSilencing {
                if isActive {
                    startPlayback(at: currentSentence, keepingPlaying: isClipReady(at: currentSentence, in: voice))
                } else if status == .paused {
                    invalidateSchedule()
                }
            }
        }
        reopenCutSplice(clearing: false)
    }

    /// Lifts a cut-short splice's silence back to the requested level;
    /// `clearing` also forgets what the render side was waiting for.
    private func reopenCutSplice(clearing: Bool) {
        cutSplice.unsilence(restoring: Self.effectiveOutputVolume(requestedOutputVolume, muted: isOutputMuted),
                            clearing: clearing)
    }

    /// Whether sentence `index` plays in `voice` without waiting on
    /// synthesis: its clip cached, or a beat of silence.
    private func isClipReady(at index: Int, in voice: TtsVoice) -> Bool {
        guard let content, content.sentences.indices.contains(index) else { return false }
        if skippedSentences.contains(index) { return true }
        let spoken = synthesisText(at: index, voice: voice)
        if spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let key = AudioClipCache.key(voice: voice, skipBrackets: skipBrackets, contentHash: content.contentHash,
                                     nativeSpeed: nativePace(for: voice), sentenceID: index)
        return cache.clip(forKey: key) != nil
    }

    private func invalidateSchedule() {
        // A restart (a seek, a skip, a voice change) takes a dry spell over:
        // it ends here, given up, never carried into the new start's wait.
        budgetSignposts.end(&catchingUp, gaveUp: true)
        // A primed splice that never played: the restarted schedule (seek,
        // pause from buffering, book switch) speaks the new voice from its
        // first clip. A handoff still warming survives in the old voice.
        if handoff?.spliceAt != nil { commitHandoff() }
        // Only a pause's ramp ends here: any other (a sleep fade) carries on
        // across the restart.
        if isRampingToPause { cancelVolumeRamp() }
        // A new token: a claim for the old one is no start's now (a
        // restart carries its claim past this, `startPlayback`).
        cancelPendingClaim()
        claimedToken = nil
        playToken &+= 1
        scheduleTask?.cancel()
        hasActiveSchedule = false
        isSpeakingSample = false
        lastScheduledCompression = nil
        setPreparingVoice(false)
        frozenSentenceElapsed = nil
        player.stop()
        onAudioScheduleEvent?(.stopped)
        // A clip a cut-short splice silenced went with the queue: the level
        // comes back for whatever plays next.
        reopenCutSplice(clearing: true)
        wordTiming.reset()   // player.stop() rewound the node's sample time
    }

    private func failPlayback() {
        invalidateSchedule()
        setPreparingVoice(false)
        pendingFadeIn = nil
        status = .error
        audition = nil
        record(.playbackError)   // mid-audition too: the error is real
    }

    /// The hardware wouldn't start. A call, or an app that outranks Aloud,
    /// holding the audio (`AudioOutputHeldElsewhere`) is an interruption,
    /// not a failure: playback pauses with that reason. A session Aloud
    /// holds hears the interruption end, which resumes it when iOS says it
    /// may. One it doesn't hold (given back by the idle stop) never hears
    /// an end, so nothing is promised: the reason is said now, and Play
    /// after the call reads on. Anything else fails.
    private func audioHardwareFailed(_ error: Error) {
        guard error is AudioOutputHeldElsewhere else { return failPlayback() }
        let auditioning = audition != nil
        if isActive { pause(rampsOut: false) }
        guard !auditioning else { return }
        record(.interrupted)
        if holdsAudioSession {
            resumeAfterInterruption = true
        } else if isAppActive() {
            announceHeldBackStop()   // says the stop held back for an end
        }
    }

    // MARK: - Speed / voice / skip changes

    /// A deliberate speed pick, app-wide (R7): becomes the active rate and
    /// (via `rateSelections`) the persisted speed for every book.
    func selectRate(_ newRate: Double) {
        rate = newRate
        rateSelections.send(rate)   // post-clamp value
        // The pace tier keys Kokoro's clips (`NativeSpeed`): a cue warmed at
        // the old tier never stands in, so Play would wait on a fresh
        // synthesis. Cued with nothing on the node, warm it at this speed
        // (at the same tier its clips are cached, and nothing is made).
        // Here, not in `rate`'s didSet: a slider sets the rate every tick
        // and picks only at the drag's end. From the end, Play starts at
        // the top (as `load` warms it).
        guard !isActive, !hasActiveSchedule else { return }
        if status == .ended {
            cuePrefetch(from: 0, through: 1, voice: voice, replacingWarmUps: true)
        } else {
            cuePrefetch(moved: true)
        }
    }

    /// A deliberate voice pick, app-wide (R7), heard where it is made (R8):
    /// - playing: the current sentence restarts in the new voice;
    /// - not playing: the current sentence is spoken once in it (an
    ///   audition), then playback returns to where it was — ended stays
    ///   ended, anything else pauses; a re-tap of the same voice speaks it
    ///   once more;
    /// - no book: the sample line plays through the same graph.
    /// Only a change emits on `voiceSelections`: re-picking the selected
    /// voice writes nothing (R5). A pick of the voice speaking while a
    /// switch away from it is pending cancels the switch, and is a choice:
    /// it emits, so the stored voice is the one kept.
    func selectVoice(_ newVoice: TtsVoice) {
        let keepsAgainstASwitch = newVoice == voice && handoff != nil
        if keepsAgainstASwitch { cancelVoiceHandoff() }   // a change cancels it in `voice`'s didSet
        let changed = newVoice != voice
        if let content, !content.sentences.isEmpty {
            if !isActive, currentSentence >= 0, audition == nil {
                audition = Audition(stopAfter: currentSentence,
                                    restore: status == .ended ? .ended : .paused)
            }
            if changed {
                voice = newVoice   // didSet → applyVoiceOrSkipChange → (warm a cold Kokoro) → reloadCurrent
            } else if audition != nil, !isActive {
                reloadCurrent()    // re-tap while paused: hear it once more
            }
        } else {
            if changed { voice = newVoice }
            speakSample(in: newVoice)
        }
        if changed || keepsAgainstASwitch { voiceSelections.send(newVoice) }
    }

    /// Drops a pending switch and keeps the voice speaking: a pick of that
    /// voice, the incoming voice's model removed (a removal always wins
    /// over the install switch), or heat (R11). Only a clip in the incoming
    /// voice already on the node makes the current sentence reload in this
    /// one, so none plays under its chip. With none there yet (the splice
    /// still ahead of the queue, or past the end of the book) the sentence
    /// reading goes on: the top-up reads the splice in this voice, since
    /// `voiceForSentence` no longer names the incoming one.
    func cancelVoiceHandoff() {
        guard let pending = handoff else { return }
        handoff = nil   // first: an invalidate would commit a primed splice
        // A splice cut short has the outgoing voice's own clips past it:
        // only what was queued after them is in the incoming voice.
        guard let splice = pending.spliceAt else { return }
        let firstIncoming = pending.outgoingThrough.map { max($0 + 1, splice) } ?? splice
        if hasActiveSchedule, lastScheduled >= firstIncoming { reloadCurrent() }
    }

    /// R5 install switch (and R11's thermal fallback): moves to `newVoice`
    /// with no gap and no buffering.
    /// - Playing: the engine warms off the audio path while the current voice
    ///   keeps reading. The splice is then fixed at the first sentence not yet
    ///   handed to the player node (`lastScheduled + 1`, at most the
    ///   look-ahead + 1 ahead), never the literal next boundary: the node can't unqueue
    ///   single buffers, and a flush would make the gap R5 forbids. That
    ///   sentence is synthesized in the new voice and queued behind the old
    ///   clips; when it becomes current the voice commits quietly and the
    ///   notice is posted (`notice`, or the new voice's name). If no sentence
    ///   is left to queue, the commit waits for the book to end. Status never
    ///   changes and "Preparing voice…" never shows.
    /// - Not playing: the voice changes at once (with the notice when a book
    ///   is loaded) and the cue is warmed in it.
    /// Never emits `voiceSelections`: the stored choice didn't change, only
    /// what can now honor it. A deliberate pick before the splice cancels it.
    /// `landingWithin` (R11's cooling switch on an iPhone): with more clips
    /// queued past the playhead than this, the splice is the next boundary
    /// instead, and the clips queued past it are dropped there: reading
    /// restarts from that sentence in the new voice, already warmed.
    func switchVoiceAtSentenceBoundary(to newVoice: TtsVoice, notice: PlaybackNotice? = nil,
                                       landingWithin: Int? = nil) {
        guard newVoice != voice else { handoff = nil; return }
        if audition != nil { finishAudition() }   // back to the cue it began from; that switches quietly
        guard isActive, content != nil, currentSentence >= 0 else {
            handoff = nil
            // Paused with old clips still queued: drop them, so Play speaks
            // the voice the notice names.
            if hasActiveSchedule { invalidateSchedule() }
            setVoiceQuietly(newVoice)
            Task { await scheduler.cancelPending() }
            if content != nil {
                cuePrefetch()   // warms Kokoro inside synthesis, with no UI flag
                postNotice(notice ?? .nowReadingIn(voiceName: newVoice.name))
            }
            return
        }
        handoff = VoiceHandoff(voice: newVoice, notice: notice, spliceAt: nil, landingWithin: landingWithin)
        if newVoice.engine == .kokoro, let kokoro, !kokoro.isWarm {
            let expected = newVoice
            Task { [weak self] in
                do {
                    try await kokoro.warmUp()
                    guard let self, self.handoff?.voice == expected else { return }
                    self.primeHandoff()
                } catch {
                    guard let self, self.handoff?.voice == expected else { return }
                    self.handoff = nil
                    self.postNotice(.fellBackToSystem)
                }
            }
        } else {
            primeHandoff()
        }
    }

    /// Fixes the splice once the incoming voice can speak. With nothing
    /// audible to splice behind (the first clip still buffering, a pause from
    /// buffering, no book) the voice simply commits, and live playback
    /// restarts in it: a cold natural voice's warm-up (`prepareNeuralVoice`)
    /// leaves no top-up running to pick the new voice up, and its own reload
    /// is for a voice no longer wanted. When the old voice has
    /// already queued every sentence left, the splice falls past the end:
    /// those clips play out under the voice the chip names, and the end of
    /// the book (or a restart before it) commits the switch and its notice.
    private func primeHandoff() {
        guard var pending = handoff, pending.spliceAt == nil else { return }
        guard let content, hasActiveSchedule else {
            commitHandoff()
            // Nothing is audible yet, so a restart loses nothing.
            if isActive { startPlayback(at: max(currentSentence, 0)) } else { cuePrefetch() }
            return
        }
        var splice = min(lastScheduled + 1, content.sentences.count)
        // Too deep a queue for the switch's limit: it lands at the next
        // boundary the render hasn't reached (the main actor hears of each
        // one an output latency late), where the clips queued past it are
        // dropped; its marker silences them as it renders.
        if let limit = pending.landingWithin, splice - currentSentence > max(limit, 1),
           currentSentence + 1 < content.sentences.count,
           let next = cutSplice.arm(after: currentSentence, through: lastScheduled, token: playToken) {
            pending.outgoingThrough = lastScheduled
            splice = next
        }
        pending.spliceAt = splice
        handoff = pending
        // The outgoing voice's Forward 15 warm-ups (`warmSkipTargets`) lie
        // past the splice, so they will never play: dropped, they never
        // hold up its first clips.
        cuePrefetch(from: splice, through: splice + 1, voice: pending.voice, replacingWarmUps: true)
    }

    /// The incoming voice becomes the active one without a restart. Never
    /// emits `voiceSelections`.
    private func commitHandoff() {
        guard let pending = handoff else { return }
        handoff = nil
        forgetSkips()   // the incoming voice never failed on them
        setVoiceQuietly(pending.voice)
        if content != nil { postNotice(pending.notice ?? .nowReadingIn(voiceName: pending.voice.name)) }
    }

    /// Sets `voice` without restarting anything. It must not cancel pending
    /// synthesis: that would fail the live top-up's `.now` wait and stall the
    /// schedule.
    private func setVoiceQuietly(_ newVoice: TtsVoice) {
        isSettingVoiceQuietly = true
        voice = newVoice
        isSettingVoiceQuietly = false
        if let content {
            cache.purge(keepingPrefix: AudioClipCache.keyPrefix(
                voice: newVoice, skipBrackets: skipBrackets, contentHash: content.contentHash))
        }
    }

    /// The web app's `reloadCurrent`: purge mismatched clips, drop the queue,
    /// and re-synthesize from the current sentence keeping position and state.
    /// Switching to a cold Kokoro voice warms the engine first, surfacing
    /// "Preparing voice…", and degrades to the system voice on failure.
    private func applyVoiceOrSkipChange() {
        forgetSkips()
        if let content {
            cache.purge(keepingPrefix: AudioClipCache.keyPrefix(
                voice: voice, skipBrackets: skipBrackets, contentHash: content.contentHash))
        } else {
            cache.removeAll()
        }
        Task { await scheduler.cancelPending() }

        guard content != nil, currentSentence >= 0 else { return }
        if voice.engine == .kokoro {
            guard let kokoro else { fallBackToSystemVoice(); return }
            if !kokoro.isWarm {
                prepareNeuralVoice(kokoro)
                return
            }
        }
        reloadCurrent()
    }

    /// Restart or re-cue at the current sentence with the active voice/skip.
    /// An audition plays its sentence even from a pause.
    private func reloadCurrent() {
        guard content != nil, currentSentence >= 0 else { return }
        if isActive || audition != nil {
            startPlayback(at: currentSentence)
        } else {
            invalidateSchedule()
            cuePrefetch()
        }
    }

    /// Warms the neural engine off-main (seconds, ~800 MB) before resuming.
    /// A warm-up failure is a global engine failure → automatic system-voice
    /// fallback with a notice, never an error state.
    private func prepareNeuralVoice(_ kokoro: any WarmableTtsEngine) {
        let expected = voice
        // Buffering too: a clip in the old voice still being synthesized
        // would otherwise be scheduled after the switch.
        if isActive {
            invalidateSchedule()
            status = .buffering
        } else if hasActiveSchedule {
            // Paused with the old voice's clips still on the node (the
            // warm-up's reload would drop them anyway): a Play during the
            // warm-up is then an ordinary start in the new voice, fading in,
            // never the old voice resumed until the reload cuts it off.
            invalidateSchedule()
        }
        setPreparingVoice(true)   // after invalidate, which clears the flag
        Task { [weak self] in
            do {
                try await kokoro.warmUp()
                guard let self, self.voice == expected else {
                    self?.setPreparingVoice(false)
                    return
                }
                self.setPreparingVoice(false)
                self.reloadCurrent()
            } catch {
                guard let self, self.voice == expected else {
                    self?.setPreparingVoice(false)
                    return
                }
                self.setPreparingVoice(false)
                self.fallBackToSystemVoice()
            }
        }
    }

    /// Global neural failure: keep reading with the system default voice.
    private func fallBackToSystemVoice() {
        setPreparingVoice(false)
        postNotice(.fellBackToSystem)
        if voice != fallbackVoice {
            voice = fallbackVoice   // didSet re-runs applyVoiceOrSkipChange
        } else {
            reloadCurrent()
        }
    }

    /// Frees the ~800 MB neural engine when it won't be missed: app
    /// backgrounded while paused, or a memory warning while not playing.
    /// The next synthesis transparently re-warms.
    func releaseNeuralEngineIfIdle() {
        // A handoff to a natural voice paused mid-way keeps its warm engine
        // (no re-warm on Play). One to the System voice (heat's) needs
        // nothing more from it: every clip before its splice is queued.
        guard !isActive, handoff?.voice.engine != .kokoro else { return }
        kokoro?.release()
    }

    /// Whether the audio engine runs now. Paused, it runs on until the idle
    /// stop (`idleEngineStopDelay`). Reading it never builds the output.
    var isAudioEngineRunning: Bool { audioEngine.isRunning }

    /// The app went to the background where the platform frees memory there
    /// (`PlatformTuning.releasesNeuralOnBackground`). While the idle audio
    /// engine still runs, iOS can't suspend the app, a memory warning still
    /// reaches it, and Play comes back to a warm voice: the natural voice
    /// stays, and the idle stop frees it when the engine stops
    /// (`stopIdleEngine`). With the engine already stopped it goes now.
    func releaseNeuralEngineOnBackground() {
        guard !isAudioEngineRunning else { return }
        releaseNeuralEngineIfIdle()
    }

    /// The audio engine stopped while not playing: the idle stop, or the
    /// system stopping it first (an interruption, an output change, a
    /// media-services reset), which no idle stop follows. From then iOS may
    /// suspend a paused Aloud in the background, and a suspended app gets
    /// no memory warning to free the natural voice by, so where the
    /// platform frees memory there it goes now. Play warms it again.
    private func releaseNeuralEngineIfBackgrounded() {
        guard PlatformTuning.releasesNeuralOnBackground, !isAppActive() else { return }
        releaseNeuralEngineIfIdle()
    }

    /// Listening view hook: auditioning a natural voice may have warmed the
    /// ~800 MB neural engine before the listener settled on another voice —
    /// give it back when the active voice isn't neural. A memory warning asks
    /// the same at any status (`NeuralPrewarm`). Playback with a
    /// non-neural voice never touches Kokoro (pending
    /// neural work was cancelled on the switch), so this is safe even
    /// mid-play; the next neural synthesis transparently re-warms.
    func releaseNeuralEngineIfUnused() {
        // A pending handoff needs it too: closing the Listening view the
        // download started from must not undo the warm-up behind the splice.
        guard voice.engine != .kokoro, handoff == nil else { return }
        kokoro?.release()
    }

    /// Warms the cache for the sentence Play will start on and its successor
    /// (tap-while-paused cue): the cue, or, with a resume rewind due after a
    /// break, the sentence the rewind lands on (`resumeRewindTarget`), so a
    /// morning resume never synthesizes its first sentence cold, nor waits
    /// behind a warm-up of the cue it backs up from.
    /// `moved`: the cue left where it was, so the warm-ups still queued for
    /// there are dropped first and never hold up the new place.
    private func cuePrefetch(moved: Bool = false) {
        let first = resumeRewindTarget() ?? currentSentence
        cuePrefetch(from: first, through: first + 1, voice: voice, replacingWarmUps: moved)
    }

    /// Warms the cache for sentences `first...last` (clamped) in `voice`,
    /// in order, after dropping the queued warm-ups when `replacingWarmUps`.
    private func cuePrefetch(from first: Int, through last: Int, voice: TtsVoice,
                             replacingWarmUps: Bool = false) {
        guard let content, first >= 0 else { return }
        let skip = skipBrackets
        let upper = min(last, content.sentences.count - 1)
        guard first <= upper else { return }
        let pace = nativePace(for: voice)
        var warmUps: [(text: String, key: String)] = []
        var plans: [String: ColdLeadPlan] = [:]
        for index in first...upper where !skippedSentences.contains(index) {
            let spoken = synthesisText(at: index, voice: voice)
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = AudioClipCache.key(voice: voice, skipBrackets: skip, contentHash: content.contentHash,
                                         nativeSpeed: pace, sentenceID: index)
            warmUps.append((text: spoken, key: key))
            // C4: with the reader away, a long one in clause pieces.
            plans[key] = backgroundPlan(forSentence: index, voice: voice, pace: pace, spoken: spoken)
        }
        guard !warmUps.isEmpty || replacingWarmUps else { return }
        let readingVoice = AVSpeechEngine.voice(voice, reading: systemVoiceLanguage)
        // One call: the drop never lands between the new cue's warm-ups.
        Task { [scheduler, warmUps, plans] in
            await scheduler.prefetch(warmUps, voice: readingVoice, speed: pace, replacingWarmUps: replacingWarmUps,
                                     plans: plans)
        }
    }

    /// R8 with no book loaded: one sample line in `voice`, on the same player
    /// node as every sentence (so only one voice ever speaks, and the mute
    /// holds). Status stays `.idle`; loading a book flushes it.
    private func speakSample(in voice: TtsVoice) {
        invalidateSchedule()
        let token = playToken
        isSpeakingSample = true
        if voice.engine == .kokoro, let kokoro, !kokoro.isWarm {
            setPreparingVoice(true)
        }
        Task { [weak self] in
            guard let self else { return }
            // A line that never starts is no sample speaking; a newer one
            // (another token) keeps its own flag.
            var started = false
            defer { if !started, token == self.playToken { self.isSpeakingSample = false } }
            await self.scheduler.cancelPending()
            guard token == self.playToken, self.content == nil else { return }
            let made: SynthesizedAudio
            do {
                let pace = self.nativePace(for: voice)
                made = try await self.scheduler.synthesize(
                    Self.sampleLine, voice: voice, speed: pace,
                    key: "sample|\(voice.id)|" + NativeSpeed.keyComponent(pace), priority: .now)
            } catch {
                if token == self.playToken { self.setPreparingVoice(false) }
                return
            }
            guard token == self.playToken, self.content == nil else { return }
            let clip = await Self.stretchedToSpeed(made, rate: self.rate)
            guard token == self.playToken, self.content == nil else { return }
            self.setPreparingVoice(false)
            if self.graphFormat == nil || self.graphFormat?.sampleRate != clip.sampleRate {
                self.connectGraph(sampleRate: clip.sampleRate)
            }
            guard let format = self.graphFormat,
                  let buffer = Self.pcmBuffer(from: clip, in: format) else { return }
            self.playingCompression = clip.nativeSpeed > 0 ? clip.nativeSpeed : 1
            self.applyTimePitchRate(atBoundary: true)   // the node was stopped for it
            if !self.isRampingVolume { self.setOutputVolume(1) }   // a hard start
            do { try self.startAudioHardware() } catch { return }
            self.player.scheduleBuffer(buffer, at: nil, options: [],
                                       completionCallbackType: self.completionCallbackType) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, token == self.playToken else { return }
                    self.player.stop()
                    self.isSpeakingSample = false
                }
            }
            self.onAudioScheduleEvent?(.scheduled(sentence: -1, voiceID: voice.id))
            self.player.play()
            started = true
            // Status never changes for a sample: the idle wait starts again
            // here, so the engine never stops under the line.
            self.armIdleEngineStop()
        }
    }

    // MARK: - Audio graph and volume automation (R19/R20)

    /// The ONLY writer of the main mixer volume. Every ramp, fade, edge and
    /// restore goes through it, so a test mute can never be ramped back up.
    /// It writes through `CutSpliceSilencer`, whose own writes are a cut
    /// splice's zero and the restore of this level.
    /// Before the graph exists it only records the level: `connectGraph`
    /// writes it the moment the mixer is connected, before the engine can
    /// start, so the mute holds without building the output at launch.
    private func setOutputVolume(_ volume: Float) {
        requestedOutputVolume = volume
        if graphFormat != nil {
            // Through the cut-short splice's silencer: a ramp step never
            // lifts its silence.
            cutSplice.write(Self.effectiveOutputVolume(volume, muted: isOutputMuted))
        }
        onAudioEdge?(.volume(volume))
        #if DEBUG
        if graphFormat != nil { checkMuteTripwire() }
        #endif
    }

    /// Moves the level linearly to `target` over `duration`, by elapsed time,
    /// from wherever it is now. A newer ramp replaces this one (whose
    /// completion then gets false); the last step writes exactly `target`
    /// and completes with true.
    func rampOutputVolume(to target: Float, over duration: TimeInterval,
                          completion: (@MainActor (Bool) -> Void)? = nil) {
        cancelVolumeRamp()
        guard duration > 0 else {
            setOutputVolume(target)
            completion?(true)
            return
        }
        let from = requestedOutputVolume
        let step = UInt64(VolumeRamp.stepInterval(for: duration) * 1_000_000_000)
        let generation = rampGeneration
        let clock = ContinuousClock()
        let start = clock.now
        rampCompletion = completion
        rampTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: step)
                guard let self, self.rampGeneration == generation else { return }
                let progress = Self.seconds(start.duration(to: clock.now)) / duration
                guard progress < 1 else {
                    self.finishVolumeRamp(at: target)
                    return
                }
                self.setOutputVolume(VolumeRamp.level(from: from, to: target, progress: progress))
            }
        }
    }

    /// Stops the ramp in flight (its completion gets false). A pause's ramp
    /// pauses the node now, so a cancelled pause is still a pause.
    func cancelVolumeRamp() {
        rampGeneration &+= 1
        let wasPausing = isRampingToPause
        isRampingToPause = false
        rampTask?.cancel()
        rampTask = nil
        let completion = rampCompletion
        rampCompletion = nil
        completion?(false)
        if wasPausing { pauseNode() }
    }

    var isRampingVolume: Bool { rampTask != nil }

    private func finishVolumeRamp(at target: Float) {
        setOutputVolume(target)
        rampTask = nil
        let completion = rampCompletion
        rampCompletion = nil
        completion?(true)
    }

    private func pauseNode() {
        // Where the node will resume: a clip queued while it is paused, after
        // the queue ran dry, starts there (`schedulingPlayhead`). A node that
        // reports no playhead (already paused or stopped) keeps the last one.
        if let now = playerMediaSeconds { wordTiming.pausedPlayhead = now }
        player.pause()
        applyTimePitchRate()   // the node is still: a speed picked mid-render settles
        onAudioEdge?(.nodePaused)
    }

    private func resumeNode() {
        wordTiming.pausedPlayhead = nil   // running again: the live playhead rules
        player.play()
        onAudioEdge?(.nodeResumed)
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// The level a schedule's first clip starts at. After a user play,
    /// autoplay or seek-and-play: silent, ramping in over the returned fade.
    /// Otherwise a hard start at full level, unless a ramp (a sleep fade) is
    /// running, which carries on across the restart.
    private func applyColdStartLevel() -> TimeInterval? {
        if let fade = pendingFadeIn {
            pendingFadeIn = nil
            cancelVolumeRamp()
            setOutputVolume(0)
            return fade
        }
        if !isRampingVolume { setOutputVolume(1) }
        return nil
    }

    /// The app's one audio engine, made here alone: at init, and anew after
    /// a media-services reset.
    private nonisolated static func makeAudioEngine() -> AVAudioEngine { AVAudioEngine() }

    /// Attaches the nodes to the engine, unconnected, and listens for the
    /// engine's own output changes (S7b, posted on whichever thread noticed
    /// them). The first clip connects the graph (`connectGraph`).
    private func assembleAudioGraph() {
        audioEngine.attach(player)
        audioEngine.attach(timePitch)
        timePitch.rate = 1.0
        timePitch.overlap = NativeSpeed.timePitchOverlap
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.outputConfigurationChanged() }
        }
    }

    /// iPhone: the media server restarted, and every audio object made
    /// before it went with it, so Apple's answer is to make them anew.
    /// Playback stops with the honest reason, whose one-tap retry now works;
    /// the engine and its nodes are rebuilt, and the next Play schedules
    /// afresh from the sentence start, claiming the session on the way.
    func mediaServicesWereReset() {
        stop(because: .playbackError)
        if hasActiveSchedule { invalidateSchedule() }
        releaseNeuralEngineIfBackgrounded()   // the engine went with the server
        #if DEBUG
        renderPump?.stop()
        renderPump = nil
        #endif
        audioEngine = Self.makeAudioEngine()
        player = AVAudioPlayerNode()
        timePitch = AVAudioUnitTimePitch()
        graphFormat = nil
        holdsAudioSession = false   // the session went with the media server
        assembleAudioGraph()
    }

    private func connectGraph(sampleRate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else { return }
        #if DEBUG
        // Before anything reaches the output: offline, it never has a device.
        if rendersOffline, !audioEngine.isInManualRenderingMode { enterOfflineRendering() }
        #endif
        let (engine, player, timePitch) = (audioEngine, self.player, self.timePitch)
        withEngineHeld {
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        }
        graphFormat = format
        cutSplice.attach(audioEngine.mainMixerNode)   // the mixer every level write reaches
        // A reconnect re-asserts the requested level (never louder than the
        // mute, never a jump out of a fade).
        setOutputVolume(requestedOutputVolume)
    }

    /// Starts the engine; the level is the caller's (`applyColdStartLevel`,
    /// the warm resume's ramp). Throws `AudioOutputHeldElsewhere` when a
    /// call holds the audio.
    private func startAudioHardware() throws {
        // Offline there is no session or device to claim. A resume inside
        // the idle window keeps the session it holds and its running
        // engine: an interruption stops the engine (and lapses the claim),
        // and a media-services reset drops the hold, so either way the
        // next start claims it again. A cold start's claim that landed off
        // the main actor (R4-33) leaves nothing to activate; one still on
        // its way (a first clip that never waited for it, a skip's
        // silence) is overtaken by this claim in place.
        let claimed = claimedToken == playToken
        claimedToken = nil
        if pendingClaim?.token == playToken { pendingClaim = nil }
        if !rendersOffline, !claimed, !(holdsAudioSession && audioEngine.isRunning && !sessionClaimLapsed) {
            let claim = Self.audioStartSignposter.beginInterval("activate")
            defer { Self.audioStartSignposter.endInterval("activate", claim) }
            do {
                try audioOutput.activate()
                holdsAudioSession = true
                sessionClaimLapsed = false
            } catch let heldElsewhere as AudioOutputHeldElsewhere {
                throw heldElsewhere
            } catch {
                // Any other session failure alone shouldn't block simulator
                // playback.
            }
        }
        if !audioEngine.isRunning {
            if !rendersOffline { audioOutput.bindOutput(of: audioEngine) }
            audioEngine.prepare()
            #if DEBUG
            try willStartEngine()
            #endif
            let start = Self.audioStartSignposter.beginInterval("engineStart")
            defer { Self.audioStartSignposter.endInterval("engineStart", start) }
            try audioEngine.start()
            #if DEBUG
            if rendersOffline { startRenderPump() }
            #endif
        }
    }

    /// The session claim and the engine start inside M19's first-audio
    /// interval, apart from its budget signposts, so a trace shows what a
    /// cold start spends there.
    private static let audioStartSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davidxie.Aloud", category: "AudioStart")

    /// Runs a graph change where no offline render is in flight (on the
    /// pump's queue), or in place when nothing renders offline.
    private func withEngineHeld(_ change: () -> Void) {
        #if DEBUG
        if let renderPump {
            renderPump.exclusively(change)
            return
        }
        #endif
        change()
    }

    #if DEBUG
    /// The tripwire: a muted controller's mixer is at zero whenever the
    /// engine may run. A DEBUG build traps rather than make a sound.
    private func checkMuteTripwire() {
        precondition(!isOutputMuted || audioEngine.mainMixerNode.outputVolume.isZero,
                     "a muted controller's mixer left zero")
    }

    private struct OfflineRenderingUnavailable: Error {}

    /// The fences before every engine start: the mute tripwire, and a
    /// controller meant to render offline never falling back to a device.
    private func willStartEngine() throws {
        checkMuteTripwire()
        guard !audioEngine.isInManualRenderingMode else { return }
        if rendersOffline { throw OfflineRenderingUnavailable() }
        realtimeEngineStarts += 1
    }

    /// Takes the engine off the device, while it is stopped and before the
    /// mixer is connected. 48 kHz stereo, like a typical device: the mixer
    /// converts each voice's rate. On failure the engine stays on the device
    /// and `willStartEngine` refuses to start it.
    private func enterOfflineRendering() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return }
        try? audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    }

    private func startRenderPump() {
        let pump = renderPump ?? MutedRenderPump(engine: audioEngine)
        renderPump = pump
        pump.start()
    }
    #endif

    // MARK: - Idle engine stop (M19)

    /// (Re)starts the wait for the idle stop. Nothing while active, or
    /// where the platform keeps its engine running (`idleEngineStopDelay`).
    private func armIdleEngineStop() {
        cancelIdleEngineStop()
        guard let delay = idleEngineStopDelay, !isActive else { return }
        idleEngineStopItem = scheduleIdleEngineStop(delay) { [weak self] in
            self?.stopIdleEngine()
        }
    }

    private func cancelIdleEngineStop() {
        idleEngineStopItem?.cancel()
        idleEngineStopItem = nil
    }

    /// Nothing has played for `idleEngineStopDelay`: the engine stops and
    /// lets the output device go, and with it the idle-sleep assertion
    /// coreaudiod holds while the device runs. A paused schedule goes too,
    /// as at a route stop (the node can't be trusted to keep its buffers
    /// across a stopped engine): Play reads on from the start of the same
    /// sentence, fading in like any start, and `startAudioHardware` starts
    /// the engine again on the way, behind the same fences as every start.
    /// Offline (muted), the pump stops with it. Then, on an iPhone, the
    /// session goes (never before the engine stops, which iOS refuses), so a
    /// paused Aloud can be suspended; Play claims it again. An app Aloud
    /// interrupted is told it may resume only once listening is over (a
    /// book heard to its end at full level, the book closed), never after a
    /// pause or a sleep stop, nor under the sleep timer's End-of-book fade,
    /// which a sleeper hears. Not while an interruption may still hand the
    /// audio back: its end resumes through the same Play.
    private func stopIdleEngine() {
        idleEngineStopItem = nil
        guard !isActive else { return }
        if hasActiveSchedule {
            invalidateSchedule()   // also ends a pause's ramp, pausing the node
            cuePrefetch()
        }
        // From here iOS may suspend a paused Aloud: in the background the
        // natural voice goes now, as at the move there.
        releaseNeuralEngineIfBackgrounded()
        // A session held with no engine running (the system stopped it
        // under the pause) is given back too, so iOS can still suspend the
        // paused app (R4-33).
        let engineWasRunning = audioEngine.isRunning
        guard engineWasRunning || holdsAudioSession else { return }
        if engineWasRunning {
            let engine = audioEngine
            withEngineHeld { engine.stop() }
            #if DEBUG
            renderPump?.stop()
            #endif
        }
        if !rendersOffline, !resumeAfterInterruption {
            let listeningIsOver = status == .idle || (status == .ended && requestedOutputVolume >= 1)
            audioOutput.deactivate(notifyingOthers: listeningIsOver)
            holdsAudioSession = false
        }
    }

    /// The idle stop's clock outside tests.
    nonisolated static func afterDelayOnMain(_ delay: TimeInterval,
                                             _ fire: @escaping @MainActor @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    /// Builds a PCM buffer in the graph's format, resampling when a clip's
    /// rate differs from the established connection (keeps gapless scheduling).
    private static func pcmBuffer(from clip: SynthesizedAudio,
                                  in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !clip.samples.isEmpty,
              let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: clip.sampleRate,
                                               channels: 1,
                                               interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(clip.samples.count))
        else { return nil }

        source.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { pointer in
            source.floatChannelData![0].update(from: pointer.baseAddress!, count: clip.samples.count)
        }
        if format.sampleRate == clip.sampleRate { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let capacity = AVAudioFrameCount(
            (Double(clip.samples.count) * format.sampleRate / clip.sampleRate).rounded(.up) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        converter.convert(to: converted, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        return converted.frameLength > 0 ? converted : nil
    }

    // MARK: - Interruptions

    /// A call, Siri or another app took the audio. It stops like any
    /// unattended stop; if the audio comes back on its own (shouldResume),
    /// playback resumes and the stop clears unannounced, otherwise the
    /// reason is announced now.
    private func handleInterruption(_ event: AudioInterruption) {
        switch event {
        case .began:
            sessionClaimLapsed = true
            // Stopping nothing, this interruption may resume nothing either.
            // It stops a paused Aloud's idle engine, though, with no idle
            // stop to follow.
            guard isActive else {
                resumeAfterInterruption = false
                releaseNeuralEngineIfBackgrounded()
                return
            }
            // An interrupted audition doesn't come back as playback. Set
            // after the stop, whose pause clears the flag.
            let auditioning = audition != nil
            stop(because: .interrupted)
            resumeAfterInterruption = !auditioning
        case .ended(let shouldResume):
            // The session comes back inactive: the resume's Play claims it.
            holdsAudioSession = false
            // Auto-resume is not a user action — no `userPlayAction` bump,
            // so the reader never re-centers on interruption recovery.
            if resumeAfterInterruption && shouldResume {
                play(userInitiated: false)
            } else if isAppActive() {
                announceHeldBackStop()
            }
            resumeAfterInterruption = false
        }
    }

    // MARK: - Output changes and sleep (S7b, S11)

    /// The engine stopped itself because its output device or format
    /// changed. The monitor decides what playback does: it stops with the
    /// honest reason, or follows the new output (on an iPhone, and on a Mac
    /// switching devices, once the change has settled: `.ignore` until then).
    func outputConfigurationChanged() {
        switch audioOutput.decisionAfterConfigurationChange() {
        case .ignore:
            return
        case .stop(let reason):
            stop(because: reason)
            // Nothing queued for the old output plays into the new one: the
            // next Play schedules afresh from the sentence start.
            if hasActiveSchedule, !isActive {
                invalidateSchedule()
                cuePrefetch()
            }
            releaseNeuralEngineIfBackgrounded()   // the engine stopped itself
        case .follow:
            followNewOutput()
        }
    }

    /// Rewires the graph for the output as it is now and, when playback was
    /// active, restarts it from the current sentence's start. No notice:
    /// the listener chose the device. The restart rebinds the output
    /// (`startAudioHardware`); a pause rebinds at the next Play.
    private func followNewOutput() {
        let wasActive = isActive
        if hasActiveSchedule { invalidateSchedule() }   // stops the player
        if audioEngine.isRunning {   // it is not, after a real change
            let engine = audioEngine
            withEngineHeld { engine.stop() }
        }
        if let rate = graphFormat?.sampleRate { connectGraph(sampleRate: rate) }
        if wasActive { startPlayback(at: max(currentSentence, 0)) }
    }

    /// The machine is about to sleep, and the audio with it: an honest stop
    /// now, resumable with one Play. Nothing when not playing.
    func systemWillSleep() {
        stop(because: .macSlept)
    }

    // MARK: - Progress & notices

    private func reportProgress() {
        guard let document, let content, !content.sentences.isEmpty, currentSentence >= 0 else { return }
        var fraction = status == .ended
            ? 1.0
            : Self.positionFraction(of: currentSentence, wordsBefore: wordsBefore,
                                    sentenceCount: content.sentences.count)
        if let cue = finishedCue, cue.sentence == currentSentence { fraction = max(fraction, cue.fraction) }
        onProgress?(document.id, currentSentence, fraction)
    }

    /// The share of the book's words before `sentence`. One minus it is the
    /// share left, so the card's time left (`wordCount` times that) counts
    /// what the reader's position line does, and a run of short lines (an
    /// index, a reference list) can't skew it. By position when the book has
    /// no words to weigh.
    nonisolated static func positionFraction(of sentence: Int, wordsBefore: [Int],
                                             sentenceCount: Int) -> Double {
        guard let total = wordsBefore.last, total > 0, wordsBefore.indices.contains(sentence) else {
            return Double(sentence) / Double(max(sentenceCount, 1))
        }
        return Double(wordsBefore[sentence]) / Double(total)
    }

    /// Shows `notice` in the chapter line for `PlaybackNotice.displaySeconds`
    /// and announces it once. A newer notice replaces it and owns the clear;
    /// the same notice again only restarts the clock.
    private func postNotice(_ newNotice: PlaybackNotice) {
        if notice != newNotice {
            notice = newNotice
            announce(newNotice.spokenText)
        }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PlaybackNotice.displaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.notice == newNotice else { return }
            self.notice = nil
        }
    }

    /// A notice belongs to the book it was posted for: loading another one,
    /// or none, takes it down with its clock.
    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }
}

/// P009: the render side of a splice cut short (R11's cooling switch on an
/// iPhone's deep queue). The marker ahead of the splice's clip reports
/// itself rendered from the audio thread, one output latency before the
/// sentence ending ahead of it is heard, and the main mixer goes to zero
/// right there: the outgoing voice's clip renders silent until the main
/// actor drops it. Never the player node's own volume, which a node feeding
/// an effect (the time-pitch unit) ignores. Every main-mixer write passes
/// through `write`, so no ramp step lifts the silence meanwhile. The lock
/// guards the marks only: no mixer is written while it is held.
final class CutSpliceSilencer: @unchecked Sendable {
    private struct Mark: Equatable {
        let sentence: Int
        let token: UInt64
    }

    private let lock = NSLock()
    /// The main mixer, once the graph is connected (`attach`).
    private var mixer: AVAudioMixerNode?
    private var armed: Mark?
    /// Silenced at, the main actor not yet told.
    private var fired: Mark?
    /// The last marker rendered: the render is inside that sentence's clip.
    private var rendered: Mark?
    private var silencing = false
    private var silencedAt: Int?

    /// Arms the first sentence past `current` whose marker hasn't rendered
    /// under `token`; nil, arming nothing, past `last` (the last queued).
    func arm(after current: Int, through last: Int, token: UInt64) -> Int? {
        lock.withLock {
            let reached = rendered.flatMap { $0.token == token ? $0.sentence : nil } ?? current
            let sentence = max(current, reached) + 1
            guard sentence <= last else { return nil }
            armed = Mark(sentence: sentence, token: token)
            return sentence
        }
    }

    func disarm() {
        lock.withLock { armed = nil }
    }

    /// The main mixer of the graph just connected.
    func attach(_ mixer: AVAudioMixerNode) {
        lock.withLock { self.mixer = mixer }
    }

    /// From the audio thread: the marker ahead of `sentence`'s clip
    /// rendered. True when that is the armed splice, now silenced.
    func markerRendered(_ sentence: Int, token: UInt64) -> Bool {
        let silenced: AVAudioMixerNode?? = lock.withLock {
            let mark = Mark(sentence: sentence, token: token)
            if rendered.map({ $0.token < token || ($0.token == token && $0.sentence < sentence) }) ?? true {
                rendered = mark
            }
            guard armed == mark else { return nil }
            armed = nil
            fired = mark
            silencing = true
            silencedAt = sentence
            return .some(mixer)
        }
        guard let mixer = silenced else { return false }
        Self.set(mixer, to: 0)
        return true
    }

    /// Whether the render side lands the cut at `sentence`: armed there,
    /// or silenced there with the main actor not yet told.
    func isTaking(_ sentence: Int, token: UInt64) -> Bool {
        lock.withLock {
            let mark = Mark(sentence: sentence, token: token)
            return armed == mark || fired == mark
        }
    }

    /// The main actor has heard of the cut at `sentence`.
    func land(_ sentence: Int, token: UInt64) {
        lock.withLock {
            if fired == Mark(sentence: sentence, token: token) { fired = nil }
        }
    }

    /// Writes `level` to the mixer, or zero while silenced. A cut silencing
    /// it between the read and the write still wins.
    func write(_ level: Float) {
        let (mixer, silenced) = lock.withLock { (self.mixer, silencing) }
        Self.set(mixer, to: silenced ? 0 : level)
        if !silenced, isSilencing { Self.set(mixer, to: 0) }
    }

    /// Lifts the silence back to `level`, unless another cut silenced it
    /// since, its landing still to come; `clearing` (the queue flushed)
    /// also forgets the armed and silenced marks.
    func unsilence(restoring level: Float, clearing: Bool) {
        let lifted: AVAudioMixerNode?? = lock.withLock {
            if clearing { armed = nil; fired = nil }
            guard silencing, fired == nil else { return nil }
            silencing = false
            return .some(mixer)
        }
        guard let mixer = lifted else { return }
        Self.set(mixer, to: level)
        if isSilencing { Self.set(mixer, to: 0) }
    }

    var isSilencing: Bool { lock.withLock { silencing } }
    var lastSilencedSentence: Int? { lock.withLock { silencedAt } }

    /// The app's one write of the main mixer's level.
    private static func set(_ mixer: AVAudioMixerNode?, to level: Float) {
        mixer?.outputVolume = level
    }
}

#if DEBUG
// MARK: - Test seams (DEBUG)

extension PlaybackController {

    /// How far the engine has really rendered, in seconds, by the main
    /// mixer's clock: through the device or offline. Nil before the graph
    /// exists (reading it never builds the output).
    var renderedSeconds: TimeInterval? {
        guard graphFormat != nil, let time = audioEngine.mainMixerNode.lastRenderTime,
              time.isSampleTimeValid, time.sampleRate > 0 else { return nil }
        return Double(time.sampleTime) / time.sampleRate
    }

    /// Whether the engine runs now (M19's idle stop). Reading it never
    /// builds the output.
    var isEngineRunning: Bool { audioEngine.isRunning }

    /// P009: whether a cut-short splice holds the mixer at zero now, and the
    /// sentence whose marker last did so.
    var isSilencingCutSplice: Bool { cutSplice.isSilencing }
    var cutSpliceSilencedAt: Int? { cutSplice.lastSilencedSentence }

    /// Delivers `.AVAudioEngineConfigurationChange` for this controller's
    /// engine, as the system would after an output change.
    func postEngineConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audioEngine)
    }

    /// Stops the engine under the controller, as the system does for an
    /// interruption or an output change: the node flushes its queue and
    /// calls every completion at once. Offline, the pump stops with it.
    func stopEngineAsTheSystemWould() {
        let engine = audioEngine
        withEngineHeld { engine.stop() }
        renderPump?.stop()
    }

    /// Which engine plays now: a new one after a media-services reset.
    var engineIdentity: ObjectIdentifier { ObjectIdentifier(audioEngine) }

    /// A rendered buffer's absolute peak and how long it lasts.
    typealias PeakReport = @Sendable (_ peak: Float, _ seconds: TimeInterval) -> Void

    /// Reports every rendered buffer where the time-pitch unit feeds the
    /// main mixer (`premix`) and at the mixer's output, what the device or
    /// the offline render receives. False before the graph is connected,
    /// when there is nothing to tap.
    func installPeakTaps(premix: @escaping PeakReport, mixerOutput: @escaping PeakReport) -> Bool {
        guard graphFormat != nil else { return false }
        let (engine, timePitch) = (audioEngine, self.timePitch)
        withEngineHeld {
            timePitch.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.peakTap(premix))
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.peakTap(mixerOutput))
        }
        return true
    }

    func removePeakTaps() {
        let (engine, timePitch) = (audioEngine, self.timePitch)
        withEngineHeld {
            timePitch.removeTap(onBus: 0)
            engine.mainMixerNode.removeTap(onBus: 0)
        }
    }

    /// Built off the main actor: the block runs on the render thread.
    private nonisolated static func peakTap(_ report: @escaping PeakReport) -> AVAudioNodeTapBlock {
        { buffer, _ in report(peak(of: buffer), Double(buffer.frameLength) / buffer.format.sampleRate) }
    }

    nonisolated static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        return peak
    }
}
#endif
