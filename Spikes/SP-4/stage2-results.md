# SP-4 stage 2: results

Measured on 2026-11-20 in this worktree's two simulators (iOS 27.2 runtime, `-iphone` and `-ipad`), both signed in to one additional Apple ID that is not on the team, against the development environment of `iCloud.com.p3ob7o.knot.dev`, with the Development build and `LiveRunner`. The numbers are from the simulators over the build Mac's network. The report, `docs/spikes/SP-4.md`, draws on this file.

## Accounts

Both simulators answered `accountStatus = available` for both containers. An Apple ID that is not a member of the team reads and writes the development environment from a development-signed build: every step below ran under it. On the first launch the engine sent `accountChange signIn` before anything else, with no saved state.

## The statements of the note's "Not verified yet"

| # | Statement | Answer |
|---|---|---|
| 1 | A `stateUpdate` never covers a batch not yet applied, and how often one comes | Holds. In every trace a `stateUpdate` came after the fetched batch it covers, never between a batch and its application. It came after nearly every event: 15 in one sync of 600 records (fetch, send, fetch). Fetched records came 200 to an event. |
| 2 | Whether a batch's sent event arrives before the next request for a batch | Yes, in every send traced: request, `stateUpdate`, `sentRecordZoneChanges`, then the next request. |
| 3 | Whether the engine's `RecordZoneChangeBatch(pendingChanges:recordProvider:)` counts bytes, and what the server does with large records under 250 | It counts bytes. With records of about 600 KB it put two in a batch (1.2 MB), with records of about 350 KB five (1.4 MB), and asked for a sixth that it left out: its budget lies between 1.4 and 1.75 MB of field data. The server took one request of 4.8 MB and refused 5.6, 6.4 and 7.2 MB: every record of the batch failed with `limitExceeded` (27), the manual send threw `partialFailure` (2), and the engine did not split the batch. |
| 4 | Whether `hasPendingUntrackedChanges` clears itself | It does not. It stays set after a send that found nothing, is kept in the saved state across launches, and each later send asks the delegate once and gets nothing. |
| 9 | Encrypted `title`, `text` and `rawTranscript` round-trip | Yes. 600 records sent from one simulator and fetched on the other give the same digest of every text, raw transcript and title. |
| 10 | A segment's note reference can change after the record is saved | Yes. A move saved the segment again with another note reference and a higher `noteGeneration`; the other simulator fetched it and the placements agree. |
| 11 | The server keeps a field a save does not send | Yes. One simulator wrote `futureField` to a note straight to the database; the other fetched the note, changed its title, and saved it rebuilt from its system fields; the field was still there, beside the new title. |
| 4, the size | Which way of telling the engine about pending changes keeps its state smaller | Untracked. With nothing tracked the saved state stays between 1.3 and 4 KB. Each change the engine tracks costs it 144 to 181 bytes: 25,000 tracked changes make a state of 4.5 MB, which the engine hands over again at nearly every event. |
| 5 | `.allExcluding([Attachments])`, pushes, and a deleted Attachments zone | On fetches the exclusion holds: with it the engine fetched Stream only, though the database changes still listed Attachments; without it the engine fetched the Attachments zone and its asset record whole. A deleted Attachments zone is still reported, with reason `deleted`, while excluded. Pushes: in 120 s of listening with automatic sync on, with and without the app registered for remote notifications (registration gave a token), no push reached the simulator and no fetch followed another simulator's writes. One scheduled fetch ran at the start. The push part moves to hardware. The on-demand read works: an asset record fetched with `desiredKeys` naming everything but the file came without it, and fetched whole came with its 4,096-byte file. |
| 6 | Cancelling the task that awaits a send, and `cancelOperations()` | Both cancel the send. Cancelling the task: `sendChanges` threw `CancellationError` within about 100 ms, the batch in flight failed with `operationCancelled` (20), `didSendChanges` followed, and nothing came in the next 5 s. `cancelOperations()` returned before the batch's sent event, which came after it with `operationCancelled` on every record, and the manual send threw 20. In both cases the server had saved the cancelled batch: the next fetch brought those 250 records back. A record reported cancelled may be on the server. |
| 8 | The record limit, and whether encryption counts | 1 MiB, measured: one string field of 1,047,656 bytes saved and one of 1,048,437 bytes was refused with `limitExceeded` (27), plain and encrypted alike, so encryption adds less than the 781 bytes between them. The limit is 2^20 bytes less a few hundred of overhead, not 10^6. An asset of 52,500,000 bytes saved in 5.6 s, so the native API does not hold an asset to the 50 MB of the Web Services reference. Larger assets were not tried, to keep the build Mac's network free. |
| 12a | A zone removed by the app, and a send into it | The other simulator's fetch reported the Stream zone with reason `deleted`. Its send into the removed zone failed with `zoneNotFound` (26), without `CKErrorUserDidResetEncryptedDataKey`, and the manual send threw `partialFailure` (2). The engine did not make the zone again by itself. |
| 14 | The state's size, and the restore time for 5,000 notes, 20,000 segments and their deletions | One simulator sent 25,000 records (5,000 notes, 500 of them deleted, and 20,000 segments) in 5 min 38 s, in 100 batches. A fresh store on the other simulator restored all of them in 2 min 17 s, in 125 fetched events, with every digest equal. The saved state stayed at 2.6 KB throughout, with nothing tracked. These are simulator times over the build Mac's network, into a store kept in memory: WP-16's SQLite writes and a phone's network come on top, and M4 measures them. A deletion that the server purged is not fetched by a fresh replica at all, so "their deletions" here are the notes marked deleted. |

## Found on the way

- Sending is slow next to fetching: 600 small records took 31 s to send, about 10 s for each batch of 250, and 11 s to fetch on a fresh replica.
- A fresh engine state reports past zone deletions. A replica whose store and state were reset fetched the database's changes from the start and was told that Stream, Attachments and a probe zone had been deleted, with reason `deleted`, although Stream was being made again in the same sync. A store that paused on that would never upload. The spike now pauses on a removed zone only if it had synced records under it, which is §11's rule that a zone that is gone deletes nothing.
- The store must learn which records a batch took. The spike's store first marked every record it offered as handed out, and the adapter's builder took fewer when they were large, so the rest of the send asked for nothing. The store's interface needs "these went into a batch", not only "here are the pending records".

## Moved to hardware, at M4

- Push delivery (part of statement 5): no CloudKit push reached a simulator, registered or not, so whether a push starts a fetch, and that such a fetch keeps Attachments out, needs a device.
- Statement 7: whether the engine retries network failures by itself. Only `notAuthenticated` (9) was seen, with no account: a manual fetch and send then fail at once. A network failure needs airplane mode on a device, because the simulators share the build Mac's network.
- Statement 17: whether the sandboxed Mac app needs `com.apple.security.network.client`. No team-signed Mac build runs on the build Mac.
- Statement 14 on a phone: the restore time on cellular and Wi-Fi.

## Ready for the second sitting

- The development schema of `iCloud.com.p3ob7o.knot.spike4` holds the record types `Note` (6 fields), `Segment` (16 fields) and `Asset`, written once with every field set by `schema-seed` and deleted after, and the zones `Stream` and `Attachments`. Nothing has reached its production side.
- The Production build is made by `build.sh sim-build Production` and names that container alone.
