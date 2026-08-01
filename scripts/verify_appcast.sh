#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT_DIR/dist/Router Quota.app}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/dist/appcast.xml}"
ZIP_PATH="${ZIP_PATH:?Set ZIP_PATH to the Sparkle update ZIP.}"
SPARKLE_SIGN_UPDATE_PATH="${SPARKLE_SIGN_UPDATE_PATH:?Set SPARKLE_SIGN_UPDATE_PATH.}"
SPARKLE_PRIVATE_KEY_PATH="${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH.}"

if [[ ! -d "$APP_PATH" || ! -s "$APPCAST_PATH" || ! -s "$ZIP_PATH" \
  || ! -x "$SPARKLE_SIGN_UPDATE_PATH" || ! -s "$SPARKLE_PRIVATE_KEY_PATH" ]]; then
  echo "The built app, appcast, update ZIP, Sparkle verifier, and private key are required." >&2
  exit 1
fi

public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PATH/Contents/Info.plist")"
feed_length="$(sed -n 's/^length: //p' "$APPCAST_PATH" | tail -1)"
enclosure_signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST_PATH" | head -1)"
enclosure_length="$(sed -n 's/.*<enclosure[^>]* length="\([0-9][0-9]*\)".*/\1/p' "$APPCAST_PATH" | head -1)"

if [[ -z "$public_key" || -z "$enclosure_signature" ]]; then
  echo "The appcast is missing its embedded public key or Ed25519 signatures." >&2
  exit 1
fi
if [[ ! "$feed_length" =~ ^[1-9][0-9]*$ || ! "$enclosure_length" =~ ^[1-9][0-9]*$ ]]; then
  echo "The appcast contains an invalid signed length." >&2
  exit 1
fi

zip_length="$(stat -f %z "$ZIP_PATH")"
if [[ "$zip_length" != "$enclosure_length" ]]; then
  echo "The appcast enclosure length does not match the update ZIP." >&2
  exit 1
fi
if (( feed_length >= $(stat -f %z "$APPCAST_PATH") )); then
  echo "The signed feed length does not leave room for the Sparkle signature block." >&2
  exit 1
fi

"$SPARKLE_SIGN_UPDATE_PATH" \
  --verify \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
  "$APPCAST_PATH"

"$SPARKLE_SIGN_UPDATE_PATH" \
  --verify \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
  "$ZIP_PATH" \
  "$enclosure_signature"

echo "Verified Sparkle feed and enclosure signatures with the key matching the built app."
