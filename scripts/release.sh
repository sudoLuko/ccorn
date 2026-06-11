#!/bin/bash
# Builds, signs, notarizes, staples, and packages the CCorn release artifact.
#
# Credentials come from the environment and the keychain — NEVER from the repo:
#   CCORN_SIGN_IDENTITY   Developer ID Application identity, e.g.
#                         "Developer ID Application: Jane Doe (TEAM123456)"
#   CCORN_NOTARY_PROFILE  notarytool keychain profile name (one-time setup:
#                         see RELEASING.md)
#
# Output: dist/CCorn-v<version>.zip — a stapled, notarized app ready for a
# GitHub release — plus dist/CCorn.app for local validation.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CCORN_SIGN_IDENTITY:?set CCORN_SIGN_IDENTITY to your Developer ID Application identity}"
: "${CCORN_NOTARY_PROFILE:?set CCORN_NOTARY_PROFILE to your notarytool keychain profile name}"

VERSION=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\(.*\)".*/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "[release] could not read MARKETING_VERSION from project.yml" >&2; exit 1; }
APP=build-release/Build/Products/Release/CCorn.app
DIST=dist
ZIP="$DIST/CCorn-v$VERSION.zip"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "[release] v$VERSION — generating project and building Release"
xcodegen generate > /dev/null
xcodebuild -project CCorn.xcodeproj -scheme CCorn -configuration Release \
    -derivedDataPath ./build-release build 2>&1 | grep -E "^\*\*" || true
[[ -d "$APP" ]] || { echo "[release] no Release app produced" >&2; exit 1; }

echo "[release] signing with Developer ID (hardened runtime + timestamp)"
codesign --force --options runtime --timestamp \
    --entitlements Sources/CCorn.entitlements \
    --sign "$CCORN_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "[release] submitting for notarization (waits for Apple's verdict)"
ditto -c -k --keepParent "$APP" "$DIST/notarize-upload.zip"
SUBMIT_LOG=$(xcrun notarytool submit "$DIST/notarize-upload.zip" \
    --keychain-profile "$CCORN_NOTARY_PROFILE" --wait 2>&1 | tee /dev/stderr)
rm -f "$DIST/notarize-upload.zip"
grep -q "status: Accepted" <<<"$SUBMIT_LOG" || {
    echo "[release] notarization was not accepted; fetch the log with:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $CCORN_NOTARY_PROFILE" >&2
    exit 1
}

echo "[release] stapling the notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "[release] packaging"
ditto "$APP" "$DIST/CCorn.app"
ditto -c -k --keepParent "$DIST/CCorn.app" "$ZIP"

echo "[release] validating the artifact (gatecheck)"
scripts/preflight/release-gatecheck.sh "$DIST/CCorn.app"

echo "[release] done: $ZIP"
