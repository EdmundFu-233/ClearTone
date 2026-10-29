import Foundation
import ImageIO

enum CoverImageDecoder {
    /// 只解码封面实际会用到的格式。
    ///
    /// ImageIO 是系统里最容易吃到不可信数据的组件之一：它支持几十种格式，
    /// 每种都是一个解析器。网易云封面只返回 JPEG / PNG / WebP，本地曲库
    /// 的封面由系统元数据读取后重新编码，也只会是这几种。把 TIFF / RAW /
    /// PSD / BMP 之类排除掉，等于把攻击面从「ImageIO 支持的全部格式」
    /// 缩到「实际使用的少数几个」。
    private static let allowedTypes: Set<String> = [
        "public.jpeg",
        "public.png",
        "org.webmproject.webp",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
    ]

    /// 解码前的像素尺寸上限。
    ///
    /// 封面下载本身已有 15MB 体积限制，但一张 20000×20000 的 PNG 可以只有
    /// 几十 KB（大面积纯色）。`kCGImageSourceThumbnailMaxPixelSize` 会在解码
    /// 阶段缩小，但尺寸解析、整数运算与内存分配发生在更早的步骤，
    /// 超大尺寸正是 ImageIO 整数溢出类漏洞的常见触发条件。
    private static let maximumPixelDimension = 12000

    static func decode(_ data: Data, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, maxPixelSize > 0, data.count <= 32 * 1024 * 1024 else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else { return nil }
            guard let type = CGImageSourceGetType(source) as String?,
                  allowedTypes.contains(type) else { return nil }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0,
                  width <= maximumPixelDimension, height <= maximumPixelDimension else {
                return nil
            }
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
