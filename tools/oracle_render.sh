#!/bin/bash
# Make the oracle view references: bluecompress "develop --rec709" output,
# frames 0, 100 and 818, as 1920x1080 PNG files.
# Usage: tools/oracle_render.sh [--exact] <clip.R3D> <out_dir>
#
# --exact: no HEVC step. BLUECOMPRESS_FFMPEG points to tools/oracle_ffmpeg_wrapper.sh,
# which saves the oracle's exact P010 frames (frames 0, 100, 818 only, 1920x1080,
# p010le, BT.709 limited range, 4:2:0) instead of encoding. The script converts them
# with: ffmpeg -f rawvideo -pix_fmt p010le -s 1920x1080 -i <frame>.p010
#   -vf scale=in_color_matrix=bt709:in_range=tv:out_range=full  (rgb48 PNG).
# Use out_dir testdata/ref/view-p010 for this mode. The default mode (HEVC) is unchanged.
# The oracle is used only as a black box (build the CLI, run it).
#
# Reproducibility: testdata/MANIFEST.sha256 records the hashes of ONE run.
# The oracle encodes HEVC (hevc_videotoolbox), which may not be deterministic,
# so a later run can give different bytes. The script compares the new hashes
# with the manifest and prints MATCH or DIFFERS per file (informational only).
#
# Colour conversion is pinned. The oracle's .mov is tagged yuv420p10le,
# color_space/transfer/primaries bt709, color_range tv (limited). So the
# swscale step uses in_color_matrix=bt709 and in_range=tv, out_range=full.
# The script prints the tags on every run; if they change, review the flags.
set -euo pipefail

EXACT=0
if [ "${1:-}" = "--exact" ]; then EXACT=1; shift; fi
CLIP=${1:?usage: oracle_render.sh <clip> <out_dir>}
OUT=${2:?usage: oracle_render.sh <clip> <out_dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/testdata/oracle-bin/bin/bluecompress
TMP=$ROOT/testdata/tmp
FRAMES="0 100 818"

if [ ! -x "$BIN" ]; then
    memory_pressure | tail -1
    sysctl vm.swapusage
    cargo install --git https://github.com/redn3/blue-compressor --rev 4d35f31 \
        --root "$ROOT/testdata/oracle-bin" --locked bluecompress-cli
fi

mkdir -p "$OUT" "$TMP"
MOV=$TMP/oracle_view.mov
RAWDIR=$TMP/exact
trap 'rm -f "$MOV"; rm -rf "$RAWDIR"' EXIT
rm -f "$MOV"
rm -rf "$RAWDIR"
memory_pressure | tail -1
sysctl vm.swapusage
if [ "$EXACT" = 1 ]; then
    mkdir -p "$RAWDIR"
    df -h "$TMP" | tail -1
    ORACLE_FRAMES_DIR=$RAWDIR ORACLE_FRAMES="$FRAMES" ORACLE_FRAME_SIZE=1920x1080 \
        BLUECOMPRESS_FFMPEG="$ROOT/tools/oracle_ffmpeg_wrapper.sh" \
        "$BIN" develop "$CLIP" --rec709 --width 1920 -o "$MOV"
else
    "$BIN" develop "$CLIP" --rec709 --width 1920 -o "$MOV"
    ffprobe -v error -select_streams v:0 -show_entries \
        stream=pix_fmt,color_space,color_range,color_transfer,color_primaries \
        -of default=nw=1 "$MOV"
fi

rc=0
for n in $FRAMES; do
    f=$(printf '%s/f%04d.png' "$OUT" "$n")
    if [ "$EXACT" = 1 ]; then
        ffmpeg -v error -y -f rawvideo -pix_fmt p010le -s 1920x1080 \
            -i "$(printf '%s/p%04d.p010' "$RAWDIR" "$n")" \
            -vf "scale=in_color_matrix=bt709:in_range=tv:out_range=full" \
            -frames:v 1 -fps_mode passthrough "$f"
    else
        ffmpeg -v error -y -i "$MOV" \
            -vf "select=eq(n\,$n),scale=in_color_matrix=bt709:in_range=tv:out_range=full" \
            -frames:v 1 -fps_mode passthrough "$f"
    fi
    size=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0 "$f")
    echo "$f: $size"
    if [ "$size" != "1920,1080" ]; then
        echo "error: $f is not 1920x1080" >&2
        exit 1
    fi
    new=$(shasum -a 256 "$f" | cut -d' ' -f1)
    old=$(grep -F "ref/$(basename "$OUT")/$(basename "$f")" "$ROOT/testdata/MANIFEST.sha256" | cut -d' ' -f1 || true)
    if [ "$new" = "$old" ]; then echo "  MATCH $new"; else echo "  DIFFERS new=$new manifest=${old:-none}"; fi
done
