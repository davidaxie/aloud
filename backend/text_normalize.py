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

# Characters removed outright. Soft hyphen, zero-width space and BOM are
# invisible artifacts that split or fuse words for the phonemizer. The zero-width
# joiner and non-joiner (U+200D / U+200C) are not here: they are spelling inside
# emoji sequences and Persian/Indic words, so ``_drop_stray_joiners`` removes
# them only where they are leftovers (see ``_keeps_joiner``).
_DELETE: dict[int, None] = {
    0x00AD: None,  # SOFT HYPHEN
    0x200B: None,  # ZERO WIDTH SPACE
    0xFEFF: None,  # ZERO WIDTH NO-BREAK SPACE / BOM
}

# Exotic spaces mapped to a plain ASCII space. NFKC already folds most of these,
# but the line/paragraph separators (U+2028/U+2029) and NEL (U+0085) survive it,
# so we map the whole family explicitly for safety and clarity. Those three
# become "\n" so the hyphen repair below still sees a line break; the
# whitespace collapse turns every break into a space afterwards.
_SPACE_CODEPOINTS: list[int] = [
    0x00A0,  # NO-BREAK SPACE
    0x202F,  # NARROW NO-BREAK SPACE
    *range(0x2000, 0x200B),  # EN QUAD .. HAIR SPACE (en/em/thin/figure/etc.)
]
_LINE_BREAK_CODEPOINTS: list[int] = [
    0x0085,  # NEXT LINE (NEL, a C1 control that acts as a line break)
    0x2028,  # LINE SEPARATOR
    0x2029,  # PARAGRAPH SEPARATOR
]
_SPACE: dict[int, str] = {cp: " " for cp in _SPACE_CODEPOINTS}
_SPACE.update({cp: "\n" for cp in _LINE_BREAK_CODEPOINTS})

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
# Zero-width joiner / non-joiner
# ---------------------------------------------------------------------------

_JOINERS = "\u200c\u200d"  # ZERO WIDTH NON-JOINER, ZERO WIDTH JOINER

# Letters and marks: in a non-Latin script these are what a joiner shapes.
_SHAPING_CATEGORIES = frozenset({"Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me"})


def _shapes(ch: str | None) -> bool:
    """True for a character a ZWJ/ZWNJ beside it belongs to: an emoji (or its
    presentation selector, skin-tone modifier, keycap or flag tag) or a letter
    or mark of a non-Latin script."""
    if ch is None:
        return False
    cp = ord(ch)
    if cp <= 0x7F:
        return False
    if (
        cp in (0xFE0F, 0x20E3)  # emoji presentation selector, combining keycap
        or 0x2190 <= cp <= 0x2BFF  # arrows .. misc symbols, dingbats (U+2640, U+2764)
        or 0x1F000 <= cp <= 0x1FAFF  # emoji blocks, incl. modifiers U+1F3FB..U+1F3FF
        or 0xE0020 <= cp <= 0xE007F  # tag characters (subdivision flags)
    ):
        return True
    if cp < 0x0370 or 0x1E00 <= cp <= 0x1EFF:  # Latin, IPA and their diacritics
        return False
    return unicodedata.category(ch) in _SHAPING_CATEGORIES


def _keeps_joiner(before: str | None, after: str | None) -> bool:
    """ZWJ and ZWNJ beside an emoji or a non-Latin letter are spelling: they
    join a ZWJ emoji sequence into one emoji and keep Persian and Devanagari
    words as written. Between Latin letters they are leftovers of ligature
    breaking in PDFs and go. Same rule as TextNormalizer.keepsJoiner (iOS/Mac)."""
    return _shapes(before) or _shapes(after)


def _drop_stray_joiners(text: str) -> str:
    """Delete each ZWJ/ZWNJ that ``_keeps_joiner`` does not keep."""
    if "\u200c" not in text and "\u200d" not in text:
        return text
    out: list[str] = []
    for i, ch in enumerate(text):
        if ch in _JOINERS:
            before = out[-1] if out else None
            after = text[i + 1] if i + 1 < len(text) else None
            if not _keeps_joiner(before, after):
                continue
        out.append(ch)
    return "".join(out)


# ---------------------------------------------------------------------------
# Regex passes
# ---------------------------------------------------------------------------

# Remaining C0/C1 control characters, keeping only the "normal whitespace"
# controls TAB, LF, VT, FF, CR (0x09-0x0D). NEL (0x85) was already mapped to a
# line break above, so deleting the 0x7F-0x9F range here is safe.
_CONTROL_RE = re.compile(r"[\x00-\x08\x0e-\x1f\x7f-\x9f]")

# Line-wrap hyphenation repair: a letter, an ASCII hyphen, whitespace holding a
# line break, then a lowercase word -> join the two fragments
# ("inter-\nnational" -> "international"). The required space after the hyphen
# keeps genuine compounds like "well-being" untouched. A hyphen and space on
# one line is the author's suspended hyphen ("pre- and post-war",
# "mid- to late-1990s") and is kept as written. The groups are the letter, the
# whitespace and the following word.
_LINEWRAP_HYPHEN_RE = re.compile(r"([A-Za-z])-(\s+)(?=([a-z][A-Za-z]*))")
_LINE_BREAKS = "\n\r\v\f"

# After a hyphen these words mark a suspended compound ("two- or three-day")
# even across a line break. Same list as TextNormalizer.swift.
_SUSPENDED_HYPHEN_FOLLOWERS = frozenset({"and", "or", "nor"})


def _repair_line_wrap_hyphen(match: re.Match[str]) -> str:
    """Re-join a word split at a line break; leave anything else as written."""
    letter, gap, right = match.groups()
    if not any(ch in _LINE_BREAKS for ch in gap) or right in _SUSPENDED_HYPHEN_FOLLOWERS:
        return match.group(0)
    return letter

# Any run of whitespace -> a single space.
_WHITESPACE_RE = re.compile(r"\s+")

# A space sitting before sentence punctuation -> no space ("word ," -> "word,").
_SPACE_BEFORE_PUNCT_RE = re.compile(r"\s+([,.;:!?])")


def normalize_for_tts(text: str) -> str:
    """Clean ``text`` so a TTS phonemizer can pronounce it reliably.

    The transformation is a fixed pipeline:

    1. Unicode **NFKC** normalization (expands ligatures ``ﬁ`` -> ``fi`` etc.).
    2. Single-pass character translation: delete soft hyphen / zero-width
       space / BOM, map exotic spaces to a plain space (and Unicode line
       separators to a newline), straighten quotes,
       convert dashes to " - ", expand the ellipsis, and drop non-ASCII
       bullets. Then drop ZWJ/ZWNJ except inside emoji sequences and
       non-Latin words, where they are spelling.
    3. Strip remaining C0/C1 control characters (keeping normal whitespace).
    4. Repair conservative line-wrap hyphenation (only across a line break,
       never before and/or/nor).
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
    result = _drop_stray_joiners(result)

    # 3. Drop leftover control characters that are not normal whitespace.
    result = _CONTROL_RE.sub("", result)

    # 4. Re-join words split by line-wrap hyphenation (conservatively).
    result = _LINEWRAP_HYPHEN_RE.sub(_repair_line_wrap_hyphen, result)

    # 5. Collapse all whitespace to single spaces and trim the ends.
    result = _WHITESPACE_RE.sub(" ", result).strip()

    # 6. Tidy spacing directly before sentence punctuation.
    result = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", result)

    # Safety net: never hand back an empty string to the synthesizer.
    if not result.strip():
        return text.strip()

    return result
