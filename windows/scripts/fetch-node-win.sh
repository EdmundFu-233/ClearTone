#!/bin/bash
# 下载 Windows x64 版 Node.js（与 macOS 端一致的 v22.14.0），放到 windows/runtime/node.exe。
# 该文件不入库；打包时由 ClearTone.csproj 复制到输出目录的 helper/bin/ 下。
set -euo pipefail

NODE_VERSION="22.14.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$WINDOWS_DIR/runtime"
URL="https://nodejs.org/dist/v$NODE_VERSION/win-x64/node.exe"

mkdir -p "$OUT_DIR"
if [ -f "$OUT_DIR/node.exe" ]; then
    echo "node.exe 已存在，跳过下载：$OUT_DIR/node.exe"
    exit 0
fi

echo "下载 $URL"
curl -fL --retry 3 -o "$OUT_DIR/node.exe.part" "$URL"
mv "$OUT_DIR/node.exe.part" "$OUT_DIR/node.exe"
echo "已写入 $OUT_DIR/node.exe"
