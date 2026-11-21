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
[[ -d $TARGET ]] || knot_fail "worktree-remove-missing" "$(knot_home_path "$TARGET") is not a folder." "Name a worktree from git worktree list." "safe" "nothing"
TARGET="$(cd "$TARGET" && pwd -P)"
# The lines it prints end in the journal, so each path in them is shown with no home folder.
SHOWN="$(knot_home_path "$TARGET")"

# It must be a worktree of this repository, and not the main checkout.
main="$(git -C "$KNOT_ROOT" worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
main="$(cd "$main" && pwd -P)"
found=0
while IFS= read -r tree; do
    if [[ "$(cd "$tree" 2>/dev/null && pwd -P)" == "$TARGET" ]]; then found=1; fi
done < <(git -C "$KNOT_ROOT" worktree list --porcelain | awk '/^worktree / { print substr($0, 10) }')
((found)) ||
    knot_fail "worktree-remove-not-worktree" "$SHOWN is not a worktree of this repository." \
        "Name a folder from git worktree list." "safe" "nothing"
[[ $TARGET != "$main" ]] ||
    knot_fail "worktree-remove-main" "$SHOWN is the main checkout, which is never removed." \
        "Name another worktree." "safe" "nothing"
if ((!FORCE)) && [[ -n "$(git -C "$TARGET" status --porcelain)" ]]; then
    knot_fail "worktree-remove-dirty" "$SHOWN has changes that are not committed." \
        "Commit or move them, or pass --force to remove them with the worktree." "safe" "nothing"
fi

# The worktree's ID, as scripts/lib/common.sh computes it there.
name="$(basename "$TARGET")"
id="$name-$(printf '%s' "$TARGET" | shasum -a 256 | cut -c1-6)"
echo "worktree-remove: $SHOWN, ID $id"

# 1. Its simulators: every set named by its ID. A booted one is shut down first, because
#    simctl cannot delete it. Simulators named the old way, by the folder's name alone,
#    could belong to another checkout in a folder of the same name, so they are listed for
#    a person to remove and left alone. Every simctl call has a limit, since CoreSimulator
#    can hang, and a dialog can hold it.
knot_select_xcode
simctl_limit=${KNOT_SIMCTL_LIMIT:-120}
devices_status=0
devices="$(knot_limit "$simctl_limit" xcrun simctl list devices -j)" || devices_status=$?
if ((devices_status == 124)); then
    knot_fail "infra-simulators-silent" "xcrun simctl list devices did not answer within ${simctl_limit}s." \
        "$(knot_dialog_message "The list of simulators" "$simctl_limit") Then rerun scripts/worktree-remove.sh." "safe" "nothing"
fi
((devices_status == 0)) ||
    knot_fail "infra-simulators-list" "xcrun simctl list devices failed with status $devices_status." \
        "Run xcrun simctl list devices to see why, then rerun scripts/worktree-remove.sh." "safe" "nothing"
while IFS=$'\t' read -r what udid simulator state; do
    if [[ $what == old ]]; then
        echo "worktree-remove: left $simulator ($udid), named the old way: another checkout may own it."
        echo "worktree-remove: delete it with xcrun simctl delete $udid once you know nothing uses it."
        continue
    fi
    [[ $state == Shutdown ]] || knot_sim_call "$simctl_limit" shutdown "$simulator" xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    why="$(knot_sim_call "$simctl_limit" delete "$simulator" xcrun simctl delete "$udid" 2>&1 >/dev/null)" ||
        knot_fail "infra-simulator-delete" "simctl could not delete $simulator ($udid). $why" \
            "Quit Simulator.app, then rerun scripts/worktree-remove.sh on $SHOWN." "safe" "the simulators listed before it"
    echo "worktree-remove: deleted the simulator $simulator"
done < <(printf '%s\n' "$devices" | python3 -I -c '
import json, sys
id, name = sys.argv[1], sys.argv[2]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"].startswith(id + "-"):
            print("\t".join(["delete", d["udid"], d["name"], d["state"]]))
        elif d["name"] in (name + "-iphone", name + "-ipad", name + "-watch"):
            print("\t".join(["old", d["udid"], d["name"], d["state"]]))' "$id" "$name")

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
        echo "worktree-remove: removed the development store $(knot_home_path "$store")"
    done < <(find "$container" -maxdepth 7 -type d -name "$id" -print0 2>/dev/null || true)
fi
echo "worktree-remove: app group containers were not looked at, since reading one can raise a consent dialog."
echo "worktree-remove: a store of this worktree in the development app group, if a build put one there,"
echo "worktree-remove: is $(knot_home_path "$HOME/Library/Group Containers/group.com.p3ob7o.knot.dev")/…/$id; remove it by hand."

# 3. The worktree, with its .build/ and DerivedData inside it.
if ((FORCE)); then
    git -C "$KNOT_ROOT" worktree remove --force "$TARGET"
else
    git -C "$KNOT_ROOT" worktree remove "$TARGET"
fi
git -C "$KNOT_ROOT" worktree prune
echo "worktree-remove: removed the worktree $SHOWN"
