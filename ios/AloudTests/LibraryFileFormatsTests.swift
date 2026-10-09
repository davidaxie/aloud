import XCTest
import UniformTypeIdentifiers
@testable import Aloud

/// R3-06: Add a file says which files it takes, on both apps, and the
/// words can't drift from the pickers: every type a picker accepts is
/// named in the + menu's line, the VoiceOver hint (the Mac's open panel
/// message) and the empty Library's caption.
final class LibraryFileFormatsTests: XCTestCase {

    /// How the copy names each type a picker may accept. A type added to a
    /// picker with no name here fails `testEveryAcceptedTypeIsNamed`, so its
    /// name is added, and the copy says it, in the same change.
    private static let names: [UTType: [String]] = [
        .pdf: ["PDF"],
        .plainText: ["plain text", "plain-text"],
    ]

    private static let copy = [
        LibraryAddMenuItem.fileFormats,
        LibraryAddMenuItem.fileFormatsHint,
        LibraryAddMenuItem.fileFormatsCaption,
    ]

    /// The iPhone's Files picker, and on the Mac its open panel's.
    private var acceptedTypes: [UTType] {
        #if os(macOS)
        return LibraryAddMenuItem.fileContentTypes + MacFileIntake.contentTypes
        #else
        return LibraryAddMenuItem.fileContentTypes
        #endif
    }

    func testEveryAcceptedTypeIsNamed() {
        for type in acceptedTypes {
            XCTAssertNotNil(Self.names[type], "name \(type.identifier) in the copy and here")
        }
    }

    func testTheCopyNamesEveryAcceptedType() {
        for type in acceptedTypes {
            let names = Self.names[type] ?? []
            for line in Self.copy {
                XCTAssertTrue(names.contains { line.localizedCaseInsensitiveContains($0) },
                              "\u{201C}\(line)\u{201D} never names \(type.identifier)")
            }
        }
    }

    /// The copy names nothing the pickers turn away (an EPUB, a Word file).
    func testTheCopyNamesNothingThePickersRefuse() {
        let refused = ["EPUB", "RTF", "Word", "DOC"]
        for line in Self.copy {
            for name in refused {
                XCTAssertFalse(line.range(of: "\\b\(name)\\b", options: [.regularExpression, .caseInsensitive]) != nil,
                               "\u{201C}\(line)\u{201D} names \(name)")
            }
        }
    }

    /// The iPhone's picker and the Mac's take the same files.
    func testBothAppsAcceptTheSameFiles() {
        #if os(macOS)
        XCTAssertEqual(Set(LibraryAddMenuItem.fileContentTypes), Set(MacFileIntake.contentTypes))
        #endif
        XCTAssertEqual(LibraryAddMenuItem.fileContentTypes, [.pdf, .plainText])
    }

    /// The caption reads as a sentence of its own: the row above it holds
    /// three links, so it can't lean on one of them.
    func testTheCaptionIsASentence() {
        let caption = LibraryAddMenuItem.fileFormatsCaption
        XCTAssertEqual(caption.first?.isUppercase, true)
        XCTAssertTrue(caption.hasSuffix("."))
        XCTAssertFalse(LibraryAddMenuItem.fileFormatsHint.hasSuffix("."), "a hint, read after the label")
    }
}
