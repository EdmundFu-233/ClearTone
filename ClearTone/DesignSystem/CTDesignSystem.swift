import SwiftUI

/// 设计系统 Token，统一管理颜色/排版/间距，支持深浅色
public enum CTColors {
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
