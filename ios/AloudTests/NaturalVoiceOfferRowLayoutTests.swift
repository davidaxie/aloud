import SwiftUI
import XCTest
@testable import Aloud

/// R5's offer copy "Natural voice · 353 MB, once" is never truncated in the
/// chapter line: the row stays one line while the copy and both buttons fit
/// and otherwise wraps the copy above the buttons. Widths are the chapter
/// line's (the screen minus the 20pt gutters). Nothing here downloads.
@MainActor
final class NaturalVoiceOfferRowLayoutTests: XCTestCase {

    private var directory: URL!
    private var suite: String!
    private var offer: NaturalVoiceOffer!
    private var manager: ModelManager!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaturalVoiceOfferRowLayoutTests-\(UUID().uuidString)", isDirectory: true)
        suite = "aloud.tests.offerRowLayout.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        offer = nil
        manager = nil
        super.tearDown()
    }

    private func rowHeight(width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        // An expensive path and an empty directory: a tap could only ask.
        manager = ModelManager(pathSource: FixedNetworkPath(isExpensiveOrConstrained: true),
                               installDirectory: directory)
        offer = NaturalVoiceOffer(defaults: UserDefaults(suiteName: suite)!, deviceSupported: true, now: { 0 })
        let row = NaturalVoiceOfferRow(onOpenContents: {})
            .environmentObject(offer)
            .environmentObject(manager)
            .environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
    }

    /// One 44pt row means the copy, Download and Not now share a line.
    private static let oneRow: CGFloat = 44
    /// The copy's 44pt row above the 44pt button row.
    private static let stacked: CGFloat = 88

    /// xLarge on a 375pt phone (335pt line) needs ~365pt for one line: the
    /// copy used to truncate to "Natural voice · 353 M…".
    func testXLargeOn375PhoneWrapsInsteadOfTruncating() {
        XCTAssertGreaterThanOrEqual(rowHeight(width: 335, size: .xLarge), Self.stacked)
    }

    /// The same on a 390pt phone (350pt line).
    func testXLargeOn390PhoneWrapsInsteadOfTruncating() {
        XCTAssertGreaterThanOrEqual(rowHeight(width: 350, size: .xLarge), Self.stacked)
    }

    /// Larger sizes on a small phone wrap too.
    func testXXXLargeOn375PhoneWraps() {
        XCTAssertGreaterThanOrEqual(rowHeight(width: 335, size: .xxxLarge), Self.stacked)
    }

    /// Where everything fits, the row keeps the one-line form.
    func testDefaultSizeOnAWideLineStaysOneRow() {
        XCTAssertEqual(rowHeight(width: 500, size: .large), Self.oneRow, accuracy: 0.5)
    }
}
