#!/bin/bash
# iOS 不需要 Node / npm。--ipa 生成供侧载工具重新签名的未签名设备包。
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:---simulator}"
case "$MODE" in
  --simulator) SDK=iphonesimulator; DESTINATION='generic/platform=iOS Simulator'; CONFIG=Debug ;;
  --device) SDK=iphoneos; DESTINATION='generic/platform=iOS'; CONFIG=Debug ;;
  --ipa) SDK=iphoneos; DESTINATION='generic/platform=iOS'; CONFIG=Release ;;
  *) echo "用法：$0 [--simulator|--device|--ipa]" >&2; exit 2 ;;
esac
xcodegen generate
OUTPUT="$PWD/build/iOS"
mkdir -p "$OUTPUT"
# 避开桌面 File Provider 的扩展属性；保留编译缓存加速后续构建。
DERIVED="${TMPDIR:-/tmp}/cleartone-ios-${SDK}-${CONFIG}"
LOG="$OUTPUT/build-${SDK}-${CONFIG}.log"
SIGNING=(CODE_SIGNING_ALLOWED=NO)
if [ "$SDK" = iphonesimulator ]; then
  # 模拟器需要本地签名来获得标准应用身份，否则 SecItem 可能返回 -34018。
  SIGNING=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
fi
if ! xcodebuild -project ClearTone.xcodeproj -scheme ClearToneiOS \
  -configuration "$CONFIG" -sdk "$SDK" -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" build "${SIGNING[@]}" > "$LOG" 2>&1; then
  tail -80 "$LOG" >&2
  exit 1
fi
APP="$DERIVED/Build/Products/${CONFIG}-${SDK}/ClearToneiOS.app"
if [ "$MODE" = --ipa ]; then
  STAGING="$(mktemp -d "${TMPDIR:-/tmp}/cleartone-ipa-XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  mkdir -p "$STAGING/Payload"
  ditto --norsrc --noextattr "$APP" "$STAGING/Payload/ClearToneiOS.app"
  ditto -c -k --norsrc --noextattr "$STAGING" "$OUTPUT/ClearTone-unsigned.ipa"
  echo "未签名 IPA：$OUTPUT/ClearTone-unsigned.ipa"
else
  echo "构建成功：$APP"
fi
# 验证实际打包产物：不允许把桌面 helper 或申请额外 capability 的 entitlement 混入。
python3 - "$APP" <<'PY'
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleSupportedPlatforms'][0] in ('iPhoneOS', 'iPhoneSimulator')
assert info.get('UIBackgroundModes') == ['audio']
assert not (app / 'HelperRuntime').exists()
assert not list(app.rglob('node_modules'))
assert not list(app.rglob('*.entitlements'))
assert not list(app.rglob('*.appex'))

# 版本号必须来自 build setting，而不是 XcodeGen 的 `1.0` 默认值
assert info.get('CFBundleShortVersionString') == '0.1.0', info.get('CFBundleShortVersionString')
assert info.get('CFBundleVersion') == '1', info.get('CFBundleVersion')

# **iOS 不得申请任何需要付费开发者账号的 entitlement。**
# 只放行 Personal Team 免费账号一定拿得到的那几个（与 docs/ios/validation.md
# 实测记录的三项一致）。任何新的 com.apple.developer.* 出现都要先问一句
# 「Personal Team 能签吗」，答不上来就别加。
ALLOWED = {
    'application-identifier',
    'com.apple.application-identifier',
    'team-identifier',
    'com.apple.developer.team-identifier',
    'com.apple.security.get-task-allow',
    'get-task-allow',
}
result = subprocess.run(
    ['codesign', '-d', '--entitlements', ':-', str(app)],
    capture_output=True, text=True,
)
if result.returncode != 0:
    print('（未签名产物，跳过 entitlement 检查）')
else:
    blob = result.stdout
    import re
    keys = set(re.findall(r'<key>([^<]+)</key>', blob))
    # 平铺的 XML 形式之外，codesign 有时给 binary plist
    if not keys and blob.lstrip().startswith('bplist'):
        import plistlib as _pl
        try:
            keys = set(_pl.loads(blob.encode()).keys())
        except Exception:
            keys = set()
    bad = sorted(k for k in keys if k not in ALLOWED)
    assert not bad, f'iOS 申请了不该有的 entitlement: {bad}\n实际: {sorted(keys)}'
    print(f'iOS entitlement 检查通过：{sorted(keys)}')

print('iOS 包检查通过：无 Node、无扩展、后台模式仅 audio。')
PY
