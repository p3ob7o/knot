#!/bin/bash
set -euo pipefail
export KNOT_AGENT=1
repo=$1 scratch=$2 output=$3
source "$repo/scripts/lib/common.sh"
knot_select_xcode

available=$(df -g /System/Volumes/Data | awk 'NR == 2 {print $4}')
[[ $available -ge 24 ]] || { echo "Rendering needs 24 GB free on the build Mac." >&2; exit 1; }
trap '"$repo/scripts/sim.sh" shutdown' EXIT
"$repo/scripts/sim.sh" boot iphone
udid=$("$repo/scripts/sim.sh" udid iphone)
id=app.knot.design-review
simctl() { knot_limit 120 xcrun simctl "$@"; }
# Reset an earlier run's overrides even when it was killed before cleanup.
reset_appearance() {
    local result=0
    simctl ui "$udid" appearance light || result=1
    simctl ui "$udid" content_size large || result=1
    if [[ $(simctl ui "$udid" appearance) != light ||
          $(simctl ui "$udid" content_size) != large ]]; then
        echo "Could not reset the preview simulator's appearance and text size." >&2
        result=1
    fi
    return "$result"
}
restore_simulator() {
    local result=$?
    reset_appearance || result=1
    "$repo/scripts/sim.sh" shutdown || result=1
    exit "$result"
}
trap restore_simulator EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
reset_appearance
# Keep a new simulator's keyboard tutorial out of the capture-state screenshots.
simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
simctl install "$udid" "$scratch/DerivedData/Build/Products/Debug-iphonesimulator/KnotDesignReview.app"
container=$(simctl get_app_container "$udid" "$id" data)
preview_rows="$scratch/rows.tsv"
render_id=$(basename "$scratch")
python3 - "$scratch/catalog.json" > "$preview_rows" <<'PY'
import json
import sys

for index, _, _, slug in json.load(open(sys.argv[1])):
    print(f"{index}\t{slug}")
PY

for combination in light-default dark-default light-ax5; do
    appearance=${combination%%-*}
    size=${combination#*-}
    simctl ui "$udid" appearance "$appearance"
    if [[ $size == ax5 ]]; then
        simctl ui "$udid" content_size accessibility-extra-extra-extra-large
    else
        simctl ui "$udid" content_size large
    fi
    while IFS=$'\t' read -r index slug; do
        image="$output/$slug-$combination.png"
        variant="$render_id-$combination"
        simctl launch --terminate-running-process "$udid" "$id" "$index" "$size" "$variant" >/dev/null
        marker="$container/tmp/$index-$variant.ready"
        for ((attempt = 0; attempt < 600; attempt++)); do
            [[ ! -f $marker ]] || break
            sleep 1
        done
        [[ -f $marker ]] || { echo "Preview did not appear: $slug ($combination)" >&2; exit 1; }
        if ! simctl io "$udid" screenshot "$image" >"$scratch/screenshot.log" 2>&1; then
            cat "$scratch/screenshot.log" >&2
            exit 1
        fi
    done < "$preview_rows"
    echo "Rendered $combination"
done
