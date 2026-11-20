# shellcheck shell=bash
# Shared by every script in scripts/. Source it; it sets strict mode, the paths of this
# worktree, and the Xcode that .xcode-version names.

set -euo pipefail

# The scripts come from one checkout, KNOT_SCRIPTS, and work on one tree, KNOT_ROOT. They
# are the same folder unless KNOT_TREE names another tree: then the scripts of this
# checkout, such as main's, check that tree, such as a candidate in the gate worktree
# (docs/architecture.md §18). Everything a script reads of the code, the plan, the fixtures
# and the pinned Xcode comes from the tree; the scripts, their helpers and the lists only the
# orchestrator edits come from KNOT_SCRIPTS.
KNOT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=fail.sh
source "$KNOT_SCRIPTS/lib/fail.sh"
KNOT_ROOT="$(cd "$KNOT_SCRIPTS/.." && pwd -P)"
if [[ -n ${KNOT_TREE:-} ]]; then
    KNOT_ROOT="$(cd "$KNOT_TREE" 2>/dev/null && pwd -P)" ||
        knot_fail "knot-tree-missing" "KNOT_TREE names $KNOT_TREE, which is not a folder." \
            "Name the tree to check, such as the gate worktree, or unset KNOT_TREE." "safe" "nothing"
fi
# Children, such as a step that runs in its own process, check the same tree.
export KNOT_TREE="$KNOT_ROOT" KNOT_SCRIPTS

# This worktree's own build products (docs/architecture.md §18). `.build/` is git-ignored.
KNOT_WORKTREE="$(basename "$KNOT_ROOT")"
# The worktree's ID on this Mac: its folder name and a short hash of its root path, so two
# clones in folders of the same name never share simulators or a development store.
KNOT_WORKTREE_ID="$KNOT_WORKTREE-$(printf '%s' "$KNOT_ROOT" | shasum -a 256 | cut -c1-6)"
KNOT_BUILD="$KNOT_ROOT/.build"
KNOT_CONFIG="$KNOT_BUILD/config"
KNOT_LOGS="$KNOT_BUILD/logs"
KNOT_SWIFTPM="$KNOT_BUILD/swiftpm"
KNOT_DERIVED="$KNOT_BUILD/DerivedData"
KNOT_SOURCE_PACKAGES="$KNOT_BUILD/SourcePackages"
KNOT_PACKAGE="$KNOT_ROOT/Packages/KnotKit"
KNOT_PROJECT="$KNOT_ROOT/Knot.xcodeproj"

# The build folder outside every worktree: the orchestrator's journal and the local
# signing configuration live there.
KNOT_BUILD_FOLDER="${KNOT_BUILD_FOLDER:-$HOME/knot-build}"

# Pinned tools.
KNOT_XCODEGEN_VERSION="2.47.0"

# XcodeGen is chosen by the scripts, as the Xcode is, and not by whatever PATH holds, which a
# machine-wide upgrade can change under a run (docs/dev-setup.md). knot_resolve_xcodegen
# settles on one binary, as an absolute path, in this order:
#   1. KNOT_XCODEGEN, a path to the binary, when it is set;
#   2. the pinned release unpacked under the build folder's tools/, when it is there;
#   3. xcodegen on PATH, as on a hosted runner.
# It sets KNOT_XCODEGEN_PATH, empty when none was found, and KNOT_XCODEGEN_FROM, which says
# which of the three it chose.
knot_resolve_xcodegen() {
    local pinned="$KNOT_BUILD_FOLDER/tools/xcodegen-$KNOT_XCODEGEN_VERSION/xcodegen/bin/xcodegen" found=""
    KNOT_XCODEGEN_PATH=""
    if [[ -n ${KNOT_XCODEGEN:-} ]]; then
        KNOT_XCODEGEN_FROM="KNOT_XCODEGEN"
        found=$KNOT_XCODEGEN
    elif [[ -x $pinned ]]; then
        KNOT_XCODEGEN_FROM="the build folder's tools/"
        found=$pinned
    else
        KNOT_XCODEGEN_FROM="PATH"
        found="$(command -v xcodegen || true)"
    fi
    if [[ -n $found && -f $found && -x $found ]]; then
        KNOT_XCODEGEN_PATH="$(cd "$(dirname "$found")" && pwd -P)/$(basename "$found")"
    fi
}

# Resolves XcodeGen and checks its version: one start of the binary. Returns 0 when it is
# the pinned version. Otherwise it sets KNOT_XCODEGEN_CODE, KNOT_XCODEGEN_WHAT and
# KNOT_XCODEGEN_FIX for a failure report, and returns 1.
knot_check_xcodegen() {
    local version where
    knot_resolve_xcodegen
    where="the build folder's tools/xcodegen-$KNOT_XCODEGEN_VERSION/ ($KNOT_BUILD_FOLDER/tools/xcodegen-$KNOT_XCODEGEN_VERSION/xcodegen/bin/xcodegen)"
    KNOT_XCODEGEN_FIX="Unpack the XcodeGen $KNOT_XCODEGEN_VERSION release, checked against its SHA-256 in docs/dev-setup.md, under $where, or name a copy with KNOT_XCODEGEN. Do not change Homebrew for the project."
    if [[ -z $KNOT_XCODEGEN_PATH ]]; then
        KNOT_XCODEGEN_CODE="infra-xcodegen-missing"
        if [[ $KNOT_XCODEGEN_FROM == KNOT_XCODEGEN ]]; then
            KNOT_XCODEGEN_WHAT="KNOT_XCODEGEN names $KNOT_XCODEGEN, which is not an executable file."
        else
            KNOT_XCODEGEN_WHAT="XcodeGen $KNOT_XCODEGEN_VERSION is not in the build folder, and no xcodegen is on PATH."
        fi
        return 1
    fi
    version="$("$KNOT_XCODEGEN_PATH" --version 2>/dev/null | awk '{ print $2 }' || true)"
    if [[ $version != "$KNOT_XCODEGEN_VERSION" ]]; then
        KNOT_XCODEGEN_CODE="infra-xcodegen-version"
        KNOT_XCODEGEN_WHAT="XcodeGen at $KNOT_XCODEGEN_PATH, chosen from $KNOT_XCODEGEN_FROM, is ${version:-of no version it states}, not $KNOT_XCODEGEN_VERSION."
        return 1
    fi
}

knot_now() { date +%s; }

# Prints a duration in seconds as "1m05s".
knot_duration() {
    local s=$1
    if ((s >= 60)); then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

# Runs a command with a time limit, in seconds. macOS has no `timeout`.
knot_with_timeout() {
    local seconds=$1
    shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$seconds" "$@"
}

# Reads the Xcode version and build that an Xcode.app holds.
knot_xcode_identity() {
    local app=$1 plist="$1/Contents/version.plist"
    [[ -f $plist ]] || return 1
    printf '%s %s\n' \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" \
        "$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$plist")"
}

# A beta's build number ends in a lower-case letter, as in 27C5035i.
knot_is_beta_build() { [[ $1 =~ [a-z]$ ]]; }

# The pin in .xcode-version: its first line that is not a comment, "<version> <build>",
# or "pending" until the owner installs the release Xcode at gate G1.
knot_xcode_pin() {
    [[ -f $KNOT_ROOT/.xcode-version ]] || return 1
    grep -v -E '^[[:space:]]*(#|$)' "$KNOT_ROOT/.xcode-version" | head -n 1
}

# Sets DEVELOPER_DIR for every command that follows, and checks it (docs/architecture.md
# §18). Never changes xcode-select.
#
# The Xcode is the one .xcode-version pins, found among /Applications/Xcode*.app and
# ~/Applications/Xcode*.app. KNOT_XCODE=/path/to/Xcode.app names another one, such as the
# beta, by name; the run then says that it did not use the pinned Xcode.
#
# Sets KNOT_XCODE_VERSION, KNOT_XCODE_BUILD and KNOT_XCODE_NOTE.
knot_select_xcode() {
    local pin app identity
    pin="$(knot_xcode_pin || true)"
    KNOT_XCODE_NOTE=""
    if [[ -n ${KNOT_XCODE:-} ]]; then
        app="${KNOT_XCODE%/}"
        identity="$(knot_xcode_identity "$app")" ||
            knot_fail "infra-xcode-named-missing" "KNOT_XCODE names $app, which is not an Xcode." \
                "Set KNOT_XCODE to the path of an Xcode.app, or unset it to use the pinned Xcode." "safe" "nothing"
        if [[ -z $pin || $pin == "pending" ]]; then
            KNOT_XCODE_NOTE="named by KNOT_XCODE; .xcode-version pins none yet"
        elif [[ $identity != "$pin" ]]; then
            KNOT_XCODE_NOTE="named by KNOT_XCODE, not the pinned $pin"
        fi
    else
        if [[ -z $pin || $pin == "pending" ]]; then
            knot_fail "infra-xcode-unpinned" ".xcode-version pins no Xcode yet: the release Xcode 27 arrives at gate G1." \
                "Install the release Xcode 27 beside the beta and run scripts/bootstrap.sh --pin-xcode /Applications/Xcode.app. Until then, name an Xcode with KNOT_XCODE=/Applications/Xcode-beta.app." \
                "safe" "nothing"
        fi
        app=""
        local candidate
        for candidate in /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
            [[ -d $candidate ]] || continue
            if [[ "$(knot_xcode_identity "$candidate" 2>/dev/null || true)" == "$pin" ]]; then
                app="$candidate"
                break
            fi
        done
        [[ -n $app ]] ||
            knot_fail "infra-xcode-missing" "No Xcode in /Applications or ~/Applications is the pinned $pin." \
                "Install Xcode $pin, or name another one with KNOT_XCODE=/path/to/Xcode.app." "safe" "nothing"
        identity="$pin"
    fi
    export DEVELOPER_DIR="$app/Contents/Developer"
    KNOT_XCODE_VERSION="${identity% *}"
    KNOT_XCODE_BUILD="${identity#* }"
    # Check that the tools answer as the version the files claim.
    local reported
    reported="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    if [[ $reported != "Xcode $KNOT_XCODE_VERSION Build version $KNOT_XCODE_BUILD " ]]; then
        knot_fail "infra-xcode-mismatch" "xcodebuild in $DEVELOPER_DIR reports '$reported', not Xcode $identity." \
            "Run the Xcode once to finish its installation (xcodebuild -runFirstLaunch), or reinstall it." \
            "safe" "nothing"
    fi
    if knot_is_beta_build "$KNOT_XCODE_BUILD"; then
        KNOT_XCODE_NOTE="${KNOT_XCODE_NOTE:+$KNOT_XCODE_NOTE, }a beta"
    fi
}

# "Xcode 27.3 (27C5035i, a beta)" for the summary line.
knot_xcode_label() {
    printf 'Xcode %s (%s%s)' "$KNOT_XCODE_VERSION" "$KNOT_XCODE_BUILD" "${KNOT_XCODE_NOTE:+, $KNOT_XCODE_NOTE}"
}

# "macOS 27.3 (26D...)" for the summary line.
knot_macos_label() {
    printf 'macOS %s (%s)' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
}

# Settings every xcodebuild run takes, in the array KNOT_XCODEBUILD: this worktree's
# DerivedData and package checkouts, the local signing configuration, and no index store
# for agent builds. Scripts run on macOS's bash 3.2, so arrays are set, not printed.
knot_xcodebuild_settings() {
    KNOT_XCODEBUILD=(
        -derivedDataPath "$KNOT_DERIVED"
        -clonedSourcePackagesDirPath "$KNOT_SOURCE_PACKAGES"
        KNOT_SIGNING=local
    )
    if [[ ${KNOT_AGENT:-} == 1 ]]; then
        KNOT_XCODEBUILD+=(COMPILER_INDEX_STORE_ENABLE=NO)
    fi
}

# Flags for `swift build` and `swift test` on the package, in the array KNOT_SWIFTPM_FLAGS.
knot_swiftpm_flags() {
    KNOT_SWIFTPM_FLAGS=(--package-path "$KNOT_PACKAGE" --scratch-path "$KNOT_SWIFTPM")
    if [[ ${KNOT_AGENT:-} == 1 ]]; then
        KNOT_SWIFTPM_FLAGS+=(--disable-index-store)
    fi
}

# Writes this worktree's generated configuration into .build/config/: its name, for the
# Mac development store folder, and a link to the local signing configuration that
# KNOT_LOCAL_CONFIG names, if any.
knot_write_worktree_config() {
    mkdir -p "$KNOT_CONFIG"
    printf '// Written by scripts/bootstrap.sh. Not committed.\nKNOT_WORKTREE = %s\nKNOT_WORKTREE_ID = %s\n' \
        "$KNOT_WORKTREE" "$KNOT_WORKTREE_ID" >"$KNOT_CONFIG/Worktree.xcconfig"
    if [[ -n ${KNOT_LOCAL_CONFIG:-} ]]; then
        [[ -f $KNOT_LOCAL_CONFIG ]] ||
            knot_fail "bootstrap-local-config-missing" "KNOT_LOCAL_CONFIG names $KNOT_LOCAL_CONFIG, which does not exist." \
                "Create it from Apps/Config/Local.xcconfig.example, or unset KNOT_LOCAL_CONFIG." "safe" \
                ".build/config/Worktree.xcconfig"
        ln -sfn "$KNOT_LOCAL_CONFIG" "$KNOT_CONFIG/Local.xcconfig"
    else
        rm -f "$KNOT_CONFIG/Local.xcconfig"
    fi
}

# Generates Knot.xcodeproj from project.yml, with the XcodeGen that knot_resolve_xcodegen
# chooses. Its version is checked again just before it generates, so a tool that changed
# since the doctor's check fails the step and never generates with another version.
knot_generate_project() {
    knot_write_worktree_config
    knot_check_xcodegen ||
        knot_fail "$KNOT_XCODEGEN_CODE" "$KNOT_XCODEGEN_WHAT" "$KNOT_XCODEGEN_FIX" "safe" "nothing"
    (cd "$KNOT_ROOT" && "$KNOT_XCODEGEN_PATH" generate --spec project.yml --quiet)
}

# Whether this Mac can run Mac UI tests, from the output of `automationmodetool` (no
# arguments) and of `DevToolsSecurity -status`. Prints what is missing, one item a line, and
# returns 1 when anything is.
#
# `automationmodetool` prints two lines (man automationmodetool): whether Automation Mode is
# on now, and whether turning it on needs authentication. The first says "disabled" whenever
# no UI test runs, because a test run turns it on and off. What matters is the second:
# "This device DOES NOT REQUIRE user authentication to enable Automation Mode". Developer
# mode must read "currently enabled"; "disabled" holds the word "enabled", so the whole
# phrase is matched.
knot_mac_ui_ready() {
    local automation=$1 developer=$2 missing=0
    if ! printf '%s\n' "$automation" | grep -i -e 'does not require user authentication to enable automation mode' >/dev/null; then
        echo "enabling Automation Mode needs authentication: sudo automationmodetool enable-automationmode-without-authentication"
        missing=1
    fi
    if ! printf '%s\n' "$developer" | grep -i -e 'developer mode is currently enabled' >/dev/null; then
        echo "developer mode is off: sudo DevToolsSecurity -enable"
        missing=1
    fi
    return "$missing"
}

# Runs a command with a time limit, and returns its status. At the limit the command and its
# descendants, found before any of them ends, get TERM, then KILL two seconds later for those
# that ignore it; the function then sets KNOT_LIMIT_HIT=1 and returns 124. The command's
# output goes where the caller sends it: send it to a file, not a pipe that the caller reads,
# since a process that outlives the kill would hold the pipe open.
#   knot_limit <seconds> <command…>
KNOT_LIMIT_HIT=0
knot_limit() {
    local seconds=$1 status=0 pid timer
    shift
    KNOT_LIMIT_HIT=0
    "$@" &
    pid=$!
    # The limit is wall-clock time: a timer process that sleeps for it, which a loaded Mac
    # cannot stretch as it stretches a count of polls.
    /bin/sleep "$seconds" &
    timer=$!
    while kill -0 "$pid" 2>/dev/null && kill -0 "$timer" 2>/dev/null; do
        sleep 0.1
    done
    kill "$timer" 2>/dev/null || true
    wait "$timer" 2>/dev/null || true
    if kill -0 "$pid" 2>/dev/null; then
        knot_end_process "$pid"
        wait "$pid" 2>/dev/null || true
        KNOT_LIMIT_HIT=1
        return 124
    fi
    wait "$pid" || status=$?
    return "$status"
}

# Ends a process and its descendants, found before any of them ends: TERM, then KILL two
# seconds later for those that ignore it. The two seconds are for the whole family: when the
# process is a shell function's subshell, it dies at TERM at once, while what it started,
# such as xcodebuild ending its test session, still needs the time.
knot_end_process() {
    local family ticks=0
    family="$1 $(knot_descendants "$1")"
    # shellcheck disable=SC2086
    kill -TERM $family 2>/dev/null || true
    # shellcheck disable=SC2086
    while knot_any_alive $family && ((ticks < 20)); do
        sleep 0.1
        ticks=$((ticks + 1))
    done
    # shellcheck disable=SC2086
    kill -KILL $family 2>/dev/null || true
}

# Whether any of the processes named is still alive.
knot_any_alive() {
    local p
    for p in "$@"; do
        kill -0 "$p" 2>/dev/null && return 0
    done
    return 1
}

# Prints the process IDs of every descendant of a process, one per line.
knot_descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        knot_descendants "$child"
    done
}

# What a step says when a run outlives its limit: on this Mac, a system dialog that only the
# owner can answer is the likely cause, and no agent answers it.
knot_dialog_message() {
    echo "$1 did not end within ${2}s. A system dialog, such as a consent prompt, may be waiting for the owner on this Mac; no agent answers it. Ask him to look at the screen."
}

# Runs a command that starts something Knot built, such as xcodebuild running tests, with a
# time limit. At the limit it prints knot_dialog_message for <what> and returns 124, with
# KNOT_LIMIT_HIT set; otherwise it returns the command's status, so the caller can read the
# results first and then fail on the status.
#   knot_run_limited <what> <seconds> <command…>
knot_run_limited() {
    local what=$1 seconds=$2 status=0
    shift 2
    knot_limit "$seconds" "$@" || status=$?
    if ((KNOT_LIMIT_HIT)); then
        knot_dialog_message "$what" "$seconds"
        return 124
    fi
    return "$status"
}

# The limit on a step that runs the package's tests, in seconds: two hours. The suites end
# every wait after SuiteWait.limit, ten minutes, and the most waits one test can run in turn
# is 11, in RecorderContract.run, so a run in which every wait runs out ends after 110
# minutes, while the other tests run beside it. A test that hangs outside a wait, such as a
# deadlock, would otherwise hold the step for ever. The self-test checks that no test can
# run more waits in turn than fit in this limit.
KNOT_SWIFT_TEST_LIMIT=${KNOT_SWIFT_TEST_LIMIT:-7200}

# Runs a command that runs the package's tests, with KNOT_SWIFT_TEST_LIMIT. At the limit it
# fails and names the step: a hung test, not a dialog. Otherwise it returns the command's
# status.
#   knot_swift_test_limited <step> <command…>
knot_swift_test_limited() {
    local step=$1 status=0
    shift
    knot_limit "$KNOT_SWIFT_TEST_LIMIT" "$@" || status=$?
    if ((KNOT_LIMIT_HIT)); then
        echo "The step $step did not end within $(knot_duration "$KNOT_SWIFT_TEST_LIMIT") (KNOT_SWIFT_TEST_LIMIT), longer than a run in which every wait of a suite runs out. A test hangs outside its waits, such as in a deadlock: the last test that started, above, is the one to read."
        return 124
    fi
    return "$status"
}

# Prints the fakes that a Mach-O file holds, one a line, and returns 0 when it holds any.
# The fakes are listed in <list>, one qualified name a line, as `scripts/lib/knot_tool.py
# fake-types` prints them: each top-level type declared under an `#if` that names
# KNOT_FAKES, in any module, such as KnotLink.FakeLinkSystem. The file's symbols and strings
# are demangled before they are matched, because Swift abbreviates repeated words in a
# mangled name, and a name matches only whole, so KnotLink.FakeLinkSystem does not match
# KnotLink.FakeLinkSystems. The KnotFakes module counts too, whatever it declares: its
# mangled name in a symbol, or its name in a string, as the scan has looked for it since
# WP-01. A symbol's debug-map path, such as Sources/KnotFakes/, is neither.
#   knot_fakes_in <Mach-O file> <list>
knot_fakes_in() {
    local file=$1 list=$2 symbols strings found
    symbols="$(nm -a "$file" 2>/dev/null || true)"
    strings="$(strings -a "$file" 2>/dev/null || true)"
    found="$(printf '%s\n%s\n' "$symbols" "$strings" | xcrun swift-demangle |
        awk 'NR == FNR { if ($0 != "") { name = $0; gsub(/[.]/, "[.]", name); names[$0] = name "([^A-Za-z0-9_]|$)" } next }
            { for (n in names) if ($0 ~ names[n]) seen[n] = 1 }
            END { for (n in seen) print n }' "$list" - | sort)"
    if grep -e 9KnotFakes <<<"$symbols" >/dev/null || grep -e KnotFakes <<<"$strings" >/dev/null; then
        found="${found:+$found$'\n'}the module KnotFakes"
    fi
    [[ -n $found ]] || return 1
    printf '%s\n' "$found"
}

# Runs one simctl call on a simulator with a time limit, and fails, naming the simulator,
# when it does not end in time or ends with a status other than zero. The failure goes to
# standard error, which a step sends to its log, so a caller may drop the call's output.
#   knot_sim_call <seconds> <what> <simulator name> <command…>
knot_sim_call() {
    local seconds=$1 what=$2 simulator=$3 status=0
    shift 3
    knot_limit "$seconds" "$@" || status=$?
    if ((KNOT_LIMIT_HIT)); then
        echo "simctl $what on the simulator $simulator did not end within ${seconds}s. The simulator may be stuck booting, or a system dialog may be waiting for the owner on this Mac; no agent answers it. Ask him to look at the screen; scripts/sim.sh shutdown ends this worktree's simulators." >&2
        return 1
    fi
    if ((status != 0)); then
        echo "simctl $what on the simulator $simulator failed with status $status." >&2
        return 1
    fi
}

# Starts an app that Knot built and waits up to <seconds> for its first window, which the
# probe finds: the probe is called with the app's process ID appended, and prints the
# windows it sees, or nothing. Then it ends the app and everything the app started. Prints
# "windows: …" and returns 0 when a window came. Fails when the app exited first, or when no
# window came in time, which on this Mac most likely means a system dialog holds the start.
#   knot_start_app <seconds> <app executable> <probe…>
knot_start_app() {
    local seconds=$1 app=$2 found="" deadline status=0 exited=0 out pid
    shift 2
    out="$(mktemp)"
    "$app" >/dev/null 2>&1 &
    pid=$!
    deadline=$(($(knot_now) + seconds))
    while (($(knot_now) < deadline)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            exited=1
            break
        fi
        knot_limit 15 "$@" "$pid" >"$out" 2>/dev/null || true
        found="$(cat "$out")"
        [[ -n $found ]] && break
        sleep 0.5
    done
    if ((exited)); then
        wait "$pid" || status=$?
    else
        knot_end_process "$pid"
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$out"
    if [[ -n $found ]]; then
        echo "windows: $found"
        return 0
    fi
    if ((exited)); then
        echo "$(basename "$app") exited with status $status before it showed a window."
    else
        echo "$(basename "$app") showed no window within ${seconds}s. A system dialog, such as a consent prompt, may be holding its start and waiting for the owner on this Mac; no agent answers it. Ask him to look at the screen."
    fi
    return 1
}

# Starts a tool that Knot built, such as knot-dev, with a time limit, and prints its standard
# output; its standard error goes to standard error. A start that a system dialog holds, such
# as a consent prompt, never returns, and nothing but the owner can answer the dialog, so the
# limit turns that hang into a failure that says so, on standard error. Returns the tool's
# status, or 1 when the limit ran out.
#   knot_start_tool <seconds> <tool> [arguments…]
knot_start_tool() {
    local seconds=$1 status=0 output errors
    shift
    # The tool's standard output is what the caller compares; its standard error, and the
    # message at the limit, go to standard error, which a step sends to its log.
    output="$(mktemp)"
    errors="$(mktemp)"
    knot_limit "$seconds" "$@" >"$output" 2>"$errors" || status=$?
    cat "$output"
    cat "$errors" >&2
    rm -f "$output" "$errors"
    if ((KNOT_LIMIT_HIT)); then
        knot_dialog_message "$(basename "$1")" "$seconds" >&2
        return 1
    fi
    return "$status"
}

# Takes the signing team's ID out of a build log, by pattern: Xcode writes the team's prefix
# into the log of every app build on a Mac that knows the team, whatever the signing, as
# TeamIdentifierPrefix, AppIdentifierPrefix and the entitlements it prints, such as
# application-identifier. No run needs the ID, and most do not know it, so a team ID is
# matched by its shape, ten capitals and digits, where those keys or an identifier put it:
# before `.com.` or `.*`, as a plist's whole string, as codesign's `[String]` value, and as
# the parenthesised end of a certificate's name. A run that has the owner's configuration
# knows the ID: the filter reads it, as the team-ID step does, from KNOT_TEAM_CONFIG, else
# KNOT_LOCAL_CONFIG, else the configuration that bootstrap linked into the tree, never prints
# it, and masks it wherever it stands.
#   … | knot_filter_team
KNOT_TEAM_FILTER='
    BEGIN {
        my $config = $ENV{KNOT_FILTER_CONFIG} || "";
        if ($config ne "" && open(my $file, "<", $config)) {
            local $/;
            my $text = <$file>;
            ($main::team) = $text =~ /^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$/m;
        }
    }
    s/((?:TeamIdentifierPrefix|AppIdentifierPrefix)\\?[=:]\s*"?)[A-Z0-9]{10}(?=[."\s]|$)/$1<TEAM>/g;
    s/(DEVELOPMENT_TEAM\w*\s*\\?[=:]\s*"?)[A-Z0-9]{10}\b/$1<TEAM>/g;
    s/((?:team-identifier|TeamIdentifier|com\.apple\.developer\.team-identifier)"?\s*[=:]\s*"?)[A-Z0-9]{10}\b/$1<TEAM>/g;
    s/\b[A-Z0-9]{10}(?=\.(?:(?:com|group|iCloud|org|net)\b|\*))/<TEAM>/g;
    s/(<string>\s*)[A-Z0-9]{10}(?=\s*<\/string>)/$1<TEAM>/g;
    s/(\[String\]\s+)[A-Z0-9]{10}\b/$1<TEAM>/g;
    s/\([A-Z0-9]{10}\)/(<TEAM>)/g;
    s/\Q$main::team\E/<TEAM>/g if defined $main::team;
'
# The configuration the filter reads the ID from, chosen as step_team_id chooses it.
knot_filter_config() { echo "${KNOT_TEAM_CONFIG:-${KNOT_LOCAL_CONFIG:-$KNOT_CONFIG/Local.xcconfig}}"; }
knot_filter_team() { KNOT_FILTER_CONFIG="$(knot_filter_config)" perl -pe "$KNOT_TEAM_FILTER"; }

# Rewrites, in place, the logs that the scripts kept in a folder, through knot_filter_team:
# the files named verify-* and bootstrap-*. Other files are left alone: one may be the output
# of a command still writing to it, and a rewrite would give the file a new inode under the
# writer, whose lines would then be lost.
knot_scrub_logs() {
    local folder=$1 log
    [[ -d $folder ]] || return 0
    for log in "$folder"/verify-* "$folder"/bootstrap-*; do
        [[ -f $log ]] || continue
        KNOT_FILTER_CONFIG="$(knot_filter_config)" perl -pi -e "$KNOT_TEAM_FILTER" "$log" 2>/dev/null || true
    done
}

# Judges the log of an xcodebuild test run of XCTest cases, such as UI tests. Prints one line,
# "xctest: N passed, M failed", and returns 1 when no case passed, when a case failed, or
# when a destination named after the log has no passed case: a run that executed 0 tests is
# a failure, not a pass. A run on several destinations writes "passed on '<name> - …'".
#   knot_xctest_result <log> [destination name…]
knot_xctest_result() {
    local log=$1 passed failed destination missing=""
    shift
    passed=$(grep -a -c -E "Test [Cc]ase '[^']+' passed" "$log" || true)
    failed=$(grep -a -c -E "Test [Cc]ase '[^']+' failed" "$log" || true)
    for destination in "$@"; do
        grep -a -F -e "passed on '$destination" "$log" >/dev/null || missing="$missing $destination"
    done
    echo "xctest: $passed passed, $failed failed${missing:+, none passed on:$missing}"
    ((passed > 0 && failed == 0)) && [[ -z $missing ]]
}
