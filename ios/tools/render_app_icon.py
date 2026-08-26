#!/usr/bin/env python3
"""Render the Aloud app icon set (light / dark / tinted) at 1024x1024.

Design: the app's typographic cover language — warm paper ground, a large
serif capital "A" (Iowan Old Style, falling back to Georgia) set slightly
above optical center, and a thin bronze accent rule beneath it, matching
the in-app book covers. The OS applies the squircle mask; no corner
rounding is done here.

Usage:  python3 ios/tools/render_app_icon.py            # write the icon set
        python3 ios/tools/render_app_icon.py --check    # verify, write nothing
Output: ios/Aloud/Resources/Assets.xcassets/AppIcon.appiconset/
        icon-light.png, icon-dark.png, icon-tinted.png

The committed PNGs are binary blobs no diff review can read, so this script
refuses to render anything it cannot render exactly: the font is resolved by
family AND face name, a missing primary font is an error rather than a silent
substitution, and --check re-renders in memory to prove the committed files
still correspond to this source.
"""

import argparse
import io
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

CANVAS = 1024
SS = 4  # supersample factor for crisp serif edges
S = CANVAS * SS

# Palette (matches Theme/AloudTheme.swift bronze monochrome)
PAPER_LIGHT = (0xFB, 0xF8, 0xF2, 0xFF)   # warm paper
INK_LIGHT = (0x26, 0x1D, 0x10, 0xFF)     # sepia-black
RULE_LIGHT = (0xA8, 0x74, 0x34, 0xFF)    # bronze

PAPER_DARK = (0x14, 0x10, 0x0A, 0xFF)    # near-black paper
INK_DARK = (0xC9, 0x9A, 0x5B, 0xFF)      # brass
RULE_DARK = (0xC9, 0x9A, 0x5B, 0xFF)     # brass

WHITE = (0xFF, 0xFF, 0xFF, 0xFF)

# Geometry (in 1024-space, scaled by SS at render time)
GLYPH_TARGET_HEIGHT = round(CANVAS * 0.55)  # ~563 px visual cap height
GLYPH_CENTER_Y = 448                         # slightly above optical center
RULE_W, RULE_H = 200, 8
RULE_GAP = 56                                # gap between glyph bottom and rule

# The shipped icon IS this face. A different one changes the committed PNGs in
# a way no diff review can see (they are binary blobs), so the fallback is
# opt-in: without --allow-fallback a machine that lacks Iowan Old Style fails
# loudly instead of quietly re-rendering the app icon in Georgia.
PRIMARY_FONT = ("/System/Library/Fonts/Supplemental/Iowan Old Style.ttc",
                "Iowan Old Style", "Roman")
FALLBACK_FONT = ("/System/Library/Fonts/Supplemental/Georgia.ttf",
                 "Georgia", "Regular")

ALLOW_FALLBACK = False


def _face(path: str, size: int, want_style: str) -> ImageFont.FreeTypeFont:
    """The named face of a font file, by style name — never face 0 on a guess."""
    if not path.endswith(".ttc"):
        return ImageFont.truetype(path, size)
    index = 0
    while True:
        try:
            font = ImageFont.truetype(path, size, index=index)
        except OSError:
            break
        if font.getname()[1].lower() == want_style.lower():
            return font
        index += 1
    raise SystemExit(
        f"{path} has no '{want_style}' face — refusing to guess a weight or slant"
    )


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path, family, style in (PRIMARY_FONT, FALLBACK_FONT):
        if not Path(path).exists():
            continue
        if (path, family, style) == FALLBACK_FONT and not ALLOW_FALLBACK:
            break
        font = _face(path, size, style)
        # Assert what actually resolved: a silent substitution here is the one
        # way this script can rewrite the app icon without anyone noticing.
        got = font.getname()
        if got[0] != family:
            raise SystemExit(f"Expected {family!r}, got {got[0]!r} from {path}")
        return font
    raise SystemExit(
        f"{PRIMARY_FONT[1]} not found at {PRIMARY_FONT[0]}. The committed icons "
        f"are rendered in it; pass --allow-fallback to render in "
        f"{FALLBACK_FONT[1]} instead, knowing the result will not match."
    )


def fit_font(target_glyph_height: int) -> ImageFont.FreeTypeFont:
    """Find a font size whose rendered 'A' is target_glyph_height tall."""
    size = target_glyph_height
    for _ in range(12):
        font = load_font(size)
        left, top, right, bottom = font.getbbox("A")
        height = bottom - top
        if abs(height - target_glyph_height) <= 1:
            return font
        size = max(8, round(size * target_glyph_height / height))
    raise SystemExit(
        f"Cap height did not converge on {target_glyph_height}px — the icon "
        f"geometry would be off by an unbounded amount; not writing a guess."
    )


def render(paper, ink, rule, *, transparent_ground: bool) -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0) if transparent_ground else paper)
    draw = ImageDraw.Draw(img)

    font = fit_font(GLYPH_TARGET_HEIGHT * SS)
    left, top, right, bottom = font.getbbox("A")
    glyph_w = right - left
    glyph_h = bottom - top

    x = (S - glyph_w) // 2 - left
    y = GLYPH_CENTER_Y * SS - glyph_h // 2 - top
    draw.text((x, y), "A", font=font, fill=ink)

    glyph_bottom = y + top + glyph_h  # baseline-independent visual bottom
    rule_top = glyph_bottom + RULE_GAP * SS
    rx0 = (S - RULE_W * SS) // 2
    draw.rectangle(
        [rx0, rule_top, rx0 + RULE_W * SS - 1, rule_top + RULE_H * SS - 1],
        fill=rule,
    )

    out = img.resize((CANVAS, CANVAS), Image.LANCZOS)
    if not transparent_ground:
        # App Store validation rejects alpha in the opaque 1024 icon.
        out = out.convert("RGB")
    return out


def variants() -> dict:
    """filename → rendered image. Only the light/primary 1024 is opaque:
    iOS composites the dark and tinted appearances over a background it
    supplies itself, so those two ship their artwork on transparency."""
    return {
        "icon-light.png": render(
            PAPER_LIGHT, INK_LIGHT, RULE_LIGHT, transparent_ground=False
        ),
        "icon-dark.png": render(
            PAPER_DARK, INK_DARK, RULE_DARK, transparent_ground=True
        ),
        "icon-tinted.png": render(None, WHITE, WHITE, transparent_ground=True),
    }


def main() -> None:
    global ALLOW_FALLBACK
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="re-render and compare against the committed PNGs; write nothing",
    )
    parser.add_argument(
        "--allow-fallback",
        action="store_true",
        help="render in Georgia when Iowan Old Style is missing (changes the icon)",
    )
    args = parser.parse_args()
    ALLOW_FALLBACK = args.allow_fallback

    out_dir = (
        Path(__file__).resolve().parent.parent
        / "Aloud/Resources/Assets.xcassets/AppIcon.appiconset"
    )
    rendered = variants()

    if args.check:
        drift = []
        for name, image in rendered.items():
            buffer = io.BytesIO()
            image.save(buffer, format="PNG")
            committed = out_dir / name
            if not committed.exists() or committed.read_bytes() != buffer.getvalue():
                drift.append(name)
        if drift:
            raise SystemExit(
                "Committed icons do not match this source: " + ", ".join(drift)
            )
        print(f"{len(rendered)} icons match the committed PNGs")
        return

    out_dir.mkdir(parents=True, exist_ok=True)
    for name, image in rendered.items():
        image.save(out_dir / name)
    print(f"Wrote {len(rendered)} icons to {out_dir}")


if __name__ == "__main__":
    main()
