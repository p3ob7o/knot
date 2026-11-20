# SP-4 stage 2: what it needs, and in what order

Prepared on 2026-11-20. Stage 2 runs the spike's iOS app, signed with the owner's team, in this worktree's two simulators: the iPhone simulator whose name ends in `-iphone` and the iPad simulator whose name ends in `-ipad` (`scripts/sim.sh list`). It never runs a team-signed build on the Mac itself.

## The builds

| Build | Containers it names | Environment | Made by |
|---|---|---|---|
| Development | `iCloud.com.p3ob7o.knot.dev`, `iCloud.com.p3ob7o.knot.spike4` | Development | `build.sh sim-build Development` |
| Production | `iCloud.com.p3ob7o.knot.spike4` only | Production, through `com.apple.developer.icloud-container-environment` | `build.sh sim-build Production` |

The environment entitlement applies to every container a build names, so the Production build names the throwaway container alone. `LiveSync.target` refuses `iCloud.com.p3ob7o.knot` by name, refuses any container but these two, and refuses Production for the development container. `build.sh` checks the entitlements of each build and fails on any other container.

A simulator build is signed ad hoc and needs no provisioning profile: Xcode writes the entitlements into the executable's `__TEXT,__entitlements` section, and the build never passes `-allowProvisioningUpdates`, so it registers nothing. Both builds were made on 2026-11-20. With no account signed in, the app reached CloudKit: `accountStatus` answered `noAccount`, and a manual fetch and send failed at once with `notAuthenticated` (code 9).

## What has to exist in the developer account

| Thing | Needed for the simulators? | How it comes to exist |
|---|---|---|
| The container `iCloud.com.p3ob7o.knot.dev` | Yes. CloudKit refuses an unknown container (`badContainer`). | Developer portal: Identifiers, (+), iCloud Containers. Or Xcode's iCloud capability editor, whose (+) registers it. Whether Xcode's automatic provisioning from `xcodebuild` makes a missing container is not documented. |
| The container `iCloud.com.p3ob7o.knot.spike4` | Yes, the same way. | The same. |
| The app ID `com.p3ob7o.knot.dev`, with iCloud (CloudKit) on and both containers assigned | Not documented for a simulator, which checks no profile. It is what a device build needs, so stage 2 has it made rather than find out by failing. | Developer portal: Identifiers, the app ID, iCloud, Edit, tick both containers. Or Xcode's automatic provisioning for a device destination, which registers the app ID and turns its capabilities on from the entitlements; the team already has registered iOS devices, so it can make a development profile. |
| A provisioning profile | No. A simulator build uses none. | Only a device build makes one. |
| The app group `group.com.p3ob7o.knot.dev` | No: the spike names no app group. | Not needed now. |

## Getting a schema to the production side of the throwaway container

- `cktool`'s help lists `import-schema`, `validate-schema` and `export-schema` with `--environment`, and its man page spells the values `development | production`. Every one of them needs a management token, which reaches every container of the team, so the spike plans on none.
- Apple's page "Integrating a Text-Based Schema into Your Workflow": "The CloudKit command line tools download, verify, and install a schema to your container's sandbox environment, while the CloudKit dashboard promotes a schema to the production environment." Apple's page "Deploying an iCloud Container's Schema" gives the Console's steps: CloudKit Database, the container, Deploy Schema Changes, review, Deploy. Deploying copies record types, fields and indexes, not records, and only adds to what production has.
- So the schema reaches production by the owner's click in the CloudKit Console, once. The spike's first saves in the development environment make the development schema, and the Console promotes it.

## A second Apple ID that is not on the team

Apple's page "Enabling CloudKit in Your App" says to pick or create an iCloud account for development, enter it on each simulator, and that the iCloud account is distinct from the developer account. Using the same Apple ID only adds a view of that account's private data in the Console. The environment comes from the build's entitlement, not from the account. So, by the documentation, an additional Apple ID that is not a member of the team can use the development environment of these containers from a development-signed build. Nothing read says it plainly for a non-member, so the first `account` and `sync` steps after sign-in settle it, in about two minutes.

## The seventeen statements of the note's "Not verified yet"

Agent times are for one agent, one heavy build at a time.

### The two simulators answer by themselves, once signed in

| # | Statement | Agent time |
|---|---|---|
| 1 | A `stateUpdate` never covers a batch not yet applied, and how often one comes | 15 min |
| 2 | Whether a batch's sent event comes before the next request for a batch | 10 min |
| 3 | Whether `RecordZoneChangeBatch(pendingChanges:recordProvider:)` counts bytes, and what the server does with large records under 250 | 25 min |
| 4 | Whether `hasPendingUntrackedChanges` clears itself, and which way of telling the engine keeps the state smaller | 20 min |
| 5 | `.allExcluding([Attachments])` in scheduled fetches, pushes for that zone, and a deleted Attachments zone. If CloudKit's pushes do not reach a simulator, the push part moves to hardware. | 30 min |
| 6 | Cancelling the task that awaits a fetch or a send, and what `cancelOperations()` leaves running | 10 min |
| 8 | The record limit, 10^6 or 2^20 bytes, whether encryption and field names count, and the asset limit | 30 min |
| 9 | Encrypted `title`, `text` and `rawTranscript` round-trip through the development schema made by the first save. That the schema marks them encrypted is read in the Console at the sitting. | 10 min |
| 10 | A segment's note reference changes after the record is saved | 5 min |
| 11 | The server keeps a field a save does not send | 10 min |
| 12a | A zone removed by the app (`deleted`), and what a send into it returns | 15 min |
| 14 | The state's size, and the restore time for 5,000 notes, 20,000 segments and their deletions, in a simulator. A phone's time follows at M4. | 45 min |
| 16 | Whether the Swift `Configuration` holds its delegate weakly | Done on 2026-11-20 with no account: it does. The engine does not keep the adapter alive. |

About 3 h 45 min of agent time, with no one at the Mac.

### Need the owner at a sitting

| # | Statement | His part |
|---|---|---|
| 15 | A move from development to production, in the throwaway container | 3 min: the Console's Deploy Schema Changes. The agent then runs the Production build, about 15 min. |
| 9 | The schema marks the three text fields encrypted | Under 1 min, at the same Console page |
| 12b | A zone purged by the user (`purged`) | 3 min: in the iPad simulator's Settings, the Apple ID, iCloud, Manage Storage, the spike's data, Delete. |
| 13 | What the account event reports on sign-out, sign-in and switch, and that the engine drops its pending list, with uploads pending | 3 min to sign the iPad simulator out and in again. 6 min for the switch: sign it out, sign in with his own Apple ID, wait while the agent runs one step, sign out, sign back in with the additional one. |
| 12c | `encryptedDataReset` | Only by resetting the additional Apple ID's end-to-end encrypted data, which a simulator may not offer. Proposed: skipped, and the report rests on reading for it, unless he says otherwise. |

### Need hardware

| # | Statement | Where |
|---|---|---|
| 7 | That the engine retries the transient codes itself. Only `notAuthenticated` was seen, with no account. A network failure needs airplane mode on a device, because the simulators share the build Mac's network with other threads. | M4, 10 min |
| 17 | Whether the sandboxed Mac app needs `com.apple.security.network.client`. A team-signed Mac build cannot run on the build Mac. | M4, on his other Mac, 5 min |
| 14 | The restore time on a phone | M4, 15 min |
