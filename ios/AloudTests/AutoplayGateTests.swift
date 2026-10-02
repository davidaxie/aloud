import XCTest
@testable import Aloud

/// R4's autoplay policy, which lives in `startAutoplay()`: suppressed in a
/// UI-test launch without -uitest-allow-autoplay, a Finished book never
/// starts (it opens at its end, .ended, R24, and stays there; BookEndTests
/// covers the Finished rule's time slack), and anything else starts
/// speaking from its saved sentence. (Continuing a book already speaking:
/// ContinueAutoplayTests.)
@MainActor
final class AutoplayGateTests: XCTestCase {

    private func open(_ rig: PlaybackTestRig,
                      sentences: Int,
                      progressSentence: Int,
                      progressFraction: Double,
                      wordCount: Int = 0) {
        var document = PlaybackTestRig.makeDocument(hash: "rig-hash",
                                                    sentences: sentences,
                                                    progressSentence: progressSentence,
                                                    progressFraction: progressFraction)
        document.wordCount = wordCount
        rig.controller.load(document: document, content: rig.content)
    }

    func testSuppressedAutoplayLeavesBookPaused() {
        let rig = PlaybackTestRig(autoplaySuppressed: true)
        open(rig, sentences: 12, progressSentence: 4, progressFraction: 0.3)

        rig.controller.startAutoplay()

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, 4)
        XCTAssertEqual(rig.controller.userPlayAction, 0)
    }

    func testFinishedBookOpensPausedAtItsEnd() {
        let rig = PlaybackTestRig(sentences: 4)
        open(rig, sentences: 4, progressSentence: 3, progressFraction: 1.0)

        rig.controller.startAutoplay()

        XCTAssertEqual(rig.controller.status, .ended, "at its end, the colophon showing (R24)")
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(rig.controller.userPlayAction, 0)
        // The cue at the last sentence is 3/4 by position; writing that back
        // would un-finish the book in the store.
        XCTAssertTrue(rig.progress.allSatisfy { $0.fraction >= LibraryDocument.finishedThreshold },
                      "reported \(rig.progress.map(\.fraction))")
    }

    /// Under 100 sentences, (n-1)/n is below the Finished threshold. Each open
    /// is fed the record the store would hold after the one before, so a
    /// re-cue that un-finishes the book shows up as the second open autoplaying.
    func testFinishedShortBookStaysPausedOnEveryReopen() {
        let rig = PlaybackTestRig(sentences: 40)
        let content = PlaybackTestRig.makeContent(hash: "short", count: 40)
        var stored = PlaybackTestRig.makeDocument(hash: "short", sentences: 40,
                                                  progressSentence: 39, progressFraction: 1.0)
        for open in 1...3 {
            rig.controller.load(document: stored, content: content)
            rig.controller.startAutoplay()
            XCTAssertEqual(rig.controller.status, .ended, "open \(open)")

            // What DocumentStore.saveProgress holds now.
            if let saved = rig.progress.last(where: { $0.documentID == stored.id }) {
                stored.progressSentence = saved.sentence
                stored.progressFraction = saved.fraction
            }
            XCTAssertTrue(stored.isFinished, "open \(open): \(stored.progressFraction)")
            rig.controller.unload()   // the next open is a fresh load, as after a relaunch
        }
    }

    func testUnfinishedBookAutoplays() {
        let rig = PlaybackTestRig()
        open(rig, sentences: 12, progressSentence: 6, progressFraction: 0.5)

        rig.controller.startAutoplay()

        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.currentSentence, 6, "from the saved sentence")
        XCTAssertEqual(rig.controller.userPlayAction, 1)
    }

    /// Autoplay follows the Finished rule: from 0.99 with no length to
    /// weigh or a minute or less left (9,900 words: 36 s), a book opens at
    /// its end; with 20 minutes left (333,333 words) it is in progress and
    /// speaks from its saved sentence.
    func testThresholdBoundary() {
        let cases: [(fraction: Double, words: Int, autoplays: Bool)] = [
            (0.989, 0, true), (0.99, 0, false), (0.99, 9_900, false), (0.99, 333_333, true),
        ]
        for (fraction, words, autoplays) in cases {
            let rig = PlaybackTestRig()
            open(rig, sentences: 12, progressSentence: 11, progressFraction: fraction, wordCount: words)

            rig.controller.startAutoplay()

            let context = "progress \(fraction), \(words) words"
            XCTAssertEqual(rig.controller.isActive, autoplays, context)
            XCTAssertEqual(rig.controller.isAtEnd, !autoplays, context)
            if autoplays {
                XCTAssertEqual(rig.controller.currentSentence, 11, context)
                rig.controller.pause(rampsOut: false)
            }
        }
    }

    func testNothingLoadedDoesNothing() {
        let rig = PlaybackTestRig()
        rig.controller.startAutoplay()
        XCTAssertEqual(rig.controller.status, .idle)
        XCTAssertEqual(rig.controller.userPlayAction, 0)
    }
}
