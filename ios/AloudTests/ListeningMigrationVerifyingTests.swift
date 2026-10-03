import XCTest
@testable import Aloud

/// M3 meets R7: an install from before the pinned files re-hashes once at
/// launch (`isVerifying`, state still `.notInstalled`), and its files are on
/// disk meanwhile. The V3 migration that launch runs must see the model, or
/// an explicit System voice choice is dropped as the no-model stand-in and
/// R5 switches the listener to Michael once the hash passes.
///
/// SAFETY: the manager here has its own directory and defaults suite, a
/// fixed path, and a hasher that answers from the pin without reading, so
/// nothing touches the network or the app's model.
@MainActor
final class ListeningMigrationVerifyingTests: XCTestCase {

    private typealias Key = AppModel.PrefKey

    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListeningMigrationVerifyingTests-\(UUID().uuidString)", isDirectory: true)
        suite = "aloud.tests.migrationVerifying.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        suite = nil
        directory = nil
        super.tearDown()
    }

    /// Both pinned files on disk (sparse, at their sizes) with no install
    /// record, as an install from before M3 leaves them: the new manager
    /// starts hashing them at once.
    private func makeVerifyingManager() throws -> ModelManager {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ModelManager.remoteFiles {
            let url = directory.appendingPathComponent(file.name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.expectedBytes))
            try handle.close()
        }
        let manager = ModelManager(pathSource: FixedNetworkPath(isExpensiveOrConstrained: false),
                                   installDirectory: directory,
                                   defaults: defaults,
                                   freeSpace: { 2_000_000_000 },
                                   hasher: { url in
                                       ModelManager.remoteFiles.first { $0.name == url.lastPathComponent }?.sha256 ?? ""
                                   })
        manager.startsNetworkTasks = false
        manager.announce = { _ in }
        return manager
    }

    /// Lets the hash finish before the directory goes.
    private func drain(_ manager: ModelManager) async {
        for _ in 0..<4 {
            guard let task = manager.verification else { return }
            await task.value
        }
    }

    private func book(voiceID: String?) -> LibraryDocument {
        LibraryDocument(id: UUID(),
                        title: "A",
                        fileName: "A.txt",
                        addedAt: Date(timeIntervalSinceNow: -30 * 24 * 3600),
                        lastOpenedAt: Date(timeIntervalSinceNow: -3600),
                        pageCount: 1,
                        sentenceCount: 10,
                        contentHash: "hash-A",
                        kind: .text,
                        wordCount: 1000,
                        preferredRate: nil,
                        preferredVoiceID: voiceID)
    }

    /// The launch's own rule, asked of a manager mid-hash.
    func testAVerifyingModelCountsAsInstalled() async throws {
        let manager = try makeVerifyingManager()
        XCTAssertTrue(manager.isVerifying)
        XCTAssertFalse(manager.isInstalled)
        XCTAssertTrue(AppModel.migrationSeesModel(manager))

        await drain(manager)
        XCTAssertEqual(manager.state, .installed, "the files were a real install")
        XCTAssertTrue(AppModel.migrationSeesModel(manager))
    }

    /// A stored global System choice survives a launch whose model is still
    /// being checked.
    func testAnExplicitSystemChoiceSurvivesWhileTheModelIsVerifying() async throws {
        let manager = try makeVerifyingManager()
        defaults.set(AVSpeechEngine.systemVoiceID, forKey: Key.voiceID)

        AppModel.runListeningMigrationIfNeeded(defaults, documents: [book(voiceID: nil)],
                                               modelInstalled: AppModel.migrationSeesModel(manager))

        XCTAssertEqual(defaults.string(forKey: Key.voiceID), AVSpeechEngine.systemVoiceID)
        XCTAssertTrue(defaults.bool(forKey: Key.migratedV3))
        await drain(manager)
    }

    /// The last book's own System pin becomes the global choice the same way.
    func testABooksSystemPinSurvivesWhileTheModelIsVerifying() async throws {
        let manager = try makeVerifyingManager()

        AppModel.runListeningMigrationIfNeeded(defaults,
                                               documents: [book(voiceID: AVSpeechEngine.systemVoiceID)],
                                               modelInstalled: AppModel.migrationSeesModel(manager))

        XCTAssertEqual(defaults.string(forKey: Key.voiceID), AVSpeechEngine.systemVoiceID)
        await drain(manager)
    }

    /// Why the rule matters: read as "no model", the same launch drops the
    /// choice.
    func testReadAsNoModelTheSameChoiceIsDropped() {
        defaults.set(AVSpeechEngine.systemVoiceID, forKey: Key.voiceID)

        AppModel.runListeningMigrationIfNeeded(defaults, documents: [book(voiceID: AVSpeechEngine.systemVoiceID)],
                                               modelInstalled: false)

        XCTAssertNil(defaults.string(forKey: Key.voiceID))
    }

    /// `AppModel.shared` is built once per test process, before any test
    /// could arrange a verifying model, so the one call site is pinned in
    /// source: the launch migration asks `migrationSeesModel`, nothing
    /// narrower.
    func testTheLaunchMigrationAsksTheVerifyingRule() throws {
        let sources = try SourceTree.sources(only: ["App"])
        let call = "AppModel.runListeningMigrationIfNeeded("
        XCTAssertEqual(SourceTree.files(containing: call, in: sources), ["App/AppModel.swift"])
        let text = try XCTUnwrap(sources["App/AppModel.swift"])
        XCTAssertEqual(SourceTree.occurrences(of: call, in: sources), 1, "one launch call")
        // The declaration and that call: no second, unqualified call
        // (`Self.…`) slips past the pin with a narrower argument.
        XCTAssertEqual(SourceTree.occurrences(of: "runListeningMigrationIfNeeded(", in: sources), 2)
        let start = try XCTUnwrap(text.range(of: call))
        let arguments = text[start.upperBound...].prefix(240)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(arguments.hasPrefix("defaults, documents: store.documents, "
                                          + "modelInstalled: AppModel.migrationSeesModel(modelManager))"),
                      arguments)
    }
}
