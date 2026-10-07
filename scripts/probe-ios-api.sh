#!/bin/bash
# 显式联网的匿名只读探针；不属于离线单元测试。
set -euo pipefail
cd "$(dirname "$0")/.."
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cleartone-ios-probe-XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PROBE_DIR/modules" \
  ClearTone/Core/Models/MusicError.swift ClearTone/Core/Logging/CTLog.swift \
  ClearTone/Providers/Netease/{NeteaseCrypto,OrderedJSON,NeteaseEndpoint,NeteaseMobileRoute,NeteaseXeapi,NeteaseDirectTransport}.swift \
  scripts/probes/ios-api.swift -o "$PROBE_DIR/probe"
"$PROBE_DIR/probe" "$@"
