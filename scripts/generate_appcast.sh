#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?Set VERSION.}"
TAG="${TAG:?Set TAG, for example v1.0.0.}"
REPOSITORY="${REPOSITORY:?Set REPOSITORY, for example tufw95/router-quota.}"
SPARKLE_PRIVATE_KEY_PATH="${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH.}"

SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
DIST_DIR="$ROOT_DIR/dist"
ZIP_NAME="Router-Quota-$VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
APPCAST_PATH="$DIST_DIR/appcast.xml"

if [[ "$TAG" != "v$VERSION" && "$TAG" != "office-v$VERSION" ]]; then
  echo "TAG '$TAG' does not match VERSION '$VERSION'. Expected v$VERSION or office-v$VERSION." >&2
  exit 1
fi
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "REPOSITORY must use the owner/name form." >&2
  exit 1
fi
if [[ ! -s "$ZIP_PATH" || ! -s "$SPARKLE_PRIVATE_KEY_PATH" ]]; then
  echo "The update ZIP and Sparkle EdDSA private key are required." >&2
  exit 1
fi

tools_dir="$(mktemp -d)"
archives_dir="$(mktemp -d)"
sparkle_archive="$tools_dir/Sparkle-$SPARKLE_VERSION.tar.xz"

curl --fail --silent --show-error --location "$SPARKLE_URL" --output "$sparkle_archive"
actual_sha256="$(shasum -a 256 "$sparkle_archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$SPARKLE_SHA256" ]]; then
  echo "Sparkle tool archive checksum mismatch." >&2
  exit 1
fi
tar -xJf "$sparkle_archive" -C "$tools_dir"

cp "$ZIP_PATH" "$archives_dir/$ZIP_NAME"
notes_path="$archives_dir/Router-Quota-$VERSION.md"
generation_log="$tools_dir/generate-appcast.log"
awk -v heading="## [$VERSION]" '
  index($0, heading) == 1 { capture=1; next }
  capture && /^## \[/ { exit }
  capture && /^\[[^]]+\]: / { exit }
  capture { print }
' "$ROOT_DIR/CHANGELOG.md" > "$notes_path"

if ! "$tools_dir/bin/generate_appcast" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
  --full-release-notes-url "https://github.com/$REPOSITORY/releases/tag/$TAG" \
  --link "https://github.com/$REPOSITORY" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$APPCAST_PATH" \
  "$archives_dir" 2>&1 | tee "$generation_log"; then
  echo "Sparkle failed to generate the appcast." >&2
  exit 1
fi

if grep -Fq 'does not match key EdDSA' "$generation_log"; then
  echo "The Sparkle private key does not match SUPublicEDKey in the built app." >&2
  exit 1
fi

if ! grep -Eq '<enclosure[^>]+sparkle:edSignature=' "$APPCAST_PATH"; then
  echo "Generated appcast does not contain a signed update enclosure. Verify that the private key matches SUPublicEDKey." >&2
  exit 1
fi
if ! grep -q 'sparkle-signatures:' "$APPCAST_PATH"; then
  echo "Generated appcast feed is not signed." >&2
  exit 1
fi
if ! grep -q "$ZIP_NAME" "$APPCAST_PATH"; then
  echo "Generated appcast does not reference $ZIP_NAME." >&2
  exit 1
fi

SPARKLE_SIGN_UPDATE_PATH="$tools_dir/bin/sign_update" \
  SPARKLE_PRIVATE_KEY_PATH="$SPARKLE_PRIVATE_KEY_PATH" \
  ZIP_PATH="$ZIP_PATH" \
  "$ROOT_DIR/scripts/verify_appcast.sh"

echo "$APPCAST_PATH"
