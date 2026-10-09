# Contributing to Claudio

Thank you for helping improve Claudio. Small, focused changes with evidence are easiest to review.

## Before you start

- Search existing issues and pull requests first.
- Use an issue for user-visible behavior changes, new host integrations, sound-pack format changes, or release/distribution changes.
- Never include private prompts, responses, project paths, host configuration, receipts, logs, signing credentials, or licensed personal sound packs in an issue or commit.
- Keep `local-packs/`, `dist/`, `.build/`, and machine-specific artifacts out of Git.
- Version only the default Factory Pack, `packs/minimal-chime/`; other directories of sound packs under `packs/` stay local and are ignored. Keep the distribution selection and `.gitignore` allowlist aligned when changing the default pack.

## Development environment

- macOS 12 or later.
- Xcode Command Line Tools with Swift 6.
- `jq` for validating the string catalog.
- Node.js for the standalone sound-pack selector state regression.
- Python 3 and Node.js for the embedded OpenCode plugin and additional-host CLI contracts.
- `ffmpeg` and `ffprobe` for curated sound-pack measurements.

CI keeps the Helper lane on Xcode 16.4 and pins GUI/bundle checks to Xcode 26.3 for
SDK 26 APIs and SwiftUI compiler compatibility. The macOS deployment target remains 12.
The GUI lane configures its disposable runner's virtual display to 1920×1080 before
native layout checks, preserving the 1240×820 settings-window test premise.

Clone the repository and run commands from its root. The helper and GUI are separate Swift packages; always pass the explicit package path and product shown below.

## Build and test

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
node scripts/test-sound-pack-selector-state.js
python3 scripts/test-sound-pack-candidates.py
python3 scripts/embed-opencode-plugin.py --check
node scripts/test-opencode-plugin.mjs
python3 scripts/test-additional-host-cli-contract.py
python3 scripts/test-additional-host-migration.py
python3 scripts/test-additional-host-migration.py --acceptance

swift build -c debug --package-path gui --product ClaudioGUI
swift build -c release --package-path gui --product ClaudioGUI

jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
git diff --check
```

The selector state regression compares the exact six-package curated roster with the versioned
`packs/LICENSES.md`, including duplicate/missing/extra entries, rather than requiring ignored local
audio directories. The bundled-pack selection must be a subset of that licensed roster.

`--ai-cue-gallery` mounts the production presentation seam with fixtures. Ordinary builds verify
credential-entry rejection; `-Xswiftc -DCLAUDIO_BAILIAN_ACCEPTANCE` verifies admitted sheets;
`-Xswiftc -DCLAUDIO_PUBLIC_PREVIEW` verifies storage-limited rejection. These checks do not grant
Provider admission or establish real Keychain access or UI acceptance.

`scripts/test-sound-pack-candidates.py` always checks generators and license records; audio checks for local candidate packs report a skip when their pack directories are absent. Present candidate packs retain all existing audio and ledger checks.

`scripts/dev-bundle.sh` produces an ad-hoc signed, current-architecture app for local inspection only. It is not equivalent to the universal, Developer ID signed, notarized release artifact.

Bailian Audio 3.1 remains closed in ordinary builds until the resource contract and real adoption
pass ADR 0027. Use `bash scripts/dev-bundle.sh --bailian-acceptance` for its explicit local bundle.
It records source file hashes and the code-owned asset policy in `bailian-acceptance-source.json`;
the identity is frozen before compilation and checked after each build and bundle assembly.
Source drift fails the build and removes that run's app. Run
`python3 scripts/test-bailian-bundle-identity.py` for the deterministic build-orchestration regression.
This build does not establish distribution eligibility. See
[the current evidence](plan/PLAN-BAILIAN-AUDIO-31-EVIDENCE.md) before making real requests.

OpenCode and Kimi Code qualify per binding under ADR 0024. Ordinary Release builds expose a
source when it has reviewed bindings and keep its unverified bindings closed. The current evidence
is recorded in `docs/validation/opencode-kimi-code-2026-10-06.md`. Debug builds expose all candidates. Use `bash scripts/dev-bundle.sh --additional-host-acceptance` for an explicit local
acceptance bundle. It compiles the same flag into GUI and helper and marks the app plist.
The plugin source is embedded in the helper and copied to `Resources/integrations/opencode/`;
after editing `integrations/opencode/claudio.js`, regenerate with
`python3 scripts/embed-opencode-plugin.py` and run the check above.
Bundle builds use `-Osize` for the helper, preserving the existing executable-size budget.

The migration suite exercises public adapters in isolated temporary roots under ordinary Release
and explicit acceptance builds. Configuration ownership recognizes exact known historical templates
and implemented bindings independently of release admission; connect migrates them to the current
template and permitted binding set. Edited managed bytes remain conflicts, and one-shot backups
are preserved. This automated migration evidence does not replace real-host acceptance.

On a Command Line Tools installation whose current SDK requires unavailable SwiftUI macro
plugins, select a compatible installed SDK explicitly for local checks, for example
`--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
Set `SDKROOT` to that same path when running the GUI harness so its compiler probes use it too.
`CLAUDIO_BUILD_SDK=/absolute/path/to/compatible.sdk bash scripts/dev-bundle.sh` passes that same
SDK to all local bundle builds. This is local toolchain evidence and does not replace the CI
Xcode, architecture, signing or native acceptance gates.

For changes that affect the unified settings experience, run the fixed-baseline integration gate:

```bash
bash scripts/verify-settings-experience.sh <BASE_SHA>
```

Use [the unified settings acceptance checklist](docs/settings-experience-acceptance.md) to keep
automated, native UI, real-system, Provider, architecture, signing, and release evidence separate.

## Public preview candidates

The independent [preview workflow](.github/workflows/preview.yml) builds a clean exact `main`
commit as `0.0.N`. It does not create a public release in build mode. Publish mode consumes an
accepted artifact's original DMG, validates the GitHub archive digest and every device gate in
[preview-acceptance.json](docs/preview-acceptance.json), then verifies public assets before deploying
the signed Pages feed. See [the preview ledger](docs/preview-acceptance.md) and ADR 0030.

For local inspection only (current architecture, uncommitted source permitted):

```bash
CLAUDIO_VERSION=0.0.1 bash scripts/dev-bundle.sh --public-preview
swift run --package-path gui claudio-gui-tests --public-preview
bash scripts/test-sparkle-contract.sh
python3 scripts/test-preview-artifact.py
```

`--public-preview` cannot be combined with Provider/host acceptance flags. Sparkle's pinned upstream
universal framework is copied with its versioned links and signed inside out. It has a separate
3,500,000-byte budget; original app/resource budgets remain enforced. A dev bundle lacks a feed;
an installed preview uses the preview feed, and a formal bundle uses the formal feed. Formal
framework tools require the same Developer ID team, runtime and timestamp gates as other binaries.
Neither local inspection nor a universal candidate establishes Gatekeeper, login or two-version
upgrade acceptance. CI needs `SPARKLE_PRIVATE_KEY` (32-byte seed in base64); use stdin, never a
command-line secret. The matching public key is checked in `config/sparkle-public-key.txt`.

## Change rules

- Preserve existing host hooks, unknown JSON keys, user sound packs, configuration, backups, and receipts unless the issue explicitly defines a migration.
- Keep Claude Code and Codex adapters independent. A failure in one host must not damage or freeze the other.
- Treat a written configuration and a real hook receipt as different states.
- Keep UI semantics, keyboard focus order, hit targets, Dynamic Type layouts, and VoiceOver output aligned.
- Add or update the executable harness checks for behavior changes. Static source scans should guard cross-file contracts only when a compile-time link cannot.
- Add English and `zh-Hans` entries with matching placeholders for every localization key, and update `ClaudioL10nKey.allKnown`.
- Do not commit generated `dist/` bundles or personal/imported audio.
- Do not change the hook command format, configuration schema, or user-data paths as part of an unrelated change.

## Pull requests

Describe:

1. The user-visible problem and intended behavior.
2. The files or contracts changed.
3. Commands run and their exact result.
4. Manual checks performed, especially native UI, VoiceOver, keyboard/focus, and real-host callbacks.
5. Anything not verified.

CI is required but does not establish native macOS or real-host acceptance. Maintainers may ask for Apple Silicon and Intel evidence for release-sensitive changes.

By contributing, you agree that your contribution is licensed under the repository's [PolyForm Noncommercial License 1.0.0](LICENSE), and you grant d0m999 the right to also license your contribution under separate commercial terms. You will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
