#!/usr/bin/env bash
# Build a signed Release app and install it into /Applications.
#
# Signing identity, in order of preference: "Developer ID Application", "Apple Development",
# or ad-hoc ("-") when no certificate is present. A real certificate gives the app a stable
# identity, so the Keychain keeps trusting it across rebuilds without re-prompting.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-/Applications}"
APP_NAME="Overhead"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }

identity="-"; team=""
for kind in "Developer ID Application" "Apple Development"; do
  line=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "\"$kind:" || true)
  if [ -n "$line" ]; then
    identity="$kind"
    team=$(echo "$line" | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p')
    break
  fi
done
echo "Signing with: $identity ${team:+(team $team)}"

xcodegen generate --quiet
xcodebuild -project Overhead.xcodeproj -scheme Overhead -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
  PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build 2>&1 | grep -E "error:|warning: .*sign|BUILD (SUCCEEDED|FAILED)" || true

BUILT="build/DerivedData/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "Build failed: $BUILT not found"; exit 1; }
codesign --verify --deep --strict "$BUILT" && echo "Signature OK: $(codesign -dvv "$BUILT" 2>&1 | grep -m1 -E "^Authority=")"

# Replace any running copy (and the app under its previous name), then install.
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -x "LLM Overview" 2>/dev/null || true
sleep 1
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app" "$DEST/LLM Overview.app"
ditto "$BUILT" "$DEST/$APP_NAME.app"
echo "Installed: $DEST/$APP_NAME.app"
open "$DEST/$APP_NAME.app"
