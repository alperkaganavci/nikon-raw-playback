# Clean-room development

The `tico_raw` decoder was written clean room. This note states the rules and records, for
each file, which sources its author used.

## Why

An existing open-source program, [blue-compressor](https://github.com/redn3/blue-compressor)
(Apache-2.0, Rust), decodes this codec. FFmpeg is LGPL-2.1-or-later, and Apache-2.0 code
cannot go into an LGPL-2.1 file as it is. Facts about a file format are not protected by
copyright, but the expression of a program's code is. So the work was split in a way that
keeps the two apart.

## Roles

- **Format writer.** The only role that read blue-compressor's source. It wrote
  [`format/tico-raw-nikon.md`](format/tico-raw-nikon.md): a description of facts only
  (marker and box layouts, field sizes and meanings, tag numbers, value ranges, and
  algorithms as math or plain steps). Not allowed in the note: copied code, code-shaped
  pseudocode that mirrors blue-compressor's functions, its names for internal functions,
  types or variables, and its comments. The note was reviewed against these rules before decoder
  authors used it (see "Reviews").
- **Decoder authors.** Separate authors who never read
  blue-compressor's source. Their allowed sources:
  - the format note;
  - [SVT-JPEG-XS](https://github.com/OpenVisualCloud/SVT-JPEG-XS) (Intel, BSD-2-Clause-Patent,
    an ISO/IEC 21122 implementation), whose code may be studied and, with its notice kept,
    reused;
  - FFmpeg's own code;
  - public standards (ISO/IEC 21122, ITU-R BT.709, IEC 61966-2-1);
  - the bytes of the test clips.
- **Test oracle.** blue-compressor is built and run as a black box, to produce reference
  output (decoded planes, rendered frames). Decoder authors saw its output, not its source.
  The harness that runs it is in [`oracle/`](../oracle/). It links blue-compressor as a
  library and is not part of the decoder.

Facts that no public standard covers (the Nikon `NRAW` wrapper and `NRMT` tags, the `CAP`
vendor capability, the 13 vendor bytes in `PIH` with the square-root transfer curve) come
only from the format note and the clip bytes.

Each decoder author ended their work with the statement: "I did not read blue-compressor
source code."

## Reviews

The format note had a dedicated review against a clean-room checklist before decoder authors
used it. After the decoder was finished, a final review of the whole branch compared it with
the source of the reference renderer and found no derivation (result: pass).

## AI assistance

Most of the code and documentation was written with AI assistance (Anthropic Claude), under
the clean-room process and the reviews described here.

## Third-party notices

- blue-compressor is Apache-2.0. It is the black-box reference. Its source was read by the
  format writer and by the oracle author.
- Its `frame.rs` states that its Star-Tetrix lifting steps, 5/3 wavelet and transfer curve
  follow [rawmakase](https://github.com/pch/rawmakase) (MIT licence, licence line
  "Copyright (c) 2026 RAWmakase contributors"), and blue-compressor ships a `NOTICE` file
  that mentions it. The format note records these as facts of the format.
- SVT-JPEG-XS v0.10.0 (BSD-2-Clause-Patent) was used in the phase-0 study, which tested
  whether it could decode the codestream. Its `Mct.c` was compiled in unchanged for a stage
  check. No SVT code is in the decoder.

## Provenance table

Every decoder file has a row. "Reference dumps" means output of the oracle, used for
comparison only. FFmpeg files are named by their path under `libavcodec/` (or `libavutil/`
when stated).

| File | Sources used | Author role |
| --- | --- | --- |
| `docs/format/tico-raw-nikon.md` | blue-compressor source at commit `4d35f31` (read); bytes of the test clip `A015_C004_0706JH.R3D` and of its N-RAW rewrap; reference dumps; general knowledge of ISO/IEC 21122 (the standard text was not available). For section 12 (viewing transform) the format writer read blue-compressor's `develop.rs`, `develop.wgsl`, `develop_wgpu.rs`, `main.rs` (CLI), `proxy.rs`, `r3d.rs`, `frame.rs` and `denoise.rs`, and ran the oracle binary as a black box (`develop --stats`, and `develop --rec709 --width 1920` with a capture wrapper for its FFmpeg calls); numeric checks against a reference still | format writer (read blue-compressor source) |
| `oracle/` (`Cargo.toml`, `Cargo.lock`, `run.sh`, `src/main.rs`) | blue-compressor `4d35f31` as a library dependency and its source; clip bytes | oracle author (read blue-compressor source) |
| `tools/extract_frame.py` | `ffprobe -show_packets` output for the test clip; Python standard library | decoder author |
| `tools/compare_stage.py` | format note section 10 (dump layout, frame JSON keys); the reference JSON for frame 0; Python standard library | decoder author |
| `tests/test_tools.py` | clip bytes of the test clip; reference JSON; Python standard library | decoder author |
| phase-0 study (not included in this repository) | SVT-JPEG-XS `v0.10.0` (`CMakeLists.txt`, README, `ParseHeader.c`, `Pi.c`, `Codestream.h`, `Packing.c`, `Mct.c` compiled in unchanged, `NltDec.c`, `Dequant.c`, the public API `SvtJpegxsDec.h`, the options of `SvtJpegxsDecApp`); format note sections 2–5, 8 and 10; reference dumps `planes_st` and `cfa_companded`; Python standard library | decoder author |
| `libavcodec/ticoraw_nraw.h`, `libavcodec/ticoraw_nraw.c` | format note section 2 (Nikon wrapper) and 10.8 (meta keys); bytes of one frame sample; FFmpeg `libavutil/intreadwrite.h`, `libavutil/intfloat.h`, `libavutil/log.h` | decoder author |
| `libavcodec/ticoraw_header.h`, `libavcodec/ticoraw_header.c` | format note sections 3 (markers, PIH, CDT, WGT, Star-Tetrix recognition), 9.1 (vendor bytes) and 11 (supported set, damaged data); bytes of one frame sample; FFmpeg `jpegxs.h` (marker values), `libavutil/intreadwrite.h`, `libavutil/log.h` | decoder author |
| `libavcodec/ticoraw_entropy.h`, `libavcodec/ticoraw_entropy.c` | format note sections 4, 5 (slices, bands, precincts, packets, GCLI, magnitudes, signs, placement), 6 (dequantization), 10.3–10.4 (canonical coefficient layout) and 11.3 (damaged data); FFmpeg `get_bits.h`, `libavutil/intmath.h`, `libavutil/intreadwrite.h`, `jpegxs.h`, `libavutil/mem.h`; reference coefficient dumps (comparison only). SVT-JPEG-XS source was not read for this file; no code copied | decoder author |
| `libavcodec/ticoraw_dsp.h`, `libavcodec/ticoraw_dsp.c` | format note sections 7 (inverse 5/3 wavelet), 8 (inverse Star-Tetrix) and 10.5–10.6; reference dumps `planes_st` and `cfa_companded` (comparison only); FFmpeg `libavutil/common.h` (`av_clip`), `libavutil/attributes.h`, `aarch64/bitpacked_init_aarch64.c` (model for the architecture hook). No SVT-JPEG-XS code copied | decoder author |
| `libavcodec/ticoraw_core.h`, `libavcodec/ticoraw_core.c` | format note sections 5.1, 5.2, 7.2–7.3, 8, 9 (transfer curve, white level), 10.2 and 10.7 (mosaic placement); reference dumps (comparison only); FFmpeg `libavutil/mem.h`, `libavutil/common.h`, `pthread.c` (thread type selection), `pthread_slice.c` and `libavutil/slicethread.c` (`execute2`, `threadnr`, per-job return values), `options.c`, `libavutil/avassert.h` | decoder author |
| `libavcodec/ticorawdec.c` | format note sections 2, 9, 10.7, 10.8 (float printing), 11.1–11.2 (RGGB only) and 12.5 (the clip type sets a gain); FFmpeg `imm6.c`, `prores_raw.c` (model for Bayer output and frame threading), `codec_internal.h`, `pthread_frame.c`, `decode.h`, `decode.c`, `thread.h`, `libavutil/dict.h`, `libavutil/eval.h`, `libavutil/imgutils.h`, `hevc/hevcdec.c` (model for an option table with constants), `libavutil/opt.h`, `libavutil/opt.c`, `libavutil/eval.c`, `fftools/opt_common.c`, `pthread_slice.c` | decoder author |
| `libavcodec/ticoraw_view.h`, `libavcodec/ticoraw_view.c` | format note sections 9, 10.7, 10.8 (`cam_to_xyz` expects white-balanced input) and 12 (the viewing transform); ITU-R BT.709 (primaries) and IEC 61966-2-1 (D65 white): the XYZ-to-BT.709 matrix was computed from the primaries and the white point with Python `fractions`; IEEE 754 single-precision layout; FFmpeg `ticoraw_core.c` (row jobs as the model), `libavutil/mathematics.h`, `libavutil/intfloat.h`, `libavutil/thread.h` (`ff_thread_once`), `libavutil/mem.h` | decoder author |
| `libavcodec/aarch64/ticoraw_init.c` | FFmpeg `aarch64/bitpacked_init_aarch64.c` (style model), `libavutil/attributes.h`. An empty hook: no NEON code | decoder author |
| `libavcodec/tests/ticoraw.c` | format note 10.1–10.8 (frame JSON, float printing), 11.2 and 12.10; FFmpeg `tests/apv.c` (style model), `options.c`, `libavutil/opt.h` | decoder author |
| `libavcodec/codec_id.h`, `libavcodec/codec_desc.c`, `libavformat/isom_tags.c`, `libavcodec/allcodecs.c`, `libavcodec/Makefile`, `libavcodec/aarch64/Makefile` (changed) | format note section 1 (fourcc `NR3D`, `NRAW`); FFmpeg source of the neighbouring entries | decoder author |
| `tests/decoder_checks.sh` | `tools/compare_stage.py` usage text; format note 2, 3.2, 5.4, 5.5, 9, 10.7–10.9, 11.3 and 12; the output formats of FFmpeg `ffprobe` and the `ssim` filter; AddressSanitizer and UndefinedBehaviorSanitizer builds; Python standard library | decoder author |
| `tools/decode_latency.c` | FFmpeg public API (`avcodec.h` send and receive, `thread_type`, `active_thread_type`, `av_dict_parse_string`, `avcodec_flush_buffers`; `libavutil/time.h`); `ffbuild/config.sh` of the FFmpeg build for the link flags | decoder author |
| `tests/test_deps_build.py` | FFmpeg public API (`avcodec_find_decoder_by_name`, `avformat_open_input`, `avformat_find_stream_info`, `av_find_best_stream`); Python standard library (`ctypes`) | decoder author |
| `tools/install_iina_raw.sh`, `check_iina_raw_bundle` and `check_stock_iina_untouched` in `tests/decoder_checks.sh` | macOS `lsregister`, `LSSetDefaultRoleHandlerForContentType`, `mdls`, `pluginkit`, Python `plistlib` | decoder author |
| `docs/results.md` | measurements of `tools/decode_latency.c`, `tests/decoder_checks.sh` and `tests/test_playback.sh`; an independent Python model of the viewing pipeline written from format note section 12 | decoder author |
| FFmpeg 9.0.2 port (branch `tico-raw-9.0`) | the same decoder files, unchanged, plus the registration lines in `codec_id.h`, `codec_desc.c`, `allcodecs.c`, `Makefile`, `aarch64/Makefile` and `isom_tags.c`; FFmpeg `n9.0.2` source for the places where the registration differs from `master` | decoder author (port, no decoder behaviour change) |
| `build/patches/ffmpeg-9.0.2-tico_raw.patch` | `git diff n9.0.2 tico-raw-9.0` of the FFmpeg fork | generated from our own commits |
| IINA RAW app (`alperkaganavci/iina`, branch `iina-raw`) | IINA `v1.5.1` source (GPL-3.0), edited for bundle id, name, update removal, document types and default mpv options; the Quick Look extensions and the `RawFrameGrabber` module are our own code (C helper over libavformat, libavcodec and libswscale, with a Swift wrapper); libraries from the deps build (FFmpeg 9.0.2 with `tico_raw`, mpv 0.41.0, libplacebo) | decoder author |

## FFmpeg base

The FFmpeg fork starts from FFmpeg `master` at commit
`2bf291526e50480d2c355b4c6c8dd04863212aa1` (2026-11-08, "swscale/aarch64/ops: store the
linear coefficients in the op chain"), branch `tico-raw`. Upstream:
<https://github.com/FFmpeg/FFmpeg>.

The 9.0.2 port is the branch `tico-raw-9.0`, which starts at tag `n9.0.2` and holds the same
decoder. The only conflict was in `libavcodec/codec_id.h` and `libavcodec/codec_desc.c`,
where `master` has the extra codec ids `ASTC`, `RW2` and `IMM6` that 9.0.2 does not have.
The port keeps only `AV_CODEC_ID_TICO_RAW`.
