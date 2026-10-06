import AppKit

/// The Dock icon's menu (M13, mac-ux §6.2): while a book is loaded, its
/// title (disabled, a header), then Play or Pause, Back 15 Seconds and
/// Forward 15 Seconds. With none loaded there is no menu, so only the
/// system's items show. No sleep timer, recents or voice.
///
/// Each item runs the Playback menu's own command through
/// `MacCommandActions`, with its title and enabled state, so the Dock, the
/// menu, the keys and the media keys land on the same sentence (the one
/// `skip(seconds:)`), and a skip with nothing to play stays disabled.
///
/// AppKit asks on every right-click and keeps the items only while the menu
/// is open, so the menu is built fresh each time, with the state of that
/// moment. The items' target is this object: its owner keeps it.
@MainActor
final class MacDockMenu: NSObject {

    /// The Playback items the Dock repeats, in the Playback menu's order.
    static let commands: [MacCommand] = [.playPause, .back15, .forward15]

    private let actions: MacCommandActions

    init(actions: MacCommandActions) {
        self.actions = actions
    }

    /// The menu now: the header and the three items, or nil with no book.
    func menu() -> NSMenu? {
        guard let document = actions.playback.document else { return nil }
        let menu = NSMenu()
        // The items carry their states; the Dock has no responder chain to
        // validate them against.
        menu.autoenablesItems = false

        // The store's record is the live one: it carries a rename first,
        // as Now Playing reads it.
        let live = actions.store.documents.first { $0.id == document.id } ?? document
        let header = NSMenuItem(title: live.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for command in Self.commands {
            // No key equivalent: the Dock shows none, and the plain keys are
            // the router's (M11).
            let item = NSMenuItem(title: actions.title(for: command), action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.isEnabled = actions.isEnabled(command)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func run(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let command = MacCommand(rawValue: name) else { return }
        actions.perform(command)
    }
}
