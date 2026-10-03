import AppKit
import SwiftUI

// The one keyboard table (mac-prd, Keyboard shortcuts; M11). The menus, the
// tooltips, the key router and the tests all read it, so a key, its title
// and its menu can't drift apart.

/// The menu a command sits in.
enum MacMenu: String, CaseIterable, Sendable {
    case aloud, file, edit, view, playback, window
}

/// A key on the keyboard, as the table names it.
enum MacShortcutKey: Hashable, Sendable {
    case character(Character)
    case space, leftArrow, rightArrow, delete

    /// What SwiftUI binds a menu item to.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let character): return KeyEquivalent(character)
        case .space: return .space
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .delete: return .delete
        }
    }

    /// How a menu or a tooltip spells it: "Space", "←", "O".
    var symbol: String {
        switch self {
        case .character(let character): return String(character).uppercased()
        case .space: return "Space"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .delete: return "⌫"
        }
    }

    /// The key a key-down event carries, ignoring its modifiers. Arrows and
    /// Delete by key, the rest by the character the layout types.
    init?(event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: self = .leftArrow
        case .rightArrow?: self = .rightArrow
        case .delete?, .backspace?: self = .delete
        default:
            guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
                  let character = characters.first else { return nil }
            self = character == " " ? .space : .character(character.lowercased().first ?? character)
        }
    }
}

/// The modifiers a shortcut holds down, in the Mac's spelling order.
struct MacModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let control = MacModifiers(rawValue: 1 << 0)
    static let option = MacModifiers(rawValue: 1 << 1)
    static let shift = MacModifiers(rawValue: 1 << 2)
    static let command = MacModifiers(rawValue: 1 << 3)

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if contains(.control) { modifiers.insert(.control) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// "⌃⌥⇧⌘", in Apple's order.
    var symbol: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }

    /// An event's held modifiers. Function, keypad and Caps Lock aren't
    /// held for a shortcut: an arrow carries the first two by itself.
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: MacModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// A key and its modifiers.
struct MacShortcut: Hashable, Sendable {
    let key: MacShortcutKey
    var modifiers: MacModifiers = []

    /// No modifier: Space, ←, →, [ and ]. These never become menu key
    /// equivalents; `MacKeyRouter` dispatches them, so a text field still
    /// types them.
    var isPlain: Bool { modifiers.isEmpty }

    /// "⇧⌘O", "Space".
    var symbol: String { modifiers.symbol + key.symbol }
}

/// Every command with a menu item or a key. Title case is the menus'; the
/// tooltips use the shared sentence case (`help`).
enum MacCommand: String, CaseIterable, Sendable {
    // Playback
    case playPause, back15, forward15, previousChapter, nextChapter, followVoice
    case faster, slower, voiceAndSpeed, sleepTimer
    // Edit
    case undoJump, find, deleteBook
    // View
    case toggleContents, biggerText, smallerText, appearance, back
    // File
    case addFromFiles, addClassic, closeWindow
    // Built by AppKit or SwiftUI, listed so no command of ours takes their key
    case settings, fullScreen, minimize, hide, quit

    /// The menu item's title at rest. A few change with the state (Pause,
    /// Hide Contents, Previous Page): `MacCommandActions.title(for:)`.
    var title: String {
        switch self {
        case .playPause: return MacMenuCopy.play
        case .back15: return MacMenuCopy.back15
        case .forward15: return MacMenuCopy.forward15
        case .previousChapter: return MacMenuCopy.previousChapter
        case .nextChapter: return MacMenuCopy.nextChapter
        case .followVoice: return MacMenuCopy.followVoice
        case .faster: return MacMenuCopy.faster
        case .slower: return MacMenuCopy.slower
        case .voiceAndSpeed: return MacMenuCopy.voiceAndSpeed
        case .sleepTimer: return MacMenuCopy.sleepTimer
        case .undoJump: return MacMenuCopy.undoJump
        case .find: return MacMenuCopy.find
        case .deleteBook: return MacMenuCopy.deleteBook
        case .toggleContents: return MacMenuCopy.showContents
        case .biggerText: return MacMenuCopy.biggerText
        case .smallerText: return MacMenuCopy.smallerText
        case .appearance: return MacMenuCopy.appearance
        case .back: return MacMenuCopy.back
        case .addFromFiles: return MacMenuCopy.addFromFiles
        case .addClassic: return MacMenuCopy.addClassic
        case .closeWindow: return MacMenuCopy.close
        case .settings: return MacMenuCopy.settings
        case .fullScreen: return MacMenuCopy.fullScreen
        case .minimize: return MacMenuCopy.minimize
        case .hide: return MacMenuCopy.hide
        case .quit: return MacMenuCopy.quit
        }
    }

    /// nil: a menu item with no key (Voice & Speed…, the two submenus).
    var shortcut: MacShortcut? {
        switch self {
        case .playPause: return MacShortcut(key: .space)
        case .back15: return MacShortcut(key: .leftArrow)
        case .forward15: return MacShortcut(key: .rightArrow)
        case .previousChapter: return MacShortcut(key: .leftArrow, modifiers: .command)
        case .nextChapter: return MacShortcut(key: .rightArrow, modifiers: .command)
        case .followVoice: return MacShortcut(key: .character("j"), modifiers: .command)
        case .faster: return MacShortcut(key: .character("]"))
        case .slower: return MacShortcut(key: .character("["))
        case .voiceAndSpeed, .sleepTimer, .appearance: return nil
        case .undoJump: return MacShortcut(key: .character("z"), modifiers: .command)
        case .find: return MacShortcut(key: .character("f"), modifiers: .command)
        case .deleteBook: return MacShortcut(key: .delete, modifiers: .command)
        case .toggleContents: return MacShortcut(key: .character("s"), modifiers: [.control, .command])
        case .biggerText: return MacShortcut(key: .character("+"), modifiers: .command)
        case .smallerText: return MacShortcut(key: .character("-"), modifiers: .command)
        case .back: return MacShortcut(key: .character("["), modifiers: .command)
        case .addFromFiles: return MacShortcut(key: .character("o"), modifiers: .command)
        case .addClassic: return MacShortcut(key: .character("o"), modifiers: [.shift, .command])
        case .closeWindow: return MacShortcut(key: .character("w"), modifiers: .command)
        case .settings: return MacShortcut(key: .character(","), modifiers: .command)
        case .fullScreen: return MacShortcut(key: .character("f"), modifiers: [.control, .command])
        case .minimize: return MacShortcut(key: .character("m"), modifiers: .command)
        case .hide: return MacShortcut(key: .character("h"), modifiers: .command)
        case .quit: return MacShortcut(key: .character("q"), modifiers: .command)
        }
    }

    var menu: MacMenu {
        switch self {
        case .playPause, .back15, .forward15, .previousChapter, .nextChapter, .followVoice,
             .faster, .slower, .voiceAndSpeed, .sleepTimer:
            return .playback
        case .undoJump, .find, .deleteBook: return .edit
        case .toggleContents, .biggerText, .smallerText, .appearance, .back, .fullScreen: return .view
        case .addFromFiles, .addClassic, .closeWindow: return .file
        case .settings, .hide, .quit: return .aloud
        case .minimize: return .window
        }
    }

    /// AppKit or SwiftUI builds the item: Settings… (the Settings scene),
    /// Enter Full Screen, Minimize, Hide Aloud and Quit Aloud.
    var isSystem: Bool {
        switch self {
        case .settings, .fullScreen, .minimize, .hide, .quit: return true
        default: return false
        }
    }

    var isPlainKey: Bool { shortcut?.isPlain ?? false }

    /// A key a focused text field also edits with: it types the plain keys,
    /// ⌘← and ⌘→ move the caret, and ⌘⌫ deletes to the line's start. The
    /// router hands these to the field before any menu sees them.
    var defersToEditableText: Bool {
        isPlainKey || self == .previousChapter || self == .nextChapter || self == .deleteBook
    }

    /// The tooltip: the shared sentence-case name and the key, "Back 15
    /// seconds (←)".
    var help: String {
        guard let shortcut else { return MacMenuCopy.Help.label(for: self) }
        return "\(MacMenuCopy.Help.label(for: self)) (\(shortcut.symbol))"
    }

    /// The plain-key command an event asks for: Space, ←, →, [ or ] with no
    /// modifier held.
    static func plainCommand(for event: NSEvent) -> MacCommand? {
        command(for: event).flatMap { $0.isPlainKey ? $0 : nil }
    }

    /// The command whose key an event is, if any.
    static func command(for event: NSEvent) -> MacCommand? {
        guard let key = MacShortcutKey(event: event) else { return nil }
        return command(for: MacShortcut(key: key, modifiers: MacModifiers(event: event)))
    }

    static func command(for shortcut: MacShortcut) -> MacCommand? {
        allCases.first { $0.shortcut == shortcut }
    }
}

/// The menus' own copy: title case for menu items, as Apple's menus spell
/// them. Shared sentence-case strings stay in their own tables; these are
/// only what a Mac menu says.
enum MacMenuCopy {
    static let playbackMenu = "Playback"
    static let about = "About Aloud"

    static let play = "Play"
    static let pause = "Pause"
    static let tryAgain = "Try Again"
    static let listenAgain = "Listen Again"
    static let back15 = "Back 15 Seconds"
    static let forward15 = "Forward 15 Seconds"
    static let previousChapter = "Previous Chapter"
    static let nextChapter = "Next Chapter"
    static let previousPage = "Previous Page"
    static let nextPage = "Next Page"
    static let followVoice = "Follow the Voice"
    static let faster = "Faster"
    static let slower = "Slower"
    static let voiceAndSpeed = "Voice & Speed\u{2026}"
    static let sleepTimer = "Sleep Timer"
    static let endOfChapter = "End of Chapter"
    static let endOfBook = "End of Book"
    static let off = "Off"

    static let undoJump = "Undo Jump"
    static let findMenu = "Find"
    static let find = "Find\u{2026}"
    /// "Book" keeps it apart from the system's text Delete beside it.
    static let deleteBook = "Delete Book\u{2026}"

    static let showContents = "Show Contents"
    static let hideContents = "Hide Contents"
    static let biggerText = "Make Text Bigger"
    static let smallerText = "Make Text Smaller"
    static let appearance = "Appearance"
    static let back = "Back"

    static let addFromFiles = "Add from Files\u{2026}"
    static let addClassic = "Add a Classic\u{2026}"
    static let close = "Close"

    static let settings = "Settings\u{2026}"
    static let fullScreen = "Enter Full Screen"
    static let minimize = "Minimize"
    static let hide = "Hide Aloud"
    static let quit = "Quit Aloud"

    /// Every menu title above, for the table's tests.
    static let all: Set<String> = [
        playbackMenu, play, pause, tryAgain, listenAgain, back15, forward15, previousChapter, nextChapter,
        previousPage, nextPage, followVoice, faster, slower, voiceAndSpeed, sleepTimer, endOfChapter,
        endOfBook, off, undoJump, findMenu, find, deleteBook, showContents, hideContents, biggerText,
        smallerText, appearance, back, addFromFiles, addClassic, close, settings, fullScreen, minimize,
        hide, quit, about,
    ]

    /// The tooltips' names, in the shared sentence case.
    enum Help {
        static func label(for command: MacCommand) -> String {
            switch command {
            case .playPause: return "Play or pause"
            case .back15: return "Back 15 seconds"
            case .forward15: return "Forward 15 seconds"
            case .previousChapter: return "Previous chapter"
            case .nextChapter: return "Next chapter"
            case .followVoice: return "Follow the voice"
            case .faster: return "Faster"
            case .slower: return "Slower"
            case .voiceAndSpeed: return ListeningCopy.title
            case .sleepTimer: return SleepTimer.Copy.section
            case .undoJump: return "Undo jump"
            case .find: return "Find"
            case .deleteBook: return "Delete book"
            case .toggleContents: return "Contents"
            case .biggerText: return "Bigger text"
            case .smallerText: return "Smaller text"
            case .appearance: return AppearanceCopy.title
            case .back: return "Back"
            case .addFromFiles: return "Add from Files"
            case .addClassic: return "Add a classic"
            case .closeWindow: return "Close the window"
            case .settings: return "Settings"
            case .fullScreen: return "Full screen"
            case .minimize: return "Minimize"
            case .hide: return "Hide Aloud"
            case .quit: return "Quit Aloud"
            }
        }
    }
}
