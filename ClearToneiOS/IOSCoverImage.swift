import SwiftUI
import UIKit
import ImageIO

struct IOSCover: View {
    let url: URL?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary).overlay { Image(systemName: "music.note").foregroundStyle(.secondary) } }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: "\(url?.absoluteString ?? "")@\(size)") {
            image = nil
            let loaded = await CoverLoader.shared.load(url: url, pointSize: size)
            if !Task.isCancelled { image = loaded }
        }
    }
}

@MainActor
final class CoverLoader {
    static let shared = CoverLoader()
    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private init() {
        memory.countLimit = 120
        memory.totalCostLimit = 48 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }
    func load(url: URL?, pointSize: CGFloat) async -> UIImage? {
        guard let url else { return nil }
        let pixels = min(1800, max(96, Int(pointSize * 3)))
        let key = "\(url.absoluteString)@\(pixels)" as NSString
        if let image = memory.object(forKey: key) { return image }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host?.hasSuffix("music.126.net") == true {
            components?.scheme = "https"
            var query = components?.queryItems ?? []
            query.removeAll { $0.name == "param" }
            query.append(URLQueryItem(name: "param", value: "\(pixels)y\(pixels)"))
            components?.queryItems = query
        }
        guard let target = components?.url,
              let (data, response) = try? await session.data(from: target),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 15 * 1024 * 1024 else { return nil }
        // ImageIO 在后台下采样，避免列表滚动时在主线程解码原图。
        let image = await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return Optional<UIImage>.none }
            return UIImage(cgImage: thumbnail)
        }.value
        if let image { memory.setObject(image, forKey: key, cost: pixels * pixels * 4) }
        return image
    }
}
