#!/bin/sh
# PW3 NetSurf smoke test.
#
# Run ON the Kindle, from inside the extracted package directory:
#     ./smoke-test.sh [cookies.netscape]
#
# It runs a staged set of URLs, records objective results for each, and writes
# report.txt next to this script (plus the raw frame.pgm/frame.json per case).
# It is self-contained: NETSURFRES/CA paths resolve relative to this directory.
#
# Optional argument: a Netscape-format cookies file for the authenticated
# Goodreads case (case 11). Without it, that case is marked SKIPPED.

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/netsurf_render"
RES="$HERE/resources"
COOKIES="$1"
TMP="${TMPDIR:-/tmp}"
OUTDIR="$TMP/netsurf-smoke"
mkdir -p "$OUTDIR" 2>/dev/null || OUTDIR="/tmp"
REPORT="$HERE/report.txt"
: > "$REPORT"

export NETSURFRES="$RES"
export CURL_CA_BUNDLE="$RES/ca-bundle"
export SSL_CERT_FILE="$RES/ca-bundle"

log() { echo "$@" >> "$REPORT"; }
say() { echo "$@"; }

field() { grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed "s/.*\"$2\":\"//; s/\"\$//"; }
num()   { grep -o "\"$2\":[0-9]*" "$1" 2>/dev/null | head -1 | sed "s/.*://"; }
hits()  { grep -o '"href"' "$1" 2>/dev/null | wc -l | tr -d ' '; }

make_pages() {
  cat > "$HERE/t1_plain.html" <<'EOF'
<html><head><title>PW3 t1 plain</title></head>
<body><h1>Plain local page</h1><p>No styling beyond defaults.</p></body></html>
EOF
  cat > "$HERE/t2_css.html" <<'EOF'
<html><head><title>PW3 t2 css</title><style>
body{font-size:1.2em;color:#222;margin:1em}
h1{color:#003366;font-size:2.2em}
a{color:#0366d6}
blockquote{border-left:4px solid #ccc;margin:1em;padding-left:1em}
</style></head><body>
<h1>Styled local page</h1>
<p>Paragraph with a <a href="t1_plain.html">link</a>.</p>
<blockquote>Quoted text.</blockquote></body></html>
EOF
  cat > "$HERE/t3_image.html" <<'EOF'
<html><head><title>PW3 t3 image</title></head>
<body><h1>Local image</h1>
<p><img src="resources/favicon.png" width="96" height="96"></p></body></html>
EOF
  cat > "$HERE/t4_links.html" <<'EOF'
<html><head><title>PW3 t4 links</title></head>
<body><h1>Link targets</h1>
<p><a href="t1_plain.html">plain</a> <a href="t2_css.html">styled</a>
   <a href="t3_image.html">image</a></p></body></html>
EOF
  # Tall page for the scroll test.
  { echo '<html><head><title>PW3 t5 tall</title></head><body><h1>Scroll test</h1>'
    i=1; while [ $i -le 120 ]; do echo "<p>Line $i of a deliberately tall page.</p>"; i=$((i+1)); done
    echo '</body></html>'; } > "$HERE/t5_tall.html"
}

run_case() {
  idx="$1"; desc="$2"; url="$3"; shift 3
  base="$OUTDIR/c$idx"
  rm -f "$base.pgm" "$base.json"
  log "------------------------------------------------------------"
  log "[$idx] $desc"
  log "  url: $url"
  if [ ! -x "$BIN" ]; then log "  SKIPPED: helper not executable"; return; fi
  t0=$(date +%s 2>/dev/null || echo 0)
  "$BIN" --url "$url" --width 600 --height 800 --out "$base" "$@" >"$base.log" 2>&1 &
  pid=$!
  hwm=0
  while kill -0 "$pid" 2>/dev/null; do
    v=$(sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$pid/status" 2>/dev/null)
    if [ -n "$v" ]; then case "$v" in *[!0-9]*) ;; *) [ "$v" -gt "$hwm" ] && hwm="$v" ;; esac; fi
    sleep 1
  done
  wait "$pid"; rc=$?
  t1=$(date +%s 2>/dev/null || echo 0)

  pgm="no"; [ -f "$base.pgm" ] && [ "$(head -c2 "$base.pgm" 2>/dev/null)" = "P5" ] && pgm="yes"
  js="no";  [ -f "$base.json" ] && js="yes"
  log "  exit: $rc   frame.pgm: $pgm ($(wc -c < "$base.pgm" 2>/dev/null) bytes)   frame.json: $js"
  if [ "$js" = "yes" ]; then
    log "  title: $(field "$base.json" title)"
    log "  url:   $(field "$base.json" url)"
    log "  viewport: $(num "$base.json" width)x$(num "$base.json" height)   scroll_h: $(num "$base.json" scroll_h)"
    log "  hits: $(hits "$base.json")"
  fi
  log "  time: $((t1 - t0))s   peakRSS: ${hwm}kB"
  say "[$idx] $desc -> exit=$rc pgm=$pgm json=$js title=$(field "$base.json" title)"
}

say "NetSurf PW3 smoke test -> $REPORT"
make_pages

run_case 1  "local file:// HTML"                "file://$HERE/t1_plain.html"
run_case 2  "local HTML + CSS"                  "file://$HERE/t2_css.html"
run_case 3  "local PNG image"                   "file://$HERE/t3_image.html"
run_case 4  "local links + hitmap"              "file://$HERE/t4_links.html"
run_case 5  "scrolling (tall page, --scroll 400)" "file://$HERE/t5_tall.html" --scroll 400
run_case 6  "data: URL"                         "data:text/html,<h1>data ok</h1>"
run_case 7  "http://example.com/"               "http://example.com/"
run_case 8  "https://example.com/"              "https://example.com/"
run_case 9  "CSS-heavy (gnu.org)"               "https://www.gnu.org/"
run_case 10 "Goodreads public book page"        "https://www.goodreads.com/book/show/3.Harry_Potter_and_the_Sorcerers_Stone"
if [ -n "$COOKIES" ] && [ -f "$COOKIES" ]; then
  run_case 11 "Goodreads authenticated (My Books)" "https://www.goodreads.com/review/list" --cookies "$COOKIES"
else
  log "------------------------------------------------------------"
  log "[11] Goodreads authenticated — SKIPPED (pass a Netscape cookies file)"
fi

log "============================================================"
log "done $(date 2>/dev/null)"
say "done; send report.txt back"
