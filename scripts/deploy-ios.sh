#!/bin/bash
# 真机部署：构建 → 安装 → 启动 ClearToneiOS。
#
# 为什么单独一个脚本：
#
# 1. `project.yml` 里 iOS target 的 `DEVELOPMENT_TEAM` 是**空的** —— 仓库不能替
#    用户选团队（见 docs/ios/README）。但真机安装必须带一个真实团队，
#    `build-ios.sh --device/--ipa` 又刻意产出未签名包，所以这一步只能在这里补。
# 2. 设备上已装的 App ID 是 **`com.cleartone.app.ios`**（沿用免费 Personal Team
#    已经注册好的那个），而 `project.yml` 里写的是 `com.cleartone.ios`。
#    直接按 project.yml 装会变成「第二个 App」：原 App 的数据看不到，
#    还多占一个免费账号的 App ID 名额（一共只有 10 个）。所以这里显式覆盖。
#
# 用法：
#   ./scripts/deploy-ios.sh                 # 自动找已配对的 iPhone
#   ./scripts/deploy-ios.sh <UDID>          # 指定设备
#   IOS_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/deploy-ios.sh
#   IOS_BUNDLE_ID=com.example.app ./scripts/deploy-ios.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  # devicectl 的表格里 UDID 形如 00008150-00112D81228A401C
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | grep -i 'physical' | grep -vi 'watch' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)
fi
if [ -z "$DEVICE" ]; then
  echo "没有找到已配对的 iPhone。用 USB 连上并在「访达 → 设备」里信任本机后重试，" >&2
  echo "或显式指定：$0 <UDID>（可用 xcrun devicectl list devices 查看）" >&2
  exit 2
fi

# 团队默认取 project.yml 里 macOS target 用的那个（同一个开发者账号的 Personal Team）。
TEAM="${IOS_DEVELOPMENT_TEAM:-$(grep -m1 -E '^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*[A-Za-z0-9]' project.yml | awk '{print $2}')}"
if [ -z "$TEAM" ]; then
  echo "没能确定 DEVELOPMENT_TEAM，请显式指定：IOS_DEVELOPMENT_TEAM=XXXXXXXXXX $0" >&2
  exit 2
fi
# 已注册的 App ID（复用现有的免费 profile，见文件头说明）。
# Widget 扩展的 bundle ID 在 project.yml 里由 `$(CT_APP_BUNDLE_ID).widget` 推导，
# 因此这里覆盖的是变量本身，而不是某个 target 的 PRODUCT_BUNDLE_IDENTIFIER ——
# 否则扩展会拿到和宿主相同的 ID，嵌入校验直接失败。
BUNDLE="${IOS_BUNDLE_ID:-com.cleartone.app.ios}"

OUTPUT="$PWD/build/iOS"
mkdir -p "$OUTPUT"
LOG="$OUTPUT/build-device-deploy.log"
# 与 build-ios.sh 一致：派生数据放临时目录，避开桌面 File Provider 的扩展属性
DERIVED="${TMPDIR:-/tmp}/cleartone-ios-device"

echo "设备：$DEVICE"
echo "团队：$TEAM"
echo "App ID：$BUNDLE"

xcodegen generate >/dev/null

if ! xcodebuild -project ClearTone.xcodeproj -scheme ClearToneiOS \
  -configuration Debug -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CT_APP_BUNDLE_ID="$BUNDLE" \
  build > "$LOG" 2>&1; then
  tail -80 "$LOG" >&2
  echo "完整日志：$LOG" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Debug-iphoneos/ClearToneiOS.app"
if [ ! -d "$APP" ]; then
  echo "构建成功但找不到产物：$APP" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP"

# 签名里不得出现超出「免费 Personal Team 一定拿得到」的那几项 —— 与
# build-ios.sh 的检查同一条规则，这里针对的是**签名后**的产物。
# 宿主与 Widget 扩展各自的签名都要过一遍；App Group / Keychain Sharing
# 这类会出现在扩展上的能力，也不能靠「只查宿主」漏过去。
python3 - "$APP" <<'PY'
import pathlib, plistlib, re, subprocess, sys

app = pathlib.Path(sys.argv[1])
appexes = sorted(app.rglob('*.appex'))
assert [p.name for p in appexes] == ['ClearToneWidget.appex'], [p.name for p in appexes]
ALLOWED = {
    'application-identifier', 'com.apple.application-identifier',
    'team-identifier', 'com.apple.developer.team-identifier',
    'com.apple.security.get-task-allow', 'get-task-allow',
}
for binary in [app] + appexes:
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(binary)],
                            capture_output=True, text=True)
    blob = result.stdout
    keys = set(re.findall(r'<key>([^<]+)</key>', blob))
    if not keys and blob.lstrip().startswith('bplist'):
        try:
            keys = set(plistlib.loads(blob.encode()).keys())
        except Exception:
            keys = set()
    bad = sorted(k for k in keys if k not in ALLOWED)
    assert not bad, f'{binary.name} 签名里出现了不该有的 entitlement: {bad}'
    print(f'{binary.name} 签名 entitlement 检查通过：{sorted(keys)}')
PY

xcrun devicectl device install app --device "$DEVICE" "$APP"

# 自动启动只是为了顺手验证一次；锁屏状态下系统会拒绝（Locked），
# 那不是部署失败 —— 安装已经完成了，别让脚本带着红字退出。
LAUNCH_LOG="$(mktemp -t cleartone-launch)"
if ! xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" > "$LAUNCH_LOG" 2>&1; then
  if grep -q "Locked" "$LAUNCH_LOG"; then
    echo "⚠️  手机处于锁屏，无法自动启动。解锁后在手机上点开「澄音」即可（安装已完成）。" >&2
  else
    echo "⚠️  自动启动失败，但安装已完成。可在手机上手动打开「澄音」。" >&2
    tail -5 "$LAUNCH_LOG" >&2
  fi
  rm -f "$LAUNCH_LOG"
  echo "已安装。构建日志：$LOG"
  exit 0
fi
rm -f "$LAUNCH_LOG"
echo "已安装并启动。构建日志：$LOG"
