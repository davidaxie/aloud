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
        // J012: neither shows a change the index never records.
        XCTAssertThrowsError(try store.rename(book, to: "Renamed")) { error in
            XCTAssertEqual(EditFailure(.rename, error).cause, .libraryUnreadable)
        }
        XCTAssertThrowsError(try store.markFinished(id: book.id))
        XCTAssertEqual(store.documents.first?.title, book.title, "the rename is rolled back")
        XCTAssertEqual(store.documents.first?.progressFraction, 0.3, "Mark as finished is rolled back")
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

    /// An add while an unreadable index is kept fails, saying the library
    /// couldn't be read (J011: before, "This file couldn't be opened", a
    /// retry that could never work), and leaves no copy behind: shelved for
    /// this session only, it would be gone next launch after the importer
    /// announced it. Refused before the copy and the extraction.
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
            XCTAssertEqual(ImportFailure(error, isPDF: false), .libraryUnreadable)
            XCTAssertEqual(ImportFailure(error, isPDF: true), .libraryUnreadable)
        }
        // A file with no text fails its extraction: refused before that, it
        // says why the library can't take it, not that the file is empty.
        let empty = index.deletingLastPathComponent().appendingPathComponent("empty.txt")
        try "   ".write(to: empty, atomically: true, encoding: .utf8)
        do {
            _ = try await store.importText(title: "Empty", from: empty)
            XCTFail("the add should fail")
        } catch {
            XCTAssertEqual(error as? LibraryIndexError, .unreadable, "refused before the extraction")
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

        XCTAssertThrowsError(try store.delete(book), "a delete the index can't record fails")
        XCTAssertEqual(store.documents.map(\.id), [book.id], "a delete the index can't record keeps the book")
    }

    // MARK: A delete the index can't record

    /// A store over an index of one book whose file, content cache and
    /// thumbnail are on disk, uniquely named and removed after the test.
    private func makeStoreWithBookFiles() throws
        -> (store: DocumentStore, book: LibraryDocument, index: URL, files: [URL]) {
        let index = try makeFolder().appendingPathComponent("library.json")
        let book = PlaybackTestRig.makeDocument(hash: "delete-\(UUID().uuidString)", sentences: 400)
        try Self.encoder.encode(Index(version: 2, documents: [book])).write(to: index)
        let files = [DocumentStore.fileURL(for: book), DocumentStore.contentCacheURL(for: book.id),
                     DocumentStore.thumbnailURL(for: book.id)]
        for file in files {
            try Data("x".utf8).write(to: file)
            addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        }
        let store = DocumentStore(indexURL: index, saveInterval: 60, notifications: NotificationCenter())
        XCTAssertEqual(store.documents.map(\.id), [book.id], "the store reads its own index")
        return (store, book, index, files)
    }

    /// The books library.json lists now.
    private func idsOnDisk(_ index: URL) throws -> [UUID] {
        try Self.decoder.decode(Index.self, from: Data(contentsOf: index)).documents.map(\.id)
    }

    /// A delete library.json can't record for lack of space (the disk a
    /// Delete is meant to clear) frees the book's caches and tries again;
    /// once the record is gone, so is the book's file. Before, the failed
    /// write kept everything, freed nothing and said nothing.
    func testADeleteOutOfSpaceFreesTheCachesAndTriesAgain() throws {
        let (store, book, index, files) = try makeStoreWithBookFiles()
        let file = files[0], cache = files[1]
        var writes = 0
        store.writeIndexData = { data, url in
            writes += 1
            if writes == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "the caches go first")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the book's file waits for the record")
            try data.write(to: url, options: .atomic)
        }

        XCTAssertNoThrow(try store.delete(book))

        XCTAssertEqual(writes, 2)
        XCTAssertEqual(store.documents.map(\.id), [])
        XCTAssertEqual(try idsOnDisk(index), [])
        for file in files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is gone")
        }
    }

    /// A delete library.json still can't record fails, saying why, with the
    /// book and its file as they were, and the shelf never publishes itself
    /// without the book: the place history's sweep would take its places.
    func testADeleteTheIndexStillCantRecordKeepsTheBook() throws {
        let (store, book, index, files) = try makeStoreWithBookFiles()
        store.writeIndexData = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        var shelves: [[UUID]] = []
        let watching = store.$documents.dropFirst().sink { shelves.append($0.map(\.id)) }

        XCTAssertThrowsError(try store.delete(book)) { error in
            XCTAssertEqual(DeleteFailure(error), .outOfSpace)
        }

        XCTAssertEqual(store.documents.map(\.id), [book.id], "the book stays")
        XCTAssertEqual(shelves, [], "no shelf without it was published")
        XCTAssertEqual(try idsOnDisk(index), [book.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path), "the book's file stays")
        // J010: and so does its content cache, put back after the retry.
        XCTAssertEqual(try? Data(contentsOf: files[1]), Data("x".utf8), "the content cache stays")
        watching.cancel()
    }

    /// J010: a book whose content cache can't be written (here a folder
    /// stands where it goes, as a full disk refuses it) still opens: the
    /// write after an extraction is best-effort. Before, the open failed.
    func testABookOpensWhenItsCacheCantBeWritten() async throws {
        let index = try makeFolder().appendingPathComponent("library.json")
        var book = PlaybackTestRig.makeDocument(hash: "cacheless-\(UUID().uuidString)", sentences: 2)
        book = LibraryDocument(id: book.id, title: book.title, fileName: "\(book.id.uuidString).txt",
                               addedAt: book.addedAt, pageCount: 1, sentenceCount: 2,
                               contentHash: book.contentHash, kind: .text)
        let file = DocumentStore.fileURL(for: book)
        let cache = DocumentStore.contentCacheURL(for: book.id)
        try "A short book. It has two sentences.".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: cache)
        }
        try Self.encoder.encode(Index(version: 2, documents: [book])).write(to: index)
        let store = DocumentStore(indexURL: index, saveInterval: 60, notifications: NotificationCenter())

        let content = try await store.content(for: book)

        XCTAssertFalse(content.sentences.isEmpty, "the book opens")
    }

    // MARK: Rename and Mark as finished the index can't record (J012)

    /// Out of space: the change is rolled back and thrown, so the Library
    /// can say why. Before, the shelf showed it and the next launch lost it.
    func testARenameOrMarkTheIndexCantRecordIsRolledBack() throws {
        let (store, book, index) = try makeStore(saveInterval: 60)
        store.writeIndexData = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }

        XCTAssertThrowsError(try store.rename(book, to: "Emma (book club)")) { error in
            XCTAssertEqual(EditFailure(.rename, error).cause, .outOfSpace)
        }
        XCTAssertThrowsError(try store.markFinished(id: book.id)) { error in
            XCTAssertEqual(EditFailure(.markFinished, error).cause, .outOfSpace)
        }

        XCTAssertEqual(store.documents.first?.title, book.title)
        XCTAssertEqual(store.documents.first?.progressFraction, 0)
        XCTAssertEqual(try sentenceOnDisk(index, book.id), 0)
    }

    /// The failure alert says which change didn't happen, and what to do,
    /// in Delete's words.
    func testARenameOrMarkFailureSaysWhyInFixedCopy() {
        let full = CocoaError(.fileWriteOutOfSpace)
        XCTAssertEqual(EditFailure(.rename, full).title, DeleteFailure.outOfSpace.title)
        XCTAssertEqual(EditFailure(.markFinished, full).nextStep, "Free up some space, then try again.")
        let unreadable = EditFailure(.rename, LibraryIndexError.unreadable)
        XCTAssertEqual(unreadable.title, "This book couldn’t be renamed.")
        XCTAssertEqual(unreadable.nextStep, DeleteFailure.libraryUnreadable.nextStep)
        XCTAssertEqual(EditFailure(.markFinished, CocoaError(.fileWriteNoPermission)).title,
                       "This book couldn’t be marked as finished.")
        XCTAssertEqual(EditFailure(.markFinished, CocoaError(.fileWriteNoPermission)).nextStep, "Try again.")
        XCTAssertEqual(EditFailure(.markUnfinished, CocoaError(.fileWriteNoPermission)).title,
                       "This book couldn’t be marked as unfinished.")
        XCTAssertEqual(EditFailure(.markUnfinished, full).title, DeleteFailure.outOfSpace.title)
    }

    // MARK: - Mark as Unfinished (R2-06)

    /// Partway, then Mark as Finished, then Mark as Unfinished: the book is
    /// back at its place, on disk at once, and the kept place is gone.
    func testMarkAsUnfinishedPutsTheOldPlaceBack() throws {
        let (store, book, index) = try makeStore(saveInterval: 60)
        store.saveProgress(id: book.id, sentence: 120, fraction: 0.3)
        try store.markFinished(id: book.id)
        let finished = try XCTUnwrap(store.documents.first)
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.placeBeforeFinish, 120)
        XCTAssertEqual(finished.fractionBeforeFinish, 0.3)
        XCTAssertEqual(try sentenceOnDisk(index, book.id), 399, "Mark as Finished is written at once")

        try store.markUnfinished(id: book.id, newestPlace: 7)
        let unfinished = try XCTUnwrap(store.documents.first)
        XCTAssertFalse(unfinished.isFinished)
        XCTAssertEqual(unfinished.progressSentence, 120, "the kept place outranks the newest stop")
        XCTAssertEqual(unfinished.progressFraction, 0.3, accuracy: 0.0001)
        XCTAssertNil(unfinished.placeBeforeFinish)
        XCTAssertNil(unfinished.fractionBeforeFinish)
        XCTAssertEqual(try sentenceOnDisk(index, book.id), 120, "written at once, not debounced")
    }

    /// A progress write that moves the place forgets the kept one, which
    /// would otherwise be stale; one that leaves the book where it is (a
    /// finished book reopened at its end) keeps it.
    func testAProgressWriteForgetsTheKeptPlace() throws {
        let (store, book, _) = try makeStore(saveInterval: 60)
        store.saveProgress(id: book.id, sentence: 120, fraction: 0.3)
        try store.markFinished(id: book.id)
        store.saveProgress(id: book.id, sentence: 399, fraction: 1)
        XCTAssertEqual(store.documents.first?.placeBeforeFinish, 120, "no move, nothing forgotten")
        store.saveProgress(id: book.id, sentence: 10, fraction: 0.025)
        XCTAssertNil(store.documents.first?.placeBeforeFinish)
        XCTAssertNil(store.documents.first?.fractionBeforeFinish)
    }

    /// A mark the index can't record leaves the book Finished, its kept
    /// place with it.
    func testAnUnfinishTheIndexCantRecordIsRolledBack() throws {
        let (store, book, index) = try makeStore(saveInterval: 60)
        store.saveProgress(id: book.id, sentence: 120, fraction: 0.3)
        try store.markFinished(id: book.id)
        store.writeIndexData = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try store.markUnfinished(id: book.id)) { error in
            XCTAssertEqual(EditFailure(.markUnfinished, error).cause, .outOfSpace)
        }
        XCTAssertEqual(store.documents.first?.progressFraction, 1)
        XCTAssertEqual(store.documents.first?.placeBeforeFinish, 120)
        XCTAssertEqual(try sentenceOnDisk(index, book.id), 399)
    }

    /// A library.json written before the kept place existed still loads,
    /// and a record that has one writes and reads it back.
    func testTheKeptPlaceDecodesFromOldAndNewRecords() throws {
        let old = """
            {"id":"\(UUID().uuidString)","title":"Old","fileName":"old.txt","addedAt":"2024-01-01T00:00:00Z",
             "pageCount":1,"sentenceCount":10,"progressSentence":9,"progressFraction":1,"contentHash":"h"}
            """
        let decoded = try Self.decoder.decode(LibraryDocument.self, from: Data(old.utf8))
        XCTAssertNil(decoded.placeBeforeFinish)
        XCTAssertNil(decoded.fractionBeforeFinish)
        XCTAssertEqual(DocumentStore.markingUnfinished(decoded).progressSentence, 0, "no kept place: the start")

        var kept = decoded
        kept.placeBeforeFinish = 4
        kept.fractionBeforeFinish = 0.4
        let round = try Self.decoder.decode(LibraryDocument.self, from: Self.encoder.encode(kept))
        XCTAssertEqual(round.placeBeforeFinish, 4)
        XCTAssertEqual(round.fractionBeforeFinish, 0.4)
        let plain = String(decoding: try Self.encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(plain.contains("BeforeFinish"), "a record without one writes no key")
    }

    /// A delete while an unreadable index is kept fails too, and frees
    /// nothing: no write is tried.
    func testADeleteWhileTheIndexIsUnreadableFails() throws {
        let (index, bytes, book) = try writeNewerIndex()
        let store = DocumentStore(indexURL: index, saveInterval: 60, notifications: NotificationCenter())
        let cache = DocumentStore.contentCacheURL(for: book.id)
        try Data("x".utf8).write(to: cache)
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }

        XCTAssertThrowsError(try store.delete(book)) { error in
            XCTAssertEqual(DeleteFailure(error), .libraryUnreadable)
        }

        XCTAssertEqual(store.documents.map(\.id), [book.id])
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    /// A failed Delete's alert is fixed copy, the device named as each
    /// platform names it.
    func testADeleteFailureSaysWhyInFixedCopy() {
        #if os(iOS)
        XCTAssertEqual(DeleteFailure.outOfSpace.title, "iPhone is out of space.")
        #else
        XCTAssertEqual(DeleteFailure.outOfSpace.title, "Your Mac is out of space.")
        #endif
        XCTAssertEqual(DeleteFailure.outOfSpace.nextStep, "Free up some space, then delete it again.")
        XCTAssertEqual(DeleteFailure(POSIXError(.ENOSPC)), .outOfSpace)
        XCTAssertEqual(DeleteFailure(CocoaError(.fileWriteNoPermission)), .notSaved)
        XCTAssertEqual(DeleteFailure(LibraryIndexError.unreadable), .libraryUnreadable)
        for failure in DeleteFailure.allCases {
            XCTAssertFalse(failure.title.isEmpty)
            XCTAssertFalse(failure.nextStep.isEmpty)
        }
    }

    // MARK: Rename

    /// An empty or all-space title is no rename: Rename's Save is off for
    /// it (LibraryView), and the store keeps the old title.
    func testAnEmptyTitleIsNoRename() throws {
        XCTAssertNil(DocumentStore.renamedTitle(""))
        XCTAssertNil(DocumentStore.renamedTitle("  \n "))
        XCTAssertEqual(DocumentStore.renamedTitle("  Emma "), "Emma")

        let (store, book, _) = try makeStore(saveInterval: 60)
        try store.rename(book, to: "   ")
        XCTAssertEqual(store.documents.first?.title, book.title)
        try store.rename(book, to: " Emma ")
        XCTAssertEqual(store.documents.first?.title, "Emma")
    }
}
