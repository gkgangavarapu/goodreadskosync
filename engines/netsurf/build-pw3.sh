#!/bin/sh
# Cross-compile the NetSurf engine helper for the Kindle Paperwhite 3.
#
#   CROSS=arm-kindle-linux-gnueabi- SYSROOT=/path/to/pw3-sysroot ./build-pw3.sh
#
# Requirements:
#   - a PW3 (ARMv7 hard-float, glibc) cross toolchain
#   - a sysroot with NetSurf's deps (curl/png/jpeg/ssl/expat/harfbuzz/freetype/
#     fontconfig/gif/webp/zlib) AND a NetSurf core built for armv7
#   - libnsfb built with the "mem" surface enabled (no framebuffer needed)
#
# The helper stays software-only: no EGL/GBM/DRM, no /dev/fb0.
set -eu

: "${CROSS:?set CROSS to your arm toolchain prefix, e.g. arm-kindle-linux-gnueabi-}"
: "${SYSROOT:?set SYSROOT to the PW3 cross sysroot}"
: "${NETSURF_OBJDIR:?set NETSURF_OBJDIR to the armv7 NetSurf build dir}"
: "${NETSURF_SRC:?set NETSURF_SRC to the NetSurf source dir}"

CC="${CROSS}gcc"
OUT="out/pw3"
mkdir -p "$OUT"

pkg-config --define-prefix --exists libnsfb 2>/dev/null || true

"$CC" -O2 -g -Wall -Wno-unused-parameter \
    --sysroot="$SYSROOT" \
    $(pkg-config --cflags --sysroot="$SYSROOT" libnsfb 2>/dev/null) \
    -I"$NETSURF_SRC" -I"$NETSURF_OBJDIR" \
    netsurf_render.c -o "$OUT/netsurf_render" \
    -L"$NETSURF_OBJDIR" -lnetsurf_core \
    $(pkg-config --libs --sysroot="$SYSROOT" libnsfb 2>/dev/null || echo -lnsfb) \
    -lcurl -lpng -ljpeg -lssl -lcrypto -lexpat -lharfbuzz -lfreetype \
    -lfontconfig -lgif -lwebp -lz -lm

echo "built $OUT/netsurf_render"
echo "copy to the device, e.g.:"
echo "  /mnt/us/koreader/goodreadskosync/bin/netsurf_render"
