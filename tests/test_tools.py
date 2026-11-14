"""Tests for tools/extract_frame.py and tools/compare_stage.py (stdlib unittest)."""
import array
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTRACT = os.path.join(ROOT, "tools", "extract_frame.py")
COMPARE = os.path.join(ROOT, "tools", "compare_stage.py")
# The test clip: set CLIP to the path of a Nikon ZR .R3D clip. Tests that need it are skipped
# (with a message) when CLIP is not set or the file does not exist.
CLIP = os.environ.get("CLIP", "")
REF_JSON = os.path.join(ROOT, "testdata", "ref", "A015_C004", "f0000.json")


def run(*args):
    return subprocess.run([sys.executable, *args], capture_output=True, text=True)


def write_i32(path, values):
    with open(path, "wb") as f:
        array.array("i", values).tofile(f)


class ExtractFrameTest(unittest.TestCase):
    @unittest.skipUnless(CLIP and os.path.exists(CLIP), "set CLIP=/path/to/clip.R3D to run this test")
    def test_extract_frame0(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "f0000.bin")
            r = run(EXTRACT, CLIP, "0", out)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(os.path.getsize(out), 7750656)
            with open(out, "rb") as f:
                data = f.read(1026)
            self.assertEqual(data[0:4], bytes([0x00, 0x76, 0x44, 0x00]))
            self.assertEqual(data[4:8], b"NRAW")
            self.assertEqual(data[1024:1026], bytes([0xFF, 0x10]))

    @unittest.skipUnless(os.path.exists(CLIP), "test clip not present")
    def test_extract_bad_index(self):
        with tempfile.TemporaryDirectory() as d:
            r = run(EXTRACT, CLIP, "99999", os.path.join(d, "x.bin"))
            self.assertNotEqual(r.returncode, 0)


class CompareStageTest(unittest.TestCase):
    W, H, P = 4, 5, 2  # planes 0..1, each 4 x 5

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        n = self.W * self.H * self.P
        self.base = [i * 3 - 20 for i in range(n)]
        self.ours = os.path.join(self.tmp.name, "ours.bin")
        self.ref = os.path.join(self.tmp.name, "ref.bin")
        write_i32(self.ref, self.base)

    def cmp(self, *extra):
        return run(COMPARE, self.ours, self.ref, "--dtype", "int32",
                   "--planes", str(self.P), "--width", str(self.W),
                   "--height", str(self.H), *extra)

    def mutate(self, plane, x, y, delta):
        v = list(self.base)
        v[plane * self.W * self.H + y * self.W + x] += delta
        write_i32(self.ours, v)

    def test_compare_equal(self):
        write_i32(self.ours, self.base)
        r = self.cmp()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_compare_first_mismatch(self):
        v = list(self.base)
        # later mismatch first in the list to prove the first by position is reported
        v[1 * 20 + 4 * 3 + 3] += 9
        v[1 * 20 + 3 * 4 + 2] += 5  # plane 1, x 2, y 3
        write_i32(self.ours, v)
        r = self.cmp()
        self.assertEqual(r.returncode, 1)
        self.assertIn("plane=1 x=2 y=3", r.stdout)
        self.assertIn("ours=%d ref=%d" % (self.base[1 * 20 + 14] + 5, self.base[1 * 20 + 14]), r.stdout)
        self.assertIn("MISMATCH: 2 sample(s) differ by more than 0", r.stdout)  # mismatch count

    def test_compare_tolerance(self):
        self.mutate(1, 2, 3, 1)
        self.assertEqual(self.cmp("--tolerance", "1").returncode, 0)
        self.assertEqual(self.cmp().returncode, 1)
        self.mutate(1, 2, 3, 2)
        self.assertEqual(self.cmp("--tolerance", "1").returncode, 1)

    def test_compare_rows_from(self):
        self.mutate(0, 1, 1, 7)
        self.assertEqual(self.cmp("--rows-from", "2").returncode, 0)
        self.assertEqual(self.cmp("--rows-from", "1").returncode, 1)

    def test_compare_cols_from(self):
        # a difference left of X is ignored; one at or right of X fails with the absolute x
        self.mutate(1, 1, 2, 7)
        self.assertEqual(self.cmp("--cols-from", "2").returncode, 0)
        self.assertEqual(self.cmp("--cols-from", "1").returncode, 1)
        self.mutate(1, 2, 3, 5)  # at X
        r = self.cmp("--cols-from", "2")
        self.assertEqual(r.returncode, 1)
        self.assertIn("plane=1 x=2 y=3", r.stdout)
        self.mutate(0, 3, 4, 5)  # last column, last row, plane 0
        r = self.cmp("--cols-from", "3")
        self.assertEqual(r.returncode, 1)
        self.assertIn("plane=0 x=3 y=4", r.stdout)
        # combined with --rows-from: the row limit still applies
        self.mutate(0, 3, 1, 5)
        self.assertEqual(self.cmp("--cols-from", "3", "--rows-from", "2").returncode, 0)
        r = self.cmp("--cols-from", "3", "--rows-from", "1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("plane=0 x=3 y=1", r.stdout)

    def test_compare_size_mismatch(self):
        write_i32(self.ours, self.base[:-1])
        self.assertEqual(self.cmp().returncode, 1)

    def test_compare_uint16(self):
        a = array.array("H", [1, 2, 3, 4, 5, 6])
        b = array.array("H", [1, 2, 3, 9, 5, 6])
        with open(self.ours, "wb") as f:
            b.tofile(f)
        with open(self.ref, "wb") as f:
            a.tofile(f)
        r = run(COMPARE, self.ours, self.ref, "--dtype", "uint16", "--planes", "1",
                "--width", "3", "--height", "2")
        self.assertEqual(r.returncode, 1)
        self.assertIn("plane=0 x=0 y=1 ours=9 ref=4", r.stdout)

    def test_compare_chunk_boundaries(self):
        # mismatch in the second read chunk; exercises chunked reading
        w, h = 1000, 3000  # 12 MB per file, larger than one read chunk
        base = array.array("i", range(w * h))
        bad = array.array("i", base)
        bad[2500 * w + 321] += 1
        write_i32(self.ref, base)
        write_i32(self.ours, bad)
        r = run(COMPARE, self.ours, self.ref, "--dtype", "int32", "--planes", "1",
                "--width", str(w), "--height", str(h))
        self.assertEqual(r.returncode, 1)
        self.assertIn("plane=0 x=321 y=2500", r.stdout)

    def jcmp(self, a, b, section):
        pa = os.path.join(self.tmp.name, "a.json")
        pb = os.path.join(self.tmp.name, "b.json")
        for p, d in ((pa, a), (pb, b)):
            with open(p, "w") as f:
                json.dump(d, f)
        return run(COMPARE, "--json", pa, pb, "--section", section)

    def test_compare_json_meta(self):
        meta = {"cfa": "RGGB", "wb_gain": [1.673828125, 1.0, 2.048828125], "iso": 6400,
                "white_level": 16383}
        a = {"meta": meta}
        self.assertEqual(self.jcmp(a, {"meta": dict(meta)}, "meta").returncode, 0)
        near = dict(meta, wb_gain=[1.673828125 + 5e-5, 1.0, 2.048828125])
        self.assertEqual(self.jcmp(a, {"meta": near}, "meta").returncode, 0)
        bad = dict(meta, wb_gain=[1.673828125 + 0.01, 1.0, 2.048828125])
        r = self.jcmp(a, {"meta": bad}, "meta")
        self.assertEqual(r.returncode, 1)
        self.assertIn("wb_gain", r.stdout)

    def test_compare_json_strings_lengths_keys(self):
        meta = {"cfa": "RGGB", "wb_gain": [1.0, 1.0, 1.0]}
        a = {"meta": meta}
        self.assertEqual(self.jcmp(a, {"meta": dict(meta, cfa="BGGR")}, "meta").returncode, 1)
        self.assertEqual(self.jcmp(a, {"meta": dict(meta, wb_gain=[1.0, 1.0])}, "meta").returncode, 1)
        self.assertEqual(self.jcmp(a, {"meta": dict(meta, extra=1)}, "meta").returncode, 1)
        missing = {"cfa": "RGGB"}
        self.assertEqual(self.jcmp(a, {"meta": missing}, "meta").returncode, 1)

    def test_compare_json_header_section_only(self):
        a = {"meta": {"iso": 1}, "header": {"nc": 4}}
        b = {"meta": {"iso": 2}, "header": {"nc": 4}}
        self.assertEqual(self.jcmp(a, b, "header").returncode, 0)
        self.assertEqual(self.jcmp(a, b, "meta").returncode, 1)

    @unittest.skipUnless(os.path.exists(REF_JSON), "reference JSON not present")
    def test_compare_json_real_reference(self):
        for section in ("meta", "header"):
            r = run(COMPARE, "--json", REF_JSON, REF_JSON, "--section", section)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
