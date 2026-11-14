# Design

This note describes what the project builds and why it is built this way. It is short on
purpose. The facts about the file format are in [`format/tico-raw-nikon.md`](format/tico-raw-nikon.md).
The measurements are in [`results.md`](results.md).

## 1. Goals

Nikon cameras record raw video as R3D NE (`.R3D`, Nikon ZR) or N-RAW (`.NEV`, Z8, Z9 and
Z6III). Both formats use the same codec. Most players cannot open them on a Mac.

The project has these goals:

1. **G1: an FFmpeg decoder.** `ffmpeg -i clip.R3D` and `ffmpeg -i clip.NEV` decode every
   frame.
2. **G2: exact decoding.** The decoded Bayer values are identical to the values of a
   reference decoder, at every stage, on the test frames.
3. **G3: a correct-looking picture.** As-shot white balance, the clip's own colour matrix
   and a Rec.709 viewing transform.
4. **G4: real-time playback** in a player at the clip's frame rate, at a preview size of at
   least 1920 × 1080, on an Apple Silicon Mac.
5. **G5: seeking.** Every frame is intra-coded, so any frame can be decoded alone.
6. **G6: audio** plays in sync.
7. **G7: clean code.** The decoder is written so that it could be offered to FFmpeg later.

## 2. Formats in scope

| Format | Extension | Cameras | Container fourcc |
| --- | --- | --- | --- |
| R3D NE | `.R3D` | Nikon ZR | `NR3D` |
| N-RAW | `.NEV` | Nikon Z8, Z9, Z6III | `NRAW` |

Classic RED R3D (REDCODE) is out of scope. It uses a different codec and a different
container.

The container is ISO base media. FFmpeg's `mov` demuxer already opens these files. The only
missing parts in FFmpeg were the video decoder and the mapping of the two fourcc values to a
codec id.

## 3. Parts

| Part | What it is | Where |
| --- | --- | --- |
| Decoder | A `tico_raw` decoder for FFmpeg. Output: the linear Bayer mosaic. | [`alperkaganavci/FFmpeg`](https://github.com/alperkaganavci/FFmpeg), branches `tico-raw` and `tico-raw-9.0` |
| View | An optional Rec.709 view inside the same decoder (fork only). | same branches |
| Player | IINA RAW, an unofficial IINA fork that links the FFmpeg 9.0.2 build. | [`alperkaganavci/iina`](https://github.com/alperkaganavci/iina), branch `iina-raw` |
| Quick Look | Finder thumbnails and a space-bar preview that plays the clip. | same branch |
| Tests and tools | Check scripts, a reference harness, install script. | this repo |

## 4. Decoder

One packet holds one whole frame: the Nikon wrapper and the codestream. The decoder runs
these stages in order.

1. **Wrapper.** Read the `NRAW` box and its `NRMT` tags: size, CFA pattern, white balance
   gains, camera-to-XYZ matrix, ISO. Take the codestream length.
2. **Codestream header.** Read `SOC`, `CAP`, `PIH`, `CDT` and `WGT`. Reject every value
   outside the supported set with a clear "unsupported" error. Never output a wrong picture.
3. **Entropy decoding.** For every slice, precinct and packet, decode the group
   code-length indices, the magnitudes and the signs, and dequantize them. This gives the
   wavelet coefficients (stage `coeffs`).
4. **Inverse 5/3 wavelet** (five horizontal levels, one vertical level). Stage `planes_st`.
5. **Inverse Star-Tetrix.** This turns the four decorrelated components into the four CFA
   planes. Stage `cfa_companded`.
6. **Transfer curve.** A square-root style curve gives linear values. The planes are
   placed into the Bayer mosaic. Stage `bayer_linear`.

Each stage has a defined dump format ([format note, section 10](format/tico-raw-nikon.md)),
so each stage can be compared with the reference on its own. The self-test program
`libavcodec/tests/ticoraw.c` in the FFmpeg fork writes these dumps, and `tools/compare_stage.py`
compares them.

Every read is bounds checked. A damaged frame gives an error, not a crash.

### Why a native decoder

A first study tried to reuse SVT-JPEG-XS (an ISO/IEC 21122 implementation). It does not
decode this codestream. The packets are grouped in a different order, the dequantizer scale
differs, and the output scaling cannot hold the values. The result is in
[`results.md`](results.md), section "Phase 0". SVT's inverse Star-Tetrix does match, on a
transposed grid, and the study uses it as an independent check.

## 5. Threads and speed

Slices are independent. The decoder uses them in two ways:

- **Slice threads.** The slices are entropy decoded in parallel through `execute2`. The
  horizontal wavelet steps run per slice. The vertical step runs in column strips. The
  Star-Tetrix passes and the plane-to-mosaic step run in row jobs. One decode of a 6K frame
  is fast, so a seek is fast (median about 47 ms).
- **Frame threads.** Frames are independent, so frame threads also work. They use more
  memory (about 145 MB per thread) and do not help one-frame latency.

The player uses 12 slice threads. Memory stays about the same at every thread count.

## 6. Output and metadata

The default output is a 16-bit RGGB Bayer mosaic (`AV_PIX_FMT_BAYER_RGGB16`), the same kind
of output as FFmpeg's `prores_raw` decoder. Only the RGGB pattern is supported.

The decoder exports frame metadata so a later stage can render the picture:
`ticoraw.cfa`, `ticoraw.wb_gain`, `ticoraw.cam_to_xyz`, `ticoraw.iso`,
`ticoraw.white_level` and `ticoraw.black_level`.

## 7. View transform

A raw mosaic is not a viewable picture. The decoder has an optional Rec.709 view, set with
the options `view`, `view_size` and `exposure`:

| Option | Values | Meaning |
| --- | --- | --- |
| `view` | `bayer` (default), `rec709` | `rec709` outputs planar RGB (`gbrp16`, BT.709, full range) |
| `view_size` | `half` (default), `full` | `half`: one pixel per 2 × 2 quad (3030 × 1705 for a 6060 × 3410 clip), no demosaic. `full`: bilinear demosaic |
| `exposure` | -8 to 8 | offset in stops, default 0 |

The steps for each pixel:

1. Read the four CFA samples of the quad. Normalise them with the black level and the
   transfer curve.
2. Apply the white balance gains stored in the clip (as shot). Clamp to 0 to 1.
3. Apply the clip's camera-to-XYZ matrix and the XYZ-to-Rec.709 matrix.
4. Apply the exposure gain (about +3 EV for R3D NE, so that sensor white sits six stops above
   grey).
5. Apply a tone map around grey, a soft highlight shoulder, and a power 1/2.4 transfer.
6. Quantise to 16 bits.

The numbers and the evidence are in [format note, section 12](format/tico-raw-nikon.md).
The view is a quick look, not a grade. It targets the picture of a reference renderer, and
a final colour check against a grading tool is still the user's job.

The view code is table driven (a per-frame table for the input curve, a fixed table for the
tone map) so the half view decodes faster than real time (about twice as fast as needed). It is fork-only and is not
meant for upstream FFmpeg. The Bayer output stays unchanged.

## 8. Delivery

IINA RAW is a local IINA build that links the FFmpeg build above:

- native playback, seeking and audio, with no helper process;
- its own name and bundle id (`com.alperkaganavci.iina-raw`), so it sits next to stock IINA
  and does not change it;
- no update checks;
- it declares only the `.R3D` and `.NEV` file types;
- built-in decoder options: `vd-lavc-o=view=rec709,view_size=half,thread_type=slice`
  and 12 decoder threads. A user can replace them in the settings.

The libraries (FFmpeg 9.0.2 with the decoder, mpv 0.41.0, libplacebo and others) come from
IINA's own `deps-buildscripts`, plus one patch for the decoder
([`build/README.md`](../build/README.md)).

## 9. Quick Look

Two app extensions inside IINA RAW share a small frame-grabber module (C and Swift, over
libavformat, libavcodec and libswscale):

- **RawThumbnail.appex** gives Finder a thumbnail: a frame from 10 percent into the clip.
- **RawPreview.appex** makes the space bar play the clip in the preview.

The `.R3D` and `.NEV` types are declared as `public.data` and `public.content`, not as
`public.movie`. If they conformed to `public.movie`, macOS would send them to its own movie
thumbnailer and ignore the extension. One side effect: Spotlight searches for "Kind: Movie"
do not match these clips.

Builds are ad-hoc signed, so the extensions need the `disable-library-validation`
entitlement to load the app's own libraries.

## 10. Non-goals

- Classic RED R3D.
- Grading controls, LUTs, export and transcoding.
- Windows and Linux. The decoder C code stays portable, but the player and the build are for
  Apple Silicon macOS only.
- ProRes RAW. Encoding TICO RAW.
- Sidecar files (`.RMD`) are ignored.
- The decoder must never change the camera files.

## 11. Notes on patents and upstreaming

TICO RAW is intoPIX technology, a JPEG XS variant. FFmpeg ships other patented codecs. Any
submission to FFmpeg should say so, follow FFmpeg's current policy on AI-assisted patches,
and leave out the Rec.709 view, which is meant for players.
