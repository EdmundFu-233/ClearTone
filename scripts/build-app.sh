#!/bin/bash
# 构建 Release .app 并完成签名安装。
#
# ## 为什么不能直接 `xcodebuild ... build`
#
# 仓库在桌面上，而桌面被 File Provider（iCloud/第三方同步）接管：
# 它会给复制出来的文件重新加上 `com.apple.FinderInfo` 等扩展属性，
# 于是 codesign 报 "resource fork, Finder information, or similar detritus
# not allowed" 而失败。`xattr -cr` 在原地无效 —— 改完立刻又被加回来。
#
# 所以这里先编出**未签名**产物，再 `ditto` 到普通文件系统（/tmp），
# 在那里清属性并签名，最后装到 /Applications。
#
# ## 签名策略
#
# - 主 App 与打包进去的 `bin/node`（嵌套 Mach-O 代码）都要签，
#   否则 hardened runtime 下签名校验不过；
# - npm 装出来的 `.js` 虽然带 +x，但脚本不算 nested code，不用签；
# - **开发证书 + hardened runtime，未公证**。`spctl` 会判 rejected，
#   本机双击可正常运行；要分发必须走 Apple Developer ID + notarization。
#
# 用法：./scripts/build-app.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="澄音"
BUNDLE_ID="com.cleartone.app"
STAGE="/tmp/cleartone-stage"
INSTALL_DIR="/Applications"
ENTITLEMENTS="$(mktemp -t cleartone-entitlements).plist"

log() { printf '\033[1m==> %s\033[0m\n' "$1"; }

# ---- 0. 前置检查 -------------------------------------------------------
# 三项分别对应 ./scripts/setup-helper.sh 的三个步骤，且只有第 3 项是
# `api/` 入库之后新增的。少任何一项的报错都很难定位：node 缺失会在第 4 步
# 签嵌套代码时才炸，node_modules 缺失要到第 4b 步自检才炸 —— 那时已经
# 编完、签完、跑了两个分钟，错误还只是一串 MODULE_NOT_FOUND。
if [ ! -x ClearTone/Resources/HelperRuntime/bin/node ]; then
  echo "错误：缺少辅助进程的 Node 运行时。" >&2
  echo "      执行 ./scripts/setup-helper.sh（从 nodejs.org 下载约 104MB）" >&2
  exit 1
fi
if [ ! -f ClearTone/Resources/HelperRuntime/api/app.js ]; then
  echo "错误：缺少 HelperRuntime/api（辅助进程的业务代码）。" >&2
  echo "      执行 ./scripts/setup-helper.sh" >&2
  exit 1
fi
if [ ! -d ClearTone/Resources/HelperRuntime/api/node_modules ]; then
  echo "错误：缺少 HelperRuntime/api/node_modules（约 45MB，不入库）。" >&2
  echo "      执行 ./scripts/setup-helper.sh，会在 api/ 下跑 npm ci" >&2
  echo "      它是硬依赖：辅助进程启动时会 require axios / crypto-js / node-forge。" >&2
  exit 1
fi

# ---- 1. 挑一个可用的开发签名身份 ----------------------------------------
# 与 project.yml 的 DEVELOPMENT_TEAM 对应；换机器时改这里。
TEAM_ID="$(grep -oE 'DEVELOPMENT_TEAM: *[A-Z0-9]+' project.yml | head -1 | awk '{print $2}')"
IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Apple Development" \
  | while read -r line; do
      hash=$(echo "$line" | awk '{print $2}')
      pem=$(security find-certificate -c "$(echo "$line" | sed 's/.*"\(.*\)".*/\1/')" -p 2>/dev/null || true)
      [ -n "$pem" ] || continue
      ou=$(printf '%s' "$pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*OU *= *//;s/,.*//')
      if [ "$ou" = "$TEAM_ID" ]; then echo "$hash"; break; fi
    done)"

if [ -z "$IDENTITY" ]; then
  echo "错误：找不到 team $TEAM_ID 对应的开发证书。" >&2
  echo "可用身份：" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi
log "签名身份 $IDENTITY (team $TEAM_ID)"

# ---- 2. 生成工程并编译（不签名）----------------------------------------
log "xcodegen generate"
xcodegen generate >/dev/null

log "xcodebuild Release（CODE_SIGNING_ALLOWED=NO）"
# 注意：target 名是 ClearTone，澄音只是 PRODUCT_NAME（产物名）——两者不同。
# 也不能把 xcodebuild 的输出接 `|| true`：那会让构建失败仍然往下走去签一个
# 过期的 .app，然后报告成功。构建失败必须立刻中止。
BUILD_LOG="$(mktemp -t cleartone-build).log"
if ! xcodebuild -project ClearTone.xcodeproj -target ClearTone \
      -configuration Release build CODE_SIGNING_ALLOWED=NO >"$BUILD_LOG" 2>&1; then
  echo "错误：构建失败，详见 $BUILD_LOG" >&2
  grep -E "error:" "$BUILD_LOG" | head -20 >&2 || true
  exit 1
fi
grep -E "error:|BUILD SUCCEEDED" "$BUILD_LOG" | head -5 || true

SRC="build/Release/$APP_NAME.app"
[ -d "$SRC" ] || { echo "错误：未产出 $SRC" >&2; exit 1; }

# ---- 3. 复制到普通文件系统并清属性 -------------------------------------
log "复制到 $STAGE 并清理扩展属性"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$SRC" "$STAGE/$APP_NAME.app"
xattr -cr "$STAGE/$APP_NAME.app"

# ---- 4. 写 entitlements 并签名 -----------------------------------------
# App 的 entitlements 必须与 project.yml 的 `entitlements.properties` 一致。
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
</dict>
</plist>
PLIST

# node 的 entitlements 单独一份。
#
# **这里漏了会直接导致 App 起不来**：Node 跑在 V8 上，依赖 JIT。
# 开了 hardened runtime（-o runtime）却没有 com.apple.security.cs.allow-jit，
# macOS 会拒绝 MAP_JIT，node 启动即退、**且不输出任何错误** ——
# 症状是 App 能开、能显示界面，但辅助进程永远不来。
# 首次遇到这个问题时因为没验这一步，把一个「App 打得开但联网全废」的
# 产物装到了 /Applications。下面的自检就是为了不再犯。
#
# disable-library-validation：api-enhanced 从 node_modules 加载原生 .node 插件，
# 它们不是随包签名的。
NODE_ENTITLEMENTS="$(mktemp -t cleartone-node-entitlements).plist"
cat > "$NODE_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
PLIST

log "签名嵌套代码（HelperRuntime/bin/node）"
xattr -cr "$STAGE/$APP_NAME.app/Contents/Resources/HelperRuntime/bin/node"
codesign --force --sign "$IDENTITY" -o runtime \
  --entitlements "$NODE_ENTITLEMENTS" \
  "$STAGE/$APP_NAME.app/Contents/Resources/HelperRuntime/bin/node"

log "签名 App"
codesign --force --sign "$IDENTITY" -o runtime \
  --entitlements "$ENTITLEMENTS" \
  "$STAGE/$APP_NAME.app"

log "校验签名"
codesign --verify --deep --strict --verbose=2 "$STAGE/$APP_NAME.app"

# ---- 4b. 辅助进程自检 ---------------------------------------------------
# codesign 校验通过 ≠ 运行时能起来。必须真的把 node 拉起来看它有没有
# 打印监听地址 —— 这是唯一能抓到 hardened runtime / entitlement 类问题的办法。
log "自检：启动打包的辅助进程"
SELFTEST_LOG="$(mktemp -t cleartone-selftest).log"
SELFTEST_PORT=$(( 21000 + RANDOM % 8000 ))
(
  cd "$STAGE/$APP_NAME.app/Contents/Resources/HelperRuntime"
  HOST=127.0.0.1 PORT="$SELFTEST_PORT" CT_AUTH_TOKEN=selftest-token \
    ./bin/node api/app.js >"$SELFTEST_LOG" 2>&1 &
  echo $! > "$SELFTEST_LOG.pid"
  sleep 12
  if grep -q "ClearTone Helper listening" "$SELFTEST_LOG"; then
    kill "$(cat "$SELFTEST_LOG.pid")" 2>/dev/null || true
    exit 0
  fi
  kill "$(cat "$SELFTEST_LOG.pid")" 2>/dev/null || true
  exit 1
) || {
  echo "错误：辅助进程自检失败 —— 签名后的 node 起不来。" >&2
  echo "---- 自检输出 ----" >&2
  cat "$SELFTEST_LOG" >&2
  echo "------------------" >&2
  echo "node 的 entitlements 里必须有 com.apple.security.cs.allow-jit（V8 依赖 JIT）。" >&2
  exit 1
}
log "辅助进程自检通过"

# ---- 5. 安装 ------------------------------------------------------------
if [ "${1:-}" = "--no-install" ]; then
  log "跳过安装，产物在 $STAGE/$APP_NAME.app"
  exit 0
fi

log "安装到 $INSTALL_DIR"
if pgrep -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1; then
  echo "提示：$APP_NAME 正在运行，请先退出再重新打开以加载新版本" >&2
fi
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$STAGE/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"
codesign --verify --deep --strict "$INSTALL_DIR/$APP_NAME.app"

log "完成"
cat <<EOF
路径      $INSTALL_DIR/$APP_NAME.app
体积      $(du -sh "$INSTALL_DIR/$APP_NAME.app" | cut -f1)
架构      $(lipo -archs "$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME")
签名      开发证书 + hardened runtime，**未公证**
          spctl 会判 rejected（开发签的正常结果），本机可直接双击运行。
          要分发必须换成 Developer ID 并走 notarization。

首次运行会拉起打包在包内的 Node 辅助进程（日志：~/Library/Logs/ClearTone/helper.log）。
EOF
