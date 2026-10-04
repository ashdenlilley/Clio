using System.Diagnostics;
using Clio.Editor;
using Clio.Intelligence;

namespace Clio.App;

/// <summary>
/// Reformats a pasted block of plain text once structure recovery answers (macOS <c>PasteStructureController</c>). The
/// paste itself already happened: the writer sees their text land at once, and this replaces it a moment later only if the
/// passes found structure worth applying. The replacement is its own undo step, so a single Ctrl+Z takes back the
/// formatting and leaves the pasted text in place.
/// </summary>
public sealed class PasteStructureController
{
    private CancellationTokenSource? _cts;

    public bool IsRecovering { get; private set; }

    /// <summary>Raised on the UI thread when <see cref="IsRecovering"/> changes.</summary>
    public event Action? StateChanged;

    public void Cancel()
    {
        _cts?.Cancel();
        _cts = null;
        SetRecovering(false);
    }

    /// <summary>Starts recovery for a paste that just landed. Does nothing unless every gate is open.</summary>
    public void Recover(string pasted, TextRange range, EditorControl editor, IntelligenceService service)
    {
        Cancel();
        // The gates run before anything is built or sent: feature on, key stored, paste switch on, and a paste worth it.
        if (!service.IsReady || !service.FormatsPastes || !StructureRecovery.ShouldAttempt(pasted)) return;

        var cts = _cts = new CancellationTokenSource();
        var model = editor.Model;
        var clock = Stopwatch.StartNew();
        SetRecovering(true);
        _ = RunAsync(pasted, range, editor, model, service, clock, cts);
    }

    private async Task RunAsync(string pasted, TextRange range, EditorControl editor, EditorModel model, IntelligenceService service, Stopwatch clock, CancellationTokenSource cts)
    {
        try
        {
            var markdown = await service.RecoverStructureAsync(pasted, cts.Token);
            if (markdown is null || cts.IsCancellationRequested) return;
            // A different document, or any edit to the pasted text since, means the answer no longer applies.
            if (!ReferenceEquals(editor.Model, model) || !PasteRecoveryPolicy.CanApply(model.Buffer.Text, range, pasted, clock.Elapsed)) return;
            model.SetSelection(range.Start, range.End);
            model.Insert(markdown);
        }
        finally
        {
            if (ReferenceEquals(_cts, cts)) SetRecovering(false);
        }
    }

    private void SetRecovering(bool value)
    {
        if (IsRecovering == value) return;
        IsRecovering = value;
        StateChanged?.Invoke();
    }
}
