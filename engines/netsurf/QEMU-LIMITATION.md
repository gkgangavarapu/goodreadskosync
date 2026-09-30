# PW3 / runtime findings (supersedes the earlier "QEMU limitation" note)

## CORRECTION — this is a REAL bug, not a QEMU artifact

The earlier conclusion ("qemu cannot faithfully reproduce the static binary's
fetch failure") was **wrong**. Running the same static ARM helper on the
**physical PW3** reproduces the failure exactly:

```
# on the real Kindle (armv7l, Linux 3.0.35)
$ ./netsurf_render --url data:text/html,<h1>hi</h1> --out /tmp/a
rc=134
json: {"url":"about:query/fetcherror","title":"FetchErrorTitle", ...}
# stderr: *** glibc detected *** ./netsurf_render: double free or corruption (!prev): 0x0056c2c8 ***
```

So qemu was in fact a faithful proxy. The defect is in our ARM build/run.

## What we know (from the device)

- The helper **executes** and writes a valid `frame.pgm` (480015 bytes) and
  `frame.json` for the (error) page, then exits 134.
- **Every** scheme fails to fetch: `about:blank`, `data:`, `file:`, `http:`,
  `https:` all yield `about:query/fetcherror`. Non-network schemes failing rules
  out DNS/TLS/CA/cookies/filesystem permissions.
- The abort is a **heap corruption**: `double free or corruption (!prev)`.
- `/proc/cpu/alignment` did not matter (setting it to fixup `2` did not help),
  so unaligned access is **not** the cause.
- With `MALLOC_CHECK_=0`, `data:` no longer aborts (exit 0) but *still* returns
  `about:query/fetcherror` — so the fetch failure and the double free are
  independent symptoms of an underlying memory/build problem.

## QEMU status

- Dynamic `kindlepw2` (glibc 2.12) binaries still **cannot** be executed under
  the available qemu-user (loader segfault) — that part stands.
- The **static** ARM binary's behaviour under qemu matched the device, so qemu is
  usable for iterating on this bug (faster than re-flashing).

## Next: root-cause the ARM memory bug

Targeted steps (in order):
1. Rebuild the ARM helper with NetSurf debug logging enabled to see whether the
   fetchers register (`fetch_init`) and where the first bad free occurs.
2. Add a `SIGABRT` backtrace (monkey already has a backtrace handler for
   SIGSEGV/ILL/FPE/BUS) so the `double free` call stack can be symbolised.
3. Bisect build flags most likely to differ from the working x86_64 build and to
   be ARM-hostile: `-fsigned-char` (ARM `char` is unsigned by default),
   `-fno-common`, `-mno-unaligned-access`, `-mfpu=vfpv3`/`-marm` (drop
   NEON/Thumb), and `-O1`.
4. Confirm with a local non-network case (`data:`, `file:`) before retesting
   HTTPS.

The helper's post-output abort is already tolerated by the engine (it consumes a
complete `frame.pgm`/`frame.json` even on a non-zero exit), so once fetching /
rendering is correct the integration will still work.
