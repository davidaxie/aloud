import AppKit
import ObjectiveC

/// Speech out of every text menu (M11, testing §1.3). A text view's
/// right-click menu carries Speech ▸ Start Speaking, which reads the
/// selection through the system synthesizer, on the speakers, past the
/// muted engine. `MacMenuPruner` clears the menu bar; a context menu is
/// built afresh on each right-click, so the prune runs there instead.
///
/// The text that needs it most is the field editor: the one text view per
/// window that every SwiftUI text and search field edits through (the
/// Classics search, the Rename field). The window makes it, and the
/// window's delegate is SwiftUI's, so neither a subclass nor
/// `windowWillReturnFieldEditor(_:to:)` can reach it. Instead
/// `NSTextView.menu(for:)` passes its menu through `MacMenuPruner` before
/// AppKit shows it, for the field editors and every other text view alike.
/// A text view of Aloud's own that builds its menu without `super` prunes
/// it itself.
@MainActor
enum MacFieldEditor {

    private static var isInstalled = false

    /// Once, before the first window. Release too: Speech would talk over
    /// Aloud's own voice.
    static func install() {
        guard !isInstalled else { return }
        let selector = #selector(NSView.menu(for:))
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return }
        isInstalled = true
        // NSTextView's own, or NSView's when it inherits one. Replacing on
        // NSTextView leaves every other view's menu as it was.
        typealias MenuForEvent = @convention(c) (NSView, Selector, NSEvent) -> NSMenu?
        let original = unsafeBitCast(method_getImplementation(method), to: MenuForEvent.self)
        let pruned: @convention(block) (NSView, NSEvent) -> NSMenu? = { view, event in
            let menu = original(view, selector, event)
            MainActor.assumeIsolated { MacMenuPruner.removeSpeech(from: menu) }
            return menu
        }
        class_replaceMethod(NSTextView.self, selector, imp_implementationWithBlock(pruned),
                            method_getTypeEncoding(method))
    }
}
