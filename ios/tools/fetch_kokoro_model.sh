#!/usr/bin/env bash
# Fetches the pinned Kokoro pair (model.onnx + voices.bin, 353 MB) into
# /Users/Shared/AloudKokoroModel/, the seed that UI tests and the Mac's
# offline tests read. Outside OneDrive and /tmp, so it survives syncs,
# cache purges and reboots.
#
# Every file is checked with `shasum -a 256` against the pinned hash and
# refused on any mismatch: a wrong file is deleted, never kept. The
# revision, sizes and hashes are the ones in ModelManager.remoteFiles
# (ios/Aloud/TTS/ModelManager.swift); change them together.
#
# A 353 MB download: run it only with the owner's OK.
set -euo pipefail

REVISION=7e9b67b79bfdcbd2b4bc144370345fcceac3cb0c
BASE="https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/$REVISION"
DEST=/Users/Shared/AloudKokoroModel

expected_bytes() {
  case "$1" in
    model.onnx) echo 325630829 ;;
    voices.bin) echo 27678720 ;;
  esac
}

expected_sha256() {
  case "$1" in
    model.onnx) echo c436dc6a842b62aba06af67e40bafcfb9c60ac3af895358f1974ad9a7f7c026b ;;
    voices.bin) echo 8a77c0d397026208d22211f37670b5b3b11e03f190756b25a1d24041fced82a9 ;;
  esac
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

mkdir -p "$DEST"
for name in model.onnx voices.bin; do
  final="$DEST/$name"
  want_bytes=$(expected_bytes "$name")
  want_sha=$(expected_sha256 "$name")

  # A file already here is kept only if it is the pinned one.
  if [[ -f "$final" ]]; then
    if [[ "$(stat -f %z "$final")" == "$want_bytes" && "$(sha256_of "$final")" == "$want_sha" ]]; then
      echo "[kokoro] $name already pinned, kept"
      continue
    fi
    echo "[kokoro] $name is not the pinned file, replacing it"
    rm -f "$final"
  fi

  part="$final.part"
  rm -f "$part"
  echo "[kokoro] downloading $name ($want_bytes bytes) at $REVISION"
  curl --fail --location --retry 3 --output "$part" "$BASE/$name"

  got_bytes=$(stat -f %z "$part")
  if [[ "$got_bytes" != "$want_bytes" ]]; then
    rm -f "$part"
    echo "[kokoro] REFUSED $name: $got_bytes bytes, expected $want_bytes" >&2
    exit 1
  fi
  got_sha=$(sha256_of "$part")
  if [[ "$got_sha" != "$want_sha" ]]; then
    rm -f "$part"
    echo "[kokoro] REFUSED $name: sha256 $got_sha, expected $want_sha" >&2
    exit 1
  fi
  mv -f "$part" "$final"
done

# The hashes as shasum derives them, to compare with ModelManager before a
# change to the pins is committed.
echo "[kokoro] verified in $DEST:"
(cd "$DEST" && shasum -a 256 model.onnx voices.bin)
