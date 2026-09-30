#!/bin/sh
# Assemble the PW3 device-test bundle: the renderer, NetSurf resources, a
# launcher that wires up NETSURFRES, and the smoke test.
#
#   ./package-pw3.sh            # uses out/pw3/netsurf_render
#
# Output: out/pw3/device-test/  (tarred as out/pw3/netsurf_render-pw3.tar.gz)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out/pw3"
PKG="$OUT/device-test"
BIN="${1:-$OUT/netsurf_render}"

[ -f "$BIN" ] || { echo "missing $BIN (run build-pw3.sh first)" >&2; exit 1; }

RES=""
for cand in "$HERE/out/pw3/resources" "$HERE/../netsurf-arm/netsurf/resources"; do
	[ -d "$cand" ] && RES="$cand" && break
done

rm -rf "$PKG"
mkdir -p "$PKG"
install -m 755 "$BIN" "$PKG/netsurf_render"

if [ -n "$RES" ]; then
	cp -a "$RES" "$PKG/resources"
else
	echo "warning: NetSurf resources/ not found; the binary needs NETSURFRES at runtime" >&2
fi

cat > "$PKG/run.sh" <<'EOF'
#!/bin/sh
# Usage: ./run.sh <url> [out-prefix] [width] [height]
# The Kindle glibc is old (2.12); keep it simple.
HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-https://example.com/}"
OUT="${2:-/tmp/netsurf-render}"
W="${3:-600}"
H="${4:-800}"
export NETSURFRES="$HERE/resources"
exec "$HERE/netsurf_render" --url "$URL" --width "$W" --height "$H" --out "$OUT"
EOF
chmod 755 "$PKG/run.sh"

cat > "$PKG/README.txt" <<'EOF'
NetSurf renderer — PW3 device test
==================================
1. Copy this directory to the Kindle, e.g.
     /mnt/us/koreader/goodreadskosync/netsurf/
2. Run:
     /mnt/us/koreader/goodreadskosync/netsurf/run.sh https://example.com/ /tmp/ex
   -> writes /tmp/ex.pgm and /tmp/ex.json
3. Measures to record:
     time ./run.sh https://example.com/ /tmp/ex      # startup + first render
     /usr/bin/time -v ./run.sh ... (if available)     # peak RSS
Static ARM binary (armv7-a, soft-float, glibc). No JavaScript. No /dev/fb0.
EOF

echo "== bundle: $PKG =="
ls -l "$PKG"
tar -C "$OUT" -czf "$OUT/netsurf_render-pw3.tar.gz" device-test
echo "== $OUT/netsurf_render-pw3.tar.gz =="
ls -l "$OUT/netsurf_render-pw3.tar.gz"
