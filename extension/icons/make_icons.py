#!/usr/bin/env python3
"""Generate the extension's PNG icons.

Chrome only accepts raster icons, so the Aloud mark — three white "sound wave"
bars on a rounded macOS-orange square — is rendered here rather than shipped as
an SVG. Everything is pure standard library (``zlib`` + ``struct`` write the PNG
by hand), so this needs no Pillow and no network.

Shapes are drawn as signed-distance fields and sampled at ``SS`` x ``SS`` per
pixel, which gives clean antialiased corners even at 16 px.

    python3 make_icons.py        # writes icon16/32/48/128.png next to this file
"""

from __future__ import annotations

import os
import struct
import zlib

# macOS systemOrange — the single accent used across the Aloud UI.
ACCENT = (255, 149, 0)
BAR_COLOR = (255, 255, 255)
SIZES = (16, 32, 48, 128)
SS = 6  # supersampling factor per axis


def rounded_rect_sdf(x: float, y: float, cx: float, cy: float, hw: float, hh: float, r: float) -> float:
    """Signed distance from (x, y) to a rounded rect. Negative = inside."""
    dx = abs(x - cx) - (hw - r)
    dy = abs(y - cy) - (hh - r)
    outside = (max(dx, 0.0) ** 2 + max(dy, 0.0) ** 2) ** 0.5
    inside = min(max(dx, dy), 0.0)
    return outside + inside - r


def render(size: int) -> bytes:
    """Render one icon at `size` px and return its RGBA byte rows."""
    # Geometry in a 0..1 unit square, scaled to `size` — so every icon is
    # identical modulo resolution.
    tile = size / 1.0
    plate_r = 0.235 * tile          # squircle-ish corner radius
    plate_hw = plate_hh = 0.5 * tile

    # Three bars: short, tall, medium — a waveform at rest.
    bar_w = 0.104 * tile
    bar_r = bar_w / 2
    gap = 0.078 * tile
    heights = (0.30 * tile, 0.52 * tile, 0.38 * tile)
    centers_x = (
        0.5 * tile - (bar_w + gap),
        0.5 * tile,
        0.5 * tile + (bar_w + gap),
    )

    px = bytearray()
    step = 1.0 / SS
    samples = SS * SS
    for py in range(size):
        for pxi in range(size):
            plate_cov = 0.0
            bar_cov = 0.0
            for sy in range(SS):
                y = py + (sy + 0.5) * step
                for sx in range(SS):
                    x = pxi + (sx + 0.5) * step
                    if rounded_rect_sdf(x, y, 0.5 * tile, 0.5 * tile, plate_hw, plate_hh, plate_r) < 0:
                        plate_cov += 1.0
                    for cx, h in zip(centers_x, heights):
                        if rounded_rect_sdf(x, y, cx, 0.5 * tile, bar_w / 2, h / 2, bar_r) < 0:
                            bar_cov += 1.0
                            break
            a_plate = plate_cov / samples
            a_bar = bar_cov / samples
            if a_plate <= 0.0:
                px += bytes((0, 0, 0, 0))
                continue
            # Composite the white bars over the orange plate, then premultiply
            # nothing — PNG stores straight alpha.
            r = round(ACCENT[0] * (1 - a_bar) + BAR_COLOR[0] * a_bar)
            g = round(ACCENT[1] * (1 - a_bar) + BAR_COLOR[1] * a_bar)
            b = round(ACCENT[2] * (1 - a_bar) + BAR_COLOR[2] * a_bar)
            px += bytes((r, g, b, round(255 * a_plate)))
    return bytes(px)


def write_png(path: str, size: int, rgba: bytes) -> None:
    """Write 8-bit RGBA pixel data as a PNG (no filtering, one IDAT)."""
    stride = size * 4
    raw = b"".join(b"\x00" + rgba[y * stride : (y + 1) * stride] for y in range(size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(png)


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    for size in SIZES:
        out = os.path.join(here, f"icon{size}.png")
        write_png(out, size, render(size))
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
