import AppIntents
import XCTest
@testable import Aloud

/// R26's two App Intents on the Mac (phase 4, S4-D): the Mac app compiles
/// them, and each intent's run (what its perform() does over the app's
/// parts) works over the shared controller, Continue playback and sleep
/// timer, the ones the Playback menu and the Dock menu read. Continue
/// listening plays the Continue card's book from where it was, never
/// restarts or pauses a speaking one, and throws its fixed copy when there
/// is nothing to play; Set sleep timer arms the Playback menu's timer.
///
/// Silent: every run is over the muted rig and a fake shelf, never the
/// app's shared model or library, and no intent runs through the system.
@MainActor
final class MacIntentsTests: XCTestCase {

    // MARK: - Fakes

    /// The shelf Continue listening reads: records every load and open.
    @MainActor
    private final class FakeContinueLibrary: ContinueLibrary {
        var documents: [LibraryDocument] = []
        private(set) var liveContentCalls: [UUID] = []
        private(set) var openedIDs: [UUID] = []
        private let content: DocContent

        init(content: DocContent) {
            self.content = content
        }

        func liveContent(for document: LibraryDocument) async throws -> (document: LibraryDocument, content: DocContent) {
            liveContentCalls.append(document.id)
            guard let live = documents.first(where: { $0.id == document.id }) else { throw CancellationError() }
            return (live, content)
        }

        func noteOpened(id: UUID) {
            openedIDs.append(id)
        }
    }

    /// The rig, the shelf and the app's shared parts, wired as AppModel
    /// wires them, with the Mac's menus over the same controller and timer.
    @MainActor
    private final class Harness {
        let rig: PlaybackTestRig
        let library: FakeContinueLibrary
        let continuePlayback: ContinuePlayback
        let sleepTimer: SleepTimer
        let commands: MacCommandActions

        /// 5 s clips, so a sentence holds still while it is checked.
        init(store: DocumentStore) {
            let rig = PlaybackTestRig(clipDuration: 5)
            let continuePlayback = ContinuePlayback()
            let sleepTimer = SleepTimer(timing: .standard, defaults: rig.defaults)
            sleepTimer.attach(to: rig.controller)
            var commands = MacCommandActions(playback: rig.controller, router: LibraryRouter(), store: store,
                                             sleepTimer: sleepTimer, continuePlayback: continuePlayback,
                                             ui: MacUIState())
            commands.announce = { _ in }
            self.rig = rig
            library = FakeContinueLibrary(content: rig.content)
            self.continuePlayback = continuePlayback
            self.sleepTimer = sleepTimer
            self.commands = commands
        }

        /// What `AppModel.shortcutActions` hands both intents.
        var actions: ShortcutActions {
            ShortcutActions(library: library, playback: rig.controller,
                            continuePlayback: continuePlayback, sleepTimer: sleepTimer)
        }

        /// The Dock menu's first item: the loaded book's title.
        var dockHeader: String? { MacDockMenu(actions: commands).menu()?.items.first?.title }
    }

    private func makeHarness() -> Harness {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-intents-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore(indexURL: folder.appendingPathComponent("library.json"),
                                  notifications: NotificationCenter())
        return Harness(store: store)
    }

    /// A shelf record of the rig's book, opened a minute ago and listened up
    /// to `sentence`.
    private static func record(_ rig: PlaybackTestRig, at sentence: Int) -> LibraryDocument {
        var document = rig.document
        document.progressSentence = sentence
        document.progressFraction = Double(sentence) / Double(rig.content.sentences.count)
        document.lastOpenedAt = Date().addingTimeInterval(-60)
        return document
    }

    /// Runs Continue listening's intent; nil when it played, else what it threw.
    private func continueListening(_ h: Harness) async -> ShortcutError? {
        do {
            try await ContinueListeningIntent.continueListening(with: h.actions)
            return nil
        } catch let error as ShortcutError {
            return error
        } catch {
            XCTFail("only ShortcutError is thrown: \(error)")
            return nil
        }
    }

    /// The started path needs the host's audio engine; a host that can't
    /// start it errors every start (PlaybackTestRig.waitUntilPlayingOrSkip).
    private func skipIfTheHostCantPlay(_ error: ShortcutError?, _ rig: PlaybackTestRig) throws {
        if case .couldNotPlay = error, rig.statuses.contains(.error) {
            throw XCTSkip("The audio engine can't start in this test host")
        }
    }

    // MARK: - Continue listening

    /// The loaded book, paused: it plays from where it was cued, muted, and
    /// the Playback and Dock menus read it as playing.
    func testContinueListeningPlaysTheLoadedPausedBook() async throws {
        let h = makeHarness()
        h.library.documents = [Self.record(h.rig, at: 5)]
        h.rig.loadDefault(at: 5)
        XCTAssertEqual(h.commands.title(for: .playPause), MacMenuCopy.play)

        let error = await continueListening(h)

        try skipIfTheHostCantPlay(error, h.rig)
        XCTAssertNil(error, "success is the voice itself: nothing is said")
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.rig.controller.currentSentence, 5, "from where it was cued")
        XCTAssertEqual(h.library.liveContentCalls, [], "the loaded book is never reloaded")
        XCTAssertEqual(h.commands.title(for: .playPause), MacMenuCopy.pause, "the Playback menu's Pause")
        XCTAssertEqual(h.dockHeader, h.rig.document.title)
        XCTAssertEqual(h.rig.controller.mixerOutputVolume, 0, "muted")
    }

    /// Nothing loaded: the Continue card's book is loaded through the card's
    /// own Continue playback, stamped opened, and plays from its saved
    /// sentence; the Dock menu then names it.
    func testContinueListeningLoadsTheCardsBook() async throws {
        let h = makeHarness()
        let book = Self.record(h.rig, at: 3)
        h.library.documents = [book]
        XCTAssertNil(h.dockHeader, "no book, no Dock menu")

        let error = await continueListening(h)

        XCTAssertEqual(h.library.liveContentCalls, [book.id], "loaded once")
        XCTAssertEqual(h.library.openedIDs, [book.id], "stamped opened, as a circle click is")
        XCTAssertEqual(h.rig.controller.document?.id, book.id)
        XCTAssertNil(h.continuePlayback.pendingDocumentID, "the card's arc is gone")
        XCTAssertEqual(h.dockHeader, book.title)
        try skipIfTheHostCantPlay(error, h.rig)
        XCTAssertNil(error)
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.rig.controller.currentSentence, 3, "from the saved sentence")
        XCTAssertEqual(h.rig.controller.mixerOutputVolume, 0, "muted")
    }

    /// Already speaking: continue means leave it alone, not even a Play.
    func testContinueListeningLeavesASpeakingBookAlone() async throws {
        let h = makeHarness()
        h.library.documents = [Self.record(h.rig, at: 2)]
        h.rig.loadDefault(at: 2)
        h.rig.controller.play()
        try await h.rig.waitUntilPlayingOrSkip()
        let statusMark = h.rig.statuses.count
        let plays = h.rig.controller.userPlayAction

        let error = await continueListening(h)

        XCTAssertNil(error)
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(Array(h.rig.statuses[statusMark...]), [], "never paused or restarted")
        XCTAssertEqual(h.rig.controller.userPlayAction, plays)
        XCTAssertEqual(h.library.liveContentCalls, [])
    }

    /// An empty shelf: Siri or Shortcuts says the fixed line, and nothing
    /// loads or speaks.
    func testNothingToContinueSaysSo() async {
        let h = makeHarness()

        let error = await continueListening(h)

        XCTAssertEqual(error, .nothingToContinue)
        XCTAssertEqual(error.map { String(localized: $0.localizedStringResource) }, ShortcutCopy.nothingToContinue)
        XCTAssertNil(h.rig.controller.document)
        XCTAssertEqual(h.rig.controller.status, .idle)
        XCTAssertEqual(h.rig.engineA.requests.count, 0, "nothing was synthesized")
        XCTAssertNil(h.dockHeader)
    }

    /// A Finished book is never restarted by an intent: "Listen again" is a
    /// choice made at the window.
    func testAFinishedBookIsNotRestarted() async {
        let h = makeHarness()
        var finished = Self.record(h.rig, at: h.rig.content.sentences.count - 1)
        finished.progressFraction = 1
        h.library.documents = [finished]
        h.rig.controller.load(document: finished, content: h.rig.content)
        _ = await h.rig.waitUntil(0.3) { false }
        let statusMark = h.rig.statuses.count
        let plays = h.rig.controller.userPlayAction

        let error = await continueListening(h)

        XCTAssertEqual(error, .finished(title: finished.title))
        XCTAssertEqual(error?.message, ShortcutCopy.finished(finished.title))
        XCTAssertEqual(Array(h.rig.statuses[statusMark...]), [])
        XCTAssertEqual(h.rig.controller.userPlayAction, plays)
    }

    // MARK: - Set sleep timer

    /// The intent arms the app's one timer: the one Playback ▸ Sleep Timer
    /// checks, listed first there next time, like a menu pick.
    func testSetSleepTimerArmsThePlaybackMenusTimer() {
        let h = makeHarness()

        XCTAssertEqual(SetSleepTimerIntent(choice: .thirty).setSleepTimer(with: h.actions),
                       "Sleep timer set for 30 minutes")
        XCTAssertEqual(h.sleepTimer.option, .minutes(30))
        let armed = MacCommandState(actions: h.commands).snapshot
        XCTAssertEqual(armed.sleepSelection, .minutes(30), "the menu's checkmark")
        XCTAssertEqual(armed.sleepOptions.first, .minutes(30), "listed first next time")

        XCTAssertEqual(SetSleepTimerIntent(choice: .endOfChapter).setSleepTimer(with: h.actions),
                       "Sleep timer set for the end of the chapter", "no book yet: the choice's own name")
        XCTAssertEqual(MacCommandState(actions: h.commands).snapshot.sleepSelection, .endOfChapter)

        XCTAssertEqual(SetSleepTimerIntent(choice: .off).setSleepTimer(with: h.actions), "Sleep timer off")
        XCTAssertFalse(h.sleepTimer.isArmed)
        XCTAssertEqual(MacCommandState(actions: h.commands).snapshot.sleepSelection, .off)
    }

    /// With a book loaded, End of chapter names what the timer resolved:
    /// the rig's book has no chapter list, so the end of the book.
    func testSetSleepTimerSaysTheEndOfTheBookWithoutChapters() {
        let h = makeHarness()
        h.rig.loadDefault()

        XCTAssertEqual(SetSleepTimerIntent(choice: .endOfChapter).setSleepTimer(with: h.actions),
                       "Sleep timer set for the end of the book")
        XCTAssertFalse(h.sleepTimer.endsAtChapter)
        XCTAssertEqual(h.commands.sleepTitle(for: .endOfChapter), MacMenuCopy.endOfBook, "the menu agrees")
    }

    // MARK: - In the Mac app

    /// Both intents, behind the one provider, and what they say names no
    /// iPhone, gesture or lock screen.
    func testTheTwoIntentsReadRightOnAMac() {
        XCTAssertEqual(AloudShortcuts.appShortcuts.count, 2)
        XCTAssertEqual(String(localized: ContinueListeningIntent.title), "Continue listening")
        XCTAssertEqual(String(localized: SetSleepTimerIntent.title), "Set sleep timer")
        let lines = [ShortcutCopy.nothingToContinue, ShortcutCopy.finished("Emma"), ShortcutCopy.couldNotPlay("Emma")]
            + SleepTimerChoice.allCases.flatMap { choice in
                [true, false].map { ShortcutCopy.sleepTimerSet(choice.option, endsAtChapter: $0) }
            }
        for line in lines {
            for word in ["iPhone", "phone", "tap", "Tap", "swipe", "lock", "Lock"] {
                XCTAssertFalse(line.contains(word), "«\(line)» says \(word)")
            }
        }
    }

    /// The Mac app's built App Intents metadata lists exactly the two
    /// actions, so Shortcuts and Spotlight on the Mac offer exactly two. On
    /// the Mac it sits in the bundle's Resources. Skips where the host was
    /// built without the extraction step's output.
    func testTheMacAppsMetadataListsExactlyTwoActions() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let url = resources.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("No App Intents metadata at \(url.path)")
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                 "extract.actionsdata is not a JSON object")
        let actions = try XCTUnwrap(root["actions"] as? [String: Any], "keys: \(root.keys.sorted())")
        XCTAssertEqual(actions.keys.sorted(), ["ContinueListeningIntent", "SetSleepTimerIntent"])
    }
}
