#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?Set VERSION.}"
APPLE_ID="${APPLE_ID:?Set APPLE_ID.}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID.}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD.}"
SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY.}"

DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/Bigroute.app"
ZIP_PATH="$DIST_DIR/Bigroute-$VERSION.zip"
DMG_PATH="$DIST_DIR/Bigroute-$VERSION.dmg"

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "Notarized releases require a Developer ID Application identity." >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" || ! -s "$ZIP_PATH" || ! -s "$DMG_PATH" ]]; then
  echo "Signed release candidates are missing; run scripts/build_release.sh first." >&2
  exit 1
fi

notary_args=(
  --apple-id "$APPLE_ID"
  --team-id "$APPLE_TEAM_ID"
  --password "$APPLE_APP_PASSWORD"
  --wait
)

# Notarize the ZIP first so the app can be stapled before both final archives are rebuilt.
xcrun notarytool submit "$ZIP_PATH" "${notary_args[@]}"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

dmg_stage="$(mktemp -d)"
ditto "$APP_PATH" "$dmg_stage/Bigroute.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create \
  -volname "Bigroute" \
  -srcfolder "$dmg_stage" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" "${notary_args[@]}"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "Notarized and stapled $APP_PATH and $DMG_PATH"
