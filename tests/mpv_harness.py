#!/usr/bin/env python3
"""libmpv playback harness for IINA RAW (Python 3 standard library only).

Usage:
  tests/mpv_harness.py <libmpv.dylib> <clip> <mode> [options]

Modes (each prints exactly one JSON line on stdout):
  probe   Load the clip, show the first frame (paused) and print video-codec, width, height,
          video-params/pixelformat and a few more properties.
  play    Play with vo=null for --seconds (default 20) and print estimated-vf-fps (mean and
          last), frame-drop-count, decoder-frame-drop-count, the achieved frame rate (frames
          per wall-clock second, from estimated-frame-number) and RSS. With --untimed
          (untimed=yes) the clip plays as fast as it decodes, to the end of the file (or
          --seconds), and decode_fps is frames / wall seconds.
  seek    Play, then do --seeks (default 30) seeks to seeded random times ("seek <t>
          absolute+exact") and print each one's time from the command to the next
          playback-restart event, and the maximum.
  audio   Play with audio=yes and ao=null for --seconds (default 10); print audio-codec-name
          and avsync samples.

Options:
  --vd-lavc-o VALUE        default: view=rec709,view_size=half,thread_type=slice
  --vd-lavc-threads N      default: 12
  --seconds S              play/audio length (default 20 for play, 10 for audio)
  --seeks N, --seed N      seek count (30) and random seed (default: current time; printed)
  --loop                   loop-file=inf (for runs longer than the clip)
  --untimed                untimed=yes (play mode)
  --pause                  seek mode: seek while paused (default: while playing)
  --set NAME=VALUE         extra mpv option before initialize (repeatable)

The defaults of --vd-lavc-o and --vd-lavc-threads are the built-in defaults of IINA RAW.
The harness loads the libmpv dylib with ctypes. The dylibs next to it use @rpath names, and a
plain Python process has no rpath to that folder, so the harness first loads every dylib of
the folder (dependencies first, by retrying) as tests/test_deps_build.py does.
"""

import argparse
import ctypes
import glob
import json
import math
import os
import random
import resource
import statistics
import subprocess
import sys
import time

# Event ids from mpv/client.h (libmpv 0.41).
EV_NONE = 0
EV_SHUTDOWN = 1
EV_LOG_MESSAGE = 2
EV_START_FILE = 6
EV_END_FILE = 7
EV_FILE_LOADED = 8
EV_SEEK = 20
EV_PLAYBACK_RESTART = 21

DROP_PROPS = ("frame-drop-count", "decoder-frame-drop-count", "vo-delayed-frame-count",
              "vo-drop-frame-count")

APP_VD_LAVC_O = "view=rec709,view_size=half,thread_type=slice"
APP_VD_LAVC_THREADS = "12"


class MpvEvent(ctypes.Structure):
    _fields_ = [("event_id", ctypes.c_int), ("error", ctypes.c_int),
                ("reply_userdata", ctypes.c_uint64), ("data", ctypes.c_void_p)]


class MpvEventEndFile(ctypes.Structure):
    _fields_ = [("reason", ctypes.c_int), ("error", ctypes.c_int)]


class MpvEventLog(ctypes.Structure):
    _fields_ = [("prefix", ctypes.c_char_p), ("level", ctypes.c_char_p),
                ("text", ctypes.c_char_p), ("log_level", ctypes.c_int)]


def die(msg):
    print(json.dumps({"error": msg}))
    sys.stderr.write("mpv_harness: " + msg + "\n")
    sys.exit(2)


def preload_dir(lib_dir):
    """dlopen every real dylib of the folder, dependencies first (retry loop)."""
    pending = [p for p in sorted(glob.glob(os.path.join(lib_dir, "*.dylib"))) if not os.path.islink(p)]
    keep = []
    while pending:
        progress = False
        for p in list(pending):
            try:
                keep.append(ctypes.CDLL(p))
            except OSError:
                continue
            pending.remove(p)
            progress = True
        if not progress:
            break
    return keep, pending


class Mpv:
    def __init__(self, libpath):
        self._preloaded, self.unloadable = preload_dir(os.path.dirname(os.path.abspath(libpath)))
        self.lib = ctypes.CDLL(libpath)
        L = self.lib
        L.mpv_create.restype = ctypes.c_void_p
        L.mpv_create.argtypes = []
        L.mpv_initialize.restype = ctypes.c_int
        L.mpv_initialize.argtypes = [ctypes.c_void_p]
        L.mpv_set_option_string.restype = ctypes.c_int
        L.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        L.mpv_set_property_string.restype = ctypes.c_int
        L.mpv_set_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        L.mpv_command.restype = ctypes.c_int
        L.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
        L.mpv_get_property_string.restype = ctypes.c_void_p
        L.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        L.mpv_free.restype = None
        L.mpv_free.argtypes = [ctypes.c_void_p]
        L.mpv_wait_event.restype = ctypes.POINTER(MpvEvent)
        L.mpv_wait_event.argtypes = [ctypes.c_void_p, ctypes.c_double]
        L.mpv_request_log_messages.restype = ctypes.c_int
        L.mpv_request_log_messages.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        L.mpv_terminate_destroy.restype = None
        L.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
        L.mpv_error_string.restype = ctypes.c_char_p
        L.mpv_error_string.argtypes = [ctypes.c_int]
        L.mpv_client_api_version.restype = ctypes.c_ulong
        L.mpv_client_api_version.argtypes = []
        self.h = L.mpv_create()
        if not self.h:
            die("mpv_create returned NULL")
        self.logs = []
        self.end_file = None

    def err(self, code):
        return self.lib.mpv_error_string(code).decode()

    def option(self, name, value):
        r = self.lib.mpv_set_option_string(self.h, name.encode(), str(value).encode())
        if r < 0:
            die("mpv_set_option_string(%s=%s): %s" % (name, value, self.err(r)))

    def initialize(self):
        self.lib.mpv_request_log_messages(self.h, b"warn")
        r = self.lib.mpv_initialize(self.h)
        if r < 0:
            die("mpv_initialize: " + self.err(r))

    def command(self, *args):
        arr = (ctypes.c_char_p * (len(args) + 1))(*[str(a).encode() for a in args], None)
        return self.lib.mpv_command(self.h, arr)

    def prop(self, name):
        p = self.lib.mpv_get_property_string(self.h, name.encode())
        if not p:
            return None
        try:
            return ctypes.string_at(p).decode(errors="replace")
        finally:
            self.lib.mpv_free(p)

    def fprop(self, name):
        v = self.prop(name)
        try:
            return float(v) if v is not None else None
        except ValueError:
            return None

    def wait(self, timeout):
        """One event: returns (event_id, error). Log messages and end-file info are kept."""
        # The event pointer is only valid until the next mpv_wait_event call: copy what we need now.
        ev = self.lib.mpv_wait_event(self.h, timeout).contents
        if ev.event_id == EV_LOG_MESSAGE and ev.data:
            lg = ctypes.cast(ev.data, ctypes.POINTER(MpvEventLog)).contents
            if len(self.logs) < 30:
                self.logs.append("[%s] %s: %s" % (lg.level.decode(), lg.prefix.decode(),
                                                  lg.text.decode(errors="replace").rstrip()))
        elif ev.event_id == EV_END_FILE and ev.data:
            ef = ctypes.cast(ev.data, ctypes.POINTER(MpvEventEndFile)).contents
            self.end_file = {"reason": ef.reason, "error": ef.error}
        return ev.event_id, ev.error

    def drain(self):
        while self.wait(0)[0] != EV_NONE:
            pass

    def wait_for(self, wanted, timeout):
        """Wait for an event id; returns True when seen, False at the timeout or end of file."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            eid, _ = self.wait(min(0.25, max(0.0, end - time.monotonic())))
            if eid == wanted:
                return True
            if eid in (EV_END_FILE, EV_SHUTDOWN):
                return False
        return False

    def destroy(self):
        self.lib.mpv_terminate_destroy(self.h)
        self.h = None


def rss_mb(pid=None):
    """Current resident set size in MB (ps)."""
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid or os.getpid())],
                         capture_output=True, text=True).stdout.strip()
    return int(out) / 1024.0 if out else 0.0


def peak_rss_mb():
    """Peak resident set size of this process (macOS reports bytes)."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024.0 * 1024.0)


def setup(args, audio):
    m = Mpv(args.libmpv)
    m.option("vo", "null")
    m.option("untimed", "yes" if args.untimed else "no")
    if audio:
        m.option("ao", "null")
        m.option("aid", "auto")
    else:
        m.option("aid", "no")
    m.option("vd-lavc-threads", args.vd_lavc_threads)
    m.option("vd-lavc-o", args.vd_lavc_o)
    m.option("config", "no")
    m.option("osc", "no")
    m.option("input-default-bindings", "no")
    if args.loop:
        m.option("loop-file", "inf")
    if args.pause and args.mode == "seek":
        m.option("pause", "yes")
    for kv in args.set:
        k, _, v = kv.partition("=")
        m.option(k, v)
    m.initialize()
    return m


def load(m, clip, timeout=60):
    """loadfile; returns (ok, ms to file-loaded, ms to first frame after playback-restart)."""
    t0 = time.monotonic()
    r = m.command("loadfile", clip)
    if r < 0:
        die("loadfile: " + m.err(r))
    if not m.wait_for(EV_FILE_LOADED, timeout):
        die("no file-loaded event (end-file %s, log %s)" % (m.end_file, m.logs[:5]))
    t_loaded = time.monotonic()
    if not m.wait_for(EV_PLAYBACK_RESTART, timeout):
        die("no playback-restart event after load (end-file %s, log %s)" % (m.end_file, m.logs[:5]))
    t_first = time.monotonic()
    return (t_loaded - t0) * 1000.0, (t_first - t0) * 1000.0


def common_info(m, out):
    out["mpv_api_version"] = int(m.lib.mpv_client_api_version())
    for name in ("video-codec", "video-params/pixelformat", "container-fps", "duration",
                 "hwdec-current", "estimated-frame-count"):
        out[name] = m.prop(name)
    for name in ("width", "height"):
        v = m.fprop(name)
        out[name] = int(v) if v is not None else None


def mode_probe(args):
    m = setup(args, audio=False)
    m.lib.mpv_set_property_string(m.h, b"pause", b"yes")
    loaded_ms, first_ms = load(m, args.clip)
    out = {"mode": "probe", "clip": os.path.basename(args.clip), "vd-lavc-o": args.vd_lavc_o,
           "vd-lavc-threads": args.vd_lavc_threads,
           "file_loaded_ms": round(loaded_ms, 1), "first_frame_ms": round(first_ms, 1)}
    common_info(m, out)
    for name in ("video-params/colormatrix", "video-params/colorlevels", "video-params/primaries",
                 "video-params/gamma", "video-format", "audio-codec-name", "file-format"):
        out[name] = m.prop(name)
    out["warnings"] = m.logs
    m.destroy()
    return out


def mode_play(args, audio=False):
    # --untimed plays to the end of the file unless --seconds says otherwise.
    seconds = args.seconds if args.seconds is not None else (10 if audio else (120 if args.untimed else 20))
    m = setup(args, audio=audio)
    loaded_ms, first_ms = load(m, args.clip)
    out = {"mode": "audio" if audio else "play", "clip": os.path.basename(args.clip),
           "vd-lavc-o": args.vd_lavc_o, "vd-lavc-threads": args.vd_lavc_threads,
           "untimed": args.untimed, "loop": args.loop, "seconds": seconds,
           "file_loaded_ms": round(loaded_ms, 1), "first_frame_ms": round(first_ms, 1)}
    common_info(m, out)
    if audio:
        out["audio-codec-name"] = m.prop("audio-codec-name")
    fps = float(out["container-fps"] or 0)
    t0 = time.monotonic()
    tp0 = m.fprop("time-pos") or 0.0
    ef0 = m.fprop("estimated-frame-number") or 0.0
    samples = []          # one per second: (wall s, estimated-vf-fps, rss MB)
    avsync = []
    last_drops = {}       # last value seen of each drop counter (the file may end first)
    loops_frames = 0.0    # frames from completed loops (frame number wraps to 0 at a loop)
    last_ef = ef0
    last_seen_ef = ef0
    next_sample = t0 + 1.0
    ended = False
    while True:
        now = time.monotonic()
        if now - t0 >= seconds:
            break
        eid, _ = m.wait(0.05)
        if eid in (EV_END_FILE, EV_SHUTDOWN):
            ended = True
            break
        for name in DROP_PROPS:
            v = m.fprop(name)
            if v is not None:
                last_drops[name] = int(v)
        ef = m.fprop("estimated-frame-number")
        if ef is not None:
            if ef < last_ef - 5:        # the file looped: add the frames of the finished pass
                loops_frames += last_ef
            last_ef = ef
            last_seen_ef = ef
        now = time.monotonic()
        if now >= next_sample:
            next_sample += 1.0
            samples.append((round(now - t0, 2), m.fprop("estimated-vf-fps"), round(rss_mb(), 1)))
            if audio:
                v = m.fprop("avsync")
                if v is not None:
                    avsync.append(round(v, 4))
    t_end = time.monotonic()
    wall = t_end - t0
    frames = loops_frames + last_seen_ef - ef0
    total = float(out["estimated-frame-count"]) if out.get("estimated-frame-count") else None
    clean_eof = (ended and not args.loop and m.end_file is not None and m.end_file["reason"] == 0
                 and not any(last_drops.get(k) for k in ("frame-drop-count", "decoder-frame-drop-count")))
    if clean_eof and total:
        # The last poll comes up to 50 ms before the end: after a clean end of file with no
        # drops, every frame of the clip was decoded.
        frames = total - ef0
    out["wall_s"] = round(wall, 3)
    out["frames"] = int(round(frames))
    out["ended_early"] = ended
    out["achieved_fps"] = round(frames / wall, 3) if wall > 0 else None
    out["time_pos_rate"] = round(((m.fprop("time-pos") or 0.0) - tp0) / wall, 4) if (wall > 0 and not ended and not args.loop) else None
    for name in DROP_PROPS:
        v = m.fprop(name)
        out[name] = int(v) if v is not None else last_drops.get(name)
    vf = [s[1] for s in samples if s[1] is not None]
    vf_steady = [s[1] for s in samples if s[1] is not None and s[0] >= 3]
    out["estimated_vf_fps_last"] = round(vf[-1], 3) if vf else None
    out["estimated_vf_fps_mean"] = round(statistics.mean(vf_steady), 3) if vf_steady else None
    out["estimated_vf_fps_min"] = round(min(vf_steady), 3) if vf_steady else None
    out["rss_samples_mb"] = [s[2] for s in samples]
    out["peak_rss_mb"] = round(max([peak_rss_mb()] + [s[2] for s in samples]), 1)
    if args.untimed:
        out["decode_fps"] = out["achieved_fps"]
    if seconds >= 100 and len(samples) >= 100:
        rss20 = next((s[2] for s in samples if s[0] >= 20), samples[19][2])
        out["rss_20s_mb"] = rss20
        out["rss_end_mb"] = samples[-1][2]
        out["rss_growth_pct"] = round((samples[-1][2] - rss20) / rss20 * 100.0, 2)
        out["rss_max_after_20s_mb"] = max(s[2] for s in samples if s[0] >= 20)
    if audio:
        out["avsync_samples"] = avsync
        out["avsync_max_abs"] = round(max(abs(x) for x in avsync), 4) if avsync else None
    out["end_file"] = m.end_file
    out["warnings"] = m.logs
    m.destroy()
    return out


def mode_seek(args):
    seed = args.seed if args.seed is not None else int(time.time())
    m = setup(args, audio=False)
    loaded_ms, first_ms = load(m, args.clip)
    out = {"mode": "seek", "clip": os.path.basename(args.clip), "vd-lavc-o": args.vd_lavc_o,
           "vd-lavc-threads": args.vd_lavc_threads, "seed": seed, "paused": args.pause,
           "loadavg_1min": round(os.getloadavg()[0], 2),
           "file_loaded_ms": round(loaded_ms, 1), "first_frame_ms": round(first_ms, 1)}
    common_info(m, out)
    duration = float(out["duration"])
    rng = random.Random(seed)
    # Times stay one second inside the clip so that "exact" has a frame to land on.
    times = [round(rng.uniform(0.0, duration - 1.0), 3) for _ in range(args.seeks)]
    time.sleep(1.0)  # let playback settle
    results = []
    for t in times:
        m.drain()
        t0 = time.monotonic()
        r = m.command("seek", "%.3f" % t, "absolute+exact")
        if r < 0:
            die("seek %.3f: %s" % (t, m.err(r)))
        ok = m.wait_for(EV_PLAYBACK_RESTART, 5.0)
        dt = (time.monotonic() - t0) * 1000.0
        pos = m.fprop("time-pos")
        results.append({"t": t, "ms": round(dt, 1), "restart": ok,
                        "landed": round(pos, 3) if pos is not None else None})
        time.sleep(0.35)
    ms = [r["ms"] for r in results]
    out["seek_count"] = len(results)
    out["seeks"] = results
    out["max_ms"] = max(ms)
    srt = sorted(ms)
    out["p95_ms"] = srt[math.ceil(0.95 * len(srt)) - 1]  # nearest rank: 2nd largest of 30
    out["min_ms"] = min(ms)
    out["median_ms"] = round(statistics.median(ms), 1)
    out["mean_ms"] = round(statistics.mean(ms), 1)
    out["all_restarted"] = all(r["restart"] for r in results)
    out["peak_rss_mb"] = round(max(peak_rss_mb(), rss_mb()), 1)
    out["warnings"] = m.logs
    m.destroy()
    return out


def main():
    ap = argparse.ArgumentParser(description="libmpv playback harness for IINA RAW")
    ap.add_argument("libmpv")
    ap.add_argument("clip")
    ap.add_argument("mode", choices=["probe", "play", "seek", "audio"])
    ap.add_argument("--vd-lavc-o", default=APP_VD_LAVC_O)
    ap.add_argument("--vd-lavc-threads", default=APP_VD_LAVC_THREADS)
    ap.add_argument("--seconds", type=float, default=None)
    ap.add_argument("--seeks", type=int, default=30)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--untimed", action="store_true")
    ap.add_argument("--pause", action="store_true")
    ap.add_argument("--set", action="append", default=[])
    args = ap.parse_args()
    if not os.path.isfile(args.libmpv):
        die("libmpv not found: " + args.libmpv)
    if not os.path.isfile(args.clip):
        die("clip not found: " + args.clip)
    if args.mode == "probe":
        out = mode_probe(args)
    elif args.mode == "play":
        out = mode_play(args)
    elif args.mode == "audio":
        out = mode_play(args, audio=True)
    else:
        out = mode_seek(args)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
