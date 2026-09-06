# Changelog

All notable changes to Bigroute are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.1] - 2026-09-06

### Fixed

- Allow HTTP endpoints (e.g. `http://ai.local`, `http://local.ai`, or custom LAN IP addresses) for router providers and Antigravity bridge without forcing HTTPS.
- Completely removed the redundant "Provider type" picker from Provider Editor to simplify configuration; auto-detection and 9Router features now work seamlessly on all configured providers.
- Added bridge provider fallback to the first enabled provider if none is explicitly tagged as 9Router, ensuring Antigravity Bridge activates automatically with any configured provider.
- Enabled manual account routing and credential importing for any non-OmniRouter provider.

## [1.6.0] - 2026-09-06

### Added

- Automated Antigravity ASAR patcher & integrity verification (`antigravity-asar-patcher.mjs`): automatically detects unpatched or freshly updated Antigravity app bundles, applies the custom Cloud Code endpoint loader to `languageServer.js`, updates `ElectronAsarIntegrity` in `Info.plist`, and re-signs binaries ad-hoc so the 9Router bridge persists seamlessly across Antigravity self-updates.

### Fixed

- Corrected HTTP forwarding, cancellation, compressed responses, UTF-8 SSE framing, synchronous generation, function-call results, and current model aliases in the Antigravity Bridge. Unknown RPCs and discovery schemas pass through unchanged.
- Surface missing configuration, unsupported media, malformed tools, and interrupted streams instead of returning misleading successful responses or falling back to Google generation.
- Reuse the local proxy only when its script hash matches the bundled version. Serialize Bridge changes, restore the previous endpoint on failure/disable, and check the endpoint used by a running Antigravity language server.
- Preserve configuration after denied Keychain reads; update changed credentials in place and skip Keychain writes when only settings change.
- Correct percentage/fraction parsing, numeric bounds, provider classification, account availability, and expired-plan detection. A Free plan alone no longer means expired.
- Prevent removed providers and old refreshes from overwriting current account state. Queue forced refreshes and keep cached failure timestamps accurate.
- Honor each build's Sparkle channel, expose update errors, and synchronize update buttons with Sparkle's actual readiness.

### Changed

- Publish signed OTA feeds through an atomic Git branch update, reject feed downgrades, retain the legacy feed for existing clients, and verify both public URLs. Interrupted office releases reuse immutable signed archives.
- Store snapshots per user; read old shared caches only for migration. Cache account sorting and remove unused quota sanitizers, widget descriptors, and obsolete widget instructions.
- Keep development builds in DerivedData instead of overwriting the installed signed app.
- Add regression coverage for Bridge transport/conversion, ASAR patcher, Keychain failure, quota parsing, cache migration, and account availability.

### Known issue / release gate

- Phone Remote Control still reports **Lost connection to the remote instance** when switching conversations. The local proxy tests pass, but the user's phone retest failed. This is not claimed fixed.
- Antigravity auto-patching ensures compatibility with standard official builds across updates; major architectural redesigns by Google may require future bridge maintenance. See `docs/audit-1.6.0.md`.

## [1.5.3] - 2026-09-05

### Fixed

- Preserved Antigravity Remote Control while the 9Router bridge is enabled by forwarding the official experiment-discovery response that supplies the `jetski-webchannel.googleapis.com` relay.
- Kept non-generation Cloud Code traffic transparent through the bridge so phone remote control, authentication, telemetry, and other Antigravity services continue to work while generation requests use 9Router.
- Restored the local bridge during Bigroute relaunch without blocking the menu-bar app on a slow macOS Keychain response.

## [1.5.2] - 2026-09-05

### Enhanced

- **Agent Tool Calling & Reasoning Support in Bridge Proxy**: Added full streaming support for OpenAI tool calls (`delta.tool_calls`) and thinking deltas (`delta.reasoning_content`) converted to Gemini function calls and thought parts.
- **Multimodal Message Support**: Bridge now formats image parts (`inlineData`) to OpenAI `image_url` for seamless image input in Antigravity chat.
- **Apply & Restart**: Made restarting Antigravity from Bigroute settings auto-save current model mode and custom model IDs before relaunching.

## [1.5.1] - 2026-09-05

### Fixed

- **Seamless Model Mapping for Keep Official Models**: When selecting *Keep Official Models*, Antigravity displays the exact clean official Google model list, while requests (e.g. `gemini-3.8-flash-high`) are automatically mapped and routed to 9Router's corresponding model (`ag/gemini-3.8-flash-high`).
- **Custom Models Mode**: Allows adding custom model IDs (e.g. `cx/gpt-5.6-sol`, `ag/gemini-3.8-flash-high`) directly to Antigravity's model list.

## [1.5.0] - 2026-09-05

### Added

- **Antigravity 9Router Bridge Switch**: Integrated an On/Off toggle in Bigroute Settings to switch Antigravity macOS app between Official Google Cloud Code and the 9Router pool seamlessly.
- **Dynamic Endpoint Support**: Automatically manages `cloud_code_endpoint.txt` and background bridge proxy (port `50999`), auto-restarting Antigravity on switch.
- **Preserved Model Metadata & Context Length**: Keeps full 1M token context length and metadata for Google models and seamlessly injects 9Router models (`cx/gpt-5.5`, `ag/claude-sonnet-4-6`...).
- **Configurable Model Mode**: Allows choosing between *Keep Official Models + 9Router (Recommended)* and *Custom Models*.

## [1.4.13] - 2026-09-04

### Changed

- Completely removed Widget extension (BigrouteWidget) and all WidgetKit dependencies to make the app ultra-lightweight and clean.
- Streamlined UI rendering and eliminated heavy frame animations, ensuring instant and lag-free popover rendering.
- Simplified shared storage and background monitoring routines.

## [1.4.12] - 2026-08-27

### Fixed

- Removed secondary quota row for Google Antigravity, reverting to a clean single-row Flash bar layout until 9Router implements official weekly support.
- Kept 2-row layout (Session & Weekly) exclusively for ChatGPT accounts.

## [1.4.11] - 2026-08-27

### Fixed

- Updated Google Antigravity account cards to display accurate model group labels (**Gemini** & **Claude**) with real-time bucket reset dates instead of forcing a generic "Weekly" title.
- Preserved **Session** (5h) and **Weekly** (7d) metrics for ChatGPT accounts where authentic 7-day windows exist.

## [1.4.10] - 2026-08-26

### Fixed

- Added automatic detection and exclusion of expired ChatGPT accounts that downgraded to Free tier (`plan: "free"`). 9Router now marks them as unavailable (`plan_free`) and clears quota data.
- Added visual `Free / Expired` red badge and `Plan expired (Free tier) · Re-subscribe` notice on account cards.
- Updated `Turn Off Empty` to automatically disable Free-tier accounts and excluded them from `Turn On Available`.

## [1.4.9] - 2026-08-26

### Fixed

- Fixed stale quota caching when accounts get logged out (lost session / token invalidated). 9Router now immediately marks auth errors and clears expired quotas instead of serving old cached data.
- Added visual `Logged Out` badge and `Session lost · Re-login in 9Router` status on affected cards.
- Updated `Turn Off Empty` action to automatically disable logged out accounts.

## [1.4.8] - 2026-08-26

### Added

- Redesigned quota account cards into a clean 2-row layout featuring **horizontal progress bars (thanh bar ngang)** for both **Session quota** (4-5h / Flash cycle) and **Weekly quota** (7-day cycle) with remaining percentages and reset times.
- Updated 9Router backend service to extract and normalize both session and weekly quota windows for ChatGPT and Google Antigravity accounts.

## [1.4.7] - 2026-08-21

### Fixed

- Fixed section count badges to accurately reflect `(active/total)` counts for each provider section (Google Antigravity & ChatGPT) regardless of whether inactive account filter is enabled.
- Fixed manual routing actions (`Turn Off Empty` / `Turn On Available`) on 9Router backend and eliminated server error dialogs.
- Improved progress ring rendering for low-percentage accounts and prevented action bar text truncation.

## [1.4.6] - 2026-08-20

### Added

- Separated accounts into 2 distinct visual blocks with clean section headers and count badges: **Google Antigravity** and **ChatGPT (Codex)**.

### Fixed

- Fixed intermittent "N/A" quota glitch by persisting last known valid quota and reset times when transient upstream refresh timeouts occur.

## [1.4.5] - 2026-08-20

### Added

- Added support for Antigravity (Gemini) router accounts with single-line quota tracking (Gemini 3.6 Flash High), displaying live percentage and reset time alongside ChatGPT accounts.

### Changed

- Updated manual routing actions to standard complementary thresholds: **Turn Off Empty (0%)** and **Turn On Available (>0%)**.

## [1.4.4] - 2026-08-20

### Added

- Added an eye toggle button in the dashboard header to quickly show or hide inactive (OFF) accounts.
- Updated Turn Off Empty threshold and action label to maximize quota utilization.

## [1.4.3] - 2026-08-20

### Fixed

- Fixed empty dashboard by displaying all accounts from the provider snapshot with clear routing status badges instead of filtering out inactive accounts.
- Eliminated unwanted spinning loading states on simple menu-bar popover open.

## [1.4.2] - 2026-08-20

### Fixed

- Increased quota request timeout to 60 seconds to support multi-account routers with high account counts.
- Fixed auto-detect provider fallback to only attempt OmniRouter when 9Router is explicitly unsupported (HTTP 404/405), preventing erroneous 401 Unauthorized errors on slow responses.

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

[Unreleased]: https://github.com/tufw95/bigroute/compare/office-v1.5.3...HEAD
[1.4.13]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.13
[1.4.12]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.12
[1.4.11]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.11
[1.4.10]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.10
[1.4.9]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.9
[1.4.8]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.8
[1.4.7]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.7
[1.4.6]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.6
[1.4.5]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.5
[1.4.4]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.4
[1.4.3]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.3
[1.4.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.2
[1.4.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.4.1
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

[1.6.0]: https://github.com/tufw95/bigroute/compare/office-v1.5.3...HEAD
[1.5.0]: https://github.com/tufw95/bigroute/releases/tag/office-v1.5.0
[1.5.1]: https://github.com/tufw95/bigroute/releases/tag/office-v1.5.1
[1.5.2]: https://github.com/tufw95/bigroute/releases/tag/office-v1.5.2
[1.5.3]: https://github.com/tufw95/bigroute/releases/tag/office-v1.5.3
