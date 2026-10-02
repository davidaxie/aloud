import SwiftUI
import XCTest
@testable import Aloud

/// The player bar's height must not depend on the height it is offered. The
/// reader's safeAreaInset reserves the bar's ideal height and then places it
/// with that finite height; a bar that comes out shorter than its inset
/// leaves its paper short of the screen bottom, with reader text showing
/// under the controls (seen at AX3 with a chapterless book, whose title
/// wraps the chapter line). Measured with silent rigs: nothing here plays.
@MainActor
final class PlayerBarLayoutTests: XCTestCase {

    private static let longTitle = "The Narrative of Arthur Gordon Pym of Nantucket"
    private static let shortTitle = "Gatsby"
    /// A 402pt phone (the size the defect was captured on).
    private static let width: CGFloat = 402

    // Kept alive for the hosted views' lifetime.
    private var rig: PlaybackTestRig?
    private var offers: [NaturalVoiceOffer] = []
    private var modelManager: ModelManager?
    private var sleepTimer: SleepTimer?
    private var suites: [String] = []
    private var modelDirectory: URL?

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        if let modelDirectory { try? FileManager.default.removeItem(at: modelDirectory) }
        super.tearDown()
    }

    // MARK: - Harness

    /// A chapterless text book (one page), so the chapter line shows its title.
    private func makeBar(title: String, offerVisible: Bool, size: DynamicTypeSize) -> some View {
        let rig = self.rig ?? PlaybackTestRig(sentences: 40, autoplaySuppressed: true)
        self.rig = rig
        let directory = modelDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerBarLayoutTests-\(UUID().uuidString)", isDirectory: true)
        modelDirectory = directory
        // An expensive path and an empty directory: nothing is ever downloaded.
        let manager = modelManager ?? ModelManager(
            pathSource: FixedNetworkPath(isExpensiveOrConstrained: true), installDirectory: directory)
        modelManager = manager
        let timer = sleepTimer ?? SleepTimer()
        sleepTimer = timer

        let suite = "aloud.tests.playerBarLayout.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(NaturalVoiceOffer.listenThreshold, forKey: NaturalVoiceOffer.Key.listenedSeconds)
        let offer = NaturalVoiceOffer(defaults: defaults, deviceSupported: offerVisible, now: { 0 })
        offer.modelStateChanged(.notInstalled)
        XCTAssertEqual(offer.isVisible, offerVisible, "offer fixture")
        offers.append(offer)

        let content = PlaybackTestRig.makeContent(hash: "bar-layout", count: 40, wordsPerSentence: 12)
        var document = PlaybackTestRig.makeDocument(hash: "bar-layout", sentences: 40)
        document.title = title
        return PlayerBarView(document: document,
                             content: content,
                             navigation: ReaderNavigation(content: content, kind: .text))
            .environmentObject(rig.controller)
            .environmentObject(offer)
            .environmentObject(manager)
            .environmentObject(timer)
            .environment(\.dynamicTypeSize, size)
    }

    private func height(of view: some View, offered height: CGFloat) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: Self.width, height: height))
            .height
    }

    // MARK: - Tests

    /// Offered exactly its ideal height, the bar takes all of it — at every
    /// text size, with a one-line or wrapping chapter line, and with the
    /// natural-voice offer in the line. Before the fix a wrapping line made
    /// the bar ~20pt shorter than its inset at AX3.
    func testBarFillsItsIdealHeightWhenOfferedExactlyThat() {
        let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
        for size in sizes {
            for title in [Self.shortTitle, Self.longTitle] {
                for offerVisible in [false, true] {
                    let bar = makeBar(title: title, offerVisible: offerVisible, size: size)
                    let ideal = height(of: bar, offered: .greatestFiniteMagnitude)
                    let placed = height(of: bar, offered: ideal)
                    XCTAssertEqual(placed, ideal, accuracy: 0.5,
                                   "\(size), \"\(title)\", offer \(offerVisible): offered its ideal "
                                   + "\(ideal)pt, the bar took \(placed)pt")
                }
            }
        }
    }

    /// Guards the test above: at AX3 the long title really wraps the chapter
    /// line (the case that went short), so the bar is taller than with a
    /// one-line title.
    func testLongTitleWrapsTheChapterLineAtAX3() {
        let short = height(of: makeBar(title: Self.shortTitle, offerVisible: false, size: .accessibility3),
                           offered: .greatestFiniteMagnitude)
        let long = height(of: makeBar(title: Self.longTitle, offerVisible: false, size: .accessibility3),
                          offered: .greatestFiniteMagnitude)
        XCTAssertGreaterThan(long, short + 20, "the AX3 chapter line should wrap the long title")
    }

    /// The scrub drag (chapter line, track fill, preview) must end with the
    /// touch even when the system cancels the drag, which never calls
    /// onEnded. @GestureState is reset on cancel; plain @State stayed frozen
    /// on the drag target. A gesture can't be cancelled from a test, so this
    /// pins the storage that gives that guarantee.
    func testScrubDragTargetIsGestureState() {
        let content = PlaybackTestRig.makeContent(hash: "bar-scrub", count: 4)
        let bar = PlayerBarView(document: PlaybackTestRig.makeDocument(hash: "bar-scrub", sentences: 4),
                                content: content,
                                navigation: ReaderNavigation(content: content, kind: .text))
        let storage = Mirror(reflecting: bar).children.first { $0.label == "_drag" }?.value
        XCTAssertNotNil(storage, "PlayerBarView.drag is gone; update this test")
        XCTAssertTrue(storage is GestureState<ScrubDrag?>,
                      "drag must be @GestureState, got \(storage.map { type(of: $0) } as Any)")
    }
}
