#!/usr/bin/env bash
# Reproducibly build generated resources and generate the Xcode project.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required; install it explicitly before bootstrap." >&2
    exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "error: npm is required to build the bundled macOS block editor." >&2
    exit 1
fi

echo "==> Building bundled Gutenberg editor"
pushd Knot/macOS/GutenbergWeb >/dev/null
NPM_CACHE="${TMPDIR:-/tmp}/knot-npm-cache"
npm ci --cache "$NPM_CACHE" --prefer-offline
npm run typecheck
npm run build
popd >/dev/null

echo "==> Generating Knot.xcodeproj"
xcodegen generate

echo
echo "Done. Open Knot.xcodeproj in Xcode and build the Knot-macOS or Knot-iOS scheme."
