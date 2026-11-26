#!/bin/bash
# Makes a milestone build, from a named commit, in one command (docs/orchestrator.md, "A
# milestone build"; docs/dev-setup.md, the table of builds).
#
#   scripts/milestone-build.sh <M1…M7> --commit <sha> [--products ios|mac|both]
#       [--allow-provisioning-updates] [--install [--device <name>]… [--again] [--mac-folder <folder>]]
#   scripts/milestone-build.sh <M1…M7> --commit <sha> --archive <folder> [--build-number <n>]
#       [--products ios|mac|both] [--allow-provisioning-updates]
#
#   --products   the iPhone app with its Watch app and widgets (ios), the Mac app (mac), or
#                both, the default
#   --commit     the commit the worktree must be at, required: the milestone's commit, or
#                that commit and a fix
#   --allow-provisioning-updates
#                passes -allowProvisioningUpdates, so that Xcode may make the milestone's
#                identifiers and development profiles in the owner's account. Only on his
#                word. Nothing passes -allowProvisioningDeviceRegistration: registering a
#                device stays a step by hand, on his word each time.
#   --install    after every check has passed: scripts/install.sh for the iPhone app, with
#                --device and --again passed through, and scripts/install.sh --mac-folder
#                for the Mac app, which then needs --mac-folder
#   --archive    an archive instead of a build, for scripts/release.sh: each product is archived
#                into <folder>, which must be new or empty, as <folder>/Knot-<product>.xcarchive,
#                from derived data of its own beside it, with its log there. Every check below
#                runs on the app in the archive; the derived data is removed once they pass, and
#                the archive stays. It installs nothing.
#   --build-number
#                the build number the archive carries, in place of Identifiers.xcconfig's, and
#                the one the checks compare: App Store Connect takes each build number once
#
# Before it builds, it stops, saying what to do, when the worktree has uncommitted changes,
# when HEAD is not the commit named, when the team's configuration is not linked into
# .build/config/, and when Xcode's saved list of accounts is empty, which it reads as a
# count and nothing else. Each product is built in fresh derived data of its own, a new
# folder under .build/milestone/, the Release configuration, through scripts/build-slot.sh.
# After each build it reads the bundle ID, the version, the build number, the flavour and
# the level from the product and compares them with the level asked for and with
# Apps/Config/Identifiers.xcconfig, runs codesign --verify --strict on every part, each
# alone, innermost first, and reads the app group each part is signed with against the groups
# its provisioning profile allows. It stops at the first failure, naming the part, and
# installs nothing. It prints the summary, with each product's path, before any install; an
# install that fails leaves the build whole, and the script names the command that installs
# it again. It never starts what it builds: a milestone build that runs opens the owner's own
# store. It prints no team ID and no signing identity. Each build's log lies beside its
# derived data, .build/milestone/milestone-build-<level>-<commit>-<product>.log, filtered for
# the team's ID as it is written; a run of verify.sh does not move it.

source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/bundle.sh
source "$KNOT_SCRIPTS/lib/bundle.sh"

usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "milestone-build-usage" "$1" "Run scripts/milestone-build.sh --help." "safe" "nothing"; }
say() { printf 'milestone-build: %s\n' "$1"; }

# ------------------------------------------------------------------ one build, in a slot

# A build runs in a second process that holds a build slot, under the build limit. It finds
# its settings in the environment: KNOT_MB_SCHEME, KNOT_MB_DESTINATION, KNOT_MB_DERIVED,
# KNOT_MB_LEVEL, KNOT_MB_LOG and KNOT_MB_PROVISIONING (1 or 0); for an archive, KNOT_MB_ARCHIVE,
# its path, and KNOT_MB_BUILD_NUMBER, the build number given, when one was.
# XCODE_XCCONFIG_FILE names settings that override even those given on xcodebuild's command line
# (man xcodebuild, ENVIRONMENT): no build of this script starts while it is set, the worker's
# included, which a caller may start alone.
refuse_xcconfig_override() {
    [[ -z ${XCODE_XCCONFIG_FILE+set} ]] ||
        knot_fail "milestone-build-xcconfig-override" "XCODE_XCCONFIG_FILE is set: its settings would override the ones the milestone build gives on the command line." \
            "Unset XCODE_XCCONFIG_FILE, then rerun." "safe" "nothing"
}
if [[ ${1:-} == --in-build ]]; then
    refuse_xcconfig_override
    # The time the build got its slot, so that the build's own time is told from the wait.
    knot_now >"$KNOT_MB_SLOT_TIME"
    knot_select_xcode
    build() {
        local flags=()
        local action=(build)
        [[ $KNOT_MB_PROVISIONING == 1 ]] && flags+=(-allowProvisioningUpdates)
        [[ -z ${KNOT_MB_BUILD_NUMBER:-} ]] || flags+=(KNOT_BUILD_NUMBER="$KNOT_MB_BUILD_NUMBER")
        [[ -z ${KNOT_MB_ARCHIVE:-} ]] || action=(archive -archivePath "$KNOT_MB_ARCHIVE")
        # The log is filtered as it is written: Xcode writes the team's prefix into it.
        { xcodebuild -project "$KNOT_PROJECT" -derivedDataPath "$KNOT_MB_DERIVED" \
            -clonedSourcePackagesDirPath "$KNOT_SOURCE_PACKAGES" -configuration Release \
            -scheme "$KNOT_MB_SCHEME" -destination "$KNOT_MB_DESTINATION" \
            ${flags[@]+"${flags[@]}"} \
            KNOT_FLAVOUR=milestone KNOT_MILESTONE_LEVEL="$KNOT_MB_LEVEL" KNOT_SIGNING=team \
            COMPILER_INDEX_STORE_ENABLE=NO "${action[@]}" 2>&1 | knot_filter_team >>"$KNOT_MB_LOG"; } 2>/dev/null # limit: build
    }
    knot_run_limited "The milestone build of $KNOT_MB_SCHEME" "$KNOT_BUILD_LIMIT" build
    exit $?
fi

# ------------------------------------------------------------------ arguments

LEVEL=""
COMMIT=""
PRODUCTS=both
PROVISIONING=0
INSTALL=0
AGAIN=0
MAC_FOLDER=""
ARCHIVE_DIR=""
BUILD_NUMBER=""
DEVICES=()
while [[ $# -gt 0 ]]; do
    case $1 in
        M[1-7]) [[ -z $LEVEL ]] || usage_fail "Name one level."; LEVEL=$1; shift ;;
        --commit) COMMIT=${2:-}; [[ -n $COMMIT ]] || usage_fail "--commit needs a commit."; shift 2 ;;
        --products)
            PRODUCTS=${2:-}
            [[ $PRODUCTS == ios || $PRODUCTS == mac || $PRODUCTS == both ]] || usage_fail "--products takes ios, mac or both."
            shift 2 ;;
        --allow-provisioning-updates) PROVISIONING=1; shift ;;
        --install) INSTALL=1; shift ;;
        --device) [[ -n ${2:-} ]] || usage_fail "--device needs a name or a UDID."; DEVICES+=("$2"); shift 2 ;;
        --again) AGAIN=1; shift ;;
        --mac-folder) MAC_FOLDER=${2:-}; [[ -n $MAC_FOLDER ]] || usage_fail "--mac-folder needs a folder."; shift 2 ;;
        --archive) ARCHIVE_DIR=${2:-}; [[ -n $ARCHIVE_DIR ]] || usage_fail "--archive needs a folder."; shift 2 ;;
        --build-number)
            BUILD_NUMBER=${2:-}
            [[ $BUILD_NUMBER =~ ^[1-9][0-9]{0,8}$ ]] || usage_fail "--build-number takes a whole number above 0."
            shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) usage_fail "Unknown argument: $1" ;;
    esac
done
[[ -n $LEVEL ]] || usage_fail "Name the level, M1 to M7."
refuse_xcconfig_override
[[ -n $COMMIT ]] || usage_fail "Name the commit the build is made from: --commit <sha>."
if ((INSTALL == 0)); then
    [[ -z $MAC_FOLDER && ${#DEVICES[@]} == 0 && $AGAIN == 0 ]] ||
        usage_fail "--device, --again and --mac-folder belong to --install."
fi
if ((INSTALL)); then
    [[ $PRODUCTS == ios || -n $MAC_FOLDER ]] ||
        usage_fail "--install with the Mac app needs --mac-folder <folder>: the Mac app is copied there, never started."
    [[ $PRODUCTS != mac || (${#DEVICES[@]} == 0 && $AGAIN == 0) ]] ||
        usage_fail "--device and --again are for the iPhone app, and --products mac builds none."
    [[ $PRODUCTS != ios || -z $MAC_FOLDER ]] || usage_fail "--mac-folder is for the Mac app, and --products ios builds none."
fi
if [[ -n $ARCHIVE_DIR ]]; then
    ((INSTALL == 0)) || usage_fail "--archive makes an archive for scripts/release.sh, and installs nothing: leave out --install."
else
    [[ -z $BUILD_NUMBER ]] || usage_fail "--build-number belongs to --archive: a build takes the number in Apps/Config/Identifiers.xcconfig."
fi
# A folder named relative to where the script was started is made absolute, so that the
# command it prints to install again is right wherever it is run.
[[ -z $MAC_FOLDER || $MAC_FOLDER == /* ]] || MAC_FOLDER="$PWD/$MAC_FOLDER"
[[ -z $ARCHIVE_DIR || $ARCHIVE_DIR == /* ]] || ARCHIVE_DIR="$PWD/$ARCHIVE_DIR"
# An archive is never made into a folder that holds anything: no run picks up an earlier one's. A
# folder that cannot be read is not an empty one. The folder is claimed before the build, by a
# file only one run can create, so that two runs never share it.
if [[ -n $ARCHIVE_DIR ]]; then
    archive_listing=""
    if [[ -e $ARCHIVE_DIR || -L $ARCHIVE_DIR ]]; then
        if [[ ! -d $ARCHIVE_DIR || -L $ARCHIVE_DIR ]] || ! archive_listing="$(ls -A "$ARCHIVE_DIR" 2>/dev/null)" || [[ -n $archive_listing ]]; then
            knot_fail "milestone-build-archive-folder" "The archive's folder $(knot_home_path "$ARCHIVE_DIR") is not a new or empty folder that can be read: an archive is never made over an earlier one." \
                "Name a new folder with --archive. Keep what the old one holds if it is evidence, then remove it by its path." "safe" "nothing"
        fi
    fi
    mkdir -p "$ARCHIVE_DIR" 2>/dev/null && (set -o noclobber && : >"$ARCHIVE_DIR/.claimed") 2>/dev/null ||
        knot_fail "milestone-build-archive-folder" "The archive's folder $(knot_home_path "$ARCHIVE_DIR") could not be claimed: another run holds it, or it cannot be written." \
            "Name a new folder with --archive." "safe" "nothing"
fi
WANTED="ios mac"
[[ $PRODUCTS == both ]] || WANTED=$PRODUCTS

# The milestone builds' logs, which earlier runs left, are filtered for the team's ID as the
# scripts' other logs are (knot_scrub_logs), each keeping its time.
mkdir -p "$KNOT_BUILD/milestone"
knot_scrub_logs "$KNOT_BUILD/milestone"

# ------------------------------------------------------------------ before it builds

# The commit and its tree, as named and as checked out.
named="$(git -C "$KNOT_ROOT" rev-parse --verify --quiet "$COMMIT^{commit}" || true)"
[[ -n $named ]] || knot_fail "milestone-build-commit-unknown" "$COMMIT is not a commit in this repository." \
    "Fetch it, or name the milestone's commit by its hash." "safe" "nothing"
head="$(git -C "$KNOT_ROOT" rev-parse HEAD)"
tree_of() { git -C "$KNOT_ROOT" rev-parse "$1^{tree}"; }
if [[ $head != "$named" ]]; then
    knot_fail "milestone-build-wrong-commit" \
        "HEAD is ${head:0:12} (tree $(tree_of "$head" | cut -c1-12)), not the commit named, ${named:0:12} (tree $(tree_of "$named" | cut -c1-12))." \
        "Check out the commit named in this worktree (git switch --detach ${named:0:12}), or name the commit you mean." \
        "safe" "nothing"
fi
dirty="$(git -C "$KNOT_ROOT" status --porcelain --untracked-files=normal)"
if [[ -n $dirty ]]; then
    knot_fail "milestone-build-dirty" "The worktree has uncommitted changes, in $(grep -c . <<<"$dirty") of its paths: a milestone build is made from a commit alone." \
        "Commit or move the changes away, then rerun: git status names them." "safe" "nothing"
fi
# An ignored file under a folder the build reads is compiled all the same: a Swift file in a
# folder named build/ under Sources, which .gitignore ignores at any depth, is one. Finder's
# .DS_Store files are not read.
ignored="$(git -C "$KNOT_ROOT" ls-files --others --ignored --exclude-standard -- Apps Packages/KnotKit/Sources \
    Packages/KnotKit/Package.swift project.yml | grep -v -e '\(^\|/\)\.DS_Store$' || true)"
if [[ -n $ignored ]]; then
    knot_fail "milestone-build-ignored" "The worktree holds files that git ignores under the folders the build reads, $(grep -c . <<<"$ignored") of them, such as $(head -n 1 <<<"$ignored"): the build would read them, and the commit named does not hold them." \
        "Move them out of Apps/, Packages/KnotKit/Sources/ and the manifests (git ls-files --others --ignored --exclude-standard names them), then rerun." "safe" "nothing"
fi
say "$LEVEL at ${head:0:12}, tree $(tree_of "$head" | cut -c1-12): HEAD is the commit named, and the worktree is clean, ignored files included"

if [[ ! -e $KNOT_CONFIG/Local.xcconfig ]]; then
    knot_fail "milestone-build-no-team" "The team's configuration is not linked into .build/config/Local.xcconfig, so the build would have no team." \
        "Run KNOT_LOCAL_CONFIG=<the owner's Local.xcconfig, outside the repository> scripts/bootstrap.sh, then rerun." "safe" "nothing"
fi
say "the team's configuration is linked into .build/config/"

# The two configurations the build includes that the repository does not hold,
# .build/config/Worktree.xcconfig and Local.xcconfig, may set only their own keys: either could
# otherwise set any setting the command line does not, such as compilation conditions that put
# the fakes into the build. Read by their keys alone; no value is printed.
# config_keys <file>: each key the file sets, one a line; "#include" for an include; and
# "line <n>" for a line that is not a setting, named by its number and never printed, since its
# value may be the team's ID.
config_keys() {
    awk '{
        line = $0
        sub(/\/\/.*$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == "") next
        if (line ~ /^#include/) { print "#include"; next }
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])*[ \t]*=/) { match(line, /^[A-Za-z_][A-Za-z0-9_]*/); print substr(line, RSTART, RLENGTH); next }
        print "line " NR
    }' "$1"
}
for entry in "Worktree.xcconfig KNOT_WORKTREE KNOT_WORKTREE_ID" "Local.xcconfig KNOT_SIGNING DEVELOPMENT_TEAM"; do
    read -r file first second <<<"$entry"
    [[ -e $KNOT_CONFIG/$file ]] || continue
    extra="$(config_keys "$KNOT_CONFIG/$file" | grep -v -x -F -e "$first" -e "$second" | sort -u |
        sed -E 's/^(line [0-9]+)$/\1 (not a setting; not printed)/' | paste -s -d ',' - | sed 's/,/, /g' || true)"
    if [[ -n $extra ]]; then
        knot_fail "milestone-build-config" ".build/config/$file sets more than $first and $second: $extra. A milestone build takes its settings from the repository and the command line." \
            "Take those lines out of the file it names (bootstrap writes Worktree.xcconfig, and Local.xcconfig is the owner's), then rerun." "safe" "nothing"
    fi
done
say "the configurations the build includes set only their own keys"

# The packages' clones under .build/SourcePackages, which git ignores: xcodebuild resolves the
# packages without resetting a checkout that was changed (a probe of 2026-11-24 kept an edit to
# GRDB through -resolvePackageDependencies), so a checkout must stand at the revision that
# Packages/KnotKit/Package.resolved pins, with no change. A missing one is cloned at the pin.
resolved="$KNOT_ROOT/Packages/KnotKit/Package.resolved"
[[ -f $resolved ]] || knot_fail "milestone-build-pins" "Packages/KnotKit/Package.resolved is missing: the packages have no pinned revision." \
    "Check out a commit that holds it." "safe" "nothing"
pins="$(python3 -I -c '
import json, sys
for pin in json.load(open(sys.argv[1])).get("pins", []):
    name = pin.get("location", "").rstrip("/").split("/")[-1]
    if name.endswith(".git"):
        name = name[:-4]
    print("%s\t%s" % (name, pin.get("state", {}).get("revision", "")))
' "$resolved")"
checked_out=0
while IFS=$'\t' read -r name revision; do
    [[ -n $name ]] || continue
    checkout="$KNOT_SOURCE_PACKAGES/checkouts/$name"
    [[ -d $checkout ]] || continue
    at="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || echo unreadable)"
    # Ignored files too: a package's own .gitignore may ignore a folder its sources are read from.
    changes="$(git -C "$checkout" status --porcelain --untracked-files=normal --ignored 2>/dev/null || echo unreadable)"
    if [[ $at != "$revision" || -n $changes ]]; then
        knot_fail "milestone-build-package-checkout" "The checkout of $name in .build/SourcePackages is $( [[ $at != "$revision" ]] && echo "at ${at:0:12}, not the pinned ${revision:0:12}" || echo "changed, in $(grep -c . <<<"$changes") of its paths"): xcodebuild would build it as it is." \
            "Remove .build/SourcePackages/checkouts/$name by its path, so that the build clones it again at its pin, then rerun." "safe" "nothing"
    fi
    checked_out=$((checked_out + 1))
done <<<"$pins"
say "the packages' checkouts stand at their pinned revisions, with no change ($checked_out read)"

# Xcode's saved list of accounts, as a count and nothing else (docs/orchestrator.md): the
# entries under IDE.Identifiers.Prod of DVTDeveloperAccountManagerAppleIDLists. Never the
# Accounts pane, which can show an account that is no longer saved.
accounts="$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -I -c '
import plistlib, sys
try:
    lists = plistlib.loads(sys.stdin.buffer.read()).get("DVTDeveloperAccountManagerAppleIDLists", {})
    print(len(lists.get("IDE.Identifiers.Prod", []) or []))
except Exception:
    print(0)
' 2>/dev/null || echo 0)"
if [[ $accounts == 0 ]]; then
    knot_fail "milestone-build-no-account" "Xcode's saved list of accounts is empty: the build cannot sign, and Xcode's Accounts pane may still show an account." \
        "Ask the owner to quit Xcode, open it again, and sign in to his account in Settings, Apple Accounts. Then rerun." "safe" "nothing"
fi
say "Xcode holds $accounts saved account$( ((accounts == 1)) || echo s)"

# ------------------------------------------------------------------ the builds

identifier() { sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p" "$KNOT_ROOT/Apps/Config/Identifiers.xcconfig" | head -n 1; }
WANT_BUNDLE="$(identifier KNOT_BUNDLE_ID_milestone)"
WANT_VERSION="$(identifier KNOT_MARKETING_VERSION)"
WANT_BUILD="${BUILD_NUMBER:-$(identifier KNOT_BUILD_NUMBER)}"
WANT_TOOL="$(identifier KNOT_TOOL_FILE_milestone)"
[[ -n $WANT_BUNDLE && -n $WANT_VERSION && -n $WANT_BUILD && -n $WANT_TOOL ]] ||
    knot_fail "milestone-build-identifiers" "Apps/Config/Identifiers.xcconfig does not give the milestone's bundle ID, version, build number and tool file." \
        "Read the file: KNOT_BUNDLE_ID_milestone, KNOT_MARKETING_VERSION, KNOT_BUILD_NUMBER and KNOT_TOOL_FILE_milestone." "safe" "nothing"

knot_select_xcode
# The project from this commit's project.yml, with the pinned XcodeGen. Not through
# knot_generate_project: it links the team's configuration again only from KNOT_LOCAL_CONFIG,
# and removes the link without it, so the build would have no team.
# The generated project goes first: XcodeGen leaves files of its own making alone, and a user
# scheme, a mirror setting or a workspace's Package.resolved left in Knot.xcodeproj would reach
# the build.
knot_check_xcodegen || knot_fail "$KNOT_XCODEGEN_CODE" "$KNOT_XCODEGEN_WHAT" "$KNOT_XCODEGEN_FIX" "safe" "nothing"
rm -rf "$KNOT_PROJECT"
(cd "$KNOT_ROOT" && "$KNOT_XCODEGEN_PATH" generate --spec project.yml --quiet)
[[ -e $KNOT_CONFIG/Local.xcconfig ]] ||
    knot_fail "milestone-build-no-team" "The team's configuration was linked, and is not after the project was generated." \
        "Run KNOT_LOCAL_CONFIG=<the owner's Local.xcconfig> scripts/bootstrap.sh, then rerun." "safe" "Knot.xcodeproj, generated"
say "project generated, $(knot_xcode_label)"

plist() { knot_plist "$@"; }
info_of() { knot_info_of "$@"; }

# Every part of a product that carries a signature of its own, innermost first, the Mac app's
# tool among them (knot_parts_of in scripts/lib/bundle.sh).
parts_of() { knot_parts_of "$1" "$WANT_TOOL"; }

# Checks one product: what it says it is, then each part's signature. Prints a line for each,
# and returns non-zero at the first failure, having named it. A failure's detail goes to the
# build's log.
#   check_product <ios|mac> <app> <log>
check_product() {
    local name=$1 app=$2 info bundle version build flavour level part count=0 out
    info="$(info_of "$app")"
    [[ -f $info ]] || { say "$name: no app at ${app#"$KNOT_ROOT"/}"; return 1; }
    parts_of "$app" >/dev/null || { say "$name: its parts cannot be listed: find could not read the product whole"; return 1; }
    bundle="$(plist "$info" CFBundleIdentifier)"
    version="$(plist "$info" CFBundleShortVersionString)"
    build="$(plist "$info" CFBundleVersion)"
    flavour="$(plist "$info" KnotFlavour)"
    level="$(plist "$info" KnotMilestoneLevel)"
    say "$name: $bundle $version ($build), flavour $flavour, level $level"
    local wrong=""
    [[ $bundle == "$WANT_BUNDLE" ]] || wrong="$wrong bundle ID $bundle, not $WANT_BUNDLE;"
    [[ $version == "$WANT_VERSION" ]] || wrong="$wrong version $version, not $WANT_VERSION;"
    [[ $build == "$WANT_BUILD" ]] || wrong="$wrong build number $build, not $WANT_BUILD;"
    [[ $flavour == milestone ]] || wrong="$wrong flavour $flavour, not milestone;"
    [[ $level == "$LEVEL" ]] || wrong="$wrong level $level, not $LEVEL;"
    # Each bundle inside it: a bundle ID under the app's, and the same version and build.
    while IFS= read -r part; do
        [[ $part == *.app || $part == *.appex ]] || continue
        [[ $part == "$(basename "$app")" ]] && continue
        local inner
        inner="$(info_of "$(dirname "$app")/$part")"
        [[ "$(plist "$inner" CFBundleIdentifier)" == "$WANT_BUNDLE".* ]] ||
            wrong="$wrong $part has bundle ID $(plist "$inner" CFBundleIdentifier);"
        [[ "$(plist "$inner" CFBundleShortVersionString) ($(plist "$inner" CFBundleVersion))" == "$WANT_VERSION ($WANT_BUILD)" ]] ||
            wrong="$wrong $part is $(plist "$inner" CFBundleShortVersionString) ($(plist "$inner" CFBundleVersion));"
    done < <(parts_of "$app")
    if [[ $name == mac ]]; then
        # The tool and the app's executable are two files, by their exact names: on a volume
        # that ignores case, a tool named like the app replaces it (WP-22, row 22d).
        local executable listing
        executable="$(plist "$info" CFBundleExecutable)"
        listing="$(ls -1 "$app/Contents/MacOS" 2>/dev/null)"
        grep -x -e "$executable" <<<"$listing" >/dev/null || wrong="$wrong Contents/MacOS holds no file named $executable;"
        grep -x -e "$WANT_TOOL" <<<"$listing" >/dev/null || wrong="$wrong Contents/MacOS holds no tool named $WANT_TOOL;"
    fi
    if [[ -n $wrong ]]; then
        say "$name: the product is not the build asked for:$wrong"
        return 1
    fi
    while IFS= read -r part; do
        if ! out="$(codesign --verify --strict "$(dirname "$app")/$part" 2>&1)"; then
            say "$name: codesign --verify --strict failed on $part: $(head -n 1 <<<"$out" | sed -e "s|$(dirname "$app")/||g" | knot_filter_team)"
            printf 'codesign --verify --strict %s\n%s\n' "$part" "$out" | knot_filter_team >>"$3"
            return 1
        fi
        count=$((count + 1))
    done < <(parts_of "$app")
    say "$name: codesign --verify --strict passed on each of its $count parts, alone: $(parts_of "$app" | tr '\n' ' ' | sed 's/ $//')"
}

# The project's entitlements file of a part, by its bundle ID's suffix under the app's.
entitlements_file() { # entitlements_file <ios|mac> <bundle ID>
    case ${2#"$WANT_BUNDLE"} in
        "") [[ $1 == ios ]] && echo Apps/iOS/Knot-iOS-team.entitlements || echo Apps/macOS/Knot-macOS-team.entitlements ;;
        .widgets) echo Apps/Extensions/Widgets-iOS/Widgets-iOS-team.entitlements ;;
        .watchkitapp) echo Apps/watchOS/Knot-watchOS-team.entitlements ;;
        .watchkitapp.widgets) echo Apps/Extensions/Widgets-watchOS/Widgets-watchOS-team.entitlements ;;
        .cli) echo Apps/macOS/Tool/knot-team.entitlements ;;
    esac
}

# The app groups a plist names, one a line: an entitlements plist, or, with --profile, the
# entitlements of a provisioning profile.
groups_in() {
    python3 -I -c '
import plistlib, sys
try:
    plist = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
if sys.argv[1:] == ["--profile"]:
    plist = plist.get("Entitlements", {})
for group in plist.get("com.apple.security.application-groups", []) or []:
    print(group)
' "$@" 2>/dev/null || true
}

# The app group, before any install (docs/orchestrator.md, "A milestone build"): for the app,
# each app extension, the Watch app and what it embeds, and the Mac app's tool, the groups
# each is signed with and the groups its embedded provisioning profile allows. It fails,
# naming the part, when a part is signed with a group its profile does not allow, or when the
# project's entitlements file gives a part the group and its signature names none. A bare
# executable, the Mac app's tool, carries no profile: only its signature is read. Every name
# it prints passes the team filter, since the Mac's group may carry the team's prefix.
#   check_groups <ios|mac> <app> <log>
check_groups() {
    local name=$1 app=$2 log=$3 base part path bundle file signed allowed group profile count=0
    # Each line it prints goes to the build's log too, filtered: the milestone's evidence.
    note() { say "$1"; printf 'milestone-build: %s\n' "$1" | knot_filter_team >>"$log"; }
    base="$(dirname "$app")"
    while IFS= read -r part; do
        path="$base/$part"
        case $part in
            *.app | *.appex) bundle="$(plist "$(info_of "$path")" CFBundleIdentifier)" ;;
            */Contents/MacOS/"$WANT_TOOL") bundle="$WANT_BUNDLE.cli" ;;
            *) continue ;;
        esac
        file="$(entitlements_file "$name" "$bundle")"
        signed="$(codesign -d --entitlements - --xml "$path" 2>/dev/null | groups_in)"
        if [[ -z $signed ]]; then
            if [[ -n $file && -n "$(groups_in <"$KNOT_ROOT/$file")" ]]; then
                note "$name: $part is signed with no app group, and $file gives it one"
                return 1
            fi
            note "$name: $part: no app group, as $file asks"
            continue
        fi
        profile=""
        for profile in "$path/embedded.mobileprovision" "$path/Contents/embedded.provisionprofile" ""; do
            [[ -z $profile || -f $profile ]] && break
        done
        if [[ -z $profile ]]; then
            if [[ $part == */Contents/MacOS/* ]]; then
                note "$name: $part: signed with $(tr '\n' ' ' <<<"$signed" | sed 's/ $//' | knot_filter_team); a bare executable carries no profile to compare"
                count=$((count + 1))
                continue
            fi
            note "$name: $part is signed with an app group and holds no provisioning profile"
            return 1
        fi
        allowed="$(security cms -D -i "$profile" 2>/dev/null | groups_in --profile)"
        while IFS= read -r group; do
            [[ -n $group ]] || continue
            if ! python3 -I -c 'import fnmatch, sys; sys.exit(0 if any(fnmatch.fnmatchcase(sys.argv[1], a) for a in sys.argv[2:]) else 1)' \
                "$group" $allowed; then
                note "$name: $part is signed with the app group $(knot_filter_team <<<"$group"), which its provisioning profile does not allow; it allows: $(tr '\n' ' ' <<<"${allowed:-none}" | sed 's/ $//' | knot_filter_team)"
                printf 'app group %s: signed %s, profile allows %s\n' "$part" "$(tr '\n' ' ' <<<"$signed")" "$(tr '\n' ' ' <<<"$allowed")" | knot_filter_team >>"$log"
                return 1
            fi
        done <<<"$signed"
        note "$name: $part: app group $(tr '\n' ' ' <<<"$signed" | sed 's/ $//' | knot_filter_team), allowed by its profile"
        count=$((count + 1))
    done < <(parts_of "$app")
    note "$name: the app group checked on $count parts"
}

# Who signed each part: the app's own team, for every part. An ad hoc signature passes
# codesign --verify --strict, so this is the check that each part was signed with the team at
# all. On the Mac, the tool's app groups are the app's. The team is compared in memory and
# never printed: each line says only whether they agree.
#   check_signers <ios|mac> <app> <log>
check_signers() {
    local name=$1 app=$2 log=$3 base part team app_team app_groups tool_groups count=0
    note() { say "$1"; printf 'milestone-build: %s\n' "$1" | knot_filter_team >>"$log"; }
    team_of() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1 || true; }
    base="$(dirname "$app")"
    app_team="$(team_of "$app")"
    if [[ -z $app_team || $app_team == "not set" ]]; then
        note "$name: $(basename "$app") is signed with no team, ad hoc or not at all"
        return 1
    fi
    while IFS= read -r part; do
        team="$(team_of "$base/$part")"
        if [[ $team != "$app_team" ]]; then
            if [[ -z $team || $team == "not set" ]]; then
                note "$name: $part is signed with no team, ad hoc or not at all"
            else
                note "$name: $part is signed by another team than the app's"
            fi
            return 1
        fi
        count=$((count + 1))
    done < <(parts_of "$app")
    note "$name: each of its $count parts is signed by the app's own team"
    if [[ -f $app/Contents/MacOS/$WANT_TOOL ]]; then
        app_groups="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | groups_in | sort)"
        tool_groups="$(codesign -d --entitlements - --xml "$app/Contents/MacOS/$WANT_TOOL" 2>/dev/null | groups_in | sort)"
        if [[ $tool_groups != "$app_groups" ]]; then
            note "$name: the tool's app groups, $(tr '\n' ' ' <<<"${tool_groups:-none}" | sed 's/ $//' | knot_filter_team), are not the app's, $(tr '\n' ' ' <<<"${app_groups:-none}" | sed 's/ $//' | knot_filter_team)"
            return 1
        fi
        note "$name: the tool's app groups are the app's"
    fi
}

# The fakes and the debug launch arguments, in every Mach-O file of a product, as the packaging
# step scans a development Release build: a build that compiled DEBUG or KNOT_FAKES in holds
# them. It fails when it found no Mach-O file, so that it cannot pass by reading nothing.
#   check_binaries <ios|mac> <app> <log>
check_binaries() {
    local name=$1 app=$2 log=$3 status=0
    knot_scan_binaries "$app" || status=$?
    case $status in
        0) say "$name: no fakes and no debug launch argument in its $KNOT_SCAN_COUNT Mach-O files" ;;
        1)
            say "$name: $KNOT_SCAN_FILE holds what a milestone build may not: $(tr '\n' ' ' <<<"$KNOT_SCAN_HELD" | cut -c1-200)"
            printf 'binary scan %s: %s\n' "$KNOT_SCAN_FILE" "$(tr '\n' ' ' <<<"$KNOT_SCAN_HELD")" | knot_filter_team >>"$log"
            return 1 ;;
        *)
            say "$name: $KNOT_SCAN_WHY"
            printf 'binary scan: %s\n' "$KNOT_SCAN_WHY" | knot_filter_team >>"$log"
            return 1 ;;
    esac
}

SUMMARY=()
APPS=()
# A path as the summary names it: relative to the tree when it lies in it.
where() { if [[ $1 == "$KNOT_ROOT"/* ]]; then echo "${1#"$KNOT_ROOT"/}"; else knot_home_path "$1"; fi; }
for product in $WANTED; do
    case $product in
        ios) scheme=Knot-iOS destination=generic/platform=iOS folder=Release-iphoneos ;;
        mac) scheme=Knot-macOS destination=generic/platform=macOS folder=Release ;;
    esac
    derived="$KNOT_BUILD/milestone/$LEVEL-${head:0:12}-$product"
    # The build's log lies beside its derived data, named by level, commit and product: a
    # milestone's evidence, which a later run of verify.sh does not move aside.
    log="$KNOT_BUILD/milestone/milestone-build-$LEVEL-${head:0:12}-$product.log"
    archive=""
    if [[ -n $ARCHIVE_DIR ]]; then
        # An archive, its derived data and its log, all in the folder named, which was new.
        mkdir -p "$ARCHIVE_DIR"
        derived="$ARCHIVE_DIR/DerivedData-$product"
        log="$ARCHIVE_DIR/milestone-build-$LEVEL-${head:0:12}-$product.log"
        archive="$ARCHIVE_DIR/Knot-$product.xcarchive"
    fi
    listing=""
    if [[ -e $derived && ! -d $derived ]] || { [[ -d $derived ]] && { ! listing="$(ls -A "$derived" 2>/dev/null)" || [[ -n $listing ]]; }; } || [[ -s $log ]]; then
        knot_fail "milestone-build-derived-data" "The derived data folder .build/milestone/$(basename "$derived"), or its log, .build/milestone/$(basename "$log"), holds an earlier build: a milestone build is never incremental." \
            "Keep the log if it is evidence, by copying it out; then remove both by their paths, and rerun." "safe" "nothing"
    fi
    mkdir -p "$derived"
    : >"$log"
    say "$product: $( [[ -n $archive ]] && echo "archiving" || echo "building") $scheme, Release, $LEVEL$( [[ -n $BUILD_NUMBER ]] && echo ", build number $BUILD_NUMBER"), in fresh derived data $(where "$derived")$( ((PROVISIONING)) && echo ', with -allowProvisioningUpdates')"
    started=$(knot_now)
    status=0
    slot_time="$(dirname "$derived")/.slot-time-$product"
    rm -f "$slot_time"
    KNOT_MB_SCHEME=$scheme KNOT_MB_DESTINATION=$destination KNOT_MB_DERIVED=$derived KNOT_MB_LEVEL=$LEVEL \
        KNOT_MB_LOG=$log KNOT_MB_PROVISIONING=$PROVISIONING KNOT_MB_SLOT_TIME=$slot_time \
        KNOT_MB_ARCHIVE=$archive KNOT_MB_BUILD_NUMBER=$BUILD_NUMBER \
        "$KNOT_SCRIPTS/build-slot.sh" run --label "milestone-build $product" -- "$KNOT_SCRIPTS/milestone-build.sh" --in-build ||
        status=$?
    # The build's own time, from the moment it held its slot; the wait for the slot apart.
    ended=$(knot_now)
    got_slot="$(cat "$slot_time" 2>/dev/null || echo "$ended")"
    rm -f "$slot_time"
    took="$(knot_duration $((ended - got_slot)))"
    waited="$(knot_duration $((got_slot - started)))"
    # Xcode registers the Mac app it builds with LaunchServices, where the owner's own Knot has
    # the same bundle ID. Once the product's checks have run, pass or fail, or its build has
    # failed, every app in its derived data leaves LaunchServices; the product stays on disk
    # for the copy.
    unregister() {
        local status=0 why=""
        knot_unregister_apps "$derived" || { status=1; why=$KNOT_UNREGISTER_WHY; }
        if [[ -n $archive ]] && ! knot_unregister_apps "$archive"; then
            status=1
            why="${why:+$why; }$KNOT_UNREGISTER_WHY"
        fi
        if ((status == 0)); then
            say "$product: its products are unregistered from LaunchServices; they stay on disk"
        else
            KNOT_UNREGISTER_WHY=$why
            say "$product: $(knot_unregister_report "${ARCHIVE_DIR:-$derived}"); they stay on disk"
        fi
    }
    if ((status != 0)); then
        unregister
        say "$product: the build failed after $took, after waiting $waited for a build slot. The last lines of its log:"
        grep -E 'error:|BUILD FAILED|ARCHIVE FAILED|did not end within' "$log" | tail -n 10 | knot_filter_team | sed 's/^/    /' || true
        knot_fail "milestone-build-failed" "The milestone build of $scheme failed. Its log is $(where "$log")." \
            "Read the log. A signing error that names an account, a profile or a device needs the owner: say so, and do not pass a flag he has not allowed." \
            "safe" "derived data in $(where "$derived"); nothing installed"
    fi
    say "$product: built in $took, after waiting $waited for a build slot"
    app="$derived/Build/Products/$folder/Knot.app"
    [[ -z $archive ]] || app="$archive/Products/Applications/Knot.app"
    checked=0
    if check_product "$product" "$app" "$log" && check_signers "$product" "$app" "$log" &&
        check_groups "$product" "$app" "$log" && check_binaries "$product" "$app" "$log"; then
        checked=1
    fi
    unregister
    if ((checked == 0)); then
        knot_fail "milestone-build-check" "The $product product failed its check, named above. Nothing is installed." \
            "Do not install it. Read $(where "$log"), then build again in fresh derived data." \
            "safe" "derived data in $(where "$derived"); nothing installed"
    fi
    if [[ -n $archive ]]; then
        # The archive is the product: the derived data it was made from goes, once checked.
        rm -rf "$derived"
        say "$product: the archive passed every check; its derived data is removed"
    fi
    APPS+=("$product=$app")
    SUMMARY+=("$product: $(plist "$(info_of "$app")" CFBundleIdentifier) $WANT_VERSION ($WANT_BUILD), $LEVEL, $( [[ -n $archive ]] && echo archived || echo built) in $took (the wait for a slot apart), every part verified, at $(where "${archive:-$app}"), its log $(where "$log")")
done

# The summary comes before any install, so that an install that fails leaves the build's
# paths on the screen.
say "summary, $LEVEL at ${head:0:12}:"
for line in "${SUMMARY[@]}"; do printf '    %s\n' "$line"; done

# ------------------------------------------------------------------ then

# A failed install leaves the build whole and checked: it says so, names the command that
# installs it again from its path, and goes on to the next product. The run fails at the end.
if ((INSTALL)); then
    missed=()
    for entry in "${APPS[@]}"; do
        product=${entry%%=*}
        app=${entry#*=}
        options=()
        if [[ $product == ios ]]; then
            for device in ${DEVICES[@]+"${DEVICES[@]}"}; do options+=(--device "$device"); done
            ((AGAIN)) && options+=(--again)
        else
            options=(--mac-folder "$MAC_FOLDER")
        fi
        say "$product: scripts/install.sh"
        if ! "$KNOT_SCRIPTS/install.sh" "$app" ${options[@]+"${options[@]}"}; then
            again="$(printf '%q' "$KNOT_SCRIPTS/install.sh") $(printf '%q' "$app")"
            for option in ${options[@]+"${options[@]}"}; do again="$again $(printf '%q' "$option")"; done
            say "$product: the install failed. The build is whole and checked, at ${app#"$KNOT_ROOT"/}. Install it again from there, from any folder: $again"
            [[ $product == ios ]] ||
                say "mac: if $MAC_FOLDER holds part of the copy, move it away first: install.sh refuses a folder that holds the app already."
            say "$product: do not rerun milestone-build.sh for it: it would refuse the folder that holds this build."
            missed+=("$product")
        fi
    done
    if ((${#missed[@]})); then
        knot_fail "milestone-build-install" "The install of ${missed[*]} failed, named above. The build is whole and checked." \
            "Run the install command printed above for each, once the devices are unlocked and near, or the folder is free." \
            "safe" "the products that installed above"
    fi
fi
((INSTALL)) || say "nothing installed and nothing started"
