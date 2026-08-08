# Security Policy

## Supported Versions

Security fixes are provided for the latest published Bigroute release.

## Report a Vulnerability

Do not open a public issue for a suspected vulnerability or accidentally exposed credential.

Use GitHub's private vulnerability reporting:

1. Open the repository's **Security** tab.
2. Choose **Advisories**.
3. Select **Report a vulnerability**.

Include the affected version, macOS version, reproduction steps, expected impact, and any relevant logs with credentials removed. You should receive an initial response within seven days.

## Credential Safety

Bigroute stores provider API keys and optional 9Router dashboard passwords in macOS Keychain. Dashboard passwords are used only for authenticated 9Router account-state reconciliation and are never copied into provider metadata, WidgetKit snapshots, logs, or release artifacts. Release signing certificates, provisioning profiles, notarization passwords, and the Sparkle EdDSA private key must remain in protected GitHub Actions secrets and must never be committed.

Automatic 9Router routing is disabled by default and fail-closed. It acts only on fresh, measured ChatGPT OAuth quota across all finite windows, changes only the `isActive` field, and records which connections Bigroute deactivated so manually disabled accounts are never reactivated automatically. Reactivation additionally requires complete `session` and `weekly` usage windows and a reset epoch newer than the one recorded at deactivation. Authentication failures, rate limits, stale/throttled/invalid quota, and unsupported providers must not trigger account mutations.

Use one designated, always-on controller Mac and one enabled automatic-routing provider for each 9Router endpoint. Other Macs should leave automatic routing disabled because 9Router does not expose a stable shared ownership or controller lease. Bigroute reuses an authenticated dashboard session across refreshes and re-authenticates after the server expires or rejects that session.

Deactivation ownership is written before the remote mutation. A definitive rejection rolls the local ownership record back; an ambiguous timeout, server error, rate limit, or malformed response is checked with a follow-up read. Unless the server explicitly proves the write was rejected, Bigroute retains ownership so a later run can recover safely instead of reactivating an account it may not have deactivated.

Disabling automation, disabling or deleting a provider, or changing its endpoint, API key, or dashboard password releases local ownership without changing 9Router state. Accounts already inactive remain inactive and may require manual activation.

Office releases use a pinned, persistent self-signed code-signing certificate and are not Apple notarized. Their update ZIP and dedicated office appcast are authenticated with the embedded Sparkle Ed25519 public key. Users must download the first installer only from this repository and verify that subsequent updates are presented by Bigroute itself.

The legacy `com.routerquota.*` bundle IDs, `group.com.routerquota.shared` App Group, Keychain service, Sparkle public key, and `Router Quota Office Signing` certificate name are compatibility identifiers. They must not be globally renamed or replaced during a product rebrand because existing installations rely on them for trusted OTA updates and credential continuity.
