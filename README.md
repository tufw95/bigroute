# Router Quota

[![CI](https://github.com/tufw95/router-quota/actions/workflows/ci.yml/badge.svg)](https://github.com/tufw95/router-quota/actions/workflows/ci.yml)
[![Office Release](https://github.com/tufw95/router-quota/actions/workflows/office-release.yml/badge.svg)](https://github.com/tufw95/router-quota/actions/workflows/office-release.yml)

Router Quota is a native macOS menu bar app and WidgetKit extension for monitoring account quota from user-configured router providers.

## Features

- Add any number of providers using a display name, HTTPS endpoint, and API key.
- Automatically understand supported OmniRouter and 9Router quota responses.
- Hide provider tabs when only one provider is configured.
- Choose quota, account-name, or refresh-time sorting in either direction; the app and widget stay in sync.
- Prefer provider-defined account names over email labels when the quota endpoint exposes them.
- Show remaining quota, account state, and time until quota refresh.
- Refresh providers in parallel every 1–60 minutes; the default is 2 minutes.
- Store API keys in macOS Keychain and share only sanitized quota snapshots with the widget.
- Use native SwiftUI, AppKit, WidgetKit, App Intents, semantic colors, and macOS materials.
- Deliver signed automatic updates with Sparkle 2.

## Install

Router Quota requires macOS 14 or later on Apple Silicon or Intel Macs.

The latest office release is available from [GitHub Releases](https://github.com/tufw95/router-quota/releases/latest):

1. Download `Router-Quota-<version>.dmg`.
2. Open the DMG and drag **Router Quota** to **Applications**.
3. On first launch, if macOS blocks the app, open **System Settings > Privacy & Security** and choose **Open Anyway**.
4. Open Router Quota once, then add providers from **Settings**.

Office builds are universal, signed with a persistent internal certificate, and authenticated by a Sparkle Ed25519 signature, but they are not Apple notarized. A fresh office installation keeps the same signing identity across later OTA releases, preserving Keychain access. Machines upgrading from the older ad-hoc preview may receive one final Keychain approval prompt. Widget discovery can still vary because Apple reserves fully provisioned App Groups for paid Developer teams.

An optional public-trust release can also be produced with a paid Apple Developer membership:

1. Open the [latest GitHub release](https://github.com/tufw95/router-quota/releases/latest).
2. Download `Router-Quota-<version>.dmg`.
3. Open the DMG and drag **Router Quota** to **Applications**.
4. Open Router Quota once, then add providers from **Settings**.

Public-trust artifacts are Developer ID signed, notarized by Apple, and validated by Gatekeeper. This stronger channel is separate from the internal office OTA channel.

## Configure Providers

Open **Router Quota > Settings**, then add a provider with:

- **Name:** any label that is useful to your team.
- **Endpoint:** the provider's HTTPS base URL or supported quota URL.
- **API key:** the credential allowed to read that provider's quota endpoint.

If only one provider exists, the provider picker is hidden. With multiple providers, use the centered picker to switch between them. API keys stay in macOS Keychain and are never copied into WidgetKit snapshots or release artifacts.

Router Quota displays account identity in this order: provider-defined name, account name, display name, username, legacy label, email, then account ID. A router endpoint that returns only an email in `label` cannot be resolved to the private account name by the app; that endpoint must expose `name` or use the configured name as its `label`.

## Add the Widget to the Desktop

If Router Quota appears only in Notification Center, macOS desktop widgets are disabled:

1. Open **System Settings > Desktop & Dock**.
2. Scroll to **Widgets > Show Widgets**.
3. Enable **On Desktop**.
4. Enable **In Stage Manager** too if you use Stage Manager.
5. Right-click the Desktop and choose **Edit Widgets**.
6. Search for **Router Quota**, choose a size, and add it.

Open the app at least once before searching for the widget. If an older widget instance shows no data or cannot be configured, remove it and add the current **Router Quota** widget again. Use **Edit Widget** to choose a provider when more than one is configured.

## Refresh Timing

The menu bar app refreshes each provider at the interval selected in Settings, which is 2 minutes by default. A successful app refresh immediately asks WidgetKit to reload.

The widget requests a new timeline every 5 minutes. macOS owns WidgetKit scheduling and may delay or combine refreshes to protect battery life. The widget header reports the age of the last successful provider result, for example `Updated 8 min ago`; it does not represent the quota reset time.

Sparkle checks for app updates hourly and also supports **Check for Updates…** from the app. Office updates are read from the dedicated signed channel:

```text
https://github.com/tufw95/router-quota/releases/download/office-channel/appcast.xml
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

- `OFFICE_SIGNING_CERTIFICATE_BASE64`: password-protected PKCS#12 containing the persistent `Router Quota Office Signing` identity.
- `OFFICE_SIGNING_CERTIFICATE_PASSWORD`: password for that PKCS#12 file.
- `SPARKLE_EDDSA_PRIVATE_KEY_BASE64`: private key matching the `SUPublicEDKey` embedded in the app.

Create an office release after CI passes on `main`:

```bash
git tag office-v1.0.0
git push origin office-v1.0.0
```

Existing office installations check the dedicated channel hourly and can also use **Check for Updates…** immediately. The first `1.0.0` release also carries a migration feed for the older preview, whose feed URL used GitHub's global latest release.

## Developer ID Release

The optional `Release` workflow runs only for stable semantic-version tags such as `v1.0.0`. It requires a paid Apple Developer membership, signs and notarizes the app, and publishes to a separate fixed `stable-channel` feed. Office installations never read this feed.

- `Router-Quota-<version>.dmg`
- `Router-Quota-<version>.zip`
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
base64 -i RouterQuota.provisionprofile | pbcopy
base64 -i RouterQuotaWidget.provisionprofile | pbcopy
base64 -i sparkle_private_key | pbcopy
```

The bundle IDs and App Group must be registered in the same Apple Developer team. Keep the Sparkle private key, certificate, profiles, and notarization credentials out of the repository.

Create and push a Developer ID release tag only after CI passes on `main`:

```bash
git tag -s v1.0.0 -m "Router Quota 1.0.0"
git push origin v1.0.0
```

See `SECURITY.md` for private vulnerability reporting.
