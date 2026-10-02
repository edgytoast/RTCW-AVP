#!/usr/bin/env bash
# Shared configuration for all scripts. Sourced, not executed.
#
# Personal values live in config.local (git-ignored), created on first use:
#   TEAM_ID     Apple signing team (auto-detected from the Mac's "Apple Development" certificate)
#   BUNDLE_ID   app bundle identifier (must be unique for free Personal Teams)
#   RTCW_DATA   folder containing pak0.pk3 and sp_pak1..4.pk3 (auto-detected or asked)
#
# Usage in scripts:  source "$(dirname "$0")/config.sh"; vos_config [--interactive]

VOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOS_CONFIG="$VOS_ROOT/config.local"
VOS_REQUIRED_PAKS=(pak0 sp_pak1 sp_pak2 sp_pak3)
VOS_OPTIONAL_PAKS=(sp_pak4)

# Xcode: use the selected one if it works and is >= 26, otherwise the newest installed
# Xcode*.app >= 26 (several versions side by side are common). Selected via DEVELOPER_DIR,
# so no sudo/xcode-select change is needed. Echoes the Developer dir, or nothing.
vos_xcode_version() { # app path -> major.minor
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null
}
vos_detect_xcode() {
  local cur app best="" bestv="0"
  if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then echo "$DEVELOPER_DIR"; return 0; fi
  cur="$(xcode-select -p 2>/dev/null)"
  if [[ "$cur" == *.app/Contents/Developer ]]; then
    local v; v="$(vos_xcode_version "${cur%/Contents/Developer}")"
    [[ "${v%%.*}" -ge 26 ]] 2>/dev/null && { echo "$cur"; return 0; }
  fi
  while IFS= read -r app; do
    [[ -d "$app" ]] || continue
    local v; v="$(vos_xcode_version "$app")"
    [[ -n "$v" && "${v%%.*}" -ge 26 ]] 2>/dev/null || continue
    if [[ "$(printf '%s\n%s\n' "$bestv" "$v" | sort -V | tail -1)" == "$v" ]]; then best="$app"; bestv="$v"; fi
  done < <( { mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null
              ls -d /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app 2>/dev/null; } | sort -u )
  [[ -n "$best" ]] && echo "$best/Contents/Developer"
}

# Team ID = OU of the newest valid "Apple Development" certificate in the keychain.
vos_detect_team() {
  security find-certificate -a -c "Apple Development" -p 2>/dev/null | python3 -c '
import re, subprocess, sys
best = None
for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", sys.stdin.read(), re.S):
    out = subprocess.run(["openssl", "x509", "-noout", "-subject", "-enddate", "-checkend", "0"],
                         input=pem.encode(), capture_output=True)
    if out.returncode != 0:
        continue                                   # expired
    text = out.stdout.decode()
    ou = re.search(r"OU\s*=\s*([A-Z0-9]{10})", text)
    end = re.search(r"notAfter=(.*)", text)
    if ou and (best is None or end.group(1) > best[1]):
        best = (ou.group(1), end.group(1))
print(best[0] if best else "")
'
}

# Does $1 contain the required single-player pk3s? (case-insensitive file names)
vos_valid_data() {
  local dir="$1" p
  [[ -d "$dir" ]] || return 1
  for p in "${VOS_REQUIRED_PAKS[@]}"; do
    [[ -n "$(find "$dir" -maxdepth 1 -iname "$p.pk3" -print -quit 2>/dev/null)" ]] || return 1
  done
}

# Candidate data folders: common GOG/Steam install locations, then a Spotlight search.
vos_find_data() {
  local c
  local candidates=(
    "$HOME/Library/Application Support/Steam/steamapps/common/Return to Castle Wolfenstein/Main"
    "$HOME/Library/Application Support/Steam/steamapps/common/Return to Castle Wolfenstein/main"
    "/Applications/Return to Castle Wolfenstein.app/Contents/Resources/game/Main"
    "$HOME/Applications/Return to Castle Wolfenstein.app/Contents/Resources/game/Main"
  )
  while IFS= read -r c; do candidates+=("$c"); done < <(
    { mdfind -name "sp_pak1.pk3" 2>/dev/null
      find "$HOME/Downloads" "$HOME/Documents" "$HOME/Games" -maxdepth 5 -iname "sp_pak1.pk3" 2>/dev/null
    } | xargs -I{} dirname "{}" | sort -u)
  for c in "${candidates[@]}"; do
    vos_valid_data "$c" && { echo "$c"; return 0; }
  done
  return 1
}

vos_write_config() {
  cat > "$VOS_CONFIG" <<EOF
# Local settings for this Mac (git-ignored). Re-run 'make setup' or edit by hand.
TEAM_ID="$TEAM_ID"
BUNDLE_ID="$BUNDLE_ID"
RTCW_DATA="$RTCW_DATA"
DEVELOPER_DIR="${DEVELOPER_DIR:-}"
EOF
  echo "==> wrote $VOS_CONFIG"
}

# Load config.local; fill in missing values (detect, then ask if --interactive).
vos_config() {
  local interactive=0 changed=0 answer
  [[ "${1:-}" == "--interactive" ]] && interactive=1
  [[ -f "$VOS_CONFIG" ]] && source "$VOS_CONFIG"
  [[ -n "${DEVELOPER_DIR:-}" && ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] && { DEVELOPER_DIR=""; changed=1; }
  if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(vos_detect_xcode)"
    [[ -n "$DEVELOPER_DIR" ]] && changed=1
  fi
  [[ -n "${DEVELOPER_DIR:-}" ]] && export DEVELOPER_DIR
  [[ -n "${DEVELOPER_DIR:-}" && -f "$VOS_CONFIG" ]] && ! grep -q "^DEVELOPER_DIR=\"$DEVELOPER_DIR\"" "$VOS_CONFIG" && changed=1

  if [[ -z "${TEAM_ID:-}" ]]; then
    TEAM_ID="$(vos_detect_team)"
    if [[ -z "$TEAM_ID" ]]; then
      echo "No 'Apple Development' signing certificate found."
      echo "Open Xcode > Settings > Accounts, add your Apple ID, then Manage Certificates > + > Apple Development."
      [[ $interactive == 1 ]] && { read -r -p "Or enter your 10-character Team ID: " TEAM_ID; }
      [[ -n "$TEAM_ID" ]] || return 1
    else
      echo "==> signing team (from certificate): $TEAM_ID"
    fi
    changed=1
  fi

  if [[ -z "${BUNDLE_ID:-}" ]]; then
    BUNDLE_ID="com.$(echo "${USER:-player}" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z').rtcw"
    changed=1
  fi

  if [[ -z "${RTCW_DATA:-}" ]] || ! vos_valid_data "$RTCW_DATA"; then
    RTCW_DATA="$(vos_find_data || true)"
    if [[ -n "$RTCW_DATA" ]]; then
      echo "==> found game data: $RTCW_DATA"
      if [[ $interactive == 1 ]]; then
        read -r -p "Use this folder? [Y/n] " answer
        [[ "$answer" =~ ^[Nn] ]] && RTCW_DATA=""
      fi
    fi
    while [[ -z "$RTCW_DATA" && $interactive == 1 ]]; do
      echo "Where is your RTCW game data? (the folder with pak0.pk3 and sp_pak1.pk3 ... sp_pak3.pk3;"
      echo "GOG: '<install>/Main', Steam: '.../Return to Castle Wolfenstein/Main'). Drag the folder here:"
      read -r -p "> " answer
      answer="${answer#\'}"; answer="${answer%\'}"; answer="${answer//\\ / }"; answer="${answer%/}"
      if vos_valid_data "$answer"; then RTCW_DATA="$answer"; else echo "Missing ${VOS_REQUIRED_PAKS[*]}.pk3 in '$answer'."; fi
    done
    [[ -n "$RTCW_DATA" ]] && changed=1
  fi

  [[ $changed == 1 ]] && vos_write_config
  export TEAM_ID BUNDLE_ID RTCW_DATA
  [[ -n "${DEVELOPER_DIR:-}" ]] && export DEVELOPER_DIR
  [[ -n "$TEAM_ID" && -n "$BUNDLE_ID" ]]
}

# xcodegen: system install if present, else a local copy in build/tools (downloaded on demand,
# no Homebrew or admin rights needed). Echoes the executable path.
vos_xcodegen() {
  local local_bin="$VOS_ROOT/build/tools/xcodegen/bin/xcodegen" tmp
  if command -v xcodegen >/dev/null; then command -v xcodegen; return 0; fi
  if [[ ! -x "$local_bin" ]]; then
    echo "==> downloading xcodegen (GitHub release)" >&2
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/xcodegen.zip" https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip \
      && mkdir -p "$VOS_ROOT/build/tools" && unzip -q -o "$tmp/xcodegen.zip" -d "$VOS_ROOT/build/tools" \
      || { rm -rf "$tmp"; echo "xcodegen download failed" >&2; return 1; }
    rm -rf "$tmp"
    xattr -dr com.apple.quarantine "$VOS_ROOT/build/tools/xcodegen" 2>/dev/null || true
  fi
  echo "$local_bin"
}

# Echo the path of pak $1 in RTCW_DATA (case-insensitive), empty if absent.
vos_pak_path() {
  find "$RTCW_DATA" -maxdepth 1 -iname "$1.pk3" -print -quit 2>/dev/null
}
