import Foundation
import PDFKit

/// Loads document cover thumbnails: memory cache → disk cache → regenerate
/// from the PDF. Text books have no thumbnail; their cards draw a
/// typographic cover instead.
final class ThumbnailProvider: @unchecked Sendable {

    static let shared = ThumbnailProvider()

    private let memory = NSCache<NSString, PlatformImage>()

    func thumbnail(for document: LibraryDocument) async -> PlatformImage? {
        guard document.kind == .pdf else { return nil }

        let key = document.id.uuidString as NSString
        if let hit = memory.object(forKey: key) { return hit }

        let fileURL = await DocumentStore.fileURL(for: document)
        let thumbURL = await DocumentStore.thumbnailURL(for: document.id)

        let image = await Task.detached(priority: .utility) { () -> PlatformImage? in
            if let data = try? Data(contentsOf: thumbURL),
               let cached = PlatformImage(data: data) {
                return cached
            }
            guard let pdf = PDFDocument(url: fileURL),
                  let page = pdf.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let width: CGFloat = 480
            let height = bounds.width > 0
                ? width * bounds.height / bounds.width
                : width * 4 / 3
            let rendered = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
            try? rendered.pngDataRepresentation()?.write(to: thumbURL, options: .atomic)
            return rendered
        }.value

        if let image { memory.setObject(image, forKey: key) }
        return image
    }
}
