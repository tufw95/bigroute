# Changelog

All notable changes to Bigroute are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.1] - 2026-08-19

### Fixed

- Quota refreshes send the `refresh=1` query flag on forced refreshes so routers refresh their snapshot when requested.
- Increased quota request timeout to 25 seconds to allow multi-account routers to aggregate and return live account quotas.
- Removed the 5-minute error retry backoff to ensure scheduled intervals and menu-bar popover opens refresh quota promptly.
- Added automatic fallback to preview and apply in manual routing actions when 9Router's cached snapshot has expired (HTTP 409).

## [1.4.0] - 2026-08-14

### Added

- Added a native **Import JSON…** action for providers configured as 9Router. It accepts up to 100 selected ChatGPT credential files, including single-account files, arrays, and `{ "accounts": [...] }` wrappers.
- Added normalization for purchased credential formats that use either snake-case or camel-case token and account fields.

### Security

- Credential files are read only after explicit user selection, kept in memory, sent over the saved HTTPS 9Router endpoint, and never persisted or logged by Bigroute.
- The API-key import path limits request size and account count, strips unknown and server-controlled fields, suppresses tokens in responses, serializes database writes, and skips duplicate accounts.

## [1.3.4] - 2026-08-14

### Fixed

- Manual 9Router results now reconcile server-issued account IDs with Bigroute's provider-scoped IDs, so an account disappears immediately after **Turn Off Empty** and reappears immediately after **Turn On Available** without waiting for the follow-up refresh.

## [1.3.3] - 2026-08-14

### Fixed

- Accounts explicitly turned off in 9Router are now hidden from both the menu-bar grid and WidgetKit instead of remaining visible with an **Off** badge.
- Turning an eligible account back on makes it reappear immediately from the retained local snapshot, while providers that do not expose routing state remain fully visible.

## [1.3.2] - 2026-08-14

### Fixed

- Bigroute now reads the live 9Router `isActive` state independently from cached quota, so accounts disabled in 9Router immediately appear as **Off** after the next app refresh.
- Manual actions now reconcile changed accounts locally, force a fresh app/widget snapshot, and show concise inline success, no-change, skipped, or error feedback instead of appearing to do nothing.
- Added an **Off** indicator to both the menu-bar account grid and WidgetKit rows while preserving quota and reset information.
- Added privacy-safe timing and result-count logs for manual actions without recording credentials, account IDs, or account names.

## [1.3.1] - 2026-08-13

### Fixed

- Manual 9Router actions now use one bounded `apply_cached` request based on the latest server-owned quota snapshot, eliminating the second account-by-account quota scan.
- Removed the manual-action confirmation and result popups; actions start immediately and show only an inline progress indicator.
- Sparkle office update checks now add a cache-busting query so an older cached channel feed cannot stage releases one version at a time.

## [1.3.0] - 2026-08-12

### Added

- Added explicit **Turn Off Empty** and **Turn On Available** actions for providers configured as 9Router.
- Added a guarded server-side account action flow that keeps internal account IDs private and rechecks current account state before each change.
- Added a provider type selector so custom providers can opt into the 9Router actions without affecting Auto-detect or OmniRouter providers.

### Security

- Kept scheduled refreshes, WidgetKit, and provider detection read-only; account state can change only after a visible user action.
- Added an in-process mutation lock, fail-closed quota checks, and per-account skip handling.

## [1.2.2] - 2026-08-10

### Removed

- Removed Automatic Account Routing, its 9Router dashboard session, and every account activation/deactivation request. Bigroute is now strictly a quota-monitoring client.

### Security

- Normalize legacy 1.2.0/1.2.1 provider settings locally before refresh, delete the retired dashboard password and ownership state from macOS storage, and never change existing account state during migration.
- Added a mandatory monitoring-only source gate to CI and office packaging that rejects 9Router management endpoints and mutating HTTP methods.

### Fixed

- Removed automatic-routing freshness warnings from the menu-bar interface.

## [1.2.1] - 2026-08-09

### Fixed

- Fixed the office OTA launch failure on macOS: self-signed office builds no longer enable Hardened Runtime library validation that rejects the embedded Sparkle framework when no Apple Team ID is available.
- Kept Sparkle Ed25519 verification and the persistent office signing identity unchanged so existing credentials and update trust remain intact.

## 1.2.0 - 2026-08-08 (withdrawn)

- Withdrawn from GitHub after the client-side account-routing design proved unsuitable for a multi-user office deployment. Its release assets and tag are no longer published.

## [1.1.2] - 2026-08-06

### Changed

- Expanded the three-color quota bands in both the menu-bar app and widget: red for displayed values from 0% through 20%, yellow from 21% through 70%, and green from 71% through 100%.

## [1.1.1] - 2026-08-06

### Changed

- Changed quota indicators in both the menu-bar app and widget to a clearer three-color scale based on the displayed percentage: red at 10% or below, yellow from 11% through 50%, and green above 50%.

## [1.1.0] - 2026-08-05

### Changed

- Rebranded the macOS app, widget, repository, documentation, build products, release artifacts, and update channels as Bigroute.
- Replaced the application and menu-bar artwork with the new Bigroute icon.
- Renamed the Xcode and SwiftPM projects, targets, modules, tests, and development scripts to match the new product name.
- Preserved the existing bundle IDs, App Group, Keychain service, Sparkle public key, and office signing identity so Router Quota 1.0.2 installations can update without losing configuration or widget continuity.

## [1.0.2] - 2026-08-05

### Added

- Added a widget refresh button that asks the app to fetch providers immediately, plus unified-log telemetry that diagnoses timeline reads without exposing account data or credentials.

### Fixed

- Preserved WidgetKit reload requests that arrive during the five-minute throttle window instead of dropping them permanently.
- Refreshed widget freshness and reset countdowns even when the numeric quota value has not changed.
- Reduced the WidgetKit fallback timeline from fifteen minutes to five minutes.
- Made the menu-bar popover resize to its two-column account content, with scrolling only for large account lists.

## [1.0.1] - 2026-08-01

### Fixed

- Coalesced content-aware, targeted WidgetKit reloads to avoid timeline-budget throttling and stale quota cards.
- Made the widget freshness label advance independently of timeline redraws.
- Bypassed local HTTP caches for provider quota requests.
- Reduced the menu-bar popover width for a denser two-column account layout.

## [1.0.0] - 2026-08-01

### Added

- Native macOS menu bar quota monitor with custom provider configuration.
- WidgetKit extension with provider selection and large account layouts.
- Keychain-backed API credentials and sanitized widget snapshots.
- Provider-defined account names with safe fallback to legacy email labels.
- Six persisted account sort modes shared by the menu bar app and WidgetKit.
- Optional future Developer ID signing and notarization workflow for a public-trust channel.
- Sparkle 2 automatic updates delivered through GitHub Releases.
- Internal office OTA releases that require no paid Apple Developer membership.
- Persistent internal code signing to keep Keychain access stable across office updates.
- Separate fixed Sparkle feeds for office and future Developer ID release channels.

[Unreleased]: https://github.com/tufw95/bigroute/compare/office-v1.4.0...HEAD
[1.4.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.0
[1.3.4]: https://github.com/tufw95/bigroute/releases/tag/office-v1.3.4
[1.3.3]: https://github.com/tufw95/bigroute/releases/tag/office-v1.3.3
[1.3.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.3.2
[1.3.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.3.1
[1.3.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.3.0
[1.2.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.2.2
[1.2.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.2.1
[1.1.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.1.2
[1.1.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.1.1
[1.1.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.1.0
[1.0.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.0.2
[1.0.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.0.1
[1.0.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.0.0
