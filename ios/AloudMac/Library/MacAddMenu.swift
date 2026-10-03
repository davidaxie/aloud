import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// R10 on the Mac: the toolbar's "+" pull-down, with exactly the iPhone's
/// two items, "Classics" and "From Files…", mirrored by File ▸ Add a
/// Classic… and Add from Files…. It shows only once a book exists; the
/// empty Library's own links are the way in until then. Drawn in Theme.text:
/// the Library's one accent fill belongs to the Continue card.
struct MacAddMenu: View {
    @EnvironmentObject private var router: LibraryRouter

    var body: some View {
        Menu {
            ForEach(LibraryAddMenuItem.allCases, id: \.self) { item in
                Button {
                    choose(item)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add a classic or a file")
        .accessibilityLabel("Add")
        .accessibilityIdentifier("library.add")
    }

    private func choose(_ item: LibraryAddMenuItem) {
        switch item {
        case .classics: router.showBookshelf()
        case .files: router.rootPresentation = .filePicker
        }
    }
}

// MARK: - Every route in

/// Every way a file reaches the Mac app, Add from Files…, a drop on the
/// window, Finder's Open With, a drop on the Dock icon and ⌘V in the
/// Library, ends here and then in the shared `DocumentImporter`, which
/// deduplicates by content hash, extracts and opens (M8). Pasted text goes
/// straight to the importer (`admitPasteboard(_:)`): it has no file to copy.
///
/// Two Mac rules sit in front of the importer:
/// - **The coordinated copy.** Each file is read through `NSFileCoordinator`
///   into a staging copy, so a cloud placeholder (iCloud Drive, or a File
///   Provider such as OneDrive) is fetched before it is read. A coordinator
///   that can't fetch it, offline, fails as `notDownloaded`, and nothing is
///   stored. The copy sits in `Documents/Inbox`, where the importer already
///   deletes its file once the add ends, whatever the outcome.
/// - **Several files open none.** Two or more go to the importer as one
///   batch (`importFiles(at:)`): all are added quietly, the user stays where
///   they are, and VoiceOver hears one count ("Added 3 books"), not a line
///   per file. One file opens playing (R4), unless the user moved on while
///   it was still copying. Open With hands its files over one at a time, so
///   they are gathered into one batch first (`admitOpened(_:)`).
@MainActor
final class MacFileIntake: ObservableObject {

    /// A file that never reached the importer. Shown in the importer's
    /// failure alert, before the importer's own failure, one at a time.
    @Published private(set) var failure: ImportFailure?

    /// Copies a file to where the importer reads it. Tests replace it.
    typealias Stage = @Sendable (URL) async throws -> URL

    /// The app's one intake, over the app's one importer. Finder's Open With
    /// and the Dock reach it from the app delegate.
    static let shared = MacFileIntake(importer: AppModel.shared.importer)

    private let importer: DocumentImporter
    private let stage: Stage
    /// While set, a finished add never opens its book: a batch is in flight.
    /// The importer's batch opens none on its own; the hold covers what it
    /// can't know, the one file of a batch whose others failed to copy, and
    /// a file whose user moved on while it copied.
    private(set) var holdsOpens = false
    /// Files still being copied, so a batch's hold outlasts a quick first add.
    private var staging = 0
    /// Files opened from outside the app this turn, admitted together on
    /// the next (`admitOpened(_:)`).
    private var gathered: [URL] = []
    private var cancellables: Set<AnyCancellable> = []

    init(importer: DocumentImporter, stage: @escaping Stage = MacFileIntake.coordinatedCopy) {
        self.importer = importer
        self.stage = stage
        // The importer's open goes through the hold. The router's open stays
        // the one way into the reader; a held add only declines to use it.
        let open = importer.onAdded
        importer.onAdded = { [weak self] document in
            guard self?.holdsOpens != true else { return }
            open?(document)
        }
        // Published values arrive before they're set, and a queued file
        // starts in the same turn the last one ended, so the hold is
        // checked a turn later, when the importer has settled.
        importer.$phase.map { _ in () }
            .merge(with: importer.$addingClassicID.map { _ in () })
            .sink { [weak self] in
                Task { @MainActor in self?.releaseHoldIfSettled() }
            }
            .store(in: &cancellables)
    }

    /// The types any route accepts: the Files panel's and the drop's.
    nonisolated static let contentTypes: [UTType] = [.pdf, .plainText]

    /// Adds `urls` in order. Anything but a PDF or plain-text file is left
    /// out (a folder, say): the panel and Info.plist already ask for only
    /// these, and the drop lights up only when one is among them.
    func admit(_ urls: [URL]) {
        let files = urls.filter(Self.isAddable)
        guard !files.isEmpty else { return }
        if staging == 0 {
            // The first add of a launch also clears what an earlier run
            // staged and never handed over (a quit or crash mid-add): the
            // importer's queue lives in memory, so nothing staged survives.
            Self.sweepStagingFolders(in: Self.stagingRoot, includingUnfinished: !Self.sweptEarlierRuns)
            Self.sweptEarlierRuns = true
        }
        staging += files.count
        let stage = stage
        // The open rule's clock starts here, not at the handoff: a user who
        // moves on while a cloud file downloads stays where they went.
        let startedAt = importer.navigation?.navigationGeneration
        Task {
            var staged: [URL] = []
            var firstFailure: ImportFailure?
            for file in files {
                do {
                    staged.append(try await stage(file))
                } catch {
                    firstFailure = firstFailure ?? Self.failure(for: error, isPDF: Self.isPDF(file))
                }
            }
            // Held from the handoff, not the admit: a classic clicked while
            // a batch copies still opens. All at once, as one batch, so the
            // importer queues it behind its first file and announces it
            // once. A single file whose user moved on is added quietly, as
            // the importer's rule would.
            let movedOn = startedAt != importer.navigation?.navigationGeneration
            if files.count > 1 || movedOn, !staged.isEmpty { holdsOpens = true }
            importer.importFiles(at: staged)
            staging -= files.count
            if failure == nil { failure = firstFailure }
            releaseHoldIfSettled()
        }
    }

    /// One file opened from outside the app: Finder's Open With or a drop
    /// on the Dock icon. AppKit hands over an Apple event's files in one
    /// `application(_:open:)` call, and SwiftUI passes them to `onOpenURL`
    /// one at a time, back to back, with no turn of the main actor between
    /// them. So the files of one turn are gathered and admitted on the next,
    /// all together: several open none and are counted once, as the same
    /// files dropped on the window would be, and one alone opens playing.
    /// No timer: a later Open With is a later event, and a gathering of its
    /// own, and a single file waits no longer than a turn. A file handed
    /// over twice in one turn is gathered once: one file still opens.
    func admitOpened(_ url: URL) {
        guard !gathered.contains(url) else { return }
        gathered.append(url)
        guard gathered.count == 1 else { return }
        Task { self.admitGathered() }
    }

    private func admitGathered() {
        let urls = gathered
        gathered = []
        admit(urls)
    }

    /// The user has seen this file's failure.
    func dismissFailure() {
        failure = nil
    }

    // MARK: Paste

    /// What Edit ▸ Paste (⌘V) takes in the Library: files, or else text.
    nonisolated static let pasteTypes: [UTType] = [.fileURL, .plainText]

    /// What one paste is, by what its items carry.
    enum PasteKind: Equatable {
        case files
        case text
    }

    /// ⌘V's rule in the Library (M8, phase 4), the one decision behind
    /// both pastes (`admitPasteboard(_:)` and `admitPaste(_:)`). Files on
    /// the pasteboard (copied in Finder) are admitted as the same files
    /// dropped would be: one opens playing, several are one batch. With no
    /// file among them, the text becomes a book of its own, titled from its
    /// first line (`DocumentImporter.importText`), for an article copied
    /// before a flight. A Finder copy carries each file's name as text too,
    /// so files win: a copied photo adds nothing, never a book of its name.
    /// Several text items make one book, in order, a blank line apart.
    nonisolated static func pasteKind(carriesFiles: Bool, carriesText: Bool) -> PasteKind? {
        if carriesFiles { return .files }
        return carriesText ? .text : nil
    }

    /// Edit ▸ Paste in the Library, from the window's key tail
    /// (`MacPasteTarget`): the pasteboard is read as the user pastes.
    func admitPasteboard(_ pasteboard: NSPasteboard) {
        let items = pasteboard.pasteboardItems ?? []
        switch Self.pasteKind(in: items) {
        case .files: admit(Self.pastedFileURLs(in: items))
        case .text: admitPastedText(Self.pastedTexts(in: items))
        case nil: return
        }
    }

    /// Whether `pasteboard` holds what Paste takes, a file or text, which
    /// keeps Edit ▸ Paste grey otherwise. Judged by the items' types alone:
    /// reading a file's URL or the text is reading the pasteboard, which
    /// macOS 15.4 and later put to the user unless it is a paste, and Paste
    /// is validated each time the Edit menu opens. So a copied photo leaves
    /// Paste on, and pasting it adds nothing (`admit(_:)` leaves it out).
    static func canAdmitPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        pasteKind(in: pasteboard.pasteboardItems ?? []) != nil
    }

    /// The same paste as SwiftUI's paste command hands it over, while a
    /// Library view has keyboard focus: item providers, read in turn.
    func admitPaste(_ providers: [NSItemProvider]) async {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let texts = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        switch Self.pasteKind(carriesFiles: !files.isEmpty, carriesText: !texts.isEmpty) {
        case .files:
            var urls: [URL] = []
            for provider in files {
                if let url = await Self.pastedFileURL(from: provider) { urls.append(url) }
            }
            admit(urls)
        case .text:
            var parts: [String] = []
            for provider in texts {
                if let text = await Self.pastedText(from: provider) { parts.append(text) }
            }
            admitPastedText(parts)
        case nil:
            return
        }
    }

    /// One book of every text item. Text that couldn't be read is no text:
    /// the empty text's failure.
    private func admitPastedText(_ parts: [String]) {
        importer.importText(parts.joined(separator: "\n\n"))
    }

    private static func pasteKind(in items: [NSPasteboardItem]) -> PasteKind? {
        pasteKind(carriesFiles: items.contains { firstType(conformingTo: .fileURL, in: $0) != nil },
                  carriesText: items.contains { firstType(conformingTo: .plainText, in: $0) != nil })
    }

    /// The first of `item`'s types that is a `type`.
    private static func firstType(conformingTo type: UTType, in item: NSPasteboardItem) -> NSPasteboard.PasteboardType? {
        item.types.first { UTType($0.rawValue)?.conforms(to: type) == true }
    }

    /// Each item's file, as a path: Finder copies a file by reference
    /// ("file:///.file/id=…"), which names no file and has no extension.
    private static func pastedFileURLs(in items: [NSPasteboardItem]) -> [URL] {
        items.compactMap { item in
            guard let fileType = firstType(conformingTo: .fileURL, in: item),
                  let string = item.string(forType: fileType),
                  let url = NSURL(string: string), url.isFileURL else { return nil }
            return url.filePathURL
        }
    }

    private static func pastedTexts(in items: [NSPasteboardItem]) -> [String] {
        items.compactMap { item in
            firstType(conformingTo: .plainText, in: item).flatMap { item.string(forType: $0) }
        }
    }

    private nonisolated static func pastedFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url.flatMap { $0.isFileURL ? $0 : nil })
            }
        }
    }

    private nonisolated static func pastedText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    /// The batch is over once nothing is copying and the importer is idle
    /// (a failure on screen holds the queue, and so the hold).
    private func releaseHoldIfSettled() {
        guard holdsOpens, staging == 0, importer.phase == .idle,
              importer.addingClassicID == nil else { return }
        holdsOpens = false
    }

    // MARK: Rules

    /// By name alone, so a drag can be judged before its files are readable.
    nonisolated static func isAddable(_ url: URL) -> Bool {
        // Lowercased, as the importer reads "SCAN.PDF".
        guard url.isFileURL, !url.hasDirectoryPath,
              let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }

    /// The importer's own test: anything not a PDF is read as text.
    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// The table row for a file that failed before the importer saw it. A
    /// coordinator that couldn't fetch the file, or a cloud file the system
    /// reports unavailable, is `notDownloaded`; anything else reads as the
    /// importer would read it (out of space, couldn't open).
    nonisolated static func failure(for error: any Error, isPDF: Bool) -> ImportFailure {
        if error is CoordinationError { return .notDownloaded }
        if let cocoa = error as? CocoaError, cocoa.code == .ubiquitousFileUnavailable { return .notDownloaded }
        return ImportFailure(error, isPDF: isPDF)
    }

    // MARK: The coordinated copy

    /// The coordinator refused the read: the file is a placeholder it
    /// couldn't fetch. Never shown; `failure(for:isPDF:)` maps it.
    struct CoordinationError: Error {
        let underlying: any Error
    }

    /// Reads `url` through a coordinator, handing `body` a readable URL, or
    /// throws `CoordinationError` when the read can't be coordinated.
    typealias CoordinatedRead = @Sendable (URL, (URL) throws -> Void) throws -> Void

    /// Where staged copies wait for the importer: the folder whose files it
    /// deletes once their add ends (`DocumentImporter.isInboxCopy`).
    nonisolated static var stagingRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// The real stage: off the main actor, since a coordinated read of a
    /// cloud file waits for its download.
    @Sendable nonisolated static func coordinatedCopy(of url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try stageCopy(of: url, into: stagingRoot, read: systemCoordinatedRead)
        }.value
    }

    /// Copies `url` into its own folder under `root`, keeping its name: the
    /// importer titles a text file, and an untitled PDF, by that name. The
    /// source's security scope (a Files panel pick) is held for the read.
    nonisolated static func stageCopy(of url: URL, into root: URL,
                                      read: CoordinatedRead) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try read(url) { readable in
                try FileManager.default.copyItem(at: readable, to: destination)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// `NSFileCoordinator`'s read, which fetches a placeholder first.
    @Sendable nonisolated static func systemCoordinatedRead(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges],
                                       error: &coordinatorError) { readable in
            do { try body(readable) } catch { bodyError = error }
        }
        if let coordinatorError { throw CoordinationError(underlying: coordinatorError) }
        if let bodyError { throw bodyError }
    }

    /// Whether this launch has cleared an earlier run's leftovers.
    private static var sweptEarlierRuns = false

    /// The importer deletes each staged file, not its folder: the empty
    /// folders go before the next batch, while nothing is being copied.
    /// `includingUnfinished` also removes folders that still hold a copy
    /// (only the intake's own, named by a UUID), once per launch.
    static func sweepStagingFolders(in root: URL, includingUnfinished: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for folder in entries where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let isEmpty = (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true
            let isOurs = UUID(uuidString: folder.lastPathComponent) != nil
            if isEmpty || (includingUnfinished && isOurs) {
                try? fm.removeItem(at: folder)
            }
        }
    }
}
