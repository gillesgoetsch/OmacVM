#!/usr/bin/env python3
"""Draw Omarchy's logo (logo.svg from basecamp/omarchy, MIT) as the UEFI boot
logo: a 24-bit BMP, Omarchy green on black, for edk2's MdeModulePkg/Logo.

The wordmark is pixel art on a 15-unit grid (81 x 19 cells), so each cell
becomes an exact CELL x CELL block: sharp edges at any whole-number size.
Only the plain path commands logo.svg uses (m h v l z) are read.

  make-logo-bmp.py logo.svg Logo.bmp [CELL]   (CELL defaults to 5: 405 x 95)
"""
import re
import struct
import sys

GRID = 15                 # logo.svg units per cell
GREEN = (168, 205, 118)   # the colour of Omarchy's Plymouth logo (#a8cd76)


def polygons(d):
    """Subpaths of a path's d attribute as lists of (x, y) points."""
    out, poly, x, y, start = [], [], 0.0, 0.0, (0.0, 0.0)
    tokens = re.findall(r"[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)", d)
    i, cmd = 0, None
    while i < len(tokens):
        if tokens[i].isalpha():
            cmd = tokens[i]
            i += 1
            if cmd in "zZ":
                if poly:
                    out.append(poly)
                poly = []
                x, y = start     # z returns to the subpath's first point
                continue
        if cmd not in ("m", "h", "v", "l"):
            raise SystemExit(f"make-logo-bmp: unsupported path command {cmd!r}")
        if cmd == "h":
            x += float(tokens[i]); i += 1
        elif cmd == "v":
            y += float(tokens[i]); i += 1
        else:
            x += float(tokens[i]); y += float(tokens[i + 1]); i += 2
        if cmd == "m":
            if poly:
                out.append(poly)
            poly, start = [], (x, y)
            cmd = "l"     # numbers after m are line-tos
        poly.append((x, y))
    if poly:
        out.append(poly)
    return out


def inside(polys, px, py):
    """Even-odd test against all subpaths of one path."""
    hit = False
    for poly in polys:
        n = len(poly)
        for k in range(n):
            (x1, y1), (x2, y2) = poly[k], poly[(k + 1) % n]
            if (y1 > py) != (y2 > py) and px < x1 + (py - y1) * (x2 - x1) / (y2 - y1):
                hit = not hit
    return hit


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    svg = open(sys.argv[1], encoding="utf-8").read()
    cell = int(sys.argv[3]) if len(sys.argv) == 4 else 5
    w, h = (int(v) for v in re.search(r'viewBox="0 0 (\d+) (\d+)"', svg).groups())
    if w % GRID or h % GRID:
        raise SystemExit("make-logo-bmp: logo.svg is not on the 15-unit grid")
    paths = [polygons(d) for d in re.findall(r'<path[^>]* d="([^"]+)"', svg)]
    cols, rows = w // GRID, h // GRID
    on = [[any(inside(p, (c + .5) * GRID, (r + .5) * GRID) for p in paths)
           for c in range(cols)] for r in range(rows)]

    width, height = cols * cell, rows * cell
    stride = (width * 3 + 3) & ~3
    pixels = bytearray()
    for y in range(height - 1, -1, -1):            # BMP rows go bottom-up
        line = bytearray()
        for x in range(width):
            b = GREEN if on[y // cell][x // cell] else (0, 0, 0)
            line += bytes((b[2], b[1], b[0]))       # stored as B, G, R
        pixels += line + bytes(stride - len(line))
    header = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(pixels),
                       2835, 2835, 0, 0)
    with open(sys.argv[2], "wb") as f:
        f.write(header + info + pixels)


if __name__ == "__main__":
    main()
