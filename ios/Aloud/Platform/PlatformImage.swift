import SwiftUI
#if os(iOS)
import UIKit
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
#endif
