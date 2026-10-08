import Foundation

/// Why an add failed, as the one fixed sentence the user sees plus what to do
/// next (R10). The copy is a closed table: an error's own text (Foundation's
/// "Error Domain=…" strings included) never reaches the screen.
enum ImportFailure: Equatable, CaseIterable {
    case pdfNoText
    case pdfLocked
    case pdfDamaged
    case pdfNoPages
    case textNoText
    case textUnreadable
    case outOfSpace
    case couldNotOpen
    case classicMissing
    /// A cloud placeholder (iCloud Drive, a File Provider) that couldn't be
    /// fetched, offline. Raised only by the Mac's coordinated copy; the
    /// iPhone's Files picker downloads before it hands a file over.
    case notDownloaded
    /// library.json couldn't be read at launch (a newer Aloud's record, a
    /// damaged file), so no book can be added to it: Delete's words
    /// (`DeleteFailure.libraryUnreadable`), never the file's fault.
    case libraryUnreadable
    /// A file of a type Aloud doesn't add, forced on the Mac by Open With
    /// Other: never read, so never said to have no readable text (L008).
    case unsupportedType

    var title: String {
        switch self {
        case .pdfNoText: return "This PDF has no readable text."
        case .pdfLocked: return "This PDF is locked with a password."
        case .pdfDamaged: return "This PDF can't be opened."
        case .pdfNoPages: return "This PDF has no pages."
        case .textNoText: return "This file has no readable text."
        case .textUnreadable: return "This text file can't be read."
        case .outOfSpace: return "\(DeviceNoun.Subject) is out of space."
        case .couldNotOpen: return "This file couldn't be opened."
        case .classicMissing: return "This classic is missing from Aloud."
        case .notDownloaded: return "This file isn't downloaded yet."
        case .libraryUnreadable: return "This book couldn't be added."
        case .unsupportedType: return "Aloud can't add this kind of file."
        }
    }

    /// `title`, naming the file when it was one of several handed over at
    /// once (the Mac's multi-file drop or pick, M8), so the alert says
    /// which of them failed (L007). Nil is the fixed sentence. Running out
    /// of space, or a classic, has no file of the user's to name.
    func title(naming fileName: String?) -> String {
        guard let fileName else { return title }
        let name = "\u{201C}\(fileName)\u{201D}"
        switch self {
        case .pdfNoText, .textNoText: return "\(name) has no readable text."
        case .pdfLocked: return "\(name) is locked with a password."
        case .pdfDamaged: return "\(name) can't be opened."
        case .pdfNoPages: return "\(name) has no pages."
        case .textUnreadable: return "\(name) can't be read."
        case .couldNotOpen: return "\(name) couldn't be opened."
        case .notDownloaded: return "\(name) isn't downloaded yet."
        case .libraryUnreadable: return "\(name) couldn't be added."
        case .unsupportedType: return "Aloud can't add \(name)."
        case .outOfSpace, .classicMissing: return title
        }
    }

    var nextStep: String {
        switch self {
        case .pdfNoText: return "Try a PDF with selectable text."
        case .pdfLocked: return "Remove the password, then add it again."
        case .pdfDamaged: return "Try another copy of the file."
        case .pdfNoPages: return "Try another PDF."
        case .textNoText: return "Try a PDF or a plain-text file."
        case .textUnreadable: return "Save it as UTF-8 plain text, then add it again."
        case .outOfSpace: return "Free up some space, then add it again."
        case .couldNotOpen: return DeviceCopy.addAgain
        case .classicMissing: return "Try another one from Classics."
        case .notDownloaded: return "Connect, then add it again."
        case .libraryUnreadable:
            return "Aloud couldn't read your library, so it leaves it as it is. Update Aloud, then try again."
        case .unsupportedType: return "Aloud adds PDFs and plain-text files."
        }
    }

    /// Classifies by type and code only. `isPDF` picks the PDF wording for
    /// the extraction errors both kinds of file can raise.
    init(_ error: any Error, isPDF: Bool) {
        switch error {
        case let extraction as ExtractionError:
            switch extraction {
            case .noReadableText: self = isPDF ? .pdfNoText : .textNoText
            case .emptyDocument: self = isPDF ? .pdfNoPages : .textNoText
            case .passwordProtected: self = .pdfLocked
            case .invalidPDF: self = .pdfDamaged
            case .unreadableTextFile: self = .textUnreadable
            }
        case is DocumentStoreError:
            self = .classicMissing
        case is LibraryIndexError:
            self = .libraryUnreadable
        default:
            self = Self.isOutOfSpace(error) ? .outOfSpace : .couldNotOpen
        }
    }

    /// CocoaError and POSIXError bridge to these two NSError domains, so one
    /// check covers all three spellings. A copy that fails for lack of space
    /// can also surface as a generic write error wrapping ENOSPC, so the
    /// underlying error is checked too.
    private static func isOutOfSpace(_ error: any Error) -> Bool {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return [nsError, underlying].contains { candidate in
            guard let candidate else { return false }
            return (candidate.domain == NSCocoaErrorDomain
                    && candidate.code == CocoaError.fileWriteOutOfSpace.rawValue)
                || (candidate.domain == NSPOSIXErrorDomain
                    && candidate.code == Int(POSIXErrorCode.ENOSPC.rawValue))
        }
    }
}

/// VoiceOver-only completion announcements for an add (R10).
enum ImportCopy {
    static func added(_ title: String) -> String { "Added \(title)" }
    static func alreadyInLibrary(_ title: String) -> String { "\(title) is already in your library" }
    /// Several files at once, announced once when the last ends (M8): the
    /// new books only, so a file already on the shelf isn't counted.
    static func addedBooks(_ count: Int) -> String { count == 1 ? "Added 1 book" : "Added \(count) books" }
    /// Several files at once, nothing new: two or more books already on the
    /// shelf (one is named, as `alreadyInLibrary`).
    static let booksAlreadyInLibrary = "These books are already in your library"
}
