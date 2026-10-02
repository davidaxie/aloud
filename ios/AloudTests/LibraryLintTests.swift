import XCTest

/// Source lints for the shelf (R12b, R12h, R18, R20). Reads the source tree
/// next to the tests; skips when the host can't read it.
final class LibraryLintTests: XCTestCase {

    private static let coverFile = "Library/BookCover.swift"
    private static let libraryFile = "Library/LibraryView.swift"

    /// The text of `struct <name>` up to the next top-level declaration.
    private func body(ofStruct name: String, in text: String,
                      file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let start = text.range(of: "struct \(name):") else {
            XCTFail("struct \(name) not found", file: file, line: line)
            return ""
        }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// R12h: Smart Invert leaves every cover as drawn. There is one cover
    /// (R22), and every other cover draws through it.
    func testCoversIgnoreInvertColors() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.coverFile])[Self.coverFile])
        XCTAssertTrue(body(ofStruct: "BookCover", in: text).contains(".accessibilityIgnoresInvertColors()"),
                      "BookCover should set accessibilityIgnoresInvertColors")
    }

    /// R12b: magic tap reaches the hero from the shelf.
    func testLibraryHandlesMagicTap() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        XCTAssertTrue(text.contains(".accessibilityAction(.magicTap"))
    }

    /// R18: the shelf never redraws per sentence. Only its hero observes the
    /// controller, through an @ObservedObject handed down.
    func testLibraryDoesNotObservePlayback() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        XCTAssertFalse(text.contains("@EnvironmentObject private var playback"))
    }

    /// R20: busy states hold still under Reduce Motion; no system spinner on
    /// the shelf or the Bookshelf.
    func testNoSpinnerOnTheShelves() throws {
        let shelves = try SourceTree.sources(only: ["Library", "Bookshelf"])
        XCTAssertEqual(SourceTree.files(containing: "ProgressView", in: shelves), [])
    }
}
