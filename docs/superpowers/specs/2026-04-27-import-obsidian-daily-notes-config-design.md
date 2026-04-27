# Import Obsidian daily-note configuration on vault pick

Status: approved
Date: 2026-04-27
Author: brainstorming session (Paolo + Claude)

## Goal

When the user picks an Obsidian vault, Knot reads the active daily-note
configuration from that vault and adopts its **folder** and **filename
format** instead of falling back to Knot's generic defaults
(`Daily` / `YYYY-MM-DD`).

The user gets a one-time, undo-able banner confirming what was imported.
Picking a vault never fails because of this — a missing or malformed
Obsidian config silently falls through to defaults.

## Non-goals

- Importing the daily-note **template file** (`Templates/Daily Template.md`).
  Knot does not seed daily notes from a template.
- Importing the Inbox folder from Obsidian's "default location for new
  notes" preference.
- Importing `dailyHeading` or `dailyBulletFormat`. These are Knot-specific
  concepts with no Obsidian equivalent.
- Live re-import on app launch or on Obsidian-side config changes. The
  read happens *only* at vault-pick time.
- Weekly/monthly periodic notes. Daily only.

## Source of truth in an Obsidian vault

Obsidian itself has no vault-level concept of "the daily note location" —
it is per-plugin. Knot resolves the active config through this chain:

1. **Periodic Notes** (community plugin) — when enabled in
   `.obsidian/community-plugins.json` *and*
   `.obsidian/plugins/periodic-notes/data.json` has
   `daily.enabled == true` with a non-empty `daily.format`. Use
   `daily.folder` and `daily.format`.
2. **Core Daily Notes** plugin — when `.obsidian/daily-notes.json`
   parses with usable values. (We treat the file's existence as
   sufficient evidence that the plugin has been configured at least
   once; reading `core-plugins-migration.json` adds little signal.)
   Use `folder` and `format`.
3. **Default** — no recognizable config. Knot's defaults stand
   (`Daily` / `YYYY-MM-DD`). Silent: no banner.

## Architecture

One new file in **KnotKit**, plus surgical edits in `EditorModel` and a
small new view used by both editor and settings screens:

```
Packages/KnotKit/Sources/KnotKit/
  ObsidianConfigImporter.swift   ← new

Knot/Shared/
  EditorModel.swift              ← setVault returns an import result;
                                   adds lastImport state and undoLastImport()
  VaultImportBanner.swift        ← new shared view
  EditorView.swift               ← renders banner above the textarea
  SettingsView.swift             ← renders banner at top of the form
```

Honors the project invariants in `CLAUDE.md`:

- Logic (parsing, resolution) lives in KnotKit, behind a value type.
- All file I/O (including the importer's reads) goes through
  `NSFileCoordinator`.
- The importer starts/stops the security-scoped resource around its reads
  (the caller — `EditorModel.setVault` — already holds the URL but does
  not assume scope is open during the import call).
- No telemetry, no network, local-only.

## Components

### `ObsidianConfigImporter` (KnotKit)

Pure read-only parser. Returns a value type. No mutation, no UI.

```swift
public struct ImportedDailyConfig: Equatable, Sendable {
    public let folder: String           // may be "" → vault root
    public let filenameFormat: String   // Moment.js pattern
    public let source: Source

    public enum Source: String, Equatable, Sendable, Codable {
        case periodicNotes
        case coreDailyNotes
    }
}

public enum ObsidianConfigImporter {
    /// Inspects `vaultURL/.obsidian/` and returns the active daily-note
    /// configuration, or nil when no recognizable config exists.
    /// Never throws — every failure mode collapses to nil.
    public static func read(vaultURL: URL) -> ImportedDailyConfig?
}
```

Resolution rule (in order):

1. Read `.obsidian/community-plugins.json` (a JSON array of plugin IDs).
   If it contains `"periodic-notes"`, attempt to read
   `.obsidian/plugins/periodic-notes/data.json`. If it parses with
   `daily.enabled == true` and `daily.format` is a non-empty string,
   return `.periodicNotes` with `daily.folder ?? ""` and `daily.format`.
2. Otherwise attempt to read `.obsidian/daily-notes.json`. If it parses,
   return `.coreDailyNotes` with `folder ?? ""` and
   `format ?? "YYYY-MM-DD"`.
3. Otherwise return `nil`.

All reads:

- Use `NSFileCoordinator` with a read intent.
- Wrap in `do { try } catch { /* return nil */ }` — never propagate
  errors to the caller.
- Briefly start/stop `startAccessingSecurityScopedResource()` on the
  vault URL.
- Emit `os.Logger` diagnostics when a file exists but cannot be
  parsed. Subsystem follows the project's existing convention; if
  none exists yet, the implementation picks a reverse-DNS string and
  applies it consistently.

### `EditorModel` changes (Shared)

Signature change:

```swift
@discardableResult
func setVault(url: URL) throws -> VaultImportResult

enum VaultImportResult: Equatable {
    case imported(ImportedDailyConfig, previous: AppSettings)
    case noConfigFound
}
```

Behavior:

1. `vaultStore.saveBookmark(from: url)` (existing).
2. `let imported = ObsidianConfigImporter.read(vaultURL: url)`.
3. If `imported == nil` → `refreshVaultStatus()`, return `.noConfigFound`.
   Do not touch `lastImport`.
4. If `imported != nil`:
   - Snapshot `let previous = settings`.
   - Build `var merged = settings`; set `merged.dailyFolder = imported.folder`
     and `merged.dailyFilenameFormat = imported.filenameFormat`.
   - If `merged == previous` (nothing actually changes), return
     `.noConfigFound`. Suppress the banner.
   - Otherwise `updateSettings(merged)` (persists), set
     `lastImport = .imported(imported, previous: previous)`,
     `refreshVaultStatus()`, return the result.

New observable properties:

```swift
var lastImport: VaultImportResult? = nil
```

New method:

```swift
func undoLastImport() {
    if case .imported(_, let previous) = lastImport {
        updateSettings(previous)
    }
    lastImport = nil
}

func dismissLastImport() {
    lastImport = nil
}
```

`lastImport` is also auto-cleared by:

- a successful `send()` (after the user posts a note),
- the user editing any field via `settingsBinding` (set inside the
  binding's setter — one extra line).

`resetAllSettings()` also clears `lastImport`.

### `VaultImportBanner` (Shared)

Tiny SwiftUI view, ~40 lines:

```swift
struct VaultImportBanner: View {
    @Bindable var model: EditorModel
    var body: some View { … }
}
```

Renders only when `model.lastImport` is `.imported(...)`. Shows:

> **Imported daily-note settings from your vault**
> Folder: `<value>`  ·  Filename: `<value>`  ·  Source: <Periodic Notes | Core Daily Notes>
> [Undo]   [Dismiss]

Visual: respects the existing `Theme` palette. Compact: ≤ 56 pt tall, 8
pt vertical padding, monospaced font for the values, secondary
foreground for labels. Two `.borderless` buttons trailing.

Mounted at the top of:

- `EditorView` (above the textarea, inside the popover content)
- `SettingsView` (as the first row of the form, above the Vault section)

Both use the same view; both bind to the same model; the banner shows in
whichever surface is visible when the import happens (Settings on
"Change…", editor on initial onboarding).

## Data flow

```
User picks vault
   │
   ▼
EditorModel.setVault(url)
   │  vaultStore.saveBookmark(from: url)        // existing
   │  ObsidianConfigImporter.read(vaultURL: url) // new
   │     ├─ Periodic Notes? read data.json
   │     ├─ Core Daily Notes? read daily-notes.json
   │     └─ neither → nil
   │
   ├─ nil               → return .noConfigFound, no banner
   ├─ identical to now  → return .noConfigFound, no banner
   └─ value             → snapshot previous AppSettings
                          merge folder + filenameFormat
                          updateSettings(merged)            // persists
                          lastImport = .imported(value, previous)
                          return .imported(...)
   │
   ▼
EditorView / SettingsView render VaultImportBanner
   ├─ Undo    → model.undoLastImport()    // restores previous, persists
   ├─ Dismiss → model.dismissLastImport()
   └─ implicit dismiss on first send() or settings edit
```

## Edge cases

| Case | Behavior |
|---|---|
| `.obsidian/` missing entirely (folder isn't an Obsidian vault) | Return `nil`. No banner. Defaults stand. We don't warn — Knot supports plain folders. |
| Periodic Notes enabled but `daily.enabled == false` | Fall through to Core. |
| Periodic Notes `daily.format` empty or missing | Fall through to Core. |
| `daily-notes.json` JSON malformed | Treat as not present. Log via `os.Logger`. Fall through. |
| Core Daily Notes config has empty `format` | Use Knot's default `YYYY-MM-DD` for that field; still return the import (folder may have been set). |
| Imported `folder` is empty string | Treat as "vault root" (Obsidian's behavior). Stored as `""` in `dailyFolder`. `DailyAppender` already tolerates this. |
| Imported values identical to current settings | Skip the banner — nothing actually changed. |
| User picks the *same* vault again via "Change…" | Re-import runs; if Obsidian-side changed since last pick, banner shows; if not, no banner. |
| File coordination read fails (locked, permissions) | Treat as not present, fall through. No user-facing error. |
| `community-plugins.json` lists `"periodic-notes"` but the plugin's `data.json` is missing | Treat Periodic Notes as not configured; fall through to Core. |

## Testing

### KnotKit unit tests — `ObsidianConfigImporterTests.swift`

Each test writes a small `.obsidian/` tree into a `FileManager` temp
directory, then calls `ObsidianConfigImporter.read(vaultURL:)` on the
parent directory and asserts the returned value.

- Periodic Notes enabled with `daily.enabled = true` →
  `.periodicNotes(folder: "Journal", filenameFormat: "YYYY-MM-DD dddd")`.
- Periodic Notes enabled but `daily.enabled = false` and Core present
  → `.coreDailyNotes(...)`.
- Periodic Notes enabled, `daily.format` empty → falls through to Core.
- Only Core Daily Notes config present → `.coreDailyNotes(...)`.
- No `.obsidian/` directory → `nil`.
- `.obsidian/` present but neither plugin has config → `nil`.
- Malformed JSON in `data.json` → treated as absent, falls through to
  Core (which is also absent in this test) → `nil`.
- Malformed JSON in `daily-notes.json` → `nil`.
- Empty-string `folder` → preserved as `""`.
- `community-plugins.json` lists `"periodic-notes"` but
  `plugins/periodic-notes/data.json` is missing → falls through to
  Core.

### Lightweight model test (added to existing `EditorModel`-adjacent
tests if any, otherwise inline next to `VaultIntegrationTests`):

- `setVault` against a temp folder containing a Periodic Notes config
  returns `.imported(...)` and merges fields into persisted
  `AppSettings`.
- `undoLastImport` restores the exact prior `AppSettings` (deep
  equality).
- A second `setVault` to a folder whose config matches the current
  settings returns `.noConfigFound` (banner suppression).

Routing/appender tests already cover what happens once values are in
`AppSettings`. No changes there.

## File touch list

- **New**: `Packages/KnotKit/Sources/KnotKit/ObsidianConfigImporter.swift`
- **New**: `Packages/KnotKit/Tests/KnotKitTests/ObsidianConfigImporterTests.swift`
- **New**: `Knot/Shared/VaultImportBanner.swift`
- **Edit**: `Knot/Shared/EditorModel.swift` (signature change on
  `setVault`, new `lastImport` state, two new methods, hooks in
  `send()`/`settingsBinding`/`resetAllSettings`)
- **Edit**: `Knot/Shared/EditorView.swift` (render banner above textarea)
- **Edit**: `Knot/Shared/SettingsView.swift` (render banner above Vault
  section; existing call sites of `setVault` already use `try` and
  ignore the return — `@discardableResult` keeps them compiling)
- **Edit**: `Knot/Shared/OnboardingView.swift` (call site already uses
  `try model.setVault(url:)` — no change needed beyond letting the
  banner appear in the editor afterwards via observed state)

No changes to `project.yml` (XcodeGen picks up new files in the existing
source folders automatically).

## Open questions

None. All resolved during brainstorming.
