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
#                given, and makes every check it makes of a build; then every check below on
#                the archive, and a list of what an upload would do. It prints the names of the
#                variables it would read, and never their values. It signs nothing for
#                distribution and contacts nothing but what the milestone build does.
#   --validate   the dry run, then the export for App Store Connect with distribution signing,
#                the checks of what would be uploaded, and App Store Connect's own validation,
#                with no upload. On the owner's word.
#   --upload     the validation, then the upload of the file that was checked, once. On the
#                owner's word, each time.
#   --rehearsal  for an agent and for the gate: it archives the development flavour, with no
#                signing, at the level and the build number given, from the worktree as it is,
#                and runs on that archive every check below that reads no signature. It never
#                signs and never contacts App Store Connect.
#
#   --products ios        the default and, until SP-3 reports, the only product
#   --allow-provisioning-updates
#                passed to scripts/milestone-build.sh, on the owner's word only
#
# The App Store Connect key, for --validate and --upload, in three environment variables:
# KNOT_ASC_KEY_PATH, the path of the key's .p8 file, KNOT_ASC_KEY_ID and KNOT_ASC_ISSUER_ID.
# None of them, and no team ID, appears in any line it prints or writes: each line passes a
# filter that masks their values and the team's (knot_filter_team). It writes nothing that
# holds them; the tools it runs keep their temporary files in the run's tmp/ folder, which is
# removed on every way out.
#
# Before anything is built it reads the tree: the level, which is refused when it opens sync
# and the tree has no committed CloudKit schema file; the evidence of each milestone below the
# level, its annotated tag m<n> at or before the commit; and the App Store icons' sources,
# which may carry no alpha channel. The checks on the archive, each naming the part that fails:
# no fakes and no debug launch argument; the Release configuration and a release Xcode; one
# identifier family, one version above 0.2.0, the build number given, one flavour and one level;
# a privacy manifest and the usage strings of the protected resources each part asks for;
# ITSAppUsesNonExemptEncryption false in every app; an opaque App Store icon in each app. After
# the export, on what would be uploaded: the same, then the production push and iCloud
# entitlements, the milestone's app group and container, no get-task-allow, and profiles that
# list no device.
#
# Each run works in a new folder,
# .build/release/<mode>-<level>-<commit>-b<n>-<UTC time>-<4 letters>/, with its log, release.log.
# A run that was cut short is never resumed: the next starts from nothing, in a folder of its own,
# and removes what earlier runs left in their tmp/. After a failed upload it says to check App
# Store Connect before a retry, and does not retry.

source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/bundle.sh
source "$KNOT_SCRIPTS/lib/bundle.sh"

usage() { sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "release-usage" "$1" "Run scripts/release.sh --help." "safe" "nothing"; }

# The variables that hold the key. Their values are never printed.
RELEASE_VARIABLES="KNOT_ASC_KEY_PATH KNOT_ASC_KEY_ID KNOT_ASC_ISSUER_ID"

# The committed CloudKit schema file, which appears with the production schema (docs/plan/WP-43.md,
# Failure rules). No document names its path yet (docs/plan/open-points.md, item 1): until the
# orchestrator names it here, every level that opens sync is refused.
CLOUDKIT_SCHEMA_FILE=""

# Masks the key's three values, the key file's resolved path among them, and then the team's ID.
# The values reach perl through its environment, never its arguments.
RELEASE_FILTER='
    BEGIN {
        @masks = ();
        for my $pair (["KNOT_RL_REAL_KEY_PATH", "<KEY-PATH>"], ["KNOT_ASC_KEY_PATH", "<KEY-PATH>"],
                      ["KNOT_ASC_KEY_ID", "<KEY-ID>"], ["KNOT_ASC_ISSUER_ID", "<ISSUER-ID>"]) {
            my $value = $ENV{$pair->[0]} // "";
            push @masks, [$value, $pair->[1]] if length($value) >= 4;
        }
    }
    for my $mask (@masks) { my ($value, $name) = @$mask; s/\Q$value\E/$name/g; }
'
release_filter() { perl -pe "$RELEASE_FILTER" | knot_filter_team; }

LOG=""
say() {
    local line
    line="$(printf 'release: %s\n' "$1" | release_filter)"
    printf '%s\n' "$line"
    [[ -z $LOG ]] || printf '%s\n' "$line" >>"$LOG"
}
# A command's output, filtered, to the run's log and, with --show, the terminal.
logged() { if [[ ${1:-} == --show ]]; then release_filter | tee -a "$LOG"; else release_filter >>"$LOG"; fi; }

# ------------------------------------------------------------------ the rehearsal's archive, in a slot

# The rehearsal's archive runs in a second process that holds a build slot. It finds its settings
# in the environment: KNOT_RL_DERIVED, KNOT_RL_ARCHIVE, KNOT_RL_LEVEL, KNOT_RL_BUILD and
# KNOT_RL_LOG. The development flavour, signed by nothing: no build of release.sh carries the
# milestone's identifiers (AGENTS.md).
if [[ ${1:-} == --in-archive ]]; then
    knot_select_xcode
    rehearsal_archive() {
        { xcodebuild -project "$KNOT_PROJECT" -derivedDataPath "$KNOT_RL_DERIVED" \
            -clonedSourcePackagesDirPath "$KNOT_SOURCE_PACKAGES" -configuration Release \
            -scheme Knot-iOS -destination generic/platform=iOS \
            KNOT_FLAVOUR=dev KNOT_MILESTONE_LEVEL="$KNOT_RL_LEVEL" KNOT_SIGNING=local \
            KNOT_BUILD_NUMBER="$KNOT_RL_BUILD" DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO \
            COMPILER_INDEX_STORE_ENABLE=NO archive -archivePath "$KNOT_RL_ARCHIVE" 2>&1 | knot_filter_team >>"$KNOT_RL_LOG"; } 2>/dev/null # limit: rehearsal_archive
    }
    knot_run_limited "The rehearsal's archive of Knot-iOS" "$KNOT_BUILD_LIMIT" rehearsal_archive
    exit $?
fi

# ------------------------------------------------------------------ arguments

MODE=dry-run
LEVEL=""
COMMIT=""
BUILD=""
PRODUCTS=ios
PROVISIONING=0
while [[ $# -gt 0 ]]; do
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
        *) usage_fail "Unknown argument: $1" ;;
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

# ------------------------------------------------------------------ the tree

knot_select_xcode
if knot_is_beta_build "$KNOT_XCODE_BUILD"; then
    knot_fail "release-beta-xcode" "The Xcode is $(knot_xcode_label): App Store Connect takes no build of a beta Xcode." \
        "Unset KNOT_XCODE, so that the release Xcode that .xcode-version pins is used." "safe" "nothing"
fi

if [[ $MODE == rehearsal ]]; then
    COMMIT_NAMED=""
    AT="$(git -C "$KNOT_ROOT" rev-parse HEAD)"
else
    COMMIT_NAMED="$(git -C "$KNOT_ROOT" rev-parse --verify --quiet "$COMMIT^{commit}" || true)"
    [[ -n $COMMIT_NAMED ]] || knot_fail "release-commit-unknown" "$COMMIT is not a commit in this repository." \
        "Fetch it, or name the milestone's commit by its hash." "safe" "nothing"
    AT=$COMMIT_NAMED
fi

# Reads a file of the tree: of the commit named, or, for a rehearsal, of the worktree as it is.
# A symbolic link is followed inside the tree. With --png it prints, for each PNG file of a
# folder, its path, its colour type and whether it holds a tRNS chunk, tab-separated.
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
        return open(full, "rb").read() if os.path.isfile(full) else None
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
        data = read(p) or b""
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

# The identifiers of the family the archive must carry.
setting() { tree cat Apps/Config/Identifiers.xcconfig | sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p" | head -n 1; }
FAMILY=milestone FLAVOUR=milestone
[[ $MODE != rehearsal ]] || FAMILY=dev FLAVOUR=dev
WANT_BUNDLE="$(setting "KNOT_BUNDLE_ID_$FAMILY")"
WANT_GROUP="$(setting "KNOT_APP_GROUP_$FAMILY")"
WANT_CONTAINER="$(setting "KNOT_CLOUD_CONTAINER_$FAMILY")"
MILESTONE_BUNDLE="$(setting KNOT_BUNDLE_ID_milestone)"
[[ -n $WANT_BUNDLE && -n $WANT_GROUP && -n $WANT_CONTAINER && -n $MILESTONE_BUNDLE ]] ||
    knot_fail "release-identifiers" "Apps/Config/Identifiers.xcconfig at ${AT:0:12} does not give the $FAMILY family's bundle ID, app group and iCloud container." \
        "Read the file: KNOT_BUNDLE_ID_$FAMILY, KNOT_APP_GROUP_$FAMILY and KNOT_CLOUD_CONTAINER_$FAMILY." "safe" "nothing"

say "$MODE of $LEVEL, build number $BUILD, at ${AT:0:12}$( [[ $MODE == rehearsal ]] && echo ", the worktree as it is"), $(knot_xcode_label)"

# The level. Sync opens at the level that KnotCore's Feature.opensAt gives it, read from the
# tree; a level at or above it needs the committed CloudKit schema file, since a TestFlight build
# uses CloudKit's production environment.
sync_opens="$(tree cat Packages/KnotKit/Sources/KnotCore/Settings/FeatureGates.swift 2>/dev/null |
    sed -n -E 's/^[[:space:]]*case[^:]*\.sync[,:][^:]*:[[:space:]]*\.m([1-7])[[:space:]]*$/\1/p' | head -n 1 || true)"
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
# milestone build's commit; the candidate is that commit or one after it.
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
    done < <(tree png "$set")
    if ((found == 0)); then
        refuse "icons: $set holds no PNG"
        icons_ok=0
    fi
done
((icons_ok == 0)) || say "ok    icons: the iPhone's and the Watch's icon sources carry no alpha channel"

# The key, before anything is built: three variables, read for being set and nothing else.
key_state() {
    local name=$1
    if [[ -z ${!name:-} ]]; then
        echo "not set"
    elif [[ $name == KNOT_ASC_KEY_PATH ]]; then
        if [[ -f ${!name} && -r ${!name} ]]; then echo "set, a readable file"; else echo "set, but no readable file"; fi
    else
        echo set
    fi
}
if [[ $MODE == validate || $MODE == upload ]]; then
    for name in $RELEASE_VARIABLES; do
        state="$(key_state "$name")"
        [[ $state == set || $state == "set, a readable file" ]] || refuse "key: $name is $state"
    done
fi

if ((${#FAILURES[@]})); then
    knot_fail "release-refused" "The candidate is refused before anything is built: ${#FAILURES[@]} check$( ((${#FAILURES[@]} == 1)) || echo s) failed, each named above." \
        "Read each FAIL line. A level whose evidence or schema is missing waits for them; it is never forced." "safe" "nothing"
fi

# ------------------------------------------------------------------ the run's folder

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# What earlier runs left in their tmp/, as a run that was killed leaves it, goes first; nothing
# else of theirs is read. Release runs are made one at a time.
for left in "$KNOT_BUILD"/release/*/tmp; do
    [[ -d $left ]] || continue
    rm -rf "$left"
done
mkdir -p "$KNOT_BUILD/release"
RUN="$(mktemp -d "$KNOT_BUILD/release/$MODE-$LEVEL-${AT:0:12}-b$BUILD-$STAMP-XXXX")"
TMP="$RUN/tmp"
mkdir -p "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
LOG="$RUN/release.log"
: >"$LOG"
[[ -z ${KNOT_ASC_KEY_PATH:-} || ! -e $KNOT_ASC_KEY_PATH ]] ||
    export KNOT_RL_REAL_KEY_PATH="$(cd "$(dirname "$KNOT_ASC_KEY_PATH")" && pwd -P)/$(basename "$KNOT_ASC_KEY_PATH")"
say "the run's folder is .build/release/$(basename "$RUN"), its log release.log"

# ------------------------------------------------------------------ the archive

if [[ $MODE == rehearsal ]]; then
    knot_check_xcodegen || knot_fail "$KNOT_XCODEGEN_CODE" "$KNOT_XCODEGEN_WHAT" "$KNOT_XCODEGEN_FIX" "safe" "nothing"
    # The project is generated afresh, and the team's configuration is left as it is linked.
    rm -rf "$KNOT_PROJECT"
    (cd "$KNOT_ROOT" && "$KNOT_XCODEGEN_PATH" generate --spec project.yml --quiet)
    ARCHIVE="$RUN/Knot-ios.xcarchive"
    derived="$RUN/DerivedData"
    say "archiving Knot-iOS, Release, the development flavour, $LEVEL, build number $BUILD, signed by nothing, in fresh derived data"
    status=0
    KNOT_RL_DERIVED=$derived KNOT_RL_ARCHIVE=$ARCHIVE KNOT_RL_LEVEL=$LEVEL KNOT_RL_BUILD=$BUILD KNOT_RL_LOG="$RUN/archive.log" \
        "$KNOT_SCRIPTS/build-slot.sh" run --label "release rehearsal" -- "$KNOT_SCRIPTS/release.sh" --in-archive || status=$?
    # An iOS app that LaunchServices never registered fails lsregister -u (-10814): what counts
    # is whether its list names one of the run's products afterwards.
    if ! knot_unregister_apps "$RUN"; then
        listed="$("$KNOT_LSREGISTER" -dump 2>/dev/null)" || listed="$RUN/ (the list could not be read)"
        if ! grep -F -e "$RUN/" <<<"$listed" >/dev/null; then
            say "LaunchServices registers none of its products ($KNOT_UNREGISTER_WHY, as for an app it never registered)"
        else
            say "its products could not be unregistered from LaunchServices: $KNOT_UNREGISTER_WHY. Unregister each by hand with lsregister -u <app>"
        fi
    fi
    rm -rf "$derived"
    if ((status != 0)); then
        grep -E 'error:|ARCHIVE FAILED|did not end within' "$RUN/archive.log" | tail -n 10 | sed 's/^/    /' | logged --show || true
        knot_fail "release-rehearsal-archive" "The rehearsal's archive failed. Its log is .build/release/$(basename "$RUN")/archive.log." \
            "Read the log." "safe" "the run's folder"
    fi
else
    say "the candidate: scripts/milestone-build.sh $LEVEL --commit ${AT:0:12} --products ios --archive, build number $BUILD"
    options=()
    ((PROVISIONING == 0)) || options+=(--allow-provisioning-updates)
    status=0
    "$KNOT_SCRIPTS/milestone-build.sh" "$LEVEL" --commit "$AT" --products ios --archive "$RUN/candidate" \
        --build-number "$BUILD" ${options[@]+"${options[@]}"} 2>&1 | logged --show || status=$?
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

# One program for the checks that read the product's files. Arguments, key=value: app, archive
# (for its dSYMs, or empty), bundle, group, container, flavour, level, build, and checks, a
# comma-separated list of: configuration, identity, privacy, usage, encryption, icons and
# entitlements, the last after the export. It prints "ok    <check>: …" or "FAIL  <check>:
# <part>: …" for each, and exits 1 when any failed.
read -r -d '' CHECKS_PY <<'PY' || true
import glob, json, os, plistlib, re, subprocess, sys

a = dict(arg.split("=", 1) for arg in sys.argv[1:])
app, archive = a["app"], a.get("archive", "")
base, group, container = a["bundle"], a["group"], a["container"]
flavour, level, build = a["flavour"], a["level"], a["build"]
root = os.path.dirname(app)
failures = 0
SUFFIXES = ("", ".widgets", ".watchkitapp", ".watchkitapp.widgets")
# The protected resources a part can ask for, by the classes whose use asks for them, and the
# usage strings any one of which its Info.plist must then hold.
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
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"}

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
            return plist_of(p) or {}
    return {}

def resource(part, name):
    mac = os.path.join(part, "Contents", "Resources", name)
    return mac if os.path.isdir(os.path.join(part, "Contents")) else os.path.join(part, name)

parts = [app]
for folder, dirs, _ in os.walk(app):
    parts += [os.path.join(folder, d) for d in dirs if d.endswith((".app", ".appex"))]
parts.sort()

def owner(path):
    return max((p for p in parts if path.startswith(p + "/")), key=len)

def run(command):
    return subprocess.run(command, capture_output=True)

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
        i = info(part)
        platform, xcode = i.get("DTPlatformName", ""), i.get("DTXcodeBuild", "")
        if platform not in ("iphoneos", "watchos", "macosx"):
            fail("configuration", rel(part), "built for %s, not for a device" % (platform or "no platform it names"))
        if not xcode or re.search(r"[a-z]$", xcode):
            fail("configuration", rel(part), "built with Xcode %s, a beta or none: App Store Connect takes the builds of a release Xcode" % (xcode or "(not named)"))
    if archive and not glob.glob(os.path.join(archive, "dSYMs", "*.dSYM")):
        fail("configuration", "dSYMs", "the archive holds no dSYM: its debug information is the Debug configuration's, dwarf, and not Release's, dwarf-with-dsym")
    if failures == before:
        ok("configuration", "Release: no debug dylib, no test bundle, every part built for a device by Xcode %s%s" % (info(app).get("DTXcodeBuild"), ", with dSYMs" if archive else ""))

def above_retired(version):
    try:
        return tuple(int(n) for n in version.split(".")) > (0, 2, 0)
    except Exception:
        return False

def check_identity():
    before = failures
    version = info(app).get("CFBundleShortVersionString", "")
    seen, suffixes = set(), set()
    for part in parts:
        i = info(part)
        bundle = i.get("CFBundleIdentifier", "")
        suffix = "" if bundle == base else bundle[len(base):] if bundle.startswith(base + ".") else None
        if suffix not in SUFFIXES:
            fail("identity", rel(part), "bundle ID %s, which is not of the family %s" % (bundle or "(none)", base))
        suffixes.add(suffix)
        if bundle in seen:
            fail("identity", rel(part), "bundle ID %s, which another part has too" % bundle)
        seen.add(bundle)
        if i.get("CFBundleShortVersionString") != version:
            fail("identity", rel(part), "version %s, not the app's %s" % (i.get("CFBundleShortVersionString"), version))
        if i.get("CFBundleVersion") != build:
            fail("identity", rel(part), "build number %s, not %s" % (i.get("CFBundleVersion"), build))
        if i.get("KnotFlavour") != flavour:
            fail("identity", rel(part), "flavour %s, not %s" % (i.get("KnotFlavour") or "none", flavour))
        if part.endswith(".app") or "KnotMilestoneLevel" in i:
            if i.get("KnotMilestoneLevel") != level:
                fail("identity", rel(part), "level %s, not %s" % (i.get("KnotMilestoneLevel") or "none", level))
        for key, want in (("KnotAppGroup", group), ("KnotCloudContainer", container), ("WKCompanionAppBundleIdentifier", base)):
            if key in i and i[key] != want:
                fail("identity", rel(part), "%s %s, not %s" % (key, i[key], want))
    if not above_retired(version):
        fail("identity", rel(app), "version %s, which is not above 0.2.0, the retired app's" % (version or "(none)"))
    if ".watchkitapp" not in suffixes:
        fail("identity", rel(app), "holds no Watch app: the upload of the iPhone app carries it")
    if failures == before:
        ok("identity", "%d parts of %s, %s (%s), flavour %s, level %s; the extensions that name no level: %s" % (
            len(parts), base, version, build, flavour, level,
            ", ".join(rel(p) for p in parts if "KnotMilestoneLevel" not in info(p)) or "none"))

def check_privacy():
    before = failures
    for part in parts:
        path = resource(part, "PrivacyInfo.xcprivacy")
        manifest = plist_of(path) if os.path.isfile(path) else None
        if manifest is None:
            fail("privacy", rel(part), "no privacy manifest, PrivacyInfo.xcprivacy, that reads as a plist")
            continue
        if manifest.get("NSPrivacyTracking") is not False:
            fail("privacy", rel(part), "its privacy manifest does not say NSPrivacyTracking false")
        if manifest.get("NSPrivacyCollectedDataTypes") != []:
            fail("privacy", rel(part), "its privacy manifest declares collected data, or does not say: NSPrivacyCollectedDataTypes is not an empty list")
    if failures == before:
        ok("privacy", "a privacy manifest in each of its %d parts, declaring no tracking and no collected data" % len(parts))

def macho_files():
    for folder, _, files in os.walk(app):
        for name in files:
            path = os.path.join(folder, name)
            try:
                with open(path, "rb") as f:
                    if f.read(4) in MACHO:
                        yield path
            except OSError:
                pass

def check_usage():
    before = failures
    symbols = {p: set() for p in parts}
    for path in macho_files():
        out = run(["nm", "-u", "-j", path]).stdout.decode("utf-8", "replace")
        symbols[owner(path) if path.startswith(app + "/") else app] |= {s.strip() for s in out.splitlines()}
    asked = []
    for part in parts:
        i = info(part)
        for what, classes, keys in USAGE:
            uses = [c for c in classes if "_OBJC_CLASS_$_" + c in symbols[part]]
            if not uses:
                continue
            held = [k for k in keys if isinstance(i.get(k), str) and i.get(k).strip()]
            if held:
                asked.append("%s asks for %s (%s), and says why in %s" % (rel(part), what, ", ".join(uses), held[0]))
            else:
                fail("usage", rel(part), "asks for %s (%s) and has no usage string: %s" % (what, ", ".join(uses), " or ".join(keys)))
    if failures == before:
        ok("usage", "; ".join(asked) if asked else "no part asks for a protected resource")

def check_encryption():
    before = failures
    apps = [p for p in parts if p.endswith(".app")]
    for part in apps:
        value = info(part).get("ITSAppUsesNonExemptEncryption")
        if value is None:
            fail("encryption", rel(part), "no ITSAppUsesNonExemptEncryption: App Store Connect would ask about encryption at each upload")
        elif value is not False:
            fail("encryption", rel(part), "ITSAppUsesNonExemptEncryption is not false: the upload would need export compliance documents")
    if failures == before:
        ok("encryption", "ITSAppUsesNonExemptEncryption false in each of its %d apps" % len(apps))

def check_icons():
    before = failures
    tool = os.environ.get("KNOT_ASSETUTIL", "xcrun assetutil").split()
    checked = []
    for part in parts:
        if not part.endswith(".app") or info(part).get("DTPlatformName") not in ("iphoneos", "watchos"):
            continue
        car = resource(part, "Assets.car")
        if not os.path.isfile(car):
            fail("icons", rel(part), "no asset catalogue, Assets.car, so no App Store icon")
            continue
        result = run(tool + ["--info", car])
        try:
            renditions = json.loads(result.stdout)
        except Exception:
            fail("icons", rel(part), "assetutil could not read its Assets.car")
            continue
        icons = [r for r in renditions if isinstance(r, dict) and r.get("AssetType") == "Icon Image" and r.get("PixelWidth", 0) >= 1024]
        if not icons:
            fail("icons", rel(part), "no App Store icon, an icon image of 1024 pixels, in its Assets.car")
        for r in icons:
            if r.get("Opaque") is not True:
                fail("icons", rel(part), "its App Store icon %s (%s) is not opaque" % (r.get("RenditionName"), r.get("Idiom")))
        checked.append(rel(part))
    if failures == before:
        ok("icons", "an opaque App Store icon in %s" % ", ".join(checked))

def entitlements_of(part):
    out = run(["codesign", "-d", "--entitlements", "-", "--xml", part]).stdout
    try:
        return plistlib.loads(out) if out.strip() else {}
    except Exception:
        return None

def check_entitlements():
    before = failures
    for part in parts:
        e = entitlements_of(part)
        if e is None:
            fail("entitlements", rel(part), "its entitlements cannot be read from its signature")
            continue
        if e.get("get-task-allow") is True:
            fail("entitlements", rel(part), "get-task-allow: a development signature, which App Store Connect refuses")
        push = e.get("aps-environment", e.get("com.apple.developer.aps-environment"))
        if part == app and push is None:
            fail("entitlements", rel(part), "no push entitlement, aps-environment, which CloudKit's notifications need")
        if push is not None and push != "production":
            fail("entitlements", rel(part), "aps-environment %s, not production" % push)
        containers = e.get("com.apple.developer.icloud-container-identifiers")
        if part == app and containers is None:
            fail("entitlements", rel(part), "no iCloud container")
        if containers is not None:
            if containers != [container]:
                fail("entitlements", rel(part), "iCloud containers %s, not %s alone" % (", ".join(containers) or "none", container))
            environment = e.get("com.apple.developer.icloud-container-environment")
            if environment != "Production":
                fail("entitlements", rel(part), "iCloud container environment %s, not Production" % (environment or "not set"))
        groups = e.get("com.apple.security.application-groups")
        if groups != [group]:
            fail("entitlements", rel(part), "app groups %s, not %s alone" % (", ".join(groups or []) or "none", group))
        profile = next((p for p in (os.path.join(part, "embedded.mobileprovision"), os.path.join(part, "Contents", "embedded.provisionprofile")) if os.path.isfile(p)), None)
        if profile is None:
            fail("entitlements", rel(part), "no provisioning profile")
            continue
        try:
            p = plistlib.loads(run(["security", "cms", "-D", "-i", profile]).stdout)
        except Exception:
            fail("entitlements", rel(part), "its provisioning profile cannot be read")
            continue
        if p.get("ProvisionedDevices"):
            fail("entitlements", rel(part), "its provisioning profile lists %d devices: a development or ad hoc profile, not App Store Connect's" % len(p["ProvisionedDevices"]))
        if p.get("ProvisionsAllDevices"):
            fail("entitlements", rel(part), "its provisioning profile provisions every device: an enterprise profile")
        allowed = p.get("Entitlements", {}) or {}
        if allowed.get("get-task-allow") is True:
            fail("entitlements", rel(part), "its provisioning profile allows get-task-allow")
        profile_push = allowed.get("aps-environment")
        if profile_push is not None and profile_push != "production":
            fail("entitlements", rel(part), "its provisioning profile's aps-environment is %s, not production" % profile_push)
    if failures == before:
        ok("entitlements", "each of its %d parts: push and iCloud in production, %s and %s, no get-task-allow, a profile that lists no device" % (len(parts), group, container))

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
            container="$WANT_CONTAINER" flavour="$FLAVOUR" level="$LEVEL" build="$BUILD" checks="$checks" 2>&1
        echo "checks ended $?"
    )
    [[ $ended == 0 ]] || status=1
    knot_scan_binaries "$app" || scan=$?
    case $scan in
        0) say "ok    binaries: no fakes and no debug launch argument in its $KNOT_SCAN_COUNT Mach-O files" ;;
        1) say "FAIL  binaries: $KNOT_SCAN_FILE holds what a release may not: $(tr '\n' ' ' <<<"$KNOT_SCAN_HELD" | cut -c1-200)"; status=1 ;;
        *) say "FAIL  binaries: no Mach-O file found in the product to scan"; status=1 ;;
    esac
    return "$status"
}

say "the checks on the archive, $(basename "$ARCHIVE"):"
if [[ $MODE == rehearsal && "$(knot_plist "$APP/Info.plist" CFBundleIdentifier)" == "$MILESTONE_BUNDLE" ]]; then
    knot_fail "release-rehearsal-identifiers" "The rehearsal's archive carries $MILESTONE_BUNDLE, the milestone's bundle ID: no build but scripts/milestone-build.sh may." \
        "Read how the rehearsal's archive was made; do not run the product." "safe" "the run's folder, which holds the archive"
fi
if ! check_product "$APP" "$ARCHIVE" configuration,identity,privacy,usage,encryption,icons; then
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
say "  2. check the exported Knot.ipa, what would be uploaded: every check above, then the push and iCloud entitlements in production, the app group and the container, no get-task-allow, profiles that list no device"
say "  3. App Store Connect's validation: altool --validate-app Knot.ipa, with the key"
say "  4. the upload: altool --upload-package Knot.ipa, with the key, once and never retried"
say "the variables it reads, by name: $(for name in $RELEASE_VARIABLES; do printf '%s (%s), ' "$name" "$(key_state "$name")"; done | sed 's/, $//')"
if [[ $MODE == dry-run ]]; then
    say "dry run passed: the candidate is checked, at .build/release/$(basename "$RUN")/candidate/$(basename "$ARCHIVE"). Nothing is exported, validated or uploaded."
    exit 0
fi

# ------------------------------------------------------------------ the export, with distribution signing

EXPORT="$RUN/export"
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
export_archive() {
    { TMPDIR="$TMP/" xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
        -exportOptionsPlist "$options_plist" -allowProvisioningUpdates \
        -authenticationKeyPath "$KNOT_ASC_KEY_PATH" -authenticationKeyID "$KNOT_ASC_KEY_ID" \
        -authenticationKeyIssuerID "$KNOT_ASC_ISSUER_ID" 2>&1 | logged; } 2>/dev/null # limit: export_archive
}
status=0
knot_run_limited "The export for App Store Connect" "$KNOT_BUILD_LIMIT" export_archive || status=$?
IPA="$EXPORT/Knot.ipa"
if ((status != 0)) || [[ ! -f $IPA ]]; then
    grep -E 'error:|EXPORT FAILED|did not end within' "$LOG" | tail -n 10 | sed 's/^/    /' || true
    knot_fail "release-export" "The export for App Store Connect failed$( [[ -f $IPA ]] || echo ", and left no Knot.ipa"). Its lines are in .build/release/$(basename "$RUN")/release.log." \
        "Read the log. A signing error that names a certificate, a profile or the account needs the owner." "safe" \
        "Xcode may have made a distribution certificate or an App Store profile in the owner's account; the run's folder"
fi
unpacked="$TMP/unpacked"
mkdir -p "$unpacked"
ditto -x -k "$IPA" "$unpacked"
EXPORTED="$unpacked/Payload/Knot.app"
[[ -d $EXPORTED ]] || knot_fail "release-export" "Knot.ipa holds no Payload/Knot.app." "Read the log." "safe" "the run's folder"
say "the checks on what would be uploaded, Knot.ipa:"
if ! check_product "$EXPORTED" "" configuration,identity,privacy,usage,encryption,icons,entitlements; then
    knot_fail "release-export-check" "What would be uploaded failed a check, each named above with its part. Nothing was sent to App Store Connect." \
        "Fix what each FAIL line names, and make a new candidate: a run is never resumed." "safe" "the run's folder, which holds the export"
fi

# ------------------------------------------------------------------ App Store Connect

ALTOOL=(xcrun altool)
[[ -z ${KNOT_ALTOOL:-} ]] || ALTOOL=("$KNOT_ALTOOL")
# altool with the key, its temporary files in tmp/, its output filtered before it reaches a file.
asc_run() {
    { "${ALTOOL[@]}" "$@" --api-key "$KNOT_ASC_KEY_ID" --api-issuer "$KNOT_ASC_ISSUER_ID" \
        --p8-file-path "$KNOT_ASC_KEY_PATH" -CDTempDir "$TMP/altool" 2>&1 | release_filter >"$TMP/altool.out"; } 2>/dev/null
}
asc() { # asc <limit> <altool arguments…>
    local limit=$1
    shift
    mkdir -p "$TMP/altool"
    knot_limit "$limit" asc_run "$@"
}
say "App Store Connect's validation of Knot.ipa"
status=0
asc "${KNOT_VALIDATE_LIMIT:-1800}" --validate-app "$IPA" || status=$?
tee -a "$LOG" <"$TMP/altool.out"
if ((status != 0)); then
    knot_fail "release-validation" "App Store Connect's validation refused Knot.ipa$( ((KNOT_LIMIT_HIT)) && echo ", or did not answer in time"): its lines are above and in the run's release.log. Nothing was uploaded." \
        "Fix what it names, in a pull request, and make a new candidate." "safe" "the run's folder, which holds the export"
fi
say "App Store Connect validated Knot.ipa"
if [[ $MODE == validate ]]; then
    say "validation passed: Knot.ipa, at .build/release/$(basename "$RUN")/export/, is checked and validated. Nothing is uploaded."
    exit 0
fi

say "uploading Knot.ipa to App Store Connect, once"
status=0
asc "${KNOT_UPLOAD_LIMIT:-3600}" --upload-package "$IPA" || status=$?
tee -a "$LOG" <"$TMP/altool.out"
if ((status != 0)); then
    knot_fail "release-upload" "The upload of Knot $(knot_plist "$EXPORTED/Info.plist" CFBundleShortVersionString) ($BUILD) failed$( ((KNOT_LIMIT_HIT)) && echo ", or did not end in time"): its lines are above and in the run's release.log. It was not retried." \
        "Check App Store Connect, the app's TestFlight builds, for build $BUILD, before any retry: the upload may have reached it. A retry needs the owner's word, and a build number App Store Connect has not taken." \
        "unsafe" "the upload may have reached App Store Connect; the run's folder holds the export"
fi
say "uploaded: Knot $(knot_plist "$EXPORTED/Info.plist" CFBundleShortVersionString) ($BUILD), $LEVEL, from ${AT:0:12}. App Store Connect processes it before TestFlight offers it."
