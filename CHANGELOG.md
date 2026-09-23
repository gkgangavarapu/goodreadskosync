# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.13.3] - 2026-09-23

Toasts are a bit bigger (same text size) and always say what happened, with the book name in two words — for example “No Longer… · Progress 40%”, “No Longer… · Linked”, “No Longer… · Note posted”, or “No Longer… · Rated 5 stars”.

## [1.13.2] - 2026-09-23

Toasts keep the normal text size but now wrap onto two lines with a little more padding, so they read as a bigger, easier-to-read toast.

## [1.13.1] - 2026-09-23

Toasts are back to the normal text size, and the book-matching list now lets you search by title, author, ISBN, or Goodreads ID when the automatic match isn't right.

## [1.13.0] - 2026-09-23

Toasts now show just the first two words of the book title. Linking books automatically is off by default (turn it on in Settings if you prefer). Change linked book now lets you type a title, author, ISBN, or Goodreads ID.

## [1.12.0] - 2026-09-18

### Changed

- Internal refactor for maintainability: a single reusable **Goodreads API**
  module, a dedicated **sync controller**, and shared **tasks / menu / notes**
  modules. No behaviour change.

## [1.11.5] - 2026-09-18

### Fixed

- Automatic syncs (open/close/reconnect) no longer abort when you tap the
  screen; the close/reconnect queue flush now runs to completion.
- Automatic open/reconnect syncs now show a toast when they send a queued item.
- **Sync now** works with no book open, and respects sticky Read / Did Not Finish.
- A fetched CSRF token is reused for a short window instead of refetching on
  every write.

### Changed

- **Notes to Goodreads** are saved offline and posted automatically when online.
- Toasts no longer prefix the plugin name; they show just the book/action detail.
- **Browse shelves** is hidden from the menu for now.

## [1.11.3] - 2026-09-16

### Fixed

- **Syncing works again (progress, shelf, rating, remove).** The plugin now
  fetches a fresh CSRF token before every write; Goodreads rotates the token, and
  a stale one made it reject writes with `404`.

## [1.11.2] - 2026-09-16

### Fixed

- **Reading progress syncs again.** The progress request now sends the CSRF token
  in the request body (Goodreads began rejecting the header-only request with a
  404), and always includes the status body field.

## [1.11.1] - 2026-09-16

### Fixed

- Diagnostic logs are now always written to `login.log` in the plugin's KOReader
  settings folder, so support knows exactly where to look.

## [1.11.0] - 2026-09-16

### Added

- **Diagnostic logging** option in Settings (off by default) that writes detailed
  sync logs to the plugin's `login.log` for troubleshooting.
- If a progress update is rejected because the book isn't on a Goodreads shelf,
  the plugin now re-adds it to **Currently Reading** and retries once.

### Changed

- Toasts are smaller and less intrusive.

## [1.10.1] - 2026-09-15

### Fixed

- Multiple reading updates with the same percent are no longer posted; a queued
  progress send now records success, so it isn't pushed again by the next sync.

## [1.10.0] - 2026-09-15

### Changed

- The plugin is now named **Goodreads KO Sync**.
- New installs default to the **Relaxed** sync preset; existing installs keep
  their chosen preset.

## [1.9.3] - 2026-09-15

### Changed

- Minor changes.

## [1.9.2] - 2026-09-15

### Fixed

- **Settings no longer crashes KOReader.**
- Reading progress is not pushed again when Goodreads already has that percent.
- The shelves browser now caches what it loaded, so it opens instantly and only
  re-fetches when you choose **Refresh from Goodreads**.

### Changed

- Shelf book lists show each book's **author**, with clear row separators.
- The update prompt now shows the **release notes** before downloading.

## [1.9.1] - 2026-09-15

### Fixed

- Opening a shelf could show **"No books"** when Goodreads served the shelf in
  its cover-grid layout. Shelves are now requested in the list (table) layout,
  so the books load reliably.

## [1.9.0] - 2026-09-15

### Added

- **Browse shelves:** open your Goodreads shelves — including custom shelves — in
  a single box that stays open until you close it. Open a shelf to see its books,
  **move books between shelves**, and **search & add** books.

### Fixed

- More reliable sign-in.

Features and fixes from earlier releases are described in the sections below.

## [1.8.1] - 2026-09-15

### Fixed

- More reliable sign-in: the plugin no longer reports a failure when the
  post-sign-in page is intercepted but the session was actually created.

## [1.8.0] - 2026-09-15

### Added

- **Browse shelves.** A new **Browse shelves** entry opens your Goodreads
  shelves in a single box that stays open until you close it. It lists all your
  shelves — including custom ones — with counts, loads each shelf's books on
  demand, and lets you **move a book to another shelf** or **search & add a
  book**. Opens instantly with your linked books and loads the full shelf list
  from Goodreads on request.

## [1.7.0] - 2026-09-15

### Changed

- The experimental shelves browser is not included in this release; behaviour is
  otherwise the same as 1.6.7.

## [1.6.7] - 2026-09-14

### Added

- **Did Not Finish** is now selectable in **Set status on Goodreads**. It is
  sticky: automatic sync never moves a DNF book.

### Changed

- Manual **Set status** can move a book to any shelf — Want to Read, Currently
  Reading, Read or Did Not Finish — including Read → Want to Read. Automatic
  syncing still only ever uses Currently Reading or Read, and never downgrades a
  finished book.

### Fixed

- No more duplicate progress updates: automatic syncs run one at a time, and a
  just-pushed percentage clears any queued duplicate.

## [1.6.6] - 2026-09-14

### Changed

- **Set status on Goodreads** lets you move a book to any shelf manually —
  Want to Read, Currently Reading or Read — including Read → Want to Read.
  Automatic syncing still only ever uses Currently Reading or Read, and never
  downgrades a finished book.

### Fixed

- No more duplicate progress updates: automatic syncs run one at a time, and a
  just-pushed percentage clears any queued duplicate, so Goodreads no longer
  shows the same percentage twice.

## [1.6.5] - 2026-09-14

### Changed

- The plugin menu now shows **Sync now**, **Set status on Goodreads** and
  **Support this project** at the top level, so no submenu is needed for them.
- Setting **Want to Read** now sticks until reading resumes: it moves to
  Currently Reading only once progress passes where it was when set (>1%). The
  status chooser also updates immediately.

## [1.6.4] - 2026-09-14

### Fixed

- Crash when changing a sync preset (a loop variable named `_` shadowed the
  translation function inside the callback).
- Crash in **Waiting to sync** when there were failed operations (same cause).
- Hardened the link-failure dialogs (nil identity) and the background-task
  fallback (errors no longer propagate) so an unexpected failure can't crash
  KOReader.

## [1.6.3] - 2026-09-14

### Changed

- Default sync preset is now **Medium** (open/close + a checkpoint every 15 minutes).
- Selecting a sync preset now shows a brief confirmation of what it does.
- When a book can't be linked automatically, a window offers to enter its
  Goodreads ID or ISBN (with a short how-to) and an **Ask me in an hour** option.

### Fixed

- Turning Wi-Fi on when prompted now runs the requested action automatically
  (Sync now, Check for updates, sign-in, Test connection, search) instead of
  needing another tap.
- Closing a book (or reconnecting) no longer shows "Offline changes synced" when
  online; the toast now names the book.

## [1.6.2] - 2026-09-14

### Fixed

- Choosing a sync preset now also turns open/close syncing on, so the event
  triggers always work (previously a legacy setting could keep them disabled).

### Changed

- README documents what triggers a sync under each preset.

## [1.6.1] - 2026-09-14

### Changed

- Update checks now run about once a day (previously once a week). When a newer
  version exists you get a single "Update now?" prompt per day until you update.
- Notifications are now prefixed with "Goodreads Sync:" and name the book, so it
  is clear what happened and where it came from. Wording is shorter and more
  specific throughout.

## [1.6.0] - 2026-09-14

First stable release after a major update round.

### Added

- **Sync presets** — one choice (Fastest default, Faster, Medium, Relaxed) sets
  all sync timing and tracking.
- **Mark new books as Currently Reading** (on by default).
- Reliable on-device sign-in, including an on-device prompt for extra
  verification and automatic retries on flaky connections.
- Gentle background notifications (offline saves and flushes, linking,
  Currently Reading, and sync failures).
- Install from **KOReader Storefront** (or from Releases).

### Changed

- Automatic syncs no longer turn Wi-Fi on; they use the connection when it is
  available and otherwise queue. Only an explicit **Sync now** asks to turn
  Wi-Fi on.
- The Account menu reflects the sign-in state (Log in when signed out, Log out
  when signed in).
- Remote shelf reads are cached; routine syncs stay quick.

### Fixed

- Login no longer reports false sign-in failures or shows vanishing popups.
- Reading offline is never stranded: progress is pushed as soon as the
  connection returns.
- Opening a new book offline no longer prompts for Wi-Fi; it links
  automatically once online.

### Removed

- The non-working "Open on Goodreads" button.
- The individual sync settings (replaced by presets).

## [1.5.2] - 2026-09-13

### Fixed

- Reading offline is never stranded: when the connection returns (or the device
  wakes), the open book's progress is pushed immediately, in addition to the
  queued changes from earlier closes/suspends.

## [1.5.1] - 2026-09-13

### Fixed

- Opening a new (unlinked) book while offline no longer prompts for Wi-Fi.
  The book is linked automatically once the connection returns (when Auto-link
  is on), then syncs per the chosen preset.

## [1.5.0] - 2026-09-13

### Changed

- Sync behaviour is now defined by a single preset — **Fastest** (default),
  Faster, Medium or Relaxed — which sets all the sync timing and tracking
  options at once.
- Removed the individual sync settings (track mode, percent/page step, interval,
  conflict policy, completion behaviour) to keep configuration simple.
- The Account menu already reflects the sign-in state (Log in / Log out).
- Removed the non-working "Open on Goodreads" button.
- Automatic syncs no longer turn Wi-Fi on: they use the connection when it is
  available and otherwise wait for reconnect. Only an explicit **Sync now**
  asks to turn Wi-Fi on.

### Added

- **Mark new books as Currently Reading** setting (on by default).

## [1.4.2] - 2026-09-13

### Fixed

- The Account menu now reflects the sign-in state: it shows **Log in** when
  signed out and **Log out** when signed in, instead of always showing both.

## [1.4.1] - 2026-09-13

### Fixed

- Login issue fixed: signing in to Goodreads now works reliably and is no longer
  reported as a failure when it isn't one.
- Login progress stays on screen long enough to read, and retry attempts are shown.
- Clearer outcomes: a success message, or a failure reason with a suggestion to
  try again in a little while.

## [1.4.0] - 2026-09-13

### Added

- Sign-in runs in the background so it no longer freezes the app, retries
  transient failures, and shows progress.
- When Goodreads asks for an extra verification step, it is shown
  on-device so you can complete it.
- After a successful login the current book syncs immediately.

### Fixed

- Sign-in prompts for Wi-Fi when it is needed.
- More tolerant sign-in timeouts.

## [1.3.0] - 2026-09-13

### Added

- Wi-Fi is now handled the KOReader way. The plugin uses Wi-Fi when it is
  already on and otherwise lets KOReader's network framework decide; it never
  toggles the radio itself.
- Opt-in automatic Wi-Fi for the meaningful sync events (open, close, first
  link): when enabled and KOReader's Network → "Wi-Fi enable action" is set to
  "turn on", the sync runs silently; KOReader's own "auto disable Wi-Fi"
  switches it back off afterwards.

### Changed

- Replaced the plugin's custom Wi-Fi power logic with KOReader's native
  `runWhenOnline`/`willRerunWhenOnline`, so manual actions follow the global
  Wi-Fi prompt/turn-on setting instead of bypassing it.
- The periodic timer and resume no longer try to bring Wi-Fi up (avoids
  reconnect churn on battery).
- The "Turn on Wi-Fi when needed" setting now explains the KOReader
  requirement and shows a hint when it is enabled without it.

## [1.2.0] - 2026-09-13

### Added

- **Sync preset** — Battery saver / Balanced / Frequent. Balanced is the new
  default (sync on open, close, reconnect and every 15 minutes).
- Newly linked books are added to **Currently Reading** on Goodreads right away
  (can be turned off in Settings).

### Changed

- The remote shelf is now only re-read on open, on a manual sync, or every
  60 minutes; periodic syncs reuse the cached value instead of downloading the
  review page every time.
- Default progress interval is 15 minutes and page turns no longer trigger a
  network sync by default.

## [1.0.0] - 2026-09-13

First stable release.

- Identify arbitrary EPUBs and link them to Goodreads (ISBN, ASIN, Goodreads
  ID, or title/author).
- Sign in to Goodreads from KOReader itself (challenges handled on-device).
- Sync shelves (Want to Read / Currently Reading / Read), reading progress
  (by time, percent, or page), completion, and ratings.
- Persistent user-shelf overrides; Read is sticky.
- Offline queue with retry; background sync never blocks reading.
- Self-update from GitHub Releases (weekly check + on demand, SHA-256 verified).

## [0.4.6] - 2026-09-13

### Fixed

- **Check for updates** now goes through the same Wi-Fi handling as sync (it no
  longer fails when Wi-Fi is off), and reports the reason on failure
  (e.g. "Couldn't check for updates (NETWORK_ERROR).").

## [0.4.5] - 2026-09-13

### Fixed

- **Change linked book** now always shows the candidate list to choose from,
  instead of auto-linking the best match.

## [0.4.4] - 2026-09-13

### Added

- **More → Version** shows the installed version (and the releases page).

## [0.4.3] - 2026-09-13

### Fixed

- Plugin failed to initialise (`ffi/util.pathExists` does not exist), which hid
  the menu and showed it only under Plugin management. The self-update cleanup
  now uses a correct existence check and is fully guarded.

## [0.4.2] - 2026-09-13

### Changed

- Version bump to exercise the in-app self-update path end to end.

## [0.4.1] - 2026-09-13

### Added

- **Self-update**: checks GitHub Releases about once a week (and on demand from
  More → Check for updates). When a newer version exists you can download,
  verify (SHA-256), install, and restart from the plugin. Fail-safe: the
  previous version is kept as a backup and restored if the swap fails. Update
  checks are fully guarded, so a missing or renamed repo never breaks the
  plugin.

## [0.4.0] - 2026-09-13

### Changed

- Default tracking is now **Percent change, every 5%**: progress syncs when you
  cross a 5% step (within ~30 s) instead of waiting for the 5-minute timer.
  The periodic timer still runs as a safety net. Configurable under Settings →
  Track progress by.

## [0.3.9] - 2026-09-13

### Fixed

- Never send 0% progress (opening a book no longer pushes 1%).
- A shelf you set to **Want to Read** on Goodreads is now honored persistently:
  progress is paused and the book stays Want to Read until you actually read
  again (new progress > 1%), then it moves to Currently Reading.
- Explicit KOReader completion overrides a Want-to-Read choice and marks Read.

## [0.3.8] - 2026-09-13

### Changed

- Plugin folder renamed to **goodreadskosync.koplugin** (no longer
  `goodreads.koplugin`).
- Plugin display name is **Goodreads Sync (unofficial)**.

## [0.3.7] - 2026-09-13

### Changed

- Renamed the plugin display name to **Goodreads Sync**.

## [0.3.6] - 2026-09-13

### Added

- Manual **Set status on Goodreads** (Want to Read / Currently Reading / Read).
- "Already marked Read on Goodreads — nothing to sync." notice when opening a
  finished book.
- "Keep syncing progress after a book is finished" setting.
- React to book-status/metadata changes from KOReader's book-info dialog.
- Retry a sync once after refreshing the session on a spurious auth failure.

### Fixed

- **Read is sticky**: a book marked Read is never auto-downgraded to Currently
  Reading (fixes the reopen-at-100% flip and protects manual shelves).
- `abandoned` status no longer moves a book to Currently Reading.
- Queued offline progress keeps its unit (percent or page).
- A shelf the user set to Want to Read on Goodreads is honored.
- Renamed the completion setting to **Mark finished at** for clarity.

## [0.3.5] - 2026-09-13

### Added

- Flush the sync queue as soon as the network reconnects.
- End-of-book hook that marks the book Read when automatic completion is
  enabled.

### Fixed

- Auto Wi-Fi now only turns Wi-Fi back off if the plugin turned it on; your
  prior Wi-Fi state is preserved.

## [0.3.4] - 2026-09-13

### Changed

- Automatic sync is now toast-only: session-expired and "finished, rate it"
  notices are toasts, not popups. Signing in and rating stay manual actions.
- Menu shows "(sign in)" when not signed in; This book items are disabled when
  no book is open; Log out and Forget link ask for confirmation.
- Status screen shows shelf, rating, local and Goodreads progress, and last
  sync time, with a "Rate this book" action.
- "Waiting to sync" shows the queue with a Sync now button.
- "Open on Goodreads" opens the link in the system browser when supported.
- Toasts for the same message within two seconds are coalesced.

## [0.3.3] - 2026-09-13

### Added

- "Rate this book" (1–5 stars) under This book; ratings are only sent on an
  explicit tap.
- Failure toast for automatic sync (at most once every 5 minutes), so failures
  are not silent.

### Fixed

- The sign-in prompt on opening a book now appears only when the session is
  genuinely expired, not merely unreadable.
- A best-effort shelf read no longer invalidates a valid session.
- Closing a book flushes the pending sync queue immediately.

## [0.3.2] - 2026-09-13

### Added

- Progress feedback: a small "N% synced to Goodreads." toast when progress is
  pushed, and "Synced N% to Goodreads." after a manual sync.
- One-time guidance when a book can't be found automatically, explaining how to
  link it manually; later attempts show a brief "Couldn't find this book on
  Goodreads." toast.

## [0.3.1] - 2026-09-13

### Changed

- Removed the "Change provider" option (the plugin uses the working Goodreads
  web provider).
- Automatic sync now shows a small "Synced with Goodreads." toast when it
  actually pushes something, and a toast when Goodreads has the book as Read.

## [0.3.0] - 2026-09-13

### Added

- Track progress by time, by percent change, or by page change, with
  configurable steps.
- Page mapper: sync by page number when the linked edition paginates
  differently (uses KOReader page labels).
- Reads the remote shelf and warns once if Goodreads marks the book Read while
  you are still reading, instead of overwriting it.
- Per-book automatic sync toggle.
- "Add note to Goodreads" from the highlight menu.
- "Check for updates" (GitHub Releases).
- Session cookies and the saved password are encrypted at rest when libcrypto
  is available (falls back to plaintext otherwise).
- Small table helpers module.

### Changed

- Auto Wi-Fi now turns Wi-Fi back off after syncing.
- Progress can be sent as a page number (`user_status[page]`) or a percent.
- Simplified README and plugin description.

## [0.2.7] - 2026-09-13

### Changed

- Opening an unlinked book now links it automatically to the best Goodreads
  match and shows a small, non-intrusive toast ("Linked to Goodreads: …")
  instead of a modal popup. The search runs in the background.
- The sign-in prompt when opening a book appears at most once per session.

### Added

- "Link books automatically" setting.

## [0.2.6] - 2026-09-13

### Changed

- Renamed the menu entry and plugin to **Goodreads Sync**.
- Friendlier, less intrusive menu: Account / This book / Settings / More.
- Single sign-in flow; after signing in the plugin asks whether to save the
  password instead of offering a separate "log in with saved password" entry.
- Opening an unlinked book shows an interactive "New book?" prompt with a
  "Find on Goodreads" action; opening a book while signed out offers to sign in.
- Automatic sync runs in the background and no longer blocks reading.

### Added

- "Turn on Wi-Fi when needed" setting (auto Wi-Fi, ShelfSync-style).

## [0.2.5] - 2026-09-13

### Changed

- Project/package name is now **goodreadskosync** everywhere (package archive,
  docs, scripts, CI artifact). The KOReader plugin folder remains
  `goodreadskosync.koplugin` as required by KOReader.
- Plugin settings directory renamed to `settings/goodreadskosync/`.

## [0.2.4] - 2026-09-13

### Fixed

- **Critical:** the HTTP transport misread LuaSocket's return tuple
  (`(1, code, headers, statusline)`), so every real response was classified as
  `INVALID_RESPONSE`. This is why the sign-in page was fetched (13 KB) yet login
  reported `start: INVALID_RESPONSE`.
- `for _, entry in ...` loops in `main.lua` and `ui/settings.lua` shadowed the
  gettext `_()` function and crashed the Settings/provider menus.

## [0.2.3] - 2026-09-13

### Added

- Login falls back to the known Goodreads email sign-in URL when the sign-in
  page does not contain the expected link.
- The login trace now records a non-secret page fingerprint (form/password/
  form/password/sign-in/consent markers) to pinpoint where a
  different page is being served.

## [0.2.2] - 2026-09-13

### Added

- Wi-Fi check with an offer to turn Wi-Fi on (`NetworkMgr:willRerunWhenOnline`)
  for login, connection test, sync, and book search; the periodic timer and
  offline queue skip silently while offline.
- Opt-in **Remember password (testing)** setting: stores credentials locally
  (plain text), prefills the login form, and offers one-tap re-login. Off by
  default; removable via "Forget saved password".

## [0.2.1] - 2026-09-13

### Added

- Stage-by-stage redacted logging for the login flow (`login/start`,
  `login/submit`, `login/interpret`, `login/finalize`), written to
  `settings/goodreadskosync/login.log`, so a failed on-device login reports exactly
  where it stopped.
- `Diagnostics → Status` shows session state and the last login stage/error.

### Fixed

- Login prefers the site's own sign-in link over
  the third-party sign-in buttons.
- A credential form returned after submit is now reported as invalid
  credentials instead of a generic failure.

## [0.2.0] - 2026-09-13

### Added

- Real Goodreads web provider (`providers/goodreads_web.lua`) as the primary
  backend, backed by `goodreads/client.lua` and `goodreads/http.lua`.
- Session-aware HTTP layer: cookie jar, `Set-Cookie` rotation, manual redirects,
  blocked-session and expired-session classification.
- On-device interactive email/password login (`auth/login.lua`,
  `auth/providers/amazon_web.lua`) with OTP support; unsolvable challenges stop the flow.
- Session manager (`auth/manager.lua`) with provider discovery/selection,
  `validate_session`, `refresh_session`, expiry detection, and account lookup.
- Session persistence (`auth/session.lua`); the password is not stored by default.
- Normalized Goodreads operations: search (`/book/auto_complete` JSON), book
  lookup (JSON-LD), shelf write/remove, progress (`/user_status.json`), rating.
- Self-contained JSON decoder (`goodreads/json.lua`) for tests and fallback.
- UI: on-device login, test connection, account state, sync-on-open/close.
- Tests for HTTP, session, auth manager, login flows, client, and provider
  (125 total).

### Changed

- `providers/web_session.lua` replaced by `providers/goodreads_web.lua`.
- Provider discovery moved from `auth.lua` into `auth/manager.lua`.
- Extended the provider interface with `get_shelves`, `get_book_shelves`,
  `remove_shelf`, `get_rating`, and the auth lifecycle.
- Default provider order now prefers the Goodreads web provider.

## [0.1.0] - 2026-09-13

### Added

- Initial `goodreadskosync.koplugin` skeleton with `_meta.lua` and `main.lua`.
- EPUB OPF metadata extraction: title, authors, contributors, identifiers,
  publisher, language, date, and series.
- Identifier support: ISBN-10/13 validation and conversion, ASIN detection,
  and explicit Goodreads ID detection.
- Resolution pipeline with conservative confidence scoring; title/author-only
  matches are never auto-selected.
- Persistent local book mappings keyed by ISBN/ASIN/Goodreads ID or a metadata
  hash, surviving restart, rename, and move.
- Provider interface plus discovery, selection, and account session handling.
- Mock provider with a fully working end-to-end flow and no built-in
  catalogue.
- Native Kindle provider with firmware/framework detection only; shelf,
  progress, and rating paths are separate but unimplemented.
- Web session and official API provider stubs.
- Sync engine with pure decision logic, shelf/progress/rating actions, and
  confirmed-success state tracking.
- Offline operation queue with coalescing, exponential backoff, and
  idempotency.
- UI: top-level Goodreads menu, status screen, candidate selection,
  unidentified-book screen, manual search, account, and settings.
- Network layer with normalized error codes.
- Redacting logging facade and diagnostic summary.
- Unit tests (75 cases) and a dependency-free test runner.
- Local tooling (`tools/setup.ps1`, `tools/build.ps1`), Makefile, and GitHub
  Actions CI.
- Documentation: architecture, authentication, identification, sync, and
  troubleshooting.

[Unreleased]: https://example.invalid/goodreadskosync/compare/v0.1.0...HEAD
[0.1.0]: https://example.invalid/goodreadskosync/releases/tag/v0.1.0
