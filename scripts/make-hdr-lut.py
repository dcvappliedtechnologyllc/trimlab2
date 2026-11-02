#!/usr/bin/env python3 -I
"""Bake v1's HDR -> SDR conversion into 3D LUTs for the compositor (regeneration only; the app never runs ffmpeg).

    python3 -I scripts/make-hdr-lut.py [--size 65] [--check 4000]

For each HDR transfer (HLG, PQ) it builds a lattice of BT.2020 R'G'B' code values in that transfer, runs it
through v1's exact chain (trimlab/core/filters.py HDR_ZSCALE) with ffmpeg-full, and writes the BT.709 R'G'B'
results to Packages/TrimlabKit/Sources/TrimlabMedia/Resources/<name>.lut, and the ffmpeg version and build line
it used to LUT-PROVENANCE.txt beside them.

v1's chain ends `zscale=t=bt709:m=bt709:r=tv,format=yuv420p`. Here the last step stops at BT.709 R'G'B' float
(`zscale=t=bt709,format=gbrpf32le`): Y'CbCr encoding is the compositor's encoder's job, and 4:2:0 would blend
neighbouring lattice points. Everything before it is v1's chain verbatim.

File format (little-endian): magic b"TLUT", uint32 size N, then N^3 cells of R, G, B as uint16 (value * 65535),
red varying fastest, then green, then blue (CIColorCube's order). Values are clamped to 0...1.

--check K also runs K random R'G'B' points plus a neutral ramp straight through the chain and reports the largest
difference from tetrahedral interpolation of the lattice (as the compositor does), in 8-bit code values.
"""
import argparse
import os
import random
import struct
import subprocess
import sys

FFMPEG = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
CHAIN = ("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,"
         "zscale=t=bt709,format=gbrpf32le")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Packages/TrimlabKit/Sources/TrimlabMedia/Resources")
TRANSFERS = [("hlg_to_sdr_v1.lut", "arib-std-b67"), ("pq_to_sdr_v1.lut", "smpte2084")]


def run_chain(points, trc):
    """points: list of (r, g, b) in 0...1, BT.2020 in transfer `trc`. Returns BT.709 R'G'B' per point."""
    n = len(points)
    width = 1024
    height = (n + width - 1) // width
    pad = points + [(0.0, 0.0, 0.0)] * (width * height - n)
    planes = [[p[1] for p in pad], [p[2] for p in pad], [p[0] for p in pad]]  # gbrp plane order: G, B, R
    raw = b"".join(struct.pack("<%df" % len(pl), *pl) for pl in planes)
    out = subprocess.run(
        [FFMPEG, "-v", "error", "-f", "rawvideo", "-pix_fmt", "gbrpf32le", "-s", f"{width}x{height}",
         "-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "rgb", "-i", "-",
         "-vf", CHAIN, "-f", "rawvideo", "-pix_fmt", "gbrpf32le", "-"],
        input=raw, capture_output=True, check=True).stdout
    count = width * height
    if len(out) != count * 12:
        sys.exit(f"ffmpeg returned {len(out)} bytes, expected {count * 12}")
    vals = struct.unpack("<%df" % (count * 3), out)
    g, b, r = vals[:count], vals[count:2 * count], vals[2 * count:]
    return [(r[i], g[i], b[i]) for i in range(n)]


def clamp(v):
    return 0.0 if v != v or v < 0 else 1.0 if v > 1 else v


def lattice(size):
    s = size - 1
    return [(ri / s, gi / s, bi / s) for bi in range(size) for gi in range(size) for ri in range(size)]


def tetrahedral(cells, size, p):
    """The compositor's interpolation (HDRToSDR.metal): tetrahedral, so neutral greys use only diagonal nodes."""
    s = size - 1
    idx, f = [], []
    for c in p:
        x = clamp(c) * s
        i = min(int(x), s - 1)
        idx.append(i)
        f.append(x - i)

    def c(dr, dg, db):
        return cells[(idx[0] + dr) + size * ((idx[1] + dg) + size * (idx[2] + db))]

    fr, fg, fb = f
    if fr >= fg:
        if fg >= fb:
            terms = [(1 - fr, c(0, 0, 0)), (fr - fg, c(1, 0, 0)), (fg - fb, c(1, 1, 0)), (fb, c(1, 1, 1))]
        elif fr >= fb:
            terms = [(1 - fr, c(0, 0, 0)), (fr - fb, c(1, 0, 0)), (fb - fg, c(1, 0, 1)), (fg, c(1, 1, 1))]
        else:
            terms = [(1 - fb, c(0, 0, 0)), (fb - fr, c(0, 0, 1)), (fr - fg, c(1, 0, 1)), (fg, c(1, 1, 1))]
    else:
        if fb >= fg:
            terms = [(1 - fb, c(0, 0, 0)), (fb - fg, c(0, 0, 1)), (fg - fr, c(0, 1, 1)), (fr, c(1, 1, 1))]
        elif fb >= fr:
            terms = [(1 - fg, c(0, 0, 0)), (fg - fb, c(0, 1, 0)), (fb - fr, c(0, 1, 1)), (fr, c(1, 1, 1))]
        else:
            terms = [(1 - fg, c(0, 0, 0)), (fg - fr, c(0, 1, 0)), (fr - fb, c(1, 1, 0)), (fb, c(1, 1, 1))]
    return [sum(w * cell[k] for w, cell in terms) for k in range(3)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=65)
    ap.add_argument("--check", type=int, default=0)
    args = ap.parse_args()
    if not os.access(FFMPEG, os.X_OK):
        sys.exit(f"ffmpeg-full not found at {FFMPEG}")
    os.makedirs(OUT, exist_ok=True)
    size = args.size
    version = subprocess.run([FFMPEG, "-version"], capture_output=True, text=True, check=True).stdout.splitlines()
    tool = [line for line in version if line.startswith(("ffmpeg version", "built with"))]
    print("\n".join(tool))
    with open(os.path.join(OUT, "LUT-PROVENANCE.txt"), "w") as f:
        f.write("Generated by scripts/make-hdr-lut.py (not a bundle resource).\n"
                f"Lattice: {size}^3; chain: {CHAIN}\n" + "\n".join(tool) + "\n")
    for name, trc in TRANSFERS:
        cells = [tuple(clamp(v) for v in c) for c in run_chain(lattice(size), trc)]
        q = [round(v * 65535) for c in cells for v in c]
        path = os.path.join(OUT, name)
        with open(path, "wb") as f:
            f.write(b"TLUT" + struct.pack("<I", size) + struct.pack("<%dH" % len(q), *q))
        print(f"{name}: {size}^3, {os.path.getsize(path)} bytes")
        if args.check:
            rnd = random.Random(1)
            pts = [(rnd.random(), rnd.random(), rnd.random()) for _ in range(args.check)]
            pts += [(i / 876, i / 876, i / 876) for i in range(877)]
            exact = run_chain(pts, trc)
            worst, worst_grey, total = 0.0, 0.0, 0.0
            for i, (p, e) in enumerate(zip(pts, exact)):
                got = tetrahedral(cells, size, p)
                err = max(abs(got[k] - clamp(e[k])) for k in range(3)) * 255
                worst = max(worst, err)
                total += err
                if i >= args.check:
                    worst_grey = max(worst_grey, err)
            print(f"  check: |LUT - chain| over {len(pts)} points: max {worst:.2f} codes, mean {total / len(pts):.3f}; "
                  f"neutral ramp max {worst_grey:.2f}")


if __name__ == "__main__":
    main()
