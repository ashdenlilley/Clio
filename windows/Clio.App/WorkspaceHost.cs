using Clio.Core;
using Microsoft.UI.Dispatching;

namespace Clio.App;

/// <summary>
/// One open folder: its watcher, and the pump that hands batches of events to the search index and then to the UI.
/// Events arrive on the dispatcher thread, after the index has applied them.
/// </summary>
public sealed class WorkspaceHost : IDisposable
{
    private readonly WorkspaceWatcher _watcher;
    private readonly CancellationTokenSource _cts = new();
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();

    public Guid Id { get; }
    public string Root { get; }
    public string DisplayName => Path.GetFileName(Root) is { Length: > 0 } name ? name : Root;

    /// <summary>Batches of observed changes, on the UI thread.</summary>
    public event Action<IReadOnlyList<WorkspaceEvent>>? EventsObserved;

    public WorkspaceHost(Guid id, string root, bool includeText, SearchIndex search, SemaphoreSlim indexGate)
    {
        Id = id;
        Root = AppPaths.Normalize(root);
        _watcher = new WorkspaceWatcher(id, Root, includeText);
        _ = Task.Run(() => Pump(search, indexGate));
    }

    private async Task Pump(SearchIndex search, SemaphoreSlim indexGate)
    {
        var reader = _watcher.Events;
        try
        {
            while (await reader.WaitToReadAsync(_cts.Token))
            {
                var batch = new List<WorkspaceEvent>();
                // Let a burst (a save is several raw events) settle into one batch.
                await Task.Delay(60, _cts.Token);
                while (reader.TryRead(out var e)) batch.Add(e);
                if (batch.Count == 0) continue;

                await indexGate.WaitAsync(_cts.Token);
                try { await search.ApplyAsync(batch, _cts.Token); }
                catch (Exception e) when (e is SearchIndexException or OperationCanceledException or IOException or ObjectDisposedException) { }
                finally { indexGate.Release(); }

                _ui.TryEnqueue(() => EventsObserved?.Invoke(batch));
            }
        }
        catch (OperationCanceledException) { }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _watcher.Dispose();
        _cts.Dispose();
    }
}
