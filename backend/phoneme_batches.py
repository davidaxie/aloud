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
