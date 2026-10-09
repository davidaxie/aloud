import SwiftUI
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import Aloud

/// Round 3's speed control on both apps: the speed is drawn on the scrub's
/// warm track with its accent thumb and dragged by the scrub's rules on the
/// speed scale (R3-09); the live rate reads on the track's row below the
/// accessibility sizes, the numeral only at them (R3-10); and under Increase
/// Contrast every unselected preset is edged on every surface (R3-11).
/// Rendered through ImageRenderer, which both hosts have; the source pin
/// skips where the host can't see the checkout, and the contrast check is
/// the iPhone's (UIKit traits).
@MainActor
final class SpeedControlTests: XCTestCase {

    private static let width: CGFloat = 300

    // MARK: - The drag (R3-09)

    /// x maps across the whole track to the 0.5–3× scale, clamped, every
    /// result on the 0.05 grid, the 1× detent magnetic.
    func testTheDragMapsXToTheScaleSnappedWithTheDetent() {
        let width = Self.width
        XCTAssertEqual(SpeedTrack.rate(atX: 0, width: width), 0.5)
        XCTAssertEqual(SpeedTrack.rate(atX: width, width: width), 3.0)
        XCTAssertEqual(SpeedTrack.rate(atX: width / 2, width: width), 1.75, accuracy: 1e-9)
        XCTAssertEqual(SpeedTrack.rate(atX: -40, width: width), 0.5, "clamped at the slow end")
        XCTAssertEqual(SpeedTrack.rate(atX: width + 40, width: width), 3.0, "clamped at the fast end")
        XCTAssertEqual(SpeedTrack.rate(atX: x(forRaw: 1.03), width: width), 1.0, "inside the detent")
        XCTAssertEqual(SpeedTrack.rate(atX: x(forRaw: 0.97), width: width), 1.0, "inside the detent")
        XCTAssertEqual(SpeedTrack.rate(atX: x(forRaw: 1.23), width: width), 1.25, accuracy: 1e-9)
        XCTAssertEqual(SpeedTrack.rate(atX: x(forRaw: 0.92), width: width), 0.9, accuracy: 1e-9)
        for step in 0...Int(width) {
            let rate = SpeedTrack.rate(atX: CGFloat(step), width: width)
            XCTAssertEqual(rate * 20, (rate * 20).rounded(), accuracy: 1e-9, "x \(step): \(rate) is off the grid")
            XCTAssertTrue(SpeedScale.range.contains(rate), "x \(step): \(rate)")
        }
        for rate in [0.5, 1.0, 1.75, 3.0] {
            XCTAssertEqual(SpeedTrack.fraction(of: rate) * 2.5 + 0.5, rate, accuracy: 1e-9)
        }
        XCTAssertEqual(SpeedTrack.fraction(of: 9), 1, "clamped")
        XCTAssertEqual(SpeedTrack.fraction(of: .nan), 0)
    }

    /// A sweep across the whole track, either way, lands on the detent once:
    /// the 1× tick's one arrival (R20), never once per frame on it.
    func testASweepAcrossTheTrackLandsOnTheDetentOnce() {
        for xs in [Array(0...Int(Self.width)), Array((0...Int(Self.width)).reversed())] {
            var rate = SpeedTrack.rate(atX: CGFloat(xs[0]), width: Self.width)
            var ticks = 0
            for x in xs.dropFirst() {
                let next = SpeedTrack.rate(atX: CGFloat(x), width: Self.width)
                if SpeedScale.landsOnDetent(from: rate, to: next) { ticks += 1 }
                rate = next
            }
            XCTAssertEqual(ticks, 1, "from x \(xs[0]): one tick on arriving at 1×")
        }
    }

    /// A drag that starts on the thumb carries it by the finger's travel,
    /// so it never jumps on the first frame; one that starts elsewhere on
    /// the track takes the rate under the finger, as the scrub does.
    func testADragOnTheThumbCarriesItAndOneElsewhereJumpsToTheFinger() {
        let width = Self.width
        let start = 0.8
        let thumb = WarmTrack.thumbCentre(fraction: SpeedTrack.fraction(of: start), width: width)
        XCTAssertEqual(thumb, 36, accuracy: 0.001, "0.8× sits 12% along a 300pt track")
        for grab in [thumb - 10, thumb, thumb + 10] {
            XCTAssertEqual(SpeedTrack.rate(startX: grab, x: grab, startRate: start, width: width), start,
                           accuracy: 1e-9, "grabbed at \(grab): no jump")
            XCTAssertEqual(SpeedTrack.rate(startX: grab, x: grab + 48, startRate: start, width: width), 1.2,
                           accuracy: 1e-9, "grabbed at \(grab): 48pt is 0.4×")
            XCTAssertEqual(SpeedTrack.rate(startX: grab, x: grab - 400, startRate: start, width: width), 0.5,
                           "clamped")
        }
        XCTAssertEqual(SpeedTrack.rate(startX: 200, x: 200, startRate: start, width: width),
                       SpeedTrack.rate(atX: 200, width: width), "off the thumb: the rate under the finger")
        XCTAssertEqual(SpeedTrack.rate(startX: 200, x: 210, startRate: start, width: width), 2.25, accuracy: 1e-9)
        XCTAssertEqual(SpeedTrack.rate(startX: 5, x: 5, startRate: 1, width: 0), 1, "no track yet: no change")
    }

    /// Only a drag whose first 8pt are more sideways than down is the
    /// track's, decided once: the sheet keeps its drags, and a speed drag
    /// that drifts downward later keeps the speed. The start rate is the
    /// first frame's.
    func testOnlyASidewaysDragMovesTheSpeed() {
        func engagement(_ dx: CGFloat, _ dy: CGFloat, after state: SpeedTrack.Engagement? = nil) -> SpeedTrack.Engagement {
            SpeedTrack.engagement(after: state, translation: CGSize(width: dx, height: dy))
        }
        XCTAssertEqual(engagement(8, 0), .horizontal)
        XCTAssertEqual(engagement(-9, 4), .horizontal)
        XCTAssertEqual(engagement(2, 10), .vertical)
        XCTAssertEqual(engagement(10, 10), .vertical, "a diagonal is the sheet's")
        XCTAssertEqual(engagement(6, 6), .undecided)
        XCTAssertEqual(engagement(12, 0, after: .undecided), .horizontal)
        XCTAssertEqual(engagement(60, 0, after: .vertical), .vertical, "decided once")
        XCTAssertEqual(engagement(0, 80, after: .horizontal), .horizontal, "decided once")

        let first = SpeedTrack.Drag.next(after: nil, translation: CGSize(width: 9, height: 0), rate: 0.8)
        XCTAssertEqual(first, SpeedTrack.Drag(engagement: .horizontal, startRate: 0.8))
        let later = SpeedTrack.Drag.next(after: first, translation: CGSize(width: 90, height: 30), rate: 1.4)
        XCTAssertEqual(later.startRate, 0.8, "the start is the first frame's speed")
        XCTAssertEqual(later.engagement, .horizontal)
    }

    /// On the Mac a click sets the speed where it lands, as the stock macOS
    /// slider did and as MacScrub's click seeks: no travel to wait for, and
    /// the press is the track's from its first frame. The iPhone keeps the
    /// scrub's 8pt wait and the sideways rule.
    func testOnTheMacAClickSetsTheSpeed() {
        #if os(macOS)
        XCTAssertTrue(PlatformTuning.speedTrackSetsOnClick, "the Mac's pointer clicks to set")
        #else
        XCTAssertFalse(PlatformTuning.speedTrackSetsOnClick, "the iPhone's finger waits for a sideways drag")
        #endif
        XCTAssertEqual(SpeedTrack.minimumDistance(setsOnClick: true), 0, "a click is a press with no travel")
        XCTAssertEqual(SpeedTrack.minimumDistance(setsOnClick: false), ScrubGesture.minimumDistance)

        let click = SpeedTrack.Drag.next(after: nil, translation: .zero, rate: 1, setsOnClick: true)
        XCTAssertEqual(click, SpeedTrack.Drag(engagement: .horizontal, startRate: 1), "the track's at once")
        XCTAssertEqual(SpeedTrack.Drag.next(after: nil, translation: .zero, rate: 1).engagement, .undecided,
                       "a touch waits for its 8pt")
        XCTAssertEqual(SpeedTrack.engagement(after: .undecided, translation: CGSize(width: 0, height: 30),
                                             setsOnClick: true),
                       .horizontal, "a pointer drag that wanders down still moves the speed")

        // Where it lands: off the thumb, the rate under the pointer; on the
        // thumb, the speed it holds.
        let width = Self.width
        let landed = SpeedTrack.rate(startX: 200, x: 200, startRate: 1, width: width)
        XCTAssertEqual(landed, SpeedTrack.rate(atX: 200, width: width), "the rate under the click")
        XCTAssertNotEqual(landed, 1, "a click off the thumb moves the speed")
        let thumb = WarmTrack.thumbCentre(fraction: SpeedTrack.fraction(of: 1), width: width)
        XCTAssertEqual(SpeedTrack.rate(startX: thumb, x: thumb, startRate: 1, width: width), 1,
                       "a click on the thumb holds the speed")
    }

    // MARK: - The warm track (R3-09)

    /// WarmTrack's unfilled track is the scrub's warm track (never the
    /// system's grey) and its fill the accent, in light and dark; held, the
    /// line thickens, and under Reduce Motion it doesn't.
    func testTheWarmTrackDrawsTheScrubsTrackUnderTheAccent() throws {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let unfilled = rgb(Theme.scrubTrack.resolve(in: environment))
            let accent = rgb(Theme.accent.resolve(in: environment))
            XCTAssertGreaterThan(unfilled[0], unfilled[2] + 0.02, "\(scheme): a warm track, red over blue")

            // 2x: the track is 200 x 8pt, its resting line 2 to 6pt down.
            let empty = try track(fraction: 0, scheme: scheme)
            assertColor(empty.rgb(x: 300, y: 8), unfilled, "\(scheme): the unfilled track is scrubTrack")
            XCTAssertEqual(empty.alpha(x: 300, y: 2), 0, accuracy: 0.02, "\(scheme): a resting line is 4pt")
            let full = try track(fraction: 1, scheme: scheme)
            assertColor(full.rgb(x: 300, y: 8), accent, "\(scheme): the fill is the accent")

            let held = try track(fraction: 0, isHeld: true, scheme: scheme)
            assertColor(held.rgb(x: 300, y: 2), unfilled, "\(scheme): held, the line thickens to 8pt")
            let still = try track(fraction: 0, isHeld: true, reduceMotion: true, scheme: scheme)
            XCTAssertEqual(still.alpha(x: 300, y: 2), 0, accuracy: 0.02, "\(scheme): under Reduce Motion it doesn't")
        }
    }

    // MARK: - The readout (R3-10)

    /// Below the accessibility sizes the numeral is gone: the controls are
    /// the presets' row and the track's row, with their spacing and
    /// padding, and nothing above. At them the numeral comes back.
    func testBelowTheAccessibilitySizesNoNumeralIsDrawn() throws {
        for size in DynamicTypeSize.allCases {
            XCTAssertEqual(ListeningSpeedControls.showsNumeral(at: size), size.isAccessibilitySize, "\(size)")
        }
        let rig = PlaybackTestRig()
        let rows = Theme.Space.xs + 44 + Theme.Space.md + 44 + Theme.Space.sm
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge] {
            XCTAssertEqual(try controlsHeight(rig, size: size), rows, accuracy: 1,
                           "\(size): the presets and the track's row alone")
        }
        // AX3: the presets stand in two columns, three rows each 44pt or
        // its callout line where that is taller, so the controls without a
        // numeral are `withoutNumeral` tall; the numeral adds its line and
        // the stack's spacing on top. (Two columns alone add over 100pt, so
        // a bare margin over `rows` proves nothing.)
        let ax3 = DynamicTypeSize.accessibility3
        let presetRow = try max(44, lineHeight(Theme.font(.callout), ListeningFormat.rate(1.25), size: ax3))
        let withoutNumeral = Theme.Space.xs + (3 * presetRow + 2 * Theme.Space.xs) + Theme.Space.md
            + 44 + Theme.Space.sm
        let numeral = try lineHeight(Theme.font(.numeral), ListeningFormat.rate(1), size: ax3)
        XCTAssertGreaterThan(numeral, 20, "AX3: the numeral's line")
        let height = try controlsHeight(rig, size: ax3)
        // 3pt for the half-point rounding of the four measured lines.
        XCTAssertGreaterThanOrEqual(height, withoutNumeral + Theme.Space.md + numeral - 3,
                                    "AX3: the numeral is back above the two-column presets "
                                    + "(\(height) against \(withoutNumeral) without it)")
    }

    /// The readout keeps one width at every rate, so the track beside it
    /// never resizes under a finger.
    func testTheReadoutKeepsOneWidth() throws {
        let widths = try [0.5, 1, 1.25, 2.75, 3].map { rate -> Int in
            let image = try XCTUnwrap(render(SpeedReadout(rate: rate), scale: 2), "\(rate)")
            return image.width
        }
        XCTAssertGreaterThan(widths[0], 0)
        XCTAssertEqual(Set(widths).count, 1, "one width at 0.5×, 1×, 1.25×, 2.75× and 3×: \(widths)")
    }

    // MARK: - Increase Contrast (R3-11)

    /// The unselected presets are edged where the caller asks and, on every
    /// surface, under Increase Contrast; the default look is unchanged.
    func testUnderIncreaseContrastEveryPresetIsEdged() {
        XCTAssertFalse(ListeningSpeedControls.edgesUnselected(asked: false, contrast: .standard),
                       "the reader's sheet and the Mac keep their default")
        XCTAssertTrue(ListeningSpeedControls.edgesUnselected(asked: true, contrast: .standard), "Settings")
        XCTAssertTrue(ListeningSpeedControls.edgesUnselected(asked: false, contrast: .increased),
                      "every surface under Increase Contrast")
        XCTAssertTrue(ListeningSpeedControls.edgesUnselected(asked: true, contrast: .increased))
    }

    #if os(iOS)
    /// The edge they take, `Theme.Stroke.borderColor`, is a 3:1 boundary
    /// under Increase Contrast on both chip grounds, light and dark.
    func testTheEdgeIsThreeToOneUnderIncreaseContrast() {
        for dark in [false, true] {
            let traits = UITraitCollection { traits in
                traits.userInterfaceStyle = dark ? .dark : .light
                traits.accessibilityContrast = .high
            }
            func luminance(_ color: Color) -> CGFloat {
                var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            }
            for (name, ground) in [("surface", Theme.surface), ("surface2", Theme.surface2)] {
                let (edge, base) = (luminance(Theme.Stroke.borderColor), luminance(ground))
                let ratio = (max(edge, base) + 0.05) / (min(edge, base) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(dark ? "dark" : "light") on \(name): \(ratio)")
            }
        }
    }
    #endif

    // MARK: - Source

    /// The speed control draws WarmTrack and keeps the stock slider only as
    /// its accessibilityRepresentation, under the identifier the UI tests
    /// find; the stock slider's appearance proxy is gone.
    func testTheSpeedControlDrawsTheWarmTrackAndKeepsTheSlider() throws {
        let paths = ["Settings/ListeningView.swift", "Theme/WarmTrack.swift", "App/AloudApp.swift"]
        let s = try SourceTree.sources(only: paths)
        let view = try XCTUnwrap(s[paths[0]])
        XCTAssertNotNil(s[paths[1]], "the shared track has its own file")
        let app = try XCTUnwrap(s[paths[2]])
        let start = try XCTUnwrap(view.range(of: "struct ListeningSpeedControls: View"))
        let end = try XCTUnwrap(view.range(of: "struct SpeedReadout: View"))
        let controls = String(view[start.upperBound..<end.lowerBound])
        XCTAssertTrue(controls.contains("WarmTrack(fraction: SpeedTrack.fraction(of: playback.rate),"),
                      "the speed draws the warm track")
        XCTAssertEqual(controls.components(separatedBy: "Slider(").count - 1, 1, "one slider")
        let representation = try XCTUnwrap(controls.range(of: ".accessibilityRepresentation {"))
        let slider = try XCTUnwrap(controls.range(of: "Slider("))
        XCTAssertLessThan(representation.lowerBound, slider.lowerBound, "the slider is the representation only")
        let element = String(controls[representation.upperBound...].prefix(2000))
        for needle in [".frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)",
                       ".accessibilityLabel(\"Speed\")", ".accessibilityValue(ListeningFormat.rate(playback.rate))",
                       ".accessibilityAdjustableAction { direction in",
                       ".accessibilityIdentifier(\"listening.speed.slider\")"] {
            XCTAssertTrue(element.contains(needle), "the representation keeps \(needle)")
        }
        XCTAssertFalse(controls.contains(".tint(Theme.accent)"), "no stock slider is drawn")
        XCTAssertTrue(controls.contains("private static let setsOnClick = PlatformTuning.speedTrackSetsOnClick"),
                      "the click rule is the platform's")
        XCTAssertTrue(controls.contains("DragGesture(minimumDistance: SpeedTrack.minimumDistance(setsOnClick: Self.setsOnClick))"),
                      "the scrub's 8pt drag on the iPhone, a click on the Mac")
        XCTAssertTrue(controls.contains("rate: playback.rate, setsOnClick: Self.setsOnClick)"),
                      "the Mac's press is the track's from its first frame")
        XCTAssertTrue(controls.contains(".simultaneousGesture(speedGesture(width: width))"),
                      "the sheet's and the scroll view's pans recognise alongside the speed drag")
        XCTAssertFalse(controls.contains(".gesture(speedGesture("),
                       "an exclusive drag would keep a vertical swipe from the list and the sheet")
        XCTAssertTrue(controls.contains("if new == nil, old?.engagement == .horizontal { playback.selectRate(playback.rate) }"),
                      "the release persists the pick, a cancel too")
        XCTAssertFalse(app.contains("SliderAppearance"), "the appearance proxy never reached a SwiftUI slider")
    }

    // MARK: - Helpers

    /// The x on the test track where the unsnapped rate is `raw`.
    private func x(forRaw raw: Double) -> CGFloat {
        CGFloat((raw - 0.5) / 2.5) * Self.width
    }

    private func rgb(_ resolved: Color.Resolved) -> [Double] {
        [Double(resolved.red), Double(resolved.green), Double(resolved.blue)]
    }

    private func assertColor(_ got: [Double], _ want: [Double], _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            XCTAssertEqual(got[channel], want[channel], accuracy: 0.02, "\(message): \(got) vs \(want)",
                           file: file, line: line)
        }
    }

    private func track(fraction: Double, isHeld: Bool = false, reduceMotion: Bool = false,
                       scheme: ColorScheme) throws -> Pixels {
        let view = WarmTrack(fraction: fraction, isHeld: isHeld, reduceMotion: reduceMotion)
            .frame(width: 200)
            .environment(\.colorScheme, scheme)
        let image = try XCTUnwrap(render(view, scale: 2), "WarmTrack rendered")
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 16, "a box as tall as the held line")
        return try XCTUnwrap(Pixels(image))
    }

    private func controlsHeight(_ rig: PlaybackTestRig, size: DynamicTypeSize) throws -> CGFloat {
        let view = ListeningSpeedControls(selectedChipUnderlay: nil)
            .environmentObject(rig.controller)
            .environment(\.dynamicTypeSize, size)
        let image = try XCTUnwrap(render(view, width: 390, scale: 1), "\(size)")
        return CGFloat(image.height)
    }

    /// One line of `text` in `font` at `size`, to the half point.
    private func lineHeight(_ font: Font, _ text: String, size: DynamicTypeSize) throws -> CGFloat {
        let line = Text(text).font(font).monospacedDigit().fixedSize()
            .environment(\.dynamicTypeSize, size)
        let image = try XCTUnwrap(render(line, scale: 2), "\(text) at \(size)")
        return CGFloat(image.height) / 2
    }

    private func render<V: View>(_ view: V, width: CGFloat? = nil, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        if let width { renderer.proposedSize = ProposedViewSize(width: width, height: nil) }
        return renderer.cgImage
    }

    /// An image's pixels as gamma-encoded sRGB, row 0 at the top.
    private struct Pixels {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = data.withUnsafeMutableBytes { buffer in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            bytes = data
        }

        func alpha(x: Int, y: Int) -> Double {
            Double(bytes[(y * width + x) * 4 + 3]) / 255
        }

        /// Opaque pixels only (premultiplied, so a clear one reads black).
        func rgb(x: Int, y: Int) -> [Double] {
            let index = (y * width + x) * 4
            return (0..<3).map { Double(bytes[index + $0]) / 255 }
        }
    }
}
