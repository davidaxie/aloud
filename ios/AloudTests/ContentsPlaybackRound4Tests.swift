import XCTest
@testable import Aloud

/// iPhone critique round 4, Contents and playback: the whole book's time
/// left (R4-29), the current row said once (R4-32) and a cold Play's claim
/// off the main actor (R4-33), on both apps. The sheet's own view glue is
/// held in ContentsSheetLintTests; the Low Power look-ahead (R4-34) in
/// ThermalGuardTests and CatchingUpTests.
@MainActor
final class ContentsPlaybackRound4Tests: XCTestCase {

    // MARK: - R4-29: the book's time left

    private static let minute = Array(repeating: "word", count: 165).joined(separator: " ")

    /// Five chapters ("I" to "V"), each a one-word heading and ten
    /// one-minute sentences on its own page; or, `chaptered` false, the
    /// same sentences with no headings on one page, since text makes a
    /// chapter of each page.
    private static func book(chaptered: Bool = true) -> DocContent {
        var sentences: [Sentence] = []
        for (number, heading) in ["I", "II", "III", "IV", "V"].enumerated() {
            if chaptered {
                sentences.append(Sentence(id: sentences.count, text: heading, para: sentences.count, page: number + 1))
            }
            for _ in 0..<10 {
                sentences.append(Sentence(id: sentences.count, text: minute, para: sentences.count,
                                           page: chaptered ? number + 1 : 1))
            }
        }
        return DocContent(title: "Test", pageCount: chaptered ? 5 : 1, sentences: sentences, paragraphs: [],
                          contentHash: "r4")
    }

    func testTheBooksTimeLeftCountsToTheEndOfTheBook() {
        let navigation = ReaderNavigation(content: Self.book(), kind: .text)
        XCTAssertTrue(navigation.isChaptered)
        let start = navigation.chapters[2].startSentence + 1   // Chapter III's first body sentence
        // 30 minutes left of the book at 1×, of which 10 are in this chapter.
        XCTAssertEqual(navigation.bookMinutesLeft(at: start, rate: 1, isFinished: false), 30)
        XCTAssertEqual(navigation.positionLine(at: start, rate: 1, documentTitle: "Test").minutesLeft, 10,
                       "the chapter line still counts to the chapter's end")
        XCTAssertEqual(navigation.bookMinutesLeft(at: start, rate: 2, isFinished: false), 15, "rate-aware")
        XCTAssertEqual(navigation.bookMinutesLeft(at: 0, rate: 1.5, isFinished: false),
                       ListeningEstimate.minutes(words: 50 * 165 + 5, wordsPerMinute: 165 * 1.5))
        XCTAssertNil(navigation.bookMinutesLeft(at: start, rate: 1, isFinished: true), "finished: no line")
        XCTAssertEqual(ContentsSearch.bookLeftCaption(minutes: 192), "3 hr 12 min left in the book")
        XCTAssertEqual(ContentsSearch.bookLeftSpoken(minutes: 192), "3 hours 12 minutes left in the book")
        XCTAssertTrue(ContentsSearch.showsBookLeft(query: ""))
        XCTAssertTrue(ContentsSearch.showsBookLeft(query: " \n"))
        XCTAssertFalse(ContentsSearch.showsBookLeft(query: "Lucca"), "hidden while results show")
    }

    /// Where the chapter line already counts to the end there is no second
    /// line: text without a chapter list, and page-range PDFs.
    func testNoLineWhereTheChapterLineCountsToTheEnd() {
        let chapterless = ReaderNavigation(content: Self.book(chaptered: false), kind: .text)
        XCTAssertEqual(chapterless.chapters.count, 1, "one page, one chapter")
        XCTAssertFalse(chapterless.isChaptered)
        XCTAssertNil(chapterless.bookMinutesLeft(at: 3, rate: 1, isFinished: false))
        // Five pages, so five page rows: a list, but of pages, not chapters.
        let pages = ReaderNavigation(content: Self.book(), kind: .pdf)
        XCTAssertTrue(pages.hasChapterList)
        XCTAssertFalse(pages.isChaptered)
        XCTAssertNil(pages.bookMinutesLeft(at: 3, rate: 1, isFinished: false))
        let empty = DocContent(title: "Empty", pageCount: 0, sentences: [], paragraphs: [], contentHash: "e")
        XCTAssertNil(ReaderNavigation(content: empty, kind: .text).bookMinutesLeft(at: 0, rate: 1, isFinished: false))
    }

    /// The iPhone's line costs a caption's height over the field, so at
    /// half height on the shortest screens, over a stop above the chapters,
    /// it waits for the sheet to grow, as the earlier-stops toggle does,
    /// and the first chapter still starts above the fold (P024). Anywhere
    /// with room, it shows.
    func testTheLineWaitsForTheSheetOnlyWhereTheFoldIsTight() {
        let se = 330.0, mini = 400.0
        func shows(chapters: Bool = true, stops: Bool = true, half: Bool = true,
                   height: Double? = se, ax: Bool = false) -> Bool {
            PlaceHistory.showsBookLeft(hasChapterList: chapters, hasStops: stops, atHalfHeight: half,
                                       shortSheet: height.map { PlaceHistory.isShortSheet(height: $0) },
                                       accessibilitySize: ax)
        }
        XCTAssertFalse(shows(), "an SE's half height, a stop over the chapters: the sheet grows first")
        XCTAssertTrue(shows(height: mini), "a mini's half height has the room")
        XCTAssertTrue(shows(half: false), "grown, it shows")
        XCTAssertTrue(shows(stops: false), "no stop: the chapters follow the field")
        XCTAssertTrue(shows(ax: true), "the accessibility sizes: one stop already fills the fold")
        XCTAssertTrue(shows(height: nil), "not yet measured")
        XCTAssertTrue(shows(chapters: false), "no chapter list to keep above the fold")
        XCTAssertGreaterThan(PlaceHistory.bookLeftHalfHeightMinimum, se)
        XCTAssertLessThan(PlaceHistory.bookLeftHalfHeightMinimum, mini)
    }

    /// The card's "left" for the same place and speed: `wordCount` less the
    /// controller's word-weighted fraction, rounded through seconds.
    private static func cardMinutesLeft(_ content: DocContent, at sentence: Int, rate: Double) -> Int? {
        var document = PlaybackTestRig.makeDocument(hash: content.contentHash, sentences: content.sentences.count)
        document.wordCount = content.wordCount
        document.progressSentence = sentence
        document.progressFraction = PlaybackController.positionFraction(
            of: sentence, wordsBefore: content.navigationIndex().wordsBefore, sentenceCount: content.sentences.count)
        guard case .left(let minutes) = document.shelfStatus(rate: rate) else { return nil }
        return minutes
    }

    /// Contents' line and the Library card agree on a mid-book place at
    /// 1.5× (R4-29 (4)): within a minute, the card's rounding apart.
    func testTheLineAgreesWithTheLibraryCard() throws {
        let content = Self.book()
        let navigation = ReaderNavigation(content: content, kind: .text)
        let mid = content.sentences.count / 2 + 3
        let line = try XCTUnwrap(navigation.bookMinutesLeft(at: mid, rate: 1.5, isFinished: false))
        let card = try XCTUnwrap(Self.cardMinutesLeft(content, at: mid, rate: 1.5))
        XCTAssertLessThanOrEqual(abs(line - card), 1, "Contents says \(line), the card \(card)")
    }

    /// The same on a bundled chaptered classic, mid-book at 1.5×. Slow (it
    /// extracts the whole book); skipped where the shelf isn't bundled.
    func testOnABundledClassicTheLineAgreesWithTheCard() async throws {
        let catalog = BookshelfCatalog.load(from: .main)
        guard let book = catalog.first(where: { $0.gutenbergID == 1342 }) ?? catalog.first,
              let url = BookshelfCatalog.bundledURL(for: book) else {
            throw XCTSkip("no Bookshelf book is bundled in this build")
        }
        let content = try await ExtractionPipeline().extractText(fileURL: url, title: book.title, progress: nil)
        let navigation = ReaderNavigation(content: content, kind: .text)
        try XCTSkipUnless(navigation.isChaptered, "\(book.title) has no chapter list")
        let mid = content.sentences.count / 2
        let line = try XCTUnwrap(navigation.bookMinutesLeft(at: mid, rate: 1.5, isFinished: false))
        let chapter = try XCTUnwrap(navigation.positionLine(at: mid, rate: 1.5, documentTitle: book.title).minutesLeft)
        XCTAssertGreaterThan(line, chapter, "the book's time left outruns the chapter's")
        let card = try XCTUnwrap(Self.cardMinutesLeft(content, at: mid, rate: 1.5))
        XCTAssertLessThanOrEqual(abs(line - card), 1, "\(book.title): Contents says \(line), the card \(card)")
    }

    // MARK: - R4-32: said once

    /// The iPhone's rows leave "current" to their `.isSelected` trait and
    /// still spell out their time; the Mac's announced forms keep it.
    func testTheIPhoneRowLabelsLeaveTheStateToTheTrait() {
        let row = ContentsSearch.chapterRowLabel(title: "CHAPTER I", minutes: 72)
        XCTAssertEqual(row, "CHAPTER I, 1 hour 12 minutes")
        XCTAssertFalse(row.contains("current"))
        XCTAssertNil(row.range(of: #"\b(min|hr)\b"#, options: .regularExpression), row)
        XCTAssertEqual(ContentsSearch.chapterAccessibilityLabel(title: "CHAPTER I", minutes: 72, isCurrent: true),
                       row + ", current", "the Mac's announcement keeps the state")

        let place = PlaceRow(index: 0, sentence: 3, when: "Yesterday, 10:41 PM", location: "CHAPTER THREE",
                             text: "Come in.", isCurrent: true)
        XCTAssertEqual(place.rowLabel, "Yesterday, 10:41 PM, CHAPTER THREE, Come in.")
        XCTAssertFalse(place.rowLabel.hasSuffix(", current"))
        XCTAssertEqual(place.accessibilityLabel, place.rowLabel + ", current")
    }

    // MARK: - R4-33: the claim off the main actor

    /// Stands in for the session's claim, counting it; `held` keeps it
    /// waiting (until released or cancelled), `error` refuses it.
    @MainActor
    final class ClaimProbe {
        var claims = 0
        var held = false
        var error: (any Error)?

        func claim() async throws {
            claims += 1
            while held { try await Task.sleep(nanoseconds: 10_000_000) }
            if let error { throw error }
        }
    }

    /// A rig whose controller claims through `probe`, on its idle clock.
    /// Offline (the Mac's muted rig) there is no session to claim.
    private func makeRig() throws -> (PlaybackTestRig, ClaimProbe, IdleStopClock) {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 1)
        try XCTSkipIf(rig.controller.rendersOffline, "offline there is no session to claim")
        let probe = ClaimProbe()
        rig.controller.claimAudioOutput = { try await probe.claim() }
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.loadDefault(at: 3)
        return (rig, probe, clock)
    }

    private func elapse(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A cold Play claims once, off the main actor, and starts the engine
    /// once, with no second claim in place; after the idle stop's release
    /// the next Play claims again the same way.
    func testAColdPlayAwaitsOneClaimAndStartsOnce() async throws {
        let (rig, probe, clock) = try makeRig()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(probe.claims, 1)
        XCTAssertEqual(rig.audioSession.activations, 0, "no second claim in place")
        XCTAssertEqual(rig.audioSession.bindings, 1, "the engine started once")

        rig.controller.pause()
        clock.advance(by: try XCTUnwrap(PlatformTuning.idleEngineStopDelay))
        XCTAssertEqual(rig.audioSession.deactivations, 1, "the idle stop gives the session back")
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(probe.claims, 2, "a cold Play again")
        XCTAssertEqual(rig.audioSession.activations, 0)
        rig.controller.pause()
    }

    /// Paused while the claim is still on its way: the claim is cancelled
    /// and the session given back, and nothing starts behind the pause.
    func testAPauseBeforeTheFirstClipCancelsTheClaimAndReleasesTheSession() async throws {
        let (rig, probe, _) = try makeRig()
        probe.held = true
        rig.controller.play()
        let claiming = await rig.waitUntil { probe.claims == 1 }
        XCTAssertTrue(claiming)
        await elapse(0.2)   // the first clip is made meanwhile, and waits
        XCTAssertEqual(rig.controller.status, .buffering, "the busy ring, not a frozen one")

        rig.controller.pause()
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.audioSession.deactivations, 1, "the session goes with the claim")
        probe.held = false
        await elapse(0.3)
        XCTAssertFalse(rig.controller.isEngineRunning, "nothing starts behind the pause")
        XCTAssertEqual(rig.audioSession.bindings, 0)
        XCTAssertEqual(rig.audioSession.activations, 0)
        XCTAssertEqual(rig.controller.status, .paused)

        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(probe.claims, 2, "Play claims again")
        rig.controller.pause()
    }

    /// A call holding the audio refuses the claim: the start pauses as
    /// interrupted, never failed, and the engine never starts.
    func testAHeldElsewhereClaimPausesAsInterrupted() async throws {
        let (rig, probe, _) = try makeRig()
        probe.error = AudioOutputHeldElsewhere()
        // Only what Play leads to: a loaded book starts out paused.
        let mark = rig.statuses.count
        rig.controller.play()
        let settled = await rig.waitUntil {
            let after = rig.statuses.dropFirst(mark)
            return after.contains(.paused) || after.contains(.error)
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(rig.controller.status, .paused, "an interruption, not a failure")
        XCTAssertEqual(rig.controller.stopped, PlaybackStop(reason: .interrupted, documentID: rig.document.id))
        XCTAssertFalse(rig.controller.isEngineRunning)
        XCTAssertEqual(rig.audioSession.bindings, 0)
    }

    /// Any other refusal doesn't block playback, as a claim in place never
    /// did, and the start uses the claim's result: no second activation on
    /// the main actor, which would freeze the ring on the failure it just had.
    func testAnOtherClaimFailurePlaysWithoutASecondClaim() async throws {
        let (rig, probe, _) = try makeRig()
        probe.error = NSError(domain: "AloudTests.claim", code: 1)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(probe.claims, 1)
        XCTAssertEqual(rig.audioSession.activations, 0, "no second claim in place")
        XCTAssertEqual(rig.audioSession.bindings, 1, "the engine started once")
        XCTAssertEqual(rig.controller.status, .playing)
        rig.controller.pause()
    }

    /// R1-40 unchanged: a resume inside the idle window keeps the session
    /// it holds and claims nothing.
    func testAResumeInsideTheIdleWindowMakesNoClaim() async throws {
        let (rig, probe, clock) = try makeRig()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(probe.claims, 1)
        rig.controller.pause()
        XCTAssertEqual(clock.pendingCount, 1, "inside the idle window")
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(probe.claims, 1, "the resume keeps the session it holds")
        XCTAssertEqual(rig.audioSession.activations, 0)
        XCTAssertEqual(rig.audioSession.deactivations, 0)
        rig.controller.pause()
    }
}
