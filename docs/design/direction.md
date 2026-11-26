# Knot: the design direction

Recorded by the orchestrator on 2026-11-26, and corrected the same day with the owner's answer to question 1. `docs/architecture.md` §16 says what this file holds: the answers to the brief's questions 1, 2 and 4, a structure sheet for the capture surface of each of the four devices, a link to the chosen prototype, and what stays open. The second pull requests of WP-21, WP-30, WP-32 and WP-33, and all of WP-35, build from it.

## How the direction was chosen

Section 9 of the brief asks for two or three directions, each scored, and for a choice among them before the full set. The round did not run that way. The owner ran it in Claude Design, where both parts were published on 2026-11-25, and returned one design on 2026-11-26: a design system and nine screens. That design is the chosen direction, and it is in [`handoff/`](handoff/README.md). No directions were scored against each other and no structure sheets came back. The sheets below are drawn from the handoff by the orchestrator, and they are the owner's to correct.

The design in one sentence, from its brand book: Knot is four native apps that use the controls, the colours, the type and the glass that each system already has, and Knot owns five things, which are the mark, ink as its tint, the red record control, the page, and its voice.

## Which source rules

The handoff has two parts, and they differ in places. This order settles a difference. It is the orchestrator's ruling of 2026-11-26, and the owner's to overturn.

1. `docs/product-spec.md` rules behaviour, and its words rule the names of things. The design does not change what Knot does (brief §5).
2. A system component rules over a mock's pixels (`docs/architecture.md` §16). Type maps to Dynamic Type text styles, colour to roles, and materials to system materials.
3. The screens, `handoff/screens/`, rule for what they draw. They are the later part, and they were drawn from the app as it is built.
4. The design system, `handoff/system/`, rules for everything else: what no screen draws, every state, the voice, the glyphs and the tokens.

The owner has made one exception. On 2026-11-26, with both structures drawn side by side, he chose the design system's structure for the iPhone. So for the iPhone's navigation and the placing of its controls, the design system rules over the screens.

A control that the design system names and a screen leaves out is not removed by the screen's silence: it stays, where the spec needs it. [`handoff-differences.md`](handoff-differences.md) lists the differences one by one, with what holds for each. [`deltas.md`](deltas.md) lists where the handoff differs from what is built, and who has each difference. [`handoff-check.md`](handoff-check.md) lists the cells of the state matrix that the handoff leaves without a design.

## The answers

### Question 1. On iPhone, how do the capture field and the stream relate?

They are two layers. Notes, the stream, is the root: a navigation stack with the large title "Notes" and a plain list. The capture surface is a sheet over it, at the large detent. The sheet is up when Knot launches, with the field focused and the keyboard up, and every way in that opens Knot to capture presents it. A return from the background is the exception: it shows what was left, as "Navigation" below says. The list button in the sheet's top leading corner, or a swipe down, dismisses the sheet and shows Notes. On Notes, the button beside search brings the capture surface back, as it is at launch. A row of Notes pushes its note. In the stream, time runs from the newest note down. In a note it runs from the oldest segment down, and the capture field is the last element.

This is the design system's structure (`handoff/system/01-platforms.md`, and the previews of `CaptureSurface`, `StreamRow` and `FirstRun`). The screens draw the other one, which the skeleton of WP-30's first pull request has: the capture surface as the root, with Notes pushed from the list button and a back button on Notes. The orchestrator first recorded the screens' structure, by the order above. On 2026-11-26 the owner saw both side by side and chose the design system's. WP-30's second pull request rebuilds the iPhone's navigation to it.

Two things follow from the spec and the brief, and no drawing shows them. At launch the sheet is up in the first frame, with no animation, since the brief asks for a first frame with no loading state (`brief.md` §8). And a way in that opens Knot to search shows Notes with search focused and no sheet (`docs/product-spec.md` §6).

### Question 2. With the append window open, how does the note you are adding to appear, how do you start a new note, and how does a capture without a screen show which note it joined?

The note being added to sits above the field in secondary ink, under one footnote line that names it by its time: "Adding to the note from 9:38". The field is below it and has the focus. "New note" is one tap away, at the leading edge above the keyboard, and ⌘N does the same with a hardware keyboard. When the window runs out while the field is still empty, the earlier note leaves the surface, as `docs/product-spec.md` §4.1 says. The handoff draws no moment for that, so it happens with the theme's list change and no other sign.

A capture that starts without a screen has no answer in the handoff. The Live Activity, the Watch and the Mac panel during a hold carry no sign of whether the recording continues a note or starts a new one. That stays open, below.

### Question 4. On the Mac, what tells the panel's two states apart, and how does the panel leave after a hold?

After a tap the panel is a page to type on: the field has the focus and is set in Title 2, a line of hints names the keys (⌘↩ Done, ⌘N New note, esc Close), and the record control sits idle at the trailing edge. During a hold the panel is a recording: the record control is filled red with the stop square, the timer stands beside it, the words arrive in the field, in secondary ink until they are final, and the line of hints reads "Release the hotkey to stop".

The handoff does not draw how the panel leaves after a hold. The spec's rule stands: after release the panel stays while the text arrives and hides by itself shortly after, unless the person clicks or types in it (`docs/product-spec.md` §6).

## The structure sheets

Each sheet gives the capture surface's regions, its navigation, and the component in each state. A state that the handoff does not design is marked "not designed": the builder uses the system default and adds a line to `deltas.md`.

### iPhone

Regions of the capture surface, a sheet at the large detent over Notes:

| Region | Holds |
|---|---|
| Top bar | Leading: the list button (`list.bullet`), which shows Notes. Trailing: Done, the system's confirming button, with the checkmark on prominent glass, tinted ink. |
| Page | Paper to the edges, with the system's layout margin. From the top: the footnote line and the note being added to, in secondary ink, when the append window is open; then the capture field, in Body, with the placeholder "Type a thought". |
| Above the keyboard | Leading: New note (`square.and.pencil`), when there is a note to leave. Trailing: the record control, 44 points. With the keyboard down, the two sit in the bottom toolbar. |

Navigation: Notes is the root, and the capture surface is a sheet over it. At launch the sheet is up in the first frame, with no animation. The list button and a swipe down dismiss it, and dismissing it ends a typed capture. Done and ⌘↩ end a typed capture and leave the surface up, as it is built. There is no save button. A return from the background shows what was left, as it is built: the sheet if it was up, else Notes or the note. iOS cannot tell a tap on the icon from a return through the app switcher. The owner's answer on it, of 2026-11-26, was "for now, where we left it".

Notes itself has the `ellipsis` menu in its top trailing corner, with Settings and Recently deleted, and a bottom toolbar with search and, beside it, the button that brings the capture surface back (`square.and.pencil`). Settings opens from the menu as a sheet with a close button. An open note is a pushed page with the back button and the note's own `ellipsis` menu: Copy note, Share note… and Delete note.

With the capture surface dismissed while a recording is live, Notes shows it: a notice at the top with the word "Recording", the elapsed time and one action, Show, which brings the sheet back. Nothing shows before the microphone is live. The owner asked for it on 2026-11-26. The form is the orchestrator's ruling, and his to overturn. The handoff draws nothing for it, and it is on the list for the designer in `handoff-check.md`.

The component in each state:

| State | Top bar | Page | Above the keyboard, or the bottom toolbar |
|---|---|---|---|
| Empty | The list button; Done | The field, empty, focused | The record control, idle: `mic` in ink on glass |
| Typing | The list button; Done | The field with its text | New note when the window is open; the record control, idle |
| Adding to an open note | The list button; Done | The footnote line, the note in secondary ink, the field | New note; the record control, idle |
| Recording, before the microphone is live | The list button; Done | The field does not accept typing | New note, where the model offers it; the record control with `mic.fill` in ink on glass, and no timer: until the microphone is live, nothing implies a recording (`docs/product-spec.md` §4.5). Both parts of the handoff give this phase red: see `handoff-differences.md`, I-09 |
| Recording, live | The list button; Done | The live segment in the field's place: its waveform, the words in secondary ink until they are final, and the line "Recording. Typing waits until you stop." | New note, where the model offers it; the timer in ink with monospaced digits, leading the record control, which is filled red with `stop.fill` |
| Just stopped | The list button; Done | The voice segment: its player, its duration, and the line "Saved, text on its way" until the text is there; the field below it | "Saved" beside the record control, which shows `checkmark` for one second and then is idle |
| Short recording discarded | The list button; Done | The field, as before the recording | The sentence "Too short. Nothing was kept." Where it sits is not designed |
| Stopped at the limit or by a call | As just stopped | A notice above the note: "Recording stopped at 30 minutes and was saved." A stop by a call has no sentence of its own | As just stopped |
| Could not start | The list button; Done | A notice: "Knot can’t use the microphone. You can allow it in Settings.", with Open Settings. Other reasons are not designed | The record control with `mic.slash` in secondary ink |
| Text could not be saved | | Not designed. The spec's rule stands: the surface stays open with the text in it and says that it could not save | |

The design system draws Done at all times. Whether it is disabled while no typed capture is open is not designed. The drawings to build from are `handoff/system/components/CaptureSurface/` and the iPhone part of `handoff/system/01-platforms.md`. The screens `Main.dc.html` and `iPhone-Recording.dc.html` still hold for what they say and for the states they show, and not for where the controls sit or how large they are.

### iPad

The handoff has no picture of the iPad. Its rules are in `01-platforms.md`.

- Regions: a `NavigationSplitView` with two columns. The stream is in the sidebar column, with search. The detail column is the capture surface: at launch it shows the note the append window is open on, or a new empty note, with the field focused. Done and New note are in the detail column's toolbar, and the record control is in its bottom bar.
- Navigation: a row of the sidebar opens its note in the detail column. Where two columns do not fit, the iPad has the iPhone's structure.
- States: as the iPhone's, in the detail column. Touching the Pencil to the page opens a blank ink canvas below the last segment, which grows as the person writes and ends only with Done. A Sketch control (`pencil.tip`) in the toolbar opens the same canvas for a finger. With a pointer, a segment under it takes a quiet fill and shows an `ellipsis` for its menu.
- Not designed: ink in progress as a picture, the tool affordance, and every iPad cell of the matrix that needs a picture of its own.

### Mac

The capture surface is the floating panel. The main window is the stream and the open note, and it is not a capture surface of its own: capturing in it is capturing inside the open note.

| Region of the panel | Holds |
|---|---|
| Caption | "Adding to the note from 9:38", in Subheadline and secondary ink, when the append window is open |
| Field | The text, in Title 2. It grows with the text, to half the screen's height |
| Foot | Leading: the key hints, in Subheadline. Trailing: the record control, 28 points, with the timer beside it while a recording runs |

The panel is a non-activating panel on glass, 640 points wide, with the largest of the radii, centred in the upper third of the active screen. It has no title bar, no traffic lights, no toolbar and no list of notes.

Navigation: a tap of the hotkey shows the panel with the field focused, and a second tap or Esc hides it. A hold shows it recording, and release stops the recording. ⌘↩, Esc and a click elsewhere end a typed capture. ⌘N starts a new note.

| State | Field | Foot |
|---|---|---|
| Empty | Empty, focused. Its placeholder is not designed | The key hints; the record control, idle |
| Typing | The text | The key hints; the record control, idle |
| Adding to an open note | The caption above; the text. The handoff shows the caption only, not the note's earlier segments | The key hints; the record control, idle |
| The key held, before the microphone is live | Not designed | The record control with `mic.fill` in ink on glass, by the same rule as the iPhone's. The line of hints is not designed |
| Recording while the key is held | The words, secondary until final | "Release the hotkey to stop"; the timer; the record control filled red with `stop.fill`. No level is drawn |
| Recording started by the control, Siri or Shortcuts | Not designed. The spec's rule stands: the panel shows with a stop control, and Esc also stops it | |
| Just released | Not designed. The spec's rule stands: the panel stays while the text arrives and hides by itself shortly after | |
| The limit reached, no permission, no microphone connected, text that could not be saved | Not designed for the panel. The words are those of `02-states.md` where it has them | |

### Apple Watch

One screen: the record control, 88 points, centred, and one line of outcome under it. There is no list, no text entry, no settings and no navigation.

| State | Above the control | The control | Under the control |
|---|---|---|---|
| Idle | | `mic` on glass | Nothing |
| Starting | | `mic.fill` in ink on glass, by the same rule as the iPhone's | Nothing |
| Live | The timer | Filled red, `stop.fill` | "Recording" |
| Saved | | `checkmark` on glass | "Saved" |
| Too short | | `mic` on glass | "Too short. Nothing was kept." |
| Could not start | | `mic.slash` | "Couldn’t start." and, in the footnote style and secondary ink, "Allow the microphone in Settings." |
| Stopped at the limit | | `checkmark` on glass | "Saved" and, in the footnote style and secondary ink, "Stopped at 30 minutes." |

The screen returns to idle three seconds after an outcome, by `01-platforms.md`; another page gives the saved control one second (`handoff-differences.md`, S-17). Every outcome has its haptic, by the table in the brand book. The two parts place the live timer differently, above the control on the screen and under it in the design system: see `handoff-differences.md`, I-44.

Not designed: the display dimmed during a recording, storage nearly full, whether a recording continues a note or starts a new one, and a start that needs the app in front against one that does not.

## Who builds from it

- WP-21's second pull request builds the capture surface's structure in `KnotUI`: its regions, and each component in each state of the sheets above, with a named preview for every cell of the brief's matrix that is marked "Yes". It matches no pixels. It builds neither the sheet nor the list button, which are the app's.
- The second pull requests of WP-30, WP-32 and WP-33 each build their app from their device's sheet. Each starts after WP-21's has merged and when the plan's other conditions for it are met. WP-30's rebuilds the iPhone's navigation to the answer to question 1.
- WP-40's first pull request translates `handoff/system/tokens.json` into the theme and writes `DESIGN.md`. `PLAN.md` §6 holds WP-40 until the keep-gate ruling. On 2026-11-26 the owner asked for the design to be implemented, and the orchestrator started that one pull request on his word. He confirmed the same day that it may merge ahead of the keep gate, and it merged on his yes as pull request 126. Later that day he let WP-40a, the iPhone's screens, start after WP-30a too. WP-40b, WP-40c and WP-40d keep the hold.
- The shared components of `KnotUI` are matched to the handoff by WP-40's sub-packages: the iPhone's first, which is the first to start, and each later one for what its platform alone has. Until then they keep their structure and take the theme's values. It is the orchestrator's ruling. With WP-40a's paths, which docs/plan/WP-40.md names, it settles the open point "Paths in wave 4" of `docs/plan/open-points.md` for the iPhone, and the rest of that point stays open.

## The prototype

The handoff is the prototype: [`handoff/`](handoff/README.md), with the design system in `handoff/system/` and the screens in `handoff/screens/`. No interactive prototype came back. The links to the two artifacts are not in this repository, which is public. The orchestrator's journal has them.

## What stays open

For the owner:

1. The name of the button on Notes that brings the capture surface back. The design system calls it New note. In the spec, New note is the control that forces a new note inside the append window, and this button does not: it presents the capture surface as it is at launch, which follows the window. It needs a name of its own for VoiceOver and for the menus.
2. The order under "Which source rules".
3. The five decisions prepared for the design sitting, G2-01 to G2-05, and the review of the brief in pull request 114. `handoff-check.md` says what the handoff implies for each.
4. Whether the secondary ink is the system's own. The brand book asks for the system's secondary label colour and says itself that it is below 4.5:1 on light paper. The brief asks for 4.5:1, and the accessibility audit that runs in every UI smoke test fails small text below it. Until he rules, the theme keeps a secondary ink that passes the audit.

For the designer, as one list and not as a second round: the cells of the state matrix that the handoff leaves without a design. `handoff-check.md` has them. Among them are the whole of the iPad, most states of the Mac panel, most states outside the app, and how a capture without a screen shows which note it joined.

Until the designer returns them, a builder who meets such a cell uses the system default and adds a line to `deltas.md`, as `docs/architecture.md` §16 says, and the owner clears those lines at M6.
