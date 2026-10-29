import XCTest
import AppKit
@testable import ClearTone

@MainActor
final class CoverImageDecoderTests: XCTestCase {
    private func png(width: Int, height: Int, dpi: Double = 72) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testLargeHighDPIImageDecodesOnlyRequestedPixels() async throws {
        let data = try png(width: 3000, height: 1500, dpi: 300)
        let result = await CoverImageDecoder.decode(data, maxPixelSize: 128)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 64)
        XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, 128 * 128 * 4)
    }

    func testPortraitKeepsAspectRatio() async throws {
        let data = try png(width: 200, height: 400)
        let result = await CoverImageDecoder.decode(data, maxPixelSize: 100)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.width, 50)
        XCTAssertEqual(image.height, 100)
    }

    func testInvalidDataAndSizeReturnNil() async {
        let invalid = await CoverImageDecoder.decode(Data("not an image".utf8), maxPixelSize: 128)
        let invalidSize = await CoverImageDecoder.decode(Data(), maxPixelSize: 0)
        XCTAssertNil(invalid)
        XCTAssertNil(invalidSize)
    }

    func testUnsupportedImageFormatIsRejected() async throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let tiff = try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))
        let result = await CoverImageDecoder.decode(tiff, maxPixelSize: 64)
        XCTAssertNil(result, "TIFF 不在封面格式白名单里，不应交给 ImageIO 解码")
    }

    func testSupportedImageFormatStillDecodes() async throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let result = await CoverImageDecoder.decode(jpeg, maxPixelSize: 64)
        XCTAssertNotNil(result)
    }

    func testOversizedDimensionsAreRejected() async throws {
        let data = try png(width: 12001, height: 1)
        let result = await CoverImageDecoder.decode(data, maxPixelSize: 128)
        XCTAssertNil(result, "超过尺寸上限的图片必须在进入 ImageIO 解码前被拒绝")
    }

    func testExternalImageCacheSeparatesSizes() {
        let url = URL(string: "https://example.com/cover.png")!
        XCTAssertNotEqual(CoverImageDecoder.cacheKey(url: url, pixels: 128),
                          CoverImageDecoder.cacheKey(url: url, pixels: 832))
        XCTAssertEqual(CoverImageDecoder.cacheKey(url: url, pixels: 128),
                       CoverImageDecoder.cacheKey(url: url, pixels: 128))
    }

    func testMacCoverIsEagerBitmapWithoutDrawingCallbacks() async throws {
        let data = try png(width: 512, height: 256)
        let result = await CoverLoader.decode(data, pointSize: 64)
        let image = try XCTUnwrap(result)
        XCTAssertFalse(image.representations.contains { $0 is NSCustomImageRep })
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 128)
        XCTAssertEqual(rep.pixelsHigh, 64)
    }
}
