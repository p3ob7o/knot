# Knot

Ultra-focused quick capture for Obsidian. macOS + iOS, native, local-only.

Knot is a single-textarea native app that writes notes directly into your
Obsidian vault on the device. Short notes are appended to today's daily note
under a `## Quick notes` heading; longer notes become new files in your inbox
folder. No servers, no cloud, no third parties — Obsidian Sync (or whatever
you already use) handles propagation between your devices.

- **macOS:** menubar popover with a global hotkey (default `⌃⌥Space`).
- **iOS:** single-screen app, designed for the home-screen icon, Action Button,
  and Shortcuts.
- **Storage:** writes `.md` files directly to a vault folder you pick once.
- **Sync:** none — your existing Obsidian Sync / Git / iCloud setup carries
  the file to other devices.

## Status

v0 — end-to-end capture loop on both platforms. Widgets, App Intents,
share-sheet extension, and configurable hotkey UI are tracked for v0.1+.

## Requirements

- Xcode 26 or later
- macOS 26 / iOS 26 (deployment targets)
- A paid Apple Developer account if you want to install on a real iPhone for
  longer than 7 days or distribute via TestFlight / App Store
- An Obsidian vault accessible to the OS:
  - **macOS:** any folder you can navigate to
  - **iOS:** the vault must be visible in the Files app — either iCloud Drive,
    or an Obsidian local vault with "Show in Files" enabled in Obsidian's
    vault settings

## Build

The Xcode project is generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen). To bootstrap:

```sh
./bootstrap.sh
open Knot.xcodeproj
```

The `bootstrap.sh` script installs XcodeGen via Homebrew if needed and runs
`xcodegen generate`. After that, build and run the `Knot-macOS` or
`Knot-iOS` scheme in Xcode like any other project.

## Project layout

```
Knot/
  Shared/        SwiftUI views and view models used on both platforms
  macOS/         AppKit shell (NSStatusItem + popover + global hotkey)
  iOS/           iOS shell (single SwiftUI scene)
Packages/
  KnotKit/       Pure Swift package — file I/O, models, formatting, tests
project.yml      XcodeGen project definition
```

`KnotKit` contains all platform-independent logic — file writing, the
"## Quick notes" heading splicer, slug generation, routing — and is the
unit-testable core. The two app targets are thin SwiftUI shells over it.

## How notes are written

**Short notes (≤ 280 chars, single line)** become a bullet appended under
the `## Quick notes` heading in `<vault>/Daily/YYYY-MM-DD.md`. If the file
or the heading don't exist yet, both are created. Format:

```markdown
## Quick notes

- 14:32 your note here
```

**Longer notes** become a new file at
`<vault>/Inbox/YYYY-MM-DD HHmm - <slug>.md`, where `<slug>` is a lowercased
hyphenated version of the first line, max 50 characters. Filename collisions
are resolved by appending a counter.

All paths, the daily filename pattern, the heading text, the bullet format,
and the routing thresholds are configurable in Settings.

### Date format strings

Filename patterns use the [Moment.js display format
spec](https://momentjs.com/docs/#/displaying/format/) — the same conventions
Obsidian's Daily Notes / Periodic Notes plugins use, so existing format
strings (`YYYY-MM-DD`, `YYYY/MM/YYYY-MM-DD dddd`, etc.) work as-is.

Slashes are honoured as path separators, so a daily filename pattern of
`YYYY/MM/YYYY-MM-DD` will produce `Daily/2026/04/2026-04-25.md`. Subfolders
are created automatically.

In the daily-note **bullet** template, anything inside `{{...}}` is a Moment
pattern; `{{content}}` is the note text. Default:

```
- {{HH:mm}} {{content}}
```

You can use any Moment tokens, e.g. `- [[{{YYYY-MM-DD}}]] {{HH:mm}} {{content}}`.

## Concurrency safety

Knot uses `NSFileCoordinator` for every read and write so that Obsidian and
Obsidian Sync's own `FilePresenter`s coordinate correctly. Daily-note appends
are read-modify-write inside a single coordination block. Inbox writes use
atomic file creation. If a true conflict ever occurs, Obsidian's own
`*.conflict-*.md` convention takes over — Knot doesn't try to outsmart it.

## License

MIT — see [LICENSE](LICENSE).
