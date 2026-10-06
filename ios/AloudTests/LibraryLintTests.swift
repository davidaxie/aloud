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

    /// F026, the Mac shelf: every way a card opens its book stops a Continue
    /// circle load of another book first, as the iPhone shelf's `open` does.
    func testTheMacShelfOpensThroughReaderOpens() throws {
        let file = "Library/MacLibraryView.swift"
        let text = try XCTUnwrap(try SourceTree.sources(in: SourceTree.macRoot, only: [file])[file])
        let shelf = body(ofStruct: "MacLibraryView", in: text)
        XCTAssertTrue(shelf.contains("continuePlayback.readerOpens(document.id)\n        router.open(document)"),
                      "open(_:) should stop another book's circle load before it opens")
        // The only direct open left is a circle load that failed: it was
        // this book's, and it is over.
        let direct = shelf.components(separatedBy: "router.open(").count - 1
        XCTAssertEqual(direct, 2, "only open(_:) and the circle's onFailure call router.open")
        XCTAssertTrue(shelf.contains("onFailure: { router.open(document) }"))
    }

    /// F045, the Mac: the Continue hero and Space/Play with no book loaded
    /// pick by the controller's unattended stop, as the launch restore and
    /// remote Play do, so a book stopped in its last minute stays on offer.
    func testTheMacContinueBookHonoursTheStop() throws {
        let files = ["Library/MacLibraryView.swift", "Commands/MacCommandActions.swift"]
        let sources = try SourceTree.sources(in: SourceTree.macRoot, only: files)
        let library = try XCTUnwrap(sources[files[0]])
        XCTAssertTrue(library.contains("ShelfLayout(for: documents, loadedID: loadedID, stop: stop)"))
        XCTAssertEqual(library.components(separatedBy: "stop: model.playback.stopped").count - 1, 3,
                       "both store and controller publishes and the Library showing again")
        let commands = try XCTUnwrap(sources[files[1]])
        XCTAssertTrue(commands.contains("loadedID: playback.document?.id,\n                                                 stop: playback.stopped)"),
                      "continueBook should pass the controller's stop")
    }

    /// F045: every shelf the Library derives hears the controller's
    /// unattended stop, so its hero is the book the shortcut and remote Play
    /// would continue (`DocumentStore.isAtItsEnd`).
    func testTheShelfHearsTheUnattendedStop() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        let derivations = text.components(separatedBy: .newlines).filter { $0.contains("ShelfLayout(for:") }
        XCTAssertEqual(derivations.count, 2, "the lint reads both derivations")
        for line in derivations {
            XCTAssertTrue(line.contains("stop: model.playback.stopped"), line)
        }
    }
}
