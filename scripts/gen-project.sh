#!/usr/bin/env bash
# Generate the Xcode project from config.local (team, bundle id). `make project`.
set -euo pipefail
source "$(dirname "$0")/config.sh"
vos_config || { echo "Run 'make setup' first."; exit 1; }
python3 "$VOS_ROOT/scripts/gen-project.py"
XCODEGEN="$(vos_xcodegen)" || exit 1
"$XCODEGEN" -q -s "$VOS_ROOT/src/platform/visionos/project.yml" -p "$VOS_ROOT/src/platform/visionos"
