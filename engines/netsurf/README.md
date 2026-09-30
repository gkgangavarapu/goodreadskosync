# NetSurf engine (PW3) — build kit

This is the **second local browser engine** for the plugin's `BrowserEngine`
contract. It is *not* NetSurf's framebuffer frontend and it **never touches
`/dev/fb0`**: it renders into an **libnsfb memory surface**, then writes:

- `frame.pgm` — 8-bit grayscale P5, exactly `width × height` bytes
- `frame.json` — title, url, dimensions, scroll height, and the hitmap

The Lua adapter `goodreadskosync/browser/engines/netsurf.lua` runs this helper
and exposes `load/render/tap/scroll/back/forward/reload/title/url/capabilities`.

The helper is **opt-in**. Until it is built and copied to the device, the plugin
keeps using its CRE fallback engine.

## Protocol

```
netsurf_render --url URL --width W --height H --scroll Y --out PREFIX [--cookies FILE]
```

Always exits `0` on success. On failure exits non-zero and prints a reason to
stderr. Outputs `PREFIX.pgm` and `PREFIX.json`.

`frame.json`:

```json
{
  "url": "https://example.com/",
  "title": "Example Domain",
  "width": 600, "height": 800,
  "scroll_h": 1024, "scroll_y": 0,
  "hits": [
    { "x": 12, "y": 40, "w": 180, "h": 22, "href": "https://example.com/more" }
  ]
}
```

## Build on the development machine (x86_64)

```sh
cd engines/netsurf
docker build -t netsurf-render .
docker run --rm -v "$PWD/out:/out" netsurf-render
# -> out/netsurf_render
```

Or natively, after installing the NetSurf dependencies (see Dockerfile):

```sh
./build-dev.sh          # builds ./out/netsurf_render
./out/netsurf_render --url https://example.com --width 600 --height 800 --out /tmp/example
```

Then check the smoke test:

```sh
./smoke.sh              # runs example.com through the helper
```

## Cross-compile for the Kindle PW3

The PW3 is an ARMv7 (Cortex-A9, hard-float) device with a glibc-based Kindle
Linux and **no GPU**. Point the script at your toolchain sysroot:

```sh
CROSS=arm-kindle-linux-gnueabi- \
SYSROOT=/path/to/pw3-sysroot \
./build-pw3.sh
```

The result is statically biased toward software rendering (no EGL/GBM/DRM).
Copy `netsurf_render` plus its shared deps to the device, e.g.
`/mnt/us/koreader/goodreadskosync/bin/netsurf_render`, and point the plugin's
setting `browser_netsurf_bin` at it.

## Status / honesty

This is a **spike**. The pieces here that are complete and self-contained:

- CLI + PGM writer + JSON hitmap writer (no external deps)
- libnsfb **memory** surface setup (safe: no framebuffer device)

The pieces that depend on the exact NetSurf source revision (its embedding API
is not stable, and `monkey`-style frontends are the only supported entry points)
are marked `NETSURF-INTEGRATION` in `netsurf_render.c`. Building against a
NetSurf checkout is expected to need small header/API adjustments — that work
must happen on the machine with the toolchain, not in this repo.
