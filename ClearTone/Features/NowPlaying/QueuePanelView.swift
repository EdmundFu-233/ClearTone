import SwiftUI

/// 队列侧面板
struct QueuePanelView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(L10n.Common.queue)
                    .font(CTTypography.sectionTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                Spacer()
                Text("\(player.queue.count) 首")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                Button(action: { player.clearQueue() }) {
                    Image(systemName: "trash")
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
                .help("清空队列")
                Button(action: { appState.showQueue = false }) {
                    Image(systemName: "xmark")
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(CTSpacing.lg)

            Divider()

            // 队列列表
            if player.queue.isEmpty {
                EmptyStateView(icon: "list.bullet", title: "队列为空", message: "添加歌曲开始播放")
            } else {
                List {
                    ForEach(player.queue.items) { item in
                        QueueItemRow(
                            item: item,
                            isCurrent: item.id == player.queue.currentItem?.id,
                            onPlay: { player.jumpTo(itemID: item.id) },
                            onRemove: { player.removeFromQueue(itemID: item.id) }
                        )
                    }
                    .onMove { from, to in
                        // 走 controller 统一入口：保持 currentItem 稳定 + 持久化
                        player.moveQueueItems(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 320)
        .background(CTColors.panel(for: colorScheme))
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let onPlay: () -> Void
    let onRemove: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: CTSpacing.sm) {
            // 当前播放指示
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(CTColors.accent(for: colorScheme))
                    .frame(width: 16)
            } else {
                Spacer().frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(
                        isCurrent ? CTColors.accent(for: colorScheme) :
                        (item.song.isPlayable ? CTColors.textPrimary(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
                    )
                    .lineLimit(1)

                Text(item.song.artistNames)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    .lineLimit(1)
            }

            Spacer()

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, CTSpacing.xs)
        .contentShape(Rectangle())
        // 双击播放，与其它歌曲列表一致（单击留给右键菜单与选中）
        .onTapGesture(count: 2) { onPlay() }
        .onHover { isHovering = $0 }
    }
}
