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
simctl install "$udid" "$scratch/DerivedData/Build/Products/Debug-iphonesimulator/KnotDesignReview.app"
container=$(simctl get_app_container "$udid" "$id" data)
preview_rows="$scratch/rows.tsv"
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
    while IFS=$'\t' read -r index slug; do
        image="$output/$slug-$combination.png"
        simctl launch --terminate-running-process "$udid" "$id" "$index" "$size" "$combination" >/dev/null
        marker="$container/tmp/$index-$combination.ready"
        for ((attempt = 0; attempt < 600; attempt++)); do
            [[ ! -f $marker ]] || break
            sleep 1
        done
        [[ -f $marker ]] || { echo "Preview did not appear: $slug ($combination)" >&2; exit 1; }
        simctl io "$udid" screenshot "$image" >/dev/null
    done < "$preview_rows"
done
