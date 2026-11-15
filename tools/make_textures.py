#!/usr/bin/env python3
"""Generate Oldman Java's UI textures as 32-bit TGA (white RGB + alpha, tinted in game).

Shapes are drawn from signed distance functions with 4x4 supersampling for clean edges.
Usage: python3 tools/make_textures.py [preview.png]
"""
import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "OldmanJava", "media")
SS = 4


def rounded_rect_sdf(x, y, w, h, r, inset=0.0):
    cx, cy = w / 2, h / 2
    hx, hy = w / 2 - inset - r, h / 2 - inset - r
    qx, qy = abs(x - cx) - hx, abs(y - cy) - hy
    outside = math.hypot(max(qx, 0), max(qy, 0))
    inside = min(max(qx, qy), 0)
    return outside + inside - r


def circle_sdf(x, y, w, h, r):
    return math.hypot(x - w / 2, y - h / 2) - r


def render(w, h, alpha_at):
    rows = []
    for py in range(h):
        row = []
        for px in range(w):
            total = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    total += alpha_at(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS)
            row.append(max(0, min(255, round(255 * total / (SS * SS)))))
        rows.append(row)
    return rows


def fill(d):
    return 1.0 if d <= 0 else 0.0


def stroke(d, width):
    return 1.0 if abs(d + width / 2) <= width / 2 else 0.0


def write_tga(path, rows):
    h, w = len(rows), len(rows[0])
    with open(path, "wb") as f:
        # uncompressed true colour, 32 bpp, 8 alpha bits, bottom-left origin (rows bottom-up)
        f.write(struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x08))
        for row in reversed(rows):
            for a in row:
                f.write(bytes((255, 255, 255, a)))


ARROW = [(0.50, 0.05), (0.90, 0.90), (0.50, 0.68), (0.10, 0.90)]


def in_poly(x, y, poly):
    inside, j = False, len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def shapes():
    out = {}
    # Direction arrow, pointing up.
    out["arrow"] = render(64, 64, lambda x, y: 1.0 if in_poly(x / 64, y / 64, ARROW) else 0.0)
    # Panel body and its hairline border: 64x64, radius 12 (9-slice margins 16).
    out["panel"] = render(64, 64, lambda x, y: fill(rounded_rect_sdf(x, y, 64, 64, 12)))
    out["border"] = render(64, 64, lambda x, y: stroke(rounded_rect_sdf(x, y, 64, 64, 12), 1.0))
    # Soft drop shadow: rounded rect inset 16, blurred over 14 px (9-slice margins 28).
    def shadow(x, y):
        d = rounded_rect_sdf(x, y, 64, 64, 12, inset=16)
        t = max(0.0, min(1.0, 1 - (d + 2) / 16))
        return t * t * (3 - 2 * t)
    out["shadow"] = render(64, 64, shadow)
    # Pill for buttons and fields: 32x32, radius 8 (9-slice margins 8 leave a 16 px stretchable middle).
    out["pill"] = render(32, 32, lambda x, y: fill(rounded_rect_sdf(x, y, 32, 32, 8)))
    # Thin bar for progress: 16x8, radius 3 (9-slice margins 3), works at heights of 6 px and up.
    out["bar"] = render(16, 8, lambda x, y: fill(rounded_rect_sdf(x, y, 16, 8, 3)))
    # Soft radial glow for map areas: opaque centre fading smoothly to nothing at the edge.
    def glow(x, y):
        r = math.hypot(x - 32, y - 32) / 31
        return max(0.0, 1 - r * r) ** 2
    out["glow"] = render(64, 64, glow)
    # Logo: a coffee cup on a saucer with two wisps of steam.
    def cup(x, y):
        # body: rounded box, wider at the rim
        if 22 <= y <= 50:
            t = (y - 22) / 28
            half = 16 - 3 * t
            if abs(x - 30) <= half:
                if y > 44:  # rounded bottom corners
                    cx = 30 - half + 6 if x < 30 else 30 + half - 6
                    if abs(x - 30) > half - 6 and math.hypot(x - cx, y - 44) > 6:
                        return 0.0
                return 1.0
        # handle: right-side ring
        r = math.hypot(x - 47, y - 33)
        if x > 44 and 4.5 <= r <= 9:
            return 1.0
        # saucer
        if 52 <= y <= 56 and abs(x - 31) <= 24 - (y - 52) * 0.8:
            return 1.0
        # steam: two gentle S-curves
        for sx in (24, 35):
            if 4 <= y <= 18:
                wave = sx + 2.6 * math.sin((y - 4) / 14 * 2 * math.pi)
                if abs(x - wave) <= 1.5:
                    return 1.0
        return 0.0
    out["cup"] = render(64, 64, cup)
    # Compass: filled disc and a 2 px ring.
    out["disc"] = render(64, 64, lambda x, y: fill(circle_sdf(x, y, 64, 64, 31)))
    out["ring"] = render(64, 64, lambda x, y: stroke(circle_sdf(x, y, 64, 64, 31), 2.0))
    return out


def write_preview(path, textures):
    # Composite each texture (tinted) on a dark background, side by side, at 2x.
    tint = (79, 195, 247)
    scale, pad = 2, 8
    tiles = list(textures.items())
    width = sum(len(r[0]) * scale + pad for _, r in tiles) + pad
    height = max(len(r) for _, r in tiles) * scale + pad * 2
    canvas = [[(20, 22, 28)] * width for _ in range(height)]
    x0 = pad
    for _, rows in tiles:
        for y, row in enumerate(rows):
            for x, a in enumerate(row):
                al = a / 255
                for dy in range(scale):
                    for dx in range(scale):
                        cx, cy = x0 + x * scale + dx, pad + y * scale + dy
                        bg = canvas[cy][cx]
                        canvas[cy][cx] = tuple(round(bg[k] * (1 - al) + tint[k] * al) for k in range(3))
        x0 += len(rows[0]) * scale + pad
    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in canvas)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    open(path, "wb").write(png)


def main():
    os.makedirs(MEDIA, exist_ok=True)
    textures = shapes()
    for name, rows in textures.items():
        write_tga(os.path.join(MEDIA, name + ".tga"), rows)
        print("wrote media/%s.tga (%dx%d)" % (name, len(rows[0]), len(rows)))
    if len(sys.argv) > 1:
        write_preview(sys.argv[1], textures)


if __name__ == "__main__":
    main()
