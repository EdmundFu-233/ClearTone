import SwiftUI

/// 设计系统 Token，统一管理颜色/排版/间距，支持深浅色
public enum CTColors {
    /// 沉浸式页面（正在播放）的**不透明**底色。
    ///
    /// 这一页的文字、进度、控件全是为深色背景设计的（历史上是硬编码 `.white`），
    /// 所以底色必须恒为深色，不能依赖 Metal 背景层是否成功绘制：
    /// 无 Metal 设备、首帧未提交、或浅色封面取色都可能让背景层失效，
    /// 结果就是「白底白字」。把它做成设计系统里的一个常量而不是散在视图里，
    /// 是为了让「这一页永远是深色」成为可检查的约定。
    public static let immersiveBase = Color(red: 0.07, green: 0.07, blue: 0.09)

    // MARK: - 深色主题
    public enum Dark {
        public static let background = Color(hex: 0x111216)
        public static let panel = Color(hex: 0x191B21)
        public static let overlay = Color(hex: 0x22252D)
        public static let textPrimary = Color(hex: 0xF4F4F6)
        public static let textSecondary = Color(hex: 0xA6ABB7)
        public static let accent = Color(hex: 0xEF6A67)
        public static let accentSubtle = Color(hex: 0xEF6A67).opacity(0.15)
    }

    // MARK: - 浅色主题
    public enum Light {
        public static let background = Color(hex: 0xF5F4F1)
        public static let panel = Color(hex: 0xFFFFFF)
        public static let overlay = Color(hex: 0xEEEEEC)
        public static let textPrimary = Color(hex: 0x20232A)
        public static let textSecondary = Color(hex: 0x626976)
        public static let accent = Color(hex: 0xC84045)
        public static let accentSubtle = Color(hex: 0xC84045).opacity(0.12)
    }

    /// 动态颜色，根据 colorScheme 自动切换
    public static func background(for scheme: ColorScheme) -> Color { scheme == .dark ? Dark.background : Light.background }
    public static func panel(for scheme: ColorScheme) -> Color { scheme == .dark ? Dark.panel : Light.panel }
    public static func overlay(for scheme: ColorScheme) -> Color { scheme == .dark ? Dark.overlay : Light.overlay }
    public static func textPrimary(for scheme: ColorScheme) -> Color { scheme == .dark ? Dark.textPrimary : Light.textPrimary }
    public static func textSecondary(for scheme: ColorScheme) -> Color { scheme == .dark ? Dark.textSecondary : Light.textSecondary }
    public static func accent(for scheme: ColorScheme) -> Color { scheme == .dark ? Dark.accent : Light.accent }
    public static func accentSubtle(for scheme: ColorScheme) -> Color { scheme == .dark ? Dark.accentSubtle : Light.accentSubtle }
}

public enum CTTypography {
    public static let pageTitle = Font.system(size: 30, weight: .bold, design: .default)
    public static let sectionTitle = Font.system(size: 20, weight: .semibold, design: .default)
    public static let body = Font.system(size: 14, weight: .regular, design: .default)
    public static let bodyMedium = Font.system(size: 14, weight: .medium, design: .default)
    public static let caption = Font.system(size: 12, weight: .regular, design: .default)
    public static let captionMedium = Font.system(size: 12, weight: .medium, design: .default)
}

public enum CTSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum CTRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 14
}

// MARK: - Color Hex Extension
extension Color {
    public init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - 环境键：当前主题模式
public enum CTThemeMode: String, CaseIterable, Sendable, Codable {
    case system = "跟随系统"
    case dark = "深色"
    case light = "浅色"
}

private struct CTThemeModeKey: EnvironmentKey {
    static let defaultValue: CTThemeMode = .system
}

extension EnvironmentValues {
    public var ctThemeMode: CTThemeMode {
        get { self[CTThemeModeKey.self] }
        set { self[CTThemeModeKey.self] = newValue }
    }
}

/// Shared page heading: a single title, supporting context, and a quiet accent.
struct CTPageHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: CTSpacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(CTColors.accent(for: colorScheme))
                .frame(width: 58, height: 58)
                .background(CTColors.accentSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CTRadius.large))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CTSpacing.xs) {
                Text(title).font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(CTTypography.body)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            Spacer(minLength: 0)
        }
    }
}

/// 关闭按钮：弹窗与浮层的**唯一**关闭入口实现。
///
/// 抽出来是因为它带着两件逐处手写时必然漏掉的事：`accessibilityLabel`
/// 与「最小命中区」—— SF Symbol 的固有尺寸只有约 13pt，低于 16pt 下限。
///
/// 刻意**不**加 `.keyboardShortcut(.cancelAction)`：sheet 本身就是模态窗口，
/// Esc 由 AppKit 的 `cancelOperation:` 收尾，已经能关；再加一个快捷键只会
/// 制造歧义 —— `AddToPlaylistSheet` 里嵌着 `PlaylistNameSheet`（带「取消」+ Esc），
/// 两层模态都声明 `.cancelAction` 时谁先收到是不确定的。
/// 非模态的下拉浮层要用 Esc 的话走 `.onExitCommand`（见 `SearchAssistPanel`）。
struct CTCloseButton: View {
    let onClose: () -> Void
    /// 铺在深色沉浸背景（正在播放页）上时用亮色，其余用次要色
    var onDarkBackground: Bool = false

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(onDarkBackground ? Color.white.opacity(0.8) : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Common.close)
        .help(L10n.Common.close)
    }
}

/// 弹窗页头：标题 + 关闭按钮。sheet 的统一头部长相。
///
/// 深色沉浸背景上的关闭按钮（正在播放页）不放这里 —— 那页是全出血的
/// Metal 背景、没有页头，单独用 `CTCloseButton` 叠在左上角。
struct CTSheetHeader: View {
    let title: String
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: CTSpacing.md) {
            Text(title)
                .font(CTTypography.sectionTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            Spacer(minLength: 0)
            CTCloseButton(onClose: onClose)
        }
        .padding(CTSpacing.lg)
    }
}

/// Liquid Glass is reserved for controls; content retains an opaque reading surface.
private struct CTGlassSurface: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(CTColors.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: radius))
        } else if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

extension View {
    func ctGlassSurface(radius: CGFloat = 16) -> some View {
        modifier(CTGlassSurface(radius: radius))
    }
}

