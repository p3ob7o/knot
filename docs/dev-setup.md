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
scripts/bootstrap.sh         # prerequisites, configuration, Knot.xcodeproj, packages, simulators
scripts/verify.sh --quick    # formatting, the plan check, the pins, the package and its tests
```

`scripts/bootstrap.sh --first-test` also runs the first module test and prints how long the fresh worktree took to reach it. The aim is 5 minutes, and 3 minutes for a warm `--quick`.

`Knot.xcodeproj` is generated from `project.yml` and is not committed. Run `scripts/bootstrap.sh` again after changing `project.yml` or a target's YAML file, and never edit the generated project.

## What a worktree keeps to itself

- Build products, logs, package checkouts and DerivedData in its own `.build/`, which git ignores.
- Three simulators named after the worktree: `<worktree>-iphone`, `<worktree>-ipad` and `<worktree>-watch`. `scripts/sim.sh` lists, boots, shuts down and deletes them. It never touches another project's simulators.
- On the Mac, a development store folder named after the worktree, inside the development container. The worktree's name reaches the app through `.build/config/Worktree.xcconfig` and the `KnotDevStoreFolder` key of the Info.plist.

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
