# Knot: From-Scratch Rewrite Specification

Baseline: `3a4bb5b7ce11463323c13da9442de5e4fd29941f` (`codex/gutenberg-editor`). Written 2026-09-08. Evidence and rationale: [REWRITE_AUDIT.md](REWRITE_AUDIT.md). This is an implementation specification, not a claim that the rewritten app exists.

## 1. Assignment To The Implementing Agent

Rebuild Knot's internals and macOS experience from scratch while preserving the product contract in section 2. Use the baseline as a behavior reference and migration source, not as an architecture to wrap in more layers. Complete the numbered implementation phases and acceptance gates below. Do not stop after a visual prototype or after the existing 100 core tests pass.

The first deliverable is a macOS application. Keep the iOS target building against shared contracts and label it experimental; do not expand this into an iOS launch. Preserve the existing bundle identifier, sandbox entitlements, preferences migration, vault format, app identity, and license. Do not add telemetry, accounts, network-dependent editing, Knot-specific sync, a vault-wide note browser, widgets, or a share extension.

Work on an implementation branch from the audited commit or a newer user-designated base. If the checkout has newer changes, inventory and preserve them before replacing modules. Do not reset a dirty checkout, overwrite a user vault, or use real preferences in tests. Commit logical milestones only when asked to commit; never publish a release or move an existing tag merely to satisfy a test gate.

The decisions below are defaults that let an agent implement without product clarification. Security checks that reject previously unsafe input are intentional corrections, not features to preserve. Any deviation must name the requirement, reason, replacement behavior, and tests in `IMPLEMENTATION_NOTES.md`. A documented omission does not count as completion of a required gate.

## 2. Product Contract

### 2.1 Preserve These Capabilities

| Capability | Required replacement behavior |
| --- | --- |
| Native quick capture | Menu-bar status item, immediate text focus, keyboard send, mouse send, no WebKit dependency on this path |
| Routing | Default automatic Today/Inbox decision; explicit Today and Inbox overrides; add a way back to Auto without sending |
| Today | Append a formatted capture to the configured daily file; create the file/selected heading when appropriate |
| Inbox | Create a standalone Markdown file in vault root or any nested folder; never overwrite an existing note on a collision |
| H1 filename | A first-line `# Title` with 1-7 whitespace-delimited words supplies a sanitized Unicode-preserving filename; remove that H1 from the body, retain date-based parent subfolders; otherwise use formatted timestamp |
| Folder paths | Root is valid. Existing nested folders are browsable. Explicitly confirmed new nested folders are creatable. Date patterns may generate subfolders. |
| Daily configuration | Periodic Notes import with precedence over Core Daily Notes when enabled/valid; editable folder, filename pattern, target heading, and bullet template |
| Import controls | Show source and changed fields; Dismiss and field-scoped Undo remain available |
| Attachments | Preserve vault-root, vault-relative, beside-note, and beside-note-subfolder destinations imported from Obsidian app.json |
| Rich capture | Optional Gutenberg window, promotion of quick text, paragraphs/headings/lists/quotes/code/separators/images, formatting, image paste/drop/picker, Markdown Inbox save |
| Global shortcut | Default Control-Option-K, configurable recording, conflict feedback, disable option |
| Window behavior | Popover, explicit detach/reattach, drag by a dedicated handle, saved detached geometry, reliable reopening/focus |
| Settings | Editable after onboarding; reset restarts setup without deleting unsent work or vault data |
| Offline operation | Local-only. Failed vault writes remain recoverable locally, visibly pending, and tied to their original vault and capture date |
| Obsidian independence | A folder without .obsidian is permitted after confirmation. Do not launch Obsidian or require plugins to capture. |

The rich editor remains an Inbox composer, not an arbitrary existing-vault-file editor. A small local Drafts/Pending recovery surface is allowed because it exposes Knot's own unsent work, not a vault index.

### 2.2 Defaults And Validation

Preserve these defaults for fresh settings, while onboarding may adopt imported values before confirmation:

| Setting | Default | Validation / persistence |
| --- | --- | --- |
| dailyFolder | `Daily` | Valid vault-relative folder; empty means root |
| inboxFolder | `Inbox` | Same |
| dailyFilenameFormat | `YYYY-MM-DD` | Compiled Moment-compatible pattern, no extension in settings; bounded valid generated relative path |
| inboxFilenameFormat | `YYYY-MM-DD HHmm` | Same; H1 title overrides final basename only |
| daily target | Heading `## Quick notes` | Typed target, not a blank-string sentinel; allow explicit end-of-note |
| dailyBulletFormat | `- {{HH:mm}} {{content}}` | At least one exact content placeholder; bounded valid token grammar |
| routingMaxChars | 280 | Integer 1-100000; count Swift extended grapheme clusters after trim for routing only |
| routingRequiresSingleLine | true | Treat LF, CRLF, lone CR, Unicode line/paragraph separators as line breaks |
| attachmentFolderPath | empty | Root; `/` aliases root, `.` aliases note parent, `./assets` means note-parent-relative, other paths vault-relative |
| global shortcut | Control-Option-K | Optional structured shortcut; keycode zero is a valid key, not disabled |
| appearance | System | System colors, contrast, scrollbar, motion and text preferences |

Whitespace-only captures are rejected, but do not trim the actual nonblank Markdown body on send. Preserve indentation, trailing spaces used for Markdown line breaks, and CRLF source where possible. An H1-only Inbox capture deliberately creates a title-named empty body, preserving baseline behavior. An image-only rich capture is nonempty if it has a durable attachment reference.

For manual Today on multiline content, retain the override: expand the template per capture, then indent continuation lines consistently beneath the bullet (default two spaces). Show a preview in Settings. Do not split one capture into multiple independently retried records.

### 2.3 Reliability Contract

1. Acknowledged local capture means the immutable capture and all required assets are durably stored in the app container. `Saved to vault` means publication completed and the journal recorded the receipt. Never use these labels interchangeably.
2. A send snapshots draft revision, vault identity, settings revision, resolved mode, capture time, timezone, locale, and asset IDs. Retry does not reinterpret these using current settings or today's date.
3. New text typed while an older revision is sending must survive that operation's completion. Window closure, reset, app relaunch, and WebKit termination must not silently discard checkpointed work.
4. Existing file bytes are never replaced after a failed read, decoding error, unsafe path check, or uncertain reconciliation.
5. No operation can write outside the selected vault merely because settings, an imported path, a date pattern, a symlink, or a web message asks it to.
6. File coordination protects cooperating local access; it is not distributed consensus. After a crash or an external modification that makes commit outcome uncertain, stop and offer review instead of blindly appending again.

## 3. Architecture And Ownership

Retain XcodeGen and a `KnotKit` Swift package with no UI imports. Organize that target internally rather than creating a package per small type. Mac-specific bookmark, AppKit, hotkey, and WKWebView adapters live in the app target. Shared orchestration may stay in `Knot/Shared` where it has no AppKit dependency. Pure Markdown/file-domain behavior and durable storage belong in KnotKit.

```text
Packages/KnotKit/Sources/KnotKit/
  Domain/             IDs, Draft, Capture, VaultProfile, Settings, errors
  Formatting/         Routing, TitlePolicy, DatePattern, BulletTemplate
  Markdown/           DailyDocument, HeadingTarget, source-range insertion
  Persistence/        CaptureStore, Schema, Migration, MutationJournal
  VaultIO/            ValidatedPath, CoordinatedIO, VaultWriter, Assets
  Configuration/      ObsidianConfigReader, ConfigDiff
Packages/KnotKit/Tests/KnotKitTests/
  Domain/ Persistence/ VaultIO/ Markdown/ Migration/ Fixtures/
Knot/Shared/
  AppModel.swift      presentation snapshots, not raw file operations
  CaptureController.swift
  OnboardingCoordinator.swift
  SettingsModel.swift
  EditorView.swift    quick editor controls and accessible status
Knot/macOS/
  AppCoordinator.swift
  VaultBookmarkAdapter.swift
  SurfaceCoordinator.swift
  NativeTextEditor.swift
  Hotkey/
  RichEditor/         window, bridge, bundle scheme, asset scheme
  GutenbergWeb/      TypeScript source, locked deps, tests, generated dist
Knot/iOS/             compatibility shell, experimental
Tests/KnotMacOSTests/ Tests/KnotMacOSUITests/
Fixtures/             shared JSON and Markdown conformance corpus
scripts/              verify, build-web, release, perf-fixtures
```

The file layout is a target design, not a demand for empty files. Keep tightly related small types together. Delete obsolete writer/parsing implementations when their replacements are integrated; do not retain two production write paths. `Vault.write` may remain a compatibility facade for iOS while forwarding through the same tested capture pipeline.

### 3.1 Module Interfaces

| Module | Caller's interface | Hidden responsibilities |
| --- | --- | --- |
| CaptureStore | checkpoint draft; enqueue snapshot; observe pending; acknowledge/reconcile; migrate | SQLite transactions, schema, asset references, revision checks, retention |
| VaultGateway | inspect profile; list immediate children; read daily structure; commit queued capture | Security scope, worker scheduling, path containment, coordinated I/O, mutation journal |
| CaptureController | update draft; choose mode; submit; retry; review uncertain outcome | Snapshot creation, local acknowledgement, per-vault ordering, presentation events |
| OnboardingCoordinator | begin(reason); choose vault; navigate/select folder; choose daily target; finish/back/cancel | Resumable transaction, request generations, import proposals, commit |
| SettingsModel | edit working copy; validate/preview; apply; cancel; reset configuration | Versioned validation, field diffs, migration notes, hotkey registration transaction |
| SurfaceCoordinator | show quick; detach/reattach; show settings/rich; restore | Window ownership, activation, focus, geometry, presentation transfer |
| RichDocumentCodec | Markdown to supported block representation; blocks to Markdown or typed error | Parser adapters, opaque source blocks, escaping, image references, fidelity checks |

No view constructs a file URL, instantiates a writer, reads UserDefaults directly, parses headings, or creates a detached write task. Dependency injection is limited to things that genuinely vary: production versus fixture filesystem/bookmarks, real versus controlled clock, real versus fault-injecting persistence, and system versus fake hotkey registrar.

Use Swift 6 complete concurrency checking for first-party code. Prefer immutable `Sendable` values and actors for mutable controller/store state. Do not silence warnings with project-wide `@preconcurrency` or `@unchecked Sendable`; a narrow framework wrapper requires a documented queue/ownership invariant and a concurrency test. Do not assume an actor makes blocking filesystem work suitable for a cooperative executor.

### 3.2 Dependency Decisions

Use GRDB with system SQLite for the durable capture store, Swift Markdown for native structural parsing, and mdast/micromark parsing plus mdast serialization for rich-document conversion. GRDB supplies transactions and migrations; Swift Markdown is backed by cmark-gfm. These remove complex persistence/grammar code from the app's own implementation. [GRDB](https://github.com/groue/GRDB.swift), [Swift Markdown](https://github.com/swiftlang/swift-markdown).

Retain Gutenberg and React, with Vite for the bundled editor, but convert the bridge and serializer to TypeScript. Use `mdast-util-from-markdown`, `mdast-util-to-markdown`, and explicit frontmatter/GFM extensions; do not render arbitrary Markdown HTML as active DOM. Preserve unsupported Obsidian syntax as source instead of assuming a generic Markdown library understands it. [Parser](https://github.com/syntax-tree/mdast-util-from-markdown), [Serializer](https://github.com/syntax-tree/mdast-util-to-markdown).

At phase 0, resolve stable versions compatible with the selected Xcode/Swift and Node LTS toolchains, then pin exact direct versions and commit npm and Swift lockfiles. Record versions and licenses. Do not use `latest`, floating branches, runtime CDNs, or remote fonts. Keep the WordPress dependency family coherent; isolate any unavoidable unstable/private import in one adapter with a schema test and a documented pinned version. Do not add another state-management or dependency-injection framework.

## 4. Domain Model And Persistence

Use explicit UUID wrappers for `VaultID`, `DraftID`, `CaptureID`, `AssetID`, `OperationID`, and a monotonically increasing `Revision` per draft/profile. Names and paths are labels, not identity. A bookmark's bytes may change while the vault identity remains the same.

```swift
enum RoutingChoice: Codable, Sendable { case automatic, today, inbox }
enum DailyTarget: Codable, Sendable {
    case endOfNote
    case heading(HeadingSelector, missing: MissingHeadingPolicy)
}
enum MissingHeadingPolicy: Codable, Sendable { case createAtEnd, ask }
struct CaptureSnapshot: Codable, Sendable {
    let id: CaptureID
    let draftID: DraftID
    let draftRevision: Int64
    let vaultID: VaultID
    let settingsRevision: Int64
    let settings: ValidatedSettings
    let createdAt: Date
    let timeZoneIdentifier: String
    let localeIdentifier: String
    let destination: ResolvedDestination
    let document: CaptureDocument
    let assetIDs: [AssetID]
}
```

This sketch defines the data contract, not compilable drop-in code; implement all referenced types with validation at initialization/decoding. `CaptureDocument` stores exact Markdown source plus optional versioned block JSON and opaque-source mapping. Avoid a second independently editable source of truth: the active representation owns edits and changes revision; conversion must produce a checked new revision.

### 4.1 Storage Layout

Store under the sandboxed Application Support/Knot directory, using Foundation's container-aware lookup, not a hardcoded home path:

```text
Knot/
  captures.sqlite        plus SQLite-managed WAL/SHM files
  assets/<AssetID>/original
  staging/<OperationID>/...
  migration-backups/<MigrationID>/...
```

Do not put app state inside the vault. Do not silently fall back to a temporary directory. If local durable storage is unavailable, keep the live draft, show the error and provide Copy/Export; do not clear it or claim local durability. Set restrictive container file permissions; do not log note bodies, paths, bookmarks, block JSON, or attachment contents. OS-level disk encryption remains the user's environment, not an app guarantee.

Use a GRDB `DatabaseQueue`, foreign keys, WAL mode, and durable synchronous policy for enqueue/receipts. Use GRDB migrations, not manual JSON rewriting. The database is small: no full-text search or generic event store is needed.

| Table | Required columns and constraints |
| --- | --- |
| vault_profiles | id PK, display_name, bookmark BLOB, resource_identity BLOB?, settings_version, settings_revision, settings_json, onboarding_state, created_at, updated_at |
| onboarding_sessions | id PK, profile_id nullable FK, generation, step, working_settings_json, proposed_bookmark, import_diff_json, browser_state_json, updated_at |
| drafts | id PK, profile_id nullable FK, revision, representation_version, markdown BLOB, blocks_json nullable, opaque_sources_json nullable, routing_choice, selected_range_json, updated_at, state |
| captures | id PK, draft_id, draft_revision, profile_id FK, immutable_snapshot_json, state, attempt_count, next_attempt_at nullable, last_error_code nullable, created_at, committed_at nullable; unique(draft_id,draft_revision) |
| assets | id PK, local_relative_path unique, original_name, media_type, byte_count, sha256, width nullable, height nullable, state |
| draft_assets / capture_assets | owner_id + asset_id composite PK, FK relationships; no referenced-asset deletion |
| mutations | operation_id + sequence PK, capture_id FK, kind, relative_target, before_hash nullable, after_hash, before_blob nullable, after_blob, phase, published_resource_id nullable |
| receipts | capture_id PK, note_relative_path, note_hash_at_commit, committed_at, asset_results_json |
| migration_records | migration_key PK, source_hash, completed_at, report_json |
| quarantined_records | id PK, source_name, byte_offset, raw_bytes, error_code; explicit recovery state |

JSON/BLOB fields have versioned Codable/TypeScript schemas; enforce byte limits and enum validation when decoding. SQL schema checks constrain legal state values and nonnegative revisions/counts. State transitions and revision checks are transactional. Do not keep a database transaction open while waiting for file coordination or WebKit.

Checkpoint native draft edits after a 150ms debounce, and flush on send, blur, close, promotion, app resignation, and orderly quit. Show an unobtrusive unsaved-local state until the checkpoint succeeds. Abrupt termination before the latest debounce can lose up to that unacknowledged interval; do not promise otherwise. Retain acknowledged captures/receipts for seven days, then purge bodies and owned local assets no longer referenced. Pending/uncertain/quarantined work has no automatic expiry. Provide an explicit local-data deletion control separate from configuration reset.

### 4.2 Capture State Machine

```text
draft --durable enqueue--> pending --worker claim--> preparing
preparing --journal durable--> committing --receipt durable--> committed
preparing/committing --known no-write failure--> retryableFailure
preparing/committing --outcome not provable--> needsReview
pending/retryableFailure --access unavailable--> waitingForVault
pending/retryableFailure --user cancels before mutation--> cancelled
```

Only one active writer per vault. Duplicate send commands for the same draft revision return the existing CaptureID. While pending, the same unchanged revision has a Pending/Retry control, not a second Send that generates another ID. If the user explicitly chooses Send Again after success, create a new draft revision and capture ID.

A successful enqueue acknowledges only the captured revision. Clear the editor only if it still displays that revision; otherwise retain the newer revision exactly. A status timeout also carries its operation ID so it cannot overwrite newer feedback. Reset or vault switch increments a session generation; old completions can update their original stored capture, never clear/reconfigure the new UI session.

Retry known transient no-write errors on launch/reconnect and at 1s, 5s, 30s, 2m, then at most every 5m while active, with bounded jitter. Do not keep waking an idle app forever. Permission errors, invalid configuration, missing headings with ask policy, and uncertain outcomes require action. Retry in original order per vault. If Today capture A is uncertain, pause later Today writes to the same daily path until A is resolved; other safe Inbox captures may proceed.

## 5. Vault Access And File Mutation

### 5.1 Access Lifetime And Scheduling

The macOS adapter resolves a security-scoped bookmark on a utility worker, acquires access, validates the root, refreshes a stale bookmark while access is active, and releases access after the last coordinated operation finishes. Balance successful scope acquisition even on cancellation/error. Treat a failed acquisition as permission failure for external user-selected vaults; test container-local fixture access separately. The caller never receives a naked URL that implies continuing access. [Apple security-scoped URLs](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource%28%29?changes=l_10).

Use bounded utility `OperationQueue`s: one serialized mutation queue per active vault, at most two read workers globally, and one separate serial database queue. Configuration imports, bookmark probes, directory enumeration, daily reads/parsing, hashing, image decoding, and base64 fallback decoding must not execute on MainActor. UI state publication returns to MainActor with `(VaultID, generation, requestID)` validation.

Create NSFileCoordinator per operation; use a single coordinated batch for related intents and only accessor-provided URLs. Finish actual file access before leaving the accessor; do not launch nested async work from it. Coordination applies to cooperating presenters, not arbitrary cross-device writers. [Apple file coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator?changes=_7), [asynchronous coordinated access](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate%28with%3Aqueue%3Abyaccessor%3A%29?changes=_3%2C_3).

Cancellation before mutation may stop work. After publication starts, cancellation means detach UI interest and reconcile, not pretend nothing happened. Show slow-operation state after 500ms and provider-wait state after 5s; use coordinator cancellation where supported, but do not claim an elapsed UI timeout forcibly stopped a filesystem write. Keep at most one provider-blocked operation per vault; do not grow unbounded detached tasks on repeated clicks.

Probe classifies: usable, readOnly, temporarilyUnavailable, missing, bookmarkDenied, malformedBookmark, or unconfigured. A missing .obsidian directory is a warning, not inaccessible vault. Avoid automatic write probes during every popover open; check capabilities without mutation, then handle real write errors. Use an explicit temporary write probe only after the user chooses Test Access, with coordinated unique-file creation and cleanup.

### 5.2 Path Policy

Represent vault-relative paths as validated component arrays. Folder root is an empty array. Reject NUL/control characters, `..`, absolute paths, drive/UNC forms, ambiguous separators, empty terminal filenames, and invalid generated components. Treat slash as the only supported stored separator. Normalize the permitted attachment aliases before validation. Do not percent-decode a filesystem component into a different path after validation.

Validate both settings input and the final output of filename formatting. For existing names, preserve Unicode spelling; detect collisions using actual filesystem behavior, not only case-sensitive strings. For newly generated basenames, sanitize baseline-invalid characters, preserve readable Unicode, strip unsafe trailing dots/spaces, escape Markdown link delimiters, and truncate by UTF-8 byte budget without splitting a character. Reserve suffix and `.md` space within the volume's component limit; append a short deterministic hash when truncation is needed. Validate again after suffixing. Existing unusual names may be selected if safely addressable; otherwise show a precise error rather than silently selecting root.

Resolve the chosen vault root's actual identity once under bookmark access. Descendant directory/file symlinks and alias traversal are disallowed by default, even when their target happens to be inside the vault. Display such folders disabled in the picker with a reason. Use descriptor-relative traversal (`openat`/`fstatat`, no-follow flags) and verify each directory component plus the final target; a string-prefix or one-time `resolvingSymlinksInPath` check alone is insufficient. Revalidate accessor URLs and root identity after file coordination grants access. Do not mutate multiply hard-linked daily files; return a reviewable unsupported-target error.

Where Foundation coordination and low-level publication meet, keep the validated open parent descriptors and coordinated URLs consistent. Test renamed directories, symlink swaps, case-insensitive volumes, and parent substitution. On providers that cannot satisfy the safe publication primitives, fail safely and retain Pending, rather than silently falling back to an overwrite. This protects against malicious path input and common local races; it is not a claim of protection against a privileged hostile process controlling the filesystem.

### 5.3 Durable Mutation Algorithm

All plain and rich writes enter this one algorithm:

1. Claim a durable capture. Resolve its original profile and frozen settings. Verify staged asset hashes. Do not read current editor text.
2. Acquire vault access and coordinated intents on the worker. Validate destination parents; create required directories through coordinated, no-follow operations. Directories alone may remain after failure, but no note content is lost.
3. Read target bytes under coordination. Missing file is distinct from an unreadable file. Decode existing daily Markdown strictly as UTF-8 with optional BOM; preserve BOM and newline conventions. On other encodings, stop with Export/Open choices, not lossy conversion.
4. Calculate candidate mutations in memory: final relative paths, exact before/after bytes and hashes, asset links, and note body. Recheck cancellation before any publication.
5. Persist the mutation journal durably BEFORE publishing. A private synchronous journal writer may call the shared GRDB DatabaseQueue from the utility accessor. Keep each DB transaction short and never call filesystem coordination from a DB transaction/callback; this lock ordering prevents inversion. Public CaptureStore calls remain async. Do not attempt `await` inside a synchronous coordinator accessor.
6. Write and flush same-directory temporary files with unique operation-owned names. For new files publish using an exclusive/no-replace primitive, such as Darwin `renameatx_np` with `RENAME_EXCL`; verify OS/provider support. Never use `.forReplacing` as a uniqueness mechanism. On Inbox collision, choose the next ` (N)` suffix and durably update the plan before publication. Asset collision allocation follows the same rule.
7. For a daily replacement, recheck the observed identity/hash, preserve supported permissions/metadata, and atomically replace inside coordination. Keep the old bytes in the short-lived journal for reconciliation. Use fsync/appropriate platform flushes for temporary files and parent metadata; propagate failure. Document provider/power-loss limitations, not universal durability claims.
8. Publish referenced assets before the note, then publish the note with final links. This is a recoverable multi-file operation, NOT an atomic transaction across all files. Mark each mutation as published with identity/hash; finally store the receipt and committed state in one DB transaction.
9. Release coordination/scope and update the originating UI with the CaptureID/revision receipt. Only then say Saved to vault. Clean operation-owned temporary files after successful reconciliation.

Filename counters change the basename, not the frozen date-derived parent path. If a replan does change a parent, regenerate all beside-note attachment locations and embeds before note publication. No direct public `InboxWritePlan(fileURL:body:)` bypass is permitted.

Crash recovery examines journal state and current bytes: if the target equals planned after-hash, mark that mutation done; if it still equals before-hash (or remains absent for a create), resume safely; if it differs, mark needsReview. Do not infer success from a matching bullet substring. If a receipt was not durably stored, do not simply replay the append. Show intended capture and current target for user resolution, with Open, Export, Mark Already Saved, and explicit Retry As New commands.

Retain and reuse previously published owned assets only when path and hash still match. Never remove arbitrary files from the vault during recovery. Automatically delete only private staged files with no live references. Offer cleanup of clearly journal-owned orphaned vault assets as an explicit reviewed action; other applications may already reference them.

### 5.4 Daily Markdown Algorithm

Parse structure with Swift Markdown and a small frontmatter-aware wrapper. Keep the original byte buffer. Mask initial YAML/TOML frontmatter for structural discovery while preserving offsets; never execute frontmatter or template code. Recognize ATX levels 1-6 and Setext headings in document flow; exclude fenced/indented code, blockquotes, list-contained headings, HTML blocks, and frontmatter from selectable daily sections.

Each discovered heading includes level, display text, source spelling, ancestor path, occurrence index among equal siblings, source range, and document fingerprint. UI IDs include occurrence, not just raw text. Store a `HeadingSelector` with semantic title/level/ancestor path plus occurrence and sample fingerprint. On a future day, resolve by title/level/path; use occurrence only if unambiguous. If duplicate structure changed, ask instead of choosing the first match. Migrated single-heading settings can resolve directly when unique.

Find section end at the next document-flow heading of equal or smaller level; deeper subheadings belong to the section, preserving baseline placement at the section's end. Insert one formatted capture at that boundary with the existing document's newline sequence and sufficient blank separation. End-of-note mode appends without creating a heading. If the chosen heading is absent and policy is createAtEnd, add the configured heading at EOF; ask policy leaves the capture pending.

Convert parser line/column locations into UTF-8 byte ranges with explicit tests for tabs, emoji, combining marks, CRLF, and BOM. Do not assume String indices, UTF-16 NSTextView offsets, and parser offsets are interchangeable. Never serialize the whole existing AST. Unmodified bytes before/after the insertion must remain identical, including frontmatter, hard breaks, code indentation, and trailing content. Assert that the resulting mutation actually contains the capture at the intended insertion range; a blank selector cannot return silent success.

## 6. Settings, Import, And Migration

### 6.1 Formatting And Settings

Compile date patterns once into immutable tokens and literals. Preserve all baseline-supported tokens: `YYYY YY Q Qo MMMM MMM MM Mo M DDDD DDDo DDD DD Do D dddd ddd dd do d E ww wo w HH H hh h kk k mm m ss s SSS SS S A a Z ZZ X x`, plus bracket literals and `/` subfolders. Add explicit ISO-week tokens `GGGG GG WW W Wo` because imported week-based paths commonly require them. Test week-year boundaries against reference fixtures; do not implement tokens using guessed DateFormatter substitutions.

Unknown alphabetic tokens or unmatched brackets produce validation diagnostics, not silently altered filenames. Legacy free text that is intended literal can be bracket-escaped through an explicit previewed correction. Preserve known previous DateFormatter-default migrations (`yyyy-MM-dd`, `yyyy-MM-dd HHmm`) and do not automatically reinterpret arbitrary custom patterns. Default locale remains `en_US`, calendar Gregorian, timezone captured from the current system at send. Add fixtures for DST, December/January week years, leap days, and locale/timezone changes during retry.

Parse bullet templates with a single-pass bounded parser. `{{content}}` is literal insertion and cannot be interpreted as another template. Other placeholders compile date tokens. At least one content placeholder is mandatory; malformed syntax is a validation error. Preview filename, relative destination, and complete example bullet using an injected date. The preview and writer use the same compiled representation.

Settings edits use a working copy. Apply validates and persists a revision atomically; Cancel discards only the working copy. If another window changes settings, detect the base revision mismatch and ask to reload/merge field-level edits rather than overwriting. Invalid individual legacy fields generate a migration report and a safe editable value; preserve the original raw settings blob. Do not erase all settings because one field is malformed.

### 6.2 Obsidian Configuration

Read only known files under `.obsidian`, via bounded coordinated access (maximum 1MiB per JSON file). Use JSONDecoder/JSONSerialization with typed field validation, not regex. Files may be missing or provider-unavailable; distinguish these from malformed JSON. No recursive vault scan is needed.

Precedence: use enabled Periodic Notes daily settings when their daily section is enabled and usable; otherwise use Core Daily Notes settings when available. If core-plugins.json explicitly disables Daily Notes, mark those stored settings inactive and offer manual adoption rather than silently applying them. If enablement metadata is absent but daily-notes.json is valid, offer it as a proposal with unknown enablement. Import attachmentFolderPath independently from app.json. Invalid imported paths/formats remain visible proposals with errors; they never become writable configuration automatically.

Build a `ConfigDiff` containing source, old value, proposed value and base revision for each field. Show it after vault choice and in Settings on explicit Reimport. Dismiss keeps accepted values. Undo reverts only imported fields that still equal the imported value at the expected revision; it must not revert later manual Inbox, heading, or attachment edits. Clear stale banners when changing vault. Import is one-time on selection or explicit request, not continuously overriding user choices.

### 6.3 Legacy Migration

Migration runs before writes, is idempotent, and does not require the vault to be online. Keep bundle ID `com.p3ob7o.knot` so existing sandbox/bookmark access remains attributable to the same application. Discover existing state through injected UserDefaults and container-aware paths:

| Existing source | Migration rule |
| --- | --- |
| `knot.settings` | Back up raw Data; decode field-by-field into validated versioned settings and a repair report |
| `knot.vault.bookmark`, `knot.vault.name` | Preserve bytes/name in a profile; resolve later under access scope; derive resource identity when available |
| `knot.onboarding.completed` | true + valid settings -> completed profile; false -> resume setup; absent + bookmark -> legacy review, not automatic proof of completion |
| `knot.toggleShortcut` | Migrate modifier/keycode structure; old zero/empty means disabled, but new keycode-zero shortcuts are valid; preserve recognized valid shortcuts |
| `knot.windowDetached`, `knot.windowFrame` | Preserve detached preference; validate all numbers, size, and visible frame before reuse |
| Application Support/Knot/knot-queue.jsonl | Back up byte-for-byte, stream valid lines, quarantine malformed bytes with offsets; migrate to needsReview, not automatic replay |

The old queue does not record vault identity, settings, timezone or attachment bytes. Do not invent those values from current preferences. Show the recovered content/date and ask the user to assign destination/vault and confirm whether it was already saved. Unresolved attachment tokens stay visibly unresolved; offer relinking or Markdown export. Never drop a corrupt line or claim all old captures are intact when bytes are missing.

Store migration completion keys using source hash plus record offset/legacy ID, so rerunning cannot duplicate imports. Complete each migration in a database transaction after writing a verified backup. Keep old preferences/queue untouched until migration reports are available; do not delete them automatically. On migration failure, stop writes, preserve sources and offer export. Rollback to an older app must not replay already-handled old queue entries unknowingly: document the compatibility limitation and preserve a human-readable migration report.

Reset Configuration invalidates active UI generations, flushes drafts, prevents new sends under the old active profile, clears only configuration/hotkey/window preferences, and starts a new incomplete onboarding session. Pending captures retain an inactive old profile and cannot silently move to the new vault. An operation already publishing finishes/reconciles against its old profile. Provide separate explicit actions to reassign pending work and to erase local drafts; never delete vault content as part of reset.

## 7. Sequential Onboarding

### 7.1 Presentation And State

Show setup automatically on true first launch, on configuration reset, and when the saved vault cannot be located. For temporarily offline/read-only vaults show reconnect/status first, with an explicit route into setup; keep old identity and settings. The sequence remains Vault -> Inbox -> Daily folder -> Heading when applicable. Filename-format/import review belongs within the Daily step, not an unrelated extra questionnaire.

Use a native resizable setup window, nominal 520x640pt, minimum 460x560pt where the display permits, clamped to screen visibleFrame with margins. On a small screen, allow the content area to scroll while the footer remains reachable; do not let header/footer squeeze the folder list into two rows. Aim for at least 240pt of folder viewport on an ordinary 800pt-high display. Compact quick capture keeps its own independent dimensions. Use the existing Knot icon/wordmark and semantic native colors, not a marketing page or nested decorative cards.

OnboardingCoordinator owns durable session state; SwiftUI owns only ephemeral focus/hover state. Persist the incomplete session immediately, including step and working values. Back, close, quit, detach, and reopen must not reseed from half-saved production settings. Changing the chosen vault increments generation, cancels prior requests, clears folder/heading cache, and rebuilds dependent proposals while preserving unrelated safe user inputs only when explicitly applicable.

### 7.2 Vault Step

Use NSOpenPanel with an asynchronous completion/sheet where appropriate, choose one directory only, and balance activation ownership through SurfaceCoordinator. Cancel leaves the step and prior session unchanged. After selection, show progress while the worker resolves access and reads config. Display chosen vault name and status; an arbitrary directory without .obsidian is permitted via Continue after a warning. For denied/offline/missing cases provide Retry and Choose Another Folder. Do not launch a recursive scan after selection.

### 7.3 Shared Hierarchical Folder Picker

Use the same tested picker for Inbox and Daily folders:

1. Separate `selectedPath`, `browserPath`, `query`, and `highlightedRow`. Browsing does not change selection.
2. At root show only immediate visible directories, sorted using localized natural comparison with a stable path tie-break. Exclude `.obsidian`, other hidden entries, packages and files; no arbitrary first-500 truncation.
3. Keep the top action outside the scroller: `Use vault root` at root, or `Use <current folder>` inside a folder. Activating it selects that folder but does not advance the wizard. Continue advances after explicit selection/validation.
4. Clicking a child row or pressing Right/Return on a highlighted child enters it and shows only its immediate children. It does not select it. Back/breadcrumb/Left navigates to the parent without losing the previously chosen path.
5. The path text field supports full relative paths. Split parent components from the final prefix, asynchronously resolve/load that parent, and filter its immediate children case/diacritic-insensitively. Do not flatten all descendants. Tab accepts the highlighted component; Escape dismisses suggestions without clearing selected configuration.
6. For an existing exact typed path, offer the top select action. For a missing valid path, offer a distinct `Create <path>` command and confirmation. Do not create directories while merely typing; create only at final validated commit or first capture, with the user's explicit intent recorded.
7. Render all results using List/LazyVStack with stable row IDs. Load metadata in batches if needed; never start a recursive enumerator. A filter scans cached immediate-child names, not disk on each keypress. Cache at most 32 directory listings with a five-minute TTL and key `(VaultID, generation, parent identity)`.
8. Empty folder, no search matches, loading, denied, and provider-unavailable have distinct states. Retry is available; errors are not represented by an empty list. Every late result validates generation/requestID before publication.
9. Keyboard and VoiceOver expose navigation versus selection as distinct actions, announce current path/selection, and preserve focus when results update. Show full path in an accessible label/tooltip when visually truncated.

### 7.4 Daily And Heading Steps

The Daily step shows the imported/default filename pattern with today's relative-path preview and an editable format disclosure. Folder changes recompute this preview using the same formatter as the writer. Read today's note asynchronously only after a valid folder/format selection. Limit automatic structural reads to 8MiB; for larger notes offer explicit analysis (up to 64MiB) on the worker or manual heading entry. Do not cap the directory browser because a note is large.

If today's note has valid headings, show the Heading step with hierarchy/duplicate context and an explicit End of Note option. Preselect a previously configured heading only when it resolves unambiguously; never silently switch to the first heading. Show which file supplied the headings. User selection includes a missing-heading policy (create at end or ask).

If today is absent, consult an explicitly configured static daily template path from the imported configuration, provided it remains within the vault and passes size/path checks; otherwise allow the user to choose a sample daily Markdown note. Do not scan all historical notes or execute Templater/JavaScript. The template is used for heading discovery only in this rewrite; new daily files retain baseline creation behavior unless a separate future template-generation feature is approved.

If no headings exist, proceed with the established default heading creation behavior, while exposing End of Note and manual heading choices in a disclosure. If reading fails, show Retry/Choose Sample/Manual Target, not a success path that silently skips the error. Finish displays a compact destination summary and commits the complete profile/settings/session state in one local transaction. No test note is written as a side effect of onboarding.

## 8. Native Quick Capture And Window UX

Keep the status item and Control-Option-K workflow. The quick surface starts at roughly 440x360pt, with a 140pt minimum text viewport, and may grow within the screen. Detached mode is resizable. Long drafts scroll; controls and status keep stable dimensions. This surface is for work, not product explanation.

Use the NSTextView adapter with a revision-aware binding. Do not assign the whole string for ordinary local edits. Maintain selection, marked text, undo manager and typing attributes; translate UTF-16 ranges correctly. Apply programmatic document replacement only on explicit revision changes, preserving selection when valid. Respect system scrollbar preferences and support standard macOS editing/menu commands.

Command-Return and Control-Return send exactly once; plain Return inserts a newline. Escape hides the popover by default. Preserve the ability to clear using a visible menu command/shortcut with Undo; do not silently clear on Escape. Auto/Today/Inbox uses a segmented control with an accessible current destination label; manual override persists within that draft, then new drafts default to Auto.

SurfaceCoordinator owns all windows and app activation policy. Detach/reattach transfers the same draft/coordinator, not a new view-local state machine. Dragging is restricted to a title/handle region so text selection does not move the window. Settings/rich windows may require regular activation; do not switch to accessory until the last such window closes. Reopening an existing rich window focuses it without rebuilding its document.

Validate saved frames for finite coordinates, positive reasonable sizes and screen intersection. Clamp the whole window and titlebar into a connected visibleFrame, accounting for menu bar/Dock; a one-pixel intersection is insufficient. Test monitor removal, scaling changes and multiple displays. Preserve normal close/reopen and right-click menu actions.

The status area supports idle, checkpointing, locally saved/pending, sending, saved-to-vault, retryable error and needs-review. Error text wraps independently of the Send row and provides relevant Retry, Reconnect, Open or Export commands. Expose last saved destination via a short-lived accessible status and Reveal/Open actions, without logging the path. Persist pending counts across launches; do not show success based only on local enqueue.

Use a compact native recovery window listing only Knot's drafts and pending captures, with vault, date, destination, state and excerpt. Allow reopen draft, retry, export, explicit cancel and uncertain-outcome review. Do not add vault-wide search, tags or analytics. Settings is a normal screen-fitting window with scrollable content and visible Apply/Cancel, not a 1080pt fixed form.

### Hotkey And Accessibility

Represent disabled as `nil`, not keycode zero. Record supported physical keycode plus modifiers and render using the current keyboard layout. Suspend Knot's registration while recording, restore on cancel, and transactionally register the proposed replacement before discarding the old binding. If the proposed combination is the same, perform no registration churn. Persist only after success. Check InstallEventHandler/RegisterEventHotKey return values and release handles on lifecycle teardown.

Default new bindings require Command, Control or Option with a supported key. Existing bare-character bindings are imported but require explicit confirmation before enabling because they can swallow ordinary typing; do not lose the stored value. Record/clear/restore-default actions must be keyboard and VoiceOver operable. Handle ANSI A (keycode zero), non-US layouts, modifier-only events, Escape cancel and conflicts with another app.

Use SF Symbols/native icons, tooltips for unfamiliar controls, system text styles/colors, logical focus order, and accessibility labels/values/hints. Respect Increase Contrast, Reduce Motion, dark/light mode and Always Show Scrollbars. Avoid color-only status. Test keyboard-only operation, VoiceOver, large text, RTL, CJK input and IME composition. No control should truncate its essential command or overlap another control at supported window sizes.

### iOS Compatibility Scope

Keep the existing NavigationStack capture/settings shell, folder document picker and shared onboarding/routing/writing behavior. Use an iOS-specific bookmark/document-picker adapter with in-place access and balanced scope; do not compile AppKit assumptions into KnotKit. Flush drafts on scene inactivity/backgrounding, request bounded UIKit background execution for coordinated writes already in progress, and leave unstarted captures pending when background time expires. Reconcile on the next foreground transition.

Add a generic iOS Simulator build gate and one disposable-directory smoke test for onboarding, Today and Inbox after shared contracts change. Preserve normal rotation, safe-area layout and keyboard dismissal. Do not ship Gutenberg on iOS in this rewrite, remove existing plain capture, or claim Action Button/widgets/Shortcuts integrations that are not implemented. Device/provider behavior, distribution and an iOS launch remain separate explicitly uncompleted release work.

## 9. Rich Editor And Attachments

### 9.1 Lifecycle And Draft Ownership

Create WKWebView only when rich capture is requested. Quick capture remains usable while it loads. A rich session is identified by window session UUID + DraftID + revision. Model states are unloaded, loading, ready, saving(requestID), recovering, failed and closed. Save is disabled until ready, but the source draft remains recoverable if loading fails.

Promotion transfers the same persisted draft to the rich session after a checked Markdown conversion. Native quick capture can then start a new DraftID. Reopening the active rich editor only focuses it. If promoting a different draft while one is open, checkpoint the existing rich draft and explicitly switch it into the local Drafts list before loading the new one; never overwrite unsaved content with current quick text.

Checkpoint block/document revisions to native storage after the same 150ms debounce and on blur/close/save. A close waits for bounded checkpoint acknowledgement; if it fails, offer Keep Open, Export, or explicit Discard. Handle `webViewWebContentProcessDidTerminate` by recreating the host from the last acknowledged checkpoint and reporting any unacknowledged changes. No silent empty replacement. Startup readiness timeout is five seconds with Retry/Open Source Draft; late readiness from an obsolete session is ignored.

### 9.2 Bundled Resources And Trust

Load the actual Vite-built index through a `WKURLSchemeHandler`, e.g. `knot-editor://bundle/index.html`, using a generated manifest of exact permitted resources, MIME types and hashes. Do not choose the first `index-*.js` file and do not construct a separate native HTML shell. Clean dist before build and verify every referenced stylesheet/script/font is bundled.

Use a nonpersistent WKWebsiteDataStore and no arbitrary file read-access directory. Initial HTML has a restrictive CSP: scripts from bundled self only; no unsafe-eval, inline/data/blob script; connect-src none; frame-src none; object-src none; base-uri none; form-action none. Styles may require inline allowances for Gutenberg; scope that exception to style-src and document it. Images may use the asset scheme and narrowly permitted blob previews, not network URLs. Reject top-level navigation other than the exact app entry; reject subframes, popups, downloads, dialogs and external schemes by default.

Message handling checks the originating webview, `frameInfo.isMainFrame`, expected frame URL/security origin, known protocol version, active session and known request IDs before any action. Do not treat a nonce as a replacement for frame/origin checks. Remove handlers on teardown to avoid retention/leaked privileges. External links are opened only through a native explicit-user-action command, allowlisted to https/http/mailto after validation. Never load them into the privileged editor. Do not grant network entitlements for editor assets.

### 9.3 Bridge Protocol

Define matching Swift Codable and TypeScript discriminated unions, with shared JSON golden fixtures and schema version 1:

```typescript
type Envelope<T extends string, P> = {
  version: 1;
  sessionID: string;
  draftID: string;
  revision: number;
  requestID: string;
  type: T;
  payload: P;
};
// Web -> native: ready, checkpoint, saveRequested, assetImportBegin,
// assetImportChunk, assetImportEnd, checkpointBegin, checkpointChunk,
// checkpointEnd, openExternal, editorError.
// Native -> web: initialize, checkpointAck, saveAccepted, saveResult,
// assetImportResult, command, recoverableError.
```

Every request gets one success or structured error response and a timeout path that leaves data intact. Save errors must appear in the rich window, not only in the quick popover. Ignore/diagnose unknown types, stale revisions and duplicate messages without performing I/O. Bound nesting, string lengths, counts and numeric ranges before decoding large payloads. Standard messages are at most 256KiB; document checkpoints can use a bounded chunk transfer for up to 8MiB of UTF-8 source. Permit only one in-flight checkpoint per draft, coalescing to the latest revision.

Implementation details for the protocol:

| Message | Required payload / effect |
| --- | --- |
| ready | bundle build hash and supported protocol versions; native verifies the expected manifest build before initializing |
| initialize | acknowledged revision, Markdown, versioned blocks/opaque-source mapping, permitted AssetIDs, editor capabilities and validation limits |
| checkpoint | baseRevision and nextRevision, complete document representation, selected range and referenced AssetIDs; native validates ownership and commits before checkpointAck |
| checkpointBegin / Chunk / End | transferID, declared total bytes/hash; ordered bounded chunks; end verifies hash/schema before applying one atomic checkpoint |
| checkpointAck | durable revision, canonical document hash, or revisionConflict with current stored revision; no silent last-writer-wins |
| saveRequested | last acknowledged revision and explicit Inbox destination; native enqueues that exact persisted revision, not stale live JavaScript text |
| saveAccepted | CaptureID and local durability state; UI leaves busy mode and displays Pending while a vault operation is slow |
| saveResult | CaptureID, committed receipt with relative target or typed retryable/needsReview error; never clear a different draft revision |
| assetImportBegin / Chunk / End | transferID, original filename, declared type/length/hash, chunk sequence, completion; native chooses AssetID and all filesystem locations |
| assetImportResult | AssetID, safe preview URL, validated metadata, or typed error; no implicit save of the note |
| command | allowlisted formatting/focus/source-mode command and requestID; no arbitrary JavaScript or filesystem command string |
| openExternal | validated URL plus current explicit navigation action context; native confirmation for non-http(s)/mailto schemes is not a bypass of the allowlist |
| editorError | bounded error code and sanitized diagnostic category, never document text or a DOM innerText dump |

Native supplies only session/draft/protocol bootstrap identifiers through a JSON-encoded document-start WKUserScript; the bundled editor can then send ready. Document content is transferred after that handshake. Use structured `callAsyncJavaScript(arguments:...)` or an equivalently encoded fixed dispatcher for native-to-web messages, never interpolate Markdown into executable JavaScript. Native-injected bootstrap is not a reason to allow arbitrary inline scripts in bundled HTML.

Save first flushes/checkpoints the current revision and waits for acknowledgement, then sends saveRequested. Both sides keep a bounded request table (maximum 32 entries/session) and reject late responses from previous sessions. Checkpoint transfers allow at most 8MiB source plus 16MiB block/mapping JSON, 20000 nodes and depth 64; allocate incrementally and discard incomplete transfers after 10 seconds. Standard messages remain 256KiB maximum. Swift revisions must fit the JavaScript safe-integer range. Asset ownership, URL policy and path validation are always enforced natively even if JavaScript already checked them.

For clipboard HTML conversion, pin a proven parser/sanitizer combination such as hast-util-from-html, hast-util-sanitize and hast-util-to-mdast with a fixed allowlist; retain unsafe/unsupported original material only as inert source. Do not hand-roll a tag-removal regular expression.

### 9.4 Markdown Fidelity

Keep native quick Markdown byte-preserving. For rich editing, distinguish supported semantic transformations from untouched opaque source. Parse Markdown to mdast with explicit extensions, then adapt to the pinned Gutenberg block schemas. Nested blocks must be traversed recursively; current quote/list content must not be read solely from legacy string attributes. [WordPress nested-block model](https://developer.wordpress.org/block-editor/how-to-guides/block-tutorial/nested-blocks-inner-blocks/).

Required editable support: paragraphs; H1-H6; ordered lists with start values; unordered and nested lists; blockquotes with nested paragraphs/lists and optional citation; fenced code with language; separators; images with alt/title/caption; strong/emphasis/inline code/links/hard breaks. Adapt block JSON to mdast then serialize with safe Markdown escaping. Use fences longer than any fence run in code; preserve list nesting/continuation indentation. The serialization library does not guarantee arbitrary round-trip identity or sanitize HTML, so those are explicit adapter/test responsibilities, not assumed library features.

Frontmatter, wikilinks, Obsidian embeds, callouts, math, tables or unknown plugin syntax not supported as editable blocks must be retained as opaque source blocks with exact original ranges/text and a Source editing mode. Unsupported block data must produce a preservation block or an actionable conversion error, never empty output. Keep safe Markdown source visible/exportable even when rich conversion fails. Round-trip fixtures assert byte identity for untouched opaque regions and semantic equivalence for supported edits, not indiscriminate normalization of the whole document.

For pasted HTML, use a parser/sanitizer with an explicit tag/attribute allowlist before block conversion; remove scripts, event handlers, dangerous URL schemes, forms and active embeds. Preserve readable text if an element is unsupported. No remote image download. External image URLs remain inert Markdown/source references unless the user imports a local file.

### 9.5 Asset Pipeline

Handle native picker/drop/paste through scoped native file access whenever possible. Stream bytes into private staging, calculate SHA-256, validate declared type against content and record metadata. JavaScript-origin paste falls back to a chunk protocol: begin with bounded metadata, ordered chunks no larger than 176KiB raw (leaving room for base64 expansion and metadata within 256KiB), end with declared length/hash validation. Reject duplicate/out-of-order chunks, stale sessions, oversized totals and unfinished transfers. Never accept a destination filesystem path from JavaScript.

Limits: 25MiB per image, 100MiB total staged assets per draft, 50 images per capture, maximum 40 megapixels decoded; 8MiB Markdown per capture. Larger material is retained as a draft/source export with a clear limit error, not truncated. Validate PNG/JPEG/GIF/WebP/HEIC where supported by the deployment OS; preserve original bytes, bound preview decode, and avoid animating large GIFs by default. Treat SVG/HTML as active content: do not render them in the privileged editor. Offer explicit safe raster conversion or source export instead of silently embedding active markup.

The web layer receives opaque AssetIDs and preview URLs such as `knot-asset://<session>/<AssetID>`, never vault URLs. The asset handler verifies session, draft ownership and type, serves bounded bytes, and denies directory traversal/range abuse. Revoke blob/object URLs when replaced or the session closes; collect abandoned private uploads by reference count and age after recovery, never referenced assets.

At commit the native writer resolves Obsidian destination semantics, selects collision-safe filenames and produces the embed. Retain wikilink-style embeds for ordinary safe vault-relative names. For names with `]`, `|`, `#` or other wiki delimiters, generate a correctly percent-encoded standard Markdown image destination relative to the note, or a sanitized newly generated asset name. Test spaces, Unicode, closing brackets, parentheses and duplicate names. Do not globally substitute arbitrary matching text tokens in the document: replace typed attachment nodes/opaque asset references only.

## 10. Performance And Observability

These are proposed acceptance budgets, not baseline measurements. Measure Release builds on a documented Apple-silicon Mac with macOS 26 or the chosen minimum-supported OS. Record model/RAM/OS/toolchain, cold versus warm cache, fixture size, and median/p95 over at least 30 runs. Do not hide slow provider I/O by dropping results or silently limiting folders.

| Workflow | Budget / invariant |
| --- | --- |
| Warm menu/hotkey to editable native text | p95 <=100ms |
| Cold native startup to responsive capture/setup shell | p95 <=500ms, excluding OS launch scheduling; separately report total launch time |
| Main-thread work | No app-owned synchronous vault I/O; no >50ms app-owned stalls during typing, folder navigation or send |
| Folder listing | 1000 local immediate folders p95 <=250ms; 10000 <=2s with loading state and virtualized rows; zero descendant reads |
| Typing/filtering | p95 edit-to-display <=16ms; local folder filtering <=50ms; disk work debounced/cancelled |
| Local enqueue | p95 <=100ms for 4KiB text after assets are staged; UI acknowledges only after durable commit |
| Local daily append | p95 <=200ms for 1MiB Markdown excluding external coordination delay; no quadratic parse/copy loops |
| Rich ready | Warm <=1s, cold <=2s target; recovery UI at 5s, quick capture always usable |
| Memory | Native-only steady RSS target <100MiB; rich total app+web-process target <350MiB for standard fixture; <5MiB retained growth after 50 open/close cycles |
| Idle | No periodic vault scans; effectively idle CPU, no retry storm while offline/backgrounded |
| Bundle | Record unpacked web size and loaded resources; enforce a reviewed size budget derived in phase 0, with >10% growth failing CI absent explicit budget update |

Generate deterministic fixtures: empty vault; 1000 and 10000 immediate folders with 100000 nested notes; 1MiB/8MiB daily files; 200 supported rich blocks; ten 2MiB images; malformed configs; simulated slow/denied/offline providers. Large fixtures live in test temp directories, not Git. Measure signposted stages for resolve, list, parse, enqueue, coordinate wait, publish and web-ready using operation IDs only. Never include user text or raw paths in signposts/logs.

Optimize after measurements: precompile date/template tokens, reuse safely isolated formatters, avoid rebuilding folder sets per character, debounce settings/checkpoints, lazily load WebKit, use bounded image thumbnails, and tree-shake explicitly supported blocks. Do not add a background vault index to solve onboarding or prewarm WebKit on every launch just to improve a rich-editor metric.

## 11. Verification Matrix

Use behavior tests through the production interfaces plus real filesystem/WK adapters where required. Existing 100 KnotKit tests are a starting regression suite; change expectations only for documented safety/behavior corrections. Add these suites and name test cases by the IDs below. A mock-only or source-regex check does not satisfy a runtime gate.

| Test ID | Required scenario and assertion | Audit findings |
| --- | --- | --- |
| T01 | Invalid UTF-8, denied read, cloud placeholder, BOM/CRLF daily file: failure leaves original bytes identical; no false success | F01,F07 |
| T02 | `..`, absolute/generated traversal, symlink folders/files, hardlinks, root rename, parent swaps, mixed case/Unicode: no outside mutation | F02,F16 |
| T03 | 100 same-timestamp concurrent Inbox saves from two processes plus asset collisions: every body survives at a distinct path; no overwrite | F03,F06 |
| T04 | Type revision B while A sends; close/reopen/reset/change vault mid-send; late timers/results: B survives and A retains original destination | F04,F19 |
| T05 | Kill after each journal/asset/note/receipt step; retry/relaunch: either provably one publication or needsReview, never blind duplicate append | F05,F06 |
| T06 | Disk full/database unavailable/queue corrupt/asset missing: no false local acknowledgement, raw record preserved, actionable export | F05,F08 |
| T07 | Sandboxed signed app reconnect and rich asset+note save: balanced scope success/error/cancel, stale bookmark refresh, no unauthorized writes | F06,F16 |
| T08 | Fences, code indentation, frontmatter, Setext/ATX, closing hashes, duplicate headings, emoji offsets, missing heading, end-of-note | F07,F17 |
| T09 | All token/default fixtures, ISO weeks/DST/retry timezone, malformed settings, missing content placeholder, H1 0/1/7/8-word cases | F08,F23 |
| T10 | Fresh/reset/reconnect onboarding; quit after every step then relaunch: exact resume and no partial configuration treated as complete | F12,F20 |
| T11 | Only root children initially; enter child does not select; top selects current; back/breadcrumb; all 10000 entries reachable; typed parent/prefix autocomplete | F14,F15 |
| T12 | Slow old-vault result arrives after new-vault selection; cancellation/read error/empty folder differentiated; no stale cache publication | F13,F15 |
| T13 | Periodic/Core enablement, invalid paths, absent today, template/sample headings, scoped Undo after unrelated user edit | F17,F08 |
| T14 | Real supported block schemas, nested quotes/lists/start values, marks/links/code fences/images/captions; unsupported source round-trip | F09 |
| T15 | Subframe/wrong-origin/wrong-version/stale/duplicate/oversized bridge messages; attempted file/data/blob/http navigation: no privileged action | F10,F18 |
| T16 | Large/malformed image, decompression bomb, chunk reordering, missing asset, wiki delimiters, paste/drop/picker, object URL cleanup | F11,F06 |
| T17 | Web readiness delay, invalid response, web-process kill, reopen existing rich window, failed save: recover acknowledged draft and controls | F18,F27 |
| T18 | Detach/reattach while typing and onboarding, multiwindow activation, close settings while rich open, removed display, malformed saved frames | F19 |
| T19 | Quick Return versus send shortcuts, Auto override reset, CR/CRLF/Unicode newline, indentation and trailing spaces, undoable clear | F23,F04 |
| T20 | Hotkey code zero, non-US layout change, conflict, cancel recording, disabled/default, bare-key confirmation; old binding survives failure | F21 |
| T21 | Keyboard-only/VoiceOver/IME/RTL/large text/dark/light/high contrast/system scrollbars and screen-fitting setup/settings | F20,F22 |
| T22 | Full legacy migration corpus; repeat migrations; interrupted migration; queue without vault context; reset with pending captures | F05,F08,F12,F16 |
| T23 | Concurrency sanitizer/strict-concurrency build; injected dependencies honored; no duplicate production writer/parser | F24 |
| T24 | Release-mode performance fixture runs, signpost/main-thread trace, memory after 50 rich/window cycles, idle/offline CPU | F13,F25 |
| T25 | Clean clone, npm ci, web build, XcodeGen, macOS Debug/Release: all resources loaded by manifest and no external network request | F26,F27 |
| T26 | Binary version == project version == requested release/tag; missing web assets/signature/notary rejection stop release | F28 |
| T27 | CI executes unit, integration and app/UI tests; runtime bridge tests actually invoke native handlers in WKWebView | F29 |
| T28 | README/USAGE/AGENTS/build/release docs match actual app/version, format subset, privacy and sync limits; iOS experimental label | F30 |

Add fixture/property tests for randomized Markdown punctuation and path components, with deterministic seeds and bounded sizes. Use race/failure injection at real call ordering points, not only testing helper return values. Native UI tests use a dedicated test bundle/preferences suite and disposable vault with known contents; no user's vault, bookmark or defaults are touched.

## 12. Implementation Phases

Execute in order. Each phase has a concrete exit condition; do not declare the rewrite finished while later phases remain.

| Phase | Work and files | Exit condition |
| --- | --- | --- |
| 0: Baseline | Pin source SHA/toolchains/dependencies; archive behavior fixtures; add shared fixture schema, macOS test targets and CI skeleton; record current performance measurements | Reproducible clean test/build commands and preserved migration corpus; no source-only readiness claims |
| 1: Domain | Domain/Formatting/Markdown types, validation, routing, title rules, byte-range daily insertion; first red-then-green integrity tests | T01,T02 parser/path unit portion,T08,T09,T19 pass; unsupported syntax preservation specified |
| 2: Durable state | CaptureStore/schema/assets/checkpointing/outbox/migrations/recovery interfaces | T04 model portion,T05 journal simulation,T06,T22 pass; no temporary persistence fallback |
| 3: Real vault I/O | Bookmark adapter, bounded CoordinatedIO, safe descriptor paths, exclusive publication, multi-file journal/reconciliation | T01-T07 real filesystem cases pass; signed sandbox test performed; one production writer |
| 4: Setup/settings | OnboardingCoordinator, config diff, hierarchy picker, daily discovery, settings transaction, reset/reconnect | T10-T13 pass with slow/stale fixtures and small-screen screenshots |
| 5: Native shell | App/SurfaceCoordinator, NSTextView integration, quick routing/status, recovery UI, hotkey transaction, frame restoration | T04,T18-T21 pass; fast path never constructs WebKit |
| 6: Rich editor | TS codecs, manifest resources, typed bridge, asset streaming, process recovery, promotion/checkpointing | T14-T17,T25 WK runtime portion pass; no silently dropped source or external requests |
| 7: Hardening | Cross-module crash tests, concurrency checks, accessibility, Instruments/budgets, iOS compatibility build, dependency/license audit | All T01-T27 applicable macOS tests pass; measured results attached; iOS not claimed released |
| 8: Handoff | Delete obsolete code; update docs; finalize verify/release scripts; record known limitations and screenshots | T28 and every final gate below satisfied; runnable app location and test evidence supplied |

Risk/effort guidance: phases 2-3 and 6 are the largest/highest-risk portions; budget most implementation and verification effort there. Phases 4-5 are medium, phase 1 medium, and build/docs cleanup small relative to data safety. Do not trade away recoverability or containment to meet a guessed elapsed-time estimate.

## 13. Build, CI, And Release Contract

Keep `project.yml` authoritative; generated `.xcodeproj`, plists, web dist and build output remain ignored. Track Swift and npm lockfiles, fixtures and documentation. Revise ignore rules so handoff docs do not disappear under a blanket `docs/` exclusion. `bootstrap.sh` validates prerequisites, performs a locked install/build, then generates Xcode. It must be rerunnable and must not install Homebrew software silently. No mtime-only dependency freshness heuristic.

Add a checked-in `scripts/verify.sh` with strict error handling and these stages, operating from the repository root: select/validate full Xcode without global `xcode-select` mutation; npm ci; TypeScript check; web unit tests; clean Vite build; web integration tests; Swift package tests; XcodeGen; macOS app/model/UI tests; macOS Debug and Release builds; resource/CSP checks; dependency license/security report. Each stage propagates exit status and prints a concise named result. Permit explicit `--quick` for developer iteration, but full verification is the release gate.

Expected commands after implementation (the implementing agent must make these interfaces real):

```sh
./bootstrap.sh
./scripts/verify.sh --quick
./scripts/verify.sh
swift test --package-path Packages/KnotKit
xcodebuild -project Knot.xcodeproj -scheme Knot-macOS -destination 'platform=macOS' test
./scripts/perf-fixtures.sh --output /tmp/knot-perf-fixtures
./scripts/benchmark.sh --fixtures /tmp/knot-perf-fixtures
```

CI on a pinned macOS/Xcode runner runs locked installation, package/web tests, macOS app tests, build/resource checks and a bounded UI smoke suite on every PR. Use a disposable test keychain/profile only where needed; never put signing material in Git. Longer fault/performance/accessibility suites run before release with artifacts retained. CI should not silently skip tests due to missing test target, missing generated dist, or unavailable signing; mark the relevant gate unavailable and fail the release gate.

Refactor release.sh so one validated version value drives project/binary/artifact metadata. Require a clean source tree and explicit release tag/commit, run full verification and fresh web build, archive intended architectures, export with explicit signing identity, verify codesign without `|| true`, notarize and wait for successful status, staple and validate the distributed object, and assess Gatekeeper behavior on the actual artifact. Compare CFBundleShortVersionString/CFBundleVersion with the expected release values before packaging and again after extraction. Produce checksum, source SHA, dependency/license manifest and release notes.

Signing/notarization is a separate external-credentials gate: an agent without those credentials may deliver a clearly labeled unsigned development build, but may not claim a signed/notarized release. Never move the existing v0.2.0 tag or push a new release without explicit user authorization. Resolve deployment-target/API availability for macOS 26 and perform the iOS compatibility build; do not silently raise minimum OS to match a beta SDK on the development machine.

## 14. Documentation And Final Acceptance

Update README.md with actual macOS support, quick/rich capture roles, setup sequence, build prerequisites including Node, current version source, test commands and experimental iOS status. Update USAGE.md for folder navigation versus selection, explicit daily target, pending/review status, recovery/export, shortcuts and reset semantics. Update AGENTS.md to the actual module ownership, path/scope/journal invariants and verification commands; remove obsolete claims that the app has no editor or that every sync provider follows a particular conflict-filename convention. Keep GPL notices and add third-party notices for shipped dependencies. Do not claim complete Moment/Obsidian syntax coverage where only a documented subset is implemented.

The implementation handoff must include `IMPLEMENTATION_NOTES.md` with source SHA, toolchain/dependency versions, schema version, migration evidence, test outputs, performance table, native screenshots, signed/unsigned artifact location, and genuine remaining limitations. Do not include users' note content, file paths, secrets or bookmark data in shared diagnostics.

The rewrite is complete only when all of these are true:

1. Every preserved capability in section 2 is present in the macOS app and has an exercised test/manual gate, including optional rich editing and the full sequential onboarding flow.
2. Every F01-F30 finding has its mapped T01-T28 test or documented measured verification result. Source inspection alone cannot close runtime/sandbox/data-loss findings.
3. A clean checkout can build and run without old dist/node_modules/generated projects, and full verification executes the intended test suites.
4. The failure matrix proves preservation of existing bytes, newer drafts, pending capture identity and assets across permission loss, concurrency, crash and reset cases.
5. Onboarding has a usable tall layout, only immediate children, true autocomplete, pinned select-current action and correct first-launch/reset/missing-vault behavior.
6. Real WKWebView tests prove resource completeness, nonblank interactive editor, conversion fidelity, bridge rejection and crash recovery. Native screenshots/VoiceOver/IME checks establish usable UI rather than merely compilable code.
7. Performance budgets are measured on a stated machine; unmet targets have been addressed or explicitly re-approved by the user, not silently waived.
8. Existing settings/queue migration is idempotent and backed up, iOS compatibility is stated accurately, and docs match actual behavior.
9. Release claims match actual signing/notarization evidence. Any unavailable external release gate is reported, not replaced with an unsigned build described as production-ready.

For this planning task, completion means this specification and the companion evidence-backed audit are delivered. The implementation gates above apply to the future rewrite, not to the current baseline app.
