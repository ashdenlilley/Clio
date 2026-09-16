# Sidebar document workflow

## Agreed behavior

- The sidebar's top **New Document** button asks for a name and destination using the native macOS save panel. Create opens and selects the new empty document; Cancel adds no file or tab. The destination defaults to the active document's folder, falling back to the first workspace. The existing keyboard/menu untitled-document flow remains available.
- Editable text retains native I-beam and caret behavior. Clickable sidebar rows, folders, creation/close buttons, titlebar sidebar toggle, and custom palette actions use the hand pointer. Blank, noninteractive chrome uses the arrow.
- Double-click a document or choose **Rename** from its context menu to edit its name inline. Enter saves; Escape or leaving the field cancels. Invalid or occupied names remain editable with an error. Missing extensions inherit the original extension. Renaming retains the containing folder, document identity, and contents.
- Expandable folders use connector lines, consistent indentation, folder icons, and highlighted selection. Ancestors of the active document expand automatically. The open-document list scrolls to the newly selected tab. Existing drag-and-drop folder moves remain available.

## Implementation

`WorkspaceSidebar` owns presentation, expansion, inline editing, and cursor feedback. `AppState` coordinates creation/opening and rename/index updates. `DocumentFilename` validates names and exclusively creates the empty destination under the save panel's exact-file grant. `EditorSession.rename` settles pending edits and uses the existing `DocumentMover` transaction while preserving the source parent path. Navigation changes continue through the existing index coordinator.

Documents created outside an authorized workspace use the existing exact-file access flow, which offers to add the parent folder to navigation. Declining that offer leaves the document open in the open-document list.

## Verification

Regression coverage added to `NavigationSessionTests`:

- Filename/path rejection and extension handling.
- Exclusive creation in a nested folder; duplicate and missing-parent failures leave existing bytes intact.
- Inline rename collision handling and successful nested rename preserve identity, contents, and location.

UI coverage added to `ClioNavigationUITests`:

- Cancel New Document without adding a tab.
- Double-click rename, Escape cancellation, context-menu rename, and unchanged editor text.

Local Swift source parsing and whitespace checks are performed before handoff. In keeping with the repository's Cloud-only repair workflow, compilation and unit/UI execution are pending Xcode Cloud; syntax checks do not establish runtime correctness.

## Interactive acceptance in Cloud

1. Create a named document in an existing nested workspace folder. Verify selection, expanded ancestors, caret focus, editing, autosave, and reopen.
2. Repeat outside the workspace, accepting and declining the parent-folder offer. Cancel creation and try an occupied destination; verify no existing file changes.
3. Rename from both open documents and the workspace tree, including a closed file. Check Enter, Escape, focus-loss cancellation, empty names, path characters, duplicate names, and unsaved edits.
4. Observe cursor changes between blank chrome, text fields/editor, sidebar buttons, folder toggles, and the titlebar toggle. Check pointer exit and sidebar dismissal.
5. Expand and collapse several nested branches. Check connector continuity, selected-row contrast, long names, keyboard focus, VoiceOver labels, and drag-and-drop moves.
