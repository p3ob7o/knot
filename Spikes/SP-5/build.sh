#!/bin/bash
# Builds SP-5's throwaway Mac app with the pinned Xcode (docs/plan/SP-5.md).
#
#   Spikes/SP-5/build.sh check            generate and build, signed ad hoc, sandboxed
#   Spikes/SP-5/build.sh selftest         build, check the signature, then run the self-test:
#                                         a holder process and the self-test, each of which
#                                         quits by itself within a few seconds
#   Spikes/SP-5/build.sh mac [FOLDER]     build for the sitting and copy Knot SP-5.app into
#                                         FOLDER (default ~/knot-build/sp5). It does not launch it.
#
# KNOT_SIGNING=local (the default) signs ad hoc and keeps the sandbox. KNOT_SIGNING=team signs
# with the owner's team, from the Local.xcconfig that KNOT_LOCAL_CONFIG names. The self-test
# shows nothing, takes no focus, never touches the microphone, and registers only F20 keys,
# which no Apple keyboard has.

source "$(dirname "$0")/../../scripts/lib/common.sh"
knot_select_xcode

SPIKE="$KNOT_ROOT/Spikes/SP-5"
PROJECT="$SPIKE/SP5.xcodeproj"
DERIVED="$KNOT_BUILD/DerivedData-SP5"
LOGS="$KNOT_LOGS/sp5"
APP="$DERIVED/Build/Products/Debug/SP5.app"
mkdir -p "$LOGS"

generate() {
    knot_write_worktree_config
    (cd "$SPIKE" && xcodegen generate --spec project.yml --quiet)
}

build() {
    local signing=${KNOT_SIGNING:-local}
    local extra=()
    [[ ${KNOT_AGENT:-} == 1 ]] && extra+=(COMPILER_INDEX_STORE_ENABLE=NO)
    [[ $signing == team ]] && extra+=(-allowProvisioningUpdates)
    if ! xcodebuild -project "$PROJECT" -scheme SP5 -configuration Debug -derivedDataPath "$DERIVED" \
        -destination "platform=macOS" KNOT_SIGNING="$signing" ${extra[@]+"${extra[@]}"} build >"$LOGS/build.log" 2>&1; then
        grep -E "error:|warning:" "$LOGS/build.log" | sort -u | head -40
        knot_fail "sp5-build" "The SP-5 build failed." "Read $LOGS/build.log." "safe" "$DERIVED"
    fi
    echo "sp5: built with KNOT_SIGNING=$signing"
}

# The build is sandboxed and uses the development identifiers.
check_signature() {
    local bundle entitlements
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
    case $bundle in *.dev) ;; *) knot_fail "sp5-identifier" "The spike's bundle ID is $bundle." \
        "The spike uses the development identifiers only (docs/architecture.md §7)." "safe" "nothing" ;; esac
    entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)"
    [[ $entitlements == *'"com.apple.security.app-sandbox":true'* ]] ||
        knot_fail "sp5-not-sandboxed" "The built app does not carry com.apple.security.app-sandbox." \
            "Check Spikes/SP-5/Config/SP5-*.entitlements." "safe" "nothing"
    echo "sp5: bundle $bundle"
    echo "sp5: entitlements $entitlements"
    codesign -dv "$APP" 2>&1 | grep -E "^(Signature|Format|CodeDirectory|Runtime|TeamIdentifier)" | sed 's/^/sp5: /'
    codesign --verify --strict "$APP" && echo "sp5: signature verifies"
}

case ${1:-} in
    check)
        generate
        build
        check_signature
        ;;
    selftest)
        generate
        build
        check_signature
        if pgrep -f "SP5.app/Contents/MacOS/SP5" >/dev/null; then
            knot_fail "sp5-running" "A Knot SP-5 is already running." \
                "Quit it from its menu bar item (SP-5 → Quit) and run the self-test again." "safe" "nothing"
        fi
        binary="$APP/Contents/MacOS/SP5"
        # The holder: a second sandboxed process that holds two F20 keys for five seconds.
        knot_with_timeout 8 "$binary" -SP5HoldKeys >"$LOGS/holder.log" 2>&1 &
        holder=$!
        for _ in $(seq 1 30); do
            grep -q holder.registered "$LOGS/holder.log" 2>/dev/null && break
            sleep 0.1
        done
        sed 's/^/holder: /' "$LOGS/holder.log"
        status=0
        knot_with_timeout 10 "$binary" -SP5SelfTest -SP5HolderRunning | tee "$LOGS/selftest.log" || status=$?
        wait "$holder" 2>/dev/null || true
        if pgrep -f "SP5.app/Contents/MacOS/SP5" >/dev/null; then
            echo "sp5: a process is still running" >&2
            exit 1
        fi
        echo "sp5: self-test exited with $status; no SP-5 process is left running"
        exit "$status"
        ;;
    mac)
        generate
        build
        check_signature
        folder="${2:-$KNOT_BUILD_FOLDER/sp5}"
        mkdir -p "$folder"
        target="$folder/Knot SP-5.app"
        if [[ -e $target ]]; then
            old="$(mktemp -d "$folder/previous.XXXXXX")"
            mv "$target" "$old/"
            echo "sp5: moved the previous copy aside to $old"
        fi
        ditto "$APP" "$target"
        echo "sp5: copied to $target"
        echo "sp5: open it from Finder, or with: open \"$target\""
        ;;
    *)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
