# 澄音 ClearTone

macOS 原生第三方网易云音乐播放器。

仅支持 macOS 14.0 及以上。仓库里没有 iOS / Windows / Linux target —— 曾经的 `ClearToneiOS` 已移除。

## 系统要求

- macOS 14.0 或更高版本
- Apple Silicon 优先（M3 Pro 及以上推荐）
- 网络连接（在线功能需要）

## 快速开始

### 1. 安装辅助进程

首次运行前，需要下载并安装本地 API 辅助进程：

```bash
./scripts/setup-helper.sh
```

这将下载 Node.js v22.14.0 和 NeteaseCloudMusicApiEnhanced 到 `ClearTone/Resources/HelperRuntime/`。

### 2. 构建与运行

```bash
# 生成 Xcode 工程
xcodegen generate

# 构建
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug build

# 运行
open /Users/edmundfu/Library/Developer/Xcode/DerivedData/ClearTone-*/Build/Products/Debug/澄音.app
```

### 3. 登录

- 点击右上角头像进入登录页
- 使用网易云音乐 App 扫码登录

## 功能

- 🎵 在线搜索、歌单、播放
- 📱 二维码登录
- 🎨 深色/浅色主题
- 🎧 本地音乐导入与播放
- 📊 Metal 动态背景与频谱
- 🎤 同步歌词（LRC/YRC）
- ⌨️ 系统快捷键与媒体控制
- 📋 播放队列管理

## 故障排查

### 辅助进程启动失败

```bash
# 检查辅助进程是否已安装
ls ClearTone/Resources/HelperRuntime/bin/node
ls ClearTone/Resources/HelperRuntime/api/app.js

# 重新安装
./scripts/setup-helper.sh
```

### 网络请求失败

- 检查网络连接
- 确认辅助进程已启动（设置 > 高级 > 诊断信息）
- 查看日志：`~/Library/Logs/ClearTone/helper.log`

### 播放失败

- 确认歌曲有播放权限（VIP 歌曲需要会员）
- 检查网络连接
- 尝试切换音质（设置 > 播放 > 音质）

## 开发

### 构建

```bash
xcodegen generate
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug build
```

### 测试

```bash
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test
```

### 目录结构

```
ClearTone/
  App/                 # 入口、窗口、菜单
  Core/                # 模型、网络、持久化、安全、日志
  Providers/           # Netease/Local Provider
  Playback/            # 播放控制器、队列
  Features/            # 各功能页面
  DesignSystem/        # 颜色、排版、间距
  Rendering/           # Metal 渲染
  Resources/           # 资源、辅助进程
Tests/                 # 单元测试
docs/                  # 文档
scripts/               # 构建脚本
```

## 许可证

本项目仅供学习交流使用，与网易公司无关联。

第三方组件：
- NeteaseCloudMusicApiEnhanced: MIT License
- Node.js: MIT License

## 免责声明

- 本项目是第三方客户端，与网易云音乐官方无关联
- 不提供 VIP 解锁、DRM 绕过或地区限制绕过功能
- 所有音乐版权归属原作者和网易云音乐
