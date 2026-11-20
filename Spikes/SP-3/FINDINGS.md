# SP-3 code half: where it stopped

The spike's working record, on `spike/agent-access` only. It is never merged. The short
note, `docs/notes/SP-3.md`, is written from it when the code half is resumed. Times are UTC,
2026-11-20. Paths under the home folder are written `~`, and the signing team `<team>`.

## What is here

- `project.yml`: the spike app `Knot Dev.app` (`com.p3ob7o.knot.dev`) and four packagings of
  one tool (`com.p3ob7o.knot.dev.cli`), all claiming only the development app group
  `group.com.p3ob7o.knot.dev`. No iCloud and no push.
  - `Contents/MacOS/knot-dev`: a bare executable with its own sandbox, the group, and an
    Info.plist in its binary (the packaging WP-01 chose).
  - `Contents/Helpers/knot-dev.app`: the same tool as a helper bundle, which can carry a
    provisioning profile.
  - `Contents/Helpers/variants/knot-dev-noplist`: own sandbox, no Info.plist (rule 1).
  - `Contents/Helpers/variants/knot-dev-inherit`: only `app-sandbox` and `inherit` (rule 1).
- `Shared/SpikeStore.swift`: a synthetic GRDB store, configured as Knot's (a pool in WAL
  mode, synchronous FULL, fullfsync on the writer, 5-second busy timeout), in
  `<group container>/SP3-spike/`, and the probe every process runs.
- `Tool/main.swift`: `probe`, `add`, `export <folder>`, `export -`, `export-group`, `mcp`
  (one JSON request per line) and `cleanup`.
- `App/main.swift`: `--self-test [--seconds N] [--spawn]` runs headless with no
  NSApplication, so no window and no focus, and quits within N seconds. Opened from Finder
  it shows one window for the owner's distribution-signed check.
- `run.sh build` signs every piece with the team's development certificate and no
  profile. `run.sh build --profiles` signs the app and the helper automatically, which needs
  an Xcode account. `run.sh signing` prints what each piece carries, masked.

Still to write when resumed: the check harness (`run.sh checks`, with a time limit on
every run), the stand-in MCP client, the PATH trial in a temporary folder, and the survey
of Mac App Store apps.

## Signing on this Mac

- `scripts/bootstrap.sh` linked the owner's configuration. `codesign` signed with the
  Apple Development identity without a prompt.
- Xcode has no account signed in: `xcodebuild -allowProvisioningUpdates` stops with "No
  Accounts: Add a new account in Accounts settings", and no Mac development profile is on
  the Mac. So nothing was registered in the account.
- With manual signing and no profile, Xcode refuses the app and the helper bundle: "requires
  a provisioning profile", because they claim a `group.` app group. A tool target with the
  same entitlement builds. So `run.sh build` builds unsigned and signs each piece with
  `codesign`, innermost first.

## The runs

| Time | Run | What happened |
|---|---|---|
| 01:09 | Before any team-signed run | `~/Library/Containers/com.p3ob7o.knot.dev` and `….cli`, and their folders in `Application Scripts`, existed, made on 2026-11-19 by the locally signed builds. No group container for `group.com.p3ob7o.knot.dev`. The gate's `launch` step passed: the locally signed app showed a 320x240 window. |
| 01:23:41 | Team-signed bare `knot-dev --version`, limit 10 s | Hung, killed at the limit. It never reached its own code. |
| 01:23:42 | (system log of that run) | containermanagerd: "Signature insufficient for strict scrutiny" for each of `platform binary`, `MAS`, `profile validated entitlements`, `iPad app` and `TestFlight`, then "[com.p3ob7o.knot.dev.cli] requesting [group]: REJECTED. Requestor's signature does not allow it to access a TCC-protected group container. Group containers identifiers should be prefixed by requestor's team ID to allow access on this platform." It made the group container all the same. Then secinitd: "binary identity <<team>/com.p3ob7o.knot.dev.cli; signer:development> not in ACL for container ~/Library/Containers/com.p3ob7o.knot.dev.cli/Data <[{"validationCategory":"none","signingIdentifier":"com.p3ob7o.knot.dev.cli"}]>; prompting". UserNotificationCenter put up a dialog, a window of 410x450. |
| 01:23:51 | Team-signed bare `knot-dev probe`, limit 20 s | Hung, killed at the limit. Its sandbox setup was never answered. |
| 01:25:11 | The gate's locally signed `knot-dev --version`, limit 10 s | Hung, killed at the limit. Its sandbox setup was never answered either. |
| 01:26:09 | `say -o` into a temporary file, limit 15 s | Done in a second. Its sandboxed service started normally, so sandbox setup is blocked only for the tool's identity. |
| 01:26:2x | The locally signed Knot app, as the `launch` step runs it | Showed its 320x240 window. |

The runs stopped there.

## What it shows so far

1. **A development-signed bare executable cannot use a `group.` app group.** The system
   refuses it without asking, and its log names the five kinds of signature that pass:
   platform binary, Mac App Store, entitlements validated by a profile, iPad app, and
   TestFlight. So the distribution-signed check decides whether the bare tool works in a
   TestFlight or Mac App Store build, and a development build can never answer that. The
   log itself points at the Team-ID form (`$(TeamIdentifierPrefix)com.p3ob7o.knot.dev`),
   which this round did not try: it is not one of the agreed identifiers.
2. **A locally signed and a team-signed build of one identifier do not share a container
   quietly.** The data container keeps a list of the signers allowed in. The first signer,
   the ad-hoc local build, is on it. A second signer gets a consent dialog.
3. **While that dialog waits, every launch of that identifier waits, whoever signed it.**
   The gate's own locally signed tool hangs at sandbox setup. Other sandboxed processes are
   not affected. The gate's `packaging` step runs `knot-dev --version` with no time limit,
   so on this Mac it would hang until the dialog is answered.

## State left on the Mac

- The dialog of 01:23:42 is still open. No agent answers it.
- New since 01:09, made by the system at 01:23:42: `~/Library/Group Containers/group.com.p3ob7o.knot.dev`
  and `~/Library/Application Scripts/group.com.p3ob7o.knot.dev`. The spike wrote no file into
  either, because no spike process got past its sandbox setup. Left in place: containers are
  not deleted.
- `~/Library/Containers/com.p3ob7o.knot.dev` and `….cli` are the ones of 2026-11-19. Their
  dates changed only by the gate's and this check's launches of the local builds.
- No spike process is running. The spike's build is in the worktree's `.build/sp3/`.
