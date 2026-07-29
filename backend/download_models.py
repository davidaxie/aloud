"""Download the Kokoro model + voice bank into backend/models/ (one-time setup).

Uses only the standard library so it can run with the project venv before any
optional deps are present. Safe to re-run: existing, correctly-sized files are
skipped. Run with the project venv, e.g.:

    .venv/bin/python download_models.py
"""
from __future__ import annotations

import os
import sys
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
_MODELS_DIR = os.path.join(_HERE, "models")

_BASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
# (filename, url, approx expected bytes) — expected size guards against partial downloads.
_ASSETS = [
    ("kokoro-v1.0.onnx", f"{_BASE}/kokoro-v1.0.onnx", 325_532_387),
    ("voices-v1.0.bin", f"{_BASE}/voices-v1.0.bin", 28_214_398),
]


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
    for name, url, expected in _ASSETS:
        dest = os.path.join(_MODELS_DIR, name)
        if os.path.exists(dest) and abs(os.path.getsize(dest) - expected) < expected * 0.05:
            print(f"✓ {name} already present, skipping.")
            continue
        print(f"↓ downloading {name} …")
        _download(url, dest)
        print(f"✓ {name} ready ({os.path.getsize(dest) // (1024*1024)} MB).")
    print("All Kokoro assets ready in", _MODELS_DIR)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
