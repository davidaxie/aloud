import Combine
import Foundation

/// What Continue listening reads from the shelf: the records, a book's
/// content with its live record, and the opened stamp. DocumentStore in the
/// app; a fake in the unit tests.
@MainActor
protocol ContinueLibrary: AnyObject {
    var documents: [LibraryDocument] { get }
    func liveContent(for document: LibraryDocument) async throws -> (document: LibraryDocument, content: DocContent)
    func noteOpened(id: UUID)
}

extension DocumentStore: ContinueLibrary {}

/// How one Continue listening run ended. The intent turns each into what
/// Siri or Shortcuts says (ContinueListeningIntent.error(for:)).
enum ContinueListeningOutcome: Equatable, Sendable {
    /// The voice is reading the book, or was still preparing at the deadline.
    case started
    /// A tap in the app cancelled or replaced the load, or stopped the voice
    /// as it started. The listener's newer choice stands, so nothing is said.
    case superseded
    /// No book on the shelf has been started.
    case nothingToContinue
    /// The Continue book is at its end, where Play would restart it. It is
    /// never restarted from a pocket.
    case finished(title: String)
    /// The book couldn't be loaded, or its voice failed to start.
    case failed(title: String)
}

/// The two shortcuts' actions (R26), kept free of App Intents so the unit
/// tests drive them on the muted rig without ever running an intent.
///
/// Continue listening plays exactly what the Continue card would: the card's
/// own book, through the card's own ContinuePlayback, with a user Play (so
/// R11's resume rewind and stop-clearing apply as on the lock screen). It
/// emits no haptic and opens no screen: the phone may be in a pocket.
@MainActor
struct ShortcutActions {
    let library: any ContinueLibrary
    let playback: PlaybackController
    let continuePlayback: ContinuePlayback
    let sleepTimer: SleepTimer
    /// How long Continue listening waits for audio before calling it started.
    var startTimeout: TimeInterval = ShortcutActions.defaultStartTimeout

    /// Long enough for a cold neural voice to load. Returning sooner could let
    /// iOS suspend a background launch before its audio session goes live.
    nonisolated static let defaultStartTimeout: TimeInterval = 10

    // MARK: - Continue listening

    func continueListening() async -> ContinueListeningOutcome {
        let loadedID = playback.document?.id
        // The Continue card's hero, by the same rule, so the shortcut and the
        // card never disagree about which book is "yours".
        guard let book = DocumentStore.continueListeningCandidate(in: library.documents,
                                                                  loadedID: loadedID) else {
            return .nothingToContinue
        }
        // Already speaking: continue means leave it alone, never pause or restart.
        if loadedID == book.id && playback.isListenerPlaying { return .started }
        // Only a book at its end would restart. The loaded book asks the
        // controller: paused in its last minute, its record already reads
        // Finished, yet Play (and the card's circle) reads the rest. Any
        // other Finished book reopens at its end.
        let atEnd = loadedID == book.id ? playback.isAtEnd : book.isFinished
        if atEnd { return .finished(title: book.title) }
        do {
            try await continuePlayback.resume(book, playback: playback,
                                              loader: { [library] in try await library.liveContent(for: book) },
                                              onLoaded: { [library] in library.noteOpened(id: $0) })
        } catch is CancellationError {
            return .superseded
        } catch {
            return .failed(title: book.title)
        }
        return await awaitStart(title: book.title)
    }

    /// Settles once the voice is audible or has failed. Event-driven: the
    /// status, the playhead and each queued clip are judged as they change,
    /// plus one deadline, whichever settles first.
    private func awaitStart(title: String) async -> ContinueListeningOutcome {
        let playback = self.playback
        if let outcome = Self.startOutcome(status: playback.status,
                                           speaking: Self.isSpeaking(playback, at: playback.currentSentence),
                                           initial: true, title: title) {
            return outcome
        }
        let timeout = startTimeout
        return await withCheckedContinuation { continuation in
            let wait = StartWait(continuation)
            // @Published emits before the property changes, so each sink
            // passes its own new value on and reads the rest live.
            let judge: (PlayerStatus, Int) -> Void = { status, sentence in
                if let outcome = Self.startOutcome(status: status,
                                                   speaking: Self.isSpeaking(playback, at: sentence),
                                                   initial: false, title: title) {
                    wait.finish(outcome)
                }
            }
            // dropFirst: the current values were judged just above.
            wait.subscriptions = [
                playback.$status.dropFirst().sink { judge($0, playback.currentSentence) },
                // The playhead leaving a skipped sentence's beat of silence.
                playback.$currentSentence.dropFirst().sink { judge(playback.status, $0) },
                // A clip queued for the sentence already playing, after the
                // queue ran dry behind a skip: scheduleClip writes this flag
                // for every clip it queues, once the clip is on the node.
                playback.$isPreparingVoice.dropFirst().sink { _ in
                    judge(playback.status, playback.currentSentence)
                },
            ]
            // Still preparing at the deadline (a cold neural voice, or one
            // working past skipped sentences): the voice is on its way, and
            // the card shows the arc meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { wait.finish(.started) }
            }
        }
    }

    /// Real speech at the playhead: the sentence playing has its clip on the
    /// node, with words in it. `.playing` alone isn't a start: a skipped
    /// sentence's beat of silence plays too (so does a citation-only one's),
    /// and a voice failing every sentence plays only that before it errors.
    /// Counting it would leave the listener in silence, with Siri saying
    /// nothing.
    private static func isSpeaking(_ playback: PlaybackController, at sentence: Int) -> Bool {
        guard !playback.skippedSentences.contains(sentence) else { return false }
        return playback.wordTiming.clip(for: sentence)?.windows.isEmpty == false
    }

    /// What a status means for a start in progress: `nil` keeps waiting.
    /// Playing counts only while the voice is `speaking`; over silence the
    /// next sentence decides. Stopped at the first look means play() didn't
    /// take; stopped later means something else stopped it (a tap, an
    /// interruption).
    nonisolated static func startOutcome(status: PlayerStatus, speaking: Bool, initial: Bool,
                                         title: String) -> ContinueListeningOutcome? {
        switch status {
        case .playing: return speaking ? .started : nil
        case .buffering: return nil
        case .error: return .failed(title: title)
        case .paused, .idle, .ended: return initial ? .failed(title: title) : .superseded
        }
    }

    // MARK: - Sleep timer

    /// Arms the app's one sleep timer, the one the reader's chip shows, even
    /// with no book loaded (it waits for one). Returns the spoken confirmation.
    @discardableResult
    func setSleepTimer(_ choice: SleepTimerChoice) -> String {
        sleepTimer.select(choice.option)
        // With no book there is no chapter list to judge yet: say "chapter",
        // the choice's own name.
        return ShortcutCopy.sleepTimerSet(choice.option,
                                          endsAtChapter: playback.document == nil || sleepTimer.endsAtChapter)
    }
}

/// One wait for the voice. Resumes its continuation exactly once, from the
/// first change that settles it or from the deadline, then drops the
/// subscriptions so nothing outlives the wait.
@MainActor
private final class StartWait {
    var subscriptions: [AnyCancellable] = []
    private var continuation: CheckedContinuation<ContinueListeningOutcome, Never>?

    init(_ continuation: CheckedContinuation<ContinueListeningOutcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: ContinueListeningOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        continuation.resume(returning: outcome)
    }
}
