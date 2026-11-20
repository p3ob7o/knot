#!/bin/bash
# Builds the SP-2 spike, and installs it. The spike never merges (docs/plan/SP-2.md).
#
#   Spikes/SP-2/build.sh sim       build for this worktree's simulators and install the
#                                  iPhone app on its iPhone, the Watch app on its Watch
#   Spikes/SP-2/build.sh check     also compile for devices, unsigned, to type-check the
#                                  device code paths
#   Spikes/SP-2/build.sh device    build signed with the owner's team and install on the
#                                  connected iPhone and Watch (needs KNOT_SIGNING=team in
#                                  Local.xcconfig, see Spikes/SP-2/README.md)
#
# It uses the Xcode that .xcode-version pins, and this worktree's own build folder.

source "$(dirname "$0")/../../scripts/lib/common.sh"
knot_select_xcode

SPIKE="$KNOT_ROOT/Spikes/SP-2"
DERIVED="$KNOT_BUILD/SP2-DerivedData"
mkdir -p "$KNOT_BUILD/logs"

generate() {
    command -v xcodegen >/dev/null || knot_fail "infra-xcodegen" "XcodeGen is missing." "Run scripts/bootstrap.sh." "safe" "nothing"
    (cd "$SPIKE" && xcodegen generate --quiet --spec project.yml)
}

build() {
    local destination=$1 log=$2
    shift 2
    if ! xcodebuild -project "$SPIKE/SP2.xcodeproj" -scheme SP2-iOS -configuration Debug \
        -destination "$destination" -derivedDataPath "$DERIVED" COMPILER_INDEX_STORE_ENABLE=NO "$@" \
        build >"$log" 2>&1; then
        # Xcode writes the team's prefix into the log: ten upper-case letters and digits.
        grep -E "error:|warning:" "$log" | sort -u | head -40 | sed -E 's/[A-Z0-9]{10}/<team>/g' >&2
        knot_fail "sp2-build" "The SP-2 build for $destination failed." "Read $log." "safe" "the build folder"
    fi
    echo "sp2: built for $destination ($(grep -c 'warning:' "$log" || true) warning lines)"
}

case ${1:-} in
    sim)
        generate
        build "generic/platform=iOS Simulator" "$KNOT_BUILD/logs/sp2-sim.log" KNOT_SIGNING=local
        "$KNOT_ROOT/scripts/sim.sh" ensure >/dev/null
        phone="$("$KNOT_ROOT/scripts/sim.sh" udid iphone)"
        watch="$("$KNOT_ROOT/scripts/sim.sh" udid watch)"
        "$KNOT_ROOT/scripts/sim.sh" boot iphone
        "$KNOT_ROOT/scripts/sim.sh" boot watch
        products="$DERIVED/Build/Products/Debug-iphonesimulator"
        # The iPhone app first, then the Watch app. Installing the iPhone app does not install
        # its Watch app on a simulator, and the phone's session reports the Watch app as not
        # installed for several seconds after the Watch install, and drops what the Watch
        # sends meanwhile. So wait before launching either app.
        xcrun simctl install "$phone" "$products/SP2.app"
        xcrun simctl install "$watch" "$products/SP2.app/Watch/SP2.app"
        sleep 20
        echo "sp2: installed on $phone (iPhone) and $watch (Watch)"
        ;;
    check)
        generate
        build "generic/platform=iOS Simulator" "$KNOT_BUILD/logs/sp2-sim.log" KNOT_SIGNING=local
        build "generic/platform=iOS" "$KNOT_BUILD/logs/sp2-device.log" KNOT_SIGNING=local CODE_SIGNING_ALLOWED=NO
        ;;
    device)
        # Signing with the team: KNOT_LOCAL_CONFIG names the local configuration, which is
        # given to this build alone as -xcconfig, never linked into the worktree.
        signing=()
        [[ -n ${KNOT_LOCAL_CONFIG:-} ]] && signing=(-xcconfig "$KNOT_LOCAL_CONFIG")
        generate
        build "generic/platform=iOS" "$KNOT_BUILD/logs/sp2-device.log" "${signing[@]}" -allowProvisioningUpdates -allowProvisioningDeviceRegistration
        app="$DERIVED/Build/Products/Debug-iphoneos/SP2.app"
        # Read whole before matching: with pipefail, `grep -q` closing the pipe early fails codesign.
        signature="$(codesign -dv "$app" 2>&1 || true)"
        [[ $signature == *$'\nTeamIdentifier='[A-Z0-9]* ]] || knot_fail "sp2-unsigned" "The device build is not signed with a team." \
            "Set KNOT_LOCAL_CONFIG to the local configuration that sets KNOT_SIGNING = team and DEVELOPMENT_TEAM." "safe" "nothing"
        echo "sp2: signed with a team"
        # The iPhone app first, then the Watch app embedded in it. SP2_PHONE and SP2_WATCH are
        # the devices' identifiers from `xcrun devicectl list devices`.
        if [[ -n ${SP2_PHONE:-} ]]; then
            xcrun devicectl device install app --device "$SP2_PHONE" "$app" >"$KNOT_BUILD/logs/sp2-install-phone.log" 2>&1 ||
                knot_fail "sp2-install-phone" "The install on the iPhone failed." "Read $KNOT_BUILD/logs/sp2-install-phone.log." "safe" "nothing"
            echo "sp2: installed on the iPhone"
        fi
        if [[ -n ${SP2_WATCH:-} ]]; then
            xcrun devicectl device install app --device "$SP2_WATCH" "$app/Watch/SP2.app" >"$KNOT_BUILD/logs/sp2-install-watch.log" 2>&1 ||
                knot_fail "sp2-install-watch" "The install on the Watch failed." "Read $KNOT_BUILD/logs/sp2-install-watch.log." "safe" "nothing"
            echo "sp2: installed on the Watch"
        fi
        ;;
    *)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
