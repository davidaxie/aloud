import AppKit
import SwiftUI
import XCTest
@testable import Aloud

/// Contents beside the page (M16): where the panel sits, what its rows say,
/// what its keys do, and that a row's jump is the shared one, on a muted
/// rig's controller.
@MainActor
final class MacContentsPanelTests: XCTestCase {

    // MARK: - Docked or overlaid

    func testThePanelDocksFrom780AndFloatsBelow() {
        XCTAssertEqual(MacContentsLayout.panelWidth, 300)
        XCTAssertEqual(MacContentsLayout.dockingWidth, 780, "the panel plus the 480 reading minimum")
        XCTAssertEqual(MacContentsLayout(windowWidth: 780), .docked)
        XCTAssertEqual(MacContentsLayout(windowWidth: 1200), .docked)
        XCTAssertEqual(MacContentsLayout(windowWidth: 779.5), .overlaid)
        XCTAssertEqual(MacContentsLayout(windowWidth: 600), .overlaid)
    }

    func testADockedPanelMovesThePageAndACardFloatsOverIt() {
        XCTAssertEqual(MacContentsLayout.docked.pageInset, 300, "the page re-centers in what is left")
        XCTAssertEqual(MacContentsLayout.overlaid.pageInset, 0)
        XCTAssertFalse(MacContentsLayout.docked.closesAfterJump, "docked, the list stays for the next step")
        XCTAssertTrue(MacContentsLayout.overlaid.closesAfterJump, "a card uncovers the page it moved")
    }

    // MARK: - Chapters

    func testRowsCarryTitlesDurationsAndTheCurrentChapter() {
        let navigation = ReaderNavigation(content: Self.chaptered(), kind: .text)
        let playhead = navigation.chapters[1].startSentence + 3
        let rows = MacContents.chapterRows(navigation, playhead: playhead, rate: 1)

        XCTAssertEqual(rows.map(\.title), ["CHAPTER I", "CHAPTER II", "CHAPTER III"])
        // 332, 662 and 143 words at 165 a minute.
        XCTAssertEqual(rows.map(\.minutes), [2, 4, 1])
        XCTAssertEqual(rows.map(\.estimate), ["2 min", "4 min", "1 min"])
        XCTAssertEqual(rows.map(\.isCurrent), [false, true, false], "the playhead's chapter, only")
        XCTAssertEqual(rows.map(\.isCompleted), [true, false, false], "chapters before it mute")
        XCTAssertEqual(rows.map(\.startSentence), navigation.chapters.map(\.startSentence))
        XCTAssertEqual(rows.map(\.identifier), ["chapters.row.1", "chapters.row.2", "chapters.row.3"],
                       "the iPhone's identifiers")
        XCTAssertEqual(rows[1].accessibilityLabel,
                       ContentsSearch.chapterAccessibilityLabel(title: "CHAPTER II", minutes: 4, isCurrent: true))
        XCTAssertTrue(rows[1].accessibilityLabel.hasSuffix(", current"))
        XCTAssertFalse(rows[0].accessibilityLabel.hasSuffix(", current"))
    }

    func testDurationsFollowTheRate() {
        let navigation = ReaderNavigation(content: Self.chaptered(), kind: .text)
        let rows = MacContents.chapterRows(navigation, playhead: 0, rate: 2)
        XCTAssertEqual(rows.map(\.minutes), [1, 2, 1], "at 2× a chapter takes half as long")
        XCTAssertEqual(rows.map(\.isCurrent), [true, false, false])
        XCTAssertEqual(rows.map(\.isCompleted), [false, false, false])
    }

    /// R4-29: under the title, the whole book's time left at the speed,
    /// from the iPhone's helper; none over a search, once finished, or in
    /// a book whose chapter line already counts to its end.
    func testTheTitleSaysHowMuchOfTheBookIsLeft() {
        let navigation = ReaderNavigation(content: Self.chaptered(), kind: .text)
        // 1,137 words at 165 a minute; at 2× half that.
        XCTAssertEqual(MacContents.bookMinutesLeft(navigation, playhead: 0, rate: 1, isFinished: false, query: ""), 7)
        XCTAssertEqual(MacContents.bookMinutesLeft(navigation, playhead: 0, rate: 2, isFinished: false, query: ""), 3)
        let mid = navigation.chapters[1].startSentence
        XCTAssertEqual(MacContents.bookMinutesLeft(navigation, playhead: mid, rate: 1, isFinished: false, query: ""),
                       navigation.bookMinutesLeft(at: mid, rate: 1, isFinished: false), "the shared helper")
        XCTAssertEqual(ContentsSearch.bookLeftCaption(minutes: 7), "7 min left in the book")
        XCTAssertEqual(ContentsSearch.bookLeftSpoken(minutes: 7), "7 minutes left in the book")
        XCTAssertNil(MacContents.bookMinutesLeft(navigation, playhead: 0, rate: 1, isFinished: false, query: "Lucca"),
                     "never over a search's results")
        XCTAssertEqual(MacContents.bookMinutesLeft(navigation, playhead: 0, rate: 1, isFinished: false, query: "  "), 7,
                       "a blank query is the list")
        XCTAssertNil(MacContents.bookMinutesLeft(navigation, playhead: 0, rate: 1, isFinished: true, query: ""))
        let chapterless = ReaderNavigation(content: Self.chapterless(), kind: .text)
        XCTAssertNil(MacContents.bookMinutesLeft(chapterless, playhead: 0, rate: 1, isFinished: false, query: ""))
    }

    // MARK: - What shows

    func testABookWithoutChaptersShowsSearchOnly() {
        let chapterless = ReaderNavigation(content: Self.chapterless(), kind: .text)
        XCTAssertFalse(chapterless.hasChapterList)
        XCTAssertEqual(MacContents.mode(hasChapterList: chapterless.hasChapterList, query: "",
                                        searchedQuery: nil, resultCount: 0), .searchOnly)
        XCTAssertEqual(MacContents.mode(hasChapterList: chapterless.hasChapterList, query: "trowel",
                                        searchedQuery: "trowel", resultCount: 2), .results,
                       "its search still answers")

        let chaptered = ReaderNavigation(content: Self.chaptered(), kind: .text)
        XCTAssertEqual(MacContents.mode(hasChapterList: chaptered.hasChapterList, query: "",
                                        searchedQuery: nil, resultCount: 0), .chapters)
    }

    func testTypingReplacesTheListOnceTheScanLands() {
        XCTAssertEqual(MacContents.mode(hasChapterList: true, query: "  ", searchedQuery: nil, resultCount: 0),
                       .chapters, "blank is no query")
        XCTAssertEqual(MacContents.mode(hasChapterList: true, query: "rain", searchedQuery: nil, resultCount: 0),
                       .searching, "no \"No matches\" before the first scan")
        XCTAssertEqual(MacContents.mode(hasChapterList: true, query: "rain", searchedQuery: "rain", resultCount: 0),
                       .noMatches("rain"))
        XCTAssertEqual(MacContents.mode(hasChapterList: true, query: "rains", searchedQuery: "rain", resultCount: 3),
                       .results, "the last answer holds until the next lands")
        XCTAssertEqual(MacContents.countLabel(1), "1 match")
        XCTAssertEqual(MacContents.countLabel(12), "12 matches")
        XCTAssertEqual(MacContents.noMatchesLabel("zebra"), "No matches for \u{201C}zebra\u{201D}")
        XCTAssertEqual(MacContents.searchPrompt, "Search this book")
        XCTAssertEqual(MacContents.debounceNanoseconds, 200_000_000, "the iPhone's 200 ms")
    }

    func testResultsNameTheirChapterAndCutBeforeTheHit() throws {
        let content = Self.chaptered()
        let navigation = ReaderNavigation(content: content, kind: .text)
        let matches = content.matches(of: "amontillado")
        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(navigation.qualifiedTitle(forPage: match.page), "CHAPTER III")
        let snippet = ContentsSearch.snippet(for: match, leadLimit: MacContents.leadLimit)
        XCTAssertEqual(snippet.hit, "Amontillado")
        XCTAssertLessThanOrEqual(snippet.lead.count, MacContents.leadLimit + 1, "the hit is on the first line")
    }

    /// R3-13: quotes from the book (place snippets, results) are set in the
    /// reading serif a point over the ramp's sans body in every band, the
    /// details staying in the sans footnote.
    func testQuotesFromTheBookAreSetInTheReadingSerif() {
        for scale in ChromeScale.allCases {
            let size = PlatformTypeRamp.points(.body, scale: scale) + 1
            XCTAssertEqual(Theme.excerpt(scale: scale), .custom(Theme.serifFamilyName, fixedSize: size), "\(scale)")
            XCTAssertEqual(Theme.excerpt(scale: scale, boldText: true), Theme.excerpt(scale: scale),
                           "the Mac has no Bold Text")
            XCTAssertNotEqual(Theme.excerpt(scale: scale), Theme.font(.body, scale: scale), "not the sans body")
        }
        XCTAssertEqual(Theme.excerpt(), Theme.excerpt(scale: .standard))
    }

    /// The serif is wider than the sans: a result's lead and hit still fit
    /// the row's first line in every band (the panel's 300 pt less the
    /// row's insets).
    func testTheHitStaysOnTheFirstLineInTheSerif() throws {
        let content = Self.chaptered()
        let match = try XCTUnwrap(content.matches(of: "amontillado").first)
        let snippet = ContentsSearch.snippet(for: match, leadLimit: MacContents.leadLimit)
        XCTAssertFalse(snippet.lead.isEmpty, "the fixture keeps a lead")
        let width = MacContentsLayout.panelWidth - 2 * (Theme.Space.xs + Theme.Space.sm)
        func height(_ text: String, _ scale: ChromeScale) -> CGFloat {
            NSHostingView(rootView: Text(text).font(Theme.excerpt(scale: scale))
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true))
                .fittingSize.height
        }
        for scale in ChromeScale.allCases {
            XCTAssertEqual(height(snippet.lead + snippet.hit, scale), height(snippet.hit, scale), accuracy: 0.5,
                           "\(scale): \"\(snippet.lead + snippet.hit)\" should fit the first line")
        }
    }

    /// R3-13 review: with the semibold gone the hit's tint was its only
    /// cue, so under Differentiate Without Color it is underlined too, as
    /// on the iPhone (P032): the underline draws, and the snippet keeps its
    /// size in every band so the hit stays on line one.
    func testUnderDifferentiateWithoutColorTheHitIsUnderlinedTooAtTheSameSize() throws {
        let content = Self.chaptered()
        let match = try XCTUnwrap(content.matches(of: "amontillado").first)
        let snippet = ContentsSearch.snippet(for: match, leadLimit: MacContents.leadLimit)
        let width = MacContentsLayout.panelWidth - 2 * (Theme.Space.xs + Theme.Space.sm)
        func label(_ underlined: Bool, _ scale: ChromeScale) -> some View {
            MacContentsResultLabel.emphasized(snippet, underlined: underlined)
                .font(Theme.excerpt(scale: scale))
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        func pixels(_ underlined: Bool) -> Data? {
            let renderer = ImageRenderer(content: label(underlined, .standard)
                .frame(height: 80, alignment: .topLeading)
                .background(Color.white)
                .environment(\.colorScheme, .light))
            renderer.scale = 2
            return renderer.cgImage?.dataProvider?.data as Data?
        }
        let plain = try XCTUnwrap(pixels(false), "the plain snippet draws")
        XCTAssertEqual(plain, pixels(false), "the render is deterministic")
        XCTAssertNotEqual(plain, pixels(true), "the underline draws")
        for scale in ChromeScale.allCases {
            XCTAssertEqual(NSHostingView(rootView: label(true, scale)).fittingSize,
                           NSHostingView(rootView: label(false, scale)).fittingSize, "\(scale)")
        }
    }

    /// In a book without chapters every hit would name the same derived
    /// chapter (its first sentence), so a result has no location line; a
    /// chaptered book's hits still name theirs (F040).
    func testAChapterlessBooksResultsHaveNoLocation() throws {
        let chapterless = Self.chapterless()
        let flat = ReaderNavigation(content: chapterless, kind: .text)
        let hits = chapterless.matches(of: "the")
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            XCTAssertNil(flat.searchLocation(ofSentence: hit.sentenceID, page: hit.page),
                         "sentence \(hit.sentenceID) names a chapter the book doesn't have")
        }
        let chaptered = Self.chaptered()
        let navigation = ReaderNavigation(content: chaptered, kind: .text)
        let match = try XCTUnwrap(chaptered.matches(of: "amontillado").first)
        XCTAssertEqual(navigation.searchLocation(ofSentence: match.sentenceID, page: match.page), "CHAPTER III")
    }

    /// The panel's count and no-matches copy are the shared lines VoiceOver
    /// hears as a search lands, once per changed count, through the one
    /// announcement path (F041).
    func testALandedSearchIsAnnouncedThroughTheSharedLines() {
        XCTAssertEqual(MacContents.countLabel(3), ContentsSearch.countLabel(3))
        XCTAssertEqual(MacContents.noMatchesLabel("cask"), ContentsSearch.noMatchesLabel("cask"))
        #if DEBUG
        let log = UITestAnnouncementLog.shared
        log.reset()
        ContentsSearch.announceResults(count: 2, query: "cask", previousCount: nil, muted: true)
        XCTAssertEqual(log.entries, [MacContents.countLabel(2)])
        ContentsSearch.announceResults(count: 2, query: "cask ", previousCount: 2, muted: true)
        XCTAssertEqual(log.entries, [MacContents.countLabel(2)], "the same count says nothing more")
        ContentsSearch.announceResults(count: 0, query: "caskx", previousCount: 2, muted: true)
        XCTAssertEqual(log.entries.last, MacContents.noMatchesLabel("caskx"))
        log.reset()
        #endif
    }

    // MARK: - Keys

    /// The keyboard's cursor is a ring VoiceOver can't see, over a list
    /// that is one element: each row it lands on (↓ from the field, ↑/↓)
    /// is said by the row's own label, at once, through the shared log;
    /// muted, nothing is spoken (H024).
    func testTheCursorsRowIsSaidAsItLands() throws {
        let chaptered = Self.chaptered()
        let navigation = ReaderNavigation(content: chaptered, kind: .text)
        let place = PlaceRow(index: 0, sentence: 3, when: "Yesterday, 10:41 PM", location: "CHAPTER I",
                             text: "It was a dark night.", isCurrent: false)
        func label(_ row: MacContents.ListRow?, expanded: Bool = false) -> String? {
            MacContents.cursorLabel(row, places: [place], earlier: 3, expanded: expanded,
                                    navigation: navigation, current: 1, rate: 1)
        }
        XCTAssertEqual(label(.place(0)), place.accessibilityLabel)
        XCTAssertEqual(label(.showEarlier), PlaceHistoryCopy.showEarlier(3))
        XCTAssertEqual(label(.showEarlier, expanded: true), PlaceHistoryCopy.showFewer)
        XCTAssertEqual(label(.chapter(1)),
                       MacContents.chapterRow(navigation, index: 1, current: 1, rate: 1).accessibilityLabel)
        XCTAssertNil(label(.chapter(9)))
        XCTAssertNil(label(.place(4)))
        XCTAssertNil(label(nil))

        let match = try XCTUnwrap(chaptered.matches(of: "amontillado").first)
        XCTAssertEqual(MacContents.resultLabel(match, location: "CHAPTER III"),
                       ReaderTypography.typeset(match.text) + ", CHAPTER III")
        XCTAssertEqual(MacContents.resultLabel(match, location: nil), ReaderTypography.typeset(match.text))

        #if DEBUG
        let log = UITestAnnouncementLog.shared
        log.reset()
        MacContents.announceCursor(place.accessibilityLabel, muted: true)
        XCTAssertEqual(log.entries, [place.accessibilityLabel])
        log.reset()
        #endif
    }

    func testArrowsWalkTheRowsAndUpLeavesForTheField() {
        XCTAssertEqual(MacContents.step(nil, by: 1, count: 5), .row(0))
        XCTAssertEqual(MacContents.step(2, by: 1, count: 5), .row(3))
        XCTAssertEqual(MacContents.step(2, by: -1, count: 5), .row(1))
        XCTAssertEqual(MacContents.step(4, by: 1, count: 5), .row(4), "the last row holds")
        XCTAssertEqual(MacContents.step(0, by: -1, count: 5), .field, "up off the top: the search field")
        XCTAssertEqual(MacContents.step(nil, by: -1, count: 5), .field)
        XCTAssertEqual(MacContents.step(nil, by: 1, count: 0), .field, "no rows to walk")
    }

    /// A scan landing while ↓ has the list on the previous query's results
    /// moves the cursor to the top result (which is then said), or, with
    /// nothing found, back to the field: Return never opens a result
    /// VoiceOver didn't read (L024). With the field holding the keyboard,
    /// nothing moves.
    func testALandingScanMovesAListCursorOntoWhatLanded() {
        XCTAssertEqual(MacContents.cursorAfterScan(listFocused: true, found: 3), .row(0))
        XCTAssertEqual(MacContents.cursorAfterScan(listFocused: true, found: 0), .field)
        XCTAssertNil(MacContents.cursorAfterScan(listFocused: false, found: 3))
        XCTAssertNil(MacContents.cursorAfterScan(listFocused: false, found: 0))
    }

    func testEscClearsTheSearchThenCloses() {
        XCTAssertEqual(MacContents.escape(query: "cask"), .clearSearch)
        XCTAssertEqual(MacContents.escape(query: " "), .clearSearch)
        XCTAssertEqual(MacContents.escape(query: ""), .close)
    }

    func testTheFieldTakesReturnAndEscAndLeavesTheRest() {
        XCTAssertEqual(MacContentsFieldKey(selector: #selector(NSResponder.insertNewline(_:))), .submit)
        XCTAssertEqual(MacContentsFieldKey(selector: #selector(NSResponder.cancelOperation(_:))), .escape)
        XCTAssertNil(MacContentsFieldKey(selector: #selector(NSResponder.moveDown(_:))),
                     "↓ is the router's handoff, then the field's")
        XCTAssertNil(MacContentsFieldKey(selector: #selector(NSResponder.moveLeft(_:))))
        XCTAssertNil(MacContentsFieldKey(selector: #selector(NSResponder.insertTab(_:))))

        var submits = 0
        var escapes = 0
        let field = MacContentsSearchField(text: .constant("cask"), focusRequest: 0, fontSize: 13,
                                           onSubmit: { submits += 1 }, onEscape: { escapes += 1 })
        let coordinator = MacContentsSearchField.Coordinator(parent: field)
        let control = NSSearchField()
        let editor = NSTextView()
        XCTAssertTrue(coordinator.control(control, textView: editor,
                                          doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                      "Esc is handled: never a beep")
        XCTAssertEqual(escapes, 1)
        XCTAssertTrue(coordinator.control(control, textView: editor,
                                          doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submits, 1)
        XCTAssertFalse(coordinator.control(control, textView: editor,
                                           doCommandBy: #selector(NSResponder.moveLeft(_:))),
                       "the caret's moves are the field's")
        XCTAssertFalse(coordinator.control(control, textView: editor,
                                           doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: Selector(("noop:"))),
                      "an unbound key ends at the field, silently")
        XCTAssertTrue(coordinator.control(control, textView: editor,
                                          doCommandBy: Selector(("aloudNoSuchCommand:"))),
                      "a command the field editor can't run ends there too, never at the alert sound")
        XCTAssertEqual(escapes + submits, 2)
    }

    /// The router knows the field for a search field, so ↓ there is offered
    /// to the list (`MacSearchHandoff`).
    func testTheFieldIsASearchFieldToTheKeyRouter() {
        let window = makeWindow()
        let field = MacContentsSearchFieldView(frame: NSRect(x: 16, y: 40, width: 268, height: 28))
        window.contentView?.addSubview(field)
        field.requestFocus()
        XCTAssertTrue(MacKeyRouter.isSearchFieldEditor(window.firstResponder))
    }

    /// ⌘F opening the panel asks before the field is in a window; it takes
    /// the caret as it arrives.
    func testAFocusRequestBeforeTheWindowLandsOnArrival() {
        let window = makeWindow()
        let field = MacContentsSearchFieldView(frame: NSRect(x: 16, y: 40, width: 268, height: 28))
        field.requestFocus()
        XCTAssertFalse(MacKeyRouter.isSearchFieldEditor(window.firstResponder))
        window.contentView?.addSubview(field)
        XCTAssertTrue(MacKeyRouter.isSearchFieldEditor(window.firstResponder))
    }

    // MARK: - Jumps

    /// A chapter click while paused plays from that chapter, through the
    /// shared jump: ⌘Z restores the sentence and the pause (M16).
    func testARowJumpsAndPlaysWithUndoJump() async {
        let (rig, actions) = makeActions()
        let navigation = loadChaptered(on: rig, at: 2)
        let target = navigation.chapters[2].startSentence
        XCTAssertFalse(rig.controller.isActive)

        MacContents.jump(rig.controller, to: target, origin: .chapter)
        XCTAssertEqual(rig.controller.currentSentence, target)
        XCTAssertEqual(rig.controller.undoableJump?.fromSentence, 2)
        XCTAssertEqual(rig.controller.undoableJump?.toSentence, target)
        let playing = await rig.waitUntil(2) { rig.controller.isActive }
        XCTAssertTrue(playing, "a row plays from there")

        XCTAssertTrue(actions.isEnabled(.undoJump), "⌘Z takes the offer")
        XCTAssertTrue(actions.perform(.undoJump))
        XCTAssertEqual(rig.controller.currentSentence, 2)
        let paused = await rig.waitUntil(2) { !rig.controller.isActive }
        XCTAssertTrue(paused, "and the pause it was made from")
        XCTAssertNil(rig.controller.undoableJump)
    }

    func testAResultJumpsToItsSentence() async throws {
        let (rig, _) = makeActions()
        loadChaptered(on: rig, at: 0)
        let match = try XCTUnwrap(rig.controller.content?.matches(of: "amontillado").first)
        let sentence = match.sentenceID
        XCTAssertGreaterThan(sentence, 0)

        MacContents.jump(rig.controller, to: sentence, origin: .searchResult)
        XCTAssertEqual(rig.controller.currentSentence, sentence)
        XCTAssertEqual(rig.controller.undoableJump?.fromSentence, 0)
        let playing = await rig.waitUntil(2) { rig.controller.isActive }
        XCTAssertTrue(playing)
        rig.controller.pause()
    }

    // MARK: - ⌘F and ⌃⌘S

    func testFindShowsThePanelWithItsSearchAsked() throws {
        let (_, actions) = makeActions()
        actions.router.path = [.reader(UUID())]
        let find = try XCTUnwrap(MacCommand.command(for: MacShortcutsTests.key("f", code: 3, flags: .command)))
        XCTAssertEqual(find, .find)
        XCTAssertTrue(actions.isEnabled(.find))
        XCTAssertTrue(actions.perform(find))
        XCTAssertTrue(actions.ui.isContentsShown)
        XCTAssertEqual(actions.ui.searchFocus, .contents, "the panel focuses \"Search this book\"")

        // Again, with the panel up: it stays, and asks for the field again.
        actions.ui.searchFocus = nil
        XCTAssertTrue(actions.perform(find))
        XCTAssertTrue(actions.ui.isContentsShown)
        XCTAssertEqual(actions.ui.searchFocus, .contents)
    }

    func testControlCommandSTogglesThePanel() throws {
        let (_, actions) = makeActions()
        actions.router.path = [.reader(UUID())]
        let toggle = try XCTUnwrap(MacCommand.command(for: MacShortcutsTests.key("s", code: 1,
                                                                                 flags: [.control, .command])))
        XCTAssertEqual(toggle, .toggleContents)
        XCTAssertTrue(actions.perform(toggle))
        XCTAssertTrue(actions.ui.isContentsShown)
        XCTAssertEqual(actions.title(for: toggle), MacMenuCopy.hideContents)
        XCTAssertTrue(actions.perform(toggle))
        XCTAssertFalse(actions.ui.isContentsShown)
        XCTAssertEqual(actions.title(for: toggle), MacMenuCopy.showContents)
        XCTAssertNil(actions.ui.searchFocus, "a toggle never moves focus into the field")
    }

    // MARK: - Fixtures

    /// CHAPTER I, II and III: a heading paragraph, then body sentences of 33
    /// words (a fifth of 165 wpm). III's last sentence names the cask.
    static func chaptered() -> DocContent {
        content([("CHAPTER I", 10), ("CHAPTER II", 20), ("CHAPTER III", 5)],
                lastSentence: "He drank to the Amontillado and to the buried.")
    }

    /// One page of prose: no chapter list, as in The Cask of Amontillado.
    static func chapterless() -> DocContent {
        content([("The thousand injuries of Fortunato I had borne as I best could.", 12)],
                lastSentence: "He laid the trowel down and the wall stood.")
    }

    private static func content(_ chapters: [(heading: String, body: Int)], lastSentence: String) -> DocContent {
        let body = Array(repeating: "word", count: 33).joined(separator: " ") + "."
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        func paragraph(_ texts: [String], page: Int) {
            let start = sentences.count
            for text in texts {
                sentences.append(Sentence(id: sentences.count, text: text, para: paragraphs.count, page: page))
            }
            paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: start..<sentences.count, page: page))
        }
        for (index, chapter) in chapters.enumerated() {
            let page = index + 1
            paragraph([chapter.heading], page: page)
            var texts = Array(repeating: body, count: chapter.body)
            if index == chapters.count - 1, !texts.isEmpty { texts[texts.count - 1] = lastSentence }
            paragraph(texts, page: page)
        }
        return DocContent(title: "Contents fixture", pageCount: chapters.count, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "contents-fixture")
    }

    // MARK: - Helpers

    @discardableResult
    private func loadChaptered(on rig: PlaybackTestRig, at sentence: Int) -> ReaderNavigation {
        let content = Self.chaptered()
        var document = PlaybackTestRig.makeDocument(hash: content.contentHash, sentences: content.sentences.count)
        document.progressSentence = sentence
        rig.controller.load(document: document, content: content)
        return ReaderNavigation(content: content, kind: .text)
    }

    private func makeActions() -> (PlaybackTestRig, MacCommandActions) {
        let rig = PlaybackTestRig()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-contents-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore(indexURL: folder.appendingPathComponent("library.json"),
                                  notifications: NotificationCenter())
        var actions = MacCommandActions(playback: rig.controller, router: LibraryRouter(), store: store,
                                        sleepTimer: SleepTimer(defaults: rig.defaults),
                                        continuePlayback: ContinuePlayback(), ui: MacUIState())
        actions.announce = { _ in }
        return (rig, actions)
    }

    /// Not deferred, never ordered in.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        return window
    }
}
