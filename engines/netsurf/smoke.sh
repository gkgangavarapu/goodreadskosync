#!/bin/sh
# Quick smoke test: render example.com through the helper and report.
set -eu

BIN="${1:-./out/netsurf_render}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "== helper: $BIN"
"$BIN" --url https://example.com/ --width 600 --height 800 --out "$OUT/example"

echo "== frame:"
ls -l "$OUT/example.pgm" "$OUT/example.json"
head -c 200 "$OUT/example.json"; echo
echo "== expected first bytes of PGM: P5"
head -c 2 "$OUT/example.pgm"; echo
