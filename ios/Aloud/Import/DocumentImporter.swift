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

/// R10: the one add path. Files picks, Open-in files and Bookshelf classics
/// all land here; a finished add hands the document to `onAdded`, which
/// AppModel points at `router.open` so it opens playing (R4).
///
/// The open rule. An add opens its book only if, when it ends, nothing is
/// queued behind it and the user has not navigated since it began (no push,
/// pop or swap of the stack, no root picker or alert opened). Otherwise the
/// book is added quietly and announced, and the user stays where they are.
/// Opening anyway would push a reader that starts speaking under the next
/// import's overlay or a modal, or tear down a book the user chose while a
/// slow classic was still being added. So a batch of queued files opens
/// only the last one.
@MainActor
final class DocumentImporter: ObservableObject {

    enum Phase: Equatable {
        case idle
        case importing(fileName: String, progress: Double)
        case failed(ImportFailure)
    }

    @Published private(set) var phase: Phase = .idle
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

    var onAdded: ((LibraryDocument) -> Void)?
    /// AppModel points it at the router. Without one (tests that don't care)
    /// the user never moves.
    weak var navigation: (any NavigationTracking)?

    private let library: any LibraryAdding
    private let announce: (String) -> Void
    /// Files that arrived (Open-in) while another add was running or a
    /// failure was still on screen; each is imported in turn.
    private var queued: [URL] = []
    /// Bumped by every import start and by cancel(). A task whose token is
    /// stale finished after the user moved on, so its result is dropped.
    private var token: UInt64 = 0
    private var current: Task<Void, Never>?

    init(library: any LibraryAdding,
         announce: @escaping (String) -> Void = DocumentImporter.postAnnouncement) {
        self.library = library
        self.announce = announce
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
        guard !isBusy else {
            queued.append(url)
            return
        }
        token &+= 1
        let mine = token
        let startedAt = navigation?.navigationGeneration
        // Snapshot before the add, so a duplicate (the store returns the
        // record already on the shelf) is announced as such.
        let before = Set(library.documents.map(\.id))
        let isPDF = url.pathExtension.lowercased() == "pdf"
        phase = .importing(fileName: url.lastPathComponent, progress: 0)

        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.token == mine,
                      case .importing(let name, _) = self.phase else { return }
                self.phase = .importing(fileName: name, progress: value)
            }
        }

        current = Task {
            do {
                let document = isPDF
                    ? try await library.importPDF(from: url, progress: progress)
                    : try await library.importText(title: Self.title(from: url), author: nil,
                                                   from: url, progress: progress)
                if token == mine {
                    phase = .idle
                    announce(Self.completion(for: document, before: before))
                    if mayOpen(startedAt: startedAt) { onAdded?(document) }
                }
            } catch is CancellationError {
                // cancel() already reset the phase and moved the token on.
            } catch {
                if token == mine {
                    phase = .failed(ImportFailure(error, isPDF: isPDF))
                }
            }
            // Inbox cleanup runs on success, failure and cancel alike.
            Self.removeInboxCopy(url)
            if token == mine { startNextQueued() }
        }
    }

    /// The overlay's Cancel: back to the shelf at once, the queue dropped
    /// with it. A late result is ignored by token, so the book never opens.
    func cancel() {
        guard isImporting else { return }
        token &+= 1
        current?.cancel()
        current = nil
        queued.forEach(Self.removeInboxCopy)
        queued = []
        phase = .idle
    }

    /// The user has seen the failure: clear it and resume any files that
    /// queued up behind it.
    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = .idle
        startNextQueued()
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
        Task {
            defer {
                addingClassicID = nil
                startNextQueued()
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
        importFile(at: queued.removeFirst())
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

    static func isInboxCopy(_ url: URL) -> Bool {
        guard url.isFileURL,
              let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return false }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
            .standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(inbox + "/")
    }

    /// "moby-dick_ch1.txt" → "Moby Dick Ch1"
    private static func title(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return url.lastPathComponent }
        return base == base.lowercased() ? base.localizedCapitalized : base
    }
}

/// Progress card shown over the Library while extraction runs: a modal
/// scrim in shadow ink under a raised surface card. The scrim swallows
/// touches and the overlay is modal for VoiceOver, so the shelf beneath
/// can't be reached until the add ends or is cancelled.
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
                        Capsule().fill(Theme.line)
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
