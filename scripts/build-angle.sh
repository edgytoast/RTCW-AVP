#!/usr/bin/env bash
# Build ANGLE (libEGL + libGLESv2, Metal backend only) for visionOS device and
# simulator as static libs. Adapted from upstream/halflife-visionos/VisionPort/
# build_angle_visionos.sh (GPLv3). Its chromium/build patch is rebased for our
# pinned ANGLE revision in src/patches/angle/.
# Output: build/angle/lib/{libANGLE.a,libANGLE-sim.a}, build/angle/include/.
# Needs ~12 GiB for the gclient sync. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/src/patches/angle/0001-chromium-build-visionos.patch"
ANGLE_REV=c3e419e66849ab258b11196511c393b49c3514d8  # 2026-09-30; bump deliberately and rebase the patch
WORK="$ROOT/build/angle-build"
OUT="$ROOT/build/angle"

mkdir -p "$WORK" "$OUT/lib"
[[ -d "$ROOT/build/depot_tools" ]] || git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$ROOT/build/depot_tools"
export PATH="$ROOT/build/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
[[ -f "$ROOT/build/depot_tools/python3_bin_reldir.txt" ]] || "$ROOT/build/depot_tools/ensure_bootstrap"

if [[ ! -d "$WORK/angle" ]]; then
    git clone https://chromium.googlesource.com/angle/angle "$WORK/angle"
    cd "$WORK/angle"
    git checkout -q "$ANGLE_REV"
    cp scripts/bootstrap.py .
    python3 bootstrap.py
    gclient sync --no-history --shallow
fi
# Apply the chromium/build patch once (it also adds the visionOS rust triples).
if ! grep -q "'xros'" "$WORK/angle/build/config/apple/sdk_info.py"; then
    git -C "$WORK/angle/build" apply "$PATCH"
fi

cd "$WORK/angle"
echo "angle $(git remote get-url origin) $(git rev-parse HEAD)" > "$OUT/PIN"

ARGS='target_os="ios" target_platform="xros" target_cpu="arm64" ios_deployment_target="2.0" is_debug=false is_component_build=false ios_enable_code_signing=false angle_enable_metal=true angle_enable_vulkan=false angle_enable_gl=false angle_enable_swiftshader=false angle_enable_null=false angle_enable_wgpu=false symbol_level=1 use_custom_libcxx=false treat_warnings_as_errors=false'

for variant in device simulator; do
    dir="out/xros-$variant"
    gn gen "$dir" --args="$ARGS target_environment=\"$variant\""
    autoninja -C "$dir" libEGL_static libGLESv2_static
    name=libANGLE.a; [[ $variant == simulator ]] && name=libANGLE-sim.a
    list=$(mktemp)
    (cd "$dir" && find "$PWD/obj" -name '*.o' -not -path '*/dawn/*' -not -path '*/volk/*' \
        -not -path '*/googletest/*' -not -path '*/gmock/*' -not -path '*/gtest/*' \
        -not -path '*/samples/*' -not -path '*/tests/*' -not -path '*/buildtools/*') > "$list"
    libtool -static -filelist "$list" -o "$OUT/lib/$name" 2>&1 | grep -v 'warning same member' || true
    rm -f "$list"
    ls -lh "$OUT/lib/$name"
done

rm -rf "$OUT/include" && cp -R "$WORK/angle/include" "$OUT/include"
echo "ANGLE done -> $OUT"
