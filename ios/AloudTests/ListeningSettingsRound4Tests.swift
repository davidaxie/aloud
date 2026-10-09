import SwiftUI
import XCTest
@testable import Aloud

/// Critique round 4 on Voice & speed and Settings, hosted on both apps (the
/// shared Listening view and the Licenses text the Mac's credits read):
/// the selected speed preset's fill shows on every surface (R4-24), the
/// voice list's group eyebrows (R4-25) and the Licenses copy (R4-28). The
/// source lints for these live in the iPhone's lint suites.
@MainActor
final class ListeningSettingsRound4Tests: XCTestCase {

    // MARK: - R4-24: the selected preset on every surface

    /// The reader's sheet draws the presets on surface. The selected chip's
    /// tint is drawn over surface2, the unselected chips' fill, so it stands
    /// off them (it was about 1.03:1 in light when it sat on surface), and
    /// its fill is the Appearance selected segment's: accentSoft over
    /// surface2.
    func testTheSelectedPresetStandsOffTheOthersOnSurface() throws {
        let rig = PlaybackTestRig()
        rig.controller.rate = 1
        for scheme in [ColorScheme.light, .dark] {
            let controls = ListeningSpeedControls()
                .environmentObject(rig.controller)
                .environment(\.dynamicTypeSize, .large)
                .background(Theme.surface)
                .environment(\.colorScheme, scheme)
            let image = try XCTUnwrap(render(controls, width: Self.width), "\(scheme): the controls")
            let pixels = try XCTUnwrap(Pixels(image))
            let selected = pixels.rgb(at: Self.inside(chip: 0))
            let unselected = pixels.rgb(at: Self.inside(chip: 1))
            let ratio = Self.contrast(selected, unselected)
            XCTAssertGreaterThanOrEqual(ratio, 1.08, "\(scheme): the selected 1× chip against 1.25×: "
                                        + String(format: "%.3f:1", ratio))

            let segment = Color.clear.frame(width: 8, height: 8)
                .background(Theme.accentSoft)
                .background(Theme.surface2)
                .environment(\.colorScheme, scheme)
            let reference = try XCTUnwrap(Pixels(try XCTUnwrap(render(segment, width: nil))))
            assertColor(selected, reference.rgb(at: (8, 8)),
                        "\(scheme): the selected chip is the Appearance segment's accentSoft over surface2")
            let ground = try XCTUnwrap(Pixels(try XCTUnwrap(render(Color.clear.frame(width: 8, height: 8)
                .background(Theme.surface2).environment(\.colorScheme, scheme), width: nil))))
            assertColor(unselected, ground.rgb(at: (8, 8)), "\(scheme): an unselected chip stays surface2")
        }
    }

    // MARK: - R4-25: the voice list's eyebrows

    /// The System row's eyebrow says where that voice comes from, the
    /// device, never a second name for the row's own title; the asides
    /// switch's says what it changes, never the Aa sheet's section name.
    func testTheVoiceListsEyebrowsSayWhereAndWhat() {
        XCTAssertEqual(ListeningCopy.systemVoiceHeader, "This \(DeviceNoun.device)")
        XCTAssertEqual(ListeningCopy.readingAloudHeader, "Reading aloud")
        XCTAssertNotEqual(ListeningCopy.readingAloudHeader, "Reading", "the Aa sheet's section with another switch")
        for header in [ListeningCopy.systemVoiceHeader, ListeningCopy.readingAloudHeader] {
            XCTAssertNotEqual(header, ListeningCopy.naturalVoicesHeader)
            XCTAssertFalse(header.localizedCaseInsensitiveContains("built-in"), header)
            XCTAssertFalse(header.hasSuffix("."), "an eyebrow is a label: \(header)")
        }
    }

    // MARK: - R4-28: the Licenses copy (the Mac's credits read it too)

    /// Typographic and consistent: the sign after every Copyright, each
    /// license by its name, and no note repeating the address its card's
    /// Source row links.
    func testTheLicensesCopyIsTypographicAndConsistent() throws {
        let sherpa = try XCTUnwrap(LicensesView.entries.first { $0.id == "sherpa-onnx" })
        XCTAssertEqual(sherpa.detail, "On-device neural text-to-speech runtime by the k2\u{2011}fsa project. "
                       + "Copyright \u{00A9} the sherpa-onnx contributors.")
        let espeak = try XCTUnwrap(LicensesView.entries.first { $0.id == "espeak-ng" })
        XCTAssertEqual(espeak.license, "GNU General Public License 3.0")
        XCTAssertEqual(espeak.textResource, "espeak-ng-GPL-3.0", "the bundled text keeps its file")
        XCTAssertTrue(espeak.detail.hasSuffix("links the espeak-ng library via sherpa-onnx; its source is linked below."),
                      espeak.detail)
        for entry in LicensesView.entries {
            XCTAssertFalse(entry.license.contains("-3.0") || entry.license.hasPrefix("GPL"),
                           "\(entry.id): a license by its name, not its SPDX id")
            XCTAssertFalse(entry.detail.contains(LicensesCopy.shortForm(of: entry.source)),
                           "\(entry.id): the address is its Source row's alone")
            XCTAssertEqual(entry.detail.components(separatedBy: "Copyright").count,
                           entry.detail.components(separatedBy: "Copyright \u{00A9} ").count,
                           "\(entry.id): a copyright without its sign")
        }
    }

    // MARK: - Helpers

    private static let width: CGFloat = 390

    /// A point well inside preset `index` (0 is 1×), at 2x: the presets
    /// share the row inside the sheet gutters, xs apart, under the
    /// controls' xs top padding; 5 pt in from the chip's leading edge,
    /// clear of its 1.5 pt edge and of its centred label, at mid-height.
    private static func inside(chip index: Int) -> (x: Int, y: Int) {
        let count = CGFloat(SpeedScale.presets.count)
        let chip = (width - 2 * Theme.Space.sheetGutter - (count - 1) * Theme.Space.xs) / count
        let x = Theme.Space.sheetGutter + CGFloat(index) * (chip + Theme.Space.xs) + 5
        let y = Theme.Space.xs + 22
        return (Int(x * 2), Int(y * 2))
    }

    private func render<V: View>(_ view: V, width: CGFloat?) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let width { renderer.proposedSize = ProposedViewSize(width: width, height: nil) }
        return renderer.cgImage
    }

    private func assertColor(_ got: [Double], _ want: [Double], _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            XCTAssertEqual(got[channel], want[channel], accuracy: 0.02, "\(message): \(got) vs \(want)",
                           file: file, line: line)
        }
    }

    /// WCAG contrast of two gamma-encoded sRGB colours.
    private static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ c: [Double]) -> Double {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
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

        /// Opaque pixels only (premultiplied, so a clear one reads black).
        func rgb(at point: (x: Int, y: Int)) -> [Double] {
            let index = (min(point.y, height - 1) * width + min(point.x, width - 1)) * 4
            return (0..<3).map { Double(bytes[index + $0]) / 255 }
        }
    }
}
