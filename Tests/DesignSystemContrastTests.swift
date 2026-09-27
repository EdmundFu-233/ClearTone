import XCTest
import AppKit
import SwiftUI

/// 设计系统的**可读性不变量**。
///
/// 背景：正在播放页的文字历史上是硬编码 `.white`，可读性完全依赖背景层
/// 恰好画成深色。用户实测在浅色主题下整个页面「白底白字」—— 因为
/// Metal 背景层没画出来时，透出的是 sheet 自己的浅色背景。
///
/// 这里把「沉浸页底色必须深到能承载白字」变成可计算的断言，
/// 防止有人把 `immersiveBase` 调亮、或换成跟随主题的颜色。
final class DesignSystemContrastTests: XCTestCase {

    // MARK: - WCAG 相对亮度与对比度

    /// sRGB 分量 → 线性化（WCAG 2.1 定义）
    private func linearize(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private func relativeLuminance(of color: NSColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// WCAG 对比度，1...21
    private func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = relativeLuminance(of: lhs)
        let b = relativeLuminance(of: rhs)
        let (lighter, darker) = a > b ? (a, b) : (b, a)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func srgb(_ color: Color) -> NSColor { NSColor(color) }

    // MARK: - 沉浸页底色

    /// 白字压在这个底色上必须够清晰。
    /// 取 WCAG AA 正文阈值 4.5 —— 歌词正文是 16pt，虽然按「大字号」标准 3.0
    /// 就能过，但 4.5 留出了余量，也拦得住「只是稍微调亮了一点」的改动。
    func testImmersiveBaseIsDarkEnoughForWhiteText() {
        let ratio = contrastRatio(srgb(CTColors.immersiveBase), .white)
        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            "沉浸页底色与白色的对比度只有 \(ratio):1，白字会看不清"
        )
    }

    /// 底色不能是纯黑：纯黑会让 Metal 背景的暗部糊成一片，失去层次
    func testImmersiveBaseIsNotPureBlack() {
        let luminance = relativeLuminance(of: srgb(CTColors.immersiveBase))
        XCTAssertGreaterThan(luminance, 0.001, "纯黑底会让背景暗部没有层次")
        XCTAssertLessThan(luminance, 0.2, "底色仍然必须偏暗")
    }

    /// 底色必须不透明 —— 半透明会让下层（sheet 背景）漏上来，
    /// 正是「白底白字」的直接成因
    func testImmersiveBaseIsOpaque() {
        // 用 getRed:green:blue:alpha: 而不是 getWhite:alpha: ——
        // SwiftUI 的 Color 落在 sRGB extended 空间里，getWhite: 会直接抛异常
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        srgb(CTColors.immersiveBase).getRed(&r, green: &g, blue: &b, alpha: &alpha)
        XCTAssertEqual(alpha, 1.0, accuracy: 0.0001, "底色必须不透明")
    }

    // MARK: - 主界面文字对比度

    /// 顺带守住主界面的正文对比度（浅色/深色两套主题各测一次）。
    /// 这类断言的价值在于：有人调色板时立刻会红，而不是等用户截图反馈。
    func testPrimaryTextContrastInBothThemes() {
        for (name, background, text) in [
            ("深色", CTColors.background(for: .dark), CTColors.textPrimary(for: .dark)),
            ("浅色", CTColors.background(for: .light), CTColors.textPrimary(for: .light)),
        ] {
            let ratio = contrastRatio(srgb(background), srgb(text))
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(name)主题下正文与背景的对比度只有 \(ratio):1"
            )
        }
    }

    /// 次要文字（字幕、时间戳）用 AA 大字号阈值 3.0 兜底
    func testSecondaryTextContrastInBothThemes() {
        for (name, background, text) in [
            ("深色", CTColors.background(for: .dark), CTColors.textSecondary(for: .dark)),
            ("浅色", CTColors.background(for: .light), CTColors.textSecondary(for: .light)),
        ] {
            let ratio = contrastRatio(srgb(background), srgb(text))
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "\(name)主题下次要文字与背景的对比度只有 \(ratio):1"
            )
        }
    }

    /// 强调色在两种主题下都要能被背景托住（用于链接、选中态、进度条）
    func testAccentContrastInBothThemes() {
        for (name, background) in [
            ("深色", CTColors.background(for: .dark)),
            ("浅色", CTColors.background(for: .light)),
        ] {
            let ratio = contrastRatio(srgb(background), srgb(CTColors.accent(for: name == "深色" ? .dark : .light)))
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "\(name)主题下强调色与背景的对比度只有 \(ratio):1"
            )
        }
    }
}
