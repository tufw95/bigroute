#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT_DIR/dist/Bigroute.app}"
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
python3 - "$APPCAST_PATH" "$ZIP_PATH" "$APP_PATH/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys, urllib.parse, xml.etree.ElementTree as ET, zipfile
feed, archive, app = map(pathlib.Path, sys.argv[1:])
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(feed).getroot().findall('./channel/item')
if len(items) != 1:
    sys.exit('Expected exactly one update in the channel feed.')
item = items[0]
with zipfile.ZipFile(archive) as zipped:
    info = plistlib.loads(zipped.read('Bigroute.app/Contents/Info.plist'))
built = plistlib.loads(app.read_bytes())
for key in ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'SUPublicEDKey', 'SUFeedURL'):
    if not info.get(key) or info[key] != built.get(key):
        sys.exit(f'The update ZIP and built app disagree on {key}.')
for tag, key in [('version', 'CFBundleVersion'), ('shortVersionString', 'CFBundleShortVersionString')]:
    if item.findtext(f'sparkle:{tag}', namespaces=ns) != info[key]:
        sys.exit(f'The appcast does not match the update ZIP: {tag}.')
enclosure = item.find('enclosure')
url = urllib.parse.urlparse(enclosure.get('url', '') if enclosure is not None else '')
if url.scheme != 'https' or pathlib.PurePosixPath(url.path).name != archive.name:
    sys.exit('The appcast does not reference the expected HTTPS update archive.')
PY
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

echo "Verified Sparkle signatures and matching feed, archive, and app metadata."
