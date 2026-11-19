#!/bin/bash
# Prints where the Swift interfaces of a framework are, in the SDK of the Xcode that
# .xcode-version pins (docs/architecture.md §21). Read the declaration there before you
# use an OS 26 or OS 27 API: code must compile against this SDK, so a symbol found only in
# a beta's SDK is not usable.
#
#   scripts/sdk-path.sh <platform> <framework>
#
# <platform> is ios, ios-simulator, macos, watchos or watchos-simulator. Set
# KNOT_XCODE=/path/to/Xcode.app to read another Xcode's SDK by name.

source "$(dirname "$0")/lib/common.sh"

if [[ $# -ne 2 ]]; then
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi
case $1 in
    ios) sdk=iphoneos ;;
    ios-simulator) sdk=iphonesimulator ;;
    macos) sdk=macosx ;;
    watchos) sdk=watchos ;;
    watchos-simulator) sdk=watchsimulator ;;
    *) knot_fail "sdk-path-usage" "Unknown platform: $1" \
        "Use ios, ios-simulator, macos, watchos or watchos-simulator." "safe" "nothing" ;;
esac
knot_select_xcode
root="$(xcrun --sdk "$sdk" --show-sdk-path)/System/Library/Frameworks/$2.framework"
[[ -d $root ]] ||
    knot_fail "sdk-path-missing" "$2 is not in the $sdk SDK of $(knot_xcode_label)." \
        "Check the framework's name, or whether it exists on this platform." "safe" "nothing"
if [[ -d $root/Modules/$2.swiftmodule ]]; then
    echo "$root/Modules/$2.swiftmodule"
elif [[ -d $root/Headers ]]; then
    echo "$root/Headers"
else
    echo "$root"
fi
