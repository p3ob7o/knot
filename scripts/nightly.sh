#!/bin/bash
# The nightly run, on a checkout of main (docs/architecture.md §18, PLAN.md §9).
#
#   scripts/nightly.sh [--skip mac-ui]
#
# It runs, one after another, each in its own verify run:
#   1. scripts/verify.sh --full, which does everything, Mac UI tests included;
#   2. the package tests under Thread Sanitizer, the named test
#      package-tests-under-thread-sanitizer-nightly (scripts/verify.sh --only tsan);
#   3. the soak with a fresh seed (scripts/verify.sh --soak);
#   4. the launches on the iOS 27.0 runtime, the oldest system Knot supports, with their
#      own simulators (KNOT_SIM_IOS_VERSION=27.0 scripts/verify.sh --only launch);
#   5. the recorder's kill test and its shared recording state in the iOS Simulator, with a
#      fresh seed (scripts/verify.sh --only recorder-sim);
#   6. the report of a model that changed with an update of the operating system
#      (scripts/verify.sh --only model-report).
# It prints each run's status line, and exits non-zero when any run failed. A red night
# stops the merge queue (docs/orchestrator.md).

source "$(dirname "$0")/lib/common.sh"

FULL=(--full)
case ${1:-} in
    "") ;;
    --skip) [[ ${2:-} == mac-ui ]] || knot_fail "nightly-usage" "--skip takes mac-ui only." "Run scripts/nightly.sh --help." "safe" "nothing"
        FULL=(--full --skip mac-ui) ;;
    -h | --help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) knot_fail "nightly-usage" "Unknown argument: $1" "Run scripts/nightly.sh --help." "safe" "nothing" ;;
esac
branch="$(git -C "$KNOT_ROOT" symbolic-ref --quiet --short HEAD || echo detached)"
[[ $branch == main || $branch == detached ]] ||
    echo "nightly: running on $branch, not main. The nightly run of record is on main."

failed=()
summary=()
run() {
    local name=$1
    shift
    echo "nightly: $name"
    if "$@"; then :; else failed+=("$name"); fi
    summary+=("$name: $("$KNOT_SCRIPTS/verify.sh" --status-line 2>/dev/null || echo "no status line")")
}
run full "$KNOT_SCRIPTS/verify.sh" "${FULL[@]}"
run tsan "$KNOT_SCRIPTS/verify.sh" --only tsan
run soak "$KNOT_SCRIPTS/verify.sh" --soak
run oldest-runtime env KNOT_SIM_IOS_VERSION=27.0 "$KNOT_SCRIPTS/verify.sh" --only launch
run recorder-sim "$KNOT_SCRIPTS/verify.sh" --only recorder-sim
run models "$KNOT_SCRIPTS/verify.sh" --only model-report
grep -e 'changed since' "$KNOT_LOGS/verify-model-report.log" 2>/dev/null || true

printf 'nightly: %s\n' "${summary[@]}"
if ((${#failed[@]})); then
    knot_fail "nightly" "The nightly run failed in: ${failed[*]}." \
        "Read each run's log in .build/logs/. A red night stops the queue: bisect the squash merges and revert the cause." \
        "safe" "build products in .build/ only"
fi
echo "nightly: every run passed"
