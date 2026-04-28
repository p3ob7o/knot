# CLAUDE.md

Guidance for Claude Code working in this repository.

## What Knot is

Single-purpose **quick-capture app for Obsidian users**, native,
local-only, macOS + iOS. One textarea — type a thought, press send,
and the text becomes a real `.md` file inside the user's Obsidian
vault. There is no list view, no editor, no sync; existing Obsidian
sync (Obsidian Sync / iCloud / Git / Syncthing) carries the file to
other devices.

Two destinations, auto-decided and always overridable via a Today /
Inbox segmented toggle:

- **Today** — short, single-line notes (≤ 280 chars by default) →
  bullet appended under a `## Quick notes` heading in today's daily
  note (`Daily/YYYY-MM-DD.md`).
- **Inbox** — longer or multi-line notes → new `.md` file in `Inbox/`
  (timestamp filename by default; if the first line is `# Title` with
  1–7 words, Knot uses the heading as the filename and strips it from
  the body).

On macOS the popover lives in the menu bar. A configurable global
hotkey summons it; dragging it (or right-clicking the menu-bar icon
→ *Detach*) tears it off into a free-floating window. On first
vault pick, Knot reads the user's Obsidian daily-note configuration
(Periodic Notes or Core Daily Notes), adopts the folder and filename
pattern, and surfaces the import in a small banner with *Undo* /
*Dismiss*.

Status: **v0.1** — capture loop end-to-end on both platforms,
configurable hotkey UI, vault-config import on pick, drag-to-detach.
Widgets, App Intents, and a share extension are tracked for v0.2+.

## Project layout

```
Knot/
  Shared/        SwiftUI views + view model used on both platforms
                 (EditorView, EditorModel @Observable, OnboardingView,
                  SettingsView, ModeToggle, Theme, VaultImportBanner)
  macOS/         AppKit shell — NSStatusItem popover, optional
                 detached NSWindow, ChromelessTextEditor,
                 WindowStateStore
    Hotkey/      Global hotkey: HotkeyManager, Shortcut, ShortcutStore,
                 ShortcutPickerView, KeyName
  iOS/           Single SwiftUI scene (NavigationStack + Settings sheet)
Packages/
  KnotKit/       Pure Swift package — file I/O, models, formatting,
                 unit tests. No platform dependency, no UI.
project.yml      XcodeGen project definition (the source of truth)
bootstrap.sh     Installs XcodeGen via Homebrew if needed, runs
                 xcodegen generate
scripts/
  bake-icons.swift   Renders the Knot mark SVG into the macOS .iconset
                     and the iOS 1024-pt icon
  release.sh         Builds, signs, notarizes, and DMG-packages
                     Knot-macOS for Direct Distribution
USAGE.md         End-user documentation
```

`KnotKit` is where the logic lives. The two app targets are thin
SwiftUI shells over it.

### KnotKit modules at a glance

`Vault` (entry point), `DailyAppender`, `InboxWriter`,
`HeadingSplicer` (splices bullets under `## Quick notes`),
`RoutingPolicy`, `MomentFormat` (Moment.js → Swift date formatting),
`BulletTemplate` (`{{HH:mm}}`, `{{content}}`), `TitleExtractor` (H1 →
filename), `Slug`, `AppSettings` (JSON in UserDefaults), `VaultStore`
(security-scoped bookmark), `ObsidianConfigImporter` (reads
`.obsidian/` daily-note config), `Queue` (persistent spool for failed
writes), `Note` model.

## Build & generate

The Xcode project is **generated** — never edit `Knot.xcodeproj` by
hand.

```sh
./bootstrap.sh           # installs xcodegen if missing, runs `xcodegen generate`
open Knot.xcodeproj
```

Targets: `Knot-macOS`, `Knot-iOS`. Deployment targets are macOS 26 /
iOS 26 (Xcode 26 required). Swift 6, minimal strict concurrency.

`Knot/{macOS,iOS}/Generated-Info.plist` is produced by XcodeGen —
don't edit it; change `project.yml` and re-run bootstrap.
Entitlements live in `Knot/macOS/Knot-macOS.entitlements` and
`Knot/iOS/Knot-iOS.entitlements`. App version comes from
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.

## Tests

KnotKit has the unit tests. Run them headless via SwiftPM:

```sh
swift test --package-path Packages/KnotKit
```

Or via the Xcode test action on either app scheme. Test files cover
the heading splicer, slug, Moment format, title extractor, bullet
template, routing, the Obsidian config importer, and a vault
integration test.

## Invariants — things to preserve when changing code

- **All file I/O goes through `NSFileCoordinator`.** Obsidian and
  Obsidian Sync use `NSFilePresenter`; daily-note appends are
  read-modify-write inside one coordination block; Inbox writes are
  atomic. Don't bypass this even for "simple" reads — including the
  reads inside `ObsidianConfigImporter`.
- **Security-scoped bookmark on macOS.** The vault URL is reached
  through `VaultStore.resolveBookmark()` which calls
  `startAccessingSecurityScopedResource`; every code path that
  touches the vault must go through it. Sandbox is on.
- **Logic belongs in KnotKit.** Anything platform-independent
  (parsing, formatting, routing, file shape, config import) is
  unit-testable and should land in the package, not in app target
  code.
- **The two app targets share `Knot/Shared/`.** Don't fork the editor
  view per platform; extend it with platform conditionals if needed.
- **Settings persistence.** `AppSettings` lives as JSON in
  `UserDefaults` under `AppSettings.userDefaultsKey`.
  `EditorModel.resetAllSettings()` is the single reset path — it
  clears the bookmark, drops the JSON, and broadcasts
  `.knotSettingsReset` so platform code (macOS hotkey + detached
  window state) can clean up the bits the model doesn't own.
- **Vault-import is undoable.** `EditorModel.setVault(url:)` returns
  a `VaultImportResult`; `VaultImportBanner` surfaces it with *Undo*
  (revert to the prior `AppSettings`) and *Dismiss*. Don't apply
  imported changes silently — the banner is the contract with the
  user.
- **Failed writes spool to a persistent queue** in Application
  Support (`~/Library/Application Support/Knot`). If you change the
  write path, preserve the enqueue-on-failure behavior.
- **No telemetry, no network, no accounts.** The app is local-only
  by design; don't introduce anything that contradicts this.
- **`LSUIElement = true` on macOS** — Knot is a menu-bar app with no
  Dock icon. The Settings window is a regular `NSWindow` opened on
  demand.

## UI conventions

The popover is 440×320 pt, corner radius 12, editor padding 16/8,
min height 140, body font 16 pt. The status-bar icon is the SF
Symbol `scribble.variable`. Colors are 100% system-semantic so dark
mode and accent color work for free; introduce custom colors only via
the asset catalog.

## Pointers

- End-user behavior: `USAGE.md`
- High-level project overview + how-it-writes section: `README.md`
- Project structure: `project.yml` (always the source of truth)
