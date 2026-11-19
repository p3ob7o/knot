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

# Generates Knot.xcodeproj from project.yml.
knot_generate_project() {
    knot_write_worktree_config
    (cd "$KNOT_ROOT" && xcodegen generate --spec project.yml --quiet)
}
