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
ZIP_NAME="$APP_NAME-$VERSION-$BUILD-macOS.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"

echo "$DIST_DIR/$ZIP_NAME"
