# SP-4 · the spike app

Throwaway code for [SP-4](../../docs/plan/SP-4.md): the sync design of `docs/architecture.md` §11 against CloudKit. It lives on `spike/sync-shape` and is never merged. The short note of its code half is `docs/notes/SP-4.md`, merged on its own. The report, `docs/spikes/SP-4.md`, follows stage 2.

**Stage 1** (this code) was built with no signing team on the Mac, so nothing in it reaches iCloud: no container, no signed-in device, no CloudKit Console, no schema deployed. It builds the merge core, the mapping and the adapter, and tests everything that needs no server. **Stage 2** runs the same code against the development container, `iCloud.com.p3ob7o.knot.dev`, on two signed-in devices or simulators.

## What is in it

| Path | What |
|---|---|
| `Sources/Core/Values.swift` | Knot's own record values: notes, segments, the remote changes the core takes. Version 5 and version 7 IDs. No CloudKit. |
| `Sources/Core/MergeCore.swift` | The merge core: one `Replica` per device, with `sync_record`, `change_log` and tombstones. The rules of §11: titles, deletes, late segments and derived notes, conflict copies, machine text, ownership, moves, orphans. |
| `Sources/Mapping/RecordMapping.swift` | Values to `CKRecord` and back, with the encrypted fields, the note reference, system fields, the asset record and a size measure. |
| `Sources/Adapter/Translation.swift` | The adapter's testable half: everything it does with types that have public initialisers. Errors with their time to retry, the fetch scope that keeps Attachments out, the batch builder with a record count and a byte budget. |
| `Sources/Adapter/SyncAdapter.swift` | The thin half: the `CKSyncEngineDelegate` that unpacks events, and the factory for the live engine, which refuses in a build without sync. |
| `Sources/Adapter/DraftPort.swift` | The `SyncEngine` port as the note drafts it, and `SpikeStore`, the in-memory store that stage 2 drives the engine with. |
| `Sources/Harness/` | The self-test: two replicas through a fake zone and the real mapping, then the mapping and the adapter on constructed values. |
| `Probes/no-public-init.txt` | One line per CloudKit type the note says cannot be built in a test. `build.sh probe` type-checks each against the pinned SDK. |
| `project.yml`, `Config/` | Its own XcodeGen spec on `Apps/Config/Base.xcconfig`: a Mac app and an iOS app from the same sources, development identifiers only. |

## Building

Every command runs from the repository root, with `KNOT_AGENT=1` for an agent.

```
Spikes/SP-4/build.sh check       # the Mac app (ad hoc, sandboxed, no iCloud) and the iOS Simulator app
Spikes/SP-4/build.sh selftest    # the Mac app, then its self-test, which exits with the result
Spikes/SP-4/build.sh probe       # the types with no public initialiser, checked against the SDK
```

The script refuses `KNOT_SIGNING=team` in stage 1. It checks that the Mac build carries the sandbox and no iCloud or push entitlement, and that its Info.plist says `KnotSyncAvailable = NO`. `LiveSync.makeEngine` refuses before it touches `CKContainer` unless that key says `YES` and the container's identifier ends in `.dev`.

## What stage 2 adds

These need the owner's signing on the Mac and two devices signed in to iCloud. Nothing here touches the milestone container or the production schema.

1. Team entitlements for both targets: `com.apple.developer.icloud-container-identifiers` with `iCloud.com.p3ob7o.knot.dev`, `com.apple.developer.icloud-services` with `CloudKit`, and push for CloudKit's notifications (`aps-environment` on iOS, `com.apple.developer.aps-environment` on the Mac, development). On iOS, the `remote-notification` background mode. Whether the sandboxed Mac app also needs `com.apple.security.network.client` is checked then.
2. A window to drive it: make notes and segments, edit, delete, move, fetch now, send now, cancel, and a log of events with counts, sizes and timings, never text.
3. The runs the brief lists, with the note's "Not verified yet" as the checklist.
