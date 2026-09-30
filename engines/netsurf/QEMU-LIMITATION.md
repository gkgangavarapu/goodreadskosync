# QEMU limitation for PW3 runtime validation

This documents why `qemu-user` is **not currently a valid proxy** for validating
the PW3 NetSurf runtime, and what was observed. It isolates emulator limitations
from genuine runtime bugs.

## Environment

- Toolchain: KOReader `kindlepw2` (armv7-a, Cortex-A9, NEON, EABI5, soft-float,
  **glibc 2.12**, `ld-2.12.2.so`).
- Emulators tried: Alpine `qemu-arm` and Debian `qemu-arm-static` (qemu 7.2.22).

## Finding 1 — dynamic glibc 2.12 binaries don't run

Any *dynamically linked* binary from the `kindlepw2` toolchain crashes
immediately under qemu-user:

```
$ qemu-arm-static -L <sysroot> ./hello        # dynamic ARM hello
qemu: uncaught target signal 11 (Segmentation fault)
```

The same program built **static** runs fine (`hello from armv7`). The crash is in
emulating the glibc 2.12 dynamic loader, not in the program. Consequence: only
the **static** ARM helper can be exercised under qemu at all.

## Finding 2 — the static ARM helper runs, but NetSurf fetch fails uniformly

The static ARM `netsurf_render` executes and writes a well-formed
`frame.pgm` + `frame.json`, but **every** request ends in NetSurf's
`about:query/fetcherror`, including schemes that need no network at all:

| URL | result |
|---|---|
| `about:blank` | fetch error |
| `data:text/html,<h1>Hi</h1>` | fetch error |
| `file:///…/t.html` (exists) | fetch error |
| `http://127.0.0.1:18080/t.html` | fetch error |
| `https://example.com/` | fetch error |

The process also **aborts (SIGABRT, exit 134) after writing the output files**.

Because the failure is uniform across non-network schemes, this is not DNS,
TLS, CA, cookies, curl configuration or filesystem permission — those would
affect only some schemes. It points at the emulator/static-glibc combination.

## Finding 3 — the identical frontend works natively

On x86_64 (native, no qemu) the same frontend and code path render
`file://` (including a PNG), `data:`, `https://example.com/`, images and the
Goodreads book page correctly, with a hitmap. So the frontend logic is sound;
what fails is the ARM-under-qemu runtime.

## Conclusion

QEMU-user is **not a valid proxy for PW3 fetch/runtime validation** with this
toolchain. The blocker requires **physical PW3 hardware** (or a qemu that can
faithfully run glibc 2.12). A quick low-cost sanity check (a static x86_64
control) is the only remaining cheap experiment; beyond that, device testing is
the correct next step.

## How this affected the implementation

1. The engine now consumes a **complete** `frame.pgm` + `frame.json` even when
   the helper exits non-zero (the post-output abort), recording `helper_exit` in
   the frame. It still reports a failure when no usable output exists.
2. `package-pw3.sh` produces a **self-contained** bundle (helper + resources +
   CA bundle + launcher with deterministic paths) for device testing.
3. The device smoke test is staged in the package `README.txt`.

## Device validation plan

Run the package's `run.sh` on the PW3 and record, per page (local HTML, local
image, example.com, a CSS-heavy site, the Goodreads book page):
exit status, title, URL, viewport, page height, hit count, render time, peak
RSS, and whether `frame.pgm`/`frame.json` are valid. That is the only way to
confirm real fetch behaviour.
