# SP-5 code half: the Mac hotkey, the panel and the key state

The code half of SP-5, 2026-11-19, on the build Mac: macOS 27.3 (26C5047e), Xcode 27.2 (27B52), the MacOSX 27.2 SDK. Its code is the spike app on the branch `spike/mac-hotkey`, in `Spikes/SP-5/`, at `6f2040d`, which is never merged. This note has two readers: WP-33, whose second pull request builds the hotkey and the panel, and the orchestrator, which keeps docs/architecture.md. No package waits for it.

No agent presses a key on the build Mac and none opens its microphone, and Mac UI tests cannot run there. So this note says what the SDK and a build can say. The rest is the owner's sitting, from `Spikes/SP-5/sitting.md` on the spike branch, about 15 minutes, and the report, `docs/spikes/SP-5.md`, follows it.

## In short

1. **Carbon's `RegisterEventHotKey` registers in a sandboxed build with no extra entitlement.** The spike app carries only `com.apple.security.app-sandbox` and `com.apple.security.device.audio-input`, runs in its container, and registers a key with modifiers and a function key alone, both with status 0. Whether a press and a release from the keyboard then arrive is the sitting's first two rows.
2. **Settings can tell that another app holds the key only when that app registered it exclusively.** Measured against a second sandboxed process: an exclusive registration over another app's shared one succeeds, and silences that app's key while Knot holds it. The header contradicts itself on this point, and the measurement follows the function's own comment.
3. **A tap is told from a hold by a strict timer at the 250 ms mark, and the release decides when the timer is late.** `DispatchQueue.main.asyncAfter` fired 10 ms late. A strict dispatch timer with no leeway fired 0.1 ms late. A release at or after 250 ms is a hold even when the timer has not run yet.
4. **The panel is an `NSPanel` with `nonactivatingPanel`, and the SDK offers one more collection behaviour made for it.** `canJoinAllApplications` (macOS 13) lets a window "join other apps' sets and full screen spaces when eligible" and is meant "for floating windows and system overlays". The sitting compares three variants over a full-screen app.
5. **Preparing the audio engine at key-down opens nothing, by the SDK's account.** `prepare()` preallocates, and the microphone indicator appears "any time the engine is running". Whether a tap ever lights the indicator is the sitting's first row.
6. **No call without a key press settles the key-state check.** With no key held, every reader says "up", whether or not the system lets the app see the key. It is a sitting row.
7. **Esc needs a hot key of its own during a recording.** A hold shows the panel without making it key, so Esc goes to the app in front. A global key monitor needs Accessibility, so the spike registers Esc as a Carbon hot key only while a recording runs.
8. **The local build answers the sitting.** It is signed ad hoc and sandboxed. A team-signed build changes nothing that SP-5 measures.

| Built | Result |
|---|---|
| `Spikes/SP-5/build.sh check`: Swift 6, complete concurrency checking, warnings as errors, `KNOT_SIGNING=local` | Builds clean. `codesign` reports `Signature=adhoc`, no team, and the entitlements `app-sandbox`, `device.audio-input` and `get-task-allow` |
| `Spikes/SP-5/build.sh selftest`: a holder process, then the self-test | Passes in 0.8 s and quits. No window, no panel on screen, no microphone, no activation. Quoted below. |

## Each question, and where it is answered

| Question | Where |
|---|---|
| Does a sandboxed build register a Carbon hot key with no extra entitlement? | Answered here: yes. |
| Do press and release from the keyboard arrive in that build? | Needs the sitting, rows 1 and 2. The handler and its parameters are proven here, with events sent to the app's own target. |
| What must the panel be to float over a full-screen app without taking focus? | Answered here, from the SDK: three candidates below. |
| Does the panel show over a full-screen app? | Needs the sitting, rows 7 and 8, with Knot as an accessory app and as a regular one. |
| How is a hold told from a tap at the 250 ms mark? | Answered here: the machine below, and 13 table cases that pass. |
| What does preparing the audio engine at key-down mean, without opening the microphone? | Answered here, from the SDK. That a tap never lights the indicator needs the sitting, row 1. |
| Are first words clipped when the microphone opens at the mark? | Needs the sitting, rows 2, 3 and 9. |
| Must Knot listen from key-down? | Needs the sitting: it follows rows 3 and 9. |
| Can the key's state be read once a second without Input Monitoring? | Needs the sitting, row 4. No call settles it without a press. |
| Does the hotkey need the listen-only event tap, and with it Input Monitoring? | Needs the sitting: it follows rows 1 and 2. What the tap would need is answered here. |
| Can Settings say that another app holds the key? | Answered here: only an exclusive registration. |
| Does the sitting need a team-signed build? | Answered here: no. |

## The hot key

The spike installs one Carbon handler on the application target for `kEventHotKeyPressed` and `kEventHotKeyReleased`, and reads the key's ID from `kEventParamDirectObject` and the event's time from `GetEventTime`. That time counts seconds since the system started, on the same clock as `CACurrentMediaTime` and as `AVAudioTime.seconds(forHostTime:)`, so the press, the mark and the first audio sample are timed against one another.

What the self-test measured, all in the sandboxed, ad hoc signed build, with keys built on F20, which no Apple keyboard has:

| Registration | Status |
|---|---|
| A key with modifiers | 0 |
| A function key with no modifier | 0 |
| The same key again, under a second ID, in the same process | -9878, `eventHotKeyExistsErr` |
| Exclusive, over the same process's shared registration | -9878 |
| Exclusive, over **another process's shared** registration | **0** |
| Exclusive, over another process's exclusive registration | -9878 |
| Shared, over another process's exclusive registration | 0 |

The header says two things. The `HotKeyOptions` comment: "An error is returned when an attempt is made to register an exclusive key while another hot key is already registered for that key code and modifiers." The `RegisterEventHotKey` comment: `eventHotKeyExistsErr` is returned "when another process has already registered the same hotkey using the `kEventHotKeyExclusive` option". The measurement follows the second. What that means for Knot:

- Settings can say that a key is taken only when another app took it exclusively. A key another app registered plainly, a system shortcut, and a key another app watches through an event tap all register without complaint.
- Registering exclusively takes the key from the other app's plain registration for as long as Knot holds it: "Registering an exclusive hotkey prevents non-exclusive registrants for the same key code and modifiers from receiving notification events." Registering plainly leaves both apps answering the key.
- Secure event input (`IsSecureEventInputEnabled`, held by any process, for example a focused password field) is read and recorded with each press. Whether hot keys arrive while it is on is an optional sitting row.

## Telling a tap from a hold

The machine is pure: every input carries its own time, so a table drives it. At key-down it asks for the microphone to be prepared and sets a timer for the mark.

| Event | In state | Effect |
|---|---|---|
| Key down | idle | Prepare the microphone. Start the 250 ms timer. |
| Key up before 250 ms | down | A tap: let go of the preparation, then show the panel for typing, or hide it if it was showing. |
| Timer at 250 ms | down | A hold: show the panel listening, open the microphone, arm Esc. |
| Key up at or after 250 ms, timer not run yet | down | A hold that is already over: open, then stop at once. |
| Key up | recording | Stop. |
| Key state reads up, once a second | recording | Stop: the release was missed. |
| Esc, the stop control | recording | Stop. |
| Key down | recording | Stop, and swallow this press's release, so it is not read as a tap. |
| Key down | down | A repeat: counted and ignored. |

The 13 cases of the table pass, among them a tap at 249 ms, a timer that fires 10 ms early, a release that beats a late timer, each way of stopping a recording whose release was missed, and both microphone modes.

The timer has to be strict. `DispatchQueue.main.asyncAfter` fired the mark 10.2 ms late in the self-test, on an idle machine. `DispatchSource.makeTimerSource(flags: .strict, queue: .main)` scheduled with `leeway: .nanoseconds(0)` fired it 0.1 ms late. Ten milliseconds is a fifteenth of the 150 ms budget from the mark to a live microphone.

## The panel

The spike's panel, built in the self-test and never shown:

- An `NSPanel` with the style mask `[.nonactivatingPanel, .titled, .fullSizeContentView]`, `isFloatingPanel`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = false`, and `canBecomeKey` overridden to true.
- **A tap:** `makeKeyAndOrderFront`, then `makeFirstResponder` on the text field. The panel becomes key without activating the app (NSWindow.h: "a panel that does not activate the owning application"). The spike times the release to the moment the field holds the focus, and to the next turn of the main run loop.
- **A hold:** `orderFrontRegardless`, without making it key, so the app in front keeps the keyboard.
- **Esc** on a key panel arrives as `cancelOperation(_:)`.

The three variants the sitting compares, raw values as the self-test read them:

| Variant | Collection behaviour | Level |
|---|---|---|
| A, what §15 describes | `canJoinAllSpaces`, `fullScreenAuxiliary`, `ignoresCycle` (321) | floating (3) |
| B | A plus `canJoinAllApplications` (262465) | floating (3) |
| C | B | status bar (25) |

NSWindow.h allows at most one of `primary`, `auxiliary` and `canJoinAllApplications`. The spike is an accessory app (`LSUIElement`) that becomes regular while its window is open, as §15 says Knot does, and the sitting tries the panel over a full-screen app both ways. For each press the app records whether the panel's `occlusionState` contains `.visible`, whether it is on the active Space, and whether the app that was in front before the press is still in front. It reads neither a window title nor an app's name.

## The microphone at key-down

What the SDK says, in AVAudioEngine.h:

- `prepare()`: "preallocates many of the resources the engine requires in order to start. Use it to responsively start audio input or output."
- `inputNode`: "if the engine has at any point previously had its inputNode enabled and permission to record was granted, then any time the engine is running, the mic-in-use indicator will appear." The same paragraph advises two engine instances for an app that switches between output only and input with output.
- `start()`: "starts the audio hardware via the AVAudioInputNode and/or AVAudioOutputNode instances in the engine. Audio begins to flow through the engine."

So the spike, at key-down: makes an engine, reads its input node's format, installs the tap with `installAudioTap(onBus:bufferSize:format:tapProvider:)` and calls `prepare()`. At the mark it calls `start()`. On a tap it removes the tap and drops the engine. Playback of the last hold runs on a second engine that has no input node. It prepares nothing unless the microphone permission is already granted, so a key press never brings up the system's microphone prompt.

"Live" is the host time of the first captured sample, from the first tap buffer's `AVAudioTime`. The "Listening" state can show only when that buffer reaches the app, and AVAudioNode.h gives tap buffers a "supported range" of 100 to 400 ms. So the state shows at least about 100 ms after the microphone is live. The app shows both numbers, from the mark and from key-down, and how much of the hold before the first sample went unrecorded. WP-12's note reached the same view of "live" from the file's side.

To judge clipping, the sitting says "one, two, three" from the moment of the press, ten times, and plays the last hold back from memory. The app also flags a recording whose first 30 ms are already within 20 dB of its loudest moment and above -45 dBFS: speech already under way when the microphone opened. Row 9 repeats it with the microphone opened at key-down, the alternative of the failure rule.

WP-12's proposed `Recorder` port already has `prepare()` for this key-down. The spike adds one need: a tap lets go of what was prepared.

## The key state

The three readers the sitting compares, once a second while recording:

- `CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, key)`
- `CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, key)`
- `NSEvent.modifierFlags`, for the key's modifiers

CGEventSource.h says nothing about a permission for them. With no key held, each reads "up" whether or not the system shows the app the key, so the self-test does not call them; only a held key at the sitting tells. If the session or HID reader reads "up" while the key is held, the check of §15 would stop every hold after a second, and it must not be used.

Reading the permission itself prompts nothing: `CGPreflightListenEventAccess()`, a yes or no, and `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`, which answers granted, denied or unknown. In the self-test the spike app had not been granted Input Monitoring: preflight `false`, access `unknown`. `CGPreflightPostEventAccess()` read `false`, which is why no agent can post a key press.

## What the fallback would need

If press and release do not arrive, §15's fallback is a listen-only event tap. From CGEvent.h and NSEvent.h:

- `CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, callback, nil)` for key down, key up and modifier changes, added to the main run loop. The header still says that key events need "access for assistive devices"; from macOS 10.15 the permission is Input Monitoring, checked with `CGPreflightListenEventAccess()` and asked for with `CGRequestListenEventAccess()`, "potentially prompting".
- Without the permission, "the appropriate bits in the mask are cleared. If that results in an empty mask, then NULL is returned." So the tap is created only after the permission is granted, and Knot says so when it is not.
- The tap is disabled by the system when it is slow or by user input, and arrives as `kCGEventTapDisabledByTimeout` or `kCGEventTapDisabledByUserInput`; the callback enables it again.
- It sees every key the user types, which is what the Input Monitoring prompt tells the user. That is the cost.
- `NSEvent.addGlobalMonitorForEvents` is not an alternative: "Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access."

The spike has the tap behind a button, used only by the sitting's conditional row 10. Whether a sandboxed app gets a listen-only tap is reported, not proven here.

## Local or team signing

The sitting uses the local build. `KNOT_SIGNING=local` signs ad hoc and keeps the sandbox. Inside the process the app read `com.apple.security.app-sandbox` as true and its home is its container. `RegisterEventHotKey`, the panel, the key-state readers and the audio engine need no entitlement beyond the sandbox and the microphone, so a team signature changes none of what SP-5 measures. Two differences, neither in SP-5's way:

- The microphone and Input Monitoring permissions follow the code signature, and an ad hoc signature changes with every build, so a rebuilt spike asks again.
- The ad hoc debug signature carries no hardened-runtime flag (`flags=0x2(adhoc)`), although the settings ask for it. Hardened runtime matters for distribution, which is SP-3's question.

## What the self-test showed

The holder held `⌃⌥⇧F20` shared and `⌃⌥⇧⌘F20` exclusively. From the self-test's log, without times and process IDs:

```
selftest.sandbox    appSandbox true, audioInput true, applicationGroups absent, inContainer true, signing local
selftest.permissions listenPreflight false, listenAccess unknown, postPreflight false, activationPolicy accessory, appActive false
selftest.register   handler 0, own 0, functionKeyNoModifier 0, sameKeySecondID -9878, ownExclusiveWhileShared -9878
selftest.other-process exclusiveOverShared 0, exclusiveOverExclusive -9878, sharedOverExclusive 0
selftest.synthetic  records tap,hold, markLateMS 0.1
                    effects prepareMicrophone, discardMicrophone, showPanelForTyping,
                            prepareMicrophone, showPanelListening, openMicrophone, armEscape,
                            stopRecording(released), disarmEscape
selftest.machine    passed 13, failed none
selftest.panel      A: styleMask 32897, collection 321, level 3, canBecomeKey true, visible false
                    B: collection 262465, level 3;  C: collection 262465, level 25
selftest.end        0.81 s, microphoneTouched false, panelShown false, appActive false
```

## Changes this asks of the architecture

docs/architecture.md is the orchestrator's file, so this note does not edit it. The report may add to these after the sitting.

1. **§15, hotkey failures.** "If the key is already registered by another app, Settings says so and asks for another key" holds only for a key another app registered exclusively. Knot registers its key exclusively, and Settings says a key is taken when that fails. The text should also say that an exclusive registration silences another app's plain registration of the same key while Knot runs. Product spec §6 says the same thing in its last sentence about the key and needs the same change.
2. **§15, hotkey.** The 250 ms mark is a strict timer with no leeway, and a release at or after 250 ms is a hold even when the timer has not fired.
3. **§15, hotkey failures, and product spec §6.** During a hold the panel is not key, so "Esc stops it" needs Esc registered as a hot key while a recording runs, and released when it ends. While it is registered, Esc does not reach the app in front.
4. **§15 and product spec §14, the 150 ms target.** "Live" is the first captured sample, timed from the tap buffer's host time. The listening state shows when the first buffer arrives, at least about 100 ms of audio later. The target names which of the two it measures.
5. **§5, the `Recorder` row.** With WP-12's `prepare()`, a way to let go of the preparation after a tap.
6. **§20, new rows.**
   - Carbon `RegisterEventHotKey` registers in a sandboxed, ad hoc signed build whose only entitlements are the sandbox and the microphone (build). Delivery of press and release from the keyboard is SP-5's sitting.
   - An exclusive Carbon registration fails only against another exclusive one; over a plain one it succeeds and takes the key (build, against the header's `HotKeyOptions` comment).
   - `NSWindowCollectionBehaviorCanJoinAllApplications` exists from macOS 13, for floating windows and system overlays (SDK).
   - A global monitor of key events needs Accessibility (SDK). Whether a listen-only event tap works in the sandbox with Input Monitoring is reported only.
   - `DispatchQueue.main.asyncAfter` fired a 250 ms timer 10 ms late on an idle Mac; a strict timer with no leeway fired it 0.1 ms late (build).

## Declarations read

In the MacOSX 27.2 SDK of Xcode 27.2, through `scripts/sdk-path.sh` and the framework headers beside it:

- Carbon, HIToolbox: `RegisterEventHotKey`, `UnregisterEventHotKey`, `HotKeyOptions` (`kEventHotKeyNoOptions`, `kEventHotKeyExclusive`), `eventHotKeyExistsErr`, `eventHotKeyInvalidErr`, `kEventHotKeyPressed`, `kEventHotKeyReleased`, `InstallEventHandler`, `GetEventParameter`, `GetEventTime`, `CreateEvent`, `SendEventToEventTarget`, `IsSecureEventInputEnabled`. None is deprecated in this SDK.
- AppKit: `NSPanel` (`floatingPanel`, `becomesKeyOnlyIfNeeded`, `worksWhenModal`), `NSWindowStyleMaskNonactivatingPanel`, `NSWindowCollectionBehavior` and its rules, `occlusionState`, `onActiveSpace`, `NSEvent.modifierFlags`, `addGlobalMonitorForEventsMatchingMask:handler:`.
- CoreGraphics: `CGEventSourceKeyState`, `CGEventSourceFlagsState`, `CGEventTapCreate` and its discussion, `kCGEventTapOptionListenOnly`, `CGPreflightListenEventAccess`, `CGRequestListenEventAccess`, `CGPreflightPostEventAccess`.
- IOKit: `IOHIDCheckAccess`, `IOHIDRequestAccess`, `IOHIDRequestType`, `IOHIDAccessType`.
- AVFAudio: `AVAudioEngine` (`prepare`, `start`, `inputNode`), `AVAudioNode.installAudioTap(onBus:bufferSize:format:tapProvider:)` and the deprecated `installTap`, `AVReadOnlyAudioPCMBuffer`, `AVAudioEngine.connectNode(_:to:format:)`, `AVAudioPlayerNode.playAudio()`. The last two replace `connect(_:to:format:)` and `play()`, deprecated in macOS 27, which fail a build that treats warnings as errors. AVFoundation: `AVCaptureDevice.authorizationStatus(for:)`. Security: `SecTaskCopyValueForEntitlement`.

## Not verified yet

Everything that needs a key pressed, a microphone open or a full-screen app: press and release from the keyboard, the panel over a full-screen app, the tap and hold latencies, clipping, the key-state readers while a key is held, Esc and a second press after a missed release, the indicator on taps, hot keys under secure input, and the event tap. The sitting answers them, and the report decides.
