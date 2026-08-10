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

Bigroute stores provider API keys in macOS Keychain. Widget snapshots contain quota display data but never API keys. Release signing certificates, provisioning profiles, notarization passwords, and the Sparkle EdDSA private key must remain in protected GitHub Actions secrets and must never be committed.

Bigroute is a read-only quota monitor. It does not store 9Router dashboard passwords, authenticate to dashboard management endpoints, or change provider account activation state. Upgrading from an older build removes those retired local credentials and ownership markers without sending a request to the router.

Office releases use a pinned, persistent self-signed code-signing certificate and are not Apple notarized. Since that certificate has no Apple Team ID, office artifacts intentionally do not enable Hardened Runtime library validation; enabling it would prevent macOS from loading the embedded Sparkle framework. Their update ZIP and dedicated office appcast are still authenticated with the embedded Sparkle Ed25519 public key. Users must download the first installer only from this repository and verify that subsequent updates are presented by Bigroute itself.

The legacy `com.routerquota.*` bundle IDs, `group.com.routerquota.shared` App Group, Keychain service, Sparkle public key, and `Router Quota Office Signing` certificate name are compatibility identifiers. They must not be globally renamed or replaced during a product rebrand because existing installations rely on them for trusted OTA updates and credential continuity.
