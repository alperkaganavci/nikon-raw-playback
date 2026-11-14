#!/bin/sh
# Builds the TICO RAW test oracle (blue-compressor 4d35f31 as a black-box reference) and writes
# the reference stage dumps and frame JSON. The oracle is not part of the decoder.
#
# Usage: oracle/run.sh <clip> <out_dir> <frame>...
# Example: oracle/run.sh /path/to/A015_C004_0706JH.R3D testdata/ref/A015_C004 0 100 818
#
# The clip is only read. Each frame runs in its own process, so at most one frame is in
# memory (about 200 MB). Check free memory before you run this on a shared machine.
set -eu

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <clip> <out_dir> <frame>..." >&2
    exit 2
fi
clip=$1
out=$2
shift 2

here=$(cd "$(dirname "$0")" && pwd)

echo "memory: $(memory_pressure 2>/dev/null | tail -1 || echo unknown)"
cargo build --release -j 4 --manifest-path "$here/Cargo.toml"
bin="$here/target/release/ticoraw-oracle"

mkdir -p "$out"
# Keep the decoder to 4 threads unless the caller chose otherwise.
RAYON_NUM_THREADS=${RAYON_NUM_THREADS:-4}
export RAYON_NUM_THREADS
for f in "$@"; do
    "$bin" "$clip" "$out" "$f"
done
