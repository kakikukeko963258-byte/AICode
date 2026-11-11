#!/usr/bin/env python3
"""AppIcon-1024.png を標準ライブラリだけで生成する（CI用）。
濃紺の夜空に天の川の帯と星々、一番星のきらめきを描く。"""
import math
import struct
import zlib

OUT = "AstroCam/AstroCam/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
N = 512

# 決定的な疑似乱数で星を散らす
_state = 1234567
def rnd():
    global _state
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF
    return _state / 0x7FFFFFFF

STARS = [(rnd() * N, rnd() * N, 0.6 + rnd() * 1.8) for _ in range(180)]

def pixel(x, y):
    # 背景: 上がほぼ黒の紺、下が少しだけ明るい紺
    t = y / N
    r, g, b = 3 + 3 * t, 5 + 6 * t, 16 + 22 * t
    # 天の川: 左上から右下への斜めの帯
    # 帯の中心線からの距離
    d_band = abs((x - y) - 40) / math.sqrt(2)
    band = math.exp(-d_band / 55.0)
    r += 70 * band
    g += 85 * band
    b += 120 * band
    # 星
    for sx, sy, sr in STARS:
        d = math.hypot(x - sx, y - sy)
        glow = math.exp(-d / (sr * 2.2))
        r += 200 * glow
        g += 210 * glow
        b += 255 * glow
    # 一番星（右上）の十字のきらめき
    bx, by = 380, 130
    d = math.hypot(x - bx, y - by)
    core = math.exp(-d / 7.0)
    spike_x = math.exp(-abs(y - by) / 3.0) * math.exp(-abs(x - bx) / 60.0)
    spike_y = math.exp(-abs(x - bx) / 3.0) * math.exp(-abs(y - by) / 60.0)
    sparkle = core + 0.55 * (spike_x + spike_y)
    r += 255 * sparkle
    g += 250 * sparkle
    b += 255 * sparkle
    return (min(255, int(r)), min(255, int(g)), min(255, int(b)))

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
