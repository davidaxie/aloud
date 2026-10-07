"""Download the Kokoro model + voice bank into backend/models/ (one-time setup).

Uses only the standard library so it can run with the project venv before any
optional deps are present. Safe to re-run: files that already match their
pinned SHA-256 are skipped, and anything else is fetched again. A download that
does not match is deleted rather than kept. Run with the project venv, e.g.:

    .venv/bin/python download_models.py
"""
from __future__ import annotations

import hashlib
import os
import sys
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
_MODELS_DIR = os.path.join(_HERE, "models")

_BASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
# (filename, url, expected bytes, SHA-256). The hash, not the size, decides
# whether a file is the real one: a size check also passes a corrupt or swapped
# file of nearly the right length.
_ASSETS = [
    (
        "kokoro-v1.0.onnx",
        f"{_BASE}/kokoro-v1.0.onnx",
        325_532_387,
        "7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5",
    ),
    (
        "voices-v1.0.bin",
        f"{_BASE}/voices-v1.0.bin",
        28_214_398,
        "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
    ),
]


def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _matches(path: str, expected_bytes: int, sha256: str) -> bool:
    """True if ``path`` exists and is the pinned file. The size is checked first
    so a wrong file costs no hashing."""
    return (
        os.path.exists(path)
        and os.path.getsize(path) == expected_bytes
        and _sha256(path) == sha256
    )


def _download(url: str, dest: str) -> None:
    tmp = dest + ".part"

    def _progress(block_num: int, block_size: int, total: int) -> None:
        if total <= 0:
            return
        done = min(block_num * block_size, total)
        pct = done * 100 // total
        sys.stdout.write(f"\r  {os.path.basename(dest)}: {pct:3d}%  ({done // (1024*1024)} MB)")
        sys.stdout.flush()

    urllib.request.urlretrieve(url, tmp, _progress)
    sys.stdout.write("\n")
    os.replace(tmp, dest)


def main() -> int:
    os.makedirs(_MODELS_DIR, exist_ok=True)
    for name, url, expected, sha256 in _ASSETS:
        dest = os.path.join(_MODELS_DIR, name)
        if _matches(dest, expected, sha256):
            print(f"✓ {name} already present, skipping.")
            continue
        print(f"↓ downloading {name} …")
        _download(url, dest)
        if not _matches(dest, expected, sha256):
            os.remove(dest)
            print(
                f"✗ {name} did not match its pinned SHA-256, so it was deleted. "
                f"Run this again; if it keeps failing, the file at {url} has changed.",
                file=sys.stderr,
            )
            return 1
        print(f"✓ {name} ready ({os.path.getsize(dest) // (1024*1024)} MB).")
    print("All Kokoro assets ready in", _MODELS_DIR)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
