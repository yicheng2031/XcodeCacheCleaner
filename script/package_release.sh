#!/usr/bin/env bash
set -euo pipefail

APP_NAME="XcodeCacheCleaner"
PROJECT="XcodeCacheCleaner.xcodeproj"
SCHEME="XcodeCacheCleaner"
CONFIGURATION="Release"
ARCH="$(uname -m)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$ROOT_DIR/.build/release-dmg"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"

cd "$ROOT_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
DMG_NAME="$APP_NAME-$VERSION-$BUILD-macOS.dmg"

rm -rf "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto --norsrc --noextattr "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME" >/dev/null

rm -rf "$STAGING_DIR"

echo "$DIST_DIR/$DMG_NAME"
