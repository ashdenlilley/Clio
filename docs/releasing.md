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

## Windows (unsigned, GitHub Actions)

The Windows port ships separately from the macOS pipeline above. It is **unsigned**: no
certificate or secret is involved, and nothing in the workflow publishes automatically.

- **Version:** read from `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) by
  `scripts/windows-version.ps1`, so the Windows and macOS apps share one number. A tag build fails
  if `vX.Y.Z` differs from `MARKETING_VERSION`.
- **Local build:** `pwsh scripts/windows-release.ps1` writes to `windows/artifacts/release`
  (git-ignored): `Clio-<version>-win-x64.zip`, `Clio-<version>-win-x64-setup.exe` and
  `SHA256SUMS-windows.txt`. The installer needs Inno Setup 6 (`-RequireInstaller` makes its absence
  an error). The zip holds `Clio.exe`, `clio-mcp-bridge.exe`, the third-party notices and the Hack font
  licence.
- **Smoke test:** `pwsh scripts/windows-smoke.ps1 -Asset <zip or setup.exe>` installs to a temp
  directory, launches Clio, checks it stays up, closes the window and checks for a clean exit. For the
  installer it then uninstalls and checks the files, the uninstall entry and the `Clio.Markdown`
  association key are gone. It removes `%LOCALAPPDATA%\Clio` afterwards only if the run created it.
- **CI:** `.github/workflows/windows.yml` runs on `windows-latest` for Windows-related pushes and pull
  requests: build, all test projects, package, checksum check, zip and installer smoke tests, artifact
  upload. On a canonical `vMAJOR.MINOR.PATCH` tag a final job creates a **draft** release, or adds assets
  to an existing release without overwriting any asset. A maintainer reviews and publishes it by hand.
  The tag also starts the macOS Xcode Cloud workflow; the two share no code or secrets.
- **Install behaviour:** per-user (`%LOCALAPPDATA%\Programs\Clio`), no administrator, Start Menu entry.
  Uninstall removes the app and the opt-in Markdown "Open with" registration. It keeps settings, recovery
  copies and the search index in `%LOCALAPPDATA%\Clio`, and never touches documents.

### SmartScreen and verification (users)

Because the build is unsigned, Windows SmartScreen shows "Windows protected your PC" on first run, and
browsers may flag the download. This is expected. To proceed:

1. Download the asset and `SHA256SUMS-windows.txt` from the GitHub release.
2. Verify: `(Get-FileHash .\Clio-<version>-win-x64-setup.exe -Algorithm SHA256).Hash` must equal the
   matching line in the checksums file (case-insensitive).
3. Run the installer or `Clio.exe`, choose **More info**, then **Run anyway**. For a downloaded zip you
   can instead right-click it, open Properties, tick **Unblock**, then extract.

The checksum proves the file matches what the release listed, not who built it. Only install from this
repository's releases.

### Clean-VM install checklist (manual, before publishing a draft)

Run on a fresh Windows 11 (22000+) x64 VM with no .NET, Windows App SDK or developer tools:

1. Verify the SHA-256 of the installer and zip against `SHA256SUMS-windows.txt`.
2. Install without administrator rights; confirm the Start Menu entry and that Clio launches.
3. Open a folder of Markdown files, edit, save, close and reopen; confirm text and file are intact.
4. Check `/export` to PDF, HTML, DOCX and TXT, and search, on a few documents.
5. Run the zip build from a different folder; confirm it runs without installing anything.
6. Optional features: enable the `.md` association, then uninstall and confirm the registration is gone.
7. Uninstall; confirm the install folder, Start Menu entry and uninstall entry are gone and documents
   are untouched.
8. Record the Windows build, results and any SmartScreen behaviour in the release notes.
