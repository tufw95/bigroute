# Changelog

All notable changes to Router Quota are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-01

### Added

- Native macOS menu bar quota monitor with custom provider configuration.
- WidgetKit extension with provider selection and large account layouts.
- Keychain-backed API credentials and sanitized widget snapshots.
- Provider-defined account names with safe fallback to legacy email labels.
- Six persisted account sort modes shared by the menu bar app and WidgetKit.
- Developer ID signed, notarized universal release pipeline.
- Sparkle 2 automatic updates delivered through GitHub Releases.
- Internal office OTA releases that require no paid Apple Developer membership.
- Persistent internal code signing to keep Keychain access stable across office updates.
- Separate fixed Sparkle feeds for office and future Developer ID release channels.

[Unreleased]: https://github.com/tufw95/router-quota/compare/office-v1.0.0...HEAD
[1.0.0]: https://github.com/tufw95/router-quota/releases/tag/office-v1.0.0
