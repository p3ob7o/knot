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
# owner, instead of hanging the run. The tool here only sleeps.
printf '#!/bin/sh\nsleep 30\n' >"$scratch/hanging-tool"
chmod +x "$scratch/hanging-tool"
started=$(knot_now)
status=0
output="$(knot_start_tool 1 "$scratch/hanging-tool" --version)" || status=$?
if [[ $status == 1 && $output == *"system dialog"* && $(($(knot_now) - started)) -lt 10 ]]; then
    pass "a tool that does not answer ends at its time limit, naming a system dialog"
else
    fail "a tool that does not answer: status $status after $(($(knot_now) - started))s: $output"
fi

if ((FAILED)); then
    knot_fail "self-test" "The scripts' self-test failed. Each FAIL line above says which check." \
        "Fix the script that the check names, then rerun scripts/self-test.sh." "safe" "nothing"
fi
echo "self-test: every check passed"
