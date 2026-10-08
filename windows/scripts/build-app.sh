#!/bin/bash
# 构建 Windows x64 发布包（可在 macOS/Linux 上交叉发布）
# 产物：windows/publish/win-x64/ 与 windows/publish/ClearTone-win-x64.zip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(dirname "$SCRIPT_DIR")"
PUBLISH_DIR="$WINDOWS_DIR/publish/win-x64"

echo "=== 1/3 准备辅助进程运行时（win-x64 node.exe） ==="
"$SCRIPT_DIR/fetch-node-win.sh"

echo "=== 2/3 dotnet publish (win-x64) ==="
rm -rf "$PUBLISH_DIR"
dotnet publish "$WINDOWS_DIR/src/ClearTone/ClearTone.csproj" \
  -c Release -f net8.0-windows10.0.19041.0 -r win-x64 --self-contained true \
  -p:PublishSingleFile=false \
  -o "$PUBLISH_DIR"

echo "=== 3/3 校验与打包 ==="
for required in ClearTone.exe helper/bin/node.exe helper/api/app.js helper/api/server.js; do
    if [ ! -e "$PUBLISH_DIR/$required" ]; then
        echo "缺少产物: $PUBLISH_DIR/$required" >&2
        exit 1
    fi
done

ZIP_PATH="$WINDOWS_DIR/publish/ClearTone-win-x64.zip"
rm -f "$ZIP_PATH"
(cd "$PUBLISH_DIR" && zip -qr "$ZIP_PATH" .)
echo "完成：$ZIP_PATH"
