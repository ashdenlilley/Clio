using Xunit;

namespace Clio.Core.Tests;

public sealed class WorkspaceScannerTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("clio-scan-").FullName;
    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private void Touch(string rel, string text = "")
    {
        var p = Path.Combine(_dir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllText(p, text);
    }

    [Fact]
    public void FindsMarkdownHonoursGitignoreAndSkipsSidecarsAndHidden()
    {
        Touch("a.md"); Touch("notes/b.markdown"); Touch("c.txt"); Touch("skip/d.md");
        Touch(".gitignore", "skip/\n"); Touch(".clio-save-x.md"); Touch(".hidden/e.md"); Touch("UPPER.MD");
        var files = WorkspaceScanner.Scan(_dir).Where(e => !e.IsDirectory).Select(e => e.Relative).ToArray();
        Assert.Equal(["a.md", "notes/b.markdown", "UPPER.MD"], files);
    }

    [Fact]
    public void NestedGitignoreAppliesOnlyBelowItsFolder()
    {
        Touch("sub/.gitignore", "*.md\n!keep.md\n"); Touch("sub/x.md"); Touch("sub/keep.md"); Touch("top.md");
        var files = WorkspaceScanner.Scan(_dir).Where(e => !e.IsDirectory).Select(e => e.Relative).ToArray();
        Assert.Equal(["sub/keep.md", "top.md"], files);
    }
}
