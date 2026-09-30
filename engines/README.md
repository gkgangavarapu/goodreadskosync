# Browser engines — architecture, targets, compatibility matrix

## Architecture (final)

```
+--------------------------------------------------------------+
| Browser UI         (platform-independent)  KOReader widgets   |
|   address bar, back/forward/reload/home, scroll, tap, type    |
+--------------------------------------------------------------+
| Browser Host       (platform-independent)                     |
|   engine selection by capability, viewport, session/cookies,  |
|   history, cache; never switches engines automatically        |
+--------------------------------------------------------------+
| BrowserEngine      (stable contract; engine-agnostic)         |
|   load/render/tap/scroll/back/forward/reload/title/url/caps   |
+--------------------------------------------------------------+
| platform engine implementations                               |
|   NetSurf (offscreen native helper)  |  CRE (KOReader reader) |
+--------------------------------------------------------------+
| Platform layer     (filesystem/process/display only)          |
|   KOReader abstractions; no /dev/fb0 in engines               |
+--------------------------------------------------------------+

Goodreads integration (shelves, ratings, progress, notes, metadata)
lives OUTSIDE the browser entirely and never depends on rendering.
```

- The engine returns an **offscreen grayscale bitmap + dimensions + scroll
  state + hitmap**. KOReader owns display and e-ink refresh.
- No device dimensions are hard-coded: the Host builds a viewport
  (`Host.viewport(w, h, {dpi, scale})`) and passes it to `engine:load()`.
- All OS access is funnelled through `browser/platform.lua`; engines receive a
  platform object, so they carry no platform assumptions.

## Engine capability matrix

`capabilities()` is structured (see `Engine.DEFAULT_CAPABILITIES`).

| capability | CRE (fallback) | NetSurf |
|---|---|---|
| html | 4 | 4 |
| css | partial | 2.1 |
| js | no | no (by design, for now) |
| images (raster) | yes | yes (png/jpeg/gif/bmp) |
| forms | limited | yes |
| https | yes | yes |
| cookies | yes | yes |
| navigation | yes | yes |
| scrolling | yes | yes |
| hitmap | no | yes |

`Host.choose(candidates, required)` selects the most capable engine that meets a
dotted requirement list and is available; `Host.resolve()` still honours the
user's setting with CRE as fallback.

## Platform / target build matrix

| platform | devices | CPU | float ABI | libc | graphics | KOXToolchain preset | engine |
|---|---|---|---|---|---|---|---|
| Linux | desktop | x86_64 / arm64 | hard | glibc/musl | SDL/framebuffer | (native) | NetSurf |
| Kindle (PW2+/PW3) | PW2, PW3, K4, Touch | armv7-A A9 | **softfp** | glibc ≤2.12 | Kindle EPDC | `kindlepw2` | NetSurf (first target) |
| Kindle (FW ≥5.16.3) | KOA, PW4/5, Scribe | armv7-A A9 | hard | glibc 2.20 | Kindle EPDC | `kindlehf` | NetSurf |
| Kobo | Touch, Aura, Libra | armv7-A A8/A9 | hard | glibc | Kobo fbink | `kobo` / `kobov4` | NetSurf |
| Kobo (FW 5.x) | Sage, Elipsa | armv7-A A53 | hard | glibc 2.35 | Kobo fbink | `kobov5` | NetSurf |
| PocketBook | Touch HD, Era | armv7-A A8 | softfp | glibc ≤2.9 | inkview | `pocketbook` | NetSurf |
| reMarkable | rM1/rM2 | armv7-A A9 | hard | glibc | e-ink | `remarkable` | NetSurf |
| Android | phones | armv7/arm64/x86_64 | softfp (arm) | bionic | NDK surface | (NDK) | NetSurf or platform WebView (future) |

### Build per target

```sh
# one toolchain per triplet, from koreader/koxtoolchain releases
KOX_ROOT=/path/to/x-tools ./build-target.sh kindlepw2   # PW3 etc. (first target)
KOX_ROOT=/path/to/x-tools ./build-target.sh kindlehf
KOX_ROOT=/path/to/x-tools ./build-target.sh kobo
KOX_ROOT=/path/to/x-tools ./build-target.sh kobov5
KOX_ROOT=/path/to/x-tools ./build-target.sh pocketbook
KOX_ROOT=/path/to/x-tools ./build-target.sh remarkable
./build-target.sh linux                                  # native (needs no KOX_ROOT)
```

Each target sets `CHOST`/`ARCH_CFLAGS`/`TARGET_NAME` and produces
`out/<target>/netsurf_render`. The PW3 config is just one entry — it is **not**
the global configuration.

NetSurf itself is built separately per target (points 35–38). The frontend
source (`frontend/`) is portable; only the toolchain and dependency build
differ. Cross-compiled deps per target: zlib, OpenSSL, libcurl (and optionally
libpng/libjpeg for images).

## What is platform-specific

| concern | where it lives |
|---|---|
| engine process/IO | `browser/platform.lua` |
| engine selection, viewport | `browser/host.lua` |
| UI widgets | `browser/ui/` (KOReader) |
| NetSurf native helper | `engines/netsurf/` (per target) |
| Goodreads shelf/rating/progress/metadata | plugin sync layer (never the engine) |

## Status

- Linux x86_64 NetSurf renderer: working.
- PW3 (`kindlepw2`) cross build: produces a correct static ARMv7 soft-float
  binary; on-device runtime not yet verified.
- Other targets: build configs defined; not built/tested yet.
