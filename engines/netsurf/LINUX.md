# Running the NetSurf backend on Linux (KOReader)

This documents the exact requirements and the helper protocol/lifecycle for the
Linux desktop integration (`KOReader -> Browser UI -> Browser Host ->
NetSurfEngine -> netsurf_render -> bitmap/hitmap -> KOReader display`).

## Requirements

- **KOReader Linux x86_64** (tested: v2026.07.1). The desktop AppImage bundles
  SDL3 and all runtime libs; extract it if FUSE is unavailable.
- A **glibc** userland (the helper is a normal glibc binary; KOReader desktop is
  glibc too). Alpine/musl cannot run either directly.
- **NetSurf helper** `netsurf_render` for the *same* platform (x86_64 glibc for
  desktop). Build it with `build-dev.sh` on a glibc host (or `/build-target.sh linux`).
- NetSurf **resources**: the `netsurf/resources/` directory (Messages,
  mime.types, `ca-bundle`, `default.css`). Point `NETSURFRES` at it.
- **CA bundle** for HTTPS: either the NetSurf `resources/ca-bundle` (set
  `CURL_CA_BUNDLE` / `SSL_CERT_FILE`) or the system bundle.
- Run KOReader headlessly with `SDL_VIDEODRIVER=offscreen`,
  `SDL_AUDIODRIVER=dummy`, `SDL_RENDER_DRIVER=software`.

### Environment used to point the plugin at the helper

| variable | meaning |
|---|---|
| `GRK_NETSURF_BIN` | path to `netsurf_render` (overrides the setting) |
| `NETSURFRES` | NetSurf resources dir |
| `CURL_CA_BUNDLE` / `SSL_CERT_FILE` | CA bundle for HTTPS |
| `GRK_GR_COOKIES` | raw `Cookie:` header for authenticated requests |
| `GRK_NETSURF_SELFTEST=1` | run the headless self-test and exit |
| `GRK_NETSURF_URL` | URL for the self-test |
| `GRK_NETSURF_OUT` | output dir for `netsurf-selftest.pgm` |

There is also a user setting `browser_netsurf_bin` and the dev menu entry
`More -> Browser engine (dev) -> Open NetSurf browser (dev)`.

## Helper protocol

```
netsurf_render --url URL --width W --height H --scroll Y --out PREFIX [--cookies FILE]
```

- Invoked through `browser/platform.lua` (process + file I/O), never directly
  from the engine contract.
- Writes `PREFIX.pgm` (P5, 8-bit grayscale, W×H bytes) and `PREFIX.json`
  (`url`, `title`, `width`, `height`, `scroll_h`, `scroll_y`, `hits[]`).
- The adapter reads both through the platform, parses the PGM and JSON, and
  returns `{ bitmap, width, height, scroll_y, scroll_h, hits }` from `render()`.
- `--cookies` is a Netscape cookie file; the adapter writes it from a Cookie
  header.

## Lifecycle

1. `NetSurfBrowser:new{ ctx = { engine_name = "netsurf", bin, cookie_file, platform } }`
2. `Browser Host` (`Host.create_engine`) verifies the helper exists and builds
   the engine; viewport comes from `Host.viewport(screen:getWidth(),
   screen:getHeight(), { dpi, scale })`.
3. `view:load(url, cookie_header)` -> engine `load()` -> platform runs the
   helper -> engine `render()` -> UI builds a KOReader **BB8** (memcpy of the
   grayscale bytes) and paints it.
4. Tap -> hitmap lookup -> engine `tap()` -> if a link, re-`load()`; the UI
   refreshes. Swipe -> engine `scroll()` -> re-render at the new offset.
5. Back/Forward/Reload are engine operations over its history.

Each engine call runs one short-lived helper process; nothing persists on the
device, and browsing never opens a document, so no books/`.sdr`/mappings are
created and sync cannot be triggered.

## Measured on this Linux setup (x86_64, SDL offscreen)

| page | render wall time | peak RSS (helper) |
|---|---|---|
| example.com | ~0.16 s | ~20 MB |
| gnu.org (CSS-heavy) | ~0.4 s | ~30 MB |
| netsurf-browser.org (images) | ~0.5 s | ~35 MB |
| Goodreads book page (many fonts/images) | **~25 s** | **~139 MB** |

The Goodreads page is heavy because it pulls many web fonts and images; on the
PW3 (512 MB, single Cortex-A9) this is the main performance/size risk.
