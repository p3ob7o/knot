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
original_appearance=$(simctl ui "$udid" appearance)
original_size=$(simctl ui "$udid" content_size)
case $original_appearance in light|dark) ;; *) original_appearance=light ;; esac
case $original_size in unknown|unsupported|'') original_size=large ;; esac
restore_simulator() {
    local result=$?
    simctl ui "$udid" appearance "$original_appearance" || result=1
    simctl ui "$udid" content_size "$original_size" || result=1
    if [[ $(simctl ui "$udid" appearance) != "$original_appearance" ||
          $(simctl ui "$udid" content_size) != "$original_size" ]]; then
        echo "Could not restore the preview simulator's appearance and text size." >&2
        result=1
    fi
    "$repo/scripts/sim.sh" shutdown || result=1
    exit "$result"
}
trap restore_simulator EXIT
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
