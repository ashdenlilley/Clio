using System.Net;
using System.Net.Http.Headers;

namespace Clio.Intelligence;

/// <summary>
/// Sends one evaluation request to TypeSafe and decodes the typed answers (macOS <c>TypeSafeClient</c>). This is the
/// only class in Clio that touches the network.
/// <para>
/// The key goes only into the <c>Authorization</c> header, over HTTPS. It is never put in an exception message, a log
/// line or the request body. Redirects are not followed, so a response cannot make Clio replay the key to another
/// host. Only the transient statuses TypeSafe documents (429, 529), 5xx and transport failures are retried, with
/// exponential backoff and the server's <c>retry-after</c> when it sends one.
/// </para>
/// </summary>
public sealed class TypeSafeClient
{
    public static readonly Uri DefaultEndpoint = new("https://api.typesafe.ai/v1/systemone");

    private readonly HttpClient _http;

    public Uri Endpoint { get; }
    public int MaximumAttempts { get; init; } = 3;
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>Injected so tests can drive backoff without waiting.</summary>
    public Func<TimeSpan, CancellationToken, Task> Sleep { get; init; } = Task.Delay;

    /// <param name="http">Defaults to a client that does not follow redirects. Tests pass one over a fake handler.</param>
    /// <param name="endpoint">Must be HTTPS.</param>
    public TypeSafeClient(HttpClient? http = null, Uri? endpoint = null)
    {
        Endpoint = endpoint ?? DefaultEndpoint;
        if (Endpoint.Scheme != Uri.UriSchemeHttps) throw new ArgumentException("TypeSafe requests must use HTTPS.", nameof(endpoint));
        _http = http ?? CreateDefaultHttpClient();
    }

    /// <summary>No redirects (the key must not be replayed to another host) and no cookies.</summary>
    public static SocketsHttpHandler CreateDefaultHandler() => new() { AllowAutoRedirect = false, UseCookies = false, UseProxy = true };

    public static HttpClient CreateDefaultHttpClient() =>
        new(CreateDefaultHandler())
        {
            // Per-attempt timeouts are applied by the client itself.
            Timeout = System.Threading.Timeout.InfiniteTimeSpan,
        };

    /// <exception cref="TypeSafeException">The request could not be completed.</exception>
    /// <exception cref="OperationCanceledException">The caller cancelled.</exception>
    public async Task<TypeSafeResponse> EvaluateAsync(TypeSafeRequest request, string apiKey, CancellationToken cancellationToken = default)
    {
        if (TypeSafeBudget.Overflow(request) is { } overflow)
            throw new TypeSafeException(TypeSafeErrorKind.RequestTooLarge, overflow);
        var body = request.ToBytes();
        cancellationToken.ThrowIfCancellationRequested();

        var attempt = 0;
        var last = new TypeSafeException(TypeSafeErrorKind.Transport);
        while (attempt < Math.Max(1, MaximumAttempts))
        {
            if (attempt > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await Sleep(Backoff(attempt, last), cancellationToken).ConfigureAwait(false);
            }
            attempt++;
            try
            {
                return await SendAsync(body, apiKey, cancellationToken).ConfigureAwait(false);
            }
            catch (TypeSafeException e) when (e.IsTransient)
            {
                last = e;
            }
        }
        throw last;
    }

    private async Task<TypeSafeResponse> SendAsync(byte[] body, string apiKey, CancellationToken cancellationToken)
    {
        using var message = new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = new ByteArrayContent(body) };
        message.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        // Answers are small and always fresh; never serve one from a cache.
        message.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);

        HttpResponseMessage response;
        byte[] data;
        try
        {
            response = await _http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            using (response) data = await response.Content.ReadAsByteArrayAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException)
        {
            // The exception text can name the host and the proxy but never carries the key; still, report generically.
            throw new TypeSafeException(TypeSafeErrorKind.Transport);
        }

        var status = (int)response.StatusCode;
        var retryAfter = response.Headers.TryGetValues("retry-after", out var values) ? values.FirstOrDefault() : null;
        if (TypeSafeResponseMapper.Error(status, retryAfter, data) is { } error) throw error;
        return TypeSafeResponse.Parse(data);
    }

    public static TimeSpan Backoff(int attempt, TypeSafeException after)
    {
        if (after.Kind == TypeSafeErrorKind.RateLimited && after.RetryAfter is { } retryAfter)
            return TimeSpan.FromSeconds(Math.Min(Math.Max(retryAfter.TotalSeconds, 0), 10));
        return TimeSpan.FromSeconds(Math.Min(Math.Pow(2, attempt - 1) * 0.5, 8));
    }
}
