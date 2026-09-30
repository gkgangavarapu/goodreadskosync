# PW3 (Kindle Paperwhite 3) toolchain & target notes

## Target ABI (verified, not assumed)

Determined from KOReader's `koreader-base/Makefile.defs` and its toolchain
matrix, then confirmed with a compiled binary:

| property | value |
|---|---|
| device | Kindle Paperwhite 3 (2015), i.MX6SL |
| CPU | ARMv7-A, Cortex-A9, NEON (VFPv3) |
| ABI | `arm-kindlepw2-linux-gnueabi` — **soft-float** (`-mfloat-abi=softfp`) |
| ELF | `ELF 32-bit LSB, ARM, EABI5`, flag `0x5000200` (Version5 EABI, soft-float ABI) |
| libc | **glibc**, max **2.12** (toolchain ships `ld-2.12.2.so`) |
| dynamic loader | `/lib/ld-linux.so.3` |
| KOReader target | `kindlepw2` ("Kindle PW2 & everything since") |

KOReader's newer `kindlehf` toolchain (hard-float, glibc 2.20, FW ≥ 5.16.3) does
**not** apply to the PW3.

## Toolchain

Use the KOReader KOXToolchain release — do not build one from scratch:

- repo: https://github.com/koreader/koxtoolchain
- release asset: `kindlepw2.tar.gz` / `.tar.zst`
  (e.g. `https://github.com/koreader/koxtoolchain/releases/download/2025.05/kindlepw2.tar.gz`)
- extracts to `x-tools/arm-kindlepw2-linux-gnueabi/` (GCC 14.2.0, binutils, glibc 2.12 sysroot)

## Host requirement: a glibc userland

The toolchain's host programs are **glibc-dynamic x86_64** executables
(`interpreter /lib64/ld-linux-x86-64.so.2`). They do **not** run on musl
(Alpine) — `__*_chk` symbols are missing. Run the build on a glibc host, e.g. a
Debian chroot:

```sh
# once: fetch a debian rootfs and chroot into it (needs root)
#   (the repo used debian:bookworm-slim rootfs extracted from the Docker registry)
mount --bind /proc $ROOT/proc ; mount --bind /sys $ROOT/sys ; mount --bind /dev $ROOT/dev
chroot $ROOT bash
apt-get update && apt-get install -y build-essential bison flex gperf pkg-config \
    perl ca-certificates wget file zlib1g-dev
```

Then run:

```sh
KOX_TC=/path/to/x-tools/arm-kindlepw2-linux-gnueabi ./engines/netsurf/build-pw3.sh
```

## Target libraries (all cross-compiled by build-pw3.sh)

NetSurf's own libraries are bundled in the `source-full` tarball and built with
the cross compiler. External libraries cross-built from source (never host libs):

| library | why |
|---|---|
| zlib 1.3.1 | NetSurf links `-lz` unconditionally |
| OpenSSL 3.0.15 | TLS for libcurl |
| libcurl 8.10.1 | HTTP/HTTPS fetcher (built static, HTTP/HTTPS only) |

Disabled to shrink the surface: JS/Duktape, WebP, JPEG XL, libnspsl, SVG
(`libsvgtiny`), and libdom's expat XML binding.

Images (PNG/JPEG) are **not** in this first PW3 build; add zlib+libpng/libjpeg
and set `NETSURF_USE_PNG=YES NETSURF_USE_JPEG=YES`.

## Output

`engines/netsurf/out/pw3/netsurf_render` — statically linked ARMv7 executable
(no `DT_NEEDED`), ~12 MB stripped. It writes the same `frame.pgm` + `frame.json`
as the host build; no `/dev/fb0` access; no JS.

At runtime NetSurf needs its `resources/` directory (Messages, mime.types,
ca-bundle, default.css). Either run from the build's `netsurf/` dir or set
`NETSURFRES=<dir with resources>`. On the device, ship `resources/` next to the
binary and set `NETSURFRES`.

## Status

- ✅ toolchain identified and validated (hello-world: correct arch/ABI)
- ✅ NetSurf 3.11 + zlib/OpenSSL/curl cross-compiled to a static ARM binary
- ✅ the ARM binary executes under `qemu-arm` and emits `frame.pgm`/`frame.json`
- ⚠️ **PW3 runtime not yet verified**: no device here; under `qemu-arm` the fetch
  path needs the resource dir + CA bundle wired correctly, and old-glibc DNS is
  a known soft spot. This is the next thing to nail down on-device.
