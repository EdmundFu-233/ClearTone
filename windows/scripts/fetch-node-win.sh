#!/bin/bash
# 下载 Windows 版 Node.js（与 macOS 端一致的 v22.23.4），放到 windows/runtime/win-<arch>/node.exe。
# 该文件不入库；打包时由 ClearTone.csproj 按 RuntimeIdentifier 复制到输出目录的 helper/bin/ 下。
#
# 用法：./scripts/fetch-node-win.sh [x64|arm64]   （默认 x64）
set -euo pipefail

NODE_VERSION="22.23.4"
ARCH="${1:-x64}"
case "$ARCH" in
    x64) NODE_SHA256="dccc52de28d8df2ee22d2062424f8c563070d95d8ad70c54c4bf01d590dec14f" ;;
    arm64) NODE_SHA256="64d9f6e69b4703870e8cd30a3477127df8b683ea04feb03660e439396549042a" ;;
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
    EXISTING_SHA256="$(shasum -a 256 "$OUT_DIR/node.exe" | awk '{print $1}')"
    if [ "$EXISTING_SHA256" = "$NODE_SHA256" ]; then
        echo "node.exe 已存在且哈希匹配，跳过下载：$OUT_DIR/node.exe"
        exit 0
    fi
    echo "现有 node.exe 版本/哈希不匹配，重新下载"
fi

echo "下载 $URL"
curl -fL --retry 3 -o "$OUT_DIR/node.exe.part" "$URL"
echo "$NODE_SHA256  $OUT_DIR/node.exe.part" | shasum -a 256 -c -
mv "$OUT_DIR/node.exe.part" "$OUT_DIR/node.exe"
echo "已写入 $OUT_DIR/node.exe"
