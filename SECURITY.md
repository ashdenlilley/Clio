# Security

Do not report vulnerabilities containing private documents, credentials or
signing material in public issues. Use GitHub's private vulnerability reporting
if it is enabled for this repository. If it is unavailable, ask a maintainer for
a private reporting channel without posting exploit details or sensitive data.

Never commit API keys, tokens, signing certificates with private keys, keychain
exports, environment files or unredacted build artifacts. `.gitignore` is a
convenience, not a security boundary: it does not remove previously committed
files or stop a forced add.

Release credentials belong in restricted CI configuration. Do not expose them to
untrusted pull requests or branches. Masked logs do not prevent malicious code
from reading a secret. Forks should use their own signing and repository settings.

Signed macOS apps necessarily expose their signing identity and notarization
ticket. These public verification records are not the signing private key.

If a credential was committed, revoke/rotate it first. Deleting the current file
does not revoke it or remove it from Git history, releases, forks or caches.
