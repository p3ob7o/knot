# shellcheck shell=bash
# Every script reports failure through this file (docs/architecture.md §18).
#
#   knot_fail   <code> <what> <fix> <retry> <changed>   report, then exit 1
#   knot_report <code> <what> <fix> <retry> <changed>   report, then return 1
#
# The five fields, always in this order:
#   code     a stable code of lower-case words joined by hyphens. A code that starts with
#            "infra-" is a failure of the machine or of a tool, not of the code under
#            test, and is the only kind the merge queue reruns, once.
#   what     what failed.
#   fix      what to do about it.
#   retry    "safe" when running the same command again can do no harm, else "unsafe".
#   changed  what the failed command had changed, or "nothing".
#
# When KNOT_FAIL_LOG names a file, each failure is also appended to it as one line of
# tab-separated fields, so that a calling script can collect them.

knot_report() {
    if [[ $# -ne 5 ]]; then
        set -- "infra-fail-usage" "knot_report was called with $# fields instead of 5: $*" \
            "Pass a code, what failed, the fix, retry safe|unsafe, and what was changed." \
            "safe" "nothing"
    fi
    local code=$1 what=$2 fix=$3 retry=$4 changed=$5
    case $retry in
        safe | unsafe) ;;
        *) retry="unsafe" ;;
    esac
    {
        printf 'FAIL %s\n' "$code"
        printf '  what:    %s\n' "$what"
        printf '  fix:     %s\n' "$fix"
        printf '  retry:   %s\n' "$retry"
        printf '  changed: %s\n' "$changed"
    } >&2
    if [[ -n ${KNOT_FAIL_LOG:-} ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$code" "$what" "$fix" "$retry" "$changed" >>"$KNOT_FAIL_LOG"
    fi
    return 1
}

knot_fail() {
    knot_report "$@" || true
    exit 1
}
