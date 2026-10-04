namespace Clio.Core;

public sealed class AutosaveBusyException()
    : ClioException("Wait for the current file operation to finish, then save again.");

/// <summary>
/// Debounced, serial autosave (macOS <c>Autosaver</c>). Every edit is queued for the crash journal at once and
/// saved after a quiet <see cref="Delay"/>; rapid edits coalesce into the newest revision and at most one write is in
/// flight. A conflict or a deleted file stops autosave for that document until the user acts. File operations such
/// as moves suspend autosave, then await the write already in flight before touching paths.
/// Documents with no file yet are journaled but never written: choosing a location is the app's decision.
/// </summary>
public sealed class Autosaver(DocumentService service, TimeSpan? delay = null) : IDisposable
{
    public static readonly TimeSpan DefaultDelay = TimeSpan.FromMilliseconds(400);

    private readonly object _lock = new();
    private readonly TimeSpan _delay = delay ?? DefaultDelay;
    private Timer? _debounce;
    private Task? _saveTask;
    private DocumentSession? _pending;
    private ulong _generation;
    private int _suspension;
    private string? _lastSavedPath;
    private Exception? _lastError;
    private int _attempts;

    public TimeSpan Delay => _delay;
    public Exception? LastError { get { lock (_lock) return _lastError; } }
    public int SaveAttemptCount { get { lock (_lock) return _attempts; } }
    public bool HasPendingSave { get { lock (_lock) return _pending is not null || _debounce is not null || _saveTask is not null; } }
    public bool HasActiveFileIO { get { lock (_lock) return _saveTask is not null; } }

    /// <summary>Records an editor mutation: journal it now, save it after the debounce.</summary>
    public void DocumentDidChange(DocumentSession session)
    {
        if (!session.IsDirty) return;
        service.ScheduleCrashRecovery(session);

        lock (_lock)
        {
            if (_suspension > 0)
            {
                _pending = session;
                _lastError = null;
                return;
            }
            // Deleted and trashed files stay detached until a deliberate restore: typing must never resurrect them.
            if (session.RequiresExplicitRestore || !session.IsBackedByFile)
            {
                CancelLocked();
                return;
            }
            if (session.IsAutosavePaused)
            {
                _pending = null;
                StopDebounce();
                return;
            }
            _pending = session;
            _lastError = null;
            _generation++;
            StopDebounce();
            if (_saveTask is not null) return; // the running drain picks the newest revision up
            ArmDebounce(_generation);
        }
    }

    /// <summary>Saves the pending revision now (Ctrl+S, window close). Waits for a write already in flight.</summary>
    public string? Flush(DocumentSession? session = null)
    {
        Task? running;
        lock (_lock)
        {
            if (session is { IsDirty: true }) _pending = session;
            if (_suspension > 0) throw new AutosaveBusyException();
            _generation++;
            StopDebounce();
            running = _saveTask;
        }
        running?.Wait();

        DocumentSession? document;
        lock (_lock)
        {
            document = _pending;
            _pending = null;
        }
        if (document is null) return session?.Path ?? _lastSavedPath;
        try
        {
            var path = service.Save(document);
            lock (_lock) { _lastSavedPath = path; _lastError = null; }
            return path;
        }
        catch (Exception e)
        {
            lock (_lock)
            {
                _lastError = e;
                if (!StopsAutosave(e) && document.IsDirty) _pending = document;
            }
            throw;
        }
    }

    /// <summary>Like <see cref="Flush"/> but awaitable: rapid edits coalesce and one write runs at a time.</summary>
    public async Task<string?> FlushAsync(DocumentSession? session = null)
    {
        lock (_lock)
        {
            if (session is { IsDirty: true }) _pending = session;
            if (_suspension > 0) throw new AutosaveBusyException();
            _generation++;
            StopDebounce();
            _lastError = null;
            StartSave();
        }
        await SettlePendingFileIOAsync();
        lock (_lock)
        {
            if (_lastError is { } error) throw error;
            if (_pending is not null) throw new AutosaveBusyException();
            return _lastSavedPath ?? session?.Path;
        }
    }

    /// <summary>Awaits the write already in flight. File moves and watcher reconciliation call this after suspending.</summary>
    public async Task SettlePendingFileIOAsync()
    {
        while (true)
        {
            Task? task;
            lock (_lock) task = _saveTask;
            if (task is null) return;
            await task;
        }
    }

    public void Cancel()
    {
        lock (_lock) CancelLocked();
    }

    public void SuspendForFileOperation()
    {
        lock (_lock)
        {
            if (++_suspension != 1) return;
            _generation++;
            StopDebounce();
        }
    }

    public void ResumeAfterFileOperation()
    {
        DocumentSession? resume = null;
        lock (_lock)
        {
            if (_suspension == 0 || --_suspension != 0 || _pending is not { } pending) return;
            if (!pending.IsDirty)
            {
                _pending = null;
                _lastError = null;
                return;
            }
            resume = pending;
        }
        DocumentDidChange(resume);
    }

    public void Dispose()
    {
        lock (_lock) StopDebounce();
    }

    // ---- internals ------------------------------------------------------------------------------

    private void CancelLocked()
    {
        _generation++;
        StopDebounce();
        _pending = null;
    }

    private void StopDebounce()
    {
        _debounce?.Dispose();
        _debounce = null;
    }

    private void ArmDebounce(ulong scheduled)
    {
        _debounce = new Timer(_ =>
        {
            lock (_lock)
            {
                if (_generation != scheduled) return;
                StopDebounce();
                StartSave();
            }
        }, null, _delay, Timeout.InfiniteTimeSpan);
    }

    private void StartSave()
    {
        if (_saveTask is not null || _suspension > 0 || _pending is null) return;
        StopDebounce();
        _saveTask = Task.Run(Drain);
    }

    private async Task Drain()
    {
        try
        {
            while (true)
            {
                DocumentSession document;
                lock (_lock)
                {
                    if (_suspension > 0 || _pending is null) return;
                    document = _pending;
                    _pending = null;
                    _attempts++;
                }
                try
                {
                    var path = service.Save(document);
                    lock (_lock)
                    {
                        _lastSavedPath = path;
                        _lastError = null;
                    }
                }
                catch (Exception e)
                {
                    lock (_lock)
                    {
                        _lastError = e;
                        // A conflict or deletion needs the user; any other failure retries while the buffer is dirty.
                        if (!StopsAutosave(e) && document.IsDirty) _pending = document;
                    }
                    return;
                }
                await Task.Yield();
            }
        }
        finally
        {
            lock (_lock)
            {
                _saveTask = null;
                if (_suspension == 0 && _pending is not null && _lastError is null) ArmDebounce(_generation);
            }
        }
    }

    private static bool StopsAutosave(Exception e) =>
        e is ExternalConflictException or DocumentDeletedException or DetachedDocumentException or UnbackedDocumentException;
}
