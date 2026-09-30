# NetSurf engine — real offscreen renderer

This is the **second local browser engine** for the plugin's `BrowserEngine`
contract. It links NetSurf's actual HTML parser, CSS engine, layout engine and
image decoders, renders into an **in-memory** pixel buffer, and writes:

- `frame.pgm` — 8-bit grayscale P5, exactly `width × height` bytes
- `frame.json` — title, url, dimensions, scroll height, and the hitmap

It never touches `/dev/fb0` and does not use NetSurf's framebuffer frontend.

## How it works

NetSurf has no embeddable library API, so the renderer is a small custom
frontend built **from NetSurf's core object files** (the same way NetSurf's own
frontends are built). It started from NetSurf's minimal headless `monkey`
frontend and replaces its text plotter with a memory rasteriser:

| file | role |
|---|---|
| `frontend/plot.c` | plotter that rasterises rectangles, lines, polygons, text (embedded 8×8 font) and images into a 32bpp ARGB buffer |
| `frontend/bitmap.c` | 32bpp image bitmaps + accessors |
| `frontend/render.c` | one-shot driver: load URL → event loop → redraw → PGM + hitmap |
| `frontend/render.h` | shared declarations |
| `frontend/font8x8_basic.h` | public-domain 8×8 font |

`apply-frontend.sh` copies these over a NetSurf source tree's `monkey` frontend
and patches it (viewport size, one-shot mode, `EXETARGET := netsurf_render`).
The hitmap is built by walking NetSurf's real HTML **box tree**
(`html_get_box_tree` + `struct box::href`).

## Protocol

```
netsurf_render --url URL --width W --height H --scroll Y --out PREFIX [--cookies FILE]
```

Exits `0` on success, non-zero with a reason on stderr otherwise. Writes
`PREFIX.pgm` and `PREFIX.json`.

`--cookies` is a Netscape-format cookie file (NetSurf's native jar). The Lua
adapter (`goodreadskosync/browser/engines/netsurf.lua`) writes this format.

## Build

Alpine (matches the environment this was developed and tested in):

```sh
./build-dev.sh          # installs deps, downloads source-full, builds
# -> ./out/netsurf_render
```

Any distro, given the dependencies in the `Dockerfile`:

```sh
./build-dev.sh
```

Container:

```sh
docker build -t netsurf-render .
docker run --rm -v "$PWD/out:/out" netsurf-render
```

`build-dev.sh` downloads NetSurf's `source-full-3.11` bundle (NetSurf + all its
libraries) and builds `TARGET=monkey`. It applies `apply-frontend.sh` and
rebuilds the frontend as `netsurf_render`.

## Cross-compile for the PW3

See `build-pw3.sh`. The NetSurf libraries must first be built for armv7 in a
cross sysroot; the renderer is software-only. PWM/device numbers are not yet
measured (no device in the build environment).

## Test results (x86_64 Alpine, NetSurf 3.11)

| input | result |
|---|---|
| `https://example.com/` | ✅ title, heading, paragraph; 1 link hit at (240,241) |
| `https://www.netsurf-browser.org/` | ✅ full layout, `scroll_h=4950`, ~60 link hits |
| `https://www.gnu.org/` | ✅ full layout, `scroll_h=6862`, ~57 link hits |
| `https://www.goodreads.com/book/show/…` | ✅ title, `scroll_h=17013`, cover image drawn, link hits |
| `https://www.gnu.org/graphics/gnu-head-sm.jpg` | ✅ image content rendered (129×122 JPEG) |
| Goodreads authenticated pages | ⚠️ cookie plumbing works, but the saved session was **expired**, so Goodreads redirected to sign-in |
| `https://www.goodreads.com/` (home) | ⚠️ blank: Goodreads' home is JS/app-driven with no server-rendered body |

### Known limitations

- **No JavaScript.** Goodreads' JS-only pages (review editor, home feed) are
  blank or incomplete. `capabilities().js` is `false`.
- CSS support is NetSurf's (CSS 2.1 era): floats and simple layouts look fine,
  modern flex/grid does not.
- `frame.json` hit rectangles come from inline link boxes; nested/absolute
  positioning may be approximate.
- PW3 (armv7, 512 MB, no GPU) is **not tested** here — only x86_64 Alpine.
