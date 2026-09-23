# Clio

A local-first Markdown writing app for macOS. Clio keeps your documents as plain
`.md` files in folders you control, with a quiet black canvas and controls that
fade while you write.

## Writing workspace

- Source-preserving Markdown highlighting and keyboard-driven slash commands.
- Multiple documents in a vertical sidebar, with separate windows when needed.
- Search across selected workspace folders and move documents between them.
- Focus dimming, typewriter scrolling and a compact document minimap.
- PDF, self-contained HTML, editable Word (.docx), and readable UTF-8 text (.txt) export.
- Word count, reading time and speaking time estimates.
- Autosave, external-edit conflict handling and recovery copies.
- Optional assisted commands and paste formatting, off by default.

Clio 1.0 is the first stable release. Builds still labelled **Internal testing**
or **Pre-release** are evaluation builds, not a promise of production readiness.
Keep independent backups of important documents. Automated test outcomes and
notarization are different checks: notarization is not a guarantee of correctness.
See the [changelog](CHANGELOG.md) for what changed.

## Download

See [GitHub Releases](https://github.com/ashdenlilley/Clio/releases) for available
builds and their notes. Download the DMG, open it, and drag Clio to Applications.
Published release images support Apple silicon and Intel Macs running macOS 14
or later.

On first launch, approve a workspace folder. The default is `~/Documents/Clio`.
Recovery copies are kept in `~/Documents/Clio Recovery` for seven days. Documents
in an iCloud-synced Documents folder follow your macOS sync settings.

The sidebar’s **New Document** button asks for a name and location, then opens the
created file. Double-click a sidebar document name or choose **Rename** from its
context menu to rename it. Expand folders to follow the connected file tree.
**Command-N** opens an untitled tab in the current window. **New Window** opens a blank
document in a separate window. Type `/` for commands or use **Command-K**.
Focus mode dims surrounding text; typewriter mode keeps the typing line at an
adjustable position. Manually scrolling releases that position until you type.

Clio makes no network requests of its own. Settings offers two optional features
that do: assisted commands, which read a typed request like "send this to my
editor in Word" when no command name matches, and paste formatting, which
rebuilds Markdown structure in pasted plain text. Both are off until you enable
them and add a TypeSafe API key, and both fall back to Clio's local behaviour
when off or offline. See [assisted commands](docs/assisted-commands.md) for
exactly what each one sends.

## Development

Open `Clio.xcodeproj` and select the `Clio` scheme. The generated project and
dependency lockfile are checked in. Xcode 26 is used for current release builds;
the deployment target is macOS 14. Configure your own signing team when needed.
Release credentials are not required to work on the editor or run its tests.

If you change `project.yml`, regenerate with XcodeGen 2.46 or newer:

```sh
xcodegen generate
```

Use Xcode's Test action for the shared scheme. See [testing](docs/testing.md)
for fixture isolation and [release automation](docs/releasing.md) for the
separate, maintainer-controlled distribution process. The assisted-command and
paste-formatting tests use a stubbed transport and never reach the network.

## Source layout

- `Clio/App` — application lifecycle, windows, settings and navigation
- `Clio/Editor` — AppKit/TextKit 2 editor and scrolling
- `Clio/Workspace` — document access, recovery, watchers and search
- `Clio/Markdown` — parsing, highlighting and source-preserving edits
- `Clio/Export` — PDF, HTML, Word, and plain-text exporters
- `Clio/Experience` — interface motion and focus behaviour
- `Clio/Intelligence` — optional TypeSafe client, command intent and paste formatting
- `ClioTests`, `ClioUITests` — automated regression coverage

## Feedback and security

For bugs, include your macOS version, Clio version and minimal reproduction
steps. Remove document contents, personal paths and account information from
screenshots and logs before sharing. Do not post credentials in issues or pull
requests. See [security guidance](SECURITY.md).

Bundled dependencies and fonts retain their own licenses; see
[third-party notices](Clio/Resources/THIRD-PARTY-NOTICES.md). No license for
Clio's own source code is granted by this README.
