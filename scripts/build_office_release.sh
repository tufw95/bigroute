#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/verify_monitoring_only.sh"
VERSION="${VERSION:?Set VERSION to a stable semantic version such as 1.0.0.}"
BUILD_NUMBER="${BUILD_NUMBER:?Set BUILD_NUMBER to a positive integer.}"
OFFICE_SIGN_IDENTITY="${OFFICE_SIGN_IDENTITY:?Set OFFICE_SIGN_IDENTITY to the persistent office signing identity.}"
OFFICE_SIGNING_KEYCHAIN_PATH="${OFFICE_SIGNING_KEYCHAIN_PATH:-}"
OFFICE_SIGNING_CERT_SHA1="${OFFICE_SIGNING_CERT_SHA1:?Set OFFICE_SIGNING_CERT_SHA1.}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

PROJECT="$ROOT_DIR/Bigroute.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/BigrouteOfficeReleaseDerivedData"
BUILD_APP="$DERIVED_DATA/Build/Products/Release/Bigroute.app"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP="$DIST_DIR/Bigroute.app"
ZIP_PATH="$DIST_DIR/Bigroute-$VERSION.zip"
DMG_PATH="$DIST_DIR/Bigroute-$VERSION.dmg"

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "VERSION must be a stable semantic version such as 1.0.0." >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi
if [[ ! "$OFFICE_SIGNING_CERT_SHA1" =~ ^[A-Fa-f0-9]{40}$ ]]; then
  echo "OFFICE_SIGNING_CERT_SHA1 must be a 40-character SHA-1 certificate fingerprint." >&2
  exit 1
fi

export DEVELOPER_DIR

xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme Bigroute \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$BUILD_APP" ]]; then
  echo "Xcode did not produce $BUILD_APP." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
if [[ -e "$DIST_APP" ]]; then
  rm -R "$DIST_APP"
fi
rm -f "$ZIP_PATH" "$DMG_PATH"
ditto "$BUILD_APP" "$DIST_APP"

APP_INFO="$DIST_APP/Contents/Info.plist"
WIDGET="$DIST_APP/Contents/PlugIns/BigrouteWidget.appex"
WIDGET_INFO="$WIDGET/Contents/Info.plist"
SPARKLE="$DIST_APP/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$WIDGET" || ! -d "$SPARKLE" ]]; then
  echo "The office build must contain both WidgetKit and Sparkle." >&2
  exit 1
fi

for info_plist in "$APP_INFO" "$WIDGET_INFO"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$info_plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$info_plist"
done
/usr/libexec/PlistBuddy \
  -c 'Set :SUFeedURL https://github.com/tufw95/bigroute/releases/download/office-channel/appcast.xml' \
  "$APP_INFO"

# A persistent self-signed identity keeps Keychain ACLs stable across office
# updates without claiming Apple Developer ID trust or notarization. The
# certificate has no Apple Team ID, so the office build must not enable the
# hardened runtime: dyld library validation would reject embedded Sparkle.
codesign_args=(--force --verbose=2 --sign "$OFFICE_SIGN_IDENTITY" --timestamp=none)
if [[ -n "$OFFICE_SIGNING_KEYCHAIN_PATH" ]]; then
  codesign_args+=(--keychain "$OFFICE_SIGNING_KEYCHAIN_PATH")
  security find-identity -p codesigning "$OFFICE_SIGNING_KEYCHAIN_PATH"
fi
sparkle_version="$SPARKLE/Versions/B"
sparkle_nested=(
  "$sparkle_version/Autoupdate"
  "$sparkle_version/XPCServices/Downloader.xpc"
  "$sparkle_version/XPCServices/Installer.xpc"
  "$sparkle_version/Updater.app"
)
for nested_code in "${sparkle_nested[@]}"; do
  echo "Signing $nested_code"
  codesign "${codesign_args[@]}" \
    --preserve-metadata=identifier,entitlements,requirements \
    "$nested_code"
done
codesign "${codesign_args[@]}" \
  --preserve-metadata=identifier,entitlements,requirements \
  "$SPARKLE"
codesign "${codesign_args[@]}" --generate-entitlement-der \
  --entitlements "$ROOT_DIR/Config/Bigroute/BigrouteWidget.entitlements" \
  "$WIDGET"
codesign "${codesign_args[@]}" --generate-entitlement-der \
  --entitlements "$ROOT_DIR/Config/Bigroute/Bigroute.entitlements" \
  "$DIST_APP"

codesign --verify --deep --strict --verbose=2 "$DIST_APP"
for office_code in "${sparkle_nested[@]}" "$SPARKLE" "$WIDGET" "$DIST_APP"; do
  signing_details="$(codesign -dvv "$office_code" 2>&1)"
  if [[ "$signing_details" == *"flags="*"runtime"* ]]; then
    echo "$office_code unexpectedly carries a hardened runtime signature; office Sparkle builds must remain loadable with the self-signed certificate." >&2
    exit 1
  fi
done
lipo "$DIST_APP/Contents/MacOS/Bigroute" -verify_arch arm64
lipo "$DIST_APP/Contents/MacOS/Bigroute" -verify_arch x86_64
lipo "$WIDGET/Contents/MacOS/BigrouteWidget" -verify_arch arm64
lipo "$WIDGET/Contents/MacOS/BigrouteWidget" -verify_arch x86_64

expected_fingerprint="$(printf '%s' "$OFFICE_SIGNING_CERT_SHA1" | tr '[:upper:]' '[:lower:]')"
designated_requirement="$(codesign -d -r- "$DIST_APP" 2>&1 | sed -n 's/^designated => //p')"
if [[ "$designated_requirement" != *"certificate root = H\"$expected_fingerprint\""* ]]; then
  echo "The office app is not signed by the expected persistent certificate." >&2
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$DIST_APP" "$ZIP_PATH"
unzip -tq "$ZIP_PATH" >/dev/null

dmg_stage="$(mktemp -d)"
ditto "$DIST_APP" "$dmg_stage/Bigroute.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create \
  -volname "Bigroute" \
  -srcfolder "$dmg_stage" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null
codesign "${codesign_args[@]}" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null

echo "Created Sparkle-ready office release candidates:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
