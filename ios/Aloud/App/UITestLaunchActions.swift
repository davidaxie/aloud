import Foundation

/// Launch-time UI-test setup: the fault, seeds, fixture imports, routing and
/// a shortcut action, in a fixed order. It never calls startAutoplay(); the
/// reader's startAutoplay() stays the only autoplay path, and the controller
/// gates it. Its only call into play() is `-uitest-shortcut continue`, which
/// runs the Continue listening shortcut's action as the system would, muted
/// like every `-uitest-` launch.
/// Exempt from the "no Task.sleep in add/open paths" lint (DEBUG only).
enum UITestLaunchActions {

    @MainActor
    static func run(_ model: AppModel) async {
        #if DEBUG
        // First, so a fault armed at launch is in place before any book opens.
        if let kind = UITestHooks.fault {
            UITestFaultInjector.arm(kind, afterPlayingSeconds: UITestHooks.faultAfterSeconds, model: model)
        }
        for book in model.bookshelf.prefix(UITestHooks.seedClassicCount) {
            _ = try? await model.documentStore.addClassic(book)
        }
        for id in UITestHooks.seedClassicIDs {
            if let book = model.bookshelfIndex.book(gutenbergID: id) {
                _ = try? await model.documentStore.addClassic(book)
            }
        }
        if UITestHooks.seedFinished,
           let first = model.bookshelf.first,
           let document = try? await model.documentStore.addClassic(first) {
            model.documentStore.saveProgress(id: document.id,
                                             sentence: max(document.sentenceCount - 1, 0),
                                             fraction: 1.0)
        }
        if UITestHooks.seedPlaceCount > 0, let first = model.documentStore.documents.first {
            let newest = seedPlaces(UITestHooks.seedPlaceCount, in: first, history: model.placeHistory)
            // `-uitest-playhead-at-newest-place`: the book resumes where it
            // was last left, so the newest stop and the playhead share a
            // (late) chapter, as after an ordinary listen.
            if Self.playheadAtNewestPlace, let newest, first.sentenceCount > 0 {
                model.documentStore.saveProgress(id: first.id, sentence: newest,
                                                 fraction: Double(newest) / Double(first.sentenceCount))
            }
        }
        if let kind = UITestHooks.openFixture,
           let url = try? UITestFixtures.write(kind, intoInbox: true) {
            model.handleOpenURL(url)
        }
        if let kind = UITestHooks.pickFixture,
           let url = try? UITestFixtures.write(kind, intoInbox: false) {
            model.importer.handlePick(.success(url))
        }
        if UITestHooks.openFirstDoc, let first = model.documentStore.documents.first {
            // Lets the NavigationStack attach before its path changes.
            try? await Task.sleep(for: .milliseconds(300))
            model.router.open(first)
        }
        // Last, so the shortcut finds the shelf (and any open reader) the
        // seeds and routing left, as a real one would.
        if let shortcut = UITestHooks.shortcut {
            switch shortcut {
            case .continueListening: _ = await model.shortcutActions.continueListening()
            case .sleep(let choice): model.shortcutActions.setSleepTimer(choice)
            }
        }
        #endif
    }

    #if DEBUG
    /// `count` stops through `document`, oldest first, an hour apart and far
    /// apart in the book, each a full listen from its own sentence, so the
    /// rules keep every one (`PlaceHistory.recording`).
    /// Returns the newest stop's sentence, nil when none was seeded.
    @MainActor @discardableResult
    private static func seedPlaces(_ count: Int, in document: LibraryDocument,
                                   history: PlaceHistoryStore) -> Int? {
        let kept = min(count, PlaceHistory.limit)
        var newest: Int?
        let spacing = max(document.sentenceCount / (kept + 1), PlaceHistory.samePlaceSentences + 1)
        let start = Date().addingTimeInterval(-Double(kept + 1) * 3_600)
        for index in 0..<kept {
            let sentence = min(spacing * (index + 1), max(document.sentenceCount - 1, 0))
            let startedAt = start.addingTimeInterval(Double(index) * 3_600)
            let listened = PlaceHistory.minimumListen * 3
            history.record(PlaceStop(documentID: document.id, contentHash: document.contentHash,
                                     sentence: sentence, excerpt: nil, startSentence: sentence,
                                     startedAt: startedAt, stoppedAt: startedAt.addingTimeInterval(listened),
                                     listenedSeconds: listened, movedAway: false),
                           contentHash: document.contentHash)
            newest = sentence
        }
        return newest
    }

    /// Read here rather than in `UITestHooks`: only the places seed uses it.
    private static var playheadAtNewestPlace: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-playhead-at-newest-place")
    }
    #endif
}

#if DEBUG

/// Fixed files for the `-uitest-open-fixture` / `-uitest-pick-fixture`
/// hooks. Content never varies, so the content hash (and dedupe) is stable
/// across runs.
enum UITestFixtures {

    static let sentences = "The first sentence is short. The second sentence follows it. The third sentence ends the file."

    /// Writes the fixture into the fixture root's Inbox (on the iPhone,
    /// Documents/Inbox, the Open-in drop folder) or the temporary directory,
    /// replacing any earlier copy.
    static func write(_ kind: UITestFixtureKind, intoInbox: Bool) throws -> URL {
        let fileManager = FileManager.default
        let directory: URL
        if intoInbox {
            directory = PlatformPaths.fixtureRoot.appendingPathComponent("Inbox", isDirectory: true)
        } else {
            directory = fileManager.temporaryDirectory
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: kind))
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try write(kind, to: url)
        return url
    }

    private static func fileName(for kind: UITestFixtureKind) -> String {
        switch kind {
        case .text: return "aloud-fixture.txt"
        case .pdf: return "aloud-fixture.pdf"
        case .pdfBlank: return "aloud-blank.pdf"
        case .pdfCorrupt: return "aloud-corrupt.pdf"
        }
    }

    /// The PDFs are drawn by `FixturePDF` (one US Letter page, the text
    /// inside one-inch margins), the same file on every platform.
    private static func write(_ kind: UITestFixtureKind, to url: URL) throws {
        switch kind {
        case .text:
            try Data("Aloud test fixture.\n\n\(sentences)".utf8).write(to: url)
        case .pdf:
            try FixturePDF.write(pages: [sentences], to: url)
        case .pdfBlank:
            try FixturePDF.write(pages: [""], to: url)
        case .pdfCorrupt:
            try Data("not a pdf".utf8).write(to: url)
        }
    }
}

/// `-uitest-slow-import`: holds every Files and Open-in import for `delay`
/// so the overlay and its Cancel can be exercised. The sleep throws on
/// cancel, so a cancelled import never reaches the store.
@MainActor
final class SlowLibraryAdding: LibraryAdding {

    private let base: DocumentStore
    private let delay: Duration

    init(base: DocumentStore, delay: Duration = .seconds(10)) {
        self.base = base
        self.delay = delay
    }

    var documents: [LibraryDocument] { base.documents }

    func importPDF(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
        try await Task.sleep(for: delay)
        return try await base.importPDF(from: url, progress: progress)
    }

    func importText(title: String, author: String?, from url: URL,
                    progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
        try await Task.sleep(for: delay)
        return try await base.importText(title: title, author: author, from: url, progress: progress)
    }

    func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
        try await base.addClassic(book)
    }
}

#endif
