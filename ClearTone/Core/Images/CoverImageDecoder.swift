import Foundation
import ImageIO

/// Decode only the requested thumbnail, without materializing a full-resolution bitmap.
enum CoverImageDecoder {
    static func decode(_ data: Data, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, maxPixelSize > 0 else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }.value
    }

    static func cacheKey(url: URL, pixels: Int) -> String {
        "\(url.absoluteString)@\(pixels)"
    }
}
