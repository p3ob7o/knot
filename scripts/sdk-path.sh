#!/bin/bash
# Prints where the declarations of a framework are, in the SDK of the Xcode that
# .xcode-version pins (docs/architecture.md §21). Read the declaration there before you
# use an OS 26 or OS 27 API: code must compile against this SDK, so a symbol found only in
# a beta's SDK is not usable. A framework that the platform keeps outside its SDK, such as
# XCUIAutomation, which UI tests import, and XCTest, is found under the platform's own
# Developer/Library/Frameworks. It prints each folder that declares the framework: its
# headers, as XCUIApplication's are, and then its Swift module, as SwiftUI's declarations
# nearly all are. Read both.
#
#   scripts/sdk-path.sh <platform> <framework>
#
# <platform> is ios, ios-simulator, macos, watchos or watchos-simulator. Set
# KNOT_XCODE=/path/to/Xcode.app to read another Xcode's SDK by name.

source "$(dirname "$0")/lib/common.sh"

case ${1:-} in
    -h | --help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
if [[ $# -ne 2 ]]; then
    knot_fail "sdk-path-usage" "scripts/sdk-path.sh takes a platform and a framework, and was given $# arguments." \
        "Run scripts/sdk-path.sh <platform> <framework>, for example scripts/sdk-path.sh ios AppIntents." "safe" "nothing"
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
if [[ ! -d $root ]]; then
    root="$(xcrun --sdk "$sdk" --show-sdk-platform-path)/Developer/Library/Frameworks/$2.framework"
fi
[[ -d $root ]] ||
    knot_fail "sdk-path-missing" "$2 is in neither the $sdk SDK of $(knot_xcode_label) nor its platform's own frameworks." \
        "Check the framework's name, or whether it exists on this platform." "safe" "nothing"
printed=0
if [[ -d $root/Headers ]]; then
    echo "$root/Headers"
    printed=1
fi
if [[ -d $root/Modules/$2.swiftmodule ]]; then
    echo "$root/Modules/$2.swiftmodule"
    printed=1
fi
((printed)) || echo "$root"
