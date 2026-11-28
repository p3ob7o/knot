# Knot: design brief

For Claude Design · drafted 2026-11-18, brought up to the spec on 2026-11-24 · still waits for Paolo's review

Attach two things with this brief: the product spec (`docs/product-spec.md`) and the mark (`Resources/Brand/knot-mark.svg`).

## 1. The ask

Design Knot from a blank page. Knot is a thought-capture app for iPhone, iPad, Mac and Apple Watch. Only its name and its mark are fixed.

We need three things:

- a visual language;
- the layout and behaviour of every surface in section 6;
- a handoff that engineers can build in SwiftUI.

An earlier design round exists for a different product that carried the same name. It is not a constraint.

## 2. The product

Knot gets a thought out of your head and into a note with as little friction as the device allows. You type it, say it, or write it by hand. Every capture lands in one stream, newest first. There is nothing to file and nothing to set up.

Three promises, in priority order:

1. **Ready before you are.** Every way in ends where your next action is the capture itself: a focused text field, a live microphone, or a blank canvas.
2. **Nothing is lost.** A capture is saved before anything else happens to it.
3. **Nothing to manage.** One stream with search. No folders, tags or links.

Knot is used by one person at first, its author. He reaches for it dozens of times a day on four devices, usually in the middle of something else: walking, in a meeting, at the keyboard. It is built to App Store standard.

## 3. Words we use

| Term | Meaning |
|---|---|
| Stream | The single list of all notes, newest first. |
| Note | One entry in the stream: an ordered list of segments and an optional title. |
| Capture | One act of input: a typing session, a recording, or a drawing. |
| Segment | What a capture becomes inside a note. There are three kinds: typed, voice and ink. |
| Append window | Five minutes by default, set by the user. Zero turns it off. A capture that starts inside the window joins the previous note. One that starts after it begins a new note. |
| Pending | A segment still being processed: on its way from the watch, or not yet transcribed. |

The append window shapes the layout more than anything else. A note is often built from several quick captures: a typed line, then a spoken thought, then a sketch. The person capturing should see what they are adding to, and be able to start a new note with one action, wherever the capture surface shows the note: the iPhone and iPad capture surface, the Mac panel and an open note. Capturing inside an open note always adds to it.

A voice segment goes through visible stages: recording, then a raw transcript, then, where cleanup runs and keeps your words, cleaned text that replaces it. Raw text alone is a finished state too. The recording stays attached and playable until you remove it.

## 4. The feel

"Extremely elegant and minimalist" are the owner's words. Knot does one thing, and the design should make that one thing feel inevitable.

- **The first frame is the capture.** No splash, no home screen, nothing to get past.
- **One primary action per surface.**
- **Type carries the design.** The content is words. Treat a note as a page, not a form or a chat.
- **Quiet until it matters.** Recording, pending and failed must be unmistakable at a glance, and still calm.
- **One idea, four native apps.** Each device should feel made for it, using its own materials and conventions, and still be recognisably Knot.
- **Motion explains a change of state, or it is not there.**

### References, in the owner's words

"I like clean lines, minimal controls."

- Apps he likes: Notion Calendar, Things, Bear.
- Objects he likes: the Leica Q3 camera, the iPad mini, the Schindelhauer Arthur X electric bicycle.

"I dislike tons of buttons, no OS integration."

- Apps he dislikes: every Electron app.
- Objects he dislikes: smartphones from before the iPhone, most microwave ovens, Sony cameras.

Our reading of these, for him to correct:

- **Few controls, each with one job and a precise feel.** The Q3 has one fixed lens and a handful of dials.
- **Complexity lives inside, not on the surface.** The Arthur hides its motor and battery and looks like a classic bicycle.
- **Options are not buttons.** A microwave's preset panel and a Sony menu are the failures to avoid.
- **The app belongs to its operating system.** It uses the system's own controls, materials and entry points so fully that nobody could take it for a port.

## 5. Fixed and open

**Fixed**

- The name and the mark, a K built from four bars. It may be recoloured and placed. Its shape does not change.
- The behaviour in the product spec.
- The platforms: iOS, iPadOS, macOS and watchOS 27, with their system conventions (Dynamic Island, Control Center, complications, the menu bar).
- No account, no walkthrough, no marketing moments inside the app.
- The editing model. A note is a stack of segments separated by spacing alone. Each is edited on its own, in place, as plain text with Markdown lightly styled. A selection stops at the end of its segment, undo covers the segment being edited, and copying the whole note is one action. The capture field is the last element of every open note. "A page" describes how a note reads. If the design needs a different editing model, say so in the direction step, because code is built on it.
- With the window open, the capture surface is the note you are adding to, with its field focused, and capturing in an older note looks the same. How much of the note shows, and how, is open.

**Open**

- Everything visual: colour, type, spacing, shape, materials, motion.
- The layout and navigation of every surface.
- The questions in section 7.
- How far Knot leans on the system's glass materials, and how far it sets its own tone within them.

## 6. Surfaces and states

Each list names the states a surface must be designed in. The matrix at the end of this section is the checklist: every cell is designed, inherits from a named cell, or does not apply.

### iPhone

- **Capture**, which is what the app opens to:
  - empty, keyboard up;
  - typing;
  - typing, then a recording started from the Action Button or a control: the typed text is saved as its own segment, and the recording follows it in the same note. Show how the surface says that the typed text was saved;
  - adding to an open note, with its earlier segments visible. If the window runs out while the field is still empty, that note leaves the surface. After the first keystroke it stays, because the note is fixed then;
  - the moment between the press and a live microphone, which must not look like recording;
  - recording, with the words appearing, and the text field and Pencil not accepting input while it runs;
  - on an iPhone that supports Apple Pencil, ink in progress and ending a drawing, as on the iPad;
  - just stopped, as the transcript arrives and the cleaned text replaces it;
  - a short recording discarded, saying that nothing was kept;
  - a recording that stopped at its 30-minute limit, was ended by a call, or stopped because the disk filled, saying why;
  - a recording that cannot start: permission refused, no space, the microphone in use;
  - text that could not be saved, with the surface staying open.
- **Stream:**
  - a row: the title or first line, a short preview, the time, the kinds of segment, and any pending or failed state. At large sizes the preview gives way first, then the kinds. The title or first line, the time and a failed marker always stay;
  - populated;
  - empty on first run, with the line about sync, for sync on and for sync you switched off, and up to three dismissible setup rows. Propose the line for sync you switched off;
  - rows holding pending and failed segments;
  - a row for a note with no text yet ("Recording, 0:42", "Sketch");
  - a row at the largest text size;
  - captures that arrived late, each marked until its note is opened, with the line that says so and a way to go to them;
  - the first restore from iCloud, while the stream is still filling;
  - search with results, and with none;
  - the notes could not be opened, with capture still working.
- **Note:**
  - a note mixing typed, voice and ink segments;
  - a title: none, generated, typed, and being edited;
  - a segment being edited;
  - capturing inside an older note, with the capture field as its last element;
  - a voice segment in each of its states: saved on the Watch, text on its way, text being made on another device, ready, needs you, kept with no text, with the action that moves the work to this device, where the spec offers it;
  - a voice segment playing;
  - "show original" on a voice segment;
  - a voice segment after "Remove recording": text with no player;
  - an ink segment in the states of section 5 of the spec: being recognised; recognised; recognition failed, with Retry; kept with no text, because nothing was recognised or because the drawing cannot be read, with a placeholder in its place;
  - a conflict copy;
  - a segment written from the command line or MCP, with its quiet mark;
  - a segment made by a newer Knot;
  - a recording or drawing made on another device: waiting, downloading, unavailable;
  - a typed segment or a drawing whose save failed, showing "Needs you" with its content kept, while Knot stores it by itself;
  - delete with undo;
  - a note you have open, deleted on another device, saying so and offering to restore it;
  - "Move to its own note" on a segment, where it is offered (not on the only capture of a note, not on one in progress), and the moment after it, with the note it left still open and undo;
  - share.
- **Recording outside the app:** the Live Activity on the Lock Screen; the Dynamic Island compact, minimal and expanded; the finished state. These show a timer, a level and a stop control, never the words. They also show, without any text from the note, whether the recording continues a note or starts a new one. Include the moment between the press and a live microphone, which must not look like recording; the state where a recording could not start, with its reason and a way to open Knot; and the limit reached. Design both branches of the one thing a spike still decides: a recording that starts from the locked phone, and one that starts only after Face ID opens Knot. The system may also show the Live Activity in the Watch's Smart Stack and in the Mac's menu bar, and it carries no text there either.
- **Launchers:** Control Center and Lock Screen controls (Record, New note, Search); Lock Screen widgets, a Search widget among them; a small Home Screen widget. Launchers never show note text. They may show state: recording with its timer, captures waiting, captures failed.
- **Settings:** the short list in the spec, and nothing more. It includes sync status (off, syncing, error, iCloud storage full, no iCloud account), the prompt shown when the iCloud account changes, the prompt shown when the notes were removed from iCloud, the row that explains why cleanup is unavailable, the row that says Live Activities are off, export of all notes with its progress and a list of anything it could not fetch, and the recently-deleted list. In test builds, About also offers a diagnostics export, an export of the store as it is, and a restore of a kept copy, which says how many recordings and drawings it could not bring back.
- **First-run moments:** the microphone request, the first time you record; the speech model still downloading. How to assign the Action Button is a row in Settings and one of the first-run stream's setup rows, not a screen of its own.

### iPad

- The stream and a note side by side, with capture inside that layout. At launch the open column is the capture surface.
- Where two columns do not fit, in portrait on an iPad mini, in Split View or in a narrow window, the iPad uses the iPhone's layout. Show it there, also with the keyboard up and at the largest text size.
- The capture surface shared by keyboard and Pencil: ink in progress, the tool affordance (minimal, with Pencil Pro squeeze), ending an ink capture, and a drawing stopped because the disk filled, saying why.
- The Sketch control opening the canvas; the menu bar and shortcuts with a hardware keyboard. On the capture surface the Pencil always draws, and the system's handwriting-to-text is off there.
- An ink segment inside a note: the drawing, its recognised text, copying it as text.

### Mac

- **The floating capture panel:**
  - empty;
  - typing;
  - typing, then a recording started from the microphone control or a held key: the typed text is saved as its own segment, and the recording follows it in the same note. Show how the panel says that the typed text was saved;
  - adding to an open note;
  - the key held, in the moment before the microphone is live;
  - recording while the key is held, with the words and a level;
  - just released, and how the panel leaves by itself;
  - a short recording discarded, saying that nothing was kept. Only a recording started by a click on the microphone control, from Siri or from Shortcuts can be discarded: a hold is exempt;
  - the limit reached, or the disk full;
  - no microphone permission;
  - no microphone connected, as on a Mac Studio;
  - recording started from the microphone control, Siri or Shortcuts, with a stop control because no key is held, which also covers a key release that was missed;
  - text that could not be saved, with the panel staying open.

  The panel floats over other apps, including full-screen ones.
- **Menu bar:** the icon idle and recording, and its menu.
- **Main window:** stream, search and the open note, with capturing inside an older note; the empty state; a narrow window; dragging a note out of the window.
- **Settings,** including the hotkey recorder, a key that another app already uses, and the command-line access switch, with both ways of putting `knot` on the PATH, which WP-34 still decides (a folder you pick, or one line to run), and the note for sandboxed MCP clients with the tool's path.
- **First run:** choosing the hotkey, and showing tap versus hold once. Design it both with and without a system permission prompt for the hotkey, which a spike still decides.

### Apple Watch

Design for the Ultra 2 first, then the smaller sizes.

- **Recording,** the watch app's one screen: idle with one control; the moment between the press and a live microphone, which must not look like recording; recording, with a timer and a level; recording with the display dimmed; saved; a short recording discarded; stopped at the limit, by a call, or with storage full; could not start, with the reason; storage nearly full. Design both a start that needs the app in front and one that does not, which a spike still decides. There is no list of recordings. The watch is a capture device only: it never shows the text of a note or of a recording, and it says nothing about a transcript.
- **Complications** in each family, the Smart Stack widget, and the control glyph, each idle, recording, with captures waiting, and with captures failed. The complication's count of waiting recordings is how the watch tells that a recording has not reached the phone yet.

### Across devices

- **Glyphs:** markers for typed, voice and ink; pending; failed; conflict; arrived; written from the command line or MCP; record and stop.
- **Motion:** the capture surface arriving; a recording starting and stopping; a segment landing in the stream; pending becoming ready. Give the Reduce Motion version of each.
- **Haptics and sound:** the events in section 4.5 of the spec, on each device.
- **The mark in use:** the menu bar template, the complication, and the app icon appearances (default, dark, clear, tinted).

### The state matrix

"Yes" means the state is designed for that surface. A device name means the surface inherits that device's design. A dash means the state does not apply.

| State | iPhone | iPad | Mac panel | Mac window | Watch | Outside the app |
|---|---|---|---|---|---|---|
| Capture, empty | Yes | Yes | Yes | – | – | – |
| Capture, typing | Yes | iPhone | Yes | – | – | – |
| Capture, typing ended by a recording | Yes | iPhone | Yes | – | – | – |
| Capture, adding to an open note; the window running out | Yes | Yes | Yes | – | – | – |
| Capture inside an older note | Yes | iPhone | – | Yes | – | – |
| Recording, live | Yes | iPhone | Yes | Mac panel | Yes | Yes |
| Recording, before the microphone is live | Yes | iPhone | Yes | Mac panel | Yes | Yes |
| Recording, typing and Pencil not accepted | Yes | Yes | – | – | – | – |
| Recording, continues a note or starts a new one | – | – | Yes | – | Yes | Yes |
| Recording, display dimmed | – | – | – | – | Yes | – |
| Just stopped: saved, with text arriving except on the Watch | Yes | iPhone | Yes | Mac panel | Yes | Yes |
| Short recording discarded | Yes | iPhone | Yes | Mac panel | Yes | Yes |
| Stopped at the limit, by a call, or with the disk full | Yes | iPhone | Yes | Mac panel | Yes | Yes |
| Could not start, with the reason | Yes | iPhone | Yes | Mac panel | Yes | Yes |
| No microphone connected | – | – | Yes | Mac panel | – | – |
| Text could not be saved | Yes | iPhone | Yes | Mac panel | – | – |
| Ink in progress; ending a drawing | iPad | Yes | – | – | – | – |
| Stream, populated | Yes | Yes | – | Yes | – | – |
| Stream, first run | Yes | iPhone | – | Yes | – | – |
| Stream, row with no text yet | Yes | iPhone | – | iPhone | – | – |
| Stream, rows pending and failed | Yes | iPhone | – | iPhone | – | – |
| Stream, captures arrived late | Yes | iPhone | – | iPhone | – | – |
| Stream, first restore from iCloud | Yes | iPhone | – | iPhone | – | – |
| Stream, notes could not be opened | Yes | iPhone | – | Yes | – | – |
| Stream, largest text size | Yes | Yes | – | Yes | – | – |
| Search, results and none | Yes | iPhone | – | Yes | – | – |
| Note, mixed segments | Yes | Yes | – | Yes | – | – |
| Note, title: none, generated, typed, editing | Yes | iPhone | – | iPhone | – | – |
| Note, a segment being edited | Yes | iPhone | – | Yes | – | – |
| Voice segment, each of its six states | Yes | iPhone | – | iPhone | – | – |
| Voice segment: playing, show original, recording removed | Yes | iPhone | – | iPhone | – | – |
| Ink segment: shown, being recognised, failed, nothing recognised | Yes | Yes | – | iPhone | – | – |
| Conflict copy | Yes | iPhone | – | iPhone | – | – |
| Segment from the command line; from a newer Knot | Yes | iPhone | – | iPhone | – | – |
| Attachment waiting, downloading, unavailable | Yes | iPhone | – | iPhone | – | – |
| Delete with undo; share | Yes | iPhone | – | Yes | – | – |
| A segment moved to its own note, with undo | Yes | iPhone | – | Yes | – | – |
| Open note deleted on another device, with restore | Yes | iPhone | – | iPhone | – | – |
| Storage nearly full | – | – | – | – | Yes | – |
| Launchers: idle, recording, waiting, failed | – | – | – | – | Yes | Yes |
| Menu bar icon: idle, recording; its menu | – | – | – | – | – | Yes |
| Settings, the full list | Yes | iPhone | – | Yes | – | – |
| Sync: off, syncing, error, storage full, no account | Yes | iPhone | – | iPhone | – | – |
| Prompts: account changed; notes removed from iCloud | Yes | iPhone | – | iPhone | – | – |
| Export: in progress, done, with what it could not fetch | Yes | iPhone | – | iPhone | – | – |
| Hotkey recorder; key already taken; command-line access | – | – | – | Yes | – | – |
| First run: microphone, model downloading, Action Button | Yes | iPhone | – | – | – | – |
| First run: choosing the hotkey, tap versus hold | – | – | Yes | – | – | – |
| Two columns do not fit; keyboard up | – | Yes | – | Yes | – | – |

The iPad cell “Two columns do not fit; keyboard up” is a stand-in until WP-40b.

## 7. Questions to answer

1. On iPhone, how do the capture field and the stream relate? Is it one screen or two, and which way does time run?
2. When the append window is open, how much of the note you are adding to does the capture surface show, and how do you start a new note instead? How does a capture that starts without a screen show which note it joined?
3. How do segments of different kinds read as one note, without looking like a chat or a form?
4. On the Mac, one key does two jobs: a tap opens the panel for typing, and holding it records. What distinguishes the two states of the panel, and how does the panel leave after a hold?
5. What does a recording look like outside the app, where the words must not show?
6. On the watch, what is the smallest screen that makes "it is recording" and "it is saved" certain at a glance and by feel?
7. On iPad, how do typing and Pencil share one capture surface without a mode switch, and what ends a drawing?
8. Where does a lasting problem show outside Settings: sync that has failed for hours, or notes that could not be opened?

## 8. Constraints

- **Accessibility.** Text scales with Dynamic Type to the largest accessibility sizes without cutting off content. Every control has a name for VoiceOver. Touch targets are at least 44 points. Text contrast is at least 4.5:1. Nothing is conveyed by colour alone. Reduce Motion and Reduce Transparency are respected. VoiceOver announces a recording's start and stop and stays silent while it runs. New text never moves focus, and focus returns where it was when a surface closes. On the Mac and the iPad every action, segment actions included, can be reached from the keyboard.
- **Light and dark** are both first-class.
- **Fonts and icons.** System fonts and SF Symbols are preferred. A custom font or icon set needs a reason, and an open licence that allows redistribution in a GPL-licensed app, such as the SIL Open Font License.
- **Language.** English only for now. Leave room for text to grow by a third in other languages.
- **Speed.** The capture surface draws its first frame with no loading state. Avoid anything that needs data or layout work before the cursor appears.
- **Privacy.** Nothing outside the unlocked app shows note text. That covers widgets, the Live Activity and complications.
- **Build target.** SwiftUI, with native controls and materials. Prefer what the system gives.
- **System first.** Where a mock and a system component differ, the system component wins. Type maps to Dynamic Type text styles, colour to roles, and materials to system materials. Controls, complications, widgets and the Live Activity take their glyphs, strings and content from the design and their rendering from the system.
- **Narrow widths.** The iPad in portrait on an iPad mini, in Split View and in a narrow window uses the iPhone's layout. A narrow Mac window gets its own layout rule, not a scaled one.

## 9. What to return

Start with two or three directions for the iPhone capture surface and the Mac panel, and let Paolo choose one before producing the full set. With each direction, answer questions 1, 2 and 4 of section 7, give a prototype we can link to, and say what the direction leaves open. Score each direction on three tasks, counted in actions: capture a new thought, continue the last note, find an old one. With the directions, return a structure sheet for the capture surface of each of the four devices: its regions, its navigation, and the component in each state. Code is built from those sheets before the full set arrives.

Then return the same kind of bundle as the previous round, an HTML and React prototype with CSS tokens and a README, extended to four devices:

- **Tokens,** as CSS variables and as JSON: colour roles for light and dark, the type ramp, spacing, radii, materials and elevation, motion durations and curves.
- **Components:** an inventory with every state, named the same way on every device.
- **Screens:** each surface in section 6, in each listed state, at the native size of iPhone 17 Pro, iPad mini, Apple Watch Ultra 2 and one smaller watch, plus the Mac panel and window.
- **Prototypes** of four interactions: iPhone capture with the append window; the Mac hotkey tapped and held; a watch recording; typing and Pencil on the iPad capture surface.
- **The matrix, filled in:** each cell of the state matrix in section 6 marked as designed or inherited. Show each capture surface also at the largest text size, with Reduce Motion, and with the keyboard up.
- **Assets:** glyphs as SVG, and the mark variants.
- **A README** that answers the questions in section 7, lists the tokens, and maps each screen to its components.

## 10. Not part of this round

- Photo and video capture.
- Folders, tags and other organisation.
- An onboarding walkthrough.
- The purchase flow for sync.
- App Store screenshots and a website.
