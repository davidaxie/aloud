import AppKit
import XCTest
@testable import Aloud

/// Re-layout anchoring (M15, the Mac's addition) on the book page
/// (`ReaderColumnView`): a window resize, step by step from 1000 to 600 pt
/// as a live resize goes, a resize of both sides at once, Contents docking
/// beside the page, and a text-size step each re-lay the column out, and
/// the page keeps its place. While
/// following, the active sentence keeps its top at the same fraction of the
/// viewport, inside the `FollowBand`; while not following, the reader's
/// first visible line keeps its text and its distance from the top. None of
/// them is a user scroll or a follow scroll, so none detaches following,
/// re-engages it, or spends the R16 budget. And Contents closing puts the
/// keyboard back on the text (M11).
///
/// Each page lives in an offscreen window that is never ordered in, so
/// nothing shows; nothing plays.
@MainActor
final class ReaderRelayoutTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    // MARK: - Following: the voice keeps its place

    /// A live resize from 1000 to 600 pt wide, frame by frame: the column
    /// narrows (627 → 536 pt) and every paragraph re-wraps, yet the active
    /// sentence keeps its fraction of the viewport, in the band, and the
    /// page is still following, with no chip and no follow scroll spent.
    func testAResizeFrom1000To600KeepsTheVoiceInTheBandWhileFollowing() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600))
        let coordinator = page.coordinator
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(page.activeSentenceIsInTheBand(), "a fresh column starts on the voice")
        let fraction = try page.voiceFraction()
        let scrolls = coordinator.programmaticScrollCount
        let columnBefore = try XCTUnwrap(page.textView.textContainer?.size.width)

        for width in stride(from: 950, through: 600, by: -50) {
            page.resize(to: NSSize(width: CGFloat(width), height: 600))
            XCTAssertTrue(coordinator.isFollowing, "\(width) pt: still following")
            XCTAssertTrue(page.activeSentenceIsInTheBand(), "\(width) pt: the voice in the band")
            XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance,
                           "\(width) pt: at the same fraction of the viewport")
        }
        let columnAfter = try XCTUnwrap(page.textView.textContainer?.size.width)
        XCTAssertLessThan(columnAfter, columnBefore - 50, "the column re-laid out narrower")

        // TextKit's further layout passes, and the check's confirmation on
        // laid-out text, leave it there.
        page.settleLayout()
        XCTAssertNil(coordinator.relayoutAnchor, "the anchor's check is over")
        XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance, "after layout settles")
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertNil(coordinator.voiceOffscreen, "no Follow chip")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "a re-layout is never a follow scroll")
    }

    /// Both sides at once, as a window's corner or full screen resizes it,
    /// with the voice low in the band: on the old offset the shorter
    /// viewport would leave it below the band, and the text view taking
    /// its new width asks for a layout pass before the anchor is armed.
    /// That pass never follows: the voice keeps its own fraction, in the
    /// band, with no follow scroll.
    func testAResizeOfBothSidesKeepsTheVoiceWithoutAFollow() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600))
        let coordinator = page.coordinator
        page.settleLayout()   // the opening placement's check is over
        let offset = page.offset
        try page.readOn(toFraction: 0.45)
        XCTAssertEqual(page.offset, offset, accuracy: 0.5, "reading on inside the band never scrolls")
        XCTAssertTrue(page.activeSentenceIsInTheBand())
        let fraction = try page.voiceFraction()
        XCTAssertGreaterThanOrEqual(fraction, 0.45)
        XCTAssertLessThan(fraction, 0.6, "low in the band, a line or two past 0.45")
        let scrolls = coordinator.programmaticScrollCount
        let voice = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertGreaterThan((voice.maxY - page.offset) / 400, FollowBand.bottom,
                             "400 pt tall on the old offset, the voice's foot would be under the band")

        page.resize(to: NSSize(width: 640, height: 400))
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(page.activeSentenceIsInTheBand(), "the voice in the shorter band")
        XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance, "at its own fraction")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "the new size never set off a follow")

        page.settleLayout()
        XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance, "after layout settles")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls)
        XCTAssertNil(coordinator.voiceOffscreen)
    }

    /// A text-size step rebuilds the column at the new size and puts the
    /// voice back at its fraction, still followed.
    func testATextSizeStepKeepsTheVoice() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600))
        let coordinator = page.coordinator
        let fraction = try page.voiceFraction()
        let scrolls = coordinator.programmaticScrollCount
        let offset = page.offset

        page.update(fontSize: ReaderTextSize.points(forStep: ReaderTextSize.defaultStep + 2))
        XCTAssertGreaterThan(coordinator.builtFontSize, 19, "rebuilt at the larger size")
        XCTAssertNotEqual(page.offset, offset, "the page moved to keep the voice")
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(page.activeSentenceIsInTheBand())
        XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance)

        page.settleLayout()
        XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance, "after layout settles")
        XCTAssertNil(coordinator.voiceOffscreen)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "a re-layout is never a follow scroll")
    }

    /// Contents docking beside the page (300 pt off its leading edge) and
    /// leaving again: the page narrows and widens, and the voice keeps its
    /// fraction in the band each time.
    func testADockedContentsPanelKeepsTheVoice() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600), inContainer: true)
        let coordinator = page.coordinator
        let fraction = try page.voiceFraction()
        let scrolls = coordinator.programmaticScrollCount

        page.dockContents(width: MacContentsLayout.panelWidth)
        // A legacy scroller, when the system shows one, takes its own width too.
        let docked = page.scrollView.contentView.bounds.width
        XCTAssertLessThanOrEqual(docked, 1000 - MacContentsLayout.panelWidth, "the page beside the panel")
        XCTAssertGreaterThan(docked, 1000 - MacContentsLayout.panelWidth - 30)
        XCTAssertTrue(coordinator.isFollowing, "docked: still following")
        XCTAssertTrue(page.activeSentenceIsInTheBand())
        XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance, "docked")

        page.dockContents(width: 0)
        XCTAssertTrue(coordinator.isFollowing, "closed: still following")
        XCTAssertTrue(page.activeSentenceIsInTheBand())
        XCTAssertEqual(try page.voiceFraction(), fraction, accuracy: page.tolerance, "closed")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls)
    }

    // MARK: - Not following: the reader keeps their place

    /// The reader scrolled away from the voice: a resize from 1000 to
    /// 600 pt keeps their first visible line (its text, and how far it sits
    /// under the top, clipped as it was), and never re-engages following.
    func testAResizeKeepsTheReadersPlaceWhileNotFollowing() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600))
        let coordinator = page.coordinator
        try page.scrollAway(toSentence: 60)
        let place = try page.firstVisibleLine()

        for width in stride(from: 900, through: 600, by: -100) {
            page.resize(to: NSSize(width: CGFloat(width), height: 600))
            XCTAssertFalse(coordinator.isFollowing, "\(width) pt: a resize never re-engages following")
            XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5,
                           "\(width) pt: the reader's line keeps its place")
        }
        page.settleLayout()
        XCTAssertNil(coordinator.relayoutAnchor, "the anchor's check is over")
        XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5, "after layout settles")
        XCTAssertFalse(coordinator.isFollowing)
        XCTAssertEqual(coordinator.voiceOffscreen, .down, "the chip still points to the voice")
    }

    /// A text-size step while reading elsewhere keeps the reader's line, and
    /// leaves following off.
    func testATextSizeStepKeepsTheReadersPlaceWhileNotFollowing() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600))
        let coordinator = page.coordinator
        try page.scrollAway(toSentence: 60)
        let place = try page.firstVisibleLine()

        page.update(fontSize: ReaderTextSize.points(forStep: ReaderTextSize.defaultStep - 1))
        XCTAssertFalse(coordinator.isFollowing, "a text size never re-engages following")
        XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5)
        page.settleLayout()
        XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5, "after layout settles")
        XCTAssertFalse(coordinator.isFollowing)
    }

    /// Light/dark while reading elsewhere rebuilds the column in its new
    /// colors and puts the reader's line back where it was, on laid-out
    /// text, not by the raw offset over estimated heights (F030).
    func testAnAppearanceChangeKeepsTheReadersPlaceWhileNotFollowing() throws {
        final class Edits: @unchecked Sendable { var count = 0 }
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600))
        let coordinator = page.coordinator
        try page.scrollAway(toSentence: 60)
        let place = try page.firstVisibleLine()
        let edits = Edits()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: page.textView.textStorage,
            queue: nil) { _ in edits.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let look = page.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        page.textView.appearance = NSAppearance(named: look == .darkAqua ? .aqua : .darkAqua)
        coordinator.rebuildForAppearanceChange()
        XCTAssertGreaterThan(edits.count, 0, "rebuilt in the new colors")
        XCTAssertFalse(coordinator.isFollowing, "a change of look never re-engages following")
        XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5, "the reader's line stays")
        page.settleLayout()
        XCTAssertNil(coordinator.relayoutAnchor, "the anchor's check is over")
        XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5, "after layout settles")
        XCTAssertEqual(try page.firstVisibleLine().location, place.location, "the same passage on screen")
    }

    /// Contents docking while reading elsewhere keeps the reader's line.
    func testADockedContentsPanelKeepsTheReadersPlace() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 1000, height: 600), inContainer: true)
        try page.scrollAway(toSentence: 60)
        let place = try page.firstVisibleLine()

        page.dockContents(width: MacContentsLayout.panelWidth)
        XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5, "docked")
        page.dockContents(width: 0)
        XCTAssertEqual(try page.lineTop(of: place.location), place.top, accuracy: 1.5, "closed")
        XCTAssertFalse(page.coordinator.isFollowing)
    }

    // MARK: - The anchor (pure)

    /// The anchor's arithmetic: a voice in the band keeps its own fraction,
    /// one outside it or gliding takes the landing line, and the reader's
    /// line keeps its distance from the top; every offset is clamped to
    /// where the page can rest.
    func testTheAnchorPutsTheTextBack() {
        let range = NSRange(location: 40, length: 12)
        let viewport = CGRect(x: 0, y: 1000, width: 600, height: 500)
        let inBand = CGRect(x: 0, y: 1200, width: 500, height: 40)   // 40% down
        XCTAssertEqual(ReaderRelayoutAnchor.voice(range: range, rect: inBand, in: viewport, isGliding: false).placement,
                       .fraction(0.4))
        XCTAssertEqual(ReaderRelayoutAnchor.voice(range: range, rect: inBand, in: viewport, isGliding: true).placement,
                       .fraction(FollowBand.landing), "a glide was taking it to the landing line")
        let below = CGRect(x: 0, y: 1450, width: 500, height: 40)
        XCTAssertEqual(ReaderRelayoutAnchor.voice(range: range, rect: below, in: viewport, isGliding: false).placement,
                       .fraction(FollowBand.landing), "outside the band: where following puts it")

        let voice = ReaderRelayoutAnchor(range: range, placement: .fraction(0.4))
        XCTAssertEqual(voice.offset(forTop: 3000, viewportHeight: 400, restingRange: 0...10_000), 2840,
                       accuracy: 0.001)
        XCTAssertEqual(voice.offset(forTop: 100, viewportHeight: 400, restingRange: 0...10_000), 0, "clamped at the top")
        XCTAssertEqual(voice.offset(forTop: 3000, viewportHeight: 400, restingRange: 0...2000), 2000, "and at the end")

        let reading = ReaderRelayoutAnchor.reading(range: range, lineTop: 995, viewportTop: 1000)
        XCTAssertEqual(reading.placement, .points(-5), "clipped 5 pt under the top")
        XCTAssertEqual(reading.offset(forTop: 1800, viewportHeight: 300, restingRange: 0...10_000), 1805)
    }

    // MARK: - Keyboard (M11)

    /// Contents closing (a new focus request) puts the keyboard on the
    /// text, a turn later, without moving the page or changing following.
    func testAFocusRequestPutsTheKeyboardOnTheText() throws {
        let page = try makePage(sentences: 120, active: 30, size: NSSize(width: 1000, height: 600))
        _ = page.window.makeFirstResponder(nil)
        XCTAssertFalse(page.window.firstResponder === page.textView)
        let offset = page.offset

        page.update(focusRequest: 1)
        let turn = expectation(description: "a turn of the main queue")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 2)

        XCTAssertTrue(page.window.firstResponder === page.textView, "the text has the keyboard")
        XCTAssertEqual(page.offset, offset, accuracy: 0.5, "taking focus never scrolls")
        XCTAssertTrue(page.coordinator.isFollowing)
    }

    // MARK: - Helpers

    /// One page in its window, and the inputs it was last given.
    @MainActor
    private final class Page {
        let window: NSWindow
        let scrollView: ReaderScrollView
        let coordinator: ReaderColumnView.Coordinator
        private(set) var view: ReaderColumnView

        init(window: NSWindow, scrollView: ReaderScrollView, coordinator: ReaderColumnView.Coordinator,
             view: ReaderColumnView) {
            self.window = window
            self.scrollView = scrollView
            self.coordinator = coordinator
            self.view = view
        }

        var textView: ReaderNSTextView { coordinator.textView! }
        var offset: CGFloat { scrollView.contentView.bounds.origin.y }

        /// A point and a half of the viewport, as a fraction: the clip view
        /// may round an offset to the backing's pixels.
        var tolerance: CGFloat { 1.5 / max(coordinator.viewport()?.height ?? 1, 1) }

        func update(activeSentence: Int? = nil, fontSize: CGFloat? = nil, focusRequest: Int? = nil) {
            view = ReaderColumnView(content: view.content, isChapterBook: view.isChapterBook,
                                    fontSize: fontSize ?? view.fontSize,
                                    activeSentence: activeSentence ?? view.activeSentence,
                                    activeWord: -1, followRequest: view.followRequest,
                                    focusRequest: focusRequest ?? view.focusRequest,
                                    voiceOffscreen: .constant(nil), onPlaySentence: { _ in })
            coordinator.update(to: view)
        }

        /// The voice reads on to the first sentence whose top is at least
        /// `fraction` of the way down the viewport.
        func readOn(toFraction fraction: CGFloat) throws {
            let viewport = try XCTUnwrap(coordinator.viewport())
            var id = view.activeSentence + 1
            while let rect = coordinator.rect(forSentence: id), (rect.minY - viewport.minY) / viewport.height < fraction {
                id += 1
            }
            XCTAssertLessThan(id, view.content.sentences.count, "a sentence that far down")
            update(activeSentence: id)
        }

        /// The window's content resized, as a live resize's frame does; the
        /// tile runs at once.
        func resize(to size: NSSize) {
            window.setContentSize(size)
            scrollView.tile()
        }

        /// Contents docked `width` wide on the page's leading edge (0:
        /// closed), as the screen's leading padding does.
        func dockContents(width: CGFloat) {
            let bounds = scrollView.superview?.bounds ?? .zero
            scrollView.frame = NSRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
            scrollView.tile()
        }

        /// A run of layout passes, as AppKit makes them while TextKit
        /// settles: each one checks the anchor, which ends on confirmed
        /// layout.
        func settleLayout() {
            for _ in 0..<(2 * ReaderFollowEngine.placementPassLimit + 2) {
                textView.needsLayout = true
                textView.layoutSubtreeIfNeeded()
                coordinator.handleLayout()
            }
        }

        /// The active sentence's top as a fraction of the viewport.
        func voiceFraction() throws -> CGFloat {
            let rect = try XCTUnwrap(coordinator.measureActiveSentenceRect())
            let viewport = try XCTUnwrap(coordinator.viewport())
            return (rect.minY - viewport.minY) / viewport.height
        }

        func activeSentenceIsInTheBand() -> Bool {
            guard let rect = coordinator.measureActiveSentenceRect(), let viewport = coordinator.viewport() else {
                return false
            }
            return FollowBand.contains(rect, in: viewport)
        }

        /// A gesture that leaves the page a few points into sentence `id`'s
        /// first line, the voice far below: following stops.
        func scrollAway(toSentence id: Int) throws {
            let rect = try XCTUnwrap(coordinator.rect(forSentence: id))
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: rect.minY + 5))
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            XCTAssertFalse(coordinator.isFollowing, "the gesture took the scroll")
            XCTAssertEqual(coordinator.voiceOffscreen, .down)
        }

        /// The character starting the first visible line, and its line's
        /// top under the viewport's top (less than 0: clipped).
        func firstVisibleLine() throws -> (location: Int, top: CGFloat) {
            let layout = try column()
            let origin = textView.textContainerOrigin
            let location = try XCTUnwrap(layout.characterOffset(at: CGPoint(x: origin.x + 1, y: offset + 1)))
            return (location, try lineTop(of: location))
        }

        /// The top of the line holding `location`, under the viewport's top,
        /// measured as the page measures it: where TextKit has the line now,
        /// as it is drawn.
        func lineTop(of location: Int) throws -> CGFloat {
            let rect = try XCTUnwrap(column().boundingRect(for: NSRange(location: location, length: 1)))
            return rect.minY - offset
        }

        private func column() throws -> ReaderColumnLayout {
            let manager = try XCTUnwrap(textView.textLayoutManager)
            return ReaderColumnLayout(textLayoutManager: manager, origin: textView.textContainerOrigin)
        }
    }

    /// A page in an offscreen window (never ordered in), built, measured and
    /// placed on its active sentence, at 19 pt. `inContainer` puts the
    /// scroll view in a plain view, as the screen's page slot is, so its
    /// frame can move off the window's leading edge.
    private func makePage(sentences: Int, active: Int, size: NSSize, inContainer: Bool = false) throws -> Page {
        let content = Self.content(count: sentences)
        let view = ReaderColumnView(content: content, fontSize: 19, activeSentence: active, activeWord: -1,
                                    voiceOffscreen: .constant(nil), onPlaySentence: { _ in })
        let coordinator = view.makeCoordinator()
        coordinator.reduceMotion = { false }
        coordinator.isCoasting = { _ in false }
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if inContainer {
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = container
            scrollView.frame = container.bounds
            container.addSubview(scrollView)
        } else {
            window.contentView = scrollView
        }
        windows.append(window)

        coordinator.update(to: view)
        coordinator.updateGeometry()
        // TextKit's estimate reaches the end, so the landing isn't clamped.
        _ = coordinator.rect(forSentence: content.sentences.count - 1)
        coordinator.placeActiveSentence()
        // The size the page is placed at, as the first tile records it.
        scrollView.tile()
        XCTAssertEqual(coordinator.placedViewSize, scrollView.contentView.bounds.size)
        return Page(window: window, scrollView: scrollView, coordinator: coordinator, view: view)
    }

    /// `count` sentences of eight words, four to a paragraph, on one page.
    private static func content(count: Int) -> DocContent {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        for start in stride(from: 0, to: count, by: 4) {
            let end = min(start + 4, count)
            paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: start..<end, page: 0))
            for id in start..<end {
                sentences.append(Sentence(id: id, text: "Sentence \(id) reads a few plain words aloud.",
                                          para: paragraphs.count - 1, page: 0))
            }
        }
        return DocContent(title: "Relayout", pageCount: 1, sentences: sentences, paragraphs: paragraphs,
                          contentHash: "mac-relayout-\(count)")
    }
}
