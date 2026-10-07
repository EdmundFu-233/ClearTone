# iOS 验证记录

验证日期：2026-09-30（America/Toronto）。

- `ClearToneiOS` 的 iOS Simulator Debug 本地签名构建通过，iOS Device Debug 和 Release 未签名构建通过。
- `./scripts/run-tests.sh`：453 项离线测试、0 失败。使用脚本临时目录隔离用户持久化；新增 25 项移动登录、详情分页、路由和 xeapi 对照测试。
- `./scripts/probe-ios-api.sh`：20 条 PASS，0 失败。无用户 Cookie，只读验证四类搜索、歌词、专辑、歌手资料/热门歌曲/专辑、评论、推荐、歌单详情/曲目、扫码 key/等待状态、xeapi 播放地址。
- 免费歌曲音频 CDN 返回 HTTP 206，读取 1024 字节后取消。另一个样本返回单曲 code 404、无 URL；这是内容可用性结果，未把它当成完整歌曲或虚构可播放。
- iPhone 模拟器已安装并启动。发现页成功加载真实推荐与封面，见 [发现页截图](screenshots/discover.png)。界面控制工具的 Device Hub 访问超时，因此没有宣称逐页面 GUI 交互验证已完成。
- 最终设备构建设置：`DEVELOPMENT_TEAM` 与 `CODE_SIGN_ENTITLEMENTS` 都为空。生成工程无 `SystemCapabilities`。iOS target 不继承 macOS 的 entitlement 文件。
- 最终 IPA 检查：`MinimumOSVersion=17.0`，`UIDeviceFamily=[1,2]`，`UIBackgroundModes=[audio]`；无 Node / node_modules / App Extension / entitlement 文件、无 ATS 例外和额外隐私 UsageDescription 请求。
- `git diff --check` 通过。

## 尚未验证

没有使用用户的登录凭据或替用户申请证书。扫码确认后的 Cookie 持久化、VIP/喜欢/歌单/评论写操作、实际 AVPlayer 音频播放与后台锁屏/中断/耳机切换，仍需用户设备验证。未签名 IPA 需要先由 Xcode 或侧载工具用自己的免费账号重新签名。

## 真机安装更新

2026-09-30：复用已授权设备的免费 Personal Team profile，签名完整性验证通过，iPhone 17 已安装澄音 0.1.0（App ID `com.cleartone.app.ios`）。实际签名只含 application-identifier、team-identifier、get-task-allow 三项标准 entitlement。首次启动被 iOS 的开发者信任检查拒绝，需用户在手机设置中信任开发者后继续验证。

功能范围和未移植页面见 [iOS 开发说明](README.md)。

## UI / UX 更新真机部署

2026-09-30：将本次 UI / UX 优化以 0.1.0（构建号 2）覆盖安装到已配对的 iPhone 17，保留原 App ID `com.cleartone.app.ios`，未卸载任何应用。使用现有 Personal Team profile，`codesign --verify --deep --strict` 通过；实际 entitlement 仍只有 application-identifier、team-identifier、get-task-allow。

`devicectl device install app` 安装成功；随后 `devicectl device process launch --terminate-existing` 启动成功，并在设备运行进程列表中确认 ClearToneiOS 仍在运行。本次已补齐上一轮开发者信任后的启动验证。构建日志：`build/iOS/build-device-ui-ux.log`。

当前复用的免费 profile 将于 **2026-10-02 21:23:58（多伦多时间）** 到期，到期需重新签名安装。此次安装与进程检查不能代替账号写操作、真机后台音频及 VoiceOver 的功能验收。

## 真机覆盖部署（热搜 / 榜单 / 歌词状态机）

2026-10-07：把当前工作区（新增 `feat(iOS): 补齐搜索热搜与排行榜`、
`refactor: 歌词状态机合并到 Core` 两批改动）覆盖安装到已配对的 iPhone 17，
沿用原 App ID `com.cleartone.app.ios` 与现有免费 Personal Team profile，
未卸载应用、保留原有数据。

- 新增 `scripts/deploy-ios.sh` 把「签名 → 安装 → 启动」固化下来
  （`build-ios.sh` 产出的是**未签名**包，装不上真机）。脚本会校验签名里只有
  application-identifier / team-identifier / get-task-allow 三项。
- `codesign --verify --deep --strict` 通过；`devicectl device install app` 安装成功；
  `devicectl device process launch --terminate-existing` 启动成功，
  并在设备进程列表里确认 `ClearToneiOS` 仍在运行（PID 7844）。
- 本机离线验证：`./scripts/run-tests.sh` 521 项 0 失败 0 跳过；macOS 与 iOS 模拟器构建通过。
- 构建日志：`build/iOS/build-device-deploy.log`。

此次只做了安装与启动验证，**没有**在真机上逐页面验收热搜 / 榜单加载
（需要用户登录后在设备上确认），也不能代替账号写操作与后台音频验收。

## 音量修复更新

2026-09-30：iPhone 17 已覆盖更新为构建号 3，并通过启动与进程存活检查。消除 iOS 播放器内部默认 0.8 和旧音量/静音快照带来的额外衰减，系统音量保持由用户控制。457 项离线测试通过，iOS 运行时探针通过。见 [音量修复记录](volume-fix.md)。
