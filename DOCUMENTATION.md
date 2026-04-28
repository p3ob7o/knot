# Knot — Project Documentation

Snapshot of what Knot is, how it's built, and where the project
stands.

## Overview

Knot is a single-purpose, native, local-only **quick-capture app for
Obsidian users** on macOS and iOS. The whole product is the gap
between having a thought and having it written into your vault — one
textarea, no list view, no editor, no sync of its own.

The user picks an Obsidian vault folder once. Captured text becomes a
real `.md` file inside that folder; the user's existing sync
(Obsidian Sync, iCloud, Git, Syncthing, …) carries it to other
devices.

## Routing model

Each note lands in one of two places, auto-decided and always
overridable via a Today / Inbox segmented toggle:

| Note shape                               | Destination                                                 |
| ---------------------------------------- | ----------------------------------------------------------- |
| ≤ 280 characters and a single line       | Bullet appended under `## Quick notes` in today's daily file |
| > 280 characters **or** multi-line       | New `.md` file in the Inbox folder                          |

If the first line of an Inbox note is `# Title` with 1–7 words, Knot
uses the heading as the filename and strips it from the body;
otherwise the filename is a timestamp (`YYYY-MM-DD HHmm.md`). All
paths, the daily filename pattern, the heading text, the bullet
template, and the routing thresholds are configurable.

## Vault-config import

When the user picks a vault, Knot inspects `.obsidian/` and adopts
the active daily-note configuration:

1. **Periodic Notes** (community plugin) when listed in
   `.obsidian/community-plugins.json` and its `data.json` declares
   `daily.enabled == true` with a non-empty `daily.format`.
2. **Core Daily Notes** plugin when `.obsidian/daily-notes.json`
   parses. A missing or empty `format` falls back to `"YYYY-MM-DD"`.
3. **No-op** otherwise — Knot keeps its current settings.

Imports surface in a small banner above the editor with *Undo* /
*Dismiss* actions, so the user can revert to the previous settings
in one click.

## Architecture

```
Knot/
  Shared/        SwiftUI views + view model used on both platforms
  macOS/         AppKit shell — NSStatusItem popover, optional
                 detached NSWindow, global hotkey
  iOS/           Single SwiftUI scene (NavigationStack + Settings sheet)
Packages/
  KnotKit/       Pure Swift package — file I/O, models, formatting,
                 unit tests
project.yml      XcodeGen project definition (source of truth for
                 both app targets, schemes, entitlements, Info.plist)
bootstrap.sh     `xcodegen generate` (installs xcodegen via brew if
                 needed)
scripts/
  bake-icons.swift   Renders the Knot mark into platform-ready icon
                     sets
  release.sh         Builds, signs, notarizes, and packages
                     Knot-macOS into a distributable DMG
USAGE.md         End-user documentation
```

### KnotKit (the logic core)

Platform-independent, unit-tested. Modules:

- `Vault` — entry point that owns the bookmark URL and dispatches
  writes.
- `DailyAppender` — read-modify-write on the daily file inside one
  `NSFileCoordinator` block.
- `InboxWriter` — atomic creation of new Inbox files, with
  collision-safe filename suffixing.
- `HeadingSplicer` — finds (or creates) the configured `## Quick
  notes` heading and appends a bullet under it.
- `RoutingPolicy` — decides Today vs Inbox from settings + content
  shape.
- `MomentFormat` — translates Moment.js display tokens (`YYYY`, `MM`,
  `dddd`, `[literal]`, …) into a Swift `DateFormatter` pattern,
  including `/` as a path separator for subfolders.
- `BulletTemplate` — substitutes `{{HH:mm}}`, `{{content}}`, and any
  Moment token inside `{{ }}` against the note's timestamp.
- `TitleExtractor` — extracts an H1 filename when the note's first
  line is `# 1–7-word title`.
- `Slug` — lowercase, hyphenated, max-50-char filename slug (used as
  a fallback when the user opts out of timestamp filenames).
- `AppSettings` — codable settings, persisted as JSON in
  `UserDefaults`.
- `VaultStore` — saves and resolves the security-scoped bookmark;
  manages `startAccessingSecurityScopedResource`.
- `ObsidianConfigImporter` — reads the active daily-note
  configuration from `.obsidian/` (Periodic Notes or Core Daily
  Notes), all I/O coordinated by `NSFileCoordinator`.
- `Queue` — persistent spool for failed writes inside Application
  Support, so a transient I/O error doesn't lose the user's text.
- `Note` — the captured-note model (content, mode, createdAt).

Tests cover `HeadingSplicer`, `Slug`, `MomentFormat`,
`TitleExtractor`, `BulletTemplate`, `Routing`,
`ObsidianConfigImporter`, plus a `VaultIntegrationTests`
end-to-end file-system test.

### macOS shell (`Knot/macOS/`)

- `KnotMacApp.swift` — `@main` SwiftUI app, headless (`LSUIElement =
  true`), no Dock icon. Hosts the Settings window and the menu-bar
  controller.
- `MenuBarController.swift` — `NSStatusItem` with a 16-pt
  template-image glyph; left-click toggles the popover; right-click
  opens a small menu (Detach / Reattach, Settings…, Quit). Owns the
  optional detached `NSWindow` and the live `EditorModel`.
- `WindowStateStore.swift` — persists detached-window frame; clamps
  to a connected screen on reopen so a disconnected external monitor
  can't strand the window off-screen.
- `ChromelessTextEditor.swift` — `NSTextView` wrapper used by the
  editor to drop the default chrome and hide the scroll bar until
  the user actually scrolls.
- **Detach via drag** — dragging the popover tears it off into a
  free-floating window; the same path the *Detach* menu item uses.
- `Hotkey/` — global hotkey:
  - `HotkeyManager.swift` — registers the configured shortcut with
    the system and surfaces user-facing errors when macOS refuses a
    combination.
  - `Shortcut.swift`, `KeyName.swift` — model + key-name mapping.
  - `ShortcutStore.swift` — persistence in `UserDefaults`.
  - `ShortcutPickerView.swift` — single-row recorder with display /
    recording states; *Backspace* clears, *Esc* cancels.

### iOS shell (`Knot/iOS/`)

- `KnotIOSApp.swift` — `@main` SwiftUI app, single window scene.
- `ContentScreen.swift` — `NavigationStack` with the editor (or
  onboarding if no vault is set); the gear in the toolbar opens
  Settings as a sheet with a *Done* button.

### Shared SwiftUI layer (`Knot/Shared/`)

- `EditorModel.swift` — `@Observable` view model. Owns content,
  manual mode override, status (idle / sending / sent / error),
  settings, vault-state, and the most recent `VaultImportResult`.
  `send()` resolves the bookmark on the main actor, dispatches the
  write to a detached task, enqueues on failure, and clears + flashes
  a green check on success. `setVault(url:)` runs the
  Obsidian-config importer and returns the import result so the
  banner can show *Undo* / *Dismiss*. `resetAllSettings()` is the
  single reset path: drops the bookmark, removes the settings JSON,
  posts `.knotSettingsReset` so platform code can clean up the bits
  the model doesn't own (the global hotkey + the detached-window
  state).
- `EditorView.swift` — the editor surface (textarea, mode toggle,
  status pill, send button, ⌘↩ / Esc handlers).
- `OnboardingView.swift` — first-run vault picker.
- `SettingsView.swift` — vault, hotkey (macOS), folders, daily-note
  pattern + heading + bullet template, Inbox filename, routing
  thresholds, reset-to-defaults.
- `VaultImportBanner.swift` — confirmation strip rendered when
  `EditorModel.lastImport` is `.imported(...)`. *Undo* reverts to the
  prior settings; *Dismiss* hides the banner.
- `ModeToggle.swift`, `Theme.swift` — small UI helpers.

## Concurrency safety

Every read and write goes through `NSFileCoordinator`. Daily-note
appends are read-modify-write inside one coordination block; Inbox
writes use atomic file creation; the Obsidian-config importer reads
through coordination too. Knot doesn't try to outsmart simultaneous
writes from another device — Obsidian's own `*.conflict-*.md`
convention takes over if a true conflict happens.

## Privacy posture

Local-only by design: no servers, no accounts, no telemetry. Settings
live in `UserDefaults`; the vault path is stored as a security-scoped
bookmark scoped to the app. The macOS target is sandboxed with
`com.apple.security.files.user-selected.read-write` +
`com.apple.security.files.bookmarks.app-scope`.

## Build & test

Generate the Xcode project from `project.yml` (XcodeGen):

```sh
./bootstrap.sh
open Knot.xcodeproj
```

KnotKit's unit tests run headless via SwiftPM:

```sh
swift test --package-path Packages/KnotKit
```

Targets `Knot-macOS` and `Knot-iOS` build the two app shells.
Deployment targets: macOS 26 / iOS 26 (Xcode 26). Swift 6, minimal
strict concurrency. App version comes from `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `project.yml`.

## Current status

**v0.1** — first public release. The capture loop ships end-to-end
on both platforms. Recent work has focused on the macOS chrome,
Settings polish, and onboarding:

- Reset-settings-to-defaults button in the Settings window
- Settings window default size raised to 1080 pt tall, resizable
  height
- Editor textarea scroll bar hidden until actually scrolling
- Detach/Reattach lives on the right-click menu, plus tear-off by
  dragging the popover into a free-floating window
- Send-arrow remains visible when the editor is empty (just disabled)
- Knot mark baked into the iOS + macOS app icon sets via
  `scripts/bake-icons.swift`
- Obsidian daily-note configuration imported on first vault pick,
  with an undoable banner

## Roadmap (post-v0.1)

Tracked but not yet built:

- iOS widgets and Lock Screen presence
- App Intents / Shortcuts surface
- Share-sheet extension
- Custom brand mark refinement (the menu-bar status icon currently
  uses the SF Symbol `scribble.variable`)

## Pointers

- End-user behavior: `USAGE.md`
- High-level overview + how-it-writes: `README.md`
- Agent-facing conventions and invariants: `CLAUDE.md`
- Source of truth for project structure: `project.yml`
