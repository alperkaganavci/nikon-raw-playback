//! Black-box reference harness for the TICO RAW decoder. It links blue-compressor as a library
//! and is not part of the decoder (see docs/clean-room.md).
//!
//! Decodes one video frame of a Nikon R3D NE / N-RAW clip with blue-compressor 4d35f31 and
//! writes the four stage dumps and the frame JSON that `docs/format/tico-raw-nikon.md`
//! section 10 defines:
//!
//!   fNNNN.coeffs.bin         int32 LE, 4 x cw x ch, canonical coefficient layout
//!   fNNNN.planes_st.bin      int32 LE, 4 x cw x ch, after the inverse wavelet
//!   fNNNN.cfa_companded.bin  int32 LE, 4 x cw x ch, after the inverse Star-Tetrix
//!   fNNNN.bayer_linear.bin   uint16 LE, width x height, linear sensor mosaic
//!   fNNNN.json
//!
//! Usage: ticoraw-oracle <clip> <out_dir> <frame>...
//! Frames are processed one at a time; each stage is written as soon as it exists.

use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use bluecompress::bmff::{InputFile, Movie};
use bluecompress::develop;
use bluecompress::frame::{decode_frame, inverse_star_tetrix, inverse_wavelet, Coeffs, Planes, Transfer};
use bluecompress::nraw::NrawFrame;
use bluecompress::r3d;
use bluecompress::tico::{Layout, TicoHeader};

type Res<T> = Result<T, String>;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: {} <clip> <out_dir> <frame>...", args[0]);
        return ExitCode::from(2);
    }
    let clip = PathBuf::from(&args[1]);
    let out = PathBuf::from(&args[2]);
    let mut frames = Vec::new();
    for a in &args[3..] {
        match a.parse::<usize>() {
            Ok(f) => frames.push(f),
            Err(_) => {
                eprintln!("bad frame number: {a}");
                return ExitCode::from(2);
            }
        }
    }
    if let Err(e) = run(&clip, &out, &frames) {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn run(clip: &Path, out: &Path, frames: &[usize]) -> Res<()> {
    fs::create_dir_all(out).map_err(|e| format!("cannot create {}: {e}", out.display()))?;
    let input = InputFile::open(clip).map_err(|e| e.0)?;
    let movie = Movie::parse(&input).map_err(|e| e.0)?;
    // Clip-level view of the same metadata, as blue-compressor's renderer reads it; used
    // only to cross-check the per-frame values written to the JSON.
    let info = develop::clip_info(clip).map_err(|e| e.0)?;
    for &f in frames {
        dump_frame(&input, &movie, &info, f, out)?;
    }
    Ok(())
}

// Output helpers ---------------------------------------------------------------

/// A file written to `<name>.partial` and renamed into place on `finish`.
struct Dump {
    path: PathBuf,
    tmp: PathBuf,
    w: BufWriter<File>,
    bytes: u64,
}

impl Dump {
    fn create(dir: &Path, name: &str) -> Res<Dump> {
        let path = dir.join(name);
        let tmp = dir.join(format!("{name}.partial"));
        let f = File::create(&tmp).map_err(|e| format!("cannot create {}: {e}", tmp.display()))?;
        Ok(Dump { path, tmp, w: BufWriter::with_capacity(1 << 20, f), bytes: 0 })
    }
    fn i32s(&mut self, v: &[i32]) -> Res<()> {
        let mut b = Vec::with_capacity(4 * v.len());
        for x in v {
            b.extend_from_slice(&x.to_le_bytes());
        }
        self.raw(&b)
    }
    fn u16s(&mut self, v: &[u16]) -> Res<()> {
        let mut b = Vec::with_capacity(2 * v.len());
        for x in v {
            b.extend_from_slice(&x.to_le_bytes());
        }
        self.raw(&b)
    }
    fn raw(&mut self, b: &[u8]) -> Res<()> {
        self.w.write_all(b).map_err(|e| format!("write {}: {e}", self.tmp.display()))?;
        self.bytes += b.len() as u64;
        Ok(())
    }
    fn finish(self, expect: u64) -> Res<()> {
        let Dump { path, tmp, w, bytes } = self;
        let f = w.into_inner().map_err(|e| format!("flush {}: {e}", tmp.display()))?;
        f.sync_all().map_err(|e| format!("sync {}: {e}", tmp.display()))?;
        drop(f);
        if bytes != expect {
            return Err(format!("{}: wrote {bytes} bytes, expected {expect}", path.display()));
        }
        fs::rename(&tmp, &path).map_err(|e| format!("rename {}: {e}", path.display()))?;
        println!("  {}  {bytes} bytes", path.display());
        Ok(())
    }
}

// Codestream header fields (read from the header bytes blue-compressor keeps) ----

#[derive(Default)]
struct HeaderFields {
    width: u32,
    height: u32,
    nc: u32,
    ng: u32,
    ss: u32,
    bw: u32,
    fq: u32,
    br: u32,
    cpih: u32,
    nlx: u32,
    nly: u32,
    slice_height: u32,
    comp_depth: Vec<u32>,
    comp_sx: Vec<u32>,
    comp_sy: Vec<u32>,
}

fn be16(d: &[u8], at: usize) -> u32 {
    (d[at] as u32) << 8 | d[at + 1] as u32
}

/// Walks the marker segments of the header bytes (SOC up to the first slice) and returns
/// the body (after the 2-byte length) of the first segment with `marker`.
fn segment(raw: &[u8], marker: u32) -> Res<&[u8]> {
    if raw.len() < 2 || be16(raw, 0) != 0xff10 {
        return Err("header does not start with SOC".into());
    }
    let mut at = 2;
    while at + 4 <= raw.len() {
        let m = be16(raw, at);
        let len = be16(raw, at + 2) as usize;
        if len < 2 || at + 2 + len > raw.len() {
            return Err(format!("bad length of marker {m:04x}"));
        }
        if m == marker {
            return Ok(&raw[at + 4..at + 2 + len]);
        }
        at += 2 + len;
    }
    Err(format!("marker {marker:04x} not found"))
}

fn header_fields(h: &TicoHeader) -> Res<HeaderFields> {
    let pih = segment(&h.raw, 0xff12)?;
    if pih.len() < 24 {
        return Err("PIH too short".into());
    }
    let mut f = HeaderFields {
        width: be16(pih, 8),
        height: be16(pih, 10),
        slice_height: be16(pih, 14),
        nc: pih[16] as u32,
        ng: pih[17] as u32,
        ss: pih[18] as u32,
        bw: pih[19] as u32,
        fq: (pih[20] >> 4) as u32,
        br: (pih[20] & 15) as u32,
        cpih: (pih[21] & 15) as u32,
        nlx: (pih[22] >> 4) as u32,
        nly: (pih[22] & 15) as u32,
        ..Default::default()
    };
    let cdt = segment(&h.raw, 0xff13)?;
    let nc = f.nc as usize;
    if cdt.len() != 3 * nc {
        return Err(format!("CDT is {} bytes, expected 3 per component", cdt.len()));
    }
    for c in 0..nc {
        f.comp_depth.push(cdt[3 * c] as u32);
        f.comp_sx.push((cdt[3 * c + 1] >> 4) as u32);
        f.comp_sy.push((cdt[3 * c + 1] & 15) as u32);
    }
    Ok(f)
}

// Frame metadata (Nikon NRMT tags of this frame's wrapper) ------------------------

struct Meta {
    cfa: String,
    wb: [f32; 2],
    matrix: [f32; 9],
    iso: u32,
}

/// Big-endian f32 values of an NRMT value (first byte is a type byte, then the payload).
fn tag_floats(v: &[u8], n: usize) -> Option<Vec<f32>> {
    (v.len() == 1 + 4 * n).then(|| v[1..].chunks(4).map(|c| f32::from_be_bytes(c.try_into().unwrap())).collect())
}

fn frame_meta(sample: &[u8]) -> Res<Meta> {
    let tags = r3d::frame_tags(sample);
    let get = |id: u32| tags.iter().find(|t| t.0 == id).map(|t| t.1);
    let wb = get(0x0190_0009).and_then(|v| tag_floats(v, 2)).ok_or("frame has no white balance tag 0190/0009")?;
    let m = get(0x0190_0012).and_then(|v| tag_floats(v, 9)).ok_or("frame has no camera matrix tag 0190/0012")?;
    // JSON has no literal for NaN or infinity: refuse such a frame instead of writing it.
    if wb.iter().chain(m.iter()).any(|x| !x.is_finite()) {
        return Err("white balance or camera matrix tag holds a non-finite value".into());
    }
    let iso = get(0x0110_8832)
        .filter(|v| v.len() == 5)
        .map(|v| u32::from_be_bytes(v[1..5].try_into().unwrap()))
        .ok_or("frame has no ISO tag 0110/8832")?;
    // EXIF CFAPattern: type byte, u16 columns, u16 rows, then one colour code per site
    // (0 red, 1 green, 2 blue), row by row.
    let cfa_v = get(0x0110_a302).ok_or("frame has no CFA pattern tag 0110/a302")?;
    if cfa_v.len() != 9 || be16(cfa_v, 1) != 2 || be16(cfa_v, 3) != 2 {
        return Err("CFA pattern tag is not a 2x2 pattern".into());
    }
    let mut cfa = String::new();
    for &k in &cfa_v[5..9] {
        cfa.push(match k {
            0 => 'R',
            1 => 'G',
            2 => 'B',
            _ => return Err(format!("unknown CFA colour code {k}")),
        });
    }
    Ok(Meta { cfa, wb: [wb[0], wb[1]], matrix: m.try_into().unwrap(), iso })
}

// One frame --------------------------------------------------------------------

fn dump_frame(input: &InputFile, movie: &Movie, info: &develop::ClipInfo, index: usize, out: &Path) -> Res<()> {
    let video = movie.video();
    let s = *video.samples.get(index).ok_or_else(|| format!("frame {index} out of range ({} frames)", video.samples.len()))?;
    println!("frame {index}: sample at {} ({} bytes)", s.offset, s.size);
    let sample = input.read(s.offset, s.size as usize).map_err(|e| e.0)?;
    let nf = NrawFrame::parse(&sample).map_err(|e| e.0)?;
    let cs = &sample[nf.codestream_offset..];
    let (h, _) = TicoHeader::parse(cs).map_err(|e| e.0)?;
    let l = Layout::make(&h, h.width as usize, h.height as usize).map_err(|e| e.0)?;
    let hf = header_fields(&h)?;
    let meta = frame_meta(&sample)?;

    let (width, height, cw, ch) = (l.width, l.height, l.cw, l.ch);
    if cw * 2 != width || ch * 2 != height || hf.width as usize != width || hf.height as usize != height {
        return Err("inconsistent frame size".into());
    }
    if meta.cfa != "RGGB" {
        return Err(format!("CFA {} not supported by this oracle (only RGGB)", meta.cfa));
    }
    let white_level: u32 = 16383;
    if hf.comp_depth.iter().any(|&d| (1u32 << d) - 1 != white_level) {
        return Err("component depth does not match the 14-bit white level".into());
    }
    // Cross-check with blue-compressor's clip-level reading (frame 0 tags, NCTG ISO).
    if info.iso != meta.iso || info.wb != meta.wb || info.matrix != meta.matrix {
        eprintln!(
            "warning: frame {index} metadata differs from blue-compressor's clip_info \
             (iso {} vs {}, wb {:?} vs {:?})",
            meta.iso, info.iso, meta.wb, info.wb
        );
    }

    let plane_bytes = (cw * ch * 4) as u64;
    let stem = format!("f{index:04}");

    // Stage 1: dequantized coefficients, canonical layout.
    let mut coeffs = vec![0i32; Coeffs::len(&l)];
    decode_frame(cs, &h, &l, &mut coeffs).map_err(|e| e.0)?;
    let cv = Coeffs { cw, precincts: l.precincts, data: Vec::new() };
    // Canonical layout: per component a cw x ch plane; plane row 2k is precinct k's
    // vertical low-pass line, row 2k+1 its vertical high-pass line (the phantom high line
    // of the last precinct of an odd ch is dropped). Each row keeps its horizontal bands
    // side by side (lowest band first). For the component without a wavelet the two
    // lines are the even and odd component rows.
    let mut no_wavelet_coeffs: Vec<(usize, Vec<i32>)> = Vec::new();
    {
        let mut d = Dump::create(out, &format!("{stem}.coeffs.bin"))?;
        for c in 0..4 {
            let keep = l.levels[c] == 0;
            let mut kept = Vec::new();
            for r in 0..ch {
                let at = cv.row_offset(c, r % 2 == 1, r / 2);
                let row = &coeffs[at..at + cw];
                d.i32s(row)?;
                if keep {
                    kept.extend_from_slice(row);
                }
            }
            if keep {
                no_wavelet_coeffs.push((c, kept));
            }
        }
        d.finish(4 * plane_bytes)?;
    }

    // Stage 2: inverse wavelet (Star-Tetrix domain).
    let mut pl = Planes::default();
    inverse_wavelet(&l, &mut coeffs, &mut pl);
    drop(coeffs);
    if pl.w != cw || pl.h != ch {
        return Err("unexpected plane size".into());
    }
    for (c, kept) in &no_wavelet_coeffs {
        if pl.plane(*c) != kept.as_slice() {
            return Err(format!("component {c} has no wavelet but its planes differ from its coefficients"));
        }
    }
    drop(no_wavelet_coeffs);
    {
        let mut d = Dump::create(out, &format!("{stem}.planes_st.bin"))?;
        for c in 0..4 {
            d.i32s(pl.plane(c))?;
        }
        d.finish(4 * plane_bytes)?;
    }

    // Stage 3: inverse Star-Tetrix (CFA planes Gr, R, Gb, B; companded code domain).
    inverse_star_tetrix(&mut pl);
    {
        let mut d = Dump::create(out, &format!("{stem}.cfa_companded.bin"))?;
        for c in 0..4 {
            d.i32s(pl.plane(c))?;
        }
        d.finish(4 * plane_bytes)?;
    }

    // Stage 4: transfer curve to linear 14-bit, written as the RGGB mosaic.
    // Plane at quad position (row parity, column parity): (0,0) R = 1, (0,1) Gr = 0,
    // (1,0) Gb = 2, (1,1) B = 3.
    let tr = Transfer::new(&h);
    const PLANE_AT: [[usize; 2]; 2] = [[1, 0], [2, 3]];
    {
        let mut d = Dump::create(out, &format!("{stem}.bayer_linear.bin"))?;
        let mut row = vec![0u16; width];
        for y in 0..height {
            let base = (y / 2) * cw;
            let pa = PLANE_AT[y & 1];
            let (p0, p1) = (pl.plane(pa[0]), pl.plane(pa[1]));
            for x in 0..cw {
                row[2 * x] = tr.to_raw(p0[base + x]);
                row[2 * x + 1] = tr.to_raw(p1[base + x]);
            }
            d.u16s(&row)?;
        }
        d.finish((width * height * 2) as u64)?;
    }
    drop(pl);

    // Frame JSON.
    let list = |v: &[u32]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(", ");
    // Floats: the single-precision tag value widened to f64, printed as the shortest
    // decimal that round-trips to that f64 (Rust's `{:?}`).
    let fl = |x: f32| format!("{:?}", x as f64);
    let json = format!(
        "{{\n  \"width\": {width},\n  \"height\": {height},\n  \"cw\": {cw},\n  \"ch\": {ch},\n  \"meta\": {{\n    \
         \"cfa\": \"{}\",\n    \"wb_gain\": [{}, 1.0, {}],\n    \"cam_to_xyz\": [{}],\n    \"iso\": {},\n    \
         \"white_level\": {white_level}\n  }},\n  \"header\": {{\n    \"width\": {},\n    \"height\": {},\n    \
         \"nc\": {},\n    \"ng\": {},\n    \"ss\": {},\n    \"bw\": {},\n    \"fq\": {},\n    \"br\": {},\n    \
         \"cpih\": {},\n    \"nlx\": {},\n    \"nly\": {},\n    \"slice_height\": {},\n    \"comp_depth\": [{}],\n    \
         \"comp_sx\": [{}],\n    \"comp_sy\": [{}]\n  }}\n}}\n",
        meta.cfa,
        fl(meta.wb[0]),
        fl(meta.wb[1]),
        meta.matrix.iter().map(|&x| fl(x)).collect::<Vec<_>>().join(", "),
        meta.iso,
        hf.width,
        hf.height,
        hf.nc,
        hf.ng,
        hf.ss,
        hf.bw,
        hf.fq,
        hf.br,
        hf.cpih,
        hf.nlx,
        hf.nly,
        hf.slice_height,
        list(&hf.comp_depth),
        list(&hf.comp_sx),
        list(&hf.comp_sy),
    );
    let mut d = Dump::create(out, &format!("{stem}.json"))?;
    d.raw(json.as_bytes())?;
    d.finish(json.len() as u64)?;
    Ok(())
}
