#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Pebble.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/build/ModuleCache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -O -sdk "$SDK_PATH" -target "$ARCH-apple-macos14.0" \
  -module-cache-path "$PWD/build/ModuleCache" -module-name Pebble \
  Sources/Pebble/*.swift -o "$APP/Contents/MacOS/Pebble"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp Resources/Brand/pebble-status-template.png "$APP/Contents/Resources/PebbleStatusTemplate.png"
codesign --force --sign - --identifier local.pebble.Pebble "$APP"
printf 'Built: %s\n' "$APP"
