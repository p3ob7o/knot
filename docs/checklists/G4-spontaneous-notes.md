# Ten spontaneous notes

Gate G4, wave 0. About 15 minutes.

Ten voice notes in your own words: five on the iPhone, five on the Watch. They show Knot's transcription and cleanup the way you really talk, which the read-aloud passages can't.

## Before you start

- Use Apple's **Voice Memos**, as for the [read-aloud script](G4-read-aloud.md).
- Talk the way you would to yourself. Don't read from notes, and don't tidy your speech: ums, restarts and changes of mind are what the tests need.
- Make the content up, or keep it harmless. Nothing you'd mind seeing written down.
- The copies the build uses, and the transcripts made from them, stay on the build Mac, in the folder that `KNOT_LOCAL_FIXTURES` names. They are never committed, logged or shown in a pull request. The originals stay in Voice Memos on your devices, and in iCloud if Voice Memos syncs, until you delete them: the last step below suggests it.
- Give each recording the name shown, without `.m4a`, the same way as before.

## On the iPhone

### Note 1

`note-01-iphone`

A to-do list for tomorrow: four or five things, said the way you'd say them to yourself.

### Note 2

`note-02-iphone`

A plan with a day and a time in it: when and where to meet someone.

### Note 3

`note-03-iphone`

Something with an amount of money and a person's name. An invented name is fine.

### Note 4

`note-04-iphone`

Change your mind once while you speak. Say something, correct it ("no, wait…"), and carry on.

### Note 5

`note-05-iphone`

A longer thought, about two minutes, on anything you're turning over.

## On the Watch

### Note 6

`note-06-watch`

A quick reminder, under five seconds.

### Note 7

`note-07-watch`

Start it, then lower your arm and keep talking for half a minute or so, as you would while walking.

### Note 8

`note-08-watch`

Somewhere noisier: the kitchen with the tap running, or outside near traffic.

### Note 9

`note-09-watch`

A question to yourself, and a "don't forget to…" with a "not" or "don't" in it.

### Note 10

`note-10-watch`

About a minute on a plan for the weekend, with at least one date and one number in it.

## Move the files to the Mac

All 30 recordings go to the build Mac: the 20 read-aloud passages and these 10 notes.

1. On the build Mac, open **Voice Memos**. Your iPhone and Watch recordings appear there if Voice Memos syncs through iCloud. If they don't, AirDrop them from the iPhone instead: open a recording, tap Share, choose the Mac.
2. Check that every recording carries its name, from `read-aloud-01-iphone` to `note-10-watch`.
3. Open Terminal and run `open "$KNOT_LOCAL_FIXTURES"`. The folder opens in Finder. If Terminal says the folder doesn't exist, or the variable is empty, ask the orchestrator for it.
4. Drag the 30 recordings into that folder. Each becomes a file ending in `.m4a`.
5. In Terminal, run `ls "$KNOT_LOCAL_FIXTURES"`. It should list 30 files, from `note-01-iphone.m4a` to `read-aloud-10-watch.m4a`.
6. Tell the orchestrator the recordings are in place.
7. Once the 30 files are in the folder, you can delete the originals from Voice Memos on the iPhone, and then empty its Recently Deleted. With iCloud sync on, that removes them from your other devices and from iCloud too. The build only needs the copies on the build Mac.

Don't put the files anywhere else: not in a worktree, not in iCloud Drive, not in `~/Documents` or `~/Desktop`.
