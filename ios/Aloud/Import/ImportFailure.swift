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

    var title: String {
        switch self {
        case .pdfNoText: return "This PDF has no readable text."
        case .pdfLocked: return "This PDF is locked with a password."
        case .pdfDamaged: return "This PDF can't be opened."
        case .pdfNoPages: return "This PDF has no pages."
        case .textNoText: return "This file has no readable text."
        case .textUnreadable: return "This text file can't be read."
        case .outOfSpace: return "iPhone is out of space."
        case .couldNotOpen: return "This file couldn't be opened."
        case .classicMissing: return "This classic is missing from Aloud."
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
        case .couldNotOpen: return "Try adding it again from Files."
        case .classicMissing: return "Try another one from Classics."
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
}
