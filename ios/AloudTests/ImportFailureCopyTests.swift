import XCTest
@testable import Aloud

/// R10: an add failure is one fixed sentence plus a next step. The copy is a
/// closed table, so no error's own text ("Error Domain=…") can reach the user.
final class ImportFailureCopyTests: XCTestCase {

    func testPDFRowIsThePRDCopy() {
        XCTAssertEqual(ImportFailure.pdfNoText.title, "This PDF has no readable text.")
        XCTAssertEqual(ImportFailure.pdfNoText.nextStep, "Try a PDF with selectable text.")
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
