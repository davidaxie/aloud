import XCTest
@testable import Aloud

/// "Open in Aloud": iOS hands the app a copy in Documents/Inbox, which the
/// importer removes once the store has made its own copy.
@MainActor
final class OpenInImportTests: XCTestCase {

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func testInboxCopiesAreRecognized() {
        let inboxFile = documents.appendingPathComponent("Inbox/Paper.pdf")
        XCTAssertTrue(DocumentImporter.isInboxCopy(inboxFile))
    }

    func testOtherFilesAreNeverTreatedAsInboxCopies() {
        XCTAssertFalse(DocumentImporter.isInboxCopy(documents.appendingPathComponent("Library/x.pdf")))
        XCTAssertFalse(DocumentImporter.isInboxCopy(documents.appendingPathComponent("Inboxes/x.pdf")))
        XCTAssertFalse(DocumentImporter.isInboxCopy(URL(fileURLWithPath: "/private/tmp/Inbox/x.pdf")))
        XCTAssertFalse(DocumentImporter.isInboxCopy(URL(string: "https://example.com/Inbox/x.pdf")!))
    }

    func testRemoveInboxCopyDeletesOnlyInboxFiles() throws {
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let copy = inbox.appendingPathComponent("open-in-test-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: copy)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-in-test-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        DocumentImporter.removeInboxCopy(copy)
        DocumentImporter.removeInboxCopy(outside)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

/// Opening the same file twice keeps one copy on the shelf (PRD R1b).
@MainActor
final class ImportDeduplicationTests: XCTestCase {

    private func document(_ hash: String, kind: DocKind, title: String = "T") -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "x", addedAt: Date(),
                        pageCount: 1, sentenceCount: 1, contentHash: hash, kind: kind)
    }

    func testSameContentSameKindIsADuplicate() {
        let shelf = [document("abc", kind: .pdf, title: "Paper")]
        XCTAssertEqual(DocumentStore.duplicate(of: "abc", kind: .pdf, in: shelf)?.title, "Paper")
    }

    func testDifferentKindOrContentIsNotADuplicate() {
        let shelf = [document("abc", kind: .pdf)]
        XCTAssertNil(DocumentStore.duplicate(of: "abc", kind: .text, in: shelf))
        XCTAssertNil(DocumentStore.duplicate(of: "xyz", kind: .pdf, in: shelf))
        XCTAssertNil(DocumentStore.duplicate(of: "", kind: .pdf, in: [document("", kind: .pdf)]))
    }
}
