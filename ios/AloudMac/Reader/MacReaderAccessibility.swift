import AppKit

/// VoiceOver on the book page (M18, R12a, contracts §6). The text view stays
/// a native `AXTextArea`: VoiceOver reads it by line, word and character
/// through AppKit's own ranged text attributes. This adds what the iPhone's
/// column has, on the same shared `ReaderRotor`:
///
/// - Three `NSAccessibilityCustomRotor`s, coarse to fine: Chapters (Pages in
///   a PDF), Paragraphs and Sentences (VO-U). Nothing is built up front: a
///   search is one `ReaderRotor.target(...)` step from the item VoiceOver is
///   on, and its result is that item's first sentence as a range of the
///   text view. With no item, AppKit's contract: the first item going
///   forward, the last going back, so VO-U lists the whole book (the
///   iPhone's first flick from the playhead has no Mac counterpart). A
///   search moves nothing (VoiceOver lists results before landing on one);
///   VoiceOver lands on a result by placing its cursor.
/// - VoiceOver's cursor is the text view's accessibility selection. Placing
///   it is the reader taking the page, as a rotor step is on the iPhone:
///   following stops, so the page doesn't glide away under the cursor, and a
///   cursor off screen is brought to the landing line as a user scroll,
///   never as the follow engine's (like any scroll, one that ends with the
///   voice in view resumes following, R16).
/// - "Play from here" (`NSAccessibilityCustomAction`, VO-⌘-Space) plays from
///   the sentence at the cursor through the click's path (`onPlaySentence`);
///   with no cursor placed, from the sentence the label names.
/// - The label is what the page shows where VoiceOver is: the cursor's
///   sentence while the cursor is on screen, else the colophon at the end
///   (R24), else the playhead's sentence while it is on screen, else the
///   first sentence on screen.
/// - R12e: the value is the passage on screen, at most `valueLimit`
///   characters, never the whole book (a text view's value is otherwise its
///   entire text: megabytes for Pepys, sent whole on every ask). AppKit's
///   ranged attributes still read any part of the text.
///
/// Nothing here posts an announcement: those stay in `A11yAnnounce`.
@MainActor
final class MacReaderAccessibility {

    /// The page's identifier, the UI tests' handle (as on the iPhone).
    static let identifier = "reader.text"
    /// The most of the book the value holds: more than a full screen at the
    /// smallest size in a large window, a sliver of a book.
    static let valueLimit = 6_000

    private weak var coordinator: ReaderColumnView.Coordinator?
    /// One search per rotor. A rotor holds its delegate weakly, so the
    /// searches live here.
    private var searches: [ReaderRotor: ReaderRotorSearch] = [:]
    /// The rotors last handed out, and their names: the same objects while
    /// the book offers the same rotors.
    private var rotors: [NSAccessibilityCustomRotor] = []
    private var rotorNames: [String] = []
    /// The selection an accessibility client placed, until the selection
    /// moves any other way: tells VoiceOver's cursor at the very start from
    /// the start a fresh build leaves.
    private var placedCursor: NSRange?
    private lazy var playFromHereAction = NSAccessibilityCustomAction(name: ReaderRotor.playFromHere) {
        [weak self] in
        MainActor.assumeIsolated { self?.playFromHere() ?? false }
    }

    init(coordinator: ReaderColumnView.Coordinator) {
        self.coordinator = coordinator
    }

    private var textView: ReaderNSTextView? { coordinator?.textView }

    /// The content the page shows, once its text and ranges are built for it.
    private var builtContent: DocContent? {
        guard let coordinator, !coordinator.builtHash.isEmpty else { return nil }
        let content = coordinator.parent.content
        guard coordinator.builtHash == content.contentHash,
              coordinator.sentenceRanges.count == content.sentences.count else { return nil }
        return content
    }

    // MARK: Rotors (R12a)

    /// The rotors worth offering (`ReaderRotor.available`, O(1)), coarse to
    /// fine.
    func customRotors() -> [NSAccessibilityCustomRotor] {
        guard let coordinator else { return [] }
        let parent = coordinator.parent
        let kinds = ReaderRotor.available(content: parent.content, navigation: parent.navigation)
        let names = kinds.map { $0.name(listing: parent.navigation, isChapterBook: parent.isChapterBook) }
        if names != rotorNames {
            rotors = zip(kinds, names).map { kind, name in
                NSAccessibilityCustomRotor(label: name, itemSearchDelegate: search(for: kind))
            }
            rotorNames = names
        }
        return rotors
    }

    private func search(for kind: ReaderRotor) -> ReaderRotorSearch {
        if let search = searches[kind] { return search }
        let search = ReaderRotorSearch(kind: kind, owner: self)
        searches[kind] = search
        return search
    }

    /// One rotor step, on AppKit's search contract: the nearest item start
    /// beyond the place VoiceOver searches from (its last result, or its
    /// cursor in the text); with no place (no item, another element, or
    /// `NSNotFound`), the first item going forward and the last going back.
    /// A filter (VO-U's type-ahead) skips to the next item whose name holds
    /// it. A binary search per step; nil at either end.
    func result(_ kind: ReaderRotor,
                for parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let coordinator, let textView, let content = builtContent, !content.sentences.isEmpty else { return nil }
        let ranges = coordinator.sentenceRanges
        let navigation = coordinator.parent.navigation
        let forward = parameters.searchDirection == .next
        var from: Int?
        if let item = parameters.currentItem, item.targetElement === textView,
           item.targetRange.location != NSNotFound {
            from = Self.searchOrigin(at: item.targetRange.location, forward: forward, in: ranges)
        }
        // With no place, the walk's anchor is the book's first or last sentence.
        let anchor = forward ? 0 : ranges.count - 1
        let filter = parameters.filterString.trimmingCharacters(in: .whitespacesAndNewlines)
        var target = ReaderRotor.target(kind, from: from, anchor: anchor, forward: forward,
                                        content: content, navigation: navigation)
        // Item starts only ever move on, so this ends at either end.
        while let id = target, !filter.isEmpty,
              !Self.itemName(id, kind, content: content, navigation: navigation)
                .localizedCaseInsensitiveContains(filter) {
            target = ReaderRotor.target(kind, from: id, anchor: anchor, forward: forward,
                                        content: content, navigation: navigation)
        }
        guard let target, ranges.indices.contains(target) else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: textView)
        result.targetRange = ranges[target]
        if kind == .chapters {
            // The list (VO-U) names a chapter by its title, a PDF's page by
            // its number, as Contents does.
            result.customLabel = Self.chapterName(target, navigation: navigation)
        }
        return result
    }

    /// The `from` of `ReaderRotor.target` for a search from UTF-16 offset
    /// `offset`, so the step lands on the nearest start beyond it: forward
    /// from a gap (a paragraph's end) the next sentence counts, and back
    /// from inside a sentence its own start counts. Past the last sentence
    /// (the end mark, the colophon): one past it.
    private static func searchOrigin(at offset: Int, forward: Bool, in ranges: [NSRange]) -> Int {
        guard let id = ReaderColumnLayout.sentence(atOrAfter: offset, in: ranges) else { return ranges.count }
        let start = ranges[id].location
        if forward { return offset < start ? id - 1 : id }
        return offset > start ? id + 1 : id
    }

    /// What VO-U lists an item as: a chapter's (or page's) name, else its
    /// first sentence (the text at its range).
    private static func itemName(_ id: Int, _ kind: ReaderRotor, content: DocContent,
                                 navigation: ReaderNavigation?) -> String {
        if kind == .chapters, let name = chapterName(id, navigation: navigation) { return name }
        return content.sentences.indices.contains(id) ? content.sentences[id].text : ""
    }

    /// The name of the rotor step holding sentence `id`: its title in a text
    /// book, "Page 12" (or "Pages 12–14") in a PDF, and its own page where
    /// Contents groups pages, since the rotor steps one page there (J019).
    private static func chapterName(_ id: Int, navigation: ReaderNavigation?) -> String? {
        navigation?.rotorStepTitle(containing: id)
    }

    // MARK: VoiceOver's cursor

    /// An accessibility client (VoiceOver landing on a rotor result, or
    /// moving through the text) placed the selection: the reader has taken
    /// the page. Following stops, and a cursor off screen comes into view.
    func cursorPlaced() {
        guard let coordinator, let textView else { return }
        let selection = textView.selectedRange()
        placedCursor = selection
        coordinator.userTookOverScroll()
        reveal(selection)
    }

    /// The selection moved some other way (a click, a drag, a new build):
    /// what an accessibility client placed is gone.
    func selectionMoved() {
        placedCursor = nil
    }

    /// A rebuild of the same text (a text-size step) resets the selection;
    /// VoiceOver's cursor, and whether VoiceOver placed it, come back after.
    func keepingCursor(through rebuild: () -> Void) {
        guard let textView else { return rebuild() }
        let selection = textView.selectedRange()
        let placed = placedCursor
        rebuild()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= textView.textStorage?.length ?? 0 else { return }
        textView.setSelectedRange(selection)
        placedCursor = placed
    }

    /// The UTF-16 offset of VoiceOver's cursor: the accessibility selection
    /// while any of it is on screen, except the bare start a build leaves,
    /// which is no cursor unless an accessibility client put it there. A
    /// caret off screen (a click the reading has long passed, or the reader
    /// scrolling away) is no cursor: the label names text on screen, and
    /// Play from here plays what it names. Two hit tests, no layout.
    func cursorOffset() -> Int? {
        guard builtContent != nil, let coordinator, let textView, let length = textView.textStorage?.length,
              let viewport = coordinator.viewport() else { return nil }
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound, selection.location <= length else { return nil }
        if selection.location == 0, selection.length == 0, placedCursor != selection { return nil }
        guard let visible = Self.visibleCharacterRange(of: textView, in: viewport) else { return nil }
        if selection.length > 0 {
            // A selection reaching above the screen (⌘A) starts where it shows.
            let shown = NSIntersectionRange(selection, visible)
            return shown.length > 0 ? shown.location : nil
        }
        let onScreen = visible.location <= selection.location && selection.location <= NSMaxRange(visible)
        return onScreen ? selection.location : nil
    }

    /// The sentence at cursor `offset`, or the next one from a gap (a
    /// heading, a page mark); nil past the last sentence.
    private func cursorSentence(at offset: Int) -> Int? {
        guard let coordinator else { return nil }
        return ReaderColumnLayout.sentence(atOrAfter: offset, in: coordinator.sentenceRanges)
    }

    /// Brings a cursor off screen to the landing line, as the reader's own
    /// scroll: the clip view moves under no scroll of the coordinator's, so
    /// it counts as a user scroll, never against the R16 budget, and it ends
    /// like one (following resumes only if it ends with the voice in view).
    private func reveal(_ selection: NSRange) {
        guard let coordinator, let textView, let page = coordinator.page, let scrollView = coordinator.scrollView,
              let length = textView.textStorage?.length, length > 0, selection.location != NSNotFound,
              let column, let viewport = coordinator.viewport(), viewport.height > 0 else { return }
        let first = NSRange(location: min(selection.location, length - 1), length: 1)
        guard let drawn = column.boundingRect(for: first),
              FollowBand.direction(of: drawn, in: viewport) != nil else { return }   // already on screen
        // Real geometry above it, not estimated heights.
        column.ensureLayout(through: first)
        guard let rect = column.boundingRect(for: first) else { return }
        page.syncHeight()
        let clip = scrollView.contentView
        let highest = max(page.frame.height - clip.bounds.height, 0)
        let y = FollowBand.landingContentOffsetY(sentenceMinY: rect.minY, viewport: viewport,
                                                 contentOffsetY: clip.bounds.minY, range: 0...highest)
        guard abs(y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
        coordinator.userScrolledDiscretely()
    }

    // MARK: Play from here (R12a)

    func customActions() -> [NSAccessibilityCustomAction] {
        [playFromHereAction]
    }

    /// Plays from the cursor's sentence (or, with no cursor, the one the
    /// label names) through the click's path. False on the colophon, which
    /// is no sentence: Play reads Listen again there.
    @discardableResult
    func playFromHere() -> Bool {
        guard let coordinator, let content = builtContent else { return false }
        let id: Int?
        if let offset = cursorOffset() {
            id = cursorSentence(at: offset)
        } else if coordinator.shownColophon != nil {
            id = nil
        } else {
            id = restingSentence() ?? coordinator.activeSentence
        }
        guard let id, content.sentences.indices.contains(id) else { return false }
        coordinator.parent.onPlaySentence(id)
        return true
    }

    // MARK: Label and value

    /// What the page shows where VoiceOver is: always text on the page, and
    /// one sentence of it at most (or the colophon), never the book.
    func label() -> String? {
        guard let coordinator, let content = builtContent else { return nil }
        if let offset = cursorOffset() {
            if let id = cursorSentence(at: offset) { return content.sentences[id].text }
            if let colophon = coordinator.shownColophon { return colophon.spokenText }
        }
        if let colophon = coordinator.shownColophon { return colophon.spokenText }
        return restingSentence().map { content.sentences[$0].text }
    }

    /// R12e: the passage on screen, bounded.
    func value() -> String? {
        guard let coordinator, let textView, let viewport = coordinator.viewport() else { return nil }
        return Self.visibleText(of: textView, in: viewport)
    }

    /// The playhead's sentence while any of it is on screen, else the first
    /// sentence on screen. The playhead is measured from the follow chip's
    /// cached rect: VoiceOver asks for the label often, and a fresh measure
    /// would lay out the text up to a playhead far off screen each time.
    private func restingSentence() -> Int? {
        guard let coordinator, builtContent != nil, let viewport = coordinator.viewport(),
              viewport.height > 0 else { return nil }
        let active = coordinator.activeSentence
        if coordinator.shownColophon == nil, coordinator.sentenceRanges.indices.contains(active),
           let rect = coordinator.activeSentenceRect(), FollowBand.direction(of: rect, in: viewport) == nil {
            return active
        }
        let line = ReaderPageStyle(fontSize: coordinator.builtFontSize).lineHeight
        return column?.sentence(nearTopOf: viewport, lineStep: line, in: coordinator.sentenceRanges)
    }

    /// The page's TextKit 2 geometry as it stands. Never the TextKit 1
    /// layout object.
    private var column: ReaderColumnLayout? {
        guard let textView, let manager = textView.textLayoutManager else { return nil }
        return ReaderColumnLayout(textLayoutManager: manager, origin: textView.textContainerOrigin)
    }

    // MARK: The visible passage

    /// The characters of `textView` inside `viewport` (in the text view's
    /// coordinates), from the first line's start to the last line's end,
    /// cut to `valueLimit`; "" with no text, or no line in view. TextKit 2
    /// hit tests only: no layout beyond what is drawn.
    static func visibleText(of textView: NSTextView, in viewport: CGRect) -> String {
        guard let storage = textView.textStorage, storage.length > 0,
              let range = visibleCharacterRange(of: textView, in: viewport), range.length > 0 else { return "" }
        let text = storage.string as NSString
        let capped = NSRange(location: range.location, length: min(range.length, valueLimit))
        // Never half of a composed character at the cut.
        let whole = text.rangeOfComposedCharacterSequences(for: capped)
        return text.substring(with: NSIntersectionRange(whole, NSRange(location: 0, length: text.length)))
    }

    /// The UTF-16 range `viewport` shows. A top in the paper above the text
    /// starts at the text's start; a bottom below its end ends at its end.
    static func visibleCharacterRange(of textView: NSTextView, in viewport: CGRect) -> NSRange? {
        guard let manager = textView.textLayoutManager, let length = textView.textStorage?.length,
              viewport.height > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let layout = ReaderColumnLayout(textLayoutManager: manager, origin: origin)
        let width = max((textView.textContainer?.size.width ?? viewport.width) - 1, 0)
        let top = max(viewport.minY, origin.y)
        guard top < viewport.maxY else { return nil }
        guard let start = layout.characterOffset(at: CGPoint(x: origin.x, y: top)) else {
            // No line at the top: the page is past the end of the text.
            return NSRange(location: length, length: 0)
        }
        let end = layout.characterOffset(at: CGPoint(x: origin.x + width, y: viewport.maxY - 1)) ?? length
        let upper = min(max(end + 1, start), length)
        return NSRange(location: min(start, length), length: max(upper - min(start, length), 0))
    }
}

/// One rotor's item search, on the shared `ReaderRotor` walk.
private final class ReaderRotorSearch: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {

    let kind: ReaderRotor
    weak var owner: MacReaderAccessibility?

    init(kind: ReaderRotor, owner: MacReaderAccessibility) {
        self.kind = kind
        self.owner = owner
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters)
        -> NSAccessibilityCustomRotor.ItemResult? {
        // AppKit asks on the main thread. The result is no Sendable, so it
        // leaves the main actor through a local.
        var result: NSAccessibilityCustomRotor.ItemResult?
        MainActor.assumeIsolated { result = owner?.result(kind, for: searchParameters) }
        return result
    }
}

extension ReaderColumnView.Coordinator {
    /// Gives the page its rotors, its Play from here action, its label and
    /// its bounded value (`MacReaderAccessibility`). Once, from
    /// `makeScrollView()`; again changes nothing.
    func installAccessibility() {
        guard let textView, textView.readerAccessibility == nil else { return }
        textView.readerAccessibility = MacReaderAccessibility(coordinator: self)
    }
}
