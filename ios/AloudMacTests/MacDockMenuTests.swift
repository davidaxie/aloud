import AppKit
import XCTest
@testable import Aloud

/// The Dock icon's menu (M13, phase 4): with a book loaded, its title as a
/// disabled header and the Playback menu's Play/Pause and skips, titled from
/// the menus' copy table and run through the same actions, on a muted rig's
/// controller; with none, no menu.
@MainActor
final class MacDockMenuTests: XCTestCase {

    func testFourItemsWithABook() throws {
        let (rig, dock, _) = makeDock()
        rig.loadDefault()
        let menu = try XCTUnwrap(dock.menu(), "a loaded book has a Dock menu")

        XCTAssertEqual(menu.items.map(\.title),
                       [rig.document.title, MacMenuCopy.play, MacMenuCopy.back15, MacMenuCopy.forward15])
        XCTAssertFalse(menu.items[0].isEnabled, "the title is a header")
        XCTAssertNil(menu.items[0].action)
        XCTAssertFalse(menu.autoenablesItems, "the items carry their own states")
        for item in menu.items.dropFirst() {
            XCTAssertTrue(item.isEnabled, item.title)
            XCTAssertEqual(item.keyEquivalent, "", "\(item.title): no key in the Dock")
            XCTAssertTrue(item.target === dock, "\(item.title) runs through the Dock menu")
        }
    }

    func testNoMenuWithoutABook() {
        let (_, dock, actions) = makeDock()
        XCTAssertNil(actions.playback.document)
        XCTAssertNil(dock.menu(), "no header and no items: only the system's show")
    }

    /// The Dock repeats the Playback menu: its commands, its titles and its
    /// enabled states, Play turning to Pause while the book plays.
    func testTitlesAndStatesAreThePlaybackMenus() async throws {
        let (rig, dock, actions) = makeDock()
        rig.loadDefault()
        XCTAssertEqual(MacDockMenu.commands, [.playPause, .back15, .forward15])
        XCTAssertEqual(MacDockMenu.commands.map(\.menu), [.playback, .playback, .playback])

        let paused = try XCTUnwrap(dock.menu())
        for (item, command) in zip(paused.items.dropFirst(), MacDockMenu.commands) {
            XCTAssertEqual(item.title, actions.title(for: command))
            XCTAssertEqual(item.isEnabled, actions.isEnabled(command), item.title)
            XCTAssertTrue(MacMenuCopy.all.contains(item.title), "\(item.title) is a copy-table title")
        }

        rig.controller.togglePlayPause()
        let playing = await rig.waitUntil(2) { rig.controller.isActive }
        XCTAssertTrue(playing)
        XCTAssertEqual(try XCTUnwrap(dock.menu()).items[1].title, MacMenuCopy.pause, "built fresh: Pause while playing")

        rig.controller.togglePlayPause()
        let stopped = await rig.waitUntil(2) { !rig.controller.isActive }
        XCTAssertTrue(stopped)
        XCTAssertEqual(try XCTUnwrap(dock.menu()).items[1].title, MacMenuCopy.play)
    }

    /// Each item reaches the shared controller: the skips are the one
    /// `skip(seconds:)` the keys use, and Play/Pause toggles.
    func testItemsRunTheSharedCommands() async throws {
        let (rig, dock, _) = makeDock(sentences: 40)
        rig.loadDefault(at: 20)
        let expected = PlaybackController.skipTarget(from: 20, seconds: PlaybackController.skipInterval,
                                                     sentenceCount: 40,
                                                     wordsPerMinute: LibraryDocument.spokenWordsPerMinute,
                                                     words: { _ in 3 })

        try XCTUnwrap(dock.menu()).performActionForItem(at: 3)
        XCTAssertEqual(rig.controller.currentSentence, expected, "Forward 15 Seconds")
        try XCTUnwrap(dock.menu()).performActionForItem(at: 2)
        XCTAssertLessThan(rig.controller.currentSentence, expected, "Back 15 Seconds")
        XCTAssertFalse(rig.controller.isActive, "a skip keeps the pause")

        try XCTUnwrap(dock.menu()).performActionForItem(at: 1)
        let playing = await rig.waitUntil(2) { rig.controller.isActive }
        XCTAssertTrue(playing, "Play played")
        try XCTUnwrap(dock.menu()).performActionForItem(at: 1)
        let paused = await rig.waitUntil(2) { !rig.controller.isActive }
        XCTAssertTrue(paused, "Pause paused")
    }

    /// A rename reaches the header at once: the store's record is the live
    /// one, as Now Playing reads it, while the controller keeps its copy
    /// until the next load.
    func testTheHeaderShowsARenameOfTheLoadedBook() throws {
        let (rig, dock, actions) = makeDock(shelved: true)
        rig.loadDefault()
        let shelved = try XCTUnwrap(actions.store.documents.first { $0.id == rig.document.id })
        actions.store.rename(shelved, to: "A Better Title")

        XCTAssertEqual(actions.playback.document?.title, rig.document.title, "the controller's copy is the old one")
        XCTAssertEqual(try XCTUnwrap(dock.menu()).items[0].title, "A Better Title")
    }

    // MARK: - Rig

    /// `shelved`: the rig's book is in the store's index too, as a loaded
    /// book is in the app.
    private func makeDock(sentences: Int = 12,
                          shelved: Bool = false) -> (PlaybackTestRig, MacDockMenu, MacCommandActions) {
        let rig = PlaybackTestRig(sentences: sentences)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-dock-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("library.json")
        if shelved {
            struct Index: Encodable {
                let version: Int
                let documents: [LibraryDocument]
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? encoder.encode(Index(version: 2, documents: [rig.document])).write(to: indexURL)
        }
        let store = DocumentStore(indexURL: indexURL, notifications: NotificationCenter())
        var actions = MacCommandActions(playback: rig.controller, router: LibraryRouter(), store: store,
                                        sleepTimer: SleepTimer(defaults: rig.defaults),
                                        continuePlayback: ContinuePlayback(), ui: MacUIState())
        actions.announce = { _ in }
        return (rig, MacDockMenu(actions: actions), actions)
    }
}
