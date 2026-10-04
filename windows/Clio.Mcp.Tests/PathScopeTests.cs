using System.Diagnostics;
using System.Text.Json;
using Clio.Mcp;
using Xunit;

namespace Clio.Mcp.Tests;

public class PathScopeTests
{
    private static void Outside(string file, string root) =>
        Assert.Equal(McpErrorCode.OutsideWorkspace, Assert.Throws<McpException>(() => McpWorkspaceBoundary.Validate(file, root)).Code);

    /// <summary>Junctions need no privilege, unlike symlinks.</summary>
    private static void Junction(string link, string target)
    {
        var start = new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"") { CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        using var process = Process.Start(start)!;
        process.WaitForExit();
        Assert.True(process.ExitCode == 0, "could not create junction");
    }

    private static (TempDirectory Temp, string Scope, string Other) Layout()
    {
        var temp = new TempDirectory();
        var scope = temp.Combine("scope");
        var other = temp.Combine("scope-other");
        Directory.CreateDirectory(Path.Combine(scope, "nested"));
        Directory.CreateDirectory(other);
        File.WriteAllText(Path.Combine(scope, "nested", "existing.md"), "safe");
        return (temp, scope, other);
    }

    [Fact]
    public void SharedLexicalVectors()
    {
        var (temp, scope, _) = Layout();
        using var _ = temp;
        var vector = Spec.Load("mcp-access.json").GetProperty("pathScope");
        foreach (var inside in vector.GetProperty("inside").EnumerateArray())
            McpWorkspaceBoundary.Validate(Path.Combine(scope, inside.GetString()!.Replace('/', '\\')), scope);
        foreach (var row in vector.GetProperty("outside").EnumerateArray())
            Outside(Path.Combine(scope, row.GetProperty("path").GetString()!.Replace('/', '\\')), scope);
        // `..` is rejected even when written by hand with mixed separators.
        Outside(scope + "/nested/../../scope-other/no.md", scope);
        Outside(scope + @"\missing\..\..\scope-other\new.md", scope);
    }

    [Fact]
    public void RootItselfAndSiblingPrefixAreOutside()
    {
        var (temp, scope, other) = Layout();
        using var _ = temp;
        Outside(scope, scope);
        Outside(Path.Combine(other, "no.md"), scope);
        Outside(scope + "-other", scope);
        Outside(Path.Combine(temp.Path, "no.md"), scope);
    }

    [Fact]
    public void ExistingAndMissingTailsInsideTheRootAreValid()
    {
        var (temp, scope, _) = Layout();
        using var _ = temp;
        McpWorkspaceBoundary.Validate(Path.Combine(scope, "nested", "existing.md"), scope);
        McpWorkspaceBoundary.Validate(Path.Combine(scope, "new.md"), scope);
        McpWorkspaceBoundary.Validate(Path.Combine(scope, "nested", "missing", "subdirectory", "new.md"), scope);
        // Case differences are the same file on NTFS.
        McpWorkspaceBoundary.Validate(Path.Combine(scope.ToUpperInvariant(), "NESTED", "existing.md"), scope);
    }

    [Fact]
    public void FileUsedAsDirectoryFailsClosed()
    {
        var (temp, scope, _) = Layout();
        using var _ = temp;
        Outside(Path.Combine(scope, "nested", "existing.md", "new.md"), scope);
    }

    [Fact]
    public void JunctionsInsideTheRootAreRejectedWhereverTheyPoint()
    {
        var (temp, scope, other) = Layout();
        using var _ = temp;
        var escape = Path.Combine(scope, "escape");
        var internalLink = Path.Combine(scope, "internal");
        Junction(escape, other);
        Junction(internalLink, Path.Combine(scope, "nested"));
        Outside(escape, scope);
        Outside(Path.Combine(escape, "no.md"), scope);
        Outside(Path.Combine(escape, "missing", "deep", "new.md"), scope);
        Outside(internalLink, scope);
        Outside(Path.Combine(internalLink, "existing.md"), scope);
        Outside(Path.Combine(internalLink, "new.md"), scope);
    }

    [Fact]
    public void RootAliasAboveTheApprovedFolderIsResolved()
    {
        var (temp, scope, _) = Layout();
        using var _ = temp;
        var alias = temp.Combine("approved-alias");
        Junction(alias, scope);
        // The approved root may itself be reached through a link, and spelled either way.
        foreach (var root in new[] { scope, alias })
            foreach (var spelling in new[] { scope, alias })
                McpWorkspaceBoundary.Validate(Path.Combine(spelling, "missing", "deep", "new.md"), root);
        Outside(alias, alias);
    }

    [Fact]
    public void DevicePathsStreamsAndRelativePathsAreRejected()
    {
        var (temp, scope, _) = Layout();
        using var _ = temp;
        Outside(@"\\?\" + Path.Combine(scope, "ok.md"), scope);
        Outside(@"\\.\" + Path.Combine(scope, "ok.md"), scope);
        Outside(Path.Combine(scope, "ok.md") + ":stream", scope);
        Outside(Path.Combine(scope, "nested", "existing.md:Zone.Identifier"), scope);
        Outside(@"nested\ok.md", scope);
        Outside("", scope);
        Outside(Path.Combine(scope, "ok.md"), "");
        Outside(Path.Combine(scope, "bad\0name.md"), scope);
        Outside(Path.Combine(scope, "ok.md"), Path.Combine(scope, "absent-root"));
    }

    [Fact]
    public void TrailingDotsAndSpacesCannotAliasOutside()
    {
        var (temp, scope, _) = Layout();
        using var _ = temp;
        // Win32 trims these, so "nested." names the same folder as "nested", still inside.
        McpWorkspaceBoundary.Validate(Path.Combine(scope, "nested.", "existing.md"), scope);
        Outside(Path.Combine(scope, "..."), scope);
        Outside(scope + @"\.\..\scope-other\no.md", scope);
    }
}
