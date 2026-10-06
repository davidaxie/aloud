import XCTest
@testable import Aloud

/// The chapter map rides in the content cache as an optional field: caches
/// written before it existed still load (and keep their hash, so progress
/// survives), and a map this build can't read costs only the map.
final class ChapterMapCodingTests: XCTestCase {

    private static let legacyJSON = """
        {"title":"Old","pageCount":2,\
        "sentences":[{"id":0,"text":"One.","para":0,"page":1},{"id":1,"text":"Two.","para":1,"page":2}],\
        "paragraphs":[{"id":0,"sentenceIDs":[0,1],"page":1},{"id":1,"sentenceIDs":[1,2],"page":2}],\
        "contentHash":"abc"
        """

    private func decode(_ json: String) throws -> DocContent {
        try JSONDecoder().decode(DocContent.self, from: Data(json.utf8))
    }

    func testALegacyCacheDecodesWithoutAMap() throws {
        let content = try decode(Self.legacyJSON + "}")

        XCTAssertNil(content.chapterMap)
        XCTAssertEqual(content.contentHash, "abc")
        XCTAssertEqual(content.sentences.map(\.text), ["One.", "Two."])
        XCTAssertEqual(content.paragraphs.map(\.sentenceIDs), [0..<1, 1..<2])
    }

    func testNoMapIsWrittenAsNoKey() throws {
        let content = try decode(Self.legacyJSON + "}")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])

        XCTAssertNil(object["chapterMap"])
        XCTAssertEqual(object["contentHash"] as? String, "abc")
    }

    func testAMapRoundTrips() throws {
        var content = try decode(Self.legacyJSON + "}")
        let map = ChapterMap(version: ChapterMap.currentVersion, source: .runningHeaders, entries: [
            ChapterMap.Entry(title: "Front matter", sentence: 0, section: nil),
            ChapterMap.Entry(title: "Tiny Speck", sentence: 1, section: "Part II: The Cold Start Problem"),
        ])
        content.chapterMap = map

        let decoded = try JSONDecoder().decode(DocContent.self, from: JSONEncoder().encode(content))

        XCTAssertEqual(decoded.chapterMap, map)
        XCTAssertEqual(decoded.contentHash, content.contentHash)
    }

    func testAMapThisBuildCannotReadIsDroppedNotTheCache() throws {
        let content = try decode(Self.legacyJSON
            + #","chapterMap":{"version":9,"source":"someday","entries":[]}}"#)

        XCTAssertNil(content.chapterMap)
        XCTAssertEqual(content.contentHash, "abc")
        XCTAssertTrue(DocumentStore.needsChapterMap(content, kind: .pdf))
    }

    func testSanitizedEntriesStayInRangeIncreasingAndStartAtZero() {
        let map = ChapterMap(version: 1, source: .outline, entries: [
            ChapterMap.Entry(title: "A", sentence: 2, section: nil),
            ChapterMap.Entry(title: "B", sentence: 2, section: nil),
            ChapterMap.Entry(title: "C", sentence: 1, section: nil),
            ChapterMap.Entry(title: "D", sentence: 4, section: nil),
            ChapterMap.Entry(title: "E", sentence: 9, section: nil),
        ])

        let entries = map.sanitizedEntries(sentenceCount: 5)

        XCTAssertEqual(entries.map(\.title), [PDFChapterDetector.frontMatterTitle, "B", "D"])
        XCTAssertEqual(entries.map(\.sentence), [0, 2, 4])
        XCTAssertEqual(map.sanitizedEntries(sentenceCount: 0), [])
    }
}
