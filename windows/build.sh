#!/bin/bash
# ClearTone（Windows / Qt）一键编译脚本（macOS / Linux 开发环境）。
# 准备辅助进程 → CMake 配置 → 构建 →（可选）测试 / 运行。
#
# Windows 上的发布打包请用 build.ps1 / scripts\build-app.ps1。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HELPER_DIR="$REPO_ROOT/ClearTone/Resources/HelperRuntime"

CONFIG="Debug"
BUILD_DIR="${WINDOWS_BUILD_DIR:-$SCRIPT_DIR/build}"
QT_PREFIX="${QT_PREFIX:-}"
VLC_ROOT="${CT_VLC_ROOT:-}"
RUN_TESTS=0
RUN_APP=0
CLEAN=0
SKIP_HELPER=0
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

usage() {
    cat <<'EOF'
用法: ./build.sh [选项]

  --tests          构建后运行全部离线单测（ctest）
  --run            构建后运行应用
  --release        Release 构建（默认 Debug）
  --clean          清空构建目录后重新配置
  --qt PATH        Qt 安装前缀（默认 $QT_PREFIX 或 brew --prefix qt）
  --vlc-root PATH  可选：libVLC SDK 根目录（含 include/ 与 lib/）
  --dir PATH       构建目录（默认 windows/build）
  --jobs N         并行编译任务数
  --skip-helper    跳过辅助进程准备
  -h, --help       显示本帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tests) RUN_TESTS=1 ;;
        --run) RUN_APP=1 ;;
        --release) CONFIG="Release" ;;
        --clean) CLEAN=1 ;;
        --qt) shift; QT_PREFIX="$1" ;;
        --vlc-root) shift; VLC_ROOT="$1" ;;
        --dir) shift; BUILD_DIR="$1" ;;
        --jobs) shift; JOBS="$1" ;;
        --skip-helper) SKIP_HELPER=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "未知参数：$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

# ---------------- 依赖检查 ----------------

if ! command -v cmake >/dev/null 2>&1; then
    echo "缺少 cmake：macOS 可用 brew install cmake 安装。" >&2
    exit 1
fi

if [ -z "$QT_PREFIX" ] && command -v brew >/dev/null 2>&1; then
    QT_PREFIX="$(brew --prefix qt 2>/dev/null || true)"
fi
if [ -z "$QT_PREFIX" ]; then
    echo "未找到 Qt：请用 --qt PATH 指定 Qt 安装前缀（含 lib/cmake/Qt6）。" >&2
    exit 1
fi
if [ ! -d "$QT_PREFIX/lib/cmake/Qt6" ]; then
    echo "Qt 前缀无效（缺少 lib/cmake/Qt6）：$QT_PREFIX" >&2
    exit 1
fi

# ---------------- 辅助进程 ----------------

if [ "$SKIP_HELPER" -eq 0 ]; then
    echo "=== [1/4] 准备辅助进程运行时 ==="
    if [ ! -f "$HELPER_DIR/api/app.js" ]; then
        echo "缺少辅助进程业务代码：$HELPER_DIR/api/app.js" >&2
        exit 1
    fi
    if [ ! -x "$HELPER_DIR/bin/node" ] || [ ! -d "$HELPER_DIR/api/node_modules" ]; then
        if [ "$(uname -s)" = "Darwin" ]; then
            "$REPO_ROOT/scripts/setup-helper.sh"
        else
            echo "提示：Linux 开发环境需要自行准备 $HELPER_DIR/bin/node 与 api/node_modules。" >&2
        fi
    fi
fi

# ---------------- 配置与构建 ----------------

if [ "$CLEAN" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
    echo "清理：$BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE="$CONFIG"
    -DCMAKE_PREFIX_PATH="$QT_PREFIX"
    -DCT_BUILD_TESTS=ON
)
if [ -n "$VLC_ROOT" ]; then
    CMAKE_ARGS+=("-DCT_VLC_ROOT=$VLC_ROOT")
fi

echo "=== [2/4] CMake 配置（${CONFIG}，Qt: ${QT_PREFIX}）==="
cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"

echo "=== [3/4] 构建（-j${JOBS}） ==="
cmake --build "$BUILD_DIR" -j"$JOBS"

APP_BINARY="$BUILD_DIR/ClearTone"

if [ "$RUN_TESTS" -eq 1 ]; then
    echo "=== [4/4] 离线单测 ==="
    ctest --test-dir "$BUILD_DIR" --output-on-failure
fi

if [ "$RUN_APP" -eq 1 ]; then
    echo "启动 $APP_BINARY"
    "$APP_BINARY"
fi

echo "完成：$APP_BINARY"
