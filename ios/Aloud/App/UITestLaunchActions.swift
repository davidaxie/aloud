import Foundation
import UIKit

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
}

#if DEBUG

/// Fixed files for the `-uitest-open-fixture` / `-uitest-pick-fixture`
/// hooks. Content never varies, so the content hash (and dedupe) is stable
/// across runs.
enum UITestFixtures {

    static let sentences = "The first sentence is short. The second sentence follows it. The third sentence ends the file."

    /// Writes the fixture into Documents/Inbox (the Open-in drop folder) or
    /// the temporary directory, replacing any earlier copy.
    static func write(_ kind: UITestFixtureKind, intoInbox: Bool) throws -> URL {
        let fileManager = FileManager.default
        let directory: URL
        if intoInbox {
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            directory = documents.appendingPathComponent("Inbox", isDirectory: true)
        } else {
            directory = fileManager.temporaryDirectory
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: kind))
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try data(for: kind).write(to: url)
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

    private static func data(for kind: UITestFixtureKind) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        switch kind {
        case .text:
            return Data("Aloud test fixture.\n\n\(sentences)".utf8)
        case .pdf:
            return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
                context.beginPage()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.black,
                ]
                (sentences as NSString).draw(in: page.insetBy(dx: 72, dy: 72),
                                             withAttributes: attributes)
            }
        case .pdfBlank:
            return UIGraphicsPDFRenderer(bounds: page).pdfData { $0.beginPage() }
        case .pdfCorrupt:
            return Data("not a pdf".utf8)
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
