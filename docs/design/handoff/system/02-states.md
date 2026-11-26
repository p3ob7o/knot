# States

Recording, pending and failed must read at a glance and still feel calm. Every state below has a word, a glyph and, where it is an outcome, a haptic (see *Motion, haptics and sound*). Colour is never the only signal.

## The record control's phases

| Phase | What it looks like | What it means |
| --- | --- | --- |
| Idle | `mic` in `label` on glass | Tap (or press the Action Button) to record |
| Starting | `mic.fill` in `record` on glass | The microphone is opening; under half a second |
| Live | `record` fill, `stop.fill` in `on-record`; the timer beside it in `label` | Recording. The control that started it stops it |
| Stopping | as Live, glyph at half strength, timer frozen | Closing the file |
| Saved | `checkmark` in `label` on glass, one second | On disk; then back to Idle |
| Couldn't start | `mic.slash` in `label-secondary`; a notice says why | Nothing recorded |

- Morph from Idle to Live with `.snappy`; never pulse, glow or animate the red.
- While live, typing waits: the field steps aside for the live segment, whose words appear in `label-secondary` and settle into `label` as they become final ("Recording. Typing waits until you stop.").
- A stop within one second discards the recording: the surface says "Too short. Nothing was kept." and nothing is added.
- A call, or the 30-minute limit, stops a recording and saves it: "Recording stopped at 30 minutes and was saved."

## A voice segment's six states

Named for what you can do. The state line sits at the segment's foot, in `ios-footnote`.

| State | Line | Glyph | Actions |
| --- | --- | --- | --- |
| Saved on the Watch | "Saved on the Watch" | `applewatch` | none; no player yet |
| Saved, text on its way | "Saved, text on its way" | `ellipsis.circle` | play |
| Saved, text being made elsewhere | "Saved, text being made on the Mac" | the device's glyph | play; "Make it here" |
| Ready | no line | none | everything |
| Needs you | "Needs you" in `attention`, semibold | `exclamationmark.triangle.fill` in `attention` | "Retry"; play |
| Kept, no text | "Kept, no text" | none | play, view, share, delete |

- "Kept, no text" is a final state, not an error: no colour, no glyph, no retry.
- Only "Needs you" uses `attention`. Pending states use `label-secondary`.

## Marks on a segment

- **From the command line or an assistant:** `apple.terminal` + "Added from the command line" (or "Added by an assistant").
- **Recording missing:** `waveform.slash` + "Recording missing"; the text stays.
- **Made by a newer Knot:** `arrow.down.circle` + "Made by a newer Knot." and an "Update" button (opens the App Store page).
- **Arrived late:** an 8 pt `accent` dot + "Arrived from the Watch · 9:52", until the note is next opened.

## In the stream

A row shows at most one state mark, at its trailing edge: an `accent` dot (arrived, unseen), `ellipsis.circle` in `label-secondary` (pending) or `exclamationmark.triangle.fill` in `attention` (needs you). Failed wins over pending, pending over arrived.

## Notices

Inline, in the content layer, at the top of the note or stream they concern, on `fill-tertiary` with `radius-lg`: a glyph, one or two sentences in `ios-callout`, at most two `.bordered` small buttons, and a close button only when the notice can be dismissed without acting.

| Situation | Glyph | Sentence | Actions |
| --- | --- | --- | --- |
| Note deleted on another device | `trash` | "This note was deleted on another device." | Restore |
| Microphone refused (a surface problem) | `mic.slash` in `attention` | "Knot can't use the microphone. You can allow it in Settings." | Open Settings; close |
| Edit conflict | `arrow.triangle.2.circlepath` | "This text changed on another device while you edited it." | Keep mine, Keep the other |
| Notes can't be read | `exclamationmark.icloud` in `attention` | "Knot can't read your notes. Nothing was deleted. New captures are kept safe and appear when your notes open again." | none |
| Captures arrived | `tray.and.arrow.down` | "2 captures arrived from the Watch." | Show; close |
| Stopped at the limit | `stop.fill` | "Recording stopped at 30 minutes and was saved." | close |
| Settings can't be read | none | "Settings can't be read right now." as the Form's footer; rows disabled | none |

- **The undo capsule** is the one transient element: a glass capsule above the bottom toolbar, "Segment deleted" + Undo, for six seconds or until the next action. Shake to undo and ⌘Z do the same. Deleted segments stay in Recently deleted for 30 days.
- Never use an alert for any of these. Use an alert only to confirm emptying Recently deleted.

## First run

No walkthrough, account or permission screen up front. Knot opens on the capture surface; the microphone permission is asked the first time someone records. The empty stream reads "No notes yet." with "iCloud sync is on." under it, and can carry up to three setup rows (Record with the Action Button, Add a Lock Screen control, Add the Watch complication), each dismissible with `xmark` and gone for good once done or dismissed.
