import SwiftUI
import WidgetKit

struct QuickEntry: Identifiable, Sendable {
    let link: ClearToneDeepLink
    let title: String
    let shortTitle: String
    let subtitle: String
    let symbol: String

    var id: String { link.rawValue }

    static let all: [QuickEntry] = [
        QuickEntry(link: .discover, title: "发现", shortTitle: "发现", subtitle: "每日推荐、歌单与榜单", symbol: "sparkles"),
        QuickEntry(link: .search, title: "搜索", shortTitle: "搜索", subtitle: "歌曲、歌手、专辑、歌单", symbol: "magnifyingglass"),
        QuickEntry(link: .library, title: "资料库", shortTitle: "资料库", subtitle: "喜欢、最近播放与本地音乐", symbol: "music.note.list"),
        QuickEntry(link: .nowPlaying, title: "正在播放", shortTitle: "播放", subtitle: "播放器、歌词与队列", symbol: "play.circle.fill")
    ]
}

struct ClearToneEntry: TimelineEntry {
    let date: Date
}

struct ClearToneWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClearToneEntry {
        ClearToneEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClearToneEntry) -> Void) {
        completion(ClearToneEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClearToneEntry>) -> Void) {
        let now = Date()
        let nextMidnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3_600)
        completion(Timeline(entries: [ClearToneEntry(date: now)], policy: .after(nextMidnight)))
    }
}

struct ClearToneQuickEntryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClearToneQuickEntry", provider: ClearToneWidgetProvider()) { entry in
            ClearToneWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("澄音快捷入口")
        .description("一键打开发现、搜索、资料库与正在播放。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ClearToneWidgets: WidgetBundle {
    var body: some Widget {
        ClearToneQuickEntryWidget()
    }
}

private struct ClearToneWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ClearToneEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                MediumWidgetView()
            case .systemLarge:
                LargeWidgetView(date: entry.date)
            default:
                SmallWidgetView()
            }
        }
        .widgetURL(ClearToneDeepLink.discover.url)
    }
}

private struct SmallWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                WidgetBrandMark(size: 20)
                Text("澄音")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)],
                spacing: 7
            ) {
                ForEach(QuickEntry.all) { entry in
                    WidgetTile(entry: entry, compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumWidgetView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    WidgetBrandMark(size: 24)
                    Text("澄音")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text("把喜欢的声音\n放在桌面")
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetTheme.secondaryText)
                    .lineSpacing(3)
                    .padding(.top, 3)
                Spacer(minLength: 4)
                Text("CLEARTONE")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(width: 112, alignment: .leading)

            WidgetDivider()

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(QuickEntry.all) { entry in
                    WidgetTile(entry: entry)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LargeWidgetView: View {
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                WidgetBrandMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("澄音")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("CLEARTONE")
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                Text(date, format: .dateTime.month(.abbreviated).day().weekday(.abbreviated))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetTheme.secondaryText)
            }

            Text("今天想听点什么？")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)],
                spacing: 9
            ) {
                ForEach(QuickEntry.all) { entry in
                    WidgetCard(entry: entry)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text("登录网易云后，发现与资料库会显示你的内容")
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview(as: .systemSmall) {
    ClearToneQuickEntryWidget()
} timeline: {
    ClearToneEntry(date: .now)
}

#Preview(as: .systemMedium) {
    ClearToneQuickEntryWidget()
} timeline: {
    ClearToneEntry(date: .now)
}

#Preview(as: .systemLarge) {
    ClearToneQuickEntryWidget()
} timeline: {
    ClearToneEntry(date: .now)
}
