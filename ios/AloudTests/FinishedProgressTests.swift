import XCTest
@testable import Aloud

/// A Finished book keeps its stored progress while the playhead stays on the
/// sentence it finished at. Re-cueing that sentence (an open, an audition,
/// the outgoing-book flush) would report (n-1)/n by position, which is below
/// `LibraryDocument.finishedThreshold` for any book under 100 sentences: the
/// card would lose "Finished" and the next open would autoplay (R4).
/// Moving to another sentence makes progress plain position again.
///
/// All silent: muted controller, stub engines returning silence. A test whose
/// audio engine can't start in the host is skipped, not failed.
@MainActor
final class FinishedProgressTests: XCTestCase {

    private static let threshold = LibraryDocument.finishedThreshold

    /// A 4-sentence book opened Finished: paused at sentence 3, fraction 1.0.
    private func openFinished(_ rig: PlaybackTestRig) -> LibraryDocument {
        let document = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: 4,
                                                    progressSentence: 3, progressFraction: 1.0)
        rig.controller.load(document: document, content: rig.content)
        return document
    }

    private func fractions(_ rig: PlaybackTestRig, for id: UUID, from mark: Int = 0) -> [Double] {
        rig.progress[mark...].filter { $0.documentID == id }.map(\.fraction)
    }

    // MARK: - Auditions

    /// The audition re-cues sentence 3 (startPlayback), and a pause ends it
    /// before it can hand anything back.
    func testAuditionOnReopenedFinishedBookCutShortStaysFinished() {
        let rig = PlaybackTestRig(sentences: 4)
        let book = openFinished(rig)
        let mark = rig.progress.count

        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the pick auditions sentence 3")
        rig.controller.pause()

        let reported = fractions(rig, for: book.id, from: mark)
        XCTAssertFalse(reported.isEmpty, "the audition's re-cue reports progress")
        XCTAssertTrue(reported.allSatisfy { $0 >= Self.threshold }, "reported \(reported)")
        XCTAssertEqual(rig.controller.currentSentence, 3)
    }

    /// Opening another book ends the audition, and the outgoing-book flush
    /// still saves A at its stored fraction, then B at its own position.
    func testOpeningAnotherBookMidAuditionFlushesFinishedBookAsFinished() {
        let rig = PlaybackTestRig(sentences: 4)
        let a = openFinished(rig)
        let mark = rig.progress.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)

        let b = PlaybackTestRig.makeDocument(hash: "book-b", sentences: 8,
                                             progressSentence: 2, progressFraction: 2.0 / 8)
        rig.controller.load(document: b, content: PlaybackTestRig.makeContent(hash: "book-b", count: 8))

        let aReported = fractions(rig, for: a.id, from: mark)
        XCTAssertFalse(aReported.isEmpty, "the switch flushes A")
        XCTAssertTrue(aReported.allSatisfy { $0 >= Self.threshold }, "A reported \(aReported)")
        XCTAssertEqual(rig.progress.last { $0.documentID == a.id }?.sentence, 3)
        let bSaved = rig.progress.last { $0.documentID == b.id }
        XCTAssertEqual(bSaved?.sentence, 2)
        XCTAssertEqual(bSaved?.fraction ?? -1, 2.0 / 8, accuracy: 1e-9, "B's own fraction, no floor carried over")
    }

    /// Reached .ended in this session, then an audition a pause cuts short:
    /// finishAudition never runs to put 1.0 back.
    func testAuditionFromEndedCutShortStaysFinished() async throws {
        let rig = PlaybackTestRig(sentences: 4, clipDuration: 1)
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        let mark = rig.progress.count

        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the pick auditions the last sentence")
        rig.controller.pause()

        let reported = fractions(rig, for: rig.document.id, from: mark)
        XCTAssertFalse(reported.isEmpty)
        XCTAssertTrue(reported.allSatisfy { $0 >= Self.threshold }, "reported \(reported)")
    }

    // MARK: - The floor is narrow

    func testMovingOffTheFinishedSentenceReportsPlainPosition() {
        let rig = PlaybackTestRig(sentences: 4)
        let book = openFinished(rig)

        rig.controller.seek(to: 1, andPlay: false)
        XCTAssertEqual(fractions(rig, for: book.id).last ?? -1, 0.25, accuracy: 1e-9)

        // Coming back is a new position, not the finished one.
        rig.controller.seek(to: 3, andPlay: false)
        XCTAssertEqual(fractions(rig, for: book.id).last ?? -1, 0.75, accuracy: 1e-9)
    }

    func testUnfinishedBookOpensAtPlainPosition() {
        let rig = PlaybackTestRig(sentences: 4)
        let document = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: 4,
                                                    progressSentence: 3, progressFraction: 0.75)
        rig.controller.load(document: document, content: rig.content)

        XCTAssertEqual(fractions(rig, for: document.id), [0.75])
    }
}
