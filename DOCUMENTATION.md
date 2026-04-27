# Knot — Project Documentation

Snapshot of what Knot is, how it's built, and where the project stands.

## Overview

Knot is a single-purpose, native, local-only **quick-capture app for
Obsidian users** on macOS and iOS. The whole product is the gap between
having a thought and having it written into your vault — one textarea, no
list view, no editor, no sync of its own.

The user picks an Obsidian vault folder once. Captured text becomes a real
`.md` file inside that folder; the user's existing sync (Obsidian Sync,
iCloud, Git, Syncthing, …) carries it to other devices.

## Routing model

Each note lands in one of two places, auto-decided and always overridable
via a Today / Inbox segmented toggle:

| Note shape                               | Destination                                                 |
| ---------------------------------------- | ----------------------------------------------------------- |
| ≤ 280 characters and a single line       | Bullet appended under `## Quick notes` in today's daily file |
| > 280 characters **or** multi-line       | New `.md` file in the Inbox folder                          |

If the first line of an Inbox note is `# Title` with 1–7 words, the heading
is used as the filename and stripped from the body; otherwise a timestamp
filename (`YYYY-MM-DD HHmm.md`) is used. All paths, the daily filename
pattern, the heading text, the bullet template, and the routing thresholds
are configurable.

## Architecture

```
Knot/
  Shared/        SwiftUI views + view model used on both platforms
  macOS/         AppKit shell — NSStatusItem popover, optional detached
                 NSWindow, global hotkey
  iOS/           Single SwiftUI scene (NavigationStack + Settings sheet)
Packages/
  KnotKit/       Pure Swift package — file I/O, models, formatting, tests
project.yml      XcodeGen project definition (source of truth for both
                 app targets, schemes, entitlements, Info.plist)
bootstrap.sh     `xcodegen generate` (installs xcodegen via brew if needed)
scripts/
  bake-icons.swift   Renders the Knot mark into platform-ready icon sets
docs/
  usage.md           End-user documentation
  design-brief.md    Designer handoff with every surface and constant
  design_handoff_knot/  Static HTML design handoff (assets + styles)
```

### KnotKit (the logic core)

Platform-independent, unit-tested. Modules:

- `Vault` — entry point that owns the bookmark URL and dispatches writes.
- `DailyAppender` — read-modify-write on the daily file inside one
  `NSFileCoordinator` block.
- `InboxWriter` — atomic creation of new Inbox files, with collision-safe
  filename suffixing.
- `HeadingSplicer` — finds (or creates) the configured `## Quick notes`
  heading and appends a bullet under it.
- `RoutingPolicy` — decides Today vs Inbox from settings + content shape.
- `MomentFormat` — translates Moment.js display tokens (`YYYY`, `MM`,
  `dddd`, `[literal]`, …) into a Swift `DateFormatter` pattern, including
  `/` as a path separator for subfolders.
- `BulletTemplate` — substitutes `{{HH:mm}}`, `{{content}}`, and any
  Moment token inside `{{ }}` against the note's timestamp.
- `TitleExtractor` — extracts an H1 filename when the note's first line is
  `# 1–7-word title`.
- `Slug` — lowercase, hyphenated, max-50-char filename slug.
- `AppSettings` — codable settings, persisted as JSON in `UserDefaults`.
- `VaultStore` — saves and resolves the security-scoped bookmark; manages
  `startAccessingSecurityScopedResource`.
- `Queue` — persistent spool for failed writes inside Application Support,
  so a transient I/O error doesn't lose the user's text.
- `Note` — the captured-note model (content, mode, createdAt).

Tests cover `HeadingSplicer`, `Slug`, `MomentFormat`, `TitleExtractor`,
`BulletTemplate`, `Routing`, plus a `VaultIntegrationTests` end-to-end
file-system test.

### macOS shell (`Knot/macOS/`)

- `KnotMacApp.swift` — `@main` SwiftUI app, headless (`LSUIElement = true`),
  no Dock icon. Hosts the Settings window and the menu-bar controller.
- `MenuBarController.swift` — `NSStatusItem` with a 16-pt template-image
  glyph; left-click toggles the popover; right-click opens a small menu
  (Detach / Reattach, Settings…, Quit). Owns the optional detached
  `NSWindow` and the live `EditorModel`.
- `WindowStateStore.swift` — persists detached-window frame; clamps to a
  connected screen on reopen so a disconnected external monitor can't
  strand the window off-screen.
- `ChromelessTextEditor.swift` — `NSTextView` wrapper used by the editor
  to drop the default chrome and hide the scroll bar until the user
  actually scrolls.
- `Hotkey/` — global hotkey:
  - `HotkeyManager.swift` — registers the configured shortcut with the
    system, surfaces user-facing errors when macOS refuses a combination.
  - `Shortcut.swift`, `KeyName.swift` — model + key-name mapping.
  - `ShortcutStore.swift` — persistence in `UserDefaults`.
  - `ShortcutPickerView.swift` — single-row recorder with display /
    recording states, Backspace clears, Esc cancels.

### iOS shell (`Knot/iOS/`)

- `KnotIOSApp.swift` — `@main` SwiftUI app, single window scene.
- `ContentScreen.swift` — `NavigationStack` with the editor (or
  onboarding if no vault is set), gear in the toolbar opens Settings as
  a sheet with a *Done* button.

### Shared SwiftUI layer (`Knot/Shared/`)

- `EditorModel.swift` — `@Observable` view model. Owns content, manual
  mode override, status (idle / sending / sent / error), settings, and
  vault-state. `send()` resolves the bookmark on the main actor, dispatches
  the write to a detached task, enqueues on failure, clears + flashes a
  green check on success. `resetAllSettings()` is the single reset path:
  drops the bookmark, removes the settings JSON, posts
  `.knotSettingsReset` so platform code can clean up the bits the model
  doesn't own (the global hotkey + the detached-window state).
- `EditorView.swift` — the editor surface (textarea, mode toggle,
  status pill, send button, ⌘↩ / Esc handlers).
- `OnboardingView.swift` — first-run vault-picker.
- `SettingsView.swift` — vault, hotkey (macOS), folders, daily-note
  pattern + heading + bullet template, Inbox filename, routing thresholds,
  reset-to-defaults.
- `ModeToggle.swift`, `Theme.swift` — small UI helpers.

## Concurrency safety

Every read and write goes through `NSFileCoordinator`. Daily-note appends
are read-modify-write inside one coordination block; Inbox writes use
atomic file creation. Knot doesn't try to outsmart simultaneous writes
from another device — Obsidian's own `*.conflict-*.md` convention takes
over if a true conflict happens.

## Privacy posture

Local-only by design: no servers, no accounts, no telemetry. Settings live
in `UserDefaults`; the vault path is stored as a security-scoped bookmark
scoped to the app. The macOS target is sandboxed with
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

Targets `Knot-macOS` and `Knot-iOS` build the two app shells. Deployment
targets: macOS 26 / iOS 26 (Xcode 26). Swift 6, minimal strict concurrency.

## Current status

**v0** — end-to-end capture loop on both platforms is shipping. Recent
work has focused on the macOS chrome and Settings polish:

- Reset-settings-to-defaults button in the Settings window
- Settings window default size raised to 1080 pt tall, resizable height
- Editor textarea scroll bar hidden until actually scrolling
- Detach/Reattach lives only on the right-click menu (no inline pip)
- Send-arrow remains visible when the editor is empty (just disabled)
- Knot mark baked into the iOS + macOS app icon sets via
  `scripts/bake-icons.swift`

## Roadmap (post-v0)

Tracked but not yet built:

- iOS widgets and Lock Screen presence
- App Intents / Shortcuts surface
- Share-sheet extension
- Configurable hotkey UI improvements
- Custom brand mark refinement (current SF Symbol fallback in some
  surfaces is `scribble.variable`)

Designer-facing open questions are listed in `docs/design-brief.md` §9
(empty-editor voice, sent-feedback motion, detached-window chrome,
mode-toggle metaphor, onboarding flow, iOS Action Button affordance).

## Pointers

- End-user behavior: `docs/usage.md`
- Designer handoff (every surface + every visual constant): `docs/design-brief.md`
- High-level overview + how-it-writes: `README.md`
- Agent-facing conventions and invariants: `CLAUDE.md`
- Source of truth for project structure: `project.yml`
