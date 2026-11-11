#!/usr/bin/env python3
"""AppIcon-1024.png を標準ライブラリだけで生成する（CI用）。
黒背景にシアンとマゼンタの帯がブロック状にずれて溶け合う、
データモッシュのグリッチ表現。"""
import math
import struct
import zlib

OUT = "MoshCam/MoshCam/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
N = 512

_state = 987654321
def rnd():
    global _state
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF
    return _state / 0x7FFFFFFF

# 行ブロックごとの水平ずれ量（グリッチシフト）
BLOCK = 32
SHIFTS = [int((rnd() - 0.5) * 90) for _ in range(N // BLOCK + 1)]
# ランダムな小ブロックのアクセント
SPECKS = [(int(rnd() * N), int(rnd() * N), int(6 + rnd() * 26), rnd()) for _ in range(90)]

def base(x, y):
    """ずれを適用する前の絵: 上半分シアン系、下半分マゼンタ系の横帯。"""
    t = y / N
    # 縦グラデーションの背景
    r, g, b = 8 + 6 * t, 8 + 4 * t, 14 + 10 * t
    # 中央の明るい帯（つなぎ目）
    seam = math.exp(-abs(y - N * 0.52) / 26.0)
    r += 60 * seam
    g += 70 * seam
    b += 80 * seam
    # 上: シアンの横ストリーク
    streak_c = math.exp(-abs(y - N * 0.30) / 42.0)
    r += 20 * streak_c
    g += 190 * streak_c
    b += 220 * streak_c
    # 下: マゼンタの横ストリーク
    streak_m = math.exp(-abs(y - N * 0.74) / 42.0)
    r += 225 * streak_m
    g += 40 * streak_m
    b += 165 * streak_m
    return r, g, b

def pixel(x, y):
    shift = SHIFTS[min(len(SHIFTS) - 1, y // BLOCK)]
    sx = (x + shift) % N
    r, g, b = base(sx, y)
    # RGBスプリット: つなぎ目付近で色チャンネルをずらす
    seam_band = abs(y - N * 0.52) < 46
    if seam_band:
        r2, _, _ = base((x + 14) % N, y)
        _, _, b2 = base((x - 14) % N, y)
        r, b = r2, b2
    # アクセント小ブロック
    for px, py, ps, kind in SPECKS:
        if px <= x < px + ps and py <= y < py + ps // 2:
            if kind < 0.4:
                r, g, b = 230, 245, 255
            elif kind < 0.7:
                r, g, b = 40, 220, 245
            else:
                r, g, b = 245, 60, 180
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
