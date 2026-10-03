import AppKit
import XCTest
@testable import Aloud

/// The plain keys go to whatever natively uses them, and to their command
/// only when nothing does (M11). Windows here are never ordered in: the
/// hosted run shows nothing. Every key is one the table names, and the
/// muted host's `noResponder(for:)` is silent, so no test can beep.
@MainActor
final class MacKeyRouterTests: XCTestCase {

    private var performed: [MacCommand] = []
    private var router: MacKeyRouter!
    private var handoff: MacSearchHandoff!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        MacTestSilence.installIfMuted()
        performed = []
        handoff = MacSearchHandoff()
        router = MacKeyRouter(searchHandoff: handoff) { [unowned self] command in
            performed.append(command)
            return true
        }
    }

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        router = nil
        handoff = nil
        super.tearDown()
    }

    /// Any key a window gets, a ⌘ key the menus may refuse included, gives
    /// that window the tail: Settings' chain ends there too, so a key no
    /// menu item takes is swallowed rather than beeped.
    func testEveryWindowAKeyReachesEndsInTheTail() {
        let window = makeWindow()
        XCTAssertFalse(Self.chain(of: window).contains { $0 === router.tail }, "a new window has no tail yet")
        let followVoice = MacShortcutsTests.key("j", code: 38, flags: .command, window: window)
        XCTAssertNotNil(router.handle(followVoice, in: window), "⌘J is still the menu's to take")
        XCTAssertTrue(Self.chain(of: window).contains { $0 === router.tail }, "but the window now ends in the tail")
        XCTAssertEqual(performed, [])
    }

    /// The tail's Paste belongs to the main window (or to no key window):
    /// from Settings it never adds a book to the Library behind it.
    func testTheTailsPasteIsTheMainWindowsOnly() {
        XCTAssertTrue(MacKeyTail.libraryWindowHasKeys(nil))
        let main = makeWindow()
        main.setAccessibilityIdentifier(MacWindowConfigurator.accessibilityIdentifier)
        XCTAssertTrue(MacKeyTail.libraryWindowHasKeys(main))
        let settings = makeWindow()
        settings.setAccessibilityIdentifier("aloud.window.settings")
        XCTAssertFalse(MacKeyTail.libraryWindowHasKeys(settings))
    }

    private static func chain(of window: NSWindow) -> [NSResponder] {
        var chain: [NSResponder] = []
        var next: NSResponder? = window
        while let responder = next, chain.count < 40 {
            chain.append(responder)
            next = responder.nextResponder
        }
        return chain
    }

    /// A focused, editable text view types Space as a space, and no
    /// command runs: a search field keeps its spaces.
    func testEditableTextGetsSpaceAndNoCommandFires() throws {
        let (window, text) = makeWindowWithText(editable: true)
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, window: window), in: window),
                     "the router delivered it, past the menus")
        XCTAssertTrue(Self.isOneTypedSpace(text.string), "typed \"\(text.string)\"")
        XCTAssertEqual(performed, [])
    }

    func testEditableTextGetsBracketsAndArrows() throws {
        let (window, text) = makeWindowWithText(editable: true)
        XCTAssertNil(router.handle(MacShortcutsTests.key("]", code: 30, window: window), in: window))
        XCTAssertFalse(text.string.isEmpty, "the bracket was typed")
        XCTAssertNil(router.handle(MacShortcutsTests.arrow(left: true, window: window), in: window))
        XCTAssertEqual(performed, [], "no speed step, no skip while typing")
    }

    /// ⌘← moves the caret in a field; nowhere else does the router touch it.
    func testCommandArrowGoesToTheFieldOnly() throws {
        let (window, _) = makeWindowWithText(editable: true)
        let event = MacShortcutsTests.arrow(left: true, flags: .command, window: window)
        XCTAssertNil(router.handle(event, in: window), "the field takes it before Previous Chapter")
        XCTAssertEqual(performed, [])

        let bare = makeWindow()
        let menuEvent = MacShortcutsTests.arrow(left: true, flags: .command, window: bare)
        XCTAssertTrue(router.handle(menuEvent, in: bare) === menuEvent, "the menu's to match")
    }

    /// No window at all (closed while playing): Space toggles.
    func testWithNoFirstResponderSpaceToggles() {
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49), in: nil))
        XCTAssertEqual(performed, [.playPause])
    }

    /// The window itself is first responder: Space passes through the chain
    /// unhandled, reaches the tail, and toggles.
    func testUnhandledSpaceReachesTheTailAndToggles() {
        let window = makeWindow()
        window.makeFirstResponder(nil)
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, window: window), in: window))
        XCTAssertEqual(performed, [.playPause])
        XCTAssertNil(router.handle(MacShortcutsTests.key("]", code: 30, window: window), in: window))
        XCTAssertEqual(performed, [.playPause, .faster])
    }

    /// A view that reads keys as text and commands and uses none of them
    /// passes them on as such; each still runs its command, once.
    func testKeysReadAsTextOrMovesStillRunTheirCommand() {
        let window = makeWindow()
        let view = InterpretingView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, window: window), in: window))
        XCTAssertNil(router.handle(MacShortcutsTests.key("]", code: 30, window: window), in: window))
        XCTAssertNil(router.handle(MacShortcutsTests.arrow(left: true, window: window), in: window))
        XCTAssertEqual(performed, [.playPause, .faster, .back15])
        XCTAssertEqual(view.keys, 3, "the view saw each key first")
    }

    /// A view that reads the key as text and then passes the key on too:
    /// still one press, one command.
    func testAKeyComingBackTwiceRunsOnce() {
        let window = makeWindow()
        let view = InterpretingView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.passesKeysOn = true
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, window: window), in: window))
        XCTAssertEqual(performed, [.playPause])
    }

    /// Outside a delivery, text or a move reaching the tail does nothing.
    func testTheTailIgnoresTextOutsideADelivery() {
        router.tail.insertText(" ")
        router.tail.doCommand(by: #selector(MacKeyTail.moveLeft(_:)))
        XCTAssertEqual(performed, [])
    }

    /// A selectable, read-only text view isn't typing: the key is a command.
    func testReadOnlyTextIsNotTyping() {
        let (window, text) = makeWindowWithText(editable: false)
        XCTAssertFalse(MacKeyRouter.isEditableText(text))
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, window: window), in: window))
        XCTAssertEqual(text.string, "")
        XCTAssertEqual(performed, [.playPause])
    }

    func testKeysOutsideTheTablePassThrough() {
        let window = makeWindow()
        let find = MacShortcutsTests.key("j", code: 38, flags: .command, window: window)
        XCTAssertTrue(router.handle(find, in: window) === find)
        let letter = MacShortcutsTests.key("q", code: 12, window: window)
        XCTAssertTrue(router.handle(letter, in: window) === letter)
        XCTAssertEqual(performed, [])
    }

    /// Holding Space doesn't toggle on every repeat; a held arrow skips on.
    func testRepeatsStepOnlyTheArrows() {
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, repeats: true), in: nil))
        XCTAssertEqual(performed, [])
        let held = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
                                    charactersIgnoringModifiers: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
                                    isARepeat: true, keyCode: 124)!
        XCTAssertNil(router.handle(held, in: nil))
        XCTAssertEqual(performed, [.forward15])
    }

    /// A held key still repeats in a field: only commands ignore repeats.
    func testHeldSpaceStillTypesInAField() {
        let (window, text) = makeWindowWithText(editable: true)
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, window: window, repeats: true), in: window))
        XCTAssertTrue(Self.isOneTypedSpace(text.string), "typed \"\(text.string)\"")
        XCTAssertEqual(performed, [])
    }

    /// The tail joins a chain once, at its end.
    func testTailIsAppendedOnce() {
        let window = makeWindow()
        router.ensureTail(on: window)
        router.ensureTail(on: window)
        var chain: [NSResponder] = []
        var next = window.nextResponder
        while let responder = next, chain.count < 16 {
            chain.append(responder)
            next = responder.nextResponder
        }
        XCTAssertEqual(chain.filter { $0 === router.tail }.count, 1)
        XCTAssertTrue(chain.last === router.tail)
    }

    /// A chain that runs on into the app gets the tail just before it, so a
    /// key past the window's responders still ends in silence.
    func testTailGoesBeforeTheApp() {
        let window = makeWindow()
        window.nextResponder = NSApp
        router.ensureTail(on: window)
        XCTAssertTrue(window.nextResponder === router.tail)
        XCTAssertNil(router.tail.nextResponder)
    }

    // MARK: - ↓ from a search field

    /// ↓ in a search field goes to the list that offered to take it (M7):
    /// the field never sees it, and no command runs.
    func testDownFromASearchFieldGoesToTheList() throws {
        var takes = 0
        handoff.offer(by: UUID()) { takes += 1; return true }
        let (window, _) = try makeWindowWithSearchField()
        XCTAssertNil(router.handle(Self.down(window: window), in: window), "the list took it")
        XCTAssertEqual(takes, 1)
        XCTAssertEqual(performed, [])
    }

    /// A list with no row to take focus leaves ↓ to the field's caret.
    func testDownStaysTheFieldsWhenTheListTakesNothing() throws {
        var takes = 0
        handoff.offer(by: UUID()) { takes += 1; return false }
        let (window, _) = try makeWindowWithSearchField()
        let down = Self.down(window: window)
        XCTAssertTrue(router.handle(down, in: window) === down, "AppKit's, for the field")
        XCTAssertEqual(takes, 1)
    }

    /// With no list offering, and with ⇧↓, ⌥↓ or ⌘↓ (which select or move
    /// in the field), ↓ is the field's, untouched.
    func testDownWithoutAnOfferOrWithAModifierStaysTheFields() throws {
        let (window, _) = try makeWindowWithSearchField()
        let alone = Self.down(window: window)
        XCTAssertTrue(router.handle(alone, in: window) === alone, "no list offered")

        var takes = 0
        handoff.offer(by: UUID()) { takes += 1; return true }
        for flags: NSEvent.ModifierFlags in [.shift, .option, .command] {
            let held = Self.down(flags: flags, window: window)
            XCTAssertTrue(router.handle(held, in: window) === held, "\(flags.rawValue) is the field's")
        }
        XCTAssertEqual(takes, 0)
        XCTAssertEqual(performed, [])
    }

    /// Only a search field hands ↓ on: a plain text field and a text view
    /// keep it for their caret, and outside a field it is AppKit's.
    func testDownOutsideASearchFieldPassesOn() throws {
        var takes = 0
        handoff.offer(by: UUID()) { takes += 1; return true }
        let fieldWindow = makeWindow()
        let field = NSTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        fieldWindow.contentView?.addSubview(field)
        XCTAssertTrue(fieldWindow.makeFirstResponder(field))
        XCTAssertTrue(fieldWindow.firstResponder is NSTextView, "the text field is editing")
        XCTAssertFalse(MacKeyRouter.isSearchFieldEditor(fieldWindow.firstResponder))
        let inField = Self.down(window: fieldWindow)
        XCTAssertTrue(router.handle(inField, in: fieldWindow) === inField)

        let (textWindow, text) = makeWindowWithText(editable: true)
        XCTAssertFalse(MacKeyRouter.isSearchFieldEditor(text))
        let inText = Self.down(window: textWindow)
        XCTAssertTrue(router.handle(inText, in: textWindow) === inText)

        let bare = makeWindow()
        let inWindow = Self.down(window: bare)
        XCTAssertTrue(router.handle(inWindow, in: bare) === inWindow)
        XCTAssertTrue(router.handle(inWindow, in: nil) === inWindow)
        XCTAssertEqual(takes, 0)
        XCTAssertEqual(performed, [])
    }

    /// While an input method composes in the field (a CJK source's
    /// unconfirmed text), ↓ picks its next candidate: the field's, with the
    /// list offering.
    func testDownWhileComposingStaysTheFields() throws {
        var takes = 0
        handoff.offer(by: UUID()) { takes += 1; return true }
        let (window, _) = try makeWindowWithSearchField()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setMarkedText("ぷ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText(), "the field is composing")
        let down = Self.down(window: window)
        XCTAssertTrue(router.handle(down, in: window) === down, "the input method's")
        XCTAssertEqual(takes, 0)

        editor.unmarkText()
        XCTAssertNil(router.handle(Self.down(window: window), in: window), "once confirmed, the list's")
        XCTAssertEqual(takes, 1)
        XCTAssertEqual(performed, [])
    }

    /// One offer at a time: the newest stands, and a view that goes
    /// withdraws only its own.
    func testTheNewestOfferStandsUntilItsOwnerWithdraws() {
        let (first, second) = (UUID(), UUID())
        var taken: [String] = []
        handoff.offer(by: first) { taken.append("first"); return true }
        handoff.offer(by: second) { taken.append("second"); return true }
        handoff.withdraw(by: first)
        XCTAssertTrue(handoff.moveDown())
        handoff.withdraw(by: second)
        XCTAssertFalse(handoff.moveDown(), "nothing offered")
        XCTAssertEqual(taken, ["second"])
    }

    // MARK: - Helpers

    /// ↓, which carries the function and keypad flags by itself.
    private static func down(flags: NSEvent.ModifierFlags = [], window: NSWindow?) -> NSEvent {
        MacShortcutsTests.key(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), code: 125,
                              flags: flags.union([.function, .numericPad]), window: window)
    }

    /// A search field being edited, as after ⌘F: the window's field editor
    /// is first responder, on the field's behalf.
    private func makeWindowWithSearchField() throws -> (NSWindow, NSSearchField) {
        let window = makeWindow()
        let field = NSSearchField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        field.stringValue = "pride"
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field edits through the field editor")
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertTrue(MacKeyRouter.isSearchFieldEditor(editor))
        return (window, field)
    }

    /// One space: " ", or the full-width one a CJK input source types for
    /// Space on this Mac.
    private static func isOneTypedSpace(_ typed: String) -> Bool {
        typed == " " || typed == "\u{3000}"
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    /// Reads every key through the key bindings (no input context) and
    /// uses none: what SwiftUI's hosting view may do with a key it ignores.
    private final class InterpretingView: NSView {
        private(set) var keys = 0
        /// Also hands the key itself up the chain afterwards.
        var passesKeysOn = false
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            keys += 1
            interpretKeyEvents([event])
            if passesKeysOn { super.keyDown(with: event) }
        }
    }

    private func makeWindowWithText(editable: Bool) -> (NSWindow, NSTextView) {
        let window = makeWindow()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        text.isEditable = editable
        text.isSelectable = true
        window.contentView?.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        if editable {
            text.inputContext?.activate()
            addTeardownBlock { @MainActor in text.inputContext?.deactivate() }
        }
        return (window, text)
    }
}
