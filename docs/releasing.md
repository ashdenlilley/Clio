# Release automation

Distribution is performed by a restricted Xcode Cloud workflow. GitHub stores
source and release downloads; no signing credentials belong in this repository.
Only canonical `vMAJOR.MINOR.PATCH` tags publish. Do not move published tags.

The archive must succeed and match the tag's source commit. The pipeline exports
a universal Developer ID application, validates the signing identity and
entitlements, notarizes/staples the app and DMG, verifies the mounted app and
checksums, and uploads verified assets. Test results are advisory for internal
prereleases and are never represented as successful when pending or unavailable.

## Private CI configuration

Maintainers supply these through restricted CI environment settings:

- `DEVELOPER_TEAM_ID`: the intended signing team; also used by the Xcode project.
- `EXPECTED_CLOUD_TEAM_ID`: the expected owning Cloud team identifier, checked
  against Apple's built-in `CI_TEAM_ID`. Never override `CI_TEAM_ID` itself.
- `DEVELOPER_ID_CERT_P12`: Base64 PKCS#12 containing certificate and private key.
- `DEVELOPER_ID_CERT_PASSWORD`: the PKCS#12 password.
- `NOTARY_ISSUER_ID`, `NOTARY_KEY_ID`, `NOTARY_PRIVATE_KEY`: authorized Apple
  team API credentials; the private key is raw multiline PEM text.
- `GITHUB_TOKEN`: repository-scoped release upload access.

**Migration:** workflows previously using a source-pinned Cloud identifier must
set `EXPECTED_CLOUD_TEAM_ID` before pushing another release tag. Release validation
fails closed when it is absent. This value is account configuration, not source.

Restrict workflow/tag changes and secrets to trusted maintainers. Use a separate
secret-free workflow for untrusted contributions. Review the release destination
in the script before using a fork.

## Published and private artifacts

The upload allowlist contains the DMG, dSYM archive, checksums, dependency lock,
sanitized build manifest and minimal advisory test status. Internal Cloud links,
team configuration, submission IDs and notarization logs are not uploaded.
Notarization records are temporary private runner files; retrieve submission
history through the authorized Apple account if needed. Retain operational
records separately in private storage, never GitHub public release assets.

Signed apps still expose their certificate identity and notarization ticket by
design. Hiding logs does not hide that public verification information.

Changing this pipeline does not redact existing release assets or Git history.
Audit those separately before changing repository visibility.
