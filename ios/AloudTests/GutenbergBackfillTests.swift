import XCTest
@testable import Aloud

/// R9: classics are matched by Gutenberg id, never by title. The one-time
/// v1 → v2 backfill links records added before the id existed, the lookup
/// survives a rename, and the field round-trips through library.json. Pure
/// statics only: no store instance, no file IO.
final class GutenbergBackfillTests: XCTestCase {

    private let callOfTheWild = BookshelfBook(
        gutenbergID: 215, title: "The Call of the Wild", author: "Jack London", year: nil,
        file: "215-the-call-of-the-wild.txt", words: 31_824,
        headerTitle: "The call of the wild")

    private func record(title: String,
                        author: String? = "Jack London",
                        kind: DocKind = .text,
                        wordCount: Int = 31_824,
                        gutenbergID: Int? = nil) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "\(UUID().uuidString).txt",
                        addedAt: Date(timeIntervalSince1970: 0), pageCount: 1,
                        sentenceCount: 100, contentHash: "hash", kind: kind,
                        author: author, wordCount: wordCount, gutenbergID: gutenbergID)
    }

    private func backfill(_ document: LibraryDocument,
                          catalog: [BookshelfBook]? = nil) -> LibraryDocument {
        DocumentStore.backfillingGutenbergIDs(in: [document],
                                              catalog: catalog ?? [callOfTheWild])[0]
    }

    // MARK: - Backfill

    func testHeaderSpelledRecordIsLinkedAndGetsTheNormalizedTitle() {
        let linked = backfill(record(title: "The call of the wild"))
        XCTAssertEqual(linked.gutenbergID, 215)
        XCTAssertEqual(linked.title, "The Call of the Wild")
    }

    func testNormalizedTitleIsLinked() {
        let linked = backfill(record(title: "The Call of the Wild"))
        XCTAssertEqual(linked.gutenbergID, 215)
        XCTAssertEqual(linked.title, "The Call of the Wild")
    }

    func testRenamedRecordIsLinkedByWordCountAndKeepsItsTitle() {
        let linked = backfill(record(title: "My Wild Book", wordCount: 31_824))
        XCTAssertEqual(linked.gutenbergID, 215)
        XCTAssertEqual(linked.title, "My Wild Book", "a user's rename is never overwritten")
    }

    func testRenamedRecordWithADifferentWordCountIsNotLinked() {
        XCTAssertNil(backfill(record(title: "My Wild Book", wordCount: 999)).gutenbergID)
    }

    func testPDFWithTheSameTitleAndAuthorIsNotLinked() {
        XCTAssertNil(backfill(record(title: "The Call of the Wild", kind: .pdf)).gutenbergID)
    }

    func testRecordWithoutAnAuthorIsNotLinked() {
        XCTAssertNil(backfill(record(title: "The Call of the Wild", author: nil)).gutenbergID)
    }

    func testAlreadyLinkedRecordIsUnchanged() {
        let linked = backfill(record(title: "The call of the wild", gutenbergID: 84))
        XCTAssertEqual(linked.gutenbergID, 84)
        XCTAssertEqual(linked.title, "The call of the wild")
    }

    func testMalformedAuthorIsRepaired() {
        let book = BookshelfBook(gutenbergID: 6768, title: "The Man Upstairs",
                                 author: "P. G. Wodehouse", year: nil,
                                 file: "6768-the-man-upstairs.txt", words: 100_265,
                                 headerAuthor: ". G. Wodehouse")
        let linked = backfill(record(title: "The Man Upstairs", author: ". G. Wodehouse",
                                     wordCount: 100_265),
                              catalog: [callOfTheWild, book])
        XCTAssertEqual(linked.gutenbergID, 6768)
        XCTAssertEqual(linked.author, "P. G. Wodehouse")
    }

    // MARK: - Lookup

    func testExistingClassicFindsARenamedRecord() {
        let renamed = record(title: "My Wild Book", gutenbergID: 215)
        let other = record(title: "Emma", author: "Jane Austen", gutenbergID: 158)
        XCTAssertEqual(DocumentStore.existingClassic(gutenbergID: 215, in: [other, renamed])?.id,
                       renamed.id)
    }

    func testExistingClassicIsNilWhenNothingMatches() {
        let unlinked = record(title: "The Call of the Wild")
        XCTAssertNil(DocumentStore.existingClassic(gutenbergID: 215, in: [unlinked]))
    }

    func testExistingClassicReturnsTheFirstOfTwoSharingAnID() {
        let first = record(title: "First", gutenbergID: 215)
        let second = record(title: "Second", gutenbergID: 215)
        XCTAssertEqual(DocumentStore.existingClassic(gutenbergID: 215, in: [first, second])?.id,
                       first.id)
    }

    // MARK: - Coding

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

    /// A v1 library.json record: no gutenbergID key.
    private let v1Blob = """
    {
        "id": "6F2A5D14-9C1B-4E8A-8D33-0A1B2C3D4E5F",
        "title": "Pride and Prejudice",
        "fileName": "pride.txt",
        "addedAt": "2025-11-02T09:00:00Z",
        "pageCount": 61,
        "sentenceCount": 6000,
        "progressSentence": 120,
        "progressFraction": 0.02,
        "contentHash": "abc123",
        "kind": "text",
        "author": "Jane Austen",
        "wordCount": 127359
    }
    """

    func testV1RecordDecodesWithoutAGutenbergID() throws {
        let document = try Self.decoder.decode(LibraryDocument.self, from: Data(v1Blob.utf8))
        XCTAssertNil(document.gutenbergID)
        XCTAssertEqual(document.title, "Pride and Prejudice")
    }

    func testGutenbergIDRoundTrips() throws {
        var document = try Self.decoder.decode(LibraryDocument.self, from: Data(v1Blob.utf8))
        document.gutenbergID = 1342
        let decoded = try Self.decoder.decode(LibraryDocument.self,
                                              from: Self.encoder.encode(document))
        XCTAssertEqual(decoded.gutenbergID, 1342)
    }

    func testNilGutenbergIDWritesNoKey() throws {
        let document = try Self.decoder.decode(LibraryDocument.self, from: Data(v1Blob.utf8))
        let json = String(decoding: try Self.encoder.encode(document), as: UTF8.self)
        XCTAssertFalse(json.contains("gutenbergID"))
    }

    // MARK: - Finished

    /// The one Finished rule. 31,824 words is 192.9 minutes at 1×, so 0.99
    /// leaves almost two: still in progress until a stored 1.0.
    func testFinishedStartsAtTheThreshold() {
        var document = record(title: "Book")
        document.progressFraction = 0.989
        XCTAssertFalse(document.isFinished)
        document.progressFraction = 0.99
        XCTAssertFalse(document.isFinished, "116 s left is more than the minute's slack")
        document.progressFraction = 0.9999
        XCTAssertTrue(document.isFinished)
        document.progressFraction = 1.0
        XCTAssertTrue(document.isFinished)
    }

    /// The minute's slack, at its edge: 21,120 words is 128 minutes, and
    /// 127/128 (exact in binary) leaves exactly 60 s at 1×. One word more
    /// is over. The speed never moves it: the rule is measured at 1×.
    func testFinishedAllowsAMinuteLeft() {
        var document = record(title: "Book", wordCount: 21_120)
        document.progressFraction = 127.0 / 128
        XCTAssertEqual(document.estimatedSecondsRemaining(rate: 1), LibraryDocument.finishedSlackSeconds)
        XCTAssertTrue(document.isFinished)
        XCTAssertEqual(document.listeningSubtitle(rate: 0.5), "Finished", "120 s at 0.5×, still Finished")
        document.wordCount = 21_121
        XCTAssertFalse(document.isFinished)
        XCTAssertEqual(document.listeningSubtitle(rate: 3), "1 min left", "20 s at 3×, still in progress")
    }

    /// Below 0.99 nothing is Finished, however little is left: a 100-word
    /// note at 0.989 has under a second to go.
    func testFinishedNeverStartsBelowTheThreshold() {
        var document = record(title: "Note", wordCount: 100)
        document.progressFraction = 0.989
        XCTAssertLessThan(document.estimatedSecondsRemaining(rate: 1) ?? .infinity, 1)
        XCTAssertFalse(document.isFinished)
    }

    /// With no word count there is no time to weigh: the threshold alone
    /// decides.
    func testAnUnmeasuredBookIsFinishedAtTheThreshold() {
        var document = record(title: "Book", wordCount: 0)
        XCTAssertNil(document.estimatedSecondsRemaining(rate: 1))
        document.progressFraction = 0.989
        XCTAssertFalse(document.isFinished)
        document.progressFraction = 0.99
        XCTAssertTrue(document.isFinished)
        XCTAssertEqual(document.listeningSubtitle(rate: 1), "Finished")
    }
}
