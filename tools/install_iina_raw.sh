#!/usr/bin/env bash
# Install IINA RAW: copy the built app to /Applications/IINA RAW.app, register it with
# LaunchServices, and make it the current user's default viewer for .R3D and .NEV clips.
#
# Usage: tools/install_iina_raw.sh [path/to/built/"IINA RAW.app"] [extra-clip-file...]
#
# The app path defaults to the Release build that build/build-iina-raw.sh makes
# (build/work/iina-derived/Build/Products/Release/IINA RAW.app). Every extra clip
# file is asked for its content type (mdls). A content type that another app already declared
# for the clip (for example from a grading tool) is added to the list of types that IINA RAW
# becomes the default viewer for, but only when the filename extensions of that type are
# exactly r3d or nev (case-insensitive). The file named by the environment variable CLIP
# (when set) is checked too.
#
# The copy goes to a temporary path in /Applications first. The old app is replaced only after
# that copy succeeded. The script refuses to run when the source is the installed app.
#
# The Quick Look extensions inside the app (thumbnail, preview) are registered with pluginkit and enabled.
#
# Only IINA RAW is touched. /Applications/IINA.app and the com.colliderli.iina preferences are
# never read for writing. User level only: no sudo, no system settings.

set -euo pipefail

DEST="/Applications/IINA RAW.app"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_DEFAULT="$REPO/build/work/iina-derived/Build/Products/Release/IINA RAW.app"
BUNDLE_ID="com.alperkaganavci.iina-raw"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

SRC="${1:-$BUILT_DEFAULT}"
if [ $# -gt 0 ]; then shift; fi
CLIPS=("$@")
if [ -n "${CLIP:-}" ]; then
    CLIPS+=("$CLIP")
fi

die() { echo "install_iina_raw: $*" >&2; exit 1; }

[ -d "$SRC" ] || die "built app not found: $SRC"
# Refuse to copy the installed app onto itself (resolve links and ".." first).
src_real="$(cd "$SRC" && pwd -P)"
dest_real="$DEST"
[ -d "$DEST" ] && dest_real="$(cd "$DEST" && pwd -P)"
if [ "$src_real" = "$dest_real" ] || [ "$src_real" = "/Applications/IINA RAW.app" ]; then
    die "source $SRC is the installed app ($DEST); give the path of a built app"
fi
src_id="$(defaults read "$SRC/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
[ "$src_id" = "$BUNDLE_ID" ] || die "$SRC has bundle id '$src_id', expected $BUNDLE_ID"

# Replace an older IINA RAW only. Never touch IINA.app.
if [ -e "$DEST" ]; then
    old_id="$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    [ "$old_id" = "$BUNDLE_ID" ] || die "$DEST exists but is not IINA RAW (bundle id '$old_id'); not replacing it"
    if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1; then
        die "IINA RAW is running; quit it first (osascript -e 'quit app \"IINA RAW\"')"
    fi
fi
# A thumbnail extension process of the old build may still run; end it so the new code loads.
pkill -f "$DEST/Contents/PlugIns/Raw" >/dev/null 2>&1 || true
# Copy to a temporary path first; replace the old app only when the copy worked.
TMP_DEST="/Applications/.IINA RAW.app.new"
rm -rf "$TMP_DEST"
if ! ditto "$SRC" "$TMP_DEST"; then
    rm -rf "$TMP_DEST"
    die "copy to $TMP_DEST failed; the installed app is unchanged"
fi
tmp_id="$(defaults read "$TMP_DEST/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
if [ "$tmp_id" != "$BUNDLE_ID" ]; then
    rm -rf "$TMP_DEST"
    die "the copy has bundle id '$tmp_id'; the installed app is unchanged"
fi
rm -rf "$DEST"
mv "$TMP_DEST" "$DEST"
echo "installed $DEST"

"$LSREGISTER" -f "$DEST"
# The build folder copy has the same bundle id. Xcode may have registered it, and then
# LaunchServices could open clips with that copy instead of the installed one.
if [ "$SRC" != "$DEST" ]; then
    "$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
    if [ -d "$(dirname "$SRC")/OpenInIINA.appex" ]; then "$LSREGISTER" -u "$(dirname "$SRC")/OpenInIINA.appex" >/dev/null 2>&1 || true; fi
fi
echo "registered with LaunchServices"

# Quick Look extensions inside the app: RawThumbnail.appex (Finder thumbnails) and
# RawPreview.appex (space bar preview). Each is registered with pluginkit and enabled for this
# user; then Quick Look is reset so Finder asks for new thumbnails and previews. A copy of an
# extension in the build folder (same id) is removed from pluginkit first.
QL_EXTENSIONS=("RawThumbnail.appex:com.alperkaganavci.iina-raw.thumbnail" "RawPreview.appex:com.alperkaganavci.iina-raw.preview")
for entry in "${QL_EXTENSIONS[@]}"; do
    ql_name="${entry%%:*}"
    ql_id="${entry#*:}"
    # A process of the old extension may still run; end it so the new code loads.
    pkill -f "$DEST/Contents/PlugIns/$ql_name" >/dev/null 2>&1 || true
done
for entry in "${QL_EXTENSIONS[@]}"; do
    ql_name="${entry%%:*}"
    ql_id="${entry#*:}"
    appex="$DEST/Contents/PlugIns/$ql_name"
    if [ ! -d "$appex" ]; then
        echo "note: no $ql_name in $DEST (older build)"
        continue
    fi
    # pluginkit applies a removal a moment later and by id, so wait before adding the new path.
    if [ "$SRC" != "$DEST" ] && [ -d "$SRC/Contents/PlugIns/$ql_name" ]; then
        pluginkit -r "$SRC/Contents/PlugIns/$ql_name" >/dev/null 2>&1 || true
        sleep 2
    fi
    ql_ok=0
    for _attempt in 1 2 3 4 5; do
        pluginkit -a "$appex" || true
        sleep 1
        pluginkit -e use -i "$ql_id" || true
        sleep 1
        if pluginkit -m -v -i "$ql_id" 2>&1 | grep -F "$appex" | grep -q '^ *+'; then ql_ok=1; break; fi
    done
    if [ "$ql_ok" -eq 1 ]; then
        echo "Quick Look extension enabled: $(pluginkit -m -i "$ql_id" 2>&1 | head -n 1)"
    else
        echo "warning: the Quick Look extension $ql_id is not enabled (pluginkit -m -v -i $ql_id)" >&2
    fi
done
qlmanage -r >/dev/null 2>&1 || echo "warning: qlmanage -r failed" >&2
qlmanage -r cache >/dev/null 2>&1 || echo "warning: qlmanage -r cache failed" >&2

# Content types: ours, plus the type that macOS reports for each clip when some app declared
# it and every filename extension of that type is r3d or nev (case-insensitive).
UTIS=(com.alperkaganavci.r3d com.alperkaganavci.nev)
for clip in ${CLIPS[@]+"${CLIPS[@]}"}; do
    [ -e "$clip" ] || continue
    uti="$(mdls -name kMDItemContentType -raw "$clip" 2>/dev/null || true)"
    case "$uti" in
        ""|"(null)"|dyn.*) continue ;;
    esac
    if ! swift - "$uti" <<'SWIFTEOF2' >/dev/null 2>&1
import Foundation
import UniformTypeIdentifiers

// Exit 0 only when the type has filename extension tags and all of them are r3d or nev.
let uti = CommandLine.arguments[1]
let tags = UTType(uti)?.tags[.filenameExtension] ?? []
let ok = !tags.isEmpty && tags.allSatisfy { ["r3d", "nev"].contains($0.lowercased()) }
exit(ok ? 0 : 1)
SWIFTEOF2
    then
        echo "skipping content type $uti of $clip: its filename extensions are not exactly r3d or nev"
        continue
    fi
    already=0
    for u in "${UTIS[@]}"; do [ "$u" = "$uti" ] && already=1; done
    [ "$already" -eq 0 ] && UTIS+=("$uti")
done

swift - "$BUNDLE_ID" "${UTIS[@]}" <<'SWIFTEOF'
import CoreServices
import Foundation

let args = CommandLine.arguments
let bundleID = args[1]
var failed = false
for uti in args.dropFirst(2) {
    // LaunchServices applies a change a moment later, so read it back a few times.
    var now: String? = nil
    var status: Int32 = 0
    for attempt in 0..<10 {
        if attempt % 3 == 0 {
            status = LSSetDefaultRoleHandlerForContentType(uti as CFString, LSRolesMask.all, bundleID as CFString)
        }
        Thread.sleep(forTimeInterval: 0.5)
        now = LSCopyDefaultRoleHandlerForContentType(uti as CFString, LSRolesMask.viewer)?.takeRetainedValue() as String?
        if status == 0 && now?.lowercased() == bundleID.lowercased() { break }
    }
    print("default viewer for \(uti): \(now ?? "none") (status \(status))")
    if status != 0 || now?.lowercased() != bundleID.lowercased() { failed = true }
}
exit(failed ? 1 : 0)
SWIFTEOF
