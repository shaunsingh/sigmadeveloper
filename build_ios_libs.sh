#!/usr/bin/env bash
# Cross-compile the Rust core (libsd14raw.a) for iOS device + simulator +
# native macOS and package the slices as an .xcframework the app links against.
#
# The static library is pure `std` (no system frameworks, no linker step), so a
# `rustup target add` is all the toolchain it needs - no full iOS SDK dance.
# Universal fat archives cover Apple-silicon and Intel Macs for sim + macOS.
#
# Only the final `xcodebuild -create-xcframework` needs full Xcode (not the
# Command Line Tools), so the script locates an Xcode itself - no global
# `xcode-select` switch required.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/raw/Cargo.toml"
out="$here/raw/libsd14raw.xcframework"

device="aarch64-apple-ios"
sim_targets=("aarch64-apple-ios-sim" "x86_64-apple-ios")
macos_targets=("aarch64-apple-darwin" "x86_64-apple-darwin")

# Resolve a full Xcode developer dir (not the Command Line Tools instance).
resolve_xcode() {
    local cand
    if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
        echo "$DEVELOPER_DIR"; return 0
    fi
    cand="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$cand" ] && [ -x "$cand/usr/bin/xcodebuild" ]; then
        echo "$cand"; return 0
    fi
    cand="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
    if [ -n "$cand" ] && [ -x "$cand/Contents/Developer/usr/bin/xcodebuild" ]; then
        echo "$cand/Contents/Developer"; return 0
    fi
    for cand in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -x "$cand/Contents/Developer/usr/bin/xcodebuild" ]; then
            echo "$cand/Contents/Developer"; return 0
        fi
    done
    return 1
}

if ! dev="$(resolve_xcode)"; then
    echo "error: full Xcode is required to package the xcframework (the active" >&2
    echo "       toolchain is Command Line Tools). Install Xcode, then either run" >&2
    echo "         sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "       or re-run this script after installing Xcode.app." >&2
    exit 1
fi

echo "ensuring rust Apple targets..." >&2
rustup target add "$device" "${sim_targets[@]}" "${macos_targets[@]}" >/dev/null

build() {
    echo "building libsd14raw.a for ${1}..." >&2
    cargo build --release --lib --manifest-path "$manifest" --target "$1"
}
lib() { echo "$here/raw/target/$1/release/libsd14raw.a"; }

build "$device"
for target in "${sim_targets[@]}"; do build "$target"; done
for target in "${macos_targets[@]}"; do build "$target"; done

# Fuse the two simulator architectures into one fat archive.
simdir="$here/raw/target/ios-sim-universal/release"
mkdir -p "$simdir"
echo "fusing universal simulator slice..." >&2
lipo -create "$(lib "${sim_targets[0]}")" "$(lib "${sim_targets[1]}")" -output "$simdir/libsd14raw.a"

# Fuse the two macOS architectures into one fat archive
macdir="$here/raw/target/macos-universal/release"
mkdir -p "$macdir"
echo "fusing universal macOS slice..." >&2
lipo -create "$(lib "${macos_targets[0]}")" "$(lib "${macos_targets[1]}")" -output "$macdir/libsd14raw.a"

echo "packaging ${out} (using Xcode at $dev)..." >&2
rm -rf "$out"
# No -headers: the Swift package's CFoveonRaw target already supplies the
# `foveon_*` declarations; the xcframework only needs to resolve the symbols.
DEVELOPER_DIR="$dev" xcodebuild -create-xcframework \
    -library "$(lib "$device")" \
    -library "$simdir/libsd14raw.a" \
    -library "$macdir/libsd14raw.a" \
    -output "$out"

echo "built: $out" >&2
