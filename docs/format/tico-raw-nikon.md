# TICO RAW in Nikon R3D NE and N-RAW: format note

This note describes the video format of Nikon R3D NE (`.R3D`) and N-RAW (`.NEV`) clips: the
container facts, the per-frame Nikon wrapper, and the TICO RAW codestream (a JPEG XS
variant) down to the linear Bayer mosaic. It holds facts only, as prose, tables and math.

Sources of the facts:
- the bytes of the test clip `A015_C004_0706JH.R3D` (Nikon ZR, 6060×3410, 25 fps,
  819 frames) and of its N-RAW rewrap;
- the behaviour of the reference decoder (the test oracle, built as a black box by
  `oracle/run.sh` and `tools/oracle_render.sh`), whose output in `testdata/ref/` is the
  ground truth for this project. That folder is git-ignored: make it with the oracle scripts.

"The reference" below always means that oracle. A statement marked **unverified** is a
belief that neither the clip bytes nor the reference confirm. A statement marked
**unknown** names something that nobody here has worked out.

### Notation

- All multi-byte fields in the container, the wrapper and the codestream are big-endian.
- Bits are numbered from the most significant bit (MSB) downward. Bit fields inside the
  codestream are read MSB first.
- ⌊a / 2^k⌋ is floor division. For negative a it rounds toward minus infinity. This is
  what an arithmetic right shift by k gives.
- min(max(a, lo), hi) clamps a to the range lo to hi.
- `cw` = width / 2 and `ch` = height / 2 (section 10.1).

## 1. Container and sample table facts

- The file is ISO base media (QuickTime/MP4 family). FFmpeg's `mov` demuxer opens it with no
  change.
- `ftyp`: major brand `niko`, minor version 1, compatible brand `niko`.
- Top-level boxes in the test clip, in order: `ftyp`, `moov`, `free`, `mdat`.
- `moov` holds two tracks:
  - a video track: handler `vide`, timescale 25000. Its `stts` has one entry: 819 samples
    of duration 1000, which gives 25 fps.
  - an audio track: handler `soun`, sample entry `lpcm` (FFmpeg reports `pcm_f32le`),
    48 kHz, 2 channels.
- Video sample entry:
  - the fourcc is `NR3D` in R3D NE files and `NRAW` in N-RAW files;
  - width and height are at bytes 32–35 of the entry (6060 and 3410 in the test clip).
  The entry width and height are the full coded mosaic size, the same as Wf and Hf in the
  codestream.
- Video sample table: `stsc` puts one sample in each chunk. `stsz` has one fixed sample
  size (7,750,656 bytes in the test clip). Chunk offsets are in `co64` (64-bit). So the
  offset of video sample i is entry i of `co64`. FFmpeg's demuxer already finds them.
- One video sample is one frame. Every frame is intra-coded and can be decoded alone.
  In the test clip every frame has the same size (constant bit rate).
- `moov/udta/NCDT` holds the camera's clip metadata. Its child boxes are `NCHD`, `NCTG`,
  `NCTH`, `NCVW`, `NCM1`, `NCM2` and `NCDB`.
- `NCTG` is a list of entries. Each entry is: u32 tag, u16 type, u16 count, then the value.
  The value is count × unit bytes long. The unit per type is 1, 1, 1, 2, 4, 8, 1, 1, 2, 4,
  8, 4, 8 for types 0 to 12, and 1 for any other type.
- Clip-level `NCTG` tags seen in the test clip:

| Tag | Type | Value in the test clip | Meaning |
| --- | --- | --- | --- |
| 0x00000002 | ASCII, 16 | `NIKON ZR` (NUL-padded) | camera model |
| 0x00000021 | u16 | 65 | format code (65 in R3D NE, 49 in N-RAW) |
| 0x00000022 | u16 | 6048 | active image width |
| 0x00000023 | u16 | 3402 | active image height |
| 0x00000026 | u16 | 4 | format code (4 in R3D NE, 2 in N-RAW) |
| 0x00000027 | u16 | 3 | format code (3 in R3D NE, 1 in N-RAW) |
| 0x01108832 | u32 | 6400 | ISO (the same value as the per-frame tag, section 2) |
| 0x02000005 | ASCII | `COOL WHT FL` | white balance preset name |
| 0x02000023 | undefined, 108 | contains `RWGLOG3G10` | recording gamma and gamut name |

- The active area (6048×3402) is the coded size minus 12 columns and 8 rows.
  **Unknown:** where the active area sits inside the coded mosaic. The decoder outputs the
  full coded mosaic, as the reference does.
- R3D NE and N-RAW use the same codestream, frame wrapper and container. A lossless
  rewrap changes only the sample entry fourcc, a few `NCTG` tags, and the per-frame tags
  0x01900011, 0x01900012 and 0x0200523D (section 2). The image data stays byte for byte
  the same.

## 2. Nikon frame wrapper

Each video sample starts with a Nikon wrapper and then the TICO RAW codestream. Boxes use
the ISO layout: u32 size (header included), then a fourcc.

Box structure of one sample, in order:

- `NRAW` box. Its size field equals the size of the whole sample. It contains:
  - `NRFM`, size 12: the 4 ASCII bytes `0100`.
  - `NRFH`, the frame header. It contains `NRHM` (size 12: `0100`), then one `NRMT` box
    per tag (list below).
  - `NRTH`. It contains `NRTI` (size 16: `0100`, then the u32 codestream length), then
    `NRTA` (zero bytes, padding).
  - the codestream, from SOC (0xFF10) to EOC (0xFF11).

- The size field of the `NRAW` box equals the size of the whole video sample. The
  codestream lies inside the `NRAW` box but is not a box itself.
- **Where the codestream is.** The codestream starts right after the last child box of
  `NRAW` (the child boxes start at byte 8 of the sample and follow each other by their
  size fields). It begins with SOC (0xFF 0x10), runs to the end of the sample, and its
  length equals the `NRTI` value (7,749,632 bytes in the test clip).
  - In the test clip, `NRTA` pads the wrapper to exactly 1,024 bytes, so the codestream
    starts at byte 1024 of every sample. This is not guaranteed; the box sizes are.
- **NRMT box:** u32 size, `NRMT`, then a u32 key, then the value.
  - The key is (group << 16) | tag. Group 0x0110 holds EXIF-like tags (the tag numbers
    are EXIF tag numbers). Group 0x0190 holds Nikon tags. Group 0x0200 holds blocks.
  - The value is size − 12 bytes long. It starts with one leading byte of **unknown**
    meaning, 0 in every tag seen. The payload follows that byte.
    All payload numbers are big-endian. Floats are IEEE-754 single precision.

NRMT tags in the test clip (frame 0):

| Key | Payload after the leading byte | Test clip | Meaning |
| --- | --- | --- | --- |
| 0x01100100 | u32 | 6060 | coded width |
| 0x01100101 | u32 | 3410 | coded height |
| 0x01100102 | u16 | 14 | bits per sample |
| 0x01100112 | u16 | 1 | EXIF orientation (unverified) |
| 0x0110829A | float32 | 0.0222 (1/45) | exposure time in seconds |
| 0x0110829D | float32 | 4.0 | f-number |
| 0x01108832 | u32 | 6400 | ISO → `meta.iso` |
| 0x01109204 | float32 | 0.0 | exposure bias |
| 0x0110920A | float32 | 74.0 | focal length in mm |
| 0x0110A302 | u16 columns, u16 rows, then one colour code per site, row by row (0 = R, 1 = G, 2 = B) | 2, 2, 0 1 1 2 | CFA pattern → `meta.cfa` = `RGGB` |
| 0x01900005 | 4 × float32 | | **unknown** |
| 0x01900006 | 5 × float32 | | **unknown** |
| 0x01900008 | 2 × float32 | −0.0078, +0.0078 | **unknown** |
| 0x01900009 | 2 × float32 | 1.673828125, 2.048828125 | as-shot white balance gains, red and blue (green = 1) → `meta.wb_gain` |
| 0x0190000B | 4 bytes | 06 06 04 04 | **unknown** |
| 0x0190000D | u16 | 15 | **unknown** |
| 0x01900010 | u16 | 4200 | **unknown** |
| 0x01900011 | 6 bytes | | format-specific constant (differs between R3D NE and N-RAW) |
| 0x01900012 | 9 × float32, row-major 3×3 | | matrix from white-balanced camera RGB to CIE XYZ (D65) → `meta.cam_to_xyz`; differs between R3D NE and N-RAW |
| 0x02000001 | 391 bytes, starts with `II` | | Nikon maker note (TIFF-style IFD, little-endian) |
| 0x0200523D | 64 bytes | | RED per-frame block (all zero in N-RAW) |

- The per-frame tags can change from frame to frame. Frames 0, 100 and 818 of the test
  clip have different wrapper bytes, but the same values for every tag that `meta` uses.
  Read `meta` from each frame's own wrapper.
- Only the tags marked → feed the frame JSON and the FFmpeg frame metadata.

## 3. Codestream markers and header fields

The codestream is a sequence of marker segments, then slices, then EOC. A marker is 2
bytes (0xFFxx). Every marker except SOC and EOC is followed by a u16 length L, which
counts itself and the body but not the marker. The test clip's header is 149 bytes long,
and it is the same in every frame tested.

| Order | Marker | Code | L | Body |
| --- | --- | --- | --- | --- |
| 1 | SOC | 0xFF10 | none | none |
| 2 | CAP | 0xFF50 | 34 | 32 bytes, vendor capability (below) |
| 3 | PIH | 0xFF12 | 39 | 37 bytes: 24 standard bytes + 13 vendor bytes |
| 4 | CDT | 0xFF13 | 14 | 3 bytes per component |
| 5 | WGT | 0xFF14 | 52 | 2 bytes per band (25 bands) |
| 6… | SLH | 0xFF20 | 4 | u16 slice index; precinct data follows (section 5) |
| last | EOC | 0xFF11 | none | none |

No other marker types occur (no COM, NLT, CWD, CTS or CRG). The reference reads marker
segments until the first SLH. It uses PIH, CDT and WGT, and it steps over every other
segment (CAP included) by its length. Only the markers above have been seen.

### 3.1 CAP (vendor capability)

- Body (32 bytes): the 16 ASCII bytes `CONTACT_INTOPIX_`, then 16 bytes. In the test clip
  those 16 bytes are 0xEF 0xC0 followed by 14 zero bytes.
- **Unknown:** what the 16 trailing bytes mean. They may be capability bits.

### 3.2 PIH (picture header)

Byte positions count from the first byte after L (the "PIH body").

| Bytes | Field | Bits | Test clip | Notes |
| --- | --- | --- | --- | --- |
| 0–3 | Lcod | 32 | 7,749,632 | codestream length in bytes, SOC to EOC inclusive, padding included |
| 4–5 | Ppih | 16 | 0 | profile |
| 6–7 | Plev | 16 | 0 | level |
| 8–9 | Wf | 16 | 6060 | mosaic width |
| 10–11 | Hf | 16 | 3410 | mosaic height |
| 12–13 | Cw | 16 | 0 | precinct width; 0 = full width |
| 14–15 | Hsl | 16 | 16 | slice height in precincts |
| 16 | Nc | 8 | 4 | components |
| 17 | Ng | 8 | 4 | coefficients per code group |
| 18 | Ss | 8 | 8 | code groups per significance group |
| 19 | Bw | 8 | 18 | nominal coefficient bit depth (not used by the arithmetic in this note) |
| 20 | Fq, Br | 4 + 4 | 4, 4 | Fq: fractional bits (section 6); Br: bits per raw GCLI (section 5.6) |
| 21 | Fslc, Ppoc, Cpih | 1 + 3 + 4 | 0, 1, 0 | Cpih = 0, see 3.5 |
| 22 | NLx, NLy | 4 + 4 | 5, 1 | global decomposition levels |
| 23 | Lh, Rl, Qpih, Fs, Rm | 1 + 1 + 2 + 2 + 2 | 0, 0, 1, 1, 0 | byte value 0x14 |
| 24–36 | vendor bytes V0 … V12 | 13 × 8 | 50 88 70 83 F0 15 23 D1 49 CD 3F 7F 07 | transfer curve (section 9) |

How this note uses the bits of byte 23:
- Qpih = 1: uniform inverse quantizer (section 6).
- Fs = 1: sign bits sit in their own sub-packet (section 5.8).
- Rm = 0: a significance flag of 1 means "every GCLI in this group equals its predicted
  value" (section 5.6).
- Lh = 0 and Rl = 0: see section 4.

### 3.3 CDT (component table)

Three bytes per component, in component order:

| Byte | Content | Test clip (components 0, 1, 2, 3) |
| --- | --- | --- |
| 1 | bit depth B[c] | 14, 14, 14, 14 |
| 2 | Sx in the high nibble, Sy in the low nibble | 0x11 for all |
| 3 | this component's decomposition levels: horizontal in the high nibble, vertical in the low nibble | 0x51, 0x51, 0x00, 0x51 |

So components 0, 1 and 3 have 5 horizontal levels and 1 vertical level. Component 2 has no
wavelet transform at all.

### 3.4 WGT (band weights)

For each band b, in the band order of section 5.3: one byte gain G[b], then one byte
priority P[b]. The test clip has 25 bands:

| b | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| G[b] | 3 | 3 | 2 | 2 | 1 | 1 | 2 | 1 | 1 | 0 | 0 | 0 | 0 |
| P[b] | 2 | 19 | 9 | 22 | 10 | 21 | 5 | 3 | 17 | 1 | 7 | 13 | 11 |

| b | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| G[b] | 2 | 1 | 1 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| P[b] | 6 | 4 | 16 | 0 | 8 | 14 | 20 | 18 | 15 | 23 | 12 | 24 |

The priorities are a permutation of 0 to 24. The number of WGT entries must equal the
number of bands from section 5.3.

### 3.5 Star-Tetrix with Cpih = 0

- The test clip stores Cpih = 0, which in ISO/IEC 21122 means "no colour transform".
  Even so, the four components are Star-Tetrix decorrelated, and the decoder must apply
  the inverse Star-Tetrix transform of section 8. Without it the output is wrong.
- **No field in the codestream is known to signal the Star-Tetrix.** The reference applies
  the inverse Star-Tetrix to every stream it accepts. It does not read Cpih at all, and the
  stream has no CTS or CRG marker.
- A decoder therefore knows from the profile as a whole. Treat a codestream as a
  Star-Tetrix TICO RAW stream when all of the following hold:
  - it comes from an `NR3D` or `NRAW` sample entry with the Nikon wrapper (sections 1–2);
  - a CAP marker is present and its body starts with `CONTACT_INTOPIX_`;
  - the PIH length L is 39 (37-byte body with the 13 vendor bytes);
  - the CDT has 3 bytes per component, and Nc = 4;
  - Cpih = 0.
- A stream that has a standard colour transform signalled (Cpih ≠ 0) has not been seen.
  Reject it (section 11).
- **Unknown:** whether a bit in the CAP trailing bytes or in the PIH vendor bytes means
  "Star-Tetrix".

## 4. Where TICO RAW differs from ISO/IEC 21122

This list compares the clip with the structure of ISO/IEC 21122-1 (JPEG XS core coding),
as far as it is known here. The standard text was not available while this note was
written, so every comparison with the standard is **unverified**. Phase 0 tests them with
SVT-JPEG-XS. A standard decoder will need at least items 1 to 7 handled before it can
decode the codestream.

1. **CAP marker.** The standard's CAP body is a small capability bit field. Here the body
   is 32 bytes and starts with an ASCII vendor string (3.1). A standard decoder may reject
   it or misread capability bits.
2. **PIH length.** The standard PIH has a 26-byte length (24-byte body). Here L = 39: the
   standard fields are followed by 13 vendor bytes that hold the transfer curve (3.2,
   section 9).
3. **Colour transform signalling.** The standard signals the Star-Tetrix transform with
   Cpih = 3 (with CTS and CRG markers); SVT-JPEG-XS decodes Star-Tetrix streams with
   Cpih = 3. This clip stores Cpih = 0 and has no CTS/CRG markers, but the components are
   Star-Tetrix decorrelated (3.5). A standard decoder will skip the inverse
   colour transform. The transform in section 8 has fixed weights (1/8 and 1/4) and repeats
   edge samples at the borders. **Unverified:** whether it equals the standard's
   Star-Tetrix for some CTS parameter values and CFA pattern type, and whether the
   standard's border rule is the same.
4. **CDT.** The standard CDT has 2 bytes per component (bit depth, sampling). Here it has 3:
   the third byte gives each component its own decomposition levels (3.3). The global NLx
   and NLy (5 and 1) apply to components 0, 1 and 3 only. Component 2 is not transformed
   at all. **Unverified:** the second edition of the standard has a marker (CWD) for
   components without decomposition. It is believed to apply to the last components only,
   but here the untransformed component is component 2 of 4.
5. **Band order and packets.** Bands are numbered by precinct line, then component, then
   band (5.3). The untransformed component's single band is coded on both lines of a
   precinct. **Unverified:** whether the standard's band and packet order gives the same
   sequence for this decomposition.
6. **Output scaling.** The reference multiplies every dequantized magnitude by 2^Fq
   (section 6) and never divides that factor out. After the inverse wavelet and the
   inverse Star-Tetrix it does not apply the standard's final steps (scaling to the
   component bit depth, DC level shift, clamp to B[c] bits). The values are used directly
   as companded codes: code index = value + 32768, clamped to 0 to 65535 (10.6, 10.7).
   This is a 16-bit code space, although CDT says 14 bits. A standard decoder's output
   will be at a different scale and offset. Phase 0 should check whether it equals
   `cfa_companded` after a fixed shift and offset.
7. **Transfer curve.** The camera compands the sensor values with a square-root curve.
   Decoding needs the inverse curve of section 9, whose parameters sit in the PIH vendor
   bytes. The standard signals non-linear transforms (second edition) with an NLT marker,
   and there is none here. **Unverified:** whether the curve equals the standard's
   quadratic NLT for some parameters.
8. **Packet header size.** Every packet header is 7 bytes (Dr 1 bit, Ldat 20, Lcnt 20,
   Lsgn 15), although Lh = 0. **Unverified:** in the standard, Lh = 0 selects the short
   (5-byte) header under some size condition. If that condition holds for this picture, a
   standard decoder will misread every packet.
9. **Padding.** Each precinct ends with zero bytes after its last packet; Lprc counts them
   (5.4). Precinct padding occurs in every precinct of the test clip (about 250,000 to
   290,000 bytes per frame). Between the last precinct and EOC there are no bytes in the
   three test frames. A decoder must still accept any bytes there (**unverified** that
   cameras ever write them). Lcod counts the whole codestream, so EOC is its last 2 bytes.
10. **Same as the standard, as far as known:** SOC/EOC, the marker length rule, the
    standard PIH fields, SLH, the precinct header (Lprc, Q, R, 2-bit coding modes), the
    GTLI rule, MSB-first bit packing, bit-plane interleaved magnitudes per code group, the
    separate sign sub-packet (Fs = 1), the significance flags (Rm = 0), vertical GCLI
    prediction, the uniform inverse quantizer (Qpih = 1), and the reversible 5/3 lifting
    filter with symmetric extension. Each of these is still **unverified** against the
    standard text.

## 5. Slices, precincts, packets and entropy coding

### 5.1 Geometry

- The codestream codes four components, each `cw` × `ch` (3030 × 1705 in the test clip).
- Precinct k holds component rows 2k and 2k + 1 (row 2k + 1 only when it is below
  `ch`, see 10.3), across the full width (Cw = 0). There are P = ⌈ch / 2⌉ precincts (853), numbered k = 0 to P − 1 from the top.
- A slice holds Hsl consecutive precincts (16). Precinct k is in slice ⌊k / Hsl⌋. There are
  ⌈P / Hsl⌉ slices (54). The last slice is shorter (5 precincts).
- Each precinct has two lines per component (line 0 and line 1; section 10.3).

### 5.2 Slice layout

- Each slice starts with SLH: 0xFF20, L = 4, then a u16 slice index (0, 1, 2, …).
- The precincts of the slice follow directly, one after the other. The next slice's SLH
  follows the last precinct of a slice. After the last slice, EOC follows, possibly
  after other bytes (section 4, item 9).
- Prediction state (5.6) starts fresh at every slice. Slices can be decoded independently
  once their start offsets are known. The only way to find a slice start is to walk the
  precinct lengths (Lprc) from the first slice.

### 5.3 Bands

- For each component with n ≥ 1 horizontal levels and one vertical level:
  - line 0 has n + 1 bands: the low-pass band after n levels, then the high-pass bands
    of levels n, n − 1, …, 1;
  - line 1 has 2 bands: horizontal low-pass, then horizontal high-pass.
  - The widths are those of section 10.4.
- A component with no wavelet has one band of width `cw`. It carries line 0 and also
  line 1 of every precinct: both lines use the same band, with the same weights, the same
  coding mode and the same prediction state.
- Band index b counts the bands in this order: line 0 bands of components 0, 1, 2, 3,
  then the line 1 bands of components 0, 1, 2, 3, skipping a component that has no wavelet
  (its band already has an index from line 0). This order is used by WGT, by the
  precinct's coding modes, and by the packets.

Test clip (25 bands):

| b | Component | Line | Band | Width | Code groups | Significance groups |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0 | low-pass, 5 levels | 95 | 24 | 3 |
| 1 | 0 | 0 | high-pass, level 5 | 95 | 24 | 3 |
| 2 | 0 | 0 | high-pass, level 4 | 189 | 48 | 6 |
| 3 | 0 | 0 | high-pass, level 3 | 379 | 95 | 12 |
| 4 | 0 | 0 | high-pass, level 2 | 757 | 190 | 24 |
| 5 | 0 | 0 | high-pass, level 1 | 1515 | 379 | 48 |
| 6–11 | 1 | 0 | as b = 0–5 | | | |
| 12 | 2 | 0 and 1 | whole row (no wavelet) | 3030 | 758 | 95 |
| 13–18 | 3 | 0 | as b = 0–5 | | | |
| 19 | 0 | 1 | horizontal low-pass | 1515 | 379 | 48 |
| 20 | 0 | 1 | horizontal high-pass | 1515 | 379 | 48 |
| 21–22 | 1 | 1 | as b = 19–20 | | | |
| 23–24 | 3 | 1 | as b = 19–20 | | | |

A band of width w has ⌈w / Ng⌉ code groups and ⌈⌈w / Ng⌉ / Ss⌉ significance groups. When w is
not a multiple of 4, the last code group has padding coefficients past the band's end.

### 5.4 Precinct layout

- A precinct starts with a header of 5 + ⌈2·Nb / 8⌉ bytes (12 bytes for Nb = 25):

  | Bits | Field |
  | --- | --- |
  | 24 | Lprc: byte length of the precinct after this header |
  | 8 | Q: quantization value |
  | 8 | R: refinement value |
  | 2 per band | D[b]: coding mode of band b, in band order |
  | 0–7 | zero bits to the byte boundary |

  - D[b] bit 0 (value 1) = vertical prediction; D[b] bit 1 (value 2) = significance flags.
  - In the test clip every band of every precinct has D[b] = 3.
- Then come 8 packets, in this order: (line 0, component 0), (line 0, component 1),
  (line 0, component 2), (line 0, component 3), (line 1, component 0), …, (line 1,
  component 3). Each packet holds the bands of its component on its line, in band order.
  For the test clip:

  | Packet | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | Bands b | 0–5 | 6–11 | 12 | 13–18 | 19–20 | 21–22 | 12 | 23–24 |

- After the 8th packet, zero bytes fill the precinct up to its Lprc length. The next
  precinct (or SLH) starts at header start + header length + Lprc.
- The line 1 packets of the last precinct of an odd `ch` are coded like all others. Their
  coefficients are decoded and then discarded (section 10.3). They still update the
  prediction state.

### 5.5 Packet layout

- Packet header, 7 bytes = 56 bits:

  | Bits (MSB first) | Field |
  | --- | --- |
  | 1 | Dr: 1 = raw GCLI coding for this packet |
  | 20 | Ldat: data sub-packet length in bytes |
  | 20 | Lcnt: GCLI sub-packet length in bytes |
  | 15 | Lsgn: sign sub-packet length in bytes |

- Then the sub-packets, each starting on a byte boundary:
  1. Significance sub-packet, only when Dr = 0. It has no length field. It holds the
     significance flags of every band in the packet whose D[b] has bit 1 set: one bit per
     significance group, in band order, then group order. Zero bits follow to the next byte
     boundary. So its length is ⌈(number of flags) / 8⌉ bytes (possibly 0).
  2. GCLI sub-packet: exactly Lcnt bytes.
  3. Data sub-packet: exactly Ldat bytes.
  4. Sign sub-packet: exactly Lsgn bytes.
- The content of the GCLI, data and sign sub-packets may end before their length. The
  rest is padding. The next sub-packet starts at the start of this one plus its length.
  Content that runs past the length is damaged data. The next packet header
  follows the sign sub-packet directly.
- Decoding order: for each sub-packet, all bands of the packet in order. The GCLIs of all
  bands of the packet are decoded before any magnitude.

### 5.6 GCLI decoding

For each band b in the packet, take Q and R from the precinct header:

- **Truncation position:** GTLI T = min(max(Q − G[b] − r, 0), 15), with r = 1 when
  P[b] < R and r = 0 otherwise.
- **Prediction source:** the band line most recently decoded for the same band index b
  inside the current slice. Keep its GCLI values Gs[g] and its GTLI Ts.
  - For a line 0 band, the source is that band's line in the previous precinct.
  - For a line 1 band of a transformed component, the source is that band's line 1 in the
    previous precinct.
  - For the untransformed component's band, the source for line 1 is line 0 of the same
    precinct, and the source for line 0 is line 1 of the previous precinct.
  - At the first precinct of a slice there is no source, except for that line 1 case.
- **Vertical mode** applies when D[b] bit 0 is set and a source exists. Otherwise
  **no-prediction mode** applies, even if D[b] bit 0 is set.
- **Predicted value** for code group g:
  - no-prediction mode: π = T;
  - vertical mode: π = max(Gs[g], Ts, T).
- **Significance flags** (when Dr = 0 and D[b] bit 1 is set): if the flag of significance
  group s is 1, every code group g with ⌊g / Ss⌋ = s gets GCLI = π, and no bits are read
  for them in the GCLI sub-packet. If the flag is 0, each of those code groups reads one
  unary value u, as below.
- **Unary value u:** count the 1 bits before the next 0 bit. The 0 bit is consumed. More
  than 31 ones before a 0 is damaged data.
- **GCLI from u:**
  - no-prediction mode: GCLI = T + u;
  - vertical mode: GCLI = π + δ, where the residual δ is coded as u. Let ρ = π − T (never
    negative). The encoder maps δ to u as follows: δ < 0 gives u = −2δ − 1 (odd, below
    2ρ); 0 ≤ δ ≤ ρ gives u = 2δ (even, at most 2ρ); δ > ρ gives u = δ + ρ (above 2ρ).
    Decoding inverts this mapping; the three ranges of u do not overlap.
  - Either way, a GCLI outside 0 to 15 is damaged data.
- **Raw packets (Dr = 1):** there is no significance sub-packet. Each code group's GCLI is
  the next Br-bit unsigned field (Br = 4), read in band and group order. D[b] is ignored.
  Raw packets were not seen in the test clip (section 11).
- After the GCLI sub-packet, skip to its end (start + Lcnt).
- Once a band line is decoded, it becomes the prediction source for its band index (its
  GCLIs and its GTLI).

### 5.7 Data sub-packet (magnitudes)

- For each band of the packet in order, and for each code group g in order: let
  n = GCLI − T.
  - If n ≤ 0, the four coefficients of the group have magnitude 0, and no bits are read.
  - Otherwise, read 4n bits. They are the bit planes of the group from the most
    significant plane (GCLI − 1) down to plane T. Each plane has 4 bits, for coefficients
    0, 1, 2 and 3 of the group, in that order.
- This gives an n-bit value a_j for each coefficient j. The full-scale magnitude is
  m_j = a_j · 2^T. That is, the planes below T are zero until section 6 reconstructs them.
- After the data sub-packet, skip to its end (start + Ldat).

### 5.8 Sign sub-packet

- For each band of the packet in order, each code group in order, and each coefficient
  j = 0 to 3 in that group whose m_j is not zero (padding coefficients included), read one
  bit: 1 = negative, 0 = positive. Coefficients with m_j = 0 have no sign bit.
- After the sign sub-packet, skip to its end (start + Lsgn).

### 5.9 Where the coefficients go

Coefficient i of band b (i = 0 to w − 1), on line ℓ of precinct k:
- goes to component c of the band, canonical row 2k + ℓ, column (band start + i), with
  the value of section 6;
- padding coefficients (i ≥ w) are discarded;
- a line whose row 2k + ℓ is not below `ch` is discarded (section 10.3).

## 6. Dequantization

Inputs per coefficient: its full-scale magnitude m (5.7), the GCLI and GTLI T of its code
group, and its sign bit.

- When T = 0, the reconstructed magnitude is m̂ = m.
- Otherwise m̂ = Σ ⌊m / 2^(kζ)⌋ over k ≥ 0, with ζ = GCLI − T + 1, that is, shifted
  copies of m added up:

  m̂ = m + ⌊m / 2^ζ⌋ + ⌊m / 2^(2ζ)⌋ + ⌊m / 2^(3ζ)⌋ + …

  The terms become 0 after a few steps. (When m = 0, which includes every group with
  GCLI ≤ T, the sum is 0.) This fills the truncated planes in proportion, which is the
  uniform reconstruction (Qpih = 1). No rounding offset is added.
- The coefficient value is v = ±(m̂ · 2^Fq): negative when the sign bit is 1. Fq = 4, so v is
  a multiple of 16.
- m̂ < 2^16 because GCLI ≤ 15, and |v| < 2^20. Everything fits in 32-bit signed integers.

These values, placed by 5.9, form stage `coeffs` (10.4).

## 7. Inverse 5/3 wavelet

### 7.1 One-dimensional inverse step

Input: a sequence of length N. The first ⌈N / 2⌉ entries are low-pass values s[0], s[1], …
and the next ⌊N / 2⌋ entries are high-pass values d[0], d[1], …. Output: N samples x[0] to
x[N − 1].

- If N < 2, the output equals the input.
- Even samples, for i = 0 to ⌈N / 2⌉ − 1:

  x[2i] = s[i] − ⌊(d[i − 1] + d[i] + 2) / 4⌋

  A d index below 0 is replaced by 0, and a d index above ⌊N / 2⌋ − 1 is replaced by
  ⌊N / 2⌋ − 1.
- Odd samples, for i = 0 to ⌊N / 2⌋ − 1, after all even samples:

  x[2i + 1] = d[i] + ⌊(x[2i] + x[2i + 2]) / 2⌋

  When 2i + 2 ≥ N, use x[2i] in place of x[2i + 2].
- These index replacements are the whole-sample symmetric extension of the 5/3 filter.

### 7.2 Two-dimensional inverse for NLx = 5, NLy = 1

Work on one component's `coeffs` array in the canonical layout (10.4), where n is the
component's horizontal level count (5).

1. **Horizontal, even rows** (vertical low-pass lines). On every row 2k, apply 7.1 n times,
   each time in place on a prefix of the row:
   - first on columns 0 to L₍ₙ₋₁₎ − 1 (N = L₍ₙ₋₁₎ = Lₙ + Hₙ), then N = L₍ₙ₋₂₎, …, and
     finally N = L₀ = `cw`.
   - With the widths of 10.4, each prefix holds a low-pass part of width Lⱼ followed by
     the high-pass band Hⱼ, which is exactly the input that 7.1 expects.
   - For the test clip, the prefix lengths are 190, 379, 758, 1515, 3030.
2. **Horizontal, odd rows** (vertical high-pass lines). On every row 2k + 1 (all of them
   below `ch`), apply 7.1 once with N = `cw`.
3. **Vertical.** For each column x, take the `ch` values of that column after steps 1 and
   2. Apply 7.1 with N = `ch`, using s[i] = row 2i and d[i] = row 2i + 1. The outputs
   x[0] to x[ch − 1] are rows 0 to ch − 1 of the result.
   - The line that 10.3 discards never enters this step: with ch = 1705 there are 853 low
     rows and 852 high rows.

Do the steps in this order: all horizontal steps first, then the vertical step. The
result is stage `planes_st` (10.5). No shift, offset or clamp follows.

### 7.3 Component without a wavelet

A component whose CDT decomposition byte is 0x00 (component 2) is not transformed. Its
`planes_st` plane equals its `coeffs` plane: row 2k is line 0 and row 2k + 1 is line 1 of
precinct k.

### 7.4 Range

All intermediate values fit in 32-bit signed integers. In the test clip they stay below
about 2^16 in magnitude.

## 8. Inverse Star-Tetrix and the CFA plane order

Input: the four `planes_st` planes, written here as A (component 0), C (component 1),
E (component 2) and F (component 3), each `cw` × `ch`, indexed (x, y).

Neighbour indexes repeat the edge sample: x⁻ = max(x − 1, 0), x⁺ = min(x + 1, cw − 1),
y⁻ = max(y − 1, 0), y⁺ = min(y + 1, ch − 1).

Apply five lifting steps in this order. Each step changes one plane, at every (x, y). No
step's right-hand side contains the plane it updates at any position other than (x, y), so
each step is a pure function of the previous state.

1. A(x, y) ← A(x, y) − ⌊(E(x, y⁻) + E(x⁺, y⁻) + E(x, y) + E(x⁺, y)) / 8⌋
2. E(x, y) ← E(x, y) − ⌊(C(x, y) + C(x, y⁺) + F(x⁻, y) + F(x, y)) / 8⌋
   + ⌊(A(x⁻, y) + A(x, y) + A(x⁻, y⁺) + A(x, y⁺)) / 4⌋
3. A(x, y) ← A(x, y) − ⌊(C(x, y) + C(x⁺, y) + F(x, y⁻) + F(x, y)) / 8⌋
4. C(x, y) ← C(x, y) + ⌊(A(x⁻, y) + A(x, y) + E(x, y⁻) + E(x, y)) / 4⌋
5. F(x, y) ← F(x, y) + ⌊(A(x, y) + A(x, y⁺) + E(x, y) + E(x⁺, y)) / 4⌋

In step 2, the two floor terms are computed separately and then combined.

After step 5, the planes are the CFA planes of stage `cfa_companded` (10.6):

| Plane after step 5 | CFA site | Mosaic position of sample (x, y) for RGGB |
| --- | --- | --- |
| A (plane 0) | green on the red rows, Gr | (2x + 1, 2y) |
| C (plane 1) | red, R | (2x, 2y) |
| E (plane 2) | green on the blue rows, Gb | (2x, 2y + 1) |
| F (plane 3) | blue, B | (2x + 1, 2y + 1) |

The steps match this geometry. For example, step 4 updates red at (2x, 2y) from the
four greens next to it: Gr at (2x − 1, 2y) and (2x + 1, 2y), Gb at (2x, 2y − 1) and
(2x, 2y + 1). So the informal names of 10.5 follow: C holds red minus the mean of its four
green neighbours, F holds blue minus its green neighbours, E holds Gb relative to the
surrounding Gr and chroma, and A holds the green level.

The values stay companded codes (code index = value + 32768). No clamp is applied here.

## 9. Transfer curve and white level

The camera stores companded codes. The curve Lin maps a 16-bit code index i (0 to 65535)
to a linear 14-bit sensor value.

### 9.1 Parameters

They come from the 13 PIH vendor bytes V0 to V12 (PIH body bytes 24 to 36):

| Parameter | Bits | Formula | Test clip |
| --- | --- | --- | --- |
| black level Bk | 12 | (V3 mod 16) · 256 + V4 | 1008 |
| slope S | 18 | (V7 mod 4) · 65536 + V8 · 256 + V9 | 84429 |
| pivot code K | 16 | V10 · 256 + V11 | 16255 |

The other vendor bits (V0, V1, V2, the high nibble of V3, V5, V6, the high six bits of
V7, and V12) are not used. Their meaning is **unknown**. Test clip values: V0 = 0x50,
V1 = 0x88, V2 = 0x70, V3 high nibble = 0x8, V5 = 0x15, V6 = 0x23, V7 high bits = 0xD0,
V12 = 0x07.

### 9.2 Curve

For a code index i:

- e = i − K
- if e < 0: φ = −e²
- if e ≥ 0: τ = ⌊(e · S + 32768) / 65536⌋ and φ = τ²
- Lin(i) = min(max(Bk + ⌊(φ + 163840) / 262144⌋, 0), 16383)

Notes:
- 262144 = 2^18 and 163840 = 0.625 · 2^18. Use floor division for negative φ.
- e · S and φ exceed 32 bits. Use 64-bit integers.
- Checks with the test clip parameters: Lin(K) = Bk = 1008; Lin(0) = 0;
  Lin(65535) = 16383 (clamped from 16384). Lin is non-decreasing.
- Above the pivot, the curve is quadratic in the code, so the code is a square-root
  encoding of the linear value. Below the pivot, a mirrored quadratic carries codes down to
  0, which keeps values below black (noise).
- Lin is the same for every sample of a frame. A 65,536-entry table built once per header is
  one way to apply it.

### 9.3 Use

- For each `cfa_companded` value v: i = min(max(v + 32768, 0), 65535), and the linear value
  is Lin(i). The mosaic placement is in 10.7.
- **White level** = 16383 = 2^14 − 1. It is the curve's ceiling and matches the 14-bit
  component depth.
- **Black level** = Bk (1008 in the test clip). It is not part of the frame JSON. A viewing
  transform needs it, and it comes from the vendor bytes.
- Only integer arithmetic is involved, so the reference's linear stage is exact. A
  decoder must match it with tolerance 0.

## 10. Canonical coefficient layout and stage dump definitions

### 10.1 Conventions

- Every dump file is little-endian and has no header.
- `width` and `height` are the full mosaic size from the picture header (fields Wf and Hf).
  Both are even. `cw` = width / 2 and `ch` = height / 2 are the size of one component
  (one sample per 2×2 CFA quad).
- A stage with four components stores component 0 first, then 1, 2 and 3. Each component
  is a `cw` × `ch` array in row-major order: sample (x, y) is at element index
  y · cw + x inside its component.
- "Component c" is the c-th component in codestream order, the same order as the
  component table (CDT) and the per-band weights.
- A decoder matches the oracle at a stage when its dump is byte-identical to the
  reference file.

Test clip values: `width` = 6060, `height` = 3410, `cw` = 3030, `ch` = 1705.

| Stage file | Type | Elements | Bytes (test clip) |
| --- | --- | --- | --- |
| `fNNNN.coeffs.bin` | int32 | 4 × cw × ch | 82,658,400 |
| `fNNNN.planes_st.bin` | int32 | 4 × cw × ch | 82,658,400 |
| `fNNNN.cfa_companded.bin` | int32 | 4 × cw × ch | 82,658,400 |
| `fNNNN.bayer_linear.bin` | uint16 | width × height | 41,329,200 |
| `fNNNN.json` | UTF-8 JSON | see 10.8 | about 700 |

`NNNN` is the zero-based frame index (video sample index in the container), written with
four digits.

### 10.2 The decoding stages

The decoder works in four steps. Each stage dump is the state after one step:

1. Entropy decoding and inverse quantization give the wavelet coefficients: stage
   `coeffs`.
2. The inverse wavelet transform gives four component planes in the Star-Tetrix
   (decorrelated) domain: stage `planes_st`.
3. The inverse Star-Tetrix transform gives the four CFA sample planes, still in the
   companded (square-root coded) domain: stage `cfa_companded`.
4. The transfer curve maps each companded sample to a linear 14-bit sensor value, and the
   four planes are placed back into the Bayer mosaic: stage `bayer_linear`.

All four stages are integer-valued in the reference. No floating-point step and no
rounding to integer occur anywhere in this chain.

### 10.3 Precincts and lines

- Precinct k holds component rows 2k and 2k + 1 (row 2k + 1 only when it is below
  `ch`). The number of precincts is
  P = ⌈ch / 2⌉ (853 for the test clip).
- Each precinct carries two lines for each component:
  - line 0 is the vertical low-pass line;
  - line 1 is the vertical high-pass line.
- For a component without a wavelet transform, line 0 of precinct k is component row 2k
  and line 1 is component row 2k + 1.
- When `ch` is odd, the codestream still codes line 1 of the last precinct (P − 1), but no
  image row belongs to it. Decode it, then discard it. The test clip has odd `ch` (1705),
  so its last precinct (k = 852) has such a line.

### 10.4 Stage `coeffs`: canonical coefficient layout

**Rows.** For each component, line 0 of precinct k goes to row 2k, and line 1 of
precinct k goes to row 2k + 1. The discarded extra line of 10.3 has no row. So the
`coeffs` array of a component has exactly `ch` rows, the same shape as its image plane.

**Columns.** Inside a row, the horizontal sub-bands of that line are placed side by side,
coarsest band first. Each band fills a contiguous run of columns, and coefficient i of the
band (in coded order, i = 0 to band width − 1) goes to column (band start + i).

Let n be the number of horizontal decomposition levels of the component. It is the high
nibble of the third byte of that component's CDT entry (see 10.8). The low nibble is the
number of vertical levels. In the test clip, n = 5 with one vertical level for components
0, 1 and 3, and n = 0 (no wavelet) for component 2.

Band widths for a component with n ≥ 1 and one vertical level:

- Start with L₀ = cw. For each level j = 1 to n: Hⱼ = ⌊Lⱼ₋₁ / 2⌋ and Lⱼ = Lⱼ₋₁ − Hⱼ.
  (Lⱼ is the low-pass width after j levels. Hⱼ is the high-pass width made at level j.)
- Even rows (line 0, vertical low-pass): the columns hold, from left to right, the
  low-pass band of width Lₙ, then the high-pass bands Hₙ, Hₙ₋₁, …, H₁.
- Odd rows (line 1, vertical high-pass): this line has one horizontal level only. The
  columns hold the horizontal low-pass band of width ⌈cw / 2⌉, then the horizontal
  high-pass band of width ⌊cw / 2⌋.

Test clip (cw = 3030, n = 5):

| Row kind | Band | Columns (start, width) |
| --- | --- | --- |
| even | low-pass after 5 levels | 0, 95 |
| even | high-pass, level 5 | 95, 95 |
| even | high-pass, level 4 | 190, 189 |
| even | high-pass, level 3 | 379, 379 |
| even | high-pass, level 2 | 758, 757 |
| even | high-pass, level 1 | 1515, 1515 |
| odd | horizontal low-pass | 0, 1515 |
| odd | horizontal high-pass | 1515, 1515 |

For a component without a wavelet (n = 0), each line is one band of width `cw` at column 0.
Its `coeffs` plane is therefore identical to its `planes_st` plane.

**Values.** Each element is

  v = s · m̂ · 2^Fq

where:

- m̂ is the reconstructed magnitude from the inverse quantizer (section 6). It is a
  non-negative integer at full scale: the bit planes below the truncation
  position are already restored by the reconstruction rule. It is 0 when the coefficient's
  code group has a GCLI that is not above its GTLI.
- s is −1 when the coefficient's sign bit is 1, and +1 otherwise. A sign bit is coded only
  for a non-zero magnitude; a zero magnitude gives v = 0.
- Fq is the picture header field Fq (4 in the test clip). So every element of the test
  clip's `coeffs` is a multiple of 16.

Observed range in the test clip: about −23,000 to +40,000.

### 10.5 Stage `planes_st`: after the inverse wavelet

For each component, a `cw` × `ch` int32 plane: the result of the full inverse 5/3
reversible wavelet transform (section 7) applied to that component's
`coeffs` array.

- The inverse runs in this order: first the horizontal inverse on every row (all n levels
  on the even rows, from the coarsest level to the finest; one level on the odd rows),
  then one vertical inverse level that combines each even row with the odd rows next to
  it. The order matters, because integer lifting steps do not commute exactly.
- A component without a wavelet is copied unchanged.
- No scale, offset, rounding or clamp is applied after the inverse. In particular, the
  2^Fq factor of 10.4 is not divided out; the values stay in the same units.
- The four planes are the Star-Tetrix decorrelated components, in codestream order.
  Section 8 defines them exactly, through the inverse transform. Informal names, for
  orientation only: 0 is a green-level (luma-like) component, 1 is roughly red minus
  green, 2 is a difference between the two green sites, 3 is roughly blue minus green.

### 10.6 Stage `cfa_companded`: after the inverse Star-Tetrix

Four `cw` × `ch` int32 planes: the result of the inverse Star-Tetrix transform (section 8)
applied to `planes_st`. Each plane now holds one CFA site of every
2×2 quad. Sample (x, y) of a plane belongs to the quad whose top-left mosaic pixel is
(2x, 2y).

Plane order, and the mosaic position of each plane's sample for the RGGB pattern of the
test clip (X = column, Y = row in the mosaic):

| Plane | CFA site | Mosaic position |
| --- | --- | --- |
| 0 | green on the red rows (Gr) | (2x + 1, 2y) |
| 1 | red (R) | (2x, 2y) |
| 2 | green on the blue rows (Gb) | (2x, 2y + 1) |
| 3 | blue (B) | (2x + 1, 2y + 1) |

The values are companded codes, centred on zero: the 16-bit code index of a sample is
(value + 32768). This stage applies no clamp. Values outside −32768 to 32767 can occur
(the test clip has values up to about 33,200); the clamp belongs to the next step.

### 10.7 Stage `bayer_linear`: linear sensor mosaic

A `width` × `height` uint16 array in row-major order: pixel (X, Y) is at element index
Y · width + X.

For pixel (X, Y):

1. Take the quad (x, y) = (⌊X / 2⌋, ⌊Y / 2⌋).
2. Take the plane for the position inside the quad, from the table in 10.6:
   (X even, Y even) → plane 1 (R); (X odd, Y even) → plane 0 (Gr);
   (X even, Y odd) → plane 2 (Gb); (X odd, Y odd) → plane 3 (B).
3. Let v be that plane's `cfa_companded` sample at (x, y). The code index is
   i = min(max(v + 32768, 0), 65535).
4. The pixel value is Lin(i), where Lin is the camera's square-root transfer curve with the
   parameters from the vendor bytes of the picture header (section 9).

Lin is computed with integer arithmetic only, and its output is clamped to 0 to 16383
(`white_level`). So this stage needs no rounding. Its values can lie below the sensor
black level: the test clip has values from 936 to 16383, and its black level is 1008.

### 10.8 Frame JSON (`fNNNN.json`)

Top-level keys: `width`, `height` (picture header Wf, Hf), `cw`, `ch` (10.1), `meta` and
`header`.

`meta` holds per-frame camera metadata from the Nikon frame wrapper. Each value comes from
an NRMT tag box of this frame's wrapper. Each NRMT value starts with one leading byte of
unknown meaning (0 in every tag seen); the payload follows it. All multi-byte values are big-endian.

| Key | Source NRMT tag (group, tag) | Payload | Test clip |
| --- | --- | --- | --- |
| `cfa` | 0x0110, 0xA302 (EXIF CFA pattern) | u16 columns, u16 rows, then one colour code per site, row by row (0 = R, 1 = G, 2 = B) | 2, 2, codes 0 1 1 2 → `"RGGB"` |
| `wb_gain` | 0x0190, 0x0009 | two float32: red gain, blue gain | [1.673828125, 1.0, 2.048828125] |
| `cam_to_xyz` | 0x0190, 0x0012 | nine float32, row-major 3×3 matrix | see the file |
| `iso` | 0x0110, 0x8832 | u32 | 6400 |
| `white_level` | none (constant) | 2^14 − 1, from the 14-bit component depth | 16383 |

- `wb_gain` is [R, G, B] with G = 1.0.
- `cam_to_xyz` maps white-balanced camera RGB to CIE XYZ with a D65 white.
- Float values are written as the shortest decimal that round-trips: the float32 from
  the tag is widened to double precision, and the number is the shortest decimal string
  that parses back to that double. Parsing it as a double and narrowing to float32 gives
  the tag value exactly.
- JSON has no literal for NaN or infinity. If a white-balance or matrix tag holds a
  non-finite value, the oracle stops with an error and writes no JSON for that frame.
  The test clip has no such value.
- The R3D NE and N-RAW forms of the same clip carry different `cam_to_xyz` matrices (each
  format stores its own). The image data and all other `meta` values are the same.

`header` holds the raw field values of the codestream's picture header (PIH) and
component table (CDT). Byte positions count from the first byte after the PIH length
field (Lpih):

| Key | Field | Position in the PIH body | Test clip |
| --- | --- | --- | --- |
| `width` | Wf | bytes 8–9 | 6060 |
| `height` | Hf | bytes 10–11 | 3410 |
| `slice_height` | Hsl, slice height in precincts | bytes 14–15 | 16 |
| `nc` | Nc, number of components | byte 16 | 4 |
| `ng` | Ng, coefficients per code group | byte 17 | 4 |
| `ss` | Ss, code groups per significance group | byte 18 | 8 |
| `bw` | Bw, nominal bit precision of the wavelet coefficients | byte 19 | 18 |
| `fq` | Fq, fractional bits | byte 20, high nibble | 4 |
| `br` | Br, bits per raw-coded bit-plane count | byte 20, low nibble | 4 |
| `cpih` | Cpih, colour transform field | byte 21, low nibble | 0 |
| `nlx` | NLx, horizontal decomposition levels | byte 22, high nibble | 5 |
| `nly` | NLy, vertical decomposition levels | byte 22, low nibble | 1 |

- In the test clip, the Cpih field is 0, but the four components are still
  Star-Tetrix decorrelated, and the decoder must apply the inverse Star-Tetrix transform.
  No stream with another Cpih value has been seen.
- The TICO RAW CDT has three bytes per component (the standard CDT has two):
  - byte 1: component bit depth;
  - byte 2: sampling factors, Sx in the high nibble and Sy in the low nibble;
  - byte 3: the component's own decomposition levels, horizontal in the high nibble and
    vertical in the low nibble (0x51 for components 0, 1 and 3, and 0x00 for component 2,
    in the test clip).

  `comp_depth`, `comp_sx` and `comp_sy` are lists of four values, one per component, from
  bytes 1 and 2. In the test clip they are [14, 14, 14, 14], [1, 1, 1, 1] and [1, 1, 1, 1].

### 10.9 Reference files

These files are not stored in the repository (`testdata/` is git-ignored). `oracle/run.sh`
makes them from a clip.

- `testdata/ref/A015_C004/` holds the four stage dumps and the JSON for frames 0, 100 and
  818 of the test clip.
- `testdata/ref/A015_C004_nraw.NEV` is the same clip rewrapped losslessly as N-RAW. Its
  frames decode to stage dumps that are byte-identical to those of the R3D NE clip. Only
  `meta.cam_to_xyz` differs (10.8).
- `testdata/MANIFEST.sha256` lists the SHA-256 of every file in `testdata/ref/A015_C004/`.

## 11. Known limits and untested modes

### 11.1 Supported parameter set

This note covers exactly the values below, all taken from the test clip. A decoder should
reject every other value with a clear "unsupported" error that names the field and the
value. It must never output a picture for an unsupported value.

| Item | Supported value |
| --- | --- |
| Video sample entry | `NR3D` or `NRAW` |
| Frame wrapper | `NRAW` box with the structure of section 2; codestream located as in section 2 |
| CFA pattern (NRMT 0x0110A302) | 2×2, `RGGB` |
| CAP | present; body is 32 bytes and starts with `CONTACT_INTOPIX_` |
| PIH length L | 39 |
| Ppih, Plev | 0, 0 |
| Wf, Hf | even, Wf = 2·cw, Hf = 2·ch; 6060×3410 is the only size tested (see 11.2) |
| Cw | 0 |
| Hsl | 16 |
| Nc | 4 |
| Ng, Ss | 4, 8 |
| Bw | 18 |
| Fq, Br | 4, 4 |
| Fslc, Ppoc, Cpih | 0, 1, 0 (Star-Tetrix implied, 3.5) |
| NLx, NLy | 5, 1 |
| Lh, Rl, Qpih, Fs, Rm | 0, 0, 1, 1, 0 (byte 23 = 0x14) |
| CDT length L | 14 (3 bytes × 4 components) |
| Bit depth B[c] | 14 for every component |
| Sx, Sy | 1, 1 for every component (byte 0x11) |
| Decomposition bytes | 0x51, 0x51, 0x00, 0x51 (components 0 to 3) |
| WGT | 25 entries (L = 52), one per band of 5.3 |
| PIH vendor bytes | any value: Bk, S and K enter the curve of section 9 as they are, and the unused bits are ignored |

Notes:
- The reference itself accepts more. It ignores Fslc, Lh, Rl, Bw, Ppih, Plev and Cpih,
  and it takes the wavelet levels from CDT only, not from NLx. It accepts any Hsl ≥ 1, and per-component decompositions of either 0x00 or 1 to 8
  horizontal levels with 1 vertical level. Those wider cases are not covered here, because
  no stream with them has been seen.
- The vendor bytes are not checked, because the transfer-curve parameters may change with
  the camera's settings (**unverified**), and the meaning of the unused bits is unknown.

### 11.2 Behaviour seen only partly or not at all

- **Coding modes.** In all three test frames, every band of every precinct has D[b] = 3
  (vertical prediction and significance flags). Modes 0, 1 and 2 are described by
  section 5.6 but are untested.
- **Raw packets.** Dr = 1 never occurs in the test frames. The raw GCLI rule of 5.6 is
  untested.
- **Bytes before EOC.** The test frames fill their codestream exactly. A decoder must
  accept any bytes between the last precinct and EOC (section 4, item 9); this is
  untested.
- **Picture sizes.** Only 6060×3410 has been decoded. Other Nikon ZR modes (for example
  4K, or 50/60/120 fps) and other cameras are expected to follow the same rules, but they
  are untested. Odd `ch` is tested (1705). A `cw` that leads to other band widths is
  covered by the formulas of 10.4 and 5.3, but is untested. The reference refuses a `cw`
  below 64 or a `ch` below 4.
- **N-RAW clips from other cameras** (Z8, Z9, Z6III) are untested. No such sample exists in
  this project. The only N-RAW file tested is the lossless rewrap of the test clip.
- **Other CFA patterns** are not covered: the plane-to-mosaic table of 10.6 is known for
  RGGB only.

### 11.3 Damaged data

The reference treats each of the following as damaged data. A decoder should return an
"invalid data" error for each:
- the sample is not an `NRAW` box, its size field differs from the sample size, a child
  box size is below 8 or runs past the sample, or no SOC follows the wrapper;
- the codestream does not start with SOC, a marker length is below 2 or runs past the
  data, EOC comes before any SLH, or PIH, CDT or WGT is missing;
- a slice does not start with SLH where 5.2 expects it, or a precinct header or precinct
  runs past the end of the codestream;
- a sub-packet's content runs past its length, or a sub-packet runs past its precinct;
- a unary value has more than 31 ones, or a GCLI falls outside 0 to 15;
- no EOC follows the last precinct (other bytes may come before it).

### 11.4 Unknowns

- The meaning of the 16 trailing CAP bytes (3.1).
- The meaning of the unused PIH vendor bits (9.1).
- The leading byte of every NRMT value, and the NRMT tags marked unknown (section 2).
- Where the active area (6048×3402) sits inside the coded mosaic (section 1).
- Every comparison with the ISO/IEC 21122 text in section 4.

## 12. Viewing transform of the reference renderer (`develop --rec709`)

This section describes how the reference's renderer turns the linear mosaic into the
pixels of `bluecompress develop <clip> --rec709 --width 1920 -o out.mov`. It is the
target of the Rec.709 view (`docs/design.md`, section 7). The facts come from the blue-compressor
source at commit `4d35f31`, and section 12.11 lists the numeric checks against the
binary. The reference computes every step in single-precision float (on the GPU through
Metal on Apple Silicon; its CPU path gives the same 16-bit values for the test frames).

### 12.1 Settings that apply

The command line above uses the default of every control:

| Control | Default | Effect |
| --- | --- | --- |
| exposure (`--exposure EV`) | 0 | none |
| white balance (`--kelvin`, `--tint`) | as shot | gains = recorded gains (12.4) |
| ISO (`--iso N`) | recorded ISO | gain factor 1 (12.5) |
| highlight roll-off | "medium" (shoulder 4) | 12.7; no flag changes it |
| tone map | "medium" (slope 1.16) | 12.7; no flag changes it |
| contrast, highlights, shadows, saturation, colour boost | 0 | identity (12.6); no flag changes them |
| noise reduction (`--nr-luma`, `--nr-chroma`) | 0 | off |
| sharpening | off | 12.9 |
| user LUT (`--lut FILE.cube`) | none | off |
| `--desqueeze`, `--conform` | off | none |
| `--width` | 3840 if omitted | 12.3 |

Clip-level inputs:
- The white-balance gains and `cam_to_xyz` come from the wrapper of **frame 0 only**
  (the NRMT tags of 10.8). The renderer uses them for every frame. It never reads them
  from later frames.
- The gains are accepted only if both lie in [0.2, 8). Else the renderer uses
  [1.7, 1.5] (R, B). The matrix is accepted only if |m10 + m11 + m12 − 1| < 0.05 (its
  second row, the Y row, sums to 1). Else it uses a built-in matrix, row major:
  [0.605607, 0.38127, −0.0364214; 0.228239, 1.04834, −0.276578; 0.0062585, −0.173072,
  1.25587]. A non-finite value also rejects the tag. The test clip passes both checks.
- The recorded ISO (6400 in the test clip), the recorded colour temperature (a clip-level
  text tag in kelvin; absent in the test clip, so 5600 K is assumed) and the camera model
  string are also read. With default settings none of them changes a pixel (12.4, 12.5).
- An R3D NE clip can have an `.RMD` sidecar (same base name, extension `.RMD` in any case,
  same folder). Its exposure, ISO, colour temperature and tint replace the recorded
  values. The test clip has no sidecar.

Nothing in the transform depends on image statistics, and nothing changes from frame to
frame except the mosaic itself. (The optional `--auto` flag is the only exception: see
12.5.)

### 12.2 Input and normalisation

The input of a frame is the four `cfa_companded` planes after the transfer curve, that
is, the `bayer_linear` values of 10.7 grouped by quad: four `cw` × `ch` planes Gr, R, Gb,
B (the plane order of 10.6). Values are the integers 0 to 16383, held as floats.

- Black level Bk = the curve's black level (9.1; 1008 in the test clip).
- White level = 16383 (a constant).
- Normalisation of a value s: N(s) = max((s − Bk) / (16383 − Bk), 0). (The denominator is
  at least 1.)
- N is applied **after** the spatial sampling of 12.3, to each interpolated plane value
  separately.

### 12.3 Output size, spatial sampling and demosaic

Output size, for a requested width Wreq (default 3840) and the clip's track size
W × H (6060 × 3410 in the test clip):
- ow = Wreq (at least 16; `--width 0` gives W rounded down to even).
- oh = 2 · round(ow · H / W / 2) (at least 2).
- Test clip with `--width 1920`: 1920 × 1080 (1920 · 3410 / 6060 = 1080.4).

Mapping from output pixel to mosaic position:
- sx = 2 · cw / ow and sy = 2 · ch / oh (mosaic pixels per output pixel; cw, ch from
  10.1). Test clip at 1920 × 1080: sx = 3.15625, sy = 3.1574074.
- The centre of output pixel (i, j) (column i, row j, from 0) lies at mosaic position
  mx = (i + 0.5) · sx, my = (j + 0.5) · sy.
- If sx ≥ 2 and sy ≥ 2, the renderer uses **quad sampling**. Else it uses the **full
  demosaic**. The output at 1920 wide and at 3030 wide uses quad sampling.

Bilinear sample P(u, v) of a `cw` × `ch` plane P at real quad coordinates (u, v):
- u' = min(max(u, 0), cw − 1) and v' = min(max(v, 0), ch − 1).
- x0 = ⌊u'⌋, y0 = ⌊v'⌋, x1 = min(x0 + 1, cw − 1), y1 = min(y0 + 1, ch − 1),
  fx = u' − x0, fy = v' − y0.
- top = P[y0][x0] + (P[y0][x1] − P[y0][x0]) · fx; bottom = the same on row y1;
  P(u, v) = top + (bottom − top) · fy.

Quad sampling:
- (u, v) = (mx / 2 − 0.5, my / 2 − 0.5). All four planes are sampled at the **same**
  (u, v). The CFA phase of each plane (its position inside the quad) is ignored.
- Camera RGB: r = N(R(u, v)), g = ½ · (N(Gr(u, v)) + N(Gb(u, v))), b = N(B(u, v)).
  Note that each green plane is normalised and clamped at 0 before the two are averaged.
- There is no low-pass filter before the sampling. At 1920 wide every output pixel reads
  only the 2 × 2 nearest quads of each plane (u = 1.578125 · i + 0.2890625,
  v = 1.5787037 · j + 0.2893519 at 1920 × 1080), so the resize is a plain bilinear
  decimation and it aliases.
- At ow = cw (3030 × 1705 for the test clip; the half-size output described in `docs/design.md`),
  sx = sy = 2 and (u, v) = (i, j) exactly. Then every output pixel is one quad: (R, mean of
  the two greens, B), with no interpolation.
- The resize therefore happens **first**, on linear raw values, before every colour step.
  All later steps run once per output pixel.

Full demosaic (used only when sx < 2 or sy < 2, that is, when the output has more pixels
across than `cw` or more rows than `ch`; not used by the commands in this note, and
untested here):
- The phase (px, py) of each plane inside the quad: Gr (1, 0), R (0, 0), Gb (0, 1),
  B (1, 1). For each plane c, q_c = ((mx − 0.5 − px_c) / 2, (my − 0.5 − py_c) / 2).
- G = ½ · (Gr(q_Gr) + Gb(q_Gb)).
- The green at the red phase: G_R = ½ · (Gr(q_R) + Gb(q_R)); at the blue phase:
  G_B = ½ · (Gr(q_B) + Gb(q_B)).
- Rr = G + R(q_R) − G_R and Bb = G + B(q_B) − G_B (colour differences).
- Camera RGB = (N(Rr), N(G), N(Bb)).

### 12.4 White balance and highlight clip

- Gains (gR, gG, gB): with default settings, gR and gB are the recorded `wb_gain` values
  of frame 0 and gG = 1. Test clip: (1.673828125, 1, 2.048828125).
- The renderer supports a changed colour temperature: it scales gR and gB by the ratio of
  the camera responses to two Planckian lights (the recorded temperature and the new one),
  and it sets gG = 2^(−tint / 300). With the temperature unchanged the ratio is exactly 1,
  and with tint 0 gG is exactly 1. Each gain is clamped to [0.1, 16].
- The gains are not normalised (no division by the smallest or largest gain).
- After the gains, each channel is clamped: w_c = min(max(cam_c · g_c, 0), 1).
- This clamp is the only highlight handling before the matrix. There is no highlight
  reconstruction. A pixel at sensor saturation in all three channels becomes w = (1, 1, 1)
  and stays neutral. A channel with gain > 1 clips at a lower raw value: in the test clip,
  R clips at normalised 1 / 1.6738 = 0.5974 and B at 1 / 2.0488 = 0.4881.

### 12.5 Colour matrix and exposure gain

The scene-linear Rec.709 value is lin = k · A · C · w, where w = (wR, wG, wB) from 12.4.

- C = `cam_to_xyz` of frame 0 (10.8), used as stored: row major, not inverted, not
  normalised. It maps white-balanced camera RGB to CIE XYZ with a D65 white.
- A = the XYZ (D65) to linear Rec.709 matrix, with these constants (row major):
  [3.24097, −1.537383, −0.498611; −0.969244, 1.875968, 0.041555; 0.05563, −0.203977,
  1.056972].
- There is no chromatic adaptation step. Both C and A use D65.
- k is one scalar exposure gain:
  k = 11.52 · F · 2^E · I, where
  - 11.52 = 0.18 · 64: the renderer puts sensor saturation (w = 1) six stops above
    scene grey 0.18;
  - F = 2^(−0.5) for R3D NE clips and 1 for N-RAW clips. The reference renders R3D NE half
    a stop darker than N-RAW. The offset is 0.5 EV for every camera model at this commit;
  - E = the exposure setting in stops (0 by default);
  - I = ISO setting / recorded ISO for R3D NE (1 by default; a missing recorded ISO counts
    as 800), and 1 for N-RAW. The recorded ISO alone has no effect.
- Test clip (R3D NE, defaults): k = 11.52 / √2 = 8.1458701 (+3.026 EV).
- A · C for the test clip (R3D NE matrix of 10.8):
  [1.593696, −0.504339, −0.089372; −0.182663, 1.543437, −0.360769; −0.058278, −0.549998,
  1.608268]. Its row sums are 0.999985, 1.000006 and 0.999992, so a neutral w = (a, a, a)
  gives lin ≈ (k·a, k·a, k·a).
- For the N-RAW rewrap of the same clip, F = 1 (k = 11.52) and C is the N-RAW matrix
  (10.8). Its render is therefore about half a stop brighter.

Auto exposure (only with `--auto`; not part of the reference command): once per run,
before rendering, the renderer reads one frame (`--frame N`, default 0) and takes every
s-th quad in row-major order, with s = max(⌊cw · ch / 20000⌋, 1). For each such quad it
computes the camera RGB without interpolation (R, mean of the normalised greens, B), the
steps of 12.4, and lin with E = 0. Then it takes the luminance
Y = 0.2126 · lin_R + 0.7152 · lin_G + 0.0722 · lin_B and the mean of log2(max(Y, 10^−5))
over the quads. The exposure is E = log2(0.18) − mean, rounded to 0.1 and clamped to
±7 (R3D NE) or ±5 (N-RAW). This one value is used for every frame.

### 12.6 Tone and colour controls (identity by default)

Next, the renderer applies the contrast, highlight, shadow, saturation and colour-boost
controls in scene linear, pivoted at 0.18, with the luminance weights 0.2627, 0.678 and
0.0593. With all controls at 0 (the only values the CLI can set) this step returns its
input unchanged, apart from float rounding. An implementation of the reference command can
skip it.

### 12.7 Tone curve, shoulder and output transfer function

The curve acts on each of the three channels R, G and B **separately** (not on
luminance). For a channel value x of lin:

1. Tone map (contrast around grey): t = 1.1 · 0.18 · (max(x, 0) / 0.18)^1.16. The
   exponent 1.16 is the "medium" tone map. The factor 1.1 always applies.
2. Shoulder (an extended Reinhard curve with white point L = 4, "medium" roll-off):
   y = t · (1 + t / L²) / (1 + t) · min(1 + 1 / L, 2) = t · (1 + t / 16) / (1 + t) · 1.25.
3. Clamp and transfer function: V = min(max(y, 0), 1)^(1 / 2.4).

Notes:
- Step 3 is a pure power law, the inverse of BT.1886 with zero black. It is **not** the
  BT.709 OETF (no linear segment near 0, no 1.099 and 0.099 constants).
- Negative channel values (out of the Rec.709 gamut after the matrix) become 0 in step 1.
- y reaches 1 at t = 2.319184 (the root of 0.078125 · t² + 0.25 · t − 1 = 0), that is, at
  x = 1.501550, 3.06 stops above grey. Every larger x gives V = 1. The shoulder never
  reaches its own white point. In the test clip, x = 1.50155 is a white-balanced
  normalised value of 1.50155 / k = 0.184333.
- Values of V for some x: 0 → 0; 0.01 → 0.137860; 0.05 → 0.295813; 0.18 → 0.521025;
  0.5 → 0.756127; 1 → 0.914100; 1.5016 and more → 1.
- The other settings the renderer knows (none can be chosen from the CLI): roll-off none
  (y = t), hard L = 2, soft L = 8, very soft L = 16; tone-map exponents none 1, low 1.08,
  high 1.26.

### 12.8 Quantisation and output encoding

1. **16-bit RGB.** Each channel is quantised to Q = round(V · 65535), V clamped to 0..1
   first. (The GPU path rounds to nearest; the CPU path computes ⌊V · 65535 + 0.5⌋. For the
   test frames the renderer's own check reports no difference.)
2. **P010 (10-bit 4:2:0, limited range, BT.709 matrix).** With R' = QR / 65535,
   G' = QG / 65535, B' = QB / 65535:
   - Y' = 0.2126 · R' + 0.7152 · G' + 0.0722 · B'.
   - Luma code: Y10 = min(max(round(64 + 876 · Y'), 0), 1023), per pixel.
   - Chroma, once per 2 × 2 block of pixels (rows 2m and 2m + 1, columns 2n and 2n + 1):
     Cb = ¼ · Σ (B' − Y') / (2 · (1 − 0.0722)) and Cr = ¼ · Σ (R' − Y') / (2 · (1 − 0.2126)),
     the sums over the four pixels of the block (a plain box average).
   - Chroma codes: Cb10 = min(max(round(512 + 896 · Cb), 0), 1023), and the same for Cr10.
   - Each 10-bit code is stored in the top 10 bits of a little-endian 16-bit word (the low
     6 bits are 0): a Y plane of ow × oh words, then one plane of interleaved Cb, Cr word
     pairs of (ow / 2) × (oh / 2) pairs. ow and oh must be even.
   - The box average puts the chroma sample at the centre of the block. The file does not
     record a chroma location, and FFmpeg assumes left siting when it converts back
     (**unverified** that this matters for the comparison).
   - There is no dithering.
3. **Encoder.** The renderer pipes these frames into an external `ffmpeg` (environment
   variable `BLUECOMPRESS_FFMPEG`, else an `ffmpeg` next to the program, else `PATH`, else
   `/opt/homebrew/bin` and `/usr/local/bin`). It takes the first HEVC encoder that works,
   in this order: `hevc_videotoolbox`, `hevc_nvenc`, `hevc_qsv`, `hevc_amf`, `hevc_vaapi`,
   `libx265`. If a hardware encoder refuses the frame size, it uses `libx265`. On an Apple Silicon Mac
   it is `hevc_videotoolbox`. The exact ffmpeg arguments seen for the reference command
   (test clip, 2026-11-08):
   `-hide_banner -v error -y -f rawvideo -pix_fmt p010le -s 1920x1080 -r 25 -i -`
   `-i <clip> -map 0:v:0 -map 1:a:0 -c:a pcm_f32le -shortest`
   `-vf setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv`
   `-c:v hevc_videotoolbox -profile:v main10 -b:v 25000k -pix_fmt p010le -tag:v hvc1`
   `-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv -f mov <out>.bluecompress.tmp`
   - Bitrate: 100,000 kb/s · (ow · oh) / (3840 · 2160) · max(fps / 25, 0.5), rounded and
     clamped to 8,000–400,000 kb/s. That gives 25,000 kb/s at 1920 × 1080, 25 fps.
     `--high` doubles it (clamp 16,000–800,000). `--kbps N` sets it directly. `--cbr`
     switches to constant bitrate.
   - With `libx265` the arguments are `-preset fast -pix_fmt yuv420p10le` instead of
     `-pix_fmt p010le`.
   - The HEVC step is lossy. The reference PNGs in `testdata/ref/view/` were made from this
     file with FFmpeg (`scale=in_color_matrix=bt709:in_range=tv:out_range=full`, rgb48),
     so they carry 4:2:0 chroma, HEVC loss and FFmpeg's chroma upsampling.

**Lossless or 16-bit output.** The CLI has no lossless, 16-bit, image-sequence, TIFF or
PNG output: `develop` always writes HEVC Main10 through ffmpeg. Three ways come close:
- `--stats` (with `--frame N`) renders one frame at 960 × ⌊960 · H / W⌋ (960 × 540 for the
  test clip; `--width` is ignored) to the 16-bit RGB of step 1 and prints, per channel,
  the mean / 65535, the minimum and the maximum, and an 8-bin histogram of G (bin =
  ⌊QG · 8 / 65536⌋). These numbers are exact, with no HEVC loss. Values for the test clip
  are in 12.11.
- `BLUECOMPRESS_FFMPEG=<program>` makes the renderer run another program in place of
  ffmpeg. A wrapper that passes the encoder probe calls on to a real ffmpeg, and for the
  call that has `-i -` saves stdin instead of encoding (then creates the empty output
  file, whose path is the last argument, and exits 0), receives the exact P010 frames of
  step 2, in frame order, ow · oh · 3 bytes each. This was tested on 2026-11-08 (12.11).
  It gives lossless 10-bit 4:2:0 limited-range frames, not 16-bit RGB.
- A higher bitrate (`--kbps 400000`, or `--high`) reduces the HEVC loss but does not
  remove it.
- The environment variable `BLUECOMPRESS_DEVELOP_CPU` (any value) forces the CPU renderer.
  It does not change the output format.

### 12.9 Other steps that can change pixel values

None of these runs with the reference command:
- Noise reduction (a bilateral filter on the quad planes before sampling): only when
  `--nr-luma` or `--nr-chroma` is above 0.
- Sharpening (an unsharp mask on the 16-bit RGB): N-RAW only, and only when the sharpness
  setting differs from its unity value. The CLI has no flag for it. R3D NE clips are never
  sharpened.
- A user LUT (`--lut`), applied to the 16-bit RGB before P010.
- Desqueeze changes the output width; conform changes only the frame rate.
- There is no dithering, grain, vignette or lens correction.

### 12.10 Worked example (test clip, R3D NE, defaults)

Neutral pixels in a flat area, so that interpolation does not change the values. "Raw"
is the `bayer_linear` value each plane needs for the pixel to be neutral after white
balance (Bk = 1008, range 15375, gains of 12.4, k = 8.1458701). The three channels give
the same 16-bit code here; the table shows the G channel. The reference computes in
float32, so its codes can differ from a double-precision computation by 1.

| Step | Mid-grey | White-balanced 0.18 | Sensor white |
| --- | --- | --- | --- |
| raw R / Gr = Gb / B | 1210.97 / 1347.74 / 1173.82 | 2661.40 / 3775.50 / 2358.77 | ≥ 10193.5 / 16383 / ≥ 8512.3 |
| N (12.2), G channel | 0.0220971 | 0.18 | 1 |
| w after gains and clamp (12.4) | (0.0220971, 0.0220971, 0.0220971) | (0.18, 0.18, 0.18) | (1, 1, 1) |
| lin = k · A · C · w, G (12.5) | 0.180001 | 1.466265 | 8.145915 |
| t, tone map (12.7 step 1) | 0.198001 | 2.256085 | 16.490709 |
| y, shoulder (step 2) | 0.209152 | 0.988229 | 2.393212 |
| V = clamp(y)^(1/2.4) (step 3) | 0.521026 | 0.995078 | 1 |
| Q, 16-bit (12.8 step 1) | 34145 | 65212 | 65535 |
| Y10 / Cb10 / Cr10 (step 2) | 520 / 512 / 512 | 936 / 512 / 512 | 940 / 512 / 512 |

The mid-grey column is the pixel whose scene-linear value is 0.18: a white-balanced
normalised value of 0.18 / k = 0.0220971.

### 12.11 Checks against the reference binary

Done on 2026-11-08 with the binary built from `4d35f31` (`testdata/oracle-bin/bin/bluecompress`),
the test clip and the `bayer_linear` dumps of `testdata/ref/A015_C004/`:
- A double-precision model written from 12.2–12.8 reproduces the `--stats` channel means
  of frame 0 to all four printed decimals: 0.3936, 0.3664, 0.4324.
- The P010 frames captured through `BLUECOMPRESS_FFMPEG` (12.8) for frame 0 at
  1920 × 1080 match the same model in 99.91 % of Y codes and 99.92 % of Cb and Cr codes;
  every other code differs by exactly 1 (float32 against double).
- Against `testdata/ref/view/f0000.png` (after HEVC), the model gives SSIM (All)
  0.937 and PSNR 38.2 dB when its P010 output goes through the same FFmpeg conversion to
  rgb48 as the reference PNG. Compared directly as 16-bit RGB, without the 4:2:0 round
  trip, SSIM (All) is only 0.751 (R 0.728, G 0.908, B 0.617). So a comparison with these
  PNGs needs the 4:2:0 round trip first, and its ceiling is about 0.94 because of the
  HEVC loss at ISO 6400.
- `--stats` output for the three test frames (16-bit RGB at 960 × 540; means are
  fractions of 65535; G histogram of 8 bins):

| Frame | Mean R | Mean G | Mean B | Min, max (every channel) | G histogram |
| --- | --- | --- | --- | --- | --- |
| 0 | 0.3936 | 0.3664 | 0.4324 | 0, 65535 | 95985, 126000, 76905, 69674, 61398, 38152, 20883, 29403 |
| 100 | 0.4002 | 0.3715 | 0.4399 | 0, 65535 | 89732, 124128, 82990, 68305, 62714, 40136, 21166, 29229 |
| 818 | 0.3944 | 0.3671 | 0.4322 | 0, 65535 | 95614, 122745, 78154, 72631, 61136, 36434, 21704, 29982 |
