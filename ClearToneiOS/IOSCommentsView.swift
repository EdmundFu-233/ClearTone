import SwiftUI

struct IOSCommentsView: View {
    let song: Song
    @StateObject private var store = CommentsStore()
    @EnvironmentObject private var appState: AppState
    var body: some View {
        List {
            Text(song.title).font(.headline)
            Picker("排序", selection: $store.sort) { ForEach(CommentSort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if store.isLoading { ProgressView("正在读取评论…") }
            if let error = store.errorMessage { IOSFailure(message: error) { Task { await store.reload() } } }
            if let error = store.likeError { Text(error).foregroundStyle(.red).font(.footnote) }
            if appState.isLikeWriteCoolingDown {
                IOSWriteCooldownNotice(
                    remaining: appState.likeCooldownRemaining,
                    message: appState.likesWriteError
                )
            }
            ForEach(store.comments) { comment in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        IOSCover(url: comment.avatarURL, size: 32)
                        Text(comment.nickname).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(comment.time, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(comment.content).font(.subheadline).textSelection(.enabled)
                    if let reply = comment.replyToContent { Text("\(comment.replyToNickname ?? "")：\(reply)").font(.caption).foregroundStyle(.secondary) }
                    Button {
                        if appState.canPerformWrite { Task { await store.toggleLike(comment) } }
                        else { appState.isLoginPresented = true }
                    } label: { Label("\(comment.likedCount)", systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup") }
                        .buttonStyle(.borderless)
                        // 限流冷却期间按钮必须变灰：否则点下去什么都不会发生（连请求都不发）
                        .disabled(store.pendingLikeIDs.contains(comment.id) || appState.isLikeWriteCoolingDown)
                }.padding(.vertical, 6)
            }
            if let error = store.paginationError { IOSFailure(message: error) { Task { await store.loadMore() } } }
            if store.hasMore { Button("加载更多评论") { Task { await store.loadMore() } }.disabled(store.isLoadingMore) }
            if store.comments.isEmpty, !store.isLoading, store.errorMessage == nil { ContentUnavailableView("暂无评论", systemImage: "bubble.left") }
        }
        .navigationTitle("评论 · \(store.total)").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(song.id)-\(appState.dataContextKey)-\(store.sort.rawValue)") { await store.load(song: song) }
        .refreshable { await store.reload() }
    }
}
