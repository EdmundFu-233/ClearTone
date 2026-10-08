#pragma once

#include <QString>

namespace ct {

struct L10n {
    struct Common {
        inline static const QString AppName = QStringLiteral("澄音");
        inline static const QString AppNameEN = QStringLiteral("ClearTone");
        inline static const QString Ok = QStringLiteral("好");
        inline static const QString Cancel = QStringLiteral("取消");
        inline static const QString Retry = QStringLiteral("重试");
        inline static const QString Confirm = QStringLiteral("确认");
        inline static const QString Close = QStringLiteral("关闭");
        inline static const QString Search = QStringLiteral("搜索");
        inline static const QString Loading = QStringLiteral("加载中…");
        inline static const QString Empty = QStringLiteral("暂无内容");
        inline static const QString Error = QStringLiteral("出错了");
        inline static const QString Offline = QStringLiteral("当前处于离线状态");
        inline static const QString NotLoggedIn = QStringLiteral("未登录");
        inline static const QString Login = QStringLiteral("登录");
        inline static const QString Logout = QStringLiteral("退出登录");
        inline static const QString Settings = QStringLiteral("设置");
        inline static const QString Back = QStringLiteral("返回");
        inline static const QString Forward = QStringLiteral("前进");
        inline static const QString Play = QStringLiteral("播放");
        inline static const QString Pause = QStringLiteral("暂停");
        inline static const QString Previous = QStringLiteral("上一首");
        inline static const QString Next = QStringLiteral("下一首");
        inline static const QString Volume = QStringLiteral("音量");
        inline static const QString Queue = QStringLiteral("播放队列");
        inline static const QString Lyrics = QStringLiteral("歌词");
    };

    struct Sidebar {
        inline static const QString Discover = QStringLiteral("发现音乐");
        inline static const QString Search = QStringLiteral("搜索");
        inline static const QString MyMusic = QStringLiteral("我的音乐");
        inline static const QString Liked = QStringLiteral("喜欢的音乐");
        inline static const QString Local = QStringLiteral("本地音乐");
        inline static const QString Recent = QStringLiteral("最近播放");
        inline static const QString Playlists = QStringLiteral("创建的歌单");
    };

    struct Player {
        inline static const QString Quality = QStringLiteral("音质");
        inline static const QString RequestedQuality = QStringLiteral("请求音质");
        inline static const QString ActualQuality = QStringLiteral("实际返回");
        inline static const QString Unknown = QStringLiteral("未知");
        inline static const QString Unavailable = QStringLiteral("不可播放");
        inline static const QString PureMusic = QStringLiteral("纯音乐，请欣赏");
        inline static const QString NoLyrics = QStringLiteral("暂无歌词");
        inline static const QString LoadingLyrics = QStringLiteral("正在获取歌词…");
        inline static const QString BackToCurrent = QStringLiteral("回到当前歌词");
    };

    struct Login {
        inline static const QString Title = QStringLiteral("登录网易云音乐");
        inline static const QString ScanPrompt = QStringLiteral("请使用网易云音乐 App 扫码登录");
        inline static const QString WaitingScan = QStringLiteral("等待扫码");
        inline static const QString Scanned = QStringLiteral("已扫码，请在手机上确认");
        inline static const QString Success = QStringLiteral("登录成功");
        inline static const QString Expired = QStringLiteral("二维码已过期，正在自动更换…");
        inline static const QString Failed = QStringLiteral("登录失败，请重试");
    };
};

} // namespace ct
