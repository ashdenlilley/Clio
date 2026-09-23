# Liquid Glass visual audit

Screenshot pass over every glass surface after the macOS 26 Liquid Glass
conversion. Captured by `ClioUITests/ClioVisualAuditUITests`, which is skipped
unless the runner sees `CLIO_VISUAL_AUDIT=1`:

```bash
TEST_RUNNER_CLIO_VISUAL_AUDIT=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Clio.xcodeproj -scheme Clio -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData/UITests -only-testing:ClioUITests/ClioVisualAuditUITests \
  -resultBundlePath "$SCRATCH/audit.xcresult" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
xcrun xcresulttool export attachments --path "$SCRATCH/audit.xcresult" --output-path "$SCRATCH/audit"
```

Screenshots are not committed. They show the isolated test workspace folder
name and can show local paths; per `docs/testing.md`, redact before sharing.

The audit launches with `-ApplePersistenceIgnoreState YES`, and UI-testing
launches no longer save window frames, so entering full screen or pinning the
minimum window size does not leak into later launches.

Seeded state: `CLIO_UI_TEST_SCENARIO=missing-restore` (UI testing only)
restores a tab whose file does not exist, which shows the detached-document
banner.

## Findings

| # | Surface | Checklist item | Finding | Result |
|---|---------|----------------|---------|--------|
| 1 | Window titlebar | Black base | A 32 pt band in the system window colour (about `#1F1F1F`) sat above the black editor, since the SDK 26 bump. The SwiftUI window container painted its default background behind the transparent titlebar. | Fixed (c5e4044): `.containerBackground(Palette.background, for: .window)` on the editor scene. The whole window, titlebar included, is black; traffic lights and the glass sidebar button float over it. |
| 2 | Banners over sidebar | 1 glass-on-glass, 4 text contrast | The banner card spanned the full window width, so its glass lay over the sidebar glass and the two surfaces' text overlapped ("New Document" under the banner message), windowed and in full screen. | Fixed (bc2af3c): banners take a leading inset that follows the sidebar's presentation progress, so they sit beside the panel and slide back to full width when it hides. |
| 3 | Export options sheet | 2 clipped content | The segmented format picker (equal-width segments plus an inline label on macOS 26) was wider than the 460 pt sheet, pushing the title, page setup and Cancel off the left edge. | Fixed (bc2af3c): picker label hidden; sheet 540 pt wide. |
| 4 | Sidebar panel | 1, 3 | Over black the panel reads as a neutral dark glass slab. When the sidebar overlays (unpinned) the editor, the text under it shows as a soft blur. | Accepted: this is `.regular` glass sampling what is behind it. Once the grey titlebar was gone the panel no longer reads as a flat slab against a grey band. Pinning keeps text clear of it (existing layout). No tint change. |
| 5 | Palette, search, Settings over the sidebar or text | 1, 4 | The panel refracts the sidebar edge and faint text behind it. | Accepted: the scrim darkens the background and panel text stays clearly legible. |
| 6 | Status capsule, sidebar, titlebar button fades | 5 | At rest after a typing burst the window is pure black: no grey capsule, sidebar or button remnants. A mid-slide sidebar frame shows content moving with its glass. | Pass at rest. Mid-fade frames of the capsule and titlebar button were not caught: a window screenshot takes longer than the 300 ms fade. No `glassEffectTransition` added without evidence. |
| 7 | Minimap vs status capsule | 6 | The capsule's 48 pt horizontal padding keeps it clear of the 32 pt minimap. | Pass. |
| 8 | Banner at minimum width (480 pt) with sidebar | 7 | With the sidebar inset the banner is narrow and wraps to several lines. It stays readable and doesn't overlap anything. | Pass (tall, accepted). |
| 9 | Settings at 480 × 400 | 8 | The category column collapses to icons, controls aren't truncated and Done is reachable. | Pass. |
| 10 | Full screen | 10 | The sidebar and banners start 8–12 pt from the top edge with no titlebar gap. The banner sits beside the sidebar. | Pass (after fix 2). |
| 11 | Minimum window status capsule | 1 | At 480 pt the overlay sidebar covers the left part of the capsule. | Open (minor): the overlay sidebar covers the capsule by design. Pinning or hiding the sidebar clears it. |
| 12 | Reduce Transparency | 9 | Needs the system setting turned on. | Not captured: needs someone to turn the setting on. |
| 13 | Reduce Motion | 5, 9 | Needs the system setting turned on. | Not captured: needs someone to turn the setting on. |

The caret sometimes has a small round glass badge beside it in the
screenshots. That is the system text-insertion (input source) indicator, not
Clio chrome.

## Surface × checklist

`P` pass · `F` fixed (see findings) · `A` accepted as Liquid Glass behaviour · `O` open · `—` not applicable · `N` not captured

| Surface | 1 glass-on-glass | 2 clipping | 3 halos | 4 contrast | 5 fade | 6 minimap | 7 banners narrow | 8 settings min | 9 Reduce Transparency | 10 full screen |
|---------|---|---|---|---|---|---|---|---|---|---|
| Titlebar and sidebar button | P | P | P | P | P | — | — | — | N | F |
| Sidebar | A | P | P | P | P | — | — | — | N | P |
| Command palette / inline slash | A | P | P | P | P | — | — | — | N | P |
| Workspace search | A | P | P | P | P | — | — | — | N | — |
| Settings (7 categories) | A | P | P | P | — | — | — | P | N | — |
| Export sheet | P | F | P | P | — | — | — | — | N | — |
| Detached-document banner | F | P | P | F | — | — | P | — | N | F |
| Status capsule | O | P | P | P | P | P | — | — | N | P |
| Conflict strip and sheet | N | N | N | N | N | — | N | — | N | N |

The conflict strip and sheet were not captured. Seeding an outside-change
conflict needs an external write racing the file watcher. It uses the same
`BannerCard` and `.panel` glass as the captured surfaces.
