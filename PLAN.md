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

Nothing is open at gate G0. Later on 2026-11-19 the owner answered what was left:

- The two readings of his answers on the Watch and on selection. The Watch app has one screen, the record control, with no list of recordings. Selecting several segments at once leaves v1, and `TODOS.md` defers it. "Move to its own note" takes one segment at a time.
- His recordings for gate G4: ten spontaneous voice notes in all, five on the iPhone and five on the Watch, as `docs/checklists/G4-spontaneous-notes.md` asks.
- His cadence: about an hour a day for the sittings (§10).

## 4. Scope

In v1, by device:

- **iPhone:** typing, voice with live text, the stream, search, editing, the Action Button and Lock Screen controls, widgets, Live Activity, Siri and Shortcuts.
- **iPad:** everything on iPhone, plus the Pencil canvas, a side-by-side layout and keyboard shortcuts.
- **Mac:** the one hotkey, the floating panel, hold-to-record, the main window, the menu bar item, the `knot` command and the MCP server.
- **Watch:** one-tap recording from a complication, widget, control or Double Tap, and delivery to the iPhone.
- **Everywhere but the watch:** on-device transcription and cleanup, optional iCloud sync, export.

Out of v1: see product spec §15. `TODOS.md` at the repo root holds the seventeen items deferred from v1.

### The cut order

If the build has to shrink, at the keep-gate sitting or at a later milestone sitting, scope leaves in this order, and only on the owner's word. No agent cuts scope.

1. iPad Pencil: WP-35; the rest of WP-18, and beside it the fourth PR of WP-11, which runs drawings through the engine; the Sketch control and intent; and M5. The iPad then keeps the iPhone's layout, which it has had since M1, and has no canvas, no side-by-side layout, no hardware-keyboard shortcuts and no menu bar. Ink stays a kind the store knows, so a later version can add it without a migration.
2. System surfaces beyond the first of each kind: the Watch complication families beyond one, the Smart Stack widget, and the Home Screen and Lock Screen widgets of the iPhone. The Action Button, the controls and one complication stay.

A part that is cut is not started. The orchestrator writes each cut to `TODOS.md` with what would bring it back, and updates the briefs in `docs/plan/` and the checklists in one PR. If M5 is cut, every condition that names M5 names M4: the deployment of the CloudKit production schema, which then also needs a recording made on one device to play on the other, and the start of WP-43. Anything beyond these two steps is a new decision of the owner's.

## 5. Milestones

Each milestone is something Paolo can do on a device. Hardware checks come from `docs/checklists/`.

| ID | Name | Paolo can |
|---|---|---|
| M0 | Foundations | Read a new `main` holding the plan, the scaffold and the contracts. Read five spike reports. Hold a design brief ready for Claude Design. |
| M1 | Skeleton on four devices | Type a line on iPhone, iPad and Mac and find it in the stream after relaunch. Record on the Watch and see "Saved" on the Watch. Local only, system-default look. |
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
| M1 | WP-22 PR 1 | WP-05; WP-06 PR 1; WP-06a; WP-10 PR 1; WP-12 PR 1; WP-17 PR 1; WP-21 PR 1; WP-30 PR 1; WP-32 PR 1; WP-33 PR 1 |
| M2 | WP-30 PR 2 | WP-11 PR 2; WP-11 PR 3; WP-12 PR 3; WP-13 PR 1; WP-14; WP-15 PR 2; WP-19 PR 2; WP-31 PR 1; WP-22 PR 2; SP-1; the design direction |
| M3 | WP-32 PR 2 | WP-17 PR 2; WP-19 PR 3; SP-2 |
| M4 | WP-33 PR 2 | WP-16; WP-34 PR 3; SP-3; SP-4; SP-5 |
| M5 | WP-35 | WP-18; WP-11 PR 4; WP-16; WP-19 PR 4; WP-31 PR 2 |
| M6 | WP-40 | WP-40a; WP-40b; WP-40c; WP-40d; WP-41; WP-42; WP-32 PR 3; WP-31 PR 2 if M5 is cut |
| M7 | WP-43 | WP-44; M6; WP-40a; WP-40b; WP-40c; WP-40d; WP-41; WP-42 |
<!-- milestone-needs:end -->

If M5 is cut, the second PR of WP-31 loses the Sketch control and M6 needs it. M7 needs the evidence of every milestone before it: the release script refuses a candidate that lacks any.

- **Identifiers.** Milestone builds use `com.p3ob7o.knot`, with its app group and its iCloud container (D34). They carry a version above 0.2.0, which is the retired app's. Every build that is not a milestone build uses development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. That covers agent builds, PR builds, spikes and tests, and the TestFlight upload of the SP-3 spike app, so nothing before the M1 milestone build touches the retired app or its container. Only a milestone build opens the default store or the real iCloud container.
- **Levels.** Every milestone build, and every fix built for an earlier milestone, is made at a level from M1 to M7. A feature whose milestone has not passed is switched off in it by a gate: sync and the command line open at M4, and ink at M5. A fix made for M2 during the keep-gate week therefore carries nothing from M3 or M4.
- **Real notes.** Notes on the owner's iPhone and iPad are disposable until the M2 milestone build, and notes on his Mac until the M4 milestone build, which needs SP-3's answer on where the Mac store lives. The schema does not wait for those builds. Schema version 1 is fixed from the commit that the M1 milestone build is made from, `c2a1315b`: that build is the first installed on the owner's devices, and the build after it must open the store that it left there, because on a device a milestone build is installed over the one before, and the app's container, which also holds the retired app's folder, is not cleared between them. Every schema change after that commit is a numbered migration with its tests, whichever package makes it, the second PR of WP-10 included. The first is version 2, which keeps a stored recording's level peaks on its segment. Until the builds named above, the migrations are for the build's sake, not yet for the owner's notes; after them, every change to the schema or to the store's location also keeps his notes. The orchestrator ruled it on 2026-11-21, where this bullet and the next pulled against each other for the M1 tag's store.
- **At each milestone.** The capture ledger soak runs, and `scripts/verify.sh --perf` measures the timed targets (§9). The timed targets' step is run before the milestone's last PRs are in, as the milestone build's rehearsal is, so that a broken step shows early, and until WP-42's measured tests exist the milestone's record says that nothing was measured. At each milestone tag a seeded synthetic store made by that milestone's build is committed: for M1 a store of schema version 1, made by the build from `c2a1315b`. It holds work in flight: an open capture, a queued job and a pending delete. Every later build opens it, migrates it and passes the whole `NoteStore` contract suite on it.
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

With five threads at a time, wave 2 starts in this order, which follows D16: WP-10, WP-21, WP-12, WP-11, WP-13, then WP-14, WP-15, WP-19, WP-18, WP-20. All of WP-20 may run earlier, beside WP-05. In WP-18, everything after the proof step waits for the keep-gate ruling, and so does the fourth PR of WP-11.

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
| WP-01 | 3 | The Mac UI step, run and made required | WP-01 PR 2 |
| WP-02 | 1 | The domain types, rules and reducers | WP-01 PR 1 |
| WP-02 | 2 | The ports, fakes and suites the tracer needs | WP-02 PR 1; WP-12 proof step; WP-13 proof step; WP-14 proof step |
| WP-02 | 3 | The remaining ports, fakes and suites | WP-02 PR 2; WP-18 proof step; SP-1 notes; SP-2 notes; SP-4 notes |
| WP-03 | 1 | The brief as Paolo approves it | the plan's approval |
| WP-04 | 1 | The fixtures and the checklists | WP-00 PR 2 |
| WP-05 | 1 | The thinnest real engine and queue, one end-to-end test and the preview environment | WP-02 PR 2 |
| WP-06 | 1 | The soak harness, covering typed captures first | WP-05; WP-10 PR 1 |
| WP-06 | 06a | The soak's step in `scripts/verify.sh`, split out of the first PR | WP-06 PR 1 |
| WP-06 | 2 | The child runs a recording on the live recorder with injected audio | WP-06 PR 1; WP-12 PR 2 |
| WP-06 | 06b | A kill point that never kills is held by a test of its own, on no fresh seed: the soak at a fresh seed was red by chance for a point its script did not bring about | WP-06 PR 2 |
| WP-06 | 06c | Nothing is written after a launch's last line: a log line of the engine's work still in flight at the exit followed `done`, and the witness read the launch as unfinished | WP-06b |
| WP-06 | 06d | The child drains the processing queue after recovery, the witness holds what its jobs leave, and WP-15's kill points of processing run under the soak | WP-06c; WP-15 PR 1 |
| SP-1 | Notes | The code half, a minimal app on `spike/locked-recording`, and its short note | WP-01 PR 1; WP-04 |
| SP-1 | 1 | The report, `docs/spikes/SP-1.md`, which ends with a decision | SP-1 notes |
| SP-2 | Notes | The code half on `spike/watch-delivery`, and its short note | WP-01 PR 1; WP-04 |
| SP-2 | 1 | The report, `docs/spikes/SP-2.md`, which ends with a decision | SP-2 notes |
| SP-3 | Notes | The code half on `spike/agent-access`, and its short note | WP-01 PR 1; WP-04 |
| SP-3 | 1 | The report, `docs/spikes/SP-3.md`, which ends with a decision | SP-3 notes |
| SP-4 | Notes | The first stage of the code half on `spike/sync-shape`, and its short note | WP-01 PR 1; WP-04 |
| SP-4 | 1 | The report, `docs/spikes/SP-4.md`, which holds the final CloudKit schema and ends with a decision | SP-4 notes |
| SP-5 | Notes | The code half on `spike/mac-hotkey`, and its short note | WP-01 PR 1 |
| SP-5 | 1 | The report, `docs/spikes/SP-5.md`, which ends with a decision | SP-5 notes |
| WP-10 | 1 | The store that M1 and M2 run on: everything but the second-process rules and the sync columns | WP-05 |
| WP-10 | 10a | The store's tests leave no file outside their own folders | WP-10 PR 1 |
| WP-10 | 10b | The seeded store of the M1 milestone build, committed at its tag | WP-10a |
| WP-10 | 2 | The second-process rules, the sync columns, the interface for sync and device identity | SP-3; SP-4; WP-02 PR 3 |
| WP-11 | 1 | Typed and voice captures through the engine, and the engine's line discipline | WP-05 |
| WP-11 | 11a | The engine's tests made steady: tests that failed now and then on loaded runs wait for what they read, and one outcome of the random interleavings is a stated limit | WP-11 PR 1 |
| WP-11 | 11b | A recording whose file reached `Assets/` before its capture ended reaches the stream: one that recovery could never finish, found by the soak, cured | WP-11 PR 1 |
| WP-11 | 2 | The engine as the one applier of a press, live words and levels, a stored recording's peaks, KnotCapture's copy of the real-path code replaced by KnotCore's, the moments with no kill seam, and the two tests of `FollowerPlacementTests` restated as limits | WP-11 PR 1; the contract pull request that gives `CaptureEngine` its `live` and `press` |
| WP-11 | 3 | The engine's kill points in the soak | WP-11 PR 2; WP-06 PR 2 |
| WP-11 | 11c | A late answer reads the capture's entry after its kill point: a discard that passed while the answer waited there was missed, a fault the third PR brought and the random interleavings found under load | WP-11 PR 3 |
| WP-11 | 11d | Two stale failed ends of a stored recording are shown to change nothing: the store refuses them, and a test holds each | WP-11c |
| WP-11 | 4 | Drawings through the engine. Held until the keep-gate ruling. | the ruling; WP-18 PR 1 |
| WP-12 | Proof step | The format proof, and a short note saying whether the draft `Recorder` port fits the real API's streaming, cancellation and errors | WP-01 PR 1; WP-04 |
| WP-12 | 1 | The format proof and a recorder that records and stops on every platform | WP-05 |
| WP-12 | 2 | Everything else | WP-12 PR 1; WP-02 PR 3 |
| WP-12 | 12a | The recorder's tests wait by an order and not by a bound: two waits of ten seconds ran out together at a loaded gate under the strict pool | WP-12 PR 2 |
| WP-12 | 3 | The recorder's kill points in the soak | WP-12 PR 2; WP-06 PR 2 |
| WP-12 | 12b | The mix-down test's cases run one at a time: run in parallel, the thread sanitizer took memory that the system's audio buffers reuse for a data race, and the nightly run was red | WP-12 PR 3 |
| WP-13 | Proof step | Transcription of the fixtures, and of the owner's recordings once they are on the Mac, the Simulator probe, and a short note saying whether the draft `Transcriber` port fits the real API's streaming, cancellation and errors | WP-01 PR 1; WP-04 |
| WP-13 | 1 | The whole package | WP-05 |
| WP-13 | 13a | The cancel test no longer rests on a wall-clock second: a test of the transcriber's that failed a gate under load, made right | WP-13 PR 1 |
| WP-14 | Proof step | The fidelity guard as a pure function with tests, ten cleanup pairs from the owner's recordings once they are on the Mac, and a short note saying whether the draft `Cleaner` port fits the real API's streaming, cancellation and errors | WP-01 PR 1; WP-04 |
| WP-14 | 1 | The whole package | WP-05 |
| WP-15 | 1 | The job queue, the inbox ingestor and the published states | WP-05; the contract pull request for the purge of an unreadable item's files |
| WP-15 | 2 | The hooks for background execution on iOS | SP-1 |
| WP-16 | 1 | The whole package | WP-10 PR 2 |
| WP-17 | 1 | The outbox, and the coordinator that records, converts and sends | WP-02 PR 3 |
| WP-17 | 17a | The Watch's own entry point, over a stand-in for an iPhone that is never in reach, and the endings a recording comes to by itself. Pull request 71, merged. | WP-17 PR 1 |
| WP-17 | 2 | The transport | SP-2; WP-02 PR 3 |
| WP-18 | Proof step | Recognition of the ink fixtures, and a short note saying whether the draft `InkRecogniser` port fits the real API's streaming, cancellation and errors. It runs early and is not held. | WP-01 PR 1; WP-04 |
| WP-18 | 1 | Everything after the proof step. Held until the keep-gate ruling. | WP-18 proof step; the ruling; WP-05; WP-02 PR 3 |
| WP-19 | 1 | The text intents | WP-05 |
| WP-19 | 2 | The recording intents for iPhone, iPad and Mac, with OpenCapture and OpenSearch | SP-1; WP-02 PR 3 |
| WP-19 | 3 | The watch intents | SP-2 |
| WP-19 | 4 | The OpenSketch intent. Held until the keep-gate ruling. | the ruling |
| WP-20 | 1 | The whole package | WP-02 PR 2 |
| WP-21 | 1 | A skeleton that does not depend on the design direction: the theme layer, the view models with their tests, and the components | WP-05 |
| WP-21 | 21a | What the apps' skeletons and the gate found in the skeleton after it merged: the audit's exclusion of the system keyboard, a stream row whose text is never clipped, tests that rest on no clock, and a Mac launch that ignores saved window state | WP-21 PR 1 |
| WP-21 | 2 | The structure of the direction's sheets, what rests on the contracts of WP-02 PR 3, and a named preview for every designed cell of the state matrix | the design direction; WP-02 PR 3 |
| WP-22 | 1 | The composition | WP-05; WP-10 PR 1 |
| WP-22 | 22a | The ordering test keeps one live composition per store: a test of the composition's that failed under the strict cooperative pool, made right | WP-22 PR 1 |
| WP-22 | 22b | The composition's wiring, split out of the second PR: the processing queue given this device, the purge as a launch step, `Lifecycle` with its adapters, and background time on iOS around the store's opening | WP-22 PR 1; WP-15 PR 1 |
| WP-22 | 2 | The end-to-end suite | WP-10 PR 1; WP-15 PR 1; WP-11 PR 1; WP-12 PR 2; WP-13 PR 1; WP-14; WP-22b |
| WP-22 | 22c | The composition's restore of a kept copy: the store stays closed for the rest of the launch, and Knot must be opened again | WP-22 PR 2 |
| WP-22 | 22d | The Mac app's milestone build embeds its tool: the tool's file has a name of its own, and the app copies it by its built name | WP-22c |
| WP-30 | 1 | A skeleton that does not depend on the design direction: a line typed on the iPhone or the iPad is found in the stream after relaunch | WP-21 PR 1 |
| WP-30 | 2 | The iPhone app, built from the direction's structure sheet | the design direction; WP-21 PR 2; WP-22 PR 1 |
| WP-31 | 1 | The controls, the Live Activity and the Action Button tip | SP-1; WP-19 PR 2 |
| WP-31 | 2 | The Sketch control and the Home Screen and Lock Screen widgets. Held until the keep-gate ruling. | the ruling |
| WP-32 | 1 | A skeleton that does not depend on the design direction: the owner records on the Watch and sees "Saved" on the Watch | WP-12 PR 1; WP-17a; WP-21 PR 1 |
| WP-32 | 2 | The Watch app, built from the direction's structure sheet, with its first complication family and its control | SP-2; the design direction; WP-17 PR 2; WP-19 PR 3; WP-21 PR 2 |
| WP-32 | 3 | The complication families beyond the first and the Smart Stack widget. Held until the keep-gate ruling. | the ruling |
| WP-33 | 1 | A skeleton that does not depend on the design direction: a line typed on the Mac is found in the stream after relaunch | WP-21 PR 1 |
| WP-33 | 2 | The Mac app, built from the direction's structure sheet: the hotkey, the panel, hold-to-record, the menu bar item, the main window and Settings | the design direction; SP-5; WP-21 PR 2; WP-22 PR 1 |
| WP-34 | 1 | `status`, `add`, `list`, the error contract and the access switch | WP-05 |
| WP-34 | 2 | The other commands | WP-10 PR 2; WP-20; the contract pull request for what the tool shows that KnotCore gives no source for |
| WP-34 | 3 | The MCP server, and the embedding of the tool in the Mac app | WP-34 PR 2; SP-3 for the embedding |
| WP-35 | 1 | The whole package, built from the direction's structure sheet for the iPad. Held until the keep-gate ruling. | the ruling; WP-18 PR 1; WP-11 PR 4; WP-21 PR 2; WP-30 PR 2 |
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
- The PRs of WP-11, WP-12 and WP-15 that add kill points merge after WP-06 PR 2, in which the soak's child runs a recording.
- The first PRs of WP-30 and WP-33 merge after WP-22 PR 1, and each carries the UI smoke test on `.live` on its platform.
- `scripts/check-plan.sh` fails on a cycle, on a row that names a package without a PR where the package has several, and on a milestone that needs a held PR.

### The hold until the ruling

Until the keep-gate ruling, nothing that the cut order names is built, and wave 4 does not start. That holds back WP-35; everything in WP-18 after its proof step; the fourth PR of WP-11, which runs drawings through the engine; the Sketch control of WP-31 and the OpenSketch intent of WP-19; the Home Screen and Lock Screen widgets of WP-31; WP-32's complication families beyond the first and its Smart Stack widget; and WP-40, WP-41, WP-42 and WP-43.

The hold names PRs, so that no milestone waits for a held part. Each held part of WP-11, WP-19, WP-31 and WP-32 is that package's last PR:

- WP-11 ships in four PRs. The first runs typed and voice captures through the engine. The second makes the engine the one applier of a press, publishes live words and levels, keeps a stored recording's peaks, takes KnotCore's real-path code for KnotCapture's copy, gives the engine its missing kill seams and restates the follower's two tests as limits. The third adds its kill points to the soak. The fourth, held, runs drawings through the engine, and waits for WP-18's first PR, which settles where an open drawing's saves go.
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

A spike answers questions. Its code stays on its `spike/…` branch and is never merged. Its report merges to `docs/spikes/` and ends with a decision. Where the answer changes docs/architecture.md, the report lists the changes it asks for, and the orchestrator, who owns that file, makes them in a pull request of its own before it launches a package that waits for the spike.

A spike counts as finished when its report has merged and the owner has confirmed its decision. The code half of each spike starts with the proof steps, and files the same short note. SP-4's code half runs in two stages on the same code. The first works from the pinned SDK alone, with no container, and files the short note, which says what it read and what is not verified yet. The second runs against the development iCloud container once the owner's signing and two signed-in devices or simulators are there, and SP-4's report follows it. A spike uses the development identifiers, like every build that is not a milestone build.

### Proof steps

WP-12, WP-13, WP-14 and WP-18 each begin with a proof step. It is the first thing the package does, and its brief says what it must show.

Proof comes before contracts. The proof steps, and the code half of each spike, start beside the first PR of WP-02. They need only the first PR of WP-01 and WP-04, and SP-5 needs only the first PR of WP-01. SP-4's second stage also needs the owner's signing and two signed-in devices, and its short note comes from the first. Each files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. A note is the file `docs/notes/<ID>.md`, merged by a pull request that holds nothing else, and a row that waits for notes starts when that pull request has merged. The code of a proof step stays on a branch of its own, `wp/<number>-proof`, with no pull request, and the package's first PR starts from it. The note merges from a second branch that holds only that file. A spike's code half does the same from the spike's branch. The second PR of WP-02 waits for the notes of WP-12, WP-13 and WP-14, and its third for the note of WP-18 and for those of SP-1, SP-2 and SP-4.

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
3. A fresh reviewer reads the PR against its brief and AGENTS.md, from a list of points that the orchestrator writes for that PR. WP-02, WP-05, WP-06, WP-10, WP-11, WP-12, WP-15, WP-16 and WP-17 also get a second opinion from a different model. The orchestrator reads a short note itself.
4. The implementer fixes the findings. After two rounds, the orchestrator decides what is left. Every finding the orchestrator sets aside is written in the PR and in the journal.
5. The orchestrator takes the PR into its merge queue. When `main` has moved, it merges `main` into the branch. It never rebases a branch that was pushed and never forces a push. It runs the merge gate, `scripts/verify.sh --gate`, on that head, and squash-merges. Until the second PR of WP-01 merges, the gate is `--quick` (§9). After the queue has updated a branch, its thread fast-forwards to the remote branch before it changes anything else.
6. The orchestrator removes the worktree, unless the thread goes straight on with the package's next PR. That PR starts on a new branch from `main`, in the same worktree.

The orchestrator runs a serial queue and binds each result to a base, a head and a tree. Merges follow the dependency order in §6, inside the queue's own order. The merge gate, the merge queue and the orchestrator's state follow docs/architecture.md §18.

A pull request beside a package's planned ones, which no row of its brief names, gets a row before it is gated. The row goes in the package's "Starts after" table, labelled with the package's number and a letter, as the parts of WP-40 are, such as 21a, and a section under Build says what it holds. Its squash subject starts with the package's ID and a colon. The tools count a package's merged pull requests in the order of its brief's rows, from the squash subjects that start with its ID, so a pull request with no row would shift every later one: its package would look merged too early, and the next gate would ask for the tests of a pull request that is not built.

Knot is one person's app. Paolo said so on 2026-11-21: "Let's not overoptimize for simultaneous inputs, it's not a team app, it's an individual app". The rule below is the orchestrator's reading of that sentence, not his words:

- A finding that needs several surfaces, or two devices, acting inside the same fraction of a second is recorded as a known limit, unless a capture is lost.
- A reviewer ranks such a finding low, and says plainly when a sequence needs more than one person can do.
- A fix of that kind that costs more than a small change goes to Paolo first.
- One person's ordinary sequences across surfaces stay in scope.

### 8.5 Contracts and shared files

- Once WP-02's last PR has merged, a change to KnotCore's public API goes in its own small PR on a `contract/…` branch, with the fakes updated. Until then WP-02's own PRs write that API, and its third PR only adds to what its second published: once WP-05 has started, a change that breaks that API goes in a contract PR even from WP-02. The orchestrator merges a contract PR first and tells the threads that depend on it to merge `main` into their branches. A contract PR that only adds merges in the normal queue. One that breaks keeps the two fixed times a day of docs/architecture.md §18.
- `Package.swift`, `Package.resolved`, `project.yml`, `AGENTS.md`, `PLAN.md`, `docs/plan/`, `docs/reviews/`, `docs/orchestrator.md`, `docs/product-spec.md` and `docs/architecture.md` belong to the orchestrator. So does `scripts/` after WP-01 merges, `docs/checklists/` after WP-04 merges, and `docs/errors.md`, the catalog's document, after WP-02 merges. A new error code still comes by a contract PR. A package that needs a change there asks for it in its PR description. The orchestrator's own PRs count as WP-00, which owns these paths and every path that no brief owns, and `Fixtures/` too once WP-04 has merged, outside the results folders of WP-13 and WP-14. `scripts/ownership-extra.txt` lists what a package owns beyond its brief, and only the orchestrator edits it. The ownership check reads only the package and the path from that file: the review holds the orchestrator to the conditions that its third field states.
- A package edits only the paths it owns, and the gate checks that. Path ownership has stated exceptions:
  - The first PR of WP-01 creates the first files of every module folder: an empty target with one trivial test, the module's live entry point, the crash hosts and the environment factory. It also declares `AppEnvironment` in KnotCore with its `.unavailable` value and nothing else, because the factory returns that value. Each folder belongs to its package from then on.
  - `scripts/release.sh` belongs to WP-43, though the rest of `scripts/` passes to the orchestrator after WP-01.
  - WP-35 owns `Apps/iOS/Ink/`, the canvas screens shared by the iPad and a Pencil-capable iPhone.
  - WP-05 owns `Packages/KnotKit/Sources/KnotFakes/Preview/`.
  - WP-13 owns `Fixtures/results/speech/` and WP-14 owns `Fixtures/results/cleanup/`, inside WP-04's `Fixtures/`. Each commits its synthetic results there.
  - A proof step and the code half of a spike each own their short note, `docs/notes/<ID>.md`.
  - A PR that brings a required-reason API into a module adds its reason to the privacy manifest of every target that links the module, whichever package owns the manifest (docs/architecture.md §19).
  - WP-06 owns the soak step of `scripts/verify.sh`. WP-11, WP-12 and WP-15 each add one file of kill points to `Packages/KnotKit/Tests/KnotSoak/` in their own PRs.
  - WP-40's ownership extends to the view models that a difference listed in `docs/design/deltas.md` touches. Where the handoff is silent, the implementer uses the system default and adds a line to that file, which the owner clears at M6.
- The README links to setup, the command reference, contributing and recovery. A changelog is kept from M4, with a section for the command line.

### 8.6 Limits

- Five implementer threads at a time, to start with. The machine has 16 cores and 48 GB of memory.
- Three heavy builds at a time, enforced by `scripts/build-slot.sh`. One slot is kept for the gate, Mac UI tests queue on one exclusive slot, and the script also limits how many simulators are booted at once.
- Worktrees are removed after merge, with `scripts/worktree-remove.sh`, unless a thread goes straight on with its package's next PR. Each holds several gigabytes of build products. Removing a worktree also removes its simulators and its development store.

### 8.7 Status

`docs/status.md` is one table, with a column each for the package, its state, its thread, its PR and its milestone evidence. `scripts/status.sh` prints it, and it is written to `main` only at milestones. Only the orchestrator edits it.

The orchestrator's state is rebuilt from the briefs, GitHub and a journal outside the worktrees, as docs/architecture.md §18 describes. A fresh thread takes over at M1 as a drill.

## 9. Checks

A PR is done when all of these hold:

- Its brief's merge criteria are met, with the evidence in the PR description.
- `scripts/verify.sh --gate` passes on the head that the queue brought up to date.
- New behaviour has tests. Storage, capture, ingest and sync have failure-path tests.
- No note text, transcript or audio appears in logs, test output or fixtures.
- Any OS 26 or OS 27 API used is named in the PR with the declaration that was read (architecture §21).
- Anything that could not be verified without hardware is listed, and has a row in a checklist.
- Where it changes the cleanup instructions, the guard or the speech settings, it reruns the synthetic evaluation, `knot-eval --set synthetic`, and states the results before and after. For a PR that touches speech or cleanup, the orchestrator runs the local evaluation, on the owner's recordings, at the gate and records the numbers. Until the owner's recordings exist, such a pull request merges on the synthetic evaluation, the numbers on his recordings follow, and M2 does not close without them.

**The merge gate.** The merge gate is `scripts/verify.sh --gate` on the orchestrator's Mac. It builds with the release Xcode that the owner installs at G1. It picks its depth from the diff by a fixed table and refuses a partial run: `--skip mac-ui` exists for implementers, and the gate refuses it. The table, and the checks that every depth starts with, are in docs/architecture.md §18. The gate requires both on-device models on the Mac and fails on a skipped model test. In the iOS Simulator it uses the scripted transcriber, because the real one is not available there.

After G1 and SP-3, the gate has one development-signed step for a PR that touches KnotAgent, `knot`, the Mac app or KnotStore: the sandboxed app and `knot-dev` share a store, the tool writes and the app shows it. From the deployment of the production schema on, the CloudKit schema is a committed file, and the gate fails on a change to it that is not additive.

**The soak.** The capture ledger soak runs under `scripts/verify.sh --soak`, on the harness that WP-06 builds. It runs at each milestone, and in the merge gate of any PR that touches the paths docs/architecture.md §17 lists, where `--gate` adds it from the diff. When the soak fails it prints its seed, its kill point and where the store was kept, and a soak failure is never retried to green.

**Tests.** Package tests use Swift Testing and UI tests use XCTest, as docs/architecture.md §17 states. Every port has a named implementer. Each real implementation of a port passes the contract suite of that port, where the suite can run. Tests required by name are listed in docs/architecture.md §17, each with its owner in `docs/plan/named-tests.txt`, and the gate fails when a listed test is missing once its package has merged. No automated test and no agent opens a hardware microphone on the build Mac, so start latency on a real microphone is measured at the owner's sittings.

**Thresholds.** The gate checks no accuracy threshold: thresholds belong to the package PRs that own them and to the milestones. Time thresholds are not merge criteria either. The gate asserts query plans and operation counts, and `scripts/verify.sh --perf` measures times at milestones and in WP-42, following the protocol in docs/product-spec.md §14.

**Availability.** The deployment target is 27.0. An API that first shipped in 27.1 or later is guarded or raises the stated minimum, and code must compile with the release Xcode installed at G1.

**Evaluation.** The synthetic cleanup and speech results are committed with the fixtures. A contributor's PR reruns the synthetic evaluation, and a meaning-critical case that passed and now fails blocks the PR. The orchestrator runs the local evaluation, on the owner's recordings, at the gate for a PR that touches speech or cleanup, and records the numbers. Until the owner's recordings exist, such a pull request merges on the synthetic evaluation, the numbers on his recordings follow, and M2 does not close without them.

**The nightly run.** The nightly run on `main` executes the package tests under Thread Sanitizer, and reports a model that changed with an update of the operating system. docs/architecture.md §18 says what else it runs.

**The scripts.** `scripts/verify.sh`, `scripts/build-slot.sh`, `scripts/install.sh`, `scripts/release.sh` and `knot-eval` follow docs/architecture.md §18. A verify run takes one tier, runs `scripts/doctor.sh` first and ends with one summary line. A failed step names its log and its rerun command.

**The plan check.** `scripts/check-plan.sh` checks the plan itself. It fails while `PLAN.md` still holds an amendment list, when a brief lacks a heading or still holds a quote that was replaced, and unless every item of the five amendment lists appears once in `docs/plan/amendments.md`. Its checks on the start conditions are in §6.

gstack reviews of the plan came first: `/plan-ceo-review` for scope, `/plan-eng-review` for architecture, tests and parallel lanes, `/plan-design-review` for the spec and the brief, and `/plan-devex-review` for the CLI and MCP. `/autoplan` ran them in sequence. Their record is in `docs/reviews/2026-11-19-plan-review.md`.

## 10. What Paolo does

| Gate | When | What | Minutes |
|---|---|---|---|
| G0 | 2026-11-19 | Done, and nothing is open at G0. He approved the plan, gave the answers that became D32 to D36, answered the 34 assumptions and the two readings that followed, and named his cadence: about an hour a day. | 30 |
| G0 | Wave 0 | Approve the restart PR and the licence wording. Done: the restart merged on 2026-11-19 as pull request 10. | 15 |
| G2 | Wave 0 | Review the brief, run the Claude Design direction step, choose a direction | 60 |
| G1 | With WP-01 | Confirm the identifiers, both the milestone set and the development set; install a release Xcode, which he did on 2026-11-19; pair the five devices for development builds; enable Automation Mode and developer mode once, with the two commands `scripts/doctor.sh` prints | 65 |
| G1 | With WP-01 | Extend the ruleset on `main` to require a pull request, squash merges, the status `knot/gate` and an up-to-date branch, and limit interactions to collaborators for the length of the build. Done on 2026-11-20: at his request the orchestrator set the rules. A pull request is required, squash is the only merge method, the checks `knot/gate` and `quick` are both required, the branch must be up to date, and nobody bypasses. Interactions are limited to collaborators until 2027-05-20 | 10 |
| G1 | With WP-01 | Register his other Mac for development-signed builds, and set up signing so that the gate's development-signed step runs without a prompt. Signing on the build Mac was set up on 2026-11-20 | 5 |
| G1 | With WP-01 | Create an App Store Connect record for the development identifier and an API key, for one internal TestFlight upload of the SP-3 spike app, and hand the key over as a file path through the secret prompt | 20 |
| G3 | After wave 1 | One spike sitting: SP-1 has 12 rows, and the SP-2 spike app runs its 30 transfers itself | 45 |
| G3 | After wave 1 | SP-5's rows on the Mac | 15 |
| G3 | After wave 1 | Install the SP-3 build from TestFlight and run its check, on his other Mac, where no Knot Dev build has run. On the build Mac the TestFlight build would be a new signer of the development identifiers' containers, and its first start would raise a consent dialog that has nothing to do with the app group. On a Mac where no Knot Dev build has run, no signer's dialog is expected, and any dialog is the group's | 15 |
| G3 | After wave 1 | Read the five spike reports and confirm their decisions | 20 |
| G3 | With SP-4 | Sign two simulators into iCloud with his additional Apple ID, one that is not tied to his developer account, for the second stage of the sync spike, once his signing is set up | 10 |
| G3 | With SP-4, after its first runs | Deploy the spike's schema to the production side of its throwaway container in the CloudKit Console, run the purge the spike asks for, and change the account once | 15 |
| G4 | Wave 0 | Record the read-aloud script and 10 spontaneous notes on two devices and move the files to the Mac. On 2026-11-20 he put this off | 30 |
| G4 | Before the full design round | Read the guard's table and the ten cleanup pairs; choose full cleanup, punctuation only or off | 20 |
| G2 | After the direction | Run the full Claude Design round and return the handoff | 90 |
| G2 | Before WP-40 starts | Read the handoff's gap list | 15 |
| G4 | M1 | Checklist | 15 |
| G4 | M2 | Checklist in three sittings, with locked and unlocked rows for each trigger, and the rows for Shortcuts, Siri and the live cue | 60 |
| G4 | Seven days after the M2 checklist has passed | The keep-gate sitting (§5) | 30 |
| G4 | M3 | Checklist | 30 |
| G4 | M4 | Checklist in three sittings: hotkey, CLI and MCP, two-device sync | 45 |
| G4 | M5 | Checklist | 20 |
| G4 | M6 | Checklist with the regression rows, and sign-off of the applied design | 90 |
| G4 | M2 to M5 | The VoiceOver rows, one per capture path | 5 each |
| G4 | M2 and M3 | A forced restart during a recording | 5 each |
| G4 | M2 and M4 | The rows for what injected audio cannot show | 5 in all |
| G4 | M1 to M7 | Repeat sittings after fixes: three each for M2, M3 and M4, one each for the others | 15 each |
| G4 | M1 to M7 | Free-form notes at the end of each milestone sitting, which the orchestrator turns into change requests | 10 each |
| G5 | After M5 | Approve the CloudKit production schema, before the first TestFlight build that syncs | 5 |
| G5 | M7 | Create Knot's own App Store Connect record, for `com.p3ob7o.knot`; authorise the TestFlight upload and supply an API key as a file path through the secret prompt; install over the M6 milestone build on each device | 30 |

His sittings come to about 18 hours across the build, including the repeat sittings. The owner gives about an hour a day, and the orchestrator plans the sittings on that.

- A checklist longer than 20 rows is split into two sittings.
- Gate G3 is the owner's sitting for confirming the spikes' decisions, and each spike is confirmed on its own.
- A spike or milestone sitting starts when `scripts/install.sh` has reported success. SP-1 and SP-2 each record the install procedure that worked on the iPhone and on the Watch, and the orchestrator corrects the script from those reports.
- The owner installed the release Xcode 27.2 (27B52) beside the beta on 2026-11-19, and WP-01 pins it in `.xcode-version`: it is the Xcode for the merge gate and for the archive.
- Without Automation Mode and developer mode, Mac UI tests wait on a password dialog that no agent can answer.
- An API key is requested through the secret prompt and never pasted into a thread. It is handed over for one upload and revoked after it, and each upload needs the owner's word.
- The owner makes the wave 0 recordings with Apple's Voice Memos, on the iPhone and on the Watch, and puts them in the one folder outside every worktree that `KNOT_LOCAL_FIXTURES` names.
- Until he has made them, speech and cleanup are measured on the synthetic clips alone, and the cleanup sitting of G4 has no pairs of his to read. He decided on 2026-11-20 that a pull request that touches speech or cleanup does not wait for them at the gate: it merges on the synthetic evaluation, the numbers on his recordings follow, and M2 does not close without them. The orchestrator does not raise the recordings themselves before M2's close, or before the cleanup sitting of G4 needs them.
- The owner's signing configuration is on the build Mac since 2026-11-20, in a file outside the repository that `KNOT_LOCAL_CONFIG` names. The team's ID never enters a tracked file, and the gate checks that.

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
3. Paolo: the Claude Design direction step and the recordings of wave 0. G0 holds nothing more (§3).
4. When the fold merges, launch WP-03, WP-04 and the first PR of WP-01. Paolo: G1.
5. When the first PR of WP-01 merges, launch the first PR of WP-02. The second PR of WP-01 runs beside it. Once WP-04 has merged too, launch the five spikes and the proof steps of WP-12, WP-13, WP-14 and WP-18.
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
- **Git.** Branch names `wp/…`, `spike/…`, `contract/…`. Never `master`. Never push to `main`. Never rebase a branch that was pushed, and never force a push. One branch for each PR. No session links in commits or PR descriptions. Commits are recorded in UTC.
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
against main. After the merge queue has updated your branch, fast-forward
to the remote branch before you change anything else. Never rebase a branch
you have pushed, and never force a push. When a PR of yours has been
squashed, start your next one on a new branch from origin/main.

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
