#!/bin/bash
# 构建并运行全部离线单测（Qt Test）。
# 用法：./scripts/run-tests.sh [构建目录]   （默认 windows/build-dev）
# 测试不需要网络、不需要辅助进程；持久化由 CTest 逐用例重定向到临时目录。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${1:-$WINDOWS_DIR/build-dev}"
if [ $# -gt 0 ]; then shift; fi

QT_PREFIX="${QT_PREFIX:-}"
if [ -z "$QT_PREFIX" ] && command -v brew >/dev/null 2>&1; then
    QT_PREFIX="$(brew --prefix qt 2>/dev/null || true)"
fi

CMAKE_ARGS=()
if [ -n "$QT_PREFIX" ]; then
    CMAKE_ARGS+=("-DCMAKE_PREFIX_PATH=$QT_PREFIX")
fi

echo "=== 配置（${BUILD_DIR}） ==="
cmake -S "$WINDOWS_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"

echo "=== 构建 ==="
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
cmake --build "$BUILD_DIR" -j"$JOBS"

echo "=== 运行测试 ==="
ctest --test-dir "$BUILD_DIR" --output-on-failure "$@"
