# Checklists

Step-by-step lists for the owner, for everything that only real hardware can show. Each milestone has one checklist, and wave 0 has the two recording sessions of gate G4.

| File | When | Minutes |
|---|---|---|
| [G4-read-aloud.md](G4-read-aloud.md) | Wave 0, gate G4 | 15 |
| [G4-spontaneous-notes.md](G4-spontaneous-notes.md) | Wave 0, gate G4 | 15 |
| [M1.md](M1.md) | M1 · Skeleton on four devices, two sittings | 15 |
| [M2.md](M2.md) | M2 · iPhone voice and text, two sittings | 40 |
| [M3.md](M3.md) | M3 · Watch voice, two sittings | 30 |
| [M4.md](M4.md) | M4 · Mac and sync, three sittings | 45 |
| [M5.md](M5.md) | M5 · iPad Pencil, one sitting | 20 |
| [M6.md](M6.md) | M6 · Designed, three sittings | 90 |
| [M7.md](M7.md) | M7 · TestFlight v1, one sitting | 15 |

The minutes are those of PLAN.md §10. The orchestrator owns this folder once WP-04 has merged.

## How to use a checklist

- A sitting starts when `scripts/install.sh` has reported success. Each sitting says what it needs first.
- Each row is one action. Do it, compare with **Expect**, and tick one box: ☐ pass or ☐ fail.
- Write numbers, times and anything odd in **Notes**. Never write the text of a real note there.
- Mark a row n/a when it says it may not apply, such as a row for a device you don't have.
- A failed row does not stop the sitting. Carry on, unless a later row depends on it.
- A sitting has at most 20 rows. A longer checklist is split into sittings.
- Each checklist ends with free-form notes, which the orchestrator turns into change requests.
- Fill in a copy outside the repository, and give it to the orchestrator, who records the result.

Row IDs read `M<milestone>.<sitting>-<row>`: M2.1-03 is row 3 of the first sitting of M2.

## Coverage

Every hardware item of docs/architecture.md §17 has rows here, and so does every other check that the plan leaves to the owner's sittings. `Fixtures/tools/generate.sh --check` reads the Hardware row of §17, fails when one of its items is missing from the table below, and fails when the table names a row that does not exist.

<!-- coverage:begin -->
| Item | Source | Rows |
|---|---|---|
| Action Button | architecture §17 | M2.1-02, M2.1-03, M2.1-09, M2.1-10, M2.1-11, M2.2-11, M2.2-12, M2.2-13, M2.2-14, M2.2-15, M6.1-01, M6.3-03, M7.1-06 |
| Lock Screen | architecture §17 | M2.1-03, M2.1-04, M2.1-05, M2.1-07, M2.1-10, M6.1-01 |
| hotkey | architecture §17 | M4.2-01, M4.2-02, M4.2-03, M4.2-04, M4.2-05, M4.2-10, M4.2-11, M4.2-12, M4.2-13, M4.2-14, M4.2-15, M6.1-10, M6.1-11, M6.2-12, M6.3-06 |
| Pencil | architecture §17 | M5.1-01, M5.1-02, M5.1-03, M5.1-04, M5.1-05, M5.1-06, M5.1-07, M5.1-08, M5.1-09, M5.1-10, M5.1-13, M6.1-14, M6.2-13 |
| watch delivery | architecture §17 | M3.1-02, M3.1-03, M3.1-04, M3.1-05, M3.1-11, M3.1-12, M3.2-05, M3.2-06, M3.2-09, M6.1-08 |
| real sync | architecture §17 | M4.1-01, M4.3-01, M4.3-02, M4.3-03, M4.3-04, M4.3-05, M4.3-06, M4.3-15, M5.1-11, M5.1-12, M6.1-13, M6.1-15, M7.1-08 |
| The real watch transport | architecture §5, §12 | M3.1-02, M3.1-05, M3.2-06 |
| The CloudKit adapter on hardware | architecture §11 | M4.3-01, M4.3-02, M4.3-03, M4.3-04, M4.3-05, M4.3-06 |
| Speech on iOS | architecture §9 | M2.1-01, M2.1-08, M2.1-09, M2.1-10 |
| A forced restart during a recording, at M2 and M3 | architecture §6, rule 7 | M2.2-11, M3.2-09 |
| A kill during a capture on a device | product spec §14 | M2.2-10, M5.1-10, M6.1-06 |
| Start latency on a real microphone | PLAN.md §9 | M2.1-11, M4.2-16, M6.3-03, M6.3-04, M6.3-05, M6.3-06 |
| What injected audio cannot show | WP-04 brief | M2.1-12, M2.1-13, M2.1-14, M2.1-15, M4.2-08, M4.2-09 |
| Three passages read through Knot | WP-04 brief | M2.1-09, M3.1-11 |
| Locked and unlocked rows for each iPhone trigger | WP-04 brief | M2.1-02, M2.1-03, M2.1-04, M2.1-05, M2.1-06, M2.1-07 |
| The six cues on the iPhone | product spec §4.5 | M2.2-12, M2.2-13, M2.2-14, M2.2-15, M2.1-13, M3.1-12 |
| The six cues on the Watch | product spec §4.5 | M3.2-01, M3.2-02, M3.2-03, M3.2-04, M3.2-05, M3.2-06 |
| The six cues on the Mac | product spec §4.5 | M4.2-12, M4.2-13, M4.2-14, M4.2-15, M4.2-08, M4.3-07 |
| VoiceOver on each capture path | product spec §13 | M2.1-16, M2.2-16, M3.2-08, M4.2-10, M4.2-11, M5.1-13 |
| Latencies from the diagnostics export | WP-04 brief | M2.2-17, M4.2-16, M6.3-06 |
| The 60-second Watch target, in SP-2's condition | product spec §14 | M3.1-03 |
| No text of a note or a recording on the Watch | product spec §6 | M3.2-07, M6.1-09 |
| The MCP client and version, the 2-minute setup, one folder | WP-04 brief | M4.1-04, M4.1-05, M4.3-17, M4.3-18, M4.3-19 |
| The agent on the real notes, on the other Mac | WP-04 brief | M4.3-16, M4.3-17, M4.3-18, M4.3-19 |
| `knot move` and `--back`, and a move made on the iPhone | WP-04 brief | M4.1-08, M4.3-04 |
| Dragging a note out of the Mac window | WP-04 brief | M4.2-06, M4.2-07 |
| Several displays, Spaces and full-screen apps | WP-04 brief | M4.2-03, M4.2-04, M4.2-05 |
| No milestone build on the build Mac | architecture §18 | M4.1-02, M4.1-03, M4.3-20 |
| The retired app, kept and replaced | architecture §7 | M1.1-01, M1.1-02, M1.1-03, M1.1-04, M1.1-05, M1.1-06, M1.1-07, M1.1-08, M1.1-09, M1.1-10, M1.1-11, M1.1-12, M1.1-13, M1.1-14, M1.1-15, M4.3-10, M4.3-11, M4.3-12, M4.3-13, M4.3-14 |
| An export of the store before the milestone build opens sync | PLAN.md §5 | M4.3-08, M7.1-01, M7.1-02, M7.1-03 |
| The TestFlight install over the M6 milestone build | PLAN.md §5 | M7.1-04 |
| The design applied, accessibility and speed | PLAN.md §5, M6 | M6.2-01, M6.2-02, M6.2-03, M6.2-04, M6.2-05, M6.2-09, M6.2-14, M6.2-15, M6.3-07, M6.3-08 |
<!-- coverage:end -->
