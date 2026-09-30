# Security Policy

## Reporting a vulnerability

Please report security issues privately to the project maintainers rather than
opening a public issue. Include a description, reproduction steps, and the
affected version.

## Credential handling

The plugin is built so that credentials cannot leak through logs or
diagnostics:

- By default the Goodreads password entered at login is used once and is
  **never persisted**. There is an explicit opt-in **"Remember password
  (testing)"** setting that stores it in plain text under the plugin settings
  directory so a tester does not have to re-enter it; it is off by default and
  can be removed with "Forget saved password". This is not secure storage
  (KOReader has no OS keystore) and is not recommended for normal use.
- The authenticated session (cookie bundle, CSRF token, numeric user id) is
  stored locally in `settings/goodreadskosync/session.lua` and is treated as a
  secret: it is never logged, never included in the diagnostic summary, and
  never exported.
- All plugin logging goes through `logging.lua`, which redacts tokens, cookies,
  `Authorization` headers, session IDs, passwords, CSRF tokens, access tokens,
  and refresh tokens before anything is written.
- Provider response bodies are never logged. Network logging is limited to the
  provider, operation, HTTP status, timestamp, and retry state.
- The web-session provider must never require users to paste cookies and must
  never store credentials in logs. It is a stub in this release.
- The diagnostics summary (`logging.lua:diagnosticSummary`) is built from a
  strict allowlist of scalar fields: KOReader version, plugin version, device
  family, provider, availability, last sync stage, HTTP status, and queue size.
  It never includes book titles, authors, credentials, or response bodies.

## What is never uploaded

- Book contents.
- Annotations, highlights, notes, and reading history.
- Any telemetry or analytics.

Book metadata (title, author, identifiers) is sent to a search provider only
when the user requests identification.

## Native Kindle isolation

Any future native Kindle Java-agent functionality must remain isolated behind
`providers/native_kindle.lua` and must be reviewed independently. It must never
run unless the device is detected as compatible.

## Supported versions

Only the latest released version receives security fixes.
