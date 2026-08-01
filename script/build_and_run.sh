#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/RouterQuota.xcodeproj"
DERIVED="$ROOT_DIR/.build/RouterQuotaDerived"
APP="$DERIVED/Build/Products/Debug/RouterQuota.app"
INSTALLED_APP="/Applications/Router Quota.app"
MODE="${1:-run}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

pkill -x RouterQuota 2>/dev/null || true

xcodebuild \
  -project "$PROJECT" \
  -scheme RouterQuota \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

# Local builds are intentionally ad-hoc. Release builds are signed and
# notarized by the GitHub Actions release workflow.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
WIDGET="$APP/Contents/PlugIns/RouterQuotaWidget.appex"

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
  --entitlements "$ROOT_DIR/Config/RouterQuota/RouterQuotaWidget.entitlements" "$WIDGET"
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$ROOT_DIR/Config/RouterQuota/RouterQuota.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

ditto "$APP" "$INSTALLED_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$INSTALLED_APP"
pluginkit -r "$APP/Contents/PlugIns/RouterQuotaWidget.appex" 2>/dev/null || true
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/RouterQuotaWidget.appex" 2>/dev/null || true
APP="$INSTALLED_APP"

case "$MODE" in
  run)
    /usr/bin/open -n "$APP"
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP"
    sleep 1
    pgrep -x RouterQuota >/dev/null
    ;;
  --debug|debug)
    lldb -- "$APP/Contents/MacOS/RouterQuota"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "RouterQuota"'
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
