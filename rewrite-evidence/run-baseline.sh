#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="${1:-$(dirname "$here")}"
baseline="3a4bb5b7ce11463323c13da9442de5e4fd29941f"
actual="$(git -C "$repo" rev-parse HEAD)"
if [ "$actual" != "$baseline" ]; then
    printf 'This harness characterizes baseline %s, not %s. Use a disposable checkout of the baseline.\n' "$baseline" "$actual" >&2
    exit 2
fi
if ! git -C "$repo" diff --quiet HEAD -- Packages/KnotKit/Sources/KnotKit; then
    printf 'Core sources differ from the baseline; refusing an ambiguous characterization.\n' >&2
    exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/knot-baseline.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -parse-as-library \
    "$repo"/Packages/KnotKit/Sources/KnotKit/*.swift \
    "$here/Characterization.swift" -o "$work/characterize"
"$work/characterize"
