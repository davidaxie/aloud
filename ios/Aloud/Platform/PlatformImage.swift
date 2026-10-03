import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The one image type the shared code names: covers, thumbnails and the Now
// Playing artwork. (S1)

#if os(iOS)
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

extension PlatformImage {
    /// PNG bytes for the thumbnail cache, or nil when the image has no
    /// bitmap to encode.
    func pngDataRepresentation() -> Data? {
        pngData()
    }
}

@MainActor
extension ImageRenderer {
    /// The rendered view as a platform image, at the renderer's `scale`.
    var platformImage: PlatformImage? {
        uiImage
    }
}
#elseif os(macOS)
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

extension PlatformImage {
    /// PNG bytes for the thumbnail cache, or nil when the image has nothing
    /// to encode. The image is drawn once into an sRGB bitmap at its largest
    /// representation's pixel size, so a PDF page's Retina thumbnail keeps
    /// its pixels and the file carries one known color space, as `pngData()`
    /// gives on the iPhone. (`cgImage(forProposedRect: nil, …)` alone halves
    /// a 2x snapshot and tags it with the display's profile.)
    func pngDataRepresentation() -> Data? {
        let largest = representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        let width = max(largest?.pixelsWide ?? 0, Int(size.width.rounded(.up)))
        let height = max(largest?.pixelsHigh ?? 0, Int(size.height.rounded(.up)))
        guard largest != nil, width > 0, height > 0,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let bitmap = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
    }
}

@MainActor
extension ImageRenderer {
    /// The rendered view as a platform image, at the renderer's `scale`.
    var platformImage: PlatformImage? {
        nsImage
    }
}
#endif
