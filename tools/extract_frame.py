#!/usr/bin/env python3
"""Extract the bytes of one video sample (frame) from an R3D / N-RAW clip.

usage: extract_frame.py <clip> <index> <out.bin>

The packet offset and size come from `ffprobe -show_packets -select_streams v:0`.
The sample is copied byte for byte (Nikon wrapper plus codestream).
"""
import json
import os
import subprocess
import sys

FFPROBE = os.environ.get("FFPROBE", "/opt/homebrew/bin/ffprobe")
if not os.path.exists(FFPROBE):
    FFPROBE = "ffprobe"
CHUNK = 1 << 20


def packet_location(clip, index):
    cmd = [FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_packets",
           "-show_entries", "packet=pos,size", "-of", "json", clip]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("ffprobe failed: " + r.stderr.strip())
    packets = json.loads(r.stdout).get("packets", [])
    if not 0 <= index < len(packets):
        raise IndexError("frame index %d out of range (clip has %d video packets)"
                         % (index, len(packets)))
    p = packets[index]
    return int(p["pos"]), int(p["size"])


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    clip, index_s, out = argv[1:]
    try:
        index = int(index_s)
        pos, size = packet_location(clip, index)
        remaining = size
        with open(clip, "rb") as src, open(out, "wb") as dst:
            src.seek(pos)
            while remaining:
                buf = src.read(min(CHUNK, remaining))
                if not buf:
                    raise EOFError("clip ends %d bytes before the end of frame %d"
                                   % (remaining, index))
                dst.write(buf)
                remaining -= len(buf)
    except (ValueError, RuntimeError, IndexError, EOFError, OSError) as e:
        if os.path.exists(out) and not isinstance(e, OSError):
            os.remove(out)
        print("extract_frame: %s" % e, file=sys.stderr)
        return 1
    print("frame %d: pos=%d size=%d -> %s" % (index, pos, size, out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
