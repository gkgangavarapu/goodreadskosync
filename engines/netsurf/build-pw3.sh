#!/bin/sh
# Reproducible cross-build of netsurf_render for the Kindle Paperwhite 3.
#
# Target (verified): PW3 => KOReader "kindlepw2" target =>
#   armv7-a, Cortex-A9, NEON, EABI5, **soft-float ABI**, glibc <= 2.12.
#
# Toolchain: a KOReader KOXToolchain release, e.g. "kindlepw2"
#   https://github.com/koreader/koxtoolchain/releases  (asset: kindlepw2.tar.*)
#   It bundles arm-kindlepw2-linux-gnueabi-{gcc,binutils,...} (GCC 14.2, glibc 2.12).
# Other KOReader targets are driven by ./build-target.sh, which sets CHOST,
# ARCH_CFLAGS and TARGET_NAME (this script stays target-agnostic).
#
# IMPORTANT: the toolchain's host binaries are glibc-dynamic x86_64 programs, so
# this script must run on a glibc host (e.g. a Debian chroot). See pw3-toolchain.md.
#
# Usage:
#   KOX_TC=/path/to/x-tools/arm-kindlepw2-linux-gnueabi ./build-pw3.sh
#
# Env:
#   KOX_TC        (required) path to the extracted toolchain dir (contains bin/)
#   CHOST         (optional) target triplet, default arm-kindlepw2-linux-gnueabi
#   ARCH_CFLAGS   (optional) arch flags, default softfp Cortex-A9 + NEON
#   TARGET_NAME   (optional) output dir name, default pw3
#   WORK          (optional) build dir, default ~/.cache/netsurf-<target>
#   JOBS          (optional) parallelism, default nproc
#
# Output: out/<TARGET_NAME>/netsurf_render (statically linked executable)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KOX_TC:?set KOX_TC to the extracted toolchain dir (contains bin/)}"
CHOST="${CHOST:-arm-kindlepw2-linux-gnueabi}"
TARGET_NAME="${TARGET_NAME:-pw3}"
[ -x "$KOX_TC/bin/$CHOST-gcc" ] || {
	echo "error: $KOX_TC/bin/$CHOST-gcc not found" >&2
	echo "       KOX_TC must point at a dir containing bin/$CHOST-gcc" >&2
	exit 1
}

WORK="${WORK:-$HOME/.cache/netsurf-$TARGET_NAME}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
SRC_VERSION=3.11
TARBALL="netsurf-all-$SRC_VERSION.tar.gz"
TARBALL_URL="http://download.netsurf-browser.org/netsurf/releases/source-full/$TARBALL"
TREE="$WORK/netsurf-all-$SRC_VERSION"
STAGE="$TREE/inst-monkey"
OUT="$HERE/out/$TARGET_NAME"
TCBIN="$KOX_TC/bin"
TC="$CHOST"
ARCHFLAGS="${ARCH_CFLAGS:--march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=softfp -mthumb -O2}"

export PATH="$TCBIN:$PATH"

echo "== work dir $WORK =="
mkdir -p "$WORK" "$WORK/src" "$OUT"
cd "$WORK/src"

fetch() { [ -f "$1" ] || curl -fsSL -o "$1" "$2"; }
echo "== fetching sources =="
fetch "$TARBALL" "$TARBALL_URL"
fetch zlib.tar.gz "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz"
fetch openssl.tar.gz "https://github.com/openssl/openssl/releases/download/openssl-3.0.15/openssl-3.0.15.tar.gz"
fetch curl.tar.gz "https://github.com/curl/curl/releases/download/curl-8_10_1/curl-8.10.1.tar.gz"

[ -d "$TREE" ] || tar xzf "$TARBALL"
for d in zlib-1.3.1 openssl-3.0.15 curl-8.10.1; do
	[ -d "$d" ] || { case $d in zlib*) tar xzf zlib.tar.gz;; openssl*) tar xzf openssl.tar.gz;; *) tar xzf curl.tar.gz;; esac; }
done

# ------------------------------------------------------------------ deps
echo "== zlib =="
if [ ! -f "$STAGE/lib/libz.a" ]; then
	cd "$WORK/src/zlib-1.3.1"
	CC=$TC-gcc AR=$TC-ar RANLIB=$TC-ranlib CFLAGS="$ARCHFLAGS -fPIC" \
		./configure --prefix="$STAGE" --static >/tmp/pw3-zlib.log 2>&1
	make -j"$JOBS" >/tmp/pw3-zlib.log 2>&1
	make install >/tmp/pw3-zlib.log 2>&1
fi

echo "== openssl (static, no tests) =="
if [ ! -f "$STAGE/lib/libcrypto.a" ]; then
	cd "$WORK/src/openssl-3.0.15"
	./Configure linux-armv4 --prefix="$STAGE" --openssldir="$STAGE/ssl" \
		--cross-compile-prefix="$TC-" no-shared no-tests \
		CFLAGS="$ARCHFLAGS -fPIC" >/tmp/pw3-ossl.log 2>&1
	make -j"$JOBS" >/tmp/pw3-ossl.log 2>&1
	make install_sw >/tmp/pw3-ossl.log 2>&1
fi

echo "== curl (static, HTTP/HTTPS only) =="
if [ ! -f "$STAGE/lib/libcurl.a" ]; then
	cd "$WORK/src/curl-8.10.1"
	CC=$TC-gcc AR=$TC-ar RANLIB=$TC-ranlib CFLAGS="$ARCHFLAGS -fPIC" \
	./configure --host="$TC" --prefix="$STAGE" \
		--with-openssl="$STAGE" --with-zlib="$STAGE" \
		--disable-shared --enable-static \
		--without-libpsl --without-libidn2 --without-brotli --without-zstd \
		--disable-ldap --disable-ftp --disable-file --disable-dict --disable-telnet \
		--disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher \
		--disable-mqtt --disable-rtsp --disable-smb --disable-manual \
		--disable-threaded-resolver >/tmp/pw3-curl.log 2>&1
	make -j"$JOBS" >/tmp/pw3-curl.log 2>&1
	make install >/tmp/pw3-curl.log 2>&1
fi

# ------------------------------------------------------------- NetSurf
echo "== apply frontend + PW3 build tweaks =="
grep -rl -- '-Werror' --include='Makefile*' "$TREE" 2>/dev/null | while read -r f; do
	sed -i 's/-Werror//g' "$f"
done
sh "$HERE/apply-frontend.sh" "$TREE" >/dev/null
# libdom's expat binding is only needed for XML/SVG; disable to avoid the dep.
sed -i 's/WITH_EXPAT_BINDING := yes/WITH_EXPAT_BINDING := no/' "$TREE/libdom/Makefile.config" 2>/dev/null || true
# libsvgtiny forces the XML binding and is not used by this frontend.
sed -i 's/^NSLIB_SVGTINY_TARG := libsvgtiny/NSLIB_SVGTINY_TARG :=/' "$TREE/Makefile"
# Static link (self-contained binary for the device and for qemu testing).
cat > "$TREE/netsurf/Makefile.config" <<EOF
LDFLAGS += -static -static-libgcc
EOF
grep -q 'static pthread after archives' "$TREE/netsurf/Makefile" || \
	printf '\n# static pthread after archives\nLDFLAGS += -lpthread -ldl -lrt\n' >> "$TREE/netsurf/Makefile"

echo "== cross-build NetSurf =="
export CC=$TC-gcc CXX=$TC-g++ AR=$TC-ar
export BUILD=x86_64-linux-gnu HOST=$TC
export CFLAGS="$ARCHFLAGS -fcommon"
export CXXFLAGS="$CFLAGS"
# host tool (split-messages) needs host zlib headers
cd "$TREE"
make TARGET=monkey \
	NETSURF_USE_DUKTAPE=NO NETSURF_USE_WEBP=NO NETSURF_USE_JPEGXL=NO \
	NETSURF_USE_PNG=NO NETSURF_USE_JPEG=NO NETSURF_USE_BMP=NO NETSURF_USE_GIF=NO \
	NETSURF_USE_CURL=YES NETSURF_USE_OPENSSL=YES NETSURF_USE_NSPSL=NO NETSURF_USE_NSSVG=NO \
	-j"$JOBS" >/tmp/pw3-netsurf.log 2>&1 || { tail -30 /tmp/pw3-netsurf.log; exit 1; }

cp "$TREE/netsurf/netsurf_render" "$OUT/netsurf_render"
"$TCBIN/$TC-strip" "$OUT/netsurf_render" 2>/dev/null || true
echo "== built $OUT/netsurf_render =="
ls -l "$OUT/netsurf_render"
file "$OUT/netsurf_render" 2>/dev/null || true
