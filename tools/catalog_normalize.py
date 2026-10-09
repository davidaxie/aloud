#!/usr/bin/env python3
"""Build the app's Bookshelf catalog from the raw Gutenberg catalog.

books/catalog.json keeps the Gutenberg headers' own spellings ("The call of
the wild", ". G. Wodehouse"); the fetcher and books/ stay raw. This step,
run by ios/sync_bookshelf.sh, writes the bundled copy with title case and
repaired authors, keeping the raw spelling in header_title / header_author
whenever it changed, so the app's backfill can still match libraries made
before normalization. The shelf shows a display title (display_title: no
alternative title, no generic subtitle); when that shortens the normalized
title, the normalized one is kept in full_title, so libraries made before
the shortening are renamed to match. tools/catalog_overrides.json holds the
fixes no rule can make; an override wins, verbatim, and may give a book a
"rank", its place at the head of its shelf.

Usage:
    python3 tools/catalog_normalize.py books/catalog.json --out DST/catalog.json
    python3 tools/catalog_normalize.py DST/catalog.json --check

--out writes only when the bytes change (an untouched mtime keeps Xcode from
recopying the bookshelf folder), then lints the result. --check lints as-is.
With neither, the normalized catalog goes to stdout and is linted.
Exit status: 0 clean, 1 lint violations, 2 usage or IO error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

OVERRIDES_PATH = Path(__file__).with_name("catalog_overrides.json")

# Articles, conjunctions, short prepositions and the particles of names
# ("da Vinci", "de Paris"): lowercase inside a title segment. The app's
# BookshelfCatalogTests repeats this set and title_violations; keep them in step.
MINOR_WORDS = {
    "a", "an", "the", "and", "but", "for", "nor", "or", "so", "yet", "as", "at",
    "by", "from", "in", "into", "of", "off", "on", "onto", "per", "to", "up",
    "upon", "via", "with", "vs", "v", "da", "de", "del", "della", "der", "des",
    "di", "du", "et", "la", "le", "les", "van", "von", "y", "aux",
}

WORD_RE = re.compile(r"[^\W_](?:[\w'’-]*[^\W_])?")
COMPLETE_RE = re.compile(r"\s*(?:,|—|–|--)\s*Complete\.?\s*$")
# A word right after one of these starts a new title segment...
SEGMENT_OPENERS = frozenset(":;!?—–(\"“")
# ...and a word right before one of these ends one.
SEGMENT_CLOSER_RE = re.compile(r"\s*[:;!?—–)\]]")
# "Fleet Street. A Domestic Romance": a period after a real word, not an
# initial ("Mr.", "U. S.") and not an ellipsis.
SENTENCE_END_RE = re.compile(r"[^\W\d_]{3,}\.\s+$")


class _Word:
    """One title word and the context the casing rules need."""

    def __init__(self, title: str, match: re.Match, index: int, previous: _Word | None):
        self.text = match.group()
        self.lower = self.text.lower()
        self.start, self.end = match.span()
        self.index = index
        before = title[: self.start]
        after = title[self.end:]
        tail = before.rstrip()
        # The alternative title's "or," ("Frankenstein; or, The Modern…").
        self.is_alt_or = self.lower == "or" and after.lstrip().startswith(",")
        # Left alone: "[sic]", "[Detectograms]", "&c.", "& Co.".
        self.is_verbatim = before.rfind("[") > before.rfind("]") or tail.endswith("&")
        self.starts_segment = (
            index == 0
            or tail[-1:] in SEGMENT_OPENERS
            or SENTENCE_END_RE.search(before) is not None
            or (previous is not None and previous.is_alt_or)
        )
        self.ends_segment = SEGMENT_CLOSER_RE.match(after) is not None


def _words(title: str) -> list[_Word]:
    words: list[_Word] = []
    for index, match in enumerate(WORD_RE.finditer(title)):
        words.append(_Word(title, match, index, words[-1] if words else None))
    if words:
        words[-1].ends_segment = True
    return words


def _capitalized(word: str) -> str:
    # Only first letters are raised; nothing is ever lowered ("McTeague", "XIII").
    return "-".join(part[:1].upper() + part[1:] for part in word.split("-"))


# Words that begin with an apostrophe, not an opening quote ('Tis, 'em).
# ios/Aloud/Reader/ReaderTypography.swift elisions; keep the two in step.
ELISIONS = ("tis", "twas", "twere", "em", "cause", "til", "n")
# What may come before an opening quote, besides the start and a space.
QUOTE_OPENERS = frozenset("([{\"“‘—–-")


def _opens_quote(previous: str | None, following: str | None) -> bool:
    if following is None or following.isspace():
        return False
    return previous is None or previous.isspace() or previous in QUOTE_OPENERS


def _starts_elision(text: str, start: int) -> bool:
    tail = text[start: start + 7].lower()
    for word in ELISIONS:
        if tail.startswith(word):
            boundary = tail[len(word): len(word) + 1]
            if not boundary or not boundary.isalpha():
                return True
    return False


def _closed_later(text: str, start: int) -> bool:
    """Whether a single quote after `start` closes one: a title is one line,
    so a quote that opens is closed in it, and an unclosed one before a word
    is an elision the list doesn't know ('Rickshaw). A source's own closing
    mark (U+2019) closes as a straight one does."""
    for index in range(start + 1, len(text)):
        if text[index] not in ("'", "\u2019"):
            continue
        following = text[index + 1] if index + 1 < len(text) else ""
        if not (text[index - 1].isalnum() and following.isalnum()):
            return True
    return False


def typographic_marks(text: str) -> str:
    """Straight quote marks set as the reader's colophon sets them: an
    apostrophe inside a word or after a plural's s, an opening single quote
    before a word that is not an elision and is closed later, a closing one
    anywhere else, and double quotes opening or closing by what is on
    either side. A source's opening single quote (U+2018) is decided again
    the way a straight one is, since Gutenberg sets an unclosed elision
    with it (#2806's 'Rickshaw), which takes the apostrophe instead."""
    out: list[str] = []
    for index, char in enumerate(text):
        previous = text[index - 1] if index else None
        following = text[index + 1] if index + 1 < len(text) else None
        if char in ("'", "\u2018"):
            if previous and following and previous.isalnum() and following.isalnum():
                out.append("’")
            elif previous in ("s", "S") and (following is None or following.isspace()):
                out.append("’")
            elif (_opens_quote(previous, following) and following.isalpha()
                  and not _starts_elision(text, index + 1) and _closed_later(text, index + 1)):
                out.append("‘")
            else:
                out.append("’")
        elif char == '"':
            out.append("“" if _opens_quote(previous, following) else "”")
        else:
            out.append(char)
    return "".join(out)


def normalize_title(title: str) -> str:
    title = COMPLETE_RE.sub("", title)
    title = re.sub(r"\s+", " ", title).strip()
    pieces: list[str] = []
    cursor = 0
    for word in _words(title):
        pieces.append(title[cursor: word.start])
        cursor = word.end
        if word.is_verbatim:
            pieces.append(word.text)
        elif word.is_alt_or and word.index > 0:
            pieces.append(word.lower)
        elif word.lower in MINOR_WORDS and not word.starts_segment and not word.ends_segment:
            # "THE" in an all-caps title is someone's choice; keep it.
            rest = word.text[1:]
            pieces.append(word.lower if rest == rest.lower() else word.text)
        else:
            pieces.append(_capitalized(word.text))
    pieces.append(title[cursor:])
    # Last, so full_title and the display title cut from it agree.
    return typographic_marks("".join(pieces))


# The longest title the shelf shows; a longer one is a lint violation.
MAX_TITLE_LENGTH = 60

# An alternative title: "Frankenstein; or, The Modern Prometheus",
# "The Knights of the Cross, or, Krzyzacy", "A Christmas Carol in Prose;
# Being a Ghost Story of Christmas".
ALTERNATIVE_TITLE_RE = re.compile(r"\s*(?:[;,]\s*or,\s|;\s*Being\b).*$")
# A trailing subtitle that says only what kind of book it is.
GENERIC_SUBTITLE_RES = (
    re.compile(r"\s*[:;]\s*(?:A|An) (?:Novel|Romance|Tale|Narrative|Autobiography|New Translation)\b.*$"),
    re.compile(r"\s*:\s*(?:Literally )?Translated\b.*$"),
    re.compile(r"\s*:\s*Illustrated\b.*$"),
    re.compile(r"\s*:\s*With\b.*$"),
    re.compile(r"\s*:\s.*\sEdition$"),
)
# A title longer than this is cut at its first ": ".
LONG_TITLE_LENGTH = 45


def display_title(title: str) -> str:
    """The title the shelf shows, from a normalized one: without an
    alternative title or a generic subtitle, and a long title cut at its
    first colon when what comes before is at least two words. Conservative:
    anything else is left as it is."""
    shortened = ALTERNATIVE_TITLE_RE.sub("", title)
    for pattern in GENERIC_SUBTITLE_RES:
        shortened = pattern.sub("", shortened)
    if len(shortened) > LONG_TITLE_LENGTH and ": " in shortened:
        head = shortened.split(": ", 1)[0]
        if len(head.split()) >= 2:
            shortened = head
    shortened = shortened.rstrip(" ,;:")
    return shortened or title


def normalize_author(author: str) -> str:
    # "Emperor of Rome Marcus Aurelius" -> "Marcus Aurelius": the title of
    # rank before the name.
    author = re.sub(r"^(?:Emperor|King|Queen|Sultan) of \S+ ", "", author)
    # "C. Collodi--Pseudonym of Carlo Lorenzini" -> "C. Collodi": the name on
    # the book; the real one stays in header_author, where search finds it.
    author = re.sub(r"\s*--\s*Pseudonym of\b.*$", "", author)
    # "George Gordon Byron, Baron Byron" -> "George Gordon Byron".
    author = re.sub(r",\s*Baron \w+\s*$", "", author)
    # "T. (Tobias) Smollett" -> "Tobias Smollett": the bare initial is the name.
    author = re.sub(r"^([A-Z])\.\s*\(([^)\s]+)\)\s*", r"\2 ", author)
    # Expansions and pseudonyms: "(Howard Phillips)", "(AKA Laurence Hope)".
    author = re.sub(r"\s*\([^)]*\)", "", author)
    author = re.sub(r",\s*et al\.?\s*$", "", author)
    # "G.K. Chesterton" -> "G. K. Chesterton"; a trailing "B.D." is a degree.
    author = re.sub(
        r"\b((?:[A-Z]\.){2,})(?=\s+[A-Z][a-z])",
        lambda m: " ".join(re.findall(r"[A-Z]\.", m.group(1))),
        author,
    )
    author = re.sub(r"\s+", " ", author).strip(" ,;")
    if author[:1].islower():
        author = author[0].upper() + author[1:]
    return typographic_marks(author)


DERIVED_KEYS = ("header_title", "header_author", "full_title", "rank")


def normalize_book(book: dict, overrides: dict | None = None) -> dict:
    """The book with its display title and author, every other field and
    the key order kept. Starts from the header spelling when present, so a
    re-run over an already-built catalog gives the same result. The
    normalized title goes in full_title when the display title is shorter
    (or overridden), and an override's rank is copied in."""
    raw_title = book.get("header_title", book["title"])
    raw_author = book.get("header_author", book["author"])
    override = (overrides or {}).get(str(book["gutenberg_id"]), {})
    full_title = normalize_title(raw_title)
    # An override wins verbatim but for its quote marks, which are set as
    # every other title's are.
    title = typographic_marks(override["title"]) if "title" in override else display_title(full_title)
    author = typographic_marks(override["author"]) if "author" in override else normalize_author(raw_author)

    out = {k: v for k, v in book.items() if k not in DERIVED_KEYS}
    out["title"] = title
    out["author"] = author
    if title != raw_title:
        out["header_title"] = raw_title
    if author != raw_author:
        out["header_author"] = raw_author
    if title != full_title:
        out["full_title"] = full_title
    if "rank" in override:
        out["rank"] = override["rank"]
    return out


def title_violations(title: str) -> list[str]:
    problems: list[str] = []
    for word in _words(title):
        if word.is_verbatim or word.is_alt_or:
            continue
        parts = word.text.split("-")
        lowercase_major = (parts[0][:1].islower() and word.lower not in MINOR_WORDS) or any(
            part[:1].islower() and part.lower() not in MINOR_WORDS for part in parts[1:]
        )
        if lowercase_major:
            problems.append(f"lowercase major word '{word.text}' in '{title}'")
        elif word.text[:1].islower() and word.starts_segment:
            problems.append(f"lowercase word '{word.text}' starts a segment in '{title}'")
    if len(title) > MAX_TITLE_LENGTH:
        problems.append(f"longer than {MAX_TITLE_LENGTH} characters ({len(title)}): '{title}'")
    problems += _straight_mark_violations(title)
    return problems


def _straight_mark_violations(text: str) -> list[str]:
    found = [m for m in ("'", '"') if m in text]
    return [f"straight quote mark {', '.join(repr(m) for m in found)} in '{text}'"] if found else []


def author_violations(author: str) -> list[str]:
    problems: list[str] = []
    if not author[:1].isupper():
        problems.append(f"does not start with an uppercase letter: '{author}'")
    found = [m for m in ("(", ")", "AKA", ", active", ", et al", "--", "Pseudonym") if m in author]
    if found:
        problems.append(f"contains {', '.join(repr(m) for m in found)}: '{author}'")
    problems += _straight_mark_violations(author)
    return problems


def lint(books: list[dict]) -> list[str]:
    lines: list[str] = []
    for book in books:
        book_id = book.get("gutenberg_id")
        title, author = book.get("title", ""), book.get("author", "")
        # A null or numeric value is reported, never a TypeError: the sync
        # reads exit 1 as "lint violations only" and still ships the catalog.
        if not isinstance(title, str):
            lines.append(f"#{book_id} title: is not a string: {title!r}")
        elif not title.strip():
            lines.append(f"#{book_id} title: is empty")
        else:
            lines += [f"#{book_id} title: {p}" for p in title_violations(title)]
        if not isinstance(author, str):
            lines.append(f"#{book_id} author: is not a string: {author!r}")
        else:
            lines += [f"#{book_id} author: {p}" for p in author_violations(author)]
    return lines


def load_overrides(path: Path | None = None) -> dict:
    path = path or OVERRIDES_PATH
    try:
        overrides = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    if not isinstance(overrides, dict):
        raise ValueError(f"{path} must hold an object keyed by Gutenberg id")
    # An override wins verbatim, so a bad one must stop the build before the
    # sync touches the bundle (exit 2), not ship a null or blank row.
    for book_id, override in overrides.items():
        if not isinstance(override, dict):
            raise ValueError(f"{path}: #{book_id} must be an object")
        for key in ("title", "author"):
            if key in override and (not isinstance(override[key], str) or not override[key].strip()):
                raise ValueError(f"{path}: #{book_id} {key} must be a non-empty string")
        rank = override.get("rank")
        if "rank" in override and (not isinstance(rank, int) or isinstance(rank, bool) or rank < 1):
            raise ValueError(f"{path}: #{book_id} rank must be a positive integer")
    return overrides


def load_catalog(path: Path) -> dict:
    catalog = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(catalog, dict) or not isinstance(catalog.get("books"), list):
        raise ValueError(f"{path} has no 'books' list")
    return catalog


def write_if_changed(path: Path, data: bytes) -> bool:
    """Atomically replace `path` (temp file + fsync + os.replace), only when
    its bytes differ. Returns whether it wrote."""
    try:
        if path.read_bytes() == data:
            return False
    except FileNotFoundError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".catalog-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        # mkstemp makes the file owner-only; the bundle copy must stay readable.
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("src", type=Path, help="catalog.json to read")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--out", type=Path, help="write the normalized catalog here")
    mode.add_argument("--check", action="store_true", help="lint SRC as-is")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return int(exit_.code or 0)

    try:
        catalog = load_catalog(args.src)
        if args.check:
            problems = lint(catalog["books"])
            for line in problems:
                print(line)
            return 1 if problems else 0

        overrides = load_overrides()
        catalog = {**catalog, "books": [normalize_book(b, overrides) for b in catalog["books"]]}
        text = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"
        if args.out is None:
            sys.stdout.write(text)
        else:
            write_if_changed(args.out, text.encode("utf-8"))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 2

    problems = lint(catalog["books"])
    for line in problems:
        print(line, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
