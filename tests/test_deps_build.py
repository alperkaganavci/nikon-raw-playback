#!/usr/bin/env python3
"""Check that IINA's own FFmpeg build (deps-buildscripts) contains the tico_raw decoder.

Python 3 standard library only. Loads the FFmpeg dylibs with ctypes, then checks:
  1. libavcodec has a decoder named "tico_raw".
  2. libavformat opens the test clip and picks that same decoder for its video
     stream (the mov demuxer maps the NR3D / NRAW fourcc to tico_raw).

The check avoids hand-written struct offsets: the decoder comes from
av_find_best_stream(), and it is compared with avcodec_find_decoder_by_name().

Environment:
  IINA_DEPS  checkout of iina/deps-buildscripts after the build (required; build/build-iina-raw.sh
             makes it at build/work/deps-buildscripts)
  CLIP       test clip (required): the path of a Nikon ZR .R3D clip

Library folders tried, in this order: <IINA_DEPS>/output/arm64 (after
fix-install-names.sh), then <IINA_DEPS>/install/arm64/lib (the install prefix).

Usage: python3 tests/test_deps_build.py
Exit status 0 means PASS, 1 means FAIL.
"""

import ctypes
import glob
import os
import re
import sys

IINA_DEPS = os.path.expanduser(os.environ.get("IINA_DEPS", ""))
CLIP = os.environ.get("CLIP", "")
if not IINA_DEPS:
    sys.exit("set IINA_DEPS to the deps-buildscripts checkout, for example IINA_DEPS=build/work/deps-buildscripts")
if not CLIP:
    sys.exit("set CLIP to the path of a Nikon ZR .R3D test clip")
LIB_DIRS = [
    os.path.join(IINA_DEPS, "output", "arm64"),
    os.path.join(IINA_DEPS, "install", "arm64", "lib"),
]
AVMEDIA_TYPE_VIDEO = 0


def fail(msg):
    print("FAIL test_deps_build: " + msg)
    sys.exit(1)


def find_lib_dir():
    """First folder that holds a libavcodec dylib."""
    for d in LIB_DIRS:
        if glob.glob(os.path.join(d, "libavcodec.*.dylib")):
            return d
    fail("no libavcodec dylib in " + " or ".join(LIB_DIRS)
         + " (run ./build.sh arm64 and ./fix-install-names.sh arm64 in " + IINA_DEPS + ")")


def real_files(lib_dir, name):
    """Real (non-symlink) files libNAME.<digits>*.dylib in lib_dir."""
    out = []
    for p in sorted(glob.glob(os.path.join(lib_dir, "lib%s.*.dylib" % name))):
        if re.fullmatch(r"lib%s\.\d+(\.\d+\.\d+)?\.dylib" % re.escape(name), os.path.basename(p)):
            out.append(p)
    return out


def preload_all(lib_dir):
    """dlopen every dylib in the folder, so @rpath dependencies resolve by install name.

    A dylib can depend on another one in the same folder through @rpath. Loading in a
    retry loop gives dependencies first without a hand-written order.
    """
    pending = [p for p in sorted(glob.glob(os.path.join(lib_dir, "*.dylib"))) if not os.path.islink(p)]
    loaded = {}
    last_err = {}
    while pending:
        progress = False
        for p in list(pending):
            try:
                loaded[p] = ctypes.CDLL(p)
            except OSError as e:
                last_err[p] = str(e)
                continue
            pending.remove(p)
            progress = True
        if not progress:
            break
    return loaded, {p: last_err.get(p, "") for p in pending}


def pick(loaded, lib_dir, name):
    for p in real_files(lib_dir, name):
        if p in loaded:
            return loaded[p]
    fail("lib%s dylib not found or not loadable in %s" % (name, lib_dir))


def main():
    lib_dir = find_lib_dir()
    loaded, unloadable = preload_all(lib_dir)
    avcodec = pick(loaded, lib_dir, "avcodec")
    avformat = pick(loaded, lib_dir, "avformat")
    print("test_deps_build: library folder %s (%d dylibs loaded, %d not loadable)"
          % (lib_dir, len(loaded), len(unloadable)))

    # 1. The decoder exists in libavcodec.
    avcodec.avcodec_find_decoder_by_name.restype = ctypes.c_void_p
    avcodec.avcodec_find_decoder_by_name.argtypes = [ctypes.c_char_p]
    tico = avcodec.avcodec_find_decoder_by_name(b"tico_raw")
    if not tico:
        fail('avcodec_find_decoder_by_name(b"tico_raw") returned NULL')
    print("PASS tico_raw decoder is in libavcodec")

    # 2. libavformat maps the clip's fourcc to that decoder.
    if not os.path.isfile(CLIP):
        fail("test clip not found: " + CLIP)
    avformat.avformat_open_input.restype = ctypes.c_int
    avformat.avformat_open_input.argtypes = [
        ctypes.POINTER(ctypes.c_void_p), ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
    avformat.avformat_find_stream_info.restype = ctypes.c_int
    avformat.avformat_find_stream_info.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    avformat.av_find_best_stream.restype = ctypes.c_int
    avformat.av_find_best_stream.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(ctypes.c_void_p), ctypes.c_int]
    avformat.avformat_close_input.restype = None
    avformat.avformat_close_input.argtypes = [ctypes.POINTER(ctypes.c_void_p)]

    fmt = ctypes.c_void_p(None)
    ret = avformat.avformat_open_input(ctypes.byref(fmt), CLIP.encode(), None, None)
    if ret < 0:
        fail("avformat_open_input returned %d for %s" % (ret, CLIP))
    try:
        ret = avformat.avformat_find_stream_info(fmt, None)
        if ret < 0:
            fail("avformat_find_stream_info returned %d" % ret)
        decoder = ctypes.c_void_p(None)
        idx = avformat.av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, ctypes.byref(decoder), 0)
        if idx < 0:
            fail("av_find_best_stream found no video stream with a decoder (%d)" % idx)
        if decoder.value != tico:
            fail("video stream %d decoder is not tico_raw (pointer %s, expected %s)"
                 % (idx, hex(decoder.value or 0), hex(tico)))
        print("PASS video stream %d of the clip uses the tico_raw decoder" % idx)
    finally:
        avformat.avformat_close_input(ctypes.byref(fmt))

    print("PASS test_deps_build")


if __name__ == "__main__":
    main()
