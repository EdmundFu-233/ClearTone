import SwiftUI
import UniformTypeIdentifiers

struct IOSLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @StateObject private var local = MobileLocalLibrary()
    @State private var importing = false
    @State private var importError: String?
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    if let account = appState.account, appState.isLoggedIn {
                        IOSCover(url: account.avatarURL, size: 56, cornerRadius: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.nickname).font(.title3.bold())
                            Text(account.isVIP ? "网易云 VIP · 你的音乐空间" : "你的音乐空间").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 48)).foregroundStyle(IOSTheme.accent).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("把喜欢的音乐留在身边").font(.headline)
                            Text("登录同步收藏，或直接导入本地音乐").font(.subheadline).foregroundStyle(.secondary)
                            Button("登录网易云音乐") { appState.isLoginPresented = true }.font(.subheadline.weight(.semibold)).padding(.vertical, 6)
                        }
                    }
                }.padding(.vertical, 10)
            }
            Section("我的音乐") {
                if appState.isLoggedIn {
                    NavigationLink { IOSSongListView(title: "喜欢的音乐", songs: appState.likedSongs) } label: {
                        libraryItem("喜欢的音乐", subtitle: "\(appState.likedSongs.count) 首收藏", icon: "heart.fill", color: .pink)
                    }
                } else {
                    Button { appState.isLoginPresented = true } label: { libraryItem("喜欢的音乐", subtitle: "登录后查看收藏", icon: "heart.fill", color: .pink) }.buttonStyle(.plain)
                }
                NavigationLink { IOSSongListView(title: "最近播放", songs: player.recentlyPlayed) } label: {
                    libraryItem("最近播放", subtitle: "重温最近听过的旋律", icon: "clock.fill", color: .orange)
                }
                NavigationLink { IOSSongListView(title: "本地音乐", songs: local.songs) } label: {
                    libraryItem("本地音乐", subtitle: "\(local.songs.count) 首 · 随时离线收听", icon: "folder.fill", color: IOSTheme.accent)
                }
                Button { importing = true } label: { Label("从文件导入音频", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold)).frame(minHeight: 44) }
            }
            if appState.isLoggedIn {
                Section {
                    if appState.isLoadingUserPlaylists { ProgressView("正在加载歌单…") }
                    ForEach(appState.userPlaylists) { IOSPlaylistRow(playlist: $0) }
                    if appState.userPlaylists.isEmpty, !appState.isLoadingUserPlaylists {
                        Text("用一张歌单，收藏一种心情。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    Button("创建歌单", systemImage: "plus.circle.fill") { creating = true }
                } header: { Text("我的歌单 · \(appState.userPlaylists.count)") }
            }
        }
        .navigationTitle("资料库")
        .task(id: appState.dataContextKey) { await appState.loadUserPlaylists() }
        .refreshable { await appState.loadLikedSongs(force: true); await appState.loadUserPlaylists() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            Task {
                do { try await local.importFiles(result.get()) }
                catch { importError = error.ctUserMessage }
            }
        }
        .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) { Button("好") { importError = nil } } message: { Text(importError ?? "") }
        .alert("创建歌单", isPresented: $creating) {
            TextField("歌单名称", text: $name)
            Button("取消", role: .cancel) { name = "" }
            Button("创建") {
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines); name = ""
                Task { _ = await appState.createPlaylist(name: title, isPrivate: false) }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func libraryItem(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 48, height: 48)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}
