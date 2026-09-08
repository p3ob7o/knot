#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="/private/tmp/knot-verify-debug/Build/Products/Debug/Knot.app"
JSON_OUTPUT=""
SCREENSHOT_OUTPUT=""
if [[ $# -gt 0 && "$1" != --* ]]; then
    APP_PATH="$1"
    shift
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json-output) JSON_OUTPUT="${2:-}"; shift 2 ;;
        --screenshot-output) SCREENSHOT_OUTPUT="${2:-}"; shift 2 ;;
        *) echo "usage: $0 [APP] [--json-output FILE] [--screenshot-output FILE]" >&2; exit 64 ;;
    esac
done
EXECUTABLE="$APP_PATH/Contents/MacOS/Knot"
TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
RESULT="${TMPDIR:-/tmp}/knot-rich-runtime-probe-${TOKEN}.json"
SCREENSHOT="${TMPDIR:-/tmp}/knot-rich-runtime-probe-${TOKEN}.png"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: runtime probe app is missing: $EXECUTABLE" >&2
    exit 66
fi

rm -f "$RESULT" "$SCREENSHOT"
KNOT_RUNTIME_PROBE_TOKEN="$TOKEN" "$EXECUTABLE" >/dev/null 2>&1 &
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

if [[ ! -f "$RESULT" ]]; then
    echo "error: production WKWebView runtime probe did not produce a result." >&2
    exit 70
fi

node - "$RESULT" "$TOKEN" <<'NODE'
const fs = require("node:fs");
const [path, token] = process.argv.slice(2);
const result = JSON.parse(fs.readFileSync(path, "utf8"));
const valid = result.version === 1 &&
  result.token === token &&
  result.mode === "rich" &&
  result.ok === true &&
  result.bridgeReady === true &&
  result.blockCount > 0 &&
  result.visibleBlockCount > 0 &&
  result.textLength > 100000 &&
  result.resourceCount > 0 &&
  result.externalResourceCount === 0 &&
  result.readyMilliseconds > 0 &&
  result.screenshotBytes > 1000;
if (!valid) {
  console.error("error: production WKWebView runtime probe failed:", result);
  process.exit(1);
}
console.log(`PASS WK runtime: ${result.visibleBlockCount} visible block(s), ${result.textLength} characters, ${result.resourceCount} local resources, ${result.readyMilliseconds.toFixed(1)} ms`);
NODE

if [[ ! -s "$SCREENSHOT" ]]; then
    echo "error: production WKWebView runtime probe did not produce a screenshot." >&2
    exit 70
fi
if [[ -n "$JSON_OUTPUT" ]]; then
    cp "$RESULT" "$JSON_OUTPUT"
fi
if [[ -n "$SCREENSHOT_OUTPUT" ]]; then
    cp "$SCREENSHOT" "$SCREENSHOT_OUTPUT"
fi
rm -f "$RESULT" "$SCREENSHOT"
