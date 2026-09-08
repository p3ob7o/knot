#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/private/tmp/knot-verify-debug/Build/Products/Debug/Knot.app"
OUTPUT_DIR="/private/tmp/knot-native-surface-evidence"

if [[ $# -gt 0 && "$1" != --* ]]; then
    APP_PATH="$1"
    shift
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        *) echo "usage: $0 [APP] [--output-dir DIRECTORY]" >&2; exit 64 ;;
    esac
done

EXECUTABLE="$APP_PATH/Contents/MacOS/Knot"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: runtime probe app is missing: $EXECUTABLE" >&2
    exit 66
fi
mkdir -p "$OUTPUT_DIR"

for MODE in onboarding quick; do
    TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    RESULT="${TMPDIR:-/tmp}/knot-${MODE}-runtime-probe-${TOKEN}.json"
    SCREENSHOT="${TMPDIR:-/tmp}/knot-${MODE}-runtime-probe-${TOKEN}.png"
    rm -f "$RESULT" "$SCREENSHOT"
    KNOT_RUNTIME_PROBE_TOKEN="$TOKEN" KNOT_RUNTIME_PROBE_MODE="$MODE" \
        "$EXECUTABLE" >/dev/null 2>&1 &
    PID=$!

    for _ in {1..200}; do
        if [[ -f "$RESULT" ]]; then
            break
        fi
        if ! kill -0 "$PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
    fi
    wait "$PID" 2>/dev/null || true

    if [[ ! -s "$RESULT" || ! -s "$SCREENSHOT" ]]; then
        echo "error: $MODE runtime surface did not produce evidence." >&2
        exit 70
    fi
    node - "$RESULT" "$TOKEN" "$MODE" <<'NODE'
const fs = require("node:fs");
const [path, token, mode] = process.argv.slice(2);
const result = JSON.parse(fs.readFileSync(path, "utf8"));
const minimum = mode === "onboarding"
  ? { width: 500, height: 600 }
  : { width: 400, height: 400 };
const valid = result.version === 1 && result.token === token &&
  result.mode === mode && result.ok === true &&
  result.width >= minimum.width && result.height >= minimum.height &&
  result.screenshotBytes > 1000;
if (!valid) {
  console.error(`error: ${mode} native surface probe failed:`, result);
  process.exit(1);
}
console.log(`PASS native ${mode}: ${result.width}x${result.height}, ${result.screenshotBytes} screenshot bytes`);
NODE
    cp "$RESULT" "$OUTPUT_DIR/${MODE}.json"
    cp "$SCREENSHOT" "$OUTPUT_DIR/${MODE}.png"
    rm -f "$RESULT" "$SCREENSHOT"
done
