#!/bin/sh
# Cross-compile the NetSurf renderer for the Kindle Paperwhite 3.
#
#   CROSS=arm-kindle-linux-gnueabi- \
#   SYSROOT=/path/to/pw3-sysroot \
#   NETSURF_TREE=/path/to/netsurf-all-3.11-armv7 \
#   ./build-pw3.sh
#
# The NetSurf libraries must already be built for armv7 in $NETSURF_TREE (build
# them the same way as build-dev.sh but with HOST/CC set to the cross toolchain
# and TARGET=framebuffer, which is the target that builds libnsfb). The renderer
# itself is software-only: no EGL/GBM/DRM, and it never opens /dev/fb0.
set -eu

: "${CROSS:?set CROSS to the arm toolchain prefix (e.g. arm-kindle-linux-gnueabi-)}"
: "${SYSROOT:?set SYSROOT to the PW3 cross sysroot}"
: "${NETSURF_TREE:?set NETSURF_TREE to an armv7 NetSurf source tree}"

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$NETSURF_TREE/netsurf/build"
OUT="$HERE/out/pw3"
mkdir -p "$OUT"

CC="${CROSS}gcc"
MONKEY="$NETSURF_TREE/netsurf/frontends/monkey"
SRCS="$MONKEY/render.c $MONKEY/plot.c $MONKEY/bitmap.c"

echo "== cross-compiling netsurf_render for armv7 =="
# These are the objects NetSurf's own build links into the frontend; the
# simplest reliable approach is to build the whole frontend with its Makefile.
export CFLAGS="-fcommon --sysroot=$SYSROOT"
export PKG_CONFIG_PATH="$NETSURF_TREE/inst-framebuffer/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$PATH:$NETSURF_TREE/inst-framebuffer/bin"

CC="$CC" CXX="${CROSS}g++" \
	SRC="$NETSURF_TREE" \
	make -C "$NETSURF_TREE/netsurf" TARGET=framebuffer \
		HOST="${CROSS%-}" -j"$(nproc)" 2>&1 | tail -20

cp "$NETSURF_TREE/netsurf/netsurf_render" "$OUT/netsurf_render" 2>/dev/null || {
	echo "expected $NETSURF_TREE/netsurf/netsurf_render; see build output" >&2
	exit 1
}

echo "== built $OUT/netsurf_render =="
echo "Copy the binary and its shared libraries to the device, e.g."
echo "  /mnt/us/koreader/goodreadskosync/bin/netsurf_render"
