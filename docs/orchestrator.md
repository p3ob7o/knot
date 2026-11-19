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
- A recursive delete and a forced push each wait for Paolo's approval, and a thread that sends one stalls there. A thread takes a new folder from `mktemp -d` in place of a delete, and never rewrites a branch it has pushed.
- When a tool call comes back as declined together with a message on another subject, Paolo answered while the call waited for approval. The thread acts on the message, and sends the call again if it was already allowed.
- The owner's recordings, when he has made them, are in the folder that `KNOT_LOCAL_FIXTURES` names. Nothing derived from them enters a commit, a pull request, a log or a test.

## When a thread hands back

The last line of its final message is `RESULT ok` or `RESULT blocked` with a code (`PLAN.md` §8.3).

- `RESULT ok`: arrange the review.
- `needs_owner` and `needs_hardware`: tell Paolo exactly what is needed, and resume the thread when he has done it.
- `needs_contract_change` and `needs_shared_file`: the orchestrator arranges the change, as `PLAN.md` §8.5 says.
- `brief_wrong`: correct the brief first, in a pull request of the orchestrator's own.
- `baseline_red` and `tool_failure`: find the cause before launching anything else on that base.

A top-level thread does not wake the orchestrator when it ends, and a wait on it returns within a minute. The orchestrator reads the thread when something else wakes it, or schedules one check-in. A delegated task does wake it.

## Review

- A fresh reviewer reads the diff against the package's brief and `AGENTS.md`, with gstack `/review` and the points the orchestrator lists for that pull request. It runs as a delegated task, so its end wakes the orchestrator. It changes nothing, runs what it runs in a scratch clone, and ends with `REVIEW pass` or with `REVIEW changes` and the counts.
- WP-02, WP-05, WP-06, WP-10, WP-11, WP-12, WP-15, WP-16 and WP-17 also get a second opinion from another model.
- The implementer fixes the findings. After two rounds the orchestrator decides what is left. It writes every finding it sets aside in the pull request and in the journal.

## The merge queue

One pull request at a time.

1. In the gate worktree, check out the pull request's head. If `main` has moved since the branch last took it in, merge `main` into it there. A conflict goes back to the implementer.
2. Run the gate on that commit, and write the result in the journal with the base, the head and the tree.
3. If step 1 made a merge, push it to the branch as an ordinary push, and let the workflow run on the new head. Never rebase a branch that was pushed and never force a push: a forced push waits for Paolo's approval.
4. Post the status `knot/gate` on that head, with the gate's summary line.
5. Squash-merge with `gh pr merge --squash --match-head-commit <head>`, with a subject and a body of the orchestrator's own, so that no session link enters the history.
6. Check that the tree on `main` is the tree that was tested. If `main` or the head moved in between, the result is void.
7. Delete the branch. A branch whose pull request was squashed gets no further commits. If the thread goes straight on with the package's next pull request, it starts a new branch from `origin/main` in the same worktree. Otherwise remove the worktree.

The gate depends on what has merged:

| Until | The gate is |
|---|---|
| WP-01's first pull request merges | `scripts/check-plan.sh` and the package's own merge criteria, because `scripts/verify.sh` does not exist yet |
| WP-01's second pull request merges | `scripts/verify.sh --quick` |
| Afterwards | `scripts/verify.sh --gate` |

## What needs Paolo

- The gates G0 to G5 of `PLAN.md` §10, with the minutes each takes.
- The list in `AGENTS.md`: moving a tag, distribution signing, notarising and uploading, deploying the CloudKit production schema, every operation on the milestone iCloud container, and deleting an archive branch.
- Any cut of scope, and the two points at the end of `docs/plan/open-points.md`.

## Models and cost

- Implementer and reviewer threads run on Claude Opus 5.5, as decision D14 says. A second opinion runs on another vendor's model.
- Give an agent a small input: its brief and what it needs, never the whole plan. Tell Paolo before starting more than a few agents at once.
