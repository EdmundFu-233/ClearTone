# 澄音 ClearTone 开发说明

## 环境

- macOS 14.0+
- Xcode 15.0+（推荐 27.0）
- Swift 6.0+
- XcodeGen 2.46+（用于生成 Xcode 工程）

## 构建

```bash
# 安装 XcodeGen（如果未安装）
brew install xcodegen

# 生成 Xcode 工程
xcodegen generate

# 构建
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug build

# 运行测试
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test
```

## 辅助进程

首次运行前需要安装 Node.js 辅助进程：

```bash
./scripts/setup-helper.sh
```

辅助进程包含：
- Node.js v22.14.0（ARM64）
- NeteaseCloudMusicApiEnhanced 4.40.1

### 辅助进程安全模型

- 仅监听 127.0.0.1
- 每次启动随机端口（21000-29000）
- 每次启动随机 UUID token，通过 X-CT-Token header 校验
- 网易云 Cookie 通过 X-CT-Cookie header 注入，不出现在 URL 中
- 主应用退出时自动跟随退出（父进程监控）
- 健康检查失败自动重启

## 目录结构

```
ClearTone/
  App/                 # 入口、窗口、菜单、AppState
  Core/
    Models/            # Song/Playlist/LyricLine 等
    Networking/        # HelperProcessManager
    Persistence/       # PersistenceStore
    Security/          # KeychainStore
    Logging/           # CTLog（自动脱敏）
  Providers/
    Netease/           # NeteaseProvider + LRCParser
    Local/             # LocalProvider
    Demo/              # DemoProvider + DemoAudioGenerator
  Playback/            # PlayerController + PlayQueue
  Features/            # Discover/Search/Library/Playlist/NowPlaying/Settings/Login
  DesignSystem/        # CTColors/CTTypography/CTSpacing/L10n
  Rendering/           # Metal renderer + shader + SpectrumAnalyzer
  Resources/
    HelperRuntime/     # Node.js + api-enhanced（构建时打包）
    Assets.xcassets/
Tests/                 # 单元测试（XCTest）
docs/                  # 文档
scripts/               # 构建脚本
```

## 架构决策

1. **网易云接入**：本地 Node.js 辅助进程（方案 2）
   - 理由：加密协议复杂，Swift 重写成本高、风险大
   - 上游：NeteaseCloudMusicApiEnhanced（MIT）

2. **音频播放**：AVPlayer + AVPlayerItem
   - 原生支持 HTTPS 流媒体、自动缓冲、seek

3. **频谱**：Accelerate/vDSP FFT + Metal 绘制
   - MTAudioProcessingTap 对远程流媒体支持有限，当前回退到环境动画

4. **状态管理**：SwiftUI 原生 ObservableObject + @Published
   - 避免引入 TCA 等重型框架

## 注意事项

- 不要提交 `ClearTone/Resources/HelperRuntime/` 到 git（体积过大，约 100MB）
- 发布版本需要处理 Node.js 二进制的签名与 hardened runtime
- 当前版本使用 ad-hoc 签名，仅供开发测试

## 测试

```bash
# 运行全部测试
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test

# 当前覆盖：PlayQueueTests (7), LRCParserTests (7)
```
