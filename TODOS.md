# TODOS

Items deferred from Knot v1 by the plan review of 2026-11-19, and by the owner's answers on the assumptions that day.

## Notes

### Tap a word to play from there

**What:** In a voice segment, tapping a word starts playback at that word.

**Why:** Checking one doubtful word should not mean scrubbing through a whole recording.

**Context:** The transcriber already returns a time range for each stretch of text, and v1 does not store them. This needs the ranges stored with the segment (a schema change), a tappable transcript view, and playback from an offset. Start with the transcriber output in KnotSpeech and the voice segment view in KnotUI.

**Effort:** M
**Priority:** P3
**Depends on:** Knot v1 (WP-13, WP-21).

### Transcribe old recordings again

**What:** When a better or a second speech engine arrives, run it over recordings already stored.

**Why:** Recordings made in a language v1 does not transcribe, or transcribed badly, should benefit from later engines.

**Context:** v1 stores which engine, locale and OS build produced each transcript, and keeps every recording. Running again needs transcript versions, because the raw transcript is never modified today. It also needs a rule that never overwrites text the user edited, and a trigger. The plan review deferred it for those reasons.

**Effort:** M
**Priority:** P2
**Depends on:** A second engine or language.

### Import an export back into Knot

**What:** Read a folder that "Export everything" wrote and rebuild its notes, recordings and drawings in the store.

**Why:** Export is the one copy of the stream that does not depend on iCloud or on a device backup. Without import it can be read but not restored.

**Context:** v1 protects the stream three ways: device backups and Time Machine include the store, iCloud restores it when sync is on, and Knot keeps a copy of the database before each migration. The outside reviewer asked for a full backup-and-restore path through export, and the review deferred the import half. It needs the export to carry IDs and timestamps for every segment (the front matter has the note's today), and a rule for notes that already exist. Start with KnotExport and the `knot` command.

**Effort:** M
**Priority:** P2
**Depends on:** Knot v1 (WP-20, WP-34).

### Storage management for recordings

**What:** Show how much space recordings take, and let a device give up its local copy of a recording that is safely in iCloud.

**Why:** Recordings are kept until deleted. At a few voice notes a day that is a few gigabytes a year on the device that made them.

**Context:** v1 can remove one recording at a time and keeps its text. Each device already downloads other devices' recordings only on demand, so the missing half is offloading a device's own. It needs the attachment to be confirmed in iCloud first, and a setting or an automatic rule. Start with `AssetStore` and `AssetFetcher`.

**Effort:** M
**Priority:** P3
**Depends on:** WP-16.

### Reopen a finished drawing

**What:** On a Pencil device, open a finished ink segment and add or erase strokes.

**Why:** Adding an arrow to a sketch should not make a second sketch.

**Pros:** Ink behaves like typed and spoken segments, which can be edited in place.

**Cons:** A drawing edited on two devices needs a conflict rule for its file, which v1's sync does not have. Recognition must run again.

**Context:** In v1 a finished drawing is read-only on every device, and writing more starts a new ink segment in the same note (product spec §4.3, assumption A28). Reopening needs a transition from ready back to drawing in the ink state machine, a new file version per edit, and a sync rule for two edits of one drawing. Start with the ink reducer in KnotCore and the attachment rules in KnotSync.

**Effort:** M
**Priority:** P3
**Depends on:** WP-16, WP-18.

### Stop a recording that hears no speech

**What:** A recording started outside the app stops itself when it hears no speech for a set time, and is kept and marked.

**Why:** An accidental press on the Action Button or the Watch can record a room for 30 minutes.

**Pros:** Less junk, less battery, and no long recording of other people by accident.

**Cons:** A false stop loses what is said next, which breaks "nothing is lost". The Watch has no speech framework, so detection there is by level alone.

**Context:** The plan review decided against it for v1, because a deliberate pause looks the same as an accident. v1 instead makes a start unmistakable (the cues in product spec §4.5) and marks a recording with no recognised words as "kept, no text". Revisit with real counts of accidental recordings from the first weeks of use. Start with the recorder in KnotAudio.

**Effort:** M
**Priority:** P3
**Depends on:** Knot v1 in daily use.

### Take over a recording whose device is gone

**What:** A recording whose transcription belongs to a device that no longer exists is taken over by another device after a few days, without anyone asking.

**Why:** A lost or replaced phone should not leave recordings marked "being made elsewhere" for good.

**Pros:** Nothing waits on a device that will never return.

**Cons:** A device that was only away for a week would find its work taken, and two devices could then both transcribe. That needs the ownership generation of architecture §11 to be proven first.

**Context:** In v1 the person moves the work by hand with "move the work to this device", and a store restored onto a new phone gets a new device ID. The engineering review deferred the automatic rule, because it changes assumption A19. Start with the ownership rule in KnotSync and the job queue in KnotCapture.

**Effort:** S
**Priority:** P3
**Depends on:** WP-16 in daily use.

### Merge notes, and put a segment into another note

**What:** Join two notes into one, split a note at a point, and move a segment into a note that already exists.

**Why:** v1 repairs one kind of wrong grouping: a segment that joined a note it does not belong to can be moved to a note of its own. Two notes that should have been one cannot be joined, and a segment moved by mistake can be put back only at once in the app, or for 30 days from the command line.

**Pros:** Every grouping mistake becomes repairable, in both directions.

**Cons:** A move into an existing note needs a place in that note's order, a sync rule for two devices that move the same segment to different notes, and a choice of title when both notes have one.

**Context:** The owner accepted "Move to its own note" at the review gate of 2026-11-19 (product spec §7, assumption A37), and the keep-gate sitting counts how often it is used. v1 already changes a segment's note, records the note it left for 30 days, and merges that field in sync (architecture §4, §5 and §11). Start with the move operation in `NoteStore` and the merge rule in KnotSync.

**Effort:** M
**Priority:** P3
**Depends on:** Knot v1 (WP-10, WP-16), and the move counts from the keep-gate week.

### Select several segments at once

**What:** Select several segments of a note at once, as whole segments, to copy, share or delete them together, and to move them together into one new note.

**Why:** Taking a few segments out of a long note, or sending them somewhere, should not mean repeating the same action on each one.

**Pros:** Copy, share, delete and the move work on any part of a note in one action, and one undo puts it all back.

**Cons:** The store needs a delete and a restore of several segments in one transaction. The design needs a selected state for the note on every device. A move of several segments changes an operation the engineering review fixed.

**Context:** The owner asked for it on 2026-11-19 and dropped it from v1 the same day: "Segments: drop multi-segment selection for now" and "Moving takes one segment at a time for now." In v1 a selection does not cross from one segment into the next (product spec §7, assumption A27). A text selection that runs from one segment into the next needs the rich-text editor that decision D20 rules out, so this item selects whole segments. Moving several segments together into one new note would change the move operation of architecture §5. Start with `NoteStore` and the note's view model in KnotUI.

**Effort:** M
**Priority:** P3
**Depends on:** Knot v1 (WP-10, WP-21).

### Let cleanup do more

**What:** Widen what cleanup may change in a transcript after v1.

**Why:** The owner confirmed v1's narrow cleanup on 2026-11-19 and said in the same answer: "Later we'll expand cleanup abilities."

**Context:** In v1, cleanup removes fillers, repeated words and restarts, adds punctuation and structure, and changes nothing else. It leaves a spoken self-correction as it was said and numbers as they were transcribed, and a generated title uses only words from the note (product spec §5, assumption A35). A guard checks every result against the raw transcript and discards one that changes the words (architecture §9). The two things A35 names, self-corrections and numbers, are the first candidates, and the owner has not yet said which abilities he wants. Each one loosens the guard, so it needs its own cases in the cleanup evaluation set and a way to see the original, which "Show original" already gives. Start with the fidelity guard and the cleanup instructions in KnotCleanup.

**Effort:** M
**Priority:** P2
**Depends on:** Knot v1 in daily use, and the cleanup evaluation of WP-04 and WP-14.

## System integration

### Several windows on the iPad

**What:** Let Knot open more than one window on an iPad, each with its own note.

**Why:** An iPad user may want a note beside the stream, or two notes side by side.

**Context:** v1 has one window on the iPad (product spec §6, assumption A36), because one capture is open at a time on a device and two capture fields would have to share that rule. It needs a rule for a second capture surface, and scene support in the app shell. Start with the capture engine's session rules.

**Effort:** S
**Priority:** P3
**Depends on:** Knot v1 (WP-30, WP-35).

### Spotlight finds notes

**What:** Index note text on the device so system search finds notes.

**Why:** The owner likes apps that use what the operating system offers, and search is where people look first.

**Context:** v1 already exposes notes to Shortcuts through an entity query. Indexing goes further: note text enters the system index and shows in Spotlight results on an unlocked device. That is a privacy decision for the owner, which is why the review deferred it. Start with the note entity in KnotIntents.

**Effort:** S
**Priority:** P3
**Depends on:** Knot v1 (WP-19).

### A "note ready" hook on the Mac

**What:** When a note is finished, the Mac app runs a Shortcut or a command the user chose.

**Why:** Agents get each capture pushed to them, instead of polling with `knot list --since`.

**Context:** v1 gives agents pull access through the `knot` command and the MCP server. Push needs a new setting, and a sandboxed app cannot run arbitrary commands freely, so the design has to be worked out. Running a Shortcut is the likely route. Start with the processing queue's "ready" transition and the result of spike SP-3.

**Effort:** M
**Priority:** P2
**Depends on:** WP-34, SP-3.

### Handoff between devices

**What:** A note open on the iPhone can be continued on the Mac, and the other way round.

**Why:** Starting a thought on one device and finishing it on another is the point of one stream.

**Context:** This needs sync to be on and stable, an activity type per note, and continuation handling in each app. It adds no visible control.

**Effort:** S
**Priority:** P3
**Depends on:** WP-16.

### "Add to Knot" from other apps

**What:** A Services menu item on the Mac and a share sheet action on iPhone and iPad that send selected text to Knot.

**Why:** Capturing something you are reading should not need a copy, a hotkey and a paste.

**Context:** The product spec lists a share extension as not in v1. It needs a new extension target on iOS, which writes an inbox item for the app to ingest, as architecture §6 already allows. The Mac Services item is smaller.

**Effort:** M
**Priority:** P3
**Depends on:** Knot v1 (WP-15 for the inbox).

## Build process

### Batch the merge queue

**What:** Let the orchestrator test several ready pull requests together and merge them on one green run.

**Why:** A serial queue makes a pull request wait behind every one ahead of it.

**Context:** The engineering review chose a serial queue: one candidate at a time, each result bound to a base, a head and a tree (architecture §18). It estimated about 19 hours of gate time for about 75 merges, which is not the bottleneck. Batching leaves commits on `main` that were never tested alone, so it is worth it only if the median wait passes two hours. Start with `scripts/status.sh` and the queue rules.

**Effort:** S
**Priority:** P3
**Depends on:** Measured queue waits from wave 2.

### A separate account for agent builds

**What:** Run the implementer and reviewer threads, and the merge gate, under a second macOS account or in a virtual machine that holds no personal data and no signing identity.

**Why:** A pull request is code that runs on the owner's Mac. Today the plan keeps the owner's notes off the build Mac and reads an outside pull request before building it. A separate account would make that a wall and not a rule.

**Context:** The outside reviewer asked for it in the engineering review. It was deferred because the build has no outside contributors yet, and because signing, simulators and the agent tools would all have to be set up twice. Revisit when the first outside pull request arrives.

**Effort:** M
**Priority:** P2
**Depends on:** An outside contributor, or a decision to keep real notes on the build Mac.

## Completed
