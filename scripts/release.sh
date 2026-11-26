#!/bin/bash
# Takes a milestone build to App Store Connect, and fails closed (docs/architecture.md §18,
# docs/plan/WP-43.md). Four ways to run it:
#
#   scripts/release.sh <M1…M7> --commit <sha> --build-number <n>      a dry run, the default
#   scripts/release.sh <M1…M7> --commit <sha> --build-number <n> --validate
#   scripts/release.sh <M1…M7> --commit <sha> --build-number <n> --upload
#   scripts/release.sh --rehearsal <M1…M7> --build-number <n>
#
#   a dry run    the candidate: scripts/milestone-build.sh archives the iPhone app, with its
#                Watch app and widgets, at the level, from the commit, with the build number
#                given, signed for development, and makes every check it makes of a build;
#                then every check below on the archive, and a list of what an upload would do.
#                It prints the names of the variables it would read, never their values. It
#                contacts what the milestone build contacts, and App Store Connect never.
#   --validate   the dry run, then the export for App Store Connect with distribution signing,
#                the checks of what would be uploaded, and App Store Connect's own validation,
#                with no upload. On the owner's word.
#   --upload     the validation, then the upload of the file that was checked, once. On the
#                owner's word, each time.
#   --rehearsal  for an agent and for the gate: it archives the development flavour, signed by
#                nothing, at the level and the build number given, from the worktree as it is,
#                and runs on that archive every check below that reads no signature. It signs
#                nothing and contacts nothing: it resolves no package, and refuses when the
#                pinned checkout under .build/SourcePackages is not there.
#
#   --products ios        the default and, until SP-3 reports, the only product
#   --allow-provisioning-updates
#                passed to scripts/milestone-build.sh, on the owner's word only
#
# The App Store Connect key, for --validate and --upload, in three environment variables:
# KNOT_ASC_KEY_PATH, the path of the key's .p8 file, KNOT_ASC_KEY_ID, ten capitals and digits,
# and KNOT_ASC_ISSUER_ID, a UUID. The script turns tracing off before it reads any of them,
# takes them out of its environment at once, and hands them to nothing but the two commands
# that authenticate, xcodebuild -exportArchive and altool, in their arguments. Every line it
# prints or writes passes a filter that masks their values, the key file's path as given, made
# absolute and resolved, and the team's ID (knot_filter_team). Known: while those two tools run,
# the path and the two IDs are in their arguments, which the owner's own processes can read.
#
# A validation and an upload refuse every stand-in the self-test uses: KNOT_ALTOOL,
# KNOT_ASSETUTIL, KNOT_LSREGISTER, KNOT_SLOT_DIR and KNOT_XCODEGEN, and a KNOT_XCODE that names
# another Xcode than the pinned one. Every run takes xcodebuild and altool from the selected
# Xcode, and its other tools from /usr/bin, with PATH set to the system's folders alone. No run
# starts while XCODE_XCCONFIG_FILE is set, since its settings override the command line's.
#
# Before anything is built it reads the tree: the level, which is refused when it opens sync and
# the tree has no committed CloudKit schema file, so every level from M4 on is refused until that
# file's path is named below; the evidence of each milestone below the level, its annotated tag
# m<n> at or before the commit, the convention the tag m1 shows; and the App Store icons' sources,
# which may carry no alpha channel. The checks on the archive, each naming the part that fails:
# the four parts at their paths, with their identifiers and platforms; one version, the
# candidate's, above 0.2.0, the build number given, one flavour and one level; the Release
# configuration and the pinned Xcode; no fakes and no debug launch argument; a privacy manifest
# with the reasons the lint finds needed; the usage strings each part is known to need;
# ITSAppUsesNonExemptEncryption false; an opaque 1024 by 1024 App Store icon for each device
# family. After the export, on the file that would be uploaded: the same, then every signature
# verified, every signed entitlement allowed by its part's profile, push and iCloud in
# production, the milestone's app group and container, no get-task-allow, one team, and profiles
# with no device list. Every inspector's status is read: one that failed is a failure.
#
# Known, and not checked: the scan of imports for protected resources is a help that can miss
# one; an optimised binary can hide a short string from the scan for fakes and debug arguments;
# and nothing can read from the uploaded file that it is for internal testing only, which the
# export's options ask for below M7.
#
# One release run works in a worktree at a time: it holds a lock, .build/release/.lock, through a
# descriptor its children inherit, so the lock is held until every one of them has ended. Each
# run works in a new folder, .build/release/<mode>-<level>-<commit>-b<n>-<UTC time>-<4 letters>/,
# with its log, release.log, and its own tmp/, where the tools keep their temporary files. On a
# signal it ends its children, then cleans, then leaves. On every way out it removes tmp/,
# filters the files Xcode leaves beside the exported Knot.ipa, and removes Xcode's distribution
# logs of the run, wherever they were written, keeping a filtered copy in the run's folder when
# the export or the validation failed or was cut short. Under the lock, a run removes what dead
# runs left in their tmp/. A run that was cut short is never resumed. After a failed or
# interrupted upload it says to check App Store Connect before a retry, and does not retry.
{ set +xv; } 2>/dev/null

# The key, out of the environment before anything starts.
RL_KEY_PATH=${KNOT_ASC_KEY_PATH-} RL_KEY_ID=${KNOT_ASC_KEY_ID-} RL_ISSUER=${KNOT_ASC_ISSUER_ID-}
RL_KEY_PATH_SET=${KNOT_ASC_KEY_PATH+set} RL_KEY_ID_SET=${KNOT_ASC_KEY_ID+set} RL_ISSUER_SET=${KNOT_ASC_ISSUER_ID+set}
unset KNOT_ASC_KEY_PATH KNOT_ASC_KEY_ID KNOT_ASC_ISSUER_ID
# The stand-ins the self-test uses, as the environment holds them before common.sh sets defaults.
RL_SEAMS=""
for seam in KNOT_ALTOOL KNOT_ASSETUTIL KNOT_LSREGISTER KNOT_SLOT_DIR KNOT_XCODEGEN; do
    [[ -z ${!seam+set} ]] || RL_SEAMS="$RL_SEAMS $seam"
done
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/bundle.sh
source "$KNOT_SCRIPTS/lib/bundle.sh"

usage() { sed -n '2,75p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "release-usage" "$1" "Run scripts/release.sh --help." "safe" "nothing"; }

# The committed CloudKit schema file, which appears with the production schema (docs/plan/WP-43.md,
# Failure rules). No document names its path yet (docs/plan/open-points.md, item 1): until the
# orchestrator names it here, every level that opens sync is refused.
CLOUDKIT_SCHEMA_FILE=""

# The forms of the key's path: as given, made absolute, and resolved, symbolic links and all. The
# path reaches python through its environment, never its arguments.
RL_KEY_ABSOLUTE="" RL_KEY_REAL=""
if [[ -n $RL_KEY_PATH ]]; then
    RL_KEY_ABSOLUTE="$(KNOT_RL_P="$RL_KEY_PATH" python3 -I -c 'import os; print(os.path.abspath(os.environ["KNOT_RL_P"]))')"
    RL_KEY_REAL="$(KNOT_RL_P="$RL_KEY_PATH" python3 -I -c 'import os; print(os.path.realpath(os.environ["KNOT_RL_P"]))')"
fi

# Masks the key's values, the path's three forms first, then the team's ID. The values reach perl
# through its environment, given to it alone, never its arguments.
RELEASE_FILTER='
    BEGIN {
        @masks = ();
        for my $pair (["KNOT_RL_M1", "<KEY-PATH>"], ["KNOT_RL_M2", "<KEY-PATH>"], ["KNOT_RL_M3", "<KEY-PATH>"],
                      ["KNOT_RL_M4", "<KEY-ID>"], ["KNOT_RL_M5", "<ISSUER-ID>"]) {
            my $value = $ENV{$pair->[0]} // "";
            push @masks, [$value, $pair->[1]] if length($value) >= 4;
        }
        @masks = sort { length($b->[0]) <=> length($a->[0]) } @masks;
    }
    for my $mask (@masks) { my ($value, $name) = @$mask; s/\Q$value\E/$name/g; }
'
release_filter() {
    KNOT_RL_M1="$RL_KEY_REAL" KNOT_RL_M2="$RL_KEY_ABSOLUTE" KNOT_RL_M3="$RL_KEY_PATH" KNOT_RL_M4="$RL_KEY_ID" \
        KNOT_RL_M5="$RL_ISSUER" perl -pe "$RELEASE_FILTER" | knot_filter_team
}
# Filters a file in place, as release_filter filters a stream.
filter_in_place() {
    KNOT_RL_M1="$RL_KEY_REAL" KNOT_RL_M2="$RL_KEY_ABSOLUTE" KNOT_RL_M3="$RL_KEY_PATH" KNOT_RL_M4="$RL_KEY_ID" \
        KNOT_RL_M5="$RL_ISSUER" perl -pi -e "$RELEASE_FILTER" "$1" &&
        KNOT_FILTER_CONFIG="$(knot_filter_config)" perl -pi -e "$KNOT_TEAM_FILTER" "$1"
}

LOG=""
say() {
    local line
    line="$(printf 'release: %s\n' "$1" | release_filter)"
    printf '%s\n' "$line"
    [[ -z $LOG ]] || printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
}
# A command's output, filtered, to the run's log and, with --show, the terminal.
logged() { if [[ ${1:-} == --show ]]; then release_filter | tee -a "$LOG"; else release_filter >>"$LOG"; fi; }

# XCODE_XCCONFIG_FILE names settings that override even those given on xcodebuild's command line
# (man xcodebuild, ENVIRONMENT): no run starts while it is set, the worker's included.
refuse_xcconfig_override() {
    [[ -z ${XCODE_XCCONFIG_FILE+set} ]] ||
        knot_fail "release-xcconfig-override" "XCODE_XCCONFIG_FILE is set: its settings would override the ones the release's builds give on the command line, the rehearsal's development identifiers and its no-signing among them." \
            "Unset XCODE_XCCONFIG_FILE, then rerun." "safe" "nothing"
}

# ------------------------------------------------------------------ the rehearsal's archive, in a slot

# The rehearsal's archive runs in a second process that holds a build slot. It finds its settings
# in the environment: KNOT_RL_DERIVED, KNOT_RL_ARCHIVE, KNOT_RL_LEVEL, KNOT_RL_BUILD and
# KNOT_RL_LOG. The development flavour, signed by nothing: no build of release.sh carries the
# milestone's identifiers (AGENTS.md). Xcode resolves no package: it takes the pinned checkout
# that the caller found in .build/SourcePackages, and updates nothing from its remote.
if [[ ${1:-} == --in-archive ]]; then
    refuse_xcconfig_override
    knot_select_xcode
    XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
    rehearsal_archive() {
        { "$XCODEBUILD" -project "$KNOT_PROJECT" -derivedDataPath "$KNOT_RL_DERIVED" \
            -clonedSourcePackagesDirPath "$KNOT_SOURCE_PACKAGES" -disableAutomaticPackageResolution -skipPackageUpdates \
            -configuration Release -scheme Knot-iOS -destination generic/platform=iOS \
            KNOT_FLAVOUR=dev KNOT_MILESTONE_LEVEL="$KNOT_RL_LEVEL" KNOT_SIGNING=local \
            KNOT_BUILD_NUMBER="$KNOT_RL_BUILD" DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO \
            COMPILER_INDEX_STORE_ENABLE=NO archive -archivePath "$KNOT_RL_ARCHIVE" 2>&1 | knot_filter_team >>"$KNOT_RL_LOG"; } 2>/dev/null # limit: rehearsal_archive
    }
    knot_run_limited "The rehearsal's archive of Knot-iOS" "$KNOT_BUILD_LIMIT" rehearsal_archive
    exit $?
fi

# ------------------------------------------------------------------ arguments

# No argument is echoed back: a usage error names the flag, or the argument's place.
MODE=dry-run
LEVEL=""
COMMIT=""
BUILD=""
PRODUCTS=ios
PROVISIONING=0
arguments=$#
while [[ $# -gt 0 ]]; do
    place=$((arguments - $# + 1))
    case $1 in
        M[1-7]) [[ -z $LEVEL ]] || usage_fail "Name one level."; LEVEL=$1; shift ;;
        --commit) COMMIT=${2:-}; [[ -n $COMMIT ]] || usage_fail "--commit needs a commit."; shift 2 ;;
        --build-number)
            BUILD=${2:-}
            [[ $BUILD =~ ^[1-9][0-9]{0,8}$ ]] || usage_fail "--build-number takes a whole number above 0."
            shift 2 ;;
        --products)
            PRODUCTS=${2:-}
            [[ $PRODUCTS == ios || $PRODUCTS == mac || $PRODUCTS == both ]] || usage_fail "--products takes ios, mac or both."
            shift 2 ;;
        --validate | --upload | --rehearsal)
            [[ $MODE == dry-run ]] || usage_fail "Name one of --rehearsal, --validate and --upload, or none for a dry run."
            MODE=${1#--}
            shift ;;
        --allow-provisioning-updates) PROVISIONING=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage_fail "Argument $place is not one this script takes." ;;
    esac
done
[[ -n $LEVEL ]] || usage_fail "Name the level, M1 to M7."
[[ -n $BUILD ]] || usage_fail "Name the build number with --build-number <n>: App Store Connect takes each once, and Apps/Config/Identifiers.xcconfig's is 1 for every build."
if [[ $MODE == rehearsal ]]; then
    [[ -z $COMMIT ]] || usage_fail "A rehearsal archives the worktree as it is: leave out --commit."
    ((PROVISIONING == 0)) || usage_fail "A rehearsal signs nothing: leave out --allow-provisioning-updates."
else
    [[ -n $COMMIT ]] || usage_fail "Name the commit the candidate is made from: --commit <sha>."
fi
if [[ $PRODUCTS != ios ]]; then
    knot_fail "release-mac-sp3" "The Mac app is not released yet: its upload rests on SP-3, whose check in a profile-validated build is still open. Its export, as an installer package, follows SP-3's report in a later pull request." \
        "Release the iPhone app, with its Watch app and widgets: --products ios, the default." "safe" "nothing"
fi
LEVEL_NUMBER=${LEVEL#M}
refuse_xcconfig_override

# ------------------------------------------------------------------ one run at a time

# The lock is taken on a descriptor of this shell, 9, which every child inherits: flock holds it
# until the last descriptor on it is closed, so until this run and everything it started have
# ended. A run that finds it held stops at once.
mkdir -p "$KNOT_BUILD/release"
exec 9>>"$KNOT_BUILD/release/.lock"
lock_status=0
/usr/bin/perl -MFcntl=:flock -e 'open(my $fh, ">>&=", 9) or exit 2; flock($fh, LOCK_EX | LOCK_NB) or exit 75; exit 0' || lock_status=$?
if ((lock_status != 0)); then
    knot_fail "release-busy" "Another release run in this worktree, or a process it started, holds .build/release/.lock$( ((lock_status == 75)) || echo ", or the lock could not be taken")." \
        "Wait for that run to end; a run is made one at a time. If none runs, find what holds the file with lsof .build/release/.lock." "safe" "nothing"
fi
# What dead runs left in their tmp/: no other run is alive under the lock.
for left in "$KNOT_BUILD"/release/*/tmp; do
    [[ -d $left ]] || continue
    rm -rf "$left"
done

# ------------------------------------------------------------------ signals and the way out

RUN="" TMP="" EXPORT="" EXPORT_MARK="" PHASE="" KEEP_DIAGNOSIS=0 DERIVED=""

# Ends every child of this shell, and theirs (knot_end_process).
end_children() {
    local child
    for child in $(pgrep -P $$ 2>/dev/null); do
        knot_end_process "$child"
    done
}

# Xcode's distribution logs of this run, wherever it wrote them: in the run's tmp/xcode/, which is
# the TMPDIR the export is given, in the user's own temporary folder, newer than the export's
# start, and at the path xcodebuild names. Each is removed; when the export or the validation
# failed or was cut short, a filtered copy stays in the run's folder, distribution-logs/.
collect_distribution_logs() {
    [[ -n $EXPORT_MARK && -e $EXPORT_MARK ]] || return 0
    local user_tmp found name kept=0
    user_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
    {
        find "$TMP/xcode" -maxdepth 1 -name '*.xcdistributionlogs' -print 2>/dev/null || true
        [[ -z $user_tmp ]] || find "${user_tmp%/}" -maxdepth 1 -name '*.xcdistributionlogs' -newer "$EXPORT_MARK" -print 2>/dev/null || true
        sed -n -E 's/.*Created bundle at path "([^"]+\.xcdistributionlogs)".*/\1/p' "$LOG" 2>/dev/null || true
    } | sort -u >"$TMP/distribution-logs" || true
    while IFS= read -r found; do
        [[ -n $found && -d $found ]] || continue
        case $found in "$TMP"/* | "${user_tmp%/}"/*) ;; *) continue ;; esac
        if ((KEEP_DIAGNOSIS)); then
            name="$(basename "$found")"
            (cd "$found" && find . -type f -print) 2>/dev/null | while IFS= read -r file; do
                mkdir -p "$RUN/distribution-logs/$name/$(dirname "$file")"
                release_filter <"$found/$file" >"$RUN/distribution-logs/$name/$file" 2>/dev/null || true
            done
            kept=1
        fi
        rm -rf "$found"
    done <"$TMP/distribution-logs"
    ((kept == 0)) || printf 'release: what Xcode wrote of the export, filtered: .build/release/%s/distribution-logs/\n' "$(basename "$RUN")" >&2
}

# The files Xcode leaves beside the exported Knot.ipa, such as DistributionSummary.plist, name
# the team: each is filtered in place.
scrub_export_files() {
    [[ -n $EXPORT && -d $EXPORT ]] || return 0
    local file
    while IFS= read -r -d '' file; do
        filter_in_place "$file" 2>/dev/null || rm -f "$file"
    done < <(find "$EXPORT" -type f ! -name Knot.ipa -print0 2>/dev/null)
}

finish() {
    local status=$?
    trap '' HUP INT TERM
    end_children
    collect_distribution_logs || true
    scrub_export_files || true
    if [[ -n $DERIVED && -d $DERIVED ]]; then
        knot_unregister_apps "$DERIVED" >/dev/null 2>&1 || true
        rm -rf "$DERIVED"
    fi
    [[ -z $TMP ]] || rm -rf "$TMP"
    exit "$status"
}
on_signal() {
    local code=$1
    trap '' HUP INT TERM
    end_children
    KEEP_DIAGNOSIS=1
    case $PHASE in
        upload)
            knot_report "release-upload-interrupted" "The upload of build $BUILD was cut short by a signal: it may have reached App Store Connect. It was not retried." \
                "Check App Store Connect, the app's TestFlight builds, for build $BUILD, before any retry: the upload may have reached it. A retry needs the owner's word, and a build number App Store Connect has not taken." \
                "unsafe" "the upload may have reached App Store Connect; the run's folder holds the export" || true ;;
        validate)
            knot_report "release-validation-interrupted" "App Store Connect's validation was cut short by a signal. Nothing was uploaded." \
                "Make a new run: a run is never resumed." "safe" "the run's folder" || true ;;
        export)
            knot_report "release-export-interrupted" "The export for App Store Connect was cut short by a signal. Nothing was sent to App Store Connect." \
                "Make a new run: a run is never resumed." "safe" \
                "Xcode may have made a distribution certificate or an App Store profile in the owner's account; the run's folder" || true ;;
    esac
    exit "$code"
}
trap finish EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# Runs a command in the background and waits for it, so that a signal reaches the trap at once.
waited() {
    "$@" &
    wait $!
}

# ------------------------------------------------------------------ the tree

knot_select_xcode
if knot_is_beta_build "$KNOT_XCODE_BUILD"; then
    knot_fail "release-beta-xcode" "The Xcode is $(knot_xcode_label): App Store Connect takes no build of a beta Xcode." \
        "Unset KNOT_XCODE, so that the release Xcode that .xcode-version pins is used." "safe" "nothing"
fi
PINNED_BUILD=$KNOT_XCODE_BUILD
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
ALTOOL="$DEVELOPER_DIR/usr/bin/altool"
NM="$(xcrun --find nm 2>/dev/null)" || knot_fail "release-tool" "The pinned Xcode gives no nm." "Run the Xcode once to finish its installation." "safe" "nothing"

if [[ $MODE == rehearsal ]]; then
    COMMIT_NAMED=""
    AT="$(git -C "$KNOT_ROOT" rev-parse HEAD)"
else
    COMMIT_NAMED="$(git -C "$KNOT_ROOT" rev-parse --verify --quiet "$COMMIT^{commit}" || true)"
    [[ -n $COMMIT_NAMED ]] || knot_fail "release-commit-unknown" "The commit named with --commit is not a commit in this repository." \
        "Fetch it, or name the milestone's commit by its hash." "safe" "nothing"
    AT=$COMMIT_NAMED
fi

# Reads a file of the tree: of the commit named, or, for a rehearsal, of the worktree as it is.
# A symbolic link is followed inside the tree. With png it prints, for each PNG file of a folder,
# its path, its colour type and whether it holds a tRNS chunk, tab-separated. Any failure to read
# exits non-zero.
read -r -d '' TREE_PY <<'PY' || true
import os, posixpath, struct, subprocess, sys
root, commit, command, path = sys.argv[1:5]

def git(*args):
    return subprocess.run(["git", "-C", root] + list(args), check=True, capture_output=True).stdout

def entry(p):
    out = git("ls-tree", "-z", commit, "--", p).split(b"\0")[0]
    if not out:
        return None
    meta, _ = out.split(b"\t", 1)
    mode, _, sha = meta.decode().split()
    return mode, sha

def read(p, depth=0):
    if not commit:
        full = os.path.join(root, p)
        if not os.path.isfile(full):
            return None
        with open(full, "rb") as f:
            return f.read()
    found = entry(p)
    if found is None or depth > 8:
        return None
    mode, sha = found
    data = git("cat-file", "blob", sha)
    if mode == "120000":
        return read(posixpath.normpath(posixpath.join(posixpath.dirname(p), data.decode())), depth + 1)
    return data

def listing(folder):
    if not commit:
        full = os.path.join(root, folder)
        return sorted(os.path.join(folder, n) for n in os.listdir(full)) if os.path.isdir(full) else []
    out = git("ls-tree", "-z", "--name-only", commit, "--", folder.rstrip("/") + "/")
    return sorted(n.decode() for n in out.split(b"\0") if n)

if command == "cat":
    data = read(path)
    if data is None:
        sys.exit(1)
    sys.stdout.buffer.write(data)
elif command == "png":
    for p in listing(path):
        if not p.endswith(".png"):
            continue
        data = read(p)
        if data is None:
            sys.exit("%s cannot be read" % p)
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            print("%s\tnot a PNG\t0" % p)
            continue
        ctype = data[25]
        pos, trns = 8, 0
        while pos + 8 <= len(data):
            (length,) = struct.unpack(">I", data[pos:pos + 4])
            if data[pos + 4:pos + 8] == b"tRNS":
                trns = 1
            pos += 12 + length
        print("%s\t%d\t%d" % (p, ctype, trns))
PY
tree() { python3 -I -c "$TREE_PY" "$KNOT_ROOT" "$COMMIT_NAMED" "$@"; }
FAILURES=()
refuse() { FAILURES+=("$1"); say "FAIL  $1"; }

# The identifiers of the family the archive must carry, and the candidate's version.
identifiers="$(tree cat Apps/Config/Identifiers.xcconfig)" ||
    knot_fail "release-identifiers" "Apps/Config/Identifiers.xcconfig cannot be read at ${AT:0:12}." "Read the tree." "safe" "nothing"
setting() { sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p" <<<"$identifiers" | head -n 1; }
FAMILY=milestone FLAVOUR=milestone
[[ $MODE != rehearsal ]] || FAMILY=dev FLAVOUR=dev
WANT_BUNDLE="$(setting "KNOT_BUNDLE_ID_$FAMILY")"
WANT_GROUP="$(setting "KNOT_APP_GROUP_$FAMILY")"
WANT_CONTAINER="$(setting "KNOT_CLOUD_CONTAINER_$FAMILY")"
WANT_VERSION="$(setting KNOT_MARKETING_VERSION)"
MILESTONE_BUNDLE="$(setting KNOT_BUNDLE_ID_milestone)"
[[ -n $WANT_BUNDLE && -n $WANT_GROUP && -n $WANT_CONTAINER && -n $WANT_VERSION && -n $MILESTONE_BUNDLE ]] ||
    knot_fail "release-identifiers" "Apps/Config/Identifiers.xcconfig at ${AT:0:12} does not give the $FAMILY family's bundle ID, app group and iCloud container, and the version." \
        "Read the file: KNOT_BUNDLE_ID_$FAMILY, KNOT_APP_GROUP_$FAMILY, KNOT_CLOUD_CONTAINER_$FAMILY and KNOT_MARKETING_VERSION." "safe" "nothing"

say "$MODE of $LEVEL, build number $BUILD, at ${AT:0:12}$( [[ $MODE == rehearsal ]] && echo ", the worktree as it is"), $(knot_xcode_label) at $(knot_home_path "${DEVELOPER_DIR%/Contents/Developer}")"

# The level. Sync opens at the level that KnotCore's Feature.opensAt gives it, read from the
# tree; a level at or above it needs the committed CloudKit schema file, since a TestFlight build
# uses CloudKit's production environment.
gates="$(tree cat Packages/KnotKit/Sources/KnotCore/Settings/FeatureGates.swift 2>/dev/null)" || gates=""
sync_opens="$(sed -n -E 's/^[[:space:]]*case[^:]*\.sync[,:][^:]*:[[:space:]]*\.m([1-7])[[:space:]]*$/\1/p' <<<"$gates" | head -n 1)"
if [[ -z $sync_opens ]]; then
    refuse "level: the level at which sync opens cannot be read from Feature.opensAt in Packages/KnotKit/Sources/KnotCore/Settings/FeatureGates.swift"
elif ((LEVEL_NUMBER >= sync_opens)); then
    if [[ -z $CLOUDKIT_SCHEMA_FILE ]]; then
        refuse "level: $LEVEL opens sync, which opens at M$sync_opens, and the tree has no committed CloudKit schema file: no path is named for it yet (docs/plan/open-points.md, item 1), and a TestFlight build syncs in CloudKit's production environment"
    elif ! tree cat "$CLOUDKIT_SCHEMA_FILE" >/dev/null 2>&1; then
        refuse "level: $LEVEL opens sync, which opens at M$sync_opens, and the tree at ${AT:0:12} holds no $CLOUDKIT_SCHEMA_FILE, the committed CloudKit schema"
    else
        say "ok    level: $LEVEL opens sync, and the tree holds the committed CloudKit schema, $CLOUDKIT_SCHEMA_FILE"
    fi
else
    say "ok    level: $LEVEL keeps sync shut, which opens at M$sync_opens"
fi

# The evidence of each milestone below the level: its annotated tag, m<n>, which the orchestrator
# makes on the owner's word once the milestone's checklist has passed, and which names the
# milestone build's commit; the candidate is that commit or one after it. That is the convention
# the tag m1 shows; the orchestrator writes it into the runbook.
evidence="" evidence_ok=1
for ((i = 1; i < LEVEL_NUMBER; i++)); do
    kind="$(git -C "$KNOT_ROOT" cat-file -t "refs/tags/m$i" 2>/dev/null || true)"
    if [[ $kind != tag ]]; then
        refuse "evidence: M$i has no evidence: the repository holds no annotated tag m$i$( [[ -n $kind ]] && echo ", only a tag that is not annotated")"
        evidence_ok=0
    elif ! git -C "$KNOT_ROOT" merge-base --is-ancestor "refs/tags/m$i^{commit}" "$AT" 2>/dev/null; then
        refuse "evidence: M$i's tag, m$i, names a commit that ${AT:0:12} does not hold"
        evidence_ok=0
    else
        evidence="$evidence, m$i"
    fi
done
if ((evidence_ok)); then
    if ((LEVEL_NUMBER == 1)); then
        say "ok    evidence: M1 has no milestone below it"
    else
        say "ok    evidence: the annotated tags of the milestones below $LEVEL, at or before ${AT:0:12}: ${evidence#, }"
    fi
fi

# The App Store icons' sources: a PNG of an iPhone's or a Watch's icon set may carry no alpha
# channel, which App Store Connect refuses; the compiled catalogue no longer shows the source's.
icons_ok=1
for set in Apps/iOS/Assets.xcassets/AppIcon.appiconset Apps/watchOS/Assets.xcassets/AppIcon.appiconset; do
    if ! pngs="$(tree png "$set" 2>/dev/null)"; then
        refuse "icons: the PNG files of $set cannot be read"
        icons_ok=0
        continue
    fi
    found=0
    while IFS=$'\t' read -r png ctype trns; do
        [[ -n $png ]] || continue
        found=1
        if [[ $ctype == "not a PNG" ]]; then
            refuse "icons: $png is not a PNG"
            icons_ok=0
        elif [[ $ctype == 4 || $ctype == 6 || $trns == 1 ]]; then
            refuse "icons: $png carries an alpha channel, which App Store Connect refuses in an App Store icon"
            icons_ok=0
        fi
    done <<<"$pngs"
    if ((found == 0)); then
        refuse "icons: $set holds no PNG"
        icons_ok=0
    fi
done
((icons_ok == 0)) || say "ok    icons: the iPhone's and the Watch's icon sources carry no alpha channel"

# The key: three variables, read for their forms and nothing else, and never printed. The dry run
# reads them only to say which are set.
key_state() { # key_state <path|id|issuer>
    case $1 in
        path)
            if [[ -z $RL_KEY_PATH_SET ]]; then echo "not set"
            elif [[ -f $RL_KEY_PATH && -r $RL_KEY_PATH ]]; then echo "set, a readable file"
            else echo "set, but no readable file"; fi ;;
        id)
            if [[ -z $RL_KEY_ID_SET ]]; then echo "not set"
            elif [[ $RL_KEY_ID =~ ^[A-Z0-9]{10}$ ]]; then echo "set"
            else echo "set, but not ten capitals and digits"; fi ;;
        issuer)
            if [[ -z $RL_ISSUER_SET ]]; then echo "not set"
            elif [[ $RL_ISSUER =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then echo "set"
            else echo "set, but not a UUID"; fi ;;
    esac
}
key_line() { echo "KNOT_ASC_KEY_PATH ($(key_state path)), KNOT_ASC_KEY_ID ($(key_state id)), KNOT_ASC_ISSUER_ID ($(key_state issuer))"; }
if [[ $MODE != rehearsal ]]; then
    for part in path:KNOT_ASC_KEY_PATH id:KNOT_ASC_KEY_ID issuer:KNOT_ASC_ISSUER_ID; do
        state="$(key_state "${part%%:*}")"
        case $state in
            set | "set, a readable file") ;;
            "not set") [[ $MODE == dry-run ]] || refuse "key: ${part#*:} is not set" ;;
            *) refuse "key: ${part#*:} is $state" ;;
        esac
    done
fi

# A validation and an upload take their tools from the pinned Xcode and the system alone.
if [[ $MODE == validate || $MODE == upload ]]; then
    for seam in $RL_SEAMS; do
        refuse "tools: $seam is set, a stand-in the self-test uses: a validation and an upload take their tools from the pinned Xcode and the system alone"
    done
    [[ -z $KNOT_XCODE_NOTE ]] || refuse "tools: the Xcode is $(knot_xcode_label): a validation and an upload take their tools from the pinned Xcode alone"
fi

if ((${#FAILURES[@]})); then
    knot_fail "release-refused" "The candidate is refused before anything is built: ${#FAILURES[@]} check$( ((${#FAILURES[@]} == 1)) || echo s) failed, each named above." \
        "Read each FAIL line. A level whose evidence or schema is missing waits for them; it is never forced." "safe" "nothing"
fi

# ------------------------------------------------------------------ the run's folder

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN="$(mktemp -d "$KNOT_BUILD/release/$MODE-$LEVEL-${AT:0:12}-b$BUILD-$STAMP-XXXX")"
TMP="$RUN/tmp"
mkdir -m 700 "$TMP"
LOG="$RUN/release.log"
: >"$LOG"
say "the run's folder is .build/release/$(basename "$RUN"), its log release.log"

# ------------------------------------------------------------------ the archive

if [[ $MODE == rehearsal ]]; then
    # The packages, as the milestone build reads them: each pin of Packages/KnotKit/Package.resolved
    # checked out under .build/SourcePackages at its revision, with no change. The rehearsal
    # resolves nothing, so a missing checkout stops it.
    resolved="$KNOT_ROOT/Packages/KnotKit/Package.resolved"
    pins="$(python3 -I -c '
import json, sys
for pin in json.load(open(sys.argv[1])).get("pins", []):
    name = pin.get("location", "").rstrip("/").split("/")[-1]
    if name.endswith(".git"):
        name = name[:-4]
    print("%s\t%s" % (name, pin.get("state", {}).get("revision", "")))
' "$resolved" 2>/dev/null)" || knot_fail "release-pins" "Packages/KnotKit/Package.resolved cannot be read." "Check out a tree that holds it." "safe" "the run's folder"
    while IFS=$'\t' read -r name revision; do
        [[ -n $name ]] || continue
        checkout="$KNOT_SOURCE_PACKAGES/checkouts/$name"
        at="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || echo missing)"
        changes="$(git -C "$checkout" status --porcelain --untracked-files=normal --ignored 2>/dev/null || echo unreadable)"
        if [[ $at != "$revision" || -n $changes ]]; then
            knot_fail "release-pins" "The checkout of $name in .build/SourcePackages is $( [[ $at == missing ]] && echo "not there" || echo "not at its pin, ${revision:0:12}, unchanged"): the rehearsal resolves no package, so that it contacts nothing." \
                "Run scripts/verify.sh --only pins, which resolves the packages at their pins, then rerun." "safe" "the run's folder"
        fi
    done <<<"$pins"
    say "ok    pins: the packages' checkouts stand at their pinned revisions; Xcode is told to resolve and update none"
    knot_check_xcodegen || knot_fail "$KNOT_XCODEGEN_CODE" "$KNOT_XCODEGEN_WHAT" "$KNOT_XCODEGEN_FIX" "safe" "nothing"
    # The project is generated afresh, and the team's configuration is left as it is linked.
    rm -rf "$KNOT_PROJECT"
    (cd "$KNOT_ROOT" && "$KNOT_XCODEGEN_PATH" generate --spec project.yml --quiet)
    ARCHIVE="$RUN/Knot-ios.xcarchive"
    derived="$RUN/DerivedData"
    DERIVED=$derived
    say "archiving Knot-iOS, Release, the development flavour, $LEVEL, build number $BUILD, signed by nothing, in fresh derived data"
    status=0
    waited env KNOT_RL_DERIVED="$derived" KNOT_RL_ARCHIVE="$ARCHIVE" KNOT_RL_LEVEL="$LEVEL" KNOT_RL_BUILD="$BUILD" \
        KNOT_RL_LOG="$RUN/archive.log" "$KNOT_SCRIPTS/build-slot.sh" run --label "release rehearsal" -- "$KNOT_SCRIPTS/release.sh" --in-archive ||
        status=$?
    knot_unregister_apps "$RUN" || say "$(knot_unregister_report "$RUN")"
    rm -rf "$derived"
    if ((status != 0)); then
        grep -E 'error:|BUILD FAILED|ARCHIVE FAILED|did not end within' "$RUN/archive.log" 2>/dev/null | tail -n 10 | sed 's/^/    /' | logged --show || true
        knot_fail "release-rehearsal-archive" "The rehearsal's archive failed. Its log is .build/release/$(basename "$RUN")/archive.log." \
            "Read the log." "safe" "the run's folder"
    fi
else
    say "the candidate: scripts/milestone-build.sh $LEVEL --commit ${AT:0:12} --products ios --archive, build number $BUILD"
    options=()
    ((PROVISIONING == 0)) || options+=(--allow-provisioning-updates)
    candidate() {
        "$KNOT_SCRIPTS/milestone-build.sh" "$LEVEL" --commit "$AT" --products ios --archive "$RUN/candidate" \
            --build-number "$BUILD" ${options[@]+"${options[@]}"} 2>&1 | logged --show
    }
    status=0
    waited candidate || status=$?
    if ((status != 0)); then
        knot_fail "release-candidate" "The milestone build of the candidate failed, as it said above." \
            "Read its lines and its log in .build/release/$(basename "$RUN")/candidate/." "safe" "the run's folder"
    fi
    ARCHIVE="$RUN/candidate/Knot-ios.xcarchive"
fi
APP="$ARCHIVE/Products/Applications/Knot.app"
[[ -d $APP ]] || knot_fail "release-no-archive" "The archive holds no app at $(basename "$ARCHIVE")/Products/Applications/Knot.app." \
    "Read the archive's log in the run's folder." "safe" "the run's folder"

# ------------------------------------------------------------------ the checks on a product

# The required-reason categories the lint finds in the reach of each of the tree's privacy
# manifests, by its own lists and functions (REQUIRED_REASON and MANIFESTS in knot_tool.py), read
# from the worktree, which the candidate's milestone build found at the commit named.
read -r -d '' REASONS_PY <<'PY' || true
import json, re, sys
sys.path.insert(0, sys.argv[1])
import knot_tool as k
used = {}
for path in k.swift_files():
    for number, line, _ in k.code_lines(path):
        for category, pattern in k.REQUIRED_REASON.items():
            if re.search(pattern, line):
                used.setdefault(category, set()).add(path)
needed = {}
for manifest, reach in k.MANIFESTS.items():
    need = set()
    for category, places in used.items():
        for place in places:
            module = k.module_of(place)
            if any(place.startswith(r) for r in reach if r.endswith("/")) or \
                    (module is not None and not place.startswith(k.LIBRARY_EXEMPT) and ("*" in reach or module in reach)):
                need.add(category)
    needed[manifest] = sorted(need)
print(json.dumps(needed))
PY
REASONS="$(cd "$KNOT_ROOT" && python3 -I -c "$REASONS_PY" "$KNOT_SCRIPTS/lib")" ||
    knot_fail "release-reasons" "The lint's required-reason rules could not be read over the tree." \
        "Run scripts/verify.sh --only lint, and read what it says." "safe" "the run's folder"

# One program for the checks that read the product's files. Arguments, key=value: app, archive
# (for its dSYMs, or empty), bundle, group, container, flavour, level, build, version, xcode (the
# pinned build), reasons (the lint's, as JSON), the tools nm, assetutil, codesign and security,
# and checks, a comma-separated list of: roles, configuration, privacy, usage, encryption, icons
# and signatures, the last after the export. It prints "ok    <check>: …" or "FAIL  <check>:
# <part>: …" for each, and exits 1 when any failed. Every inspector's status is read.
read -r -d '' CHECKS_PY <<'PY' || true
import fnmatch, glob, json, os, plistlib, re, subprocess, sys

a = dict(arg.split("=", 1) for arg in sys.argv[1:])
app, archive = a["app"], a.get("archive", "")
base, group, container = a["bundle"], a["group"], a["container"]
flavour, level, build, version, xcode = a["flavour"], a["level"], a["build"], a["version"], a["xcode"]
reasons = json.loads(a["reasons"])
NM, ASSETUTIL, CODESIGN, SECURITY = a["nm"], a["assetutil"], a["codesign"], a["security"]
root = os.path.dirname(app)
failures = 0
# The four parts of the upload: role, path inside the app, bundle ID suffix, platform, the tree's
# privacy manifest that its own lint reads, and the usage strings the part is known to need.
ROLES = [
    ("app", "", "", "iphoneos", "Apps/iOS/PrivacyInfo.xcprivacy", ["NSMicrophoneUsageDescription"]),
    ("widget", "PlugIns/Widgets-iOS.appex", ".widgets", "iphoneos", "Apps/Extensions/Widgets-iOS/PrivacyInfo.xcprivacy", []),
    ("watch", "Watch/Knot.app", ".watchkitapp", "watchos", "Apps/watchOS/PrivacyInfo.xcprivacy", ["NSMicrophoneUsageDescription"]),
    ("watch-widget", "Watch/Knot.app/PlugIns/Widgets-watchOS.appex", ".watchkitapp.widgets", "watchos",
     "Apps/Extensions/Widgets-watchOS/PrivacyInfo.xcprivacy", []),
]
# A help that can miss: the Objective-C classes whose use asks for a protected resource, and the
# usage strings any one of which the part's Info.plist must then hold.
USAGE = [
    ("the microphone", ["AVAudioApplication", "AVAudioRecorder"], ["NSMicrophoneUsageDescription"]),
    ("the camera", ["AVCaptureDevice", "AVCaptureSession"], ["NSCameraUsageDescription"]),
    ("speech recognition", ["SFSpeechRecognizer"], ["NSSpeechRecognitionUsageDescription"]),
    ("the photo library", ["PHPhotoLibrary", "PHAsset"], ["NSPhotoLibraryUsageDescription"]),
    ("the location", ["CLLocationManager"], ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"]),
    ("the contacts", ["CNContactStore"], ["NSContactsUsageDescription"]),
    ("the calendars and reminders", ["EKEventStore"], ["NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription", "NSRemindersFullAccessUsageDescription"]),
    ("Bluetooth", ["CBCentralManager", "CBPeripheralManager"], ["NSBluetoothAlwaysUsageDescription"]),
    ("motion", ["CMMotionActivityManager", "CMPedometer"], ["NSMotionUsageDescription"]),
    ("health data", ["HKHealthStore"], ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"]),
    ("the media library", ["MPMediaLibrary", "MPMediaQuery"], ["NSAppleMusicUsageDescription"]),
    ("Siri", ["INPreferences"], ["NSSiriUsageDescription"]),
    ("Face ID", ["LAContext"], ["NSFaceIDUsageDescription"]),
    ("tracking", ["ATTrackingManager"], ["NSUserTrackingUsageDescription"]),
    ("HomeKit", ["HMHomeManager"], ["NSHomeKitUsageDescription"]),
    ("nearby interaction", ["NISession"], ["NSNearbyInteractionUsageDescription"]),
]
IDIOMS = {1: "phone", 2: "pad", 4: "watch"}
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"}
# Entitlement values that may be printed: none holds the team's ID.
PRINTABLE = {"aps-environment", "com.apple.developer.icloud-container-environment",
             "com.apple.developer.icloud-container-identifiers", "com.apple.security.application-groups",
             "com.apple.developer.icloud-services", "get-task-allow"}

def rel(p):
    return os.path.relpath(p, root)

def fail(check, part, what):
    global failures
    failures += 1
    print("FAIL  %s: %s: %s" % (check, part, what), flush=True)

def ok(check, what):
    print("ok    %s: %s" % (check, what), flush=True)

def plist_of(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except Exception:
        return None

def info(part):
    for p in (os.path.join(part, "Contents", "Info.plist"), os.path.join(part, "Info.plist")):
        if os.path.isfile(p):
            value = plist_of(p)
            return value if isinstance(value, dict) else None
    return None

def run(command):
    try:
        return subprocess.run(command, capture_output=True)
    except OSError as error:
        return subprocess.CompletedProcess(command, 127, b"", str(error).encode())

def walk_error(error):
    raise error

# Every part of the product, by a walk whose failure is a failure.
parts, unreadable = [app], None
try:
    for folder, dirs, _ in os.walk(app, onerror=walk_error):
        parts += [os.path.join(folder, d) for d in dirs if d.endswith((".app", ".appex"))]
except OSError as error:
    unreadable = str(error)
parts.sort()
roles = {name: os.path.join(app, path) if path else app for name, path, *_ in ROLES}
role_of = {path: name for name, path in roles.items()}

def check_roles():
    before = failures
    if unreadable:
        fail("roles", rel(app), "the product cannot be read whole: %s" % unreadable)
    for name, path, suffix, platform, _, _ in ROLES:
        part = roles[name]
        i = info(part) if os.path.isdir(part) else None
        if i is None:
            fail("roles", rel(part), "the %s is not there, or its Info.plist cannot be read" % name)
            continue
        if i.get("CFBundleIdentifier") != base + suffix:
            fail("roles", rel(part), "bundle ID %s, not %s" % (i.get("CFBundleIdentifier") or "(none)", base + suffix))
        if i.get("DTPlatformName") != platform:
            fail("roles", rel(part), "built for %s, not %s" % (i.get("DTPlatformName") or "no platform it names", platform))
        v = i.get("CFBundleShortVersionString", "")
        if v != version:
            fail("roles", rel(part), "version %s, not the candidate's %s" % (v or "(none)", version))
        if i.get("CFBundleVersion") != build:
            fail("roles", rel(part), "build number %s, not %s" % (i.get("CFBundleVersion"), build))
        if i.get("KnotFlavour") != flavour:
            fail("roles", rel(part), "flavour %s, not %s" % (i.get("KnotFlavour") or "none", flavour))
        if part.endswith(".app") or "KnotMilestoneLevel" in i:
            if i.get("KnotMilestoneLevel") != level:
                fail("roles", rel(part), "level %s, not %s" % (i.get("KnotMilestoneLevel") or "none", level))
        for key, want in (("KnotAppGroup", group), ("KnotCloudContainer", container), ("WKCompanionAppBundleIdentifier", base)):
            if key in i and i[key] != want:
                fail("roles", rel(part), "%s %s, not %s" % (key, i[key], want))
        if name == "watch" and i.get("WKCompanionAppBundleIdentifier") != base:
            fail("roles", rel(part), "names no companion app %s" % base)
    for part in parts:
        if part not in role_of:
            fail("roles", rel(part), "a part the release does not know: the upload holds the app, its widgets, the Watch app and its widgets alone")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or tuple(int(n) for n in version.split(".")) <= (0, 2, 0):
        fail("roles", rel(app), "the candidate's version %s is not three numbers above 0.2.0, the retired app's" % version)
    if failures == before:
        ok("roles", "the app, its widgets, the Watch app and its widgets, at their paths, of %s, %s (%s), flavour %s, level %s; the extensions that name no level: %s" % (
            base, version, build, flavour, level,
            ", ".join(rel(p) for p in parts if "KnotMilestoneLevel" not in (info(p) or {})) or "none"))

def check_configuration():
    before = failures
    for folder, dirs, files in os.walk(app):
        for name in files:
            if name.endswith(".debug.dylib") or name == "__preview.dylib":
                fail("configuration", rel(os.path.join(folder, name)), "the debug dylib of Xcode's Debug configuration (ENABLE_DEBUG_DYLIB): no Release build holds it")
        for name in dirs:
            if name.endswith(".xctest"):
                fail("configuration", rel(os.path.join(folder, name)), "a test bundle, which no Release archive holds")
    for part in parts:
        built = (info(part) or {}).get("DTXcodeBuild", "")
        if built != xcode:
            fail("configuration", rel(part), "built with Xcode %s, not the pinned %s" % (built or "(not named)", xcode))
    if archive and not glob.glob(os.path.join(archive, "dSYMs", "*.dSYM")):
        fail("configuration", "dSYMs", "the archive holds no dSYM: its debug information is the Debug configuration's, dwarf, and not Release's, dwarf-with-dsym")
    if failures == before:
        ok("configuration", "Release: no debug dylib, no test bundle, every part built by the pinned Xcode, %s%s" % (xcode, ", with dSYMs" if archive else ""))

def check_privacy():
    before = failures
    for name, _, _, _, manifest_path, _ in ROLES:
        part = roles[name]
        path = os.path.join(part, "PrivacyInfo.xcprivacy")
        manifest = plist_of(path) if os.path.isfile(path) else None
        if not isinstance(manifest, dict):
            fail("privacy", rel(part), "no privacy manifest, PrivacyInfo.xcprivacy, that reads as a plist")
            continue
        if manifest.get("NSPrivacyTracking") is not False:
            fail("privacy", rel(part), "its privacy manifest does not say NSPrivacyTracking false")
        if manifest.get("NSPrivacyCollectedDataTypes") != []:
            fail("privacy", rel(part), "its privacy manifest declares collected data, or does not say: NSPrivacyCollectedDataTypes is not an empty list")
        declared = {e.get("NSPrivacyAccessedAPIType") for e in manifest.get("NSPrivacyAccessedAPITypes", []) or []
                    if isinstance(e, dict) and e.get("NSPrivacyAccessedAPITypeReasons")}
        for category in reasons.get(manifest_path, []):
            if category not in declared:
                fail("privacy", rel(part), "its privacy manifest gives no reason for %s, which the lint finds in the reach of %s" % (category, manifest_path))
    if failures == before:
        ok("privacy", "a privacy manifest in each of its 4 parts, declaring no tracking, no collected data, and a reason for every required-reason API the lint finds in its reach")

def macho_files():
    for folder, _, files in os.walk(app, onerror=walk_error):
        for name in files:
            path = os.path.join(folder, name)
            with open(path, "rb") as f:
                if f.read(4) in MACHO:
                    yield path

def owner(path):
    return max((p for p in roles.values() if path.startswith(p + "/")), key=len)

def check_usage():
    before = failures
    for name, _, _, _, _, needed in ROLES:
        i = info(roles[name]) or {}
        for key in needed:
            if not (isinstance(i.get(key), str) and i.get(key).strip()):
                fail("usage", rel(roles[name]), "no %s, which the %s is known to need" % (key, name))
    symbols = {p: set() for p in roles.values()}
    read = {p: 0 for p in roles.values()}
    try:
        for path in macho_files():
            result = run([NM, "-u", "-j", path])
            if result.returncode != 0:
                fail("usage", rel(path), "nm could not read it")
                continue
            part = owner(path)
            read[part] += 1
            symbols[part] |= {s.strip() for s in result.stdout.decode("utf-8", "replace").splitlines()}
    except OSError as error:
        fail("usage", rel(app), "the product cannot be read whole: %s" % error)
    asked = []
    for part in roles.values():
        if not read[part]:
            fail("usage", rel(part), "no Mach-O file of it could be read")
        i = info(part) or {}
        for what, classes, keys in USAGE:
            uses = [c for c in classes if "_OBJC_CLASS_$_" + c in symbols[part]]
            if not uses:
                continue
            held = [k for k in keys if isinstance(i.get(k), str) and i.get(k).strip()]
            if held:
                asked.append("%s uses %s, and says why in %s" % (rel(part), ", ".join(uses), held[0]))
            else:
                fail("usage", rel(part), "uses %s, which asks for %s, and has no usage string: %s" % (", ".join(uses), what, " or ".join(keys)))
    if failures == before:
        ok("usage", "the usage strings each part is known to need are there; the scan of imports, a help that can miss, finds: %s" % ("; ".join(asked) or "nothing"))

def check_encryption():
    before = failures
    apps = [p for p in roles.values() if p.endswith(".app")]
    for part in apps:
        value = (info(part) or {}).get("ITSAppUsesNonExemptEncryption")
        if value is None:
            fail("encryption", rel(part), "no ITSAppUsesNonExemptEncryption: App Store Connect would ask about encryption at each upload")
        elif value is not False:
            fail("encryption", rel(part), "ITSAppUsesNonExemptEncryption is not false: the upload would need export compliance documents")
    if failures == before:
        ok("encryption", "ITSAppUsesNonExemptEncryption false in each of its %d apps" % len(apps))

def check_icons():
    before = failures
    checked = []
    for name in ("app", "watch"):
        part = roles[name]
        i = info(part) or {}
        icon = ((i.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon") or {}).get("CFBundleIconName")
        families = i.get("UIDeviceFamily") or []
        if not icon or not families:
            fail("icons", rel(part), "its Info.plist names no icon set, CFBundleIconName, or no device family")
            continue
        car = os.path.join(part, "Assets.car")
        if not os.path.isfile(car):
            fail("icons", rel(part), "no asset catalogue, Assets.car, so no App Store icon")
            continue
        result = run([ASSETUTIL, "--info", car])
        try:
            if result.returncode != 0:
                raise ValueError
            renditions = json.loads(result.stdout)
        except Exception:
            fail("icons", rel(part), "assetutil could not read its Assets.car")
            continue
        icons = [r for r in renditions if isinstance(r, dict) and r.get("AssetType") == "Icon Image" and r.get("Name") == icon
                 and r.get("PixelWidth") == 1024 and r.get("PixelHeight") == 1024]
        for family in families:
            idiom = IDIOMS.get(family)
            if not any(r.get("Idiom") == idiom for r in icons):
                fail("icons", rel(part), "no App Store icon of 1024 by 1024 of its icon set %s for the %s" % (icon, idiom or "family %s" % family))
        for r in icons:
            if r.get("Opaque") is not True:
                fail("icons", rel(part), "its App Store icon %s (%s) is not opaque" % (r.get("RenditionName"), r.get("Idiom")))
        checked.append("%s (%s)" % (rel(part), ", ".join(IDIOMS.get(f, str(f)) for f in families)))
    if failures == before:
        ok("icons", "an opaque App Store icon of 1024 by 1024 in %s" % ", ".join(checked))

def allowed(value, permit):
    """Whether a signed entitlement's value is one its profile allows."""
    if isinstance(permit, list):
        values = value if isinstance(value, list) else [value]
        return all(any(allowed(v, p) for p in permit) for v in values)
    if isinstance(value, list):
        return all(allowed(v, permit) for v in value)
    if isinstance(permit, str) and isinstance(value, str):
        return fnmatch.fnmatchcase(value, permit)
    if isinstance(permit, bool) and isinstance(value, bool):
        return value == permit or not value
    return value == permit

def check_signatures():
    before = failures
    signed = []
    try:
        for folder, dirs, _ in os.walk(app, onerror=walk_error):
            signed += [os.path.join(folder, d) for d in dirs if d.endswith((".app", ".appex", ".framework", ".xpc"))]
    except OSError as error:
        fail("signatures", rel(app), "the product cannot be read whole: %s" % error)
    signed = sorted(signed, key=lambda p: -p.count("/")) + [app]
    for part in signed:
        result = run([CODESIGN, "--verify", "--strict", part])
        if result.returncode != 0:
            fail("signatures", rel(part), "codesign --verify --strict failed on it")
    teams = set()
    for part in roles.values():
        result = run([CODESIGN, "-d", "--entitlements", "-", "--xml", part])
        try:
            if result.returncode != 0 or not result.stdout.strip():
                raise ValueError
            e = plistlib.loads(result.stdout)
            if not isinstance(e, dict) or not e:
                raise ValueError
        except Exception:
            fail("signatures", rel(part), "its entitlements cannot be read from its signature, or are empty")
            continue
        profile = os.path.join(part, "embedded.mobileprovision")
        result = run([SECURITY, "cms", "-D", "-i", profile]) if os.path.isfile(profile) else None
        try:
            if result is None or result.returncode != 0:
                raise ValueError
            p = plistlib.loads(result.stdout)
            permits = p.get("Entitlements")
            if not isinstance(p, dict) or not isinstance(permits, dict) or not permits:
                raise ValueError
        except Exception:
            fail("signatures", rel(part), "no provisioning profile that security can read, with entitlements")
            continue
        if "ProvisionedDevices" in p:
            fail("signatures", rel(part), "its provisioning profile has a device list: a development or ad hoc profile, not App Store Connect's")
        if p.get("ProvisionsAllDevices"):
            fail("signatures", rel(part), "its provisioning profile provisions every device: an enterprise profile")
        for key, value in e.items():
            if key not in permits or not allowed(value, permits[key]):
                fail("signatures", rel(part), "it is signed with %s%s, which its provisioning profile does not allow" % (
                    key, " " + json.dumps(value) if key in PRINTABLE else ""))
        team = (p.get("TeamIdentifier") or [None])[0]
        identifier = e.get("application-identifier", "")
        if not team or identifier != "%s.%s" % (team, base + dict((n, s) for n, _, s, *_ in ROLES)[role_of[part]]):
            fail("signatures", rel(part), "its application identifier is not its profile's team and its bundle ID")
        teams.add(team)
        if e.get("get-task-allow") is True:
            fail("signatures", rel(part), "get-task-allow: a development signature, which App Store Connect refuses")
        push = e.get("aps-environment")
        if part == app and push is None:
            fail("signatures", rel(part), "no push entitlement, aps-environment, which CloudKit's notifications need")
        if push is not None and push != "production":
            fail("signatures", rel(part), "aps-environment %s, not production" % push)
        containers = e.get("com.apple.developer.icloud-container-identifiers")
        if part == app and containers is None:
            fail("signatures", rel(part), "no iCloud container")
        if containers is not None:
            if containers != [container]:
                fail("signatures", rel(part), "iCloud containers %s, not %s alone" % (", ".join(containers) or "none", container))
            environment = e.get("com.apple.developer.icloud-container-environment")
            if environment != "Production":
                fail("signatures", rel(part), "iCloud container environment %s, not Production" % (environment or "not set"))
        if e.get("com.apple.security.application-groups") != [group]:
            fail("signatures", rel(part), "app groups %s, not %s alone" % (", ".join(e.get("com.apple.security.application-groups") or []) or "none", group))
    if len(teams) > 1:
        fail("signatures", rel(app), "its parts are signed for more than one team")
    if failures == before:
        ok("signatures", "every signature of its %d signed parts verified; each signed entitlement allowed by its part's profile, one team; push and iCloud in production, %s and %s, no get-task-allow, profiles with no device list" % (len(signed), group, container))

for check in a["checks"].split(","):
    globals()["check_" + check]()
sys.exit(1 if failures else 0)
PY

# check_product <app> <archive or ""> <checks>: the checks of CHECKS_PY, then the binary scan.
check_product() {
    local app=$1 archive=$2 checks=$3 status=0 scan=0 line ended=""
    while IFS= read -r line; do
        if [[ $line == "checks ended "* ]]; then ended=${line#checks ended }; else say "$line"; fi
    done < <(
        python3 -I -c "$CHECKS_PY" app="$app" archive="$archive" bundle="$WANT_BUNDLE" group="$WANT_GROUP" \
            container="$WANT_CONTAINER" flavour="$FLAVOUR" level="$LEVEL" build="$BUILD" version="$WANT_VERSION" \
            xcode="$PINNED_BUILD" reasons="$REASONS" nm="$NM" assetutil=/usr/bin/assetutil codesign=/usr/bin/codesign \
            security=/usr/bin/security checks="$checks" 2>&1
        echo "checks ended $?"
    )
    [[ $ended == 0 ]] || status=1
    knot_scan_binaries "$app" || scan=$?
    case $scan in
        0) say "ok    binaries: no fakes and no debug launch argument in its $KNOT_SCAN_COUNT Mach-O files" ;;
        1) say "FAIL  binaries: $KNOT_SCAN_FILE holds what a release may not: $(tr '\n' ' ' <<<"$KNOT_SCAN_HELD" | cut -c1-200)"; status=1 ;;
        *) say "FAIL  binaries: could not look: $KNOT_SCAN_WHY"; status=1 ;;
    esac
    return "$status"
}

say "the checks on the archive, $(basename "$ARCHIVE"):"
if [[ $MODE == rehearsal ]]; then
    # No part of the rehearsal's archive may carry one of the milestone's bundle IDs.
    if ! rehearsal_parts="$(knot_parts_of "$APP")"; then
        knot_fail "release-rehearsal-identifiers" "The rehearsal's archive cannot be read whole." "Read the archive." "safe" "the run's folder"
    fi
    while IFS= read -r part; do
        case $part in *.app | *.appex) ;; *) continue ;; esac
        bundle="$(knot_plist "$(knot_info_of "$(dirname "$APP")/$part")" CFBundleIdentifier)"
        case $bundle in
            "$MILESTONE_BUNDLE" | "$MILESTONE_BUNDLE.widgets" | "$MILESTONE_BUNDLE.watchkitapp" | "$MILESTONE_BUNDLE.watchkitapp.widgets" | "$MILESTONE_BUNDLE.cli")
                knot_fail "release-rehearsal-identifiers" "The rehearsal's archive carries $bundle, one of the milestone's bundle IDs, in $part: no build but scripts/milestone-build.sh may." \
                    "Read how the rehearsal's archive was made; do not run the product." "safe" "the run's folder, which holds the archive" ;;
        esac
    done <<<"$rehearsal_parts"
fi
if ! check_product "$APP" "$ARCHIVE" roles,configuration,privacy,usage,encryption,icons; then
    knot_fail "release-archive-check" "The archive failed a check, each named above with its part." \
        "Fix what each FAIL line names, in a pull request, and make a new candidate: a run is never resumed." "safe" "the run's folder, which holds the archive"
fi

INTERNAL=true
((LEVEL_NUMBER < 7)) || INTERNAL=false
if [[ $MODE == rehearsal ]]; then
    say "rehearsal passed: every check that reads no signature passed on the archive of the development flavour, at .build/release/$(basename "$RUN")/$(basename "$ARCHIVE")"
    exit 0
fi

# ------------------------------------------------------------------ what an upload does

say "what an upload would do, one step after another:"
say "  1. export the archive for App Store Connect: xcodebuild -exportArchive, method app-store-connect, destination export, automatic signing with the team the archive was made with, for distribution; iCloudContainerEnvironment Production, manageAppVersionAndBuildNumber NO, uploadSymbols YES, testFlightInternalTestingOnly $( [[ $INTERNAL == true ]] && echo "YES, below M7" || echo NO); with -allowProvisioningUpdates and the key"
say "  2. check the exported Knot.ipa, what would be uploaded: every check above, then every signature verified and every signed entitlement allowed by its profile, push and iCloud in production, the app group and the container, no get-task-allow, one team, profiles with no device list; its SHA-256 taken"
say "  3. App Store Connect's validation: altool --validate-app Knot.ipa, with the key, once the SHA-256 is found again"
say "  4. the upload: altool --upload-package Knot.ipa, with the key, once the SHA-256 is found again, once and never retried"
say "the variables it reads, by name: $(key_line)"
if [[ $MODE == dry-run ]]; then
    say "dry run passed: the candidate is checked, at .build/release/$(basename "$RUN")/candidate/$(basename "$ARCHIVE"). Nothing is exported, validated or uploaded."
    exit 0
fi

# ------------------------------------------------------------------ the export, with distribution signing

EXPORT="$RUN/export"
mkdir -m 700 "$TMP/xcode"
options_plist="$TMP/ExportOptions.plist"
cat >"$options_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>signingStyle</key><string>automatic</string>
	<key>iCloudContainerEnvironment</key><string>Production</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
	<key>testFlightInternalTestingOnly</key><$INTERNAL/>
</dict>
</plist>
PLIST
say "exporting for App Store Connect, with distribution signing"
EXPORT_MARK="$TMP/export-started"
: >"$EXPORT_MARK"
export_archive() {
    { TMPDIR="$TMP/xcode/" "$XCODEBUILD" -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
        -exportOptionsPlist "$options_plist" -allowProvisioningUpdates \
        -authenticationKeyPath "$RL_KEY_PATH" -authenticationKeyID "$RL_KEY_ID" \
        -authenticationKeyIssuerID "$RL_ISSUER" 2>&1 | logged; } 2>/dev/null # limit: export_archive
}
PHASE=export
status=0
knot_run_limited "The export for App Store Connect" "$KNOT_BUILD_LIMIT" export_archive || status=$?
PHASE=""
IPA="$EXPORT/Knot.ipa"
if ((status != 0)) || [[ ! -f $IPA ]]; then
    KEEP_DIAGNOSIS=1
    grep -E 'error:|EXPORT FAILED|did not end within' "$LOG" | tail -n 10 | sed 's/^/    /' || true
    knot_fail "release-export" "The export for App Store Connect failed$( [[ -f $IPA ]] || echo ", and left no Knot.ipa"). Its lines are in .build/release/$(basename "$RUN")/release.log; what Xcode wrote of it, filtered, in distribution-logs/ beside it, when Xcode wrote any." \
        "Read them. A signing error that names a certificate, a profile or the account needs the owner." "safe" \
        "Xcode may have made a distribution certificate or an App Store profile in the owner's account; the run's folder"
fi
scrub_export_files
DIGEST="$(shasum -a 256 "$IPA" | cut -d' ' -f1)" || knot_fail "release-export" "Knot.ipa cannot be read." "Read the run's folder." "safe" "the run's folder"
unpacked="$TMP/unpacked"
mkdir -p "$unpacked"
ditto -x -k "$IPA" "$unpacked" || knot_fail "release-export" "Knot.ipa cannot be unpacked." "Read the log." "safe" "the run's folder"
EXPORTED="$unpacked/Payload/Knot.app"
[[ -d $EXPORTED ]] || knot_fail "release-export" "Knot.ipa holds no Payload/Knot.app." "Read the log." "safe" "the run's folder"
say "the checks on what would be uploaded, Knot.ipa, SHA-256 $DIGEST:"
if ! check_product "$EXPORTED" "" roles,configuration,privacy,usage,encryption,icons,signatures; then
    knot_fail "release-export-check" "What would be uploaded failed a check, each named above with its part. Nothing was sent to App Store Connect." \
        "Fix what each FAIL line names, and make a new candidate: a run is never resumed." "safe" "the run's folder, which holds the export"
fi

# ------------------------------------------------------------------ App Store Connect

# The file sent is the file checked: its SHA-256, found again before each call of altool.
same_file() { # same_file <step>
    local now
    now="$(shasum -a 256 "$IPA" 2>/dev/null | cut -d' ' -f1)" || now=""
    [[ $now == "$DIGEST" ]] ||
        knot_fail "release-changed" "Knot.ipa is not the file that was checked: its SHA-256 changed before $1. Nothing more was sent to App Store Connect." \
            "Make a new run: a run is never resumed." "safe" "the run's folder"
}
# altool with the key, its temporary files in tmp/, its output filtered before it reaches a file.
asc_run() {
    { "$ALTOOL" "$@" --api-key "$RL_KEY_ID" --api-issuer "$RL_ISSUER" \
        --p8-file-path "$RL_KEY_PATH" -CDTempDir "$TMP/altool" 2>&1 | release_filter >"$TMP/altool.out"; } 2>/dev/null
}
asc() { # asc <limit> <altool arguments…>
    local limit=$1
    shift
    mkdir -p -m 700 "$TMP/altool"
    knot_limit "$limit" asc_run "$@"
}
# What altool said, to the terminal first, then to the log; a log that cannot be written stops
# nothing.
show_altool() {
    cat "$TMP/altool.out" 2>/dev/null || true
    cat "$TMP/altool.out" >>"$LOG" 2>/dev/null || true
}
same_file "the validation"
say "App Store Connect's validation of Knot.ipa"
PHASE=validate
status=0
asc "${KNOT_VALIDATE_LIMIT:-1800}" --validate-app "$IPA" || status=$?
PHASE=""
show_altool
if ((status != 0)); then
    KEEP_DIAGNOSIS=1
    cp "$TMP/altool.out" "$RUN/validation.log" 2>/dev/null || true
    knot_fail "release-validation" "App Store Connect's validation refused Knot.ipa$( ((KNOT_LIMIT_HIT)) && echo ", or did not answer in time"): its lines, filtered, are above and in .build/release/$(basename "$RUN")/validation.log. Nothing was uploaded." \
        "Fix what it names, in a pull request, and make a new candidate." "safe" "the run's folder, which holds the export"
fi
say "App Store Connect validated Knot.ipa"
if [[ $MODE == validate ]]; then
    say "validation passed: Knot.ipa, at .build/release/$(basename "$RUN")/export/, is checked and validated. Nothing is uploaded."
    exit 0
fi

same_file "the upload"
say "uploading Knot.ipa to App Store Connect, once"
PHASE=upload
status=0
asc "${KNOT_UPLOAD_LIMIT:-3600}" --upload-package "$IPA" || status=$?
PHASE=""
show_altool
if ((status != 0)); then
    knot_fail "release-upload" "The upload of Knot $WANT_VERSION ($BUILD) failed$( ((KNOT_LIMIT_HIT)) && echo ", or did not end in time"): its lines are above and in the run's release.log. It was not retried." \
        "Check App Store Connect, the app's TestFlight builds, for build $BUILD, before any retry: the upload may have reached it. A retry needs the owner's word, and a build number App Store Connect has not taken." \
        "unsafe" "the upload may have reached App Store Connect; the run's folder holds the export"
fi
say "uploaded: Knot $WANT_VERSION ($BUILD), $LEVEL, from ${AT:0:12}. App Store Connect processes it before TestFlight offers it."
