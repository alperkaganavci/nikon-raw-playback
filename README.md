# nikon-raw-playback

Watch Nikon ZR R3D NE and N-RAW clips on a Mac in real time. This project has an FFmpeg
decoder (`tico_raw`) for the raw video of these clips, and an IINA-based player, IINA RAW,
that plays them. IINA RAW also gives Finder thumbnails and a space-bar preview that plays the
clip. The decoder was written clean room, from a written description of the format. This
repository holds the documents, the tools, the tests and the build script. The code lives in
two forks.

IINA RAW is an unofficial fork of IINA. This project is not affiliated with Nikon, intoPIX,
RED, the IINA project or the FFmpeg project.

## What works

All numbers come from one Nikon ZR clip (R3D NE, 6060 × 3410, 25 fps, 819 frames) on an
Apple Silicon Mac. Details and methods are in [`docs/results.md`](docs/results.md).

- **Exact decoding.** The decoder's output is byte-exact against the reference decoder at
  every stage (coefficients, wavelet planes, CFA planes and the linear Bayer mosaic) on the
  three test frames (0, 100 and 818). The N-RAW copy of the clip decodes to the same stage
  dumps.
- **Real-time playback.** IINA RAW plays the 6K clip at 25 fps with no dropped frames. The
  picture is the half view: 3030 × 1705, Rec.709, as-shot white balance.
- **Speed in reserve.** The decoder decodes the whole clip at 54 to 59 fps in the player's
  library (untimed). The app's memory use is about 0.6 to 1 GB.
- **Fast seeks.** A seek takes about 47 ms (median of 210 seeks).
- **Picture.** The Rec.709 view matches the reference renderer: SSIM 0.947 to 0.948 after the
  same 4:2:0 round trip, and channel means within 0.4 %.
- **Finder thumbnails.** A Quick Look thumbnail extension gives a frame of each clip in about
  0.3 s per clip.
- **Space-bar preview.** A Quick Look preview extension plays the clip at about 22 to 24 fps,
  with about 270 MB of memory.
- **Damaged files.** Damaged input gives an error, not a crash. A corruption check runs under
  AddressSanitizer and UndefinedBehaviorSanitizer.

## Not tested yet

- Other ZR modes (4K, 50, 60 and 120 fps) and other camera modes.
- Real N-RAW (`.NEV`) clips from a Z8, Z9 or Z6III. The `.NEV` path is tested only with a
  lossless rewrapped copy of an R3D NE clip.
- The full-size view (`view_size=full`) against the reference. It does not play in real time
  (about 16 fps).
- A visual colour check against a grading tool. The view is a quick look, not a grade.
- CFA patterns other than RGGB.

## How it fits together

```
 FFmpeg fork          alperkaganavci/FFmpeg   branches tico-raw (on master) and
 (tico_raw decoder)                           tico-raw-9.0 (on FFmpeg 9.0.2)
      |
      |  build/patches/ffmpeg-9.0.2-tico_raw.patch
      v
 IINA deps            iina/deps-buildscripts at ee35579d, plus the patch above:
 (47 libraries)       FFmpeg 9.0.2, mpv, libplacebo and more
      |
      |  deps/lib and deps/include
      v
 IINA fork            alperkaganavci/iina   branch iina-raw (IINA 1.5.1)
 (IINA RAW source)    own name and bundle id, no updates, R3D and NEV only,
      |               decoder defaults, Quick Look extensions
      |  xcodebuild (ad-hoc signed), tools/install_iina_raw.sh
      v
 IINA RAW.app         /Applications/IINA RAW.app
```

This repository (`nikon-raw-playback`) holds the format note, the design, the results, the
tests, the reference harness and the script that runs the whole chain.

| Path | What it holds |
| --- | --- |
| `docs/format/tico-raw-nikon.md` | The format note: container, Nikon wrapper, codestream, every decoding stage, the viewing transform |
| `docs/design.md` | Goals, architecture, decoder stages, view transform, delivery |
| `docs/clean-room.md` | The clean-room rules and which sources each file used |
| `docs/results.md` | Measurements and methods |
| `docs/HOW-TO-USE.md` | How to use IINA RAW |
| `build/` | `build-iina-raw.sh`, its README and the two patches |
| `tools/` | Frame extraction, stage compare, latency tool, install script, reference renderer scripts |
| `tests/` | The decoder checks, the playback check and the unit tests |
| `oracle/` | The black-box reference harness. It links blue-compressor as a library. It is not part of the decoder. |

## Build and install

You need an Apple Silicon Mac, Xcode and a few Homebrew packages. Then run:

```
build/build-iina-raw.sh
```

The first run takes tens of minutes. The steps, the options and what to do when something
fails are in [`build/README.md`](build/README.md).

## Using IINA RAW

Double-click a `.R3D` or `.NEV` clip. How to change the view size or the exposure, how to
remove the app and what the limits are: [`docs/HOW-TO-USE.md`](docs/HOW-TO-USE.md).

## Run the tests

The tests need a Nikon ZR clip and reference files. The repository does not hold them
(`testdata/` is git-ignored). Make them from your own clip:

```
export CLIP=/path/to/clip.R3D

# frame samples
mkdir -p testdata/samples
for i in 0 100 818; do tools/extract_frame.py "$CLIP" $i testdata/samples/f$(printf %04d $i).bin; done

# reference dumps (needs Rust; the oracle builds blue-compressor 4d35f31)
oracle/run.sh "$CLIP" testdata/ref/A015_C004 0 100 818

# reference views (the first command builds the oracle CLI into testdata/oracle-bin)
tools/oracle_render.sh --exact "$CLIP" testdata/ref/view-p010
tools/oracle_render.sh "$CLIP" testdata/ref/view

```

The checks that use the N-RAW copy (`testdata/ref/A015_C004_nraw.NEV`, a lossless rewrap of the
clip) fail with "missing file" when it is absent. The blue-compressor command line can make it
(`bluecompress --rewrap --to-nev`). That command is **untested** here, so check its options
with `bluecompress --help`.

Then build the FFmpeg decoder (see [`build/README.md`](build/README.md), section "Only the
decoder") and run the checks:

```
FFMPEG_BUILD=/path/to/ffmpeg-build CLIP=$CLIP tests/decoder_checks.sh all   # decoder checks
CLIP=$CLIP python3 tests/test_tools.py                                       # tool unit tests
CLIP=$CLIP tests/test_playback.sh                                            # needs IINA RAW installed
```

The shell scripts stop with a clear message when `CLIP` or `FFMPEG_BUILD` is not set;
`tests/test_tools.py` skips its clip tests instead. The
Quick Look checks also need `IINA_RAW_SRC`, a checkout of
[`alperkaganavci/iina`](https://github.com/alperkaganavci/iina) (branch `iina-raw`) with
`deps/lib` filled by the build.

## Clean-room development

The decoder authors never read the source of blue-compressor, the program that decodes this
codec in Rust. Someone else read it once, and wrote down the facts of the format in
[`docs/format/tico-raw-nikon.md`](docs/format/tico-raw-nikon.md). The decoder authors used only
that note, FFmpeg, public standards and the bytes of the clips. blue-compressor ran as a black
box and gave reference output. The rules and the evidence for each file are in
[`docs/clean-room.md`](docs/clean-room.md).

Most of the code and documentation was written with AI assistance (Anthropic Claude), under
the clean-room process and the reviews described here.

## Credits

- [FFmpeg](https://ffmpeg.org): the decoder is an FFmpeg decoder, and the build uses FFmpeg 9.0.2.
- [IINA](https://github.com/iina/iina): IINA RAW is a fork of IINA 1.5.1.
- [mpv](https://mpv.io) and [libplacebo](https://code.videolan.org/videolan/libplacebo): the
  player core and the renderer that IINA uses.
- [blue-compressor](https://github.com/redn3/blue-compressor) by its authors (Apache-2.0): the
  black-box reference for the stage checks. Its `NOTICE` mentions
  [rawmakase](https://github.com/pch/rawmakase) (MIT, "Copyright (c) 2026 RAWmakase
  contributors"). The provenance is recorded in [`docs/clean-room.md`](docs/clean-room.md).
- [SVT-JPEG-XS](https://github.com/OpenVisualCloud/SVT-JPEG-XS) (Intel, BSD-2-Clause-Patent):
  used in the phase-0 study. See [`docs/results.md`](docs/results.md).

## Licence

- The code and scripts in this repository: MIT ([`LICENSE`](LICENSE)). Exceptions: the file
  `build/patches/ffmpeg-9.0.2-tico_raw.patch` is under the licence of the FFmpeg fork, and
  `build/patches/deps-buildscripts.patch` changes one line of `iina/deps-buildscripts` (our line is
  MIT; its two context lines belong to that project). See [`LICENSE-docs`](LICENSE-docs).
- The documentation (`README.md`, `build/README.md` and `docs/`): CC BY 4.0
  ([`LICENSE-docs`](LICENSE-docs)).
- The FFmpeg fork: LGPL-2.1-or-later, the licence of FFmpeg.
- The IINA fork: GPL-3.0, the licence of IINA.

Not affiliated with Nikon, intoPIX, RED, the IINA project or the FFmpeg project. Nikon, N-RAW,
RED and the other names are trademarks of their respective holders.
