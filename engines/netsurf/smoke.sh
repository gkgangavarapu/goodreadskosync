#!/bin/sh
# Render one URL through the helper and report. Usage:
#   ./smoke.sh [path-to-netsurf_render] [url]
set -eu

BIN="${1:-./out/netsurf_render}"
URL="${2:-https://example.com/}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "== helper: $BIN"
echo "== url:    $URL"
"$BIN" --url "$URL" --width 600 --height 800 --out "$OUT/page"

echo "== outputs =="
ls -l "$OUT/page.pgm" "$OUT/page.json"
echo "== json =="
cat "$OUT/page.json"; echo
echo "== pgm magic (expect P5) =="
head -c 2 "$OUT/page.pgm"; echo
