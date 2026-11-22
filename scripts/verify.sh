#!/bin/bash
# Builds and tests Knot (docs/architecture.md §18). One run takes one tier.
#
#   scripts/verify.sh --quick                  the check before a pull request: formatting, the
#                                              plan, the fixtures, the pins, the package build,
#                                              its tests, and the scripts' self-test
#   scripts/verify.sh --full [--skip mac-ui]   all of it: the lint, ownership, KnotCore's API,
#                                              the named tests, every app, the packaging
#                                              proofs, the launches and the Mac UI tests
#   scripts/verify.sh --gate --branch <name> [--package <ID>] [--base <ref>]
#                                              the merge gate: its depth comes from the diff;
#                                              --branch is required on a detached head
#   scripts/verify.sh --soak [--seed <n>]      the capture ledger soak (its step is WP-06's)
#   scripts/verify.sh --perf                   the timed targets, on an optimised build with
#                                              the fakes, holding every build slot
#   scripts/verify.sh --only <step>            doctor, then that one step
#   scripts/verify.sh --module <name>          doctor, then the build and the tests of one
#                                              module or test target
#   scripts/verify.sh --status-line            print the last run's status line, which fits
#                                              in a commit status (140 characters)
#   … --tree <path>                            check another tree with these scripts, as the
#                                              gate does: main's scripts on the candidate
#
# Steps: doctor, plan, links, fixtures, format, pins, lint, team-id, ownership, core-api,
# named-tests, package-build, package-test, package-test-strict, contract-two-targets,
# self-test, apps, packaging, launch, mac-ui, soak, perf, tsan, model-report.
#
# Every run starts with scripts/doctor.sh and ends with one summary line: the counts, the
# skips, the duration, the Xcode and the macOS build. A failed step names itself, its log
# and the command that reruns only that step. Heavy steps wait for a build slot
# (scripts/build-slot.sh). Logs go to .build/logs/.
#
# The gate refuses --only, --module, --skip, KNOT_LOCAL_CONFIG and an Xcode named by
# KNOT_XCODE that is not the pinned one, and it fails on a skipped step. It runs on a
# detached head, so it needs the branch, --branch, which tells a note's pull request from a
# code one; --package names the package when the branch does not. It compares with --base,
# origin/main by default. scripts/gate-steps.txt lists its steps.

# --tree <path> checks another tree with these scripts, as KNOT_TREE does. It is read
# before anything else, because every path of the run depends on it.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ ${args[i]} == --tree ]]; then export KNOT_TREE="${args[i + 1]:-}"; fi
done
source "$(dirname "$0")/lib/common.sh"

ALL_STEPS="doctor plan links fixtures format pins lint team-id ownership core-api named-tests package-build package-test
package-test-strict contract-two-targets self-test apps packaging ios-hosted launch mac-ui live-smoke two-process soak perf tsan
model-report"
QUICK_STEPS="doctor plan fixtures format pins package-build package-test contract-two-targets self-test"
FULL_STEPS="doctor plan links fixtures format pins lint team-id ownership core-api named-tests package-build package-test
package-test-strict contract-two-targets self-test apps packaging ios-hosted launch mac-ui"
# Steps that wait for a build slot, and the slot options each one needs.
slot_options() {
    case $1 in
        package-build | package-test | package-test-strict | contract-two-targets | apps | packaging | core-api | soak | tsan) echo "" ;;
        launch | ios-hosted) echo "--simulators" ;;
        mac-ui) echo "--mac-ui" ;;
        perf) echo "--all" ;;
        *) echo "none" ;;
    esac
}

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "verify-usage" "$1" "Run scripts/verify.sh --help." "safe" "nothing"; }

STATUS_FILE="$KNOT_LOGS/verify-status.txt"

# ------------------------------------------------------------------ one step, in a slot

# A heavy step runs in a second process that holds a build slot. It finds the run's
# choices in the environment.
if [[ ${1:-} == --in-step ]]; then
    IN_STEP=${2:?}
    TIER=${KNOT_VERIFY_TIER:-}
    MODULE=${KNOT_VERIFY_MODULE:-}
    TEST_TARGET=${KNOT_VERIFY_TEST_TARGET:-}
    PACKAGE=${KNOT_VERIFY_PACKAGE:-}
    BASE=${KNOT_VERIFY_BASE:-origin/main}
    SEED=${KNOT_VERIFY_SEED:-}
    knot_select_xcode
else
    IN_STEP=""
    TIER=""
    ONLY=""
    MODULE=""
    TEST_TARGET=""
    PACKAGE=""
    BRANCH=""
    BASE=""
    SEED=""
    SKIP=""
    ALLOW=()
    set_tier() {
        [[ -z $TIER ]] || usage_fail "One run takes one tier; got --$TIER and $1."
        TIER=${1#--}
    }
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick | --full | --gate | --soak | --perf) set_tier "$1"; shift ;;
            --only) ONLY=${2:-}; [[ -n $ONLY ]] || usage_fail "--only needs a step."; shift 2 ;;
            --module) MODULE=${2:-}; [[ -n $MODULE ]] || usage_fail "--module needs a module name."; shift 2 ;;
            --skip) SKIP=${2:-}; [[ $SKIP == mac-ui ]] || usage_fail "--skip takes mac-ui only."; shift 2 ;;
            --seed) SEED=${2:-}; [[ $SEED =~ ^[0-9]+$ ]] || usage_fail "--seed needs a number."; shift 2 ;;
            --package) PACKAGE=${2:-}; [[ $PACKAGE =~ ^(WP|SP)-[0-9]+$|^contract$ ]] || usage_fail "--package needs an ID such as WP-10."; shift 2 ;;
            --branch) BRANCH=${2:-}; [[ -n $BRANCH ]] || usage_fail "--branch needs a branch name."; shift 2 ;;
            --allow) [[ -n ${2:-} ]] || usage_fail "--allow needs a path."; ALLOW+=("$2"); shift 2 ;;
            --tree) [[ -n ${2:-} ]] || usage_fail "--tree needs the folder of the tree to check."; shift 2 ;;
            --base) BASE=${2:-}; [[ -n $BASE ]] || usage_fail "--base needs a ref."; shift 2 ;;
            --status-line)
                [[ -f $STATUS_FILE ]] || knot_fail "verify-no-status" "No run has written $STATUS_FILE yet." \
                    "Run a tier first." "safe" "nothing"
                cat "$STATUS_FILE"
                exit 0 ;;
            -h | --help) usage; exit 0 ;;
            *) usage_fail "Unknown argument: $1" ;;
        esac
    done
    # A gate that is refused before it runs must not leave an earlier run's line behind:
    # --status-line prints the file, and the line names no commit.
    if [[ $TIER == gate ]]; then rm -f "$STATUS_FILE"; fi
    if [[ -n $ONLY || -n $MODULE ]]; then
        [[ -z $TIER ]] || usage_fail "--only and --module run one part. They take no tier."
        [[ -z $ONLY || -z $MODULE ]] || usage_fail "Use --only or --module, not both."
    fi
    [[ -n $TIER || -n $ONLY || -n $MODULE ]] || usage_fail "Name a tier, --only <step> or --module <name>."
    [[ -z $SKIP || $TIER == full ]] || usage_fail "--skip mac-ui belongs to --full. The gate refuses it."
    [[ -z $SEED || $TIER == soak ]] || usage_fail "--seed belongs to --soak."
    # The steps that read the package and the branch take them alone too, as the gate runs
    # them.
    [[ -z $PACKAGE$BRANCH || $TIER == gate || $TIER == full || " ownership named-tests core-api " == *" $ONLY "* ]] ||
        usage_fail "--package and --branch belong to --gate, --full, and --only ownership, named-tests or core-api."
    ((${#ALLOW[@]} == 0)) || [[ $TIER == gate || $ONLY == ownership ]] ||
        usage_fail "--allow belongs to --gate and --only ownership: the orchestrator allows a path by hand there."
    BASE=${BASE:-origin/main}
fi

# ------------------------------------------------------------------ helpers

xcb() {
    # xcb <log> <xcodebuild arguments…>
    local log=$1
    shift
    knot_xcodebuild_settings
    # Xcode writes the team's prefix into the log of every app build on a Mac that knows the
    # team, so the log is filtered as it is written (knot_filter_team). xcodebuild's own
    # output goes to the log; the shell's standard error, where bash reports an xcodebuild
    # that a signal ended with this script's path, goes nowhere: the step names the signal
    # itself (ended_by_signal).
    { xcodebuild -project "$KNOT_PROJECT" "${KNOT_XCODEBUILD[@]}" "$@" 2>&1 | knot_filter_team >>"$log"; } 2>/dev/null # limit: xcb
}

tool() { python3 -I "$KNOT_SCRIPTS/lib/knot_tool.py" "$@"; }

# Swift Testing's event stream, which every step that runs Swift Testing writes and reads:
# `--event-stream-output-path` with `--event-stream-version 0`, an option of `swift test`
# that its --help does not list (docs/dev-setup.md). The console can print a cancelled case
# of a test with arguments as passed, and an event whose reason or name holds a newline over
# two lines; the stream says what ran.
#   event_flags <stream>         sets EVENT_FLAGS for swift test, and removes an old stream
#   check_events <stream>        prints what did not run, and fails on a missing or
#                                incomplete stream, and at the gate on a test or case that
#                                did not run (knot_tool.py test-events)
event_flags() {
    rm -f "$1"
    EVENT_FLAGS=(--event-stream-output-path "$1" --event-stream-version 0)
}
check_events() {
    if [[ $TIER == gate ]]; then tool test-events "$1" --gate; else tool test-events "$1"; fi
}

products() { printf '%s/Build/Products/%s' "$KNOT_DERIVED" "$1"; }

# xcodebuild's own test limits, for every run of tests in a simulator or on the desktop: a
# case that hangs fails after its allowance, three minutes and five at most.
KNOT_TEST_LIMIT_FLAGS=(-test-timeouts-enabled YES -default-test-execution-time-allowance 180
    -maximum-test-execution-time-allowance 300)

# ended_by_signal <what> <status> <limit variable>: when an xcodebuild run ended by a signal
# that the step's limit did not send, a status above 128 with no limit hit, it says so, with
# the signal's number and name, and returns 0, so that the step fails on it at once and does
# not judge the run as one with no tests. Something outside the step sent it.
ended_by_signal() {
    local what=$1 status=$2 limit=$3
    ((status > 128 && KNOT_LIMIT_HIT == 0)) || return 1
    echo "$what: xcodebuild ended by signal $((status - 128)) ($(kill -l $((status - 128)) 2>/dev/null || echo unknown)), which this step's limit ($limit) did not send: a process outside the step ended the run, so it says nothing of the tests."
}

# report_skips <what> <log>: the skipped or cancelled tests of a test log that is not the
# step's own, as XCTest's and the hosted run's are (knot_skipped_tests, which reads XCTest's
# "Test Case '…' skipped" too). It prints their lines once, as they are, so that the summary,
# which reads the step's log, counts them; and at the gate it fails, since the gate requires
# every test to run, as it does for the package's tests.
report_skips() {
    local skipped
    skipped="$(knot_skipped_tests "$2")"
    [[ -n $skipped ]] || return 0
    echo "$1: skipped or cancelled:"
    printf '%s\n' "$skipped"
    if [[ $TIER == gate ]]; then
        echo "$1: the gate requires every test to run."
        return 1
    fi
}

# ui_tests <what> <log> [destination name…] -- <xcodebuild arguments…>
# Runs one UI test bundle, which the arguments name with -only-testing. xcodebuild's own test
# limits are on, so a case that hangs fails after its allowance, and an outer limit round the
# whole call (KNOT_UI_TEST_LIMIT, 20 minutes) ends a run that a system dialog holds. The
# results are read first: a run that executed no test, a failed case, or a destination with
# no pass fails (knot_xctest_result), and the step's log then gives the failed cases' error
# lines and names the long log (knot_xctest_failures). Then xcodebuild's own status: a run
# whose cases passed and that still exited with an error fails too.
ui_tests() {
    local what=$1 log=$2 limit=${KNOT_UI_TEST_LIMIT:-1200} status=0
    local destinations=()
    shift 2
    while [[ $1 != -- ]]; do
        destinations+=("$1")
        shift
    done
    shift
    knot_run_limited "$what" "$limit" xcb "$log" "$@" "${KNOT_TEST_LIMIT_FLAGS[@]}" test || status=$?
    ((KNOT_LIMIT_HIT == 0)) || return 1
    ! ended_by_signal "$what" "$status" KNOT_UI_TEST_LIMIT || return 1
    if ! knot_xctest_result "$log" ${destinations[@]+"${destinations[@]}"}; then
        # The reason is in the long log; the step's own log, which a failure shows, gives it.
        knot_xctest_failures "$log"
        return 1
    fi
    report_skips "$what" "$log" || return 1
    if ((status != 0)); then
        echo "$what: xcodebuild exited with $status after the cases above. Its log is $log."
        return 1
    fi
}

check() {
    # check <what> <command…>: one line of a proof.
    local what=$1
    shift
    if "$@"; then
        printf 'ok    %s\n' "$what"
    else
        printf 'FAIL  %s\n' "$what"
        return 1
    fi
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# Prints every Mach-O file under a folder, each ended by a NUL, so that a path with a
# space survives. Read it with: while IFS= read -r -d '' f; do …; done < <(macho_files …)
macho_files() {
    local f
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -e Mach-O >/dev/null; then printf '%s\0' "$f"; fi
    done < <(find "$1" -type f -print0)
}

# The main executable of an app bundle, from its Info.plist.
main_executable() {
    if [[ -f $1/Contents/Info.plist ]]; then
        printf '%s/Contents/MacOS/%s' "$1" "$(plist_value "$1/Contents/Info.plist" CFBundleExecutable)"
    else
        printf '%s/%s' "$1" "$(plist_value "$1/Info.plist" CFBundleExecutable)"
    fi
}

# The state of a step in scripts/gate-steps.txt: required, pending, or nothing.
gate_state() { awk -F'\t' -v s="$1" '$1 == s { print $2 " " $3; exit }' "$KNOT_SCRIPTS/gate-steps.txt"; }

# ------------------------------------------------------------------ steps

step_doctor() {
    local options=(--tier "${TIER:-quick}")
    [[ ${RUN_MAC_UI:-0} == 1 ]] && options+=(--mac-ui)
    [[ $TIER == gate ]] && options+=(--models)
    "$KNOT_SCRIPTS/doctor.sh" "${options[@]}"
}

step_plan() { "$KNOT_SCRIPTS/check-plan.sh"; }

step_links() { tool links; }

# The synthetic fixtures match a fresh run, and the generated audio has its format and
# length (Fixtures/README.md).
# The fixtures. When this tree lacks its generated audio, as a fresh checkout and the hosted
# runner do, or the audio is stale (knot_tool.py fixtures-audio), the step speaks it first
# with the generator as it is, so that the package tests that read Fixtures/generated/audio/
# find it here as they would on a Mac that made it. Two runs in one tree must not speak at
# once, since the generator writes the clips in place: the decision and the speaking hold a
# lock in the tree's .build/, and a second run waits for it and then finds the audio made.
step_fixtures() {
    knot_make_audio
    "$KNOT_ROOT/Fixtures/tools/generate.sh" --check
}

# Speaks this tree's audio when it lacks it, and stamps it. step_fixtures runs it holding
# the audio's lock; it is no step of its own.
step_fixtures_audio() {
    local why
    if ! why="$(cd "$KNOT_ROOT" && tool fixtures-audio)"; then
        echo "fixtures: $why. Speaking this tree's audio first: Fixtures/tools/generate.sh --audio"
        "$KNOT_ROOT/Fixtures/tools/generate.sh" --audio
        (cd "$KNOT_ROOT" && tool fixtures-audio --write-stamp)
    else
        echo "fixtures: $why"
    fi
}

step_format() {
    (cd "$KNOT_ROOT" && xcrun swift-format lint --strict --recursive --parallel \
        Packages/KnotKit/Package.swift Packages/KnotKit/Sources Packages/KnotKit/Tests Apps scripts/lib/windows.swift \
        scripts/lib/models.swift)
}

# The lint, and the tree's workflows: the nightly one makes the audio before the package
# tests under Thread Sanitizer (knot_tool.py workflows). The workflow is read here, on the
# tree, since the self-test reads its own checkout; the lint runs at every depth of the gate.
step_lint() {
    local status=0
    (cd "$KNOT_ROOT" && tool lint) || status=$?
    (cd "$KNOT_ROOT" && tool workflows) || status=1
    return "$status"
}

# The signing team's ID in no tracked file. Without the owner's local configuration on this
# Mac there is no ID to look for: the step then exits 3 and counts as skipped, never as
# passed, and the gate fails on a skipped step.
#
# KNOT_TEAM_CONFIG names the configuration for this check alone. Unlike KNOT_LOCAL_CONFIG it
# links nothing into the tree, so the run builds what every other run builds. The gate
# takes the configuration this way.
step_team_id() {
    local config="${KNOT_TEAM_CONFIG:-${KNOT_LOCAL_CONFIG:-}}"
    [[ -n $config ]] || config="$KNOT_CONFIG/Local.xcconfig"
    (cd "$KNOT_ROOT" && tool team-id --team-config "$config")
}

step_ownership() {
    if [[ -z $PACKAGE ]]; then
        echo "ownership: no package to check: this is not a package's branch, and no --package or --branch named one."
        return "$SKIPPED_CODE"
    fi
    local allow=() path
    for path in ${ALLOW[@]+"${ALLOW[@]}"}; do allow+=(--allow "$path"); done
    (cd "$KNOT_ROOT" && tool ownership --package "$PACKAGE" --base "$BASE" ${allow[@]+"${allow[@]}"})
}

# The pull request under test counts as merged, so a package's last pull request is held
# to its named tests at its own gate.
step_named_tests() {
    local options=()
    [[ -n $PACKAGE ]] && options+=(--package "$PACKAGE")
    [[ -n $BRANCH ]] && options+=(--branch "$BRANCH")
    (cd "$KNOT_ROOT" && tool named-tests ${options[@]+"${options[@]}"})
}

# KnotCore's public API must equal the base's (docs/architecture.md §3), except on a contract
# branch, and on WP-02's branches until WP-02's last pull request has merged. It compares the public symbols and relationships of the two
# symbol graphs. The base's is kept in .build/core-api/, by commit.
core_api_digest() {
    # core_api_digest <package folder> <scratch folder> <output file>
    swift package --package-path "$1" --scratch-path "$2" dump-symbol-graph --minimum-access-level public >/dev/null
    python3 -I - "$2/out/symbolgraph/KnotCore.symbols.json" >"$3" <<'PY'
import json, sys
graph = json.load(open(sys.argv[1]))
names = {s["identifier"]["precise"]: ".".join(s["pathComponents"]) for s in graph["symbols"]}
for s in graph["symbols"]:
    print("symbol", s["kind"]["identifier"], ".".join(s["pathComponents"]),
          "".join(f["spelling"] for f in s.get("declarationFragments", [])))
for r in graph.get("relationships", []):
    print("relationship", r["kind"], names.get(r["source"], r["source"]), names.get(r["target"], r.get("targetFallback", r["target"])))
PY
    sort -o "$3" "$3"
}
step_core_api() {
    # A contract branch, and WP-02 until its last pull request has merged, may change the
    # API; scripts/lib/knot_tool.py decides, and says why.
    if (cd "$KNOT_ROOT" && tool core-api-rule --package "$PACKAGE"); then
        return 0
    fi
    local base changed
    base="$(git -C "$KNOT_ROOT" merge-base "$BASE" HEAD)"
    changed="$(git -C "$KNOT_ROOT" diff --name-only "$base" -- Packages/KnotKit/Sources/KnotCore/)"
    changed="$changed$(git -C "$KNOT_ROOT" ls-files --others --exclude-standard -- Packages/KnotKit/Sources/KnotCore/)"
    if [[ -z $changed ]]; then
        echo "core-api: KnotCore is unchanged from $BASE"
        return 0
    fi
    local cache="$KNOT_BUILD/core-api" here
    mkdir -p "$cache"
    if [[ ! -s $cache/$base.txt ]]; then
        local tree
        tree="$(mktemp -d "$KNOT_BUILD/core-api/base.XXXXXX")"
        git -C "$KNOT_ROOT" worktree add --detach --quiet "$tree" "$base"
        core_api_digest "$tree/Packages/KnotKit" "$tree/.build/swiftpm" "$cache/$base.txt" || {
            git -C "$KNOT_ROOT" worktree remove --force "$tree"
            return 1
        }
        git -C "$KNOT_ROOT" worktree remove --force "$tree"
    fi
    here="$cache/head.txt"
    core_api_digest "$KNOT_PACKAGE" "$KNOT_SWIFTPM" "$here"
    if diff -u "$cache/$base.txt" "$here"; then
        echo "core-api: KnotCore's public API equals $BASE's"
    else
        echo "core-api: KnotCore's public API differs from $BASE's. A change to it goes in a contract/ branch (PLAN.md §8.5)."
        return 1
    fi
}

# GRDB is pinned by version and by revision, for SwiftPM and for Xcode, because the
# generated project's lock file is not committed (docs/architecture.md §18). Knot has no
# other dependency. SwiftPM's pins are in the committed Package.resolved. Xcode writes no
# lock file for a dependency that comes through a local package, so its pins are read from
# the checkout state it records in this worktree's .build/SourcePackages.
check_resolved() {
    local file=$1 version=$2 revision=$3
    python3 -I - "$file" "$version" "$revision" <<'PY'
import json, sys
path, version, revision = sys.argv[1:]
data = json.load(open(path))
if "pins" in data:
    pins = [(p["identity"], p["state"]) for p in data["pins"]]
else:
    pins = [(d["packageRef"]["identity"], d["state"].get("checkoutState", {})) for d in data["object"]["dependencies"]]
names = sorted(name for name, _ in pins)
if names != ["grdb.swift"]:
    sys.exit(f"{path}: pins {names}, but Knot has one dependency, GRDB")
state = pins[0][1]
if state.get("version") != version or state.get("revision") != revision:
    sys.exit(f"{path}: GRDB is {state.get('version')} at {state.get('revision')}, not {version} at {revision}")
print(f"ok    {path}: GRDB {version} at {revision}")
PY
}
step_pins() {
    local manifest="$KNOT_PACKAGE/Package.swift" version revision
    version="$(sed -n -E 's/^let grdbVersion: Version = "([^"]+)"/\1/p' "$manifest")"
    revision="$(sed -n -E 's/^let grdbRevision = "([0-9a-f]{40})"/\1/p' "$manifest")"
    [[ -n $version && -n $revision ]] || {
        echo "Package.swift does not state grdbVersion and grdbRevision."
        return 1
    }
    echo "SwiftPM"
    knot_swiftpm_flags
    swift package "${KNOT_SWIFTPM_FLAGS[@]}" resolve
    check_resolved "$KNOT_PACKAGE/Package.resolved" "$version" "$revision"
    echo "Xcode"
    knot_generate_project
    knot_run_limited "Resolving the packages for Xcode" "$KNOT_BUILD_LIMIT" \
        xcb /dev/stdout -scheme Knot-iOS -resolvePackageDependencies
    check_resolved "$KNOT_SOURCE_PACKAGES/workspace-state.json" "$version" "$revision"
}

step_package_build() {
    knot_swiftpm_flags
    swift build "${KNOT_SWIFTPM_FLAGS[@]}" --build-tests --explicit-target-dependency-import-check error
}

step_package_test() {
    knot_swiftpm_flags
    local filter=() output="$KNOT_LOGS/verify-package-test.out" stream="$KNOT_LOGS/verify-package-test-events.jsonl"
    if [[ -n $MODULE ]]; then
        # The Swift module of a test target turns "-" into "_": knot-evalTests is
        # knot_evalTests.
        filter=(--filter "^${TEST_TARGET//-/_}\.")
    fi
    event_flags "$stream"
    package_tests() {
        swift test "${KNOT_SWIFTPM_FLAGS[@]}" --explicit-target-dependency-import-check error \
            "${EVENT_FLAGS[@]}" ${filter[@]+"${filter[@]}"} 2>&1 | tee "$output" # limit: package_tests
    }
    knot_swift_test_limited package-test package_tests
    # A run that matched no test is a failure, not a pass.
    if ! grep -E 'Test run with [1-9][0-9]* tests?' "$output" >/dev/null; then
        echo "No test ran${MODULE:+ for $TEST_TARGET}."
        return 1
    fi
    # The stream says what ran: a run whose stream is missing or did not end fails, and at
    # the gate a test or case that did not run fails it, whatever the console printed. The
    # console's own reading below stays as a second one.
    check_events "$stream" || return 1
    # The gate requires the on-device models, so a test skipped because a model is missing,
    # or cancelled at run time, fails it (docs/architecture.md §17).
    if [[ $TIER == gate && -n "$(knot_skipped_tests "$output")" ]]; then
        # Indented, so that the summary, which reads this step's log, counts each test once.
        echo "The gate requires every test to run. Skipped or cancelled:"
        knot_skipped_tests "$output" | sed 's/^/    /'
        return 1
    fi
}

# The package's tests once more, with Swift's cooperative pool held strict
# (LIBDISPATCH_COOPERATIVE_POOL_STRICT=1): one thread for each priority, so that a test whose
# wait blocks a pool thread while the work that would end it needs a thread of the same
# priority hangs here, as it does on the three-core hosted runner, where three such waits
# take every thread (docs/dev-setup.md). It builds the tests without the variable, which
# package-build has done already, and runs them under it, with a limit of its own
# (KNOT_STRICT_TEST_LIMIT, 30 minutes). At the limit, or on a failure, it names the tests
# that had started and not ended, and those that failed. Not in --quick, and not on the
# hosted runner, which is the other proof.
step_package_test_strict() {
    knot_swiftpm_flags
    local output="$KNOT_LOGS/verify-package-test-strict.out" limit=${KNOT_STRICT_TEST_LIMIT:-1800} status=0
    local stream="$KNOT_LOGS/verify-package-test-strict-events.jsonl"
    local filter=()
    if [[ -n $MODULE ]]; then
        filter=(--filter "^${TEST_TARGET//-/_}\.")
    fi
    : >"$output"
    event_flags "$stream"
    strict_build() {
        swift build "${KNOT_SWIFTPM_FLAGS[@]}" --build-tests --explicit-target-dependency-import-check error # limit: strict_build
    }
    strict_tests() {
        env LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test "${KNOT_SWIFTPM_FLAGS[@]}" --skip-build \
            "${EVENT_FLAGS[@]}" ${filter[@]+"${filter[@]}"} >"$output" 2>&1 # limit: strict_tests
    }
    knot_run_limited "The package build" "$KNOT_BUILD_LIMIT" strict_build || return 1
    knot_limit "$limit" strict_tests || status=$?
    cat "$output"
    local unended
    unended="$(tool unended-tests "$output")"
    if ((KNOT_LIMIT_HIT)); then
        echo "The package's tests under the strict pool did not end within $(knot_duration "$limit") (KNOT_STRICT_TEST_LIMIT)."
        echo "A test may be blocking a thread of the cooperative pool while the work that would end its wait needs a thread of the same priority. These had started and not ended:"
        printf '%s\n' "${unended:-    none that Swift Testing printed}" | sed 's/^/    /'
        return 1
    fi
    if ((status != 0)); then
        echo "The package's tests failed under the strict pool. A test that fails here and passes in package-test may be blocking a thread of the cooperative pool:"
        printf '%s\n' "${unended:-    none that Swift Testing named}" | sed 's/^/    /'
        return 1
    fi
    if ! grep -E 'Test run with [1-9][0-9]* tests?' "$output" >/dev/null; then
        echo "No test ran${MODULE:+ for $TEST_TARGET} under the strict pool."
        return 1
    fi
    check_events "$stream" || return 1
    if [[ $TIER == gate && -n "$(knot_skipped_tests "$output")" ]]; then
        echo "The gate requires every test to run. Skipped or cancelled under the strict pool:"
        knot_skipped_tests "$output" | sed 's/^/    /'
        return 1
    fi
}

# The named test contract-suite-dummy-port-two-test-targets: one contract suite in
# KnotTestSupport, run from two test targets.
step_contract_two_targets() {
    knot_swiftpm_flags
    local output="$KNOT_LOGS/verify-contract-run.out" suite=contractSuiteDummyPortTwoTestTargets
    # Run the suite from each test target on its own, and count a target only when its run
    # passed exactly that test. The listing and every run share one limit, whose message goes
    # to the step's log, not to a target's output.
    contract_runs() {
        local targets target ran=0
        targets="$(swift test "${KNOT_SWIFTPM_FLAGS[@]}" list 2>/dev/null | grep -e "$suite" | cut -d. -f1 | sort -u)" # limit: contract_runs
        for target in $targets; do
            event_flags "$KNOT_LOGS/verify-contract-run-$target-events.jsonl"
            swift test "${KNOT_SWIFTPM_FLAGS[@]}" "${EVENT_FLAGS[@]}" --filter "^$target\.$suite" >"$output" 2>&1 || { # limit: contract_runs
                echo "FAIL  the dummy contract suite failed in $target"
                continue
            }
            if ! check_events "$KNOT_LOGS/verify-contract-run-$target-events.jsonl"; then
                echo "FAIL  the dummy contract suite's run in $target did not run every test"
            elif grep -E 'Test run with 1 test .*passed' "$output" >/dev/null; then
                echo "ok    the dummy contract suite ran and passed in $target"
                ran=$((ran + 1))
            else
                echo "FAIL  the dummy contract suite did not run in $target"
            fi
        done
        echo "$ran test targets ran the dummy contract suite (two needed)"
        ((ran >= 2))
    }
    knot_swift_test_limited contract-two-targets contract_runs
}

# The named test scripts-self-test.
# The scripts' self-test. Its output goes to a file that the step then prints, so that a
# process one of its checks leaves behind can hold no pipe of the run open, and it has a
# limit (KNOT_SELF_TEST_LIMIT, 10 minutes; it takes under a minute), so that a check that
# hangs fails the step with its log instead of holding the run.
step_self_test() {
    local output="$KNOT_LOGS/verify-self-test.out" limit=${KNOT_SELF_TEST_LIMIT:-600} status=0
    knot_limit "$limit" "$KNOT_SCRIPTS/self-test.sh" >"$output" 2>&1 || status=$?
    cat "$output"
    if ((KNOT_LIMIT_HIT)); then
        echo "self-test: did not end within $(knot_duration "$limit"); the check after the last line above hangs."
        return 1
    fi
    return "$status"
}

# Every app, Debug: the iOS app with the Watch app and both widget extensions in it, and
# the Mac app with the `knot` tool in it.
step_apps() {
    local log="$KNOT_LOGS/verify-apps.log"
    : >"$log"
    knot_generate_project
    echo "Knot-iOS, Debug, iOS Simulator"
    knot_run_limited "The Debug build of Knot-iOS" "$KNOT_BUILD_LIMIT" \
        xcb "$log" -scheme Knot-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' build
    echo "Knot-macOS, Debug"
    knot_run_limited "The Debug build of Knot-macOS" "$KNOT_BUILD_LIMIT" \
        xcb "$log" -scheme Knot-macOS -configuration Debug -destination 'platform=macOS' build
}

# The packaging that otherwise fails late, each proven with one trivial instance
# (docs/plan/WP-01.md).
step_packaging() {
    step_apps
    local log="$KNOT_LOGS/verify-packaging-release.log"
    : >"$log"
    echo "Knot-iOS and Knot-macOS, Release"
    knot_run_limited "The Release build of Knot-iOS" "$KNOT_BUILD_LIMIT" \
        xcb "$log" -scheme Knot-iOS -configuration Release -destination 'generic/platform=iOS Simulator' build
    knot_run_limited "The Release build of Knot-macOS" "$KNOT_BUILD_LIMIT" \
        xcb "$log" -scheme Knot-macOS -configuration Release -destination 'platform=macOS' build

    local ios mac failed=0
    ios="$(products Debug-iphonesimulator)/Knot.app"
    mac="$(products Debug)/Knot.app"

    # WP-19's text intents, declared in KnotIntents, reach the metadata of the iOS app and of
    # its widget extension. The App Shortcuts, which Apps/Shared/KnotShortcuts.swift provides,
    # reach the iOS app's and the Mac app's: a provider in the package reaches neither.
    intent_in() { tool app-intents --metadata "$1/Metadata.appintents/extract.actionsdata" --action CreateNoteIntent; }
    shortcuts_in() { tool app-intents --metadata "$1/Metadata.appintents/extract.actionsdata" --shortcuts; }
    check "CreateNoteIntent, declared in KnotIntents, in the iOS app's metadata" intent_in "$ios" || failed=1
    check "the same intent in the widget extension's metadata" intent_in "$ios/PlugIns/Widgets-iOS.appex" || failed=1
    check "the iOS app's App Shortcuts are not empty" shortcuts_in "$ios" || failed=1
    check "the Mac app's App Shortcuts are not empty" shortcuts_in "$mac/Contents/Resources" || failed=1

    activity_in() {
        local f
        while IFS= read -r -d '' f; do
            nm "$f" 2>/dev/null | xcrun swift-demangle |
                grep -e "KnotIntents.KnotPlaceholderActivityAttributes" >/dev/null && return 0
        done < <(macho_files "$1")
        return 1
    }
    check "Live Activity attributes type in the widget extension" activity_in "$ios/PlugIns/Widgets-iOS.appex" || failed=1
    check "the iOS app supports Live Activities" \
        test "$(plist_value "$ios/Info.plist" NSSupportsLiveActivities)" = true || failed=1

    watch_embedded() {
        local watch
        watch="$(find "$ios/Watch" -maxdepth 1 -name '*.app' | head -n 1)"
        [[ -n $watch ]] &&
            [[ "$(plist_value "$watch/Info.plist" WKCompanionAppBundleIdentifier)" == "$(plist_value "$ios/Info.plist" CFBundleIdentifier)" ]] &&
            [[ -d $watch/PlugIns/Widgets-watchOS.appex ]]
    }
    check "Watch app, with its widget extension, embedded in the iPhone app" watch_embedded || failed=1

    tool_embedded() {
        local tool="$mac/Contents/MacOS/knot-dev" version
        version="$(plist_value "$mac/Contents/Info.plist" CFBundleShortVersionString)"
        [[ -x $tool ]] &&
            codesign --verify --strict --deep "$mac" &&
            codesign -d --entitlements - "$tool" 2>/dev/null | grep -e com.apple.security.app-sandbox >/dev/null &&
            [[ "$(knot_start_tool "${KNOT_TOOL_START_LIMIT:-30}" "$tool" --version)" == "knot-dev $version (dev)" ]]
    }
    check "knot-dev embedded and signed in the Mac app, with its own sandbox, and runs" tool_embedded || failed=1

    check "a contract suite in KnotTestSupport run from two test targets" step_contract_two_targets || failed=1

    # Scans every Mach-O file of an app bundle, its main executable included, for fakes:
    # the KnotFakes module, and any type of a Knot module named Fake…, such as a fake
    # transport inside KnotLink (knot_fakes_in). It fails when it scanned nothing, so it
    # cannot pass by finding no file. `want` is "none" for a release build and "some" for
    # the debug control.
    scan_for_fakes() {
        local app=$1 want=$2 f main scanned=0 main_seen=0 found=0 held
        main="$(main_executable "$app")"
        while IFS= read -r -d '' f; do
            scanned=$((scanned + 1))
            [[ $f == "$main" ]] && main_seen=1
            if held="$(knot_fakes_in "$f")"; then
                echo "      fakes in $f: $(tr '\n' ' ' <<<"$held" | cut -c1-200)"
                found=$((found + 1))
            fi
        done < <(macho_files "$app")
        echo "      scanned $scanned Mach-O files in $app, main executable $( ((main_seen)) && echo included || echo MISSING)"
        ((scanned > 0 && main_seen)) || return 1
        if [[ $want == none ]]; then ((found == 0)); else ((found > 0)); fi
    }
    check "Release Mac app free of KnotFakes" scan_for_fakes "$(products Release)/Knot.app" none || failed=1
    check "Release iOS app, its extension and the Watch app free of KnotFakes" \
        scan_for_fakes "$(products Release-iphonesimulator)/Knot.app" none || failed=1
    check "the Debug iOS app does hold KnotFakes, so the check can see it" scan_for_fakes "$ios" some || failed=1
    ((failed == 0))
}

# The tests hosted in the iOS app, in the worktree's iPhone simulator: the contract suites
# that can run only there (docs/architecture.md §5). It holds a simulator slot. Like the UI
# tests, the run has xcodebuild's own test limits and an outer limit round the whole call
# (KNOT_HOSTED_TEST_LIMIT, 20 minutes), whose failure says that a system dialog may be
# holding it. The results are read first, then xcodebuild's status.
step_ios_hosted() {
    local log="$KNOT_LOGS/verify-ios-hosted-tests.log" iphone limit=${KNOT_HOSTED_TEST_LIMIT:-1200} status=0
    : >"$log"
    "$KNOT_SCRIPTS/sim.sh" ensure
    iphone="$("$KNOT_SCRIPTS/sim.sh" udid iphone)"
    trap '"$KNOT_SCRIPTS/sim.sh" shutdown' EXIT
    knot_generate_project
    knot_run_limited "The hosted iOS tests" "$limit" xcb "$log" -scheme Knot-iOS -configuration Debug \
        -destination "id=$iphone" -only-testing:Knot-iOS-Tests "${KNOT_TEST_LIMIT_FLAGS[@]}" test || status=$?
    ((KNOT_LIMIT_HIT == 0)) || return 1
    ! ended_by_signal "The hosted iOS tests" "$status" KNOT_HOSTED_TEST_LIMIT || return 1
    grep -E 'Test run with [0-9]+ tests?|passed after|failed after' "$log" | tail -n 5 || true
    grep -E 'Test run with [1-9][0-9]* tests? .*passed' "$log" >/dev/null || {
        echo "No hosted test ran."
        return 1
    }
    report_skips "The hosted iOS tests" "$log" || return 1
    if ((status != 0)); then
        echo "The hosted iOS tests: xcodebuild exited with $status after the tests above. Its log is $log."
        return 1
    fi
}

# The three apps launch and show the placeholder: the UI tests on the iPhone, the iPad and
# the Watch simulators, a screenshot of each, and the Mac app's window. It holds a
# simulator slot, which limits how many sets are booted at once.
step_launch() {
    local log="$KNOT_LOGS/verify-launch-tests.log" watch_log="$KNOT_LOGS/verify-launch-watch-tests.log" iphone ipad watch
    : >"$log"
    : >"$watch_log"
    "$KNOT_SCRIPTS/sim.sh" ensure
    iphone="$("$KNOT_SCRIPTS/sim.sh" udid iphone)"
    ipad="$("$KNOT_SCRIPTS/sim.sh" udid ipad)"
    watch="$("$KNOT_SCRIPTS/sim.sh" udid watch)"
    # Shut the set down whatever happens, so that a failed run leaves nothing booted.
    trap '"$KNOT_SCRIPTS/sim.sh" shutdown' EXIT
    knot_generate_project
    # The UI tests must run and pass: on both iOS simulators, and on the Watch. A run that
    # executed no test fails (knot_xctest_result).
    local iphone_name ipad_name
    iphone_name="$("$KNOT_SCRIPTS/sim.sh" list | awk '$1 == "iphone" { print $2 }')"
    ipad_name="$("$KNOT_SCRIPTS/sim.sh" list | awk '$1 == "ipad" { print $2 }')"
    echo "UI tests on $iphone_name and $ipad_name"
    ui_tests "The iOS UI tests" "$log" "$iphone_name" "$ipad_name" -- \
        -scheme Knot-iOS -configuration Debug -destination "id=$iphone" -destination "id=$ipad" \
        -only-testing:Knot-iOS-UITests
    echo "UI tests on the Watch"
    ui_tests "The Watch UI tests" "$watch_log" -- \
        -scheme Knot-watchOS -configuration Debug -destination "id=$watch" -only-testing:Knot-watchOS-UITests

    # Each simctl call has a time limit (knot_sim_call), so a simulator that never finishes
    # booting, or a start that a dialog holds, fails the step and names the simulator.
    local ios bundle role udid name
    ios="$(products Debug-iphonesimulator)/Knot.app"
    bundle="$(plist_value "$ios/Info.plist" CFBundleIdentifier)"
    for role in iphone ipad watch; do
        udid="$("$KNOT_SCRIPTS/sim.sh" udid $role)"
        name="$("$KNOT_SCRIPTS/sim.sh" list | awk -v role=$role '$1 == role { print $2 }')"
        knot_sim_call 300 "bootstatus" "$name" xcrun simctl bootstatus "$udid" -b >/dev/null
        if [[ $role == watch ]]; then
            knot_sim_call 120 "install" "$name" \
                xcrun simctl install "$udid" "$(find "$ios/Watch" -maxdepth 1 -name '*.app' | head -n 1)"
            knot_sim_call 60 "launch" "$name" xcrun simctl launch "$udid" "$bundle.watchkitapp" >/dev/null
        else
            knot_sim_call 120 "install" "$name" xcrun simctl install "$udid" "$ios"
            knot_sim_call 60 "launch" "$name" xcrun simctl launch "$udid" "$bundle" >/dev/null
        fi
        sleep 4
        knot_sim_call 30 "screenshot" "$name" xcrun simctl io "$udid" screenshot "$KNOT_LOGS/launch-$role.png" >/dev/null
        echo "screenshot: $KNOT_LOGS/launch-$role.png"
    done

    # The Mac app puts a window on screen within KNOT_APP_START_LIMIT seconds, 60: the first
    # probe compiles its script, which a loaded Mac makes slow. The probe reads only what
    # needs no Screen Recording permission; the Mac UI tests are the mac-ui step. Afterwards
    # neither the app nor anything it started may be left running.
    local mac status=0
    mac="$(products Debug)/Knot.app"
    knot_start_app "${KNOT_APP_START_LIMIT:-60}" "$mac/Contents/MacOS/Knot" \
        xcrun swift "$KNOT_SCRIPTS/lib/windows.swift" || status=$?
    end_mac_test_hosts
    if [[ -n "$(mac_test_hosts)" ]]; then
        echo "The Mac app, or something it started, was still running after it was ended: $(mac_test_hosts | tr '\n' ' ')"
        return 1
    fi
    return "$status"
}

# The Mac UI tests. They take over the desktop, so they hold the one exclusive Mac UI slot,
# and they need Automation Mode, which doctor checks first.
step_mac_ui() {
    local log="$KNOT_LOGS/verify-mac-ui-tests.log" status=0
    : >"$log"
    knot_generate_project
    ui_tests "The Mac UI tests" "$log" -- \
        -scheme Knot-macOS -configuration Debug -destination 'platform=macOS' -only-testing:Knot-macOS-UITests ||
        status=$?
    # The app and the test runner are started by the system, not by xcodebuild, so a run that
    # was ended could leave them open on the owner's desktop. Only this worktree's are ended.
    end_mac_test_hosts
    return "$status"
}

# Ends the Mac app and the UI test runner that this worktree built, if either is still open.
# Prints the process IDs of whatever runs from this worktree's Debug products: the Mac app
# and the UI test runner. A literal match on the command line: pgrep -f would read the path
# as a pattern, in which a "." matches any character.
mac_test_hosts() {
    ps -axww -o pid=,command= | KNOT_MATCH="$(products Debug)/" awk 'index($0, ENVIRON["KNOT_MATCH"]) { print $1 }'
}

end_mac_test_hosts() {
    local folder pids
    folder="$(products Debug)/"
    pids="$(mac_test_hosts)"
    [[ -z $pids ]] && return 0
    echo "ending what the run left open from $folder: $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 2
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
}

# The .live smoke tests (WP-22) and the two-process test (WP-34) are pending in
# scripts/gate-steps.txt until their packages build them. Should a line turn to required
# before the step is filled in, the gate fails here rather than pass a check it did not run.
step_live_smoke() {
    echo "live-smoke: not built yet. WP-22 builds the .live smoke tests (docs/architecture.md §17)."
    return 1
}
step_two_process() {
    echo "two-process: not built yet. WP-34 builds it after G1 and SP-3 (docs/architecture.md §18)."
    return 1
}

# ---- The soak step. It belongs to WP-06, which builds the harness in
# ---- Packages/KnotKit/Tests/KnotSoak/ and fills this function in.
# The capture ledger soak (docs/architecture.md §17, docs/plan/WP-06.md): every test of the
# KnotSoak target, at the soak tier's size, which KNOT_SOAK_SEED selects: the soak of 500
# typed captures from the seed, each injected fault that must turn it red, and the store's
# every-order test, which only this tier runs. A seed comes from --seed, or a fresh one is
# drawn and printed. A failure is never retried: it prints the seed, the kill points and where
# the store was kept, and the rerun with that seed.
step_soak() {
    local seed=${SEED:-$((RANDOM * 32768 + RANDOM))}
    local output="$KNOT_LOGS/verify-soak.out" status=0
    echo "soak: seed $seed"
    knot_swiftpm_flags
    soak_tests() {
        KNOT_SOAK_SEED=$seed swift test "${KNOT_SWIFTPM_FLAGS[@]}" --explicit-target-dependency-import-check error \
            --filter "${KNOT_SOAK_FILTER:-^KnotSoak\.}" 2>&1 | tee "$output" # limit: soak_tests
    }
    knot_swift_test_limited soak soak_tests || status=$?
    # A soak that ran no test, or that skipped or cancelled one, is a failure, not a pass.
    if ((status == 0)) && ! grep -E 'Test run with [1-9][0-9]* tests?' "$output" >/dev/null; then
        echo "soak: no test ran, with seed $seed."
        status=1
    fi
    if ((status == 0)) && [[ -n "$(knot_skipped_tests "$output")" ]]; then
        echo "soak: a test was skipped or cancelled, with seed $seed:"
        knot_skipped_tests "$output"
        status=1
    fi
    if ((status != 0)); then
        # The verdict's own lines: the seed, the kill points, the kept store and the codes.
        grep -E '^ *(capture ledger soak: RED|the store is kept at|kills by point|configuration:|repeat it with)' "$output" || true
        echo "soak: failed with seed $seed. Repeat it with scripts/verify.sh --soak --seed $seed"
        return 1
    fi
    grep -E '^capture ledger soak: |^everyOrderKeepsTheEdit: ' "$output" || true
}
# ---- End of the soak step.

# The timed targets of docs/product-spec.md §14, on an optimised build that keeps the fakes
# (-DKNOT_FAKES). It holds every build slot, so that nothing else runs beside it. The
# measured tests are WP-42's; until they exist this step says so.
step_perf() {
    local scratch="$KNOT_BUILD/swiftpm-perf" output="$KNOT_LOGS/verify-perf.out"
    swift build --package-path "$KNOT_PACKAGE" --scratch-path "$scratch" -c release -Xswiftc -DKNOT_FAKES --build-tests
    perf_tests() {
        swift test --package-path "$KNOT_PACKAGE" --scratch-path "$scratch" -c release -Xswiftc -DKNOT_FAKES \
            --filter 'Performance' 2>&1 | tee "$output" # limit: perf_tests
    }
    knot_swift_test_limited perf perf_tests || return 1
    if grep -E 'Test run with [1-9][0-9]* tests?|Executed [1-9]' "$output" >/dev/null; then
        echo "perf: results in $output. Report each as a median and a 95th percentile of at least 20 runs."
    else
        echo "perf: no measured tests yet. WP-42 adds them, with the protocol of docs/product-spec.md §14."
    fi
}

# The package tests under Thread Sanitizer, as the nightly run does (named test
# package-tests-under-thread-sanitizer-nightly).
step_tsan() {
    local stream="$KNOT_LOGS/verify-tsan-events.jsonl"
    event_flags "$stream"
    knot_swift_test_limited tsan \
        swift test --package-path "$KNOT_PACKAGE" --scratch-path "$KNOT_BUILD/swiftpm-tsan" --sanitize=thread "${EVENT_FLAGS[@]}"
    check_events "$stream"
}

# Reports a change in the on-device models since the last report, as the nightly run on
# main does. The last report is kept in the build folder, outside the worktree.
step_model_report() {
    local last="$KNOT_BUILD_FOLDER/models-last.txt" now
    mkdir -p "$KNOT_BUILD_FOLDER"
    local output="$KNOT_LOGS/verify-model-report.out" status=0
    knot_limit "${KNOT_MODEL_REPORT_LIMIT:-600}" xcrun swift "$KNOT_SCRIPTS/lib/models.swift" >"$output" || status=$?
    if ((KNOT_LIMIT_HIT)); then
        knot_dialog_message "The model report" "${KNOT_MODEL_REPORT_LIMIT:-600}"
        return 1
    fi
    ((status == 0)) || return "$status"
    now="$(cat "$output")"
    echo "$now"
    if [[ -f $last ]] && ! diff -u "$last" <(printf '%s\n' "$now") >/dev/null; then
        echo "model-report: the models or the system changed since the last report:"
        diff -u "$last" <(printf '%s\n' "$now") || true
    elif [[ -f $last ]]; then
        echo "model-report: no change since the last report"
    else
        echo "model-report: first report"
    fi
    printf '%s\n' "$now" >"$last"
}

if [[ -n $IN_STEP ]]; then
    "step_${IN_STEP//-/_}"
    exit $?
fi

# ------------------------------------------------------------------ the plan of the run

# The package whose paths the ownership check holds the diff to.
if [[ -z $PACKAGE ]]; then
    if [[ -n $BRANCH ]]; then
        PACKAGE="$(cd "$KNOT_ROOT" && tool package --branch "$BRANCH" || true)"
        [[ -n $PACKAGE ]] || usage_fail "The branch $BRANCH belongs to no package: name it with --package."
    else
        PACKAGE="$(cd "$KNOT_ROOT" && tool package 2>/dev/null || true)"
    fi
fi
# The branch tells a proof step's note from the package's own pull requests. On a detached
# head the orchestrator names it with --branch.
[[ -n $BRANCH ]] || BRANCH="$(git -C "$KNOT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

DEPTH=""
RUN_MAC_UI=0
PENDING=""
PENDING_COUNT=0
if [[ -n $ONLY ]]; then
    case " $(echo $ALL_STEPS) " in *" $ONLY "*) ;; *)
        usage_fail "Unknown step: $ONLY. Steps: $(echo $ALL_STEPS)." ;;
    esac
    STEPS="doctor"
    [[ $ONLY == doctor ]] || STEPS="doctor $ONLY"
    [[ $ONLY == mac-ui ]] && RUN_MAC_UI=1
    LABEL="--only $ONLY"
elif [[ -n $MODULE ]]; then
    # --module takes a module or a test target. It runs the test target: the folder of
    # that name under Tests/, or else <module>Tests.
    if [[ -d $KNOT_PACKAGE/Tests/$MODULE ]]; then
        TEST_TARGET=$MODULE
    elif [[ -d $KNOT_PACKAGE/Sources/$MODULE && -d $KNOT_PACKAGE/Tests/${MODULE}Tests ]]; then
        TEST_TARGET=${MODULE}Tests
    elif [[ -d $KNOT_PACKAGE/Sources/$MODULE ]]; then
        usage_fail "$MODULE has no test target of its own. Name the module whose tests use it, or a folder of Packages/KnotKit/Tests."
    else
        usage_fail "No module or test target $MODULE in Packages/KnotKit/Sources or Packages/KnotKit/Tests."
    fi
    STEPS="doctor package-build package-test"
    LABEL="--module $MODULE"
else
    case $TIER in
        quick) STEPS=$QUICK_STEPS ;;
        full)
            STEPS=$FULL_STEPS
            if [[ $SKIP == mac-ui ]]; then STEPS="${STEPS/mac-ui/}"; else RUN_MAC_UI=1; fi ;;
        soak) STEPS="doctor package-build soak" ;;
        perf) STEPS="doctor perf" ;;
        gate)
            # The gate builds what every thread builds, signed locally and with no local
            # configuration linked into the tree: a linked one would give its app steps
            # build settings that no other run has. So it refuses KNOT_LOCAL_CONFIG, and
            # it removes a link that an earlier run left. The team-ID check then reads
            # what KNOT_TEAM_CONFIG names and nothing else. The refusal comes before the
            # Xcode is selected, because it needs none.
            if [[ -n ${KNOT_LOCAL_CONFIG:-} ]]; then
                knot_fail "verify-gate-local-config" "The gate builds with no local configuration, as every thread does, and KNOT_LOCAL_CONFIG is set." \
                    "Unset KNOT_LOCAL_CONFIG. Name the owner's configuration for the team-ID check with KNOT_TEAM_CONFIG, which links nothing into the tree." \
                    "safe" "nothing"
            fi
            rm -f "$KNOT_CONFIG/Local.xcconfig"
            # The gate builds with the pinned Xcode only.
            knot_select_xcode
            if [[ ${KNOT_XCODE_NOTE:-} == *"named by KNOT_XCODE"* ]]; then
                knot_fail "verify-gate-xcode" "The gate builds with the pinned Xcode, and KNOT_XCODE names $(knot_xcode_label)." \
                    "Unset KNOT_XCODE, or name the Xcode that .xcode-version pins." "safe" "nothing"
            fi
            [[ -n $PACKAGE ]] || usage_fail "The gate needs the branch, --branch <name>: a detached head has no branch to read, and the branch tells a note's pull request from a code one. --package <ID> beside it names the package when the branch does not."
            # The branch tells a proof step's note from the package's code: without it, a
            # note's pull request would count as a code one, and the named tests of a package
            # that has not merged would be asked for.
            [[ -n $BRANCH ]] || usage_fail "The gate needs the branch, --branch <name>, beside --package: it tells a note's pull request from a code one, and a detached head has no branch to read."
            git -C "$KNOT_ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null ||
                usage_fail "The base $BASE is not a commit here. Fetch it, or name another with --base."
            depth_out="$(cd "$KNOT_ROOT" && tool depth --base "$BASE")"
            DEPTH="$(printf '%s\n' "$depth_out" | sed -n 's/^depth=//p')"
            gate_soak="$(printf '%s\n' "$depth_out" | sed -n 's/^soak=//p')"
            gate_mac_ui="$(printf '%s\n' "$depth_out" | sed -n 's/^mac_ui=//p')"
            gate_hosted="$(printf '%s\n' "$depth_out" | sed -n 's/^hosted=//p')"
            reason="$(printf '%s\n' "$depth_out" | sed -n 's/^reason=//p')"
            common="doctor plan format ownership core-api package-build named-tests pins lint team-id links fixtures"
            case $DEPTH in
                # The lint runs at every depth: its file-name rule catches a copy such as
                # "docs/x 2.md" in a pull request of documents alone. It builds nothing.
                # The team-ID check runs at every depth too: a note or a brief is where an
                # ID is most easily written down.
                documents) STEPS="doctor plan links ownership named-tests lint team-id" ;;
                leaf)
                    STEPS="$common package-test package-test-strict contract-two-targets self-test apps launch"
                    [[ $gate_hosted == 1 ]] && STEPS="$STEPS ios-hosted" ;;
                everything)
                    # docs/architecture.md §18: everything adds the two-process test and the
                    # .live smoke tests. They are pending until their packages build them.
                    STEPS="$common package-test package-test-strict contract-two-targets self-test apps packaging ios-hosted launch"
                    STEPS="$STEPS live-smoke two-process" ;;
            esac
            if [[ $DEPTH != documents && $gate_mac_ui == 1 ]]; then STEPS="$STEPS mac-ui"; RUN_MAC_UI=1; fi
            [[ $DEPTH != documents && $gate_soak == 1 ]] && STEPS="$STEPS soak"
            # A step that scripts/gate-steps.txt lists as pending does not run yet.
            kept=""
            for step in $STEPS; do
                state="$(gate_state "$step")"
                if [[ $state == pending* ]]; then
                    PENDING="$PENDING $step (${state#pending })"
                    PENDING_COUNT=$((PENDING_COUNT + 1))
                    [[ $step == mac-ui ]] && RUN_MAC_UI=0
                else
                    kept="$kept $step"
                fi
            done
            STEPS=$kept
            echo "verify: gate for $PACKAGE against $BASE: depth $DEPTH, because of $reason"
            echo "verify: scripts from $KNOT_SCRIPTS at $(git -C "$KNOT_SCRIPTS" rev-parse --short HEAD), tree $KNOT_ROOT at $(git -C "$KNOT_ROOT" rev-parse --short HEAD)"
            if [[ "$(cd "$KNOT_SCRIPTS/.." && pwd -P)" == "$KNOT_ROOT" ]]; then
                echo "verify: the scripts are the tree's own. The gate runs main's scripts, except for a pull request that changes scripts/."
            fi
            [[ -n $PENDING ]] && echo "verify: pending, not run:$PENDING" ;;
    esac
    LABEL="--$TIER"
    [[ -n $DEPTH ]] && LABEL="--gate $DEPTH"
    [[ $SKIP == mac-ui ]] && LABEL="--full, skip mac-ui"
fi

mkdir -p "$KNOT_LOGS"
# Logs that earlier runs kept, before the filter existed, lose the team's ID too.
knot_scrub_logs "$KNOT_LOGS"
START=$(knot_now)
PASSED=0
SKIPPED_STEPS=0
SKIPPED_NAMES=""
# A step that cannot run on this Mac exits with this status, and counts as skipped.
SKIPPED_CODE=3
SKIPPABLE="team-id ownership"
FAILED_STEP=""
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

count_tests() {
    local log=$1 n
    for n in $(grep -E 'Test run with [0-9]+ tests? .* passed' "$log" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/'); do
        TESTS_PASSED=$((TESTS_PASSED + n))
    done
    TESTS_FAILED=$((TESTS_FAILED + $(knot_failed_tests "$log" | grep -c . || true)))
    # The console's reading and the event stream's, the larger: a cancelled case prints as
    # passed, and an event over two lines matches no pattern, while the stream counts both.
    local console stream=0
    console=$(knot_skipped_tests "$log" | grep -c . || true)
    for n in $(sed -n -E 's/^events: [0-9]+ of [0-9]+ runs ended, [0-9]+ tests, ([0-9]+) skipped or cancelled.*/\1/p' "$log"); do
        stream=$((stream + n))
    done
    TESTS_SKIPPED=$((TESTS_SKIPPED + (stream > console ? stream : console)))
    # XCTest cases, such as UI tests, from knot_xctest_result's lines.
    for n in $(sed -n -E 's/^xctest: ([0-9]+) passed, ([0-9]+) failed.*/\1/p' "$log"); do
        TESTS_PASSED=$((TESTS_PASSED + n))
    done
    for n in $(sed -n -E 's/^xctest: ([0-9]+) passed, ([0-9]+) failed.*/\2/p' "$log"); do
        TESTS_FAILED=$((TESTS_FAILED + n))
    done
}

export KNOT_VERIFY_TIER=$TIER KNOT_VERIFY_MODULE=$MODULE KNOT_VERIFY_TEST_TARGET=$TEST_TARGET \
    KNOT_VERIFY_PACKAGE=$PACKAGE KNOT_VERIFY_BASE=$BASE KNOT_VERIFY_SEED=$SEED

# The steps whose logs hold test results, which the summary counts, whether they pass or fail.
COUNTED_STEPS="package-test tsan soak ios-hosted launch mac-ui"
# package-test-strict runs the same tests as package-test, which counts them: the summary
# adds only its failures.
for step in $STEPS; do
    log="$KNOT_LOGS/verify-$step.log"
    step_start=$(knot_now)
    options="$(slot_options "$step")"
    runner="step_${step//-/_}"
    # The Mac UI tests need the screen unlocked. The state is read once, before the step. A
    # locked screen fails the step at once, before it takes its slot, and runs no test. A
    # read that says nothing never passes the step: the step runs, and fails by itself if the
    # screen is locked.
    if [[ $step == mac-ui ]]; then
        case "$(knot_console_state)" in
            locked)
                options=none
                runner=knot_mac_ui_locked ;;
            unknown)
                echo "verify: could not read whether the screen is locked; the Mac UI step runs, and fails by itself if it is." ;;
        esac
    fi
    if [[ $options == none ]]; then
        # A light step runs in a background subshell, so that `set -e` holds inside it:
        # bash ignores -e in a function that runs as the condition of an `if`.
        # Its output is filtered for the team's ID, as every log of the run is.
        (
            set -o pipefail
            ("$runner") 2>&1 | knot_filter_team
        ) >"$log" &
    else
        # A heavy step runs in its own process, holding a build slot.
        # shellcheck disable=SC2086
        (
            set -o pipefail
            "$KNOT_SCRIPTS/build-slot.sh" run $( [[ $TIER == gate ]] && echo --gate ) $options --label "$step" \
                -- "$KNOT_SCRIPTS/verify.sh" --in-step "$step" 2>&1 | knot_filter_team
        ) >"$log" &
    fi
    code=0
    wait $! || code=$?
    if ((code == SKIPPED_CODE)) && [[ " $SKIPPABLE " == *" $step "* ]]; then
        # A step that could not run here says so, and counts as skipped, never as passed.
        SKIPPED_STEPS=$((SKIPPED_STEPS + 1))
        SKIPPED_NAMES="$SKIPPED_NAMES $step"
        printf 'verify: skip  %-22s %s\n' "$step" "$(tail -n 1 "$log")"
    elif ((code == 0)); then
        PASSED=$((PASSED + 1))
        printf 'verify: ok    %-22s %s\n' "$step" "$(knot_duration $(($(knot_now) - step_start)))"
        if [[ $step == ownership ]]; then
            ALLOWED=$(sed -n -E 's/.* ([0-9]+) allowed by hand$/\1/p' "$log" | tail -n 1)
            # The paths the orchestrator allowed by hand show on the console, not only in the log.
            grep -E '^ownership: allowed by hand: ' "$log" | sed 's/^ownership: /        /' || true
        fi
        [[ " $COUNTED_STEPS " == *" $step "* ]] && count_tests "$log"
        # Doctor has checked the Xcode; every later step uses it.
        [[ $step == doctor ]] && knot_select_xcode
    else
        FAILED_STEP=$step
        printf 'verify: FAIL  %-22s %s\n' "$step" "$(knot_duration $(($(knot_now) - step_start)))"
        # A failed step's tests count too, so the summary shows its failed cases.
        [[ " $COUNTED_STEPS " == *" $step "* ]] && count_tests "$log"
        [[ $step == package-test-strict ]] && TESTS_FAILED=$((TESTS_FAILED + $(knot_failed_tests "$log" | grep -c . || true)))
        tail -n 25 "$log" | sed 's/^/        /'
        rerun="scripts/verify.sh --only $step"
        [[ -n $MODULE && $step == package-* ]] && rerun="scripts/verify.sh --module $MODULE"
        [[ $step == soak ]] && rerun="scripts/verify.sh --soak${SEED:+ --seed $SEED}"
        knot_report "verify-$step" "The step $step failed. Its log is $log." \
            "Read the log, fix the cause, then rerun only this step: $rerun" "safe" \
            "build products in .build/ only" || true
        break
    fi
done

total=$(echo $STEPS | wc -w | tr -d ' ')
failed=$((${#FAILED_STEP} > 0 ? 1 : 0))
not_run=$((total - PASSED - failed - SKIPPED_STEPS))
ALLOWED=${ALLOWED:-0}
pending=$PENDING_COUNT
status=ok
[[ -n $FAILED_STEP ]] && status=FAILED
# The gate refuses a partial run: a step that could not run here fails it. Every other tier
# reports the step as skipped and ends ok.
if [[ $TIER == gate && -z $FAILED_STEP && -n $SKIPPED_NAMES ]]; then
    status=FAILED
    knot_report "verify-gate-skipped" "The gate could not run:$SKIPPED_NAMES. A gate with a skipped step has not passed." \
        "For team-id, name the owner's configuration with KNOT_TEAM_CONFIG and run the gate again. A thread without it runs scripts/verify.sh --full, which reports the step as skipped." \
        "safe" "build products in .build/ only" || true
fi
xcode="$( [[ -n ${KNOT_XCODE_VERSION:-} ]] && knot_xcode_label || echo 'Xcode not selected')"
duration="$(knot_duration $(($(knot_now) - START)))"
allowed_text=""
((ALLOWED)) && allowed_text=" · $ALLOWED paths allowed by hand"
printf 'verify %s: %s · steps %d passed, %d failed, %d skipped, %d not run, %d pending · tests %d passed, %d failed, %d skipped%s · %s · %s · %s\n' \
    "$LABEL" "$status" "$PASSED" "$failed" "$SKIPPED_STEPS" "$not_run" "$pending" \
    "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED" "$allowed_text" "$duration" "$xcode" "$(knot_macos_label)"

# The status line: the same facts in at most 140 characters, for a commit status, whose
# description GitHub cuts at 140. scripts/verify.sh --status-line prints it again.
short="${LABEL#--} $status${FAILED_STEP:+ at $FAILED_STEP}: $PASSED/$total steps, $TESTS_PASSED tests"
((TESTS_FAILED)) && short="$short, $TESTS_FAILED failed"
((TESTS_SKIPPED)) && short="$short, $TESTS_SKIPPED skipped"
((SKIPPED_STEPS)) && short="$short, $SKIPPED_STEPS steps skipped"
((pending)) && short="$short, $pending pending"
((ALLOWED)) && short="$short, $ALLOWED allowed by hand"
short="$short · $duration · Xcode ${KNOT_XCODE_VERSION:-?} ${KNOT_XCODE_BUILD:-}"
[[ -n ${KNOT_XCODE_NOTE:-} ]] && short="$short*"
candidate="$short · macOS $(sw_vers -buildVersion)"
((${#candidate} <= 140)) && short=$candidate
short="${short:0:140}"
printf '%s\n' "$short" >"$STATUS_FILE"
[[ $status == ok ]]
