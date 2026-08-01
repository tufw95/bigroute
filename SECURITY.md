# Security Policy

## Supported Versions

Security fixes are provided for the latest published Router Quota release.

## Report a Vulnerability

Do not open a public issue for a suspected vulnerability or accidentally exposed credential.

Use GitHub's private vulnerability reporting:

1. Open the repository's **Security** tab.
2. Choose **Advisories**.
3. Select **Report a vulnerability**.

Include the affected version, macOS version, reproduction steps, expected impact, and any relevant logs with credentials removed. You should receive an initial response within seven days.

## Credential Safety

Router Quota stores provider API keys in macOS Keychain. Widget snapshots contain quota display data but never API keys. Release signing certificates, provisioning profiles, notarization passwords, and the Sparkle EdDSA private key must remain in protected GitHub Actions secrets and must never be committed.
