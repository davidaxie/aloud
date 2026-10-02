import XCTest
@testable import Aloud

/// Segmentation reuses one NLTokenizer (allocating one per paragraph made
/// adding a large classic slow). NLTokenizer is not thread-safe, so the
/// shared instance is locked; concurrent callers must see serial results.
final class ExtractionSegmenterConcurrencyTests: XCTestCase {

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int: [String]] = [:]
        func set(_ value: [String], at index: Int) {
            lock.lock(); defer { lock.unlock() }
            storage[index] = value
        }
        func value(at index: Int) -> [String]? {
            lock.lock(); defer { lock.unlock() }
            return storage[index]
        }
    }

    func testConcurrentChunkingMatchesSerial() {
        let paragraphs = (0..<300).map {
            "Paragraph \($0) begins here. Dr. Smith saw No. \($0 + 1) at noon. "
                + "Then (he left. Quietly.) It ended \($0 % 7 == 0 ? "* * *" : "well")."
        }
        let serial = paragraphs.map { SentenceSegmenter.chunkParagraph($0) }

        let results = Results()
        DispatchQueue.concurrentPerform(iterations: paragraphs.count) { index in
            results.set(SentenceSegmenter.chunkParagraph(paragraphs[index]), at: index)
        }
        for index in paragraphs.indices {
            XCTAssertEqual(results.value(at: index), serial[index], "paragraph \(index)")
        }
    }

    func testRepeatedSplittingIsStable() {
        // The shared tokenizer carries no state from one paragraph to the next.
        let a = "First sentence here. Second one there."
        let b = "Une phrase. Encore une."
        let first = SentenceSegmenter.splitIntoSentences(a)
        _ = SentenceSegmenter.splitIntoSentences(b)
        XCTAssertEqual(SentenceSegmenter.splitIntoSentences(a), first)
        XCTAssertEqual(first, ["First sentence here.", "Second one there."])
    }
}
