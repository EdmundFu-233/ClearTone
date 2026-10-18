import XCTest

/// 封面按显示尺寸拼 `?param=WxH` 的逻辑：直接决定下载体积（实测原图 307KB / 80px 3.7KB）
@MainActor
final class CoverImageTests: XCTestCase {

    private let neteaseCover = URL(string: "https://p4.music.126.net/iAwVf8ag_45csIUuh1wSZg==/109951168912558470.jpg")!

    func testNeteaseCoverGetsSizeParam() {
        let sized = CoverLoader.sizedURL(neteaseCover, pointSize: 100)
        let items = URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // 100pt × 2 屏密度 = 200px
        XCTAssertEqual(items.first { $0.name == "param" }?.value, "200y200")
    }

    func testSmallSizeIsClampedToLowerBound() {
        // 列表行 40pt → 80px；再小也不低于 64，避免请求过小反而模糊
        let sized = CoverLoader.sizedURL(neteaseCover, pointSize: 10)
        let items = URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "param" }?.value, "64y64")
    }

    func testLargeSizeIsClampedToUpperBound() {
        let sized = CoverLoader.sizedURL(neteaseCover, pointSize: 5000)
        let items = URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "param" }?.value, "1200y1200")
    }

    func testExistingParamIsReplacedNotDuplicated() {
        let withParam = URL(string: "https://p1.music.126.net/abc/1099.jpg?param=50y50")!
        let sized = CoverLoader.sizedURL(withParam, pointSize: 100)
        let items = URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "param" }.count, 1)
        XCTAssertEqual(items.first { $0.name == "param" }?.value, "200y200")
    }

    func testOtherQueryItemsArePreserved() {
        let signed = URL(string: "https://p3.music.126.net/abc/1099.jpg?imageViewType=1")!
        let sized = CoverLoader.sizedURL(signed, pointSize: 100)
        let items = URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "imageViewType" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "param" }?.value, "200y200")
    }

    func testNonNeteaseHostLeftUntouched() {
        // 本地文件 / 其他图床不能拼网易云的裁剪参数
        let local = URL(string: "file:///Users/x/cover.png")!
        XCTAssertEqual(CoverLoader.sizedURL(local, pointSize: 100), local)
    }

    func testClampedHelper() {
        XCTAssertEqual(5.clamped(to: 64...1200), 64)
        XCTAssertEqual(5000.clamped(to: 64...1200), 1200)
        XCTAssertEqual(300.clamped(to: 64...1200), 300)
    }

    // MARK: - 尺寸量化
    //
    // 正在播放页封面尺寸随窗口实时变化；不量化时每个像素级变化都会生成一个
    // 不同的 `?param=WxH`（一次窗口拖拽可产生上百次下载/解码/缓存条目）。

    func testQuantizedPointSizeRoundsUpToGrid() {
        XCTAssertEqual(CoverLoader.quantizedPointSize(64), 64, "网格点上保持不变")
        XCTAssertEqual(CoverLoader.quantizedPointSize(65), 96, "向上量化到下一个 32pt 网格")
        XCTAssertEqual(CoverLoader.quantizedPointSize(100), 128)
        XCTAssertEqual(CoverLoader.quantizedPointSize(400), 416)
    }

    func testQuantizedPointSizeClampsBounds() {
        XCTAssertEqual(CoverLoader.quantizedPointSize(10), 64, "低于下限取下限")
        XCTAssertEqual(CoverLoader.quantizedPointSize(5000), 1200, "高于上限取上限")
    }

    func testQuantizedPointSizeIsStableWithinBucket() {
        // 同一网格内的微小变化必须落到同一个桶，否则缓存会被尺寸抖动冲掉
        XCTAssertEqual(
            CoverLoader.quantizedPointSize(340),
            CoverLoader.quantizedPointSize(352)
        )
    }
}
