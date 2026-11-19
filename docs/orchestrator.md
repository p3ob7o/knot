# The orchestrator's runbook

For the thread that runs the Knot build. Read it after a reset, before doing anything new. `PLAN.md` §8 and `docs/architecture.md` §18 set the rules. This file says how they are carried out today, and it changes as the tooling lands.

## Where the state is

- **The plan.** `PLAN.md`, the briefs in `docs/plan/`, and `docs/plan/open-points.md`, which lists what is still unsettled and who settles it.
- **GitHub.** The branches (`wp/…`, `spike/…`, `contract/…`), the pull requests and their descriptions.
- **The journal.** `journal.md` in the build folder, which sits outside every worktree. On the build Mac the build folder is `~/knot-build`. The journal has one line for each operation, written before it starts and again when it ends, with the base, the head and the tree where they apply. It holds no note text and no secrets.
- **The threads.** The package threads in T3 Code, and their worktrees, which `git worktree list` shows.

After a reset, read the last lines of the journal, list the open pull requests and the worktrees, and compare the three. Finish or undo an operation that was cut short before starting anything new. A release step that was cut short is never resumed: it goes back to Paolo.

## Launching a package

1. Read its rows in the start table of `PLAN.md` §6. Everything a row names has merged. A spike it names has its report merged and Paolo's confirmation.
2. Read `docs/plan/open-points.md` for the points to settle before that package starts. Settle them in the documents first, in a pull request of the orchestrator's own.
3. Write the launch in the journal.
4. Launch one top-level thread with `t3_thread_launch`: a worktree from `origin/main` on the branch `wp/<number>-<slug>`, the model `claude-opus-5-5`, and effort `high`, or `xhigh` for WP-10, WP-12 and WP-16. The first message is the prompt of `PLAN.md` Appendix B, followed by what the orchestrator has settled for the package and by what the build Mac has today.
5. Keep to five implementer threads at a time.

## When a thread hands back

The last line of its final message is `RESULT ok` or `RESULT blocked` with a code (`PLAN.md` §8.3).

- `RESULT ok`: arrange the review.
- `needs_owner` and `needs_hardware`: tell Paolo exactly what is needed, and resume the thread when he has done it.
- `needs_contract_change` and `needs_shared_file`: the orchestrator arranges the change, as `PLAN.md` §8.5 says.
- `brief_wrong`: correct the brief first, in a pull request of the orchestrator's own.
- `baseline_red` and `tool_failure`: find the cause before launching anything else on that base.

## Review

- A fresh reviewer thread reads the diff against the package's brief and `AGENTS.md`, with gstack `/review`.
- WP-02, WP-05, WP-06, WP-10, WP-11, WP-12, WP-15, WP-16 and WP-17 also get a second opinion from another model.
- The implementer fixes the findings. After two rounds the orchestrator decides what is left. It writes every finding it sets aside in the pull request and in the journal.

## The merge queue

One pull request at a time.

1. Rebase the branch on `main` and push it. A conflict goes back to the implementer.
2. Run the gate on that exact head, and write the result in the journal with the base, the head and the tree.
3. Squash-merge with `gh pr merge --squash --match-head-commit <head>`, with a subject and a body of the orchestrator's own, so that no session link enters the history.
4. Check that the tree on `main` is the tree that was tested. If `main` or the head moved in between, the result is void.
5. Remove the worktree and delete the branch.

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
