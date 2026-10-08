#!/bin/bash
# 构建 Windows 发布包（可在 macOS/Linux 上交叉发布）
# 用法：./scripts/build-app.sh [x64|arm64|all]   （默认 x64）
# 产物：windows/publish/win-<arch>/ 与 windows/publish/ClearTone-win-<arch>.zip
set -euo pipefail

ARCH_ARG="${1:-x64}"
case "$ARCH_ARG" in
    x64|arm64|all) ;;
    *)
        echo "用法：$0 [x64|arm64|all]" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(dirname "$SCRIPT_DIR")"

build_arch() {
    local arch="$1"
    local publish_dir="$WINDOWS_DIR/publish/win-$arch"

    echo "=== [$arch] 1/3 准备辅助进程运行时（win-$arch node.exe） ==="
    "$SCRIPT_DIR/fetch-node-win.sh" "$arch"

    echo "=== [$arch] 2/3 dotnet publish (win-$arch) ==="
    rm -rf "$publish_dir"
    local vlc_props=(-p:VlcWindowsX86Enabled=false)
    if [ "$arch" = "x64" ]; then
        vlc_props+=(-p:VlcWindowsArm64Enabled=false)
    else
        vlc_props+=(-p:VlcWindowsX64Enabled=false)
    fi
    dotnet publish "$WINDOWS_DIR/src/ClearTone/ClearTone.csproj" \
      -c Release -f net8.0-windows10.0.19041.0 -r "win-$arch" --self-contained true \
      -p:PublishSingleFile=false \
      "${vlc_props[@]}" \
      -o "$publish_dir"

    echo "=== [$arch] 3/3 校验与打包 ==="
    for required in ClearTone.exe helper/bin/node.exe helper/api/app.js helper/api/server.js "libvlc/win-$arch/libvlc.dll"; do
        if [ ! -e "$publish_dir/$required" ]; then
            echo "缺少产物: $publish_dir/$required" >&2
            exit 1
        fi
    done

    local zip_path="$WINDOWS_DIR/publish/ClearTone-win-$arch.zip"
    rm -f "$zip_path"
    (cd "$publish_dir" && zip -qr "$zip_path" .)
    echo "完成：$zip_path"
}

if [ "$ARCH_ARG" = "all" ]; then
    build_arch x64
    build_arch arm64
else
    build_arch "$ARCH_ARG"
fi
