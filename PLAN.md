# Knot v1: build plan

Paolo approved this plan on 2026-11-19. The record of its reviews is in `docs/reviews/2026-11-19-plan-review.md`. `docs/plan/amendments.md` shows where each amendment went. Each package has a brief in `docs/plan/`.

This plan drives a team of agents to rebuild Knot from an empty repository. It has four parts, which are one plan and are reviewed together:

- [docs/product-spec.md](docs/product-spec.md) says what Knot v1 does.
- [docs/architecture.md](docs/architecture.md) says how it is built.
- [docs/design/brief.md](docs/design/brief.md) is the brief for Claude Design.
- This file says how the work is split, ordered, checked and merged.

An agent working on one package reads `AGENTS.md`, the product spec, the architecture, and its own brief in `docs/plan/`. Nobody needs to read every package.

## 1. Summary

- **Product.** A capture tool for Mac, iPhone, iPad and Apple Watch. You type, speak or write by hand, and everything lands in one stream. Transcription and cleanup run on-device. Sync uses CloudKit and is optional.
- **Shape of the work.** 5 spikes and 31 work packages, in five waves, and about 60 PRs before contract and fix PRs. After the serial foundation packages and the capture tracer, WP-05, up to five agents work at once, each in its own T3 Code thread and worktree.
- **How parallel work stays safe.** Contracts come first: one package defines every interface, and a fake for each port except `CaptureEngine` and `ProcessingQueue`. After that, each package owns its own folders and builds against the interfaces, so two agents rarely touch the same file.
- **What only Paolo can do.** Approve the plan, run the Claude Design round, confirm each spike's decision, test on hardware at each milestone, rule at the keep gate after M2, and authorise anything that signs for distribution or uploads. Scope leaves the build only on his word.
- **Main risks.** Five facts the design rests on are unconfirmed, so five spikes run before the packages that depend on them: recording from a locked iPhone, getting recordings off the watch, command-line access to a sandboxed app's store, the shape of CloudKit sync, and the Mac hotkey in a sandboxed build.

## 2. Decisions

These are Paolo's. D1 to D31 are from 2026-11-18, and D32 to D36 from 2026-11-19.

| ID | Decision |
|---|---|
| D1 | Knot is an inbox: one reverse-chronological stream with search. Notes can also flow out. |
| D2 | Captures less than X minutes apart append to the same note. After X minutes a new note starts. X is a user setting. |
| D3 | Knot stands alone. Obsidian is not a destination. |
| D4 | Transcription starts with English. Other languages come later. |
| D5 | The watch records and the iPhone or Mac transcribes. "No phone no notes." |
| D6 | Cleanup covers punctuation, fillers, false starts, paragraphs, lists and a title. It runs on-device for now. |
| D7 | A pencil note keeps the ink and makes the recognised text searchable and copyable. The canvas is for iPad and iPhone Duo only. |
| D8 | Photo and video come later. |
| D9 | The Mac has one hotkey: pressed, it opens the floating text panel; held, it records in that panel. The other devices follow the proposal in product spec §6. |
| D10 | Test devices: iPhone 17 Pro, the latest iPad mini with Apple Pencil Pro, Apple Watch Ultra 2, MacBook Pro, Mac Studio. |
| D11 | A database on each device, synced through CloudKit. Notes are editable only in Knot and through an MCP server or a CLI. |
| D12 | Built to App Store standard, for Paolo alone to begin with, and open source. |
| D13 | Design comes from Claude Design, from a written brief. |
| D14 | The build runs as T3 Code threads and worktrees with parallel Opus 5.5 agents. gstack reviews and refines the plan. |
| D15 | Everything in the repository goes except the icon and the licence. |
| D16 | Order: the shared core and all four app shells first, then iPhone voice and text, Watch voice, Mac hotkey, iPad Pencil. |
| D17 | Minimum OS is 27 on every platform. |
| D18 | No account, no backend, no analytics. iCloud sync may sit behind a paywall later. |
| D19 | A capture reaches disk before anything else. Recordings are kept until deleted. Pending and failed states are visible. |
| D20 | Notes are plain text with lightly styled Markdown. No rich-text editor, no web views. |
| D21 | No folders, tags, links or templates in v1. Search only. |
| D22 | On the Mac, Knot does not type into other apps. |
| D23 | Siri and Shortcuts actions exist on every platform. |
| D24 | The interface is English-only, with VoiceOver and Dynamic Type. |
| D25 | The database is the only store. There is no Markdown mirror. Notes leave through export, the CLI and the MCP server. |
| D26 | Agents push branches and open PRs. A second agent reviews. The orchestrator thread merges on green. Paolo gates milestones on hardware. Independent features get their own worktrees, so several branches are open at once. |
| D27 | Holding the Mac hotkey is push-to-talk: releasing it stops the recording. The key is set in Settings. |
| D28 | The append window defaults to 5 minutes. |
| D29 | The licence is GPL-3.0-or-later, replacing GPL-2.0. It carries an additional permission for app store distribution, and contributions are accepted on the same terms. |
| D30 | GRDB is the one third-party library, pinned to an exact version. |
| D31 | Design taste: clean lines, minimal controls, full use of what the operating system offers. The references are in the design brief. |
| D32 | M2 is a keep gate. When the M2 checklist has passed, the owner uses the M2 milestone build as his only capture tool on the iPhone for seven days. He then rules one of four ways: continue as planned, continue with cuts, revise the spec first, or stop the build. |
| D33 | A wrong grouping can be repaired. A segment can be moved to its own note, as docs/product-spec.md §7 and rule 16 of §3 state, and the app undoes the move at once. Merging notes, splitting a note at a point and moving a segment into another existing note stay out of v1. |
| D34 | Milestone builds reuse the retired app's bundle identifier, `com.p3ob7o.knot`, with the app group `group.com.p3ob7o.knot` and the iCloud container `iCloud.com.p3ob7o.knot`. The retired app does not live beside them: the first milestone build installed on a device replaces it there. The Mac's app-group form stays open until SP-3 reports. |
| D35 | The one internal TestFlight upload of the SP-3 spike app is a planned part of G1. At G1 the owner creates an App Store Connect record for the development identifier and an API key, and hands the key over. The upload runs only then. Knot's own record, for `com.p3ob7o.knot`, is created by the owner at G5. |
| D36 | The build Mac holds no real notes while the build runs. From the M4 milestone build the owner's real notes on a Mac live on his other Mac. |

## 3. Open questions

Q1 to Q8 were answered on 2026-11-18 and became D10 and D25 to D30. The owner answered the 34 assumptions of the product spec on 2026-11-19, and docs/product-spec.md §16 lists each with his answer.

Three things are still open at gate G0:

- A38, a reading of his answer on the Watch: the Watch still lists its own recent recordings, by time, length and delivery state.
- A39, a reading of his answer on selection: "select multiple segments" means whole segments, with copy, share and delete, and "Move to its own note" still takes one segment at a time.
- How many sittings a week he can give.

Both readings are in docs/product-spec.md §16. WP-02 does not start before the owner has confirmed them, because WP-02 turns them into tests. A39 is the costly one.

## 4. Scope

In v1, by device:

- **iPhone:** typing, voice with live text, the stream, search, editing, the Action Button and Lock Screen controls, widgets, Live Activity, Siri and Shortcuts.
- **iPad:** everything on iPhone, plus the Pencil canvas, a side-by-side layout and keyboard shortcuts.
- **Mac:** the one hotkey, the floating panel, hold-to-record, the main window, the menu bar item, the `knot` command and the MCP server.
- **Watch:** one-tap recording from a complication, widget, control or Double Tap, and delivery to the iPhone.
- **Everywhere but the watch:** on-device transcription and cleanup, optional iCloud sync, export.

Out of v1: see product spec §15. `TODOS.md` at the repo root holds the sixteen items deferred from v1.

### The cut order

If the build has to shrink, at the keep-gate sitting or at a later milestone sitting, scope leaves in this order, and only on the owner's word. No agent cuts scope.

1. iPad Pencil: WP-35, the rest of WP-18, the Sketch control and intent, and M5. The iPad then keeps the iPhone's layout, which it has had since M1, and has no canvas, no side-by-side layout, no hardware-keyboard shortcuts and no menu bar. Ink stays a kind the store knows, so a later version can add it without a migration.
2. System surfaces beyond the first of each kind: the Watch complication families beyond one, the Smart Stack widget, and the Home Screen and Lock Screen widgets of the iPhone. The Action Button, the controls and one complication stay.

A part that is cut is not started. The orchestrator writes each cut to `TODOS.md` with what would bring it back, and updates the briefs in `docs/plan/` and the checklists in one PR. If M5 is cut, every condition that names M5 names M4: the deployment of the CloudKit production schema, which then also needs a recording made on one device to play on the other, and the start of WP-43. Anything beyond these two steps is a new decision of the owner's.

## 5. Milestones

Each milestone is something Paolo can do on a device. Hardware checks come from `docs/checklists/`.

| ID | Name | Paolo can |
|---|---|---|
| M0 | Foundations | Read a new `main` holding the plan, the scaffold and the contracts. Read five spike reports. Hold a design brief ready for Claude Design. |
| M1 | Skeleton on four devices | Type a line on iPhone, iPad and Mac and find it in the stream after relaunch. Record on the Watch and see the capture listed on the Watch as saved. Local only, system-default look. |
| M2 | iPhone voice and text | Press the Action Button, speak, and find a cleaned, titled note. Type notes, watch the append window work, search, edit, delete and undo. Kill the app while recording and lose nothing. |
| M3 | Watch voice | Tap the complication, record with the wrist down, and find the note transcribed on the iPhone, including after the phone was away. |
| M4 | Mac and sync | Tap the hotkey to type and hold it to record, over a full-screen app. Use `knot` and the MCP server from Claude Code. See notes sync both ways between iPhone and Mac. |
| M5 | iPad Pencil | Write by hand, search the handwriting, copy it as text, and see the drawing on the Mac and iPhone. |
| M6 | Designed | See the Claude Design handoff applied on all four devices, with accessibility and speed targets met. |
| M7 | TestFlight v1 | Install Knot from TestFlight on every device. |

M1 adds no playback on the Watch, and delivery to the iPhone belongs to M3.

M2 to M5 are functional gates. WP-40 applies the design to each platform after the keep-gate ruling (§6), and M6 repeats the core rows of the M2 to M5 checklists after the design is applied.

### Milestone builds

A milestone build is made from `main` in a fresh worktree by the thread of the owning package:

<!-- milestone-needs:begin -->
| Milestone | Owning package | Also needs |
|---|---|---|
| M1 | WP-22 PR 1 | WP-05; WP-06; WP-10 PR 1; WP-12 PR 1; WP-17 PR 1; WP-21 PR 1; WP-30 PR 1; WP-32 PR 1; WP-33 PR 1 |
| M2 | WP-30 PR 2 | WP-11; WP-13; WP-14; WP-15 PR 2; WP-19 PR 2; WP-31 PR 1; WP-22 PR 2; SP-1; the design direction |
| M3 | WP-32 PR 2 | WP-17 PR 2; WP-19 PR 3; SP-2 |
| M4 | WP-33 PR 2 | WP-16; WP-34 PR 3; SP-3; SP-4; SP-5 |
| M5 | WP-35 | WP-18; WP-16; WP-19 PR 4; WP-31 PR 2 |
| M6 | WP-40 | WP-40a; WP-40b; WP-40c; WP-40d; WP-41; WP-42; WP-32 PR 3; WP-31 PR 2 if M5 is cut |
| M7 | WP-43 | WP-44; M6; WP-40a; WP-40b; WP-40c; WP-40d; WP-41; WP-42 |
<!-- milestone-needs:end -->

If M5 is cut, the second PR of WP-31 loses the Sketch control and M6 needs it. M7 needs the evidence of every milestone before it: the release script refuses a candidate that lacks any.

- **Identifiers.** Milestone builds use `com.p3ob7o.knot`, with its app group and its iCloud container (D34). They carry a version above 0.2.0, which is the retired app's. Every build that is not a milestone build uses development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. That covers agent builds, PR builds, spikes and tests, and the TestFlight upload of the SP-3 spike app, so nothing before the M1 milestone build touches the retired app or its container. Only a milestone build opens the default store or the real iCloud container.
- **Levels.** Every milestone build, and every fix built for an earlier milestone, is made at a level from M1 to M7. A feature whose milestone has not passed is switched off in it by a gate: sync and the command line open at M4, and ink at M5. A fix made for M2 during the keep-gate week therefore carries nothing from M3 or M4.
- **Real notes.** Notes on the owner's iPhone and iPad are disposable until the M2 milestone build, and notes on his Mac until the M4 milestone build, which needs SP-3's answer on where the Mac store lives. After those builds, every change to the schema or to the store's location ships a tested migration. Schema version 1 is the schema of the M2 milestone build. Every change after that build is a numbered migration, whichever package makes it, the second PR of WP-10 included.
- **At each milestone.** The capture ledger soak runs, and `scripts/verify.sh --perf` measures the timed targets (§9). At each milestone tag a seeded synthetic store made by that build is committed. It holds work in flight: an open capture, a queued job and a pending delete. Every later build opens it, migrates it and passes the whole `NoteStore` contract suite on it.
- **The retired app.** The first milestone build installed on a device replaces the retired app there. Before that install, on every device that had the retired app, the owner clears its Recovery window of drafts, pending captures and outcomes that need review, keeps a copy of the retired app, and quits it. If something was missed, that copy still opens its store, which v1 leaves untouched.
- **Upgrades.** The upgrade rows name what they install over. At M1 the milestone build, signed for development as `com.p3ob7o.knot`, is installed over the retired app, and the row checks that the retired app's folder is still there. At M7 the TestFlight build is installed over the M6 milestone build, which has the same identifier and development signing. The SP-3 upload under the development identifier proves neither.
- **The build Mac.** From the M4 milestone build on, no milestone build is installed or run on the build Mac, because a milestone build with sync open would bring the owner's notes onto it (D36). For a Mac, `scripts/install.sh` writes the build to a folder the owner names, and he opens it there. The M4 checklist names the Mac for each row. The owner's recordings in `KNOT_LOCAL_FIXTURES` stay on the build Mac: they are recordings he makes for the build and chooses himself, not notes from his stream.
- **M4.** The M4 sitting passes its two-device rows on development builds first, in the development container. The M4 milestone build then opens sync on the owner's notes, after an export of the iPhone's store.
- **The production schema.** The CloudKit production schema is deployed only after M5, when two-device sync and attachment sync have passed on hardware with development builds. The move from the development environment to production is rehearsed between two development containers before M7, and the M7 checklist starts with an export of the store on each device.

### The keep gate

M2 is a keep gate (D32). When the M2 checklist has passed, the owner uses the M2 milestone build as his only capture tool on the iPhone for seven days. The week runs on that build as it is, in the system look and with the structure of the chosen direction. A fix found during the week ships as a new M2 build with a tested migration, because his iPhone notes are real from M2 on.

The week ends with the keep-gate sitting, about 30 minutes. The owner brings the diagnostics export from About, which gives the week's counts without any note text: captures a day by kind, captures that failed or stayed pending, uses of "New note", and segments moved to their own note. He answers five questions in writing: did he reach for Knot, was anything lost or stuck, was the grouping right, did the notes get used, and would he go back to what he used before. He then rules one of four ways: continue as planned, continue with cuts, revise the spec first, or stop the build. Cuts follow the cut order of §4.

The orchestrator records the answers and the ruling in `docs/decisions/keep-gate.md` and turns his notes into changes to docs/product-spec.md, each through a contract PR where it reaches KnotCore. No "handled" mark is added in v1. The mark is looked at again at this sitting.

Until the ruling, the parts that the cut order names are held (§6).

## 6. Waves and dependencies

| Wave | Starts when | Packages that can run in parallel |
|---|---|---|
| 0 | The plan is approved | WP-00, then WP-01, then WP-02, in series. The second PR of WP-01 runs beside WP-02. Alongside them: WP-03 and WP-04. |
| 1 | The first PR of WP-01 and WP-04 are merged | SP-1, SP-2, SP-3, SP-4, SP-5 |
| 2 | WP-05 is merged | WP-10, WP-11, WP-12, WP-13, WP-14, WP-15, WP-18, WP-20, WP-21, and the text intents of WP-19 |
| 3 | Its own dependencies land | WP-16, WP-17, WP-22, WP-30, WP-31, WP-32, WP-33, WP-34, WP-35, and the recording, watch and sketch intents of WP-19 |
| 4 | The keep-gate ruling, and then each package's own start conditions | WP-40, WP-41, WP-42, WP-43; WP-44 runs from M1 onward |

Wave 0 is reset and foundations, wave 1 spikes, wave 2 modules, wave 3 integration and apps, and wave 4 design and hardening.

WP-05, the capture tracer, starts after the second PR of WP-02 and comes before wave 2. WP-06, the soak harness, starts after WP-05 and the first PR of WP-10. The proof steps of WP-12, WP-13, WP-14 and WP-18, and the code half of each spike, start beside the first PR of WP-02 (§7).

With five threads at a time, wave 2 starts in this order, which follows D16: WP-10, WP-21, WP-12, WP-11, WP-13, then WP-14, WP-15, WP-19, WP-18, WP-20. All of WP-20 may run earlier, beside WP-05. In WP-18, everything after the proof step waits for the keep-gate ruling.

The longest chain to M2 is WP-00, the first PR of WP-01, the first two of WP-02 with the proof steps beside them, WP-05, the first PR of WP-10, the modules, the second PR of WP-22 and the second of WP-30. A second chain runs through the third PR of WP-02, which waits for the short notes of the spikes and not for their reports, and the second PRs of WP-21 and WP-30. A third also gates M2: the first PR of WP-01, SP-1 with the owner's confirmation, then the second PRs of WP-15 and WP-19, then the first PR of WP-31. A fourth is the design direction, which the second PR of WP-30 waits for. No chain to M2 waits for the report of SP-2, SP-3 or SP-4. M2 needs the second PR of WP-22, although the second PRs of WP-30 and WP-33 do not wait for it.

The design chain runs beside them: WP-03, the direction step, the full Claude Design round, the accepted handoff, WP-40.

Sizes: S is under about 500 lines including tests. M is 500 to 2,000. L is larger, and ships as at least two PRs, the first being the thinnest slice that works end to end against real interfaces. The plan has 31 work packages, five spikes and about 60 PRs before contract and fix PRs.

### Start conditions

Each brief says what its package starts after, with one row for each PR. This table is generated from the headers of the briefs.

<!-- start-table:begin -->

| Package | PR | What it holds | Starts after |
|---|---|---|---|
| WP-00 | 1 | The restart | the plan's approval |
| WP-00 | 2 | The fold | WP-00 PR 1 |
| WP-01 | 1 | The scaffold that unblocks WP-02 and the spikes | WP-00 PR 2 |
| WP-01 | 2 | The tooling, beside WP-02 | WP-01 PR 1 |
| WP-02 | 1 | The domain types, rules and reducers | WP-01 PR 1; the owner's confirmation of A38 and A39 |
| WP-02 | 2 | The ports, fakes and suites the tracer needs | WP-02 PR 1; WP-12 proof step; WP-13 proof step; WP-14 proof step |
| WP-02 | 3 | The remaining ports, fakes and suites | WP-02 PR 2; WP-18 proof step; SP-1 notes; SP-2 notes; SP-4 notes |
| WP-03 | 1 | The brief as Paolo approves it | the plan's approval |
| WP-04 | 1 | The fixtures and the checklists | WP-00 PR 2 |
| WP-05 | 1 | The thinnest real engine and queue, one end-to-end test and the preview environment | WP-02 PR 2 |
| WP-06 | 1 | The soak harness, covering typed captures first | WP-05; WP-10 PR 1 |
| SP-1 | Notes | The code half, a minimal app on `spike/locked-recording`, and its short note | WP-01 PR 1; WP-04 |
| SP-1 | 1 | The report, `docs/spikes/SP-1.md`, which ends with a decision | SP-1 notes |
| SP-2 | Notes | The code half on `spike/watch-delivery`, and its short note | WP-01 PR 1; WP-04 |
| SP-2 | 1 | The report, `docs/spikes/SP-2.md`, which ends with a decision | SP-2 notes |
| SP-3 | Notes | The code half on `spike/agent-access`, and its short note | WP-01 PR 1; WP-04 |
| SP-3 | 1 | The report, `docs/spikes/SP-3.md`, which ends with a decision | SP-3 notes |
| SP-4 | Notes | The code half on `spike/sync-shape`, and its short note | WP-01 PR 1; WP-04 |
| SP-4 | 1 | The report, `docs/spikes/SP-4.md`, which holds the final CloudKit schema and ends with a decision | SP-4 notes |
| SP-5 | Notes | The code half on its `spike/…` branch, and its short note | WP-01 PR 1 |
| SP-5 | 1 | The report, which ends with a decision | SP-5 notes |
| WP-10 | 1 | The store that M1 and M2 run on: everything but the second-process rules and the sync columns | WP-05 |
| WP-10 | 2 | The second-process rules, the sync columns, the interface for sync and device identity | SP-3; SP-4; WP-02 PR 3 |
| WP-11 | 1 | The whole package | WP-05 |
| WP-12 | Proof step | The format proof, and a short note saying whether the draft `Recorder` port fits the real API's streaming, cancellation and errors | WP-01 PR 1; WP-04 |
| WP-12 | 1 | The format proof and a recorder that records and stops on every platform | WP-05 |
| WP-12 | 2 | Everything else | WP-12 PR 1; WP-02 PR 3 |
| WP-13 | Proof step | Transcription of the fixtures and of the owner's recordings, the Simulator probe, and a short note saying whether the draft `Transcriber` port fits the real API's streaming, cancellation and errors | WP-01 PR 1; WP-04 |
| WP-13 | 1 | The whole package | WP-05 |
| WP-14 | Proof step | The fidelity guard as a pure function with tests, ten cleanup pairs from the owner's recordings, and a short note saying whether the draft `Cleaner` port fits the real API's streaming, cancellation and errors | WP-01 PR 1; WP-04 |
| WP-14 | 1 | The whole package | WP-05 |
| WP-15 | 1 | The job queue, the inbox ingestor and the published states | WP-05 |
| WP-15 | 2 | The hooks for background execution on iOS | SP-1 |
| WP-16 | 1 | The whole package | WP-10 PR 2 |
| WP-17 | 1 | The outbox, and the coordinator that records, converts and sends | WP-02 PR 2 |
| WP-17 | 2 | The transport | SP-2; WP-02 PR 3 |
| WP-18 | Proof step | Recognition of the ink fixtures, and a short note saying whether the draft `InkRecogniser` port fits the real API's streaming, cancellation and errors. It runs early and is not held. | WP-01 PR 1; WP-04 |
| WP-18 | 1 | Everything after the proof step. Held until the keep-gate ruling. | WP-18 proof step; the ruling; WP-05; WP-02 PR 3 |
| WP-19 | 1 | The text intents | WP-05 |
| WP-19 | 2 | The recording intents for iPhone, iPad and Mac, with OpenCapture and OpenSearch | SP-1; WP-02 PR 3 |
| WP-19 | 3 | The watch intents | SP-2 |
| WP-19 | 4 | The OpenSketch intent. Held until the keep-gate ruling. | the ruling |
| WP-20 | 1 | The whole package | WP-02 PR 2 |
| WP-21 | 1 | A skeleton that does not depend on the design direction: the theme layer, the view models with their tests, and the components | WP-05 |
| WP-21 | 2 | The structure of the direction's sheets, what rests on the contracts of WP-02 PR 3, and a named preview for every designed cell of the state matrix | the design direction; WP-02 PR 3 |
| WP-22 | 1 | The composition | WP-05; WP-10 PR 1 |
| WP-22 | 2 | The end-to-end suite | WP-10 PR 1; WP-15 PR 1; WP-11; WP-12 PR 2; WP-13; WP-14 |
| WP-30 | 1 | A skeleton that does not depend on the design direction: a line typed on the iPhone or the iPad is found in the stream after relaunch | WP-21 PR 1 |
| WP-30 | 2 | The iPhone app, built from the direction's structure sheet | the design direction; WP-21 PR 2; WP-22 PR 1 |
| WP-31 | 1 | The controls, the Live Activity and the Action Button tip | SP-1; WP-19 PR 2 |
| WP-31 | 2 | The Sketch control and the Home Screen and Lock Screen widgets. Held until the keep-gate ruling. | the ruling |
| WP-32 | 1 | A skeleton that does not depend on the design direction: the owner records on the Watch and sees the capture listed on the Watch as saved | WP-12 PR 1; WP-17 PR 1; WP-21 PR 1 |
| WP-32 | 2 | The Watch app, built from the direction's structure sheet, with its first complication family and its control | SP-2; the design direction; WP-17 PR 2; WP-19 PR 3; WP-21 PR 2 |
| WP-32 | 3 | The complication families beyond the first and the Smart Stack widget. Held until the keep-gate ruling. | the ruling |
| WP-33 | 1 | A skeleton that does not depend on the design direction: a line typed on the Mac is found in the stream after relaunch | WP-21 PR 1 |
| WP-33 | 2 | The Mac app, built from the direction's structure sheet: the hotkey, the panel, hold-to-record, the menu bar item, the main window and Settings | the design direction; SP-5; WP-21 PR 2; WP-22 PR 1 |
| WP-34 | 1 | `status`, `add`, `list`, the error contract and the access switch | WP-05 |
| WP-34 | 2 | The other commands | WP-10 PR 2; WP-20 |
| WP-34 | 3 | The MCP server, and the embedding of the tool in the Mac app | WP-34 PR 2; SP-3 for the embedding |
| WP-35 | 1 | The whole package, built from the direction's structure sheet for the iPad. Held until the keep-gate ruling. | the ruling; WP-18 PR 1; WP-21 PR 2; WP-30 PR 2 |
| WP-40 | 1 | The theme: the tokens translated from the handoff, and `DESIGN.md` | the ruling; the accepted handoff |
| WP-40 | 40a | The iPhone's screens matched to the handoff | the ruling; the accepted handoff; WP-40 PR 1; WP-30 PR 2 |
| WP-40 | 40b | The iPad's screens matched to the handoff | the ruling; the accepted handoff; WP-40 PR 1; WP-35 |
| WP-40 | 40c | The Mac's screens matched to the handoff | the ruling; the accepted handoff; WP-40 PR 1; WP-33 PR 2 |
| WP-40 | 40d | The Watch's screens matched to the handoff | the ruling; the accepted handoff; WP-40 PR 1; WP-32 PR 3 |
| WP-41 | 1 | The audit made clean, and the accessibility behaviour confirmed | the ruling; WP-40a; WP-40b; WP-40c; WP-40d |
| WP-42 | 1 | The measurements, and the report that sets them against the targets | the ruling; WP-22 PR 2 |
| WP-43 | 1 | The release script, the privacy manifest, the audit, the icon sets, the documents and the notices | the ruling; M5 or, if M5 is cut, M4 |
| WP-44 | Campaign | QA at each milestone, continuously from M1 | M1 |

<!-- start-table:end -->

These rules sit beside the table:

- A PR starts when everything in its row has merged.
- A spike counts when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names.
- A row that waits for notes waits for the short note of a spike or of a proof step (§7), and not for the report.
- "The ruling" is the keep-gate ruling (§5).
- A row names the PR wherever a package ships in several. Elsewhere, a package named without a number means its last PR.
- The PRs of WP-11, WP-12 and WP-15 that add kill points merge after WP-06.
- `scripts/check-plan.sh` fails on a cycle, on a row that names a package without a PR where the package has several, and on a milestone that needs a held PR.

### The hold until the ruling

Until the keep-gate ruling, nothing that the cut order names is built, and wave 4 does not start. That holds back WP-35; everything in WP-18 after its proof step; the Sketch control of WP-31 and the OpenSketch intent of WP-19; the Home Screen and Lock Screen widgets of WP-31; WP-32's complication families beyond the first and its Smart Stack widget; and WP-40, WP-41, WP-42 and WP-43.

The hold names PRs, so that no milestone waits for a held part. Each held part of WP-19, WP-31 and WP-32 is that package's last PR:

- WP-19's fourth PR is the OpenSketch intent.
- WP-31 ships in two PRs. The first has the controls, the Live Activity and the Action Button tip. The second, held, has the Sketch control and the Home Screen and Lock Screen widgets.
- WP-32 ships in three PRs. Its third, held, has the complication families beyond the first and the Smart Stack widget.

WP-18's proof step still runs early, because WP-02's third PR waits for its note, and the ink types stay in WP-02's contracts. WP-44 keeps running from M1, and the work for M3 and M4 goes on during the week. Seven days pass between the M2 checklist and the start of M5 and wave 4 work.

If the full design round has run by the ruling, the orchestrator lists what the ruling changes in `docs/design/deltas.md` and sends that list to the designer, as it does for a gap.

### The design track

The design direction comes first. Right after the plan is approved, the owner runs the brief's direction step in Claude Design, described in docs/design/brief.md §9, and chooses a direction for the iPhone capture surface and the Mac panel. The orchestrator records the choice in `docs/design/direction.md`, and docs/architecture.md §16 says what that file holds. The design may propose another editing model in the direction step, and the owner must accept it before code depends on it.

The first PRs of WP-21, WP-30, WP-32 and WP-33 are skeletons that do not depend on the direction. The second PRs of WP-21, WP-30, WP-32 and WP-33, and all of WP-35, build from its structure sheets and wait for it.

The full design round follows the direction, and its handoff is committed to `docs/design/handoff/`. The round does not wait for the spikes, because the brief asks for both branches of the three surfaces a spike still decides.

Before WP-40 starts, the orchestrator checks the handoff against the state matrix of docs/design/brief.md §6. Gaps go back to the designer as a list, not as a second round. The handoff that has passed this check is the accepted handoff of the start conditions. WP-40a to WP-40d each start after their platform's app package has merged, and own that platform's views from then on. Where the design changes structure, the orchestrator lists each difference in `docs/design/deltas.md` and assigns it. docs/architecture.md §16 holds these rules in full.

## 7. Work packages

Each package has a brief in `docs/plan/`: one file per package, named by its ID, such as `docs/plan/WP-10.md` or `docs/plan/SP-3.md`. Every brief has the same fixed headings: goal, owns, starts after, build, merge criteria, milestone evidence, prior art, failure rules and named tests. Paths in a brief are relative to the repository root and include the package's tests.

<!-- package-index:begin -->

| Package | Name | Size | Wave | Run by | Brief |
|---|---|---|---|---|---|
| WP-00 | Restart PR | S | 0 | The orchestrator | [docs/plan/WP-00.md](docs/plan/WP-00.md) |
| WP-01 | Scaffold | L | 0 | Its own thread | [docs/plan/WP-01.md](docs/plan/WP-01.md) |
| WP-02 | Contracts and fakes | L | 0 | Its own thread | [docs/plan/WP-02.md](docs/plan/WP-02.md) |
| WP-03 | Design brief | S | 0 | Its own thread | [docs/plan/WP-03.md](docs/plan/WP-03.md) |
| WP-04 | Fixtures and device checklists | S | 0 | Its own thread | [docs/plan/WP-04.md](docs/plan/WP-04.md) |
| WP-05 | Capture tracer | M | Before wave 2 | Its own thread | [docs/plan/WP-05.md](docs/plan/WP-05.md) |
| WP-06 | Soak harness | S | Not numbered | Its own thread | [docs/plan/WP-06.md](docs/plan/WP-06.md) |
| SP-1 | Recording from a locked iPhone | S | 1 | Its own thread | [docs/plan/SP-1.md](docs/plan/SP-1.md) |
| SP-2 | Watch capture and delivery | S | 1 | Its own thread | [docs/plan/SP-2.md](docs/plan/SP-2.md) |
| SP-3 | Command-line access to the store | S | 1 | Its own thread | [docs/plan/SP-3.md](docs/plan/SP-3.md) |
| SP-4 | CloudKit sync shape | M | 1 | Its own thread | [docs/plan/SP-4.md](docs/plan/SP-4.md) |
| SP-5 | The Mac hotkey in a sandboxed build | S | 1 | Its own thread | [docs/plan/SP-5.md](docs/plan/SP-5.md) |
| WP-10 | Store | L | 2 | Its own thread | [docs/plan/WP-10.md](docs/plan/WP-10.md) |
| WP-11 | Capture engine | M | 2 | Its own thread | [docs/plan/WP-11.md](docs/plan/WP-11.md) |
| WP-12 | Recorder | L | 2 | Its own thread | [docs/plan/WP-12.md](docs/plan/WP-12.md) |
| WP-13 | Speech | M | 2 | Its own thread | [docs/plan/WP-13.md](docs/plan/WP-13.md) |
| WP-14 | Cleanup | M | 2 | Its own thread | [docs/plan/WP-14.md](docs/plan/WP-14.md) |
| WP-15 | Processing and ingest | M | 2 | Its own thread | [docs/plan/WP-15.md](docs/plan/WP-15.md) |
| WP-16 | Sync | L | 3 | Its own thread | [docs/plan/WP-16.md](docs/plan/WP-16.md) |
| WP-17 | Watch link | M | 3 | Its own thread | [docs/plan/WP-17.md](docs/plan/WP-17.md) |
| WP-18 | Ink | M | 2 | Its own thread | [docs/plan/WP-18.md](docs/plan/WP-18.md) |
| WP-19 | Intents | M | 2 and 3 | Its own thread | [docs/plan/WP-19.md](docs/plan/WP-19.md) |
| WP-20 | Export | S | 2 | Its own thread | [docs/plan/WP-20.md](docs/plan/WP-20.md) |
| WP-21 | UI foundation | L | 2 | Its own thread | [docs/plan/WP-21.md](docs/plan/WP-21.md) |
| WP-22 | Composition and end to end | M | 3 | Its own thread | [docs/plan/WP-22.md](docs/plan/WP-22.md) |
| WP-30 | iPhone app | L | 3 | Its own thread | [docs/plan/WP-30.md](docs/plan/WP-30.md) |
| WP-31 | iPhone system surfaces | M | 3 | Its own thread | [docs/plan/WP-31.md](docs/plan/WP-31.md) |
| WP-32 | Watch app | L | 3 | Its own thread | [docs/plan/WP-32.md](docs/plan/WP-32.md) |
| WP-33 | Mac app | L | 3 | Its own thread | [docs/plan/WP-33.md](docs/plan/WP-33.md) |
| WP-34 | CLI and MCP | L | 3 | Its own thread | [docs/plan/WP-34.md](docs/plan/WP-34.md) |
| WP-35 | iPad | M | 3 | Its own thread | [docs/plan/WP-35.md](docs/plan/WP-35.md) |
| WP-40 | Design system | L | 4 | Its own thread | [docs/plan/WP-40.md](docs/plan/WP-40.md) |
| WP-41 | Accessibility | M | 4 | Its own thread | [docs/plan/WP-41.md](docs/plan/WP-41.md) |
| WP-42 | Performance | M | 4 | Its own thread | [docs/plan/WP-42.md](docs/plan/WP-42.md) |
| WP-43 | Release readiness | M | 4 | Its own thread | [docs/plan/WP-43.md](docs/plan/WP-43.md) |
| WP-44 | QA campaign | Not sized | 4 | Its own thread | [docs/plan/WP-44.md](docs/plan/WP-44.md) |

<!-- package-index:end -->

The rules below hold for a whole wave or for every package.

### Merge criteria and milestone evidence

A package's "Done when" list is the merge criteria of its brief, and it holds only checks an agent can run. The criteria name `scripts/verify.sh --quick`, never a bare `swift test`. Lines that need the owner, hardware or the real iCloud service are milestone evidence. They close at the milestone, not at merge.

### Spikes

A spike answers questions. Its code stays on its `spike/…` branch and is never merged. Its report merges to `docs/spikes/`, ends with a decision, and updates architecture.md where the answer changes it.

A spike counts as finished when its report has merged and the owner has confirmed its decision. The code half of each spike starts with the proof steps, and files the same short note. A spike uses the development identifiers, like every build that is not a milestone build.

### Proof steps

WP-12, WP-13, WP-14 and WP-18 each begin with a proof step. It is the first thing the package does, and its brief says what it must show.

Proof comes before contracts. The proof steps, and the code half of each spike, start beside the first PR of WP-02. They need only the first PR of WP-01 and WP-04, and SP-5 needs only the first PR of WP-01. Each files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. A note is the file `docs/notes/<ID>.md`, merged by a pull request that holds nothing else, and a row that waits for notes starts when that pull request has merged. The second PR of WP-02 waits for the notes of WP-12, WP-13 and WP-14, and its third for the note of WP-18 and for those of SP-1, SP-2 and SP-4.

### Prior art

Some briefs name prior art: archived code to read before writing. All of it is on the branch `archive/main-before-restart-2026-11-18`. Prior art is read, not copied. Each PR description names what it read.

### Failure rules and named tests

Failure behaviour is fixed in docs/architecture.md, and each rule has an owner. A brief lists the rules its package owns. It also lists the tests that docs/architecture.md §17 requires of its package by name.

### The state matrix

Each UI package's build list names the cells it implements, from the state matrix that ends docs/design/brief.md §6.

## 8. Running the team in T3 Code

### 8.1 Roles

| Role | Who | Does |
|---|---|---|
| Orchestrator | The T3 Code thread that wrote this plan | Launches package threads, tracks status, arranges reviews, merges. |
| Implementer | One thread per package, on Claude Opus 5.5, in its own worktree | Builds one package and opens its PR. |
| Reviewer | One fresh thread per PR | Reviews the diff against the package's brief and `AGENTS.md`. |
| Paolo | | Approves the plan and passes the gates in §10. |

### 8.2 Launching a package

- One top-level thread per package, created with `t3_thread_launch`.
- Workspace: a new worktree from `origin/main`, on branch `wp/<number>-<slug>`. A PR stacked on unmerged work of its own package starts from that local branch instead. Stacking happens only inside one package.
- Builds: tests and agent builds use a local build configuration that keeps the sandbox and leaves out the entitlements that need the owner's signing profile, with sync off. The signing team's ID stays out of the repository: `KNOT_LOCAL_CONFIG` names the local file that holds it, beside `KNOT_LOCAL_FIXTURES`.
- Model: `claude-opus-5-5`. Effort `high` by default, and `xhigh` for WP-10, WP-12 and WP-16, where a mistake loses data.
- Every thread started for an agent exports `KNOT_AGENT=1`.
- First message: the prompt in Appendix B.

### 8.3 What a thread hands back

Its final message states what was built, what was verified and how, what remains unverified because it needs hardware, and any departure from the brief. Its last line is `RESULT ok` with the PR, the head and the verify summary, or `RESULT blocked` with one code, the pushed branch, what it needs and how to resume. The codes are `baseline_red`, `brief_wrong`, `needs_contract_change`, `needs_shared_file`, `needs_owner`, `needs_hardware` and `tool_failure`.

A thread that finds its brief wrong or blocked stops and says so. It does not widen its scope.

### 8.4 Review and merge

1. The implementer runs `scripts/bootstrap.sh` and `scripts/verify.sh --quick` before it changes anything, and stops if that baseline is red. The first PR of WP-01 is the exception (Appendix B).
2. The implementer runs `scripts/verify.sh --quick` before opening the PR.
3. A reviewer thread runs gstack `/review` on the PR. WP-02, WP-05, WP-06, WP-10, WP-11, WP-12, WP-15, WP-16 and WP-17 also get a second opinion from a different model through `/codex`.
4. The implementer fixes the findings. After two rounds, the orchestrator decides what is left. Every finding the orchestrator sets aside is written in the PR and in the journal.
5. The orchestrator takes the PR into its merge queue. It rebases the branch on `main`, runs the merge gate, `scripts/verify.sh --gate`, on that head, and squash-merges. Until the second PR of WP-01 merges, the gate is `--quick` (§9). After the queue has rebased a branch, its thread resets to the remote branch before it changes anything else.
6. The orchestrator removes the worktree.

The orchestrator runs a serial queue and binds each result to a base, a head and a tree. Merges follow the dependency order in §6, inside the queue's own order. The merge gate, the merge queue and the orchestrator's state follow docs/architecture.md §18.

### 8.5 Contracts and shared files

- A change to KnotCore's public API goes in its own small PR on a `contract/…` branch, with the fakes updated. The orchestrator merges it first and tells the threads that depend on it to rebase. A contract PR that only adds merges in the normal queue. One that breaks keeps the two fixed times a day of docs/architecture.md §18.
- `Package.swift`, `project.yml`, `AGENTS.md`, `PLAN.md`, `docs/plan/`, `docs/reviews/`, `docs/orchestrator.md`, `docs/product-spec.md` and `docs/architecture.md` belong to the orchestrator. So does `scripts/` after WP-01 merges, and `docs/checklists/` after WP-04 merges. A package that needs a change there asks for it in its PR description.
- A package edits only the paths it owns, and the gate checks that. Path ownership has stated exceptions:
  - The first PR of WP-01 creates the first files of every module folder: an empty target with one trivial test, the module's live entry point, the crash hosts and the environment factory. It also declares `AppEnvironment` in KnotCore with its `.unavailable` value and nothing else, because the factory returns that value. Each folder belongs to its package from then on.
  - `scripts/release.sh` belongs to WP-43, though the rest of `scripts/` passes to the orchestrator after WP-01.
  - WP-35 owns `Apps/iOS/Ink/`, the canvas screens shared by the iPad and a Pencil-capable iPhone.
  - WP-05 owns `Packages/KnotKit/Sources/KnotFakes/Preview/`.
  - WP-13 owns `Fixtures/results/speech/` and WP-14 owns `Fixtures/results/cleanup/`, inside WP-04's `Fixtures/`. Each commits its synthetic results there.
  - A proof step and the code half of a spike each own their short note, `docs/notes/<ID>.md`.
  - WP-06 owns the soak step of `scripts/verify.sh`. WP-11, WP-12 and WP-15 each add one file of kill points to `Packages/KnotKit/Tests/KnotSoak/` in their own PRs.
  - WP-40's ownership extends to the view models that a difference listed in `docs/design/deltas.md` touches. Where the handoff is silent, the implementer uses the system default and adds a line to that file, which the owner clears at M6.
- The README links to setup, the command reference, contributing and recovery. A changelog is kept from M4, with a section for the command line.

### 8.6 Limits

- Five implementer threads at a time, to start with. The machine has 16 cores and 48 GB of memory.
- Three heavy builds at a time, enforced by `scripts/build-slot.sh`. One slot is kept for the gate, Mac UI tests queue on one exclusive slot, and the script also limits how many simulators are booted at once.
- Worktrees are removed after merge, with `scripts/worktree-remove.sh`. Each holds several gigabytes of build products. Removing a worktree also removes its simulators and its development store.

### 8.7 Status

`docs/status.md` is one table, with a column each for the package, its state, its thread, its PR and its milestone evidence. `scripts/status.sh` prints it, and it is written to `main` only at milestones. Only the orchestrator edits it.

The orchestrator's state is rebuilt from the briefs, GitHub and a journal outside the worktrees, as docs/architecture.md §18 describes. A fresh thread takes over at M1 as a drill.

## 9. Checks

A PR is done when all of these hold:

- Its brief's merge criteria are met, with the evidence in the PR description.
- `scripts/verify.sh --gate` passes on the head that the queue rebased.
- New behaviour has tests. Storage, capture, ingest and sync have failure-path tests.
- No note text, transcript or audio appears in logs, test output or fixtures.
- Any OS 26 or OS 27 API used is named in the PR with the declaration that was read (architecture §21).
- Anything that could not be verified without hardware is listed, and has a row in a checklist.
- Where it changes the cleanup instructions, the guard or the speech settings, it reruns the synthetic evaluation, `knot-eval --set synthetic`, and states the results before and after. For a PR that touches speech or cleanup, the orchestrator runs the local evaluation, on the owner's recordings, at the gate and records the numbers.

**The merge gate.** The merge gate is `scripts/verify.sh --gate` on the orchestrator's Mac. It builds with the release Xcode that the owner installs at G1. It picks its depth from the diff by a fixed table and refuses a partial run: `--skip mac-ui` exists for implementers, and the gate refuses it. The table, and the checks that every depth starts with, are in docs/architecture.md §18. The gate requires both on-device models on the Mac and fails on a skipped model test. In the iOS Simulator it uses the scripted transcriber, because the real one is not available there. Until the second PR of WP-01 merges, the gate is `--quick`, listed as an exception in `scripts/gate-steps.txt`.

After G1 and SP-3, the gate has one development-signed step for a PR that touches KnotAgent, `knot`, the Mac app or KnotStore: the sandboxed app and `knot-dev` share a store, the tool writes and the app shows it. From the deployment of the production schema on, the CloudKit schema is a committed file, and the gate fails on a change to it that is not additive.

**The soak.** The capture ledger soak runs under `scripts/verify.sh --soak`, on the harness that WP-06 builds. It runs at each milestone, and in the merge gate of any PR that touches the paths docs/architecture.md §17 lists, where `--gate` adds it from the diff. When the soak fails it prints its seed, its kill point and where the store was kept, and a soak failure is never retried to green.

**Tests.** Package tests use Swift Testing and UI tests use XCTest, as docs/architecture.md §17 states. Every port has a named implementer. Each real implementation of a port passes the contract suite of that port, where the suite can run. Tests required by name are listed in docs/architecture.md §17, each with its owner in `docs/plan/named-tests.txt`, and the gate fails when a listed test is missing once its package has merged. No automated test and no agent opens a hardware microphone on the build Mac, so start latency on a real microphone is measured at the owner's sittings.

**Thresholds.** The gate checks no accuracy threshold: thresholds belong to the package PRs that own them and to the milestones. Time thresholds are not merge criteria either. The gate asserts query plans and operation counts, and `scripts/verify.sh --perf` measures times at milestones and in WP-42, following the protocol in docs/product-spec.md §14.

**Availability.** The deployment target is 27.0. An API that first shipped in 27.1 or later is guarded or raises the stated minimum, and code must compile with the release Xcode installed at G1.

**Evaluation.** The synthetic cleanup and speech results are committed with the fixtures. A contributor's PR reruns the synthetic evaluation, and a meaning-critical case that passed and now fails blocks the PR. The orchestrator runs the local evaluation, on the owner's recordings, at the gate for a PR that touches speech or cleanup, and records the numbers.

**The nightly run.** The nightly run on `main` executes the package tests under Thread Sanitizer, and reports a model that changed with an update of the operating system. docs/architecture.md §18 says what else it runs.

**The scripts.** `scripts/verify.sh`, `scripts/build-slot.sh`, `scripts/install.sh`, `scripts/release.sh` and `knot-eval` follow docs/architecture.md §18. A verify run takes one tier, runs `scripts/doctor.sh` first and ends with one summary line. A failed step names its log and its rerun command.

**The plan check.** `scripts/check-plan.sh` checks the plan itself. It fails while `PLAN.md` still holds an amendment list, when a brief lacks a heading or still holds a quote that was replaced, and unless every item of the five amendment lists appears once in `docs/plan/amendments.md`. Its checks on the start conditions are in §6.

gstack reviews of the plan came first: `/plan-ceo-review` for scope, `/plan-eng-review` for architecture, tests and parallel lanes, `/plan-design-review` for the spec and the brief, and `/plan-devex-review` for the CLI and MCP. `/autoplan` ran them in sequence. Their record is in `docs/reviews/2026-11-19-plan-review.md`.

## 10. What Paolo does

| Gate | When | What | Minutes |
|---|---|---|---|
| G0 | Now | Confirm the two readings A38 and A39 in docs/product-spec.md §16, and say how many sittings a week he can give. The rest of G0 is done: on 2026-11-19 he approved the plan, gave the answers that became D32 to D36, and answered the 34 assumptions. | 30 |
| G0 | Wave 0 | Approve the restart PR and the licence wording. The restart merged on 2026-11-19 as pull request 10. | 15 |
| G2 | Wave 0 | Review the brief, run the Claude Design direction step, choose a direction | 60 |
| G1 | With WP-01 | Confirm the identifiers, both the milestone set and the development set; install a release Xcode; pair the five devices for development builds; enable Automation Mode and developer mode once, with the two commands `scripts/doctor.sh` prints | 65 |
| G1 | With WP-01 | Extend the ruleset on `main` to require a pull request, squash merges, the status `knot/gate` and an up-to-date branch, and limit interactions to collaborators for the length of the build | 10 |
| G1 | With WP-01 | Register his other Mac for development-signed builds, and set up signing so that the gate's development-signed step runs without a prompt | 5 |
| G1 | With WP-01 | Create an App Store Connect record for the development identifier and an API key, for one internal TestFlight upload of the SP-3 spike app, and hand the key over as a file path through the secret prompt | 20 |
| G3 | After wave 1 | One spike sitting: SP-1 has 12 rows, and the SP-2 spike app runs its 30 transfers itself | 45 |
| G3 | After wave 1 | SP-5's rows on the Mac | 15 |
| G3 | After wave 1 | Install the SP-3 build from TestFlight and run its check | 15 |
| G3 | After wave 1 | Read the five spike reports and confirm their decisions | 20 |
| G3 | With SP-4 | Sign two devices into iCloud for the sync spike | 10 |
| G4 | Wave 0 | Record the read-aloud script and 10 spontaneous notes on two devices and move the files to the Mac | 30 |
| G4 | Before the full design round | Read the guard's table and the ten cleanup pairs; choose full cleanup, punctuation only or off | 20 |
| G2 | After the direction | Run the full Claude Design round and return the handoff | 90 |
| G2 | Before WP-40 starts | Read the handoff's gap list | 15 |
| G4 | M1 | Checklist | 15 |
| G4 | M2 | Checklist in two sittings, with locked and unlocked rows for each trigger | 40 |
| G4 | Seven days after the M2 checklist has passed | The keep-gate sitting (§5) | 30 |
| G4 | M3 | Checklist | 30 |
| G4 | M4 | Checklist in two sittings: hotkey, CLI and MCP, two-device sync | 45 |
| G4 | M5 | Checklist | 20 |
| G4 | M6 | Checklist with the regression rows, and sign-off of the applied design | 90 |
| G4 | M2 to M5 | The VoiceOver rows, one per capture path | 5 each |
| G4 | M2 and M3 | A forced restart during a recording | 5 each |
| G4 | M2 and M4 | The rows for what injected audio cannot show | 5 in all |
| G4 | M1 to M7 | Repeat sittings after fixes: three each for M2, M3 and M4, one each for the others | 15 each |
| G4 | M1 to M7 | Free-form notes at the end of each milestone sitting, which the orchestrator turns into change requests | 10 each |
| G5 | After M5 | Approve the CloudKit production schema, before the first TestFlight build that syncs | 5 |
| G5 | M7 | Create Knot's own App Store Connect record, for `com.p3ob7o.knot`; authorise the TestFlight upload and supply an API key as a file path through the secret prompt; install over the M6 milestone build on each device | 30 |

His sittings come to about 18 hours across the build, including the repeat sittings. The orchestrator derives dates for the sittings from the cadence the owner names at G0.

- A checklist longer than 20 rows is split into two sittings.
- Gate G3 is the owner's sitting for confirming the spikes' decisions, and each spike is confirmed on its own.
- A spike or milestone sitting starts when `scripts/install.sh` has reported success. SP-1 and SP-2 each record the install procedure that worked on the iPhone and on the Watch, and the orchestrator corrects the script from those reports.
- At G1 the owner installs a release Xcode 27 beside the beta, and WP-01 records its version: it is the Xcode for the merge gate and for the archive.
- Without Automation Mode and developer mode, Mac UI tests wait on a password dialog that no agent can answer.
- An API key is requested through the secret prompt and never pasted into a thread. It is handed over for one upload and revoked after it, and each upload needs the owner's word.
- The owner makes the wave 0 recordings with Apple's Voice Memos, on the iPhone and on the Watch, and puts them in the one folder outside every worktree that `KNOT_LOCAL_FIXTURES` names.

## 11. Risks

| Risk | If it happens | Response |
|---|---|---|
| Recording cannot start from a locked iPhone | The Action Button needs Face ID first | The control opens Knot and recording starts at once. SP-1 decides early. |
| Watch delivery is unreliable | Recordings arrive late or need a retry | The durable outbox and re-send mean nothing is lost. SP-2 measures delivery on the Ultra 2 early. |
| On-device cleanup quality is poor | Cleaned notes change meaning or read badly | The guard rejects bad results. Paolo chooses punctuation-only or off by default. A cloud option is a later feature. |
| CKSyncEngine is harder than planned | Sync lands late | Knot is fully usable on each device without sync. Sync has its own lane and its own gate. |
| The design handoff arrives late or changes structure | UI rework | The design direction is chosen first (§6). Behaviour lives in view models. Views are thin and restyled in WP-40. |
| Agents write OS 27 APIs from stale memory | Code that does not compile, or misuses an API | The read-the-SDK rule in architecture §21, and the spikes. |
| Parallel agents collide | Merge conflicts, drifting interfaces | Contracts first, owned paths, contract PRs, one owner for shared files. |
| A sandboxed CLI cannot reach the store | No direct command-line access | XPC to the running app, built only if SP-3 fails in wave 1. SP-3 decides early, and is closed only when the route it chooses has passed the distribution-signed check. If the direct route fails there, the XPC route gets an internal upload of its own. |
| The machine is overloaded | Slow or flaky builds | The thread and build limits in §8.6. |
| Nobody can test the iPhone Duo | A Pencil path ships unverified | It sits behind a capability check and is stated as untested. |
| Hotkey press and release do not arrive in a sandboxed build | The hotkey needs the Input Monitoring permission | The fallback is a listen-only event tap. SP-5 decides in wave 1. |
| A development build opens the owner's store | It writes into the owner's notes | The development identifiers and the Appendix A rule prevent it. |
| Code is written against the beta SDK | The release Xcode cannot compile it | The availability rule applies, and the merge gate builds with the release Xcode. |

## 12. First steps after approval

1. The restart, WP-00's first PR, merged on 2026-11-19 as pull request 10. It doubled as the spec PR.
2. The fold is WP-00's second PR. It turns the plan and its amendments into this text and a brief for each package. A second model reviews it item by item, and it merges only when `scripts/check-plan.sh` passes.
3. Paolo: the three things G0 still holds (§3), the Claude Design direction step, and the recordings of wave 0.
4. When the fold merges, launch WP-03, WP-04 and the first PR of WP-01. Paolo: G1.
5. When the first PR of WP-01 merges, launch the first PR of WP-02, once the owner has confirmed A38 and A39. The second PR of WP-01 runs beside it. Once WP-04 has merged too, launch the five spikes and the proof steps of WP-12, WP-13, WP-14 and WP-18.
6. When the second PR of WP-02 merges, launch WP-05. All of WP-20 may run beside it.
7. When WP-05 merges, launch wave 2 in the order given in §6.

## Appendix A. The new AGENTS.md

WP-00's first PR wrote it, with these sections:

- **Product contract.** Five lines, pointing to the spec. Knot has no account, server or telemetry, and one third-party library, GRDB.
- **Sources of truth.** `docs/product-spec.md`, `docs/architecture.md`, `PLAN.md` and the briefs in `docs/plan/`. `project.yml` owns targets and settings. Never edit the generated project.
- **Boundaries.** The rules in architecture §6. Views never touch storage. Extensions never open the database. Sync runs only in the app.
- **Hard rules.**
  - Never log note text, transcripts, audio or content-derived paths. Every log line about a capture carries its capture ID.
  - No network use except CloudKit and Apple's model downloads.
  - No new dependency without Paolo's approval.
  - Swift 6 strict concurrency; warnings are errors.
  - Synthetic fixtures only. No real notes, recordings, credentials or signing material in tests or commits. The one exemption is `knot-eval`, which reads the owner's own recordings from the folder that `KNOT_LOCAL_FIXTURES` names. It prints no text from the recordings, nothing derived from them enters a commit, a PR, a log or a test, and examples shown in PRs stay synthetic.
  - Read the SDK before using an OS 26 or OS 27 API.
  - Only a milestone build opens the default store or the real iCloud container.
  - No automated test and no agent opens a hardware microphone on the build Mac. The recorder takes injected audio and refuses the hardware input under test.
  - Agents use `knot-dev` and never `knot`, and their threads export `KNOT_AGENT=1`.
  - Agents act only on the project's own `wp/`, `spike/` and `contract/` branches and never read issue or pull-request comments from GitHub.
  - A pull request from outside is read before it is built.
  - The repository gets no self-hosted runner, and its workflows hold no secrets and pin their actions.
  - A PR that changes the cleanup instructions, the guard or the speech settings reruns the synthetic evaluation, `knot-eval --set synthetic`, and states the results before and after. For a PR that touches speech or cleanup, the orchestrator runs the local evaluation, on the owner's recordings, at the gate and records the numbers.
  - No agent cuts scope. Scope leaves only on the owner's word.
- **Working in parallel.** Edit only the paths your package owns. Contract changes and shared files go through the orchestrator. Keep the repository, the build folder and the fixtures folder out of any folder that a cloud file provider syncs: `scripts/doctor.sh` refuses them there.
- **Git.** Branch names `wp/…`, `spike/…`, `contract/…`. Never `master`. Never push to `main`. No session links in commits or PR descriptions.
- **Needs Paolo's explicit authorisation.** Moving a tag, distribution signing, notarising, uploading, deploying the CloudKit production schema, every operation on the milestone iCloud container in either environment, deleting an archive branch.
- **Commands.** `scripts/bootstrap.sh` and `scripts/verify.sh`. Every script sets `DEVELOPER_DIR` from `.xcode-version` and checks the version. Implementers use that Xcode, and the beta only by name. Package criteria name `scripts/verify.sh --quick`, never a bare `swift test`.

## Appendix B. Thread prompt

```
You are implementing work package <ID> of the Knot v1 build.

Read, in this order: AGENTS.md, docs/product-spec.md, docs/architecture.md,
then your brief, docs/plan/<ID>.md. You do not need the other briefs.

Your brief says what you own, what "done" means, and what to watch out for.
Edit only the paths you own. If the brief is wrong or you are blocked, stop and
say so in your final message instead of widening the scope.

Before you change anything, run scripts/bootstrap.sh and
scripts/verify.sh --quick. If that baseline is red, stop.

Before using any OS 26 or OS 27 API, read its declaration in the SDK
(docs/architecture.md, section 21).

Work on the branch you are on. Run scripts/verify.sh --quick, then open a PR
against main. After the merge queue has rebased your branch, reset to the
remote branch before you change anything else.

In your final message, state what you built, what you verified and how, what
needs hardware, and any departure from the brief. Its last line is one of:
RESULT ok: PR <url>, head <sha>, verify <summary>
RESULT blocked: <code>, branch <pushed branch>, needs <what>, resume <how>
The codes are baseline_red, brief_wrong, needs_contract_change,
needs_shared_file, needs_owner, needs_hardware and tool_failure.
```

The first PR of WP-01 is the stated exception to the baseline step. It starts from a tree with no `scripts/bootstrap.sh` and no `scripts/verify.sh`, so its baseline is that the tree matches WP-00's file list. Its second PR runs the baseline step like every other PR.

## Appendix C. PR description

- Package ID and goal, in one line.
- What changed, in a few bullets.
- Evidence for each merge criterion: the command and its result.
- OS 26 and OS 27 declarations read.
- Prior art read, where the brief names any.
- The evaluation results before and after, where the PR changes the cleanup instructions, the guard or the speech settings.
- Not verified, and where it will be checked.
- Requests to the orchestrator: contract changes, shared-file edits.
