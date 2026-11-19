#!/bin/bash
# This worktree's simulators: a small fixed set, named after the worktree, so that two
# worktrees never share a simulator, a store or a recording state (docs/architecture.md
# §7, §18). Simulators of other projects on this Mac are never touched.
#
#   scripts/sim.sh ensure          create the set if it is missing, and print it
#   scripts/sim.sh list            print role, name, UDID and state
#   scripts/sim.sh udid <role>     print the UDID of iphone, ipad or watch
#   scripts/sim.sh boot <role>     boot one and wait until it is ready
#   scripts/sim.sh shutdown        shut down the set
#   scripts/sim.sh delete          delete the set

source "$(dirname "$0")/lib/common.sh"
knot_select_xcode

ROLES="iphone ipad watch"

name_of() { printf '%s-%s' "$KNOT_WORKTREE" "$1"; }

# Prints the UDID of an existing simulator with this name, or nothing.
udid_of() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)' "$1"
}

# The runtime of a platform that matches the pinned SDK: the one of the same version if it
# is installed, else the newest older one of the same major version, else the oldest newer
# one. A runtime newer than the SDK, such as a beta's, comes last. Only a runtime that
# supports the device type counts: some runtimes serve one device model alone.
runtime_for() {
    local platform=$1 sdk=$2 type=$3 version
    version="$(xcrun --sdk "$sdk" --show-sdk-version)"
    xcrun simctl list runtimes -j | python3 -I -c '
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

# The runtime identifier of an existing simulator.
runtime_of() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if any(d["udid"] == sys.argv[1] for d in devices):
        print(runtime); break' "$1"
}

# The device type identifier of an existing simulator.
type_of() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["udid"] == sys.argv[1]:
            print(d["deviceTypeIdentifier"]); sys.exit(0)' "$1"
}

# The first device type in the list that this Xcode knows.
device_type() {
    xcrun simctl list devicetypes -j | python3 -I -c '
import json, sys
known = {t["identifier"] for t in json.load(sys.stdin)["devicetypes"]}
for wanted in sys.argv[1:]:
    if "com.apple.CoreSimulator.SimDeviceType." + wanted in known:
        print("com.apple.CoreSimulator.SimDeviceType." + wanted); break' "$@"
}

create() {
    local role=$1 name type runtime
    name="$(name_of "$role")"
    case $role in
        iphone)
            type="$(device_type iPhone-17-Pro iPhone-18-Pro iPhone-17)"
            runtime="$(runtime_for iOS iphonesimulator "$type")" ;;
        ipad)
            type="$(device_type iPad-Pro-13-inch-M5-12GB iPad-Pro-13-inch-M4-8GB iPad-Air-13-inch-M3)"
            runtime="$(runtime_for iOS iphonesimulator "$type")" ;;
        watch)
            type="$(device_type Apple-Watch-Series-11-46mm Apple-Watch-Series-12-46mm Apple-Watch-Series-10-46mm)"
            runtime="$(runtime_for watchOS watchsimulator "$type")" ;;
    esac
    if [[ -z $type || -z $runtime ]]; then
        knot_fail "infra-simulator-runtime" "No device type or runtime for the $role simulator with $(knot_xcode_label)." \
            "Install the runtime: DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -downloadPlatform $([[ $role == watch ]] && echo watchOS || echo iOS)" \
            "safe" "nothing"
    fi
    xcrun simctl create "$name" "$type" "$runtime"
}

ensure() {
    local role udid wanted
    for role in $ROLES; do
        udid="$(udid_of "$(name_of "$role")")"
        if [[ -n $udid ]]; then
            # A simulator left on another runtime, such as one made with the beta, is made
            # again on the runtime of the pinned SDK.
            local type
            type="$(type_of "$udid")"
            if [[ $role == watch ]]; then
                wanted="$(runtime_for watchOS watchsimulator "$type")"
            else
                wanted="$(runtime_for iOS iphonesimulator "$type")"
            fi
            if [[ -n $wanted && "$(runtime_of "$udid")" != "$wanted" ]]; then
                xcrun simctl delete "$udid"
                udid=""
            fi
        fi
        [[ -n $udid ]] || create "$role" >/dev/null
    done
    # Pair the watch with the iPhone, as the companion app expects.
    local phone watch
    phone="$(udid_of "$(name_of iphone)")"
    watch="$(udid_of "$(name_of watch)")"
    if ! xcrun simctl list pairs | grep -e "$watch" >/dev/null; then
        xcrun simctl pair "$watch" "$phone" >/dev/null
    fi
    list
}

list() {
    local role name udid state
    for role in $ROLES; do
        name="$(name_of "$role")"
        udid="$(udid_of "$name")"
        state="$( [[ -n $udid ]] && xcrun simctl list devices | grep "$udid" | sed -E 's/.*\(([A-Za-z]+)\) *$/\1/' || echo missing)"
        printf '%-7s %-50s %-36s %s\n' "$role" "$name" "${udid:--}" "$state"
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
        xcrun simctl bootstatus "$udid" -b >/dev/null ;;
    shutdown)
        for role in $ROLES; do
            udid="$(udid_of "$(name_of "$role")")"
            [[ -n $udid ]] && xcrun simctl shutdown "$udid" 2>/dev/null || true
        done ;;
    delete)
        for role in $ROLES; do
            udid="$(udid_of "$(name_of "$role")")"
            [[ -n $udid ]] && xcrun simctl delete "$udid"
        done
        true ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) knot_fail "sim-usage" "Unknown command: ${1:-none}." \
        "Use ensure, list, udid <role>, boot <role>, shutdown or delete (scripts/sim.sh --help)." "safe" "nothing" ;;
esac
