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
# What it defends against is an accident: a variable left in a shell, a stand-in left on a path, a
# stale file, a tool that fails, a run cut short. It does not defend against someone who controls
# the operator's shell or files, who could replace the script itself.
#
# Known, and not defended, by that measure: the key's path held in another variable as well, or
# of several lines or of three characters, is not masked there; altool's signature is checked
# once, before the validation; a FAT64 header and code outside Payload/Knot.app are not read; a
# profile's malformed values and the entitlement matcher's looser shapes are App Store Connect's
# validation to judge; a line of the run's own release.log that names a .xcdistributionlogs folder
# is taken as this run's; a file beside Knot.ipa named with the filter's own suffix, .filtering;
# and a copy of altool's output that fails on the way out after a signal.
#
# The App Store Connect key, for --validate and --upload, in three environment variables:
# KNOT_ASC_KEY_PATH, the absolute path of the key's .p8 file, KNOT_ASC_KEY_ID, ten capitals and
# digits, and KNOT_ASC_ISSUER_ID, a UUID. The script turns tracing and allexport off before it reads
# any of them, and takes them out of its environment at once into names of its own that carry no
# export attribute. While it runs the values are in two places: the arguments of the two commands
# that authenticate, xcodebuild -exportArchive and altool, which the owner's own processes can read
# while those run, and the environment of the filters, perl and python, that mask them. Every line
# it prints or writes passes a filter that masks them, whatever their case, the key file's path as
# given and resolved, and the team's ID (knot_filter_team); what the shared scripts print while
# they are read passes the key's filter, and the failure helper filters each field it prints or
# logs.
#
# A validation and an upload refuse every stand-in the self-test uses: KNOT_ALTOOL, KNOT_ASSETUTIL,
# KNOT_BUILD_FOLDER, KNOT_LSREGISTER, KNOT_SLOT_DIR, KNOT_XCODEGEN, KNOT_XCODE, KNOT_TREE and
# TOOLCHAINS. Before that refusal only the system's tools run, and python3 for the forms of the
# key's path, which /usr/bin hands to the selected developer folder's: that normalization runs
# first, and no other tool of an Xcode does. They take the pinned Xcode from where .xcode-version and the scripts' own search find
# it, check that its xcodebuild and its altool are signed by Apple (codesign -R 'anchor apple')
# before either gets the key, take the other tools from /usr/bin with PATH set to the system's
# folders alone, and take XcodeGen from the build folder's tools/ alone. No run starts while
# XCODE_XCCONFIG_FILE is set, since its settings override the command line's.
#
# Before anything is built it reads the tree: the level, which is refused when it opens sync and
# the tree has no committed CloudKit schema file, so every level from M4 on is refused until that
# file's path is named below; the evidence of each milestone below the level, its annotated tag
# m<n> at or before the commit, the convention the tag m1 shows; and the App Store icons' sources,
# which may carry no alpha channel. The checks on the archive, each naming the part that fails:
# the four parts at their paths, with their identifiers, platforms, device families and the keys
# their source Info.plists declare; one version, the candidate's, above 0.2.0, the build number
# given, one flavour and one level; the Release configuration and the build that .xcode-version
# pins; no fakes and no debug launch argument; a privacy manifest with the reasons the lint finds
# needed; the usage strings each part is known to need; ITSAppUsesNonExemptEncryption false; an
# opaque 1024 by 1024 App Store icon of the set AppIcon for each device family. After the export,
# on the file that would be uploaded: the same, then every code object's signature verified, loose
# libraries among them; for each part, a signing certificate its profile lists and one team, the
# signature's, the profile's and the archive's; the application identifier, the profile's prefix
# and the bundle ID; every signed entitlement allowed by its profile, by type and form; push and
# iCloud in production, the milestone's app group and container, no get-task-allow; and profiles
# with no device list that allow no debugging and production push. Every inspector's status is
# read: one that failed is a failure.
#
# Known, and not checked: that a certificate and a profile are Apple's is App Store Connect's
# validation to say; the self-test's made-up certificates test the comparison, not the trust. The
# scan of imports for protected resources is a help that can miss one; an optimised binary can hide
# a short string from the scan for fakes and debug arguments; and nothing can read from the
# uploaded file that it is for internal testing only, which the export's options ask for below M7.
#
# One release run works in a worktree at a time: it holds a lock, .build/release/.lock, through a
# descriptor its children inherit, so the lock is held until every one of them has ended. After a
# kill that cannot be caught, the lock stays held while a child lives: the timer of a time limit
# sleeps to its end, up to KNOT_UPLOAD_LIMIT, an hour, during the upload, KNOT_VALIDATE_LIMIT, 30
# minutes, during the validation, and KNOT_BUILD_LIMIT, 40 minutes, during the export or the
# rehearsal's archive. lsof .build/release/.lock shows who holds it. Each run works in a new
# folder, .build/release/<mode>-<level>-<commit>-b<n>-<UTC time>-<4 letters>/, with its log,
# release.log, and its own tmp/, where the tools keep their temporary files. On a signal it ends
# its children, then cleans, then leaves, a closed output among the signals. On every way out it
# removes tmp/, filters the files Xcode leaves beside the exported Knot.ipa, and removes the
# distribution logs it can tie to the run, under tmp/ or at the path its xcodebuild printed,
# keeping a filtered copy in the run's folder when the export or the validation failed or was cut
# short; a record it cannot read and filter is reported and fails the run. An interrupted
# validation or upload leaves altool's filtered output in the run's folder. Under the lock, a run
# removes what dead runs left in their tmp/. A run that was cut short is never resumed. Once the
# upload has started, every way out without its outcome says to check App Store Connect before a
# retry, and the script does not retry. The outcome, or that sentence, reaches the run's
# release.log before the terminal: when the log says "uploaded", the upload succeeded, whatever
# became of the lines printed after it. A reader of the output that goes away (PIPE) ends the run
# as another signal does, with status 141.
{ set +xva; } 2>/dev/null
# A SHELLOPTS or BASHOPTS that a caller exported would hand this script's options to every bash
# it starts: they stay its own.
export -n SHELLOPTS BASHOPTS

# The key, out of the environment before anything starts. The script's own names are unset first,
# so that none keeps an export attribute a caller gave it.
unset RL_KEY_PATH RL_KEY_ID RL_ISSUER RL_KEY_PATH_SET RL_KEY_ID_SET RL_ISSUER_SET RL_KEY_ABSOLUTE RL_KEY_REAL RL_SEAMS RL_FAIL_LOG
RL_KEY_PATH=${KNOT_ASC_KEY_PATH-} RL_KEY_ID=${KNOT_ASC_KEY_ID-} RL_ISSUER=${KNOT_ASC_ISSUER_ID-}
RL_KEY_PATH_SET=${KNOT_ASC_KEY_PATH+set} RL_KEY_ID_SET=${KNOT_ASC_KEY_ID+set} RL_ISSUER_SET=${KNOT_ASC_ISSUER_ID+set}
unset KNOT_ASC_KEY_PATH KNOT_ASC_KEY_ID KNOT_ASC_ISSUER_ID
# The stand-ins the self-test uses, as the environment holds them before common.sh sets defaults.
RL_SEAMS=""
for seam in KNOT_ALTOOL KNOT_ASSETUTIL KNOT_BUILD_FOLDER KNOT_LSREGISTER KNOT_SLOT_DIR KNOT_XCODEGEN KNOT_XCODE KNOT_TREE TOOLCHAINS; do
    [[ -z ${!seam+set} ]] || RL_SEAMS="$RL_SEAMS $seam"
done
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

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
        $| = 1;
        @masks = ();
        for my $pair (["KNOT_RL_M1", "<KEY-PATH>"], ["KNOT_RL_M2", "<KEY-PATH>"], ["KNOT_RL_M3", "<KEY-PATH>"],
                      ["KNOT_RL_M4", "<KEY-ID>"], ["KNOT_RL_M5", "<ISSUER-ID>"]) {
            my $value = $ENV{$pair->[0]} // "";
            push @masks, [$value, $pair->[1]] if length($value) >= 4;
        }
        @masks = sort { length($b->[0]) <=> length($a->[0]) } @masks;
    }
    for my $mask (@masks) { my ($value, $name) = @$mask; s/\Q$value\E/$name/gi; }
'
key_filter() {
    KNOT_RL_M1="$RL_KEY_REAL" KNOT_RL_M2="$RL_KEY_ABSOLUTE" KNOT_RL_M3="$RL_KEY_PATH" KNOT_RL_M4="$RL_KEY_ID" \
        KNOT_RL_M5="$RL_ISSUER" perl -pe "$RELEASE_FILTER"
}
release_filter() { key_filter | knot_filter_team; }
# Filters a file in place, as release_filter filters a stream.
filter_in_place() {
    KNOT_RL_M1="$RL_KEY_REAL" KNOT_RL_M2="$RL_KEY_ABSOLUTE" KNOT_RL_M3="$RL_KEY_PATH" KNOT_RL_M4="$RL_KEY_ID" \
        KNOT_RL_M5="$RL_ISSUER" perl -pi -e "$RELEASE_FILTER" "$1" &&
        KNOT_FILTER_CONFIG="$(knot_filter_config)" perl -pi -e "$KNOT_TEAM_FILTER" "$1"
}

# What the shared scripts print while they are read, before the team's filter stands, passes the
# key's filter: a failure of theirs could name a path. A failure log is written only once the
# failure helper below filters what it writes there.
RL_FAIL_LOG=${KNOT_FAIL_LOG-}
unset KNOT_FAIL_LOG
{
    source "$(dirname "$0")/lib/common.sh"
    # shellcheck source=lib/bundle.sh
    source "$KNOT_SCRIPTS/lib/bundle.sh"
} 2> >(key_filter >&2)
# The failure helper filters each of its fields, for the terminal and for the failure log.
eval "knot_report_unfiltered() $(declare -f knot_report | sed 1d)"
knot_report() {
    local field filtered=()
    for field in "$@"; do filtered+=("$(printf '%s' "$field" | release_filter)"); done
    knot_report_unfiltered "${filtered[@]}"
}
[[ -z $RL_FAIL_LOG ]] || export KNOT_FAIL_LOG=$RL_FAIL_LOG

usage() { sed -n '2,109p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "release-usage" "$1" "Run scripts/release.sh --help." "safe" "nothing"; }

# The committed CloudKit schema file, which appears with the production schema (docs/plan/WP-43.md,
# Failure rules). No document names its path yet (docs/plan/open-points.md, item 1): until the
# orchestrator names it here, every level that opens sync is refused.
CLOUDKIT_SCHEMA_FILE=""

LOG=""
say() {
    local line
    line="$(printf 'release: %s\n' "$1" | release_filter)"
    printf '%s\n' "$line"
    [[ -z $LOG ]] || printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
}
# A line, filtered, to the run's log alone: an outcome goes to the drive before the terminal.
log_line() { [[ -n $LOG ]] && printf 'release: %s\n' "$1" | release_filter >>"$LOG" 2>/dev/null; }
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
# A validation and an upload take their tools from the pinned Xcode, found where .xcode-version
# and the scripts' own search find it, and from the system: every stand-in the self-test uses is
# refused, KNOT_XCODE among them, before any tool of an Xcode but python3, which gave the key's
# path its forms above. XcodeGen comes from the build folder's
# tools/xcodegen-<version>/ alone (docs/dev-setup.md, XcodeGen).
if [[ ($MODE == validate || $MODE == upload) && -n $RL_SEAMS ]]; then
    knot_fail "release-stand-ins" "A validation and an upload take their tools from the pinned Xcode and the system alone, and these are set:$RL_SEAMS." \
        "Unset them. The pinned Xcode is found in /Applications by .xcode-version, and XcodeGen under the build folder's tools/xcodegen-$KNOT_XCODEGEN_VERSION/." "safe" "nothing"
fi

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

# Xcode's distribution logs of this run, those it can be tied to: under the run's tmp/xcode/,
# which is the TMPDIR the export is given, and at the path this run's xcodebuild printed. Nothing
# in the user's shared temporary folder is taken because it is newer. When the export or the
# validation failed or was cut short, a filtered copy stays in the run's folder,
# distribution-logs/, and the original is removed only once its copy is there; otherwise the
# original is removed. A file that cannot be read or filtered is reported, never kept unfiltered,
# and the function returns 1.
collect_distribution_logs() {
    [[ -n $EXPORT_MARK && -e $EXPORT_MARK ]] || return 0
    local found name file files copy problem=0 failed kept=0
    {
        find "$TMP/xcode" -maxdepth 1 -name '*.xcdistributionlogs' -print 2>/dev/null || true
        sed -n -E 's/.*Created bundle at path "([^"]+\.xcdistributionlogs)".*/\1/p' "$LOG" 2>/dev/null || true
    } | sort -u >"$TMP/distribution-logs" || true
    while IFS= read -r found; do
        [[ -n $found && -d $found ]] || continue
        if ((KEEP_DIAGNOSIS)); then
            name="$(basename "$found")"
            failed=0
            if ! files="$(cd "$found" && find . -type f -print 2>/dev/null)"; then
                printf 'release: Xcode'"'"'s distribution log %s cannot be read whole: it is left where it is\n' "$name" >&2
                problem=1
                continue
            fi
            while IFS= read -r file; do
                [[ -n $file ]] || continue
                copy="$RUN/distribution-logs/$name/$file"
                mkdir -p "$(dirname "$copy")"
                if [[ -r $found/$file ]] && release_filter <"$found/$file" >"$copy.partial" 2>/dev/null && mv "$copy.partial" "$copy"; then
                    kept=1
                else
                    rm -f "$copy.partial"
                    printf 'release: %s of Xcode'"'"'s distribution log %s cannot be read and filtered\n' "$file" "$name" >&2
                    failed=1
                fi
            done <<<"$files"
            if ((failed)); then
                problem=1
                [[ $found == "$TMP"/* ]] || printf 'release: it is left at %s, unfiltered\n' "$(knot_home_path "$found")" >&2
                continue
            fi
        fi
        rm -rf "$found"
    done <"$TMP/distribution-logs"
    ((kept == 0)) || printf 'release: what Xcode wrote of the export, filtered: .build/release/%s/distribution-logs/\n' "$(basename "$RUN")" >&2
    return "$problem"
}

# The files Xcode leaves beside the exported Knot.ipa, such as DistributionSummary.plist, name
# the team: each is filtered, through a copy that replaces it. One that cannot be read or
# filtered is removed and reported, and the function returns 1.
scrub_export_files() {
    [[ -n $EXPORT && -d $EXPORT ]] || return 0
    local file problem=0
    if ! find "$EXPORT" -type f ! -path "$EXPORT/Knot.ipa" ! -name '*.filtering' -print0 >"$TMP/sidecars" 2>/dev/null; then
        printf 'release: the files beside Knot.ipa cannot be listed whole\n' >&2
        return 1
    fi
    while IFS= read -r -d '' file; do
        if [[ -r $file ]] && release_filter <"$file" >"$file.filtering" 2>/dev/null && mv "$file.filtering" "$file"; then
            continue
        fi
        rm -f "$file.filtering" "$file"
        printf 'release: %s, beside Knot.ipa, cannot be read and filtered: it is removed\n' "$(basename "$file")" >&2
        problem=1
    done <"$TMP/sidecars"
    return "$problem"
}

UPLOAD_REPORTED=0
# The sentence on a retry, once the upload has started and its outcome is not recorded.
# It reaches the run's release.log first, then the terminal and the failure log.
RETRY_SENTENCE=""
report_upload_unfinished() {
    [[ $PHASE == upload && $UPLOAD_REPORTED != 1 ]] || return 0
    local what="The upload of build $BUILD was cut short before its outcome was recorded: it may have reached App Store Connect. It was not retried."
    log_line "FAIL  release-upload-interrupted: $what $RETRY_SENTENCE" || true
    UPLOAD_REPORTED=1
    knot_report "release-upload-interrupted" "$what" "$RETRY_SENTENCE" \
        "unsafe" "the upload may have reached App Store Connect; the run's folder holds the export" || true
}

finish() {
    local status=$? record=0
    trap '' HUP INT TERM PIPE
    end_children
    report_upload_unfinished
    collect_distribution_logs || record=1
    scrub_export_files || record=1
    if [[ -n $DERIVED && -d $DERIVED ]]; then
        knot_unregister_apps "$DERIVED" >/dev/null 2>&1 || true
        rm -rf "$DERIVED"
    fi
    [[ -z $TMP ]] || rm -rf "$TMP"
    if ((record)); then
        knot_report "release-record" "A record of the export could not be read and filtered: each is named above." \
            "Read what is named. Nothing unfiltered is kept in the run's folder." "safe" "the run's folder" || true
        ((status != 0)) || status=1
    fi
    exit "$status"
}
on_signal() {
    local code=$1
    trap '' HUP INT TERM PIPE
    end_children
    KEEP_DIAGNOSIS=1
    case $PHASE in
        upload | validate)
            # What altool said before the signal, filtered, as a failed step leaves it.
            cat "$TMP/altool.out" >>"$LOG" 2>/dev/null || true
            cp "$TMP/altool.out" "$RUN/$PHASE.log" 2>/dev/null || true ;;
    esac
    case $PHASE in
        upload) report_upload_unfinished ;;
        validate)
            knot_report "release-validation-interrupted" "App Store Connect's validation was cut short by a signal. Nothing was uploaded. What altool said is in the run's validate.log." \
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
# A reader of the output that goes away: the run ends as a signal ends it, with that status.
trap 'on_signal 141' PIPE

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
# The pinned build, from .xcode-version: what every part of the product must have been built by.
PINNED_BUILD="$(knot_xcode_pin)" && PINNED_BUILD=${PINNED_BUILD#* }
# Whether a tool is signed by Apple: checked on xcodebuild and on altool before they get the key.
apple_signed() { /usr/bin/codesign --verify -R='anchor apple' "$1" >/dev/null 2>&1; }
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
            elif [[ $RL_KEY_PATH != /* ]]; then echo "set, but not an absolute path"
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
            "Read its lines, above and in .build/release/$(basename "$RUN")/release.log; once its build had started, the build's own log is in .build/release/$(basename "$RUN")/candidate/." "safe" "the run's folder"
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
import json, os, plistlib, re, shutil, subprocess, sys, tempfile

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
# What each role's source Info.plist declares, so that the product must carry it: the keys the
# code reads, and the device families, which the App Store icon must serve.
REQUIRED_KEYS = {"app": ["KnotAppGroup", "KnotCloudContainer"], "widget": ["KnotAppGroup"], "watch": ["KnotAppGroup"],
                 "watch-widget": ["KnotAppGroup"]}
FAMILIES = {"app": [1, 2], "widget": [1, 2], "watch": [4], "watch-widget": [4]}
ICON_SET = "AppIcon"
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
        for key in REQUIRED_KEYS[name]:
            if key not in i:
                fail("roles", rel(part), "no %s, which its source Info.plist declares" % key)
        if i.get("UIDeviceFamily") != FAMILIES[name]:
            fail("roles", rel(part), "device families %s, not %s" % (i.get("UIDeviceFamily"), FAMILIES[name]))
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
    try:
        for folder, dirs, files in os.walk(app, onerror=walk_error):
            for name in files:
                if name.endswith(".debug.dylib") or name == "__preview.dylib":
                    fail("configuration", rel(os.path.join(folder, name)), "the debug dylib of Xcode's Debug configuration (ENABLE_DEBUG_DYLIB): no Release build holds it")
            for name in dirs:
                if name.endswith(".xctest"):
                    fail("configuration", rel(os.path.join(folder, name)), "a test bundle, which no Release archive holds")
    except OSError as error:
        fail("configuration", rel(app), "the product cannot be read whole: %s" % error)
    for part in parts:
        built = (info(part) or {}).get("DTXcodeBuild", "")
        if built != xcode:
            fail("configuration", rel(part), "built with Xcode %s, not the pinned %s" % (built or "(not named)", xcode))
    if archive:
        try:
            dsyms = [name for name in os.listdir(os.path.join(archive, "dSYMs")) if name.endswith(".dSYM")]
        except FileNotFoundError:
            dsyms = []
        except OSError:
            dsyms = None
            fail("configuration", "dSYMs", "the archive's dSYMs cannot be read")
        if dsyms == []:
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
        families = FAMILIES[name]
        if icon != ICON_SET:
            fail("icons", rel(part), "its Info.plist names the icon set %s, not %s" % (icon or "(none)", ICON_SET))
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
    """Whether a signed entitlement's value is one its profile allows, by type and form: a Boolean
    with a Boolean, a list with a list, a string with a string. A profile's list of strings also
    allows one of them, as the iCloud container environment is signed; a wildcard counts only as a
    profile writes one, "*" alone or at the end of a prefix ending ".*"."""
    if isinstance(permit, bool) or isinstance(value, bool):
        return isinstance(permit, bool) and isinstance(value, bool) and (value == permit or not value)
    if isinstance(permit, list):
        if isinstance(value, list):
            return all(isinstance(v, str) and any(allowed(v, p) for p in permit) for v in value)
        return isinstance(value, str) and any(allowed(value, p) for p in permit)
    if not isinstance(permit, str):
        return False
    if isinstance(value, list):
        return permit == "*" and all(isinstance(v, str) for v in value)
    if not isinstance(value, str):
        return False
    if permit == "*":
        return True
    if permit.endswith(".*"):
        return value.startswith(permit[:-1])
    return value == permit

def signer_team(part):
    """The team of a part's signature, read in memory, never printed; None for no team."""
    result = run([CODESIGN, "-dv", part])
    if result.returncode != 0:
        return None
    found = re.search(rb"^TeamIdentifier=(.+)$", result.stderr, re.M)
    team = found.group(1).decode("utf-8", "replace").strip() if found else ""
    return None if team in ("", "not set") else team

def signer_leaf(part):
    """The leaf certificate of a part's signature, as DER bytes, or None."""
    folder = tempfile.mkdtemp()
    try:
        result = run([CODESIGN, "-d", "--extract-certificates=" + os.path.join(folder, "certificate"), part])
        path = os.path.join(folder, "certificate0")
        if result.returncode != 0 or not os.path.isfile(path):
            return None
        with open(path, "rb") as f:
            return f.read()
    finally:
        shutil.rmtree(folder, ignore_errors=True)

def check_signatures():
    before = failures
    signed = []
    try:
        for folder, dirs, _ in os.walk(app, onerror=walk_error):
            signed += [os.path.join(folder, d) for d in dirs if d.endswith((".app", ".appex", ".framework", ".xpc"))]
    except OSError as error:
        fail("signatures", rel(app), "the product cannot be read whole: %s" % error)
    signed = sorted(signed, key=lambda p: -p.count("/")) + [app]
    # Every code object: each bundle, and each Mach-O file that is not a bundle's own executable,
    # such as a loose library.
    mains = set()
    for part in signed:
        executable = (info(part) or {}).get("CFBundleExecutable")
        if executable:
            mains.add(os.path.join(part, "Contents", "MacOS", executable) if os.path.isdir(os.path.join(part, "Contents"))
                      else os.path.join(part, executable))
    try:
        signed += [path for path in macho_files() if path not in mains]
    except OSError as error:
        fail("signatures", rel(app), "the product cannot be read whole: %s" % error)
    for part in signed:
        result = run([CODESIGN, "--verify", "--strict", part])
        if result.returncode != 0:
            fail("signatures", rel(part), "codesign --verify --strict failed on it")
    # The archive's team, which signed the candidate for development: the export's must be it.
    archive_team = signer_team(a["signed_archive"]) if a.get("signed_archive") else None
    if not archive_team:
        fail("signatures", "the archive", "its signature names no team that can be read")
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
        # Who signed: the leaf among the profile's certificates, and one team, the signature's, the
        # profile's and the archive's, compared in memory and never printed.
        team = signer_team(part)
        if not team or team != (p.get("TeamIdentifier") or [None])[0] or team != archive_team:
            fail("signatures", rel(part), "it is signed by no team, or by another team than its provisioning profile's or the archive's")
        leaf = signer_leaf(part)
        if not leaf or leaf not in [c for c in p.get("DeveloperCertificates") or [] if isinstance(c, bytes)]:
            fail("signatures", rel(part), "its signing certificate is not one its provisioning profile lists")
        prefix = (p.get("ApplicationIdentifierPrefix") or [None])[0]
        identifier = e.get("application-identifier", "")
        if not prefix or identifier != "%s.%s" % (prefix, base + dict((n, s) for n, _, s, *_ in ROLES)[role_of[part]]):
            fail("signatures", rel(part), "its application identifier is not its profile's prefix and its bundle ID")
        teams.add(team)
        if permits.get("get-task-allow") is True:
            fail("signatures", rel(part), "its provisioning profile allows debugging, get-task-allow")
        profile_push = permits.get("aps-environment", permits.get("com.apple.developer.aps-environment"))
        if profile_push is not None and profile_push != "production":
            fail("signatures", rel(part), "its provisioning profile's push environment is %s, not production" % profile_push)
        if e.get("get-task-allow") is True:
            fail("signatures", rel(part), "get-task-allow: a development signature, which App Store Connect refuses")
        push = e.get("aps-environment", e.get("com.apple.developer.aps-environment"))
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
        ok("signatures", "every signature of its %d code objects verified; each part signed by the archive's team with a certificate its profile lists; each signed entitlement allowed by its part's profile; push and iCloud in production, %s and %s, no get-task-allow, profiles with no device list that allow no debugging" % (len(signed), group, container))

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
        TMPDIR="$TMP" python3 -I -c "$CHECKS_PY" app="$app" archive="$archive" bundle="$WANT_BUNDLE" group="$WANT_GROUP" \
            container="$WANT_CONTAINER" flavour="$FLAVOUR" level="$LEVEL" build="$BUILD" version="$WANT_VERSION" \
            xcode="$PINNED_BUILD" reasons="$REASONS" nm="$NM" assetutil=/usr/bin/assetutil codesign=/usr/bin/codesign signed_archive="$APP" \
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
apple_signed "$XCODEBUILD" || knot_fail "release-tool-signature" "The xcodebuild of the pinned Xcode does not verify as signed by Apple: it does not get the key." \
    "Reinstall the pinned Xcode, then make a new run." "safe" "the run's folder"
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
scrub_export_files || knot_fail "release-export-record" "A file Xcode left beside Knot.ipa could not be read and filtered: it is removed, named above. Nothing was sent to App Store Connect." \
    "Read what is named, and make a new run." "safe" "the run's folder, which holds the export"
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
apple_signed "$ALTOOL" || knot_fail "release-tool-signature" "The altool of the pinned Xcode does not verify as signed by Apple: it does not get the key." \
    "Reinstall the pinned Xcode, then make a new run." "safe" "the run's folder, which holds the export"
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
RETRY_SENTENCE="Check App Store Connect, the app's TestFlight builds, for build $BUILD, before any retry: the upload may have reached it. A retry needs the owner's word, and a build number App Store Connect has not taken."
PHASE=upload
status=0
asc "${KNOT_UPLOAD_LIMIT:-3600}" --upload-package "$IPA" || status=$?
show_altool
if ((status != 0)); then
    what="The upload of Knot $WANT_VERSION ($BUILD) failed$( ((KNOT_LIMIT_HIT == 0)) || echo ", or did not end in time"): its lines are above and in the run's release.log. It was not retried."
    log_line "FAIL  release-upload: $what $RETRY_SENTENCE" || true
    UPLOAD_REPORTED=1
    knot_fail "release-upload" "$what" "$RETRY_SENTENCE" \
        "unsafe" "the upload may have reached App Store Connect; the run's folder holds the export"
fi
# The outcome, in the log first. Once the log holds it the upload succeeded: a print that fails
# after it, a reader gone among the causes, changes neither the outcome nor the status.
uploaded="uploaded: Knot $WANT_VERSION ($BUILD), $LEVEL, from ${AT:0:12}. App Store Connect processes it before TestFlight offers it."
log_line "$uploaded" && PHASE=""
{ printf 'release: %s\n' "$uploaded" | release_filter 2>/dev/null; } && PHASE="" || true
