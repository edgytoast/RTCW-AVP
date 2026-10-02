#!/usr/bin/env bash
# Build (signed, Personal Team), install and launch RTCW on the paired Vision Pro.
# Game data (pak0 + sp_pak1..4, ~636 MB) is copied into Documents/main only when
# missing; it survives reinstalls.
#
# Usage: scripts/device-run.sh [--debug] [--no-launch] [engine args...]
#   default: Release build, launches with the intro skipped
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"
vos_config || { echo "Run 'make setup' first."; exit 1; }
BUNDLE="$BUNDLE_ID"
CONFIG=Release LAUNCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG=Debug; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    *) break ;;
  esac
done
ARGS=("$@"); [[ ${#ARGS[@]} -eq 0 ]] && ARGS=(+set com_introplayed 1 +set in_padDebug 1)
# The app shows a VR/flat start screen unless -vr or -flat is passed (e.g. make vr).

find_dev() { xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /Vision Pro/ && /connected|available \(paired\)/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1; }
dev=$(find_dev)
if [[ -z "$dev" ]]; then
  echo "==> waiting up to 90 s for the Vision Pro (put it on, unlock it)..."
  for _ in $(seq 18); do sleep 5; dev=$(find_dev); [[ -n "$dev" ]] && break; done
fi
[[ -n "$dev" ]] || { cat <<'MSG'
Vision Pro not reachable. Check:
  - headset worn and unlocked (it drops off the network when asleep)
  - same Wi-Fi as this Mac, VPN off on the Mac
  - on the headset: Settings > General > Remote Devices (keeps it discoverable)
  - Xcode > Window > Devices and Simulators shows it as connected
MSG
exit 1; }

echo "==> building ($CONFIG)"
bash "$ROOT/scripts/stage-engine.sh" >/dev/null
PROJ="$ROOT/src/platform/visionos/RTCW.xcodeproj/project.pbxproj"
[[ -f "$PROJ" && ! "$VOS_CONFIG" -nt "$PROJ" && ! "$ROOT/scripts/gen-project.py" -nt "$PROJ" ]] || bash "$ROOT/scripts/gen-project.sh" >/dev/null
xcodebuild -project "$ROOT/src/platform/visionos/RTCW.xcodeproj" -scheme RTCW -configuration "$CONFIG" \
  -destination "id=$dev" -derivedDataPath "$ROOT/build/dd" -allowProvisioningUpdates build \
  > "$ROOT/build/logs/build-signed.log" 2>&1 || { grep -E "error:" "$ROOT/build/logs/build-signed.log" | head; exit 1; }
APP="$ROOT/build/dd/Build/Products/$CONFIG-xros/RTCW.app"

echo "==> installing"
xcrun devicectl device install app --device "$dev" "$APP" >/dev/null

have=$(xcrun devicectl device info files --device "$dev" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --subdirectory Documents/main 2>/dev/null || true)
for p in "${VOS_REQUIRED_PAKS[@]}" "${VOS_OPTIONAL_PAKS[@]}"; do
  if grep -q "^$p.pk3 " <<<"$have"; then continue; fi
  src="$(vos_pak_path "$p")"
  [[ -n "$src" ]] || { echo "==> $p.pk3 not in $RTCW_DATA (skipped; import it in the app if needed)"; continue; }
  echo "==> copying $p.pk3"
  xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source "$src" --destination "Documents/main/$p.pk3" >/dev/null
done

[[ $LAUNCH == 1 ]] || { echo "installed (not launched)"; exit 0; }
echo "==> launching"
if ! out=$(xcrun devicectl device process launch --device "$dev" --terminate-existing -- "$BUNDLE" +set logfile 2 "${ARGS[@]}" 2>&1); then
  if grep -q "explicitly trusted" <<<"$out"; then
    # visionOS refuses remote launches of free Personal Team apps even when trusted.
    echo "Installed. Open RTCW from the Home View on the headset (remote launch is not allowed for free-team apps)."
    exit 0
  fi
  echo "$out" | head -8
  exit 1
fi
echo "launched on Vision Pro. Free Personal Team builds expire after 7 days: just re-run this script."
