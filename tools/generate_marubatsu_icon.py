#!/usr/bin/env python3
"""AppIcon-1024.png を標準ライブラリだけで生成する（CI用）。
512pxで描画して2倍に拡大する。白背景に3x3の罫、左上に赤い○、
右下に青い×、右上にはみ出す枠外マスにオレンジの点線枠。"""
import math
import struct
import zlib

OUT = "MaruBatsu/MaruBatsu/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
N = 512


def dist_segment(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy or 1.0
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_sq))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def pixel(x, y):
    r, g, b = 248, 248, 246  # 白背景
    cell = N / 3.0
    # 罫線（縦2本・横2本）
    for gx in (cell, 2 * cell):
        if abs(x - gx) < 7:
            r, g, b = 40, 40, 48
    for gy in (cell, 2 * cell):
        if abs(y - gy) < 7:
            r, g, b = 40, 40, 48
    # 左上セルに赤い○
    d = math.hypot(x - cell / 2, y - cell / 2)
    if abs(d - 52) < 11:
        r, g, b = 225, 45, 45
    # 右下セルに青い×
    cx, cy = 2.5 * cell, 2.5 * cell
    d1 = dist_segment(x, y, (cx - 48, cy - 48), (cx + 48, cy + 48))
    d2 = dist_segment(x, y, (cx - 48, cy + 48), (cx + 48, cy - 48))
    if min(d1, d2) < 11:
        r, g, b = 45, 85, 225
    # 右上セルの右に「枠外」マス風のオレンジ枠（右端にはみ出す）
    ox0, oy0, osz = N - 118, 26, 92
    if ox0 <= x < ox0 + osz and oy0 <= y < oy0 + osz:
        edge = min(x - ox0, ox0 + osz - 1 - x, y - oy0, oy0 + osz - 1 - y)
        if edge < 9:
            r, g, b = 245, 140, 20
        elif ox0 + 30 <= x < ox0 + osz - 30 and oy0 + 30 <= y < oy0 + osz - 30:
            r, g, b = 245, 140, 20
    return (r, g, b)


def main():
    raw = bytearray()
    for y in range(N):
        row = bytearray(b"\x00")
        for x in range(N):
            row += bytes(pixel(x, y))
        wide = bytearray(b"\x00")
        for i in range(1, len(row), 3):
            wide += row[i:i + 3] * 2
        raw += wide + wide

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(OUT, "wb") as f:
        f.write(png)
    print("wrote", OUT, len(png), "bytes")


if __name__ == "__main__":
    main()
