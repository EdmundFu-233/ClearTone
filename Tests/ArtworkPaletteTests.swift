import XCTest
import CoreGraphics
@testable import ClearTone

final class ArtworkPaletteTests: XCTestCase {
    private func image(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try XCTUnwrap(context.makeImage())
    }

    func testWhiteArtworkCannotProduceBrightBackground() async throws {
        let source = try image(red: 1, green: 1, blue: 1)
        let palette = await ArtworkPalette.extract(from: source)
        XCTAssertEqual(palette.colors.count, 5)
        for color in palette.colors {
            XCTAssertLessThanOrEqual(color.red, 0.32)
            XCTAssertLessThanOrEqual(color.green, 0.32)
            XCTAssertLessThanOrEqual(color.blue, 0.32)
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            // Include the shader's +0.03 texture contribution in the worst case.
            let luminance = 0.2126 * linear(color.red + 0.03) + 0.7152 * linear(color.green + 0.03) + 0.0722 * linear(color.blue + 0.03)
            XCTAssertGreaterThan(1.05 / (luminance + 0.05), 4.5)
        }
    }

    func testSaturatedCoverRetainsItsHue() async throws {
        let source = try image(red: 1, green: 0, blue: 0)
        let palette = await ArtworkPalette.extract(from: source)
        XCTAssertGreaterThan(palette.colors[0].red, palette.colors[0].green * 3)
        XCTAssertGreaterThan(palette.colors[0].red, palette.colors[0].blue * 3)
    }

    func testTransparentArtworkUsesFallback() async throws {
        let source = try image(red: 1, green: 1, blue: 1, alpha: 0)
        let palette = await ArtworkPalette.extract(from: source)
        XCTAssertEqual(palette, .fallback)
    }

    func testBlackArtworkStillHasVisibleDepth() async throws {
        let source = try image(red: 0, green: 0, blue: 0)
        let palette = await ArtworkPalette.extract(from: source)
        XCTAssertGreaterThan(palette.colors[0].red, 0)
        XCTAssertGreaterThan(palette.colors[0].blue, 0)
    }
}
