#!/usr/bin/env bash
# Archive & export SigmaDevelop with your Apple Developer account.
#
#   iOS    -> .xcarchive -> .ipa
#   macOS  -> .xcarchive -> .app   (native, not Catalyst)
#
# and, with --upload, ships either straight to TestFlight / App Store Connect.
#
# Signing is automatic (managed by Xcode) using the team baked into the project
# (override with TEAM=...). A full Xcode is required — Command Line Tools cannot
# archive.
#
# Examples
#   ./export_app.sh                         # ad-hoc .ipa + .app into build/export
#   ./export_app.sh --ios                   # just the .ipa
#   ./export_app.sh --mac                   # just the .app
#   ./export_app.sh --method developer-id   # notarizable standalone .app / .ipa
#   ./export_app.sh --upload                # build for the store + push to TestFlight
#
# TestFlight upload needs an App Store Connect API key (App Store Connect ->
# Users and Access -> Integrations -> keys), supplied via the environment:
#   ASC_KEY_ID=XXXXXXXXXX \
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
#   ASC_KEY_PATH=~/keys/AuthKey_XXXXXXXXXX.p8 \
#   ./export_app.sh --upload
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project="$here/app/SigmaDevelop.xcodeproj"
scheme="SigmaDevelop"
team="${TEAM:-47FFZHHXF3}"

# ---- args -------------------------------------------------------------------
do_ios=1
do_mac=1
picked=0
method="release-testing"   # iOS: release-testing (ad-hoc) | app-store-connect | debugging
                           # macOS equivalents: mac-application | app-store-connect |
                           # debugging | developer-id  (release-testing auto-maps to mac-application)
upload=0
outdir="$here/build/export"
build_libs=0

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ios)       do_ios=1; do_mac=0; picked=1 ;;
        --mac|--macos) do_mac=1; do_ios=0; picked=1 ;;
        --both)      do_ios=1; do_mac=1; picked=1 ;;
        --method)    method="$2"; shift ;;
        --method=*)  method="${1#*=}" ;;
        --upload)    upload=1 ;;
        --output)    outdir="$2"; shift ;;
        --output=*)  outdir="${1#*=}" ;;
        --build-libs) build_libs=1 ;;
        -h|--help)   usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done
[ "$picked" -eq 1 ] || { do_ios=1; do_mac=1; }

if [ "$upload" -eq 1 ]; then
    method="app-store-connect"
    : "${ASC_KEY_ID:?--upload needs ASC_KEY_ID (App Store Connect API key id)}"
    : "${ASC_ISSUER_ID:?--upload needs ASC_ISSUER_ID (API key issuer id)}"
    : "${ASC_KEY_PATH:?--upload needs ASC_KEY_PATH (path to the AuthKey_*.p8)}"
    [ -f "$ASC_KEY_PATH" ] || { echo "error: ASC_KEY_PATH not found: $ASC_KEY_PATH" >&2; exit 1; }
fi

# ---- resolve a full Xcode (not the Command Line Tools) ----------------------
resolve_xcode() {
    local cand
    if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
        echo "$DEVELOPER_DIR"; return 0
    fi
    cand="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$cand" ] && [ -x "$cand/usr/bin/xcodebuild" ]; then echo "$cand"; return 0; fi
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
dev="$(resolve_xcode)" || { echo "error: full Xcode is required to archive." >&2; exit 1; }
export DEVELOPER_DIR="$dev"

# ---- prerequisites: rust xcframework (+ macOS slice) & metallibs ------------
xcframework="$here/raw/libsd14raw.xcframework"
have_macos_slice() {
    [ -d "$xcframework" ] && ls "$xcframework" | grep -qi '^macos'
}
if [ "$build_libs" -eq 1 ] \
   || [ ! -d "$xcframework" ] \
   || { [ "$do_mac" -eq 1 ] && ! have_macos_slice; }; then
    echo "==> building rust libs / xcframework..." >&2
    "$here/build_ios_libs.sh"
    echo "==> building metal libraries..." >&2
    "$here/develop/build_metallib.sh"
fi

mkdir -p "$outdir"

# ---- write a temp export options plist --------------------------------------
export_plist() {  # $1 = method, echoes a temp plist path
    local m="$1" dest="export" f
    [ "$upload" -eq 1 ] && dest="upload"
    f="$(mktemp -t sigma-export).plist"
    cat > "$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>            <string>$m</string>
    <key>destination</key>       <string>$dest</string>
    <key>signingStyle</key>      <string>automatic</string>
    <key>teamID</key>            <string>$team</string>
    <key>stripSwiftSymbols</key> <true/>
</dict>
</plist>
PLIST
    echo "$f"
}

auth_args=()
if [ "$upload" -eq 1 ]; then
    auth_args=(-authenticationKeyPath "$ASC_KEY_PATH"
               -authenticationKeyID "$ASC_KEY_ID"
               -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# iOS and macOS accept different `method` values; translate so one --method flag
# works for both. iOS ad-hoc == macOS "mac-application" (a signed standalone .app).
resolve_method() {  # $1 = label -> platform-valid method
    local m="$method"
    if [ "$1" = mac ]; then
        case "$m" in
            release-testing|ad-hoc|adhoc) m="mac-application" ;;
        esac
    else
        case "$m" in
            mac-application|developer-id) m="release-testing" ;;
        esac
    fi
    echo "$m"
}

# ---- archive + export one destination ---------------------------------------
run() {  # $1 = label, $2 = xcodebuild destination
    local label="$1" destination="$2"
    local archive="$outdir/$label/SigmaDevelop.xcarchive"
    local exp="$outdir/$label"
    local m; m="$(resolve_method "$label")"
    local plist; plist="$(export_plist "$m")"

    echo "==> archiving $label ($destination)..." >&2
    xcodebuild archive \
        -project "$project" \
        -scheme "$scheme" \
        -configuration Release \
        -destination "$destination" \
        -archivePath "$archive" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$team"

    echo "==> exporting $label ($m)..." >&2
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportOptionsPlist "$plist" \
        -exportPath "$exp" \
        -allowProvisioningUpdates \
        ${auth_args[@]+"${auth_args[@]}"}

    rm -f "$plist"
    echo "    -> $exp" >&2
}

[ "$do_ios" -eq 1 ] && run ios "generic/platform=iOS"
[ "$do_mac" -eq 1 ] && run mac "generic/platform=macOS"

echo "done. artifacts under: $outdir" >&2
find "$outdir" -maxdepth 3 \( -name '*.ipa' -o -name '*.app' -o -name '*.pkg' \) -print 2>/dev/null || true
