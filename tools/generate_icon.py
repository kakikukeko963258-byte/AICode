#!/usr/bin/env python3
"""AppIcon-1024.png を標準ライブラリだけで生成する（CI用）。
512pxで描画して2倍に拡大する。暗い青の夜景グラデーションに
赤と青白の光跡が奥の一点へ収束するデザイン。"""
import math
import struct
import zlib

OUT = "TrailCam/TrailCam/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
N = 512  # 描画解像度（最終的に1024へ拡大）

SEGMENTS_RED = [((70, 512), (200, 380)), ((200, 380), (330, 320)), ((330, 320), (262, 250))]
SEGMENTS_BLUE = [((452, 512), (330, 380)), ((330, 380), (300, 320)), ((300, 320), (272, 250))]


def dist_segment(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy or 1.0
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_sq))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def pixel(x, y):
    # 背景: 上が濃紺、下がやや明るい青
    t = y / N
    r, g, b = 4 + 6 * t, 10 + 14 * t, 30 + 38 * t
    d_red = min(dist_segment(x, y, a, b) for a, b in SEGMENTS_RED)
    d_blue = min(dist_segment(x, y, a, b) for a, b in SEGMENTS_BLUE)
    glow_r = math.exp(-d_red / 16.0)
    glow_b = math.exp(-d_blue / 13.0)
    core_r = math.exp(-d_red / 4.0)
    core_b = math.exp(-d_blue / 3.5)
    r += 255 * glow_r * 0.85 + 255 * core_r
    g += 70 * glow_r * 0.85 + 200 * core_b + 120 * glow_b * 0.7
    b += 25 * glow_r + 255 * glow_b * 0.85 + 255 * core_b
    return (min(255, int(r)), min(255, int(g)), min(255, int(b)))


def main():
    raw = bytearray()
    for y in range(N):
        row = bytearray(b"\x00")
        for x in range(N):
            row += bytes(pixel(x, y))
        # 2倍拡大: 行を2回、各ピクセルを横に2回
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
