import XCTest
@testable import Aloud

/// R4: opening book B while A plays stops A and saves the sentence A was
/// speaking (its card updates from that), A keeps its rest anchor, and B
/// then autoplays from its own saved sentence.
@MainActor
final class OpenWhilePlayingTests: XCTestCase {

    private struct Switched {
        let rig: PlaybackTestRig
        let a: LibraryDocument
        let b: LibraryDocument
    }

    /// A is speaking sentence 2 (clips long enough that it can't move on)
    /// when B is opened.
    private func openBWhileAPlays() async -> Switched {
        let rig = PlaybackTestRig(clipDuration: 2)
        let a = rig.document
        rig.controller.load(document: a, content: rig.content)
        rig.controller.seek(to: 2, andPlay: true)
        let active = await rig.waitUntil { rig.controller.isActive }
        XCTAssertTrue(active)
        XCTAssertEqual(rig.controller.currentSentence, 2)

        let b = PlaybackTestRig.makeDocument(hash: "book-b", sentences: 8,
                                             progressSentence: 3, progressFraction: 3.0 / 8)
        rig.controller.load(document: b, content: PlaybackTestRig.makeContent(hash: "book-b", count: 8))
        return Switched(rig: rig, a: a, b: b)
    }

    func testOpeningBWhileAPlaysSavesAsCurrentSentence() async {
        let s = await openBWhileAPlays()

        let aProgress = s.rig.progress.filter { $0.documentID == s.a.id }
        XCTAssertEqual(aProgress.last?.sentence, 2, "A's saved sentence is the one it was speaking")
        XCTAssertEqual(s.rig.controller.document?.id, s.b.id)
        XCTAssertEqual(s.rig.controller.status, .paused)
        XCTAssertEqual(s.rig.anchorStore.load()?.documentID, s.a.id,
                       "A's rest starts at the switch, and B can't inherit it")
    }

    func testOutgoingBookGetsNoProgressAfterTheSwitch() async {
        let s = await openBWhileAPlays()
        let count = s.rig.progress.filter { $0.documentID == s.a.id }.count

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(s.rig.progress.filter { $0.documentID == s.a.id }.count, count)
    }

    func testAutoplayThenStartsB() async {
        let s = await openBWhileAPlays()

        s.rig.controller.startAutoplay()

        XCTAssertTrue(s.rig.controller.isActive)
        XCTAssertEqual(s.rig.controller.document?.id, s.b.id)
        XCTAssertEqual(s.rig.controller.currentSentence, s.b.progressSentence)
    }
}
