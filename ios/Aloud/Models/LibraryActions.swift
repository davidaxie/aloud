import SwiftUI

// MARK: - Add menu

/// The + menu's items, in order (R10). Exactly two: the bundled classics
/// and the Files picker.
enum LibraryAddMenuItem: CaseIterable {
    case classics, files

    var title: String { self == .classics ? "Classics" : "From Files\u{2026}" }
    var systemImage: String { self == .classics ? "books.vertical" : "folder" }
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
}
