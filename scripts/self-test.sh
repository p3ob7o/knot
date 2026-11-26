#!/bin/bash
# The scripts' self-test, the named test scripts-self-test (docs/architecture.md §17).
# scripts/verify.sh --quick runs it.
#
#   scripts/self-test.sh
#
# It checks that a slot is released when its holder is killed, that a failure prints the
# agreed fields, and that the plan check catches a brief with a missing heading; then that
# the gate's helper reads a brief's paths and the depth table as the plan states them, what
# the team-ID check answers, and that the gate refuses a local configuration. It works in
# folders from mktemp, and changes nothing in the worktree.

source "$(dirname "$0")/lib/common.sh"

# The self-test checks the scripts, so every file it reads comes from the checkout the scripts
# come from, never from the tree that KNOT_TREE or --tree names: the plan, the fixtures'
# manifest, the pinned Xcode, the apps' manifests, project.yml and the nightly workflow. A
# trial of these scripts on another tree, or main's scripts on a candidate, then judges the
# scripts alone, whatever that tree holds (docs/dev-setup.md).
KNOT_SELF="$(cd "$KNOT_SCRIPTS/.." && pwd -P)"

FAILED=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
scratch="$(mktemp -d)"
# The folder is this script's own, from mktemp, so it removes it at the end.
trap 'rm -rf "$scratch"' EXIT

# 1. A slot is released when its holder is killed.
slots="$scratch/slots"
KNOT_SLOT_DIR="$slots" KNOT_BUILD_SLOTS=2 "$KNOT_SCRIPTS/build-slot.sh" run --label self-test -- sleep 120 &
runner=$!
holder=""
for _ in $(seq 1 50); do
    if [[ -s $slots/build-1.holder ]]; then
        holder="$(sed -E 's/^pid ([0-9]+),.*/\1/' "$slots/build-1.holder")"
        break
    fi
    sleep 0.1
done
if [[ -z $holder ]]; then
    fail "a slot is released when its holder is killed: the holder never took the slot"
else
    if /usr/bin/lockf -s -t 0 -k "$slots/build-1.lock" true; then
        fail "a slot is released when its holder is killed: the slot was free while held"
    else
        kill -9 "$holder"
        wait "$runner" 2>/dev/null || true
        if /usr/bin/lockf -s -t 0 -k "$slots/build-1.lock" true; then
            pass "a slot is released when its holder is killed"
        else
            fail "a slot is released when its holder is killed: still taken after kill -9"
        fi
    fi
fi
kill "$runner" 2>/dev/null || true

# 1b. A command that itself exits with lockf's status 75 runs once, and its status comes back.
count="$scratch/count-75"
status=0
KNOT_SLOT_DIR="$slots" KNOT_SLOT_TIMEOUT=5 KNOT_COUNT="$count" "$KNOT_SCRIPTS/build-slot.sh" run -- \
    sh -c 'echo ran >>"$KNOT_COUNT"; exit 75' 2>/dev/null || status=$?
if [[ $status == 75 && "$(wc -l <"$count" | tr -d ' ')" == 1 ]]; then
    pass "a command that exits with 75 runs once, and its 75 comes back"
else
    fail "a command that exits with 75: status $status, ran $(wc -l <"$count" 2>/dev/null | tr -d ' ') times"
fi

# 1c. A run that waited says how long it waited, when it gets the slot: not the wait and its
#     own run together, after the command has ended. One slot is open; its holder keeps it
#     3 s, and the waiter's command takes 6 s.
wait_slots="$scratch/wait-slots"
KNOT_SLOT_DIR="$wait_slots" KNOT_BUILD_SLOTS=2 "$KNOT_SCRIPTS/build-slot.sh" run --label holder -- sleep 3 &
waiting_holder=$!
for _ in $(seq 1 50); do [[ -s $wait_slots/build-1.holder ]] && break; sleep 0.1; done
KNOT_SLOT_DIR="$wait_slots" KNOT_BUILD_SLOTS=2 "$KNOT_SCRIPTS/build-slot.sh" run --label waiter -- sleep 6 2>"$scratch/waiter.err"
wait "$waiting_holder" 2>/dev/null || true
reported="$(sed -n -E 's/^build-slot: got a slot after ([0-9]+)s, at .*/\1/p' "$scratch/waiter.err")"
if [[ -n $reported ]] && ((reported >= 1 && reported <= 5)); then
    pass "a run that waited reports the wait alone, when it gets the slot"
else
    fail "a run that waited reported: $(cat "$scratch/waiter.err")"
fi

# 1d. The tree a script works on is never inherited from another checkout's scripts (item
#     108): two scratch checkouts, a and b. b's common.sh sourced by a command that a's
#     build-slot.sh runs refuses the tree that a's scripts exported, where before it built and
#     tested a silently. A command of a's own scripts takes a's tree; b's own build-slot.sh
#     gives b's; a tree named in the command's own environment is taken as named; and a tree
#     that --tree named, as the gate's in-step children inherit it, stands.
tc="$scratch/tree-checkouts"
for checkout in a b; do
    mkdir -p "$tc/$checkout"
    cp -R "$KNOT_SCRIPTS" "$tc/$checkout/scripts"
    cp "$KNOT_SELF/.xcode-version" "$tc/$checkout/"
done
tree_a="$(cd "$tc/a" && pwd -P)" tree_b="$(cd "$tc/b" && pwd -P)"
tree_of() { # tree_of <build-slot.sh's checkout> <common.sh's checkout> [env…]: the tree, or the refusal's code
    # The env words go to build-slot.sh; KNOT_SELF_TEST_NAME, when set, is a tree that the
    # command itself names, with KNOT_TREE_NAMED=1 beside it.
    local slot=$1 sourced=$2
    shift 2
    env -u KNOT_TREE -u KNOT_TREE_SET_BY -u KNOT_TREE_EXPORTED "$@" KNOT_SLOT_DIR="$tc/slots" \
        "$tc/$slot/scripts/build-slot.sh" run -- \
        bash -c 'if [[ -n ${KNOT_SELF_TEST_NAME:-} ]]; then export KNOT_TREE=$KNOT_SELF_TEST_NAME KNOT_TREE_NAMED=1; fi
            source "$1/scripts/lib/common.sh"; echo "tree $KNOT_ROOT"' _ "$tc/$sourced" 2>&1 |
        sed -n -E 's/^(tree .*|FAIL [a-z-]+)$/\1/p' | head -n 1 || true
}
inherited="$(tree_of a b)"
own_a="$(tree_of a a)"
own_b="$(tree_of b b)"
named_b="$(tree_of a b KNOT_SELF_TEST_NAME="$tree_a")"
gate_b="$(tree_of a a KNOT_TREE="$tree_b")"
if [[ $inherited == "FAIL knot-tree-inherited" && $own_a == "tree $tree_a" && $own_b == "tree $tree_b" &&
    $named_b == "tree $tree_a" && $gate_b == "tree $tree_b" ]]; then
    pass "a script refuses the tree that another checkout's scripts exported, and takes its own, a named one and the gate's"
else
    fail "the inherited tree: another checkout's '$inherited', its own '$own_a' and '$own_b', named '$named_b', the gate's '$gate_b'"
fi
# The plan check takes the tree as the other scripts do, though it sources no common.sh:
# started from inside b through a's build-slot.sh, with b's plan broken and a's whole, it
# checked a's plan and passed, and with --write would have written into it (the review of
# 30ec9092). Now it refuses that tree, and b's own build-slot.sh checks b's plan.
for checkout in a b; do
    mkdir -p "$tc/$checkout/docs"
    cp "$KNOT_SELF/PLAN.md" "$tc/$checkout/"
    cp -R "$KNOT_SELF/docs/plan" "$tc/$checkout/docs/"
done
sed -i '' '1,/^## /s/^## \(.*\)$/## \1, renamed/' "$tc/b/docs/plan/$(cd "$tc/b/docs/plan" && ls WP-*.md | head -n 1)"
plan_of() { # plan_of <build-slot.sh's checkout>: b's plan check's status and its FAIL code
    local status=0
    env -u KNOT_TREE -u KNOT_TREE_SET_BY -u KNOT_TREE_EXPORTED KNOT_SLOT_DIR="$tc/slots" \
        "$tc/$1/scripts/build-slot.sh" run -- "$tc/b/scripts/check-plan.sh" >"$tc/plan-$1.out" 2>&1 || status=$?
    echo "$status $(sed -n -E 's/^FAIL ([a-z-]+)$/\1/p' "$tc/plan-$1.out" | head -n 1)"
}
plan_through_a="$(plan_of a)"
plan_own="$(plan_of b)"
# And knot_tool.py, which reads the lists only the orchestrator edits from its scripts' folder,
# takes that folder from where it is, not from a KNOT_SCRIPTS that a's build-slot.sh exported.
lists_through_a="$(env -u KNOT_TREE -u KNOT_TREE_SET_BY -u KNOT_TREE_EXPORTED KNOT_SLOT_DIR="$tc/slots" \
    "$tc/a/scripts/build-slot.sh" run -- python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import knot_tool; print(knot_tool.SCRIPTS)' \
    "$tc/b/scripts/lib" 2>/dev/null | tail -n 1 || true)"
if [[ $plan_through_a == "1 knot-tree-inherited" && $plan_own == "1 plan-check" && $lists_through_a == "$tree_b/scripts" ]]; then
    pass "the plan check refuses the tree that another checkout's scripts exported, and checks its own; knot_tool.py reads its own lists"
else
    fail "the plan check's tree: through another checkout's build-slot.sh '$plan_through_a'; through its own '$plan_own'; knot_tool.py's lists, through another checkout's build-slot.sh, '$lists_through_a'"
fi

# 2. A failure prints the agreed fields: a code, what failed, the fix, whether a retry is
#    safe, and what was changed, and exits 1.
status=0
output="$(bash -c 'source "$1"; knot_fail "self-test-code" "what it was" "how to fix it" "safe" "nothing"' _ \
    "$KNOT_SCRIPTS/lib/fail.sh" 2>&1)" || status=$?
expected=$'FAIL self-test-code\n  what:    what it was\n  fix:     how to fix it\n  retry:   safe\n  changed: nothing'
if [[ $status == 1 && $output == "$expected" ]]; then
    pass "a failure prints the agreed fields and exits 1"
else
    fail "a failure prints the agreed fields: got status $status and: $output"
fi
output="$(bash -c 'source "$1"; knot_report "only-two" "fields" || true' _ "$KNOT_SCRIPTS/lib/fail.sh" 2>&1)"
if [[ $output == "FAIL infra-fail-usage"* ]]; then
    pass "a failure with fields missing is reported as infra-fail-usage"
else
    fail "a failure with fields missing: got $output"
fi

# 3. The plan check catches a brief with a missing heading, and passes on the plan as it is.
#    It runs on a copy of the real plan, which the plan step holds to the same check at every
#    depth, so a documents pull request cannot pass that and fail this; and it names no brief
#    or heading of the real plan: it renames the first heading of the first brief.
plan="$scratch/plan"
mkdir -p "$plan/docs" "$plan/scripts/lib"
cp "$KNOT_SELF/PLAN.md" "$plan/"
cp -R "$KNOT_SELF/docs/plan" "$plan/docs/"
cp "$KNOT_SCRIPTS/check-plan.sh" "$plan/scripts/"
cp "$KNOT_SCRIPTS/lib/fail.sh" "$KNOT_SCRIPTS/lib/tree.sh" "$plan/scripts/lib/"
if KNOT_TREE="$plan" "$plan/scripts/check-plan.sh" >"$scratch/plan-ok.log" 2>&1; then
    pass "the plan check passes on the plan as it is"
else
    fail "the plan check fails on an unchanged copy of the plan: $(tail -n 3 "$scratch/plan-ok.log")"
fi
renamed_brief="$(cd "$plan/docs/plan" && ls WP-*.md | head -n 1)"
sed -i '' '1,/^## /s/^## \(.*\)$/## \1, renamed/' "$plan/docs/plan/$renamed_brief"
status=0
KNOT_TREE="$plan" "$plan/scripts/check-plan.sh" >"$scratch/plan-bad.log" 2>&1 || status=$?
if [[ $status == 1 ]] && grep -e "$renamed_brief: its '##' headings must be exactly" "$scratch/plan-bad.log" >/dev/null &&
    grep -e "^FAIL plan-check" "$scratch/plan-bad.log" >/dev/null; then
    pass "the plan check catches a brief with a missing heading"
else
    fail "the plan check missed a brief with a missing heading (status $status)"
fi

# 3b. A row lettered past d, a pull request beside the planned ones, is a row: on fresh
#     copies of the real plan, a row 22y after WP-22d, in the brief and in PLAN.md's table,
#     passes; a row after WP-22z, which does not exist, is read and refused; and a row of two
#     letters, 22ab, is still no row label. The letters are y and z so that the case does not
#     meet a row the real plan holds: with 22e it failed on the tree that gave WP-22 its row
#     22e, a label twice.
lettered_plan() { # lettered_plan <name> <label> <starts after>: the check's status on a copy with that row added
    local copy="$scratch/plan-$1"
    mkdir -p "$copy/docs"
    cp -R "$plan/scripts" "$copy/"
    cp "$KNOT_SELF/PLAN.md" "$copy/"
    cp -R "$KNOT_SELF/docs/plan" "$copy/docs/"
    python3 -I - "$copy" "$2" "$3" <<'PY'
import sys
copy, label, after = sys.argv[1:]
for path, old, new in (
        (copy + "/docs/plan/WP-22.md", "| WP-22c |\n", "| WP-22c |\n| %s | A synthetic fifth row | %s |\n" % (label, after)),
        (copy + "/PLAN.md", "| WP-22c |\n", "| WP-22c |\n| WP-22 | %s | A synthetic fifth row | %s |\n" % (label, after))):
    text = open(path).read()
    assert text.count(old) == 1, (path, old)
    open(path, "w").write(text.replace(old, new))
PY
    local status=0
    KNOT_TREE="$copy" "$copy/scripts/check-plan.sh" >"$scratch/plan-$1.log" 2>&1 || status=$?
    echo "$status"
}
row_e="$(lettered_plan row-e 22y WP-22d)"
row_f="$(lettered_plan after-f 22y WP-22z)"
row_ab="$(lettered_plan row-ab 22ab WP-22d)"
if [[ $row_e == 0 && $row_f == 1 && $row_ab == 1 ]] && grep -e "WP-22z" "$scratch/plan-after-f.log" >/dev/null &&
    grep -e "'22ab' is not a row label" "$scratch/plan-row-ab.log" >/dev/null; then
    pass "the plan check takes a row lettered past d, reads a reference to one, and refuses two letters"
else
    fail "lettered rows: 22y status $row_e ($(grep -e FAIL -e "is not" "$scratch/plan-row-e.log" | head -n 2)), after WP-22z status $row_f, 22ab status $row_ab"
fi

# 4. The gate's helper reads the plan as it states it. It reads a fixture plan of the
#    self-test's own and pins nothing of the real one (item 104): a documents pull request
#    that changes a brief's rows passes the gate at the documents depth, which does not run
#    the self-test, so a check that read the real briefs failed only later, on the hosted
#    runner. The fixture holds the forms the helper reads: a start table with notes and
#    lettered rows, an Owns list with an 'except' clause, a part of a file, and a spike's
#    branch. The real plan is the plan step's, at every depth.
fp="$scratch/fixture-plan"
mkdir -p "$fp/docs/plan"
fixture_brief() { # fixture_brief <ID> <owns lines> <start table rows, one a line>
    {
        printf '# %s\n\n## Owns\n\n%s\n\n## Starts after\n\n| PR | After |\n|---|---|\n' "$1" "$2"
        while IFS= read -r row; do printf '| %s | before |\n' "$row"; done <<<"$3"
    } >"$fp/docs/plan/$1.md"
}
fixture_brief WP-00 '- `docs/architecture.md`' 'Notes'
fixture_brief WP-01 '- `scripts/`, except `scripts/release.sh`' '1'
fixture_brief WP-02 '- `Packages/KnotKit/Sources/KnotFakes/`, except its `Preview/` folder' $'1\n2\n3'
fixture_brief WP-06 '- the soak step of `scripts/verify.sh`' '1'
fixture_brief WP-10 '- `Packages/KnotKit/Sources/KnotStore/`' '1'
fixture_brief WP-11 '- `Packages/KnotKit/Sources/KnotCapture/`' $'1\n11a\n2\n3\n4'
fixture_brief WP-22 '- `Packages/KnotKit/Sources/KnotApp/`' $'1\n22a\n2\n22d\n22e'
fixture_brief WP-14 '- `Packages/KnotKit/Sources/KnotCleanup/`' $'Proof step\n1'
fixture_brief WP-40 '- `Packages/KnotKit/Sources/KnotSync/`' $'Proof step\n40a\n40b\n40c\n40d'
fixture_brief SP-1 '- `spike/locked-recording`' 'Notes'
cd "$fp"
# The helper comes from the scripts' own folder; the plan it reads, from the fixture.
if python3 -I -B - "$KNOT_SCRIPTS/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import knot_tool as k
owned, excluded, parts = k.owned_paths("WP-01")
assert "scripts/" in owned and "scripts/release.sh" in excluded, (owned, excluded)
assert "scripts/verify.sh" not in excluded, excluded       # "the soak step of scripts/verify.sh" is a part
assert k.package_of_branch("wp/01-tooling") == "WP-01"
assert k.package_of_branch("origin/wp/10-store") == "WP-10"
assert k.package_of_branch("contract/ports") == "contract"
# A pull request beside the planned ones, lettered, is its number's package; wp/13-note stays
# WP-13's note, and anything else between the number and the dash names no package.
assert k.package_of_branch("wp/06b-done-line") == "WP-06", k.package_of_branch("wp/06b-done-line")
assert k.package_of_branch("origin/wp/22d-mac-tool") == "WP-22"
assert k.package_of_branch("wp/13-note") == "WP-13" and k.is_note_branch("wp/13-note")
assert not k.is_note_branch("wp/13b-note")
assert k.package_of_branch("wp/06B-x") is None and k.package_of_branch("wp/06bc-x") is None
assert k.package_of_branch("wp/06b") is None and k.package_of_branch("wp/6-x") == "WP-06"
# A fifth lettered row counts toward its package: four merged of five, then all of them.
assert k.plan_rows("WP-22") == ["1", "22a", "2", "22d", "22e"], k.plan_rows("WP-22")
assert k.merge_state("WP-22", [("WP-22", False)] * 4) == (4, 5)
assert k.package_of_branch("wp/22e-fifth") == "WP-22"
assert k.merge_state("WP-22", [("WP-22", False)] * 5) == (5, 5)
assert k.classify(["docs/architecture.md", "PLAN.md"])[0] == "documents"
assert k.classify(["Packages/KnotKit/Sources/KnotSpeech/Transcriber.swift"])[0] == "leaf"
assert k.classify(["Packages/KnotKit/Sources/KnotStore/Store.swift"])[0] == "everything"
assert k.classify(["Something/New.txt"])[0] == "everything"
assert k.classify(["Packages/KnotKit/Sources/KnotStore/Store.swift"])[2] is True       # the soak
assert k.classify(["Packages/KnotKit/Sources/KnotSpeech/Transcriber.swift"])[2] is False
assert k.classify(["Apps/macOS/Sources/KnotMacApp.swift"])[3] is True                  # Mac UI tests
assert k.classify(["Packages/KnotKit/Sources/KnotAudio/Recorder.swift"])[5] is True   # the recorder in the iOS Simulator
assert k.classify(["Packages/KnotKit/Sources/KnotAudioCrashHost/KillTest.swift"])[5] is True
assert k.classify(["Packages/KnotKit/Sources/KnotStore/Store.swift"])[5] is False
# The Mac UI step itself and a new Xcode pin reach the Mac UI tests (review of PR 38).
assert k.classify(["scripts/verify.sh"])[3] is True, "scripts/ reaches the Mac UI tests"
assert k.classify([".xcode-version"])[3] is True, ".xcode-version reaches the Mac UI tests"
assert k.classify(["scripts/gate-steps.txt"])[3] is True, "gate-steps.txt alone reaches the Mac UI tests"
assert k.classify([".github/workflows/verify.yml"])[3] is True, "the workflow that runs the Mac UI tests on the hosted runner reaches them"
assert k.classify([".github/workflows/nightly.yml"])[3] is False
# The accessibility audit that every UI test calls, WP-21's (finding 35).
assert k.classify(["Apps/UITestSupport/Audit.swift"])[3] is True, "Apps/UITestSupport/ reaches the Mac UI tests"
assert k.classify(["Packages/KnotKit/Sources/KnotInk/Recogniser.swift"])[4] is True     # the hosted suites
assert k.classify(["Packages/KnotKit/Sources/KnotSpeech/Transcriber.swift"])[4] is False
assert k.matches("scripts/verify.sh", "scripts/") and not k.matches("scriptsx/a", "scripts/")
# Every row of a brief's start table is a pull request, notes included (blocker 1 of PR 20).
assert k.plan_rows("WP-14") == ["Proof step", "1"], k.plan_rows("WP-14")
assert k.plan_rows("WP-40")[1:] == ["40a", "40b", "40c", "40d"], k.plan_rows("WP-40")
assert k.is_note_branch("wp/14-note") and k.is_note_branch("spike/locked-recording-note")
assert not k.is_note_branch("wp/14-cleaner")
assert k.merge_state("WP-14", [("WP-14", True)]) == (1, 2)
assert not k.has_merged("WP-14", [("WP-14", True)])
assert k.has_merged("WP-14", [("WP-14", True), ("WP-14", False)])
assert k.package_of_branch("spike/locked-recording-note") == "SP-1"
# An 'except' path is resolved against the folder its line owns (fix 3).
owned, excluded, parts = k.owned_paths("WP-02")
assert "Packages/KnotKit/Sources/KnotFakes/Preview/" in excluded, excluded
# A part of a file: WP-06 owns the soak step of scripts/verify.sh, not the file (fix 5).
owned, excluded, parts = k.owned_paths("WP-06")
assert ("scripts/verify.sh", "soak") in parts and "scripts/verify.sh" not in owned, (owned, parts)
text = "a\n# ---- The soak step. It belongs to WP-06\nb\n# ---- End of the soak step.\nc\n"
assert k.part_markers(text, "soak") == (2, 4), k.part_markers(text, "soak")
# Who may change KnotCore's public API (item 8 of the run on pull request 22).
assert len(k.plan_rows("WP-02")) == 3, k.plan_rows("WP-02")
assert k.core_api_exemption("WP-02", [("WP-02", False)]), "WP-02 with one of three merged"
assert k.core_api_exemption("WP-02", [("WP-02", False)] * 2), "WP-02's last pull request under test"
assert k.core_api_exemption("WP-02", [("WP-02", False)] * 3) is None, "WP-02 with all three merged"
assert k.core_api_exemption("WP-10", []) is None, "another package"
assert k.core_api_exemption("contract", [("WP-02", False)] * 3), "a contract branch"
# A named test given to a pull request is required once that pull request has merged
# (finding 23): WP-11 plans several, and its last is held. One given to no pull request waits
# for the package's last, as before, however many the brief plans: the count is read from
# the brief, so that a package cut into more pull requests does not fail this check.
assert k.named_test_pr("WP-11", "WP-11 PR 2 adds one file of kill points to the soak") == "2"
assert k.named_test_pr("WP-11 PR 1", "A late draft save") == "1"
assert k.named_test_pr("WP-11", "A late draft save") is None
one = [("WP-11", False)]
assert k.named_test_required("WP-11", "1", one) and not k.named_test_required("WP-11", "2", one)
assert not k.named_test_required("WP-11", None, one)
# Where the brief puts its pull request "2" among its rows is read from the brief too: a row
# for a pull request beside the planned ones may stand before it.
rows = [row for row in k.plan_rows("WP-11") if row not in k.NOTE_ROWS]
second = rows.index("2") + 1
planned = len(rows)
assert planned >= 3 and second < planned, rows
assert not k.named_test_required("WP-11", "2", one * (second - 1))
assert k.named_test_required("WP-11", "2", one * second) and not k.named_test_required("WP-11", None, one * second)
assert not k.named_test_required("WP-11", None, one * (planned - 1))
assert k.named_test_required("WP-11", None, one * planned)
# And the command holds to it (finding 41): named-tests itself, with a given list of merged
# pull requests, on a list of made-up tests that no code holds. At WP-11's first pull request
# the test given to it is required and missing, and the others wait; at its pull request "2",
# where the brief puts it, the test given to that one joins it, and the package's own still
# waits; at its last, every one is required.
import contextlib, io, os, tempfile
with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as named:
    named.write("# made-up tests\n"
                "WP-11 PR 1\tselftest-given-to-pr-one\tA test the first pull request holds\n"
                "WP-11\tselftest-given-to-pr-two\tWP-11 PR 2 adds a test the second holds\n"
                "WP-11\tselftest-given-to-package\tA test for the package's end\n"
                "WP-14 PR 1\tselftest-given-to-wp14-pr-one\tA test WP-14's first code pull request holds\n")
k.NAMED_TESTS, k.code_text = named.name, dict
def named_missing(branch, merged, package="WP-11"):
    k.merged_prs = lambda source: list(merged)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        status = k.cmd_named_tests("git", package, branch)
    return status, sorted(w.rstrip(",") for w in out.getvalue().split() if w.startswith("selftest-"))
assert named_missing("wp/11-engine", []) == (1, ["selftest-given-to-pr-one"]), named_missing("wp/11-engine", [])
assert named_missing("wp/11-engine-2", one * (second - 1)) == (1, ["selftest-given-to-pr-one", "selftest-given-to-pr-two"])
assert named_missing("wp/11-engine-last", one * (planned - 1))[1] == ["selftest-given-to-package",
                                                                     "selftest-given-to-pr-one", "selftest-given-to-pr-two"]
# A note's branch is not the package's code (41b): WP-14's proof step under test leaves the
# test given to its first code pull request waiting, and that pull request's branch, after
# the note, requires it.
assert named_missing("wp/14-note", [], "WP-14") == (0, []), named_missing("wp/14-note", [], "WP-14")
assert named_missing("wp/14-cleaner", [("WP-14", True)], "WP-14") == (1, ["selftest-given-to-wp14-pr-one"])
os.unlink(named.name)
# The orchestrator's lines of scripts/ownership-extra.txt, which are the scripts' own: the
# error catalog's document passes to the orchestrator once WP-02 has merged (item 89).
owned, excluded, parts = k.owned_paths("WP-00")
assert "docs/errors.md" in owned, owned
# A path that no brief owns falls to WP-00 (blocker 2).
assert k.owners_of("README.md") == [] and "WP-01" in k.owners_of("scripts/verify.sh")
PY
then
    pass "the gate's helper reads a brief's paths, the branches and the depth table"
else
    fail "the gate's helper does not read the plan as it states it"
fi

# 5. The lint catches every case of its fixture, scripts/lint-cases/Cases.swift, and lets its
#    harmless lines pass: each "expect: <rule>" line must be answered by a finding of that
#    rule on the next line, and each "expect: nothing" line by none. The fixture is linted
#    from a folder named "Copies 2", so the folder-name rule is tested too, and against a
#    privacy manifest of the self-test's own, which declares only the defaults reason: the
#    verdict must not rest on the tree's manifests, which packages go on changing.
copies="$scratch/Copies 2"
mkdir -p "$copies"
cp "$KNOT_SCRIPTS/lint-cases/Cases.swift" "$copies/Cases.swift"
fixture_manifest="$scratch/FixturePrivacyInfo.xcprivacy"
cat >"$fixture_manifest" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array><string>1C8F.1</string></array>
		</dict>
	</array>
</dict>
</plist>
XML
lint_fixture() {
    # lint_fixture <folder to run from> <output>: the fixture's lint, from that folder.
    (cd "$1" && python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" lint --files "$copies/Cases.swift" \
        --as Apps/Extensions/Widgets-iOS/Sources/ --manifest "$fixture_manifest" >"$2") || true
}
lint_fixture "$KNOT_SELF" "$scratch/lint.out"
if python3 -I - "$copies/Cases.swift" "$scratch/lint.out" <<'PY'
import re, sys
fixture, output = sys.argv[1], open(sys.argv[2]).read()
found = {(int(m.group(1)), m.group(2)) for m in re.finditer(r":(\d+): \[([\w-]+)\]", output)}
flagged = {number for number, _ in found}
expected, clean = [], []
for number, line in enumerate(open(fixture), 1):
    m = re.match(r"^// expect: ([\w-]+)$", line.strip())
    if m and m.group(1) == "nothing":
        clean.append(number + 1)
    elif m:
        expected.append((number + 1, m.group(1)))
missed = [case for case in expected if case not in found]
wrong = [number for number in clean if number in flagged]
copy = "[copy-file]" in output
for number, rule in missed:
    print(f"      missed: line {number}, {rule}")
for number in wrong:
    print(f"      flagged, though it must pass: line {number}")
if not copy:
    print('      missed: the folder named "Copies 2"')
print(f"      caught {len(expected) - len(missed) + (1 if copy else 0)} of {len(expected) + 1} cases, "
      f"and let {len(clean) - len(wrong)} of {len(clean)} harmless lines pass")
sys.exit(1 if missed or wrong or not copy else 0)
PY
then
    pass "the lint catches every case of its fixture, and lets its harmless lines pass"
else
    fail "the lint misses or wrongly flags cases of its fixture: $(tail -n 1 "$scratch/lint.out")"
fi

# 5a. The lint reads the package's tests for its cancel rule (finding 64): a whole run, not
#     a fixture, on a scratch repository whose one Swift file is a package test that cancels
#     itself, beside copies of the apps' manifests, finds it.
lt="$scratch/lint-tests"
mkdir -p "$lt/Packages/KnotKit/Tests/SelfTestTests"
git -C "$lt" init -q -b main
for manifest in Apps/iOS Apps/macOS Apps/watchOS Apps/Extensions/Widgets-iOS Apps/Extensions/Widgets-watchOS; do
    mkdir -p "$lt/$manifest"
    cp "$KNOT_SELF/$manifest/PrivacyInfo.xcprivacy" "$lt/$manifest/"
done
printf 'import Testing\n\n@Test func needsAModel() throws {\n    try Test.cancel("the model is not on this Mac")\n}\n' \
    >"$lt/Packages/KnotKit/Tests/SelfTestTests/Cancels.swift"
(cd "$lt" && python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" lint >"$lt/out" 2>&1) || true
if grep -e 'Packages/KnotKit/Tests/SelfTestTests/Cancels.swift:4: \[test-cancel\]' "$lt/out" >/dev/null; then
    pass "the lint reads the package's tests, and finds a test that cancels itself"
else
    fail "the lint on a package test that cancels itself: $(tail -n 3 "$lt/out")"
fi

# 5b. The fixture's verdict is the same when the tree's manifests change: run again from a
#     copy whose real manifests declare every required reason, the findings must not move.
manifests="$scratch/manifests"
for manifest in Apps/iOS Apps/macOS Apps/watchOS Apps/Extensions/Widgets-iOS Apps/Extensions/Widgets-watchOS; do
    mkdir -p "$manifests/$manifest"
    python3 -I - "$KNOT_SELF/$manifest/PrivacyInfo.xcprivacy" "$manifests/$manifest/PrivacyInfo.xcprivacy" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    manifest = plistlib.load(f)
manifest["NSPrivacyAccessedAPITypes"] = [
    {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + category, "NSPrivacyAccessedAPITypeReasons": [reason]}
    for category, reason in [("UserDefaults", "CA92.1"), ("FileTimestamp", "C617.1"), ("SystemBootTime", "35F9.1"),
                             ("DiskSpace", "E174.1"), ("ActiveKeyboards", "3EC4.1")]]
with open(sys.argv[2], "wb") as f:
    plistlib.dump(manifest, f)
PY
done
lint_fixture "$manifests" "$scratch/lint-changed.out"
if [[ -s $scratch/lint.out ]] && diff "$scratch/lint.out" "$scratch/lint-changed.out" >/dev/null; then
    pass "the fixture's verdict does not move when the tree's manifests gain every reason"
else
    fail "the fixture's verdict moved with the tree's manifests"
fi

# The team-ID check passes on a clean tree, finds an ID that a tracked file holds, and
# exits 3, which counts as skipped, when there is no configuration to read. The ID here is
# made up.
team_repo="$scratch/team-repo"
mkdir -p "$team_repo"
git -C "$team_repo" init --quiet
printf 'KNOT_SIGNING = team\nDEVELOPMENT_TEAM = SELFTEST01\n' >"$scratch/Team.xcconfig"
printf 'nothing to find\n' >"$team_repo/clean.txt"
git -C "$team_repo" add clean.txt
team_id_status() {
    local status=0
    (cd "$team_repo" && python3 "$KNOT_SCRIPTS/lib/knot_tool.py" team-id --team-config "$1") >/dev/null 2>&1 || status=$?
    echo "$status"
}
clean="$(team_id_status "$scratch/Team.xcconfig")"
printf 'DEVELOPMENT_TEAM = SELFTEST01\n' >"$team_repo/leak.txt"
git -C "$team_repo" add leak.txt
leaked="$(team_id_status "$scratch/Team.xcconfig")"
absent="$(team_id_status "$scratch/no-such.xcconfig")"
if [[ $clean == 0 && $leaked == 1 && $absent == 3 ]]; then
    pass "the team-ID check passes, finds a tracked ID, and is skipped without a configuration"
else
    fail "the team-ID check: clean $clean, a tracked ID $leaked, no configuration $absent"
fi

# The gate refuses a local configuration, which would give its builds settings that no
# other run has, and a refused gate leaves no earlier run's status line behind. The gate
# runs on a tree of its own here, so that it removes nothing in the worktree.
gate_tree="$scratch/gate-tree"
mkdir -p "$gate_tree/.build/logs"
printf 'gate everything ok: an earlier run\n' >"$gate_tree/.build/logs/verify-status.txt"
status=0
output="$(KNOT_LOCAL_CONFIG="$scratch/Team.xcconfig" "$KNOT_SCRIPTS/verify.sh" --gate --package WP-00 --tree "$gate_tree" 2>&1)" || status=$?
if [[ $status == 1 && $output == *"FAIL verify-gate-local-config"* && ! -e $gate_tree/.build/logs/verify-status.txt ]]; then
    pass "the gate refuses KNOT_LOCAL_CONFIG, and leaves no earlier status line"
else
    fail "the gate with KNOT_LOCAL_CONFIG set: status $status, earlier line $(ls "$gate_tree/.build/logs"), and: $output"
fi

# On a detached head the gate needs the branch, which tells a note's pull request from a code
# one: it refuses --package alone, and with neither it asks for --branch, not for either.
# The scratch tree has no branch to read, as a detached head has none, and the tree's pin.
cp "$KNOT_SELF/.xcode-version" "$gate_tree/"
status_package=0
output_package="$("$KNOT_SCRIPTS/verify.sh" --gate --package WP-01 --tree "$gate_tree" 2>&1)" || status_package=$?
status_none=0
output_none="$("$KNOT_SCRIPTS/verify.sh" --gate --tree "$gate_tree" 2>&1)" || status_none=$?
if [[ $status_package == 1 && $output_package == *"needs the branch, --branch <name>"* &&
    $status_none == 1 && $output_none == *"needs the branch, --branch <name>"* && $output_none != *" or --branch"* ]]; then
    pass "on a detached head the gate refuses --package alone, and asks for --branch"
else
    fail "the gate without --branch: status $status_package and $status_none, and: $output_package / $output_none"
fi

# The Mac UI readiness check reads the second line of automationmodetool, which says whether
# turning Automation Mode on needs authentication, and the whole phrase "currently enabled"
# of DevToolsSecurity, since "disabled" holds "enabled". The samples are the two tools'
# answers on this Mac before and after the owner's commands.
ready_off=$'Automation Mode is disabled.\nThis device DOES NOT REQUIRE user authentication to enable Automation Mode.'
ready_needs=$'Automation Mode is disabled.\nThis device requires user authentication to enable Automation Mode.'
developer_on="Developer mode is currently enabled."
developer_off="Developer mode is currently disabled."
cases=0
knot_mac_ui_ready "$ready_off" "$developer_on" >/dev/null && cases=$((cases + 1))
knot_mac_ui_ready "$ready_needs" "$developer_on" >/dev/null || cases=$((cases + 1))
knot_mac_ui_ready "$ready_off" "$developer_off" >/dev/null || cases=$((cases + 1))
knot_mac_ui_ready "$ready_needs" "$developer_off" >/dev/null || cases=$((cases + 1))
if ((cases == 4)); then
    pass "the Mac UI check reads the authentication line and developer mode, not the mode of the moment"
else
    fail "the Mac UI check judged $cases of 4 samples right"
fi

# Starting a tool that a system dialog holds ends at its time limit, with a message for the
# owner on standard error, instead of hanging the run. Each case is shaped like the packaging
# step's call, which compares the standard output with the version line: a tool that only
# sleeps, one that answers with a harmless line on standard error, and one that ignores TERM.
printf '#!/bin/sh\nsleep 30\n' >"$scratch/hanging-tool"
printf '#!/bin/sh\necho "a harmless note" >&2\necho "knot-dev 1.0 (dev)"\n' >"$scratch/noisy-tool"
printf '#!/bin/bash\ntrap "" TERM\nwhile :; do sleep 0.2; done\n' >"$scratch/stubborn-tool"
chmod +x "$scratch/hanging-tool" "$scratch/noisy-tool" "$scratch/stubborn-tool"
answers() { [[ "$(knot_start_tool "$1" "$2" --version)" == "knot-dev 1.0 (dev)" ]]; }
started=$(knot_now)
status=0
answers 1 "$scratch/hanging-tool" 2>"$scratch/hanging.err" || status=$?
if [[ $status == 1 && "$(cat "$scratch/hanging.err")" == *"system dialog"* && $(($(knot_now) - started)) -lt 10 ]]; then
    pass "a tool that does not answer ends at its time limit, naming a system dialog where the log gets it"
else
    fail "a tool that does not answer: status $status after $(($(knot_now) - started))s, standard error: $(cat "$scratch/hanging.err")"
fi
if answers 5 "$scratch/noisy-tool" 2>"$scratch/noisy.err" && [[ "$(cat "$scratch/noisy.err")" == "a harmless note" ]]; then
    pass "a tool's line on standard error neither fails the version check nor is lost"
else
    fail "a tool with a line on standard error failed the check, or the line was lost: $(cat "$scratch/noisy.err")"
fi
started=$(knot_now)
status=0
answers 1 "$scratch/stubborn-tool" 2>/dev/null || status=$?
if [[ $status == 1 && $(($(knot_now) - started)) -lt 10 ]] && ! pgrep -f "$scratch/stubborn-tool" >/dev/null; then
    pass "a tool that ignores TERM is killed"
else
    fail "a tool that ignores TERM: status $status after $(($(knot_now) - started))s"
    pkill -KILL -f "$scratch/stubborn-tool" || true
fi

# A limit on a shell function, as ui_tests puts on xcb, gives the processes inside it the
# same two seconds after TERM: the function's own subshell dies at once, so the wait must
# watch the whole family. The child here cleans up for half a second on TERM, inside a
# pipeline, as xcodebuild ends its test session.
printf '#!/bin/bash\ntrap "sleep 0.5; echo cleaned >\"\$1\"; exit 0" TERM\nwhile :; do sleep 0.1; done\n' >"$scratch/tidy-tool"
chmod +x "$scratch/tidy-tool"
piped() { "$scratch/tidy-tool" "$scratch/tidy.done" | cat; }
status=0
knot_limit 1 piped >/dev/null 2>&1 || status=$?
if [[ $status == 124 && "$(cat "$scratch/tidy.done" 2>/dev/null)" == cleaned ]]; then
    pass "a limit on a shell function gives its processes their time after TERM"
else
    fail "a limit on a shell function: status $status, and the child's clean-up did not finish"
    pkill -KILL -f "$scratch/tidy-tool" || true
fi

# Every start the scripts wait for has a limit, shaped like its call site: a run of hosted
# tests (knot_run_limited), a simctl call (knot_sim_call) and the Mac app's start
# (knot_start_app). For each, a stub that hangs ends at a short limit with its message, a
# stub that passes is not slowed, and a status other than zero still fails. The timings
# allow 10 s, room for a loaded Mac: a missing limit shows as 15 s or more, since the
# stubs hang for 30 and a probe has 15.
lim="$scratch/limits"
mkdir -p "$lim"
printf '#!/bin/sh\nsleep 30\n' >"$lim/hangs"
printf '#!/bin/sh\nexit 0\n' >"$lim/passes"
printf '#!/bin/sh\nexit 65\n' >"$lim/fails"
printf '#!/bin/sh\nexit 1\n' >"$lim/quits"
printf '#!/bin/sh\n' >"$lim/no-window"
printf '#!/bin/sh\necho "$1 layer 0 320x240"\n' >"$lim/a-window"
chmod +x "$lim"/*
# timed <name> <command…>: runs the command, keeping its status, output and seconds.
timed() {
    local name=$1 start
    shift
    start=$(knot_now)
    eval "${name}_status=0"
    "$@" >"$lim/$name.out" 2>&1 || eval "${name}_status=\$?"
    eval "${name}_seconds=$(($(knot_now) - start))"
}
timed hosted_hang knot_run_limited "The hosted iOS tests" 1 "$lim/hangs"
timed hosted_pass knot_run_limited "The hosted iOS tests" 30 "$lim/passes"
timed hosted_fail knot_run_limited "The hosted iOS tests" 30 "$lim/fails"
if [[ $hosted_hang_status == 124 && "$(cat "$lim/hosted_hang.out")" == *"system dialog"* && $hosted_hang_seconds -lt 10 &&
    $hosted_pass_status == 0 && $hosted_pass_seconds -lt 10 && $hosted_fail_status == 65 ]]; then
    pass "a run of hosted tests ends at its limit naming a dialog, is not slowed when it passes, and keeps its status"
else
    fail "hosted tests: hang $hosted_hang_status in ${hosted_hang_seconds}s, pass $hosted_pass_status in ${hosted_pass_seconds}s, fail $hosted_fail_status: $(cat "$lim/hosted_hang.out")"
fi
timed sim_hang knot_sim_call 1 launch set-iphone "$lim/hangs"
timed sim_pass knot_sim_call 30 launch set-iphone "$lim/passes"
timed sim_fail knot_sim_call 30 launch set-iphone "$lim/fails"
if [[ $sim_hang_status == 1 && "$(cat "$lim/sim_hang.out")" == *"set-iphone did not end within 1s"* && $sim_hang_seconds -lt 10 &&
    $sim_pass_status == 0 && $sim_pass_seconds -lt 10 &&
    $sim_fail_status == 1 && "$(cat "$lim/sim_fail.out")" == *"set-iphone failed with status 65"* ]]; then
    pass "a simctl call ends at its limit naming the simulator, is not slowed when it passes, and fails on its status"
else
    fail "simctl calls: hang $sim_hang_status in ${sim_hang_seconds}s, pass $sim_pass_status in ${sim_pass_seconds}s, fail $sim_fail_status: $(cat "$lim/sim_hang.out" "$lim/sim_fail.out")"
fi
timed app_hang knot_start_app 2 "$lim/hangs" "$lim/no-window"
hang_left="$(pgrep -f "$lim/hangs" || true)"
timed app_pass knot_start_app 30 "$lim/hangs" "$lim/a-window"
pass_left="$(pgrep -f "$lim/hangs" || true)"
timed app_fail knot_start_app 30 "$lim/quits" "$lim/no-window"
# The start ends the app it started, and says so in its own words; bash's notice of the job
# it ended, which names this script by its path, reaches no log (item 4 of the eighth list).
if [[ $app_hang_status == 1 && "$(cat "$lim/app_hang.out")" == *"no window within 2s"*"system dialog"* && $app_hang_seconds -lt 10 &&
    -z $hang_left && $app_pass_status == 0 && $app_pass_seconds -lt 10 && -z $pass_left &&
    $app_fail_status == 1 && "$(cat "$lim/app_fail.out")" == *"exited with status 1"* &&
    "$(cat "$lim/app_pass.out")" == *"ended hangs, which it started"* &&
    "$(cat "$lim/app_pass.out" "$lim/app_hang.out")" != *"Terminated"* ]]; then
    pass "the Mac app's start ends at its limit naming a dialog, is not slowed by a window, fails when it quits, leaves nothing running, and says that it ended the app with no notice of bash's"
else
    fail "the app's start: hang $app_hang_status in ${app_hang_seconds}s (left: $hang_left), window $app_pass_status in ${app_pass_seconds}s (left: $pass_left), quit $app_fail_status: $(cat "$lim/app_hang.out" "$lim/app_fail.out")"
fi
pkill -KILL -f "$lim/hangs" 2>/dev/null || true

# The app's start says why it failed: a probe that cannot run is no system dialog, and what
# the app writes to standard error reaches the step's log.
printf '#!/bin/sh\necho "the probe cannot run" >&2\nexit 1\n' >"$lim/broken-probe"
printf '#!/bin/sh\necho "the app says something" >&2\ntouch "%s/talked"\nsleep 30\n' "$lim" >"$lim/talks"
# The window comes once the app has written its line: the probe waits for the app's sign,
# so the case cannot race.
printf '#!/bin/sh\nfor i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do\n    [ -e "%s/talked" ] && break\n    sleep 0.25\ndone\necho "$1 layer 0 320x240"\n' "$lim" >"$lim/a-later-window"
chmod +x "$lim/broken-probe" "$lim/talks" "$lim/a-later-window"
timed app_probe knot_start_app 2 "$lim/hangs" "$lim/broken-probe"
timed app_talks knot_start_app 30 "$lim/talks" "$lim/a-later-window"
probe_message="$(cat "$lim/app_probe.out")"
if [[ $app_probe_status == 1 && $probe_message == *"probe"*"status 1"*"the probe cannot run"* && $probe_message != *"system dialog"* &&
    $app_talks_status == 0 && "$(cat "$lim/app_talks.out")" == *"the app says something"* ]]; then
    pass "the app's start tells a probe that cannot run from a window that has not come, and keeps the app's errors"
else
    fail "the app's start with a broken probe: $app_probe_status, $probe_message; with an app that talks: $app_talks_status, $(cat "$lim/app_talks.out")"
fi
pkill -KILL -f "$lim/hangs" 2>/dev/null || true
pkill -KILL -f "$lim/talks" 2>/dev/null || true

# The app's standard error reaches the caller through a file, printed after the start: a
# process the app starts that leaves its family keeps the app's standard error, and must not
# hold the caller's pipe. Here it holds it for 20 s; the start, piped, ends in a few.
# The app's child has left once the app touches its sign; the probe waits for the sign.
printf '#!/bin/sh\n( sleep 20 >&2 & )\ntouch "%s/left"\nsleep 30\n' "$lim" >"$lim/leaves"
printf '#!/bin/sh\nfor i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do\n    [ -e "%s/left" ] && break\n    sleep 0.25\ndone\necho "$1 layer 0 320x240"\n' "$lim" >"$lim/after-it-left"
chmod +x "$lim/leaves" "$lim/after-it-left"
piped_started=$(knot_now)
{ knot_start_app 30 "$lim/leaves" "$lim/after-it-left" 2>&1 | cat >/dev/null; } || true
piped_seconds=$(($(knot_now) - piped_started))
if ((piped_seconds < 8)); then
    pass "the app's standard error reaches the caller through a file, so a child that leaves holds no pipe"
else
    fail "the app's start, piped, waited ${piped_seconds}s for a child the app left behind"
fi
pkill -KILL -f "$lim/leaves" 2>/dev/null || true

# The app's start keeps to its own limit, whatever the probe does: a probe that never
# answers is cut at the time left, not after its own 15 seconds.
printf '#!/bin/sh\nsleep 30\n' >"$lim/silent-probe"
chmod +x "$lim/silent-probe"
timed app_silent knot_start_app 2 "$lim/hangs" "$lim/silent-probe"
if [[ $app_silent_status == 1 && $app_silent_seconds -lt 10 && "$(cat "$lim/app_silent.out")" == *"did not answer"* ]]; then
    pass "the app's start keeps to its limit when the probe does not answer"
else
    fail "the app's start with a probe that never answers: status $app_silent_status after ${app_silent_seconds}s (limit 2s): $(cat "$lim/app_silent.out")"
fi
pkill -KILL -f "$lim/hangs" 2>/dev/null || true
pkill -KILL -f "$lim/silent-probe" 2>/dev/null || true

# A step that runs the package's tests has an outer limit (knot_swift_test_limited): a test
# that hangs ends at it, and the failure names the step and says nothing of a dialog; a run
# that passes is not slowed; a failing run keeps its status.
timed swift_hang env KNOT_SWIFT_TEST_LIMIT=1 bash -c 'source "$1"; knot_swift_test_limited package-test "$2"' _ \
    "$KNOT_SCRIPTS/lib/common.sh" "$lim/hangs"
timed swift_pass knot_swift_test_limited package-test "$lim/passes"
timed swift_fail knot_swift_test_limited package-test "$lim/fails"
swift_message="$(cat "$lim/swift_hang.out")"
if [[ $swift_hang_status == 124 && $swift_message == *"The step package-test did not end"* && $swift_message != *dialog* &&
    $swift_hang_seconds -lt 10 && $swift_pass_status == 0 && $swift_pass_seconds -lt 10 && $swift_fail_status == 65 ]]; then
    pass "a step of package tests ends at its limit naming the step, is not slowed when it passes, and keeps its status"
else
    fail "package tests under their limit: hang $swift_hang_status in ${swift_hang_seconds}s, pass $swift_pass_status, fail $swift_fail_status: $swift_message"
fi
# The release scan finds a fake that lives outside KnotFakes, by its name: a type of a Knot
# module named Fake…, matched demangled, since Swift abbreviates it in the mangled name, in
# every form a fake's symbols take: public, nested, private and fileprivate, local, and
# nested in an extension of a type from outside the project. A made-up KnotLink holds them
# under the guard; it is compiled once with KNOT_FAKES and once without, unoptimised, which
# keeps every symbol. The old scan, for the KnotFakes module only, missed them all.
fk="$scratch/fakes"
mkdir -p "$fk/Sources/KnotLink"
cat >"$fk/Sources/KnotLink/Link.swift" <<'SWIFT'
#if DEBUG || KNOT_FAKES
    public struct FakeLinkSystem { public init() {}; public func send() -> Int { 42 } }
    public enum Outer { public struct FakeNested { public init() {}; public func v() -> Int { 2 } } }
    private struct FakePrivate { func v() -> Int { 3 } }
    fileprivate final class FakeFilePrivate { func v() -> Int { 4 } }
    extension Array { public struct FakeInExtension { public init() {}; public func v() -> Int { 5 } } }
    public func useAll() -> Int {
        struct FakeLocal { func v() -> Int { 7 } }
        return FakePrivate().v() + FakeFilePrivate().v() + FakeLocal().v()
    }
#endif

public func linkValue() -> Int {
    #if DEBUG || KNOT_FAKES
        return FakeLinkSystem().send() + Outer.FakeNested().v() + useAll() + [Int].FakeInExtension().v()
    #else
        return 0
    #endif
}
SWIFT
knot_select_xcode
built=0
xcrun swiftc -emit-library -Onone -module-name KnotLink -D KNOT_FAKES "$fk/Sources/KnotLink/Link.swift" \
    -o "$fk/with-fakes.dylib" >/dev/null 2>&1 && built=$((built + 1))
xcrun swiftc -emit-library -Onone -module-name KnotLink "$fk/Sources/KnotLink/Link.swift" \
    -o "$fk/release.dylib" >/dev/null 2>&1 && built=$((built + 1))
with_fakes="$(knot_fakes_in "$fk/with-fakes.dylib" || true)"
release="$(knot_fakes_in "$fk/release.dylib" || true)"
old_scan="$({ nm -a "$fk/with-fakes.dylib"; strings -a "$fk/with-fakes.dylib"; } 2>/dev/null | grep -c -e KnotFakes || true)"
missing=""
for fake in "KnotLink.FakeLinkSystem" "KnotLink.Outer.FakeNested" "KnotLink.(FakePrivate" "KnotLink.(FakeFilePrivate" \
    "FakeLocal #1 in KnotLink" "(extension in KnotLink):Swift.Array.FakeInExtension"; do
    [[ $with_fakes == *"$fake"* ]] || missing="$missing [$fake]"
done
if [[ $built == 2 && -z $missing && -z $release && $old_scan == 0 ]]; then
    pass "the release scan finds a fake in another module by its name, public, nested, private, local or in an extension"
else
    fail "the scan for fakes outside KnotFakes: built $built, missed:${missing:- none}, release '$release', old scan $old_scan"
fi

# The fixtures step speaks this tree's audio when it lacks it (knot_tool.py fixtures-audio
# decides): with no local manifest, with one from another generator version, with a clip
# missing or changed, or when what decides the audio in the committed manifest, such as a
# clip's text, its voice or the speech rate, has changed since the step's stamp was made. A
# complete, stamped set is left as it is. The fixtures here are made up.
fa="$scratch/fixtures-audio/Fixtures"
mkdir -p "$fa/generated/audio"
committed_manifest() { # committed_manifest <text checksum> <voice> <rate> [<clip a's own voice>]
    printf '{"generatorVersion": 2, "speechRate": %s, "voices": [{"name": "%s"}], "generatedAudio": "generated/manifest.json", "audio": [{"file": "generated/audio/a.wav", "referenceSha256": "%s", "voice": "%s", "about": "one"}, {"file": "generated/audio/b.wav", "referenceSha256": "0", "voice": "%s"}]}\n' \
        "$3" "$2" "$1" "${4:-$2}" "$2" >"$fa/manifest.json"
}
audio_state() { python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" fixtures-audio --fixtures "$fa" >/dev/null 2>&1 && echo present || echo missing; }
stamp() { python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" fixtures-audio --fixtures "$fa" --write-stamp >/dev/null 2>&1; }
committed_manifest aaa Reed 175
states="$(audio_state)"
printf 'one\n' >"$fa/generated/audio/a.wav"
printf 'two\n' >"$fa/generated/audio/b.wav"
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
write_local() { printf '{"generatorVersion": %s, "audio": [{"file": "generated/audio/a.wav", "sha256": "%s"}, {"file": "generated/audio/b.wav", "sha256": "%s"}]}\n' \
    "$1" "$(sum "$fa/generated/audio/a.wav")" "$(sum "$fa/generated/audio/b.wav")" >"$fa/generated/manifest.json"; }
write_local 2
states="$states $(audio_state)"
stamp
states="$states $(audio_state)"
committed_manifest bbb Reed 175
states="$states $(audio_state)"
committed_manifest aaa Flo 175
states="$states $(audio_state)"
committed_manifest aaa Reed 200
states="$states $(audio_state)"
committed_manifest aaa Reed 175
states="$states $(audio_state)"
committed_manifest aaa Reed 175 Flo
states="$states $(audio_state)"
committed_manifest aaa Reed 175
write_local 1
states="$states $(audio_state)"
write_local 2
printf 'changed\n' >"$fa/generated/audio/b.wav"
states="$states $(audio_state)"
if [[ $states == "missing missing present missing missing missing present missing missing missing" ]]; then
    pass "the fixtures step finds this tree's audio missing, unstamped, stale by text, voice, a clip's voice or rate, of another version or changed"
else
    fail "the local audio's state, with none, unstamped, stamped, a new text, voice and rate, the same again, a clip's own voice, another version and a changed clip: $states"
fi

# The stamp is written only after the audio is spoken: a generator that fails leaves none,
# so the next run speaks again. A scratch tree holds the committed manifest and a generator
# that fails; the fixtures step's own path runs on it.
st="$scratch/stamp-tree"
mkdir -p "$st/Fixtures/tools"
cp "$KNOT_SELF/Fixtures/manifest.json" "$st/Fixtures/"
cp "$KNOT_SELF/.xcode-version" "$st/"
printf '#!/bin/sh\necho "the voices are missing" >&2\nexit 2\n' >"$st/Fixtures/tools/generate.sh"
chmod +x "$st/Fixtures/tools/generate.sh"
stamp_status=0
env -u KNOT_TREE KNOT_TREE="$st" "$KNOT_SCRIPTS/verify.sh" --in-step fixtures-audio >"$scratch/stamp-tree.out" 2>&1 || stamp_status=$?
if [[ $stamp_status != 0 && ! -e $st/Fixtures/generated/verify-stamp.txt ]]; then
    pass "the audio's stamp is written only after the audio is spoken: a generator that fails leaves none"
else
    fail "the fixtures step with a generator that fails: status $stamp_status, stamp $(ls "$st/Fixtures/generated" 2>&1 | tr '\n' ' ')"
fi

# A limit is wall-clock time, not a count of polls: with each poll's sleep slowed to 0.3 s,
# as a loaded Mac slows it, a 6-second limit still ends near 6 seconds. A limit under a
# minute is stated in seconds.
precise_now() { python3 -I -c 'import time; print("%.2f" % time.time())'; }
slow_started="$(precise_now)"
timed slow_polls bash -c 'source "$1"; sleep() { /bin/sleep 0.3; }; knot_limit 6 "$2"' _ "$KNOT_SCRIPTS/lib/common.sh" "$lim/hangs"
slow_elapsed="$(python3 -I -c 'import sys; print("%.1f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$slow_started" "$(precise_now)")"
timed short_limit env KNOT_SWIFT_TEST_LIMIT=1 bash -c 'source "$1"; knot_swift_test_limited package-test "$2"' _ \
    "$KNOT_SCRIPTS/lib/common.sh" "$lim/hangs"
# It ends neither late nor early: at least the limit, as the timer measures it, and within
# twice it. The limit is 6 s, so that a timer at half the limit, 3 s, and a count of the slowed
# polls, 18 s, stay far from the bounds however loaded the Mac.
if [[ $slow_polls_status == 124 && "${slow_elapsed%.*}${slow_elapsed#*.}" -ge 55 && "${slow_elapsed%.*}" -le 12 &&
    "$(cat "$lim/short_limit.out")" == *"within 1s"* ]]; then
    pass "a limit is wall-clock time, neither early nor late however slow each poll, and a short one is stated in seconds"
else
    fail "a 6 s limit with slow polls ended after ${slow_elapsed}s, status $slow_polls_status; message: $(cat "$lim/short_limit.out")"
fi
pkill -KILL -f "$lim/hangs" 2>/dev/null || true

# The wiring check reads the shell: it finds every unbounded call of its fixture,
# scripts/lint-cases/Unbounded.sh, in its many spellings, and passes every bounded one.
if unbounded_verdict="$(python3 -I -B - "$KNOT_SCRIPTS/lib" "$KNOT_SCRIPTS/lint-cases/Unbounded.sh" \
    "$KNOT_SCRIPTS/lint-cases/Unbounded-lib.sh" <<'PY'
import os, re, subprocess, sys
fixtures = sys.argv[2:]
want = {}
for fixture in fixtures:
    lines = open(fixture).read().splitlines()
    for n, line in enumerate(lines):
        m = re.search(r"#\s*expect:\s*(\w+)", line)
        if m:
            want[(fixture, n + 2)] = m.group(1)
out = subprocess.run([sys.executable, "-I", "-B", sys.argv[1] + "/knot_tool.py", "unbounded-calls"] + fixtures,
                     capture_output=True, text=True).stdout
found = {(m.group(1), int(m.group(2))) for m in re.finditer(r"^([^:\n]+):(\d+):", out, re.M)}
missed = sorted(f"{os.path.basename(f)}:{n}" for (f, n), w in want.items() if w == "unbounded" and (f, n) not in found)
wrong = sorted(f"{os.path.basename(f)}:{n}" for (f, n), w in want.items() if w == "nothing" and (f, n) in found)
unbounded = sum(1 for w in want.values() if w == "unbounded")
print(f"found {unbounded - len(missed)} of {unbounded} unbounded calls, flagged {len(wrong)} bounded ones;"
      f" missed lines {missed}, wrongly flagged {wrong}")
sys.exit(1 if missed or wrong else 0)
PY
)"; then
    pass "the wiring check reads the shell: $unbounded_verdict"
else
    fail "the wiring check on its fixture: $unbounded_verdict"
fi

# Every start in the scripts is wired through a limit (knot_tool.py unbounded-calls): no call
# of swift test, xcrun simctl, xcodebuild or xcb in any script of scripts/ or scripts/lib/,
# so a new script is read too, is made without a limit helper. A copy of verify.sh with the
# hosted run's limit taken off, and one with a wrapper called bare, fail.
wiring="$scratch/wiring"
mkdir -p "$wiring"
wiring_check() { python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" unbounded-calls "$@" >"$wiring/out" 2>&1; }
real=0
wiring_check "$KNOT_SCRIPTS"/*.sh "$KNOT_SCRIPTS"/lib/*.sh || real=$?
real_out="$(cat "$wiring/out")"
sed 's/knot_run_limited "The hosted iOS tests" "\$limit" xcb/xcb/' "$KNOT_SCRIPTS/verify.sh" >"$wiring/hosted.sh"
sed 's/knot_swift_test_limited package-test package_tests/package_tests/' "$KNOT_SCRIPTS/verify.sh" >"$wiring/wrapper.sh"
hosted=0
wiring_check "$wiring/hosted.sh" || hosted=$?
hosted_out="$(cat "$wiring/out")"
wrapper=0
wiring_check "$wiring/wrapper.sh" || wrapper=$?
wrapper_out="$(cat "$wiring/out")"
if [[ $real == 0 && $hosted == 1 && $hosted_out == *"no limit: xcb"*"Knot-iOS"* && $wrapper == 1 && $wrapper_out == *"package_tests"*"no limit"* ]] &&
    ! cmp -s "$wiring/hosted.sh" "$KNOT_SCRIPTS/verify.sh" && ! cmp -s "$wiring/wrapper.sh" "$KNOT_SCRIPTS/verify.sh"; then
    pass "every swift test, simctl, xcodebuild and xcb call in the scripts goes through a limit, and a bare one is found"
else
    fail "the wiring of the limits: real $real, hosted mutant $hosted, wrapper mutant $wrapper: $real_out / $hosted_out / $wrapper_out"
fi

# The screen's lock state, as knot_console_state reads it: locked, unlocked, and unknown for a
# listing without the key or a read that does not answer within its limit; and the message
# that fails the Mac UI step on a locked screen names the owner. A stub on PATH stands for
# ioreg.
lockdir="$scratch/console"
mkdir -p "$lockdir/locked" "$lockdir/unlocked" "$lockdir/none" "$lockdir/silent"
for state in locked unlocked; do
    value=$([[ $state == locked ]] && echo true || echo false)
    printf '#!/bin/sh\ncat <<PLIST\n<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>IOConsoleLocked</key><%s/><key>IOConsoleUsers</key><array/></dict></plist>\nPLIST\n' \
        "$value" >"$lockdir/$state/ioreg"
done
printf '#!/bin/sh\necho "<plist version=\\"1.0\\"><dict></dict></plist>"\n' >"$lockdir/none/ioreg"
printf '#!/bin/sh\nsleep 30\n' >"$lockdir/silent/ioreg"
chmod +x "$lockdir"/*/ioreg
console() { # console <stub>: the state read
    env PATH="$lockdir/$1:$PATH" KNOT_CONSOLE_READ_LIMIT=2 bash -c 'source "$1"; knot_console_state' _ "$KNOT_SCRIPTS/lib/common.sh" 2>/dev/null
}
started=$(knot_now)
states="$(console locked) $(console unlocked) $(console none) $(console silent)"
locked_message="$(bash -c 'source "$1"; knot_mac_ui_locked' _ "$KNOT_SCRIPTS/lib/common.sh" 2>&1 || true)"
if [[ $states == "locked unlocked unknown unknown" && $locked_message == *"locked"*"owner"*"unlock"* &&
    $(($(knot_now) - started)) -lt 12 ]]; then
    pass "the screen's lock state reads locked, unlocked or unknown, the silent read within its limit, and the message names the owner"
else
    fail "the screen's lock state: $states, message: $locked_message"
fi
pkill -KILL -f "$lockdir/silent/ioreg" 2>/dev/null || true

# The lock check's wiring, through verify.sh's own step loop. A copy of scripts/ in which
# only the doctor and the Mac UI step are stand-ins runs `--only mac-ui` on a scratch tree,
# with its build slots in a scratch folder, and a stub ioreg that counts its reads. A locked
# screen fails the step at once, takes no slot and runs no test; an unlocked one runs it; a
# read that does not answer runs it too, and never passes it unrun; a screen that reads
# locked and then unlocked still fails; a run without the Mac UI step reads nothing.
wl="$scratch/lock-loop"
mkdir -p "$wl/tree" "$wl/slots" "$wl/stubs"
cp -R "$KNOT_SCRIPTS" "$wl/scripts"
cp "$KNOT_SELF/.xcode-version" "$wl/tree/"
python3 -I - "$wl/scripts/verify.sh" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
for name, body in (("step_doctor", 'echo "doctor stand-in"'), ("step_mac_ui", 'echo "mac-ui stand-in ran" >>"$KNOT_LOCK_LOOP/ran"')):
    start = text.index(name + "() {")
    end = text.index("\n}\n", start) + 3
    text = text[:start] + name + "() {\n    " + body.replace("$KNOT_LOCK_LOOP/", "$KNOT_LOCK_LOOP_RUN/") + "\n}\n" + text[end:]
open(path, "w").write(text)
PY
lock_stub() { # lock_stub <name> <first answer> [<later answer>]: an ioreg that counts its reads
    mkdir -p "$wl/stubs/$1"
    printf '#!/bin/sh\necho x >>"$KNOT_LOCK_LOOP_RUN/reads"\nn=$(wc -l <"$KNOT_LOCK_LOOP_RUN/reads" | tr -d " ")\nanswer=%s\n[ "$n" -gt 1 ] && answer=%s\n[ "$answer" = silent ] && exec sleep 30\nprintf "<plist version=\\"1.0\\"><dict><key>IOConsoleLocked</key><%%s/></dict></plist>\\n" "$answer"\n' \
        "$2" "${3:-$2}" >"$wl/stubs/$1/ioreg"
    chmod +x "$wl/stubs/$1/ioreg"
}
lock_stub locked true
lock_stub unlocked false
lock_stub silent silent
lock_stub flips true false
lock_loop() { # lock_loop <stub> <step>: status, reads, whether the stand-in ran, whether a slot was taken
    local status=0 run="$wl/run-$1-$2"
    mkdir -p "$run/slots"
    env PATH="$wl/stubs/$1:$PATH" KNOT_LOCK_LOOP_RUN="$run" KNOT_TREE="$wl/tree" KNOT_SLOT_DIR="$run/slots" \
        KNOT_CONSOLE_READ_LIMIT=2 "$wl/scripts/verify.sh" --only "$2" >"$wl/out-$1-$2" 2>&1 || status=$?
    echo "$status $( [[ -f $run/reads ]] && wc -l <"$run/reads" | tr -d ' ' || echo 0) $( [[ -f $run/ran ]] && echo ran || echo not-run) $(ls "$run/slots" | grep -c holder || true)"
}
locked_run="$(lock_loop locked mac-ui)"
unlocked_run="$(lock_loop unlocked mac-ui)"
silent_run="$(lock_loop silent mac-ui)"
flips_run="$(lock_loop flips mac-ui)"
plan_run="$(lock_loop locked doctor)"
if [[ ${locked_run%% *} != 0 && $locked_run == *" 1 not-run 0" && "$(cat "$wl/out-locked-mac-ui")" == *"locked"*"owner"* &&
    $unlocked_run == "0 1 ran "* && $silent_run == "0 1 ran "* && ${flips_run%% *} != 0 && $flips_run == *"not-run"* &&
    $plan_run == "0 0 not-run 0" ]]; then
    pass "through verify's loop, a locked screen fails the Mac UI step unrun and slotless, and no step passes unrun"
else
    fail "the lock check through verify's loop (status, reads, stand-in, slots): locked '$locked_run', unlocked '$unlocked_run', silent '$silent_run', locked then unlocked '$flips_run', a run without the step '$plan_run'"
fi

# The doctor reads the screen's lock only in a run that has the Mac UI step, and says what it
# read as a note: with a stub ioreg that counts its reads and never answers, a doctor without
# --mac-ui reads nothing, and one with it reads once, within its limit, and notes it.
dl="$scratch/doctor-lock"
mkdir -p "$dl/stub"
printf '#!/bin/sh\necho x >>"%s/reads"\nexec sleep 30\n' "$dl" >"$dl/stub/ioreg"
chmod +x "$dl/stub/ioreg"
env PATH="$dl/stub:$PATH" KNOT_CONSOLE_READ_LIMIT=2 "$KNOT_SCRIPTS/doctor.sh" >"$dl/plain.out" 2>&1 || true
plain_reads=$( [[ -f $dl/reads ]] && wc -l <"$dl/reads" | tr -d ' ' || echo 0)
env PATH="$dl/stub:$PATH" KNOT_CONSOLE_READ_LIMIT=2 "$KNOT_SCRIPTS/doctor.sh" --mac-ui >"$dl/mac-ui.out" 2>&1 || true
all_reads=$( [[ -f $dl/reads ]] && wc -l <"$dl/reads" | tr -d ' ' || echo 0)
if [[ $plain_reads == 0 && $all_reads == 1 && "$(cat "$dl/mac-ui.out")" == *"note  screen"*"could not"* ]]; then
    pass "the doctor reads the screen's lock only for a run with the Mac UI step, and notes what it read"
else
    fail "the doctor and the lock: reads without --mac-ui $plain_reads, in all $all_reads; $(grep -e screen "$dl/mac-ui.out" || echo 'no screen line')"
fi
pkill -KILL -f "$dl/stub/ioreg" 2>/dev/null || true

# An xcodebuild that does not answer is a dialog waiting for the owner, not a wrong Xcode:
# knot_select_xcode fails as infra-xcode-silent, never as infra-xcode-mismatch, which would
# send an agent to reinstall what only the owner can unblock. A stub that never answers
# stands for xcodebuild, with a 1 s limit.
xs="$scratch/xcode-silent"
mkdir -p "$xs"
printf '#!/bin/sh\nexec sleep 30\n' >"$xs/xcodebuild"
chmod +x "$xs/xcodebuild"
silent_status=0
silent_out="$(env PATH="$xs:$PATH" KNOT_XCODE_ANSWER_LIMIT=1 bash -c 'source "$1"; knot_select_xcode' _ \
    "$KNOT_SCRIPTS/lib/common.sh" 2>&1)" || silent_status=$?
if [[ $silent_status != 0 && $silent_out == *"FAIL infra-xcode-silent"*"owner"* && $silent_out != *"infra-xcode-mismatch"* ]]; then
    pass "an xcodebuild that does not answer fails as infra-xcode-silent, naming the owner"
else
    fail "a silent xcodebuild: status $silent_status: $silent_out"
fi
pkill -KILL -f "$xs/xcodebuild" 2>/dev/null || true

# This tree's audio is made in one place, knot_make_audio, under its lock, for the fixtures
# step and for bootstrap alike: on a scratch tree with a stub generator that writes the
# committed manifest's clips, the first call speaks and stamps, and a second speaks nothing.
# And bootstrap.sh makes the audio only through it, never by calling the generator itself,
# which writes no stamp.
ma="$scratch/make-audio"
mkdir -p "$ma/Fixtures/tools"
cp "$KNOT_SELF/Fixtures/manifest.json" "$ma/Fixtures/"
cp "$KNOT_SELF/.xcode-version" "$ma/"
cat >"$ma/Fixtures/tools/generate.sh" <<'STUB'
#!/bin/sh
echo spoke >>"$(dirname "$0")/../../spoken"
exec python3 -I - "$(dirname "$0")/.." <<'PY'
import hashlib, json, os, sys
fixtures = sys.argv[1]
committed = json.load(open(os.path.join(fixtures, "manifest.json")))
entries = []
for clip in committed["audio"]:
    path = os.path.join(fixtures, clip["file"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(clip["file"].encode())
    entries.append({"file": clip["file"], "sha256": hashlib.sha256(clip["file"].encode()).hexdigest()})
json.dump({"generatorVersion": committed["generatorVersion"], "audio": entries},
          open(os.path.join(fixtures, "generated", "manifest.json"), "w"))
PY
STUB
chmod +x "$ma/Fixtures/tools/generate.sh"
make_audio() { env -u KNOT_TREE KNOT_TREE="$ma" bash -c 'source "$1"; knot_make_audio' _ "$KNOT_SCRIPTS/lib/common.sh" >/dev/null 2>&1; }
spoken() { if [[ -f $ma/spoken ]]; then wc -l <"$ma/spoken" | tr -d ' '; else echo 0; fi; }
make_audio || true
first="$( [[ -f $ma/Fixtures/generated/verify-stamp.txt ]] && echo stamped || echo unstamped) $(spoken)"
make_audio || true
second="$(spoken)"
# Bootstrap is read as shell, by its calls, not its text: a comment that names the helper is
# no call of it, and the generator run in any quoting, or as the argument of another command
# such as bash, is a call.
bootstrap_ok="$(python3 -I -B - "$KNOT_SCRIPTS/lib" "$KNOT_SCRIPTS/bootstrap.sh" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import knot_tool as k
words = [k.command_words(k.shell_words(segment), {}, {}) for _, _, segment in k.shell_segments(open(sys.argv[2]).read())]
names = [os.path.basename(w[0]) for w in words if w]
# The generator run in any way, as the command or as an argument, as in `bash generate.sh`.
generator = any(os.path.basename(word) == "generate.sh" for w in words for word in w)
print(1 if "knot_make_audio" in names and not generator else 0)
PY
)"
if [[ $first == "stamped 1" && $second == 1 && $bootstrap_ok == 1 ]]; then
    pass "the audio is made in one place, stamped and spoken once, and bootstrap.sh makes it there"
else
    fail "making the audio: first call '$first', spoken after the second '$second', bootstrap through knot_make_audio: $bootstrap_ok"
fi

# The hosted nightly run makes the tree's audio before the package tests under Thread
# Sanitizer, since `--only tsan` has no fixtures step and a test will read the audio. The
# gate's lint step checks it on the tree's own workflow (knot_tool.py workflows), since the
# self-test reads its own checkout. Here the check is run on six workflows: the scripts' own,
# which passes; and five wrong ones, each refused: tsan before the fixtures (36a), the
# fixtures step commented out (36b), the fixtures step with `if: false` (43a), the fixtures
# step in another job (43b), the tsan step with an `if:` of its own, and (finding 62) the tsan
# job with `if: false`, and `continue-on-error: true` on the fixtures step or on the job.
nw="$scratch/nightly"
mkdir -p "$nw"
python3 -I - "$KNOT_SELF/.github/workflows/nightly.yml" "$nw" <<'PY'
import os, sys
text, out = open(sys.argv[1]).read(), sys.argv[2]
fixtures = "      - name: The fixtures, with this tree's audio\n        run: scripts/verify.sh --only fixtures\n"
tsan = "      - name: Package tests under Thread Sanitizer\n        run: scripts/verify.sh --only tsan\n"
if fixtures + tsan not in text:
    # The scripts' own workflow is not as the variants expect: its own check below says why.
    sys.exit(0)
both = fixtures + tsan
variants = {
    "tsan-first": text.replace(both, tsan + fixtures),
    "commented": text.replace(fixtures, "".join("      # " + l[6:] + "\n" for l in fixtures.splitlines())),
    "if-false": text.replace(fixtures, fixtures.replace("        run:", "        if: false\n        run:")),
    "other-job": text.replace(fixtures, "") + "  audio:\n    runs-on: xcode-27\n    steps:\n" + fixtures,
    "tsan-if": text.replace(tsan, tsan.replace("        run:", "        if: github.event_name == 'schedule'\n        run:")),
    "job-if": text.replace("  tsan:\n    runs-on:", "  tsan:\n    if: false\n    runs-on:"),
    "fixtures-continue": text.replace(fixtures, fixtures.replace("        run:", "        continue-on-error: true\n        run:")),
    "job-continue": text.replace("  tsan:\n    runs-on:", "  tsan:\n    continue-on-error: true\n    runs-on:"),
}
for name, body in variants.items():
    assert body != text, name
    open(os.path.join(out, name + ".yml"), "w").write(body)
PY
nightly_ok=0
python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" workflows --file "$KNOT_SELF/.github/workflows/nightly.yml" >"$nw/own.out" 2>&1 || nightly_ok=$?
nightly_refused=""
for variant in tsan-first commented if-false other-job tsan-if job-if fixtures-continue job-continue; do
    python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" workflows --file "$nw/$variant.yml" >"$nw/$variant.out" 2>&1 &&
        nightly_refused="$nightly_refused passed:$variant" || nightly_refused="$nightly_refused refused:$variant"
done
if [[ $nightly_ok == 0 && $nightly_refused == " refused:tsan-first refused:commented refused:if-false refused:other-job refused:tsan-if refused:job-if refused:fixtures-continue refused:job-continue" ]]; then
    pass "the hosted nightly run makes the audio first, in the same job, unconditionally, and each wrong workflow is refused"
else
    fail "the nightly workflow's check: the scripts' own workflow status $nightly_ok ($(tail -n 1 "$nw/own.out")), the wrong ones:$nightly_refused"
fi

# A test cancelled at run time counts as one skipped, as a test skipped by its trait does:
# the summary counts both and the gate fails on both (knot_skipped_tests). The lines are
# Swift Testing's, as the pinned Xcode prints them; a cancellation whose comment holds the
# word "Skipped" counts once.
sk="$scratch/skips.log"
cat >"$sk" <<'LOG'
􀟈  Test cancelledAtRunTime() started.
􀙟  Test disabledByARunTimeTrait() skipped: "the speech model is on this Mac"
􀙟  Test cancelledAtRunTime() was cancelled after 0.001 seconds: "Skipped: the speech model is not on this Mac."
􁁛  Test aPlainTest() passed after 0.001 seconds.
LOG
skip_lines="$(bash -c 'source "$1"; knot_skipped_tests "$2"' _ "$KNOT_SCRIPTS/lib/common.sh" "$sk" 2>&1 || true)"
if [[ "$(grep -c . <<<"$skip_lines")" == 2 && $skip_lines == *disabledByARunTimeTrait*cancelledAtRunTime* ]]; then
    pass "a cancelled test counts as skipped, as a skipped one does, each once"
else
    fail "the skipped and cancelled tests found: $skip_lines"
fi

# The gate's own check of skipped and cancelled tests, through verify.sh's step loop: a
# copy of scripts/ in which the doctor is a stand-in, the package tests print a given log in
# place of running swift test, and the in-step process takes the tier that KNOT_SKIP_TIER
# names (the gate refuses --only, so this is the one change to its tier). At the gate, a log
# with a cancelled test, or with a skipped one, fails the step; at the quick tier it passes.
# Either way the summary counts the test once, though the failing step names it again.
sl="$scratch/skip-loop"
mkdir -p "$sl/tree" "$sl/logs"
cp -R "$KNOT_SCRIPTS" "$sl/scripts"
cp "$KNOT_SELF/.xcode-version" "$sl/tree/"
python3 -I - "$sl/scripts/verify.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
start = text.index("step_doctor() {")
end = text.index("\n}\n", start) + 3
text = text[:start] + 'step_doctor() {\n    echo "doctor stand-in"\n}\n' + text[end:]
for old, new in (
    ('swift test "${KNOT_SWIFTPM_FLAGS[@]}" --explicit-target-dependency-import-check error \\\n'
     '            "${EVENT_FLAGS[@]}" ${filter[@]+"${filter[@]}"} 2>&1 | tee "$output"',
     '{ if [[ -f $KNOT_SKIP_LOG.events ]]; then cp "$KNOT_SKIP_LOG.events" "${EVENT_FLAGS[1]}"; fi; '
     'cat "$KNOT_SKIP_LOG"; } | tee "$output"'),
    ("export KNOT_VERIFY_TIER=$TIER", "export KNOT_VERIFY_TIER=${KNOT_SKIP_TIER:-$TIER}"),
):
    assert old in text, old
    text = text.replace(old, new)
open(path, "w").write(text)
PY
cat >"$sl/logs/cancelled.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀙟  Test cancelledAtRunTime() was cancelled after 0.001 seconds: "the speech model is not on this Mac"
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
cat >"$sl/logs/skipped.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀙟  Test disabledByATrait() skipped: "the speech model is not on this Mac"
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
# Lines that only look like a skip: a test's own printed line, a recorded issue's text, and
# passing tests whose names hold "skipped" or "cancelled after". Each test passed, so the
# gate passes and the summary counts nothing as skipped.
cat >"$sl/logs/lookalike.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
recorder: Test session was cancelled after 2 retries, as the fake store asked
􀢄  Test aRecordedIssue() recorded an issue at A.swift:3:5: Expectation failed: (status → "Test x was cancelled after 1 s") == "ok"
􁁛  Test "A capture that was cancelled after the disk filled is kept" passed after 0.002 seconds.
􁁛  Test "A clip skipped by the guard is still on disk" passed after 0.002 seconds.
􁁛  Test skippedSegmentIsReported() passed after 0.001 seconds.
	  Test printedByATest() skipped: "a line the test printed, after a tab"
􁁛  Test run with 3 tests in 1 suite passed after 0.005 seconds.
LOG
# Skipped tests as the pinned Xcode prints them, from the review of pull request 63: a
# display name that holds quotes, and a skip with no comment, which ends with a period.
cat >"$sl/logs/quoted.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀙟  Test "He said "hi"" skipped: "quoted display"
􀙟  Test plainDisabled() skipped.
􁁛  Test run with 3 tests in 1 suite passed after 0.005 seconds.
LOG
# One test failed: the run's own line says "failed after" too, and the summary counts one
# failure, not two (finding 65).
cat >"$sl/logs/failed.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀢄  Test aFailingTest() recorded an issue at A.swift:3:5: Expectation failed: false
􀢄  Test aFailingTest() failed after 0.002 seconds with 1 issue.
􀢄  Test run with 2 tests in 1 suite failed after 0.003 seconds with 1 issue.
LOG
# Each log has the event stream its run would write beside it, <log>.events, which the copy's
# package tests hand to the step as swift test would (finding 60). The re-check's probe of
# pull request 63 adds six runs that the console reads wrong: three cancellations, a case
# cancelled by `try Test` and `.cancel` on the next line, a test cancelled through an alias,
# and a case cancelled by its task, two of them printed as passed; and three events over two
# lines, a skip reason, a display name and a cancellation reason. And two runs that print as
# passed with no stream, and with a stream whose run did not end.
cat >"$sl/logs/case-cancel-split.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􁁛  Test caseCancelSplit(x:) with 2 test cases passed after 0.001 seconds.
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
cat >"$sl/logs/alias-cancel.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀙟  Test aliasCancel() was cancelled after 0.001 seconds: "through an alias"
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
cat >"$sl/logs/case-task-cancel.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􁁛  Test caseTaskCancelled(x:) with 2 test cases passed after 0.001 seconds.
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
cat >"$sl/logs/reason-two-lines.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀙟  Test multiLineReason() skipped: "first line
second line"
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
cat >"$sl/logs/name-two-lines.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀙟  Test "two
lines" skipped: "r"
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
cat >"$sl/logs/cancel-two-lines.log" <<'LOG'
􁁛  Test aPlainTest() passed after 0.001 seconds.
􀙟  Test cancelMultiLine() was cancelled after 0.001 seconds: "one
two"
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
LOG
cp "$sl/logs/lookalike.log" "$sl/logs/no-stream.log"
# A run whose console says tests ran while its stream holds a run with no test in it, as a
# filter that matched nothing writes it (item 108, its second half).
cp "$sl/logs/lookalike.log" "$sl/logs/no-test-in-stream.log"
cp "$sl/logs/lookalike.log" "$sl/logs/no-run-end.log"
python3 -I - "$sl/logs" <<'PY'
import json, os, sys
logs = sys.argv[1]
def stream(name, tests, events, ended=True):
    """tests: [(id, name, display name)]; events: [(kind, id, case display name)]"""
    lines = [{"kind": "test", "payload": {"id": i, "name": n, "displayName": d, "kind": "function"}, "version": 0}
             for i, n, d in tests]
    lines.append({"kind": "event", "payload": {"kind": "runStarted"}, "version": 0})
    skipped = {i for kind, i, _ in events if kind == "testSkipped"}
    for i, _, _ in tests:
        if i not in skipped:
            lines.append({"kind": "event", "payload": {"kind": "testStarted", "testID": i}, "version": 0})
    for kind, i, case in events:
        payload = {"kind": kind, "testID": i}
        if case:
            payload["_testCase"] = {"displayName": case}
        lines.append({"kind": "event", "payload": payload, "version": 0})
    if ended:
        lines.append({"kind": "event", "payload": {"kind": "runEnded"}, "version": 0})
    with open(os.path.join(logs, name + ".log.events"), "w") as f:
        f.write("".join(json.dumps(line) + "\n" for line in lines))
plain = ("p", "aPlainTest()", None)
stream("cancelled", [plain, ("c", "cancelledAtRunTime()", None)], [("testCancelled", "c", None)])
stream("skipped", [plain, ("s", "disabledByATrait()", None)], [("testSkipped", "s", None)])
stream("lookalike", [plain, ("a", "aRecordedIssue()", None), ("b", "skippedSegmentIsReported()", None)], [])
stream("quoted", [plain, ("q", "quoted()", 'He said "hi"'), ("d", "plainDisabled()", None)],
       [("testSkipped", "q", None), ("testSkipped", "d", None)])
stream("failed", [plain, ("f", "aFailingTest()", None)], [])
stream("case-cancel-split", [plain, ("x", "caseCancelSplit(x:)", None)], [("testCaseCancelled", "x", "2")])
stream("alias-cancel", [plain, ("y", "aliasCancel()", None)], [("testCancelled", "y", None)])
stream("case-task-cancel", [plain, ("z", "caseTaskCancelled(x:)", None)], [("testCaseCancelled", "z", "2")])
stream("reason-two-lines", [plain, ("r", "multiLineReason()", None)], [("testSkipped", "r", None)])
stream("name-two-lines", [plain, ("n", "multiLineName()", "two\nlines")], [("testSkipped", "n", None)])
stream("cancel-two-lines", [plain, ("m", "cancelMultiLine()", None)], [("testCancelled", "m", None)])
stream("no-run-end", [plain], [], ended=False)
stream("no-test-in-stream", [], [])
PY
skip_loop() { # skip_loop <log> <tier>: the step's line and the summary's tests
    local status=0 run="$sl/run-$1-$2"
    mkdir -p "$run/slots"
    env KNOT_SKIP_LOG="$sl/logs/$1.log" KNOT_SKIP_TIER="$2" KNOT_TREE="$sl/tree" KNOT_SLOT_DIR="$run/slots" \
        "$sl/scripts/verify.sh" --only package-test >"$run/out" 2>&1 || status=$?
    printf '%s %s · %s' "$status" "$(sed -n -E 's/^verify: (ok|FAIL) +package-test.*/\1/p' "$run/out")" \
        "$(grep -oE 'tests [0-9]+ passed, [0-9]+ failed, [0-9]+ skipped' "$run/out" || true)"
}
gate_cancelled="$(skip_loop cancelled gate)"
gate_skipped="$(skip_loop skipped gate)"
quick_cancelled="$(skip_loop cancelled quick)"
gate_lookalike="$(skip_loop lookalike gate)"
gate_quoted="$(skip_loop quoted gate)"
quick_failed="$(skip_loop failed quick)"
if [[ $gate_cancelled == "1 FAIL · tests 2 passed, 0 failed, 1 skipped" &&
    $gate_skipped == "1 FAIL · tests 2 passed, 0 failed, 1 skipped" &&
    $quick_cancelled == "0 ok · tests 2 passed, 0 failed, 1 skipped" &&
    $gate_lookalike == "0 ok · tests 3 passed, 0 failed, 0 skipped" &&
    $gate_quoted == "1 FAIL · tests 3 passed, 0 failed, 2 skipped" && $quick_failed == *"tests 0 passed, 1 failed, 0 skipped" ]]; then
    pass "through verify's loop, a cancelled or a skipped test fails the gate's package tests, passes the quick tier, and counts once; a line that only looks like one counts for nothing"
else
    fail "the gate's check of skipped tests through verify's loop: cancelled at the gate '$gate_cancelled', skipped at the gate '$gate_skipped', cancelled at the quick tier '$quick_cancelled', lookalike lines at the gate '$gate_lookalike', quoted names and a bare skip at the gate '$gate_quoted', one failed test at the quick tier '$quick_failed'"
fi
# The event stream decides (finding 60): each of the probe's six runs fails the gate and
# passes the quick tier with one skipped, though the console printed two of them as passed
# and three over two lines; a run with no stream, or whose stream did not end, fails at
# either tier.
stream_verdicts=""
for run in case-cancel-split alias-cancel case-task-cancel reason-two-lines name-two-lines cancel-two-lines; do
    stream_verdicts="$stream_verdicts $run: $(skip_loop "$run" gate) / $(skip_loop "$run" quick);"
done
no_stream="$(skip_loop no-stream quick)"
no_run_end="$(skip_loop no-run-end quick)"
no_test_in_stream="$(skip_loop no-test-in-stream quick)"
expected_verdicts=""
for run in case-cancel-split alias-cancel case-task-cancel reason-two-lines name-two-lines cancel-two-lines; do
    expected_verdicts="$expected_verdicts $run: 1 FAIL · tests 2 passed, 0 failed, 1 skipped / 0 ok · tests 2 passed, 0 failed, 1 skipped;"
done
if [[ $stream_verdicts == "$expected_verdicts" && $no_stream == "1 FAIL"* && $no_run_end == "1 FAIL"* &&
    $no_test_in_stream == "1 FAIL"* ]]; then
    pass "the event stream fails the gate on a cancelled case printed as passed and on events over two lines, and a run with no complete stream fails"
else
    fail "the event stream through verify's loop:$stream_verdicts no stream '$no_stream', no end of run '$no_run_end', no test in the stream '$no_test_in_stream'"
fi

# worktree-remove.sh prints no path with the home folder in it, since its lines end in the
# journal: a path under the home folder shows as "the home folder's …". It runs on a scratch
# repository whose worktree sits in a scratch home folder, with a store of the worktree in the
# development app's container there, and a stub xcrun that lists one simulator of it.
wr="$scratch/worktree-remove"
mkdir -p "$wr/home" "$wr/stub" "$wr/repo"
git -C "$wr/repo" init -q -b main
cp -R "$KNOT_SCRIPTS" "$wr/repo/scripts"
cp "$KNOT_SELF/.xcode-version" "$wr/repo/"
git -C "$wr/repo" add scripts .xcode-version
git -C "$wr/repo" -c user.name=self-test -c user.email=self-test@example.invalid commit -q -m scratch
git -C "$wr/repo" worktree add -q "$wr/home/wt" -b self-test-wt
wr_tree="$(cd "$wr/home/wt" && pwd -P)"
wr_id="wt-$(printf '%s' "$wr_tree" | shasum -a 256 | cut -c1-6)"
mkdir -p "$wr/home/Library/Containers/com.p3ob7o.knot.dev/Data/Library/Application Support/Knot/$wr_id"
printf '#!/bin/sh\necho "$*" >>"%s/calls"\n[ "$*" = "simctl list devices -j" ] && printf %s\n' "$wr" \
    "'{\"devices\":{\"r\":[{\"name\":\"$wr_id-iphone\",\"udid\":\"U1\",\"state\":\"Shutdown\"}]}}\\n'" >"$wr/stub/xcrun"
# With KNOT_WR_FAIL set, the delete fails as simctl does, with a message that names a path
# under the home folder in its resolved form, as simctl names it.
printf '[ -n "$KNOT_WR_FAIL" ] && [ "$1 $2" = "simctl delete" ] && { echo "An error was encountered processing the command (domain=NSCocoaErrorDomain, code=513): NSFilePath=$(cd "$HOME" && pwd -P)/Library/Developer/CoreSimulator/Devices/U1" >&2; exit 1; }\nexit 0\n' >>"$wr/stub/xcrun"
# The failing run's home folder is a link, so that its given and resolved forms differ
# wherever the self-test runs (finding 64).
ln -s "$wr/home" "$wr/home-link"
chmod +x "$wr/stub/xcrun"
# A refusal names its target with no home folder in it either: a folder under the home
# folder that is no worktree of the repository.
mkdir -p "$wr/home/not-a-worktree"
wr_refused_status=0
(cd "$wr/repo" && env -u KNOT_TREE HOME="$wr/home" PATH="$wr/stub:$PATH" \
    scripts/worktree-remove.sh "$wr/home/not-a-worktree" >"$wr/refused.out" 2>&1) || wr_refused_status=$?
# A delete that fails prints simctl's message with no home folder in it either.
wr_fail_status=0
(cd "$wr/repo" && env -u KNOT_TREE HOME="$wr/home-link" PATH="$wr/stub:$PATH" KNOT_SIMCTL_LIMIT=10 KNOT_WR_FAIL=1 \
    scripts/worktree-remove.sh "$wr_tree" >"$wr/fail.out" 2>&1) || wr_fail_status=$?
wr_status=0
(cd "$wr/repo" && env -u KNOT_TREE HOME="$wr/home" PATH="$wr/stub:$PATH" KNOT_SIMCTL_LIMIT=10 \
    scripts/worktree-remove.sh "$wr_tree" >"$wr/out" 2>&1) || wr_status=$?
wr_home="$(cd "$wr/home" && pwd -P)"
if [[ $wr_status == 0 && "$(cat "$wr/out")" != *"$wr_home"* && "$(cat "$wr/out")" != *"$wr/home"* &&
    "$(cat "$wr/out")" != *"~/"* &&
    "$(cat "$wr/out")" == *"the home folder's Library/Group Containers/"* &&
    "$(cat "$wr/out")" == *"removed the development store the home folder's Library/Containers/"* &&
    "$(cat "$wr/out")" == *"deleted the simulator $wr_id-iphone"* && ! -d $wr_tree &&
    $wr_fail_status != 0 && "$(cat "$wr/fail.out")" == *"FAIL infra-simulator-delete"*"NSFilePath=the home folder's Library/"* &&
    "$(cat "$wr/fail.out")" != *"$wr_home"* && "$(cat "$wr/fail.out")" != *"$wr/home"* &&
    $wr_refused_status != 0 && "$(cat "$wr/refused.out")" == *"FAIL worktree-remove-not-worktree"*"the home folder's not-a-worktree"* &&
    "$(cat "$wr/refused.out")" != *"$wr_home"* && "$(cat "$wr/refused.out")" != *"$wr/home"* ]]; then
    pass "worktree-remove.sh removes the worktree, its simulator and its store, and prints no path with the home folder in it, simctl's message included"
else
    fail "worktree-remove.sh, status $wr_status: $(sed -e "s|$wr_home|<home>|g" -e "s|$wr/home|<home>|g" "$wr/out"); a failed delete, status $wr_fail_status: $(sed -e "s|$wr_home|<home>|g" -e "s|$wr/home|<home>|g" "$wr/fail.out"); a refusal, status $wr_refused_status: $(sed -e "s|$wr_home|<home>|g" -e "s|$wr/home|<home>|g" "$wr/refused.out")"
fi

# The package's tests under the strict cooperative pool (package-test-strict), through
# verify.sh's loop: a copy of scripts/ whose doctor is a stand-in, and whose in-step process
# takes the tier that KNOT_POOL_TIER names, with a stub swift whose build passes and whose
# suite does what KNOT_STUB_MODE says when LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 is set, and
# passes when it is not. It writes the event stream as swift test does.
# - hang: with a 3 s limit the step fails, says that a test may be blocking a thread of the
#   cooperative pool, and names the test that started and did not end, and not the one that
#   passed; a copy that runs the tests without the variable passes, which this case refuses.
# - skip-console, cancel-stream (finding 64): at the gate a skip that only the console shows,
#   and a cancelled case that only the stream shows, each fail the step, since either
#   reading fails the gate.
# - fail: a test that fails only under the variable fails the step, and the summary counts
#   one failure.
ps="$scratch/pool-strict"
mkdir -p "$ps/tree" "$ps/stub"
cp -R "$KNOT_SCRIPTS" "$ps/scripts"
cp "$KNOT_SELF/.xcode-version" "$ps/tree/"
python3 -I - "$ps/scripts/verify.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
start = text.index("step_doctor() {")
end = text.index("\n}\n", start) + 3
text = text[:start] + 'step_doctor() {\n    echo "doctor stand-in"\n}\n' + text[end:]
old = "export KNOT_VERIFY_TIER=$TIER"
assert old in text
text = text.replace(old, "export KNOT_VERIFY_TIER=${KNOT_POOL_TIER:-$TIER}")
open(path, "w").write(text)
PY
cat >"$ps/stub/swift" <<'SH'
#!/bin/sh
for word in "$@"; do [ "$word" = build ] && exit 0; done
# The event stream, as swift test writes it at --event-stream-output-path, once the run ends.
stream="" previous=""
for word in "$@"; do [ "$previous" = --event-stream-output-path ] && stream=$word; previous=$word; done
mode=pass
[ "$LIBDISPATCH_COOPERATIVE_POOL_STRICT" = 1 ] && mode=${KNOT_STUB_MODE:-hang}
printf '%s\n' "􀟈  Test aPlainTest() started." "􁁛  Test aPlainTest() passed after 0.001 seconds." "􀟈  Test aWaitThatBlocks() started."
[ "$mode" = hang ] && exec sleep 30
if [ "$mode" = fail ]; then
    printf '%s\n' "􀢄  Test aWaitThatBlocks() recorded an issue at A.swift:3:5: Expectation failed: false" \
        "􀢄  Test aWaitThatBlocks() failed after 0.002 seconds with 1 issue." \
        "􀢄  Test run with 2 tests in 1 suite failed after 0.003 seconds with 1 issue."
    exit 1
fi
printf '%s\n' "􁁛  Test aWaitThatBlocks() passed after 0.002 seconds."
[ "$mode" = skip-console ] && printf '%s\n' "􀙟  Test aSkippedOne() skipped: \"only on the console\""
printf '%s\n' "􁁛  Test run with 2 tests in 1 suite passed after 0.003 seconds."
if [ -n "$stream" ]; then
    printf '%s\n' '{"kind":"test","payload":{"id":"w","name":"aWaitThatBlocks()","kind":"function"},"version":0}' \
        '{"kind":"event","payload":{"kind":"runStarted"},"version":0}' \
        '{"kind":"event","payload":{"kind":"testStarted","testID":"w"},"version":0}' >"$stream"
    [ "$mode" = cancel-stream ] &&
        printf '%s\n' '{"kind":"event","payload":{"kind":"testCaseCancelled","testID":"w","_testCase":{"displayName":"2"}},"version":0}' >>"$stream"
    printf '%s\n' '{"kind":"event","payload":{"kind":"runEnded"},"version":0}' >>"$stream"
fi
exit 0
SH
chmod +x "$ps/stub/swift"
pool_strict() { # pool_strict <scripts folder> <name> [mode] [tier]: status, the step's log, the summary
    local status=0 run="$ps/run-$2"
    mkdir -p "$run/slots" "$run/tree"
    cp "$ps/tree/.xcode-version" "$run/tree/"
    env PATH="$ps/stub:$PATH" KNOT_STRICT_TEST_LIMIT=3 KNOT_STUB_MODE="${3:-hang}" KNOT_POOL_TIER="${4:-}" \
        KNOT_TREE="$run/tree" KNOT_SLOT_DIR="$run/slots" \
        "$1/verify.sh" --only package-test-strict >"$run/out" 2>&1 || status=$?
    echo "$status"
    cat "$run/tree/.build/logs/verify-package-test-strict.log" 2>/dev/null || true
    grep -oE 'tests [0-9]+ passed, [0-9]+ failed, [0-9]+ skipped' "$run/out" | sed 's/^/summary: /' || true
    # bash's own notice of the job that the limit ended must reach neither the log nor the
    # console, since it names the script by its path (finding 63).
    grep -h -e 'Terminated' "$run/tree/.build/logs/verify-package-test-strict.log" "$run/out" 2>/dev/null | sed 's/^/notice: /' || true
}
strict_hang="$(pool_strict "$ps/scripts" hang)"
cp -R "$ps/scripts" "$ps/unset-scripts"
sed -i '' 's/env LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test/env swift test/' "$ps/unset-scripts/verify.sh"
strict_unset="$(pool_strict "$ps/unset-scripts" unset)"
strict_skip_console="$(pool_strict "$ps/scripts" skip-console skip-console gate)"
strict_cancel_stream="$(pool_strict "$ps/scripts" cancel-stream cancel-stream gate)"
strict_fail="$(pool_strict "$ps/scripts" fail fail)"
pkill -KILL -f "$ps/stub/swift" 2>/dev/null || true
if [[ ${strict_hang%%$'\n'*} == 1 && $strict_hang == *"may be blocking a thread of the cooperative pool"* &&
    $strict_hang == *"started, not ended: aWaitThatBlocks()"* && $strict_hang != *"not ended: aPlainTest()"* &&
    $strict_hang != *"notice: "* &&
    ${strict_unset%%$'\n'*} == 0 ]] && ! cmp -s "$ps/scripts/verify.sh" "$ps/unset-scripts/verify.sh"; then
    pass "under the strict pool a suite that hangs fails package-test-strict, which names the test that had not ended; without the variable it would pass"
else
    fail "package-test-strict through verify's loop: a suite that hangs under the variable: $strict_hang; run without the variable, status ${strict_unset%%$'\n'*}"
fi
if [[ ${strict_skip_console%%$'\n'*} == 1 && ${strict_cancel_stream%%$'\n'*} == 1 &&
    $strict_cancel_stream == *"events: cancelled case: aWaitThatBlocks() (2)"* &&
    ${strict_fail%%$'\n'*} == 1 && $strict_fail == *"summary: tests 0 passed, 1 failed, 0 skipped"* ]]; then
    pass "at the gate the strict step fails on a skip the console shows and on a cancelled case the stream shows, and counts its failures once"
else
    fail "package-test-strict's skips and failures: a skip on the console alone at the gate: ${strict_skip_console%%$'\n'*}; a cancelled case in the stream alone at the gate: $strict_cancel_stream; a failure: $strict_fail"
fi

# The live smoke step (item 80): after launch and mac-ui it reads their results, and fails
# unless each platform's smoke test, found by its named comment in the sources, ran and
# passed in this run, and was not skipped. On a fixture tree of its own, so that it pins none
# of the real sources: three smoke tests named in its named-tests.txt, two in launch's logs
# and the Mac's in mac-ui's; a fourth, merged, marked in a package's test, which package-test
# runs and named-tests requires, so that this step says so and does not ask for it; and a
# fifth whose pull request has not merged, which is not asked for. The results are logs
# written for each run, in both of XCTest's forms.
st="$scratch/live-smoke"
mkdir -p "$st/tree/docs/plan" "$st/tree/Apps/iOS/UITests" "$st/tree/Apps/watchOS/UITests" "$st/tree/Apps/macOS/UITests" \
    "$st/tree/Packages/KnotKit/Tests/KnotEndToEndTests"
git -C "$st/tree" init -q -b main
printf 'WP-30 PR 1\tlive-smoke-a-iphone\tThe iPhone.\nWP-32 PR 1\tlive-smoke-a-watch\tThe Watch.\nWP-33 PR 1\tlive-smoke-a-mac\tThe Mac.\nWP-22 PR 2\tlive-smoke-a-composition\tA package test.\nWP-23 PR 1\tlive-smoke-a-later\tNot merged.\n' \
    >"$st/tree/docs/plan/named-tests.txt"
# Between each class and its test stands a line with the word class that declares no class: a
# comment, a class method, and Xcode's own class property. The test's class is the one
# declared, with its name before a colon or a brace, outside comments.
printf 'final class PhoneTests: XCTestCase {\n    /// `live-smoke-a-iphone`: type, kill, relaunch, read.\n    // This class launches the app once.\n    @MainActor\n    func testPhoneSmoke() throws {}\n}\n' \
    >"$st/tree/Apps/iOS/UITests/PhoneTests.swift"
printf '/// The smoke test (named test `live-smoke-a-watch`).\nfinal class WatchSmokeTests: XCTestCase {\n    override class func setUp() { super.setUp() }\n    func testWatchSmoke() throws {}\n}\n' \
    >"$st/tree/Apps/watchOS/UITests/WatchSmokeTests.swift"
printf '// live-smoke-a-mac: the Mac'"'"'s smoke test, named over its class and over its test.\nfinal class MacSmokeTests: XCTestCase {\n    override class var runsForEachTargetApplicationUIConfiguration: Bool { false }\n    // live-smoke-a-mac\n    func testMacSmoke() throws {}\n}\n' \
    >"$st/tree/Apps/macOS/UITests/MacSmokeTests.swift"
# The package's form of a named test: Swift Testing's, the slug in the test's name, a function
# of any name, and no comment.
printf 'import Testing\n\n@Test("live-smoke-a-composition", .tags(.named)) func theCompositionTypesKillsAndReads() async throws {}\n' \
    >"$st/tree/Packages/KnotKit/Tests/KnotEndToEndTests/CompositionSmokeTests.swift"
# A package test whose comment only mentions the iPhone's slug marks nothing: the UI test is
# looked for first, so a run in which the iPhone's test did not run still fails.
printf 'import Testing\n\n// As live-smoke-a-iphone does on the phone, this reads a line back.\n@Test func readsALineBack() async throws {}\n' \
    >"$st/tree/Packages/KnotKit/Tests/KnotEndToEndTests/MentionsTheIPhone.swift"
smoke_logs() { # smoke_logs <folder> <iPhone line> <Watch line> <Mac line>: fresh logs of a run
    mkdir -p "$1"
    printf '%s\n' "$2" >"$1/verify-launch-tests.log"
    printf '%s\n' "$3" >"$1/verify-launch-watch-tests.log"
    printf '%s\n' "$4" >"$1/verify-mac-ui-tests.log"
}
phone_ok="Test case 'PhoneTests.testPhoneSmoke()' passed on 'set-iphone - Runner (1)' (7.4 seconds)"
watch_ok="Test Case '-[Knot_watchOS_UITests.WatchSmokeTests testWatchSmoke]' passed (13.8 seconds)."
mac_ok="Test Case '-[Knot_macOS_UITests.MacSmokeTests testMacSmoke]' passed (133.4 seconds)."
smoke_start=$(($(date +%s) - 1))
smoke_logs "$st/all" "$phone_ok" "$watch_ok" "$mac_ok"
smoke_logs "$st/phone-missing" "Test case 'PhoneTests.testOther()' passed on 'set-iphone - Runner (1)' (1.0 seconds)" "$watch_ok" "$mac_ok"
smoke_logs "$st/watch-skipped" "$phone_ok" "Test Case '-[Knot_watchOS_UITests.WatchSmokeTests testWatchSmoke]' skipped (0.001 seconds)." "$mac_ok"
smoke_logs "$st/mac-old" "$phone_ok" "$watch_ok" "$mac_ok"
# The iPhone's test runs on two destinations, the iPhone and the iPad: it passed on one, and
# failed, or was skipped, on the other. Each fails the step: one destination's pass is not
# the test's.
smoke_logs "$st/pad-failed" "$phone_ok"$'\n'"Test case 'PhoneTests.testPhoneSmoke()' failed on 'set-ipad - Runner (1)' (180.0 seconds)" "$watch_ok" "$mac_ok"
smoke_logs "$st/pad-skipped" "$phone_ok"$'\n'"Test case 'PhoneTests.testPhoneSmoke()' skipped on 'set-ipad - Runner (1)' (0.0 seconds)" "$watch_ok" "$mac_ok"
touch -t 202001020304.05 "$st/mac-old/verify-mac-ui-tests.log"
# A tree in which a helper file's comment also names the iPhone's slug, and sorts first: the
# slug is marked in two places, which the step names, rather than judge the helper's test.
cp -R "$st/tree" "$st/tree-two-marks"
printf 'final class LaunchHelperTests: XCTestCase {\n    // Unlike live-smoke-a-iphone, this one does not kill the app.\n    func testLaunchOnly() throws {}\n}\n' \
    >"$st/tree-two-marks/Apps/iOS/UITests/AppLaunchHelpers.swift"
smoke_logs "$st/helper-ran" "Test case 'LaunchHelperTests.testLaunchOnly()' passed on 'set-iphone - Runner (1)' (2.0 seconds)" "$watch_ok" "$mac_ok"
smoke() { # smoke <logs> <mac-ui 0|1> [tree]: status and the check's lines
    python3 -I -B - "$KNOT_SCRIPTS/lib" "${3:-$st/tree}" "$1" "$smoke_start" "$2" <<'PY' 2>&1 || true
import contextlib, io, os, sys
sys.path.insert(0, sys.argv[1])
import knot_tool as k
os.chdir(sys.argv[2])
k.merged_prs = lambda source: [("WP-30", False), ("WP-32", False), ("WP-33", False), ("WP-22", False), ("WP-22", False)]
# The fixture's packages plan two pull requests each, of which the first has merged.
k.plan_rows = lambda package: ["1", "2"]
out = io.StringIO()
with contextlib.redirect_stdout(out):
    status = k.cmd_live_smoke(sys.argv[3], int(sys.argv[4]), sys.argv[5] == "1")
print(status)
print(out.getvalue())
PY
}
smoke_all="$(smoke "$st/all" 1)"
smoke_no_mac="$(smoke "$st/all" 0)"
smoke_phone="$(smoke "$st/phone-missing" 1)"
smoke_watch="$(smoke "$st/watch-skipped" 1)"
smoke_old="$(smoke "$st/mac-old" 1)"
# A Mac UI log that the gate took from the hosted job begins with the hosted header: the
# step judges the Mac's test from it as from a local log, and says it passed in the hosted job.
smoke_logs "$st/mac-hosted" "$phone_ok" "$watch_ok" "$mac_ok"
python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import knot_tool as k
open(sys.argv[2], "w").write(k.HOSTED_MAC_UI_HEADER + " check run 7, https://example.invalid/job/7, workflow run 99, commit abc.\n" + sys.argv[3] + "\n")' \
    "$KNOT_SCRIPTS/lib" "$st/mac-hosted/verify-mac-ui-tests.log" "$mac_ok"
smoke_hosted="$(smoke "$st/mac-hosted" 1)"
smoke_two="$(smoke "$st/helper-ran" 1 "$st/tree-two-marks")"
smoke_pad_failed="$(smoke "$st/pad-failed" 1)"
smoke_pad_skipped="$(smoke "$st/pad-skipped" 1)"
if [[ ${smoke_all%%$'\n'*} == 0 &&
    $smoke_all == *"live-smoke-a-composition"*"Packages/KnotKit/Tests/KnotEndToEndTests/CompositionSmokeTests.swift"*"a package test, which package-test runs"* &&
    $smoke_all == *"live-smoke-a-later"*"has not merged"* &&
    ${smoke_no_mac%%$'\n'*} == 0 && $smoke_no_mac == *"live-smoke-a-mac"*"not asked for"*"mac-ui"* &&
    ${smoke_phone%%$'\n'*} == 1 && $smoke_phone == *"live-smoke-a-iphone"*"did not pass"* &&
    ${smoke_watch%%$'\n'*} == 1 && $smoke_watch == *"live-smoke-a-watch"*"skipped"* &&
    ${smoke_old%%$'\n'*} == 1 && $smoke_old == *"live-smoke-a-mac"*"earlier run"* &&
    ${smoke_hosted%%$'\n'*} == 0 && $smoke_hosted == *"live-smoke-a-mac: MacSmokeTests.testMacSmoke passed in the hosted job mac-ui, check run 7, https://example.invalid/job/7"* &&
    ${smoke_two%%$'\n'*} == 1 && $smoke_two == *"live-smoke-a-iphone"*"more than one"*"AppLaunchHelpers.swift"*"PhoneTests.swift"* &&
    ${smoke_pad_failed%%$'\n'*} == 1 && $smoke_pad_failed == *"live-smoke-a-iphone"*"did not pass"*"passed, failed"* &&
    ${smoke_pad_skipped%%$'\n'*} == 1 && $smoke_pad_skipped == *"live-smoke-a-iphone"*"skipped"* ]]; then
    pass "the live smoke step asks each platform's smoke test, found by its named comment, to have passed in this run, and no other"
else
    fail "the live smoke step: all '$smoke_all'; without mac-ui '$smoke_no_mac'; the iPhone's missing '$smoke_phone'; the Watch's skipped '$smoke_watch'; an earlier run's Mac log '$smoke_old'; the hosted job's Mac log '$smoke_hosted'; two marks '$smoke_two'; passed on one destination and failed on the other '$smoke_pad_failed', skipped on the other '$smoke_pad_skipped'"
fi

# The packaging step's scan for the debug launch arguments (item 99): a file that holds one of
# the list's names is found, by name; one that holds none, or holds a name that is not on the
# list, is clean. The list is the tool's own.
da="$scratch/debug-arguments"
mkdir -p "$da"
printf 'some code\0-KnotTemporaryStore\0more code\n' >"$da/holds"
printf 'some code\0-KnotSomethingElse\0more code\n' >"$da/clean"
debug_list="$(python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" debug-arguments 2>&1 || true)"
debug_holds="$(bash -c 'source "$1"; knot_debug_arguments_in "$2" "$3"' _ "$KNOT_SCRIPTS/lib/common.sh" "$da/holds" "$debug_list" 2>&1 || true)"
debug_clean="$(bash -c 'source "$1"; knot_debug_arguments_in "$2" "$3" && echo found' _ "$KNOT_SCRIPTS/lib/common.sh" "$da/clean" "$debug_list" 2>&1 || true)"
if [[ $(grep -c . <<<"$debug_list") == 8 && $debug_list == *"-KnotPreview"*"-KnotEnterLine"* &&
    $debug_holds == "-KnotTemporaryStore" && -z $debug_clean ]]; then
    pass "the scan for debug launch arguments finds one of the list's names in a file, by name, and nothing in a clean one"
else
    fail "the scan for debug launch arguments: the list '$debug_list'; a file that holds one '$debug_holds'; a clean one '$debug_clean'"
fi

# The launch step's Mac part and the desktop (item 105). Its app has the bundle ID of every
# worktree's development build, so it comes to the front beside another worktree's Mac UI
# test: it takes the exclusive Mac UI slot for as long as its app is up, and no second build
# slot. And it builds the Mac app it starts, so that --only launch never starts an old one.
# a. build-slot.sh run --mac-ui-only holds the Mac UI slot and no build slot while its
#    command runs.
ms="$scratch/mac-ui-only"
mkdir -p "$ms/slots"
KNOT_SLOT_DIR="$ms/slots" "$KNOT_SCRIPTS/build-slot.sh" run --mac-ui-only --label self-test -- \
    bash -c 'for lock in "$1"/*.lock; do /usr/bin/lockf -s -t 0 -k "$lock" true || echo "held $(basename "$lock")"; done' _ "$ms/slots" \
    >"$ms/held" 2>&1 || true
# b. The Mac part builds the app, then starts it: a copy of scripts/ whose xcb and app start
#    are stand-ins that write what they did, run as the launch step runs it.
cp -R "$KNOT_SCRIPTS" "$ms/scripts"
mkdir -p "$ms/tree/.build/logs"
cp "$KNOT_SELF/.xcode-version" "$ms/tree/"
python3 -I - "$ms/scripts/verify.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
for name, body in (("xcb", 'echo built >>"$KNOT_MAC_PART"'),):
    start = text.index(name + "() {")
    end = text.index("\n}\n", start) + 3
    text = text[:start] + name + "() {\n    " + body + "\n}\n" + text[end:]
old = 'step_launch_mac() {'
# On a version with no Mac part of its own, the edit finds nothing and the case says so.
text = text.replace(old, 'knot_start_app() { echo started >>"$KNOT_MAC_PART"; echo "windows: 1 layer 0 320x240"; }\n' + old, 1)
open(path, "w").write(text)
PY
env KNOT_MAC_PART="$ms/did" KNOT_TREE="$ms/tree" KNOT_SLOT_DIR="$ms/slots" \
    "$ms/scripts/verify.sh" --in-step launch-mac >"$ms/part.out" 2>&1 || true
# c. The launch step starts its Mac part only that way, as a call of build-slot.sh with
#    --mac-ui-only, read with the wiring check's own shell reader.
launch_wiring="$(python3 -I -B - "$KNOT_SCRIPTS/lib" "$KNOT_SCRIPTS/verify.sh" <<'PY'
import os, re, sys
sys.path.insert(0, sys.argv[1])
import knot_tool as k
text = open(sys.argv[2]).read()
start = text.index("step_launch() {")
body = text[start:text.index("\n}\n", start)]
calls = [k.command_words(k.shell_words(segment), {}, {}) for _, _, segment in k.shell_segments(body)]
slot = [w for w in calls if w and os.path.basename(w[0]) == "build-slot.sh"]
starts = [w for w in calls if w and w[0] == "knot_start_app"]
print("slot" if any("--mac-ui-only" in w and "launch-mac" in w for w in slot) else "no-slot", "start" if starts else "no-start")
PY
)"
if [[ "$(cat "$ms/held")" == "held mac-ui.lock" && "$(tr '\n' ' ' <"$ms/did" 2>/dev/null)" == "built started " &&
    $launch_wiring == "slot no-start" ]]; then
    pass "the launch step's Mac part holds the Mac UI slot and no build slot, and builds the app before it starts it"
else
    fail "the launch step's Mac part: locks held '$(tr '\n' ' ' <"$ms/held")'; what the part did '$(tr '\n' ' ' <"$ms/did" 2>/dev/null)'; the step's calls '$launch_wiring'"
fi

# The step's place in each tier: after package-test in --full and in the gate's leaf and
# everything depths, and in neither --quick nor the gate of documents alone. And the live
# smoke step's: last in --full and the everything depth, after launch and mac-ui, whose
# results it reads (item 80); mac-ui is left out here, as --skip mac-ui and a diff that does
# not reach the Mac app leave it. A copy of
# scripts/ whose runner records each step's name and runs nothing, and whose gate takes its
# depth from KNOT_SELF_TEST_DEPTH, runs each tier on a scratch tree.
pl="$scratch/step-lists"
mkdir -p "$pl/tree"
cp -R "$KNOT_SCRIPTS" "$pl/scripts"
cp "$KNOT_SELF/.xcode-version" "$pl/tree/"
python3 -I - "$pl/scripts/verify.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
base_check = 'git -C "$KNOT_ROOT" rev-parse --verify --quiet "$BASE^{' + 'commit}" >/dev/null ||'
for old, new in (
    ('    options="$(slot_options "$step")"\n    runner="step_${step//-/_}"',
     '    options=none\n    runner=record_step'),
    (base_check, 'true ||'),
    ('depth_out="$(cd "$KNOT_ROOT" && tool depth --base "$BASE")"',
     'depth_out="$(printf \'depth=%s\\nmac_ui=0\\nsoak=0\\nhosted=0\\nreason=the self-test\\n\' "$KNOT_SELF_TEST_DEPTH")"'),
):
    assert old in text, old
    text = text.replace(old, new)
text = text.replace("for step in $STEPS; do\n    log=", 'record_step() { echo "$step" >>"$KNOT_STEP_RECORD"; }\nfor step in $STEPS; do\n    log=', 1)
open(path, "w").write(text)
PY
step_list() { # step_list <name> <depth> <verify arguments…>: the steps the tier ran, on one line
    local name=$1 depth=$2
    shift 2
    env -u KNOT_LOCAL_CONFIG KNOT_STEP_RECORD="$pl/$name" KNOT_SELF_TEST_DEPTH="$depth" KNOT_TREE="$pl/tree" \
        "$pl/scripts/verify.sh" "$@" >"$pl/$name.out" 2>&1 || true
    tr '\n' ' ' <"$pl/$name" 2>/dev/null || true
}
list_quick="$(step_list quick - --quick)"
list_full="$(step_list full - --full --skip mac-ui)"
list_leaf="$(step_list leaf leaf --gate --branch wp/01-self-test --package WP-01)"
list_everything="$(step_list everything everything --gate --branch wp/01-self-test --package WP-01)"
list_documents="$(step_list documents documents --gate --branch wp/01-self-test --package WP-01)"
if [[ $list_quick == *"package-test "* && $list_quick != *"package-test-strict"* &&
    $list_full == *"package-test package-test-strict "* && $list_leaf == *"package-test package-test-strict "* &&
    $list_everything == *"package-test package-test-strict "* && -n $list_documents && $list_documents != *"package-test"* &&
    $list_full == *" launch live-smoke " && $list_everything == *" launch live-smoke " &&
    $list_quick != *"live-smoke"* && $list_leaf != *"live-smoke"* && $list_documents != *"live-smoke"* ]]; then
    pass "package-test-strict follows package-test in --full and the gate's leaf and everything depths, and is in neither --quick nor a gate of documents; live-smoke comes last in --full and the everything depth, after launch and mac-ui"
else
    fail "the steps of each tier: quick '$list_quick'; full '$list_full'; gate leaf '$list_leaf'; everything '$list_everything'; documents '$list_documents'"
fi

# The team's ID leaves the logs the scripts keep, by pattern: the lines Xcode writes on a
# Mac that knows the team, with a made-up ID. The filter keeps everything else, and the
# scrub rewrites a kept log in place, keeping its time (item 115): the log of a step that an
# earlier run started, dated 2020 here, keeps that date, so that a reader of this run's logs
# does not take it for this run's.
fake_team="ZZ9QX42K7T"
team_log="$scratch/verify-apps.log"
{
    echo 'export TeamIdentifierPrefix\='"$fake_team"'. AppIdentifierPrefix\='"$fake_team"'.'
    echo '    "application-identifier" = "'"$fake_team"'.com.p3ob7o.knot.dev";'
    echo '    "com.apple.developer.team-identifier" = '"$fake_team"';'
    echo 'DEVELOPMENT_TEAM = '"$fake_team"
    echo 'keep: com.p3ob7o.knot.dev iCloud.com.p3ob7o.knot.dev Build version 27B52 KNOT_WORKTREE'
} >"$team_log"
touch -t 202001020304.05 "$team_log"
filtered="$(knot_filter_team <"$team_log")"
knot_scrub_logs "$scratch"
scrubbed_time="$(date -r "$(stat -f %m "$team_log")" +%Y%m%d%H%M.%S)"
if [[ $filtered != *"$fake_team"* && $filtered == *"keep: com.p3ob7o.knot.dev iCloud.com.p3ob7o.knot.dev Build version 27B52"* &&
    $(grep -c -e '<TEAM>' "$team_log") == 4 && $scrubbed_time == 202001020304.05 ]] && ! grep -e "$fake_team" "$team_log" >/dev/null; then
    pass "the team's ID leaves a build log, by pattern, and the rest stays, and the scrubbed log keeps its time"
else
    fail "the team filter left an ID or took too much, or the scrub changed the log's time to $scrubbed_time: $filtered"
fi

# At the start of a whole run, a tier, the earlier run's logs go aside, to .build/logs-earlier/,
# so that no file in .build/logs/ after the run is older than it: an earlier run's soak output,
# dated 2020 here, a screenshot and a hidden file move, keeping their times, and the run before
# that, in logs-earlier/ already, is gone. A run of one step, --only, leaves the whole run's
# logs where they are, and moves nothing. Through verify.sh's loop, `--perf` and then
# `--only doctor`, with the doctor and the perf step stand-ins, on a scratch tree.
la="$scratch/logs-aside"
mkdir -p "$la/tree/.build/logs" "$la/tree/.build/logs-earlier" "$la/slots"
cp "$KNOT_SELF/.xcode-version" "$la/tree/"
cp -R "$KNOT_SCRIPTS" "$la/scripts"
python3 -I - "$la/scripts/verify.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
for name, body in (("step_doctor", 'echo "doctor stand-in"; [[ -z ${KNOT_LA_EXTRA:-} ]] || printf "TeamIdentifierPrefix=%s.\\n" "$KNOT_LA_EXTRA" >"$KNOT_LOGS/verify-doctor-extra.out"'), ("step_perf", 'echo "perf stand-in"')):
    start = text.index(name + "() {")
    end = text.index("\n}\n", start) + 3
    text = text[:start] + name + "() {\n    " + body + "\n}\n" + text[end:]
open(path, "w").write(text)
PY
printf 'capture ledger soak: RED with seed 1\nTeamIdentifierPrefix=%s.\n' "$fake_team" >"$la/tree/.build/logs/verify-soak.out"
touch -t 202001020304.05 "$la/tree/.build/logs/verify-soak.out"
printf 'png\n' >"$la/tree/.build/logs/launch-iphone.png"
printf 'hidden\n' >"$la/tree/.build/logs/.earlier-hidden"
printf 'older\n' >"$la/tree/.build/logs-earlier/verify-older-run.log"
la_started=$(knot_now)
la_status=0
env KNOT_TREE="$la/tree" KNOT_SLOT_DIR="$la/slots" "$la/scripts/verify.sh" --perf >"$la/out" 2>&1 || la_status=$?
la_old=""
for f in "$la/tree/.build/logs"/* "$la/tree/.build/logs"/.[!.]*; do
    [[ -e $f ]] || continue
    (($(stat -f %m "$f") >= la_started)) || la_old="$la_old $(basename "$f")"
done
la_aside="$(cd "$la/tree/.build/logs-earlier" && ls -A | tr '\n' ' ')"
la_soak_time="$(date -r "$(stat -f %m "$la/tree/.build/logs-earlier/verify-soak.out" 2>/dev/null || echo 0)" +%Y%m%d%H%M.%S)"
# Then one step alone: the whole run's logs stay, and logs-earlier/ is as the whole run left it.
# A log another run may still be writing, which holds an ID, is not touched: same inode, same
# text. The run's own output, written unfiltered by its step, is scrubbed at its end.
printf 'TeamIdentifierPrefix=%s.\n' "$fake_team" >"$la/tree/.build/logs/verify-live-elsewhere.log"
la_live_inode="$(stat -f %i "$la/tree/.build/logs/verify-live-elsewhere.log")"
la_only_status=0
env KNOT_TREE="$la/tree" KNOT_SLOT_DIR="$la/slots" KNOT_LA_EXTRA="$fake_team" "$la/scripts/verify.sh" --only doctor >"$la/only.out" 2>&1 || la_only_status=$?
la_live="$( [[ "$(stat -f %i "$la/tree/.build/logs/verify-live-elsewhere.log")" == "$la_live_inode" ]] && grep -c -e "$fake_team" "$la/tree/.build/logs/verify-live-elsewhere.log" || echo moved)"
la_own="$(grep -c -e "$fake_team" "$la/tree/.build/logs/verify-doctor-extra.out" 2>/dev/null || true)/$(grep -c -e '<TEAM>' "$la/tree/.build/logs/verify-doctor-extra.out" 2>/dev/null || true)"
la_after_only="$(cd "$la/tree/.build/logs" && ls | tr '\n' ' ')"
la_aside_after_only="$(cd "$la/tree/.build/logs-earlier" && ls -A | tr '\n' ' ')"
if [[ $la_status == 0 && -z $la_old && -f $la/tree/.build/logs/verify-perf.log &&
    $la_aside == ".earlier-hidden launch-iphone.png verify-soak.out " && $la_soak_time == 202001020304.05 &&
    $la_only_status == 0 && $la_after_only == *"verify-perf.log"* && $la_after_only == *"verify-doctor.log"* &&
    $la_live == 1 && $la_own == 0/1 &&
    $la_aside_after_only == "$la_aside" ]] &&
    ! grep -e "$fake_team" "$la/tree/.build/logs-earlier/verify-soak.out" >/dev/null; then
    pass "a whole run moves the earlier run's logs aside, scrubbed and keeping their times, and the run before that goes; a run of one step moves nothing"
else
    fail "the earlier run's logs at a run's start: status $la_status, older files left in logs/:${la_old:- none}, logs-earlier holds '$la_aside', the soak's time $la_soak_time; after --only doctor ($la_only_status): logs '$la_after_only', logs-earlier '$la_aside_after_only', another run's live log $la_live, its own output $la_own: $(tail -n 5 "$la/out")"
fi
# A step whose wait for a build slot runs out did not run, and is named apart from a failure:
# --perf, which takes every slot, with one of them held and a wait of 2 s, ends NOT RUN with
# its own status, 4.
/usr/bin/lockf -k "$la/slots/build-1.lock" sleep 20 &
la_holder=$!
for _ in $(seq 1 50); do /usr/bin/lockf -s -t 0 -k "$la/slots/build-1.lock" true 2>/dev/null || break; sleep 0.1; done
la_slot_status=0
env KNOT_TREE="$la/tree" KNOT_SLOT_DIR="$la/slots" KNOT_SLOT_TIMEOUT=2 "$la/scripts/verify.sh" --perf >"$la/no-slot.out" 2>&1 || la_slot_status=$?
kill "$la_holder" 2>/dev/null || true
wait "$la_holder" 2>/dev/null || true
if [[ $la_slot_status == 4 ]] && grep -e '^verify: NOT RUN perf .*no build slot came free' "$la/no-slot.out" >/dev/null &&
    grep -e '^verify --perf: NOT RUN' "$la/no-slot.out" >/dev/null && ! grep -e '^verify: FAIL' "$la/no-slot.out" >/dev/null &&
    grep -e 'perf NOT RUN at perf, no slot' "$la/tree/.build/logs/verify-status.txt" >/dev/null; then
    pass "a step whose wait for a slot runs out is NOT RUN, with a status of its own, not a failure"
else
    fail "a step with no slot: status $la_slot_status: $(grep -e '^verify' "$la/no-slot.out" | tr '\n' '|')"
fi

# Four more forms that a signed build or codesign can print, and the ID wherever it stands
# when the run names the owner's configuration and so knows it. The configuration here is
# made up, with the same made-up ID.
forms="$(
    printf '%s\n' '"'"$fake_team"'.*"' "<string>$fake_team</string>" \
        "        [String] $fake_team" 'Apple Development: Someone ('"$fake_team"')' |
        env -u KNOT_TEAM_CONFIG -u KNOT_LOCAL_CONFIG bash -c 'source "$1"; knot_filter_team' _ "$KNOT_SCRIPTS/lib/common.sh"
)"
printf 'DEVELOPMENT_TEAM = %s\n' "$fake_team" >"$scratch/Owner.xcconfig"
loose="a note that names $fake_team where no key stands before it"
literal="$(printf '%s\n' "$loose" | KNOT_TEAM_CONFIG="$scratch/Owner.xcconfig" bash -c 'source "$1"; knot_filter_team' _ "$KNOT_SCRIPTS/lib/common.sh")"
unknown="$(printf '%s\n' "$loose" | env -u KNOT_TEAM_CONFIG -u KNOT_LOCAL_CONFIG bash -c 'source "$1"; knot_filter_team' _ "$KNOT_SCRIPTS/lib/common.sh")"
# A tree into which bootstrap linked the configuration knows the ID too, with neither
# variable set, as the team-ID step falls back to it.
mkdir -p "$scratch/linked-tree/.build/config"
cp "$scratch/Owner.xcconfig" "$scratch/linked-tree/.build/config/Local.xcconfig"
linked="$(printf '%s\n' "$loose" | env -u KNOT_TEAM_CONFIG -u KNOT_LOCAL_CONFIG KNOT_TREE="$scratch/linked-tree" \
    bash -c 'source "$1"; knot_filter_team' _ "$KNOT_SCRIPTS/lib/common.sh")"
if [[ $forms != *"$fake_team"* && $(grep -c -e '<TEAM>' <<<"$forms") == 4 && $literal == "${loose/$fake_team/<TEAM>}" &&
    $linked == "$literal" && $unknown == "$loose" ]]; then
    pass "the filter masks the quoted wildcard, a plist string, codesign's value and a certificate's name, and the known ID anywhere, from a variable or the linked configuration"
else
    fail "the filter left an ID in: $forms / $literal / $linked"
fi

# A UI test run counts only when its cases ran and passed: a run that executed 0 tests, one
# with a failed case, and one with no pass on a destination it should have run on all fail.
xct="$scratch/xctest"
mkdir -p "$xct"
printf "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds\n** TEST SUCCEEDED **\n" >"$xct/zero.log"
printf "Test Case '-[UITests.Launch testMark]' passed (5.7 seconds).\n" >"$xct/serial.log"
printf "Test case 'Launch.testMark()' passed on 'set-iphone - Runner (1)' (7.4 seconds)\nTest case 'Launch.testMark()' passed on 'set-ipad - Runner (2)' (6.9 seconds)\n" >"$xct/both.log"
printf "Test case 'Launch.testMark()' passed on 'set-iphone - Runner (1)' (7.4 seconds)\n" >"$xct/one.log"
printf "Test Case '-[UITests.Launch testMark]' passed (5.7 seconds).\nTest Case '-[UITests.Launch testOther]' failed (1.0 seconds).\n" >"$xct/failed.log"
cases=0
knot_xctest_result "$xct/zero.log" >/dev/null || cases=$((cases + 1))
knot_xctest_result "$xct/serial.log" >/dev/null && cases=$((cases + 1))
knot_xctest_result "$xct/both.log" set-iphone set-ipad >/dev/null && cases=$((cases + 1))
knot_xctest_result "$xct/one.log" set-iphone set-ipad >/dev/null || cases=$((cases + 1))
knot_xctest_result "$xct/failed.log" >/dev/null || cases=$((cases + 1))
if ((cases == 5)); then
    pass "a UI test run counts only when its cases ran and passed, on each destination"
else
    fail "the UI test judge was right on $cases of 5 logs"
fi

# When a UI test fails, the step's own log gives the failing case's error lines, by file and
# line with no folder, and names the longer log, so the gate's failure shows the reason.
# Through verify.sh's loop: a copy of scripts/ in which the doctor is a stand-in, the project
# is not generated, xcb prints a made-up failing run into the test log, and a stub ioreg says
# the screen is unlocked; the Mac UI step runs on a scratch tree with scratch slots.
ul="$scratch/ui-loop"
mkdir -p "$ul/tree" "$ul/slots" "$ul/stub"
cp -R "$KNOT_SCRIPTS" "$ul/scripts"
cp "$KNOT_SELF/.xcode-version" "$ul/tree/"
python3 -I - "$ul/scripts/verify.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
for name, body in (("step_doctor", 'echo "doctor stand-in"'),
                   ("xcb", 'cat "$KNOT_UI_RUN" >>"$1"')):
    start = text.index(name + "() {")
    end = text.index("\n}\n", start) + 3
    text = text[:start] + name + "() {\n    " + body + "\n}\n" + text[end:]
for old, new in (
    ('    knot_generate_project\n    ui_tests "The Mac UI tests"', '    ui_tests "The Mac UI tests"'),
    ('    knot_generate_project\n    knot_run_limited "The hosted iOS tests"', '    knot_run_limited "The hosted iOS tests"'),
    ("export KNOT_VERIFY_TIER=$TIER", "export KNOT_VERIFY_TIER=${KNOT_UI_TIER:-$TIER}"),
):
    assert old in text, old
    text = text.replace(old, new)
open(path, "w").write(text)
PY
# The hosted step's simulators: a stand-in that names one and boots nothing.
printf '#!/bin/sh\n[ "$1" = udid ] && echo SELF-TEST-UDID\nexit 0\n' >"$ul/scripts/sim.sh"
chmod +x "$ul/scripts/sim.sh"
printf '#!/bin/sh\nprintf "<plist version=\\"1.0\\"><dict><key>IOConsoleLocked</key><false/></dict></plist>\\n"\n' >"$ul/stub/ioreg"
chmod +x "$ul/stub/ioreg"
cat >"$ul/run.log" <<'LOG'
Test Case '-[Knot_macOS_UITests.KnotMacLaunchTests testLaunchShowsTheMark]' started.
/tmp/self-test-tree/Apps/UITestSupport/AccessibilityAudit.swift:53: error: -[Knot_macOS_UITests.KnotMacLaunchTests testLaunchShowsTheMark] : Element has no description: a made-up button
Test Case '-[Knot_macOS_UITests.KnotMacLaunchTests testLaunchShowsTheMark]' failed (3.204 seconds).
** TEST FAILED **
LOG
ui_status=0
env PATH="$ul/stub:$PATH" KNOT_UI_RUN="$ul/run.log" KNOT_TREE="$ul/tree" KNOT_SLOT_DIR="$ul/slots" \
    "$ul/scripts/verify.sh" --only mac-ui >"$ul/out" 2>&1 || ui_status=$?
ui_step_log="$(cat "$ul/tree/.build/logs/verify-mac-ui.log" 2>/dev/null || true)"
if [[ $ui_status != 0 && $ui_step_log == *"AccessibilityAudit.swift:53: error: "*"Element has no description"* &&
    $ui_step_log == *".build/logs/verify-mac-ui-tests.log"* && $ui_step_log != *"/tmp/self-test-tree/"* &&
    "$(cat "$ul/out")" == *"AccessibilityAudit.swift:53: error: "* ]]; then
    pass "a failed UI test's error lines are in the step's log and the run's failure, and the longer log is named"
else
    fail "a failed UI test through verify's loop, status $ui_status: the step's log: $ui_step_log"
fi
# A run with twenty-five error lines gives twenty, and says that five more are in the long log.
for n in $(seq 1 25); do
    echo "/tmp/self-test-tree/Apps/UITestSupport/AccessibilityAudit.swift:$n: error: -[Knot_macOS_UITests.KnotMacLaunchTests testLaunchShowsTheMark] : made-up error $n"
done >"$ul/many.log"
echo "Test Case '-[Knot_macOS_UITests.KnotMacLaunchTests testLaunchShowsTheMark]' failed (3.204 seconds)." >>"$ul/many.log"
mkdir -p "$ul/many-slots"
env PATH="$ul/stub:$PATH" KNOT_UI_RUN="$ul/many.log" KNOT_TREE="$ul/tree" KNOT_SLOT_DIR="$ul/many-slots" \
    "$ul/scripts/verify.sh" --only mac-ui >"$ul/many.out" 2>&1 || true
ui_many_log="$(cat "$ul/tree/.build/logs/verify-mac-ui.log" 2>/dev/null || true)"
if [[ "$(grep -c -e 'made-up error' <<<"$ui_many_log")" == 20 && $ui_many_log == *"5 more error lines are in"* ]]; then
    pass "a failed UI run's error lines are cut at twenty, and the step says how many more the long log holds"
else
    fail "a failed UI run with 25 error lines: the step's log: $ui_many_log"
fi

# A skipped XCTest case, or a skipped test in the hosted run, is counted as skipped, and at
# the gate it fails the step, as the package's tests do: in the Mac UI step one case passed
# and one was skipped, and in the hosted iOS run one test passed and one was skipped. At the
# quick tier both steps pass, and the summary counts the skipped one.
cat >"$ul/ui-skip.log" <<'LOG'
Test Case '-[Knot_macOS_UITests.KnotMacLaunchTests testLaunchShowsTheMark]' passed (5.702 seconds).
Test Case '-[Knot_macOS_UITests.KnotMacLaunchTests testNeedsAnotherMac]' skipped (0.001 seconds).
** TEST SUCCEEDED **
LOG
cat >"$ul/hosted-skip.log" <<'LOG'
􁁛  Test aHostedTest() passed after 0.001 seconds.
􀙟  Test aHostedTestWithoutItsModel() skipped: "the model is not on this Mac"
􁁛  Test run with 2 tests in 1 suite passed after 0.005 seconds.
** TEST SUCCEEDED **
LOG
skip_step() { # skip_step <step> <run log> <tier>: status, the step's line and the summary's tests
    local status=0 run="$ul/skip-$1-$3"
    mkdir -p "$run/slots"
    env PATH="$ul/stub:$PATH" KNOT_UI_RUN="$2" KNOT_UI_TIER="$3" KNOT_TREE="$ul/tree" KNOT_SLOT_DIR="$run/slots" \
        "$ul/scripts/verify.sh" --only "$1" >"$run/out" 2>&1 || status=$?
    printf '%s %s · %s' "$status" "$(sed -n -E "s/^verify: (ok|FAIL) +$1 .*/\1/p" "$run/out")" \
        "$(grep -oE 'tests [0-9]+ passed, [0-9]+ failed, [0-9]+ skipped' "$run/out" || true)"
}
ui_gate="$(skip_step mac-ui "$ul/ui-skip.log" gate)"
ui_quick="$(skip_step mac-ui "$ul/ui-skip.log" quick)"
hosted_gate="$(skip_step ios-hosted "$ul/hosted-skip.log" gate)"
hosted_quick="$(skip_step ios-hosted "$ul/hosted-skip.log" quick)"
if [[ $ui_gate == "1 FAIL · tests 1 passed, 0 failed, 1 skipped" && $ui_quick == "0 ok · tests 1 passed, 0 failed, 1 skipped" &&
    $hosted_gate == "1 FAIL · tests 2 passed, 0 failed, 1 skipped" && $hosted_quick == "0 ok · tests 2 passed, 0 failed, 1 skipped" ]]; then
    pass "a skipped XCTest case or hosted test is counted, and fails the Mac UI and hosted steps at the gate"
else
    fail "skipped UI and hosted tests through verify's loop: Mac UI at the gate '$ui_gate', at the quick tier '$ui_quick'; hosted at the gate '$hosted_gate', at the quick tier '$hosted_quick'"
fi

# An xcodebuild ended by a signal that the step's limit did not send (finding 66): the step
# says so, with the signal's number, and does not judge the run as one with no tests; and
# bash's own notice of the killed command, which names the script by its path, reaches
# neither the log nor the console. A copy of scripts/ with the real xcb, its doctor a
# stand-in, no project generated and a stand-in sim.sh, runs the Mac UI step and the hosted
# step with a stub xcodebuild that writes `** BUILD INTERRUPTED **` and dies by TERM.
us="$scratch/signal-loop"
mkdir -p "$us/tree" "$us/stub"
cp -R "$KNOT_SCRIPTS" "$us/scripts"
cp "$KNOT_SELF/.xcode-version" "$us/tree/"
python3 -I - "$us/scripts/verify.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
start = text.index("step_doctor() {")
end = text.index("\n}\n", start) + 3
text = text[:start] + 'step_doctor() {\n    echo "doctor stand-in"\n}\n' + text[end:]
for old, new in (
    ('    knot_generate_project\n    ui_tests "The Mac UI tests"', '    ui_tests "The Mac UI tests"'),
    ('    knot_generate_project\n    knot_run_limited "The hosted iOS tests"', '    knot_run_limited "The hosted iOS tests"'),
):
    assert old in text, old
    text = text.replace(old, new)
open(path, "w").write(text)
PY
printf '#!/bin/sh\n[ "$1" = udid ] && echo SELF-TEST-UDID\nexit 0\n' >"$us/scripts/sim.sh"
chmod +x "$us/scripts/sim.sh"
printf '#!/bin/sh\nprintf "<plist version=\\"1.0\\"><dict><key>IOConsoleLocked</key><false/></dict></plist>\\n"\n' >"$us/stub/ioreg"
printf '#!/bin/sh\n[ "$1" = -version ] && exec /usr/bin/xcodebuild -version\necho "** BUILD INTERRUPTED **"\nkill -TERM $$\n' >"$us/stub/xcodebuild"
chmod +x "$us/stub/ioreg" "$us/stub/xcodebuild"
signal_step() { # signal_step <step>: status, the step's log, and any notice on the console
    local status=0 run="$us/run-$1"
    mkdir -p "$run/slots"
    env PATH="$us/stub:$PATH" KNOT_TREE="$us/tree" KNOT_SLOT_DIR="$run/slots" \
        "$us/scripts/verify.sh" --only "$1" >"$run/out" 2>&1 || status=$?
    echo "$status"
    cat "$us/tree/.build/logs/verify-$1.log" 2>/dev/null || true
    grep -h -e 'Terminated' "$run/out" 2>/dev/null | sed 's/^/notice: /' || true
}
signal_ui="$(signal_step mac-ui)"
signal_hosted="$(signal_step ios-hosted)"
if [[ ${signal_ui%%$'\n'*} == 1 && $signal_ui == *"ended by signal 15 (TERM)"*"did not send"* && $signal_ui != *"xctest: 0 passed"* &&
    ${signal_hosted%%$'\n'*} == 1 && $signal_hosted == *"ended by signal 15 (TERM)"*"did not send"* && $signal_hosted != *"No hosted test ran"* &&
    $signal_ui != *"Terminated"* && $signal_hosted != *"Terminated"* ]]; then
    pass "an xcodebuild ended by a signal from outside the step is named so, with its number, in the UI and hosted steps, and bash's notice of it reaches no log"
else
    fail "an xcodebuild ended by a signal from outside: the Mac UI step: $signal_ui; the hosted step: $signal_hosted"
fi

# sdk-path.sh finds a framework of the SDK, and one that the platform keeps outside it, as
# XCUIAutomation, which UI tests import, and XCTest are, under the platform's
# Developer/Library/Frameworks. It prints every folder that declares the framework: the
# headers, where XCUIApplication is declared, and the Swift module beside them, where
# SwiftUI declares nearly everything; in the pinned Xcode.
sdk_sdk="$("$KNOT_SCRIPTS/sdk-path.sh" macos SwiftUI 2>&1 || true)"
sdk_ui="$("$KNOT_SCRIPTS/sdk-path.sh" macos XCUIAutomation 2>&1 || true)"
sdk_ios_ui="$("$KNOT_SCRIPTS/sdk-path.sh" ios-simulator XCUIAutomation 2>&1 || true)"
sdk_ui_headers="$(sed -n '/\/Headers$/p' <<<"$sdk_ui")"
if [[ $sdk_sdk == */SDKs/*/SwiftUI.framework/Headers*/SwiftUI.framework/Modules/SwiftUI.swiftmodule &&
    $sdk_ui == */MacOSX.platform/Developer/Library/Frameworks/XCUIAutomation.framework/Headers*XCUIAutomation.framework/Modules/XCUIAutomation.swiftmodule &&
    -n $sdk_ui_headers && -n "$(grep -l -e '@interface XCUIApplication' "$sdk_ui_headers"/*.h 2>/dev/null || true)" &&
    $sdk_ios_ui == */iPhoneSimulator.platform/Developer/Library/Frameworks/XCUIAutomation.framework/Headers* ]]; then
    pass "sdk-path.sh prints the headers and the Swift module of a framework, in the SDK or in the platform's own frameworks"
else
    fail "sdk-path.sh: SwiftUI '$sdk_sdk', XCUIAutomation on the Mac '$sdk_ui', on the iOS simulator '$sdk_ios_ui'"
fi

# XcodeGen is chosen by the scripts, not by PATH (docs/dev-setup.md): KNOT_XCODEGEN, else the
# pinned release under the build folder's tools/, else xcodegen on PATH, and its version is
# checked again just before it generates. The stubs answer --version from a file beside them
# and, asked to generate, write their name into a marker.
xg="$scratch/xcodegen"
make_xcodegen() { # make_xcodegen <folder> <name> <version>
    mkdir -p "$1"
    printf '%s\n' "$3" >"$1/version"
    printf '#!/bin/sh\ncase $1 in\n    --version) echo "Version: $(cat "$(dirname "$0")/version")" ;;\n    generate) echo %s >"$KNOT_STUB_MARK" ;;\nesac\n' "$2" >"$1/xcodegen"
    chmod +x "$1/xcodegen"
}
pinned_dir="tools/xcodegen-$KNOT_XCODEGEN_VERSION/xcodegen/bin"
make_xcodegen "$xg/path-wrong" path-wrong 2.48.0
make_xcodegen "$xg/path-right" path-right "$KNOT_XCODEGEN_VERSION"
make_xcodegen "$xg/folder/$pinned_dir" pinned "$KNOT_XCODEGEN_VERSION"
make_xcodegen "$xg/named-wrong" named-wrong 2.48.0
make_xcodegen "$xg/moving/$pinned_dir" moving "$KNOT_XCODEGEN_VERSION"
mkdir -p "$xg/empty-folder" "$xg/tree"
cp "$KNOT_SELF/project.yml" "$xg/tree/"
# xg_doctor <build folder> <PATH entry> [KNOT_XCODEGEN]: the doctor's XcodeGen line or failure.
xg_doctor() {
    env -u KNOT_XCODEGEN PATH="$2:$PATH" KNOT_BUILD_FOLDER="$1" ${3:+KNOT_XCODEGEN="$3"} \
        "$KNOT_SCRIPTS/doctor.sh" 2>&1 | grep -A2 -e "infra-xcodegen" -e "^doctor: ok    xcodegen" || true
}
# xg_generate <build folder> <PATH entry> [KNOT_XCODEGEN]: generates in a scratch tree, and
# prints the failure, if any, and the name of the stub that generated, if one did.
xg_generate() {
    rm -f "$xg/mark"
    env -u KNOT_XCODEGEN PATH="$2:$PATH" KNOT_BUILD_FOLDER="$1" KNOT_TREE="$xg/tree" KNOT_STUB_MARK="$xg/mark" \
        ${3:+KNOT_XCODEGEN="$3"} bash -c 'source "$1"; knot_generate_project' _ "$KNOT_SCRIPTS/lib/common.sh" 2>&1 || true
    [[ -f $xg/mark ]] && echo "generated by $(cat "$xg/mark")"
    return 0
}
doctor_out="$(xg_doctor "$xg/folder" "$xg/path-wrong")"
generate_out="$(xg_generate "$xg/folder" "$xg/path-wrong")"
if [[ $doctor_out == *"ok"*"xcodegen"* && $doctor_out != *"infra-xcodegen"* && $generate_out == "generated by pinned" ]]; then
    pass "the build folder's XcodeGen wins over another version on PATH, for the doctor and for generation"
else
    fail "XcodeGen with the wrong version on PATH and the pinned one in the build folder: $doctor_out / $generate_out"
fi
doctor_out="$(xg_doctor "$xg/folder" "$xg/path-right" "$xg/named-wrong/xcodegen")"
generate_out="$(xg_generate "$xg/folder" "$xg/path-right" "$xg/named-wrong/xcodegen")"
if [[ $doctor_out == *"infra-xcodegen-version"* && $doctor_out == *KNOT_XCODEGEN* &&
    $generate_out == *"infra-xcodegen-version"* && $generate_out == *KNOT_XCODEGEN* && $generate_out != *"generated by"* ]]; then
    pass "KNOT_XCODEGEN naming another version fails as infra-xcodegen-version, naming the variable"
else
    fail "KNOT_XCODEGEN naming another version: $doctor_out / $generate_out"
fi
doctor_out="$(xg_doctor "$xg/empty-folder" "$xg/path-right")"
generate_out="$(xg_generate "$xg/empty-folder" "$xg/path-right")"
if [[ $doctor_out == *"ok"*"xcodegen"* && $doctor_out != *"infra-xcodegen"* && $generate_out == "generated by path-right" ]]; then
    pass "with no pinned copy, the pinned version on PATH serves, as on a hosted runner"
else
    fail "no pinned copy and the right version on PATH: $doctor_out / $generate_out"
fi
doctor_out="$(xg_doctor "$xg/moving" "$xg/path-wrong")"
printf '2.48.0\n' >"$xg/moving/$pinned_dir/version"
generate_out="$(xg_generate "$xg/moving" "$xg/path-wrong")"
if [[ $doctor_out == *"ok"*"xcodegen"* && $doctor_out != *"infra-xcodegen"* &&
    $generate_out == *"infra-xcodegen-version"* && $generate_out != *"generated by"* ]]; then
    pass "an XcodeGen that changes version after the doctor fails generation, which generates nothing"
else
    fail "XcodeGen that changed after the doctor: $doctor_out / $generate_out"
fi

# The packaging step's reading of an app's App Intents metadata: an action among its actions,
# and App Shortcuts that are not empty, naming their intents. On fixture metadata, in the form
# the build writes: a key of actions, and autoShortcuts with each shortcut's actionIdentifier.
ai="$scratch/app-intents"
mkdir -p "$ai"
printf '{"actions": {"CreateNoteIntent": {}, "FindNotesIntent": {}}, "autoShortcuts": [{"actionIdentifier": "CreateNoteIntent"}]}\n' >"$ai/full.json"
printf '{"actions": {"KnotPlaceholderIntent": {}}, "autoShortcuts": []}\n' >"$ai/empty.json"
printf 'not json\n' >"$ai/broken.json"
app_intents() { python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" app-intents --metadata "$@" >/dev/null 2>&1 && echo pass || echo fail; }
ai_found="$(app_intents "$ai/full.json" --action CreateNoteIntent)"
ai_missing="$(app_intents "$ai/empty.json" --action CreateNoteIntent)"
ai_shortcuts="$(app_intents "$ai/full.json" --shortcuts)"
ai_no_shortcuts="$(app_intents "$ai/empty.json" --shortcuts)"
ai_broken="$(app_intents "$ai/broken.json" --shortcuts)"
ai_absent="$(app_intents "$ai/none.json" --action CreateNoteIntent)"
if [[ "$ai_found $ai_missing $ai_shortcuts $ai_no_shortcuts $ai_broken $ai_absent" == "pass fail pass fail fail fail" ]]; then
    pass "the packaging step finds an intent among an app's actions and its App Shortcuts not empty, and fails without them"
else
    fail "an app's App Intents metadata: the intent there '$ai_found', missing '$ai_missing'; shortcuts '$ai_shortcuts', none '$ai_no_shortcuts'; unreadable '$ai_broken', absent '$ai_absent'"
fi

# The recorder's step in the iOS Simulator passes only when state-check says ok and the kill
# test passes all seven trials, and fails, naming the seed, on any other verdict. The step's
# function from verify.sh, with stand-in crash hosts that print a verdict chosen per run, a
# stand-in sim.sh, and builds that do nothing.
rs="$scratch/recorder-sim"
mkdir -p "$rs/scripts" "$rs/swiftpm/out/Products/Debug" "$rs/build/DerivedData-crash-hosts/Build/Products/Debug-iphonesimulator"
printf '#!/bin/bash\n[[ $1 == udid ]] && echo SIM-UDID\nexit 0\n' >"$rs/scripts/sim.sh"
cat >"$rs/swiftpm/out/Products/Debug/KnotAudioCrashHost" <<'HOST'
#!/bin/bash
case $1 in
    state-check) echo "state-check ${KNOT_SELF_TEST_STATE:-ok}"; [[ ${KNOT_SELF_TEST_STATE:-ok} == ok ]] ;;
    kill-test) echo "summary trials 7 passed ${KNOT_SELF_TEST_PASSED:-7} maxLossMs 0.0 seed 5"; [[ ${KNOT_SELF_TEST_PASSED:-7} == 7 ]] ;;
esac
HOST
cp "$rs/swiftpm/out/Products/Debug/KnotAudioCrashHost" "$rs/build/DerivedData-crash-hosts/Build/Products/Debug-iphonesimulator/"
chmod +x "$rs/scripts/sim.sh" "$rs/swiftpm/out/Products/Debug/KnotAudioCrashHost" \
    "$rs/build/DerivedData-crash-hosts/Build/Products/Debug-iphonesimulator/KnotAudioCrashHost"
recorder_sim() { # recorder_sim [env…]: the step's status and its last line
    python3 -I - "$KNOT_SCRIPTS/verify.sh" "$KNOT_SCRIPTS/lib/common.sh" "$rs" <<'PY' | env "$@" bash 2>&1 | tail -n 1 || true
import sys
text = open(sys.argv[1]).read()
start = text.index("crash_host_for_simulator() {")
body = text[start:text.index("\n}\n", text.index("step_recorder_sim() {")) + 3]
rs = sys.argv[3]
print(f'source "{sys.argv[2]}"')
print(f'KNOT_SCRIPTS="{rs}/scripts" KNOT_SWIFTPM="{rs}/swiftpm" KNOT_BUILD="{rs}/build" KNOT_LOGS="{rs}" SEED=5')
print(body)
print('knot_run_limited() { :; }')
print('step_recorder_sim & code=0; wait $! || code=$?; echo "status $code"')
PY
}
rs_ok="$(recorder_sim)"
rs_state="$(recorder_sim KNOT_SELF_TEST_STATE="FAIL the state read is not the state written")"
rs_kill="$(recorder_sim KNOT_SELF_TEST_PASSED=6)"
if [[ $rs_ok == "status 0" && $rs_state == "status 1" && $rs_kill == "status 1" ]]; then
    pass "the recorder's step in the iOS Simulator passes on state-check ok and seven trials passed, and fails on any other verdict"
else
    fail "the recorder's step in the iOS Simulator: all well '$rs_ok'; state-check red '$rs_state'; a trial failed '$rs_kill'"
fi
# A red soak prints its verdict's lines in the step's own output, the line that says how to
# replay the recovery over a copy of the kept store among them, and not only in its log (item
# 120). The step's function, from verify.sh, with a stand-in run whose soak is red.
sk="$scratch/soak-verdict"
mkdir -p "$sk"
soak_out="$(python3 -I - "$KNOT_SCRIPTS/verify.sh" <<'PY' | KNOT_LOGS="$sk" bash 2>&1 || true
import sys
text = open(sys.argv[1]).read()
start = text.index("step_soak() {")
body = text[start:text.index("\n}\n", start) + 3]
print('knot_swiftpm_flags() { KNOT_SWIFTPM_FLAGS=(); }')
print('knot_skipped_tests() { :; }')
print('''knot_swift_test_limited() {
    printf '%s\\n' "capture ledger soak: RED at kill 3" "the store is kept at /tmp/kept" \\
        "replay the recovery over a copy of the kept store with: knot-dev replay /tmp/kept" >"$KNOT_LOGS/verify-soak.out"
    return 1
}''')
print(body)
print("SEED=7 step_soak")
PY
)"
if [[ $soak_out == *"capture ledger soak: RED"* && $soak_out == *"replay the recovery over a copy of the kept store with:"* &&
    $soak_out == *"Repeat it with scripts/verify.sh --soak --seed 7"* ]]; then
    pass "a red soak prints its verdict's lines, the replay of the recovery among them"
else
    fail "a red soak's lines: '$soak_out'"
fi

# The gate's Mac UI step met by the hosted job (--mac-ui-hosted). With stand-ins for GitHub's
# answers: the check runs on a commit, the job, and the artifact the job kept. It passes only
# on the job mac-ui of GitHub Actions, completed with success on the very commit, with its
# log kept; it refuses every other answer, saying why, and refuses outright while the screen
# is not locked or when the diff changes the scripts or the workflow the job ran.
hm="$scratch/hosted-mac-ui"
mkdir -p "$hm"
hosted_cases="$(python3 -I -B - "$KNOT_SCRIPTS/lib" "$hm" <<'PY' 2>&1 || true
import contextlib, io, os, sys
sys.path.insert(0, sys.argv[1])
import knot_tool as k
folder = sys.argv[2]
SHA = "a" * 40
LOG = "Test Case '-[Knot_macOS_UITests.T testA]' passed (1.0 seconds).\n"

def run(name, status="completed", conclusion="success", sha=SHA, app="github-actions", id=7):
    return {"id": id, "name": name, "head_sha": sha, "status": status, "conclusion": conclusion,
            "app": {"slug": app}, "html_url": f"https://example.invalid/job/{id}", "completed_at": "2026-11-22T10:00:00Z"}

def case(label, runs, screen="locked", changed=(), kept=LOG, job_sha=SHA, ancestor=True):
    k.changed_files = lambda base: list(changed)
    k.is_ancestor = lambda base, sha: ancestor
    def gh_json(path):
        if "/check-runs" in path:
            name = path.split("check_name=")[1].split("&")[0]
            return {"check_runs": [r for r in runs if r["name"] == name]}
        return {"run_id": 99, "head_sha": job_sha}
    def download(run_id, name, dest):
        assert (run_id, name) == (99, "mac-ui-logs"), (run_id, name)
        if kept is not None:
            open(os.path.join(dest, "verify-mac-ui-tests.log"), "w").write(kept)
    k.gh_json, k.gh_download_artifact = gh_json, download
    log = os.path.join(folder, label + ".log")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        status = k.cmd_hosted_mac_ui(SHA, "origin/main", screen, log)
    text = open(log).read() if os.path.exists(log) else ""
    print(f"{label}: {status} {out.getvalue().strip()} | {text.splitlines()[0] if text else ''}")

case("pass", [run("mac-ui")])
case("none", [])
case("other-app", [run("mac-ui", app="someone-else")])
case("running", [run("mac-ui", status="in_progress", conclusion=None)])
case("failed", [run("mac-ui", conclusion="failure")])
case("cancelled", [run("mac-ui", conclusion="cancelled")])
case("skipped", [run("mac-ui", conclusion="skipped")])
case("scope-said-no", [run("mac-ui", conclusion="skipped"), run("mac-ui-scope", id=6)])
case("latest", [run("mac-ui", conclusion="success", id=7), run("mac-ui", conclusion="failure", id=8)])
case("no-log", [run("mac-ui")], kept=None)
case("job-elsewhere", [run("mac-ui")], job_sha="b" * 40)
case("unlocked", [run("mac-ui")], screen="unlocked")
case("unknown", [run("mac-ui")], screen="unknown")
case("scripts", [run("mac-ui")], changed=["scripts/verify.sh"])
case("workflow", [run("mac-ui")], changed=[".github/workflows/verify.yml"])
case("behind", [run("mac-ui")], ancestor=False)
case("ancestry-unknown", [run("mac-ui")], ancestor=None)
PY
)"
hosted_line() { printf '%s\n' "$hosted_cases" | grep -e "^$1: " || echo "$1: missing"; }
hosted_ok=1
expect_hosted() { # expect_hosted <case> <status> <words the line must hold>
    local line
    line="$(hosted_line "$1")"
    [[ $line == "$1: $2 "*"$3"* ]] || { hosted_ok=0; echo "  $line"; }
}
hosted_why="$(
    expect_hosted pass 0 "passed on $(printf 'a%.0s' {1..40})"
    [[ "$(hosted_line pass)" == *"| # The Mac UI tests' log of the hosted job mac-ui, not of this Mac: check run 7"* ]] || echo "  pass: no header"
    expect_hosted none 1 "no check run mac-ui"
    expect_hosted other-app 1 "no check run mac-ui"
    expect_hosted running 1 "still in_progress"
    expect_hosted failed 1 "ended failure"
    expect_hosted cancelled 1 "ended cancelled"
    expect_hosted skipped 1 "was skipped"
    expect_hosted scope-said-no 1 "the scope job mac-ui-scope said the diff does not reach"
    expect_hosted latest 1 "ended failure"
    expect_hosted no-log 1 "keeps no verify-mac-ui-tests.log"
    expect_hosted job-elsewhere 1 "not on"
    expect_hosted unlocked 1 "screen reads unlocked"
    expect_hosted unknown 1 "screen reads unknown"
    expect_hosted scripts 1 "the diff changes scripts/verify.sh"
    expect_hosted workflow 1 "the diff changes .github/workflows/verify.yml"
    expect_hosted behind 1 "origin/main is not an ancestor of"
    expect_hosted ancestry-unknown 1 "origin/main is not known to be an ancestor of"
    ((hosted_ok)) || true
)"
# The step reads the kept log as the local step reads its own: a log with no test, or with
# a failed or skipped case, fails even when the job's run says success. The step's function
# from verify.sh, with a stand-in tool that writes the kept log it is given.
hosted_step() { # hosted_step <kept log's lines>: the step's status and its last line
    printf '%s\n' "$1" >"$hm/kept"
    python3 -I - "$KNOT_SCRIPTS/verify.sh" "$KNOT_SCRIPTS/lib/common.sh" "$hm" "$KNOT_SELF" <<'PY' | bash 2>&1 | tail -n 1 || true
import sys
text = open(sys.argv[1]).read()
def function(name):
    start = text.index(name + "() {")
    return text[start:text.index("\n}\n", start) + 3]
print(f'source "{sys.argv[2]}"')
# The step reads the commit under test from a tree's head: this checkout's, whatever folder
# an earlier case left the self-test in.
print(f'KNOT_LOGS="{sys.argv[3]}" KNOT_ROOT="{sys.argv[4]}" BASE=origin/main TIER=gate')
print('tool() { local log=""; while (($#)); do [[ $1 == --log ]] && log=$2; shift; done; cp "' + sys.argv[3] + '/kept" "$log"; }')
print(function("report_skips"))
print('slow_cases() { :; }')
print(function("step_mac_ui_hosted"))
# In the background, as verify.sh runs a light step, so that set -e holds inside it.
print('step_mac_ui_hosted & code=0; wait $! || code=$?; echo "status $code"')
PY
}
step_pass="$(hosted_step "Test Case '-[Knot_macOS_UITests.T testA]' passed (1.0 seconds).")"
step_none="$(hosted_step "# a log with no test")"
step_failed="$(hosted_step "Test Case '-[Knot_macOS_UITests.T testA]' failed (1.0 seconds).")"
step_skipped="$(hosted_step "Test Case '-[Knot_macOS_UITests.T testA]' passed (1.0 seconds).
Test Case '-[Knot_macOS_UITests.T testB]' skipped (0.0 seconds).")"
# The option belongs to the gate alone.
full_hosted="$(env -u KNOT_TREE "$KNOT_SCRIPTS/verify.sh" --full --mac-ui-hosted 2>&1 || true)"
if [[ -z $hosted_why && $step_pass == "status 0" && $step_none == "status 1" && $step_failed == "status 1" &&
    $step_skipped == "status 1" && $full_hosted == *"FAIL verify-usage"*"--mac-ui-hosted belongs to --gate"* ]]; then
    pass "the gate takes the hosted job's Mac UI result only when it passed on the commit under test, kept its log, and that log holds passed tests and no skip"
else
    fail "the hosted Mac UI job: wrong answers$hosted_why; the step on a passing log '$step_pass', with no test '$step_none', a failed case '$step_failed', a skip '$step_skipped'; --full with the option '$full_hosted'"
fi

# A UI or hosted step prints one line for each case that took longer than a minute, with its
# name, its destination and its seconds: how an idle wait that ran out shows when the test
# goes on and passes. On a fixture log in each form the steps read: XCTest's with a
# destination, XCTest's without, and Swift Testing's; a fast case and the run's own line print
# nothing.
sc="$scratch/slow-cases"
mkdir -p "$sc"
cat >"$sc/log" <<'LOG'
Test case 'KnotIOSLaunchTests.testSlow()' passed on 'set-iphone - Knot-iOS-UITests-Runner (1)' (205.3 seconds)
Test case 'KnotIOSLaunchTests.testFast()' passed on 'set-ipad - Knot-iOS-UITests-Runner (2)' (16.9 seconds)
Test Case '-[Knot_macOS_UITests.MacTests testSlowOnTheMac]' failed (61.0 seconds).
✔ Test hostedSlowly() passed after 75.5 seconds.
✔ Test run with 3 tests in 0 suites passed after 300.0 seconds.
LOG
slow_out="$(python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" slow-cases --log "$sc/log" --over 60 --destination "this Mac" 2>&1 || true)"
slow_want="slow: KnotIOSLaunchTests.testSlow() on set-iphone took 205.3 s, passed
slow: Knot_macOS_UITests.MacTests testSlowOnTheMac on this Mac took 61.0 s, failed
slow: hostedSlowly() on this Mac took 75.5 s, passed"
if [[ $slow_out == "$slow_want" ]]; then
    pass "a step names each case that took longer than a minute, with its destination and its seconds, and no other"
else
    fail "the slow cases: '$slow_out'"
fi

# scripts/install.sh skips a device that holds the build's version and build number, and
# with --again installs there all the same, as a build signed again needs. With a saved device
# list of one synthetic paired iPhone, and a stand-in xcrun whose devicectl says that the
# device holds 0.3.0 (1) and writes down each install it is asked for.
ia="$scratch/install-again"
mkdir -p "$ia/stub" "$ia/Knot.app"
cat >"$ia/devices.json" <<'JSON'
{"result": {"devices": [{"identifier": "SELF-TEST-DEVICE", "deviceProperties": {"name": "Self-test iPhone"},
  "properties": {"hardware": {"platform": "iOS", "reality": "physical", "udid": "SELF-TEST-UDID"},
                 "connection": {"pairingState": "paired", "state": "connected"}}}]}}
JSON
for key in "CFBundleIdentifier string com.p3ob7o.knot.dev" "CFBundleShortVersionString string 0.3.0" "CFBundleVersion string 1"; do
    /usr/libexec/PlistBuddy -c "Add :$key" "$ia/Knot.app/Info.plist" >/dev/null
done
cat >"$ia/stub/xcrun" <<'SH'
#!/bin/bash
[[ $1 == devicectl ]] || exec /usr/bin/xcrun "$@"
out=""
for ((i = 1; i <= $#; i++)); do [[ ${!i} == --json-output ]] && { j=$((i + 1)); out=${!j}; }; done
case "$2 $3 $4" in
    "device info apps") printf '{"result": {"apps": [{"version": "0.3.0", "bundleVersion": "1"}]}}\n' >"$out" ;;
    "device install app") echo "install $*" >>"$KNOT_INSTALL_RECORD" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$ia/stub/xcrun"
install_run() { # install_run <name> <options…>: the lines it printed, and how many installs it made
    local name=$1
    shift
    env PATH="$ia/stub:$PATH" KNOT_DEVICECTL_JSON="$ia/devices.json" KNOT_INSTALL_RECORD="$ia/$name.record" \
        "$KNOT_SCRIPTS/install.sh" "$ia/Knot.app" "$@" >"$ia/$name.out" 2>&1 || echo "status $?" >>"$ia/$name.out"
    echo "$(grep -c . "$ia/$name.record" 2>/dev/null || echo 0) $(grep -e '^install: [0-9]' "$ia/$name.out")"
}
plain_install="$(install_run plain)"
again_install="$(install_run again --again)"
mac_again="$(mkdir -p "$ia/mac.app/Contents" && cp "$ia/Knot.app/Info.plist" "$ia/mac.app/Contents/" &&
    "$KNOT_SCRIPTS/install.sh" "$ia/mac.app" --mac-folder "$ia/folder" --again 2>&1 || true)"
if [[ $plain_install == "0 install: 0 installed, 1 already held the build, 0 missed" &&
    $again_install == "1 install: 1 installed, 0 already held the build, 0 missed" &&
    $(cat "$ia/again.record") == *"device install app --device SELF-TEST-DEVICE $ia/Knot.app"* &&
    $mac_again == *"--again is for devices"* && ! -e $ia/folder/mac.app ]]; then
    pass "install.sh skips a device that holds the build, and installs there again with --again"
else
    fail "install.sh and --again: without it '$plain_install', with it '$again_install' ($(cat "$ia/again.out")), a Mac build with it '$mac_again'"
fi

# scripts/nightly.sh keeps each of its runs' logs in a folder of its own, .build/nightly/<run>/,
# cleared when the night starts: a whole run sets the earlier runs' logs aside, so without the
# folders only the last two runs' logs were left. With a stand-in verify.sh that writes one log
# named for its arguments, and a scratch tree.
ng="$scratch/nightly-logs"
mkdir -p "$ng/tree/.build/nightly/from-an-earlier-night"
cp -R "$KNOT_SCRIPTS" "$ng/scripts"
cp "$KNOT_SELF/.xcode-version" "$ng/tree/"
cat >"$ng/scripts/verify.sh" <<'SH'
#!/bin/bash
[[ ${1:-} == --status-line ]] && { echo "stand-in status"; exit 0; }
# A run finds no slot when KNOT_NG_NO_SLOT names it, and fails when KNOT_NG_FAIL does.
[[ -n ${KNOT_NG_NO_SLOT:-} && " $* " == *" $KNOT_NG_NO_SLOT "* ]] && exit 4
[[ -n ${KNOT_NG_FAIL:-} && " $* " == *" $KNOT_NG_FAIL "* ]] && exit 1
source "$(dirname "$0")/lib/common.sh"
# A whole run sets the earlier logs aside, as verify.sh does; a run of one step does not.
[[ ${1:-} == --only ]] || knot_set_logs_aside "$KNOT_LOGS"
mkdir -p "$KNOT_LOGS"
echo "a log of verify.sh $*" >"$KNOT_LOGS/verify-$(printf '%s' "$*" | tr -c 'a-z0-9' '-').log"
SH
chmod +x "$ng/scripts/verify.sh"
ng_status=0
(cd "$ng/tree" && git init -q && env KNOT_TREE="$ng/tree" "$ng/scripts/nightly.sh" >"$ng/out" 2>&1) || ng_status=$?
ng_folders="$( { cd "$ng/tree/.build/nightly" && ls; } 2>/dev/null | tr '\n' ' ' || true)"
ng_full="$( { cat "$ng/tree/.build/nightly/full/"verify-* || true; } 2>/dev/null | tr '\n' ' ')"
ng_tsan="$( { ls "$ng/tree/.build/nightly/tsan/" || true; } 2>/dev/null | tr '\n' ' ')"
if [[ $ng_status == 0 && $ng_folders == "full models oldest-runtime perf recorder-sim soak tsan " &&
    $ng_full == "a log of verify.sh --full " && $ng_tsan == "verify---only-tsan.log " ]]; then
    pass "the nightly run keeps each run's logs in a folder of its own, and clears an earlier night's"
else
    fail "the nightly's logs: status $ng_status, folders '$ng_folders', full's '$ng_full', tsan's '$ng_tsan': $(tail -n 3 "$ng/out")"
fi

# A night that did not run every run gives no verdict: status 4, neither green nor red, its last
# line naming what did not run, whether perf or the full run found no slot; a run that failed
# makes it red, status 1, whatever else did not run.
ng_night() { # ng_night <name> <environment…>: the night's status and its last line
    local name=$1 status=0
    shift
    (cd "$ng/tree" && env KNOT_TREE="$ng/tree" "$@" "$ng/scripts/nightly.sh" >"$ng/$name.out" 2>&1) || status=$?
    echo "$status|$(grep -v -e '^ ' -e '^FAIL' "$ng/$name.out" | tail -n 1)"
}
ng_perf="$(ng_night no-slot-perf KNOT_NG_NO_SLOT=--perf)"
ng_full="$(ng_night no-slot-full KNOT_NG_NO_SLOT=--full)"
ng_red="$(ng_night red KNOT_NG_NO_SLOT=--perf KNOT_NG_FAIL=--soak)"
if [[ $ng_perf == "4|nightly: no verdict: no run failed, and these did not run, for want of a build slot: perf" &&
    $ng_full == "4|nightly: no verdict: no run failed, and these did not run, for want of a build slot: full" &&
    ${ng_red%%|*} == 1 ]] && grep -e 'failed in: soak. Not run, for want of a build slot: perf.' "$ng/red.out" >/dev/null; then
    pass "a night that did not run every run gives no verdict, status 4, naming what did not run; a failed run makes it red"
else
    fail "the nightly's verdicts: perf with no slot '$ng_perf', full with no slot '$ng_full', a failure beside '$ng_red'"
fi

# scripts/milestone-build.sh, with stand-ins for what it calls: an xcodebuild that writes
# down its arguments and makes a synthetic product, a codesign that fails on a part named in
# KNOT_MB_UNSIGNED, a defaults that holds KNOT_MB_ACCOUNTS saved accounts, and an install.sh
# that writes down what it was asked, and an XcodeGen that generates nothing. A scratch git
# tree holds the identifiers and a stand-in for the team's configuration, which a run keeps
# (the first real run found that generating the project removed it). A part that fails its check
# stops the run before any install; a derived-data folder that is not empty, a HEAD that is
# not the commit named, a dirty tree and an empty list of accounts are refused before any
# build; and no provisioning flag reaches the build unless asked, the device one never.
# The app group: the stand-in xcodebuild writes down beside each part the groups it is
# signed with, which the stand-in codesign -d reads, and a profile that allows them, which a
# stand-in security decodes; the Mac's group carries a made-up team prefix. A part signed with
# a group its profile does not allow, and a part signed with none that its entitlements file
# gives one, stop the run before any install, naming the part; no printed line holds the
# made-up team ID. Each build's log lies beside its derived data, where a later verify run's
# set-aside does not reach it. And an install that fails comes after the summary, names the
# command that installs the build again, and the next product is still installed.
mb="$scratch/milestone-build"
mkdir -p "$mb/tree/Apps/Config" "$mb/stub" "$mb/slots"
cp "$KNOT_SELF/Apps/Config/Identifiers.xcconfig" "$mb/tree/Apps/Config/"
mb_entitlements=(Apps/iOS/Knot-iOS-team.entitlements Apps/macOS/Knot-macOS-team.entitlements
    Apps/watchOS/Knot-watchOS-team.entitlements Apps/macOS/Tool/knot-team.entitlements
    Apps/Extensions/Widgets-iOS/Widgets-iOS-team.entitlements Apps/Extensions/Widgets-watchOS/Widgets-watchOS-team.entitlements)
for f in "${mb_entitlements[@]}"; do mkdir -p "$mb/tree/$(dirname "$f")" && cp "$KNOT_SELF/$f" "$mb/tree/$f"; done
mb_team="ZZ9QX42K7T"
cp "$KNOT_SELF/.xcode-version" "$mb/tree/"
printf '.build/\nbuild/\n*.xcodeproj/\n' >"$mb/tree/.gitignore"
mb_git() { git -C "$mb/tree" -c user.name=self-test -c user.email=self-test@example.invalid -c commit.gpgsign=false "$@"; }
mb_record() { # mb_record <message>: records the tree's staged files as a commit
    mb_git commit -q -m "$1"
}
# A package's checkout, a small git repository, and the pin of its revision in Package.resolved.
mb_pkg="$mb/tree/.build/SourcePackages/checkouts/Synthetic"
mkdir -p "$mb_pkg"
mb_pkg_git() { git -C "$mb_pkg" -c user.name=self-test -c user.email=self-test@example.invalid -c commit.gpgsign=false "$@"; }
mb_pkg_git init -q
printf 'one\n' >"$mb_pkg/Source.swift"
mb_pkg_git add Source.swift
mb_pkg_git commit -q -m "the pinned revision"
mkdir -p "$mb/tree/Packages/KnotKit"
printf '{"pins": [{"identity": "synthetic", "kind": "remoteSourceControl", "location": "https://example.invalid/Synthetic.git", "state": {"revision": "%s", "version": "1.0.0"}}], "version": 3}\n' \
    "$(mb_pkg_git rev-parse HEAD)" >"$mb/tree/Packages/KnotKit/Package.resolved"
mb_git init -q
mb_git add .gitignore .xcode-version Apps/Config/Identifiers.xcconfig "${mb_entitlements[@]}" Packages/KnotKit/Package.resolved
mb_record "the milestone's commit"
mb_commit="$(mb_git rev-parse HEAD)"
mkdir -p "$mb/tree/.build/config"
printf '// a stand-in: no team\n' >"$mb/tree/.build/config/Local.xcconfig"
cp -R "$KNOT_SCRIPTS" "$mb/scripts"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "Version: %s"\nexit 0\n' "$KNOT_XCODEGEN_VERSION" >"$mb/stub/xcodegen"
cat >"$mb/scripts/install.sh" <<'SH'
#!/bin/bash
echo "install $*" >>"$KNOT_MB_RECORD"
[[ -n ${KNOT_MB_INSTALL_FAIL:-} && $1 == *"-$KNOT_MB_INSTALL_FAIL/"* ]] && { echo "install: could not reach a locked device"; exit 1; }
exit 0
SH
chmod +x "$mb/scripts/install.sh"
printf '#!/bin/bash\necho "lsregister $*" >>"$KNOT_MB_RECORD"\n' >"$mb/stub/lsregister"
chmod +x "$mb/stub/lsregister"
cat >"$mb/stub/security" <<'SH'
#!/bin/bash
[[ "$1 $2 $3" == "cms -D -i" ]] || exec /usr/bin/security "$@"
cat "$4"
SH
cat >"$mb/stub/defaults" <<'SH'
#!/bin/bash
[[ "$1 $2" == "export com.apple.dt.Xcode" ]] || exec /usr/bin/defaults "$@"
entries=""
for ((i = 0; i < ${KNOT_MB_ACCOUNTS:-1}; i++)); do entries="$entries<dict><key>identifier</key><string>synthetic-$i</string></dict>"; done
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>DVTDeveloperAccountManagerAppleIDLists</key><dict><key>IDE.Identifiers.Prod</key><array>%s</array></dict></dict></plist>\n' "$entries"
SH
cat >"$mb/stub/codesign" <<'SH'
#!/bin/bash
part="${@: -1}"
echo "codesign $*" >>"$KNOT_MB_RECORD"
if [[ $1 == -dv ]]; then
    # Who signed it: the made-up team, or no team where KNOT_MB_ADHOC names the part.
    team="$KNOT_MB_TEAM"
    [[ -n ${KNOT_MB_ADHOC:-} && $part == *"$KNOT_MB_ADHOC" ]] && team="not set"
    printf 'Executable=%s\nTeamIdentifier=%s\n' "$part" "$team" >&2
    exit 0
fi
if [[ $1 == -d ]]; then
    groups=""
    [[ -n ${KNOT_MB_NO_GROUP:-} && $part == *"$KNOT_MB_NO_GROUP" ]] || groups="$(cat "$part.groups-signed")"
    printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.application-groups</key><array>%s</array></dict></plist>\n' "$groups"
    exit 0
fi
if [[ -n ${KNOT_MB_UNSIGNED:-} && $part == *"$KNOT_MB_UNSIGNED" ]]; then
    echo "$part: code object is not signed at all" >&2
    exit 1
fi
SH
cat >"$mb/stub/xcodebuild" <<'SH'
#!/bin/bash
[[ ${1:-} == -version ]] && exec /usr/bin/xcodebuild "$@"
echo "xcodebuild $*" >>"$KNOT_MB_RECORD"
derived="" scheme="" level="" archive="" number=1
for ((i = 1; i <= $#; i++)); do
    j=$((i + 1))
    case ${!i} in
        -derivedDataPath) derived=${!j} ;;
        -scheme) scheme=${!j} ;;
        KNOT_MILESTONE_LEVEL=*) level=${!i#KNOT_MILESTONE_LEVEL=} ;;
        -archivePath) archive=${!j} ;;
        KNOT_BUILD_NUMBER=*) number=${!i#KNOT_BUILD_NUMBER=} ;;
    esac
done
info() { # info <folder> <bundle ID>: a wrong build number or level where asked
    local build=$number at=$level
    [[ -n ${KNOT_MB_WRONG_BUILD:-} && $1 == *"$KNOT_MB_WRONG_BUILD" ]] && build=2
    [[ -n ${KNOT_MB_WRONG_LEVEL:-} && $1 == *"$KNOT_MB_WRONG_LEVEL" ]] && at=M2
    mkdir -p "$1"
    printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleShortVersionString</key><string>0.3.0</string><key>CFBundleVersion</key><string>%s</string><key>CFBundleExecutable</key><string>Knot</string><key>KnotFlavour</key><string>milestone</string><key>KnotMilestoneLevel</key><string>%s</string></dict></plist>\n' "$2" "$build" "$at" >"$1/Info.plist"
}
binary() { # binary <path>: a Mach-O file, which holds the fakes' module or a debug argument when asked
    local kind=plain
    [[ -n ${KNOT_MB_FAKES:-} && $1 == *"$KNOT_MB_FAKES" ]] && kind=fakes
    [[ -n ${KNOT_MB_DEBUG_ARGUMENT:-} && $1 == *"$KNOT_MB_DEBUG_ARGUMENT" ]] && kind=debug
    cp "$KNOT_MB_BINARIES/$kind" "$1"
}
signed() { # signed <part> <group> [<profile>]: the group it is signed with, and a profile that allows it
    printf '<string>%s</string>' "$2" >"$1.groups-signed"
    local allowed=$2
    [[ -n ${KNOT_MB_PROFILE_OTHER:-} && $1 == *"$KNOT_MB_PROFILE_OTHER" ]] && allowed="$KNOT_MB_TEAM.com.example.other"
    [[ -n ${KNOT_MB_NO_PROFILE:-} && $1 == *"$KNOT_MB_NO_PROFILE" ]] && return 0
    [[ -z ${3:-} ]] || printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Entitlements</key><dict><key>com.apple.security.application-groups</key><array><string>%s</string></array></dict></dict></plist>\n' "$allowed" >"$3"
}
if [[ -n $archive && -n ${KNOT_MB_ARCHIVE_FAIL:-} ]]; then
    echo "error: synthetic: the archive could not be made"
    echo "** ARCHIVE FAILED **"
    exit 65
fi
if [[ $scheme == Knot-iOS ]]; then
    app="$derived/Build/Products/Release-iphoneos/Knot.app"
    [[ -z $archive ]] || app="$archive/Products/Applications/Knot.app"
    info "$app" com.p3ob7o.knot
    info "$app/PlugIns/Widgets-iOS.appex" com.p3ob7o.knot.widgets
    info "$app/Watch/KnotWatch.app" com.p3ob7o.knot.watchkitapp
    info "$app/Watch/KnotWatch.app/PlugIns/Widgets-watchOS.appex" com.p3ob7o.knot.watchkitapp.widgets
    for part in "$app" "$app/PlugIns/Widgets-iOS.appex" "$app/Watch/KnotWatch.app" "$app/Watch/KnotWatch.app/PlugIns/Widgets-watchOS.appex"; do
        signed "$part" group.com.p3ob7o.knot "$part/embedded.mobileprovision"
        binary "$part/Knot"
    done
    mkdir -p "$app/Frameworks/Synthetic.framework"
    binary "$app/Frameworks/Synthetic.framework/Synthetic"
else
    app="$derived/Build/Products/Release/Knot.app"
    [[ -z $archive ]] || app="$archive/Products/Applications/Knot.app"
    info "$app/Contents" com.p3ob7o.knot
    mkdir -p "$app/Contents/MacOS"
    binary "$app/Contents/MacOS/Knot"
    binary "$app/Contents/MacOS/knot-cli"
    signed "$app" "$KNOT_MB_TEAM.com.p3ob7o.knot" "$app/Contents/embedded.provisionprofile"
    signed "$app/Contents/MacOS/knot-cli" "${KNOT_MB_TOOL_GROUP:-$KNOT_MB_TEAM.com.p3ob7o.knot}"
fi
# The three forms in which xcodebuild writes the signing identity, made up: its SHA-1, the
# certificate's name, and the name in an exported setting, with its parentheses escaped.
echo "    /usr/bin/codesign --force --sign 0123456789ABCDEF0123456789ABCDEF01234567 --timestamp=none $app"
echo '    Signing Identity:     "Apple Development: Self Test Owner (QQ1WW2EE3R)"'
echo '    export EXPANDED_CODE_SIGN_IDENTITY_NAME\=Apple\ Development:\ Self\ Test\ Owner\ \(QQ1WW2EE3R\)'
echo '    export EXPANDED_CODE_SIGN_IDENTITY\=0123456789ABCDEF0123456789ABCDEF01234567'
echo "    builtin-embeddedBinaryValidationUtility $app -signing-cert 0123456789ABCDEF0123456789ABCDEF01234567 -info-plist-path x"
# A commit's hash, which no flag or key names, stays readable.
echo "    a commit 0123456789abcdef0123456789abcdef01234567 of the tree"
echo "** BUILD SUCCEEDED **"
SH
chmod +x "$mb/stub/defaults" "$mb/stub/codesign" "$mb/stub/xcodebuild" "$mb/stub/xcodegen" "$mb/stub/security"
# Three small Mach-O files for the binary scan, which reads a file's sections: one plain, one
# that names the fakes' module, and one that holds a debug launch argument.
mkdir -p "$mb/bin"
for kind in "plain " "fakes KnotFakes" "debug -KnotPreview"; do
    printf 'int main(void) { return 0; }\n__attribute__((used)) static const char marker[] = "%s";\n' "${kind#* }" >"$mb/bin/${kind%% *}.c"
    xcrun clang -o "$mb/bin/${kind%% *}" "$mb/bin/${kind%% *}.c" 2>>"$mb/bin/clang.log" || echo "the binary ${kind%% *} was not made" >>"$mb/bin/clang.log"
done
mb_run() { # mb_run <name> <arguments…>: runs it with a fresh record and no derived data; prints its status
    local name=$1 status=0
    shift
    rm -rf "$mb/tree/.build/milestone"
    : >"$mb/$name.record"
    env -u KNOT_LOCAL_CONFIG PATH="$mb/stub:$PATH" KNOT_XCODEGEN="$mb/stub/xcodegen" KNOT_TREE="$mb/tree" \
        KNOT_SLOT_DIR="$mb/slots" KNOT_MB_RECORD="$mb/$name.record" KNOT_MB_TEAM="$mb_team" KNOT_MB_BINARIES="$mb/bin" \
        KNOT_LSREGISTER="${KNOT_MB_LSREGISTER:-$mb/stub/lsregister}" \
        "$mb/scripts/milestone-build.sh" "$@" >"$mb/$name.out" 2>&1 || status=$?
    echo "$status"
}
mb_builds() { grep -c -e '^xcodebuild .* build$' "$mb/$1.record" || true; }
mb_installs() { grep -c -e '^install ' "$mb/$1.record" || true; }
# A clean run of both products, with the install, and no provisioning flag. It keeps the
# team's configuration, and removes the generated project, with a user scheme left in it, before
# it generates it again.
mkdir -p "$mb/tree/Knot.xcodeproj/xcuserdata/self-test.xcuserdatad/xcschemes"
printf 'a scheme left behind\n' >"$mb/tree/Knot.xcodeproj/xcuserdata/self-test.xcuserdatad/xcschemes/Left.xcscheme"
mb_plain="$(mb_run plain M1 --commit "$mb_commit" --install --mac-folder "$mb/folder")"
mb_kept="$( [[ -e $mb/tree/.build/config/Local.xcconfig ]] && echo kept || echo removed)"
mb_project="$( [[ -e $mb/tree/Knot.xcodeproj ]] && echo left || echo removed)"
# The Mac product leaves LaunchServices once its checks have run, and stays on disk.
mb_unregistered="$(grep -c -e "^lsregister -u .*/M1-${mb_commit:0:12}-mac/Build/Products/Release/Knot.app$" "$mb/plain.record" || true)/$( [[ -d $mb/tree/.build/milestone/M1-${mb_commit:0:12}-mac/Build/Products/Release/Knot.app ]] && echo kept || echo gone)"
# The app-group check's lines go into the build's log as well as to the terminal.
mb_group_log="$( { grep -c -e 'milestone-build: ios: Knot.app: app group group.com.p3ob7o.knot, allowed by its profile' -e 'milestone-build: ios: the app group checked on 4 parts' \
    "$mb/tree/.build/milestone/milestone-build-M1-${mb_commit:0:12}-ios.log" || true; } )"
# Its logs lie beside the derived data, and a verify run's set-aside of .build/logs/ leaves them.
mb_log="$mb/tree/.build/milestone/milestone-build-M1-${mb_commit:0:12}-ios.log"
mkdir -p "$mb/tree/.build/logs"
(KNOT_TREE="$mb/tree" bash -c 'source "$1/lib/common.sh"; knot_set_logs_aside "$KNOT_LOGS"' _ "$mb/scripts")
mb_logs="$( [[ -f $mb_log && -f ${mb_log%-ios.log}-mac.log && ! -e $mb/tree/.build/logs-earlier/$(basename "$mb_log") ]] && echo beside || echo moved)"
# The signing identity leaves the build's log: its SHA-1 after --sign, after -signing-cert and as
# EXPANDED_CODE_SIGN_IDENTITY, the certificate's name and its ID; a commit's hash stays.
mb_identity="$( { grep -h -e '0123456789ABCDEF0123456789ABCDEF01234567' -e 'Self Test Owner' -e 'QQ1WW2EE3R' "$mb_log" ${mb_log%-ios.log}-mac.log || true; } | grep -c . || true)/$(grep -c -e '<IDENTITY>' -e '<NAME>' "$mb_log" || true)/$(grep -c -e 'a commit 0123456789abcdef0123456789abcdef01234567 of the tree' "$mb_log" || true)"
# The app group: a profile that does not allow the iOS widget's group, and a Watch app signed
# with no group, which its entitlements file gives one.
mb_profile="$(KNOT_MB_PROFILE_OTHER=Widgets-iOS.appex mb_run profile M1 --commit "$mb_commit" --install --mac-folder "$mb/folder")"
# The detail it writes to the build's log passes the team filter: the group the profile allows
# carries the made-up team prefix.
mb_profile_log="$( { grep -h -e 'app group Knot.app/PlugIns/Widgets-iOS.appex' "$mb/tree/.build/milestone/"*.log || true; } | tr '\n' ' ')"
mb_nogroup="$(KNOT_MB_NO_GROUP=Watch/KnotWatch.app mb_run nogroup M1 --commit "$mb_commit" --install --mac-folder "$mb/folder")"
mb_group_log="$mb_group_log/$( { grep -c -e 'is signed with no app group' "$mb/tree/.build/milestone/"*-ios.log || true; } )"
# Who signed each part: an ad hoc widget, and a Mac tool with another app group than the app's.
mb_adhoc="$(KNOT_MB_ADHOC=Widgets-iOS.appex mb_run adhoc M1 --commit "$mb_commit" --install --mac-folder "$mb/folder")"
mb_tool_group="$(KNOT_MB_TOOL_GROUP=group.com.example.other mb_run tool-group M1 --commit "$mb_commit" --products mac --install --mac-folder "$mb/folder")"
# An unregister that fails, and LaunchServices' tool missing: said as such, never claimed.
printf '#!/bin/bash\necho "lsregister $*" >>"$KNOT_MB_RECORD"\nexit 1\n' >"$mb/stub/lsregister-fails"
chmod +x "$mb/stub/lsregister-fails"
mb_unregister_fails="$(KNOT_MB_LSREGISTER="$mb/stub/lsregister-fails" mb_run unregister-fails M1 --commit "$mb_commit" --products mac)"
mb_unregister_missing="$(KNOT_MB_LSREGISTER="$mb/stub/no-such-tool" mb_run unregister-missing M1 --commit "$mb_commit" --products mac)"
# A part signed with a group that holds no profile.
mb_noprofile="$(KNOT_MB_NO_PROFILE=Widgets-iOS.appex mb_run noprofile M1 --commit "$mb_commit" --install --mac-folder "$mb/folder")"
mb_group_log="$mb_group_log/$( { grep -c -e 'Widgets-iOS.appex is signed with an app group and holds no provisioning profile' "$mb/tree/.build/milestone/"*-ios.log || true; } )"
# What the build reads beyond the commit: an ignored Swift file under Sources, an untracked
# file, a key beyond its own in each of the two configurations the build includes, and a binary
# that holds the fakes' module or a debug launch argument.
mkdir -p "$mb/tree/Packages/KnotKit/Sources/KnotCore/build"
printf '#error("hidden")\n' >"$mb/tree/Packages/KnotKit/Sources/KnotCore/build/Hidden.swift"
mb_ignored="$(mb_run ignored M1 --commit "$mb_commit")"
rm -r "$mb/tree/Packages/KnotKit/Sources"
printf 'untracked\n' >"$mb/tree/Apps/Untracked.swift"
mb_untracked="$(mb_run untracked M1 --commit "$mb_commit")"
rm "$mb/tree/Apps/Untracked.swift"
printf 'KNOT_WORKTREE = x\nSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG KNOT_FAKES\n' >"$mb/tree/.build/config/Worktree.xcconfig"
mb_worktree_config="$(mb_run worktree-config M1 --commit "$mb_commit")"
rm "$mb/tree/.build/config/Worktree.xcconfig"
cp "$mb/tree/.build/config/Local.xcconfig" "$mb/local.copy"
printf '#include "elsewhere.xcconfig"\nOTHER_SWIFT_FLAGS = -DDEBUG\n' >>"$mb/tree/.build/config/Local.xcconfig"
mb_local_config="$(mb_run local-config M1 --commit "$mb_commit")"
cp "$mb/local.copy" "$mb/tree/.build/config/Local.xcconfig"
# A line the key reader cannot parse, holding a value like the team's ID: named by its file and
# its number, and never printed.
printf 'DEVELOPMENT_TEAM %s_NO_EQUALS\n' "$mb_team" >>"$mb/tree/.build/config/Local.xcconfig"
mb_unparsed_config="$(mb_run unparsed-config M1 --commit "$mb_commit")"
cp "$mb/local.copy" "$mb/tree/.build/config/Local.xcconfig"
mb_fakes="$(KNOT_MB_FAKES=Widgets-iOS.appex/Knot mb_run fakes M1 --commit "$mb_commit" --install --mac-folder "$mb/folder")"
mb_debug="$(KNOT_MB_DEBUG_ARGUMENT=MacOS/knot-cli mb_run debug M1 --commit "$mb_commit" --products mac --install --mac-folder "$mb/folder")"
# A product that is not the build asked for: the app at another level, the app or an inner
# part with another build number.
mb_level="$(KNOT_MB_WRONG_LEVEL=Release-iphoneos/Knot.app mb_run level M1 --commit "$mb_commit" --products ios)"
mb_app_build="$(KNOT_MB_WRONG_BUILD=Release-iphoneos/Knot.app mb_run app-build M1 --commit "$mb_commit" --products ios)"
mb_inner_build="$(KNOT_MB_WRONG_BUILD=Widgets-iOS.appex mb_run inner-build M1 --commit "$mb_commit" --products ios)"
# A log that an earlier build left, with no derived data beside it.
rm -rf "$mb/tree/.build/milestone"
mkdir -p "$mb/tree/.build/milestone"
echo "an earlier build's log" >"$mb/tree/.build/milestone/milestone-build-M1-${mb_commit:0:12}-ios.log"
mb_earlier_log=0
: >"$mb/earlier-log.record"
env -u KNOT_LOCAL_CONFIG PATH="$mb/stub:$PATH" KNOT_XCODEGEN="$mb/stub/xcodegen" KNOT_TREE="$mb/tree" \
    KNOT_SLOT_DIR="$mb/slots" KNOT_MB_RECORD="$mb/earlier-log.record" KNOT_MB_TEAM="$mb_team" KNOT_MB_BINARIES="$mb/bin" \
    KNOT_LSREGISTER="$mb/stub/lsregister" \
    "$mb/scripts/milestone-build.sh" M1 --commit "$mb_commit" >"$mb/earlier-log.out" 2>&1 || mb_earlier_log=$?
# A package's checkout that was changed, and one at another revision than its pin.
printf 'an edit\n' >>"$mb_pkg/Source.swift"
mb_pkg_edited="$(mb_run pkg-edited M1 --commit "$mb_commit")"
mb_pkg_git checkout -q -- Source.swift
printf 'two\n' >"$mb_pkg/Other.swift"
mb_pkg_git add Other.swift
mb_pkg_git commit -q -m "a later revision"
mb_pkg_moved="$(mb_run pkg-moved M1 --commit "$mb_commit")"
mb_pkg_git reset -q --hard HEAD~1
# An ignored Swift file in the checkout, under a folder the package's own ignore list names.
printf 'build/\n' >>"$mb_pkg/.git/info/exclude"
mkdir -p "$mb_pkg/build"
printf '#error("hidden")\n' >"$mb_pkg/build/Hidden.swift"
mb_pkg_ignored="$(mb_run pkg-ignored M1 --commit "$mb_commit")"
rm -r "$mb_pkg/build"
# A build that waits for its slot: both slots a build outside the gate may take are held for
# 3 s, so the wait is said apart and the build's own time stays short.
/usr/bin/lockf -k "$mb/slots/build-1.lock" sleep 3 &
mb_hold_1=$!
/usr/bin/lockf -k "$mb/slots/build-2.lock" sleep 3 &
mb_hold_2=$!
for _ in $(seq 1 50); do
    /usr/bin/lockf -s -t 0 -k "$mb/slots/build-1.lock" true 2>/dev/null || /usr/bin/lockf -s -t 0 -k "$mb/slots/build-2.lock" true 2>/dev/null || break
    sleep 0.1
done
mb_wait="$(mb_run wait M1 --commit "$mb_commit" --products ios)"
wait "$mb_hold_1" "$mb_hold_2" 2>/dev/null || true
mb_wait_line="$(grep -e '^milestone-build: ios: built in ' "$mb/wait.out" || true)"
# An install that fails: the iPhone app's.
mb_install="$(KNOT_MB_INSTALL_FAIL=ios mb_run install M1 --commit "$mb_commit" --install --device "Self-test iPhone" --mac-folder "$mb/folder")"
mb_order="$( { grep -n -e 'summary, M1' -e ': scripts/install.sh$' "$mb/install.out" || true; } | cut -d: -f1 | tr '\n' ' ')"
# The Mac app's install fails, with the folder named relative to where the script was started:
# the command names the absolute folder, and says to move a part of a copy away first.
mb_mac_install="$(cd "$mb" && KNOT_MB_INSTALL_FAIL=mac mb_run mac-install M1 --commit "$mb_commit" --products mac --install --mac-folder folder)"
# The same, with the provisioning updates the owner allowed.
mb_allowed="$(mb_run allowed M1 --commit "$mb_commit" --allow-provisioning-updates --products ios)"
# An option for the device's registration does not exist.
mb_device="$(mb_run device M1 --commit "$mb_commit" --allow-provisioning-device-registration)"
# The iOS widget unsigned: the run stops at it, and installs nothing.
mb_unsigned="$(KNOT_MB_UNSIGNED=Widgets-iOS.appex mb_run unsigned M1 --commit "$mb_commit" --install --mac-folder "$mb/folder")"
# Derived data that is not empty.
mb_dd_status=0
: >"$mb/derived.record"
mkdir -p "$mb/tree/.build/milestone/M1-${mb_commit:0:12}-ios"
echo earlier >"$mb/tree/.build/milestone/M1-${mb_commit:0:12}-ios/earlier"
env -u KNOT_LOCAL_CONFIG PATH="$mb/stub:$PATH" KNOT_XCODEGEN="$mb/stub/xcodegen" KNOT_TREE="$mb/tree" \
    KNOT_SLOT_DIR="$mb/slots" KNOT_MB_RECORD="$mb/derived.record" KNOT_MB_TEAM="$mb_team" KNOT_MB_BINARIES="$mb/bin" \
    KNOT_LSREGISTER="$mb/stub/lsregister" \
    "$mb/scripts/milestone-build.sh" M1 --commit "$mb_commit" >"$mb/derived.out" 2>&1 || mb_dd_status=$?
# HEAD is not the commit named: a later commit is checked out.
printf 'later\n' >"$mb/tree/later.txt"
mb_git add later.txt
mb_record "a later one"
mb_head="$(mb_run head M1 --commit "$mb_commit")"
# A dirty tree, at the commit named.
printf 'changed\n' >>"$mb/tree/later.txt"
mb_dirty="$(mb_run dirty M1 --commit "$(mb_git rev-parse HEAD)")"
printf 'later\n' >"$mb/tree/later.txt"
# No saved account.
mb_none="$(KNOT_MB_ACCOUNTS=0 mb_run none M1 --commit "$(mb_git rev-parse HEAD)")"
mb_verdicts="wait $mb_wait unregister $mb_unregister_fails $mb_unregister_missing project $mb_project packages $mb_pkg_edited/$(mb_builds pkg-edited) $mb_pkg_moved/$(mb_builds pkg-moved) $mb_pkg_ignored/$(mb_builds pkg-ignored) unregistered $mb_unregistered/$(grep -c -e '^lsregister -u .*-mac/Build/Products/Release/Knot.app$' "$mb/tool-group.record" || true) signers $mb_adhoc/$(mb_installs adhoc) $mb_tool_group/$(mb_installs tool-group) group-log $mb_group_log noprofile $mb_noprofile/$(mb_installs noprofile) product $mb_level/$mb_app_build/$mb_inner_build/$mb_earlier_log/$(mb_builds earlier-log) read $mb_ignored/$(mb_builds ignored) $mb_untracked/$(mb_builds untracked) $mb_worktree_config/$(mb_builds worktree-config) $mb_local_config/$(mb_builds local-config) $mb_unparsed_config/$(mb_builds unparsed-config) $mb_fakes/$(mb_installs fakes) $mb_debug/$(mb_installs debug) logs $mb_logs identity $mb_identity profile $mb_profile/$(mb_installs profile) nogroup $mb_nogroup/$(mb_installs nogroup) install $mb_install/$(mb_installs install) plain $mb_plain/$mb_kept/$(mb_builds plain)/$(mb_installs plain) allowed $mb_allowed/$(mb_builds allowed) device $mb_device/$(mb_builds device) unsigned $mb_unsigned/$(mb_builds unsigned)/$(mb_installs unsigned) derived $mb_dd_status/$(mb_builds derived) head $mb_head/$(mb_builds head) dirty $mb_dirty/$(mb_builds dirty) none $mb_none/$(mb_builds none)"
if [[ $mb_verdicts == "wait 0 unregister 0 0 project removed packages 1/0 1/0 1/0 unregistered 1/kept/1 signers 1/0 1/0 group-log 2/1/1 noprofile 1/0 product 1/1/1/1/0 read 1/0 1/0 1/0 1/0 1/0 1/0 1/0 logs beside identity 0/5/1 profile 1/0 nogroup 1/0 install 1/2 plain 0/kept/2/2 allowed 0/1 device 1/0 unsigned 1/1/0 derived 1/0 head 1/0 dirty 1/0 none 1/0" ]] &&
    ! grep -e '-allowProvisioning' "$mb/plain.record" >/dev/null &&
    grep -e '^xcodebuild .*-allowProvisioningUpdates' "$mb/allowed.record" >/dev/null &&
    ! grep -e '-allowProvisioningDeviceRegistration' "$mb/plain.record" "$mb/allowed.record" >/dev/null &&
    grep -e "^install .*/M1-${mb_commit:0:12}-mac/Build/Products/Release/Knot.app --mac-folder $mb/folder$" "$mb/plain.record" >/dev/null &&
    grep -e 'codesign --verify --strict .*Knot.app/Contents/MacOS/knot-cli$' "$mb/plain.record" >/dev/null &&
    ! grep -e 'codesign .*--deep' "$mb/plain.record" >/dev/null &&
    grep -e 'failed on Knot.app/PlugIns/Widgets-iOS.appex' "$mb/unsigned.out" >/dev/null &&
    grep -e 'not the commit named' "$mb/head.out" >/dev/null && grep -e "(tree " "$mb/head.out" >/dev/null &&
    grep -e 'holds an earlier build' "$mb/derived.out" >/dev/null && grep -e 'uncommitted changes' "$mb/dirty.out" >/dev/null &&
    grep -e 'saved list of accounts is empty' "$mb/none.out" >/dev/null &&
    grep -e 'Xcode holds 1 saved account$' "$mb/plain.out" >/dev/null &&
    grep -e 'Knot.app/PlugIns/Widgets-iOS.appex is signed with the app group group.com.p3ob7o.knot, which its provisioning profile does not allow' "$mb/profile.out" >/dev/null &&
    grep -e 'Watch/KnotWatch.app is signed with no app group, and Apps/watchOS/Knot-watchOS-team.entitlements gives it one' "$mb/nogroup.out" >/dev/null &&
    grep -e 'mac: Knot.app: app group <TEAM>.com.p3ob7o.knot, allowed by its profile' "$mb/plain.out" >/dev/null &&
    grep -e 'mac: Knot.app/Contents/MacOS/knot-cli: signed with <TEAM>.com.p3ob7o.knot; a bare executable carries no profile' "$mb/plain.out" >/dev/null &&
    grep -e 'ios: the app group checked on 4 parts' "$mb/plain.out" >/dev/null &&
    ! grep -e "$mb_team" "$mb"/*.out >/dev/null &&
    grep -e "its log .build/milestone/milestone-build-M1-${mb_commit:0:12}-ios.log" "$mb/plain.out" >/dev/null &&
    [[ $mb_order =~ ^([0-9]+)\ ([0-9]+)\ ([0-9]+)\ $ ]] && ((BASH_REMATCH[1] < BASH_REMATCH[2])) &&
    grep -e "Install it again from there, from any folder: /[^ ]*/scripts/install.sh /[^ ]*/.build/milestone/M1-${mb_commit:0:12}-ios/Build/Products/Release-iphoneos/Knot.app --device Self-test\\\\ iPhone$" "$mb/install.out" >/dev/null &&
    grep -e 'would refuse the folder' "$mb/install.out" >/dev/null &&
    [[ $mb_wait_line =~ built\ in\ ([0-9]+)s,\ after\ waiting\ ([0-9]+)s ]] && ((BASH_REMATCH[1] <= 1 && BASH_REMATCH[2] >= 2)) &&
    grep -e 'mac: its products could not be unregistered from LaunchServices: lsregister -u failed on Knot.app' "$mb/unregister-fails.out" >/dev/null &&
    grep -e "mac: its products could not be unregistered from LaunchServices: LaunchServices' tool is not at" "$mb/unregister-missing.out" >/dev/null &&
    ! grep -e 'are unregistered from LaunchServices' "$mb/unregister-fails.out" "$mb/unregister-missing.out" >/dev/null &&
    grep -e '^milestone-build: ios: built in [0-9]*s, after waiting [0-9]*s for a build slot$' "$mb/plain.out" >/dev/null &&
    grep -e 'built in [0-9]*s (the wait for a slot apart), every part verified' "$mb/plain.out" >/dev/null &&
    [[ -z "$(ls -A "$mb/tree/.build/milestone" | grep -e '^\.slot-time' || true)" ]] &&
    grep -e 'The checkout of Synthetic in .build/SourcePackages is changed, in 1 of its paths' "$mb/pkg-edited.out" >/dev/null &&
    grep -e 'The checkout of Synthetic in .build/SourcePackages is at [0-9a-f]*, not the pinned' "$mb/pkg-moved.out" >/dev/null &&
    grep -e "the packages' checkouts stand at their pinned revisions, with no change (1 read)" "$mb/plain.out" >/dev/null &&
    grep -e 'ios: Knot.app/PlugIns/Widgets-iOS.appex is signed with no team, ad hoc or not at all' "$mb/adhoc.out" >/dev/null &&
    grep -e "mac: the tool's app groups, group.com.example.other, are not the app's, <TEAM>.com.p3ob7o.knot" "$mb/tool-group.out" >/dev/null &&
    grep -e "ios: each of its 5 parts is signed by the app's own team" "$mb/plain.out" >/dev/null &&
    grep -e "mac: the tool's app groups are the app's" "$mb/plain.out" >/dev/null &&
    [[ $mb_mac_install == 1 ]] &&
    grep -e "Install it again from there, from any folder: /[^ ]*/scripts/install.sh /[^ ]*/.build/milestone/M1-${mb_commit:0:12}-mac/Build/Products/Release/Knot.app --mac-folder /[^ ]*/folder$" "$mb/mac-install.out" >/dev/null &&
    grep -e 'move it away first' "$mb/mac-install.out" >/dev/null &&
    grep -e 'git ignores under the folders the build reads, 1 of them, such as Packages/KnotKit/Sources/KnotCore/build/Hidden.swift' "$mb/ignored.out" >/dev/null &&
    grep -e 'uncommitted changes' "$mb/untracked.out" >/dev/null &&
    grep -e 'Worktree.xcconfig sets more than KNOT_WORKTREE and KNOT_WORKTREE_ID: SWIFT_ACTIVE_COMPILATION_CONDITIONS\.' "$mb/worktree-config.out" >/dev/null &&
    ! grep -e 'DEBUG KNOT_FAKES' "$mb/worktree-config.out" >/dev/null &&
    grep -e 'Local.xcconfig sets more than KNOT_SIGNING and DEVELOPMENT_TEAM: #include, OTHER_SWIFT_FLAGS\.' "$mb/local-config.out" >/dev/null &&
    grep -e 'Local.xcconfig sets more than KNOT_SIGNING and DEVELOPMENT_TEAM: line 2 (not a setting; not printed)\.' "$mb/unparsed-config.out" >/dev/null &&
    ! grep -e 'NO_EQUALS' -e "$mb_team" "$mb/unparsed-config.out" >/dev/null &&
    grep -e 'ios: Knot.app/PlugIns/Widgets-iOS.appex/Knot holds what a milestone build may not: the module KnotFakes' "$mb/fakes.out" >/dev/null &&
    grep -e 'mac: Knot.app/Contents/MacOS/knot-cli holds what a milestone build may not: -KnotPreview' "$mb/debug.out" >/dev/null &&
    grep -e 'ios: no fakes and no debug launch argument in its 5 Mach-O files' "$mb/plain.out" >/dev/null &&
    grep -e 'ios: codesign --verify --strict passed on each of its 5 parts, alone: .*Knot.app/Frameworks/Synthetic.framework' "$mb/plain.out" >/dev/null &&
    grep -e 'level M2, not M1;' "$mb/level.out" >/dev/null && grep -e 'build number 2, not 1;' "$mb/app-build.out" >/dev/null &&
    grep -e 'Knot.app/PlugIns/Widgets-iOS.appex is 0.3.0 (2);' "$mb/inner-build.out" >/dev/null &&
    grep -e 'holds an earlier build' "$mb/earlier-log.out" >/dev/null &&
    [[ $mb_profile_log == *"profile allows <TEAM>.com.example.other"* && $mb_profile_log != *"$mb_team"* ]] &&
    grep -e "^install .*-mac/Build/Products/Release/Knot.app --mac-folder" "$mb/install.record" >/dev/null; then
    pass "milestone-build.sh stops before the install at a part that fails its check or its app group, refuses used derived data, another HEAD, a dirty tree and no account, keeps the team's configuration and its logs, prints its summary before an install that, failing, names how to install again, and passes a provisioning flag only when asked, the device's never"
else
    fail "milestone-build.sh: $mb_verdicts; order $mb_order; plain: $(grep -e 'app group' "$mb/plain.out" | tr '\n' '|'); profile: $(grep -e 'app group' "$mb/profile.out" | tail -n 1); install: $(grep -e 'again' "$mb/install.out" | tr '\n' '|')"
fi

# The archive that scripts/release.sh asks scripts/milestone-build.sh for (--archive): the same
# stand-ins, at the tree's HEAD. The build is an archive into the folder named, with the build
# number given passed to xcodebuild and compared on every part, its log in that folder; every
# check of a build runs on the app in the archive, and the derived data goes once they pass. A
# folder that holds anything, --install beside --archive, a build number without --archive and
# one that is not a whole number above 0 are refused before any build; a part with another build
# number than the one given fails the check.
mb_head="$(mb_git rev-parse HEAD)"
mkdir -p "$mb/archives/used"
echo earlier >"$mb/archives/used/earlier"
mb_archive="$(mb_run archive M1 --commit "$mb_head" --products ios --archive "$mb/archives/ok" --build-number 7)"
mb_archive_used="$(mb_run archive-used M1 --commit "$mb_head" --products ios --archive "$mb/archives/used" --build-number 7)"
mb_archive_install="$(mb_run archive-install M1 --commit "$mb_head" --products ios --archive "$mb/archives/install" --install)"
mb_archive_number="$(mb_run archive-number M1 --commit "$mb_head" --products ios --build-number 7)"
mb_archive_zero="$(mb_run archive-zero M1 --commit "$mb_head" --products ios --archive "$mb/archives/zero" --build-number 0)"
mb_archive_wrong="$(KNOT_MB_WRONG_BUILD=Widgets-iOS.appex mb_run archive-wrong M1 --commit "$mb_head" --products ios --archive "$mb/archives/wrong" --build-number 7)"
mb_archived() { grep -c -e '^xcodebuild .* archive -archivePath ' "$mb/$1.record" || true; }
# An archive that fails: the excerpt of its log names it. A folder that cannot be read, and an
# empty one that cannot be claimed. XCODE_XCCONFIG_FILE, for the script and for its worker alone.
mb_archive_failed="$(KNOT_MB_ARCHIVE_FAIL=1 mb_run archive-failed M1 --commit "$mb_head" --products ios --archive "$mb/archives/failed" --build-number 7)"
mkdir -p "$mb/archives/locked" "$mb/archives/read-only"
chmod 000 "$mb/archives/locked"
chmod 500 "$mb/archives/read-only"
mb_archive_locked="$(mb_run archive-locked M1 --commit "$mb_head" --products ios --archive "$mb/archives/locked" --build-number 7)"
mb_archive_read_only="$(mb_run archive-read-only M1 --commit "$mb_head" --products ios --archive "$mb/archives/read-only" --build-number 7)"
chmod 700 "$mb/archives/locked" "$mb/archives/read-only"
mb_override="$(XCODE_XCCONFIG_FILE="$mb/override.xcconfig" mb_run override M1 --commit "$mb_head" --products ios --archive "$mb/archives/override" --build-number 7)"
mb_worker=0
env XCODE_XCCONFIG_FILE="$mb/override.xcconfig" KNOT_TREE="$mb/tree" "$mb/scripts/milestone-build.sh" --in-build >"$mb/worker.out" 2>&1 || mb_worker=$?
mb_archive_verdicts="ok $mb_archive/$(mb_archived archive) used $mb_archive_used/$(mb_archived archive-used) install $mb_archive_install/$(mb_archived archive-install) number $mb_archive_number/$(mb_builds archive-number) zero $mb_archive_zero/$(mb_archived archive-zero) wrong $mb_archive_wrong/$(mb_archived archive-wrong) failed $mb_archive_failed/$(mb_archived archive-failed) locked $mb_archive_locked/$(mb_archived archive-locked) read-only $mb_archive_read_only/$(mb_archived archive-read-only) override $mb_override/$(mb_archived override) worker $mb_worker"
if [[ $mb_archive_verdicts == "ok 0/1 used 1/0 install 1/0 number 1/0 zero 1/0 wrong 1/1 failed 1/1 locked 1/0 read-only 1/0 override 1/0 worker 1" ]] &&
    grep -e '^    \*\* ARCHIVE FAILED \*\*$' "$mb/archive-failed.out" >/dev/null &&
    grep -e 'is not a new or empty folder that can be read' "$mb/archive-locked.out" >/dev/null &&
    grep -e 'could not be claimed' "$mb/archive-read-only.out" >/dev/null &&
    grep -e 'milestone-build-xcconfig-override' "$mb/override.out" >/dev/null && grep -e 'milestone-build-xcconfig-override' "$mb/worker.out" >/dev/null &&
    grep -e "^xcodebuild .* KNOT_BUILD_NUMBER=7 .* archive -archivePath $mb/archives/ok/Knot-ios.xcarchive$" "$mb/archive.record" >/dev/null &&
    grep -e "-derivedDataPath $mb/archives/ok/DerivedData-ios " "$mb/archive.record" >/dev/null &&
    [[ -f $mb/archives/ok/Knot-ios.xcarchive/Products/Applications/Knot.app/Info.plist && ! -e $mb/archives/ok/DerivedData-ios ]] &&
    [[ -s $mb/archives/ok/milestone-build-M1-${mb_head:0:12}-ios.log ]] &&
    grep -e '^milestone-build: ios: com.p3ob7o.knot 0.3.0 (7), flavour milestone, level M1$' "$mb/archive.out" >/dev/null &&
    grep -e 'ios: the archive passed every check; its derived data is removed' "$mb/archive.out" >/dev/null &&
    grep -e "archived in [0-9]*s (the wait for a slot apart), every part verified, at .*/archives/ok/Knot-ios.xcarchive" "$mb/archive.out" >/dev/null &&
    ! grep -e '^install ' "$mb/archive.record" >/dev/null &&
    grep -e 'is not a new or empty folder' "$mb/archive-used.out" >/dev/null &&
    grep -e 'Knot.app/PlugIns/Widgets-iOS.appex is 0.3.0 (2);' "$mb/archive-wrong.out" >/dev/null; then
    pass "milestone-build.sh --archive archives into a new folder with the build number given, checks the archived app as it checks a build, names a failed archive, and refuses a used, unreadable or unclaimable folder, an install, a build number without an archive, and XCODE_XCCONFIG_FILE in the script and in its worker"
else
    fail "milestone-build.sh --archive: $mb_archive_verdicts; $(tail -n 3 "$mb/archive.out" | tr '\n' ' ')"
fi

# The gate's packaging check of the milestone flavour builds under the development identifiers
# (B1): the build is given KNOT_BUNDLE_ID_milestone, KNOT_APP_GROUP_milestone and
# KNOT_CLOUD_CONTAINER_milestone with their development values before it starts, and a product
# that carries the milestone's bundle ID fails the check. The check's own function, from
# verify.sh, with a stand-in xcodebuild that writes down its arguments and makes a product under
# the bundle ID it is given (the milestone's when it is given none, as the project would), and a
# stand-in lsregister; on a scratch tree that holds the identifiers.
pk="$scratch/packaging-milestone"
mkdir -p "$pk/tree/Apps/Config" "$pk/stub"
cp "$KNOT_SELF/Apps/Config/Identifiers.xcconfig" "$pk/tree/Apps/Config/"
cat >"$pk/stub/xcodebuild" <<'SH'
#!/bin/bash
echo "xcodebuild $*" >>"$KNOT_PK_RECORD"
derived="" bundle=com.p3ob7o.knot
for ((i = 1; i <= $#; i++)); do
    j=$((i + 1))
    case ${!i} in
        -derivedDataPath) derived=${!j} ;;
        KNOT_BUNDLE_ID_milestone=*) bundle=${!i#KNOT_BUNDLE_ID_milestone=} ;;
    esac
done
[[ -z ${KNOT_PK_FORCE_BUNDLE:-} ]] || bundle=$KNOT_PK_FORCE_BUNDLE
app="$derived/Build/Products/Release/Knot.app"
mkdir -p "$app/Contents/MacOS"
echo app >"$app/Contents/MacOS/Knot"
echo tool >"$app/Contents/MacOS/knot-cli"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>Knot</string><key>KnotFlavour</key><string>milestone</string></dict></plist>\n' "$bundle" >"$app/Contents/Info.plist"
echo "** BUILD SUCCEEDED **"
SH
printf '#!/bin/bash\necho "lsregister $*" >>"$KNOT_PK_RECORD"\n' >"$pk/stub/lsregister"
chmod +x "$pk/stub/xcodebuild" "$pk/stub/lsregister"
python3 -I - "$KNOT_SCRIPTS/verify.sh" "$pk/check.sh" <<'PY'
import sys
text = open(sys.argv[1]).read()
def function(name):
    start = text.index(name + "() {")
    return text[start:text.index("\n}\n", start) + 3]
open(sys.argv[2], "w").write('source "$KNOT_SCRIPTS/lib/common.sh"\n' + function("plist_value") + function("packaging_milestone_mac") +
                            'packaging_milestone_mac "$1"\n')
PY
pk_run() { # pk_run <name> <environment…>: the check's status
    local name=$1 status=0
    shift
    : >"$pk/$name.record"
    env PATH="$pk/stub:$PATH" KNOT_SCRIPTS="$KNOT_SCRIPTS" KNOT_TREE="$pk/tree" KNOT_TREE_NAMED=1 \
        KNOT_LSREGISTER="$pk/stub/lsregister" KNOT_PK_RECORD="$pk/$name.record" "$@" \
        bash "$pk/check.sh" "$pk/$name.log" >"$pk/$name.out" 2>&1 || status=$?
    echo "$status"
}
pk_dev="$(pk_run dev)"
pk_forced="$(pk_run forced KNOT_PK_FORCE_BUNDLE=com.p3ob7o.knot)"
if [[ $pk_dev == 0 && $pk_forced == 1 ]] &&
    grep -e '^xcodebuild .* KNOT_FLAVOUR=milestone .*KNOT_BUNDLE_ID_milestone=com.p3ob7o.knot.dev KNOT_APP_GROUP_milestone=group.com.p3ob7o.knot.dev KNOT_CLOUD_CONTAINER_milestone=iCloud.com.p3ob7o.knot.dev ' "$pk/dev.record" >/dev/null &&
    grep -e '^lsregister -u .*/DerivedData-milestone/Build/Products/Release/Knot.app$' "$pk/dev.record" >/dev/null &&
    [[ ! -e $pk/tree/.build/DerivedData-milestone ]] &&
    grep -e 'carries com.p3ob7o.knot, not the development bundle ID com.p3ob7o.knot.dev' "$pk/forced.out" >/dev/null &&
    grep -e '^lsregister -u ' "$pk/forced.record" >/dev/null; then
    pass "the gate's milestone-flavour check builds under the development identifiers, and fails a product with the milestone's bundle ID, unregistering it"
else
    fail "the gate's milestone-flavour check: status $pk_dev, with the milestone's ID $pk_forced: $(head -n 1 "$pk/dev.record" | cut -c1-300) / $(tail -n 2 "$pk/forced.out" | tr '\n' ' ')"
fi

# scripts/release.sh, on made-up archives. What it calls is reached as a real run reaches it:
# xcodebuild and altool through the Xcode the script selects, here a stand-in Xcode named by
# KNOT_XCODE that carries the pinned Xcode's identity and links every other tool to the real
# one; codesign, security, nm, strings, assetutil, actool and openssl are the real tools, on
# products the test makes and signs ad hoc, with profiles it signs itself. A stand-in
# milestone-build.sh in a copy of the scripts makes the candidate. The stand-ins print the key's
# values and write files that hold them, as the real tools may; a stand-in export leaves the files
# Xcode leaves beside Knot.ipa, naming a made-up team. A scratch git tree holds the identifiers,
# the feature gates, icon sets, a Swift file that uses UserDefaults, a package's pinned checkout,
# an annotated tag m1 and the candidate after it. Nothing signs with a team and nothing reaches
# App Store Connect. Each check fails on a product that lacks what it checks, naming the part,
# and passes on the whole one; an inspector that fails is a failure; no value of the key appears
# in what a run prints or leaves, under tracing too; a signal ends the export and the upload it
# interrupts; a second run waits for none; the file sent is the file checked.
rl_started=$(knot_now)
rl="$scratch/release"
mkdir -p "$rl/tree/Apps/Config" "$rl/tree/Apps/iOS/Sources" "$rl/tree/Packages/KnotKit/Sources/KnotCore/Settings" \
    "$rl/slots" "$rl/fx" "$rl/key"
# Its path resolved, as the scripts resolve the tree: /var is /private/var.
rl="$(cd "$rl" && pwd -P)"
cp "$KNOT_SELF/Apps/Config/Identifiers.xcconfig" "$rl/tree/Apps/Config/"
cp "$KNOT_SELF/Packages/KnotKit/Sources/KnotCore/Settings/FeatureGates.swift" "$rl/tree/Packages/KnotKit/Sources/KnotCore/Settings/"
cp "$KNOT_SELF/.xcode-version" "$rl/tree/"
printf '.build/\n*.xcodeproj/\n' >"$rl/tree/.gitignore"
# A Swift file of the iPhone app that uses UserDefaults: the lint finds that required-reason API in
# the reach of the iPhone app's privacy manifest.
printf 'import Foundation\nlet synthetic = UserDefaults(suiteName: "synthetic")\n' >"$rl/tree/Apps/iOS/Sources/Synthetic.swift"
# The PNG files: the tree's icon sources, with no alpha channel, and the catalogues' sources, an
# opaque icon and one that is transparent.
python3 -I - "$rl" <<'PY'
import json, os, struct, sys, zlib
rl = sys.argv[1]
def png(path, size, alpha):
    pixel = bytes([30, 60, 90, 0]) if alpha else bytes([30, 60, 90])
    raw = (b"\0" + pixel * size) * size
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6 if alpha else 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
for platform in ("iOS", "watchOS"):
    png("%s/tree/Apps/%s/Assets.xcassets/AppIcon.appiconset/icon-1024.png" % (rl, platform), 16, False)
png(rl + "/fx/alpha-icon.png", 16, True)
for name, alpha, platform in (("ios-opaque", False, "ios"), ("watch-opaque", False, "watchos"), ("watch-clear", True, "watchos")):
    folder = "%s/fx/%s.xcassets" % (rl, name)
    png(folder + "/AppIcon.appiconset/icon.png", 1024, alpha)
    json.dump({"images": [{"filename": "icon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}],
               "info": {"author": "xcode", "version": 1}}, open(folder + "/AppIcon.appiconset/Contents.json", "w"))
    json.dump({"info": {"author": "xcode", "version": 1}}, open(folder + "/Contents.json", "w"))
PY
for catalogue in ios-opaque:iphoneos:iphone:ipad watch-opaque:watchos:watch: watch-clear:watchos:watch:; do
    IFS=: read -r name platform device second <<<"$catalogue"
    devices=(--target-device "$device")
    [[ -z $second ]] || devices+=(--target-device "$second")
    mkdir -p "$rl/fx/$name"
    xcrun actool --compile "$rl/fx/$name" --platform "$platform" --minimum-deployment-target 27.0 --app-icon AppIcon \
        --output-partial-info-plist "$rl/fx/$name.plist" "${devices[@]}" "$rl/fx/$name.xcassets" >>"$rl/fx/actool.log" 2>&1 ||
        echo "the catalogue $name was not compiled" >>"$rl/fx/actool.log"
done
printf 'not a catalogue\n' >"$rl/fx/corrupt.car"
# The binaries: the milestone build's plain, fakes and debug ones; one that uses AVAudioApplication,
# which asks for the microphone; and one that file takes for a Mach-O file and nm cannot read.
cp "$mb/bin/plain" "$mb/bin/fakes" "$mb/bin/debug" "$rl/fx/"
printf 'extern char microphone[] __asm__("_OBJC_CLASS_$_AVAudioApplication");\nint main(void) { return microphone[0]; }\n' >"$rl/fx/mic.c"
xcrun clang -o "$rl/fx/mic" "$rl/fx/mic.c" -framework AVFAudio 2>>"$rl/fx/clang.log" || echo "the binary mic was not made" >>"$rl/fx/clang.log"
printf '\xcf\xfa\xed\xfe not an object\n' >"$rl/fx/corrupt"
# The profiles' signer, a certificate the test makes, and the made-up team.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$rl/fx/signer.key" -out "$rl/fx/signer.pem" -days 2 \
    -subj "/CN=Synthetic Profile Signer" >>"$rl/fx/openssl.log" 2>&1 || echo "the signer was not made" >>"$rl/fx/openssl.log"
rl_team="ZZ9QX42K7T"
# The team's configuration, as bootstrap links the owner's: the filter masks the team's ID by it.
mkdir -p "$rl/tree/.build/config"
printf 'KNOT_SIGNING = team\nDEVELOPMENT_TEAM = %s\n' "$rl_team" >"$rl/tree/.build/config/Local.xcconfig"
# The archive, as the milestone build or the rehearsal makes it:
#   make-archive.py <folder> <milestone|dev> <level> <build number>
cat >"$rl/make-archive.py" <<'PY'
import os, plistlib, shutil, sys
out, family, level, build = sys.argv[1:5]
broken, fx = set(os.environ.get("KNOT_RL_BREAK", "").split(",")), os.environ["KNOT_RL_FIXTURES"]
base = {"milestone": "com.p3ob7o.knot", "dev": "com.p3ob7o.knot.dev"}[family]
archive = os.path.join(out, "Knot-ios.xcarchive")
app = os.path.join(archive, "Products", "Applications", "Knot.app")
parts = [("app", app, "", "iphoneos", [1, 2]), ("widget", app + "/PlugIns/Widgets-iOS.appex", ".widgets", "iphoneos", [1, 2])]
if "no-watch" not in broken:
    parts += [("watch", app + "/Watch/Knot.app", ".watchkitapp", "watchos", [4]),
              ("watch-widget", app + "/Watch/Knot.app/PlugIns/Widgets-watchOS.appex", ".watchkitapp.widgets", "watchos", [4])]
if "extra-part" in broken:
    parts += [("other", app + "/PlugIns/Other.appex", ".other", "iphoneos", [1, 2])]
def dump(value, path):
    with open(path, "wb") as f:
        plistlib.dump(value, f)
for name, path, suffix, platform, families in parts:
    os.makedirs(path, exist_ok=True)
    is_app = path.endswith(".app")
    info = {"CFBundleIdentifier": base + suffix, "CFBundleShortVersionString": "0.3.0", "CFBundleVersion": build,
            "CFBundleExecutable": "Knot", "CFBundlePackageType": "APPL" if is_app else "XPC!", "KnotFlavour": family,
            "KnotAppGroup": "group." + base, "DTPlatformName": platform, "DTXcodeBuild": os.environ["KNOT_RL_XCODE_BUILD"],
            "UIDeviceFamily": families}
    if is_app:
        info.update(KnotMilestoneLevel=level, ITSAppUsesNonExemptEncryption=False,
                    NSMicrophoneUsageDescription="Synthetic: says why it records.",
                    CFBundleIcons={"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}})
    if name == "app":
        info["KnotCloudContainer"] = "iCloud." + base
    if name == "watch":
        info["WKCompanionAppBundleIdentifier"] = base
    edits = {
        "family": ("watch", "CFBundleIdentifier", "com.example.watchkitapp"),
        "version": ("widget", "CFBundleShortVersionString", "0.3.1"),
        "build": ("widget", "CFBundleVersion", "1"),
        "flavour": ("watch-widget", "KnotFlavour", "dev"),
        "level": ("watch", "KnotMilestoneLevel", "M3"),
        "group": ("widget", "KnotAppGroup", "group.com.example"),
        "simulator": ("watch", "DTPlatformName", "watchsimulator"),
        "beta": ("app", "DTXcodeBuild", "27C5035i"),
        "other-xcode": ("widget", "DTXcodeBuild", "27A1"),
        "encryption-true": ("app", "ITSAppUsesNonExemptEncryption", True),
    }
    for edit, (role, key, value) in edits.items():
        if edit in broken and role == name:
            info[key] = value
    if "retired" in broken:
        info["CFBundleShortVersionString"] = "0.2.0"
    if "usage" in broken and name == "watch":
        del info["NSMicrophoneUsageDescription"]
    if "encryption" in broken and name == "watch":
        del info["ITSAppUsesNonExemptEncryption"]
    dump(info, path + "/Info.plist")
    if not ("privacy" in broken and name == "watch-widget"):
        reasons = [] if "reason" in broken or name != "app" else [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}]
        dump({"NSPrivacyTracking": "tracking" in broken and name == "widget", "NSPrivacyTrackingDomains": [],
              "NSPrivacyCollectedDataTypes": [], "NSPrivacyAccessedAPITypes": reasons}, path + "/PrivacyInfo.xcprivacy")
    binary = "mic" if is_app else "plain"
    if "fakes" in broken and name == "widget":
        binary = "fakes"
    if "debug" in broken and name == "watch":
        binary = "debug"
    if "usage-scan" in broken and name == "widget":
        binary = "mic"
    if "corrupt-binary" in broken and name == "widget":
        binary = "corrupt"
    if not ("no-executable" in broken and name == "widget"):
        shutil.copy(os.path.join(fx, binary), path + "/Knot")
    if is_app and not ("no-car" in broken and name == "app"):
        car = {"app": "ios-opaque/Assets.car", "watch": "watch-opaque/Assets.car"}[name]
        if "icon" in broken and name == "watch":
            car = "watch-clear/Assets.car"
        if "corrupt-car" in broken and name == "app":
            car = "corrupt.car"
        shutil.copy(os.path.join(fx, car), path + "/Assets.car")
if "unreadable" in broken:
    os.makedirs(app + "/PlugIns/Widgets-iOS.appex/Locked")
    os.chmod(app + "/PlugIns/Widgets-iOS.appex/Locked", 0)
if "debug-dylib" in broken:
    open(app + "/Knot.debug.dylib", "w").write("synthetic")
if "xctest" in broken:
    os.makedirs(app + "/PlugIns/Knot-iOS-Tests.xctest")
if "no-dsym" not in broken:
    os.makedirs(os.path.join(archive, "dSYMs", "Knot.app.dSYM"), exist_ok=True)
dump({"Name": "Knot", "ApplicationProperties": {"CFBundleIdentifier": base}}, os.path.join(archive, "Info.plist"))
PY
# The export, as xcodebuild -exportArchive makes Knot.ipa: each part signed again, ad hoc here,
# with the entitlements of a distribution signature, and a profile the test signs. Beside it, the
# files Xcode leaves there, which name the team and may name the key.
#   export.py <archive> <export folder> <key ID>
cat >"$rl/export.py" <<'PY'
import os, plistlib, shutil, subprocess, sys, tempfile
archive, export, key_id = sys.argv[1:4]
work = tempfile.mkdtemp()
broken, fx, team = set(os.environ.get("KNOT_RL_EXPORT_BREAK", "").split(",")), os.environ["KNOT_RL_FIXTURES"], os.environ["KNOT_RL_TEAM"]
stage = os.path.join(export, "stage")
app = os.path.join(stage, "Payload", "Knot.app")
shutil.copytree(os.path.join(archive, "Products", "Applications", "Knot.app"), app)
parts = []
for folder, dirs, _ in os.walk(os.path.join(stage, "Payload")):
    parts += [os.path.join(folder, d) for d in dirs if d.endswith((".app", ".appex"))]
for part in sorted(parts, key=lambda p: -p.count("/")):
    with open(part + "/Info.plist", "rb") as f:
        bundle = plistlib.load(f)["CFBundleIdentifier"]
    top = part == app
    watch = part.endswith("Watch/Knot.app")
    e = {"application-identifier": "%s.%s" % ("AA1BB2CC3D" if "team" in broken and watch else team, bundle),
         "com.apple.developer.team-identifier": team, "beta-reports-active": True,
         "com.apple.security.application-groups": ["group.com.example" if "group" in broken and part.endswith("Widgets-iOS.appex") else "group.com.p3ob7o.knot"]}
    if top:
        e["aps-environment"] = "development" if "push" in broken else "production"
        e["com.apple.developer.icloud-services"] = ["CloudKit"]
        e["com.apple.developer.icloud-container-identifiers"] = ["iCloud.com.example" if "container" in broken else "iCloud.com.p3ob7o.knot"]
        e["com.apple.developer.icloud-container-environment"] = "Development" if "container-environment" in broken else "Production"
    if "get-task-allow" in broken and watch:
        e["get-task-allow"] = True
    permits = dict(e)
    permits["application-identifier"] = "%s.%s" % (team, bundle)
    permits["com.apple.developer.icloud-container-environment"] = ["Development", "Production"]
    permits["keychain-access-groups"] = [team + ".*"]
    if "get-task-allow" in broken and watch:
        permits["get-task-allow"] = True
    if "not-allowed" in broken and part.endswith("Widgets-iOS.appex"):
        del permits["beta-reports-active"]
    profile = {"Name": "Synthetic App Store", "TeamIdentifier": [team], "Entitlements": permits}
    if "devices" in broken and part.endswith("Widgets-iOS.appex"):
        profile["ProvisionedDevices"] = []
    with open(work + "/profile.plist", "wb") as f:
        plistlib.dump(profile, f)
    if "unreadable-profile" in broken and watch:
        open(part + "/embedded.mobileprovision", "w").write("not a profile")
    else:
        subprocess.run(["/usr/bin/openssl", "smime", "-sign", "-binary", "-nodetach", "-signer", fx + "/signer.pem",
                        "-inkey", fx + "/signer.key", "-in", work + "/profile.plist", "-outform", "der",
                        "-out", part + "/embedded.mobileprovision"], check=True)
    with open(work + "/entitlements.plist", "wb") as f:
        plistlib.dump(e, f)
    if not ("unsigned" in broken and part.endswith("Widgets-iOS.appex")):
        subprocess.run(["/usr/bin/codesign", "-f", "-s", "-", "--entitlements", work + "/entitlements.plist", part],
                       check=True, capture_output=True)
if "tampered" in broken:
    with open(app + "/Watch/Knot.app/Knot", "ab") as f:
        f.write(b"changed after signing")
subprocess.run(["ditto", "-c", "-k", "--keepParent", os.path.join(stage, "Payload"), os.path.join(export, "Knot.ipa")], check=True)
shutil.rmtree(stage)
shutil.rmtree(work)
with open(os.path.join(export, "DistributionSummary.plist"), "wb") as f:
    plistlib.dump({"Knot.ipa": [{"team": {"id": team, "name": "Synthetic Team"}, "certificate": "Apple Distribution: Synthetic (%s)" % team}]}, f)
with open(os.path.join(export, "Packaging.log"), "w") as f:
    f.write("Signing with team %s, authenticated with the key %s\n" % (team, key_id))
PY
# The stand-in Xcode: the pinned one's identity, every tool of the pinned one but xcodebuild and
# altool, which are stand-ins that write down what they were given and the names of their
# environment. Its xcodebuild hands what it does not stand in for to the real one.
rl_real="${DEVELOPER_DIR%/Contents/Developer}"
rl_xcode="$rl/Xcode-standin.app"
mkdir -p "$rl_xcode/Contents/Developer/usr/bin"
cp "$rl_real/Contents/version.plist" "$rl_real/Contents/Info.plist" "$rl_xcode/Contents/"
for folder in Toolchains Platforms Library; do ln -s "$rl_real/Contents/Developer/$folder" "$rl_xcode/Contents/Developer/$folder"; done
for folder in lib libexec share include; do ln -s "$rl_real/Contents/Developer/usr/$folder" "$rl_xcode/Contents/Developer/usr/$folder"; done
for tool in "$rl_real"/Contents/Developer/usr/bin/*; do
    case $(basename "$tool") in xcodebuild | altool) continue ;; esac
    ln -s "$tool" "$rl_xcode/Contents/Developer/usr/bin/$(basename "$tool")"
done
{
    echo '#!/bin/bash'
    echo "real=$(printf '%q' "$rl_real/Contents/Developer")"
    cat <<'SH'
stood=""
for argument in "$@"; do [[ $argument == archive || $argument == -exportArchive ]] && stood=$argument; done
[[ -n $stood ]] || DEVELOPER_DIR=$real exec "$real/usr/bin/xcodebuild" "$@"
echo "xcodebuild $*" >>"$KNOT_RL_RECORD"
echo "environment $(env | cut -d= -f1 | sort | tr '\n' ' ')" >>"$KNOT_RL_RECORD"
archive="" export="" flavour="" level="" number="" key_path="" key_id="" issuer=""
for ((i = 1; i <= $#; i++)); do
    j=$((i + 1))
    case ${!i} in
        -archivePath) archive=${!j} ;;
        -exportPath) export=${!j} ;;
        -exportOptionsPlist) echo "options $(tr -d '\n\t' <"${!j}")" >>"$KNOT_RL_RECORD" ;;
        -authenticationKeyPath) key_path=${!j} ;;
        -authenticationKeyID) key_id=${!j} ;;
        -authenticationKeyIssuerID) issuer=${!j} ;;
        KNOT_FLAVOUR=*) flavour=${!i#KNOT_FLAVOUR=} ;;
        KNOT_MILESTONE_LEVEL=*) level=${!i#KNOT_MILESTONE_LEVEL=} ;;
        KNOT_BUILD_NUMBER=*) number=${!i#KNOT_BUILD_NUMBER=} ;;
    esac
done
if [[ $stood == -exportArchive ]]; then
    echo $$ >"$KNOT_RL_RECORD.pid"
    # What xcodebuild keeps while it runs, its distribution logs in its TMPDIR, and what it
    # prints: both name the key.
    logs="${TMPDIR}Knot_synthetic.xcdistributionlogs"
    mkdir -p "$logs"
    echo "authenticated with $key_id of $issuer, team $KNOT_RL_TEAM" >"$logs/IDEDistribution.standard.log"
    echo "IDEDistribution: Created bundle at path \"$logs\"."
    echo "Exporting with the key $key_id, issuer $issuer, from $key_path and $(python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$key_path")"
    if [[ -n ${KNOT_RL_EXPORT_SLEEP:-} ]]; then
        : >"$KNOT_RL_RECORD.sleeping"
        sleep "$KNOT_RL_EXPORT_SLEEP"
        : >"$KNOT_RL_RECORD.woke"
    fi
    if [[ -n ${KNOT_RL_EXPORT_FAIL:-} ]]; then
        echo "error: exportArchive: synthetic: no profile for the team"
        echo "** EXPORT FAILED **"
        exit 70
    fi
    python3 -I "$KNOT_RL_EXPORT" "$archive" "$export" "$key_id" || exit 1
    echo "** EXPORT SUCCEEDED **"
    exit 0
fi
python3 -I "$KNOT_RL_MAKE" "$(dirname "$archive")" "${KNOT_RL_REHEARSAL_FAMILY:-$flavour}" "$level" "$number"
echo "** ARCHIVE SUCCEEDED **"
SH
} >"$rl_xcode/Contents/Developer/usr/bin/xcodebuild"
cat >"$rl_xcode/Contents/Developer/usr/bin/altool" <<'SH'
#!/bin/bash
echo "altool $*" >>"$KNOT_RL_RECORD"
echo "environment $(env | cut -d= -f1 | sort | tr '\n' ' ')" >>"$KNOT_RL_RECORD"
echo "sent $(shasum -a 256 "$2" | cut -d' ' -f1)" >>"$KNOT_RL_RECORD"
temporary="" key_path="" key_id="" issuer=""
for ((i = 1; i <= $#; i++)); do
    j=$((i + 1))
    case ${!i} in
        -CDTempDir) temporary=${!j} ;;
        --p8-file-path) key_path=${!j} ;;
        --api-key) key_id=${!j} ;;
        --api-issuer) issuer=${!j} ;;
    esac
done
echo "chunks of the key $key_id" >"$temporary/upload-chunk"
echo "Authenticating with the key $key_id, issuer $issuer, from $key_path and $(python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$key_path")"
if [[ $1 == --upload-package && -n ${KNOT_RL_UPLOAD_SLEEP:-} ]]; then
    echo $$ >"$KNOT_RL_RECORD.pid"
    : >"$KNOT_RL_RECORD.sleeping"
    sleep "$KNOT_RL_UPLOAD_SLEEP"
    : >"$KNOT_RL_RECORD.woke"
fi
[[ $1 == --validate-app && -n ${KNOT_RL_TAMPER:-} ]] && echo "changed" >>"$2"
if [[ $1 == --validate-app && -n ${KNOT_RL_VALIDATE_FAIL:-} ]] || [[ $1 == --upload-package && -n ${KNOT_RL_UPLOAD_FAIL:-} ]]; then
    echo "ERROR: synthetic: the server did not answer"
    exit 1
fi
echo "No errors $( [[ $1 == --upload-package ]] && echo uploading || echo validating) Knot.ipa"
SH
chmod +x "$rl_xcode/Contents/Developer/usr/bin/xcodebuild" "$rl_xcode/Contents/Developer/usr/bin/altool"
# The stand-in milestone build: it makes the candidate's archive, or fails, or waits.
mkdir -p "$rl/stub"
cat >"$rl/milestone-build.sh" <<'SH'
#!/bin/bash
echo "milestone-build $*" >>"$KNOT_RL_RECORD"
echo "environment $(env | cut -d= -f1 | sort | tr '\n' ' ')" >>"$KNOT_RL_RECORD"
level=$1 folder="" number=""
for ((i = 1; i <= $#; i++)); do
    j=$((i + 1))
    case ${!i} in --archive) folder=${!j} ;; --build-number) number=${!j} ;; esac
done
if [[ -n ${KNOT_RL_MB_SLEEP:-} ]]; then
    : >"$KNOT_RL_RECORD.sleeping"
    sleep "$KNOT_RL_MB_SLEEP"
fi
[[ -z ${KNOT_RL_MB_FAIL:-} ]] || { echo "milestone-build: ios: the build failed"; exit 1; }
mkdir -p "$folder"
python3 -I "$KNOT_RL_MAKE" "$folder" milestone "$level" "$number"
echo "milestone-build: summary, $level"
SH
printf '#!/bin/sh\n[ "$1" = --version ] && echo "Version: %s"\nexit 0\n' "$KNOT_XCODEGEN_VERSION" >"$rl/stub/xcodegen"
printf '#!/bin/bash\necho "lsregister $*" >>"$KNOT_RL_RECORD"\n' >"$rl/stub/lsregister"
chmod +x "$rl/stub/"* "$rl/milestone-build.sh"
cp -R "$KNOT_SCRIPTS" "$rl/scripts"
cp "$rl/milestone-build.sh" "$rl/scripts/milestone-build.sh"
rl_git() { git -C "$rl/tree" -c user.name=self-test -c user.email=self-test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
# A package's pinned checkout, as the rehearsal requires it.
rl_pkg="$rl/tree/.build/SourcePackages/checkouts/Synthetic"
mkdir -p "$rl_pkg"
git -C "$rl_pkg" init -q
printf 'one\n' >"$rl_pkg/Source.swift"
git -C "$rl_pkg" add Source.swift
git -C "$rl_pkg" -c user.name=self-test -c user.email=self-test@example.invalid -c commit.gpgsign=false commit -q -m "the pinned revision"
mkdir -p "$rl/tree/Packages/KnotKit"
printf '{"pins": [{"identity": "synthetic", "kind": "remoteSourceControl", "location": "https://example.invalid/Synthetic.git", "state": {"revision": "%s", "version": "1.0.0"}}], "version": 3}\n' \
    "$(git -C "$rl_pkg" rev-parse HEAD)" >"$rl/tree/Packages/KnotKit/Package.resolved"
rl_git init -q
rl_git add .gitignore .xcode-version Apps Packages
rl_git commit -q -m "the first milestone's commit"
rl_git tag -a m1 -m "M1: a synthetic milestone"
printf 'after the milestone\n' >"$rl/tree/later.txt"
rl_git add later.txt
rl_git commit -q -m "the candidate"
rl_head="$(rl_git rev-parse HEAD)"
# A candidate whose iPhone icon carries an alpha channel, on a branch of its own.
rl_git switch -q -c alpha-icon
cp "$rl/fx/alpha-icon.png" "$rl/tree/Apps/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
rl_git add Apps/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png
rl_git commit -q -m "an icon with alpha"
rl_alpha="$(rl_git rev-parse HEAD)"
rl_git switch -q -
# The key's made-up values: a file named through a folder that is a symbolic link, so that its
# resolved path differs from the path given, an ID and an issuer. None appears in any output.
rl_key_id="SYNTHKEY42" rl_issuer="5ab1c2d3-1e2f-4a5b-8c9d-0e1f2a3b4c5d"
ln -s "$rl/key" "$rl/key-link"
rl_key_path="$rl/key-link/AuthKey_$rl_key_id.p8" rl_key_real="$rl/key/AuthKey_$rl_key_id.p8"
printf 'not a key\n' >"$rl_key_real"
rl_key=(KNOT_ASC_KEY_PATH="$rl_key_path" KNOT_ASC_KEY_ID="$rl_key_id" KNOT_ASC_ISSUER_ID="$rl_issuer")
rl_env() { # rl_env <name>: the environment of a run, as the stand-ins need it
    printf '%s\n' "KNOT_TREE=$rl/tree" "KNOT_XCODE=$rl_xcode" "KNOT_RL_RECORD=$rl/$1.record" "KNOT_RL_MAKE=$rl/make-archive.py" \
        "KNOT_RL_EXPORT=$rl/export.py" "KNOT_RL_FIXTURES=$rl/fx" "KNOT_RL_TEAM=$rl_team" "KNOT_RL_XCODE_BUILD=$KNOT_XCODE_BUILD"
}
rl_run() { # rl_run <name> [NAME=value…] -- <arguments…>: runs release.sh with a fresh record; prints its status
    local name=$1 status=0 settings=() entry
    shift
    while [[ $1 != -- ]]; do settings+=("$1"); shift; done
    shift
    : >"$rl/$name.record"
    rm -f "$rl/$name.record.pid" "$rl/$name.record.sleeping" "$rl/$name.record.woke"
    while IFS= read -r entry; do settings=("$entry" ${settings[@]+"${settings[@]}"}); done < <(rl_env "$name")
    env -u KNOT_LOCAL_CONFIG -u KNOT_ASC_KEY_PATH -u KNOT_ASC_KEY_ID -u KNOT_ASC_ISSUER_ID -u KNOT_XCODEGEN -u KNOT_SLOT_DIR \
        -u KNOT_LSREGISTER ${settings[@]+"${settings[@]}"} "$rl/scripts/release.sh" "$@" >"$rl/$name.out" 2>&1 || status=$?
    echo "$status"
}
# The rehearsal's own stand-ins: its XcodeGen, its slots and LaunchServices' tool.
rl_rehearsal_env=(KNOT_XCODEGEN="$rl/stub/xcodegen" KNOT_SLOT_DIR="$rl/slots" KNOT_LSREGISTER="$rl/stub/lsregister")
rl_has() { grep -F -e "$2" "$rl/$1.out" >/dev/null; } # rl_has <name> <text>: the run printed it
rl_calls() { grep -c -e "^$2" "$rl/$1.record" || true; } # rl_calls <name> <tool>: how often it ran
# The run's folder, from the line that names it, and whether its tmp/ is gone: read right after the
# run, before a later run could sweep it.
rl_folder() { sed -n -E 's/^release: the run.s folder is \.build\/release\/([^,]+), its log release\.log$/\1/p' "$rl/$1.out" | head -n 1; }
rl_tmp() { local f; f="$(rl_folder "$1")"; if [[ -z $f ]]; then echo "no-folder"; elif [[ -e $rl/tree/.build/release/$f/tmp ]]; then echo "tmp-left"; else echo "tmp-gone"; fi; }
# Nothing a run printed or left in the tree holds a value of the key or the made-up team, Knot.ipa
# aside, whose signatures name the team as every signed app does: grep must say "no match",
# status 1; an error of its own is no clean search.
rl_clean() {
    local status=0
    grep -r -F --exclude=Knot.ipa -e "$rl_key_id" -e "$rl_issuer" -e "$rl_key_path" -e "$rl_key_real" -e "$rl_team" \
        "$rl/$1.out" "$rl/tree/.build/release" >/dev/null 2>&1 || status=$?
    [[ $status == 1 ]] && echo clean || echo "leaked($status)"
}
# A whole archive, by a dry run, with a tmp/ that a dead run left, and with the key's values set;
# a dry run under tracing.
mkdir -p "$rl/tree/.build/release/killed/tmp"
echo "a killed run's chunk" >"$rl/tree/.build/release/killed/tmp/left"
rl_good="$(rl_run good -- M2 --commit "$rl_head" --build-number 7)/$(rl_tmp good)"
rl_swept="$( [[ -e $rl/tree/.build/release/killed/tmp ]] && echo left || echo swept)"
rl_names="$(rl_run names "${rl_key[@]}" -- M2 --commit "$rl_head" --build-number 7)/$(rl_clean names)"
: >"$rl/traced.record"
rl_traced=0
env -u KNOT_LOCAL_CONFIG $(rl_env traced) "${rl_key[@]}" bash -x "$rl/scripts/release.sh" M2 --commit "$rl_head" --build-number 7 \
    >"$rl/traced.out" 2>&1 || rl_traced=$?
rl_traced="$rl_traced/$(rl_clean traced)/$(grep -c -e '^+' "$rl/traced.out" || true)"
rl_verdicts="good $rl_good/$rl_swept names $rl_names traced $rl_traced"
# Each check on the archive, against archives that lack what it checks. Breaks that cannot hide one
# another share a run, since every check reports every part that fails it; the scan for fakes and
# debug arguments, which stops at its first find, has one break a run. Each line: the breaks of
# the run, then the FAIL line that one of them must bring.
rl_g1="version,flavour,level,group,simulator,extra-part,encryption-true,tracking,xctest,debug-dylib,no-dsym,privacy,no-car,fakes"
rl_g2="family,build,reason,usage,usage-scan,encryption,icon,beta,other-xcode,corrupt-car,retired,debug"
rl_cases="$rl_g1|binaries: Knot.app/PlugIns/Widgets-iOS.appex/Knot holds what a release may not: the module KnotFakes
$rl_g2|binaries: Knot.app/Watch/Knot.app/Knot holds what a release may not: -KnotPreview
corrupt-binary|binaries: could not look: Knot.app/PlugIns/Widgets-iOS.appex/Knot: nm could not read the file
corrupt-binary|usage: Knot.app/PlugIns/Widgets-iOS.appex/Knot: nm could not read it
no-executable|binaries: could not look: Knot.app/PlugIns/Widgets-iOS.appex has no executable where its Info.plist names one (Knot)
no-executable|usage: Knot.app/PlugIns/Widgets-iOS.appex: no Mach-O file of it could be read
unreadable|roles: Knot.app: the product cannot be read whole
unreadable|binaries: could not look: find could not read the product whole
$rl_g1|configuration: Knot.app/Knot.debug.dylib: the debug dylib of Xcode's Debug configuration
$rl_g1|configuration: Knot.app/PlugIns/Knot-iOS-Tests.xctest: a test bundle
$rl_g1|configuration: dSYMs: the archive holds no dSYM
$rl_g2|configuration: Knot.app: built with Xcode 27C5035i, not the pinned
$rl_g2|configuration: Knot.app/PlugIns/Widgets-iOS.appex: built with Xcode 27A1, not the pinned
$rl_g1|roles: Knot.app/Watch/Knot.app: built for watchsimulator, not watchos
$rl_g2|roles: Knot.app/Watch/Knot.app: bundle ID com.example.watchkitapp, not com.p3ob7o.knot.watchkitapp
no-watch|roles: Knot.app/Watch/Knot.app: the watch is not there
$rl_g1|roles: Knot.app/PlugIns/Other.appex: a part the release does not know
$rl_g1|roles: Knot.app/PlugIns/Widgets-iOS.appex: version 0.3.1, not the candidate's 0.3.0
$rl_g2|roles: Knot.app: version 0.2.0, not the candidate's 0.3.0
$rl_g2|roles: Knot.app/PlugIns/Widgets-iOS.appex: build number 1, not 7
$rl_g1|roles: Knot.app/Watch/Knot.app/PlugIns/Widgets-watchOS.appex: flavour dev, not milestone
$rl_g1|roles: Knot.app/Watch/Knot.app: level M3, not M2
$rl_g1|roles: Knot.app/PlugIns/Widgets-iOS.appex: KnotAppGroup group.com.example, not group.com.p3ob7o.knot
$rl_g1|privacy: Knot.app/Watch/Knot.app/PlugIns/Widgets-watchOS.appex: no privacy manifest
$rl_g1|privacy: Knot.app/PlugIns/Widgets-iOS.appex: its privacy manifest does not say NSPrivacyTracking false
$rl_g2|privacy: Knot.app: its privacy manifest gives no reason for NSPrivacyAccessedAPICategoryUserDefaults, which the lint finds in the reach of Apps/iOS/PrivacyInfo.xcprivacy
$rl_g2|usage: Knot.app/Watch/Knot.app: no NSMicrophoneUsageDescription, which the watch is known to need
$rl_g2|usage: Knot.app/PlugIns/Widgets-iOS.appex: uses AVAudioApplication, which asks for the microphone, and has no usage string
$rl_g2|encryption: Knot.app/Watch/Knot.app: no ITSAppUsesNonExemptEncryption
$rl_g1|encryption: Knot.app: ITSAppUsesNonExemptEncryption is not false
$rl_g2|icons: Knot.app/Watch/Knot.app: its App Store icon icon.png (watch) is not opaque
$rl_g1|icons: Knot.app: no asset catalogue
$rl_g2|icons: Knot.app: assetutil could not read its Assets.car"
rl_broken=""
for broken in $(cut -d'|' -f1 <<<"$rl_cases" | sort -u); do
    name="broken-$(shasum <<<"$broken" | cut -c1-8)"
    status="$(rl_run "$name" KNOT_RL_BREAK="$broken" -- M2 --commit "$rl_head" --build-number 7)"
    { [[ $status == 1 ]] && rl_has "$name" "release-archive-check"; } || rl_broken="$rl_broken ${broken:0:20}…($status)"
    while IFS='|' read -r group expected; do
        [[ $group == "$broken" ]] || continue
        rl_has "$name" "FAIL  $expected" || rl_broken="$rl_broken [$expected]"
    done <<<"$rl_cases"
done
# A product with a folder no one may read is left so that the scratch folder can be removed.
find "$rl/tree/.build/release" -type d -name Locked -exec chmod 700 {} + 2>/dev/null || true
# What it refuses before anything is built: a level that opens sync, a milestone below with no
# tag or a tag that is not annotated, an icon source with alpha, the Mac, the key not set or
# malformed for a validation, a stand-in set for a validation, XCODE_XCCONFIG_FILE, and an
# argument it does not take, which it does not echo. A failed milestone build stops it.
rl_sync="$(rl_run sync -- M4 --commit "$rl_head" --build-number 7)"
rl_no_tag="$(rl_run no-tag -- M3 --commit "$rl_head" --build-number 7)"
rl_git tag m2 "$rl_head"
rl_light="$(rl_run light -- M3 --commit "$rl_head" --build-number 7)"
rl_git tag -d m2 >/dev/null
rl_alpha_icon="$(rl_run alpha-icon -- M2 --commit "$rl_alpha" --build-number 7)"
rl_mac="$(rl_run mac -- M2 --commit "$rl_head" --build-number 7 --products mac)"
rl_no_key="$(rl_run no-key KNOT_ASC_KEY_ID="$rl_key_id" -- M2 --commit "$rl_head" --build-number 7 --validate)"
rl_bad_key="$(rl_run bad-key KNOT_ASC_KEY_PATH="$rl_key_path" KNOT_ASC_KEY_ID=lowercase-$rl_key_id KNOT_ASC_ISSUER_ID="not-$rl_issuer" -- M2 --commit "$rl_head" --build-number 7)"
rl_seam="$(rl_run seam "${rl_key[@]}" KNOT_ALTOOL=/usr/bin/true KNOT_LSREGISTER=/usr/bin/true -- M2 --commit "$rl_head" --build-number 7 --upload)"
rl_override="$(rl_run override XCODE_XCCONFIG_FILE="$rl/fx/override.xcconfig" -- M2 --commit "$rl_head" --build-number 7)"
rl_argument="$(rl_run argument -- M2 --commit "$rl_head" --build-number 7 "--key=$rl_key_id")"
rl_mb_fail="$(rl_run mb-fail KNOT_RL_MB_FAIL=1 -- M2 --commit "$rl_head" --build-number 7)"
rl_verdicts="$rl_verdicts before sync $rl_sync/$(rl_calls sync milestone-build) no-tag $rl_no_tag light $rl_light alpha $rl_alpha_icon mac $rl_mac no-key $rl_no_key/$(rl_calls no-key milestone-build)/$(rl_clean no-key) bad-key $rl_bad_key/$(rl_calls bad-key milestone-build)/$(rl_clean bad-key) seam $rl_seam/$(rl_calls seam milestone-build) override $rl_override/$(rl_calls override milestone-build) argument $rl_argument/$(rl_clean argument) mb-fail $rl_mb_fail"
# A validation and an upload; what would be uploaded, short of each thing the export checks; and
# the export, the validation and the upload that fail.
rl_validate="$(rl_run validate "${rl_key[@]}" -- M2 --commit "$rl_head" --build-number 7 --validate)/$(rl_tmp validate)"
rl_validate_run="$rl/tree/.build/release/$(rl_folder validate)"
rl_upload="$(rl_run upload "${rl_key[@]}" -- M2 --commit "$rl_head" --build-number 7 --upload)/$(rl_tmp upload)"
rl_upload_fail="$(rl_run upload-fail "${rl_key[@]}" KNOT_RL_UPLOAD_FAIL=1 -- M2 --commit "$rl_head" --build-number 7 --upload)/$(rl_tmp upload-fail)"
rl_validate_fail="$(rl_run validate-fail "${rl_key[@]}" KNOT_RL_VALIDATE_FAIL=1 -- M2 --commit "$rl_head" --build-number 7 --upload)/$(rl_tmp validate-fail)"
rl_validate_fail_run="$rl/tree/.build/release/$(rl_folder validate-fail)"
rl_export_fail="$(rl_run export-fail "${rl_key[@]}" KNOT_RL_EXPORT_FAIL=1 -- M2 --commit "$rl_head" --build-number 7 --upload)/$(rl_tmp export-fail)"
rl_export_fail_run="$rl/tree/.build/release/$(rl_folder export-fail)"
rl_tampered="$(rl_run tamper "${rl_key[@]}" KNOT_RL_TAMPER=1 -- M2 --commit "$rl_head" --build-number 7 --upload)"
rl_verdicts="$rl_verdicts validate $rl_validate/$(rl_calls validate 'altool --validate-app')/$(rl_calls validate 'altool --upload-package')/$(rl_clean validate) upload $rl_upload/$(rl_calls upload 'altool --upload-package')/$(rl_clean upload) upload-fail $rl_upload_fail/$(rl_calls upload-fail 'altool --upload-package')/$(rl_clean upload-fail) validate-fail $rl_validate_fail/$(rl_calls validate-fail 'altool --upload-package')/$(rl_clean validate-fail) export-fail $rl_export_fail/$(rl_calls export-fail altool)/$(rl_clean export-fail) tamper $rl_tampered/$(rl_calls tamper 'altool --upload-package')"
rl_e1="push,container-environment,container,group,get-task-allow,devices,not-allowed,team,tampered"
rl_e2="unreadable-profile,unsigned"
rl_export_cases="$rl_e1|signatures: Knot.app: aps-environment development, not production
$rl_e1|signatures: Knot.app: iCloud container environment Development, not Production
$rl_e1|signatures: Knot.app: iCloud containers iCloud.com.example, not iCloud.com.p3ob7o.knot alone
$rl_e1|signatures: Knot.app/PlugIns/Widgets-iOS.appex: app groups group.com.example, not group.com.p3ob7o.knot alone
$rl_e1|signatures: Knot.app/Watch/Knot.app: get-task-allow
$rl_e1|signatures: Knot.app/PlugIns/Widgets-iOS.appex: its provisioning profile has a device list
$rl_e1|signatures: Knot.app/PlugIns/Widgets-iOS.appex: it is signed with beta-reports-active, which its provisioning profile does not allow
$rl_e1|signatures: Knot.app/Watch/Knot.app: its application identifier is not its profile's team and its bundle ID
$rl_e1|signatures: Knot.app/Watch/Knot.app: codesign --verify --strict failed on it
$rl_e2|signatures: Knot.app/Watch/Knot.app: no provisioning profile that security can read
$rl_e2|signatures: Knot.app/PlugIns/Widgets-iOS.appex: its entitlements cannot be read from its signature"
for broken in "$rl_e1" "$rl_e2"; do
    name="export-$(shasum <<<"$broken" | cut -c1-8)"
    status="$(rl_run "$name" "${rl_key[@]}" KNOT_RL_EXPORT_BREAK="$broken" -- M2 --commit "$rl_head" --build-number 7 --upload)"
    if [[ $status != 1 ]] || ! rl_has "$name" "release-export-check" || [[ $(rl_calls "$name" altool) != 0 || $(rl_clean "$name") != clean ]]; then
        rl_broken="$rl_broken export:${broken:0:20}…($status)"
    fi
    while IFS='|' read -r group expected; do
        [[ $group == "$broken" ]] || continue
        rl_has "$name" "FAIL  $expected" || rl_broken="$rl_broken [$expected]"
    done <<<"$rl_export_cases"
done
# A signal: TERM during the export, TERM and INT during the upload. Each run ends the stand-in it
# started, which had not woken, says what it says, and leaves no value and no tmp/.
rl_signal() { # rl_signal <name> <signal> <environment…>: the status, whether the stand-in ended, tmp/
    local name=$1 signal=$2 pid status=0 waited=0 stand_in alive
    shift 2
    : >"$rl/$name.record"
    rm -f "$rl/$name.record.pid" "$rl/$name.record.sleeping" "$rl/$name.record.woke"
    # A job in the background of a shell that is not interactive starts with INT ignored, which bash
    # cannot then trap: perl gives INT back its default before it starts the run, as a terminal's
    # run has it.
    env -u KNOT_LOCAL_CONFIG $(rl_env "$name") "${rl_key[@]}" "$@" /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die' \
        "$rl/scripts/release.sh" M2 --commit "$rl_head" --build-number 7 --upload >"$rl/$name.out" 2>&1 &
    pid=$!
    while [[ ! -e $rl/$name.record.sleeping ]] && ((waited < 300)); do sleep 0.1; waited=$((waited + 1)); done
    stand_in="$(cat "$rl/$name.record.pid" 2>/dev/null || true)"
    kill "-$signal" "$pid" 2>/dev/null || true
    wait "$pid" || status=$?
    alive="ended"
    [[ -z $stand_in ]] || ! kill -0 "$stand_in" 2>/dev/null || alive="alive"
    [[ ! -e $rl/$name.record.woke ]] || alive="woke"
    echo "$status/$alive/$(rl_tmp "$name")/$(rl_clean "$name")"
}
rl_sig_export="$(rl_signal sig-export TERM KNOT_RL_EXPORT_SLEEP=20)"
rl_sig_upload="$(rl_signal sig-upload TERM KNOT_RL_UPLOAD_SLEEP=20)"
rl_sig_upload_int="$(rl_signal sig-upload-int INT KNOT_RL_UPLOAD_SLEEP=20)"
# Two runs at once in one worktree: the second refuses while the first waits in its milestone build.
: >"$rl/first.record"
rm -f "$rl/first.record.sleeping"
env -u KNOT_LOCAL_CONFIG $(rl_env first) KNOT_RL_MB_SLEEP=4 "$rl/scripts/release.sh" M2 --commit "$rl_head" --build-number 7 >"$rl/first.out" 2>&1 &
rl_first=$!
rl_waited=0
while [[ ! -e $rl/first.record.sleeping ]] && ((rl_waited < 300)); do sleep 0.1; rl_waited=$((rl_waited + 1)); done
rl_second="$(rl_run second -- M2 --commit "$rl_head" --build-number 7)"
rl_first_status=0
wait "$rl_first" || rl_first_status=$?
rl_verdicts="$rl_verdicts signals $rl_sig_export $rl_sig_upload $rl_sig_upload_int together $rl_first_status/$rl_second/$(rl_calls second milestone-build)"
# The rehearsal: the development flavour, signed by nothing, resolving nothing, with no signature
# read and the key out of its environment; one whose archive carries the milestone's bundle ID in
# a part; one with the pinned checkout missing; and one that LaunchServices' tool cannot serve.
rl_rehearsal="$(rl_run rehearsal "${rl_rehearsal_env[@]}" "${rl_key[@]}" -- --rehearsal M2 --build-number 7)/$(rl_tmp rehearsal)"
rl_rehearsal_milestone="$(rl_run rehearsal-milestone "${rl_rehearsal_env[@]}" KNOT_RL_REHEARSAL_FAMILY=milestone -- --rehearsal M2 --build-number 7)"
printf '#!/bin/bash\necho "lsregister $*" >>"$KNOT_RL_RECORD"\n[[ $1 == -dump ]] && { echo "path: /Applications/Other.app"; exit 0; }\nexit 1\n' >"$rl/stub/lsregister-unknown"
chmod +x "$rl/stub/lsregister-unknown"
rl_unknown="$(rl_run rehearsal-unknown "${rl_rehearsal_env[@]}" KNOT_LSREGISTER="$rl/stub/lsregister-unknown" -- --rehearsal M2 --build-number 7)"
mv "$rl_pkg" "$rl/fx/moved-checkout"
rl_no_checkout="$(rl_run rehearsal-no-checkout "${rl_rehearsal_env[@]}" -- --rehearsal M2 --build-number 7)/$(rl_calls rehearsal-no-checkout xcodebuild)"
mv "$rl/fx/moved-checkout" "$rl_pkg"
rl_verdicts="$rl_verdicts rehearsal $rl_rehearsal/$(rl_calls rehearsal milestone-build)/$(rl_calls rehearsal 'xcodebuild -exportArchive')/$(rl_calls rehearsal altool) rehearsal-milestone $rl_rehearsal_milestone unknown $rl_unknown no-checkout $rl_no_checkout"
# The bytes sent: the SHA-256 the run printed, and what altool was given at each call.
rl_digest="$(sed -n -E 's/.*Knot\.ipa, SHA-256 ([0-9a-f]{64}):.*/\1/p' "$rl/upload.out" | head -n 1)"
rl_sent="$(sed -n -E 's/^sent ([0-9a-f]{64})$/\1/p' "$rl/upload.record" | sort -u | tr '\n' ' ')"
rl_expected="good 0/tmp-gone/swept names 0/clean traced 0/clean/0 before sync 1/0 no-tag 1 light 1 alpha 1 mac 1 no-key 1/0/clean bad-key 1/0/clean seam 1/0 override 1/0 argument 1/clean mb-fail 1 validate 0/tmp-gone/1/0/clean upload 0/tmp-gone/1/clean upload-fail 1/tmp-gone/1/clean validate-fail 1/tmp-gone/0/clean export-fail 1/tmp-gone/0/clean tamper 1/0 signals 143/ended/tmp-gone/clean 143/ended/tmp-gone/clean 130/ended/tmp-gone/clean together 0/1/0 rehearsal 0/tmp-gone/0/0/0 rehearsal-milestone 1 unknown 0 no-checkout 1/0"
if [[ $rl_verdicts == "$rl_expected" && -z $rl_broken ]] &&
    grep -e "^milestone-build M2 --commit $rl_head --products ios --archive $rl/tree/.build/release/dry-run-M2-${rl_head:0:12}-b7-[0-9TZ]*-[A-Za-z0-9]*/candidate --build-number 7$" "$rl/good.record" >/dev/null &&
    rl_has good "dry run passed" && rl_has good "ok    evidence: the annotated tags of the milestones below M2, at or before ${rl_head:0:12}: m1" &&
    rl_has good "ok    level: M2 keeps sync shut, which opens at M4" && rl_has good "ok    icons: the iPhone's and the Watch's icon sources" &&
    rl_has good "ok    roles: the app, its widgets, the Watch app and its widgets, at their paths, of com.p3ob7o.knot, 0.3.0 (7)" &&
    rl_has good "ok    privacy: a privacy manifest in each of its 4 parts" &&
    rl_has good "Knot.app uses AVAudioApplication, and says why in NSMicrophoneUsageDescription" &&
    rl_has good "ok    icons: an opaque App Store icon of 1024 by 1024 in Knot.app (phone, pad), Knot.app/Watch/Knot.app (watch)" &&
    rl_has good "ok    binaries: no fakes and no debug launch argument in its 4 Mach-O files" &&
    rl_has good "KNOT_ASC_KEY_PATH (not set), KNOT_ASC_KEY_ID (not set), KNOT_ASC_ISSUER_ID (not set)" &&
    rl_has names "KNOT_ASC_KEY_PATH (set, a readable file), KNOT_ASC_KEY_ID (set), KNOT_ASC_ISSUER_ID (set)" &&
    ! grep -e 'KNOT_ASC_' -e 'XCODE_XCCONFIG_FILE' <(grep -e '^environment ' "$rl/names.record" "$rl/validate.record" "$rl/upload.record" "$rl/rehearsal.record") >/dev/null &&
    [[ $(grep -c -e '^environment ' "$rl/validate.record") == 3 ]] &&
    [[ $(rl_calls good xcodebuild) == 0 && $(rl_calls good altool) == 0 ]] &&
    rl_has traced "dry run passed" &&
    rl_has sync "M4 opens sync, which opens at M4, and the tree has no committed CloudKit schema file" &&
    rl_has no-tag "evidence: M2 has no evidence: the repository holds no annotated tag m2" &&
    rl_has light "only a tag that is not annotated" &&
    rl_has alpha-icon "icons: Apps/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png carries an alpha channel" &&
    rl_has mac "release-mac-sp3" && rl_has mac "SP-3" &&
    rl_has no-key "key: KNOT_ASC_KEY_PATH is not set" && rl_has no-key "key: KNOT_ASC_ISSUER_ID is not set" &&
    rl_has bad-key "key: KNOT_ASC_KEY_ID is set, but not ten capitals and digits" && rl_has bad-key "key: KNOT_ASC_ISSUER_ID is set, but not a UUID" &&
    rl_has seam "tools: KNOT_ALTOOL is set" && rl_has seam "tools: KNOT_LSREGISTER is set" &&
    rl_has override "release-xcconfig-override" && rl_has argument "Argument 6 is not one this script takes." &&
    rl_has mb-fail "release-candidate" &&
    grep -e "^xcodebuild -exportArchive .* -allowProvisioningUpdates -authenticationKeyPath $rl_key_path -authenticationKeyID $rl_key_id -authenticationKeyIssuerID $rl_issuer$" "$rl/validate.record" >/dev/null &&
    grep -e "^altool --validate-app $rl_validate_run/export/Knot.ipa --api-key $rl_key_id --api-issuer $rl_issuer --p8-file-path $rl_key_path -CDTempDir " "$rl/validate.record" >/dev/null &&
    grep -F -e "Exporting with the key <KEY-ID>, issuer <ISSUER-ID>, from <KEY-PATH> and <KEY-PATH>" "$rl_validate_run/release.log" >/dev/null &&
    rl_has validate "Authenticating with the key <KEY-ID>, issuer <ISSUER-ID>, from <KEY-PATH> and <KEY-PATH>" &&
    grep -e '^options .*<key>method</key><string>app-store-connect</string>.*<key>destination</key><string>export</string>.*<key>iCloudContainerEnvironment</key><string>Production</string>.*<key>manageAppVersionAndBuildNumber</key><false/>.*<key>testFlightInternalTestingOnly</key><true/>' "$rl/validate.record" >/dev/null &&
    ! grep -e '^options .*teamID' "$rl/validate.record" >/dev/null &&
    rl_has validate "ok    signatures: every signature of its 4 signed parts verified" && rl_has validate "validation passed" &&
    [[ -f $rl_validate_run/export/Knot.ipa && -f $rl_validate_run/export/DistributionSummary.plist && ! -e $rl_validate_run/distribution-logs ]] &&
    grep -e '<TEAM>' "$rl_validate_run/export/DistributionSummary.plist" >/dev/null && grep -e '<KEY-ID>' "$rl_validate_run/export/Packaging.log" >/dev/null &&
    rl_has upload "uploaded: Knot 0.3.0 (7), M2" && [[ -n $rl_digest && $rl_sent == "$rl_digest " && $(grep -c -e '^sent ' "$rl/upload.record") == 2 ]] &&
    rl_has upload-fail "FAIL release-upload" && rl_has upload-fail "Check App Store Connect, the app's TestFlight builds, for build 7, before any retry" &&
    rl_has upload-fail "retry:   unsafe" &&
    rl_has validate-fail "release-validation" && [[ -f $rl_validate_fail_run/validation.log ]] &&
    rl_has export-fail "release-export" && grep -e '<KEY-ID>' "$rl_export_fail_run/distribution-logs/Knot_synthetic.xcdistributionlogs/IDEDistribution.standard.log" >/dev/null &&
    rl_has tamper "release-changed" &&
    rl_has sig-export "release-export-interrupted" && rl_has sig-upload "release-upload-interrupted" &&
    rl_has sig-upload "Check App Store Connect, the app's TestFlight builds, for build 7, before any retry" && rl_has sig-upload "retry:   unsafe" &&
    rl_has sig-upload-int "release-upload-interrupted" &&
    rl_has second "release-busy" && rl_has first "dry run passed" &&
    grep -e '^xcodebuild .* -disableAutomaticPackageResolution -skipPackageUpdates .* KNOT_FLAVOUR=dev KNOT_MILESTONE_LEVEL=M2 KNOT_SIGNING=local KNOT_BUILD_NUMBER=7 DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO .* archive -archivePath ' "$rl/rehearsal.record" >/dev/null &&
    ! grep -e 'KNOT_FLAVOUR=milestone' "$rl/rehearsal.record" >/dev/null &&
    rl_has rehearsal "rehearsal passed" && rl_has rehearsal "ok    pins: the packages' checkouts stand at their pinned revisions" &&
    rl_has rehearsal "ok    roles: the app, its widgets, the Watch app and its widgets, at their paths, of com.p3ob7o.knot.dev, 0.3.0 (7), flavour dev, level M2" &&
    rl_has rehearsal-milestone "release-rehearsal-identifiers" &&
    rl_has rehearsal-unknown "LaunchServices registers none of its products (lsregister -u failed on Knot.app" &&
    rl_has rehearsal-no-checkout "The checkout of Synthetic in .build/SourcePackages is not there"; then
    pass "release.sh refuses a product that lacks any thing it checks, or whose inspection fails, naming the part, and passes the whole one; refuses before any build a level that opens sync, a milestone with no evidence, an icon with alpha, the Mac, a key missing or malformed, a stand-in in a real run and XCODE_XCCONFIG_FILE; prints and leaves no value of the key, under tracing too; checks the signatures of what it exports and sends that file once, unchanged; ends what a signal interrupts; runs one at a time; and rehearses the development flavour unsigned and offline ($(knot_duration $(($(knot_now) - rl_started))))"
else
    fail "release.sh: $rl_verdicts; broken:${rl_broken:- none}; good: $(grep -e FAIL "$rl/good.out" | head -n 3 | tr '\n' ' ')"
fi

if ((FAILED)); then
    knot_fail "self-test" "The scripts' self-test failed. Each FAIL line above says which check." \
        "Fix the script that the check names, then rerun scripts/self-test.sh." "safe" "nothing"
fi
echo "self-test: every check passed"
