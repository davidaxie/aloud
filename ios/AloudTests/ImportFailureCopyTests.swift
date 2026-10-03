import XCTest
@testable import Aloud

/// R10: an add failure is one fixed sentence plus a next step. The copy is a
/// closed table, so no error's own text ("Error Domain=…") can reach the user.
final class ImportFailureCopyTests: XCTestCase {

    func testPDFRowIsThePRDCopy() {
        XCTAssertEqual(ImportFailure.pdfNoText.title, "This PDF has no readable text.")
        XCTAssertEqual(ImportFailure.pdfNoText.nextStep, "Try a PDF with selectable text.")
    }

    /// Every row as the iPhone reads it, letter for letter. The device noun
    /// now comes from `DeviceNoun`, and the words around it must not move.
    /// The Mac's one different row is pinned letter for letter too.
    func testEveryRowReadsAsItAlwaysHas() {
        #if os(iOS)
        let outOfSpace = "iPhone is out of space."
        #else
        let outOfSpace = "Your Mac is out of space."
        #endif
        let table: [ImportFailure: (title: String, nextStep: String)] = [
            .pdfNoText: ("This PDF has no readable text.", "Try a PDF with selectable text."),
            .pdfLocked: ("This PDF is locked with a password.", "Remove the password, then add it again."),
            .pdfDamaged: ("This PDF can't be opened.", "Try another copy of the file."),
            .pdfNoPages: ("This PDF has no pages.", "Try another PDF."),
            .textNoText: ("This file has no readable text.", "Try a PDF or a plain-text file."),
            .textUnreadable: ("This text file can't be read.", "Save it as UTF-8 plain text, then add it again."),
            .outOfSpace: (outOfSpace, "Free up some space, then add it again."),
            .couldNotOpen: ("This file couldn't be opened.", "Try adding it again from Files."),
            .classicMissing: ("This classic is missing from Aloud.", "Try another one from Classics."),
            .notDownloaded: ("This file isn't downloaded yet.", "Connect, then add it again."),
        ]
        XCTAssertEqual(Set(table.keys), Set(ImportFailure.allCases), "every row is pinned")
        for (failure, copy) in table {
            XCTAssertEqual(failure.title, copy.title, "\(failure) title")
            XCTAssertEqual(failure.nextStep, copy.nextStep, "\(failure) nextStep")
        }
        XCTAssertEqual(ImportFailure.outOfSpace.title, "\(DeviceNoun.Subject) is out of space.")
    }

    /// The Mac's cloud placeholder row: the iPhone's Files picker downloads
    /// before it hands a file over, so no error an iPhone add can raise
    /// reads as "not downloaded", the ubiquity ones included.
    func testNotDownloadedIsNeverClassifiedOnThePhone() {
        let errors: [any Error] = [
            CocoaError(.ubiquitousFileUnavailable),
            CocoaError(.ubiquitousFileNotUploadedDueToQuota),
            CocoaError(.fileReadNoSuchFile),
            URLError(.notConnectedToInternet),
        ]
        for error in errors {
            XCTAssertEqual(ImportFailure(error, isPDF: true), .couldNotOpen, "\(error)")
            XCTAssertEqual(ImportFailure(error, isPDF: false), .couldNotOpen, "\(error)")
        }
    }

    func testEveryRowIsOneSentencePlusANextStep() {
        let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
        for failure in ImportFailure.allCases {
            XCTAssertTrue(failure.title.hasSuffix("."), "\(failure) title")
            XCTAssertTrue(failure.nextStep.hasSuffix("."), "\(failure) nextStep")
            XCTAssertEqual(failure.title.filter(terminators.contains).count, 1, "\(failure) title")
        }
    }

    func testNoRowLeaksErrorOrImportWording() {
        let banned = ["Error Domain", "NSCocoaErrorDomain", "error", "import"]
        for failure in ImportFailure.allCases {
            for text in [failure.title, failure.nextStep] {
                for word in banned {
                    XCTAssertNil(text.range(of: word, options: .caseInsensitive),
                                 "\(failure): \"\(text)\" contains \(word)")
                }
            }
        }
    }

    func testForeignErrorTextIsNeverRead() {
        let error = NSError(domain: "NSCocoaErrorDomain", code: 260,
                            userInfo: [NSLocalizedDescriptionKey: "Error Domain=X"])
        XCTAssertEqual(ImportFailure(error, isPDF: true), .couldNotOpen)
        XCTAssertEqual(ImportFailure(error, isPDF: false), .couldNotOpen)
    }

    func testOutOfSpaceInEverySpelling() {
        XCTAssertEqual(ImportFailure(CocoaError(.fileWriteOutOfSpace), isPDF: true), .outOfSpace)
        XCTAssertEqual(ImportFailure(POSIXError(.ENOSPC), isPDF: false), .outOfSpace)
        XCTAssertEqual(ImportFailure(NSError(domain: NSCocoaErrorDomain, code: 640), isPDF: true),
                       .outOfSpace)
        XCTAssertEqual(ImportFailure(NSError(domain: NSPOSIXErrorDomain, code: 28), isPDF: true),
                       .outOfSpace)
    }

    func testExtractionErrorMapping() {
        let table: [(ExtractionError, pdf: ImportFailure, text: ImportFailure)] = [
            (.noReadableText, .pdfNoText, .textNoText),
            (.emptyDocument, .pdfNoPages, .textNoText),
            (.passwordProtected, .pdfLocked, .pdfLocked),
            (.invalidPDF, .pdfDamaged, .pdfDamaged),
            (.unreadableTextFile, .textUnreadable, .textUnreadable),
        ]
        for (error, pdf, text) in table {
            XCTAssertEqual(ImportFailure(error, isPDF: true), pdf, "\(error) as PDF")
            XCTAssertEqual(ImportFailure(error, isPDF: false), text, "\(error) as text")
        }
    }

    func testMissingClassicMapsToClassicMissing() {
        XCTAssertEqual(ImportFailure(DocumentStoreError.bundledBookMissing("x.txt"), isPDF: false),
                       .classicMissing)
    }

    func testAnnouncementCopy() {
        XCTAssertEqual(ImportCopy.added("Fixture"), "Added Fixture")
        XCTAssertEqual(ImportCopy.alreadyInLibrary("Fixture"), "Fixture is already in your library")
    }
}
