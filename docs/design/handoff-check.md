# The handoff's check against the state matrix

`docs/architecture.md` §16 has the orchestrator check the design handoff against the state matrix that ends `docs/design/brief.md` §6, before WP-40 starts: every cell is designed or inherits from a named cell, and each capture surface is shown at the largest text size, with Reduce Motion and with the keyboard up. Gaps go back to the designer as a list, not as a second round. This file is that check, made on 2026-11-26 on the handoff in [`handoff/`](handoff/README.md).

How it was made: two readers went through the matrix cell by cell against every file of the handoff, and a second reader checked each of their lists against the files, corrected it and added what was missed. It is a reading of files. It judges whether a state has a design, not whether the design is good.

## The result

The check has not passed. The matrix on `main` marks 87 cells "Yes". Of those:

| What the handoff has for the cell | Cells |
|---|---|
| A picture: a screen | 10 |
| A picture: a component's preview | 7 |
| A rule in the design system's text, and no picture | 9 |
| A design in part: something the brief asks for in that state is missing | 42 |
| No design | 19 |

A further 49 cells inherit another device's design: 15 inherit a cell that is designed, and 34 inherit a cell that is a gap or designed in part.

So the handoff is not yet the accepted handoff of WP-40's start conditions. The list for the designer is below. Until the designer returns those cells, a builder who meets one uses the system default and adds a line to [`deltas.md`](deltas.md), as `docs/architecture.md` §16 says for a silent handoff.

## The matrix, filled in

A dash is a cell that does not apply. The words are those of the table above: "Drawn" is a screen, "Stated" is a rule with no picture.

| State | iPhone | iPad | Mac panel | Mac window | Watch | Outside the app |
|---|---|---|---|---|---|---|
| Capture, empty | In part | Stated | Stated | – | – | – |
| Capture, typing | Drawn | iPhone | Component | – | – | – |
| Capture, adding to an open note; the window running out | In part | In part | In part | – | – | – |
| Capture inside an older note | Drawn | iPhone | – | Drawn | – | – |
| Recording, live | Drawn | iPhone | In part | Mac panel: inherits a gap | In part | In part |
| Recording, before the microphone is live | – | – | In part | – | – | – |
| Recording, typing and Pencil not accepted | In part | In part | – | – | – | – |
| Recording, continues a note or starts a new one | – | – | In part | – | **Not designed** | **Not designed** |
| Recording, display dimmed | – | – | – | – | **Not designed** | – |
| Just stopped: saved, with text arriving except on the Watch | In part | iPhone: inherits a gap | In part | Mac panel: inherits a gap | Drawn | **Not designed** |
| Short recording discarded | Stated | iPhone | – | – | Drawn | **Not designed** |
| Stopped at the limit, or by a call | In part | iPhone: inherits a gap | In part | Mac panel: inherits a gap | In part | **Not designed** |
| Could not start, with the reason | In part | iPhone: inherits a gap | In part | Mac panel: inherits a gap | Component | **Not designed** |
| No microphone connected | – | – | **Not designed** | Mac panel: inherits a gap | – | – |
| Text could not be saved | **Not designed** | iPhone: inherits a gap | **Not designed** | Mac panel: inherits a gap | – | – |
| Ink in progress; ending a drawing | – | In part | – | – | – | – |
| Stream, populated | Drawn | Stated | – | Drawn | – | – |
| Stream, first run | In part | iPhone: inherits a gap | – | In part | – | – |
| Stream, row with no text yet | In part | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Stream, rows pending and failed | Drawn | iPhone | – | iPhone | – | – |
| Stream, captures arrived late | Drawn | iPhone | – | iPhone | – | – |
| Stream, first restore from iCloud | **Not designed** | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Stream, notes could not be opened | Component | iPhone | – | Stated | – | – |
| Stream, largest text size | In part | In part | – | In part | – | – |
| Search, results and none | **Not designed** | iPhone: inherits a gap | – | **Not designed** | – | – |
| Note, mixed segments | Component | Stated | – | In part | – | – |
| Note, title: none, generated, typed, editing | In part | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Note, a segment being edited | Stated | iPhone | – | Stated | – | – |
| Voice segment, each of its six states | Component | iPhone | – | iPhone | – | – |
| Voice segment: playing, show original, recording removed | In part | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Ink segment: shown, being recognised, failed, nothing recognised | In part | In part | – | iPhone: inherits a gap | – | – |
| Conflict copy | In part | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Segment from the command line; from a newer Knot | Component | iPhone | – | iPhone | – | – |
| Attachment waiting, downloading, unavailable | In part | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Delete with undo; share | Component | iPhone | – | Stated | – | – |
| A segment moved to its own note, with undo | In part | iPhone: inherits a gap | – | In part | – | – |
| Storage nearly full | – | – | – | – | **Not designed** | – |
| Launchers: idle, recording, waiting, failed | – | – | – | – | In part | In part |
| Menu bar icon: idle, recording; its menu | – | – | – | – | – | In part |
| Settings, the full list | In part | iPhone: inherits a gap | – | In part | – | – |
| Sync: off, syncing, error, storage full, no account | **Not designed** | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Prompts: account changed; notes removed from iCloud | **Not designed** | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Export: in progress, done, with what it could not fetch | **Not designed** | iPhone: inherits a gap | – | iPhone: inherits a gap | – | – |
| Hotkey recorder; key already taken; command-line access | – | – | – | In part | – | – |
| First run: microphone, model downloading, Action Button | In part | iPhone: inherits a gap | – | – | – | – |
| First run: choosing the hotkey, tap versus hold | – | – | **Not designed** | – | – | – |
| Two columns do not fit; keyboard up | – | In part | – | **Not designed** | – | – |

## The list for the designer

Every cell marked "Yes" on `main` that has no design or a design in part, with what is missing. A cell that inherits a gap is not listed again: it is met when the cell it inherits from is.

### iPhone

| State | The handoff has | Missing |
|---|---|---|
| Capture, empty | screens: Main.dc.html, view "Blank" (empty textarea with placeholder "Type a thought", the Notes button, the idle 64 pt record control in the bottom bar; Done and New note sit inside `sc-if value="{{adding}}"`, so Blank has neither). system: 01-platforms.md, iPhone: "The field has focus as the sheet appears. Above the keyboard, a `ToolbarItemGroup(placement: .keyboard)` carries New note (`square.and.pencil`) leading and the record control trailing". components/CaptureSurface/preview.html draws the keyboard-up arrangement, but with text in the field. | No picture of the empty field with the keyboard up, which brief section 6 asks for ("empty, keyboard up"). The Blank view draws no keyboard and puts the record control in the bottom bar, which 01-platforms.md calls the keyboard-down layout ("with the keyboard down they sit in the bottom toolbar"). It also drops the Done button and New note that 01-platforms.md places on the capture surface. |
| Capture, adding to an open note; the window running out | screens: Main.dc.html, view Adding ("Adding to the note from 9:38" above the earlier text in secondary ink). system: components/CaptureSurface/preview.html and README.md ("While the append window is open, show the note being added to above the field in `label-secondary`, under a footnote line"). | The moment the window runs out and the note leaves the surface. The draft also asks that the note leaves only while the field is empty and stays after the first keystroke. |
| Recording, typing and Pencil not accepted | screens: iPhone-Recording.dc.html, Live (textarea `disabled="{{live}}"`). system: components/CaptureSurface/preview.html ("Recording. Typing waits until you stop."). 02-states.md: "While live, typing waits: the field steps aside for the live segment". | Pencil. Main's iPhone list already asks for "the text field and Pencil not accepting input while it runs", and the draft keeps it; nothing in the handoff addresses Pencil during a recording on iPhone (a search of both folders for "Pencil" finds only the iPad rule in 01-platforms.md and the `square.and.pencil` and `pencil.tip` symbols). The typing half is designed. |
| Just stopped: saved, with text arriving except on the Watch | screens: iPhone-Recording.dc.html, phase Saved (player "0:12" with "Saved, text on its way", and "Saved" beside a 64 pt glass control drawing a checkmark, labelled "Record"). | The transcript arriving and the cleaned text replacing it (brief: "just stopped, as the transcript arrives and the cleaned text replaces it"). |
| Stopped at the limit, or by a call | system: components/Notice/preview.html, "Stopped at the limit" ("Recording stopped at 30 minutes and was saved."). 02-states.md: "A call, or the 30-minute limit, stops a recording and saves it: \"Recording stopped at 30 minutes and was saved.\"" | A stop by a call has no sentence of its own: the rule gives it the 30-minute sentence, so it does not say why. The draft's disk-full stop is absent. No iPhone artboard. |
| Could not start, with the reason | system: 02-states.md ("Couldn't start \| `mic.slash` in `label-secondary`; a notice says why"; notice "Knot can't use the microphone. You can allow it in Settings." with Open Settings and close). components/Notice/preview.html, "A surface problem". components/RecordControl/preview.html, "Couldn’t start". screens: States.dc.html, the same notice. | Only the refused-permission reason is designed. "No space" and "the microphone in use" have no sentence or picture. No iPhone capture artboard shows it. |
| Text could not be saved | Nothing | Text that could not be saved, with the surface staying open. |
| Stream, first run | system: components/FirstRun/preview.html and README.md ("No notes yet.", "iCloud sync is on.", setup rows "Record with the Action Button", "Add a Lock Screen control", "Add the Watch complication", each with `xmark`). 02-states.md, First run. | The draft asks for the line about sync both "for sync on and for sync you switched off" and asks the designer to propose the second; only "iCloud sync is on." exists (a search of both folders for "switched off" finds nothing). Against main alone, this would be designed_component. |
| Stream, row with no text yet | screens: iPhone-Stream.dc.html, row "Recording, 0:42" (no preview, voice glyph). system: components/StreamRow/preview.html and README.md: "A recording-only note is titled \"Recording, 0:42\" until its text arrives." | The "Sketch" row for a drawing with no text yet. No row or rule covers an ink-only note: in the screens "Sketch" is only the aria-label of the ink kind glyph (iPhone-Stream.dc.html, Mac-Window.dc.html), and in the system it names the iPad Sketch control (01-platforms.md; README.md "Sketch (iPad) \| `pencil.tip`"), never a row title. |
| Stream, first restore from iCloud | Nothing | The stream during the first restore from iCloud, while it is still filling. |
| Stream, largest text size | system: components/StreamRow/preview.html, "Accessibility sizes (AX3). The preview goes first, the title wraps, the meta line wraps beneath it, and the trailing mark joins the meta line." StreamRow/README.md, the same. README.md Typography: "Dynamic Type works up to AX5". | The one row drawn is at AX3, not at the largest size (AX5), and it is not on an artboard. The draft asks that "the preview gives way first, then the kinds"; the handoff never says the kinds give way (the AX3 row keeps all its kind glyphs). |
| Search, results and none | Nothing | Both states: the stream filtered to results (the spec: "It filters the stream as you type") and the state with no results. Neither is drawn or described: a search for 'result' finds nothing in either folder. iPhone-Stream.dc.html also has no New note button beside search, which goes against 01-platforms.md and the two system previews. |
| Note, title: none, generated, typed, editing | Only "none": handoff/screens/iPhone-Note.dc.html opens straight on the segments, with no title and no date line; handoff/system/components/Segment/preview.html has only a date line, "Today, 9:38". handoff/system/01-platforms.md gives the note no title element: "A pushed page: date line, segments, the capture field last." | Generated, typed and being-edited titles. The handoff treats a title as the first line: StreamRow/README.md says "the note's first line (title)", and tokens.json for ios-headline says "A stream row's title (the note's first line)." The spec instead says a note has an optional title that "is edited in place and can be cleared", and that cleanup generates one for a note that starts with a recording. |
| Voice segment: playing, show original, recording removed | Playing is designed: handoff/screens/iPhone-Note.dc.html has a Pause button, 13 of 40 waveform bars in ink (played = 13), and "0:14 / 0:42". "Show original" and "Remove recording" appear only as menu items, in SegmentMenu/preview.html and States.dc.html. What Show original does is stated only in the Settings preview footer: "Tidying removes filler words; 'Show original' brings them back." | The segment after "Show original" (the original text shown) and the segment after "Remove recording" (text with no player). 02-states.md's "Recording missing" (`waveform.slash`, "the text stays") is a different state, although README.md gives the two one glyph: "Recording missing / Remove recording \| `waveform.slash`". |
| Ink segment: shown, being recognised, failed, nothing recognised | Only "shown": handoff/system/components/Segment/preview.html draws the drawing (svg class k-ink) with no text. Segment/README.md: "Ink is the drawing itself, in `label`, on the paper." | Being recognised, recognised text, recognition failed (the draft adds "with Retry"), and nothing recognised or unreadable with a placeholder. The only match for 'recogni' in either folder is VoiceStates/preview.html, "Nothing to recognise.", which is about a voice segment's "Kept, no text"; nothing concerns handwriting recognition. |
| Conflict copy | An edit-conflict notice and a glyph. handoff/system/components/Notice/preview.html: "This text changed on another device while you edited it." with "Keep mine" / "Keep the other". handoff/screens/States.dc.html: "This text changed elsewhere while you edited it." with "Keep mine" / "Keep the new text". Notice/README.md: "A notice that needs a decision (an edit conflict) stays until decided." README.md iconography: "Edit conflict \| `arrow.triangle.2.circlepath`". | The conflict copy itself. The spec keeps both versions, one placed beside the other and marked as a conflict, and the user deletes the one they do not want. The handoff instead asks the user to choose, which goes against that model. The two artifacts also word the notice and its second button differently. |
| Attachment waiting, downloading, unavailable | Unavailable, for a recording only: Segment/preview.html ("Text kept from before the restore." with "Recording missing") and 02-states.md ("`waveform.slash` + \"Recording missing\"; the text stays"). Waiting, for a Watch recording only: VoiceStates/preview.html "Saved on the Watch", captioned "Safe on the Watch, waiting for the iPhone. Nothing to do." | Downloading; waiting for a recording made on another iPhone, iPad or Mac (the spec: it "downloads when you open its note"); and every one of these states for a drawing made on another device. A search for 'download' finds nothing in either folder. |
| A segment moved to its own note, with undo | Only the menu item "Move to its own note", in SegmentMenu/preview.html and States.dc.html. README.md gives its glyph, `rectangle.portrait.and.arrow.right`. | The moment after the move, with undo; the capsule is only for a delete ("Segment deleted"). The draft's "with the note it left still open". The draft's "where it is offered" is not covered either: SegmentMenu/README.md only says to "omit the rest rather than disabling them", and never states the spec's conditions (not on the only capture of a note, not on one in progress). |
| Settings, the full list | handoff/screens/iPhone-Settings.dc.html: Append window (2 minutes), Clean up transcripts, English variant (Follow the region), iCloud sync, the footer "Live Activities are off, so recording from the Lock Screen opens Knot first.", Export all notes…, Recently deleted, About. Settings/preview.html shows the same kinds of row under other names, with a different footer ("Captures within this time join the same note. Tidying removes filler words; 'Show original' brings them back.") and no Live Activities row. | Sync status beside iCloud sync, the row that explains why cleanup is unavailable, About's contents and the test-build exports, and (draft) the Action Button row. The two artifacts name the rows differently: the system has "Add to a note for", "Tidy up transcripts", "English", "About Knot"; the screen has "Append window", "Clean up transcripts", "English variant", "About". The Live Activities row exists only in the screen. |
| Sync: off, syncing, error, storage full, no account | Nothing | All five statuses. |
| Prompts: account changed; notes removed from iCloud | Nothing | Both prompts. |
| Export: in progress, done, with what it could not fetch | Nothing | In progress, done, and the list of what could not be fetched. |
| First run: microphone, model downloading, Action Button | Microphone, by rule: 02-states.md "the microphone permission is asked the first time someone records"; the refusal notice is in Notice/preview.html ("Knot can’t use the microphone. You can allow it in Settings."). Action Button: the setup row "Record with the Action Button" in FirstRun/preview.html (FirstRun/README.md: "tapping explains the system steps in a sheet"). | The speech model still downloading: nothing in either folder (no match for 'model' or 'download'). The sheet that explains the Action Button. The Action Button row in Settings, which the draft requires. |

One more iPhone state goes to the designer. It is not a cell of the matrix and is not counted above: Notes while a recording is live and the capture surface is dismissed. The handoff has nothing for it. The owner asked on 2026-11-26 that Notes show the recording. Until the designer returns it, the built form is the orchestrator's ruling in `direction.md`: a notice with the word "Recording", the elapsed time and Show, which brings the sheet back.

### iPad

| State | The handoff has | Missing |
|---|---|---|
| Capture, adding to an open note; the window running out | system: 01-platforms.md, iPad: "on launch it shows the note the append window is open on". README.md, Layout: "When the append window is open, the note being added to sits above the field in `label-secondary`, with a footnote line (\"Adding to the note from 9:38\")". | No iPad picture. The window running out and the note leaving are not designed. |
| Recording, typing and Pencil not accepted | system: 02-states.md, a general rule: "While live, typing waits: the field steps aside for the live segment, whose words appear... (\"Recording. Typing waits until you stop.\")". | No iPad picture. Nothing says Pencil is not accepted while recording. 01-platforms.md says "Touching the Pencil to the page opens a blank ink canvas" and makes no exception for a recording. |
| Ink in progress; ending a drawing | system: 01-platforms.md, iPad: "Touching the Pencil to the page opens a blank ink canvas below the last segment (`PKCanvasView`, the system tool picker hidden; ink only, in `label`). The canvas grows as you write and ends only with Done, never with a stray touch. A Sketch control (`pencil.tip`) in the toolbar opens the same canvas with a finger." 03-elements.md: "Ink \| `PKCanvasView`..., tool picker hidden". | No picture of ink in progress or of ending a drawing. The tool affordance with Pencil Pro squeeze is not designed: the tool picker is hidden and squeeze is never mentioned. The draft's drawing stopped because the disk filled is absent. |
| Stream, largest text size | system: README.md Typography, shared by iOS and iPadOS: "Dynamic Type works up to AX5"; "At accessibility sizes, let a stream row's preview go first, then stack the meta line under the title; never truncate a title to one line." | No iPad picture of the sidebar stream at the largest size. The rule does not cover the draft's order ("the preview gives way first, then the kinds"). |
| Ink segment: shown, being recognised, failed, nothing recognised | Rules only: Segment/README.md ("Ink is the drawing itself") and 01-platforms.md Pencil ("Touching the Pencil to the page opens a blank ink canvas below the last segment"). | No iPad picture. The recognition states, the recognised text and copying it as text (brief §6 iPad) are missing. |
| Two columns do not fit; keyboard up | Rule: 01-platforms.md "In compact width (Slide Over, narrow windows) it collapses to the iPhone structure on its own." This matches the draft ("the iPad uses the iPhone's layout"), not main §8 ("each get their own layout rule"). | No iPad picture at all. The rule does not name portrait on an iPad mini or Split View; a full-screen iPad in portrait is not compact width, so the rule as written would not collapse there. The keyboard-up and largest-text versions are missing. |

### Mac panel

| State | The handoff has | Missing |
|---|---|---|
| Capture, adding to an open note; the window running out | system: components/MacCapture/preview.html, first panel: "Adding to the note from 9:38" above the field. | The window running out and the note leaving the panel. The preview also shows no earlier segments of the open note, only the caption. |
| Recording, live | system: components/MacCapture/preview.html, second panel (words with the provisional part in secondary, "Release the hotkey to stop", timer "0:08", live record control). | No level: brief asks "recording while the key is held, with the words and a level". No panel for a recording started from the microphone control, Siri or Shortcuts, with a stop control because no key is held. |
| Recording, before the microphone is live | system: 02-states.md: "Starting \| `mic.fill` in `record` on glass \| The microphone is opening; under half a second". components/RecordControl/README.md: "28 pt in the Mac panel". | No picture of the panel with the key held. The rule fixes only the control's glyph. Nothing says what the field, the key-hint line ("Release the hotkey to stop") and the timer show before the microphone is live. |
| Recording, continues a note or starts a new one | system: components/MacCapture/README.md: "Provide: the field's text, the append-window note (if open), and the record control's phase." and "the append caption and key hints in `mac-subheadline`". components/MacCapture/preview.html shows the caption "Adding to the note from 9:38" on the typing panel only. | No text or picture says what the panel shows while recording into an open note versus a new one. The rule names the append caption only as an input and a type style, and the recording panel in the MacCapture preview has no caption. |
| Just stopped: saved, with text arriving except on the Watch | system: README.md, haptics table, Mac column: "Saved \| ... \| the checkmark, one second". components/RecordControl/README.md: "Saved shows `checkmark` for one second." | No picture. How the panel leaves by itself after the key is released: MacCapture/README.md lists only "Esc, ⌘↩ or clicking elsewhere ends the capture". The text arriving in the panel. |
| Stopped at the limit, or by a call | system: README.md haptics, Mac column: "Stopped at the limit \| ... \| the notice". 02-states.md notice: "Recording stopped at 30 minutes and was saved." | No picture of the panel. The disk-full stop the draft adds ("the limit reached, or the disk full") is absent. Against main's Mac list ("the limit reached") alone, this would be designed_rule. |
| Could not start, with the reason | system: README.md haptics, Mac column: "Couldn't start \| ... \| the notice". The notice in 02-states.md ("Knot can't use the microphone..."). Typography: a notice's sentence on macOS is `mac-callout`. | No picture of the panel. Notices are placed "at the top of the note or stream they concern", which does not fit the panel. Reasons other than permission are absent. |
| No microphone connected | Nothing | The panel when no microphone is connected (as on a Mac Studio). |
| Text could not be saved | Nothing | Text that could not be saved, with the panel staying open. |
| First run: choosing the hotkey, tap versus hold | Nothing | The whole first-run moment, in both branches (with and without a system permission prompt). The handoff goes against it: 01-platforms.md says "The person chooses the key in Settings", while the spec says "On the Mac, the first launch asks you to choose a hotkey and shows tap versus hold once." |

### Mac window

| State | The handoff has | Missing |
|---|---|---|
| Stream, first run | system: 02-states.md, First run, stated for all devices: "The empty stream reads \"No notes yet.\" with \"iCloud sync is on.\" under it, and can carry up to three setup rows". | No Mac picture. The only setup rows named are iPhone and Watch ones (Action Button, Lock Screen control, Watch complication). FirstRun/README.md gives only iOS styles (`ios-body`, `ios-footnote`). The Mac window's empty state is not designed. |
| Stream, largest text size | system: README.md, Typography: the general rule "At accessibility sizes, let a stream row's preview go first...". components/MacWindow/README.md gives the sidebar rows `mac-headline`, `mac-subheadline` and `mac-footnote`. | No Mac picture. Nothing says what the Mac sidebar does at the largest text size: the accessibility-size rule is written in terms of Dynamic Type (AX5), and the Mac column says nothing about it. |
| Search, results and none | Nothing | The results state and the no-results state. The two artifacts also disagree on where the field goes: the screen puts it in the main area's top bar, while 03-elements.md ("sidebar on iPad and Mac") and the MacWindow preview put it in the sidebar. |
| Note, mixed segments | handoff/screens/Mac-Window.dc.html: a typed segment, a voice segment playing "0:14 / 0:42", a voice segment "Saved, text on its way", and a typed segment marked "Added from the command line". handoff/system/components/MacWindow/preview.html: a typed segment and a voice segment. | No ink segment in a Mac note. Both Mac pictures leave it out, although the selected sidebar row in the MacWindow preview shows the ink kind glyph (g-ink). |
| A segment moved to its own note, with undo | Only the menu, reached by the hover rule in MacWindow/README.md ("it and secondary click open the segment menu"). | A Mac picture, and the moment after the move with undo. |
| Settings, the full list | Rules: 01-platforms.md "The `Settings` scene, one grouped `Form`: the iPhone rows plus Hotkey (a shortcut recorder) and Open at login."; Settings/preview.html caption "Mac: the Settings scene (⌘,), the same rows plus the hotkey and Open at login." | No Mac picture. The command-line access switch is not designed at all, and so neither are the draft's two ways of putting `knot` on the PATH and the note for sandboxed MCP clients. |
| Hotkey recorder; key already taken; command-line access | Rule only: 01-platforms.md "Hotkey (a shortcut recorder)" in the Settings scene, and "The person chooses the key in Settings (no default steals a common shortcut)". MacWindow/preview.html caption: "⌥Space is an example: the person sets the hotkey." | A picture of the recorder; the key that another app already uses; the command-line access switch (and the draft's two ways of putting `knot` on the PATH, and the note for sandboxed MCP clients). |
| Two columns do not fit; keyboard up | Nothing | The narrow Mac window's layout rule and picture. |

### Watch

| State | The handoff has | Missing |
|---|---|---|
| Recording, live | screens: Watch.dc.html, "Live" (timer "0:12", red stop control, "Recording"). system: components/WatchRecord/preview.html, Live. | No level: brief asks "recording, with a timer and a level". Neither picture draws one. |
| Recording, continues a note or starts a new one | Nothing | How the Watch shows, without note text, whether a recording continues a note or starts a new one. |
| Recording, display dimmed | Nothing | The Watch recording screen with the display dimmed. |
| Stopped at the limit, or by a call | system: components/WatchRecord/preview.html, "Stopped at the limit" ("Saved / Stopped at 30 minutes.", "Haptic: stop, then notification"). | A stop by a call and a stop with storage full, which the draft asks for on the Watch. Not on screens: Watch.dc.html. Against main's Watch list ("the limit reached") alone, this would be designed_component. |
| Storage nearly full | Nothing | The whole state. |
| Launchers: idle, recording, waiting, failed | handoff/system/components/Complications/preview.html: "Circular: the mark" (idle), "Circular, live" (`mic.fill`), "Corner" (the mark), and "Rectangular and Smart Stack" with "Record" / "2 waiting". handoff/screens/Widgets.dc.html "Watch complication" shows only the mark. | Failed: Complications/README.md asks only for "how many captures wait, and whether a recording is live". Recording on the corner, rectangular and Smart Stack. The Watch control glyph (brief §6). |

### Outside the app

| State | The handoff has | Missing |
|---|---|---|
| Recording, live | system: components/Launchers/preview.html (Live Activity Lock Screen "Recording / 0:12 · Knot" with stop; Dynamic Island expanded with live waveform; compact `mic.fill` and "0:12"; minimal `mic.fill`; "Control, live"). components/Complications/preview.html, "Circular, live". screens: Widgets.dc.html, "Dynamic Island, recording and minimal". | The Lock Screen Live Activity has no level. 01-platforms.md: "Lock Screen: a red dot, \"Recording\", the timer and a stop button, nothing else". The brief says these show "a timer, a level and a stop control". The two start branches (from the locked phone, and after Face ID opens Knot) are not designed. The draft also asks for the Live Activity in the Watch's Smart Stack and the Mac's menu bar; neither is shown. The artboard contradicts the system: in screens: Widgets.dc.html the compact Dynamic Island shows the Knot mark (`aria-label="Knot"`) and red bars with no timer, and the minimal shows the mark, while 01-platforms.md says "compact leading `mic.fill` in `record`, compact trailing the timer ... minimal is `mic.fill` alone". |
| Recording, continues a note or starts a new one | Nothing | The Live Activity and Dynamic Island showing, without note text, whether the recording continues a note or starts a new one. |
| Just stopped: saved, with text arriving except on the Watch | Nothing | The Live Activity's finished state, on the Lock Screen and in the Dynamic Island. |
| Short recording discarded | Nothing | The Live Activity, Dynamic Island and control after a discarded short recording. |
| Stopped at the limit, or by a call | Nothing | The Live Activity when the limit is reached (brief: "and the limit reached"), and when a call or the disk stops the recording. |
| Could not start, with the reason | Nothing | The state where a recording could not start, with its reason and a way to open Knot. |
| Launchers: idle, recording, waiting, failed | handoff/system/components/Launchers/preview.html: the small widget with "2 waiting" (full colour and tinted) and "1 needs you" (clear), the Lock Screen accessory (the mark), "Control: Record" (`mic`), and "Control, live" (`stop.fill` only). The recording timer appears in the Live Activity ("Recording", "0:12 · Knot") and the Dynamic Island. | The control's timer while live: 01-platforms.md says it "shows `stop.fill` tinted `record` and the timer", but the "Control, live" preview shows no timer. The New note and Search controls (brief: "Record, New note, Search") and the draft's Search widget. handoff/screens/Widgets.dc.html goes against the system: its small widget shows only the mark, with no "Knot" and no state line (01-platforms.md: "The mark top-leading, \"Knot\" and one state line"). |
| Menu bar icon: idle, recording; its menu | handoff/system/components/MacWindow/preview.html: the menu bar extra with the mark, and its menu: "2 captures waiting to sync", New Capture ⌥Space, Start Recording "hold ⌥Space", Open Knot, Settings… ⌘,, Quit Knot ⌘Q. assets/Logos/README.md: "template image, 16 pt tall". | The icon while recording. No recording variant exists, and MacWindow/README.md says "don't colour the menu bar icon". |

## Cells with a rule and no picture

The design system states these in words. A builder can build them. The brief asked for each as a screen, so they are listed for the designer too, after the list above.

| State | Surface | Where the rule is |
|---|---|---|
| Capture, empty | iPad | system: 01-platforms.md, iPad: "The detail column is the capture surface: on launch it shows the note the append window is open on, or a new empty note, with the field focused. Done and New note are in the detail toolbar; the record control is in the bottom toolbar of the detail column." |
| Capture, empty | Mac panel | system: 01-platforms.md, Mac: "A non-activating `NSPanel` over any app, `mac-panel-width` wide, centred in the upper third of the active screen, on glass with `radius-xl` corners. The field uses `mac-title2`... A footnote line names the keys (⌘↩ Done, ⌘N New note, esc Close); the 28 pt record control is trailing." components/MacCapture/README.md: "Tap the hotkey to type". |
| Short recording discarded | iPhone | system: 02-states.md: "A stop within one second discards the recording: the surface says \"Too short. Nothing was kept.\" and nothing is added." README.md haptics: "Too short, nothing kept \| `.warning`". |
| Stream, populated | iPad | system: 01-platforms.md, iPad: "`NavigationSplitView` with two columns: the stream in the sidebar column, the open note in the detail column." 03-elements.md: "Search \| `.searchable` (... sidebar on iPad and Mac)". |
| Stream, notes could not be opened | Mac window | system: 02-states.md, Notices: "Inline, in the content layer, at the top of the note or stream they concern", with the "Notes can't be read" sentence. README.md Typography: "A notice's sentence \| `ios-callout` \| `mac-callout`". |
| Note, mixed segments | iPad | handoff/system/01-platforms.md iPad: "`NavigationSplitView` with two columns: the stream in the sidebar column, the open note in the detail column." README.md: "On iPad and Mac, keep note text within `readable-width` (the readable content width, which grows with Dynamic Type), aligned to the leading margin." and "A note is a page: segments stack with `space-6` between them and nothing else, no dividers, cards or bubbles." |
| Note, a segment being edited | iPhone | handoff/system/components/Segment/README.md: "Each segment edits in place. Actions are in its context menu, never as buttons on it." handoff/system/03-elements.md: "Note text and the field \| `TextEditor` / `TextField(axis: .vertical)` per segment, plain style, no border". |
| Note, a segment being edited | Mac window | 03-elements.md gives one rule for every platform: "`TextEditor` / `TextField(axis: .vertical)` per segment, plain style, no border". MacWindow/README.md: "Hovering a segment lifts it onto `fill-quaternary` with a quiet `ellipsis`". |
| Delete with undo; share | Mac window | Rules: MacWindow/README.md: "Hovering a segment lifts it onto `fill-quaternary` with a quiet `ellipsis`; it and secondary click open the segment menu." 01-platforms.md Mac: "The window toolbar holds New note, Share and the note's `ellipsis` menu". README.md: "⌘⌫ Delete segment, ⌘Z Undo". The MacWindow preview draws the entry points: the toolbar group with compose, share and ellipsis glyphs, and a hovered segment with its ellipsis. |

## What the draft brief changes

Pull request 114 holds a draft that brings the brief up to the spec. It is not merged, and its matrix differs from the one on `main` in these cells. They are checked here so that the list does not grow by surprise when the draft merges.

| State | Surface | On `main` | In the draft | The handoff has | Missing |
|---|---|---|---|---|---|
| Recording, before the microphone is live | iPhone | – | Yes | In part | The artboard's Starting uses the live red fill and shows a timer, so it looks like recording, which the draft forbids. It also contradicts components/RecordControl/README.md: "Idle and Starting are `.buttonStyle(.glass)`". |
| Recording, before the microphone is live | iPad | – | iPhone | Inherits a gap | As on iPhone: a Starting phase that does not look like recording. |
| Recording, before the microphone is live | Mac window | – | Mac panel | Inherits a gap | As in the Mac panel. |
| Recording, before the microphone is live | Watch | – | Yes | Drawn as a component | Not on screens: Watch.dc.html or components/WatchRecord/preview.html. No outcome line is stated for it. |
| Recording, before the microphone is live | Outside the app | – | Yes | Not designed | The Live Activity, Dynamic Island and control in the moment between the press and a live microphone, which must not look like recording. |
| Short recording discarded | Mac panel | – | Yes | In part | No picture. The handoff discards every stop within one second. The draft says "Only a recording started by a click on the microphone control, from Siri or from Shortcuts can be discarded: a hold is exempt", and nothing in the handoff exempts a hold. |
| Short recording discarded | Mac window | – | Mac panel | Inherits a gap | As in the Mac panel. |
| Ink in progress; ending a drawing | iPhone | – | iPad | Inherits a gap | As on iPad. |
| Capture, typing ended by a recording | iPhone | no such row | Yes | Not designed | The whole state: typed text saved as its own segment when a recording starts from the Action Button or a control, the recording following it in the same note, and how the surface says that the typed text was saved. |
| Capture, typing ended by a recording | iPad | no such row | iPhone | Inherits a gap | Everything, as on iPhone. |
| Capture, typing ended by a recording | Mac panel | no such row | Yes | Not designed | Typing, then a recording started from the microphone control or a held key: the typed text saved as its own segment, and how the panel says so. |
| Open note deleted on another device, with restore | iPhone | no such row | Yes | Drawn as a component | Nothing. |
| Open note deleted on another device, with restore | iPad | no such row | iPhone | Inherits | None. |
| Open note deleted on another device, with restore | Mac window | no such row | iPhone | Inherits | None. |

## The three conditions of acceptance

`docs/architecture.md` §16 asks that each capture surface is shown at the largest text size, with Reduce Motion and with the keyboard up.

| Surface and condition | Result | Where, and what is missing |
|---|---|---|
| iPhone capture surface at the largest text size | Missing | Only a rule: README.md "so Dynamic Type works up to AX5". The only large-size picture is a stream row at AX3 (StreamRow/preview.html), which is neither the capture surface nor the largest size. No capture surface at AX5. |
| iPhone capture surface with Reduce Motion | Partial | README.md: "With Reduce Motion on, replace morphs with crossfades and freeze the live waveform to a level bar.". A rule only; no picture of the capture surface under Reduce Motion. |
| iPhone capture surface with the keyboard up | Met | handoff/system/components/CaptureSurface/preview.html: the first phone shows a 300 px keyboard stand-in, with the append window open and typing. handoff/screens/Main.dc.html and iPhone-Recording.dc.html draw no keyboard. |
| iPad capture surface at the largest text size | Missing | No iPad picture anywhere. |
| iPad capture surface with Reduce Motion | Partial | Only the general README.md Reduce Motion rule. No iPad picture. |
| iPad capture surface with the keyboard up | Missing | No iPad picture. |
| Mac panel at the largest text size | Missing | MacCapture/preview.html at the default size only. |
| Mac panel with Reduce Motion | Partial | Only the general README.md rule. No picture. |
| Mac panel with the keyboard up | Met | MacCapture/preview.html shows the panel while typing. The Mac has no on-screen keyboard, so this condition does not apply in substance. The orchestrator should confirm it counts it as met. |
| Watch capture surface at the largest text size | Missing | WatchRecord/preview.html and handoff/screens/Watch.dc.html are at the default size only. |
| Watch capture surface with Reduce Motion | Partial | Only the general README.md rule. No picture. |
| Watch capture surface with the keyboard up | Met | Not applicable: the Watch has no keyboard. 01-platforms.md: "No list, no text entry, no settings, no navigation.". Not applicable, so marked met. |

## What the brief asked to be returned

Section 9 of the brief, item by item.

| What is asked | Result | Where, and what is missing |
|---|---|---|
| Two or three directions with their scores (actions to capture, continue, find) | Missing | Nothing: no directions and no scores in either folder. The handoff is a single direction. |
| Structure sheet for the capture surface of each of the four devices | Partial | 01-platforms.md describes each device's structure in prose (iPhone sheet over the stream, iPad split view, Mac panel, Watch one screen). RecordControl/README.md gives the control's phases. There are no sheets. The iPad capture surface's regions and the component in each state are thin. |
| Tokens as CSS variables | Missing | components/bundle.css uses var(--...) and says "Every value comes from tokens.css". tokens.css is not in either folder, and nothing in the handoff defines the variables. |
| Tokens as JSON: colour roles for light and dark | Met | tokens.json color: 23 tokens and 4 themes ("iOS · iPadOS Light", "iOS · iPadOS · watchOS Dark", "macOS Light", "macOS Dark"). handoff/screens/ds/knot/tokens.json is byte-identical to the system's. |
| Tokens: type ramp | Met | tokens.json type groups for iOS · iPadOS, macOS and watchOS; README.md typography table. |
| Tokens: spacing and radii | Met | tokens.json spacing space-1 to space-8; radius-sm to radius-full. |
| Tokens: materials and elevation | Partial | tokens.json has glass and glass-edge colours and shadow-glass and shadow-panel. README.md: these "exist only so these web previews can suggest Liquid Glass". There are no material tokens; materials are named only in the README prose. |
| Tokens: motion durations and curves | Missing | tokens.json has no motion group (its groups are color, type, spacing, radius, size, shadow). README.md names only ".smooth by default, .snappy for the record control's morph". |
| Component inventory with every state, named the same on every device | Partial | 15 components with README and preview, plus Cover. Many states are missing (ink recognition, sync, export, search, Watch storage full). The capture surface is named differently per device (CaptureSurface, MacCapture, WatchRecord). |
| Screens at the native size of iPhone 17 Pro | Partial | The screens artboards are 390 × 844 (canvas.json). Only the component previews' .k-phone frame is 402 × 874. 402 × 874 is my understanding of the 17 Pro's size in points; the handoff names no model. Most states have no screen. |
| Screens at the native size of iPad mini | Missing | No iPad artboard or preview. |
| Screens at the native size of Apple Watch Ultra 2 | Partial | handoff/screens/Watch.dc.html and .k-watch are 208 × 248. The handoff names no watch model. By my understanding the Ultra 2 is 205 × 251 points, so these frames match no listed size. |
| Screens at one smaller watch size | Missing | Only one watch frame size. |
| Screens of the Mac panel | Partial | Only MacCapture/preview.html (typing with the append window; held, recording). No screens artboard. |
| Screens of the Mac window | Partial | handoff/screens/Mac-Window.dc.html, 1280 × 800. One state only (a populated stream with an open note); none of the window's other listed states, such as empty, narrow or search. Its toolbar goes against 01-platforms.md. |
| Prototype: iPhone capture with the append window | Missing | Main.dc.html has only a static "view" switch (Adding, Blank). No interaction. |
| Prototype: Mac hotkey tapped and held | Missing | MacCapture/preview.html shows the two states, static. |
| Prototype: a watch recording | Missing | Watch.dc.html shows Ready, Live, Saved and Too short side by side, static. |
| Prototype: typing and Pencil on the iPad capture surface | Missing | Nothing. |
| The matrix, filled in | Missing | A search for 'matrix' finds nothing, and 'inherit' appears only as the CSS value font-family: inherit. |
| Glyphs as SVG | Partial | components/bundle.css holds 44 glyphs as inline SVG data URIs (.g-mic, .g-stop, .g-wave, .g-ink, .g-terminal, .g-conflict and others). README.md calls them "hand-drawn stand-ins for the symbols named here" and maps every glyph to an SF Symbol. There are no SVG glyph files, and the inline SVGs are stand-ins for the preview, not assets meant for the apps. |
| Mark variants | Partial | assets/Logos/knot-mark.svg and knot-mark-white.svg; AppIcon/preview.html (default, dark, clear, tinted). The Icon Composer layers that AppIcon/README.md says to provide are absent. |
| README that answers the questions, lists the tokens and maps screens to components | Partial | README.md is a brand book with tokens by role. It has no section answering §7's questions (the answers are scattered across files) and no map from screen to components. |

## The brief's eight questions

Section 7 of the brief. Where the two parts of the handoff answer differently, both are given, and [`direction.md`](direction.md) says which holds.

| Question | Result | Where, and what is missing |
|---|---|---|
| Q1: iPhone capture field and stream: one screen or two, which way time runs | Partial | system 01-platforms.md: "The stream is the root ... The capture surface is a `.sheet` at the large detent over it ... the stream is one gesture away, never a tab." StreamRow/preview.html: "Plain list, newest first.". The two artifacts differ. The screens read as two screens, with the stream pushed from capture: Main.dc.html has a "Notes" button, and iPhone-Stream.dc.html has a "Back" button and no New note button. |
| Q2: how the note being added to appears; how to start a new note; how a capture without a screen shows which note it joined | Partial | README.md: "the note being added to sits above the field in `label-secondary`, with a footnote line (\"Adding to the note from 9:38\")". CaptureSurface/README.md: "New note is always one tap (⌘N) away." Same in Main.dc.html (Adding view). The part about a capture without a screen is not answered: the Live Activity shows only "Recording". On the draft's "how much of the note": not stated. The CaptureSurface preview shows one line, while Main.dc.html shows two sentences. |
| Q3: segments of different kinds as one note | Met | README.md: "A note is a page: segments stack with `space-6` between them and nothing else, no dividers, cards or bubbles." |
| Q4: Mac panel tapped versus held, and how it leaves after a hold | Partial | 01-platforms.md: "Tap to type, hold to record; releasing stops." MacCapture/preview.html: the typing panel shows key hints (⌘↩ Done, ⌘N New note, esc Close); the held panel shows "Release the hotkey to stop" and the live control with its timer. README.md haptics, Mac Saved: "the checkmark, one second". Nothing says how the panel leaves after a hold: MacCapture/README.md only says "Esc, ⌘↩ or clicking elsewhere ends the capture." There is no screens artboard for the panel. |
| Q5: a recording outside the app, without words | Partial | system 01-platforms.md: "Lock Screen: a red dot, \"Recording\", the timer and a stop button ... compact leading `mic.fill` in `record`, compact trailing the timer; ... minimal is `mic.fill` alone.". The two artifacts differ: screens Widgets.dc.html draws the Dynamic Island with the mark and a red waveform, and the minimal with the mark. Neither shows whether the recording continues a note. |
| Q6: smallest Watch screen that makes recording and saved certain | Met | 01-platforms.md: "The record control at `record-control-watch`, centred, and one outcome line under it." README.md haptics: Live `.start`; Saved `.stop`, then `.success`. Watch.dc.html adds the word "Recording" under the live control, where WatchRecord/preview.html shows the timer only. |
| Q7: iPad typing and Pencil without a mode switch; what ends a drawing | Met | 01-platforms.md: "Touching the Pencil to the page opens a blank ink canvas below the last segment ... ends only with Done, never with a stray touch. A Sketch control (`pencil.tip`) ... opens the same canvas with a finger.". Answered in text only; there is no picture. |
| Q8: where a lasting problem shows outside Settings | Partial | 02-states.md notice: "Knot can't read your notes. Nothing was deleted. New captures are kept safe and appear when your notes open again." at the top of the stream. States.dc.html has the shorter "Knot can’t read your notes. Nothing was deleted.". Sync failing for hours is not answered. The only related item is the menu bar's "2 captures waiting to sync". |

## Across devices

Section 6 of the brief, "Across devices".

| What is asked | Result | Where, and what is missing |
|---|---|---|
| Glyphs: typed, voice, ink; pending; failed; conflict; arrived; command line; record and stop | Met | README.md iconography: `text.alignleft`, `waveform`, `scribble`; `ellipsis.circle`; `exclamationmark.triangle.fill`; `arrow.triangle.2.circlepath`; 8 pt dot and `tray.and.arrow.down`; `apple.terminal`; `mic`, `mic.fill`, `stop.fill`. These are named SF Symbols. The only SVGs are the preview stand-ins inside bundle.css. |
| Motion: the capture surface arriving, with its Reduce Motion version | Partial | Only the general rules: "Animate with the system's springs (`.smooth` by default...)"; "replace morphs with crossfades". |
| Motion: a recording starting and stopping, with its Reduce Motion version | Met | README.md: "`.snappy` for the record control's morph from circle to live fill"; under Reduce Motion, crossfades and "freeze the live waveform to a level bar". |
| Motion: a segment landing in the stream, with its Reduce Motion version | Missing | Nothing specific. |
| Motion: pending becoming ready, with its Reduce Motion version | Partial | VoiceStates/README.md: "Don't animate pending glyphs beyond the symbol's own `variableColor` effect". 02-states.md: live words "settle into `label`". The change to Ready and its Reduce Motion version are not described. |
| Haptics and sound by event and device (spec §4.5) | Partial | README.md table: Live, Saved, Too short, Couldn't start, Stopped at the limit, Deleted, across iPhone · iPad, Watch and Mac. "Knot plays no sounds of its own.". Missing: stopped by a call or because the recording could not be saved further, and delivered to the iPhone (the complication count). The iPhone discard is `.warning`, where the spec says "A light haptic". The Mac discard row does not give the spec's exemption for a held hotkey. |
| The mark in use: menu bar template | Met | MacWindow/preview.html menu bar; Logos/README.md: "template image, 16 pt tall". |
| The mark in use: complication | Met | Complications/preview.html (circular, corner, rectangular); Widgets.dc.html "Watch complication". Widgets.dc.html also puts the mark in the Dynamic Island compact and minimal views, where 01-platforms.md has `mic.fill`. |
| The mark in use: app icon appearances (default, dark, clear, tinted) | Met | AppIcon/preview.html: "Default \| Ink on paper", "Dark \| Paper on ink", "Clear \| The bars as glass", "Tinted \| One ink, the person’s". The Icon Composer layers are not supplied. |

## The five decisions of the design sitting

Five decisions were prepared for the owner's sitting at gate G2, and the sitting did not take them. This is what the handoff implies for each. None is decided by it: they stay the owner's.

| Decision | What the handoff implies |
|---|---|
| G2-01. Do the four rules read from his references stand: few controls, each with one job; complexity inside, not on the surface; options are not buttons; the app belongs to its operating system? | The handoff is built on all four readings but does not record the owner's word. README Principles: "Use the system's element, and only for its job." "Fewer controls than you expect. A control used on every visit is in the toolbar. A control used now and then is in a menu. Actions on a segment live in its context menu, never as buttons on every segment." Intro: "Knot is four native apps that feel like part of the system ... The system is the brand". 03-elements: "Things Knot never has: ... any control that only some people would use." |
| G2-02. The Live Activity and the Dynamic Island during a recording: a level meter, as the brief asks, or the timer and the stop control only, as the spec has it? | The two artifacts disagree. System: Lock Screen "a red dot, "Recording", the timer and a stop button, nothing else". Dynamic Island "compact leading `mic.fill` in `record`, compact trailing the timer; expanded adds the live waveform; minimal is `mic.fill` alone". So the level is in the expanded island only. Screens (Widgets.dc.html, "Dynamic Island, recording and minimal"): the mark and six red level bars, no timer, and the mark as minimal. Both add a level somewhere. Neither puts one on the Lock Screen. |
| G2-03. A typed line or a drawing whose save failed: does Retry try the save again at once, or does the case get a state of its own with no action? | Silent on typed and drawing saves. By default "Needs you" always carries Retry: "Needs you \| "Needs you" in `attention`, semibold \| ... \| "Retry"; play" and "Only "Needs you" is coloured (`attention`, with `exclamationmark.triangle.fill` and a Retry button)". Applied as written, that would give the failed-save case a Retry. |
| G2-04. Three texts not yet written: the mark on a conflict copy, the first-run line when sync is switched off, and how the capture surface says that typed text was saved when a recording ends it. | None of the three texts is written. Conflict copy: no mark, only a decision notice ("This text changed on another device while you edited it." with Keep mine / Keep the other). Sync switched off: only "iCloud sync is on.". Typed text saved when a recording ends it: nothing, only "Recording. Typing waits until you stop." |
| G2-05. Whether to attach the retired app's handoff as an example of the format. | Silent. Nothing in either folder refers to the retired app or its handoff ("retired", "previous round" occur in neither). The delivered format differs from brief §9's "same kind of bundle as the previous round". There is a design system (README.md, tokens.json, components with preview.html, bundle.css), and nine .dc.html artboards with canvas.json. There is no filled state matrix, no motion tokens, and no README that answers the brief's section 7 questions explicitly. design-system.json notes "First version: HIG-native tokens, brand book, 15 components, the mark." |

## The open points that waited for the design round

From `docs/plan/open-points.md`. A point that the handoff answers is not yet settled in the documents: the orchestrator settles it in a pull request of its own, with the owner's word where the point is his.

| Open point | What the handoff says |
|---|---|
| 2. The shared consistency check | Not a design point (it names a package brief only: "No brief claims it."). The handoff does not bear on it. |
| 5. Paths in wave 4 | Not answered. The handoff does not say which views or paths each sub-package restyles. It also has no state matrix marked designed or inherited ("matrix" occurs in neither folder), which arch §16's acceptance check and the term "designed cell" need. |
| 10. A start row that misses a dependency | Not a design question, and the handoff does not settle it. It does change what the Sketch control is: 01-platforms.md: "A Sketch control (`pencil.tip`) in the toolbar opens the same canvas with a finger", an in-app button and not a system control. That may change whether WP-31 holds a Sketch control at all (S-09). |
| 11. Settings lines from the system surfaces | Partly. The ownership question is not answered. The handoff gives the content: the screens' Settings has "Live Activities are off, so recording from the Lock Screen opens Knot first.", and FirstRun gives the rows "Record with the Action Button, Add a Lock Screen control, Add the Watch complication" ("tapping explains the system steps in a sheet"). There is no Action Button tip in Settings. |
| 13. A cut and the design sub-packages | Not answered. The handoff says nothing about cuts or sub-package order. |
| 14. The release dry run | Not a design point. Not answered. |
| 15. Header cells no item filled | Not a design point; it mentions WP-03's brief only. Not answered. |
| 17. The cells outside the app | Not answered. The handoff designs widgets, controls, the Live Activity and complications (Launchers, Complications, Widgets.dc.html). It says nothing about the iPhone Live Activity appearing in the Watch Smart Stack or the Mac menu bar, or about what a tap there does. |
| 18. The milestone table | Not a design point (it names package briefs only). Not answered. |
| 19. Conditions added in wave 4 (theme and DESIGN.md) | Not answered. The handoff supplies tokens.json and a brand book README.md that could seed the theme, but no DESIGN.md. tokens.json has groups color, type, spacing, radius, size and shadow, and no motion durations or curves, which the brief §9 asks for (README only says "Animate with the system's springs (`.smooth` by default, `.snappy` ...)"). handoff/screens/ds/knot/tokens.json is identical. |
| 20. Who makes the M6 build | Not a design question. Not answered. |
| 22. Full iCloud storage | Not answered. The only sync status in the handoff is the Mac menu line "2 captures waiting to sync", the first-run line "iCloud sync is on." and the Settings toggle "iCloud sync". There is no storage-full state ("storage" occurs in neither folder). |
| 23. The prompt when the iCloud account changes | Not answered. No prompt is designed; "account" occurs only in "No walkthrough, account or permission screen up front." The alert ban in 02-states ("Use an alert only to confirm emptying Recently deleted") leaves no form for one (S-50). |
| 24. What a person sees when sync pauses for a large delete or a restored store | Not answered. No sync-pause prompt or notice appears in 02-states.md's notice table. |
| 25. The thresholds that left WP-10 and WP-30 | Not a design point. Not answered. |
| 29. Why a recording ended, after a relaunch | It bears on the point without settling it. The handoff shows the reason only as a dismissible notice: "Stopped at the limit \| `stop.fill` \| "Recording stopped at 30 minutes and was saved." \| close". It does not show the reason on the segment, so it implies no lasting field is needed. That conflicts with spec §4.2, "the segment says why it ended" (S-23). The Watch shows it as an outcome line, "Saved / Stopped at 30 minutes." (WatchRecord/preview.html). |
| 30. Taking over the work of a recording | Not named by the keywords, but bears on it. The handoff names the action "Make it here" on "Saved, text being made elsewhere" (02-states.md; VoiceStates/preview.html) and nowhere else; it does not touch the missing operation. |
| 33. The Watch says "Recording" over a stopped microphone | Bears on it. The screens show the word "Recording" under the live control (Watch.dc.html). The system defines a separate Stopping phase: "as Live, glyph at half strength, timer frozen", and the RecordControl preview draws Watch "Stopping". So the design expects a Stopping look while the file closes, not Live. |
| 37. A segment whose save failed | Not answered. The handoff defines "Needs you" only for voice, with "Retry" ("Needs you \| ... \| "Retry"; play"; SegmentMenu "Retry (needs you)"). It has no case for typed text or a drawing whose save failed, and no state of their own. |
| 38. A conflict copy in an export | Not answered. There is no mark on a conflict copy. The handoff instead has a decision notice: "This text changed on another device while you edited it." with "Keep mine, Keep the other" (screens: "This text changed elsewhere while you edited it." / "Keep the new text"), and glyph name "Edit conflict". |
| 39. The first-run line when sync is switched off | Not answered. Only "iCloud sync is on." is given. |
| 40. A typed capture that ends under its surface | Not answered. The recording frames show "Recording. Typing waits until you stop." and the live segment. In the CaptureSurface preview the recording frame no longer shows the typed line from the typing frame ("Bulbs from the market, not the shop"), and no saved message is given. |
