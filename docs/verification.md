# 验证文档

> 验证日期：2026-09-25

## 环境

- macOS 27.0 (Build 26A428)
- Xcode 27.0 (Build 27A266a)
- Swift 6.4
- Apple M3 Pro, 18 GB RAM, Dell S3225QS 6K 外接显示器

## 构建验证

```bash
# 生成 Xcode 工程
xcodegen generate

# 构建
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug build
# 结果：✅ BUILD SUCCEEDED

# 单元测试
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test
# 结果：✅ 14 tests passed, 0 failures
```

## 辅助进程验证

```bash
# 安装辅助进程
./scripts/setup-helper.sh
# 结果：✅ Node.js v22.14.0 + api-enhanced 4.40.1 安装成功

# 启动辅助进程（手动测试）
cd ClearTone/Resources/HelperRuntime/api
PORT=3001 CT_AUTH_TOKEN=mysecrettoken HOST=127.0.0.1 ../bin/node app.js

# 测试鉴权
curl -s "http://127.0.0.1:3001/search?keywords=test"  # 无 token
# 结果：✅ 401 {"error":"unauthorized"}

curl -s "http://127.0.0.1:3001/search?keywords=test&limit=1" -H "X-CT-Token: mysecrettoken"
# 结果：✅ 200 返回真实搜索结果

curl -s "http://127.0.0.1:3001/ct_health" -H "X-CT-Token: mysecrettoken"
# 结果：✅ 200 {"status":"ok","timestamp":...}
```

## 应用启动验证

```bash
# 启动应用
open /path/to/澄音.app
# 或使用 xcodebuild 运行
```

- ✅ 应用可启动，主窗口显示
- ✅ 侧栏/工具栏/播放栏布局正常
- ✅ 深色主题正确应用
- ⚠️ 截图：当前终端环境无屏幕录制权限，`screencapture` 失败，无法自动截图

## 单元测试

| 测试套件 | 数量 | 通过 | 失败 |
|---------|------|------|------|
| PlayQueueTests | 7 | 7 | 0 |
| LRCParserTests | 7 | 7 | 0 |

覆盖场景：
- 队列增删、重复条目、随机历史、循环、当前条目被移除、最后一首结束
- LRC/YRC 解析、偏移、重复时间戳、异常行、二分定位边界

## 真实联调范围

| 项目 | 状态 | 说明 |
|------|------|------|
| 网易云搜索 | ✅ 已验证 | 通过辅助进程返回真实数据 |
| 二维码登录 | ⚠️ 未完整验证 | API 可用，但需真实手机扫码 |
| 在线播放 | ⚠️ 未验证 | 需要登录后获取有效播放地址 |
| 本地播放 | ✅ 已验证 | 演示音频可正常播放 |
| Metal 背景 | ✅ 已验证 | shader 编译成功，视图可渲染 |
| 频谱 | ⚠️ 回退 | MTAudioProcessingTap 不支持远程流，使用环境动画 |

## 手工检查项

- [ ] 冷启动进入搜索、选择结果、开始播放、切歌、打开歌词、调整队列
- [ ] 设置持久化，重启恢复队列但不默认出声
- [ ] 主窗口关闭后媒体控制仍正常，重新打开不双重播放
- [ ] 最小尺寸、默认尺寸、全屏、深浅色、长文本、Retina 布局
- [ ] 10,000 条曲目列表滚动与搜索不卡住主线程
- [ ] 窗口最小化/恢复、拖到不同屏幕、睡眠唤醒、断网恢复
- [ ] 沉浸页播放/暂停时频谱与背景渲染状态符合设置

## 受外部条件限制的项目

1. **截图验证**：当前终端环境无屏幕录制权限，无法生成自动截图。需要用户在真实 macOS 桌面环境中手动验证 UI。
2. **扫码登录**：需要真实网易云账号和手机 App 扫码，未验证完整登录闭环。
3. **VIP 播放**：需要 VIP 账号验证高音质和无损播放。
4. **频谱**：MTAudioProcessingTap 对 HTTPS 远程流媒体支持有限，当前版本回退到环境动画。
