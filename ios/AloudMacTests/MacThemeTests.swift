import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import Aloud

/// The Mac's halves of the theme seam (M5, M18): tokens resolve through an
/// `NSColor` provider with dark and Increase Contrast branches and the
/// iPhone's hex values; the type ramp and the chrome bands have the sizes
/// the PRD names; the reader's faces, rule images and PNG thumbnails come
/// from AppKit; and the iPhone-only modifiers render as no-ops.
final class MacThemeTests: XCTestCase {

    // MARK: R1, R5 · color

    func testPlatformTypesAreAppKits() {
        XCTAssertTrue(PlatformColor.self == NSColor.self)
        XCTAssertTrue(PlatformFont.self == NSFont.self)
        XCTAssertTrue(PlatformImage.self == NSImage.self)
    }

    /// The provider sees Dark Mode end to end: AppKit resolves the color
    /// under each appearance it can draw in.
    func testDynamicColorResolvesItsDarkBranchUnderNSAppearance() throws {
        let color = PlatformColor.dynamicColor { dark, highContrast in
            switch (dark, highContrast) {
            case (false, false): return NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            case (true, false): return NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            case (false, true): return NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            case (true, true): return NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
            }
        }
        assertComponents(try resolve({ color }, under: .aqua), [1, 0, 0, 1], "aqua")
        assertComponents(try resolve({ color }, under: .darkAqua), [0, 0, 1, 1], "darkAqua")
        // A vibrant appearance reads as its light or dark family.
        assertComponents(try resolve({ color }, under: .vibrantDark), [0, 0, 1, 1], "vibrantDark")
    }

    /// Increase Contrast reaches the provider only as a best match: a test
    /// can't build that appearance (`NSAppearance(named:)` hands back plain
    /// Aqua or Dark Aqua for the high-contrast names), so the match itself
    /// is what is pinned.
    func testDynamicColorReadsIncreaseContrastFromTheBestMatch() {
        XCTAssertEqual(PlatformColor.lookNames,
                       [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        let looks: [(NSAppearance.Name?, dark: Bool, highContrast: Bool)] = [
            (.aqua, false, false),
            (.darkAqua, true, false),
            (.accessibilityHighContrastAqua, false, true),
            (.accessibilityHighContrastDarkAqua, true, true),
            (nil, false, false),
        ]
        for (name, dark, highContrast) in looks {
            let look = PlatformColor.look(matching: name)
            XCTAssertEqual(look.dark, dark, "\(String(describing: name))")
            XCTAssertEqual(look.highContrast, highContrast, "\(String(describing: name))")
        }
    }

    /// The theme's own tokens, through SwiftUI and back to AppKit as the
    /// reader takes them, keep the iPhone's hex values.
    func testThemeTokensKeepTheirHexValues() throws {
        assertComponents(try resolve({ NSColor(Theme.textMuted) }, under: .aqua), rgb(0x6A5B45), "textMuted light")
        assertComponents(try resolve({ NSColor(Theme.textMuted) }, under: .darkAqua), rgb(0xA99A7C), "textMuted dark")
        assertComponents(try resolve({ NSColor(Theme.bg) }, under: .aqua), rgb(0xFBF8F2), "bg light")
        assertComponents(try resolve({ NSColor(Theme.bg) }, under: .darkAqua), rgb(0x14100A), "bg dark")
        var accentSoftDark = rgb(0xC99A5B)
        accentSoftDark[3] = 0.20
        assertComponents(try resolve({ NSColor(Theme.accentSoft) }, under: .darkAqua), accentSoftDark,
                         "accentSoft dark")
    }

    func testHairlineIsOnePhysicalPixel() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        XCTAssertEqual(PlatformScreen.hairline, 1 / max(scale, 1))
        XCTAssertEqual(Theme.Stroke.hairlineWidth, PlatformScreen.hairline)
    }

    /// A rule is one pixel of the screen it is drawn on, whichever screen
    /// is main (H059): at 1x a bottom-aligned rule (Classics' separators)
    /// is one whole pixel, never rounded away, and at 2x one pixel, not two.
    @MainActor
    func testAHairlineFollowsTheScreenItIsDrawnOn() throws {
        XCTAssertEqual(PlatformScreen.hairline(scale: 1), 1)
        XCTAssertEqual(PlatformScreen.hairline(scale: 2), 0.5)
        XCTAssertEqual(PlatformScreen.hairline(scale: 0), 1, "never wider than a point")
        for scale: CGFloat in [1, 2] {
            let rule = Color.white
                .frame(width: 4, height: 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black).hairlineHeight() }
                .environment(\.displayScale, scale)
            let renderer = ImageRenderer(content: rule)
            renderer.scale = scale
            let rows = try grayRows(of: XCTUnwrap(renderer.cgImage))
            XCTAssertEqual(rows.count, Int(6 * scale), "\(scale)x")
            XCTAssertLessThan(rows[rows.count - 1], 64, "\(scale)x: the bottom pixel row is the rule")
            XCTAssertGreaterThan(rows[rows.count - 2], 191, "\(scale)x: one pixel, not two")
        }
    }

    // MARK: T1 · the type ramp and the chrome bands

    func testRampHasTheMacSizes() {
        let expected: [(Theme.TypeStyle, CGFloat)] = [
            (.display, 26), (.title, 20), (.headline, 15), (.body, 13), (.callout, 12), (.subhead, 11),
            (.footnote, 11), (.caption, 11), (.eyebrow, 11), (.numeral, 28), (.aside, 13),
        ]
        XCTAssertEqual(expected.count, Theme.TypeStyle.allCases.count, "every style has a Mac size")
        for (style, points) in expected {
            XCTAssertEqual(PlatformTypeRamp.basePoints(style), points, "\(style)")
            XCTAssertEqual(PlatformTypeRamp.points(style, scale: .standard), points, "\(style)")
        }
    }

    /// M18's table: body / callout / caption per band.
    func testBandsGrowBodyCalloutAndCaption() {
        let table: [(ChromeScale, [CGFloat], circle: CGFloat, secondRow: Bool)] = [
            (.standard, [13, 12, 11], 44, false),
            (.large, [15, 14, 13], 52, true),
            (.largest, [17, 16, 15], 60, true),
        ]
        XCTAssertEqual(table.map(\.0), ChromeScale.allCases)
        for (scale, sizes, circle, secondRow) in table {
            XCTAssertEqual([.body, .callout, .caption].map { PlatformTypeRamp.points($0, scale: scale) }, sizes,
                           "\(scale)")
            XCTAssertEqual(scale.playCircleDiameter, circle, "\(scale)")
            XCTAssertEqual(scale.chipsOnSecondRow, secondRow, "\(scale)")
        }
    }

    /// 16-21 pt is the standard band, 23-30 large and 35-40 largest.
    func testReaderSizePicksTheBand() {
        XCTAssertEqual(ReaderTextSize.steps.indices.map { ChromeScale(readerStep: $0) },
                       [.standard, .standard, .standard, .standard, .large, .large, .large, .largest, .largest])
        XCTAssertEqual(ChromeScale(readerPoints: 21), .standard)
        XCTAssertEqual(ChromeScale(readerPoints: 23), .large)
        XCTAssertEqual(ChromeScale(readerPoints: 30), .large)
        XCTAssertEqual(ChromeScale(readerPoints: 35), .largest)
        XCTAssertEqual(EnvironmentValues().chromeScale, .standard, "the Library, Classics and Settings")
    }

    /// `Theme.font` reads the ramp on the Mac, with the iPhone styles'
    /// weights and features.
    func testThemeFontReadsTheRamp() {
        for style in Theme.TypeStyle.allCases {
            for scale in ChromeScale.allCases {
                XCTAssertNotNil(PlatformTypeRamp.font(for: style, scale: scale), "\(style) \(scale)")
            }
        }
        XCTAssertEqual(Theme.font(.body), .system(size: 13))
        XCTAssertEqual(Theme.font(.body), Theme.font(.body, scale: .standard))
        XCTAssertEqual(Theme.font(.caption, scale: .largest), .system(size: 15, weight: .medium).monospacedDigit())
        XCTAssertEqual(Theme.font(.display), .custom(Theme.serifFamilyName, fixedSize: 26))
        XCTAssertEqual(Theme.font(.headline, scale: .large),
                       .custom(Theme.serifFamilyName, fixedSize: 17).weight(.semibold))
    }

    @MainActor
    func testReaderStartsAtNineteenPoints() {
        XCTAssertEqual(ReaderTextSize.platformDefaultStep, 2)
        XCTAssertEqual(ReaderTextSize.points(forStep: ReaderTextSize.platformDefaultStep), 19)
    }

    // MARK: R2 · typography

    func testNamedFontIsNSFontByName() throws {
        let font = try XCTUnwrap(PlatformFont.named("Georgia", size: 19))
        XCTAssertEqual(font, NSFont(name: "Georgia", size: 19))
        XCTAssertNil(PlatformFont.named("No Such Face", size: 19))
        XCTAssertTrue(PlatformFont.exists(named: "Georgia"))
        XCTAssertFalse(PlatformFont.exists(named: "No Such Face"))
        XCTAssertEqual(Theme.serifFamilyName,
                       NSFont(name: "Iowan Old Style", size: 17) != nil ? "Iowan Old Style" : "Georgia")
    }

    func testBoldAndItalicStayInTheFamily() throws {
        let georgia = try XCTUnwrap(NSFont(name: "Georgia", size: 19))
        for (derived, trait) in [(PlatformFontTraits.bold(georgia), NSFontDescriptor.SymbolicTraits.bold),
                                 (PlatformFontTraits.italic(georgia), .italic)] {
            let font = try XCTUnwrap(derived)
            XCTAssertEqual(font.pointSize, 19)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(trait))
            XCTAssertEqual(font.familyName, "Georgia")
        }
        let smallCaps = PlatformFontTraits.smallCaps(georgia)
        XCTAssertEqual(smallCaps.familyName, "Georgia")
        XCTAssertEqual(smallCaps.pointSize, 19)
        XCTAssertTrue(ReaderPageStyle.serif(size: 19, bold: true).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(PlatformLegibility.isBold(NSAppearance.currentDrawing()), "macOS has no Bold Text")
    }

    func testRuleImageIsASolidFillOfItsSize() throws {
        let size = CGSize(width: 10, height: 2)
        let image = PlatformRuleImage.make(size: size, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                                           scale: 2)
        XCTAssertEqual(image.size, size)
        let pixels = try sRGBPixels(of: XCTUnwrap(image.pngDataRepresentation()))
        XCTAssertEqual(pixels.count, 10 * 2)
        XCTAssertEqual(Set(pixels), [[255, 0, 0, 255]])
    }

    // MARK: S1 · images

    func testPNGDataRoundTripsThroughTheImageType() throws {
        let image = PlatformRuleImage.make(size: CGSize(width: 4, height: 6), color: .black, scale: 1)
        let png = try XCTUnwrap(image.pngDataRepresentation())
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
        let decoded = try XCTUnwrap(PlatformImage(data: png))
        XCTAssertEqual(decoded.size.width / decoded.size.height, 4.0 / 6, accuracy: 0.01)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(bitmap.colorSpace?.name, CGColorSpace.sRGB, "one known color space, not the display's")
        XCTAssertNil(NSImage(size: CGSize(width: 4, height: 4)).pngDataRepresentation(), "nothing to encode")
    }

    @MainActor
    func testRendererGivesAPlatformImage() throws {
        let renderer = ImageRenderer(content: Theme.bg.frame(width: 30, height: 20))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.platformImage)
        XCTAssertEqual(image.size.width / image.size.height, 1.5, accuracy: 0.01)
        XCTAssertNotNil(image.pngDataRepresentation())
        _ = Image(platformImage: image)
    }

    // MARK: U1, U2 · view modifiers

    @MainActor
    func testIPhoneOnlyModifiersRenderOnTheMac() {
        let views: [AnyView] = [
            AnyView(Text("Listening").inlineTitleOnPhone()),
            AnyView(Text("Play").largeContentViewerIfAvailable()),
            AnyView(Image(systemName: "play.fill").largeContentViewerIfAvailable { Label("Play", systemImage: "play.fill") }),
            AnyView(Text("Licenses").toolbarColorSchemeOnPhone(.dark)),
            AnyView(Text("Library").shelfScrollEdge(rule: true)),
            AnyView(Text("Voice").shelfScrollEdge(ground: Theme.surface)),
            AnyView(Menu("Sleep") { Text("Off") }.menuOrderNearestFirst()),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view.frame(width: 120, height: 60))
            XCTAssertNotNil(renderer.nsImage)
        }
    }

    /// A− or A+ at the 16 or 40 pt limit reads as dead beside the live one
    /// (J028): text against textFaint, as on the iPhone, not the
    /// transport's textMuted, which sits about 1.2:1 from textFaint.
    @MainActor
    func testTheTextSizeStepperShowsItsLimit() throws {
        for scheme: ColorScheme in [.light, .dark] {
            func glyph(enabled: Bool) throws -> [Double] {
                let button = Button {} label: { Rectangle() }
                    .buttonStyle(MacTextStepButtonStyle())
                    .disabled(!enabled)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: button)
                renderer.scale = 1
                return try centerColor(of: XCTUnwrap(renderer.cgImage))
            }
            let live = try glyph(enabled: true), dead = try glyph(enabled: false)
            let ratio = contrast(live, dead)
            XCTAssertGreaterThanOrEqual(ratio, 2, "\(scheme): the limit shows, \(ratio):1")
        }
    }

    // MARK: - Helpers

    /// The center pixel's sRGB components, 0 to 1.
    private func centerColor(of image: CGImage) throws -> [Double] {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (height / 2) * context.bytesPerRow + (width / 2) * 4
        XCTAssertEqual(bytes[offset + 3], 255, "an opaque glyph")
        return (0..<3).map { Double(bytes[offset + $0]) / 255 }
    }

    /// WCAG's contrast ratio between two sRGB colors.
    private func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ c: [Double]) -> Double {
            let linear = c.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// Each pixel row's mean gray (0 black, 255 white), top row first.
    private func grayRows(of image: CGImage) throws -> [Int] {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<height).map { row in
            (0..<width).reduce(0) { $0 + Int(bytes[row * context.bytesPerRow + $1]) } / width
        }
    }

    /// `make()`'s color in sRGB, built and read while `name` is the drawing
    /// appearance (as AppKit resolves a dynamic color when it draws).
    private func resolve(_ make: () -> NSColor, under name: NSAppearance.Name) throws -> [CGFloat] {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var components: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            if let color = make().usingColorSpace(.sRGB) {
                components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            }
        }
        return components
    }

    /// Every pixel of a PNG as 8-bit sRGB RGBA, decoded by Core Graphics.
    /// (`NSBitmapImageRep.colorAt` is not used: its sRGB conversion drifts.)
    private func sRGBPixels(of png: Data) throws -> [[UInt8]] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (width, height) = (image.width, image.height)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<width * height).map { index in (0..<4).map { bytes[index * 4 + $0] } }
    }

    private func rgb(_ hex: UInt32) -> [CGFloat] {
        [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, 1]
    }

    private func assertComponents(_ actual: [CGFloat], _ expected: [CGFloat], _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, 4, "\(label): no sRGB color", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 0.5 / 255, "\(label): \(actual) vs \(expected)", file: file, line: line)
        }
    }
}
