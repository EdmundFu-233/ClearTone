import SwiftUI
import WidgetKit

enum WidgetTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.20, blue: 0.56),
            Color(red: 0.43, green: 0.25, blue: 0.70)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let tileFill = Color.white.opacity(0.13)
    static let tileStroke = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.72)

    static func tileShape(_ radius: CGFloat = 12) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

struct WidgetBackground: View {
    var body: some View {
        ZStack {
            WidgetTheme.background
            Circle()
                .fill(.white.opacity(0.13))
                .frame(width: 190, height: 190)
                .blur(radius: 46)
                .offset(x: 92, y: -86)
            Circle()
                .fill(Color(red: 0.56, green: 0.31, blue: 0.83).opacity(0.45))
                .frame(width: 170, height: 170)
                .blur(radius: 52)
                .offset(x: -104, y: 104)
        }
    }
}

struct WidgetBrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(WidgetTheme.tileFill, in: WidgetTheme.tileShape(size * 0.32))
            .overlay {
                WidgetTheme.tileShape(size * 0.32)
                    .stroke(WidgetTheme.tileStroke, lineWidth: 0.5)
            }
    }
}

struct WidgetDivider: View {
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.14))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

struct WidgetTile: View {
    let entry: QuickEntry
    var compact = false

    var body: some View {
        Link(destination: entry.link.url) {
            VStack(spacing: compact ? 3 : 4) {
                Image(systemName: entry.symbol)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .frame(height: compact ? 13 : 15)
                Text(compact ? entry.shortTitle : entry.title)
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 6 : 8)
            .background(WidgetTheme.tileFill, in: WidgetTheme.tileShape(compact ? 9 : 12))
            .overlay {
                WidgetTheme.tileShape(compact ? 9 : 12)
                    .stroke(WidgetTheme.tileStroke, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("打开\(entry.title)")
    }
}

struct WidgetCard: View {
    let entry: QuickEntry

    var body: some View {
        Link(destination: entry.link.url) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 22)
                Spacer(minLength: 4)
                Text(entry.title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                Text(entry.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(WidgetTheme.secondaryText)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WidgetTheme.tileFill, in: WidgetTheme.tileShape(14))
            .overlay {
                WidgetTheme.tileShape(14)
                    .stroke(WidgetTheme.tileStroke, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("打开\(entry.title)，\(entry.subtitle)")
    }
}
