using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Clio.Mcp;

public sealed record McpClientInfo(Guid Id, string Name, IReadOnlySet<Guid> WorkspaceIds);

/// <summary>A client with its secret. The token never leaves this library except through the explicit config helpers.</summary>
public sealed record McpStoredClient(Guid Id, string Name, IReadOnlySet<Guid> WorkspaceIds, byte[] Token)
{
    public McpClientInfo Info => new(Id, Name, WorkspaceIds);
}

/// <summary>Where client tokens live. The Windows implementation is Credential Manager.</summary>
public interface ICredentialVault
{
    byte[]? Read(string target);
    void Write(string target, string userName, byte[] secret);
    void Delete(string target);
}

/// <summary>Persistence for MCP clients and the default-off switch.</summary>
public interface IMcpClientStore
{
    bool Enabled { get; set; }
    /// <summary>Clients that still hold a credential and have not been revoked.</summary>
    IReadOnlyList<McpStoredClient> Load();
    void Add(McpStoredClient client);
    /// <summary>Revocation survives a failed delete: the id is recorded as revoked first.</summary>
    void Remove(Guid id);
}

/// <summary>Volatile store for tests and for hosts that must not persist anything.</summary>
public sealed class MemoryMcpClientStore : IMcpClientStore
{
    private readonly List<McpStoredClient> _clients = [];
    public bool Enabled { get; set; }
    public IReadOnlyList<McpStoredClient> Load() => [.. _clients];
    public void Add(McpStoredClient client) => _clients.Add(client);
    public void Remove(Guid id) => _clients.RemoveAll(c => c.Id == id);
}

/// <summary>
/// Tokens are individual generic credentials (the vault limits one secret to 2560 bytes, so a combined blob
/// would not hold 32 clients). Non-secret metadata, the revoked list and the enabled flag are kept in a small
/// JSON file written atomically. A client counts only when both halves exist.
/// </summary>
public sealed class CredentialMcpClientStore(ICredentialVault vault, string metadataPath) : IMcpClientStore
{
    private const string TargetPrefix = "Clio.MCP.client.";
    private readonly object _lock = new();

    private sealed class Metadata
    {
        public bool Enabled { get; set; }
        public List<ClientRecord> Clients { get; set; } = [];
        public List<Guid> Revoked { get; set; } = [];
    }

    private sealed class ClientRecord
    {
        public Guid Id { get; set; }
        public string Name { get; set; } = "";
        public List<Guid> WorkspaceIDs { get; set; } = [];
    }

    public static string DefaultMetadataPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clio", "mcp-clients.json");

    public bool Enabled
    {
        get { lock (_lock) return Read().Enabled; }
        set { lock (_lock) { var data = Read(); data.Enabled = value; Write(data); } }
    }

    public IReadOnlyList<McpStoredClient> Load()
    {
        lock (_lock)
        {
            var data = Read();
            var clients = new List<McpStoredClient>();
            foreach (var record in data.Clients.Where(c => !data.Revoked.Contains(c.Id)).Take(McpLimits.MaximumClients))
            {
                var token = vault.Read(Target(record.Id));
                if (token is not { Length: 32 }) continue;
                clients.Add(new McpStoredClient(record.Id, record.Name, record.WorkspaceIDs.ToHashSet(), token));
            }
            return clients;
        }
    }

    public void Add(McpStoredClient client)
    {
        lock (_lock)
        {
            var data = Read();
            vault.Write(Target(client.Id), client.Id.ToString("D"), client.Token);
            data.Clients.RemoveAll(c => c.Id == client.Id);
            data.Clients.Add(new ClientRecord { Id = client.Id, Name = client.Name, WorkspaceIDs = [.. client.WorkspaceIds] });
            try { Write(data); }
            catch { vault.Delete(Target(client.Id)); throw; }
        }
    }

    public void Remove(Guid id)
    {
        lock (_lock)
        {
            var data = Read();
            // Record the revocation before touching the credential: if either step fails the client
            // stays denied, and the failure is reported to the caller.
            if (!data.Revoked.Contains(id)) data.Revoked.Add(id);
            Write(data);
            vault.Delete(Target(id));
            data.Clients.RemoveAll(c => c.Id == id);
            Write(data);
        }
    }

    private static string Target(Guid id) => TargetPrefix + id.ToString("D");

    private Metadata Read()
    {
        try
        {
            var bytes = File.ReadAllBytes(metadataPath);
            if (bytes.Length > 256 * 1024) return new Metadata();
            return JsonSerializer.Deserialize<Metadata>(bytes) ?? new Metadata();
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return new Metadata();
        }
        catch (JsonException)
        {
            // A damaged file must not enable anything: it reads as empty and default-off.
            return new Metadata();
        }
    }

    private void Write(Metadata data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(metadataPath))!);
        var temporary = metadataPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(data));
            File.Move(temporary, metadataPath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

/// <summary>Windows Credential Manager (generic credentials, per user, local machine persistence).</summary>
public sealed class WindowsCredentialVault : ICredentialVault
{
    private const uint TypeGeneric = 1;
    private const uint PersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;
    public const int MaximumSecretBytes = 2560;

    [StructLayout(LayoutKind.Sequential)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredWriteW")]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredReadW")]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredDeleteW")]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public byte[]? Read(string target)
    {
        if (!CredRead(target, TypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound) return null;
            throw new Win32Exception(error);
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            var secret = new byte[credential.CredentialBlobSize];
            if (secret.Length > 0) Marshal.Copy(credential.CredentialBlob, secret, 0, secret.Length);
            return secret;
        }
        finally { CredFree(pointer); }
    }

    public void Write(string target, string userName, byte[] secret)
    {
        if (secret.Length is 0 or > MaximumSecretBytes) throw new ArgumentOutOfRangeException(nameof(secret));
        var blob = Marshal.AllocHGlobal(secret.Length);
        var name = Marshal.StringToCoTaskMemUni(target);
        var user = Marshal.StringToCoTaskMemUni(userName);
        try
        {
            Marshal.Copy(secret, 0, blob, secret.Length);
            var credential = new Credential
            {
                Type = TypeGeneric, TargetName = name, UserName = user,
                CredentialBlobSize = (uint)secret.Length, CredentialBlob = blob, Persist = PersistLocalMachine,
            };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            // Do not leave the token in freed unmanaged memory.
            Marshal.Copy(new byte[secret.Length], 0, blob, secret.Length);
            Marshal.FreeHGlobal(blob);
            Marshal.FreeCoTaskMem(name);
            Marshal.FreeCoTaskMem(user);
        }
    }

    public void Delete(string target)
    {
        if (CredDelete(target, TypeGeneric, 0)) return;
        var error = Marshal.GetLastWin32Error();
        if (error != ErrorNotFound) throw new Win32Exception(error);
    }
}
