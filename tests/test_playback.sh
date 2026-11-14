#!/usr/bin/env bash
# End-to-end playback checks for IINA RAW: the app's own libmpv (FFmpeg 9.0.2 + tico_raw)
# plays the test clip with the app's built-in decoder options.
#
# Usage (from the project repo root):
#   tests/test_playback.sh
# Each check prints "PASS <name>: <numbers>" or "FAIL <name>: <numbers>". Every harness JSON
# line is printed after "  json: ". The exit status is non-zero if any check failed.
# This is a heavy test (about 4 minutes): it runs one libmpv process at a time.
#
# Environment:
#   LIBMPV     libmpv inside the installed app
#              (default "/Applications/IINA RAW.app/Contents/Frameworks/libmpv.2.dylib")
#   CLIP       test clip (required): the path of a Nikon ZR .R3D clip
#   NRAW       stock N-RAW copy for the report-only run
#              (default testdata/ref/A015_C004_nraw.NEV; skipped when the file is missing)
#   SEED       seed of the 30 random seeks (default 20261114)
#   SKIP_LONG  set to 1 to skip the 120 s run
#   ONLY       run one check only: probe, play20, decode_rate, play120, seek, audio or nraw
#   MAX_SWAP_MB  refuse to start when more swap than this is used (default 8192)
#
# The harness (tests/mpv_harness.py) uses vd-lavc-threads=12 and
# vd-lavc-o=view=rec709,view_size=half,thread_type=slice unless told otherwise. These are
# the built-in defaults of IINA RAW. `tests/decoder_checks.sh iina_raw_bundle` fails when the
# default string inside the installed app differs from the harness value.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBMPV="${LIBMPV:-/Applications/IINA RAW.app/Contents/Frameworks/libmpv.2.dylib}"
CLIP="${CLIP:?set CLIP to the path of a Nikon ZR .R3D test clip}"
NRAW="${NRAW:-$ROOT/testdata/ref/A015_C004_nraw.NEV}"
SEED="${SEED:-20261114}"
MAX_SWAP_MB="${MAX_SWAP_MB:-8192}"
HARNESS="$ROOT/tests/mpv_harness.py"

FAILED=0

# ONLY=<check> runs one check only (probe, play20, decode_rate, play120, seek, audio, nraw).
CHECK_NAMES="probe play20 decode_rate play120 seek audio nraw"
want() { [ -z "${ONLY:-}" ] || [ "$ONLY" = "$1" ]; }
if [ -n "${ONLY:-}" ]; then
    case " $CHECK_NAMES " in
        *" $ONLY "*) ;;
        *) echo "FAIL ONLY: unknown check '$ONLY'; valid names: $CHECK_NAMES" >&2; exit 2 ;;
    esac
fi

pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2"; FAILED=$((FAILED + 1)); }

# harness <mode> [harness options...]: run the harness on the test clip, print the JSON line.
harness() {
    local mode="$1"
    shift
    python3 "$HARNESS" "$LIBMPV" "$CLIP" "$mode" "$@"
}

# jq_py <json> <python expression using d>: evaluate the expression on the parsed JSON.
# The expressions are written in this file only (never read from input), so eval is safe here.
jq_py() {
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

# Memory guard: this is a heavy test, so refuse to start while the machine swaps a lot.
swap_used_mb="$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/' | cut -d. -f1)"
echo "memory: $(memory_pressure | tail -1); swap used ${swap_used_mb} MB"
if [ "${swap_used_mb:-0}" -gt "$MAX_SWAP_MB" ]; then
    echo "FAIL memory_guard: swap used ${swap_used_mb} MB is above ${MAX_SWAP_MB} MB; wait and run again"
    exit 1
fi

[ -f "$HARNESS" ] || { echo "FAIL harness: missing $HARNESS"; exit 1; }
[ -f "$LIBMPV" ] || { echo "FAIL libmpv: missing $LIBMPV"; exit 1; }
[ -f "$CLIP" ] || { echo "FAIL clip: missing $CLIP"; exit 1; }

if want probe; then
    # 1. probe: decoder, size and pixel format of the half view. mpv's video-codec property is
    #    the codec's long name ("intoPIX TICO RAW ..."); video-format is the codec name tico_raw.
    out="$(harness probe)" || { fail probe "harness failed: $out"; out='{}'; }
    echo "  json: $out"
    if [ "$(jq_py "$out" "d.get('video-format')=='tico_raw' and 'TICO RAW' in str(d.get('video-codec')) and d.get('width')==3030 and d.get('height')==1705 and d.get('video-params/pixelformat')=='gbrp16'")" = "True" ]; then
        pass probe "$(jq_py "$out" "'%s (%s) %sx%s %s' % (d['video-format'], d['video-codec'], d['width'], d['height'], d['video-params/pixelformat'])")"
    else
        fail probe "expected tico_raw 3030x1705 gbrp16"
    fi
fi

if want play20; then
    # 2. play 20 s: real-time rate, no dropped frames, peak RSS.
    out="$(harness play --seconds 20)" || { fail play20 "harness failed: $out"; out='{}'; }
    echo "  json: $out"
    if [ "$(jq_py "$out" "d.get('estimated_vf_fps_mean',0)>=24.5 and d.get('achieved_fps',0)>=24.5 and d.get('decoder-frame-drop-count')==0 and d.get('frame-drop-count')==0 and d.get('peak_rss_mb',1e9)<=1536")" = "True" ]; then
        pass play20 "$(jq_py "$out" "'vf-fps mean %.2f, achieved %.2f, drops %s/%s, peak RSS %.0f MB' % (d['estimated_vf_fps_mean'], d['achieved_fps'], d['decoder-frame-drop-count'], d['frame-drop-count'], d['peak_rss_mb'])")"
    else
        fail play20 "need vf-fps >= 24.5, achieved >= 24.5, decoder-frame-drop-count 0, frame-drop-count 0, peak RSS <= 1536 MB"
    fi
fi

if want decode_rate; then
    # 3. play untimed to the end: the most the decoder and the pipeline can do.
    out="$(harness play --untimed)" || { fail decode_rate "harness failed: $out"; out='{}'; }
    echo "  json: $out"
    if [ "$(jq_py "$out" "d.get('decode_fps',0)>=25")" = "True" ]; then
        pass decode_rate "$(jq_py "$out" "'%.2f fps (%s frames in %.2f s)' % (d['decode_fps'], d['frames'], d['wall_s'])")"
    else
        fail decode_rate "need untimed decode rate >= 25 fps"
    fi
fi

if want play120; then
    # 4. play 120 s with the clip looping: RSS growth from 20 s to 120 s.
    if [ "${SKIP_LONG:-0}" = "1" ]; then
        echo "SKIP play120 (SKIP_LONG=1)"
    else
        out="$(harness play --seconds 120 --loop)" || { fail play120 "harness failed: $out"; out='{}'; }
        echo "  json: $out"
        if [ "$(jq_py "$out" "d.get('rss_growth_pct',1e9)<=10 and d.get('decoder-frame-drop-count')==0")" = "True" ]; then
            pass play120 "$(jq_py "$out" "'RSS %.0f MB at 20 s, %.0f MB at 120 s, growth %.2f %%, drops %s' % (d['rss_20s_mb'], d['rss_end_mb'], d['rss_growth_pct'], d['decoder-frame-drop-count'])")"
        else
            fail play120 "need RSS growth <= 10 % and decoder-frame-drop-count 0"
        fi
    fi
fi

if want seek; then
    # 5. seek: 30 seeks to seeded random times; time from the command to playback-restart.
    #    Rule: every seek restarted, p95 <= 200 ms and max <= 400 ms (one slow seek
    #    under load from other processes must not fail the run).
    out="$(harness seek --seed "$SEED" --seeks 30)" || { fail seek "harness failed: $out"; out='{}'; }
    echo "  json: $out"
    if [ "$(jq_py "$out" "d.get('seek_count')==30 and d.get('all_restarted') is True and d.get('p95_ms',1e9)<=200 and d.get('max_ms',1e9)<=400")" = "True" ]; then
        pass seek "$(jq_py "$out" "'seed %s, 30 seeks, all restarted, median %.1f ms, p95 %.1f ms, max %.1f ms, load average %s' % (d['seed'], d['median_ms'], d['p95_ms'], d['max_ms'], d['loadavg_1min'])")"
    else
        fail seek "need 30 seeks, every one with a playback-restart event, p95 <= 200 ms and max <= 400 ms"
    fi
fi

if want audio; then
    # 6. audio: codec and A/V sync with the null audio output.
    out="$(harness audio --seconds 10)" || { fail audio "harness failed: $out"; out='{}'; }
    echo "  json: $out"
    if [ "$(jq_py "$out" "d.get('audio-codec-name')=='pcm_f32le' and len(d.get('avsync_samples',[]))>=5 and all(abs(x)<=0.1 for x in d['avsync_samples'])")" = "True" ]; then
        pass audio "$(jq_py "$out" "'pcm_f32le, avsync samples %s' % d['avsync_samples']")"
    else
        fail audio "need audio-codec-name pcm_f32le and at least 5 avsync samples within +-0.1 s"
    fi
fi

if want nraw; then
    # 7. report only: the stock N-RAW copy (probe and 10 s play), no threshold.
    if [ -f "$NRAW" ]; then
        out="$(python3 "$HARNESS" "$LIBMPV" "$NRAW" probe)" || out="harness failed: $out"
        echo "REPORT nraw_probe: $out"
        out="$(python3 "$HARNESS" "$LIBMPV" "$NRAW" play --seconds 10)" || out="harness failed: $out"
        echo "REPORT nraw_play10: $out"
    else
        echo "SKIP nraw (missing $NRAW)"
    fi
fi

if [ "$FAILED" -eq 0 ]; then
    echo "test_playback: all checks passed"
    exit 0
fi
echo "test_playback: $FAILED check(s) failed"
exit 1
