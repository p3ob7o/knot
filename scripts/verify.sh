#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
QUICK=0

if [[ "${1:-}" == "--quick" ]]; then
    QUICK=1
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--quick]" >&2
    exit 64
fi

stage() { printf '\n==> %s\n' "$1"; }

cd "$ROOT"
stage "toolchain"
test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"
xcodebuild -version
node --version
npm --version
xcodegen --version

stage "handoff structure"
node rewrite-evidence/validate-handoff.mjs

stage "dependency integrity and licenses"
node scripts/dependency-report.mjs --json /private/tmp/knot-dependencies.json --notices /private/tmp/knot-third-party-notices.md
cmp THIRD_PARTY_NOTICES.md /private/tmp/knot-third-party-notices.md
(cd Knot/macOS/GutenbergWeb && npm audit --omit=dev --audit-level=high --offline --json > /private/tmp/knot-npm-audit-offline.json)

stage "web"
scripts/build-web.sh
node scripts/dependency-security.mjs /private/tmp/knot-dependencies.json
if [[ $QUICK -eq 0 ]]; then
    (cd Knot/macOS/GutenbergWeb && npm run test:integration)
fi

stage "KnotKit"
swift test --package-path Packages/KnotKit --scratch-path /private/tmp/knot-verify-swift
if [[ $QUICK -eq 0 ]]; then
    stage "two-process vault publication"
    scripts/two-process-vault-test.sh
fi

stage "XcodeGen"
xcodegen generate

stage "macOS Debug"
xcodebuild -project Knot.xcodeproj -scheme Knot-macOS -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/knot-verify-debug CODE_SIGNING_ALLOWED=NO build

stage "production WKWebView runtime"
scripts/wk-runtime-probe.sh /private/tmp/knot-verify-debug/Build/Products/Debug/Knot.app
scripts/native-surface-probe.sh /private/tmp/knot-verify-debug/Build/Products/Debug/Knot.app
PROJECT_VERSION=$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml)
BINARY_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /private/tmp/knot-verify-debug/Build/Products/Debug/Knot.app/Contents/Info.plist)
[[ "$PROJECT_VERSION" == "$BINARY_VERSION" ]]

if [[ $QUICK -eq 0 ]]; then
    stage "macOS tests"
    xcodebuild -project Knot.xcodeproj -scheme Knot-macOS -destination 'platform=macOS' -derivedDataPath /private/tmp/knot-verify-tests CODE_SIGNING_ALLOWED=NO test

    stage "macOS Release"
    xcodebuild -project Knot.xcodeproj -scheme Knot-macOS -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/knot-verify-release CODE_SIGNING_ALLOWED=NO build

    stage "iOS compatibility"
    xcodebuild -project Knot.xcodeproj -scheme Knot-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/knot-verify-ios CODE_SIGNING_ALLOWED=NO build
fi

echo "PASS verify"
