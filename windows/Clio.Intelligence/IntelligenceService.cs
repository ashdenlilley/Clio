using Clio.Editor.Commands;

namespace Clio.Intelligence;

/// <summary>Where the TypeSafe API key lives. Windows uses Credential Manager; tests use an in-memory store.</summary>
public interface IApiKeyStore
{
    /// <summary>The stored key, or null when there is none or it cannot be read.</summary>
    string? Load();

    /// <summary>Writes the key, or removes it when passed null. Returns whether the store accepted the change.</summary>
    bool Store(string? key);
}

/// <summary>The two switches that gate everything, persisted by the app. Both are plain preferences, never the key.</summary>
public interface IIntelligenceSettings
{
    /// <summary>The master switch. Off on first launch and after an upgrade, so an update never starts making requests.</summary>
    bool Enabled { get; set; }

    /// <summary>
    /// Whether a long unstructured paste may be offered as formatted Markdown. Separate from the master switch because it
    /// sends pasted text, while assisted commands send only what was typed into the command bar. Only ever runs behind
    /// <see cref="Enabled"/>.
    /// </summary>
    bool FormatPastes { get; set; }
}

/// <summary>Keeps a key only for the lifetime of the process.</summary>
public sealed class InMemoryApiKeyStore(string? initial = null) : IApiKeyStore
{
    private readonly object _gate = new();
    private string? _key = initial;

    public string? Load() { lock (_gate) return _key; }

    public bool Store(string? key) { lock (_gate) _key = key; return true; }
}

public sealed class InMemoryIntelligenceSettings : IIntelligenceSettings
{
    public bool Enabled { get; set; }
    public bool FormatPastes { get; set; } = true;
}

/// <summary>
/// Owns Clio's one outbound network capability (macOS <c>IntelligenceService</c>). Clio is a local-first editor and every
/// other part of it works with no network. Assisted commands and paste formatting are the exception, so they are off until
/// the writer turns them on and are gated in exactly one place: <see cref="EvaluateAsync"/> refuses before a request is
/// built whenever the feature is off or no key is stored. Callers treat a null result as "carry on locally", which is also
/// what they do offline.
/// <para>Use from the UI thread: it is not synchronised, and <see cref="Changed"/> fires on the calling context.</para>
/// </summary>
public sealed class IntelligenceService
{
    public enum KeyVerificationState { Unchecked, Checking, Valid, Invalid }

    private readonly IIntelligenceSettings _settings;
    private readonly IApiKeyStore _keys;
    private readonly TypeSafeClient _client;

    public IntelligenceService(IIntelligenceSettings settings, IApiKeyStore keys, TypeSafeClient? client = null)
    {
        _settings = settings;
        _keys = keys;
        _client = client ?? new TypeSafeClient();
        HasApiKey = keys.Load() is not null;
    }

    /// <summary>Raised whenever status text, the key state or a setting changes.</summary>
    public event Action? Changed;

    public bool IsEnabled
    {
        get => _settings.Enabled;
        set
        {
            if (_settings.Enabled == value) return;
            _settings.Enabled = value;
            if (value) RefreshKeyStatus(); else LastError = null;
            Changed?.Invoke();
        }
    }

    public bool FormatsPastes
    {
        get => _settings.FormatPastes;
        set
        {
            if (_settings.FormatPastes == value) return;
            _settings.FormatPastes = value;
            Changed?.Invoke();
        }
    }

    public bool HasApiKey { get; private set; }
    public KeyVerificationState KeyVerification { get; private set; }
    public string? KeyVerificationReason { get; private set; }
    public string? LastError { get; private set; }
    public bool IsEvaluating { get; private set; }

    /// <summary>Whether a request could be made right now. Callers check this before doing any work to build one.</summary>
    public bool IsReady => IsEnabled && HasApiKey;

    public string StatusDescription
    {
        get
        {
            if (!IsEnabled) return "Off. Clio makes no network requests.";
            if (!HasApiKey) return "No key stored. Add your own TypeSafe API key to finish setting this up.";
            switch (KeyVerification)
            {
                case KeyVerificationState.Checking: return "Checking the key…";
                case KeyVerificationState.Valid: return "Key checked and working.";
                case KeyVerificationState.Invalid: return KeyVerificationReason ?? "The key could not be checked.";
            }
            return LastError ?? "Key stored. Ready.";
        }
    }

    /// <summary>Re-reads whether a key is stored, so a read that came back empty at launch can be corrected later.</summary>
    public void RefreshKeyStatus()
    {
        HasApiKey = _keys.Load() is not null;
        if (!HasApiKey) KeyVerification = KeyVerificationState.Unchecked;
        Changed?.Invoke();
    }

    public void SetApiKey(string key)
    {
        var trimmed = key.Trim();
        if (trimmed.Length == 0) { ClearApiKey(); return; }
        var stored = _keys.Store(trimmed);
        HasApiKey = _keys.Load() is not null;
        // A new key has not been checked, whatever the last one's result was.
        KeyVerification = KeyVerificationState.Unchecked;
        KeyVerificationReason = null;
        LastError = stored ? null : "Clio could not store the key in Windows Credential Manager.";
        Changed?.Invoke();
    }

    public void ClearApiKey()
    {
        _keys.Store(null);
        HasApiKey = false;
        KeyVerification = KeyVerificationState.Unchecked;
        KeyVerificationReason = null;
        LastError = null;
        Changed?.Invoke();
    }

    /// <summary>
    /// Sends the smallest possible request to confirm the stored key works. Gated behind <see cref="IsEnabled"/> like every
    /// other request, so checking a key is still something the writer opts into.
    /// </summary>
    public async Task VerifyKeyAsync(CancellationToken cancellationToken = default)
    {
        if (!IsReady)
        {
            KeyVerification = KeyVerificationState.Invalid;
            KeyVerificationReason = new TypeSafeException(TypeSafeErrorKind.MissingApiKey).Message;
            Changed?.Invoke();
            return;
        }
        KeyVerification = KeyVerificationState.Checking;
        Changed?.Invoke();
        var probe = TypeSafeRequest.WithState("ping", new Dictionary<string, TypeSafeQuestion>
        {
            ["reachable"] = TypeSafeQuestion.Noul("Is this text in English?"),
        });
        try
        {
            await EvaluateAsync(probe, cancellationToken).ConfigureAwait(true);
            KeyVerification = KeyVerificationState.Valid;
            KeyVerificationReason = null;
        }
        catch (TypeSafeException e)
        {
            KeyVerification = KeyVerificationState.Invalid;
            KeyVerificationReason = e.Message;
        }
        catch (OperationCanceledException)
        {
            KeyVerification = KeyVerificationState.Unchecked;
        }
        Changed?.Invoke();
    }

    // ---- evaluation -------------------------------------------------------------------------------

    /// <exception cref="TypeSafeException">Off, no key, or the service failed.</exception>
    public async Task<TypeSafeResponse> EvaluateAsync(TypeSafeRequest request, CancellationToken cancellationToken = default)
    {
        if (!IsEnabled) throw new TypeSafeException(TypeSafeErrorKind.Disabled);
        if (_keys.Load() is not { } key)
        {
            HasApiKey = false;
            throw new TypeSafeException(TypeSafeErrorKind.MissingApiKey);
        }
        IsEvaluating = true;
        try
        {
            var response = await _client.EvaluateAsync(request, key, cancellationToken).ConfigureAwait(true);
            LastError = null;
            return response;
        }
        catch (TypeSafeException e)
        {
            LastError = e.Message;
            throw;
        }
        finally
        {
            IsEvaluating = false;
            Changed?.Invoke();
        }
    }

    // ---- assisted commands ------------------------------------------------------------------------

    /// <summary>
    /// Matches a natural-language palette request to a command, or returns null when nothing matched well enough. Never
    /// throws: the palette's own substring filtering stays in charge, and a failure here is silent.
    /// </summary>
    public async Task<CommandIntentResult?> ResolveCommandAsync(string text, CommandIntentContext context, CancellationToken cancellationToken = default)
    {
        if (!IsReady) return null;
        var trimmed = text.Trim();
        if (trimmed.Length < CommandIntentResolver.MinimumRequestCharacters) return null;
        try
        {
            var response = await EvaluateAsync(CommandIntentResolver.Request(trimmed, context), cancellationToken).ConfigureAwait(true);
            return CommandIntentResolver.Resolve(response);
        }
        catch (Exception e) when (e is TypeSafeException or OperationCanceledException)
        {
            return null;
        }
    }

    // ---- structure recovery -----------------------------------------------------------------------

    /// <summary>
    /// Rebuilds Markdown structure for a pasted block of plain text, or returns null when the paste does not need it or
    /// the passes could not run. The two requests are sequential because the blocks classified by the second do not exist
    /// until the first has answered.
    /// </summary>
    public async Task<string?> RecoverStructureAsync(string pasted, CancellationToken cancellationToken = default)
    {
        if (!IsReady || !FormatsPastes || !StructureRecovery.ShouldAttempt(pasted)) return null;

        var lines = StructureRecovery.Lines(pasted);
        if (lines.Count < 3) return null;

        try
        {
            var stitched = await EvaluateAsync(StructureRecovery.StitchRequest(lines), cancellationToken).ConfigureAwait(true);
            var joins = StructureRecovery.Joins(stitched, lines.Count);
            var blocks = StructureRecovery.Merge(lines, joins);

            cancellationToken.ThrowIfCancellationRequested();

            var classified = await EvaluateAsync(StructureRecovery.ClassifyRequest(blocks), cancellationToken).ConfigureAwait(true);
            var judgments = StructureRecovery.Judgments(classified, blocks.Count);

            var markdown = StructureRecovery.Render(blocks, judgments);
            // Nothing was recovered if the result is the paste again.
            return markdown == pasted.Trim() ? null : markdown;
        }
        catch (Exception e) when (e is TypeSafeException or OperationCanceledException)
        {
            return null;
        }
    }
}
