using System.Net;
using System.Net.Sockets;

namespace Clio.Mcp;

/// <summary>
/// Loopback-only listener. Binds <c>127.0.0.1</c> exclusively (never <c>Any</c>, never IPv6, never a LAN
/// address), refuses a second process sharing the port, drops any peer that is not loopback, and handles
/// one length-delimited request per connection. Authentication happens in the handler.
/// </summary>
public sealed class McpHttpServer : IDisposable
{
    private static readonly TimeSpan HeadTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan HandlerTimeout = TimeSpan.FromSeconds(120);

    private readonly object _lock = new();
    private readonly HashSet<TcpClient> _connections = [];
    private TcpListener? _listener;
    private CancellationTokenSource? _stop;

    public McpHttpServer(ushort port = McpLimits.Port) => RequestedPort = port;

    public ushort RequestedPort { get; }

    /// <summary>The bound port, valid while listening. Differs from <see cref="RequestedPort"/> only when that is 0.</summary>
    public ushort Port { get; private set; }

    public bool IsListening { get { lock (_lock) return _listener is not null; } }

    public Func<McpHttpRequest, Task<McpHttpResponse>>? Handler { get; set; }

    /// <summary>Raised when the listener stops on its own, for example after an accept failure.</summary>
    public event Action<string>? Failed;

    /// <summary>Throws <see cref="SocketException"/> when the port is taken.</summary>
    public void Start()
    {
        Stop();
        var listener = new TcpListener(IPAddress.Loopback, RequestedPort) { ExclusiveAddressUse = true };
        listener.Start(backlog: 16);
        var stop = new CancellationTokenSource();
        lock (_lock)
        {
            _listener = listener;
            _stop = stop;
            Port = (ushort)((IPEndPoint)listener.LocalEndpoint).Port;
        }
        _ = Task.Run(() => AcceptLoopAsync(listener, stop.Token));
    }

    public void Stop()
    {
        TcpListener? listener;
        CancellationTokenSource? stop;
        List<TcpClient> open;
        lock (_lock)
        {
            listener = _listener; stop = _stop;
            _listener = null; _stop = null;
            open = [.. _connections];
            _connections.Clear();
        }
        stop?.Cancel();
        try { listener?.Stop(); } catch (SocketException) { }
        foreach (var connection in open) connection.Dispose();
        stop?.Dispose();
    }

    public void Dispose() => Stop();

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken stop)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stop);
                bool admit;
                lock (_lock) admit = _connections.Count < McpLimits.MaximumConnections && ReferenceEquals(_listener, listener)
                    && client.Client.RemoteEndPoint is IPEndPoint { Address: var peer } && IPAddress.IsLoopback(peer);
                if (!admit) { client.Dispose(); continue; }
                lock (_lock) _connections.Add(client);
                _ = Task.Run(() => ServeAsync(client, stop));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is SocketException or ObjectDisposedException or InvalidOperationException)
        {
            if (!stop.IsCancellationRequested)
            {
                lock (_lock) { if (ReferenceEquals(_listener, listener)) { _listener = null; } }
                Failed?.Invoke("Unable to listen. The port may be in use.");
            }
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken stop)
    {
        try
        {
            using var _ = client;
            var stream = client.GetStream();
            McpHttpRequest? request = null;
            var received = new List<byte>();
            var buffer = new byte[16_384];
            using var head = CancellationTokenSource.CreateLinkedTokenSource(stop);
            head.CancelAfter(HeadTimeout);
            try
            {
                while (request is null)
                {
                    var count = await stream.ReadAsync(buffer, head.Token);
                    if (count == 0) return;
                    received.AddRange(buffer.AsSpan(0, count));
                    request = McpHttpRequest.Decode(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(received), Port);
                }
            }
            catch (McpException error)
            {
                await SendAsync(stream, new McpHttpResponse(McpHttpRequest.StatusFor(error)), stop);
                return;
            }
            catch (OperationCanceledException) { return; }

            // A disconnect is NOT cancellation: the router owns in-flight work and replay state.
            using var work = CancellationTokenSource.CreateLinkedTokenSource(stop);
            work.CancelAfter(HandlerTimeout);
            McpHttpResponse response;
            try
            {
                var handler = Handler;
                response = handler is null ? new McpHttpResponse(503) : await handler(request).WaitAsync(work.Token);
            }
            catch (OperationCanceledException) { response = new McpHttpResponse(503); }
            catch (Exception) { response = new McpHttpResponse(503); }
            await SendAsync(stream, response, stop);
        }
        catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
        {
            // The peer went away. Nothing to report: its work, if any, is owned by the router.
        }
        finally
        {
            lock (_lock) _connections.Remove(client);
        }
    }

    private static async Task SendAsync(NetworkStream stream, McpHttpResponse response, CancellationToken stop)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop);
        timeout.CancelAfter(HeadTimeout);
        await stream.WriteAsync(response.Encode(), timeout.Token);
        await stream.FlushAsync(timeout.Token);
    }
}
