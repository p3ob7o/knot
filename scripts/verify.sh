#!/bin/bash
# Builds and tests Knot (docs/architecture.md §18). One run takes one tier.
#
#   scripts/verify.sh --quick              formatting, the plan check, the pins, the package
#                                          build and its tests
#   scripts/verify.sh --only <step>        doctor, then that one step
#   scripts/verify.sh --module <name>      doctor, then the package build and the tests of
#                                          one module, such as KnotStore
#   scripts/verify.sh --full | --gate | --soak [--seed <n>] | --perf
#                                          arrive with WP-01 PR 2 (scripts/gate-steps.txt)
#
# Steps: doctor, plan, format, pins, package-build, package-test, contract-two-targets
# (the --quick tier), and apps, packaging, launch (run with --only until --full exists).
#
# Every run starts with scripts/doctor.sh and ends with one summary line: the counts, the
# skips, the duration, the Xcode and the macOS build. A failed step names itself, its log
# and the command that reruns only that step. Logs go to .build/logs/.

source "$(dirname "$0")/lib/common.sh"

QUICK_STEPS="doctor plan format pins package-build package-test contract-two-targets"
OTHER_STEPS="apps packaging launch"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "verify-usage" "$1" "Run scripts/verify.sh --help." "safe" "nothing"; }

TIER=""
ONLY=""
MODULE=""
set_tier() {
    [[ -z $TIER ]] || usage_fail "One run takes one tier; got --$TIER and $1."
    TIER=${1#--}
}
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick | --full | --gate | --soak | --perf) set_tier "$1"; shift ;;
        --only) ONLY=${2:-}; [[ -n $ONLY ]] || usage_fail "--only needs a step."; shift 2 ;;
        --module) MODULE=${2:-}; [[ -n $MODULE ]] || usage_fail "--module needs a module name."; shift 2 ;;
        --seed | --skip) usage_fail "$1 belongs to a tier that arrives with WP-01 PR 2." ;;
        -h | --help) usage; exit 0 ;;
        *) usage_fail "Unknown argument: $1" ;;
    esac
done

case $TIER in
    full | soak | perf)
        knot_fail "verify-tier-not-built" "The --$TIER tier arrives with WP-01 PR 2." \
            "Use --quick, or --only <step> for: $QUICK_STEPS $OTHER_STEPS." "safe" "nothing" ;;
    gate)
        knot_fail "verify-tier-not-built" "--gate arrives with WP-01 PR 2. Until then the gate is --quick (scripts/gate-steps.txt)." \
            "Run scripts/verify.sh --quick." "safe" "nothing" ;;
esac
if [[ -n $ONLY || -n $MODULE ]]; then
    [[ -z $TIER ]] || usage_fail "--only and --module run one part. They take no tier."
    [[ -z $ONLY || -z $MODULE ]] || usage_fail "Use --only or --module, not both."
fi
if [[ -z $TIER && -z $ONLY && -z $MODULE ]]; then
    usage_fail "Name a tier, --only <step> or --module <name>."
fi

if [[ -n $ONLY ]]; then
    case " $QUICK_STEPS $OTHER_STEPS " in *" $ONLY "*) ;; *)
        usage_fail "Unknown step: $ONLY. Steps: $QUICK_STEPS $OTHER_STEPS." ;;
    esac
    STEPS="doctor"
    [[ $ONLY == doctor ]] || STEPS="doctor $ONLY"
    LABEL="--only $ONLY"
elif [[ -n $MODULE ]]; then
    [[ -d $KNOT_PACKAGE/Sources/$MODULE ]] || usage_fail "No module $MODULE in Packages/KnotKit/Sources."
    STEPS="doctor package-build package-test"
    LABEL="--module $MODULE"
else
    STEPS=$QUICK_STEPS
    LABEL="--$TIER"
fi

mkdir -p "$KNOT_LOGS"
START=$(knot_now)
PASSED=0
FAILED_STEP=""
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# ------------------------------------------------------------------ helpers

xcb() {
    # xcb <log> <xcodebuild arguments…>
    local log=$1
    shift
    knot_xcodebuild_settings
    xcodebuild -project "$KNOT_PROJECT" "${KNOT_XCODEBUILD[@]}" "$@" >>"$log" 2>&1
}

products() { printf '%s/Build/Products/%s' "$KNOT_DERIVED" "$1"; }

check() {
    # check <what> <command…>: one line of the packaging proof.
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

macho_files() { find "$1" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print; }

# ------------------------------------------------------------------ steps

step_doctor() { "$KNOT_ROOT/scripts/doctor.sh" --tier "${TIER:-quick}"; }

step_plan() { "$KNOT_ROOT/scripts/check-plan.sh"; }

step_format() {
    (cd "$KNOT_ROOT" && xcrun swift-format lint --strict --recursive --parallel \
        Packages/KnotKit/Package.swift Packages/KnotKit/Sources Packages/KnotKit/Tests Apps scripts/lib/windows.swift)
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
    xcb /dev/stdout -scheme Knot-iOS -resolvePackageDependencies
    check_resolved "$KNOT_SOURCE_PACKAGES/workspace-state.json" "$version" "$revision"
}

step_package_build() {
    knot_swiftpm_flags
    swift build "${KNOT_SWIFTPM_FLAGS[@]}" --build-tests --explicit-target-dependency-import-check error
}

step_package_test() {
    knot_swiftpm_flags
    local filter=()
    if [[ -n $MODULE ]]; then
        filter=(--filter "^${MODULE%Tests}Tests\.")
        [[ $MODULE == KnotSoak ]] && filter=(--filter "^KnotSoak\.")
    fi
    swift test "${KNOT_SWIFTPM_FLAGS[@]}" --explicit-target-dependency-import-check error ${filter[@]+"${filter[@]}"}
}

# The named test contract-suite-dummy-port-two-test-targets: one contract suite in
# KnotTestSupport, run from two test targets.
step_contract_two_targets() {
    knot_swiftpm_flags
    local targets
    targets="$(swift test "${KNOT_SWIFTPM_FLAGS[@]}" list 2>/dev/null |
        grep 'contractSuiteDummyPortTwoTestTargets' | cut -d. -f1 | cut -d/ -f1 | sort -u)"
    echo "Targets that run the dummy contract suite:"
    echo "$targets"
    [[ $(printf '%s\n' "$targets" | grep -c .) -ge 2 ]]
}

# Every app, Debug: the iOS app with the Watch app and both widget extensions in it, and
# the Mac app with the `knot` tool in it.
step_apps() {
    local log="$KNOT_LOGS/verify-apps.log"
    : >"$log"
    knot_generate_project
    echo "Knot-iOS, Debug, iOS Simulator"
    xcb "$log" -scheme Knot-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' build
    echo "Knot-macOS, Debug"
    xcb "$log" -scheme Knot-macOS -configuration Debug -destination 'platform=macOS' build
}

# The packaging that otherwise fails late, each proven with one trivial instance
# (docs/plan/WP-01.md).
step_packaging() {
    step_apps
    local log="$KNOT_LOGS/verify-packaging-release.log"
    : >"$log"
    echo "Knot-iOS and Knot-macOS, Release"
    xcb "$log" -scheme Knot-iOS -configuration Release -destination 'generic/platform=iOS Simulator' build
    xcb "$log" -scheme Knot-macOS -configuration Release -destination 'platform=macOS' build

    local ios mac failed=0
    ios="$(products Debug-iphonesimulator)/Knot.app"
    mac="$(products Debug)/Knot.app"

    intent_in() { grep -q KnotPlaceholderIntent "$1/Metadata.appintents/extract.actionsdata"; }
    check "App Intent declared in KnotIntents, in the iOS app's metadata" intent_in "$ios" || failed=1
    check "the same intent in the widget extension's metadata" intent_in "$ios/PlugIns/Widgets-iOS.appex" || failed=1

    activity_in() {
        local f
        for f in $(macho_files "$1"); do
            nm "$f" 2>/dev/null | xcrun swift-demangle | grep -e "KnotIntents.KnotPlaceholderActivityAttributes" >/dev/null && return 0
        done
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
            [[ "$("$tool" --version)" == "knot-dev $version (dev)" ]]
    }
    check "knot-dev embedded and signed in the Mac app, with its own sandbox, and runs" tool_embedded || failed=1

    check "a contract suite in KnotTestSupport run from two test targets" step_contract_two_targets >/dev/null || failed=1

    free_of_fakes() {
        local f found=0
        for f in $(macho_files "$1"); do
            if nm -a "$f" 2>/dev/null | grep -e 9KnotFakes >/dev/null || strings -a "$f" | grep -e KnotFakes >/dev/null; then
                echo "KnotFakes in $f"
                found=1
            fi
        done
        ((found == 0))
    }
    check "Release Mac app free of KnotFakes" free_of_fakes "$(products Release)/Knot.app" || failed=1
    check "Release iOS app, its extension and the Watch app free of KnotFakes" \
        free_of_fakes "$(products Release-iphonesimulator)/Knot.app" || failed=1
    debug_has_fakes() {
        local f
        for f in $(macho_files "$ios"); do nm -a "$f" 2>/dev/null | grep -e 9KnotFakes >/dev/null && return 0; done
        return 1
    }
    check "the Debug iOS app does hold KnotFakes, so the check can see it" debug_has_fakes || failed=1
    ((failed == 0))
}

# The three apps launch and show the placeholder: the UI launch tests on the iPhone, the
# iPad and the Watch simulators, a screenshot of each, and the Mac app's window.
step_launch() {
    local log="$KNOT_LOGS/verify-launch-tests.log" iphone ipad watch
    : >"$log"
    "$KNOT_ROOT/scripts/sim.sh" ensure
    iphone="$("$KNOT_ROOT/scripts/sim.sh" udid iphone)"
    ipad="$("$KNOT_ROOT/scripts/sim.sh" udid ipad)"
    watch="$("$KNOT_ROOT/scripts/sim.sh" udid watch)"
    knot_generate_project
    echo "UI launch tests on $KNOT_WORKTREE-iphone and -ipad"
    xcb "$log" -scheme Knot-iOS -configuration Debug -destination "id=$iphone" -destination "id=$ipad" \
        -only-testing:Knot-iOS-UITests test
    echo "UI launch test on $KNOT_WORKTREE-watch"
    xcb "$log" -scheme Knot-watchOS -configuration Debug -destination "id=$watch" test

    local ios bundle role udid
    ios="$(products Debug-iphonesimulator)/Knot.app"
    bundle="$(plist_value "$ios/Info.plist" CFBundleIdentifier)"
    for role in iphone ipad watch; do
        udid="$("$KNOT_ROOT/scripts/sim.sh" udid $role)"
        xcrun simctl bootstatus "$udid" -b >/dev/null
        if [[ $role == watch ]]; then
            xcrun simctl install "$udid" "$(find "$ios/Watch" -maxdepth 1 -name '*.app' | head -n 1)"
            xcrun simctl launch "$udid" "$bundle.watchkitapp" >/dev/null
        else
            xcrun simctl install "$udid" "$ios"
            xcrun simctl launch "$udid" "$bundle" >/dev/null
        fi
        sleep 4
        xcrun simctl io "$udid" screenshot "$KNOT_LOGS/launch-$role.png" >/dev/null 2>&1
        echo "screenshot: $KNOT_LOGS/launch-$role.png"
    done
    "$KNOT_ROOT/scripts/sim.sh" shutdown

    # The Mac app: Mac UI tests need Automation Mode, so this checks that the app puts a
    # window on screen. It reads only what needs no Screen Recording permission.
    local mac pid windows="" i
    mac="$(products Debug)/Knot.app"
    "$mac/Contents/MacOS/Knot" >/dev/null 2>&1 &
    pid=$!
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        windows="$(xcrun swift "$KNOT_ROOT/scripts/lib/windows.swift" "$pid" 2>/dev/null || true)"
        [[ -n $windows ]] && break
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "Mac app windows: ${windows:-none}"
    [[ -n $windows ]]
}

# ------------------------------------------------------------------ run

count_tests() {
    local log=$1 n
    for n in $(grep -E 'Test run with [0-9]+ tests? .* passed' "$log" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/'); do
        TESTS_PASSED=$((TESTS_PASSED + n))
    done
    TESTS_FAILED=$((TESTS_FAILED + $(grep -c -E 'Test .* failed after' "$log" || true)))
    TESTS_SKIPPED=$((TESTS_SKIPPED + $(grep -c -E 'Test .* skipped' "$log" || true)))
}

for step in $STEPS; do
    log="$KNOT_LOGS/verify-$step.log"
    step_start=$(knot_now)
    # Each step runs in a background subshell, so that `set -e` holds inside it: bash
    # ignores -e in a function that runs as the condition of an `if`.
    ("step_${step//-/_}") >"$log" 2>&1 &
    if wait $!; then
        PASSED=$((PASSED + 1))
        printf 'verify: ok    %-22s %s\n' "$step" "$(knot_duration $(($(knot_now) - step_start)))"
        [[ $step == package-test ]] && count_tests "$log"
        # Doctor has checked the Xcode; every later step uses it.
        [[ $step == doctor ]] && knot_select_xcode
    else
        FAILED_STEP=$step
        printf 'verify: FAIL  %-22s %s\n' "$step" "$(knot_duration $(($(knot_now) - step_start)))"
        [[ $step == package-test ]] && count_tests "$log"
        tail -n 25 "$log" | sed 's/^/        /'
        rerun="scripts/verify.sh --only $step"
        [[ -n $MODULE && $step == package-* ]] && rerun="scripts/verify.sh --module $MODULE"
        knot_report "verify-$step" "The step $step failed. Its log is $log." \
            "Read the log, fix the cause, then rerun only this step: $rerun" "safe" \
            "build products in .build/ only" || true
        break
    fi
done

total=$(echo $STEPS | wc -w | tr -d ' ')
not_run=$((total - PASSED - (${#FAILED_STEP} > 0 ? 1 : 0)))
status=ok
[[ -n $FAILED_STEP ]] && status=FAILED
xcode="$( [[ -n ${KNOT_XCODE_VERSION:-} ]] && knot_xcode_label || echo 'Xcode not selected')"
printf 'verify %s: %s · steps %d passed, %d failed, %d not run · tests %d passed, %d failed, %d skipped · %s · %s · %s\n' \
    "$LABEL" "$status" "$PASSED" "$((${#FAILED_STEP} > 0 ? 1 : 0))" "$not_run" \
    "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED" \
    "$(knot_duration $(($(knot_now) - START)))" "$xcode" "$(knot_macos_label)"
[[ -z $FAILED_STEP ]]
