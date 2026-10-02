import XCTest
@testable import Aloud

/// R18: the Continue circle plays and pauses in place. The loaded book just
/// toggles; any other book is loaded behind a gate the test opens, so the
/// in-between state can be checked. Silent: the frozen muted rig.
@MainActor
final class ContinuePlaybackTests: XCTestCase {

    /// A loader that waits until the test opens it (or fails it).
    @MainActor
    private final class LoadGate {
        private var waiter: CheckedContinuation<Void, Error>?
        private var outcome: Result<Void, Error>?
        private(set) var calls = 0

        func wait() async throws {
            calls += 1
            if let outcome { return try outcome.get() }
            try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func open() { resume(.success(())) }
        func fail(_ error: Error) { resume(.failure(error)) }

        private func resume(_ result: Result<Void, Error>) {
            guard let waiter else { outcome = result; return }
            self.waiter = nil
            waiter.resume(with: result)
        }
    }

    private struct LoadFailed: Error {}

    /// The rig's book, a ContinuePlayback, and what its callbacks reported.
    @MainActor
    private final class Harness {
        let rig = PlaybackTestRig()
        let continuePlayback = ContinuePlayback()
        let gate = LoadGate()
        private(set) var loadedIDs: [UUID] = []
        private(set) var failures = 0

        /// A circle tap on the rig's book, loading it through the gate.
        func tap() {
            let rig = rig
            let gate = gate
            continuePlayback.toggle(rig.document, playback: rig.controller,
                                    loader: {
                                        try await gate.wait()
                                        return (rig.document, rig.content)
                                    },
                                    onLoaded: { [weak self] in self?.loadedIDs.append($0) },
                                    onFailure: { [weak self] in self?.failures += 1 })
        }

        var effectiveStatus: PlayerStatus {
            ContinuePlayback.effectiveStatus(documentID: rig.document.id,
                                             loadedID: rig.controller.document?.id,
                                             status: rig.controller.status,
                                             pendingID: continuePlayback.pendingDocumentID)
        }
    }

    // MARK: - The loaded book

    func testLoadedPlayingBookPausesInPlace() async throws {
        let h = Harness()
        h.rig.loadDefault()
        h.rig.controller.play()
        try await h.rig.waitUntilPlayingOrSkip()

        h.tap()

        XCTAssertEqual(h.rig.controller.status, .paused, "a pause publishes at once")
        XCTAssertNil(h.continuePlayback.pendingDocumentID)
        XCTAssertEqual(h.gate.calls, 0, "the loaded book is never reloaded")
        XCTAssertEqual(h.loadedIDs, [])
    }

    func testLoadedPausedBookPlays() async throws {
        let h = Harness()
        h.rig.loadDefault(at: 3)
        let mark = h.rig.statuses.count

        h.tap()

        XCTAssertTrue(h.rig.controller.isActive)
        XCTAssertEqual(h.rig.controller.currentSentence, 3, "it plays from where it was cued")
        XCTAssertEqual(h.gate.calls, 0)
        try await h.rig.waitUntilPlayingOrSkip(after: mark)
    }

    // MARK: - A book not loaded yet

    func testUnloadedBookLoadsThenPlays() async throws {
        let h = Harness()
        h.tap()

        XCTAssertEqual(h.continuePlayback.pendingDocumentID, h.rig.document.id, "the tap answers at once")
        XCTAssertNil(h.rig.controller.document)
        XCTAssertEqual(h.effectiveStatus, .buffering, "the card shows the arc while it loads")

        h.gate.open()
        let loaded = await h.rig.waitUntil { h.rig.controller.document?.id == h.rig.document.id }
        XCTAssertTrue(loaded, "the book reaches the controller once the loader returns")
        XCTAssertNil(h.continuePlayback.pendingDocumentID)
        XCTAssertEqual(h.loadedIDs, [h.rig.document.id], "onLoaded fires once")
        XCTAssertEqual(h.failures, 0)
        XCTAssertTrue(h.rig.statuses.contains(.buffering) || h.rig.statuses.contains(.playing))
        try await h.rig.waitUntilPlayingOrSkip()
    }

    func testSecondTapWhileLoadingCancels() async {
        let h = Harness()
        h.tap()
        h.tap()

        XCTAssertNil(h.continuePlayback.pendingDocumentID, "the second tap stops the arc")
        XCTAssertEqual(h.effectiveStatus, .paused)

        h.gate.open()
        // Give the abandoned load time to finish and be ignored.
        _ = await h.rig.waitUntil(0.3) { false }
        XCTAssertNil(h.rig.controller.document, "the late result is ignored")
        XCTAssertEqual(h.loadedIDs, [])
        XCTAssertEqual(h.failures, 0)
        XCTAssertEqual(h.rig.events, [], "nothing was scheduled")
        XCTAssertFalse(h.rig.statuses.contains(.buffering))
    }

    func testLoaderFailureCallsOnFailureOnly() async {
        let h = Harness()
        h.tap()
        h.gate.fail(LoadFailed())

        let failed = await h.rig.waitUntil { h.failures > 0 }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.failures, 1)
        XCTAssertEqual(h.loadedIDs, [])
        XCTAssertNil(h.continuePlayback.pendingDocumentID)
        XCTAssertNil(h.rig.controller.document)
        XCTAssertEqual(h.rig.events, [])
    }

    func testCancellationIsSilent() async {
        let h = Harness()
        h.tap()
        h.gate.fail(CancellationError())

        let cleared = await h.rig.waitUntil { h.continuePlayback.pendingDocumentID == nil }
        XCTAssertTrue(cleared, "a load with nothing to play leaves no arc behind")
        XCTAssertEqual(h.failures, 0, "and reports nothing")
        XCTAssertEqual(h.loadedIDs, [])
    }

    /// The reader opened the book meanwhile and a voice pick is speaking a
    /// sample over its pause (R8): that isn't the book playing, so the tap
    /// still plays it, and the sample carries on as the book.
    func testAVoiceSampleTheReaderStartedMeanwhileStillPlays() async {
        let rig = PlaybackTestRig()
        let continuePlayback = ContinuePlayback()
        continuePlayback.toggle(rig.document, playback: rig.controller, loader: {
            rig.loadDefault(at: 3)
            rig.controller.selectVoice(PlaybackTestRig.voiceB)
            return (rig.document, rig.content)
        })
        let playActions = rig.controller.userPlayAction

        let finished = await rig.waitUntil { continuePlayback.pendingDocumentID == nil }
        XCTAssertTrue(finished)

        XCTAssertEqual(rig.controller.userPlayAction, playActions + 1, "the tap was a Play")
        // A host whose audio engine can't start errors the start; the counter
        // above is the check there.
        guard !rig.statuses.contains(.error) else { return }
        XCTAssertTrue(rig.controller.isListenerPlaying, "the book plays, not a sample")
    }

    // MARK: - Mark as finished and Delete

    /// Mark as finished while the circle's load runs. The load would hand
    /// back the record now Finished, which reopens at its end, and Play from
    /// the end starts at the top: the load stops instead, arc and all.
    func testLettingGoOfALoadingBookStopsItsLoad() async {
        let h = Harness()
        h.tap()
        XCTAssertEqual(h.continuePlayback.pendingDocumentID, h.rig.document.id)

        h.continuePlayback.letGo(of: h.rig.document.id, playback: h.rig.controller)
        XCTAssertNil(h.continuePlayback.pendingDocumentID, "the arc stops at once")
        XCTAssertEqual(h.effectiveStatus, .paused)

        h.gate.open()
        _ = await h.rig.waitUntil(0.3) { false }
        XCTAssertNil(h.rig.controller.document, "the late result is ignored")
        XCTAssertEqual(h.loadedIDs, [])
        XCTAssertEqual(h.failures, 0)
        XCTAssertEqual(h.rig.events, [], "nothing was scheduled")
        XCTAssertEqual(h.rig.progress.count, 0, "no progress write undoes the mark")
    }

    func testLettingGoOfTheLoadedBookUnloadsIt() async throws {
        let h = Harness()
        h.rig.loadDefault(at: 3)
        h.rig.controller.play()
        try await h.rig.waitUntilPlayingOrSkip()

        h.continuePlayback.letGo(of: h.rig.document.id, playback: h.rig.controller)

        XCTAssertNil(h.rig.controller.document)
        XCTAssertEqual(h.rig.controller.status, .idle)
    }

    /// Finishing or deleting another book leaves this one's load alone.
    func testLettingGoOfAnotherBookKeepsTheLoad() async {
        let h = Harness()
        h.tap()

        h.continuePlayback.letGo(of: UUID(), playback: h.rig.controller)
        XCTAssertEqual(h.continuePlayback.pendingDocumentID, h.rig.document.id)

        h.gate.open()
        let loaded = await h.rig.waitUntil { h.rig.controller.document?.id == h.rig.document.id }
        XCTAssertTrue(loaded)
        XCTAssertEqual(h.loadedIDs, [h.rig.document.id])
    }

    /// The shelf's Mark as finished and Delete both go through `letGo`,
    /// before the store changes: a site that only unloaded the player is how
    /// a pending load outlived the mark. A source lint, since neither site
    /// runs without the app.
    func testMarkAsFinishedAndDeleteLetGoFirst() throws {
        let sources = try SourceTree.sources(only: ["Library/LibraryView.swift", "App/AppModel.swift"])
        let library = try XCTUnwrap(sources["Library/LibraryView.swift"])
        let app = try XCTUnwrap(sources["App/AppModel.swift"])
        let perform = try XCTUnwrap(Self.slice(of: library, from: "func perform(_ action: DocumentAction",
                                               to: "\n    }\n"))
        let markFinished = try XCTUnwrap(Self.slice(of: String(perform), from: "case .markFinished:",
                                                    to: "case .delete:"))
        let delete = try XCTUnwrap(Self.slice(of: app, from: "func deleteDocument(", to: "\n    }\n"))
        for (name, body, change) in [("Mark as finished", markFinished, "store.markFinished("),
                                     ("Delete", delete, "documentStore.delete(")] {
            let letGo = try XCTUnwrap(body.range(of: "continuePlayback.letGo(of: document.id"),
                                      "\(name) never lets go")
            let mutation = try XCTUnwrap(body.range(of: change), "\(name) not found")
            XCTAssertLessThan(letGo.lowerBound, mutation.lowerBound, "\(name) lets go before the store changes")
        }
    }

    /// `text` from `start` up to `end`, or nil when either is missing.
    private static func slice(of text: String, from start: String, to end: String) -> Substring? {
        guard let head = text.range(of: start),
              let tail = text[head.upperBound...].range(of: end) else { return nil }
        return text[head.lowerBound..<tail.lowerBound]
    }

    func testReaderThatLoadedTheBookMeanwhileIsNotRestarted() async throws {
        let h = Harness()
        h.tap()
        // The reader opens the same book and starts it while the circle's load runs.
        h.rig.loadDefault()
        h.rig.controller.startAutoplay()
        try await h.rig.waitUntilPlayingOrSkip()
        let mark = h.rig.statuses.count
        let eventMark = h.rig.events.count

        h.gate.open()
        let finished = await h.rig.waitUntil { h.continuePlayback.pendingDocumentID == nil }
        XCTAssertTrue(finished)

        XCTAssertEqual(h.loadedIDs, [h.rig.document.id])
        XCTAssertTrue(h.rig.controller.isActive)
        XCTAssertFalse(h.rig.statuses[mark...].contains(.buffering), "the voice was never restarted")
        XCTAssertFalse(h.rig.events[eventMark...].contains(.stopped), "the schedule was never flushed")
    }
}
