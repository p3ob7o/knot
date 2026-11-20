# SP-3 code half: the working record

The spike's working record, on `spike/agent-access` only. It is never merged. The short
note, `docs/notes/SP-3.md`, is written from it once the runs that need the owner at the Mac
are done. Times are UTC, 2026-11-20. Paths under the home folder are written `~`, the
signing team `<team>`, and a certificate's holder `<holder>`.

## What is here

- `project.yml`: the spike app `Knot Dev.app` (`com.p3ob7o.knot.dev`) and four packagings of
  one tool (`com.p3ob7o.knot.dev.cli`). Every piece claims two forms of the development app
  group, `group.com.p3ob7o.knot.dev` and the Team-ID form, written only as
  `$(TeamIdentifierPrefix)com.p3ob7o.knot.dev`. No iCloud and no push.
  - `Contents/MacOS/knot-dev`: a bare executable with its own sandbox and an Info.plist in
    its binary (the packaging WP-01 chose).
  - `Contents/Helpers/knot-dev.app`: the same tool as a helper bundle, which can carry a
    provisioning profile.
  - `Contents/Helpers/variants/knot-dev-noplist`: own sandbox, no Info.plist (rule 1).
  - `Contents/Helpers/variants/knot-dev-inherit`: only `app-sandbox` and `inherit` (rule 1).
- `Shared/SpikeStore.swift`: a synthetic GRDB store configured as Knot's (a pool in WAL
  mode, synchronous FULL, fullfsync on the writer, 5-second busy timeout), in
  `<group container>/SP3-spike/`. Each process reads its groups from its own signature, and
  `--team-group` picks the Team-ID form.
- `Tool/main.swift`: `probe`, `add`, `export <folder>`, `export -`, `export-group`, `mcp` (one
  JSON request per line, exits at end of input) and `cleanup`.
- `App/main.swift`: `--self-test [--seconds N] [--spawn]` runs headless with no
  NSApplication, so no window and no focus, quits within N seconds, and with `--spawn`
  starts each packaging of the tool over standard input and output, as a sandboxed MCP
  client would. Opened from Finder it shows one window for the owner's distribution-signed
  check, with the Terminal commands to run.
- `run.sh build` signs every piece with the team's development certificate and no profile.
  `run.sh build --profiles` signs the app and the helper automatically. `run.sh signing`
  prints what each piece carries. `run.sh checks tool|app` runs `checks.py`: every run under
  a time limit, the system log read after each run for a consent prompt (it stops at once
  on one), and the gate's locally signed `knot-dev --version` checked after each first
  start. Everything printed is masked.

## Signing on this Mac

- `codesign` signs with the Apple Development identity without a prompt.
- Morning: Xcode had no account ("No Accounts"). Afternoon, after the owner signed in:
  `xcodebuild -allowProvisioningUpdates` stops at "Device … isn't registered in your
  developer account". With the owner's word, `-allowProvisioningDeviceRegistration`
  registered this Mac at 12:46, and the build then signs the app and the helper with the
  wildcard Mac team profile. The build logs do not say whether explicit App IDs were
  registered.
- With manual signing and no profile, Xcode refuses an app or helper bundle that claims a
  `group.` group: "requires a provisioning profile". A tool target with the same entitlement
  builds. So `run.sh build` builds unsigned and signs each piece with `codesign`.

## The runs

### Morning: the dialog

| Time | Run | What happened |
|---|---|---|
| 01:09 | Before any team-signed run | `~/Library/Containers/com.p3ob7o.knot.dev` and `….cli`, made on 2026-11-19 by the locally signed builds. No group container. The gate's `launch` step passed. |
| 01:23:41 | Team-signed bare `knot-dev --version`, limit 10 s | Hung at sandbox setup. secinitd: "binary identity <<team>/com.p3ob7o.knot.dev.cli; signer:development> not in ACL for container ~/Library/Containers/com.p3ob7o.knot.dev.cli/Data <[{"validationCategory":"none","signingIdentifier":"com.p3ob7o.knot.dev.cli"}]>; prompting". A dialog came up. |
| 01:23:42 | (same run) | containermanagerd, for the `group.` group: "Signature insufficient for strict scrutiny" for `platform binary`, `MAS`, `profile validated entitlements`, `iPad app` and `TestFlight`, then "REJECTED … Group containers identifiers should be prefixed by requestor's team ID to allow access on this platform." No prompt for the group: it is refused. |
| 01:25:11 | The gate's locally signed `knot-dev --version` | Hung too, while the dialog waited. `say -o` started its own sandboxed service normally, and the locally signed Knot app launched. |

The owner answered "Allow" later in the morning. The team is now a second signer of the
tool's data container, and the locally signed tool starts again.

### Afternoon: the tool phase (`run.sh checks tool`, 12:35:54 to 12:36:25)

No consent prompt in any run, and the gate's local `knot-dev --version` started after every
first start and after the last run.

| Check | Result |
|---|---|
| Bare tool, team-signed, no profile: `--version` | Starts at once. |
| Bare: `probe`, `group.` form | The group is refused at sandbox setup with no prompt; writing in its container fails, `NSCocoaErrorDomain 513` (no permission). |
| Bare: `probe` and `add`, Team-ID form | The group container `~/Library/Group Containers/<team>.com.p3ob7o.knot.dev` opens. The store opens in WAL mode, a write commits, and `notify_post` succeeds. |
| Bare: `export <folder>`, a folder under the temporary folder and one under the home folder | Refused, `NSCocoaErrorDomain 513`, in both. |
| Bare: `export - > file`, the shell opens the file | Works: the file is written. |
| Bare: `export-group`, Team-ID form | Works: the file lands in the group container. |
| PATH: a symbolic link to the tool, in a folder of the user's own on PATH | Runs, sandboxed, under its own container. But `Bundle.main` finds no Info.plist through a link: no bundle ID, no version. The same through a link called by its absolute path. |
| PATH: a two-line shell script that `exec`s the tool's real path | Runs, and `Bundle.main` reads the embedded Info.plist. |
| PATH: a copy of the bare binary outside the bundle | Runs as the same identity, with its Info.plist. |
| A stand-in MCP client, from a shell: `knot-dev mcp` over pipes; a second process writes while the session is open; then the session writes; then end of input | The open session sees the other process's write on its next read (counter 1, 2, 3), and the tool exits 0 at end of input. |
| Helper bundle, no profile: `--version`, `probe` in both forms | As the bare tool: `group.` refused, Team-ID form works. Through a link, the helper loses its bundle the same way. |
| No Info.plist: `--version` | Traps at launch: "Unable to get bundle identifier for container id com.p3ob7o.knot.dev.cli: Unable to get bundle identifier because Info.plist from code signature information has no value for kCFBundleIdentifierKey." |
| Only `inherit`, started from a shell | Traps at launch: "Process is not in an inherited sandbox." |
| `cleanup`, both forms | Removed the four files and the `SP3-spike` folder from the Team-ID group container; nothing was in the `group.` one. |

### Shipping Mac App Store apps on this Mac (read, not run)

| App | Tool | How it is packaged | How it is delivered |
|---|---|---|---|
| Day One 2026.23 | `Contents/MacOS/dayone`, a CLI | Bare executable, identifier `com.bloombuilt.dayone.cli`, its own `app-sandbox`, an Info.plist in its binary (12 entries), app groups in the Team-ID form only, signed by Apple Mac OS Application Signing. No profile. | Its public guide has the user run `sudo bash …/install_cli.sh`, which writes `/usr/local/bin/dayone`; the installed version carries no such script in its bundle. The CLI finds the app through `DAYONE_APP_PATH`. |
| DetailsPro 6.20.0 | `Contents/MacOS/detailspro-mcp`, an MCP server | Bare executable, identifier `app.funfocus.DetailsPro.mcp`, its own `app-sandbox`, an Info.plist in its binary (6 entries), a `group.` app group and `network.client`, signed by Apple. | The app shows a configuration with the absolute path into its bundle, and `claude mcp add` / `codex mcp add` lines. The server bridges to the running app over loopback port 13777: "DetailsPro must be running on the user's Mac for this MCP server to work." |

### Afternoon: the sitting with the owner, 12:44 to 12:49

| Time | Run | What happened |
|---|---|---|
| 12:44:30 | The app's first team-signed start, `--self-test --team-group`, limit 90 s | secinitd: "binary identity <<team>/com.p3ob7o.knot.dev; signer:development> not in ACL for container ~/Library/Containers/com.p3ob7o.knot.dev/Data …; prompting". The owner allowed it at 12:44:35. The Team-ID group: "APPROVED", no dialog. The app opened the store. |
| 12:44:56 | `run.sh checks app`: the app runs, the tool writes, the app spawns each packaging | The app saw the tool's write through the Darwin notification. Its spawned bare tool raised a second dialog at 12:44:58: the tool's identity was "not in ACL" for the app's data container, `~/Library/Containers/com.p3ob7o.knot.dev/Data`. The owner allowed it at 12:45:02, after the child had been killed at its 3 s limit. |
| 12:45:58 | `run.sh checks app` again | No prompt. Spawned by the sandboxed app, the bare tool, the helper and the no-Info.plist tool each trap in sandbox setup (signal 5); the `inherit` tool runs, inside the app's container (`APP_SANDBOX_CONTAINER_ID` is the app's). |
| 12:46:32 | `run.sh build --profiles` with `-allowProvisioningDeviceRegistration` | Xcode registered this Mac and fetched a profile; the first try failed on the profile's file not yet being on disk, the second built. |
| 12:47 | Explicit App Groups: the capability in the project, `REGISTER_APP_GROUPS=YES`, a clean build | Xcode still signs the app and the helper with the wildcard "Mac Team Provisioning Profile: *", one device, which authorises no app group. |
| 12:48:13 | Both phases on the profiled build | As without a profile: `group.` refused for the app and the helper too, the Team-ID form works, no prompt. The app's own `probe` in the `group.` form fails with 513. |

The gate's local `knot-dev --version` started after every run, and the locally signed app
showed its 320x240 window at 12:46 and at 12:49.

## What it shows so far

1. **Packaging rule 1 holds.** A tool started from Terminal needs its own `app-sandbox`
   (an `inherit`-only tool traps) and an Info.plist in its binary (without one it traps
   before `main`).
2. **Packaging rule 2, for a development build: the Team-ID form works with no profile, and
   the `group.` form does not.** A development-signed tool, bare or in a helper bundle with
   no profile, is refused the `group.` group without a prompt and gets the Team-ID group.
   The system's log names five kinds of signature that pass for `group.`: platform binary,
   Mac App Store, profile-validated entitlements, iPad app, TestFlight. So whether a bare
   `group.` tool works in a TestFlight build is for the distribution-signed check; DetailsPro
   ships exactly that. Apple's forum posts describe the same three routes to no prompt: Mac
   App Store, TestFlight on macOS 15.1 or later, or a Team-ID prefix.
3. **The store works across processes in the group container.** WAL mode, two sandboxed
   processes, a write by one seen by the other's open session, and the Darwin notification
   posts.
4. **A sandboxed tool cannot write to a folder named on the command line**, under the
   temporary folder or the home folder. `knot export -` writing to standard output, which
   the shell places, works, and so does writing into the group container.
5. **PATH.** The sandboxed app cannot write `/usr/local/bin` or the user's shell files. A
   symbolic link works for the sandbox but loses the embedded Info.plist, which WP-01's
   `knot` reads for its flavour and version, and so for the rule that refuses an agent the
   milestone tool. A shell script that `exec`s the real path keeps it. MCP clients take the
   absolute path and need no PATH.
6. **A locally signed and a team-signed build of one identifier can share a container only
   after the owner allows it.** Each new signer raises a dialog, and while it waits every
   start of that identifier, the first signer's included, waits.
7. **The app sees the tool's write while it runs**, through the Darwin notification, in the
   Team-ID group container.
8. **A sandboxed parent cannot start the tool.** A tool with its own sandbox traps in sandbox
   setup when a sandboxed app starts it; an `inherit` tool runs, but in the parent's
   container and the parent's groups, and its identity must be allowed into the parent's
   data container. So an MCP client that is itself a sandboxed app cannot start Knot's tool.
9. **A development profile does not change the group's answer** while Xcode picks the
   wildcard team profile, which authorises no group.

## Left over

- A profile that authorises the `group.` group. Xcode signs with the wildcard team profile,
  which authorises none, and an explicit App ID with App Groups needs the developer website
  or an App Store Connect key. The distribution-signed check needs explicit App IDs anyway.
- The distribution-signed check itself (docs/notes/SP-3.md lists its commands).

## State on the Mac at 12:49

- `~/Library/Containers/com.p3ob7o.knot.dev` and `….cli`, from 2026-11-19. The team is now a
  second signer of both, and the tool's identity a third signer of the app's.
- `~/Library/Group Containers/group.com.p3ob7o.knot.dev` and its `Application Scripts`
  folder, made by the system at 01:23:42; the spike wrote nothing there.
- `~/Library/Group Containers/<team>.com.p3ob7o.knot.dev` and its `Application Scripts`
  folder, made at 12:35:54 by the tool; empty of the spike's files after the last `cleanup`.
- This Mac is registered as a development device in the owner's account, and Xcode holds a
  Mac wildcard team profile. The spike's crash reports were removed by name.
- No spike process running. The build is in the worktree's `.build/sp3/`. Containers are
  left in place.
