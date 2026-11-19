# SP-4 code half: CKSyncEngine against the draft port

The code half of SP-4, stage 1, 2026-11-20, on the build Mac: macOS 27.3 (26C5047e), Xcode 27.2 (27B52), the MacOSX 27.2 and iPhoneSimulator 27.2 SDKs. Its code is the spike app on the branch `spike/sync-shape`, in `Spikes/SP-4/`, at `985f2e6`, which is never merged. This note has three readers: WP-02, whose third pull request writes the `SyncEngine` port; WP-10 and WP-16, which build the store's interface for sync and the sync itself; and the orchestrator, which keeps docs/architecture.md.

The build Mac has no signing team yet, so nothing in stage 1 reaches iCloud: no container was opened, no device was signed in, no schema was made anywhere. Every statement about how CKSyncEngine behaves rests on reading the pinned SDK: the Swift interface that `scripts/sdk-path.sh macos CloudKit` prints, and the Objective-C headers beside it, which carry the documentation. Stage 2 runs the same code against the development container on two signed-in devices, and the report, `docs/spikes/SP-4.md`, follows it. The last section lists what stage 2 checks.

## In short

1. **The draft port fits, but "start, stop and report status" is too thin.** The engine streams nothing a status can be read from, except the events it hands its delegate one at a time. Its cancellation is asynchronous: an operation in flight may finish after `cancelOperations()` returns. It retries transient errors by itself and never says how long it waits. The port needs a status stream that the adapter derives from the events, a stop that also drops any late event, a manual sync that throws with a time to retry, and a way to answer the questions a pause asks. A draft is below.
2. **The store cannot apply a batch and the engine's state in one transaction.** The state comes in an event of its own, `stateUpdate`, after the changes it covers. The store applies each batch in one transaction and saves the state in another. A kill between the two costs a fetch of the same changes again, so applying a batch must change nothing the second time. The harness shows that it does.
3. **The store hands out pending records in pieces, during a send.** The engine calls `nextRecordZoneChangeBatch` again and again in one send until it gets `nil`. The store must not hand out the same records twice in one send, must keep to the send's scope, and the adapter must bound each batch by bytes as well as by count.
4. **Apple's guidance on accounts and removed zones differs from §11.** The headers say to delete local data on a sign-out, a switch of account, a zone purged in Settings and an encrypted-data reset. §11 keeps the notes and asks. That stays right for Knot, whose local store is the primary copy, but the question after a purge or a reset should default to not uploading. The engine also clears its pending changes on a change of account, so `change_log` stays the only list of what waits to go up.
5. **Assets can be kept out of the engine's fetches by zone, not by field.** The engine's fetch options have no `desiredKeys`, so a record comes with all its fields, assets included. The delegate can return a scope that excludes the Attachments zone, and the engine asks for the options before each server request, automatic fetches included. §11's two zones are the right shape.
6. **The record limit was read, not measured.** CKRecord's header and Apple's page say a record stores at most 1 MB, assets apart. A segment at §4's first sizes, 256 KiB of text with the raw transcript beside it, has 524,451 bytes of field data. So WP-02 PR 3 keeps the first sizes of §4, and the report confirms the limit or a contract PR changes them.
7. **Twenty-one types of the API cannot be built outside the engine.** Every payload of `CKSyncEngine.Event`, the fetch and send contexts, the engine's `State`, and the four change types of `CKDatabase` have no accessible initialiser. A probe type-checks each against the pinned SDK. The adapter keeps all of them inside one `switch`, and everything below that line takes types a test can make.

| Built | Result |
|---|---|
| `Spikes/SP-4/build.sh check`: the Mac app, signed ad hoc and sandboxed, and the iOS app for the Simulator, Swift 6, complete concurrency checking, warnings as errors, `KNOT_SIGNING=local` | Both build clean. The Mac app's entitlements are `app-sandbox` and `get-task-allow`, with no iCloud and no push, and its Info.plist says `KnotSyncAvailable = NO` |
| `Spikes/SP-4/build.sh selftest`: two replicas through a fake zone and the real mapping, then the mapping and the adapter's testable half on constructed values | 102 checks pass, 0 fail. No container is opened. |
| `Spikes/SP-4/build.sh probe`: 21 constructions that must fail and 7 controls that must compile, each type-checked alone against the MacOSX 27.2 SDK | All 28 as expected |

## The engine's events and their order

`CKSyncEngine.Event` has twelve cases. The enum is not frozen: a `switch` over it needs `@unknown default`, and so do the account change type, the zone deletion reason and the two scopes. The delegate gets one event at a time, and the engine waits for `handleEvent` to return before it sends the next. The delegate must not call `fetchChanges` or `sendChanges` from inside it.

A fetch, as the headers describe it:

```
willFetchChanges                         may be skipped: a fetch already running, or no account
  fetchedDatabaseChanges                 zones made and zones deleted, with a reason for each
  willFetchRecordZoneChanges(zone)       one per zone
    fetchedRecordZoneChanges             records and deletions, possibly several events per zone
  didFetchRecordZoneChanges(zone, error) one per willFetchRecordZoneChanges
didFetchChanges                          one per willFetchChanges
stateUpdate                              "occasionally", whenever the state changes
```

A send:

```
willSendChanges(context)
  sentDatabaseChanges                    zones saved or deleted, and the failures
  nextRecordZoneChangeBatch → sentRecordZoneChanges, repeated once per batch until the delegate returns nil
didSendChanges(context)
```

Three points of order matter to the core:

- **Records arrive in no promised order.** The headers say CloudKit does not guarantee the order of fetched changes, though it is typically oldest to newest. So a segment can arrive before its note, within one event or across two. The core holds such a segment and settles it only when `didFetchChanges` comes, and only if every zone's `didFetchRecordZoneChanges` came without an error, because a failed zone fetch may still owe the note. The harness covers all three outcomes: the note follows in the same fetch, the fetch fails, the fetch completes without it.
- **The state follows the changes it covers.** "You should persist this state alongside any changes fetched prior to receiving this state." With events delivered one at a time, a `stateUpdate` cannot overtake a batch the delegate is still applying, provided the delegate awaits its write before it returns.
- **A batch's sent event and the next request for a batch.** The header says each batch gets its own `sentRecordZoneChanges`. It does not say that the event arrives before the engine asks for the next batch. So the store keeps a set of the records it has handed out in the current send, cleared at `willSendChanges` and `didSendChanges`.

## What `nextRecordZoneChangeBatch` asks of the store, and when

The engine asks for a batch whenever it runs a send: a scheduled one, after pending changes were added to its state or `hasPendingUntrackedChanges` was set, or a manual one, from `sendChanges`. It asks again after each batch until the delegate returns `nil` or the send is cancelled. The call is `async`, so the store's read can await.

What the store must give:

- **Only changes inside the send's scope.** `context.options.scope` can name zones, exclude zones or name records. Returning a change outside it fails the whole send with `invalidArguments`. `SendChangesOptions.Scope.contains(_:)` is public, so the batch builder filters with it, and the harness checks the filter.
- **No more than a request can carry.** The engine's header puts the server's limit at 250 records per request, saves and deletes together. A larger batch fails with `limitExceeded`, which the engine "treats like any other send failure". The header does not say that it splits the batch. CKError.h gives "2 MB per request (not counting asset sizes)" and 400 items as guidelines, and says an app that gets `limitExceeded` must halve the request. The engine's own builder, `RecordZoneChangeBatch(pendingChanges:recordProvider:)`, stops when "the size of the batch reaches the maximum limit", and does not say whether it counts bytes. Knot's segments can reach half a megabyte, so the spike's builder counts both: at most 250 records and at most 1.5 MB of field data, with one record always allowed alone. Four segments of about 600 KB each give a batch of two.
- **Each record rebuilt on its system fields.** A record saved without the change tag of the server's last version fails with `serverRecordChanged`. The store keeps the system fields per record (`sync_record`), the adapter decodes them into a `CKRecord` and writes only Knot's fields onto it.
- **Records it will not send, reported.** A record over the record limit never goes into a batch. The builder returns it apart, and the store must split it or show it.

Pending changes can live in two places, and stage 2 measures both. The engine can track them, through `state.add(pendingRecordZoneChanges:)`, in which case they are part of its serialised state. Or the store can keep them in `change_log` and set `hasPendingUntrackedChanges`, in which case the engine asks the delegate without knowing what is pending. Either way `change_log` must stay the source: a change of account clears the engine's list, and a kill after `add` but before the next saved state loses it from the engine. At each launch the adapter adds the `change_log` rows again, which the engine de-duplicates. A `change_log` row leaves only when a sent event reports the record saved with the values the store still holds, so an edit made during a send is sent again.

## The engine's state, and a kill between a batch and the state

`CKSyncEngine.State.Serialization` is opaque. It is `Codable` in Swift and `NSSecureCoding` in Objective-C, The headers say the engine's state keeps the server change tokens of the database and its zones, the subscription IDs, the last user record ID "and so on", with the pending changes the engine tracks. It is handed over in a `stateUpdate` event, "occasionally" during normal sync and whenever the app changes the state itself, and handed back at the next launch through `Configuration(database:stateSerialization:delegate:)`. The engine does not write it anywhere. A test can decode one from bytes, since its only initialiser is `init(from:)`, but cannot make one any other way. How large it grows is a stage 2 measurement.

A kill between applying a batch and saving the next state costs this much: at the next launch the engine starts from the older state and fetches again everything since its saved tokens. Nothing is lost, provided applying a batch twice changes nothing. The core makes that hold: a record that arrives again equal to the stored one leaves nothing pending, and a conflict copy's ID is derived from the segment, the device and the revision, so a second pass finds the copy already there. The harness kills a replica after it applied a fetch and before it saved the token, fetches again, and finds the replica unchanged with nothing pending. The other order, a state saved before its batch is applied, would lose changes. It cannot happen as long as the delegate applies each batch inside `handleEvent` and awaits the write before returning.

## What cancels a fetch or a send

- **`cancelOperations()`**, `async` in Swift. "The sync engine processes cancellation requests asynchronously, meaning it's possible for in-progress operations to complete even after this method returns." So a stop cannot rely on it alone. The spike's adapter carries a generation number, and the store drops every input from an older generation, so an event that arrives after a stop, or after a change of account, never reaches the notes.
- **Returning `nil` from `nextRecordZoneChangeBatch`** ends a send's batches. The spike's store returns nothing while a question waits, so no upload happens before the user answers.
- **`automaticallySync = false`** stops the engine from scheduling anything. Knot keeps it on, because the engine uses a database subscription to learn of remote changes, and with sync off Knot makes no engine at all (§11, the gate).
- **A manual `fetchChanges` or `sendChanges`** returns only after the delegate has handled all its events. What cancelling the Swift task that awaits it does is not documented.

The configuration also says: with CloudKit's production environment, do not make two engines on the same database. Knot makes one, in the app process (§6, rule 4).

## Which errors carry a time to retry

CKError.h adds `CKErrorRetryAfterKey` to `serviceUnavailable` and `requestRateLimited`, and tells an app to look for it on `zoneBusy` too. Swift reads it as `CKError.retryAfterSeconds`. The harness builds a rate-limit error and a busy-zone error with the key and reads 7 s and 2.5 s back.

The engine handles seven codes itself and retries them "when it makes sense": `notAuthenticated`, `accountTemporarilyUnavailable`, `networkFailure`, `networkUnavailable`, `requestRateLimited`, `serviceUnavailable` and `zoneBusy`. For rate limiting it waits the retry-after time. The header says it handles these "behind the scenes", and names no event that reports the error or the wait. So the status can say "waiting" with a time only after a manual sync that threw one.

What reaches the delegate, and what the store does:

| Where | Code | Knot's handling |
|---|---|---|
| `sentRecordZoneChanges.failedRecordSaves` | `serverRecordChanged`, with the server's record in `serverRecord` | Merge it like a fetched record, keep the record pending, send again |
| the same, and `failedRecordDeletes` | `zoneNotFound` (with `CKErrorUserDidResetEncryptedDataKey` after a reset), `userDeletedZone` | Pause and ask (§11) |
| the same | `limitExceeded` | Split the batch; the engine does not |
| the same | `quotaExceeded` | Stop sending and say that the user's iCloud storage is full |
| the same | `unknownItem` | The record is gone from the server; the long-absence rule decides |
| the same | `batchRequestFailed` | Only with `atomicByZone`, which Knot leaves off |
| `didFetchRecordZoneChanges.error` | any | The zone's fetch failed: settle no orphans this time |
| `sentDatabaseChanges.failedZoneSaves`, `failedZoneDeletes` | any | The zone was not made or removed |
| the error `fetchChanges` and `sendChanges` throw | any | A manual sync: report it, with its time to retry |

The spike's `SyncCondition` sorts these into transient, server record changed, zone missing (deleted by the user, or after an encrypted-data reset), limit exceeded, quota exceeded, unknown item, and final. They are the sync conditions WP-02's error taxonomy names.

## A removed zone and a changed account

`fetchedDatabaseChanges` reports each deleted zone with one of three reasons, and the headers attach instructions to two of them:

- `deleted`: "Your app deleted the record zone."
- `purged`: "The owner of the iCloud account purged your app's data using the Settings app. Upon receipt of deletions with this reason, you must delete any locally cached data and not resend it to iCloud."
- `encryptedDataReset`: "The owner of the iCloud account reset their encrypted data", with the same instruction.

`accountChange` reports `signIn(currentUser:)`, `signOut(previousUser:)` or `switchAccounts(previousUser:currentUser:)`. For a sign-in the header lists keeping the local data apart, merging it, deleting it or asking the owner. For a sign-out and a switch it says "You should delete any locally-stored data for the previous account." When the account changes the engine resets its state and clears every pending change the app had added. Several changes while the app was not running arrive as one event, from the last known state to the current one.

§11 keeps local notes in all of these cases and asks before uploading. That differs from Apple's guidance on purpose: Knot's store is not a cache of iCloud, it is where a capture lands first. Two consequences belong in §11. After `purged` or `encryptedDataReset` the user asked iCloud to forget, so the question defaults to not uploading. And the account's identity for account isolation is the user record ID's `recordName` from this event. No API read here reports the CloudKit environment, so Knot takes it from its own build, from the entitlement it was signed with.

The spike translates each reason and each change type, and the harness checks that all three reasons reach the store. What CloudKit actually reports, and when, needs the container.

## Keeping assets out of automatic fetches

`FetchChangesOptions` has a scope, `.all`, `.allExcluding(zones)` or `.zoneIDs(zones)`, and an order of zones to fetch first. It has no `desiredKeys`. So the engine fetches whole records, and CKAsset's header says that fetching a record that holds an asset downloads the asset too, unless the operation's `desiredKeys` leave the field out. That confirms §20's report from the SDK.

The delegate's `nextFetchChangesOptions` is called "in between each server request while fetching changes", for every fetch, so the adapter can keep the Attachments zone out of all of them by returning `.allExcluding([Attachments])`, or by removing it from a scope that names it. The harness checks the three cases. An asset is then fetched on demand outside the engine, with `CKDatabase.records(for:desiredKeys:)` or `CKFetchRecordsOperation`, and its metadata without the file by leaving `file` out of `desiredKeys`. Downloaded asset files land in a staging area that the system clears, so the fetcher moves each file into the store at once.

## The record limit

| Limit | Value | Source |
|---|---|---|
| Data a record stores, assets apart | 1 MB | `CKRecord.h` in the MacOSX 27.2 SDK: "the data that a record stores must not exceed 1 MB. Assets don't count toward this limit, but all other data types do." Apple's page for `CKRecord`, read as JSON, says the same. |
| An asset | 50 MB per asset field | "CloudKit Web Services Reference: Data Size Limits", Apple's documentation archive, last updated 2016-06-13. The same table gives 1 MB per record. The SDK's headers state no asset limit. |
| A request | 2 MB, assets apart, and 400 items, as "general guidelines" the server can change | `CKError.h`, on `CKErrorLimitExceeded`, and Apple's page for that code |
| A sync engine batch | 250 records, saves and deletes together | `CKSyncEngine.h`, "Batches" |

These were read and not measured. Neither says whether "1 MB" is 10^6 or 2^20 bytes, or whether encryption, field names and system fields count against it, so the spike uses 1,000,000 bytes. Measured locally, with no server: a segment record with 256 KiB of text and a 256 KiB raw transcript holds 524,451 bytes of field data and archives to 528,765 bytes. So §4's first sizes leave about half of the limit free, WP-02 PR 3 keeps them, and the report confirms the limit or a contract PR changes the sizes. Apple's CKAsset page also advises an asset for any value "more than a few kilobytes in size". Knot keeps text in fields, because it must be readable without a download, and stays well inside the limit.

At 64 kbit/s, 50 MB of audio is about an hour and 45 minutes. Whether the native API holds an asset to the same 50 MB is a stage 2 question.

## What a test cannot build, and what the adapter hides

The probe, `Spikes/SP-4/Probes/no-public-init.txt`, constructs each type alone, and the compiler answers for each: "cannot be constructed because it has no accessible initializers".

- The payload of every event: `CKSyncEngine.Event.StateUpdate`, `AccountChange`, `FetchedDatabaseChanges`, `FetchedRecordZoneChanges`, `SentDatabaseChanges` and its `FailedZoneSave`, `SentRecordZoneChanges` and its `FailedRecordSave`, `WillFetchChanges`, `WillFetchRecordZoneChanges`, `DidFetchRecordZoneChanges`, `DidFetchChanges`, `WillSendChanges`, `DidSendChanges`.
- The contexts the delegate is handed: `CKSyncEngine.FetchChangesContext`, `CKSyncEngine.SendChangesContext`.
- The engine's `CKSyncEngine.State`. Its `Serialization` has only `init(from:)`.
- What the events carry: `CKDatabase.RecordZoneChange.Modification` and `.Deletion`, `CKDatabase.DatabaseChange.Modification` and `.Deletion`.
- The engine itself needs a `CKDatabase`, which comes only from a `CKContainer`, which needs the iCloud entitlement.

These compile, and the harness builds them: `CKRecord` with its ID, zone and encrypted values, `CKRecord.Reference`, `CKError` with any code and user info, `CKSyncEngine.Event.AccountChange.ChangeType`, `CKDatabase.DatabaseChange.Deletion.Reason`, `FetchChangesOptions` and `SendChangesOptions` with their scopes, `PendingRecordZoneChange`, and `RecordZoneChangeBatch`.

So the adapter is two layers. `SyncAdapter`, the delegate, does nothing but a `switch` over the event that unpacks each payload into records, record IDs, zone IDs, reasons and errors, and hands them to `EventTranslator`. `EventTranslator`, the batch builder and the fetch-scope function take only the constructible types and return the core's values, and the harness tests them. The lines left untested are the unpacking itself and the factory that makes the engine. Stage 2 runs them, and M4 runs them on hardware.

## What the harness showed

Two replicas sync through a fake zone that keeps its own change tags, because a `CKRecord`'s change tag is set only by the server. Every record crosses the real mapping both ways. After each scenario the harness checks that the replicas end equal, nothing is left pending, nothing made after a delete sits in a deleted note, and every segment is in a note that exists.

| Rule of §11 | Result |
|---|---|
| A title keeps the later edit | Holds in both sync orders. It needs a time for the title itself: the spike adds `titleEditedAt`. |
| A deleted note stays deleted | Holds. An edit that arrives later lands on the deleted copy, and the earliest delete wins on both devices. |
| A segment that starts after its note's delete moves to a derived note | Holds. Two late segments land in the same version 5 note, one that started before the delete stays, the derived note takes its dates from the segment, and a late segment passes a deleted derived note to the next one. |
| Text edited on two devices: both versions kept | Holds, found on a fetch and found on a refused send. The server's text stays, the other is one copy in the same note, with no file. Applying every batch again changes nothing. |
| Machine text | An edit beats cleaned text with no copy, and the raw transcript is never modified. |
| A segment that arrives before its note | It waits. It is placed when the note follows in the same fetch, is left alone when a zone fetch failed, and moves to a derived note when a complete fetch ends without its note. |
| A kill between applying a batch and saving the state | Fetching again changes nothing. |
| Two devices take a recording at the same generation | The higher device ID owns it on both, its text stands, and there is no copy. |

The mapping and the adapter, on constructed values:

```
ok   mapping: Segment round-trips every field, unknown kinds and states kept
     Segment: allKeys() lists the encrypted keys too: true
ok   system fields: a field from a newer build is not in the save, so the server keeps it
     a segment at §4's first limit, 256 KiB text + 256 KiB raw: 524451 field bytes, 528765 bytes archived locally
ok   record size: a record over the limit is never put in a batch
ok   errors: requestRateLimited is transient and carries its time to retry
ok   errors: zoneNotFound after an encrypted-data reset says so
ok   errors: serverRecordChanged reaches the core with the server's version
ok   fetch scope: the default scope excludes Attachments
ok   batches: large records stop the batch at the byte budget  · 2 records, 1228966 bytes
ok   zones: each of the three reasons for a deleted zone reaches the store
ok   unknown kind: a record kind this build does not know is reported, not dropped
selftest: 102 passed, 0 failed
```

Two of these settle points of §11 without a server. A record rebuilt from its system fields and given only Knot's fields lists only those in `changedKeys()`, so a save does not send a field from a newer build, and the server keeps it untouched. And `allKeys()` lists encrypted keys beside the plain ones, so whether a field is encrypted is decided by how it was first written and then by the schema, never by reading a record.

## For WP-02: the port

As the spike compiles it, in `Sources/Adapter/DraftPort.swift`, where the protocol is named `SyncEnginePort`:

```swift
protocol SyncEngine: Sendable {
    func statusUpdates() -> AsyncStream<SyncStatus>   // the current status, then every change
    func start() async
    func stop() async                                 // cancels, and drops every later event of this run
    func syncNow() async throws(SyncFailure)          // fetch, then send; the condition carries retryAfter
    func answer(_ question: SyncQuestion, _ answer: SyncAnswer) async
}
enum SyncStatus { case off, idle(lastSuccess: Date?), fetching, sending(remaining: Int),
                  waiting(until: Date?), paused(SyncQuestion), failed(SyncCondition) }
enum SyncQuestion { case signedOut, accountChanged, zoneRemoved(ZoneLoss), largeDelete(notes: Int, ofTotal: Int),
                    restoredStore, environmentChanged, recordTooLarge(count: Int) }
enum SyncAnswer { case upload, keepPaused }
```

- **Streaming.** The engine gives no progress, only its events. `fetching` and `sending` come from the will and did events, `remaining` from the store's count of pending records. `waiting(until:)` has a time only after a manual sync, because the engine waits by itself and silently.
- **Cancellation.** `stop()` calls `cancelOperations()`, raises the run's generation and releases the engine, so a late event is dropped whatever the engine still finishes.
- **Errors.** No method of the port throws an engine error except `syncNow`. Everything else surfaces as a status, as the engine surfaces it as an event.
- **Questions.** Each pause of §11 is a question with the two answers §11 defines. The port must let the app answer.

## For WP-10 and WP-16: the store's interface for sync

§3 gives KnotStore one interface for sync: read the pending changes, apply a fetched batch together with the engine's state in one transaction, and save a record's system fields. Reading the SDK changes it to:

1. Apply a fetched batch in one transaction, idempotently. It returns the records the merge made or settled, already queued.
2. Save the engine's state in its own transaction, when a `stateUpdate` comes.
3. Read the next pending records for the current send, in order, at most a given number, never one already handed out in this send.
4. Record a sent batch: the system fields of each saved record, and remove a `change_log` row only when the saved values are still the stored ones.
5. Settle at the end of a fetch, given whether every zone's fetch completed.
6. Report and keep apart a record over the size limit.

## The questions of the brief

| Question | Stage 1 |
|---|---|
| Does §11's design hold: an engine-managed zone, and an attachments zone kept out of automatic fetches and read on demand? | By reading, yes: the fetch options take a scope and are asked for before each request. Stage 2 checks it against the container. |
| Do encrypted fields work for all text? | The mapping writes `title`, `text` and `rawTranscript` through `encryptedValues`, and a round trip keeps them. CKRecord.h: any type but `CKAsset` (always encrypted) and `CKRecord.Reference` (never) can be encrypted, only on a new field, and encrypted fields cannot be indexed. Stage 2. |
| Can a trigger-fed change log drive the engine's pending changes, including writes from another process? | Yes by design: `change_log` stays the source in both ways of telling the engine. Stage 2 measures which. |
| How large does the engine's serialised state grow? | Stage 2. |
| How long does a fresh install take to restore 5,000 notes, 20,000 segments and their deletions? | Stage 2. |
| What do toggling sync off and on, and changing iCloud account, do? | Read: the account events and the engine's reset, above. Stage 2. |
| Do the ownership, machine-text and deleted-note rules hold when two devices see the same segment? | On the core, yes (the harness). Stage 2 on the container. |
| Can a segment record's note reference change after the record is saved? | Locally, yes: the mapping uses a reference with no action and sets it again. Stage 2 on the server. |
| What happens when a device moves from development to production? | Stage 2, in the development environment only. Production is the owner's to authorise. |
| What does CKSyncEngine report when the zone is removed from iCloud? | Read: three reasons, above, all translated. Stage 2 tests each. |
| How is a replica that stayed away for more than 30 days handled? | Stage 2 and the report. |
| What happens to a segment that arrives before its note? | Answered on the core: it waits for the end of the fetch. |
| What happens on a kill between applying a batch and saving the engine's state? | Answered on the core: a refetch, which changes nothing. |
| What happens to a store restored from an older copy? | Stage 2. |
| What happens to a record at the size limit? | Read: 1 MB. A record over it is never batched. Stage 2 measures the limit. |
| What happens on a change of account with uploads pending? | Read: the engine drops its pending list; `change_log` keeps it. Stage 2. |
| What does a restored or replaced phone do to device identity? | Stage 2. |
| Does an existing sync layer such as SQLiteData meet the rules, and at what cost? | Stage 2 and the report. Adding it would be the owner's decision (D30). |

## Declarations and pages read

In the MacOSX 27.2 SDK of Xcode 27.2, through `scripts/sdk-path.sh macos CloudKit`, the Swift interface `arm64e-apple-macos.swiftinterface` and the headers beside it:

- `CKSyncEngine.h`: `CKSyncEngine` and its overview (sending, batches, fetching, scheduling, error handling, accounts), `fetchChanges`, `sendChanges`, `cancelOperations`, `CKSyncEngineDelegate` (`handleEvent`, `nextRecordZoneChangeBatch`, `nextFetchChangesOptions`), `FetchChangesOptions`, `FetchChangesScope`, `SendChangesOptions`, `SendChangesScope`, `SyncReason`, `FetchChangesContext`, `SendChangesContext`.
- `CKSyncEngineConfiguration.h`: `database`, `stateSerialization`, `delegate`, `automaticallySync`, `subscriptionID`.
- `CKSyncEngineEvent.h`: every event type and class, `AccountChangeType`, `ZoneDeletionReason`, `FetchedRecordDeletion`, `FetchedZoneDeletion`, `FailedRecordSave`, `FailedZoneSave`.
- `CKSyncEngineState.h`: `State`, `pendingRecordZoneChanges`, `pendingDatabaseChanges`, `hasPendingUntrackedChanges`, `zoneIDsWithUnfetchedServerChanges`, `add`/`remove`, `StateSerialization`, `PendingRecordZoneChange`, `PendingDatabaseChange`.
- `CKSyncEngineRecordZoneChangeBatch.h`: both initialisers, `atomicByZone`.
- The Swift interface for all of the above, `CKDatabase.RecordZoneChange` and `CKDatabase.DatabaseChange` with `Deletion.Reason`, and `CKError`'s `retryAfterSeconds`, `serverRecord`, `clientRecord`, `ancestorRecord`, `partialErrorsByItemID`.
- `CKError.h`: the codes, `CKErrorRetryAfterKey`, `CKErrorUserDidResetEncryptedDataKey`, the `CKRecordChangedError…` keys. `CKRecord.h`: the 1 MB limit, `encryptedValues`, `encodeSystemFields`. `CKAsset.h`, `CKReference.h`, `CKRecordID.h`, `CKRecordZoneID.h`, `CKModifyRecordsOperation.h`.

Apple's pages, as JSON: `cloudkit/ckrecord`, `cloudkit/ckasset`, `cloudkit/ckrecord/encryptedvalues`, `cloudkit/ckerror/code/limitexceeded`, `cloudkit/cksyncengine-5sie5`. And the archived "CloudKit Web Services Reference: Data Size Limits".

## Changes this asks of the architecture

docs/architecture.md is the orchestrator's file, so this note does not edit it. The report may add to these after stage 2.

1. **§3, KnotStore's interface for sync.** Not "apply a fetched batch together with the engine's state in one transaction": the engine hands its state over in an event of its own, after the changes it covers. The interface is the six operations listed above: apply a batch idempotently, save the state on its own, read pending records per send, record a sent batch, settle at the end of a fetch, keep an oversized record apart.
2. **§5, the `SyncEngine` row.** A status stream, start, a stop that cancels and drops late events, a manual sync that throws with a time to retry, and an answer to each question a pause asks. WP-02's taxonomy takes the sync conditions: transient, server record changed, zone missing (deleted by the user, encrypted data reset), limit exceeded, quota exceeded, unknown item, final.
3. **§4, `Note`.** A synced `titleEditedAt`, because "a title keeps the later edit" needs the time of the title's own edit.
4. **§7, `change_log`.** It stays the source of pending changes in every case, because the engine clears its own list on a change of account and can lose an addition to a kill. A row leaves only when a sent event reports the record saved with the values the store still holds. At launch the adapter adds every row to the engine again.
5. **§11, Zone `Attachments`.** Kept out by the scope the delegate returns from `nextFetchChangesOptions`, `.allExcluding([Attachments])`, which the engine asks for before each request. Assets and their metadata are fetched on demand with `desiredKeys`, outside the engine, and a downloaded file is moved out of CloudKit's staging area at once.
6. **§11, sending.** The adapter builds each batch itself: only records inside the send's scope, at most 250, and at most a byte budget of field data, 1.5 MB to start with. A record over the record limit is never sent and is reported.
7. **§11, Notes removed from iCloud, and Account changes.** Record that Apple's headers say to delete local data on a sign-out, a switch, a purge and an encrypted-data reset, and that Knot keeps it on purpose because its store is the primary copy. After `purged` or `encryptedDataReset` the upload question defaults to keeping sync paused.
8. **§11, Account isolation.** The account is the user record ID's `recordName` from the engine's account event. The environment comes from the build's own entitlement, because no API read here reports it.
9. **§11, a segment whose note has not arrived.** It is settled only at `didFetchChanges`, and only when every zone's `didFetchRecordZoneChanges` came without an error.
10. **§11, Structure, and §20's row on `FetchedRecordZoneChanges`.** The types with no accessible initialiser are every event payload, the fetch and send contexts, the engine's `State`, and `CKDatabase`'s four change types, and the engine needs a container. The adapter keeps them in one `switch`, and the layer below it takes only types a test can make.
11. **§20, new and changed rows.**
    - A record stores at most 1 MB of data, assets apart (SDK, `CKRecord.h`, and Apple's page; read, not measured; SP-4's report measures it).
    - An asset field holds at most 50 MB (CloudKit Web Services Reference, 2016; not in the SDK).
    - A request carries about 2 MB and 400 items, assets apart, and the server may change that (SDK, `CKError.h`). A sync engine batch carries at most 250 records, and the engine treats a batch that fails with `limitExceeded` like any other failed send (SDK, `CKSyncEngine.h`).
    - "CKSyncEngine downloads assets eagerly and offers no way to fetch selected fields" becomes SDK: the fetch options have a zone scope and no `desiredKeys`.
    - The engine retries seven transient codes itself, and the header names no event that reports the error or the wait (SDK).
    - `cancelOperations()` is asynchronous, and an operation in flight may finish after it returns (SDK).
    - `CKSyncEngine.Event` and its nested enums are not frozen, so a `switch` needs `@unknown default` (build).
    - `allKeys()` lists encrypted keys beside plain ones; a save from a record rebuilt on its system fields sends only the keys set on it (the spike's self-test).

## Not verified yet

Every statement below rests on reading alone, and stage 2 checks it against the development container on two signed-in devices or simulators:

- That a `stateUpdate` never covers a batch the delegate has not finished applying, and how often one comes.
- Whether `sentRecordZoneChanges` for a batch arrives before the next call to `nextRecordZoneChangeBatch`.
- Whether `RecordZoneChangeBatch(pendingChanges:recordProvider:)` counts bytes, and what the server does with a batch of large records under 250.
- Whether `hasPendingUntrackedChanges` clears itself after a send, and which way of telling the engine about pending changes keeps its state smaller.
- That `.allExcluding([Attachments])` keeps the zone out of scheduled fetches, whether a push for that zone makes the engine fetch nothing again and again, and whether a deleted Attachments zone is still reported.
- What cancelling the task that awaits `fetchChanges` or `sendChanges` does, and what `cancelOperations()` leaves running.
- That the engine retries the seven codes by itself, and whether any of them still reaches the delegate.
- The record limit itself: 10^6 or 2^20 bytes, and whether encryption and field names count. The asset limit for the native API.
- That encrypted fields work for `title`, `text` and `rawTranscript` in the development schema, made by the first save.
- That a segment record's note reference can change after the record is saved, on the server.
- That the server keeps a field a save does not send.
- Each zone-deletion reason as CloudKit reports it, and what a send into a removed zone returns.
- What the account event reports on a sign-out, a sign-in and a switch, and that the engine then drops its pending list.
- The serialised state's size, and the restore time for 5,000 notes, 20,000 segments and their deletions.
- A move from the development environment to production. Deploying the production schema needs the owner's word.
- Whether the Swift `Configuration` holds its delegate weakly, as the Objective-C one does.
- Whether the sandboxed Mac app needs `com.apple.security.network.client` beside the iCloud entitlements.
