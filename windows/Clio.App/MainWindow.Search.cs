using Clio.Core;
using Clio.Editor;
using Microsoft.UI.Xaml;

namespace Clio.App;

/// <summary>Quick open and workspace search overlay hosting.</summary>
public sealed partial class MainWindow
{
    private void InitSearch()
    {
        SearchPanel.ResultChosen += OnSearchResultChosen;
        SearchPanel.Dismissed += () => Editor.Focus(FocusState.Programmatic);
    }

    private void ShowSearch(SearchMode mode, string query = "")
    {
        if (Palette.Palette.IsPresented) Palette.Palette.Dismiss();
        SearchPanel.Show(mode, query);
    }

    private void OnSearchResultChosen(string path, TextSpan? match)
    {
        if (OpenPath(path) is null) return;
        // The match range is in the document's text; it is only valid while the text is what the index read.
        if (match is { } span && span.Start + span.Length <= Editor.Model.Buffer.Length)
            Editor.Model.SetSelection(span.Start, span.Start + span.Length);
        Editor.Focus(FocusState.Programmatic);
    }
}
