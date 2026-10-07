import SwiftUI

/// 歌词时间偏移微调。
///
/// 步进 0.1s，覆盖 ±5s。三个原因这么定：
/// - 0.1s 是人耳能分辨的最小 lyric 提前/滞后量，再细没有意义；
/// - ±5s 已经能覆盖「卡拉OK版整体不同步」这种极端情况；
/// - 步进按钮而不是滑杆：滑杆在小控件上很难精确点到 0.1s，
///   而这类调整恰恰需要精确。
///
/// 偏移是**全局**设置（存在 `AppSettings`）：它反映的是音源本身的
/// 普遍时延，不是某一首歌的问题。
struct LyricOffsetControl: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    private static let step: Double = 0.1
    private static let limit: Double = 5.0

    private var offset: Double { settings.settings.lyricOffset }

    var body: some View {
        HStack(spacing: CTSpacing.xs) {
            if isExpanded {
                Button {
                    adjust(by: -Self.step)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(offset <= -Self.limit)
                .help("歌词延后 0.1 秒")

                Text(displayText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(offset == 0
                                     ? CTColors.textSecondary(for: colorScheme)
                                     : CTColors.accent(for: colorScheme))
                    .frame(minWidth: 52)

                Button {
                    adjust(by: Self.step)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(offset >= Self.limit)
                .help("歌词提前 0.1 秒")

                if offset != 0 {
                    Button {
                        adjust(by: -offset)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重置为 0")
                }
            }

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help("歌词偏移：当前 \(displayText)")
            .accessibilityLabel("歌词偏移，当前 \(displayText)")
        }
        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
    }

    private var displayText: String {
        guard abs(offset) >= 0.001 else { return "0.0s" }
        // 正数 = 歌词更早出现
        return offset > 0
            ? String(format: "提前 %.1fs", offset)
            : String(format: "延后 %.1fs", -offset)
    }

    private func adjust(by delta: Double) {
        let next = min(max(offset + delta, -Self.limit), Self.limit)
        // 消除浮点累积误差：0.1 累加会出现 0.30000000000000004
        settings.settings.lyricOffset = (next * 10).rounded() / 10
    }
}
