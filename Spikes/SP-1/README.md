# SP-1 · the spike app

Throwaway code for [SP-1](../../docs/plan/SP-1.md): does a recording start from a locked iPhone while Knot is not running, and how does the work after stop get its time. It lives on `spike/locked-recording` and is never merged. The short note of this code half is `docs/notes/SP-1.md`, merged on its own. The report, `docs/spikes/SP-1.md`, follows the owner's sitting with [sitting.md](sitting.md).

## What is in it

| Path | What |
|---|---|
| `project.yml` | Its own XcodeGen spec, on `Apps/Config/Base.xcconfig`, so it takes the development identifiers and the same signing switch. The real `project.yml` is untouched. |
| `Shared/` | Compiled into both the app and the widget extension: the draft ports (`DraftPorts.swift`), the intents (`Intents.swift`) and the content-free event log (`SpikeLog.swift`). |
| `App/` | The app: the press state machine (`RecordingController.swift`), a minimal recorder, the Live Activity, the work after stop with its three mechanisms, the protection and recovery probes, the screen, and a Simulator self-test. |
| `Widgets/` | Three controls (SP-1 Toggle, SP-1 Press, SP-1 Probe) and the Live Activity's views. |
| `build.sh` | Builds with the pinned Xcode. `check`, `sim` and `device`. |
| `sitting.md` | The rows the owner goes through on the iPhone. |

Identifiers, all from `Apps/Config/Identifiers.xcconfig`, development set only: the app `com.p3ob7o.knot.dev`, the extension `com.p3ob7o.knot.dev.widgets`, the group `group.com.p3ob7o.knot.dev`. The home screen name is "Knot SP-1". Installing it replaces any "Knot Dev" build on the same iPhone, because the bundle ID is the same.

## The intents

| Intent | Protocols | Process | Used by |
|---|---|---|---|
| `ToggleRecordingIntent` | `SetValueIntent`, `AudioRecordingIntent`, `LiveActivityIntent`, `LongRunningIntent`, `CancellableIntent` | Pinned to the app with `allowedExecutionTargets = [.main]` | SP-1 Toggle control, the Action Button |
| `PressRecordingIntent` | The same without `SetValueIntent` | Not pinned | SP-1 Press control, Siri and Shortcuts |
| `StopRecordingIntent` | `LiveActivityIntent`, `LongRunningIntent`, `CancellableIntent` | Pinned to the app | The Live Activity's Stop button |
| `ProbeIntent` | `AppIntent` | Not pinned | SP-1 Probe control. Records nothing. |

The app registers its host with `AppDependencyManager` in `App.init`. The extension registers none, so an intent run there gets `@Dependency`'s default, the unavailable host, and fails with "ran this in the widgets process".

If Live Activities are off or the microphone permission is missing, a press asks to continue in the foreground (`continueInForeground`) and starts there.

## The log

Every step writes one JSON line to `SP1/events.jsonl` in the group container: event name, process, pid, time, IDs, states, durations, counts and error codes. Never text, a transcript or audio. The file has no file protection, so that a press before the first unlock can still be logged. The app shows the log and shares the file ("Share the log").

The recordings stay in the app's container on the phone, in `Application Support/SP1/Recording/`, with `completeUntilFirstUserAuthentication`. Nothing copies them off the phone.

## Building

Every command runs from the repository root with `KNOT_AGENT=1` for an agent.

```
Spikes/SP-1/build.sh check            # compile for the Simulator, and unsigned for a device
Spikes/SP-1/build.sh sim              # build, install on this worktree's iPhone simulator, self-test
Spikes/SP-1/build.sh device [UDID]    # build signed for the owner's iPhone, and install it
```

`sim` launches the app with `-SP1SelfTest`. In the Simulator the recorder refuses the hardware input before it touches the audio session, so no microphone opens. The self-test seeds a recording left open by a dead launch, presses twice at once, presses Stop while idle, and runs each background mechanism over one second of synthetic silence. It prints the log.

## Installing on the iPhone

What `device` needs, once:

1. The owner's signing configuration: a `Local.xcconfig` outside the repository with `KNOT_SIGNING = team` and `DEVELOPMENT_TEAM = <team>`, named by `KNOT_LOCAL_CONFIG`, then `scripts/bootstrap.sh` to link it into `.build/config/`.
2. Xcode signed in to the owner's Apple developer account (Xcode → Settings → Accounts), so that `-allowProvisioningUpdates` can register `com.p3ob7o.knot.dev`, `com.p3ob7o.knot.dev.widgets` and `group.com.p3ob7o.knot.dev` if they are not registered yet, and make the development profiles.
3. The iPhone 17 Pro paired with this Mac and Developer Mode on (Settings → Privacy & Security → Developer Mode). `xcrun devicectl list devices` shows its identifier.

Then:

```
export KNOT_LOCAL_CONFIG=~/knot-build/Local.xcconfig   # wherever the owner keeps it
scripts/bootstrap.sh
Spikes/SP-1/build.sh device <iPhone identifier>
```

The build is Debug, signed "Apple Development" with automatic signing. `devicectl device install app` installs `SP1.app`. The report records what actually worked, so that the orchestrator can correct `scripts/install.sh`. SP-1 has no Watch app. Its brief asks the report to record the Watch install as well, so the report takes it from the sitting it shares with SP-2.
