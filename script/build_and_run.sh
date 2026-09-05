#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/Bigroute.xcodeproj"
DERIVED="$ROOT_DIR/.build/BigrouteDerived"
APP="$DERIVED/Build/Products/Debug/Bigroute.app"
MODE="${1:-run}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodebuild \
  -project "$PROJECT" \
  -scheme Bigroute \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

# Local builds are intentionally ad-hoc. Release builds are signed and
# notarized by the GitHub Actions release workflow.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

codesign --force --sign - --timestamp=none \
  "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - --timestamp=none \
  "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - --timestamp=none \
  "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign - --timestamp=none \
  "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign - --timestamp=none "$SPARKLE"
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$ROOT_DIR/Config/Bigroute/Bigroute.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

# Keep development builds in DerivedData. Overwriting the signed office app
# with an ad-hoc build changes its Keychain identity on every compilation.
case "$MODE" in
  run)
    /usr/bin/open -n "$APP"
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP"
    sleep 1
    pgrep -x Bigroute >/dev/null
    ;;
  --debug|debug)
    lldb -- "$APP/Contents/MacOS/Bigroute"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "Bigroute"'
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.routerquota.app"'
    ;;
  *)
    echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac
