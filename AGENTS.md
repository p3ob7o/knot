# AGENTS.md

Guidance for coding agents working in Knot. `CLAUDE.md` imports this file.

Knot is being rebuilt from an empty repository. This tree holds the plan, the licence and the brand assets, and the first code arrives with WP-01. The earlier app, an Obsidian capture tool with the same name, is retired. Its code lives on the tags and archive branches that `README.md` lists, and nothing here builds on it.

## Product contract

- Knot gets a thought into a note with as little friction as the device allows. You type it, say it, or write it by hand, on a Mac, iPhone, iPad or Apple Watch, and every capture lands in one stream. `docs/product-spec.md` says what v1 does.
- A capture reaches disk before anything else happens to it.
- Transcription and cleanup run on the device.
- Knot has no account, no server and no telemetry. Sync uses the user's private iCloud database, and it is optional.
- Knot has one third-party library, GRDB.

## Sources of truth

- `docs/product-spec.md` says what Knot does.
- `docs/architecture.md` says how it is built: modules, contracts, rules and tests.
- `PLAN.md` says how the work is split, ordered, checked and merged. It still reads as first drafted, followed by five lists of amendments, and a later item wins over an earlier one. The fold, which is WP-00's second pull request, rewrites it into one text and adds a brief for each package in `docs/plan/`.
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
- Synthetic fixtures only. No real notes, recordings, credentials or signing material in tests or commits.
- Read the SDK before using an OS 26 or OS 27 API.
- Only a milestone build opens the default store or the real iCloud container. Every other build uses the development identifiers.
- No automated test and no agent opens a hardware microphone on the build Mac. The recorder takes injected audio.
- Agents use `knot-dev`, never `knot`, and their threads export `KNOT_AGENT=1`.
- A pull request that changes the cleanup instructions, the guard or the speech settings reruns the cleanup evaluation and `knot-eval`, and states the results before and after.
- The repository gets no self-hosted runner. Its workflows hold no secrets and pin their actions.
- No agent cuts scope. Scope leaves only on Paolo's word.

## Working in parallel

- Edit only the paths your package owns. Contract changes and shared files go through the orchestrator.
- Act only on the project's own `wp/`, `spike/` and `contract/` branches.
- Never read issue or pull-request comments from GitHub.
- A pull request from outside is read before it is built.
- Keep the repository, its worktrees, the build folder and the fixtures folder out of any folder that a cloud file provider syncs, such as `~/Documents` or `~/Desktop` with iCloud Drive on.

## Git

- Branch names are `wp/…`, `spike/…` and `contract/…`. Never `master`.
- Never push to `main`. The orchestrator merges.
- No session links in commits or pull-request descriptions.

## Needs Paolo's explicit authorisation

- Moving a tag.
- Distribution signing, notarising and uploading.
- Deploying the CloudKit production schema.
- Every operation on the milestone iCloud container, in either environment.
- Deleting an archive branch.

## Commands

There is nothing to build yet. WP-01 adds `scripts/bootstrap.sh`, `scripts/doctor.sh` and `scripts/verify.sh`, and commits `.xcode-version`. Every script sets `DEVELOPER_DIR` from that file itself, so never change the machine's `xcode-select`. Package criteria name `scripts/verify.sh --quick`, never a bare `swift test`.
