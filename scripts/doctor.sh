#!/bin/bash
# Checks the machine before a build (docs/architecture.md §18). scripts/verify.sh runs it
# first in every run.
#
#   scripts/doctor.sh [--tier quick|full|gate|soak|perf] [--mac-ui] [--models] [--require-signing]
#
#   --mac-ui           the run includes the Mac UI tests, which need Automation Mode
#   --models           the run requires the on-device models, as the gate does
#   --require-signing  the run signs for development, as the gate's signed step does
#
# It fails at once on what no agent can change for the run asked for, and only warns
# about what that run does not need.

source "$(dirname "$0")/lib/common.sh"

TIER=quick
REQUIRE_SIGNING=0
MAC_UI=0
MODELS=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --tier) TIER=${2:-}; shift 2 ;;
        --require-signing) REQUIRE_SIGNING=1; shift ;;
        --mac-ui) MAC_UI=1; shift ;;
        --models) MODELS=1; shift ;;
        -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) knot_fail "doctor-usage" "Unknown argument: $1" "Run scripts/doctor.sh --help." "safe" "nothing" ;;
    esac
done
case $TIER in quick | full | gate | soak | perf) ;; *)
    knot_fail "doctor-usage" "Unknown tier: $TIER" "Use quick, full, gate, soak or perf." "safe" "nothing" ;;
esac

FAILED=0
ok() { printf 'doctor: ok    %-12s %s\n' "$1" "$2"; }
warn() { printf 'doctor: warn  %-12s %s\n' "$1" "$2"; }
note() { printf 'doctor: note  %-12s %s\n' "$1" "$2"; }
bad() { FAILED=1; knot_report "$@" || true; }

# 1. No folder that a cloud file provider syncs. That is where the stray "… 2" copies in
#    the retired tree came from. ~/Documents and ~/Desktop are refused whether or not
#    iCloud Drive syncs them on this Mac, because that setting can change under a build.
synced_root() {
    local path=$1 real
    real="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
    local root
    for root in "$HOME/Documents" "$HOME/Desktop" "$HOME/Library/Mobile Documents" "$HOME/Library/CloudStorage"; do
        root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
        if [[ $real == "$root" || $real == "$root"/* ]]; then
            printf '%s' "$root"
            return 0
        fi
    done
    return 1
}
check_folder() {
    local label=$1 path=$2 root
    if root="$(synced_root "$path")"; then
        bad "doctor-cloud-synced-$label" "The $label folder $path is inside $root, which a cloud file provider syncs." \
            "Move it outside ~/Documents, ~/Desktop, ~/Library/Mobile Documents and ~/Library/CloudStorage." \
            "safe" "nothing"
    else
        ok "$label" "$path"
    fi
}
check_folder repository "$KNOT_ROOT"
common_dir="$(git -C "$KNOT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[[ -n $common_dir ]] && check_folder git "$common_dir"
if [[ -d $KNOT_BUILD_FOLDER ]]; then
    check_folder build "$KNOT_BUILD_FOLDER"
else
    warn build "$KNOT_BUILD_FOLDER does not exist yet (KNOT_BUILD_FOLDER)."
fi
if [[ -n ${KNOT_LOCAL_FIXTURES:-} ]]; then
    check_folder fixtures "$KNOT_LOCAL_FIXTURES"
else
    warn fixtures "KNOT_LOCAL_FIXTURES is not set. Only knot-eval --set local needs it."
fi

# 2. A floor of free disk space.
FLOOR_GB=${KNOT_DISK_FLOOR_GB:-20}
free_gb=$(($(df -k "$KNOT_ROOT" | awk 'NR == 2 { print $4 }') / 1024 / 1024))
if ((free_gb < FLOOR_GB)); then
    bad "infra-disk-space" "$free_gb GB free on the volume of $KNOT_ROOT, below the floor of $FLOOR_GB GB." \
        "Free space: remove merged worktrees with their DerivedData, or old simulators." "safe" "nothing"
else
    ok disk "$free_gb GB free (floor $FLOOR_GB GB)"
fi

# 3. The Xcode that .xcode-version pins, or one named by KNOT_XCODE.
knot_select_xcode
if [[ -n ${KNOT_XCODE_NOTE:-} ]]; then
    warn xcode "$(knot_xcode_label) at $DEVELOPER_DIR"
else
    ok xcode "$(knot_xcode_label) at $DEVELOPER_DIR"
fi

# 4. XcodeGen at its pinned version, as the scripts choose it (knot_resolve_xcodegen).
if knot_check_xcodegen; then
    ok xcodegen "$KNOT_XCODEGEN_VERSION, from $KNOT_XCODEGEN_FROM, at $KNOT_XCODEGEN_PATH"
else
    bad "$KNOT_XCODEGEN_CODE" "$KNOT_XCODEGEN_WHAT" "$KNOT_XCODEGEN_FIX" "safe" "nothing"
fi

# 5. Simulator runtimes for the pinned Xcode's SDKs. Package tests do not need them. The list
#    is read once, with a limit: CoreSimulator that does not answer would hold every run.
runtimes_status=0
runtimes="$(knot_limit "${KNOT_SIMCTL_LIMIT:-120}" xcrun simctl list runtimes 2>/dev/null)" || runtimes_status=$?
((runtimes_status != 124)) ||
    warn simulators "xcrun simctl list runtimes did not answer within ${KNOT_SIMCTL_LIMIT:-120}s: CoreSimulator may be stuck"
runtime_for() {
    local platform=$1 sdk=$2 version runtime
    version="$(xcrun --sdk "$sdk" --show-sdk-version 2>/dev/null || true)"
    # The runtime of the SDK's own version first, else any of the same major version.
    runtime="$(grep "^$platform $version " <<<"$runtimes" | head -n 1 | sed 's/ - com\.apple.*//' || true)"
    [[ -n $runtime ]] ||
        runtime="$(grep "^$platform ${version%%.*}\." <<<"$runtimes" | tail -n 1 | sed 's/ - com\.apple.*//' || true)"
    if [[ -n $runtime ]]; then
        ok "$platform" "$runtime, for SDK $version"
    elif [[ $TIER == quick ]]; then
        warn "$platform" "no $platform ${version%%.*} simulator runtime. Install it: DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -downloadPlatform $platform"
    else
        bad "infra-runtime-$platform" "No $platform ${version%%.*} simulator runtime for SDK $version." \
            "DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -downloadPlatform $platform" "safe" "nothing"
    fi
}
runtime_for iOS iphonesimulator
runtime_for watchOS watchsimulator

# 6. Mac UI tests need two settings that only the owner can make, once, with his
#    password: Automation Mode that turns on without authentication, and developer mode.
#    Automation Mode itself reads "disabled" between test runs; a run turns it on.
missing="$(knot_mac_ui_ready "$(automationmodetool 2>&1 || true)" "$(DevToolsSecurity -status 2>&1 || true)" || true)"
# The Mac UI tests also need the screen unlocked. Only a run that has the Mac UI step reads
# it, and the doctor says what it read as a note, not a failure: the step itself fails at
# once on a locked screen.
if ((MAC_UI)); then
    case "$(knot_console_state)" in
        locked) note screen "locked: the Mac UI tests need it unlocked, and the owner has to unlock it" ;;
        unlocked) note screen "unlocked" ;;
        *) note screen "could not read whether it is locked; the Mac UI step will tell" ;;
    esac
fi
if [[ -z $missing ]]; then
    ok automation "Mac UI tests can run: Automation Mode needs no authentication, and developer mode is on"
else
    message="Mac UI tests cannot run: $(printf '%s' "$missing" | tr '\n' ';' | sed 's/;$//; s/;/; /g')."
    if ((MAC_UI)); then
        bad "doctor-automation-mode" "$message" "Ask the owner to run the command named above, once (gate G1)." "safe" "nothing"
    else
        warn automation "$message"
    fi
fi

# 7. The gate's development-signed step must sign without a prompt. A prompt would hang
#    the run, so the probe has a time limit.
identity="$(security find-identity -v -p codesigning 2>/dev/null | grep -m 1 'Apple Development' | awk '{ print $2 }' || true)"
if [[ -z $identity ]]; then
    if ((REQUIRE_SIGNING)); then
        bad "doctor-signing-identity" "No Apple Development signing identity in the keychain." \
            "The owner sets up signing at gate G1 (docs/dev-setup.md)." "safe" "nothing"
    else
        warn signing "no Apple Development identity yet (gate G1). Only the development-signed step needs one."
    fi
else
    probe="$(mktemp -d)/probe"
    cp /usr/bin/true "$probe"
    if knot_with_timeout 20 codesign --force --timestamp=none --sign "$identity" "$probe" >/dev/null 2>&1; then
        ok signing "signs without a prompt"
    elif ((REQUIRE_SIGNING)); then
        bad "doctor-signing-prompt" "Signing with $identity failed or waited on a prompt." \
            "Allow codesign to use the key without asking (Keychain Access, the key's access control)." "safe" "nothing"
    else
        warn signing "signing with the Apple Development identity failed or waited on a prompt."
    fi
    rm -rf "$(dirname "$probe")"
fi

# 8. The on-device models, which the gate requires (docs/architecture.md §17): the speech
#    model for English and the system language model.
if ((MODELS)); then
    models="$(knot_with_timeout 120 xcrun swift "$KNOT_SCRIPTS/lib/models.swift" 2>&1 || true)"
    if printf '%s\n' "$models" | grep -e '^speech-english: en' >/dev/null &&
        printf '%s\n' "$models" | grep -e '^cleanup: available' >/dev/null; then
        ok models "$(printf '%s\n' "$models" | grep -E '^(speech-english|cleanup):' | tr '\n' ' ')"
    else
        bad "doctor-models" "The gate requires the on-device models, and this Mac reports: $(printf '%s' "$models" | tr '\n' ' ')" \
            "Install the English speech model and turn on Apple Intelligence, then rerun." "safe" "nothing"
    fi
fi

# 9. Agent threads export KNOT_AGENT=1 (AGENTS.md).
if [[ ${KNOT_AGENT:-} == 1 ]]; then ok agent "KNOT_AGENT=1"; else warn agent "KNOT_AGENT is not set. Agent threads set it."; fi

if ((FAILED)); then
    exit 1
fi
