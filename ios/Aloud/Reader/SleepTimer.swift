import Combine
import Foundation

/// R19: a sleep timer that respects sleep. AppModel owns the one instance,
/// so leaving the reader never disarms it.
///
/// A minute timer counts down only while the book plays, never through a
/// voice sample. Its last `fade` seconds ramp the voice to silence, and the
/// stop lands on a sentence end when one falls within `landingWindow` of the
/// deadline (`landing`, through the controller's scheduled stop). End of
/// chapter fades across the chapter's last sentence and stops after it; a
/// book without a chapter list gets End of book, where the book's own end is
/// the stop. During a fade the chip offers "+15 min". Every level change goes
/// through the controller.
@MainActor
final class SleepTimer: ObservableObject {

    /// The clock. Tests scale it down.
    struct Timing: Equatable {
        /// Seconds in one menu minute.
        var secondsPerMinute: TimeInterval = 60
        /// How long a minute timer fades before its deadline.
        var fade: TimeInterval = 15
        /// How far from the deadline a sentence end may be and still be the stop.
        var landingWindow: TimeInterval = 5
        /// The countdown's step.
        var tick: TimeInterval = 1

        static let standard = Timing()
    }

    enum Option: Hashable {
        case off
        case minutes(Int)
        case endOfChapter

        /// "Off", "15 minutes", "1 hour", and "End of chapter", or "End of
        /// book" in a book without a chapter list.
        func title(endsAtChapter: Bool) -> String {
            switch self {
            case .off: return "Off"
            case .minutes(let minutes): return ListeningEstimate.spokenPhrase(minutes: minutes)
            case .endOfChapter: return endsAtChapter ? "End of chapter" : "End of book"
            }
        }

        /// What `Key.lastOption` stores ("15", "chapter"); Off is never stored.
        var storageValue: String? {
            switch self {
            case .off: return nil
            case .minutes(let minutes): return String(minutes)
            case .endOfChapter: return "chapter"
            }
        }

        init?(storageValue: String) {
            if storageValue == "chapter" {
                self = .endOfChapter
            } else if let minutes = Int(storageValue), minutes > 0 {
                self = .minutes(minutes)
            } else {
                return nil
            }
        }
    }

    enum Key {
        static let lastOption = "aloud.sleep.lastOption.v1"
    }

    enum Copy {
        static let section = "Sleep timer"
        /// "+15 min", with its VoiceOver label "Add 15 minutes" and hint
        /// "Keeps playing for 15 more minutes": all three worded by
        /// ListeningEstimate from the minutes "+15 min" really adds (R25).
        static let extendChip = "+" + ListeningEstimate.phrase(minutes: SleepTimer.extensionMinutes)
        static let extendSpoken = "Add " + ListeningEstimate.spokenPhrase(minutes: SleepTimer.extensionMinutes)
        static let extendHint = "Keeps playing for "
            + ListeningEstimate.spokenMorePhrase(minutes: SleepTimer.extensionMinutes)
        static let chapterEnd = "Chapter end"
        static let bookEnd = "Book end"
        /// The chip's VoiceOver words at "0:00": the deadline has passed and
        /// the stop waits for the sentence to end (or for playback to
        /// resume), never "1 minute left".
        static let noTimeLeftSpoken = "No time left"
    }

    static let standardMinuteChoices = [15, 30, 45, 60]
    /// Nonisolated so `Copy`, which is not main-actor bound, can word it.
    nonisolated static let extensionMinutes = 15

    /// The menu's durations. A UI test adds 1 minute, so a whole timer fits
    /// in one test.
    let minuteChoices: [Int]

    @Published private(set) var option: Option = .off
    /// Seconds left on a minute timer (below 0 inside the landing window);
    /// 0 for every other option.
    @Published private(set) var remaining: TimeInterval = 0
    /// The voice is fading toward the stop, so the chip offers "+15 min".
    @Published private(set) var isFading = false
    /// The loaded book is text with a chapter list, so End of chapter ends a
    /// chapter rather than the book.
    @Published private(set) var endsAtChapter = false
    /// Whole minutes from the playhead to where End of chapter stops
    /// (`chapterBoundary`) at the current rate: the chapter's rest, or the
    /// book's where End of chapter ends the book. Nil with no book, or
    /// before its chapters are read. Set only when the minute changes, so
    /// the menu redraws about once a minute and the player bar never.
    @Published private(set) var untilStopMinutes: Int?

    var isArmed: Bool { option != .off }

    /// The most recent option first, then the durations, End of chapter, Off.
    var menuOptions: [Option] { Self.orderedOptions(lastUsed: lastUsed, minuteChoices: minuteChoices) }

    /// "28:14", "Chapter end" or "Book end"; empty while off.
    var chipText: String {
        switch option {
        case .off:
            return ""
        case .minutes:
            // The one countdown format: rounded up, so it never reads 0:00
            // while time is left, and 0:00 inside the landing window.
            return ListeningEstimate.countdown(seconds: remaining)
        case .endOfChapter:
            return endsAtChapter ? Copy.chapterEnd : Copy.bookEnd
        }
    }

    private let timing: Timing
    private let defaults: UserDefaults
    private var lastUsed: Option?
    private weak var playback: PlaybackController?
    private var cancellables: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?
    /// End of chapter: the armed chapter, from its first sentence to the one
    /// the stop comes after.
    private var chapter: ClosedRange<Int>?
    /// The loaded book's navigation, built once per content hash.
    private var navigation: (hash: String, value: ReaderNavigation)?
    /// The loaded book as the timer last saw it. A new id is a new load,
    /// which drops the scheduled stop even when the text (and so the hash)
    /// is the same: a deleted book added again.
    private var documentID: UUID?

    init(timing: Timing = .standard, defaults: UserDefaults = .standard) {
        self.timing = timing
        self.defaults = defaults
        minuteChoices = (UITestHooks.sleepOneMinuteOption ? [1] : []) + Self.standardMinuteChoices
        lastUsed = defaults.string(forKey: Key.lastOption).flatMap(Option.init(storageValue:))
    }

    /// Wire to the controller once (idempotent).
    func attach(to playback: PlaybackController) {
        guard self.playback !== playback else { return }
        self.playback = playback
        cancellables = []

        // Every publisher emits in willSet. Deliver on the next main-loop
        // turn, so the timer never acts from INSIDE a controller transition
        // (a synchronous pause() from within startPlayback once left clips
        // scheduled) and reads settled state: a stop records its reason
        // after its status, and a load sets the content after the document.
        playback.$document
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.documentChanged() }
            .store(in: &cancellables)

        playback.$status
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &cancellables)

        playback.$currentSentence
            .receive(on: RunLoop.main)
            .sink { [weak self] sentence in
                self?.sentenceChanged(sentence)
                self?.refreshUntilStop()
            }
            .store(in: &cancellables)

        // The time to the stop follows the speed.
        playback.$rate
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUntilStop() }
            .store(in: &cancellables)

        // R24: the controller's own word that the book played to its end.
        // Statuses can't say it: Play over a voice sample from a pause turns
        // the sample into the book with no status change, and a sample over
        // the end or Undo back to it reach `.ended` just like a real end.
        playback.$bookEndSerial
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.bookEnded() }
            .store(in: &cancellables)

        // R19: likewise the controller's word that a sleep stop was recorded.
        // A `.paused` with a sleep stop on record can't say it: a voice
        // sample over that stop hands `.paused` back with the old stop still
        // recorded, and would turn off a timer armed since.
        playback.$sleepStopSerial
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stopLanded() }
            .store(in: &cancellables)
    }

    func select(_ option: Option) {
        tearDown()
        self.option = option
        switch option {
        case .off:
            remaining = 0
        case .minutes(let minutes):
            remaining = Double(minutes) * timing.secondsPerMinute
            if playback?.status == .playing { startTicking() }
        case .endOfChapter:
            remaining = 0
            if let playback {
                armChapterEnd(at: max(playback.currentSentence, 0))
                if playback.status == .playing, playback.currentSentence == chapter?.upperBound {
                    fadeAcrossChapterEnd()
                }
            }
        }
        if let value = option.storageValue {
            lastUsed = option
            defaults.set(value, forKey: Key.lastOption)
        }
    }

    /// "+15 min" during a fade: full volume again and 15 minutes on the
    /// clock. Not a menu pick, so the most recent option is unchanged.
    func addFifteenMinutes() {
        playback?.cancelScheduledStop()
        dropFade()
        chapter = nil
        option = .minutes(Self.extensionMinutes)
        remaining = Double(Self.extensionMinutes) * timing.secondsPerMinute
        if tickTask == nil, playback?.status == .playing { startTicking() }
    }

    // MARK: - Pure rules

    /// The menu order: `lastUsed` first when it is on the menu, then the
    /// durations ascending, End of chapter, and Off last.
    nonisolated static func orderedOptions(lastUsed: Option?, minuteChoices: [Int]) -> [Option] {
        var options = minuteChoices.sorted().map(Option.minutes) + [.endOfChapter]
        if let lastUsed, let index = options.firstIndex(of: lastUsed) {
            options.insert(options.remove(at: index), at: 0)
        }
        return options + [.off]
    }

    /// The sleep menu's rows on both apps: the choices in `options`' order
    /// (most recent first) with Off never among them, and whether Off shows
    /// apart below them, which it does only while a timer is armed. With
    /// nothing set there is nothing to turn off, so no checked Off reads as
    /// a choice.
    nonisolated static func menuItems(options: [Option], isArmed: Bool) -> (choices: [Option], showsOff: Bool) {
        (options.filter { $0 != .off }, isArmed)
    }

    /// A menu item's spoken label on both apps (R2-22): its title, then the
    /// time `minutes` stands for, spelled out as the iPhone's subtitle line
    /// is. A menu cell reads only the label it is given and drops its
    /// subtitle once one is set, so the time has to be in the label itself.
    /// Nil or no minutes leave the title alone.
    nonisolated static func menuSpokenLabel(title: String, minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return title }
        return "\(title), \(ListeningEstimate.spokenPhrase(minutes: minutes))"
    }

    /// The sentence whose end is nearest the deadline, within `window` either
    /// side of it (a tie goes to the earlier end); nil when none is that close.
    nonisolated static func landing(deadline: TimeInterval, ends: [SentenceEnd],
                                    window: TimeInterval) -> Int? {
        func distance(_ end: SentenceEnd) -> TimeInterval { abs(end.secondsFromNow - deadline) }
        return ends
            .filter { distance($0) <= window }
            .min { (distance($0), $0.secondsFromNow) < (distance($1), $1.secondsFromNow) }?
            .sentence
    }

    /// The sentence End of chapter stops after: the last of the folded
    /// chapter holding `sentence` in text with a chapter list or a PDF with
    /// a chapter map (`ReaderNavigation.isChaptered`), else the
    /// book's last.
    nonisolated static func chapterBoundary(navigation: ReaderNavigation, sentenceCount: Int,
                                            at sentence: Int) -> Int {
        chapterSpan(navigation: navigation, sentenceCount: sentenceCount, at: sentence).upperBound
    }

    nonisolated private static func chapterSpan(navigation: ReaderNavigation, sentenceCount: Int,
                                                at sentence: Int) -> ClosedRange<Int> {
        let last = max(sentenceCount - 1, 0)
        guard navigation.isChaptered,
              let index = navigation.chapterIndex(containing: sentence) else { return 0...last }
        let chapter = navigation.chapters[index]
        let end = min(max(chapter.lastSentence, 0), last)
        return min(chapter.startSentence, end)...end
    }

    // MARK: - Observing the controller

    private func documentChanged() {
        guard let playback else { return }
        guard let document = playback.document, let content = playback.content else {
            // Unloaded (the book deleted or let go): its stop went with it,
            // and so do its chapter and any fade, so whatever loads next is
            // aimed afresh, the same text included.
            documentID = nil
            chapter = nil
            dropFade()
            refreshUntilStop()
            return
        }
        let isNewLoad = document.id != documentID
        documentID = document.id
        if option == .endOfChapter, isNewLoad || navigation?.hash != content.contentHash {
            // The load dropped the old book's stop: aim at this book's chapter.
            armChapterEnd(at: max(playback.currentSentence, 0))
            return
        }
        guard navigation?.hash != content.contentHash else { return }
        // Off the main actor: it is a pass over every word, made while the
        // reader opens (and builds its own).
        let hash = content.contentHash
        let kind = document.kind
        Task.detached(priority: .utility) { [weak self] in
            let built = ReaderNavigation(content: content, kind: kind)
            await self?.adopt(built, hash: hash, kind: kind)
        }
    }

    private func statusChanged(_ status: PlayerStatus) {
        guard isArmed, let playback else { return }
        switch status {
        case .playing:
            if case .minutes = option { startTicking() }
            if option == .endOfChapter, playback.currentSentence == chapter?.upperBound {
                fadeAcrossChapterEnd()
            }
        case .buffering:
            // A restart (seek, voice change): the countdown waits for the
            // audio, and a fade carries on across it.
            stopTicking()
        case .paused, .idle, .error, .ended:
            // The timer's own stop turns it off a moment later
            // (`stopLanded`), so a .paused here waits, whatever stop is on
            // record. A real end has turned the timer off already
            // (`bookEnded`), so an .ended here is a bare one, where nothing
            // played to the end: a Finished book opening there (it loads
            // .paused, then .ended), a voice sample over the end handing it
            // back, or Undo back to the end from a jump that played. An
            // armed timer waits, and ticks again on Listen again.
            stopTicking()
            guard isFading else { return }
            isFading = false
            // A minute timer re-aims its landing when audio resumes, fading
            // over what is left; End of chapter keeps its stop.
            if case .minutes = option { playback.cancelScheduledStop() }
        }
    }

    /// The book ended while the listener played it (End of book's stop, or
    /// simply the last sentence), however that playback began: nothing is
    /// left to sleep through (R24).
    private func bookEnded() {
        guard isArmed else { return }
        select(.off)
    }

    /// The controller recorded a sleep stop: the timer's landing (or its
    /// deadline's stop, which has turned it off already). Never a pause,
    /// nor a voice sample handed back over an earlier sleep stop.
    private func stopLanded() {
        guard isArmed else { return }
        select(.off)
    }

    private func sentenceChanged(_ sentence: Int) {
        guard option == .endOfChapter, let playback, sentence >= 0 else { return }
        guard let chapter, chapter.contains(sentence) else {
            // Any move out of the armed chapter (a seek, live or paused)
            // re-aims at the chapter it reached.
            dropFade()
            armChapterEnd(at: sentence)
            return
        }
        if sentence != chapter.upperBound {
            // Back from the last sentence (a tap on an earlier one): the
            // voice returns until the end comes round again.
            dropFade()
        } else if playback.status == .playing {
            fadeAcrossChapterEnd()
        }
    }

    // MARK: - Minutes

    private func startTicking() {
        tickTask?.cancel()
        let step = UInt64(timing.tick * 1_000_000_000)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: step)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        // A voice sample (R8) is not the book playing: the countdown waits
        // through it, and runs on if Play carries the sample on as the book.
        guard case .minutes = option, let playback, playback.status == .playing,
              playback.isListenerPlaying else { return }
        remaining -= timing.tick
        guard isFading || remaining <= timing.fade else { return }

        if let landing = Self.landing(deadline: remaining, ends: playback.queuedSentenceEnds(),
                                      window: timing.landingWindow),
           landing != playback.scheduledStopSentence {
            playback.scheduleStop(afterSentence: landing)
            let fallback = remaining
            fadeOut { playback.secondsUntilEnd(ofSentence: landing) ?? fallback }
        } else if !isFading {
            let duration = max(remaining, timing.tick)
            fadeOut { duration }
        }

        // No sentence end near the deadline, or the landing never came.
        if remaining <= -(timing.landingWindow + timing.tick)
            || (remaining <= 0 && playback.scheduledStopSentence == nil) {
            playback.stop(because: .sleepTimer)
            select(.off)
        }
    }

    // MARK: - End of chapter

    /// Aims at the chapter holding `sentence`: the stop comes after its last
    /// sentence, unless that is the book's last, whose own end is the stop.
    private func armChapterEnd(at sentence: Int) {
        guard let playback else { return }
        playback.cancelScheduledStop()
        guard let content = playback.content, !content.sentences.isEmpty,
              let navigation = currentNavigation() else {
            chapter = nil
            return
        }
        let span = Self.chapterSpan(navigation: navigation, sentenceCount: content.sentences.count,
                                    at: sentence)
        chapter = span
        if span.upperBound < content.sentences.count - 1 {
            playback.scheduleStop(afterSentence: span.upperBound)
        }
    }

    /// The chapter's last sentence is playing: fade across it, so the voice
    /// is silent as it ends.
    private func fadeAcrossChapterEnd() {
        guard let playback, let boundary = chapter?.upperBound,
              let content = playback.content, content.sentences.indices.contains(boundary) else { return }
        let estimate = Double(content.sentences[boundary].wordCount)
            / (LibraryDocument.spokenWordsPerMinute * playback.rate) * 60
        fadeOut { playback.secondsUntilEnd(ofSentence: boundary) ?? estimate }
    }

    private func currentNavigation() -> ReaderNavigation? {
        guard let playback, let document = playback.document, let content = playback.content else { return nil }
        if let navigation, navigation.hash == content.contentHash { return navigation.value }
        let built = ReaderNavigation(content: content, kind: document.kind)
        adopt(built, hash: content.contentHash, kind: document.kind)
        return built
    }

    private func adopt(_ built: ReaderNavigation, hash: String, kind: DocKind) {
        // A build for a book that has since been replaced is dropped.
        guard playback?.content?.contentHash == hash, navigation?.hash != hash else { return }
        navigation = (hash, built)
        endsAtChapter = built.isChaptered
        refreshUntilStop()
    }

    /// `untilStopMinutes` from the navigation already built, never building
    /// one here: this runs on every sentence.
    private func refreshUntilStop() {
        var minutes: Int?
        if let playback, let content = playback.content, !content.sentences.isEmpty,
           let navigation, navigation.hash == content.contentHash {
            let sentence = max(playback.currentSentence, 0)
            let boundary = Self.chapterBoundary(navigation: navigation.value,
                                                sentenceCount: content.sentences.count, at: sentence)
            minutes = ListeningEstimate.minutes(
                words: navigation.value.wordsRemaining(from: sentence, through: boundary),
                wordsPerMinute: LibraryDocument.spokenWordsPerMinute * playback.rate)
        }
        if minutes != untilStopMinutes { untilStopMinutes = minutes }
    }

    // MARK: - Volume

    /// Starts the fade, or re-aims the one running, to reach silence in
    /// `duration()` seconds. The timer hears of a resume a run-loop turn
    /// late, while its ramp-in is still running: that ramp then finishes
    /// first, so resuming into a fade is never silent from the start.
    private func fadeOut(over duration: @escaping @MainActor () -> TimeInterval) {
        guard let playback else { return }
        let resuming = !isFading && playback.isRampingVolume && playback.requestedOutputVolume < 1
        isFading = true
        guard resuming else {
            playback.rampOutputVolume(to: 0, over: duration())
            return
        }
        playback.rampOutputVolume(to: 1, over: AudioEdge.resumeRamp) { [weak self] finished in
            guard finished, let self, self.isFading else { return }
            self.playback?.rampOutputVolume(to: 0, over: duration())
        }
    }

    /// Ends a fade early: the voice comes back to full.
    private func dropFade() {
        guard isFading else { return }
        isFading = false
        guard let playback else { return }
        // Active, not just .playing: a seek or skip mid-fade restarts through
        // .buffering, the fade's ramp survives the restart, and the cold
        // start keeps a running ramp. Only a ramp to 1 that replaces the fade
        // brings the voice back; skipping it there left the rest silent.
        if playback.isActive {
            playback.rampOutputVolume(to: 1, over: AudioEdge.resumeRamp)
        } else {
            // Nothing playing: end the dead fade, so it can't ride into the
            // next hard start.
            playback.cancelVolumeRamp()
        }
    }

    /// Undoes whatever the current option set up before another replaces it.
    private func tearDown() {
        stopTicking()
        playback?.cancelScheduledStop()
        dropFade()
        chapter = nil
    }
}
