using System.Diagnostics;
using System.Text.Json;
using Xunit;

namespace Clio.Editor.Tests;

internal static class Spec
{
    public static string Root { get; } = Find();

    private static string Find()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (Directory.Exists(Path.Combine(d.FullName, "spec", "vectors"))) return d.FullName;
        throw new DirectoryNotFoundException("spec/vectors not found");
    }

    public static JsonElement Vectors(string name) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(Root, "spec", "vectors", name))).RootElement.GetProperty("vectors");
}

public class FocusUnitTests
{
    [Fact]
    public void MatchesSharedVectors()
    {
        foreach (var v in Spec.Vectors("focus-ranges.json").EnumerateArray())
        {
            var sel = v.GetProperty("selection");
            var actual = FocusUnit.FocusRange(v.GetProperty("text").GetString()!, new TextRange(sel[0].GetInt32(), sel[1].GetInt32()));
            var exp = v.GetProperty("expected");
            TextRange? expected = exp.ValueKind == JsonValueKind.Null ? null : new TextRange(exp[0].GetInt32(), exp[1].GetInt32());
            Assert.True(expected == actual, $"{v.GetProperty("name").GetString()}: expected {expected}, got {actual}");
        }
    }

    [Fact]
    public void LargeDocumentDiscoveryIsBoundedNearCaret()
    {
        var text = string.Concat(Enumerable.Repeat("paragraph\n\n", 900_000)) + "tail thought\ncontinues\n";
        var caret = text.LastIndexOf("tail thought", StringComparison.Ordinal);
        var sw = Stopwatch.StartNew();
        var range = FocusUnit.FocusRange(text, new TextRange(caret, 0));
        Assert.Equal(new TextRange(caret, "tail thought\ncontinues\n".Length), range);
        Assert.True(sw.ElapsedMilliseconds < 500, $"took {sw.ElapsedMilliseconds} ms");
        Assert.True(FocusUnit.MaximumSynchronousScanLength < text.Length);
    }
}
