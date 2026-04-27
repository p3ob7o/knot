# CLAUDE.md

Guidance for Claude Code working in this repository.

## What Knot is

Single-purpose **quick-capture app for Obsidian users**, native, local-only,
macOS + iOS. One textarea — type a thought, press send, and the text becomes
a real `.md` file inside the user's Obsidian vault. There is no list view, no
editor, no sync; existing Obsidian sync (Obsidian Sync / iCloud / Git /
Syncthing) carries the file to other devices.

Two destinations, auto-decided and always overridable via a Today / Inbox
segmented toggle:

- **Today** — short, single-line notes (≤ 280 chars by default) → bullet
  appended under a `## Quick notes` heading in today's daily note
  (`Daily/YYYY-MM-DD.md`).
- **Inbox** — longer or multi-line notes → new `.md` file in `Inbox/`
  (timestamp filename by default; if the first line is `# Title` with 1–7
  words, the heading is used as the filename and stripped from the body).

Status: **v0** — capture loop end-to-end on both platforms. Widgets, App
Intents, share extension are tracked for v0.1+.

## Project layout

```
Knot/
  Shared/        SwiftUI views + view model used on both platforms
                 (EditorView, EditorModel @Observable, OnboardingView,
                  SettingsView, ModeToggle, Theme)
  macOS/         AppKit shell — NSStatusItem popover, optional detached
                 NSWindow, ChromelessTextEditor, WindowStateStore
    Hotkey/      Global hotkey: HotkeyManager, Shortcut, ShortcutStore,
                 ShortcutPickerView, KeyName
  iOS/           Single SwiftUI scene (NavigationStack + Settings sheet)
Packages/
  KnotKit/       Pure Swift package — file I/O, models, formatting, tests.
                 No platform dependency, no UI. Unit-tested core.
project.yml      XcodeGen project definition (source of truth)
bootstrap.sh     Installs XcodeGen via Homebrew if needed, runs xcodegen
scripts/
  bake-icons.swift   Renders Knot mark SVG into macOS .iconset + iOS 1024px
docs/
  usage.md           End-user documentation
  design-brief.md    Designer handoff: every surface, every visual constant
  design_handoff_knot/  Static HTML design handoff
```

`KnotKit` is where the logic lives. The two app targets are thin SwiftUI
shells over it.

### KnotKit modules at a glance

`Vault` (entry point), `DailyAppender`, `InboxWriter`, `HeadingSplicer`
(splices bullets under `## Quick notes`), `RoutingPolicy`, `MomentFormat`
(Moment.js → Swift date formatting), `BulletTemplate` (`{{HH:mm}}`,
`{{content}}`), `TitleExtractor` (H1 → filename), `Slug`, `AppSettings`
(JSON in UserDefaults), `VaultStore` (security-scoped bookmark), `Queue`
(persistent spool for failed writes), `Note` model.

## Build & generate

The Xcode project is **generated** — never edit `Knot.xcodeproj` by hand.

```sh
./bootstrap.sh           # installs xcodegen if missing, runs `xcodegen generate`
open Knot.xcodeproj
```

Targets: `Knot-macOS`, `Knot-iOS`. Deployment targets are macOS 26 / iOS 26
(Xcode 26 required). Swift 6, minimal strict concurrency.

`Knot/{macOS,iOS}/Generated-Info.plist` is produced by XcodeGen — don't edit
it; change `project.yml` and re-run bootstrap. Entitlements live in
`Knot/macOS/Knot-macOS.entitlements` and `Knot/iOS/Knot-iOS.entitlements`.

## Tests

KnotKit has the unit tests. Run them headless via SwiftPM:

```sh
swift test --package-path Packages/KnotKit
```

Or via the Xcode test action on either app scheme. Test files cover the
heading splicer, slug, Moment format, title extractor, bullet template,
routing, and a vault integration test.

## Invariants — things to preserve when changing code

- **All file I/O goes through `NSFileCoordinator`.** Obsidian and Obsidian
  Sync use `NSFilePresenter`; daily-note appends are read-modify-write
  inside one coordination block; Inbox writes are atomic. Don't bypass this
  even for "simple" reads.
- **Security-scoped bookmark on macOS.** The vault URL is reached through
  `VaultStore.resolveBookmark()` which calls `startAccessingSecurityScopedResource`;
  every code path that touches the vault must go through it. Sandbox is on.
- **Logic belongs in KnotKit.** Anything platform-independent (parsing,
  formatting, routing, file shape) is unit-testable and should land in the
  package, not in app target code.
- **The two app targets share `Knot/Shared/`.** Don't fork the editor view
  per platform; extend it with platform conditionals if needed.
- **Settings persistence.** `AppSettings` lives as JSON in `UserDefaults`
  under `AppSettings.userDefaultsKey`. `EditorModel.resetAllSettings()` is
  the single reset path — it clears the bookmark, drops the JSON, and
  broadcasts `.knotSettingsReset` so platform code (macOS hotkey + detached
  window state) can clean up the bits the model doesn't own.
- **Failed writes spool to a persistent queue** in Application Support
  (`~/Library/Application Support/Knot`). If you change the write path,
  preserve the enqueue-on-failure behavior.
- **No telemetry, no network, no accounts.** The app is local-only by
  design; don't introduce anything that contradicts this.
- **`LSUIElement = true` on macOS** — Knot is a menu-bar app with no Dock
  icon. The Settings window is a regular `NSWindow` opened on demand.

## UI conventions

Visual constants are listed in `docs/design-brief.md` §7 — popover is
440×320 pt, corner radius 12, editor padding 16/8, min height 140, body
font 16 pt, status icon is SF Symbol `scribble.variable`. Colors are 100%
system semantic so dark mode and accent color work for free; introduce
custom colors only via the asset catalog.

## Pointers

- End-user behavior: `docs/usage.md`
- Designer-facing spec of every screen + open design questions:
  `docs/design-brief.md`
- High-level project overview + how-it-writes section: `README.md`
- Project structure: `project.yml` (always the source of truth)
