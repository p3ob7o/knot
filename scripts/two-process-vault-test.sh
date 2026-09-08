#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
PACKAGE="$ROOT/Packages/KnotKit"
SCRATCH="${TMPDIR:-/tmp}/knot-two-process-build"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/knot-two-process.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

swift build --package-path "$PACKAGE" --scratch-path "$SCRATCH" -c release --product KnotVaultWorker
BIN="$(swift build --package-path "$PACKAGE" --scratch-path "$SCRATCH" -c release --show-bin-path)"
WORKER="$BIN/KnotVaultWorker"
VAULT="$FIXTURE/Vault"
SUPPORT="$FIXTURE/Support"
PROFILE="11111111-1111-4111-8111-111111111111"
mkdir -p "$VAULT" "$SUPPORT"

"$WORKER" --initialize --vault "$VAULT" --support "$SUPPORT" --profile "$PROFILE"
"$WORKER" --vault "$VAULT" --support "$SUPPORT" --profile "$PROFILE" \
    --label A --start 0 --count 50 --output "$FIXTURE/a.json" &
PID_A=$!
"$WORKER" --vault "$VAULT" --support "$SUPPORT" --profile "$PROFILE" \
    --label B --start 50 --count 50 --output "$FIXTURE/b.json" &
PID_B=$!

STATUS=0
wait "$PID_A" || STATUS=$?
wait "$PID_B" || STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    echo "error: a two-process publisher exited with status $STATUS" >&2
    exit "$STATUS"
fi

node - "$FIXTURE" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const a = JSON.parse(fs.readFileSync(path.join(root, "a.json"), "utf8"));
const b = JSON.parse(fs.readFileSync(path.join(root, "b.json"), "utf8"));
const notePaths = [...a.notePaths, ...b.notePaths];
const assetPaths = [...a.assetPaths, ...b.assetPaths];
const expectedBodies = new Set(Array.from({ length: 100 }, (_, index) => `body-${String(index).padStart(3, "0")}`));
const actualBodies = new Set();

if (a.captures !== 50 || b.captures !== 50) throw new Error("worker count mismatch");
if (notePaths.length !== 100 || new Set(notePaths).size !== 100) throw new Error("note collision overwrote a capture");
if (assetPaths.length !== 100 || new Set(assetPaths).size !== 100) throw new Error("asset collision overwrote an image");
for (const relative of notePaths) {
  const markdown = fs.readFileSync(path.join(root, "Vault", relative), "utf8");
  const body = markdown.split("\n", 1)[0];
  actualBodies.add(body);
  if (markdown.includes("knot-asset://")) throw new Error("opaque asset token reached the vault");
  if (!markdown.includes("![fixture](")) throw new Error("image embed missing from note");
}
if (actualBodies.size !== expectedBodies.size || [...expectedBodies].some((value) => !actualBodies.has(value))) {
  throw new Error("one or more capture bodies did not survive");
}
for (const relative of assetPaths) {
  const bytes = fs.readFileSync(path.join(root, "Vault", relative));
  if (bytes.length < 60 || bytes[0] !== 0x89 || bytes[1] !== 0x50) throw new Error("published asset bytes are invalid");
}
console.log("PASS T03: 100 same-timestamp captures and 100 same-name assets survived two concurrent processes");
NODE
