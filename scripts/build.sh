#!/usr/bin/env bash
# Build the visionOS app. Usage: scripts/build.sh [device|sim] [extra xcodebuild args]
# Prints unique errors and the final status line; full log in build/logs/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"
vos_config || { echo "Run 'make setup' first."; exit 1; }
# (Re)generate the Xcode project when missing or when the generator/config changed.
PROJ="$ROOT/src/platform/visionos/RTCW.xcodeproj/project.pbxproj"
if [[ ! -f "$PROJ" || "$ROOT/scripts/gen-project.py" -nt "$PROJ" || "$VOS_CONFIG" -nt "$PROJ" ]]; then
  bash "$ROOT/scripts/gen-project.sh" >/dev/null
fi
KIND="${1:-device}"; shift || true
DEST='generic/platform=visionOS'; [[ $KIND == sim ]] && DEST='generic/platform=visionOS Simulator'
LOG="$ROOT/build/logs/build-$KIND.log"
mkdir -p "$ROOT/build/logs"
bash "$ROOT/scripts/stage-engine.sh" >/dev/null
xcodebuild -project "$ROOT/src/platform/visionos/RTCW.xcodeproj" -scheme RTCW -destination "$DEST" \
  -configuration "${CONFIG:-Debug}" -derivedDataPath "$ROOT/build/dd" CODE_SIGNING_ALLOWED=NO "$@" build > "$LOG" 2>&1
rc=$?
grep -E "error:|duplicate symbol|Undefined symbols|^  \"_" "$LOG" | sed "s|$ROOT/||" | sort | uniq -c | sort -rn | head -40
grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$LOG"
exit $rc
