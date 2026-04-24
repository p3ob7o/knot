#!/usr/bin/env bash
# Bootstrap script for Knot — installs XcodeGen if missing, then generates
# the Xcode project from project.yml.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "error: Homebrew is required to install XcodeGen automatically." >&2
        echo "       Install Homebrew (https://brew.sh/) or install XcodeGen manually:" >&2
        echo "         https://github.com/yonaskolb/XcodeGen#installing" >&2
        exit 1
    fi
    echo "==> Installing XcodeGen via Homebrew"
    brew install xcodegen
fi

echo "==> Generating Knot.xcodeproj"
xcodegen generate

echo
echo "Done. Open Knot.xcodeproj in Xcode and build the Knot-macOS or Knot-iOS scheme."
