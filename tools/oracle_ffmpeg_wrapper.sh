#!/bin/bash
# Stand-in for ffmpeg, used through BLUECOMPRESS_FFMPEG (see docs/format/tico-raw-nikon.md 12.8).
# Calls without "-i -" (encoder probes) go to the real ffmpeg.
# The call with "-i -" gets the exact P010 frames on stdin. This script saves
# the wanted frames to $ORACLE_FRAMES_DIR/pNNNN.p010, discards the rest, creates the
# empty output file (the last argument) and exits 0. No HEVC encode happens.
# Env: ORACLE_FRAMES_DIR, ORACLE_FRAMES (e.g. "0 100 818"), ORACLE_FRAME_SIZE (e.g. 1920x1080).
set -euo pipefail
REAL=${ORACLE_REAL_FFMPEG:-/opt/homebrew/bin/ffmpeg}
args=("$@")
capture=0
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
    if [ "${args[i]}" = "-i" ] && [ "${args[i+1]}" = "-" ]; then capture=1; fi
done
if [ "$capture" = 0 ]; then exec "$REAL" "$@"; fi

last=${args[${#args[@]}-1]}
PYCODE=$(cat <<'PY'
import sys
d, frames, size, out = sys.argv[1:5]
w, h = (int(x) for x in size.split("x"))
fs = w * h * 3
want = {int(x) for x in frames.split()}
stdin = sys.stdin.buffer
n = 0
while True:
    buf = bytearray()
    while len(buf) < fs:
        c = stdin.read(fs - len(buf))
        if not c:
            break
        buf += c
    if len(buf) == 0:
        break
    if len(buf) < fs:
        sys.exit("short frame %d: %d of %d bytes" % (n, len(buf), fs))
    if n in want:
        with open("%s/p%04d.p010" % (d, n), "wb") as f:
            f.write(buf)
    n += 1
open(out, "wb").close()
sys.stderr.write("wrapper: read %d frames\n" % n)
PY
)
exec python3 -I -c "$PYCODE" "$ORACLE_FRAMES_DIR" "$ORACLE_FRAMES" "$ORACLE_FRAME_SIZE" "$last"
