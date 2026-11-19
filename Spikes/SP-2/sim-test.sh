#!/bin/bash
# Runs one SP-2 test between this worktree's iPhone and Watch simulators, and prints the
# lines that each app's event log gained. No test opens a microphone.
#
#   Spikes/SP-2/sim-test.sh watch <test> [-sp2-name value …]   launch the Watch app with a test
#   Spikes/SP-2/sim-test.sh phone <test>                        launch the iPhone app with a test
#   Spikes/SP-2/sim-test.sh relaunch watch|phone                terminate and launch, no test
#   Spikes/SP-2/sim-test.sh terminate watch|phone
#
# Watch tests: run, cancel, missing, duplicate, probes, bigprobe, context, message,
# outstanding (see Watch/Sources/LaunchTests.swift). Phone tests: context, probes.
# SP2_WAIT sets the seconds to wait before reading the logs (default 20).

source "$(dirname "$0")/../../scripts/lib/common.sh"
knot_select_xcode

phone="$("$KNOT_ROOT/scripts/sim.sh" udid iphone)"
watch="$("$KNOT_ROOT/scripts/sim.sh" udid watch)"
bundle=com.p3ob7o.knot.dev

log_of() {
    local device=$1 id=$2 data
    data="$(xcrun simctl get_app_container "$device" "$id" data 2>/dev/null)" || return 0
    printf '%s/Library/Application Support/SP2/events.jsonl' "$data"
}

lines() { [[ -f $1 ]] && wc -l <"$1" | tr -d ' ' || echo 0; }

phone_log="$(log_of "$phone" $bundle)"
watch_log="$(log_of "$watch" $bundle.watchkitapp)"
phone_before="$(lines "$phone_log")"
watch_before="$(lines "$watch_log")"

target() { case $1 in watch) echo "$watch $bundle.watchkitapp" ;; phone) echo "$phone $bundle" ;; esac; }

case ${1:-} in
    watch | phone)
        side=$1 test=$2
        shift 2
        read -r device id <<<"$(target "$side")"
        xcrun simctl terminate "$device" "$id" 2>/dev/null || true
        sleep 1
        xcrun simctl launch "$device" "$id" -sp2-test "$test" "$@" >/dev/null
        ;;
    relaunch)
        read -r device id <<<"$(target "$2")"
        xcrun simctl terminate "$device" "$id" 2>/dev/null || true
        sleep 1
        xcrun simctl launch "$device" "$id" >/dev/null
        ;;
    terminate)
        read -r device id <<<"$(target "$2")"
        xcrun simctl terminate "$device" "$id"
        exit 0
        ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac

sleep "${SP2_WAIT:-20}"
phone_log="$(log_of "$phone" $bundle)"
watch_log="$(log_of "$watch" $bundle.watchkitapp)"
echo "--- Watch"
[[ -f $watch_log ]] && tail -n +"$((watch_before + 1))" "$watch_log"
echo "--- iPhone"
[[ -f $phone_log ]] && tail -n +"$((phone_before + 1))" "$phone_log"
true
