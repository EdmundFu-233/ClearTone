#!/bin/bash
# 本机（macOS/Linux 开发环境）Release 构建。
#
# Windows 发布包请在 Windows 上执行 scripts/build-app.ps1（Qt 无法从 macOS
# 交叉发布 Windows 产物）。本脚本只用于开发机自测。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${CT_BUILD_DIR:-$WINDOWS_DIR/build-release}"

QT_PREFIX="${QT_PREFIX:-}"
if [ -z "$QT_PREFIX" ] && command -v brew >/dev/null 2>&1; then
    QT_PREFIX="$(brew --prefix qt 2>/dev/null || true)"
fi

CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release)
if [ -n "$QT_PREFIX" ]; then
    CMAKE_ARGS+=("-DCMAKE_PREFIX_PATH=$QT_PREFIX")
fi

echo "=== 配置（${BUILD_DIR}） ==="
cmake -S "$WINDOWS_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}" "$@"

echo "=== 构建 ==="
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
cmake --build "$BUILD_DIR" -j"$JOBS"

echo "完成：$BUILD_DIR/ClearTone"
