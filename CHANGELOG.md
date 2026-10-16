# Changelog

All notable changes to Claudio are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Added

- Native macOS menu bar sound center for Claude Code and Codex.
- Five semantic sound events with per-event mute, preview, and master-volume controls.
- Sound pack selection, import, favorites, factory restoration, and local diagnostics.
- Explicit dual-host connection management with one-time backups and minimal real-event receipts.
- English and Simplified Chinese interfaces with keyboard and VoiceOver support.
- Public project documentation, contribution guidance, security policy, code of conduct, and issue forms.
- Push and pull-request CI for helper/GUI harnesses, Debug/Release GUI builds, localization JSON, whitespace, and release-size checks.
- A unified build version provider with `0.0.0-dev` as the local development version.
- Fail-closed Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper assessment, and `SHA256SUMS.txt` generation for releases.
- Optional Homebrew tap updates controlled by `HOMEBREW_TAP_ENABLED`.
- OpenCode 2 plugin contract: the bridge plugin dual-exports the 1.x `server` hooks and the 2.x `setup` entry point with an event-stream subscription, and the helper reads OpenCode 2's branded version line (`opencode v2.0.27`) again.

[0.1.0]: https://github.com/d0m999/Claudio/releases/tag/v0.1.0
