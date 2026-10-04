#!/usr/bin/env bash
# Build, sign, notarize and staple a distributable DMG.
#
#   scripts/release.sh <version> [--skip-notarize] [--publish]
#
# One-time setup (your Apple ID, an app-specific password from appleid.apple.com, your team):
#   xcrun notarytool store-credentials overhead-notary \
#       --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific-password>
# Override the profile name with NOTARY_PROFILE=... ; --publish creates a GitHub release with gh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--skip-notarize] [--publish]}"; shift || true
SKIP_NOTARIZE=0; PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --publish) PUBLISH=1 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

APP_NAME="Overhead"
PROFILE="${NOTARY_PROFILE:-overhead-notary}"
# Fall back to the profile name used before the app was renamed.
if [ -z "${NOTARY_PROFILE:-}" ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
   && xcrun notarytool history --keychain-profile llmoverview-notary >/dev/null 2>&1; then
  PROFILE="llmoverview-notary"
fi
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
DIST="dist"; STAGE="$DIST/stage"
DMG="$DIST/Overhead-$VERSION.dmg"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
line=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application:' || true)
[ -n "$line" ] || { echo "No 'Developer ID Application' certificate in the keychain; notarization requires one."; exit 1; }
IDENTITY=$(echo "$line" | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p')
TEAM=$(echo "$line" | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p')
echo "==> Signing identity: $IDENTITY"

if [ "$SKIP_NOTARIZE" = 0 ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat <<MSG
No notarization credentials found under keychain profile '$PROFILE'. Store them once with:

  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id $TEAM --password <app-specific password>

(create the app-specific password at https://account.apple.com → Sign-In and Security). Or pass --skip-notarize.
MSG
  exit 1
fi

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER)"
xcodegen generate --quiet
rm -rf "$DIST"; mkdir -p "$STAGE"
xcodebuild -project Overhead.xcodeproj -scheme Overhead -configuration Release \
  -derivedDataPath build/DerivedData \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
BUILT="build/DerivedData/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "Build failed"; exit 1; }
ditto "$BUILT" "$STAGE/$APP_NAME.app"
codesign --verify --deep --strict --verbose=1 "$STAGE/$APP_NAME.app"

if [ "$SKIP_NOTARIZE" = 0 ]; then
  echo "==> Notarizing app"
  ditto -c -k --keepParent "$STAGE/$APP_NAME.app" "$DIST/app.zip"
  xcrun notarytool submit "$DIST/app.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$STAGE/$APP_NAME.app"
  rm "$DIST/app.zip"
fi

echo "==> Creating DMG"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARIZE" = 0 ]; then
  echo "==> Notarizing DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi
rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Done: $DMG"

if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null || { echo "gh not found: brew install gh"; exit 1; }
  gh release create "v$VERSION" "$DMG" "$DMG.sha256" --title "Overhead $VERSION" --generate-notes
fi
