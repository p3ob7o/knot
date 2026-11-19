#!/bin/bash
# Prints the status table (PLAN.md §8.7, docs/architecture.md §18): one row per package,
# with its state, its thread, its pull requests and its milestone evidence.
#
#   scripts/status.sh            print the table
#   scripts/status.sh --write    also write it to docs/status.md, which goes to main only
#                                at milestones
#
# The briefs give the packages and how many pull requests each plans. GitHub gives the
# pull requests, by branch name, with their labels and the knot/gate status of their head.
# The threads come from threads.tsv in the build folder (a package and a thread link per
# line), and the milestone evidence from the column of the same name in docs/status.md.

source "$(dirname "$0")/lib/common.sh"

case ${1:-} in
    "" | --write) ;;
    -h | --help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) knot_fail "status-usage" "Unknown argument: $1" "Run scripts/status.sh --help." "safe" "nothing" ;;
esac
command -v gh >/dev/null ||
    knot_fail "infra-gh-missing" "The GitHub command-line tool, gh, is missing." "brew install gh, then gh auth login." "safe" "nothing"
cd "$KNOT_ROOT"
KNOT_BUILD_FOLDER="$KNOT_BUILD_FOLDER" python3 -I scripts/lib/knot_tool.py status ${1:+"$1"} ||
    knot_fail "infra-status" "The status table could not be built." "Read the error above. gh must be signed in." "safe" \
        "$( [[ ${1:-} == --write ]] && echo "docs/status.md may be half written" || echo nothing)"
