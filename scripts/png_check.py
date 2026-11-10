#!/usr/bin/env python3
"""Tiny PNG analysis (stdlib only) used by the emulator E2E test.

usage: png_check.py colorful <file.png>   -> exit 0 if the bottom rows contain >= 6 distinct colours
       (i.e. the TV is showing the colour-bar test pattern rather than the dark idle screen)
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, width, height, ctype = 8, b"", 0, 0, 0
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and ctype in (2, 6), "unsupported PNG format"
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    i = 0
    for _ in range(height):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(line)
        prev = line
    return width, height, bpp, rows


def distinct_colors(path, y_fraction=0.85):
    w, h, bpp, rows = read_png(path)
    row = rows[int(h * y_fraction)]
    colors = set()
    for x in range(0, w, 20):
        px = row[x * bpp:x * bpp + 3]
        colors.add(tuple(c // 48 for c in px))
    return len(colors)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "colorful":
        print(__doc__)
        sys.exit(2)
    n = distinct_colors(sys.argv[2])
    print(f"distinct colours on sampled row: {n}")
    sys.exit(0 if n >= 6 else 1)
