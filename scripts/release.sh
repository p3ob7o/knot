#!/usr/bin/env bash
# release.sh — build, sign, notarize, and package Knot-macOS into a DMG.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate at
#      https://developer.apple.com/account/resources/certificates
#      Download the .cer and double-click to install it in your login keychain.
#   2. Generate an app-specific password at https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords) and store it for
#      notarytool — the keychain profile name defaults to AC_PASSWORD:
#        xcrun notarytool store-credentials AC_PASSWORD \
#          --apple-id YOU@EXAMPLE.COM --team-id MPZ3RJ4REN \
#          --password YOUR_APP_SPECIFIC_PASSWORD
#   3. Install create-dmg:
#        brew install create-dmg
#
# Usage:
#   ./scripts/release.sh                # uses MARKETING_VERSION from project.yml
#   ./scripts/release.sh 0.1.0          # explicit version override
#
# Override the keychain profile name with KEYCHAIN_PROFILE if you used
# something other than AC_PASSWORD in step 2.
#
# Output: build/release/Knot-<version>.dmg, signed and notarized.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ---- Config ----
SCHEME="Knot-macOS"
PRODUCT_NAME="Knot"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-AC_PASSWORD}"
BUILD_DIR="build/release"
ARCHIVE_PATH="$BUILD_DIR/${PRODUCT_NAME}.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
LOG_DIR="$BUILD_DIR/logs"

# ---- Version ----
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    VERSION=$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml)
fi
if [[ -z "$VERSION" ]]; then
    echo "error: could not read MARKETING_VERSION from project.yml; pass version as first arg." >&2
    exit 64
fi

APP_PATH="$EXPORT_PATH/${PRODUCT_NAME}.app"
DMG_PATH="$BUILD_DIR/${PRODUCT_NAME}-${VERSION}.dmg"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

echo "==> Releasing ${PRODUCT_NAME} ${VERSION}"

# ---- Tool checks ----
need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: '$1' not found in PATH." >&2
        [[ -n "${2:-}" ]] && echo "       $2" >&2
        exit 70
    fi
}
need xcodebuild
need xcrun
need codesign
need create-dmg "Install with: brew install create-dmg"
need xcodegen "Run ./bootstrap.sh once to install"

# ---- Find Developer ID Application certificate ----
IDENTITY_LINE=$(security find-identity -p codesigning -v 2>/dev/null \
    | grep "Developer ID Application" \
    | head -1 || true)
if [[ -z "$IDENTITY_LINE" ]]; then
    echo "error: no 'Developer ID Application' certificate found in your keychain." >&2
    echo "       Create one at https://developer.apple.com/account/resources/certificates" >&2
    echo "       (the 'Apple Development' cert is for local testing only — it can't notarize)." >&2
    exit 71
fi
IDENTITY=$(echo "$IDENTITY_LINE" | sed -nE 's/.*"(.+)"/\1/p')
TEAM_ID=$(echo "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\).*/\1/p')
echo "==> Signing identity: $IDENTITY"
echo "==> Team ID: $TEAM_ID"

# ---- Notarization profile check ----
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool keychain profile '$KEYCHAIN_PROFILE' not configured." >&2
    echo "       Set up with:" >&2
    echo "         xcrun notarytool store-credentials $KEYCHAIN_PROFILE \\" >&2
    echo "           --apple-id YOU@EXAMPLE.COM --team-id $TEAM_ID \\" >&2
    echo "           --password APP_SPECIFIC_PASSWORD" >&2
    exit 72
fi

# ---- Regenerate Xcode project so any project.yml changes flow through ----
echo "==> Regenerating Knot.xcodeproj from project.yml"
xcodegen generate >/dev/null

# ---- Clean output ----
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_PATH" "$LOG_DIR"

# ---- Archive ----
# We override the project's CODE_SIGN_STYLE to Manual at the command line so
# Xcode signs the archive directly with the Developer ID Application cert
# (the project keeps Automatic signing so day-to-day Xcode builds still work).
# An empty PROVISIONING_PROFILE_SPECIFIER tells Xcode "no profile needed",
# which is correct for a sandboxed Mac app distributed via Developer ID
# whose entitlements don't require one (sandbox + user-selected files +
# bookmarks all qualify).
echo "==> Archiving (a few minutes; full log: $LOG_DIR/archive.log)"
if ! xcodebuild archive \
        -project Knot.xcodeproj \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        > "$LOG_DIR/archive.log" 2>&1; then
    echo "error: archive failed. Tail of log:" >&2
    tail -40 "$LOG_DIR/archive.log" >&2
    exit 73
fi

# ---- ExportOptions.plist (signingStyle=manual matches the Manual archive) ----
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
EOF

# ---- Export the signed .app ----
echo "==> Exporting signed .app (full log: $LOG_DIR/export.log)"
if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        > "$LOG_DIR/export.log" 2>&1; then
    echo "error: export failed. Tail of log:" >&2
    tail -40 "$LOG_DIR/export.log" >&2
    exit 74
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: export did not produce $APP_PATH" >&2
    exit 75
fi

# ---- Verify app signature ----
echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 \
    | grep -E "valid on disk|satisfies its Designated Requirement" || true
codesign --display --verbose=2 "$APP_PATH" 2>&1 \
    | grep -E "Authority|TeamIdentifier|Identifier"

# ---- Build the DMG ----
echo "==> Building DMG"
rm -f "$DMG_PATH"
create-dmg \
    --volname "${PRODUCT_NAME} ${VERSION}" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "${PRODUCT_NAME}.app" 130 200 \
    --app-drop-link 410 200 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH" \
    > "$LOG_DIR/create-dmg.log" 2>&1

# ---- Sign the DMG ----
echo "==> Signing DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

# ---- Notarize ----
echo "==> Submitting DMG for notarization (typically 2–10 minutes)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# ---- Staple ----
echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# ---- Final assessment ----
echo "==> Gatekeeper assessment"
if spctl --assess --type install --verbose=2 "$DMG_PATH" 2>&1; then
    echo "(passed)"
else
    echo "(spctl assessment failed — the stapler validate above is the authoritative check.)"
fi

echo
echo "Done. Signed, notarized, stapled DMG:"
echo "    $DMG_PATH"
echo
echo "Next: gh release create v${VERSION} --generate-notes --title \"v${VERSION}\" \"$DMG_PATH\""
