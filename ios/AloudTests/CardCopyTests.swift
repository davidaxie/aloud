import CoreText
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Aloud

/// R25, with R24's Finished card: a shelf card reads exactly one of three
/// forms — "4 hr 52 min" before the first listen, "1 hr 12 min left" in
/// progress, or "Finished" — and no line when its length is unknown. Never
/// a percent, never a page count, and VoiceOver hears the time spelled out.
///
/// Pure copy rules, plus ImageRenderer snapshots of the three states (a
/// renderer never runs the cover's .task). Nothing plays.
final class CardCopyTests: XCTestCase {

    private func doc(title: String = "Title", author: String? = "Author",
                     progress: Double = 0, wordCount: Int, kind: DocKind = .text) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: kind == .pdf ? "doc.pdf" : "doc.txt",
                        addedAt: Date(timeIntervalSince1970: 0),
                        lastOpenedAt: progress > 0 ? Date(timeIntervalSince1970: 1_000_000) : nil,
                        pageCount: 12, sentenceCount: 100, progressSentence: Int(progress * 99),
                        progressFraction: progress, contentHash: "hash", kind: kind,
                        author: author, wordCount: wordCount)
    }

    // MARK: - The three forms

    /// A Classics row shows the book's length at the app-wide speed, like
    /// the featured card and the book's Library card once added. It read
    /// 14 min at 2× beside a 7 min featured card (H016).
    func testClassicsRowsReadTheirLengthAtTheAppWideSpeed() {
        let cask = BookshelfBook(gutenbergID: 1063, title: "The Cask of Amontillado",
                                 author: "Edgar Allan Poe", year: nil,
                                 file: "1063-the-cask-of-amontillado.txt", words: 2317)
        XCTAssertEqual(BookshelfView.rowSubtitle(for: cask, rate: 1), "Edgar Allan Poe · 14 min")
        XCTAssertEqual(BookshelfView.rowSubtitle(for: cask, rate: 2), "Edgar Allan Poe · 7 min")
        XCTAssertEqual(BookshelfView.rowLabel(for: cask, rate: 2),
                       "The Cask of Amontillado, by Edgar Allan Poe, about 7 minutes")
        for rate in [0.5, 1, 1.5, 2, 3] {
            XCTAssertEqual(BookshelfView.rowSubtitle(for: cask, rate: rate),
                           FeaturedClassic.subtitle(for: cask, rate: rate), "the featured card agrees at \(rate)×")
            // L019: and its shelf is chosen by the same time.
            XCTAssertEqual(BookshelfView.rowMinutes(of: cask, rate: rate), cask.listeningMinutes(rate: rate))
        }
        let added = doc(title: cask.title, author: cask.author, wordCount: cask.words)
        XCTAssertEqual(BookshelfView.rowSubtitle(for: cask, rate: 2),
                       "\(cask.author) · \(added.listeningSubtitle(rate: 2))", "the Library card agrees")
    }

    /// P052: below the accessibility sizes a Classics row reads the title
    /// over the author, and its trailing column always holds one caption, so
    /// the lengths line up: the length at the app-wide speed, else the
    /// library copy, else the add in progress, as on the Mac.
    func testClassicsRowsTrailOneStatus() {
        let cask = BookshelfBook(gutenbergID: 1063, title: "The Cask of Amontillado",
                                 author: "Edgar Allan Poe", year: nil,
                                 file: "1063-the-cask-of-amontillado.txt", words: 2317)
        XCTAssertEqual(BookshelfView.rowByline(for: cask), "by Edgar Allan Poe")
        XCTAssertEqual(BookshelfView.rowStatus(for: cask, rate: 1, inLibrary: false, adding: false), "14 min")
        XCTAssertEqual(BookshelfView.rowStatus(for: cask, rate: 2, inLibrary: false, adding: false), "7 min")
        XCTAssertEqual(BookshelfView.rowStatus(for: cask, rate: 2, inLibrary: true, adding: false), "In library")
        XCTAssertEqual(BookshelfView.rowStatus(for: cask, rate: 2, inLibrary: true, adding: true), "Adding\u{2026}")
        XCTAssertEqual(BookshelfView.rowStatus(for: cask, rate: 2, inLibrary: false, adding: true), "Adding\u{2026}")
        for rate in [0.5, 1, 1.5, 2, 3] {
            // The column's length is the stacked line's, and the featured card's.
            XCTAssertEqual("\(cask.author) · \(BookshelfView.rowStatus(for: cask, rate: rate, inLibrary: false, adding: false))",
                           BookshelfView.rowSubtitle(for: cask, rate: rate), "at \(rate)×")
        }
        // The spoken label is unchanged by the new layout.
        XCTAssertEqual(BookshelfView.rowLabel(for: cask, rate: 1),
                       "The Cask of Amontillado, by Edgar Allan Poe, about 14 minutes")
    }

    /// P052: the trailing column fits its widest status at every text size
    /// below the accessibility sizes (where the row stacks instead), so no
    /// length is ever cut short. With tabular digits every three-digit hour
    /// count with minutes is equally wide; the longest classic runs past a
    /// hundred hours at 1×. B7-1: it fits in bold too, for Bold Text.
    func testTheClassicsStatusColumnFitsItsWidestStatus() {
        let longest = BookshelfBook(gutenbergID: 1, title: "Long", author: "Author", year: nil,
                                    file: "long.txt", words: 59_999 * Int(LibraryDocument.spokenWordsPerMinute))
        let statuses = [
            BookshelfView.rowStatus(for: longest, rate: 1, inLibrary: false, adding: false),
            BookshelfView.rowStatus(for: longest, rate: 1, inLibrary: true, adding: false),
            BookshelfView.rowStatus(for: longest, rate: 1, inLibrary: false, adding: true),
        ]
        XCTAssertEqual(statuses[0].filter(\.isNumber).count, 5, "a three-digit hour count: \(statuses[0])")
        let sizes: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large,
                                              .extraLarge, .extraExtraLarge, .extraExtraExtraLarge]
        for size in sizes {
            let traits = UITraitCollection(preferredContentSizeCategory: size)
            let points = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption1,
                                                                  compatibleWith: traits).pointSize
            let column = UIFontMetrics(forTextStyle: .caption1)
                .scaledValue(for: BookshelfView.statusColumnWidth, compatibleWith: traits)
            // Theme's caption: medium, tabular digits; and bold, as Bold Text
            // draws it (the column and the text scale together, so a status
            // that overflows at one size overflows at all of them).
            for weight: UIFont.Weight in [.medium, .bold] {
                let plain = UIFont.systemFont(ofSize: points, weight: weight)
                let tabular = plain.fontDescriptor.addingAttributes([.featureSettings: [[
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                ]]])
                let font = UIFont(descriptor: tabular, size: points)
                for status in statuses {
                    let width = (status as NSString).size(withAttributes: [.font: font]).width
                    XCTAssertLessThanOrEqual(width.rounded(.up), column,
                                             "'\(status)' at \(size.rawValue), weight \(weight.rawValue), "
                                             + "needs \(width) pt of \(column)")
                }
            }
        }
    }

    /// P053: a row's hint drops for a finished library copy, and the copy
    /// weighed is the one the row opens: the first in store order.
    func testFinishedClassicsAreTheCopiesTheRowsOpen() {
        func copy(_ id: Int?, progress: Double) -> LibraryDocument {
            LibraryDocument(id: UUID(), title: "Title", fileName: "doc.txt", addedAt: Date(timeIntervalSince1970: 0),
                            pageCount: 1, sentenceCount: 100, progressSentence: Int(progress * 99),
                            progressFraction: progress, contentHash: UUID().uuidString, kind: .text,
                            wordCount: 2_317, gutenbergID: id)
        }
        let documents = [copy(1063, progress: 1), copy(64317, progress: 0.4), copy(64317, progress: 1),
                         copy(nil, progress: 1), copy(1342, progress: 0)]
        XCTAssertEqual(BookshelfView.finishedClassicIDs(in: documents), [1063])
        XCTAssertEqual(DocumentStore.existingClassic(gutenbergID: 64317, in: documents)?.isFinished, false,
                       "the row opens the unfinished copy, so it still promises reading")
        XCTAssertEqual(BookshelfView.finishedClassicIDs(in: []), [])
        XCTAssertEqual(BookshelfView.rowHint(finished: true), "")
        XCTAssertEqual(BookshelfView.rowHint(finished: false), "Opens and starts reading aloud")
    }

    /// The Great Gatsby, never started: 48,208 words at 1× is 292 minutes.
    func testAnUnstartedBookReadsItsLength() {
        let gatsby = doc(wordCount: 48_208)
        XCTAssertEqual(gatsby.listeningSubtitle(rate: 1), "4 hr 52 min")
        XCTAssertEqual(gatsby.spokenListeningSubtitle(rate: 1), "4 hours 52 minutes")
        XCTAssertEqual(gatsby.shelfStatus(rate: 1), .length(minutes: 292))
    }

    /// 20,842 words is 126.3 minutes at 1×; 57% of it is 72.
    func testABookInProgressReadsItsTimeLeft() {
        let book = doc(progress: 0.43, wordCount: 20_842)
        XCTAssertEqual(book.listeningSubtitle(rate: 1), "1 hr 12 min left")
        XCTAssertEqual(book.spokenListeningSubtitle(rate: 1), "1 hour 12 minutes left")
        XCTAssertEqual(book.shelfStatus(rate: 1), .left(minutes: 72))
    }

    /// Finished (`isFinished`): a stored 1.0 at any length; from the 0.99
    /// threshold with a minute or less left at 1× (9,900 words is an hour,
    /// so 0.99 leaves 36 s), or with no length to weigh. Whatever the speed:
    /// at 0.5× those 36 s would be 72, and the card still reads Finished.
    func testAFinishedBookReadsFinished() {
        let cases: [(progress: Double, words: Int)] = [(1.0, 48_208), (1.0, 0), (0.99, 9_900), (0.99, 0)]
        for (progress, words) in cases {
            for rate in [0.5, 1, 3] {
                let book = doc(progress: progress, wordCount: words)
                let context = "\(progress), \(words) words, \(rate)×"
                XCTAssertEqual(book.listeningSubtitle(rate: rate), "Finished", context)
                XCTAssertEqual(book.spokenListeningSubtitle(rate: rate), "finished", context)
                XCTAssertEqual(book.shelfStatus(rate: rate), .finished, context)
            }
        }
    }

    /// Past 0.99 with more than a minute left is still in progress: The
    /// Great Gatsby at 0.99 has 2.9 minutes to go, and the card says so,
    /// at the listener's own speed.
    func testALongBookPastTheThresholdReadsItsTimeLeft() {
        let gatsby = doc(progress: 0.99, wordCount: 48_208)
        XCTAssertFalse(gatsby.isFinished)
        XCTAssertEqual(gatsby.listeningSubtitle(rate: 1), "3 min left")
        XCTAssertEqual(gatsby.spokenListeningSubtitle(rate: 1), "3 minutes left")
        XCTAssertEqual(gatsby.listeningSubtitle(rate: 0.5), "6 min left")
        XCTAssertEqual(gatsby.listeningSubtitle(rate: 3), "1 min left")
        XCTAssertEqual(gatsby.shelfStatus(rate: 1), .left(minutes: 3))
    }

    /// No word count, no length to quote: the card draws no line at all.
    func testAnUnknownLengthReadsNothing() {
        for progress in [0, 0.43] {
            let book = doc(progress: progress, wordCount: 0)
            XCTAssertEqual(book.listeningSubtitle(rate: 1), "")
            XCTAssertEqual(book.spokenListeningSubtitle(rate: 1), "")
            XCTAssertEqual(book.shelfStatus(rate: 1), .unknown)
        }
    }

    /// Every progress, speed, length and kind lands on exactly one form, in
    /// both wordings, on the same minute, with no percent anywhere.
    func testEveryCardReadsOneOfTheThreeForms() {
        for progress in [0, 0.001, 0.43, 0.98, 0.99, 1] {
            for rate in [0.5, 1, 1.5, 3] {
                for words in [100, 9_900, 333_333] {
                    for kind in [DocKind.text, .pdf] {
                        let book = doc(progress: progress, wordCount: words, kind: kind)
                        let visible = book.listeningSubtitle(rate: rate)
                        let spoken = book.spokenListeningSubtitle(rate: rate)
                        let context = "\(progress), \(rate)×, \(words) words, \(kind): '\(visible)' / '\(spoken)'"

                        XCTAssertFalse(visible.contains("%"), context)
                        XCTAssertFalse(spoken.contains("%"), context)
                        XCTAssertFalse(spoken.contains("·"), context)
                        XCTAssertNil(spoken.range(of: #"\b(min|hr)\b"#, options: .regularExpression), context)
                        XCTAssertNil(spoken.range(of: #"(^|\D)1 (hours|minutes)\b"#, options: .regularExpression),
                                     "singular for one: \(context)")

                        guard let shown = Self.form(of: visible, spoken: false),
                              let heard = Self.form(of: spoken, spoken: true) else {
                            XCTFail("not one of the three forms: \(context)")
                            continue
                        }
                        XCTAssertEqual(shown, heard, "visible and spoken agree on the minute: \(context)")
                        XCTAssertEqual(shown, book.shelfStatus(rate: rate), context)
                        switch shown {
                        case .finished:
                            XCTAssertTrue(book.isFinished, context)
                            XCTAssertGreaterThanOrEqual(progress, LibraryDocument.finishedThreshold, context)
                        case .length(let minutes):
                            XCTAssertEqual(progress, 0, context)
                            XCTAssertGreaterThanOrEqual(minutes, 1, context)
                        case .left(let minutes):
                            // Past 0.99 too, when more than a minute is left.
                            XCTAssertFalse(book.isFinished, context)
                            XCTAssertGreaterThan(progress, 0, context)
                            XCTAssertLessThan(progress, 1, context)
                            XCTAssertGreaterThanOrEqual(minutes, 1, context)
                        case .unknown:
                            XCTFail("every book here has a length: \(context)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Every surface reads the same line

    /// With nothing outranking it, the Continue card's subtitle is the
    /// author, then the grid card's line (R1-02); the spoken line still has
    /// no author, since the card's label already ends with it.
    func testTheHeroReadsTheCardsLine() {
        let books = [doc(wordCount: 48_208), doc(progress: 0.43, wordCount: 20_842),
                     doc(progress: 1, wordCount: 20_842), doc(progress: 0.43, wordCount: 0),
                     doc(progress: 0.5, wordCount: 1_320, kind: .pdf), doc(author: nil, wordCount: 2_317)]
        for book in books {
            for rate in [1, 1.5] {
                XCTAssertEqual(ContinueListeningCopy.subtitle(for: book, rate: rate, stop: nil,
                                                              offersNaturalVoice: false, modelState: .notInstalled),
                               [book.author ?? "", book.listeningSubtitle(rate: rate)]
                                   .filter { !$0.isEmpty }.joined(separator: " · "))
                XCTAssertEqual(ContinueListeningCopy.spokenSubtitle(for: book, rate: rate, stop: nil,
                                                                    offersNaturalVoice: false,
                                                                    modelState: .notInstalled),
                               book.spokenListeningSubtitle(rate: rate))
            }
        }
    }

    /// "Title, Author, <spoken form>", and just "Title, Author" when the
    /// length is unknown (DocumentCardView drops the empty line).
    func testCardLabelsReadTheSpokenForm() {
        // The Cask of Amontillado: 2,317 words is 14 minutes at 1×.
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(wordCount: 2_317), rate: 1),
                       "Title, Author, 14 minutes")
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(progress: 0.43, wordCount: 20_842), rate: 1),
                       "Title, Author, 1 hour 12 minutes left")
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(progress: 1, wordCount: 20_842), rate: 1),
                       "Title, Author, finished")
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(progress: 0.43, wordCount: 0), rate: 1),
                       "Title, Author")
    }

    // MARK: - Snapshots

    /// The three states drawn as a 170pt grid card at 2x, in light and dark,
    /// attached for review ("card-<state>-<scheme>"). The three must draw
    /// differently: the line (and the progress bar) is the only difference.
    @MainActor
    func testTheThreeStatesRenderInLightAndDark() throws {
        let states: [(name: String, document: LibraryDocument)] = [
            ("length", doc(title: "The Great Gatsby", author: "F. Scott Fitzgerald", wordCount: 48_208)),
            ("left", doc(title: "The Great Gatsby", author: "F. Scott Fitzgerald",
                         progress: 0.43, wordCount: 48_208)),
            ("finished", doc(title: "The Great Gatsby", author: "F. Scott Fitzgerald",
                             progress: 1, wordCount: 48_208)),
        ]
        for (schemeName, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            var pngs: [Data] = []
            for state in states {
                let name = "card-\(state.name)-\(schemeName)"
                let image = try XCTUnwrap(Self.render(state.document, scheme: scheme), name)
                XCTAssertGreaterThan(image.height, 0, name)
                let png = try XCTUnwrap(RenderedPixels.pngData(image), name)
                pngs.append(png)
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: UTType.png.identifier)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertEqual(Set(pngs).count, states.count, "the three states draw alike in \(schemeName)")
        }
    }

    /// A grid card as the shelf lays it out, on the paper of `scheme`. The
    /// trait pin reaches Theme's UIColor providers as well as SwiftUI.
    @MainActor
    private static func render(_ document: LibraryDocument, scheme: ColorScheme) -> CGImage? {
        let card = DocumentCardView(document: document, rate: 1)
            .frame(width: 170)
            .padding(Theme.Space.sm)
            .background(Theme.bgResolved(for: scheme))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        var image: CGImage?
        UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light).performAsCurrent {
            image = renderer.cgImage
        }
        return image
    }

    // MARK: - Reading a line back

    /// The form a line is in, with its minutes, read from the words alone;
    /// nil when it is none of the three (or rolls 60 minutes into "60 min").
    private static func form(of line: String, spoken: Bool) -> LibraryDocument.ShelfStatus? {
        if line.isEmpty { return .unknown }
        if line == (spoken ? "finished" : "Finished") { return .finished }
        let pattern = spoken
            ? #"^(?:(\d+) hours?(?: (\d+) minutes?)?|(\d+) minutes?)( left)?$"#
            : #"^(?:(\d+) hr(?: (\d+) min)?|(\d+) min)( left)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else {
            return nil
        }
        func number(_ group: Int) -> Int {
            let range = match.range(at: group)
            return range.location == NSNotFound ? 0 : Int(text.substring(with: range)) ?? 0
        }
        guard number(2) < 60, number(3) < 60 else { return nil }
        let minutes = number(1) * 60 + number(2) + number(3)
        return match.range(at: 4).location == NSNotFound ? .length(minutes: minutes) : .left(minutes: minutes)
    }
}

// MARK: - The Classics row as VoiceOver meets it

/// P052 and P053 on a hosted Classics row: one button whose label the new
/// layout leaves unchanged (side by side and stacked), whose hint says what
/// happens, as a grid card's does, and which promises nothing for a finished
/// library copy. Hosted in a window with the AX runtime's automation on, as
/// ScrubAccessibilityTests does; only a host that vends no tree at all
/// skips. Silent: the row's action does nothing.
@MainActor
final class ClassicsRowAccessibilityTests: XCTestCase {

    private static let cask = BookshelfBook(gutenbergID: 1063, title: "The Cask of Amontillado",
                                            author: "Edgar Allan Poe", year: nil,
                                            file: "1063-the-cask-of-amontillado.txt", words: 2317)
    private static let identifier = "bookshelf.row.1063"
    private static let label = "The Cask of Amontillado, by Edgar Allan Poe, about 14 minutes"
    private static let hint = "Opens and starts reading aloud"

    private var window: UIWindow?
    private var restoreAccessibility: (() -> Void)?

    override func setUp() {
        super.setUp()
        restoreAccessibility = ClassicsAXRuntime.enable()
    }

    override func tearDown() {
        closeWindow()
        restoreAccessibility?()
        restoreAccessibility = nil
        super.tearDown()
    }

    func testABookNotYetAddedPromisesReadingAloud() async throws {
        for stacked in [false, true] {
            let row = try await hostRow(inLibrary: false, finished: false, stacked: stacked)
            XCTAssertEqual(row.accessibilityLabel, Self.label, "stacked: \(stacked)")
            XCTAssertEqual(row.accessibilityHint, Self.hint, "stacked: \(stacked)")
            XCTAssertEqual(row.accessibilityHint, BookshelfView.rowHint(finished: false))
            XCTAssertTrue(row.accessibilityTraits.contains(.button), "stacked: \(stacked)")
            XCTAssertTrue(row.accessibilityValue?.isEmpty ?? true, "no status yet: \(row.accessibilityValue ?? "")")
        }
    }

    func testAFinishedCopyPromisesNothing() async throws {
        let row = try await hostRow(inLibrary: true, finished: true, stacked: false)
        XCTAssertEqual(row.accessibilityLabel, Self.label)
        XCTAssertEqual(row.accessibilityValue, "In library")
        XCTAssertTrue(row.accessibilityHint?.isEmpty ?? true,
                      "a finished copy opens paused, so no hint: \(row.accessibilityHint ?? "")")
    }

    func testAnUnfinishedCopyStillPromisesReadingAloud() async throws {
        let row = try await hostRow(inLibrary: true, finished: false, stacked: false)
        XCTAssertEqual(row.accessibilityValue, "In library")
        XCTAssertEqual(row.accessibilityHint, Self.hint)
    }

    // MARK: Hosting

    /// The row alone in a real window, then its element in the tree SwiftUI
    /// builds for it.
    private func hostRow(inLibrary: Bool, finished: Bool, stacked: Bool) async throws -> NSObject {
        closeWindow()
        let row = ClassicsRowButton(book: Self.cask, rate: 1, inLibrary: inLibrary, adding: false,
                                    finished: finished, stacked: stacked) {}
        let controller = UIHostingController(rootView: VStack(spacing: 0) { row; Spacer() }.background(Theme.bg))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        self.window = window

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let found = find(Self.identifier) { return found }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard vendsTree else { throw XCTSkip("This test host builds no SwiftUI accessibility tree") }
        throw ClassicsRowMissing()
    }

    private func closeWindow() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    private var vendsTree: Bool {
        guard let root = window?.rootViewController?.view else { return false }
        if let elements = root.accessibilityElements, !elements.isEmpty { return true }
        let count = root.accessibilityElementCount()
        return count > 0 && count != NSNotFound
    }

    /// A breadth-first walk over accessibility children and subviews.
    private func find(_ identifier: String) -> NSObject? {
        guard let root = window?.rootViewController?.view else { return nil }
        var queue: [NSObject] = [root]
        var next = 0
        while next < queue.count, next < 5_000 {
            let node = queue[next]
            next += 1
            if Self.identifier(of: node) == identifier { return node }
            if let elements = node.accessibilityElements {
                queue.append(contentsOf: elements.compactMap { $0 as? NSObject })
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { queue.append(child) }
                    }
                }
            }
            if let view = node as? UIView { queue.append(contentsOf: view.subviews) }
        }
        return nil
    }

    private static func identifier(of node: NSObject) -> String? {
        if let identified = node as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        guard node.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return node.value(forKey: "accessibilityIdentifier") as? String
    }
}

/// The tree is there, the row isn't: a real failure, never a skip.
private struct ClassicsRowMissing: Error, CustomStringConvertible {
    var description: String { "The accessibility tree has no Classics row" }
}

/// SwiftUI builds its accessibility tree only for an assistive client; the
/// AX runtime's own switches stand in for one, as in
/// ScrubAccessibilityTests. Private API, in the test target only.
private enum ClassicsAXRuntime {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    private static let library: UnsafeMutableRawPointer? = {
        let path = "/usr/lib/libAccessibility.dylib"
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        return dlopen(root + path, RTLD_NOW) ?? dlopen(path, RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    /// Turns automation and app accessibility on; the closure puts back
    /// what was there.
    static func enable() -> () -> Void {
        let switches = [("_AXSAutomationEnabled", "_AXSSetAutomationEnabled"),
                        ("_AXSApplicationAccessibilityEnabled", "_AXSApplicationAccessibilitySetEnabled")]
        var restores: [() -> Void] = []
        for (getterName, setterName) in switches {
            guard let get = symbol(getterName, as: Getter.self),
                  let set = symbol(setterName, as: Setter.self) else { continue }
            let before = get()
            set(1)
            restores.append { set(before) }
        }
        return { restores.forEach { $0() } }
    }
}
