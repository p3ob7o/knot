# SP-3 · Command-line access to the store

| Size | Wave | Run by |
|---|---|---|
| S | 1 | Its own thread |

## Goal

Decide how the `knot` command and the MCP server reach the Mac app's store: direct store access from a sandboxed executable inside the app bundle, or XPC to the running app. The route it chooses must pass a distribution-signed check in wave 1.

## Owns

- `spike/agent-access`, the branch that holds the spike's code. It is never merged.
- `docs/spikes/SP-3.md`, the report.
- `docs/notes/SP-3.md`, the short note of its code half

## Starts after

| PR | What it holds | Starts after |
|---|---|---|
| Notes | The code half on `spike/agent-access`, and its short note | WP-01 PR 1; WP-04 |
| 1 | The report, `docs/spikes/SP-3.md`, which ends with a decision | SP-3 notes |

The code half starts beside WP-02 PR 1, with the proof steps of WP-12, WP-13, WP-14 and WP-18. It needs only WP-01 PR 1 and WP-04. It files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. The note is `docs/notes/SP-3.md`, merged by a pull request that holds nothing else. No package waits for SP-3's short note.

The TestFlight upload of the spike app runs only once the owner has handed over the API key at G1.

SP-3 is done when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names. SP-3 is closed only when the route it chooses has passed the distribution-signed check.

These wait for SP-3:

- WP-10 PR 2, for the second-process rules.
- The embedding of the tool in the Mac app, in WP-34 PR 3.
- WP-34 PR 2, if the direct route fails the distribution-signed check. The XPC route then gets an internal upload of its own before that PR.
- After G1 and SP-3, the gate has one development-signed step for a PR that touches KnotAgent, `knot`, the Mac app or KnotStore: the sandboxed app and `knot-dev` share a store, the tool writes and the app shows it.
- The M4 milestone build, which needs SP-3's answer on where the Mac store lives.

No chain to M2 waits for the report of SP-3.

## Build

- SP-3 covers command-line access to the store, the packaging rules and distribution signing. The hotkey's press and release, the panel over a full-screen app, the key-state check and clipped first words belong to SP-5.
- SP-3 runs on a sandboxed build signed for development. One internal TestFlight upload of the spike app in wave 1 checks distribution signing.
- The code on `spike/agent-access` answers these questions:
  - Can a sandboxed executable inside the Mac app bundle, started from Terminal or by an MCP client, open the app's SQLite store in the app group container for reading and writing, in a TestFlight-signed build, with no consent prompt?
  - Which entitlements and bundle layout does that need?
  - How does a sandboxed app put the command on the user's PATH? A development build installs the tool as `knot-dev`.
  - Does it work while the app is running, and does the app see the change?
  - How do two or three shipping Mac App Store apps deliver a CLI or an MCP server?
  - Can the sandboxed tool write to a folder the user names? If not, how does `knot export` deliver its output?
  - Where does the Mac store live?
- `docs/architecture.md` §15 states the preferred design: a sandboxed executable inside the app bundle, carrying the app-group entitlement and opening the store directly. The fallback is a CLI that talks to the running app over XPC.
- Test the two packaging rules of `docs/architecture.md` §15. A tool started from Terminal needs its own sandbox entitlements and an embedded Info.plist. A bare executable cannot carry the provisioning profile that a `group.` app group needs, so the Team-ID form or a helper bundle may be the only route.
- Settle the Mac's app-group form. Milestone builds use the app group `group.com.p3ob7o.knot` (D34), and the Mac's form stays open until SP-3 reports.
- `docs/architecture.md` §20 expects that a sandboxed command-line tool cannot write to an arbitrary folder passed as an argument. SP-3 confirms it.
- The distribution-signed check. The TestFlight upload is made under the development identifier, and runs only once the owner has handed over the API key at G1. The report includes the result of the check.
- If the direct route fails that check, the XPC route gets an internal upload of its own, and the report says what the tool does when Knot is not running. `docs/product-spec.md` §10 then follows it.
- The spike app carries the privacy manifests with their required reasons, so App Store Connect checks them in wave 1.
- The report, `docs/spikes/SP-3.md`, has a decision between direct store access and XPC to the running app.
- Where the answer changes `docs/architecture.md`, the report lists the changes it asks for. The orchestrator owns that file and makes them in a pull request of its own (PLAN.md §7).

## Merge criteria

- `docs/spikes/SP-3.md` decides between direct store access and XPC to the running app.
- It answers every question under "Build", including where the Mac store lives, the Mac's app-group form and how `knot export` delivers its output.
- It reports on both packaging rules.
- It includes the result of each distribution-signed check, and the route it chooses is one that passed.
- If the direct route failed that check, it says what the tool does when Knot is not running.
- It ends with a decision.
- Nothing from `spike/agent-access` merges to `main`. The report PR changes documents only, so the gate runs the plan check and the link check (`docs/architecture.md` §18), and both pass.

## Milestone evidence

- Gate G1, with WP-01. The owner creates an App Store Connect record for the development identifier and an API key, about 20 minutes, and hands the key over as a file path through the secret prompt.
- Each upload needs the owner's word. The key is handed over for one upload and revoked after it.
- Gate G3, after wave 1. The owner installs the SP-3 build from TestFlight and runs its check, about 15 minutes.
- Gate G3. The owner reads the report and confirms its decision. Each spike is confirmed on its own.
- M4 needs SP-3.

## Prior art

None.

## Failure rules

- If a sandboxed CLI cannot reach the store, there is no direct command-line access, and the response is XPC to the running app. The XPC route is built only if SP-3 fails in wave 1, never later.
- The spike app and its TestFlight upload keep the development identifiers, so nothing before the M1 milestone build touches the retired app or its container. Only a milestone build opens the default store or the real iCloud container.
- The SP-3 upload under the development identifier proves neither upgrade row: not the M1 install of the milestone build over the retired app, and not the M7 install of the TestFlight build over the M6 milestone build.
- Knot's own App Store Connect record, for `com.p3ob7o.knot`, is created by the owner at G5, not for this spike.
- The spike's code stays on `spike/agent-access` and is never merged.
- Read the declaration of each OS 26 or OS 27 API in the SDK before using it (`docs/architecture.md` §21), and name the declarations read in the report PR.

## Named tests

None.
