#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?Set VERSION to a stable semantic version such as 1.0.0.}"
BUILD_NUMBER="${BUILD_NUMBER:?Set BUILD_NUMBER to a positive integer.}"
SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY to a Developer ID Application identity.}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID.}"
APP_PROFILE="${APP_PROVISIONING_PROFILE_PATH:?Set APP_PROVISIONING_PROFILE_PATH.}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_BUNDLE_ID="com.routerquota.app"
APP_GROUP="group.com.routerquota.shared"
PROJECT="$ROOT_DIR/Bigroute.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/BigrouteReleaseDerivedData"
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
if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "SIGN_IDENTITY must be a Developer ID Application identity; ad-hoc releases are forbidden." >&2
  exit 1
fi
if [[ ! -s "$APP_PROFILE" ]]; then
  echo "Developer ID provisioning profile is required." >&2
  exit 1
fi

export DEVELOPER_DIR

profile_plist() {
  local profile="$1"
  local output="$2"
  security cms -D -i "$profile" > "$output"
  plutil -lint "$output" >/dev/null
}

validate_profile() {
  local profile="$1"
  local expected_bundle_id="$2"
  local label="$3"
  local decoded
  local application_identifier
  local team_identifier

  decoded="$(mktemp)"
  profile_plist "$profile" "$decoded"
  application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null || true)"
  team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded" 2>/dev/null || true)"

  if [[ "$team_identifier" != "$APPLE_TEAM_ID" ]]; then
    echo "$label profile belongs to team '$team_identifier', expected '$APPLE_TEAM_ID'." >&2
    exit 1
  fi
  if [[ "$application_identifier" != "$APPLE_TEAM_ID.$expected_bundle_id" ]]; then
    echo "$label profile is for '$application_identifier', expected '$APPLE_TEAM_ID.$expected_bundle_id'." >&2
    exit 1
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$decoded" \
    | grep -Fq "$APP_GROUP"; then
    echo "$label profile does not authorize App Group '$APP_GROUP'." >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$decoded" 2>/dev/null || true)" != "true" ]]; then
    echo "$label profile is not a Developer ID distribution profile (ProvisionsAllDevices is missing)." >&2
    exit 1
  fi
}

validate_profile "$APP_PROFILE" "$APP_BUNDLE_ID" "App"

identity_team="$(security find-certificate -c "$SIGN_IDENTITY" -p \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU[ =]*\([^,\/]*\).*/\1/p' \
  | tr -d ' ')"
if [[ -n "$identity_team" && "$identity_team" != "$APPLE_TEAM_ID" ]]; then
  echo "Developer ID certificate team '$identity_team' does not match APPLE_TEAM_ID '$APPLE_TEAM_ID'." >&2
  exit 1
fi

xcodebuild \
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
SPARKLE_FRAMEWORK="$DIST_APP/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "The release app does not contain Sparkle.framework; OTA releases require Sparkle 2.9.4." >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_INFO"
/usr/libexec/PlistBuddy \
  -c 'Set :SUFeedURL https://raw.githubusercontent.com/tufw95/bigroute/ota-feeds/stable/appcast.xml' \
  "$APP_INFO"

cp "$APP_PROFILE" "$DIST_APP/Contents/embedded.provisionprofile"

entitlements_dir="$(mktemp -d)"
app_entitlements="$entitlements_dir/Bigroute.entitlements"
cp "$ROOT_DIR/Config/Bigroute/Bigroute.entitlements" "$app_entitlements"

# Xcode normally injects these provisioning-backed identifiers into its
# generated .xcent files. This pipeline signs manually, so add them explicitly.
/usr/libexec/PlistBuddy \
  -c 'Delete :com.apple.application-identifier' \
  "$app_entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c 'Delete :com.apple.developer.team-identifier' \
  "$app_entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.application-identifier string $APPLE_TEAM_ID.$APP_BUNDLE_ID" \
  "$app_entitlements"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.developer.team-identifier string $APPLE_TEAM_ID" \
  "$app_entitlements"

# Xcode preserves ad-hoc signatures from Sparkle's binary target when the host
# build disables signing. Re-sign nested code from the inside out so every
# executable in the shipped bundle belongs to the release team.
sparkle_version="$SPARKLE_FRAMEWORK/Versions/B"
sparkle_nested=(
  "$sparkle_version/Autoupdate"
  "$sparkle_version/XPCServices/Downloader.xpc"
  "$sparkle_version/XPCServices/Installer.xpc"
  "$sparkle_version/Updater.app"
)
for nested_code in "${sparkle_nested[@]}"; do
  if [[ ! -e "$nested_code" ]]; then
    echo "Sparkle release component is missing: $nested_code" >&2
    exit 1
  fi
  codesign --force --options runtime --timestamp \
    --preserve-metadata=identifier,entitlements,requirements \
    --sign "$SIGN_IDENTITY" \
    "$nested_code"
done
codesign --force --options runtime --timestamp \
  --preserve-metadata=identifier,entitlements,requirements \
  --sign "$SIGN_IDENTITY" \
  "$SPARKLE_FRAMEWORK"

codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  --entitlements "$app_entitlements" \
  "$DIST_APP"

codesign --verify --deep --strict --verbose=2 "$DIST_APP"
lipo "$DIST_APP/Contents/MacOS/Bigroute" -verify_arch arm64
lipo "$DIST_APP/Contents/MacOS/Bigroute" -verify_arch x86_64

validate_signed_entitlements() {
  local bundle="$1"
  local expected_bundle_id="$2"
  local require_sandbox="$3"
  local signed_entitlements

  signed_entitlements="$(mktemp)"
  codesign -d --entitlements :- "$bundle" > "$signed_entitlements" 2>/dev/null
  plutil -lint "$signed_entitlements" >/dev/null
  test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$signed_entitlements")" \
    = "$APPLE_TEAM_ID.$expected_bundle_id"
  test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$signed_entitlements")" \
    = "$APPLE_TEAM_ID"
  /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$signed_entitlements" \
    | grep -Fq "$APP_GROUP"
  if [[ "$require_sandbox" == "1" ]]; then
    test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$signed_entitlements")" = "true"
  fi
}

validate_signed_entitlements "$DIST_APP" "$APP_BUNDLE_ID" 0

for signed_component in "${sparkle_nested[@]}" "$SPARKLE_FRAMEWORK" "$DIST_APP"; do
  component_team="$(codesign -dv --verbose=4 "$signed_component" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p' \
    | head -n 1)"
  if [[ "$component_team" != "$APPLE_TEAM_ID" ]]; then
    echo "Signed component '$signed_component' has TeamIdentifier '$component_team', expected '$APPLE_TEAM_ID'." >&2
    exit 1
  fi
done

actual_team="$(codesign -dv --verbose=4 "$DIST_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
if [[ "$actual_team" != "$APPLE_TEAM_ID" ]]; then
  echo "Signed app TeamIdentifier '$actual_team' does not match '$APPLE_TEAM_ID'." >&2
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$DIST_APP" "$ZIP_PATH"

dmg_stage="$(mktemp -d)"
trap 'rm -rf "$dmg_stage"' EXIT
ditto "$DIST_APP" "$dmg_stage/Bigroute.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create \
  -volname "Bigroute" \
  -srcfolder "$dmg_stage" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "Created signed release candidates:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
