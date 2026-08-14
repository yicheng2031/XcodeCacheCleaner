#!/usr/bin/env bash
set -euo pipefail

APP_NAME="XcodeCacheCleaner"
PROJECT="XcodeCacheCleaner.xcodeproj"
SCHEME="XcodeCacheCleaner"
CONFIGURATION="Release"
DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-xcode-cache-cleaner-notary}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$ROOT_DIR/.build/release-dmg"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"

cd "$ROOT_DIR"

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "Developer ID Application"; then
  echo "Developer ID Application certificate not found in the current keychain." >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_IDENTITY" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  -quiet \
  clean \
  build

/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "$DEVELOPER_IDENTITY" \
  "$APP_BUNDLE"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
DMG_NAME="$APP_NAME-$VERSION-$BUILD-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

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
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"

/usr/bin/codesign \
  --force \
  --sign "$DEVELOPER_IDENTITY" \
  --timestamp \
  "$DMG_PATH"

/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  --verbose=2 \
  "$APP_BUNDLE"

/usr/bin/codesign \
  --verify \
  --verbose=2 \
  "$DMG_PATH"

NOTARY_DIR="$ROOT_DIR/.build/notarization"
NOTARY_RESPONSE="$NOTARY_DIR/$DMG_NAME.plist"
mkdir -p "$NOTARY_DIR"

if ! /usr/bin/xcrun notarytool submit \
  "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format plist > "$NOTARY_RESPONSE"; then
  /bin/cat "$NOTARY_RESPONSE" >&2 || true
  exit 1
fi

NOTARY_STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$NOTARY_RESPONSE")"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  echo "Apple notarization failed with status: $NOTARY_STATUS" >&2
  /bin/cat "$NOTARY_RESPONSE" >&2
  exit 1
fi

/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/bin/xcrun stapler validate "$DMG_PATH"

echo "$DMG_PATH"
