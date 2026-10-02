import AVFoundation
import Combine
import Foundation
import UIKit

enum PlayerStatus: String, Sendable {
    case idle, buffering, playing, paused, ended, error
}

/// A queued sentence's end, for the sleep timer's landing (R19).
struct SentenceEnd: Equatable, Sendable {
    let sentence: Int
    let secondsFromNow: TimeInterval
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
            wordTimingStatusChanged(status)   // M3 karaoke display link
            let wasActive = oldValue == .playing || oldValue == .buffering
            if !wasActive, isActive { didEnterActivePlayback() }
            if wasActive, !isActive {
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
            timePitch.rate = Float(rate)
        }
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
    var isAppActive: () -> Bool = { UIApplication.shared.applicationState == .active }

    /// How long an "Undo jump" offer stays up. Tests shorten it.
    var undoJumpLifetime: TimeInterval = UndoableJump.displaySeconds

    /// Queued, so an announcement never cuts off what VoiceOver is already
    /// saying. A muted controller (UI tests) only records it, so a test can
    /// assert what VoiceOver would have heard.
    static func postAnnouncement(_ text: String, muted: Bool) {
        #if DEBUG
        UITestAnnouncementLog.shared.record(text)
        #endif
        guard !muted else { return }
        UIAccessibility.post(notification: .announcement,
                             argument: NSAttributedString(string: text, attributes: [
                                 .accessibilitySpeechQueueAnnouncement: true,
                             ]))
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

    /// Mirrored from the word-highlight pref (AppModel). The 30 fps karaoke
    /// display link exists only to feed the reader's word tint, so it runs
    /// only while this is on — the default-off configuration pays zero
    /// per-frame cost. Word windows are still recorded at schedule time, so
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
    /// Words before each sentence of `content`, the same sums the reader's
    /// time left counts (`NavigationIndex.wordsBefore`): one entry more than
    /// there are sentences, the last the book's total. Built once per load,
    /// so each progress write is one division.
    private var wordsBefore: [Int] = []

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

    // MARK: - Dependencies & graph

    private let engine: any TtsEngine
    private let kokoro: (any WarmableTtsEngine)?
    private let fallbackVoice: TtsVoice
    private let scheduler: SynthesisScheduler
    private let cache: AudioClipCache
    private let audioSession: AudioSessionManager
    private let anchorStore: ResumeAnchorStore
    private let stopStore: PlaybackStopStore

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var graphFormat: AVAudioFormat?

    // MARK: - Scheduling state

    /// M3 word karaoke: clip windows + display link (PlaybackController+WordTiming.swift).
    let wordTiming = WordKaraokeState()

    private var playToken: UInt64 = 0
    private var scheduleTask: Task<Void, Never>?
    private var lastScheduled = -1
    private var hasActiveSchedule = false
    private var consecutiveFailures = 0
    /// Set only by an interruption that stopped playback. Every user
    /// transport and every later stop clears it, so `.ended(shouldResume:)`
    /// brings back that stop and nothing the listener paused since.
    private var resumeAfterInterruption = false
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
    private struct VoiceHandoff {
        let voice: TtsVoice
        let notice: PlaybackNotice?
        var spliceAt: Int?
    }
    private var handoff: VoiceHandoff?
    private var isSettingVoiceQuietly = false

    private static let lookAhead = 2
    private static let synthesisAttempts = 3   // 1 try + 2 retries per sentence
    private static let skippedClipDuration = 0.05

    // MARK: - Init

    init(engine: any TtsEngine,
         kokoro: (any WarmableTtsEngine)? = nil,
         defaultVoice: TtsVoice,
         scheduler: SynthesisScheduler,
         cache: AudioClipCache,
         audioSession: AudioSessionManager,
         anchorStore: ResumeAnchorStore = ResumeAnchorStore(),
         stopStore: PlaybackStopStore = PlaybackStopStore(),
         outputMuted: Bool = UITestHooks.muteAudio,
         autoplaySuppressed: Bool = UITestHooks.suppressAutoplay) {
        self.engine = engine
        self.kokoro = kokoro
        self.fallbackVoice = defaultVoice
        self.scheduler = scheduler
        self.cache = cache
        self.audioSession = audioSession
        self.anchorStore = anchorStore
        self.stopStore = stopStore
        self.isOutputMuted = outputMuted
        self.isAutoplaySuppressed = autoplaySuppressed
        self.voice = defaultVoice

        audioEngine.attach(player)
        audioEngine.attach(timePitch)
        // The level is only remembered here: connecting the graph writes it.
        // Touching mainMixerNode builds the output unit, an audio-server round
        // trip that aborted launch when it timed out.
        timePitch.rate = 1.0

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
        }
        stopped = stopStore.load()

        audioSession.onInterruption = { [weak self] event in
            self?.handleInterruption(event)
        }
        audioSession.onRouteRequiresPause = { [weak self] in
            self?.stop(because: .headphonesDisconnected)
        }
        configureWordTiming()
    }

    // MARK: - Word-timing hooks (implementation in PlaybackController+WordTiming.swift)

    /// Playhead position in 1× media seconds since the player's last stop.
    /// `playerTime` counts source frames, so the time-pitch rate is already
    /// folded in — word windows laid out at natural duration map directly.
    var playerMediaSeconds: TimeInterval? {
        guard let nodeTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: nodeTime),
              time.sampleRate > 0, time.sampleTime >= 0 else { return nil }
        return Double(time.sampleTime) / time.sampleRate
    }

    /// Where a clip handed to the node now starts if the queue has run dry
    /// (synthesis slower than speech): a running node, playing or ramping
    /// out a pause, has moved on through silence to its live playhead; a
    /// paused one resumes from where it stopped. Nil for a schedule's first
    /// clip, which starts the node at 0. A clip never starts before the end
    /// of the queue (`WordKaraokeState.appendScheduled`).
    var schedulingPlayhead: TimeInterval? {
        guard hasActiveSchedule else { return nil }
        if status == .playing || isRampingToPause { return playerMediaSeconds }
        return wordTiming.pausedPlayhead
    }

    /// Publishes `currentWord` on change only (called by the display link).
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
        audition = nil
        // An interruption's end never starts a book the listener switched to.
        resumeAfterInterruption = false
        isSwitchingDocument = true
        defer { isSwitchingDocument = false }

        invalidateSchedule()
        cache.removeAll()   // clips from the previous document can never replay
        self.document = document
        self.content = content
        wordsBefore = content.navigationIndex().wordsBefore   // before the cue's progress write
        skippedSentences = []
        consecutiveFailures = 0
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
            let cue = atEnd ? last : min(max(document.progressSentence, 0), last)
            if atEnd { finishedCue = (cue, document.progressFraction) }
            currentSentence = cue
            if atEnd { status = .ended }
        }
        restoreResumeAnchor(for: document)
        if !content.sentences.isEmpty {
            // Play from the end starts at the top (Listen again): warm that.
            if status == .ended {
                cuePrefetch(from: 0, through: 1, voice: voice)
            } else {
                cuePrefetch()
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
        if let document { discardStop(for: document.id) }
        audition = nil
        invalidateSchedule()
        document = nil
        content = nil
        wordsBefore = []
        skippedSentences = []
        sleepStopAfter = nil
        pendingFadeIn = nil
        clearUndoableJump()
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
        if status == .paused, hasActiveSchedule {
            do { try startAudioHardware() } catch { failPlayback(); return }
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

    /// A user pause (R20): `.paused` publishes at once — chrome, Now Playing
    /// rate 0, the resume anchor — while the audio ramps out over 120 ms and
    /// only then pauses the node. `rampsOut: false` cuts at once and leaves
    /// the level at 0, so the next resume ramps in. Over a voice sample of a
    /// Finished book it hands back the end instead (`returnAuditionToTheEnd`).
    func pause(rampsOut: Bool = true) {
        // A pause is the last word: no interruption's end resumes past it.
        // (`.began` sets the flag after its own stop has paused.)
        resumeAfterInterruption = false
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
                    if self.currentSentence != pausedAt { self.stampResumeAnchor() }
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
        if andPlay || playing {
            let wasActive = isActive
            audition = nil
            startPlayback(at: target)
            // An audition was already active, so `status.didSet` saw no
            // entry: this is where its stop clears and the session goes live.
            if auditioning, wasActive { didEnterActivePlayback() }
        } else {
            invalidateSchedule()
            status = .paused   // `audition` still set: a sample stamps no resume anchor
            audition = nil
            currentSentence = target
            cuePrefetch()
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
        resumeAfterInterruption = false
        guard isActive else { return }
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

    /// Announces a stop recorded while VoiceOver couldn't hear it, once, if
    /// it is still the current stop.
    func sceneDidBecomeActive() {
        guard let pending = pendingStopAnnouncement else { return }
        pendingStopAnnouncement = nil
        guard stopped?.reason == pending else { return }
        announce(pending.spokenText)
    }

    /// The process is going away in order: whatever was playing gets its
    /// rest anchored, and no closed-by-iOS reason is reported next launch.
    func applicationWillTerminate() {
        if isActive { stampResumeAnchor() }
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
        markLiveSession()
    }

    /// While audio plays, the marker says where; an audition is not a session.
    private func markLiveSession() {
        guard audition == nil, let document, currentSentence >= 0 else { return }
        stopStore.markLive(LiveSession(documentID: document.id,
                                       sentenceIndex: currentSentence,
                                       wallClock: Date()))
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
                    secondsFromNow: max(0, (clip.start + clip.duration - now) / rate))
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
        return max(0, now - clip.start) / rate
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
        let lifetime = max(undoJumpLifetime, 0)
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

    private func startPlayback(at index: Int) {
        guard let content, !content.sentences.isEmpty else { return }
        let target = min(max(index, 0), content.sentences.count - 1)
        invalidateSchedule()
        status = .buffering
        if voice.engine == .kokoro, let kokoro, !kokoro.isWarm {
            isPreparingVoice = true   // first synthesis pays the model load
        }
        currentSentence = target
        lastScheduled = target - 1
        consecutiveFailures = 0
        chainTopUp(token: playToken)
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

    /// Keeps the player node loaded `lookAhead` sentences past the playhead.
    /// The current sentence rides the `now` lane; look-ahead uses `prefetch`.
    private func topUpSchedule(token: UInt64) async {
        while token == playToken, let content {
            let lastIndex = content.sentences.count - 1
            // An audition speaks its one sentence and nothing after it; a
            // sleep stop's sentence is the last one queued.
            let horizon = min(currentSentence + Self.lookAhead, lastIndex,
                              audition?.stopAfter ?? lastIndex,
                              max(sleepStopAfter ?? lastIndex, currentSentence))
            guard lastScheduled < horizon else { return }

            let next = lastScheduled + 1
            let clipVoice = voiceForSentence(next)
            let spoken = SentenceSegmenter.spokenText(content.sentences[next].text,
                                                     skipBrackets: skipBrackets)
            let clip: SynthesizedAudio
            if skippedSentences.contains(next)
                || spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Citation-only / aside-only sentences (spokenText == "" with
                // skip-brackets on) ride this branch: a beat of silence whose
                // completion callback advances to the next sentence.
                clip = .silence(duration: Self.skippedClipDuration)
            } else {
                let key = AudioClipCache.key(voice: clipVoice, skipBrackets: skipBrackets,
                                             contentHash: content.contentHash, sentenceID: next)
                let priority: SynthesisPriority = next == currentSentence ? .now : .prefetch
                do {
                    clip = try await synthesizeWithRetry(spoken, voice: clipVoice, key: key,
                                                         priority: priority, token: token)
                    guard token == playToken else { return }
                    // The splice was fixed while this clip was synthesizing:
                    // the old voice never reaches the node at or past it.
                    guard clipVoice == voiceForSentence(next) else { continue }
                    consecutiveFailures = 0
                } catch is CancellationError {
                    return
                } catch {
                    guard token == playToken else { return }
                    // The incoming voice can't read: drop the handoff, and the
                    // current voice reads this sentence and keeps going.
                    if let pending = handoff, clipVoice == pending.voice {
                        handoff = nil
                        postNotice(.fellBackToSystem)
                        continue
                    }
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
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
                    postNotice(.skippedSentence)
                    scheduleSilence(forSentence: next, voice: voiceForSentence(next), token: token)
                    continue
                }
            }
            guard token == playToken else { return }
            scheduleClip(clip, forSentence: next, voice: clipVoice, token: token)
        }
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
                                     key: String,
                                     priority: SynthesisPriority,
                                     token: UInt64) async throws -> SynthesizedAudio {
        var lastError: Error = TtsError.emptyAudio
        for _ in 0..<Self.synthesisAttempts {
            guard token == playToken else { throw CancellationError() }
            do {
                return try await scheduler.synthesize(text, voice: voice, key: key, priority: priority)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func scheduleSilence(forSentence index: Int, voice: TtsVoice, token: UInt64) {
        scheduleClip(.silence(duration: Self.skippedClipDuration), forSentence: index,
                     voice: voice, token: token)
    }

    private func scheduleClip(_ clip: SynthesizedAudio, forSentence index: Int,
                              voice: TtsVoice, token: UInt64) {
        if graphFormat == nil || (!hasActiveSchedule && graphFormat?.sampleRate != clip.sampleRate) {
            connectGraph(sampleRate: clip.sampleRate)
        }
        guard let format = graphFormat,
              let buffer = Self.pcmBuffer(from: clip, in: format) else {
            lastScheduled = index   // unplayable clip: bookkeeping moves on
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sentenceFinished(index, token: token)
            }
        }
        onAudioScheduleEvent?(.scheduled(sentence: index, voiceID: voice.id))
        lastScheduled = index
        wordTimingRecordScheduled(sentence: index,
                                  frameLength: buffer.frameLength,
                                  sampleRate: format.sampleRate)
        isPreparingVoice = false   // first clip through means the engine is warm

        if !hasActiveSchedule {
            // Only a live start may start the hardware: a clip landing after a
            // pause (or any non-playing state) must never make sound.
            guard status == .buffering || status == .playing else { return }
            let fadeIn = applyColdStartLevel()
            do { try startAudioHardware() } catch { failPlayback(); return }
            player.play()
            hasActiveSchedule = true
            if status == .buffering { status = .playing }
            if let fadeIn { rampOutputVolume(to: 1, over: fadeIn) }
        }
    }

    private func sentenceFinished(_ index: Int, token: UInt64) {
        // A boundary inside a pause's 120 ms ramp still counts: the audio
        // really did reach it.
        guard token == playToken, isActive || isRampingToPause, let content else { return }
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
        // The display link prunes only while the word tint is on.
        wordTiming.prune(before: currentSentence)
        // The first clip in the incoming voice is now the one playing.
        if let splice = handoff?.spliceAt, currentSentence >= splice { commitHandoff() }
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

    private func invalidateSchedule() {
        // A primed splice that never played: the restarted schedule (seek,
        // pause from buffering, book switch) speaks the new voice from its
        // first clip. A handoff still warming survives in the old voice.
        if handoff?.spliceAt != nil { commitHandoff() }
        // Only a pause's ramp ends here: any other (a sleep fade) carries on
        // across the restart.
        if isRampingToPause { cancelVolumeRamp() }
        playToken &+= 1
        scheduleTask?.cancel()
        hasActiveSchedule = false
        isPreparingVoice = false
        frozenSentenceElapsed = nil
        player.stop()
        onAudioScheduleEvent?(.stopped)
        wordTiming.reset()   // player.stop() rewound the node's sample time
    }

    private func failPlayback() {
        invalidateSchedule()
        isPreparingVoice = false
        pendingFadeIn = nil
        status = .error
        audition = nil
        record(.playbackError)   // mid-audition too: the error is real
    }

    // MARK: - Speed / voice / skip changes

    /// A deliberate speed pick, app-wide (R7): becomes the active rate and
    /// (via `rateSelections`) the persisted speed for every book.
    func selectRate(_ newRate: Double) {
        rate = newRate
        rateSelections.send(rate)   // post-clamp value
    }

    /// A deliberate voice pick, app-wide (R7), heard where it is made (R8):
    /// - playing: the current sentence restarts in the new voice;
    /// - not playing: the current sentence is spoken once in it (an
    ///   audition), then playback returns to where it was — ended stays
    ///   ended, anything else pauses; a re-tap of the same voice speaks it
    ///   once more;
    /// - no book: the sample line plays through the same graph.
    /// Only a change emits on `voiceSelections`: re-picking the selected
    /// voice writes nothing (R5).
    func selectVoice(_ newVoice: TtsVoice) {
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
        if changed { voiceSelections.send(newVoice) }
    }

    /// R5 install switch (and R11's thermal fallback): moves to `newVoice`
    /// with no gap and no buffering.
    /// - Playing: the engine warms off the audio path while the current voice
    ///   keeps reading. The splice is then fixed at the first sentence not yet
    ///   handed to the player node (`lastScheduled + 1`, at most `lookAhead`
    ///   + 1 ahead), never the literal next boundary: the node can't unqueue
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
    func switchVoiceAtSentenceBoundary(to newVoice: TtsVoice, notice: PlaybackNotice? = nil) {
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
        handoff = VoiceHandoff(voice: newVoice, notice: notice, spliceAt: nil)
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
        let splice = min(lastScheduled + 1, content.sentences.count)
        pending.spliceAt = splice
        handoff = pending
        cuePrefetch(from: splice, through: splice + 1, voice: pending.voice)
    }

    /// The incoming voice becomes the active one without a restart. Never
    /// emits `voiceSelections`.
    private func commitHandoff() {
        guard let pending = handoff else { return }
        handoff = nil
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
        isPreparingVoice = true   // after invalidate, which clears the flag
        Task { [weak self] in
            do {
                try await kokoro.warmUp()
                guard let self, self.voice == expected else {
                    self?.isPreparingVoice = false
                    return
                }
                self.isPreparingVoice = false
                self.reloadCurrent()
            } catch {
                guard let self, self.voice == expected else {
                    self?.isPreparingVoice = false
                    return
                }
                self.isPreparingVoice = false
                self.fallBackToSystemVoice()
            }
        }
    }

    /// Global neural failure: keep reading with the system default voice.
    private func fallBackToSystemVoice() {
        isPreparingVoice = false
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

    /// Listening view hook: auditioning a natural voice may have warmed the
    /// ~800 MB neural engine before the listener settled on another voice —
    /// give it back when the active voice isn't neural. Playback with a
    /// non-neural voice never touches Kokoro (pending
    /// neural work was cancelled on the switch), so this is safe even
    /// mid-play; the next neural synthesis transparently re-warms.
    func releaseNeuralEngineIfUnused() {
        // A pending handoff needs it too: closing the Listening view the
        // download started from must not undo the warm-up behind the splice.
        guard voice.engine != .kokoro, handoff == nil else { return }
        kokoro?.release()
    }

    /// Warms the cache for the cued sentence and its successor (tap-while-paused cue).
    private func cuePrefetch() {
        cuePrefetch(from: currentSentence, through: currentSentence + 1, voice: voice)
    }

    /// Warms the cache for sentences `first...last` (clamped) in `voice`.
    private func cuePrefetch(from first: Int, through last: Int, voice: TtsVoice) {
        guard let content, first >= 0 else { return }
        let skip = skipBrackets
        let upper = min(last, content.sentences.count - 1)
        guard first <= upper else { return }
        for index in first...upper where !skippedSentences.contains(index) {
            let spoken = SentenceSegmenter.spokenText(content.sentences[index].text, skipBrackets: skip)
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = AudioClipCache.key(voice: voice, skipBrackets: skip,
                                         contentHash: content.contentHash, sentenceID: index)
            Task { await scheduler.prefetch(spoken, voice: voice, key: key) }
        }
    }

    /// R8 with no book loaded: one sample line in `voice`, on the same player
    /// node as every sentence (so only one voice ever speaks, and the mute
    /// holds). Status stays `.idle`; loading a book flushes it.
    private func speakSample(in voice: TtsVoice) {
        invalidateSchedule()
        let token = playToken
        if voice.engine == .kokoro, let kokoro, !kokoro.isWarm {
            isPreparingVoice = true
        }
        Task { [weak self] in
            guard let self else { return }
            await self.scheduler.cancelPending()
            guard token == self.playToken, self.content == nil else { return }
            let clip: SynthesizedAudio
            do {
                clip = try await self.scheduler.synthesize(Self.sampleLine, voice: voice,
                                                           key: "sample|\(voice.id)", priority: .now)
            } catch {
                if token == self.playToken { self.isPreparingVoice = false }
                return
            }
            guard token == self.playToken, self.content == nil else { return }
            self.isPreparingVoice = false
            if self.graphFormat == nil || self.graphFormat?.sampleRate != clip.sampleRate {
                self.connectGraph(sampleRate: clip.sampleRate)
            }
            guard let format = self.graphFormat,
                  let buffer = Self.pcmBuffer(from: clip, in: format) else { return }
            if !self.isRampingVolume { self.setOutputVolume(1) }   // a hard start
            do { try self.startAudioHardware() } catch { return }
            self.player.scheduleBuffer(buffer, at: nil, options: [],
                                       completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, token == self.playToken else { return }
                    self.player.stop()
                }
            }
            self.onAudioScheduleEvent?(.scheduled(sentence: -1, voiceID: voice.id))
            self.player.play()
        }
    }

    // MARK: - Audio graph and volume automation (R19/R20)

    /// The ONLY writer of the main mixer volume. Every ramp, fade, edge and
    /// restore goes through it, so a test mute can never be ramped back up.
    /// Before the graph exists it only records the level: `connectGraph`
    /// writes it the moment the mixer is connected, before the engine can
    /// start, so the mute holds without building the output at launch.
    private func setOutputVolume(_ volume: Float) {
        requestedOutputVolume = volume
        if graphFormat != nil {
            audioEngine.mainMixerNode.outputVolume = Self.effectiveOutputVolume(volume, muted: isOutputMuted)
        }
        onAudioEdge?(.volume(volume))
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

    private func connectGraph(sampleRate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else { return }
        audioEngine.connect(player, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
        graphFormat = format
        // A reconnect re-asserts the requested level (never louder than the
        // mute, never a jump out of a fade).
        setOutputVolume(requestedOutputVolume)
    }

    /// Starts the engine; the level is the caller's (`applyColdStartLevel`,
    /// the warm resume's ramp).
    private func startAudioHardware() throws {
        try? audioSession.activate()   // session failure alone shouldn't block simulator playback
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
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
    private func handleInterruption(_ event: AudioSessionManager.Interruption) {
        switch event {
        case .began:
            // Stopping nothing, this interruption may resume nothing either.
            guard isActive else { resumeAfterInterruption = false; return }
            // An interrupted audition doesn't come back as playback. Set
            // after the stop, whose pause clears the flag.
            let auditioning = audition != nil
            stop(because: .interrupted)
            resumeAfterInterruption = !auditioning
        case .ended(let shouldResume):
            // Auto-resume is not a user action — no `userPlayAction` bump,
            // so the reader never re-centers on interruption recovery.
            if resumeAfterInterruption && shouldResume {
                play(userInitiated: false)
            } else if isAppActive() {
                sceneDidBecomeActive()
            }
            resumeAfterInterruption = false
        }
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
}
