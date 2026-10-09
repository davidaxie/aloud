import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add menu

/// The + menu's items both apps share, in order (R10): the bundled classics
/// and the Files picker. The iPhone's menu adds the clipboard's text after
/// them (`PasteTextAction`); the Mac pastes with its Edit menu instead.
enum LibraryAddMenuItem: CaseIterable {
    case classics, files

    var title: String { self == .classics ? "Classics" : "From Files\u{2026}" }
    var systemImage: String { self == .classics ? "books.vertical" : "folder" }

    /// What the iPhone's Files picker accepts (the Mac's is
    /// `MacFileIntake.contentTypes`). The copy below names each one, and
    /// LibraryFileFormatsTests holds the two together.
    static let fileContentTypes: [UTType] = [.pdf, .plainText]

    /// R3-06: the From Files… item's second line on the iPhone's + menu.
    static let fileFormats = "PDF or plain text"
    /// VoiceOver's hint on Add a file, and the Mac's open panel message.
    static let fileFormatsHint = "Choose a PDF or plain-text file"
    /// The empty Library's line under its links (`FileFormatsCaption`).
    static let fileFormatsCaption = "Reads PDFs and plain-text files."
}

// MARK: - Classics shelf map

/// R3-05: one of the buttons in the Classics screen's first row, on both
/// apps, jumping to its shelf's heading. Made from
/// `BookshelfIndex.shelves(rate:)`, never a fixed list: a speed that
/// regroups the books, or empties a shelf, changes the row with it.
struct ShelfJump: Equatable, Identifiable {
    let section: BookshelfSection
    let count: Int

    var id: String { section.rawValue }
    var title: String { section.title }
    /// The quiet count beside the title.
    var countText: String { "\(count)" }
    var identifier: String { "bookshelf.jump.\(section.rawValue)" }
    /// VoiceOver's label: the shelf's title and its book count.
    var accessibilityLabel: String { "\(section.title), \(count == 1 ? "1 book" : "\(count) books")" }

    static let hint = "Jumps to this shelf"

    /// One per shelf at `rate`, in the shelves' order.
    static func jumps(in index: BookshelfIndex, rate: Double) -> [ShelfJump] {
        index.shelves(rate: rate).map { ShelfJump(section: $0.section, count: $0.books.count) }
    }
}

/// R3-05: how a shelf-map jump reaches a far shelf in the lazy Classics
/// list, on both apps. A lazy stack lays out only the rows near what it
/// shows; where everything else sits is estimated from the rows it has
/// measured. A scroll to a mark it hasn't laid out goes to that estimate,
/// and from the top of Classics, past a hundred rows of one- and two-line
/// titles, the longest shelf's mark was put some 160 books into it. A scroll
/// repeated there asked the same estimate and stayed, however many turns
/// it waited, since nothing between the top and the mark was ever laid out.
///
/// The walk never scrolls to anything the stack hasn't laid out. It
/// scrolls the deepest row laid out short of the shelf to the top, which
/// lays out the next screen of rows beside it from measured heights, and
/// asks again a run-loop turn later, until the shelf's mark is laid out
/// (it appeared, or rows on both sides of it did). Only then does the jump
/// scroll the mark to the top, which lands where it really is. Walking up,
/// from inside or past the shelf, scrolls the shallowest row to the bottom.
/// Appearances are counted, not kept in a set, so a row whose next
/// appearance comes before its last disappearance stays laid out.
final class ShelfWalk {
    enum Step: Equatable {
        /// The shelf's mark is laid out: scroll it to the top.
        case land(BookshelfSection)
        /// Scroll this laid-out row to the edge (the top walking down, the
        /// bottom walking up), then ask again a run-loop turn later.
        case hop(bookID: Int, edge: Edge)
        /// The rows the last hop brought in haven't appeared yet: ask again
        /// a turn later, scrolling nothing.
        case wait
    }

    enum Edge: Equatable { case top, bottom }

    /// Turns a walk waits for the rows its last hop brought in before it
    /// lands as it is, rather than walking forever on a stack that has
    /// stopped saying what it lays out.
    static let patience = 3

    private var rows: [Int: Int] = [:]
    private var marks: [BookshelfSection: Int] = [:]
    private var target: BookshelfSection?
    private var token = 0
    private var lastHop: Int?
    private var waits = 0
    private var steps = 0

    func rowAppeared(_ bookID: Int) { rows[bookID, default: 0] += 1 }
    func rowDisappeared(_ bookID: Int) { rows[bookID] = max((rows[bookID] ?? 0) - 1, 0) }
    func markAppeared(_ section: BookshelfSection) { marks[section, default: 0] += 1 }
    func markDisappeared(_ section: BookshelfSection) { marks[section] = max((marks[section] ?? 0) - 1, 0) }

    func isLaidOut(_ bookID: Int) -> Bool { (rows[bookID] ?? 0) > 0 }
    func isLaidOut(_ section: BookshelfSection) -> Bool { (marks[section] ?? 0) > 0 }

    /// Starts a walk to `section`, ending any walk before it; the token
    /// its steps are asked for by.
    @discardableResult
    func begin(toward section: BookshelfSection) -> Int {
        token += 1
        target = section
        lastHop = nil
        waits = 0
        steps = 0
        return token
    }

    /// Ends the walk under way, if any: a search took the list.
    func cancel() {
        token += 1
        target = nil
    }

    /// The walk's next step through `shelves`, the list's own, or nil once
    /// that walk is over: landed, cancelled or replaced by another jump.
    func next(_ token: Int, through shelves: [BookshelfShelf]) -> Step? {
        guard token == self.token, let target else { return nil }
        steps += 1
        let order = shelves.flatMap { $0.books.map(\.id) }
        // Every hop moves at least a row, and waits at most `patience`
        // turns: past that the stack isn't saying what it lays out.
        guard !isLaidOut(target),
              let start = Self.start(of: target, in: shelves),
              steps <= (order.count + 1) * (Self.patience + 1)
        else { return land(target) }
        // The mark sits between the shelf's first book and the book before
        // it: with both laid out, so is the mark.
        if start > 0, isLaidOut(order[start - 1]), isLaidOut(order[start]) { return land(target) }
        if let before = order[..<start].lastIndex(where: { isLaidOut($0) }) {
            return hop(order[before], .top, toward: target)
        }
        if let after = order[start...].firstIndex(where: { isLaidOut($0) }) {
            return hop(order[after], .bottom, toward: target)
        }
        // Nothing laid out to stand on: the mark's own scroll is all there is.
        return land(target)
    }

    /// Where the shelf's first book is in the list's order of rows.
    private static func start(of section: BookshelfSection, in shelves: [BookshelfShelf]) -> Int? {
        var start = 0
        for shelf in shelves {
            if shelf.section == section { return shelf.books.isEmpty ? nil : start }
            start += shelf.books.count
        }
        return nil
    }

    private func hop(_ bookID: Int, _ edge: Edge, toward section: BookshelfSection) -> Step {
        guard bookID == lastHop else {
            lastHop = bookID
            waits = 0
            return .hop(bookID: bookID, edge: edge)
        }
        waits += 1
        return waits > Self.patience ? land(section) : .wait
    }

    private func land(_ section: BookshelfSection) -> Step {
        target = nil
        return .land(section)
    }
}

/// The iPhone's third way in: the text on the clipboard, added as a book of
/// its own (`DocumentImporter.importText(_:)`), the article copied in
/// Safari to listen to. The last item of the + menu; in the link row under
/// the empty Library's featured classic and at the shelf's foot it is the
/// system's paste control, which labels itself, while there is text.
enum PasteTextAction {
    /// The + menu's item.
    static let menuTitle = "Paste Text"
    static let systemImage = "doc.on.clipboard"

    /// The + menu's item read nothing although the clipboard held text: the
    /// paste prompt was declined, or Settings denies pasting. Said, with a
    /// way to Settings, rather than nothing happening.
    static let declinedTitle = "Aloud wasn’t allowed to paste."
    static let declinedMessage = "Choose Allow Paste, or turn on Paste from Other Apps in Settings > Aloud."
    static let openSettings = "Open Settings"
    /// The shelf's paste control's VoiceOver hint (`PlatformPasteControl`);
    /// the control names itself.
    static let controlHint = "Adds the copied text as a book"
    /// The system control's own English label, measured to size it when it
    /// doesn't say (`PlatformPasteControl.labelSize`); never drawn by Aloud.
    static let controlTitle = "Paste"

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
    case rename, markFinished, markUnfinished, delete

    var title: String {
        switch self {
        case .rename: return "Rename"
        // Title case, as Apple's menus spell items: the Mac's card menu
        // and menu bar read these same strings (`MacMenuCopy`).
        case .markFinished: return "Mark as Finished"
        case .markUnfinished: return "Mark as Unfinished"
        case .delete: return "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .rename: return "pencil"
        case .markFinished: return "checkmark.circle"
        case .markUnfinished: return "arrow.uturn.backward.circle"
        case .delete: return "trash"
        }
    }

    var role: ButtonRole? { self == .delete ? .destructive : nil }

    /// What VoiceOver hears once Mark as Unfinished has put the place back,
    /// on both apps.
    static let markedUnfinished = "Marked as unfinished"

    /// Delete's confirmation message, on both apps: what goes, and for a
    /// bundled classic, that it can come back.
    static func deleteMessage(for document: LibraryDocument) -> String {
        let removes = "This removes the book and your place in it."
        guard document.gutenbergID != nil else { return removes }
        return removes + " You can add it again from Classics."
    }

    /// A Finished book has nothing left to mark, and offers its reverse in
    /// the same slot: Mark as Unfinished puts back the place it had. So a
    /// card always offers three.
    static func available(for document: LibraryDocument) -> [DocumentAction] {
        let finished = document.isFinished
        return allCases.filter { action in
            switch action {
            case .markFinished: return !finished
            case .markUnfinished: return finished
            case .rename, .delete: return true
            }
        }
    }

    /// The iPhone's long-press menu: the same actions, with Delete in a
    /// section of its own at the foot, apart from the ones that keep the
    /// book. VoiceOver's actions stay the flat `available(for:)` list.
    static func menuSections(for document: LibraryDocument) -> [[DocumentAction]] {
        let actions = available(for: document)
        return [actions.filter { $0 != .delete }, actions.filter { $0 == .delete }].filter { !$0.isEmpty }
    }
}
