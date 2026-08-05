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

Office releases use a pinned, persistent self-signed code-signing certificate and are not Apple notarized. Their update ZIP and dedicated office appcast are authenticated with the embedded Sparkle Ed25519 public key. Users must download the first installer only from this repository and verify that subsequent updates are presented by Bigroute itself.

The legacy `com.routerquota.*` bundle IDs, `group.com.routerquota.shared` App Group, Keychain service, Sparkle public key, and `Router Quota Office Signing` certificate name are compatibility identifiers. They must not be globally renamed or replaced during a product rebrand because existing installations rely on them for trusted OTA updates and credential continuity.
