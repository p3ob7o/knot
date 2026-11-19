# SP-1 · Recording from a locked iPhone

| Size | Wave | Run by |
|---|---|---|
| S | 1 | Its own thread |

## Goal

Find out whether a recording starts from a locked iPhone while Knot is not running, and how the work after a recording stops runs in the background. The report ends with a decision that WP-15, WP-19 and WP-31 build on.

## Owns

- `spike/locked-recording`, the branch that holds the spike's code. It is never merged.
- `docs/spikes/SP-1.md`, the report.
- `docs/notes/SP-1.md`, the short note of its code half

## Starts after

| PR | What it holds | Starts after |
|---|---|---|
| Notes | The code half, a minimal app on `spike/locked-recording`, and its short note | WP-01 PR 1; WP-04 |
| 1 | The report, `docs/spikes/SP-1.md`, which ends with a decision | SP-1 notes |

The code half starts beside WP-02 PR 1, with the proof steps of WP-12, WP-13, WP-14 and WP-18. It needs only WP-01 PR 1 and WP-04. It files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. The note is `docs/notes/SP-1.md`, merged by a pull request that holds nothing else.

WP-02 PR 3 waits for SP-1's short note, and not for its report.

SP-1 is done when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names.

These wait for SP-1: WP-15 PR 2, for the background mechanism; WP-19 PR 2, the recording intents on iPhone, iPad and Mac; and WP-31 PR 1. One chain to M2 runs through SP-1: the first PR of WP-01, SP-1 with the owner's confirmation, then the second PRs of WP-15 and WP-19, then the first PR of WP-31.

The full design round does not wait for SP-1. The design brief asks for both branches of the surface it decides: a recording from a locked iPhone, or one that starts only after Face ID.

## Build

- SP-1 needs the iPhone 17 Pro.
- The code is a minimal app on `spike/locked-recording`. It answers these questions:
  - Does an intent conforming to `AudioRecordingIntent` and `LiveActivityIntent` start recording from the Action Button and from a Lock Screen control, while the phone is locked and Knot is not running?
  - What happens when Live Activities are off, or the microphone permission is missing?
  - How long is it from the press to the first captured sample?
  - Does transcription finish in the background after stop? Try `LongRunningIntent.performBackgroundTask` and a continued-processing background task.
  - Does cleanup with the on-device model finish in the background after a recording stops?
  - Which file protection class does this need? `docs/architecture.md` §7 proposes `completeUntilFirstUserAuthentication` for everything Knot writes on iOS, because recording and ingest must work while the phone is locked.
  - What happens on a press after a restart and before the first unlock, on a double press on a cold start, and on a press after a force quit during a recording?
  - In which process does each intent run?
  - Does a toggle control's intent carry the value the control showed? On iPhone and iPad, ToggleRecording starts a recording when idle and stops the one running (`docs/architecture.md` §14).
- Confirm the rules that `docs/architecture.md` §14 takes from Apple's documentation:
  - ToggleRecording and StopRecording must be compiled into both the app and the widget extension.
  - The Live Activity must start with the recording and last as long as it does, or the system stops the recording.
  - If Live Activities are off or the microphone permission is missing, the intent must open the app.
- `docs/architecture.md` §20 marks "Starting a recording from a locked iPhone works for third-party apps" as unconfirmed, with one developer reporting a failure. SP-1 settles it.
- Choose the mechanism for background execution on iOS. WP-15 PR 2 builds its hooks on it.
- The latencies bear on a first target of `docs/product-spec.md` §14: the Action Button to a live microphone in 1 s. The spikes and WP-42 calibrate those targets.
- Record the install procedure that worked on the iPhone and on the Watch. The orchestrator corrects `scripts/install.sh` from it.
- The report, `docs/spikes/SP-1.md`, has a result matrix (locked or unlocked, app running or terminated, each trigger), the latencies and a decision. It includes the feedback flow for each entry state, including Live Activities turned off and a missing microphone permission.
- The report updates `docs/architecture.md` where the answer changes it.

## Merge criteria

- `docs/spikes/SP-1.md` has the result matrix: locked or unlocked, app running or terminated, each trigger.
- It gives the latencies from the press to the first captured sample.
- It answers every question under "Build", and names the mechanism for background execution on iOS.
- It includes the feedback flow for each entry state, including Live Activities turned off and a missing microphone permission.
- It records the install procedure that worked on the iPhone and on the Watch.
- It ends with a decision.
- Nothing from `spike/locked-recording` merges to `main`. The report PR changes documents only, so the gate runs the plan check and the link check (`docs/architecture.md` §18), and both pass.

## Milestone evidence

- Gate G3, after wave 1. Paolo installs the build and runs a 12-row checklist, about 15 minutes. It is part of the one spike sitting shared with SP-2, about 45 minutes.
- The sitting starts when `scripts/install.sh` has reported success.
- Gate G3. The owner reads the report and confirms its decision. Each spike is confirmed on its own.
- M2 needs SP-1.

## Prior art

None.

## Failure rules

- If a locked start fails, the control opens Knot after Face ID and recording starts at once.
- The spike's code stays on `spike/locked-recording` and is never merged.
- The spike app uses the development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. Only a milestone build opens the default store or the real iCloud container, so nothing before the M1 milestone build touches the retired app or its container.
- Read the declaration of each OS 26 or OS 27 API in the SDK before using it (`docs/architecture.md` §21), and name the declarations read in the report PR.

## Named tests

None.
