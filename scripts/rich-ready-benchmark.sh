#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH=""
OUTPUT="/private/tmp/knot-rich-ready-results.json"
RUNS=30
CACHE="cold"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="${2:-}"; shift 2 ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --runs) RUNS="${2:-}"; shift 2 ;;
        --cache) CACHE="${2:-}"; shift 2 ;;
        *) echo "usage: $0 --app APP [--output FILE] [--runs N>=30] [--cache warm|cold]" >&2; exit 64 ;;
    esac
done

if [[ -z "$APP_PATH" || ! "$RUNS" =~ ^[0-9]+$ || "$RUNS" -lt 30 ]]; then
    echo "error: --app is required and --runs must be at least 30" >&2
    exit 64
fi
if [[ "$CACHE" != "warm" && "$CACHE" != "cold" ]]; then
    echo "error: --cache must be warm or cold" >&2
    exit 64
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/knot-rich-ready.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

for ((index = 0; index < RUNS; index += 1)); do
    "$ROOT/scripts/wk-runtime-probe.sh" "$APP_PATH" \
        --json-output "$SCRATCH/run-$index.json" >/dev/null
done

node - "$SCRATCH" "$OUTPUT" "$CACHE" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [directory, output, cache] = process.argv.slice(2);
const values = fs.readdirSync(directory)
  .filter((name) => name.endsWith(".json"))
  .map((name) => JSON.parse(fs.readFileSync(path.join(directory, name), "utf8")).readyMilliseconds)
  .sort((a, b) => a - b);
const percentile = (fraction) => values[Math.min(values.length - 1, Math.ceil(values.length * fraction) - 1)];
const median = percentile(0.5);
const p95 = percentile(0.95);
const budgetP95 = cache === "warm" ? 1000 : 2000;
const report = {
  schemaVersion: 1,
  cache,
  configuration: "Debug runtime probe with the production manifest and bridge",
  runs: values.length,
  median,
  p95,
  budgetP95,
  passed: p95 <= budgetP95,
};
fs.writeFileSync(output, JSON.stringify(report, null, 2) + "\n");
console.log(`rich-ready-${cache}\t${median.toFixed(3)} ms median\t${p95.toFixed(3)} ms p95\t${report.passed ? "PASS" : "FAIL"}`);
if (!report.passed) process.exit(1);
NODE
