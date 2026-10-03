import AppKit
import XCTest
@testable import Aloud

/// M11: no text menu offers Speech ▸ Start Speaking, which would read the
/// selection through the system synthesizer past the muted engine. A
/// right-click in a search field is a right-click in its window's field
/// editor, so that menu is checked, and a plain text view's too. Each keeps
/// its editing items. The window is never ordered in, so nothing shows.
@MainActor
final class MacFieldEditorTests: XCTestCase {

    func testTheFieldEditorsMenuHasNoSpeech() throws {
        MacFieldEditor.install()
        let window = makeWindow()
        let field = NSSearchField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        field.stringValue = "Read me aloud"
        window.contentView?.addSubview(field)
        // Editing, as after a click in the field: the field editor is in.
        _ = window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView,
                                   "the search field edits through the window's field editor")
        XCTAssertTrue(editor.isFieldEditor)
        editor.selectAll(nil)

        let menu = try XCTUnwrap(editor.menu(for: rightClick(in: window, at: NSPoint(x: 40, y: 52))))
        XCTAssertEqual(Self.speechItems(in: menu), [], "no Speech ▸ Start Speaking")
        XCTAssertTrue(Self.contains(#selector(NSText.copy(_:)), in: menu), "Copy is still offered")
    }

    /// A text view whose menu is known to carry Speech ▸, so the check
    /// fails if the hook ever stops running, whatever the system's own text
    /// menu holds on this macOS.
    func testATextViewsMenuHasNoSpeech() throws {
        MacFieldEditor.install()
        MacFieldEditor.install()   // once only: a second install doesn't wrap the menu twice
        let window = makeWindow()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.string = "Read me aloud."
        textView.menu = Self.menuWithSpeech()
        XCTAssertFalse(Self.speechItems(in: try XCTUnwrap(textView.menu)).isEmpty, "the menu starts with Speech")
        window.contentView?.addSubview(textView)
        textView.selectAll(nil)

        let menu = try XCTUnwrap(textView.menu(for: rightClick(in: window, at: NSPoint(x: 20, y: 100))))
        XCTAssertEqual(Self.speechItems(in: menu), [])
        XCTAssertTrue(Self.contains(#selector(NSText.copy(_:)), in: menu))
    }

    /// The prune itself: a Speech ▸ submenu goes whole, loose Speech items
    /// go alone, and everything else stays.
    func testThePruneTakesOnlySpeech() {
        let menu = Self.menuWithSpeech()
        menu.addItem(withTitle: "Start Speaking", action: NSSelectorFromString("startSpeaking:"), keyEquivalent: "")

        MacMenuPruner.removeSpeech(from: menu)
        XCTAssertEqual(menu.items.map(\.title), ["Copy"])
    }

    // MARK: - Helpers

    /// Copy, then a Speech ▸ submenu as AppKit's text menu spells it.
    private static func menuWithSpeech() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let speech = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        speech.submenu = NSMenu(title: "Speech")
        speech.submenu?.addItem(withTitle: "Start Speaking", action: NSSelectorFromString("startSpeaking:"),
                                keyEquivalent: "")
        speech.submenu?.addItem(withTitle: "Stop Speaking", action: NSSelectorFromString("stopSpeaking:"),
                                keyEquivalent: "")
        menu.addItem(speech)
        return menu
    }

    /// Not deferred, so its events carry a real window number; never
    /// ordered in.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    private func rightClick(in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Every Speech item at any depth, and any submenu titled Speech, by
    /// title.
    private static func speechItems(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            let isSpeech = item.action.map { MacMenuPruner.speechActions.contains(NSStringFromSelector($0)) } ?? false
            let own = isSpeech || (item.submenu != nil && item.title == "Speech") ? [item.title] : []
            return own + (item.submenu.map(speechItems(in:)) ?? [])
        }
    }

    private static func contains(_ action: Selector, in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            item.action == action || (item.submenu.map { contains(action, in: $0) } ?? false)
        }
    }
}
