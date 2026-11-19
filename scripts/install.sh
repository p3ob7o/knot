#!/bin/bash
# Installs a named build on every paired device (docs/architecture.md §18).
#
#   scripts/install.sh <Knot.app for iOS>               every paired iPhone, iPad and Watch
#   scripts/install.sh <Knot.app for iOS> --device <name or UDID> [--device …]
#   scripts/install.sh <Knot.app for macOS> --mac-folder <folder>
#
# For an iPhone or an iPad it installs the app, and for a Watch the Watch app embedded in
# it. A device that already holds this build, by bundle ID, version and build number, is
# skipped, so a rerun installs only on the devices it missed. It names every device it
# could not reach and exits non-zero when it missed one.
#
# devicectl does not install onto a Mac. For a Mac build it copies the app to a folder the
# owner names, and he opens it there. From the M4 milestone build on, no milestone build is
# installed or run on the build Mac: he opens it on his other Mac.
#
# SP-1 and SP-2 record the procedure that worked on the iPhone and on the Watch, and the
# orchestrator corrects this script from their reports.

source "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
usage_fail() { knot_fail "install-usage" "$1" "Run scripts/install.sh --help." "safe" "nothing"; }

APP=""
MAC_FOLDER=""
WANTED=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --device) [[ -n ${2:-} ]] || usage_fail "--device needs a name or a UDID."; WANTED+=("$2"); shift 2 ;;
        --mac-folder) MAC_FOLDER=${2:-}; [[ -n $MAC_FOLDER ]] || usage_fail "--mac-folder needs a folder."; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage_fail "Unknown option: $1" ;;
        *) [[ -z $APP ]] || usage_fail "Name one build."; APP=${1%/}; shift ;;
    esac
done
[[ -n $APP ]] || usage_fail "Name the build to install: the path of a Knot.app."
[[ -d $APP ]] || usage_fail "$APP is not an app bundle."

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# ------------------------------------------------------------------ a Mac build

if [[ -f $APP/Contents/Info.plist ]]; then
    [[ -n $MAC_FOLDER ]] || usage_fail "A Mac build is not installed with devicectl. Name a folder: --mac-folder <folder>."
    mkdir -p "$MAC_FOLDER"
    destination="$MAC_FOLDER/$(basename "$APP")"
    [[ ! -e $destination ]] || knot_fail "install-mac-exists" "$destination exists already." \
        "Name an empty folder, or move the old build away first." "safe" "nothing"
    ditto "$APP" "$destination"
    level="$(plist "$APP/Contents/Info.plist" KnotMilestoneLevel)"
    echo "install: copied $(plist "$APP/Contents/Info.plist" CFBundleIdentifier) $(plist "$APP/Contents/Info.plist" CFBundleShortVersionString) to $destination"
    if [[ $(plist "$APP/Contents/Info.plist" KnotFlavour) == milestone && $level =~ ^M[4-7]$ ]]; then
        echo "install: this is a milestone build at $level. Open it on the other Mac, never on the build Mac."
    fi
    exit 0
fi
[[ -z $MAC_FOLDER ]] || usage_fail "--mac-folder is for a Mac build, and $APP is not one."
[[ -f $APP/Info.plist ]] || usage_fail "$APP has no Info.plist."

# ------------------------------------------------------------------ devices

knot_select_xcode
work="$(mktemp -d)"
xcrun devicectl list devices --quiet --json-output "$work/devices.json" >/dev/null 2>&1 ||
    knot_fail "infra-devicectl" "devicectl could not list the devices." \
        "Check that Xcode $KNOT_XCODE_VERSION has finished its first launch, then rerun." "safe" "nothing"

# One line per paired physical device: identifier, name, platform, connection state.
python3 -I - "$work/devices.json" >"$work/devices.txt" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    p = d.get("properties", {})
    hardware, connection = p.get("hardware", {}), p.get("connection", {})
    if hardware.get("fidelity", hardware.get("reality")) == "simulated" or connection.get("pairingState") != "paired":
        continue
    name = d.get("deviceProperties", {}).get("name") or p.get("name") or d["identifier"]
    print("\t".join([d["identifier"], name, hardware.get("platform", "?"), connection.get("state", "?"),
                     hardware.get("udid", "")]))
PY

bundle="$(plist "$APP/Info.plist" CFBundleIdentifier)"
version="$(plist "$APP/Info.plist" CFBundleShortVersionString) ($(plist "$APP/Info.plist" CFBundleVersion))"
watch_app="$(find "$APP/Watch" -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"

# Whether a device already holds this build.
holds() {
    local device=$1 id=$2 out
    out="$work/apps-$device.json"
    xcrun devicectl device info apps --device "$device" --bundle-id "$id" --quiet --json-output "$out" >/dev/null 2>&1 || return 1
    python3 -I - "$out" "$version" <<'PY'
import json, sys
apps = json.load(open(sys.argv[1])).get("result", {}).get("apps", [])
sys.exit(0 if any("%s (%s)" % (a.get("version", ""), a.get("bundleVersion", "")) == sys.argv[2] for a in apps) else 1)
PY
}

installed=0
skipped=0
missed=()
count=0
while IFS=$'\t' read -r identifier name platform state udid; do
    if ((${#WANTED[@]})); then
        keep=0
        for want in "${WANTED[@]}"; do [[ $want == "$name" || $want == "$identifier" || $want == "$udid" ]] && keep=1; done
        ((keep)) || continue
    fi
    count=$((count + 1))
    case $platform in
        iOS) path=$APP id=$bundle ;;
        watchOS)
            [[ -n $watch_app ]] || { echo "install: $name is a Watch, and $APP holds no Watch app"; continue; }
            path=$watch_app id="$(plist "$watch_app/Info.plist" CFBundleIdentifier)" ;;
        *) echo "install: $name runs $platform, which this build is not for"; continue ;;
    esac
    if holds "$identifier" "$id"; then
        echo "install: $name holds $id $version already"
        skipped=$((skipped + 1))
        continue
    fi
    if xcrun devicectl device install app --device "$identifier" "$path" --quiet >"$work/install-$identifier.log" 2>&1; then
        echo "install: $name now holds $id $version"
        installed=$((installed + 1))
    else
        echo "install: could not reach $name ($state): $(tail -n 1 "$work/install-$identifier.log")"
        missed+=("$name")
    fi
done <"$work/devices.txt"

if ((count == 0)); then
    knot_fail "install-no-device" "No paired device$( ((${#WANTED[@]})) && printf ' named %s' "${WANTED[*]}") to install on." \
        "Pair the devices for development builds (gate G1): connect each once, or pair it over the network in Xcode's Devices window." \
        "safe" "nothing"
fi
echo "install: $installed installed, $skipped already held the build, ${#missed[@]} missed"
if ((${#missed[@]})); then
    knot_fail "infra-install-missed" "Could not install on: ${missed[*]}." \
        "Unlock each device, keep it near this Mac and on the same network, then rerun: devices that hold the build are skipped." \
        "safe" "the build is installed on the $installed devices above"
fi
