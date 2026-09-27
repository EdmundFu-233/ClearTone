import SwiftUI

/// 倍速 + 睡眠定时器菜单。
///
/// 两个功能放一个菜单里，因为它们都是「播放参数」而不是「导航」，
/// 而且都用频率很低 —— 各占一个播放栏图标位不值。
///
/// 倍速在非 1.0x 时给播放栏加一个倍率徽标，睡眠定时器在倒计时中
/// 显示剩余时间 —— 否则设完之后就没有任何可见反馈，用户会以为没生效。
struct PlaybackUtilitiesMenu: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    /// 睡眠定时器档位。与网易云一致给常用值，不做连续输入。
    private static let sleepMinutes: [Double] = [15, 30, 45, 60, 90, 120]

    var body: some View {
        Menu {
            Section("倍速") {
                ForEach(PlayerController.availableRates, id: \.self) { rate in
                    Button {
                        player.setPlaybackRate(rate)
                    } label: {
                        // 勾选而不是高亮：和系统播放器一致
                        if abs(player.playbackRate - rate) < 0.01 {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
            }

            Divider()

            Section("睡眠定时器") {
                if player.sleepTimerEndDate != nil {
                    Button("取消（剩余 \(Self.remainingLabel(player.sleepTimerRemaining))）") {
                        player.cancelSleepTimer()
                    }
                }
                ForEach(Self.sleepMinutes, id: \.self) { minutes in
                    Button("\(Int(minutes)) 分钟后暂停") {
                        player.setSleepTimer(minutes: minutes)
                    }
                }
            }
        } label: {
            // 有非默认状态时给出可见反馈
            if player.sleepTimerEndDate != nil {
                HStack(spacing: 3) {
                    Image(systemName: "moon.zzz.fill")
                    Text(Self.remainingLabel(player.sleepTimerRemaining))
                        .font(.caption2)
                        .monospacedDigit()
                }
            } else if player.isRateAdjusted {
                Text(player.playbackRateLabel)
                    .font(.caption)
                    .monospacedDigit()
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(
            (player.isRateAdjusted || player.sleepTimerEndDate != nil)
                ? CTColors.accent(for: colorScheme)
                : CTColors.textSecondary(for: colorScheme)
        )
        .frame(width: 44)
        .fixedSize()
        .help("倍速与睡眠定时器")
    }

    private func rateLabel(_ rate: Float) -> String {
        abs(rate - 1.0) < 0.01 ? "正常 (1×)" : PlayerController.rateLabel(rate)
    }

    /// 「1 小时 5 分」/「12 分 30 秒」/「45 秒」
    static func remainingLabel(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(secs)秒" }
        return "\(secs)秒"
    }
}
