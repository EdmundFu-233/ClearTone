# API 能力验证文档

> 验证日期：2026-09-25
> 上游：NeteaseCloudMusicApiEnhanced 4.40.1（https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced）

## 验证环境

- macOS 27.0 (Build 26A428)
- Xcode 27.0, Swift 6.4
- Apple M3 Pro, 18 GB RAM
- Node.js v22.14.0（打包在 HelperRuntime 中）

## 已验证接口

| 功能 | 接口 | 是否需要登录 | 验证状态 | 备注 |
|------|------|------------|---------|------|
| 搜索歌曲 | `/search` 或 `/cloudsearch` | 否 | ✅ 已验证 | 返回 JSON，包含歌曲 ID、标题、歌手、专辑、时长 |
| 二维码 Key | `/login/qr/key` | 否 | ✅ 已验证 | 返回 unikey |
| 二维码生成 | `/login/qr/create?qrimg=true` | 否 | ✅ 已验证 | 返回 base64 图片 |
| 二维码状态 | `/login/qr/check` | 否 | ✅ 已验证 | code: 801=等待扫码, 802=已扫码, 803=成功, 800=过期 |
| 歌单详情 | `/playlist/detail` | 部分 | ✅ 已验证 | 公开歌单无需登录 |
| 歌单曲目 | `/playlist/track/all` | 部分 | ✅ 已验证 | 支持分页 limit/offset |
| 播放地址 | `/song/url/v1` | 部分 | ⚠️ 未完整验证 | 免费歌曲可获取；VIP 歌曲需登录且有权限 |
| 歌词 | `/lyric/new` | 否 | ✅ 已验证 | 返回 lrc/tlyric/romalrc/yrc |
| 推荐歌单 | `/personalized` | 否 | ✅ 已验证 | 无需登录 |
| 每日推荐 | `/recommend/songs` | 是 | ⚠️ 未验证 | 需要真实账号扫码登录 |
| 用户歌单 | `/user/playlist` | 是 | ⚠️ 未验证 | 需要真实账号扫码登录 |
| 喜欢列表 | `/likelist` | 是 | ⚠️ 未验证 | 需要真实账号扫码登录 |
| 喜欢/取消 | `/like` | 是 | ⚠️ 未验证 | 需要真实账号扫码登录 |

## 已知限制

1. **VIP 歌曲**：`/song/url/v1` 对 VIP 歌曲返回的 URL 可能为试听片段或 null，取决于账号权限。不做任何 VIP 解锁。
2. **xeapi 公钥**：api-enhanced 4.40.1 启动时警告 `xeapi public key is missing`，影响部分新接口，核心接口不受影响。
3. **匿名 token 注册**：首次启动需联网注册匿名 token，耗时 5-10 秒。
4. **二维码登录**：需要用户实际使用网易云音乐 App 扫码，本环境未验证完整登录流程（需要真实手机操作）。

## 未验证功能（需要真实账号）

以下功能代码已实现，但需要真实网易云账号扫码登录才能验证：

- 每日推荐歌曲
- 用户歌单列表
- 喜欢列表
- 喜欢/取消喜欢操作
- VIP 歌曲播放
- 高音质（无损/Hi-Res）获取


