#!/usr/bin/env bash
# One-time setup on a new Mac: `make setup`. Downloads every prerequisite automatically
# (visionOS SDK/Simulator, xcodegen, engine sources, ANGLE). The only things it cannot
# fetch are Xcode itself (App Store) and your game files (your own copy, asked for).
# Safe to re-run: finished steps are skipped.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"
mkdir -p "$ROOT/build/logs"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
step() { printf '  … %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

echo "1/7 Xcode"
[[ -f "$VOS_CONFIG" ]] && source "$VOS_CONFIG"
DEVELOPER_DIR="$(vos_detect_xcode)"
if [[ -z "$DEVELOPER_DIR" ]]; then
  found="$(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')"
  [[ -n "$found" ]] && die "Found ${found}but none is Xcode 26 or newer. Update Xcode from the App Store."
  open "macappstore://apps.apple.com/app/xcode/id497799835" 2>/dev/null
  die "Install Xcode 26+ (App Store page opened), launch it once, then run 'make setup' again."
fi
export DEVELOPER_DIR
if ! xout="$(xcodebuild -version 2>&1)"; then
  grep -qi "license" <<<"$xout" && die "Accept the Xcode license first: sudo xcodebuild -license accept   (then re-run)"
  die "Xcode at ${DEVELOPER_DIR%/Contents/Developer} does not run: open it once to finish installing, then re-run. ($xout)"
fi
xv=$(xcodebuild -version | awk '/Xcode/{print $2}')
[[ ${xv%%.*} -ge 26 ]] || die "Xcode $xv is too old: update to Xcode 26 or newer (App Store)."
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || { step "finishing Xcode first-launch setup"; xcodebuild -runFirstLaunch >/dev/null 2>&1; }
ok "Xcode $xv (${DEVELOPER_DIR%/Contents/Developer})"

# Tell the user once what will be downloaded, then do it without further questions.
need=()
xcrun --sdk xros --show-sdk-path >/dev/null 2>&1 && xcrun simctl list runtimes 2>/dev/null | grep -qi visionos || need+=("visionOS platform + Simulator (~8 GB)")
command -v xcodegen >/dev/null || [[ -x "$ROOT/build/tools/xcodegen/bin/xcodegen" ]] || need+=("xcodegen (~10 MB)")
[[ -d "$ROOT/upstream/iortcw/.git" ]] || need+=("iortcw engine source, pinned commit (~150 MB)")
[[ -f "$ROOT/build/angle/lib/libANGLE.a" && -f "$ROOT/build/angle/lib/libANGLE-sim.a" ]] || need+=("ANGLE source + build (~12 GB, up to an hour)")
if (( ${#need[@]} )); then
  echo "   Will download:"; printf '     - %s\n' "${need[@]}"
  free_gb=$(df -g "$ROOT" | awk 'NR==2{print $4}')
  [[ " ${need[*]} " == *ANGLE* && $free_gb -lt 25 ]] && die "Only ${free_gb} GB free; free at least 25 GB and re-run."
fi

echo "2/7 visionOS SDK and Simulator"
if xcrun --sdk xros --show-sdk-path >/dev/null 2>&1 && xcrun simctl list runtimes 2>/dev/null | grep -qi visionos; then
  ok "installed"
else
  step "downloading (xcodebuild -downloadPlatform visionOS)"
  xcodebuild -downloadPlatform visionOS > "$ROOT/build/logs/download-visionos.log" 2>&1 \
    || die "download failed: see build/logs/download-visionos.log"
  ok "installed"
fi

echo "3/7 Tools"
command -v python3 >/dev/null || die "python3 missing (comes with Xcode): xcode-select --install"
command -v git >/dev/null || die "git missing (comes with Xcode): xcode-select --install"
XCODEGEN="$(vos_xcodegen)" || die "could not get xcodegen"
ok "python3, git, xcodegen ($XCODEGEN)"

echo "4/7 Local config (signing team, bundle id, game data)"
vos_config --interactive || die "No signing team. Xcode > Settings > Accounts: add your Apple ID, then Manage Certificates > + > Apple Development."
ok "team $TEAM_ID, bundle $BUNDLE_ID"
[[ -n "${RTCW_DATA:-}" ]] && ok "game data $RTCW_DATA" || echo "  (no game data folder: import the pk3 files in the app instead)"

echo "5/7 Engine source (iortcw, pinned in upstream/PINS)"
bash "$ROOT/scripts/fetch-upstream.sh" > "$ROOT/build/logs/fetch-upstream.log" 2>&1 \
  || die "fetch failed: see build/logs/fetch-upstream.log"
ok "$(tail -1 "$ROOT/build/logs/fetch-upstream.log")"

echo "6/7 ANGLE (OpenGL ES -> Metal)"
if [[ -f "$ROOT/build/angle/lib/libANGLE.a" && -f "$ROOT/build/angle/lib/libANGLE-sim.a" ]]; then
  ok "already built"
else
  step "downloading and building (log: build/logs/angle.log; this is the long step)"
  bash "$ROOT/scripts/build-angle.sh" > "$ROOT/build/logs/angle.log" 2>&1 \
    || die "ANGLE build failed: see build/logs/angle.log (re-run 'make setup' to resume)"
  ok "built"
fi

echo "7/7 Xcode project and test build"
bash "$ROOT/scripts/stage-engine.sh" >/dev/null || die "engine staging failed"
bash "$ROOT/scripts/gen-project.sh" >/dev/null || die "project generation failed"
bash "$ROOT/scripts/build.sh" device >/dev/null || die "build failed: bash scripts/build.sh device"
ok "builds for Vision Pro"

cat <<EOF

Setup complete. Next:
  make vr        install on your Vision Pro (VR), then open RTCW from the Home View
  make flat      same, flat window mode
  make sim       run in the visionOS Simulator
First install only: on the headset, Settings > General > VPN & Device Management > trust your Apple ID.
EOF
