#!/bin/bash
# Keeps heavy builds on this Mac to a few at a time (docs/architecture.md §18).
#
#   scripts/build-slot.sh run [--gate] [--all] [--mac-ui] [--simulators] [--label <text>] -- <command…>
#   scripts/build-slot.sh status
#
# `run` waits for a slot, runs the command holding it, and returns the command's status.
#   --gate        the merge gate: it may also take the slot kept for the gate
#   --all         every build slot at once, as --perf needs
#   --mac-ui      also the one exclusive slot for Mac UI tests, which need the desktop
#   --simulators  also one of the slots that limit how many simulator sets are booted
#
# A slot is a lock taken with /usr/bin/lockf, which the system releases when its holder
# dies, so a killed build never leaves a slot taken. There are KNOT_BUILD_SLOTS build
# slots (3), of which the last is kept for the gate, and KNOT_SIMULATOR_SLOTS simulator
# slots (2). A waiting run prints a line each minute naming the holders, and gives up after
# KNOT_SLOT_TIMEOUT seconds (3600). The slots live in KNOT_SLOT_DIR, by default
# the build folder's slots/.

source "$(dirname "$0")/lib/common.sh"

SLOT_DIR="${KNOT_SLOT_DIR:-$KNOT_BUILD_FOLDER/slots}"
BUILD_SLOTS="${KNOT_BUILD_SLOTS:-3}"
SIMULATOR_SLOTS="${KNOT_SIMULATOR_SLOTS:-2}"
TIMEOUT="${KNOT_SLOT_TIMEOUT:-3600}"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "build-slot-usage" "$1" "Run scripts/build-slot.sh --help." "safe" "nothing"; }

# Whether a lock file is held now. lockf creates the file if needed.
held() { ! /usr/bin/lockf -s -t 0 -k "$1" true; }

# Prints the holder of each held slot.
holders() {
    local lock
    for lock in "$SLOT_DIR"/*.lock; do
        [[ -e $lock ]] || continue
        if held "$lock"; then
            printf '%s: %s\n' "$(basename "$lock" .lock)" "$(cat "${lock%.lock}.holder" 2>/dev/null || echo unknown)"
        fi
    done
}

status() {
    mkdir -p "$SLOT_DIR"
    local out
    out="$(holders)"
    if [[ -n $out ]]; then printf '%s\n' "$out"; else echo "build-slot: every slot is free"; fi
}

# Tries to run the command holding every lock in $@ before `--`, without waiting. Returns 75
# when a lock was taken by someone else, else the command's status.
try_run() {
    local locks=() marker
    while [[ $1 != -- ]]; do locks+=("$1"); shift; done
    shift
    marker="$(mktemp "$SLOT_DIR/.attempt.XXXXXX")"
    rm -f "$marker"
    local chain=() lock
    for lock in "${locks[@]}"; do chain+=(/usr/bin/lockf -s -t 0 -k "$lock"); done
    local status=0
    "${chain[@]}" /bin/bash -c '
        marker=$1 label=$2 count=$3
        shift 3
        holder="pid $$, $label, since $(date "+%H:%M:%S")"
        i=0
        while ((i < count)); do printf "%s\n" "$holder" >"${1%.lock}.holder"; shift; i=$((i + 1)); done
        : >"$marker"
        exec "$@"' _ "$marker" "$LABEL" "${#locks[@]}" "${locks[@]}" "$@" || status=$?
    if [[ -e $marker ]]; then
        rm -f "$marker"
        return "$status"
    fi
    return 75
}

run() {
    local gate=0 all=0 mac_ui=0 simulators=0
    LABEL="$KNOT_WORKTREE_ID"
    while [[ $# -gt 0 && $1 != -- ]]; do
        case $1 in
            --gate) gate=1; shift ;;
            --all) all=1; shift ;;
            --mac-ui) mac_ui=1; shift ;;
            --simulators) simulators=1; shift ;;
            --label) LABEL="$KNOT_WORKTREE_ID ${2:-}"; shift 2 ;;
            *) usage_fail "Unknown option: $1" ;;
        esac
    done
    [[ ${1:-} == -- && $# -ge 2 ]] || usage_fail "run needs -- and a command."
    shift
    mkdir -p "$SLOT_DIR"

    # The build slots this run may take: all but the gate's, unless it is the gate.
    local open=$((BUILD_SLOTS - 1)) n
    ((gate)) && open=$BUILD_SLOTS
    local choices=()
    if ((all)); then
        local every=""
        for ((n = 1; n <= BUILD_SLOTS; n++)); do every="$every $SLOT_DIR/build-$n.lock"; done
        choices=("$every")
    else
        # The gate tries its own slot first.
        if ((gate)); then choices+=("$SLOT_DIR/build-$BUILD_SLOTS.lock"); fi
        for ((n = 1; n <= open; n++)); do
            ((gate && n == BUILD_SLOTS)) || choices+=("$SLOT_DIR/build-$n.lock")
        done
    fi
    local extras=() sims=()
    ((mac_ui)) && extras+=("$SLOT_DIR/mac-ui.lock")
    if ((simulators)); then
        for ((n = 1; n <= SIMULATOR_SLOTS; n++)); do sims+=("$SLOT_DIR/simulators-$n.lock"); done
    else
        sims=("")
    fi

    local start waited=0 last_report choice sim status
    start=$(knot_now)
    last_report=$start
    while true; do
        for choice in "${choices[@]}"; do
            for sim in "${sims[@]}"; do
                local locks=()
                # Unquoted on purpose: --all names several slots in one choice.
                # shellcheck disable=SC2206
                locks=($choice)
                [[ -n $sim ]] && locks+=("$sim")
                locks+=(${extras[@]+"${extras[@]}"})
                status=0
                try_run "${locks[@]}" -- "$@" || status=$?
                if ((status != 75)); then
                    ((waited)) && echo "build-slot: got a slot after $(knot_duration $(($(knot_now) - start)))" >&2
                    return "$status"
                fi
            done
        done
        waited=1
        if (($(knot_now) - last_report >= 60)); then
            last_report=$(knot_now)
            echo "build-slot: waiting $(knot_duration $((last_report - start))) for a slot. Held: $(holders | tr '\n' ';')" >&2
        fi
        if (($(knot_now) - start >= TIMEOUT)); then
            knot_fail "infra-slot-timeout" "No slot came free in $(knot_duration "$TIMEOUT"). Held: $(holders | tr '\n' ';')" \
                "Wait for the holders to finish, or stop a run that hangs. Rerun when a slot is free." "safe" "nothing"
        fi
        sleep 1
    done
}

case ${1:-} in
    run) shift; run "$@" ;;
    status) status ;;
    -h | --help) usage ;;
    *) usage_fail "Unknown command: ${1:-none}." ;;
esac
