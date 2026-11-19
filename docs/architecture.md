# Knot v1: architecture

Draft for review · 2026-11-18

This file says how Knot v1 is built. What it does is in [product-spec.md](product-spec.md). How the work is organised is in [PLAN.md](../PLAN.md). Decision IDs (D1) and package IDs (WP-10, SP-1) refer to PLAN.md.

## 1. Fixed choices

| Choice | Value | Why |
|---|---|---|
| Minimum OS | 27 on iOS, iPadOS, macOS and watchOS | D17. It brings handwriting recognition, new App Intents and a better on-device model. |
| Language | Swift 6, strict concurrency complete, warnings are errors | Many agents write this code, and the compiler is the cheapest reviewer. |
| UI | SwiftUI. AppKit or UIKit only where SwiftUI cannot do the job: the Mac panel and hotkey, the PencilKit canvas. | D20 |
| Local store | SQLite through GRDB | The one third-party dependency (D30). |
| Sync | CloudKit private database through CKSyncEngine | D11 |
| Watch transport | WatchConnectivity | It works with sync off (D18) and fits "no phone, no notes" (D5). |
| Speech | Apple SpeechAnalyzer with SpeechTranscriber | English only in v1 (D4), on-device. |
| Cleanup | Apple Foundation Models, the on-device model | D6 |
| Ink | PencilKit with PKStrokeRecognizer | D7 |
| Project file | XcodeGen from `project.yml`. The generated project is not committed. | Parallel agents never conflict on a project file. |
| Dependencies | GRDB only. No analytics, no UI libraries, no MCP SDK. | D18, D30 |
| Toolchain | Xcode 27.x through a command-scoped `DEVELOPER_DIR`. Never change `xcode-select`. | Other projects on the machine keep their own toolchain. |

## 2. Repository layout

```
AGENTS.md  CLAUDE.md  LICENSE  PLAN.md  README.md  project.yml
Apps/
  iOS/                  iPhone and iPad app, a thin shell
  macOS/                Mac app: menu bar, hotkey, panel, window
  watchOS/              Watch app
  Extensions/
    Widgets-iOS/        controls, widgets, Live Activity views
    Widgets-watchOS/    complications, Smart Stack widget, control
Packages/KnotKit/       all logic: one Swift package, one target per module
  Sources/<Module>/
  Tests/<Module>Tests/
Fixtures/               audio, transcripts and ink, synthetic only
Resources/Brand/        the icon and mark, carried over from the old app
Spikes/                 throwaway spike code, never merged to main
docs/                   product-spec, architecture, design/, spikes/, checklists/, decisions/
scripts/                bootstrap, verify, build-slot, sim, release
```

## 3. Modules

| Module | Does | Platforms | Uses |
|---|---|---|---|
| KnotCore | Domain types, ports (protocols), the append rule, state machines, the settings model, feature gates, clock and ID generation, the logging facade, the capture manifest, store locations and the durable file helper | all | nothing |
| KnotStore | SQLite schema and migrations, note and asset repositories, full-text search, the change log that feeds sync | iOS, macOS | Core, GRDB |
| KnotAudio | The recorder: crash-tolerant recording files, metering, interruptions, conversion to the final format, recovery of orphaned recordings | all | Core |
| KnotCapture | The capture engine: typed drafts, sessions and the append rule, inbox ingest, the processing queue | iOS, macOS | Core |
| KnotSpeech | The transcriber, on SpeechAnalyzer | iOS, macOS | Core |
| KnotCleanup | The cleaner, on Foundation Models, with the fidelity guard | iOS, macOS | Core |
| KnotInk | Canvas, drawing data, recognition, rendering | iOS, macOS (viewing only) | Core |
| KnotSync | CloudKit sync: a merge core with no CloudKit in it, and a thin CloudKit adapter | iOS, macOS | Core, Store |
| KnotLink | Watch-to-phone transport and the watch outbox | iOS, watchOS | Core |
| KnotIntents | App Intents, App Shortcuts, entities | all | Core |
| KnotExport | Markdown rendering, share items, export | iOS, macOS | Core |
| KnotUI | Theme tokens, components, view models | all | Core; Ink and Export on iOS and macOS |
| KnotAgent | Command implementations and the MCP server, written against the `NoteStore` port | macOS | Core, Export |
| KnotApp | The composition root: builds the live environment | iOS, macOS | everything |
| KnotFakes | A fake for every leaf port, fixture builders and the preview environment. It imports no test framework. Its code compiles only in a debug build, or in a build that sets `KNOT_FAKES`, such as the optimised build that `--perf` measures. A release app links the module empty. | all | Core; Capture on iOS and macOS |
| KnotTestSupport | The shared contract suites, one per port | all, test targets only | Core, Fakes |
| KnotUIPreviews | SwiftUI previews of KnotUI on the preview environment. Its code compiles under the same condition as KnotFakes. | all | UI, Fakes |
| `knot-eval` | Two local commands that score the owner's own recordings | macOS | Speech, Cleanup |
| `knot` | The command-line executable, which composes KnotAgent with KnotStore | macOS | Agent, Store |

Modules depend on KnotCore's ports, not on each other. Only KnotApp knows the concrete types. KnotSync is the one exception: it uses KnotStore directly, because it needs database-level access. It never issues SQL itself. KnotStore gives it one interface: read the pending changes, apply a fetched batch together with the engine's state in one transaction, and save a record's system fields. That interface keeps revisions, the change counter, history and the search index right for a remote change as for a local one. KnotAgent is written against the `NoteStore` port, so its commands can be built and tested on the fake before the store exists, and the `knot` executable is where the real store is wired in.

Three things in KnotCore exist so that a rule has one home. `CaptureManifest` is the one file format for a recording in progress, an item in `Inbox/` and a file in the watch outbox, with one version number and one set of golden files. `StoreLocations` is the only code that computes where a store, `Inbox/` or the recording state lives. It takes the flavour from the app shell or the tool, and no library target has a default path. `DurableFile` is the only code that places a file: write, sync, rename, sync the folder (§6, rule 7). A fourth joined them in the second engineering pass: the rule that a generated title uses only words from its note is one function here, which KnotCleanup calls when it proposes a title and the store calls when a segment leaves a note.

The module table is enforced. The gate builds with `--explicit-target-dependency-import-check error`, so an import the table does not allow fails the build. On a branch that is not a contract branch, the gate also fails when KnotCore's public API differs from `main`. WP-02's own pull requests are the exception until the last of them has merged, because they are the ones that write that API. Its third only adds: once the tracer has started on the API of the second, a change that breaks it goes in a contract branch like any other. The review holds WP-02 to that, because the gate's check lets its branches through.

`AppEnvironment` is declared in KnotCore, with an `.unavailable` value whose ports all report that they are not there yet. KnotFakes builds `.preview` and KnotApp builds `.live`. On iOS and macOS, `.preview` is the real capture engine and queue running over the fakes, and WP-05 delivers that part. On watchOS the environment has no engine.

App shells get their environment from one factory in KnotApp. WP-01 writes it so that a debug build asks KnotFakes for the preview environment, which answers `.unavailable` until WP-05 fills it in, so WP-05 edits only its own folder. The first PR of WP-22 makes the factory return `.live`, filling any port that has no implementation yet with the unavailable one. A test compares the unavailable ports of `.live` with a list allowed for the coming milestone. The import of KnotFakes sits behind `#if DEBUG`, and the release script fails when a Release binary holds a KnotFakes symbol or honours the preview launch argument. UI tests select `.preview` with a launch argument that only debug builds honour. The watch app does not use `CaptureEngine`: it composes KnotAudio, KnotLink and KnotUI itself. Each module exposes one live entry point, which returns the unavailable port until its package fills it in, so a package that lands after WP-22 wires itself in without editing KnotApp.

## 4. Domain model

```swift
struct Capture { id; kind: typed | voice | ink; origin: (source, surface); startedAt; endedAt: Date?
                 outcome: open | stored | discardedEmpty | failed(code)
                 launchID                           // the process launch that owns it while it is open
                 placement: window | newNote | named // what was asked for; local
                 contentHash }                      // of a finished capture, keyed with a secret of the store, to judge a repeated ID. Text is hashed in NFC

struct Note    { id; createdAt; updatedAt
                 title: String?; titleOrigin: none | generated | user
                 lastCaptureEndedAt; closedAt: Date?; deletedAt: Date?
                 revision: Int64 }                  // the store's change counter at this note's last change

struct Segment { id; noteID; kind: typed | voice | ink
                 noteGeneration: Int                // synced: rises each time the segment's note changes
                 origin: device(DeviceID) | cli | mcp
                 startedAt; endedAt
                 text: String                       // shown, edited, searched, exported
                 textOrigin: typed | rawTranscript | cleaned | edited | recognised
                 rawTranscript: String?             // voice only, never modified
                 transcription: (engine, locale, osBuild)?   // voice only: what produced the transcript
                 cleanup: (osBuild)?                // voice only: the OS build whose model cleaned the text
                 processingOwner: DeviceID?         // voice only, synced: the device that runs its jobs
                 ownerGeneration: Int               // voice only, synced: rises each time the work moves
                 arrivedAt: Date?                   // local, not synced: set when a late capture is placed, cleared when its note is opened
                 state: SegmentState; assetID: AssetID?; duration: Duration?
                 conflictOf: SegmentID?; deletedAt: Date?
                 revision: Int64 }                  // local, never synced: rises each time the text changes

struct Asset   { id; segmentID; kind: audio | ink; byteCount; sha256
                 availability: local | remote | downloading   // whether the file is on this device
                 upload: localOnly | uploading | published }  // how far its upload has gone

struct Job     { id; segmentID; kind: transcribe | clean | recognise
                 state; attempts; deaths; notBefore; lastErrorCode }
```

IDs are time-ordered UUIDs (version 7) generated in KnotCore. They sort by creation time and never collide across devices. Every capture has a capture row, made once, which holds no content. On the store path it is the capture's first durable write. A recording writes its manifest first, and a capture that falls back to `Inbox/` gets its row when the row can be written (§6). The segment a capture becomes shares its ID. No rule may read an ID's order as time order: a capture ID given on the command line and a note ID derived for a moved segment (§11) are not time-ordered. Time comes from the timestamps. A derived ID is a version 5 UUID, so it can always be told from a fresh one, which is version 7. Text that runs past the size limit continues in further segments of the same capture: the first shares the capture's ID, and each later one has an ID derived from the capture's ID and its position. A repeat of the capture therefore returns the same segments, and the capture row counts once.

The store has an ID and a change counter. Every change to a note or to one of its segments, including one that arrives by sync, gives the note the counter's next value in the same transaction. The `knot` command polls on that value. The store also has a generation, which rises when a kept copy is restored (§7). A cursor names the store, its generation and the counter. A revision that leaves the store, in a result or on the command line, carries the generation too, so a revision kept from before a restore is refused like a foreign cursor.

A segment can leave its note for a new note of its own (product spec §7). The move makes a note with a fresh ID, and every other field of that note comes from the segment: its dates are the segment's, it is not closed and it has no title. A move changes no text, so the segment's revision stays, while both notes take the next values of the change counter. `noteGeneration` rises by one each time the segment's note changes, whether by a move, by a return or by the deleted-note rule of §11. `lastCaptureEndedAt` is recomputed for both notes in the same transaction, and again whenever a change of note arrives by sync. Titles do not move. A generated title must still use only words from its note (§9), so when a segment leaves, the note's generated title is checked again and dropped if it no longer fits. A title of origin `user` is never touched. The clean job proposes a title only for the note that holds its recording when the job finishes, and only if that recording is the note's first segment and the note has no title. A conflict copy (§11) is always in the note of the segment it copies, and moves with it.

Job states are queued, running, done and failed. Five things can stop a job, and they are told apart:

- **An attempt** is an error the step returned. After five, the job is failed and its segment shows a retry action.
- **A deferral** is a step that cannot run now: the model is not ready, the system limits requests, there is no background time left, or the device is locked. Deferrals are never counted. The job runs again when the app comes forward or the model's availability changes.
- **A death** is a job found running at launch. When background time runs out the queue yields the job cleanly, so a job still marked running means the process died. The job goes back to queued once. After two deaths it fails with its own code, so a recording that crashes the transcriber cannot kill the app at every launch.
- **A yield** is a step that was cancelled, because background time ran out or the queue was asked to stop. It is not counted, and the job stays queued.
- **A final error** is one that no retry on this device can fix: speech is unavailable here, the audio cannot be read, or the cleanup model cannot be used here. The job ends at once as done, with the error's code, and is not tried again. What its segment shows is the error's own: a recording kept without text, or the raw transcript as its text.

Sizes are bounded in the domain types, and WP-02 fixes the numbers. First values, all estimates: a segment's text holds at most 256 KiB of UTF-8, so that a record stays under CloudKit's limit with its raw transcript beside it; a title at most 200 characters; a manifest at most 64 KiB. Typed or piped text beyond the limit continues in a new segment of the same note, and nothing is cut. A file's place on disk is derived from its ID, never from a name inside a manifest or a record.

The device ID is checked against an install ID kept in the Keychain for this device only. When a store arrives on another device through a backup, the two no longer match. Knot then gives the store a new device ID, resets the sync state and fetches again, so a restored phone never acts as the old one.

A kind, an origin, a state or a field that this build does not know is kept and never dropped, and the segment shows as made by a newer Knot, which is a visible state of its own beside the six of product spec §5. That holds for the database, for synced records and for inbox manifests. A manifest is valid JSON as a whole, or it is unreadable (§6, rule 2). A field of a manifest that this build does not know keeps its value as the original JSON text, and is written back with it.

Segment states:

```
typed   draft ──end──► ready                       (empty draft ──► discarded)
        draft ──killed──► ready at relaunch

voice   recording ──stop──► recorded ──► transcribing ──► transcribed ──► cleaning ──► ready
            │ killed            │ cannot run now            │ no model, or the guard rejects
            ▼                   ▼                           ▼
        recovered ──────► recorded (pending)          ready, with the raw transcript as text
        recording ──a tap-started one, stopped within a second──► discarded
        cleaning ──cannot run now──► transcribed
        speech is unavailable on this device ──► recorded, shown as "Kept, no text" until another device takes the work
        any step fails ──► failed(step, code): the recording is kept and a retry is offered

ink     drawing ──end──► recognising ──► ready     (empty canvas ──► discarded)
        drawing ──killed──► recognising at relaunch
        recognition fails ──► failed(recognise, code): the drawing is kept and a retry is offered

watch   onWatch ──transfer──► delivered ──► continues as "recorded" on the iPhone
```

## 5. Ports

KnotCore declares these protocols. KnotFakes ships a fake for each, except `CaptureEngine` and `ProcessingQueue`, which have one real implementation each in KnotCapture. WP-02 fixes their exact signatures.

| Port | Responsibility |
|---|---|
| `NoteStore` | Create, append, update, delete and restore notes and segments. Move a segment to its own note, and return it. Page the stream. Search. Publish changes. |
| `AssetStore` | Place, find, verify and remove recording and drawing files. |
| `CaptureEngine` | Begin, update and end captures of each kind. Tell the store where the user wants each one placed. Publish capture state. |
| `Recorder` | Get ready without opening the microphone. Start a recording, which returns a session once the recording is live. The session streams levels, how much of the audio is durable, and the live audio, and it ends with its reason, whether it was stopped or stopped by itself. Stop, which cannot fail or be cancelled and returns once the file is on the drive. Discard. Recover the orphaned recordings of earlier launches, never one of the current launch. |
| `Transcriber` | Report readiness in five states: ready, not installed, installing, unsupported locale, unavailable. Install the model with progress, which only the app does. Transcribe a file in resumable runs: a run reads at most a budget of audio from an offset, ends at the last finished phrase, and returns its pieces with their time ranges and where the next run starts. Stream live text for `Sendable` chunks of samples. |
| `Cleaner` | Report availability in three states: available, not ready, unavailable with its reason. Publish its changes. Turn a raw transcript into a body and, when asked, a title, in one call that returns the whole result. A decline is a result, not an error. |
| `InkRecogniser` | Turn drawing data into text. |
| `ProcessingQueue` | Run and resume transcribe, clean and recognise jobs. Each drain takes a `BackgroundRunner` and a progress sink from its caller. |
| `SyncEngine` | Start, stop and report status. |
| `WatchLink` | Send a capture: write it to the outbox and queue it, which says nothing about delivery. Receive acknowledgements. Publish how many captures wait and how many failed, counted from the outbox and its acknowledgements, never from the session's queue. Resume at launch and on the system's events (§12). Run the Watch's background task until the session has no content pending, within a time limit. |
| `AudioPlayer` | Play, pause and seek a recording. |
| `AssetFetcher` | Bring a recording or drawing made on another device onto this one, with progress. |
| `RecordingStateStore` | Publish whether a recording is running, for controls and widgets in other processes: a synchronous read and write of one value in the app group's defaults. |
| `RecordingActivity` | Start, update and end the Live Activity that keeps an intent-started recording alive, keyed by capture ID, and at launch end every activity that has no recorder. Its errors name ActivityKit's refusal. iPhone and iPad only. |
| `SettingsStore`, `FeatureGates`, `Clock`, `IDGenerator` | Small supporting ports. |
| `SurfaceRouter`, `CueEmitter`, `BackgroundRunner`, `FreeSpaceProbe`, `InstallIdentity`, `ProcessNotifier`, `Lifecycle` | Supporting ports that the second engineering pass named, each with a fake: where an Open intent lands, the cues of product spec §4.5, background time, free space, the Keychain install ID, the notice between processes, and the app's foreground and background events. |

Implementers: `AudioPlayer` and `RecordingStateStore` in KnotAudio; `SettingsStore` in KnotStore; `AssetFetcher` in KnotSync, with a local-only version in KnotStore for when sync is off; `RecordingActivity` in the iOS app target.

SP-1's code half fixed three of these ports:

- `RecordingActivity` holds no `Activity`, because ActivityKit's `Activity` is not `Sendable`. Its implementation finds the activity by the capture ID in its attributes each time, so a new launch ends the activity that a dead one left, through `endAll(except:)`.
- `BackgroundRunner` is not a service the queue calls. Background time from an intent exists only inside that intent's `perform()`, through a method of the intent itself, and every mechanism that gives minutes requires progress reports. So the runner is passed in by whoever holds the time, is scoped to one call, and runs work that reports its progress. `ProcessingQueue` takes a runner and a progress sink for each drain and owns no background time. Which mechanism gives the time waits for SP-1's report.
- Reloading the controls when the recording phase changes belongs to the app shell, with `ControlCenter.shared.reloadControls(ofKind:)`, and not to `RecordingStateStore`, so that KnotAudio needs no WidgetKit.

KnotCore also declares two seams that are not ports of `AppEnvironment`: `FileLayer`, under `DurableFile`, which the power-cut layer of KnotTestSupport replaces in tests, and `LogSink`, under the logging facade, for tests that check that no text reaches a log.

KnotLink declares one more seam of that kind, `LinkTransport`, and WP-17 writes it with its fake. Everything in §12 sits behind it. It activates the session and reports its state; queues, lists and cancels file transfers by capture ID; receives a file through a synchronous handler that runs before the system deletes the file and returns the acknowledgement to send; sends acknowledgements; and updates the context. It streams the session's events: a change of state, a file finished, a file cancelled, an acknowledgement and a context. A file finished is not a delivery. The fake transport can lose, repeat and reorder each kind of event, and finish a file that never arrives.

Two operations carry the "nothing is lost" promise and are part of the contracts:

- `NoteStore` records a capture in one transaction: it applies the append rule, writes the capture row and writes the segment. `CaptureEngine` and the `knot` command both use that one operation, so the append rule runs in one place. The store decides. The engine passes only what the user asked for: follow the window, a new note, or a named note. The note that a capture surface shows before the first keystroke comes from a store query that calls the same rule, and a test checks that the prediction and the decision agree at the same instant. The rules about open captures on a device are checked in that transaction too, against the `capture` table, because two processes share it on the Mac. The same transaction sets a segment's `arrivedAt` when the append rule places its capture as a late arrival (product spec §3, rule 7), and `NoteStore` clears `arrivedAt` on a note's segments when the note view opens it. The mark is local display state: setting it is part of the capture's own write, and clearing it changes neither the change counter nor any revision, so opening a note never brings it back into `knot changes`.
- `CaptureEngine` publishes, with its state, the revision of the content that is durably saved. Tests and the soak harness treat only that as acknowledged.

Three more operations serve the command line and are part of the same contracts:

- Recording a capture is idempotent by capture ID. A repeat with the same ID changes nothing and returns the first result.
- `NoteStore` lists the notes changed after a given counter value, in pages, deletions included, and says when a value is ahead of the store.
- Replacing a segment's text or a note's title takes the revision the caller read and fails when it is stale. Text replaced through the command line or MCP is kept for 30 days in a local table and can be restored.

One operation repairs a grouping, and it is part of the same contracts:

- `NoteStore` moves a segment to a new note of its own in one transaction, and returns it to the note it left in another. A move names the note the caller saw the segment in. If the segment is no longer in that note, nothing moves and the result says where it is, so a repeat is safe even after a later capture has joined the new note. A move is refused for a segment whose capture is open, for a deleted segment, for a conflict copy, and for a segment that is the only live one in its note apart from its own conflict copies. Each move writes a row to `segment_history`: the note the segment left, the note the move made, the `noteGeneration` it produced and a generated title it dropped. The row stays for 30 days on the device that made the move. A return reads that row. It is refused, and changes nothing, when the segment's `noteGeneration` has changed since, or when the note it left is deleted or gone. The app's undo and `knot move --back` are both a return. Either way the rules of §4 hold: the titles, the two notes' latest-capture times and the conflict copies are settled in the same transaction.

Three rules keep a fallback or a retry from undoing newer work:

- Saving a checkpoint of an open capture is a different operation from recording one. It carries the capture ID and a revision, and it never lowers the stored revision. A checkpoint that arrives late, from a slow save or from a file in `Inbox/`, replaces older text and never newer text.
- A repeated capture ID is judged by content. The same ID with the same content returns the first result. The same ID with different content fails as a conflict, so an agent that reuses an ID learns of it.
- Replacing text checks precedence inside the store: edited beats cleaned beats raw (§11). The queue and sync both call that one operation, so neither carries a check of its own.

A recovered capture ends at its last durable write.

WP-02's error taxonomy names these failures by case, and no port throws an untyped error: disk full; store busy; store damaged; store newer than this build; write failed; microphone permission refused; no input device; audio session busy; too little space; conversion failed; audio unreadable; transcription failed, with the engine's code; speech unavailable on this device; cleanup model unavailable; cleanup declined (refusal, guardrail violation, empty or malformed result, guard rejection, text too long for the model, unsupported language, unsupported request); cleanup timed out; recognition failed; inbox item unreadable; checksum mismatch; and the sync conditions of §11. The engineering review added three cases: text too long; a capture stopped because the disk filled; and a cursor from another store generation. One code covers a cursor from another store and one from another generation of this store, and one code does the same for a revision. The recorder tells a full disk from another failed write by the volume's free space, because the audio file's error does not say. The errors of a step that cannot run now form a class of their own, a deferral (§4): speech model not installed or still installing, cleanup model not ready, requests limited by the system, with the time to try again when the system gives one, system resources limited, no background time, device locked, and, for the watch link, link not ready, counterpart missing and counterpart full. The watch link has two more cases: delivery failed, an attempt after which the capture is queued again, and outbox file missing, which fails the capture at once and keeps its manifest. A cancelled step is a yield: it is not an attempt, not a decline and not an error. Speech unavailable on this device, audio unreadable and cleanup model unavailable are final: the job ends and is not tried again on this device (§4). A job that died twice fails with a code of its own. A recording that is empty or silent is not an error either: it is ready with empty text.

Each real implementation runs its contract suite where it can run:

| Suite | Runs |
|---|---|
| `NoteStore`, `AssetStore`, `SettingsStore`, `Recorder` on injected audio, `AudioPlayer`, `Transcriber`, `Cleaner`, and `SyncEngine` on the merge core | The Mac, in the package tests |
| `RecordingStateStore` across two processes, `RecordingActivity`, and `InkRecogniser` if WP-18's proof finds it needs the Simulator | The iOS Simulator |
| `WatchLink` | The fake transport on the Mac. The real one on hardware, at M3. |

## 6. One writer, many producers

```
 producers                          one writer                      readers
 ─────────                          ──────────                      ───────
 typing in the app        ─┐
 recorder in the app      ─┤
 intents (app process)    ─┼──► CaptureEngine ──► NoteStore ──► stream, note view, search
 watch files              ─┤         │           (SQLite)  ◄─► CLI and MCP (macOS, a second process)
 recovered recordings     ─┘         ▼               ▲
                               ProcessingQueue       └──── SyncEngine (CloudKit)
                         transcribe ► clean ► title
```

Rules:

1. In each process, one `NoteStore` actor writes the database. On iOS only the app process opens the database. Extensions never do. On the Mac the `knot` command and the MCP server are a second process. They read, and they write only through `NoteStore`: a new capture goes through the same record-a-capture operation the engine uses (§5). Text added by the tool does not end a capture that is open in the app. It is placed by the window like any capture, and an open capture counts as an open window. The tool refuses to edit or delete a segment whose capture is still open.
2. Anything outside the app process that produces a capture writes an inbox item: a manifest file and a payload, written atomically into `Inbox/`, which sits in the app group container in a build that has one (§7). The app ingests inbox items at launch, on returning to the foreground and when notified, and takes the items it finds together in the order their captures started (product spec §3, rule 7). Ingest is idempotent by capture ID. A manifest is a `CaptureManifest` (§3) and carries a format version. An item that cannot be read, or whose version is newer than this build, becomes a failed segment that says so and keeps the file. Nothing in `Inbox/` is deleted before it is stored.
3. The recorder writes a manifest before the first audio sample. Recovery at launch turns orphaned manifests into segments.
4. The sync engine runs only in the app process. It learns about writes from other processes through the change log.
5. Views never touch storage. They talk to view models, and view models talk to ports.
6. The capture ledger. Every capture has a `capture` row. On the store path the row is its first durable write, and that write is what "started" means. A recording writes its manifest first, and a capture that falls back to `Inbox/` starts with its file there. A typed capture starts at its first keystroke. A recording whose microphone cannot open never starts, and the surface says why.
   - After recovery no row is `open`. Each row is stored as a segment, discarded as empty, or failed with its content kept and visible. A failed capture becomes stored when a retry succeeds.
   - Empty means no text for a typed capture, no strokes for an ink capture, and under one second for a tap-started recording. The second is measured between the two presses, and a stop that the clock puts before its start is kept.
   - A typed or ink capture whose save fails writes its content to a file in `Inbox/` and is marked failed. If the row itself cannot be written, the content still goes to `Inbox/`, and ingest creates the row later.
   - If the store cannot be opened at all, capture still works: every capture goes to `Inbox/`, and the stream shows what is wrong. Nothing is deleted. Ingest stores those captures once the store opens again.
   - Capture rows belong to the device that made the capture and do not sync. Writes from `knot` and the MCP server create rows too. The invariant covers segments that originated on this device.
   - On the watch the ledger is the outbox: every manifest is either still on the watch and visible, or acknowledged by an iPhone that holds its file in `Inbox/` or a capture row with the same ID.
   - The 150 ms and one-second tolerances in the product spec bound what a kill can lose inside a capture. They do not excuse a missing row.
   - The engine never waits for the store. A capture that begins while the store is not open yet, is migrating, or has not answered within 100 ms is written to `Inbox/` in the usual manifest format and ingested when the store answers. A recording writes its manifest first and its row when the row can be written. A capture that falls back to `Inbox/` stays on that path until it ends, and its manifest records the placement that was asked for and the note the surface showed. The store call it stopped waiting for may still commit. Either way the capture row is made once, by whichever arrives first, every later save is a checkpoint ordered by revision, and ingest places the capture where its manifest says.
   - A capture is owned by the process launch that began it. Recovery finishes only captures whose launch is not the current one, so it never ends a capture the user is making now.
7. What "on disk" means. There are three cases, and each claim says which one it rests on.
   - **A killed process.** Everything written is kept, within the 150 ms and one-second tolerances. The kill tests and the soak prove this.
   - **A sudden power cut or a kernel panic.** Only what was synced to the drive is kept. `DurableFile` syncs a file and its folder before the database row that points to it is committed. A folder's own name is synced as well, in its parent: `DurableFile` checks and syncs each folder of a path the first time it meets it, from the store's root down, and remembers it. If a save fails because a remembered folder is gone, it forgets that folder and those below it, checks and syncs them again, and tries once more: only that second try's success is acknowledged. A folder that another program replaced is not noticed (§19). On first use it also syncs the folders above the store's root, upward to the first one the process may not open, because a folder that an app made with `FileManager` was never synced. The store's folders are Knot's alone: nothing else creates them, and nothing removes or replaces one while the store is in use (§19). The database runs with `fullfsync` on, because on Apple's systems `synchronous = FULL` alone can leave a commit in the drive's cache. A recording in progress is synced every second. The "saved" cue, an acknowledgement to the watch and the engine's durable revision are given only after that sync. WP-10 and WP-12 report what the syncs cost. If a draft save cannot afford one each time, drafts are synced at least once a second.
   - **A battery that runs out.** The system shuts down in order, which is the first case.
   - A test fails when the writer connection lacks either setting. A file-layer test drops every write that was not synced and checks that recovery still holds. A power cut itself is checked by the owner, once at M2 and once at M3, with a forced restart during a recording.

In v1 the only producer outside the app process is the watch link. Extensions that capture come later.

## 7. Storage

- **Database:** `KnotStore/knot.sqlite`, a GRDB `DatabasePool` in WAL mode with `synchronous = FULL`, foreign keys on and a 5-second busy timeout. On iOS and iPadOS it lives in the app's own container: iOS kills a process that is suspended while holding a lock on a database in a shared container, and no extension needs the database. On macOS it lives in the app group container, so that the `knot` command can open it. The writer connection sets `fullfsync` (§6, rule 7). Reads use the pool's reader connections and never wait for the writer.
- **Files:** under the same `KnotStore/` root, `Assets/<last two ID characters>/<assetID>.<ext>` for recordings and drawings, because the first characters of a time-ordered ID stay the same for years, `Recording/` for audio in progress and its manifests, `Inbox/` for items waiting to be ingested. On iOS, `Inbox/` and the recording state sit in the app group container, where the watch link and the widget extension reach them, and `Recording/` stays in the app's own container beside the database. On the Watch, the recording state and what the complication reads sit in the Watch's app group, where its widget extension reaches them, and the outbox and the recordings stay in the Watch app's own container.
- **File protection on iOS:** `completeUntilFirstUserAuthentication` for everything Knot writes. Recording and ingest must work while the phone is locked, and the default class would block them.
- **Build flavours:** every build that is not a milestone build uses development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. That covers agent builds, PR builds, spikes and tests, and tests also pass the store path in. Development builds from two worktrees never share a store. On iOS each worktree has its own simulators. On the Mac a sandboxed app cannot write into a worktree, so its store sits in the development container, in a folder named for the worktree and chosen by a setting that only debug builds honour. Package tests are not sandboxed and pass a path under the worktree. A build made with the local signing configuration has no app group, and its configuration says so. `StoreLocations` then roots what would sit in the group in the app's own container, in the same `KnotStore/` layout, and reports that the group is absent, so that what needs it is off: the `knot-dev` tool cannot open that store, and the extensions see no recording state. A build that says it has a group and finds no container fails with a typed error. On a real iPhone or iPad one development build is installed at a time: a second install replaces the first and inherits its store, which is disposable. Only a milestone build opens the default store or the real iCloud container. A thread started for an agent exports `KNOT_AGENT=1`. With it set, `StoreLocations` refuses the milestone store and the milestone `knot` refuses to run, so an agent cannot open the owner's notes by accident.
- **When data must survive:** notes on the owner's iPhone and iPad are disposable until the M2 milestone build, and notes on his Mac until the M4 milestone build, which needs SP-3's answer on where the Mac store lives. After those builds, every change to the schema or to the store's location ships a tested migration. Schema version 1 is the schema of the M2 milestone build, and every change after that build is a numbered migration, whichever package makes it. A lint fails on GRDB's `eraseDatabaseOnSchemaChange`.
- **Legacy data:** milestone builds reuse the retired app's bundle ID, `com.p3ob7o.knot`, by the owner's decision of 2026-11-19. On a device that had the retired app, v1 therefore shares its container. The retired app kept everything in `Application Support/Knot/` (its `captures.sqlite`, `assets/`, `staging/` and `migration-backups/`) and its settings in the standard defaults domain. v1 never opens, lists, moves or deletes any of that. `StoreLocations` roots everything v1 writes in a folder named `KnotStore/`, in the app's container and in the app group, which is a name the retired app never used. v1 keeps its per-device settings in a named defaults suite and never reads `UserDefaults.standard`. The gate's lint fails on that symbol, on `@AppStorage` without a named store, and on an autosave name that lacks the `v1.` prefix, because the system writes those into the standard domain whatever the app does. It refuses to open a database it did not create, which it tells by the store ID in `store_meta`. A test builds a container laid out as the retired app left it, opens the store there, and checks that every old file is byte for byte as it was and that every key the retired app wrote in the standard domain still has its value. The retired app keeps drafts apart from pending captures, for inactive vaults too, and once it is replaced nothing shows them. So before the first milestone install on a device the owner clears its Recovery window and keeps a copy of the retired app, which can still open its untouched store if something was missed. Every build that is not a milestone build keeps the development identifiers, the spikes and the TestFlight upload of the SP-3 spike app included, so nothing before the M1 milestone build touches the retired app or its container. The first milestone build installed on a device replaces the retired app there.
- **Tables:** `capture`, `note`, `segment`, `segment_history`, `asset`, `job`, `setting`; `change_log`, fed by triggers and consumed only by sync, holding one row per changed record and none for a draft or a recording in progress; `sync_record`, holding CloudKit system fields and the last-synced text per record; `sync_state`, holding the engine's serialised state; and an FTS5 index over titles and segment text, maintained by triggers. A `tombstone` row, an ID with its dates and no content, outlives the purge of each deleted note and segment. `store_meta` holds the store ID, its generation and the device ID. `segment_history` is local and never syncs: it holds text that the command line or MCP replaced and, for a moved segment, the row described in §5, each for 30 days. `counter` is local too: daily counts with no content, which the diagnostics export reads (§19).
- **Deletes:** soft, through `deletedAt`. A purge job removes rows and files after 30 days and leaves a tombstone, so a device that returns after a long absence cannot bring a purged note back, and `knot changes` can still report the deletion.
- **Migrations:** forward-only and numbered. Only the app migrates. The `knot` tool never does: on a store older than itself it exits with code 7. Before each migration the app makes a copy with `VACUUM INTO` or SQLite's backup interface, because copying the file of a database in WAL mode is not safe. It checks that the copy opens and holds the same counts, and it does not migrate without one. It keeps the newest copy until the following migration. A migration never rewrites or deletes a recording or a drawing. A build that finds a database newer than it understands does not open it, change it or delete it. It says so, and capture continues into `Inbox/`. Rolling a build back therefore means restoring that copy, and the troubleshooting guide gives the steps. Restoring never deletes anything: the app and the tool are stopped first, the current store folder is moved aside whole with its files and kept, and the guide says how to export what was captured since. A restored store gets a new generation, so a cursor or a revision that an agent kept from before the restore is refused as foreign and never taken as current. With sync on, Knot asks before a restored store uploads.
- **Backups:** the store and its files are never excluded from device backups or Time Machine. A store folder copied to another place opens with every note and file, and WP-10 tests that. With sync on, a fresh install restores from iCloud.
- **Snapshots:** once a day the app writes a copy of the database in the same way and keeps seven. They hold text only, since recordings and drawings stay for 30 days after a delete anyway. Test builds show two actions in About: export the store as it is, which works when the store will not open, and restore a kept copy. A restored copy brings back text. A recording or drawing that was purged after the copy was made shows as missing, never as a broken player, and the restore says how many there are. Captures waiting in `Inbox/` live outside the store folder and are ingested after a restore as usual. At each milestone tag a seeded synthetic store made by that build is committed, with work in flight in it: an open capture, a queued job and a pending delete. Every later build must open each one, migrate it and then pass the whole `NoteStore` contract suite on it.
- **Second process on macOS:** the `knot` CLI opens the same file with the same KnotStore code. It posts a Darwin notification after writing. The app then refreshes its observers and feeds the change log to sync. GRDB's observation does not see another process, so the app tells its observers itself when the notification arrives. The notification is a hint. The app also compares the store's change counter with the one it last showed whenever it comes forward, and once a minute while it runs, so a write by a tool that died before it could post is still seen. Anything that writes many rows (a first restore from iCloud, a large inbox, the purge) commits in small batches and yields between them, so a capture never waits behind it. While sync applies fetched changes, the triggers that feed `change_log` are off on its connection, so a change that came from iCloud is not queued to go back.

## 8. Recording

- The file written during recording must be readable after the app is killed. It is Core Audio Format holding 16-bit linear PCM, mono, written through `AVAudioFile`. Its data chunk has no fixed size until the file is closed, so a reader takes the audio to the last complete frame. WP-12's proof step killed 90 recordings on the Mac and in the iOS and watchOS simulators, and lost nothing that had been appended. Fragmented MPEG-4 is not used: its writer does not exist on watchOS, and a file killed in its first three seconds cannot be read (§20). The kill test runs on the Mac in the package tests. In the iOS Simulator the Mac drives it, because a test there cannot start or kill a process. The gate runs the Mac's in every tier. The Simulator's runs at the gate's full depth when the diff reaches KnotAudio, and nightly, from WP-12's first pull request on.
- The working file keeps the input's sample rate from the start, for its whole length. A route change that changes the rate goes through a converter into it, or ends the recording. A recording's length is read from the file, never counted from what was appended.
- The file being recorded is synced to the drive every second (§6, rule 7), on a queue of its own and not on the audio tap's, because a sync can take over 100 ms.
- After stop, the audio is converted to AAC mono in `.m4a`, about 0.5 MB per minute, and verified. Only then is the working file deleted. Below 22.05 kHz the encoder takes at most 48 kbit/s, about 0.36 MB per minute.
- A recording is live when its manifest and its working file exist and the input runs, not when the first buffer has arrived. A start runs to live or to a typed error, and a stop always finishes: neither is tied to the task that awaits it. A recording can also end by itself, when the system takes the audio session, the input goes away, a write fails or the 30-minute limit is reached. The session then reports the ending with its reason, and a stop after it is safe.
- The live path feeds the same audio to the transcriber for on-screen text, copied into `Sendable` chunks of samples. The chunk is a KnotCore type, so that the contracts and their fakes need no audio framework, and the copy is small: 100 ms of mono samples at a time. The stream to the transcriber drops its oldest chunks when the transcriber falls behind, so slow text never costs audio.
- If conversion fails, the working file stays as the segment's recording and the queue retries the conversion.
- WP-12's proof step reports the working file's size per minute on each platform. On the watch, a 30-minute recording and its converted copy must fit together.
- A stored recording keeps a small array of level peaks beside it, written while recording, so that a waveform never needs the audio decoded.
- The saved recording state can outlive a crash, so it carries a heartbeat that the recorder writes every second. A state whose heartbeat is older than three seconds is stale: no recording is running. A heartbeat more than three seconds ahead of now is stale too, because a clock moved back. A press that meets a stale state recovers the orphaned recording and starts a new one, with the started cue, because a person pressing then is starting a recording. Controls show "recording" only while the heartbeat is fresh, the Live Activity carries a stale date, and launch ends an activity that has no recorder. A press while a recording is starting or stopping is ignored. In the app process the recorder itself is the truth: a press stops a recording that this process is running, whatever the heartbeat says. The heartbeat serves the controls and widgets of other processes, and recovery at launch. The rule for a press runs only in a process that has a recorder. Any other process hands the press to the app's process and never waits for an owner that may be dead. There, an idle recorder that finds a saved state recovers the orphan and starts, whether the heartbeat is fresh or stale.
- The recorder takes its audio from an injected source. Under test it refuses the hardware input, so no automated test and no proof run by an agent opens a microphone on the build Mac.
- If writing fails while a recording runs, for example because the disk filled, the recording stops with the stop cue and its reason, and everything written so far is kept.
- The authoritative transcript comes from transcribing the saved file after stop. Every recording then takes one code path, whether it started in the app, from an intent, on the watch, or was recovered after a crash.

## 9. Speech and cleanup

**Speech**

- `SpeechAnalyzer` with `SpeechTranscriber`. The locale is the English variant set in Settings: by default English as the device's region writes it, when `SpeechTranscriber.supportedLocales` holds that variant, and US English otherwise. `supportedLocale(equivalentTo:)` is not used, because it answers differently from run to run (§20).
- Model assets install through `AssetInventory`. Until they are installed, voice segments stay `recorded` and show as pending. Readiness is read from `installedLocales`, not from `AssetInventory.status`, which follows the process's own reservation. The app reserves its locale with `assetInstallationRequest` at launch, which reserves even when nothing downloads. The system gives no notice when a model arrives, so the transcriber checks again when an install it started ends and when the app comes forward.
- Speech is not available on watchOS.
- Transcription runs over a file in runs. A run starts at an offset, reads at most a budget of audio and ends at the last finished phrase, and the transcriber returns where the next run starts. A range fixed in advance could split a word. The queue saves the pieces and that time after each run, so an interrupted job continues from its last run and a long recording finishes across several short runs.
- The engine ignores the cancellation of the task that awaits it. The implementation stops it with `cancelAndFinishNow()`, and the port throws a cancellation within a second. A file with no frames is never given to the analyzer, which would not return: it is ready with empty text.
- A recording in which no words are recognised is ready with empty text, and shows as a recording.
- `SpeechTranscriber` is not available in the iOS Simulator on the build Mac (§20). Tests there use the scripted transcriber, and speech on iOS is proven on hardware.

**Cleanup**

- A `LanguageModelSession` on `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)`, and a new session for each request, because a session takes one request at a time. The body is generated as plain text in one call and never streamed: the guard needs the whole answer. The title is a second request, and its failure only drops the title. Guided generation of both at once is not used: in WP-14's probe it tripped the guardrails on harmless text (§20).
- Budgeting uses the model's own `contextSize` and `tokenCount(for:)`. A transcript that does not fit is split on sentence boundaries.
- The fidelity guard is a pure function. It compares cleaned and raw text as word sequences. WP-14 states the allowed differences as a table: letter case, punctuation, and paragraph and list breaks. A word may be removed in three cases only: it is in a closed list of filler sounds (um, uh, er, erm, ah, eh, hm, hmm, mm, mhm); it repeats the word or words that follow it; or it belongs to a restart of at most four words whose first two words come again straight after. A negation, a number, a name or a date word is never removed unless the same word comes back at the same place in what follows the restart. "Like", "you know" and "I mean" are not on the list, because they often carry meaning: whether they ever count as fillers is the owner's choice at the cleanup sitting. Nothing is inserted except punctuation and list markers, and numbers stay as the transcriber wrote them. The guard rejects a result with any other difference, and one that drops more than a set share of the words that are not filler sounds. WP-14 sets that share from its evaluation set, and its proof step uses 40% for now. A mutation suite is a merge criterion: for each evaluation transcript it drops a negation, changes a number, swaps a name, reorders two clauses and adds a word, and the guard must reject every one.
- When the model cannot be used on this device (ineligible device, Apple Intelligence off), the raw transcript is final. When the model is only not ready yet, or the system limits requests, the clean job is deferred and runs later (§4).
- A refusal, an empty or malformed result and a result the guard rejects all end the same way: the raw transcript is the text, and the log records which of them happened. The errors of Foundation Models can hold generated text, so the log records their case and never their description.
- A generated title is one line of plain text, at most 60 characters, made only of words that occur in the note. A title that fails this is dropped, and the stream shows the first line. The same check runs again when a segment leaves the note (§4).
- Cleanup runs with greedy sampling, so the same transcript gives the same result on the same model, and each cleaned segment records the OS build whose model made it.
- The guard proves that words are kept. It does not prove that added punctuation keeps the meaning. The evaluation set has cases in which only the punctuation differs, and they are reported with the meaning-critical ones.

## 10. Ink

- `PKCanvasView` wrapped for SwiftUI. Drawing data is saved at the end of every stroke.
- `PKStrokeRecognizer` produces the recognised text. It is stored on the segment, so every device can search it without recognising again.
- A Pencil-capability check decides whether the canvas is offered: iPad, and iPhone Duo. WP-18 finds the right API for that check on iPhone.

## 11. Sync

This section is the proposal that spike SP-4 tests.

- **Container:** `iCloud.com.p3ob7o.knot`, private database.
- **Zone `Stream`:** `Note`, `Segment` and `Setting` records, managed by CKSyncEngine. The text fields `title`, `text` and `rawTranscript` go in `encryptedValues`. That choice cannot be changed for a field once the schema ships.
- **Zone `Attachments`:** one record per asset, holding a `CKAsset`. This zone is excluded from the engine's automatic fetches, because CKSyncEngine otherwise downloads every asset eagerly. Assets upload from the device that made them and download on demand.
- **Local changes** reach the engine through `change_log`, so a write from any process syncs.
- **Conflicts:** new segments never conflict. When a text field changed on both sides since the last sync, the server value stays in place and the local value is inserted as a new segment with `conflictOf` set. The copy holds text only and no recording or drawing, so deleting either one never removes a file the other needs. Its ID is derived from the segment, the losing device and the losing revision, so handling the same conflict twice makes one copy.
- **Default:** the switch is on when the device is signed in to iCloud and the `sync` gate is open.
- **Who processes a recording:** the device that ingested it owns its jobs, and `processingOwner` on the segment says which. That is the capturing device, or the iPhone for a watch recording. Other devices show the segment's state and do not process it. Retry on another device moves ownership there. Each move raises `ownerGeneration`. A device writes the text it made only if it still holds the current generation, and otherwise drops its result, so two devices that both finished cannot both publish. Two devices that took the work at the same moment hold the same generation. Then the one with the higher device ID is the owner. Every device applies that rule when the records merge, not only the two that raced, and the other drops its result. An owner that no longer exists shows as "elsewhere", with the action to move the work here.
- **Appends to a deleted note:** a segment that starts after its note's `deletedAt` moves to a new note when the devices sync. The new note's ID is derived from the deleted note's ID, so every device computes the same one and several such segments stay together. A segment whose note record has already been purged is treated the same way. The comparison uses two devices' clocks, so it can misjudge captures made within seconds of the delete. A late segment never lands in a deleted note: if the derived note has been deleted too, the segment moves on to the note derived from that one. A segment whose note has simply not arrived yet waits for the fetch to finish, and only then counts as orphaned.
- **A moved segment:** a move (§4) syncs as a change to the segment's `noteID` and `noteGeneration`, together with the new note's record. The higher `noteGeneration` wins. Two sides with the same generation and different notes changed it at the same moment. Then a person's move or return wins over the deleted-note rule above, which the note's ID tells: a derived ID is a version 5 UUID and a fresh one is version 7 (§4). Between two notes of the same kind, the one whose ID sorts higher keeps the segment and the other is left empty. That uses the ID as a fixed tie-break, not as a time. A note that a move, an undo or a merge leaves empty is hidden, as rule 11 of the product spec says, and it is never marked deleted for that reason, so a segment that arrives in it later is not hidden with it. `knot changes` reports it as deleted, and the purge removes it once it has been empty and unchanged for 30 days. Deleting a note marks the note and not its segments, so a segment that another device had moved out before the two synced is no longer in it and stays. That holds until the purge: once the deleted note has been purged with the segments it then held, a move that arrives later does not bring the segment back, as for any change to a purged record. A segment that an undo returned to a note which another device has deleted is deleted with that note, as if the move had never been made, and is recoverable with it. A conflict copy is created in the note of the segment it copies, and follows it.
- **What a merge makes:** applying a fetched batch can make records of its own: a conflict copy, a derived note, or a note reference or an owner that it settled. Those are queued for upload in the same transaction, although the triggers are off on that connection (§7). Only a record applied exactly as it was fetched leaves nothing pending.
- **What syncs when:** a segment syncs once its capture has ended. Drafts and recordings in progress never sync.
- **Machine text:** a write by the processing queue never creates a conflict copy and never overwrites text whose origin is `edited`. Precedence is edited, then cleaned, then raw transcript.
- **Titles and deletes:** a title keeps the later edit. An edit that arrives for a deleted note is applied to the deleted copy, which stays deleted.
- **Settings:** the append window, the cleanup switch and the English variant sync. The hotkey, launch at login and the sync switch are per device.
- **Deletes** sync as `deletedAt`. The purge after 30 days deletes the records.
- **Account changes:** signing out pauses sync and keeps local data. Signing in to a different account asks the user before uploading anything.
- **Notes removed from iCloud:** if the zone is deleted or purged from iCloud, Knot keeps the local notes, pauses sync and asks before uploading again. It never deletes local notes because the cloud copy is gone. SP-4 tests each reason CKSyncEngine reports for a deleted zone.
- **Newer records:** a record kind or field this build does not know is kept and saved back untouched (§4).
- **Gate:** the `SyncEngine` exists only when the switch is on and the `sync` feature gate is open.
- **Production schema:** TestFlight builds use CloudKit's production environment, where record types and fields cannot be removed. The schema is deployed there only after M5, when two-device sync and attachment sync have passed on hardware. Moving a device from the development environment to production resets the engine's saved state and uploads the local notes again; SP-4 tests that switch.
- **Structure:** the rules of this section live in a merge core that has no CloudKit in it and works on Knot's own record values. A thin adapter turns CKSyncEngine's events into those values and back. The engine's events cannot be built in a test, so the replica simulation and every named sync test run on the core, and the adapter is proven by SP-4's harness and on hardware at M4.
- **A long absence:** a device that returns after more than 30 days must not bring back what was purged, and must not lose a capture it never uploaded. A record this device had synced and that iCloud no longer has is treated as deleted here. A record it never uploaded is uploaded. Tombstones (§7) back the same rule locally. The age of a synced delete is measured between two dates the server gave, the delete's own and the newest this device has seen, never against the device's clock, so a device whose clock runs ahead cannot purge early. SP-4 fixes the mechanism, and the simulation has a replica that stays away for 31 days.
- **Recordings and drawings:** an asset is local only, uploading or published, and the segment's record says which, so another device can say "not uploaded yet" and never shows a broken player. Uploads sit in a durable queue and resume. "Remove recording" during an upload cancels it and removes the remote copy when one exists. Transfers follow the system's Low Data Mode.
- **Account isolation:** the engine's saved state is kept per iCloud account and per CloudKit environment. So is `sync_record`: a record counts as synced only for the account, the environment and the zone identity it was synced under. The zone carries an identity of its own, written when the zone is made, so a zone that was removed and made again is a different zone. That keeps two rules of this section apart: a record missing from the zone it was synced to is deleted here, and a zone that is gone or new deletes nothing. A fetch that would delete more than a set share of the local notes pauses sync and asks. The first value is a tenth of them, an estimate. A change of account raises an account generation, and work started under the old one is dropped when it returns, so nothing queued for one account can reach another. Both answers to the upload question are defined: yes uploads the local notes to the new account, and no keeps sync paused.
- **The simulation's invariants:** it runs with two and with three replicas, and its interleavings include moves and their undos beside edits, appends and deletes. After any interleaving it checks six things. The replicas end equal. Nothing a replica acknowledged is missing. Nothing made after a delete sits in a deleted note. A conflict copy appears only when both sides edited the text. Applying a batch twice changes nothing. Every segment is in exactly one note, and a note with no live segment is never shown. Its named cases include a zone that was removed and made again, every replica uploading again after a change of environment, a replica whose clock runs 40 days ahead, two devices that take the same recording at the same generation, and every order of a move, its undo and a delete across three replicas.

## 12. Watch link

- **Watch outbox:** `<captureID>.m4a` and `<captureID>.json`. The manifest holds the capture ID, start, end, duration, device and checksum.
- **Send:** `WCSession.transferFile`, with the manifest as metadata. The watch keeps the file until the phone acknowledges that capture ID. The session's `didFinish` without an error is not a delivery: in the simulator it came for files that never reached the iPhone app. Only the acknowledgement moves a capture out of the outbox.
- **Receive:** the phone's delegate must move the received file before it returns, because the system deletes the file afterwards. It moves the file into `Inbox/` with `DurableFile`, checks it against its manifest, and acknowledges with `transferUserInfo` once it is durably there. Ingest follows and does not hold the acknowledgement, so a phone whose store will not open cannot fill the watch.
- **Coordinator:** the watch's sequence of record, convert and send lives in KnotLink beside the outbox, and the watch app only hosts it. It is tested on the Mac with kill points, and it finishes a conversion that a kill interrupted at the next launch.
- **Retry:** the watch re-sends unacknowledged captures when the session activates, when reachability changes, when either app comes forward, after each new capture, and on its background refresh. At launch it waits for the session's activation callback, adopts `outstandingFileTransfers` by the capture ID in their metadata before it queues anything again, and never queues again a capture that is still outstanding, so a relaunch makes no duplicate. Cancelling a transfer gives no delegate call, so the transport reports the cancel itself. A capture queued for longer than a set time with no `didFinish` and no acknowledgement, while the session is activated and reachable, is cancelled and queued again. That stall rule rests on the time since queueing until SP-2's sitting shows that a transfer's progress moves. Duplicates are harmless, because ingest is idempotent.
- **Checksums:** the phone checks each file against its manifest and acknowledges only a file that matches. On a mismatch the watch sends the file again. On the third mismatch the phone ingests what it received as a failed capture and keeps it, and it still does not acknowledge. The watch keeps its own copy, shows it as not delivered, and tries again when the session next activates. An intact delivery later replaces the damaged copy and makes the capture stored.
- **Back channel:** the phone sends the watch no note text and nothing about a transcript, because the watch is a capture device only (product spec §6). The watch learns that a recording arrived from the acknowledgement above. `updateApplicationContext` carries only what the watch needs to say whether a recording continues a note or starts a new one (product spec §3, rule 4): the end of the capture that a new recording would join, if there is one, and the window. The phone works that out by the rules of product spec §3, so a note closed by "New note" and a deleted note give none. What the watch shows is a forecast. The phone decides at ingest, by the recording's own timestamps. The Watch reads `receivedApplicationContext` at activation and does not wait for a callback at launch.
- **Testing:** in the 27.2 simulators neither files nor user info reach the other app, in either direction, while application context, from iPhone to Watch, and `sendMessage`, from Watch to iPhone, do. The logic is tested against a fake transport, and the real transport has no simulator test. Delivery is tested on hardware.

## 13. Processes and extensions

| Platform | Process | Opens the database | Role |
|---|---|---|---|
| iOS | App | Yes, the only one | Runs the intents that record or write notes, the processing queue and sync. |
| iOS | Widget extension | No | Controls, widgets and Live Activity views. Reads recording state from app-group defaults. |
| watchOS | App | There is no database | Recorder, outbox files, link. |
| watchOS | Widget extension | No | Complications, Smart Stack widget, control. |
| macOS | App | Yes | Everything, plus the hotkey and panel. |
| macOS | `knot` command | Yes, with the same code | Short-lived. Posts a notification after writing. Never migrates: it exits with code 7 on a store older than itself. |
| macOS | `knot mcp` | Yes, with the same code | Lives as long as its client's session. On every call it reads the access switch and the schema version again, inside the transaction, and refuses when access is off or the store is newer than the build. |

Launch, in the app process: the capture surface is on screen before any launch step runs, and typing does not wait for them (§6, rule 6). The steps are: open the store, recover recordings, finish drafts and drawings, ingest the inbox, resume jobs, start sync if it is on. A step that fails is logged with its code, and the steps that do not depend on it still run. The steps that need the store are skipped when it did not open. Jobs and sync start only after recovery and ingest have ended, so neither works on a half-recovered store. Each step has a breaker: if the last two launches died inside it, it is skipped and the diagnostics say so.

## 14. Intents and system surfaces

| Intent | Protocols | Runs in | Used by |
|---|---|---|---|
| ToggleRecording | `AudioRecordingIntent` and `LiveActivityIntent`. iPhone and iPad only. It starts a recording when idle and stops the one that is running. | App process | Action Button, controls, Siri, Shortcuts |
| StopRecording | `LiveActivityIntent`. iPhone and iPad only. | App process | Live Activity, Dynamic Island |
| StartRecording on the Mac | Opens the panel already recording, with a stop control | App process | Siri, Shortcuts |
| StartRecording on the Watch | Opens the watch app already recording. Whether it can start without the app in front is SP-2's question. It calls the watch recorder, not `CaptureEngine`. | Watch app | Complication, control, Siri |
| OpenCapture, OpenSketch, OpenSearch | Opens the app on the capture surface, the canvas, or the stream with search focused | App process | Widgets, controls, Shortcuts |
| CreateNote, AppendText | The system notes schema (`createNote`, `appendText`) | App process, in the background | Siri, Shortcuts |
| FindNotes | Entity query | App process | Shortcuts |

Rules taken from Apple's documentation, to be confirmed by SP-1:

- ToggleRecording and StopRecording must be compiled into both the app and the widget extension.
- The Live Activity must start with the recording and last as long as it does, or the system stops the recording.
- If Live Activities are off or the microphone permission is missing, the intent must open the app.

Intents reach the environment through the App Intents dependency manager, which the app registers at launch. The widget extension links KnotIntents for the types only, and no intent runs there. An intent reads the environment through one accessor that fails with a typed error when nothing is registered, so an intent that the system runs in the wrong process fails safely. That accessor is `@Dependency(default:)` with the unavailable environment as its default, because `AppDependencyManager` has no lookup that can fail: in a process that registered nothing, the intent gets the unavailable environment and throws the typed error. Every intent that writes declares `allowedExecutionTargets = [.main]` (OS 27), so the system cannot run it in the extension. The Live Activity's attributes type lives in KnotIntents and belongs to WP-19. WP-01 proves the packaging with one trivial intent that appears in both the app and the widget extension.

Shortcuts get StartRecording and StopRecording on every platform, and each is safe to repeat. ToggleRecording is for buttons: the Action Button and the controls.

On iPhone and iPad the intents that start a recording declare `supportedModes = [.background, .foreground(.dynamic)]`. They start in the background and call `continueInForeground` only when Live Activities are off or the microphone is refused, which is how the intent opens the app. StopRecording never needs the app in front and declares `[.background]`.

Knot's URL scheme only navigates: it opens the capture surface or a note. It never writes text and never starts a recording.

Intents on iPhone, iPad and Mac call `CaptureEngine`, and watch intents call the watch recorder. None contains storage code. `LiveActivityIntent` is used only on iPhone and iPad. The pinned SDK marks it unavailable on macOS (§20), so a type that adopts it, or that uses ActivityKit, is compiled for iOS only, inside `#if os(iOS)`. `canImport(ActivityKit)` does not tell the two apart, because it is true on the Mac too. The note entity is not indexed, so nothing about a note appears in Spotlight. Intents that only write may run on a locked device. Intents that read or pick a note require authentication.

## 15. Mac specifics

- **Hotkey keys:** a key with at least one modifier, or a function key. A modifier alone is not possible with this API. SP-5 proves press and release in a sandboxed build, and the panel over a full-screen app. If press and release do not arrive, the fallback is a listen-only event tap, which needs the Input Monitoring permission.
- **Hotkey:** Carbon `RegisterEventHotKey`. It delivers both press and release, and developers report that it works in the sandbox with no extra permission. A small state machine with a 250 ms threshold separates a tap from a hold. It times presses with a monotonic clock, and a release that arrives before the mark has been handled is a tap, so no press does nothing. A tap is known at key release, and the panel must accept typing within 100 ms of it. A hold is known at the 250 ms mark, and the microphone opens then, never on a tap, so the system's microphone indicator lights only for a recording. The audio engine is prepared at key-down, so that the microphone is live within 150 ms of the mark. SP-5 measures whether first words get clipped. If they do, the alternative is to listen from key-down into a buffer that a tap discards, on built-in and wired inputs only. Hold-to-record is exempt from the one-second discard.
- **Hotkey failures:** if the key is already registered by another app, Settings says so and asks for another key. If a release never arrives, the recording goes on with the panel showing and a stop control. Esc or another press of the hotkey stops it, and Knot checks the key's state every second while recording.
- **Panel:** an `NSPanel` that does not activate the app and joins every Space, including full-screen apps. It opens on the display that has the keyboard focus. A tap makes it the key window. A hold shows it without making it key, and it hides shortly after the text has arrived unless the pointer or the keyboard enters it. It has a microphone control that starts and stops a recording, for when a key cannot be held.
- **Menu bar:** a click opens the menu, as the system's convention has it. The icon shows when Knot is recording.
- **Activation:** Knot is an accessory app (menu bar only) that becomes a regular app while its main window is open.
- **CLI and MCP:** pending spike SP-3. The preferred design is a sandboxed executable inside the app bundle, carrying the app-group entitlement and opening the store directly. The fallback is a CLI that talks to the running app over XPC. SP-3 tests a sandboxed build signed for development. The owner planned the early upload at the review's gate: at G1 he creates an App Store Connect record for the development identifier and an API key, and one internal TestFlight upload of the spike app in wave 1 checks distribution signing. The upload runs only once he has handed over the key, and the key is revoked after each upload. The XPC fallback is built only if SP-3 fails in wave 1, never later. SP-3 is closed only when the route it chooses has passed the distribution-signed check: if the direct route fails there, the XPC route gets an internal upload of its own, and the report says what the tool does when Knot is not running. The Mac app-group identifier stays open until SP-3 reports. SP-3 also tests two packaging rules: a tool started from Terminal needs its own sandbox entitlements and an embedded Info.plist, and a bare executable cannot carry the provisioning profile that a `group.` app group needs, so the Team-ID form or a helper bundle may be the only route. SP-5 checks that reading the key's state once a second works in the sandbox without Input Monitoring. A sandboxed tool probably cannot write to a folder given as an argument, so SP-3 also decides how `knot export` delivers its output.
- **MCP:** standard input and output transport, tools only, written by hand, with conformance tests. It speaks the 2026-07-28 revision, which has no handshake, and also the handshake of the 2025-11-25 and 2025-06-18 revisions, because clients of both kinds are in use. WP-34 reads the specification before writing, as §21 requires for Apple's APIs. Nothing but protocol messages goes to standard output, and the server exits at end of input. While command-line access is off it keeps answering and fails each tool call with the reason, because a client restarts a server that exits.
- **One command table.** A single table of commands generates the command-line help, the usage errors, the MCP tool list, docs/cli.md and the golden tests, so they cannot drift apart.
- **Two builds, two names.** A development build installs the tool as `knot-dev`, and `knot status` prints the flavour and the store it opened.

## 16. UI layer and the design handoff

- `KnotUI/Theme` holds colour roles, the type ramp, spacing, radii and motion. Its values are placeholders until the Claude Design handoff arrives. WP-40 replaces them.
- View models hold the behaviour and are tested without views.
- Views stay thin, so restyling does not touch logic.
- Previews and UI tests run on `AppEnvironment.preview`: the fakes, with the real capture engine and queue over them on iOS and macOS.
- **The state matrix.** docs/design/brief.md §6 ends with a matrix of states by surface. KnotUIPreviews holds one named preview for every cell marked as designed, and a test fails when a cell has none. WP-40's side-by-side screenshots are rendered from those previews.
- **The direction.** `docs/design/direction.md` records the chosen direction: the answers to the brief's questions 1, 2 and 4, a structure sheet for the capture surface of each of the four devices (its regions, its navigation, and the component in each state), a link to the chosen prototype, and what stays open. The second PRs of WP-21, WP-30, WP-32 and WP-33, and all of WP-35, build from it.
- **Accepting the handoff.** Before WP-40 starts, the orchestrator checks the handoff against the matrix: every cell is designed or inherits from a named cell, and each capture surface is shown at the largest text size, with Reduce Motion and with the keyboard up. Gaps go back to the designer as a list, not as a second round.
- **Where the design changes structure.** The orchestrator lists every difference between the handoff and the built structure in `docs/design/deltas.md` and assigns each one. WP-40's ownership extends to the view models those differences touch. Where the handoff is silent, the implementer uses the system default and adds a line to the same file, which the owner clears at M6.
- **When the mock and the system differ.** The system component wins over the mock's pixels, and each deviation is recorded. Type maps to Dynamic Type text styles, colour to roles, and materials to system materials. Controls, complications, widgets and the Live Activity take their glyphs, strings and content from the handoff and their rendering from the system.

## 17. Testing

| Layer | What is tested | Where it runs |
|---|---|---|
| Rules and state machines | Table-driven tests with a fake clock | `swift test` on the Mac |
| Contract suites | One shared suite per port, run against both the fake and the real implementation | Mac, and the iOS Simulator for what runs only there (§5): those suites are hosted in the iOS app, in the `Knot-iOS-Tests` target, and the gate's `ios-hosted` step runs them |
| Store | Migrations, search, concurrency, a kill in mid-transaction, a second process | Mac |
| Recorder | File-driven input, the kill test, interruptions | Mac and iOS Simulator |
| Speech, cleanup, ink | Fixtures, with accuracy reported | A Mac with the models installed |
| Sync | Mapping, conflicts and the change log, with constructed records; a two-replica simulation | Mac |
| End to end | Fixture audio through to a finished note; kill and relaunch | Mac and Simulator |
| UI smoke | Type, record with injected audio, search, delete and undo | XCUITest on iOS Simulator and Mac |
| Hardware | Action Button, Lock Screen, hotkey, Pencil, watch delivery, real sync | Paolo, from `docs/checklists/` |

Rules:

- Fixtures are synthetic. Real notes and recordings never enter the repository or a test.
- Storage, capture, ingest and sync need failure-path tests through the production interface.
- A test that needs an on-device model reports "skipped: model unavailable". It never passes silently.
- A merge-gate run requires the on-device models on the Mac, where a skipped model test fails the run. In the iOS Simulator speech is always the scripted transcriber, because the real one is not available there, and cleanup may be the real model. `scripts/doctor.sh` probes both models before a gate run.
- The owner's own recordings never enter the test suite or the repository. The two `knot-eval` commands may read them from the folder that `KNOT_LOCAL_FIXTURES` names, which sits outside every worktree (§18). They print numbers only, and they write transcripts and the ten cleanup pairs back into that folder, never anywhere else.
- The capture ledger soak test is seeded and time-boxed. It uses the scripted transcriber, cleaner and recogniser, clips of at most two seconds and an injected clock. The harness is a parent process that starts a child over the real store, kills it at points the seed chooses from a named list, and relaunches it. The parent is the witness: the child reports each acknowledged capture with its revision and a hash of its content, the parent keeps that list, and after recovery it checks every entry against the store. A capture that vanished whole therefore fails the run. The run ends with one consistency check, shared with the store's tests and the diagnostics export: capture, segment and job rows agree, no capture ID is stored twice, and the foreign keys and the search index are clean. WP-06 builds the harness right after the store's first PR, and WP-11, WP-12 and WP-15 each add their kill points in their own PRs. It runs at each milestone and in the merge gate of any PR that touches KnotCore, KnotStore, KnotCapture, KnotAudio, KnotApp, the harness or the pinned GRDB version.
- Mac UI tests need the one desktop session, so they queue on an exclusive slot.
- These failure tests are required by name: two processes recording captures at once; a late draft save that must not replace newer text; an edit that arrives while a clean job is paused; a delete while a job runs; an interrupted transcription that continues from its last range; an unreadable inbox item; a checksum mismatch from the watch; a zone removed from iCloud; a hotkey release that never arrives; search text full of query syntax; a clock moved backwards; a database newer than the build; a store that will not open; a press while the saved recording state is stale; a record with an unknown kind. The engineering review added these: a capture begun before the store is open, during a migration and while another process holds the write lock; a checkpoint from `Inbox/` older than the stored text; the same capture ID with different content; a job found running at launch twice; a disk that fills during a draft save, a recording, ingest and a migration; a long typing session with sync off that leaves no more `change_log` rows than records; a fetched change that leaves nothing pending; a segment record that arrives before its note; a kill between applying a batch and saving the engine's state; a store restored from an older copy; a segment at the size limit; a change of account with uploads pending; a replica that stays away for 31 days; two devices that both finish the same recording; and export names made from hostile titles. The owner's answers at the review's gate added these: a segment moved on two devices before they sync; a move that meets a delete of the note it left; an undo that returns a segment to a note deleted elsewhere; a kill inside a move; and a container that still holds the retired app's files. The second engineering pass added these: a store call that commits after its capture fell back to `Inbox/`; a move repeated after a capture joined the new note; a return after the segment's note changed again; a move that arrives after the purge; a merge result that must be uploaded; a tool that dies before its notification; a revision from before a restore; text that runs past the size limit, repeated; an inbox item of a newer version, ingested after an update; an emptied note that appears in `knot changes`; `StoreLocations` with a missing group container; and a kill during the pre-migration copy.
- The checks are shown to fail. WP-06 merges only when four injected faults each turn the soak red: an acknowledgement before the write, a skipped capture row, a dropped last checkpoint and a capture stored twice. The `NoteStore` contract suite runs against three deliberately broken fakes, one that ignores a repeated capture ID, one that lowers a revision and one that loses a move's history, and must fail each.
- A seeded differential test applies random sequences of operations to the in-memory `NoteStore` and to the real one and compares every result. WP-34's golden tests run on both.
- Kill tests need a process to kill. WP-01 declares a small crash-host executable for KnotStore, for KnotAudio, for KnotLink and for KnotInk, and the soak's child.
- The nightly run executes the package tests under Thread Sanitizer. A lint keeps `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` to a reviewed list. A recorder test feeds 30 minutes of injected audio and counts the same frames out.
- Every query in the `NoteStore` contract has an index, and a test shows the query plan. A stream page is one query.
- A PR that changes the cleanup instructions, the guard or the speech settings reruns the cleanup evaluation and `knot-eval`, and states the results before and after.
- Accuracy thresholds are checked in the package PRs that own them and at milestones. The merge gate only requires that model tests ran.
- Package tests use Swift Testing: tables as parameterised tests, and a tag on every test this section names. XCTest is used for UI tests and for measured performance only. A contract suite is a set of functions in KnotTestSupport that take a factory, and each implementation's test target calls them. WP-01 proves that arrangement with one dummy port before WP-02 relies on it.
- `docs/plan/named-tests.txt` lists every test this section names with the package that owns it. The gate fails when a listed test is missing once its package has merged.
- One UI smoke test on each platform runs the app on `.live` with a temporary store: type, kill, relaunch, read. The other UI tests stay on `.preview`.
- The end-to-end suite carries a canary. Its fixtures hold a made-up word, and the test fails if that word appears in any log line, error or diagnostics file.
- Search is checked against a plain scan. For a seeded store, whole-word and prefix queries return the same notes as a scan of the text, across typed, spoken and handwritten segments and titles, and never a deleted note.
- Every UI smoke test runs the system's accessibility audit, which exists on all four platforms. Exclusions sit in one file, each with a reason. WP-41 makes the audit clean on every designed cell of the state matrix. The preview test reads that matrix from the brief's own table, so there is no second list to keep in step.
- Time thresholds are not merge criteria. The gate asserts query plans and counts of operations. Times are measured by `scripts/verify.sh --perf`, which takes every build slot, at milestones and in WP-42, on an optimised build with a seeded store of 10,000 notes and 20,000 segments.
- The scripts have a self-test that `--quick` runs: a slot is released when its holder is killed, a failure prints the agreed fields, and the plan check catches a brief with a missing heading.

## 18. Build, tools and parallel work

- `.xcode-version` names the Xcode for the merge gate and the archive. Every script sets `DEVELOPER_DIR` from it and checks `xcodebuild -version` against it, so nobody has to remember a prefix. The beta Xcode is used only when a command names it.
- `scripts/bootstrap.sh` checks the prerequisites first (Xcode, XcodeGen at its pinned version, the simulator runtimes) and then generates the Xcode project. A missing prerequisite stops it with the command that installs it.
- `scripts/doctor.sh` runs first in every verify run and fails at once on a machine setting no agent can change, such as Automation Mode for Mac UI tests. It also refuses to run below a floor of free disk space. It refuses a repository, a build folder or a fixtures folder that a cloud file provider syncs, which is where the stray "… 2" copies in the retired tree came from. It probes that the gate's signed step can sign without a prompt.
- `scripts/verify.sh` has five tiers, and one run takes one tier: `--quick` checks formatting, builds the package and runs its tests; `--full` adds every app build and the UI smoke tests; `--soak` runs the capture ledger soak test, with `--seed` to repeat a run; `--perf` measures the timed targets and takes every build slot; `--gate` is what the orchestrator runs before a merge. `--only <step>` and `--module <name>` run one part, and `--skip mac-ui` is for implementers. The gate chooses its own depth from the diff, by the table below, prints the depth and the reason, and refuses `--only`, `--module` and `--skip`, so a partial run can never be called a gate.
- Every run ends with one summary line: counts, skips, duration, the Xcode version and the macOS build. It also keeps a status line of at most 140 characters, which `--status-line` prints for the tree it checked, and the orchestrator posts that one as a commit status. A failed step names itself, its log file and the command that reruns only that step. A failed soak also prints its seed, its kill point and where its store was kept.
- Every script reports failure through one function in `scripts/lib/fail.sh`: a stable code, what failed, the fix, whether a retry is safe, and what was changed.
- Each worktree builds into its own `.build/` and DerivedData, uses simulators named after the worktree, and gives its development builds a store of their own (§7). `scripts/worktree-remove.sh` removes all three, with the worktree's folder in the Mac development container. Agent builds turn the index store off, and each worktree keeps a small fixed set of simulators.
- `scripts/build-slot.sh` limits concurrent heavy builds on the machine. The default is 3. A slot is a lock the system releases when its holder dies. It uses `/usr/bin/lockf`, which ships with macOS; `flock` does not. One of the three slots is kept for the gate. A waiting script prints a line each minute and gives up after a set time, naming the holders. Mac UI tests queue on one exclusive slot, and the script also limits how many simulators are booted at once.
- Builds for tests use a local configuration that keeps the sandbox and leaves out the entitlements that need the owner's signing profile, with sync switched off. Device builds, milestone builds and the spikes use registered identifiers and the owner's signing: the development set for device builds and spikes, and `com.p3ob7o.knot` with its group and container for milestone builds only (§7).
- The owner's recordings live in one folder outside every worktree, named by `KNOT_LOCAL_FIXTURES`. `knot-eval --set synthetic` runs on committed fixtures and `--set local` on that folder. Either one exits with a code when its input or its model is missing. It never waits. For each recording `<name>.m4a` in that folder, `knot-eval speech` writes the raw transcript, and nothing else, to `<name>.transcript.txt` beside it, and `knot-eval cleanup` reads those files and writes `cleanup-pairs.md` there. The exit statuses are 2 for wrong arguments, 3 for a command that is not built yet, 4 for missing input and 5 for a missing model.
- `scripts/install.sh` exits non-zero when it missed a device, and a rerun skips the devices that already hold the build. `devicectl` does not install onto a Mac, so for a Mac the script writes the build to a folder the owner names, and he opens it there. From the M4 milestone build on, no milestone build is installed or run on the build Mac.
- A milestone build is made with a level, M1 to M7. A feature whose milestone has not passed is switched off in it by a gate, and a test lists the gates for each level: sync and the command line open at M4, and ink at M5. A fix for an earlier milestone is built at that milestone's level, so it carries no feature that has not had its sitting.
- `scripts/release.sh` takes the App Store Connect key as a file path only. In a dry run it prints the names of its variables and never their values. After a failed upload it says to check App Store Connect before a retry. It belongs to WP-43.
- `scripts/sdk-path.sh <platform> <framework>` prints where the Swift interfaces of the pinned Xcode are (§21).
- Formatting uses `swift format` from the toolchain with the checked-in configuration. After WP-01 merges, `scripts/` belongs to the orchestrator.

**The gate's depth.** A fixed table maps the changed paths to a depth, and the gate applies it without anyone choosing:

| The diff touches | The gate runs |
|---|---|
| Documents only | The plan check and the link check. No build. |
| One leaf module (Speech, Cleanup, Ink, Export, Link, Intents, Agent, or a widget folder) | The checks below, the package tests with the models required, a build of every app, and the UI smoke tests that module can reach |
| KnotCore, KnotStore, KnotCapture, KnotAudio, KnotSync, KnotUI, KnotApp, an app shell, `Package.swift`, `project.yml`, `scripts/`, entitlements or the pinned GRDB version | Everything: the same on every platform, the two-process test, the `.live` smoke tests, and the soak where §17 asks for it |

Every depth starts with the same checks: `doctor`, formatting, path ownership (the diff stays inside the paths the package owns), the contract check on KnotCore, the import check, the named-test list, the dependency pins, and a lint for a team ID, a network call, logged text, the standard defaults domain (§7), `eraseDatabaseOnSchemaChange`, an unlisted concurrency escape (§17), a required-reason API with no declared reason (§19), and a file whose name ends in " 2". The lint reads names and patterns, not meaning: a pass is not proof that no note text is logged, so the review reads for that, and reads every line that a `knot-lint: allow` comment excuses. The team-ID check is pending until the owner's signing configuration is on the Mac. Mac UI tests run only where the table reaches the Mac app or KnotUI, and nightly, because they take over the desktop. WP-01 measures each depth. The aims are 12 minutes for a leaf and 25 for everything, both estimates. A step whose suite is not built yet is listed in `scripts/gate-steps.txt` with the package that delivers it, and it becomes required when that package merges. A nightly run on `main` does everything, with a fresh soak seed and on the iOS 27.0 runtime as well, which is the oldest system Knot supports.

**The merge queue.** GitHub's own queue is not offered to a repository owned by a personal account, so the orchestrator runs one.

- One pull request at a time. The order is contract PRs, then fixes for a red `main`, then the chain to the next milestone, then the rest by dependency.
- A PR enters when its review verdict is recorded, the `--quick` summary is on its head and the ownership check passes. From then on its branch is frozen.
- The orchestrator brings the branch up to date in its own gate worktree. When `main` has moved, it merges `main` into the branch, and once the gate has passed on that merge it pushes it as an ordinary push. It never rebases a branch that was pushed and never forces a push. A conflict goes back to the implementer. It runs the gate on that exact head, posts the status `knot/gate` with the summary line, and merges with `gh pr merge --squash --match-head-commit`. The candidate is three hashes: the base, the head and the tree. If `main` or the head moved, the result is void. After the merge it checks that the tree on `main` is the tree it tested.
- The ruleset on `main` requires a pull request, squash merges, the status `knot/gate` and a branch that is up to date. The owner applies it at G1.
- A failed step is rerun once, and only for an infrastructure code from `fail.sh`. A test that passes on a rerun is logged with an owner. The soak is never rerun to green, and storage, capture and sync tests are never set aside.
- A red night stops the queue. The cause is found by bisecting the squash merges, and it is reverted unless the fix is plain.
- A contract PR is additive where it can be: a new requirement comes with a default that throws the typed unavailable error, so open branches still compile. A breaking one carries the mechanical edits to every conformer and call site, as a stated exception to path ownership. A contract PR that only adds merges in the normal queue. One that breaks merges at one of two fixed times a day.
- Each pull request has a branch of its own. A branch whose pull request was squashed gets no further commits: the thread starts the package's next pull request on a new branch from `main`.
- Stacking happens only inside one package, and a stacked branch stays local until its base has merged. The thread records its fork point, rebases with `--onto` after the base is squashed, and only then pushes the branch for the first time.
- After the queue has updated a branch, its thread fast-forwards to the remote branch before it changes anything else.
- A pull request that did not come from one of the project's own threads is never run through the gate before its diff has been read, because the gate runs its code on the owner's Mac. The scripts that drive the gate come from `main`, not from the branch.
- macOS and Xcode on the build Mac are updated between milestones, never while one is being closed.

**The orchestrator's state.** It can be rebuilt from the repository, GitHub and one file.

- The briefs in `docs/plan/` carry what does not change: what each package owns, what it starts after and how many PRs it has, in a header a script can read.
- GitHub carries what changes: a branch name gives the package, labels give the queue state and a blocked code, and commit statuses carry the `--quick` and gate summaries. `scripts/status.sh` prints the table from those. `docs/status.md` is that output, written to `main` only at milestones.
- A journal in the build folder outside every worktree records each operation before it starts and when it ends, with the base, the head and the tree: a thread launched, a PR queued, a branch update pushed, a gate run, a merge, a worktree removed, a milestone build, an install. After a reset the orchestrator reads `docs/orchestrator.md`, runs `scripts/status.sh`, compares the journal with GitHub and the worktrees, and finishes or undoes an operation that was cut short before it does anything new. A release step that was cut short is never resumed. It goes back to the owner.
- At M1 a fresh thread takes over from the runbook alone, as a drill.

**What stays out of the repository.** The signing team's ID is not a secret, since it is in every signed app, but it ties the project to one account. It lives in a git-ignored `Local.xcconfig` in the build folder outside every worktree, named by `KNOT_LOCAL_CONFIG`, which `scripts/bootstrap.sh` links into a fresh worktree. Entitlements use the team prefix variable, code reads group identifiers from the Info.plist, and the lint fails when the local file's value appears in a tracked file. The repository is public, so it never gets a self-hosted runner. Its workflows hold no secrets, never use `pull_request_target`, have read-only permissions and pin their actions by revision. GRDB's revision is pinned as well as its version, and `scripts/verify.sh` checks it for SwiftPM and for Xcode, because the generated project's lock file is not committed.

## 19. Privacy and security

- **Entitlements:** app sandbox on the Mac, app group, iCloud with CloudKit, push (CloudKit uses it for change notifications), microphone, background audio.
- **Network:** CloudKit and Apple's model downloads only. Knot contacts no other host.
- **Logging:** `Logger` with categories. Logs hold IDs, counts, durations and error codes. They never hold text, transcripts, content-derived file names or audio.
- **Privacy manifest:** declares no collected data, and a required reason for each API that needs one, in every target. The SP-3 upload carries the manifests, so App Store Connect checks them in wave 1. The pull request that brings such an API into a module adds its reason to the manifest of every target that links the module, even where the manifest is another package's (PLAN.md §8.5). The gate's lint fails when one is missing in a target that its list names, and the review checks the reason's code.
- **Another program on the device:** the store defends against a crash, a kill and a power cut. It does not defend against a program that runs as the user and rewrites the store's folders while Knot runs: such a program can make Knot lose or misplace data, as it could by deleting the folder.
- **Errors:** every case of the error taxonomy carries a stable code, what to do next, whether a retry is safe and how often, and what was written. The command line, `--json`, MCP results and log lines all render from that one value. docs/errors.md has an entry for each code, and a test fails when a case has none. An unexpected failure carries a request ID and the command that shows its trace. No error ever contains note text.
- **Command-line access:** the `knot` tool refuses commands until the owner turns on command-line access in Settings on that Mac. It is off by default. While it is off the MCP server keeps answering and fails each tool call with the reason (§15). Deletes made through them are soft, and no command purges. Tool results mark note text as data, not as instructions. The switch is consent, not a wall: any program running as the user can reach the file itself, and the privacy text says so.
- **Diagnostics:** test builds can export a diagnostics file from About: capture rows without their content hash, job rows, the daily counters, signpost timings, the build and the OS. The counters (§7) hold captures by kind, captures and jobs that failed, uses of "New note", moves and returns. A move counts when it is made, a return counts apart, and a repeat that changes nothing counts as neither. The keep-gate sitting reads them (PLAN.md). It holds no note text, no titles and no content-derived names. Every log line about a capture carries the capture ID, which is the same on the watch, the phone and the Mac.
- **Search input:** search text is turned into a quoted query. Query syntax never reaches the full-text index raw.
- **Privacy text:** the README and the App Store privacy text say exactly what iCloud encrypts end to end and what it does not, checked against Apple's documentation when WP-43 writes them.
- **Agents and the owner's notes:** the build agents run as the owner's user. They use `knot-dev` from their worktree and never `knot`, their threads export `KNOT_AGENT=1` (§7), and the MCP server for the real store is registered for one personal folder, not for the user. By the owner's decision of 2026-11-19 the build Mac holds no real notes while the build runs, and from the M4 milestone build his real notes on a Mac live on his other Mac.
- **Text from outside:** agents act only on the project's own `wp/`, `spike/` and `contract/` branches. They never read issue or pull-request comments from GitHub, and review findings travel between threads. During the build the repository limits interactions to collaborators.
- **Limits at every door:** an MCP frame, piped text, a manifest and a synced record are each bounded in size (§4), and a file's path comes from its ID.
- **The microphone:** no automated test and no agent opens a hardware input on the build Mac (§8).

## 20. Platform facts

"SDK" means the declaration was read in the 27.3 beta SDK on this Mac on 2026-11-18. The code is built against the SDK of the pinned Xcode, and `scripts/sdk-facts.sh` is the check of those rows against it. Where the pinned SDK and the beta's differ, the row says so. "Apple docs" and "reported" come from the research of the same day and were not re-checked.

| Fact | Status |
|---|---|
| The Speech framework is absent from watchOS. `SpeechAnalyzer` and `SpeechTranscriber` are marked unavailable there. | SDK |
| watchOS has no ActivityKit, PencilKit or PaperKit. `LiveActivityIntent` is unavailable on watchOS. | SDK |
| `AudioRecordingIntent` is available on watchOS 11 and later. | SDK |
| watchOS has CloudKit with `CKSyncEngine`, SwiftData, WidgetKit, AppIntents, WatchConnectivity and FoundationModels. | SDK |
| `ControlWidget` is available on iOS 18, macOS 26 and watchOS 26. `handGestureShortcut` is available on watchOS 11. | SDK |
| `LongRunningIntent` exists from OS 27, with `performBackgroundTask`. | SDK |
| `AppIntent.allowedExecutionTargets` exists from OS 27. With `[.main]` the system runs an intent only in the app, though its type is compiled into the widget extension too, and the metadata of both bundles records it. | SDK and the metadata, read by SP-1 on 2026-11-19. |
| An intent's `authenticationPolicy` defaults to `.alwaysAllowed`. | SDK and the metadata, read by SP-1 on 2026-11-19. |
| `IntentSystemContext.preciseTimestamp` is recorded only for the Action Button of an Apple Watch Ultra. | Apple docs, read by SP-1 on 2026-11-19. |
| `BGContinuedProcessingTaskRequest` is submitted from the foreground, as a result of a person's action, and its task must report progress. In the iOS simulator it fails as unavailable, `BGTaskSchedulerErrorDomain` 1. | Apple docs, and observed by SP-1 in the iOS 27.2 simulator on 2026-11-19. |
| `BGTaskScheduler.submit(_:)` is deprecated in OS 27 for `submitTaskRequest(_:)`. | SDK, read by SP-1 on 2026-11-19. |
| ActivityKit's `Activity` is not `Sendable`. | SDK, read by SP-1 on 2026-11-19. |
| `LiveActivityIntent` and ActivityKit's `ActivityAttributes` are marked unavailable on macOS in the 27.2 SDK. The 27.3 beta SDK offers both from macOS 27.3. `canImport(ActivityKit)` is true on macOS with either. | SDK, both read on 2026-11-19 |
| The notes schema offers `createNote`, `updateNote` and `appendText`. It is unavailable on watchOS. | SDK |
| Xcode warns when an app lists a statically linked package in `AppIntentsPackage.includedPackages`, because that package's metadata is already included. Warnings are errors, so the apps declare no `AppIntentsPackage` of their own. | Found by WP-01's build with Xcode 27.2. |
| `PKStrokeRecognizer` exists on iOS and macOS, with an async `search`. | SDK |
| `SystemLanguageModel` exposes `availability`, `contextSize`, `tokenCount(for:)` and `supportedLanguages`. | SDK |
| `SpeechTranscriber` exposes `isAvailable`, `supportedLocales` and `installedLocales`. `AssetInventory` exposes `assetInstallationRequest(supporting:)`. | SDK |
| A recording started by intent needs both protocols and a Live Activity for its whole length. | Apple docs |
| The Lock Screen capture extension is camera-only. There is no third-party text field on a locked iPhone apart from a notification's reply box. | Apple docs |
| The Pencil Lock Screen tap and the corner-swipe Quick Note open Apple Notes only. iPhone and iPad have no global hotkey. | Apple docs |
| Starting a recording from a locked iPhone works for third-party apps. | Unconfirmed. One developer reports a failure. SP-1. |
| A watch app cannot open text input straight into dictation. | Reported |
| `WCSession.transferFile` can stall with no error until Bluetooth is toggled. | Reported. SP-2. |
| A file transfer's `didFinish` comes without an error for a file that the iPhone app never received. It is not a delivery. | Simulator, 2026-11-19 |
| Cancelling a file transfer acts at once, and no delegate call ever comes for it. | Simulator, 2026-11-19 |
| A file transfer's progress counts 100 units, a percentage, whatever the file's size. | Simulator, 2026-11-19 |
| Transfers that finish while the Watch app is not running report their `didFinish` at its next launch, straight after activation, in queue order. | Simulator, 2026-11-19 |
| `transferFile` is accepted before the session's activation completes, and the transfer waits in the queue. | Simulator, 2026-11-19 |
| `sendMessage` from the Watch launches an iPhone app that is not running, in the background. | Simulator, 2026-11-19 |
| Installing the iPhone app does not install its Watch app. A Watch app installed apart counts as not installed on the iPhone for several seconds, and the iPhone drops what arrives meanwhile. | Simulator, 2026-11-19 |
| A watch recording continues with the wrist down once started in the foreground. | Reported by an Apple engineer in 2024. SP-2. |
| CKSyncEngine downloads assets eagerly and offers no way to fetch selected fields. | Reported. SP-4. |
| iCloud Drive is unavailable on watchOS. | Apple Q&A from 2017 |
| Carbon hot keys work in the Mac sandbox without extra permission. | Reported. SP-5 proves it. |
| The Mac Studio has no built-in microphone. | Apple's specifications. Hold-to-record needs an external one there. |
| A sandboxed command-line tool cannot write to an arbitrary folder passed as an argument. | Expected from the sandbox rules. SP-3 confirms. |
| TestFlight may refuse a build made with a beta Xcode. | Unconfirmed, and no longer in the way. The owner installed the release Xcode 27.2 (27B52) on 2026-11-19, `.xcode-version` pins it, and the merge gate and the archive use it. The 27.3 beta stays installed and is used only by name. |
| The system turns Pencil writing in a text field into typed text by default. | From memory of OS 26, not checked in the 27 SDK. WP-35 checks before relying on it. |
| An iPhone Live Activity also appears in the Watch Smart Stack and the Mac menu bar. | From memory of OS 26, not checked. WP-31 checks, and decides what a tap there does. |
| Mac UI tests need Automation Mode, and enabling it on this Mac asks for a password. Developer mode is off. | Checked with `automationmodetool` and `DevToolsSecurity` on 2026-11-19. The owner enables both once at G1. |
| `xcode-select` points at the Command Line Tools, which have no iOS or watchOS SDK. | Checked on 2026-11-19. The scripts set `DEVELOPER_DIR` themselves. |
| The current MCP revision is 2026-07-28. It has no `initialize` handshake, and requires `server/discover` and a `resultType` on every result. | The specification's changelog, read on 2026-11-19. WP-34 reads it again before writing. |
| On-device cleanup quality for transcripts is thin: one developer measured the OS 26 model at 66% on general polish and 13% on spoken self-corrections. | Reported. WP-14's proof step on 30 synthetic cases, on OS 27: before the guard 2 answers changed the meaning, and the guard refused both and 2 more. The owner's own notes follow. |
| The system SQLite on this Mac, 3.54.0, defaults to `fullfsync` off, `checkpoint_fullfsync` on and `synchronous` FULL. | Checked with `sqlite3` on 2026-11-19. WP-10 sets `fullfsync` and measures the cost. |
| GitHub's merge queue is offered to repositories owned by an organisation. This one is public and owned by a personal account. | GitHub's announcement of 2023, and `gh repo view` on 2026-11-19. Not checked against today's documentation. |
| The ruleset on `main` blocks deletion and force pushes only. | `gh api` on 2026-11-19. The owner extends it at G1. |
| `performAccessibilityAudit` exists on macOS 14, iOS 17 and watchOS 10. | SDK |
| `CKSyncEngine.Event.FetchedRecordZoneChanges` has no public initialiser. | SDK. The merge core is tested on Knot's own values. |
| `SpeechTranscriber` reports itself unavailable in the iOS simulators on this Mac, inside an app as in a bare executable, while Foundation Models is available there. `DictationTranscriber` lists English locales there, and was not tried further. | A reviewing agent's probe in the iOS 27.0 and 27.3 simulators and WP-13's probe inside an app in the iOS 27.2 simulator, both on 2026-11-19. |
| Cancelling the task that awaits `SpeechAnalyzer.analyzeSequence` does not stop it. `cancelAndFinishNow()` does: the call then returns normally and `results` throws `CancellationError`. | WP-13's probe on 2026-11-19. |
| On a file with no frames, `finalizeAndFinishThroughEndOfInput()` never returns and `results` never ends. | WP-13's probe on 2026-11-19. |
| A supported locale whose speech model is not installed fails with `unexpectedAudioFormat`, not `noModel`. | WP-13's probe on 2026-11-19. |
| `AssetInventory.status` follows the process's own reservation, and `installedLocales` reports the model on disk. A process may reserve at most 5 locales. The API names no model or asset version, and gives no notice when a model arrives. | WP-13's probe on 2026-11-19. |
| `supportedLocale(equivalentTo:)` answers differently from run to run for a region with no English variant of its own. | WP-13's probe on 2026-11-19. |
| `AVAudioPCMBuffer` is not `Sendable`. From OS 27 an audio tap is installed with `installAudioTap(onBus:bufferSize:format:tapProvider:)`, which throws and hands a `@Sendable` provider an `AVReadOnlyAudioPCMBuffer`, which is. `installTap` is deprecated. `AVAudioFile` is `Sendable` from OS 26. | SDK, read by WP-12, WP-13 and SP-1. |
| `AVAssetWriter` and `AVAssetReader` are unavailable on watchOS, and AudioToolbox is not in the watchOS SDK. `AVAudioFile`, `AVAudioConverter` and `AVAudioEngine` are there. | SDK, read by WP-12. |
| From OS 27 `AVAudioSession.interruptionNotification` is deprecated in favour of `didBecomeInactiveNotification` and `resumptionRecommendationNotification`, and reading past the end of an `AVAudioFile` throws. | SDK, read by WP-12. |
| `AVAudioFile` writes a Core Audio Format data chunk of size -1 and reads such a file to its end. A full volume makes its write throw OSStatus -40, not `ENOSPC`. AAC mono takes 64 kbit/s only from 22.05 kHz. | WP-12's proof on macOS 27.3, 2026-11-19. |
| `AVAssetWriter` with movie fragments writes about the first three seconds of audio before its `moov` box, so a file killed earlier is unreadable, whatever the fragment interval. | WP-12's proof on macOS 27.3, 2026-11-19. |
| In OS 27 `AVAssetWriter.addInput`, `startWriting` and `expectsMediaDataInRealTime` are deprecated in favour of `inputReceiver(for:)`, `start()` and `appendImmediately`, which exist from OS 26. `AVAudioFile` reports its failures as OSStatus codes under the domain `com.apple.coreaudio.avfaudio`. | SDK and WP-12's proof, 2026-11-19. |
| On the build Mac a sync of the working file takes about 5 ms and once took 123 ms, and a recording is live 13 ms after its start when warm, on injected audio. | WP-12's proof, 2026-11-19. Measurements on the Mac's drive, not a phone's or a watch's. |
| On the build Mac a ten-minute file is transcribed in 6 to 8 s, and in runs of 20 s with almost the same accuracy. | WP-13's proof on synthetic audio, 2026-11-19. A measurement, not a target. |
| The on-device model's `contextSize` is 8192 on the build Mac, which holds about 20 minutes of speech in one cleanup request. | WP-14's probe on 2026-11-19, with the model "AFM 3 Core Advanced" on macOS 27.3. |
| A cancelled `ResponseStream` that is iterated ends without an error, and `collect()` throws. `respond` throws `CancellationError`. | WP-14's probe on 2026-11-19. |
| A `LanguageModelSession` takes one request at a time: a second request made while one runs throws. | WP-14's probe on 2026-11-19. |
| Guided generation trips the guardrails on harmless text that plain `String` generation with `permissiveContentTransformations` cleans. | WP-14's probe on 2026-11-19: 2 of 9 synthetic transcripts. |
| The errors of Foundation Models can hold generated text in their descriptions. `LanguageModelError`, from OS 27, replaces `LanguageModelSession.GenerationError` and is not exhaustive. | SDK and WP-14's probe, 2026-11-19. |
| `/usr/bin/lockf` ships with macOS. `flock` is on this Mac only through Homebrew. | Checked on 2026-11-19. |
| `swift build` accepts `--explicit-target-dependency-import-check`, and `swift package diagnose-api-breaking-changes` exists. | Checked with Swift 6.4.4 on 2026-11-19. |
| A CloudKit record holds at most about 1 MB apart from its assets. | From memory. SP-4 confirms it before WP-02 fixes the text limit. |
| GRDB's observation does not see changes made by another process, and its guide recommends a notification between processes. | GRDB's sharing guide, read through a mirror on 2026-11-19. WP-10 reads the original. |

## 21. APIs newer than your training data

Most of the APIs above shipped after the training cutoff of the agents writing this code. Do not write them from memory.

- Read the declaration first. `scripts/sdk-path.sh <platform> <framework>` prints the folder of Swift interfaces for the Xcode named in `.xcode-version`. Code must compile against that Xcode, so a symbol found only in the beta's SDK is not usable.
- Apple's documentation pages are JavaScript-rendered. The same content is served as JSON at
  `https://developer.apple.com/tutorials/data/documentation/<path>.json`.
- In the PR description, name the declarations and pages you read for any OS 26 or OS 27 API.
- If the SDK contradicts this document, the SDK wins. Say so in the PR, and the orchestrator updates this file.
