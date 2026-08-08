# Changelog

All notable changes to Bigroute are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-08-08

### Added

- Added optional automatic routing for explicitly configured 9Router providers: ChatGPT OAuth accounts are deactivated when any measured quota window reaches exactly 0% and Bigroute-owned accounts are reactivated only after every measured window is above 0% and exhausted-window reset epochs advance.
- Added a Keychain-backed 9Router dashboard password and provider-scoped ownership state so manually disabled accounts are not reactivated.

### Security

- Require fresh quota metadata, complete finite 0–100% values, valid reset epochs, a valid authenticated dashboard session, and a confirmed mutation response or follow-up state read before changing routing.
- Persist deactivation ownership before the remote write and cancel in-flight reconciliation when provider settings change.
- Reuse the authenticated 9Router session across refreshes and re-authenticate after expiry or a rejected session.
- Roll back write-ahead ownership only after a definitive mutation rejection; retain ownership after ambiguous failures or mismatching immediate reads so a later run can recover safely.
- Relinquish automation ownership without mutating 9Router when routing is turned off, a provider is disabled or deleted, or its router endpoint, API key, or dashboard password changes.
- Ignore OmniRouter, unknown providers, non-ChatGPT connections, stale/throttled/unlimited-only quota, missing reset epochs, and invalid or unavailable measurements.

### Documentation

- Document one enabled automatic-routing provider and one designated, always-on controller Mac per 9Router endpoint. Other Macs should keep automatic routing disabled because 9Router has no shared controller lease.
- Clarify that releasing ownership does not reactivate accounts that are already inactive; manual activation may be required.

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

[Unreleased]: https://github.com/tufw95/bigroute/compare/office-v1.2.0...HEAD
[1.2.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.2.0
[1.1.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.1.2
[1.1.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.1.1
[1.1.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.1.0
[1.0.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.0.2
[1.0.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.0.1
[1.0.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.0.0
