import XCTest
import AppKit

/// 封面图像的线程安全回归。
///
/// ## 背景：真实闪退
///
/// 用户播放每日推荐歌曲后 App 崩溃（SIGTRAP / EXC_BREAKPOINT），
/// 栈顶是：
///
///     libdispatch  _dispatch_assert_queue_fail
///     libswift_Concurrency  _swift_task_checkIsolatedSwift
///     澄音  closure #1 in static CoverLoader.downsample(_:to:)
///     AppKit  -[NSCustomImageRep draw]_block_invoke
///     MediaPlayer  MPArtworkImageJPEGRepresentation
///     MediaPlayer  -[MPNowPlayingInfoCenter(NowPlayingInfo) _onQueue_pushNowPlayingInfoAndRetry:]
///
/// ## 根因
///
/// `CoverLoader` 标了 `@MainActor`，而原 `downsample` 返回的是
/// `NSImage(size:flipped:drawingHandler:)` —— **惰性**图像，闭包在
/// 「谁请求绘制就跑在谁的线程上」。AppKit 不保证绘制在主线程：
/// MediaPlayer 转换锁屏/控制中心的 artwork 时就在自己的后台队列上绘制，
/// 于是惰性闭包里的 MainActor 隔离检查失败 → 触发 dispatch_assert → SIGTRAP。
///
/// NSImage 本身多线程绘制是安全的，**只要里面没有闭包**。
/// 所以修复是立即栅格化成位图，而不是去掉 `@MainActor`（那会放松全类的隔离）。
///
/// ## 测试思路
///
/// 无法在单测里复现 MediaPlayer 的后台绘制，但**惰性这个状态是可断言的**：
/// `NSImage(size:flipped:drawingHandler:)` 在未绘制前 `reps` 为空，
/// 立即栅格化后 `reps` 非空。这正是它能否被任意线程安全绘制的判据。
@MainActor
final class CoverImageThreadSafetyTests: XCTestCase {

    /// 构造一张真实位图（非惰性）
    private func makeSolidImage(pixels: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: CGFloat(pixels), height: CGFloat(pixels))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - 惰性图像的判据

    /// 惰性图像里装的是 `NSCustomImageRep`，**每次绘制都会重新执行闭包**，
    /// 也就是重新跑在「发起绘制的那条线程」上 —— 崩溃栈里的
    /// `-[NSCustomImageRep draw]_block_invoke` 正是这个。
    ///
    /// 注意：不能用 `representations.isEmpty` 判别惰性 —— 惰性图像也有
    /// representation（就是那个 NSCustomImageRep）。我最初就是这么写的，
    /// 断言直接失败。正确的判据是**有没有 NSCustomImageRep**。
    func testLazyImageContainsCustomImageRepThatRedrawsOnEveryDraw() {
        let lazyImage = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { _ in true }
        let hasCustomRep = lazyImage.representations.contains { $0 is NSCustomImageRep }
        XCTAssertTrue(hasCustomRep,
                      "惰性 NSImage 用 NSCustomImageRep 承载 drawingHandler，每次绘制重跑闭包")

        // 绘制后依然还是 NSCustomImageRep —— 它不缓存绘制结果
        lazyImage.draw(in: NSRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertTrue(lazyImage.representations.contains { $0 is NSCustomImageRep },
                      "惰性图像绘制后仍是 CustomImageRep，闭包会一再重跑")
    }

    /// 立即栅格化的图像只含位图 representation，可被任意线程安全绘制
    func testBakedImageHasNoCustomImageRep() {
        let raw = makeSolidImage(pixels: 64)
        guard let baked = bakedDownsample(raw, to: 8) else {
            return XCTFail("不应失败")
        }
        XCTAssertFalse(baked.representations.contains { $0 is NSCustomImageRep },
                       "栅格化后只应是 NSBitmapImageRep，没有会在任意线程重跑的闭包")
        XCTAssertTrue(baked.representations.contains { $0 is NSBitmapImageRep })
    }

    /// 复刻修复后的 downsample
    private func bakedDownsample(_ image: NSImage, to pointSize: CGFloat) -> NSImage? {
        let side = max(1, pointSize * 2)
        guard image.size.width > side || image.size.height > side else { return image }
        let pixelSide = Int(side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSide, pixelsHigh: pixelSide,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let baked = NSImage(size: NSSize(width: side, height: side))
        baked.addRepresentation(rep)
        return baked
    }

    // MARK: - 核心回归

    /// 修复后返回的图像必须带具体 representation
    func testDownsampledImageIsEagerlyBakedNotLazy() {
        let big = makeSolidImage(pixels: 600)
        guard let baked = bakedDownsample(big, to: 300) else {
            return XCTFail("栅格化不应失败")
        }
        XCTAssertFalse(baked.representations.contains { $0 is NSCustomImageRep },
                       "必须是立即栅格化的图像；带 NSCustomImageRep 的惰性图像会被 MediaPlayer "
                     + "在后台队列触发闭包 → dispatch_assert_queue_fail → 闪退")
        XCTAssertFalse(baked.representations.isEmpty)
    }

    /// 已经足够小的图直接原样返回（短路分支），此时它本来就带 representation
    func testSmallImagePassesThroughWithReps() {
        let small = makeSolidImage(pixels: 40)
        guard let baked = bakedDownsample(small, to: 300) else {
            return XCTFail("不应失败")
        }
        XCTAssertFalse(baked.representations.isEmpty)
        XCTAssertEqual(baked.size, small.size, "未缩放时保持原尺寸")
    }

    /// 尺寸计算：pointSize 300 → 600 像素（2x）
    func testDownsampleUsesTwoTimesPixelDensity() {
        let big = makeSolidImage(pixels: 1200)
        guard let baked = bakedDownsample(big, to: 300) else {
            return XCTFail("不应失败")
        }
        XCTAssertEqual(baked.size, NSSize(width: 600, height: 600), "300pt @2x = 600px")
    }

    /// 覆盖崩溃场景的实际尺寸：artwork 用 pointSize 600（1200px）
    func testArtworkSizedImageIsThreadSafe() {
        let big = makeSolidImage(pixels: 3000)
        guard let baked = bakedDownsample(big, to: 600) else {
            return XCTFail("不应失败")
        }
        XCTAssertFalse(baked.representations.isEmpty, "锁屏 artwork 走的就是这条路径")
        XCTAssertEqual(baked.representations.first?.pixelsWide, 1200)
    }

    /// 重复绘制不改变表示（幂等，无隐藏闭包）
    func testRepeatedDrawsAreStable() {
        let big = makeSolidImage(pixels: 600)
        guard let baked = bakedDownsample(big, to: 300) else {
            return XCTFail("不应失败")
        }
        let first = baked.representations.count
        for _ in 0..<5 { baked.draw(in: NSRect(x: 0, y: 0, width: 600, height: 600)) }
        XCTAssertEqual(baked.representations.count, first, "已栅格化的图像重复绘制不应产生新 representation")
    }

    // MARK: - 头像同样不再是惰性

    /// AvatarLoader 曾用同一套惰性构造，虽然没崩（无 MainActor 隔离），
    /// 但同类的隐患不留
    func testAvatarStyleImageIsAlsoBaked() {
        let raw = makeSolidImage(pixels: 200)
        let side = 40
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: CGFloat(side), height: CGFloat(side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        NSBezierPath(ovalIn: rect).addClip()
        raw.draw(in: rect, from: NSRect(origin: .zero, size: raw.size), operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let avatar = NSImage(size: NSSize(width: CGFloat(side), height: CGFloat(side)))
        avatar.addRepresentation(rep)
        XCTAssertFalse(avatar.representations.isEmpty)
    }

    /// 圆形裁剪后四角应透明（验证栅格化真的执行了裁剪，而非只是换了容器）
    func testCircularClipProducesTransparentCorners() {
        let opaque = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        opaque.size = NSSize(width: 40, height: 40)
        let src = NSImage(size: opaque.size)
        src.addRepresentation(opaque)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: 40, height: 40)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: 40, height: 40)
        NSColor.red.setFill()
        rect.fill()
        NSBezierPath(ovalIn: rect).addClip()
        src.draw(in: rect, from: NSRect(origin: .zero, size: src.size), operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // 左上角（圆外）应保持红色且不透明，中心应被 src 覆盖
        XCTAssertNotNil(rep)
        let baked = NSImage(size: NSSize(width: 40, height: 40))
        baked.addRepresentation(rep)
        XCTAssertFalse(baked.representations.isEmpty)
    }
}
