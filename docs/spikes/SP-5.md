# SP-5 · The Mac hotkey in a sandboxed build

The 2026-11-27 sitting used an ad hoc signed, sandboxed development build with Input Monitoring ungranted. The primary run used a built-in microphone. A second Mac supplied two wired USB microphone measurements. The [code-half note](../notes/SP-5.md) records the sandbox checks, registration tests and 13 passing press-state cases from Xcode 27.2 and the macOS 27.2 SDK. The spike app stays on `spike/mac-hotkey`.

## Hotkey delivery and tap latency

Carbon's exclusive `RegisterEventHotKey` returned status 0. The primary run logged 50 tap or hold records. The separate press that stopped a recording accounts for the extra event pair. All 51 presses and 51 releases arrived, with zero repeated presses. The spike deliberately ignored three releases after receiving them to test recovery.

| Event or interval | Samples | Range (ms) | Median (ms) | p95 (ms) |
|---|---:|---:|---:|---:|
| Carbon press delivery | 51 | 0.0–0.2 | 0.1 | 0.2 |
| Carbon release delivery | 51 | 0.0–0.3 | 0.1 | 0.2 |
| Tap release to typing ready at the default setting | 11 | 11.8–26.8 | 19.2 | 26.8 |
| Tap release to drawn panel at the default setting | 11 | 24.0–50.6 | 31.9 | 50.6 |

All 11 opening taps at the default microphone setting focused the field and showed the panel on the active Space. The other app stayed frontmost on all 11. The 11 closing taps are outside the opening-latency sample. The typing-ready measurement meets the 100 ms target in this sitting. The drawn measurement uses the next turn of the main run loop as a proxy. The table uses nearest-rank p95 throughout.

The Carbon results answer the permission question for WP-33 PR 2. The conditional listen-only event-tap row was skipped, and the hotkey requires no Input Monitoring prompt.

## Panel over another app

The owner reported that the panels showed as expected in full-screen and regular windows. For full-screen holds, the panel was visible on the active Space and the other app stayed frontmost in every recorded case.

| Press | Variant | Knot activation policy | Main window |
|---|---|---|---|
| 36 | B | Accessory | Closed |
| 37 | A | Accessory | Closed |
| 38 | B | Regular | Open |
| 39 | C | Regular | Open |

Press 34 also opened B for typing in the full-screen sequence. The field held focus and the other app stayed frontmost. All variants use a nonactivating `NSPanel`. A uses `canJoinAllSpaces`, `fullScreenAuxiliary`, and `ignoresCycle` at the floating level. B adds `canJoinAllApplications`. C raises B to the status-bar level. B worked in both activation policies at the floating level. A and C were each observed in one policy.

## Microphone onset and clipping

The default mode prepares the engine at key-down and starts it at the 250 ms mark. The 22 default-mode taps had no engine start or captured sample in the log. At the mark, the live measurement uses the first sample's host timestamp. **Listening** appears when the app receives the first buffer, roughly 108 ms after that sample in this run. The macOS tap API supports buffers of 100 to 400 ms.

| Built-in microphone interval | Holds | Range (ms) | Median (ms) | p95 (ms) |
|---|---:|---:|---:|---:|
| 250 ms mark to first sample, default mode | 17 | 44.0–75.2 | 52.1 | 75.2 |
| 250 ms mark to Listening, default mode | 17 | 152.1–183.5 | 160.3 | 183.5 |
| Key-down to first sample, default mode | 17 | 294.0–325.2 | 302.1 | 325.2 |
| 250 ms timer lateness, default mode | 17 | 0.1–0.2 | 0.2 | 0.2 |
| Key-down to first sample, key-down mode | 5 | 67.7–76.5 | 71.3 | 76.5 |

The owner reported, "No 'one' was ever cut," in either mode. The onset heuristic flagged speech already under way in zero of 17 default-mode holds and zero of five key-down holds. Those counts include holds for other sitting rows, such as the silent polling test. Playback supplies the clipping verdict. The key-down mode starts the engine on taps, which can light the system microphone indicator. Press 48 captured audio 75.8 ms after key-down despite ending as a tap.

On a second Mac with a wired USB microphone, two foreground holds took 451–452 ms from the mark to the first sample and 701–702 ms from key-down. **Listening** appeared 567 ms after the mark. Both holds ended on release. All three state readings showed down in polls at 1–4 s while the key was held. The built-in input met the 150 ms first-sample target. The two USB measurements show that input hardware can take longer to start.

## Key-state polling and missed releases

With another app frontmost, both `CGEventSourceKeyState` readers (`.combinedSessionState` and `.hidSystemState`) returned `false` at the first poll on all 13 background holds, presses 21–29 and 36–39. The session-state watchdog stopped every one at the first poll, with 1.00 s of audio in each record. Each Carbon release arrived 0.27–1.68 s after that poll. On the first round, presses 21–29, the actual down-to-up intervals were 2.22–2.89 s. The owner heard a few instances of "three" cut short in that round. The log places the stop while the key was still held, so the clipping happened at the end of the recording, when the watchdog stopped it.

The spike's modifier reader, `NSEvent.modifierFlags`, still showed the required modifiers down at all 13 background polls. Foreground holds showed both key-state readers down while the key was held. In press 31, the test ignored the Carbon release and both readers reported up at the 3 s poll, about 0.77 s after release, while the modifiers were still down. The session-state watchdog then stopped that hold. In presses 32 and 33, modifier flags also read up after release. Polling still logged readings there, but the key-state stop was disabled. An exclusive Esc registration returned status 0 and stopped press 32. A second hotkey press stopped press 33.

The modifier reading shows whether all required modifiers remain held. It cannot tell whether the non-modifier key was released while the modifiers stayed down. Keep Carbon release as the normal stop and keep explicit stops available. Use once-per-second modifier-only polling as a backstop for a modified hotkey. WP-33 PR 2 should verify `CGEventSourceFlagsState` against the measured AppKit reading with another app frontmost before using the Core Graphics reader. Skip polling for an unmodified function key.

## Changes this asks of the architecture

- [Architecture §15](../architecture.md#15-mac-specifics). Specify exclusive Carbon registration and delivery without an Input Monitoring flow. Settings can report a collision when another app holds the shortcut exclusively. Knot's exclusive registration suppresses a competing shared registration while Knot holds the shortcut. Carry the collision wording into [product spec §6](../product-spec.md#6-entry-points).
- [Architecture §15](../architecture.md#15-mac-specifics). Specify a strict 250 ms timer with zero leeway. Classify by elapsed press time even if the timer callback is late. Prepare audio at key-down, release the preparation on a tap, and open the microphone only at the mark for a hold. Mirror the elapsed-time rule and clarify when **Listening** appears in product spec §6.
- [Architecture §15](../architecture.md#15-mac-specifics). Specify B's floating level, nonactivating style and collection behaviors. A tap makes the panel key and focuses typing. A hold leaves the foreground app's keyboard focus in place.
- [Architecture §15](../architecture.md#15-mac-specifics). Replace the once-per-second key-code stop with a modifier-only check for modified hotkeys, stopping if any required modifier has been released. Stop normally on Carbon release. Keep the panel's **Stop** control and a second hotkey press, and register exclusive Esc only during a recording. Esc is intercepted while registered. State the explicit stops in product spec §6 as well.
- [Architecture §5](../architecture.md#5-ports). Give the recorder a way to release its preparation after a tap, as proposed in the code-half note.
- [Architecture §20](../architecture.md#20-platform-facts). Mark keyboard press and release as measured in the sandbox without Input Monitoring. Record the exclusive-versus-shared registration result from the code half, the measured panel behavior, the background key-state false negatives and the AppKit modifier readings. Record the direct Core Graphics modifier reader and secure input as awaiting a device check. Keep the listen-only tap as an untested conditional alternative.
- [Product spec §14](../product-spec.md#14-speed-and-durability-targets). Keep 100 ms from tap release to typing ready. Define the 150 ms built-in input target as the interval from the hold mark to the first captured sample. Track first-buffer delivery and the visible **Listening** state separately. Record the wired USB caveat and measure that transport separately in WP-42. The sitting's sample sizes calibrate the targets. WP-42 still needs the spec's 20 runs per target.

## SDK declarations read

The code half read these in the macOS 27.2 SDK of Xcode 27.2 through `scripts/sdk-path.sh` and the framework headers.

- Carbon, HIToolbox. `RegisterEventHotKey`, `UnregisterEventHotKey`, `HotKeyOptions` (`kEventHotKeyNoOptions`, `kEventHotKeyExclusive`), `eventHotKeyExistsErr`, `eventHotKeyInvalidErr`, `kEventHotKeyPressed`, `kEventHotKeyReleased`, `InstallEventHandler`, `GetEventParameter`, `GetEventTime`, `CreateEvent`, `SendEventToEventTarget`, and `IsSecureEventInputEnabled`.
- AppKit. `NSPanel` (`floatingPanel`, `becomesKeyOnlyIfNeeded`, `worksWhenModal`), `NSWindowStyleMaskNonactivatingPanel`, `NSWindowCollectionBehavior` and its rules, `occlusionState`, `onActiveSpace`, `NSEvent.modifierFlags`, and `addGlobalMonitorForEventsMatchingMask:handler:`.
- Core Graphics. `CGEventSourceKeyState`, `CGEventSourceFlagsState`, `CGEventTapCreate` and its discussion, `kCGEventTapOptionListenOnly`, `CGPreflightListenEventAccess`, `CGRequestListenEventAccess`, and `CGPreflightPostEventAccess`.
- IOKit. `IOHIDCheckAccess`, `IOHIDRequestAccess`, `IOHIDRequestType`, and `IOHIDAccessType`.
- AVFAudio. `AVAudioEngine` (`prepare`, `start`, `inputNode`), `AVAudioNode.installAudioTap(onBus:bufferSize:format:tapProvider:)`, the deprecated `installTap`, and `AVReadOnlyAudioPCMBuffer`. The macOS 27 declarations `AVAudioEngine.connectNode(_:to:format:)` and `AVAudioPlayerNode.playAudio()` replace `connect(_:to:format:)` and `play()`, which are deprecated in macOS 27.
- AVFoundation. `AVCaptureDevice.authorizationStatus(for:)`.
- Security. `SecTaskCopyValueForEntitlement`.

## Gate G3 and M4

Secure event input was off for all 50 press records. The optional secure-input row was not run. At M4, check hotkey delivery with a secure-input field focused, a function key without modifiers, and the shipped modifier-only fallback and **Stop** control with another app frontmost. The function key registered in the code-half self-test. Physical delivery in the sitting was measured for a modified shortcut. Gate G3 requires the owner's confirmation of the decision below.

## Decision for WP-33 PR 2

Use exclusive Carbon press and release without a listen-only event tap or Input Monitoring. Use floating Panel B for typing on a tap and for recording on a hold. Prepare at key-down and open the microphone at 250 ms. Stop on Carbon release, Esc, a second press, or the panel's **Stop** control. Use only the required modifier flags for the once-per-second backstop on modified shortcuts. A non-modifier key-state reading must never stop a recording.
