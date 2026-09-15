# goodreadskosync

Keep your KOReader reading in sync with Goodreads.

An unofficial, community KOReader plugin. Install it from **KOReader Storefront**
or manually from [Releases](https://github.com/gkgangavarapu/goodreadskosync/releases).

## Notes

- Sign-in can occasionally take a few tries; if it
  fails, wait a little and try again. Once signed in, the session is kept.

## Features

- **Sign in on-device** — log in to Goodreads from KOReader itself, with an
  on-device prompt if the site asks for extra verification, and automatic retries
  when the connection is flaky.
- **Over-the-air (OTA) updates:** checks GitHub Releases about once a day and can
  download, verify (SHA-256), install, and restart for you on request — no cable
  or manual copying needed.
- Automatically updates your shelves: **Currently Reading** and **Read**. Manual
  **Set status on Goodreads** can move a book to any shelf (Want to Read,
  Currently Reading, Read, Did Not Finish); automatic sync never downgrades a
  finished book.
- Syncs reading progress as you read, or on open/close, according to your chosen preset.
- Marks a book Read when you finish it (configurable), and offers a rating.
- Optional star ratings.
- Links a book to the best Goodreads match automatically, or lets you pick the right one.
- Manual controls: **Sync now**, **Set status**, **Rate this book**, **Find on Goodreads**.
- Reads your Goodreads shelf and never overwrites a book you have marked Read.
- Works offline and syncs when you reconnect; background sync never blocks reading.
- **Sync presets** (Fastest / Faster / Medium / Relaxed) and Wi‑Fi handled the
  KOReader way, so it never fights your device settings.
- Small, non-intrusive notifications.
- No analytics and no telemetry.

## Syncing

Syncs run in the background and never interrupt reading. Pick one preset
(**Settings → Sync preset**) — it sets all the sync behaviour for you:

| Preset | Reading progress | Regular check |
|---|---|---|
| **Medium** (default) | on open/close | every 15 minutes |
| Fastest | as you read (every 2%) | every 2 minutes |
| Faster | as you read (every 5%) | every 5 minutes |
| Relaxed | on open/close | never |

Every preset also syncs on these events — the preset only changes the in‑reading
updates above:

| Trigger | Fastest | Faster | Medium | Relaxed |
|---|---|---|---|---|
| Open / close | yes | yes | yes | yes |
| Sleep / wake / reconnect | yes | yes | yes | yes |
| Status change, new link, sign‑in, **Sync now** | yes | yes | yes | yes |

- Automatic syncs never switch Wi-Fi on; they run when you are already online
  and otherwise wait for the next connection. **Sync now** will prompt to turn
  Wi-Fi on if it is needed.
- A sync fetches your latest shelf on book open, on manual sync, or about once
  an hour; otherwise it reuses the last result, so routine syncs stay quick.
- Offline changes are saved and sent automatically when you reconnect; the open
  book's progress is pushed as soon as you are back online.
- A new book opened while offline is linked automatically once you are back
  online (when **Link books automatically** is on).
- Opening a book does not change its shelf until there is progress.
- When you finish a book it is marked **Read**.
- Newly linked books are added to **Currently Reading** by default (turn this off in Settings).
- Small toasts keep you informed while staying out of the way (linking, offline
  saves/flushes, Currently Reading, and sync failures).

## Browse shelves

**Browse shelves** (in the plugin menu) opens a box that stays open until you
close it. It opens instantly with the books the plugin has linked, then
**Load from Goodreads** fetches your shelf list — including custom shelves — with
counts. From there you can:

- open a shelf and see its books,
- **move a book** to another shelf,
- **Search & add** a book and choose its shelf,
- **Support this project** (with the QR).

Each shelf's books are fetched on demand, in a single small request.

## Download

Get the latest `goodreadskosync-<version>.zip` from the [Releases](https://github.com/gkgangavarapu/goodreadskosync/releases) page, or install it from **KOReader Storefront**.

## Installation

### From KOReader Storefront

Install **Storefront** on your device, then install **Goodreads Sync (unofficial)**
from its catalogue.

### Manually

1. Unzip the download and copy the `goodreadskosync.koplugin` folder into your KOReader `plugins` directory:
   - Kindle: `/mnt/us/koreader/plugins/` - Tested
   - Kobo: `.adds/koreader/plugins/`     - Untested
   - Android: `/sdcard/koreader/plugins/`- Untested
   - Linux / macOS: `~/.config/koreader/plugins/`- Untested
2. Restart KOReader.
3. Open **Tools → Goodreads Sync (unofficial) → Account → Log in**.

## Disclaimer

- This is an **unofficial, community project**. It is **not affiliated with, endorsed by, or sponsored by Goodreads, Amazon, or KOReader**.
- Goodreads has no public API. This plugin communicates with Goodreads' web endpoints, which are undocumented and may change or stop working at any time, with or without notice.
- **No warranty.** The software is provided "as is", without warranty of any kind, express or implied. Use it at your own risk. The authors are not liable for any loss, damage, or consequences arising from its use.
- Use it responsibly and in accordance with the terms of service of Goodreads and Amazon. You are responsible for how you use this software.
- Your credentials and session stay on your device. Nothing is sent anywhere except to Goodreads.
- Goodreads and Amazon are trademarks of their respective owners.

## Feedback and feature requests

Have an idea or want to request a feature? Post it in the
[issues](https://github.com/gkgangavarapu/goodreadskosync/issues/2).

## Support

If you find this plugin useful and want to support its continued development, you can [Buy Me a Coffee](https://buymeacoffee.com/gkgangavarapu).

## License

MIT — see [LICENSE](LICENSE).
