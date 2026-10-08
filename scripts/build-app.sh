#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/build"
APP_PATH="$BUILD_ROOT/OpenDock.app"
APP_VERSION="${OPENDOCK_VERSION:-0.2.0}"
BUILD_NUMBER="${OPENDOCK_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${OPENDOCK_SIGN_IDENTITY:--}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "OPENDOCK_VERSION must be X.Y.Z and OPENDOCK_BUILD_NUMBER must be numeric." >&2
  exit 1
fi

cd "$PROJECT_ROOT"
if ! xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  echo "Full application packaging requires Xcode 16+ selected with xcode-select (App Intents metadata tool missing)." >&2
  exit 1
fi
mkdir -p "$BUILD_ROOT"
swift build -c release -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-list -Xswiftc -Xfrontend -Xswiftc "$PROJECT_ROOT/scripts/app-intents-protocols.json" -Xswiftc -emit-const-values-path -Xswiftc "$BUILD_ROOT/OpenDock-release.swiftconstvalues"
BIN_ROOT="$(swift build -c release --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_ROOT/OpenDock" "$APP_PATH/Contents/MacOS/OpenDock"
chmod +x "$APP_PATH/Contents/MacOS/OpenDock"

ICONSET_PATH="$BUILD_ROOT/OpenDock.iconset"
mkdir -p "$ICONSET_PATH"
swift "$PROJECT_ROOT/scripts/make-icon.swift" "$ICONSET_PATH"
iconutil -c icns "$ICONSET_PATH" -o "$APP_PATH/Contents/Resources/OpenDock.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleExecutable</key><string>OpenDock</string>
  <key>CFBundleIconFile</key><string>OpenDock</string>
  <key>CFBundleIdentifier</key><string>io.github.myh66.opendock</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>OpenDock</string>
  <key>CFBundleDisplayName</key><string>OpenDock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>OpenDockReleaseTag</key><string>${OPENDOCK_RELEASE_TAG:-v${APP_VERSION}-beta.1}</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsUsageDescription</key><string>OpenDock 仅在你连接日历组件后读取系统日历，显示近期日程。</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>OpenDock 仅在你连接日历组件后读取系统日历，显示近期日程。</string>
  <key>NSRemindersUsageDescription</key><string>OpenDock 仅在你连接提醒事项组件后读取并完成系统提醒事项。</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>OpenDock 仅在你连接提醒事项组件后读取并完成系统提醒事项。</string>
  <key>NSAppleEventsUsageDescription</key><string>OpenDock 在你连接音乐组件后使用自动化读取并控制 Apple Music 或 Spotify。</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>OpenDock 仅在你点击天气组件的当前位置后读取位置，用于获取当地天气。</string>
  <key>NSLocationUsageDescription</key><string>OpenDock 仅在你点击天气组件的当前位置后读取位置，用于获取当地天气。</string>
  <key>CFBundleURLTypes</key>
  <array><dict><key>CFBundleURLName</key><string>OpenDock profile</string><key>CFBundleURLSchemes</key><array><string>opendock</string></array></dict></array>
</dict>
</plist>
PLIST

plutil -lint "$APP_PATH/Contents/Info.plist"
"$PROJECT_ROOT/scripts/extract-app-intents.sh" "$APP_PATH/Contents/Resources"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_PATH"
  echo "Local ad hoc signature; this build is not notarized."
else
  codesign --force --options runtime --timestamp --entitlements "$PROJECT_ROOT/scripts/entitlements.plist" --sign "$SIGN_IDENTITY" "$APP_PATH"
  echo "Signed with the explicitly supplied identity; notarization is a separate step."
fi
codesign --verify --strict --verbose=2 "$APP_PATH"
echo "Built: $APP_PATH"
