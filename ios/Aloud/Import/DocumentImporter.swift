import SwiftUI

/// What the importer needs from the library. DocumentStore in the app; an
/// in-memory fake in tests, so the add path is exercised without disk or
/// extraction.
@MainActor
protocol LibraryAdding: AnyObject {
    var documents: [LibraryDocument] { get }
    func importPDF(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument
    func importText(title: String, author: String?, from url: URL,
                    progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument
    func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument
}

extension DocumentStore: LibraryAdding {}

/// Where the user is, for the importer's open rule: a value that changes
/// whenever they navigate. LibraryRouter in the app.
@MainActor
protocol NavigationTracking: AnyObject {
    var navigationGeneration: UInt64 { get }
}

extension LibraryRouter: NavigationTracking {}

/// R10: the one add path. Files picks, Open-in files, Bookshelf classics
/// and the Mac's pasted text all land here; a finished add hands the
/// document to `onAdded`, which AppModel points at `router.open` so it
/// opens playing (R4).
///
/// The open rule. An add opens its book only if, when it ends, nothing is
/// queued behind it and the user has not navigated since it began (no push,
/// pop or swap of the stack, no root picker or alert opened). Otherwise the
/// book is added quietly and announced, and the user stays where they are.
/// Opening anyway would push a reader that starts speaking under the next
/// import's overlay or a modal, or tear down a book the user chose while a
/// slow classic was still being added. So a batch of queued files opens
/// only the last one.
///
/// Several files handed over at once (`importFiles(at:)`, the Mac's
/// multi-file pick or drop) are a batch of their own (M8): all are added,
/// none opens, and VoiceOver hears one count when the last ends ("Added 3
/// books") instead of a line per file.
@MainActor
final class DocumentImporter: ObservableObject {

    enum Phase: Equatable {
        case idle
        case importing(fileName: String, progress: Double)
        case failed(ImportFailure)
    }

    @Published private(set) var phase: Phase = .idle {
        // Each new phase drops the last failure's file name; a batch's
        // failure sets its own just after (`failedFileName`).
        didSet { if failedFileName != nil { failedFileName = nil } }
    }
    /// The file the failure on screen is about, when it is one of several
    /// handed over at once (a Mac drop or multi-file pick, M8): the alert
    /// names it (`failureTitle`). Nil for a single add, whose file the
    /// user has just chosen, and for every other failure (L007).
    @Published private(set) var failedFileName: String?
    /// The classic being added; the Bookshelf shows its row's spinner from it.
    @Published private(set) var addingClassicID: Int?

    var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    var failure: ImportFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    /// The failure alert's title: the fixed sentence, naming the file
    /// when it was one of a batch (`ImportFailure.title(naming:)`).
    var failureTitle: String? {
        failure.map { $0.title(naming: failedFileName) }
    }

    var onAdded: ((LibraryDocument) -> Void)?
    /// AppModel points it at the router. Without one (tests that don't care)
    /// the user never moves.
    weak var navigation: (any NavigationTracking)?

    private let library: any LibraryAdding
    private let announce: (String) -> Void
    /// Files that arrived (Open-in) while another add was running or a
    /// failure was still on screen; each is imported in turn, in the batch
    /// it came with, if any, and pasted text with the title it was given.
    private var queued: [(url: URL, batch: Batch?, title: String?)] = []
    /// The batch of the file being added now, if it came in one.
    private var currentBatch: Batch?
    /// A batch's line when its last file failed: said once the failure is
    /// dismissed, not over the alert.
    private var heldBatchLine: String?
    /// Bumped by every import start and by cancel(). A task whose token is
    /// stale finished after the user moved on, so its result is dropped.
    private var token: UInt64 = 0
    private var current: Task<Void, Never>?
    /// Where another app's Open-in copies arrive (the iPhone's
    /// Documents/Inbox), cleared of leftovers when idle; nil on a Mac.
    private let inbox: URL?
    /// How long a copy has been in `inbox` before it counts as left over:
    /// one that has only just arrived may still be on its way here.
    var inboxSweepAge: TimeInterval = 60

    init(library: any LibraryAdding,
         announce: @escaping (String) -> Void = DocumentImporter.postAnnouncement,
         inbox: URL? = PlatformPaths.openInInbox) {
        self.library = library
        self.announce = announce
        self.inbox = inbox
    }

    /// Busy holds the queue: starting the next file mid-add, or over a
    /// failure not yet dismissed, would overwrite what the user is reading.
    private var isBusy: Bool { phase != .idle || addingClassicID != nil }

    func handlePick(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            importFile(at: url)
        case .failure(let error):
            // Backing out of the picker is not a failure.
            if (error as? CocoaError)?.code == .userCancelled { return }
            phase = .failed(.couldNotOpen)
        }
    }

    func importFile(at url: URL) {
        start(url, in: nil)
    }

    /// Several files handed over at once (M8): all are added in order and
    /// none opens, and the count is announced once, when the last ends. A
    /// failure among them still shows, and holds the rest, as any failure
    /// does; when the last one fails, the count waits for its alert to
    /// close. One file is an ordinary add.
    func importFiles(at urls: [URL]) {
        guard urls.count > 1 else {
            urls.first.map(importFile(at:))
            return
        }
        let batch = Batch(count: urls.count)
        for url in urls { start(url, in: batch) }
    }

    /// ⌘V's text in the Mac's Library (M8): a book of its own, titled from
    /// its first line with words in it, added as a text file is. The words
    /// are written to a file of their own (`pastedTextFolder`) and handed to
    /// the store like any text file, so the same text pasted twice is the
    /// book already on the shelf, and one paste opens playing by the open
    /// rule (R4). Behind an add in flight it waits its turn, as a file does.
    /// Text that is only whitespace fails as an empty text file does; with
    /// an add in flight or a failure on screen there is nowhere to say so,
    /// and it is let go.
    func importText(_ text: String) {
        guard let title = Self.pastedTitle(from: text) else {
            if !isBusy { phase = .failed(.textNoText) }
            return
        }
        do {
            start(try Self.writePastedText(text), in: nil, title: title)
        } catch {
            if !isBusy { phase = .failed(ImportFailure(error, isPDF: false)) }
        }
    }

    /// `title` names pasted text, whose file's name says nothing.
    private func start(_ url: URL, in batch: Batch?, title: String? = nil) {
        guard !isBusy else {
            queued.append((url, batch, title))
            return
        }
        token &+= 1
        let mine = token
        currentBatch = batch
        let startedAt = navigation?.navigationGeneration
        // Snapshot before the add, so a duplicate (the store returns the
        // record already on the shelf) is announced as such.
        let before = Set(library.documents.map(\.id))
        let isPDF = !Self.isPastedText(url) && Self.isPDF(url)
        let name = title ?? url.displayName
        phase = .importing(fileName: name, progress: 0)

        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.token == mine,
                      case .importing(let name, _) = self.phase else { return }
                self.phase = .importing(fileName: name, progress: value)
            }
        }

        // Leaving the app mid-add finishes it rather than suspending it
        // halfway with its copies on disk (F036).
        let backgroundTime = PlatformBackgroundTask(name: "Adding a book")
        current = Task {
            do {
                let document = isPDF
                    ? try await library.importPDF(from: url, progress: progress)
                    : try await library.importText(title: title ?? Self.title(from: url), author: nil,
                                                   from: url, progress: progress)
                if token == mine {
                    phase = .idle
                    if let batch {
                        batch.tally(document, isNew: !before.contains(document.id))
                    } else {
                        announce(Self.completion(for: document, before: before))
                        if mayOpen(startedAt: startedAt) { onAdded?(document) }
                    }
                }
            } catch is CancellationError {
                // cancel() already reset the phase and moved the token on.
            } catch {
                if token == mine {
                    phase = .failed(ImportFailure(error, isPDF: isPDF))
                    // One of several added at once: the alert says which.
                    if batch != nil { failedFileName = name }
                }
            }
            // Inbox cleanup runs on success, failure and cancel alike, and
            // so does a paste's.
            Self.removeHandedOverCopy(url)
            if token == mine {
                currentBatch = nil
                if let batch { endFile(of: batch) }
                startNextQueued()
            }
            sweepInboxIfIdle()
            backgroundTime.end()
        }
    }

    /// The overlay's Cancel: back to the shelf at once, the queue dropped
    /// with it. A late result is ignored by token, so the book never opens.
    /// A batch cut short still announces the books it had added.
    func cancel() {
        guard isImporting else { return }
        token &+= 1
        current?.cancel()
        current = nil
        queued.forEach { Self.removeHandedOverCopy($0.url) }
        let cut = ([currentBatch] + queued.map(\.batch)).compactMap { $0 }
        queued = []
        currentBatch = nil
        phase = .idle
        var seen: Set<ObjectIdentifier> = []
        for batch in cut where seen.insert(ObjectIdentifier(batch)).inserted && batch.added > 0 {
            announce(ImportCopy.addedBooks(batch.added))
        }
    }

    /// The user has seen the failure: clear it, say the count of a batch
    /// it ended, and resume any files that queued up behind it.
    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = .idle
        if let line = heldBatchLine {
            heldBatchLine = nil
            announce(line)
        }
        startNextQueued()
        sweepInboxIfIdle()
    }

    /// A Bookshelf row: adds the bundled book if needed and opens it. No
    /// overlay, since most classics add in a moment, so the user can leave
    /// while a long one is still extracting; the open rule then keeps it from
    /// opening on top of wherever they went. The opened reader is the
    /// confirmation; a quiet add is announced instead. A tap while anything
    /// is in flight is ignored, so a double tap adds one copy.
    func addClassic(_ book: BookshelfBook) {
        guard addingClassicID == nil, phase == .idle else { return }
        addingClassicID = book.id
        let startedAt = navigation?.navigationGeneration
        let before = Set(library.documents.map(\.id))
        let backgroundTime = PlatformBackgroundTask(name: "Adding a book")
        Task {
            defer {
                addingClassicID = nil
                startNextQueued()
                backgroundTime.end()
            }
            do {
                let document = try await library.addClassic(book)
                if mayOpen(startedAt: startedAt) {
                    onAdded?(document)
                } else {
                    announce(Self.completion(for: document, before: before))
                }
            } catch {
                phase = .failed(ImportFailure(error, isPDF: false))
            }
        }
    }

    /// The open rule (see the type comment), checked when an add ends.
    private func mayOpen(startedAt generation: UInt64?) -> Bool {
        queued.isEmpty && generation == navigation?.navigationGeneration
    }

    private static func completion(for document: LibraryDocument, before: Set<UUID>) -> String {
        before.contains(document.id)
            ? ImportCopy.alreadyInLibrary(document.title)
            : ImportCopy.added(document.title)
    }

    private func startNextQueued() {
        guard !isBusy, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        start(next.url, in: next.batch, title: next.title)
    }

    /// One of `batch`'s files has ended, added or not; the last announces,
    /// or holds its line while its own failure is on screen.
    private func endFile(of batch: Batch) {
        batch.remaining -= 1
        guard batch.remaining == 0, let line = batch.completion else { return }
        if failure == nil { announce(line) } else { heldBatchLine = line }
    }

    /// Several files handed over at once. Its files share this tally rather
    /// than each announcing or opening on its own.
    @MainActor
    private final class Batch {
        /// Files not yet ended, the one being added included.
        var remaining: Int
        private(set) var added = 0
        /// The books that were already on the shelf, by title, each once.
        private var alreadyInLibrary: [UUID: String] = [:]

        init(count: Int) {
            remaining = count
        }

        func tally(_ document: LibraryDocument, isNew: Bool) {
            if isNew { added += 1 } else { alreadyInLibrary[document.id] = document.title }
        }

        /// The batch's one line: the new books, or that what it held was
        /// already on the shelf, by title when that is one book (the same
        /// file twice, or the others failed). None when every file failed,
        /// since each failure was shown and nothing was added.
        var completion: String? {
            if added > 0 { return ImportCopy.addedBooks(added) }
            switch alreadyInLibrary.count {
            case 0: return nil
            case 1: return alreadyInLibrary.values.first.map(ImportCopy.alreadyInLibrary)
            default: return ImportCopy.booksAlreadyInLibrary
            }
        }
    }

    /// Completion is spoken over whatever VoiceOver was reading: the overlay
    /// that held focus has just gone. Never posted in a muted (test) process.
    nonisolated static func postAnnouncement(_ text: String) {
        guard !UITestHooks.muteAudio else { return }
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// "Open in Aloud" from another app: iOS copies the file into
    /// Documents/Inbox (the app does not open documents in place). The store
    /// makes its own copy, so the Inbox copy is removed once the import ends,
    /// successful or not.
    static func removeInboxCopy(_ url: URL) {
        guard isInboxCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Clears what an add that never finished left in the Open-in folder
    /// (the app ended mid-import, F036). Only while nothing is being added
    /// or waits its turn, so never during an import; never at launch, when
    /// a cold Open-in's copy is there before its URL arrives; and only
    /// copies at least `inboxSweepAge` old.
    private func sweepInboxIfIdle() {
        guard !isBusy, queued.isEmpty, let inbox else { return }
        Self.sweepLeftovers(in: inbox, arrivedBefore: Date().addingTimeInterval(-inboxSweepAge))
    }

    /// Removes what arrived in `folder` before `cutoff`: by the date it was
    /// added there, else its creation, else its last change.
    nonisolated static func sweepLeftovers(in folder: URL, arrivedBefore cutoff: Date) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        else { return }
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            guard let arrived = values?.addedToDirectoryDate ?? values?.creationDate
                    ?? values?.contentModificationDate,
                  arrived < cutoff else { continue }
            DocumentStore.unlock(entry)
            try? fm.removeItem(at: entry)
        }
    }

    static func isInboxCopy(_ url: URL) -> Bool {
        guard url.isFileURL,
              let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return false }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
            .standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(inbox + "/")
    }

    /// The importer's own copy of what it was handed, an Inbox copy or a
    /// paste's file, removed once its add ends. A file picked where it
    /// lives is never touched. A locked copy (an Open-in's, an earlier
    /// build's staged one) is unlocked first, or it would stay.
    private static func removeHandedOverCopy(_ url: URL) {
        guard isInboxCopy(url) || isPastedText(url) else { return }
        DocumentStore.unlock(url)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Pasted text

    /// The longest a pasted text's title runs before it is cut, with "…".
    static let pastedTitleLimit = 80

    /// Where pasted text waits for the store's own copy: the temporary
    /// folder, since the iPhone's Inbox is the system's to write to.
    static var pastedTextFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Pasted", isDirectory: true)
    }

    static func isPastedText(_ url: URL) -> Bool {
        url.isFileURL
            && url.standardizedFileURL.path.hasPrefix(pastedTextFolder.standardizedFileURL.path + "/")
    }

    /// A pasted text's title: its first line with words in it, each run of
    /// whitespace one space, cut back to a whole word past
    /// `pastedTitleLimit` characters (or mid-word, when a cut at a word
    /// would leave less than half). Nil when the text is only whitespace.
    static func pastedTitle(from text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        guard line.count > pastedTitleLimit else { return line }
        var cut = line.prefix(pastedTitleLimit)
        if line[cut.endIndex] != " ", let space = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: space) >= pastedTitleLimit / 2 {
            cut = cut[..<space]
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The paste's words as a UTF-8 file of its own: the bytes the store
    /// hashes to find the same text pasted again.
    private static func writePastedText(_ text: String) throws -> URL {
        let folder = pastedTextFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// A ".pdf" name, or a PDF's own "%PDF-" signature under another name
    /// (a download saved as .txt), which the text reader would only read
    /// out as its internal syntax. A file that can't be read yet goes by
    /// its name.
    nonisolated static func isPDF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024) else { return false }
        return TextExtractor.hasPDFSignature(head)
    }

    /// "moby-dick_ch1.txt" → "Moby Dick Ch1". From the name Finder shows
    /// (`URL.displayStem`), so "AC/DC Live.txt" is "AC/DC Live".
    static func title(from url: URL) -> String {
        let base = url.displayStem
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return url.displayName }
        return base == base.lowercased() ? base.localizedCapitalized : base
    }
}

/// Progress card shown over the Library while extraction runs: a modal
/// scrim in shadow ink under a raised surface card. The scrim swallows
/// touches and the overlay is modal for VoiceOver, so the shelf beneath
/// can't be reached until the add ends or is cancelled. Modal alone doesn't
/// hide the stack's hosted content, so LibraryView hides its shelf and bar
/// items itself while `isImporting`.
struct ImportProgressOverlay: View {
    let fileName: String
    let progress: Double
    let onCancel: () -> Void

    init(fileName: String, progress: Double, onCancel: @escaping () -> Void) {
        self.fileName = fileName
        self.progress = progress
        self.onCancel = onCancel
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focused: Bool

    /// Fits "100%" at the caption style's current size.
    @ScaledMetric(relativeTo: .caption) private var percentWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 300

    var body: some View {
        ZStack {
            Theme.Elevation.scrim
                .ignoresSafeArea()
                .accessibilityHidden(true)
            card
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onCancel)
        .accessibilityIdentifier("import.overlay")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            progressGroup
            cancelButton
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.surface)
                .raisedElevation()
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth)
        )
        .padding(Theme.Space.xxl)
    }

    private var progressGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // R25: one word for an add in progress, as on the Bookshelf row
            // ("Adding…"). "Preparing" means only "Preparing voice…".
            Text("Adding")
                .font(Theme.font(.eyebrow))
                .eyebrowTracking()
                .foregroundStyle(Theme.textFaint)
            Text(fileName)
                .font(Theme.font(.callout))
                .foregroundStyle(Theme.text)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
            HStack(spacing: Theme.Space.sm) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * clampedProgress)
                    }
                }
                .frame(height: 4)
                .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.crossfade),
                           value: clampedProgress)
                Text("\(percent)%")
                    .font(Theme.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: percentWidth, alignment: .trailing)
            }
        }
        // One element, label then value, so VoiceOver reads the file once
        // and only the percent as it changes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Adding \(fileName)")
        .accessibilityValue("\(percent) percent")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($focused)
        .accessibilityIdentifier("import.progress")
        .onAppear { focused = true }
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("Cancel")
                .font(Theme.font(.callout).weight(.medium))
                .foregroundStyle(Theme.accentStrong)
                .padding(.horizontal, Theme.Space.xs)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("import.cancel")
    }

    private var clampedProgress: Double { min(max(progress, 0), 1) }
    private var percent: Int { Int((clampedProgress * 100).rounded()) }
}

extension URL {
    /// The name Finder and Files show: a ":" in the name on disk reads as
    /// "/" there, so "AC/DC Live.txt" is never "AC:DC Live.txt" (L010).
    /// The name on disk when the file can't be asked (gone, out of scope).
    var displayName: String {
        (try? resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? lastPathComponent
    }

    /// `displayName` without its extension. The shown name may already
    /// hide it (Finder's Hide extension), so only a matching one is cut:
    /// "Mr. Smith" stays whole.
    var displayStem: String {
        let name = displayName
        let ext = pathExtension
        guard !ext.isEmpty, name.lowercased().hasSuffix("." + ext.lowercased()),
              name.count > ext.count + 1 else { return name }
        return String(name.dropLast(ext.count + 1))
    }
}
