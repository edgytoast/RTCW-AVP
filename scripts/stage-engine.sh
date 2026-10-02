#!/usr/bin/env bash
# Stage iortcw SP sources into build/iortcw/code and apply our patches.
# upstream/ stays pristine; everything we change lives in src/patches/iortcw/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/upstream/iortcw/SP/code"
DST="$ROOT/build/iortcw/code"
PATCHES="$ROOT/src/patches/iortcw"
STAMP="$ROOT/build/iortcw/.stamp"

# Restage when upstream pin or any patch changed.
want="$(cat "$ROOT/upstream/PINS" 2>/dev/null; cat "$PATCHES"/*.patch 2>/dev/null)"
want="$(printf '%s' "$want" | shasum | cut -d' ' -f1)"
[[ -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]] && { echo "stage: up to date"; exit 0; }

rm -rf "$DST" && mkdir -p "$DST"
for d in qcommon client server botlib splines renderer cgame game ui sys zlib-1.2.11 jpeg-8c; do
    rsync -a "$SRC/$d" "$DST/"
done

# ui_shared.h includes ../../main/ui/menudef.h
mkdir -p "$ROOT/build/iortcw/main" && rsync -a "$SRC/../main/ui" "$ROOT/build/iortcw/main/"

shopt -s nullglob
for p in "$PATCHES"/*.patch; do
    echo "stage: applying $(basename "$p")"
    patch -d "$DST" -p1 --forward --quiet < "$p"
done

echo "$want" > "$STAMP"
echo "stage: done -> $DST"
