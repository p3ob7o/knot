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
#      (scripts/verify.sh --only model-report);
#   7. the timed targets on an optimised build with the fakes (scripts/verify.sh --perf),
#      holding every build slot, so that a change that breaks that build shows the next
#      morning and not at a milestone.
# It prints each run's status line, and exits non-zero when any run failed. A red night
# stops the merge queue (docs/orchestrator.md). A run that did not start for want of a build
# slot, verify.sh's status 4, as --perf can on a busy night, is reported as not run, apart from
# the failures, and does not make the night red. Each run's logs, the files it wrote in
# .build/logs/, are kept in a folder of their own, .build/nightly/<run>/, cleared when the
# night starts: one verify run's logs would otherwise go aside at the next whole run.

source "$(dirname "$0")/lib/common.sh"

FULL=(--full)
case ${1:-} in
    "") ;;
    --skip) [[ ${2:-} == mac-ui ]] || knot_fail "nightly-usage" "--skip takes mac-ui only." "Run scripts/nightly.sh --help." "safe" "nothing"
        FULL=(--full --skip mac-ui) ;;
    -h | --help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) knot_fail "nightly-usage" "Unknown argument: $1" "Run scripts/nightly.sh --help." "safe" "nothing" ;;
esac
branch="$(git -C "$KNOT_ROOT" symbolic-ref --quiet --short HEAD || echo detached)"
[[ $branch == main || $branch == detached ]] ||
    echo "nightly: running on $branch, not main. The nightly run of record is on main."

NIGHTLY="$KNOT_BUILD/nightly"
rm -rf "$NIGHTLY"
mkdir -p "$NIGHTLY" "$KNOT_LOGS"
failed=()
not_run=()
summary=()
run() {
    local name=$1 marker
    shift
    echo "nightly: $name"
    marker="$NIGHTLY/.started-$name"
    : >"$marker"
    local status=0
    "$@" || status=$?
    if ((status == 4)); then
        not_run+=("$name")
    elif ((status != 0)); then
        failed+=("$name")
    fi
    # The files the run wrote, kept in its own folder.
    mkdir -p "$NIGHTLY/$name"
    find "$KNOT_LOGS" -maxdepth 1 -type f -newer "$marker" -exec cp -p {} "$NIGHTLY/$name/" \;
    rm -f "$marker"
    summary+=("$name: $("$KNOT_SCRIPTS/verify.sh" --status-line 2>/dev/null || echo "no status line")")
}
run full "$KNOT_SCRIPTS/verify.sh" "${FULL[@]}"
run tsan "$KNOT_SCRIPTS/verify.sh" --only tsan
run soak "$KNOT_SCRIPTS/verify.sh" --soak
run oldest-runtime env KNOT_SIM_IOS_VERSION=27.0 "$KNOT_SCRIPTS/verify.sh" --only launch
run recorder-sim "$KNOT_SCRIPTS/verify.sh" --only recorder-sim
run models "$KNOT_SCRIPTS/verify.sh" --only model-report
grep -e 'changed since' "$NIGHTLY/models/verify-model-report.log" 2>/dev/null || true
run perf "$KNOT_SCRIPTS/verify.sh" --perf

printf 'nightly: %s\n' "${summary[@]}"
((${#not_run[@]} == 0)) ||
    echo "nightly: not run, for want of a build slot: ${not_run[*]}. No failure of the code; run each again when the slots are free."
if ((${#failed[@]})); then
    knot_fail "nightly" "The nightly run failed in: ${failed[*]}." \
        "Read each run's logs in .build/nightly/<run>/. A red night stops the queue: bisect the squash merges and revert the cause." \
        "safe" "build products in .build/ only"
fi
if ((${#not_run[@]})); then
    echo "nightly: every run that ran passed"
else
    echo "nightly: every run passed"
fi
