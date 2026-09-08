#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/Knot/macOS/GutenbergWeb"
CACHE="${TMPDIR:-/tmp}/knot-npm-cache"

cd "$WEB"
npm ci --cache "$CACHE" --prefer-offline
npm run typecheck
npm run test:unit
npm run build

test -f dist/index.html
test -f dist/.vite/manifest.json
echo "PASS build-web: locked install, typecheck, unit tests, clean bundle"
