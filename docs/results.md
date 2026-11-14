# Results

Measurements for the decoder, the Rec.709 view and IINA RAW. They were taken on an Apple
Silicon Mac (M-series) while other work ran on the same Mac, so take the numbers as
approximate. The test clip is a Nikon ZR R3D NE clip (`A015_C004_0706JH.R3D`, 6060 × 3410,
25 fps, 819 frames, ISO 6400). Its N-RAW copy is a lossless rewrap of the same clip.

Sections:

1. Phase 0: SVT-JPEG-XS study.
2. Decoder baseline: frame threads.
3. Slice threads: single-frame latency.
4. Rec.709 view.
5. Speed and memory for IINA RAW.
6. FFmpeg 9.0.2 port and deps.
7. Playback in IINA RAW.
8. Quick Look.

## Phase 0: SVT-JPEG-XS v0.10.0 does not decode the TICO RAW codestream

Date: 2026-11-08. The scripts and the raw tool output of this study are not part of this repository. The numbers below are the record.

### Decision

The decoder is native code. It does not reuse SVT-JPEG-XS.

SVT-JPEG-XS v0.10.0 decodes no slice of any test frame, after every header
normalization that the format note supports. The blocker is in the precinct data, not in
the markers: the clip groups the bands into packets in a different way from SVT's only
supported progression order (Ppoc = 0). No header rewrite can change that. Three further
differences would also prevent a bit-exact match even if the packets could be read
(dequantizer scale, output scaling, and the Star-Tetrix grid orientation; see below).

One stage of SVT does match the reference exactly: SVT's inverse Star-Tetrix (its
`Mct.c`, unchanged), applied to the reference `planes_st` on the transposed grid, gives
`cfa_companded` with 0 mismatches on frames 0, 100 and 818. The study used this as an
independent check of the decoder's own inverse Star-Tetrix.

### Setup

- SVT-JPEG-XS tag `v0.10.0`, built from source. CMake 4.4.5 (Homebrew), Apple clang 21, arm64.
  Release build, `-j4`, with `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`. The NEON build
  succeeded and `SvtJpegxsDecApp --help` runs. The level-7 decode was repeated with
  `--asm c` (plain C paths) and `--asm neon`; both fail identically, so SIMD is not a factor.
- A normalisation script makes the test codestreams (levels 0 to 7, cumulative).
- A run script runs every level through `SvtJpegxsDecApp` and converts
  any picture to int32. No level produced a picture, so nothing reached the int32 step.
- A probe program calls the public API directly (`get_single_frame_size` with a
  full scan, then `decoder_init`), because the sample app's own frame-size scan fails
  first and hides the header parser's answer.
- A check program compiles SVT's `Mct.c` unchanged and runs
  `inverse_star_tetrix()` on the reference `planes_st`.

### Normalization attempts and SVT's answers

Frame 0 shown. Frames 100 and 818 give the same answer at every level (only the byte
counts in the level 7 message differ). "Silent" means SVT returns
`SvtJxsErrorDecoderInvalidBitstream` (0x80003001) without a message; the field named is
the check in `Source/Lib/Decoder/Codec/ParseHeader.c` that rejects it.

| Level | Change (cumulative) | Note section | SVT answer |
| --- | --- | --- | --- |
| 0 | wrapper dropped (codestream from SOC) | 2 | app: "Unable to get first frame size"; init: 0x80003001 silent. CAP body is 32 bytes = 256 bits, above SVT's `MAX_CAPABILITY` of 16 bits |
| 1 | + CAP body emptied (Lcap 34 → 2) | 3.1, 4.1 | init: `Picture header size invalid, expected=26, read=39!` |
| 2 | + 13 PIH vendor bytes dropped, Lpih 39 → 26, Lcod fixed | 3.2, 4.2 | init: 0x80003001 silent: Fq = 4 with Bw = 18. SVT accepts only Fq = 0, (Bw 18, Fq 6) or (Bw 20, Fq 8) |
| 3 | + Fq 4 → 6 | 4.6 | init: 0x80003001 silent: Ppoc = 1. SVT accepts only Ppoc = 0 |
| 4 | + Ppoc 1 → 0 | none (the note gives Ppoc = 1 but does not discuss it) | init: 0x80003001 silent: CDT length 14 ≠ 2 × Nc |
| 5 | + CDT 3 → 2 bytes per component, CWD added with Sd = 1 | 3.3, 4.4 | init OK (6060 × 3410, 14 bit, 4 components). Decode: `First precinct in Slice could not have Vertical Prediction!` in slices 0 to 52 (no separate message for slice 53; at this level SVT still takes 6060 × 3410 as the component size); no picture |
| 6 | + Cpih 0 → 3, CTS (Cf 0, e1 0, e2 0), CRG for CFA type 0, Wf/Hf → 3030/1705, Lh = 1, WGT in SVT's band order | 3.5, 4.3, 4.5, 4.8, 10.1 | init OK (3030 × 1705). Decode: same error as level 5, in all 54 slices; no picture |
| 7 | + D[b] bit 0 cleared in the first precinct of each slice | 5.6 | Decode: `(GCLI) corruption detected - unpacked=364 , expected=361` in all 54 slices; no picture |

Separate checks on the level-7 stream: setting back only Fq = 4, or only Ppoc = 1, makes
`decoder_init` fail again (0x80003001). Setting back only Cpih = 0 is accepted.

Levels 3 and 4 are not lossless: level 3 changes the dequantizer scale (2^6 instead of
2^4), and level 4 only relabels a packet layout that stays as it is. They were needed to
reach the packet layer and measure the next point of divergence.

### First point of divergence

Slice 0, precinct 0, packet 1, GCLI sub-packet (the same point in every slice of every
frame).

- SVT reads the precinct header and the first packet header correctly: Lprc = 9072,
  Q = 4, R = 0, then Dr = 0, Ldat = 1062, Lcnt = 361, Lsgn = 318.
- SVT then decodes the GCLIs of the bands that its packet 0 holds. For NLx = 5, NLy = 1,
  Sd = 1 and Ppoc = 0 (`Pi.c`, `calc_packet_inclusion`), packet 0 holds the 5 coarsest
  line-0 bands of all 3 transformed components (15 bands, components interleaved band
  by band). SVT has 6 packets per precinct: {levels 0–4 of components 0–2},
  {line-1 low-pass of 0–2}, {line-0 level-1 high-pass of 0–2}, {line-1 high-pass of 0–2},
  {untransformed component, line 0}, {untransformed component, line 1}.
- The clip's packet 1 holds the 6 line-0 bands of component 0 only (note 5.4: 8 packets,
  one per line and component).
- So SVT reads 364 bytes of GCLI data where the packet has 361, and stops with the
  corruption error.

### Other differences that block a bit-exact SVT route

Each of these would stop ROUTE=svt even if the packet layout were the same.

1. **Untransformed component position.** SVT's CWD (Sd) makes the last Sd components
   untransformed. The clip's untransformed component is component 2 of 4 (note 3.3).
   SVT also numbers bands level-major (band index = level × 3 + component, then the Sd
   component; `Pi.c`, `pi_compute`), the clip numbers them line, component, band
   (note 5.3).
2. **Dequantizer scale.** SVT shifts every dequantized magnitude left by Fq and accepts
   Fq = 4 only if Bw is changed in a way it also rejects (Fq 0, 6 or 8 only). The clip
   needs a shift of 4 (note 6). Fq = 6 multiplies the coefficients by 4 more, and integer
   5/3 lifting does not scale exactly, so the result is not a constant shift of the
   reference.
3. **Output scaling and clamp.** SVT outputs
   `clamp((v + 2^(Bw−1) + 2^(Bw−B−1)) >> (Bw − B), 0, 2^B − 1)` (`NltDec.c`,
   `linear_output_scaling_16bit_line_c`); B must be 8 to 16. With Bw = 18 and B = 14 this
   drops the 4 least significant bits. In `cfa_companded`, 19,372,609 of 20,664,600
   samples of frame 0 (93.7 %) have non-zero low 4 bits (19,374,729 and 19,372,557 for
   frames 100 and 818). Also, 1,215 samples of frame 0 (1,347 and 1,120 for frames 100
   and 818) lie outside −32768 to 32767, so even a 16-bit output (B = 16, which needs
   Bw = 16 and then Fq = 0) could not hold them unclamped.
4. **Star-Tetrix grid orientation.** See the next section. No constant plane reorder makes
   SVT's inverse Star-Tetrix match the clip on the untransposed grid.

### SVT's inverse Star-Tetrix against the reference (stage check)

`mct_check` gives the reference `planes_st` to SVT's `inverse_star_tetrix()` with Cf = 0,
e1 = e2 = 0, for all 24 assignments of the clip components to SVT's 4 slots, both SVT
CFA types (ct 0 and 1), on the planes as they are and transposed. Each SVT output plane is
compared with each `cfa_companded` plane, and the best plane matching is kept.

| Frame | Best of the 48 untransposed runs (mismatches of 20,664,600) | Transposed, ct = 0, slots ← clip (0, 3, 1, 2), outputs → ref planes (1, 2, 0, 3) |
| --- | --- | --- |
| 0 | 20,610,463 | 0 |
| 100 | 20,611,118 | 0 |
| 818 | 20,608,943 | 0 |

Every other run (all other slot assignments, ct = 1, or the untransposed grid) fails at
more than 99.6 % of the samples.

So the TICO RAW inverse Star-Tetrix (note section 8) equals the standard Star-Tetrix as
SVT implements it (Tables F.4 to F.12: average, delta, Y and CbCr steps, mirror borders)
with Cf = 0 and e1 = e2 = 0, for CFA type 0, on the transposed component grid:

- SVT slot 0 (the "average" green) = clip component 0 (A, Gr);
- SVT slot 1 = clip component 3 (F, B); SVT slot 2 = clip component 1 (C, R);
- SVT slot 3 (the "delta" green) = clip component 2 (E, Gb);
- SVT outputs 0, 1, 2, 3 (after its own plane swap) = `cfa_companded` planes 1, 2, 0, 3.

In other words, SVT's CFA type 0 puts the average green at offset (0, 1) of each 2 × 2
quad and the delta green at (1, 0). The clip puts the average green at (1, 0) and the
delta green at (0, 1). SVT's CRG handling (`get_cfa_pattern`) knows only its two fixed
types, so no CRG value expresses the clip's layout to SVT. The edge-repeat border rule of the format note (section 8)
gives the same result as SVT's mirror rule here (0 mismatches includes the borders).

### Notes on the comparison

`compare_stage.py` was not run on SVT output, because SVT wrote no picture at any level.
The Star-Tetrix stage check is built into the check program (it counts mismatches per plane, the
same test that `tools/compare_stage.py` applies).

Not tested here: SVT's inverse wavelet against `planes_st` (the packet layer failed first,
and SVT's wavelet runs line by line inside its precinct pipeline).

## Decoder baseline: frame threads

Measured 2026-11-08 with the native `tico_raw` decoder (Bayer output), on an Apple Silicon
Mac (M-series). Build: an out-of-tree FFmpeg build (default `-O3`, no hwaccel). Other work ran
on the Mac at the same time, so take the numbers as approximate.

Command (decode only, no output file; audio dropped with `-an`):

```
/usr/bin/time -l ffmpeg -nostdin -v error -threads 0 -i A015_C004_0706JH.R3D -an \
    -frames:v 200 -f null -
```

| Run | Threads | Frames | Wall time | Decode speed | Peak RSS |
| --- | --- | --- | --- | --- | --- |
| 1 | `-threads 0` (auto: one frame thread per CPU thread) | 200 | 2.89 s | 69 fps | 2,808 MB |
| 2 | `-threads 0` | 200 | 2.57 s | 78 fps | 2,810 MB |
| 3 | `-threads 0` | 200 | 2.62 s | 76 fps | 2,810 MB |
| reference point | `-threads 1` | 50 | 5.79 s | 8.6 fps | 246 MB |

- The speed includes process start, demuxing and the 7.75 MB reads per frame from the
  internal SSD.
- Each frame thread holds its own decoder core (four int32 planes, about 83 MB) and its
  own output frame (41 MB). So peak RSS grows by about 160 MB per thread. A player
  should cap the thread count where memory matters.
- One frame thread decodes about 8.6 frames per second, so real-time playback at 25 fps
  needs at least 3 frame threads on the test machine.

## Slice threads: single-frame decode latency (2026-11-08)

Build: an out-of-tree FFmpeg build (branch `tico-raw`, with slice threads, default `-O3`). Output: the default Bayer view
(`bayer_rggb16le`, 6060 × 3410).

Tool: `tools/decode_latency.c` (the build command is in its header comment). It opens one
`tico_raw` decoder context, decodes frame 818 (`testdata/samples/f0818.bin`) once cold
(the core allocates its buffers), then 10 more times warm, as a player does after a seek
with the same context. Each time runs from `avcodec_send_packet()` to the end of
`avcodec_receive_frame()`.

```
decode_latency testdata/samples/f0818.bin 1 none 10
decode_latency testdata/samples/f0818.bin 8 slice 10
```

| Threads | Cold | Median of 10 warm | Fastest | Slowest | Speed-up (median) |
| --- | --- | --- | --- | --- | --- |
| `-threads 1` | 170.2 ms | 161.7 ms | 161.1 ms | 162.6 ms | 1.0× |
| `-thread_type slice -threads 8` | 26.7 ms | 25.2 ms | 22.5 ms | 28.7 ms | 6.4× |

- Two earlier runs of the same pair, a minute before, gave medians of 162.8 ms and
  162.6 ms (1 thread) and 32.3 ms and 22.4 ms (8 slice threads). The slice-thread time
  varies more, because it depends on what else runs on the same cores.
- With `-threads 15` (all cores) the median was 25.0 ms: more than 8 slice threads gives
  no gain for one frame at this point.
- Where the time goes (one frame, in-process timing of the decoder core): entropy
  decoding of the 54 slices about 115 ms with 1 thread and 14 ms with 8; inverse wavelet
  about 14 ms and 3 ms; inverse Star-Tetrix about 23 ms and 5 ms; the plane-to-mosaic
  step about 10 ms with 1 thread. Entropy decoding is the largest cost in both cases.

50 frames, wall clock, `ffmpeg -an -frames:v 50 -f null -` (check `check_slices` of
`tests/decoder_checks.sh`): `-threads 1` 8.6 s, `-thread_type slice -threads 8` 1.65 s
(5.2×). This includes process start, demuxing and reading 7.75 MB per frame.

## Rec.709 view (2026-11-08)

Build: an out-of-tree FFmpeg build (branch `tico-raw`). The view follows the oracle's viewing transform, format note
section 12, at the view's own size: half = one pixel per quad (12.3 quad sampling at
ow = cw), full = the full demosaic of 12.3 (untested against the oracle, as the note
says). The 4:2:0 P010 step and the HEVC step of the oracle are not part of the view.

A first version followed a guessed pipeline (BT.709 OETF, no exposure gain). It gave SSIM All
0.219, 0.230 and 0.230 and a view about 3 EV darker than the oracle. It was replaced by the
pipeline of section 12.

### Against the oracle render (`check_view_oracle`)

Which references the check uses, and why:
- `testdata/ref/view-p010/` (the check's default, `VIEW_REF`): the oracle's exact P010
  frames (format note 12.8 step 2: 10-bit 4:2:0, BT.709, limited range), captured before
  its lossy HEVC step, converted by FFmpeg to rgb48 1920 × 1080 with
  `scale=in_color_matrix=bt709:in_range=tv:out_range=full`. They hold the oracle's
  transform without compression loss.
- `testdata/ref/view/`: the oracle's HEVC renders. Their HEVC loss caps the SSIM below
  0.85 even for the oracle's own method (frames 100 and 818, see below), so the check no
  longer uses them. They stay as stills for a visual comparison.

Our half view (`-view rec709 -view_size half`, exposure 0) is scaled to 1920 × 1080 with
`scale=1920:1080:flags=lanczos`. Then it makes the same 4:2:0 round trip as the
references: `yuv420p10le` with the BT.709 matrix and limited range, and back to rgb48 with
the BT.709 matrix and full range. SSIM comes from the FFmpeg `ssim` filter (system FFmpeg
9.0.2). Means are of the 16-bit full-range values after the round trip. The threshold is
SSIM All ≥ 0.85 after the round trip, with the same channel-mean order.

Against the exact P010 references (`testdata/ref/view-p010/`, the check):

| Frame | SSIM All, round trip | SSIM All, direct | Ours R / G / B | Oracle R / G / B | Order (both) |
| --- | --- | --- | --- | --- | --- |
| 0 | 0.948 | 0.790 | 25658 / 23894 / 28156 | 25712 / 23937 / 28241 | B > R > G |
| 100 | 0.948 | 0.796 | 26096 / 24232 / 28645 | 26142 / 24270 / 28730 | B > R > G |
| 818 | 0.947 | 0.786 | 25737 / 23958 / 28172 | 25769 / 23981 / 28238 | B > R > G |

`check_view_oracle` passes on all three frames. The means agree within 0.4 %. The rest of
the difference comes from the resize: our view is one pixel per quad scaled with lanczos
after the colour steps, while the oracle decimates the linear raw planes bilinearly to
1920 wide before the colour steps (12.3).

Against the HEVC renders (`testdata/ref/view/`, for reference only):

| Frame | SSIM All, round trip | SSIM All, direct | Section 12 model at 1920, round trip |
| --- | --- | --- | --- |
| 0 | 0.909 | 0.750 | 0.936 |
| 100 | 0.829 | 0.692 | 0.828 |
| 818 | 0.817 | 0.676 | 0.809 |

The last column is a double-precision model of section 12 at the oracle's own 1920 × 1080
sampling. Frame 0 agrees with the note's 0.937 (12.11). On frames 100 and 818 even the
oracle's own method stays below 0.85 against these files, so their HEVC loss sets the
limit.

### Correctness

- `check_view_example` (format note 12.10 worked example, through
  `ff_ticoraw_view_pixel` in the test program's `view_example` stage): mid-grey 34145,
  white-balanced 0.18 65212, sensor white 65535, the same in R, G and B, exactly the
  note's codes.
- An independent double-precision Python model of 12.2 to 12.8 step 1, run on the Bayer
  dump of frame 0, matches the decoder within 1 code (about 0.5 % of pixels differ by 1)
  on 20,000 sampled pixels each of: half view (R3D, F = 2^−0.5), half view at +1.5 EV,
  half view of the N-RAW copy (F = 1, its own matrix), and full view with its edges and
  corners.
- `check_view_highlights`: frame 0 has 7 quads with all four CFA samples at 16383. In all
  7, R = G = B (largest difference 0).
- `check_view_threads`: 30 frames, same framemd5 with `-threads 1`, `-thread_type frame
  -threads 4` and `-thread_type slice -threads 8`. Full view under ASan and UBSan, 3
  frames at −1.25 EV: no report, and the same framemd5 with 1, slice 8, frame 4 and
  frame+slice 8 threads.

### Speed (50 frames, wall clock, `-f null`, includes process start)

| Threads | Bayer | Rec.709 half | Rec.709 full |
| --- | --- | --- | --- |
| `-threads 1` | 8.77 s | 18.09 s | 71.03 s |
| `-thread_type slice -threads 8` | 1.71 s | 3.43 s | 12.71 s |

The half view adds about 190 ms per frame on one thread: per channel two `powf` (tone map
and the power 1/2.4), no lookup tables, no SIMD. With 8 slice threads it runs at about
15 fps, below the 25 fps target. The next section covers the speed work. The full view runs the 12.3
demosaic with 8 bilinear samples per pixel and is not tuned.

## Speed and memory for IINA RAW (2026-11-08)

IINA RAW defaults: vd-lavc-threads=12, thread_type=slice

In IINA RAW this is `vd-lavc-threads=12` together with
`vd-lavc-o=view=rec709,view_size=half,thread_type=slice`.

Build: an out-of-tree FFmpeg build (branch `tico-raw`, default `-O3`).
Machine: an Apple Silicon M-series Mac (thread counts up to all of its cores). Other work ran on the Mac at the
same time.

Command (one run at a time, after one warm-up run so the clip is in the file cache):

```
/usr/bin/time -l ffmpeg -nostdin -v error -c:v tico_raw -view rec709 -view_size half \
    [-thread_type T] -threads N -i A015_C004_0706JH.R3D -an -frames:v 300 -f null -
```

fps = 300 / wall-clock time (includes process start and demuxing). RSS = "maximum
resident set size" of `/usr/bin/time -l`. "default" = no `-thread_type`, so FFmpeg's
`frame+slice`; FFmpeg then picks frame threads.

### What was changed

A profile of the old build (`sample`, 8 slice threads, 8 s) put 40 % of the busy CPU
time in `powf` (two calls per channel in the view's tone curve), 16 % in the view loop
itself, 30 % in entropy decoding and 14 % in the inverse wavelet and Star-Tetrix. The
view now reads:
- N(Lin(i)) (format note 12.2) from a 65536-entry float table, rebuilt for each frame
  with the same float operations (identical values);
- the full view's column taps from per-frame tables (identical values);
- the tone map, shoulder and power 1/2.4 of 12.7 with the quantisation of 12.8 step 1
  from one table of 5249 entries (128 per octave of the input from 2^−40 to 2), read with
  linear interpolation. An exhaustive test over every float from 0 to 4 (1,082,130,433
  inputs), larger floats, infinities and NaN found no code more than 1 from the old
  formula; 0.16 % of the inputs differ by 1.

After this change the profile (12 slice threads) shows entropy decoding at 52 % of the
busy time, the view loop at 20 % and the wavelet and Star-Tetrix at 27 %. 30 fps was
reached, so no NEON code was written.

### Before and after (fps / peak RSS)

| Threads | frame, before | frame, after | slice, before | slice, after | default, before | default, after |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | 5.7 / 354 MB | 9.9 / 355 MB | 5.7 / 207 MB | 9.7 / 207 MB | 5.7 / 354 MB | 9.9 / 355 MB |
| 3 | 8.5 / 471 MB | 14.7 / 472 MB | 8.4 / 207 MB | 14.3 / 207 MB | 8.5 / 471 MB | 14.6 / 472 MB |
| 4 | 11.1 / 618 MB | 19.2 / 619 MB | 10.9 / 207 MB | 18.3 / 208 MB | 11.1 / 618 MB | 19.2 / 619 MB |
| 6 | 14.5 / 912 MB | 24.5 / 913 MB | 14.1 / 207 MB | 23.7 / 208 MB | 14.1 / 912 MB | 24.2 / 913 MB |
| 8 | 16.0 / 1208 MB | 28.0 / 1208 MB | 16.1 / 207 MB | 27.0 / 208 MB | 15.9 / 1206 MB | 28.1 / 1208 MB |
| 12 | 18.4 / 1796 MB | 33.4 / 1799 MB | 18.7 / 208 MB | 31.8 / 208 MB | 18.5 / 1794 MB | 33.3 / 1797 MB |

Extra runs after the change: `-thread_type slice -threads 12` twice more, 31.4 and
32.1 fps; `slice -threads 10` 30.1 fps; `slice -threads 15` 31.6 fps;
`frame -threads 10` 31.9 fps at 1505 MB.

### Choice

- Frame threads use about 145 MB per thread (one core with its planes and one output
  frame each). 12 frame threads pass 30 fps (33.4 fps) at about 1.8 GB: over the 1.5 GB
  limit. 10 frame threads also pass 30 fps (31.9 fps) at 1505 MB, which is at the limit,
  and a frame thread decodes one frame alone, so the single-frame latency stays about
  196 ms (see below). RSS in this table is the "maximum resident set size" of
  `/usr/bin/time -l` (bytes on macOS), shown in MB. The table does not record whether
  1 MB is 10^6 or 2^20 bytes (a 4.9 % difference).
- Slice threads stay at about 208 MB at every count. 12 slice threads give 31.4 to
  32.1 fps over three runs. 10 slice threads gave 30.1 fps, with no headroom, so the
  choice is 12. More than 12 gives nothing (15: 31.6 fps): entropy decoding of the
  54 slices and the passes between them set the limit.
- Single-frame latency (seek proxy, `tools/decode_latency.c`, frame 818,
  `view=rec709,view_size=half`, median of 10 warm decodes): `slice 12` 23.8 ms and
  28.6 ms (two runs), `slice 10` 32.5 ms, `frame 8` 196.5 ms (a frame thread decodes one
  frame alone), 1 thread 196.9 ms. Slice threads keep a seek far below the 200 ms target.

### Equality

- Bayer output: the Bayer code is unchanged; every decoder check passes.
- View, old exact formula against the tables, 8 slice threads, every sample of the frame:
  half view frames 0, 100 and 818, largest difference 1 code (1.96 %, 2.00 % and 1.97 % of
  samples differ by 1); full view frame 0, largest difference 1 code (1.98 %).
- `check_view_example`, `check_view_oracle` and `check_view_highlights` pass unchanged.

## FFmpeg 9.0.2 port and IINA deps (2026-11-14)

- Port: branch `tico-raw-9.0` of the FFmpeg fork, from tag `n9.0.2`, with the same decoder. One
  conflict, in `codec_id.h` and `codec_desc.c`: `master` has the codec ids `ASTC`, `RW2` and
  `IMM6`, 9.0.2 does not. The port keeps only `AV_CODEC_ID_TICO_RAW`. All decoder files are
  byte-identical to the `tico-raw` branch. No FFmpeg-internal API needed a change.
- Small test build (same `./configure` options as the `master` build): configure 46 s,
  `make -j4` 20 s, plus `libavcodec/tests/ticoraw`.
- `FFMPEG_BUILD=<9.0.2 build> tests/decoder_checks.sh all`: 25 PASS, 0 FAIL, 3 min 22 s. The values
  are the same as on `master`, for example `check_view_oracle` SSIM 0.947543, 0.948030 and
  0.947047 for frames 0, 100 and 818, and `check_slices` 8.792 s with 1 thread and 2.144 s with
  8 slice threads for 50 frames.
- Deps: `iina/deps-buildscripts` at `ee35579d` plus two changes (`build/patches/` in this
  repo): the FFmpeg patch `ffmpeg-9.0.2-tico_raw.patch` (about 3600 lines), and a one-line change
  that lets `JOBS` come from the environment (`common.sh` hard-coded the CPU count). The
  existing `apply_patches` step in `build-ffmpeg.sh` applies the patch; the FFmpeg configure
  flags have no explicit decoder list, so `tico_raw` builds by default.
- Build: `JOBS=4 ./build.sh arm64`. The first run stopped at package 11 (zimg) because `libtool`
  (`glibtoolize`) was missing on the test Mac; `brew install libtool` fixed it. The second run built
  the remaining 22 packages, zimg to mpv, in 11 min 0 s (the first 10 packages took about 5 min in
  the first run). Then `./fix-install-names.sh arm64` (47 libraries) and `./copy-headers.sh`.
- Result: `output/arm64/` holds `libavcodec.63.dylib`, `libavformat.63.dylib`, `libmpv.2.dylib`
  and the other dylibs (flat folder, `@rpath` names). The install prefix is `install/arm64/lib`.
- `tests/test_deps_build.py`: before the build FAIL (no libavcodec dylib), after the build PASS
  (`tico_raw` is in libavcodec; video stream 0 of the test clip uses the `tico_raw` decoder).

## Playback in IINA RAW (2026-11-14)

What ran: `tests/test_playback.sh`, which runs `tests/mpv_harness.py` (Python `ctypes`, standard
library only) against the libmpv inside the installed app,
`/Applications/IINA RAW.app/Contents/Frameworks/libmpv.2.dylib` (mpv 0.41.0, FFmpeg 9.0.2,
client API 131077). The harness first loads every dylib of that folder, because they use
`@rpath` names. It uses the app's own defaults: `vd-lavc-threads=12` and
`vd-lavc-o=view=rec709,view_size=half,thread_type=slice`, with `vo=null`, `untimed=no` and
`audio=no` (`ao=null` with audio in the audio run). Machine: an Apple Silicon Mac (M-series). Other
work ran on the Mac at the same time (load average 8 to 9). One heavy run at a time.

Test clip: `A015_C004_0706JH.R3D`, 819 frames, 25 fps, 32.76 s. Decoder `tico_raw`, output
3030 × 1705, `gbrp16`, Rec.709 full range.

| Check | Threshold | Measured (script run 1 / run 2) |
| --- | --- | --- |
| probe | `tico_raw`, 3030 × 1705, `gbrp16` | pass, pass |
| play 20 s, `estimated-vf-fps` | ≥ 24.5 | 25.00 / 25.00 (steady, min 25.00) |
| play 20 s, achieved rate (frames per wall second) | report | 24.96 / 24.96 (500 frames in 20.03 s) |
| `decoder-frame-drop-count`, `frame-drop-count` | 0 | 0, 0 / 0, 0 |
| peak RSS, 20 s | ≤ 1.5 GB | 385 MB / 385 MB |
| untimed (`untimed=yes`), whole clip, max decode rate | ≥ 25 fps | 59.07 fps / 54.16 fps (809 frames in 13.70 s / 14.94 s); no drops |
| play 120 s (`loop-file=inf`), RSS 20 s to 120 s | growth ≤ 10 % | 367 → 362 MB (−1.52 %) / 362 → 366 MB (+0.99 %); 0 drops |
| seek, 30 seeks, seed 20261114, time to `playback-restart` | every seek restarts, p95 ≤ 200 ms, max ≤ 400 ms (see below) | max 60.4 ms (median 45.2) / max **316.7 ms** (median 46.6, p95 about 50): passes the rule |
| audio, codec | `pcm_f32le` | `pcm_f32le` |
| audio, `avsync`, 10 samples in 10 s | within ±0.1 s | largest 0.0026 s (first sample), the rest 0.0000 s |

`estimated-vf-fps` with `vo=null` is the container rate (it comes from frame timestamps),
so it shows 25.00 whenever the clip keeps up. Two numbers show the real speed: the achieved
rate (`estimated-frame-number` per wall second, 24.96 at real-time pace, no drops) and the
untimed run, where mpv plays as fast as it can decode: 54 to 59 fps. Earlier, the
same decode ran at 31 to 32 fps in `ffmpeg -f null`. The same check run later with the
9.0.2 build of `ffmpeg` (300 frames, 12 slice threads) gave 55.7 fps (5.39 s), so libmpv and the
FFmpeg tool agree (57 fps in mpv). The Mac was probably more loaded during the earlier run (or the
core clocks differed). Treat the high figure as the more recent measurement on a busy Mac.

### Seek time and the one outlier

Each seek is `seek <t> absolute+exact` while the clip plays, from the command to the next
`playback-restart` event, with 0.35 s between seeks (the harness prints every seek).

| Run | Max (ms) | Median (ms) |
| --- | --- | --- |
| script run 1 | 60.4 | 45.2 |
| script run 2 | **316.7** | 46.6 |
| repeat 1 to 5, same seed | 62.0, 159.7, 57.9, 59.1, 57.3 | 46.0 to 48.6 |
| paused, same seed | 57.4 | 37.5 |

All 210 seeks (7 runs of 30): median 46.6 ms, 90th percentile 53.2 ms, 99th 112.5 ms, 4 seeks
above 100 ms and 1 seek above 200 ms (316.7 ms, at 31.243 s in script run 2). The slow seeks
land on different times in different runs (run 2: 31.243 s; repeat 2: 7.587 s), so no time
in the clip is slow. The Mac was busy at those moments (load average above 8).
With 12 slice threads the decoder waits for the slowest thread, so one preempted thread
delays a frame. Verdict: typical seek 45 to 60 ms (far below 200 ms), with rare spikes under
load. The first strict threshold (the maximum of 30 seeks ≤ 200 ms) failed in 1 of 7 runs.

Rule of the check: it passes when, over the 30 seeded seeks, every seek ends with a
`playback-restart` event, p95 ≤ 200 ms and max ≤ 400 ms. Reason: over 210 seeks the median is
46.6 ms and the 99th percentile 112.5 ms. The only seek above 200 ms was one spike of 316.7 ms
at a load average of 8 to 9 (other work on the Mac). One preempted thread must not fail a
run, but a slow typical seek or a seek that never restarts must. The harness seek JSON now has
`p95_ms` (nearest rank, the 2nd largest of 30), `median_ms`, `max_ms`, `all_restarted` and
`loadavg_1min` (the 1-minute load average at the start of the run).

### Stock N-RAW copy (`testdata/ref/A015_C004_nraw.NEV`, report only)

Same options as above. Probe: `tico_raw`, 3030 × 1705, `gbrp16`, first frame after 52 ms.
Play 10 s: 24.94 fps achieved, `estimated-vf-fps` 25.00, 0 drops, peak RSS 396 MB.
Untimed whole clip: 53.1 fps (809 frames in 15.23 s), 0 drops, peak RSS 369 MB.

### Other views (report only; the test clip, the same libmpv)

| Option | Result |
| --- | --- |
| `view_size=full`, timed 10 s | 6060 × 3410; 79 frames dropped; achieved 18.6 fps; peak RSS 652 MB |
| `view_size=full`, untimed | 15.6 fps (238 frames in 15.2 s); peak RSS 533 MB |
| `exposure=1` (half) | opens, 3030 × 1705 `gbrp16`, no warning |

### Real app smoke test (no picture looked at)

`open -a "IINA RAW" <clip>`, 10 s later: process running, RSS 618 MB, CPU 525 %, `lsof` shows
the clip open. At 15 s and 20 s: RSS 617 MB, CPU about 500 %. No IINA RAW crash report in
`~/Library/Logs/DiagnosticReports/` (0 before, 0 after). Quit with
`osascript -e 'quit app "IINA RAW"'`: the process ended, none left. An earlier launch resumed at
32.36 s, because an earlier test run had saved the end position (`save-position-on-quit`). The
app then stopped at the end of the clip after 0.4 s, with no CPU use. That is how IINA behaves;
`docs/HOW-TO-USE.md` explains the setting.

### Chosen settings

IINA RAW keeps `vd-lavc-threads=12` and
`vd-lavc-o=view=rec709,view_size=half,thread_type=slice`. They give real-time playback with
0 dropped frames and about 2 times headroom (54 to 59 fps untimed), at 0.4 GB (harness)
and 0.6 to 1.0 GB (whole app). The user guide is `docs/HOW-TO-USE.md`.

## Quick Look: thumbnails and preview (2026-11-14)

IINA RAW has two Quick Look extensions (`RawThumbnail.appex` and `RawPreview.appex`) over a
shared frame-grabber module. The checks are in `tests/decoder_checks.sh`
(`check_frame_grabber`, `check_ql_thumbnail`, `check_ql_preview`,
`check_ql_preview_playback`).

| Item | Result |
| --- | --- |
| Frame grabber: one frame, long side 512 | 512 × 288, mean luminance 34.6 %, about 0.23 s |
| Finder thumbnail through `QLThumbnailGenerator`, new copy of the clip each time (no cache) | 512 × 288, about 0.3 s per clip once the extension process is warm (0.5 to 0.9 s on a cold start) |
| Clip info line | `3030×1705 · 25 fps · 00:33 · ISO 6400 · TICO RAW` |
| Preview playback (view controller in a test window, 5 s) | 22.0 to 24.5 fps at a load average of 5 to 6; the preview paces itself at the clip's frame rate (25 fps) and uses 6 decoder threads |
| Preview memory | about 266 MB for the process that plays (a still frame alone needs about 185 MB) |
| Stops | 0 frames shown after the preview closes; playback pauses when the window is covered |

The preview plays at about 22 to 24 fps and uses about 270 MB. The speed depends on machine
load. Both numbers are inside the limits of the checks (at least 20 fps, below 600 MB).
