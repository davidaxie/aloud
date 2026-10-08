import SwiftUI

// MARK: - Add menu

/// The + menu's items both apps share, in order (R10): the bundled classics
/// and the Files picker. The iPhone's menu adds the clipboard's text after
/// them (`PasteTextAction`); the Mac pastes with its Edit menu instead.
enum LibraryAddMenuItem: CaseIterable {
    case classics, files

    var title: String { self == .classics ? "Classics" : "From Files\u{2026}" }
    var systemImage: String { self == .classics ? "books.vertical" : "folder" }
}

/// The iPhone's third way in: the text on the clipboard, added as a book of
/// its own (`DocumentImporter.importText(_:)`), the article copied in
/// Safari to listen to. The last item of the + menu; beside the empty
/// Library's other two links it is the system's paste control, which
/// labels itself.
enum PasteTextAction {
    /// The + menu's item.
    static let menuTitle = "Paste Text"
    static let systemImage = "doc.on.clipboard"

    /// The + menu's item read nothing although the clipboard held text: the
    /// paste prompt was declined, or Settings denies pasting. Said, with a
    /// way to Settings, rather than nothing happening.
    static let declinedTitle = "Aloud wasn't allowed to paste."
    static let declinedMessage = "Choose Allow Paste, or turn on Paste from Other Apps in Settings > Aloud."
    static let openSettings = "Open Settings"

    /// What a read of the clipboard found.
    enum Outcome: Equatable {
        case text(String)
        /// Text was there, but the read came back empty: declined.
        case declined
        /// The text had gone by the time it was read: nothing to say.
        case gone
    }

    /// `hadStrings` is the clipboard's `hasStrings`, read before the text
    /// itself (which asks first); `string` is what the read returned.
    static func outcome(hadStrings: Bool, string: String?) -> Outcome {
        if let string { return .text(string) }
        return hadStrings ? .declined : .gone
    }
}

// MARK: - Opening from the menu

/// The lead of the iPhone's long-press menu: the card's own tap, named by
/// whether the open will start the voice (`PlaybackController.opensPlaying`).
enum OpenMenuItem {
    static func title(plays: Bool) -> String { plays ? "Play" : "Open" }
    static func systemImage(plays: Bool) -> String { plays ? "play.fill" : "book" }
}

// MARK: - Document actions

/// What a card's context menu and VoiceOver actions offer (R12g), in order.
/// Kept apart from the views so every menu that acts on a book reads the
/// one list.
enum DocumentAction: CaseIterable {
    case rename, markFinished, delete

    var title: String {
        switch self {
        case .rename: return "Rename"
        // Title case, as Apple's menus spell items: the Mac's card menu
        // and menu bar read this same string (`MacMenuCopy.markFinished`).
        case .markFinished: return "Mark as Finished"
        case .delete: return "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .rename: return "pencil"
        case .markFinished: return "checkmark.circle"
        case .delete: return "trash"
        }
    }

    var role: ButtonRole? { self == .delete ? .destructive : nil }

    /// Delete's confirmation message, on both apps: what goes, and for a
    /// bundled classic, that it can come back.
    static func deleteMessage(for document: LibraryDocument) -> String {
        let removes = "This removes the book and your place in it."
        guard document.gutenbergID != nil else { return removes }
        return removes + " You can add it again from Classics."
    }

    /// A Finished book has nothing left to mark.
    static func available(for document: LibraryDocument) -> [DocumentAction] {
        allCases.filter { $0 != .markFinished || !document.isFinished }
    }

    /// The iPhone's long-press menu: the same actions, with Delete in a
    /// section of its own at the foot, apart from the ones that keep the
    /// book. VoiceOver's actions stay the flat `available(for:)` list.
    static func menuSections(for document: LibraryDocument) -> [[DocumentAction]] {
        let actions = available(for: document)
        return [actions.filter { $0 != .delete }, actions.filter { $0 == .delete }].filter { !$0.isEmpty }
    }
}
