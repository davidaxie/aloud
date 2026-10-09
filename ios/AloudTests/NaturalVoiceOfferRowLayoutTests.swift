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

    private func makeRow(size: DynamicTypeSize, rowAlignment: VerticalAlignment = .center) -> some View {
        // An expensive path and an empty directory: a tap could only ask.
        manager = ModelManager(pathSource: FixedNetworkPath(isExpensiveOrConstrained: true),
                               installDirectory: directory)
        offer = NaturalVoiceOffer(defaults: UserDefaults(suiteName: suite)!, deviceSupported: true, now: { 0 })
        return NaturalVoiceOfferRow(onOpenContents: {}, rowAlignment: rowAlignment)
            .environmentObject(offer)
            .environmentObject(manager)
            .environment(\.dynamicTypeSize, size)
    }

    private func rowHeight(width: CGFloat, size: DynamicTypeSize,
                           rowAlignment: VerticalAlignment = .center) -> CGFloat {
        UIHostingController(rootView: makeRow(size: size, rowAlignment: rowAlignment))
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

    /// R1-44: on the iPhone bar's `.bottom` row the one-line offer sets its
    /// ink on the row's foot, lifted as the position line it replaces is, so
    /// the crossfade between them never moves the ink. Centred, as it was,
    /// it sat ~9pt higher. The row stays one 44pt row, and the ink moves
    /// whole: drawn, not just laid out.
    func testOnABottomRowTheOfferInkSitsOnTheRowsFoot() throws {
        XCTAssertEqual(rowHeight(width: 500, size: .large, rowAlignment: .bottom), Self.oneRow, accuracy: 0.5)
        let scale: CGFloat = 2
        /// The topmost and lowest inked rows of the one-line form, in points.
        func ink(_ rowAlignment: VerticalAlignment) throws -> (top: CGFloat, foot: CGFloat) {
            let pixels = try XCTUnwrap(RenderedPixels(makeRow(size: .large, rowAlignment: rowAlignment),
                                                      size: CGSize(width: 500, height: Self.oneRow), scale: scale))
            let inked = (0..<pixels.height).filter { y in
                (0..<pixels.width).contains { pixels.rgba(x: $0, y: y).a > 100 }
            }
            let first = try XCTUnwrap(inked.first, "the offer draws"), last = try XCTUnwrap(inked.last)
            return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
        }
        let centred = try ink(.center)
        let footed = try ink(.bottom)
        XCTAssertGreaterThanOrEqual(footed.foot - centred.foot, 6, "the ink moves down to the row's foot")
        XCTAssertEqual(footed.top - centred.top, footed.foot - centred.foot, accuracy: 1,
                       "the ink moves whole; nothing grows")
        XCTAssertLessThanOrEqual(footed.foot, Self.oneRow - ReaderMessageLine.footInset,
                                 "lifted off the foot as the position line is")
    }

    /// R2-26: at an accessibility size the wrapped offer on the bar's foot
    /// keeps the chapter line's air above its copy (12pt), so the crossfade
    /// between them never moves the ink; the button row may take its own
    /// air too where its ink outgrows the row, never more. Below those sizes
    /// the footed offer is exactly as tall as the centred one.
    func testAtAnAccessibilitySizeTheFootedOfferKeepsAirAboveIt() {
        let centred = rowHeight(width: 335, size: .accessibility2)
        let footed = rowHeight(width: 335, size: .accessibility2, rowAlignment: .bottom)
        XCTAssertGreaterThanOrEqual(centred, Self.stacked, "the copy wraps above the buttons")
        XCTAssertGreaterThanOrEqual(footed - centred, ReaderMessageLine.overflowHeadroom - 0.5,
                                    "air above the wrapped copy")
        XCTAssertLessThanOrEqual(footed - centred, 2 * ReaderMessageLine.overflowHeadroom + 0.5,
                                 "at most the copy's and the buttons' air")
        XCTAssertEqual(rowHeight(width: 335, size: .xxxLarge, rowAlignment: .bottom),
                       rowHeight(width: 335, size: .xxxLarge), accuracy: 0.5, "nothing moves below them")
    }
}
