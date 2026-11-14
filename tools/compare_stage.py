#!/usr/bin/env python3
"""Compare a decoder stage dump with a reference dump, or two frame JSON files.

Binary mode:
  compare_stage.py <ours> <ref> --dtype int32|uint16 --planes N --width W --height H
                   [--tolerance T] [--rows-from Y] [--cols-from X]
  Exit 0 when every sample differs by at most T (default 0), else exit 1 and print
  the mismatch count and the first mismatch as `plane=P x=X y=Y ours=A ref=B`.
  Files are little-endian, planes concatenated, each plane W x H, row-major.
  --rows-from Y ignores rows above Y in every plane.
  --cols-from X ignores columns left of X in every row of every plane. It combines with
  --rows-from. The x in a reported mismatch is always the absolute column.

JSON mode:
  compare_stage.py --json <ours.json> <ref.json> --section meta|header
  Numbers compare within 1e-4 (absolute); strings and list lengths compare exactly;
  missing or extra keys in the section are mismatches. Exit 0 or 1.

Exit code 2 means a usage or input error.
"""
import argparse
import array
import json
import os
import sys

CHUNK_BYTES = 8 << 20  # per-file read size; keeps peak memory small
JSON_TOL = 1e-4
TYPECODE = {"int32": "i", "uint16": "H"}


def fail_usage(msg):
    print("compare_stage: %s" % msg, file=sys.stderr)
    return 2


def to_le(arr):
    if sys.byteorder == "big":
        arr.byteswap()
    return arr


def compare_binary(args):
    code = TYPECODE[args.dtype]
    itemsize = array.array(code).itemsize
    if args.dtype == "int32" and itemsize != 4:
        return fail_usage("platform int is not 32 bits")
    plane_samples = args.width * args.height
    plane_bytes = plane_samples * itemsize
    expected = plane_bytes * args.planes
    for label, path in (("ours", args.ours), ("ref", args.ref)):
        try:
            size = os.path.getsize(path)
        except OSError as e:
            return fail_usage("%s: %s" % (label, e))
        if size != expected:
            print("size mismatch: %s has %d bytes, expected %d (%d planes of %dx%d %s)"
                  % (label, size, expected, args.planes, args.width, args.height, args.dtype))
            return 1
    if not 0 <= args.rows_from <= args.height:
        return fail_usage("--rows-from must be within 0..height")
    if not 0 <= args.cols_from <= args.width:
        return fail_usage("--cols-from must be within 0..width")

    count = 0
    first = None
    skip_bytes = args.rows_from * args.width * itemsize
    # whole rows per chunk so the chunk start is always row aligned
    rows_per_chunk = max(1, CHUNK_BYTES // (args.width * itemsize))
    row_bytes = args.width * itemsize
    cut = args.cols_from * itemsize  # bytes dropped at the start of each row
    kept_width = args.width - args.cols_from
    with open(args.ours, "rb") as fo, open(args.ref, "rb") as fr:
        for plane in range(args.planes):
            base = plane * plane_bytes
            fo.seek(base + skip_bytes)
            fr.seek(base + skip_bytes)
            row = args.rows_from
            while row < args.height:
                n_rows = min(rows_per_chunk, args.height - row)
                bo = fo.read(n_rows * row_bytes)
                br = fr.read(n_rows * row_bytes)
                if len(bo) != len(br) or len(bo) != n_rows * row_bytes:
                    return fail_usage("short read")
                if kept_width == 0:  # --cols-from == width leaves nothing to compare
                    row += n_rows
                    continue
                if cut:  # keep only columns >= cols_from of each row
                    bo = b"".join(bo[r * row_bytes + cut:(r + 1) * row_bytes]
                                  for r in range(n_rows))
                    br = b"".join(br[r * row_bytes + cut:(r + 1) * row_bytes]
                                  for r in range(n_rows))
                if bo != br:  # fast path: equal chunks cost one memcmp
                    ao = to_le(array.array(code, bo))
                    ar = to_le(array.array(code, br))
                    for i in range(len(ao)):
                        d = ao[i] - ar[i]
                        if d > args.tolerance or -d > args.tolerance:
                            count += 1
                            if first is None:
                                y, x = divmod(i, kept_width)
                                first = (plane, x + args.cols_from, row + y, ao[i], ar[i])
                row += n_rows
    if count == 0:
        print("OK: %d plane(s) %dx%d %s equal within tolerance %d"
              % (args.planes, args.width, args.height, args.dtype, args.tolerance))
        return 0
    p, x, y, a, b = first
    print("MISMATCH: %d sample(s) differ by more than %d" % (count, args.tolerance))
    print("first: plane=%d x=%d y=%d ours=%d ref=%d" % (p, x, y, a, b))
    return 1


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def diff_json(a, b, path, out):
    if is_number(a) and is_number(b):
        if not (a == b or abs(a - b) <= JSON_TOL):
            out.append("%s: ours=%r ref=%r" % (path, a, b))
    elif isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            sub = "%s.%s" % (path, k)
            if k not in a:
                out.append("%s: missing in ours (ref=%r)" % (sub, b[k]))
            elif k not in b:
                out.append("%s: extra in ours (ours=%r)" % (sub, a[k]))
            else:
                diff_json(a[k], b[k], sub, out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append("%s: length ours=%d ref=%d" % (path, len(a), len(b)))
        else:
            for i, (x, y) in enumerate(zip(a, b)):
                diff_json(x, y, "%s[%d]" % (path, i), out)
    else:
        if type(a) is not type(b) or a != b:
            out.append("%s: ours=%r ref=%r" % (path, a, b))


def compare_json(args):
    docs = []
    for path in (args.ours, args.ref):
        try:
            with open(path, "r", encoding="utf-8") as f:
                docs.append(json.load(f))
        except (OSError, ValueError) as e:
            return fail_usage("%s: %s" % (path, e))
    secs = []
    for label, d in zip(("ours", "ref"), docs):
        if not isinstance(d, dict) or args.section not in d:
            return fail_usage("%s has no section %r" % (label, args.section))
        secs.append(d[args.section])
    out = []
    diff_json(secs[0], secs[1], args.section, out)
    if not out:
        print("OK: section %s equal" % args.section)
        return 0
    print("MISMATCH: %d difference(s) in section %s" % (len(out), args.section))
    for line in out:
        print(line)
    return 1


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ours")
    ap.add_argument("ref")
    ap.add_argument("--json", action="store_true", help="compare frame JSON files")
    ap.add_argument("--section", choices=("meta", "header"))
    ap.add_argument("--dtype", choices=sorted(TYPECODE))
    ap.add_argument("--planes", type=int)
    ap.add_argument("--width", type=int)
    ap.add_argument("--height", type=int)
    ap.add_argument("--tolerance", type=int, default=0)
    ap.add_argument("--rows-from", type=int, default=0, dest="rows_from")
    ap.add_argument("--cols-from", type=int, default=0, dest="cols_from")
    args = ap.parse_args(argv[1:])
    if args.json:
        if not args.section:
            return fail_usage("--json needs --section meta|header")
        return compare_json(args)
    for name in ("dtype", "planes", "width", "height"):
        if getattr(args, name) is None:
            return fail_usage("--%s is required in binary mode" % name)
    if min(args.planes, args.width, args.height) <= 0 or args.tolerance < 0:
        return fail_usage("planes, width, height must be positive and tolerance >= 0")
    return compare_binary(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
