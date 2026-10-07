import AppKit
import SwiftUI
import XCTest
@testable import Aloud

/// M18 and R12a on the Mac's book page (`MacReaderAccessibility`): the page
/// is a native text area, "reader.text", whose parent lists it; it offers
/// Chapters (Pages), Paragraphs and Sentences rotors that walk item starts in
/// order through the shared `ReaderRotor` (from the first or last item when
/// VoiceOver names no place, AppKit's contract, so VO-U lists the whole
/// book) and stop at both ends, moving nothing; "Play from here" plays the
/// sentence at VoiceOver's cursor (the accessibility selection) through the
/// click's path; a cursor off screen comes into view as the reader's own
/// scroll; the label is the sentence where VoiceOver is, always on screen;
/// and the value is the passage on screen, never the book (R12e).
///
/// VoiceOver never runs: these call what it calls. Each page lives in an
/// offscreen window that is never ordered in, and the one controller is the
/// muted rig, autoplay suppressed.
@MainActor
final class MacReaderAccessibilityTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var rig: PlaybackTestRig?

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        // Play from here started the muted rig: leave no chain running into
        // the next test.
        rig?.controller.pause(rampsOut: false)
        rig = nil
        super.tearDown()
    }

    // MARK: - A native text area (M18)

    /// A text area named by the text where VoiceOver is, with the UI tests'
    /// identifier and one action, sitting where its parent lists it: the
    /// paper under it is no element, and neither are the highlight and veil.
    func testThePageIsANativeTextAreaItsParentLists() throws {
        let book = Self.book(chapters: 3, paragraphs: 2, perParagraph: 3, hash: "a11y-native")
        let page = try makePage(content: book, active: 4)
        let textView = page.textView

        XCTAssertTrue(textView.isAccessibilityElement())
        XCTAssertEqual(textView.accessibilityRole(), .textArea)
        XCTAssertEqual(textView.accessibilityIdentifier(), "reader.text")
        XCTAssertEqual(textView.accessibilityLabel(), book.sentences[4].text,
                       "no cursor: the playhead's sentence, on screen")
        XCTAssertEqual(textView.accessibilityCustomActions()?.map(\.name), ["Play from here"])

        let paper = try XCTUnwrap(page.coordinator.page)
        XCTAssertFalse(paper.isAccessibilityElement())
        XCTAssertEqual(paper.accessibilityChildren()?.count, 1)
        XCTAssertTrue(paper.accessibilityChildren()?.first as AnyObject === textView, "only the text area")
        let parent = try XCTUnwrap(textView.accessibilityParent() as? NSView, "the text area has a parent")
        XCTAssertTrue((parent.accessibilityChildren() ?? []).contains { $0 as AnyObject === textView },
                      "and that parent lists it (the audit's parent-child rule)")

        // Installing again (the coordinator's own call) changes nothing.
        let rotors = textView.accessibilityCustomRotors()
        page.coordinator.installAccessibility()
        XCTAssertTrue(zip(rotors, textView.accessibilityCustomRotors()).allSatisfy { $0 === $1 })
    }

    /// The app's page has it too: making the page installs the rotors, the
    /// action and the label (`makePage` below installs it again, which
    /// changes nothing), so they reach VoiceOver outside these tests.
    func testMakingThePageInstallsItsAccessibility() throws {
        let content = Self.book(chapters: 3, paragraphs: 2, perParagraph: 3, hash: "a11y-wired")
        let view = ReaderColumnView(content: content, isChapterBook: true,
                                    navigation: ReaderNavigation(content: content, kind: .text),
                                    fontSize: 19, activeSentence: 0, activeWord: -1,
                                    voiceOffscreen: .constant(nil), onPlaySentence: { _ in })
        let coordinator = view.makeCoordinator()
        let scrollView = coordinator.makeScrollView()
        withExtendedLifetime(scrollView) {
            XCTAssertNotNil(coordinator.textView?.readerAccessibility,
                            "makeScrollView() calls installAccessibility()")
        }
        coordinator.tearDown()
    }

    // MARK: - Rotors (R12a)

    /// Coarse to fine: Chapters, Paragraphs and Sentences in a chapter book;
    /// Paragraphs and Sentences with one chapter; Pages in a PDF. The same
    /// rotors on every ask, each with a live search.
    func testThreeRotorsInAChapterBookTwoInOneChapter() throws {
        let chaptered = try makePage(content: Self.book(chapters: 3, paragraphs: 2, perParagraph: 3,
                                                        hash: "a11y-chaptered"), active: 0)
        let rotors = chaptered.textView.accessibilityCustomRotors()
        XCTAssertEqual(rotors.map(\.label), ["Chapters", "Paragraphs", "Sentences"])
        for rotor in rotors {
            XCTAssertEqual(rotor.type, .custom, rotor.label)
            XCTAssertNotNil(rotor.itemSearchDelegate, "\(rotor.label): the page keeps its search alive")
        }
        let again = chaptered.textView.accessibilityCustomRotors()
        XCTAssertEqual(again.count, rotors.count)
        XCTAssertTrue(zip(rotors, again).allSatisfy { $0 === $1 }, "built once, not on every ask")

        let oneChapter = try makePage(content: Self.book(chapters: 1, paragraphs: 3, perParagraph: 3,
                                                         hash: "a11y-one-chapter"), active: 0)
        XCTAssertEqual(oneChapter.textView.accessibilityCustomRotors().map(\.label), ["Paragraphs", "Sentences"])

        let pdf = try makePage(content: Self.book(chapters: 3, paragraphs: 2, perParagraph: 3, hash: "a11y-pdf"),
                               kind: .pdf, active: 0)
        XCTAssertEqual(pdf.textView.accessibilityCustomRotors().map(\.label), ["Pages", "Paragraphs", "Sentences"])
        // VO-U lists a PDF's pages by number, as Contents does, never by
        // their first sentence.
        let navigation = try XCTUnwrap(pdf.coordinator.parent.navigation)
        let pages = try pdf.rotor("Pages")
        let page = try XCTUnwrap(pdf.step(pages, after: nil))
        let second = try XCTUnwrap(pdf.step(pages, after: page))
        XCTAssertEqual(page.customLabel, navigation.labels.contextTitle(forPage: navigation.chapters[0].page))
        XCTAssertEqual(second.customLabel, navigation.labels.contextTitle(forPage: navigation.chapters[1].page))
        XCTAssertTrue(page.customLabel?.hasPrefix("Page") == true, page.customLabel ?? "no label")
    }

    /// AppKit's search contract: with no item, the first sentence going
    /// forward and the last going back, so VO-U lists the whole book in
    /// order; from an item, one sentence per step, stopping at both ends.
    /// Each result is a sentence's range of the text view. Searching moves
    /// nothing: not the playhead, the page, following or the cursor.
    func testTheSentencesRotorWalksEverySentenceAndStopsAtTheEnds() throws {
        let book = Self.book(chapters: 1, paragraphs: 4, perParagraph: 3, hash: "a11y-sentences")
        let page = try makePage(content: book, active: 5)
        let sentences = try page.rotor("Sentences")
        let offset = page.offset
        let selection = page.textView.selectedRange()

        let first = try XCTUnwrap(page.step(sentences, after: nil))
        XCTAssertTrue(first.targetElement === page.textView, "the text area is the one element")
        XCTAssertEqual(first.targetRange, page.ranges[0], "no item: the first sentence, not the playhead's")
        let last = try XCTUnwrap(page.step(sentences, after: nil, forward: false))
        XCTAssertEqual(last.targetRange, page.ranges[11], "no item going back: the last sentence")
        XCTAssertEqual(try page.walk(sentences, from: first, forward: true), Array(1..<12), "the whole list")
        XCTAssertEqual(try page.walk(sentences, from: last, forward: false), Array((0..<11).reversed()))

        let middle = page.item(at: page.ranges[5])
        XCTAssertEqual(try page.walk(sentences, from: middle, forward: true), Array(6..<12))
        XCTAssertEqual(try page.walk(sentences, from: middle, forward: false), Array((0..<5).reversed()))

        XCTAssertEqual(page.played.ids, [], "a rotor never plays")
        XCTAssertEqual(page.coordinator.activeSentence, 5)
        XCTAssertTrue(page.coordinator.isFollowing, "a search never takes the page")
        XCTAssertEqual(page.offset, offset)
        XCTAssertEqual(page.textView.selectedRange(), selection)
    }

    /// A search from VoiceOver's cursor lands on the nearest start beyond
    /// it: back from inside a sentence, that sentence's own start; forward
    /// from a paragraph's end, the next paragraph's first sentence. An item
    /// with no place in the text, or on another element, is no item.
    func testASearchFromTheCursorLandsOnTheNearestStartBeyondIt() throws {
        let book = Self.book(chapters: 1, paragraphs: 4, perParagraph: 3, hash: "a11y-origin")
        let page = try makePage(content: book, active: 0)
        let sentences = try page.rotor("Sentences")
        let paragraphs = try page.rotor("Paragraphs")

        let inside = page.item(at: NSRange(location: page.ranges[7].location + 4, length: 3))
        XCTAssertEqual(page.step(sentences, after: inside)?.targetRange, page.ranges[8])
        XCTAssertEqual(page.step(sentences, after: inside, forward: false)?.targetRange, page.ranges[7],
                       "back from inside a sentence: its own start")
        XCTAssertEqual(page.step(paragraphs, after: inside, forward: false)?.targetRange, page.ranges[6])

        let gap = NSMaxRange(page.ranges[5])
        XCTAssertLessThan(gap, page.ranges[6].location, "a gap between the paragraphs")
        XCTAssertEqual(page.step(sentences, after: page.item(at: NSRange(location: gap, length: 0)))?.targetRange,
                       page.ranges[6], "forward from a paragraph's end: the next sentence counts")

        let storage = try XCTUnwrap(page.textView.textStorage)
        let end = page.item(at: NSRange(location: storage.length, length: 0))
        XCTAssertNil(page.step(sentences, after: end), "nothing after the end")
        XCTAssertEqual(page.step(sentences, after: end, forward: false)?.targetRange, page.ranges[11])

        let nowhere = page.item(at: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(page.step(sentences, after: nowhere)?.targetRange, page.ranges[0])
        XCTAssertEqual(page.step(sentences, after: nowhere, forward: false)?.targetRange, page.ranges[11])
        let elsewhere = NSAccessibilityCustomRotor.ItemResult(targetElement: page.scrollView)
        elsewhere.targetRange = page.ranges[7]
        XCTAssertEqual(page.step(sentences, after: elsewhere)?.targetRange, page.ranges[0])
    }

    /// Paragraph starts: from no item the first and the last; from inside a
    /// paragraph, the next start each way, stopping at both ends.
    func testTheParagraphsRotorLandsOnParagraphStarts() throws {
        let book = Self.book(chapters: 1, paragraphs: 4, perParagraph: 3, hash: "a11y-paragraphs")
        let page = try makePage(content: book, active: 5)
        let paragraphs = try page.rotor("Paragraphs")

        let first = try XCTUnwrap(page.step(paragraphs, after: nil))
        XCTAssertEqual(first.targetRange, page.ranges[0])
        XCTAssertEqual(try page.walk(paragraphs, from: first, forward: true), [3, 6, 9])
        XCTAssertEqual(page.step(paragraphs, after: nil, forward: false)?.targetRange, page.ranges[9])
        let middle = page.item(at: page.ranges[5])
        XCTAssertEqual(try page.walk(paragraphs, from: middle, forward: true), [6, 9])
        XCTAssertEqual(try page.walk(paragraphs, from: middle, forward: false), [3, 0])
        XCTAssertEqual(page.played.ids, [])
    }

    /// Chapter starts, each named by its title in the rotor's list; a
    /// search from VoiceOver's cursor starts there.
    func testTheChaptersRotorLandsOnChapterStartsByTitle() throws {
        let book = Self.book(chapters: 3, paragraphs: 2, perParagraph: 3, hash: "a11y-chapter-walk")
        XCTAssertEqual(ReaderNavigation(content: book, kind: .text).chapters.map(\.startSentence), [0, 6, 12])
        let page = try makePage(content: book, active: 8)
        let chapters = try page.rotor("Chapters")

        let first = try XCTUnwrap(page.step(chapters, after: nil))
        XCTAssertEqual(first.targetRange, page.ranges[0])
        XCTAssertEqual(first.customLabel, "Chapter 1")
        XCTAssertEqual(try page.walk(chapters, from: first, forward: true), [6, 12])
        let next = try XCTUnwrap(page.step(chapters, after: first))
        XCTAssertEqual(next.customLabel, "Chapter 2")
        XCTAssertEqual(page.step(chapters, after: nil, forward: false)?.customLabel, "Chapter 3")

        // VoiceOver's cursor in chapter 3, searching back: chapter 3's start.
        page.textView.setAccessibilitySelectedTextRange(NSRange(location: page.ranges[14].location, length: 0))
        let cursor = page.item(at: page.textView.accessibilitySelectedTextRange())
        let back = try XCTUnwrap(page.step(chapters, after: cursor, forward: false))
        XCTAssertEqual(back.targetRange, page.ranges[12])
        XCTAssertEqual(try page.walk(chapters, from: back, forward: false), [6, 0])
        XCTAssertEqual(page.played.ids, [])
        XCTAssertEqual(page.coordinator.activeSentence, 8, "browsing never moves the playhead")
    }

    /// VO-U's type-ahead: a filter skips to the items whose name holds it,
    /// in either case, and the list ends after the last match.
    func testAFilterListsOnlyTheItemsNamedByIt() throws {
        let book = Self.book(chapters: 3, paragraphs: 2, perParagraph: 3, hash: "a11y-filter")
        let page = try makePage(content: book, active: 0)
        let chapters = try page.rotor("Chapters")
        let sentences = try page.rotor("Sentences")

        let chapter = try XCTUnwrap(page.step(chapters, after: nil, filter: "chapter 2"))
        XCTAssertEqual(chapter.customLabel, "Chapter 2")
        XCTAssertNil(page.step(chapters, after: chapter, filter: "chapter 2"), "one match")
        XCTAssertEqual(page.step(chapters, after: nil, forward: false, filter: "CHAPTER 1")?.targetRange,
                       page.ranges[0])

        let sentence = try XCTUnwrap(page.step(sentences, after: nil, filter: "sentence 9 reads"))
        XCTAssertEqual(sentence.targetRange, page.ranges[9])
        XCTAssertNil(page.step(sentences, after: sentence, filter: "sentence 9 reads"))
        XCTAssertNil(page.step(sentences, after: nil, filter: "no such words"))
        XCTAssertEqual(page.coordinator.activeSentence, 0)
    }

    // MARK: - Play from here (R12a)

    /// VoiceOver lands on a rotor result by putting its cursor (the
    /// accessibility selection) there; Play from here then starts the book
    /// at that sentence, as a click does. A cursor inside a sentence plays
    /// that sentence. A cursor on screen never moves the page.
    func testPlayFromHerePlaysTheSentenceAtTheAccessibilitySelection() throws {
        let rig = makeRig(sentences: 40)
        let page = try makePage(content: rig.content, active: 0) { id in
            ReaderColumnView.playFromSentence(id, on: rig.controller)
        }
        let sentences = try page.rotor("Sentences")
        var item = page.step(sentences, after: nil)
        for _ in 0..<3 { item = page.step(sentences, after: item) }
        let stop = try XCTUnwrap(item)
        XCTAssertEqual(stop.targetRange, page.ranges[3])
        XCTAssertEqual(rig.controller.currentSentence, 0, "a rotor step never moves the playhead")

        let offset = page.offset
        page.textView.setAccessibilitySelectedTextRange(stop.targetRange)
        XCTAssertEqual(page.textView.accessibilitySelectedTextRange().location, page.ranges[3].location)
        XCTAssertEqual(page.textView.accessibilityLabel(), rig.content.sentences[3].text)
        XCTAssertEqual(page.offset, offset, "a cursor on screen never moves the page")

        let action = try XCTUnwrap(page.textView.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.name, "Play from here")
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(page.played.ids, [3])
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertTrue([.buffering, .playing].contains(rig.controller.status), "\(rig.controller.status)")

        page.textView.setAccessibilitySelectedTextRange(NSRange(location: page.ranges[7].location + 4, length: 0))
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(page.played.ids, [3, 7])
        XCTAssertEqual(rig.controller.currentSentence, 7)
    }

    /// With no cursor (a fresh build leaves the selection at the start),
    /// Play from here plays the sentence the label names, the playhead's,
    /// as on the iPhone. A text-size step keeps VoiceOver's cursor. Over
    /// the colophon there is nothing to play from.
    func testWithNoCursorPlayFromHerePlaysThePlayheadsSentence() throws {
        let book = Self.book(chapters: 1, paragraphs: 4, perParagraph: 3, hash: "a11y-no-cursor")
        let page = try makePage(content: book, active: 5)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 0, length: 0))
        let action = try XCTUnwrap(page.textView.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(page.played.ids, [5])

        page.textView.setAccessibilitySelectedTextRange(NSRange(location: page.ranges[9].location, length: 0))
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[9].text)
        page.update(activeSentence: 5, fontSize: 23)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: page.ranges[9].location, length: 0),
                       "a text-size step keeps VoiceOver's cursor")
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[9].text)
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(page.played.ids, [5, 9], "and Play from here still starts there")

        // A selection no accessibility client made drops the cursor.
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let colophon = ReaderColophon(title: "Rotors", author: "A. Writer", words: 900, rate: 1)
        page.update(activeSentence: 11, colophon: colophon)
        XCTAssertEqual(page.textView.accessibilityLabel(), colophon.spokenText)
        XCTAssertEqual(action.handler?(), false, "the colophon is no sentence")
        XCTAssertEqual(page.played.ids, [5, 9])
    }

    /// A crash a hosted run found: VoiceOver's cursor kept through a
    /// text-size step, then the colophon shown. The label's visible range
    /// asked TextKit for a point off its lines, TextKit answered NSNotFound,
    /// and adding that to the line's start overflowed. The label is now
    /// asked in exactly that state.
    func testTheLabelSurvivesACursorKeptIntoTheColophon() throws {
        let book = Self.book(chapters: 1, paragraphs: 4, perParagraph: 3, hash: "a11y-colophon-cursor")
        let page = try makePage(content: book, active: 5)
        page.textView.setAccessibilitySelectedTextRange(NSRange(location: page.ranges[9].location, length: 0))
        page.update(activeSentence: 5, fontSize: 23)
        let colophon = ReaderColophon(title: "Rotors", author: "A. Writer", words: 900, rate: 1)
        page.update(activeSentence: 11, colophon: colophon)
        let label = try XCTUnwrap(page.textView.accessibilityLabel())
        XCTAssertTrue(label == book.sentences[9].text || label == colophon.spokenText, "got '\(label)'")
        XCTAssertNotNil(page.textView.accessibilityValue())
    }

    /// Light/dark or Increase Contrast recolors the column as it draws,
    /// with no edit to the text: VoiceOver's cursor, and a reader's
    /// selection for Copy, stay where they were.
    func testAnAppearanceChangeKeepsTheCursorAndTheSelection() throws {
        final class Edits: @unchecked Sendable { var count = 0 }
        let book = Self.book(chapters: 1, paragraphs: 4, perParagraph: 3, hash: "a11y-appearance")
        let page = try makePage(content: book, active: 5)
        let edits = Edits()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: page.textView.textStorage,
            queue: nil) { _ in edits.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let cursor = NSRange(location: page.ranges[9].location, length: 0)
        page.textView.setAccessibilitySelectedTextRange(cursor)
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[9].text)

        page.textView.appearance = NSAppearance(named: Self.otherLook(than: page.textView.effectiveAppearance))
        page.coordinator.rebuildForAppearanceChange()
        XCTAssertEqual(edits.count, 0, "recolored as it draws, with no edit")
        XCTAssertEqual(page.textView.selectedRange(), cursor, "VoiceOver's cursor stays")
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[9].text)
        let action = try XCTUnwrap(page.textView.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(page.played.ids, [9], "Play from here starts at the cursor, not the playhead")

        page.textView.setSelectedRange(page.ranges[10])
        let before = edits.count
        page.textView.appearance = NSAppearance(named: Self.otherLook(than: page.textView.effectiveAppearance))
        page.coordinator.rebuildForAppearanceChange()
        XCTAssertEqual(edits.count, before, "and again")
        XCTAssertEqual(page.textView.selectedRange(), page.ranges[10], "the selection stays for Copy")
    }

    /// Light if `appearance` is dark, else dark: a change of look.
    private static func otherLook(than appearance: NSAppearance) -> NSAppearance.Name {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .aqua : .darkAqua
    }

    /// Every point on the page, beside, below and between the lines, the
    /// colophon's included, maps to a character in the text or to none:
    /// never past the end, and never a trap.
    func testEveryPointOnThePageMapsInsideTheTextOrToNothing() throws {
        let book = Self.book(chapters: 2, paragraphs: 3, perParagraph: 3, hash: "a11y-point-sweep")
        let page = try makePage(content: book, active: 2)
        let colophon = ReaderColophon(title: "Sweep", author: "A. Writer", words: 600, rate: 1)
        page.update(activeSentence: 17, colophon: colophon)
        let textView = page.textView
        let manager = try XCTUnwrap(textView.textLayoutManager)
        let length = try XCTUnwrap(textView.textStorage?.length)
        let layout = ReaderColumnLayout(textLayoutManager: manager, origin: textView.textContainerOrigin)
        let bounds = textView.bounds
        var placed = 0
        for y in stride(from: -40, through: bounds.maxY + 200, by: 7) {
            for x in stride(from: -60, through: bounds.maxX + 300, by: 23) {
                guard let offset = layout.characterOffset(at: CGPoint(x: x, y: y)) else { continue }
                placed += 1
                XCTAssertTrue((0...length).contains(offset), "(\(x), \(y)) gave \(offset) of \(length)")
            }
        }
        XCTAssertGreaterThan(placed, 0, "the sweep lands on the text")
    }

    /// VoiceOver's cursor at the very start of the text is a cursor, though
    /// a fresh build leaves the selection there too.
    func testACursorPlacedAtTheStartIsACursor() throws {
        let book = Self.book(chapters: 1, paragraphs: 4, perParagraph: 3, hash: "a11y-start")
        let page = try makePage(content: book, active: 7)
        let start = NSRange(location: 0, length: 0)
        page.textView.setAccessibilitySelectedTextRange(start)
        XCTAssertEqual(page.textView.selectedRange(), start)
        let action = try XCTUnwrap(page.textView.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(page.played.ids, [0], "the first sentence, not the playhead's")

        // A click elsewhere is the reader's selection, and VoiceOver's
        // cursor follows it.
        page.textView.setSelectedRange(NSRange(location: page.ranges[10].location, length: 0))
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[10].text)
    }

    // MARK: - Scrolling under VoiceOver

    /// A cursor placed off screen comes to the landing line as the reader's
    /// scroll: following stops, the Follow chip points to the voice, no
    /// follow scroll is counted, the playhead stays, and the next sentence
    /// never pulls the page back.
    func testACursorOffScreenComesIntoViewAsTheReadersScroll() throws {
        let book = Self.book(chapters: 1, paragraphs: 75, perParagraph: 4, hash: "a11y-reveal")
        let page = try makePage(content: book, active: 150, size: NSSize(width: 800, height: 500))
        let coordinator = page.coordinator
        XCTAssertTrue(coordinator.isFollowing)
        let scrolls = coordinator.programmaticScrollCount
        let far = 20
        let before = try XCTUnwrap(coordinator.viewport())
        XCTAssertNotNil(FollowBand.direction(of: try XCTUnwrap(coordinator.rect(forSentence: far)), in: before),
                        "off screen to begin with")

        page.textView.setAccessibilitySelectedTextRange(NSRange(location: page.ranges[far].location, length: 0))
        XCTAssertFalse(coordinator.isFollowing, "VoiceOver took the page")
        let after = try XCTUnwrap(coordinator.viewport())
        XCTAssertNil(FollowBand.direction(of: try XCTUnwrap(coordinator.rect(forSentence: far)), in: after),
                     "the cursor is on screen")
        XCTAssertLessThan(page.offset, before.minY)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "the reader's scroll, never a follow scroll")
        XCTAssertEqual(coordinator.voiceOffscreen, .down, "the Follow chip points down to the voice")
        XCTAssertEqual(coordinator.activeSentence, 150)
        XCTAssertEqual(page.played.ids, [])

        let offset = page.offset
        page.update(activeSentence: 151)
        XCTAssertEqual(page.offset, offset, "no glide back to the voice")
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[far].text)
    }

    /// Scrolled away from the playhead with no cursor, the label names the
    /// first sentence on screen: always text the page shows.
    func testTheLabelNamesTextOnScreen() throws {
        let book = Self.book(chapters: 1, paragraphs: 75, perParagraph: 4, hash: "a11y-label")
        let page = try makePage(content: book, active: 150, size: NSSize(width: 800, height: 500))
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[150].text)

        page.scrollView.contentView.setBoundsOrigin(.zero)
        XCTAssertFalse(page.coordinator.isFollowing)
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[0].text, "the top of the page")
    }

    /// A caret on screen (a click's) is where VoiceOver is; left off screen
    /// it is no cursor, so the label and Play from here both take the text
    /// on screen, never a sentence the reader can't see.
    func testACaretOffScreenIsNoCursor() throws {
        let book = Self.book(chapters: 1, paragraphs: 75, perParagraph: 4, hash: "a11y-stale-caret")
        let page = try makePage(content: book, active: 150, size: NSSize(width: 800, height: 500))
        page.textView.setSelectedRange(NSRange(location: page.ranges[151].location + 2, length: 0))
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[151].text, "the caret, on screen")

        page.scrollView.contentView.setBoundsOrigin(.zero)
        XCTAssertEqual(page.textView.accessibilityLabel(), book.sentences[0].text, "not the caret off screen")
        let action = try XCTUnwrap(page.textView.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(page.played.ids, [0], "the sentence the label names")

        // A selection reaching above the screen (⌘A) starts where it shows.
        let middle = try XCTUnwrap(page.coordinator.rect(forSentence: 100))
        page.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: middle.minY))
        page.textView.selectAll(nil)
        let label = try XCTUnwrap(page.textView.accessibilityLabel())
        XCTAssertNotEqual(label, book.sentences[0].text, "not the selection's start, off screen")
        let id = try XCTUnwrap(book.sentences.firstIndex { $0.text == label })
        XCTAssertNil(FollowBand.direction(of: try XCTUnwrap(page.coordinator.rect(forSentence: id)),
                                          in: try XCTUnwrap(page.coordinator.viewport())), "a sentence on screen")
    }

    // MARK: - The value (R12e)

    /// The value is the passage on screen, at most `valueLimit` characters:
    /// the playhead's sentence is in it, the book's start and end are not.
    /// The text area still reads any part of the book by range, natively.
    func testTheValueIsThePassageOnScreenNeverTheBook() throws {
        let book = Self.book(chapters: 1, paragraphs: 300, perParagraph: 4, hash: "a11y-value")
        let page = try makePage(content: book, active: 600)
        let storage = try XCTUnwrap(page.textView.textStorage)

        let value = try XCTUnwrap(page.textView.accessibilityValue())
        let length = (value as NSString).length
        XCTAssertGreaterThan(length, 0)
        XCTAssertLessThanOrEqual(length, MacReaderAccessibility.valueLimit)
        XCTAssertLessThan(length, storage.length / 10, "a screen, not the book")
        XCTAssertTrue(value.contains(book.sentences[600].text), "the playhead's sentence is on screen")
        XCTAssertFalse(value.contains(book.sentences[1].text))
        XCTAssertFalse(value.contains(book.sentences[1199].text))

        // Measured in the view's own visible rect, as before the coordinator
        // installs its part: as bounded.
        let own = MacReaderAccessibility.visibleText(of: page.textView, in: page.textView.visibleRect)
        XCTAssertLessThanOrEqual((own as NSString).length, MacReaderAccessibility.valueLimit)
        XCTAssertTrue(own.contains(book.sentences[600].text))

        XCTAssertEqual(page.textView.accessibilityNumberOfCharacters(), storage.length,
                       "the text area still holds the whole book")
        let end = page.ranges[1199]
        XCTAssertEqual(page.textView.accessibilityString(for: end), (storage.string as NSString).substring(with: end))
        XCTAssertTrue(page.textView.accessibilityString(for: end)?.contains("Sentence 1199") == true)
    }

    // MARK: - Helpers

    /// The sentences a page played, in order.
    private final class PlayLog {
        var ids: [Int] = []
    }

    /// One page in its window, and the inputs it was last given.
    @MainActor
    private final class Page {
        let window: NSWindow
        let scrollView: ReaderScrollView
        let coordinator: ReaderColumnView.Coordinator
        let played: PlayLog
        private(set) var view: ReaderColumnView

        init(window: NSWindow, scrollView: ReaderScrollView, coordinator: ReaderColumnView.Coordinator,
             played: PlayLog, view: ReaderColumnView) {
            self.window = window
            self.scrollView = scrollView
            self.coordinator = coordinator
            self.played = played
            self.view = view
        }

        var textView: ReaderNSTextView { coordinator.textView! }
        var offset: CGFloat { scrollView.contentView.bounds.origin.y }
        var ranges: [NSRange] { coordinator.sentenceRanges }

        /// The same page with new inputs, handed to the coordinator as
        /// SwiftUI's update would; the navigation stays.
        func update(activeSentence: Int, fontSize: CGFloat? = nil, colophon: ReaderColophon? = nil) {
            view = ReaderColumnView(content: view.content, isChapterBook: view.isChapterBook,
                                    navigation: view.navigation, fontSize: fontSize ?? view.fontSize,
                                    activeSentence: activeSentence, activeWord: -1,
                                    followRequest: view.followRequest, colophon: colophon ?? view.colophon,
                                    voiceOffscreen: .constant(nil), onPlaySentence: view.onPlaySentence)
            coordinator.update(to: view)
        }

        func rotor(_ name: String) throws -> NSAccessibilityCustomRotor {
            try XCTUnwrap(textView.accessibilityCustomRotors().first { $0.label == name }, "no \(name) rotor")
        }

        /// One search, as VoiceOver makes it: from `item` (nil: none), one
        /// way, through VO-U's type-ahead `filter`.
        func step(_ rotor: NSAccessibilityCustomRotor, after item: NSAccessibilityCustomRotor.ItemResult?,
                  forward: Bool = true, filter: String = "") -> NSAccessibilityCustomRotor.ItemResult? {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = item
            parameters.searchDirection = forward ? .next : .previous
            parameters.filterString = filter
            return rotor.itemSearchDelegate?.rotor(rotor, resultFor: parameters)
        }

        /// A place in the text to search from, as VoiceOver hands one over
        /// (its last result, or its cursor).
        func item(at range: NSRange) -> NSAccessibilityCustomRotor.ItemResult {
            let item = NSAccessibilityCustomRotor.ItemResult(targetElement: textView)
            item.targetRange = range
            return item
        }

        /// Every stop after `start`, one way, until the rotor stops: the
        /// sentence each lands on.
        func walk(_ rotor: NSAccessibilityCustomRotor, from start: NSAccessibilityCustomRotor.ItemResult,
                  forward: Bool) throws -> [Int] {
            var stops: [Int] = []
            var item = start
            for _ in 0...ranges.count {
                guard let next = step(rotor, after: item, forward: forward) else { return stops }
                XCTAssertTrue(next.targetElement === textView)
                stops.append(try XCTUnwrap(ranges.firstIndex(of: next.targetRange), "a sentence's range"))
                item = next
            }
            XCTFail("\(rotor.label) never stopped")
            return stops
        }
    }

    /// The muted rig with `sentences` loaded, paused at 0; autoplay
    /// suppressed.
    private func makeRig(sentences: Int) -> (controller: PlaybackController, content: DocContent) {
        let rig = PlaybackTestRig(sentences: sentences, autoplaySuppressed: true)
        self.rig = rig
        let content = PlaybackTestRig.makeContent(hash: "mac-a11y-rig", count: sentences, wordsPerSentence: 6)
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: "mac-a11y-rig", sentences: sentences),
                            content: content)
        return (rig.controller, content)
    }

    /// A page in an offscreen window (never ordered in), with its navigation
    /// and accessibility, built, measured and placed on its active
    /// sentence. `onPlay` runs after the play log records.
    private func makePage(content: DocContent, kind: DocKind = .text, active: Int,
                          size: NSSize = NSSize(width: 1000, height: 600),
                          onPlay: ((Int) -> Void)? = nil) throws -> Page {
        let log = PlayLog()
        let view = ReaderColumnView(content: content, isChapterBook: kind == .text,
                                    navigation: ReaderNavigation(content: content, kind: kind),
                                    fontSize: 19, activeSentence: active, activeWord: -1,
                                    voiceOffscreen: .constant(nil), onPlaySentence: { id in
                                        log.ids.append(id)
                                        onPlay?(id)
                                    })
        let coordinator = view.makeCoordinator()
        coordinator.reduceMotion = { false }
        coordinator.isCoasting = { _ in false }
        let scrollView = coordinator.makeScrollView()
        coordinator.installAccessibility()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)

        coordinator.update(to: view)
        coordinator.updateGeometry()
        // TextKit's estimate reaches the end, so the landing isn't clamped.
        _ = coordinator.rect(forSentence: content.sentences.count - 1)
        coordinator.placeActiveSentence()
        XCTAssertNotNil(coordinator.textView?.readerAccessibility)
        return Page(window: window, scrollView: scrollView, coordinator: coordinator, played: log, view: view)
    }

    /// `chapters` chapters (a book's chapters are its pages) of `paragraphs`
    /// paragraphs of `perParagraph` sentences. Each chapter opens on
    /// "Chapter N.", its title; every other sentence is distinct text.
    private static func book(chapters: Int, paragraphs: Int, perParagraph: Int, hash: String) -> DocContent {
        var sentences: [Sentence] = []
        var paras: [Paragraph] = []
        for chapter in 0..<chapters {
            let opening = sentences.count
            for _ in 0..<paragraphs {
                let start = sentences.count
                for _ in 0..<perParagraph {
                    let id = sentences.count
                    let text = id == opening ? "Chapter \(chapter + 1)." : "Sentence \(id) reads a few plain words aloud."
                    sentences.append(Sentence(id: id, text: text, para: paras.count, page: chapter + 1))
                }
                paras.append(Paragraph(id: paras.count, sentenceIDs: start..<sentences.count, page: chapter + 1))
            }
        }
        return DocContent(title: "Rotors", pageCount: chapters, sentences: sentences, paragraphs: paras,
                          contentHash: hash)
    }
}
