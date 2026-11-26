# shellcheck shell=bash
# What scripts/milestone-build.sh and scripts/release.sh read of a built product: its parts,
# their Info.plists, and the fakes and debug launch arguments in its Mach-O files. Source it
# after common.sh.

# The value of a key of a plist, or nothing.
#   knot_plist <plist> <key, as PlistBuddy takes it>
knot_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# The Info.plist of a bundle: Contents/Info.plist for a Mac bundle, Info.plist otherwise.
knot_info_of() { if [[ -f $1/Contents/Info.plist ]]; then echo "$1/Contents/Info.plist"; else echo "$1/Info.plist"; fi; }

# Every part of a product that carries a signature of its own, innermost first: each app
# extension, the Watch app and what it embeds, each framework, the Mac app's tool when its file
# is named, then the app. Each line is a path relative to the folder that holds the app. It
# returns 1, having printed nothing, when the app is not there or find could not read it whole:
# a part it missed is never left out in silence.
#   knot_parts_of <app> [<the Mac tool's file>]
knot_parts_of() {
    local app=$1 tool=${2:-} base found
    base="$(dirname "$app")"
    [[ -d $app ]] || return 1
    found="$(find "$app" -mindepth 1 -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \) -print 2>/dev/null)" ||
        return 1
    {
        [[ -z $found ]] || printf '%s\n' "$found"
        [[ -z $tool || ! -f $app/Contents/MacOS/$tool ]] || echo "$app/Contents/MacOS/$tool"
    } | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1rn -k2 | cut -f2- | sed "s|^$base/||"
    echo "$(basename "$app")"
}

# The fakes and the debug launch arguments, in every Mach-O file of a product, as the packaging
# step scans a Release build (knot_fakes_in, knot_debug_arguments_in): a build that compiled
# DEBUG or KNOT_FAKES in holds them. First, each part's declared executable must be there and be
# a Mach-O file. Every tool's status is read: an inspection that failed is a failure, never a
# file that holds nothing. It returns 0 when it scanned at least one file and found neither; 1
# at the first file that holds either; and 2 when it could not look, as when a tool failed, a
# part's executable is missing, or it found no Mach-O file, so that it cannot pass by reading
# nothing. It sets KNOT_SCAN_COUNT, the files scanned; on a find KNOT_SCAN_FILE, the file's path
# relative to the folder that holds the app, and KNOT_SCAN_HELD, what it holds, one a line; and
# on 2 KNOT_SCAN_WHY, why it could not look. An optimised binary can keep a fake's name or a short
# argument out of its symbols and strings, where no scan sees it.
#   knot_scan_binaries <app>
knot_scan_binaries() {
    local app=$1 base f held list kind part parts info executable files status
    KNOT_SCAN_COUNT=0 KNOT_SCAN_FILE="" KNOT_SCAN_HELD="" KNOT_SCAN_WHY=""
    base="$(dirname "$app")"
    if ! list="$(python3 -I "$KNOT_SCRIPTS/lib/knot_tool.py" debug-arguments)" || [[ -z $list ]]; then
        KNOT_SCAN_WHY="the list of debug launch arguments could not be read"
        return 2
    fi
    if ! parts="$(knot_parts_of "$app")"; then
        KNOT_SCAN_WHY="find could not read the product whole"
        return 2
    fi
    while IFS= read -r part; do
        case $part in *.app | *.appex | *.framework) ;; *) continue ;; esac
        info="$(knot_info_of "$base/$part")"
        executable="$(knot_plist "$info" CFBundleExecutable)"
        f="$base/$part/$executable"
        [[ -f $base/$part/Contents/Info.plist ]] && f="$base/$part/Contents/MacOS/$executable"
        if [[ -z $executable || ! -f $f ]]; then
            KNOT_SCAN_WHY="$part has no executable where its Info.plist names one${executable:+ ($executable)}"
            return 2
        fi
        if ! kind="$(file -b "$f" 2>/dev/null)" || [[ $kind != *Mach-O* ]]; then
            KNOT_SCAN_WHY="$part's executable, $executable, is not a Mach-O file that file can read"
            return 2
        fi
    done <<<"$parts"
    files="$(mktemp)"
    status=0
    find "$app" -type f -print0 >"$files" 2>/dev/null || status=$?
    if ((status != 0)); then
        rm -f "$files"
        KNOT_SCAN_WHY="find could not read the product whole"
        return 2
    fi
    while IFS= read -r -d '' f; do
        if ! kind="$(file -b "$f" 2>/dev/null)"; then
            rm -f "$files"
            KNOT_SCAN_WHY="file could not read ${f#"$base"/}"
            return 2
        fi
        [[ $kind == *Mach-O* ]] || continue
        KNOT_SCAN_COUNT=$((KNOT_SCAN_COUNT + 1))
        if held="$(knot_fakes_in "$f")" || held="$(knot_debug_arguments_in "$f" "$list")"; then
            rm -f "$files"
            if [[ $held == "the inspection failed: "* ]]; then
                KNOT_SCAN_WHY="${f#"$base"/}: ${held#the inspection failed: }"
                return 2
            fi
            KNOT_SCAN_FILE="${f#"$base"/}"
            KNOT_SCAN_HELD="$held"
            return 1
        fi
    done <"$files"
    rm -f "$files"
    if ((KNOT_SCAN_COUNT == 0)); then
        KNOT_SCAN_WHY="no Mach-O file found in the product to scan"
        return 2
    fi
}
