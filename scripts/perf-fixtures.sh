#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

if [[ "${1:-}" != "--output" || -z "${2:-}" || $# -ne 2 ]]; then
    echo "usage: $0 --output DIRECTORY" >&2
    exit 64
fi

xcrun swift "$ROOT/scripts/perf-fixtures.swift" "$2"
