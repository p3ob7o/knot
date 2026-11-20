#!/bin/bash
# Removes a worktree with everything it made on this Mac (docs/architecture.md §18): its
# simulators, its development store folder in the development app's own container, and the
# worktree itself with its .build/ and DerivedData. It does not look in app group containers,
# and says so.
#
#   scripts/worktree-remove.sh <worktree folder> [--force]
#
# --force also removes a worktree with changes that are not committed, which git otherwise
# refuses. The main checkout is never removed. The worktree's branch stays.

source "$(dirname "$0")/lib/common.sh"

TARGET=""
FORCE=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --force) FORCE=1; shift ;;
        -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) knot_fail "worktree-remove-usage" "Unknown option: $1" "Run scripts/worktree-remove.sh --help." "safe" "nothing" ;;
        *) TARGET=$1; shift ;;
    esac
done
[[ -n $TARGET ]] || knot_fail "worktree-remove-usage" "Name the worktree folder to remove." \
    "Run scripts/worktree-remove.sh <folder>." "safe" "nothing"
[[ -d $TARGET ]] || knot_fail "worktree-remove-missing" "$TARGET is not a folder." "Name a worktree from git worktree list." "safe" "nothing"
TARGET="$(cd "$TARGET" && pwd -P)"

# It must be a worktree of this repository, and not the main checkout.
main="$(git -C "$KNOT_ROOT" worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
main="$(cd "$main" && pwd -P)"
found=0
while IFS= read -r tree; do
    if [[ "$(cd "$tree" 2>/dev/null && pwd -P)" == "$TARGET" ]]; then found=1; fi
done < <(git -C "$KNOT_ROOT" worktree list --porcelain | awk '/^worktree / { print substr($0, 10) }')
((found)) ||
    knot_fail "worktree-remove-not-worktree" "$TARGET is not a worktree of this repository." \
        "Name a folder from git worktree list." "safe" "nothing"
[[ $TARGET != "$main" ]] ||
    knot_fail "worktree-remove-main" "$TARGET is the main checkout, which is never removed." \
        "Name another worktree." "safe" "nothing"
if ((!FORCE)) && [[ -n "$(git -C "$TARGET" status --porcelain)" ]]; then
    knot_fail "worktree-remove-dirty" "$TARGET has changes that are not committed." \
        "Commit or move them, or pass --force to remove them with the worktree." "safe" "nothing"
fi

# The worktree's ID, as scripts/lib/common.sh computes it there.
name="$(basename "$TARGET")"
id="$name-$(printf '%s' "$TARGET" | shasum -a 256 | cut -c1-6)"
echo "worktree-remove: $TARGET, ID $id"

# 1. Its simulators: every set named by its ID. A booted one is shut down first, because
#    simctl cannot delete it. Simulators named the old way, by the folder's name alone,
#    could belong to another checkout in a folder of the same name, so they are listed for
#    a person to remove and left alone.
knot_select_xcode
xcrun simctl list devices -j | python3 -I -c '
import json, sys
id, name = sys.argv[1], sys.argv[2]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"].startswith(id + "-"):
            print("\t".join(["delete", d["udid"], d["name"], d["state"]]))
        elif d["name"] in (name + "-iphone", name + "-ipad", name + "-watch"):
            print("\t".join(["old", d["udid"], d["name"], d["state"]]))' "$id" "$name" |
    while IFS=$'\t' read -r what udid simulator state; do
        if [[ $what == old ]]; then
            echo "worktree-remove: left $simulator ($udid), named the old way: another checkout may own it."
            echo "worktree-remove: delete it with xcrun simctl delete $udid once you know nothing uses it."
            continue
        fi
        [[ $state == Shutdown ]] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        xcrun simctl delete "$udid" ||
            knot_fail "infra-simulator-delete" "simctl could not delete $simulator ($udid)." \
                "Quit Simulator.app, then rerun scripts/worktree-remove.sh $TARGET." "safe" "the simulators listed before it"
        echo "worktree-remove: deleted the simulator $simulator"
    done

# 2. Its Mac development store: a folder named by its ID. docs/architecture.md §7 puts the
#    Mac store in the app group container when the build has a group, and in the app's own
#    container when it has none, as a build made with the local signing configuration has
#    none. Only the app's own container is read here: macOS guards another app's group container, and reading one
#    can raise a consent dialog that only the owner can answer. So a store in the group is
#    left, and the script says where. Only a folder of exactly the ID's name is removed, and
#    a scan that cannot read the container does not stop the removal.
container="$HOME/Library/Containers/com.p3ob7o.knot.dev"
if [[ -d $container ]]; then
    while IFS= read -r -d '' store; do
        [[ $store == "$container"/*/"$id" ]] || continue
        rm -rf "$store"
        echo "worktree-remove: removed the development store $store"
    done < <(find "$container" -maxdepth 7 -type d -name "$id" -print0 2>/dev/null || true)
fi
echo "worktree-remove: app group containers were not looked at, since reading one can raise a consent dialog."
echo "worktree-remove: a store of this worktree in the development app group, if a build put one there,"
echo "worktree-remove: is ~/Library/Group Containers/group.com.p3ob7o.knot.dev/…/$id; remove it by hand."

# 3. The worktree, with its .build/ and DerivedData inside it.
if ((FORCE)); then
    git -C "$KNOT_ROOT" worktree remove --force "$TARGET"
else
    git -C "$KNOT_ROOT" worktree remove "$TARGET"
fi
git -C "$KNOT_ROOT" worktree prune
echo "worktree-remove: removed the worktree $TARGET"
