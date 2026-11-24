#!/bin/bash
# Makes a milestone build, from a named commit, in one command (docs/orchestrator.md, "A
# milestone build"; docs/dev-setup.md, the table of builds).
#
#   scripts/milestone-build.sh <M1…M7> --commit <sha> [--products ios|mac|both]
#       [--allow-provisioning-updates] [--install [--device <name>]… [--again] [--mac-folder <folder>]]
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
#
# Before it builds, it stops, saying what to do, when the worktree has uncommitted changes,
# when HEAD is not the commit named, when the team's configuration is not linked into
# .build/config/, and when Xcode's saved list of accounts is empty, which it reads as a
# count and nothing else. Each product is built in fresh derived data of its own, a new
# folder under .build/milestone/, the Release configuration, through scripts/build-slot.sh.
# After each build it reads the bundle ID, the version, the build number, the flavour and
# the level from the product and compares them with the level asked for and with
# Apps/Config/Identifiers.xcconfig, then runs codesign --verify --strict on every part, each
# alone, innermost first. It stops at the first failure, naming the part, and installs
# nothing. It never starts what it builds: a milestone build that runs opens the owner's own
# store. It prints no team ID and no signing identity. Each build's log lies beside its
# derived data, .build/milestone/milestone-build-<level>-<commit>-<product>.log, filtered for
# the team's ID as it is written; a run of verify.sh does not move it.

source "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "milestone-build-usage" "$1" "Run scripts/milestone-build.sh --help." "safe" "nothing"; }
say() { printf 'milestone-build: %s\n' "$1"; }

# ------------------------------------------------------------------ one build, in a slot

# A build runs in a second process that holds a build slot, under the build limit. It finds
# its settings in the environment: KNOT_MB_SCHEME, KNOT_MB_DESTINATION, KNOT_MB_DERIVED,
# KNOT_MB_LEVEL, KNOT_MB_LOG and KNOT_MB_PROVISIONING (1 or 0).
if [[ ${1:-} == --in-build ]]; then
    knot_select_xcode
    build() {
        local flags=()
        [[ $KNOT_MB_PROVISIONING == 1 ]] && flags+=(-allowProvisioningUpdates)
        # The log is filtered as it is written: Xcode writes the team's prefix into it.
        { xcodebuild -project "$KNOT_PROJECT" -derivedDataPath "$KNOT_MB_DERIVED" \
            -clonedSourcePackagesDirPath "$KNOT_SOURCE_PACKAGES" -configuration Release \
            -scheme "$KNOT_MB_SCHEME" -destination "$KNOT_MB_DESTINATION" \
            ${flags[@]+"${flags[@]}"} \
            KNOT_FLAVOUR=milestone KNOT_MILESTONE_LEVEL="$KNOT_MB_LEVEL" KNOT_SIGNING=team \
            COMPILER_INDEX_STORE_ENABLE=NO build 2>&1 | knot_filter_team >>"$KNOT_MB_LOG"; } 2>/dev/null # limit: build
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
        -h | --help) usage; exit 0 ;;
        *) usage_fail "Unknown argument: $1" ;;
    esac
done
[[ -n $LEVEL ]] || usage_fail "Name the level, M1 to M7."
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
say "$LEVEL at ${head:0:12}, tree $(tree_of "$head" | cut -c1-12): HEAD is the commit named, and the worktree is clean"

if [[ ! -e $KNOT_CONFIG/Local.xcconfig ]]; then
    knot_fail "milestone-build-no-team" "The team's configuration is not linked into .build/config/Local.xcconfig, so the build would have no team." \
        "Run KNOT_LOCAL_CONFIG=<the owner's Local.xcconfig, outside the repository> scripts/bootstrap.sh, then rerun." "safe" "nothing"
fi
say "the team's configuration is linked into .build/config/"

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
WANT_BUILD="$(identifier KNOT_BUILD_NUMBER)"
WANT_TOOL="$(identifier KNOT_TOOL_FILE_milestone)"
[[ -n $WANT_BUNDLE && -n $WANT_VERSION && -n $WANT_BUILD && -n $WANT_TOOL ]] ||
    knot_fail "milestone-build-identifiers" "Apps/Config/Identifiers.xcconfig does not give the milestone's bundle ID, version, build number and tool file." \
        "Read the file: KNOT_BUNDLE_ID_milestone, KNOT_MARKETING_VERSION, KNOT_BUILD_NUMBER and KNOT_TOOL_FILE_milestone." "safe" "nothing"

knot_select_xcode
# The project from this commit's project.yml, with the pinned XcodeGen. Not through
# knot_generate_project: it links the team's configuration again only from KNOT_LOCAL_CONFIG,
# and removes the link without it, so the build would have no team.
knot_check_xcodegen || knot_fail "$KNOT_XCODEGEN_CODE" "$KNOT_XCODEGEN_WHAT" "$KNOT_XCODEGEN_FIX" "safe" "nothing"
(cd "$KNOT_ROOT" && "$KNOT_XCODEGEN_PATH" generate --spec project.yml --quiet)
[[ -e $KNOT_CONFIG/Local.xcconfig ]] ||
    knot_fail "milestone-build-no-team" "The team's configuration was linked, and is not after the project was generated." \
        "Run KNOT_LOCAL_CONFIG=<the owner's Local.xcconfig> scripts/bootstrap.sh, then rerun." "safe" "Knot.xcodeproj, generated"
say "project generated, $(knot_xcode_label)"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
info_of() { if [[ -f $1/Contents/Info.plist ]]; then echo "$1/Contents/Info.plist"; else echo "$1/Info.plist"; fi; }

# Every part of a product that carries a signature of its own, innermost first: each app
# extension, the Watch app and what it embeds, each framework, the Mac app's tool, then the
# app. Each line is a path relative to the folder that holds the app.
parts_of() {
    local app=$1 base
    base="$(dirname "$app")"
    {
        find "$app" -mindepth 1 -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \) -print 2>/dev/null || true
        [[ ! -f $app/Contents/MacOS/$WANT_TOOL ]] || echo "$app/Contents/MacOS/$WANT_TOOL"
    } | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1rn -k2 | cut -f2- | sed "s|^$base/||"
    echo "$(basename "$app")"
}

# Checks one product: what it says it is, then each part's signature. Prints a line for each,
# and returns non-zero at the first failure, having named it. A failure's detail goes to the
# build's log.
#   check_product <ios|mac> <app> <log>
check_product() {
    local name=$1 app=$2 info bundle version build flavour level part count=0 out
    info="$(info_of "$app")"
    [[ -f $info ]] || { say "$name: no app at ${app#"$KNOT_ROOT"/}"; return 1; }
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

SUMMARY=()
APPS=()
for product in $WANTED; do
    case $product in
        ios) scheme=Knot-iOS destination=generic/platform=iOS folder=Release-iphoneos ;;
        mac) scheme=Knot-macOS destination=generic/platform=macOS folder=Release ;;
    esac
    derived="$KNOT_BUILD/milestone/$LEVEL-${head:0:12}-$product"
    # The build's log lies beside its derived data, named by level, commit and product: a
    # milestone's evidence, which a later run of verify.sh does not move aside.
    log="$KNOT_BUILD/milestone/milestone-build-$LEVEL-${head:0:12}-$product.log"
    if [[ -d $derived && -n "$(ls -A "$derived" 2>/dev/null)" ]] || [[ -s $log ]]; then
        knot_fail "milestone-build-derived-data" "The derived data folder .build/milestone/$(basename "$derived"), or its log, .build/milestone/$(basename "$log"), holds an earlier build: a milestone build is never incremental." \
            "Keep the log if it is evidence, by copying it out; then remove both by their paths, and rerun." "safe" "nothing"
    fi
    mkdir -p "$derived"
    : >"$log"
    say "$product: building $scheme, Release, $LEVEL, in fresh derived data .build/milestone/$(basename "$derived")$( ((PROVISIONING)) && echo ', with -allowProvisioningUpdates')"
    started=$(knot_now)
    status=0
    KNOT_MB_SCHEME=$scheme KNOT_MB_DESTINATION=$destination KNOT_MB_DERIVED=$derived KNOT_MB_LEVEL=$LEVEL \
        KNOT_MB_LOG=$log KNOT_MB_PROVISIONING=$PROVISIONING \
        "$KNOT_SCRIPTS/build-slot.sh" run --label "milestone-build $product" -- "$KNOT_SCRIPTS/milestone-build.sh" --in-build ||
        status=$?
    took="$(knot_duration $(($(knot_now) - started)))"
    if ((status != 0)); then
        say "$product: the build failed after $took. The last lines of its log:"
        grep -E 'error:|BUILD FAILED|did not end within' "$log" | tail -n 10 | knot_filter_team | sed 's/^/    /' || true
        knot_fail "milestone-build-failed" "The milestone build of $scheme failed. Its log is .build/milestone/$(basename "$log")." \
            "Read the log. A signing error that names an account, a profile or a device needs the owner: say so, and do not pass a flag he has not allowed." \
            "safe" "derived data in .build/milestone/$(basename "$derived"); nothing installed"
    fi
    say "$product: built in $took"
    app="$derived/Build/Products/$folder/Knot.app"
    if ! check_product "$product" "$app" "$log"; then
        knot_fail "milestone-build-check" "The $product product failed its check, named above. Nothing is installed." \
            "Do not install it. Read .build/milestone/$(basename "$log"), then build again in fresh derived data." \
            "safe" "derived data in .build/milestone/$(basename "$derived"); nothing installed"
    fi
    APPS+=("$product=$app")
    SUMMARY+=("$product: $(plist "$(info_of "$app")" CFBundleIdentifier) $WANT_VERSION ($WANT_BUILD), $LEVEL, built in $took, every part verified, at ${app#"$KNOT_ROOT"/}, its log .build/milestone/$(basename "$log")")
done

# ------------------------------------------------------------------ then

if ((INSTALL)); then
    for entry in "${APPS[@]}"; do
        product=${entry%%=*}
        app=${entry#*=}
        if [[ $product == ios ]]; then
            options=()
            for device in ${DEVICES[@]+"${DEVICES[@]}"}; do options+=(--device "$device"); done
            ((AGAIN)) && options+=(--again)
            say "ios: scripts/install.sh"
            "$KNOT_SCRIPTS/install.sh" "$app" ${options[@]+"${options[@]}"}
        else
            say "mac: scripts/install.sh --mac-folder"
            "$KNOT_SCRIPTS/install.sh" "$app" --mac-folder "$MAC_FOLDER"
        fi
    done
fi

say "summary, $LEVEL at ${head:0:12}:"
for line in "${SUMMARY[@]}"; do printf '    %s\n' "$line"; done
((INSTALL)) || say "nothing installed and nothing started"
