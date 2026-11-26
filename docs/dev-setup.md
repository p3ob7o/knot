# Setting up to build Knot

This page lists what a Mac needs to build and test Knot, with the version of each prerequisite and the command that installs it. `scripts/bootstrap.sh` checks all of them and stops at the first one missing, with its command.

## Prerequisites

| What | Version | How to install it |
|---|---|---|
| macOS | 27 | Software Update. |
| Xcode | The release Xcode 27 that `.xcode-version` pins | Install it from Apple's developer downloads beside any beta, at `/Applications/Xcode.app` or another `/Applications/Xcode*.app`. Then run it once, or run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -runFirstLaunch`. |
| iOS simulator runtime | The one that matches the pinned Xcode's iOS SDK | `DEVELOPER_DIR=<that Xcode>/Contents/Developer xcodebuild -downloadPlatform iOS` |
| watchOS simulator runtime | The one that matches the pinned Xcode's watchOS SDK | `DEVELOPER_DIR=<that Xcode>/Contents/Developer xcodebuild -downloadPlatform watchOS` |
| XcodeGen | 2.47.0 | Download `xcodegen.zip` from the [2.47.0 release](https://github.com/yonaskolb/XcodeGen/releases/tag/2.47.0), check its SHA-256 against `6ef12a3ef5327c2c713397f46d9160550f8b1cdc5c925cd884d65c77c9f696cd`, and unpack it, as the zip unpacks, into `tools/xcodegen-2.47.0/` under the build folder. The scripts find it there: see [XcodeGen](#xcodegen) below. |
| python3 and git | The ones that come with Xcode | `xcode-select --install` installs the command-line tools. Do not point `xcode-select` at an Xcode: the scripts choose the Xcode themselves. |

GRDB, the one third-party library, comes through Swift Package Manager. Its version and its revision are pinned in `Packages/KnotKit/Package.swift`, and `scripts/verify.sh` checks both.

## The Xcode

`.xcode-version` names the Xcode for the merge gate and the archive, by version and build. Every script sets `DEVELOPER_DIR` from it for each command and checks `xcodebuild -version` against it. Nobody changes `xcode-select`, because other projects on the same Mac keep their own toolchain.

- To pin a newly installed release Xcode: `scripts/bootstrap.sh --pin-xcode /Applications/Xcode.app`. It refuses a beta.
- To use another Xcode, such as the beta, name it: `KNOT_XCODE=/Applications/Xcode-beta.app scripts/verify.sh --quick`. The summary line then says that the run did not use the pinned Xcode.
- After pinning, `scripts/sdk-facts.sh` checks the rows of `docs/architecture.md` §20 marked "SDK" against the new SDK.
- `scripts/sdk-path.sh <platform> <framework>` prints where a framework's declarations are, for reading one before using an OS 26 or OS 27 API (`docs/architecture.md` §21): its headers, and then its Swift module, each that exists. Read both: XCUIAutomation declares `XCUIApplication` in its headers, and SwiftUI nearly everything in its module. It looks in the SDK, then in the platform's own `Developer/Library/Frameworks`, where XCUIAutomation, which UI tests import, and XCTest are.

Until the owner installs the release Xcode at gate G1, `.xcode-version` reads `pending` and every script asks for `KNOT_XCODE`.

## XcodeGen

The scripts choose their XcodeGen as they choose their Xcode, so a machine-wide upgrade cannot change it under a run. `knot_resolve_xcodegen` in `scripts/lib/common.sh` settles on one binary, in this order:

1. `KNOT_XCODEGEN`, a path to the binary, for a copy kept elsewhere;
2. the pinned release under the build folder, `tools/xcodegen-<version>/xcodegen/bin/xcodegen`;
3. `xcodegen` on `PATH`.

The way on any Mac is the second: the release, checked against the checksum in the table above, unpacked under the build folder's `tools/` with its `share/` beside `bin/`. Homebrew's copy serves only when there is no pinned copy and its version is the pinned one. Nobody relinks, pins or installs anything in Homebrew for the project: Homebrew on the build Mac is the owner's, and other projects keep their own tools.

`scripts/doctor.sh` and `scripts/bootstrap.sh` say which of the three they chose. `knot_generate_project` checks the chosen binary's version again just before it generates. A tool that changed during a run fails the step with `infra-xcodegen-version` and generates nothing. A missing copy fails with `infra-xcodegen-missing`, and the scripts download nothing.

The hosted workflows install XcodeGen the same way, from the release with its checksum, and put its `bin` on `PATH`. A runner has no build folder, so the third choice serves there.

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
| Configuration | Debug, `project.yml`'s default | Release, made with `-configuration Release`, so that it holds no fakes and honours no debug-only launch argument |

The identifiers are constants in `Apps/Config/Identifiers.xcconfig`. The Mac's app-group form stays open until SP-3 reports. A milestone build carries a version above 0.2.0, the retired app's, and a build phase refuses one whose level, signing or version does not agree. A feature whose milestone has not passed is switched off by a gate that reads the level from the Info.plist: sync and the command line open at M4, and ink at M5.

Signing has two configurations, chosen by `KNOT_SIGNING`:

- `local`, for tests and agent builds. It keeps the sandbox, signs ad hoc, and leaves out the entitlements that need the owner's signing profile: the app group, iCloud and push. Sync is off (`KnotSyncAvailable` is `NO`). `scripts/verify.sh` always builds with it.
- `team`, for device builds, spikes and milestone builds. It needs a team ID, which never enters the repository. Copy `Apps/Config/Local.xcconfig.example` to a file outside the repository, for the owner `~/knot-build/Local.xcconfig`, fill in the team, and set `KNOT_LOCAL_CONFIG` to its path. `scripts/bootstrap.sh` links it into `.build/config/Local.xcconfig`, and removes that link when the variable is not set.

A build reads the team's configuration only through that link, which `Apps/Config/Base.xcconfig` includes when it is there: no other file of the build's settings names a team. So the worktree of a milestone build needs `KNOT_LOCAL_CONFIG` set when `scripts/bootstrap.sh` runs, as it was at the first milestone's commit, `c2a1315b`. `KNOT_TEAM_CONFIG` is read by the team-ID check alone and links nothing, so it gives a build no team.

## The fakes in an optimised build

KnotFakes, which holds the fakes and the preview environment, and KnotUIPreviews compile only under `DEBUG` or `KNOT_FAKES`: every file of both sits inside `#if DEBUG || KNOT_FAKES`. Xcode links a package product into every configuration of an app, so without that guard a release app would carry the fakes. A fake can also live in another module, such as a fake transport inside KnotLink. Such a fake has a name that begins with `Fake` and sits under the same guard: the lint fails a type named `Fake…` outside KnotFakes that is not under `#if DEBUG || KNOT_FAKES` (`fake-unguarded`). `scripts/verify.sh --only packaging` fails when a Release binary holds the KnotFakes module, or a type of one of Knot's modules whose name begins with `Fake`, found in its demangled symbols and strings: public or nested, private or fileprivate, local, or nested in an extension of a type from elsewhere. An optimised build can keep no symbol of a type at all, a private or local one above all, or keep only its bare name with no module, which the scan does not count; the lint is what catches a fake whose guard was lost.

An optimised build that needs the fakes, such as `scripts/verify.sh --perf` or an optimised soak child, opts in by defining `KNOT_FAKES`:

```sh
swift build -c release --package-path Packages/KnotKit -Xswiftc -DKNOT_FAKES
```

With `xcodebuild`, pass `OTHER_SWIFT_FLAGS='$(inherited) -DKNOT_FAKES'`. No build that ships defines it.

## The tiers of `scripts/verify.sh`

One run takes one tier. Each run starts with `scripts/doctor.sh`, and ends with one summary line and a status line.

| Command | Runs |
|---|---|
| `scripts/verify.sh --quick` | doctor, the plan check, the fixtures check, formatting, the pins, the package build and its tests, the contract-suite proof and the scripts' self-test. The check before a pull request. When the tree lacks its generated audio, as a fresh checkout and the hosted runner do, or the audio is stale because a clip's text, voice or format or the speech rate changed in `Fixtures/manifest.json`, the fixtures step speaks it first with `Fixtures/tools/generate.sh --audio` and stamps it (`Fixtures/generated/verify-stamp.txt`), so the package tests that read it find it. It holds a lock while it speaks, so two runs in one tree never speak at once. |
| `scripts/verify.sh --full` | Everything: also the link check, the lint, ownership, KnotCore's API, the named tests, the package's tests under the strict cooperative pool, every app, the packaging proofs, the tests hosted in the iOS app, the launches and the Mac UI tests. `--skip mac-ui` leaves the Mac UI tests out, for an implementer whose Mac cannot run them. The packaging proofs build the Mac app once at the milestone flavour, unsigned, under the development identifiers, so that a fault only that flavour has fails the gate; the product is unregistered from LaunchServices and removed after the check. No build but `scripts/milestone-build.sh` carries the milestone's identifiers. |
| `scripts/verify.sh --gate` | The merge gate, on the orchestrator's Mac. Its depth comes from the diff against `--base` (`origin/main` by default), by the table of `docs/architecture.md` §18, and `scripts/gate-steps.txt` lists its steps and which are pending. It runs on a detached head, so the orchestrator names the branch with `--branch wp/10-store`, which tells a note's pull request from a code one, and the package with `--package WP-10` when the branch does not name it. On a detached head the gate refuses to run without `--branch`. It builds with the pinned Xcode only, requires the on-device models and fails on a skipped or cancelled test, and refuses `--only`, `--module`, `--skip` and a `KNOT_XCODE` that names another Xcode. |
| `scripts/verify.sh --soak [--seed <n>]` | The capture ledger soak, whose step WP-06 builds. A failure prints its seed. |
| `scripts/verify.sh --perf` | The timed targets of `docs/product-spec.md` §14, on an optimised build with the fakes (`-DKNOT_FAKES`), compiled for testing (`-enable-testing`) and with `DEBUG` defined, since the tests import their modules with `@testable` and some use members a debug build alone declares, holding every build slot. WP-42 adds the measured tests. A step whose wait for a build slot runs out is NOT RUN, not failed, and the run ends with status 4. |
| `scripts/verify.sh --only <step>` | Doctor, then one step. `scripts/verify.sh --help` lists the steps. |
| `scripts/verify.sh --module <name>` | Doctor, then the package build and the tests of one module, such as `KnotStore`, or of one test target, such as `KnotSoak`. It fails when no test ran. |

A failed step names its log in `.build/logs/` and the command that reruns only that step. A whole run, a tier such as `--quick`, `--full` or the gate, first moves every file an earlier run left in `.build/logs/` to `.build/logs-earlier/`, which holds the run before and nothing older, so that after it every log in `.build/logs/` is its own. A run of one step, `--only` or `--module`, rewrites only the logs of the steps it starts; the others stay from the earlier runs and keep their own times. So a thread that reruns one step after a whole run, or runs the steps after a stop one by one, keeps the whole run's logs. A run scrubs the team's ID, at its end, only from the logs it wrote itself, so that a run of one step beside a whole run cannot cut that run's live log. One run at a time in a worktree is the rule all the same: two whole runs at once move each other's logs aside.

**Which scripts drive the gate.** The scripts that drive the gate come from `main`, not from the candidate (`docs/architecture.md` §18). Every script reads the code, the plan, the fixtures and the pinned Xcode from the tree that `KNOT_TREE` or `--tree` names, and its own helpers and the orchestrator's lists from the checkout it runs from. So the orchestrator, with the candidate checked out in its gate worktree, runs main's scripts on it:

```sh
KNOT_TREE=<gate worktree> ~/knot/scripts/bootstrap.sh
~/knot/scripts/verify.sh --gate --tree <gate worktree> --branch wp/10-store
~/knot/scripts/verify.sh --tree <gate worktree> --status-line
```

The build products, the logs and the status line go to the tree's own `.build/`. A pull request that changes `scripts/` is the stated exception: the orchestrator then runs the candidate's own scripts, `<gate worktree>/scripts/verify.sh --gate --branch …`, and says so in the journal. The gate prints which scripts checked which tree, by commit.

**A replay, and the tree a script inherits.** A script's tree comes from `KNOT_TREE` when the environment holds one, and every script exports its own, so that a step in its own process checks the same tree. A replay of a worktree's scripts therefore starts them through that worktree's own `scripts/build-slot.sh`, from inside it:

```sh
cd <worktree> && scripts/build-slot.sh run --label replay -- scripts/verify.sh --only package-test
```

Started through another checkout's `build-slot.sh`, the worktree's scripts would inherit that checkout's tree and build and test it, silently: on 2026-11-21 a replay ran 18 times on the main checkout, each `swift test --filter` matching nothing. So `scripts/lib/common.sh` refuses a `KNOT_TREE` that is still the tree another checkout's scripts exported (`knot-tree-inherited`). A tree that `--tree` names, or one named with `KNOT_TREE_NAMED=1` beside it, is taken as named. So is one that differs from what was exported. The exporting scripts' own children inherit it, as the gate's steps do.

**A trial of a scripts pull request on another head.** To see a pull request that changes `scripts/` run another package's gate before it merges, the orchestrator makes a base and a tree in scratch worktrees (docs/orchestrator.md). The base is the scripts pull request's head, merged with `main` whenever the other pull request's branch holds a newer `main` than the scripts pull request's does. The tree is the other head merged onto that base, never the scripts head merged into the other head, so that the base is an ancestor of the tree. The base's scripts then run with `--tree` at the tree and `--base` at the base:

```sh
git -C <base worktree> merge --no-edit origin/main    # only when the other branch holds a newer main
git -C <trial worktree> merge --no-edit <other head>  # the trial worktree checked out at the base
<base worktree>/scripts/verify.sh --gate --branch <other branch> --tree <trial worktree> --base <base head>
```

The tree then holds both changes, as the merge queue would. With `--base` at the base, the ownership step and the depth read the other package's change alone; against `origin/main` the scripts' files would count as the other package's, and ownership would fail on them. The depth follows that change too, so a step that only the scripts' change reaches, such as `mac-ui` for a change to `scripts/`, runs only if the other change reaches it as well. A trial on the other head merged with main alone does not test the scripts' change: the tree lacks the files that change with the scripts, and the steps that read the tree's own files would judge main's. The lint step is one: it reads the tree's `.github/workflows/nightly.yml` and requires the fixtures step before the tsan step in the same job, with no condition and no `continue-on-error` on either step or on the job (`knot_tool.py workflows`), so a scripts pull request that changes the workflow passes it only on a tree that holds that change. The scripts' self-test checks the scripts, and pins nothing of the real plan. Its checks of the gate's helper read a fixture plan of their own, since a documents pull request, which the documents depth gives no self-test, may change a brief's rows. Its plan check runs on a copy of the real plan, which the plan step holds to the same check at every depth. The files it reads itself, the plan, the fixtures' manifest, the pinned Xcode, the apps' manifests, `project.yml` and the nightly workflow, come from the checkout the scripts come from, whatever tree `--tree` names. Two of its cases run a script that reads the tree as every script does: the doctor's and `sdk-path.sh`'s, through `knot_select_xcode`, read the tree's `.xcode-version`.

**The status line.** GitHub cuts a commit status's description at 140 characters, and the summary line is longer. So every run also writes a status line of at most 140 characters, such as `gate everything ok: 18/18 steps, 27 tests, 1 pending · 9m12s · Xcode 27.2 27B52 · macOS 26C5047e`, to `.build/logs/verify-status.txt`. `scripts/verify.sh --status-line` prints the last one, for the orchestrator to post as `knot/gate`. A `*` after the Xcode means it was named by `KNOT_XCODE`.

**Build slots.** A heavy step waits for a build slot (`scripts/build-slot.sh`): three on this Mac, one of them kept for the gate, an exclusive one for the Mac UI tests, and two for booted simulator sets. A slot is a `lockf` lock, so a killed build frees it at once. A waiting run prints the holders each minute. `scripts/build-slot.sh status` shows who holds what. `KNOT_SLOT_DIR`, `KNOT_BUILD_SLOTS`, `KNOT_SIMULATOR_SLOTS` and `KNOT_SLOT_TIMEOUT` change the defaults. A script of another worktree, such as the replay of a pull request, is started with that worktree's own `scripts/build-slot.sh`, from inside it: `build-slot.sh` exports its own checkout's tree in `KNOT_TREE` to the command it runs, so through another checkout's it builds and tests that checkout, silently (docs/architecture.md §18). The launch step's Mac part, whose app has the bundle ID of every worktree's development build, takes the exclusive Mac UI slot for as long as the app is up, with `scripts/build-slot.sh run --mac-ui-only`, and no second build slot, since the step holds one. It builds the Debug Mac app before it starts it, so `--only launch` never starts an old one.

**The Mac app's saved window state.** A launch of the Mac app by a script or a test passes `-ApplePersistenceIgnoreState YES` first, before any flag that takes no value, such as `-KnotPreview`, after which AppKit does not see the pair. Every development build has one bundle ID, and so one saved window state (docs/architecture.md §18).

**The recorder in the iOS Simulator.** `recorder-sim` runs the recorder's kill test and its recording state shared by two processes in this worktree's iPhone simulator. A test there cannot start or kill a process, so the Mac drives it (docs/notes/WP-12.md). The step builds `KnotAudioCrashHost` for the Mac and for the iOS Simulator. It boots the iPhone simulator, and runs the Mac's crash host with `--runner "xcrun simctl spawn <udid>"` and the simulator's build as the child.
- **`state-check`** must print `state-check ok`.
- **`kill-test`** runs the trials of the Mac's named test, recording-format-kill-test: four live and early kills and three staged ones. It must print `summary trials 7 passed 7`, with a fresh seed that a failure prints. `scripts/verify.sh --only recorder-sim --seed <n>` repeats it.

The gate takes the step at every depth but documents where the diff reaches KnotAudio, its crash host, their tests or the package manifest (`RECORDER_SIM` in `scripts/lib/knot_tool.py`). The nightly run takes it with a fresh seed. On this Mac on 2026-11-22 it took 33 s once it had its slot: the two builds, a `state-check` of 3 s and a kill test of 13 s.

**The nightly run.** `scripts/nightly.sh`, on a checkout of `main`, runs `--full`, the package tests under Thread Sanitizer, the soak with a fresh seed, the launches on the iOS 27.0 runtime, the recorder's step in the iOS Simulator, a report of models that changed with an update of the system, and `--perf`. It keeps each run's logs in a folder of its own, `.build/nightly/<run>/`, cleared when the night starts. A run that did not run to its end for want of a build slot is reported as not run, apart from the failures. The night ends 0 only when every run ran and passed; 1 when any run failed; and 4, no verdict, when none failed and at least one did not run, its last line naming those, for the orchestrator to run again. `.github/workflows/nightly.yml` runs the Thread Sanitizer part on a hosted runner too.

**What the lint catches, and what it does not.** A pass of the lint is not proof that Knot logs no note text and reaches no host. It reads the Swift sources line by line, joining a call that runs over several lines, and it catches:

- a log call, on any receiver, with an interpolated value that states no `privacy:`, checked for each value; `os_log` and `NSLog`; `print`, `debugPrint` and `dump`, `Swift.print` among them, anywhere but the command-line executables;
- `privacy: .public` on a value that is not named as an ID, a count, a code, a duration or a state. The lint knows an ID by its name: one component of the expression must be such a name, as in `captureID`, `note.id` or `elapsed`, and every component after it must only format it, as `uuidString`, `description` or `formatted()` do. So `\(note.id.uuidString, privacy: .public)` and `\(elapsed.formatted(), privacy: .public)` pass, and `\(note.text, privacy: .public)` does not;
- `UserDefaults.standard`, `UserDefaults()`, a `UserDefaults` or `UserDefaults?` set to `.standard`, `@AppStorage(…, store: .standard)` and `.defaultAppStorage(.standard)`; `@AppStorage` without a store; an autosave name without `v1.`;
- `URLSession`, `URLRequest`, the `NW` connection, listener, browser and endpoint types, `CFStream`, `CFSocket` and any `http://` or `https://` in code;
- `eraseDatabaseOnSchemaChange`; a concurrency escape beyond `scripts/concurrency-escapes.txt`;
- a required-reason API, among them the file-timestamp resource keys, `stat`, `fstat`, `lstat`, `fstatat`, the `getattrlist` family and the `statfs` family, without its reason in the manifest of each target that links it;
- a file or folder whose name ends in " 2";
- a launch argument, a string `"-Knot…"`, that is not in the list of debug arguments, `DEBUG_ARGUMENTS` in `scripts/lib/knot_tool.py`. A release build ignores them, and the packaging step looks for each in every Mach-O file of each Release app, and in the Debug iOS app as its control. An optimised build can keep a name of 15 bytes or fewer, as `-KnotPreview` and `-KnotEnterLine` are, inside its code, where the scan cannot see it, and the step says which names those are. The lint sees a name written whole in one string literal; one built at run time, joined from pieces or interpolated, it cannot;
- `Test.cancel(…)` or `Test.Case.cancel(…)`, in the sources and in the package's tests, which it reads for this alone, with a string that names it no call and `.cancel(…)` on the line after `try Test` one. It is a first word to the author: a test that cannot run here says so by a trait, such as `.enabled(if:)`, which Swift Testing prints as skipped. What decides whether a test ran is the event stream, below, since a cancellation can be written in forms the lint cannot know, through an alias or by cancelling the test's task.

It cannot know what a value holds. A value named `noteID` that holds text passes, so does a value logged through a helper of our own, and so does a host reached through an API it does not name. The review reads for those. A comment `knot-lint: allow network` or `knot-lint: allow logged-text` on a line, followed by the reason, lets that line pass, as for a sink that logs a finished line as public by design. The review checks each one. `scripts/lint-cases/Cases.swift` holds a case for each rule and three lines that must pass, and the self-test fails when the lint misses a case or flags one of those lines. It judges the fixture against a privacy manifest of its own, so the result does not change when a package adds a reason to a real manifest.

**A start that does not answer.** On this Mac a system dialog, such as a consent prompt, can hold every start of a development build until the owner answers it, and no agent answers it. So in every script of `scripts/` and `scripts/lib/`, `scripts/worktree-remove.sh` and a script added later included, every call of `swift test`, `xcrun simctl`, `xcodebuild` and `xcb` is made through a limit helper of `scripts/lib/common.sh`, and the self-test fails on one that is not (`knot_tool.py unbounded-calls`); the soak's step is WP-06's and is left to it. The check reads the shell: each simple command, split outside quotes, with what command substitutions, `eval`, `bash -c`, `env -S`, a trap's action, `find`'s `-exec` and a here-document fed to a shell hold, past prefixes such as `env`, `exec`, `arch`, `time -p`, `coproc`, `stdbuf` or `xargs`, and with a command word held in a variable or an array of the same file, `declare -a`, an array built by `+=`, a `for` loop's variable, an assignment by `${name:=…}` and a quoted value such as `SIMCTL="xcrun simctl"` included, put in its place; a word such as `"${XCODEBUILD:-xcodebuild}"` is read as its default. A lookup, such as `command -v xcodebuild` or `xcrun -f xcodebuild`, and a case pattern, such as `xcodebuild | swift)`, in parentheses or over two lines too, are no calls. A call is bounded when a limit helper is the command word of its own simple command. A wrapper's own call carries `# limit: <wrapper>`, naming the function that holds the line; every call of that wrapper, in any of the files the check reads, must then be bounded, and the wrapper must have a call the check can see, so a function called only by a name built at run time, such as a step, cannot be one. It cannot see a command word built at run time, such as one read from a file or put together from pieces; an alias; a command that another runs from its arguments, other than those named here, such as `script -q /dev/null xcodebuild`; an option of `stdbuf` with a value of its own, as in `stdbuf -o 0 xcodebuild -list`, whose value is read as the command (macOS ships no `stdbuf`); a here-document fed to anything but bash, sh or zsh; what a script that a call runs does in turn; or a function named in a variable assigned in another file. So a reviewer of a change to the scripts reads its new calls by hand. Its fixture is `scripts/lint-cases/Unbounded.sh`, with `Unbounded-lib.sh`. The start of `knot-dev`, the Mac app's start and the model report have limits of their own. At a limit the step ends what it started, the command and every process under it, with KILL two seconds after TERM if it must, fails, and says in its log what may be holding it: for a start of a build, a dialog waiting for the owner. A limit is wall-clock time. The limits:

| Start | Limit | Variable, in seconds |
|---|---|---|
| `knot-dev --version`, in the packaging step | 30 seconds | `KNOT_TOOL_START_LIMIT` |
| Each xcodebuild build, in `apps` and `packaging`, and the package resolution in `pins` | 40 minutes | `KNOT_BUILD_LIMIT` |
| Each xcodebuild run of UI tests, in `launch` and `mac-ui` | 20 minutes | `KNOT_UI_TEST_LIMIT` |
| The xcodebuild run of the hosted iOS tests, in `ios-hosted` | 20 minutes | `KNOT_HOSTED_TEST_LIMIT` |
| Each case in those runs, by xcodebuild's own test limits | 10 minutes | |
| `simctl bootstatus`, `install`, `launch` and `screenshot`, in `launch` | 300, 120, 60 and 30 seconds | |
| Every other simctl call of `scripts/sim.sh`, such as in `ensure` and in `shutdown`, which a step's exit runs, the doctor's and bootstrap's list of runtimes, and each simctl call of `scripts/worktree-remove.sh` | 120 seconds | `KNOT_SIMCTL_LIMIT` |
| `xcodebuild -version`, when a script chooses the pinned Xcode | 120 seconds | `KNOT_XCODE_ANSWER_LIMIT` |
| `scripts/sim.sh boot`, which shuts the simulator down at its limit | 300 seconds | `KNOT_SIM_BOOT_LIMIT` |
| The Mac app's first window, in `launch`; each window probe has 15 seconds, and never more than the time left | 60 seconds | `KNOT_APP_START_LIMIT` |
| `swift test`, in `package-test`, `contract-two-targets`, `perf`, `tsan` and `soak`, the soak's by WP-06 | 50 minutes | `KNOT_SWIFT_TEST_LIMIT` |
| `swift test` under the strict cooperative pool, in `package-test-strict` | 30 minutes | `KNOT_STRICT_TEST_LIMIT` |
| The model report, in the nightly run | 10 minutes | `KNOT_MODEL_REPORT_LIMIT` |
| The scripts' self-test, in `self-test` | 10 minutes | `KNOT_SELF_TEST_LIMIT` |
| Reading whether the screen is locked, before `mac-ui` and in the doctor | 10 seconds | `KNOT_CONSOLE_READ_LIMIT` |
| A wait for the audio's lock, while another run in the same tree speaks it, in `fixtures` and `scripts/bootstrap.sh` | 30 minutes | `KNOT_FIXTURES_LOCK_WAIT` |

The package tests' limit is not about a dialog. At 50 minutes it stays under the hour that another run waits for a build slot, and it catches a test that hangs, such as in a deadlock; a run whose waits keep running out may be ended by it first, with its log kept. The Thread Sanitizer run took 2m52s here. A test step reads its results first and then xcodebuild's status, so a run whose tests passed fails when xcodebuild exits with an error. A simctl failure names the simulator. The `launch` and `mac-ui` steps end the Mac app and the test runner that the worktree built, and `launch` fails if either is still running afterwards. The Mac app's start keeps the app's standard error in the step's log, and tells a window probe that failed from a window that has not come.

**The live smoke step.** `live-smoke` runs no test of its own. The smoke tests on `.live` run inside other steps: the iPhone's and the Watch's in `launch`, the Mac's in `mac-ui`. Each is named in `docs/plan/named-tests.txt` by a slug that begins `live-smoke-`, and marked in its source by a comment that names the slug. After both steps, `live-smoke` finds each test by that comment and reads its step's XCTest log, which must be this run's. It fails unless the test passed there, with no failure and no skip.

- **The Mac's test** is asked for only in a run that starts `mac-ui`. Otherwise the step says it was not asked for, as in `--full --skip mac-ui`, or a gate whose diff does not reach the Mac app.
- **A test whose row's pull request has not merged**, or is not the one under test, is not asked for either, by the rule the named tests follow.
- **The UI test is looked for first.** It is marked by a comment that names the slug, in `Apps/iOS/`, `Apps/watchOS/` or `Apps/macOS/`, over the first `func test…` after it, in the class declared before that, by its name before a colon or a brace. Both are read outside comments, so `override class func setUp()` or a comment that says "this class" names no class. It is judged when found.
- **A slug marked in more than one place** fails as ambiguous, and the step names the places, since which is the smoke test is not its to guess. Comments that lead to the same test, as one over its class and one over the test do, are one place. A comment elsewhere that only mentions the slug, as a helper's might, is a second place: leave the slug on the smoke test alone.
- **A package's test.** Only when no UI test carries the slug does a package's Swift Testing test of that name, `@Test("<slug>", .tags(.named))` under `Packages/KnotKit/Tests/`, make it the package's. `package-test` runs it and the named-tests step requires it, and this step names the file. A comment in a package test marks nothing, so no mention can turn a platform's check off. A slug that neither names fails the step.
- **The result lines it reads** are XCTest's two forms, at the start of a line: `Test Case '-[Module.Class method]' passed (…)` and `Test case 'Class.method()' passed on '…' (…)`, with `failed` or `skipped` in place of `passed`. A line in another form is not read. A test whose results are all in such a form has none, and fails; a failure in such a form beside a pass in a form it reads would go unseen. No log of a real run read so far holds one.
- **`--only live-smoke`** alone fails, since no step of its run wrote the logs. It comes last in `--full` and the gate's everything depth.

**What ran: Swift Testing's event stream.** The console cannot say whether every test ran. Swift Testing prints a cancelled case of a test with arguments as `with 2 test cases passed`. It prints a skip or a cancellation whose reason or display name holds a newline over two lines. So every step that runs Swift Testing, on this Mac and on the hosted runner, also writes the run's event stream, and `knot_tool.py test-events` reads it. The steps are `package-test`, `package-test-strict`, `contract-two-targets` and `tsan`.

- **The option.** `swift test --event-stream-output-path <file> --event-stream-version 0` writes the stream. `swift test --help` does not list the option; `--help-hidden` does. The stream is one JSON object a line, and every test target's run is appended to the one file: 21 runs for the package.
- **What it says.** Version 0, the pinned Xcode's, writes `testSkipped`, `testCancelled` and `testCaseCancelled`. A thrown `CancellationError` is a recorded issue, and its test fails.
- **What fails.** A run that says it passed fails its step when its stream is missing, holds no run, or holds a run that did not end. It also fails when the stream holds no test that started or was skipped. A filter that matches nothing ends `swift test` with status 0 and `warning: No matching test cases were run`, and writes such a stream. Each filtered step also reads its console for a run with a test in it, as the soak's does. At the gate, a test skipped, a test cancelled or a case cancelled fails the step, whatever the sources or the console say. The console's reading stays as a second one, and either fails the gate. The summary counts the larger of the two as skipped.
- **A new Xcode.** The probe package of the review of pull request 63, with its skipped, cancelled and two-line forms, is run again on any change of the pinned Xcode, to read what its stream writes.

**The package's tests under the strict cooperative pool.** `package-test-strict` runs the package's tests a second time, after `package-test` and on its build, with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. It is in `--full` and in the gate's leaf and everything depths, and not in `--quick` or the hosted workflow, whose three-core runner is the other proof. It exists because a test whose wait blocks a thread of Swift's cooperative pool, while the work that would end the wait needs a thread of that pool, hangs on the runner and passes on this Mac: twice in one night a hosted check ran to its 30-minute limit so, the store's `Gate` test in pull request 56 and the recorder's ordered stop in pull request 57.

What the variable does, from the sources read for it, not from memory:

- libdispatch, `libdispatch-1542.100.32`, `src/queue.c`. `libdispatch_init` reads the variable. `_dispatch_root_queues_init_once` then sets the kernel's `kern.wq_limit_cooperative_threads` to `-1`, which its comment calls "strict per QoS bucket".
- XNU, `xnu-12377.121.6`, `bsd/pthread/pthread_workqueue.c`. `-1` is `WQ_COOPERATIVE_POOL_SIZE_STRICT_PER_QOS`, which sets the pool's size to one thread, where it is otherwise the number of CPUs. Either way, `workq_cooperative_allowance` still admits a thread for a priority bucket that has work waiting and no thread. A strict size across all buckets, `-2`, is declared and marked as not available.
- Swift, `stdlib/public/Concurrency/DispatchGlobalExecutor.cpp`. On Apple platforms each task priority runs on `dispatch_get_global_queue(priority, …)` with the cooperative flag, a queue for each priority.

So the variable holds the pool to one thread for each priority, not one thread in all. A probe on this Mac, which has 16 logical CPUs, showed it, with a task that blocks on a semaphore that another task signals. It hangs when both have one priority, and runs when the signaller has another. A test in a probe package that blocks its thread that way passed under `swift test` without the variable, and hung under it.

What the step shows: a wait that blocks a pool thread when the work that ends it has the same priority. One such wait is enough here, where the three-core runner needs three at once. What it cannot show: a wait whose ending work has another priority, which gets a thread of its own. A test that blocks one thread and passes on the runner can fail here. It is a test to mend all the same, since it hangs once two more such waits run beside it.

At its limit the step says that a test may be blocking a thread of the cooperative pool, and names the tests that had started and not ended (`knot_tool.py unended-tests`). A test that fails under it is named the same way, as a test to compare with `package-test`. Its skipped and cancelled tests fail the gate, as the package step's do. The summary does not count its passing tests again, only its failures. The build, which `package-build` has done, runs without the variable. The `swift test` driver runs under it and was not affected.

Its cost here: on 2026-11-21 main's suite, 746 tests in 21 runs, passed under the variable in 3m18s, against 4m35s for `package-test` just before, on the same build. The load average ran from 84 to 204 from other agents, so the difference is load. The variable made the run no longer that could be measured.

xcodebuild allows a case ten minutes, as long as a contract suite waits (`SuiteWait.limit`), so a contract suite hosted on iOS whose wait runs long ends with the suite's own message.

**A UI test that waits for idle.** Twice on 2026-11-22, in about twenty-four launch runs, an iPhone UI test ran into its allowance, then three minutes, on the gate's iPhone simulator: once in pull request 87's first gate, once in a rehearsal of pull request 95. Neither set nor test was the same, and the iPad passed the same test in the same run.
- **What it looks like in the bundle:** the app launches and shows the capture field within seconds. Then each "Wait for com.p3ob7o.knot.dev to idle", at the first action after the keyboard comes up and at each one after, runs its 60 s and ends "App animations complete notification not received, will attempt to continue". The test goes on after each, and three such waits were the allowance.
- **The app was idle:** the spindump at the end has its main thread asleep in its run loop, and the screen recording shows the field focused, the keyboard up and nothing in the way.
- **Not reproduced here:** 13 runs in a worktree's own set, two of them straight after deleting and remaking it, had no such wait. Its cause is not known.
- **The bundles** are kept in the build folder's `review-evidence/`, as `pr95/rehearsal-launch-iphone-180s.xcresult` and `pr87/launch-iphone-smoke-180s.xcresult`.

So the allowance is ten minutes, which three or six failed waits fit in. That the test then passes slowly is likely and not shown. A longer bound only makes a real hang fail later. No test is retried, since a retry would turn a real hang green. And each UI step, `launch`, `ios-hosted` and `mac-ui`, prints one line for each case that took longer than a minute, read from the log its result is read from: `slow: <case> on <destination> took <seconds> s, <result>`. That is how the next stall will show (`knot_tool.py slow-cases`).

On the Mac every launch of the Mac app by a UI test waits its full minute for an idle that does not come. At pull request 95's gate on 2026-11-22 the Mac's launch test took 65.4 s and its live smoke test 132.4 s, both passed: in the result bundle each launch waits 60 s for the app to idle, since the app is not brought to the front on this desktop, by the rule that no Mac UI test synthesizes an event. It is no defect, and the Mac UI step's allowance is ten minutes since pull request 95. A way for those tests not to wait would take about three minutes off the step, and is for WP-01 or WP-33 when there is room.

**The team's ID in build logs.** On a Mac whose Xcode knows the owner's team, every app build writes the team's prefix into its log, whatever the signing: `TeamIdentifierPrefix`, `AppIdentifierPrefix` and the entitlements it prints, such as `application-identifier`. So `scripts/verify.sh` filters every log it keeps, and everything it prints from them, through `knot_filter_team` in `scripts/lib/common.sh`, and it rewrites the logs that earlier runs left in `.build/logs-earlier/` at the start of a whole run, and the logs a run wrote itself at that run's end, each keeping its time. The filter masks, as `<TEAM>`, ten capitals and digits where those keys, `DEVELOPMENT_TEAM` or an identifier such as `<ID>.com.…` or `<ID>.*` put them, as a plist's whole `<string>`, as codesign's `[String]` value, and as the parenthesised end of a certificate's name, its parentheses escaped or not. It masks a signing identity too: its SHA-1 after `--sign`, as `<IDENTITY>`, and the name of a certificate after `Apple Development:` and its like, as `<NAME>`. A run that has the owner's configuration also masks the ID itself wherever it stands. The filter reads it, as the `team-id` step does, from `KNOT_TEAM_CONFIG`, else `KNOT_LOCAL_CONFIG`, else the configuration that bootstrap linked into `.build/config/`, and never prints it. Other runs know no ID and go by the patterns alone. Xcode's own logs in DerivedData keep the prefix; the scripts never print them, and nothing from a build log goes into a note, a commit or a pull request unfiltered.

## The other scripts

| Command | Does |
|---|---|
| `scripts/install.sh <Knot.app>` | Installs an iOS build on every paired iPhone and iPad, and its Watch app on every paired Watch, with `devicectl`. It skips a device that holds the build already, names every device it could not reach, and exits non-zero when it missed one. `--device <name>` picks devices. |
| `scripts/install.sh <Knot.app> --again` | Installs on a device that holds the same version and build too, as a build signed again needs. Without it such a device is skipped. |
| `scripts/install.sh <Knot.app> --mac-folder <folder>` | Copies a Mac build to a folder the owner names. He opens it there. From the M4 milestone build on, no milestone build runs on the build Mac. |
| `scripts/milestone-build.sh <M1…M7> --commit <sha>` | A milestone build, by the orchestrator, with the owner's go-ahead. Before it builds, it refuses a worktree with uncommitted changes or with files git ignores under the folders the build reads, a `HEAD` that is not the commit named, a tree with no team configuration linked, a `.build/config/Worktree.xcconfig` or `Local.xcconfig` that sets more than its own keys, a package's checkout under `.build/SourcePackages` off its pin or changed, and an Xcode whose saved list of accounts is empty. It builds each product, `--products ios`, `mac` or `both` (the default), in fresh derived data under `.build/milestone/`, in Release, through a build slot, and says the build's time apart from the wait for the slot. Then, for each product: its bundle ID, version, build number, flavour and level against the level and `Apps/Config/Identifiers.xcconfig`; `codesign --verify --strict` on every part, each alone; every part signed by the app's own team, and the Mac tool's app groups the app's; each part's app groups against those its provisioning profile allows; and no fakes and no debug launch argument in any Mach-O file. It stops at the first failure, naming the part, and installs nothing. Its products are unregistered from LaunchServices once checked, and stay on disk. Each build's log is `.build/milestone/milestone-build-<level>-<commit>-<product>.log`, filtered as it is written; `verify.sh` does not move it. It prints its summary, with each product's path and log, before any install. `--allow-provisioning-updates` passes `-allowProvisioningUpdates`, on the owner's word; nothing passes `-allowProvisioningDeviceRegistration`. `--install` then runs `scripts/install.sh`, with `--device` and `--again` passed through, and `--mac-folder <folder>` for the Mac app; an install that fails leaves the build whole, and the script prints the command that installs it again. It never starts what it builds. |
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

  The Mac UI tests also need the screen unlocked, at every run that holds them: on a locked screen their app cannot come to the front. A run reads the lock state once, before the Mac UI step, under a limit, and fails that step at once when the screen is locked, before it takes its slot, saying that the owner has to unlock the Mac; no agent does. A read that says nothing never passes the step: the step runs, and fails by itself if the screen is locked. `scripts/doctor.sh` reads it only in a run that has the Mac UI step, and notes what it read.

  When a UI test fails, in `mac-ui` or `launch`, the step's own log, which the run's failure shows, gives the failed cases' error lines, `<file>:<line>: error: …`, with no folder, and names the long log, `.build/logs/verify-mac-ui-tests.log` for the Mac. A skipped XCTest case, in `mac-ui` or `launch`, and a skipped or cancelled test in `ios-hosted`, is listed in the step's log and counted as skipped in the summary, and at the gate it fails the step, as one in the package's tests does. When the xcodebuild of a UI or hosted step ends by a signal that the step's limit did not send, the step says so, with the signal's number and name, and does not read the run as one with no tests: a process outside the step ended it.

  **A thread and the Mac UI tests.** A thread may run `scripts/verify.sh --only mac-ui` itself, on the build Mac, only when the orchestrator says the desktop is free for it, and not otherwise. The tests take the desktop: their app comes to the front, and the runner moves the pointer and types, so a person at the Mac would be in the way, and would be typed over. The run needs four things: Automation Mode without authentication and developer mode, which `scripts/doctor.sh --mac-ui` checks; the screen unlocked, since the step fails at once on a locked one and no agent unlocks it; the one exclusive Mac UI slot, which the run waits for while the gate or another thread holds it; and a quiet Mac, since a case that waits on a busy one can outlive its allowance. A thread without the desktop runs `scripts/verify.sh --full --skip mac-ui`, which never runs these tests, and says so in its hand-back. When its change reaches one of the paths for which the gate's depth takes the step (`MAC_UI` in `scripts/lib/knot_tool.py`: the Mac app, the shared app code and configuration, `project.yml`, the package manifest, KnotUI, KnotApp, `Apps/UITestSupport/`, `scripts/`, `.xcode-version` and `.github/workflows/verify.yml`), it asks the orchestrator for the desktop before it hands back, so that a Mac UI test does not fail first at the gate, as WP-21's accessibility audit of the Mac app did at its first run. `--full` itself still runs the step.

  Before a gate with the Mac UI step, the orchestrator reads how long ago the build Mac had input. When the owner is at it, he is asked for the window first, in clock times: the launch step's Mac part and the Mac UI step start the app on his screen, about 21 to 30 minutes into the gate, and a window that opens under his hands can take what he types (docs/orchestrator.md).

- Set up signing so that `scripts/doctor.sh --require-signing` passes: the gate's development-signed step must sign without a prompt.
- Confirm the identifiers in the table above, pair the devices for development builds, and register the other Mac.
- Before the first milestone build, register the milestone identifiers: they need explicit App IDs and development profiles of their own, with the app group, iCloud and push, since the wildcard team profiles authorise none of them. The development identifiers' profiles do not serve. Whether a build below M4 signs without iCloud and push is an open point (docs/plan/open-points.md, "Signing below M4").

## Continuous integration

GitHub offers a hosted runner with Xcode 27: the `xcode-27` image, a preview on 2026-11-19, carries the release Xcode 27.0, 27.1 and 27.2. `.github/workflows/verify.yml` runs `scripts/verify.sh --quick` there on every pull request and every push to `main`. It passes only once `.xcode-version` pins a release Xcode that the image carries.

For a pull request whose diff reaches those same paths, `MAC_UI`, the workflow's `mac-ui` job runs `scripts/verify.sh --only mac-ui` there too: the doctor, then the gate's Mac UI step, as the scripts run it on the build Mac. A small job on a Linux runner, `mac-ui-scope`, reads the diff with `knot_tool.py depth` first, so a pull request that does not reach the Mac app starts no Mac runner for it. No merge requires the job: it is there to learn whether the hosted runner can bring the app to the front and read its accessibility tree. It fails as the step does, on a locked screen, a failed or skipped test, or a run in which no test ran, and it keeps its logs as an artifact for seven days, after a pass too. Its first run, on 2026-11-22 on the `xcode-27-arm64` image, passed the 24 Mac UI tests: the doctor found Automation Mode turning on without authentication, developer mode on and the screen unlocked, and the job took 3m26s, 3m00s of it the step.

**The gate with the hosted job's Mac UI result.** `scripts/verify.sh --gate … --mac-ui-hosted` lets the hosted `mac-ui` job meet the gate's Mac UI step. The orchestrator uses it only when this Mac's screen is locked, and only by the owner's word. No agent unlocks the screen, and without the option a locked screen fails the gate at `mac-ui`. The option belongs to the gate alone, and `--full` and `--quick` refuse it. With it:

- **Nothing runs on this Mac for the step.** The doctor does not ask for Automation Mode. The step asks GitHub, through `gh`, for the check run `mac-ui` that GitHub Actions made on the tree's head, the commit under test (`knot_tool.py hosted-mac-ui`). It reads no secret of its own: the check runs and the artifacts of a public repository, which `gh` reads signed in.
- **It passes only** when the latest such run is completed with success on that very commit, its workflow run kept `verify-mac-ui-tests.log` in the artifact `mac-ui-logs`, and that log, read as the local step reads its own, holds passed tests, no failed case and no skip. The log becomes this run's Mac UI log, under a first line that names the job, the check run and the commit.
- **It fails, and says why:**
  - while the screen reads anything but locked;
  - when the gate's base is not an ancestor of the commit under test. On a pull request the job tests GitHub's merge of the head into the base as it then was, and the check run is recorded on the head. Only with the base an ancestor of the head does that merge have the head's own tree. A branch behind main merges main in and lets the job run on the new head;
  - when the diff changes `scripts/` or `.github/`, since the hosted job ran the candidate's own scripts and workflow, which main's have not checked;
  - when GitHub has no such run on the commit, as for a commit not pushed;
  - when the run is still going, or ended failed, cancelled or otherwise;
  - when the job was skipped. If the scope job passed, the scope said the diff does not reach the Mac UI paths, which the gate's own depth says it does: the job ran on another base;
  - when the artifact is gone, after its seven days;
  - when GitHub's answer cannot be read.
- **The summary and the status line say it.** The step shows as `mac-ui (hosted job)` with the run's address. Its tests are counted apart, as the hosted job's, and never in this Mac's totals. The summary adds "mac-ui met by the hosted job, its N tests not counted here", and the status line adds "mac-ui by hosted job".
- **The live smoke step** reads the Mac's smoke test from that log, as it reads a local run's, and says that it passed in the hosted job, naming the check run.

The repository gets no self-hosted runner, because it is public. Its workflows hold no secrets, never use `pull_request_target`, have read-only permissions and pin their actions by revision. The merge gate itself, `scripts/verify.sh --gate`, runs on the orchestrator's Mac.
