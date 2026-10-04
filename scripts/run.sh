#!/usr/bin/env bash
# Regenerate the Xcode project, build a Release app, and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project Overhead.xcodeproj -scheme Overhead -configuration Release \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="build/DerivedData/Build/Products/Release/Overhead.app"
[ -d "$APP" ] && open "$APP"
