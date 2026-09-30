#!/bin/sh
# Target-specific NetSurf build configurations for KOReader platforms.
#
#   KOX_ROOT=/path/to/x-tools ./build-target.sh <target>
#
# KOX_ROOT is a directory of extracted KOReader KOXToolchain releases, one per
# triplet, e.g.:
#   x-tools/arm-kindlepw2-linux-gnueabi/
#   x-tools/arm-kobo-linux-gnueabihf/
# Get them from https://github.com/koreader/koxtoolchain/releases.
#
# The PW3 (kindlepw2) config is only one entry here; nothing makes it global.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
: "${KOX_ROOT:?set KOX_ROOT to the directory containing x-tools/<triplet> dirs}"

case "$TARGET" in
	kindlepw2|pw3)   CHOST=arm-kindlepw2-linux-gnueabi
	                 ARCH="-march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=softfp -mthumb -O2" ;;
	kindlehf)        CHOST=arm-kindlehf-linux-gnueabihf
	                 ARCH="-march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard -mthumb -O2" ;;
	kobo|kobov4)     CHOST=arm-kobo-linux-gnueabihf
	                 ARCH="-march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard -mthumb -O2" ;;
	kobov5)          CHOST=arm-kobov5-linux-gnueabihf
	                 ARCH="-march=armv7-a -mtune=cortex-a53 -mfpu=neon -mfloat-abi=hard -mthumb -O2" ;;
	pocketbook)      CHOST=arm-pocketbook-linux-gnueabi
	                 ARCH="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb -O2" ;;
	remarkable)      CHOST=arm-remarkable-linux-gnueabihf
	                 ARCH="-march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard -mthumb -O2" ;;
	linux)
		echo "== linux: native build =="
		exec "$HERE/build-dev.sh" ;;
	"")
		echo "usage: KOX_ROOT=... $0 <kindlepw2|kindlehf|kobo|kobov4|kobov5|pocketbook|remarkable|linux>" >&2
		exit 1 ;;
	*)
		echo "unknown target: $TARGET" >&2; exit 1 ;;
esac

[ -d "$KOX_ROOT/$CHOST" ] || {
	echo "error: toolchain for $CHOST not found under $KOX_ROOT" >&2
	echo "       expected $KOX_ROOT/$CHOST/bin/$CHOST-gcc" >&2
	exit 1
}

echo "== target=$TARGET chost=$CHOST =="
KOX_TC="$KOX_ROOT/$CHOST" CHOST="$CHOST" ARCH_CFLAGS="$ARCH" TARGET_NAME="$TARGET" \
	exec "$HERE/build-pw3.sh"
