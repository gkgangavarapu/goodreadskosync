#!/bin/sh
# Build the NetSurf-backed renderer on a development machine.
#
#   ./build-dev.sh
#
# Outputs ./out/netsurf_render.
#
# This script installs nothing on non-Alpine systems; it assumes the NetSurf
# build dependencies are present (see Dockerfile for the exact list). On Alpine
# it installs them with apk when run as root or with sudo.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${NETSURF_WORK:-$HOME/.cache/netsurf-render}"
VERSION=3.11
TARBALL="netsurf-all-$VERSION.tar.gz"
URL="http://download.netsurf-browser.org/netsurf/releases/source-full/$TARBALL"
TREE="$WORK/netsurf-all-$VERSION"
OUT="$HERE/out"

DEP_LIST="build-base git curl wget tar perl coreutils flex bison gperf pkgconf \
	linux-headers musl-dev curl-dev openssl-dev expat-dev libpng-dev \
	libjpeg-turbo-dev libwebp-dev giflib-dev zlib-dev freetype-dev \
	harfbuzz-dev fontconfig-dev libxml2-dev"

if command -v apk >/dev/null 2>&1; then
	APK="apk"
	if [ "$(id -u)" != "0" ]; then APK="sudo -n apk"; fi
	echo "== installing Alpine build dependencies =="
	for p in $DEP_LIST; do
		$APK add --no-cache "$p" >/dev/null 2>&1 || echo "  (skip $p)"
	done
fi

mkdir -p "$WORK" "$OUT"
cd "$WORK"
if [ ! -f "$TARBALL" ]; then
	echo "== downloading $URL =="
	wget -q -O "$TARBALL" "$URL"
fi
if [ ! -d "$TREE" ]; then
	tar xzf "$TARBALL"
fi

echo "== building NetSurf libraries (TARGET=monkey) =="
cd "$TREE"
export CFLAGS="-fcommon"
# Upstream ignores several warnings that newer compilers promote to errors.
grep -rl -- '-Werror' --include='Makefile*' . 2>/dev/null | while read -r f; do
	sed -i 's/-Werror//g' "$f"
done
make TARGET=monkey -j"$(nproc)" >/tmp/netsurf-libs.log 2>&1 || {
	echo "library build failed; see /tmp/netsurf-libs.log" >&2
	tail -20 /tmp/netsurf-libs.log >&2
	exit 1
}

echo "== applying netsurf_render frontend =="
"$HERE/apply-frontend.sh" "$TREE"

echo "== building netsurf_render =="
export PKG_CONFIG_PATH="$TREE/inst-monkey/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$PATH:$TREE/inst-monkey/bin"
cd "$TREE/netsurf"
make TARGET=monkey -j"$(nproc)" >/tmp/netsurf-render.log 2>&1 || {
	echo "renderer build failed; see /tmp/netsurf-render.log" >&2
	tail -30 /tmp/netsurf-render.log >&2
	exit 1
}

cp "$TREE/netsurf/netsurf_render" "$OUT/netsurf_render"
echo "== built $OUT/netsurf_render =="
