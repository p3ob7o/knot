# SP-5 · the spike app

Throwaway code for [SP-5](../../docs/plan/SP-5.md): the Mac hotkey in a sandboxed build. Do press and release arrive, does the panel show over a full-screen app, can the key's state be read without Input Monitoring, and are first words clipped when the microphone opens at the 250 ms mark of a hold. It lives on `spike/mac-hotkey` and is never merged. The short note of this code half is `docs/notes/SP-5.md`, merged on its own. The report, `docs/spikes/SP-5.md`, follows the owner's sitting with [sitting.md](sitting.md).

## What is in it

| Path | What |
|---|---|
| `project.yml` | Its own XcodeGen spec, on `Apps/Config/Base.xcconfig`, so it takes the development identifiers and the same signing switch. The real `project.yml` is untouched. |
| `App/HotKey.swift` | Carbon `RegisterEventHotKey`, one handler for pressed and released, and a way to send a hot key event to the app's own target for the self-test. |
| `App/PressMachine.swift` | The tap/hold machine at 250 ms. Pure: every input carries its own time. |
| `App/PressController.swift` | Joins the events, the machine, the microphone and the panel. Measures every press and keeps the last 60 in memory. |
| `App/Microphone.swift` | `AVAudioEngine` with the macOS 27 Sendable tap. Prepared at key-down without starting, started at the mark. The audio stays in memory for "Play the last hold" and is never written. |
| `App/Panel.swift` | The non-activating `NSPanel`, in three variants of collection behaviour and level. |
| `App/KeyState.swift` | The three key-state readers, the permission checks that never prompt, and the listen-only event tap fallback. |
| `App/SpikeWindow.swift`, `App/SP5App.swift` | The window the owner reads, the menu bar item, and the three launch modes. |
| `App/SelfTest.swift` | The self-test and the holder process. |
| `build.sh` | Builds with the pinned Xcode. `check`, `selftest` and `mac`. |
| `sitting.md` | The rows the owner goes through at the Mac. |

Identifiers come from `Apps/Config/Identifiers.xcconfig`, development set only: the bundle ID `com.p3ob7o.knot.dev`. The app needs no app group and no iCloud container. Its name in Finder is "Knot SP-5". It shares its container with any other "Knot Dev" build on this Mac, because the bundle ID is the same, and it writes only into `Library/Application Support/SP5/` there.

## The three launch modes

| Arguments | What it does |
|---|---|
| none | The sitting: an "SP-5" menu bar item and the window. It is an accessory app (`LSUIElement`), and becomes a regular app while its window is open, as `docs/architecture.md` §15 says Knot does. |
| `-SP5SelfTest` | No menu bar item, no window, no panel on screen, never activates, never touches the microphone. It registers only F20 keys, which no Apple keyboard has, and quits within a second. |
| `-SP5HoldKeys` | The holder: another sandboxed process that holds ⌃⌥⇧F20 shared and ⌃⌥⇧⌘F20 exclusively for five seconds, so the self-test can see what registration says about a key another app holds. |

## The log

Each press writes one JSON line to `Library/Application Support/SP5/events.jsonl` in the app's container: event names, key codes, timings, counts, states and status codes. Never typed text and never audio. The panel's text field shows only how many characters were typed, and the field is cleared when the panel hides.

## Building

Every command runs from the repository root, with `KNOT_AGENT=1` for an agent.

```
Spikes/SP-5/build.sh check            # build, signed ad hoc, and check that it is sandboxed
Spikes/SP-5/build.sh selftest         # build, then the holder and the self-test; both quit by themselves
Spikes/SP-5/build.sh mac [FOLDER]     # build for the sitting and copy "Knot SP-5.app" to FOLDER
```

`mac` copies the app to `~/knot-build/sp5/` by default and does not launch it. A previous copy is moved aside into a new folder, never deleted. The local build answers every question of the sitting (see the note), so `KNOT_SIGNING=team` is not needed. If the owner wants it anyway, `KNOT_LOCAL_CONFIG` names his `Local.xcconfig` and `scripts/bootstrap.sh` links it; the entitlements are the same.

An ad hoc signature changes with every build, and the system's microphone and Input Monitoring permissions follow the signature, so a rebuilt app asks again.
