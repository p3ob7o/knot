# SP-3 code half: command-line access to the store

The code half of SP-3, 2026-11-20, on the build Mac: macOS 27.3 (26C5047e), Xcode 27.2 (27B52), the MacOSX 27.2 SDK. Its code is the spike app on the branch `spike/agent-access`, in `Spikes/SP-3/`, at `a9c95718`, which is never merged; `Spikes/SP-3/FINDINGS.md` there is the run-by-run record. This note has three readers: WP-10 and WP-34, which build the second process and the tool; the orchestrator, which keeps docs/architecture.md and the runbook; and the report, `docs/spikes/SP-3.md`, which follows the distribution-signed check.

Everything here was signed for development with the owner's team, under the development identifiers only: the app `com.p3ob7o.knot.dev`, the tool `com.p3ob7o.knot.dev.cli`, and the app group in two forms, `group.com.p3ob7o.knot.dev` and the Team-ID form, written `$(TeamIdentifierPrefix)com.p3ob7o.knot.dev`. No iCloud and no push. A development build cannot say what a TestFlight build does, so the questions of the brief are marked "answered here", "needs the distribution-signed check" or "needs the owner". Times are UTC; `<team>` stands for the team's ID and `~` for the home folder.

## In short

1. **The direct route works in a development build, with the Team-ID form of the group.** A sandboxed tool inside the app bundle, started from Terminal or by a stand-in MCP client, opens a GRDB store in WAL mode in the group container, writes, and posts the Darwin notification, with no consent prompt and no provisioning profile. The app, running at the time, sees the write through the notification.
2. **The `group.` form is refused to every development-signed piece.** The system refuses the bare tool and the helper bundle, with or without the wildcard development profile Xcode chose, and the app with that profile, and asks nothing. Its log names the five kinds of signature that pass: platform binary, Mac App Store, entitlements validated by a profile, iPad app and TestFlight. So whether the `group.` form works for a shipped tool is for the distribution-signed check. One shipping App Store app does use it (below).
3. **Both packaging rules of §15 hold.** A tool started from Terminal traps before `main` without its own `app-sandbox` (an `inherit`-only tool) and without an Info.plist in its binary. A bare executable carries no profile, and with the Team-ID form it needs none.
4. **A sandboxed parent cannot start the tool.** Started by a sandboxed app, every packaging with its own sandbox traps in sandbox setup. So an MCP client that is itself a sandboxed app cannot start Knot's tool; Claude Code, Codex and other unsandboxed clients can.
5. **A sandboxed tool cannot write to a folder named on the command line**, under the temporary folder or the home folder. `knot export -`, written to standard output and placed by the shell, works, and so does writing into the group container.
6. **The app cannot put the command on PATH by itself, and a symbolic link is not enough.** Through a link the tool keeps its sandbox but loses the Info.plist in its binary, which WP-01's `knot` reads for its flavour and version. A two-line shell script that `exec`s the real path keeps it.
7. **A locally signed and a team-signed build of one identifier share a container only after a consent dialog for each new signer, and while the dialog waits every start of that identifier waits**, the gate's locally signed tool included.

## Each question, and where it is answered

| Question of the brief | Status | Answer |
|---|---|---|
| Can a sandboxed executable inside the bundle, started from Terminal or by an MCP client, open the store in the app group container for reading and writing, in a TestFlight-signed build, with no consent prompt? | Answered here for a development build; needs the distribution-signed check for TestFlight | Development: yes with the Team-ID form, no prompt, no profile; no with the `group.` form. Started by an unsandboxed client over standard input and output: yes. Started by a sandboxed app: no, it traps. TestFlight: the check below. |
| Which entitlements and bundle layout does that need? | Answered here; the group's form needs the check | A bare executable in `Contents/MacOS`, its own `com.apple.security.app-sandbox` and `com.apple.security.application-groups`, no `inherit`, an Info.plist in its binary (`CREATE_INFOPLIST_SECTION_IN_BINARY`) whose `CFBundleIdentifier` is the tool's ID, signed with the tool's ID. A helper bundle adds nothing while its profile authorises no group. |
| How does a sandboxed app put the command on the user's PATH? | Answered here for the shell; the in-app route is untested | The sandbox lets the app write neither `/usr/local/bin` nor the user's shell files. The command can be a shell script that `exec`s the tool's real path, in a folder on PATH; Settings can show the one line that makes it, or write it into a folder the user picks in an open panel, which this spike did not build. MCP clients take the absolute path and need no PATH. |
| Does it work while the app is running, and does the app see the change? | Answered here | Yes. The app had the store open; the tool wrote; the app read the new counter on the Darwin notification. Two tools and the app shared the WAL store in the group container, and an open MCP session saw another process's write on its next read. |
| How do two or three shipping Mac App Store apps deliver a CLI or an MCP server? | Answered here | Day One and DetailsPro, below. |
| Can the sandboxed tool write to a folder the user names? If not, how does `knot export` deliver its output? | Answered here; the choice is the report's | No: `NSCocoaErrorDomain 513` in both places tried. Standard output works (`knot export - > …`, or a stream that `tar` unpacks), and so does a folder in the group container that the tool names and the user copies from. |
| Where does the Mac store live? | Answered here for development; needs the check and the owner for shipping | In the group container. In a development build that is `~/Library/Group Containers/<team>.com.p3ob7o.knot.dev/`. Which form the milestone builds use waits for the distribution-signed check and the owner's decision. |
| The Mac's app-group form | Needs the distribution-signed check, then the owner | Development builds can use only the Team-ID form. The `group.` form passes only an App Store or TestFlight signature, by the system's own log. A DTS answer on Apple's forums, read through a search summary, says there is no way to move a group's content to another group, so the form the M4 milestone build ships is kept. |

## What the runs showed

The checks run from `Spikes/SP-3/run.sh checks tool|app`, each under a time limit, with the system log read after each run for a consent prompt and the gate's locally signed `knot-dev --version` started after each first start. The tool's commands are `probe`, `add`, `export`, `export-group`, `mcp` and `cleanup`; the app's headless `--self-test` opens no window and takes no focus.

| Check | Result |
|---|---|
| Bare tool, team-signed, no profile, `--version` | Starts at once. |
| `probe`, `group.` form | containermanagerd: "Signature insufficient for strict scrutiny" for `platform binary`, `MAS`, `profile validated entitlements`, `iPad app` and `TestFlight`, then "REJECTED. Requestor's signature does not allow it to access a TCC-protected group container. Group containers identifiers should be prefixed by requestor's team ID to allow access on this platform." No prompt. Writing there fails with 513. |
| `probe` and `add`, Team-ID form | "APPROVED". The store opens in WAL mode, the write commits, `notify_post` succeeds. |
| `export <folder>`, under the temporary folder and under the home folder | 513 in both. |
| `export - > file` | The shell writes the file. |
| `export-group` | The file lands in the group container. |
| A symbolic link on PATH, called by name and by absolute path | Sandboxed, its own container, the store opens; `Bundle.main` has no Info.plist: no bundle ID, no version. |
| A shell script on PATH that `exec`s the real path | `Bundle.main` reads the embedded Info.plist. |
| A copy of the binary outside the bundle | Runs as the same identity, with its Info.plist. |
| A stand-in MCP client from a shell: `knot-dev mcp` over pipes, a second writer while the session is open, then end of input | The session reads 1, then 2 after the other process wrote, writes 3, and the tool exits 0 at end of input. |
| The helper bundle, from Terminal | As the bare tool, with and without the wildcard profile. |
| No Info.plist in the binary, from Terminal | Traps: "Unable to get bundle identifier for container id com.p3ob7o.knot.dev.cli: Unable to get bundle identifier because Info.plist from code signature information has no value for kCFBundleIdentifierKey." |
| Only `inherit`, from Terminal | Traps: "Process is not in an inherited sandbox." |
| The app, `--self-test --team-group`, the tool writing while it runs | The app sees the write "by notification". Its `probe` in the `group.` form fails with 513. |
| The app starts each packaging, as a sandboxed MCP client would | The bare tool, the helper and the no-Info.plist tool trap in `_libsecinit_appsandbox`. The `inherit` tool runs inside the app's container, with the app's groups, and its own identity has to be allowed into the app's data container. |

## Two signers of one identifier

The gate builds the Mac app and its tool with local, ad hoc signing under the same development identifiers, and the containers it made came first. Each data container keeps a list of the signers allowed in. The first start of a team-signed build logged, from secinitd, "binary identity <<team>/com.p3ob7o.knot.dev.cli; signer:development> not in ACL for container ~/Library/Containers/com.p3ob7o.knot.dev.cli/Data <[{"validationCategory":"none","signingIdentifier":"com.p3ob7o.knot.dev.cli"}]>; prompting", and a dialog came up. Until it was answered, every start of that identifier hung at sandbox setup, the gate's locally signed `knot-dev --version` among them, while other sandboxed processes started normally. The owner allowed it, then two more at his sitting: the app's container for the team-signed app, and the app's container for the tool's identity, which the app had spawned. Since then both builds start under their identifiers: the gate's locally signed `knot-dev --version` starts, and the locally signed app shows its window when started as the `launch` step starts it.

So the two flavours of signing live on one Mac, at the cost of one dialog per new signer of each container, which only the owner answers. A test or a gate that starts a sandboxed build needs a time limit, because a dialog makes the start wait without end.

## Shipping Mac App Store apps

Read from the bundles installed on the build Mac and from public pages; neither app was run.

| App | Tool | Packaging | Delivery |
|---|---|---|---|
| Day One 2026.23 | `Contents/MacOS/dayone`, a CLI | Bare executable, identifier `com.bloombuilt.dayone.cli`, its own `app-sandbox`, an Info.plist in its binary, app groups in the Team-ID form only, signed by Apple Mac OS Application Signing, no profile | Its public guide has the user run an install script with `sudo`, which writes `/usr/local/bin/dayone`. The CLI finds the app through `DAYONE_APP_PATH`. |
| DetailsPro 6.20.0 | `Contents/MacOS/detailspro-mcp`, an MCP server | Bare executable, identifier `app.funfocus.DetailsPro.mcp`, its own `app-sandbox`, an Info.plist in its binary, a `group.` app group and `network.client`, signed by Apple, no profile | The app shows an MCP client configuration with the absolute path into its bundle, and `claude mcp add` and `codex mcp add` lines. The server bridges to the running app over loopback port 13777 and says the app must be running. |

Day One is the direct route with the Team-ID form. DetailsPro is a bare `group.` tool that passes review, but it reaches its data through the running app over the network, which Knot does not use.

## The distribution-signed check, prepared

Not run: it needs the owner's word and an App Store Connect key. What the owner hands over, at G1:

- The App Store Connect record for the development identifier, `com.p3ob7o.knot.dev`, on macOS.
- An API key with the right to manage profiles, as a file path through the secret prompt, with its key ID and issuer ID, for one upload, revoked after it.
- His word for the upload.

The key lets Xcode make the explicit App IDs `com.p3ob7o.knot.dev` and `com.p3ob7o.knot.dev.cli` with App Groups, and their distribution profiles. On this Mac, development builds got only the wildcard team profile, which authorises no group, whatever the project asked.

Before the upload, the report half drops the two counter-examples, `knot-dev-noplist` and `knot-dev-inherit`, from the app it uploads: each traps at launch by design. Then, from the worktree, with `KNOT_AGENT=1` and `KNOT_LOCAL_CONFIG` exported:

```sh
scripts/bootstrap.sh
Spikes/SP-3/run.sh build --profiles        # generates the project; a development build
xcodebuild -project Spikes/SP-3/SP3.xcodeproj -scheme SP3 -configuration Release \
  -destination 'generic/platform=macOS' -archivePath .build/sp3/SP3.xcarchive \
  KNOT_SIGNING=team REGISTER_APP_GROUPS=YES KNOT_BUILD_NUMBER=<n> \
  -allowProvisioningUpdates -authenticationKeyPath <key.p8> \
  -authenticationKeyID <key ID> -authenticationKeyIssuerID <issuer ID> archive
xcodebuild -exportArchive -archivePath .build/sp3/SP3.xcarchive -exportPath .build/sp3/export \
  -exportOptionsPlist <options made at run time, outside the repository> \
  -allowProvisioningUpdates -authenticationKeyPath <key.p8> \
  -authenticationKeyID <key ID> -authenticationKeyIssuerID <issuer ID>
```

The export options name the method `app-store-connect`, the destination `upload` and the team, read from the build settings at run time, so that no team ID is written down. Build output goes to a file and is filtered before anything is quoted.

**Where to run it.** Not on the build Mac. The upload reuses `com.p3ob7o.knot.dev` and `com.p3ob7o.knot.dev.cli`, whose data containers there list only the local and the development signers, so the TestFlight build is a new signer and its first start raises the same "not in ACL" dialog, for a reason that has nothing to do with the group. The owner runs the check on a Mac, or in a user account, where no Knot Dev build has ever run. There no signer's dialog is expected, and any dialog is the group's.

**Telling the two apart, if a dialog does come.** The system log says which it is. Right after the dialog, in Terminal:

```sh
/usr/bin/log show --last 5m --style compact --predicate \
  '(process == "secinitd" AND eventMessage CONTAINS "prompting") OR (process == "containermanagerd" AND eventMessage CONTAINS "knot.dev") OR (process == "tccd" AND eventMessage CONTAINS "knot.dev")'
```

A secinitd line "… not in ACL for container ~/Library/Containers/com.p3ob7o.knot.dev…/Data …; prompting" is a signer's dialog: he allows it, and it does not fail the check. A line about the group container, a containermanagerd "REJECTED" or a tccd request naming `knot.dev`, is the group's, and it fails the check for that form. The lines carry the team's ID: they are read, not pasted into a note.

At G3 the owner installs the build from TestFlight and opens Knot Dev once. Its window probes both forms of the group on each refresh, one line each, "group. form: store …, counter n (moved)" and "team form: …", because both forms post the same notification and a window that read one form would refresh with a counter that did not move after an add in the other. He runs in Terminal the lines the window lists:

```sh
"/Applications/Knot Dev.app/Contents/MacOS/knot-dev" probe
"/Applications/Knot Dev.app/Contents/MacOS/knot-dev" add synthetic
"/Applications/Knot Dev.app/Contents/MacOS/knot-dev" probe --team-group
"/Applications/Knot Dev.app/Contents/MacOS/knot-dev" add synthetic --team-group
"/Applications/Knot Dev.app/Contents/Helpers/knot-dev.app/Contents/MacOS/knot-dev" probe
"/Applications/Knot Dev.app/Contents/MacOS/knot-dev" cleanup
"/Applications/Knot Dev.app/Contents/MacOS/knot-dev" cleanup --team-group
```

He notes any dialog and its text. The check passes for a form when `probe` in that form says `"store":"opened"`, `add` in that form raises its counter, and the window's line for that form reads "moved", with no group's dialog. TestFlight on macOS 15.1 or later is one of the signatures the log names, so the `group.` form is expected to pass there; a development build cannot show it.

## Declarations read

No OS 26 or OS 27 API is used. In the MacOSX 27.2 SDK: `Security/SecTask.h` (`SecTaskCreateFromSelf`, `SecTaskCopyValueForEntitlement`, which the tool uses to read its own groups) and `usr/include/notify.h` with its module map (`notify_post`, `notify_register_dispatch`, `notify_cancel`, from the module `notify`). Pages: Apple's developer forum thread "App Groups: macOS vs iOS: Working Towards Harmony" and the threads that cite it, read through a search summary because the pages render with JavaScript; Day One's guide to its command line.

## Changes this asks of the architecture

docs/architecture.md is the orchestrator's file, so this note does not edit it. The report may add to these after the distribution-signed check.

1. **§15, CLI and MCP, and Identifiers.xcconfig.** Development builds of the Mac app and the tool use the Team-ID form of the group, `$(TeamIdentifierPrefix)com.p3ob7o.knot.dev`: the `group.` form is refused to every development signature, so the gate's development-signed step (the tool writes, the app shows it) can only pass with the Team-ID form. The milestone form waits for the check and the owner.
2. **§15, packaging.** The two rules are confirmed, with the system's messages. Add: the tool reads its flavour and version from something that survives a symbolic link, such as a value compiled in, or a shim that `exec`s the real path. Through a link, WP-01's `knot` reads no Info.plist, takes the default flavour `dev`, and so would not refuse an agent the milestone tool.
3. **§15 and product spec §10, MCP.** Clients that are sandboxed apps cannot start the tool. The settings text and docs/cli.md say so, and give the absolute path for MCP clients.
4. **Product spec §10 and §11, the PATH.** Command-line access in Settings installs a shell script that `exec`s the tool, not a symbolic link, in a folder the user picks or by a line the user runs. Which of the two is WP-34's, with the owner.
5. **Product spec §10, `knot export <folder>`.** The tool cannot write to the folder. The command writes to standard output, as an archive or one stream, or into a folder in the group container that it names; the report chooses.
6. **§7 and §18, two signers.** A team-signed build of a development identifier on the build Mac needs one consent dialog per new signer of each container, answered by the owner, and blocks every start of that identifier while the dialog waits. Every start of a sandboxed build in `scripts/verify.sh` gets a time limit: the packaging step runs `knot-dev --version` with none.
7. **§20, new rows.**
   - A development-signed process is refused a `group.` app group without a prompt; the log names platform binary, Mac App Store, profile-validated entitlements, iPad app and TestFlight as the signatures that pass. The Team-ID form is approved with no profile (build Mac, 2026-11-20).
   - A sandboxed command-line tool cannot write to a folder passed as an argument: confirmed, 513 (build Mac). This replaces the row "Expected from the sandbox rules. SP-3 confirms."
   - A tool with its own sandbox traps in sandbox setup when a sandboxed app starts it; an `inherit` tool runs in its parent's container (build Mac).
   - Through a symbolic link, `Bundle.main` of a bare executable finds no Info.plist (build Mac).
   - A data container keeps a list of allowed signers; a new signer raises a dialog, and every start of that identifier waits for it (build Mac).
   - Xcode 27.2 signs a Mac development build that claims an app group with the wildcard team profile, which authorises no group, even with `REGISTER_APP_GROUPS=YES` and the capability in the project (build Mac).

## Not verified yet

- The distribution-signed check: both forms of the group in a TestFlight build, and whether App Store Connect accepts the upload with the tool and the helper.
- A profile that authorises the `group.` group in a development build, which needs an explicit App ID.
- The in-app route to PATH through an open panel, which needs a window and the owner.
- A store in the group container under the app's own `KnotStore/` layout and `fullfsync`, with WP-10's real store; the spike used a synthetic store with the same settings.
- `knot export -` as an archive: the spike streamed one Markdown file.
