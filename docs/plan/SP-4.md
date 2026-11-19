# SP-4 · CloudKit sync shape

| Size | Wave | Run by |
|---|---|---|
| M | 1 | Its own thread |

## Goal

Test the sync design of `docs/architecture.md` §11 against CloudKit, and fix the final CloudKit schema before the sync columns of WP-10 and the sync of WP-16 build on it.

## Owns

- `spike/sync-shape`, the branch that holds the spike's code. It is never merged.
- `docs/spikes/SP-4.md`, the report.
- `docs/notes/SP-4.md`, the short note of its code half

## Starts after

| PR | What it holds | Starts after |
|---|---|---|
| Notes | The code half on `spike/sync-shape`, and its short note | WP-01 PR 1; WP-04 |
| 1 | The report, `docs/spikes/SP-4.md`, which holds the final CloudKit schema and ends with a decision | SP-4 notes |

The code half starts beside WP-02 PR 1, with the proof steps of WP-12, WP-13, WP-14 and WP-18. It needs only WP-01 PR 1 and WP-04. It files a short note saying whether the draft port fits the real API's streaming, cancellation and errors. The note is `docs/notes/SP-4.md`, merged by a pull request that holds nothing else.

WP-02 PR 3 waits for SP-4's short note, and not for its report. No chain to M2 waits for the report of SP-4. WP-02 fixes its size numbers after SP-4 confirms CloudKit's record limit.

SP-4 is done when its report has merged and the owner has confirmed its decision. Gate G3 is the owner's sitting for those confirmations, and each spike is confirmed on its own, so a package waits only for the spikes its row names.

These wait for SP-4: WP-10 PR 2, for the sync columns; and WP-16, which starts after WP-10 PR 2 and builds everything in `docs/architecture.md` §11 as amended by SP-4.

## Build

- SP-4 needs the development iCloud container and two signed-in devices or simulators.
- The code on `spike/sync-shape` answers these questions:
  - Does the design in `docs/architecture.md` §11 hold: an engine-managed zone for notes and segments, and an attachments zone kept out of automatic fetches and read on demand?
  - Do encrypted fields work for all text?
  - Can a trigger-fed change log drive the engine's pending changes, including writes from another process?
  - How large does the engine's serialised state grow?
  - How long does a fresh install take to restore 5,000 notes, 20,000 segments and their deletions?
  - What do toggling sync off and on, and changing iCloud account, do?
  - Do the ownership, machine-text and deleted-note rules of `docs/architecture.md` §11 hold when two devices see the same segment?
  - Can a segment record's note reference change after the record is saved? Sync carries a move by the rule in `docs/architecture.md` §11, and the deleted-note rule needs the answer as well.
  - What happens when a device moves from CloudKit's development environment to production?
  - What does CKSyncEngine report when the zone is removed from iCloud? Test each reason it reports for a deleted zone.
  - How is a replica that stayed away for more than 30 days handled? SP-4 fixes the mechanism (`docs/architecture.md` §11).
  - What happens to a segment that arrives before its note?
  - What happens on a kill between applying a batch and saving the engine's state?
  - What happens to a store restored from an older copy?
  - What happens to a record at the size limit?
  - What happens on a change of account with uploads pending?
  - What does a restored or replaced phone do to device identity?
  - Does an existing sync layer over GRDB and CKSyncEngine, such as SQLiteData, meet those rules, and at what dependency cost?
- Confirm CloudKit's record limit. `docs/architecture.md` §20 holds, from memory, that a record holds at most about 1 MB apart from its assets.
- Fix the mechanism of account isolation, which WP-16 builds. A record counts as synced only for the account, the environment and the zone identity it was synced under, and the zone carries an identity written when it is made. So a record missing from the zone it was synced to is deleted locally, and a zone that is gone or new deletes nothing. A fetch that would delete more than a set share of the local notes pauses sync and asks.
- `docs/architecture.md` §20 reports that CKSyncEngine downloads assets eagerly and offers no way to fetch selected fields. SP-4 checks it.
- The engine's events cannot be built in a test, so `docs/architecture.md` §11 has the thin adapter between CKSyncEngine and the merge core proven by SP-4's harness, and on hardware at M4.
- Set the restore time. A fresh install in WP-16 restores within the time SP-4 set.
- The report, `docs/spikes/SP-4.md`, holds the final CloudKit schema.
- Where the answer changes `docs/architecture.md`, the report lists the changes it asks for. The orchestrator owns that file and makes them in a pull request of its own (PLAN.md §7).

## Merge criteria

- `docs/spikes/SP-4.md` holds the final CloudKit schema.
- It answers every question under "Build".
- It confirms CloudKit's record limit.
- It sets the restore time for a fresh install of 5,000 notes, 20,000 segments and their deletions.
- It fixes the mechanism of account isolation and the mechanism for a replica that stayed away for more than 30 days.
- It says whether an existing sync layer such as SQLiteData meets the rules of `docs/architecture.md` §11, and at what dependency cost.
- It ends with a decision.
- Nothing from `spike/sync-shape` merges to `main`. The report PR changes documents only, so the gate runs the plan check and the link check (`docs/architecture.md` §18), and both pass.

## Milestone evidence

- Gate G3, with SP-4. The owner signs two devices into iCloud for the sync spike, about 10 minutes.
- A sitting with the spike's build starts when `scripts/install.sh` has reported success.
- Gate G3. The owner reads the report and confirms its decision. Each spike is confirmed on its own.
- Adding a dependency, such as an existing sync layer, stays the owner's decision under D30.
- M4 needs SP-4.

## Prior art

None.

## Failure rules

- If CKSyncEngine is harder than planned, sync lands late. Knot is fully usable on each device without sync. Sync has its own lane and its own gate.
- No new dependency without the owner's approval. GRDB is the one third-party library (D30).
- Deploying the CloudKit production schema needs Paolo's explicit authorisation.
- The spike app uses the development identifiers: the bundle ID with a `.dev` suffix, its own app group and its own iCloud container. Only a milestone build opens the default store or the real iCloud container, so nothing before the M1 milestone build touches the retired app or its container.
- The spike's code stays on `spike/sync-shape` and is never merged.
- Read the declaration of each OS 26 or OS 27 API in the SDK before using it (`docs/architecture.md` §21), and name the declarations read in the report PR.

## Named tests

None.
