#!/bin/bash
# This worktree's simulators: a small fixed set, named by the worktree's ID, so that two
# worktrees never share a simulator, a store or a recording state (docs/architecture.md
# §7, §18). Simulators of other projects on this Mac are never touched.
#
#   scripts/sim.sh ensure          create the set if it is missing, and print it
#   scripts/sim.sh list            print role, name, UDID and state
#   scripts/sim.sh udid <role>     print the UDID of iphone, ipad or watch
#   scripts/sim.sh boot <role>     boot one and wait until it is ready
#   scripts/sim.sh shutdown        shut down the set
#   scripts/sim.sh delete          delete every set named by this worktree's ID
#
# The ID is the worktree's folder name and a short hash of its path, as in
# wp-01-tooling-1a2b3c-iphone. Each simulator runs the runtime that matches the pinned
# SDK. KNOT_SIM_IOS_VERSION and KNOT_SIM_WATCHOS_VERSION ask for another runtime, such as
# 27.0 for the nightly run on the oldest system Knot supports; that set's names end in the
# version, as in wp-01-tooling-1a2b3c-ios27.0-iphone, so it lives beside the usual one. An
# Xcode named by KNOT_XCODE that is not the pinned one gets a set of its own the same way,
# as in wp-01-tooling-1a2b3c-xcode27.3-iphone.

source "$(dirname "$0")/lib/common.sh"

# Every simctl call of this script goes through here, with a limit (KNOT_SIMCTL_LIMIT, 120
# seconds; a boot's wait has its own), so that a CoreSimulator that no longer answers, or
# a simulator stuck in a shutdown, fails the call instead of holding the run.
simctl() {
    local status=0 limit=${KNOT_SIMCTL_LIMIT:-120}
    knot_limit "$limit" xcrun simctl "$@" || status=$?
    if ((KNOT_LIMIT_HIT)); then
        echo "sim: xcrun simctl $1 did not end within ${limit}s. CoreSimulator may be stuck, or a simulator; scripts/sim.sh shutdown ends this worktree's, and quitting Simulator.app may help." >&2
    fi
    return "$status"
}
knot_select_xcode

ROLES="iphone ipad watch"

set_suffix() {
    local suffix=""
    # An Xcode named by KNOT_XCODE that is not the pinned one keeps a set of its own, so
    # that alternating the two does not make the usual set again each time.
    [[ -n ${KNOT_XCODE:-} && -n ${KNOT_XCODE_NOTE:-} && $KNOT_XCODE_NOTE == *"named by KNOT_XCODE"* ]] &&
        suffix="-xcode$KNOT_XCODE_VERSION"
    [[ -n ${KNOT_SIM_IOS_VERSION:-} ]] && suffix="$suffix-ios$KNOT_SIM_IOS_VERSION"
    [[ -n ${KNOT_SIM_WATCHOS_VERSION:-} ]] && suffix="$suffix-watchos$KNOT_SIM_WATCHOS_VERSION"
    printf '%s' "$suffix"
}
name_of() { printf '%s%s-%s' "$KNOT_WORKTREE_ID" "$(set_suffix)" "$1"; }

# Every simulator on this Mac, available or not, as lines of: udid, name, state,
# availability, runtime, device type.
devices() {
    simctl list devices -j | python3 -I -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        print("\t".join([d["udid"], d["name"], d["state"], "available" if d.get("isAvailable", True) else "unavailable",
                         runtime, d.get("deviceTypeIdentifier", "")]))'
}

field() { awk -F'\t' -v n="$1" -v want="$2" -v col="$3" '$n == want { print $col; exit }'; }

# The UDID of the available simulator with this name, or nothing.
udid_of() { devices | awk -F'\t' -v want="$1" '$2 == want && $4 == "available" { print $1; exit }'; }

# The runtime that matches the pinned SDK, or the version asked for: the same version if it
# is installed, else the newest older one of the same major version, else the oldest newer
# one. A runtime newer than the SDK, such as a beta's, comes last. Only a runtime that
# supports the device type counts: some runtimes serve one device model alone.
runtime_for() {
    local platform=$1 sdk=$2 type=$3 version
    case $platform in
        iOS) version="${KNOT_SIM_IOS_VERSION:-}" ;;
        watchOS) version="${KNOT_SIM_WATCHOS_VERSION:-}" ;;
    esac
    [[ -n $version ]] || version="$(xcrun --sdk "$sdk" --show-sdk-version)"
    simctl list runtimes -j | python3 -I -c '
import json, sys
platform, sdk, device = sys.argv[1], [int(p) for p in sys.argv[2].split(".")], sys.argv[3]
def key(r): return [int(p) for p in r["version"].split(".")]
found = [r for r in json.load(sys.stdin)["runtimes"]
         if r["platform"] == platform and r["isAvailable"] and key(r)[0] == sdk[0]
         and any(t["identifier"] == device for t in r.get("supportedDeviceTypes", []))]
older = sorted((r for r in found if key(r) <= sdk), key=key)
newer = sorted((r for r in found if key(r) > sdk), key=key)
choice = older[-1] if older else (newer[0] if newer else None)
print(choice["identifier"] if choice else "")' "$platform" "$version" "$type"
}

# The first device type in the list that this Xcode knows.
device_type() {
    simctl list devicetypes -j | python3 -I -c '
import json, sys
known = {t["identifier"] for t in json.load(sys.stdin)["devicetypes"]}
for wanted in sys.argv[1:]:
    if "com.apple.CoreSimulator.SimDeviceType." + wanted in known:
        print("com.apple.CoreSimulator.SimDeviceType." + wanted); break' "$@"
}

type_for() {
    case $1 in
        iphone) device_type iPhone-17-Pro iPhone-18-Pro iPhone-17 ;;
        ipad) device_type iPad-Pro-13-inch-M5-12GB iPad-Pro-13-inch-M4-8GB iPad-Air-13-inch-M3 ;;
        watch) device_type Apple-Watch-Series-11-46mm Apple-Watch-Series-12-46mm Apple-Watch-Series-10-46mm ;;
    esac
}

wanted_runtime() {
    # wanted_runtime <role> <device type>
    if [[ $1 == watch ]]; then runtime_for watchOS watchsimulator "$2"; else runtime_for iOS iphonesimulator "$2"; fi
}

# Shuts a simulator down if it is booted, then deletes it. A booted simulator makes
# `simctl delete` fail, so the shutdown comes first.
remove() {
    local udid=$1 name=$2 state
    state="$(devices | field 1 "$udid" 3)"
    if [[ $state != Shutdown && -n $state ]]; then
        simctl shutdown "$udid" >/dev/null 2>&1 || true
    fi
    simctl delete "$udid" 2>/dev/null ||
        knot_fail "infra-simulator-delete" "simctl could not delete the simulator $name ($udid), state $state." \
            "Shut it down (xcrun simctl shutdown $udid), or quit Simulator.app, then rerun scripts/sim.sh ensure." \
            "safe" "the simulators of this worktree that came before it in the list"
}

create() {
    local role=$1 name type runtime
    name="$(name_of "$role")"
    type="$(type_for "$role")"
    [[ -n $type ]] && runtime="$(wanted_runtime "$role" "$type")"
    if [[ -z $type || -z ${runtime:-} ]]; then
        knot_fail "infra-simulator-runtime" "No device type or runtime for the $role simulator with $(knot_xcode_label)." \
            "Install the runtime: DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -downloadPlatform $([[ $role == watch ]] && echo watchOS || echo iOS)" \
            "safe" "nothing"
    fi
    simctl create "$name" "$type" "$runtime" ||
        knot_fail "infra-simulator-create" "simctl could not create $name on $runtime." \
            "Check the runtime with xcrun simctl list runtimes, then rerun scripts/sim.sh ensure." "safe" \
            "the simulators of this worktree that came before it"
}

ensure() {
    local role name udid line
    for role in $ROLES; do
        name="$(name_of "$role")"
        # A simulator of this name left unavailable, as when its runtime was removed, is
        # deleted, so that no duplicate appears beside it.
        devices | awk -F'\t' -v want="$name" '$2 == want && $4 == "unavailable" { print $1 }' |
            while IFS= read -r udid; do remove "$udid" "$name"; done
        udid="$(udid_of "$name")"
        if [[ -n $udid ]]; then
            # A simulator left on another runtime, such as one made with the beta, is made
            # again on the runtime of the pinned SDK.
            line="$(devices | awk -F'\t' -v u="$udid" '$1 == u')"
            local runtime type wanted
            runtime="$(printf '%s' "$line" | cut -f5)"
            type="$(printf '%s' "$line" | cut -f6)"
            wanted="$(wanted_runtime "$role" "$type")"
            if [[ -n $wanted && $runtime != "$wanted" ]]; then
                remove "$udid" "$name"
                udid=""
            fi
        fi
        [[ -n $udid ]] || create "$role" >/dev/null
    done
    # Pair the watch with the iPhone, as the companion app expects.
    local phone watch
    phone="$(udid_of "$(name_of iphone)")"
    watch="$(udid_of "$(name_of watch)")"
    if ! simctl list pairs | grep -e "$watch" >/dev/null; then
        simctl pair "$watch" "$phone" >/dev/null ||
            knot_fail "infra-simulator-pair" "simctl could not pair $(name_of watch) with $(name_of iphone)." \
                "Rerun scripts/sim.sh ensure. If it fails again, delete the set with scripts/sim.sh delete." "safe" \
                "this worktree's simulators were created"
    fi
    list
    old_names
}

# Simulators named the old way, by a folder's name without the hash, are left alone: a
# name like knot-iphone cannot tell which checkout made it, and another checkout in a
# folder of the same name may still use it. They are listed for a person to remove.
old_names() {
    local found
    found="$(devices | awk -F'\t' -v old="$KNOT_WORKTREE" '$2 == old "-iphone" || $2 == old "-ipad" || $2 == old "-watch" { print "  " $2 " (" $1 ")" }')"
    if [[ -n $found ]]; then
        echo "sim: simulators named the old way, by the folder name $KNOT_WORKTREE alone, are left alone because"
        echo "sim: another checkout in a folder of that name may own them. Delete one with xcrun simctl delete <UDID>"
        echo "sim: once you know nothing uses it:"
        printf '%s\n' "$found"
    fi
}

list() {
    local role name udid state
    for role in $ROLES; do
        name="$(name_of "$role")"
        udid="$(udid_of "$name")"
        state="$( [[ -n $udid ]] && devices | field 1 "$udid" 3 || echo missing)"
        printf '%-7s %-60s %-36s %s\n' "$role" "$name" "${udid:--}" "$state"
    done
}

require_role() {
    case ${1:-} in iphone | ipad | watch) ;; *)
        knot_fail "sim-usage" "Unknown simulator role: ${1:-none}" "Use iphone, ipad or watch." "safe" "nothing" ;;
    esac
    local udid
    udid="$(udid_of "$(name_of "$1")")"
    [[ -n $udid ]] || knot_fail "sim-missing" "This worktree has no $1 simulator." "Run scripts/sim.sh ensure." "safe" "nothing"
    printf '%s' "$udid"
}

case ${1:-} in
    ensure) ensure ;;
    list) list ;;
    udid) require_role "${2:-}"; echo ;;
    boot)
        udid="$(require_role "${2:-}")"
        # A boot that never finishes would hold the run: it has a limit (knot_sim_call), and a
        # simulator still booting at the limit is shut down, so the run leaves none behind.
        if ! why="$(knot_sim_call "${KNOT_SIM_BOOT_LIMIT:-300}" "bootstatus" "$(name_of "$2")" \
            xcrun simctl bootstatus "$udid" -b 2>&1 >/dev/null)"; then
            simctl shutdown "$udid" >/dev/null 2>&1 || true
            knot_fail "infra-simulator-boot" "The $2 simulator ($udid) did not boot, and was shut down. $(tail -n 1 <<<"$why")" \
                "Rerun the step. If it fails again, run scripts/sim.sh delete and scripts/sim.sh ensure." "safe" "nothing"
        fi ;;
    shutdown)
        devices | awk -F'\t' -v id="$KNOT_WORKTREE_ID" 'index($2, id "-") == 1 && $3 != "Shutdown" { print $1 }' |
            while IFS= read -r udid; do simctl shutdown "$udid" 2>/dev/null || true; done ;;
    delete)
        # Every simulator of this worktree: each set named by its ID, available or not. Old
        # names, without the hash, are listed and left alone.
        devices | awk -F'\t' -v id="$KNOT_WORKTREE_ID" 'index($2, id "-") == 1 { print $1 "\t" $2 }' |
            while IFS=$'\t' read -r udid name; do remove "$udid" "$name"; done
        old_names ;;
    -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) knot_fail "sim-usage" "Unknown command: ${1:-none}." \
        "Use ensure, list, udid <role>, boot <role>, shutdown or delete (scripts/sim.sh --help)." "safe" "nothing" ;;
esac
