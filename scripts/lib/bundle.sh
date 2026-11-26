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
# is named, then the app. Each line is a path relative to the folder that holds the app.
#   knot_parts_of <app> [<the Mac tool's file>]
knot_parts_of() {
    local app=$1 tool=${2:-} base
    base="$(dirname "$app")"
    {
        find "$app" -mindepth 1 -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \) -print 2>/dev/null || true
        [[ -z $tool || ! -f $app/Contents/MacOS/$tool ]] || echo "$app/Contents/MacOS/$tool"
    } | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1rn -k2 | cut -f2- | sed "s|^$base/||"
    echo "$(basename "$app")"
}

# The fakes and the debug launch arguments, in every Mach-O file of a product, as the packaging
# step scans a Release build (knot_fakes_in, knot_debug_arguments_in): a build that compiled
# DEBUG or KNOT_FAKES in holds them. It returns 0 when it scanned at least one file and found
# neither, 1 at the first file that holds either, and 2 when it found no Mach-O file, so that it
# cannot pass by reading nothing. It sets KNOT_SCAN_COUNT, the files scanned; and on a find
# KNOT_SCAN_FILE, the file's path relative to the folder that holds the app, and KNOT_SCAN_HELD,
# what it holds, one a line.
#   knot_scan_binaries <app>
knot_scan_binaries() {
    local app=$1 f held list
    KNOT_SCAN_COUNT=0 KNOT_SCAN_FILE="" KNOT_SCAN_HELD=""
    list="$(python3 -I "$KNOT_SCRIPTS/lib/knot_tool.py" debug-arguments)"
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -e Mach-O >/dev/null || continue
        KNOT_SCAN_COUNT=$((KNOT_SCAN_COUNT + 1))
        if held="$(knot_fakes_in "$f")" || held="$(knot_debug_arguments_in "$f" "$list")"; then
            KNOT_SCAN_FILE="${f#"$(dirname "$app")"/}"
            KNOT_SCAN_HELD="$held"
            return 1
        fi
    done < <(find "$app" -type f -print0)
    ((KNOT_SCAN_COUNT > 0)) || return 2
}
