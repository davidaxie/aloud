import Foundation

/// How far ahead of the voice each platform synthesizes.
enum PlatformPlaybackTuning {
    #if os(iOS)
    /// About this much listening, at the current speed, queued past the
    /// playhead. A fixed two sentences ran dry at speed: two short lines of
    /// dialogue are about a second of listening at 2.5x, less than one
    /// synthesis, and the voice went silent mid-paragraph.
    static let lookAheadSeconds: TimeInterval? = 10
    /// Never fewer than 2 sentences, nor more than 6 (the Mac's 10 would
    /// be too deep here): the R5 install handoff splices after the last
    /// queued sentence and R11's cooling switch lands within a few, so a
    /// deeper queue would delay both.
    static let lookAheadSentences = 2...6
    /// Under Low Power Mode or at `.serious` heat the queue keeps two
    /// sentences, as it always did: synthesis ahead is the heaviest work
    /// the phone does, and a hot one is about to hand off to the System
    /// voice anyway.
    static let lookAheadUnderStrain: Int? = 2
    /// R11: the cooling switch to the System voice lands within this many
    /// sentences. With more natural-voice clips queued than that, the ones
    /// past the next sentence boundary are dropped there
    /// (`PlaybackController.switchVoiceAtSentenceBoundary`).
    static let coolingSwitchLandsWithin: Int? = 3
    /// R3-07: a cold start (a jump or seek that misses the cache) whose
    /// sentence would take longer than this to make whole starts on a
    /// lead clause instead (`ColdLeadPlan`); nil makes every sentence whole.
    static let coldLeadFirstAudioBudget: TimeInterval? = 1.0
    #elseif os(macOS)
    /// About this much listening, at the current speed, queued past the
    /// playhead. Two sentences ran dry at 2.95x: two short lines of
    /// dialogue are about a second of listening, less than one synthesis.
    static let lookAheadSeconds: TimeInterval? = 12
    /// Never fewer than 3 sentences, nor more than 10: the R5 voice
    /// handoff splices after the last queued sentence, so a deeper queue
    /// would delay it.
    static let lookAheadSentences = 3...10
    /// A Mac keeps its whole look-ahead under Low Power Mode and heat.
    static let lookAheadUnderStrain: Int? = nil
    /// The cooling switch splices after the last queued sentence, however
    /// deep the queue.
    static let coolingSwitchLandsWithin: Int? = nil
    /// R3-07: as the iPhone. The Mac makes a sentence in about half the
    /// time, so fewer sentences pass the budget, and those split into
    /// longer leads.
    static let coldLeadFirstAudioBudget: TimeInterval? = 1.0
    #endif
}
