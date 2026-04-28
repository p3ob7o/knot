# Knot

Ultra-focused quick capture for Obsidian. macOS + iOS, native,
local-only.

Knot is a single textarea: type a thought, press send, and the text
becomes a real `.md` file inside your Obsidian vault. There is no
list view, no editor, no sync. Your existing setup (Obsidian Sync,
iCloud, Git, Syncthing) carries the file to your other devices.

- **macOS** — menu-bar popover with a configurable global hotkey
  (default `⌃⌥K`). Tear the popover off into a free-floating window
  if you'd rather keep it on screen.
- **iOS** — single-screen app, designed for the home-screen icon, the
  Action Button, and Shortcuts.
- **Vault** — pick a folder once. Knot writes `.md` files into it. If
  your vault uses the Periodic Notes or Core Daily Notes plugins,
  Knot adopts their daily-note folder and filename pattern on first
  pick.
- **Privacy** — local-only by design. No accounts, no servers, no
  telemetry, no third parties.

See [USAGE.md](USAGE.md) for the full feature walkthrough.

## How notes are routed

Two destinations, auto-decided and always overridable via a Today /
Inbox toggle in the editor.

| Note shape                              | Destination                                                  |
| --------------------------------------- | ------------------------------------------------------------ |
| ≤ 280 characters and a single line      | Bullet appended under `## Quick notes` in today's daily file |
| > 280 characters **or** multi-line      | New `.md` file in the Inbox folder                           |

If an Inbox note's first line is `# Title` (1–7 words), Knot uses
that heading as the filename and strips it from the body. Otherwise
the filename is a timestamp.

All paths, the daily filename pattern, the heading text, the bullet
template, and the routing thresholds are configurable in Settings.

## Status

**v0.1** — first public release. Capture loop is end-to-end on both
platforms; macOS has a configurable global hotkey, a tear-off
detached window, and an importer for Obsidian's daily-note settings
on first vault pick.

Tracked for v0.2+: iOS widgets, App Intents and Shortcuts surface,
share-sheet extension.

## Requirements

- Xcode 26 or later
- macOS 26 / iOS 26 (deployment targets)
- A paid Apple Developer account if you want to install on a real
  iPhone for longer than 7 days
- An Obsidian vault accessible to the OS:
  - **macOS:** any folder you can navigate to.
  - **iOS:** the vault must be visible in the Files app — either
    iCloud Drive, or a local Obsidian vault with "Show in Files"
    enabled in Obsidian's vault settings.

## Build

The Xcode project is generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
./bootstrap.sh
open Knot.xcodeproj
```

`bootstrap.sh` installs XcodeGen via Homebrew if needed and runs
`xcodegen generate`. After that, build the `Knot-macOS` or `Knot-iOS`
scheme like any other project.

KnotKit (the logic core) has its own SwiftPM tests:

```sh
swift test --package-path Packages/KnotKit
```

## Project layout

```
Knot/
  Shared/        SwiftUI views and view model used on both platforms
  macOS/         AppKit shell — NSStatusItem popover, optional
                 detached NSWindow, global hotkey
  iOS/           Single SwiftUI scene
Packages/
  KnotKit/       Pure Swift package — file I/O, models, formatting,
                 unit tests. No UI, no platform deps.
project.yml      XcodeGen project definition (the source of truth)
USAGE.md         End-user documentation
```

`KnotKit` contains every platform-independent piece — file writing,
the "## Quick notes" heading splicer, slug generation, routing, the
Obsidian-config importer. The two app targets are thin SwiftUI
shells over it.

## How notes are written

**Short notes (≤ 280 chars, single line)** become a bullet appended
under the `## Quick notes` heading in
`<vault>/Daily/YYYY-MM-DD.md`. If the file or the heading don't
exist yet, Knot creates both. Format:

```markdown
## Quick notes

- 14:32 your note here
```

**Longer notes** become a new file at
`<vault>/Inbox/YYYY-MM-DD HHmm.md` (or
`<vault>/Inbox/<heading>.md` if the first line is a 1–7-word
`# Title`). On a filename collision, Knot appends a counter.

### Date format strings

Filename patterns use the [Moment.js display format
spec](https://momentjs.com/docs/#/displaying/format/) — the same
conventions Obsidian's Daily Notes / Periodic Notes plugins use, so
existing format strings (`YYYY-MM-DD`, `YYYY/MM/YYYY-MM-DD dddd`,
etc.) work as-is. Slashes act as path separators, so a daily
filename pattern of `YYYY/MM/YYYY-MM-DD` produces
`Daily/2026/04/2026-04-25.md`. Knot creates the subfolders for you.

In the daily-note **bullet** template, anything inside `{{...}}` is a
Moment pattern; `{{content}}` is the note text. Default:

```
- {{HH:mm}} {{content}}
```

You can use any Moment tokens, e.g.
`- [[{{YYYY-MM-DD}}]] {{HH:mm}} {{content}}`.

## Concurrency safety

Knot uses `NSFileCoordinator` for every read and write so Obsidian
and Obsidian Sync's own `FilePresenter`s coordinate correctly.
Daily-note appends are read-modify-write inside a single coordination
block; Inbox writes are atomic. If a true conflict happens
(typically because another device wrote the same daily file while
offline), Obsidian's own `*.conflict-*.md` convention takes over —
Knot doesn't try to outsmart it.

## License

GPL-2.0 — see [LICENSE](LICENSE).
