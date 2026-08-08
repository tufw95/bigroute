# Bigroute

[![CI](https://github.com/tufw95/bigroute/actions/workflows/ci.yml/badge.svg)](https://github.com/tufw95/bigroute/actions/workflows/ci.yml)
[![Office Release](https://github.com/tufw95/bigroute/actions/workflows/office-release.yml/badge.svg)](https://github.com/tufw95/bigroute/actions/workflows/office-release.yml)

Bigroute is a native macOS menu bar app and WidgetKit extension for monitoring account quota from user-configured router providers.

## Features

- Add any number of providers using a display name, HTTPS endpoint, and API key.
- Automatically understand supported OmniRouter and 9Router quota responses.
- Hide provider tabs when only one provider is configured.
- Choose quota, account-name, or refresh-time sorting in either direction; the app and widget stay in sync.
- Prefer provider-defined account names over email labels when the quota endpoint exposes them.
- Show remaining quota with red (0–20%), yellow (21–70%), and green (71–100%) indicators, plus account state and time until quota refresh.
- Refresh providers in parallel every 1–60 minutes; the default is 2 minutes.
- Store API keys in macOS Keychain and share only sanitized quota snapshots with the widget.
- Optionally keep 9Router ChatGPT OAuth routing healthy: deactivate an account when any measured quota window reaches exactly 0%, then reactivate Bigroute-managed accounts only after every measured window is above 0% and each exhausted window reports a newer reset epoch.
- Use native SwiftUI, AppKit, WidgetKit, App Intents, semantic colors, and macOS materials.
- Deliver signed automatic updates with Sparkle 2.

## Install

Bigroute requires macOS 14 or later on Apple Silicon or Intel Macs.

The current office build is available from [Bigroute 1.2.0 Office](https://github.com/tufw95/bigroute/releases/tag/office-v1.2.0):

Existing Router Quota 1.0.2 users should use **Check for Updates…** for the cleanest in-place migration. For a manual upgrade, quit Router Quota and move `/Applications/Router Quota.app` to the Trash before copying Bigroute; keeping both bundles can make macOS load the older widget because they intentionally share compatibility identifiers.

1. Download `Bigroute-<version>.dmg`.
2. Open the DMG and drag **Bigroute** to **Applications**.
3. On first launch, if macOS blocks the app, open **System Settings > Privacy & Security** and choose **Open Anyway**.
4. Open Bigroute once, then add providers from **Settings**.

Office builds are universal, signed with a persistent internal certificate, and authenticated by a Sparkle Ed25519 signature, but they are not Apple notarized. Bigroute keeps the existing signed app identity, Keychain service, App Group, and Sparkle key so Router Quota 1.0.2 installations can upgrade in place without losing providers or widget configuration. Machines upgrading from the older ad-hoc preview may receive one final Keychain approval prompt. Widget discovery can still vary because Apple reserves fully provisioned App Groups for paid Developer teams.

An optional public-trust release can also be produced with a paid Apple Developer membership:

1. Open the [latest GitHub release](https://github.com/tufw95/bigroute/releases/latest).
2. Download `Bigroute-<version>.dmg`.
3. Open the DMG and drag **Bigroute** to **Applications**.
4. Open Bigroute once, then add providers from **Settings**.

Public-trust artifacts are Developer ID signed, notarized by Apple, and validated by Gatekeeper. This stronger channel is separate from the internal office OTA channel.

## Configure Providers

Open **Bigroute > Settings**, then add a provider with:

- **Name:** any label that is useful to your team.
- **Endpoint:** the provider's HTTPS base URL or supported quota URL.
- **API key:** the credential allowed to read that provider's quota endpoint.

For a 9Router provider, choose **9Router** as the provider type to enable **Automatic Account Routing**. This optional feature also asks for the 9Router dashboard password, which is stored separately in macOS Keychain. Bigroute changes only the `isActive` state of ChatGPT OAuth accounts:

- Any measured quota window at exactly `0%`: deactivate the account so 9Router stops sending new requests to it.
- Every measured quota window above `0%`: reactivate it, but only if Bigroute previously deactivated that account and the previously exhausted window has crossed its recorded reset epoch.
- Stale, throttled, missing, invalid, unlimited-only, or unavailable quota: make no change.

Automatic routing is off by default, requests fresh 9Router quota before each reconciliation, never applies to OmniRouter or auto-detected unknown providers, and does not reactivate accounts that a person disabled manually. Reactivation requires complete session/weekly quota windows with valid reset times; legacy ownership without a recorded reset epoch remains inactive until manually enabled. Bigroute reuses the authenticated dashboard session across refreshes and re-authenticates when 9Router expires or rejects it.
Run automatic routing from one designated, always-on controller Mac for each 9Router endpoint, and configure only one automatic-routing provider for that endpoint. Leave the feature off on every other Mac that points at that endpoint because 9Router does not expose a stable shared ownership or controller lease.
Turning automatic routing or the provider off, deleting the provider, or changing its router endpoint, API key, or dashboard password relinquishes Bigroute's ownership without changing the account's current `isActive` state. An account that is already inactive remains inactive and may need manual activation; re-enabling later starts with a clean ownership state.
Before each deactivation, Bigroute records ownership locally. If 9Router definitively rejects the write, Bigroute rolls that ownership record back. For a timeout, server error, rate limit, or malformed response, it verifies the account with a follow-up read; unless the server explicitly proves the write was rejected, ownership is retained for safe recovery on the next run.
The configured endpoint must permit authenticated 9Router dashboard API access. If dashboard access is disabled for a public tunnel, use the router's LAN or Tailscale endpoint for that provider instead.

If only one provider exists, the provider picker is hidden. With multiple providers, use the centered picker to switch between them. API keys stay in macOS Keychain and are never copied into WidgetKit snapshots or release artifacts.

Bigroute displays account identity in this order: provider-defined name, account name, display name, username, legacy label, email, then account ID. A router endpoint that returns only an email in `label` cannot be resolved to the private account name by the app; that endpoint must expose `name` or use the configured name as its `label`.

## Add the Widget to the Desktop

If Bigroute appears only in Notification Center, macOS desktop widgets are disabled:

1. Open **System Settings > Desktop & Dock**.
2. Scroll to **Widgets > Show Widgets**.
3. Enable **On Desktop**.
4. Enable **In Stage Manager** too if you use Stage Manager.
5. Right-click the Desktop and choose **Edit Widgets**.
6. Search for **Bigroute**, choose a size, and add it.

Open the app at least once before searching for the widget. If an older widget instance shows no data or cannot be configured, remove it and add the current **Bigroute** widget again. Use **Edit Widget** to choose a provider when more than one is configured.

## Refresh Timing

The menu bar app refreshes each provider at the interval selected in Settings, which is 2 minutes by default. It bypasses local HTTP caches and coalesces automatic WidgetKit reload requests to one every 5 minutes so macOS does not throttle the widget. A request received during that window is queued and delivered as soon as the window ends instead of being discarded. A manual app refresh requests an immediate reload.

The widget also requests a fallback timeline every 5 minutes. Its refresh button opens Bigroute, fetches the configured providers immediately, saves a new sanitized snapshot, and requests a widget redraw. macOS owns WidgetKit scheduling and may still delay or combine refreshes to protect battery life. The widget header reports the age of the last successful provider result, for example `Updated 8 min ago`; it does not represent the quota reset time.

After upgrading, remove and add the widget once if macOS keeps showing an old extension timeline. macOS can keep a previous WidgetKit extension process alive after a Sparkle update even though the menu-bar app is already current.

Sparkle checks for app updates hourly and also supports **Check for Updates…** from the app. Office updates are read from the dedicated signed channel:

```text
https://github.com/tufw95/bigroute/releases/download/office-channel/appcast.xml
```

## Build from Source

Requirements:

- macOS 14 or later.
- A full Xcode installation at `/Applications/Xcode.app`.
- Swift 6.

Run the tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Build and launch a local Debug copy:

```bash
./script/build_and_run.sh
```

Unsigned or ad-hoc local builds are suitable for development, but WidgetKit discovery and the shared App Group work most reliably when both targets use the same Apple Development team.

## Office OTA Release

The `Office Release` workflow requires the persistent office certificate and Sparkle Ed25519 key configured in GitHub Actions. It builds a universal internally signed app, verifies the appcast and ZIP signatures against the public key embedded in the app, publishes the numbered release, and atomically updates the fixed `office-channel` feed.

Required repository secrets:

- `OFFICE_SIGNING_CERTIFICATE_BASE64`: password-protected PKCS#12 containing the persistent `Router Quota Office Signing` compatibility identity. Do not rename or replace this certificate; installed office builds require the same signing root.
- `OFFICE_SIGNING_CERTIFICATE_PASSWORD`: password for that PKCS#12 file.
- `SPARKLE_EDDSA_PRIVATE_KEY_BASE64`: private key matching the `SUPublicEDKey` embedded in the app.

Create an office release after CI passes on `main`:

```bash
git tag -a office-v1.2.0 -m "Bigroute 1.2.0"
git push origin office-v1.2.0
```

Existing office installations check the dedicated channel hourly and can also use **Check for Updates…** immediately. The legacy `com.routerquota.*` bundle IDs and App Group are intentionally retained for OTA, Keychain, and WidgetKit continuity even though all user-facing product and release names are Bigroute.

## Developer ID Release

The optional `Release` workflow runs only for stable semantic-version tags such as `v1.0.0`. It requires a paid Apple Developer membership, signs and notarizes the app, and publishes to a separate fixed `stable-channel` feed. Office installations never read this feed.

- `Bigroute-<version>.dmg`
- `Bigroute-<version>.zip`
- `appcast.xml`

Before pushing a tag, add a matching section to `CHANGELOG.md` and configure the repository's protected `release` environment. The environment should require reviewer approval and contain every secret below. A missing secret stops the workflow before any release is created.

### Required GitHub Actions Secrets

- `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded password-protected `.p12` containing a **Developer ID Application** certificate and private key.
- `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`: password used when exporting the `.p12`.
- `MACOS_APP_PROVISIONING_PROFILE_BASE64`: base64-encoded **Developer ID** provisioning profile for `com.routerquota.app` with App Group `group.com.routerquota.shared`.
- `MACOS_WIDGET_PROVISIONING_PROFILE_BASE64`: base64-encoded **Developer ID** provisioning profile for `com.routerquota.app.widget` with App Group `group.com.routerquota.shared`.
- `APPLE_ID`: Apple Developer account email used by `notarytool`.
- `APPLE_TEAM_ID`: the 10-character Apple Developer team ID present in the certificate and both profiles.
- `APPLE_APP_PASSWORD`: app-specific password for the Apple ID used by `notarytool`.
- `SPARKLE_EDDSA_PRIVATE_KEY_BASE64`: base64 of the private Ed25519 key file whose public key is embedded as `SUPublicEDKey` in the app.

Create base64 values without line wrapping on macOS:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i Bigroute.provisionprofile | pbcopy
base64 -i BigrouteWidget.provisionprofile | pbcopy
base64 -i sparkle_private_key | pbcopy
```

The bundle IDs and App Group must be registered in the same Apple Developer team. Keep the Sparkle private key, certificate, profiles, and notarization credentials out of the repository.

Create and push a Developer ID release tag only after CI passes on `main`:

```bash
git tag -s v1.0.0 -m "Bigroute 1.0.0"
git push origin v1.0.0
```

See `SECURITY.md` for private vulnerability reporting.
