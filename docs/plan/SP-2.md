# SP-2 · Watch capture and delivery

| Size | Wave | Run by |
|---|---|---|
| S | 1 | Its own thread |

## Goal

Find out how a recording starts and runs on the Apple Watch, and how reliably it reaches the iPhone. The report ends with a decision that WP-17, WP-19 and WP-32 build on.

## Owns

- `spike/watch-delivery`, the branch that holds the spike's code. It is never merged.
- `docs/spikes/SP-2.md`, the report.

## Starts after

| PR | What it holds | Starts after |
|---|---|---|
| Notes | The code half on `spike/watch-delivery`, and its short note | WP-01 PR 1; WP-04 |
| 1 | The report, `docs/spikes/SP-2.md`, which ends with a decision | SP-2 notes |

The code half starts beside WP-02 PR 1, with the proof steps of WP-12, WP-13, WP-14 and WP-18. It needs only WP-01 PR 1 and WP-04. It files a short note saying whether the draft port fits the real API's streaming, cancellation and errors.

WP-02 PR 3 waits for SP-2's short note, and not for its report. No chain to M2 waits for the report of SP-2.

SP-2 is done when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names.

These wait for SP-2: WP-17 PR 2, the transport; WP-19 PR 3, the watch intents; and WP-32 PR 2.

The full design round does not wait for SP-2. The design brief asks for both branches of the surface it decides: a Watch start with the app in front, and one without it.

## Build

- SP-2 needs the Apple Watch Ultra 2 and the iPhone.
- The code on `spike/watch-delivery` answers these questions:
  - Does recording continue with the wrist down and the screen off?
  - How long is it from a complication tap to the first sample?
  - Can a watch control or `AudioRecordingIntent` start a recording without bringing the app forward? watchOS has no Live Activities, so Apple's iOS recipe does not apply.
  - Can a watch intent start a recording at all?
  - Does Double Tap start a recording when Knot is not the app in front?
  - Does a control bound to the Ultra's Action Button start a recording directly?
  - How long does `transferFile` take, and how often does it stall, with the phone near, with the phone away and then back, and with the iPhone app terminated?
  - Is the iPhone app woken to receive the file?
  - How much background time does the phone grant when it is locked and Knot is not running, and does transcription finish in it?
- Record for 30 minutes with the wrist down.
- StartRecording on the Watch opens the watch app already recording, and calls the watch recorder. Whether it can start without the app in front is SP-2's question (`docs/architecture.md` §14).
- `docs/architecture.md` §20 lists two reported facts for SP-2 to check: `WCSession.transferFile` can stall with no error until Bluetooth is toggled, and a watch recording continues with the wrist down once started in the foreground.
- Calibrate the Watch target of `docs/product-spec.md` §14: 60 seconds from the stop of a 30-second recording to its transcript on the iPhone, with the phone nearby. It is an estimate, and the M3 checklist measures it.
- The latencies also bear on the first targets of `docs/product-spec.md` §14 for a complication tap to a live microphone: 700 ms warm and 1.5 s cold. The spikes and WP-42 calibrate those targets.
- Record the install procedure that worked on the iPhone and on the Watch. The orchestrator corrects `scripts/install.sh` from it.
- The report, `docs/spikes/SP-2.md`, has timings over at least 30 transfers and a decision.
- The report updates `docs/architecture.md` where the answer changes it.

## Merge criteria

- `docs/spikes/SP-2.md` has timings over at least 30 transfers.
- It answers every question under "Build", including the background time a locked phone grants when Knot is not running.
- It reports the 30-minute recording with the wrist down.
- It gives the calibrated estimate for the 60-second Watch target.
- It records the install procedure that worked on the iPhone and on the Watch.
- It ends with a decision.
- Nothing from `spike/watch-delivery` merges to `main`. The report PR changes documents only, so the gate runs the plan check and the link check (`docs/architecture.md` §18), and both pass.

## Milestone evidence

- Gate G3, after wave 1. Paolo installs the build on the iPhone and the Watch and runs the delivery checklist. The SP-2 spike app runs its 30 transfers itself. It is part of the one spike sitting shared with SP-1, about 45 minutes.
- The sitting starts when `scripts/install.sh` has reported success.
- Gate G3. The owner reads the report and confirms its decision. Each spike is confirmed on its own.
- M3 needs SP-2. The M3 checklist measures the 60-second Watch target, and its row states the condition SP-2 measured: the background time the phone grants when it is locked and Knot is not running.

## Prior art

None.

## Failure rules

- If delivery is unreliable, recordings arrive late or need a retry. The durable outbox and re-send mean nothing is lost.
- File transfer does not work in the Simulator. Delivery is tested on hardware.
- The spike's code stays on `spike/watch-delivery` and is never merged.
- The spike app uses the development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. Only a milestone build opens the default store or the real iCloud container, so nothing before the M1 milestone build touches the retired app or its container.
- Read the declaration of each OS 26 or OS 27 API in the SDK before using it (`docs/architecture.md` §21), and name the declarations read in the report PR.

## Named tests

None.
