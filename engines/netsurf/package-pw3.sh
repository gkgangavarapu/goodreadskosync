#!/bin/sh
# Build a self-contained PW3 device-test package for the NetSurf helper.
#
#   NETSURF_RES=/path/to/netsurf/resources ./package-pw3.sh /path/to/netsurf_render
#
# Output: out/pw3/netsurf_render-pw3.tar.gz containing
#   device-test/netsurf_render   ARM helper
#   device-test/resources/       NetSurf resources (default.css, ca-bundle, ...)
#   device-test/run.sh           launcher with deterministic paths
#   device-test/README.txt       device instructions
#
# The package references only files inside itself; there is no dependency on the
# build tree. A launcher resolves everything relative to its own directory.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out/pw3"
PKG="$OUT/device-test"
BIN="${1:-$OUT/netsurf_render}"

[ -f "$BIN" ] || { echo "missing helper: $BIN" >&2; echo "usage: NETSURF_RES=... $0 <netsurf_render>" >&2; exit 1; }

# Locate NetSurf resources (default.css, ca-bundle, Messages, ...).
RES="${NETSURF_RES:-}"
if [ -z "$RES" ]; then
	for cand in "$OUT/resources" "$HERE/resources" \
	            "$HOME/.cache/netsurf-pw3/netsurf-all-3.11/netsurf/resources" \
	            "$HOME/.cache/netsurf-kindlepw2/netsurf-all-3.11/netsurf/resources"; do
		[ -d "$cand" ] && RES="$cand" && break
	done
fi
[ -n "$RES" ] && [ -d "$RES" ] || { echo "NetSurf resources not found; set NETSURF_RES" >&2; exit 1; }
[ -f "$RES/ca-bundle" ] || { echo "warning: $RES/ca-bundle missing (HTTPS will fail)" >&2; }

rm -rf "$PKG"
mkdir -p "$PKG"
install -m 755 "$BIN" "$PKG/netsurf_render"
cp -a "$RES" "$PKG/resources"

# Optional: a mime.types improves local-file content typing (NetSurf otherwise
# falls back to a minimal built-in table).
for mt in /etc/mime.types /usr/share/mime.types; do
	[ -f "$mt" ] && cp "$mt" "$PKG/resources/mime.types" && break
done

cat > "$PKG/run.sh" <<'EOF'
#!/bin/sh
# Self-contained launcher. Everything is resolved relative to this script.
#   ./run.sh [url] [out-prefix] [width] [height]
HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-https://example.com/}"
OUT="${2:-/tmp/netsurf-render}"
W="${3:-600}"
H="${4:-800}"

# Deterministic runtime/resource paths (no build-tree dependency).
export NETSURFRES="$HERE/resources"
export CURL_CA_BUNDLE="$HERE/resources/ca-bundle"
export SSL_CERT_FILE="$HERE/resources/ca-bundle"
# Keep per-run scratch files off persistent storage where possible.
export TMPDIR="${TMPDIR:-/var/tmp}"

exec "$HERE/netsurf_render" --url "$URL" --width "$W" --height "$H" --out "$OUT"
EOF
chmod 755 "$PKG/run.sh"

install -m 755 "$HERE/pw3-smoke-test.sh" "$PKG/smoke-test.sh"

cat > "$PKG/README.txt" <<'EOF'
NetSurf renderer — PW3 device test bundle
=========================================
Contents
  netsurf_render   - static ARMv7 (armv7-a, soft-float, EABI5, glibc<=2.12) helper
  resources/       - NetSurf resources (default.css, ca-bundle, Messages, mime.types)
  run.sh           - launcher; resolves resources relative to this directory

Usage
  1. Copy this whole directory to the device, e.g.
       /mnt/us/koreader/goodreadskosync/netsurf/
  2. One-command smoke test (writes report.txt + per-case frame.pgm/frame.json):
       ./smoke-test.sh
     Optional authenticated Goodreads case 11 (Netscape cookies file):
       ./smoke-test.sh /path/to/cookies.netscape
  3. Or render a single URL:
       ./run.sh https://example.com/ /tmp/ex
  4. Point the plugin's browser_netsurf_bin setting at <dir>/netsurf_render.
  5. Send back report.txt (and any case .json that failed).

Notes
  - No JavaScript. Software-only; never touches /dev/fb0.
  - The helper exits non-zero after writing output on some glibc versions; the
    engine still consumes a complete frame.pgm/frame.json (post-output abort).
  - Record: startup time, first-render time, peak RSS, and page results.
EOF

echo "== package: $PKG =="
ls -l "$PKG" "$PKG/resources" | head -30
tar -C "$OUT" -czf "$OUT/netsurf_render-pw3.tar.gz" device-test
echo "== $OUT/netsurf_render-pw3.tar.gz ($(wc -c < "$OUT/netsurf_render-pw3.tar.gz") bytes) =="
