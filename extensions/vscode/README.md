# Claudio Session Navigation

Install `dist/claudio-session-navigation-1.0.0.vsix` explicitly using **Extensions: Install from VSIX…** in VS Code or Cursor, then run Claudio. The status bar shows connected, disconnected, or unsupported version. Build with `npm run package` from this directory; run fixtures with `npm test`.

Only local macOS integrated terminals are supported. SSH, containers, remote workspaces and native AI chat panels are excluded. Each window opens its own private Unix socket connection to the current GUI epoch and registers terminal shell PIDs. No workspace paths or session IDs are persisted. Window reload, connection loss and terminal closure invalidate registrations. Claudio verifies OS process identities and requires a unique terminal match.

The extension only performs `workbench.action.focusWindow` and `terminal.show(false)`. It confirms window focus and active terminal; Claudio also checks the foreground application. Missing focus capability falls back to the previously verified source application. Default URI handlers are not used.

## Wire protocol (schema 1)

Newline-delimited JSON, maximum 8 KiB per frame, same-user peer credentials. Every message includes the discovery `epoch`; navigate/cancel/result include the per-window `instance` and request UUID. Registration sends at most 64 shell PIDs and a `supported` capability. GUI returns a `registered` acknowledgment only after OS validation; the status bar reports connected only after that acknowledgment. Navigate carries one registered `shell` PID and `remainingMs` (1–3000). Result returns that shell and `confirmed` or `unavailable`. Cancellation is best effort for an already dispatched window focus, and prevents subsequent terminal selection. No command strings or URLs are accepted.

Fixture tests and VSIX packaging do not establish real window focus, keyboard focus, VoiceOver or Cursor compatibility. See the repository session-navigation validation ledger.
