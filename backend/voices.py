"""Voice metadata helpers for Aloud.

Kokoro identifies voices with short ids such as ``af_heart`` or ``bm_george``.
The id encodes language and gender in its first two characters and a display
name after the underscore:

    <lang-char><gender-char>_<name>

    first char  -> language  (a->en-us, b->en-gb, e->es, f->fr-fr,
                               h->hi, i->it, j->ja, p->pt-br, z->zh)
    second char -> gender     (f->female, m->male)
    after "_"   -> display name (title-cased)

We build the public metadata by parsing whatever voice ids the installed model
actually exposes (via ``Kokoro.get_voices()``), so the list always matches the
model on disk. Unknown prefixes fall back to English / "other" rather than
raising, keeping the server resilient to future voice additions.
"""

from __future__ import annotations

from typing import TypedDict

# First id character -> BCP-47-ish language tag understood by Kokoro's create().
_LANG_BY_CHAR: dict[str, str] = {
    "a": "en-us",
    "b": "en-gb",
    "e": "es",
    "f": "fr-fr",
    "h": "hi",
    "i": "it",
    "j": "ja",
    "p": "pt-br",
    "z": "zh",
}

# Second id character -> gender label.
_GENDER_BY_CHAR: dict[str, str] = {
    "f": "female",
    "m": "male",
}

# Fallbacks for ids that do not follow the known convention.
_DEFAULT_LANG = "en-us"
_DEFAULT_GENDER = "other"


class VoiceMeta(TypedDict):
    """Public metadata describing a single voice."""

    id: str
    name: str
    lang: str
    gender: str


def _display_name(voice_id: str) -> str:
    """Turn ``af_heart`` into ``Heart`` (title-cased text after the underscore).

    If there is no underscore, fall back to title-casing the whole id.
    """
    _, _, raw = voice_id.partition("_")
    raw = raw or voice_id
    # Title-case each underscore/space separated chunk so e.g. multi-word
    # names remain readable ("xiao_xiao" -> "Xiao Xiao").
    return " ".join(part.capitalize() for part in raw.replace("_", " ").split())


def parse_voice(voice_id: str) -> VoiceMeta:
    """Parse a single Kokoro voice id into structured metadata.

    Unknown language/gender prefixes fall back to en-us / other so that new or
    unexpected voices still produce valid metadata.
    """
    lang_char = voice_id[0] if len(voice_id) >= 1 else ""
    gender_char = voice_id[1] if len(voice_id) >= 2 else ""

    return VoiceMeta(
        id=voice_id,
        name=_display_name(voice_id),
        lang=_LANG_BY_CHAR.get(lang_char, _DEFAULT_LANG),
        gender=_GENDER_BY_CHAR.get(gender_char, _DEFAULT_GENDER),
    )


def build_voice_metadata(voice_ids: list[str]) -> list[VoiceMeta]:
    """Parse an iterable of voice ids into a sorted list of metadata dicts."""
    return [parse_voice(vid) for vid in sorted(voice_ids)]


# Display tags that espeak-ng names differently. Clients key labels on the
# display tag ("zh"), but phonemizer's espeak backend only accepts "cmn" for
# Mandarin — passing "zh" failed every request for all 8 Chinese voices.
_ESPEAK_LANG: dict[str, str] = {
    "zh": "cmn",
}


# Languages this server cannot phonemize. espeak-ng's Japanese has no kanji
# readings: it spells every kanji as the English words "Chinese letter", and
# writes the /a/ vowel as a symbol Kokoro's vocabulary drops, so a Japanese
# voice turned ordinary Japanese into gibberish. Kokoro's Japanese voices need a
# Japanese G2P (misaki[ja] / pyopenjtalk), which the engine does not have, so
# they are left out of /voices and treated as not installed until it does.
_UNSPEAKABLE_LANGS: frozenset[str] = frozenset({"ja"})


def voice_is_speakable(voice_id: str) -> bool:
    """False for a voice whose language this server cannot phonemize."""
    return parse_voice(voice_id)["lang"] not in _UNSPEAKABLE_LANGS


def lang_for_voice(voice_id: str) -> str:
    """Return the espeak language tag that Kokoro's ``create()`` should use."""
    lang_char = voice_id[0] if voice_id else ""
    display = _LANG_BY_CHAR.get(lang_char, _DEFAULT_LANG)
    return _ESPEAK_LANG.get(display, display)
