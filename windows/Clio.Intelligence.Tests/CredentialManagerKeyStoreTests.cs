using Xunit;

namespace Clio.Intelligence.Tests;

/// <summary>Round-trips a throwaway credential under a unique target name and always removes it. The real Clio entry is never touched.</summary>
public class CredentialManagerKeyStoreTests
{
    private static string UniqueTarget() => "olympus.clio.windows.typesafe.test." + Guid.NewGuid().ToString("N");

    [Fact]
    public void StoresReadsReplacesAndRemovesAKey()
    {
        if (!OperatingSystem.IsWindows()) return;
        var store = new CredentialManagerKeyStore(UniqueTarget());
        try
        {
            Assert.Null(store.Load());
            Assert.True(store.Store("first-key"));
            Assert.Equal("first-key", store.Load());
            Assert.True(store.Store("  second-key\n"));
            Assert.Equal("second-key", store.Load());
            Assert.True(store.Store(null));
            Assert.Null(store.Load());
            Assert.True(store.Store(null), "removing an absent key is not a failure");
        }
        finally { store.Store(null); }
    }

    [Fact]
    public void KeysSurviveNonAsciiAndAreIsolatedByTarget()
    {
        if (!OperatingSystem.IsWindows()) return;
        var a = new CredentialManagerKeyStore(UniqueTarget());
        var b = new CredentialManagerKeyStore(UniqueTarget());
        try
        {
            Assert.True(a.Store("kéy-ünïcode-✓"));
            Assert.Equal("kéy-ünïcode-✓", a.Load());
            Assert.Null(b.Load());
        }
        finally { a.Store(null); b.Store(null); }
    }

    [Fact]
    public void AKeyBeyondCredentialManagersLimitIsRefusedAndNothingIsStored()
    {
        if (!OperatingSystem.IsWindows()) return;
        var store = new CredentialManagerKeyStore(UniqueTarget());
        try
        {
            Assert.False(store.Store(new string('k', CredentialManagerKeyStore.MaximumKeyBytes + 1)));
            Assert.Null(store.Load());
            Assert.True(store.Store(new string('k', CredentialManagerKeyStore.MaximumKeyBytes)));
            Assert.Equal(CredentialManagerKeyStore.MaximumKeyBytes, store.Load()!.Length);
        }
        finally { store.Store(null); }
    }

    [Fact]
    public void TheDefaultTargetIsNotTheMacOsServiceName() =>
        Assert.Equal("olympus.clio.windows.typesafe", CredentialManagerKeyStore.DefaultTarget);
}
