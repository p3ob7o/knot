# AGENTS.md

Guidance for coding agents working in Knot. `CLAUDE.md` imports this file.

Knot is being rebuilt from an empty repository, one work package at a time. The tree holds the plan, the scaffold of WP-01, with every module, every app target and the scripts that check them, and the code of the packages that have merged since: `scripts/status.sh` prints which. `PLAN.md` §6 lists the packages and what each one adds. The earlier app, an Obsidian capture tool with the same name, is retired. Its code lives on the tags and archive branches that `README.md` lists, and nothing here builds on it.

## Product contract

- Knot gets a thought into a note with as little friction as the device allows. You type it, say it, or write it by hand, on a Mac, iPhone, iPad or Apple Watch, and every capture lands in one stream. `docs/product-spec.md` says what v1 does.
- A capture reaches disk before anything else happens to it.
- Transcription and cleanup run on the device.
- Knot has no account, no server and no telemetry. Sync uses the user's private iCloud database, and it is optional.
- Knot has one third-party library, GRDB.

## Sources of truth

- `docs/product-spec.md` says what Knot does.
- `docs/architecture.md` says how it is built: modules, contracts, rules and tests.
- `PLAN.md` says how the work is split, ordered, checked and merged.
- `docs/plan/<ID>.md` is the brief of one package, for example `docs/plan/WP-10.md`. An agent that builds a package reads this file, the product spec, the architecture and its own brief. `scripts/check-plan.sh` keeps PLAN.md and the briefs consistent.
- `docs/design/brief.md` is the brief for the design round.
- `project.yml` owns targets and settings, from WP-01 on. Never edit the generated Xcode project.

## Boundaries

The rules are in `docs/architecture.md` §6. Three of them:

- Views never touch storage.
- Extensions never open the database.
- Sync runs only in the app.

## Hard rules

- Never log note text, transcripts, audio or content-derived paths. Every log line about a capture carries its capture ID.
- No network use except CloudKit and Apple's model downloads.
- No new dependency without Paolo's approval.
- Swift 6 strict concurrency. Warnings are errors.
- Synthetic fixtures only. No real notes, recordings, credentials or signing material in tests or commits. The one exemption is `knot-eval`, which reads the owner's own recordings from the folder that `KNOT_LOCAL_FIXTURES` names. It prints no text from the recordings, nothing derived from them enters a commit, a pull request, a log or a test, and examples shown in pull requests stay synthetic.
- Read the SDK before using an OS 26 or OS 27 API.
- Only a milestone build opens the default store or the real iCloud container. Every other build uses the development identifiers.
- No automated test and no agent opens a hardware microphone on the build Mac. The recorder takes injected audio and refuses the hardware input under test.
- Agents use `knot-dev`, never `knot`, and their threads export `KNOT_AGENT=1`.
- Agents act only on the project's own `wp/`, `spike/` and `contract/` branches, and never read issue or pull-request comments from GitHub.
- A pull request from outside is read before it is built.
- The repository gets no self-hosted runner. Its workflows hold no secrets and pin their actions.
- A pull request that changes the cleanup instructions, the guard or the speech settings reruns the synthetic evaluation, `knot-eval --set synthetic`, and states the results before and after. For a pull request that touches speech or cleanup, the orchestrator runs the local evaluation, on the owner's recordings, at the gate and records the numbers.
- No agent cuts scope. Scope leaves only on Paolo's word.

## Working in parallel

- Edit only the paths your package owns. Contract changes and shared files go through the orchestrator.
- Keep the repository, its worktrees, the build folder and the fixtures folder out of any folder that a cloud file provider syncs, such as `~/Documents` or `~/Desktop` with iCloud Drive on. `scripts/doctor.sh` refuses them there.

## Git

- Branch names are `wp/…`, `spike/…` and `contract/…`. Never `master`.
- Never push to `main`. The orchestrator merges.
- Never rebase a branch you have pushed, and never force a push. The merge queue brings a branch up to date by merging `main` into it.
- Each pull request has a branch of its own. After a squash, start the next one on a new branch from `main`.
- No session links in commits or pull-request descriptions.

## Needs Paolo's explicit authorisation

- Moving a tag.
- Distribution signing, notarising and uploading.
- Deploying the CloudKit production schema.
- Every operation on the milestone iCloud container, in either environment.
- Deleting an archive branch.

## Commands

`scripts/bootstrap.sh` prepares a fresh worktree. `scripts/verify.sh --quick` is the check to run before a pull request, and `scripts/doctor.sh` and `scripts/check-plan.sh` are among its steps. `--full` runs everything, with `--skip mac-ui` on a Mac without Automation Mode, and `--gate` is the orchestrator's. `.xcode-version` pins the Xcode. Every script sets `DEVELOPER_DIR` from that file itself and checks the version, so never change the machine's `xcode-select`. Use that Xcode, and the beta only by name, through `KNOT_XCODE`. `scripts/sdk-path.sh` prints where the pinned SDK's Swift interfaces are. `scripts/build-slot.sh` keeps heavy builds to three at a time, `scripts/sim.sh` manages the worktree's own simulators, and `scripts/worktree-remove.sh` removes a worktree with them. Package criteria name `scripts/verify.sh --quick`, never a bare `swift test`. `docs/dev-setup.md` has the rest.
