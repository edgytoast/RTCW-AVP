#!/usr/bin/env bash
# Fetch upstream sources at the exact commits pinned in upstream/PINS, so every build uses
# the same code the patches were made against.
#   scripts/fetch-upstream.sh        only what the build needs (iortcw)
#   scripts/fetch-upstream.sh all    also the reference repos used during development
# Idempotent: an existing checkout at the pinned commit is left alone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$ROOT/upstream/PINS"
MODE="${1:-build}"

fetch_pinned() { # name url sha
  local dir="$ROOT/upstream/$1"
  if [[ -d "$dir/.git" ]] && [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$3" ]]; then
    echo "ok   $1 @ ${3:0:12}"; return
  fi
  echo "get  $1 @ ${3:0:12}"
  rm -rf "$dir" && mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$2"
  git -C "$dir" fetch -q --depth 1 origin "$3"
  git -C "$dir" checkout -q FETCH_HEAD
}

[[ -f "$PINS" ]] || { echo "missing $PINS"; exit 1; }
while read -r name url sha; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ "$MODE" == all || "$name" == iortcw ]] || continue
  fetch_pinned "$name" "$url" "$sha"
done < "$PINS"
