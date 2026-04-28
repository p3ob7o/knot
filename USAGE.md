# Using Knot

A short guide to capturing thoughts into your Obsidian vault with Knot.

## First run

1. Launch Knot.
2. The first screen asks you to **pick your vault folder**. Choose the
   root of your Obsidian vault (the folder that contains `.obsidian/`).
   On iOS, the folder must be visible in the Files app — iCloud Drive
   vaults work out of the box; local Obsidian vaults need the *Show in
   Files* toggle in Obsidian's vault settings.
3. **macOS only:** Knot installs itself as a menu-bar app. There is no
   Dock icon. Look for the small pen-stroke icon in the menu bar.

If your vault uses Obsidian's **Periodic Notes** community plugin or
the **Core Daily Notes** plugin, Knot reads the configured daily-note
folder and filename pattern from `.obsidian/` and adopts them
automatically. A small banner above the editor confirms what was
imported and offers an *Undo*.

## Capturing a note

1. Open Knot.
   - **macOS:** press the global hotkey (default **⌃⌥K**) or click the
     menu-bar icon.
   - **iOS:** tap the home-screen icon, the Action Button (if you've
     mapped it), or run a Shortcut.
2. The textarea is already focused. Start typing.
3. When you're done, **press ⌘↩** (or ⌃↩, or click the send arrow).
4. **Press Esc** to clear the textarea without sending.

That's it — the note is now a real `.md` file inside your vault, and
your existing sync (Obsidian Sync, iCloud, Git, Syncthing) carries it
to your other devices.

## Where notes go

Knot picks one of two destinations automatically based on what you
typed.

| Note shape                              | Destination                                         |
| --------------------------------------- | --------------------------------------------------- |
| ≤ 280 characters and a single line      | Bullet under `## Quick notes` in today's daily file |
| > 280 characters **or** multi-line      | New `.md` file in your Inbox folder                 |

You can override the destination at any time using the **Today /
Inbox** segmented toggle in the editor — the override applies to that
note only.

### Daily-note bullet shape

```
## Quick notes

- 14:32 your note here
```

Knot creates the daily file and the `## Quick notes` heading on
demand, then appends a new bullet on subsequent captures. The time
prefix and bullet shape are fully configurable.

### Inbox file shape

By default, a long note becomes
`Inbox/2026-04-25 1432.md` containing exactly what you typed.

#### Pro tip — name a note from its first line

If your note starts with a markdown H1 followed by **1 to 7 words** on
the same line, Knot uses that heading as the filename and strips it
from the body.

For example, this input:

```
# Project plan

- scope is roughly 4 weeks
- next: brief Anna
```

…lands at `Inbox/Project plan.md` with body:

```
- scope is roughly 4 weeks
- next: brief Anna
```

Eight or more words on the heading line, indented hashes, or `## H2`
headings all fall back to the timestamp filename, so you only get the
title behaviour when you're explicitly using it.

If your Inbox filename pattern includes date subfolders (e.g.
`YYYY/MM/YYYY-MM-DD HHmm`), they are preserved — your titled note
becomes `Inbox/2026/04/Project plan.md`.

## Settings reference

Open Settings via the **gear icon** in the editor's top-right corner,
or right-click the menu-bar icon (macOS).

### Vault

- **Change…** — pick a different vault folder. Your current capture
  in progress is preserved.
- **Disconnect vault** — clear the saved security-scoped bookmark.
  Knot returns to the onboarding screen.

### Toggle Knot (macOS only)

The hotkey that summons Knot. Click the field and press your desired
combination — any single printable character with any mix of ⌃ ⌥ ⇧ ⌘
modifiers works (including the four-modifier "Hyperkey" pattern).
*Backspace* clears the recorded value; *Esc* cancels recording. If
macOS refuses the combination (system reserved, already taken by
another app), Knot will tell you.

### Folders

- **Daily folder** — relative path from your vault root where daily
  notes live. Default `Daily`.
- **Inbox folder** — relative path for new Inbox files. Default
  `Inbox`.

### Daily note

- **Filename pattern** — Moment.js format string for the daily file
  name (no extension). Default `YYYY-MM-DD`. Slashes create
  subfolders, so `YYYY/MM/YYYY-MM-DD` produces
  `Daily/2026/04/2026-04-25.md`.
- **Heading** — the markdown heading bullets are appended under.
  Default `## Quick notes`. Must start with at least one `#`.
- **Bullet format** — template for each bullet. `{{HH:mm}}` and any
  Moment token inside `{{ }}` is formatted against the note's
  timestamp; `{{content}}` is replaced with your text.

  Examples:

  ```
  - {{HH:mm}} {{content}}
  - [[{{YYYY-MM-DD}}]] {{HH:mm}} {{content}}
  - **{{ddd}}** {{content}}
  ```

### Inbox

- **Filename** — Moment.js pattern for new Inbox files. Default
  `YYYY-MM-DD HHmm`. Slashes create subfolders. Wrap literal text in
  `[brackets]` so individual letters aren't interpreted as date tokens
  (e.g. `[Notes]/YYYY-MM-DD` → `Notes/2026-04-25`).

### Routing

- **Max characters for daily** — anything longer auto-routes to the
  Inbox.
- **Force inbox when note has multiple lines** — when on, any newline
  pushes the note to Inbox even if it's under the character limit.

## Date format reference

Filename and bullet patterns use the
[Moment.js display format spec](https://momentjs.com/docs/#/displaying/format/),
the same conventions Obsidian's Daily Notes / Periodic Notes plugins
use. Common tokens:

| Token   | Output            |
| ------- | ----------------- |
| `YYYY`  | 2026              |
| `MM`    | 04                |
| `DD`    | 25                |
| `HH`    | 14                |
| `mm`    | 32                |
| `dddd`  | Saturday          |
| `ddd`   | Sat               |
| `[…]`   | literal text      |

## macOS extras

- **Detach the popover into a window.** Two ways:
  - **Drag** the popover by its top chrome — it tears off into a
    free-floating window you can place anywhere.
  - **Right-click** the menu-bar icon → *Detach Window*.
  The window remembers its position. To switch back, right-click the
  menu-bar icon → *Reattach to Menu Bar*.
- **Right-click menu bar icon.** Quick access to *Detach / Reattach*,
  *Settings…*, and *Quit Knot*.

## Troubleshooting

- **Hotkey did nothing.** Open Settings → Toggle Knot. If macOS
  rejected your combination, an error row appears under the field.
  Pick another combination — combinations including ⌘⇧Q are reserved
  by macOS for log out.
- **"Vault permission lost" or writes fail.** macOS sometimes
  invalidates the security-scoped bookmark (e.g. after a major OS
  update). Disconnect and re-pick the same folder in Settings.
- **Two devices wrote at the same time.** Knot uses
  `NSFileCoordinator` so concurrent writes from Knot itself are safe.
  If a true conflict still happens (typically: another device wrote
  the daily file while offline), Obsidian's own `*.conflict-*.md`
  convention takes over.
- **My captured note never appeared.** Knot writes inside your vault.
  Check the configured **Daily folder** / **Inbox folder** — both are
  relative to your vault root. If they're empty, double-check
  Settings.
- **The vault-import banner showed the wrong daily folder.** Click
  *Undo* in the banner to revert to your previous settings. You can
  re-pick the vault later if you change your Obsidian config.

## Privacy

Knot is local-only. No accounts, no servers, no telemetry. Settings
live in `UserDefaults`; the path to your vault is stored as a
security-scoped bookmark scoped to this app.
