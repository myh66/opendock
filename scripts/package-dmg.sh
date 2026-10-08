#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/build/OpenDock.app"
DMG_PATH="$PROJECT_ROOT/build/OpenDock.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build the application first: ./scripts/build-app.sh" >&2
  exit 1
fi
codesign --verify --strict "$APP_PATH"
STAGING_PATH="$(mktemp -d "${TMPDIR:-/tmp}/opendock-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_PATH"' EXIT
ditto "$APP_PATH" "$STAGING_PATH/OpenDock.app"
ln -s /Applications "$STAGING_PATH/Applications"
hdiutil create -volname "OpenDock" -srcfolder "$STAGING_PATH" -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
echo "Packaged: $DMG_PATH"
echo "DMG packaging does not notarize the application."
