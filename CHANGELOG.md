# Changelog

All notable changes to Router Quota are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/tufw95/router-quota/compare/office-v1.0.2...HEAD
[1.0.2]: https://github.com/tufw95/router-quota/releases/tag/office-v1.0.2
[1.0.1]: https://github.com/tufw95/router-quota/releases/tag/office-v1.0.1
[1.0.0]: https://github.com/tufw95/router-quota/releases/tag/office-v1.0.0
