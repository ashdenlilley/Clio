using System.Runtime.InteropServices;
using System.Text;

namespace Clio.Intelligence;

/// <summary>
/// Windows Credential Manager storage for the TypeSafe API key (macOS keeps it in the login Keychain). The key is a
/// credential, so it never reaches the settings file, the install folder or a log. It is stored for this Windows account
/// and this device only (<c>CRED_PERSIST_LOCAL_MACHINE</c>: it does not roam), and it is protected by the account's own
/// DPAPI keys. Each Windows account adds its own key.
/// </summary>
public sealed class CredentialManagerKeyStore(string targetName = CredentialManagerKeyStore.DefaultTarget) : IApiKeyStore
{
    public const string DefaultTarget = "olympus.clio.windows.typesafe";

    /// <summary>Credential Manager's own limit on a credential blob is 2560 bytes.</summary>
    public const int MaximumKeyBytes = 2560;

    private const uint TypeGeneric = 1;
    private const uint PersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    public string? Load()
    {
        if (!OperatingSystem.IsWindows()) return null;
        if (!CredReadW(targetName, TypeGeneric, 0, out var handle)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(handle);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0 || credential.CredentialBlobSize > MaximumKeyBytes) return null;
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            try
            {
                var key = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes).Trim();
                return key.Length == 0 ? null : key;
            }
            catch (DecoderFallbackException) { return null; }
            finally { Array.Clear(bytes); }
        }
        finally { CredFree(handle); }
    }

    public bool Store(string? key)
    {
        if (!OperatingSystem.IsWindows()) return false;
        var trimmed = key?.Trim() ?? "";
        if (trimmed.Length == 0) return Remove();
        var bytes = Encoding.UTF8.GetBytes(trimmed);
        if (bytes.Length > MaximumKeyBytes) { Array.Clear(bytes); return false; }

        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = TypeGeneric,
                TargetName = targetName,
                Comment = "Clio assisted commands (TypeSafe API key)",
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = PersistLocalMachine,
                UserName = "api-key-v1",
            };
            return CredWriteW(ref credential, 0);
        }
        finally
        {
            // Wipe both copies of the secret before releasing them.
            Array.Clear(bytes);
            Marshal.Copy(new byte[bytes.Length], 0, blob, bytes.Length);
            Marshal.FreeHGlobal(blob);
        }
    }

    private bool Remove()
    {
        if (CredDeleteW(targetName, TypeGeneric, 0)) return true;
        return Marshal.GetLastWin32Error() == ErrorNotFound;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);

    [DllImport("advapi32.dll", SetLastError = false)]
    private static extern void CredFree(IntPtr buffer);
}
