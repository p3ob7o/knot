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

## Found on the way

- Sending is slow next to fetching: 600 small records took 31 s to send, about 10 s for each batch of 250, and 11 s to fetch on a fresh replica.
- The store must learn which records a batch took. The spike's store first marked every record it offered as handed out, and the adapter's builder took fewer when they were large, so the rest of the send asked for nothing. The store's interface needs "these went into a batch", not only "here are the pending records".
