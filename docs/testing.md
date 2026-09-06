# Testing

Use Xcode's Test action with the shared Clio scheme. Unit and UI tests use
isolated fixtures: never point test cases at a writer's real documents, folder
bookmarks, recovery store or preferences.

Native UI tests require an unlocked interactive macOS desktop. Do not run
multiple UI suites with the same app bundle ID concurrently; they can steal
focus or terminate each other's app.

The test-only crash probe exercises recovery and atomic writes without shipping
a test helper in the application. Performance and stress tests are opt-in and
require sufficient disk space for disposable workspace/index fixtures.

`scripts/test.sh` is a development helper. Official CI and distribution run in
Xcode Cloud. Signing/notarization checks do not establish application correctness,
and automated tests do not replace manual accessibility, trackpad, fullscreen,
or fresh-download installation checks.

Reports shared publicly must be redacted: remove document text, personal paths,
account identifiers and internal build links.
