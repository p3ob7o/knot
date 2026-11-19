# SP-5 · the sitting at the Mac

Nine rows and one that runs only if an earlier row fails, about 15 minutes after a 3-minute setup, on the build Mac with Knot SP-5 built by `Spikes/SP-5/build.sh mac`. The app measures everything itself and shows it in its window and its panel. You do the steps, look, and say one word per row (yes, no, or what happened) to the orchestrator. Nothing needs typing.

The rows go from the plain desktop to a full-screen app, and from the default settings to the alternatives, so each row starts where the last one left off.

**What to say on a hold.** Start saying "one, two, three" the moment you press, not after. That is how a person speaks when they hold a key to dictate, and it is what clips.

**The microphone indicator** is the orange dot in the menu bar, near Control Center. The app opens the microphone only for a hold, never at launch.

## Setup, about 3 minutes

1. In Finder, open `~/knot-build/sp5/Knot SP-5.app`. Its window opens and "SP-5" appears in the menu bar.
2. Under **This app**: "Sandboxed" reads `entitlement true, in a container: yes`. "Input device" names a device. If it reads `none`, connect a microphone, preferably a wired or USB one, and click **Read again**. A Mac Studio has no built-in microphone.
3. Click **Ask for the microphone** and allow it. "Microphone" reads `allowed` after **Read again**.
4. Click **Choose a key** and press a key with at least one modifier, one that nothing else on this Mac uses. The line above reads `registered …, exclusive (status 0)`. If it says another app holds the key, choose another.
5. Check the settings: Microphone opens **at the 250 ms mark**, Panel **B**, Key state stops a recording by **session state**, and the release toggle off.
6. Close the window with its red button. Knot SP-5 stays in the menu bar. Click any window of another app, such as Finder, so that app is in front.

## The rows

| # | Before | Do | Look for | Seen |
|---|---|---|---|---|
| 1 | Desktop, another app in front, window closed | **Tap** the key, type one letter, tap again. Ten times. | The panel appears each time with the cursor in its field, and the letter lands there. The menu bar keeps the other app's name: Knot did not take over. The orange dot never lights. | |
| 2 | The same | **Hold** the key and say "one, two, three" from the moment you press. Release after "three". Ten times. | The panel appears without taking the keyboard, shows "Listening", then "Saved", and hides after 4 s. The dot lights only after the panel appears and goes out at release. | |
| 3 | The same | Open the window (menu bar SP-5 → Open the SP-5 window). Click **Play the last hold**. | Is the first "one" whole, or cut? Then read under **Measurements**: "Hold: 250 ms mark → microphone live" and "Tap: release → panel ready", and count the rows marked `SPEECH AT OPEN`. Say the two medians and the count. | |
| 4 | Window open | Hold the key for four seconds in silence, then release. | In the newest row, the key-state line reads `session down, HID down, modifiers down` at 1, 2 and 3 s, and it stopped with `stop: released`. If it stopped by itself at 1 s with `stop: key state read up` while you held it, say which of the three read `up`. | |
| 5 | Window open | Tick **Ignore the key's release**. Hold for two seconds, release, and wait. | The recording stops by itself about a second after you let go, with `stop: key state read up`. | |
| 6 | Release still ignored | Set Key state to **off**. Hold two seconds and release: the recording goes on. Press **Esc**. Then hold one second, release, and tap the key once. | Esc stops it (`stop: Esc`). The tap stops the second one (`stop: pressed again`). Then untick the release toggle and set Key state back to **session state**. | |
| 7 | Close the window. Put another app in full screen (its green button), such as Safari | In the full-screen app: tap, type a letter, tap again. Then hold two seconds and release. | The panel shows over the full-screen app both times, the letter lands in it, and the screen stays in the full-screen Space. | |
| 8 | In the full-screen app | Reveal the menu bar (pointer to the top), SP-5 → Open the window, set Panel to **A**, close the window, return to the full-screen app. Tap, then hold. If A or B failed, do the same with **C**. Then repeat with **B** while the window stays **open** in its own Space. | Which of A, B and C show over the full-screen app, with the window closed and with it open. | |
| 9 | Leave full screen. Window open | Set Microphone opens to **at key-down**. Five holds saying "one, two, three" from the press, then five taps. Click **Play the last hold**. | The dot now lights on taps too, briefly: that is expected. Is the first "one" whole now? Read "Hold from key-down: key-down → live". Then set it back to **at the 250 ms mark**. | |
| 10 | Only if row 1 or 2 got no panel, or a hold never stopped at release | Click **Start the event tap** under Fallback. Allow Input Monitoring in System Settings if asked, then click it again. Three taps and three holds. | "Seen for the key" counts downs and ups as you press. Afterwards remove Knot SP-5 from Input Monitoring in System Settings. | |

**If you have a minute more:** with a password field focused in another app, so that "Secure input" reads `on` after **Read again**, tap and hold once. Say whether the panel came. Each row in the window also records whether secure input was on.

## After the last row

Quit from the menu bar (SP-5 → Quit Knot SP-5). The app keeps its log, with no text and no audio, in its container at `~/Library/Containers/com.p3ob7o.knot.dev/Data/Library/Application Support/SP5/events.jsonl`. The resumed SP-5 thread reads it for the report. The recordings were only in memory and are gone.

Tell the orchestrator the "Seen" column and the numbers from row 3. The orchestrator resumes the SP-5 thread with them.

## What each row answers

| # | Question of the brief |
|---|---|
| 1 | Press and release arrive in the sandbox, for a tap. The panel takes the keyboard without activating Knot. Tap latency, against the 100 ms target. |
| 2 | Press and release arrive for a hold. The panel shows without taking the keyboard. The microphone opens only for a hold. |
| 3 | Are first words clipped with the microphone opening at the mark. Mark-to-live latency, against the 150 ms target. |
| 4 | Can the key's state be read in the sandbox without Input Monitoring. |
| 5 | A missed release is caught by the key-state check. |
| 6 | A missed release with no key-state check: Esc, registered as a hot key only while recording, and a second press both stop it. |
| 7 | The panel over a full-screen app, as an accessory app. |
| 8 | Which panel variant it takes, and whether a regular app (window open) behaves the same. |
| 9 | Listening from key-down: whether it removes the clipping, and what it costs. |
| 10 | The fallback: whether a listen-only event tap gets press and release, and what asking for Input Monitoring looks like. |

The report adds what the log alone answers: delivery delays, how late the 250 ms timer fired, and whether any repeated presses arrived while a key was held.
