#!/bin/bash
# Build Pebble.app.
#
# Defaults suit local development: a native-arch app with an ad-hoc signature.
# CI overrides these through the environment to produce a signed, notarisable
# universal build:
#
#   VERSION        inject into Info.plist (CFBundleShortVersionString/CFBundleVersion)
#   ARCHS          space-separated targets, e.g. "arm64 x86_64"; >1 => universal
#   SIGN_IDENTITY  codesign identity; '-' (default) => ad-hoc
#   ENTITLEMENTS   optional path to an entitlements plist
#   MIN_MACOS      deployment target (default 14.0)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pebble"
BUNDLE_ID="local.pebble.Pebble"
ROOT="$PWD"
APP="$ROOT/build/$APP_NAME.app"

VERSION="${VERSION:-}"
ARCHS="${ARCHS:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
MIN_MACOS="${MIN_MACOS:-14.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/ModuleCache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

# Compile one slice per arch, then lipo them into a universal binary if needed.
SLICES=()
for ARCH in $ARCHS; do
  SLICE_DIR="$ROOT/build/.slice-$ARCH"
  rm -rf "$SLICE_DIR"; mkdir -p "$SLICE_DIR"
  echo "Compiling $ARCH ..."
  xcrun swiftc -swift-version 5 -O -sdk "$SDK_PATH" -target "$ARCH-apple-macos$MIN_MACOS" \
    -module-cache-path "$ROOT/build/ModuleCache" -module-name "$APP_NAME" \
    Sources/$APP_NAME/*.swift -o "$SLICE_DIR/$APP_NAME"
  SLICES+=("$SLICE_DIR/$APP_NAME")
done

if [ "${#SLICES[@]}" -eq 1 ]; then
  cp "${SLICES[0]}" "$APP/Contents/MacOS/$APP_NAME"
else
  xcrun lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
fi
rm -rf "$ROOT"/build/.slice-*

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp Resources/Brand/pebble-status-template.png "$APP/Contents/Resources/PebbleStatusTemplate.png"

# A real identity signs under the hardened runtime with a secure timestamp,
# which notarisation requires; ad-hoc signing supports neither.
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID")
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
if [ -n "$ENTITLEMENTS" ]; then
  SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Built: $APP"
[ -n "$VERSION" ] && echo "Version: $VERSION"
echo "Archs: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "Signed as: $SIGN_IDENTITY"

