# Goodreads KO Sync

Sync your KOReader reading progress with Goodreads.

### Support the project

If Goodreads KO Sync is useful to you, consider supporting its development:

**[Buy Me a Coffee](https://buymeacoffee.com/gkgangavarapu)**

Your support helps with development, maintenance, bug fixes, and keeping the plugin working as Goodreads changes.

A Community KOReader plugin. Install it from **KOReader Storefront** or manually from [Releases](https://github.com/gkgangavarapu/goodreadskosync/releases).

## Screenshots

| Reading Challenge | Main menu |
| --- | --- |
| <img src="docs/screenshots/10-reading-challenge.png" width="380"> | <img src="docs/screenshots/02-main-menu.png" width="380"> |

<details>
<summary><b>More screenshots</b></summary>

| Reading stats | Set status on Goodreads |
| --- | --- |
| <img src="docs/screenshots/11-reading-stats.png" width="380"> | <img src="docs/screenshots/03-set-status.png" width="380"> |

| This book | Rate a book |
| --- | --- |
| <img src="docs/screenshots/04-this-book-menu.png" width="380"> | <img src="docs/screenshots/05-rate-book.png" width="380"> |

| Signed in on-device | Sync presets |
| --- | --- |
| <img src="docs/screenshots/01-login-success.png" width="380"> | <img src="docs/screenshots/06-sync-presets.png" width="380"> |

| After a sync | Connection check |
| --- | --- |
| <img src="docs/screenshots/07-sync-toast.png" width="380"> | <img src="docs/screenshots/08-connection-ok.png" width="380"> |

| Reading menu | Support the project |
| --- | --- |
| <img src="docs/screenshots/09-reading-menu.png" width="380"> | <img src="docs/screenshots/12-support.png" width="380"> |

</details>

## Features

- **Sign in on-device** — Log in to Goodreads directly from KOReader.
- **Automatic sync** — Sync reading progress and Goodreads shelves in the background.
- **Offline support** — Save changes offline and sync when you reconnect.
- **Shelf management** — Manage Currently Reading, Read, Want to Read, Did Not Finish, and custom shelves.
- **Automatic book matching** — Find and link books to Goodreads automatically, or find them manually by title, author, ISBN, or Goodreads ID.
- **Ratings** — Optionally sync star ratings.
- **Notes to Goodreads** — Save a note offline and it posts automatically when you reconnect.
- **Reading Challenge** — See your annual goal, books read, percentage, days left, and whether you're ahead of or behind schedule.
- **Change reading goal** — Set or update your annual goal from the device.
- **Reading stats** — A year-by-year list of how many books you've finished.
- **Sync presets** — Fastest, Faster, Medium, or Relaxed, to balance freshness against battery use.
- **Manual controls** — Sync now (works with or without a book open), change status, rate books, and find books on Goodreads.
- **Diagnostic logging** — Optional, off by default, for troubleshooting.
- **OTA updates** — Download and install plugin updates directly from KOReader.
- **No telemetry** — No analytics or tracking.

## Installation

### KOReader Storefront

Install **Storefront** on your device and install **Goodreads KO Sync** from its catalogue.

### Manual

1. Download the latest release.
2. Unzip it.
3. Copy `goodreadskosync.koplugin` to your KOReader `plugins` directory.
4. Restart KOReader.
5. Open **Tools → Goodreads KO Sync → More → Account → Log in**.

### Plugin directory

- **Kindle:** `/mnt/us/koreader/plugins/`
- **Kobo:** `.adds/koreader/plugins/`
- **Android:** `/sdcard/koreader/plugins/`
- **Linux / macOS:** `~/.config/koreader/plugins/`

Kindle is tested. Other platforms may work but are less tested.

## Support & Feedback

Found a bug or have a feature request?

**[Open an issue on GitHub](https://github.com/gkgangavarapu/goodreadskosync/issues)**.

If you enjoy using the plugin, the best way to support continued development is:

**[Buy Me a Coffee](https://buymeacoffee.com/gkgangavarapu)**

## Important

- Goodreads sign-in may occasionally require a few attempts.
- Goodreads does not provide a public API. The plugin uses Goodreads web endpoints, which may change without notice.
- Your credentials and session remain on your device.
- This is an unofficial community project and is not affiliated with Goodreads, Amazon, or KOReader.

## License

MIT — see [LICENSE](LICENSE).
