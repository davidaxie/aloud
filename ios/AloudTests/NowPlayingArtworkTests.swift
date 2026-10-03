import MediaPlayer
import SwiftUI
import XCTest
@testable import Aloud

/// R22's lock-screen art, rendered and measured: a light 900 px square with
/// the 2:3 cover centred, and a textless variant for compact requests.
/// Render only: nothing here touches the system's now-playing state, its
/// remote commands or audio.
@MainActor
final class NowPlayingArtworkTests: XCTestCase {

    /// Theme.bgTint in the light palette.
    private static let lightGround: UInt32 = 0xF3EDE1

    private func renderLarge(_ title: String, _ author: String?, page: PlatformImage? = nil) throws -> PlatformImage {
        try XCTUnwrap(NowPlayingArtwork.image(title: title, author: author, page: page), "large render")
    }

    private func renderSmall(_ title: String, _ author: String?) throws -> PlatformImage {
        try XCTUnwrap(NowPlayingArtwork.image(title: title, author: author, page: nil,
                                              side: NowPlayingArtwork.smallSide), "small render")
    }

    private func pixels(_ image: PlatformImage) throws -> RenderedPixels {
        try XCTUnwrap(RenderedPixels(image: image), "pixels")
    }

    func testTheArtIsANineHundredPixelSquare() throws {
        let image = try renderLarge("Pride and Prejudice", "Jane Austen")
        XCTAssertEqual(image.size, CGSize(width: 300, height: 300))
        XCTAssertEqual(image.scale, 3)
        XCTAssertEqual(image.cgImage?.width, 900)
        XCTAssertEqual(image.cgImage?.height, 900)
    }

    /// The compact art's cover is 51pt wide: ground and rule, no title.
    func testTheSmallArtIsTextless() throws {
        let pride = try renderSmall("Pride and Prejudice", "Jane Austen")
        let cask = try renderSmall("The Cask of Amontillado", "Edgar Allan Poe")
        XCTAssertEqual(pride.cgImage?.width, 288)
        XCTAssertEqual(pride.cgImage?.height, 288)
        XCTAssertLessThanOrEqual(try pixels(pride).maxChannelDifference(to: try pixels(cask)), 1)
    }

    /// The square is the light palette whatever the phone's appearance: the
    /// corners and the strip above the cover are bgTint's light value.
    func testTheGroundIsLightEvenInDarkMode() throws {
        let plain = try renderLarge("Pride and Prejudice", "Jane Austen")
        var darkRender: PlatformImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            darkRender = NowPlayingArtwork.image(title: "Pride and Prejudice", author: "Jane Austen", page: nil)
        }
        let dark = try XCTUnwrap(darkRender)
        // The renderer ignores the current traits, so the case that proves
        // the pin is a dark SwiftUI environment around the view.
        let darkEnvironment = try XCTUnwrap(RenderedPixels(
            NowPlayingArtworkView(title: "Pride and Prejudice", author: "Jane Austen", page: nil)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 300, height: 300), scale: 3))
        for (name, rendered) in [("plain", try pixels(plain)), ("dark traits", try pixels(dark)),
                                 ("dark environment", darkEnvironment)] {
            for (x, y) in [(6, 6), (893, 6), (6, 893), (893, 893), (450, 30)] {
                let pixel = rendered.rgba(x: x, y: y)
                XCTAssertTrue(RenderedPixels.matches(pixel, rgb: Self.lightGround, tolerance: 2),
                              "\(name) (\(x), \(y)) is \(pixel)")
            }
        }
    }

    /// A PDF page fills the cover, centred, at 2:3 once the 1pt border
    /// (3 px a side) is counted back in.
    func testAPageIsCentredAtTwoByThree() throws {
        let red = RenderedPixels.solidImage(rgb: 0xFF0000, size: CGSize(width: 480, height: 720))
        let rendered = try pixels(try renderLarge("Doc", nil, page: red))
        func isRed(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
        let row = (0..<rendered.width).filter { isRed(rendered.rgba(x: $0, y: rendered.height / 2)) }
        let column = (0..<rendered.height).filter { isRed(rendered.rgba(x: rendered.width / 2, y: $0)) }
        let rowStart = try XCTUnwrap(row.first), rowEnd = try XCTUnwrap(row.last)
        let columnStart = try XCTUnwrap(column.first), columnEnd = try XCTUnwrap(column.last)
        XCTAssertEqual(row.count, rowEnd - rowStart + 1, "one red span across")
        XCTAssertEqual(column.count, columnEnd - columnStart + 1, "one red span down")
        XCTAssertEqual(Double(rowStart + rowEnd) / 2, 449.5, accuracy: 1.5)
        XCTAssertEqual(Double(columnStart + columnEnd) / 2, 449.5, accuracy: 1.5)
        XCTAssertEqual(Double(row.count + 6) / Double(column.count + 6), 0.667, accuracy: 0.01)
    }

    func testTheLargeArtCarriesTheTitle() throws {
        let pride = try pixels(try renderLarge("Pride and Prejudice", "Jane Austen"))
        let cask = try pixels(try renderLarge("The Cask of Amontillado", "Edgar Allan Poe"))
        XCTAssertGreaterThan(pride.maxChannelDifference(to: cask), 64)
    }

    /// Requests under 150pt get the textless render, the rest the full one.
    func testTheArtworkServesTheTextlessRenderToSmallRequests() throws {
        let large = try renderLarge("Pride and Prejudice", "Jane Austen")
        let small = try renderSmall("Pride and Prejudice", "Jane Austen")
        let artwork = NowPlayingArtwork.artwork(large: large, small: small)
        XCTAssertEqual(artwork.bounds.size, large.size)
        XCTAssertTrue(artwork.image(at: CGSize(width: 40, height: 40)) === small)
        XCTAssertTrue(artwork.image(at: CGSize(width: 149, height: 149)) === small)
        XCTAssertTrue(artwork.image(at: CGSize(width: 150, height: 150)) === large)
        XCTAssertTrue(artwork.image(at: CGSize(width: 300, height: 300)) === large)
    }

    /// Opt-in: writes the art and a 72 px Dynamic Island compact preview for
    /// a human to look at. Set ALOUD_SHOTS_DIR to a writable folder.
    func testWritesTheArtForReviewWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["ALOUD_SHOTS_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set ALOUD_SHOTS_DIR to write artwork.png and its compact preview")
        }
        let large = try renderLarge("Pride and Prejudice", "Jane Austen")
        let small = try renderSmall("Pride and Prejudice", "Jane Austen")
        // The compact Island asks for about 24pt: 72 px at 3x.
        let compactSource = try XCTUnwrap(NowPlayingArtwork.artwork(large: large, small: small)
            .image(at: CGSize(width: 24, height: 24)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let compact = UIGraphicsImageRenderer(size: CGSize(width: 72, height: 72), format: format).image { _ in
            compactSource.draw(in: CGRect(x: 0, y: 0, width: 72, height: 72))
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(large.pngDataRepresentation()).write(to: folder.appendingPathComponent("artwork.png"))
        try XCTUnwrap(compact.pngDataRepresentation()).write(to: folder.appendingPathComponent("artwork-compact-72.png"))
    }
}
