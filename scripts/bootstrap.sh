#!/bin/bash
# Prepares a fresh clone or worktree (docs/architecture.md §18).
#
#   scripts/bootstrap.sh                     check the prerequisites, write the worktree's
#                                            configuration, generate Knot.xcodeproj,
#                                            resolve the packages, create the simulators,
#                                            and speak the fixtures' audio
#   scripts/bootstrap.sh --first-test        the same, then run the first module test and
#                                            print how long a fresh worktree took to reach it
#   scripts/bootstrap.sh --pin-xcode <app>   write .xcode-version from a release Xcode.app
#
# A missing prerequisite stops it with the command that installs it. It never changes
# xcode-select.

source "$(dirname "$0")/lib/common.sh"

START=$(knot_now)
FIRST_TEST=0
case ${1:-} in
    "") ;;
    --first-test) FIRST_TEST=1 ;;
    --pin-xcode)
        app="${2:-}"
        [[ -n $app ]] || knot_fail "bootstrap-usage" "--pin-xcode needs the path of an Xcode.app." \
            "Run scripts/bootstrap.sh --pin-xcode /Applications/Xcode.app." "safe" "nothing"
        identity="$(knot_xcode_identity "${app%/}")" ||
            knot_fail "bootstrap-not-xcode" "$app is not an Xcode." "Name the Xcode.app you installed." "safe" "nothing"
        if knot_is_beta_build "${identity#* }"; then
            knot_fail "bootstrap-pin-beta" "$app is a beta ($identity). .xcode-version pins the release Xcode." \
                "Install the release Xcode 27 beside the beta and pin that one." "safe" "nothing"
        fi
        {
            echo "# The Xcode for the merge gate and the archive: its version and its build."
            echo "# Every script sets DEVELOPER_DIR from this file and checks it. Written by"
            echo "# scripts/bootstrap.sh --pin-xcode."
            echo "$identity"
        } >"$KNOT_ROOT/.xcode-version"
        echo "bootstrap: .xcode-version pins Xcode $identity"
        exit 0
        ;;
    -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) knot_fail "bootstrap-usage" "Unknown argument: $1" "Run scripts/bootstrap.sh --help." "safe" "nothing" ;;
esac

step() { printf 'bootstrap: %s\n' "$1"; }

# Prerequisites.
command -v python3 >/dev/null ||
    knot_fail "infra-python-missing" "python3 is missing." "It comes with Xcode's command-line tools: xcode-select --install." "safe" "nothing"
command -v git >/dev/null ||
    knot_fail "infra-git-missing" "git is missing." "xcode-select --install" "safe" "nothing"
knot_select_xcode
step "$(knot_xcode_label)"
knot_check_xcodegen ||
    knot_fail "$KNOT_XCODEGEN_CODE" "$KNOT_XCODEGEN_WHAT" "$KNOT_XCODEGEN_FIX" "safe" "nothing"
step "XcodeGen $KNOT_XCODEGEN_VERSION, from $KNOT_XCODEGEN_FROM, at $KNOT_XCODEGEN_PATH"
for platform in iOS:iphonesimulator watchOS:watchsimulator; do
    name=${platform%%:*}
    sdk=${platform#*:}
    major="$(xcrun --sdk "$sdk" --show-sdk-version | cut -d. -f1)"
    xcrun simctl list runtimes | grep -e "^$name $major\." >/dev/null ||
        knot_fail "infra-runtime-$name" "No $name $major simulator runtime for $(knot_xcode_label)." \
            "DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -downloadPlatform $name" "safe" "nothing"
done
step "simulator runtimes for iOS and watchOS"

# The worktree's configuration and the project.
knot_write_worktree_config
if [[ -L $KNOT_CONFIG/Local.xcconfig ]]; then
    step "local configuration linked from KNOT_LOCAL_CONFIG"
else
    step "no KNOT_LOCAL_CONFIG: builds use the local signing configuration only"
fi
knot_generate_project
step "generated Knot.xcodeproj"

# Packages, for SwiftPM and for Xcode, into this worktree's .build/.
knot_swiftpm_flags
swift package "${KNOT_SWIFTPM_FLAGS[@]}" resolve >/dev/null
knot_xcodebuild_settings
xcodebuild -project "$KNOT_PROJECT" "${KNOT_XCODEBUILD[@]}" -scheme Knot-iOS -resolvePackageDependencies >/dev/null
step "resolved GRDB for SwiftPM and for Xcode"

"$KNOT_SCRIPTS/sim.sh" ensure | sed 's/^/bootstrap: simulator /'

# The fixtures' audio. The system voices speak it on this Mac, because their licence does
# not allow committing it (Fixtures/README.md). It goes to Fixtures/generated/, which git
# ignores.
mkdir -p "$KNOT_LOGS"
# It goes through the fixtures step's own path (verify.sh's fixtures-audio, under the same
# lock), which speaks only when the audio is missing or stale and then stamps it, so that the
# first verify run does not speak it again.
/usr/bin/lockf -k -t "${KNOT_FIXTURES_LOCK_WAIT:-1800}" "$KNOT_BUILD/fixtures-audio.lock" \
    "$KNOT_SCRIPTS/verify.sh" --in-step fixtures-audio >"$KNOT_LOGS/bootstrap-fixtures.log" 2>&1 ||
    knot_fail "bootstrap-fixtures" "The fixtures' audio was not made and stamped. Its log is $KNOT_LOGS/bootstrap-fixtures.log." \
        "Read the log. The audio needs the macOS system voices that Fixtures/README.md names." "safe" \
        "part of Fixtures/generated/, which git ignores"
step "the fixtures' audio: $(tail -n 1 "$KNOT_LOGS/bootstrap-fixtures.log" | sed 's/^fixtures: //')"

step "done in $(knot_duration $(($(knot_now) - START)))"

if ((FIRST_TEST)); then
    mkdir -p "$KNOT_LOGS"
    swift test "${KNOT_SWIFTPM_FLAGS[@]}" --filter '^KnotCoreTests\.' >"$KNOT_LOGS/bootstrap-first-test.log" 2>&1 ||
        knot_fail "bootstrap-first-test" "The first module test failed. Its log is $KNOT_LOGS/bootstrap-first-test.log." \
            "Read the log." "safe" "build products in .build/ only"
    step "a fresh worktree reached its first green module test in $(knot_duration $(($(knot_now) - START))) (target 5m)"
fi
