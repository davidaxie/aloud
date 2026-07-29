"""Text normalization for TTS input.

PDF-extracted text is riddled with typographic artifacts that a neural TTS
phonemizer (espeak-ng, under Kokoro) chokes on: ligatures (``ﬁ``/``ﬂ``), soft
hyphens, non-breaking / zero-width / exotic spaces, smart quotes, en/em dashes,
control characters, bullets, and hyphenation introduced by line wrapping. When
these reach the phonemizer they cause word-count mismatches and garbled, poorly
enunciated speech.

``normalize_for_tts`` rewrites any input into clean, ASCII-leaning, speakable
text *before* synthesis. It is deliberately conservative: it never invents words
and, if normalization somehow empties the string, it returns the original text
untouched so the caller still has something to speak.

Pure standard library (``unicodedata`` + ``re``); no third-party dependencies.
"""

from __future__ import annotations

import re
import unicodedata

# ---------------------------------------------------------------------------
# Single-pass character translation table
#
# ``str.translate`` applies all of the following in one efficient pass. A value
# of ``None`` deletes the character; a string (possibly multi-character or empty)
# substitutes for it. Everything here operates on individual code points.
# ---------------------------------------------------------------------------

# Characters removed outright. Soft hyphen and the zero-width family are
# invisible artifacts that split or fuse words for the phonemizer.
_DELETE: dict[int, None] = {
    0x00AD: None,  # SOFT HYPHEN
    0x200B: None,  # ZERO WIDTH SPACE
    0x200C: None,  # ZERO WIDTH NON-JOINER
    0x200D: None,  # ZERO WIDTH JOINER
    0xFEFF: None,  # ZERO WIDTH NO-BREAK SPACE / BOM
}

# Exotic spaces mapped to a plain ASCII space. NFKC already folds most of these,
# but the line/paragraph separators (U+2028/U+2029) and NEL (U+0085) survive it,
# so we map the whole family explicitly for safety and clarity.
_SPACE_CODEPOINTS: list[int] = [
    0x0085,  # NEXT LINE (NEL, a C1 control that acts as a line break)
    0x00A0,  # NO-BREAK SPACE
    0x202F,  # NARROW NO-BREAK SPACE
    0x2028,  # LINE SEPARATOR
    0x2029,  # PARAGRAPH SEPARATOR
    *range(0x2000, 0x200B),  # EN QUAD .. HAIR SPACE (en/em/thin/figure/etc.)
]
_SPACE: dict[int, str] = {cp: " " for cp in _SPACE_CODEPOINTS}

# Smart / typographic quotes -> straight ASCII quotes.
_QUOTES: dict[int, str] = {
    0x2018: "'",  # LEFT SINGLE QUOTATION MARK
    0x2019: "'",  # RIGHT SINGLE QUOTATION MARK (also apostrophe)
    0x201A: "'",  # SINGLE LOW-9 QUOTATION MARK
    0x201B: "'",  # SINGLE HIGH-REVERSED-9 QUOTATION MARK
    0x201C: '"',  # LEFT DOUBLE QUOTATION MARK
    0x201D: '"',  # RIGHT DOUBLE QUOTATION MARK
    0x201E: '"',  # DOUBLE LOW-9 QUOTATION MARK
    0x201F: '"',  # DOUBLE HIGH-REVERSED-9 QUOTATION MARK
}

# Dashes -> " - ": a spaced ASCII hyphen reads as a natural spoken pause and
# keeps the phonemizer from treating the dash as part of a word.
_DASHES: dict[int, str] = {
    0x2012: " - ",  # FIGURE DASH
    0x2013: " - ",  # EN DASH
    0x2014: " - ",  # EM DASH
    0x2015: " - ",  # HORIZONTAL BAR
}

# Ellipsis -> three ASCII dots.
_ELLIPSIS: dict[int, str] = {0x2026: "..."}

# Non-ASCII bullet / list-marker glyphs -> removed. Any surrounding whitespace is
# collapsed later, so "• Item" cleanly becomes "Item".
_BULLETS: dict[int, str] = {
    cp: ""
    for cp in (
        0x2022,  # BULLET
        0x2023,  # TRIANGULAR BULLET
        0x2043,  # HYPHEN BULLET
        0x2219,  # BULLET OPERATOR
        0x25CF,  # BLACK CIRCLE
        0x25E6,  # WHITE BULLET
        0x25AA,  # BLACK SMALL SQUARE
        0x25AB,  # WHITE SMALL SQUARE
        0x00B7,  # MIDDLE DOT
        0x2027,  # HYPHENATION POINT
        0x2024,  # ONE DOT LEADER
    )
}

# Merge every rule into one translation table consumed by ``str.translate``.
_TRANSLATION: dict[int, str | None] = {}
_TRANSLATION.update(_DELETE)
_TRANSLATION.update(_SPACE)
_TRANSLATION.update(_QUOTES)
_TRANSLATION.update(_DASHES)
_TRANSLATION.update(_ELLIPSIS)
_TRANSLATION.update(_BULLETS)

# ---------------------------------------------------------------------------
# Regex passes
# ---------------------------------------------------------------------------

# Remaining C0/C1 control characters, keeping only the "normal whitespace"
# controls TAB, LF, VT, FF, CR (0x09-0x0D). NEL (0x85) was already mapped to a
# space above, so deleting the 0x7F-0x9F range here is safe.
_CONTROL_RE = re.compile(r"[\x00-\x08\x0e-\x1f\x7f-\x9f]")

# Line-wrap hyphenation repair: a letter, an ASCII hyphen, whitespace, then a
# lowercase letter -> join the two fragments ("inter- national" ->
# "international"; "inter-\nnational" -> "international"). The required space
# after the hyphen is what makes this safe: genuine compounds like "well-being"
# have no space and are left untouched.
_LINEWRAP_HYPHEN_RE = re.compile(r"([A-Za-z])-\s+([a-z])")

# Any run of whitespace -> a single space.
_WHITESPACE_RE = re.compile(r"\s+")

# A space sitting before sentence punctuation -> no space ("word ," -> "word,").
_SPACE_BEFORE_PUNCT_RE = re.compile(r"\s+([,.;:!?])")


def normalize_for_tts(text: str) -> str:
    """Clean ``text`` so a TTS phonemizer can pronounce it reliably.

    The transformation is a fixed pipeline:

    1. Unicode **NFKC** normalization (expands ligatures ``ﬁ`` -> ``fi`` etc.).
    2. Single-pass character translation: delete soft hyphen / zero-width chars,
       map exotic spaces to a plain space, straighten quotes, convert dashes to
       " - ", expand the ellipsis, and drop non-ASCII bullets.
    3. Strip remaining C0/C1 control characters (keeping normal whitespace).
    4. Repair conservative line-wrap hyphenation.
    5. Collapse whitespace runs and trim ends.
    6. Remove any space that precedes sentence punctuation.

    If the pipeline yields an empty / whitespace-only string, the original text
    (stripped) is returned unchanged rather than an empty result -- the caller
    already guards genuinely-empty input, so this only guards the pathological
    case where normalization would erase everything.

    Args:
        text: Arbitrary input text (may contain PDF-extraction artifacts).

    Returns:
        A cleaned, phonemizer-friendly string.
    """
    # Guard against ``None`` / empty without raising: return the input as-is.
    if not text:
        return text

    # 1. NFKC: expands ligatures, folds most compatibility spaces, etc.
    result = unicodedata.normalize("NFKC", text)

    # 2. One-pass character rewrites (deletions, spaces, quotes, dashes, ...).
    result = result.translate(_TRANSLATION)

    # 3. Drop leftover control characters that are not normal whitespace.
    result = _CONTROL_RE.sub("", result)

    # 4. Re-join words split by line-wrap hyphenation (conservatively).
    result = _LINEWRAP_HYPHEN_RE.sub(r"\1\2", result)

    # 5. Collapse all whitespace to single spaces and trim the ends.
    result = _WHITESPACE_RE.sub(" ", result).strip()

    # 6. Tidy spacing directly before sentence punctuation.
    result = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", result)

    # Safety net: never hand back an empty string to the synthesizer.
    if not result.strip():
        return text.strip()

    return result
