import Foundation

/// 字符串集中管理，预留英文。当前阶段使用代码内字符串，后续可迁移至 .xcstrings
public enum L10n {
    public enum Common {
        public static let appName = "澄音"
        public static let appNameEN = "ClearTone"
        public static let ok = "好"
        public static let cancel = "取消"
        public static let retry = "重试"
        public static let confirm = "确认"
        public static let close = "关闭"
        public static let search = "搜索"
        public static let loading = "加载中…"
        public static let empty = "暂无内容"
        public static let error = "出错了"
        public static let offline = "当前处于离线状态"
        public static let notLoggedIn = "未登录"
        public static let login = "登录"
        public static let logout = "退出登录"
        public static let settings = "设置"
        public static let back = "返回"
        public static let forward = "前进"
        public static let play = "播放"
        public static let pause = "暂停"
        public static let previous = "上一首"
        public static let next = "下一首"
        public static let volume = "音量"
        public static let queue = "播放队列"
        public static let lyrics = "歌词"
    }

    public enum Sidebar {
        public static let discover = "发现音乐"
        public static let search = "搜索"
        public static let myMusic = "我的音乐"
        public static let liked = "喜欢的音乐"
        public static let local = "本地音乐"
        public static let recent = "最近播放"
        public static let playlists = "创建的歌单"
    }

    public enum Player {
        public static let quality = "音质"
        public static let requestedQuality = "请求音质"
        public static let actualQuality = "实际返回"
        public static let unknown = "未知"
        public static let unavailable = "不可播放"
        public static let pureMusic = "纯音乐，请欣赏"
        public static let noLyrics = "暂无歌词"
        public static let backToCurrent = "回到当前歌词"
    }

    public enum Login {
        public static let title = "登录网易云音乐"
        public static let scanPrompt = "请使用网易云音乐 App 扫码登录"
        public static let waitingScan = "等待扫码"
        public static let scanned = "已扫码，请在手机上确认"
        public static let success = "登录成功"
        public static let expired = "二维码已过期，正在自动更换…"
        public static let failed = "登录失败，请重试"
    }

    public enum Settings {
        public static let general = "通用"
        public static let appearance = "外观"
        public static let playback = "播放"
        public static let quality = "音质"
        public static let performance = "性能"
        public static let advanced = "高级"
        public static let about = "关于"
        public static let theme = "主题"
        public static let language = "语言"
        public static let apiServer = "API 服务地址（开发/高级）"
        public static let apiServerHint = "仅用于开发调试，默认使用内置本地服务"
        public static let closeBehavior = "关闭窗口时"
        public static let continuePlaying = "继续播放"
        public static let quitApp = "退出应用"
        public static let resumePlayback = "启动时恢复播放"
        public static let resumePlaybackHint = "恢复上次播放位置，但不自动出声"
        public static let dynamicBackground = "动态背景"
        public static let spectrum = "频谱显示"
        public static let lyricOffset = "歌词偏移"
        public static let performanceMode = "性能模式"
        public static let performanceAuto = "自动"
        public static let performanceSaver = "节能"
        public static let performanceQuality = "高质量"
        public static let performanceStatic = "静态"
    }
}
