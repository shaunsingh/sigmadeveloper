#!/usr/bin/env bash
# Compile the SigmaFoveon Metal kernels into per-platform metallibs bundled as
# package resources.
#
#   Metal/LensCorrection.ci.metal  Core Image colour kernels — need the metal
#     compiler's -fcikernel and the metallib linker's -cikernel flags.
#   Metal/FilmSim.metal            plain compute kernels for the spectral film
#     simulation (run inside a CIImageProcessorKernel) — a normal metallib.
#
# SwiftPM can't pass those flags, so we precompile here. The outputs are committed
# (the iOS app build just consumes them); re-run after editing a kernel. A full
# Xcode (not Command Line Tools) is required for `metal`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/Metal/LensCorrection.ci.metal"
out="$here/Sources/SigmaFoveon/Assets"
mkdir -p "$out"

# Resolve a full Xcode (CommandLineTools has no `metal`); mirrors build_ios_libs.sh.
resolve_xcode() {
    local cand
    if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
        echo "$DEVELOPER_DIR"; return 0
    fi
    cand="$(xcode-select -p 2>/dev/null || true)"
    # `metal` lives in the toolchain (invoked via xcrun), never at usr/bin/metal;
    # gate on xcodebuild like the DEVELOPER_DIR and /Applications branches do.
    if [ -n "$cand" ] && [ -x "$cand/usr/bin/xcodebuild" ]; then echo "$cand"; return 0; fi
    for cand in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -x "$cand/Contents/Developer/usr/bin/xcodebuild" ]; then
            echo "$cand/Contents/Developer"; return 0
        fi
    done
    return 1
}
dev="$(resolve_xcode)" || { echo "error: full Xcode required for the metal toolchain" >&2; exit 1; }

# sdk -> output suffix
build() {
    local sdk="$1" name="$2"
    local tmp air; tmp="$(mktemp -t lenscorr)"; air="$tmp.air"
    echo "compiling $name CI kernel ($sdk)..." >&2
    DEVELOPER_DIR="$dev" xcrun -sdk "$sdk" metal -fcikernel -c "$src" -o "$air"
    DEVELOPER_DIR="$dev" xcrun -sdk "$sdk" metallib -cikernel "$air" -o "$out/LensCorrection_$name.ci.metallib"
    rm -f "$tmp" "$air"
}

build macosx          macos
build iphoneos        ios
build iphonesimulator iossim

echo "built: $out/LensCorrection_{macos,ios,iossim}.ci.metallib" >&2

# Plain compute metallibs (no -fcikernel/-cikernel)
build_compute() {
    local sdk="$1" name="$2" base="$3" csrc="$4"
    local tmp air; tmp="$(mktemp -t "$base")"; air="$tmp.air"
    echo "compiling $base compute kernel ($sdk)..." >&2
    DEVELOPER_DIR="$dev" xcrun -sdk "$sdk" metal -c "$csrc" -o "$air"
    DEVELOPER_DIR="$dev" xcrun -sdk "$sdk" metallib "$air" -o "$out/${base}_$name.metallib"
    rm -f "$tmp" "$air"
}

for base in FilmSim Denoise; do
    csrc="$here/Metal/$base.metal"
    build_compute macosx          macos  "$base" "$csrc"
    build_compute iphoneos        ios    "$base" "$csrc"
    build_compute iphonesimulator iossim "$base" "$csrc"
    echo "built: $out/${base}_{macos,ios,iossim}.metallib" >&2
done
