#!/usr/bin/env bash
# Fetch the engine console log (rtcwconsole.log) from the Vision Pro to build/logs/device.log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"
vos_config || { echo "Run 'make setup' first."; exit 1; }
dev=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /Vision Pro/ && /connected|available \(paired\)/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[[ -n "$dev" ]] || { echo "Vision Pro not reachable"; exit 1; }
xcrun devicectl device copy from --device "$dev" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source "Library/Application Support/RTCW/main/rtcwconsole.log" --destination "$ROOT/build/logs/device.log" >/dev/null
echo "build/logs/device.log ($(wc -l < "$ROOT/build/logs/device.log") lines)"
