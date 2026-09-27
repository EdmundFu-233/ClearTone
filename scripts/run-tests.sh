#!/bin/bash
# 离线单元测试。不构建 App target，绕开 Metal 工具链问题。
# 用法：./scripts/run-tests.sh [--no-build] [XCTest 类名 ...]（不传类名则跑全部）
set -euo pipefail
cd "$(dirname "$0")/.."

# 默认每次都重新构建。之前只在 bundle 缺失时构建，于是改了源码再跑测试
# 拿到的是**上一次的**结果 —— 绿色的测试可能根本没测新代码。
BUILD=1
if [ "${1:-}" = "--no-build" ]; then
  BUILD=0
  shift
fi

if [ "$BUILD" = "1" ]; then
  xcodebuild -project ClearTone.xcodeproj -target ClearToneTests \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO >/dev/null
fi

if [ ! -d build/Debug/ClearToneTests.xctest ]; then
  echo "build/Debug/ClearToneTests.xctest 不存在，先构建一次" >&2
  exit 1
fi

# 测试 bundle 若位于带扩展属性的目录（iCloud 同步的桌面等），
# 签名阶段会报 "resource fork ... not allowed"，先清掉再 ad-hoc 签一次
xattr -cr build/Debug/ClearToneTests.xctest
codesign --force --sign - build/Debug/ClearToneTests.xctest 2>/dev/null

# 持久化隔离。
#
# `PersistenceStore.storageRoot` 是 `static let`（只求值一次），所以隔离必须
# 在**进程启动前**由环境变量决定。之前由两个测试类各自 `setenv` 了不同的目录，
# 另一个静默无效；而 `DemoAudioGeneratorTests` 压根不隔离，直接删改开发者真实
# App 目录下的 tone_440.wav（同一个文件正被其它测试的 AVPlayer 打开）。
# 现在一个环境变量管住全部：queue.json、settings、测试音频。
TEST_STORAGE="$(mktemp -d "${TMPDIR:-/tmp}/cleartone-tests-XXXXXX")"
export CLEARTONE_TEST_STORAGE_DIR="$TEST_STORAGE"
cleanup() { rm -rf "$TEST_STORAGE"; }
trap cleanup EXIT

LOG="$(mktemp -t cleartone-xctest).log"

run() {
  if [ $# -gt 0 ]; then
    xcrun xctest -XCTest "$1" build/Debug/ClearToneTests.xctest
  else
    xcrun xctest build/Debug/ClearToneTests.xctest
  fi
}

set +e
run "$@" > "$LOG" 2>&1
STATUS=$?
set -e

grep -E "^(Test Suite 'All tests'|Test Suite 'ClearToneTests)" -A 1 "$LOG" | tail -2 || true
# 跳过数必须显式报出来：XCTSkip 会让用例「不失败」，
# 一次 6 条全跳过的运行和一次全绿在默认输出里长得一模一样。
SKIPPED=$(grep -c "was skipped" "$LOG" || true)
if [ "${SKIPPED:-0}" -gt 0 ]; then
  echo "⚠️  $SKIPPED 处被 XCTSkip 跳过（环境原因），别把这次运行当成全绿"
  grep -E "was skipped" "$LOG" | sed 's/^/   /' | head -20
fi

if [ "$STATUS" -ne 0 ]; then
  echo "--- 失败详情 ---"
  grep -E "error:|failed \(" "$LOG" | head -40
  echo "--- 完整日志：$LOG"
  exit "$STATUS"
fi
rm -f "$LOG"
