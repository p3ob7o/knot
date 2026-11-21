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
plan="$scratch/plan"
mkdir -p "$plan/docs" "$plan/scripts/lib"
cp "$KNOT_ROOT/PLAN.md" "$plan/"
cp -R "$KNOT_ROOT/docs/plan" "$plan/docs/"
cp "$KNOT_SCRIPTS/check-plan.sh" "$plan/scripts/"
cp "$KNOT_SCRIPTS/lib/fail.sh" "$plan/scripts/lib/"
if KNOT_TREE="$plan" "$plan/scripts/check-plan.sh" >"$scratch/plan-ok.log" 2>&1; then
    pass "the plan check passes on the plan as it is"
else
    fail "the plan check fails on an unchanged copy of the plan: $(tail -n 3 "$scratch/plan-ok.log")"
fi
sed -i '' 's/^## Prior art$/## Prior work/' "$plan/docs/plan/WP-10.md"
status=0
KNOT_TREE="$plan" "$plan/scripts/check-plan.sh" >"$scratch/plan-bad.log" 2>&1 || status=$?
if [[ $status == 1 ]] && grep -e "WP-10.md: its '##' headings must be exactly" "$scratch/plan-bad.log" >/dev/null &&
    grep -e "^FAIL plan-check" "$scratch/plan-bad.log" >/dev/null; then
    pass "the plan check catches a brief with a missing heading"
else
    fail "the plan check missed a brief with a missing heading (status $status)"
fi

# 4. The gate's helper reads the plan as it states it.
cd "$KNOT_ROOT"
# The helper comes from the scripts' own folder; the plan it reads, from the tree.
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
assert k.classify(["docs/architecture.md", "PLAN.md"])[0] == "documents"
assert k.classify(["Packages/KnotKit/Sources/KnotSpeech/Transcriber.swift"])[0] == "leaf"
assert k.classify(["Packages/KnotKit/Sources/KnotStore/Store.swift"])[0] == "everything"
assert k.classify(["Something/New.txt"])[0] == "everything"
assert k.classify(["Packages/KnotKit/Sources/KnotStore/Store.swift"])[2] is True       # the soak
assert k.classify(["Packages/KnotKit/Sources/KnotSpeech/Transcriber.swift"])[2] is False
assert k.classify(["Apps/macOS/Sources/KnotMacApp.swift"])[3] is True                  # Mac UI tests
# The Mac UI step itself and a new Xcode pin reach the Mac UI tests (review of PR 38).
assert k.classify(["scripts/verify.sh"])[3] is True, "scripts/ reaches the Mac UI tests"
assert k.classify([".xcode-version"])[3] is True, ".xcode-version reaches the Mac UI tests"
assert k.classify(["scripts/gate-steps.txt"])[3] is True, "gate-steps.txt alone reaches the Mac UI tests"
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
# (finding 23): WP-11 plans three, and its last is held. One given to no pull request waits
# for the package's last, as before.
assert k.named_test_pr("WP-11", "WP-11 PR 2 adds one file of kill points to the soak") == "2"
assert k.named_test_pr("WP-11 PR 1", "A late draft save") == "1"
assert k.named_test_pr("WP-11", "A late draft save") is None
one = [("WP-11", False)]
assert k.named_test_required("WP-11", "1", one) and not k.named_test_required("WP-11", "2", one)
assert not k.named_test_required("WP-11", None, one)
assert k.named_test_required("WP-11", "2", one * 2) and not k.named_test_required("WP-11", None, one * 2)
assert k.named_test_required("WP-11", None, one * 3)
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
lint_fixture "$KNOT_ROOT" "$scratch/lint.out"
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

# 5b. The fixture's verdict is the same when the tree's manifests change: run again from a
#     copy whose real manifests declare every required reason, the findings must not move.
manifests="$scratch/manifests"
for manifest in Apps/iOS Apps/macOS Apps/watchOS Apps/Extensions/Widgets-iOS Apps/Extensions/Widgets-watchOS; do
    mkdir -p "$manifests/$manifest"
    python3 -I - "$KNOT_ROOT/$manifest/PrivacyInfo.xcprivacy" "$manifests/$manifest/PrivacyInfo.xcprivacy" <<'PY'
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
cp "$KNOT_ROOT/.xcode-version" "$gate_tree/"
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
if [[ $app_hang_status == 1 && "$(cat "$lim/app_hang.out")" == *"no window within 2s"*"system dialog"* && $app_hang_seconds -lt 10 &&
    -z $hang_left && $app_pass_status == 0 && $app_pass_seconds -lt 10 && -z $pass_left &&
    $app_fail_status == 1 && "$(cat "$lim/app_fail.out")" == *"exited with status 1"* ]]; then
    pass "the Mac app's start ends at its limit naming a dialog, is not slowed by a window, fails when it quits, and leaves nothing running"
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
cp "$KNOT_ROOT/Fixtures/manifest.json" "$st/Fixtures/"
cp "$KNOT_ROOT/.xcode-version" "$st/"
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
# of swift test, xcrun simctl, xcodebuild or xcb in verify.sh, sim.sh, nightly.sh, doctor.sh,
# which starts every run, lib/common.sh or bootstrap.sh is
# made without a limit helper. A copy of verify.sh with the hosted run's limit taken off,
# and one with a wrapper called bare, fail.
wiring="$scratch/wiring"
mkdir -p "$wiring"
wiring_check() { python3 -I -B "$KNOT_SCRIPTS/lib/knot_tool.py" unbounded-calls "$@" >"$wiring/out" 2>&1; }
real=0
wiring_check "$KNOT_SCRIPTS/verify.sh" "$KNOT_SCRIPTS/sim.sh" "$KNOT_SCRIPTS/nightly.sh" "$KNOT_SCRIPTS/doctor.sh" \
    "$KNOT_SCRIPTS/lib/common.sh" "$KNOT_SCRIPTS/bootstrap.sh" || real=$?
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
cp "$KNOT_ROOT/.xcode-version" "$wl/tree/"
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
cp "$KNOT_ROOT/Fixtures/manifest.json" "$ma/Fixtures/"
cp "$KNOT_ROOT/.xcode-version" "$ma/"
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
bootstrap_ok=0
grep -e 'knot_make_audio' "$KNOT_SCRIPTS/bootstrap.sh" >/dev/null &&
    ! grep -e 'generate\.sh --audio' -e 'generate.sh" --audio' "$KNOT_SCRIPTS/bootstrap.sh" >/dev/null && bootstrap_ok=1
if [[ $first == "stamped 1" && $second == 1 && $bootstrap_ok == 1 ]]; then
    pass "the audio is made in one place, stamped and spoken once, and bootstrap.sh makes it there"
else
    fail "making the audio: first call '$first', spoken after the second '$second', bootstrap through knot_make_audio: $bootstrap_ok"
fi

# The team's ID leaves the logs the scripts keep, by pattern: the lines Xcode writes on a
# Mac that knows the team, with a made-up ID. The filter keeps everything else, and the
# scrub rewrites a kept log in place.
fake_team="ZZ9QX42K7T"
team_log="$scratch/verify-apps.log"
{
    echo 'export TeamIdentifierPrefix\='"$fake_team"'. AppIdentifierPrefix\='"$fake_team"'.'
    echo '    "application-identifier" = "'"$fake_team"'.com.p3ob7o.knot.dev";'
    echo '    "com.apple.developer.team-identifier" = '"$fake_team"';'
    echo 'DEVELOPMENT_TEAM = '"$fake_team"
    echo 'keep: com.p3ob7o.knot.dev iCloud.com.p3ob7o.knot.dev Build version 27B52 KNOT_WORKTREE'
} >"$team_log"
filtered="$(knot_filter_team <"$team_log")"
knot_scrub_logs "$scratch"
if [[ $filtered != *"$fake_team"* && $filtered == *"keep: com.p3ob7o.knot.dev iCloud.com.p3ob7o.knot.dev Build version 27B52"* &&
    $(grep -c -e '<TEAM>' "$team_log") == 4 ]] && ! grep -e "$fake_team" "$team_log" >/dev/null; then
    pass "the team's ID leaves a build log, by pattern, and the rest stays"
else
    fail "the team filter left an ID or took too much: $filtered"
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
cp "$KNOT_ROOT/project.yml" "$xg/tree/"
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

if ((FAILED)); then
    knot_fail "self-test" "The scripts' self-test failed. Each FAIL line above says which check." \
        "Fix the script that the check names, then rerun scripts/self-test.sh." "safe" "nothing"
fi
echo "self-test: every check passed"
