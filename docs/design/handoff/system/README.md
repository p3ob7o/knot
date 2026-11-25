Ready before you are. Nothing lost. Nothing to manage.

Knot is four native apps that feel like part of the system, not something installed on top of it. The system is the brand: Knot uses the controls, colours, type and glass that iOS, iPadOS, macOS and watchOS already have, each for the one job it was made for. Knot owns only five things: **the mark**, **ink as its tint**, **the red dot** (the record control), **the page** (how a note reads), and **its voice**. Everything in this system follows from that.

## Principles

1. **Use the system's element, and only for its job.** A list is a `List`, a setting is a row in a `Form`, a delete is a `.destructive` menu item, a search is `.searchable`. If the system has no element for a need (the record control, a voice segment), design one and keep it as plain as the system's own. Never reach for a SwiftUI element because it exists: the element map in *Elements* lists the one allowed for each need.
2. **Ready before you are.** Every way in ends on a focused field, a live microphone or a blank canvas. No launch screen beyond the system's, no walkthrough, no spinner, no confirmation.
3. **Content is paper, controls are glass.** Notes, rows and segments sit on `background` and never on Liquid Glass. Controls float on glass: system bars, the record control, the Mac capture panel, the undo capsule. Never put glass on glass.
4. **One colour, one meaning.** Ink (`label`, `accent`) for everything. `record` red only while a microphone is live. `attention` orange only when Knot needs you. Nothing else is coloured.
5. **Calm signals.** Every capture outcome gets one word, one glyph and one haptic. No alerts, no badges, no sounds that repeat, no exclamation marks.
6. **Fewer controls than you expect.** A control used on every visit is in the toolbar. A control used now and then is in a menu. Actions on a segment live in its context menu, never as buttons on every segment.

## Voice

- Write short, plain, present-tense sentences in sentence case. Address the person as "you". When Knot must speak of itself, it says "Knot": "Knot can't use the microphone."
- Say what happened and what is safe: "Too short. Nothing was kept." "Saved, text on its way." "Nothing was deleted."
- Never write "Oops", "Successfully", "Please", "Error:", exclamation marks or emoji. Never apologise for the system.
- Start buttons with the verb: "Restore", "Keep mine", "Retry", "Show", "Undo", "Make it here", "Update". Use the brief's words exactly: note, segment, capture, stream (in copy the stream is titled "Notes").
- Name the six segment states only as *States* names them. Do not invent synonyms ("processing", "syncing", "error").
- Times are compact and absolute: "9:41" today, "Yesterday", "Tue" this week, "24 Nov" before that. Never "12 seconds ago".
- Use the typographer's apostrophe and quotes (’ “ ”) and the ellipsis character (…) for commands that ask for more, like "Share…" and "Export all notes…".

## Colour

Knot is paper and ink. Paper is `background`; ink is `label`. Use the system's semantic colours by name and never hard-code their values: the values in `tokens.json` are references for design work, and the system adjusts them for Increase Contrast, vibrancy and each release.

| Role | Token | iOS · iPadOS | macOS |
| --- | --- | --- | --- |
| Paper: capture surface, note, stream | `background` | `systemBackground` | `textBackgroundColor` |
| Settings ground, rows | `background-grouped`, `background-grouped-cell` | grouped backgrounds | `.formStyle(.grouped)` |
| Ink: everything written, toolbar glyphs | `label` | `.primary` | `labelColor` |
| Metadata: previews, times, pending states | `label-secondary` | `.secondary` | `secondaryLabelColor` |
| Placeholder, disabled | `label-tertiary` | `.tertiary` | `placeholderTextColor` |
| Unplayed waveform | `label-quaternary` | `.quaternary` | `quaternaryLabelColor` |
| Notice ground, menu-open highlight | `fill-tertiary` | `tertiarySystemFill` | `tertiarySystemFill` |
| Tint | `accent` | AccentColor asset | AccentColor (Multicolor only) |
| Live microphone | `record` | `Color.red` | `Color.red` |
| Needs you | `attention` | "Attention" asset | "Attention" asset |

- **The tint is ink.** Set the AccentColor asset to `#000000` (Any) and `#FFFFFF` (Dark). Prominent glass buttons (Done) fill with it and carry `on-accent`. Text buttons in ink read as buttons by their weight (semibold) and shape (`.bordered` capsules), never by colour.
- **The red dot.** `record` appears only on the record control while starting, live or stopping, in the live waveform, and in the Dynamic Island while recording. Never use red for a heading, a badge, an error or a brand flourish. The one exception is the system's own: a `.destructive` menu item is red because iOS and macOS paint it so.
- **Attention.** `attention` marks "Needs you" and the surface problems in *States*: the glyph and, on paper, the word. Light uses Apple's increased-contrast orange (`#C55300`) at all times so the word reads; dark uses `systemOrange`.
- **Leave the system's colours alone.** Toggles stay system green (`toggle-on`); the Mac keeps the person's accent for selection and focus; the keyboard, sheets, menus and alerts keep their own surfaces.
- **Contrast.** `label` reads at 15:1 or more on every background in every theme. `label-secondary` is the system's and stays exact: 3.4:1 on iOS light paper and 4.0:1 on macOS light, below WCAG AA for small text (it passes in dark). Use it only for metadata that supplements ink nearby, never for the only copy of something a person must read. `record` and `on-record` are for glyphs (3:1 or more), never for text; the live timer sits beside the red control in `label`.
- `glass`, `glass-edge`, `shadow-glass` and `shadow-panel` exist only so these web previews can suggest Liquid Glass. In the apps, glass is never a colour.

## Typography

- Use the system fonts and nothing else: **SF Pro** on iPhone, iPad and Mac, **SF Compact** on Apple Watch, **SF Compact Rounded** in complications (the system applies it). Do not embed or bundle any font; this system ships none.
- Set every piece of text with a text style (`.font(.body)`), never a point size, so Dynamic Type works up to AX5. The sizes in the type groups are each style at the default size; they grow with the person's setting.
- Knot's whole hierarchy is five styles per platform:

| Role | iOS · iPadOS | macOS | watchOS |
| --- | --- | --- | --- |
| What a person wrote; the capture field | `ios-body` | `mac-body` (panel: `mac-title2`) | `watch-body` |
| A stream row's title | `ios-headline` | `mac-headline` | |
| A stream row's preview | `ios-subheadline`, secondary | `mac-subheadline`, secondary | |
| Meta lines, segment states, captions | `ios-footnote`, secondary | `mac-subheadline` / `mac-footnote` | `watch-footnote1` |
| A notice's sentence | `ios-callout` | `mac-callout` | |

- Inside a note, light Markdown renders as the system would: `#` in Title 2 emphasized, `##` in Title 3 emphasized, `**bold**` in the emphasized weight of Body, lists as text. No other styling, no colours, no fonts per note.
- Show timers and durations with monospaced digits (`.monospacedDigit()`), so "0:12" does not jitter.
- Keep weight changes to the style's emphasized weight (`.bold()` on a text style). Never use Light, Thin or Black weights.
- At accessibility sizes, let a stream row's preview go first, then stack the meta line under the title; never truncate a title to one line.

## Layout and spacing

- Respect the safe area and the system's layout margins: `space-4` on compact width, `space-5` on regular. Never hard-code them.
- On iPad and Mac, keep note text within `readable-width` (the readable content width, which grows with Dynamic Type), aligned to the leading margin.
- A note is a page: segments stack with `space-6` between them and nothing else, no dividers, cards or bubbles. A segment's marks and state take one footnote line at its foot, `space-2` below its text.
- Place the capture field last in every note, `space-6` below the last segment. When the append window is open, the note being added to sits above the field in `label-secondary`, with a footnote line ("Adding to the note from 9:38") `space-2` above it.
- Give every tappable thing at least `hit-target` (44 pt) on iPhone, iPad and Watch, and `hit-target-mac` (28 pt) on the Mac, even when the glyph is smaller.
- Use the spacing tokens in steps of 4: `space-1` 4, `space-2` 8, `space-3` 12, `space-4` 16, `space-5` 20, `space-6` 24, `space-8` 32.

## Shape and material

- Let the system round its own components. Knot's own shapes use the radius tokens: `radius-full` for capsules (record control, undo capsule, waveform bars, small buttons), `radius-lg` for an inline notice, `radius-md` for a highlighted segment, `radius-xl` for the Mac capture panel.
- Keep corners concentric: an inner shape's radius is the outer radius minus the padding between them. In SwiftUI, use `ConcentricRectangle` and `containerShape` rather than numbers.
- **Liquid Glass, where it goes:** the system toolbars and their buttons (`.buttonStyle(.glass)`), the Done button (`.glassProminent`, tinted ink), the record control (`.glass` idle, `.glassProminent` tinted `record` while live), the search field (`.searchable`), the Mac capture panel and menu bar extra, the undo capsule. Use the *regular* variant everywhere; Knot has no media backgrounds, so never *clear*.
- **Where it never goes:** note text, segments, stream rows, notices, Settings rows, widgets' content. Never tint glass for decoration; only Done (ink) and the live record control (red) are tinted.
- Do not draw shadows, gradients or blur yourself. iOS 27 lets people set how clear or tinted glass is; Knot looks right at every setting because it puts nothing on glass but controls.

## Iconography

- Use SF Symbols only, weight-matched to the adjacent text (`.imageScale` with the text style), in `label` unless a state below says otherwise. Use the hierarchical rendering mode for state glyphs.
- The glyphs in this system's previews are hand-drawn stand-ins for the symbols named here; the apps use the symbols themselves.

| Concept | SF Symbol |
| --- | --- |
| Record, idle / starting | `mic` / `mic.fill` |
| Stop | `stop.fill` |
| Saved | `checkmark` |
| Couldn't start, microphone refused | `mic.slash` |
| New note | `square.and.pencil` |
| The stream (from the capture surface) | `list.bullet` |
| Search | `magnifyingglass` |
| Kinds: text, voice, ink | `text.alignleft`, `waveform`, `scribble` |
| Pending (on its way) | `ellipsis.circle` |
| Saved on the Watch / text made elsewhere | `applewatch` / `laptopcomputer`, `iphone`, `ipad` |
| Needs you | `exclamationmark.triangle.fill` in `attention` |
| Added from the command line or an assistant | `apple.terminal` |
| Recording missing / Remove recording | `waveform.slash` |
| Made by a newer Knot | `arrow.down.circle` |
| Arrived | an 8 pt ink dot in the stream; `tray.and.arrow.down` in a notice |
| Undo | `arrow.uturn.backward` |
| Move to its own note | `rectangle.portrait.and.arrow.right` |
| Show original | `doc.plaintext` |
| Retry | `arrow.clockwise` |
| Edit conflict | `arrow.triangle.2.circlepath` |
| Notes can't be read | `exclamationmark.icloud` |
| Sketch (iPad) | `pencil.tip` |

- **The mark** (a K of four bars) appears only where Knot stands for itself outside its own windows: the app icon, widgets, the Lock Screen accessory, complications, the Mac menu bar extra (as a template image) and the Live Activity's attribution. Never inside a note, toolbar or row. Recolour it with any single ink; never change its shape, cut, proportions or add effects. See the Logos group.

## Motion, haptics and sound

- Animate with the system's springs (`.smooth` by default, `.snappy` for the record control's morph from circle to live fill). No custom curves, no bounces, no looping animation except the live waveform, which follows the input level.
- With Reduce Motion on, replace morphs with crossfades and freeze the live waveform to a level bar.
- Every outcome has one haptic (`.sensoryFeedback` on iPhone and iPad, `WKHapticType` on Watch):

| Outcome | iPhone · iPad | Watch | Mac |
| --- | --- | --- | --- |
| Live | `.start` | `.start` | panel shows red; no sound |
| Saved | `.stop` | `.stop`, then `.success` | the checkmark, one second |
| Too short, nothing kept | `.warning` | `.retry` | the sentence in the panel |
| Couldn't start | `.error` | `.failure` | the notice |
| Stopped at the limit | `.stop` | `.stop`, then `.notification` | the notice |
| Deleted (undo available) | `.impact(weight: .light)` | none | none |

- Knot plays no sounds of its own. The system's own sounds (keyboard clicks, screenshot) are the system's.

## Accessibility

- Label the record control by state ("Record", "Stop recording, 0:12") and announce outcomes with `AccessibilityNotification.Announcement` in the words above.
- Give every segment `accessibilityActions` matching its context menu, so VoiceOver and Switch Control reach every action without long press.
- Support Large Content Viewer on toolbar buttons and the record control, Bold Text, Increase Contrast (custom colours carry their increased-contrast variants), Reduce Transparency (glass becomes opaque by itself) and Differentiate Without Colour (every state already has a word and a glyph).
- Keyboard: ⌘N New note, ⌘F Search, ⌘↩ Done, ⌘⌫ Delete segment, ⌘Z Undo, ⌘, Settings; Esc closes the Mac panel. List them in the iPad and Mac menu bars so the ⌘ overlay shows them.
