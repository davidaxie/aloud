import XCTest
@testable import Aloud

/// Progress in library.json: a tick reaches disk within the save interval
/// even while ticks keep coming (a throttle, never a debounce each tick
/// restarts), and is written at once on background and on termination.
/// An index this build can't read is never written over, and an add or a
/// delete the index can't record leaves the shelf as it was.
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

    /// A fresh temporary folder, removed after the test.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A store over an index of one unstarted 400-sentence book, in a folder
    /// removed after the test.
    private func makeStore(saveInterval: TimeInterval,
                           notifications: NotificationCenter = NotificationCenter())
        throws -> (store: DocumentStore, book: LibraryDocument, index: URL) {
        let index = try makeFolder().appendingPathComponent("library.json")
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

    // MARK: - One publish per save

    /// A progress save is one element write: `documents` publishes once,
    /// not once per field, so everything watching the store (the Library
    /// shelf, the Continue card) re-renders once a sentence.
    func testAProgressSavePublishesOnce() throws {
        let (store, book, _) = try makeStore(saveInterval: 60)
        var publishes = 0
        let watch = store.$documents.dropFirst().sink { _ in publishes += 1 }
        defer { watch.cancel() }
        store.saveProgress(id: book.id, sentence: 42, fraction: 0.105)
        XCTAssertEqual(publishes, 1)
        let saved = try XCTUnwrap(store.documents.first { $0.id == book.id })
        XCTAssertEqual(saved.progressSentence, 42)
        XCTAssertEqual(saved.progressFraction, 0.105, accuracy: 0.0001)
        XCTAssertNotNil(saved.lastOpenedAt)
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

    // MARK: An unreadable index

    /// library.json as a newer build sharing the container might leave it:
    /// version 3, a book this build reads and a record of a kind it lacks
    /// ("epub"), which fails the whole index.
    private func writeNewerIndex() throws -> (index: URL, bytes: Data, book: LibraryDocument) {
        let index = try makeFolder().appendingPathComponent("library.json")
        let book = PlaybackTestRig.makeDocument(hash: "kept", sentences: 400)
        let newer = PlaybackTestRig.makeDocument(hash: "newer", sentences: 90)
        let encoded = try Self.encoder.encode(Index(version: 3, documents: [book, newer]))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var records = try XCTUnwrap(json["documents"] as? [[String: Any]])
        records[1]["kind"] = "epub"
        json["documents"] = records
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: index)
        XCTAssertThrowsError(try Self.decoder.decode(Index.self, from: bytes),
                             "fixture: the index should fail as a whole")
        return (index, bytes, book)
    }

    /// The names in the app's library folder, where an add copies its book.
    private func libraryFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: DocumentStore.libraryDir.path))
    }

    /// Nothing writes over an index this build can't read: not a progress
    /// save, a rename, Mark as finished, an open, the background or the
    /// termination flush. Before, the first flush wrote an empty shelf over
    /// it, and the next launch read that cleanly and swept every book's
    /// files. The record that decodes still shows, a copy is set aside, and
    /// the next launch reads the same shelf, its sweep still off.
    func testAnUnreadableIndexIsNeverWrittenOver() async throws {
        let (index, bytes, book) = try writeNewerIndex()
        let center = NotificationCenter()
        let store = DocumentStore(indexURL: index, saveInterval: 0.05, notifications: center)
        XCTAssertFalse(store.isIndexReadable)
        XCTAssertEqual(store.documents.map(\.id), [book.id], "the record that decodes still shows")

        store.saveProgress(id: book.id, sentence: 120, fraction: 0.3)
        store.rename(book, to: "Renamed")
        store.markFinished(id: book.id)
        store.noteOpened(id: book.id)
        PlatformLifecycle.post(.didEnterBackground, to: center)
        PlatformLifecycle.post(.willTerminate, to: center)
        // Past the 50 ms save interval, and any hop the background flush takes.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(try Data(contentsOf: index), bytes, "library.json is as it was")
        XCTAssertEqual(store.unreadableIndexURL.lastPathComponent, "library.unreadable.json")
        XCTAssertEqual(store.unreadableIndexURL.deletingLastPathComponent().standardizedFileURL,
                       index.deletingLastPathComponent().standardizedFileURL, "beside it")
        XCTAssertEqual(try Data(contentsOf: store.unreadableIndexURL), bytes, "a copy is set aside")

        let relaunched = DocumentStore(indexURL: index, saveInterval: 60, notifications: NotificationCenter())
        XCTAssertFalse(relaunched.isIndexReadable, "so the launch sweep stays off")
        XCTAssertEqual(relaunched.documents.map(\.id), [book.id], "the next launch finds the same shelf")
    }

    /// A damaged index, not JSON at all: an empty shelf, and still nothing
    /// written over it.
    func testADamagedIndexStaysAsItIs() throws {
        let index = try makeFolder().appendingPathComponent("library.json")
        let bytes = Data("{\"version\":2,\"documents\":[{\"id\":".utf8)
        try bytes.write(to: index)
        let center = NotificationCenter()
        let store = DocumentStore(indexURL: index, saveInterval: 60, notifications: center)
        XCTAssertFalse(store.isIndexReadable)
        XCTAssertTrue(store.documents.isEmpty)

        PlatformLifecycle.post(.willTerminate, to: center)

        XCTAssertEqual(try Data(contentsOf: index), bytes, "library.json is as it was")
        XCTAssertEqual(try Data(contentsOf: store.unreadableIndexURL), bytes, "a copy is set aside")
    }

    /// No index yet is a known, empty shelf: the first write makes one, and
    /// nothing is set aside.
    func testNoIndexYetIsAnEmptyShelfThatWrites() throws {
        let index = try makeFolder().appendingPathComponent("library.json")
        let center = NotificationCenter()
        let store = DocumentStore(indexURL: index, saveInterval: 60, notifications: center)
        XCTAssertTrue(store.isIndexReadable)
        PlatformLifecycle.post(.willTerminate, to: center)
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.unreadableIndexURL.path))
    }

    /// An add while an unreadable index is kept fails, as "couldn't be
    /// opened", and leaves no copy behind: shelved for this session only,
    /// it would be gone next launch after the importer announced it.
    func testAnAddWhileTheIndexIsUnreadableFails() async throws {
        let (index, bytes, book) = try writeNewerIndex()
        let store = DocumentStore(indexURL: index, saveInterval: 60, notifications: NotificationCenter())
        let text = index.deletingLastPathComponent().appendingPathComponent("new.txt")
        try "A new book. It has two sentences.".write(to: text, atomically: true, encoding: .utf8)
        let before = try libraryFiles()

        do {
            _ = try await store.importText(title: "New", from: text)
            XCTFail("the add should fail")
        } catch {
            XCTAssertEqual(error as? LibraryIndexError, .unreadable)
            XCTAssertEqual(ImportFailure(error, isPDF: false), .couldNotOpen)
        }

        XCTAssertEqual(store.documents.map(\.id), [book.id])
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertEqual(try libraryFiles(), before, "the copy and its cache are removed")
    }

    // MARK: A write that fails

    /// An add library.json can't record (out of space; here, a folder that
    /// can't be written) fails, with the shelf as it was. Before, the
    /// write's error was dropped and the add announced, and the next launch
    /// lost the record and swept the book's files. A delete the index can't
    /// record keeps the book too, rather than leave a record of files gone.
    func testAnAddTheIndexCantRecordFails() async throws {
        let (store, book, index) = try makeStore(saveInterval: 60)
        let folder = index.deletingLastPathComponent()
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-add-\(UUID().uuidString).txt")
        try "A new book. It has two sentences.".write(to: text, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: text) }
        let original = try Data(contentsOf: index)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        // Runs before the folder's removal (teardown blocks run last first).
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        let before = try libraryFiles()

        do {
            _ = try await store.importText(title: "New", from: text)
            XCTFail("an add the index can't record should fail")
        } catch {}

        XCTAssertEqual(store.documents.map(\.id), [book.id], "the shelf is as it was")
        XCTAssertEqual(try libraryFiles(), before, "the copy and its cache are removed")
        XCTAssertEqual(try Data(contentsOf: index), original)

        store.delete(book)
        XCTAssertEqual(store.documents.map(\.id), [book.id], "a delete the index can't record keeps the book")
    }

    // MARK: Rename

    /// An empty or all-space title is no rename: Rename's Save is off for
    /// it (LibraryView), and the store keeps the old title.
    func testAnEmptyTitleIsNoRename() throws {
        XCTAssertNil(DocumentStore.renamedTitle(""))
        XCTAssertNil(DocumentStore.renamedTitle("  \n "))
        XCTAssertEqual(DocumentStore.renamedTitle("  Emma "), "Emma")

        let (store, book, _) = try makeStore(saveInterval: 60)
        store.rename(book, to: "   ")
        XCTAssertEqual(store.documents.first?.title, book.title)
        store.rename(book, to: " Emma ")
        XCTAssertEqual(store.documents.first?.title, "Emma")
    }
}
