#!/bin/bash
# Builds SP-1's throwaway app with the pinned Xcode (docs/plan/SP-1.md).
#
#   Spikes/SP-1/build.sh check            compile for the Simulator and, unsigned, for a device
#   Spikes/SP-1/build.sh sim              build for the Simulator, install on this worktree's
#                                         iPhone simulator, launch with -SP1SelfTest, print the log
#   Spikes/SP-1/build.sh device [UDID]    build for the owner's iPhone with KNOT_SIGNING=team,
#                                         and install it with devicectl when a UDID is given
#
# The Simulator run never opens a microphone: the recorder refuses the hardware input there.
# The device build needs the owner's signing configuration: KNOT_LOCAL_CONFIG names a file that
# sets KNOT_SIGNING = team and DEVELOPMENT_TEAM, and scripts/bootstrap.sh has linked it.

source "$(dirname "$0")/../../scripts/lib/common.sh"
knot_select_xcode

SPIKE="$KNOT_ROOT/Spikes/SP-1"
PROJECT="$SPIKE/SP1.xcodeproj"
DERIVED="$KNOT_BUILD/DerivedData-SP1"
LOGS="$KNOT_LOGS/sp1"
mkdir -p "$LOGS"

generate() {
    knot_write_worktree_config
    (cd "$SPIKE" && xcodegen generate --spec project.yml --quiet)
}

xcb() {
    local log=$1
    shift
    if ! xcodebuild -project "$PROJECT" -scheme SP1 -configuration Debug -derivedDataPath "$DERIVED" \
        COMPILER_INDEX_STORE_ENABLE=NO "$@" >"$LOGS/$log.log" 2>&1; then
        grep -E "error:|warning:" "$LOGS/$log.log" | sort -u | head -40
        knot_fail "sp1-build-$log" "The SP-1 build ($log) failed." "Read $LOGS/$log.log." "safe" "$DERIVED"
    fi
    echo "sp1: $log ok"
}

case ${1:-} in
    check)
        generate
        xcb sim-check -destination "generic/platform=iOS Simulator" KNOT_SIGNING=local build
        xcb device-check -destination "generic/platform=iOS" KNOT_SIGNING=local CODE_SIGNING_ALLOWED=NO build
        ;;
    sim)
        generate
        udid="$("$KNOT_ROOT/scripts/sim.sh" udid iphone)"
        "$KNOT_ROOT/scripts/sim.sh" boot iphone >/dev/null
        xcb sim -destination "id=$udid" KNOT_SIGNING=local build
        app="$DERIVED/Build/Products/Debug-iphonesimulator/SP1.app"
        bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
        group="$(/usr/libexec/PlistBuddy -c 'Print :KnotAppGroup' "$app/Info.plist")"
        case $bundle in *.dev) ;; *) knot_fail "sp1-identifier" "The spike's bundle ID is $bundle." \
            "The spike uses the development identifiers only (docs/architecture.md §7)." "safe" "nothing" ;; esac
        xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
        xcrun simctl install "$udid" "$app"
        log="$(xcrun simctl get_app_container "$udid" "$bundle" "$group")/SP1/events.jsonl"
        : >"$log" 2>/dev/null || true
        xcrun simctl launch "$udid" "$bundle" -SP1SelfTest >/dev/null
        for _ in $(seq 1 30); do
            grep -q '"selftest.end"\|"selftest.refused"' "$log" 2>/dev/null && break
            sleep 1
        done
        sleep 2
        echo "sp1: log at $log"
        cat "$log"
        ;;
    device)
        generate
        [[ -L $KNOT_CONFIG/Local.xcconfig ]] ||
            knot_fail "sp1-no-signing" "No local signing configuration is linked." \
                "Set KNOT_LOCAL_CONFIG to the owner's Local.xcconfig and run scripts/bootstrap.sh." "safe" "nothing"
        xcb device -destination "generic/platform=iOS" -allowProvisioningUpdates build
        app="$DERIVED/Build/Products/Debug-iphoneos/SP1.app"
        echo "sp1: built $app"
        if [[ -n ${2:-} ]]; then
            xcrun devicectl device install app --device "$2" "$app"
            echo "sp1: installed on $2"
        fi
        ;;
    *)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
