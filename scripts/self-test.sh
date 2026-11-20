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
# stub that passes is not slowed, and a status other than zero still fails.
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
if [[ $hosted_hang_status == 124 && "$(cat "$lim/hosted_hang.out")" == *"system dialog"* && $hosted_hang_seconds -lt 6 &&
    $hosted_pass_status == 0 && $hosted_pass_seconds -lt 2 && $hosted_fail_status == 65 ]]; then
    pass "a run of hosted tests ends at its limit naming a dialog, is not slowed when it passes, and keeps its status"
else
    fail "hosted tests: hang $hosted_hang_status in ${hosted_hang_seconds}s, pass $hosted_pass_status in ${hosted_pass_seconds}s, fail $hosted_fail_status: $(cat "$lim/hosted_hang.out")"
fi
timed sim_hang knot_sim_call 1 launch set-iphone "$lim/hangs"
timed sim_pass knot_sim_call 30 launch set-iphone "$lim/passes"
timed sim_fail knot_sim_call 30 launch set-iphone "$lim/fails"
if [[ $sim_hang_status == 1 && "$(cat "$lim/sim_hang.out")" == *"set-iphone did not end within 1s"* && $sim_hang_seconds -lt 6 &&
    $sim_pass_status == 0 && $sim_pass_seconds -lt 2 &&
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
if [[ $app_hang_status == 1 && "$(cat "$lim/app_hang.out")" == *"no window within 2s"*"system dialog"* && $app_hang_seconds -lt 8 &&
    -z $hang_left && $app_pass_status == 0 && $app_pass_seconds -lt 4 && -z $pass_left &&
    $app_fail_status == 1 && "$(cat "$lim/app_fail.out")" == *"exited with status 1"* ]]; then
    pass "the Mac app's start ends at its limit naming a dialog, is not slowed by a window, fails when it quits, and leaves nothing running"
else
    fail "the app's start: hang $app_hang_status in ${app_hang_seconds}s (left: $hang_left), window $app_pass_status in ${app_pass_seconds}s (left: $pass_left), quit $app_fail_status: $(cat "$lim/app_hang.out" "$lim/app_fail.out")"
fi
pkill -KILL -f "$lim/hangs" 2>/dev/null || true

# A step that runs the package's tests has an outer limit (knot_swift_test_limited): a test
# that hangs ends at it, and the failure names the step and says nothing of a dialog; a run
# that passes is not slowed; a failing run keeps its status.
timed swift_hang env KNOT_SWIFT_TEST_LIMIT=1 bash -c 'source "$1"; knot_swift_test_limited package-test "$2"' _ \
    "$KNOT_SCRIPTS/lib/common.sh" "$lim/hangs"
timed swift_pass knot_swift_test_limited package-test "$lim/passes"
timed swift_fail knot_swift_test_limited package-test "$lim/fails"
swift_message="$(cat "$lim/swift_hang.out")"
if [[ $swift_hang_status == 124 && $swift_message == *"The step package-test did not end"* && $swift_message != *dialog* &&
    $swift_hang_seconds -lt 6 && $swift_pass_status == 0 && $swift_pass_seconds -lt 2 && $swift_fail_status == 65 ]]; then
    pass "a step of package tests ends at its limit naming the step, is not slowed when it passes, and keeps its status"
else
    fail "package tests under their limit: hang $swift_hang_status in ${swift_hang_seconds}s, pass $swift_pass_status, fail $swift_fail_status: $swift_message"
fi
# The limit outlasts a run in which every wait of a suite runs out: no test can run more
# SuiteWait waits in turn, each ten minutes, a contract's run counted as all of its waits and
# a wait of SuiteWait.limit * n as n, than fit in KNOT_SWIFT_TEST_LIMIT.
longest="$(python3 -I "$KNOT_SCRIPTS/lib/suite_waits.py" "$KNOT_ROOT/Packages/KnotKit" || true)"
if [[ $longest =~ ^[0-9]+\  ]] && ((${longest%% *} * 600 < KNOT_SWIFT_TEST_LIMIT)); then
    pass "the package tests' limit outlasts the longest run of waits in one test: ${longest%% *} of ten minutes, in ${longest#* }"
else
    fail "the package tests' limit, ${KNOT_SWIFT_TEST_LIMIT}s, does not outlast the longest run of waits in one test: ${longest:-not counted}"
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
