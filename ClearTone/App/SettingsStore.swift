import Foundation

/// 设置存储。全应用单例：菜单栏项、迷你播放器、主窗口读的是同一份设置。
@MainActor
public class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { PersistenceStore.shared.saveSetting(settings, forKey: "appSettings") }
    }

    public init() {
        self.settings = PersistenceStore.shared.loadSetting(forKey: "appSettings", as: AppSettings.self) ?? AppSettings()
    }
}
