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
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        MacTestSilence.installIfMuted()
        performed = []
        router = MacKeyRouter { [unowned self] command in
            performed.append(command)
            return true
        }
    }

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        router = nil
        super.tearDown()
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

    // MARK: - Helpers

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
