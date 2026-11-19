# Knot — Design Brief

A handoff document for a designer joining the project. Captures what the
app is, every screen and UI element it currently has, and the constraints
that shape the visuals.

## 1. What Knot is

Knot is a single-purpose **quick capture** app for Obsidian users. It
sits in the macOS menu bar (and as a normal app icon on iOS) and exposes
one textarea. You hit a global hotkey (or tap the icon), type a thought,
press send, and the text becomes a file inside your Obsidian vault.

There is no list of past notes, no editor, no formatting toolbar. The
whole product is "the gap between having a thought and having it written
down in your vault." Everything else — searching, editing, linking — is
Obsidian's job.

Two routes exist for a captured note:

- **Today** — short, single-line notes append as a bullet under a
  `## Quick notes` heading inside that day's daily note.
- **Inbox** — longer or multi-line notes become a new `.md` file in the
  Inbox folder.

The route is auto-decided but always overridable.

## 2. Target user & scenario

- **Who:** Existing Obsidian power users on macOS and iOS who already
  have Daily Notes / Periodic Notes plugins set up and a sync solution
  they trust (Obsidian Sync, iCloud, Git, Syncthing).
- **When they reach for it:** Walking, in a meeting, mid-flow on another
  task. They have a single thought (5 seconds to 30 seconds long) and
  need it on disk before they forget. Opening the full Obsidian app
  feels heavy for that.
- **Tone:** Calm, precise, slightly "tool-like." Not playful, not
  consumer. Think Things, Linear, Bear — not Notion or Snapchat.

## 3. Platforms & form factors

| Platform | Surface | Trigger |
| --- | --- | --- |
| macOS | Menu-bar popover (default) | Global hotkey, click status icon |
| macOS | Detached free-floating window (optional) | Same as above; user opts in |
| macOS | Settings window | Gear icon, right-click status icon |
| iOS | Single-screen app | Home-screen icon, Action Button, Shortcuts |
| iOS | Settings sheet | Gear icon |

Both platforms share the same SwiftUI editor view; only the surrounding
chrome differs.

## 4. Core surfaces

### 4.1 Status bar icon (macOS)

- Lives in the menu bar as a 16-point template image. Current glyph is
  the SF Symbol `scribble.variable`. Open to a custom mark.
- **Left-click** toggles the popover (or detached window).
- **Right-click** opens a small menu: *Detach Window* / *Reattach to
  Menu Bar*, *Settings…*, *Quit Knot*.
- No badge, no animation today. (Future: subtle "queued / syncing" hint.)

### 4.2 Popover (macOS, default)

- Anchored under the status icon, transient (clicking outside dismisses).
- Fixed size **440 × 320 pt**.
- Top-right corner: a small button cluster (16-pt SF Symbols, secondary
  foreground):
  - `pip.exit` — Detach to free-floating window.
  - `gearshape` — Open Settings.
- Body: the editor view (see §5).

### 4.3 Detached window (macOS, opt-in)

- A free-floating `NSWindow`, same 440 × 320 content size.
- Hidden title bar (`.titled + .fullSizeContentView`,
  `titlebarAppearsTransparent = true`); only the red close button is
  visible. The whole window is movable from anywhere on its chrome
  (`isMovableByWindowBackground`).
- Persistence: position and size are saved to `UserDefaults` on every
  move/resize/close, and the saved frame is clamped to a connected
  screen on reopen so a disconnected external monitor can't strand it.
- Top-right corner: same button cluster, but with `pip.enter` to mean
  "Reattach to menu bar."
- Close button hides the window (does not destroy state). The next
  hotkey/icon press reopens it at the saved spot.

### 4.4 Settings window (macOS)

- 520 × 560 pt, system-titled, closable, miniaturizable.
- Standard `Form` with `.grouped` style.
- Sections:
  1. **Vault** — current folder name, *Change…* button, optional error
     row, *Disconnect vault* destructive button.
  2. **Toggle Knot** — single-row shortcut recorder (see §6) with help
     copy below.
  3. **Folders** — `Daily folder`, `Inbox folder` text fields.
  4. **Daily note** — filename pattern, heading, bullet template; help
     footer linking to the Moment.js format reference.
  5. **Inbox** — filename pattern with subfolder/bracket help.
  6. **Routing** — max characters number field; "Force inbox when note
     has multiple lines" toggle.

### 4.5 Onboarding (both platforms)

Shown until a vault is selected. Otherwise the editor takes over.

- Title: "Knot" (bold).
- Subtitle: "Quick capture into your Obsidian vault."
- Four bullet points with a leading `•` glyph:
  - "Pick your vault folder once."
  - "Short notes append to today's daily file."
  - "Longer notes go to your inbox."
  - "Local-only — no servers, no accounts."
- Single bordered-prominent button: "Pick vault folder…" (folder icon).
- On error, a small red caption appears above the button.

### 4.6 iOS app

- `NavigationStack` with title "Knot" inline.
- Top-right toolbar: gear icon → presents Settings as a sheet with a
  *Done* button.
- Body: editor when a vault is set; otherwise the same onboarding view.

## 5. The editor (shared, primary surface)

The editor is the only screen most users will ever see. It has three
visible elements stacked vertically inside 16 pt of padding:

### 5.1 Textarea

- Multiline `TextEditor`, 16 pt system font.
- Placeholder text: *What's on your mind?* in secondary foreground,
  shown only when empty.
- Background: `.background.secondary`, 12 pt continuous corner radius,
  8 pt internal padding, **140 pt minimum height**.
- Auto-focused on appear so the user can type immediately.

### 5.2 Bottom row (left → right)

1. **Mode toggle** — segmented picker, max width 180 pt, two segments:
   - "Today" (= daily note bullet)
   - "Inbox" (= new file)
   - Always reflects the auto-routed mode unless the user has tapped
     to override; tapping just changes the mode for the current note.
   The auto rule today: > 280 chars **or** multi-line → Inbox.
2. **Spacer** — pushes the rest right.
3. **Status pill** — transient status:
   - `idle`: hidden.
   - `sending`: small `ProgressView`.
   - `sent`: green check (`checkmark.circle.fill`), fades out after
     ~1.2 s.
   - `error`: red triangle (`exclamationmark.triangle.fill`) +
     truncated message, full message in a tooltip.
4. **Send button** — plain-button-styled `arrow.up.circle.fill`, title
   size, 40 % opacity when disabled. Disabled when the textarea is
   empty, no vault is set, or a write is in flight.

### 5.3 Keyboard

- **⌘↩ / ⌃↩** — send.
- **Esc** — clear the textarea.
- **Tab / ⇧Tab** — focus is normally on the textarea so Tab inserts a
  tab character; the dismiss/send affordances live on hardware keys.

### 5.4 Visible states

| State          | Send button | Status pill                | Notes                |
| -------------- | ----------- | -------------------------- | -------------------- |
| No vault       | disabled    | hidden                     | Onboarding shown     |
| Empty editor   | disabled    | hidden                     | Placeholder visible  |
| Typing         | enabled     | hidden                     | Mode toggle live     |
| Sending        | disabled    | spinner                    | Brief                |
| Sent           | disabled\*  | green check                | Auto-clears in 1.2 s |
| Error          | enabled     | red triangle + tooltip     | Content stays        |

\* Becomes enabled again as soon as the user types.

## 6. Hotkey recorder (macOS settings only)

Implemented as a single editable "field" that captures the next keypress.

- Two visible states:
  1. **Display** — shows the current shortcut as Apple's symbol stack
     (`⌃ ⌥ ⇧ ⌘ K`) and a small × to clear.
  2. **Recording** — receives focus; placeholder reads
     "Press a single character with any combination of ⌃ ⌥ ⇧ ⌘".
- Accepts any printable single Unicode character (letters, digits,
  punctuation, currency, etc.) plus 0–4 modifier flags.
- *Backspace* clears the recorded value; *Esc* cancels recording.
- Below the field, a help line and an inline error row when macOS
  refuses to register the chosen combination (already-owned, reserved,
  or unsupported). Error copy is provided by `HotkeyManager`.

## 7. Visual constants currently in code

| Token                  | Value                |
| ---------------------- | -------------------- |
| Popover size           | 440 × 320 pt         |
| Settings window size   | 520 × 560 pt         |
| Corner radius          | 12 pt                |
| Editor outer padding   | 16 pt                |
| Editor inner padding   | 8 pt                 |
| Editor min height      | 140 pt               |
| Body font              | System 16 pt         |
| Status icon glyph      | SF Symbol `scribble.variable` |
| Send glyph             | `arrow.up.circle.fill` |
| Settings glyph         | `gearshape`          |
| Detach / Reattach      | `pip.exit` / `pip.enter` |
| Vault picker glyph     | `folder`             |
| Sent glyph             | `checkmark.circle.fill` (green) |
| Error glyph            | `exclamationmark.triangle.fill` (red) |

Colors today are 100 % system semantic colors so the app inherits dark
mode and accent color. Designer is welcome to keep that approach or
introduce a brand accent.

## 8. Constraints & non-goals

- **Stays out of the way.** The product loses if it ever feels like a
  full app. No tab bar, no list view, no past-notes browser inside
  Knot. Past notes live in Obsidian.
- **Plain text only.** No rich text styling, no inline media, no
  attachments. Markdown is the user's, not ours.
- **Local-only.** No servers, no accounts, no telemetry. The visual
  language should reflect that calm self-containment.
- **Sandboxed I/O on macOS.** The vault is accessed via a security-
  scoped bookmark the user grants once. Designs shouldn't imply
  multi-vault, vault discovery, or "open recent."
- **Latency budget.** From hotkey press to first keystroke landing in
  the textarea must feel instant (< 100 ms perceived). Animations on
  the popover/window appearance need to be subtle.

## 9. Open questions for the designer

These are the spots where we'd most like fresh thinking.

1. **App / status mark.** Today the status item is the SF Symbol
   `scribble.variable`. We need a custom mark that reads at 16 pt
   monochrome and works as an iOS app icon at 60–1024 pt.
2. **Empty editor.** Is "What's on your mind?" the right voice? Should
   the empty state look more like a notepad? A canvas? Nothing at all?
3. **Sent feedback.** Currently a 1.2 s green check fade. Could be a
   subtle slide-out, a dot returning to the icon, etc. The send must
   feel definitive but never noisy.
4. **Detached window chrome.** Today the title bar is hidden and the
   window is moved by background. We may want a slim grab handle, a
   subtle drop shadow tier, or a custom traffic-light layout.
5. **Mode toggle wording / shape.** "Today / Inbox" is functional; is
   there a cleaner metaphor (e.g. an icon pair, a single switch)?
6. **Routing affordance.** When the user crosses the auto-routing
   threshold mid-typing, the toggle silently flips from Today to
   Inbox. Should that transition be visible? Animated?
7. **Onboarding.** The current screen is a wall of text + one button.
   With a real brand mark and a richer welcome flow, what should the
   first-launch moment feel like?
8. **iOS Action Button / Lock Screen widget.** v0.1 will surface Knot
   from the Action Button; what does that affordance look like?

## 10. Reference flow (for storyboarding)

1. User invokes hotkey → menu-bar popover slides down under the icon.
2. Textarea is auto-focused. Cursor blinking. Mode toggle reads
   "Today" (auto).
3. User types two sentences. As they cross 280 characters or hit
   Enter, the toggle flips to "Inbox."
4. Press ⌘↩ → send button briefly disables, status spinner appears.
5. ~150 ms later: green check shows, popover stays open for 1.2 s with
   the textarea cleared.
6. User dismisses (Esc / click outside / hotkey again) and returns to
   what they were doing.
