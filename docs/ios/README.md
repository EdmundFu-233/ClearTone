# 澄音 iOS

iPhone / iPad 原生 SwiftUI 应用，最低 iOS 17。选择 `ClearToneiOS` scheme。
macOS 版仍保留原来的 Node 辅助进程；iOS 使用原生 weapi / eapi / xeapi 直接连接网易云，包内不包含 Node、JIT、动态代码下载或外部 API 代理。

## 构建与安装

只需要完整 Xcode 和 XcodeGen；**不必运行 `setup-helper.sh`**。

```bash
xcodegen generate
./scripts/build-ios.sh --simulator   # 本地 ad-hoc 签名，不需要 Apple 账号
./scripts/build-ios.sh --device      # 未签名 Debug 设备构建
./scripts/build-ios.sh --ipa         # 未签名 Release IPA，供侧载工具重新签名
```

IPA 输出到 `build/iOS/ClearTone-unsigned.ipa`。该文件本身不能直接安装到真机，需用自己的免费账号通过侧载工具重新签名，或直接在 Xcode 中运行：

1. 打开生成的 `ClearTone.xcodeproj`，选择 `ClearToneiOS` target。
2. 在 Signing & Capabilities 中选择自己的 **Personal Team**，Automatic Signing 保持开启。
3. 如果 App ID 已占用，将 `com.cleartone.ios` 改为自己的唯一标识。
4. 连接 iPhone / iPad，按设备提示启用 Developer Mode，选择设备后运行。

工程没有给 iOS 写死团队 ID。免费 Personal Team 的设备测试流程与限制见 [Apple 官方说明](https://developer.apple.com/support/compare-memberships/)。本次实现不代用户登录 Xcode 或申请 provisioning profile。

## 签名与能力边界

- **没有 iOS 自定义 entitlement 文件，没有额外 SystemCapabilities，也没有 App Extension。**
- 不启用 App Groups、iCloud、Push Notifications、Sign in with Apple、Associated Domains、Network Extensions、Keychain Sharing 等需要申请或额外配置的服务。
- Cookie 使用应用默认的系统钥匙串；不设置 `kSecAttrAccessGroup`，不跨应用共享，不同步 iCloud。标准应用身份由 Xcode/侧载工具签名时生成。
- 后台音乐仅在 Info.plist 写 `UIBackgroundModes: [audio]`，配合 `AVAudioSession(.playback)`、`MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter`，不需要申请额外 entitlement。[Apple 后台模式说明](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- 使用系统文件选择器复制用户选定的音频到 App 容器；无照片、麦克风、通讯录权限请求。
- 网络使用 HTTPS，没有 ATS 全局例外；扫码图像在本机用 CoreImage 生成。

## 已实现

- 发现：推荐歌单、登录后的每日推荐、排行榜目录（榜单点进去就是歌单详情）。
- 搜索：歌曲 / 歌手 / 专辑 / 歌单，四类分页、取消与旧响应隔离；搜索联想、热搜与本地历史。
- 详情：歌单曲目分页、专辑、歌手热门歌曲及专辑。
- 账号：二维码登录、Cookie 登录、取消登录不写入迟到凭据、恢复与退出登录。
- 资料库：喜欢的音乐、最近播放、用户歌单、创建歌单、歌曲添加到歌单、本地音频文件导入。
- 播放：队列、排序与移除、播放模式、进度、音质、倍速、睡眠定时、LRC/YRC 歌词与翻译、锁屏/耳机媒体控制、来电中断与耳机断开处理。
- 评论：推荐 / 热度 / 最新排序、分页、点赞和失败回滚。
- 设置：账号、音质、恢复位置、自动缓存与清缓存。

iOS 缓存采用系统 `AVAssetExportPresetAppleM4A` 输出 AAC，码率显示实测值；不能冒称与 macOS 的 128 kbps OPUS 相同。缓存上限约 1.5 GB、最长保留 7 天，试听不缓存。

当前 iOS 没有桌面菜单栏/迷你窗口/Metal 背景，也尚未移植电台、私人 FM、私信和个人资料扩展页面。未适配的路由明确报错。iOS 不使用 Node 的第三方解灰复合接口：账号无权访问的歌曲可能只有试听或无播放地址。

## 验证

构建、签名配置、离线测试和匿名联网探针的本次结果见 [验证记录](validation.md)。

```bash
# 全部离线测试；保持持久化隔离，不要裸跑 xctest
./scripts/run-tests.sh

# 显式联网：匿名、只读、不读本机凭据，不输出扫码 key / Cookie / 播放 URL
./scripts/probe-ios-api.sh
```

离线覆盖移动登录取消/账号切换、歌单分页/去重/失败重试、移动路由参数转换、xeapi 的 Node 对照向量、AES 响应与 gzip 解码。离线测试不能代替账号登录、VIP、收藏写操作和真机后台音频验证。

二维码可通过分享面板保存，再用网易云扫一扫从相册识别；也可以用另一台已登录网易云的设备扫码。
