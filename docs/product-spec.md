# Knot v1: product spec

Draft of 2026-11-18 · assumptions answered by Paolo on 2026-11-19

This file says what Knot v1 does. How it is built is in [architecture.md](architecture.md). How the work is organised is in [PLAN.md](../PLAN.md).

Where a behaviour here is an assumption and not yet Paolo's decision, it is marked **(A)** and listed again in section 16. None is left.

## 1. What Knot is

Knot gets a thought out of your head and into a note with as little friction as the device allows. You type it, say it, or write it by hand, on a Mac, iPhone, iPad or Apple Watch. Every capture lands in one stream. There is nothing to file and nothing to set up.

Knot is built to App Store standard, used by Paolo alone to begin with, and open source.

Three promises, in priority order:

1. **Ready before you are.** Every entry point ends in a state where your next action is the capture itself: a focused text field, a live microphone, or a blank canvas.
2. **Nothing is lost.** A capture is on disk before Knot does anything else with it. A recording survives a crash, a dead battery and a failed transcription.
3. **Nothing to manage.** One stream, newest first, with search. No folders, tags, links or templates.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| Stream | The single list of all notes, newest first. |
| Note | One entry in the stream: an ordered list of segments and an optional title. |
| Capture | One act of input: a typing session, a recording, or a drawing. |
| Segment | What a capture becomes inside a note. There are three kinds: typed, voice and ink. |
| Append window | A number of minutes, X, set by the user. It decides whether a capture joins the previous note or starts a new one. |
| Pending | A segment whose processing is unfinished: still on the watch, not yet transcribed, or not yet cleaned up. |

## 3. Notes and the append window

A note is a series of captures made close together.

1. When a capture starts, Knot looks at the most recent capture in this device's copy of the stream. If that capture ended less than X minutes ago, the new one becomes the next segment of the same note. Otherwise it starts a new note.
2. X is a setting, in minutes. The default is 5. Zero turns appending off, so every capture is its own note. The one exception is a capture that ends an open one on the same device (rules 13 and 15): it stays in that capture's note.
3. The gap runs from the end of the previous capture to the start of the new one. A long recording keeps its note open while it runs. A gap that comes out negative, because a clock moved back, counts as inside the window when it is negative by less than X. A larger negative gap starts a new note.
4. "New note" forces a new note inside the window. It is one action away wherever the capture surface shows the note: the iPhone and iPad capture surface, the Mac panel and an open note. A capture started from the Action Button, a control, the Watch or a held key follows the window, and its surface shows whether it continues a note or starts a new one, without showing any text. A capture made from inside a note that "New note" closed joins that note, by rule 5, and does not reopen it: the next capture that follows the window still starts a new note.
5. Capturing from inside an open note always appends to that note, whatever the window says.
6. Modes mix. A typed line, then a recording, then a sketch, all inside the window, are three segments of one note.
7. A capture that arrives late, such as a watch recording delivered an hour afterwards, is placed by its own timestamps. With the window at zero it is its own note (rule 2). Otherwise Knot looks at the captures that started before it. If one of them was still running when the late one started, the late one joins that capture's note, as rule 3 keeps a note open while a recording runs, and if several were running, the one that started last decides. If none was running, the earlier capture that ended last decides: when it ended less than X minutes before the late one started, the late one joins its note. The late capture takes its place in the note in time order. When no note qualifies, or rule 10 rules out the one that does, it becomes a new note dated when it was recorded, and Knot looks no further back. A deleted capture counts here as rule 14 says. Existing notes are never regrouped. Late captures that arrive together are placed in the order they started. Those that arrive at different times are placed as they arrive, so two of them can land differently depending on which arrives first.
8. Two devices that are offline at the same time each apply the rule to what they know. Knot does not merge the resulting notes afterwards.
9. The stream is ordered by the time of each note's latest capture, using the capture's own timestamps. Editing a note does not move it.
10. A late capture never joins a deleted note. It joins a note closed by "New note" only if it was recorded before the note was closed. The window applied to a late capture is the receiving device's current setting.
11. A note with no segments left is treated as deleted.
12. A draft found after a crash becomes a finished typed segment at relaunch.
13. A typed capture starts at its first keystroke, not when the surface appears, and the note it joins is decided then. Holding the Mac hotkey while typing ends the typed capture and starts a recording as the next segment of the same note.
14. A capture never joins a deleted note, and a note with no segment left counts as deleted (rule 11). A deleted capture does not count for the window, with one exception that comes first. If the most recent capture of all, deleted or not, belongs to a deleted note, a new note starts, and Knot does not fall back to an older note. In every other case the window looks at the most recent capture that has not been deleted. A capture inside the window joins that capture's note, unless that note is deleted: then a new note starts, and Knot looks no further back. A deleted note counts here only until it is purged, 30 days after the delete: from then on its captures no longer count for the window.
15. One capture is open at a time on a device. Starting a capture of another kind, or on another surface, ends the open one, and the new capture is the next segment of the same note. A recording is the exception: while it runs, no capture surface on that device accepts typing or Pencil. Text added through the command line or MCP does not end an open capture. It is placed by the window like any other capture.
16. Knot never regroups notes by itself. You can: "Move to its own note" takes one segment out of a note (section 7). A move does not reset the window. The window still looks at the most recent capture, in whichever note now holds it, so a capture made within the window of a segment you have just moved out joins that segment's new note.

## 4. Capturing

### 4.1 Typing

- The field has focus when the surface appears.
- Text is saved as you type, at most 150 ms behind the last keystroke. It is saved again whenever the surface hides, the app goes to the background, or the app quits.
- There is no save button. A typing capture ends when you dismiss the surface, press ⌘↩ or Done, or leave the app. An empty capture leaves nothing in the stream, and text that is only spaces and line breaks is empty.
- If saving fails, Knot writes the text to a fallback file, shows the capture as failed and retries.
- If the append window is open, the earlier segments of the note are visible with the field, so you can see what you are adding to. That display follows the window: when the window runs out while the field is still empty, the earlier note leaves the surface. The destination is fixed at the first keystroke and does not change after it.

### 4.2 Speaking

- Recording starts at once. The audio is written to disk continuously, in a form that survives the app being killed. At most the last second is lost.
- Where a screen is showing, the words appear as you speak. The Watch is the exception: it shows no words.
- You stop with the control that started the recording. A recording also stops when a phone call interrupts it, or after 30 minutes. Reaching that limit gives the same cue as stopping, and the segment says why it ended.
- A recording started by a tap and stopped within one second of that tap is treated as an accidental press and discarded. The second is measured between the two presses, not in audio. A press while a recording is still starting or stopping is ignored. Hold-to-record on the Mac is exempt, because the hold already filters accidents. Every other recording is kept, even if it is silent or cannot be transcribed. A recording with no recognised words shows as a recording with no text.
- The recording stays attached to its segment until you delete it.
- If a crash cut a recording short, the next press starts a new recording, and the cut one is recovered beside it. A press never does nothing.
- Transcription runs on-device. v1 transcribes English only.

### 4.3 Writing by hand

- On an iPad, and on an iPhone that supports Apple Pencil (the iPhone Duo), touching the Pencil to the capture surface starts an ink segment on a blank canvas. The canvas grows as you write. On that surface the Pencil always draws: the system's handwriting-to-text input is off there.
- Strokes are saved as you make them.
- When the capture ends, Knot recognises the handwriting on-device. The ink stays as ink. The recognised text makes it searchable and can be copied.
- A drawing never ends by accident: one stray key press or touch does not end it. It ends with Done, or in the way the design chooses for typing and Pencil to share the surface.
- Every device shows a finished drawing. In v1 a finished drawing is not reopened: writing more starts a new ink segment in the same note.

### 4.4 When a capture cannot start or cannot be saved

- If a recording cannot start, Knot says why, wherever you are. On a locked iPhone the Live Activity shows the reason and offers to open Knot. The Watch gives a failure haptic and shows the reason when you raise it. The Mac panel appears with the reason.
- With too little free space, Knot refuses to start a recording and says so.
- If the disk fills while you record or draw, the capture stops with the stop cue and says why. What was captured up to then is kept.
- Text longer than one segment can hold continues in a new segment of the same note. Nothing is cut.
- If typed text cannot be saved anywhere, the capture surface stays open with the text in it and says that it could not save.
- A watch away from its phone keeps its recordings until the phone returns. It warns when little space is left and refuses new recordings at the limit.
- If Knot cannot open its notes at all, capturing still works. New captures are kept safe and appear once the notes open again, and the stream says what is wrong. Knot never deletes notes to recover.

### 4.5 What tells you it worked

Until the "live" cue, nothing on any device implies that Knot is recording. The design sets the exact haptics and sounds.

| Event | iPhone and iPad | Watch | Mac |
|---|---|---|---|
| Recording started and the microphone is live | A haptic, with the Live Activity or the recording state in the app | A haptic, and the timer starts | The panel's listening state |
| Stopped and saved | A haptic. The Live Activity shows saved, then ends. | A haptic and "Saved" | The panel shows saved |
| Could not start | A different haptic, and the reason in the Live Activity or the app | A failure haptic and the reason | The panel with the reason |
| Discarded, under one second | A light haptic, and the surface says nothing was kept | The same | Does not apply: a hold is exempt |
| Stopped at the limit, by a call, or because it could not be saved further | The stop cue, and the segment says why | The stop cue and the reason | The stop cue and the reason |
| Delivered to the iPhone | Nothing | The count of waiting recordings on the complication goes down | Nothing |

## 5. After a capture

| Kind | Step | Result |
|---|---|---|
| Typed | None | The text is the segment. |
| Voice | Transcribe | A raw transcript, kept permanently. |
| Voice | Clean up | Punctuation added, fillers and false starts removed, paragraphs and lists formed. The cleaned text becomes the segment's text. |
| Voice | Title | If the note has no title and its first segment is a recording, cleanup proposes one. |
| Ink | Recognise | Recognised text stored beside the ink. |

Rules:

- Cleanup may remove disfluencies and add punctuation and structure. It may not add, replace or reorder what you said. In v1 it removes fillers, repeated words and restarts where you began again with the same words. It leaves a spoken self-correction as you said it, and it leaves numbers as they were transcribed. Knot checks each result against the raw transcript and discards one that changes the words. The raw transcript is then the segment's text. That check proves the words are kept. It cannot prove that added punctuation keeps the meaning, so "Show original" is always one action away.
- "Show original" switches a voice segment between its cleaned and raw text.
- Cleanup and titles use Apple's built-in on-device model. On a device without that model, the raw transcript is the text. That is a finished state, not an error. If the model is only still downloading, cleanup waits for it.
- A title you typed is never replaced. A note with no voice segment gets no generated title, and the stream shows its first line. A generated title uses only words from the note.
- The device that made a recording transcribes and cleans it. A watch recording is handled by its iPhone. If that device cannot finish, Retry on another device takes the work over there.
- Knot records which engine and language produced each transcript.
- Every step can wait. If transcription cannot run now, because the speech model is still downloading or the app has no time left in the background, the segment shows as a playable recording marked pending. Knot finishes it at the next opportunity.
- A failed step is visible on the segment, with a retry action. A failure never removes the recording.

A voice segment is always in one of these states, named for what you can do, not for what Knot is doing:

| What you see | What it means | What you can do |
|---|---|---|
| Saved on the Watch | The recording is safe on the Watch and waits for the iPhone. | Nothing is needed. |
| Saved, text on its way | The recording is in the note and plays. Its text is being made on this device, and part of it may already show. | Play it. |
| Saved, text being made elsewhere | The same, but the work belongs to the device that recorded it. | Play it, or move the work to this device. |
| Ready | The text is there. Cleanup may still replace the raw text once. | Everything. |
| Needs you | A step failed. The recording is kept. | Retry. |
| Kept, no text | No words were recognised, the audio or the drawing cannot be read, the handwriting is in a language that cannot be recognised, or this device cannot turn speech into text. This is a final state, not an error. | Play, view or share the file, or delete it. Where this device cannot make the text and another can, move the work to that device there. |

Typed and handwritten segments use the same names. A typed segment is Ready, or "Needs you" when its save failed: its text is kept, and Knot stores it when it can. A drawing whose text is still being recognised is "Saved, text on its way", a recognised one is Ready, one whose recognition failed is "Needs you", and one whose drawing cannot be read, or whose handwriting is in a language that cannot be recognised, is "Kept, no text", with its file kept. A recording whose transcript is there is Ready while cleanup runs. A segment that a newer Knot made in a state this one does not know says so, and offers nothing else.

## 6. Entry points

### iPhone

| Trigger | What happens |
|---|---|
| App icon, Home Screen widget, Lock Screen widget | Knot opens with the keyboard up. From the Lock Screen this needs Face ID. |
| Action Button, Lock Screen control, Control Center control | Recording starts without opening the app. A Live Activity shows the timer and a stop button. Pressing the same control again also stops it. |
| Siri and Shortcuts | "New note", "Append to note", "Start recording", "Search notes". Back Tap and automations come through Shortcuts. |
| A "Search" control or widget | Knot opens on the stream with search focused. |
| Inside the app | A microphone button beside the text field. |

Starting a recording while the phone is locked is documented by Apple but unconfirmed in practice. Spike SP-1 tests it. If it fails, the control opens Knot after Face ID and recording starts immediately.

Widgets are launchers. They never show note text. A widget, control or complication may show state without text: a recording with its timer, how many captures are waiting, how many failed.

Notes are not indexed for Spotlight. Actions that only write, such as starting a recording, work on a locked device. Actions that read or pick a note need it unlocked.

### iPad

Everything the iPhone does, plus:

- Pencil on the capture surface starts an ink segment.
- A "Sketch" control and Shortcuts action open the canvas directly.
- Hardware keyboard: ⌘N new note, ⌘F search, ⌘↩ end capture, and a menu bar.
- The stream and the open note sit side by side. At launch the open column is the capture surface. When the width cannot hold two columns, as in portrait on an iPad mini or in a narrow window, the iPad uses the iPhone's layout.
- Knot has one window on the iPad in v1.

### Mac

| Trigger | What happens |
|---|---|
| Global hotkey, tapped | The floating capture panel appears with the cursor in it. Tapping again, or pressing Esc, hides it. |
| Global hotkey, held | The panel appears and records for as long as the key is held. Releasing the key stops the recording. |
| Menu bar icon | A click opens the menu: New Note, Open Knot, Settings and Quit. The icon shows when Knot is recording. |
| Main window | The stream, search and the open note. |
| Siri, Shortcuts | The same actions as on iPhone. |
| `knot` command and MCP server | See section 10. |

The hotkey is chosen in Settings. The hotkey is a key with at least one modifier, or a function key. A press shorter than 250 ms is a tap. The microphone opens only for a hold:

| Moment | What happens |
|---|---|
| Key down | Nothing shows. Knot gets the microphone ready without opening it. |
| Released before 250 ms | A tap. The panel appears ready for typing within 100 ms, or hides if it was showing. The microphone never opened. |
| Released a moment after 250 ms, before Knot has handled the mark | A tap as well. No press does nothing. |
| Still held at 250 ms | The panel appears and the microphone opens. The listening state shows once it is live, and that is the moment to speak. |
| Released after a hold | The recording stops. |

Because the microphone opens at the 250 ms mark, the first fraction of a second of a hold is not recorded. SP-5 measures whether first words get clipped in practice. If they do, the alternative is to listen from key-down into a buffer that a tap discards, on built-in and wired microphones only.

A recording started from Siri or Shortcuts on the Mac shows the panel with a stop control, and Esc also stops it. If a key release is ever missed, the recording goes on with the panel showing, and Esc or another press of the hotkey stops it. Holding the key while the panel is open records into it. After release the panel stays open while the text arrives. With no microphone connected, as on a Mac Studio without one, the panel says so and still accepts typing. If the key you choose is already taken by another app, Settings says so.

The panel floats above other windows, including full-screen apps, on the display you are working on. It does not take over from the app you are in, and it remembers where you put it. A tap gives the panel the keyboard. A hold shows it without taking the keyboard from the app you are in, and it hides by itself shortly after the text has arrived, unless you click or type in it. The panel and the main window also have a microphone control that starts and stops a recording with a click or a keyboard shortcut, for when holding a key is not possible. Knot lives in the menu bar and shows a Dock icon only while its main window is open.

### Apple Watch

| Trigger | What happens |
|---|---|
| Complication, Smart Stack widget, Control Center control | Knot opens already recording. |
| Action Button on an Ultra | The same. |
| Double Tap | Starts a recording when idle. Stops and saves when recording. |
| Siri and Shortcuts | "Start recording" opens Knot already recording. |

- Recording continues with the wrist down.
- The watch saves the recording, then hands it to the iPhone when the phone is reachable. The iPhone transcribes it. With no phone nearby the recording waits on the watch, and nothing reaches the stream until the phone is back.
- The watch is a capture device only. It shows no note content: no stream, no text of a recording and no preview of one, and there is no typing on it.
- The watch app has one screen: the record control, with its recording states. It has no list of recordings and says nothing about a transcript. A recording that has not reached the iPhone stays on the watch and is sent again by itself, and the complication shows how many recordings wait and how many failed.

## 7. The stream and the note

- The stream lists notes newest first. Each row shows the title or first line, a short preview, the time, which kinds of segment the note holds, and any pending or failed state.
- A row's preview is the text of the note's latest segment. A note with no text yet says what it holds, such as "Recording, 0:42" or "Sketch". At large text sizes the preview gives way first, then the kinds. The title or first line, the time and a failed marker always stay.
- A late capture is marked as arrived until its note is opened, and the stream says once that captures arrived, with a way to go to them.
- Opening a note shows its segments in order. Text is edited in place as plain text, with Markdown lightly styled. Voice segments have a play control. Ink segments show the drawing.
- A note is a stack of segments, separated by spacing alone. Each segment is edited on its own, a selection does not cross from one segment into the next, and undo covers the segment being edited. Copying a whole note is one action.
- New text enters through the capture field, which is the last element of every open note. Capturing in an older note looks the same as capturing in a new one, and with the window open the capture surface is that note with its field focused.
- A title is the heading of the note. It is edited in place and can be cleared.
- "Show original" shows the raw transcript and returns to the text as it was, your edits included.
- A segment written through the command line or MCP carries a quiet mark. A segment made by a newer Knot says so and asks for an update.
- Search is full text over titles, segment text and recognised handwriting. It filters the stream as you type.
- Delete works on a segment or a whole note. It can be undone at once, and deleted items stay recoverable for 30 days.
- "Move to its own note" takes one segment out of a note and makes it a note by itself. It repairs a grouping the window got wrong. It is offered on a segment when its note holds another segment that is not deleted, and never on a capture still in progress. The segment keeps its text, its recording or drawing, and any work still pending on it. The new note is dated by that capture, so it takes its place in the stream by its own time, and the note it left stays open in front of you. Titles stay where they are. A title you typed is never touched, and a title that Knot generated is dropped if it no longer fits the note it is on, which then shows its first line. The move can be undone at once, like a delete. In the app, a move that is not undone at once stays: v1 does not put a segment into another existing note. The command line can return a moved segment for 30 days (section 10).
- If a note you have open is deleted on another device, the note says so and offers to restore it.
- "Remove recording" keeps a voice segment's text and deletes its audio. The text stays, without a player. It is offered once the segment has text: until then the recording is all there is.
- If a late save of a capture reaches Knot after you changed that capture's text, your text stays, and the late save is added beside it, marked as a conflict, as for an edit made on two devices (section 9).
- Notes are edited in Knot, or through the command line and MCP server. Nothing else writes to them.

## 8. Getting notes out

- Share or copy a note as text or Markdown. Share a recording or a drawing as a file.
- Export everything to a folder of Markdown files with their recordings and drawings. Export first downloads any that are still on another device, and lists those it could not get.
- On the Mac, drag a note out of the window. It drops as text into another app, or as a Markdown file into Finder. Recordings and drawings stay behind; Share sends those.
- On the Mac, the command line and MCP server read and write notes.
- There is no continuous mirror into a folder and no Obsidian integration.

## 9. Sync

- One switch covers the whole app. When it is on, notes, titles, settings, recordings and drawings sync through the user's private iCloud database. When it is off, each device keeps its own notes and everything else works.
- A recording or drawing made on another device downloads when you open its note.
- Appending never conflicts. If the same segment's text was edited on two devices while they were apart, Knot keeps both. One stays in place and the other is added beside it, marked as a conflict.
- Sync is on by default when the device is signed in to iCloud.
- A segment added to a note that another device had already deleted is not hidden. On sync it moves to a new note.
- A segment moved to its own note on one device moves on the others. If two devices move the same segment before they sync, it ends in one of the two new notes, and the other, left empty, disappears. A note deleted on one device does not take with it a segment that another device had already moved out, as long as the move reaches it before the deleted note is purged.
- Text that Knot wrote never conflicts with yours. Your edit always wins over cleaned text, and cleaned text wins over the raw transcript.
- A capture syncs once it has ended. Drafts and recordings in progress stay on their device.
- A title edited on two devices keeps the later edit. A note deleted on one device and edited on another stays deleted, with the edit kept in the recoverable copy.
- The append window, the cleanup switch and the English variant sync. The Mac hotkey, launch at login and the sync switch itself belong to each device.
- If the notes are removed from iCloud, this device keeps its notes, pauses sync and asks before uploading them again. When the notes were removed on purpose, by a purge in Settings or a reset of the encrypted data, the prompt's default is to keep sync paused.
- Sync sits behind a feature gate so that it can become a paid feature later. In v1 the gate is open and there is no purchase flow.
- The watch does not use iCloud. It talks to its iPhone directly, so it works with sync off.

## 10. Command line and MCP (Mac)

`knot` ships inside the Mac app and works whether or not the app is running. It stays off until you turn on command-line access in Settings. Its main user is an agent acting for you, so every command finishes without asking anything.

| Command | Does |
|---|---|
| `knot add <text>` | Captures text, following the append window. `--new` forces a new note. |
| `knot append <note> <text>` | Appends to one specific note. |
| `knot list` | Lists recent notes. Takes `--limit` and `--since`. |
| `knot changes --after <cursor>` | Lists the notes that changed after a cursor, deletions included, with the next cursor. |
| `knot show <note>` | Prints a note as Markdown. |
| `knot search <query>` | Full-text search. |
| `knot edit <segment> <text>` | Replaces a segment's text. |
| `knot title <note> <text>` | Sets a title. `--clear` removes it. |
| `knot move <segment> --from <note>` | Moves a segment out of that note into a new note of its own. `--back` returns it. |
| `knot delete <id>`, `knot restore <id>` | Deletes a note or segment, and undoes that. `restore` also brings back text that `edit` replaced. |
| `knot export <folder>` | Exports everything. |
| `knot status` | Shows the store, how current it is, the open window and the versions in use. |
| `knot mcp` | Runs the MCP server on standard input and output. |

Rules:

- **Text.** Text is a required argument. A single `-` reads it from standard input. A command given no text is refused and writes nothing. No command ever prompts.
- **IDs.** Output shows full IDs. An argument may be a full ID, or the last eight or more characters of one if that is unique.
- **Output.** Every command takes `--json`. Results go to standard output and everything else to standard error. A write returns the note, the segment, whether it joined an existing note, the segment's revision and the store's cursor.
- **Retrying safely.** `add` and `append` take `--capture-id`. Repeating a command with the same ID changes nothing and answers with the capture as it is stored now. The same ID with different text is refused as a conflict.
- **Editing safely.** `edit` and `title` take `--if-revision`, and refuse when the segment or note has changed since that revision. A revision carries the store's generation, so one kept from before a restore of the store is refused too. Text that `edit` replaced is kept for 30 days. A segment whose capture is still open in the app cannot be edited, deleted or moved from the command line.
- **Moving.** `knot move` names the note you saw the segment in. If the segment is no longer there, nothing moves and the result says where it is, so the command is safe to repeat. It returns both notes, the segment and the store's cursor. `knot move <segment> --back` returns a segment to the note it left. It works for 30 days, on the Mac where the move was made, and it is refused when the segment has moved again since or the note it left is gone. `knot restore` is not used for moves: it undoes a delete, or brings back replaced text on a segment that is not deleted.
- **Polling.** `--since` is a filter on time. An agent that polls uses `knot changes`, which also reports a late Watch recording and a deletion. A page is read in one go and ordered by the counter, so a note that changes again simply appears again, and nothing is skipped. A deletion stays reportable after the purge. A cursor taken before a restore of the store is refused as a conflict, with the instruction to read again from the start.
- **Is a note finished.** Each note says whether it is settled: its window has closed, and nothing is still being transcribed, cleaned or downloaded. A segment whose step failed waits for a person and not for work, so it does not keep its note unsettled. Neither does a segment that shows "Kept, no text", which is a final state on this device (section 5). A settled note can still gain a late capture, or text that another device makes, and then it appears in `knot changes` again. Settling by time alone writes nothing, so an unsettled note carries the time at which it will settle if nothing else happens, or no time while work still runs, and an agent reads it again then. Each segment carries its state, in the six names of section 5 or as made by a newer Knot, where its text came from and its revision.
- **Is the store current.** Every result says whether Knot is running, whether sync is on, and when it last synced. Text output adds one line on standard error when the store may be behind. That is information, never an error.
- **Export.** The command does not download. If recordings or drawings are still on another device, it writes nothing and says so. `--skip-missing` exports the rest, with a list of what is missing.
- **Errors.** Every error says what failed, the fix, whether a retry is safe and what was written, under a stable code. With `--json` it is one object on standard error. Exit codes: 0 done, 1 unexpected, 2 usage, 3 ID not found or ambiguous, 4 access off, 5 conflict, 6 store busy, 7 the store needs the owner, 8 incomplete.
- **Compatibility.** JSON output carries a schema number that changes only on a breaking change. A renamed flag or tool keeps working for one release, with a warning. A code never changes its meaning.
- A segment written this way is marked as coming from the command line or from MCP.
- A delete made through them can be undone for 30 days, like any other.

The MCP server offers the same operations as tools, except export. A capture made by an agent follows the append window unless the agent asks for a new note, and the tool makes it say which. While command-line access is off the server still answers, and each tool call fails with the reason.

## 11. Settings

This is the complete list.

- Append window, in minutes. Zero is off.
- Clean up transcripts, on or off. When cleanup is unavailable on the device, the row says why.
- English variant used for transcription. It follows the device region by default and falls back to US English.
- iCloud sync, on or off, with its status.
- Mac only: the hotkey, launch at login, and command-line access, which installs the `knot` command.
- Export all notes.
- Recently deleted.
- About: version, licence and source link. In test builds, a diagnostics export that holds no note text, an export of the store as it is, and a restore of a kept copy.

## 12. First run and permissions

- There is no account and no walkthrough. The first launch opens the capture surface.
- Knot asks for the microphone the first time you record.
- The speech model downloads in the background on first launch. A recording made before it arrives is transcribed when it does.
- On the Mac, the first launch asks you to choose a hotkey and shows tap versus hold once.
- On the iPhone, Settings explains how to assign Knot to the Action Button, because only the user can do that. If Live Activities are off, Settings says that recording from the Lock Screen will open Knot instead.
- The empty stream on first run says that sync is on and where its switch is. It can also carry up to three rows, each dismissible, on setting up the Action Button, a Lock Screen control and the Watch complication.

## 13. Accessibility, language and privacy

- The interface is in English. Strings live in a catalog so that other languages can follow.
- VoiceOver announces when a recording starts and stops, and stays silent while it runs. The text is read afterwards, except on the Watch, which has none. New text arriving never moves focus, and focus returns to where it was when a surface closes. Every segment action can be reached from the keyboard on the Mac and the iPad. Each capture path is checked with VoiceOver at its milestone.
- Every control has a VoiceOver label and action. Text scales with Dynamic Type up to the largest sizes. The Mac and iPad are fully usable from the keyboard. Reduce Motion is respected.
- There is no account, no server and no analytics. The one third-party library, GRDB, is an on-device database layer that makes no network calls. The only network use is iCloud sync and Apple's own model downloads.
- Logs and diagnostics hold IDs, categories and timings. They never hold note text, transcripts or audio.

## 14. Speed and durability targets

These are first targets, set without measurements. The spikes and WP-42 calibrate them.

| Moment | Target |
|---|---|
| Mac: key release of a tap to a panel that accepts typing | 100 ms |
| Mac: the 250 ms mark of a hold to a live microphone | 150 ms |
| iPhone: icon tap to accepting keystrokes, warm | 300 ms |
| iPhone: icon tap to accepting keystrokes, cold | 1 s |
| iPhone: Action Button to a live microphone | 1 s |
| Watch: complication tap to a live microphone, warm | 700 ms |
| Watch: complication tap to a live microphone, cold | 1.5 s |
| Watch: stop of a 30 s recording to its transcript on the iPhone, phone nearby | 60 s |
| Typed text on disk after the last keystroke | 150 ms |
| Audio lost if the app is killed while recording | at most 1 s |
| Transcript ready for a 60 s recording on iPhone 17 Pro | 15 s |
| Search results in a stream of 10,000 notes | 50 ms |
| A capture's first write while a restore from iCloud is being applied | 50 ms |
| Ink on disk after the end of a stroke | 500 ms |
| A note of 200 segments, opened | 100 ms |
| Lost on a sudden power cut | at most the last second of typing and the last two seconds of audio |

Each target is measured over at least 20 runs and reported as a median and a 95th percentile, with the device's state written down: cold means after a restart, and warm means the app was open in the last minute. A target that starts before Knot's process exists, such as an icon tap or the Action Button, is timed from outside the app, by the test runner or from a screen recording at a sitting. The store of 10,000 notes holds 20,000 segments in the mix that a year of use would give: mostly short typed lines, a quarter recordings, a few drawings and a few notes of 200 segments. WP-42 also sets and measures first budgets for the waits a person sees: cleanup, conversion after a recording, text arriving in the Mac panel, and export.

## 15. Not in v1

- Photo and video capture.
- Languages other than English.
- Cleanup through a cloud API or Apple's Private Cloud Compute.
- A mirror folder, Obsidian integration, daily notes.
- Folders, tags, links, templates, pins and archive.
- Sharing notes with other people.
- Typing into other apps (system-wide dictation).
- The purchase flow for paid sync. Only the gate exists.
- A share extension, Mac widgets and controls, CarPlay, visionOS.
- Note text on the Watch, and typing there. The Watch is a capture device only.
- Merging notes, splitting a note at a point, and moving a segment into another existing note. Moving one segment to a note of its own is in v1 (section 7).
- Selecting several segments at once.

## 16. Assumptions

Paolo answered every assumption in this section on 2026-11-19, at gate G0 of PLAN.md. A1, A4 and A11 had been confirmed the day before. They are decisions D28, D27 and D25 in PLAN.md.

- He confirmed 33 of the 34 as written. They are decisions now, and their marks are gone from the text.
- He changed one, A6. The table gives his words, and section 6 follows them.
- He first changed A27 as well, and later the same day he dropped that change from v1, so A27 is among the 33. TODOS.md carries what he had asked for.
- He confirmed A35 for v1 and said that cleanup will do more later. TODOS.md carries that.

Applying his changes to A6 and A27 took a reading of each, A38 and A39. He answered both the same day: A38 is now part of A6, and A39 went with his change to A27. No assumption is left open.

### Answered on 2026-11-19

| ID | Rule | Section | Change later | Answer |
|---|---|---|---|---|
| A2 | A late capture is placed by its timestamps, and existing notes are never regrouped. | 3 | Costly | Confirmed |
| A3 | Notes created on two offline devices are not merged automatically. | 3 | Costly | Confirmed |
| A5 | A recording stops after 30 minutes. | 4.2 | Cheap | Confirmed |
| A6 | The watch is a capture device only. It shows no note content, and it has no stream and no typing. It has one screen, the record control, with no list of recordings. | 6 | Cheap | Changed. His words: "Watch doesn't show content, it's only a capture device." Later the same day, on what the Watch shows: "Watch: only record button". |
| A7 | Deleted items stay recoverable for 30 days. | 7 | Cheap | Confirmed |
| A8 | "Remove recording" keeps the text and deletes the audio. | 7 | Cheap | Confirmed |
| A9 | When the same text was edited on two devices, both versions are kept. | 9 | Costly | Confirmed |
| A10 | A title is generated only when a note's first segment is a recording. | 5 | Cheap | Confirmed |
| A12 | Widgets are launchers and never show note text. | 6 | Cheap | Confirmed |
| A13 | On the Mac, Knot lives in the menu bar and shows a Dock icon only while its window is open. | 6 | Cheap | Confirmed |
| A14 | A tap-started recording stopped within one second of its start is discarded as an accidental press, measured between the two presses. Hold-to-record is exempt. | 4.2 | Cheap | Confirmed |
| A15 | Stream order, late captures, emptied notes and recovered drafts follow rules 9 to 12. | 3 | Costly | Confirmed |
| A16 | On the Mac the microphone opens at the 250 ms mark of a hold, never on a tap. Listening from key-down is the alternative if first words get clipped. | 6 | Cheap | Confirmed |
| A17 | A typed capture starts at its first keystroke, and holding the hotkey while typing starts a recording as the next segment. | 3 | Costly | Confirmed |
| A18 | Sync is on by default when the device is signed in to iCloud. | 9 | Cheap | Confirmed |
| A19 | The device that made a recording processes it, and Retry on another device takes it over. | 5 | Costly | Confirmed |
| A20 | Knot's own text never conflicts with the user's: edited beats cleaned beats raw. | 9 | Costly | Confirmed |
| A21 | Titles keep the later edit; a deleted note stays deleted; a segment added to it after the delete moves to a new note. | 9 | Costly | Confirmed |
| A22 | The append window, cleanup switch and English variant sync; the hotkey, launch at login and the sync switch do not. | 9 | Cheap | Confirmed |
| A23 | The window ignores deleted captures, and the hotkey must be a key with a modifier or a function key. | 3, 6 | Cheap | Confirmed |
| A24 | What Knot does when a capture cannot start or cannot be saved follows section 4.4. | 4.4 | Cheap | Confirmed |
| A25 | One capture is open at a time on a device, and a running recording blocks typing and Pencil. | 3 | Costly | Confirmed |
| A26 | If the notes are removed from iCloud, the device keeps them and asks before uploading again. | 9 | Cheap | Confirmed |
| A27 | A note is a stack of segments, each edited on its own. A selection does not cross segments, and new text enters through the capture field. | 7 | Costly | Confirmed as first drafted. He first asked for more: "It should be possible to select multiple segments at once." Later the same day he dropped it for now: "Segments: drop multi-segment selection for now" and "Moving takes one segment at a time for now." TODOS.md carries it. |
| A28 | A finished drawing is not reopened. Writing more starts a new ink segment. | 4.3 | Costly | Confirmed |
| A29 | The first-run stream says that sync is on, and may carry up to three dismissible setup rows. | 12 | Cheap | Confirmed |
| A30 | The Mac panel and window have a microphone control beside the hotkey. | 6 | Cheap | Confirmed |
| A31 | A capture made by an agent follows the append window unless it asks for a new note. | 10 | Cheap | Confirmed |
| A32 | The store keeps a change counter and a revision for each segment, and the command line shows both. | 10 | Costly | Confirmed |
| A33 | Text replaced through the command line is kept for 30 days and can be restored. | 10 | Costly | Confirmed |
| A34 | A note is settled when its window has closed and nothing is pending. | 10 | Cheap | Confirmed |
| A35 | Cleanup leaves spoken self-corrections and numbers as they were, and a generated title uses only words from the note. | 5 | Cheap | Confirmed for v1. His words: "Later we'll expand cleanup abilities." |
| A36 | Knot has one window on the iPad. | 6 | Cheap | Confirmed |
| A37 | A segment can be moved to its own note, with undo at once and no merging. The window follows the most recent capture into its new note. | 3, 7 | Costly | Confirmed |

"Costly" means the rule shapes the data model, the sync rules or the contracts that WP-02 fixes, so changing it after WP-02 means rework in several packages. Each costly one has an example below, so that it can be checked by reading what would happen.

- **A2.** At 09:58 you type a line on the iPhone. At 10:00 you record on the Watch, away from the phone. At 10:02 you type on the Mac. The recording reaches the phone at 11:00. It joins the 09:58 note as its second segment, because it started two minutes after that line ended. It does not join the 10:02 note. Had there been no 09:58 line, it would be its own note dated 10:00.
- **A3.** On a flight you type a line on the iPhone at 14:00 and another on the iPad at 14:02, both offline. After landing you have two notes, one from each device. Knot does not join them, although they are two minutes apart.
- **A9.** You fix a typo in a segment on the Mac while the iPhone is offline, and you reword the same segment on the iPhone. After they sync, the note shows both versions one after the other, the second marked as a conflict. You delete the one you do not want.
- **A15.** You edit yesterday's note, and it stays where it was in the stream. A watch recording from yesterday that arrives today appears under yesterday's time, not at the top, so you find it by its time or by search.
- **A17.** You open the Mac panel at 10:00 and leave it empty until 10:07, then type. The line starts a new note, because the capture began at 10:07, more than five minutes after the previous one ended. Opening the panel did not count.
- **A19.** You record on the iPhone and close Knot before the transcript is ready. On the Mac the segment shows as pending and is not transcribed there, although the recording has synced. It becomes text when the iPhone finishes, or when you press Retry on the Mac, which moves the work there.
- **A20.** A recording is being cleaned on the iPhone while you correct a word in its raw transcript on the Mac. Your correction stays. The cleaned text does not replace it, and no conflict copy appears.
- **A21.** You delete a note on the Mac at 09:00. The iPhone, offline, appends a recording to that note at 09:03. After sync the note stays deleted, and the recording appears as a new note dated 09:03.
- **A27.** You open a note that holds a typed line and a recording. You drag a selection from the typed line: it stops at the end of that line and does not run into the recording's text. To copy everything, you use Copy note.
- **A28.** You sketch on the iPad and end the capture. A minute later you want to add an arrow, so you draw again. The arrow is a second sketch in the same note, below the first.
- **A32.** Your agent last read the store at cursor 1840. An hour later a Watch recording from this morning arrives and joins a note from this morning. `knot changes --after 1840` returns that note, although nothing about its time is new.
- **A33.** An agent replaces a segment's text with a summary. The next day you want your own words back: `knot restore` on that segment returns them.
- **A25.** You are typing in the capture surface on the iPhone and press the Action Button. The typed line is saved as it stands, and the recording becomes the next segment of the same note. While the recording runs, the text field does not accept typing.
- **A37.** At 10:00 you record a thought about the roof. At 10:03 you type "buy stamps", and it joins the same note. You open the note and choose "Move to its own note" on that line. It becomes a note of its own dated 10:03, just above the roof note in the stream. At 10:05 you record again, and the recording joins the stamps note, because that line is now the most recent capture. To start afresh you would press "New note".

## 17. Where Knot sits

Research on 2026-11-18 found typed capture crowded and three gaps that this spec aims at.

- **Crowded:** Drafts covers all four devices and every entry point. Apple Notes is free and owns the Pencil Lock Screen gesture. Obsidian shipped its own Quick Capture in October 2026. Capture, by Sir Studio, is the closest existing product: typing, voice and photo on every Apple device, handing notes off to other apps.
- **Gap, the Watch:** Apple's Notes on the watch cannot append, and its dictation stops after one to two minutes. Several 2026 watch apps claim on-device transcription, and none of those claims is tested. The gap is proven delivery and accuracy, not an absence of competitors.
- **Gap, losing nothing:** no competitor promises it, and some document ways to lose a capture.
- **Gap, three inputs in one calm tool:** nobody combines typing, voice and ink behind one stream.

Apple absorbs more of this category each year, so Knot has to win on feel and reliability, not on features.
