#!/bin/bash
# Render the iPhone matrix's Xcode previews in this checkout's iPhone simulator.
set -euo pipefail
export KNOT_AGENT=1
renderer="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(git -C "$renderer" rev-parse --show-toplevel)"
source "$repo/scripts/lib/common.sh"
knot_select_xcode
knot_check_xcodegen
output="${1:?Name an output folder for the PNGs and index}"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
scratch="$(mktemp -d)"
cleanup_build() {
    local status=$?
    # The generated project and its logs can be inspected after rendering. The
    # scratch build is specific to this run and does not need to stay on disk.
    # SIGKILL skips this trap. The printed build-log path identifies the scratch directory.
    (
        cd -- "$scratch"
        if [[ -d ./DerivedData ]]; then /usr/bin/find ./DerivedData -depth -delete; fi
    ) || status=1
    exit "$status"
}
trap cleanup_build EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$scratch/Sources"
preview_sources="$repo/Packages/KnotKit/Sources/KnotUIPreviews"
cp "$preview_sources/"*.swift "$scratch/Sources/"
python3 "$renderer/preview_catalog.py" "$preview_sources/MatrixPreviews.swift" "$scratch"
mv "$scratch/PhonePreviewCatalog.swift" "$scratch/Sources/"
cp "$renderer/PreviewRenderer.swift" "$scratch/Sources/"
mkdir "$scratch/Sources/Assets.xcassets"
cp -R "$repo/Apps/iOS/Assets.xcassets/AccentColor.colorset" "$scratch/Sources/Assets.xcassets/"
cp "$repo/Apps/iOS/Assets.xcassets/Contents.json" "$scratch/Sources/Assets.xcassets/"
cat > "$scratch/project.yml" <<YAML
name: KnotDesignReview
deploymentTargets:
  iOS: "27.0"
packages:
  KnotKit:
    path: "$repo/Packages/KnotKit"
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG
    COMPILER_INDEX_STORE_ENABLE: NO
    CODE_SIGNING_ALLOWED: NO
targets:
  KnotDesignReview:
    type: application
    platform: iOS
    sources: Sources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.knot.design-review
        GENERATE_INFOPLIST_FILE: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: ""
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    dependencies:
      - package: KnotKit
        products: [KnotCore, KnotFakes, KnotUI]
YAML
(cd "$scratch" && "$KNOT_XCODEGEN_PATH" generate --quiet)
df -g / /System/Volumes/Data
available=$(df -g /System/Volumes/Data | awk 'NR == 2 {print $4}')
[[ $available -ge 24 ]] || { echo "Preview build needs 24 GB free on the build Mac." >&2; exit 1; }
echo "Preview build log: $scratch/build.log"
"$repo/scripts/build-slot.sh" run --label phone-previews -- xcodebuild \
    -project "$scratch/KnotDesignReview.xcodeproj" -scheme KnotDesignReview -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$scratch/DerivedData" "ARCHS=$(uname -m)" \
    -clonedSourcePackagesDirPath "$KNOT_SOURCE_PACKAGES" build 2>&1 | knot_filter_team > "$scratch/build.log"
df -g / /System/Volumes/Data
"$repo/scripts/build-slot.sh" run --simulators --label render-phone-previews -- \
    "$renderer/capture_previews.sh" "$repo" "$scratch" "$output"
python3 "$renderer/index_previews.py" "$scratch/catalog.json" "$output" "$repo" --previews-only
