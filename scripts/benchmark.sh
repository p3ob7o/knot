#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

if [[ "${1:-}" != "--fixtures" || -z "${2:-}" ]]; then
    echo "usage: $0 --fixtures DIRECTORY [--output FILE] [--runs N>=30] [--cache warm|cold]" >&2
    exit 64
fi

FIXTURES="$2"
shift 2
swift run --package-path "$ROOT/Packages/KnotKit" -c release KnotBenchmark \
    --fixtures "$FIXTURES" "$@"
