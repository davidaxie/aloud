import XCTest
@testable import Aloud

/// Progress in library.json: a tick reaches disk within the save interval
/// even while ticks keep coming (a throttle, never a debounce each tick
/// restarts), and is written at once on background and on termination.
///
/// Each store keeps its index in a temporary folder and hears a private
/// notification center: the app's library is never touched, and the host
/// app hears nothing.
@MainActor
final class ProgressIndexTests: XCTestCase {

    /// library.json's shape.
    private struct Index: Codable {
        var version: Int
        var documents: [LibraryDocument]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A store over an index of one unstarted 400-sentence book, in a folder
    /// removed after the test.
    private func makeStore(saveInterval: TimeInterval,
                           notifications: NotificationCenter = NotificationCenter())
        throws -> (store: DocumentStore, book: LibraryDocument, index: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let index = folder.appendingPathComponent("library.json")
        let book = PlaybackTestRig.makeDocument(hash: "progress-index", sentences: 400)
        try Self.encoder.encode(Index(version: 2, documents: [book])).write(to: index)
        let store = DocumentStore(indexURL: index, saveInterval: saveInterval, notifications: notifications)
        XCTAssertEqual(store.documents.map(\.id), [book.id], "the store reads its own index")
        return (store, book, index)
    }

    /// The book's progress sentence as library.json has it now.
    private func sentenceOnDisk(_ index: URL, _ id: UUID) throws -> Int? {
        let data = try Data(contentsOf: index)
        return try Self.decoder.decode(Index.self, from: data).documents.first { $0.id == id }?.progressSentence
    }

    /// Polls `condition` every 20 ms; false when `timeout` passes first.
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - Forced writes

    /// Swiping the app away while a book plays in the background: the
    /// progress since the last write reaches disk before the post returns,
    /// with no turn of the run loop for a dying process to miss.
    func testTerminationWritesPendingProgressAtOnce() throws {
        let center = NotificationCenter()
        let (store, book, index) = try makeStore(saveInterval: 60, notifications: center)
        store.saveProgress(id: book.id, sentence: 120, fraction: 0.3)
        XCTAssertEqual(try sentenceOnDisk(index, book.id), 0, "still waiting on the throttle")

        PlatformLifecycle.post(.willTerminate, to: center)

        XCTAssertEqual(try sentenceOnDisk(index, book.id), 120)
    }

    func testBackgroundWritesPendingProgress() async throws {
        let center = NotificationCenter()
        let (store, book, index) = try makeStore(saveInterval: 60, notifications: center)
        store.saveProgress(id: book.id, sentence: 80, fraction: 0.2)
        XCTAssertEqual(try sentenceOnDisk(index, book.id), 0)

        PlatformLifecycle.post(.didEnterBackground, to: center)

        let written = await waitUntil { (try? self.sentenceOnDisk(index, book.id)) == 80 }
        XCTAssertTrue(written, "the background flush never wrote")
    }

    // MARK: - The throttle

    /// 2-3x through short dialogue: progress changes more often than the
    /// save interval, with no pause. It still reaches disk while the ticks
    /// keep coming, and the last tick lands once they stop.
    func testContinuousProgressReachesDiskWhileItKeepsComing() async throws {
        let (store, book, index) = try makeStore(saveInterval: 0.2)
        var sentence = 0
        var writtenWhileTicking = false
        let deadline = Date().addingTimeInterval(3)
        // A tick every 50 ms, well inside the 200 ms interval: a debounce
        // restarted by each tick writes nothing until they stop.
        while Date() < deadline {
            sentence += 1
            store.saveProgress(id: book.id, sentence: sentence, fraction: Double(sentence) / 400)
            try await Task.sleep(nanoseconds: 50_000_000)
            let onDisk = try sentenceOnDisk(index, book.id) ?? 0
            if onDisk > 0 {
                writtenWhileTicking = true
                break
            }
        }
        XCTAssertTrue(writtenWhileTicking, "nothing reached disk in \(sentence) ticks")

        let last = sentence + 1
        store.saveProgress(id: book.id, sentence: last, fraction: Double(last) / 400)
        let landed = await waitUntil { (try? self.sentenceOnDisk(index, book.id)) == last }
        XCTAssertTrue(landed, "the last tick never reached disk")
    }
}
