# 澄音 ClearTone（Windows）

ClearTone 的 Windows 桌面版，使用 **.NET 8 + Avalonia** 构建，与 macOS 版共用
同一套网易云接入方案：本地 Node.js 辅助进程运行 NeteaseCloudMusicApiEnhanced，
仅监听 `127.0.0.1`，随机端口 + 一次性 token（`X-CT-Token`），网易云 Cookie 走
`X-CT-Cookie` 头注入，主进程退出时辅助进程自动跟随退出。

## 功能范围

与 macOS 版对齐：发现/每日推荐、搜索（联想/热搜/历史/分页）、歌单/专辑/歌手详情、
排行榜、电台、私人 FM、我的音乐/喜欢的音乐/本地音乐/最近播放、评论、消息、
个人资料（等级/听歌排行/签到/收藏计数）、设置、二维码登录、播放队列、
播放栏与全屏正在播放页（歌词逐字 YRC / 整行高亮、翻译/音译、偏移调节、
手动滚动时暂停自动跟随并可一键回到当前行）、音质菜单与单曲音质覆盖、
倍速菜单、睡眠定时、音频缓存、动态背景。

与 macOS 的差异（有意为之）：

- 音频输出用 **libVLC**（跨平台）而非 AVFoundation；
- 系统媒体控制用 **SMTC**（`net8.0-windows10.0.19041.0` 目标，`#if WINDOWS` 隔离，
  不可用时静默降级不影响播放）；菜单栏形态为**系统托盘 + 独立迷你播放器窗口**；
- 音频缓存不做转码（macOS 用 `afconvert` 转 128kbps OPUS），直接缓存原始流文件；
- 凭据用 **DPAPI**（当前用户）加密后存于 `credentials.json`。

## 构建与运行

要求：.NET 8 SDK。辅助进程的 `api/` 业务代码与 macOS 版共用（`ClearTone/Resources/HelperRuntime/api`），
Windows 只额外需要 `node.exe`：

```bash
# 下载 win-x64 Node.js v22.14.0 到 windows/runtime/node.exe
./scripts/fetch-node-win.sh

# 运行（开发；工程为 net8.0 + net8.0-windows10.0.19041.0 双目标）
dotnet run --project src/ClearTone/ClearTone.csproj -f net8.0

# 在 Windows 上开发时直接跑 Windows 目标（含 SMTC 系统媒体控制）
dotnet run --project src/ClearTone/ClearTone.csproj -f net8.0-windows10.0.19041.0

# 单元测试（离线，不需要真实账号/网络）
dotnet test tests/ClearTone.Tests/ClearTone.Tests.csproj
```

## 发布打包

```powershell
# 在 Windows 上
powershell -ExecutionPolicy Bypass -File scripts/build-app.ps1
```

```bash
# 在 macOS/Linux 上交叉发布
./scripts/build-app.sh
```

产物：`publish/win-x64/`（自包含，目标机无需安装 .NET）与 `publish/ClearTone-win-x64.zip`。

## 本地数据

| 内容 | 位置 |
| --- | --- |
| 设置 / 队列 / 最近播放 / 账号缓存 | `%APPDATA%\ClearTone` |
| 凭据（DPAPI 加密） | `%APPDATA%\ClearTone\credentials.json` |
| 音频缓存 / 封面缓存 | `%APPDATA%\ClearTone\AudioCache`、`CoverCache` |
| 辅助进程日志 | `%LOCALAPPDATA%\ClearTone\logs\helper.log` |

测试与开发可用环境变量重定向：

- `CLEARTONE_STORAGE_DIR`：持久化根目录；
- `CLEARTONE_HELPER_ROOT` / `CLEARTONE_HELPER_NODE`：辅助进程目录与 node 二进制覆盖
  （在 macOS 上开发调试时指向仓库内 `HelperRuntime` 与 `bin/node`）。

## 辅助进程启动排查

辅助进程无法启动时优先看 `%LOCALAPPDATA%\ClearTone\logs\helper.log`。常见原因：

- 缺少 `helper/bin/node.exe` —— 运行 `scripts/fetch-node-win.sh` 后重新构建；
- 缺少 `helper/api/node_modules` —— 在 `ClearTone/Resources/HelperRuntime/api` 下执行
  `npm ci --omit=dev --ignore-scripts`；
- 杀毒软件拦截本地回环监听 —— 将安装目录加入白名单。
