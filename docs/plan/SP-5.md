# SP-5 · The Mac hotkey in a sandboxed build

| Size | Wave | Run by |
|---|---|---|
| S | 1 | Its own thread |

## Goal

Prove that the hotkey's press and release arrive in a sandboxed build and that the panel shows over a full-screen app, and find out whether first words are clipped. The report ends with a decision that WP-33 PR 2 builds on.

## Owns

- `spike/mac-hotkey`, the branch that holds the spike's code. It is never merged.
- `docs/spikes/SP-5.md`, the report.
- `docs/notes/SP-5.md`, the short note of its code half

## Starts after

| PR | What it holds | Starts after |
|---|---|---|
| Notes | The code half on `spike/mac-hotkey`, and its short note | WP-01 PR 1 |
| 1 | The report, `docs/spikes/SP-5.md`, which ends with a decision | SP-5 notes |

SP-5 starts after the first PR of WP-01. Its code half starts beside WP-02 PR 1, like the code half of each spike, with the proof steps of WP-12, WP-13, WP-14 and WP-18, and it needs only WP-01 PR 1. It files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. The note is `docs/notes/SP-5.md`, merged by a pull request that holds nothing else. No package waits for SP-5's short note.

SP-5 is done when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names.

WP-33 PR 2 waits for SP-5.

The full design round does not wait for SP-5. The design brief asks for both branches of the surface it decides: the Mac's first run with a permission prompt for the hotkey, and without one.

## Build

- SP-5 takes the hotkey's press and release in a sandboxed build, the panel over a full-screen app, the key-state check and whether first words are clipped. Command-line access to the store stays with SP-3.
- The spike runs on a sandboxed build, signed for development like every spike (`docs/architecture.md` §18). Its code answers these questions:
  - Do hotkey press and release arrive in a sandboxed build? `docs/architecture.md` §15 uses Carbon `RegisterEventHotKey`, which delivers both, and developers report that it works in the sandbox with no extra permission. `docs/architecture.md` §20 marks that as reported, for SP-5 to prove.
  - Does the panel show over a full-screen app? The panel is an `NSPanel` that does not activate the app and joins every Space, including full-screen apps.
  - Are first words clipped when the microphone opens at the 250 ms mark of a hold? The audio engine is prepared at key-down, so that the microphone is live within 150 ms of the mark.
  - Does reading the key's state once a second work in the sandbox without Input Monitoring? If a release never arrives, the recording goes on with the panel showing and a stop control, and Knot checks the key's state every second while recording (`docs/architecture.md` §15).
- A hotkey is a key with at least one modifier, or a function key. A modifier alone is not possible with this API.
- `docs/product-spec.md` §14 sets two first targets for the Mac: 100 ms from the key release of a tap to a panel that accepts typing, and 150 ms from the 250 ms mark of a hold to a live microphone. The spikes and WP-42 calibrate them.
- The report ends with a decision. Where the answer changes `docs/architecture.md`, the report lists the changes it asks for. The orchestrator owns that file and makes them in a pull request of its own (PLAN.md §7).

## Merge criteria

- The report answers every question under "Build": press and release in a sandboxed build, the panel over a full-screen app, the key-state check, and clipped first words.
- It says whether the hotkey needs the listen-only event tap, and with it the Input Monitoring permission.
- It says whether Knot must listen from key-down.
- It ends with a decision.
- Nothing from the spike's branch merges to `main`. The report PR changes documents only, so the gate runs the plan check and the link check (`docs/architecture.md` §18), and both pass.

## Milestone evidence

- Gate G3, after wave 1. SP-5's rows on the Mac, about 15 minutes.
- Start latency on a real microphone is measured at the owner's sittings, because no automated test and no agent opens a hardware microphone on the build Mac.
- The sitting starts when `scripts/install.sh` has reported success.
- Gate G3. The owner reads the report and confirms its decision. Each spike is confirmed on its own.
- M4 needs SP-5.

## Prior art

None.

## Failure rules

- If press and release do not arrive, the fallback is a listen-only event tap, which needs the Input Monitoring permission. SP-5 decides in wave 1.
- If first words are clipped, the alternative is to listen from key-down into a buffer that a tap discards, on built-in and wired inputs only.
- The microphone opens at the 250 ms mark of a hold and never on a tap, so the system's microphone indicator lights only for a recording.
- No automated test and no agent opens a hardware microphone on the build Mac. The recorder takes injected audio and refuses the hardware input under test.
- The Mac Studio has no built-in microphone. Hold-to-record needs an external one there.
- The spike app uses the development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. Only a milestone build opens the default store or the real iCloud container, so nothing before the M1 milestone build touches the retired app or its container.
- The spike's code stays on its branch and is never merged.
- Read the declaration of each OS 26 or OS 27 API in the SDK before using it (`docs/architecture.md` §21), and name the declarations read in the report PR.

## Named tests

None.
