**Approved by Paolo on 2026-11-19.** Four gstack reviews read this plan, and he approved it at gate revision 2. The text of the plan still reads as first drafted. The four lists after Appendix C amend it, a fifth holds his answers on the assumptions of the product spec, and a later item wins over an earlier one. WP-00's fold rewrites it into one text.

## URGENT, outside this plan

None.

## Implementation plan
# Knot v1: build plan

Draft for review · 2026-11-18 · not yet reviewed with gstack

This plan drives a team of agents to rebuild Knot from an empty repository. It has four parts, which are one plan and are reviewed together:

- [docs/product-spec.md](docs/product-spec.md) says what Knot v1 does.
- [docs/architecture.md](docs/architecture.md) says how it is built.
- [docs/design/brief.md](docs/design/brief.md) is the brief for Claude Design.
- This file says how the work is split, ordered, checked and merged.

An agent working on one package reads `AGENTS.md`, the product spec, the architecture, and its own package section in §7. Nobody needs to read every package.

## 1. Summary

- **Product.** A capture tool for Mac, iPhone, iPad and Apple Watch. You type, speak or write by hand, and everything lands in one stream. Transcription and cleanup run on-device. Sync uses CloudKit and is optional.
- **Shape of the work.** 4 spikes and 29 work packages, in five waves. After two serial foundation packages, up to five agents work at once, each in its own T3 Code thread and worktree.
- **How parallel work stays safe.** Contracts come first: one package defines every interface and a fake for each. After that, each package owns its own folders and builds against the interfaces, so two agents rarely touch the same file.
- **What only Paolo can do.** Approve the plan, run the Claude Design round, test on hardware at each milestone, and authorise anything that signs or uploads.
- **Main risks.** Four facts the design rests on are unconfirmed, so four spikes run before the packages that depend on them: recording from a locked iPhone, getting recordings off the watch, command-line access to a sandboxed app's store, and the shape of CloudKit sync.

## 2. Decisions

These are Paolo's, from 2026-11-18.

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

## 3. Open questions

None are open. Q1 to Q8 were answered on 2026-11-18 and became D10 and D25 to D30. The product-level assumptions that remain are in product spec §16.

## 4. Scope

In v1, by device:

- **iPhone:** typing, voice with live text, the stream, search, editing, the Action Button and Lock Screen controls, widgets, Live Activity, Siri and Shortcuts.
- **iPad:** everything on iPhone, plus the Pencil canvas, a side-by-side layout and keyboard shortcuts.
- **Mac:** the one hotkey, the floating panel, hold-to-record, the main window, the menu bar item, the `knot` command and the MCP server.
- **Watch:** one-tap recording from a complication, widget, control or Double Tap, and delivery to the iPhone.
- **Everywhere but the watch:** on-device transcription and cleanup, optional iCloud sync, export.

Out of v1: see product spec §15.

## 5. Milestones

Each milestone is something Paolo can do on a device. Hardware checks come from `docs/checklists/`.

| ID | Name | Paolo can |
|---|---|---|
| M0 | Foundations | Read a new `main` holding the plan, the scaffold and the contracts. Read four spike reports. Hold a design brief ready for Claude Design. |
| M1 | Skeleton on four devices | Type a line on iPhone, iPad and Mac and find it in the stream after relaunch. Record on the Watch and see the voice segment arrive on the iPhone. Local only, system-default look. |
| M2 | iPhone voice and text | Press the Action Button, speak, and find a cleaned, titled note. Type notes, watch the append window work, search, edit, delete and undo. Kill the app while recording and lose nothing. |
| M3 | Watch voice | Tap the complication, record with the wrist down, and find the note transcribed on the iPhone, including after the phone was away. |
| M4 | Mac and sync | Tap the hotkey to type and hold it to record, over a full-screen app. Use `knot` and the MCP server from Claude Code. See notes sync both ways between iPhone and Mac. |
| M5 | iPad Pencil | Write by hand, search the handwriting, copy it as text, and see the drawing on the Mac and iPhone. |
| M6 | Designed | See the Claude Design handoff applied on all four devices, with accessibility and speed targets met. |
| M7 | TestFlight v1 | Install Knot from TestFlight on every device. |

M2 to M5 are functional gates. If the design handoff arrives early, WP-40 applies it to each platform before that platform's gate.

## 6. Waves and dependencies

| Wave | Starts when | Packages that can run in parallel |
|---|---|---|
| 0 | The plan is approved | WP-00, then WP-01, then WP-02, in series. Alongside them: WP-03 and WP-04. |
| 1 | WP-01 is merged | SP-1, SP-2, SP-3, SP-4 |
| 2 | WP-02 is merged | WP-10, WP-11, WP-12, WP-13, WP-14, WP-15, WP-18, WP-20, WP-21, and the text intents of WP-19 |
| 3 | Its own dependencies land | WP-16, WP-17, WP-22, WP-30, WP-31, WP-32, WP-33, WP-34, WP-35, and the recording intents of WP-19 |
| 4 | The handoff is in, or features are complete | WP-40, WP-41, WP-42, WP-43; WP-44 runs from M1 onward |

With five threads at a time, wave 2 starts in this order, which follows D16: WP-10, WP-21, WP-12, WP-11, WP-13, then WP-14, WP-15, WP-19, WP-18, WP-20.

The longest chain is WP-00, WP-01, WP-02, WP-10, WP-22, WP-30, then M2. The design chain runs beside it: WP-03, the Claude Design round, WP-40.

Sizes: S is under about 500 lines including tests. M is 500 to 2,000. L is larger, and ships as at least two PRs, the first being the thinnest slice that works end to end against real interfaces.

## 7. Work packages

### Wave 0: reset and foundations

#### WP-00 · Restart PR

S · after the plan is approved · run by the orchestrator

**Goal.** `main` holds only the new plan, the licence and the brand assets, and nothing from the old app is lost.

**Build**
- Create `archive/main-before-restart-2026-11-18` at the current head of `main`, following the existing `archive/…` branches. Add one commit there containing the untracked legacy files (`docs/design-brief.md`, `docs/design_handoff_knot/`, `docs/usage.md`, `docs/knot.pnm`). Push it. Do not move the `v0.2.0` tag, which points at an earlier commit.
- On branch `restart`, move `AppIcon.appiconset` and `KnotMark.imageset` (iOS and macOS), `docs/knot.svg`, `docs/knot.png` and the two `knot-mark` files into `Resources/Brand/`. Delete every other tracked file. Replace `LICENSE` with the GPL-3.0 text. Add the app store permission as `LICENSE-APPSTORE.md` and the contributions note to the README, both worded for Paolo to approve in the PR.
- Add `PLAN.md`, `docs/product-spec.md`, `docs/architecture.md`, `docs/design/brief.md`, a new `AGENTS.md` (Appendix A), `CLAUDE.md` importing it, a short `README.md` and a trimmed `.gitignore`.
- Remove the local leftovers git does not track: the "… 2" duplicate files, `Knot 2.xcodeproj`, `Knot 3.xcodeproj` and `build/`.

**Done when**
- `git ls-files` on `restart` lists only the files above.
- The archive branch is on `origin` and contains the legacy documents.
- The PR lists a checksum for each brand file, before and after the move.
- Paolo has approved and the PR is merged.

**Watch out.** The icon sources in `docs/` and the old handoff folder are untracked today. Deleting before archiving would lose them for good.

#### WP-01 · Scaffold

M · after WP-00 · owns `project.yml`, `Apps/`, `Packages/KnotKit/Package.swift`, `scripts/`, `.github/`, `.swift-format`, `docs/dev-setup.md`

**Goal.** A fresh clone builds four empty apps and an empty package with one command.

**Build**
- `Package.swift` with every module in architecture §3 as an empty target with one trivial test, GRDB pinned to an exact version, and platform minimums of 27.
- XcodeGen targets, one YAML file per target, included from `project.yml`: `Knot-iOS` (universal), `Knot-watchOS` (a companion embedded in the iOS app), `Knot-macOS`, `Widgets-iOS`, `Widgets-watchOS`, and the `knot` executable embedded in the Mac app. Each app launches to a placeholder showing the mark.
- Entitlements and Info.plist keys: microphone usage string, background audio, app group, iCloud with CloudKit, push. Identifiers are constants in one xcconfig.
- `scripts/bootstrap.sh`, `scripts/verify.sh --quick|--full`, `scripts/build-slot.sh`, `scripts/sim.sh`, and per-worktree DerivedData.
- Swift 6 mode, strict concurrency complete, warnings as errors.
- The watchOS 27 simulator runtime, installed, with the command documented. Only iOS runtimes are on the machine today.
- A GitHub Actions workflow running `verify.sh --quick`, if a hosted runner offers Xcode 27. If none does, say so in `docs/dev-setup.md`.

**Done when**
- On a fresh clone, `scripts/bootstrap.sh && scripts/verify.sh --full` passes.
- The three apps launch (iOS Simulator, watchOS Simulator, Mac) and show the placeholder.
- Two worktrees run `verify.sh --full` at the same time without interfering.

**Watch out.** This package declares every target and resource folder up front, so later packages do not need to edit `Package.swift` or `project.yml`.

#### WP-02 · Contracts and fakes

M · after WP-01, in the same thread · owns `Sources/KnotCore/`, `Sources/KnotTesting/`, and the preview environment in `Sources/KnotApp/`

**Goal.** Every interface exists with a working fake, so every later package can start in parallel.

**Build**
- The domain types and ports in architecture §4 and §5.
- The append rule as a pure function, with table-driven tests for every rule in product spec §3, late arrivals included.
- Segment state machines as pure reducers, with tests for every transition and every illegal one.
- The settings model, feature gates (`sync`), an error taxonomy and the logging facade.
- KnotTesting: an in-memory `NoteStore`; scriptable `Recorder`, `Transcriber`, `Cleaner`, `InkRecogniser`, `WatchLink` and `SyncEngine`; a fake clock; builders for notes and segments; one shared contract test suite per port.
- `AppEnvironment.preview`.

**Done when**
- `swift test` passes on the Mac.
- Every port has a fake, and every fake passes its contract suite.
- architecture §4 and §5 match the code.

**Watch out.** After this merges, the public API of KnotCore changes only through a contract PR (§8.5).

#### WP-03 · Design brief

S · drafted on 2026-11-18, waiting for Paolo's review · owns `docs/design/brief.md`

**Goal.** Claude Design has what it needs to design every Knot surface in one round.

**Build**
- The product on one page, taken from the spec: the promises, the vocabulary, the append window.
- The one fixed brand element: the icon and mark.
- Every surface to design, by device, with the states each must cover: empty, typing, recording, pending, failed, appending to an open note, search results, conflict.
- The interaction questions the designer should answer:
  - how the stream and the capture field relate on iPhone;
  - how the note being appended to appears in the capture surface;
  - how segments of different kinds read as one note;
  - the Mac panel while typing and while recording;
  - the recording Live Activity and Dynamic Island;
  - the watch recording screen;
  - how typing and Pencil share the iPad capture surface.
- Constraints: system materials, light and dark, Dynamic Type, VoiceOver, SF Symbols, and exact device sizes (iPhone 17 Pro, iPad mini, the Mac panel and window, Watch).
- The handoff format wanted: tokens, a component inventory, per-screen specs and motion. The previous handoff on the archive branch shows the format Claude Design returns.

**Done when.** Paolo approves the brief. He then runs Claude Design, and the handoff is committed to `docs/design/handoff/` (gate G2).

#### WP-04 · Fixtures and device checklists

S · starts with WP-00 · owns `Fixtures/`, `docs/checklists/`

**Goal.** Packages share test data, and Paolo has a step-by-step list for each hardware test.

**Build**
- Audio fixtures generated by a script from text, using the system voices: clean speech, speech with scripted fillers and self-corrections, a list, numbers and names, silence, a 10-minute file and a noisy file. Each has a reference transcript.
- A cleanup evaluation set: 30 raw transcripts, each with notes on what a correct cleanup keeps and removes.
- Ink fixtures built from Bézier paths: a line of handwriting, a list and a sketch.
- One checklist per milestone, M1 to M7. Each row is one action, its expected result, and a pass or fail box.

**Done when.** The generation script is reproducible, and the checklists cover every hardware item in architecture §17.

**Watch out.** Paolo's own recordings go in a git-ignored local folder and are never committed.

### Wave 1: spikes

A spike answers questions. Its code stays on its `spike/…` branch and is never merged. Its report merges to `docs/spikes/`, ends with a decision, and updates architecture.md where the answer changes it.

#### SP-1 · Recording from a locked iPhone

S · after WP-01 · needs the iPhone 17 Pro

**Questions**
- Does an intent conforming to `AudioRecordingIntent` and `LiveActivityIntent` start recording from the Action Button and from a Lock Screen control, while the phone is locked and Knot is not running?
- What happens when Live Activities are off, or the microphone permission is missing?
- How long is it from the press to the first captured sample?
- Does transcription finish in the background after stop? Try `LongRunningIntent.performBackgroundTask` and a continued-processing background task.
- Which file protection class does this need?

**Output.** A minimal app on `spike/locked-recording`. `docs/spikes/SP-1.md` with a result matrix (locked or unlocked, app running or terminated, each trigger), the latencies and a decision.

**Paolo.** Installs the build and runs a 12-row checklist, about 15 minutes.

**Gates** WP-19 and WP-31. If a locked start fails, the control opens Knot after Face ID and recording starts at once.

#### SP-2 · Watch capture and delivery

S · after WP-01 · needs the Apple Watch Ultra 2 and the iPhone

**Questions**
- Does recording continue with the wrist down and the screen off?
- How long is it from a complication tap to the first sample?
- Can a watch control or `AudioRecordingIntent` start a recording without bringing the app forward? watchOS has no Live Activities, so Apple's iOS recipe does not apply.
- Does a control bound to the Ultra's Action Button start a recording directly?
- How long does `transferFile` take, and how often does it stall, with the phone near, with the phone away and then back, and with the iPhone app terminated?
- Is the iPhone app woken to receive the file?

**Output.** `spike/watch-delivery`. `docs/spikes/SP-2.md` with timings over at least 30 transfers and a decision.

**Paolo.** Installs the build on the iPhone and the Watch and runs the delivery checklist.

**Gates** WP-17 and WP-32.

#### SP-3 · Command-line access to the store

S · after WP-01

**Questions**
- Can a sandboxed executable inside the Mac app bundle, started from Terminal or by an MCP client, open the app's SQLite store in the app group container for reading and writing, in a TestFlight-signed build, with no consent prompt?
- Which entitlements and bundle layout does that need?
- How does a sandboxed app put the command on the user's PATH?
- Does it work while the app is running, and does the app see the change?
- How do two or three shipping Mac App Store apps deliver a CLI or an MCP server?

**Output.** `spike/agent-access`. `docs/spikes/SP-3.md` with a decision between direct store access and XPC to the running app.

**Gates** WP-34, and the second-process rules in WP-10.

#### SP-4 · CloudKit sync shape

M · after WP-01 · needs the iCloud container and two signed-in devices or simulators

**Questions**
- Does the design in architecture §11 hold: an engine-managed zone for notes and segments, and an attachments zone kept out of automatic fetches and read on demand?
- Do encrypted fields work for all text?
- Can a trigger-fed change log drive the engine's pending changes, including writes from another process?
- How large does the engine's serialised state grow?
- How long does a fresh install take to restore 5,000 notes, 20,000 segments and their deletions?
- What do toggling sync off and on, and changing iCloud account, do?

**Output.** `spike/sync-shape`. `docs/spikes/SP-4.md` with the final CloudKit schema.

**Gates** WP-16, and the sync columns in WP-10.

### Wave 2: modules

#### WP-10 · Store

L · after WP-02 · owns `Sources/KnotStore/`, `Tests/KnotStoreTests/`

**Goal.** Notes and their files are stored durably, are searchable, and stay safe through crashes and a second process.

**Build**
- Everything in architecture §7: the pool and its settings, schema version 1 and the migrator, repositories implementing `NoteStore` and `AssetStore`, the FTS5 index and search, the trigger-fed change log, soft delete and purge, the pre-migration copy.
- Asset files placed by atomic move and verified by SHA-256.
- iOS file protection as specified.
- Change streams for the UI.

**Done when**
- The real store passes the same `NoteStore` contract suite as the fake.
- A process killed in mid-transaction leaves a consistent database.
- A second process reads and writes concurrently on macOS.
- With 10,000 notes on the Mac, a stream page loads in under 16 ms and a search returns in under 50 ms.

**Watch out.** On iOS the system kills a process that is suspended while holding a lock on a database in a shared container. That is why extensions never open the database.

#### WP-11 · Capture engine

M · after WP-02 · owns `Sources/KnotCapture/Engine/`

**Goal.** Typed, spoken and drawn captures become segments in the right note, and typed text is never lost.

**Build**
- The `CaptureEngine` actor. For typed captures: begin, update and end, with saves at most 150 ms behind the last keystroke and a flush on end, background and termination.
- Voice and ink captures, run through the `Recorder` and ink ports.
- The session tracker: the append rule, "New note", and appends to an explicit note.
- Placement of late arrivals, for the ingestor.
- Empty captures discarded.

**Done when**
- Every rule in product spec §3 has a test that uses the fake clock.
- Text saved before a simulated kill is present after relaunch.
- A randomised test finds no sequence of begin, update and end that loses saved characters.

#### WP-12 · Recorder

L · after WP-02 · owns `Sources/KnotAudio/`

**Goal.** A recording starts fast, survives anything, and ends as a small verified file.

**Build**
- Proof first: choose the crash-tolerant format with a kill test on the Mac and the iOS Simulator, and measure start latency. Report both in the first PR.
- `Recorder` on AVFAudio for iOS, iPadOS, macOS and watchOS.
- The manifest written before the first sample, and recovery of orphaned recordings.
- Level metering for the waveform.
- Interruptions (calls), route changes (AirPods connecting) and the 30-minute cap.
- Conversion to AAC `.m4a` after stop, verified before the working file is deleted.
- A hook that hands live buffers to a `Transcriber`.

**Done when**
- File-driven input produces the expected output.
- Killing the process during recording loses at most 1 second.
- Interruption and route-change tests pass.

**Watch out.** The watch needs the same guarantees with a small file, about 0.5 MB per minute, because the file travels over Bluetooth.

#### WP-13 · Speech

M · after WP-02 · owns `Sources/KnotSpeech/`

**Goal.** A saved recording becomes an accurate English transcript on-device.

**Build**
- Proof first: transcribe the fixtures on the Mac, and report word error rate and speed.
- `Transcriber` on `SpeechAnalyzer` and `SpeechTranscriber`: asset installation with status and retry, the choice of English locale, live results, file transcription with time ranges, cancellation and availability.

**Done when**
- Integration tests pass on a Mac with the model installed, and report "skipped: model unavailable" elsewhere.
- Word error rate on the clean fixtures is at most 8%.
- No audio or text reaches a log.

#### WP-14 · Cleanup

M · after WP-02 · owns `Sources/KnotCleanup/`

**Goal.** A raw transcript becomes clean text and a title without changing what was said, or it is left alone.

**Build**
- The fidelity guard first, as a pure function with tests.
- `Cleaner` on Foundation Models: instructions, guided generation of title and body, token budgeting with the model's own counts, chunking on sentence boundaries, and availability.
- An evaluation command that runs the 30-transcript set and prints the pass rate.

**Done when**
- The guard tests pass.
- The evaluation result is in the PR, with ten examples of input and output for Paolo to read.
- A 10-minute transcript is cleaned in chunks with nothing dropped.
- A result the guard rejects never reaches the store.

**Watch out.** Evidence on quality is thin (architecture §20). If the pass rate is poor, Paolo chooses between punctuation-only cleanup and cleanup off by default.

#### WP-15 · Processing and ingest

M · after WP-02 · owns `Sources/KnotCapture/Processing/`, `Sources/KnotCapture/Ingest/`

**Goal.** Every recording is transcribed and cleaned eventually, whatever interrupts it, and outside captures enter exactly once.

**Build**
- The durable job queue: transcribe, clean and title, recognise; retry with backoff; resume at launch.
- Hooks for background execution on iOS, using the mechanism SP-1 chooses.
- The inbox ingestor: idempotent by capture ID, with late-arrival placement.
- Pending and failed states published through `NoteStore`.

**Done when**
- With scripted fakes, a failure at every step leaves a recoverable state.
- A duplicate inbox item is ingested once.
- Late arrivals land in the right note, in the right order.

#### WP-18 · Ink

M · after WP-02 · owns `Sources/KnotInk/`

**Goal.** Handwriting is captured without lag, kept as ink, and searchable as text.

**Build**
- Proof first: recognise the ink fixtures in the Simulator, and report accuracy and latency.
- The canvas wrapper, with a minimal tool set and a growing canvas, saving at the end of every stroke. Pencil Pro squeeze, barrel roll and hover work as the system tool picker provides them.
- Recognition through `PKStrokeRecognizer`, the read-only renderer, and PNG rendering for export.
- The Pencil-capability check.

**Done when**
- Fixture tests pass.
- Strokes saved before a kill are present after relaunch.
- The M5 checklist passes on the iPad mini.

**Watch out.** Nobody on the project owns an iPhone Duo. That path ships untested on hardware.

#### WP-19 · Intents

M · text intents after WP-02, recording intents after SP-1 · owns `Sources/KnotIntents/`

**Goal.** Every system surface starts a capture through one shared set of intents.

**Build.** The intents in architecture §14, App Shortcuts with phrases, a note entity with a query, and the watch variants.

**Done when**
- Each intent's `perform()` is tested against the fake environment.
- The intents appear and run in Shortcuts on the Simulator.
- The M2 checklist passes.

#### WP-20 · Export

S · after WP-02 · owns `Sources/KnotExport/`

**Goal.** A note renders as clean Markdown, and the whole stream exports to a folder.

**Build.** Note to Markdown, with small flat front matter (ID, created, updated). Share items for text, Markdown, audio and image. Export of everything, with deterministic file names.

**Done when.** Golden-file tests pass.

#### WP-21 · UI foundation

L · after WP-02 · owns `Sources/KnotUI/`

**Goal.** Every screen's behaviour exists and is tested before the design arrives.

**Build**
- The theme layer, with placeholder values.
- View models for the stream, a note, capture, search and settings.
- Components: the stream row, the three segment views with their states, the capture field, record button, waveform, audio player, pending and failed markers, search field and settings forms.
- VoiceOver labels and Dynamic Type from the first PR.

**Done when**
- View-model tests pass.
- Previews compile for iOS, macOS and watchOS on `AppEnvironment.preview`.
- No view imports a storage module.

### Wave 3: integration and apps

#### WP-16 · Sync

L · after SP-4 and WP-10 · owns `Sources/KnotSync/`

**Goal.** Notes, edits, deletions and attachments converge across iPhone, iPad and Mac, and nothing is silently overwritten.

**Build**
- Everything in architecture §11, as amended by SP-4.
- Status: idle, syncing, error, quota exceeded, no account.
- Diagnostics: counts, last sync time, last error code.

**Done when**
- Mapping, conflict and change-log tests pass with constructed records.
- A two-replica simulation converges after any interleaving of edits, appends and deletes.
- A fresh install restores within the time SP-4 set.
- The two-device rows of the M4 checklist pass.

**Watch out.** The production CloudKit schema cannot drop fields. Deploy it only when Paolo approves.

#### WP-17 · Watch link

M · after SP-2 · owns `Sources/KnotLink/`

**Goal.** A recording made on the watch reaches the iPhone once, and the watch knows that it did.

**Build.** Everything in architecture §12, behind a `LinkTransport` protocol with a fake.

**Done when**
- With the fake transport, tests pass for loss, duplication, reordering and a lost acknowledgement.
- The M3 checklist passes on hardware.

#### WP-22 · Composition and end to end

M · after WP-10 to WP-15 · owns `Sources/KnotApp/`, `Tests/KnotEndToEndTests/`

**Goal.** The real modules work together, proven by tests that take a capture from audio to a finished note.

**Build**
- `AppEnvironment.live` for each platform.
- The launch sequence: open the store, recover recordings, ingest the inbox, resume jobs, start sync if it is on.
- Signposts for every target in product spec §14.
- End-to-end tests: fixture audio to a cleaned note; typed sessions; a kill and relaunch at each stage.

**Done when.** The suite passes on the Mac and the iOS Simulator.

#### WP-30 · iPhone app

L · after the first PR of WP-21 · owns `Apps/iOS/` except `Apps/iOS/iPad/`

**Goal.** On an iPhone, typing and speaking a note feel instant, and nothing is lost.

**Build**
- Launch straight into capture with the keyboard up.
- In-app recording with live text.
- The stream, the note view with in-place editing, search, delete and undo, and share.
- Settings, the permission flow, deep links for intents, and a flush on background and termination.

**Done when**
- UI tests pass: type and see it in the stream; record with injected audio and see a voice segment; search; delete and undo.
- A launch-time test meets the warm target.
- The M2 checklist passes.

#### WP-31 · iPhone system surfaces

M · after SP-1 and WP-19 · owns `Apps/Extensions/Widgets-iOS/`

**Goal.** Recording starts from the Action Button, the Lock Screen and Control Center without opening Knot.

**Build.** Controls (Record, New note, and Sketch on iPad). Lock Screen and Home Screen widgets. The recording Live Activity, with timer and stop. The Action Button tip in Settings.

**Done when.** Widget previews render, and the M2 checklist rows for the Action Button, Lock Screen and Control Center pass, locked and unlocked.

#### WP-32 · Watch app

L · after SP-2 and WP-17 · owns `Apps/watchOS/`, `Apps/Extensions/Widgets-watchOS/`

**Goal.** Raising the wrist and tapping once records a thought that reaches the phone.

**Build**
- The recording screen: one control, Double Tap as its primary action, haptics, a timer and a waveform.
- Recording with the wrist down.
- Recent captures with their delivery state.
- Complications in every family, a Smart Stack widget, and a control for Control Center and the Ultra's Action Button.

**Done when.** Simulator UI tests pass, and the M3 checklist passes on hardware.

#### WP-33 · Mac app

L · after the first PR of WP-21 · owns `Apps/macOS/`

**Goal.** From any app, one key opens Knot ready to type, and holding it records.

**Build**
- Proof first: hotkey press and release, and the panel over a full-screen app, in a sandboxed build.
- The tap-or-hold state machine, the panel, and hold-to-record with live text.
- The menu bar item, main window, settings with a hotkey recorder, launch at login and the microphone flow.

**Done when**
- The tap-or-hold state machine is tested with the fake clock.
- UI tests pass for the main window.
- The M4 checklist passes: latency, full-screen apps, several displays and Spaces.

#### WP-34 · CLI and MCP

M · after SP-3, WP-10 and WP-20 · owns `Sources/KnotAgent/`, `Sources/knot/`, `docs/cli.md`

**Goal.** An agent or a shell script reads and writes notes safely.

**Build.** The commands in product spec §10, with `--json`. The MCP server. The install step from the Mac app.

**Done when**
- Golden tests pass for every command's output.
- Tests drive the binary over standard input and output, through the MCP handshake and each tool.
- A write made while the app is running appears in the app.
- Paolo can use it from Claude Code on his Mac.

#### WP-35 · iPad

M · after WP-30 and WP-18 · owns `Apps/iOS/iPad/`

**Goal.** On an iPad, the Pencil starts a note as readily as the keyboard.

**Build.** The side-by-side layout. Pencil on the capture surface starting an ink segment. The Sketch control and intent. Keyboard shortcuts and the menu bar. The Pencil-capable iPhone path.

**Done when.** iPad Simulator UI tests pass, and the M5 checklist passes.

### Wave 4: design and hardening

#### WP-40 · Design system

L · after gate G2 · owns `Sources/KnotUI/Theme/`, then one sub-package per platform (40a iPhone, 40b iPad, 40c Mac, 40d Watch), each owning that platform's views

**Goal.** Knot looks and moves as designed on every device.

**Build.** Tokens translated from the handoff. Components restyled. Each platform's screens matched to the handoff.

**Done when.** Every screen and state in the handoff has a side-by-side screenshot. Findings from gstack `/design-review` and `/ios-design-review` are resolved. Paolo signs off.

#### WP-41 · Accessibility

M · after WP-40

**Goal.** Knot is fully usable with VoiceOver, large text and the keyboard.

**Done when.** An Accessibility Inspector audit is clean on each platform. Every flow in the checklist works with VoiceOver and at the largest text size. The Mac and iPad work without a pointer.

#### WP-42 · Performance

M · after WP-22

**Goal.** Knot meets the targets in product spec §14, or the targets are corrected with evidence.

**Done when.** Each target has an automated measurement or a checklist measurement, and the report sets measured values against targets.

#### WP-43 · Release readiness

M · after M5

**Goal.** A signed build can go to TestFlight the moment Paolo says so.

**Build.** The privacy manifest, usage strings, an entitlement audit, icon sets for every platform from the kept mark, a `scripts/release.sh` that fails closed, a README and short user guide, and third-party notices.

**Done when.** A dry run of the release script passes every check short of uploading.

**Watch out.** Uploading needs Paolo's explicit authorisation and an App Store Connect API key. The key is requested through the secret prompt and never pasted into a thread.

#### WP-44 · QA campaign

Continuous from M1.

**Goal.** Tools find bugs before Paolo finds them by hand.

**Build.** gstack `/ios-qa` and `/qa-only` at each milestone, `/cso` before TestFlight, and `/health` and `/test-audit` at M4 and M7. Each finding becomes a small fix thread.

## 8. Running the team in T3 Code

### 8.1 Roles

| Role | Who | Does |
|---|---|---|
| Orchestrator | The T3 Code thread that wrote this plan | Launches package threads, tracks status, arranges reviews, merges. |
| Implementer | One thread per package, on Claude Opus 5.5, in its own worktree | Builds one package and opens its PR. |
| Reviewer | One fresh thread per PR | Reviews the diff against the package section and `AGENTS.md`. |
| Paolo | | Approves the plan and passes the gates in §10. |

### 8.2 Launching a package

- One top-level thread per package, created with `t3_thread_launch`.
- Workspace: a new worktree from `origin/main`, on branch `wp/<number>-<slug>`. A package stacked on unmerged work starts from that local branch instead.
- Model: `claude-opus-5-5`. Effort `high` by default, and `xhigh` for WP-10, WP-12 and WP-16, where a mistake loses data.
- First message: the prompt in Appendix B.

### 8.3 What a thread hands back

Its final message states what was built, what was verified and how, what remains unverified because it needs hardware, and any departure from the brief. It ends with the PR URL, the head commit and the state of the checks.

A thread that finds its brief wrong or blocked stops and says so. It does not widen its scope.

### 8.4 Review and merge

1. The implementer runs `scripts/verify.sh --quick` before opening the PR.
2. A reviewer thread runs gstack `/review` on the PR. WP-10, WP-12, WP-15 and WP-16 also get a second opinion from a different model through `/codex`.
3. The implementer fixes the findings. After two rounds, the orchestrator decides what is left.
4. The orchestrator rebases the branch on `main`, runs `scripts/verify.sh --full`, and squash-merges.
5. The orchestrator removes the worktree and updates `docs/status.md`.

Merges follow the dependency order in §6.

### 8.5 Contracts and shared files

- A change to KnotCore's public API goes in its own small PR on a `contract/…` branch, with the fakes updated. The orchestrator merges it first and tells the threads that depend on it to rebase.
- `Package.swift`, `project.yml`, `AGENTS.md`, `PLAN.md`, `docs/product-spec.md` and `docs/architecture.md` belong to the orchestrator. A package that needs a change there asks for it in its PR description.
- A package edits only the paths it owns.

### 8.6 Limits

- Five implementer threads at a time, to start with. The machine has 16 cores and 48 GB of memory.
- Three heavy builds at a time, enforced by `scripts/build-slot.sh`.
- Worktrees are removed after merge. Each holds several gigabytes of build products.

### 8.7 Status

`docs/status.md` is one table: package, state, thread, PR. Only the orchestrator edits it.

## 9. Checks

A PR is done when all of these hold:

- Its package's "Done when" list is met, with the evidence in the PR description.
- `scripts/verify.sh --full` passes on the merge result.
- New behaviour has tests. Storage, capture, ingest and sync have failure-path tests.
- No note text, transcript or audio appears in logs, test output or fixtures.
- Any OS 26 or OS 27 API used is named in the PR with the declaration that was read (architecture §21).
- Anything that could not be verified without hardware is listed, and has a row in a checklist.

gstack reviews of the plan come first: `/plan-ceo-review` for scope, `/plan-eng-review` for architecture, tests and parallel lanes, `/plan-design-review` for the spec and later the brief, and `/plan-devex-review` for the CLI and MCP. `/autoplan` runs them in sequence.

## 10. What Paolo does

| Gate | When | What |
|---|---|---|
| G0 | Now | Run the gstack plan reviews and approve the plan. |
| G1 | With WP-01 | Confirm the identifiers: app IDs under `com.p3ob7o.knot`, app group `group.com.p3ob7o.knot`, iCloud container `iCloud.com.p3ob7o.knot`. Allow Xcode's automatic signing to register them. |
| G2 | After WP-03 | Run the brief through Claude Design and return the handoff. |
| G3 | After wave 1 | Run the spike checklists on the iPhone and the Watch. |
| G4 | At M1 to M6 | Run the milestone checklist on hardware. |
| G5 | At M7 | Authorise the TestFlight upload and supply the App Store Connect API key through the secret prompt. |

Also wanted, when convenient: 10 to 20 real English voice notes for the cleanup evaluation, kept in the git-ignored folder.

## 11. Risks

| Risk | If it happens | Response |
|---|---|---|
| Recording cannot start from a locked iPhone | The Action Button needs Face ID first | The control opens Knot and recording starts at once. SP-1 decides early. |
| Watch delivery is unreliable | Recordings arrive late or need a retry | The durable outbox and re-send mean nothing is lost. SP-2 measures delivery on the Ultra 2 early. |
| On-device cleanup quality is poor | Cleaned notes change meaning or read badly | The guard rejects bad results. Paolo chooses punctuation-only or off by default. A cloud option is a later feature. |
| CKSyncEngine is harder than planned | Sync lands late | Knot is fully usable on each device without sync. Sync has its own lane and its own gate. |
| The design handoff arrives late or changes structure | UI rework | Behaviour lives in view models. Views are thin and restyled in WP-40. |
| Agents write OS 27 APIs from stale memory | Code that does not compile, or misuses an API | The read-the-SDK rule in architecture §21, and the spikes. |
| Parallel agents collide | Merge conflicts, drifting interfaces | Contracts first, owned paths, contract PRs, one owner for shared files. |
| A sandboxed CLI cannot reach the store | No direct command-line access | XPC to the running app. SP-3 decides early. |
| The machine is overloaded | Slow or flaky builds | The thread and build limits in §8.6. |
| Nobody can test the iPhone Duo | A Pencil path ships unverified | It sits behind a capability check and is stated as untested. |

## 12. First steps after approval

1. Fold in Paolo's answers and the gstack review findings.
2. Open the restart PR (WP-00). It doubles as the spec PR.
3. Launch WP-01, WP-03 and WP-04.
4. Paolo: G1, and the Claude Design round once WP-03 is approved.
5. When WP-01 merges, launch the four spikes, and continue WP-02 in the scaffold thread.
6. When WP-02 merges, launch wave 2 in the order given in §6.

## Appendix A. The new AGENTS.md

WP-00 writes it with these sections:

- **Product contract.** Five lines, pointing to the spec. Knot has no account, server or telemetry, and one third-party library, GRDB.
- **Sources of truth.** `docs/product-spec.md`, `docs/architecture.md`, `PLAN.md`. `project.yml` owns targets and settings. Never edit the generated project.
- **Boundaries.** The rules in architecture §6. Views never touch storage. Extensions never open the database. Sync runs only in the app.
- **Hard rules.**
  - Never log note text, transcripts, audio or content-derived paths.
  - No network use except CloudKit and Apple's model downloads.
  - No new dependency without Paolo's approval.
  - Swift 6 strict concurrency; warnings are errors.
  - Synthetic fixtures only. No real notes, recordings, credentials or signing material in tests or commits.
  - Read the SDK before using an OS 26 or OS 27 API.
- **Working in parallel.** Edit only the paths your package owns. Contract changes and shared files go through the orchestrator.
- **Git.** Branch names `wp/…`, `spike/…`, `contract/…`. Never `master`. Never push to `main`. No session links in commits or PR descriptions.
- **Needs Paolo's explicit authorisation.** Moving a tag, signing, notarising, uploading, deploying the CloudKit production schema, deleting an archive branch.
- **Commands.** `scripts/bootstrap.sh` and `scripts/verify.sh`, with `DEVELOPER_DIR` scoped to the command.

## Appendix B. Thread prompt

```
You are implementing work package <ID> of the Knot v1 build.

Read, in this order: AGENTS.md, docs/product-spec.md, docs/architecture.md,
then the section "<ID>" in PLAN.md. You do not need the other package sections.

Your section says what you own, what "done" means, and what to watch out for.
Edit only the paths you own. If the brief is wrong or you are blocked, stop and
say so in your final message instead of widening the scope.

Before using any OS 26 or OS 27 API, read its declaration in the SDK
(docs/architecture.md, section 21).

Work on the branch you are on. Run scripts/verify.sh --quick, then open a PR
against main. In your final message, state what you built, what you verified
and how, what needs hardware, and any departure from the brief. End with:
PR <url>, head <sha>, checks <state>.
```

## Appendix C. PR description

- Package ID and goal, in one line.
- What changed, in a few bullets.
- Evidence for each "Done when" item: the command and its result.
- OS 26 and OS 27 declarations read.
- Not verified, and where it will be checked.
- Requests to the orchestrator: contract changes, shared-file edits.

<!-- autoplan-accepted:ceo -->
- The items below amend the plan above. Where an item contradicts earlier text, the item wins. The earlier text is rewritten after the owner approves this review.
- A new package, WP-05 Capture tracer, runs after WP-02 and before wave 2. Its size is M. It owns `Sources/KnotCapture/` until it merges, and the preview environment in `Sources/KnotFakes/Preview/`. It builds the thinnest real `CaptureEngine` and `ProcessingQueue` and one end-to-end test. In that test a typed capture and a fixture recording go through the engine, the queue, the in-memory `NoteStore` and the scripted `Recorder`, `Transcriber` and `Cleaner`, and the assertions read the stream page that `NoteStore` publishes. WP-05 merges when four things hold: the end-to-end test passes in `swift test`; a capture row is written before any content, for typed and for voice; `.preview` runs the real engine and queue over the fakes on iOS and macOS; and every contract correction it found has merged as a contract PR. WP-11 and WP-15 then extend its two halves. The proof-first steps of WP-12, WP-13, WP-14 and WP-18, and all of WP-20, may run beside WP-05. Every other wave 2 package starts when WP-05 merges.
- The plan now has 30 work packages and about 50 PRs, before contract PRs and fix PRs. WP-02, WP-12 and WP-22 ship in two PRs each, and WP-19 in three: the text intents, then the recording intents for iPhone, iPad and Mac, then the watch intents. For WP-02 the first PR holds the domain types, the rules and the reducers, and the second holds the ports, the fakes and the contract suites. For WP-12 the first PR is the format proof and a recorder that records and stops on every platform, and the second is everything else. For WP-22 the first PR is the composition and the second is the end-to-end suite and the soak test.
- The test and preview code is three targets, replacing KnotTesting, and docs/architecture.md §3 lists them. KnotFakes holds the fakes, the fixture builders and the preview environment, imports no test framework, and is linked by debug builds of the apps only. KnotTestSupport holds the shared contract suites and is used by test targets only. KnotUIPreviews holds the SwiftUI previews. `AppEnvironment` is declared in KnotCore with an `.unavailable` value. The factory in KnotApp returns `.unavailable` from WP-01, `.preview` in debug builds from WP-05, and `.live` from the first PR of WP-22, with any port not yet implemented filled by the unavailable one. UI tests select `.preview` with a launch argument that only debug builds honour.
- WP-02 owns `Sources/KnotCore/`, `Sources/KnotFakes/` except its `Preview/` folder, and `Sources/KnotTestSupport/`. Its fake list adds `AssetStore`, `AudioPlayer`, `AssetFetcher`, `RecordingStateStore`, `RecordingActivity` and `SettingsStore`. `CaptureEngine` and `ProcessingQueue` are not faked. Its domain types add `Capture`, `closedAt` on `Note`, and `transcription` and `processingOwner` on `Segment`. Two operations are part of its contracts: `NoteStore` records a capture in one transaction, applying the append rule and writing the capture row and the segment, and `CaptureEngine` publishes the revision of the content that is durably saved. Its append-rule tests cover rules 9 to 15 of docs/product-spec.md §3, and the rule is written as an ordered list of small rules, first match wins, each with its own test table. Before WP-02 starts, the owner confirms the assumptions still open in docs/product-spec.md §16, because WP-02 turns them into tests.
- Every port has an implementer. WP-12 implements `Recorder`, `AudioPlayer` and `RecordingStateStore`. WP-10 implements `NoteStore` with the capture rows and the one-transaction capture operation, `AssetStore`, `SettingsStore` and the local-only `AssetFetcher`. WP-16 implements `SyncEngine` and the syncing `AssetFetcher`. WP-30 implements `RecordingActivity`, the app-side code of the Live Activity, and WP-31 owns its views. Each implementation passes the contract suite of its port. The `knot` command and the MCP server write through the same `NoteStore` operation as the engine, so the append rule runs in one place.
- WP-10, WP-11, WP-33 and WP-43 each gain a "Prior art" line naming archived code to read before writing. WP-10 reads `Packages/KnotKit/Sources/KnotKit/Persistence/`. WP-11 reads the draft checkpointing in `Knot/Shared/EditorModel.swift`. WP-33 reads `Knot/macOS/Hotkey/`, `Knot/macOS/SurfaceCoordinator.swift` and `Knot/macOS/MenuBarController.swift`. WP-43 reads `scripts/release.sh`. All are on the branch `archive/main-before-restart-2026-11-18`. Prior art is read, not copied: the old hotkey adapter registers press events only. Each PR description names what it read.
- Real recordings. WP-04 adds a read-aloud script of 10 short English passages with known text, and asks for 10 spontaneous voice notes. The owner records both with Apple's Voice Memos, on the iPhone and on the Watch, in wave 0, so that the proof steps of WP-13 and WP-14 run on them beside WP-05. He puts the files in the git-ignored folder `Fixtures/local/`, named `read-aloud-<number>-<device>.m4a` and `note-<number>-<device>.m4a`. An executable target `knot-eval`, declared by WP-01 and listed in docs/architecture.md §3, reads that folder. WP-13 owns `knot-eval speech`, which runs first, writes transcripts into the same folder and prints word error rate on the read-aloud set. WP-14 owns `knot-eval cleanup`, which then writes ten input and output pairs to a git-ignored file for the owner to read. Neither command prints text from the recordings, and nothing derived from them enters a commit, a PR, a log or a test. Examples shown in PRs stay synthetic. This is the one exemption from the synthetic-fixtures rule. The first thresholds are 10% word error rate on iPhone recordings and 12% on Watch recordings, both estimates. Voice Memos recordings measure the speech engine, not Knot's own recorder, so the M2 and M3 checklists each have a row where the owner reads three passages through Knot and compares the result by eye. WP-13 still merges on its synthetic criterion, and if a threshold is missed the owner decides what happens.
- Every voice segment records the engine, the locale and the OS build that produced its transcript, as `transcription` on `Segment` in docs/architecture.md §4. v1 has no re-transcription; that is deferred to TODOS.md.
- The capture ledger is rule 6 of docs/architecture.md §6, backed by a `capture` table whose rows `NoteStore` carries. WP-02 defines the `Capture` type, WP-10 stores it, and WP-05 writes the row as the first durable write of every capture. The second PR of WP-22 adds the soak test: 500 captures on the Mac from a fixed seed, mixing typed text, fixture recordings of at most two seconds and fixture drawings, with the scripted transcriber, cleaner and recogniser and an injected clock, finishing inside 3 minutes. The harness is a child process over the real store, killed at points the seed chooses from a named list, then relaunched. It asserts three things: no capture row is still open, every segment that originated on the device has a row, and every stored segment holds at least the revision the engine reported as saved. It runs under `scripts/verify.sh --soak`, at each milestone and in the merge gate of any PR that touches KnotStore, KnotCapture or KnotAudio. WP-17 proves the watch half with the fake transport: every manifest is still on the watch or acknowledged.
- Crash recovery covers all three kinds. A typed draft found at relaunch becomes a finished segment, a drawing found at relaunch goes on to recognition, and a recovered capture ends at its last durable write. The launch sequence in WP-22 gains a step that finishes drafts and drawings, beside the one that recovers recordings.
- "Done when" lists are merge criteria and hold only checks an agent can run. Lines that need the owner, hardware or the real iCloud service are milestone evidence. They close at the milestone, not at merge. This applies to the checklist lines of WP-16, WP-17, WP-18, WP-19, WP-30, WP-31, WP-32, WP-33, WP-34 and WP-35, to the restore time on real CloudKit in WP-16, to the owner's sign-off in WP-40 and to the VoiceOver flows in WP-41. `docs/status.md` gains a milestone-evidence column. A milestone build is made from `main` in a fresh worktree by the thread of the owning package:

  | Milestone | Owning package | Also needs |
  |---|---|---|
  | M1 | WP-22, PR 1 | WP-05; PR 1 of WP-10, WP-12, WP-21, WP-30, WP-32 and WP-33 |
  | M2 | WP-30 | WP-11; WP-13; WP-14; WP-15; WP-19, PR 2; WP-31; WP-22, PR 2; SP-1; the design direction |
  | M3 | WP-32 | WP-17; WP-19, PR 3; SP-2 |
  | M4 | WP-33 | WP-16; WP-34; SP-3; SP-4 |
  | M5 | WP-35 | WP-18; WP-16 |
  | M6 | WP-40 | WP-41; WP-42 |
  | M7 | WP-43 | WP-44 |

- M1 changes on the Watch: the owner records and sees the capture listed on the Watch as saved. Delivery to the iPhone moves to M3. M1 adds no playback on the Watch.
- Start conditions replace the "after" notes in the package headers and the chain in §6. "PR 1" and "PR 2" are a package's first and second PR, and a package named without a number means its last PR. A spike counts as finished when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names:

  | Package | PR 1 starts after | PR 2 starts after |
  |---|---|---|
  | WP-02 | WP-01 | Its own PR 1 |
  | WP-05 | WP-02 | |
  | WP-10 | WP-05 | SP-3 and SP-4, for the second-process rules and the sync columns |
  | WP-11 | WP-05 | |
  | WP-12 | WP-05, with its proof step beside WP-05 | Its own PR 1 |
  | WP-13, WP-14, WP-18 | WP-05, with their proof steps beside WP-05 | |
  | WP-15 | WP-05 | SP-1, for the background mechanism |
  | WP-19 | WP-05, for the text intents | SP-1, for the recording intents on iPhone, iPad and Mac. Its third PR, the watch intents, starts after SP-2 |
  | WP-20 | WP-02 | |
  | WP-21 | WP-05 | The design direction |
  | WP-22 | WP-05 and WP-10, PR 1 | PR 1 of WP-10 and WP-15; WP-11, WP-12, WP-13 and WP-14 |
  | WP-30 | WP-21, PR 1 | The design direction and WP-22, PR 2 |
  | WP-33 | WP-21, PR 1 | The design direction, WP-22, PR 2, and SP-3, for the hotkey and the panel |
  | WP-32 | PR 1 of WP-12 and WP-21 | SP-2, WP-17 and WP-19, PR 3 |
  | WP-31 | SP-1 and WP-19, PR 2 | |
  | WP-16 | WP-10, PR 2 | |
  | WP-17 | SP-2 | |
  | WP-34 | SP-3, WP-10, PR 2, and WP-20 | |
  | WP-35 | WP-30 and WP-18 | |

  The longest chain to M2 is WP-00, WP-01, WP-02, WP-05, WP-10 PR 1, WP-22, WP-30. A second chain also gates M2: WP-01, SP-1 with the owner's confirmation, then the second PRs of WP-15 and WP-19, then WP-31. A third is the design direction, which the second PR of WP-30 waits for. No chain to M2 waits for SP-2, SP-3 or SP-4. A package the table does not list keeps the start condition in its header. WP-22 builds the live environment for iOS, iPadOS and macOS only, and WP-32 composes the watch app.
- Path ownership has three exceptions to "a package owns its folders". `scripts/release.sh` belongs to WP-43, though the rest of `scripts/` passes to the orchestrator after WP-01. WP-35 owns `Apps/iOS/Ink/`, the canvas screens shared by the iPad and a Pencil-capable iPhone. WP-05 owns `Sources/KnotFakes/Preview/`.
- The design direction comes first. Right after the plan is approved, the owner runs the brief's direction step in Claude Design, described in docs/design/brief.md §9, and chooses a direction for the iPhone capture surface and the Mac panel. The orchestrator records the choice in `docs/design/direction.md`. The first PRs of WP-21, WP-30, WP-32 and WP-33 are skeletons that do not depend on it. The second PRs of WP-21, WP-30 and WP-33 wait for it. WP-32 and WP-35 build provisional structure for the watch and the iPad, which the full design round may change. WP-40a to WP-40d each start after their platform's app package has merged and own that platform's views from then on. M6 repeats the core rows of the M2 to M5 checklists after the design is applied.
- WP-00's archive commit also holds the nine untracked files whose names end in " 2", because six of them differ from their originals. Only generated products are removed without archiving: `Knot 2.xcodeproj`, `Knot 3.xcodeproj` and `build/`. WP-00 keeps `TODOS.md` in the new tree.
- Build flavours protect the owner's notes. Every build that is not a milestone build uses development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. That covers agent builds, PR builds, spikes and tests, and tests also pass the store path in. Appendix A gains a hard rule: only a milestone build opens the default store or the real iCloud container. Notes on the owner's iPhone and iPad are disposable until the M2 milestone build, and notes on his Mac until the M4 milestone build, which needs SP-3's answer on where the Mac store lives. After those builds, every change to the schema or to the store's location ships a tested migration.
- The risk table in §11 gains three rows. Hotkey press and release do not arrive in a sandboxed build: the fallback is a listen-only event tap, which needs the Input Monitoring permission, and SP-3 decides in wave 1. A development build writes into the owner's notes: the development identifiers and the Appendix A rule prevent it. The release Xcode cannot compile code written against the beta SDK: the availability rule applies, and the merge gate builds with the release Xcode.
- At G1 the owner decides whether milestone builds reuse the bundle ID `com.p3ob7o.knot`, which is the retired app's. The recommendation is a new identifier, so that the retired app keeps working beside milestone builds and no special-case code is needed. Reusing the old one gives the new app the old app's container and preferences. In that case v1 keeps everything under a new subfolder and a new defaults suite, refuses to open a database it did not create, and the M1 checklist starts with a row, for every device that had the old app, to empty its pending captures first. The Mac app-group identifier stays open until SP-3 reports. At G1 the owner also installs a release Xcode 27 beside the beta, and WP-01 records its version: it is the Xcode for the merge gate and for the archive.
- The owner's work is listed with expected minutes, replacing the table in §10. The gate IDs stay. A checklist longer than 20 rows is split into two sittings. After WP-04 merges, `docs/checklists/` belongs to the orchestrator. The total is about 16 hours across the build, including the repeat sittings. The orchestrator derives dates for the sittings from the cadence the owner names at G0.

  | Gate | When | What | Minutes |
  |---|---|---|---|
  | G0 | Now | Answer this review's gate, confirm the open assumptions in docs/product-spec.md §16, say how many sittings a week he can give, approve the plan | 30 |
  | G0 | Wave 0 | Approve the restart PR and the licence wording | 15 |
  | G2 | Wave 0 | Review the brief, run the Claude Design direction step, choose a direction | 60 |
  | G1 | With WP-01 | Confirm the identifiers, both the milestone set and the development set, and the bundle ID; install a release Xcode; pair the five devices for development builds | 60 |
  | G1 | With WP-01, if authorised | Create the App Store Connect record and an API key for one internal TestFlight upload of the SP-3 spike app | 20 |
  | G3 | After wave 1 | One spike sitting: SP-1 has 12 rows, and the SP-2 spike app runs its 30 transfers itself | 45 |
  | G3 | After wave 1 | Read the four spike reports and confirm their decisions | 20 |
  | G3 | With SP-4 | Sign two devices into iCloud for the sync spike | 10 |
  | G4 | Wave 0 | Record the read-aloud script and 10 spontaneous notes on two devices and move the files to the Mac | 30 |
  | G4 | Before the full design round | Read the guard's table and the ten cleanup pairs; choose full cleanup, punctuation only or off | 20 |
  | G2 | After the direction | Run the full Claude Design round and return the handoff | 90 |
  | G4 | M1 | Checklist | 15 |
  | G4 | M2 | Checklist in two sittings, with locked and unlocked rows for each trigger | 40 |
  | G4 | M3 | Checklist | 30 |
  | G4 | M4 | Checklist in two sittings: hotkey, CLI and MCP, two-device sync | 45 |
  | G4 | M5 | Checklist | 20 |
  | G4 | M6 | Checklist with the regression rows, and sign-off of the applied design | 90 |
  | G4 | M1 to M7 | Repeat sittings after fixes: three each for M2, M3 and M4, one each for the others | 15 each |
  | G4 | M1 to M7 | Free-form notes at the end of each milestone sitting, which the orchestrator turns into change requests | 10 each |
  | G5 | After M5 | Approve the CloudKit production schema, before the first TestFlight build that syncs | 5 |
  | G5 | M7 | Authorise the TestFlight upload, supply the API key if not already supplied, install over the development build on each device | 30 |

- The CloudKit production schema is deployed only after M5, when two-device sync and attachment sync have passed on hardware with development builds. This replaces any earlier timing. The M7 checklist has rows for installing the TestFlight build over a development build.
- The spikes answer more questions. SP-1: does cleanup with the on-device model finish in the background after a recording stops. SP-2: does Double Tap start a recording when Knot is not the app in front, and can a watch intent start one at all. SP-3: do hotkey press and release arrive in a sandboxed build, does the panel show over a full-screen app, with the listen-only event tap as the fallback, and are first words clipped when the microphone opens at the 250 ms mark; can the sandboxed tool write to a folder the user names, and if not, how does `knot export` deliver its output. SP-4: do the ownership, machine-text and deleted-note rules of docs/architecture.md §11 hold when two devices see the same segment, what happens when a device moves from CloudKit's development environment to production, what CKSyncEngine reports when the zone is removed from iCloud, and whether an existing sync layer over GRDB and CKSyncEngine, such as SQLiteData, meets those rules and at what dependency cost. Adding a dependency stays the owner's decision under D30. SP-3 runs on a sandboxed build signed for development. If the owner authorises it at the final gate, one internal TestFlight upload of the SP-3 spike app in wave 1 checks distribution signing early. Without that, the check waits for M7, the command-line result at M4 is provisional, and WP-34 builds the XPC fallback only if the M7 check fails.
- WP-01 states the availability rule: the deployment target is 27.0, an API that first shipped in 27.1 or later is guarded or raises the stated minimum, and code must compile with the release Xcode installed at G1. WP-01 also declares the targets KnotFakes, KnotTestSupport, KnotUIPreviews and `knot-eval`, creates the environment factory in KnotApp returning `.unavailable`, defines the development identifiers, gives `scripts/build-slot.sh` an exclusive slot for Mac UI tests, and adds `scripts/verify.sh --gate` and `--soak`. Its criterion about two worktrees changes: both run `--full` at once, with Mac UI tests queued on the one slot.
- The merge gate is `scripts/verify.sh --gate` on the orchestrator's Mac. It requires the on-device models and fails on a skipped model test, but it checks no accuracy threshold: thresholds belong to the package PRs that own them and to the milestones. The design of the merge queue for about 50 PRs is decided by the Eng review.
- docs/architecture.md §14 lists the intents per platform. iPhone and iPad have ToggleRecording, which starts a recording when idle and stops the one running, so the control that starts a recording also stops it. The Mac's StartRecording opens the panel recording, with a stop control. The Watch's StartRecording opens the watch app recording and calls the watch recorder, and the watch part of WP-19 waits for SP-2. Intents reach the environment through the App Intents dependency manager, which the app registers at launch, and the widget extension links KnotIntents for the types only. The note entity is not indexed, no intent that reads or picks a note runs on a locked device, and intents are tested against `.preview`.
- WP-33 lets a note be dragged out of the Mac main window, as docs/product-spec.md §8 describes: text into another app, a Markdown file into Finder, recordings and drawings left behind. It uses KnotExport for the Markdown. A UI test drags a note onto a text field, and the M4 checklist has a row for it.
- docs/design/brief.md §6 holds the states the spec requires and the brief lacked: recently deleted, sync status and the account-change prompt, attachments waiting or downloading, a failed segment with its retry, a recording being transcribed on another device, export of all notes, cleanup unavailable, no microphone connected on the Mac, a recording on the Mac started from Siri or Shortcuts, text that could not be saved, a recording that could not start, a watch capture not yet delivered, a recording that stopped at its limit, notes that could not be opened, export progress and its result, a hotkey that another app already uses, the command-line access switch, and the moment a held key waits for the microphone. The brief also asks where a lasting problem shows outside Settings, and sets touch targets at 44 points or more.
- On iOS and iPadOS the database lives in the app's own container, and only `Inbox/` and the recording state use the app group, as docs/architecture.md §7 states. WP-10 implements both locations.
- docs/architecture.md §11 fixes the sync default, who processes a recording, when a segment syncs, the precedence of machine text, titles, deletes, appends to a deleted note, and which settings sync. WP-16 implements those rules, and its two-replica simulation covers each one, including several segments added to a note that the other replica had deleted, which must land together in one new note.
- docs/product-spec.md §3 holds rules 9 to 15, §4.4 says what happens when a capture cannot start or cannot be saved, and §6 fixes the hotkey behaviour in a timeline table: the microphone opens at the 250 ms mark of a hold and never on a tap, and listening from key-down is the alternative if SP-3 measures clipped first words. A release that never arrives leaves a visible stop control, and a key another app already uses is refused in Settings. Hold-to-record is exempt from the one-second discard. WP-02 and WP-33 encode these rules. §16 marks each assumption as cheap or costly to change after WP-02, and gives a worked example for each costly one.
- The CLI and MCP contract is decided by the DX review before WP-34 starts: ID forms, `--since`, how a pending note is marked, exit codes, the MCP revision, export of recordings still on another device, how an agent learns that the store is stale because the Mac app is not running or sync is off, a settled state that tells an agent a note is finished, and a change cursor that counts store changes so that a late watch recording is not skipped. Three points are already fixed: the tool and the MCP server stay off until the owner turns on command-line access in Settings; their deletes are soft and nothing purges; and tool results mark note text as data, not as instructions.
- docs/product-spec.md §17 states the Watch gap as proven delivery and accuracy, not an absence of competitors.
- `TODOS.md` at the repo root holds the eight items this review deferred.
- Device installs. WP-01 adds `scripts/install.sh`, which installs a named build on every paired device with `devicectl` and names any device it could not reach. SP-1 and SP-2 each record the install procedure that worked on the iPhone and on the Watch, and the orchestrator corrects the script from those reports. A spike or milestone sitting starts when the script has reported success.
- WP-14's first PR states the fidelity guard's allowed differences as a table: letter case, punctuation, paragraph and list breaks, the removal of fillers, repeated words and abandoned starts, and the written form of a number. Any other difference is a changed word, and the guard rejects the result. The owner reads that table with the ten cleanup pairs.
- Failure behaviour is fixed in docs/architecture.md and each rule has an owner. WP-10: a store that cannot be opened is never deleted, a database newer than the build is refused untouched, and the newest pre-migration copy is kept until the following migration. WP-11 and WP-22: when the store is unavailable, captures go to `Inbox/` and the stream says what is wrong. WP-15: an unreadable inbox item becomes a failed segment that keeps its file, manifests carry a version, jobs have four named states and fail after five attempts, an interrupted transcription continues from its last saved range, and a recording with no recognised words is ready with empty text. WP-17: a file whose checksum does not match is not acknowledged, and on the third mismatch it is ingested as failed and kept. WP-16: when the zone is removed from iCloud the local notes stay, sync pauses and Knot asks before uploading; a record kind or field the build does not know is kept and saved back untouched. WP-12: a failed conversion keeps the working file as the recording, a stale recording state never starts a second recording, a small array of level peaks is stored beside each recording, and the proof step reports the working file's size per minute on each platform. WP-14: cleanup waits when the model is not ready, and treats a refusal, an empty or malformed result and a guard rejection alike. WP-22: the capture surface is on screen before the launch steps run, and a failed step never blocks the next.
- WP-02's error taxonomy names each of those failures by case, as docs/architecture.md §5 lists them, and no port throws an untyped error.
- These failure tests are required by name, as docs/architecture.md §17 lists them: two processes recording captures at once and a store that will not open (WP-10); a late draft save that must not replace newer text (WP-11); an edit during a paused clean job, a delete during a job, an interrupted transcription and an unreadable inbox item (WP-15); a checksum mismatch (WP-17); a zone removed from iCloud and a record of an unknown kind (WP-16); a hotkey release that never arrives (WP-33); search text full of query syntax and a database newer than the build (WP-10); a clock moved backwards (WP-02); a press while the saved recording state is stale (WP-12).
- Performance rules for WP-10: a stream page is one query, every query in the `NoteStore` contract has an index, and a test shows each query plan.
- Security rules. The `knot` tool and the MCP server refuse to run until command-line access is turned on in Settings, and WP-33 and WP-34 build that switch. Knot's URL scheme only navigates and never writes text or starts a recording. Search text never reaches the full-text index as raw query syntax. A generated title is one line of plain text of at most 60 characters. WP-43's privacy text says exactly what iCloud encrypts end to end.
- Diagnostics. Test builds export a diagnostics file from About: capture rows, job rows, counts, signpost timings, the build and the OS, with no note text, titles or content-derived names. WP-22 builds the exporter and WP-30 and WP-33 the entry in About. Every log line about a capture carries the capture ID. The M2 and M4 checklists record the latencies it reports.
- WP-43 adds a troubleshooting guide with one entry for each failure this review lists, and the steps to roll a build back. The M7 checklist has five smoke rows: type, record, search, sync, and the install over a development build.
- The M4 checklist begins with one row: a note captured on the iPhone is read and filed by an agent on the Mac through `knot` or the MCP server.
- docs/product-spec.md §14 gains a Watch target, 60 seconds from the stop of a 30-second recording to its transcript on the iPhone with the phone nearby. It is an estimate that SP-2 calibrates, and the M3 checklist measures it.
- WP-04's cleanup evaluation set includes at least ten meaning-critical cases: negations, amounts, dates, names and spoken self-corrections. The evaluation reports them separately. One changed meaning among them sends the cleanup default to the owner's decision.
- Backups. The store and its files are never excluded from device backups or Time Machine, and WP-10 tests that a store folder copied elsewhere opens with every note and file. Importing an export is deferred to TODOS.md.
- WP-00's README says what happened to the Obsidian capture app and where its code and its tags live.
- WP-40 writes `DESIGN.md` at the repo root from the handoff, as the reference for the design reviews that follow.
- Appendix A gains two rules. A PR that changes the cleanup instructions, the guard or the speech settings reruns the cleanup evaluation and `knot-eval` and states the results before and after. Every log line about a capture carries its capture ID.
- After approval, this review's record moves to `docs/reviews/2026-11-19-plan-review.md`, and PLAN.md holds the plan only.
<!-- /autoplan-accepted:ceo -->

<!-- autoplan-accepted:design -->
- These items come from the design review. They add to the items above, and where one of them contradicts an earlier item, the later one wins.
- The editing model is fixed in docs/product-spec.md §7, as assumption A27. A note is a stack of segments, each edited on its own. A selection does not cross from one segment into the next, and undo covers the segment being edited. New text enters through the capture field, which is the last element of every open note. With the append window open, the capture surface is that note with its field focused, so WP-21 builds one view model for the note and for capture. The design may propose another model in the direction step, and the owner must accept it before code depends on it.
- WP-02 adds three things to its contracts: a local `arrivedAt` on `Segment` that does not sync; the rule that a title is generated only when a note's first segment is a recording; and an ink state machine with no transition from ready back to drawing, because a finished drawing is not reopened in v1 (assumption A28). Its reducer tests reject that transition.
- Rule 4 of docs/product-spec.md §3 now says where "New note" is: the iPhone and iPad capture surface, the Mac panel and an open note. A capture started from the Action Button, a control, the Watch or a held key follows the window. The Live Activity, the Watch and the Mac panel during a hold show whether a recording continues a note or starts a new one, without any text from the note. WP-31, WP-32 and WP-33 build that indicator.
- docs/product-spec.md §4.1 fixes what the capture surface shows: the note a capture would join, following the window, with the destination fixed at the first keystroke. WP-11 and WP-21 implement it, and a view-model test covers the window running out while the field is empty.
- docs/product-spec.md §4.5 lists the cue for each of six events on each device. WP-12, WP-30, WP-32 and WP-33 implement them, and the M2, M3 and M4 checklists have one row per event and device. Until the "live" cue, nothing implies that Knot is recording.
- docs/product-spec.md §5 names six states of a voice segment by what the user can do: saved on the Watch; saved, text on its way; saved, text being made elsewhere; ready; needs you; kept, no text. WP-21 maps every internal state to one of the six, with a view-model test for each. Retry on another device is labelled as moving the work to this device.
- The stream row follows docs/product-spec.md §7: its preview is the latest segment's text; a note with no text says what it holds; at large text sizes the preview gives way first, then the kinds; the title or first line, the time and a failed marker always stay. A late capture is marked as arrived until its note is opened, and the stream says once that captures arrived. WP-21, WP-30 and WP-33 build this, with a UI test that injects a late capture through `.preview`.
- The state matrix. docs/design/brief.md §6 ends with a matrix of 47 states by six surfaces. WP-21 adds one named preview in KnotUIPreviews for every cell marked as designed, and a test fails when a cell has none. WP-40's side-by-side screenshots are rendered from those previews. Each UI package's build list names the cells it implements.
- The direction. `docs/design/direction.md` holds the answers to the brief's questions 1, 2 and 4, a structure sheet for the capture surface of each of the four devices, a link to the chosen prototype, and what stays open. The direction step scores each direction on three tasks counted in actions: capture a new thought, continue the last note, find an old one. The second PRs of WP-21, WP-30, WP-32 and WP-33, and all of WP-35, build from the sheets. This replaces the provisional structure for the watch and the iPad, so the second PR of WP-32 and the whole of WP-35 also wait for the design direction.
- The brief asks for both branches of the three surfaces a spike still decides: a recording from a locked iPhone or only after Face ID; a Watch start with or without the app in front; and the Mac's first run with or without a permission prompt for the hotkey. The full design round therefore does not wait for the spikes. SP-1's report includes the feedback flow for each entry state, including Live Activities turned off and a missing microphone permission.
- Accepting the handoff. Before WP-40 starts, the orchestrator checks the handoff against the matrix: every cell is designed or inherits from a named cell, and each capture surface is shown at the largest text size, with Reduce Motion and with the keyboard up. Gaps go back to the designer as a list, not as a second round.
- Where the design changes structure, the orchestrator lists each difference in `docs/design/deltas.md` and assigns it, and WP-40's ownership extends to the view models those differences touch. Where the handoff is silent, the implementer uses the system default and adds a line to the same file, which the owner clears at M6.
- Where a mock and a system component differ, the system component wins and the deviation is recorded. Type maps to Dynamic Type text styles, colour to roles and materials to system materials. Controls, complications, widgets and the Live Activity take glyphs, strings and content from the handoff and rendering from the system. WP-40 writes these rules into `DESIGN.md`.
- WP-19 adds an OpenSearch intent, and WP-31 a Search control and widget target, which open the stream with search focused. A widget, control or complication may show state without text: a recording with its timer, how many captures are waiting, how many failed.
- WP-33 follows docs/product-spec.md §6 for the panel. A tap gives it the keyboard. A hold shows it without taking the keyboard, and it hides by itself shortly after the text has arrived unless it is clicked or typed in. It opens on the display that has the keyboard focus. A click on the menu bar icon opens the menu. The panel and the main window have a microphone control that starts and stops a recording (assumption A30). The state machine tests cover a tap taking the keyboard and a hold not taking it.
- WP-35 makes the Pencil always draw on the capture surface, after checking in the 27 SDK how the system's handwriting input is turned off there. A drawing does not end on one stray key press or touch. When two columns do not fit, the iPad uses the iPhone layout, and at launch its open column is the capture surface. UI tests cover a narrow width and a key press during a drawing.
- Accessibility is behaviour, as docs/product-spec.md §13 states it: VoiceOver announces the start and stop of a recording and stays silent while it runs; new text never moves focus; focus returns when a surface closes; every segment action is reachable from the keyboard on the Mac and the iPad. WP-21 builds this into its components, WP-04 adds one VoiceOver row per capture path to the M2 to M5 checklists, and WP-41 confirms it.
- The first-run stream says that sync is on and where its switch is. It may also carry up to three dismissible rows on setting up the Action Button, a Lock Screen control and the Watch complication (assumption A29). If Live Activities are off, Settings says that recording from the Lock Screen will open Knot.
- A segment written through the command line or MCP carries a quiet mark, and a segment made by a newer Knot says so and asks for an update. WP-21 builds both.
- The owner calendar gains about 35 minutes: 15 at G2 to read the handoff's gap list, and 5 at each of M2 to M5 for the VoiceOver rows.
- No mockups were made with gstack's designer in this review. By D13 the visual design comes from Claude Design.
- Assumptions A27 to A30 join docs/product-spec.md §16, and the owner confirms them with the others at G0. `TODOS.md` gains two deferred items, ten in all: reopening a finished drawing, and stopping a recording that hears no speech.
<!-- /autoplan-accepted:design -->

<!-- autoplan-accepted:dx -->
- These items come from the developer-experience review. They add to the items above, and where one of them contradicts an earlier item, the later one wins.
- The command-line and MCP contract is fixed in docs/product-spec.md §10, and replaces the open list of the earlier item. Text is a required argument, `-` reads standard input, a command given no text writes nothing, and no command prompts. Every command takes `--json`. An argument is a full ID or a unique suffix of eight or more characters. A write returns the note, the segment, whether it joined an existing note, the segment's revision and the store's cursor. `add` and `append` take `--capture-id` and are idempotent on it. `edit` and `title` take `--if-revision`, and `title --clear` removes a title. `knot changes --after <cursor>` is the polling command. Each note says whether it is settled, each segment carries its state, the origin of its text and its revision, and every result says how current the store is. Export never downloads: it refuses when attachments are on another device, and `--skip-missing` exports the rest with a list. Exit codes run from 0 to 8 as listed there.
- Four parts of that contract reach the store, so WP-02 and WP-10 carry them from schema version 1: a store ID and a change counter, with a `revision` on each note; a `revision` on each segment; capture recording that is idempotent by capture ID; and a local `segment_history` table that keeps replaced text for 30 days. WP-02's contract suites cover each: a repeated capture ID changes nothing and returns the first result; a stale revision fails; changes after a cursor include a late capture and a deletion; and a cursor ahead of the store is reported.
- Errors use one mechanism, as docs/architecture.md §19 states. In WP-02 every case of the error taxonomy carries a stable code, the next action, whether a retry is safe and how often, and what was written, and a test fails when a case lacks a code or an entry in docs/errors.md. WP-34 renders the command line's text, `--json` and the MCP results from that one value, and has a golden test for every error, run with no terminal and with standard input closed. WP-01 adds `scripts/lib/fail.sh`, and every script reports failure through it.
- WP-34 is size L and ships in three PRs: first `status`, `add`, `list`, the error contract and the access switch; then the other commands; then the MCP server. Its commands are written against the `NoteStore` port, so its first PR starts after WP-05 on the fake store. Its second PR starts after the second PR of WP-10 and after WP-20. Embedding the tool in the Mac app waits for SP-3. One command table generates the help, the usage errors, the MCP tool list, docs/cli.md and the golden tests. A development build installs the tool as `knot-dev`.
- The MCP server speaks the 2026-07-28 revision, and the handshake of the 2025-11-25 and 2025-06-18 revisions. WP-34 reads the specification before writing it. Conformance tests cover both kinds of client, an unknown method, an unsupported version, standard output that holds protocol messages only, and exit at end of input. Tool names carry a noun, the capture tool requires a placement of "window" or "new note", results are bounded and carry a next cursor, and no tool exports. `knot mcp` reads the access switch and the schema version again on every call. While access is off it keeps answering and fails each call with the reason. Tests cover access switched off, and a store migrated while a server is connected. The M4 checklist names the client and the version it was proven with.
- Getting started. The Settings row for command-line access shows the two lines to paste, each with the tool's absolute path: one puts `knot` on the PATH, and one registers the MCP server. `knot` with no arguments prints the four everyday commands, and `knot help <code>` prints an error's entry. The target is 2 minutes from the switch to a note read by an agent, and the M4 checklist times it.
- docs/cli.md holds a three-command quick start, every command with an example and its `--json` output generated from the golden files, the exit-code and error tables with anchors, and a registration line for each client. A test runs every example in it. The README links to setup, the command reference, contributing and recovery. A changelog is kept from M4, with a section for the command line.
- Xcode selection. WP-01 commits `.xcode-version`, and every script sets `DEVELOPER_DIR` from it and checks the version. Implementers use that Xcode, and the beta only by name. `scripts/sdk-path.sh` replaces the fixed path of docs/architecture.md §21. WP-01 checks every row marked "SDK" in §20 against that Xcode's SDK. Package criteria name `scripts/verify.sh --quick`, never a bare `swift test`. WP-01 joins the prior-art list: the retired `scripts/verify.sh` already set `DEVELOPER_DIR`.
- `scripts/verify.sh` follows docs/architecture.md §18: one tier per run; `--only`, `--module` and `--seed`; the soak added by `--gate` from the diff; one summary line; and a failed step that names its log and its rerun command. `scripts/doctor.sh` runs first. `--skip mac-ui` exists for implementers, and the gate refuses it. WP-14's evaluation command becomes `knot-eval --set synthetic`.
- At G1 the owner enables Automation Mode and developer mode once, with the two commands `scripts/doctor.sh` prints. Without that, Mac UI tests wait on a password dialog that no agent can answer. It adds five minutes to that row of his calendar.
- Tests and agent builds use a local build configuration that keeps the sandbox and leaves out the entitlements that need the owner's signing profile, with sync off. WP-01 adds it, with an optional `Local.xcconfig` for a contributor's own team.
- Each worktree's development builds keep their store and their recording state in a folder of that worktree. Removing a worktree removes that folder with its simulators.
- The owner's recordings live in one folder outside every worktree, named by `KNOT_LOCAL_FIXTURES`, which replaces `Fixtures/local/`. WP-04 says whether the synthetic audio is committed or generated, where tests find it, and the error a test gives when it is absent. A contributor's PR reruns the synthetic evaluation. The orchestrator runs the local one at the gate for a PR that touches speech or cleanup, and records the numbers.
- WP-01 has a time target: a fresh worktree reaches a first green module test in 5 minutes, and `--quick` takes 3 minutes when warm. The script prints both. docs/dev-setup.md lists each prerequisite with its version and the command that installs it.
- `scripts/build-slot.sh`, `scripts/install.sh`, `scripts/release.sh` and `knot-eval` follow docs/architecture.md §18. A slot is a lock that frees itself when its holder dies. The install script exits non-zero when it missed a device. The release script takes the key as a file path only, prints variable names only in a dry run, and after a failed upload says to check App Store Connect before retrying. When the soak fails it prints its seed, its kill point and where the store was kept, and a soak failure is never retried to green.
- Package briefs. The rewrite after approval produces one file per package in `docs/plan/`, with fixed headings: goal, owns, starts after, build, merge criteria, milestone evidence, prior art, failure rules and named tests. Paths in them are relative to the repository root and include each package's tests. `scripts/check-plan.sh` fails while PLAN.md still holds an amendment list or a brief lacks a heading, and WP-00 merges only when it passes. Appendix B names the package's one file.
- Appendix B changes in two ways. The thread runs `scripts/bootstrap.sh` and `scripts/verify.sh --quick` before it changes anything, and stops if that baseline is red. Its last line is `RESULT ok` with the PR, the head and the verify summary, or `RESULT blocked` with one code, the pushed branch, what it needs and how to resume. The codes are `baseline_red`, `brief_wrong`, `needs_contract_change`, `needs_shared_file`, `needs_owner`, `needs_hardware` and `tool_failure`.
- Rolling back never discards work. Restoring a pre-migration copy stops the app and the tool, moves the current store folder aside whole and keeps it, and WP-43's guide says how to export what was captured since. WP-10 tests that the newer store is still there after a restore.
- Shortcuts get StartRecording and StopRecording on every platform, each safe to repeat. ToggleRecording stays for the Action Button and the controls. WP-19 builds them, with a test that repeating either changes nothing.
- WP-44 runs gstack `/devex-review` at M4, against the 2-minute target.
- Assumptions A31 to A34 join docs/product-spec.md §16, and the owner confirms them with the others at G0.
<!-- /autoplan-accepted:dx -->

<!-- autoplan-accepted:eng -->
- These items come from the engineering review. They add to the items above, and where one of them contradicts an earlier item, the later one wins.
- Counts. The plan now has 31 work packages and about 54 PRs before contract and fix PRs. WP-06, the soak harness, is new. WP-01 and WP-02 become size L: WP-01 ships in two PRs and WP-02 in three.
- WP-01's first PR is the scaffold that unblocks WP-02 and the spikes: the targets, both build flavours, the local configuration, `scripts/bootstrap.sh`, `scripts/doctor.sh` and `scripts/verify.sh --quick`. It also proves the packaging that otherwise fails late, with one trivial instance of each and a check in `verify.sh`: an App Intent declared in the package and present in both the app and the widget extension, a Live Activity attributes type, the watch app embedded in the iPhone app, the `knot` tool embedded and signed in the Mac app, a contract suite in KnotTestSupport run from two test targets, and a Release binary free of KnotFakes. Its second PR is the tooling and runs beside WP-02: `--full`, `--gate`, `--perf`, the slots, the install script, the ownership check, `scripts/status.sh`, `scripts/worktree-remove.sh` and the scripts' self-test. Until that second PR merges, the gate is `--quick`, listed as an exception in `scripts/gate-steps.txt`.
- WP-01 also follows the other additions to docs/architecture.md §18: a floor of free disk space in `scripts/doctor.sh`, slots on `/usr/bin/lockf` with one kept for the gate, the index store off for agent builds, and a small fixed set of simulators for each worktree.
- WP-01 writes the environment factory so that a debug build asks KnotFakes for the preview environment, which answers `.unavailable` until WP-05 fills it in. WP-05 therefore edits only its own folders. This replaces the earlier wording in which WP-05 changed the factory.
- WP-01 has a stated exception to Appendix B. It starts from a tree with no scripts, so its baseline is that the tree matches WP-00's file list.
- WP-02 ships in three PRs: the domain types, rules and reducers; then the ports, fakes and suites the tracer needs, which are the stores, the recorder, the transcriber, the cleaner, the clock and the IDs; then the remaining ports, fakes and suites, which may run beside WP-05. WP-05 starts after the second.
- Proof before contracts. The proof steps of WP-12, WP-13, WP-14 and WP-18, and the code half of each spike, start beside WP-02's first PR. They need only WP-01's first PR and WP-04. Each files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. WP-02's second PR waits for the notes of WP-12, WP-13 and WP-14, and its third for WP-18's and for those of SP-1, SP-2 and SP-4. This replaces the earlier timing beside WP-05.
- WP-06, the soak harness, is size S and starts after WP-05 and the first PR of WP-10. It owns `Tests/KnotSoak/` and the soak step of `scripts/verify.sh`. It covers typed captures first. WP-11, WP-12 and WP-15 each add one file of kill points there in their own PRs, as a stated exception to path ownership, and the soak is among their merge criteria. The harness follows docs/architecture.md §17: the parent process is the witness, and one shared consistency check ends the run. The second PR of WP-22 keeps the end-to-end suite and no longer builds the soak.
- One home for each rule, all in KnotCore and built by WP-02: `CaptureManifest`, the one versioned format for a recording in progress, an inbox item and a watch outbox file; `StoreLocations`, the only code that computes a store path, with no default in any library target; `DurableFile`, the only code that places a file; the mapping from internal states to the six that a person sees; and the settled rule. KnotUI and KnotAgent both use the last two, and the command line reports the six names.
- The append rule has one owner. The store's record-a-capture transaction decides, the engine passes only the placement the user asked for, and the note a capture surface shows comes from a store query that calls the same rule. WP-02 writes a test that the prediction and the decision agree, and WP-11's session tracker holds intent only.
- Checkpoints and repeats. Saving a checkpoint of an open capture is its own store operation, ordered by revision, and it never lowers stored text. A repeated capture ID with the same content returns the first result, and with different content it fails as a conflict. Replacing text checks the precedence of edited, cleaned and raw inside the store. WP-02 and WP-10 carry all three with contract tests.
- The engine never waits for the store. A capture that begins while the store is not open, is migrating or has not answered within 100 ms goes to `Inbox/` in the manifest format and is ingested later. A recording writes its manifest first. A capture belongs to the process launch that began it, and recovery finishes only the captures of earlier launches. WP-05, WP-11 and WP-22 each have a named test: before open, during a migration, during a held write lock.
- Launch steps depend on one another as docs/architecture.md §13 states: the steps that need the store are skipped when it did not open, jobs and sync wait for recovery and ingest, and a step in which the last two launches died is skipped and reported. WP-22 builds this. It replaces the earlier rule that a failed step never blocks the next.
- Jobs count attempts, deferrals and deaths apart, as docs/architecture.md §4 states. The error taxonomy gains the deferral class and three cases: text too long, a capture stopped because the disk filled, and a cursor from another store generation. WP-02 and WP-15 carry it.
- Durability has three cases, stated as rule 7 of docs/architecture.md §6. WP-10 turns `fullfsync` on, reports what a commit costs on the iPhone and the Mac, and tests that the writer connection keeps both settings. WP-12 syncs the file being recorded every second and reports the cost. `DurableFile` syncs the file and its folder before the row that points to it is committed, and a file-layer test drops unsynced writes. The owner forces a restart during a recording once at M2 and once at M3.
- Sizes are bounded as docs/architecture.md §4 states, and WP-02 fixes the numbers after SP-4 confirms CloudKit's record limit. Longer text continues in a new segment. A path on disk comes from an ID. WP-34 bounds an MCP frame and piped text, and WP-15 bounds a manifest.
- Device identity. WP-10 keeps an install ID in the Keychain for this device only, and a store that arrives through a backup gets a new device ID and a reset sync state. Automatic takeover of a recording whose owner is gone is deferred to TODOS.md. The action to move the work stays.
- WP-10 gains these rules from docs/architecture.md §7: only the app migrates, and the tool exits with code 7 on an older store; the copy before a migration is made with `VACUUM INTO` or the backup interface, checked, and required; a restored store gets a new generation; a daily copy is kept seven times; `change_log` holds one row per record and none for drafts, and its triggers are off while sync applies; bulk writers commit in small batches; reads use the reader connections; a purge leaves a tombstone. At each milestone tag a seeded synthetic store made by that build is committed, and every later build must open each one.
- WP-30 builds two actions into About for test builds, by M2: export the store as it is, and restore a kept copy.
- Sync follows the additions to docs/architecture.md §11. WP-16 splits into a merge core with no CloudKit in it and a thin adapter, and KnotStore gives it one transactional interface, so KnotSync issues no SQL. Ownership of a recording carries a generation. A conflict copy holds text only and has a derived ID. A late segment never lands in a deleted note. An asset is local only, uploading or published. The engine's state is kept per account and environment. The simulation runs with two and with three replicas and checks the five invariants listed there.
- SP-4 also answers: how a replica that stayed away for more than 30 days is handled, a segment that arrives before its note, a kill between applying a batch and saving the engine's state, a store restored from an older copy, a record at the size limit, a change of account with uploads pending, and what a restored or replaced phone does to device identity.
- The watch link acknowledges only a file that matches its checksum, as docs/architecture.md §12 states. After a third mismatch the phone keeps the damaged copy as a failed capture and the watch keeps its own. WP-17 also sends again on each of the triggers listed there and cancels a transfer that shows no progress. SP-2 measures how much background time the phone grants when it is locked and Knot is not running, and whether transcription finishes in it. The M3 row for the 60-second target states that condition.
- A stale recording state is judged by a heartbeat, as docs/architecture.md §8 states: a press that meets a stale state recovers the orphan and starts a new recording. This replaces the earlier rule that such a press starts nothing. The one-second discard is measured between the two presses. WP-02 encodes both in its reducers and WP-12 writes the heartbeat.
- No automated test and no agent opens a hardware microphone on the build Mac. The recorder takes injected audio and refuses the hardware input under test. Start latency on a real microphone is measured at the owner's sittings. Appendix A gains this as a hard rule.
- The fidelity guard is stricter, as docs/architecture.md §9 states: three kinds of removal, nothing inserted but punctuation and list markers, numbers untouched, and a mutation suite as a merge criterion of WP-14's first PR. A generated title uses only words from the note. Assumption A35 records that v1 leaves spoken self-corrections as they were said.
- Speech in the Simulator. The gate requires both models on the Mac and uses the scripted transcriber in the iOS Simulator, where the real one is not available. WP-13's proof step repeats that probe inside an app. The M2 checklist gains three rows for speech on the iPhone: the first transcription after the model downloads, a long recording that finishes across background runs, and live text. WP-22's criterion changes: the suite passes on the Mac with the models and in the Simulator with scripted speech.
- Tests added by name are listed in docs/architecture.md §17, each with its owner in `docs/plan/named-tests.txt`, which WP-00 creates from this review. The gate fails when a listed test is missing once its package has merged.
- Package tests use Swift Testing and UI tests use XCTest, as docs/architecture.md §17 states. Each real implementation runs its contract suite where it can run, as the table in §5 says.
- More tests: a UI smoke test on `.live` on each platform (WP-22 PR 1, WP-30, WP-33); the allowed list of unavailable ports per milestone (WP-22); the log canary (WP-22 PR 2); search checked against a plain scan (WP-10); the system's accessibility audit in every UI smoke test from WP-21's first PR, made clean on every designed cell by WP-41; and export names from hostile titles (WP-20). The preview test reads the state matrix from the brief's own table, so there is no second list.
- Time thresholds leave the merge criteria of WP-10 and WP-30. The gate asserts query plans and operation counts, and `scripts/verify.sh --perf` measures times at milestones and in WP-42, following the protocol in docs/product-spec.md §14. That section gains four targets, all estimates.
- The merge gate, the merge queue and the orchestrator's state follow docs/architecture.md §18. The gate picks its depth from the diff by a fixed table and refuses a partial run. The orchestrator runs a serial queue and binds each result to a base, a head and a tree. Its state is rebuilt from the briefs, GitHub and a journal outside the worktrees, and a fresh thread takes over at M1 as a drill. `docs/status.md` is written to `main` only at milestones. This settles the open point of the earlier item on the merge gate.
- Milestones. M1 also needs WP-06. M7 also needs M6, WP-40, WP-41 and WP-42, and the release script refuses a candidate that lacks any milestone's evidence. The XPC route is built only if SP-3 fails in wave 1.
- The early upload. Both reviewers ask to make the one internal TestFlight upload of the SP-3 spike app a required part of G1. It stays the owner's to authorise. If he declines and distribution signing then fails at M7, the recommendation is that v1 ships without the command line, and that no XPC route is built at the last gate. This replaces the earlier item that built the fallback after a failed M7 check.
- SP-3 also tests the two packaging rules and the key-state check named in docs/architecture.md §15. SP-1 also tests a press after a restart and before the first unlock, a double press on a cold start, a press after a force quit during a recording, and in which process each intent runs.
- WP-00 changes in four ways. It writes the first `scripts/check-plan.sh` and `docs/plan/named-tests.txt` itself, so its own merge criterion can run. It lists what else exists before it deletes: the second worktree `knot-rewrite-sol` with its four untracked items, which join the archive commit; the local branch `codex/rewrite-sol`; the remote branches `codex/gutenberg-editor` and `triage/v0.1-week1`; and open pull request 8, which the owner closes or keeps. It removes ignored leftovers with a reviewed `git clean -X` list. It checks that the `v0.2.0` tag points where it did before.
- Folding the amendments. `docs/plan/amendments.md` has one row for every item of the four amendment lists, by list and position, naming the brief that absorbed it or the reason it was dropped. `scripts/check-plan.sh` fails unless every item appears once, and a second thread compares the two before WP-00 merges.
- The repository's rules at G1. The owner extends the ruleset on `main` to require a pull request, squash merges, the status `knot/gate` and an up-to-date branch, and limits interactions to collaborators for the length of the build. He also decides which Mac holds real notes while the build runs, and the recommendation is that the build Mac holds none.
- Appendix A gains these hard rules: agents use `knot-dev` and never `knot`, and their threads export `KNOT_AGENT=1`; agents act only on the project's own `wp/`, `spike/` and `contract/` branches and never read issue or pull-request comments from GitHub; a pull request from outside is read before it is built; the repository gets no self-hosted runner, and its workflows hold no secrets and pin their actions.
- The signing team's ID stays out of the repository, as docs/architecture.md §18 states. `KNOT_LOCAL_CONFIG` names the local file, beside `KNOT_LOCAL_FIXTURES`.
- GRDB's revision is pinned as well as its version, and `scripts/verify.sh` checks it for SwiftPM and for Xcode, because the generated project's lock file is not committed.
- The Mac development store sits in the development container in a folder named for the worktree, which corrects the earlier item that placed it in the worktree. After G1 and SP-3, the gate has one development-signed step for a PR that touches KnotAgent, `knot`, the Mac app or KnotStore: the sandboxed app and `knot-dev` share a store, the tool writes and the app shows it.
- The command line follows the additions to docs/product-spec.md §10: an unsettled note carries the time at which it will settle, a deletion stays reportable after the purge, a foreign cursor is refused, and a segment whose capture is open cannot be edited or deleted.
- WP-34 covers each of those additions with a golden test. The M4 setup registers the MCP server for one personal folder, not for the user.
- Product behaviour added to docs/product-spec.md, each with its builder: a press never does nothing after a crash (§4.2, WP-02 and WP-12); a capture that the disk stops keeps what it has (§4.4, WP-12 and WP-18); longer text continues in a new segment (§4.4, WP-02 and WP-11); an open note deleted elsewhere says so and offers to restore (§7, WP-21); and one window on the iPad (§6, assumption A36, WP-01 and WP-35). Assumptions A35 and A36 join §16, and A14 now says how its second is measured.
- The Live Activity's attributes type lives in KnotIntents and belongs to WP-19. An intent reads the environment through one accessor that fails with a typed error when nothing is registered, and WP-19 tests that.
- WP-18 saves a drawing off the main thread with one save in flight, and meets the new target of 500 ms after a stroke.
- Evaluation baselines. The synthetic cleanup and speech results are committed with the fixtures. A meaning-critical case that passed and now fails blocks the PR, and the nightly run on `main` reports a model that changed with an update of the operating system.
- WP-43's release script repeats the check for KnotFakes on the archive, and refuses a binary that honours the preview launch argument. Its privacy text says that the command-line switch is consent and not a wall.
- Appendix B gains one line: after the queue has rebased a branch, its thread resets to the remote branch before it changes anything else.
- The owner's calendar gains about 20 minutes: 10 at G1 for the ruleset and the interaction limit, and 5 each at M2 and M3 for the forced restart.
- `TODOS.md` gains four deferred items, fourteen in all: automatic takeover of a recording whose device is gone, batching the merge queue, a separate account for agent builds, and several windows on the iPad.
- The owner answered the review's gate on 2026-11-19. The items below, as far as the one that begins "The second engineering pass", record his answers and what they change, and each wins over any earlier item it contradicts. He took every recommendation except one: milestone builds reuse the retired app's bundle identifier. The rewrite after approval adds the five answers that change the plan to §2 as D32 to D36, dated 2026-11-19.
- D32, the keep gate (user challenge 1, taken without the wave 0 trial). M2 is a keep gate. When the M2 checklist has passed, the owner uses the M2 milestone build as his only capture tool on the iPhone for seven days. The week runs on that build as it is, in the system look and with the structure of the chosen direction. A fix found during the week ships as a new M2 build with a tested migration, because his iPhone notes are real from M2 on.
- The week ends with the keep-gate sitting, about 30 minutes. The owner brings the diagnostics export from About, which gives the week's counts without any note text: captures a day by kind, captures that failed or stayed pending, uses of "New note", and segments moved to their own note. WP-22's exporter carries those counts. He answers five questions in writing: did he reach for Knot, was anything lost or stuck, was the grouping right, did the notes get used, and would he go back to what he used before. He then rules one of four ways: continue as planned, continue with cuts, revise the spec first, or stop the build. The orchestrator records the answers and the ruling in `docs/decisions/keep-gate.md` and turns his notes into changes to docs/product-spec.md, each through a contract PR where it reaches KnotCore. The "handled" mark of user challenge 3 is looked at again at this sitting.
- Until that ruling, nothing that the cut order names is built, and wave 4 does not start. That holds back WP-35; everything in WP-18 after its proof step; the Sketch control of WP-31 and the OpenSketch intent of WP-19; the Home Screen and Lock Screen widgets of WP-31; WP-32's complication families beyond the first and its Smart Stack widget; and WP-40, WP-41, WP-42 and WP-43. Each held part of WP-19, WP-31 and WP-32 becomes that package's last PR, so the plan has about 57 PRs before contract and fix PRs. WP-18's proof step still runs early, because WP-02's third PR waits for its note, and the ink types stay in WP-02's contracts. WP-44 keeps running from M1, and the work for M3 and M4 goes on during the week. If the full design round has run by the ruling, the orchestrator lists what the ruling changes in `docs/design/deltas.md` and sends that list to the designer, as it does for a gap.
- The cut order. If the build has to shrink, at the keep-gate sitting or at a later milestone sitting, scope leaves in this order, and only on the owner's word. No agent cuts scope.
  1. iPad Pencil: WP-35, the rest of WP-18, the Sketch control and intent, and M5. The iPad then keeps the iPhone's layout, which it has had since M1, and has no canvas, no side-by-side layout, no hardware-keyboard shortcuts and no menu bar. Ink stays a kind the store knows, so a later version can add it without a migration.
  2. System surfaces beyond the first of each kind: the Watch complication families beyond one, the Smart Stack widget, and the Home Screen and Lock Screen widgets of the iPhone. The Action Button, the controls and one complication stay.

  A part that is cut is not started. The orchestrator writes each cut to `TODOS.md` with what would bring it back, and updates the briefs in `docs/plan/` and the checklists in one PR. If M5 is cut, every condition that names M5 names M4: the deployment of the CloudKit production schema, which then also needs a recording made on one device to play on the other, and the start of WP-43. Anything beyond these two steps is a new decision of the owner's.
- The owner's calendar gains the keep-gate sitting, 30 minutes, and seven days pass between the M2 checklist and the start of M5 and wave 4 work. His sittings come to about 17 and a half hours.
- D33, a repair for a wrong grouping (user challenge 4). A segment can be moved to its own note, as docs/product-spec.md §7 and rule 16 of §3 state, with assumption A37 and its example in §16. The action sits beside Delete on every segment of a note that holds another live segment. The app undoes it at once, and the window follows the most recent capture into its new note. Merging notes, splitting a note at a point and moving a segment into another existing note stay out of v1, and `TODOS.md` gains that as one deferred item, fifteen in all.
- The store carries the move as one operation and its inverse, as docs/architecture.md §4 and §5 state. WP-02 puts both in the `NoteStore` contract and in the in-memory fake, and WP-10 implements them. The new note has a fresh ID, and its other fields come from the segment. Both notes take new counter values, and each note's latest-capture time is recomputed, in one transaction. A generated title follows the recording at the head of its note, and a typed title stays. A conflict copy moves with the segment it copies. `segment_history` keeps the note a segment left for 30 days. The contract suite covers these cases, and the real store passes them: a move and its return leave both notes exactly as they were; a repeated move changes nothing; a move is refused for an open capture, for a deleted segment and for a conflict copy; a segment alone in its note stays; a return is refused when the note it left is deleted; a generated title goes with its recording and comes back with it; and a process killed inside a move leaves the segment in exactly one note. WP-02's table for rule 16 covers a capture made inside the window of a segment that was just moved.
- Sync carries a move by the rule in docs/architecture.md §11, and WP-16's merge core implements it. The segment's `noteID` merges against the last-synced value. When two devices moved the same segment, the note whose ID sorts higher keeps it. A person's move wins over the deleted-note rule. A note left empty is hidden and is never marked deleted for that reason. Deleting a note marks the note and not its segments. A conflict copy is made in the note of the segment it copies. The simulation adds moves and their undos to its interleavings and checks a sixth invariant: every segment is in exactly one note, and a note with no live segment is never shown. Three sync tests are required by name, as docs/architecture.md §17 lists them: a segment moved on two devices before they sync, a move that meets a delete of the note it left, and an undo that returns a segment to a note deleted elsewhere. SP-4 also answers whether a segment record's note reference can change after the record is saved, which the deleted-note rule needs as well.
- The command line gains `knot move <segment>`, as docs/product-spec.md §10 states, and `knot restore` returns a moved segment for 30 days. The command table generates the MCP tool from the same row. WP-34 adds a golden test for each result: moved, nothing to move, refused for an open capture, returned, and a return refused because the note is gone. `knot changes` reports both notes after a move, and reports a note left empty as deleted.
- The interface for the move. WP-21 adds the action and its undo to the note's view model, with tests for when the action is offered and for an undo after the note it left was deleted. WP-30 and WP-33 build it into the note view on the iPhone and the Mac, the iPad inherits it, and it can be reached from the keyboard on the Mac and the iPad. The state matrix of docs/design/brief.md §6 gains the row "A segment moved to its own note, with undo", 48 rows in all, and WP-21's preview test reads it from that table. The UI smoke tests on the iPhone and the Mac move a segment and undo the move. WP-04 adds one row to the M2 checklist, for the move and its undo, and two to the M4 checklist: `knot move` with `knot restore`, and a move made on the iPhone that shows on the Mac.
- D34, the bundle identifier (taste decision 12 of the gate, answered against the recommendation). Milestone builds reuse `com.p3ob7o.knot`, with the app group `group.com.p3ob7o.knot` and the iCloud container `iCloud.com.p3ob7o.knot`, and the Mac's app-group form stays open until SP-3 reports. The retired app does not live beside them: the first milestone build installed on a device replaces it there. This replaces the recommendation of the earlier item, and that item's conditional rules now hold outright, as docs/architecture.md §7 states them under "Legacy data". `StoreLocations` roots everything v1 writes in a folder named `KnotStore/`, because the retired app owns `Application Support/Knot/` in the same container. v1 keeps its settings in a named defaults suite and never reads `UserDefaults.standard`, and the lint of WP-01's gate fails on that symbol. v1 refuses a database it did not create. WP-10 has a test, required by name, that builds a container laid out as the retired app left it and checks that every old file is byte for byte unchanged after the store has opened there. Milestone builds carry a version above 0.2.0, which is the retired app's.
- Every build that is not a milestone build keeps the development identifiers, as the earlier item on build flavours says. That includes the spikes and the TestFlight upload of the SP-3 spike app, so nothing before the M1 milestone build touches the retired app or its container. The M1 checklist starts with two rows for every device that had the retired app: empty its pending captures, and quit it before the install. G1 still confirms the whole set of identifiers.
- D35, the early upload (taste decision 1 of the gate). The one internal TestFlight upload of the SP-3 spike app is a planned part of G1, and its row in the owner's calendar no longer says "if authorised". At G1 he creates an App Store Connect record for the development identifier and an API key, about 20 minutes, and hands the key over as a file path through the secret prompt. The upload runs only then. SP-3's report includes the result of the distribution-signed check. Knot's own record, for `com.p3ob7o.knot`, is created by the owner at G5.
- D36, the owner's notes and the build Mac (taste decision 2 of the gate). The build Mac holds no real notes while the build runs. From the M4 milestone build the owner's real notes on a Mac live on his other Mac, and the M4 checklist names the Mac for each row. This replaces the recommendation of the earlier item on the repository's rules at G1.
- His other answers leave the earlier items as written. Sync stays optional and lands at M4, with its gate kept for a later decision (user challenge 2). No "handled" mark is added in v1 (user challenge 3). The Pencil canvas stays on the iPad and the iPhone Duo, with the Duo path stated as untested (user challenge 5). Taste decisions 3 to 11 and 13 to 26 of the gate stand as recommended.
- The second engineering pass read the plan with those answers applied. Its two reviewers raised 48 findings. The items below are what they change, and each wins over any earlier item it contradicts. They change how the owner's answers are carried out, and none of the answers.
- The hold names PRs, so that no milestone waits for a held part. WP-31 ships in two PRs: the first has the controls, the Live Activity and the Action Button tip, and the second, held, has the Sketch control and the Home Screen and Lock Screen widgets. WP-32 ships in three, and its third, held, has the complication families beyond the first and the Smart Stack widget. WP-19's fourth PR, held, is the OpenSketch intent. M2 needs the first PR of WP-31, and M3 the second of WP-32. M5 needs the fourth PR of WP-19 and the second of WP-31, and M6 the third of WP-32. If M5 is cut, WP-31's second PR loses the Sketch control and M6 needs it.
- Start conditions, replacing the table of the earlier item. A PR starts when everything in its row has merged. A spike counts when its report has merged and the owner has confirmed it. "The ruling" is the keep-gate ruling.

  | Package | PR | Starts after |
  |---|---|---|
  | WP-00 | 1, the restart | The plan's approval |
  | WP-00 | 2, the fold | Its PR 1 |
  | WP-01 | 1 | WP-00, PR 2 |
  | WP-01 | 2 | Its PR 1, beside WP-02 |
  | WP-04 | | WP-00, PR 2 |
  | The proof steps of WP-12, WP-13, WP-14 and WP-18, and the code half of each spike | | WP-01, PR 1, and WP-04 |
  | WP-02 | 1 | WP-01, PR 1 |
  | WP-02 | 2 | Its PR 1, and the notes of WP-12, WP-13 and WP-14 |
  | WP-02 | 3 | Its PR 2, and the notes of WP-18, SP-1, SP-2 and SP-4 |
  | WP-05 | | WP-02, PR 2 |
  | WP-06 | | WP-05 and WP-10, PR 1 |
  | WP-10 | 1 | WP-05 |
  | WP-10 | 2 | SP-3, SP-4 and WP-02, PR 3 |
  | WP-11 | | WP-05 |
  | WP-12 | 1 | WP-05 |
  | WP-12 | 2 | Its PR 1 and WP-02, PR 3 |
  | WP-13, WP-14 | | WP-05 |
  | WP-15 | 1 | WP-05 |
  | WP-15 | 2 | SP-1 |
  | WP-16 | | WP-10, PR 2 |
  | WP-17 | 1, the outbox | WP-02, PR 2 |
  | WP-17 | 2, the transport | SP-2 and WP-02, PR 3 |
  | WP-18 | After its proof step | The ruling, WP-05 and WP-02, PR 3 |
  | WP-19 | 1 | WP-05 |
  | WP-19 | 2 | SP-1 and WP-02, PR 3 |
  | WP-19 | 3 | SP-2 |
  | WP-19 | 4 | The ruling |
  | WP-20 | | WP-02, PR 2 |
  | WP-21 | 1 | WP-05 |
  | WP-21 | 2 | The design direction and WP-02, PR 3 |
  | WP-22 | 1 | WP-05 and WP-10, PR 1 |
  | WP-22 | 2 | PR 1 of WP-10 and WP-15; WP-11, WP-12, WP-13 and WP-14 |
  | WP-30 | 1 | WP-21, PR 1 |
  | WP-30 | 2 | The design direction, WP-21, PR 2, and WP-22, PR 1 |
  | WP-31 | 1 | SP-1 and WP-19, PR 2 |
  | WP-31 | 2 | The ruling |
  | WP-32 | 1 | PR 1 of WP-12, WP-17 and WP-21 |
  | WP-32 | 2 | SP-2, the design direction, WP-17, PR 2, WP-19, PR 3, and WP-21, PR 2 |
  | WP-32 | 3 | The ruling |
  | WP-33 | 1 | WP-21, PR 1 |
  | WP-33 | 2 | The design direction, SP-5, WP-21, PR 2, and WP-22, PR 1 |
  | WP-34 | 1 | WP-05 |
  | WP-34 | 2 | WP-10, PR 2, and WP-20 |
  | WP-34 | 3 | Its PR 2. Embedding the tool waits for SP-3. |
  | WP-35 | | The ruling, WP-18, WP-21, PR 2, and WP-30 |
  | WP-40a to WP-40d | | The ruling, the accepted handoff, and that platform's app package |
  | WP-41 | | WP-40 |
  | WP-42 | | The ruling and WP-22 |
  | WP-43 | | The ruling, and M5 or, if M5 is cut, M4 |

  Three rules sit beside the table. The PRs of WP-11, WP-12 and WP-15 that add kill points merge after WP-06. M2 still needs the second PR of WP-22, although the second PRs of WP-30 and WP-33 no longer wait for it. The longest chain to M2 is WP-00, the first PR of WP-01, the first two of WP-02 with the proof steps beside them, WP-05, the first PR of WP-10, the modules, the second PR of WP-22 and the second of WP-30. A second chain runs through the third PR of WP-02, which waits for the short notes of the spikes and not for their reports, and the second PRs of WP-21 and WP-30. The fold generates this table from the headers of the briefs, and `scripts/check-plan.sh` fails on a cycle, on a row that names a package without a PR where the package has several, and on a milestone that needs a held PR.
- The keep-gate counts have a source. WP-10 keeps a local table of daily counters that hold no content: captures by kind, captures and jobs that failed, uses of "New note", moves and returns. A capture row records the placement that was asked for. A move counts when it is made, a return counts apart, and a repeat that changes nothing counts as neither. WP-22's exporter reads the table, as docs/architecture.md §7 and §19 state.
- A milestone build has a level. Every milestone build, and every fix built for an earlier milestone, is made at a level from M1 to M7, and a feature whose milestone has not passed is switched off in it by a gate: sync and the command line open at M4, and ink at M5. WP-01 builds the mechanism, and WP-22 the test that lists the gates for each level. A fix made for M2 during the keep-gate week therefore carries nothing from M3 or M4. The M4 sitting passes its two-device rows on development builds first, in the development container. The M4 milestone build then opens sync on the owner's notes, after an export of the iPhone's store.
- Appendix A's list of what needs the owner's word gains every operation on the milestone iCloud container, in either environment. It says "distribution signing" where it said "signing", because agents sign development builds all day. From the deployment of the production schema on, the CloudKit schema is a committed file, and the gate fails on a change to it that is not additive.
- Schema version 1 is the schema of the M2 milestone build. Every change after that build is a numbered migration, whichever package makes it, the second PR of WP-10 included. WP-01's lint fails on GRDB's `eraseDatabaseOnSchemaChange`. The seeded store committed at each milestone tag holds work in flight: an open capture, a queued job and a pending delete. Every later build opens it, migrates it and passes the whole `NoteStore` contract suite on it.
- The move names what the caller saw. `knot move <segment> --from <note>` moves the segment only if it is still in that note, and otherwise changes nothing and says where it is, so a repeat is safe even after a later capture has joined the new note. `knot move <segment> --back` returns it. A return is refused when the segment's note has changed since the move, or when the note it left is deleted or gone, and it works on the Mac where the move was made, because `segment_history` is local. `knot restore` keeps its two meanings and gains none: it undoes a delete, or brings back replaced text on a segment that is not deleted. The app's undo is the same return. This replaces the wording of the owner's items on the command line and on the M4 checklist, whose row uses `knot move --back`. The contract cases of the owner's item on the store change with it: a repeat answers "not in that note", and a segment alone in its note is refused. WP-34's golden tests cover six results: moved; not in that note; refused for an open capture; returned; a return refused because the segment moved again; and a return refused because the note is gone.
- A segment's place has a generation. `noteGeneration` on `Segment` syncs, and rises each time the segment's note changes, by a move, a return or the deleted-note rule, as docs/architecture.md §4 and §11 state. The higher generation wins a merge. At the same generation a person's move wins over the deleted-note rule, and then the note whose ID sorts higher wins. A derived ID is a version 5 UUID, so the two are told apart by the ID alone. This replaces the comparison with the last-synced value in the owner's item on sync. WP-16's simulation runs every order of a move, its undo and a delete across three replicas.
- A move does not outlive a purge. A segment moved out of a note that another device deleted stays only if the move reaches that device before the deleted note is purged, 30 days later. After that the purge stands, as for any change to a purged record, and a test with that name covers it.
- Titles do not move with a segment. When a segment leaves a note, the note's generated title is checked again against the words still in the note and dropped if it no longer fits, and a typed title is never touched. The new note has no title. The clean job proposes a title only for the note that holds its recording when the job finishes, and only if that recording is the note's first segment and the note has none. A return puts a dropped title back if the note still has none. The check is one function in KnotCore, which KnotCleanup and the store both call. This replaces "a generated title follows the recording" in the owner's item on the store, and its contract case becomes a dropped title that a return puts back.
- Sync uploads what a merge makes. A conflict copy, a derived note, or a note reference or an owner that the merge settled is queued for upload in the transaction that made it, although the change-log triggers are off on that connection. Only a record applied exactly as fetched leaves nothing pending, and the test of that name says so.
- Two devices that take a recording at the same generation are told apart by device ID: the higher one owns it, every device applies that rule when the records merge, and the other drops its result. WP-16's simulation has that case by name.
- The retired app holds drafts as well as pending captures, for inactive vaults too (`Knot/macOS/RecoveryView.swift:21`). The M1 checklist's rows for a device that had it become three: clear its Recovery window of drafts, pending captures and outcomes that need review; keep a copy of the retired app; quit it before the install. If something was missed, that copy still opens its store, which v1 leaves untouched, and WP-43's guide says how.
- The upgrade rows name what they install over. At M1 the milestone build, signed for development as `com.p3ob7o.knot`, is installed over the retired app, and the row checks that the retired app's folder is still there. At M7 the TestFlight build is installed over the M6 milestone build, which has the same identifier and development signing. The SP-3 upload under the development identifier proves neither.
- The standard defaults domain belongs to the retired app's keys. WP-01's lint also fails on `@AppStorage` without a named store and on an autosave name without the `v1.` prefix, because the system writes those into the standard domain. WP-10's test of the retired container also checks that every key the retired app wrote still has its value.
- SP-3 is closed only when the route it chooses has passed the distribution-signed check. If the direct route fails there, the XPC route gets an internal upload of its own before the second PR of WP-34, and the report says what the tool does when Knot is not running, which docs/product-spec.md §10 then follows. The API key is handed over for one upload and revoked after it, and each upload needs the owner's word. The spike app carries the privacy manifests with their required reasons, so App Store Connect checks them in wave 1.
- SP-3 splits. SP-3 keeps command-line access to the store, the packaging rules and distribution signing. A new spike, SP-5, takes the hotkey's press and release in a sandboxed build, the panel over a full-screen app, the key-state check and whether first words are clipped. Every earlier mention of SP-3 for those means SP-5. SP-5 is size S, starts after the first PR of WP-01 and gates the second PR of WP-33. G3 gains two rows: 15 minutes for SP-5's rows on the Mac, and 15 to install the SP-3 build from TestFlight and run its check.
- From the M4 milestone build on, no milestone build is installed or run on the build Mac, because a milestone build with sync open would bring the owner's notes onto it. At G1 the owner registers his other Mac for development-signed builds. `scripts/install.sh` gains a path for a Mac: it writes the build to a folder he names, and he opens it there. The owner's recordings in `KNOT_LOCAL_FIXTURES` stay on the build Mac, as the earlier items say: they are recordings he makes for the build and chooses himself, not notes from his stream.
- Text past the size limit continues in further segments of the same capture. The first shares the capture's ID, and each later one has an ID derived from the capture's ID and its position, so a repeat returns the same segments and the ledger counts the capture once. WP-02 and WP-11 carry it, with a test that repeats a long capture.
- A revision that leaves the store carries the store's generation. A write that names a revision from before a restore is refused as a conflict, like a foreign cursor, and WP-34 has a golden test for it.
- Three rules of docs/product-spec.md §3 and §4.1 are now exact, and WP-02 tests each. A capture started on another surface ends the open one, whatever its kind. A gap that is negative by less than the window counts as inside it, and a larger one starts a new note. Text that is only spaces and line breaks is empty.
- WP-02's third PR adds seven supporting ports, each with a fake, as docs/architecture.md §5 lists them: where an Open intent lands, the cues, background time, free space, the install identity, the notice between processes and the app's lifecycle. Error codes are values and not a closed list of cases, and every synced enum has an unknown case from WP-02's first PR, so a new case does not break a branch. A contract PR that only adds merges in the normal queue. One that breaks keeps the two fixed times.
- A capture has one life across the store and `Inbox/`. One that falls back stays on the file path until it ends, and its manifest records the placement that was asked for and the note the surface showed. The store call it stopped waiting for may still commit. The row is made once, by whichever arrives first, every later save is a checkpoint by revision, and ingest places the capture where the manifest says. WP-05 and WP-11 have a named test for a store call that commits after the fallback.
- In the app process the recorder decides, not the heartbeat: a press stops a recording that this process is running. The heartbeat serves other processes and recovery. WP-02's reducers and WP-12 follow docs/architecture.md §8, and SP-1 also tests whether a toggle control's intent carries the value the control showed.
- The in-memory `NoteStore` is checked against the real one. WP-10 has a seeded differential test that applies random sequences of operations to both and compares every result, and WP-34's golden tests run on both.
- The notice between processes is a hint. The app also compares the store's change counter with the one it last showed whenever it comes forward, and once a minute while it runs. WP-10 has a test in which the tool dies before it posts.
- A restored copy brings back text. A recording or drawing purged after the copy was made shows as missing, and the restore says how many there are. Captures waiting in `Inbox/` are ingested afterwards as usual. WP-10 tests a restore of a copy older than a purge.
- A record counts as synced only for the account, the environment and the zone identity it was synced under, and the zone carries an identity written when it is made. So a record missing from the zone it was synced to is deleted locally, and a zone that is gone or new deletes nothing. A fetch that would delete more than a set share of the local notes pauses sync and asks. WP-16 builds this and SP-4 fixes the mechanism. The simulation adds a zone removed and made again, and every replica uploading after a change of environment. The move from the development environment to production is rehearsed between two development containers before M7, and the M7 checklist starts with an export of the store on each device.
- The age of a synced delete is measured between two dates the server gave, never against the device's clock. The simulation has a replica whose clock runs 40 days ahead.
- Asset folders are named by the last two characters of the ID, since the first ones of a time-ordered ID stay the same for years. The content hash of a capture is keyed with a secret of the store and stays out of the diagnostics export. When iCloud storage is full, sync says so, and text waits with the recordings while everything stays on the device.
- WP-17 ships in two PRs. The first is the outbox and the coordinator that records, converts and sends, both in KnotLink and tested on the Mac with kill points. The second is the transport. The coordinator finishes a conversion that a kill interrupted. The phone acknowledges a file once it is durably in `Inbox/` and matches its manifest, without waiting for ingest, so a phone whose store will not open cannot fill the watch. M1 needs the first PR of WP-17.
- WP-01's first PR declares a crash-host executable for KnotStore, for KnotAudio and for KnotLink, and the soak's child, because a kill test needs a process to kill. Each module exposes one live entry point that returns the unavailable port until its package fills it in, so WP-16, WP-17, WP-18 and WP-19 wire themselves in without editing `Sources/KnotApp/`.
- The checks are shown to fail. WP-06 merges only when four injected faults each turn the soak red: an acknowledgement before the write, a skipped capture row, a dropped last checkpoint and a capture stored twice. The `NoteStore` contract suite must fail three deliberately broken fakes. The second opinion from another model extends to WP-02, WP-05, WP-06, WP-11 and WP-17. Every finding the orchestrator sets aside is written in the PR and in the journal.
- A lint keeps `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` to a reviewed list. The nightly run executes the package tests under Thread Sanitizer. WP-12 has a test that feeds 30 minutes of injected audio and counts the same frames out.
- WP-04 adds checklist rows for what injected audio cannot show. M2: AirPods connecting during a recording, an incoming call, Siri and an alarm. M4: a microphone unplugged during a recording, and sleep. SP-2 records 30 minutes with the wrist down. The meaning-critical cleanup set gains cases in which only the punctuation differs, and docs/product-spec.md §5 says what the guard proves and what it does not.
- At G1 the owner sets up signing so that the gate's development-signed step runs without a prompt, and `scripts/doctor.sh` probes it. The script also refuses a repository, a build folder or a fixtures folder that a cloud file provider syncs: the stray "… 2" files of the retired tree are conflict copies from such a sync, and `~/Documents` still carries its attributes. The gate's lint fails on a file whose name ends in " 2".
- docs/architecture.md §17 lists the tests this pass adds by name, and `docs/plan/named-tests.txt` gives each its owner. Cleanup runs with greedy sampling, and each cleaned segment records the OS build whose model made it. `scripts/build-slot.sh` also limits how many simulators are booted at once.
- Every target has a privacy manifest that declares a required reason for each API that needs one, and WP-01's lint fails on such an API with no reason declared.
- WP-00 ships in two PRs: the restart, then the fold. The fold turns the amendment lists into the briefs, and a second model reviews it item by item. `docs/plan/amendments.md` gains a column that names what each item replaces, with a short quote of the replaced text, and `scripts/check-plan.sh` fails when a brief still holds a quote that was replaced. Four traps are known: the soak is built by WP-06 and not by WP-22; late arrivals are placed by the store and not by WP-11 or WP-15; the soak's trigger paths are those of docs/architecture.md §17; and the answers D32 to D36 join §2. WP-00's `git clean -X` runs from a reviewed list that leaves `.gstack/` and `.conductor/`. The second worktree's untracked files go into the archive under a folder of their own, because one of them differs from a tracked file of the same name.
- Counts. The plan has 31 work packages, five spikes and about 60 PRs before contract and fix PRs. The owner's calendar gains about 40 minutes: 30 at G3 for the two spike rows, 5 at G1 for the other Mac and for signing, and 5 across M2 and M4 for the audio rows. His sittings come to about 18 hours.
<!-- /autoplan-accepted:eng -->

<!-- owner-answers:g0-assumptions -->
- These items come from the owner's answers on the assumptions of docs/product-spec.md §16. He gave them on 2026-11-19, after approving the plan, as gate G0 asks. They add to the items above, and where one of them contradicts an earlier item, the later one wins. No review has read them yet: the fold's item-by-item review reads them with the rest. The fold treats this list as it treats the four before it. `docs/plan/amendments.md` has one row for each of its items, and `scripts/check-plan.sh` fails while PLAN.md still holds it.
- He confirmed 32 of the 34 assumptions as written. They are decisions now. Their marks are gone from docs/product-spec.md, and §16 lists each with his answer. WP-02 turns them into tests, as planned.
- A6, changed. His words: "Watch doesn't show content, it's only a capture device." The Watch shows no note content: no stream, no text of a recording and no preview of one. docs/product-spec.md §6 and §15 say so. The back channel of docs/architecture.md §12 carries no note text and nothing about a transcript. It carries only what the Watch needs for the indicator of rule 4: the end of the capture that a new recording would join, if there is one, and the window. The phone works that out by the rules of §3, so a note closed by "New note" and a deleted note give none. WP-17 builds it that way and gives its payload no field that can hold note text. WP-32's recent recordings show a time, a length and a delivery state. The Watch states of docs/design/brief.md §6 lose "transcribed with a short preview" and "transcription failed on the phone". WP-04 adds one row to the M3 checklist: no text of a note or of a recording appears anywhere on the Watch.
- A27, changed. His words: "It should be possible to select multiple segments at once." This replaces one part of the design review's item on the editing model: the rule that a selection does not cross from one segment into the next. Several segments can be selected at once, as whole segments, and copied, shared or deleted together, as docs/product-spec.md §7 and §8 state. The rest of that item stands. Each segment is edited on its own, undo covers the segment being edited, and the capture field is the last element of every open note. A text selection made inside a segment stays inside it, so D20 stands, and so does the design review's decision against selecting text across segments.
- What A27 asks of the packages. WP-02 adds the delete and the restore of several segments of one note, each in one transaction, to the `NoteStore` contract and to the in-memory fake, as docs/architecture.md §5 states, and WP-10 implements them. The contract suite covers a selection deleted and restored, a selection that holds every live segment of its note, and a process killed inside the delete, which docs/architecture.md §17 requires by name. WP-20 renders a selection of segments as text and as Markdown with the code that renders a note, and its golden files gain one selection. WP-21 adds the selection and its three actions to the note's view model, with tests for the order of the copied text and for one undo. WP-30 and WP-33 build it into the note view on the iPhone and the Mac, the iPad inherits it, and it can be reached from the keyboard on the Mac and the iPad. The state matrix of docs/design/brief.md §6 gains the row "Note, several segments selected", 49 rows in all. The command line does not change.
- Two readings wait for the owner, and they are the only assumptions left in docs/product-spec.md §16. A38: the Watch still lists its own recent recordings, by time, length and delivery state. The other reading is a Watch with no list at all. A39: "select multiple segments" means whole segments, with copy, share and delete, and "Move to its own note" still takes one segment at a time. The other reading is a text selection that runs from one segment into the next, which needs the rich-text editor D20 rules out. Moving several selected segments together into one new note is left out too, because it would change the move operation that the engineering review fixed. The first list already says that WP-02 does not start before the owner has confirmed the assumptions still open in §16. That holds for both, and A39 is the costly one.
- A35, confirmed for v1. His words: "For v1 yes. Later we'll expand cleanup abilities." Nothing changes in v1. `TODOS.md` gains one deferred item, "Let cleanup do more", sixteen in all.
- G0 has three things left for the owner: A38, A39, and how many sittings a week he can give.
<!-- /owner-answers:g0-assumptions -->
## Review record

Run `main-20261118-235359` of /autoplan, 2026-11-18. Restore point: `.gstack/tmp/autoplan/main-autoplan-restore-20261118-235359.md`. UI scope: yes. DX scope: yes. Outside reviewer: Codex, ready at preflight. gstack upgraded itself from 1.100.0.0 to 1.101.0.0 before the run.

### Phase 1: CEO review

Methodology read in full: `.gstack/tmp/autoplan/autoplan-ceo-methodology-IjAZP1/methodology.md`, lines 1-600, 601-1200, 1201-1800 and 1801-2223 of 2223. Review depth: implementation-ready. Working plan: this file, with docs/product-spec.md, docs/architecture.md and docs/design/brief.md as its parts.

#### System audit

- No stash. Nothing touched in 30 days. The last change on `main` is 5b04c933, from 2026-09-08.
- TODO and FIXME markers exist only in the retired tree, which WP-00 deletes.
- No TODOS.md. No gstack design doc, no prior CEO plan, no learnings and no brain digests exist for this repo.
- The plan files are untracked on `main`. Nothing from them has landed on `origin/main`.
- Retrospective: the repo was rewritten once already, in 5b04c933, from a 76 KB REWRITE_PLAN.md. That rewrite kept the product and replaced the engine. This one replaces the product. The earlier pattern was one large plan followed by one huge change; this plan lands 29 packages as separate PRs instead.
- Taste calibration. Patterns to keep: the verification-status column in docs/architecture.md §20; the assumptions table in docs/product-spec.md §16; the old tree's single-writer rule, which architecture §6 carries over. Patterns to avoid: the retired Gutenberg web editor, a second product inside a capture tool; and the old verify chain of npm audits and notices for a Swift app.

#### Landscape check

Aside was not available, so the queries ran through web search.

- Layer 1, tried and true: capture apps survive on one narrow job, a free or one-time core, and years of maintenance. Bear and Drafts kept moving; Simplenote and Byword stalled.
- Layer 2, new and popular: 2026 brought a crowd of watch voice apps that claim on-device transcription (Talk Memo at $3.99, ThoughtTrack, Dexter Notes, Voice Note Pro). The claims come from App Store listings and are untested.
- Layer 3, first principles: with one owner who is also the user, the market is not the constraint. Daily use is. The real risk is not a competitor. It is a v1 that takes so long to reach the wrist and the hotkey that the owner keeps using what he has.

#### 0A. Premise challenge

The real problem: a thought is lost or delayed because every capture path costs an unlock, an app launch, or typing on the wrong device, and the captures that do land are scattered across four apps. The target outcome: any thought captured in about two seconds from the nearest device, never lost, in one stream. The do-nothing cost: the owner keeps a patchwork of Apple Notes, Voice Memos, a dictation app and Obsidian's Quick Capture. That patchwork works. Knot is a bet on taste and reliability by its only user, and the plan solves that pain directly, not a proxy for it.

| # | Premise | Receipt | Verdict |
|---|---|---|---|
| 1 | The Watch is a gap: "Voice apps upload to a server" | docs/product-spec.md:409, as since corrected | Finding. Several 2026 watch apps claim on-device transcription. The gap is narrower than the spec says. |
| 2 | A recording can start from a locked iPhone | docs/architecture.md:518 | Unverified. SP-1 owns it. |
| 3 | WatchConnectivity delivers recordings reliably | docs/architecture.md:520 | Unverified. SP-2 owns it. |
| 4 | A sandboxed CLI can open the app's store | docs/architecture.md:380 | Unverified. SP-3 owns it. |
| 5 | CKSyncEngine works with an attachments zone it does not fetch | docs/architecture.md:522 | Unverified. SP-4 owns it. |
| 6 | On-device cleanup is good enough | docs/architecture.md:533 | Unverified. WP-14 measures it. |
| 7 | English transcription meets 8% word error rate | PLAN.md:365 | Finding. The fixtures are synthetic system voices (PLAN.md:212), so the gate does not measure the owner's speech. |
| 8 | Contracts first makes ten parallel packages safe | PLAN.md:24, PLAN.md:105 | Unverified. Finding: nothing runs end to end against the contracts before the fan-out. |
| 9 | Carbon hot keys deliver press and release in the sandbox | docs/architecture.md:524 | Unverified. The old adapter registered press only (Knot/macOS/Hotkey/HotkeyManager.swift:120). WP-33 proves it first. |
| 10 | The machine has 16 cores and 48 GB | PLAN.md:681 | Verified. [measured: sysctl, 2026-11-18] |
| 11 | 4 spikes and 29 work packages | PLAN.md:23 | Verified. [measured: heading count, 2026-11-18] |
| 12 | The owner has time for every gate | PLAN.md:702 | Unverified. Seven milestone checklists, four spike checklists and a design round all queue on one person. |
| 13 | Nothing in the old tree is worth keeping | PLAN.md:48 | Finding. The archive holds working code for problems that return unchanged: Knot/macOS/Hotkey/ (about 600 lines, with a shortcut recorder), SurfaceCoordinator.swift and scripts/release.sh. |

Unverified: 8 (rows 2, 3, 4, 5, 6, 8, 9, 12). Findings: 4 (rows 1, 7, 8, 13). Receipts for the two other documents were refreshed to their current lines on 2026-11-19, after the amendments of all four phases moved them. The verdicts are as first recorded.

#### 0B. Existing code leverage

| Sub-problem | Existing code | Does the plan reuse it? |
|---|---|---|
| Global hotkey registration and a shortcut recorder | Knot/macOS/Hotkey/ | No. WP-33 starts from nothing. The old adapter lacks release events, so it is a reference, not a drop-in. |
| A menu bar app that becomes a regular app while a window is open | Knot/macOS/SurfaceCoordinator.swift, MenuBarController.swift | No. |
| A typed draft saved 150 ms behind the last keystroke and flushed on blur and termination | Knot/Shared/EditorModel.swift | No. WP-11 specifies the same behaviour again. |
| A GRDB store in WAL mode with `synchronous = FULL` and a 5-second busy timeout | Packages/KnotKit/Sources/KnotKit/Persistence/ | The settings are carried into docs/architecture.md §7. The code is not. |
| A release script that fails closed | scripts/release.sh | No. WP-43 writes a new one. |
| The app icon and mark | Knot/*/Assets.xcassets | Yes, by D15. |

Why a rebuild and not a refactor: the old product writes Markdown into an Obsidian vault through a vault gateway, and none of that survives D3 and D25. The data model, the storage and three of the four platforms are new, and the owner chose the clean slate in D15. What the plan misses is cheap to fix: point the packages above at the archive branch as prior art.

Reality rows:

REALITY: premise-table finding 13 premises, unverified=8, 4 findings docs/product-spec.md:409
REALITY: already-done pass nothing from the plan files has landed on origin/main since 2026-11-18 PLAN.md:1
REALITY: surface-check pass swift format, xcodegen 2.47.0 and the 14 named gstack skills exist; the scripts and the knot command are planned outputs PLAN.md:149
REALITY: binding-decisions pass no gstack decisions on this branch; D1 to D31 bind and the plan overrules none PLAN.md:28
REALITY: numbers finding speed targets are estimates by the spec's own statement; the 8% accuracy gate rests on synthetic audio docs/product-spec.md:311
REALITY: deferred-asks pass no linked issue PLAN.md:1
REALITY: pr-count finding about 50 PRs against a default of one per wave; D26 binds; the merge queue is C8, owned by the Eng review PLAN.md:668

#### 0C. Dream state

```
CURRENT STATE                      THIS PLAN                          12-MONTH IDEAL
A retired Mac and iPhone app  -->  Knot v1 on four devices:      -->  Knot is the reflex on every device,
for Obsidian capture. Thoughts     one stream; typed, spoken and      in any language the owner speaks.
scattered across Notes, Voice      drawn capture; on-device           Photos and video. His agents read
Memos, a dictation app and         English speech and cleanup;        the stream and act on it. Zero lost
Obsidian's Quick Capture.          optional iCloud sync; a CLI        captures, measured over months.
                                   and an MCP server. One user,       Public on the App Store, sync paid.
                                   through TestFlight.
```

The plan moves straight toward the ideal. It leaves three gaps by the owner's choice: other languages (D4), photo and video (D8), and a public release (D12).

No new approach decision was needed in 0D: D16 settles the approach, with the shared core and four shells first.

#### 0F and 0G. Scope under SELECTIVE EXPANSION

Complexity check. The plan creates 15 modules, 5 app and extension targets and one command-line tool. The module count serves parallel work, not the running app: each module is one agent's folder. That is a fair price on one condition. Every module boundary is a contract written before any implementation exists, so C1 below tests the contracts before the fan-out.

Minimum scope check. Nothing in v1 can be deferred without breaking a decision or a promise. Sync keeps "one stream" true across devices. The CLI and MCP server are D11. The recently-deleted list backs "nothing is lost" against a slip of the finger. Every remaining item is small.

10x view. For about twice the effort, Knot becomes the capture layer for the owner's agents: every finished note reaches them within seconds, and capture needs no screen at all. v1 gives agents pull access through the CLI and MCP server, and screenless capture from the Action Button, the wrist and the Mac hotkey. Push to agents is deferred (X4).

Platform potential. Segments, the inbox and the ports let later versions add inputs (photo, video) and engines (other languages, other cleanup models) without a schema break. The CLI and MCP server are the public surface.

| ID | Proposal | Effort | Risk | Decision |
|---|---|---|---|---|
| C1 | WP-02 proves the contracts compose, with one end-to-end test through the fakes, before wave 2 starts | S | Low | Accepted |
| C2 | WP-10, WP-11, WP-33 and WP-43 read the archived code as prior art | S | Low | Accepted |
| C3 | A read-aloud script and the owner's real recordings become an input to M2 | S | Low | Accepted |
| C4 | Correct the Watch-gap claim in docs/product-spec.md §17 | S | Low | Accepted |
| C5 | Record engine, version and locale on every transcript, and allow re-transcription | S | Low | Accepted |
| C6 | Capture ledger invariant, with a kill-and-count soak test | M | Low | Accepted |
| C7 | Bound the owner's gate load: one spike sitting, timed checklists | S | Low | Accepted |
| C8 | Price and design the merge queue for about 45 PRs | M | Medium | Pending. Owner: Eng review. |
| X1 | Tap a word in a voice segment to play from there | M | Low | Deferred to TODOS.md |
| X2 | Drag a note out of the Mac window as text or a Markdown file | S | Low | Accepted. A taste decision for the final gate. |
| X3 | Spotlight finds notes | S | Medium, privacy | Deferred to TODOS.md |
| X4 | A "note ready" hook on the Mac that runs a Shortcut or a command | M | Medium, sandbox | Deferred to TODOS.md |
| X5 | Handoff of an open note between devices | S | Low | Deferred to TODOS.md |
| X6 | "Add to Knot" in the Services menu and the share sheet | M | Low | Deferred to TODOS.md |

This table is the scope as first decided. The spec review loop added C9 to C39 and X7 and replaced C1, C3, C5, C6 and C7; the CEO scope summary lists every row.

Decision ledger:

| ID and owner | Contract and evidence | Current | Proposed | Status | Exact approval and scope |
|---|---|---|---|---|---|
| C1, CEO 0A | Premise 8; PLAN.md:105 | Ten packages start as soon as the contracts merge | WP-02 adds an end-to-end test through the fakes, and wave 2 waits for it | approved | Auto-decision 3. Scope: WP-02 "Done when" and the wave 2 start condition. |
| C2, CEO 0B | Premise 13; Knot/macOS/Hotkey/HotkeyManager.swift:120 | Packages start from nothing | Four packages read named archive paths first | approved | Auto-decision 4. Scope: a "Prior art" line in WP-10, WP-11, WP-33 and WP-43. |
| C3, CEO 0A | Premise 7; PLAN.md:212, PLAN.md:365 | Accuracy gate on synthetic voices; real recordings "when convenient" | Read-aloud script; the owner records before M2; both numbers reported | approved | Auto-decision 5. Scope: WP-04, WP-13, the §10 gate row and the M2 checklist. |
| C4, CEO 0A | Premise 1; landscape check | The spec says voice apps upload to a server | A corrected claim | approved | Auto-decision 6. Scope: docs/product-spec.md §17 only. |
| C5, CEO 0C | D4 leaves other languages for later | No record of what produced a transcript | Engine, version and locale stored; the transcribe job can run again | approved | Auto-decision 7. Scope: `Segment` fields and one WP-15 behaviour. |
| C6, CEO 0A | Promise 2 of the spec, "nothing is lost" | No single invariant and no count | Ledger invariant and soak test | approved | Auto-decision 8. Scope: an architecture §6 rule and a WP-22 test. |
| C7, CEO 0A | Premise 12; PLAN.md:702 | Eleven checklists with no time bounds | One spike sitting; minutes and a 20-row cap per checklist | approved | Auto-decision 9. Scope: §10 and WP-04. |
| C8, Eng | The pr-count reality row; PLAN.md:668 | Serial rebase and full verify for every PR | To be designed | unresolved | None yet. Eng review owns it. |
| X2, CEO 0G | Owner taste for OS integration, D31 | No drag-out | Drag a note out of the Mac window | approved | Auto-decision 10, taste. Scope: WP-33 only. Surfaced at the final gate. |
| X1 and X3 to X6, CEO 0G | Delight scan | Not in the plan | Later versions | deferred | Auto-decisions 11 to 15. Scope: TODOS.md entries only. |
| S1.1, spec review | Finding 1.1; docs/architecture.md §4 and §6 | An invariant with nothing to count | A `capture` table, a defined start and outcomes, the watch outbox as its ledger | approved | Auto-decision 16. Replaces C6. Scope: architecture §4, §6, §7; WP-02, WP-05, WP-10, WP-17, WP-22. |
| S1.2, spec review | Finding 1.2 | Cross-device processing undefined | Ownership, sync timing, machine-text precedence, titles, deletes, the settings split | approved | Auto-decision 17. Scope: architecture §11, spec §5 and §9, SP-4, WP-16. |
| S1.3, spec review | Finding 1.3 | The brief lacks eight states | Added | approved | Auto-decision 18. Scope: brief §6. |
| S1.4, spec review | Finding 1.4 | Nine " 2" files deleted unarchived; bundle ID reuse unexamined | Archive them; decide the bundle ID at G1 | approved | Auto-decision 19. Scope: WP-00, G1, the M1 checklist. |
| S2.1, spec review | Finding 2.1 | C1's test cannot be written inside WP-02 | WP-05 Capture tracer | approved | Auto-decision 20, taste. Replaces C1. Surfaced at the final gate. |
| S2.2, spec review | Finding 2.2 | Hardware checks inside merge criteria; M1 unowned | Merge criteria split from milestone evidence; an owner per milestone; M1 without watch delivery | approved | Auto-decision 21. |
| S2.3, spec review | Finding 2.3 | Re-transcription contradicts "never modified" | Metadata only; re-transcription deferred | approved | Auto-decision 22. Replaces part of C5. |
| S2.4, spec review | Finding 2.4 | Headers disagree with the spikes and the chain | One table of start and second-PR conditions | approved | Auto-decision 23. |
| S2.5, spec review | Finding 2.5 | C3 conflicts with the fixtures rule and sets no bar | Local commands, one exemption, first thresholds, Voice Memos as the method | approved | Auto-decision 24. Replaces C3. |
| S2.6, spec review | Finding 2.6 | C7's cap does not fit the plan | An owner calendar with minutes | approved | Auto-decision 25. Replaces C7. |
| S2.7, spec review | Finding 2.7 | A module cycle and missing ports | `AppEnvironment` in KnotCore; three ports added | approved | Auto-decision 26. |
| S3.1, DX | Finding 3.1 | The CLI and MCP contract is open | To be decided | unresolved | None yet. The DX review owns it. |
| S3.2, spec review | Finding 3.2 | Append and hotkey rules undecided | Rules 9 to 12; the hotkey timing | approved | Auto-decision 28, taste for A14 to A16. |
| S4.1, spec review | Finding 4.1 | Spotlight still named as a consumer | The entity is not indexed; reads need an unlocked device | approved | Auto-decision 29. |
| S4.2, spec review | Finding 4.2 | Drag-out unspecified; the Duo path untested | Drag-out specified. The Duo path stays as D7 says. | approved | Auto-decision 30. The Duo choice goes to the final gate. |
| S5.1, spec review | Finding 5.1 | The spikes miss four questions; SP-3 needs signing | Questions added; a development-signed build | approved | Auto-decision 31. |
| S5.2, spec review | Finding 5.2 | The iOS database sits in the shared container | The app's own container on iOS | approved | Auto-decision 32. |
| S5.3, spec review | Finding 5.3 | The soak runs in every merge; skipped model tests pass | Soak nightly and per milestone; models required at the gate | approved | Auto-decision 33. The merge queue stays with C8. |
| S5.4, spec review | Finding 5.4 | The design arrives after the UI is built | The direction step first; second PRs wait for it | approved | Auto-decision 34, taste. Surfaced at the final gate. |
| S5.5, spec review | Finding 5.5 | The beta toolchain is unexamined | An availability rule; a release Xcode check | approved | Auto-decision 35. |
| T1, spec review 2 | Issue 1; the M1 row and WP-22's start | The package that owns M1 starts after all of wave 2 | WP-22 in two PRs; the composition PR owns M1 | approved | Auto-decision 36. Scope: WP-22, the milestone table, the start table. |
| T2, spec review 2 | Issue 2; docs/architecture.md §11 | The production CloudKit schema is approved before its hardware evidence | Deployed only after M5 | approved | Auto-decision 37. Scope: architecture §11, the owner calendar, WP-16. |
| T3, spec review 2 | Issue 3; docs/product-spec.md §4.2 and §6 | A held note under about 1.3 seconds is discarded | Hold-to-record exempt from the one-second discard; a listening cue; the microphone at key-down on built-in and wired inputs | approved | Auto-decision 38, taste. Scope: spec §4.2, §6, §14; WP-33. Surfaced at the final gate. |
| T4, spec review 2 | Issue 4; WP-14's "Done when" | The evaluation prints "numbers only" and also shows ten pairs in a PR | Pairs go to a git-ignored file; PR examples stay synthetic; the order of the two commands is fixed | approved | Auto-decision 39. Scope: the real-recordings amendment, architecture §17. |
| T5, spec review 2 | Issue 5; docs/architecture.md §7 | Reusing the bundle ID shares the retired app's container | A new subfolder and defaults suite, a database check, an M1 row; decided at G1 | approved | Auto-decision 40. Scope: architecture §7, G1, the M1 checklist. |
| T6, spec review 2 | Issue 6; docs/architecture.md §3 | `.preview` cannot be built from fakes alone | `.preview` is the real engine over the fakes on iOS and macOS; WP-05 delivers it | approved | Auto-decision 41. Scope: architecture §3, WP-05. |
| T7, spec review 2 | Issue 7; docs/design/brief.md §9 | The direction rule and its table disagree | The table aligned; `docs/design/direction.md`; provisional structure for the watch and the iPad | approved | Auto-decision 42. Scope: the design-direction amendment. |
| T8, spec review 2 | Issue 8; docs/architecture.md §5 | Four ports have no implementer | Each port assigned to a package, with its contract suite | approved | Auto-decision 43. Scope: architecture §5; WP-10, WP-12, WP-16. |
| T9, spec review 2 | Issue 9; docs/product-spec.md §9 | A segment appended to a note deleted elsewhere is hidden, then purged | It moves to a new note on sync | approved | Auto-decision 44. Scope: spec §9, architecture §11, WP-16's simulation. |
| T10, spec review 2 | Issue 10; docs/product-spec.md §3 | No rule says when a typed capture starts | Rule 13: at the first keystroke | approved | Auto-decision 45. Scope: spec §3, assumption A17, WP-02's tests. |
| T11, spec review 2 | Issue 11; docs/architecture.md §4 | Crash recovery is defined for recordings only | Killed transitions for typed and ink; a launch step that finishes drafts and drawings | approved | Auto-decision 46. Scope: architecture §4, WP-22. |
| T12, DX | Issue 12; docs/product-spec.md §10 | An agent cannot tell a stale store from a current one | To be decided with the CLI and MCP contract | unresolved | None yet. The DX review owns it, with S3.1. |
| T13, spec review 2 | Issue 13; PLAN.md §10 | The owner calendar omits four duties and drops the gate IDs | Rows added, G0 to G5 kept, a milestone-evidence column in `docs/status.md` | approved | Auto-decision 48. Scope: the owner calendar, §8.7. |
| T14, spec review 2 | Issue 14; docs/architecture.md §6 | The capture ledger leaves five questions open | Each answered in rule 6; WP-05 has merge criteria | approved | Auto-decision 49. Scope: architecture §6, WP-05. |
| T15, spec review 2 | Issue 15; docs/architecture.md §4 | The model cannot express two amended rules | `closedAt` on `Note`, `processingOwner` on `Segment`, one more brief state | approved | Auto-decision 50. Scope: architecture §4, brief §6. |
| T16, spec review 2 | Issue 16; the CEO scope summary | Three amendments and seven items have no decision row; watch playback appeared at M1 | Rows added; playback removed | approved | Auto-decision 51. Scope: the CEO scope summary, the M1 amendment. |
| T17, spec review 2 | Issue 17; PLAN.md §6 sizes | WP-02 and WP-22 are sized M | Both L, in two PRs; about 50 PRs | approved | Auto-decision 52. Scope: WP-02, WP-22, the PR count. |
| T18, final gate | Issue 18; decision D7 | The Pencil canvas ships for an iPhone nobody can test | iPad only in v1 | unresolved | None. D7 is the owner's decision, so the question goes to the final gate and D7 stands until he rules. |
| T19, spec review 2 | Issue 19; SP-3 | Distribution signing is checked last | One internal TestFlight upload of the SP-3 spike app in wave 1, if the owner authorises it | approved | Auto-decision 54, taste. Uploading needs the owner's explicit authorisation at the final gate. |
| T20, spec review 2 | Issue 20; docs/architecture.md §17 | The soak, the Mac UI tests and the model thresholds do not fit their budgets | The soak's fakes stated; an exclusive UI-test slot; `--gate`; thresholds in package PRs | approved | Auto-decision 55. Scope: architecture §17 and §18, WP-01. |
| U1, spec review 3 | Issue 1; WP-01's identifiers, docs/architecture.md §7 | Development and test builds share the owner's real store and iCloud account | Development identifiers for every build that is not a milestone build; an Appendix A hard rule | approved | Auto-decision 56. Scope: architecture §7, WP-01, Appendix A. |
| U2, spec review 3 | Issue 2; docs/architecture.md §7 | No rule says when on-device data must survive | Disposable until M2 on iPhone and iPad and until M4 on the Mac; then tested migrations; an SP-4 question; M7 rows | approved | Auto-decision 57. Scope: architecture §7 and §11, SP-4, the M7 checklist. |
| U3, spec review 3 | Issue 3; docs/architecture.md §11 | The deleted-note rule splits one note into several | The new note's ID is derived from the deleted note's ID; a purged record is treated the same | approved | Auto-decision 58. Scope: architecture §11, WP-16's simulation. |
| U4, spec review 3 | Issue 4; docs/product-spec.md §4 | Five edge cases have no stated behaviour | Spec §4.4, rule 14, the `RecordingActivity` port, export of remote attachments, three brief states | approved | Auto-decision 59. Scope: spec §3, §4.4, §8; architecture §5; brief §6. |
| U5, spec review 3 | Issue 5; docs/architecture.md §14, decision D23 | Recording intents outside the iPhone contradict each other | A per-platform intent table; ToggleRecording; WP-19 in three PRs with the watch part after SP-2 | approved | Auto-decision 60. Scope: architecture §14, spec §6, WP-19. |
| U6, spec review 3 | Issue 6; docs/architecture.md §3 and §6 | Command-line writes bypass the one writer | One `NoteStore` operation records a capture for the engine and for `knot` | approved | Auto-decision 61. Scope: architecture §5 and §6, WP-02, WP-10, WP-34. |
| U7, spec review 3 | Issue 7; the start table | Unnamed PRs hide chains to M2 | A PR named for every dependency; spikes confirmed one by one; chains recomputed | approved | Auto-decision 62. Scope: the start table, the milestone table. |
| U8, spec review 3 | Issue 8; docs/product-spec.md §16 | New cross-device rules are not marked as assumptions; counts disagree | A18 to A24; counts and four stale lines corrected | approved | Auto-decision 63. Scope: spec §9 and §16, the CEO scope summary, architecture §5 and §11, brief §6. |
| U9, spec review 3 | Issue 9; docs/product-spec.md §6 | The first 250 ms of the hotkey are undefined | A timeline table per microphone class; no listening before permission or when hiding; which keys qualify | approved | Auto-decision 64, taste, with T3. Scope: spec §6 and §14, architecture §15. |
| U10, spec review 3 | Issue 10; the soak test | "Acknowledged" has no contract behind it | `CaptureEngine` publishes the saved revision; the harness is a child process killed at named points | approved | Auto-decision 65. Scope: architecture §5 and §17, WP-02, WP-22. |
| U11, spec review 3 | Issue 11; PLAN.md §8.5 | Some merge criteria need the owner; some deliverables sit in paths their package does not own | The milestone-evidence rule extended; three path exceptions | approved | Auto-decision 66. Scope: the milestone-evidence amendment, path ownership. |
| U12, spec review 3 | Issue 12; the real-recordings amendment | `knot-eval` and a nightly run have no owner | `knot-eval` declared by WP-01 and owned by WP-13 and WP-14; file names; by-eye repeats; no nightly run | approved | Auto-decision 67. Scope: architecture §3 and §17, WP-01, WP-13, WP-14. |
| U13, spec review 3 | Issue 13; docs/architecture.md §3 | The test module is linked into the apps, and WP-01 returns an environment that does not exist yet | KnotFakes, KnotTestSupport and KnotUIPreviews; an `.unavailable` environment; a debug-only launch argument | approved | Auto-decision 68. Scope: architecture §3, WP-01, WP-02, WP-05. |
| U14, spec review 3 | Issue 14; SP-3, WP-33 | Three facts are proven after the work that depends on them | The hotkey and panel proof in SP-3 with a fallback; the release Xcode at G1; the M4 command-line result provisional without the early upload | approved | Auto-decision 69. Scope: SP-3, architecture §15, G1, the risk table. |
| U15, spec review 3 | Issue 15; the owner calendar | The calendar under-counts the milestone sittings | Each milestone sized on its own, repeat sittings counted, about 13 hours in total | approved | Auto-decision 70. Scope: the owner calendar. |

#### 0H. Spec review loop

The CEO scope summary is saved on the build Mac, in gstack's folder for this project, as `ceo-plans/2026-11-19-knot-v1-rebuild.md`.

Launch 1 scored the plan 6 out of 10 and passed no dimension. It raised 20 issues, 4 of them blocking: the capture ledger had nothing to count (1.1), C1's test could not be written inside WP-02 (2.1), "Done when" lists mixed merge criteria with hardware gates (2.2), and re-transcription contradicted the data model (2.3). Every finding was checked against the documents and held. All 20 were resolved: 18 by amendments to the four documents, and 2 routed to later phases (the merge queue to the Eng review, the CLI and MCP contract to the DX review).

Launch 2 scored the amended plan 7 out of 10 and again passed no dimension. It raised 20 new issues, 4 of them blocking: the package that owns M1 could not start until all of wave 2 had landed (1), the production CloudKit schema was approved before its hardware evidence (2), short push-to-talk notes were discarded by the one-second rule (3), and four ports had no implementer (8). None repeated a launch 1 issue. All 20 held when checked. 18 were amended, 1 joined the DX review's list (how an agent learns the store is stale), and 1 is queued for the final gate because it would change decision D7 (the iPhone Duo canvas).

Launch 3, the last the loop allows, scored the plan 7 out of 10 and again passed no dimension. It raised 15 new issues, 3 of them blocking: development and test builds shared the owner's real store and iCloud account (1), the recording intents outside the iPhone contradicted each other (5), and the test module ended up linked into the apps while WP-01 had to return an environment that did not exist yet (13). None repeated an earlier issue. All 15 held when checked, and all 15 were amended.

The loop stops at its cap of three launches, so no reviewer has read the last amendments. The primary reviewer checked each launch 3 fix against the amended text: issues verified, 15 of 15. That check also found six stale lines in docs/architecture.md and four loose ends in the amendments, all now fixed: WP-19 needed a third PR for the watch intents; M2 needed both PRs of WP-15; start conditions named gate G3 where they meant one spike; and the Mac's notes could not be promised at M2 while SP-3 still decides where its store lives.

Decision, spec not re-verified: the amended documents go forward without a fourth spec review. The CEO dual voices and the Design, DX and Eng reviews read the amended plan next, and they are the remaining independent check.

Totals for the loop: 3 launches, 55 issues, 11 of them blocking. 51 were amended, 3 were routed to the DX and Eng reviews, and 1 waits for the owner at the final gate. Later launches found none of the 36 amended issues of launches 1 and 2 again. Latest score: 7 out of 10. Prior review scores: 6 and 7.

Scope-document approval: auto-decided A. The CEO scope summary and the amended plan state the same decisions, counts and proposal IDs, checked after the last amendment. This accepts the document versions only. The pending rows (C8, C9, T12, T18) stay open.

#### 0I. Temporal interrogation

The implementer here is a team of agents, so the hours map to waves.

| Stage | What the implementer needs, or will hit | Disposition |
|---|---|---|
| Hour 1, foundations: WP-00, WP-01, WP-02, WP-05 | An agent reads one package section, so the amendments must be folded into the body before WP-00 opens its PR. | Covered by the first amendment and by §12 step 1. |
| | Two sets of identifiers now exist, for milestone builds and for development builds. Both must be registered under the owner's account. | Covered by G1, whose row now names both sets. |
| | Where the signing team ID lives in a public repository. | Pending. Owner: Eng review. Not a blocker. |
| | How a port publishes changes. WP-02 fixes 18 signatures before any consumer exists. | Covered by WP-05, the first consumer, which corrects contracts before the fan-out. |
| Hours 2 to 3, core logic: wave 2 | What the fidelity guard may accept. The cleanup pass rate depends on it, and "changes the words" is not yet defined for case, punctuation or numbers. | New obligation: WP-14 states the allowed differences as a table. Auto-decision 73. |
| | Which recording format survives a kill. | Covered by WP-12's proof-first step. |
| | Whether the speech model is installed where the gate runs. | Covered: the merge gate requires the models. |
| Hours 4 to 5, integration: wave 3 | Getting a build onto five devices. No package owned the procedure, and a watch install goes through the iPhone. | New obligation: `scripts/install.sh`, corrected from what SP-1 and SP-2 learn. Auto-decision 74. |
| | About 50 PRs through one serial gate. | Pending: C8. Owner: Eng review. |
| | The Mac app-group identifier and the entitlements of the `knot` tool. | Covered by SP-3. |
| Hour 6 and later, polish and tests: wave 4 | Side-by-side screenshots for WP-40 need a way to render every state of every screen. | Pending. Owner: Design review. |
| | An automated accessibility audit for WP-41. | Pending. Owners: Design and Eng reviews. |
| | The orchestrator thread runs for weeks, so its state must survive a context reset. | Pending: C8. Owner: Eng review. `docs/status.md` is the durable record. |

Feasibility blockers: none stays open at this level. Two were found here and closed by amendments: the install path, and the guard's allowed differences.

Effort, as estimates and not measurements:

- A human team: 30 packages and 4 spikes, 10 of the packages L. About 16 to 20 engineer-months for a team of four.
- CC and gstack: about 120 to 200 agent-hours of implementation with five threads at a time, so the build work fits in days. What is serial sets the calendar: about 50 merges through one gate, and about 13 hours of the owner's time across seven milestones, one spike sitting and two design steps. A realistic span is 2 to 4 weeks if each gate is answered within a day.

Spec review metrics, saved to gstack's analytics log on the build Mac: 3 launches, 55 issues found, 36 fixed (none found again by a later launch), 19 remaining (15 amended after the last launch and not yet read by a reviewer, 3 routed, 1 for the final gate), latest score 7.

#### CEO dual voices

Both voices read the same input: `.gstack/tmp/autoplan/autoplan-ceo-jqy0hm/ceo-implementation.md`, SHA-256 `010b747a11a9be855e30c75687bb34bcd2c9f60d5bf3e4831369532004020832`, the implementation plan as amended through 0I. Their full reports are saved beside it as `ceo-voice-claude.md` and `ceo-voice-codex.md`.

**Claude subagent.** Completed, and its INPUT line matched the snapshot hash. One critical, five high and five medium findings:

1. Critical. The plan stops when a note lands. All three promises are about capture, and v1 has no way to finish an item. Its reframing: Knot is the input device for the owner's agents.
2. High. Sync is called optional, but "one stream" across devices depends on it, and it arrives at M4.
3. High. Three product premises are tested after the plan commits to them: speech on the owner's own voice, what cleanup adds, and the append window.
4. Medium. The critical path runs through the owner, and the plan schedules the agents.
5. High. This is the third build in seven months, and nothing says what would make it stick. It asks for a keep gate at M2 and a written cut order.
6. Medium. The spec says Knot wins on feel and reliability. The plan builds reliability first and feel last.
7. Medium. Reusing the retired app's bundle ID costs special-case code and replaces a working app.
8. Medium. The microphone would open on every tap of the Mac hotkey.
9. High. A one-way outbox was ruled out together with the mirror (D25), with no recorded reason.
10. Medium. Nobody asked whether to build or adopt the sync layer.
11. High. The gaps Knot aims at come from one day of desk research. It asks for a two-day bake-off with the alternatives.

**Codex.** Completed with model `gpt-6-astra`, VERDICT: FINDINGS. Ten high findings and one medium:

1. High. Approval is treated as validation. No milestone requires sustained use.
2. High. Closeness in time is taken for relatedness, and a wrong grouping cannot be repaired.
3. High. The plan optimises depositing thoughts without showing how they become useful.
4. High. Sync is classed as optional although the promise depends on it.
5. High. Four-platform breadth is committed before the first product-learning gate.
6. High. The cleanup promise exceeds what the evidence can establish.
7. High. Alternatives are listed, not tested against the build.
8. High. The Watch advantage has no end-to-end success measure.
9. Medium. A later paywall targets behaviour the free product teaches.
10. High. The archive can gather transcription mistakes with no way to improve them.
11. High. "Nothing is lost" has crash tests but no backup and restore path.

```
CEO DUAL VOICES — CONSENSUS TABLE:
  Dimension                               Claude                     Codex                        Consensus
  1. Premises valid?                      No: three tested late      No: approval is not proof    CONFIRMED concern
  2. Right problem to solve?              Partly: ends at capture    Partly: deposit, not use     CONFIRMED concern
  3. Scope calibration correct?           No: no keep gate, no cuts  No: breadth before learning  CONFIRMED concern
  4. Alternatives sufficiently explored?  No: outbox, sync layer     No: none tested              CONFIRMED concern
  5. Competitive/market risks covered?    No: desk research only     No: Watch claim unmeasured   CONFIRMED concern
  6. 6-month trajectory sound?            No: third rebuild          No: no restore, no reprocess CONFIRMED concern
CONFIRMED = completed subagent + outside; primary cannot replace outside.
```

Both voices completed, so each cell is a two-voice result. Neither found a flaw in the build mechanics. Both ask whether the plan proves the product before it builds all of it.

Dispositions. Two reviewers agreeing is not evidence, so each finding was checked against the documents first.

**User Challenges.** Where both voices recommend changing a direction the owner stated, the change is not made here. It goes to the final gate, and the owner's direction stands until he rules:

| ID | The owner said | Both voices recommend | Findings |
|---|---|---|---|
| UC1 | Build everything, as parallel as possible, in the order of D16 | Prove it before building all of it: a two-day trial of the alternatives and a premise sitting in wave 0, a week of real use at M2 before iPad Pencil and wave 4 start, and a written cut order | Claude 3, 5, 11. Codex 1, 5, 7. |
| UC2 | Notes are saved locally and/or synced, and sync may be paid later (D18) | Treat sync as core: bring it forward, and settle now whether it can ever be paid | Claude 2. Codex 4, 9. |
| UC3 | One thing done well: offload a thought. No folders, tags or links (D21) | Decide what happens to a note after capture: a "handled" mark that the owner or an agent sets, and one tested path from capture to use | Claude 1, 9. Codex 3. |
| UC4 | Captures inside the window join one note (D2) | Add a repair for a wrong grouping: move a segment out into its own note | Claude 3. Codex 2. |

**Accepted now**, because they change no decision of the owner's:

- The owner records the read-aloud script and his voice notes in wave 0, so that the proof steps of WP-13 and WP-14 run on real speech before the fan-out. He reads the cleanup pairs before the full design round. (Claude 3)
- docs/product-spec.md §16 marks each assumption cheap or costly to change after WP-02, with a worked example for each costly one. (Claude 3)
- The owner calendar takes a cadence from the owner, budgets three repeat sittings each for M2, M3 and M4, and adds free-form notes. The total is about 16 hours. (Claude 4, Codex 5)
- Test builds export a diagnostics file, and the M2 and M4 checklists record measured latencies. (Claude 4, 6)
- SP-4 also asks whether an existing sync layer would fit. The choice stays the owner's under D30. (Claude 10)
- The cleanup evaluation reports meaning-critical cases separately. (Codex 6, Claude 3)
- The Watch gets an end-to-end target, measured at M3. (Codex 8)
- The M4 checklist begins with an agent filing a note captured on the phone, and the CLI and MCP contract gains a settled state and a change cursor. (Claude 1)
- The README says what happened to the Obsidian capture app. (Claude 7)

**Taste decisions**, auto-decided, with the other view kept for the final gate:

- Backups are stated and tested, but importing an export is deferred. Codex asked for a full backup and restore path through export. (Codex 11)
- Re-transcription stays deferred. It can be added later without a schema break. Codex wants the path defined now. (Codex 10)
- The recommendation at G1 changes to a new bundle identifier. (Claude 7)
- On the Mac the microphone opens at the 250 ms mark of a hold, never on a tap. This reverses the key-down part of auto-decision 38, which a spec reviewer had asked for. Key-down listening stays as the alternative if SP-3 measures clipped first words. (Claude 8)
- The full design round is not split in two. The plan already lets WP-40 apply the handoff to a platform as soon as it exists, and the owner's calendar puts the full round right after the direction. (Claude 6)
- A write-once outbox folder is not added. D25 is the owner's explicit decision, and only one voice asked. It is offered as an option inside UC3. (Claude 9)

#### Current scope

Mode: SELECTIVE EXPANSION, fixed by /autoplan (auto-decision 2).

- Accepted: C1 to C7 and C10 to C46 in the CEO scope summary, and X2. Several replace earlier forms: C1, C3, C5, C6, C7 and the key-down part of C18.
- Pending: C8, the merge queue (Eng review). C9 with T12, the CLI and MCP contract (DX review). T18, the iPhone Duo canvas (final gate). UC1 to UC4 (final gate).
- Deferred to TODOS.md: X1, X3 to X9.
- Rejected: listed under "NOT in scope" below.

#### Section 1: Architecture review

```
 iPhone and iPad app          Mac app                          Watch app
 ┌──────────────────┐         ┌───────────────────────┐        ┌──────────────────┐
 │ KnotUI views     │         │ KnotUI panel, window  │        │ KnotUI           │
 │ KnotIntents      │         │ hotkey, menu bar      │        │ KnotAudio        │
 │ KnotApp (.live)  │         │ KnotApp (.live)       │        │ KnotLink outbox  │
 └────────┬─────────┘         └───────────┬───────────┘        └────────┬─────────┘
          │ ports declared in KnotCore    │                             │ transferFile
          ▼                               ▼                             ▼
 CaptureEngine ──► NoteStore ◄── ProcessingQueue          Inbox/ on the iPhone (app group)
  (KnotCapture)    (KnotStore, SQLite)     │                    │ ingest, once per capture ID
       ▲               ▲        ▲          ├─ Transcriber (KnotSpeech)
 Recorder (KnotAudio)  │        │          ├─ Cleaner (KnotCleanup)
                       │        │          └─ InkRecogniser (KnotInk)
       SyncEngine (KnotSync)    └── knot command and MCP server (KnotAgent): Mac only,
              │                     a second process, off until the owner enables it
              ▼
       CloudKit private database: zone Stream, zone Attachments
 Widget extensions (iOS, watchOS): no database. They read the recording state from the app group.
```

Examined: the module table and dependency rule of docs/architecture.md §3, the four paths of each capture kind, the state machines in §4, the single points of failure, and what a rollback looks like after M2.

- Boundaries hold. Modules depend on KnotCore's ports, with two stated exceptions (KnotSync and KnotAgent use KnotStore). The accepted cherry-picks fit: the capture ledger is local and does not sync, the tracer splits cleanly into WP-11's and WP-15's folders, and the drag-out reuses KnotExport.
- Finding 1.1. Nothing said how an intent reaches the environment, or what the widget extension links. Fixed in docs/architecture.md §14: intents use the App Intents dependency manager, and the extension links KnotIntents for the types only.
- Finding 1.2. Job states were not enumerated, and nothing said what a build does with a kind it does not know. Fixed in §4. The second matters now: v1 builds will meet records from later versions.
- Finding 1.3. Rollback after M2 had no path. Migrations are forward-only, and the pre-migration copy was dropped after one good launch. Fixed in §7: an older build refuses a newer database untouched, and the copy is kept until the following migration.
- Finding 1.4. The review record sits inside the file every implementing agent reads. After approval it moves to `docs/reviews/`, and PLAN.md holds the plan only.
- Scaling. One user, so what grows is the archive. The stream is tested at 10,000 notes. Recordings add roughly 2 to 3 GB a year on the device that makes them, and v1 has no storage management. That is deferred to TODOS.md as X9.
- Single points of failure: the database file (now with a rescue path, Section 2), the iPhone as the watch's only route (D5, by decision), and the orchestrator's Mac for the build (C8).
- Value test for artifacts about the work. `docs/status.md`, the spike reports, `docs/design/direction.md` and the checklists each have a named consumer and a decision that depends on them. Nothing was added that nobody reads.
- What would make it obvious to a new engineer: one page that follows a capture from key press to synced note. docs/architecture.md §6 is that page once the amendments are folded in.

#### Section 2: Error and rescue map

Examined: every port operation in docs/architecture.md §5, the launch sequence, the watch link, sync and the hotkey. The full table is the Error and Rescue Registry below: 46 paths.

Fourteen paths had no stated behaviour before this section. Three of them were silent, which makes them critical: an unreadable inbox item, notes removed from iCloud, and a hotkey release that never arrives. All fourteen now have a rule in docs/architecture.md, an error case that WP-02 must name, an owner package and a test:

1. The database cannot be opened, or is damaged: nothing is deleted, capture continues into `Inbox/`, and the stream says what is wrong (C40).
2. The database is newer than the build: refused, untouched.
3. Conversion to the final audio format fails: the working file stays as the recording.
4. A transcription is interrupted: it continues from its last saved range.
5. No words are recognised: the segment is ready with empty text.
6. The cleanup model is not ready yet: the job waits. Before, the raw transcript became final.
7. A job keeps failing: failed after five attempts, with a manual retry.
8. An inbox item cannot be read: it becomes a failed segment that keeps its file.
9. A watch file fails its checksum: not acknowledged, and on the third time ingested as failed.
10. The zone is removed from iCloud: local notes stay, sync pauses, Knot asks.
11. The saved recording state is stale after a crash: a press recovers the orphan and starts nothing.
12. The hotkey is taken by another app: Settings says so.
13. A hotkey release never arrives: a stop control shows, and Knot checks the key each second.
14. A launch step fails: it is logged, and the next step still runs.

For the language model, the four failure kinds are kept apart in the log and end the same way for the user: a refusal, an empty result, a malformed result and a result the guard rejects all leave the raw transcript as the text.

#### Section 3: Security and threat model

Examined: every way data enters or leaves (no network listener exists), the second process on the Mac, the URL scheme, the model prompt, and what shows on a locked device.

| # | Threat | Likelihood | Impact | Mitigated? |
|---|---|---|---|---|
| 3.1 | Any local process can run the bundled `knot` tool and read, edit or delete every note, past the container protection macOS gives the app | Medium | High | Now yes. The tool and the MCP server refuse to run until the owner turns on command-line access. Deletes are soft. |
| 3.2 | A note's text carries instructions that an agent reading it through MCP then follows | Medium | Medium | Partly. Tool results mark note text as data, and no tool purges. The DX review owns the rest. |
| 3.3 | A web page or another app opens Knot's URL scheme to write text or start a recording | Low | Medium | Now yes. The scheme only navigates. |
| 3.4 | Search text with full-text query syntax causes an error or an unintended query | Medium | Low | Now yes. Search text is quoted, with a test. |
| 3.5 | A transcript steers the cleanup model | Low | Low | Yes for the body: the guard rejects added words. A generated title is limited to one plain line of 60 characters. |
| 3.6 | The privacy text overstates what iCloud encrypts end to end | Low | Medium | Now yes. WP-43 checks the wording against Apple's documentation. |

One finding is high: 3.1. No secrets enter the repository, the App Store Connect key goes through the secret prompt, GRDB is the only dependency, and logs hold no note text. Lock Screen surfaces show no text, and actions that read a note need an unlocked device.

#### Section 4: Data flow and interaction edge cases

```
 INPUT          VALIDATION            TRANSFORM                 PERSIST                         OUTPUT
 microphone ──► permission,     ──►   working file ► AAC   ──►  capture row ► manifest ►   ──►  stream row,
 samples        input, space          transcribe ► clean        segment + recording             note, search
   │                │                      │                         │
   │ nil: no input  │ refused: never       │ kill: recovered at      │ store busy or full: content goes
   │ device         │ starts, and the      │ launch, at most 1 s     │ to Inbox/, ingest stores it later
   │ empty: a tap   │ reason is shown      │ lost                    │ store will not open: Inbox/, and
   │ under 1 s is   │                      │ convert fails: working  │ the stream says what is wrong
   │ discarded;     │                      │ file kept, retried      │ duplicate: ingest is idempotent
   │ silence is     │                      │ no model: pending       │ stale draft save: ignored by its
   │ kept           │                      │ guard rejects: raw text │ revision
```

Async ordering. Four pairs of operations share state, and each now has a named mechanism and a test with controlled pauses:

| Pair | Invariant | Mechanism | Test |
|---|---|---|---|
| Two captures recorded at once, in one process or two | One append decision each, no duplicate note | The record-a-capture transaction takes the write lock before it reads | WP-10, two processes |
| A debounced draft save and the final flush | Newer text is never replaced by older | Each save carries its revision, and the store ignores an older one | WP-11, paused saves |
| A clean job and an edit by the user | The user's edit survives | The queue never writes over text whose origin is `edited`, checked inside the write | WP-15, paused job |
| A job and a delete | A deleted segment stays deleted | The job's result is dropped when its segment is gone | WP-15 |

Interaction edge cases: 24 examined. Six had no answer and now do:

| Interaction | Edge case | Handled? | How |
|---|---|---|---|
| Typing, then pressing the Action Button | Two captures open at once | Now yes | Rule 15: one capture open per device. The typed line is saved, and the recording is the next segment. |
| Pencil or typing while recording | Overlap | Now yes | Rule 15: a running recording accepts no typing and no Pencil. Assumption A25. |
| A control pressed after a crash | The saved state says "recording" | Now yes | The orphan is recovered and no second recording starts. |
| A clock set back, or a time zone change | A negative gap | Now yes | It counts as inside the window. |
| A recording reaches 30 minutes | The user is not told | Now yes | The same cue as a stop, and the segment says why. |
| Search text with quotes or operators | A query error | Now yes | Quoted, tested. |
| Action Button pressed twice quickly | An accidental recording | Yes | Under one second it is discarded. |
| Hotkey tapped twice, or held while the panel is open | State confusion | Yes | The tap-or-hold state machine. |
| Leaving the app while typing | Lost text | Yes | A flush on background and on quit. |
| Delete, then undo | | Yes | Soft delete, 30 days. |
| "New note" pressed twice | | Yes | The second press does nothing. |
| The window set to zero, or changed mid-window | | Yes | Rules 2 and 10. |
| A phone call during a recording | | Yes | The recording stops and is kept. |
| The watch out of range, or out of space | | Yes | The outbox, and docs/product-spec.md §4.4. |
| Two devices recording at once | | Yes | Rule 8: two notes. |
| A duplicate or backlogged job, or a late arrival | | Yes | WP-15's tests. |
| Sharing while attachments are on another device | | Yes | Export downloads first and lists what it could not get. |
| An edit through `knot` on a segment that changed since it was read | A stale write | Pending | The MCP revision, on the DX review's list. |

#### Section 5: Code quality review

No new code exists, so this section reviews the planned structure. Examined: the module split, naming, and where the plan is over- or under-built.

- Finding 5.1. The append rule now has 15 rules. As one function it would branch far more than five times. WP-02 writes it as an ordered list of small rules, first match wins, each with its own test table.
- Finding 5.2. WP-02 owned "an error taxonomy" with no content. It now has the cases from Section 2, and no port throws an untyped error.
- Not over-built: the 15 modules exist so that one agent owns one folder, and they cost nothing at run time. `FeatureGates` stays a port with one gate, because D18 asks for it.
- One duplication is deliberate: the watch records without the capture engine, because it has no database. The append rule still runs in one place, on the phone.

#### Section 6: Test review

```
 NEW THING                    TEST TYPE              OWNER      HAPPY PATH / FAILURE PATH / EDGE
 Append rule, rules 1 to 15   unit, one table each   WP-02      each rule / none / clock set back, window zero
 Segment and capture states   unit reducers          WP-02      each transition / each illegal one / killed
 Record a capture             contract suite         WP-10      one transaction / busy, full / two processes
 Search                       integration            WP-10      match / query syntax / 10,000 notes
 Migrations and store open    integration            WP-10      upgrade / failed migration / newer database
 Draft saving                 unit, integration      WP-11      saved within 150 ms / save fails / late save
 Recorder                     file-driven            WP-12      record and stop / kill, conversion fails / stale state
 Transcriber                  integration, model     WP-13      fixtures / model missing / no words, from an offset
 Cleaner and guard            unit, evaluation       WP-14      pass set / changed words / refusal, not ready
 Queue                        integration, fakes     WP-15      transcribe then clean / each step fails / edit or delete mid-job
 Inbox ingest                 integration            WP-15      once / duplicate / unreadable item
 Sync                         unit, simulation       WP-16      converge / conflict / zone removed, unknown kind
 Watch link                   unit, fake transport   WP-17      deliver and ack / loss, duplicate, reorder / checksum
 Ink                          fixtures               WP-18      recognise / failure / killed mid-stroke
 Intents                      unit on .preview       WP-19      each perform / Live Activities off / stale state
 Export                       golden files           WP-20      a note / unwritable folder / attachment elsewhere
 View models                  unit                   WP-21      each screen state
 End to end                   system                 WP-22      audio to note / kill at each stage / soak, store unavailable
 Hotkey state machine         unit, fake clock       WP-33      tap, hold / release never arrives / key taken
 `knot` and MCP               golden, stdio          WP-34      each command / bad ID, locked store / access off
 UI smoke                     XCUITest               WP-30, 32, 33, 35   type, record, search, delete and undo
 Hardware                     checklists             M1 to M7   the owner, on five devices
```

What a green result proves, and what it does not, for the promises:

| Promise | Assertion | A wrong result it rejects | Not proven by it |
|---|---|---|---|
| Nothing is lost | After 500 seeded captures with kills: no open capture row, every local segment has a row, every segment holds at least the saved revision | A segment missing after a kill; text shorter than what was reported saved | Real audio hardware, real speech and cleanup engines (scripted here), iOS suspension, the watch, power loss. The M2 and M3 rows and WP-12's kill test cover parts. |
| Typed text is on disk within 150 ms | With a fake clock, the store holds the text 150 ms after the last keystroke | Text held only in memory | Real write latency on a device. WP-42 measures it. |
| At most one second of audio is lost | A killed recording is at least as long as what was recorded, less one second | A file that cannot be read after a kill | The watch and a dead battery. An M3 row. |
| Cleanup never changes the words | The guard rejects any insertion, replacement or reordering | A cleaned text with a new word | A meaning changed by a deletion or by punctuation. The meaning-critical cases and the owner's reading cover that. |
| A watch recording arrives exactly once | With the fake transport: loss, duplication, reordering and a lost acknowledgement all end with one segment | Two segments, or none | Real WatchConnectivity timing. SP-2 and M3. |
| Sync converges and overwrites nothing silently | Two replicas converge after any interleaving of edits, appends and deletes | A lost edit; a segment hidden in a deleted note | Real CloudKit errors and throttling, and three devices. M4 covers two real devices. |

Gaps: 15 failure tests were implied by accepted behaviour and not named. docs/architecture.md §17 now names them with their owners. They are determined by decisions already taken, so they needed no new choice.

- The test for 2 a.m. on a Friday: the soak with kills, plus the end-to-end suite.
- The test a hostile tester writes: a kill inside every write, airplane mode during a transfer, a full disk, a clock change, a search made of query syntax.
- The chaos test: seeded kill points, random interleavings of two replicas, random draft sequences. All three are in the plan.
- The pyramid is sound: many rule and reducer tests, one contract suite per port, few system and UI tests, hardware by checklist.
- Flakiness is handled where it could arise: time through a fake clock, randomness through seeds, model tests kept out of the merge gate's thresholds, Mac UI tests on one exclusive slot.
- Prompt changes: a PR that changes the cleanup instructions, the guard or the speech settings reruns the evaluation set and `knot-eval` and states both results. The baseline is the raw transcript.

#### Section 7: Performance review

Examined: the stream query, memory for long recordings and drawings, indexes, the processing queue's worst case and the launch path.

- Finding 7.1. A stream row needs a title or first line, a preview, the kinds and any pending state. Fetched per row, that is one query per note. WP-10 makes a stream page one query, gives every contract query an index, and shows each query plan in a test.
- Finding 7.2. A 30-minute recording transcribes for several minutes, longer than iOS gives a background app. A job that restarts from zero each time might never finish. Transcription now runs in ranges and continues from the last saved one.
- Finding 7.3. The working file's size was unbounded on the watch. WP-12's proof step reports it per minute on each platform, and a 30-minute recording must fit with its converted copy.
- Finding 7.4. The launch sequence could delay the first frame. The capture surface is now on screen before any launch step, and typing does not wait.
- The three slowest paths, as estimates: transcribing a long recording (minutes), a fresh restore of 5,000 notes from iCloud (unknown, SP-4 measures it), and a cold launch to the keyboard (target one second).
- No pool pressure: writes run on the store's actor, and the 5-second busy timeout never blocks the main thread.

#### Section 8: Observability and debuggability

Knot has no telemetry by decision, so everything here is local.

- Finding 8.1. Nothing tied a capture's log lines together across devices. Every line about a capture now carries the capture ID, which is the same on the watch, the phone and the Mac.
- Finding 8.2. A failed checklist row cost another sitting to diagnose. Test builds now export a diagnostics file from About, with no note text in it.
- Finding 8.3. A sync error shows only in Settings, so sync could be stuck for days unseen. The brief now asks where a lasting problem shows. The Design review owns the answer.
- Finding 8.4. No runbook existed. WP-43 writes a troubleshooting guide with one entry per failure in the registry.
- Three weeks after a bug: system logs will be gone, but the `capture` rows, the job rows and the sync records are in the database. The ledger is the audit trail, and the diagnostics export carries it.
- Day-one "dashboard": `knot status` on the Mac and the diagnostics file elsewhere, with captures by outcome, pending and failed jobs, the last sync time and error, and the watch outbox.

#### Section 9: Deployment and rollout

```
 PR merged on main ──► milestone build from main, in a fresh worktree, with the real identifiers
   ──► scripts/install.sh on the paired devices ──► the owner's checklist sitting ──► evidence in docs/status.md
 M1 to M6: development signing, CloudKit development environment
 after M5: the owner approves the CloudKit production schema ──► deploy it (one way)
 M7: archive with the release Xcode ──► the owner authorises the upload ──► TestFlight
   ──► install over the development build ──► five smoke rows
```

```
 A bad PR on main?  ──► revert the squash merge ──► gate ──► merge
 A bad milestone build on a device?
   ├─ no migration ran ──► install the previous milestone build
   └─ a migration ran  ──► the previous build refuses the newer database and leaves it untouched
         ├─ sync on  ──► reinstall the previous build and restore from iCloud
         └─ sync off ──► restore the pre-migration copy; the newer file is kept beside it
 A bad TestFlight build? ──► the previous build stays installable until it expires
 The CloudKit production schema? ──► no rollback: fields are only ever added
```

- Risk 9.1. Two devices on different builds will sync with each other after v1. A build must keep, and save back untouched, a kind or a field it does not know. Fixed in docs/architecture.md §4 and §11, with a round-trip test in WP-16. This is cheap now and expensive after the first release.
- Risk 9.2. Rollback steps existed nowhere. They are in §7 and go into WP-43's guide.
- Risk 9.3. The first minutes after the TestFlight install had no checks. The M7 checklist gains five smoke rows.
- Migration safety, the production schema's timing and the switch between CloudKit environments were settled in Step 0.

#### Section 10: Long-term trajectory

- Debt this plan takes on, five items: the Carbon hotkey API, which is old but the only one that fits; a hand-written MCP server that must follow its specification; provisional watch and iPad structure until the design round; the amendment list until it is folded in; and recordings that grow without storage management.
- Reversibility: 4 out of 5. Packages are separate PRs, the old app is archived, and data is disposable until M2. Two doors are one-way and both are gated: the CloudKit production schema, and the bundle identifier once an App Store record exists.
- Path dependency: the note and segment model shapes what comes next. Photo and video add kinds, which the unknown-kind rule now allows. Re-transcription adds transcript versions, which is additive. Splitting a note (UC4) changes a segment's note, which sync must then carry.
- After v1: other languages, photo and video, a public release with paid sync, and push to agents. The ports, the `transcription` record and the `sync` gate support each.
- Looking back at the cherry-picks: none of the deferred items turned out to be load-bearing. X4, the "note ready" hook, becomes the first candidate after v1 if the owner accepts UC3.
- In a year, a new engineer reads the spec, the architecture and one package section. That holds only if the amendments are folded in and the review record leaves PLAN.md.

#### Section 11: Design and UX review

```
              any entry point
  icon, widget │ Action Button, control, hotkey held, wrist │ Pencil on iPad
       ▼                         ▼                                 ▼
  CAPTURE: typing ──mic──► CAPTURE: recording               CAPTURE: ink
       │                         │ stop                           │ end
       │                         ▼                                ▼
       │                 recorded ► transcribed ► cleaned     recognising ► ready
       │                         │ a step fails: failed, with retry
       ▼                         ▼
   the segment lands in the open note, or in a new one
                 ▼
              STREAM ◄──► SEARCH
                 ▼
               NOTE: read, edit in place, play, show original, delete and undo, share
                 ▼
             SETTINGS: window, cleanup, English variant, sync, export, recently deleted, about
  problems: cannot start (reason shown) · could not save (surface stays open) · notes could not be opened · sync error
```

| Feature | Loading | Empty | Error | Success | Partial |
|---|---|---|---|---|---|
| Typed capture | None, by rule | Empty field | Could not save; the surface stays open | Segment in the stream | Draft recovered after a crash |
| Voice capture | Key held, microphone not yet live | Under one second discarded; no words recognised | Cannot start, with the reason; a failed step with retry | Cleaned text with its recording | Pending; raw transcript before cleaned |
| Ink capture | None | Empty canvas discarded | Recognition failed, with retry | Drawing with recognised text | Recognising |
| Stream | None: a page loads in one frame | First run | Notes could not be opened | Rows | Rows with pending and failed segments |
| Search | None | No results | None: any text is a valid search | Results | None |
| Sync | Syncing | Off | Error, storage full, no account, notes removed from iCloud | Idle | Attachments waiting or downloading |
| Watch | None | Idle | Could not start; storage nearly full | Saved | Waiting for the phone, sent, transcribed |
| Export | In progress | Nothing to export | Folder not writable | Done | Done, with a list of what it could not fetch |

- What the user sees first is the capture surface, then the note being added to, then the stream. Whether the stream is the same screen is the brief's first question, and the direction step answers it.
- Finding 11.1. The brief lacked six states the documents now require: a recording stopped at its limit, notes that could not be opened, export progress and result, a hotkey already taken, the command-line access switch, and a held key before the microphone is live. Added to docs/design/brief.md §6.
- Finding 11.2. A lasting problem had no place outside Settings. Added as the brief's eighth question.
- Finding 11.3. Touch targets had no minimum. The brief now sets 44 points.
- Finding 11.4. The plan runs gstack's design reviews later, and they compare against `DESIGN.md`, which does not exist. WP-40 writes it from the handoff.
- Finding 11.5. Until WP-40 lands, the owner judges the product in the system's default look. That risk is real for M2. It is covered if he runs the full design round before M2, which his calendar allows.
- The emotional arc: a thought arrives mid-task, one press, a cue that Knot is listening, relief. Stop, and certainty that it is saved. Later, a cleaned and titled note. The next day, it is found. When something fails, the reason shows at once and nothing fails silently.
- Generic-interface risk is low. The brief asks for a page, not a form or a chat, and names what the owner dislikes.
- The deep design review is Phase 2 of this run. After the build, `/design-review` and `/ios-design-review` check the rendered apps, as WP-40 already requires.

#### NOT in scope

Deferred, each with an entry in TODOS.md:

- X1, tap a word to play from there. It needs stored word timings.
- X3, Spotlight finds notes. A privacy decision for the owner.
- X4, a "note ready" hook on the Mac. A new setting, and sandbox questions.
- X5, Handoff between devices. It depends on stable sync.
- X6, "Add to Knot" from other apps. A new extension target.
- X7, transcribing old recordings again. No trigger and no consumer in v1.
- X8, importing an export. Backups cover restore in v1.
- X9, storage management for recordings. A concern at one year, not at launch.

Rejected, with no TODO:

- A second Claude Design round. One round with a direction step first.
- Reference implementations inside the test target. WP-05 builds the real thin engine.
- A nightly soak run. It had no owner. The soak runs at milestones and in the gate of PRs that touch the store, capture or audio.
- Copying the retired app's code. It is read as prior art.
- Watch playback at M1. Nobody had decided it.
- Building the XPC fallback up front. Only if the signing check fails.
- Listening from key-down by default. It stays the alternative.
- A write-once outbox folder. D25 excludes a mirror. It is offered inside UC3.
- Making the designed iPhone app part of M2. The owner's calendar already allows it.

The owner's own exclusions are in docs/product-spec.md §15 and are not repeated here.

#### What already exists

The table in 0B stands: the hotkey adapter, the activation coordinator, the draft checkpointing, the GRDB settings and the release script are read as prior art by WP-33, WP-11, WP-10 and WP-43. The icon and mark are reused as files. Outside the repository, the plan reuses gstack's `/review`, `/codex`, `/qa-only`, `/ios-qa`, `/cso`, `/design-review` and `/health`, and T3 Code's threads and worktrees, and builds none of that itself.

#### Dream state delta

After this plan: Knot v1 on four devices, one stream, typed, spoken and drawn capture, on-device English speech and cleanup, iCloud sync, a command and an MCP server, for one user through TestFlight. The capture ledger and the diagnostics file make "zero lost captures" something he can count, not only hope for.

Still short of the 12-month ideal:

- Other languages, photo and video, and a public release, by the owner's decisions D4, D8 and D12.
- Agents are served by pull. Push waits for X4.
- What happens to a note after capture is undecided (UC3), and a wrong grouping cannot be repaired (UC4).
- Old transcripts cannot improve (X7), an export cannot be imported (X8), and recordings grow unmanaged (X9).

#### Error and Rescue Registry

| # | Codepath | What can go wrong | Error case | Rescued? | Rescue action | The user sees |
|---|---|---|---|---|---|---|
| 1 | `NoteStore`, record a capture | Disk full | disk full | Y | Content goes to `Inbox/`. If that fails too, the surface stays open. | "Could not save", with the text still in the field |
| 2 | | Store busy for more than 5 s | store busy | Y | Content goes to `Inbox/`; ingest stores it later | A failed marker, then the segment |
| 3 | | The row cannot be written | write failed | Y | As row 2 | As row 2 |
| 4 | `NoteStore`, open at launch | Database damaged | store damaged | Y | Nothing deleted. Capture continues into `Inbox/`. Restore of the pre-migration copy is offered. | The stream says the notes could not be opened |
| 5 | | Database newer than the build | store newer | Y | Not opened, not changed | The same screen, with the reason |
| 6 | | A migration fails | migration failed | Y | The database stays as it was before the migration. Capture continues into `Inbox/`. | The same screen |
| 7 | `AssetStore`, place a file | Disk full; checksum differs after the move | disk full, checksum mismatch | Y | The working file stays in `Recording/`; the queue retries | A failed marker with retry |
| 8 | Typed draft save | The save fails | as rows 1 to 3 | Y | A fallback file in `Inbox/`; marked failed; retried | A failed marker; the text is kept |
| 9 | `Recorder`, start | Permission refused | permission refused | Y | No capture starts | The reason, where the user is |
| 10 | | No input device | no input device | Y | No capture starts | "No microphone"; typing still works |
| 11 | | The audio session is busy | session busy | Y | No capture starts | The reason |
| 12 | | Too little space | too little space | Y | Refuses to start | The reason |
| 13 | `Recorder`, while recording | A phone call | interruption | Y | Stops and saves | The stop cue |
| 14 | | The process is killed | none | Y | Recovered from the manifest at launch | A recovered segment |
| 15 | | The 30-minute limit | limit | Y | Stops and saves | The stop cue, and why it ended |
| 16 | `Recorder`, convert | Conversion or verification fails | conversion failed | Y | The working file stays as the recording; retried | Nothing |
| 17 | `Transcriber` | Speech model not installed | speech model missing | Y | The job waits | A playable recording marked pending |
| 18 | | Audio unreadable | audio unreadable | Y | Failed after its attempts | A failed marker with retry |
| 19 | | Engine error, or no background time left | engine error | Y | Retried from the last saved range | Pending, then failed with retry |
| 20 | | No words recognised | none | Y | Ready with empty text | A recording with no text |
| 21 | `Cleaner` | Model not ready yet | cleanup model not ready | Y | The job waits | The raw transcript meanwhile |
| 22 | | Model unavailable on this device | cleanup model unavailable | Y | The raw transcript is final | The raw transcript; Settings says why |
| 23 | | Refusal, empty or malformed result | cleanup declined | Y | The raw transcript is the text; the kind is logged | The raw transcript |
| 24 | | The result changes the words | guard rejection | Y | The result is discarded | The raw transcript |
| 25 | | The transcript exceeds the context | none | Y | Split on sentence boundaries | Nothing |
| 26 | `InkRecogniser` | Recognition fails | recognition failed | Y | Retried, then failed | The drawing, with a failed marker |
| 27 | `ProcessingQueue` | A job keeps failing | attempts | Y | Failed after five attempts | A failed marker with retry |
| 28 | | A job is found running at launch | none | Y | Back to queued | Nothing |
| 29 | Inbox ingest | An item is unreadable, or from a newer version | inbox item unreadable | Y | A failed segment that keeps the file | A segment that says it could not be read |
| 30 | | A duplicate item | none | Y | Ingest is idempotent | Nothing |
| 31 | `WatchLink`, send | Phone unreachable | none | Y | Kept in the outbox; sent again | "Waiting for iPhone" |
| 32 | `WatchLink`, receive | The move into `Inbox/` fails | disk full | Y | Not acknowledged; the watch sends again | The watch still shows waiting |
| 33 | | Checksum mismatch | checksum mismatch | Y | Not acknowledged; the third time ingested as failed | A failed segment on the phone |
| 34 | `SyncEngine` | No account, storage full, no network | sync status | Y | The engine retries | The status in Settings |
| 35 | | The same text changed on both sides | conflict | Y | The server value stays; the local value is added | Both versions, one marked |
| 36 | | The zone is removed from iCloud | zone removed | Y | Local notes kept; sync paused | A question before uploading again |
| 37 | | The account changes | account changed | Y | Sync paused | A question before uploading |
| 38 | | A record of an unknown kind | none | Y | Kept and saved back untouched | "Made by a newer Knot" |
| 39 | `AssetFetcher` | Not uploaded yet; no network | availability | Y | Waits; tried again on open | Waiting, downloading or unavailable |
| 40 | Export | Folder not writable; an attachment unavailable | export error | Y | Stops with the reason; lists what it could not fetch | The message and the list |
| 41 | Intents | Live Activities off; permission missing | none | Y | The intent opens the app | Knot opens |
| 42 | | The saved recording state is stale | none | Y | The orphan is recovered; nothing starts | A recovered segment |
| 43 | Hotkey | The key is taken by another app | registration error | Y | Not registered | Settings asks for another key |
| 44 | | A release never arrives | none | Y | A stop control; the key is checked each second | The panel with stop |
| 45 | `knot` and MCP | Access off; store missing, locked or newer; unknown ID | exit codes | Pending | The DX review fixes the codes | An error on standard error |
| 46 | Launch | One step fails | step error | Y | Logged with its code; the next step runs | Depends on the step |

46 rows. 14 were gaps before this review (rows 4, 5, 16, 19, 20, 21, 27, 29, 33, 36, 42, 43, 44 and 46), and all are closed by amendments. Row 45 is pending with the DX review.

#### Failure Modes Registry

| Codepath | Failure mode | Rescued? | Test? | The user sees | Logged? |
|---|---|---|---|---|---|
| Record a capture | Store busy, full or failing | Y | Y: WP-10 contract suite, two processes | A failed marker, then the segment | Y |
| Store open | Damaged, newer, failed migration | Y | Y: WP-10 and WP-22 | The stream says so; capture works | Y |
| Draft save | A late save over newer text | Y | Y: WP-11, paused saves | Nothing | Y |
| Recording | Process killed | Y | Y: WP-12 kill test, the soak | A recovered segment | Y |
| Recording | Conversion fails | Y | Y: WP-12 | Nothing | Y |
| Recording start | No permission, no input, busy, no space | Y | Y: WP-12, WP-19 | The reason | Y |
| Transcription | Model missing; interrupted | Y | Y: WP-13, WP-15 | Pending | Y |
| Cleanup | Refusal, malformed, guard rejection, not ready | Y | Y: WP-14 | The raw transcript | Y |
| Queue | An edit or a delete while a job runs | Y | Y: WP-15 | The user's text stays | Y |
| Inbox | An unreadable item | Y | Y: WP-15 | A failed segment | Y |
| Watch link | Loss, duplicate, reorder, lost acknowledgement, checksum | Y | Y: WP-17 | Waiting, on the watch | Y |
| Sync | Conflict, zone removed, account change, unknown kind | Y | Y: WP-16 | A conflict copy; a question | Y |
| Hotkey | Missed release; key taken | Y | Y: WP-33 | A stop control; a message | Y |
| Intents | Stale recording state | Y | Y: WP-12, WP-19 | A recovered segment | Y |
| Launch | A step fails | Y | Y: WP-22 | Depends on the step | Y |
| `knot` and MCP | Bad input, locked store, access off | Pending | Pending: DX review | An error message | Pending |
| Real CloudKit, real WatchConnectivity, a locked iPhone | Behaviour differs from the fakes | Unknown | Hardware only: SP-1, SP-2, SP-4, M2 to M4 | Unknown until the spikes report | Not applicable |

17 rows. Critical gaps after amendments: 0. Three paths were silent before this review and are closed: the unreadable inbox item, the zone removed from iCloud, and the missed hotkey release. The last row is the open risk, and the spikes exist for it.

#### Scope expansion decisions

The full record is the CEO scope summary on the build Mac, in gstack's folder for this project, as `ceo-plans/2026-11-19-knot-v1-rebuild.md`.

- Accepted: C1 to C7, C10 to C46, and X2.
- Deferred to TODOS.md: X1, X3, X4, X5, X6, X7, X8, X9.
- Pending: C8 (Eng review) and C9 (DX review).
- Rejected: the nine items listed under "NOT in scope".

#### Diagrams and the stale-diagram audit

Seven diagrams were produced: system architecture (Section 1), data flow with shadow paths (Section 4), state machines (below), error flow (below), deployment sequence and rollback (Section 9), and the user flow (Section 11).

```
 Capture:  open ──content stored──► stored
             │ ──empty──────────► discardedEmpty
             └ ──save fails─────► failed(code) ──a retry succeeds──► stored
           After recovery no row is open. stored and discardedEmpty are final.

 Job:      queued ──► running ──► done
              ▲          │ fails: one more attempt, back to queued after a delay
              └──────────┘ five attempts: failed; a manual retry returns it to queued
           running at launch ──► queued

 Hotkey:   idle ──key down──► waiting, 250 ms ──release──► TAP: show or hide the panel
                                   │ still held
                                   ▼
                          microphone opening ──live──► recording ──release──► stopped and saved
                                                           │ the release never arrives
                                                           ▼
                                             recording with a stop control ──Esc, hotkey, or key seen up──► stopped
           Not possible: a tap opening the microphone; a second key down starting a second recording.
```

```
 a capture cannot start ──► the reason shows where the user is: surface, Live Activity, watch or panel
 a save fails ──► a file in Inbox/ ──► a failed capture, visible ──► ingest or retry ──► stored
                      └ Inbox/ fails too ──► the surface stays open with the text
 a processing step fails ──► retry with a delay, five times ──► failed on the segment ──► manual retry
 the store will not open ──► nothing deleted ──► capture into Inbox/ ──► the stream explains ──► restore the copy, or a newer build
 a sync problem ──► status in Settings ──► the engine retries; zone removed or account changed ──► pause and ask
```

Audit of diagrams in the files this plan keeps: the segment state diagram in docs/architecture.md §4 is accurate. The one-writer diagram in §6 showed the `knot` command as a reader only, which was stale once it writes captures; it is corrected. The retired tree's diagrams leave with WP-00. Stale diagrams found: 1, fixed.

#### Implementation tasks

Synthesized from this review's findings. Each task derives from a finding above. The effort ratios assume features at about 30 times faster with CC, tests at about 50 times, and documents at about 5 times.

- [ ] **T1 (P1, human: ~6h / CC: ~1h)** · PLAN.md · Fold the amendments into the package sections and move the review record out
  - Surfaced by: Section 1, finding 1.4
  - Files: PLAN.md, docs/reviews/2026-11-19-plan-review.md
  - Verify: no amendment list remains in PLAN.md, and each package section states its start condition, its paths and its merge criteria
- [ ] **T2 (P1, human: ~3d / CC: ~2h)** · WP-02 · Name every registry failure in the error taxonomy, and write the append rule as ordered small rules for rules 1 to 15
  - Surfaced by: Sections 2 and 5, findings 5.1 and 5.2
  - Files: to be determined (Packages/KnotKit/Sources/KnotCore/)
  - Verify: `swift test`; one test table per rule, including a clock set back
- [ ] **T3 (P1, human: ~4d / CC: ~3h)** · WP-10 · Store safety: refuse a newer database, keep the pre-migration copy, record a capture under the write lock, one-query stream page, quoted search
  - Surfaced by: Sections 1, 4 and 7, findings 1.3 and 7.1
  - Files: to be determined (Packages/KnotKit/Sources/KnotStore/)
  - Verify: the named tests in docs/architecture.md §17 that belong to WP-10
- [ ] **T4 (P1, human: ~3d / CC: ~2h)** · WP-11, WP-22 · Capture into `Inbox/` when the store is unavailable; launch steps isolated and after the first frame
  - Surfaced by: Section 2, gaps 1 and 14; Section 7, finding 7.4
  - Files: to be determined (Sources/KnotCapture/Engine/, Sources/KnotApp/)
  - Verify: the "store that will not open" test; a launch-time test
- [ ] **T5 (P1, human: ~4d / CC: ~3h)** · WP-13, WP-15 · Transcription in ranges that continues after an interruption; unreadable inbox items; job states with a five-attempt limit
  - Surfaced by: Section 2, gaps 4, 7 and 8; Section 7, finding 7.2
  - Files: to be determined (Sources/KnotSpeech/, Sources/KnotCapture/Processing/, Sources/KnotCapture/Ingest/)
  - Verify: an interrupted job yields the same transcript as an uninterrupted one; edit and delete during a paused job
- [ ] **T6 (P1, human: ~3d / CC: ~2h)** · SP-4, WP-16 · Notes removed from iCloud; unknown kinds kept; the sync-layer question
  - Surfaced by: Section 2, gap 10; Section 9, risk 9.1; Claude 10
  - Files: docs/spikes/SP-4.md; to be determined (Sources/KnotSync/)
  - Verify: SP-4's report answers both questions; a record with an unknown kind round-trips untouched
- [ ] **T7 (P1, human: ~1d / CC: ~45min)** · WP-17 · Checksum mismatch: no acknowledgement, then ingest as failed
  - Surfaced by: Section 2, gap 9
  - Files: to be determined (Sources/KnotLink/)
  - Verify: a fake-transport test with three mismatches
- [ ] **T8 (P1, human: ~2d / CC: ~1.5h)** · WP-12 · Conversion failure, stale recording state, working-file size report
  - Surfaced by: Section 2, gaps 3 and 11; Section 7, finding 7.3
  - Files: to be determined (Sources/KnotAudio/)
  - Verify: the named tests; the proof-step report lists the size per minute on each platform
- [ ] **T9 (P1, human: ~3d / CC: ~2h)** · SP-3, WP-33 · Hotkey: microphone at the hold mark, a missed release, a taken key
  - Surfaced by: Section 2, gaps 12 and 13; Claude 8
  - Files: docs/spikes/SP-3.md; to be determined (Apps/macOS/)
  - Verify: SP-3 reports whether first words are clipped; state machine tests with the fake clock
- [ ] **T10 (P1, human: ~1d / CC: ~45min)** · WP-33, WP-34 · Command-line access, off until the owner turns it on
  - Surfaced by: Section 3, threat 3.1
  - Files: to be determined (Sources/KnotAgent/, Apps/macOS/)
  - Verify: the tool exits with the documented code while access is off
- [ ] **T11 (P2, human: ~2d / CC: ~1.5h)** · WP-22, WP-30, WP-33 · Diagnostics export; the capture ID on every log line
  - Surfaced by: Section 8, findings 8.1 and 8.2
  - Files: to be determined (Sources/KnotApp/, Apps/)
  - Verify: a test asserts the export holds no text field of any note
- [ ] **T12 (P2, human: ~1d / CC: ~1h)** · WP-43 · Troubleshooting guide, rollback steps, privacy text, M7 smoke rows
  - Surfaced by: Sections 3, 8 and 9
  - Files: to be determined (docs/)
  - Verify: one guide entry for each registry row that the user can see
- [ ] **T13 (P2, human: ~1d / CC: ~1h)** · WP-04 · Meaning-critical cleanup cases; checklist rows for M2, M3, M4 and M7
  - Surfaced by: Codex 6 and 8; Claude 1 and 6
  - Files: Fixtures/, docs/checklists/
  - Verify: the evaluation prints the meaning-critical cases as their own line
- [ ] **T14 (P2, human: ~2h / CC: ~20min)** · WP-40 · Write `DESIGN.md` from the handoff
  - Surfaced by: Section 11, finding 11.4
  - Files: DESIGN.md
  - Verify: `/design-review` finds it
- [ ] **T15 (P2, human: ~30min / CC: ~5min)** · WP-00 · The README says what happened to the Obsidian capture app
  - Surfaced by: Claude 7
  - Files: README.md
  - Verify: the README names the archive branch and the two tags
- [ ] **T16 (P3, human: ~1w / CC: ~4h)** · TODOS.md · Import an export; storage management for recordings
  - Surfaced by: Codex 11; Section 1, scaling
  - Files: to be determined
  - Verify: tracked in TODOS.md as X8 and X9

#### Reality check

The seven `REALITY:` lines are under 0B. The check on them printed:

`PLAN_REALITY: phase=ceo rows=7/7 missing=none unverified=8 verdict=complete`

#### Completion summary

```
  +====================================================================+
  |            MEGA PLAN REVIEW — COMPLETION SUMMARY                   |
  +====================================================================+
  | Mode selected        | SELECTIVE EXPANSION                         |
  | System Audit         | Clean tree; plan files untracked; one prior |
  |                      | rewrite; no TODOS.md before this review     |
  | Step 0               | 13 premises, 4 findings; 46 proposals;      |
  |                      | spec review: 3 launches, 55 issues          |
  | Section 1  (Arch)    | 4 issues found                              |
  | Section 2  (Errors)  | 46 error paths mapped, 14 GAPS, all closed  |
  | Section 3  (Security)| 6 issues found, 1 High severity             |
  | Section 4  (Data/UX) | 24 edge cases mapped, 6 unhandled, closed   |
  | Section 5  (Quality) | 2 issues found                              |
  | Section 6  (Tests)   | Diagram produced, 15 gaps, all named        |
  | Section 7  (Perf)    | 4 issues found                              |
  | Section 8  (Observ)  | 4 gaps found                                |
  | Section 9  (Deploy)  | 3 risks flagged                             |
  | Section 10 (Future)  | Reversibility: 4/5, debt items: 5           |
  | Section 11 (Design)  | 5 issues                                    |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (17 items)                          |
  | What already exists  | written                                     |
  | Dream state delta    | written                                     |
  | Error/rescue registry| 46 rows, 0 CRITICAL GAPS (3 found, closed)  |
  | Failure modes        | 17 total, 0 CRITICAL GAPS                   |
  | TODOS.md updates     | 8 items                                     |
  | Scope proposals      | 55 proposed, 45 accepted, 8 deferred,       |
  |                      | 2 pending                                   |
  | CEO plan             | written                                     |
  | Outside voice        | codex completed; Claude subagent completed  |
  | Lake Score           | 87/100 recommendations chose the complete   |
  |                      | option                                      |
  | Diagrams produced    | 7 (architecture, data flow, state machines, |
  |                      | error flow, deployment, rollback, user flow)|
  | Stale diagrams found | 1, fixed                                    |
  | Unresolved decisions | 7 (listed below)                            |
  | Reality rows         | 7/7 rows (PLAN_REALITY), 8 unverified       |
  +====================================================================+
```

#### Unresolved decisions

1. UC1, prove it before building all of it. Owner, final gate.
2. UC2, sync as core, and the paywall idea. Owner, final gate.
3. UC3, what happens to a note after capture. Owner, final gate.
4. UC4, a repair for a wrong grouping. Owner, final gate.
5. T18, the Pencil canvas on the iPhone Duo. Owner, final gate.
6. C8, the merge queue. Eng review.
7. C9 with T12, the CLI and MCP contract. DX review.

#### Decision ledger, continued

| ID and owner | Contract and evidence | Current | Proposed | Status | Exact approval and scope |
|---|---|---|---|---|---|
| UC1, final gate | Both voices; PLAN.md §5, D16 | Every platform is built before any is lived with | A trial of the alternatives, a premise sitting, a week of use at M2, a cut order | unresolved | None. The owner decides at the final gate. |
| UC2, final gate | Both voices; PLAN.md §1 and §11, D18 | Sync is optional and arrives at M4 | Sync as core, brought forward; the paywall settled | unresolved | None. The owner decides at the final gate. |
| UC3, final gate | Both voices; docs/product-spec.md §7, §8, D21 | A note has no state after capture | A "handled" mark and one tested path from capture to use | unresolved | None. The owner decides at the final gate. |
| UC4, final gate | Both voices; docs/product-spec.md §3, §15, D2 | A wrong grouping cannot be repaired | Move a segment out into its own note | unresolved | None. The owner decides at the final gate. |
| V1 to V7, V12 and V13, CEO voices | The "accepted now" list above | As the amended plan stood after 0I | The nine accepted items | approved | Auto-decisions 79 to 85, 90 and 91. Scope: the owner calendar, docs/product-spec.md §14 and §16, WP-04, SP-4, the M4 and M3 checklists, the README. |
| V8 to V11, V14 and V15, CEO voices | The taste list above | As the amended plan stood after 0I | Six taste decisions | approved | Auto-decisions 86 to 89, 92 and 93, taste. Surfaced at the final gate. |
| R1, Section 1 | Findings 1.1 to 1.4 | Unstated | docs/architecture.md §4, §7, §14; the record leaves PLAN.md | approved | Auto-decisions 94, 95 and 109. |
| R2, Section 2 | The 14 gaps | Unstated, three of them silent | Rules in docs/architecture.md, error cases, owners and tests | approved | Auto-decisions 96 to 98. C40 is the one that adds behaviour. |
| R3, Section 3 | Threats 3.1 to 3.6 | Unmitigated | Command-line access off by default, and five smaller rules | approved | Auto-decisions 99 and 100. |
| R4, Section 4 | Six unhandled edge cases | Unstated | Rule 15 with assumption A25, and five smaller rules | approved | Auto-decisions 101 and 102. Rule 15 is taste, and the owner confirms it with §16. |
| R5, Sections 5 and 6 | Findings 5.1, 5.2 and the 15 test gaps | Implied | Named in WP-02 and in docs/architecture.md §17 | approved | Auto-decisions 103 and 110. |
| R6, Sections 7 to 9 | Findings 7.1 to 7.4, 8.1 to 8.4, 9.1 to 9.3 | Unstated | Rules in docs/architecture.md; WP-43's guide; M7 smoke rows | approved | Auto-decisions 104 to 106. |
| R7, Sections 10 and 11 | Storage growth; findings 11.1 to 11.4 | Unstated | X9 deferred; the brief's states; `DESIGN.md` | approved | Auto-decisions 107 and 108. |

Approval readiness: PASS. Checked rows: C1 to C7 and C10 to C46, X1 to X9, S1.1 to S5.5, T1 to T20, U1 to U15, V1 to V15 and R1 to R7, each against its auto-decision number in the Decision Audit Trail (3 to 110). The plan applies only those scopes. Unresolved rows are kept out of accepted work: C8, C9 with S3.1 and T12, T18, and UC1 to UC4.

<!-- autoplan-accepted:ceo -->
- The items below amend the plan above. Where an item contradicts earlier text, the item wins. The earlier text is rewritten after the owner approves this review.
- A new package, WP-05 Capture tracer, runs after WP-02 and before wave 2. Its size is M. It owns `Sources/KnotCapture/` until it merges, and the preview environment in `Sources/KnotFakes/Preview/`. It builds the thinnest real `CaptureEngine` and `ProcessingQueue` and one end-to-end test. In that test a typed capture and a fixture recording go through the engine, the queue, the in-memory `NoteStore` and the scripted `Recorder`, `Transcriber` and `Cleaner`, and the assertions read the stream page that `NoteStore` publishes. WP-05 merges when four things hold: the end-to-end test passes in `swift test`; a capture row is written before any content, for typed and for voice; `.preview` runs the real engine and queue over the fakes on iOS and macOS; and every contract correction it found has merged as a contract PR. WP-11 and WP-15 then extend its two halves. The proof-first steps of WP-12, WP-13, WP-14 and WP-18, and all of WP-20, may run beside WP-05. Every other wave 2 package starts when WP-05 merges.
- The plan now has 30 work packages and about 50 PRs, before contract PRs and fix PRs. WP-02, WP-12 and WP-22 ship in two PRs each, and WP-19 in three: the text intents, then the recording intents for iPhone, iPad and Mac, then the watch intents. For WP-02 the first PR holds the domain types, the rules and the reducers, and the second holds the ports, the fakes and the contract suites. For WP-12 the first PR is the format proof and a recorder that records and stops on every platform, and the second is everything else. For WP-22 the first PR is the composition and the second is the end-to-end suite and the soak test.
- The test and preview code is three targets, replacing KnotTesting, and docs/architecture.md §3 lists them. KnotFakes holds the fakes, the fixture builders and the preview environment, imports no test framework, and is linked by debug builds of the apps only. KnotTestSupport holds the shared contract suites and is used by test targets only. KnotUIPreviews holds the SwiftUI previews. `AppEnvironment` is declared in KnotCore with an `.unavailable` value. The factory in KnotApp returns `.unavailable` from WP-01, `.preview` in debug builds from WP-05, and `.live` from the first PR of WP-22, with any port not yet implemented filled by the unavailable one. UI tests select `.preview` with a launch argument that only debug builds honour.
- WP-02 owns `Sources/KnotCore/`, `Sources/KnotFakes/` except its `Preview/` folder, and `Sources/KnotTestSupport/`. Its fake list adds `AssetStore`, `AudioPlayer`, `AssetFetcher`, `RecordingStateStore`, `RecordingActivity` and `SettingsStore`. `CaptureEngine` and `ProcessingQueue` are not faked. Its domain types add `Capture`, `closedAt` on `Note`, and `transcription` and `processingOwner` on `Segment`. Two operations are part of its contracts: `NoteStore` records a capture in one transaction, applying the append rule and writing the capture row and the segment, and `CaptureEngine` publishes the revision of the content that is durably saved. Its append-rule tests cover rules 9 to 15 of docs/product-spec.md §3, and the rule is written as an ordered list of small rules, first match wins, each with its own test table. Before WP-02 starts, the owner confirms the assumptions still open in docs/product-spec.md §16, because WP-02 turns them into tests.
- Every port has an implementer. WP-12 implements `Recorder`, `AudioPlayer` and `RecordingStateStore`. WP-10 implements `NoteStore` with the capture rows and the one-transaction capture operation, `AssetStore`, `SettingsStore` and the local-only `AssetFetcher`. WP-16 implements `SyncEngine` and the syncing `AssetFetcher`. WP-30 implements `RecordingActivity`, the app-side code of the Live Activity, and WP-31 owns its views. Each implementation passes the contract suite of its port. The `knot` command and the MCP server write through the same `NoteStore` operation as the engine, so the append rule runs in one place.
- WP-10, WP-11, WP-33 and WP-43 each gain a "Prior art" line naming archived code to read before writing. WP-10 reads `Packages/KnotKit/Sources/KnotKit/Persistence/`. WP-11 reads the draft checkpointing in `Knot/Shared/EditorModel.swift`. WP-33 reads `Knot/macOS/Hotkey/`, `Knot/macOS/SurfaceCoordinator.swift` and `Knot/macOS/MenuBarController.swift`. WP-43 reads `scripts/release.sh`. All are on the branch `archive/main-before-restart-2026-11-18`. Prior art is read, not copied: the old hotkey adapter registers press events only. Each PR description names what it read.
- Real recordings. WP-04 adds a read-aloud script of 10 short English passages with known text, and asks for 10 spontaneous voice notes. The owner records both with Apple's Voice Memos, on the iPhone and on the Watch, in wave 0, so that the proof steps of WP-13 and WP-14 run on them beside WP-05. He puts the files in the git-ignored folder `Fixtures/local/`, named `read-aloud-<number>-<device>.m4a` and `note-<number>-<device>.m4a`. An executable target `knot-eval`, declared by WP-01 and listed in docs/architecture.md §3, reads that folder. WP-13 owns `knot-eval speech`, which runs first, writes transcripts into the same folder and prints word error rate on the read-aloud set. WP-14 owns `knot-eval cleanup`, which then writes ten input and output pairs to a git-ignored file for the owner to read. Neither command prints text from the recordings, and nothing derived from them enters a commit, a PR, a log or a test. Examples shown in PRs stay synthetic. This is the one exemption from the synthetic-fixtures rule. The first thresholds are 10% word error rate on iPhone recordings and 12% on Watch recordings, both estimates. Voice Memos recordings measure the speech engine, not Knot's own recorder, so the M2 and M3 checklists each have a row where the owner reads three passages through Knot and compares the result by eye. WP-13 still merges on its synthetic criterion, and if a threshold is missed the owner decides what happens.
- Every voice segment records the engine, the locale and the OS build that produced its transcript, as `transcription` on `Segment` in docs/architecture.md §4. v1 has no re-transcription; that is deferred to TODOS.md.
- The capture ledger is rule 6 of docs/architecture.md §6, backed by a `capture` table whose rows `NoteStore` carries. WP-02 defines the `Capture` type, WP-10 stores it, and WP-05 writes the row as the first durable write of every capture. The second PR of WP-22 adds the soak test: 500 captures on the Mac from a fixed seed, mixing typed text, fixture recordings of at most two seconds and fixture drawings, with the scripted transcriber, cleaner and recogniser and an injected clock, finishing inside 3 minutes. The harness is a child process over the real store, killed at points the seed chooses from a named list, then relaunched. It asserts three things: no capture row is still open, every segment that originated on the device has a row, and every stored segment holds at least the revision the engine reported as saved. It runs under `scripts/verify.sh --soak`, at each milestone and in the merge gate of any PR that touches KnotStore, KnotCapture or KnotAudio. WP-17 proves the watch half with the fake transport: every manifest is still on the watch or acknowledged.
- Crash recovery covers all three kinds. A typed draft found at relaunch becomes a finished segment, a drawing found at relaunch goes on to recognition, and a recovered capture ends at its last durable write. The launch sequence in WP-22 gains a step that finishes drafts and drawings, beside the one that recovers recordings.
- "Done when" lists are merge criteria and hold only checks an agent can run. Lines that need the owner, hardware or the real iCloud service are milestone evidence. They close at the milestone, not at merge. This applies to the checklist lines of WP-16, WP-17, WP-18, WP-19, WP-30, WP-31, WP-32, WP-33, WP-34 and WP-35, to the restore time on real CloudKit in WP-16, to the owner's sign-off in WP-40 and to the VoiceOver flows in WP-41. `docs/status.md` gains a milestone-evidence column. A milestone build is made from `main` in a fresh worktree by the thread of the owning package:

  | Milestone | Owning package | Also needs |
  |---|---|---|
  | M1 | WP-22, PR 1 | WP-05; PR 1 of WP-10, WP-12, WP-21, WP-30, WP-32 and WP-33 |
  | M2 | WP-30 | WP-11; WP-13; WP-14; WP-15; WP-19, PR 2; WP-31; WP-22, PR 2; SP-1; the design direction |
  | M3 | WP-32 | WP-17; WP-19, PR 3; SP-2 |
  | M4 | WP-33 | WP-16; WP-34; SP-3; SP-4 |
  | M5 | WP-35 | WP-18; WP-16 |
  | M6 | WP-40 | WP-41; WP-42 |
  | M7 | WP-43 | WP-44 |

- M1 changes on the Watch: the owner records and sees the capture listed on the Watch as saved. Delivery to the iPhone moves to M3. M1 adds no playback on the Watch.
- Start conditions replace the "after" notes in the package headers and the chain in §6. "PR 1" and "PR 2" are a package's first and second PR, and a package named without a number means its last PR. A spike counts as finished when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names:

  | Package | PR 1 starts after | PR 2 starts after |
  |---|---|---|
  | WP-02 | WP-01 | Its own PR 1 |
  | WP-05 | WP-02 | |
  | WP-10 | WP-05 | SP-3 and SP-4, for the second-process rules and the sync columns |
  | WP-11 | WP-05 | |
  | WP-12 | WP-05, with its proof step beside WP-05 | Its own PR 1 |
  | WP-13, WP-14, WP-18 | WP-05, with their proof steps beside WP-05 | |
  | WP-15 | WP-05 | SP-1, for the background mechanism |
  | WP-19 | WP-05, for the text intents | SP-1, for the recording intents on iPhone, iPad and Mac. Its third PR, the watch intents, starts after SP-2 |
  | WP-20 | WP-02 | |
  | WP-21 | WP-05 | The design direction |
  | WP-22 | WP-05 and WP-10, PR 1 | PR 1 of WP-10 and WP-15; WP-11, WP-12, WP-13 and WP-14 |
  | WP-30 | WP-21, PR 1 | The design direction and WP-22, PR 2 |
  | WP-33 | WP-21, PR 1 | The design direction, WP-22, PR 2, and SP-3, for the hotkey and the panel |
  | WP-32 | PR 1 of WP-12 and WP-21 | SP-2, WP-17 and WP-19, PR 3 |
  | WP-31 | SP-1 and WP-19, PR 2 | |
  | WP-16 | WP-10, PR 2 | |
  | WP-17 | SP-2 | |
  | WP-34 | SP-3, WP-10, PR 2, and WP-20 | |
  | WP-35 | WP-30 and WP-18 | |

  The longest chain to M2 is WP-00, WP-01, WP-02, WP-05, WP-10 PR 1, WP-22, WP-30. A second chain also gates M2: WP-01, SP-1 with the owner's confirmation, then the second PRs of WP-15 and WP-19, then WP-31. A third is the design direction, which the second PR of WP-30 waits for. No chain to M2 waits for SP-2, SP-3 or SP-4. A package the table does not list keeps the start condition in its header. WP-22 builds the live environment for iOS, iPadOS and macOS only, and WP-32 composes the watch app.
- Path ownership has three exceptions to "a package owns its folders". `scripts/release.sh` belongs to WP-43, though the rest of `scripts/` passes to the orchestrator after WP-01. WP-35 owns `Apps/iOS/Ink/`, the canvas screens shared by the iPad and a Pencil-capable iPhone. WP-05 owns `Sources/KnotFakes/Preview/`.
- The design direction comes first. Right after the plan is approved, the owner runs the brief's direction step in Claude Design, described in docs/design/brief.md §9, and chooses a direction for the iPhone capture surface and the Mac panel. The orchestrator records the choice in `docs/design/direction.md`. The first PRs of WP-21, WP-30, WP-32 and WP-33 are skeletons that do not depend on it. The second PRs of WP-21, WP-30 and WP-33 wait for it. WP-32 and WP-35 build provisional structure for the watch and the iPad, which the full design round may change. WP-40a to WP-40d each start after their platform's app package has merged and own that platform's views from then on. M6 repeats the core rows of the M2 to M5 checklists after the design is applied.
- WP-00's archive commit also holds the nine untracked files whose names end in " 2", because six of them differ from their originals. Only generated products are removed without archiving: `Knot 2.xcodeproj`, `Knot 3.xcodeproj` and `build/`. WP-00 keeps `TODOS.md` in the new tree.
- Build flavours protect the owner's notes. Every build that is not a milestone build uses development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. That covers agent builds, PR builds, spikes and tests, and tests also pass the store path in. Appendix A gains a hard rule: only a milestone build opens the default store or the real iCloud container. Notes on the owner's iPhone and iPad are disposable until the M2 milestone build, and notes on his Mac until the M4 milestone build, which needs SP-3's answer on where the Mac store lives. After those builds, every change to the schema or to the store's location ships a tested migration.
- The risk table in §11 gains three rows. Hotkey press and release do not arrive in a sandboxed build: the fallback is a listen-only event tap, which needs the Input Monitoring permission, and SP-3 decides in wave 1. A development build writes into the owner's notes: the development identifiers and the Appendix A rule prevent it. The release Xcode cannot compile code written against the beta SDK: the availability rule applies, and the merge gate builds with the release Xcode.
- At G1 the owner decides whether milestone builds reuse the bundle ID `com.p3ob7o.knot`, which is the retired app's. The recommendation is a new identifier, so that the retired app keeps working beside milestone builds and no special-case code is needed. Reusing the old one gives the new app the old app's container and preferences. In that case v1 keeps everything under a new subfolder and a new defaults suite, refuses to open a database it did not create, and the M1 checklist starts with a row, for every device that had the old app, to empty its pending captures first. The Mac app-group identifier stays open until SP-3 reports. At G1 the owner also installs a release Xcode 27 beside the beta, and WP-01 records its version: it is the Xcode for the merge gate and for the archive.
- The owner's work is listed with expected minutes, replacing the table in §10. The gate IDs stay. A checklist longer than 20 rows is split into two sittings. After WP-04 merges, `docs/checklists/` belongs to the orchestrator. The total is about 16 hours across the build, including the repeat sittings. The orchestrator derives dates for the sittings from the cadence the owner names at G0.

  | Gate | When | What | Minutes |
  |---|---|---|---|
  | G0 | Now | Answer this review's gate, confirm the open assumptions in docs/product-spec.md §16, say how many sittings a week he can give, approve the plan | 30 |
  | G0 | Wave 0 | Approve the restart PR and the licence wording | 15 |
  | G2 | Wave 0 | Review the brief, run the Claude Design direction step, choose a direction | 60 |
  | G1 | With WP-01 | Confirm the identifiers, both the milestone set and the development set, and the bundle ID; install a release Xcode; pair the five devices for development builds | 60 |
  | G1 | With WP-01, if authorised | Create the App Store Connect record and an API key for one internal TestFlight upload of the SP-3 spike app | 20 |
  | G3 | After wave 1 | One spike sitting: SP-1 has 12 rows, and the SP-2 spike app runs its 30 transfers itself | 45 |
  | G3 | After wave 1 | Read the four spike reports and confirm their decisions | 20 |
  | G3 | With SP-4 | Sign two devices into iCloud for the sync spike | 10 |
  | G4 | Wave 0 | Record the read-aloud script and 10 spontaneous notes on two devices and move the files to the Mac | 30 |
  | G4 | Before the full design round | Read the guard's table and the ten cleanup pairs; choose full cleanup, punctuation only or off | 20 |
  | G2 | After the direction | Run the full Claude Design round and return the handoff | 90 |
  | G4 | M1 | Checklist | 15 |
  | G4 | M2 | Checklist in two sittings, with locked and unlocked rows for each trigger | 40 |
  | G4 | M3 | Checklist | 30 |
  | G4 | M4 | Checklist in two sittings: hotkey, CLI and MCP, two-device sync | 45 |
  | G4 | M5 | Checklist | 20 |
  | G4 | M6 | Checklist with the regression rows, and sign-off of the applied design | 90 |
  | G4 | M1 to M7 | Repeat sittings after fixes: three each for M2, M3 and M4, one each for the others | 15 each |
  | G4 | M1 to M7 | Free-form notes at the end of each milestone sitting, which the orchestrator turns into change requests | 10 each |
  | G5 | After M5 | Approve the CloudKit production schema, before the first TestFlight build that syncs | 5 |
  | G5 | M7 | Authorise the TestFlight upload, supply the API key if not already supplied, install over the development build on each device | 30 |

- The CloudKit production schema is deployed only after M5, when two-device sync and attachment sync have passed on hardware with development builds. This replaces any earlier timing. The M7 checklist has rows for installing the TestFlight build over a development build.
- The spikes answer more questions. SP-1: does cleanup with the on-device model finish in the background after a recording stops. SP-2: does Double Tap start a recording when Knot is not the app in front, and can a watch intent start one at all. SP-3: do hotkey press and release arrive in a sandboxed build, does the panel show over a full-screen app, with the listen-only event tap as the fallback, and are first words clipped when the microphone opens at the 250 ms mark; can the sandboxed tool write to a folder the user names, and if not, how does `knot export` deliver its output. SP-4: do the ownership, machine-text and deleted-note rules of docs/architecture.md §11 hold when two devices see the same segment, what happens when a device moves from CloudKit's development environment to production, what CKSyncEngine reports when the zone is removed from iCloud, and whether an existing sync layer over GRDB and CKSyncEngine, such as SQLiteData, meets those rules and at what dependency cost. Adding a dependency stays the owner's decision under D30. SP-3 runs on a sandboxed build signed for development. If the owner authorises it at the final gate, one internal TestFlight upload of the SP-3 spike app in wave 1 checks distribution signing early. Without that, the check waits for M7, the command-line result at M4 is provisional, and WP-34 builds the XPC fallback only if the M7 check fails.
- WP-01 states the availability rule: the deployment target is 27.0, an API that first shipped in 27.1 or later is guarded or raises the stated minimum, and code must compile with the release Xcode installed at G1. WP-01 also declares the targets KnotFakes, KnotTestSupport, KnotUIPreviews and `knot-eval`, creates the environment factory in KnotApp returning `.unavailable`, defines the development identifiers, gives `scripts/build-slot.sh` an exclusive slot for Mac UI tests, and adds `scripts/verify.sh --gate` and `--soak`. Its criterion about two worktrees changes: both run `--full` at once, with Mac UI tests queued on the one slot.
- The merge gate is `scripts/verify.sh --gate` on the orchestrator's Mac. It requires the on-device models and fails on a skipped model test, but it checks no accuracy threshold: thresholds belong to the package PRs that own them and to the milestones. The design of the merge queue for about 50 PRs is decided by the Eng review.
- docs/architecture.md §14 lists the intents per platform. iPhone and iPad have ToggleRecording, which starts a recording when idle and stops the one running, so the control that starts a recording also stops it. The Mac's StartRecording opens the panel recording, with a stop control. The Watch's StartRecording opens the watch app recording and calls the watch recorder, and the watch part of WP-19 waits for SP-2. Intents reach the environment through the App Intents dependency manager, which the app registers at launch, and the widget extension links KnotIntents for the types only. The note entity is not indexed, no intent that reads or picks a note runs on a locked device, and intents are tested against `.preview`.
- WP-33 lets a note be dragged out of the Mac main window, as docs/product-spec.md §8 describes: text into another app, a Markdown file into Finder, recordings and drawings left behind. It uses KnotExport for the Markdown. A UI test drags a note onto a text field, and the M4 checklist has a row for it.
- docs/design/brief.md §6 holds the states the spec requires and the brief lacked: recently deleted, sync status and the account-change prompt, attachments waiting or downloading, a failed segment with its retry, a recording being transcribed on another device, export of all notes, cleanup unavailable, no microphone connected on the Mac, a recording on the Mac started from Siri or Shortcuts, text that could not be saved, a recording that could not start, a watch capture not yet delivered, a recording that stopped at its limit, notes that could not be opened, export progress and its result, a hotkey that another app already uses, the command-line access switch, and the moment a held key waits for the microphone. The brief also asks where a lasting problem shows outside Settings, and sets touch targets at 44 points or more.
- On iOS and iPadOS the database lives in the app's own container, and only `Inbox/` and the recording state use the app group, as docs/architecture.md §7 states. WP-10 implements both locations.
- docs/architecture.md §11 fixes the sync default, who processes a recording, when a segment syncs, the precedence of machine text, titles, deletes, appends to a deleted note, and which settings sync. WP-16 implements those rules, and its two-replica simulation covers each one, including several segments added to a note that the other replica had deleted, which must land together in one new note.
- docs/product-spec.md §3 holds rules 9 to 15, §4.4 says what happens when a capture cannot start or cannot be saved, and §6 fixes the hotkey behaviour in a timeline table: the microphone opens at the 250 ms mark of a hold and never on a tap, and listening from key-down is the alternative if SP-3 measures clipped first words. A release that never arrives leaves a visible stop control, and a key another app already uses is refused in Settings. Hold-to-record is exempt from the one-second discard. WP-02 and WP-33 encode these rules. §16 marks each assumption as cheap or costly to change after WP-02, and gives a worked example for each costly one.
- The CLI and MCP contract is decided by the DX review before WP-34 starts: ID forms, `--since`, how a pending note is marked, exit codes, the MCP revision, export of recordings still on another device, how an agent learns that the store is stale because the Mac app is not running or sync is off, a settled state that tells an agent a note is finished, and a change cursor that counts store changes so that a late watch recording is not skipped. Three points are already fixed: the tool and the MCP server stay off until the owner turns on command-line access in Settings; their deletes are soft and nothing purges; and tool results mark note text as data, not as instructions.
- docs/product-spec.md §17 states the Watch gap as proven delivery and accuracy, not an absence of competitors.
- `TODOS.md` at the repo root holds the eight items this review deferred.
- Device installs. WP-01 adds `scripts/install.sh`, which installs a named build on every paired device with `devicectl` and names any device it could not reach. SP-1 and SP-2 each record the install procedure that worked on the iPhone and on the Watch, and the orchestrator corrects the script from those reports. A spike or milestone sitting starts when the script has reported success.
- WP-14's first PR states the fidelity guard's allowed differences as a table: letter case, punctuation, paragraph and list breaks, the removal of fillers, repeated words and abandoned starts, and the written form of a number. Any other difference is a changed word, and the guard rejects the result. The owner reads that table with the ten cleanup pairs.
- Failure behaviour is fixed in docs/architecture.md and each rule has an owner. WP-10: a store that cannot be opened is never deleted, a database newer than the build is refused untouched, and the newest pre-migration copy is kept until the following migration. WP-11 and WP-22: when the store is unavailable, captures go to `Inbox/` and the stream says what is wrong. WP-15: an unreadable inbox item becomes a failed segment that keeps its file, manifests carry a version, jobs have four named states and fail after five attempts, an interrupted transcription continues from its last saved range, and a recording with no recognised words is ready with empty text. WP-17: a file whose checksum does not match is not acknowledged, and on the third mismatch it is ingested as failed and kept. WP-16: when the zone is removed from iCloud the local notes stay, sync pauses and Knot asks before uploading; a record kind or field the build does not know is kept and saved back untouched. WP-12: a failed conversion keeps the working file as the recording, a stale recording state never starts a second recording, a small array of level peaks is stored beside each recording, and the proof step reports the working file's size per minute on each platform. WP-14: cleanup waits when the model is not ready, and treats a refusal, an empty or malformed result and a guard rejection alike. WP-22: the capture surface is on screen before the launch steps run, and a failed step never blocks the next.
- WP-02's error taxonomy names each of those failures by case, as docs/architecture.md §5 lists them, and no port throws an untyped error.
- These failure tests are required by name, as docs/architecture.md §17 lists them: two processes recording captures at once and a store that will not open (WP-10); a late draft save that must not replace newer text (WP-11); an edit during a paused clean job, a delete during a job, an interrupted transcription and an unreadable inbox item (WP-15); a checksum mismatch (WP-17); a zone removed from iCloud and a record of an unknown kind (WP-16); a hotkey release that never arrives (WP-33); search text full of query syntax and a database newer than the build (WP-10); a clock moved backwards (WP-02); a press while the saved recording state is stale (WP-12).
- Performance rules for WP-10: a stream page is one query, every query in the `NoteStore` contract has an index, and a test shows each query plan.
- Security rules. The `knot` tool and the MCP server refuse to run until command-line access is turned on in Settings, and WP-33 and WP-34 build that switch. Knot's URL scheme only navigates and never writes text or starts a recording. Search text never reaches the full-text index as raw query syntax. A generated title is one line of plain text of at most 60 characters. WP-43's privacy text says exactly what iCloud encrypts end to end.
- Diagnostics. Test builds export a diagnostics file from About: capture rows, job rows, counts, signpost timings, the build and the OS, with no note text, titles or content-derived names. WP-22 builds the exporter and WP-30 and WP-33 the entry in About. Every log line about a capture carries the capture ID. The M2 and M4 checklists record the latencies it reports.
- WP-43 adds a troubleshooting guide with one entry for each failure this review lists, and the steps to roll a build back. The M7 checklist has five smoke rows: type, record, search, sync, and the install over a development build.
- The M4 checklist begins with one row: a note captured on the iPhone is read and filed by an agent on the Mac through `knot` or the MCP server.
- docs/product-spec.md §14 gains a Watch target, 60 seconds from the stop of a 30-second recording to its transcript on the iPhone with the phone nearby. It is an estimate that SP-2 calibrates, and the M3 checklist measures it.
- WP-04's cleanup evaluation set includes at least ten meaning-critical cases: negations, amounts, dates, names and spoken self-corrections. The evaluation reports them separately. One changed meaning among them sends the cleanup default to the owner's decision.
- Backups. The store and its files are never excluded from device backups or Time Machine, and WP-10 tests that a store folder copied elsewhere opens with every note and file. Importing an export is deferred to TODOS.md.
- WP-00's README says what happened to the Obsidian capture app and where its code and its tags live.
- WP-40 writes `DESIGN.md` at the repo root from the handoff, as the reference for the design reviews that follow.
- Appendix A gains two rules. A PR that changes the cleanup instructions, the guard or the speech settings reruns the cleanup evaluation and `knot-eval` and states the results before and after. Every log line about a capture carries its capture ID.
- After approval, this review's record moves to `docs/reviews/2026-11-19-plan-review.md`, and PLAN.md holds the plan only.
<!-- /autoplan-accepted:ceo -->

### Phase 2: Design review

Methodology read in full: `.gstack/tmp/autoplan/autoplan-design-methodology-wwiSkG/methodology.md`, lines 1-600, 601-1200 and 1201-1576 of 1576.

#### Step 0: design scope

- UI scope: four apps, and the surfaces outside them (Live Activity, Dynamic Island, controls, widgets, complications, the menu bar). The visual design is open by decision D13 and comes from Claude Design. This review covers the decisions the plan and the brief make or leave open, and what code built before the design arrives will assume.
- Initial rating: 6 out of 10. Behaviour is specified to the millisecond and the brief lists states at length. What is missing sits between the two: the interaction contracts that view models encode (how a note is edited, what "pending" means to the user, how Pencil and typing share a surface, what the Mac panel does with focus), and the path from the handoff into code.
- A 10 for this plan: every surface has a cell in a state matrix; every interaction contract that code encodes is fixed or handed to the direction step by name; the handoff has acceptance criteria and a rule for where it meets system components; and accessibility is specified as behaviour, per flow.
- DESIGN.md: none. By D13 the design system comes from Claude Design, so `/design-consultation` is not recommended. WP-40 writes `DESIGN.md` from the handoff.
- Existing design to reuse: the mark, the system's own components and materials (D31), and the retired handoff folder as an example of the format Claude Design returns.
- Focus: all seven passes (auto-decision).
- Mockups: gstack's designer is available (`DESIGN_READY`), and no mockups were generated. The owner chose Claude Design as the visual source, and the brief's direction step already gives him two or three directions to choose from. A taste decision, kept for the final gate.
- No earlier design review, no `/office-hours` design doc and no prior learnings exist for this repository.

#### Design dual voices

Both voices read `.gstack/tmp/autoplan/autoplan-design-nUaBfo/design-implementation.md`, SHA-256 `2af6dec2e9ba3dc840e4da618ac99942b27f82c1c2e514d3b6a97049538eb1f0`, the implementation plan with the CEO amendments applied. Only Codex was given the CEO findings; the Claude subagent stayed independent. Their full reports are saved as `.gstack/tmp/autoplan/design-voice-claude.md` and `design-voice-codex.md`.

**CODEX SAYS (design, UX challenge).** Completed with `gpt-6-astra`, VERDICT: FINDINGS. Seven high and two medium:

1. High. Choosing a visual direction does not approve the interaction model, and the watch and the iPad proceed on provisional structure.
2. High. The note shown in the capture surface can differ from the one chosen at the first keystroke, and a wrong grouping cannot be repaired.
3. High. "Pending" hides the difference between safe, usable and stuck.
4. Medium. A late Watch capture is placed correctly and is then hard to find.
5. High. "Reads as one page" has no editing contract behind it: selection, undo, moving between segments.
6. High. Layouts are per device, but nothing says what happens when a layout does not fit.
7. High. Pencil input has a promise and no gesture contract.
8. High. Accessibility has measurable visual rules and no interaction rules: focus order, announcements while recording.
9. Medium. A failed start on a locked phone relies on a surface that can be turned off.

**CLAUDE SUBAGENT (design, independent review).** Completed, and its INPUT line matched the snapshot hash. One critical, five high and eight medium:

1. Critical. A capture can join the wrong note, unseen, and cannot be moved. Four entry points have no "New note" action although rule 4 promises one everywhere.
2. High. The note's editing model is undecided, and WP-21 builds it before the design exists.
3. High. The direction and the handoff have no defined content and no acceptance step.
4. High. WP-40 is planned as restyling while the brief leaves layout and navigation open, and nothing says who wins when a mock and a system component differ.
5. High. On the Mac, recording needs a sustained hold, and the panel's focus and leaving are undefined.
6. High. On the iPad, the Pencil rule collides with the system's handwriting input, one key press ends a drawing, and the first frame is undefined.
7. Medium. Nineteen states are still missing, and the brief's lists should be a matrix.
8. Medium. The stream row and the title have no content rules.
9. Medium. A late capture arrives unannounced.
10. Medium. On iPhone, finding a note always starts behind capture.
11. Medium. Eyes-free capture has no feedback contract.
12. Medium. Accessibility is verified last.
13. Medium. First run needs setup that the product says it does not have.
14. Medium. The UI packages are described as lists of nouns.

```
DESIGN OUTSIDE VOICES — LITMUS SCORECARD:
═══════════════════════════════════════════════════════════════════════
  Check                                    Claude     Codex       Consensus
  ───────────────────────────────────────  ─────────  ──────────  ──────────
  1. Brand unmistakable in first screen?   not asked  NOT SPEC'D  NOT SPEC'D
  2. One strong visual anchor?             not asked  NOT SPEC'D  NOT SPEC'D
  3. Scannable by headlines only?          not asked  NOT SPEC'D  NOT SPEC'D
  4. Each section has one job?             not asked  NOT SPEC'D  NOT SPEC'D
  5. Cards actually necessary?             not asked  NO          one voice
  6. Motion improves hierarchy?            not asked  YES         one voice
  7. Premium without decorative shadows?   not asked  NOT SPEC'D  NOT SPEC'D
  ───────────────────────────────────────  ─────────  ──────────  ──────────
  Hard rejections triggered:               none       none        none
═══════════════════════════════════════════════════════════════════════
```

The native prompt asks five other questions, so the Claude column holds no litmus answers and no row is CONFIRMED. That is expected for a plan with no visual design yet. Nothing here is a hard rejection.

Where the two voices agree, on seven points: the editing model, what the direction step must settle, the Pencil rules, the late capture, accessibility as behaviour, what happens when a layout does not fit, and the wrong-note problem. The last one is UC4 from the CEO phase. Four reviewers have now raised it independently, and it stays the owner's decision.

#### Pass 1: information architecture. 6 → 8

```
 iPhone (structure only; the direction step arranges it)
 ┌─────────────────────────┐   first:  the capture field, focused, keyboard up
 │ the note being added to │   second: the note this capture will join, while the window is open
 │ [capture field]   (mic) │   third:  the way to the stream and to search
 │ New note                │
 └─────────────────────────┘
        │ stream, or the Search control
        ▼
 ┌─────────────────────────┐
 │ search                  │
 │ title or first line · time
 │ preview of the latest segment · kinds · pending or failed
 └─────────────────────────┘
        │ open a note
        ▼
 ┌─────────────────────────┐
 │ title, if there is one  │
 │ segment                 │
 │ segment, voice  ▶       │
 │ [capture field]         │   the field is the last element of every open note
 └─────────────────────────┘

 iPad:       two columns when they fit: stream | open note with its capture field. Otherwise the iPhone structure.
 Mac panel:  capture field · the note being added to · New note · microphone.   Mac window: stream | open note.
 Watch:      one control, record or stop  →  recent captures.
```

- 1.1. Rule 4 promised "New note" on every capture surface, and four entry points have none. The rule now says where the action is, and those four surfaces show whether a recording continues a note or starts a new one, without text. Moving a capture afterwards stays with UC4.
- 1.2. The note shown in the capture surface could differ from the one a capture joins. The display now follows the window, and the destination is fixed at the first keystroke.
- 1.3. The stream row had five elements and no rule for which gives way. docs/product-spec.md §7 now has one, and says what a row with no text shows.
- 1.4. Finding an old note always started behind capture. A Search control, widget target and Shortcuts action open the stream with search focused.
- 1.5. The iPad had no first frame, and the Mac's menu bar icon both toggled the panel and offered a menu. Both are fixed: the iPad opens on the capture surface, and a click on the icon opens the menu.
- Still open, by design: how the stream and the capture field relate on iPhone. That is the brief's first question, and the direction step answers it, scored on three tasks counted in actions.

#### Pass 2: interaction state coverage. 7 → 9

The brief listed states by device, and several existed for one device only. It now ends with a state matrix of 47 rows by six surfaces, where each cell is designed, inherits from a named surface, or does not apply. Nineteen states were added.

- 2.1. "Pending" covered three different situations. docs/product-spec.md §5 now names six states of a voice segment by what the user can do: saved on the Watch; saved, text on its way; saved, text being made elsewhere; ready; needs you; kept, no text.
- 2.2. A failure that no retry can fix had no final state, so failed markers would pile up. "Kept, no text" is that state.
- 2.3. The matrix is made checkable: WP-21 adds one named preview per designed cell, a test fails when a cell has none, and WP-40's screenshots come from those previews. That also answers how every state gets rendered for the side-by-side comparison.
- Remaining: the cells are named, not yet designed. That is the design round's job.

#### Pass 3: user journey and emotional arc. 6 → 8

| Step | The user does | The user feels | The plan specifies |
|---|---|---|---|
| 1 | A thought arrives mid-task. He presses the Action Button, holds the hotkey or taps the wrist. | Urgency, and fear of losing it | Entry points per device (spec §6) and speed targets (§14) |
| 2 | Waits for a sign | A beat of doubt: is it listening? | Now: the cues of spec §4.5. Before: start and stop on two devices only. |
| 3 | Speaks, or types | Flow | Live text where a screen shows; typed text saved within 150 ms |
| 4 | Stops | Relief, if he trusts it | The saved cue; the Live Activity's finished state |
| 5 | Wonders where it went | Mild doubt | Now: "continues a note" or "new note", shown without text |
| 6 | Later sees a cleaned, titled note | A small delight | Pending becoming ready; the title rule |
| 7 | Next day, looks for it | Trust, or betrayal | Search; stream order; the arrival mark for late captures |
| 8 | Something failed | Annoyance, then calm if told | The reason at once; a retry; "kept, no text" as a calm end |

- Five seconds: the cue that Knot is listening. Five minutes: capture, then find the note. Five years: an archive he trusts.
- 3.1. A late Watch recording arrived with no sign. `Segment` gains a local `arrivedAt`, the stream marks such captures until their note is opened, and it says once that they arrived.
- 3.2. Eyes-free capture had cues for two events on two devices. Spec §4.5 lists six events on three devices.
- 3.3. A failed start on a locked phone relied on the Live Activity, which can be off. SP-1's report now includes the feedback flow for each entry state, and the brief asks for both branches.
- 3.4. First run. Sync is on by default and nothing said so. The first-run stream now says it, and may carry three dismissible setup rows. The rows are a taste decision.
- Not fixed here: a capture that joined the wrong note still cannot be moved. That keeps this pass below 10 until the owner rules on UC4.

#### Pass 4: generic-interface risk. 7 → 8

Classifier: every Knot surface is an app surface where the user finishes a task, so the app rules apply. No hard rejection applies: nothing specifies cards, a hero or decoration, and the brief asks for a page, not a form or a chat.

My own litmus answers, from the plan and the brief: brand in the first screen, not specified; one visual anchor, yes in intent (the capture field is the anchor on every device); scannable by headlines, does not apply; one job per section, yes ("one primary action per surface"); cards necessary, no; motion improves hierarchy, yes ("motion explains a change of state, or it is not there"); premium without shadows, not specified.

- 4.1. The UI packages named things without content: "widgets", "complications in every family", "settings forms". Each launcher now has a rule for what it shows idle, recording and with captures waiting, and each UI package builds named cells of the matrix.
- 4.2. The methodology's rule against a system font as the main typeface is written for the web. For a native app whose owner wants it to belong to its operating system, the system font is the right default, and the brief already allows a custom face with an open licence. Kept as it is. A taste decision.
- Remaining: until WP-40 lands, the apps wear the system's default look. That is the system's look, not a generic one, and it goes when the handoff does.

#### Pass 5: design system alignment. 4 → 7

No `DESIGN.md` exists, so this pass rates the plan's own tokens and components. WP-21 names its components, and the brief asks for tokens as CSS variables and JSON. Nothing said how they map to SwiftUI, or what happens where the mock and the system disagree.

- 5.1. Three rules now govern the mapping: the system component wins over the mock's pixels; type maps to Dynamic Type text styles, colour to roles and materials to system materials; and controls, complications, widgets and the Live Activity take content from the handoff and rendering from the system.
- 5.2. WP-40 was planned as restyling, yet the brief leaves layout and navigation open. Structural differences are now listed in `docs/design/deltas.md` and assigned, and WP-40's ownership extends to the view models they touch.
- 5.3. The handoff had no acceptance step. The orchestrator now checks it against the matrix before WP-40 starts.
- It stays at 7 until the handoff exists and `DESIGN.md` is written. That is the order D13 sets.

#### Pass 6: responsive behaviour and accessibility. 5 → 8

- 6.1. Nothing said what a layout does when it does not fit. The iPad uses the iPhone layout when two columns do not fit, and the brief asks for narrow-width, keyboard-up and largest-text versions.
- 6.2. Accessibility was a list of visual rules. Spec §13 now has behaviour: VoiceOver announces the start and stop of a recording and stays silent while it runs, new text never moves focus, focus returns when a surface closes, and every segment action is reachable from the keyboard.
- 6.3. Accessibility was verified last, in WP-41. Each capture path now has a VoiceOver row at its milestone, and the handoff is accepted only with the largest text size shown.
- 6.4. On the Mac the only way to record was to hold a key for the whole recording. The panel and the main window gain a microphone control. It adds a control to a surface the owner wants minimal, so it is a taste decision for the final gate.
- 6.5. On the iPad, the Pencil would write into a focused text field as typed text, and one key press would end a drawing. On the capture surface the Pencil now always draws, and a drawing never ends by accident. How typing and Pencil share the surface stays the brief's seventh question.

#### Pass 7: unresolved design decisions

| Decision needed | If deferred |
|---|---|
| How the stream and the capture field relate on iPhone (brief question 1) | The second PR of WP-30 cannot start. The direction step decides. |
| Moving a capture that joined the wrong note (UC4) | A wrong grouping is permanent, and rule 4 holds on two surfaces only. |
| What ends a drawing, and how typing and Pencil share a surface (brief question 7) | WP-35 would invent it. It now waits for the iPad's structure sheet. |
| When the Mac panel leaves after a hold (brief question 4) | An implementer picks a number of seconds. |
| Where a lasting problem shows outside Settings (brief question 8) | Sync can be stuck for days unseen. |
| A microphone control in the Mac panel (taste) | Recording on the Mac needs a sustained hold. |
| Setup rows in the first-run stream (taste) | The best entry points stay undiscovered. |
| Whether a finished drawing can be reopened (taste, A28) | Decided as no for v1; reopening is in TODOS.md. |

Resolved in this phase: 22 decisions, listed as rows 111 to 132 of the Decision Audit Trail. Left for the owner or the design round: the eight rows above.

#### NOT in scope, design

Deferred, with entries in TODOS.md:

- Reopening a finished drawing. It needs a sync rule for two edits of one file.
- Stopping a recording that hears no speech. A false stop would lose what is said next.

Decided against, with no TODO:

- Mockups from gstack's designer. Claude Design is the visual source (D13).
- Selecting text across segments. It needs the rich-text editor D20 rules out.
- A second full design round. Gaps in the handoff go back as a list.
- Requiring a custom typeface. The system font is the default.

#### What already exists, design

The mark, in `Resources/Brand/` after WP-00. The system's components, materials and Dynamic Type, which D31 asks the app to use fully. The retired handoff folder on the archive branch, as an example of the bundle Claude Design returns. The brief, now with a state matrix.

#### Implementation tasks, design

Synthesized from this review's findings. Effort ratios as in the CEO list.

- [ ] **T1 (P1, human: ~1d / CC: ~45min)** · WP-02 · Add the local `arrivedAt`, the title rule, and no transition that reopens a drawing
  - Surfaced by: Pass 3, finding 3.1; Pass 1, finding 1.3; the Claude voice, finding 6
  - Files: to be determined (Packages/KnotKit/Sources/KnotCore/)
  - Verify: reducer tests reject a ready drawing going back to drawing; a title is proposed only when the first segment is a recording
- [ ] **T2 (P1, human: ~1w / CC: ~4h)** · WP-21 · One named preview per designed cell of the state matrix, with a test that fails on a missing one; the six user-facing voice states; the row rules; focus and announcements
  - Surfaced by: Pass 2, findings 2.1 to 2.3; Pass 6, finding 6.2
  - Files: to be determined (Sources/KnotUI/, Sources/KnotUIPreviews/)
  - Verify: the matrix test passes; view-model tests for each of the six states
- [ ] **T3 (P1, human: ~3h / CC: ~30min)** · Orchestrator · Write `docs/design/direction.md` with four structure sheets; check the handoff against the matrix; keep `docs/design/deltas.md`
  - Surfaced by: Pass 5, findings 5.2 and 5.3; both voices on the direction step
  - Files: docs/design/direction.md, docs/design/deltas.md
  - Verify: each second PR of a UI package cites the sheet it built from
- [ ] **T4 (P1, human: ~3d / CC: ~2h)** · WP-33 · Panel focus and leaving, the display it opens on, the menu on a click, the microphone control
  - Surfaced by: the Claude voice, finding 5; Pass 6, finding 6.4
  - Files: to be determined (Apps/macOS/)
  - Verify: the state machine tests cover a tap taking the keyboard and a hold not taking it
- [ ] **T5 (P1, human: ~3d / CC: ~2h)** · WP-35 · Pencil always draws on the capture surface; a drawing never ends by accident; the iPhone layout when two columns do not fit
  - Surfaced by: Pass 6, findings 6.1 and 6.5
  - Files: to be determined (Apps/iOS/iPad/, Apps/iOS/Ink/)
  - Verify: UI tests at a narrow width and with one stray key press during a drawing
- [ ] **T6 (P2, human: ~2d / CC: ~1.5h)** · WP-19, WP-31 · The Search action, control and widget target; launcher states without text; "continues a note" or "new note" on the Live Activity
  - Surfaced by: Pass 1, findings 1.1 and 1.4; Pass 4, finding 4.1
  - Files: to be determined (Sources/KnotIntents/, Apps/Extensions/Widgets-iOS/)
  - Verify: intent tests on `.preview`; widget previews for each state
- [ ] **T7 (P2, human: ~2d / CC: ~1.5h)** · WP-12, WP-30, WP-32, WP-33 · The cues of spec §4.5 on each device
  - Surfaced by: Pass 3, finding 3.2
  - Files: to be determined
  - Verify: one checklist row per event and device at M2, M3 and M4
- [ ] **T8 (P2, human: ~2h / CC: ~20min)** · WP-04 · A VoiceOver row per capture path in the M2 to M5 checklists
  - Surfaced by: Pass 6, finding 6.3
  - Files: docs/checklists/
  - Verify: each of the four checklists has the row
- [ ] **T9 (P2, human: ~1d / CC: ~1h)** · WP-30, WP-33 · The arrival mark and line; the first-run stream
  - Surfaced by: Pass 3, findings 3.1 and 3.4
  - Files: to be determined (Apps/iOS/, Apps/macOS/)
  - Verify: UI tests with a late capture injected through `.preview`
- [ ] **T10 (P3, human: ~1w / CC: ~4h)** · TODOS.md · Reopen a finished drawing; stop a recording that hears no speech
  - Surfaced by: the Claude voice, findings 6 and 11
  - Files: to be determined
  - Verify: tracked in TODOS.md

#### Design review completion summary

```
  +====================================================================+
  |         DESIGN PLAN REVIEW — COMPLETION SUMMARY                    |
  +====================================================================+
  | System Audit         | No DESIGN.md; UI on four devices and the    |
  |                      | surfaces outside the apps                   |
  | Step 0               | 6/10; all seven passes                      |
  | Pass 1  (Info Arch)  | 6/10 → 8/10 after fixes                     |
  | Pass 2  (States)     | 7/10 → 9/10 after fixes                     |
  | Pass 3  (Journey)    | 6/10 → 8/10 after fixes                     |
  | Pass 4  (AI Slop)    | 7/10 → 8/10 after fixes                     |
  | Pass 5  (Design Sys) | 4/10 → 7/10 after fixes                     |
  | Pass 6  (Responsive) | 5/10 → 8/10 after fixes                     |
  | Pass 7  (Decisions)  | 22 resolved, 8 deferred                     |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (6 items)                           |
  | What already exists  | written                                     |
  | TODOS.md updates     | 2 items                                     |
  | Approved Mockups     | 0 generated, 0 approved                     |
  | Decisions made       | 22 added to plan                            |
  | Decisions deferred   | 8 (listed in Pass 7)                        |
  | Overall design score | 4/10 → 7/10                                 |
  +====================================================================+
```

Pass 5 holds the overall score at 7: the design system cannot exist before the handoff. Every other pass is at 8 or above. After the build, `/design-review` and `/ios-design-review` check the rendered apps.

<!-- autoplan-accepted:design -->
- These items come from the design review. They add to the items above, and where one of them contradicts an earlier item, the later one wins.
- The editing model is fixed in docs/product-spec.md §7, as assumption A27. A note is a stack of segments, each edited on its own. A selection does not cross from one segment into the next, and undo covers the segment being edited. New text enters through the capture field, which is the last element of every open note. With the append window open, the capture surface is that note with its field focused, so WP-21 builds one view model for the note and for capture. The design may propose another model in the direction step, and the owner must accept it before code depends on it.
- WP-02 adds three things to its contracts: a local `arrivedAt` on `Segment` that does not sync; the rule that a title is generated only when a note's first segment is a recording; and an ink state machine with no transition from ready back to drawing, because a finished drawing is not reopened in v1 (assumption A28). Its reducer tests reject that transition.
- Rule 4 of docs/product-spec.md §3 now says where "New note" is: the iPhone and iPad capture surface, the Mac panel and an open note. A capture started from the Action Button, a control, the Watch or a held key follows the window. The Live Activity, the Watch and the Mac panel during a hold show whether a recording continues a note or starts a new one, without any text from the note. WP-31, WP-32 and WP-33 build that indicator.
- docs/product-spec.md §4.1 fixes what the capture surface shows: the note a capture would join, following the window, with the destination fixed at the first keystroke. WP-11 and WP-21 implement it, and a view-model test covers the window running out while the field is empty.
- docs/product-spec.md §4.5 lists the cue for each of six events on each device. WP-12, WP-30, WP-32 and WP-33 implement them, and the M2, M3 and M4 checklists have one row per event and device. Until the "live" cue, nothing implies that Knot is recording.
- docs/product-spec.md §5 names six states of a voice segment by what the user can do: saved on the Watch; saved, text on its way; saved, text being made elsewhere; ready; needs you; kept, no text. WP-21 maps every internal state to one of the six, with a view-model test for each. Retry on another device is labelled as moving the work to this device.
- The stream row follows docs/product-spec.md §7: its preview is the latest segment's text; a note with no text says what it holds; at large text sizes the preview gives way first, then the kinds; the title or first line, the time and a failed marker always stay. A late capture is marked as arrived until its note is opened, and the stream says once that captures arrived. WP-21, WP-30 and WP-33 build this, with a UI test that injects a late capture through `.preview`.
- The state matrix. docs/design/brief.md §6 ends with a matrix of 47 states by six surfaces. WP-21 adds one named preview in KnotUIPreviews for every cell marked as designed, and a test fails when a cell has none. WP-40's side-by-side screenshots are rendered from those previews. Each UI package's build list names the cells it implements.
- The direction. `docs/design/direction.md` holds the answers to the brief's questions 1, 2 and 4, a structure sheet for the capture surface of each of the four devices, a link to the chosen prototype, and what stays open. The direction step scores each direction on three tasks counted in actions: capture a new thought, continue the last note, find an old one. The second PRs of WP-21, WP-30, WP-32 and WP-33, and all of WP-35, build from the sheets. This replaces the provisional structure for the watch and the iPad, so the second PR of WP-32 and the whole of WP-35 also wait for the design direction.
- The brief asks for both branches of the three surfaces a spike still decides: a recording from a locked iPhone or only after Face ID; a Watch start with or without the app in front; and the Mac's first run with or without a permission prompt for the hotkey. The full design round therefore does not wait for the spikes. SP-1's report includes the feedback flow for each entry state, including Live Activities turned off and a missing microphone permission.
- Accepting the handoff. Before WP-40 starts, the orchestrator checks the handoff against the matrix: every cell is designed or inherits from a named cell, and each capture surface is shown at the largest text size, with Reduce Motion and with the keyboard up. Gaps go back to the designer as a list, not as a second round.
- Where the design changes structure, the orchestrator lists each difference in `docs/design/deltas.md` and assigns it, and WP-40's ownership extends to the view models those differences touch. Where the handoff is silent, the implementer uses the system default and adds a line to the same file, which the owner clears at M6.
- Where a mock and a system component differ, the system component wins and the deviation is recorded. Type maps to Dynamic Type text styles, colour to roles and materials to system materials. Controls, complications, widgets and the Live Activity take glyphs, strings and content from the handoff and rendering from the system. WP-40 writes these rules into `DESIGN.md`.
- WP-19 adds an OpenSearch intent, and WP-31 a Search control and widget target, which open the stream with search focused. A widget, control or complication may show state without text: a recording with its timer, how many captures are waiting, how many failed.
- WP-33 follows docs/product-spec.md §6 for the panel. A tap gives it the keyboard. A hold shows it without taking the keyboard, and it hides by itself shortly after the text has arrived unless it is clicked or typed in. It opens on the display that has the keyboard focus. A click on the menu bar icon opens the menu. The panel and the main window have a microphone control that starts and stops a recording (assumption A30). The state machine tests cover a tap taking the keyboard and a hold not taking it.
- WP-35 makes the Pencil always draw on the capture surface, after checking in the 27 SDK how the system's handwriting input is turned off there. A drawing does not end on one stray key press or touch. When two columns do not fit, the iPad uses the iPhone layout, and at launch its open column is the capture surface. UI tests cover a narrow width and a key press during a drawing.
- Accessibility is behaviour, as docs/product-spec.md §13 states it: VoiceOver announces the start and stop of a recording and stays silent while it runs; new text never moves focus; focus returns when a surface closes; every segment action is reachable from the keyboard on the Mac and the iPad. WP-21 builds this into its components, WP-04 adds one VoiceOver row per capture path to the M2 to M5 checklists, and WP-41 confirms it.
- The first-run stream says that sync is on and where its switch is. It may also carry up to three dismissible rows on setting up the Action Button, a Lock Screen control and the Watch complication (assumption A29). If Live Activities are off, Settings says that recording from the Lock Screen will open Knot.
- A segment written through the command line or MCP carries a quiet mark, and a segment made by a newer Knot says so and asks for an update. WP-21 builds both.
- The owner calendar gains about 35 minutes: 15 at G2 to read the handoff's gap list, and 5 at each of M2 to M5 for the VoiceOver rows.
- No mockups were made with gstack's designer in this review. By D13 the visual design comes from Claude Design.
- Assumptions A27 to A30 join docs/product-spec.md §16, and the owner confirms them with the others at G0. `TODOS.md` gains two deferred items, ten in all: reopening a finished drawing, and stopping a recording that hears no speech.
<!-- /autoplan-accepted:design -->

### Phase 2.5: Developer experience review

Methodology read in full: `.gstack/tmp/autoplan/autoplan-dx-methodology-T6kzSB/methodology.md`, lines 1-600, 601-1200, 1201-1800 and 1801-1870 of 1870. Mode: DX POLISH, fixed by /autoplan. Product type: a command-line tool with an MCP server. The repository is a second developer surface, because agents implement every package from it.

#### Step 0: investigation

```
TARGET DEVELOPER PERSONA
========================
Who:       An AI coding agent acting for the owner on his Mac, and the owner himself at a terminal
Context:   It is asked to read, file or add to his notes while doing other work. It runs unattended, with no terminal.
Tolerance: One failed command. It reads every error literally, retries blindly and cannot ask what was meant.
Expects:   --help, --json, a non-zero exit on failure, and an MCP server whose tools it can list
```

The second persona is an implementing agent in a fresh worktree. Its journey is the repository's scripts.

**Developer perspective**, predicted from the plan as it stood before this phase. Nothing is built yet, so none of this was observed.

> I am an agent in the owner's terminal. He said: "file this morning's notes." I run `knot list --json`. The first thing I get is a refusal, because command-line access is off. The plan does not say what that refusal looks like, so I cannot tell whether to retry, fix something or ask him. He turns it on. One note came from his Watch and has no text yet. Is it finished? The output does not say. I file what I can and remember the time, so that next time I can ask for notes since then. An hour later a Watch recording from that same morning arrives. My next `--since` skips it, because its time is this morning. Nobody notices. Later `knot add` times out. Did it land? I run it again, and now there are two. Then I tidy a segment, and `knot edit` with my text variable empty sits waiting for input that never comes.

**Competitive benchmark.** Aside was not available, so the research ran through web search. Times are estimates from each tool's documented steps, not measurements.

| Tool | Start to first result | Time, and what it rests on | The choice it makes | Source |
|---|---|---|---|---|
| Obsidian CLI | Turn it on in Settings, let it register on the PATH, run `obsidian version` | About 2 to 3 minutes, estimated from the documented steps | An opt-in switch in the app. The tool talks to the running app. | help.obsidian.md/cli |
| Day One CLI | Run an install script inside the app bundle with `sudo`, then `dayone new` | About 2 minutes, estimated | One command only. It cannot read or export. | dayoneapp.com/guides/command-line-interface-cli |
| Bear | No first-party tool. Community MCP servers over its URL scheme or its database | 5 to 15 minutes, estimated: a runtime, a client config, a token or a setting | Third parties read the database directly | github.com/lestroos/bear-mcp and others |
| Knot, as planned | Turn on command-line access, paste one line, run `knot status` | About 2 minutes, estimated. Nothing is built. | An opt-in switch. The tool works with the app closed. A first-party MCP server. | This plan |

Target, auto-decided: 2 minutes from the Settings switch to a note read by an agent. That is the champion tier, and the M4 checklist times it. How the tool reaches the PATH from a sandboxed app is still SP-3's question, so the Settings row shows the tool's absolute path either way.

**Magical moment.** He speaks a thought into his Watch on a walk, and back at the Mac his agent has already read it and filed it. It is delivered with what the plan already has: the first row of the M4 checklist, and a three-command quick start in docs/cli.md (`knot status`, `knot changes --after 0 --json`, `knot show <id>`).

**Developer journey**

| Stage | The developer does | Friction found | Status |
|---|---|---|---|
| 1. Discover | Sees "Command-line access" in Settings, or finds `knot` in docs/cli.md | The Settings row showed nothing to paste | Fixed: the row shows two lines with copy buttons |
| 2. Install | Turns on the switch and pastes one line | How a sandboxed app puts a tool on the PATH | Open until SP-3. The row shows an absolute path either way. |
| 3. Hello world | Runs `knot status`, then `knot list` | No stated output and no time target | Fixed: a 2-minute target timed at M4; `knot` alone prints the four everyday commands |
| 4. Real usage | Polls for changes, reads, adds, edits | A late capture skipped; a retry that doubles a note; no "finished" signal; a stale store unseen | Fixed: `knot changes`, `--capture-id`, settled, the store's freshness in every result |
| 5. Debug | Reads an error | No message, code or retry rule on any path, and one command could hang | Fixed: one error mechanism; text is a required argument |
| 6. Upgrade | The app updates under a running MCP server | The server kept writing to a migrated store; no rule for changes to the JSON | Fixed: checks on every call; a schema number; one release of warning |

```
FIRST-TIME DEVELOPER REPORT
============================
Persona: an agent acting for the owner
Attempting: Knot's command line, getting started (predicted from the plan before this phase)

CONFUSION LOG:
T+0:00  The owner turns on command-line access. Nothing says what to do next.            -> fixed: two lines to paste
T+0:20  `knot`: command not found. Where is it?                                          -> fixed: the absolute path is shown; SP-3 settles the PATH
T+1:00  `knot list` works. One note has no text. Finished or not?                        -> fixed: settled, and a state per segment
T+2:00  Registering the MCP server: which command, and for which client?                 -> fixed: the line is in Settings and in docs/cli.md
T+3:00  The client speaks the 2026 revision and sends server/discover. No answer.        -> fixed: both kinds of client are served
T+4:00  `knot edit <id> "$TEXT"` with TEXT empty waits for input.                         -> fixed: no text is a usage error
```

#### DX dual voices

Both voices read `.gstack/tmp/autoplan/autoplan-dx-kpL9Qp/dx-implementation.md`, SHA-256 `3101505009075b76a05f99de231dab022507068325c9a281459be0f0b10e02be`: the plan with the CEO and design amendments applied. Full reports: `.gstack/tmp/autoplan/dx-voice-claude.md` and `dx-voice-codex.md`.

**CODEX SAYS (DX, developer experience challenge).** Completed with `gpt-6-astra`, VERDICT: FINDINGS. Two critical, ten high and six medium. The critical ones: `knot add` can block waiting for input, and the prescribed rollback can discard newer work. The high ones: an unbounded contributor setup; polling that misses notes; "ready", "settled" and "current" with no machine contract; no safe retry and no stale-edit check; an MCP target that is not pinned; no error contract; a partial export with no outcome; a long-lived MCP server treated as short-lived; worktrees that share one development store; evaluations that need the owner's private recordings; and a contract scheduled after the packages it shapes.

**CLAUDE SUBAGENT (DX, independent review).** Completed, and its INPUT line matched the snapshot hash. Two critical, fourteen high and nine medium. The critical ones: the same blocking command, and `scripts/verify.sh --full` waiting on a macOS password dialog for Mac UI tests. It also found that the scripts do not choose their own Xcode, that worktrees do not share git-ignored fixtures, that the MCP lifecycle in the plan is the retired one, and that a package's brief sits in three places. It proposed a decision for each of the nine contract items.

Three of its claims about this Mac were checked before use, and all hold: `xcode-select` points at the Command Line Tools; Automation Mode is disabled and needs a password to enable; and the MCP revision 2026-07-28 exists and drops the handshake, by the specification's own changelog.

```
DX DUAL VOICES — CONSENSUS TABLE:
  Dimension                           Claude                      Codex                        Consensus
  1. Getting started < 5 min?          No: install step undefined  No: not established          CONFIRMED concern
  2. API/CLI naming guessable?         Partly: writes return none  No: IDs and text are guesses CONFIRMED concern
  3. Error messages actionable?        No: two blocking paths      No: one blocking path        CONFIRMED concern
  4. Docs findable & complete?         Partly: named, no contents  No: no map, no examples      CONFIRMED concern
  5. Upgrade path safe?                No: long-lived MCP server   No: rollback loses work      CONFIRMED concern
  6. Dev environment friction-free?    No: Xcode, fixtures, slots  No: shared store, paths      CONFIRMED concern
CONFIRMED = native + outside agree; primary cannot replace outside. DISAGREE → taste.
```

Both voices agree on every dimension, and on the remedy: decide the agent contract now, before WP-02 fixes the store's contracts. Neither asks to change a decision of the owner's, so this phase adds no User Challenge. Each critical finding came from at least one voice and was confirmed here: the blocking command by both, the password dialog by a check on this Mac, and the rollback by reading docs/architecture.md §7.

#### Pass 1: getting started. 5 → 8

- The path was implied in six steps with no timed target. It is now three steps and 2 minutes, timed at M4.
- The Settings row shows the two lines to paste, with the tool's absolute path, so an agent's client does not depend on a shell's PATH.
- For an implementing agent: a fresh worktree reaches a first green module test in 5 minutes, and `--quick` takes 3 when warm. Both are printed by the script. Appendix B makes the thread run the baseline before it changes anything.
- It stays at 8: how the tool reaches the PATH is open until SP-3.

#### Pass 2: command-line and MCP design. 5 → 8

The contract that the CEO phase left open (C9, with S3.1 and T12) is decided and written into docs/product-spec.md §10:

| Item | Decision |
|---|---|
| IDs | Output shows full IDs. An argument is a full ID or a unique suffix of eight or more characters. Never a prefix: the leading characters of these IDs are a timestamp. |
| Text | A required argument. `-` reads standard input. No text is a usage error, and nothing is written. Clearing a title is `--clear`. |
| `--since` | A filter on time, for people. |
| Polling | `knot changes --after <cursor>`, over a change counter kept in the store from schema version 1. It returns late captures and deletions. |
| Finished | Each note says whether it is settled. Each segment carries its state, the origin of its text and its revision. |
| Pending marker | In JSON, the segment's state. In Markdown, a line in the front matter and a comment where text is missing. |
| Staleness | Every result says whether Knot is running, whether sync is on and when it last synced. Never an error. |
| Safe retry | `--capture-id` on `add` and `append`. A repeat is a no-op that returns the first result. |
| Safe edit | `--if-revision` on `edit` and `title`, required in the MCP tools. Replaced text is kept 30 days. |
| Export | It never downloads. It refuses when attachments are elsewhere, and `--skip-missing` exports the rest with a list. |
| Exit codes | 0 to 8, with the string code as the contract. |
| MCP revision | 2026-07-28, plus the handshake of the two revisions before it. |

- Four of these reach the store, so WP-02 and WP-10 carry them from schema version 1. Adding them at M4 would have cost a contract PR and a migration of notes the owner already relies on.
- The MCP server lives as long as its client's session, which the plan had called short-lived. It now checks the access switch and the schema version on every call.
- Considered and left out: a `--queue` flag that accepts a capture while the store is busy, and `knot show --wait`. A retry with `--capture-id` and a poll with `knot changes` cover both. A taste decision.
- It stays at 8: nothing is built, and SP-3 may still move the tool behind XPC.

#### Pass 3: error messages. 4 → 8

Before this phase, 28 of 125 applicable items were specified across 18 paths, by the Claude voice's count, and two paths blocked an unattended agent. The plan now has one mechanism: every case of the error taxonomy carries a stable code, the next action, whether a retry is safe and how often, and what was written, and the command line, `--json`, MCP results, log lines and the scripts all render from it.

```
ERROR PATH MATRIX (agent-ready-v1), as the plan now specifies them
Path                                  | Class       | what | fix  | recovery | code | context | trace | redaction | channel | Cap
knot add, no text                     | usage       | pass | pass | N/A      | pass | N/A     | N/A   | pass      | pass    | none; was CAP4:channel
knot list, access off                 | environment | pass | pass | pass     | pass | pass    | N/A   | pass      | pass    | none; was CAP6:fix
knot edit, segment changed since read | conflict    | pass | pass | pass     | pass | pass    | N/A   | pass      | pass    | none; was unspecified
knot show, unexpected failure         | unexpected  | pass | pass | pass     | pass | pass    | pass  | pass      | pass    | none; was CAP6:trace
verify.sh --full, Mac UI tests        | environment | pass | pass | pass     | pass | pass    | N/A   | pass      | pass    | none; was CAP4:channel
```

The two blocking paths, as an agent would have met them and as they now read:

```
before:  $ knot add                       (waits for standard input; never returns)
after:   knot: error[usage_missing_text]: `knot add` got no text, so nothing was captured.
         fix: knot add "text"    (or pipe it: printf '%s' "$TEXT" | knot add -)

before:  $ scripts/verify.sh --full       (a password dialog opens on the Mac; the run waits)
after:   verify: error[KNOT-ENV-AUTOMATION]: Mac UI tests need Automation Mode, and this Mac asks for a password to enable it. No test ran.
         recovery: ask the owner; do not retry until he has done this once. Without Mac UI tests: scripts/verify.sh --full --skip mac-ui
         fix (owner, once): the two commands scripts/doctor.sh prints
```

- Safety model: command-line access is off by default, the message for it never offers a command that turns it on, deletes are soft, and no error carries note text.
- It stays at 8: these are specified, not yet written. WP-34's golden tests run every error with no terminal and with standard input closed.

#### Pass 4: documentation. 5 → 8

- docs/cli.md and docs/dev-setup.md were named with no contents. Both now have them, and a test runs every example in docs/cli.md.
- A package's brief sat in three places: its section, about 100 amendment items, and two other documents. The rewrite after approval produces one file per package with fixed headings, and a script fails while an amendment list remains.
- The README links to setup, the command reference, contributing and recovery.

#### Pass 5: upgrade path. 4 → 7

- Restoring a pre-migration copy could discard everything captured since. Restoring now moves the current store aside whole and keeps it, with the app and the tool stopped first.
- Nothing protected an agent's workflow across an app update. JSON output now carries a schema number, a renamed flag or tool warns for one release, and codes never change meaning.
- It stays at 7: there is no upgrade history to judge, and codemods do not apply to a tool with one user.

#### Pass 6: development environment. 4 → 8

- The scripts did not choose their own Xcode. `.xcode-version` and a check in every script fix that.
- Mac UI tests would wait on a password dialog. The owner enables Automation Mode once at G1, `scripts/doctor.sh` fails at once until he has, and implementers can skip those tests while the gate cannot.
- Worktrees shared one development store and did not share the owner's recordings. Each worktree now has its own store, and the recordings live in one folder outside all of them.
- Tests and agent builds no longer need the owner's signing profile.
- `verify.sh` runs one tier per run, can run one step or one module, and ends with one summary line.

#### Pass 7: community and ecosystem. 4 → 5

The code is open under GPL-3.0 with a note on contributions, and a contributor can now build without the owner's team. There is no community channel and no plan for one, because Knot is for one user to begin with (D12). That is the right size for now, and it holds this pass at 5.

#### Pass 8: measurement. 3 → 7

Knot has no telemetry by decision, so measurement is by hand: the M4 checklist times the path from the switch to a note read by an agent, the scripts print their own durations, and WP-44 runs `/devex-review` at M4 against the 2-minute target.

#### NOT in scope, developer experience

- A `--queue` flag and `knot show --wait`. Covered by `--capture-id` and `knot changes`.
- A playground or a hosted sandbox. The tool is local and has one user.
- Shell completions and a Homebrew formula. Later, if the tool gains other users.
- A community channel. See Pass 7.

#### What already exists, developer experience

The retired `scripts/verify.sh` already set `DEVELOPER_DIR` and is prior art for WP-01. The capture ledger already keys on a capture ID, which is what makes `--capture-id` cheap. `swift format` and XcodeGen 2.47.0 are installed. gstack's `/devex-review` measures the result after M4.

#### DX review scorecard

```
+====================================================================+
|              DX PLAN REVIEW — SCORECARD                             |
+====================================================================+
| Dimension            | Score  | Prior  | Trend  |
|----------------------|--------|--------|--------|
| Getting Started      |  8/10  |  5/10  |  +3    |
| API/CLI/SDK          |  8/10  |  5/10  |  +3    |
| Error Messages       |  8/10  |  4/10  |  +4    |
| Documentation        |  8/10  |  5/10  |  +3    |
| Upgrade Path         |  7/10  |  4/10  |  +3    |
| Dev Environment      |  8/10  |  4/10  |  +4    |
| Community            |  5/10  |  4/10  |  +1    |
| DX Measurement       |  7/10  |  3/10  |  +4    |
+--------------------------------------------------------------------+
| TTHW                 | 2 min target | not specified before         |
| Competitive Rank     | Champion, if the 2-minute target holds at M4 |
| Magical Moment       | designed, via the M4 first row and quick start|
| Product Type         | CLI tool with an MCP server                  |
| Mode                 | POLISH                                       |
| Overall DX           |  7/10  |  4/10  |  +3    |
+====================================================================+
| DX PRINCIPLE COVERAGE                                               |
| Zero Friction      | covered, pending SP-3 for the PATH             |
| Learn by Doing     | covered: tested examples in docs/cli.md        |
| Fight Uncertainty  | covered: one error mechanism                   |
| Opinionated + Escape Hatches | covered                              |
| Code in Context    | covered: the quick start is the agent's loop   |
| Magical Moments    | covered                                        |
| Agents Are Users   | covered: no prompts, --json, safe retries      |
+====================================================================+
```

"Prior" is this plan before the phase, since no earlier DX review exists. No pass is below 5 after the fixes. The scores describe a specification, and `/devex-review` at M4 measures the real thing.

```
DX IMPLEMENTATION CHECKLIST
============================
[ ] Time to hello world under 2 minutes, timed at M4
[ ] Installation is one switch and one pasted line
[ ] First run produces meaningful output (`knot status`)
[ ] Magical moment delivered via the M4 first row and the quick start
[ ] Every error message meets the agent-ready error contract (Pass 3)
[ ] Command and tool names are guessable without docs
[ ] Every parameter has a sensible default
[ ] docs/cli.md has copy-paste examples, and a test runs them
[ ] Examples show the agent's real loop, not only hello world
[ ] Upgrade path documented, with the restore steps
[ ] Breaking changes warn for one release
[ ] Works with no terminal and with standard input closed
[ ] A changelog exists from M4
[n/a] TypeScript types, free tier, docs search, community channel
```

#### Implementation tasks, developer experience

- [ ] **T1 (P1, human: ~1w / CC: ~4h)** · WP-02 · Put the store-facing contract in the ports: change counter, revisions, capture idempotent by ID, kept history, and error cases that carry a code, a recovery and what was written
  - Surfaced by: Pass 2; both voices on timing
  - Files: to be determined (Packages/KnotKit/Sources/KnotCore/)
  - Verify: the contract suites for a repeated capture ID, a stale revision, changes after a cursor and a cursor ahead of the store
- [ ] **T2 (P1, human: ~1w / CC: ~4h)** · WP-01 · `.xcode-version`, `doctor.sh`, `lib/fail.sh`, verify tiers and summary line, the local build configuration, a store per worktree, `sdk-path.sh`, time targets, dev-setup
  - Surfaced by: Pass 6; the Claude voice, findings 1.1, 1.3 and 2.7
  - Files: scripts/, docs/dev-setup.md, .xcode-version
  - Verify: a fresh worktree reaches a green module test within the printed 5-minute target
- [ ] **T3 (P1, human: ~2w / CC: ~1d)** · WP-34 · Build the command line in three PRs to the contract of spec §10, from one command table
  - Surfaced by: Pass 2; Pass 3
  - Files: to be determined (Packages/KnotKit/Sources/KnotAgent/, Packages/KnotKit/Sources/knot/), docs/cli.md, docs/errors.md
  - Verify: golden tests for every command and every error, run with no terminal and standard input closed
- [ ] **T4 (P1, human: ~1w / CC: ~6h)** · WP-34 · The MCP server for both kinds of client, with checks on every call
  - Surfaced by: the Claude voice, findings 2.2 and 2.3; Codex, findings 7 and 14
  - Files: to be determined (Packages/KnotKit/Sources/KnotAgent/)
  - Verify: conformance tests for both kinds; access switched off and a store migrated under a connected server
- [ ] **T5 (P1, human: ~1d / CC: ~1.5h)** · WP-00 · One brief file per package in `docs/plan/`, `scripts/check-plan.sh`, and the two changes to Appendix B
  - Surfaced by: Pass 4; the Claude voice, findings 4.1 and 2.9
  - Files: docs/plan/, scripts/check-plan.sh, PLAN.md
  - Verify: `scripts/check-plan.sh` passes
- [ ] **T6 (P1, human: ~5min / CC: none)** · Owner, G1 · Enable Automation Mode and developer mode once
  - Surfaced by: Pass 3, the second blocking path
  - Files: none
  - Verify: `scripts/doctor.sh` passes
- [ ] **T7 (P2, human: ~2d / CC: ~1.5h)** · WP-10 · Restore that keeps the newer store; the history table and its 30-day purge; the cursor's index
  - Surfaced by: Pass 5; Codex, finding 12
  - Files: to be determined (Packages/KnotKit/Sources/KnotStore/)
  - Verify: after a restore the newer store folder is still present
- [ ] **T8 (P2, human: ~1d / CC: ~1h)** · WP-04, WP-13, WP-14 · The recordings folder outside worktrees; `knot-eval --set synthetic|local`
  - Surfaced by: Pass 6; the Claude voice, finding 1.2; Codex, finding 17
  - Files: Fixtures/, docs/dev-setup.md
  - Verify: `knot-eval --set local` exits with a code when the folder is missing
- [ ] **T9 (P2, human: ~1d / CC: ~45min)** · WP-33 · The Settings row with the two lines to paste
  - Surfaced by: Pass 1
  - Files: to be determined (Apps/macOS/)
  - Verify: the M4 row that times the path
- [ ] **T10 (P2, human: ~1d / CC: ~45min)** · WP-19 · StartRecording and StopRecording for Shortcuts on every platform
  - Surfaced by: the Claude voice, finding 5.3
  - Files: to be determined (Packages/KnotKit/Sources/KnotIntents/)
  - Verify: intent tests show that repeating either changes nothing
- [ ] **T11 (P2, human: ~1d / CC: ~1h)** · WP-43, WP-44 · A changelog from M4; `/devex-review` at M4
  - Surfaced by: Pass 5; Pass 8
  - Files: CHANGELOG.md
  - Verify: the M4 report compares the measured time with the 2-minute target

#### Unresolved decisions, developer experience

None is the owner's. One depends on a spike: how the tool reaches the PATH, and whether it opens the store directly or through the running app (SP-3).

<!-- autoplan-accepted:dx -->
- These items come from the developer-experience review. They add to the items above, and where one of them contradicts an earlier item, the later one wins.
- The command-line and MCP contract is fixed in docs/product-spec.md §10, and replaces the open list of the earlier item. Text is a required argument, `-` reads standard input, a command given no text writes nothing, and no command prompts. Every command takes `--json`. An argument is a full ID or a unique suffix of eight or more characters. A write returns the note, the segment, whether it joined an existing note, the segment's revision and the store's cursor. `add` and `append` take `--capture-id` and are idempotent on it. `edit` and `title` take `--if-revision`, and `title --clear` removes a title. `knot changes --after <cursor>` is the polling command. Each note says whether it is settled, each segment carries its state, the origin of its text and its revision, and every result says how current the store is. Export never downloads: it refuses when attachments are on another device, and `--skip-missing` exports the rest with a list. Exit codes run from 0 to 8 as listed there.
- Four parts of that contract reach the store, so WP-02 and WP-10 carry them from schema version 1: a store ID and a change counter, with a `revision` on each note; a `revision` on each segment; capture recording that is idempotent by capture ID; and a local `segment_history` table that keeps replaced text for 30 days. WP-02's contract suites cover each: a repeated capture ID changes nothing and returns the first result; a stale revision fails; changes after a cursor include a late capture and a deletion; and a cursor ahead of the store is reported.
- Errors use one mechanism, as docs/architecture.md §19 states. In WP-02 every case of the error taxonomy carries a stable code, the next action, whether a retry is safe and how often, and what was written, and a test fails when a case lacks a code or an entry in docs/errors.md. WP-34 renders the command line's text, `--json` and the MCP results from that one value, and has a golden test for every error, run with no terminal and with standard input closed. WP-01 adds `scripts/lib/fail.sh`, and every script reports failure through it.
- WP-34 is size L and ships in three PRs: first `status`, `add`, `list`, the error contract and the access switch; then the other commands; then the MCP server. Its commands are written against the `NoteStore` port, so its first PR starts after WP-05 on the fake store. Its second PR starts after the second PR of WP-10 and after WP-20. Embedding the tool in the Mac app waits for SP-3. One command table generates the help, the usage errors, the MCP tool list, docs/cli.md and the golden tests. A development build installs the tool as `knot-dev`.
- The MCP server speaks the 2026-07-28 revision, and the handshake of the 2025-11-25 and 2025-06-18 revisions. WP-34 reads the specification before writing it. Conformance tests cover both kinds of client, an unknown method, an unsupported version, standard output that holds protocol messages only, and exit at end of input. Tool names carry a noun, the capture tool requires a placement of "window" or "new note", results are bounded and carry a next cursor, and no tool exports. `knot mcp` reads the access switch and the schema version again on every call. While access is off it keeps answering and fails each call with the reason. Tests cover access switched off, and a store migrated while a server is connected. The M4 checklist names the client and the version it was proven with.
- Getting started. The Settings row for command-line access shows the two lines to paste, each with the tool's absolute path: one puts `knot` on the PATH, and one registers the MCP server. `knot` with no arguments prints the four everyday commands, and `knot help <code>` prints an error's entry. The target is 2 minutes from the switch to a note read by an agent, and the M4 checklist times it.
- docs/cli.md holds a three-command quick start, every command with an example and its `--json` output generated from the golden files, the exit-code and error tables with anchors, and a registration line for each client. A test runs every example in it. The README links to setup, the command reference, contributing and recovery. A changelog is kept from M4, with a section for the command line.
- Xcode selection. WP-01 commits `.xcode-version`, and every script sets `DEVELOPER_DIR` from it and checks the version. Implementers use that Xcode, and the beta only by name. `scripts/sdk-path.sh` replaces the fixed path of docs/architecture.md §21. WP-01 checks every row marked "SDK" in §20 against that Xcode's SDK. Package criteria name `scripts/verify.sh --quick`, never a bare `swift test`. WP-01 joins the prior-art list: the retired `scripts/verify.sh` already set `DEVELOPER_DIR`.
- `scripts/verify.sh` follows docs/architecture.md §18: one tier per run; `--only`, `--module` and `--seed`; the soak added by `--gate` from the diff; one summary line; and a failed step that names its log and its rerun command. `scripts/doctor.sh` runs first. `--skip mac-ui` exists for implementers, and the gate refuses it. WP-14's evaluation command becomes `knot-eval --set synthetic`.
- At G1 the owner enables Automation Mode and developer mode once, with the two commands `scripts/doctor.sh` prints. Without that, Mac UI tests wait on a password dialog that no agent can answer. It adds five minutes to that row of his calendar.
- Tests and agent builds use a local build configuration that keeps the sandbox and leaves out the entitlements that need the owner's signing profile, with sync off. WP-01 adds it, with an optional `Local.xcconfig` for a contributor's own team.
- Each worktree's development builds keep their store and their recording state in a folder of that worktree. Removing a worktree removes that folder with its simulators.
- The owner's recordings live in one folder outside every worktree, named by `KNOT_LOCAL_FIXTURES`, which replaces `Fixtures/local/`. WP-04 says whether the synthetic audio is committed or generated, where tests find it, and the error a test gives when it is absent. A contributor's PR reruns the synthetic evaluation. The orchestrator runs the local one at the gate for a PR that touches speech or cleanup, and records the numbers.
- WP-01 has a time target: a fresh worktree reaches a first green module test in 5 minutes, and `--quick` takes 3 minutes when warm. The script prints both. docs/dev-setup.md lists each prerequisite with its version and the command that installs it.
- `scripts/build-slot.sh`, `scripts/install.sh`, `scripts/release.sh` and `knot-eval` follow docs/architecture.md §18. A slot is a lock that frees itself when its holder dies. The install script exits non-zero when it missed a device. The release script takes the key as a file path only, prints variable names only in a dry run, and after a failed upload says to check App Store Connect before retrying. When the soak fails it prints its seed, its kill point and where the store was kept, and a soak failure is never retried to green.
- Package briefs. The rewrite after approval produces one file per package in `docs/plan/`, with fixed headings: goal, owns, starts after, build, merge criteria, milestone evidence, prior art, failure rules and named tests. Paths in them are relative to the repository root and include each package's tests. `scripts/check-plan.sh` fails while PLAN.md still holds an amendment list or a brief lacks a heading, and WP-00 merges only when it passes. Appendix B names the package's one file.
- Appendix B changes in two ways. The thread runs `scripts/bootstrap.sh` and `scripts/verify.sh --quick` before it changes anything, and stops if that baseline is red. Its last line is `RESULT ok` with the PR, the head and the verify summary, or `RESULT blocked` with one code, the pushed branch, what it needs and how to resume. The codes are `baseline_red`, `brief_wrong`, `needs_contract_change`, `needs_shared_file`, `needs_owner`, `needs_hardware` and `tool_failure`.
- Rolling back never discards work. Restoring a pre-migration copy stops the app and the tool, moves the current store folder aside whole and keeps it, and WP-43's guide says how to export what was captured since. WP-10 tests that the newer store is still there after a restore.
- Shortcuts get StartRecording and StopRecording on every platform, each safe to repeat. ToggleRecording stays for the Action Button and the controls. WP-19 builds them, with a test that repeating either changes nothing.
- WP-44 runs gstack `/devex-review` at M4, against the 2-minute target.
- Assumptions A31 to A34 join docs/product-spec.md §16, and the owner confirms them with the others at G0.
<!-- /autoplan-accepted:dx -->

### Phase 3: Eng review

The engineering review ran last, on the plan with the CEO, design and developer-experience amendments applied. Its methodology was read in full: 4 of 4 ranges, 2110 of 2110 lines. Nothing is built yet, so every finding is about the plan and its three companion documents. Line numbers for `docs/architecture.md` and `docs/product-spec.md` are those of the documents as reviewed, before this phase edited them.

#### Step 0: scope challenge

**What already exists.** Read in the retired tree on 2026-11-19:

- `Knot/macOS/Hotkey/HotkeyManager.swift:120` registers `kEventHotKeyPressed` only, so the plan is right that the old adapter has no release event.
- `scripts/verify.sh:5` sets `DEVELOPER_DIR` itself, as the plan says.
- `scripts/release.sh:41` refuses a dirty tree. It is prior art for WP-43.
- `Packages/KnotKit/Sources/KnotKit/Persistence/` holds the GRDB store actor in 10 files. It is prior art for WP-10.
- `Knot/Shared/EditorModel.swift:402` checkpoints drafts. It is prior art for WP-11.
- `Packages/KnotKit/Package.swift:16` pins GRDB at exactly 7.10.0.
- 14 retired test files use XCTest and 1 uses Swift Testing.

**Found and not in the plan:**

- A second worktree, `../knot-rewrite-sol`, on the local-only branch `codex/rewrite-sol`, with four untracked items.
- Open pull request 8, from `triage/v0.1-week1`, and the remote branch `codex/gutenberg-editor`.
- A ruleset on `main` that blocks deletion and force pushes, and nothing else.
- A workflow, `.github/workflows/ci.yml`, that targets a `macos-26` runner.

**Checked on this Mac:**

- `swift build --explicit-target-dependency-import-check` and `swift package diagnose-api-breaking-changes` both exist in Swift 6.4.4.
- `/usr/bin/lockf` ships with macOS. `flock` is here only through Homebrew.
- The system SQLite defaults to `fullfsync` off.
- `performAccessibilityAudit` is declared for macOS, iOS and watchOS in the 27.3 SDK.
- `CKSyncEngine.Event.FetchedRecordZoneChanges` has no public initialiser.
- The repository is public and owned by a personal account.

**Search check.** Aside was not available, so the research ran through web search.

- [Layer 1] GRDB's sharing guide: observation does not see another process, and a notification between processes is the documented pattern. The plan matches it.
- [Layer 1] SQLite's `fullfsync` is off by default, and plain `fsync` on Apple's systems does not flush the drive's cache.
- [Layer 1] The system's accessibility audit and SwiftPM's import check are built in. Both are adopted.
- [Layer 2] Swift Testing belongs in test targets and in libraries meant for them. KnotTestSupport fits, and KnotFakes stays free of it.
- [Layer 3] GitHub's merge queue is offered to organisation repositories, so the orchestrator runs its own serial queue.
- [Layer 3] The sync engine's events cannot be built in a test, so the sync rules live in a core with no CloudKit in it.

**Complexity check.** The plan proposes 19 package targets, 6 Xcode targets, 19 ports, 30 work packages and 4 spikes. That is far past the gate of 8 files or 2 new services. This phase never reduces scope, so the only question is the arrangement.

| | Original arrangement | Smaller arrangement |
|---|---|---|
| Package targets | 19 | About 11 |
| How | One target per module of docs/architecture.md §3 | Audio, speech, cleanup and ink folded into capture; sync into the store; the three test targets into one |
| Features and contracts | All | All |

Decision: the original arrangement. The smaller one breaks three commitments: a release build free of the test framework, a different platform list per module, and one folder per parallel agent.

Scope Challenge result: scope accepted as-is.

**Premises**

| # | Premise | Receipt | Verdict |
|---|---|---|---|
| 1 | The old hotkey adapter registers press events only | Knot/macOS/Hotkey/HotkeyManager.swift:120 | Verified |
| 2 | The retired verify script sets `DEVELOPER_DIR` | scripts/verify.sh:5 | Verified |
| 3 | The `v0.2.0` tag sits behind the head of `main` | 75140bbd | Verified |
| 4 | GRDB is pinned to an exact version | Packages/KnotKit/Package.swift:16 | Verified |
| 5 | No watchOS simulator runtime is installed | PLAN.md:151 | Verified with `simctl` |
| 6 | `synchronous = FULL` makes a commit survive a power cut | docs/architecture.md:534 | False. `fullfsync` is off by default. |
| 7 | GitHub's merge queue can serve this repository | docs/architecture.md:535 | False. The orchestrator runs the queue. |
| 8 | WP-00 loses nothing | PLAN.md:123 | False as written. A second worktree holds four untracked items. |
| 9 | Speech runs in the iOS Simulator for the gate | docs/architecture.md:539 | False, by the reviewing agent's probe. WP-13 repeats it. |
| 10 | Carbon hot keys deliver press and release in the sandbox | docs/architecture.md:524 | Unverified. SP-3 owns it. |
| 11 | A sandboxed tool can open the store in the app group | docs/architecture.md:380 | Unverified. SP-3 owns it. |
| 12 | A recording can start from a locked iPhone | docs/architecture.md:518 | Unverified. SP-1 owns it. |
| 13 | Watch transfers and wrist-down recording behave as reported | docs/architecture.md:520 | Unverified. SP-2 owns it. |
| 14 | An attachments zone can stay out of automatic fetches | docs/architecture.md:522 | Unverified. SP-4 owns it. |
| 15 | A CloudKit record holds about 1 MB | docs/architecture.md:542 | Unverified. From memory. SP-4 confirms. |
| 16 | A hosted runner offers Xcode 27 | PLAN.md:152 | Unverified. The plan already hedges. |
| 17 | TestFlight accepts a build from the installed Xcode | docs/architecture.md:527 | Unverified. The owner installs a release Xcode at G1. |

Seven premises are unverified, and each has an owner. Four were false, and each is corrected in this phase.

**Reality rows**

REALITY: premise-table finding 17 premises, unverified=7, four false and corrected in this phase docs/architecture.md:534
REALITY: already-done pass nothing from the plan has landed on origin/main since the request; its head is unchanged 5b04c933
REALITY: surface-check finding swift format, xcodegen, devicectl, lockf, the import check and the API check exist; the merge queue the plan left open is not offered to this repository, and flock is not a system tool docs/architecture.md:540
REALITY: binding-decisions pass no gstack decisions on this branch; D1 to D31 bind, and this phase overrules none PLAN.md:28
REALITY: numbers finding package and PR counts and the owner's hours were re-derived and hold as estimates; every speed target is an estimate by the spec's own statement PLAN.md:791
REALITY: deferred-asks pass no linked issue; video, photo and cloud cleanup were deferred by the owner PLAN.md:41
REALITY: pr-count finding about 54 PRs against a default of one per wave; D26 binds; each extra PR costs one review thread and one gate run, now stated docs/architecture.md:457
REALITY: prior-art finding GRDB's guide calls sharing a database across processes hard; the plan shares it on the Mac only and adopts the guide's notification; the choice of a sync layer stays with SP-4 docs/architecture.md:543
REALITY: transaction-semantics finding bulk writers now batch, reads use reader connections, sync's triggers are off on its own connection, and the soak reruns when the GRDB pin changes docs/architecture.md:252
REALITY: contract-assumptions pass assumed defaults are listed with their checks: SQLite's sync flags, GitHub's queue, the simulator's speech model, CloudKit's record limit docs/architecture.md:534
REALITY: units finding the one-second discard now measures the gap between two presses, not audio; the spec rule, assumption A14 and the reducers follow docs/product-spec.md:67
REALITY: perf-table finding no measurement can exist before code; the protocol is fixed: runs, percentiles, device state and workload docs/product-spec.md:332
REALITY: recall finding search is now checked against a plain scan across typed, spoken and handwritten text and titles docs/architecture.md:428
REALITY: dependency-fallback pass each spike has a stated fallback, and the command line's is now fixed to wave 1 PLAN.md:719
REALITY: obligation-tiers pass tasks carry P1 to P3 and packages carry size bands PLAN.md:113

#### Eng dual voices

Both voices read `.gstack/tmp/autoplan/autoplan-eng-oNb6Cb/eng-implementation.md`, SHA-256 `205da118783a4159032d0dc306b45403e9096d134f568c13b77372e82ff0cbd2`: the plan with the three earlier amendment lists applied. Full reports: `.gstack/tmp/autoplan/eng-voice-claude.md` and `eng-voice-codex.md`.

**CODEX SAYS (eng, architecture challenge).** Completed with `gpt-6-astra`, VERDICT: FINDINGS. Twenty-six findings, 21 high and 5 medium. The high ones: a fallback file that the idempotent capture operation would ignore; rules about a device enforced per process; no convergence rule for two devices that both finish a recording; a purge that removes what a returning device needs; no protocol for attachments; polling that misses a note that settles by time; a soak test that passes after losing a whole capture; kill tests offered as proof against a dead battery; a 150 ms promise beside a 5-second lock wait; a gate that runs contributor code beside private data; no bounds on input; account change without isolation; a recovery that can race the capture it permits; no behaviour for a disk that fills mid-capture; watch delivery with no liveness rule; copies that are not consistent snapshots; merge evidence not bound to a candidate; a gate that is not fail-closed; an orchestrator that cannot resume from a status table; M7 without M6; and the signed check of the command line left to M7.

**CLAUDE SUBAGENT (eng, independent review).** Completed, and its INPUT line matched the snapshot hash. Twenty-nine findings, 10 high. The high ones: ports fixed before anything has run against the APIs they wrap; a store that is not open yet; a stale recording state that drops the capture the user is making; an interrupted job not told apart from a crashing one; a gate that needs a speech model the Simulator lacks; the soak arriving after the packages it gates; build flavours that stop builds and not agents; `main` protected by prose; a fidelity guard that cannot see a dropped "not"; and the signed check of the command line at M7. It also designed the merge queue in eleven points.

Claims checked before use. Four were re-run here and hold: the ruleset on `main`, the user-owned repository, the second worktree and its untracked files, and 201 GiB free. One was not re-run: that the speech model is unavailable in the iOS Simulator. It is recorded as the reviewing agent's probe, and WP-13 repeats it inside an app.

```
ENG DUAL VOICES — CONSENSUS TABLE:
  Dimension                           Claude                       Codex                         Consensus
  1. Architecture sound?               Partly: rules meet unruled   No: invariants span processes CONFIRMED concern
  2. Test coverage sufficient?         No: soak late, no .live test No: soak blind, kill is not   CONFIRMED concern
                                                                    power loss
  3. Perf risks + budget/bench named?  No: timed asserts, bulk      No: 150 ms beside a 5 s lock, CONFIRMED concern
                                       writes ahead of a capture    endpoints undefined
  4. Security threats covered?         No: agents beside the notes, No: gate runs outside code,   CONFIRMED concern
                                       main guarded by prose        no input bounds
  5. Error paths handled?              No: stale press, job death,  No: fallback, recovery race,  CONFIRMED concern
                                       full disk                    disk full, watch liveness
  6. Deployment risk manageable?       With fixes: signed check at  No: evidence unbound, gate    CONFIRMED concern
                                       M7, packaging unproven       open, no resume, M7 skips M6
CONFIRMED = native + outside agree; primary cannot replace outside. DISAGREE → taste.
Missing/disabled voice = N/A, never CONFIRMED. Flag any single-voice critical finding.
```

Both voices completed, so every cell is a two-voice result. They agree on all six dimensions, and neither asks to change a decision of the owner's, so this phase adds no User Challenge.

Critical findings raised by one voice only were each checked against the documents, and all hold:

- From Claude alone: ports fixed before first use, the stale recording state, job deaths, the Simulator's missing speech model, agents beside the owner's notes, the room microphone, and the guard.
- From Codex alone: the fallback file against idempotency, ownership generations, the purge, attachments, polling that misses a settle, account isolation, evidence bound to a candidate, the journal, M7 without M6, and the bootstrap cycle.

The voices disagree on one remedy. Codex asks for a full gate on every merge. Claude asks for a depth that follows the diff. The decision is a fixed table that the gate applies by itself, with a full run every night. It goes to the final gate as a taste decision.

#### Section 1: architecture

```
                         apps and tools (Xcode targets)
  Knot-iOS    Knot-macOS    Knot-watchOS    Widgets-iOS    Widgets-watchOS    knot    knot-eval
     |            |              |               |                |             |          |
     +-----+------+              |               +-------+--------+             |          |
           v                     |                       v                      v          v
        KnotApp                  |                  KnotIntents             KnotAgent   Speech,
   the only place that           |              (types only in the             |        Cleanup
   names concrete types          |               extensions)                   | NoteStore port
           |                     v                                             v
           |          KnotAudio + KnotLink + KnotUI                        KnotStore <--- KnotSync
           v                                                                   ^     core | adapter --> CloudKit
  KnotUI  KnotCapture  KnotAudio  KnotSpeech  KnotCleanup  KnotInk  KnotExport  KnotLink
     |         |           |           |           |          |         |          |
     +---------+-----------+-----------+-----+-----+----------+---------+----------+
                                             v
                                         KnotCore
        ports, domain types, the append rule, reducers,
        and new in this phase: CaptureManifest, StoreLocations, DurableFile, the six states

  test side:  KnotFakes --> KnotCore (and KnotCapture for .preview)
              KnotTestSupport --> KnotCore, KnotFakes       KnotUIPreviews --> KnotUI, KnotFakes
              KnotSoak, new with WP-06 --> KnotStore, KnotCapture, KnotAudio
```

Two processes on the Mac:

```
  Knot.app (sandboxed) --writes--> knot.sqlite in the app group <--writes-- knot, knot mcp (sandboxed)
     ^  one NoteStore actor          WAL, fullfsync on                       one NoteStore actor
     +------ notification <---------------------------------------------------- posts after writing
  only the app migrates and syncs; the store's transaction enforces the rules about a device
```

The capture path, with the rule this phase adds:

```
  keystroke, press or stroke
        |
        v
  CaptureEngine -- store answers within 100 ms? --yes--> NoteStore records the capture
        |                                                  (row, segment, append rule, one transaction)
        | no: not open yet, migrating, or the write lock is held          |
        v                                                                 v
  CaptureManifest in Inbox/, placed by DurableFile            checkpoints by revision, never lower
        |
        +-- ingested when the store answers --> the same two operations
```

**Two shapes before one.** The plan introduces three boundaries worth a second design.

1. The capture path.
   - Shape A, the plan's: the engine writes a capture row and a segment through one store operation, and falls back to a file when the store cannot be used.
   - Shape B: every producer writes a file first, and one ingestor is the only writer of rows. In five lines: `write(manifest)`; `ingest(manifest) -> row`; the engine never touches the store; the tool drops files or runs the ingestor; the stream reads drafts from the engine.
   - Pick: A. It hides the ledger behind one operation that the engine and the tool share. B has a smaller write interface but leaks into the interface, because drafts are then not in the store, and it needs an ingestor that always runs. One part of B is borrowed: when the store does not answer in time, the capture takes the file path that already exists.
2. The tool's door to the store on the Mac: open the store directly, or ask the running app over XPC. The plan already carries both and SP-3 picks. Direct access is the deeper module, because the same store code serves both processes and the tool works with the app closed.
3. Sync: Knot's own merge core, or an existing layer over GRDB and CKSyncEngine. SP-4 already weighs both.

**The eight red flags**

| Flag | Found | Fix |
|---|---|---|
| Shallow module | None. The ports with one implementation exist to keep modules apart. | |
| Information leakage | The manifest format in three modules; the user-facing states in the interface and the tool; SQL in KnotSync and KnotStore | `CaptureManifest` and the state rules in KnotCore; one store interface for sync |
| Temporal decomposition | None that matters. The launch steps are a sequence by nature. | |
| Pass-through method | None | |
| Split ownership | The append rule in the engine and in the store; the rules about a device in two processes | The store decides, in its transaction |
| Two ways to do one task | Status in a file and on GitHub; a time-based and a count-based rule for a failed job | Status is derived; three counters with separate meanings |
| Importable internals | "Modules depend on ports, not on each other" was a sentence | The import check and the API check fail the build |
| Hand-synced list | Named tests and test code; amendments and briefs; the state matrix and the previews; the status table and GitHub | A checked list for each, or one source |

**Findings**

- [CRITICAL] (confidence: 9/10) docs/architecture.md:205 — "WAL mode with `synchronous = FULL`", beside the promise "survives a crash, a dead battery" (docs/product-spec.md:18). The system SQLite leaves `fullfsync` off, so a commit can sit in the drive's cache, and every planned proof kills a process, which keeps the cache. Raised by both voices and by this review.
- [CRITICAL] (confidence: 9/10) docs/architecture.md:192 — "Every capture writes a `capture` row as its first durable write", while the launch (line 298) puts the capture surface on screen before the store opens. A store that is not open yet, is migrating, or is locked by the tool has no rule, and the Action Button has a one-second target. Raised by both voices and by this review.
- [CRITICAL] (confidence: 8/10) docs/architecture.md:163 — "A repeat with the same ID changes nothing and returns the first result", beside line 195, where a failed save "writes its content to a file in `Inbox/`". Ingesting that file is a repeat, so newer text is dropped. Raised by Codex.
- [CRITICAL] (confidence: 8/10) docs/architecture.md:225 — "Knot recovers the orphaned recording and does not start a new one". The press is usually a person starting a recording, and nothing is kept. Raised by Claude.
- [CRITICAL] (confidence: 8/10) docs/architecture.md:110 — "A job found running at launch goes back to queued." If that counts as an attempt, a suspended app burns them. If it does not, an input that crashes the process restarts at every launch. Raised by Claude.
- [CRITICAL] (confidence: 8/10) PLAN.md:841 — "Build flavours protect the owner's notes." They protect the notes from builds. After M4 the real store and the real tool sit on a Mac where agents run as the same user, and the gate runs a pull request's code beside them. Raised by both voices.
- [CRITICAL] (confidence: 9/10) PLAN.md:754 — "Never push to `main`" is an instruction. The ruleset blocks deletion and force pushes only, and an agent that reads a pull request's comments reads text from the internet. Raised by Claude and by this review.
- [CRITICAL] (confidence: 8/10) PLAN.md:871 — "WP-34 builds the XPC fallback only if the M7 check fails", while docs/architecture.md:334 says "only if SP-3 fails". An XPC route at the last gate is a new architecture. Raised by both voices.
- [INFORMATIONAL] (confidence: 9/10) docs/architecture.md:140 — the engine's row says "Apply the append rule", and line 158 says the store "applies the append rule". One rule has two owners.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:187 — "In each process, one `NoteStore` actor writes the database." The rule "one capture is open at a time on a device" spans two processes on the Mac, and text added by the tool during an open capture has no rule. Raised by Codex.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:69 — "it uses KnotStore directly, because it needs database-level access", with no interface that keeps revisions, counters and history right for remote changes. Raised by Codex.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:263 — "Retry on another device moves ownership there", with no generation. The first owner can finish later and both publish. A conflict copy also has no stable ID, and a copy that pointed at the same recording would let a delete remove a file still in use. Raised by Codex and by this review.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:269 — "The purge after 30 days deletes the records." A device away for longer can bring a purged note back, a parent that has not arrived yet looks purged, and a note derived for a moved segment may itself be deleted. Raised by both voices and by this review.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:259 — "Assets upload from the device that made them and download on demand", with no queue, no state and no rule for a removal during an upload. Raised by Codex.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:270 — "Signing in to a different account asks the user before uploading anything." Work queued for the old account has no rule. Raised by Codex.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:213 — "Knot copies the database before each migration", while line 215 has the tool open the store "with the same KnotStore code". Either process could migrate, a file copy of a WAL database is unsafe, and a restored counter makes old cursors look current. Raised by both voices.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:211 — "`change_log`, fed by triggers and consumed only by sync". With sync off nothing empties it, and a change that sync applies fires the same triggers. Raised by Claude and by this review.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:282 — "On the third mismatch it ingests what it received as a failed capture and keeps the file." It does not say whether the watch may then delete its own copy, and the watch retries only on two events. Raised by Codex and by this review.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:164 — the changes list covers writes. A note that settles by time alone writes nothing, a purged deletion disappears from the list, and a repeated capture ID with different text returns success. Raised by both voices.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:93 — "`processingOwner: DeviceID?`". A store restored onto a new phone clones the device ID while the old phone may still run. Raised by Claude.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:258 — "The text fields `title`, `text` and `rawTranscript` go in `encryptedValues`", with no size limit anywhere. A pasted megabyte can never sync, and no other input is bounded. Raised by both voices and by this review.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:822 — the proof steps start "beside WP-05", after WP-02 has fixed the ports for APIs nobody has run. Raised by Claude.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:188 — "A manifest carries a format version", for a format that the recorder, the watch link and the ingestor each write or read.
- [INFORMATIONAL] (confidence: 6/10) docs/architecture.md:318 — "no intent runs there". Medium confidence, verify this is actually an issue: an intent that the system does run in the widget process would find no environment registered.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:338 — "measure start latency" in a proof step, on a Mac whose default input is a live microphone. Raised by Claude.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:402 — the access switch reads as a wall. Any program running as the user can open the file. Raised by Claude and by this review.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:148 — "Identifiers are constants in one xcconfig." The plan does not say where the signing team's ID lives in a public repository, and a fresh worktree does not carry git-ignored files.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:147 — "Each app launches to a placeholder." The packaging that fails late is first built in wave 3: intents in two bundles, a Live Activity type with no owner, the embedded watch app and the embedded tool. Raised by Claude and by this review.

Dispositions: all 28 accepted (audit rows 157 to 181). Each is fixed in docs/architecture.md, docs/product-spec.md or the accepted items below. Three carry a decision for the owner: which Mac holds real notes, the early TestFlight upload, and the ruleset.

#### Section 2: code quality

- [INFORMATIONAL] (confidence: 8/10) PLAN.md:792 — "`.preview` in debug builds from WP-05", while WP-05 owns only `Sources/KnotCapture/` and the preview folder (PLAN.md:790). An agent that keeps to its paths stops on its first day.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:63 — "Debug builds of the apps link it; release builds do not." SwiftPM cannot make a dependency depend on the configuration, so nothing enforces this. Raised by Claude and by this review.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:69 — "Modules depend on KnotCore's ports, not on each other" has no check, and neither has "the public API of KnotCore changes only through a contract PR" (PLAN.md:180).
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:266 — "Precedence is edited, then cleaned, then raw transcript", stated for sync and needed by the queue too. One guard in the store's operation beats a check in each caller.
- [INFORMATIONAL] (confidence: 7/10) PLAN.md:791 — WP-01 and WP-02 are sized M and sit alone on the serial chain, after the amendments added eight scripts, four verify tiers, six fakes and the command line's contract to them. Raised by Claude.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:945 — "`scripts/check-plan.sh` fails while PLAN.md still holds an amendment list or a brief lacks a heading." It does not check that every amendment landed, and about 140 items are folded by an agent. Raised by Claude.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:945 — "WP-00 merges only when it passes", but WP-00's tree holds no scripts (PLAN.md:132) and WP-01 writes them. The thread prompt also demands a green baseline on a tree that has no build. Raised by Codex.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:208 — "keeps its store and its recording state in a folder of that worktree's own". A sandboxed Mac app cannot write there, and local builds leave out the app group, so the two-process path would first run at the owner's M4 sitting. Raised by Claude.
- [INFORMATIONAL] (confidence: 9/10) PLAN.md:123 — "nothing from the old app is lost", while WP-00 archives the main worktree only. The second worktree, a local branch, an open pull request and ignored build leftovers are not named. Raised by Claude and by this review.
- [INFORMATIONAL] (confidence: 7/10) docs/product-spec.md:50 — "One capture is open at a time on a device." Two capture fields of the same kind, as two iPad windows would give, have no rule.
- [INFORMATIONAL] (confidence: 6/10) docs/architecture.md:267 — "An edit that arrives for a deleted note is applied to the deleted copy." Medium confidence, verify this is actually an issue: a person typing in a note that another device just deleted would keep typing into a hidden copy.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:206 — paths for the store, `Inbox/` and the recording state are computed by every module that touches files, and so is the write, rename and verify sequence.

Shared code, judged by the rubric. All callers are proposed, since nothing is built.

| Helper | Proposed callers | Same behaviour? | Verdict |
|---|---|---|---|
| `CaptureManifest` | The recorder's manifest (PLAN.md:340), the watch outbox (docs/architecture.md:278), the inbox (docs/architecture.md:188) | Yes: versioned encode and decode, unknown fields kept, an unreadable file becomes a failed segment | Accept. One version policy and one set of golden files replace three. Estimated 100 to 200 lines saved. |
| `StoreLocations` | KnotStore, KnotAudio, KnotLink, KnotCapture, the widgets, the tool | Yes: flavour to path | Accept. It turns "only a milestone build opens the default store" into one guard with one test. |
| `DurableFile` | The asset store, the recorder, the inbox, the watch outbox | Yes: write, sync, rename, verify | Accept. The sync policy of this phase must be the same everywhere. |
| The six states and the settled rule | KnotUI, KnotAgent | Yes: one mapping | Accept. The command line reports the same names the interface shows. |
| A shared retry policy | The job queue, the watch link | No: one waits on time, the other on events | Reject. Similar names, different behaviour. |

Dispositions: all 12 accepted (audit rows 175, 182 to 189). The four helpers are WP-02's work.

#### Section 3: test review

**Framework.** The retired tree uses XCTest in 14 files and Swift Testing in 1, and the plan deletes all of them. For the new code the plan named XCUITest for UI tests and nothing for the rest. Decision: Swift Testing for package tests, XCTest for UI tests and measured performance.

**Coverage, as the plan stood before this phase.** Nothing is built, so "tested" means the plan names a test that would catch a regression. Stars rate the planned test.

```
CODE PATHS                                               USER FLOWS
[+] KnotCore rules and reducers                          [+] Type a note (iPhone, iPad, Mac panel)
  ├── [★★★ PLANNED] append rule, 15 rules, fake clock      ├── [★★★ PLANNED] type, kill, relaunch
  ├── [★★★ PLANNED] reducers, every transition             ├── [★★  PLANNED] UI smoke on .preview
  ├── [★★★ PLANNED] tap or hold, release never arrives     ├── [GAP] [→E2E] the same on .live
  ├── [GAP] the prediction equals the decision             ├── [GAP] first keystroke before the store opens
  ├── [GAP] the manifest format, unknown version           ├── [GAP] a paste larger than a segment
  └── [GAP] a development build never finds the real store └── [GAP] typing in a note deleted elsewhere

[+] NoteStore, fake and real                             [+] Record (Action Button, hold, Watch)
  ├── [★★★ PLANNED] contract suite, both                   ├── [★★★ PLANNED] kill test, at most 1 s lost
  ├── [★★★ PLANNED] repeated ID, stale revision, cursor    ├── [★★  PLANNED] injected audio, UI smoke
  ├── [★★★ PLANNED] kill in mid-transaction                ├── [GAP] a press on a stale state
  ├── [★★★ PLANNED] two processes at once                  ├── [GAP] a double press on a cold start
  ├── [★★  PLANNED] migrations                             ├── [GAP] the disk fills mid-recording
  ├── [GAP] nothing to migrate from                        ├── [GAP] a forced restart mid-recording
  ├── [GAP] the same ID with different text                └── [GAP] speech on a real iPhone, by row
  ├── [GAP] a checkpoint older than the stored text
  ├── [GAP] the writer's sync settings                   [+] Watch to iPhone
  ├── [GAP] search against a plain scan                    ├── [★★★ PLANNED] loss, duplicate, reorder, lost ack
  └── [GAP] a capture while a restore is applied           ├── [★★  PLANNED] checksum mismatch
                                                           ├── [GAP] a third mismatch keeps the watch copy
[+] CaptureEngine and queue                                └── [GAP] a transfer that stalls
  ├── [★★★ PLANNED] random begin, update, end
  ├── [★★★ PLANNED] late draft save                      [+] Sync across devices
  ├── [★★★ PLANNED] a failure at every job step            ├── [★★  PLANNED] two-replica simulation
  ├── [GAP] a job found running twice                      ├── [GAP] three replicas, stated invariants
  └── [GAP] recovery does not end the current capture      ├── [GAP] a segment before its note
                                                           ├── [GAP] a kill between batch and state
[+] Soak                                                   ├── [GAP] 31 days away
  ├── [★★  PLANNED] 500 captures, seeded kills             ├── [GAP] both devices finish one recording
  ├── [GAP] a capture that vanishes whole                  └── [GAP] an account change with uploads pending
  └── [GAP] it runs before the packages it gates
                                                         [+] Agent on the Mac
[+] Cleanup                                                ├── [★★★ PLANNED] golden tests, every command
  ├── [★★★ PLANNED] guard, pure function                   ├── [★★★ PLANNED] both protocol eras
  ├── [→EVAL] [★★ PLANNED] 30 transcripts, 10 critical     ├── [GAP] the sandboxed app and tool share a store
  └── [GAP] [→EVAL] the guard against changed meaning      └── [GAP] a cursor from before a restore

[+] Hard rules                                           [+] Accessibility
  ├── [GAP] no note text in any log                        ├── [★   PLANNED] a manual audit at WP-41
  ├── [GAP] a release binary without fakes                 └── [GAP] an audit in every UI smoke test
  └── [GAP] a named test that silently vanished

COVERAGE: 24/61 paths planned (39%)  |  Code paths: 14/31 (45%)  |  User flows: 10/30 (33%)
QUALITY: ★★★:16 ★★:7 ★:1  |  GAPS: 37 (1 E2E, 1 eval)
```

Legend: ★★★ behavior + edge + error  |  ★★ happy path  |  ★ smoke check
[→E2E] = needs integration test  |  [→EVAL] = needs LLM eval

**Gaps and what closes them.** Each of the 37 gaps now has a planned test with an owner. The ones that change a package's shape:

- [CRITICAL] (confidence: 8/10) PLAN.md:798 — the soak "asserts three things", all about rows that survive. A capture that vanishes whole passes. The parent process becomes the witness. Raised by Codex.
- [CRITICAL] (confidence: 9/10) PLAN.md:798 — the soak ships in "the second PR of WP-22", after the store, the engine, the recorder and the queue have merged. It becomes WP-06, right after the store's first PR. Raised by both voices.
- [CRITICAL] (confidence: 8/10) PLAN.md:508 — "The suite passes on the Mac and the iOS Simulator", while a skipped model test fails the gate (docs/architecture.md:370) and the Simulator has no speech model. The requirement is now stated per destination. Raised by Claude.
- [CRITICAL] (confidence: 8/10) docs/architecture.md:242 — "one that drops more than a set share of the words". A share cannot see one dropped "not", and nothing tests that the guard rejects a changed meaning. A mutation suite becomes a merge criterion. Raised by Claude.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:344 — "Previews and UI tests run on `AppEnvironment.preview`", so no automated test runs an app on the live environment. Raised by both voices.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:356 — "One shared suite per port, run against both the fake and the real implementation", on the Mac. Two real implementations cannot run there. Raised by Codex.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:747 — "Never log note text" has review as its only check. The end-to-end suite gains a canary.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:374 — "These failure tests are required by name", with nothing that notices a missing one.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:841 — "every change to the schema ... ships a tested migration", with no earlier store to test against, and no way out on an iPhone. Raised by Claude.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:478 — "A two-replica simulation converges after any interleaving." Three devices exist, and "converges" is the only assertion.
- [INFORMATIONAL] (confidence: 7/10) PLAN.md:609 — "An Accessibility Inspector audit is clean on each platform", by hand, at the end.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:404 — search is tested for query syntax only. Nothing checks that it finds what a scan finds, or leaves deleted notes out.
- [INFORMATIONAL] (confidence: 7/10) PLAN.md:149 — eight scripts carry the gate and none has a test.

**Evals.** Every suite that touches a model is in scope, and none is dropped:

| Suite | Runs | Baseline |
|---|---|---|
| Cleanup, 30 synthetic transcripts with 10 meaning-critical cases | Every PR that touches the instructions, the guard or the speech settings | Committed with the fixtures. A critical case that passed and now fails blocks the PR. |
| Guard mutations, five per transcript | WP-14's first PR and every change to the guard | Every mutation rejected |
| Speech, synthetic fixtures, word error rate | WP-13 and every change to speech settings | The first measured run |
| Speech and cleanup on the owner's recordings | The orchestrator, at the gate of a speech or cleanup PR | Numbers only, kept outside the repository |
| Ink recognition on the ink fixtures | WP-18 | The first measured run |
| The nightly run on `main` | Every night | Catches a model that changed with an OS update |

**Regression rule.** The plan removes every existing behaviour by the owner's decision D15, so nothing existing is at risk by accident. The contract to keep is the restart itself: the brand files keep their checksums, the archive branch holds every tracked and untracked legacy file, and the `v0.2.0` tag points where it did. WP-00 asserts all three. The tag check is new.

**Tests made obsolete by this plan.** All 15 retired test files. They leave with the retired app and stay on the archive branch. No retirement card is needed for a deleted app.

**Test plan artifact.** Saved on the build Mac, in gstack's folder for this project, as the engineering review's test plan of 2026-11-19, 04:26.

Dispositions: all 13 listed findings and all 37 gaps accepted (audit rows 190 to 199). No test requirement is pending.

#### Section 4: performance

- [CRITICAL] (confidence: 8/10) docs/architecture.md:205 — "a 5-second busy timeout", beside "Typed text on disk after the last keystroke: 150 ms" (docs/product-spec.md:318). One writer serves a first restore of 20,000 segments, the purge, a large inbox and every capture. No budget covers a capture that waits behind them, and no benchmark runs under load. Scale: 20,000 rows in one transaction, unknown duration. Raised by both voices and by this review.
- [INFORMATIONAL] (confidence: 8/10) PLAN.md:309 — "a stream page loads in under 16 ms and a search returns in under 50 ms", as a merge criterion on a Mac running three heavy builds. It will fail at random. Raised by Claude and by this review.
- [INFORMATIONAL] (confidence: 7/10) docs/product-spec.md:312 — "iPhone: icon tap to accepting keystrokes". A signpost inside the app cannot see the tap. No target states its runs, its percentile or the device's state. Raised by Codex.
- [INFORMATIONAL] (confidence: 7/10) docs/product-spec.md:321 — "a stream of 10,000 notes" says nothing of segments or text sizes, and cleanup, conversion, ink saves and export have no budget. Raised by Codex.
- [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:249 — "Drawing data is saved at the end of every stroke." The data grows with the drawing, so each save costs more than the last. Scale: unknown, about 1,000 strokes a page.
- [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:373 — "Mac UI tests need the one desktop session." Run in every gate, they take the owner's keyboard about 75 times.
- [INFORMATIONAL] (confidence: 7/10) PLAN.md:873 — the gate has no time budget, and the queue's cost was never stated. Scale: about 75 merges.
- [INFORMATIONAL] (confidence: 7/10) PLAN.md:683 — "Each holds several gigabytes of build products." Seven worktrees with four platforms and their simulators can approach the 201 GiB free. Raised by Claude.
- [INFORMATIONAL] (confidence: 6/10) PLAN.md:893 — "60 seconds from the stop of a 30-second recording to its transcript". Medium confidence, verify this is actually an issue: a locked phone with Knot not running grants a short background window. Raised by Claude.

Dispositions: all 9 accepted (audit rows 200 to 203, and 201 for the first). Bulk writers batch and yield, reads use reader connections, the engine falls back to a file after 100 ms, and docs/product-spec.md §14 gains a target of 50 ms for a capture's first write under load. Time thresholds move to `scripts/verify.sh --perf`. The gate's aims are 12 and 25 minutes, both estimates that WP-01 measures.

#### The merge queue, the gate and the orchestrator's state

The plan left these three to this review. The full rules are in docs/architecture.md §18.

- **The queue.** Serial, one candidate at a time, run by the orchestrator. A result is bound to a base, a head and a tree, and it is void if either moved. At about 15 minutes a merge, about 75 merges cost about 19 hours of gate time, all estimates. That is not the bottleneck, so nothing is batched.
- **The gate.** It picks its depth from the diff by a fixed table, prints the depth and the reason, and refuses a partial run. A full run happens every night on `main`.
- **The state.** It is rebuilt from the briefs, GitHub and a journal outside the worktrees. A fresh thread takes over at M1 as a drill.

#### NOT in scope, engineering

- Batching the merge queue. Serial is enough at this volume. Deferred to TODOS.md.
- A separate macOS account or a virtual machine for agent builds. Deferred to TODOS.md until an outside contributor appears.
- Automatic takeover of a recording whose device is gone. It changes assumption A19. Deferred to TODOS.md.
- Several windows on the iPad. Deferred to TODOS.md.
- A custom SQLite file layer to simulate a power cut inside the database. The settings test, the file-layer test and two forced restarts cover it at far less cost.
- Encrypting the store at rest. It would need a second dependency, and the system's file protection already applies.
- A snapshot-testing library for the interface. D30 allows one dependency.

#### What already exists, engineering

- The retired store, draft checkpointing, hotkey adapter and release script are prior art, read and not copied, as the CEO phase decided.
- SwiftPM's import check and API check, the system's accessibility audit and `/usr/bin/lockf` are built in and adopted in place of anything written here.
- GRDB's documented pattern for a database shared between processes is adopted as it stands.

#### Failure modes, engineering

| # | Path | Failure | Test | Handling | Seen by the user | Before this phase |
|---|---|---|---|---|---|---|
| 1 | Any capture | A power cut after the "saved" cue | Settings test, file-layer test, forced restart | Syncs before the cue | The capture is there | **Critical gap** |
| 2 | Cold launch | A capture begins before the store opens | Three named tests | The file path after 100 ms | Nothing | **Critical gap** |
| 3 | Typed capture | A fallback file older or newer than the store | Named test | Checkpoints by revision | Nothing | **Critical gap** |
| 4 | Recording | A press on a stale state | Named test | Heartbeat; a new recording starts | The started cue | **Critical gap** |
| 5 | Sync | A fetched change queued to go back | Named test | Triggers off while applying | Nothing | **Critical gap** |
| 6 | Sync | Two devices publish text for one recording | Named test | Ownership generation | One result | **Critical gap** |
| 7 | Sync | A purged note returns with an old device | Simulation, 31 days | Tombstones and the absence rule | Nothing | **Critical gap** |
| 8 | Watch | A damaged delivery is acknowledged | Named test | Only a verified file is acknowledged | "Not delivered" on the watch | **Critical gap** |
| 9 | Cleanup | A dropped "not" passes the guard | Mutation suite | Stricter guard | The raw transcript | **Critical gap** |
| 10 | Jobs | An input that crashes the process | Named test | Two deaths, then failed | A retry action | Gap, visible as a crash |
| 11 | Sync | A record over the size limit | Named test | Text continues in a new segment | Nothing | Gap, visible as a sync error |
| 12 | Recording | The disk fills mid-capture | Four named tests | Stop cue, what exists is kept | The reason | Gap |
| 13 | Agent | A cursor from before a restore | Golden test | Refused as a conflict | Exit code 5 | Gap |
| 14 | Build | An agent opens the owner's notes | Locations test | `KNOT_AGENT=1` refuses | Nothing | Gap |
| 15 | Build | A push to `main` outside the queue | None possible | The ruleset | A refused push | Gap |
| 16 | Build | The orchestrator resets mid-merge | The drill at M1 | The journal | Nothing | Gap |
| 17 | Release | A build released without M6 | Release dry run | The script refuses | A named refusal | Gap |

Nine failure modes had no test, no handling and no sign to the user. All nine are closed in the plan by this phase.

#### Worktree parallelization

| Step | Modules touched | Depends on |
|---|---|---|
| WP-00 | The repository root, `docs/` | The owner's approval |
| WP-01, PR 1 | `project.yml`, `Apps/`, `Package.swift`, `scripts/` | WP-00 |
| WP-01, PR 2 | `scripts/` | WP-01 PR 1 |
| WP-02, PR 1 to 3 | KnotCore, KnotFakes, KnotTestSupport | WP-01 PR 1, and the port-fit notes for PR 2 |
| Proof steps and spikes | KnotAudio, KnotSpeech, KnotCleanup, KnotInk, `Spikes/` | WP-01 PR 1, WP-04 |
| WP-05 | KnotCapture, the preview folder of KnotFakes | WP-02 PR 2 |
| WP-10 | KnotStore | WP-05 |
| WP-06 | `Tests/KnotSoak/` | WP-05, WP-10 PR 1 |
| WP-11, WP-15 | Separate folders of KnotCapture | WP-05 |
| WP-12, WP-13, WP-14, WP-18, WP-20 | One module each | WP-05, and WP-02 for WP-20 |
| WP-21 | KnotUI, KnotUIPreviews | WP-05 |
| WP-19 | KnotIntents | WP-05, SP-1, SP-2 |
| WP-22 | KnotApp, the end-to-end tests | WP-05, WP-10 PR 1 |
| WP-30, WP-33, WP-32, WP-35, WP-31 | One app folder each | WP-21 PR 1 and their spikes |
| WP-16 | KnotSync | WP-10 PR 2, SP-4 |
| WP-17 | KnotLink | SP-2 |
| WP-34 | KnotAgent, `knot` | WP-05, then WP-10 PR 2, WP-20, SP-3 |
| WP-40 to WP-44 | The theme, then each platform's views | The handoff, and the app packages |

Parallel lanes:

- Lane A, the foundation, in sequence: WP-00, WP-01 PR 1, WP-02 PR 1 and 2, WP-05, WP-10 PR 1, WP-22 PR 1.
- Lane B, tooling: WP-01 PR 2, beside WP-02.
- Lane C, proofs and spikes: eight threads beside WP-02, within the limit of five at a time.
- Lane D, media: WP-12, WP-13, WP-14, WP-18, each in its own module.
- Lane E, capture: WP-11 and WP-15, in separate folders, with WP-06 beside them.
- Lane F, interface: WP-21, then the four app shells, then WP-31 and WP-35.
- Lane G, sync: WP-10 PR 2, then WP-16.
- Lane H, the agent: WP-34's three PRs.
- Lane I, the watch: WP-17, then the second PR of WP-32.
- Lane J, design: the brief, the direction, the handoff, WP-40.

Execution order: lane A runs alone until WP-01 PR 1 merges. Then B and C start beside it. When WP-05 merges, D, E, F and H start. G and I wait for their spikes.

Conflict flags: KnotCapture is shared by WP-05, WP-11 and WP-15, in sequence and then in separate folders. KnotUI passes from WP-21 to WP-40. `Tests/KnotSoak/` takes one file from each of WP-11, WP-12 and WP-15. KnotCore changes only through contract PRs, merged at two fixed times a day. `scripts/` belongs to the orchestrator after WP-01.

#### Implementation tasks, engineering

- [ ] **T1 (P1, human: ~2d / CC: ~1h)** · WP-00 · List what else exists before deleting, write the first plan check, the named-tests list and the amendments map, and assert the tag
  - Surfaced by: Section 2; Codex on the bootstrap cycle; Claude on the second worktree
  - Files: scripts/check-plan.sh, docs/plan/named-tests.txt, docs/plan/amendments.md
  - Verify: the script passes on the restart branch, and `git rev-parse v0.2.0` matches the value recorded before
- [ ] **T2 (P1, human: ~1w / CC: ~4h)** · WP-01 PR 1 · Scaffold with both flavours, the local configuration outside the worktrees, the Mac development store, and one proof of each packaging risk
  - Surfaced by: Section 1; Claude, finding 26
  - Files: project.yml, Apps/, Packages/KnotKit/Package.swift, scripts/bootstrap.sh, scripts/doctor.sh, scripts/verify.sh
  - Verify: `scripts/verify.sh --quick` asserts the intent in both bundles, the embedded tool's signature, the contract suite from two test targets and a Release binary without fakes
- [ ] **T3 (P1, human: ~1w / CC: ~4h)** · WP-01 PR 2 · The gate with its depth table and checks, the slots on `lockf`, `status.sh`, the journal, `worktree-remove.sh` and the scripts' self-test
  - Surfaced by: the merge queue; Codex, findings 21 to 23
  - Files: scripts/
  - Verify: the self-test passes, and a gate run with `--only` is refused
- [ ] **T4 (P1, human: ~2w / CC: ~1d)** · WP-02 · The one-home helpers, the append rule's single owner, checkpoints, the content hash, size limits, the three job counters, the heartbeat reducers and the launch ID, in three PRs
  - Surfaced by: Sections 1 and 2
  - Files: to be determined (Packages/KnotKit/Sources/KnotCore/, KnotFakes/, KnotTestSupport/)
  - Verify: contract tests for a prediction equal to the decision, a late checkpoint, a repeated ID with other text, and a job found running twice
- [ ] **T5 (P1, human: ~3d / CC: ~3h)** · WP-12, WP-13, WP-14, WP-18 and the spikes · Start the proofs beside WP-02's first PR and file a port-fit note each
  - Surfaced by: Section 1; Claude, finding 1
  - Files: docs/spikes/, the proof code in each module
  - Verify: WP-02's second PR links four notes
- [ ] **T6 (P1, human: ~2w / CC: ~1d)** · WP-10 · Sync settings on the writer with their cost, migration by the app alone with a checked copy, generations, daily copies, the one-row change log, batches, tombstones, the install ID, and search checked against a scan
  - Surfaced by: Sections 1, 3 and 4
  - Files: to be determined (Packages/KnotKit/Sources/KnotStore/)
  - Verify: the named store tests, and a report of commit cost on the iPhone and the Mac
- [ ] **T7 (P1, human: ~3d / CC: ~3h)** · WP-06 · The soak harness with the parent as witness and the shared consistency check
  - Surfaced by: Section 3; both voices
  - Files: Packages/KnotKit/Tests/KnotSoak/
  - Verify: a seeded run in which a capture is deleted by hand fails
- [ ] **T8 (P1, human: ~1w / CC: ~4h)** · WP-05, WP-11, WP-22 · The file path when the store does not answer, ownership by launch, step dependencies and the breaker
  - Surfaced by: Section 1; both voices
  - Files: to be determined (KnotCapture/, KnotApp/)
  - Verify: the three named tests: before open, during a migration, during a held lock
- [ ] **T9 (P1, human: ~1w / CC: ~4h)** · WP-12 · The heartbeat, a sync every second, injected audio with the hardware input refused under test, and the stop when the disk fills
  - Surfaced by: Section 1; Claude, findings 7 and 22
  - Files: to be determined (KnotAudio/)
  - Verify: a press on a stale state starts a recording, and a test that asks for the hardware input fails
- [ ] **T10 (P1, human: ~1w / CC: ~4h)** · WP-14 · The stricter guard, the mutation suite and the title rule
  - Surfaced by: Section 3; Claude, finding 24
  - Files: to be determined (KnotCleanup/)
  - Verify: every mutation of every evaluation transcript is rejected
- [ ] **T11 (P1, human: ~3w / CC: ~2d)** · WP-16 and SP-4 · The merge core and adapter, the store's interface, generations, the absence rule, asset states, account isolation, and the simulation with its invariants
  - Surfaced by: Section 1; Codex, findings 3 to 5 and 16
  - Files: to be determined (KnotSync/), docs/spikes/SP-4.md
  - Verify: the simulation with two and three replicas, and the seven named sync tests
- [ ] **T12 (P2, human: ~3d / CC: ~3h)** · WP-17 and SP-2 · Acknowledge only verified files, the retry triggers, a stalled transfer, and the background time the phone grants
  - Surfaced by: Section 1; Codex, finding 19
  - Files: to be determined (KnotLink/), docs/spikes/SP-2.md
  - Verify: the fake-transport test for a third mismatch keeps the watch copy
- [ ] **T13 (P1, human: ~1w / CC: ~4h)** · WP-22, WP-30, WP-33 · A `.live` smoke test on each platform, the allowed list of unavailable ports, the log canary, and export and restore in About
  - Surfaced by: Section 3; both voices
  - Files: to be determined (KnotApp/, Apps/)
  - Verify: the canary word appears in no log of the end-to-end run
- [ ] **T14 (P2, human: ~3d / CC: ~2h)** · WP-21, WP-41 · The accessibility audit in every UI smoke test
  - Surfaced by: Section 3
  - Files: to be determined (the UI test targets)
  - Verify: an unlabelled control fails the smoke test
- [ ] **T15 (P2, human: ~1w / CC: ~4h)** · WP-42 · The `--perf` tier, the seeded store and the measurement protocol
  - Surfaced by: Section 4; Codex, findings 12 and 13
  - Files: scripts/verify.sh, to be determined (the benchmark targets)
  - Verify: the report gives a median and a 95th percentile over 20 runs for each target
- [ ] **T16 (P2, human: ~1w / CC: ~4h)** · WP-34 · The settle time, a deletion after the purge, a foreign cursor, the refusal on an open capture and the bounds on input
  - Surfaced by: Section 1; Codex, finding 6
  - Files: to be determined (KnotAgent/), docs/cli.md
  - Verify: golden tests for each
- [ ] **T17 (P2, human: ~2d / CC: ~1h)** · WP-43 · The release refuses without every milestone's evidence, and checks the Release binary
  - Surfaced by: Codex, finding 24
  - Files: scripts/release.sh
  - Verify: a dry run without M6's evidence is refused by name
- [ ] **T18 (P1, human: ~1d / CC: ~1h)** · The orchestrator · The runbook, and the drill at M1
  - Surfaced by: the orchestrator's state; Codex, finding 23
  - Files: docs/orchestrator.md
  - Verify: a fresh thread reaches the same status table from the runbook alone
- [ ] **T19 (P1, human: ~20min / CC: n/a)** · The owner, at G1 · Extend the ruleset, limit interactions, and say which Mac holds real notes
  - Surfaced by: Section 1; both voices
  - Files: none
  - Verify: `gh api` shows the four rules

#### Unresolved decisions, engineering

None blocks the plan. Three belong to the owner and go to the final gate: which Mac holds real notes while the build runs; the early TestFlight upload of the spike app, which both voices now ask to make required; and the ruleset on `main` at G1. Four depend on spikes, as before.

#### Decision ledger, engineering

Every remedy in this phase was decided by principle under the pipeline's rules, and each cites its audit row. The checked rows are 155 to 210. Eight are taste decisions and go to the final gate: 157, 160, 169, 176, 180, 194, 205 and 206.

Approval readiness: PASS

#### Completion summary

- Step 0: Scope Challenge — scope accepted as-is
- Reality rows: 15/15 applicable rows emitted, 7 unverified premises
- Architecture Review: 28 issues found
- Code Quality Review: 12 issues found
- Test Review: diagram produced, 37 gaps identified
- Performance Review: 9 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 4 items added by principle, 14 in all
- Failure modes: 9 critical gaps flagged, all closed in the plan
- Unresolved decisions: 3 in this review, all the owner's
- Outside voice: Codex, completed
- Parallelization: 10 lanes, 9 parallel / 1 sequential
- Lake Score: N/A. Every choice was made by principle, and none was scored for completeness.

<!-- autoplan-accepted:eng -->
- These items come from the engineering review. They add to the items above, and where one of them contradicts an earlier item, the later one wins.
- Counts. The plan now has 31 work packages and about 54 PRs before contract and fix PRs. WP-06, the soak harness, is new. WP-01 and WP-02 become size L: WP-01 ships in two PRs and WP-02 in three.
- WP-01's first PR is the scaffold that unblocks WP-02 and the spikes: the targets, both build flavours, the local configuration, `scripts/bootstrap.sh`, `scripts/doctor.sh` and `scripts/verify.sh --quick`. It also proves the packaging that otherwise fails late, with one trivial instance of each and a check in `verify.sh`: an App Intent declared in the package and present in both the app and the widget extension, a Live Activity attributes type, the watch app embedded in the iPhone app, the `knot` tool embedded and signed in the Mac app, a contract suite in KnotTestSupport run from two test targets, and a Release binary free of KnotFakes. Its second PR is the tooling and runs beside WP-02: `--full`, `--gate`, `--perf`, the slots, the install script, the ownership check, `scripts/status.sh`, `scripts/worktree-remove.sh` and the scripts' self-test. Until that second PR merges, the gate is `--quick`, listed as an exception in `scripts/gate-steps.txt`.
- WP-01 also follows the other additions to docs/architecture.md §18: a floor of free disk space in `scripts/doctor.sh`, slots on `/usr/bin/lockf` with one kept for the gate, the index store off for agent builds, and a small fixed set of simulators for each worktree.
- WP-01 writes the environment factory so that a debug build asks KnotFakes for the preview environment, which answers `.unavailable` until WP-05 fills it in. WP-05 therefore edits only its own folders. This replaces the earlier wording in which WP-05 changed the factory.
- WP-01 has a stated exception to Appendix B. It starts from a tree with no scripts, so its baseline is that the tree matches WP-00's file list.
- WP-02 ships in three PRs: the domain types, rules and reducers; then the ports, fakes and suites the tracer needs, which are the stores, the recorder, the transcriber, the cleaner, the clock and the IDs; then the remaining ports, fakes and suites, which may run beside WP-05. WP-05 starts after the second.
- Proof before contracts. The proof steps of WP-12, WP-13, WP-14 and WP-18, and the code half of each spike, start beside WP-02's first PR. They need only WP-01's first PR and WP-04. Each files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. WP-02's second PR waits for the notes of WP-12, WP-13 and WP-14, and its third for WP-18's and for those of SP-1, SP-2 and SP-4. This replaces the earlier timing beside WP-05.
- WP-06, the soak harness, is size S and starts after WP-05 and the first PR of WP-10. It owns `Tests/KnotSoak/` and the soak step of `scripts/verify.sh`. It covers typed captures first. WP-11, WP-12 and WP-15 each add one file of kill points there in their own PRs, as a stated exception to path ownership, and the soak is among their merge criteria. The harness follows docs/architecture.md §17: the parent process is the witness, and one shared consistency check ends the run. The second PR of WP-22 keeps the end-to-end suite and no longer builds the soak.
- One home for each rule, all in KnotCore and built by WP-02: `CaptureManifest`, the one versioned format for a recording in progress, an inbox item and a watch outbox file; `StoreLocations`, the only code that computes a store path, with no default in any library target; `DurableFile`, the only code that places a file; the mapping from internal states to the six that a person sees; and the settled rule. KnotUI and KnotAgent both use the last two, and the command line reports the six names.
- The append rule has one owner. The store's record-a-capture transaction decides, the engine passes only the placement the user asked for, and the note a capture surface shows comes from a store query that calls the same rule. WP-02 writes a test that the prediction and the decision agree, and WP-11's session tracker holds intent only.
- Checkpoints and repeats. Saving a checkpoint of an open capture is its own store operation, ordered by revision, and it never lowers stored text. A repeated capture ID with the same content returns the first result, and with different content it fails as a conflict. Replacing text checks the precedence of edited, cleaned and raw inside the store. WP-02 and WP-10 carry all three with contract tests.
- The engine never waits for the store. A capture that begins while the store is not open, is migrating or has not answered within 100 ms goes to `Inbox/` in the manifest format and is ingested later. A recording writes its manifest first. A capture belongs to the process launch that began it, and recovery finishes only the captures of earlier launches. WP-05, WP-11 and WP-22 each have a named test: before open, during a migration, during a held write lock.
- Launch steps depend on one another as docs/architecture.md §13 states: the steps that need the store are skipped when it did not open, jobs and sync wait for recovery and ingest, and a step in which the last two launches died is skipped and reported. WP-22 builds this. It replaces the earlier rule that a failed step never blocks the next.
- Jobs count attempts, deferrals and deaths apart, as docs/architecture.md §4 states. The error taxonomy gains the deferral class and three cases: text too long, a capture stopped because the disk filled, and a cursor from another store generation. WP-02 and WP-15 carry it.
- Durability has three cases, stated as rule 7 of docs/architecture.md §6. WP-10 turns `fullfsync` on, reports what a commit costs on the iPhone and the Mac, and tests that the writer connection keeps both settings. WP-12 syncs the file being recorded every second and reports the cost. `DurableFile` syncs the file and its folder before the row that points to it is committed, and a file-layer test drops unsynced writes. The owner forces a restart during a recording once at M2 and once at M3.
- Sizes are bounded as docs/architecture.md §4 states, and WP-02 fixes the numbers after SP-4 confirms CloudKit's record limit. Longer text continues in a new segment. A path on disk comes from an ID. WP-34 bounds an MCP frame and piped text, and WP-15 bounds a manifest.
- Device identity. WP-10 keeps an install ID in the Keychain for this device only, and a store that arrives through a backup gets a new device ID and a reset sync state. Automatic takeover of a recording whose owner is gone is deferred to TODOS.md. The action to move the work stays.
- WP-10 gains these rules from docs/architecture.md §7: only the app migrates, and the tool exits with code 7 on an older store; the copy before a migration is made with `VACUUM INTO` or the backup interface, checked, and required; a restored store gets a new generation; a daily copy is kept seven times; `change_log` holds one row per record and none for drafts, and its triggers are off while sync applies; bulk writers commit in small batches; reads use the reader connections; a purge leaves a tombstone. At each milestone tag a seeded synthetic store made by that build is committed, and every later build must open each one.
- WP-30 builds two actions into About for test builds, by M2: export the store as it is, and restore a kept copy.
- Sync follows the additions to docs/architecture.md §11. WP-16 splits into a merge core with no CloudKit in it and a thin adapter, and KnotStore gives it one transactional interface, so KnotSync issues no SQL. Ownership of a recording carries a generation. A conflict copy holds text only and has a derived ID. A late segment never lands in a deleted note. An asset is local only, uploading or published. The engine's state is kept per account and environment. The simulation runs with two and with three replicas and checks the five invariants listed there.
- SP-4 also answers: how a replica that stayed away for more than 30 days is handled, a segment that arrives before its note, a kill between applying a batch and saving the engine's state, a store restored from an older copy, a record at the size limit, a change of account with uploads pending, and what a restored or replaced phone does to device identity.
- The watch link acknowledges only a file that matches its checksum, as docs/architecture.md §12 states. After a third mismatch the phone keeps the damaged copy as a failed capture and the watch keeps its own. WP-17 also sends again on each of the triggers listed there and cancels a transfer that shows no progress. SP-2 measures how much background time the phone grants when it is locked and Knot is not running, and whether transcription finishes in it. The M3 row for the 60-second target states that condition.
- A stale recording state is judged by a heartbeat, as docs/architecture.md §8 states: a press that meets a stale state recovers the orphan and starts a new recording. This replaces the earlier rule that such a press starts nothing. The one-second discard is measured between the two presses. WP-02 encodes both in its reducers and WP-12 writes the heartbeat.
- No automated test and no agent opens a hardware microphone on the build Mac. The recorder takes injected audio and refuses the hardware input under test. Start latency on a real microphone is measured at the owner's sittings. Appendix A gains this as a hard rule.
- The fidelity guard is stricter, as docs/architecture.md §9 states: three kinds of removal, nothing inserted but punctuation and list markers, numbers untouched, and a mutation suite as a merge criterion of WP-14's first PR. A generated title uses only words from the note. Assumption A35 records that v1 leaves spoken self-corrections as they were said.
- Speech in the Simulator. The gate requires both models on the Mac and uses the scripted transcriber in the iOS Simulator, where the real one is not available. WP-13's proof step repeats that probe inside an app. The M2 checklist gains three rows for speech on the iPhone: the first transcription after the model downloads, a long recording that finishes across background runs, and live text. WP-22's criterion changes: the suite passes on the Mac with the models and in the Simulator with scripted speech.
- Tests added by name are listed in docs/architecture.md §17, each with its owner in `docs/plan/named-tests.txt`, which WP-00 creates from this review. The gate fails when a listed test is missing once its package has merged.
- Package tests use Swift Testing and UI tests use XCTest, as docs/architecture.md §17 states. Each real implementation runs its contract suite where it can run, as the table in §5 says.
- More tests: a UI smoke test on `.live` on each platform (WP-22 PR 1, WP-30, WP-33); the allowed list of unavailable ports per milestone (WP-22); the log canary (WP-22 PR 2); search checked against a plain scan (WP-10); the system's accessibility audit in every UI smoke test from WP-21's first PR, made clean on every designed cell by WP-41; and export names from hostile titles (WP-20). The preview test reads the state matrix from the brief's own table, so there is no second list.
- Time thresholds leave the merge criteria of WP-10 and WP-30. The gate asserts query plans and operation counts, and `scripts/verify.sh --perf` measures times at milestones and in WP-42, following the protocol in docs/product-spec.md §14. That section gains four targets, all estimates.
- The merge gate, the merge queue and the orchestrator's state follow docs/architecture.md §18. The gate picks its depth from the diff by a fixed table and refuses a partial run. The orchestrator runs a serial queue and binds each result to a base, a head and a tree. Its state is rebuilt from the briefs, GitHub and a journal outside the worktrees, and a fresh thread takes over at M1 as a drill. `docs/status.md` is written to `main` only at milestones. This settles the open point of the earlier item on the merge gate.
- Milestones. M1 also needs WP-06. M7 also needs M6, WP-40, WP-41 and WP-42, and the release script refuses a candidate that lacks any milestone's evidence. The XPC route is built only if SP-3 fails in wave 1.
- The early upload. Both reviewers ask to make the one internal TestFlight upload of the SP-3 spike app a required part of G1. It stays the owner's to authorise. If he declines and distribution signing then fails at M7, the recommendation is that v1 ships without the command line, and that no XPC route is built at the last gate. This replaces the earlier item that built the fallback after a failed M7 check.
- SP-3 also tests the two packaging rules and the key-state check named in docs/architecture.md §15. SP-1 also tests a press after a restart and before the first unlock, a double press on a cold start, a press after a force quit during a recording, and in which process each intent runs.
- WP-00 changes in four ways. It writes the first `scripts/check-plan.sh` and `docs/plan/named-tests.txt` itself, so its own merge criterion can run. It lists what else exists before it deletes: the second worktree `knot-rewrite-sol` with its four untracked items, which join the archive commit; the local branch `codex/rewrite-sol`; the remote branches `codex/gutenberg-editor` and `triage/v0.1-week1`; and open pull request 8, which the owner closes or keeps. It removes ignored leftovers with a reviewed `git clean -X` list. It checks that the `v0.2.0` tag points where it did before.
- Folding the amendments. `docs/plan/amendments.md` has one row for every item of the four amendment lists, by list and position, naming the brief that absorbed it or the reason it was dropped. `scripts/check-plan.sh` fails unless every item appears once, and a second thread compares the two before WP-00 merges.
- The repository's rules at G1. The owner extends the ruleset on `main` to require a pull request, squash merges, the status `knot/gate` and an up-to-date branch, and limits interactions to collaborators for the length of the build. He also decides which Mac holds real notes while the build runs, and the recommendation is that the build Mac holds none.
- Appendix A gains these hard rules: agents use `knot-dev` and never `knot`, and their threads export `KNOT_AGENT=1`; agents act only on the project's own `wp/`, `spike/` and `contract/` branches and never read issue or pull-request comments from GitHub; a pull request from outside is read before it is built; the repository gets no self-hosted runner, and its workflows hold no secrets and pin their actions.
- The signing team's ID stays out of the repository, as docs/architecture.md §18 states. `KNOT_LOCAL_CONFIG` names the local file, beside `KNOT_LOCAL_FIXTURES`.
- GRDB's revision is pinned as well as its version, and `scripts/verify.sh` checks it for SwiftPM and for Xcode, because the generated project's lock file is not committed.
- The Mac development store sits in the development container in a folder named for the worktree, which corrects the earlier item that placed it in the worktree. After G1 and SP-3, the gate has one development-signed step for a PR that touches KnotAgent, `knot`, the Mac app or KnotStore: the sandboxed app and `knot-dev` share a store, the tool writes and the app shows it.
- The command line follows the additions to docs/product-spec.md §10: an unsettled note carries the time at which it will settle, a deletion stays reportable after the purge, a foreign cursor is refused, and a segment whose capture is open cannot be edited or deleted.
- WP-34 covers each of those additions with a golden test. The M4 setup registers the MCP server for one personal folder, not for the user.
- Product behaviour added to docs/product-spec.md, each with its builder: a press never does nothing after a crash (§4.2, WP-02 and WP-12); a capture that the disk stops keeps what it has (§4.4, WP-12 and WP-18); longer text continues in a new segment (§4.4, WP-02 and WP-11); an open note deleted elsewhere says so and offers to restore (§7, WP-21); and one window on the iPad (§6, assumption A36, WP-01 and WP-35). Assumptions A35 and A36 join §16, and A14 now says how its second is measured.
- The Live Activity's attributes type lives in KnotIntents and belongs to WP-19. An intent reads the environment through one accessor that fails with a typed error when nothing is registered, and WP-19 tests that.
- WP-18 saves a drawing off the main thread with one save in flight, and meets the new target of 500 ms after a stroke.
- Evaluation baselines. The synthetic cleanup and speech results are committed with the fixtures. A meaning-critical case that passed and now fails blocks the PR, and the nightly run on `main` reports a model that changed with an update of the operating system.
- WP-43's release script repeats the check for KnotFakes on the archive, and refuses a binary that honours the preview launch argument. Its privacy text says that the command-line switch is consent and not a wall.
- Appendix B gains one line: after the queue has rebased a branch, its thread resets to the remote branch before it changes anything else.
- The owner's calendar gains about 20 minutes: 10 at G1 for the ruleset and the interaction limit, and 5 each at M2 and M3 for the forced restart.
- `TODOS.md` gains four deferred items, fourteen in all: automatic takeover of a recording whose device is gone, batching the merge queue, a separate account for agent builds, and several windows on the iPad.
- The owner answered the review's gate on 2026-11-19. The items below, as far as the one that begins "The second engineering pass", record his answers and what they change, and each wins over any earlier item it contradicts. He took every recommendation except one: milestone builds reuse the retired app's bundle identifier. The rewrite after approval adds the five answers that change the plan to §2 as D32 to D36, dated 2026-11-19.
- D32, the keep gate (user challenge 1, taken without the wave 0 trial). M2 is a keep gate. When the M2 checklist has passed, the owner uses the M2 milestone build as his only capture tool on the iPhone for seven days. The week runs on that build as it is, in the system look and with the structure of the chosen direction. A fix found during the week ships as a new M2 build with a tested migration, because his iPhone notes are real from M2 on.
- The week ends with the keep-gate sitting, about 30 minutes. The owner brings the diagnostics export from About, which gives the week's counts without any note text: captures a day by kind, captures that failed or stayed pending, uses of "New note", and segments moved to their own note. WP-22's exporter carries those counts. He answers five questions in writing: did he reach for Knot, was anything lost or stuck, was the grouping right, did the notes get used, and would he go back to what he used before. He then rules one of four ways: continue as planned, continue with cuts, revise the spec first, or stop the build. The orchestrator records the answers and the ruling in `docs/decisions/keep-gate.md` and turns his notes into changes to docs/product-spec.md, each through a contract PR where it reaches KnotCore. The "handled" mark of user challenge 3 is looked at again at this sitting.
- Until that ruling, nothing that the cut order names is built, and wave 4 does not start. That holds back WP-35; everything in WP-18 after its proof step; the Sketch control of WP-31 and the OpenSketch intent of WP-19; the Home Screen and Lock Screen widgets of WP-31; WP-32's complication families beyond the first and its Smart Stack widget; and WP-40, WP-41, WP-42 and WP-43. Each held part of WP-19, WP-31 and WP-32 becomes that package's last PR, so the plan has about 57 PRs before contract and fix PRs. WP-18's proof step still runs early, because WP-02's third PR waits for its note, and the ink types stay in WP-02's contracts. WP-44 keeps running from M1, and the work for M3 and M4 goes on during the week. If the full design round has run by the ruling, the orchestrator lists what the ruling changes in `docs/design/deltas.md` and sends that list to the designer, as it does for a gap.
- The cut order. If the build has to shrink, at the keep-gate sitting or at a later milestone sitting, scope leaves in this order, and only on the owner's word. No agent cuts scope.
  1. iPad Pencil: WP-35, the rest of WP-18, the Sketch control and intent, and M5. The iPad then keeps the iPhone's layout, which it has had since M1, and has no canvas, no side-by-side layout, no hardware-keyboard shortcuts and no menu bar. Ink stays a kind the store knows, so a later version can add it without a migration.
  2. System surfaces beyond the first of each kind: the Watch complication families beyond one, the Smart Stack widget, and the Home Screen and Lock Screen widgets of the iPhone. The Action Button, the controls and one complication stay.

  A part that is cut is not started. The orchestrator writes each cut to `TODOS.md` with what would bring it back, and updates the briefs in `docs/plan/` and the checklists in one PR. If M5 is cut, every condition that names M5 names M4: the deployment of the CloudKit production schema, which then also needs a recording made on one device to play on the other, and the start of WP-43. Anything beyond these two steps is a new decision of the owner's.
- The owner's calendar gains the keep-gate sitting, 30 minutes, and seven days pass between the M2 checklist and the start of M5 and wave 4 work. His sittings come to about 17 and a half hours.
- D33, a repair for a wrong grouping (user challenge 4). A segment can be moved to its own note, as docs/product-spec.md §7 and rule 16 of §3 state, with assumption A37 and its example in §16. The action sits beside Delete on every segment of a note that holds another live segment. The app undoes it at once, and the window follows the most recent capture into its new note. Merging notes, splitting a note at a point and moving a segment into another existing note stay out of v1, and `TODOS.md` gains that as one deferred item, fifteen in all.
- The store carries the move as one operation and its inverse, as docs/architecture.md §4 and §5 state. WP-02 puts both in the `NoteStore` contract and in the in-memory fake, and WP-10 implements them. The new note has a fresh ID, and its other fields come from the segment. Both notes take new counter values, and each note's latest-capture time is recomputed, in one transaction. A generated title follows the recording at the head of its note, and a typed title stays. A conflict copy moves with the segment it copies. `segment_history` keeps the note a segment left for 30 days. The contract suite covers these cases, and the real store passes them: a move and its return leave both notes exactly as they were; a repeated move changes nothing; a move is refused for an open capture, for a deleted segment and for a conflict copy; a segment alone in its note stays; a return is refused when the note it left is deleted; a generated title goes with its recording and comes back with it; and a process killed inside a move leaves the segment in exactly one note. WP-02's table for rule 16 covers a capture made inside the window of a segment that was just moved.
- Sync carries a move by the rule in docs/architecture.md §11, and WP-16's merge core implements it. The segment's `noteID` merges against the last-synced value. When two devices moved the same segment, the note whose ID sorts higher keeps it. A person's move wins over the deleted-note rule. A note left empty is hidden and is never marked deleted for that reason. Deleting a note marks the note and not its segments. A conflict copy is made in the note of the segment it copies. The simulation adds moves and their undos to its interleavings and checks a sixth invariant: every segment is in exactly one note, and a note with no live segment is never shown. Three sync tests are required by name, as docs/architecture.md §17 lists them: a segment moved on two devices before they sync, a move that meets a delete of the note it left, and an undo that returns a segment to a note deleted elsewhere. SP-4 also answers whether a segment record's note reference can change after the record is saved, which the deleted-note rule needs as well.
- The command line gains `knot move <segment>`, as docs/product-spec.md §10 states, and `knot restore` returns a moved segment for 30 days. The command table generates the MCP tool from the same row. WP-34 adds a golden test for each result: moved, nothing to move, refused for an open capture, returned, and a return refused because the note is gone. `knot changes` reports both notes after a move, and reports a note left empty as deleted.
- The interface for the move. WP-21 adds the action and its undo to the note's view model, with tests for when the action is offered and for an undo after the note it left was deleted. WP-30 and WP-33 build it into the note view on the iPhone and the Mac, the iPad inherits it, and it can be reached from the keyboard on the Mac and the iPad. The state matrix of docs/design/brief.md §6 gains the row "A segment moved to its own note, with undo", 48 rows in all, and WP-21's preview test reads it from that table. The UI smoke tests on the iPhone and the Mac move a segment and undo the move. WP-04 adds one row to the M2 checklist, for the move and its undo, and two to the M4 checklist: `knot move` with `knot restore`, and a move made on the iPhone that shows on the Mac.
- D34, the bundle identifier (taste decision 12 of the gate, answered against the recommendation). Milestone builds reuse `com.p3ob7o.knot`, with the app group `group.com.p3ob7o.knot` and the iCloud container `iCloud.com.p3ob7o.knot`, and the Mac's app-group form stays open until SP-3 reports. The retired app does not live beside them: the first milestone build installed on a device replaces it there. This replaces the recommendation of the earlier item, and that item's conditional rules now hold outright, as docs/architecture.md §7 states them under "Legacy data". `StoreLocations` roots everything v1 writes in a folder named `KnotStore/`, because the retired app owns `Application Support/Knot/` in the same container. v1 keeps its settings in a named defaults suite and never reads `UserDefaults.standard`, and the lint of WP-01's gate fails on that symbol. v1 refuses a database it did not create. WP-10 has a test, required by name, that builds a container laid out as the retired app left it and checks that every old file is byte for byte unchanged after the store has opened there. Milestone builds carry a version above 0.2.0, which is the retired app's.
- Every build that is not a milestone build keeps the development identifiers, as the earlier item on build flavours says. That includes the spikes and the TestFlight upload of the SP-3 spike app, so nothing before the M1 milestone build touches the retired app or its container. The M1 checklist starts with two rows for every device that had the retired app: empty its pending captures, and quit it before the install. G1 still confirms the whole set of identifiers.
- D35, the early upload (taste decision 1 of the gate). The one internal TestFlight upload of the SP-3 spike app is a planned part of G1, and its row in the owner's calendar no longer says "if authorised". At G1 he creates an App Store Connect record for the development identifier and an API key, about 20 minutes, and hands the key over as a file path through the secret prompt. The upload runs only then. SP-3's report includes the result of the distribution-signed check. Knot's own record, for `com.p3ob7o.knot`, is created by the owner at G5.
- D36, the owner's notes and the build Mac (taste decision 2 of the gate). The build Mac holds no real notes while the build runs. From the M4 milestone build the owner's real notes on a Mac live on his other Mac, and the M4 checklist names the Mac for each row. This replaces the recommendation of the earlier item on the repository's rules at G1.
- His other answers leave the earlier items as written. Sync stays optional and lands at M4, with its gate kept for a later decision (user challenge 2). No "handled" mark is added in v1 (user challenge 3). The Pencil canvas stays on the iPad and the iPhone Duo, with the Duo path stated as untested (user challenge 5). Taste decisions 3 to 11 and 13 to 26 of the gate stand as recommended.
- The second engineering pass read the plan with those answers applied. Its two reviewers raised 48 findings. The items below are what they change, and each wins over any earlier item it contradicts. They change how the owner's answers are carried out, and none of the answers.
- The hold names PRs, so that no milestone waits for a held part. WP-31 ships in two PRs: the first has the controls, the Live Activity and the Action Button tip, and the second, held, has the Sketch control and the Home Screen and Lock Screen widgets. WP-32 ships in three, and its third, held, has the complication families beyond the first and the Smart Stack widget. WP-19's fourth PR, held, is the OpenSketch intent. M2 needs the first PR of WP-31, and M3 the second of WP-32. M5 needs the fourth PR of WP-19 and the second of WP-31, and M6 the third of WP-32. If M5 is cut, WP-31's second PR loses the Sketch control and M6 needs it.
- Start conditions, replacing the table of the earlier item. A PR starts when everything in its row has merged. A spike counts when its report has merged and the owner has confirmed it. "The ruling" is the keep-gate ruling.

  | Package | PR | Starts after |
  |---|---|---|
  | WP-00 | 1, the restart | The plan's approval |
  | WP-00 | 2, the fold | Its PR 1 |
  | WP-01 | 1 | WP-00, PR 2 |
  | WP-01 | 2 | Its PR 1, beside WP-02 |
  | WP-04 | | WP-00, PR 2 |
  | The proof steps of WP-12, WP-13, WP-14 and WP-18, and the code half of each spike | | WP-01, PR 1, and WP-04 |
  | WP-02 | 1 | WP-01, PR 1 |
  | WP-02 | 2 | Its PR 1, and the notes of WP-12, WP-13 and WP-14 |
  | WP-02 | 3 | Its PR 2, and the notes of WP-18, SP-1, SP-2 and SP-4 |
  | WP-05 | | WP-02, PR 2 |
  | WP-06 | | WP-05 and WP-10, PR 1 |
  | WP-10 | 1 | WP-05 |
  | WP-10 | 2 | SP-3, SP-4 and WP-02, PR 3 |
  | WP-11 | | WP-05 |
  | WP-12 | 1 | WP-05 |
  | WP-12 | 2 | Its PR 1 and WP-02, PR 3 |
  | WP-13, WP-14 | | WP-05 |
  | WP-15 | 1 | WP-05 |
  | WP-15 | 2 | SP-1 |
  | WP-16 | | WP-10, PR 2 |
  | WP-17 | 1, the outbox | WP-02, PR 2 |
  | WP-17 | 2, the transport | SP-2 and WP-02, PR 3 |
  | WP-18 | After its proof step | The ruling, WP-05 and WP-02, PR 3 |
  | WP-19 | 1 | WP-05 |
  | WP-19 | 2 | SP-1 and WP-02, PR 3 |
  | WP-19 | 3 | SP-2 |
  | WP-19 | 4 | The ruling |
  | WP-20 | | WP-02, PR 2 |
  | WP-21 | 1 | WP-05 |
  | WP-21 | 2 | The design direction and WP-02, PR 3 |
  | WP-22 | 1 | WP-05 and WP-10, PR 1 |
  | WP-22 | 2 | PR 1 of WP-10 and WP-15; WP-11, WP-12, WP-13 and WP-14 |
  | WP-30 | 1 | WP-21, PR 1 |
  | WP-30 | 2 | The design direction, WP-21, PR 2, and WP-22, PR 1 |
  | WP-31 | 1 | SP-1 and WP-19, PR 2 |
  | WP-31 | 2 | The ruling |
  | WP-32 | 1 | PR 1 of WP-12, WP-17 and WP-21 |
  | WP-32 | 2 | SP-2, the design direction, WP-17, PR 2, WP-19, PR 3, and WP-21, PR 2 |
  | WP-32 | 3 | The ruling |
  | WP-33 | 1 | WP-21, PR 1 |
  | WP-33 | 2 | The design direction, SP-5, WP-21, PR 2, and WP-22, PR 1 |
  | WP-34 | 1 | WP-05 |
  | WP-34 | 2 | WP-10, PR 2, and WP-20 |
  | WP-34 | 3 | Its PR 2. Embedding the tool waits for SP-3. |
  | WP-35 | | The ruling, WP-18, WP-21, PR 2, and WP-30 |
  | WP-40a to WP-40d | | The ruling, the accepted handoff, and that platform's app package |
  | WP-41 | | WP-40 |
  | WP-42 | | The ruling and WP-22 |
  | WP-43 | | The ruling, and M5 or, if M5 is cut, M4 |

  Three rules sit beside the table. The PRs of WP-11, WP-12 and WP-15 that add kill points merge after WP-06. M2 still needs the second PR of WP-22, although the second PRs of WP-30 and WP-33 no longer wait for it. The longest chain to M2 is WP-00, the first PR of WP-01, the first two of WP-02 with the proof steps beside them, WP-05, the first PR of WP-10, the modules, the second PR of WP-22 and the second of WP-30. A second chain runs through the third PR of WP-02, which waits for the short notes of the spikes and not for their reports, and the second PRs of WP-21 and WP-30. The fold generates this table from the headers of the briefs, and `scripts/check-plan.sh` fails on a cycle, on a row that names a package without a PR where the package has several, and on a milestone that needs a held PR.
- The keep-gate counts have a source. WP-10 keeps a local table of daily counters that hold no content: captures by kind, captures and jobs that failed, uses of "New note", moves and returns. A capture row records the placement that was asked for. A move counts when it is made, a return counts apart, and a repeat that changes nothing counts as neither. WP-22's exporter reads the table, as docs/architecture.md §7 and §19 state.
- A milestone build has a level. Every milestone build, and every fix built for an earlier milestone, is made at a level from M1 to M7, and a feature whose milestone has not passed is switched off in it by a gate: sync and the command line open at M4, and ink at M5. WP-01 builds the mechanism, and WP-22 the test that lists the gates for each level. A fix made for M2 during the keep-gate week therefore carries nothing from M3 or M4. The M4 sitting passes its two-device rows on development builds first, in the development container. The M4 milestone build then opens sync on the owner's notes, after an export of the iPhone's store.
- Appendix A's list of what needs the owner's word gains every operation on the milestone iCloud container, in either environment. It says "distribution signing" where it said "signing", because agents sign development builds all day. From the deployment of the production schema on, the CloudKit schema is a committed file, and the gate fails on a change to it that is not additive.
- Schema version 1 is the schema of the M2 milestone build. Every change after that build is a numbered migration, whichever package makes it, the second PR of WP-10 included. WP-01's lint fails on GRDB's `eraseDatabaseOnSchemaChange`. The seeded store committed at each milestone tag holds work in flight: an open capture, a queued job and a pending delete. Every later build opens it, migrates it and passes the whole `NoteStore` contract suite on it.
- The move names what the caller saw. `knot move <segment> --from <note>` moves the segment only if it is still in that note, and otherwise changes nothing and says where it is, so a repeat is safe even after a later capture has joined the new note. `knot move <segment> --back` returns it. A return is refused when the segment's note has changed since the move, or when the note it left is deleted or gone, and it works on the Mac where the move was made, because `segment_history` is local. `knot restore` keeps its two meanings and gains none: it undoes a delete, or brings back replaced text on a segment that is not deleted. The app's undo is the same return. This replaces the wording of the owner's items on the command line and on the M4 checklist, whose row uses `knot move --back`. The contract cases of the owner's item on the store change with it: a repeat answers "not in that note", and a segment alone in its note is refused. WP-34's golden tests cover six results: moved; not in that note; refused for an open capture; returned; a return refused because the segment moved again; and a return refused because the note is gone.
- A segment's place has a generation. `noteGeneration` on `Segment` syncs, and rises each time the segment's note changes, by a move, a return or the deleted-note rule, as docs/architecture.md §4 and §11 state. The higher generation wins a merge. At the same generation a person's move wins over the deleted-note rule, and then the note whose ID sorts higher wins. A derived ID is a version 5 UUID, so the two are told apart by the ID alone. This replaces the comparison with the last-synced value in the owner's item on sync. WP-16's simulation runs every order of a move, its undo and a delete across three replicas.
- A move does not outlive a purge. A segment moved out of a note that another device deleted stays only if the move reaches that device before the deleted note is purged, 30 days later. After that the purge stands, as for any change to a purged record, and a test with that name covers it.
- Titles do not move with a segment. When a segment leaves a note, the note's generated title is checked again against the words still in the note and dropped if it no longer fits, and a typed title is never touched. The new note has no title. The clean job proposes a title only for the note that holds its recording when the job finishes, and only if that recording is the note's first segment and the note has none. A return puts a dropped title back if the note still has none. The check is one function in KnotCore, which KnotCleanup and the store both call. This replaces "a generated title follows the recording" in the owner's item on the store, and its contract case becomes a dropped title that a return puts back.
- Sync uploads what a merge makes. A conflict copy, a derived note, or a note reference or an owner that the merge settled is queued for upload in the transaction that made it, although the change-log triggers are off on that connection. Only a record applied exactly as fetched leaves nothing pending, and the test of that name says so.
- Two devices that take a recording at the same generation are told apart by device ID: the higher one owns it, every device applies that rule when the records merge, and the other drops its result. WP-16's simulation has that case by name.
- The retired app holds drafts as well as pending captures, for inactive vaults too (`Knot/macOS/RecoveryView.swift:21`). The M1 checklist's rows for a device that had it become three: clear its Recovery window of drafts, pending captures and outcomes that need review; keep a copy of the retired app; quit it before the install. If something was missed, that copy still opens its store, which v1 leaves untouched, and WP-43's guide says how.
- The upgrade rows name what they install over. At M1 the milestone build, signed for development as `com.p3ob7o.knot`, is installed over the retired app, and the row checks that the retired app's folder is still there. At M7 the TestFlight build is installed over the M6 milestone build, which has the same identifier and development signing. The SP-3 upload under the development identifier proves neither.
- The standard defaults domain belongs to the retired app's keys. WP-01's lint also fails on `@AppStorage` without a named store and on an autosave name without the `v1.` prefix, because the system writes those into the standard domain. WP-10's test of the retired container also checks that every key the retired app wrote still has its value.
- SP-3 is closed only when the route it chooses has passed the distribution-signed check. If the direct route fails there, the XPC route gets an internal upload of its own before the second PR of WP-34, and the report says what the tool does when Knot is not running, which docs/product-spec.md §10 then follows. The API key is handed over for one upload and revoked after it, and each upload needs the owner's word. The spike app carries the privacy manifests with their required reasons, so App Store Connect checks them in wave 1.
- SP-3 splits. SP-3 keeps command-line access to the store, the packaging rules and distribution signing. A new spike, SP-5, takes the hotkey's press and release in a sandboxed build, the panel over a full-screen app, the key-state check and whether first words are clipped. Every earlier mention of SP-3 for those means SP-5. SP-5 is size S, starts after the first PR of WP-01 and gates the second PR of WP-33. G3 gains two rows: 15 minutes for SP-5's rows on the Mac, and 15 to install the SP-3 build from TestFlight and run its check.
- From the M4 milestone build on, no milestone build is installed or run on the build Mac, because a milestone build with sync open would bring the owner's notes onto it. At G1 the owner registers his other Mac for development-signed builds. `scripts/install.sh` gains a path for a Mac: it writes the build to a folder he names, and he opens it there. The owner's recordings in `KNOT_LOCAL_FIXTURES` stay on the build Mac, as the earlier items say: they are recordings he makes for the build and chooses himself, not notes from his stream.
- Text past the size limit continues in further segments of the same capture. The first shares the capture's ID, and each later one has an ID derived from the capture's ID and its position, so a repeat returns the same segments and the ledger counts the capture once. WP-02 and WP-11 carry it, with a test that repeats a long capture.
- A revision that leaves the store carries the store's generation. A write that names a revision from before a restore is refused as a conflict, like a foreign cursor, and WP-34 has a golden test for it.
- Three rules of docs/product-spec.md §3 and §4.1 are now exact, and WP-02 tests each. A capture started on another surface ends the open one, whatever its kind. A gap that is negative by less than the window counts as inside it, and a larger one starts a new note. Text that is only spaces and line breaks is empty.
- WP-02's third PR adds seven supporting ports, each with a fake, as docs/architecture.md §5 lists them: where an Open intent lands, the cues, background time, free space, the install identity, the notice between processes and the app's lifecycle. Error codes are values and not a closed list of cases, and every synced enum has an unknown case from WP-02's first PR, so a new case does not break a branch. A contract PR that only adds merges in the normal queue. One that breaks keeps the two fixed times.
- A capture has one life across the store and `Inbox/`. One that falls back stays on the file path until it ends, and its manifest records the placement that was asked for and the note the surface showed. The store call it stopped waiting for may still commit. The row is made once, by whichever arrives first, every later save is a checkpoint by revision, and ingest places the capture where the manifest says. WP-05 and WP-11 have a named test for a store call that commits after the fallback.
- In the app process the recorder decides, not the heartbeat: a press stops a recording that this process is running. The heartbeat serves other processes and recovery. WP-02's reducers and WP-12 follow docs/architecture.md §8, and SP-1 also tests whether a toggle control's intent carries the value the control showed.
- The in-memory `NoteStore` is checked against the real one. WP-10 has a seeded differential test that applies random sequences of operations to both and compares every result, and WP-34's golden tests run on both.
- The notice between processes is a hint. The app also compares the store's change counter with the one it last showed whenever it comes forward, and once a minute while it runs. WP-10 has a test in which the tool dies before it posts.
- A restored copy brings back text. A recording or drawing purged after the copy was made shows as missing, and the restore says how many there are. Captures waiting in `Inbox/` are ingested afterwards as usual. WP-10 tests a restore of a copy older than a purge.
- A record counts as synced only for the account, the environment and the zone identity it was synced under, and the zone carries an identity written when it is made. So a record missing from the zone it was synced to is deleted locally, and a zone that is gone or new deletes nothing. A fetch that would delete more than a set share of the local notes pauses sync and asks. WP-16 builds this and SP-4 fixes the mechanism. The simulation adds a zone removed and made again, and every replica uploading after a change of environment. The move from the development environment to production is rehearsed between two development containers before M7, and the M7 checklist starts with an export of the store on each device.
- The age of a synced delete is measured between two dates the server gave, never against the device's clock. The simulation has a replica whose clock runs 40 days ahead.
- Asset folders are named by the last two characters of the ID, since the first ones of a time-ordered ID stay the same for years. The content hash of a capture is keyed with a secret of the store and stays out of the diagnostics export. When iCloud storage is full, sync says so, and text waits with the recordings while everything stays on the device.
- WP-17 ships in two PRs. The first is the outbox and the coordinator that records, converts and sends, both in KnotLink and tested on the Mac with kill points. The second is the transport. The coordinator finishes a conversion that a kill interrupted. The phone acknowledges a file once it is durably in `Inbox/` and matches its manifest, without waiting for ingest, so a phone whose store will not open cannot fill the watch. M1 needs the first PR of WP-17.
- WP-01's first PR declares a crash-host executable for KnotStore, for KnotAudio and for KnotLink, and the soak's child, because a kill test needs a process to kill. Each module exposes one live entry point that returns the unavailable port until its package fills it in, so WP-16, WP-17, WP-18 and WP-19 wire themselves in without editing `Sources/KnotApp/`.
- The checks are shown to fail. WP-06 merges only when four injected faults each turn the soak red: an acknowledgement before the write, a skipped capture row, a dropped last checkpoint and a capture stored twice. The `NoteStore` contract suite must fail three deliberately broken fakes. The second opinion from another model extends to WP-02, WP-05, WP-06, WP-11 and WP-17. Every finding the orchestrator sets aside is written in the PR and in the journal.
- A lint keeps `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` to a reviewed list. The nightly run executes the package tests under Thread Sanitizer. WP-12 has a test that feeds 30 minutes of injected audio and counts the same frames out.
- WP-04 adds checklist rows for what injected audio cannot show. M2: AirPods connecting during a recording, an incoming call, Siri and an alarm. M4: a microphone unplugged during a recording, and sleep. SP-2 records 30 minutes with the wrist down. The meaning-critical cleanup set gains cases in which only the punctuation differs, and docs/product-spec.md §5 says what the guard proves and what it does not.
- At G1 the owner sets up signing so that the gate's development-signed step runs without a prompt, and `scripts/doctor.sh` probes it. The script also refuses a repository, a build folder or a fixtures folder that a cloud file provider syncs: the stray "… 2" files of the retired tree are conflict copies from such a sync, and `~/Documents` still carries its attributes. The gate's lint fails on a file whose name ends in " 2".
- docs/architecture.md §17 lists the tests this pass adds by name, and `docs/plan/named-tests.txt` gives each its owner. Cleanup runs with greedy sampling, and each cleaned segment records the OS build whose model made it. `scripts/build-slot.sh` also limits how many simulators are booted at once.
- Every target has a privacy manifest that declares a required reason for each API that needs one, and WP-01's lint fails on such an API with no reason declared.
- WP-00 ships in two PRs: the restart, then the fold. The fold turns the amendment lists into the briefs, and a second model reviews it item by item. `docs/plan/amendments.md` gains a column that names what each item replaces, with a short quote of the replaced text, and `scripts/check-plan.sh` fails when a brief still holds a quote that was replaced. Four traps are known: the soak is built by WP-06 and not by WP-22; late arrivals are placed by the store and not by WP-11 or WP-15; the soak's trigger paths are those of docs/architecture.md §17; and the answers D32 to D36 join §2. WP-00's `git clean -X` runs from a reviewed list that leaves `.gstack/` and `.conductor/`. The second worktree's untracked files go into the archive under a folder of their own, because one of them differs from a tracked file of the same name.
- Counts. The plan has 31 work packages, five spikes and about 60 PRs before contract and fix PRs. The owner's calendar gains about 40 minutes: 30 at G3 for the two spike rows, 5 at G1 for the other Mac and for signing, and 5 across M2 and M4 for the audio rows. His sittings come to about 18 hours.
<!-- /autoplan-accepted:eng -->

### Gate revision 1: the owner's answer

The gate of 32 items went to the owner on 2026-11-19, and he answered the same day. His words were `rec except d12a`.

Under the reply grammar a token names the option chosen, so those words resolve to the recommendation for every item, d12 included, and the exception changes nothing. They are read here as taking every recommendation and declining d12a, the new bundle identifier. Item d12 has two options, so it resolves to b. Gate revision 2 shows d12 as answered b, for him to confirm or reverse. Audit row 211.

| Item | Answer | What it changes |
|---|---|---|
| uc1 | c | M2 becomes a keep gate with a week of real use, and the plan carries a written cut order. The wave 0 trial of the alternatives is not taken. |
| uc2 | a | Nothing. Sync stays optional and lands at M4. |
| uc3 | a | Nothing in v1. The question returns at the keep-gate sitting. |
| uc4 | b | A segment can be moved to its own note. |
| uc5 | a | Nothing. The iPhone Duo path stays, stated as untested. |
| d1 | a | The early TestFlight upload of the SP-3 spike app is a planned part of G1. |
| d2 | a | The build Mac holds no real notes while the build runs. |
| d12 | b | Milestone builds reuse the retired app's bundle identifier. |
| d3 to d11, d13 to d26 | a | Nothing. Each stands as recommended, and the plan already carried it. |
| p1 | b | The plan is taken with the reviews' changes and these answers. |

The answers that change the plan are items of the engineering list, after its first 52, because that list is the one a second engineering pass may extend. The earlier lists stay as they were written. The companions were edited to match: docs/product-spec.md §3, §7, §9, §10, §15 and §16; docs/architecture.md §4, §5, §7, §11, §15, §17, §18 and §19; docs/design/brief.md §6; and TODOS.md.

Applying the answers took choices that the owner has not seen. Each was decided by principle and has an audit row, 212 to 223. Three are taste and go to gate revision 2: the reading of his reply (211), how far the hold before the keep gate reaches (213), and what the cut order says (214).

What was read in the retired tree for the bundle identifier:

- `Packages/KnotKit/Sources/KnotKit/Persistence/CaptureStore.swift:237` names the retired database `captures.sqlite`. Line 294 places it in `Application Support/Knot/`, and line 260 creates `assets`, `staging` and `migration-backups` beside it.
- `Knot/Shared/EditorModel.swift:60` takes `UserDefaults.standard` as its default, so the retired app's settings are in the standard domain.
- `project.yml:62` and `:108` set `com.p3ob7o.knot` for the Mac and the iOS target, and `:57` turns the sandbox on.
- On this Mac the container `~/Library/Containers/com.p3ob7o.knot` exists, with an empty `Application Support/Knot/` and a preferences file. The exported retired app is version 0.2.0, build 1.
- docs/architecture.md §7 named the new database `Knot/knot.sqlite`. In a shared container that folder is the retired app's. It is now `KnotStore/knot.sqlite`.

### Phase 3, second pass: Eng review after the owner's answers

The owner's answers changed the plan, so the engineering review ran again on the plan as amended. Both reviewers read the whole plan, with the owner's items in it. This record holds what is new. The first pass above stands where this one does not contradict it.

Methodology read: 4 of 4 ranges, 2,110 of 2,110 lines.

#### Step 0, second pass: scope challenge

**What already exists.** Read in the retired tree on 2026-11-19, beside the lines listed under the owner's answer:

- `Knot/macOS/RecoveryView.swift:21` lists drafts through `recoverableDrafts()`, and line 31 lists pending captures separately. A draft of another vault shows as "Inactive vault". The plan's "empty its pending captures" covered the second list only.
- `~/Documents`, where this repository lives, carries the attributes `com.apple.file-provider-domain-id` and `com.apple.fileprovider.detached#B`, and its provider is iCloud Drive. `.git/ORIG_HEAD 2` is a conflict copy of the same kind as the nine " 2" files. Corrected on 2026-11-19, after approval: this record first said that the sync was off, which was inferred from a missing folder. A direct check shows that it is on. macOS reports `PLAN.md`, `project.yml`, `.git/HEAD` and `.git/objects` as iCloud items, uploaded and current, so the repository and its `.git` folder are in iCloud Drive today, and so is the second worktree. The tree holds 1,080 conflict copies, 1,067 of them under `node_modules`. `~/.t3/worktrees` is not in iCloud.
- `swift test --sanitize` exists in Swift 6.4.4. `xcrun devicectl list devices` lists no Mac.
- `origin/main` is still at 5b04c933. Nothing from the plan has landed.
- GRDB is not checked out in the tree, so the name `eraseDatabaseOnSchemaChange` is from memory. WP-01 reads GRDB before it writes that lint.

**What is the least that does the job.** The three accepted changes cannot be made smaller without losing what the owner chose. The keep gate needs a hold, or the cut order saves nothing. The move needs a sync rule, or two devices disagree for good. The reused identifier needs a root folder of its own, or v1 writes into the retired app's folder.

**Complexity.** This pass adds no package target. It adds one store operation with its inverse, one synced field (`noteGeneration`), one local field (`placement` on a capture), one local table (`counter`), one command with one flag, seven small ports, one spike (SP-5) and six PRs. The complexity gate tripped in the first pass, and its structure decision stands: the original arrangement of targets.

**Search check.** No web search was run in this pass. The patterns it adds are standard ones, labelled here:

- [Layer 1] A derived ID as a version 5 UUID (RFC 9562), told from a version 7 one by its version bits.
- [Layer 1] A generation counter with a fixed tie-break for a value that two devices can set, which the plan already uses for `ownerGeneration`.
- [Layer 1] Thread Sanitizer through `swift test --sanitize=thread`.
- [Layer 2] Required-reason declarations in a privacy manifest. From memory of Apple's rule, not re-read. WP-01 reads it.
- [Layer 3] A move made safe to repeat by naming the note the caller saw, with no stored operation ID.

**TODOS.** `TODOS.md` holds fifteen items after the owner's answer. This pass adds none.

**Reality rows.**

REALITY: premise-table finding 13 premises behind the owner's items and this pass, unverified=7, each with an owner in a spike, WP-01 or a checklist row docs/architecture.md:255
REALITY: already-done pass nothing from the plan has landed on origin/main; its head is unchanged at 5b04c933 PLAN.md:9
REALITY: surface-check finding swift test accepts --sanitize; devicectl lists no Mac, so install.sh gains a Mac path; knot move and its flags are to be built; GRDB's option name is unchecked because no checkout exists docs/architecture.md:463
REALITY: binding-decisions pass D1 to D31 bind, and the owner's five answers bind as D32 to D36; this pass changes how they are carried out and overrules none PLAN.md:1006
REALITY: numbers finding the PR count was re-derived as 54, plus 3 held PRs, the fold, the outbox and SP-5, about 60, an estimate; the owner's hours as 17.5 plus 40 minutes, about 18, an estimate PLAN.md:1120
REALITY: deferred-asks pass no linked issue; the wave 0 trial of the alternatives was declined by the owner at the gate PLAN.md:3494
REALITY: pr-count finding about 60 PRs against a default of one per wave; D26 binds; the six added PRs cost six gate runs, between one and two and a half hours of machine time PLAN.md:1120
REALITY: transaction-semantics finding a move is one transaction; sync's connection has the change-log triggers off, so what a merge makes is now queued for upload explicitly docs/architecture.md:318
REALITY: contract-assumptions finding four defaults assumed and listed with their checks: a note reference that can change after save (SP-4), a container shared across signing kinds (the M1 row), the required-reason check at upload (SP-3), and greedy sampling (WP-14) docs/architecture.md:317
REALITY: dependency-fallback pass every held PR is named and no milestone needs one; the fallback of SP-3 now has a signed check of its own PLAN.md:1027
REALITY: obligation-tiers pass the tasks of this pass carry P1 or P2, and the held work is named as held PLAN.md:1027

Premises that stay unverified, with who settles each: `devicectl` cannot install onto a Mac (WP-01); `@AppStorage` and autosave names write to the standard domain under a sandbox (WP-01's lint test); a segment record's note reference can change after save (SP-4); App Store Connect checks required reasons at upload (SP-3); a milestone build shares the retired app's container across signing kinds (the M1 row); Foundation Models offers greedy sampling (WP-14); TestFlight takes the spike under the development identifier as an app of its own (G1).

**Scope Challenge findings.**

1. [CRITICAL] (confidence: 9/10) PLAN.md:805 — "M2 | WP-30 | WP-11; WP-13; WP-14; WP-15; WP-19, PR 2; WP-31" names WP-31 whole, and the owner's item held WP-31's last PR until a ruling that comes after M2. The graph could not reach its own gate. Codex 1.
2. [CRITICAL] (confidence: 9/10) Knot/macOS/RecoveryView.swift:21 — `let drafts = try await store.recoverableDrafts()` is a second list beside pending captures, and the M1 row emptied only the captures. Codex 7.
3. [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:255 — the lint on `UserDefaults.standard` misses `@AppStorage` and autosave names, which the system writes into the same domain. Claude S4.

Dispositions: all three accepted, audit rows 224, 236 and 238.

Scope Challenge result: scope accepted as-is.

#### Eng dual voices, second pass

Both voices read `.gstack/tmp/autoplan/autoplan-eng-3tZBa1/eng-implementation.md`, SHA-256 `455f26989426025253463d878a0a19a6ffac270ce7d75fcad5093615a53c8474`: the plan with all four lists and the owner's items applied. Full reports: `.gstack/tmp/autoplan/eng2-voice-claude.md` and `eng2-voice-codex.md`.

**CODEX SAYS (eng, architecture challenge).** Completed with `gpt-6-astra` in 313 seconds, VERDICT: FINDINGS. Nineteen findings, 14 high and 5 medium. It was told which items were new, and twelve of its findings are about them. The high ones: the hold made M2 and M3 unreachable; a repeated `knot move` made a second note once a capture had joined the first; the precedence of a move could not be told from `noteID` alone; undo and `restore` had no clear target and no precondition; a moved segment could not survive a purge; the retired app's drafts would be stranded; the early upload did not prove the route SP-3 might fall back to; a milestone build on the build Mac would bring the owner's notes there by sync; what a merge makes was never uploaded; two devices could take a recording at the same generation; text past the limit broke the rule that a capture and its segment share an ID; a revision kept across a restore could pass; a restored copy could point at purged recordings; and a store call that timed out could still commit.

**CLAUDE SUBAGENT (eng, independent review).** Completed in 1,538 seconds, and its INPUT line matched the snapshot hash. It was not told what was new. Twenty-nine findings, 5 high, 17 medium and 7 low. The high ones: real notes meet features that have had no sitting, because fixes are cut from a moving `main`; nothing freezes schema version 1; two sync rules share a trigger and disagree when a zone is made again; the soak and the contract suites are never shown to fail; and WP-00, sized S, folds every amendment into the briefs.

Claims checked before use. Five were re-run here and hold: the drafts list in the retired app, the file-provider attributes on `~/Documents`, the conflict copy in `.git`, the sanitizer flag, and that `devicectl` lists no Mac. One was reasoned and holds: the first two characters of a version 7 UUID change every 35 years. Seven stay unverified and are listed above.

```
ENG DUAL VOICES — CONSENSUS TABLE, SECOND PASS:
  Dimension                           Claude                        Codex                         Consensus
  1. Architecture sound?               Partly: ownership gaps, a     No: a move needs a version,   CONFIRMED concern
                                       second store in the fake      a merge's results unsent
  2. Test coverage sufficient?         No: checks never shown to     No: no three-replica orders,  CONFIRMED concern
                                       fail                          no purge case
  3. Perf risks + budget/bench named?  Minor: storage at ten times   No finding                    No new concern
  4. Security threats covered?         Partly: manifests, the key,   No: notes reach the build     CONFIRMED concern
                                       the standard domain           Mac by sync
  5. Error paths handled?              No: a capture with two homes  No: a late commit, a lost     CONFIRMED concern
                                                                     notice
  6. Deployment risk manageable?       No: no schema freeze, fixes   No: a cycle, an upgrade path  CONFIRMED concern
                                       from a moving main            that tests the wrong build
CONFIRMED = native + outside agree; primary cannot replace outside. DISAGREE → taste.
```

Both voices completed, so every cell is a two-voice result. Five of six dimensions are a confirmed concern, and every one is answered by an item of this pass. Neither voice asks to reverse an answer of the owner's, so this pass adds no User Challenge. Two of Codex's remedies were not taken as written, and both go to the gate as taste: a stored operation ID for a move, where the plan takes a precondition on the note, and a stored source for a generated title, where the plan takes the words rule. One of its recommendations is not taken and goes to the gate as taste: moving the owner's test recordings off the build Mac.

#### Architecture, second pass

```
                 a move, end to end

  note view (WP-21, WP-30, WP-33)        knot move S --from N (WP-34)
        | "Move to its own note"                  |
        v                                         v
  NoteStore.move(S, from: N) ---------------------+      one transaction (WP-10):
        |                                                  S.noteID = P (fresh), S.noteGeneration + 1
        |   refused: capture open, S deleted,              note P made from S
        |   S a conflict copy, S alone in N                N and P: counter, latest-capture time
        |   no-op: S is not in N -> "it is in P"           N: generated title checked again (KnotCore)
        v                                                  segment_history: left N, made P, generation
  change_log -> KnotSync merge core (WP-16)                counter: moves + 1
        |
        |   higher noteGeneration wins
        |   same generation: a person's note (v7) beats a derived note (v5), then the higher ID
        |   what the merge makes is queued for upload in its own transaction
        v
  other devices: S in P; a note left empty is hidden, reported as deleted, purged after 30 days

  undo in the app, knot move S --back  ->  NoteStore.return(S)
        refused: S.noteGeneration changed since the move, or N deleted or gone
```

**Two shapes before one.** The move is a new operation on a public surface, so a second shape was required.

- Shape A, as first written under the owner's answer: the new note's ID is unchanged in kind, the segment's `noteID` merges by comparison with the last-synced value, a repeat is a no-op when the segment is alone, and a generated title travels with its recording.
- Shape B, taken: the segment carries `noteGeneration`, a move names the note the caller saw, a return checks the generation, and titles stay and are checked by one rule.
- Depth: B hides more behind the same two calls. The caller passes what it saw and gets a result that is safe to repeat. Ordering, the tie-break, the title check, history and counters all sit behind `move` and `return`. A needed the caller to know when a repeat was safe, and it was not safe once a capture had joined the new note.

**Red flags.** One was raised and fixed. Split ownership: the rule that a generated title uses only words from its note was KnotCleanup's, and the store now needs it too. It becomes one function in KnotCore that both call. The others were screened and are clear: the app's undo and `--back` are one return, `restore` gains no third meaning, the start table is generated and not kept by hand, and the gates per level are listed by a test.

Findings, most severe first:

1. [CRITICAL] (confidence: 9/10) docs/architecture.md:189 — the move was repeat-safe only while the segment stayed alone, and rule 16 lets the next capture join it. Codex 2.
2. [CRITICAL] (confidence: 8/10) docs/architecture.md:318 — sync applied fetched changes with the triggers off, so a conflict copy or a derived note it made was never sent. Codex 11.
3. [CRITICAL] (confidence: 8/10) PLAN.md:841 — "After those builds, every change to the schema or to the store's location ships a tested migration" had no build named as the freeze, and WP-10's second PR still said version 1. Claude E2.
4. [CRITICAL] (confidence: 8/10) docs/architecture.md:332 — "is treated as deleted here" and "never deletes local notes because the cloud copy is gone" share a trigger when a zone is made again. Claude E3.
5. [CRITICAL] (confidence: 8/10) PLAN.md:800 — "A milestone build is made from `main`", which moves, so a fix for M2 could carry sync before M4. Claude E1.
6. [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:317 — precedence between a move, an undo and the deleted-note rule could not be read from `noteID`. Codex 3.
7. [INFORMATIONAL] (confidence: 8/10) docs/product-spec.md:272 — `restore` had three meanings and a return had no precondition. Codex 4.
8. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:317 — a move could not outlive the purge of the note it left. Codex 5.
9. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:119 — a generated title had no recorded source, so it could not follow a recording reliably. Codex 6.
10. [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:315 — two devices could take a recording at the same generation. Codex 12.
11. [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:115 — text past the limit continued in a new segment, while a capture and its segment share one ID. Codex 13, Claude E5.
12. [INFORMATIONAL] (confidence: 8/10) docs/architecture.md:117 — a revision was a bare number and survived a restore that a cursor did not. Codex 14.
13. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:238 — a store call that the engine stopped waiting for could still commit. Codex 16, Claude A3.
14. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:261 — the app learned of a tool's write only from a notification posted after the commit. Codex 17.
15. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:260 — a restored copy could point at recordings purged since. Codex 15.
16. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:463 — a milestone build on the build Mac syncs the owner's notes onto it, and the other Mac had no way to receive a build. Codex 10, Claude H3.
17. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:394 — the early upload proved the direct route only. Codex 9.
18. [INFORMATIONAL] (confidence: 7/10) PLAN.md:891 — "the install over a development build" did not say which identifier. Codex 8.
19. [INFORMATIONAL] (confidence: 7/10) PLAN.md:793 — the in-memory `NoteStore` is a second implementation of every store rule. Claude A1.
20. [INFORMATIONAL] (confidence: 7/10) PLAN.md:793 — KnotCore's enums break every switch on a new case, and seven ports were unnamed. Claude A2.
21. [INFORMATIONAL] (confidence: 7/10) PLAN.md:812 — "the owner records and sees the capture listed on the Watch as saved" at M1 needs the outbox, which waited for SP-2. Claude A4.
22. [INFORMATIONAL] (confidence: 8/10) PLAN.md:815 — the start table predates WP-02's third PR and WP-06. Claude A5.
23. [INFORMATIONAL] (confidence: 7/10) PLAN.md:956 — kill tests had no executable to kill. Claude A6.
24. [INFORMATIONAL] (confidence: 7/10) PLAN.md:792 — the composition root had no owner after WP-22. Claude A7.
25. [INFORMATIONAL] (confidence: 6/10) docs/architecture.md:272 — a late heartbeat could turn a stop into a start. Medium confidence, verify this is actually an issue. Claude E4.
26. [INFORMATIONAL] (confidence: 7/10) PLAN.md:871 — SP-3 held three spikes. Claude H2.
27. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:330 — the purge trusted the device's clock. Claude E6.

Dispositions: all 27 accepted. Audit rows 224 to 250.

#### Code quality, second pass

1. [INFORMATIONAL] (confidence: 8/10) PLAN.md:990 — the fold of every amendment list into the briefs was one step of a package sized S, checked for presence only. Claude H1.
2. [INFORMATIONAL] (confidence: 8/10) docs/product-spec.md:38 — a negative gap of any size counted as inside the window. Claude E5.
3. [INFORMATIONAL] (confidence: 8/10) docs/product-spec.md:50 — a second typed capture on another surface was undefined. Claude E5.
4. [INFORMATIONAL] (confidence: 8/10) docs/product-spec.md:59 — whether text of only spaces is empty was undefined. Claude E5.
5. [INFORMATIONAL] (confidence: 9/10) docs/architecture.md:251 — asset folders named by the first two characters of a version 7 ID all land in one folder. Claude E7.
6. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:86 — a plain content hash in an exported row lets a short note be guessed. Claude S3.
7. [INFORMATIONAL] (confidence: 8/10) PLAN.md:755 — "signing" needs the owner's word while agents sign development builds, and the API key stayed readable until M7. Claude S2.
8. [INFORMATIONAL] (confidence: 8/10) PLAN.md:989 — `git clean -X` unscoped would remove `.gstack/` and `.conductor/`, and the second worktree's files collide with tracked names. Claude H4.
9. [INFORMATIONAL] (confidence: 8/10) PLAN.md:840 — the " 2" files are conflict copies from a file provider, and nothing stops the next one. Claude H4.
10. [INFORMATIONAL] (confidence: 6/10) docs/architecture.md:296 — cleanup had no fixed sampling and no record of the model's build. Medium confidence, verify this is actually an issue. Claude T6.

Dispositions: all 10 accepted. Audit rows 251 to 256.

#### Test review, second pass

**Coverage of what this pass and the owner's answers add.** Nothing is built, so "tested" means the plan names a test that would catch a regression. Stars rate the planned test.

```
CODE PATHS                                               USER FLOWS
[+] NoteStore: move and return                           [+] Repair a wrong grouping (iPhone, Mac)
  ├── [★★★ PLANNED] move and return leave both notes       ├── [★★★ PLANNED] move, then undo, UI smoke
  ├── [★★★ PLANNED] refused: open, deleted, copy, alone    ├── [★★  PLANNED] the action is offered or not
  ├── [★★★ PLANNED] a kill inside a move                   ├── [★★★ PLANNED] undo after the note was deleted
  ├── [GAP→ADDED] repeated after a capture joined          ├── [★★  PLANNED] M2 row: move and undo
  ├── [GAP→ADDED] return after the note changed again      └── [★★  PLANNED] M4 row: iPhone move shows on Mac
  ├── [GAP→ADDED] a generated title dropped and put back
  └── [GAP→ADDED] differential against the fake          [+] An agent moves a segment
                                                           ├── [★★★ PLANNED] six golden results
[+] Sync merge core                                        ├── [GAP→ADDED] a revision from before a restore
  ├── [★★★ PLANNED] two devices move the same segment      └── [GAP→ADDED] the goldens on the real store too
  ├── [★★★ PLANNED] a move meets a delete
  ├── [GAP→ADDED] every order across three replicas      [+] Replace the retired app (M1)
  ├── [GAP→ADDED] a move that arrives after the purge      ├── [★★★ PLANNED] the old files byte for byte
  ├── [GAP→ADDED] what a merge makes is uploaded           ├── [GAP→ADDED] the old keys keep their values
  ├── [GAP→ADDED] two owners at one generation             ├── [GAP→ADDED] three rows: Recovery, copy, quit
  ├── [GAP→ADDED] a zone removed and made again            └── [GAP→ADDED] install over the retired app
  ├── [GAP→ADDED] all replicas upload after a switch
  └── [GAP→ADDED] a clock 40 days ahead                  [+] The keep-gate week
                                                           ├── [GAP→ADDED] counters: each event counts once
[+] Capture engine and files                               ├── [GAP→ADDED] an M2 fix carries no M4 feature
  ├── [GAP→ADDED] a store call commits after fallback      └── [GAP→ADDED] milestone store: migrate, then suite
  ├── [GAP→ADDED] a long capture, repeated
  ├── [GAP→ADDED] a tool dies before its notice          [+] Recording on hardware
  └── [GAP→ADDED] a restore older than a purge             ├── [GAP→ADDED] AirPods, a call, Siri, an alarm
                                                           ├── [GAP→ADDED] unplugged microphone, sleep
[+] The checks themselves                                  └── [GAP→ADDED] 30 minutes, wrist down (SP-2)
  ├── [GAP→ADDED] four faults turn the soak red
  ├── [GAP→ADDED] three broken fakes fail the suite      Cleanup: [GAP→ADDED] [→EVAL] punctuation-only cases
  ├── [GAP→ADDED] Thread Sanitizer, nightly
  └── [GAP→ADDED] 30 minutes of frames in and out

COVERAGE BEFORE THIS PASS: 10/42 paths planned (24%)  |  Code paths: 5/26  |  User flows: 5/16
QUALITY: ★★★:7 ★★:3 ★:0  |  GAPS: 32 (1 eval), all added to the plan in this pass
```

Legend: ★★★ behavior + edge + error  |  ★★ happy path  |  ★ smoke check
[→E2E] = needs integration test  |  [→EVAL] = needs LLM eval  |  [GAP→ADDED] = a gap this pass closed in the plan

**Regression rule.** The retired app's files and keys are behaviour at risk with no coverage in the retired tree's terms, so the byte-for-byte test and the key test are required, and both are named.

**Evals.** The cleanup evaluation gains punctuation-only cases in its meaning-critical set. No prompt or instruction text changes in this pass.

**Test plan.** Written for the second pass on the build Mac, in gstack's folder for this project, as the engineering review's test plan of 2026-11-19, 10:12. The first pass's test plan stands beside it.

Dispositions: all 32 gaps accepted. Audit rows 257 to 262.

#### Performance, second pass

1. [INFORMATIONAL] (confidence: 6/10) docs/architecture.md:260 — seven daily copies of the database sit inside every device backup. At 20,000 segments of text that is a few megabytes each; scale unknown beyond that. Medium confidence, verify this is actually an issue. Claude E8.
2. [INFORMATIONAL] (confidence: 7/10) docs/architecture.md:332 — recordings and text share one iCloud quota, so a full quota stops text sync as well. Claude E8.

Checked and clear: the counter comparison once a minute is one read of one row. A move recomputes the latest-capture time of two notes, which is the indexed query the stream page already needs. The differential test and the four soak faults run in the package tests and at WP-06's merge, not in every gate.

Dispositions: finding 1 noted and left, because the copies are text only. Finding 2 accepted as a stated behaviour, audit row 255.

#### NOT in scope, second pass

- The two-day trial of the alternatives and the premise sitting in wave 0. Declined by the owner at the gate.
- A "handled" mark on a note. Declined for v1 by the owner, and looked at again at the keep-gate sitting.
- Merging notes, splitting a note at a point, and moving a segment into another existing note. Deferred to TODOS.md.
- Returning a move from a device other than the one that made it. The record of a move is local, as replaced text is.
- A stored operation ID for a move, and a stored source for a generated title. Codex asked for both. The plan reaches the same safety with a precondition and with the words rule, and the choice is at the gate.
- A backup manifest that pins recordings to a database copy. A restored copy is stated as text only.
- Moving the owner's test recordings off the build Mac. At the gate.
- A separate macOS account for agent builds. Already deferred to TODOS.md.

#### What already exists, second pass

- The retired store's layout and its Recovery window, read above, are why v1 gets its own root folder and why the M1 rows clear three lists.
- `PersistenceFaultInjector` in the retired `CaptureStore.swift` is prior art for the four faults the soak must catch. WP-06 reads it, as WP-10 already does.
- `ownerGeneration` in docs/architecture.md §11 is the pattern `noteGeneration` reuses, with the tie-break that both now share.
- The words rule for a generated title in docs/architecture.md §9 is reused for a note that a segment leaves.
- `segment_history`, added by the DX review for replaced text, carries the record of a move.

#### Failure modes, second pass

| # | Path | Failure | Test | Handling | Seen by the user | Before this pass |
|---|---|---|---|---|---|---|
| 1 | `knot move` | The reply is lost, a capture joins the new note, the agent repeats | Golden and contract tests | The move names the note it saw | "Not in that note; it is in P" | **Critical gap** |
| 2 | Sync | A merge makes a conflict copy or a derived note | Named test | Queued for upload in its transaction | Nothing | **Critical gap** |
| 3 | First milestone install | The retired app's drafts are left behind | Container test; three M1 rows | Recovery cleared; a copy of the app kept | The rows | **Critical gap** |
| 4 | A fix during the keep-gate week | It carries sync before M4 | The gates-per-level test | The build's level | Nothing | **Critical gap** |
| 5 | A schema change after M2 | The owner's store no longer opens | Milestone stores: migrate, then the suite | A numbered migration; a lint | Nothing | **Critical gap** |
| 6 | A zone made again, or a new environment | Local notes read as deleted | Two simulation cases; a rehearsal | Zone identity; a pause that asks | A question | **Critical gap** |
| 7 | Two devices move one segment | Two notes for one segment | Simulation, three replicas | Generation, then the tie-break | One note | Stated without a version |
| 8 | A move after the purge | The segment does not return | Named test | The purge stands | The segment is gone, as deleted 30 days before | Unstated |
| 9 | The tool dies after its commit | The app shows stale notes | Named test | Counter compared on foreground and each minute | At most a minute late | Unhandled |
| 10 | The hold | M2 and M3 wait for held PRs | `check-plan.sh` fails on it | PRs named | Nothing | The graph had a cycle |
| 11 | A milestone build on the build Mac after M4 | The owner's notes sync onto it | None automated | Never installed there; a Mac path in the script | Nothing | Unhandled |

Six critical gaps, all closed in the plan. Row 11 rests on a rule and a script and has no automated test, and it is listed as an accepted risk.

#### Worktree parallelization, second pass

The ten lanes of the first pass stand. Three things change:

- Wave 1 has five spikes. SP-5 runs beside the others and needs the Mac only.
- WP-17's first PR joins the lane of WP-12 and runs before SP-2 reports.
- A held lane opens at the keep-gate ruling: the rest of WP-18, then WP-35; the fourth PR of WP-19; the second of WP-31; the third of WP-32; and wave 4.

Conflict flags: the move touches KnotCore (WP-02), KnotStore (WP-10), KnotSync (WP-16), KnotUI (WP-21) and KnotAgent (WP-34). Each owns its folder, and the contract arrives in WP-02's second PR, so none shares a file.

#### Implementation tasks, second pass

The first pass's nineteen tasks are carried. T19 is reworded, because the owner has now said which Mac holds real notes.

- [ ] **T20 (P1, human: ~1w / CC: ~4h)** — WP-00 — Split into the restart and the fold; add the "replaces" column; generate the start table and fail on a cycle; add D32 to D36 to §2
  - Surfaced by: Code quality 1; Scope Challenge 1; Claude H1 and A5; Codex 1
  - Files: docs/plan/, scripts/check-plan.sh
  - Verify: `scripts/check-plan.sh`
- [ ] **T21 (P1, human: ~1w / CC: ~4h)** — WP-02 — The move and its return in the contract; `noteGeneration`; continuation IDs; revisions with the generation; the three exact rules; seven ports; three broken fakes; the title rule in KnotCore
  - Surfaced by: Architecture 1, 6, 7, 9, 11, 12 and 20; Code quality 2 to 4
  - Files: Packages/KnotKit/Sources/KnotCore/, Packages/KnotKit/Sources/KnotFakes/, Packages/KnotKit/Sources/KnotTestSupport/
  - Verify: `scripts/verify.sh --quick`
- [ ] **T22 (P1, human: ~2w / CC: ~1d)** — WP-10 — The move, the history row and the counters; the `KnotStore/` root and the retired-container test; the schema freeze and the milestone stores; the differential test; the counter comparison; asset folders
  - Surfaced by: Architecture 3, 14, 15 and 19; Scope Challenge 2 and 3
  - Files: Packages/KnotKit/Sources/KnotStore/
  - Verify: `scripts/verify.sh --quick --module KnotStore`
- [ ] **T23 (P1, human: ~2w / CC: ~1d)** — WP-16, SP-4 — Merge by generation with both tie-breaks; upload what a merge makes; zone identity and the pause; server dates for the purge; the new simulation cases
  - Surfaced by: Architecture 2, 4, 6, 8, 10 and 27
  - Files: Packages/KnotKit/Sources/KnotSync/, docs/spikes/SP-4.md
  - Verify: `scripts/verify.sh --quick --module KnotSync`
- [ ] **T24 (P1, human: ~3d / CC: ~2h)** — WP-34, SP-3 — `knot move --from` and `--back` with six goldens; the goldens on both stores; SP-3 closed on the route that ships
  - Surfaced by: Architecture 1, 7, 12 and 17
  - Files: Packages/KnotKit/Sources/KnotAgent/, docs/cli.md, docs/spikes/SP-3.md
  - Verify: `scripts/verify.sh --quick --module KnotAgent`
- [ ] **T25 (P2, human: ~3d / CC: ~2h)** — WP-21, WP-30, WP-33 — The move action with its undo, the matrix row and the smoke tests
  - Surfaced by: The owner's answer on user challenge 4
  - Files: Packages/KnotKit/Sources/KnotUI/, Apps/iOS/, Apps/macOS/
  - Verify: `scripts/verify.sh --full`
- [ ] **T26 (P1, human: ~1w / CC: ~4h)** — WP-17, WP-32 — The outbox and the coordinator in KnotLink with kill points; acknowledge on a durable file; three PRs for WP-32
  - Surfaced by: Architecture 21; Scope Challenge 1
  - Files: Packages/KnotKit/Sources/KnotLink/, Apps/watchOS/
  - Verify: `scripts/verify.sh --quick --module KnotLink`
- [ ] **T27 (P1, human: ~1w / CC: ~4h)** — WP-01 — Crash hosts; the lints; the doctor's two new checks; the level of a milestone build; a Mac path in the install script; privacy manifests
  - Surfaced by: Architecture 5, 16 and 23; Code quality 8 and 9; Claude S1 and T4
  - Files: project.yml, scripts/, Packages/KnotKit/Package.swift
  - Verify: `scripts/verify.sh --quick`
- [ ] **T28 (P1, human: ~3d / CC: ~3h)** — WP-05, WP-06, WP-11 — Four faults that turn the soak red; one life for a capture across the store and the inbox
  - Surfaced by: Architecture 13; Claude T1
  - Files: Packages/KnotKit/Tests/KnotSoak/, Packages/KnotKit/Sources/KnotCapture/
  - Verify: `scripts/verify.sh --soak`
- [ ] **T29 (P2, human: ~1d / CC: ~1h)** — WP-04 — Checklist rows: the move, the audio events, the three rows for the retired app, the named installs at M1 and M7; punctuation-only cleanup cases
  - Surfaced by: Architecture 18; Claude T3; Codex 18
  - Files: docs/checklists/, Fixtures/
  - Verify: `knot-eval --set synthetic`
- [ ] **T30 (P1, human: ~1h / CC: n/a)** — Owner — The keep-gate sitting; at G1 the other Mac, unattended signing, the record for the development identifier and the key; before M1 the retired app's Recovery window
  - Surfaced by: The owner's answers; Scope Challenge 2; Claude T4 and H3
  - Files: docs/decisions/keep-gate.md
  - Verify: the G1 and M1 checklists
- [ ] **T31 (P2, human: ~3d / CC: ~2h)** — WP-22 — The counters in the diagnostics export; the test of gates per level; live entry points
  - Surfaced by: Architecture 5 and 24; Codex 19
  - Files: Packages/KnotKit/Sources/KnotApp/
  - Verify: `scripts/verify.sh --quick --module KnotApp`
- [ ] **T32 (P2, human: ~2d / CC: ~1h)** — SP-5 — The hotkey, the panel, the key state and clipped first words, as a spike of its own
  - Surfaced by: Architecture 26
  - Files: docs/spikes/SP-5.md
  - Verify: the SP-5 rows at G3
- [ ] **T33 (P2, human: ~2d / CC: ~1h)** — WP-12, WP-14 — The recorder decides in its own process; 30 minutes of frames; greedy sampling and the model's build
  - Surfaced by: Architecture 25; Code quality 10; Claude T2
  - Files: Packages/KnotKit/Sources/KnotAudio/, Packages/KnotKit/Sources/KnotCleanup/
  - Verify: `scripts/verify.sh --quick --module KnotAudio`

#### Unresolved decisions, second pass

None blocks the plan. Six are taste and go to gate revision 2: the reading of the owner's reply; how far the hold reaches; what the cut order says; a precondition or an operation ID for a move; the words rule or a stored source for a title; and the owner's test recordings on the build Mac. Seven premises wait for a spike, WP-01 or a checklist row, as listed under the reality rows.

#### Decision ledger, second pass

Every remedy in this pass was decided by principle under the pipeline's rules, and each cites its audit row. The checked rows are 211 to 262. Six are taste and go to the gate: 211, 213, 214, 225, 229 and 241.

Approval readiness: PASS

#### Completion summary, second pass

- Step 0: Scope Challenge — scope accepted as-is
- Reality rows: 7/7 required rows emitted, and 4 more by scope, 7 unverified premises
- Architecture Review: 27 issues found
- Code Quality Review: 10 issues found
- Test Review: diagram produced, 32 gaps identified
- Performance Review: 2 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 1 item added under the owner's answer, 15 in all; none added by this pass
- Failure modes: 6 critical gaps flagged, all closed in the plan
- Unresolved decisions: 6 in this pass, all taste for the gate
- Outside voice: Codex, completed
- Parallelization: 10 lanes as before, plus one held lane that opens at the keep-gate ruling
- Lake Score: N/A. Every choice was made by principle, and none was scored for completeness.

### Gate revision 2: the owner's answer

The gate of seven items went to the owner on 2026-11-19, after the second engineering pass. He replied `rec`.

| Item | Answer | What it settles |
|---|---|---|
| d27 | a | Milestone builds reuse `com.p3ob7o.knot`. The reading of his first reply is confirmed. |
| d28 | a | Both steps of the cut order wait for the keep-gate ruling. |
| d29 | a | The cut order stands as written: iPad Pencil first, then the system surfaces beyond the first of each kind. |
| d30 | a | `knot move` names the note the caller saw. There is no stored operation ID. |
| d31 | a | Titles stay, and a generated one that no longer fits is dropped. There is no stored source. |
| d32 | a | His test recordings stay on the build Mac. |
| p1 | b | The plan is approved as it stands. |

Every answer is what the plan already carried, so nothing was applied and no review ran again. The approved implementation plan is the one with SHA-256 `c5b522d326598f994df952d3e8d936d575199a3f5b488b080a3f5f18a272e463`. Audit row 263.

Two things the plan asks of the owner at G0 are still open: confirming the assumptions of docs/product-spec.md §16, which WP-02 turns into tests, and saying how many sittings a week he can give. Neither holds up WP-00 or WP-01.

### G0: the owner's answers on the assumptions

On 2026-11-19, after he had approved the plan, the owner answered the 34 assumptions of docs/product-spec.md §16. His message, in full:

> A2 → A5: OK
> A6: Watch doesn't show content, it's only a capture device.
> A7 → A26: OK
> A27: It should be possible to select multiple segments at once.
> A28 → A34: OK
> A35: For v1 yes. Later we'll expand cleanup abilities.
> A36 → A37: OK

| Assumption | Answer | What was done |
|---|---|---|
| 31 of the 34 | Confirmed | Their marks are gone from the spec, and §16 lists each as confirmed. |
| A6 | Changed | The Watch shows no note content. The spec, the back channel of docs/architecture.md §12 and the Watch states of the design brief follow. |
| A27 | Changed | Several segments can be selected at once and copied, shared or deleted together. The spec, the `NoteStore` contract of docs/architecture.md §5 and the design brief follow. |
| A35 | Confirmed for v1 | Nothing changes in v1. `TODOS.md` gains "Let cleanup do more". |

Applying A6 and A27 took a reading of each, and the two readings wait for him as A38 and A39. A38 keeps a list of the Watch's own recordings, by time, length and delivery state. A39 takes "select multiple segments" as whole segments, keeps a text selection inside its segment, and leaves "Move to its own note" at one segment.

No review ran on these changes. They sit in the fifth list of the implementation plan, between the markers `owner-answers:g0-assumptions`, and the fold's review reads them. The plan as approved is the one with SHA-256 `c5b522d326598f994df952d3e8d936d575199a3f5b488b080a3f5f18a272e463`. Since then the fifth list was added and one sentence of the approval note names it. Audit rows 264 and 265.

Three things are still open at G0: A38, A39, and how many sittings a week he can give. WP-02 does not start before he has answered A38 and A39.

<!-- AUTONOMOUS DECISION LOG -->
## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|----------------|-----------|-----------|----------|
| 1 | Intake | Skip the /office-hours offer | Mechanical | P6 | docs/product-spec.md was written today from three rounds of owner answers and serves as the design doc | Running /office-hours |
| 2 | CEO 0E | Review mode: SELECTIVE EXPANSION | Mechanical | /autoplan override | The pipeline fixes the mode | The other three modes |
| 3 | CEO 0G | C1: WP-02 proves the contracts compose before wave 2 | Mechanical | P1 | Ten packages build on contracts nobody has run end to end | A separate tracer package with real implementations: one more serial step for little extra proof |
| 4 | CEO 0B | C2: four packages read archived code as prior art | Mechanical | P4 | Working code exists for hotkeys, activation policy, draft saving and release | Copying the old code; ignoring it |
| 5 | CEO 0A | C3: real recordings gate M2 | Mechanical | P1 | A gate on synthetic voices does not measure the owner's speech | Keeping the recordings optional |
| 6 | CEO 0A | C4: correct the Watch-gap claim | Mechanical | P5 | The landscape check contradicts the spec's sentence | Leaving it |
| 7 | CEO 0C | C5: store engine and locale, allow re-transcription | Mechanical | P1 | D4 defers languages; old recordings should benefit when they arrive | Adding it with the second language |
| 8 | CEO 0A | C6: capture ledger invariant and soak test | Mechanical | P1 | "Nothing is lost" had no single measurable check | Per-package kill tests only |
| 9 | CEO 0A | C7: bound the owner's gate load | Mechanical | P3 | Eleven untimed checklists queue on one person | Leaving the gates unsized |
| 10 | CEO 0G | X2: drag a note out of the Mac window | Taste | P2 | Small, inside WP-33, no new control, matches D31 | Deferring it to the design round |
| 11 | CEO 0G | X1: word-tap playback deferred | Mechanical | P3 | Needs stored word timings, outside this plan's blast radius | Adding it now |
| 12 | CEO 0G | X3: Spotlight indexing deferred | Taste | P3 | It puts note text in the system index, a privacy call for the owner | Adding it now |
| 13 | CEO 0G | X4: note-ready hook deferred | Mechanical | P3 | A new setting and sandbox questions; the CLI gives agents pull access in v1 | Adding it now |
| 14 | CEO 0G | X5: Handoff deferred | Mechanical | P3 | It depends on sync being on and stable | Adding it now |
| 15 | CEO 0G | X6: Services menu and share sheet deferred | Mechanical | P3 | A new extension target; the spec already lists it as not in v1 | Adding it now |
| 16 | CEO 0H | S1.1: the capture ledger gets a `capture` table and defined outcomes | Mechanical | P1 | The invariant had nothing to count | Dropping the invariant |
| 17 | CEO 0H | S1.2: cross-device processing rules | Mechanical | P5 | Two devices finishing one segment would create conflict copies | Leaving it to WP-16 |
| 18 | CEO 0H | S1.3: the brief gains eight missing states | Mechanical | P1 | One design round is budgeted, so the brief must be complete | A second design round |
| 19 | CEO 0H | S1.4: archive the nine " 2" files; decide the bundle ID at G1 | Mechanical | P1 | Six of the nine differ from their originals; the bundle ID is the retired app's | Deleting them unarchived |
| 20 | CEO 0H | S2.1: WP-05 Capture tracer replaces the test inside WP-02 | Taste | P1 | A test through fakes alone proves that fakes compose with fakes | Reference implementations in KnotTesting, with WP-02 grown to L |
| 21 | CEO 0H | S2.2: merge criteria split from milestone evidence; one owner per milestone | Mechanical | P5 | Three packages could not merge until packages that depend on them had shipped | Leaving the lists as written |
| 22 | CEO 0H | S2.3: keep transcript metadata, defer re-transcription | Mechanical | P3 | No trigger and no consumer in v1, and it contradicted "never modified" | Transcript versions in v1 |
| 23 | CEO 0H | S2.4: one table of start and second-PR conditions | Mechanical | P5 | The headers disagreed with the spikes | Fixing headers one by one |
| 24 | CEO 0H | S2.5: real recordings through local commands, with first thresholds | Mechanical | P1 | The first version broke the synthetic-fixtures rule and set no bar | Dropping real recordings |
| 25 | CEO 0H | S2.6: an owner calendar with minutes | Mechanical | P3 | A 20-row cap could not hold the spike checks | Keeping the cap |
| 26 | CEO 0H | S2.7: `AppEnvironment` in KnotCore; three ports added | Mechanical | P5 | The module graph had a cycle | Letting KnotUI depend on KnotApp |
| 27 | CEO 0H | S3.1: the CLI and MCP contract goes to the DX review | Mechanical | P6 | That phase exists for it | Deciding it here |
| 28 | CEO 0H | S3.2: rules 9 to 12, the one-second discard and the hotkey timing | Taste | P5 | WP-02 and WP-33 must encode them; opening the microphone at key-down would interrupt Bluetooth audio on every tap | Microphone from key-down, which never clips the first word |
| 29 | CEO 0H | S4.1: the note entity is not indexed | Mechanical | P4 | X3 was deferred, and the text still named Spotlight | Indexing by default |
| 30 | CEO 0H | S4.2: drag-out specified; the Duo path stays as D7 says | Mechanical | P5 | D7 is the owner's decision; the alternative goes to the gate | Shipping the Duo path switched off |
| 31 | CEO 0H | S5.1: four more spike questions; SP-3 on a development-signed build | Mechanical | P1 | The spikes did not ask what M2 and `knot export` rest on | A signed upload in wave 1 |
| 32 | CEO 0H | S5.2: the iOS database moves to the app's own container | Mechanical | P5 | iOS kills a suspended process that holds a lock on a database in a shared container | Suspension handling in WP-10 |
| 33 | CEO 0H | S5.3: soak nightly and per milestone; models required at the merge gate | Mechanical | P3 | A 500-capture soak on each of 46 merges is unpriced | Soak in every `--full` run |
| 34 | CEO 0H | S5.4: the design direction comes first | Taste | P1 | Structure questions are not restyling; the brief is already drafted | Building default screens now and restyling later |
| 35 | CEO 0H | S5.5: an availability rule and a release Xcode check | Mechanical | P1 | Only a beta Xcode is installed | Finding out at M7 |
| 36 | CEO 0H | T1: WP-22 ships in two PRs and its composition PR owns M1 | Mechanical | P5 | The package that owned M1 could not start until all of wave 2 had landed | A separate composition package |
| 37 | CEO 0H | T2: the CloudKit production schema is deployed only after M5 | Mechanical | P1 | That schema can never drop a field, and its hardware evidence comes at M4 and M5 | Approval before WP-16's hardware rows |
| 38 | CEO 0H | T3: hold-to-record is exempt from the one-second discard; the microphone opens at key-down on built-in and wired inputs | Taste | P1 | A held note under about 1.3 seconds left nothing, with no feedback | Keeping one rule for taps and holds |
| 39 | CEO 0H | T4: cleanup pairs go to a git-ignored file; PR examples stay synthetic | Mechanical | P5 | The repo is public and the pairs hold the owner's speech | Ten real examples in the PR |
| 40 | CEO 0H | T5: if the bundle ID is reused, v1 uses a new subfolder and defaults suite and refuses a database it did not create | Mechanical | P1 | The same ID gives the new app the retired app's container | Assuming a new ID |
| 41 | CEO 0H | T6: `.preview` is the real engine over the fakes, delivered by WP-05 | Mechanical | P5 | The engine and the queue have no fake | Faking the engine |
| 42 | CEO 0H | T7: the direction is recorded in `docs/design/direction.md`; watch and iPad structure is provisional | Mechanical | P5 | The rule and its table disagreed, and the direction step covers two surfaces only | Widening the direction step to four devices |
| 43 | CEO 0H | T8: every port has a named implementer | Mechanical | P1 | Four ports had none, and `.live` needs them | Leaving it to WP-22 |
| 44 | CEO 0H | T9: a segment appended to a note deleted on another device moves to a new note | Mechanical | P1 | It would be hidden and purged after 30 days | Restoring the deleted note |
| 45 | CEO 0H | T10: a typed capture starts at its first keystroke | Mechanical | P5 | Starting when the surface appears would write empty rows and move the append decision | Starting when the surface appears |
| 46 | CEO 0H | T11: crash recovery covers typed drafts and drawings | Mechanical | P1 | The soak test kills all three kinds, and only recordings had a recovery rule | Recovery for recordings only |
| 47 | CEO 0H | T12: store freshness joins the CLI and MCP contract in the DX review | Mechanical | P6 | That phase owns the contract | Deciding it here |
| 48 | CEO 0H | T13: four owner duties added, gate IDs kept, a milestone-evidence column | Mechanical | P1 | The calendar omitted reading the spike reports and confirming the assumptions | A calendar without gate IDs |
| 49 | CEO 0H | T14: the capture ledger's five open questions are answered in rule 6 | Mechanical | P5 | No port carried capture rows, and `failed` was final while the spec retries | Leaving them to WP-10 |
| 50 | CEO 0H | T15: `closedAt` and `processingOwner` added to the domain model | Mechanical | P5 | Rule 10 and the ownership rule could not be expressed | Deriving both at run time |
| 51 | CEO 0H | T16: decision rows added to the CEO scope summary; watch playback at M1 removed | Mechanical | P3 | Playback was new behaviour nobody had decided | Keeping playback as a debug control |
| 52 | CEO 0H | T17: WP-02 and WP-22 resized to L | Mechanical | P5 | WP-02 now carries 18 ports and 14 rules | Leaving the sizes |
| 53 | CEO 0H | T18: the iPhone Duo canvas is not decided here | User Challenge candidate | None | D7 is the owner's decision. Two spec reviewers recommend iPad only. It becomes a User Challenge if both CEO voices agree, and goes to the final gate either way. | Changing D7 without the owner |
| 54 | CEO 0H | T19: one internal TestFlight upload of the SP-3 spike app in wave 1, if authorised | Taste | P1 | Container access depends on signing, and the check otherwise waits for M7 | Waiting for M7 without saying so |
| 55 | CEO 0H | T20: the soak's fakes stated, an exclusive Mac UI-test slot, a `--gate` mode | Mechanical | P3 | 500 captures in 3 minutes needs scripted engines, and two worktrees cannot share one desktop session | Soak in every `--full` run |
| 56 | CEO 0H | U1: development identifiers for every build that is not a milestone build | Mechanical | P1 | A branch build could migrate the owner's Mac database or sync test notes into his stream | Relying on "synthetic fixtures only" |
| 57 | CEO 0H | U2: data is disposable until M2 on iPhone and iPad and until M4 on the Mac | Mechanical | P5 | No rule said when a schema change needs a migration | Migrations from the first PR |
| 58 | CEO 0H | U3: the replacement note's ID is derived from the deleted note's ID | Mechanical | P5 | Deriving it from each segment split one note into several | One note per segment |
| 59 | CEO 0H | U4: spec §4.4, rule 14, the `RecordingActivity` port and export of remote attachments | Mechanical | P1 | Five edge cases had no stated behaviour | Leaving them to the implementers |
| 60 | CEO 0H | U5: a per-platform intent table; ToggleRecording; WP-19 in three PRs | Mechanical | P5 | The table promised protocols that the Watch and the Mac do not have | One intent set for every platform |
| 61 | CEO 0H | U6: one `NoteStore` operation records a capture for the engine and for `knot` | Mechanical | P4 | The capture sequence would otherwise exist twice | KnotAgent depending on KnotCapture |
| 62 | CEO 0H | U7: the start table names a PR for every dependency, and spikes are confirmed one by one | Mechanical | P5 | Read literally, iPhone M2 waited for the Mac and CloudKit spikes | Leaving "WP-10 to WP-15" |
| 63 | CEO 0H | U8: assumptions A18 to A24 added; counts and stale lines corrected | Mechanical | P5 | The owner confirms §16 before WP-02 turns it into tests | Leaving the rules unmarked |
| 64 | CEO 0H | U9: the hotkey's first 250 ms as a timeline table | Taste | P5 | A tap would otherwise open the microphone and light the system indicator | Opening the panel at key-down |
| 65 | CEO 0H | U10: `CaptureEngine` publishes the saved revision; the soak harness is a child process | Mechanical | P5 | The test asserted on "acknowledged" with no contract behind it | Asserting on row counts only |
| 66 | CEO 0H | U11: the milestone-evidence rule extended; three path-ownership exceptions | Mechanical | P5 | Three merge criteria still needed the owner | Leaving them as merge criteria |
| 67 | CEO 0H | U12: `knot-eval` declared and owned; no nightly soak run | Mechanical | P3 | A target and a scheduled run had no owner | A nightly runner |
| 68 | CEO 0H | U13: KnotFakes, KnotTestSupport and KnotUIPreviews replace KnotTesting | Mechanical | P5 | A module that hosts test suites cannot be linked into an app | Conditional compilation inside one module |
| 69 | CEO 0H | U14: the hotkey and panel proof moves into SP-3; the release Xcode is installed at G1 | Mechanical | P1 | Three facts were proven after the work that depends on them | Proving the hotkey in WP-33 |
| 70 | CEO 0H | U15: the owner calendar resized to about 13 hours | Mechanical | P3 | 20 minutes per milestone did not fit M2, M4 or M6 | Keeping one figure for every milestone |
| 71 | CEO 0H | Close the spec review loop at its cap; spec not re-verified | Mechanical | P6 | Three launches is the cap. Fixes verified against the text: 15 of 15. The dual voices and three more phases follow. | A fourth launch |
| 72 | CEO 0H | Approve the scope documents and continue to 0I | Mechanical | P6 | The summary and the amended plan state the same decisions | Revising again before the dual voices |
| 73 | CEO 0I | WP-14 states the fidelity guard's allowed differences as a table | Mechanical | P5 | "Changes the words" was undefined for case, punctuation and numbers, and the pass rate depends on it | Leaving the guard's rule to the implementer |
| 74 | CEO 0I | `scripts/install.sh` installs builds on the paired devices; the spikes record the procedure | Mechanical | P1 | Eleven sittings need a build on up to five devices, and no package owned that | The owner installing each build by hand from Xcode |
| 75 | CEO voices | UC1: prove it before building all of it | User Challenge | None | Both voices recommend it, and it changes D16 and the parallel build. The owner decides at the final gate. | Deciding it here, either way |
| 76 | CEO voices | UC2: treat sync as core, bring it forward, settle the paywall idea | User Challenge | None | Both voices recommend it, and it changes D18 and the order of D16. | Deciding it here |
| 77 | CEO voices | UC3: decide what happens to a note after capture | User Challenge | None | Both voices recommend adding a state that D21's minimalism excludes. | Deciding it here |
| 78 | CEO voices | UC4: a repair for a wrong grouping | User Challenge | None | Both voices recommend a feature that docs/product-spec.md §15 excludes. | Deciding it here |
| 79 | CEO voices | V1: recordings in wave 0, and the proof steps run on real speech | Mechanical | P1 | A premise about the owner's own voice should be tested before the contracts are fixed | Recording before WP-14's evaluation |
| 80 | CEO voices | V2: §16 marks costly assumptions and gives a worked example for each | Mechanical | P5 | 23 assumptions confirmed in one sitting need to be readable as consequences | A flat list |
| 81 | CEO voices | V3: the calendar takes a cadence, three repeats for M2 to M4, and free-form notes | Mechanical | P1 | One repeat per milestone was optimistic for locked-phone, watch and sync work | One repeat each |
| 82 | CEO voices | V4: a diagnostics export in test builds; measured latencies on the M2 and M4 checklists | Mechanical | P2 | A failed row should be diagnosable without another sitting | Diagnosing from a description |
| 83 | CEO voices | V5: SP-4 asks whether an existing sync layer fits | Mechanical | P1 | The riskiest package was priced only as a hand build | Not asking |
| 84 | CEO voices | V6: meaning-critical cleanup cases are reported separately | Mechanical | P1 | A word-level guard does not see a changed negation or amount | One pass rate for all cases |
| 85 | CEO voices | V7: a Watch target from stop to transcript, measured at M3 | Mechanical | P1 | A recording can be durable and still arrive too late to matter | Component targets only |
| 86 | CEO voices | V8: backups stated and tested; importing an export deferred | Taste | P3 | Device backups, iCloud and the migration copy cover restore in v1. Codex asked for restore through export. | Building import now |
| 87 | CEO voices | V9: re-transcription stays deferred | Taste | P3 | It can be added later without a schema break. Codex wants the path defined now. | Transcript versions in v1 |
| 88 | CEO voices | V10: the recommendation at G1 becomes a new bundle identifier | Taste | P5 | The retired app keeps working beside milestone builds, and no special-case code is needed | Reusing the retired app's identifier |
| 89 | CEO voices | V11: the Mac microphone opens at the 250 ms mark of a hold, never on a tap | Taste | P5 | Listening on every tap lights the microphone indicator each time the owner types. Reverses the key-down part of decision 38. | Listening from key-down, which never clips a first word |
| 90 | CEO voices | V12: M4 begins with an agent filing a phone capture; the contract gains a settled state and a change cursor | Mechanical | P1 | The agent path is the one way notes leave without a hand | Testing the command alone |
| 91 | CEO voices | V13: the README says what happened to the Obsidian capture app | Mechanical | P5 | Two tags describe a different product under the same name | Saying nothing |
| 92 | CEO voices | V14: the full design round is not split in two | Taste | P3 | WP-40 already applies the handoff per platform as soon as it exists. The Claude voice wanted two surfaces designed in full first. | A second ordering rule |
| 93 | CEO voices | V15: a write-once outbox folder is not added | Taste | P4 | D25 is the owner's explicit decision and one voice asked. It is offered inside UC3. | Adding a delivery folder |
| 94 | CEO S1 | Intents use the dependency manager; job states named; unknown kinds kept | Mechanical | P5 | Three things an implementer would have had to guess | Leaving them to WP-02 and WP-19 |
| 95 | CEO S1 | An older build refuses a newer database; the pre-migration copy is kept until the following migration | Mechanical | P1 | After M2 a rollback had no path | Dropping the copy after one launch |
| 96 | CEO S2 | C40: when the store cannot be opened, capture continues into `Inbox/` | Mechanical | P1 | The fallback already existed for a failed write; the worst moment to lose a thought is when the store is down | A blocking error screen |
| 97 | CEO S2 | Rules for an unreadable inbox item, a checksum mismatch, a removed zone, a failed conversion, a model not ready, a failing job, an interrupted transcription and a failed launch step | Mechanical | P1 | None had stated behaviour, and two were silent | Leaving them to each package |
| 98 | CEO S2 | A missed hotkey release, a taken key and a stale recording state | Mechanical | P1 | A missed release would record until the 30-minute limit | Trusting the release event |
| 99 | CEO S3 | Command-line access is off until the owner turns it on | Mechanical | P1 | The bundled tool was a door past the container protection for any local process | On by default |
| 100 | CEO S3 | The URL scheme only navigates; search text is quoted; titles are limited; the privacy text is checked | Mechanical | P5 | Four small surfaces with no stated rule | Leaving them open |
| 101 | CEO S4 | Rule 15: one capture open at a time on a device | Taste | P5 | Overlapping captures had no rule. Sketching while recording is the use it rules out. | Allowing overlap |
| 102 | CEO S4 | A negative gap appends; the 30-minute limit gives a cue | Mechanical | P5 | Two edge cases with no answer | Leaving them open |
| 103 | CEO S6 | 15 failure tests named with owners; evaluations rerun when the cleanup or speech settings change | Mechanical | P1 | They follow from accepted behaviour and were named nowhere | Leaving them implied |
| 104 | CEO S7 | A stream page is one query with shown plans; the working file's size is reported; launch steps follow the first frame | Mechanical | P1 | Three places where the targets could quietly fail | Measuring in WP-42 only |
| 105 | CEO S8 | The capture ID on every log line; a troubleshooting guide in WP-43 | Mechanical | P1 | No telemetry exists, so local evidence must be complete | Logs without a common ID |
| 106 | CEO S9 | Five smoke rows at M7; rollback steps written down | Mechanical | P1 | The first minutes after the TestFlight install had no checks | Finding out by use |
| 107 | CEO S10 | X9: storage management for recordings deferred | Mechanical | P3 | A concern at one year, not at launch | Adding it to v1 |
| 108 | CEO S11 | Six states, an eighth question and a touch-target rule in the brief; WP-40 writes `DESIGN.md` | Mechanical | P1 | One design round is budgeted, and the later design reviews need a reference | A second design round |
| 109 | CEO S1 | The review record leaves PLAN.md after approval | Mechanical | P5 | Every implementing agent reads PLAN.md | Keeping the record in the plan |
| 110 | CEO S5 | The append rule as ordered small rules; the error taxonomy by case | Mechanical | P5 | Fifteen rules in one function would branch far more than five times | One function |
| 111 | Design 0 | No mockups from gstack's designer | Taste | P4 | Claude Design is the visual source by D13, and its direction step already offers the owner a choice | Generating a second set of directions with another tool |
| 112 | Design P1 | Rule 4 says where "New note" is; four surfaces show "continues a note" or "new note" without text | Mechanical | P5 | The rule promised an action that four entry points do not have | Leaving the promise as written |
| 113 | Design P1 | The editing model: a stack of segments, no selection across them, the capture field last (A27) | Mechanical | P5 | Both voices found that view models would be built on an undecided model | Leaving it to the design round |
| 114 | Design P1 | The capture surface follows the window; the destination is fixed at the first keystroke | Mechanical | P5 | The note shown could differ from the note joined | Fixing the destination when the surface appears |
| 115 | Design P1 | Stream row and title rules; a title only when the first segment is a recording (changes A10) | Mechanical | P5 | Five row elements had no priority, and a generated title could replace the user's own first line | A title for any note with a recording |
| 116 | Design P1 | A Search action, control and widget target; directions scored on three tasks | Mechanical | P2 | Knot is where the notes live, and every entry led to capture | Search only inside the app |
| 117 | Design P2 | A state matrix in the brief, with 19 more states and one preview per cell | Mechanical | P1 | Several states existed for one device only, and nothing checked coverage | Longer lists |
| 118 | Design P2 | Six user-facing states for a voice segment | Mechanical | P5 | "Pending" covered safe, usable and stuck alike | One pending marker |
| 119 | Design P3 | A local `arrivedAt`, an arrival mark and one line in the stream | Mechanical | P1 | Both voices: a late capture is placed correctly and then cannot be found | Moving late captures to the top |
| 120 | Design P3 | Cues for six events on three devices (spec §4.5) | Mechanical | P1 | Eyes-free capture had cues for two events on two devices | Leaving cues to each app package |
| 121 | Design P3 | SP-1 reports the feedback flow for each entry state; the brief asks for both branches of three spike-dependent surfaces | Mechanical | P1 | A failed start relied on a surface that can be off | Running the design round after the spikes |
| 122 | Design P3 | The first-run stream says sync is on, and may carry three dismissible setup rows (A29) | Taste | P1 | Notes upload with no prompt, so it must be said once. The rows come close to the walkthrough the owner ruled out. | No first-run content |
| 123 | Design P4 | Launchers may show state without text | Mechanical | P5 | It is the one place a Watch wearer would see that delivery is stuck | Launchers that show nothing |
| 124 | Design P4 | The system font stays the default | Taste | P5 | The rule against system fonts is written for the web; this app is meant to belong to its operating system | Requiring a custom typeface |
| 125 | Design P5 | The system component wins over the mock; mapping rules; `docs/design/deltas.md`; WP-40 owns the view models it must change | Mechanical | P5 | WP-40 was planned as restyling while layout and navigation are open | Pixel-matching the prototype |
| 126 | Design P5 | `docs/design/direction.md` has defined content with four structure sheets; the handoff is checked against the matrix | Mechanical | P5 | Both voices: a visual direction does not approve the interaction model | A direction that only records a choice |
| 127 | Design P6 | Layout rules when two columns do not fit; narrow, keyboard-up and largest-text versions in the brief | Mechanical | P5 | Fixed device screenshots do not describe adaptive layouts | Leaving it to WP-35 |
| 128 | Design P6 | Accessibility as behaviour in spec §13; a VoiceOver row per capture path at M2 to M5 | Mechanical | P1 | Both voices: it was verified last and specified as visuals only | Checking it in WP-41 alone |
| 129 | Design P6 | A microphone control in the Mac panel and window (A30) | Taste | P1 | Recording on the Mac otherwise needs a key held for the whole recording. It adds a control to a surface the owner wants minimal. | The hotkey as the only way |
| 130 | Design P6 | On the iPad capture surface the Pencil always draws, and a drawing never ends by accident; the panel's focus rule; a click on the menu bar icon opens the menu | Mechanical | P5 | Four interaction rules an implementer would have had to guess | Leaving them to WP-33 and WP-35 |
| 131 | Design P7 | A finished drawing is not reopened in v1 (A28) | Taste | P5 | Reopening needs a sync rule for two edits of one file | A reopen transition in v1 |
| 132 | Design P7 | A silent recording is not stopped automatically | Taste | P1 | A false stop would lose what is said next, which breaks "nothing is lost" | Stopping after 20 seconds with no speech |
| 133 | DX 0 | Persona: an agent acting for the owner, then the owner at a terminal | Mechanical | P6 | The plan's own M4 row is "use `knot` and the MCP server from Claude Code" | A human developer as the main reader |
| 134 | DX 0 | Target: 2 minutes from the Settings switch to a note read by an agent | Mechanical | P5 | Three steps, and the closest peers take about that long | The 5-minute tier |
| 135 | DX 0 | The magical moment is delivered by the M4 first row and a three-command quick start | Mechanical | P5 | It needs nothing the plan does not already have | A hosted demo |
| 136 | DX P2 | Text is a required argument; `-` reads standard input; `--json` on every command; suffix IDs; writes return what they made | Mechanical | P5 | Both voices: a missing argument could hang an agent or erase a title | Optional text that falls back to standard input |
| 137 | DX P2 | `knot changes --after <cursor>`, over a change counter in the store from schema version 1 | Mechanical | P1 | Both voices: polling by time misses a late Watch recording | `--since` on capture time |
| 138 | DX P2 | `--capture-id` makes `add` and `append` safe to repeat | Mechanical | P1 | Both voices: a retry after a lost response doubled the note | Checking by hand before a retry |
| 139 | DX P2 | `--if-revision` on `edit` and `title`; `--clear` for a title | Mechanical | P1 | Both voices: nothing protected the owner's own edit | Last write wins |
| 140 | DX P2 | Text replaced through the command line is kept 30 days and can be restored (A33) | Taste | P1 | An agent's edit was the one agent action that could not be undone. It adds a local table. | Trusting the revision check alone |
| 141 | DX P2 | Each note says whether it is settled; each result says how current the store is | Mechanical | P5 | Both voices: "ready", "settled" and "current" are three facts | One "pending" flag |
| 142 | DX P2 | No `--queue` flag and no `show --wait` in v1 | Taste | P3 | A retry with a capture ID and a poll on changes cover both | Adding both now |
| 143 | DX P3 | One error mechanism, from the taxonomy to the command line, MCP, logs and scripts | Mechanical | P1 | 28 of 125 applicable items were specified, and two paths blocked an agent | A message per path, written by each package |
| 144 | DX P3 | Exit codes 0 to 8, with the string code as the contract | Mechanical | P5 | Scripts branch on the class and agents on the code | Many exit codes |
| 145 | DX P2 | The MCP server speaks the 2026-07-28 revision and two handshake revisions, and checks access and schema on every call | Mechanical | P1 | The plan tested a handshake the current revision removed, and called a long-lived server short-lived | One revision |
| 146 | DX P1 | WP-34 is L in three PRs, written against the port, starting after WP-05 | Mechanical | P5 | It was sized M and started last, with a contract that shapes WP-02 | One PR at M4 |
| 147 | DX P6 | `.xcode-version`, `doctor.sh`, one tier per verify run, `lib/fail.sh`, a local build configuration, a store per worktree | Mechanical | P5 | The scripts relied on every agent remembering a prefix, and worktrees shared one store | Leaving it to WP-01 |
| 148 | DX P6 | The owner enables Automation Mode once at G1 | Mechanical | P6 | Checked on this Mac: Mac UI tests would wait on a password dialog | Skipping Mac UI tests for good |
| 149 | DX P4 | One brief file per package, a script that checks them, and result codes in the hand-back | Mechanical | P5 | A package's brief sat in three places, and the prompt hid two | Folding into PLAN.md only |
| 150 | DX P5 | A restore moves the current store aside; JSON, flags and codes get a compatibility rule | Mechanical | P1 | Codex: the prescribed rollback could discard newer work | Restoring in place |
| 151 | DX P6 | The recordings folder sits outside worktrees; contributors run the synthetic evaluation and the gate runs the local one | Mechanical | P5 | Worktrees do not share git-ignored files, and a contributor has no recordings | The folder inside the repository |
| 152 | DX P8 | The path is timed at M4, and `/devex-review` runs there | Mechanical | P5 | No telemetry exists by decision | No measurement |
| 153 | DX P7 | No community channel in v1 | Mechanical | P3 | Knot is for one user to begin with (D12) | Opening discussions now |
| 154 | DX P2 | Shortcuts get StartRecording and StopRecording on every platform | Mechanical | P5 | A toggle in an automation stops a recording it meant to start | ToggleRecording only |
| 155 | Eng 0 | Keep the original arrangement of 19 package targets | Mechanical | P5 | The smaller arrangement breaks three commitments: a release free of the test framework, a platform list per module, one folder per agent | Folding to about 11 targets |
| 156 | Eng 0 | Scope accepted as-is | Mechanical | /autoplan override | The pipeline never reduces scope in this phase | Any cut |
| 157 | Eng S1 | Durability stated in three cases; `fullfsync` on and measured; a recording synced every second | Taste | P1 | Both voices and this review found the promise untested, and the system SQLite leaves the flag off | Narrowing the promise to a crash and a kill |
| 158 | Eng S1 | The engine never waits for the store: 100 ms, then the manifest in `Inbox/` | Mechanical | P1 | A cold launch, a migration and a held lock all open the gap | Waiting for the store |
| 159 | Eng S1 | Checkpoints are their own store operation, ordered by revision | Mechanical | P5 | Idempotent creation would drop a newer checkpoint | One operation for both |
| 160 | Eng S1 | A press on a stale recording state starts a new recording, judged by a heartbeat | Taste | P1 | A start taken for a stop loses the thought; a stop taken for a start leaves a clip | The earlier rule that such a press starts nothing |
| 161 | Eng S1 | Jobs count attempts, deferrals and deaths apart; launch steps get a breaker | Mechanical | P1 | An interruption is not a failure, and a crashing input must not restart for ever | One counter |
| 162 | Eng S1 | The store decides the append rule; the engine passes placement only | Mechanical | P5 | One rule with two owners drifts | The rule in the engine's session tracker |
| 163 | Eng S1 | Device rules and remote changes go through store transactions; KnotSync issues no SQL | Mechanical | P5 | The invariants span two processes | Each caller checking |
| 164 | Eng S1 | Ownership generation; conflict copies with derived IDs and text only | Mechanical | P1 | Two devices could both publish, and a replay could duplicate | The device ID alone |
| 165 | Eng S1 | Tombstones outlive the purge; a long absence has a rule; SP-4 fixes the mechanism | Mechanical | P1 | A returning device could bring back a purged note | Purging everything |
| 166 | Eng S1 | Assets carry a publication state and a durable upload queue | Mechanical | P1 | A segment can sync before its file | Implicit ordering |
| 167 | Eng S1 | Sync state per account and environment, with an account generation | Mechanical | P1 | Queued work must not reach another account | The consent prompt alone |
| 168 | Eng S1 | Only the app migrates; a checked copy by `VACUUM INTO`; a restore mints a generation | Mechanical | P1 | A file copy of a WAL database is unsafe, and an old counter revives old cursors | Either process migrating |
| 169 | Eng S1 | Daily local copies, seven kept; export and restore in About | Taste | P2 | From M2 the phone holds the only copy until sync lands | The pre-migration copy alone |
| 170 | Eng S1 | `change_log` holds one row per record; its triggers are off while sync applies | Mechanical | P5 | It grows for ever with sync off and echoes fetched changes | An append-only log |
| 171 | Eng S1 | The watch acknowledges only a verified file | Mechanical | P1 | An acknowledgement after a damaged copy could delete the good one | Acknowledging on the third mismatch |
| 172 | Eng S1 | Sizes bounded; longer text continues in a new segment | Mechanical | P1 | CloudKit refuses an oversized record on every attempt | No limit; truncation |
| 173 | Eng S1 | Install ID in the Keychain; automatic takeover deferred | Mechanical | P3 | A restored phone must not act as the old one, and A19 stays the owner's | An automatic lease now |
| 174 | Eng S1 | Proof steps and spike code start beside WP-02's first PR, with port-fit notes | Mechanical | P3 | Ports frozen before first use of new APIs mean contract churn | Proofs after the contracts |
| 175 | Eng S1 | One home in KnotCore for the manifest, locations, file placement, the six states and the settled rule | Mechanical | P4 | Each lived in two or three modules | A copy per module |
| 176 | Eng S1 | Agents use `knot-dev`, `KNOT_AGENT=1` refuses the real store, and the owner says which Mac holds notes | Taste | P5 | Flavours stop builds, not agents; Codex asks for a separate account | A separate macOS account now |
| 177 | Eng S1 | A fuller ruleset on `main`, an interaction limit, and no pull-request comments read by agents | Mechanical | P1 | Protection was prose on a public repository | Convention alone |
| 178 | Eng S1 | No hardware microphone in tests or in proofs run by agents | Mechanical | P1 | The build Mac's default input is live | Measuring latency on the real input |
| 179 | Eng S1 | The team ID lives in a local file outside the worktrees | Mechanical | P5 | It ties the repository to one account, and worktrees do not carry ignored files | Committing it |
| 180 | Eng S1 | XPC only if SP-3 fails in wave 1; the early upload is recommended as required | Taste | P1 | Both voices: a fallback at M7 reopens the architecture. The upload needs the owner's word | Leaving the check to M7 |
| 181 | Eng S1 | WP-01 proves the packaging and the contract-suite arrangement | Mechanical | P1 | Both fail in wave 3 otherwise | Placeholder apps only |
| 182 | Eng S2 | WP-01 writes the factory so that WP-05 edits only its folder | Mechanical | P5 | An agent that keeps to its paths would stop | A shared-file request |
| 183 | Eng S2 | A release check for KnotFakes, the import check and the API check | Mechanical | P5 | SwiftPM cannot say "debug only", and the module rules had no check | Review alone |
| 184 | Eng S2 | WP-01 in two PRs, WP-02 in three | Mechanical | P3 | Both sit alone on the serial chain | One PR each |
| 185 | Eng S2 | An amendments map and a named-tests list, checked by script | Mechanical | P1 | About 140 items are folded by hand | A headings check only |
| 186 | Eng S2 | WP-00 writes the first plan check; WP-01 has a baseline exception | Mechanical | P5 | The bootstrap rules formed a cycle | Leaving the cycle |
| 187 | Eng S2 | The Mac development store in the development container; a development-signed gate step | Mechanical | P5 | A sandboxed app cannot write into a worktree | A store in the worktree |
| 188 | Eng S2 | WP-00 lists the second worktree, the branches and the open pull request | Mechanical | P1 | "Nothing is lost" missed four untracked items | The main worktree only |
| 189 | Eng S2 | One window on the iPad (A36); an open note deleted elsewhere says so | Mechanical | P5 | Two capture fields of one kind had no rule | Several windows now |
| 190 | Eng S3 | Swift Testing for package tests, XCTest for UI tests and measured performance | Mechanical | P5 | No framework was named | XCTest everywhere |
| 191 | Eng S3 | The soak harness as WP-06, with the parent as witness | Mechanical | P1 | It arrived after the packages it gates and could pass after a loss | The soak in WP-22 |
| 192 | Eng S3 | The model requirement per destination; iOS speech proven on hardware | Mechanical | P5 | The Simulator has no speech model | A gate that can never pass |
| 193 | Eng S3 | A `.live` smoke test per platform; an allowed list of unavailable ports | Mechanical | P1 | Production wiring had no automated test | Preview tests only |
| 194 | Eng S3 | A stricter guard with a mutation suite; titles from the note's own words | Taste | P1 | A share limit lets one dropped "not" through | The share limit alone; free titles |
| 195 | Eng S3 | A log canary, search against a scan, hostile export names, the scripts' self-test | Mechanical | P1 | Hard rules had no test | Review alone |
| 196 | Eng S3 | The accessibility audit in every UI smoke test | Mechanical | P1 | The audit exists on all four platforms | A manual audit at WP-41 |
| 197 | Eng S3 | The simulation with two and three replicas and five invariants; named sync tests | Mechanical | P1 | "Converges" was the only assertion | Two replicas, no invariants |
| 198 | Eng S3 | A synthetic store committed at each milestone | Mechanical | P1 | A migration test needs something to migrate | No fixtures |
| 199 | Eng S3 | The restart's regression contract: files, checksums, archive and tag | Mechanical | P1 | The rewrite removes everything by decision D15 | No check on the tag |
| 200 | Eng S4 | Time thresholds leave the merge criteria; a `--perf` tier | Mechanical | P5 | They fail at random on a loaded Mac | Timed asserts in the gate |
| 201 | Eng S4 | Bulk writers batch; readers do not wait; a 50 ms target under load | Mechanical | P1 | A capture could wait behind a restore | One unbounded writer queue |
| 202 | Eng S4 | A measurement protocol and four new targets | Mechanical | P1 | Targets had no endpoints, counts or workload | Signposts alone |
| 203 | Eng S4 | Mac UI tests only where the diff reaches the Mac, and nightly | Mechanical | P3 | They take over the owner's desktop | Every gate |
| 204 | Eng C8 | A serial queue run by the orchestrator, bound to a base, a head and a tree | Mechanical | P5 | GitHub's queue is not offered to this repository | Batching; no queue |
| 205 | Eng C8 | The gate picks its depth from the diff by a fixed table; a full run every night | Taste | P3 | Codex asks for a full gate every time. The table cannot be chosen by hand and keeps the queue affordable | A full gate on every merge |
| 206 | Eng C8 | State from the briefs, GitHub and a local journal; a drill at M1 | Taste | P5 | A status table cannot resume an operation that was cut short | A status file on `main`; a public tracking issue |
| 207 | Eng C8 | One rerun, for infrastructure codes only | Mechanical | P1 | A rerun to green hides a data-loss bug | Free reruns |
| 208 | Eng | M7 needs M6; the release refuses without every milestone's evidence | Mechanical | P1 | The written graph allowed a release before design and accessibility | Package completion as acceptance |
| 209 | Eng | Four deferrals to TODOS.md | Mechanical | P3 | Each has a trigger and no need in v1 | Building them now |
| 210 | Eng | Questions added to SP-1 to SP-4 | Mechanical | P1 | Only hardware or the real service can answer them | Deciding without evidence |
| 211 | Gate 1 | The owner's reply `rec except d12a` is read as declining d12a, so d12 resolves to b | Taste | P5 | Under the reply grammar the words resolve to plain `rec`, which makes the exception empty, and d12 has two options | Reading it as plain `rec`; stopping the run to ask |
| 212 | Gate 1 | UC1, option c: M2 is a keep gate with seven days of use, a sitting with five questions and four rulings | Owner's answer | None | He chose it at the gate | The wave 0 trial, which he declined |
| 213 | Gate 1 | The hold before the keep gate covers everything the cut order names, and wave 4; WP-18's proof step still runs early | Taste | P3 | A cut is free only for work not yet built, and the proof step feeds a contract that is built either way | Building the cut candidates on their packages' schedule; holding the proof step too |
| 214 | Gate 1 | The cut order: iPad Pencil first, then system surfaces beyond the first of each kind | Taste | P5 | He accepted a written order without reading one. This is the order a reviewer proposed, and it reverses D16 | Leaving the order unwritten until a cut is needed |
| 215 | Gate 1 | UC4, option b: a segment can be moved to its own note | Owner's answer | None | He chose it at the gate | No repair in v1 |
| 216 | Gate 1 | A move makes a note with a fresh ID, and two concurrent moves are settled by ID order | Mechanical | P5 | A derived ID would be reused after an undo, when that note may hold other segments or be purged | An ID derived from the segment |
| 217 | Gate 1 | A generated title follows its recording, and a typed title stays | Mechanical | P1 | A generated title must use only words from its note | Leaving the title behind; a new job that makes a title |
| 218 | Gate 1 | The app undoes a move at once, and `knot restore` returns one for 30 days | Mechanical | P1 | v1 has no merge, so a mistaken move would be permanent, and every other action of an agent can be taken back for 30 days | No undo |
| 219 | Gate 1 | A note left empty is hidden and never marked deleted for that reason | Mechanical | P1 | A delete mark would hide a segment that another device moves in later | Marking it deleted |
| 220 | Gate 1 | Taste decision 12, option b: the store root is `KnotStore/`, with a named defaults suite, a lint and a byte-for-byte test of the retired app's files | Mechanical | P1 | The retired app owns `Application Support/Knot/` and the standard defaults domain in the same container | A different file name inside the same folder |
| 221 | Gate 1 | Spikes and the SP-3 upload keep the development identifiers | Mechanical | P5 | The build-flavour rule already says so, and a spike under the real identifier would replace the retired app in wave 1 | Uploading the spike under `com.p3ob7o.knot` |
| 222 | Gate 1 | Taste decisions 1 and 2, option a: the early upload is planned at G1, and the build Mac holds no real notes | Owner's answer | None | He chose them at the gate | The alternatives listed at the gate |
| 223 | Gate 1 | One deferral to TODOS.md: merging notes, splitting at a point, and moving a segment into another note | Mechanical | P3 | He accepted one repair, not regrouping in general | Building merge now |
| 224 | Eng 2 | The hold names PRs, and a milestone needs only PRs that are not held (Codex 1) | Mechanical | P5 | The graph could not reach the ruling that unlocks it | Leaving packages named whole |
| 225 | Eng 2 | A move names the note the caller saw, in place of a stored operation ID (Codex 2) | Taste | P5 | A precondition makes a repeat safe with no new table. Codex asks for an ID | A durable operation ID with its stored result |
| 226 | Eng 2 | `noteGeneration` with a fixed tie-break (Codex 3) | Mechanical | P1 | Precedence could not be read from the note alone | Comparison with the last-synced value only |
| 227 | Eng 2 | `knot move --back` is the return, `restore` gains no third meaning, and a return checks the generation (Codex 4) | Mechanical | P5 | One ID could mean three things to undo | A third meaning for `restore` |
| 228 | Eng 2 | A move does not outlive a purge (Codex 5) | Mechanical | P3 | A purged record cannot give its recording back, and the rule for any change to a purged record applies | Bringing a purged segment back |
| 229 | Eng 2 | Titles stay, and a generated one is dropped when it no longer fits; no stored source (Codex 6) | Taste | P4 | The words rule exists already and needs no new field. Codex asks for a stored source | A source field on the note, and a title that travels |
| 230 | Eng 2 | What a merge makes is queued for upload (Codex 11) | Mechanical | P1 | With the triggers off, replicas would not converge | Trusting the triggers |
| 231 | Eng 2 | Equal ownership generations are settled by device ID (Codex 12) | Mechanical | P1 | Two offline devices can both take the work | A bare counter |
| 232 | Eng 2 | Continuation segments have IDs derived from the capture (Codex 13, Claude E5) | Mechanical | P5 | A capture and its segment share an ID | A capture with child rows of another kind |
| 233 | Eng 2 | A revision carries the store's generation (Codex 14) | Mechanical | P1 | A restored store can reuse a number | A bare integer |
| 234 | Eng 2 | One life for a capture across the store and the inbox (Codex 16, Claude A3) | Mechanical | P1 | A call that timed out can still commit | Treating the timeout as a failure |
| 235 | Eng 2 | The notice between processes is a hint, and the counter is compared on foreground and each minute (Codex 17) | Mechanical | P1 | The tool can die between its commit and its notice | The notification alone |
| 236 | Eng 2 | The retired app's drafts: three M1 rows and a kept copy of the app (Codex 7) | Mechanical | P1 | Drafts are a second list beside pending captures | The one row for pending captures |
| 237 | Eng 2 | Upgrade rows name the identifier and the signing (Codex 8) | Mechanical | P5 | "A development build" could mean either identifier | Leaving the row as written |
| 238 | Eng 2 | The lint covers `@AppStorage` and autosave names, and the old keys are tested (Claude S4) | Mechanical | P1 | The system writes those into the standard domain | The one symbol |
| 239 | Eng 2 | SP-3 closes on the route that ships, with a second upload if that is XPC, and the key revoked after each (Codex 9, Claude S2) | Mechanical | P1 | A test of a rejected route proves nothing about its replacement | One upload whatever the result |
| 240 | Eng 2 | No milestone build on the build Mac from M4, the other Mac registered, and a Mac path in the install script (Codex 10, Claude H3) | Mechanical | P1 | A milestone build with sync open brings the notes there | Trusting `KNOT_AGENT` |
| 241 | Eng 2 | The owner's test recordings stay on the build Mac (Codex 10) | Taste | P3 | He makes them for the build, and the gate needs them there. Codex asks to move them | Running that evaluation by hand on the other Mac |
| 242 | Eng 2 | A restored copy is stated as text only (Codex 15) | Mechanical | P3 | A manifest that pins recordings costs more than it saves for one owner | A backup manifest with pinned files |
| 243 | Eng 2 | A differential test of the fake against the real store, and the goldens on both (Claude A1) | Mechanical | P1 | The fake is a second implementation of every rule | Trusting the contract suite alone |
| 244 | Eng 2 | Seven supporting ports, error codes as values, and additive contract PRs in the normal queue (Claude A2) | Mechanical | P5 | A new enum case broke every open branch | Closed enums, and two merge times for everything |
| 245 | Eng 2 | WP-17 in two PRs, the coordinator in KnotLink, and an acknowledgement on a durable file (Claude A4) | Mechanical | P1 | M1 needed an outbox that waited for SP-2, and a phone that cannot ingest would fill the watch | One PR after SP-2 |
| 246 | Eng 2 | The start table re-derived, and generated at the fold (Claude A5) | Mechanical | P5 | It predated WP-02's third PR and WP-06 | Patching rows by hand |
| 247 | Eng 2 | Crash hosts declared by WP-01, and a live entry point for each module (Claude A6, A7) | Mechanical | P5 | Kill tests had nothing to kill, and KnotApp had no owner after WP-22 | Later edits to shared files |
| 248 | Eng 2 | A level for every milestone build, and sync opens at M4 after its rows pass on development builds (Claude E1) | Mechanical | P1 | A fix cut from a moving `main` could sync real notes early | Fix branches at each milestone |
| 249 | Eng 2 | Schema version 1 frozen at the M2 build, and milestone stores migrated and run through the suite (Claude E2) | Mechanical | P1 | The owner's store is real from M2 | Editing version 1 in place |
| 250 | Eng 2 | Zone identity, a scoped `sync_record`, a pause before many deletions, server dates for the purge, the recorder as the truth in its process, and SP-5 (Claude E3, E4, E6, H2) | Mechanical | P1 | Each was a rule with two readings or with none | Leaving them to the packages |
| 251 | Eng 2 | WP-00 in two PRs, a "replaces" column, and a scoped clean (Claude H1, H4) | Mechanical | P1 | The fold writes every agent's only instructions | A presence check alone |
| 252 | Eng 2 | Three exact rules: another surface, a bounded negative gap, and whitespace (Claude E5) | Mechanical | P5 | WP-02 would have frozen an accident | Leaving them open |
| 253 | Eng 2 | Asset folders by the last two characters, and the content hash keyed and not exported (Claude E7, S3) | Mechanical | P5 | The first characters do not vary, and a plain hash can be guessed | The first two characters; a plain hash |
| 254 | Eng 2 | "Distribution signing" in Appendix A, the owner's word for operations on the milestone container, and the schema committed (Claude S2, E1) | Mechanical | P5 | The rule forbade what agents do all day | The word "signing" |
| 255 | Eng 2 | A full iCloud quota is stated, not engineered around (Claude E8) | Mechanical | P3 | Text and recordings share one quota by the service's design | An upload order of our own |
| 256 | Eng 2 | The doctor refuses a cloud-synced path, a lint on " 2" names, greedy sampling, and a limit on booted simulators (Claude H4, T6) | Mechanical | P1 | The " 2" files are conflict copies from such a sync | Cleaning them up once |
| 257 | Eng 2 | Four faults must turn the soak red, and three broken fakes must fail the suite (Claude T1) | Mechanical | P1 | A check never seen to fail proves nothing | Trusting green |
| 258 | Eng 2 | A second model also reviews WP-02, WP-05, WP-06, WP-11 and WP-17, and set-aside findings are logged (Claude T1) | Mechanical | P1 | These carry the contracts and the ledger | Four packages only |
| 259 | Eng 2 | Thread Sanitizer nightly, a list for concurrency escapes, and 30 minutes of frames (Claude T2) | Mechanical | P1 | Strict concurrency can be switched off one annotation at a time | The compiler alone |
| 260 | Eng 2 | Checklist rows for audio events, and 30 minutes wrist down in SP-2 (Claude T3) | Mechanical | P1 | Injected audio cannot show them | Leaving them to chance |
| 261 | Eng 2 | Unattended signing settled at G1 and probed, and privacy manifests with required reasons and a lint (Claude T4, S1) | Mechanical | P1 | A prompt at night stops the queue, and a missing reason stops an upload | Finding out at M7 |
| 262 | Eng 2 | Counters as the source of the keep-gate counts, punctuation-only cleanup cases, and the named tests of this pass (Codex 19 and 18, Claude T5) | Mechanical | P1 | The counts could not be rebuilt from rows that change | Counting from capture rows |
| 263 | Gate 2 | The owner replied `rec`: d27 to d32 as recommended, and the plan approved as it stands | Owner's answer | None | He chose it at the gate, and every option was what the plan already carried | The alternatives listed at the gate |
| 264 | G0 | The owner answered the 34 assumptions of the product spec: 32 confirmed, A6 and A27 changed, and cleanup to do more after v1 | Owner's answer | None | They are his to decide, and WP-02 turns them into tests | A6 and A27 as they were drafted |
| 265 | G0 | A6 read as a Watch that still lists its own recordings by time, length and delivery state (A38). A27 read as whole segments with copy, share and delete, with the move left at one segment (A39) | Taste | P5 | His words leave both open, and a spec that agents build from cannot stay vague. Both wait for his answer | For A6, a Watch with no list. For A27, a text selection across segments, which D20 rules out, and moving several segments together, which would change the reviewed move operation |
