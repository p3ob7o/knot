# Setting up to build Knot

This page lists what a Mac needs to build and test Knot, with the version of each prerequisite and the command that installs it. `scripts/bootstrap.sh` checks all of them and stops at the first one missing, with its command.

## Prerequisites

| What | Version | How to install it |
|---|---|---|
| macOS | 27 | Software Update. |
| Xcode | The release Xcode 27 that `.xcode-version` pins | Install it from Apple's developer downloads beside any beta, at `/Applications/Xcode.app` or another `/Applications/Xcode*.app`. Then run it once, or run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -runFirstLaunch`. |
| iOS simulator runtime | The one that matches the pinned Xcode's iOS SDK | `DEVELOPER_DIR=<that Xcode>/Contents/Developer xcodebuild -downloadPlatform iOS` |
| watchOS simulator runtime | The one that matches the pinned Xcode's watchOS SDK | `DEVELOPER_DIR=<that Xcode>/Contents/Developer xcodebuild -downloadPlatform watchOS` |
| XcodeGen | 2.47.0 | `brew install xcodegen`, if Homebrew's version is 2.47.0. Otherwise download `xcodegen.zip` from the [2.47.0 release](https://github.com/yonaskolb/XcodeGen/releases/tag/2.47.0), check its SHA-256 against `6ef12a3ef5327c2c713397f46d9160550f8b1cdc5c925cd884d65c77c9f696cd`, and put `xcodegen/bin` on your `PATH`. |
| python3 and git | The ones that come with Xcode | `xcode-select --install` installs the command-line tools. Do not point `xcode-select` at an Xcode: the scripts choose the Xcode themselves. |

GRDB, the one third-party library, comes through Swift Package Manager. Its version and its revision are pinned in `Packages/KnotKit/Package.swift`, and `scripts/verify.sh` checks both.

## The Xcode

`.xcode-version` names the Xcode for the merge gate and the archive, by version and build. Every script sets `DEVELOPER_DIR` from it for each command and checks `xcodebuild -version` against it. Nobody changes `xcode-select`, because other projects on the same Mac keep their own toolchain.

- To pin a newly installed release Xcode: `scripts/bootstrap.sh --pin-xcode /Applications/Xcode.app`. It refuses a beta.
- To use another Xcode, such as the beta, name it: `KNOT_XCODE=/Applications/Xcode-beta.app scripts/verify.sh --quick`. The summary line then says that the run did not use the pinned Xcode.
- After pinning, `scripts/sdk-facts.sh` checks the rows of `docs/architecture.md` §20 marked "SDK" against the new SDK.
- `scripts/sdk-path.sh <platform> <framework>` prints where a framework's Swift interfaces are, for reading a declaration before using an OS 26 or OS 27 API (`docs/architecture.md` §21).

Until the owner installs the release Xcode at gate G1, `.xcode-version` reads `pending` and every script asks for `KNOT_XCODE`.

## First build

```sh
export KNOT_AGENT=1          # in an agent's thread only
scripts/bootstrap.sh         # prerequisites, configuration, Knot.xcodeproj, packages, simulators, fixtures' audio
scripts/verify.sh --quick    # the plan, the fixtures, formatting, the pins, the package, its tests, the self-test
```

`scripts/bootstrap.sh --first-test` also runs the first module test and prints how long the fresh worktree took to reach it. The aim is 5 minutes, and 3 minutes for a warm `--quick`.

`Knot.xcodeproj` is generated from `project.yml` and is not committed. Run `scripts/bootstrap.sh` again after changing `project.yml` or a target's YAML file, and never edit the generated project.

## What a worktree keeps to itself

- Build products, logs, package checkouts and DerivedData in its own `.build/`, which git ignores.
- An ID: the worktree's folder name and the first six characters of the SHA-256 of its root path, as in `wp-01-tooling-1a2b3c`. Two clones in folders of the same name get different IDs, so they never share simulators or a store.
- Three simulators named by that ID: `<ID>-iphone`, `<ID>-ipad` and `<ID>-watch`, on the runtimes that match the pinned SDK. `scripts/sim.sh` creates, lists, boots, shuts down and deletes them, and never touches another project's simulators. It makes a simulator again when it sits on another runtime, shutting it down first, and deletes one of the same name that its runtime's removal left unavailable. An Xcode named by `KNOT_XCODE` gets a set of its own, `<ID>-xcode27.3-iphone` and so on, so that alternating the two Xcodes does not make the usual set again each time. `KNOT_SIM_IOS_VERSION=27.0` asks for a set on another runtime, as the nightly run does.
- On the Mac, a development store folder named by the ID, inside the development container. The ID reaches the app through `.build/config/Worktree.xcconfig` and the `KnotDevStoreFolder` key of the Info.plist.

`scripts/worktree-remove.sh <folder>` removes a worktree with its simulators and its development store folder.

Simulators named the old way, by a folder's name alone, as in `knot-iphone`, are never deleted by a script: the name cannot tell which checkout made it, and another checkout in a folder of the same name may still use it. `scripts/sim.sh ensure`, `scripts/sim.sh delete` and `scripts/worktree-remove.sh` list them with their UDIDs, for a person to delete with `xcrun simctl delete <UDID>`.

Keep the repository, its worktrees, the build folder (`~/knot-build`, or `KNOT_BUILD_FOLDER`) and the fixtures folder (`KNOT_LOCAL_FIXTURES`) out of any folder that a cloud file provider syncs, such as `~/Documents` or `~/Desktop` with iCloud Drive on. `scripts/doctor.sh` refuses them there.

## Build flavours and signing

| | Development build | Milestone build |
|---|---|---|
| Who makes it | Every agent build, PR build, spike and test | Only the orchestrator, at a milestone, with the owner's go-ahead |
| Bundle ID | `com.p3ob7o.knot.dev`, and `.widgets`, `.watchkitapp`, `.watchkitapp.widgets`, `.cli` | `com.p3ob7o.knot`, with the same suffixes |
| App group | `group.com.p3ob7o.knot.dev` | `group.com.p3ob7o.knot` |
| iCloud container | `iCloud.com.p3ob7o.knot.dev` | `iCloud.com.p3ob7o.knot` |
| Mac tool | `knot-dev` | `knot` |
| Name on the device | Knot Dev | Knot |
| Build settings | `KNOT_FLAVOUR=dev`, the default | `KNOT_FLAVOUR=milestone KNOT_MILESTONE_LEVEL=M1 … M7 KNOT_SIGNING=team` |

The identifiers are constants in `Apps/Config/Identifiers.xcconfig`. The Mac's app-group form stays open until SP-3 reports. A milestone build carries a version above 0.2.0, the retired app's, and a build phase refuses one whose level, signing or version does not agree. A feature whose milestone has not passed is switched off by a gate that reads the level from the Info.plist: sync and the command line open at M4, and ink at M5.

Signing has two configurations, chosen by `KNOT_SIGNING`:

- `local`, for tests and agent builds. It keeps the sandbox, signs ad hoc, and leaves out the entitlements that need the owner's signing profile: the app group, iCloud and push. Sync is off (`KnotSyncAvailable` is `NO`). `scripts/verify.sh` always builds with it.
- `team`, for device builds, spikes and milestone builds. It needs a team ID, which never enters the repository. Copy `Apps/Config/Local.xcconfig.example` to a file outside the repository, for the owner `~/knot-build/Local.xcconfig`, fill in the team, and set `KNOT_LOCAL_CONFIG` to its path. `scripts/bootstrap.sh` links it into `.build/config/Local.xcconfig`.

## The fakes in an optimised build

KnotFakes, which holds the fakes and the preview environment, and KnotUIPreviews compile only under `DEBUG` or `KNOT_FAKES`: every file of both sits inside `#if DEBUG || KNOT_FAKES`. Xcode links a package product into every configuration of an app, so without that guard a release app would carry the fakes. `scripts/verify.sh --only packaging` fails when a Release binary holds a KnotFakes symbol.

An optimised build that needs the fakes, such as `scripts/verify.sh --perf` or an optimised soak child, opts in by defining `KNOT_FAKES`:

```sh
swift build -c release --package-path Packages/KnotKit -Xswiftc -DKNOT_FAKES
```

With `xcodebuild`, pass `OTHER_SWIFT_FLAGS='$(inherited) -DKNOT_FAKES'`. No build that ships defines it.

## The tiers of `scripts/verify.sh`

One run takes one tier. Each run starts with `scripts/doctor.sh`, and ends with one summary line and a status line.

| Command | Runs |
|---|---|
| `scripts/verify.sh --quick` | doctor, the plan check, the fixtures check, formatting, the pins, the package build and its tests, the contract-suite proof and the scripts' self-test. The check before a pull request. |
| `scripts/verify.sh --full` | Everything: also the link check, the lint, ownership, KnotCore's API, the named tests, every app, the packaging proofs, the tests hosted in the iOS app, the launches and the Mac UI tests. `--skip mac-ui` leaves the Mac UI tests out, for an implementer whose Mac cannot run them. |
| `scripts/verify.sh --gate` | The merge gate, on the orchestrator's Mac. Its depth comes from the diff against `--base` (`origin/main` by default), by the table of `docs/architecture.md` §18, and `scripts/gate-steps.txt` lists its steps and which are pending. It runs on a detached head, so the orchestrator names the package with `--package WP-10` or the branch with `--branch wp/10-store`. It builds with the pinned Xcode only, requires the on-device models and fails on a skipped test, and refuses `--only`, `--module`, `--skip` and a `KNOT_XCODE` that names another Xcode. |
| `scripts/verify.sh --soak [--seed <n>]` | The capture ledger soak, whose step WP-06 builds. A failure prints its seed. |
| `scripts/verify.sh --perf` | The timed targets of `docs/product-spec.md` §14, on an optimised build with the fakes (`-DKNOT_FAKES`), holding every build slot. WP-42 adds the measured tests. |
| `scripts/verify.sh --only <step>` | Doctor, then one step. `scripts/verify.sh --help` lists the steps. |
| `scripts/verify.sh --module <name>` | Doctor, then the package build and the tests of one module, such as `KnotStore`, or of one test target, such as `KnotSoak`. It fails when no test ran. |

A failed step names its log in `.build/logs/` and the command that reruns only that step.

**Which scripts drive the gate.** The scripts that drive the gate come from `main`, not from the candidate (`docs/architecture.md` §18). Every script reads the code, the plan, the fixtures and the pinned Xcode from the tree that `KNOT_TREE` or `--tree` names, and its own helpers and the orchestrator's lists from the checkout it runs from. So the orchestrator, with the candidate checked out in its gate worktree, runs main's scripts on it:

```sh
KNOT_TREE=<gate worktree> ~/knot/scripts/bootstrap.sh
~/knot/scripts/verify.sh --gate --tree <gate worktree> --branch wp/10-store
~/knot/scripts/verify.sh --tree <gate worktree> --status-line
```

The build products, the logs and the status line go to the tree's own `.build/`. A pull request that changes `scripts/` is the stated exception: the orchestrator then runs the candidate's own scripts, `<gate worktree>/scripts/verify.sh --gate --branch …`, and says so in the journal. The gate prints which scripts checked which tree, by commit.

**The status line.** GitHub cuts a commit status's description at 140 characters, and the summary line is longer. So every run also writes a status line of at most 140 characters, such as `gate everything ok: 18/18 steps, 27 tests, 1 pending · 9m12s · Xcode 27.2 27B52 · macOS 26C5047e`, to `.build/logs/verify-status.txt`. `scripts/verify.sh --status-line` prints the last one, for the orchestrator to post as `knot/gate`. A `*` after the Xcode means it was named by `KNOT_XCODE`.

**Build slots.** A heavy step waits for a build slot (`scripts/build-slot.sh`): three on this Mac, one of them kept for the gate, an exclusive one for the Mac UI tests, and two for booted simulator sets. A slot is a `lockf` lock, so a killed build frees it at once. A waiting run prints the holders each minute. `scripts/build-slot.sh status` shows who holds what. `KNOT_SLOT_DIR`, `KNOT_BUILD_SLOTS`, `KNOT_SIMULATOR_SLOTS` and `KNOT_SLOT_TIMEOUT` change the defaults.

**The nightly run.** `scripts/nightly.sh`, on a checkout of `main`, runs `--full`, the package tests under Thread Sanitizer, the soak with a fresh seed, the launches on the iOS 27.0 runtime, and a report of models that changed with an update of the system. `.github/workflows/nightly.yml` runs the Thread Sanitizer part on a hosted runner too.

**What the lint catches, and what it does not.** A pass of the lint is not proof that Knot logs no note text and reaches no host. It reads the Swift sources line by line, joining a call that runs over several lines, and it catches:

- a log call, on any receiver, with an interpolated value that states no `privacy:`, checked for each value; `os_log` and `NSLog`; `print`, `debugPrint` and `dump`, `Swift.print` among them, anywhere but the command-line executables;
- `privacy: .public` on a value that is not named as an ID, a count, a code, a duration or a state. The lint knows an ID by its name: one component of the expression must be such a name, as in `captureID`, `note.id` or `elapsed`, and every component after it must only format it, as `uuidString`, `description` or `formatted()` do. So `\(note.id.uuidString, privacy: .public)` and `\(elapsed.formatted(), privacy: .public)` pass, and `\(note.text, privacy: .public)` does not;
- `UserDefaults.standard`, `UserDefaults()`, a `UserDefaults` or `UserDefaults?` set to `.standard`, `@AppStorage(…, store: .standard)` and `.defaultAppStorage(.standard)`; `@AppStorage` without a store; an autosave name without `v1.`;
- `URLSession`, `URLRequest`, the `NW` connection, listener, browser and endpoint types, `CFStream`, `CFSocket` and any `http://` or `https://` in code;
- `eraseDatabaseOnSchemaChange`; a concurrency escape beyond `scripts/concurrency-escapes.txt`;
- a required-reason API, among them the file-timestamp resource keys, `stat`, `fstat`, `lstat`, `fstatat`, the `getattrlist` family and the `statfs` family, without its reason in the manifest of each target that links it;
- a file or folder whose name ends in " 2".

It cannot know what a value holds. A value named `noteID` that holds text passes, so does a value logged through a helper of our own, and so does a host reached through an API it does not name. The review reads for those. A comment `knot-lint: allow network` or `knot-lint: allow logged-text` on a line, followed by the reason, lets that line pass, as for a sink that logs a finished line as public by design. The review checks each one. `scripts/lint-cases/Cases.swift` holds a case for each rule and three lines that must pass, and the self-test fails when the lint misses a case or flags one of those lines. It judges the fixture against a privacy manifest of its own, so the result does not change when a package adds a reason to a real manifest.

**A tool that does not answer.** The packaging step starts the `knot-dev` that it built, with a limit of 30 seconds (`KNOT_TOOL_START_LIMIT`). A system dialog, such as a consent prompt, can hold every start of a new tool; then the step ends the tool, with KILL two seconds after TERM if it must, fails, and says in its log that a dialog may be waiting for the owner on this Mac. No agent answers such a dialog.

**The team's ID in build logs.** On a Mac whose Xcode knows the owner's team, every app build writes the team's prefix into its log, whatever the signing: `TeamIdentifierPrefix`, `AppIdentifierPrefix` and the entitlements it prints, such as `application-identifier`. So `scripts/verify.sh` filters every log it keeps, and everything it prints from them, through `knot_filter_team` in `scripts/lib/common.sh`, and at the start of each run it rewrites the logs that earlier runs left in `.build/logs`. The filter knows no ID: it masks ten capitals and digits where those keys, `DEVELOPMENT_TEAM` or an identifier such as `<ID>.com.…` put them, as `<TEAM>`. Xcode's own logs in DerivedData keep the prefix; the scripts never print them, and nothing from a build log goes into a note, a commit or a pull request unfiltered.

## The other scripts

| Command | Does |
|---|---|
| `scripts/install.sh <Knot.app>` | Installs an iOS build on every paired iPhone and iPad, and its Watch app on every paired Watch, with `devicectl`. It skips a device that holds the build already, names every device it could not reach, and exits non-zero when it missed one. `--device <name>` picks devices. |
| `scripts/install.sh <Knot.app> --mac-folder <folder>` | Copies a Mac build to a folder the owner names. He opens it there. From the M4 milestone build on, no milestone build runs on the build Mac. |
| `scripts/status.sh [--write]` | Prints the status table from the briefs, GitHub and the build folder's `threads.tsv`. `--write` writes `docs/status.md`, which goes to `main` only at milestones. |
| `scripts/worktree-remove.sh <folder> [--force]` | Removes a worktree with its simulators and its development store folder. |
| `scripts/self-test.sh` | The scripts' self-test, which `--quick` runs. |
| `scripts/sdk-facts.sh` | Checks the rows of `docs/architecture.md` §20 marked "SDK" against the pinned SDK. |

## What the owner does once, at gate G1

- Install the release Xcode 27 beside the beta, and pin it: `scripts/bootstrap.sh --pin-xcode /Applications/Xcode.app`.
- Install the watchOS and iOS simulator runtimes for that Xcode, with the two commands above.
- Enable Automation Mode and developer mode, which Mac UI tests need. Without them, Mac UI tests wait on a password dialog that no agent can answer. `scripts/doctor.sh` prints the commands:

  ```sh
  sudo automationmodetool enable-automationmode-without-authentication
  sudo DevToolsSecurity -enable
  ```

- Set up signing so that `scripts/doctor.sh --require-signing` passes: the gate's development-signed step must sign without a prompt.
- Confirm the identifiers in the table above, pair the devices for development builds, and register the other Mac.

## Continuous integration

GitHub offers a hosted runner with Xcode 27: the `xcode-27` image, a preview on 2026-11-19, carries the release Xcode 27.0, 27.1 and 27.2. `.github/workflows/verify.yml` runs `scripts/verify.sh --quick` there on every pull request and every push to `main`. It passes only once `.xcode-version` pins a release Xcode that the image carries.

The repository gets no self-hosted runner, because it is public. Its workflows hold no secrets, never use `pull_request_target`, have read-only permissions and pin their actions by revision. The merge gate itself, `scripts/verify.sh --gate`, runs on the orchestrator's Mac.
