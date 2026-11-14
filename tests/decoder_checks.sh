#!/usr/bin/env bash
# End-to-end checks for the tico_raw FFmpeg decoder.
#
# Usage (from the project repo root):
#   tests/decoder_checks.sh <check>... | all
# A check name may be written as "probe" or "check_probe". Each check prints
# "PASS <name>" or "FAIL <name>: <reason>". Exit status is non-zero if any check failed.
#
# Environment:
#   FFMPEG_BUILD  out-of-tree FFmpeg build dir with the tico_raw decoder (required)
#   TICORAW       test program (default $FFMPEG_BUILD/libavcodec/tests/ticoraw)
#   CLIP          test clip (required): the path of a Nikon ZR .R3D clip, 6060x3410, 25 fps
#   REF           reference folder (default testdata/ref/A015_C004)
#   SAMPLES       frame sample folder (default testdata/samples)
#   VIEW_REF      oracle Rec.709 view references (default testdata/ref/view-p010: the
#                 oracle's exact P010 frames before HEVC, as rgb48 PNG)
#   TOOL_FFMPEG   a full FFmpeg build used only as a comparison tool, to read the reference
#                 PNGs and run the ssim filter (default: ffmpeg from PATH). The tico_raw
#                 builds are configured without the PNG decoder and the ssim filter.
#
# To add a check: write a function check_<name> that returns 0 on success, or prints a
# reason on stdout and returns non-zero. It then runs by name and as part of "all".

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_BUILD="${FFMPEG_BUILD:?set FFMPEG_BUILD to an out-of-tree FFmpeg build directory that has the tico_raw decoder}"
CLIP="${CLIP:?set CLIP to the path of a Nikon ZR .R3D test clip (6060x3410, 25 fps)}"
REF="${REF:-$ROOT/testdata/ref/A015_C004}"
SAMPLES="${SAMPLES:-$ROOT/testdata/samples}"
FRAMES="0000 0100 0818"

FFPROBE="$FFMPEG_BUILD/ffprobe"
FFMPEG="$FFMPEG_BUILD/ffmpeg"
TICORAW="${TICORAW:-$FFMPEG_BUILD/libavcodec/tests/ticoraw}"
COMPARE="$ROOT/tools/compare_stage.py"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/decoder_checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A hang must fail a check, not stall the suite. macOS has no timeout(1), so use perl's alarm:
# run_limited <frames> <command>...  allows FRAME_TIMEOUT seconds (default 10) per frame
# plus 30 s for start-up; the command is killed by SIGALRM (exit status 142) when it is late.
run_limited() {
    local frames="$1"
    shift
    perl -e 'alarm shift; exec @ARGV' "$(( ${FRAME_TIMEOUT:-10} * frames + 30 ))" "$@"
}

need_file() { # need_file <path>: print a reason and fail when the file is missing
    if [ ! -e "$1" ]; then
        echo "missing file: $1"
        return 1
    fi
}

need_iina_raw_src() { # IINA_RAW_SRC must name a checkout of alperkaganavci/iina (branch iina-raw)
    if [ -z "${IINA_RAW_SRC:-}" ]; then
        echo "set IINA_RAW_SRC to a checkout of alperkaganavci/iina (branch iina-raw) with deps/lib filled"
        return 1
    fi
}

# build_grabber_tool <main.swift> <output> [extra source...]: compile a command-line program with
# the frame grabber sources of the IINA RAW checkout (the environment variable IINA_RAW_SRC, the
# path of a checkout of alperkaganavci/iina on branch iina-raw, with its deps/lib filled) and its dylibs.
build_grabber_tool() {
    local main="$1" out="$2" src="${IINA_RAW_SRC:-}" gdir tmp
    shift 2
    need_iina_raw_src || return 1
    gdir="$src/RawFrameGrabber"
    need_file "$gdir/RawFrameGrabber.swift" || return 1
    need_file "$main" || return 1
    tmp="$WORK/gt-$(basename "$(dirname "$main")")"
    mkdir -p "$tmp"
    if ! clang -c -O2 -I"$src/deps/include" "$gdir/rawframe.c" -o "$tmp/rawframe.o" 2>"$tmp/clang.log"; then
        echo "clang failed: $(head -n 3 "$tmp/clang.log" | tr '\n' ' ')"
        return 1
    fi
    if ! swiftc -O -import-objc-header "$gdir/RawFrameGrabber-Bridging-Header.h" -I "$gdir" \
        "$gdir/RawFrameGrabber.swift" "$main" ${1+"$@"} "$tmp/rawframe.o" \
        -Xlinker -rpath -Xlinker "$src/deps/lib" \
        "$src/deps/lib/libavformat.63.dylib" "$src/deps/lib/libavcodec.63.dylib" \
        "$src/deps/lib/libavutil.61.dylib" "$src/deps/lib/libswscale.10.dylib" \
        -o "$out" 2>"$tmp/swiftc.log"; then
        echo "swiftc failed: $(grep -m3 'error' "$tmp/swiftc.log" | tr '\n' ' ')"
        return 1
    fi
}

# ffprobe reports tico_raw, 6060 x 3410, for the first video stream of the clip.
check_probe() {
    need_file "$FFPROBE" || return 1
    need_file "$CLIP" || return 1
    local out want="tico_raw,6060,3410"
    # stdout only: ffprobe logs decoder errors to stderr while it probes the stream
    out="$("$FFPROBE" -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height -of csv=p=0 "$CLIP" 2>"$WORK/probe.err")"
    if [ "$out" != "$want" ]; then
        echo "ffprobe printed '$out', expected '$want' (stderr: $(tail -n 1 "$WORK/probe.err"))"
        return 1
    fi
}

# The test program's meta stage matches the reference JSON on every test frame.
check_meta() {
    need_file "$TICORAW" || return 1
    need_file "$COMPARE" || return 1
    local f out
    for f in $FRAMES; do
        need_file "$SAMPLES/f$f.bin" || return 1
        need_file "$REF/f$f.json" || return 1
        out="$WORK/f$f.meta.json"
        if ! "$TICORAW" "$SAMPLES/f$f.bin" meta "$out" >"$WORK/log" 2>&1; then
            echo "frame $f: ticoraw meta failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        if ! python3 "$COMPARE" --json "$out" "$REF/f$f.json" --section meta >"$WORK/log" 2>&1; then
            echo "frame $f: meta differs from reference: $(head -n 2 "$WORK/log" | tr '\n' ' ')"
            return 1
        fi
    done
}

# The test program's header stage matches the reference JSON on every test frame, and also
# writes the same meta section as the meta stage.
check_header() {
    need_file "$TICORAW" || return 1
    need_file "$COMPARE" || return 1
    local f out section
    for f in $FRAMES; do
        need_file "$SAMPLES/f$f.bin" || return 1
        need_file "$REF/f$f.json" || return 1
        out="$WORK/f$f.header.json"
        if ! "$TICORAW" "$SAMPLES/f$f.bin" header "$out" >"$WORK/log" 2>&1; then
            echo "frame $f: ticoraw header failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        for section in header meta; do
            if ! python3 "$COMPARE" --json "$out" "$REF/f$f.json" --section "$section" \
                >"$WORK/log" 2>&1; then
                echo "frame $f: $section differs from reference: $(head -n 2 "$WORK/log" | tr '\n' ' ')"
                return 1
            fi
        done
    done
}

# Copy frame 0 to $2 with one picture-header (PIH) field changed. The script finds the PIH by
# walking the wrapper boxes and the codestream markers, so no file offset is hard-coded.
# Byte positions inside the PIH body are those of note section 3.2.
patch_pih() { # patch_pih <in.bin> <out.bin> <patch name>
    python3 -I - "$1" "$2" "$3" <<'PYEOF'
import struct, sys

src, dst, patch = sys.argv[1:4]
d = bytearray(open(src, "rb").read())
pos = 8  # child boxes of NRAW start at byte 8; NRTH is the last one
while True:
    size, tag = struct.unpack_from(">I4s", d, pos)
    pos += size
    if tag == b"NRTH":
        break
assert d[pos:pos + 2] == b"\xff\x10", "no SOC after the wrapper"
p = pos + 2
while True:
    marker, length = struct.unpack_from(">HH", d, p)
    if marker == 0xFF12:
        body = p + 4
        break
    p += 2 + length

if patch == "nlx":         # NLx 5 -> 4 (byte 22, high nibble)
    d[body + 22] = (d[body + 22] & 0x0F) | (4 << 4)
elif patch == "nc":        # Nc 4 -> 3 (byte 16)
    d[body + 16] = 3
elif patch == "slice_height":  # Hsl 16 -> 32 (bytes 14-15)
    struct.pack_into(">H", d, body + 14, 32)
elif patch == "cpih":      # Cpih 0 -> 3 (byte 21, low nibble)
    d[body + 21] = (d[body + 21] & 0xF0) | 3
elif patch == "odd_width":  # Wf 6060 -> 6061 (bytes 8-9)
    struct.pack_into(">H", d, body + 8, 6061)
else:
    sys.exit("unknown patch " + patch)
open(dst, "wb").write(d)
PYEOF
}

# Copy frame 0 to $2 with the version string "0100" of one wrapper box (NRFM, NRHM or NRTI,
# note section 2) changed to "0200". The box is found by its fourcc inside the wrapper.
patch_wrapper_version() { # patch_wrapper_version <in.bin> <out.bin> <box>
    python3 -I - "$1" "$2" "$3" <<'PYEOF'
import sys

src, dst, box = sys.argv[1:4]
d = bytearray(open(src, "rb").read())
at = d.find(box.encode(), 0, 1024)  # the wrapper is the first 1,024 bytes in the test clip
if at < 0 or d[at + 4:at + 8] != b"0100":
    sys.exit("no %s box with version 0100 in the wrapper" % box)
d[at + 4:at + 8] = b"0200"
open(dst, "wb").write(d)
PYEOF
}

# Frame 0 with one PIH field or one wrapper version string changed: the test program must exit
# non-zero, write no output, and name the field (or the box) and its value on stderr.
check_unsupported() {
    need_file "$TICORAW" || return 1
    need_file "$SAMPLES/f0000.bin" || return 1
    local c patch want
    for c in "nlx|NLx (nlx) 4" "nc|Nc (nc) 3" "slice_height|Hsl (slice_height) 32" \
             "cpih|Cpih (cpih) 3" "odd_width|Wf (width) 6061"; do
        patch="${c%%|*}"
        want="${c#*|}"
        if ! patch_pih "$SAMPLES/f0000.bin" "$WORK/patched.bin" "$patch" 2>"$WORK/log"; then
            echo "$patch: cannot make the patched copy: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        rm -f "$WORK/patched.json"
        if "$TICORAW" "$WORK/patched.bin" header "$WORK/patched.json" >"$WORK/log" 2>&1; then
            echo "$patch: ticoraw accepted the patched stream"
            return 1
        fi
        if [ -e "$WORK/patched.json" ]; then
            echo "$patch: ticoraw wrote output for an unsupported stream"
            return 1
        fi
        if ! grep -qF "$want" "$WORK/log"; then
            echo "$patch: stderr does not say '$want' (stderr: $(tail -n 1 "$WORK/log"))"
            return 1
        fi
        if ! grep -qi "patches welcome" "$WORK/log"; then
            echo "$patch: stderr does not report an unsupported stream (stderr: $(tail -n 1 "$WORK/log"))"
            return 1
        fi
    done
    local box
    for box in NRFM NRHM NRTI; do
        if ! patch_wrapper_version "$SAMPLES/f0000.bin" "$WORK/patched.bin" "$box" 2>"$WORK/log"; then
            echo "$box: cannot make the patched copy: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        rm -f "$WORK/patched.json"
        if "$TICORAW" "$WORK/patched.bin" header "$WORK/patched.json" >"$WORK/log" 2>&1; then
            echo "$box: ticoraw accepted the patched version string"
            return 1
        fi
        if [ -e "$WORK/patched.json" ]; then
            echo "$box: ticoraw wrote output for an unsupported version"
            return 1
        fi
        if ! grep -qF "Unsupported version \"0200\" in the $box box" "$WORK/log"; then
            echo "$box: stderr does not say 'Unsupported version \"0200\" in the $box box' (stderr: $(tail -n 1 "$WORK/log"))"
            return 1
        fi
        if ! grep -qi "patches welcome" "$WORK/log"; then
            echo "$box: stderr does not report an unsupported stream (stderr: $(tail -n 1 "$WORK/log"))"
            return 1
        fi
    done
}

# Copy frame 0 to $2 with the CFA pattern of the NRMT tag 0x0110A302 (note section 2) replaced
# by the four colour codes in $3 (0 = R, 1 = G, 2 = B, e.g. "2 1 1 0" for BGGR).
patch_cfa() { # patch_cfa <in.bin> <out.bin> <codes>
    python3 -I - "$1" "$2" "$3" <<'PYEOF'
import struct, sys

src, dst, codes = sys.argv[1:4]
codes = bytes(int(c) for c in codes.split())
d = bytearray(open(src, "rb").read())


def children(pos, end):  # yield (offset, size, fourcc) of the boxes between pos and end
    while pos + 8 <= end:
        size, tag = struct.unpack_from(">I4s", d, pos)
        yield pos, size, tag
        pos += size


for pos, size, tag in children(8, len(d)):
    if tag != b"NRFH":
        continue
    for npos, nsize, ntag in children(pos + 8, pos + size):
        # NRMT: size, "NRMT", u32 key, one leading byte, then u16 columns, u16 rows, colours
        if ntag == b"NRMT" and struct.unpack_from(">I", d, npos + 8)[0] == 0x0110A302:
            at = npos + 12 + 1 + 4
            assert d[at:at + 4] == b"\x00\x01\x01\x02", "unexpected CFA bytes"
            d[at:at + 4] = codes
            open(dst, "wb").write(d)
            sys.exit(0)
sys.exit("no CFA tag in the wrapper")
PYEOF
}

# Frame 0 with a CFA pattern other than RGGB: the mosaic placement is known for RGGB only
# (note 11.2), so the test program must refuse the bayer_linear stage with the
# patches-welcome error that names the pattern, and write no output.
check_cfa_unsupported() {
    need_file "$TICORAW" || return 1
    need_file "$SAMPLES/f0000.bin" || return 1
    local c codes name
    for c in "2 1 1 0|BGGR" "1 0 2 1|GRBG" "1 2 0 1|GBRG"; do
        codes="${c%%|*}"
        name="${c#*|}"
        if ! patch_cfa "$SAMPLES/f0000.bin" "$WORK/patched.bin" "$codes" 2>"$WORK/log"; then
            echo "$name: cannot make the patched copy: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        rm -f "$WORK/patched.bin.out"
        if "$TICORAW" "$WORK/patched.bin" bayer_linear "$WORK/patched.bin.out" >"$WORK/log" 2>&1; then
            echo "$name: ticoraw accepted the patched stream"
            return 1
        fi
        if [ -e "$WORK/patched.bin.out" ]; then
            echo "$name: ticoraw wrote output for an unsupported CFA pattern"
            return 1
        fi
        if ! grep -qF "Unsupported CFA pattern (cfa) $name" "$WORK/log"; then
            echo "$name: stderr does not say 'Unsupported CFA pattern (cfa) $name' (stderr: $(tail -n 1 "$WORK/log"))"
            return 1
        fi
        if ! grep -qi "patches welcome" "$WORK/log"; then
            echo "$name: stderr does not report an unsupported stream (stderr: $(tail -n 1 "$WORK/log"))"
            return 1
        fi
    done
    # The decoder itself: the first 9 MB of the clip (frame 0 and the start of frame 1), with the
    # CFA of frame 0 changed to BGGR, must give no picture and name the pattern.
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    head -c 9000000 "$CLIP" >"$WORK/cfa_clip.mov"
    if ! python3 -I - "$WORK/cfa_clip.mov" <<'PYEOF' 2>"$WORK/log"
import sys

d = bytearray(open(sys.argv[1], "rb").read())
sig = b"NRMT\x01\x10\xa3\x02\x00\x00\x02\x00\x02\x00\x01\x01\x02"
at = d.find(sig)
if at < 0:
    sys.exit("no CFA tag in the first 9 MB")
d[at + len(sig) - 4:at + len(sig)] = b"\x02\x01\x01\x00"
open(sys.argv[1], "wb").write(d)
PYEOF
    then
        echo "cannot patch the clip prefix: $(tail -n 1 "$WORK/log")"
        return 1
    fi
    rm -f "$WORK/cfa_clip.out"
    run_limited 1 "$FFMPEG" -nostdin -v error -i "$WORK/cfa_clip.mov" -an -frames:v 1 -f rawvideo -y \
        "$WORK/cfa_clip.out" >"$WORK/log" 2>&1
    if ! grep -qF "Unsupported CFA pattern (cfa) BGGR" "$WORK/log"; then
        echo "ffmpeg: stderr does not say 'Unsupported CFA pattern (cfa) BGGR' (stderr: $(tail -n 1 "$WORK/log"))"
        return 1
    fi
    if [ -s "$WORK/cfa_clip.out" ]; then
        echo "ffmpeg wrote a picture for an unsupported CFA pattern"
        return 1
    fi
    rm -f "$WORK/cfa_clip.mov" "$WORK/cfa_clip.out"
}

# Run one int32 plane stage of the test program on every test frame and compare it with the
# reference dump, tolerance 0. The size of the planes comes from the reference frame JSON.
stage_check() { # stage_check <stage>: helper, not a check itself
    need_file "$TICORAW" || return 1
    need_file "$COMPARE" || return 1
    local stage="$1" f out w h
    for f in $FRAMES; do
        need_file "$SAMPLES/f$f.bin" || return 1
        need_file "$REF/f$f.$stage.bin" || return 1
        need_file "$REF/f$f.json" || return 1
        read -r w h < <(python3 -I -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j["cw"], j["ch"])' "$REF/f$f.json")
        out="$WORK/f$f.$stage.bin"
        rm -f "$out"
        if ! "$TICORAW" "$SAMPLES/f$f.bin" "$stage" "$out" >"$WORK/log" 2>&1; then
            echo "frame $f: ticoraw $stage failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        if ! python3 "$COMPARE" "$out" "$REF/f$f.$stage.bin" --dtype int32 --planes 4 \
            --width "$w" --height "$h" --tolerance 0 >"$WORK/log" 2>&1; then
            echo "frame $f: $stage differs from reference: $(head -n 2 "$WORK/log" | tr '\n' ' ')"
            return 1
        fi
        rm -f "$out"
    done
}

# Stage coeffs (entropy decoding and dequantization) matches the reference on every frame.
check_coeffs() { stage_check coeffs; }

# Stage planes_st (after the inverse wavelet) matches the reference on every frame.
check_planes() { stage_check planes_st; }

# Stage cfa_companded (after the inverse Star-Tetrix) matches the reference on every frame.
check_cfa() { stage_check cfa_companded; }

# A focused diagnostic subset of check_cfa (same stage, same frame 0818), kept to localise
# edge regressions quickly: it compares only the rows and columns where the clamped
# neighbours, the partial last slice and the odd wavelet widths show up first.
# Edges of stage cfa_companded on frame 0818, tolerance 0: the last 25 quad rows (rows 1680
# and below, which include the partial last slice, as 3410 is not a multiple of 16), and the
# last 8 columns of every plane (columns 3022 and up of the 3030 wide planes).
check_edges() {
    need_file "$TICORAW" || return 1
    need_file "$COMPARE" || return 1
    local f=0818 stage=cfa_companded out w h
    need_file "$SAMPLES/f$f.bin" || return 1
    need_file "$REF/f$f.$stage.bin" || return 1
    need_file "$REF/f$f.json" || return 1
    read -r w h < <(python3 -I -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j["cw"], j["ch"])' "$REF/f$f.json")
    out="$WORK/f$f.$stage.edges.bin"
    rm -f "$out"
    if ! "$TICORAW" "$SAMPLES/f$f.bin" "$stage" "$out" >"$WORK/log" 2>&1; then
        echo "frame $f: ticoraw $stage failed: $(tail -n 1 "$WORK/log")"
        return 1
    fi
    if ! python3 "$COMPARE" "$out" "$REF/f$f.$stage.bin" --dtype int32 --planes 4 \
        --width "$w" --height "$h" --tolerance 0 --rows-from 1680 >"$WORK/log" 2>&1; then
        echo "frame $f: $stage rows 1680 and below differ from reference: $(head -n 2 "$WORK/log" | tr '\n' ' ')"
        return 1
    fi
    if ! python3 "$COMPARE" "$out" "$REF/f$f.$stage.bin" --dtype int32 --planes 4 \
        --width "$w" --height "$h" --tolerance 0 --cols-from 3022 >"$WORK/log" 2>&1; then
        echo "frame $f: $stage columns 3022 and up differ from reference: $(head -n 2 "$WORK/log" | tr '\n' ' ')"
        return 1
    fi
    rm -f "$out"
}

NEV="${NEV:-$ROOT/testdata/ref/A015_C004_nraw.NEV}"
BAYER_W=6060
BAYER_H=3410

# Compare a uint16 mosaic dump with a reference bayer_linear dump, tolerance 0 (note 9.3).
bayer_compare() { # bayer_compare <ours> <ref> <label>: helper, not a check itself
    if ! python3 "$COMPARE" "$1" "$2" --dtype uint16 --planes 1 --width "$BAYER_W" \
        --height "$BAYER_H" --tolerance 0 >"$WORK/log" 2>&1; then
        echo "$3: bayer_linear differs from reference: $(head -n 2 "$WORK/log" | tr '\n' ' ')"
        return 1
    fi
}

# Decode frame <n> of <clip> with the select filter and write it as raw video to <out>.
decode_frame_n() { # decode_frame_n <clip> <n> <out>: helper, not a check itself
    rm -f "$3"
    if ! run_limited "$(($2 + 1))" "$FFMPEG" -nostdin -v error -i "$1" -an -vf "select=eq(n\,$2)" -frames:v 1 \
        -f rawvideo -y "$3" >"$WORK/log" 2>&1; then
        echo "ffmpeg failed on frame $2: $(tail -n 1 "$WORK/log")"
        return 1
    fi
}

# The test program's bayer_linear stage matches the reference dump on every test frame.
check_bayer_stage() {
    need_file "$TICORAW" || return 1
    need_file "$COMPARE" || return 1
    local f out
    for f in $FRAMES; do
        need_file "$SAMPLES/f$f.bin" || return 1
        need_file "$REF/f$f.bayer_linear.bin" || return 1
        out="$WORK/f$f.bayer_stage.bin"
        rm -f "$out"
        if ! "$TICORAW" "$SAMPLES/f$f.bin" bayer_linear "$out" >"$WORK/log" 2>&1; then
            echo "frame $f: ticoraw bayer_linear failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        bayer_compare "$out" "$REF/f$f.bayer_linear.bin" "frame $f" || return 1
        rm -f "$out"
    done
}

# ffmpeg output for every test frame equals the reference bayer_linear dump.
check_bayer() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    need_file "$COMPARE" || return 1
    local f out
    for f in $FRAMES; do
        need_file "$REF/f$f.bayer_linear.bin" || return 1
        out="$WORK/f$f.bayer.bin"
        decode_frame_n "$CLIP" "$((10#$f))" "$out" || return 1
        bayer_compare "$out" "$REF/f$f.bayer_linear.bin" "frame $f" || return 1
        rm -f "$out"
    done
}

# ffprobe lists the six ticoraw.* frame metadata keys on the first frame. Five carry the values
# of the reference f0000.json meta section (numbers within 1e-4). ticoraw.black_level is not in
# the reference JSON (note 9: the black level comes from the vendor bytes), so it is compared
# with 1008, the black level of the test clip (note 9).
check_metadata_keys() {
    need_file "$FFPROBE" || return 1
    need_file "$CLIP" || return 1
    need_file "$REF/f0000.json" || return 1
    if ! "$FFPROBE" -v error -select_streams v:0 -show_frames -read_intervals %+#1 \
        -show_entries frame_tags -of json "$CLIP" >"$WORK/tags.json" 2>"$WORK/log"; then
        echo "ffprobe failed: $(tail -n 1 "$WORK/log")"
        return 1
    fi
    python3 -I - "$WORK/tags.json" "$REF/f0000.json" <<'PYEOF'
import json, sys


def fail(msg):  # the reason goes to stdout, where decoder_checks.sh collects it
    print(msg)
    sys.exit(1)


frames = json.load(open(sys.argv[1])).get("frames", [])
ref = json.load(open(sys.argv[2]))["meta"]
if not frames:
    fail("ffprobe printed no frame")
tags = frames[0].get("tags", {})
want = {"cfa": [ref["cfa"]], "wb_gain": ref["wb_gain"], "cam_to_xyz": ref["cam_to_xyz"],
        "iso": [ref["iso"]], "white_level": [ref["white_level"]],
        "black_level": [ref.get("black_level", 1008)]}  # 1008: test clip, not in the JSON
for key, ref_vals in want.items():
    name = "ticoraw." + key
    if name not in tags:
        fail("key %s missing (tags: %s)" % (name, sorted(tags)))
    vals = tags[name].split()
    if len(vals) != len(ref_vals):
        fail("%s has %d values, expected %d: %r" % (name, len(vals), len(ref_vals), tags[name]))
    for v, r in zip(vals, ref_vals):
        if isinstance(r, str):
            ok = v == r
        else:
            try:
                ok = abs(float(v) - r) <= 1e-4
            except ValueError:
                ok = False
        if not ok:
            fail("%s = %r, reference %r" % (name, tags[name], ref_vals))
PYEOF
}

# framemd5 of the first 50 frames is the same with 1 and with 8 decoder threads.
check_threads() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    local t
    for t in 1 8; do
        if ! run_limited 50 "$FFMPEG" -nostdin -v error -threads "$t" -i "$CLIP" -an -frames:v 50 \
            -f framemd5 -y "$WORK/threads$t.md5" >"$WORK/log" 2>&1; then
            echo "ffmpeg -threads $t failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
    done
    if [ "$(grep -vc '^#' "$WORK/threads1.md5")" -ne 50 ]; then
        echo "framemd5 with -threads 1 has $(grep -vc '^#' "$WORK/threads1.md5") frames, expected 50"
        return 1
    fi
    if ! cmp -s "$WORK/threads1.md5" "$WORK/threads8.md5"; then
        echo "framemd5 differs between -threads 1 and -threads 8: $(diff "$WORK/threads1.md5" "$WORK/threads8.md5" | sed -n 2p)"
        return 1
    fi
}

# Slice threads: (a) the decoder advertises frame and slice threads; (b) the first 50 frames
# give the same framemd5 with -thread_type slice -threads 8 and with -thread_type frame+slice
# -threads 8 (the FFmpeg default type) as with -threads 1; (c) they decode at least 2x faster
# (wall clock, -f null) with -thread_type slice -threads 8 than with -threads 1.
check_slices() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    local caps want="Threading capabilities: frame and slice" name args t0 t1 t_one t_slice
    caps="$("$FFMPEG" -hide_banner -h decoder=tico_raw 2>&1 | sed -n 's/^ *\(Threading capabilities:\)/\1/p')"
    if [ "$caps" != "$want" ]; then
        echo "ffmpeg -h decoder=tico_raw printed '${caps:-no threading line}', expected '$want'"
        return 1
    fi

    for name in one slice framesl; do
        case "$name" in
            one)     args=(-threads 1) ;;
            slice)   args=(-thread_type slice -threads 8) ;;
            framesl) args=(-thread_type frame+slice -threads 8) ;;
        esac
        if ! run_limited 50 "$FFMPEG" -nostdin -v error "${args[@]}" -i "$CLIP" -an -frames:v 50 \
            -f framemd5 -y "$WORK/slices_$name.md5" >"$WORK/log" 2>&1; then
            echo "ffmpeg ${args[*]} failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
    done
    if [ "$(grep -vc '^#' "$WORK/slices_one.md5")" -ne 50 ]; then
        echo "framemd5 with -threads 1 has $(grep -vc '^#' "$WORK/slices_one.md5") frames, expected 50"
        return 1
    fi
    for name in slice framesl; do
        if ! cmp -s "$WORK/slices_one.md5" "$WORK/slices_$name.md5"; then
            echo "framemd5 differs between -threads 1 and $name threads: $(diff "$WORK/slices_one.md5" "$WORK/slices_$name.md5" | sed -n 2p)"
            return 1
        fi
    done

    for name in one slice; do
        case "$name" in
            one)   args=(-threads 1) ;;
            slice) args=(-thread_type slice -threads 8) ;;
        esac
        t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
        if ! run_limited 50 "$FFMPEG" -nostdin -v error "${args[@]}" -i "$CLIP" -an -frames:v 50 \
            -f null - >"$WORK/log" 2>&1; then
            echo "ffmpeg ${args[*]} -f null failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
        if [ "$name" = one ]; then
            t_one="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
        else
            t_slice="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
        fi
    done
    echo "check_slices: 50 frames: -threads 1 ${t_one} s, -thread_type slice -threads 8 ${t_slice} s" >&2
    if ! awk -v a="$t_one" -v b="$t_slice" 'BEGIN { exit !(a >= 2 * b) }'; then
        echo "slice threads decode 50 frames in $t_slice s, -threads 1 in $t_one s: less than 2x faster"
        return 1
    fi
}

# Seeking to 32.72 s (frame 818 at 25 fps) gives the last frame, equal to the reference.
check_seek_last() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    need_file "$COMPARE" || return 1
    need_file "$REF/f0818.bayer_linear.bin" || return 1
    local out="$WORK/seek.bin"
    rm -f "$out"
    if ! run_limited 1 "$FFMPEG" -nostdin -v error -ss 32.72 -i "$CLIP" -an -frames:v 1 \
        -f rawvideo -y "$out" >"$WORK/log" 2>&1; then
        echo "ffmpeg -ss 32.72 failed: $(tail -n 1 "$WORK/log")"
        return 1
    fi
    bayer_compare "$out" "$REF/f0818.bayer_linear.bin" "seek to 32.72" || return 1
    rm -f "$out"
}

# The N-RAW copy probes as tico_raw, 6060 x 3410, and its frame 100 equals the reference
# picture. Only the picture is compared: its cam_to_xyz differs by design (note 10.8).
check_nev() {
    need_file "$FFPROBE" || return 1
    need_file "$FFMPEG" || return 1
    need_file "$NEV" || return 1
    need_file "$COMPARE" || return 1
    need_file "$REF/f0100.bayer_linear.bin" || return 1
    local out want="tico_raw,6060,3410"
    out="$("$FFPROBE" -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height -of csv=p=0 "$NEV" 2>"$WORK/probe.err")"
    if [ "$out" != "$want" ]; then
        echo "ffprobe printed '$out', expected '$want' (stderr: $(tail -n 1 "$WORK/probe.err"))"
        return 1
    fi
    out="$WORK/nev100.bin"
    decode_frame_n "$NEV" 100 "$out" || return 1
    bayer_compare "$out" "$REF/f0100.bayer_linear.bin" "N-RAW frame 100" || return 1
    rm -f "$out"
}

# --- Rec.709 view -----------------------------------------------------------
# The decoder options view, view_size and exposure select an
# RGB viewing picture (gbrp16le, BT.709, full range) instead of the default Bayer mosaic.

VIEW_REF="${VIEW_REF:-$ROOT/testdata/ref/view-p010}"
TOOL_FFMPEG="${TOOL_FFMPEG:-$(command -v ffmpeg)}"
VIEW_HALF_W=3030
VIEW_HALF_H=1705
WHITE_LEVEL=16383   # white_level of the test clip (note 9.3)

# Decode frame <n> of the clip with the given decoder options and write it as raw video to
# <out>. Seeks to n / 25 s, as check_seek_last does (every sample is a key frame). Options
# after "--" are output options (for example a scale filter).
view_frame() { # view_frame <n> <out> <decoder option>... [-- <output option>...]: helper
    local n="$1" out="$2" ss
    shift 2
    local dec=() outopts=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do dec+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    outopts=("$@")
    ss="$(awk -v n="$n" 'BEGIN { printf "%.2f", n / 25 }')"
    rm -f "$out"
    if ! run_limited 1 "$FFMPEG" -nostdin -v error ${dec[@]+"${dec[@]}"} -ss "$ss" -i "$CLIP" -an \
        -frames:v 1 ${outopts[@]+"${outopts[@]}"} -f rawvideo -y "$out" >"$WORK/log" 2>&1; then
        echo "ffmpeg ${dec[*]:-} -ss $ss failed: $(tail -n 1 "$WORK/log")"
        return 1
    fi
}

# Print the first decoded frame's color_primaries, color_range, color_space, color_transfer,
# height, pix_fmt and width as ffprobe reports them with the given decoder options: sorted
# key=value pairs joined by commas.
probe_frame() { # probe_frame <decoder option>...: helper
    "$FFPROBE" -v error "$@" -select_streams v:0 -read_intervals %+#1 -show_frames \
        -show_entries frame=pix_fmt,width,height,color_primaries,color_transfer,color_space,color_range \
        -of default=noprint_wrappers=1 "$CLIP" 2>"$WORK/probe.err" | grep -v '^TAG:' |
        sort -u | paste -sd, -
}

# Without options the decoder still outputs the Bayer mosaic: bayer_rggb16le, 6060 x 3410.
check_bayer_default() {
    need_file "$FFPROBE" || return 1
    need_file "$CLIP" || return 1
    local out want="height=3410,pix_fmt=bayer_rggb16le,width=6060"
    out="$(probe_frame | tr ',' '\n' | grep -E '^(height|pix_fmt|width)=' | paste -sd, -)"
    if [ "$out" != "$want" ]; then
        echo "ffprobe printed '$out', expected '$want' (stderr: $(tail -n 1 "$WORK/probe.err"))"
        return 1
    fi
}

# -view rec709 gives gbrp16le, BT.709 primaries and transfer, RGB matrix (gbr), full range
# (pc): 3030 x 1705 with -view_size half and 6060 x 3410 with -view_size full.
check_view_formats() {
    need_file "$FFPROBE" || return 1
    need_file "$CLIP" || return 1
    local c size w h want out
    for c in "half|$VIEW_HALF_W|$VIEW_HALF_H" "full|$BAYER_W|$BAYER_H"; do
        IFS='|' read -r size w h <<<"$c"
        want="color_primaries=bt709,color_range=pc,color_space=gbr,color_transfer=bt709"
        want="$want,height=$h,pix_fmt=gbrp16le,width=$w"
        out="$(probe_frame -c:v tico_raw -view rec709 -view_size "$size")"
        if [ "$out" != "$want" ]; then
            echo "view_size $size: ffprobe printed '$out', expected '$want' (stderr: $(tail -n 1 "$WORK/probe.err"))"
            return 1
        fi
    done
}

# SSIM All of two 1920 x 1080 gbrp16le raw files, from the ssim filter of TOOL_FFMPEG.
ssim_all() { # ssim_all <a.raw> <b.raw>: helper, prints the number or fails
    if ! "$TOOL_FFMPEG" -nostdin -v info -hide_banner \
        -f rawvideo -pix_fmt gbrp16le -s 1920x1080 -i "$1" \
        -f rawvideo -pix_fmt gbrp16le -s 1920x1080 -i "$2" \
        -lavfi ssim -f null - >"$WORK/ssim.log" 2>&1; then
        echo "ssim run failed: $(tail -n 1 "$WORK/ssim.log")"
        return 1
    fi
    sed -n 's/.*SSIM .* All:\([0-9.]*\).*/\1/p' "$WORK/ssim.log" | tail -n 1 | grep . ||
        { echo "no SSIM line: $(tail -n 1 "$WORK/ssim.log")"; return 1; }
}

# Our half view of frames 0, 100 and 818 against the oracle's Rec.709 render. The default
# references (testdata/ref/view-p010) are the oracle's exact P010 frames (format note 12.8
# step 2: 4:2:0, BT.709, limited range), taken before its lossy HEVC step and converted by
# FFmpeg to full-range rgb48. The HEVC renders in testdata/ref/view cap the SSIM below 0.85
# even for the oracle's own method, so they serve only the comparison stills. Our view is scaled
# to 1920 x 1080 with lanczos, then it makes the same 4:2:0 round trip: yuv420p10le with
# the BT.709 matrix and limited range, then back to rgb48 with the BT.709 matrix and full
# range. Pass: SSIM All >= 0.85 after the round trip, and the
# three channel means (after the round trip) in the same order (largest to smallest) as the
# oracle's. The SSIM without the round trip is printed too. Every frame is measured before
# the check fails; the numbers of each frame are printed on stderr.
check_view_oracle() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    need_file "$TOOL_FFMPEG" || return 1
    local f ssim ssim_rt reasons=""
    for f in $FRAMES; do
        need_file "$VIEW_REF/f$f.png" || return 1
        view_frame "$((10#$f))" "$WORK/ours.raw" -c:v tico_raw -view rec709 -view_size half -- \
            -vf scale=1920:1080:flags=lanczos,format=gbrp16le || return 1
        rm -f "$WORK/ref.raw" "$WORK/ours_rt.raw"
        if ! "$TOOL_FFMPEG" -nostdin -v error -i "$VIEW_REF/f$f.png" -frames:v 1 -vf format=gbrp16le \
            -f rawvideo -y "$WORK/ref.raw" >"$WORK/log" 2>&1; then
            echo "frame $f: cannot read the reference PNG: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        if ! "$TOOL_FFMPEG" -nostdin -v error -f rawvideo -pix_fmt gbrp16le -s 1920x1080 \
            -i "$WORK/ours.raw" -frames:v 1 -vf \
            "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p10le,scale=in_color_matrix=bt709:in_range=tv:out_range=full,format=rgb48le,format=gbrp16le" \
            -f rawvideo -y "$WORK/ours_rt.raw" >"$WORK/log" 2>&1; then
            echo "frame $f: 4:2:0 round trip failed: $(tail -n 1 "$WORK/log")"
            return 1
        fi
        ssim="$(ssim_all "$WORK/ours.raw" "$WORK/ref.raw")" || { echo "frame $f: $ssim"; return 1; }
        ssim_rt="$(ssim_all "$WORK/ours_rt.raw" "$WORK/ref.raw")" || { echo "frame $f: $ssim_rt"; return 1; }
        python3 -I - "$WORK/ours_rt.raw" "$WORK/ref.raw" "$WORK/ours.raw" "$f" "$ssim_rt" "$ssim" \
            >"$WORK/oracle.out" <<'PYEOF'
import array, sys

ours, ref, direct, frame = sys.argv[1:5]
ssim, ssim_direct = float(sys.argv[5]), float(sys.argv[6])
n = 1920 * 1080


def means(path):  # gbrp16le planes G, B, R -> means of R, G, B
    a = array.array("H")
    a.frombytes(open(path, "rb").read())
    if sys.byteorder != "little":
        a.byteswap()
    if len(a) != 3 * n:
        print("frame %s: %s has %d samples, expected %d" % (frame, path, len(a), 3 * n))
        sys.exit(1)
    g, b, r = (sum(a[i * n:(i + 1) * n]) / n for i in range(3))
    return {"R": r, "G": g, "B": b}


mo, mr, md = means(ours), means(ref), means(direct)
order = lambda m: "".join(sorted(m, key=m.get, reverse=True))
sys.stderr.write("check_view_oracle: frame %s SSIM All %.6f after the 4:2:0 round trip, %.6f "
                 "without; means ours R %.0f G %.0f B %.0f (%s) after, R %.0f G %.0f B %.0f "
                 "without; oracle R %.0f G %.0f B %.0f (%s)\n"
                 % (frame, ssim, ssim_direct, mo["R"], mo["G"], mo["B"], order(mo),
                    md["R"], md["G"], md["B"], mr["R"], mr["G"], mr["B"], order(mr)))
if ssim < 0.85:
    print("frame %s: SSIM All %.6f < 0.85" % (frame, ssim))
    sys.exit(1)
if order(mo) != order(mr):
    print("frame %s: channel mean order %s (ours) differs from %s (oracle)"
          % (frame, order(mo), order(mr)))
    sys.exit(1)
PYEOF
        [ $? -eq 0 ] || reasons="${reasons:+$reasons; }$(cat "$WORK/oracle.out")"
    done
    rm -f "$WORK/ours.raw" "$WORK/ours_rt.raw" "$WORK/ref.raw"
    if [ -n "$reasons" ]; then
        echo "$reasons"
        return 1
    fi
}

# The worked example of format note 12.10 (test clip, R3D NE, default settings): the view's
# per-pixel colour steps (12.4 to 12.8 step 1), run by the test program's view_example stage
# on neutral normalised inputs with the black level, gains and matrix of frame 0, give the
# 16-bit codes 34145 (mid-grey, N = 0.0220971), 65212 (white-balanced 0.18) and 65535
# (sensor white) in each of R, G and B, within 1 code.
check_view_example() {
    need_file "$TICORAW" || return 1
    need_file "$SAMPLES/f0000.bin" || return 1
    rm -f "$WORK/example.txt"
    if ! "$TICORAW" "$SAMPLES/f0000.bin" view_example "$WORK/example.txt" >"$WORK/log" 2>&1; then
        echo "ticoraw view_example failed: $(tail -n 1 "$WORK/log")"
        return 1
    fi
    python3 -I - "$WORK/example.txt" <<'PYEOF'
import sys

want = {"midgrey": 34145, "grey018": 65212, "white": 65535}
got = {}
for line in open(sys.argv[1]):
    f = line.split()
    got[f[0]] = [int(v) for v in f[1:4]]
for name, q in want.items():
    if name not in got:
        print("no line for %s in the view_example output" % name)
        sys.exit(1)
    if any(abs(v - q) > 1 for v in got[name]):
        print("%s: R G B = %s, expected %d within 1" % (name, got[name], q))
        sys.exit(1)
sys.stderr.write("check_view_example: %s\n" % " ".join(
    "%s %s" % (k, "/".join(map(str, got[k]))) for k in want))
PYEOF
}

# Clipped highlights stay neutral: in frame 0, every half-view pixel whose four CFA samples
# are all >= white_level (all equal 16383, the curve ceiling) has |R - G| <= 655 and
# |B - G| <= 655 (1 % of 65535). If frame 0 has no such pixel, the first test frame that has
# one is used; the check fails if none has.
check_view_highlights() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    local f rc
    for f in $FRAMES; do
        view_frame "$((10#$f))" "$WORK/hl_bayer.raw" || return 1
        view_frame "$((10#$f))" "$WORK/hl_view.raw" -c:v tico_raw -view rec709 -view_size half || return 1
        python3 -I - "$WORK/hl_bayer.raw" "$WORK/hl_view.raw" "$f" "$BAYER_W" "$BAYER_H" \
            "$WHITE_LEVEL" <<'PYEOF'
import array, re, struct, sys

bayer_path, view_path, frame = sys.argv[1:4]
W, H, white = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
cw, ch = W // 2, H // 2
bayer = open(bayer_path, "rb").read()
view = array.array("H")
view.frombytes(open(view_path, "rb").read())
if sys.byteorder != "little":
    view.byteswap()
if len(bayer) != W * H * 2 or len(view) != 3 * cw * ch:
    print("frame %s: unexpected sizes %d, %d" % (frame, len(bayer), len(view)))
    sys.exit(1)
pair = struct.pack("<HH", white, white)  # two neighbouring samples at the white level
find = re.compile(b"(?=" + re.escape(pair) + b")")
n = cw * ch
count = worst = 0
bad = None
for y in range(ch):
    row0 = bayer[2 * y * W * 2:(2 * y + 1) * W * 2]
    row1 = bayer[(2 * y + 1) * W * 2:(2 * y + 2) * W * 2]
    for m in find.finditer(row0):
        off = m.start()
        if off % 4 or row1[off:off + 4] != pair:
            continue
        x = off // 4
        g, b, r = view[y * cw + x], view[n + y * cw + x], view[2 * n + y * cw + x]
        d = max(abs(r - g), abs(b - g))
        count += 1
        worst = max(worst, d)
        if d > 655 and bad is None:
            bad = (x, y, r, g, b)
sys.stderr.write("check_view_highlights: frame %s: %d clipped quads, largest |R-G| or |B-G| %d\n"
                 % (frame, count, worst))
if bad:
    print("frame %s: quad (%d, %d) has R %d G %d B %d: not neutral within 655" % ((frame,) + bad))
    sys.exit(1)
sys.exit(0 if count else 3)  # 3: no clipped quad in this frame
PYEOF
        rc=$?
        [ "$rc" -eq 0 ] && break
        [ "$rc" -eq 3 ] || return 1
    done
    rm -f "$WORK/hl_bayer.raw" "$WORK/hl_view.raw"
    if [ "$rc" -ne 0 ]; then
        echo "no test frame ($FRAMES) has a quad with all four samples at $WHITE_LEVEL"
        return 1
    fi
}

# -view rec709: framemd5 of the first 30 frames of the half view, and of the first 4 frames
# of the full view (-view_size full), is the same with -threads 1, with -thread_type frame
# -threads 4 and with -thread_type slice -threads 8.
check_view_threads() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    local c size frames name args
    for c in half:30 full:4; do
        size="${c%%:*}"
        frames="${c#*:}"
        for name in one frame slice; do
            case "$name" in
                one)   args=(-threads 1) ;;
                frame) args=(-thread_type frame -threads 4) ;;
                slice) args=(-thread_type slice -threads 8) ;;
            esac
            if ! run_limited "$((frames * 4))" "$FFMPEG" -nostdin -v error -c:v tico_raw -view rec709 \
                -view_size "$size" "${args[@]}" -i "$CLIP" -an -frames:v "$frames" -f framemd5 \
                -y "$WORK/view_$name.md5" >"$WORK/log" 2>&1; then
                echo "ffmpeg -view rec709 -view_size $size ${args[*]} failed: $(tail -n 1 "$WORK/log")"
                return 1
            fi
        done
        if [ "$(grep -vc '^#' "$WORK/view_one.md5")" -ne "$frames" ]; then
            echo "view_size $size: framemd5 with -threads 1 has $(grep -vc '^#' "$WORK/view_one.md5") frames, expected $frames"
            return 1
        fi
        for name in frame slice; do
            if ! cmp -s "$WORK/view_one.md5" "$WORK/view_$name.md5"; then
                echo "view_size $size: framemd5 differs between -threads 1 and $name threads: $(diff "$WORK/view_one.md5" "$WORK/view_$name.md5" | sed -n 2p)"
                return 1
            fi
        done
    done
}

# The exposure gain k of format note 12.5 has F = 1 for N-RAW and F = 2^-0.5 for R3D NE: the
# reference renders the N-RAW rewrap of the clip half a stop brighter. Frame 0 of the N-RAW
# copy (testdata/ref/A015_C004_nraw.NEV) and of the R3D, half view: (1) the N-RAW view at
# exposure 0 has a mean G code at least 1.05 times that of the R3D view at exposure 0;
# (2) it is within 5 % of the R3D view at exposure +0.5, which has the same k. The means
# are of the 16-bit codes after the tone curve, so 0.5 EV is not a factor of 2^0.5 in them.
# Measured 2026-11-08: ratio (1) 1.118 and (2) 0.989 with F = 1; with F = 2^-0.5 for N-RAW
# too (a test build) 0.989 and 0.875. The limits sit about halfway between.
check_view_nraw_gain() {
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    need_file "$NEV" || return 1
    CLIP="$NEV" view_frame 0 "$WORK/gain_nraw.raw" -c:v tico_raw -view rec709 -view_size half || return 1
    view_frame 0 "$WORK/gain_r3d.raw" -c:v tico_raw -view rec709 -view_size half || return 1
    view_frame 0 "$WORK/gain_r3d05.raw" -c:v tico_raw -view rec709 -view_size half -exposure 0.5 || return 1
    python3 -I - "$WORK/gain_nraw.raw" "$WORK/gain_r3d.raw" "$WORK/gain_r3d05.raw" \
        "$VIEW_HALF_W" "$VIEW_HALF_H" <<'PYEOF' || return 1
import array, sys

n = int(sys.argv[4]) * int(sys.argv[5])


def mean_g(path):  # gbrp16le: plane 0 is G
    a = array.array("H")
    with open(path, "rb") as f:
        a.frombytes(f.read(2 * n))
    if sys.byteorder != "little":
        a.byteswap()
    if len(a) != n:
        print("%s: %d G samples, expected %d" % (path, len(a), n))
        sys.exit(1)
    return sum(a) / n


nraw, r3d, r3d05 = (mean_g(p) for p in sys.argv[1:4])
up, match = nraw / r3d, nraw / r3d05
sys.stderr.write("check_view_nraw_gain: mean G N-RAW %.1f, R3D %.1f, R3D +0.5 EV %.1f; "
                 "N-RAW / R3D %.4f, N-RAW / R3D +0.5 EV %.4f\n" % (nraw, r3d, r3d05, up, match))
if up < 1.05:
    print("N-RAW mean G is %.4f times the R3D one, expected at least 1.05 (F = 1 for N-RAW)" % up)
    sys.exit(1)
if abs(match - 1.0) > 0.05:
    print("N-RAW mean G is %.4f times the R3D one at +0.5 EV, expected 1 within 0.05" % match)
    sys.exit(1)
PYEOF
    rm -f "$WORK/gain_nraw.raw" "$WORK/gain_r3d.raw" "$WORK/gain_r3d05.raw"
}

# A non-finite exposure is refused before any frame is decoded. (1) Through the API: the
# option range (-8 to 8) does not stop a NaN set with av_opt_set_double() (every comparison
# with NaN is false), so the decoder checks it at init: the test program's exposure_nan
# stage must report avcodec_open2 = AVERROR(EINVAL) (-22). (2) On the ffmpeg command line,
# nan, inf and -inf must each end with an error and no frame (FFmpeg's option parser already
# refuses them: a NaN expression result and the range).
check_view_exposure_finite() {
    need_file "$TICORAW" || return 1
    need_file "$FFMPEG" || return 1
    need_file "$CLIP" || return 1
    need_file "$SAMPLES/f0000.bin" || return 1
    local v frames line
    rm -f "$WORK/exp.txt"
    if ! "$TICORAW" "$SAMPLES/f0000.bin" exposure_nan "$WORK/exp.txt" >"$WORK/log" 2>&1; then
        echo "ticoraw exposure_nan failed: $(tail -n 1 "$WORK/log")"
        return 1
    fi
    line="$(cat "$WORK/exp.txt")"
    if [ "$line" != "avcodec_open2 -22" ]; then
        echo "NaN exposure through av_opt_set_double: '$line', expected 'avcodec_open2 -22' (EINVAL)"
        return 1
    fi
    for v in nan inf -inf; do
        rm -f "$WORK/exp.md5"
        if run_limited 1 "$FFMPEG" -nostdin -v error -c:v tico_raw -view rec709 -exposure "$v" \
            -i "$CLIP" -an -frames:v 1 -f framemd5 -y "$WORK/exp.md5" >"$WORK/log" 2>&1; then
            frames="$(grep -vc '^#' "$WORK/exp.md5" 2>/dev/null || true)"
            echo "-exposure $v: ffmpeg exit 0 with ${frames:-0} frames, expected an error"
            return 1
        fi
        if [ -s "$WORK/exp.md5" ] && [ "$(grep -vc '^#' "$WORK/exp.md5")" -ne 0 ]; then
            echo "-exposure $v: ffmpeg wrote a frame before the error"
            return 1
        fi
    done
}

# Damaged input. Run this check against an AddressSanitizer build for the full effect:
#   FFMPEG_BUILD=/path/to/build-asan tests/decoder_checks.sh corrupt
# Environment: CORRUPT_SEED (default: random, always printed), CORRUPT_COPIES (random-flip
# copies of frame 0, default 200), CORRUPT_TIMEOUT (seconds per frame, default 10).
#   1. Frame 0 cut to 50 %, 90 % and 1,100 bytes: exit 1 with "Invalid data" and no output.
#      The same cuts with the wrapper sizes (NRAW box, NRTI) fixed up, so the cut reaches the
#      entropy decoder: the same result.
#   2. Copies of frame 0 with 16 random bytes changed after offset 1,024, and targeted
#      mutations of the packet headers found with note section 5: Dr = 1 (raw GCLI packets),
#      D[b] changed to 0, 1 or 2 (coding modes), lengths, Lprc, Q and R, runs of 0x00 or 0xFF
#      in the sub-packets. Each copy must give
#      exit 0 or 1, no hang, and no sanitizer report.
#   3. The first 100 MB of the clip: ffmpeg decodes every complete frame, no crash.
#   4. ffmpeg -max_pixels below the frame size: an error, no picture, before any allocation.
check_corrupt() {
    need_file "$TICORAW" || return 1
    need_file "$FFMPEG" || return 1
    need_file "$FFPROBE" || return 1
    need_file "$CLIP" || return 1
    need_file "$SAMPLES/f0000.bin" || return 1
    local seed="${CORRUPT_SEED:-$((RANDOM * 32768 + RANDOM))}"
    echo "check_corrupt: seed $seed" >&2
    export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:exitcode=99}"
    export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1:exitcode=98}"

    python3 -I - "$TICORAW" "$SAMPLES/f0000.bin" "$WORK" "$seed" "${CORRUPT_COPIES:-200}" \
        "${CORRUPT_TIMEOUT:-10}" <<'PYEOF'
import os, random, re, struct, subprocess, sys, time

ticoraw, sample, work, seed, copies, limit = sys.argv[1:7]
seed, copies, limit = int(seed), int(copies), float(limit)
orig = open(sample, "rb").read()
out_path = work + "/fuzz.out"
bad = re.compile(rb"AddressSanitizer|runtime error|SUMMARY: |ERROR: ")


def fail(msg):  # the reason goes to stdout, where decoder_checks.sh collects it
    print(msg)
    sys.exit(1)


def run(data, label, want_invalid=False):
    """Run the bayer_linear stage on data. Returns the exit status (0 or 1)."""
    path = work + "/fuzz.bin"
    open(path, "wb").write(data)
    try:
        os_unlink(out_path)
        t0 = time.time()
        try:
            r = subprocess.run([ticoraw, path, "bayer_linear", out_path], capture_output=True,
                               timeout=limit)
        except subprocess.TimeoutExpired:
            fail("%s: no result after %g s (hang)" % (label, limit))
        err = r.stderr
        if bad.search(err):
            # $WORK is deleted when the check ends, so keep the input outside it
            keep = "%s/ticoraw-crash-%d-%s.bin" % (os.environ.get("TMPDIR", "/tmp").rstrip("/"),
                                                    seed, re.sub(r"\W", "_", label))
            open(keep, "wb").write(data)
            fail("%s: sanitizer report (input kept in %s; or rerun with CORRUPT_SEED=%d): %s"
                 % (label, keep, seed, bad.search(err).group(0).decode() + " ... " +
                    err.decode(errors="replace").strip().splitlines()[-1]))
        if r.returncode not in (0, 1):
            fail("%s: exit status %d (crash?): %s" % (label, r.returncode,
                                                      err.decode(errors="replace")[-200:]))
        if r.returncode == 1 and b"Invalid data" not in err and b"patches welcome" not in err \
                and b"Cannot allocate" not in err:
            fail("%s: exit 1 without an Invalid data message: %s"
                 % (label, err.decode(errors="replace")[-200:]))
        if want_invalid:
            if r.returncode != 1 or b"Invalid data" not in err:
                fail("%s: expected exit 1 with 'Invalid data', got exit %d: %s"
                     % (label, r.returncode, err.decode(errors="replace")[-200:]))
            if os_exists(out_path):
                fail("%s: output written for a damaged stream" % label)
        return r.returncode
    finally:
        os_unlink(path)
        os_unlink(out_path)


def os_unlink(p):
    import os
    try:
        os.unlink(p)
    except FileNotFoundError:
        pass


def os_exists(p):
    import os
    return os.path.exists(p)


# --- locate things in the sample (note sections 2, 3 and 5) ---------------------------------
pos = 8
nraw_children_end = None
while True:  # child boxes of NRAW; NRTH is the last, NRTI its first child
    size, tag = struct.unpack_from(">I4s", orig, pos)
    if tag == b"NRTH":
        nrti = pos + 8  # NRTI box at pos + 8: size, tag, "0100", u32 length
        assert orig[nrti + 4:nrti + 8] == b"NRTI"
        nrti_len_at = nrti + 12
    pos += size
    if tag == b"NRTH":
        break
cs = pos
assert orig[cs:cs + 2] == b"\xff\x10"
p = cs + 2
while struct.unpack_from(">H", orig, p)[0] != 0xFF20:  # markers up to the first SLH
    p += 2 + struct.unpack_from(">H", orig, p + 2)[0]

precincts = []  # (header offset, [packet header offsets])
while orig[p:p + 2] == b"\xff\x20":
    p += 6
    for _ in range(16):
        if orig[p] == 0xFF:
            break
        lprc = int.from_bytes(orig[p:p + 3], "big")
        q, pk = p + 12, []
        for _ in range(8):
            pk.append(q)
            v = int.from_bytes(orig[q:q + 7], "big")
            ldat, lcnt, lsgn = (v >> 35) & 0xFFFFF, (v >> 15) & 0xFFFFF, v & 0x7FFF
            q += 7 + 12 + lcnt + ldat + lsgn  # 12 significance bytes: every band has D[b] = 3
        assert q <= p + 12 + lprc, "packet walk runs past the precinct"
        precincts.append((p, pk))
        p += 12 + lprc
assert orig[p:p + 2] == b"\xff\x11" and len(precincts) == 853, "walk did not reach EOC"
packets = [(pi, k, off) for pi, (_, pk) in enumerate(precincts) for k, off in enumerate(pk)]


def put_bits(d, bit_at, n, value):  # big-endian bit field inside d
    for i in range(n):
        byte, bit = divmod(bit_at + i, 8)
        mask = 0x80 >> bit
        if (value >> (n - 1 - i)) & 1:
            d[byte] |= mask
        else:
            d[byte] &= ~mask


def set_dr(d, off, v):
    put_bits(d, off * 8, 1, v)


def set_len(d, off, which, v):  # which 0 = Ldat (bits 1-20), 1 = Lcnt (21-40), 2 = Lsgn (41-55)
    start, width = ((1, 20), (21, 20), (41, 15))[which]
    put_bits(d, off * 8 + start, width, v & ((1 << width) - 1))


def set_mode(d, ph, b, v):  # D[b] of the precinct header at ph
    put_bits(d, ph * 8 + 40 + 2 * b, 2, v)


# --- 1. truncation --------------------------------------------------------------------------
stats = {}


def count(cls, rc):
    stats.setdefault(cls, [0, 0])[rc] += 1


for name, n in (("50%", len(orig) // 2), ("90%", len(orig) * 9 // 10), ("1100 bytes", 1100)):
    run(orig[:n], "cut to " + name, want_invalid=True)       # sizes of the wrapper now wrong
    d = bytearray(orig[:n])                                  # sizes fixed: cut inside the codestream
    if n > cs:
        struct.pack_into(">I", d, 0, n)
        struct.pack_into(">I", d, nrti_len_at, n - cs)
        run(bytes(d), "cut to %s, sizes fixed" % name, want_invalid=True)
stats["truncation"] = [0, 6]

# --- 2. random and targeted mutations -------------------------------------------------------
rng = random.Random(seed)


def case(cls, i, d):
    count(cls, run(bytes(d), "%s #%d (seed %d)" % (cls, i, seed)))


for i in range(copies):
    d = bytearray(orig)
    for _ in range(16):
        d[rng.randrange(1024, len(d))] ^= rng.randrange(1, 256)
    case("random flips", i, d)

for i in range(100):  # Dr = 1: raw GCLI packets
    d = bytearray(orig)
    kind = i % 4
    if kind == 0:    # one packet anywhere
        set_dr(d, rng.choice(packets)[2], 1)
    elif kind == 1:  # all 8 packets of one precinct
        for off in rng.choice(precincts)[1]:
            set_dr(d, off, 1)
    elif kind == 2:  # first packet of the first precinct (reaches the decoder at once)
        set_dr(d, precincts[0][1][rng.randrange(8)], 1)
    else:            # one packet, with the length fields of the packet changed a little too
        pi, k, off = rng.choice(packets)
        set_dr(d, off, 1)
        set_len(d, off, rng.randrange(3), rng.randrange(0, 64))
    case("Dr = 1", i, d)

for i in range(100):  # D[b] in {0, 1, 2}
    d = bytearray(orig)
    kind = i % 4
    ph = precincts[0][0] if kind == 3 else rng.choice(precincts)[0]
    if kind == 0:    # one band
        set_mode(d, ph, rng.randrange(25), rng.randrange(3))
    elif kind == 1:  # a random subset of bands
        for b in range(25):
            if rng.random() < 0.3:
                set_mode(d, ph, b, rng.randrange(3))
    elif kind == 2:  # every band of one precinct, one mode
        m = rng.randrange(3)
        for b in range(25):
            set_mode(d, ph, b, m)
    else:            # first precinct, all bands, mode i // 4 % 3
        for b in range(25):
            set_mode(d, ph, b, (i // 4) % 3)
    case("D[b] in 0..2", i, d)

for i in range(60):  # packet length fields, Lprc, Q and R
    d = bytearray(orig)
    kind = i % 3
    if kind == 0:
        pi, k, off = rng.choice(packets)
        set_len(d, off, rng.randrange(3), rng.choice((0, 1, rng.randrange(1 << 20), 0xFFFFF)))
    elif kind == 1:
        ph = rng.choice(precincts)[0]
        d[ph:ph + 3] = rng.choice((0, 1, rng.randrange(1 << 24), 0xFFFFFF)).to_bytes(3, "big")
    else:
        ph = rng.choice(precincts)[0]
        d[ph + 3 + rng.randrange(2)] = rng.choice((0, 255, rng.randrange(256)))
    case("lengths, Lprc, Q, R", i, d)

for i in range(60):  # a run of 0xFF or 0x00 inside the GCLI, data or sign sub-packet
    d = bytearray(orig)
    pi, k, off = rng.choice(packets)
    v = int.from_bytes(orig[off:off + 7], "big")
    ldat, lcnt, lsgn = (v >> 35) & 0xFFFFF, (v >> 15) & 0xFFFFF, v & 0x7FFF
    start, size = ((off + 7 + 12, lcnt), (off + 7 + 12 + lcnt, ldat),
                   (off + 7 + 12 + lcnt + ldat, lsgn))[i % 3]
    a = start + rng.randrange(max(size, 1))
    n = min(rng.choice((4, 16, 64, size)), start + size - a)
    d[a:a + n] = bytes([rng.choice((0x00, 0xFF))]) * n
    case("sub-packet fill", i, d)

total = copies + 100 + 100 + 60 + 60
sys.stderr.write("check_corrupt: seed %d, %d mutated copies + 6 cut copies\n" % (seed, total))
for cls, (ok, err) in stats.items():
    sys.stderr.write("check_corrupt:   %-22s exit 0: %3d   exit 1: %3d\n" % (cls, ok, err))
PYEOF
    [ $? -eq 0 ] || return 1
    rm -f "$WORK/fuzz.bin" "$WORK/fuzz.out"

    # The frame size is checked against max_pixels before the decoder allocates anything.
    rm -f "$WORK/maxpix.out"
    run_limited 1 "$FFMPEG" -nostdin -v error -max_pixels 1000000 -i "$CLIP" -an -frames:v 1 -f rawvideo -y \
        "$WORK/maxpix.out" >"$WORK/log" 2>&1
    if ! grep -q "exceeds specified max pixel count" "$WORK/log" || grep -Eq "AddressSanitizer|runtime error" "$WORK/log"; then
        echo "-max_pixels 1000000: no 'exceeds specified max pixel count' error (stderr: $(tail -n 1 "$WORK/log"))"
        return 1
    fi
    if [ -s "$WORK/maxpix.out" ]; then
        echo "-max_pixels 1000000: ffmpeg wrote a picture"
        return 1
    fi
    rm -f "$WORK/maxpix.out"

    # 3. the first 100 MB of the clip
    local first_bytes=100000000 want got
    head -c "$first_bytes" "$CLIP" >"$WORK/clip100.mov"
    # complete samples in the first 100 MB, from the packet positions in the full clip
    want="$("$FFPROBE" -v error -select_streams v:0 -show_entries packet=pos,size -of csv=p=0 \
        "$CLIP" 2>/dev/null | awk -F, -v n="$first_bytes" '$1 + $2 <= n' | wc -l | tr -d ' ')"
    rm -f "$WORK/clip100.md5"
    run_limited 20 "$FFMPEG" -nostdin -v error -i "$WORK/clip100.mov" -an -f framemd5 -y "$WORK/clip100.md5" \
        >"$WORK/log" 2>&1
    local rc=$?
    if grep -Eq "AddressSanitizer|runtime error|SUMMARY: " "$WORK/log"; then
        echo "100 MB prefix: sanitizer report: $(grep -E 'AddressSanitizer|runtime error' "$WORK/log" | head -n 1)"
        return 1
    fi
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "100 MB prefix: ffmpeg exit status $rc"
        return 1
    fi
    got="$(grep -vc '^#' "$WORK/clip100.md5")"
    echo "check_corrupt: 100 MB prefix: ffmpeg exit $rc, $got frames decoded, $want complete samples" >&2
    if [ "$got" -ne "$want" ] || [ "$want" -lt 5 ]; then
        echo "100 MB prefix: ffmpeg decoded $got frames, expected $want complete ones"
        return 1
    fi
    rm -f "$WORK/clip100.mov" "$WORK/clip100.md5"
}

# IINA RAW: the installed app has its own bundle id, no update feed, only the R3D and NEV
# document types, and a bundled libavcodec that contains the tico_raw decoder.
check_iina_raw_bundle() {
    local app="${IINA_RAW_APP:-/Applications/IINA RAW.app}"
    need_file "$app/Contents/Info.plist" || return 1
    local id
    id="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)"
    if [ "$id" != "com.alperkaganavci.iina-raw" ]; then
        echo "CFBundleIdentifier is '$id', expected com.alperkaganavci.iina-raw"
        return 1
    fi
    python3 -I - "$app/Contents/Info.plist" <<'PYEOF' || return 1
import os, plistlib, sys

info = plistlib.load(open(sys.argv[1], "rb"))
if "SUFeedURL" in info:
    print("SUFeedURL is present in Info.plist")
    sys.exit(1)
for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate"):
    if info.get(key) is not False:
        print("%s is %r, expected NO" % (key, info.get(key)))
        sys.exit(1)
types = info.get("CFBundleDocumentTypes", [])
if len(types) != 2:
    print("CFBundleDocumentTypes has %d entries, expected exactly 2 (R3D and NEV)" % len(types))
    sys.exit(1)
exts = []
utis = set()
for t in types:
    exts += [e.lower() for e in t.get("CFBundleTypeExtensions", [])]
    utis |= set(t.get("LSItemContentTypes", []))
if sorted(exts) != ["nev", "r3d"]:
    print("document type extensions are %s, expected exactly R3D and NEV" % sorted(exts))
    sys.exit(1)
# Ours, plus a clip UTI that tools/install_iina_raw.sh accepted (its filename extension is
# r3d or nev); such a UTI is passed in IINA_RAW_EXTRA_UTIS (space separated).
allowed = {"com.alperkaganavci.r3d", "com.alperkaganavci.nev"} | set(os.environ.get("IINA_RAW_EXTRA_UTIS", "").split())
extra = utis - allowed
if extra:
    print("LSItemContentTypes has types other than the R3D and NEV ones: %s" % sorted(extra))
    sys.exit(1)
imported = {d.get("UTTypeIdentifier") for d in info.get("UTImportedTypeDeclarations", [])}
for want in ("com.alperkaganavci.r3d", "com.alperkaganavci.nev"):
    if want not in imported:
        print("UTImportedTypeDeclarations lacks %s" % want)
        sys.exit(1)
PYEOF
    local lib="$app/Contents/Frameworks/libavcodec.63.dylib"
    need_file "$lib" || return 1
    if ! strings "$lib" | grep -q tico_raw; then
        echo "strings of $lib has no tico_raw"
        return 1
    fi
    # The built-in decoder options of the app (AppData.rawViewDecoderOptions) must equal the
    # value that tests/mpv_harness.py (APP_VD_LAVC_O) tests with.
    local want bin found=0
    want="$(sed -n 's/^APP_VD_LAVC_O = "\(.*\)"$/\1/p' "$ROOT/tests/mpv_harness.py")"
    if [ -z "$want" ]; then
        echo "APP_VD_LAVC_O not found in tests/mpv_harness.py"
        return 1
    fi
    for bin in "$app"/Contents/MacOS/*; do
        [ -f "$bin" ] || continue
        if strings - "$bin" | grep -qxF "$want"; then found=1; break; fi
    done
    if [ "$found" -ne 1 ]; then
        echo "the app binary does not contain the harness default vd-lavc-o '$want' (AppData.swift and tests/mpv_harness.py differ)"
        return 1
    fi
}

# The stock IINA (/Applications/IINA.app and its preferences domain com.colliderli.iina) is
# not changed by the IINA RAW work. Stock IINA updates itself and writes preferences such as
# SULastCheckTime, so the default mode asserts lasting facts only:
#   (a) the stock bundle id is still com.colliderli.iina,
#   (b) the stock preferences dump has no iina-raw or alperkaganavci string,
#   (c) the stock Info.plist still declares its own document types (none of ours).
# STRICT_STOCK=1 adds the exact comparison with the baseline in testdata/stock-iina-baseline/
# (git-ignored; sha256.txt and defaults-dump.txt). It fails after a normal stock update.
check_stock_iina_untouched() {
    local app=/Applications/IINA.app id
    need_file "$app/Contents/Info.plist" || return 1
    id="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)"
    if [ "$id" != "com.colliderli.iina" ]; then
        echo "stock IINA bundle id is '$id', expected com.colliderli.iina"
        return 1
    fi
    defaults read com.colliderli.iina 2>&1 | sort >"$WORK/stock-defaults.txt"
    if grep -Eiq 'iina-raw|alperkaganavci' "$WORK/stock-defaults.txt"; then
        echo "defaults of com.colliderli.iina mention iina-raw or alperkaganavci"
        return 1
    fi
    python3 -I - "$app/Contents/Info.plist" <<'PYEOF' || return 1
import plistlib, sys

info = plistlib.load(open(sys.argv[1], "rb"))
types = info.get("CFBundleDocumentTypes", [])
if not types:
    print("stock Info.plist declares no document types")
    sys.exit(1)
text = repr(info).lower()
if "iina-raw" in text or "alperkaganavci" in text:
    print("stock Info.plist mentions iina-raw or alperkaganavci")
    sys.exit(1)
if len(types) < 3:
    print("stock Info.plist has only %d document types; expected its own long list" % len(types))
    sys.exit(1)
PYEOF
    if [ "${STRICT_STOCK:-0}" = 1 ]; then
        local base="${STOCK_BASELINE:-$ROOT/testdata/stock-iina-baseline}"
        need_file "$base/sha256.txt" || return 1
        need_file "$base/defaults-dump.txt" || return 1
        local out
        if ! out="$(shasum -a 256 -c "$base/sha256.txt" 2>&1)"; then
            echo "stock IINA file hash changed: $(echo "$out" | grep -v ': OK$' | head -n 2 | tr '\n' ' ')"
            return 1
        fi
        if ! diff -q "$base/defaults-dump.txt" "$WORK/stock-defaults.txt" >/dev/null; then
            echo "defaults of com.colliderli.iina changed: $(diff "$base/defaults-dump.txt" "$WORK/stock-defaults.txt" | head -n 3 | tr '\n' ' ')"
            return 1
        fi
    fi
}

# IINA RAW: the Quick Look extension inside the app and the document icon. The extension is
# RawThumbnail.appex in Contents/PlugIns with bundle id com.alperkaganavci.iina-raw.thumbnail,
# supports exactly the two clip UTIs, is sandboxed, passes codesign, and every @rpath library of
# its binary exists in the app's Contents/Frameworks (no second copy of the dylibs). Both document
# types use the generic video document icon (doc_other_v), and the two clip types do not conform
# to public.movie or public.audiovisual-content (macOS sends those types to its own secure
# extensions and never asks a third-party extension).
check_ql_extension_bundle() {
    local app="${IINA_RAW_APP:-/Applications/IINA RAW.app}"
    local appex="$app/Contents/PlugIns/RawThumbnail.appex"
    need_file "$appex/Contents/Info.plist" || return 1
    need_file "$appex/Contents/MacOS/RawThumbnail" || return 1
    python3 -I - "$app/Contents/Info.plist" "$appex/Contents/Info.plist" <<'PYEOF' || return 1
import plistlib, sys

app = plistlib.load(open(sys.argv[1], "rb"))
ext = plistlib.load(open(sys.argv[2], "rb"))


def fail(msg):
    print(msg)
    sys.exit(1)


if ext.get("CFBundleIdentifier") != "com.alperkaganavci.iina-raw.thumbnail":
    fail("extension bundle id is %r" % ext.get("CFBundleIdentifier"))
ns = ext.get("NSExtension", {})
if ns.get("NSExtensionPointIdentifier") != "com.apple.quicklook.thumbnail":
    fail("extension point is %r" % ns.get("NSExtensionPointIdentifier"))
types = ns.get("NSExtensionAttributes", {}).get("QLSupportedContentTypes")
if sorted(types or []) != ["com.alperkaganavci.nev", "com.alperkaganavci.r3d"]:
    fail("QLSupportedContentTypes is %r" % types)
if ns.get("NSExtensionAttributes", {}).get("QLThumbnailMinimumDimension") != 0:
    fail("QLThumbnailMinimumDimension is not 0")
for t in app.get("CFBundleDocumentTypes", []):
    if t.get("CFBundleTypeIconFile") != "doc_other_v":
        fail("document type %r has icon %r, expected doc_other_v" % (t.get("CFBundleTypeName"), t.get("CFBundleTypeIconFile")))
for d in app.get("UTImportedTypeDeclarations", []):
    bad = {"public.movie", "public.audiovisual-content", "public.video"} & set(d.get("UTTypeConformsTo", []))
    if bad:
        fail("%s conforms to %s; the thumbnail extension would never be asked" % (d.get("UTTypeIdentifier"), sorted(bad)))
    if not {"public.data", "public.content"} <= set(d.get("UTTypeConformsTo", [])):
        fail("%s must conform to public.data and public.content, has %r" % (d.get("UTTypeIdentifier"), d.get("UTTypeConformsTo")))
PYEOF
    if ! codesign --verify --deep --strict "$app" 2>"$WORK/cs.log"; then
        echo "codesign --verify --deep --strict failed: $(head -n 1 "$WORK/cs.log")"
        return 1
    fi
    # Both extensions (thumbnail and preview): sandboxed, no dylibs of their own, every @rpath
    # library of the binary exists in the app's Contents/Frameworks.
    local name ent dep missing
    for name in RawThumbnail RawPreview; do
        appex="$app/Contents/PlugIns/$name.appex"
        need_file "$appex/Contents/MacOS/$name" || return 1
        ent="$(codesign -d --entitlements :- "$appex" 2>/dev/null)"
        if ! printf '%s' "$ent" | grep -A1 'com.apple.security.app-sandbox' | grep -q '<true/>'; then
            echo "$name is not sandboxed (no com.apple.security.app-sandbox entitlement)"
            return 1
        fi
        missing=""
        while IFS= read -r dep; do
            [ -e "$app/Contents/Frameworks/${dep#@rpath/}" ] || missing="$missing $dep"
        done < <(otool -L "$appex/Contents/MacOS/$name" | awk 'NR>1 && $1 ~ /^@rpath\// {print $1}')
        if [ -n "$missing" ]; then
            echo "@rpath libraries of $name missing from Contents/Frameworks:$missing"
            return 1
        fi
        if [ -n "$(find "$appex" -name '*.dylib' 2>/dev/null)" ]; then
            echo "$name contains its own dylibs; it must use the app's Contents/Frameworks"
            return 1
        fi
    done
}

# IINA RAW: the frame grabber (RawFrameGrabber/ in the IINA RAW checkout, shared by the Quick Look
# extensions) decodes one frame of the clip through the dylibs in its deps/lib. The check
# compiles tests/frame_grabber_test/main.swift with the grabber sources, runs it on the clip and
# requires: long side 512 and 16:9, mean luminance 5 %..95 %, info = 3030x1705 half view with ISO
# and white balance present, a non-raw file gives an error. IINA_RAW_SRC is the IINA RAW checkout.
check_frame_grabber() {
    local src="${IINA_RAW_SRC:-}" gdir
    need_iina_raw_src || return 1
    gdir="$src/RawFrameGrabber"
    need_file "$gdir/RawFrameGrabber.swift" || return 1
    need_file "$gdir/rawframe.c" || return 1
    need_file "$CLIP" || return 1
    mkdir -p "$WORK/fg"
    if ! clang -c -O2 -I"$src/deps/include" "$gdir/rawframe.c" -o "$WORK/fg/rawframe.o" 2>"$WORK/fg/clang.log"; then
        echo "clang failed: $(head -n 3 "$WORK/fg/clang.log" | tr '\n' ' ')"
        return 1
    fi
    if ! swiftc -O -import-objc-header "$gdir/RawFrameGrabber-Bridging-Header.h" -I "$gdir" \
        "$gdir/RawFrameGrabber.swift" "$ROOT/tests/frame_grabber_test/main.swift" "$WORK/fg/rawframe.o" \
        -L "$src/deps/lib" -Xlinker -rpath -Xlinker "$src/deps/lib" \
        "$src/deps/lib/libavformat.63.dylib" "$src/deps/lib/libavcodec.63.dylib" \
        "$src/deps/lib/libavutil.61.dylib" "$src/deps/lib/libswscale.10.dylib" \
        -o "$WORK/fg/frame_grabber_test" 2>"$WORK/fg/swiftc.log"; then
        echo "swiftc failed: $(grep -m3 'error' "$WORK/fg/swiftc.log" | tr '\n' ' ')"
        return 1
    fi
    local out
    if ! out="$(run_limited 1 "$WORK/fg/frame_grabber_test" "$CLIP" 512 0.1 2>&1)"; then
        echo "frame_grabber_test failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
        return 1
    fi
    echo "$out" >&2
    python3 -I - "$out" <<'PYEOF' || return 1
import re, sys

text = sys.argv[1]


def fail(msg):
    print(msg)
    sys.exit(1)


m = re.search(r"grab (\d+)x(\d+) mean ([\d.]+)% in ([\d.]+) s", text)
if not m:
    fail("no grab line: %r" % text[:200])
w, h, mean = int(m.group(1)), int(m.group(2)), float(m.group(3))
if max(w, h) != 512:
    fail("grabbed %dx%d, expected a long side of 512" % (w, h))
if not 1.70 <= w / h <= 1.85:
    fail("grabbed %dx%d is not 16:9" % (w, h))
if not 5.0 < mean < 95.0:
    fail("mean luminance %.1f %% is outside 5..95 %%" % mean)
m = re.search(r"info (\d+)x(\d+) fps ([\d.]+) duration ([\d.]+) s codec '([^']*)' iso (\S+) wb (\S+)", text)
if not m:
    fail("no info line: %r" % text[:300])
iw, ih = int(m.group(1)), int(m.group(2))
if (iw, ih) != (3030, 1705):
    fail("info size %dx%d, expected the 3030x1705 half view" % (iw, ih))
if float(m.group(3)) < 1 or float(m.group(4)) <= 0:
    fail("fps or duration missing: %s" % m.group(0))
if m.group(6) == "none" or m.group(7) == "none":
    fail("ISO or white balance missing: %s" % m.group(0))
if "not-raw-file-error true" not in text:
    fail("a file that is not a raw clip gave no error")
PYEOF
}

# IINA RAW: Finder thumbnails for the clips come from the Quick Look thumbnail extension
# (com.alperkaganavci.iina-raw.thumbnail, embedded in the installed app). Checks:
#   (a) pluginkit lists the extension and it is enabled (the line starts with "+"),
#   (b) "qlmanage -t -s 512" writes a PNG with long side 512, 16:9 (the clip's own aspect, so
#       a square generic document icon fails) and a mean luminance between 5 % and 95 %,
#   (c) the thumbnail takes less than 3 s wall clock.
# When qlmanage -t gives no PNG within 15 s (it hangs without a window server), the check asks
# QLThumbnailGenerator for the same thumbnail (tests/ql_thumbnail_test/main.swift) and says so.
# Numbers only: no image is opened or shown. IINA_RAW_QL_ID overrides the extension id.
check_ql_thumbnail() {
    local id="${IINA_RAW_QL_ID:-com.alperkaganavci.iina-raw.thumbnail}" pk
    need_file "$CLIP" || return 1
    # The enabled extension must be the one inside /Applications/IINA RAW.app (not a build folder copy).
    local appex="${IINA_RAW_APPEX:-/Applications/IINA RAW.app/Contents/PlugIns/RawThumbnail.appex}"
    pk="$(pluginkit -m -v -i "$id" 2>&1)"
    if ! printf '%s\n' "$pk" | grep -q "$id"; then
        echo "pluginkit does not list $id"
        return 1
    fi
    if ! printf '%s\n' "$pk" | grep -F "$appex" | grep -q '^ *+'; then
        echo "pluginkit does not list an enabled $id at $appex: $(printf '%s' "$pk" | grep "$id" | head -n 1 | cut -c1-200)"
        return 1
    fi
    # A thumbnail may come from the Quick Look cache, so ask for one of a clone of the clip
    # with a name that was never used (APFS clone: no data is copied). It is deleted after.
    local clone="$WORK/clone/clip-$$-$RANDOM.R3D"
    mkdir -p "$WORK/clone" "$WORK/ql"
    rm -f "${WORK:?}"/ql/* 2>/dev/null
    # Delete the clone when the check is interrupted (the EXIT trap of the script removes $WORK too).
    trap "rm -f '$clone'; exit 130" INT TERM HUP
    if ! cp -c "$CLIP" "$clone" 2>/dev/null && ! cp "$CLIP" "$clone"; then
        echo "cannot make a copy of $CLIP in $WORK/clone"
        rm -f "$clone"
        trap - INT TERM HUP
        return 1
    fi
    python3 -I - "$clone" "$WORK/ql" "$ROOT" <<'PYEOF'
import glob, os, struct, subprocess, sys, time

clip, outdir, root = sys.argv[1], sys.argv[2], sys.argv[3]
QLMANAGE_LIMIT = 15


method = "qlmanage -t"
elapsed = 0.0


def fail(msg):  # the reason goes to stdout, where decoder_checks.sh collects it
    print("[%s, %.2f s] %s" % (method, elapsed, msg))
    sys.exit(1)


t0 = time.monotonic()
try:
    run = subprocess.run(["qlmanage", "-t", "-s", "512", "-o", outdir, clip],
                         capture_output=True, text=True, timeout=QLMANAGE_LIMIT)
    rc, msg = run.returncode, (run.stdout + run.stderr).strip()[:200]
except subprocess.TimeoutExpired:
    rc, msg = -1, "no answer within %d s" % QLMANAGE_LIMIT
elapsed = time.monotonic() - t0
pngs = sorted(glob.glob(os.path.join(outdir, "*.png")))
if rc != 0 or not pngs:
    # qlmanage -t can hang when there is no window server. The same service that Finder
    # uses (QLThumbnailGenerator, thumbnail only, no generic icon) is the fallback.
    print("note: qlmanage -t gave no PNG (rc=%d: %s); using QLThumbnailGenerator" % (rc, msg), file=sys.stderr)
    method = "QLThumbnailGenerator"
    helper_src = os.path.join(root, "tests", "ql_thumbnail_test", "main.swift")
    helper = os.path.join(outdir, "ql_thumbnail_test")
    c = subprocess.run(["swiftc", "-O", helper_src, "-o", helper], capture_output=True, text=True, timeout=300)
    if c.returncode != 0:
        fail("swiftc failed for the thumbnail helper: %s" % c.stderr.strip()[:200])
    png = os.path.join(outdir, "helper.png")
    t0 = time.monotonic()
    r = subprocess.run([helper, clip, "512", png], capture_output=True, text=True, timeout=60)
    elapsed = time.monotonic() - t0
    if r.returncode != 0 or not os.path.exists(png):
        fail("no thumbnail from the extension: %s" % (r.stdout + r.stderr).strip()[:200])
else:
    png = pngs[0]


def sips(*args):
    r = subprocess.run(["sips", *args], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        fail("sips failed: %s" % r.stderr.strip()[:200])
    return r.stdout


out = sips("-g", "pixelWidth", "-g", "pixelHeight", png)
vals = {l.split(":")[0].strip(): int(l.split(":")[1]) for l in out.splitlines() if ":" in l}
w, h = vals["pixelWidth"], vals["pixelHeight"]
if max(w, h) != 512:
    fail("thumbnail is %dx%d, expected a long side of 512" % (w, h))
if not 1.70 <= w / h <= 1.85:
    fail("thumbnail is %dx%d (aspect %.2f), expected about 16:9 (a generic icon is square)" % (w, h, w / h))
bmp = os.path.join(outdir, "t.bmp")
sips("-s", "format", "bmp", png, "--out", bmp)
d = open(bmp, "rb").read()
off = struct.unpack_from("<I", d, 10)[0]
bw, bh = struct.unpack_from("<ii", d, 18)
bpp = struct.unpack_from("<H", d, 28)[0]
if bpp not in (24, 32):
    fail("unexpected BMP depth %d" % bpp)
stride = ((abs(bw) * bpp + 31) // 32) * 4
total = 0.0
count = 0
for y in range(abs(bh)):
    row = off + y * stride
    for x in range(abs(bw)):
        b, g, r = d[row + x * bpp // 8: row + x * bpp // 8 + 3]
        total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        count += 1
mean = total / count / 255.0
if not 0.05 < mean < 0.95:
    fail("mean luminance %.1f %% is outside 5 %%..95 %% (blank or black picture)" % (mean * 100))
if elapsed >= 3.0:
    fail("thumbnail took %.2f s, expected under 3 s" % elapsed)
# On success the line goes to stdout; main() prints it after PASS.
print("%s: %dx%d, mean luminance %.1f %%, %.2f s, uncached clone" % (method, w, h, mean * 100, elapsed))
PYEOF
    local rc=$?
    rm -f "$clone"
    trap - INT TERM HUP
    return $rc
}

# IINA RAW: the Quick Look preview extension (space bar in Finder), RawPreview.appex.
# (a) pluginkit lists com.alperkaganavci.iina-raw.preview enabled at /Applications/IINA RAW.app,
# (b) the clip's content type (com.alperkaganavci.r3d, from the filename extension) is in the
#     QLSupportedContentTypes of the extension as LaunchServices has registered it (lsregister
#     dump) and in the extension's own Info.plist,
# (c) a command-line program (tools/rawframe_probe/main.swift) that compiles the same grabber
#     sources as the extension prints the info line and the image size: 1920x1080 for the test
#     clip, and the line "3030×1705 · 25 fps · 00:33 · ISO 6400 · TICO RAW" (duration 32.76 s,
#     frame size of the half view). Nothing is shown; numbers only.
check_ql_preview() {
    local id="${IINA_RAW_PREVIEW_ID:-com.alperkaganavci.iina-raw.preview}" pk
    local appex="${IINA_RAW_PREVIEW_APPEX:-/Applications/IINA RAW.app/Contents/PlugIns/RawPreview.appex}"
    need_file "$CLIP" || return 1
    pk="$(pluginkit -m -v -i "$id" 2>&1)"
    if ! printf '%s\n' "$pk" | grep -F "$appex" | grep -q '^ *+'; then
        echo "pluginkit does not list an enabled $id at $appex: $(printf '%s' "$pk" | head -n 1 | cut -c1-200)"
        return 1
    fi
    local uti
    uti="$(swift - "$CLIP" 2>/dev/null <<'SWIFTEOF'
import Foundation
import UniformTypeIdentifiers
let ext = URL(fileURLWithPath: CommandLine.arguments[1]).pathExtension
print(UTType(filenameExtension: ext)?.identifier ?? "none")
SWIFTEOF
)"
    if [ "$uti" != "com.alperkaganavci.r3d" ]; then
        echo "the clip's content type is '$uti', expected com.alperkaganavci.r3d"
        return 1
    fi
    python3 -I - "$appex/Contents/Info.plist" "$uti" <<'PYEOF' || return 1
import plistlib, sys

info = plistlib.load(open(sys.argv[1], "rb"))
ns = info.get("NSExtension", {})
if ns.get("NSExtensionPointIdentifier") != "com.apple.quicklook.preview":
    print("extension point is %r, expected com.apple.quicklook.preview" % ns.get("NSExtensionPointIdentifier"))
    sys.exit(1)
types = ns.get("NSExtensionAttributes", {}).get("QLSupportedContentTypes", [])
if sys.argv[2] not in types or sorted(types) != ["com.alperkaganavci.nev", "com.alperkaganavci.r3d"]:
    print("QLSupportedContentTypes of the extension is %r" % types)
    sys.exit(1)
PYEOF
    local lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$lsreg" -dump 2>/dev/null | awk -v id="$id" '
        /^identifier: / { cur = $2 }
        cur == id && /QLSupportedContentTypes/ { grab = 1; next }
        grab && /\)/ { grab = 0 }
        grab && cur == id { gsub(/[ ",]/, ""); print }' | sort -u >"$WORK/preview-types.txt"
    if ! grep -qx "$uti" "$WORK/preview-types.txt"; then
        echo "LaunchServices has not registered $uti for $id (registered: $(tr '\n' ' ' <"$WORK/preview-types.txt"))"
        return 1
    fi
    build_grabber_tool "$ROOT/tools/rawframe_probe/main.swift" "$WORK/probe" || return 1
    local out
    if ! out="$(run_limited 1 "$WORK/probe" "$CLIP" preview 2>/dev/null)"; then
        echo "rawframe_probe failed: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"
        return 1
    fi
    printf '%s\n' "$out" >&2
    # Damaged values (inf, NaN, negative, huge) must not trap the info line formatting; the
    # damaged fields are left out.
    local fmt
    if ! fmt="$(run_limited 1 "$WORK/probe" "$CLIP" format 2>&1)"; then
        echo "rawframe_probe format crashed (rc $?): $(printf '%s' "$fmt" | tail -n 2 | tr '\n' ' ')"
        return 1
    fi
    out="$out
$fmt"
    # The scaling guard: frames of changing size and pixel format go through one scaler without
    # writing past the picture, and empty or format-less frames are refused (code-level test of
    # rawframe_selftest_scale; a real clip with a changing frame size is hard to make).
    local guard
    if ! guard="$(run_limited 1 "$WORK/probe" "$CLIP" selftest 2>&1)" || [ "$guard" != "selftest: ok" ]; then
        echo "scaling guard selftest failed: $(printf '%s' "$guard" | tail -n 2 | tr '\n' ' ')"
        return 1
    fi
    python3 -I - "$out" <<'PYEOF'
import re, sys

text = sys.argv[1]
m = re.search(r"^info-line: (.*)$", text, re.M)
if not m:
    print("no info-line in the probe output")
    sys.exit(1)
want = "3030×1705 · 25 fps · 00:33 · ISO 6400 · TICO RAW"
if m.group(1) != want:
    print("info line is %r, expected %r" % (m.group(1), want))
    sys.exit(1)
bare = "3030\u00d71705 \u00b7 TICO RAW"
for value in ("inf", "-inf", "nan", "-1.0", "0.0", "1e+300", "86400.0", "1e+19", "fps0.0004"):
    m = re.search(r"^format %s: (.*)$" % re.escape(value), text, re.M)
    if not m or m.group(1) != bare:
        print("format %s gave %r, expected %r" % (value, m.group(1) if m else None, bare))
        sys.exit(1)
m = re.search(r"^format ok: (.*)$", text, re.M)
if not m or m.group(1) != "3030\u00d71705 \u00b7 23.976 fps \u00b7 00:33 \u00b7 ISO 800 \u00b7 TICO RAW":
    print("format ok line is %r" % (m.group(1) if m else None))
    sys.exit(1)
m = re.search(r"^image: (\d+)x(\d+)$", text, re.M)
if not m or (int(m.group(1)), int(m.group(2))) != (1920, 1080):
    print("image size is %r, expected 1920x1080" % (m.group(0) if m else None))
    sys.exit(1)
m = re.search(r"^duration: ([\d.]+)$", text, re.M)
if not m or not 32.5 <= float(m.group(1)) <= 33.0:
    print("duration is %r, expected about 32.8 s" % (m.group(0) if m else None))
    sys.exit(1)
PYEOF
}

# IINA RAW: version 2 of the preview, playback. tools/preview_harness/main.swift runs the real
# view controller of RawPreview.appex (RawPreview/PreviewViewController.swift, compiled in) in a
# window that is never shown for 5 s, and counts the frames it puts on the display layer. It
# requires: preparePreviewOfFile is ok with the info line, at least 20 frames per second, the
# display layer is not failed, the video is visible, playback stops when the preview closes
# (no frame after viewWillDisappear), and the resident memory of the process is below 600 MB.
# Then the controller reuse tests of the harness (reuse, stale, close, failed, pause) must all
# print "<name>: ok": a second prepare on the same controller shows no frame of the first clip, an
# older request's result is dropped, one loop at most runs, a close before the still decoded
# leaves 0 loops, a failed clip shows the still frame, and the pause hook stops the decoding.
check_ql_preview_playback() {
    local src="${IINA_RAW_SRC:-}" out
    need_iina_raw_src || return 1
    need_file "$CLIP" || return 1
    need_file "$src/RawPreview/PreviewViewController.swift" || return 1
    build_grabber_tool "$ROOT/tools/preview_harness/main.swift" "$WORK/preview_harness" "$src/RawPreview/PreviewViewController.swift" || return 1
    if ! out="$(run_limited 5 "$WORK/preview_harness" "$CLIP" 5 2>&1)"; then
        echo "preview_harness failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
        return 1
    fi
    printf '%s\n' "$out" >&2
    python3 -I - "$out" <<'PYEOF'
import re, sys

text = sys.argv[1]


def fail(msg):
    print(msg)
    sys.exit(1)


if "info: 3030×1705 · 25 fps · 00:33 · ISO 6400 · TICO RAW" not in text:
    fail("prepare line or info line is wrong: %r" % text[:200])
m = re.search(r"played: (\d+) frames in ([\d.]+) s = ([\d.]+) fps \| layer status: (\d+) .*video visible: (\w+)", text)
if not m:
    fail("no played line: %r" % text[:300])
fps, status, visible = float(m.group(3)), int(m.group(4)), m.group(5)
if fps < 20.0:
    fail("playback is %.1f fps, expected at least 20" % fps)
if status == 2:
    fail("the display layer failed")
if visible != "yes":
    fail("the video is not visible after 5 s")
if "stopped=true" not in text:
    fail("frames were still shown after the preview closed")
for name in ("reuse", "stale", "close", "failed", "pause"):
    if "\n%s: ok" % name not in text:
        reason = [l for l in text.splitlines() if l.startswith(name + ": FAIL")]
        fail("controller reuse test '%s' did not pass: %s" % (name, "; ".join(reason) or "no result line"))
if "reuse-tests: ok" not in text:
    fail("reuse tests failed")
m = re.search(r"rss: (\d+) MB", text)
if not m or int(m.group(1)) >= 600:
    fail("resident memory %s MB, expected under 600" % (m.group(1) if m else "?"))
print("%.1f fps, %s MB, stops on close" % (fps, m.group(1)))
PYEOF
}

all_checks() {
    declare -F | awk '{print $3}' | grep '^check_' | sort
}

main() {
    if [ $# -eq 0 ]; then
        echo "usage: $0 <check>... | all" >&2
        echo "checks: $(all_checks | sed 's/^check_//' | tr '\n' ' ')" >&2
        return 2
    fi
    local names=() arg
    for arg in "$@"; do
        if [ "$arg" = all ]; then
            while IFS= read -r arg; do names+=("$arg"); done < <(all_checks)
        else
            names+=("check_${arg#check_}")
        fi
    done
    local name reason failed=0
    for name in "${names[@]}"; do
        if ! declare -F "$name" >/dev/null; then
            echo "FAIL $name: no such check"
            failed=1
            continue
        fi
        if reason="$("$name")"; then
            echo "PASS $name${reason:+: $reason}"
        else
            echo "FAIL $name: ${reason:-no reason given}"
            failed=1
        fi
    done
    return $failed
}

main "$@"
