# Bigroute

[![CI](https://github.com/tufw95/bigroute/actions/workflows/ci.yml/badge.svg)](https://github.com/tufw95/bigroute/actions/workflows/ci.yml)

A native macOS menu bar app for monitoring 9Router and OmniRouter account quotas. Requires macOS 14 or later, on Apple Silicon or Intel.

## Install and update

Download the DMG from the [latest release](https://github.com/tufw95/bigroute/releases/latest), then drag Bigroute into Applications. Existing installations can use **Check for Updates…**. Office builds use a persistent internal signing certificate and signed Sparkle updates; they are not Apple notarized. macOS may require **Privacy & Security → Open Anyway** on first installation.

The 1.6.0 source upgrade is being validated. **The phone Remote Control conversation-switching issue remains unresolved; 1.6.0 has not been released for team OTA.** See [audit findings and release gate](docs/audit-1.6.0.md).

## Providers and quotas

In Settings, add a name, provider type, HTTPS endpoint, and API key. HTTP is accepted only for loopback endpoints. Choose **9Router** explicitly to enable its manual account actions, JSON import, and Bridge. Auto-detect and OmniRouter support quota monitoring.

- Providers refresh concurrently every 1–60 minutes (default: 2). Manual refresh requests fresh server data.
- Quota percentages, reset times, authentication errors, account state, and expired plans come from provider responses. Missing measurements display as unavailable. Failed refreshes retain the last successful snapshot and its timestamp.
- Sort by quota, account name, or refresh time. Hide inactive accounts using the eye button.
- **Turn Off Empty** and **Turn On Available** are explicit user actions. Monitoring never changes account state in the background.
- **Import JSON…** accepts up to 100 selected ChatGPT credential files, including arrays and account wrappers. Files stay in memory and are submitted to the configured 9Router endpoint. Imported tokens are never saved by Bigroute.

API keys are stored in macOS Keychain. Quota snapshots contain display data only and are saved in the current user's Application Support directory. A locked or denied Keychain produces a retryable error; it does not erase saved providers. Sorting and Bridge setting changes do not rewrite unchanged keys.

WidgetKit was removed in 1.4.13. There is no widget extension to install or configure.

## Antigravity 9Router Bridge

The optional Bridge requires Node.js 20 or later and an enabled provider explicitly configured as 9Router. With multiple 9Router providers, the first enabled one supplies the endpoint and key.

The local listener binds to `127.0.0.1:50999`. It translates generation between Antigravity's Cloud Code format and 9Router's chat-completions format, including streamed text, images, reasoning, and function calls. Unsupported media and malformed upstream results produce errors rather than silently losing input. Non-generation traffic is forwarded to Google's upstream; custom model discovery retains other response fields.

**Compatibility is conditional.** The inspected official Antigravity 2.12.2 package hardcodes its Cloud Code endpoint. The installed modified package reads `~/.gemini/antigravity/cloud_code_endpoint.txt`. Bigroute manages that file and checks the endpoint used by the running language server; it does not modify Antigravity's signed application bundle. A future Antigravity update may remove endpoint support. Do not assume that a healthy local proxy proves that Antigravity is using it or that phone remote works.

Toggling Bridge or pressing **Apply & Restart Antigravity** requests a graceful Antigravity restart. Bigroute startup and OTA do not restart Antigravity. Turning Bridge off restores the previously saved endpoint, or removes the override so Antigravity can choose its default.

**Keep Official Models** retains the discovered catalogue and maps unprefixed model IDs to `ag/<model>`. **Custom Models** accepts provider-prefixed IDs. This mode depends on Antigravity's internal model schema; it is more sensitive to vendor changes. The Bridge's model availability values keep router routes selectable; they are not measured Google or 9Router account quotas. Use Bigroute's quota dashboard for actual provider measurements. Model capabilities and context limits depend on the chosen upstream model.

While enabled, the Node process needs a private on-disk copy of the selected API key at `~/.gemini/antigravity/bridge_config.json` (permissions `0600`). Disabling Bridge removes this copy. Logs are bounded and omit keys, headers, and conversation bodies.

For the reported **Lost connection to the remote instance** error, the next required check is the same phone navigation with Bridge enabled and disabled, followed by a clean official Antigravity installation if needed. See the audit for observed transport errors and the limits of the existing proxy tests.

## Development

Requires full Xcode, Swift 6, and Node.js 20+ for Bridge tests.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
node --test Tests/antigravity-bridge-proxy.test.mjs
python3 Tests/publish-channel.test.py
./scripts/verify_monitoring_only.sh
./script/build_and_run.sh
```

The development script launches from DerivedData. It does not replace the signed app in Applications. Avoid running development and installed copies together: they intentionally share compatibility identifiers. An ad-hoc build has a different signing identity and may require Keychain approval; use signed office releases for routine work.

## Office OTA release

After the release gate is satisfied, date the matching changelog entry, push the commit to `main`, and wait for CI. Push `office-v<version>` at that exact commit to run **Office Release**. The workflow builds a universal app, checks the pinned signing identity, verifies Sparkle signatures and archive metadata, and publishes the numbered release.

Protected `office-release` environment secrets:

- `OFFICE_SIGNING_CERTIFICATE_BASE64`: the existing password-protected office PKCS#12 certificate and key.
- `OFFICE_SIGNING_CERTIFICATE_PASSWORD`: its export password.
- `SPARKLE_EDDSA_PRIVATE_KEY_BASE64`: the private key matching the app's embedded Sparkle public key.

Numbered release archives are immutable. Rerunning an interrupted publication reuses their original signed bytes. The signed feed is committed to `ota-feeds/office/appcast.xml`; the Git ref update is atomic and rejects downgrades. The legacy `office-channel` release asset is also maintained for older clients. Publication verifies the downloadable bytes at both URLs.

New builds read the [office feed](https://raw.githubusercontent.com/tufw95/bigroute/ota-feeds/office/appcast.xml) and add a unique query to each check. The separate Developer ID workflow uses `ota-feeds/stable/appcast.xml`. A previously staged old update may still need to finish before an older client performs its next check; 1.6.0 cannot change code already installed on that client.

Keep the `com.routerquota.app` bundle ID, Keychain service, Sparkle key, and office signing certificate unchanged. Existing credential access depends on signing continuity. macOS can still request approval when migrating from an ad-hoc build or when Keychain permissions were changed.

## Optional Developer ID distribution

The `Release` workflow uses `v<version>` tags, a separate `release` environment, and Apple notarization. It additionally requires `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`, `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`, `MACOS_APP_PROVISIONING_PROFILE_BASE64`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`. The app profile must match the retained bundle ID and App Group. A widget profile is no longer used.

See [SECURITY.md](SECURITY.md) for credential boundaries and private vulnerability reporting.
