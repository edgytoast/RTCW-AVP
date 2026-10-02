#!/usr/bin/env bash
# Install and run RTCW in the visionOS Simulator, capturing the engine console.
# Usage: [SHOT=out.png] scripts/sim-run.sh <seconds> [engine args...]
#   e.g. scripts/sim-run.sh 70 +set dedicated 1 +map escape1
# Game data: copies pak0 + sp_pak1..4.pk3 from RTCW_DATA (config.local)
# into the app's Documents/main (lowercase dir; visionOS FS is case-sensitive).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-30}"; shift || true
source "$ROOT/scripts/config.sh"
vos_config || { echo "Run 'make setup' first."; exit 1; }
BUNDLE="$BUNDLE_ID"
APP="$ROOT/build/dd/Build/Products/${CONFIG:-Debug}-xrsimulator/RTCW.app"
LOG="$ROOT/build/logs/sim-run.log"

# Use the first available visionOS simulator.
udid=$(xcrun simctl list devices available | awk '/-- visionOS/{f=1;next} /^--/{f=0} f' | grep -oE '[0-9A-F-]{36}' | head -1)
[[ -n "$udid" ]] || { echo "no visionOS simulator available"; exit 1; }
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$APP"

container=$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)
[[ -d "$container" ]] || { echo "no app data container: '$container'"; exit 1; }
mkdir -p "$container/Documents/main"
for p in "${VOS_REQUIRED_PAKS[@]}" "${VOS_OPTIONAL_PAKS[@]}"; do
  src="$(vos_pak_path "$p")"; dst="$container/Documents/main/$p.pk3"   # lowercase on device
  [[ -n "$src" ]] || continue
  [[ -f "$dst" && $(stat -f %z "$src") == $(stat -f %z "$dst") ]] || cp "$src" "$dst"
done

xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1
QLOG="$container/Library/Application Support/RTCW/main/rtcwconsole.log"
rm -f "$QLOG"
# Engine console -> rtcwconsole.log (logfile 2 = flush every write); os_log drops lines.
xcrun simctl launch "$udid" "$BUNDLE" +set logfile 2 "$@" >/dev/null
sleep "$SECS"
# Optional: SHOT=path.png takes a simulator screenshot before terminating.
[[ -n "${SHOT:-}" ]] && xcrun simctl io "$udid" screenshot "$SHOT" >/dev/null 2>&1
xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1
cp "$QLOG" "$LOG" 2>/dev/null || : > "$LOG"
echo "udid=$udid log=$LOG lines=$(wc -l < "$LOG")"
