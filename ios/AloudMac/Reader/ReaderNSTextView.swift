import AppKit
import QuartzCore
import SwiftUI

/// The book page's text view (M14, contracts §6): TextKit 2, read-only and
/// selectable, and quiet. `ReaderColumnView.Coordinator` measures and moves
/// it; this class owns what AppKit asks the view itself.
///
/// - A click (mouse-up, click count 1, no selection made) reports its point
///   for play-from-here; a drag selects as AppKit's does, and ⌘C copies
///   plain text.
/// - The right-click menu is built here, whole: Play from Here, Copy and
///   Look Up. Nothing of NSTextView's own (Speech, Font, Spelling,
///   Substitutions, Transformations, Layout Orientation, Share) and no
///   Services or Writing Tools.
/// - Keys: Space, ←, → and the brackets are the app's (`MacKeyRouter` runs
///   them before the page sees them). Scroll keys move the page as a user
///   scroll. `doCommand(by:)` swallows every other selector without passing
///   it on, so no key ends at `noResponder(for:)` and the alert sound.
/// - VoiceOver (M18): a native text area, identifier "reader.text", with
///   the rotors, the Play from here action, the label and the bounded value
///   of `MacReaderAccessibility` (R12a, R12e).
///
/// Made through AppKit's `init(usingTextLayoutManager:)`, so every stored
/// property here starts at zero (nil, false, 0): nothing relies on a Swift
/// initial value. It never asks for the TextKit 1 layout object, which
/// would drop it out of TextKit 2 for good.
final class ReaderNSTextView: NSTextView {

    // Wired by the coordinator; all optional, so zero is "not yet".

    /// A mouse-down landed on the page, before AppKit tracks it.
    var onClickLanded: (@MainActor () -> Void)?
    /// The click ended: its point in this view, its click count, and
    /// whether it left a selection.
    var onClickEnded: (@MainActor (CGPoint, Int, Bool) -> Void)?
    /// The sentence under a point (Play from Here), nil off the text.
    var sentenceAtPoint: (@MainActor (CGPoint) -> Int?)?
    /// The UTF-16 offset under a point (Look Up's word), nil off the text.
    var characterOffsetAtPoint: (@MainActor (CGPoint) -> Int?)?
    /// Where a range's first line sits on its baseline, for Look Up's panel.
    var baselineOrigin: (@MainActor (NSRange) -> CGPoint?)?
    var onPlayFromHere: (@MainActor (Int) -> Void)?
    /// A key command the page takes itself (the scroll keys); true when
    /// it did.
    var onCommand: (@MainActor (Selector) -> Bool)?
    var onAppearanceChange: (@MainActor () -> Void)?
    /// After every layout pass, as the iPhone's `onLayout`.
    var onLayout: (@MainActor () -> Void)?
    /// The frame changed (TextKit grew or shrank the text, or a resize).
    var onFrameChange: (@MainActor () -> Void)?
    /// VoiceOver's rotors, action, label and value; nil until the
    /// coordinator installs them.
    var readerAccessibility: MacReaderAccessibility?

    /// True while AppKit lays out or prepares the text: an offset that
    /// moves then is TextKit keeping its viewport, never the reader
    /// scrolling.
    private(set) var isLayingOut = false
    /// The click count of the mouse-down AppKit is tracking; 0 when none.
    private var armedClickCount = 0
    /// True while an accessibility client sets the selection: the
    /// selection that moves then is VoiceOver's cursor.
    private var isPlacingAccessibilityCursor = false

    // MARK: Layout

    override func layout() {
        isLayingOut = true
        super.layout()
        isLayingOut = false
        onLayout?()
    }

    override func prepareContent(in rect: NSRect) {
        let outer = isLayingOut
        isLayingOut = true
        super.prepareContent(in: rect)
        isLayingOut = outer
    }

    override func viewWillDraw() {
        let outer = isLayingOut
        isLayingOut = true
        super.viewWillDraw()
        isLayingOut = outer
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onFrameChange?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    // MARK: Click to play (R15)

    /// AppKit tracks a click or a drag selection inside `super.mouseDown`,
    /// through the mouse-up; the click is judged once that returns (or in
    /// `mouseUp`, when AppKit hands that on instead).
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else {
            // ⌃-click is the right-click menu, never a click to play.
            armedClickCount = 0
            super.mouseDown(with: event)
            return
        }
        onClickLanded?()
        armedClickCount = max(event.clickCount, 1)
        super.mouseDown(with: event)
        if armedClickCount > 0, let up = NSApp.currentEvent, up.type == .leftMouseUp {
            finishClick(at: up)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if armedClickCount > 0 { finishClick(at: event) }
    }

    private func finishClick(at event: NSEvent) {
        let clicks = armedClickCount
        armedClickCount = 0
        onClickEnded?(convert(event.locationInWindow, from: nil), clicks, hasSelection)
    }

    /// Some text is selected (a drag, a double-click, ⇧-click).
    var hasSelection: Bool {
        selectedRanges.contains { $0.rangeValue.length > 0 }
    }

    // MARK: Context menu (M14)

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    /// Play from Here (the sentence under the pointer), a separator, Copy
    /// (with a selection) and Look Up. Built afresh, never from `super`, so
    /// none of NSTextView's own items can come back with a macOS update.
    func contextMenu(at point: CGPoint) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }

        let sentence = sentenceAtPoint?(point)
        let play = NSMenuItem(title: ReaderMenuCopy.playFromHere,
                              action: #selector(playFromHereFromMenu(_:)), keyEquivalent: "")
        play.target = self
        play.tag = sentence ?? -1
        play.isEnabled = sentence != nil
        menu.addItem(play)
        menu.addItem(.separator())

        let copy = NSMenuItem(title: ReaderMenuCopy.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = hasSelection
        menu.addItem(copy)

        let term = lookUpRange(at: point)
        let lookUp = NSMenuItem(title: ReaderMenuCopy.lookUp(term.flatMap(lookUpTitleTerm)),
                                action: #selector(lookUpFromMenu(_:)), keyEquivalent: "")
        lookUp.target = self
        lookUp.isEnabled = term != nil
        lookUp.representedObject = term.map { NSValue(range: $0) }
        menu.addItem(lookUp)
        return menu
    }

    @objc func playFromHereFromMenu(_ sender: NSMenuItem) {
        guard sender.tag >= 0 else { return }
        onPlayFromHere?(sender.tag)
    }

    @objc func lookUpFromMenu(_ sender: NSMenuItem) {
        guard let range = (sender.representedObject as? NSValue)?.rangeValue,
              let storage = textStorage, NSMaxRange(range) <= storage.length,
              let origin = baselineOrigin?(range) else { return }
        showDefinition(for: storage.attributedSubstring(from: range), at: origin)
    }

    /// What Look Up looks up: the selection when the pointer is on it (or
    /// off the text), else the word under the pointer.
    private func lookUpRange(at point: CGPoint) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let offset = characterOffsetAtPoint?(point)
        let selection = selectedRange()
        if selection.length > 0, offset.map({ NSLocationInRange($0, selection) }) ?? true {
            return selection
        }
        guard let offset, offset < storage.length else { return nil }
        let word = storage.doubleClick(at: offset)
        guard word.length > 0 else { return nil }
        let text = storage.attributedSubstring(from: word).string
        return text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) ? word : nil
    }

    /// The term in Look Up's title, as AppKit's own item quotes it; nil for
    /// a long selection, which reads as the plain title.
    private func lookUpTitleTerm(_ range: NSRange) -> String? {
        guard let storage = textStorage, range.length <= ReaderMenuCopy.lookUpTermLimit else { return nil }
        let term = storage.attributedSubstring(from: range).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || term.contains("\n") ? nil : term
    }

    /// No Services for the page, in its menu or the app's: none of them
    /// reads a book.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        nil
    }

    /// ⌘C quotes the words, never the page's colors and fonts: of AppKit's
    /// own types, the plain-text one only. A text view writes it under its
    /// legacy name (it lands as public.utf8-plain-text); naming `.string`
    /// here instead would copy nothing at all.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter { $0 == .string || $0 == Self.legacyPlainText }
    }

    private static let legacyPlainText = NSPasteboard.PasteboardType("NSStringPboardType")

    /// Speech would read the selection through the system synthesizer, on
    /// the speakers, past the muted engine. `MacMenuPruner` keeps it out of
    /// the menus; should any item or service still ask, the page declines,
    /// in silence.
    override func startSpeaking(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSTextView.startSpeaking(_:)) { return false }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Keys (M11)

    override func keyDown(with event: NSEvent) {
        if MacCommand.plainCommand(for: event) != nil {
            // Space, ←, →, [ and ]: MacKeyRouter runs these before the page
            // sees them. One that gets here anyway goes to the window's key
            // tail, which runs its command; never to a hidden caret.
            keyTail?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    /// The router's tail on this view's responder chain, once a key has
    /// been delivered through the window.
    private var keyTail: MacKeyTail? {
        var responder = nextResponder
        for _ in 0..<32 {
            guard let current = responder else { return nil }
            if let tail = current as? MacKeyTail { return tail }
            responder = current.nextResponder
        }
        return nil
    }

    /// Read-only: typing is never text, and never the alert sound.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any) {
        guard isEditable else { return }
        super.insertText(insertString)
    }

    /// Every selector a key reads as ends here. The scroll keys move the
    /// page (`onCommand`), Tab leaves it, Esc goes to whoever takes it, and
    /// the selection keys extend the selection. Anything else is swallowed
    /// in silence: never handed on, so never `noResponder(for:)`.
    override func doCommand(by selector: Selector) {
        if onCommand?(selector) == true { return }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(self)
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectPreviousKeyView(self)
        case #selector(NSResponder.cancelOperation(_:)):
            // tryToPerform stops at the end of the chain without a sound.
            _ = nextResponder?.tryToPerform(selector, with: nil)
        default:
            if Self.selectionCommands.contains(selector), responds(to: selector) {
                _ = tryToPerform(selector, with: nil)
            }
        }
    }

    /// The keys that extend a selection (⇧ with the arrows and their
    /// friends: ⌘⇧ and ⌃⇧ with ← and → to the line's ends, ⇧Page Up and
    /// ⇧Page Down, and the Emacs keys ⌃⇧B/F and ⌃⌥⇧B/F) and ⌘A's selector.
    static let selectionCommands: Set<Selector> = [
        #selector(NSResponder.moveLeftAndModifySelection(_:)),
        #selector(NSResponder.moveRightAndModifySelection(_:)),
        #selector(NSResponder.moveBackwardAndModifySelection(_:)),
        #selector(NSResponder.moveForwardAndModifySelection(_:)),
        #selector(NSResponder.moveWordBackwardAndModifySelection(_:)),
        #selector(NSResponder.moveWordForwardAndModifySelection(_:)),
        #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)),
        #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)),
        #selector(NSResponder.pageUpAndModifySelection(_:)),
        #selector(NSResponder.pageDownAndModifySelection(_:)),
        #selector(NSResponder.moveUpAndModifySelection(_:)),
        #selector(NSResponder.moveDownAndModifySelection(_:)),
        #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
        #selector(NSResponder.moveWordRightAndModifySelection(_:)),
        #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
        #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
        #selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:)),
        #selector(NSResponder.moveToEndOfParagraphAndModifySelection(_:)),
        #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)),
        #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)),
        #selector(NSResponder.moveParagraphForwardAndModifySelection(_:)),
        #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:)),
        #selector(NSResponder.selectAll(_:)),
    ]

    // MARK: VoiceOver (M18, R12a, R12e)

    /// A native text area, whatever else asks: VoiceOver reads it by line,
    /// word and character through AppKit's ranged text attributes.
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    /// Pinned: the UI tests' handle, as on the iPhone.
    override func accessibilityIdentifier() -> String { MacReaderAccessibility.identifier }

    /// The sentence where VoiceOver is (or the colophon), never the book.
    override func accessibilityLabel() -> String? {
        readerAccessibility?.label() ?? super.accessibilityLabel()
    }

    /// R12e: the passage on screen, bounded; never a text view's own value,
    /// which is the whole book. Before the coordinator installs its part,
    /// the passage is measured in the view's own visible rect.
    override func accessibilityValue() -> String? {
        readerAccessibility?.value() ?? MacReaderAccessibility.visibleText(of: self, in: visibleRect)
    }

    /// Chapters (Pages), Paragraphs and Sentences, searched on demand.
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        readerAccessibility?.customRotors() ?? []
    }

    /// Play from here (VO-⌘-Space).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        readerAccessibility?.customActions()
    }

    /// VoiceOver placing its cursor, on a rotor result or in the text.
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let outer = isPlacingAccessibilityCursor
        isPlacingAccessibilityCursor = true
        super.setAccessibilitySelectedTextRange(range)
        // However AppKit keeps it, the cursor is the text's selection.
        if range.location != NSNotFound, NSMaxRange(range) <= textStorage?.length ?? 0, selectedRange() != range {
            setSelectedRange(range)
        }
        isPlacingAccessibilityCursor = outer
        if !outer { readerAccessibility?.cursorPlaced() }
    }

    /// Every selection change comes through here; one no accessibility
    /// client made (a click, a drag, a new build) leaves VoiceOver's
    /// cursor behind.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isPlacingAccessibilityCursor { readerAccessibility?.selectionMoved() }
    }
}

// MARK: - The scroll view

/// The page's scroll view. It tells a coast apart (momentum after the
/// fingers lift, or a flung wheel), so a click on moving text only stops
/// it (R15), reports a mouse's wheel (which no live scroll announces), and
/// reports each tile, when its size settles.
final class ReaderScrollView: NSScrollView {

    /// Momentum is moving the page.
    private(set) var isCoasting = false
    /// From a gesture's first momentum event to its last, dropped ones
    /// included: the fingers are off the trackpad.
    private(set) var inMomentum = false
    /// A click (or following) stopped the coast: its remaining momentum is
    /// dropped until the next gesture starts.
    private var dropsMomentum = false
    /// When the last coast stopped (system uptime), at its end or under a
    /// new touch.
    private var coastStoppedAt: TimeInterval?
    /// A click this soon after a coast stops still landed on moving text:
    /// the finger that clicks touches the trackpad first, and that touch
    /// can end the momentum before the mouse-down arrives.
    static let coastGrace: TimeInterval = 0.3
    /// Test seam: the clock `coastStoppedAt` is read against.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// True while the scroll view takes a new size or tiles: the clip view
    /// moving then is AppKit keeping it on the page, never the reader.
    private(set) var isResizing = false
    var onTile: (@MainActor () -> Void)?
    /// A wheel event with no phases (a mouse's wheel), before it scrolls.
    var onPhaselessWheel: (@MainActor () -> Void)?

    /// Momentum is moving the page, or stopped a moment ago.
    var isCoastingOrJustStopped: Bool {
        if isCoasting { return true }
        guard let coastStoppedAt else { return false }
        return now() - coastStoppedAt < Self.coastGrace
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            // A new touch stops any momentum still running.
            if isCoasting { coastStopped() }
            inMomentum = false
            dropsMomentum = false
        }
        let momentum = event.momentumPhase
        if !momentum.isEmpty {
            let ending = momentum.contains(.ended) || momentum.contains(.cancelled)
            inMomentum = !ending
            if ending {
                if isCoasting { coastStopped() }
            } else if !dropsMomentum {
                isCoasting = true
            }
            // A stopped coast's momentum goes unheard, so the page stays
            // still and the next click plays; the ending event still goes
            // through, so the live scroll ends.
            if dropsMomentum, !ending { return }
        } else if event.phase.isEmpty, event.scrollingDeltaY != 0 {
            // No gesture: AppKit posts no live scroll for it, and a glide
            // in flight would carry on over it.
            onPhaselessWheel?()
        }
        super.scrollWheel(with: event)
    }

    /// A click on coasting text, or following taking the scroll back: the
    /// page stops where it is.
    func stopCoasting() {
        guard isCoasting || inMomentum else { return }
        isCoasting = false
        dropsMomentum = true
    }

    /// The live scroll is over (momentum included).
    func liveScrollEnded() {
        if isCoasting { coastStopped() }
        inMomentum = false
    }

    private func coastStopped() {
        isCoasting = false
        coastStoppedAt = now()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let outer = isResizing
        isResizing = true
        super.setFrameSize(newSize)
        isResizing = outer
    }

    override func tile() {
        let outer = isResizing
        isResizing = true
        super.tile()
        onTile?()
        isResizing = outer
    }
}

// MARK: - The page

/// The scroll view's document: the paper the page is set on, flipped like
/// the text. From the back: the highlight (`HighlightLayers`, beneath the
/// text, never in it), the text view, and the colophon's veil while it
/// fades in. The text view sits at the top-left, so the page's coordinates
/// are the text's, the content coordinates every follow decision uses.
/// Below the text the page adds `bottomInset` of paper, so the end of the
/// book can still reach the landing line (M15).
final class ReaderPageView: NSView {

    let textView: ReaderNSTextView
    let highlightView: ReaderHighlightView
    /// The three highlight shapes, in the highlight view's layer.
    let highlight: HighlightLayers
    /// Paper below the text: 0.45 × the visible height.
    var bottomInset: CGFloat = 0 {
        didSet { if bottomInset != oldValue { syncHeight() } }
    }
    /// The page is at least this tall (the clip view's height), so a short
    /// text still fills the page.
    var minimumHeight: CGFloat = 0 {
        didSet { if minimumHeight != oldValue { syncHeight() } }
    }
    /// TextKit's own figure for the text's height, when it runs ahead of
    /// the text view's frame (a deep jump's layout pass).
    var laidOutTextHeight: (@MainActor () -> CGFloat?)?

    init(textView: ReaderNSTextView) {
        self.textView = textView
        let host = ReaderHighlightView()
        // Layer-backed: AppKit keeps the layer's geometry the view's own,
        // flipped included, so the shapes use the page's coordinates.
        host.wantsLayer = true
        highlightView = host
        highlight = HighlightLayers(host: host.layer ?? CALayer())
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        autoresizingMask = [.width]
        textView.frame = bounds
        highlightView.frame = bounds
        addSubview(highlightView)
        addSubview(textView, positioned: .above, relativeTo: highlightView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Paper, not an element: VoiceOver finds one thing on it, the text
    /// area, which names the scroll area as its parent. The highlight and
    /// the veil are drawing, never children.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? { [textView] }

    /// The text's height and the paper under it, never shorter than the
    /// clip view.
    var contentHeight: CGFloat {
        let text = max(textView.frame.maxY, laidOutTextHeight?() ?? 0)
        return max(text + bottomInset, minimumHeight)
    }

    /// Follows the text view's frame; the highlight spans the page.
    func syncHeight() {
        let height = contentHeight.rounded(.up)
        if frame.height != height {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
        let highlightFrame = bounds
        if highlightView.frame != highlightFrame {
            highlightView.frame = highlightFrame
        }
    }

    /// Room for an offset of `y` in a clip view `visibleHeight` tall
    /// before the text view's frame has caught up with TextKit, so the
    /// clip view never clamps a placement short.
    func ensureRoom(forOffset y: CGFloat, visibleHeight: CGFloat) {
        let needed = (y + visibleHeight).rounded(.up)
        if frame.height < needed {
            setFrameSize(NSSize(width: frame.width, height: needed))
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        highlightView.frame = bounds
    }
}

/// The highlight's host: flipped, so its layer's shapes use the page's
/// top-down coordinates, and never in the way of a click or VoiceOver.
final class ReaderHighlightView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// The paper-colored cover the colophon fades in from (R24).
final class ReaderVeilView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

// MARK: - Measure

/// The page's measure (M14, mac-ux §3.5): a column `min(width − 2 ×
/// gutter, 33 em)` wide, centered through the text container inset, 32
/// below the top, with 0.45 × the visible height of paper under the end.
enum ReaderColumnMetrics {
    /// The widest column in ems of the text size: about 627 pt at 19 pt.
    static let maxEms: CGFloat = 33
    /// The first line rests this far below the top of the page.
    static let topInset: CGFloat = Theme.Space.xxl
    static let bottomFraction: CGFloat = 0.45

    /// The column for a page `width` wide; the window's gutter (32, 20
    /// below 600) comes off both sides first.
    static func columnWidth(forWidth width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let gutter = MacGridMetrics.gutter(forWindowWidth: width)
        return max(min(width - 2 * gutter, maxEms * fontSize), 0).rounded(.down)
    }

    /// Either side of the centered column, rounded up: the text container
    /// takes what the two insets leave (`widthTracksTextView`), which is
    /// then never a point past the measure.
    static func sideInset(forWidth width: CGFloat, fontSize: CGFloat) -> CGFloat {
        max(((width - columnWidth(forWidth: width, fontSize: fontSize)) / 2).rounded(.up), 0)
    }

    static func bottomInset(forVisibleHeight height: CGFloat) -> CGFloat {
        (max(height, 0) * bottomFraction).rounded()
    }
}

// MARK: - Copy

/// The page's right-click menu, in the menus' title case (M14).
enum ReaderMenuCopy {
    static let playFromHere = "Play from Here"
    static let copy = "Copy"
    /// Look Up, quoting its term as AppKit's own item does.
    static func lookUp(_ term: String?) -> String {
        guard let term else { return "Look Up" }
        return "Look Up \u{201C}\(term)\u{201D}"
    }
    /// The longest term the title quotes.
    static let lookUpTermLimit = 24
}

// MARK: - Colors

extension ReaderInk {
    /// The theme's colors as they draw: each resolves for the appearance
    /// it is drawn under (light or dark, Increase Contrast or not), and so
    /// do the rule images, whose drawing handler fills in them. A change of
    /// look only redraws the page: no edit drops TextKit's layout, so
    /// nothing is laid out again from the top of the book.
    static func live() -> ReaderInk {
        func live(_ color: Color) -> NSColor {
            NSColor(name: nil) { appearance in
                NSColor(cgColor: appearance.resolvedCGColor(color)) ?? NSColor(color)
            }
        }
        return ReaderInk(text: live(Theme.text),
                         textMuted: live(Theme.textMuted),
                         accent: live(Theme.accent),
                         lineStrong: live(Theme.lineStrong),
                         ruleImage: { size, color in
                             PlatformRuleImage.make(size: size, color: color, scale: 2)
                         })
    }
}

extension NSAppearance {
    /// A theme color as it draws under this appearance (light or dark,
    /// Increase Contrast or not).
    func resolvedCGColor(_ color: Color) -> CGColor {
        let dynamic = NSColor(color)
        var resolved = dynamic.cgColor
        performAsCurrentDrawingAppearance {
            resolved = dynamic.cgColor
        }
        return resolved
    }
}

// MARK: - Glide timing

extension FollowBand {
    /// The glide's (0.4, 0, 0.2, 1) curve for `NSAnimationContext`.
    static func mediaTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(glideCurve.0.x), Float(glideCurve.0.y),
                              Float(glideCurve.1.x), Float(glideCurve.1.y))
    }
}
