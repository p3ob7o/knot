#!/bin/bash
# Builds SP-4's throwaway app with the pinned Xcode (docs/plan/SP-4.md).
#
#   Spikes/SP-4/build.sh check       generate, build the Mac app (signed ad hoc, sandboxed)
#                                    and the iOS app for the Simulator, and check both
#   Spikes/SP-4/build.sh selftest    build the Mac app, then run its self-test, which drives
#                                    the merge core, the mapping and the adapter's testable
#                                    half and quits by itself
#   Spikes/SP-4/build.sh probe       type-check each line of Probes/no-public-init.txt
#                                    against the pinned macOS SDK: every CloudKit type the
#                                    note names must fail to construct, every control must not
#
# Stage 1 builds only with KNOT_SIGNING=local. That build has no iCloud entitlement and
# says KnotSyncAvailable = NO, so nothing in it can open a container.

source "$(dirname "$0")/../../scripts/lib/common.sh"
knot_select_xcode

SPIKE="$KNOT_ROOT/Spikes/SP-4"
PROJECT="$SPIKE/SP4.xcodeproj"
DERIVED="$KNOT_BUILD/DerivedData-SP4"
LOGS="$KNOT_LOGS/sp4"
MAC_APP="$DERIVED/Build/Products/Debug/SP4.app"
mkdir -p "$LOGS"

if [[ ${KNOT_SIGNING:-local} != local ]]; then
    knot_fail "sp4-stage" "Stage 1 of SP-4 builds only with KNOT_SIGNING=local." \
        "Stage 2 adds the team entitlements first (Spikes/SP-4/README.md)." "safe" "nothing"
fi

generate() {
    knot_write_worktree_config
    (cd "$SPIKE" && xcodegen generate --spec project.yml --quiet)
}

build() {
    local scheme=$1 destination=$2 log="$LOGS/build-$1.log"
    local extra=()
    [[ ${KNOT_AGENT:-} == 1 ]] && extra+=(COMPILER_INDEX_STORE_ENABLE=NO)
    if ! "$KNOT_SCRIPTS/build-slot.sh" run --label "sp4 $scheme" -- \
        xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Debug -derivedDataPath "$DERIVED" \
        -destination "$destination" KNOT_SIGNING=local ${extra[@]+"${extra[@]}"} build >"$log" 2>&1; then
        grep -E "error:|warning:" "$log" | sort -u | head -40
        knot_fail "sp4-build" "The SP-4 build of $scheme failed." "Read $log." "safe" "$DERIVED"
    fi
    echo "sp4: built $scheme"
}

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
    *)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
