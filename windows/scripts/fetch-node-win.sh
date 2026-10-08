#!/bin/bash
# 下载 Windows 版 Node.js（与 macOS 端一致的 v22.14.0），放到 windows/runtime/win-<arch>/node.exe。
# 该文件不入库；打包时由 ClearTone.csproj 按 RuntimeIdentifier 复制到输出目录的 helper/bin/ 下。
#
# 用法：./scripts/fetch-node-win.sh [x64|arm64]   （默认 x64）
set -euo pipefail

NODE_VERSION="22.14.0"
ARCH="${1:-x64}"
case "$ARCH" in
    x64|arm64) ;;
    *)
        echo "用法：$0 [x64|arm64]" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$WINDOWS_DIR/runtime/win-$ARCH"
URL="https://nodejs.org/dist/v$NODE_VERSION/win-$ARCH/node.exe"

mkdir -p "$OUT_DIR"

# 兼容旧布局：runtime/node.exe 视为 win-x64 的产物
LEGACY="$WINDOWS_DIR/runtime/node.exe"
if [ "$ARCH" = "x64" ] && [ -f "$LEGACY" ] && [ ! -f "$OUT_DIR/node.exe" ]; then
    mv "$LEGACY" "$OUT_DIR/node.exe"
    echo "已迁移 $LEGACY -> $OUT_DIR/node.exe"
fi

if [ -f "$OUT_DIR/node.exe" ]; then
    echo "node.exe 已存在，跳过下载：$OUT_DIR/node.exe"
    exit 0
fi

echo "下载 $URL"
curl -fL --retry 3 -o "$OUT_DIR/node.exe.part" "$URL"
mv "$OUT_DIR/node.exe.part" "$OUT_DIR/node.exe"
echo "已写入 $OUT_DIR/node.exe"
