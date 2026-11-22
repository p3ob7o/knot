# shellcheck shell=bash
# The tree that the scripts of KNOT_SCRIPTS work on, as KNOT_ROOT. Sourced by common.sh and by
# check-plan.sh, which sources no common.sh: every script that takes KNOT_TREE takes it here,
# so that none takes a tree another checkout's scripts exported. KNOT_SCRIPTS and fail.sh come
# first.
KNOT_ROOT="$(cd "$KNOT_SCRIPTS/.." && pwd -P)"
if [[ -n ${KNOT_TREE:-} ]]; then
    # A tree is named, or inherited from the scripts that exported it below. An inherited one
    # is right for those scripts' own children, such as a step in its own process, and wrong
    # for another checkout's: a script of one worktree started through another checkout's
    # build-slot.sh would build and test that checkout, silently. So a KNOT_TREE that is
    # still the one another checkout's scripts exported is refused, unless --tree, or
    # KNOT_TREE_NAMED=1 beside it, names it (docs/dev-setup.md, a replay).
    if [[ ${KNOT_TREE_NAMED:-} != 1 && -n ${KNOT_TREE_SET_BY:-} && $KNOT_TREE_SET_BY != "$KNOT_SCRIPTS" &&
        $KNOT_TREE == "${KNOT_TREE_EXPORTED:-}" ]]; then
        knot_fail "knot-tree-inherited" "KNOT_TREE names $(basename "$KNOT_TREE"), which the scripts of $(basename "$(dirname "$KNOT_TREE_SET_BY")") exported, and these scripts are $(basename "$KNOT_ROOT")'s: a script started through another checkout's build-slot.sh." \
            "Start it through its own checkout's scripts/build-slot.sh, or name the tree with --tree or KNOT_TREE_NAMED=1." "safe" "nothing"
    fi
    KNOT_ROOT="$(cd "$KNOT_TREE" 2>/dev/null && pwd -P)" ||
        knot_fail "knot-tree-missing" "KNOT_TREE names $KNOT_TREE, which is not a folder." \
            "Name the tree to check, such as the gate worktree, or unset KNOT_TREE." "safe" "nothing"
fi
# Children, such as a step that runs in its own process, check the same tree, and know which
# scripts exported it.
export KNOT_TREE="$KNOT_ROOT" KNOT_SCRIPTS KNOT_TREE_SET_BY="$KNOT_SCRIPTS" KNOT_TREE_EXPORTED="$KNOT_ROOT"
unset KNOT_TREE_NAMED
