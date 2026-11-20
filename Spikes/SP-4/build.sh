#!/bin/bash
# Builds SP-4's throwaway app with the pinned Xcode (docs/plan/SP-4.md).
#
#   Spikes/SP-4/build.sh check       generate, build the Mac app (signed ad hoc, sandboxed)
#                                    and the iOS app for the Simulator, both signed locally
#   Spikes/SP-4/build.sh selftest    build the Mac app, then run its self-test, which drives
#                                    the merge core, the mapping and the adapter's testable
#                                    half and quits by itself
#   Spikes/SP-4/build.sh probe       type-check each line of Probes/no-public-init.txt
#                                    against the pinned macOS SDK: every CloudKit type the
#                                    note names must fail to construct, every control must not
#
# Stage 2, simulators only, signed with the owner's team (KNOT_LOCAL_CONFIG linked by
# scripts/bootstrap.sh). ENV is Development (the default) or Production, which names the
# throwaway container alone:
#   Spikes/SP-4/build.sh sim-build [ENV]          build the iOS app for the Simulator, team-signed
#   Spikes/SP-4/build.sh sim-install ROLE [ENV]   boot the worktree's iphone or ipad, install it
#   Spikes/SP-4/build.sh live ROLE ARGS…          run one LiveRunner step there and print it
#
# The Mac app is never signed with the team: a team-signed Mac build of the development
# identifiers raises a consent dialog on the build Mac that only the owner can answer.

source "$(dirname "$0")/../../scripts/lib/common.sh"
knot_select_xcode

SPIKE="$KNOT_ROOT/Spikes/SP-4"
PROJECT="$SPIKE/SP4.xcodeproj"
DERIVED="$KNOT_BUILD/DerivedData-SP4"
LOGS="$KNOT_LOGS/sp4"
MAC_APP="$DERIVED/Build/Products/Debug/SP4.app"
mkdir -p "$LOGS"

BUNDLE_ID=com.p3ob7o.knot.dev

if [[ ${KNOT_SIGNING:-local} != local ]]; then
    knot_fail "sp4-signing" "Set no KNOT_SIGNING for this script." \
        "The Mac app is always local; sim-build signs the iOS app with the team itself." "safe" "nothing"
fi

generate() {
    knot_write_worktree_config
    (cd "$SPIKE" && xcodegen generate --spec project.yml --quiet)
}

# build SCHEME DESTINATION [SIGNING [ENV]]. Never passes -allowProvisioningUpdates, so a
# build cannot register anything in the owner's developer account.
build() {
    local scheme=$1 destination=$2 signing=${3:-local} env=${4:-Development}
    local derived="$DERIVED" log="$LOGS/build-$1-$signing-$env.log"
    [[ $signing == team ]] && derived="$DERIVED-team-$env"
    local extra=()
    [[ ${KNOT_AGENT:-} == 1 ]] && extra+=(COMPILER_INDEX_STORE_ENABLE=NO)
    if ! "$KNOT_SCRIPTS/build-slot.sh" run --label "sp4 $scheme $signing" -- \
        xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Debug -derivedDataPath "$derived" \
        -destination "$destination" KNOT_SIGNING="$signing" SP4_CLOUD_ENVIRONMENT="$env" \
        ${extra[@]+"${extra[@]}"} build >"$log" 2>&1; then
        # The log holds the team's prefix; print only error lines, with it taken out.
        grep -E "error:" "$log" | grep -v -E "TeamIdentifierPrefix|AppIdentifierPrefix" |
            sed -E 's/[A-Z0-9]{10}\./<team>./g' | sort -u | head -20
        knot_fail "sp4-build" "The SP-4 build of $scheme ($signing, $env) failed." "Read $log (it holds the team's prefix)." "safe" "$derived"
    fi
    echo "sp4: built $scheme ($signing, $env)"
}

sim_app() { printf '%s/Build/Products/Debug-iphonesimulator/SP4.app' "$DERIVED-team-${1:-Development}"; }

# What the simulator build carries, with identifiers that hold the team's prefix left out.
check_sim() {
    local app entitlements
    app="$(sim_app "$1")"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :KnotSyncAvailable' "$app/Info.plist")" == YES ]] ||
        knot_fail "sp4-sim-sync" "The team-signed simulator build says sync is unavailable." "Check the local config link." "safe" "nothing"
    # A simulator build is signed ad hoc and keeps its entitlements in the executable's
    # __TEXT,__entitlements section, which the simulator honours in place of a profile.
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/sp4-ent.XXXXXX")"
    lipo "$app/SP4" -thin arm64 -output "$tmp/thin"
    segedit "$tmp/thin" -extract __TEXT __entitlements "$tmp/ent.plist"
    entitlements="$(plutil -convert json -o - "$tmp/ent.plist")"
    python3 -I -c '
import json,sys
e=json.loads(sys.argv[1] or "{}")
keep={k:v for k,v in e.items() if k in ("aps-environment","com.apple.developer.icloud-container-identifiers",
      "com.apple.developer.icloud-services","com.apple.developer.icloud-container-environment","get-task-allow")}
print("sp4: simulated entitlements, team identifiers left out:", json.dumps(keep, sort_keys=True))
print("sp4: other keys present:", sorted(k for k in e if k not in keep))
' "$entitlements"
    python3 -I -c '
import json,sys
e=json.loads(sys.argv[1] or "{}")
bad=[c for c in e.get("com.apple.developer.icloud-container-identifiers",[]) if c not in ("iCloud.com.p3ob7o.knot.dev","iCloud.com.p3ob7o.knot.spike4")]
prod=e.get("com.apple.developer.icloud-container-environment")=="Production"
if bad or (prod and e.get("com.apple.developer.icloud-container-identifiers")!=["iCloud.com.p3ob7o.knot.spike4"]):
    sys.exit(1)
' "$entitlements" || knot_fail "sp4-container" "The build names a container it must not." "Check Config/SP4-iOS-team*.entitlements." "safe" "nothing"
}

udid() { "$KNOT_SCRIPTS/sim.sh" udid "$1"; }

# The Mac build is sandboxed, uses the development identifiers and has no iCloud entitlement.
check_mac() {
    local bundle entitlements
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MAC_APP/Contents/Info.plist")"
    case $bundle in *.dev) ;; *) knot_fail "sp4-identifier" "The spike's bundle ID is $bundle." \
        "The spike uses the development identifiers only (docs/architecture.md §7)." "safe" "nothing" ;; esac
    entitlements="$(codesign -d --entitlements - --xml "$MAC_APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)"
    [[ $entitlements == *'"com.apple.security.app-sandbox":true'* ]] ||
        knot_fail "sp4-not-sandboxed" "The Mac app does not carry the sandbox." "Check Config/SP4-macOS-local.entitlements." "safe" "nothing"
    [[ $entitlements != *icloud* && $entitlements != *aps-environment* ]] ||
        knot_fail "sp4-icloud" "The stage 1 build carries an iCloud or push entitlement." "Remove it." "safe" "nothing"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :KnotSyncAvailable' "$MAC_APP/Contents/Info.plist")" == NO ]] ||
        knot_fail "sp4-sync-available" "The stage 1 build says sync is available." "Build with KNOT_SIGNING=local." "safe" "nothing"
    echo "sp4: bundle $bundle, entitlements $entitlements, KnotSyncAvailable NO"
}

probe() {
    local folder sdk failures=0 line expr expect n=0
    folder="$(mktemp -d "${TMPDIR:-/tmp}/sp4-probe.XXXXXX")"
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    echo "sp4: probing against $(basename "$sdk")"
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        n=$((n + 1))
        if [[ $line == ok:* ]]; then expect=compiles; expr="${line#ok: }"; else expect=fails; expr="$line"; fi
        printf 'import CloudKit\n@available(macOS 27.0, *)\nfunc probe() { _ = %s }\n' "$expr" >"$folder/p$n.swift"
        local out status=0
        out="$(xcrun --sdk macosx swiftc -typecheck -swift-version 6 -target arm64-apple-macos27.0 "$folder/p$n.swift" 2>&1)" || status=$?
        local reason
        reason="$(grep -m1 -o 'error: .*' <<<"$out" | sed 's/^error: //' || true)"
        if [[ $expect == fails && $status -ne 0 ]]; then
            echo "  no init   $expr"
            echo "            $reason"
        elif [[ $expect == compiles && $status -eq 0 ]]; then
            echo "  compiles  $expr"
        else
            echo "  UNEXPECTED ($expect) $expr"
            [[ -n $reason ]] && echo "            $reason"
            failures=$((failures + 1))
        fi
    done <"$SPIKE/Probes/no-public-init.txt"
    echo "sp4: probe $n lines, $failures unexpected; the probe files are in $folder"
    [[ $failures -eq 0 ]]
}

case ${1:-} in
    check)
        generate
        build SP4-macOS "platform=macOS"
        check_mac
        build SP4-iOS "generic/platform=iOS Simulator"
        ;;
    selftest)
        generate
        build SP4-macOS "platform=macOS"
        check_mac
        status=0
        knot_with_timeout 60 "$MAC_APP/Contents/MacOS/SP4" -SP4SelfTest | tee "$LOGS/selftest.log" || status=$?
        echo "sp4: self-test exited with $status"
        exit "$status"
        ;;
    probe)
        probe
        ;;
    sim-build)
        env=${2:-Development}
        [[ $env == Development || $env == Production ]] || knot_fail "sp4-env" "ENV is $env." "Use Development or Production." "safe" "nothing"
        [[ -n ${KNOT_LOCAL_CONFIG:-} ]] ||
            knot_fail "sp4-no-team" "KNOT_LOCAL_CONFIG names no team configuration." "Export it; every build.sh call needs it, or generate unlinks it." "safe" "nothing"
        generate
        build SP4-iOS "generic/platform=iOS Simulator" team "$env"
        check_sim "$env"
        ;;
    sim-install)
        role=${2:?role}; env=${3:-Development}
        "$KNOT_SCRIPTS/sim.sh" boot "$role" >/dev/null
        xcrun simctl install "$(udid "$role")" "$(sim_app "$env")"
        echo "sp4: installed the $env build on the $role simulator"
        ;;
    live)
        role=${2:?role}; shift 2
        knot_with_timeout "${SP4_LIVE_TIMEOUT:-900}" xcrun simctl launch --console-pty --terminate-running-process \
            "$(udid "$role")" "$BUNDLE_ID" -SP4Live "$@" | grep '^sp4live:' | tee -a "$LOGS/live-$role.log"
        ;;
    *)
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
