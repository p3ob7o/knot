# The orchestrator's runbook

For the thread that runs the Knot build. Read it after a reset, before doing anything new. `PLAN.md` §8 and `docs/architecture.md` §18 set the rules. This file says how they are carried out today, and it changes as the tooling lands.

## Where the state is

- **The plan.** `PLAN.md`, the briefs in `docs/plan/`, and `docs/plan/open-points.md`, which lists what is still unsettled and who settles it.
- **GitHub.** The branches (`wp/…`, `spike/…`, `contract/…`), the pull requests and their descriptions.
- **The journal.** `journal.md` in the build folder, which sits outside every worktree. On the build Mac the build folder is `~/knot-build`. The journal has one line for each operation, written before it starts and again when it ends, with the base, the head and the tree where they apply. Its times are local. It holds no note text and no secrets.
- **The threads.** The package threads in T3 Code, and their worktrees, which `git worktree list` shows.

After a reset, read the last lines of the journal, list the open pull requests and the worktrees, and compare the three. Finish or undo an operation that was cut short before starting anything new. A release step that was cut short is never resumed: it goes back to Paolo.

## Launching a package

1. Read its rows in the start table of `PLAN.md` §6. Everything a row names has merged. A spike it names has its report merged and Paolo's confirmation, and the changes its report asks of `docs/architecture.md` have merged too.
2. Read `docs/plan/open-points.md` for the points to settle before that package starts. Settle them in the documents first, in a pull request of the orchestrator's own.
3. Write the launch in the journal.
4. Launch one top-level thread with `t3_thread_launch`: a worktree from `origin/main` on the branch `wp/<number>-<slug>`, the model `claude-opus-5-5`, and effort `high`, or `xhigh` for WP-10, WP-12 and WP-16. The first message is the prompt of `PLAN.md` Appendix B, followed by what the orchestrator has settled for the package and by what the build Mac has today.
5. Keep to five implementer threads at a time.

What the build Mac has today, for every first message:

- The pinned Xcode is the one `.xcode-version` names. The beta is used only by name, through `KNOT_XCODE`.
- A forced push can wait for Paolo's approval, and a thread that sends one stalls there. A thread never rewrites a branch it has pushed, takes a new folder from `mktemp -d` in place of a recursive delete, and never chains a command that removes something with one that must run.
- When a tool call comes back as declined together with a message on another subject, Paolo answered while the call waited for approval. The thread acts on the message, and sends the call again if it was already allowed.
- The owner's recordings, when he has made them, are in the folder that `KNOT_LOCAL_FIXTURES` names. Nothing derived from them enters a commit, a pull request, a log or a test.
- `KNOT_AGENT=1` is exported in every shell before a script runs.
- A hook refuses `git add -A`, `git add -u` and a commit inside a compound command. A thread stages files by name, runs `git commit -F <file>` as a command of its own, and gives `gh pr create` its description with `--body-file`.
- A thread records each commit in UTC, as `AGENTS.md` says: `TZ=UTC git commit -F <file>`. The hook lets that form through.
- No hardware microphone, ever. A simulator's microphone is the Mac's own, so no recording path runs in a simulator.
- No suite has a bound that a loaded machine can miss. Every wait of the suites ends through `SuiteWait` after ten minutes, with an issue that names what it waited for, and a test that holds something back bounds its own calls into what it tests the same way (docs/architecture.md §17). On main, three calls in `NoteStoreFakeTests.swift` that are made during a hold do not yet: WP-02's third pull request bounds them.
- A package test takes no file from `Fixtures/generated/`, which a fresh checkout and the hosted runner lack, unless only the build Mac runs the test (docs/architecture.md §17).
- The owner's team configuration is on the Mac since 2026-11-20, in a file outside the repository. A thread whose package must sign with the team gets the file's path in `KNOT_LOCAL_CONFIG`, and no other thread does: every other build signs locally. The team's ID is never printed, never logged and never written to a tracked file, a note or a pull request. A thread that has the file runs `scripts/verify.sh --only team-id` before each push, and it does not run the gate, which refuses the variable.
- Xcode on this Mac knows the owner's team, and it writes the team's prefix into the log of every app build, whatever the signing: the lines `TeamIdentifierPrefix` and `AppIdentifierPrefix`, and the entitlements it prints. So the ID is in the build logs of every worktree that has built an app. The team-ID check does not see it there, because it reads tracked files only, and it sees no commit message and no description of a pull request. No thread puts a build log, or a part of one, into a note, a commit message or a pull request without taking those lines out. On 2026-11-20 every branch, tag, commit message and pull request description was searched, and none held the ID.
- A build signed with the team and a locally signed build of the same bundle ID do not share a container quietly on this Mac. Each new signer raises a consent dialog that only Paolo answers, and while it is open every start of that bundle ID waits, the gate's own too. So a team-signed build of the development identifiers runs on this Mac only with him at the Mac, and while no gate and no UI test runs. Xcode on this Mac is signed in to his account, he allowed this Mac to be registered as a development device, and he answers each consent dialog himself.
- Other threads build at the same time. A thread runs one heavy build at a time.
- A note or a pull request describes the SDK and the simulators, never the owner's own settings: no locale or region of this Mac, no account name, no path under `/Users`. The repository is public.
- The description of a pull request follows `PLAN.md` Appendix C.

The first message ends by telling the thread to send its RESULT line to the orchestrator's thread with `t3_thread_send` when it ends.

## When a thread hands back

The last line of its final message is `RESULT ok` or `RESULT blocked` with a code (`PLAN.md` §8.3).

- `RESULT ok`: arrange the review.
- `needs_owner` and `needs_hardware`: tell Paolo exactly what is needed, and resume the thread when he has done it.
- `needs_contract_change` and `needs_shared_file`: the orchestrator arranges the change, as `PLAN.md` §8.5 says.
- `brief_wrong`: correct the brief first, in a pull request of the orchestrator's own.
- `baseline_red` and `tool_failure`: find the cause before launching anything else on that base.

A top-level thread does not wake the orchestrator by ending. The RESULT line that it sends with `t3_thread_send` does. That line is not Paolo's: the orchestrator reads the thread's last message before it acts on it. One scheduled check an hour looks for a thread that stalled on an approval prompt. A thread that shows as waiting on a background command of its own is at work, and it has not handed back until its RESULT line arrives. A delegated task wakes the orchestrator by itself, and so does a watched pull request when its checks end.

## Review

- A fresh reviewer reads the diff against the package's brief and `AGENTS.md`, from a list of points that the orchestrator writes for that pull request. It runs as a delegated task, so its end wakes the orchestrator. It changes nothing, runs what it runs in a scratch clone, and ends with `REVIEW pass` or with `REVIEW changes` and the counts.
- The orchestrator checks each finding before it passes it on, and rules where the documents are silent. A ruling goes into the documents in a pull request of the orchestrator's own.
- A proof step's code stays on `wp/<number>-proof` with no pull request, and its note merges from `wp/<number>-note`. The orchestrator reads a short note itself, and the squash message says that no second agent did.
- WP-02, WP-05, WP-06, WP-10, WP-11, WP-12, WP-15, WP-16 and WP-17 also get a second opinion from another model.
- The implementer fixes the findings. After two rounds the orchestrator decides what is left. It writes every finding it sets aside in the pull request and in the journal.

## The merge queue

One pull request at a time.

Since 2026-11-20 the ruleset on `main` requires a pull request, squash as the only merge method, an up-to-date branch and two checks, `knot/gate` and `quick`, the hosted workflow's run of `scripts/verify.sh --quick`, and nobody bypasses it. GitHub refuses a merge without both checks, so the hosted check is required, not a habit: a head waits for it as it waits for the gate.

1. In the gate worktree, check out the pull request's head. If `main` has moved since the branch last took it in, merge `main` into it there, with `TZ=UTC` in front of the command, so that the merge is recorded in UTC. A conflict goes back to the implementer.
2. Run the gate on that commit from the main checkout, so that main's scripts check the candidate: `scripts/verify.sh --gate --tree <the gate worktree> --branch <branch> --package <ID>`. The head is detached there, and on a detached head the gate refuses `--package` alone: `--branch` names the branch, which also tells a note's pull request from a code one. A stated exception to path ownership is passed with `--allow <path>`, and an allowance that matches nothing fails. A pull request that changes `scripts/` is gated with its own scripts, from the gate worktree. Write the result in the journal with the base, the head and the tree.
3. If step 1 made a merge, push it to the branch as an ordinary push, and let the workflow run on the new head. Never rebase a branch that was pushed and never force a push: a forced push waits for Paolo's approval.
4. Post the status `knot/gate` on that head, with the output of `scripts/verify.sh --status-line --tree <the gate worktree>`: the same `--tree` as the gate run, because the line is kept in that tree's `.build/logs` and names no commit. A failed gate is posted too, as a failure, and what it found goes to the implementer.
5. Squash-merge at the tested head, with a subject and a body of the orchestrator's own, so that no session link enters the history. The merge is made through GitHub's REST call for merging a pull request, `PUT /repos/<owner>/<repository>/pulls/<number>/merge`, with `merge_method` set to `squash`, with `sha` set to the tested head, which refuses the merge if the head has moved, and with the header `Time-Zone: Etc/UTC`. The subject goes in `commit_title` and the body in `commit_message`. GitHub's REST documentation gives that header for the time zone of a commit that GitHub makes. Without it the commit on `main` takes the zone GitHub last knew for the account. The merge of pull request 36 was the first made this way, and it showed what the header does: the committer's date of the squash records +0000, and the author's date keeps the zone GitHub holds for the account, as on every merge before it. Neither is this Mac's offset. The subject starts with the package's ID, as in `WP-02 PR 1: …`, because the gate's helper reads the subjects on `main` when it cannot ask GitHub which pull requests have merged.
6. Check that the tree on `main` is the tree that was tested. If `main` or the head moved in between, the result is void.
7. Delete the branch. A branch whose pull request was squashed gets no further commits. If the thread goes straight on with the package's next pull request, it starts a new branch from `origin/main` in the same worktree. Otherwise remove the worktree.

The gate is `scripts/verify.sh --gate`, and its depth comes from the diff (docs/architecture.md §18). `scripts/gate-steps.txt` lists every step and marks those that are still pending, each with what delivers it, and the orchestrator turns a line to required when that has arrived. The Mac UI step, `mac-ui`, is required since WP-01's third pull request, pull request 38. The soak waits for WP-06, the `.live` smoke tests for WP-22 and the two-process test for WP-34.

The team-ID check is required since 2026-11-20, when Paolo's signing configuration came to the Mac, and it runs at every depth. The orchestrator names the configuration for it with `KNOT_TEAM_CONFIG`, in front of the gate's command. That variable serves the check alone and links nothing into the tree. `KNOT_LOCAL_CONFIG` would link the configuration into the gate worktree and give the gate's app steps build settings that no thread has, so the gate refuses it, and it removes such a link if an earlier run left one. Without a configuration the step is skipped, and the gate fails on a skipped step: its line reads FAILED, and that is what is posted. A thread without the configuration runs `scripts/verify.sh --full`, which reports the step as skipped and ends ok.

Since pull request 38 the packaging step starts `knot-dev` under a time limit, and so does each run of UI tests, and at the limit the step fails and says that a system dialog may be waiting for Paolo (docs/architecture.md §18).

A pull request that changes the gate, or a contract that others build on, is tried on the next pull request in the queue before it merges, by running its scripts with `--tree` on that candidate. On 2026-11-19 this found two faults in the tooling that its own gate could not show.

## What needs Paolo

- The gates G0 to G5 of `PLAN.md` §10, with the minutes each takes.
- The list in `AGENTS.md`: moving a tag, distribution signing, notarising and uploading, deploying the CloudKit production schema, every operation on the milestone iCloud container, and deleting an archive branch.
- Any cut of scope, and the points under "For the owner" at the end of `docs/plan/open-points.md`.

What he has answered, each on 2026-11-20:

- SP-4 may deploy its schema to the production side of a throwaway iCloud container made only for that spike (`docs/plan/SP-4.md`). His answer covers nothing else: no other deployment, and no other container.
- The wave 0 recordings are put off, and the orchestrator does not raise them before M2's close, or before the cleanup sitting of G4 needs them. Until they exist, a pull request that touches speech or cleanup merges on the synthetic evaluation, the numbers on his recordings follow, and M2 does not close without them. He chose this on 2026-11-20, when it was put to him with its details.
- The branch of a merged pull request is deleted right after the merge, as step 7 of the merge queue says, without asking him. Only such a branch is deleted. The spike-app and proof branches, which never merge, the `archive/` branches and branches that are not this build's stay.
- Builds signed with his team may be made. He was told what the first build that Xcode provisions registers under his account: the app IDs of the development identifiers, their app group and the development iCloud container. When SP-3's first builds were made on 2026-11-20, Xcode had no account signed in, and they were signed with `codesign` and no profile. Later that day Xcode was signed in to his account, he allowed this Mac to be registered as a development device, and SP-3 was allowed to try the Team-ID form of the app group. Which form of the app group Knot ships with is still his to say, on SP-3's report. Distribution signing still needs his word each time.

## Models and cost

- Implementer and reviewer threads run on Claude Opus 5.5, as decision D14 says. A second opinion runs on another vendor's model.
- Give an agent a small input: its brief and what it needs, never the whole plan. Tell Paolo before starting more than a few agents at once.
