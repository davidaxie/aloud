import CryptoKit
import XCTest
@testable import Aloud

/// Re-opening a file already on the shelf returns that book, even across an
/// extractor change. A record's stored contentHash goes stale when the
/// extractor changes (its cached content is reused), so the store dedupes on
/// sourceHash, the SHA-256 of the file's bytes, first. Records from before
/// sourceHash get it from their library copy at launch. Pure statics and
/// temporary files only: no store instance, so the real shelf is untouched.
@MainActor
final class SourceHashDedupeTests: XCTestCase {

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func record(kind: DocKind = .pdf, contentHash: String = "old-extractor-hash",
                        sourceHash: String? = nil, title: String = "Report") -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "\(UUID().uuidString).pdf",
                        addedAt: Date(timeIntervalSince1970: 0), pageCount: 3, sentenceCount: 40,
                        contentHash: contentHash, kind: kind, sourceHash: sourceHash)
    }

    /// A temporary file holding `data`, removed after the test.
    private func file(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-sourcehash-\(name)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Bytes that differ across the 1 MiB read boundary, so a streaming bug
    /// that drops or repeats a chunk changes the hash.
    private func largeData() -> Data {
        Data((0..<(2 * 1_048_576 + 12_345)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
    }

    // MARK: - Codable

    /// A record written before sourceHash existed (exactly what an old
    /// library.json holds) still decodes.
    private let oldBlob = """
    {
        "id": "6F2A5D14-9C1B-4E8A-8D33-0A1B2C3D4E5F",
        "title": "Walden",
        "fileName": "6F2A5D14-9C1B-4E8A-8D33-0A1B2C3D4E5F.txt",
        "addedAt": "2025-11-02T09:00:00Z",
        "pageCount": 1,
        "sentenceCount": 4021,
        "progressSentence": 120,
        "progressFraction": 0.03,
        "contentHash": "abc123",
        "kind": "text",
        "wordCount": 114000,
        "gutenbergID": 205
    }
    """

    func testOldIndexBlobDecodesWithoutSourceHash() throws {
        let document = try Self.decoder.decode(LibraryDocument.self, from: Data(oldBlob.utf8))
        XCTAssertNil(document.sourceHash)
        XCTAssertEqual(document.title, "Walden")
        XCTAssertEqual(document.contentHash, "abc123")
        XCTAssertEqual(document.progressSentence, 120)
        XCTAssertEqual(document.gutenbergID, 205)
    }

    func testSourceHashRoundtripsAndNilWritesNoKey() throws {
        var document = try Self.decoder.decode(LibraryDocument.self, from: Data(oldBlob.utf8))
        let untouched = String(decoding: try Self.encoder.encode(document), as: UTF8.self)
        XCTAssertFalse(untouched.contains("sourceHash"), "old records stay byte-stable until hashed")

        document.sourceHash = "feedface"
        let decoded = try Self.decoder.decode(LibraryDocument.self,
                                              from: Self.encoder.encode(document))
        XCTAssertEqual(decoded.sourceHash, "feedface")
        XCTAssertEqual(decoded.id, document.id)
    }

    // MARK: - Hashing

    func testSourceHashIsTheSHA256OfTheBytes() async throws {
        let data = largeData()
        let url = try file(data)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let hash = try await DocumentStore.sourceHash(of: url)
        XCTAssertEqual(hash, expected)
        XCTAssertEqual(hash.count, 64)
    }

    /// The hash names the bytes, not the file: the same content under
    /// another name (the library copy, an Inbox copy) hashes the same, and
    /// one changed byte does not.
    func testSameBytesHashTheSameAndOneByteDiffers() async throws {
        var data = largeData()
        let original = try await DocumentStore.sourceHash(of: try file(data, name: "a.pdf"))
        let copy = try await DocumentStore.sourceHash(of: try file(data, name: "b.pdf"))
        data[data.count - 1] ^= 0xFF
        let edited = try await DocumentStore.sourceHash(of: try file(data, name: "c.pdf"))

        XCTAssertEqual(original, copy)
        XCTAssertNotEqual(original, edited)
    }

    func testMissingFileThrows() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-sourcehash-missing-\(UUID().uuidString)")
        do {
            _ = try await DocumentStore.sourceHash(of: missing)
            XCTFail("an unreadable file has no hash")
        } catch {}
    }

    // MARK: - Dedupe

    /// The bug: a book imported before the extractor rewrite keeps its old
    /// contentHash, so re-opening the same file matched nothing on text and
    /// added a second copy. Its bytes still match.
    func testSameFileMatchesDespiteAStaleContentHash() {
        let shelf = [record(contentHash: "old-extractor-hash", sourceHash: "bytes")]

        XCTAssertNil(DocumentStore.duplicate(of: "new-extractor-hash", kind: .pdf, in: shelf),
                     "the text match alone misses it")
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: nil,
                                                  kind: .pdf, in: shelf)?.id, shelf[0].id,
                       "found before extraction, by its bytes")
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: "new-extractor-hash",
                                                  kind: .pdf, in: shelf)?.id, shelf[0].id)
    }

    func testBytesWinOverAnotherRecordsText() {
        let byText = record(contentHash: "text", title: "Re-saved copy")
        let byBytes = record(contentHash: "stale", sourceHash: "bytes", title: "Original")
        let match = DocumentStore.existingCopy(sourceHash: "bytes", contentHash: "text",
                                               kind: .pdf, in: [byText, byBytes])
        XCTAssertEqual(match?.title, "Original")
    }

    /// Different bytes, same text (a re-saved PDF): still one book.
    func testTextStillMatchesWhenTheBytesDiffer() {
        let shelf = [record(contentHash: "text", sourceHash: "other-bytes")]
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: "text",
                                                  kind: .pdf, in: shelf)?.id, shelf[0].id)
        XCTAssertNil(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: nil,
                                                kind: .pdf, in: shelf),
                     "before extraction only the bytes can match")
    }

    func testKindAndEmptyHashesNeverMatch() {
        let shelf = [record(kind: .text, contentHash: "", sourceHash: "bytes")]
        XCTAssertNil(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: nil, kind: .pdf, in: shelf),
                     "a PDF and a text file are never merged")
        XCTAssertNil(DocumentStore.existingCopy(sourceHash: "", contentHash: "", kind: .text,
                                                in: [record(kind: .text, contentHash: "", sourceHash: "")]))
    }

    // MARK: - Launch backfill

    func testBackfillFillsOnlyMissingHashes() {
        let legacy = record(sourceHash: nil, title: "Legacy")
        let hashed = record(sourceHash: "kept", title: "Hashed")
        let missingCopy = record(sourceHash: nil, title: "No copy")
        let hashes = [legacy.id: "legacy-bytes", hashed.id: "would-overwrite"]

        let filled = DocumentStore.fillingSourceHashes(in: [legacy, hashed, missingCopy], from: hashes)

        XCTAssertEqual(filled.map(\.sourceHash), ["legacy-bytes", "kept", nil])
        XCTAssertEqual(filled.map(\.id), [legacy.id, hashed.id, missingCopy.id], "order and records kept")
        XCTAssertEqual(filled[0].contentHash, legacy.contentHash, "nothing else changes")
    }

    /// End to end over real files: a PDF and a text file added before this
    /// release, each with a stale contentHash and no sourceHash. The
    /// backfill hashes their library copies; re-picking the same files
    /// (another path, same bytes) then finds both before extraction.
    func testBackfilledRecordsAreFoundWhenTheSameFilesAreOpenedAgain() async throws {
        let pdfBytes = largeData()
        let textBytes = Data("Call me Ishmael. Some years ago, never mind how long precisely.".utf8)
        let pdf = record(kind: .pdf, contentHash: "stale-pdf")
        let text = record(kind: .text, contentHash: "stale-text", title: "Moby Dick")
        let libraryCopies = [pdf.id: try file(pdfBytes, name: "\(pdf.id).pdf"),
                             text.id: try file(textBytes, name: "\(text.id).txt")]

        var hashes: [UUID: String] = [:]
        for (id, url) in libraryCopies { hashes[id] = try await DocumentStore.sourceHash(of: url) }
        let shelf = DocumentStore.fillingSourceHashes(in: [pdf, text], from: hashes)

        let pickedPDF = try await DocumentStore.sourceHash(of: try file(pdfBytes, name: "report.pdf"))
        let pickedText = try await DocumentStore.sourceHash(of: try file(textBytes, name: "moby.txt"))
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: pickedPDF, contentHash: nil,
                                                  kind: .pdf, in: shelf)?.id, pdf.id)
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: pickedText, contentHash: nil,
                                                  kind: .text, in: shelf)?.id, text.id)
    }
}
