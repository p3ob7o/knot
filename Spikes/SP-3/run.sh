#!/bin/bash
# SP-3's spike: builds the app and every packaging of the tool, signed for development
# with the owner's team, and runs the checks. Never merged (docs/plan/SP-3.md).
#
#   Spikes/SP-3/run.sh build     generate the project and build it, team-signed
#   Spikes/SP-3/run.sh signing   print what each piece carries, masked
#   Spikes/SP-3/run.sh checks tool|app   run the checks of one phase, each with a time limit
#   Spikes/SP-3/run.sh cleanup   remove the spike's files from the group container, by name
#   Spikes/SP-3/run.sh quote <file>   print a log through the mask, the only way to quote one
#
# Needs KNOT_LOCAL_CONFIG linked by scripts/bootstrap.sh. Every line this script prints
# goes through mask(), which writes the team ID as <team> and the home folder as ~, because
# xcodebuild and codesign print both.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
source "$root/scripts/lib/common.sh"
knot_select_xcode

out="$root/.build/sp3"
derived="$out/DerivedData"
logs="$out/logs"
mkdir -p "$logs"
app="$derived/Build/Products/Debug/Knot Dev.app"
team="$(xcodebuild -project "$here/SP3.xcodeproj" -target knot-dev -showBuildSettings 2>/dev/null |
    awk '$1 == "DEVELOPMENT_TEAM" { print $3; exit }' || true)"

mask() {
    sed -E -e "s/${team:-NO-TEAM-KNOWN}/<team>/g" -e "s#$HOME#~#g" -e "s#/Users/[^/ \"]+#~#g" \
        -e 's/(Apple (Development|Distribution)|Developer ID Application|3rd Party Mac Developer [A-Za-z]+): [^(]*\([^)]*\)/\1: <holder>/g'
}

# Runs a command with a time limit, so that a run that waits on a dialog ends and is
# reported as what it is.
limit() { knot_with_timeout "$@"; }

build() {
    (cd "$here" && xcodegen generate --quiet --spec project.yml)
    team="$(xcodebuild -project "$here/SP3.xcodeproj" -target knot-dev -showBuildSettings 2>/dev/null |
        awk '$1 == "DEVELOPMENT_TEAM" { print $3; exit }' || true)"
    [[ -n $team ]] || { echo "no DEVELOPMENT_TEAM: link KNOT_LOCAL_CONFIG with scripts/bootstrap.sh"; exit 1; }
    # Two ways to sign, both with the team's development certificate:
    #   build             no provisioning profile anywhere, and no Xcode account. Xcode
    #                     refuses to sign an app that claims a `group.` app group without a
    #                     profile, so the build is unsigned and sign_unprofiled() signs each
    #                     piece with codesign, innermost first.
    #   build --profiles  the app and the helper bundle sign automatically and get their
    #                     profiles. Needs an Xcode account signed in to the team; the first
    #                     run registers the development identifiers in that account.
    local signing_args=(CODE_SIGNING_ALLOWED=NO)
    # --profiles also lets Xcode register the Mac it runs on as a development device, which
    # a Mac development profile needs. It registers that Mac only.
    if [[ ${1:-} == --profiles ]]; then signing_args=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration REGISTER_APP_GROUPS=YES); fi
    "$root/scripts/build-slot.sh" run --label "SP-3 spike build" -- \
        xcodebuild -project "$here/SP3.xcodeproj" -scheme SP3 -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$derived" \
        -clonedSourcePackagesDirPath "$out/SourcePackages" COMPILER_INDEX_STORE_ENABLE=NO \
        ENABLE_DEBUG_DYLIB=NO KNOT_SIGNING=team "${signing_args[@]}" ${SP3_CLEAN:+clean} build >"$logs/build.log" 2>&1 || {
        grep -E 'error:|warning:|BUILD' "$logs/build.log" | mask | tail -n 30
        exit 1
    }
    grep -E 'BUILD' "$logs/build.log" | tail -n 1
    [[ ${1:-} == --profiles ]] || sign_unprofiled
    signing
}

# Signs every piece with the team's Apple Development certificate, its own entitlements,
# the hardened runtime and no profile. The group in the entitlements files is a build
# setting, which this expands: the development group of Identifiers.xcconfig, and the
# Team-ID form, whose prefix is the team's ID and a dot, as $(TeamIdentifierPrefix) is.
sign_unprofiled() {
    local identity tmp
    identity="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')"
    [[ -n $identity ]] || { echo "no Apple Development identity in the keychain"; exit 1; }
    tmp="$(mktemp -d)"
    local name
    for name in App Tool Tool-inherit Helper; do
        sed -e 's/$(KNOT_APP_GROUP_dev)/group.com.p3ob7o.knot.dev/' -e "s/\$(TeamIdentifierPrefix)/$team./" \
            "$here/Config/$name.entitlements" >"$tmp/$name.entitlements"
    done
    sign() { # <path> <entitlements> [identifier]
        codesign --force --sign "$identity" --options runtime --timestamp=none \
            --entitlements "$tmp/$2.entitlements" ${3:+--identifier "$3"} "$1" >>"$logs/sign.log" 2>&1
    }
    : >"$logs/sign.log"
    sign "$app/Contents/Helpers/variants/knot-dev-noplist" Tool com.p3ob7o.knot.dev.cli
    sign "$app/Contents/Helpers/variants/knot-dev-inherit" Tool-inherit com.p3ob7o.knot.dev.cli
    sign "$app/Contents/MacOS/knot-dev" Tool com.p3ob7o.knot.dev.cli
    sign "$app/Contents/Helpers/knot-dev.app" Helper
    sign "$app" App
    echo "signed with the development certificate, no profile"
}

# What each packaging carries: its identifier, its signature, its entitlements, whether
# an Info.plist is bound and whether a profile is embedded. Team lines are masked.
signing() {
    local item
    for item in "$app" "$app/Contents/MacOS/knot-dev" "$app/Contents/Helpers/knot-dev.app" \
        "$app/Contents/Helpers/variants/knot-dev-noplist" "$app/Contents/Helpers/variants/knot-dev-inherit"; do
        echo "== ${item#"$derived/Build/Products/Debug/"}"
        codesign -d --verbose=2 "$item" 2>&1 |
            grep -E '^(Identifier|Format|Authority|TeamIdentifier|Info.plist|Signature)' | mask | sed 's/^/   /'
        codesign -d --entitlements - --xml "$item" 2>/dev/null | plutil -convert json -o - - 2>/dev/null | mask |
            sed 's/^/   entitlements: /'
        echo
        [[ -d $item ]] && for p in "$item/Contents/embedded.provisionprofile"; do
            if [[ -f $p ]]; then
                security cms -D -i "$p" 2>/dev/null >"$logs/profile.plist" || true
                echo "   profile: $(/usr/libexec/PlistBuddy -c 'Print :Name' "$logs/profile.plist" 2>/dev/null | mask)," \
                    "groups $(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$logs/profile.plist" 2>/dev/null | tr -d '\n ' | mask)," \
                    "devices $(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$logs/profile.plist" 2>/dev/null | grep -c -v -E '^(Array \{|\})$' || true)," \
                    "all devices $(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$logs/profile.plist" 2>/dev/null || echo no)"
                rm -f "$logs/profile.plist"
            else
                echo "   profile: none"
            fi
        done
        echo
    done
    codesign --verify --strict --deep "$app" && echo "codesign --verify --strict --deep: ok"
}

cleanup() {
    limit 10 "$app/Contents/MacOS/knot-dev" cleanup 2>&1 | mask
}

case "${1:-}" in
    build) shift; build "$@" ;;
    signing) signing ;;
    cleanup) cleanup ;;
    quote) mask <"${2:?a log file}" ;;
    checks)
        exec python3 -I "$here/checks.py" "$app" "$team" \
            "$root/.build/DerivedData/Build/Products/Debug/Knot.app/Contents/MacOS/knot-dev" \
            "${2:?tool or app}" "$logs/checks-${2}.json"
        ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
