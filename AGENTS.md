# AGENTS.md

Guidance for coding agents working in Knot.

## Product Contract

Knot 0.2.0 is a local-first Obsidian capture app. The supported product is the macOS 26 menu-bar app. Its native quick path must remain independent of WebKit. The optional bundled Gutenberg window promotes a quick draft into a rich Inbox draft; it is not an arbitrary vault-file editor. The iOS 26 target is an experimental compatibility shell and must not be described as released.

The application runtime has no account, server, telemetry, remote font, CDN, or network API. External sync remains outside Knot. Never claim that file coordination provides distributed consensus or that all providers use a particular conflict-file convention.

## Source Of Truth

`project.yml` owns targets, deployment values, entitlements, version, and build settings. Never edit generated `Knot.xcodeproj`, generated Info plists, Gutenberg `dist`, `node_modules`, or build output. Direct npm and Swift dependencies are exact and lockfiles are tracked.

```text
Knot/Shared/
  EditorModel.swift            quick orchestration and persisted capture snapshots
  EditorModel+Rich.swift       rich promotion, checkpoints, durable enqueue
  EditorView.swift             native quick capture
  OnboardingView.swift         resumable five-step setup UI
  SettingsView.swift           transactional settings UI

Knot/macOS/
  KnotMacApp.swift             process and regular-window ownership
  MenuBarController.swift      status item, popover, detach/reattach
  SurfaceCoordinator.swift     activation policy and regular/accessory surfaces
  RecoveryView.swift           drafts, pending work, uncertain outcomes
  GutenbergEditorWindowController.swift
                                WKWebView lifecycle, schemes, typed native bridge
  RichCheckpointTransferStore.swift
  Hotkey/                      transactional Carbon shortcut adapter
  GutenbergWeb/               TypeScript Gutenberg source and locked tests

Packages/KnotKit/Sources/KnotKit/
  Domain/                      typed IDs, immutable snapshots, validated settings
  Formatting/                  compiled date and bullet formats
  Markdown/DailyDocument.swift byte-range daily-note parsing and insertion
  Persistence/                 GRDB store, migrations, drafts, assets, recovery
  VaultIO/                     access lease, validated paths, browser, one writer
  Configuration/               safe Obsidian import proposals and field diffs

Tests/KnotMacOSTests/           hosted native and bundled-resource tests
rewrite-evidence/              audited baseline and retained evidence
scripts/                       reproducible build, verification, benchmarks, release
```

The pre-rewrite `Vault`, `DailyAppender`, `InboxWriter`, `AttachmentWriter`, JSONL `Queue`, recursive `VaultStructure`, regex heading splicer, and duplicate Obsidian importer were removed. Do not reintroduce a second production writer, parser, or queue.

## Ownership Boundaries

`CaptureStore` is the durable local authority. It is a Swift actor backed by one GRDB `DatabaseQueue`, schema version 1, foreign keys, WAL, `synchronous=FULL`, and a 5-second busy timeout. It owns revision checks, immutable capture snapshots, capture state transitions, staged-asset references, mutation records, receipts, quarantine, and migration records.

`VaultGateway` is the only production vault writer. It serializes a capture commit, holds a `VaultAccessLease`, prepares a mutation plan, records that plan before publication, publishes assets before the note, records identities and hashes, and stores a receipt. An uncertain outcome moves to `needsReview`; it must never become a blind retry.

`BookmarkVaultAccessProvider` owns balanced security-scope lifetime and stale-bookmark refresh. Test code uses `DirectoryVaultAccessProvider`. Views do not resolve bookmarks or construct vault file URLs.

`SafeFileSystem` coordinates the authorized root, opens that root and every descendant descriptor-relative with `O_NOFOLLOW`, checks root/device/inode identity, rejects symlinks and multiply linked regular files, writes an exclusive temporary file, fsyncs file and parent, and uses no-clobber rename for new targets. Never replace this with standardized-path prefix checks or check-then-write URL APIs.

`DailyDocument` performs bounded UTF-8 parsing and byte-range insertion. Preserve BOM and line-ending style, and leave unaffected bytes identical. Heading detection must distinguish actual ATX headings from fences, indentation, quotes, list content, Setext syntax, and closing hashes.

`VaultBrowser` lists immediate visible directories only. Entering a child is navigation, not selection. Results are generation-scoped so a late request from a previous vault cannot publish into the current session.

`EditorModel` checkpoints native edits after 150ms and flushes on blur, resign-active, and termination. Send captures the current draft revision, profile, settings revision, route, timestamp, timezone, locale, document, and assets before local acknowledgement. Completion may clear only the same source revision; newer typing must survive.

## Rich Editor Trust Boundary

The editor is a bundled, nonpersistent `WKWebView` loaded only through `knot-editor://`. `EditorBundleManifest` verifies every production resource against its hash and injects a nonce into the fixed CSP. There are no runtime external resources.

All native/web messages use the versioned envelope in `GutenbergWeb/src/protocol.ts`. Native validates the main frame, exact entry origin, protocol/session/draft/request IDs, JavaScript-safe revision, type, payload shape, byte limit, request replay, asset ownership, and checkpoint revision. Standard messages are limited to 256 KiB. Document and asset transfers are ordered, bounded, hashed, and expire.

Never interpolate Markdown into JavaScript. Use the fixed dispatcher and structured `callAsyncJavaScript(arguments:)`. Never accept a vault path from JavaScript. External URLs may open only from WebKit's direct `.linkActivated` navigation action and only for validated `http`, `https`, or nonempty `mailto`; the `openExternal` bridge message is denied.

Rich Markdown conversion uses mdast/micromark with GFM/frontmatter extensions. Supported syntax becomes semantic blocks. Unsupported source is retained in typed opaque blocks and remains exportable. HTML paste goes through a parsed sanitizer allowlist. The local `vendor/showdown-safe` adapter exists only to neutralize WordPress's unpatched raw-paste dependency; Knot's Markdown codec does not use it.

Assets are staged in the private store, content-validated, size/pixel bounded, hashed, and owned by a draft before they receive an opaque AssetID. `knot-asset://` previews validate session and ID. At publication, replace only parsed image destinations, never arbitrary matching text.

## Settings And Migration

`ValidatedSettings` schema version 1 is the persisted contract. Paths are typed `VaultRelativePath` values; root is valid. Formats are compiled before persistence. Settings Apply uses an expected revision, Cancel discards the working copy, and import Undo changes only fields represented by `ConfigDiff`.

Onboarding is a durable transaction. Only Finish activates the profile. Reset marks the old profile inactive and begins a new session while preserving drafts, pending captures, assets, and vault files.

Legacy preferences and `knot-queue.jsonl` are copied into verified migration backups. Invalid settings fields are repaired individually and reported. Legacy queue rows are quarantined with raw bytes and source offsets because they lack safe vault/settings context. Migration keys are idempotent; do not delete source material automatically.

## UI Invariants

- Keep quick capture native and immediately focusable.
- Ordinary Return inserts a newline; Command-Return and Control-Return send.
- Escape hides the quick surface without erasing the draft.
- Clear goes through the native text system so Undo works.
- `Pending` means durable local enqueue; `Saved to vault` means receipt-backed publication.
- `Needs review` requires explicit user resolution with a duplicate warning for retry-as-new.
- Root-folder selection, missing-heading policy, hotkey disable, and imported bare-key approval remain explicit controls.
- Settings, Recovery, rich editor, popover, and detached window keep one coherent draft owner.

## Build And Verify

The audited implementation uses Xcode 27 beta through a command-scoped `DEVELOPER_DIR`; never mutate global `xcode-select`.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./bootstrap.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/verify.sh --quick
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/verify.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/KnotKit
```

Performance and true two-process checks:

```sh
./scripts/perf-fixtures.sh --output /tmp/knot-perf-fixtures
./scripts/benchmark.sh --fixtures /tmp/knot-perf-fixtures --runs 30 --cache warm
./scripts/two-process-vault-test.sh
./scripts/rich-ready-benchmark.sh --app /path/to/Knot.app --runs 30 --cache cold
```

`scripts/verify.sh` performs handoff validation, deterministic dependency/notices comparison, offline supplemental npm audit, locked web install/typecheck/tests/build, dependency security inspection, Swift tests, the two-process publication test, XcodeGen, macOS Debug/runtime probe/hosted tests/Release, binary version comparison, and the iOS compatibility build.

The offline npm audit is cache-only and is not evidence of current registry advisory status. `scripts/dependency-security.mjs` verifies the reviewed vulnerable transitive graph is absent and checks the shipped bundle. Keep `THIRD_PARTY_NOTICES.md` synchronized with `Package.resolved` and `package-lock.json` through `scripts/dependency-report.mjs`.

## Release

`scripts/release.sh` must stay fail-closed. It requires a clean tree, exact version tag at HEAD, explicit Developer ID identity and team, working notary profile, full verification, measured performance, successful archive/export, strict code-sign verification, accepted notarization, stapling, Gatekeeper assessment, mounted-artifact verification, checksum, source SHA, dependency manifest, notices, and release notes.

Never move a release tag, commit, push, publish, sign, notarize, or describe an unsigned app as production-ready without explicit user authorization and actual evidence.

## Editing Rules

- Prefer existing typed domain values and actor interfaces.
- Keep first-party Swift under complete strict concurrency.
- Use injected providers and disposable fixtures; never use a real vault, user defaults suite, note content, bookmark, credential, or signing secret in tests.
- Keep diagnostics to IDs, bounded categories, and timings. Do not log document text or raw user paths.
- Scale tests with data-loss and containment risk. Changes to persistence, path handling, publication, bridge validation, or migration require failure-path coverage through the production interface.
