"""Keep every phoneme run short enough for Kokoro's context window.

kokoro_onnx splits the phonemes of one ``create()`` call only at ``. , ! ? ;``
and hands each piece to the model whole. A piece of 510 phonemes or more
overruns the 510-row voice-style table, and ``create()`` raises IndexError
(kokoro_onnx 0.5.0), so the whole chunk comes back as a 500 and the reader skips
it. A 350-character chunk with no punctuation gets there easily once numbers
are spelled out: the years 1950 to 2019 phonemize to about 1,460 phonemes, which
is what a PDF table row looks like after its lines are joined.

``split_for_model`` breaks only those over-long runs, at the last space that
keeps each piece under the limit, and leaves everything else alone, so an
ordinary sentence still reaches the model as one call.
"""

from __future__ import annotations

import re

# Comfortably below kokoro_onnx's MAX_PHONEME_LENGTH of 510, so a cut never has
# to land exactly on the edge.
MAX_RUN = 400

# The marks kokoro_onnx itself splits at, kept in the output by the group.
_PUNCTUATION = re.compile(r"([.,!?;])")


def _cut_run(run: str, limit: int) -> list[str]:
    """Cut one punctuation-free run into pieces shorter than ``limit``, at spaces.

    A single "word" longer than the limit (no space to cut at) is cut where it
    stands: a clipped syllable is better than losing the whole chunk.
    """
    pieces: list[str] = []
    current = ""
    for word in run.split():
        while len(word) >= limit:
            if current:
                pieces.append(current)
                current = ""
            pieces.append(word[: limit - 1])
            word = word[limit - 1 :]
        if current and len(current) + 1 + len(word) >= limit:
            pieces.append(current)
            current = word
        else:
            current = f"{current} {word}" if current else word
    if current:
        pieces.append(current)
    return pieces


def split_for_model(phonemes: str, limit: int = MAX_RUN) -> list[str]:
    """Split ``phonemes`` so no punctuation-free run in any piece reaches ``limit``.

    Each piece is meant for its own ``create(..., is_phonemes=True)`` call.
    Returns ``[phonemes]`` unchanged when no run is too long, which is the
    common case.
    """
    parts = _PUNCTUATION.split(phonemes)
    if all(len(part.strip()) < limit for part in parts):
        return [phonemes]

    pieces: list[str] = []
    current = ""
    for part in parts:
        if len(part.strip()) < limit:
            current += part
            continue
        head, *rest = _cut_run(part, limit)
        pieces.append(f"{current} {head}".strip())
        if rest:
            pieces.extend(rest[:-1])
            current = rest[-1]
        else:
            current = ""
    if current.strip():
        pieces.append(current.strip())
    return pieces


# The most phonemes one request may become. Ordinary text is about 1.2 phonemes
# a character and a number-heavy 350-character client chunk about 1,460, but a
# compatibility character such as U+FDFA expands to 18 letters under NFKC and
# phonemizes to about 66 phonemes a character, so 2,000 of them (a 6 KB body)
# held the single worker for a quarter of an hour and gigabytes of memory.
MAX_PHONEMES = 6000


class TooLongError(ValueError):
    """The text phonemizes to more than ``MAX_PHONEMES``; answered with a 413."""


def check_length(phonemes: str, limit: int = MAX_PHONEMES) -> None:
    """Raise :class:`TooLongError` when ``phonemes`` is more than one request may ask for."""
    if len(phonemes) > limit:
        raise TooLongError(f"text is too long to speak in one request ({len(phonemes)} phonemes)")


# espeak-ng has no IPA spelling for Mandarin's retroflex sounds and writes them
# as ASCII names ending in a full stop: "s." for ʂ, "ts." for ʈʂ, "ts.h" for
# ʈʂʰ, "z." for ʐ, and "i." for the vowel of zhi, chi, shi. That "." is the
# model's sentence-final token, so every such syllable got a full stop in the
# middle of it, and kokoro_onnx put a space after each one. The replacements
# are the symbols Kokoro's Chinese voices were trained on (ʐ is not in its
# vocabulary; ɻ is what they use for that initial). A consonant's marker is
# always followed by its vowel or a stress mark, never by a space, which keeps
# a real full stop after a Latin word ("yes.") as it was.
_MANDARIN_RETROFLEX_RE = re.compile(r"ts\.h(?=\S)|ts\.(?=\S)|s\.(?=\S)|z\.(?=\S)")
_MANDARIN_RETROFLEX = {"ts.h": "ʈʂʰ", "ts.": "ʈʂ", "s.": "ʂ", "z.": "ɻ"}
# The apical vowel after a retroflex initial, possibly after a stress mark.
_MANDARIN_APICAL_RE = re.compile(r"(ʈʂʰ|ʈʂ|ʂ|ɻ)([ˈˌ]?)i\.")


def respell_for_model(phonemes: str, lang: str) -> str:
    """Rewrite espeak-ng's ASCII names for sounds the model has symbols for.

    Only Mandarin ("cmn") needs it; every other language passes through.
    """
    if lang != "cmn" or "." not in phonemes:
        return phonemes
    phonemes = _MANDARIN_RETROFLEX_RE.sub(lambda m: _MANDARIN_RETROFLEX[m.group(0)], phonemes)
    return _MANDARIN_APICAL_RE.sub(r"\1\2ɻ", phonemes)
