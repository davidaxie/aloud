import SwiftUI
import UIKit

/// The bundled classics (R9), pushed full height on the Library's stack.
/// Rows are the action: one tap adds the book if needed, opens it and plays
/// it. Three shelves by listening length; the pinned search spans all three.
struct BookshelfView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var importer: DocumentImporter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    /// nil shows the shelves. Searched once per query change, never per body run.
    @State private var results: [BookshelfBook]?
    /// The classics already in the library. The store is read through the
    /// model rather than observed: it republishes on every progress save,
    /// even with this screen under the reader, and only these sets matter.
    @State private var libraryIDs: Set<Int> = []
    /// The classics whose library copy is finished: those rows open paused,
    /// so their hint promises nothing, as a finished grid card's doesn't.
    @State private var finishedIDs: Set<Int> = []
    /// The classic the player is voicing, if any. One value followed, not
    /// the controller, which republishes many times a second.
    @State private var playingClassicID: Int?
    /// Bumped by a Search key that opened nothing: the keyboard goes, the
    /// query and its results stay.
    @State private var keyboardDismissals = 0
    /// What the lazy list has laid out, and the shelf-map jump under way
    /// (`ShelfWalk`). A reference, never observed: rows appearing as the
    /// list scrolls redraw nothing.
    @State private var walk = ShelfWalk()

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var noResultsMessage: String {
        "No classics match \u{201C}\(trimmedQuery)\u{201D}"
    }

    /// The search field's placeholder, for the prompt and the UIKit field.
    static let searchPrompt = "Title or author"

    /// R2-32: the placeholder's ink, AA on the fill the system field draws
    /// (tertiarySystemFill over bg) in both modes: textMuted, since
    /// textFaint measures 4.4:1 on the light fill and 4.0:1 on the dark
    /// one. The token carries its Increase Contrast value, resolved in the
    /// field's own traits.
    static let searchPromptInk = UIColor { traits in
        UIColor(Theme.textMuted).resolvedColor(with: traits)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 0).id("top")
                    content(proxy)
                }
            }
            .accessibilityIdentifier("bookshelf.list")
            // Each keystroke reshapes the list; start it from the top, and
            // end a jump still walking to a shelf the search took away.
            .onChange(of: query) {
                walk.cancel()
                proxy.scrollTo("top", anchor: .top)
            }
            // The loaded book plays or pauses from anywhere on the list,
            // as on the Library (R12b).
            .accessibilityAction(.magicTap) { magicTap() }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.immediately)
        .modifier(ShelfScrollEdge(showsScrollRule: true))
        // R2-32: the placeholder in searchPromptInk, warm and AA on the
        // field in both modes, never the system's neutral grey (3.47:1).
        // The prompt's own style is asked for, and the UIKit field
        // underneath is set as well, since the navigation bar's search may
        // drop SwiftUI's style.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(Self.searchPrompt).foregroundStyle(Color(uiColor: Self.searchPromptInk)))
        .background {
            SearchPlaceholderTint(prompt: Self.searchPrompt)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .modifier(SearchKeyboardDismissal(requests: keyboardDismissals))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // The keyboard's Search key plays a search's only book, as a tap on
        // its row would: the same haptic and busy guard. With several books
        // found, or none, it only lowers the keyboard, so the list it hid can
        // be read and the query stays to refine.
        .onSubmit(of: .search) { openTopResult() }
        .onChange(of: query, initial: true) {
            let found = model.bookshelfIndex.search(query)
            // Once, as the list empties; typing on into nothing stays quiet.
            // Through the one announcement path, so a muted launch only logs it.
            if found?.isEmpty == true, results?.isEmpty != true {
                PlaybackController.postAnnouncement(noResultsMessage, muted: model.playback.isOutputMuted)
            }
            results = found
        }
        .onReceive(model.documentStore.$documents) { documents in
            let ids = Set(documents.compactMap(\.gutenbergID))
            if ids != libraryIDs { libraryIDs = ids }
            let finished = BookshelfCatalog.finishedClassicIDs(in: documents)
            if finished != finishedIDs { finishedIDs = finished }
        }
        .onReceive(BookshelfCatalog.playingClassicIDs(of: model.playback)) { id in
            if id != playingClassicID { playingClassicID = id }
        }
        .navigationTitle("Classics")
        .navigationBarTitleDisplayMode(.inline)
        // The bar's system content (back chevron, title rendering) follows
        // the app's scheme, not the phone's: under an in-app Dark override
        // on a Light phone it otherwise drew dark-on-dark.
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Classics")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    // The bar caps text scaling; at accessibility sizes a
                    // long press shows the title large instead.
                    .accessibilityShowsLargeContentViewer()
            }
        }
    }

    @ViewBuilder
    private func content(_ proxy: ScrollViewProxy) -> some View {
        if let results {
            if results.isEmpty {
                Text(noResultsMessage)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Space.screenGutter)
                    .padding(.top, Theme.Space.xxl)
                    .accessibilityIdentifier("bookshelf.noResults")
            } else {
                ForEach(results) { row($0) }
            }
        } else {
            let shelves = model.bookshelfIndex.shelves(rate: model.globalRate)
            // R3-05: the shelf map, unpinned, above the first heading.
            shelfMap(proxy)
            // A branch per shelf, never a ForEach over the shelves, whose
            // every element was a mark and a whole section: a number of
            // views the lazy stack can't read off its data. Here the only
            // ForEach is each shelf's books, one row per book, so every row
            // the walk scrolls to (`jump(to:_:)`) is found by its index.
            shelf(.underAnHour, in: shelves)
            shelf(.anEvening, in: shelves)
            shelf(.longReads, in: shelves)
        }
    }

    /// One shelf, when the speed leaves it any books: its mark, then its
    /// section under a pinned heading. Its rows tell the walk when the lazy
    /// stack lays them out and lets them go (`jump(to:_:)`).
    @ViewBuilder
    private func shelf(_ section: BookshelfSection, in shelves: [BookshelfShelf]) -> some View {
        if let shelf = shelves.first(where: { $0.section == section }) {
            shelfAnchor(section)
            Section {
                ForEach(shelf.books) { book in
                    row(book)
                        .onAppear { walk.rowAppeared(book.id) }
                        .onDisappear { walk.rowDisappeared(book.id) }
                }
            } header: {
                header(section)
            }
        }
    }

    private func header(_ section: BookshelfSection) -> some View {
        Text(section.title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            // Capitals, as the shelf's other eyebrows are drawn; VoiceOver
            // and Voice Control keep the title as written.
            .textCase(.uppercase)
            .accessibilityLabel(Text(section.title))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenGutter)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xs)
            // Pinned: rows scroll under it.
            .background(Theme.bg)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("bookshelf.section.\(section.rawValue)")
    }

    /// The shelf map's target (`jump(to:_:)`): a one-point mark just above
    /// the shelf's heading, never the heading itself. A pinned heading sits
    /// at the top anywhere in its shelf, so a scroll to it reads as already
    /// there wherever it lands. Scrolled to the top, the mark brings the
    /// heading to the top at its own place, the shelf's first book under
    /// it. A point tall, not zero, so it has an area for the lazy stack to
    /// find in what it shows and lay out, and it says so to the walk.
    private func shelfAnchor(_ section: BookshelfSection) -> some View {
        Color.clear
            .frame(height: 1)
            .accessibilityHidden(true)
            .id(section.rawValue)
            .onAppear { walk.markAppeared(section) }
            .onDisappear { walk.markDisappeared(section) }
    }

    // MARK: Shelf map

    /// R3-05: one button per shelf, its title and a quiet count, so the
    /// longer shelves far down the list are one tap away and their being
    /// there is said at the top. Side by side while they fit, full-width
    /// rows at the large sizes (`ShelfMapLayout`). No selected state: the
    /// pinned heading already says where the list is. No identifier on the
    /// row: a stack isn't an accessibility element, so one set here would
    /// land on the buttons and could replace their `bookshelf.jump.<shelf>`
    /// ids.
    private func shelfMap(_ proxy: ScrollViewProxy) -> some View {
        let jumps = ShelfJump.jumps(in: model.bookshelfIndex, rate: model.globalRate)
        return ShelfMapLayout(spacing: Theme.Space.xs) {
            ForEach(jumps) { jumpButton($0, proxy) }
        }
        .padding(.horizontal, Theme.Space.screenGutter - Theme.Space.sm)
        .padding(.top, Theme.Space.sm)
    }

    private func jumpButton(_ jump: ShelfJump, _ proxy: ScrollViewProxy) -> some View {
        Button {
            self.jump(to: jump.section, proxy)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text(jump.title)
                    .font(Theme.font(.callout).weight(.medium))
                    .foregroundStyle(Theme.accentStrong)
                Text(jump.countText)
                    .font(Theme.font(.callout))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
            }
            // No line limit: the side-by-side map is only chosen while its
            // labels fit whole, and on the full-width rows a title wraps at
            // the largest sizes rather than being cut. A one-line limit on
            // text drawn at its own width is what the clipping audit
            // reported here; the count never breaks.
            .multilineTextAlignment(.leading)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xxs)
            // Its own width side by side, the full row when stacked: the
            // layout proposes one or the other.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShelfRowButtonStyle())
        .accessibilityLabel(jump.accessibilityLabel)
        .accessibilityHint(ShelfJump.hint)
        .accessibilityIdentifier(jump.identifier)
    }

    /// To the shelf's heading, by the mark above it (`shelfAnchor(_:)`).
    /// Silent, as a Contents pick is (TransportHaptics: picks never answer
    /// with one).
    ///
    /// A scroll straight to a far mark the lazy stack hasn't laid out goes
    /// where the stack estimates it is: from the top of Classics, some 160
    /// books into the longest shelf, where a repeated scroll stayed. So the
    /// jump walks there first (`ShelfWalk`): each step scrolls a row the
    /// stack has laid out, unanimated, which lays out the screen past it,
    /// and the next step runs a turn of the run loop later, once those rows
    /// are laid out and have appeared; never on a timer. Once the mark is
    /// laid out, it lands.
    private func jump(to section: BookshelfSection, _ proxy: ScrollViewProxy) {
        walkStep(walk.begin(toward: section), proxy)
    }

    private func walkStep(_ token: Int, _ proxy: ScrollViewProxy) {
        guard let step = walk.next(token, through: model.bookshelfIndex.shelves(rate: model.globalRate)) else {
            return
        }
        switch step {
        case .land(let section):
            land(on: section, proxy)
        case .hop(let bookID, let edge):
            proxy.scrollTo(bookID, anchor: edge == .top ? .top : .bottom)
            DispatchQueue.main.async { walkStep(token, proxy) }
        case .wait:
            DispatchQueue.main.async { walkStep(token, proxy) }
        }
    }

    /// The mark, laid out now, to the top: animated from within a screen
    /// unless Reduce Motion is on, then settled, as rows near it may be
    /// measured afresh, by a scroll when the animation completes (at once
    /// without one) and another on the next turn of the run loop.
    private func land(on section: BookshelfSection, _ proxy: ScrollViewProxy) {
        let id = section.rawValue
        let settle = {
            proxy.scrollTo(id, anchor: .top)
            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        }
        if reduceMotion {
            settle()
        } else {
            withAnimation(.smooth, completionCriteria: .logicallyComplete) {
                proxy.scrollTo(id, anchor: .top)
            } completion: {
                settle()
            }
        }
    }

    private func row(_ book: BookshelfBook) -> some View {
        ClassicsRowButton(book: book, rate: model.globalRate,
                          inLibrary: libraryIDs.contains(book.id),
                          adding: importer.addingClassicID == book.id,
                          finished: finishedIDs.contains(book.id),
                          stacked: dynamicTypeSize.isAccessibilitySize,
                          playing: playingClassicID == book.id) { listen(to: book) }
    }

    // MARK: Row copy

    /// A book's length at the app-wide speed, as the featured card and
    /// every Library card show it (R7). The shelves group by the same
    /// measure (`BookshelfIndex.shelves(rate:)`), so a heading never
    /// disagrees with the times under it (L019).
    nonisolated static func rowMinutes(of book: BookshelfBook, rate: Double) -> Int {
        book.listeningMinutes(rate: rate)
    }

    /// The stacked row's second line at accessibility sizes: the author and
    /// the length at the app-wide speed, as the featured card shows them.
    nonisolated static func rowSubtitle(for book: BookshelfBook, rate: Double) -> String {
        "\(book.author) · \(ListeningEstimate.phrase(minutes: rowMinutes(of: book, rate: rate)))"
    }

    /// The side-by-side row's line under the title: the author alone, with
    /// the length in the trailing column.
    nonisolated static func rowByline(for book: BookshelfBook) -> String {
        "by \(book.author)"
    }

    /// The side-by-side row's trailing column, never empty, so the lengths
    /// line up down the list: the add in progress, else the copy the player
    /// is voicing, else a finished copy, else the library copy, else the
    /// length at the app-wide speed.
    nonisolated static func rowStatus(for book: BookshelfBook, rate: Double,
                                      inLibrary: Bool, adding: Bool,
                                      finished: Bool = false, playing: Bool = false) -> String {
        if adding { return "Adding\u{2026}" }
        if playing { return "Playing" }
        if finished { return "Finished" }
        if inLibrary { return "In library" }
        return ListeningEstimate.phrase(minutes: rowMinutes(of: book, rate: rate))
    }

    /// The row's spoken value: the trailing column's status, in the same
    /// order, and nothing for a book not yet added (its length is already
    /// in the label).
    nonisolated static func rowValue(inLibrary: Bool, adding: Bool,
                                     finished: Bool = false, playing: Bool = false) -> String {
        if adding { return "Adding" }
        if playing { return "Playing" }
        if finished { return "Finished" }
        if inLibrary { return "In library" }
        return ""
    }

    /// The trailing column's width at the default text size; it scales with
    /// the caption style. It fits the widest status, a three-digit hour count
    /// with minutes in tabular digits (the longest classic runs past 100
    /// hours at 1×, and past 50 hours a half-speed row reaches three digits),
    /// in bold as well, since Bold Text draws the medium caption heavier.
    nonisolated static let statusColumnWidth: CGFloat = 98

    /// What the row does, as the grid cards say it. A finished library copy
    /// opens paused at its end, so it promises nothing; the copy already
    /// playing goes on as it is, so the row only brings up its reader.
    nonisolated static func rowHint(finished: Bool, playing: Bool = false) -> String {
        if playing { return "Opens the reader" }
        return finished ? "" : "Opens and starts reading aloud"
    }

    /// "The Cask of Amontillado, by Edgar Allan Poe, about 7 minutes" at 2×.
    nonisolated static func rowLabel(for book: BookshelfBook, rate: Double) -> String {
        "\(book.title), by \(book.author), "
            + ListeningEstimate.aboutPhrase(minutes: rowMinutes(of: book, rate: rate))
    }

    /// The only tap handler. The importer adds the book if needed (or finds
    /// the copy already linked to it, renamed or not), then onAdded opens it
    /// on top of this screen and the reader autoplays. The soft haptic (R20)
    /// answers only a tap that will start a voice: the importer ignores taps
    /// while it is busy, and the copy already on the shelf follows the same
    /// rule as a grid card.
    private func listen(to book: BookshelfBook) {
        guard importer.addingClassicID == nil, importer.phase == .idle else { return }
        let playback = model.playback
        let startsPlaying = model.documentStore.document(forGutenbergID: book.gutenbergID)
            .map { playback.opensPlaying($0) } ?? !playback.isAutoplaySuppressed
        if startsPlaying { TransportHaptics.emit(.play) }
        importer.addClassic(book)
    }

    /// The keyboard's Search key: a search's only book, through the tap's
    /// path. Several books, or none, keep the query and the list, and only
    /// lower the keyboard.
    private func openTopResult() {
        guard let results, results.count == 1, let only = results.first else {
            keyboardDismissals += 1
            return
        }
        listen(to: only)
    }

    /// VoiceOver's two-finger double tap: the loaded book plays or pauses,
    /// with the Library's haptic. Nothing when no book is loaded.
    private func magicTap() {
        let playback = model.playback
        guard playback.document != nil else { return }
        TransportHaptics.emitToggle(isActive: playback.isActive)
        playback.togglePlayPause()
    }
}

/// Lowers the search field's keyboard each time `requests` changes, keeping
/// its text: through the search field's focus where SwiftUI offers it, else
/// by resigning the first responder.
private struct SearchKeyboardDismissal: ViewModifier {
    let requests: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .searchFocused($focused)
                .onChange(of: requests) { focused = false }
        } else {
            content
                .onChange(of: requests) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
        }
    }
}

/// R2-32: sets the navigation bar search field's placeholder in
/// `BookshelfView.searchPromptInk` (textFaint in light, textMuted in dark),
/// resolved in the field's own traits, where the system
/// draws a neutral grey under the AA line on the warm field. Zero size and
/// hidden from assistive tech: it finds the search controller on the
/// hosting navigation item and sets the UIKit field's attributed
/// placeholder, again when it appears, on each SwiftUI update and when the
/// appearance or contrast changes. The field stays the system's own search
/// field, so the Search key, its submit and its haptic are untouched.
private struct SearchPlaceholderTint: UIViewControllerRepresentable {
    let prompt: String

    func makeUIViewController(context: Context) -> Controller {
        Controller(prompt: prompt)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.prompt = prompt
        controller.apply()
    }

    final class Controller: UIViewController {
        var prompt: String

        init(prompt: String) {
            self.prompt = prompt
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
                (controller: Controller, _: UITraitCollection) in
                controller.apply()
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func apply() {
            guard let field = searchController?.searchBar.searchTextField else { return }
            let ink = BookshelfView.searchPromptInk.resolvedColor(with: field.traitCollection)
            let placeholder = NSAttributedString(string: prompt, attributes: [.foregroundColor: ink])
            if field.attributedPlaceholder != placeholder {
                field.attributedPlaceholder = placeholder
            }
        }

        /// The search controller of the navigation item this screen hosts:
        /// on this controller's ancestors, else the stack's top item.
        private var searchController: UISearchController? {
            var next: UIViewController? = self
            while let controller = next {
                if let search = controller.navigationItem.searchController { return search }
                next = controller.parent
            }
            return navigationController?.topViewController?.navigationItem.searchController
        }
    }
}

// MARK: - Row button

/// One VoiceOver element: a Button already merges its label's text. Plain
/// values in, so a hosted test can read what VoiceOver hears without the
/// app's models.
struct ClassicsRowButton: View {
    let book: BookshelfBook
    /// The app-wide speed the length is shown at.
    let rate: Double
    let inLibrary: Bool
    let adding: Bool
    /// The library copy is finished, so the row opens it paused.
    let finished: Bool
    let stacked: Bool
    /// The player is voicing the library copy, so the row only opens it.
    var playing: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BookshelfRow(book: book, rate: rate, inLibrary: inLibrary, adding: adding,
                         finished: finished, playing: playing, stacked: stacked)
        }
        .buttonStyle(ShelfRowButtonStyle())
        .accessibilityLabel(BookshelfView.rowLabel(for: book, rate: rate))
        .accessibilityValue(BookshelfView.rowValue(inLibrary: inLibrary, adding: adding,
                                                   finished: finished, playing: playing))
        .accessibilityHint(BookshelfView.rowHint(finished: finished, playing: playing))
        .accessibilityIdentifier("bookshelf.row.\(book.gutenbergID)")
    }
}

// MARK: - Row

/// Text only: the title over the author, and a trailing column that always
/// holds one status (the length, the library copy, finished, playing, or the
/// add in progress), so the lengths line up down the list. At accessibility
/// sizes, where a trailing column would squeeze the title, the row stacks:
/// the author and length share a line, and any status drops under them.
private struct BookshelfRow: View {
    let book: BookshelfBook
    /// The app-wide speed the length is shown at.
    let rate: Double
    let inLibrary: Bool
    let adding: Bool
    let finished: Bool
    let playing: Bool
    let stacked: Bool

    @ScaledMetric(relativeTo: .caption) private var statusWidth = BookshelfView.statusColumnWidth

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    title
                    detail(BookshelfView.rowSubtitle(for: book, rate: rate))
                    stackedStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        title
                        detail(BookshelfView.rowByline(for: book))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusLine
                        .font(Theme.font(.caption))
                        .lineLimit(1)
                        .frame(width: statusWidth, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, Theme.Space.screenGutter)
        .padding(.vertical, Theme.Space.sm)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Stroke.hairlineColor)
                .frame(height: Theme.Stroke.hairlineWidth)
                .padding(.leading, Theme.Space.screenGutter)
                .accessibilityHidden(true)
        }
    }

    private var title: some View {
        Text(book.title)
            .font(Theme.font(.headline))
            .foregroundStyle(Theme.text)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(.footnote))
            .foregroundStyle(Theme.textMuted)
    }

    private var status: String {
        BookshelfView.rowStatus(for: book, rate: rate, inLibrary: inLibrary, adding: adding,
                                finished: finished, playing: playing)
    }

    /// The status in words, muted; the copy the player is voicing reads in
    /// the accent text colour behind a speaker glyph, which VoiceOver skips
    /// (the row's value already says it).
    @ViewBuilder
    private var statusLine: some View {
        if playing && !adding {
            HStack(spacing: Theme.Space.xxs) {
                Image(systemName: "speaker.wave.2.fill")
                    .accessibilityHidden(true)
                Text(status)
            }
            .foregroundStyle(Theme.accentStrong)
        } else {
            Text(status)
                .foregroundStyle(Theme.textMuted)
        }
    }

    /// Words, not a spinner: it holds still under Reduce Motion and says
    /// what the row's spoken value says. The length is already on the line
    /// above it, so only a status shows here.
    @ViewBuilder
    private var stackedStatus: some View {
        if adding || playing || finished || inLibrary {
            statusLine
                .font(Theme.font(.subhead))
                .fixedSize()
        }
    }
}

/// Rows press to surface2; no scale, so the column of text stays still.
private struct ShelfRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface2 : Theme.bg)
            .animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
    }
}

/// The shelf map's buttons side by side while all of them fit whole on one
/// line, else one per row across the full width. One set of buttons either
/// way: a ViewThatFits kept its unchosen stack in the accessibility tree,
/// where the audit read its labels as clipped and a tap could land on the
/// copy that isn't drawn.
private struct ShelfMapLayout: Layout {
    var spacing: CGFloat

    private func ideals(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    private func rowWidth(_ sizes: [CGSize]) -> CGFloat {
        sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = ideals(subviews)
        let row = rowWidth(sizes)
        if row <= (proposal.width ?? .infinity) {
            return CGSize(width: row, height: sizes.map(\.height).max() ?? 0)
        }
        let width = proposal.width ?? (sizes.map(\.width).max() ?? 0)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = ideals(subviews)
        if rowWidth(sizes) <= bounds.width {
            var x = bounds.minX
            for (subview, size) in zip(subviews, sizes) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y),
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }
}
