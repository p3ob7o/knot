# SP-1 · the sitting on the iPhone

Twelve rows, about 15 minutes after the setup, on the iPhone 17 Pro with Knot SP-1 installed (`Spikes/SP-1/build.sh device`). The rows are ordered so that each one leaves the phone where the next one starts: first unlocked, then locked with the app quit, then the two settings that are turned off, and the restart last.

Every row is read from the app's log afterwards, so you only need to do the steps and note what you **see**. Write one word per row (yes, no, or what happened) in the last column, or say it to the orchestrator.

**What to say when recording.** Count from one to ten, clearly. Nothing else. The app keeps no text, only the number of words, so ten words means transcription worked.

**Latency.** For rows 2 and 3, run a screen recording from Control Center first, with its microphone off. Afterwards, note the time from the press to the orange microphone dot, or to the Live Activity if the dot is not in the recording.

## Setup, about 5 minutes, unlocked

1. Open Knot SP-1. Tap **Ask for the microphone** and allow it.
2. Tap **Install the speech model**. Wait until "Speech assets" reads `installed` (pull to refresh).
3. Check that "Cleanup model" reads `available`. If not, turn on Apple Intelligence and wait for its model.
4. Check that "Work after stop" is `longRunningIntent`.
5. Settings → Action Button → Controls → **SP-1 Toggle**.
6. Lock Screen: long-press, Customise, Lock Screen, replace one bottom control with **SP-1 Toggle**.
7. Control Center: add **SP-1 Press** and **SP-1 Probe**.
8. Back in the app, tap **Clear the log**.

## The rows

| # | State before | Do | Look for | Seen |
|---|---|---|---|---|
| 1 | Unlocked, app in front | Tap **Record in the app**, count to ten, tap **Stop in the app**. | The log shows `recorder.first-buffer`, then `transcribe.done` with words=10 and `clean.done`. This proves the recorder and the models before the hard rows. | |
| 2 | Unlocked, app in the background (swipe home), screen recording on | Press the **Action Button**, count to ten, press it again. | Recording starts without the app opening. A Live Activity with a timer appears. The second press stops it and the activity shows "Saved". Note the press-to-dot time. | |
| 3 | **Locked**, app **quit** (swipe it away in the app switcher, then lock), screen recording on, wait 10 s | Press the **Action Button**, count to ten, tap **Stop** on the Live Activity. | Does it record **without Face ID**? Does the Live Activity appear on the Lock Screen? Does Stop work from the Lock Screen? Note the press-to-dot time. | |
| 4 | Locked, app quit, wait 10 s | Tap the **SP-1 Toggle** Lock Screen control, count to ten, tap it again. | Does the control show "Recording" while it records, and stop it on the second tap? | |
| 5 | Locked, app quit | Open Control Center on the Lock Screen. Tap **SP-1 Probe**. Then tap **SP-1 Press**, count to ten, tap **SP-1 Press** again. | Any error message from either control. Whether SP-1 Press records. | |
| 6 | Unlock, open the app, set "Work after stop" to **continuedProcessing**, quit the app, lock | Press the **Action Button**, count to ten, press it again. | Whether a system progress banner or activity appears after stop. | |
| 7 | Unlock, open the app, set it to **backgroundTask**, quit, lock | Press the **Action Button**, count to ten, press it again. Then unlock, open the app and set it back to **longRunningIntent**. | Nothing to see on screen. The log answers. | |
| 8 | Locked, app quit, wait 10 s | Press the **Action Button twice quickly**, about half a second apart. Wait 5 s. If it records, press once more to stop. | Exactly one recording, or none. No error, no second Live Activity. | |
| 9 | Unlocked | Press the **Action Button** to start, count to five, then open the app switcher and **swipe Knot SP-1 away** while it records. Wait 10 s, lock, press the **Action Button** again, count to ten, press again. | After the swipe: does the Live Activity stay, go stale, or vanish? After the next press: a new recording starts at once. | |
| 10 | Settings → Knot SP-1 → **Live Activities off**. Lock, wait 10 s | Press the **Action Button**. | Face ID prompt? Does Knot SP-1 open and record? Any message? Then stop it in the app and turn Live Activities back on. | |
| 11 | Settings → Privacy & Security → Microphone → **Knot SP-1 off**. Quit the app, lock | Press the **Action Button**. | Face ID prompt? Does Knot SP-1 open? What does it say? Then turn the microphone back on. | |
| 12 | **Restart the iPhone. Do not unlock it.** | On the Lock Screen, press the **Action Button**, wait 10 s, press it again. Then unlock, open Knot SP-1. | Anything at all before the unlock: a Live Activity, a message, nothing? | |

## After the last row

In the app, tap **Share the log** and AirDrop `events.jsonl` to the build Mac, into `~/knot-build/sp1/`. It holds no text, only events, timings and counts. The recordings stay on the phone, and deleting the app removes them.

Tell the orchestrator the press-to-dot times of rows 2 and 3, and the "Seen" column. The orchestrator resumes the SP-1 thread with both, and the report follows.

## What each row answers

| # | Question of the brief |
|---|---|
| 1 | Baseline: the recorder and both models work on this phone. |
| 2 | Action Button, unlocked, app running: start, stop, the Live Activity, latency warm. |
| 3 | Action Button, locked, app terminated: the open question of §20. Latency cold. The Live Activity's Stop from the Lock Screen. Transcription and cleanup after stop with `LongRunningIntent.performBackgroundTask`, locked. File protection at a locked press. |
| 4 | Lock Screen control, locked, terminated. Whether the toggle's intent carries the value the control showed (the log's `shownValue`). |
| 5 | The process each intent runs in, pinned and not pinned. |
| 6 | `BGContinuedProcessingTask` after a locked press. |
| 7 | `beginBackgroundTask` after a locked press. |
| 8 | A double press on a cold start. |
| 9 | A press after a force quit during a recording: recovery and the stale Live Activity. |
| 10 | Live Activities off: the feedback flow and the "open the app" rule. |
| 11 | Microphone permission missing: the same. |
| 12 | A press after a restart, before the first unlock, and which files and defaults can be read then. |

The report adds the rows that the log alone answers: which mechanism finished the work after stop, cleanup in the background, and the protection class each step needed.
