import AppKit

/// The plain keys (Space, ←, →, [ and ]) and the text-sensitive ⌘ keys, seen
/// before AppKit matches any menu key equivalent (M11, contracts §0).
///
/// A plain key goes to the window as AppKit would send it, minus the menu
/// pass: whatever natively uses it takes it (a text field types it, a
/// focused button presses on Space, a slider takes the arrows). Read-only
/// text, like the reader's page, runs the command at once. A key every
/// responder passes on (as the key, or as the text or move it was read as)
/// reaches `MacKeyTail` at the end of the window's chain and runs its
/// command there, once, or, with nothing to do, is swallowed. A key never
/// beeps, and a search field still types spaces and brackets.
///
/// ⌘←, ⌘→ and ⌘⌫ are also text keys: with an editable field focused they go
/// straight to it, so a menu item never takes the caret's moves. ↓ in a
/// search field goes to the list under it when that list offers to take
/// it (`MacSearchHandoff`), and to the field otherwise. ⌘Z in a field with
/// typing to undo undoes the typing, never Undo Jump, whose menu item sits
/// ahead of the system's Undo. ⌘=, the unshifted twin of ⌘+, runs Make
/// Text Bigger. Every other key passes through untouched. Installed once,
/// by the app delegate.
///
/// The tail also answers Edit ▸ Paste that nothing earlier in the chain
/// took, for the Library (`MacPasteTarget`).
@MainActor
final class MacKeyRouter {

    /// Runs a command; false when it had nothing to do.
    typealias Perform = @MainActor (MacCommand) -> Bool

    private let perform: Perform
    /// Where ↓ in a search field goes: the app's one, or a test's own.
    let searchHandoff: MacSearchHandoff
    /// Where Paste that reaches the tail goes: the app's one, or a test's own.
    let pasteTarget: MacPasteTarget
    private var monitor: Any?
    /// The plain key on its way through a window's chain, while it is, and
    /// whether it already ran its command there: one press, one command,
    /// however many ways it comes back unused.
    private var delivering: NSEvent?
    private var deliveryRan = false
    /// One tail, appended to each window the router sends a key to.
    let tail = MacKeyTail()

    init(searchHandoff: MacSearchHandoff? = nil, pasteTarget: MacPasteTarget? = nil,
         perform: @escaping Perform) {
        self.perform = perform
        self.searchHandoff = searchHandoff ?? .shared
        self.pasteTarget = pasteTarget ?? .shared
        tail.router = self
    }

    func install() {
        guard monitor == nil else { return }
        // AppKit calls the monitor on the main thread; the box carries the
        // event across the isolation check, which wants Sendable values.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let box = EventBox(event: event)
            return MainActor.assumeIsolated { () -> EventBox? in
                guard let self else { return box }
                return self.handle(box.event, in: box.event.window ?? NSApp.keyWindow).map(EventBox.init)
            }?.event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// What the monitor returns: the event, for AppKit's own dispatch, or
    /// nil once it was delivered or handled here.
    func handle(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        // Every window the keys reach ends in the tail (Settings and the
        // popovers too), so a ⌘ key no menu item takes is swallowed there,
        // never beeped.
        if let window { ensureTail(on: window) }
        if Self.isPlainDown(event), Self.isSearchFieldEditor(window?.firstResponder),
           !Self.isComposing(window?.firstResponder), searchHandoff.moveDown() {
            // ↓ from the search field into its results (M7), as Spotlight
            // does. The toolbar field's editor would take it for its caret
            // before the list could see it.
            return nil
        }
        if let command = MacCommand.alternateCommand(for: event) {
            // ⌘= has no menu item of its own: it runs Make Text Bigger here,
            // as ⌘+ would from the menu.
            run(command, in: window)
            return nil
        }
        if Self.isUndoKey(event), let window, Self.isEditableText(window.firstResponder),
           let undo = window.firstResponder?.undoManager, undo.canUndo {
            // ⌘Z in a field with typing to undo is the field's (the system
            // Undo's), never Undo Jump ahead of it in the Edit menu.
            undo.undo()
            return nil
        }
        guard let command = MacCommand.command(for: event), command.defersToEditableText else { return event }
        if let window, Self.isEditableText(window.firstResponder) {
            // A field types it (held down, too), or moves its caret on ⌘←
            // and ⌘→, before any menu can take it.
            window.sendEvent(event)
            return nil
        }
        // ⌘←, ⌘→, ⌘⌫ outside a field: the menu's.
        guard command.isPlainKey else { return event }
        // Holding Space, [ or ] down would toggle and step on every repeat.
        if event.isARepeat, !command.repeats { return nil }
        guard let window else {
            // No window at all (closed, Aloud still playing): the command.
            run(command, in: nil)
            return nil
        }
        if let text = window.firstResponder as? NSText, !text.isEditable {
            // Read-only text (the reader's page) never types: it would move
            // a hidden caret on the arrows and beep on Space or a bracket.
            run(command, in: window)
            return nil
        }
        ensureTail(on: window)
        delivering = event
        deliveryRan = false
        window.sendEvent(event)
        delivering = nil
        return nil
    }

    /// A plain key that every responder in a window passed on.
    fileprivate func unhandled(_ event: NSEvent) {
        if delivering === event {
            guard !deliveryRan else { return }
            deliveryRan = true
        }
        guard let command = MacCommand.plainCommand(for: event) else { return }
        run(command, in: event.window ?? NSApp.keyWindow)
    }

    /// The key being delivered came back as text or a move no one took (a
    /// responder read it through `interpretKeyEvents`): its command runs,
    /// once. Outside a delivery, nothing.
    fileprivate func unhandledDelivery() {
        guard let event = delivering else { return }
        unhandled(event)
    }

    /// Runs `command`, unless an alert, a sheet or a modal panel is up: the
    /// key is theirs to ignore, never a command behind them.
    private func run(_ command: MacCommand, in window: NSWindow?) {
        guard NSApp.modalWindow == nil, window?.attachedSheet == nil, window?.isSheet != true else { return }
        _ = perform(command)
    }

    /// Appends the tail to `window`'s responder chain unless it is there.
    /// SwiftUI may rebuild the chain, so every delivery checks. A chain that
    /// runs on into the app itself gets the tail just before it: past the
    /// window's own responders a key has no one left but the alert sound.
    func ensureTail(on window: NSWindow) {
        var last: NSResponder = window
        for _ in 0..<32 {
            guard let next = last.nextResponder, !(next is NSApplication) else {
                last.nextResponder = tail
                return
            }
            if next === tail { return }
            last = next
        }
    }

    /// ⌘Z, as the menus match it: by the shortcut table, or by the key's
    /// ⌘ layer. A Russian, Greek or Hebrew layout reads its own letter on
    /// the key ignoring modifiers, which the table never matches, while
    /// the menus still see ⌘Z and Undo Jump would take it (L030).
    static func isUndoKey(_ event: NSEvent) -> Bool {
        if MacCommand.command(for: event) == .undoJump { return true }
        guard event.type == .keyDown else { return false }
        return isUndoKey(commandLayer: event.charactersByApplyingModifiers(.command),
                         modifiers: event.modifierFlags)
    }

    /// ⌘ alone (⇧⌘Z is Redo) with the key whose ⌘ layer types "z".
    static func isUndoKey(commandLayer: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .shift, .option, .control]) == .command
            && commandLayer?.lowercased() == "z"
    }

    /// A field editor or an editable text view: it types every plain key.
    static func isEditableText(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSText { return text.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        return false
    }

    /// The window's field editor while a search field edits through it:
    /// the first responder of a focused search field, toolbar's included.
    static func isSearchFieldEditor(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate is NSSearchField
    }

    /// ↓ with no modifier: ⇧↓, ⌥↓ and ⌘↓ select or move in the field.
    private static func isPlainDown(_ event: NSEvent) -> Bool {
        event.specialKey == .downArrow && MacModifiers(event: event).isEmpty
    }

    /// An input method's unconfirmed text is in the field: its ↓ picks the
    /// next candidate, and the monitor sees the key before the input method.
    private static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}

/// ↓ in a search field, offered to the list under it (M7, mac-ux §3.4):
/// Spotlight's move from the field into its results. The toolbar search
/// field's editor takes every arrow before SwiftUI's content sees one, so
/// the router asks here first. One offer at a time: a view makes it as it
/// appears and withdraws it as it goes, and a withdrawal by a view whose
/// offer was since replaced leaves the newer one.
@MainActor
final class MacSearchHandoff {
    /// Moves focus into the list; false with nowhere to move it, and the
    /// field keeps the key.
    typealias Take = @MainActor () -> Bool

    /// The app's one: Classics offers, the router asks.
    static let shared = MacSearchHandoff()

    private var owner: UUID?
    private var take: Take?

    func offer(by owner: UUID, _ take: @escaping Take) {
        self.owner = owner
        self.take = take
    }

    func withdraw(by owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        take = nil
    }

    /// True once focus moved into the list.
    func moveDown() -> Bool {
        take?() ?? false
    }
}

/// ⌘V in the Library (M8), at the end of the window's chain. A paste
/// command on the Library's views is asked only while one of them has
/// keyboard focus, and with Full Keyboard Access off (the default) none
/// does, so Edit ▸ Paste would stay grey for a mouse. The tail answers
/// Paste for any chain that reaches it (a focused text field, a search
/// field's included, pastes for itself first) and asks here. One offer at
/// a time, as `MacSearchHandoff`'s: the Library makes it as it appears and
/// withdraws it as it goes, and a withdrawal by a view whose offer was
/// since replaced leaves the newer one.
@MainActor
final class MacPasteTarget {
    /// Adds what the pasteboard holds.
    typealias Paste = @MainActor (NSPasteboard) -> Void

    /// The app's one: the Library offers, the tail asks.
    static let shared = MacPasteTarget()

    /// The pasteboard Paste looks at (its types) as it validates and reads
    /// as it pastes: the system's, or a test's own.
    private let pasteboard: @MainActor () -> NSPasteboard
    private var owner: UUID?
    private var paste: Paste?

    init(pasteboard: @escaping @MainActor () -> NSPasteboard = { .general }) {
        self.pasteboard = pasteboard
    }

    func offer(by owner: UUID, _ paste: @escaping Paste) {
        self.owner = owner
        self.paste = paste
    }

    func withdraw(by owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        paste = nil
    }

    /// The Library is on screen, and the pasteboard holds what it takes: a
    /// file, or text, by type alone (`MacFileIntake.canAdmitPasteboard(_:)`).
    var canPaste: Bool {
        paste != nil && MacFileIntake.canAdmitPasteboard(pasteboard())
    }

    /// Hands the pasteboard to the Library; false when Paste is off.
    @discardableResult
    func pasteNow() -> Bool {
        guard canPaste, let paste else { return false }
        paste(pasteboard())
        return true
    }
}

/// An event, handed from AppKit's monitor callback to the main actor it
/// already runs on.
private struct EventBox: @unchecked Sendable {
    let event: NSEvent
}

private extension MacCommand {
    /// Only the arrows step again while held, as a held arrow does anywhere.
    var repeats: Bool { self == .back15 || self == .forward15 }
}

/// The last link of a window's responder chain. A key that reaches it was
/// handled by no one: a plain key runs its command, and any other key is
/// swallowed rather than beeped (M11). Paste that reaches it is the
/// Library's (M8).
final class MacKeyTail: NSResponder, NSMenuItemValidation, NSUserInterfaceValidations {
    fileprivate weak var router: MacKeyRouter?

    override func keyDown(with event: NSEvent) {
        router?.unhandled(event)
    }

    // A responder that reads keys as text and commands passes on what it
    // can't use as these, not as the key: Space or a bracket as text, an
    // arrow as a move. Each is the delivered key, still unhandled.

    override func insertText(_ insertString: Any) {
        router?.unhandledDelivery()
    }

    override func doCommand(by selector: Selector) {
        router?.unhandledDelivery()
    }

    override func moveLeft(_ sender: Any?) {
        router?.unhandledDelivery()
    }

    override func moveRight(_ sender: Any?) {
        router?.unhandledDelivery()
    }

    /// Nothing past the tail: an unhandled key ends here in silence.
    override func noResponder(for eventSelector: Selector) {}

    // MARK: Paste (M8)

    /// Edit ▸ Paste (⌘V) that no responder before the tail took: the
    /// Library adds what was copied, while it offers (`MacPasteTarget`).
    @objc func paste(_ sender: Any?) {
        guard Self.isUnobstructed, Self.libraryWindowHasKeys(NSApp.keyWindow) else { return }
        router?.pasteTarget.pasteNow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateUserInterfaceItem(menuItem)
    }

    /// Paste only with the Library on screen and something on the
    /// pasteboard it takes. The tail's other actions stay as AppKit leaves
    /// an unvalidated one: on.
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(paste(_:)) else { return true }
        return Self.isUnobstructed && Self.libraryWindowHasKeys(NSApp.keyWindow) && router?.pasteTarget.canPaste == true
    }

    /// The tail ends every window's chain, Settings' too: a ⌘V there must
    /// never add a book to the Library behind it. Paste is the main
    /// window's, or nobody's key window's.
    static func libraryWindowHasKeys(_ keyWindow: NSWindow?) -> Bool {
        guard let keyWindow else { return true }
        return keyWindow.accessibilityIdentifier() == MacWindowConfigurator.accessibilityIdentifier
    }

    /// No alert, sheet or modal panel is up: Paste is theirs to ignore,
    /// never a book added behind them (the plain keys' rule).
    private static var isUnobstructed: Bool {
        guard NSApp.modalWindow == nil else { return false }
        return [NSApp.keyWindow, NSApp.mainWindow].allSatisfy { window in
            window?.attachedSheet == nil && window?.isSheet != true
        }
    }
}
