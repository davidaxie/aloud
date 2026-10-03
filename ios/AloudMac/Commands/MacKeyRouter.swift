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
/// straight to it, so a menu item never takes the caret's moves. Every
/// other key passes through untouched. Installed once, by the app delegate.
@MainActor
final class MacKeyRouter {

    /// Runs a command; false when it had nothing to do.
    typealias Perform = @MainActor (MacCommand) -> Bool

    private let perform: Perform
    private var monitor: Any?
    /// The plain key on its way through a window's chain, while it is, and
    /// whether it already ran its command there: one press, one command,
    /// however many ways it comes back unused.
    private var delivering: NSEvent?
    private var deliveryRan = false
    /// One tail, appended to each window the router sends a key to.
    let tail = MacKeyTail()

    init(perform: @escaping Perform) {
        self.perform = perform
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

    /// A field editor or an editable text view: it types every plain key.
    static func isEditableText(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSText { return text.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        return false
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
/// swallowed rather than beeped (M11).
final class MacKeyTail: NSResponder {
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
}
