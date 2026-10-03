import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import Aloud

/// RGBA8 sRGB pixels of a SwiftUI view or an image, read in memory: covers
/// and lock-screen art are measured as drawn, with no window, screen or
/// simulator screenshot. Row 0 is the top. P4-art's helper for this wave.
@MainActor
struct RenderedPixels {
    let width: Int
    let height: Int
    /// Premultiplied RGBA, 4 bytes per pixel, row-major from the top-left.
    let bytes: [UInt8]

    /// `view` framed at `size` points and rendered at `scale`, read straight
    /// from the renderer's bitmap (the same one its platform image wraps).
    init?(_ view: some View, size: CGSize, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }

    /// `image`'s bitmap. (UIImage's `cgImage`: the seam has no accessor for
    /// a platform image's bitmap yet.)
    init?(image: PlatformImage) {
        guard let cgImage = image.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }

    /// `cgImage` redrawn into an RGBA8 sRGB context so every source format
    /// reads the same way.
    init?(cgImage: CGImage) {
        guard cgImage.width > 0, cgImage.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// The pixel at (`x`, `y`), counted from the top-left.
    func rgba(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "(\(x), \(y)) is outside \(width)×\(height)")
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    /// The largest difference in any channel of any pixel; Int.max when the
    /// two renders differ in size.
    func maxChannelDifference(to other: RenderedPixels) -> Int {
        guard width == other.width, height == other.height else { return Int.max }
        var largest = 0
        for i in bytes.indices {
            let difference = abs(Int(bytes[i]) - Int(other.bytes[i]))
            if difference > largest { largest = difference }
        }
        return largest
    }

    /// The largest channel difference within row `y`; Int.max when the
    /// sizes differ.
    func maxChannelDifference(to other: RenderedPixels, row y: Int) -> Int {
        guard width == other.width, height == other.height else { return Int.max }
        var largest = 0
        for i in (y * width * 4)..<((y + 1) * width * 4) {
            let difference = abs(Int(bytes[i]) - Int(other.bytes[i]))
            if difference > largest { largest = difference }
        }
        return largest
    }

    /// An opaque, solid `rgb` (0xRRGGBB) image of `size` pixels at scale 1:
    /// a stand-in PDF page whose every pixel is known.
    static func solidImage(rgb: UInt32, size: CGSize) -> PlatformImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let color = UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                            green: CGFloat((rgb >> 8) & 0xFF) / 255,
                            blue: CGFloat(rgb & 0xFF) / 255,
                            alpha: 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// `cgImage` as PNG bytes, through ImageIO rather than either platform's
    /// image type: equal bitmaps give equal bytes.
    static func pngData(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Whether `pixel`'s colour is `rgb` (0xRRGGBB) within `tolerance` per channel.
    static func matches(_ pixel: (r: Int, g: Int, b: Int, a: Int), rgb: UInt32, tolerance: Int) -> Bool {
        abs(pixel.r - Int((rgb >> 16) & 0xFF)) <= tolerance
            && abs(pixel.g - Int((rgb >> 8) & 0xFF)) <= tolerance
            && abs(pixel.b - Int(rgb & 0xFF)) <= tolerance
    }
}
