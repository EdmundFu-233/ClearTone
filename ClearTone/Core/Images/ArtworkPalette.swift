import Foundation
import CoreGraphics

struct ArtworkPalette: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    let colors: [RGB]
    static let fallback = ArtworkPalette(colors: [
        RGB(red: 0.12, green: 0.14, blue: 0.22),
        RGB(red: 0.20, green: 0.13, blue: 0.23),
        RGB(red: 0.10, green: 0.21, blue: 0.25),
        RGB(red: 0.22, green: 0.16, blue: 0.19),
        RGB(red: 0.15, green: 0.17, blue: 0.25)
    ])

    static func extract(from image: CGImage) async -> ArtworkPalette {
        await Task.detached(priority: .utility) {
            let side = 16
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return fallback }
            var sums = Array(repeating: SIMD3<Double>(repeating: 0), count: 5)
            var counts = [Int](repeating: 0, count: 5)
            for y in 0..<side {
                for x in 0..<side {
                    let index = (y * side + x) * 4
                    let alpha = Double(pixels[index + 3]) / 255
                    guard alpha > 0.2 else { continue }
                    let rgb = SIMD3(Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2])) / (255 * alpha)
                    let region = (y < side / 2 ? 0 : 2) + (x < side / 2 ? 0 : 1)
                    sums[region] += rgb
                    counts[region] += 1
                    sums[4] += rgb
                    counts[4] += 1
                }
            }
            let colors = (0..<5).map { region -> RGB in
                guard counts[region] > 0 else { return fallback.colors[region] }
                let rgb = sums[region] / Double(counts[region])
                let peak = max(rgb.x, max(rgb.y, rgb.z))
                // Keep white text readable even on a white or highly saturated cover.
                let scale = peak > 0 ? min(1, 0.32 / peak) : 1
                return RGB(red: max(0.055, rgb.x * scale),
                           green: max(0.055, rgb.y * scale),
                           blue: max(0.065, rgb.z * scale))
            }
            return ArtworkPalette(colors: colors)
        }.value
    }
}
