# Handoff: Knot — Quick capture for Obsidian

## Overview

**Knot** is a single-purpose quick-capture app for Obsidian users. It lives in the macOS menu bar (and as a normal app on iOS) and exposes one textarea: hit a global hotkey, type a thought, press send, the text becomes a file inside the user's Obsidian vault.

Two routes for any captured note, decided automatically and always overridable:
- **Today** — short single-line notes append as a bullet under `## Quick notes` in today's daily note.
- **Inbox** — longer or multi-line notes become a new `.md` file in the Inbox folder.

The product loses if it ever feels like a full app. No list view, no editor, no past-notes browser. Past notes live in Obsidian.

This bundle covers four surfaces:
1. macOS popover (default editor)
2. macOS detached window (opt-in)
3. macOS Settings window
4. Onboarding (shared, two surfaces)

## About the design files

The files in this bundle (`Knot.html`, `src/*.jsx`, `styles/*.css`) are **design references prototyped in HTML/React/CSS**. They show the intended look, layout, and behavior — they are not production code to copy directly.

The real app is **SwiftUI** for macOS (and soon iOS). Your job is to recreate these designs in SwiftUI using its native primitives — `TextEditor`, `Picker`, `Form`, `NSPopover`, `NSWindow`, etc. — taking the exact measurements, colors, copy, and behaviors from the references and translating them to SwiftUI idioms. Where SwiftUI defaults already match the design (e.g. `Form { Section { … } }` styling on macOS Settings), prefer the default — these mocks are a target, not a straitjacket.

When in doubt, choose the more native option. The two design rules:
- **Function > form.**
- **Feel native on both platforms.**

## Fidelity

**High-fidelity** — final colors, typography, spacing, and interactions are locked in. Recreate pixel-perfect in SwiftUI where possible, falling back to system semantic colors and SF Symbols so the app inherits dark mode / accent color correctly.

## Files in this bundle

```
design_handoff_knot/
├── README.md                    ← this file
├── Knot.html                    ← entry point — open in a browser to preview
├── src/
│   ├── App.jsx                  ← top-level: design canvas with all artboards
│   ├── KnotMark.jsx             ← brand mark (inline SVG, currentColor-tinted)
│   ├── Editor.jsx               ← shared editor body (textarea + bottom row)
│   ├── Onboarding.jsx           ← first-run vault picker
│   ├── Settings.jsx             ← macOS settings window
│   ├── Shells.jsx               ← chrome: PopoverShell, DetachedShell, IOSShell
│   ├── Marks.jsx                ← brand showcase artboards
│   └── Glyph.jsx                ← SF-Symbol-equivalent glyphs
├── styles/
│   ├── tokens.css               ← design tokens (colors, type, radii, shadows)
│   └── components.css           ← every component's styles
├── assets/
│   ├── knot-mark.svg            ← canonical brand mark (use this in production)
│   └── knot-mark.png            ← processed PNG (transparency-cut)
└── lib/                         ← prototype scaffolding only — not for production
    ├── design-canvas.jsx
    ├── macos-window.jsx
    ├── tweaks-panel.jsx
    └── styles.css
```

To preview: open `Knot.html` in a modern browser. The canvas pans/zooms; double-click any artboard label to focus it fullscreen.

---

## Design tokens

All values pinned in `styles/tokens.css`. The actual SwiftUI build should map these to the closest semantic system colors where possible, but the exact values are listed here for fidelity reference.

### Typography
| Role | Stack | Notes |
| --- | --- | --- |
| UI | `-apple-system, BlinkMacSystemFont, "SF Pro Text"` | SwiftUI default — use `.body`, `.callout`, `.footnote` |
| Display (wordmark) | `Fraunces, Cooper, Charter, Iowan Old Style, Georgia` | **Used only for the "Knot" wordmark** in onboarding. App UI is all SF. |
| Mono | `ui-monospace, "SF Mono", "JetBrains Mono", Menlo` | Settings input fields with date patterns |

Body text size: **16pt system** in editor; **13pt** in Settings labels; **11pt** for help captions.

### Colors

#### Dark theme (primary)
| Token | Hex / value | Usage |
| --- | --- | --- |
| `--bg-window` | `#1d1d1f` | Window/popover background |
| `--bg-surface` | `#2a2a2c` | Textarea, settings cards |
| `--bg-surface-2` | `#353537` | Mode toggle thumb |
| `--bg-elev` | `#313133` | Elevated chips |
| `--border` | `rgba(255,255,255,0.08)` | Hairlines |
| `--border-strong` | `rgba(255,255,255,0.14)` | Focused inputs |
| `--fg` | `#f2f2f3` | Primary text |
| `--fg-2` | `rgba(242,242,243,0.72)` | Secondary text |
| `--fg-3` | `rgba(242,242,243,0.42)` | Tertiary / placeholder |
| `--fg-4` | `rgba(242,242,243,0.22)` | Disabled |

#### Light theme
| Token | Hex / value |
| --- | --- |
| `--bg-window` | `#f5f5f5` |
| `--bg-surface` | `#ffffff` |
| `--bg-surface-2` | `#f0f0f0` |
| `--border` | `rgba(0,0,0,0.08)` |
| `--fg` | `#1c1c1e` |
| `--fg-2` | `rgba(28,28,30,0.74)` |
| `--fg-3` | `rgba(28,28,30,0.46)` |

#### Accent & status
| Token | Hex |
| --- | --- |
| `--accent` | `#bfbfbf` (75% gray toward white — locked, intentionally desaturated) |
| `--accent-soft` | `rgba(191,191,191,0.18)` |
| `--ok` | `#65b07a` (saved checkmark) |
| `--warn` | `#d4a44a` |
| `--err` | `#d96a6a` (error pill) |

> **Note on accent.** The user picked a neutral gray accent over a sage green during exploration. Reasoning: Knot is a tool, not a product with personality — the accent is used only for the send button glow and focused fields, and a saturated color was distracting. If a future direction wants a real brand color, all `var(--accent)` references swap atomically.

### Spacing & sizing
| Token | Value |
| --- | --- |
| Popover size | **440 × 320 pt** |
| Detached window size | **440 × 320 pt** content |
| Settings window | **520 × 560 pt** (system-titled) |
| Window corner radius | **10pt** |
| Card / surface radius | **12pt** continuous |
| Editor outer padding | **16pt** |
| Editor inner padding | **8pt** |
| Editor min height | **140pt** |

### Shadows
- Window: `0 30px 60px -12px rgba(0,0,0,0.55), inset 0 0.5px 0 rgba(255,255,255,0.08)`
- Popover: `0 22px 48px -10px rgba(0,0,0,0.6), 0 2px 6px rgba(0,0,0,0.3)`

In SwiftUI on macOS these should come from `NSPopover`'s default appearance and `NSWindow.HasShadow` — the values above are what the mocks use to *match* the system look. Don't reinvent macOS window shadows in SwiftUI; use the system.

---

## Brand mark

The Knot mark is a stylized **K** built from four thick beveled bars: a vertical spine on the left and two diagonals on the right meeting at a square negative space. Reads as "K" first, "ribbon tied into a knot" second.

**Source files:**
- `assets/knot-mark.svg` — canonical artwork (potrace traced from user's original)
- `assets/knot-mark.png` — 256×256 with transparent background

**Sizes used in design:**
| Context | Size |
| --- | --- |
| Status bar (macOS menu bar) | **14pt template image** |
| Title-bar / inline | 16–20pt |
| Window content | 26–32pt |
| App icon | 64pt+ |
| Hero / onboarding | 56–140pt |

For SwiftUI: import `assets/knot-mark.svg` as an `Image` asset with **template rendering mode** so it inherits the foreground color (matches the menu-bar template-image requirement). Provide light-mode and dark-mode variants if needed, but the SVG is monochrome so a single template is sufficient.

iOS app icon: bake the mark onto a 1024×1024 squircle background (matching iOS app-icon corner radius — system handles the masking). The mark itself should occupy ~60% of the icon's safe area.

---

## Screen 1 — macOS popover (primary surface)

**Component file:** `src/Shells.jsx → PopoverShell`, with `src/Editor.jsx` as body.

**Layout:**
- 440 × 320 pt fixed.
- Anchored under the menu-bar status icon, dismisses on click-outside.
- Top: 38pt **chrome row** (no title bar). Right-aligned button cluster: a single 30×30 circular `pip.exit` button (Detach to window).
- Body: `Editor` view filling remaining height.

**Editor body:**
- Textarea: `--bg-surface`, 12pt continuous corner radius, 8pt inner padding, **140pt minimum height**, 16pt system font, placeholder "What's on your mind?" in `--fg-3` when empty. Auto-focused on appear.
- Bottom row (left → right):
  1. **Mode toggle** — segmented icon picker: `[📅 Today] [📥 Inbox]`. Max width 180pt. Active segment fills with `--bg-surface-2`, label `--fg`. Auto-flips between Today/Inbox based on routing rule; user tap overrides.
  2. **Spacer** (flex)
  3. **Status pill** — transient:
     - `idle`: hidden
     - `sending`: small ProgressView spinner
     - `sent`: green checkmark + "Saved" label, fades out after **1.2s**
     - `error`: red triangle + truncated message, full message in tooltip
  4. **Send button** — 30×30 circular, accent-filled, white arrow-up glyph. **40% opacity when disabled.** Disabled when textarea empty, no vault, or write in flight.

**Send feedback ("Saved" chip):**
The 1.2s confirmation is a green checkmark with the word "Saved" in `--ok` color. It appears in the status-pill slot, doesn't push other UI around. Picked over alternatives ("ribbon" with a destination label, "thread" with a horizontal line slide-out) for being the most calm and unambiguous.

**Routing flip animation:**
When typing crosses the auto-route threshold (>280 chars or first newline), the mode toggle's active segment slides from "Today" to "Inbox" with a 220ms ease-out. Subtle, no flash, no sound.

**Keyboard:**
- `⌘↩` / `⌃↩` — send
- `Esc` — clear textarea (does *not* dismiss the popover; click-outside or hotkey does)
- `Tab` — inserts a tab character (focus stays on textarea)

**States to implement:**
| State | Send button | Status pill | Notes |
| --- | --- | --- | --- |
| No vault | disabled | hidden | Onboarding shown instead |
| Empty editor | disabled | hidden | Placeholder visible |
| Typing | enabled | hidden | Mode toggle live |
| Sending | disabled | spinner | ~280ms |
| Sent | disabled* | green check + "Saved" | Auto-clears in 1200ms |
| Error | enabled | red + message | Content stays |

*Re-enables when user types again.

---

## Screen 2 — macOS detached window

**Component file:** `src/Shells.jsx → DetachedShell` (chrome variant: `"minimal"`).

Same 440 × 320pt content body as the popover, identical Editor inside. Differences:

- **Free-floating `NSWindow`** (`.titled + .fullSizeContentView`, `titlebarAppearsTransparent = true`).
- **Hidden title bar.** Only the **close traffic light** is visible — top-left corner. Min/max are removed.
- The whole window is **movable from anywhere on its chrome** (`isMovableByWindowBackground = true`).
- **Top-right** of the chrome row: `pip.enter` button to reattach to menu bar (mirrors the popover's `pip.exit`).
- Close button **hides** the window (does not destroy state). Next hotkey/icon press reopens at saved position.

**Persistence:** position and size to `UserDefaults` on every move/resize/close. On reopen, **clamp the saved frame to a connected screen** so a disconnected external monitor can't strand the window.

**Why "minimal" chrome was chosen over a slim grab handle:** the user already gets full window movement from `isMovableByWindowBackground`, and a visible handle would draw attention to chrome on a tool whose whole point is to disappear.

---

## Screen 3 — macOS Settings window

**Component file:** `src/Settings.jsx`. Reference `styles/components.css → .kn-settings*` for exact spacing, but the SwiftUI build should use **native `Form { Section { … } }` with `.formStyle(.grouped)`** — that gives you matching insets, group backgrounds, and dividers for free. Do not hand-roll cards in SwiftUI.

**Window:** 520 × 560pt, system-titled, closable, miniaturizable, **not resizable**.

**Sections (in order):**

1. **Vault**
   - Row: folder glyph + current vault name (e.g. "Gake") · `Change…` button (right-aligned).
   - Row: `Disconnect vault` destructive button (right-aligned).

2. **Toggle Knot** *(macOS only)*
   - Single hotkey recorder field: shows the current shortcut as a stack of `kbd` chips: `⌃ ⌥ ⇧ ⌘ K`. Click to enter recording mode (placeholder reads "Press a single character with any combination of ⌃ ⌥ ⇧ ⌘").
   - Help line below; inline error row if macOS rejects the combination.
   - Rules: 0–4 modifier flags + any printable Unicode character. Backspace clears, Esc cancels.

3. **Folders**
   - Row: `Daily folder` text input — default `1_Diary`.
   - Row: `Inbox folder` text input — default `0_Inbox/Quick Notes`.

4. **Daily note**
   - Row: `Filename pattern` — default `YYYY/MM/YYYY-MM-DD dddd` (Moment.js).
   - Row: `Heading` — default `## Quick notes` (must start with `#`).
   - Row: `Bullet format` — default `- {{HH:mm}} {{content}}`.
   - Footer help with link to Moment.js format reference.

5. **Inbox**
   - Row: `Filename` pattern — default `YYYY-MM-DD HHmm`.
   - Footer help: `Slashes create subfolders. Wrap literal text in [brackets].`

6. **Routing**
   - Row: `Max characters for daily` — number input, default `280`.
   - Row: `Force inbox when multiple lines` — toggle, default on.

All input fields with date patterns or paths use the **mono** font stack.

---

## Screen 4 — Onboarding (first launch)

**Component file:** `src/Onboarding.jsx`. Shown until a vault is selected; otherwise the editor takes over.

**Layout** (popover variant, 440 × 320pt):
- Hero (centered):
  - **"Knot"** wordmark — 22pt **Fraunces 700**, letter-spacing -0.02em.
  - Subtitle: *"Quick capture into your Obsidian vault."* — 13pt UI, `--fg-2`.
- **No logo mark** — the wordmark carries the moment.
- Bullet list (4 items, 12.5pt UI, `--fg-2`, 6px gap):
  - "Pick your vault folder once."
  - "Short notes append to today's daily file."
  - "Longer notes go to your inbox."
  - "Local-only — no servers, no accounts."
- Bottom CTA block (centered):
  - **"Pick vault folder…"** button — 32pt height, accent-filled (`--accent`), with leading folder glyph. Full width.
  - Tip below: *"Right-click the menu bar icon for settings."* — 11pt UI, `--fg-3`.
- Padding: 14pt top/bottom, 22pt sides. CTA uses `margin-top: auto` so it sticks to the bottom; 12pt margin above tip line.

**Error state:** if vault picker fails, a red caption appears above the button (font 12pt, `--err`).

**iOS variant:** same content, scaled to fill the iOS app's body. Same wordmark, same bullets, same CTA.

---

## Interactions & behavior

### Auto-routing rule
```
if note.length > 280 OR note contains newline:
    destination = inbox
else:
    destination = today
```
Both thresholds are user-configurable in Settings.

### Note titling (Inbox)
If a note starts with `# Heading` followed by 1–7 words on the same line, that heading becomes the filename and is stripped from the body. 8+ words, indented hashes, or `## H2` fall back to the timestamp filename.

### Daily-note bullet shape
```
## Quick notes

- 14:32 your note here
```
Knot creates the daily file and the heading on demand. Time prefix and bullet template are configurable.

### Animations
- Popover appearance: subtle slide-down from menu bar (system default — don't override).
- Mode toggle flip: 220ms ease-out cubic.
- Sent state: 1200ms hold, then 200ms fade.
- Send button press: scale 0.96 for 80ms.
- All animations should be skipped under `prefers-reduced-motion`.

### Latency budget
From hotkey press to first keystroke landing in the textarea must feel **instant (<100ms perceived)**. The popover should be pre-warmed and ready, not lazily constructed.

---

## State management

The app is small enough that a single `@StateObject` view-model holds everything:

- `vaultBookmark: Data?` — security-scoped bookmark for the vault folder (nil → onboarding).
- `text: String` — current draft.
- `overrideMode: Mode?` — user-tapped destination, nil = follow auto-route.
- `status: Status` — `.idle | .sending | .sent | .error(String)`.
- `settings: Settings` — daily folder, inbox folder, filename patterns, heading, bullet template, max chars, force-inbox-on-multiline.
- `hotkey: KeyCombo?` — registered global hotkey (macOS only).

Settings persisted in `UserDefaults`. Vault path stored as a security-scoped bookmark scoped to the app.

Writes use `NSFileCoordinator` for safety against concurrent device writes.

---

## Constraints & non-goals

- **Stays out of the way.** No tab bar, no list view, no past-notes browser. Past notes live in Obsidian.
- **Plain text only.** No rich-text styling, no inline media, no attachments.
- **Local-only.** No servers, no accounts, no telemetry.
- **Sandboxed I/O on macOS.** The vault is accessed via a security-scoped bookmark granted once. No multi-vault, no vault discovery, no "open recent."

---

## Open questions / future work

The current handoff covers v0.1. Items deferred:
- iOS Action Button mapping (settings-side wiring; UI is just an SF Symbol pick).
- Lock Screen widget for iOS.
- "Queued / syncing" hint for the menu bar status icon (subtle dot or animation).
- Full iOS app surface (the editor body works as-is on iOS; needs `NavigationStack` + sheet for Settings).

---

## Quick implementation pointers for SwiftUI

- **Editor body:** `TextEditor` with `.font(.system(size: 16))`, custom `.background(Color("Surface")).cornerRadius(12).padding(8)`. Placeholder via overlay (`TextEditor` doesn't support native placeholder).
- **Mode toggle:** `Picker("", selection: $mode) { Label("Today", systemImage: "calendar"); Label("Inbox", systemImage: "tray") }.pickerStyle(.segmented)`. Default macOS appearance is close to the mock; bind to a computed property that auto-routes when override is nil.
- **Send button:** `Button { send() } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: [.command])`.
- **Status pill:** swap a `ProgressView`, a `Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)`, or a `Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)` based on state. Animate with `.transition(.opacity)`.
- **Popover:** `NSPopover` with `.transient` behavior, anchored to a `NSStatusItem.button`.
- **Detached window:** `NSWindow` with `styleMask = [.titled, .closable, .fullSizeContentView]`, `titlebarAppearsTransparent = true`, `isMovableByWindowBackground = true`. Hide min/max with `standardWindowButton(.miniaturizeButton)?.isHidden = true`.
- **Settings:** `Settings { TabView { Form { Section { … } }.formStyle(.grouped) } }`. Native — don't hand-roll.
- **Status bar icon:** `NSStatusItem` with template image from `assets/knot-mark.svg` (set `image.isTemplate = true`).
- **Hotkey:** use `Carbon.HIToolbox` or a third-party wrapper like `KeyboardShortcuts` (sindresorhus). The recorder UI can be `KeyboardShortcuts.Recorder("", name: .toggleKnot)`.

---

## Final note

If anything in the mock contradicts a SwiftUI native default that would feel more at home on macOS or iOS, **trust the platform**. These references are a target for fidelity, not a contract that overrides system behavior.
