#!/usr/bin/env bash
set -euo pipefail

# The Git ref update is atomic. Existing clients still receive the legacy
# release asset; 1.6.0+ uses the signed feed on the dedicated branch.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="${REPOSITORY:?Set REPOSITORY.}"
CHANNEL="${CHANNEL:?Set CHANNEL to office or stable.}"
VERSION="${VERSION:?Set VERSION.}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/dist/appcast.xml}"
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$CHANNEL" =~ ^(office|stable)$ ]]; then
  echo "Invalid repository or update channel." >&2
  exit 1
fi

gh auth setup-git
feed_checkout="$(mktemp -d)"
trap 'rm -rf "$feed_checkout"' EXIT
git -C "$feed_checkout" init -q
git -C "$feed_checkout" remote add origin "https://github.com/$REPOSITORY.git"
if [[ -n "$(git ls-remote --heads "https://github.com/$REPOSITORY.git" refs/heads/ota-feeds)" ]]; then
  git -C "$feed_checkout" fetch --quiet --depth 1 origin refs/heads/ota-feeds
  git -C "$feed_checkout" checkout --quiet -b ota-feeds FETCH_HEAD
else
  git -C "$feed_checkout" checkout --quiet --orphan ota-feeds
fi

python3 - "$APPCAST_PATH" "$feed_checkout/$CHANNEL/appcast.xml" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
new, old = map(pathlib.Path, sys.argv[1:])
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
def version(path):
    root = ET.parse(path).getroot()
    return int(root.findtext('./channel/item/sparkle:version', namespaces=ns))
if old.exists() and version(new) < version(old):
    sys.exit('Refusing to roll the OTA feed back to an older build.')
if old.exists() and version(new) == version(old) and new.read_bytes() != old.read_bytes():
    sys.exit('This build already has a different published feed. Published updates are immutable.')
PY

mkdir -p "$feed_checkout/$CHANNEL"
cp "$APPCAST_PATH" "$feed_checkout/$CHANNEL/appcast.xml"
git -C "$feed_checkout" add "$CHANNEL/appcast.xml"
if ! git -C "$feed_checkout" diff --cached --quiet; then
  git -C "$feed_checkout" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit --quiet -m "Publish $CHANNEL $VERSION update feed"
  git -C "$feed_checkout" push origin HEAD:refs/heads/ota-feeds
fi

# Keep the old channel alive for releases whose SUFeedURL predates 1.6.0.
channel_tag="$CHANNEL-channel"
if ! gh release view "$channel_tag" --repo "$REPOSITORY" >/dev/null 2>&1; then
  gh release create "$channel_tag" --repo "$REPOSITORY" --prerelease \
    --title "Bigroute $CHANNEL Update Channel" --notes "Signed Sparkle compatibility feed."
fi
gh release upload "$channel_tag" "$APPCAST_PATH" --repo "$REPOSITORY" --clobber

# Verify actual downloadable bytes, including the legacy entry point. Every
# request has a new cache key because GitHub assets/raw feeds are CDN-backed.
for feed_url in \
  "https://raw.githubusercontent.com/$REPOSITORY/ota-feeds/$CHANNEL/appcast.xml" \
  "https://github.com/$REPOSITORY/releases/download/$channel_tag/appcast.xml"; do
  verified=false
  for attempt in 1 2 3 4 5; do
    if curl --fail --silent --show-error --location --max-time 20 \
      "$feed_url?check=$(uuidgen)" --output "$feed_checkout/downloaded.xml" \
      && cmp -s "$APPCAST_PATH" "$feed_checkout/downloaded.xml"; then
      verified=true
      break
    fi
    sleep 2
  done
  if [[ "$verified" != true ]]; then
    echo "The public $CHANNEL feed does not yet match the signed release: $feed_url" >&2
    exit 1
  fi
done
echo "Published and verified both $CHANNEL feed URLs for $VERSION."
