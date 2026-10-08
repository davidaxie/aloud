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
/// Safari to listen to. The last item of the + menu, and a link beside the
/// empty Library's other two.
enum PasteTextAction {
    /// The + menu's item.
    static let menuTitle = "Paste Text"
    static let systemImage = "doc.on.clipboard"
    /// The empty Library's link, lower-case like its neighbours.
    static let linkTitle = "Paste text"
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
        case .markFinished: return "Mark as finished"
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
