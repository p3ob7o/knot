# Knot

Knot is a local-first capture app for writing Markdown into an Obsidian vault. Version 0.2.0 focuses on macOS 26: a native menu-bar capture surface handles the fast path, and an optional bundled Gutenberg window handles richer Inbox notes with images.

Knot has no account, server, telemetry, runtime CDN, or built-in sync. It writes files inside a folder you authorize. Obsidian Sync, iCloud, Git, Syncthing, and other providers remain separate systems; file coordination helps cooperating local processes but cannot guarantee distributed conflict behavior.

## Capture Modes

The native quick surface opens without constructing WebKit. Type Markdown, choose `Today` or `Inbox` when needed, and use Command-Return, Control-Return, or the send button. The default Control-Option-K global shortcut is configurable or can be disabled.

Automatic routing uses the preserved defaults:

| Input | Destination |
| --- | --- |
| At most 280 extended grapheme clusters and one line | A formatted bullet in today's daily note |
| Longer or multiline | A new Markdown file in Inbox |

The explicit `Today` and `Inbox` controls override that decision for the current draft. The mode returns to automatic after a successful send. A first-line H1 containing 1 to 7 words can provide an Inbox filename while the remaining body is preserved.

The rich editor is an optional Inbox composer. It supports paragraphs, headings, lists, quotes, code, separators, links, formatting, and images from paste, drop, or the native picker. It promotes the current quick draft into a durable rich draft and does not edit arbitrary existing vault files.

## Reliability

Knot distinguishes local durability from vault publication:

- `Pending` means an immutable capture snapshot and required assets were stored in Knot's private Application Support directory.
- `Saved to vault` means the coordinated file mutation completed and a receipt was recorded.
- `Retryable` means the same immutable capture can be retried without reinterpreting its destination, date, locale, or settings.
- `Needs review` means the outcome may be uncertain. Knot stops instead of blindly appending again.

Draft checkpoints, pending captures, staged assets, mutation journals, and receipts are stored in a versioned SQLite database. Vault publication validates relative paths, rejects symlinks and hardlinks, verifies the selected root identity, uses exclusive creation for new files, and records enough state to reconcile interrupted writes.

The macOS menu-bar `Recovery...` window can reopen or export drafts, retry or cancel pending captures, and explicitly resolve uncertain captures after the user checks the target.

## Setup

On first launch, reset, or lost vault access, Knot resumes a five-step setup transaction:

1. Authorize the vault folder.
2. Browse to and explicitly select the Inbox folder.
3. Browse to and explicitly select the Daily folder and review its filename format.
4. Choose a discovered or manual heading, create it when missing, or append at end of note.
5. Review and finish the configuration.

The vault root is a valid destination. Opening a child folder only navigates; `Use Vault Root` or `Use <folder>` selects the current folder. A typed nonexistent relative path requires confirmation before Knot records permission to create it.

Periodic Notes settings take precedence over Core Daily Notes settings when an enabled, valid configuration is found. Imported changes remain field-scoped and undoable. A vault without `.obsidian` is also supported.

See [USAGE.md](USAGE.md) for the complete workflow and recovery semantics.

## Supported Formats

Date patterns intentionally implement a validated Moment-compatible subset, not every Moment or Obsidian token:

```text
YYYY GGGG MMMM DDDo DDDD SSS MMM DDD dddd
YY GG MM Mo DD Do ddd dd ww wo WW Wo HH hh kk mm ss SS ZZ
Qo Q M D do d E w W H h k m s S A a Z X x
```

Wrap literal text in brackets, for example `[Notes]/YYYY-MM-DD`. Slashes generate validated subfolders. Unknown letter tokens fail validation.

The daily bullet template must contain the exact `{{content}}` placeholder. Other placeholders contain one supported date pattern, for example `- {{HH:mm}} {{content}}`.

## Requirements

- macOS 26 for the supported app
- Xcode 26 or later with the macOS 26 and iOS 26 SDKs
- XcodeGen 2.45.4 or a compatible newer release
- Node 24.20.0 and npm 12.0.2 for the reproducible rich-editor build
- A vault folder visible to the system folder picker

The iOS 26 target is an experimental compatibility shell. It is built in verification but is not claimed as a released or fully acceptance-tested product.

## Build

`project.yml` is the Xcode project and version source of truth. `bootstrap.sh` performs a locked npm install, type-checks and builds the bundled editor, then generates `Knot.xcodeproj`. It does not install tools automatically.

```sh
./bootstrap.sh
xcodebuild -project Knot.xcodeproj -scheme Knot-macOS \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

For the audited beta toolchain used by the rewrite:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/verify.sh
```

Useful focused commands:

```sh
swift test --package-path Packages/KnotKit
./scripts/build-web.sh
./scripts/verify.sh --quick
./scripts/perf-fixtures.sh --output /tmp/knot-perf-fixtures
./scripts/benchmark.sh --fixtures /tmp/knot-perf-fixtures
```

`scripts/release.sh` is fail-closed. It additionally requires a clean exact release tag, an explicit Developer ID identity and team, an available notarization profile, successful signing, notarization, stapling, and Gatekeeper assessment. An unsigned development build is not a release artifact.

## Project Layout

```text
Knot/Shared/                  shared SwiftUI orchestration and quick UI
Knot/macOS/                   AppKit surfaces, hotkey, recovery, WKWebView bridge
Knot/macOS/GutenbergWeb/      TypeScript editor, locked dependencies, tests
Knot/iOS/                     experimental compatibility shell
Packages/KnotKit/             domain, formatting, persistence, vault I/O
Tests/KnotMacOSTests/         hosted native and WK resource tests
rewrite-evidence/             audited baseline and generated test evidence
scripts/                      build, verification, benchmark, release tools
project.yml                   generated-project and version source of truth
```

Generated `Knot.xcodeproj`, web `dist`, `node_modules`, and build products are intentionally ignored.

## License

GPL-2.0-only. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
