#!/usr/bin/env bash
# Build the installer DMG of IINA RAW from a built "IINA RAW.app".
#
#   build/make-dmg.sh --app <path to IINA RAW.app> --version <ver> --out <dir> [--scrub-prefix <path>]...
#
# What it does:
#   1. Copies the app to a temporary folder. The input app is never changed.
#   2. For every --scrub-prefix: replaces each occurrence of that byte string in every regular
#      file of the copy (Mach-O files and text files included) with a neutral path of the SAME
#      byte length (/opt/iina-raw-build, then a filler path segment). Build tools record such
#      prefixes (configure/meson --prefix, the fontconfig cache dir, the OpenSSL module dir,
#      source paths in debug info). On a user's Mac they do not exist, so a neutral path that
#      does not exist either behaves the same. Longer prefixes are replaced first.
#   3. Signs the copy ad hoc, inside-out: loose Mach-O files (dylibs, helper tools), then every
#      nested bundle (.appex, .xpc, .app), then the app. The signing identifier, entitlements
#      and flags of the old signatures are kept. Then: codesign --verify --deep --strict.
#   4. Fails when a file of the copy still holds "/Users/" or a scrubbed prefix. The scan runs
#      "strings" over all bytes of every file and a byte-level grep.
#   5. Builds IINA-RAW-<version>-arm64.dmg in the output folder: compressed (UDZO), volume name
#      "IINA RAW", the app plus an "Applications" link, a Finder window layout (icon positions,
#      window size, a background with an arrow, the app icon as volume icon). The layout is
#      written without Finder or AppleScript: dmgbuild (pinned, from PyPI, in a throw-away venv)
#      writes the .DS_Store file. The background is drawn by this script (Swift, CoreGraphics).
#      If no headless layout works, the script builds a plain DMG and says so.
#   6. Prints the DMG path and its SHA-256.
#
# Needs: macOS, Xcode command line tools (codesign, strings, hdiutil, swift, tiffutil), python3,
# and network access to PyPI for the layout step.

set -euo pipefail

NEUTRAL_STEM="/opt/iina-raw-build"
VOLUME_NAME="IINA RAW"
WINDOW_W=540
WINDOW_H=380
DMGBUILD_PINS=("dmgbuild==1.6.7" "ds-store==1.3.3" "mac-alias==2.2.3")

die() { echo "make-dmg: $*" >&2; exit 1; }
note() { echo "make-dmg: $*" >&2; }

usage() {
    cat >&2 <<'EOF'
usage: build/make-dmg.sh --app <path to IINA RAW.app> --version <ver> --out <dir> [--scrub-prefix <path>]...
EOF
    exit 2
}

APP=""
VERSION=""
OUT=""
PREFIXES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --app)          [ $# -ge 2 ] || usage; APP="$2"; shift 2 ;;
        --version)      [ $# -ge 2 ] || usage; VERSION="$2"; shift 2 ;;
        --out)          [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
        --scrub-prefix) [ $# -ge 2 ] || usage; PREFIXES+=("$2"); shift 2 ;;
        -h|--help)      usage ;;
        *)              echo "make-dmg: unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "$APP" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || usage

[ "$(uname -s)" = "Darwin" ] || die "this script needs macOS"
[ -d "$APP" ] || die "app not found: $APP"
case "$APP" in *.app|*.app/) ;; *) die "--app must be a .app bundle: $APP" ;; esac
case "$VERSION" in
    ""|*[!0-9A-Za-z._-]*) die "--version may only hold letters, digits, dot, dash and underscore: $VERSION" ;;
esac
if [ ${#PREFIXES[@]} -gt 0 ]; then
    for p in "${PREFIXES[@]}"; do
        case "$p" in /?*) ;; *) die "--scrub-prefix must be an absolute path: $p" ;; esac
    done
fi
for tool in codesign strings hdiutil python3 swift tiffutil ditto shasum grep find; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
[ -e "/Volumes/$VOLUME_NAME" ] && die "a volume named '$VOLUME_NAME' is mounted; eject it first"

APP_BASENAME="$(basename "${APP%/}")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
DMG="$OUT/IINA-RAW-$VERSION-arm64.dmg"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/iina-raw-dmg.XXXXXX")"
cleanup() {
    local rc=$?
    # A volume that this run mounted and left behind.
    if [ -e "/Volumes/$VOLUME_NAME" ]; then
        hdiutil detach "/Volumes/$VOLUME_NAME" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
    exit $rc
}
trap cleanup EXIT INT TERM HUP

STAGE="$WORK/stage"
COPY="$STAGE/$APP_BASENAME"
mkdir -p "$STAGE"

# ---------------------------------------------------------------------------------------------
# 1. Copy the app.
# ---------------------------------------------------------------------------------------------
note "copying $APP_BASENAME"
ditto --norsrc --noextattr "$APP" "$COPY"
[ -f "$COPY/Contents/Info.plist" ] || die "no Contents/Info.plist in $APP"
if find "$COPY" -name '*.framework' -type d | grep -q .; then
    die "the app holds a .framework bundle; this script signs dylibs, .appex, .xpc and .app bundles only"
fi

# ---------------------------------------------------------------------------------------------
# 2. Scrub build prefixes (same byte length).
# ---------------------------------------------------------------------------------------------
if [ ${#PREFIXES[@]} -gt 0 ]; then
    note "scrubbing ${#PREFIXES[@]} prefix(es)"
    python3 -I - "$COPY" "$NEUTRAL_STEM" "${PREFIXES[@]}" <<'PY'
import os, stat, sys

root, stem = sys.argv[1], sys.argv[2].encode()
prefixes = sorted({p.encode() for p in sys.argv[3:]}, key=lambda p: (-len(p), p))

rules = []
for p in prefixes:
    if len(p) < len(stem):
        sys.exit("make-dmg: scrub prefix %r is shorter than the neutral path %r (%d < %d bytes)"
                 % (p.decode(), stem.decode(), len(p), len(stem)))
    if p in stem or stem.startswith(p) or p.startswith(stem):
        sys.exit("make-dmg: scrub prefix %r overlaps the neutral path" % p.decode())
    pad = len(p) - len(stem)
    # Neutral stem, then a filler path segment: "/" plus underscores. Same length as the prefix.
    repl = stem + ((b"/" + b"_" * (pad - 1)) if pad > 0 else b"")
    assert len(repl) == len(p)
    rules.append((p, repl))

counts = {p: 0 for p, _ in rules}
files_changed = 0
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    for name in filenames:
        path = os.path.join(dirpath, name)
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            continue
        with open(path, "rb") as f:
            data = f.read()
        new = data
        for p, repl in rules:
            n = new.count(p)
            if n:
                counts[p] += n
                new = new.replace(p, repl)
        if new != data:
            assert len(new) == len(data)
            os.chmod(path, st.st_mode | stat.S_IWUSR)
            with open(path, "r+b") as f:
                f.write(new)
            os.chmod(path, st.st_mode)
            files_changed += 1
for p, repl in rules:
    print("make-dmg: scrubbed %d occurrence(s) of a %d-byte prefix" % (counts[p], len(p)), file=sys.stderr)
    if counts[p] == 0:
        print("make-dmg: warning: a scrub prefix was not found in the app", file=sys.stderr)
print("make-dmg: %d file(s) changed" % files_changed, file=sys.stderr)
PY
fi

# ---------------------------------------------------------------------------------------------
# 3. Sign ad hoc, inside-out.
# ---------------------------------------------------------------------------------------------
note "signing"
LOOSE_LIST="$WORK/macho.txt"
BUNDLE_LIST="$WORK/bundles.txt"
python3 -I - "$COPY" "$LOOSE_LIST" "$BUNDLE_LIST" <<'PY'
import os, plistlib, stat, sys

root, loose_out, bundle_out = sys.argv[1:4]
BUNDLE_EXT = (".appex", ".xpc", ".app")

def is_macho(path):
    with open(path, "rb") as f:
        head = f.read(8)
    if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        return True
    if head[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        # Fat file; a Java class file has the same magic and a version number above 40.
        return int.from_bytes(head[4:8], "big") < 40
    return False

bundles = [root]
for dirpath, dirnames, _ in os.walk(root, followlinks=False):
    for d in dirnames:
        full = os.path.join(dirpath, d)
        if d.endswith(BUNDLE_EXT) and not os.path.islink(full):
            bundles.append(full)

main_execs = set()
for b in bundles:
    plist = os.path.join(b, "Contents", "Info.plist")
    if not os.path.isfile(plist):
        sys.exit("make-dmg: bundle without Contents/Info.plist: %s" % b)
    with open(plist, "rb") as f:
        exe = plistlib.load(f).get("CFBundleExecutable")
    if not exe:
        sys.exit("make-dmg: bundle without CFBundleExecutable: %s" % b)
    main_execs.add(os.path.join(b, "Contents", "MacOS", exe))

loose = []
for dirpath, _, filenames in os.walk(root, followlinks=False):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path) or not stat.S_ISREG(os.lstat(path).st_mode):
            continue
        if path in main_execs:
            continue
        if is_macho(path):
            loose.append(path)

def depth(p):
    return p.count(os.sep)

loose.sort(key=lambda p: (-depth(p), p))
nested = sorted([b for b in bundles if b != root], key=lambda p: (-depth(p), p))
with open(loose_out, "w") as f:
    f.write("".join(p + "\n" for p in loose))
with open(bundle_out, "w") as f:
    f.write("".join(p + "\n" for p in nested + [root]))
PY

# shellcheck disable=SC2054  # the commas are part of one option value
SIGN_FLAGS=(--force --sign - --preserve-metadata=identifier,entitlements,flags,runtime)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    codesign "${SIGN_FLAGS[@]}" "$f" >/dev/null 2>"$WORK/codesign.err" || { cat "$WORK/codesign.err" >&2; die "codesign failed: ${f#"$COPY"/}"; }
done < "$LOOSE_LIST"
while IFS= read -r b; do
    [ -n "$b" ] || continue
    codesign "${SIGN_FLAGS[@]}" "$b" >/dev/null 2>"$WORK/codesign.err" || { cat "$WORK/codesign.err" >&2; die "codesign failed: ${b#"$STAGE"/}"; }
done < "$BUNDLE_LIST"
codesign --verify --deep --strict --verbose=1 "$COPY" 2>&1 | sed 's/^/make-dmg: /' >&2
codesign --verify --deep --strict "$COPY" || die "codesign --verify --deep --strict failed"
note "signature verified ($(wc -l < "$LOOSE_LIST" | tr -d ' ') loose Mach-O files, $(wc -l < "$BUNDLE_LIST" | tr -d ' ') bundles)"

# ---------------------------------------------------------------------------------------------
# 4. Scan for leaks.
# ---------------------------------------------------------------------------------------------
note "scanning for /Users/ and scrubbed prefixes"
PATTERNS=("/Users/")
if [ ${#PREFIXES[@]} -gt 0 ]; then PATTERNS+=("${PREFIXES[@]}"); fi
PAT_FILE="$WORK/patterns.txt"
printf '%s\n' "${PATTERNS[@]}" > "$PAT_FILE"
HITS="$WORK/hits.txt"
: > "$HITS"
while IFS= read -r -d '' f; do
    # "strings -a -" reads all bytes of a Mach-O file (plain "strings -a" skips the symbol tables).
    if strings -a - "$f" 2>/dev/null | LC_ALL=C grep -a -F -q -f "$PAT_FILE"; then
        echo "strings: ${f#"$STAGE"/}" >> "$HITS"
    elif LC_ALL=C grep -a -F -q -f "$PAT_FILE" "$f" 2>/dev/null; then
        echo "bytes:   ${f#"$STAGE"/}" >> "$HITS"
    fi
done < <(find "$COPY" -type f -print0)
if [ -s "$HITS" ]; then
    echo "make-dmg: the app copy still holds /Users/ or a scrubbed prefix in:" >&2
    sort -u "$HITS" >&2
    die "scan failed (pass a --scrub-prefix for each path above)"
fi
note "scan clean"

# ---------------------------------------------------------------------------------------------
# 5. Build the DMG.
# ---------------------------------------------------------------------------------------------
ICON_FILE=""
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$COPY/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$ICON_NAME" ]; then
    case "$ICON_NAME" in *.icns) ;; *) ICON_NAME="$ICON_NAME.icns" ;; esac
    [ -f "$COPY/Contents/Resources/$ICON_NAME" ] && ICON_FILE="$COPY/Contents/Resources/$ICON_NAME"
fi

rm -f "$DMG"
LAYOUT_OK=0
LAYOUT_LOG="$WORK/layout.log"
(
    # No "set -e" here: in a subshell that is part of an "&&" list it does not apply, so each
    # step ends with "|| exit 1".
    # Background with an arrow, drawn here: 1x and 2x, combined into one multi-resolution TIFF.
    cat > "$WORK/background.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// background.swift <width> <height> <out1x.png> <out2x.png> <arrow-x0> <arrow-x1> <arrow-y-from-top>
let a = CommandLine.arguments
let w = Int(a[1])!, h = Int(a[2])!
let x0 = CGFloat(Double(a[5])!), x1 = CGFloat(Double(a[6])!), yTop = CGFloat(Double(a[7])!)

func render(scale: Int, to path: String) {
    let pw = w * scale, ph = h * scale
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("no context")
    }
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // Soft vertical gradient, light grey to white.
    let colors = [CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(h)), options: [])
    // Arrow (CoreGraphics origin is bottom left).
    let y = CGFloat(h) - yTop
    let shaft: CGFloat = 8, head: CGFloat = 26
    ctx.setFillColor(CGColor(red: 0.56, green: 0.57, blue: 0.60, alpha: 1))
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: x0, y: y - shaft / 2))
    arrow.addLine(to: CGPoint(x: x1 - head, y: y - shaft / 2))
    arrow.addLine(to: CGPoint(x: x1 - head, y: y - head * 0.75))
    arrow.addLine(to: CGPoint(x: x1, y: y))
    arrow.addLine(to: CGPoint(x: x1 - head, y: y + head * 0.75))
    arrow.addLine(to: CGPoint(x: x1 - head, y: y + shaft / 2))
    arrow.addLine(to: CGPoint(x: x0, y: y + shaft / 2))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.fillPath()
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("no image")
    }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) { fatalError("write failed") }
}
render(scale: 1, to: a[3])
render(scale: 2, to: a[4])
SWIFT
    swift "$WORK/background.swift" "$WINDOW_W" "$WINDOW_H" "$WORK/bg1x.png" "$WORK/bg2x.png" 215 325 185 || exit 1
    tiffutil -cathidpicheck "$WORK/bg1x.png" "$WORK/bg2x.png" -out "$WORK/background.tiff" || exit 1

    # dmgbuild, pinned, in a throw-away virtual environment.
    python3 -m venv "$WORK/venv" || exit 1
    "$WORK/venv/bin/python" -m pip install --quiet --disable-pip-version-check --no-input "${DMGBUILD_PINS[@]}" || exit 1

    cat > "$WORK/settings.py" <<'SETTINGS'
# dmgbuild settings. Values come in through "-D name=value".
import os.path

app_path = defines["app"]
app_name = os.path.basename(app_path)
window_w = int(defines["window_w"])
window_h = int(defines["window_h"])

format = "UDZO"
compression_level = 9
files = [app_path]
symlinks = {"Applications": "/Applications"}
if defines.get("icon"):
    icon = defines["icon"]
background = defines["background"]

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
arrange_by = None
icon_size = 128
text_size = 13
# Window frame; the title bar takes about 22 points of the height.
window_rect = ((200, 120), (window_w, window_h + 22))
icon_locations = {
    app_name: (110, 185),
    "Applications": (430, 185),
}
SETTINGS
    DEFINES=(-D "app=$COPY" -D "background=$WORK/background.tiff" -D "window_w=$WINDOW_W" -D "window_h=$WINDOW_H")
    if [ -n "$ICON_FILE" ]; then DEFINES+=(-D "icon=$ICON_FILE"); fi
    "$WORK/venv/bin/python" -m dmgbuild -s "$WORK/settings.py" "${DEFINES[@]}" "$VOLUME_NAME" "$DMG" || exit 1
) >"$LAYOUT_LOG" 2>&1 && LAYOUT_OK=1 || LAYOUT_OK=0

if [ "$LAYOUT_OK" -ne 1 ]; then
    tail -n 25 "$LAYOUT_LOG" >&2 || true
    rm -f "$DMG"
    note "WARNING: the headless layout failed; building a PLAIN DMG (no icon positions, no background, no volume icon)"
    PLAIN="$WORK/plain"
    mkdir -p "$PLAIN"
    ditto "$COPY" "$PLAIN/$APP_BASENAME"
    ln -s /Applications "$PLAIN/Applications"
    hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$PLAIN" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
fi
[ -f "$DMG" ] || die "no DMG was written"
hdiutil verify -quiet "$DMG" || die "hdiutil verify failed for $DMG"

if [ "$LAYOUT_OK" -eq 1 ]; then
    note "layout: dmgbuild (headless .DS_Store)"
else
    note "layout: NONE (plain DMG)"
fi
echo "$DMG"
shasum -a 256 "$DMG"
