#!/usr/bin/env bash
# Build, sign, notarize, validate, and package an immutable Knot macOS release.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

SCHEME="Knot-macOS"
PRODUCT="Knot"
PROJECT_VERSION="$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml)"
BUILD_NUMBER="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/{print $2; exit}' project.yml)"
VERSION="${1:-$PROJECT_VERSION}"
TAG="v${VERSION}"
SOURCE_SHA="$(git rev-parse HEAD)"
IDENTITY="${SIGNING_IDENTITY:-}"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-AC_PASSWORD}"
BUILD_ROOT="$ROOT/build/release"
ARCHIVE="$BUILD_ROOT/${PRODUCT}.xcarchive"
EXPORT="$BUILD_ROOT/export"
STAGE="$BUILD_ROOT/stage"
LOGS="$BUILD_ROOT/logs"
DMG="$BUILD_ROOT/${PRODUCT}-${VERSION}.dmg"
EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions.plist"
PERF_ROOT=""

fail() {
    echo "error: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "required tool is missing: $1"
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be semantic x.y.z"
[[ "$VERSION" == "$PROJECT_VERSION" ]] || fail "requested version $VERSION does not match project.yml $PROJECT_VERSION"
[[ -n "$BUILD_NUMBER" ]] || fail "CURRENT_PROJECT_VERSION is missing"
[[ -z "$(git status --porcelain)" ]] || fail "release requires a clean source tree"
[[ "$(git describe --tags --exact-match HEAD 2>/dev/null)" == "$TAG" ]] || fail "HEAD must have the exact release tag $TAG"
[[ "$(git rev-list -n 1 "$TAG")" == "$SOURCE_SHA" ]] || fail "release tag does not resolve to HEAD"
[[ -n "$IDENTITY" ]] || fail "set SIGNING_IDENTITY to an exact Developer ID Application identity"
[[ -n "$TEAM_ID" ]] || fail "set DEVELOPMENT_TEAM to the signing team identifier"
[[ -f RELEASE_NOTES.md ]] || fail "RELEASE_NOTES.md is required"
[[ -f THIRD_PARTY_NOTICES.md ]] || fail "THIRD_PARTY_NOTICES.md is required"

for tool in xcodebuild xcrun xcodegen codesign create-dmg security spctl hdiutil shasum node; do
    need "$tool"
done
security find-identity -p codesigning -v | grep -Fq "$IDENTITY" || fail "signing identity is not present in the selected keychain"
xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null || fail "notary profile $KEYCHAIN_PROFILE is unavailable"

echo "==> Full release verification"
./scripts/verify.sh

echo "==> Preparing release workspace"
rm -rf "$BUILD_ROOT"
mkdir -p "$EXPORT" "$STAGE" "$LOGS"
node scripts/dependency-report.mjs \
    --json "$BUILD_ROOT/dependencies.json" \
    --notices "$BUILD_ROOT/THIRD_PARTY_NOTICES.generated.md"
cmp THIRD_PARTY_NOTICES.md "$BUILD_ROOT/THIRD_PARTY_NOTICES.generated.md" \
    || fail "THIRD_PARTY_NOTICES.md does not match the lockfiles"
xcodegen generate

echo "==> Running release performance gates"
PERF_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/knot-release-perf.XXXXXX")"
cleanup_perf() {
    if [[ -n "$PERF_ROOT" ]]; then
        rm -rf "$PERF_ROOT"
    fi
}
trap cleanup_perf EXIT
scripts/perf-fixtures.sh --output "$PERF_ROOT"
scripts/benchmark.sh \
    --fixtures "$PERF_ROOT" \
    --output "$BUILD_ROOT/performance.json" \
    --runs 30 \
    --cache warm
scripts/rich-ready-benchmark.sh \
    --app /private/tmp/knot-verify-debug/Build/Products/Debug/Knot.app \
    --output "$BUILD_ROOT/rich-ready-performance.json" \
    --runs 30 \
    --cache cold
cleanup_perf
PERF_ROOT=""
trap - EXIT

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>${TEAM_ID}</string>
<key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST

echo "==> Archiving universal macOS app"
xcodebuild archive \
    -project Knot.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER='' \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    > "$LOGS/archive.log" 2>&1

echo "==> Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    > "$LOGS/export.log" 2>&1
APP="$EXPORT/${PRODUCT}.app"
[[ -d "$APP" ]] || fail "archive export did not produce $APP"

verify_app() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$VERSION" ]] \
        || fail "binary marketing version mismatch"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$BUILD_NUMBER" ]] \
        || fail "binary build number mismatch"
    codesign --verify --deep --strict --verbose=4 "$app"
    [[ "$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')" == "$TEAM_ID" ]] \
        || fail "signed app team identifier mismatch"
}

echo "==> Verifying exported app"
verify_app "$APP"
cp -R "$APP" "$STAGE/"
cp LICENSE THIRD_PARTY_NOTICES.md RELEASE_NOTES.md "$STAGE/"

echo "==> Building and signing disk image"
create-dmg \
    --volname "${PRODUCT} ${VERSION}" \
    --window-size 600 420 \
    --icon-size 96 \
    --icon "${PRODUCT}.app" 150 220 \
    --app-drop-link 450 220 \
    --no-internet-enable \
    "$DMG" "$STAGE" \
    > "$LOGS/create-dmg.log" 2>&1
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=4 "$DMG"

echo "==> Notarizing disk image"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait --output-format json > "$LOGS/notary.json"
node - "$LOGS/notary.json" <<'NODE'
const fs = require("node:fs");
const result = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (result.status !== "Accepted") {
  console.error(result);
  process.exit(1);
}
NODE
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

echo "==> Verifying installed artifact"
MOUNT="$BUILD_ROOT/mount"
mkdir -p "$MOUNT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" > "$LOGS/hdiutil-attach.log"
cleanup_mount() {
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT
verify_app "$MOUNT/${PRODUCT}.app"
cmp LICENSE "$MOUNT/LICENSE"
cmp THIRD_PARTY_NOTICES.md "$MOUNT/THIRD_PARTY_NOTICES.md"
cmp RELEASE_NOTES.md "$MOUNT/RELEASE_NOTES.md"
hdiutil detach "$MOUNT" > "$LOGS/hdiutil-detach.log"
trap - EXIT

echo "==> Writing immutable release metadata"
shasum -a 256 "$DMG" > "$DMG.sha256"
node - "$BUILD_ROOT/release-metadata.json" "$VERSION" "$BUILD_NUMBER" "$SOURCE_SHA" "$DMG" <<'NODE'
const fs = require("node:fs");
const crypto = require("node:crypto");
const [output, version, build, sourceSHA, artifact] = process.argv.slice(2);
const bytes = fs.readFileSync(artifact);
fs.writeFileSync(output, JSON.stringify({
  schemaVersion: 1,
  version,
  build,
  sourceSHA,
  artifact: artifact.split("/").at(-1),
  artifactSHA256: crypto.createHash("sha256").update(bytes).digest("hex"),
}, null, 2) + "\n");
NODE
cp RELEASE_NOTES.md "$BUILD_ROOT/RELEASE_NOTES.md"
chmod 0444 "$DMG" "$DMG.sha256" "$BUILD_ROOT/release-metadata.json" \
    "$BUILD_ROOT/dependencies.json" "$BUILD_ROOT/RELEASE_NOTES.md" \
    "$BUILD_ROOT/performance.json" "$BUILD_ROOT/rich-ready-performance.json" \
    "$BUILD_ROOT/THIRD_PARTY_NOTICES.generated.md"

echo "PASS release: signed, notarized, stapled, Gatekeeper-assessed artifact"
echo "$DMG"
