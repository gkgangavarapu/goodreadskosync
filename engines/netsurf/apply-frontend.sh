#!/bin/sh
# Apply the netsurf_render frontend to a NetSurf source tree.
#
#   ./apply-frontend.sh /path/to/netsurf-all-3.11
#
# It copies our frontend sources over the NetSurf "monkey" frontend (the
# minimal headless frontend) and patches it to:
#   - use the requested viewport size,
#   - build a one-shot renderer (netsurf_render) instead of nsmonkey,
#   - rasterise into an offscreen memory buffer via our plotter.
#
# Idempotent: safe to run repeatedly.
set -eu

TREE="${1:-}"
if [ -z "$TREE" ] || [ ! -d "$TREE/netsurf/frontends/monkey" ]; then
	echo "usage: $0 /path/to/netsurf-all-3.11" >&2
	exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
MONKEY="$TREE/netsurf/frontends/monkey"

echo "== copying frontend sources =="
cp "$HERE/frontend/render.h" "$HERE/frontend/render.c" \
   "$HERE/frontend/plot.c" "$HERE/frontend/bitmap.c" \
   "$HERE/frontend/font8x8_basic.h" "$MONKEY/"

echo "== patching browser.c =="
grep -q 'monkey/render.h' "$MONKEY/browser.c" || \
	sed -i 's:#include "monkey/plot.h":#include "monkey/plot.h"\n#include "monkey/render.h":' "$MONKEY/browser.c"
sed -i 's/ret->width = 800;/ret->width = render_default_width;/' "$MONKEY/browser.c"
sed -i 's/ret->height = 600;/ret->height = render_default_height;/' "$MONKEY/browser.c"

echo "== patching main.c =="
grep -q 'monkey/render.h' "$MONKEY/main.c" || \
	sed -i 's:#include "monkey/layout.h":#include "monkey/layout.h"\n#include "monkey/render.h":' "$MONKEY/main.c"
if ! grep -q 'render_parse_args' "$MONKEY/main.c"; then
	BLOCK="$(mktemp)"
	cat > "$BLOCK" <<'EOF'
	{
		struct render_opts ropts;
		if (render_parse_args(&argc, argv, &ropts)) {
			int rc = render_main(&ropts);
			netsurf_exit();
			nsoption_finalise(nsoptions, nsoptions_default);
			nslog_finalise();
			monkey_free_handlers();
			return rc;
		}
	}
EOF
	sed -i '/moutf(MOUT_GENERIC, "STARTED");/r '"$BLOCK" "$MONKEY/main.c"
	rm -f "$BLOCK"
fi

echo "== patching Makefile =="
sed -i 's/EXETARGET := nsmonkey/EXETARGET := netsurf_render/' "$MONKEY/Makefile"
grep -q 'fetch.c render.c' "$MONKEY/Makefile" || \
	sed -i 's/download.c 401login.c layout.c dispatch.c fetch.c/download.c 401login.c layout.c dispatch.c fetch.c render.c/' "$MONKEY/Makefile"

echo "== done: $MONKEY now builds netsurf_render =="
