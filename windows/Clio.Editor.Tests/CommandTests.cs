using System.Text.Json;
using Clio.Editor.Commands;
using Xunit;

namespace Clio.Editor.Tests;

public class CommandTests
{
    private static IEnumerable<JsonElement> Kind(string kind) =>
        Spec.Vectors("slash-commands.json").EnumerateArray().Where(v => v.GetProperty("kind").GetString() == kind);

    private static string Name(JsonElement v) => v.GetProperty("name").GetString()!;

    private static string[] Strings(JsonElement array) => [.. array.EnumerateArray().Select(e => e.GetString()!)];

    [Fact]
    public void CommandIdsMatchTheContractInOrder()
    {
        var root = JsonDocument.Parse(File.ReadAllText(Path.Combine(Spec.Root, "spec", "vectors", "slash-commands.json"))).RootElement;
        var expected = Strings(root.GetProperty("commandIds"));
        Assert.Equal(expected, Enum.GetValues<CommandId>().Select(c => c.RawValue()));
        Assert.Equal(expected, CommandDescriptor.All.Select(d => d.Command.RawValue()));
        Assert.Equal("/export", CommandId.Export.SlashName());
    }

    [Fact]
    public void CommandTokenMatchesVectors()
    {
        foreach (var v in Kind("commandToken"))
            Assert.True(v.GetProperty("expected").GetString() == CommandParser.CommandToken(v.GetProperty("input").GetString()!), Name(v));
    }

    [Fact]
    public void ParseMatchesVectors()
    {
        foreach (var v in Kind("parse"))
        {
            var input = v.GetProperty("input").GetString()!;
            if (v.TryGetProperty("error", out var error))
            {
                var ex = Assert.Throws<CommandParseException>(() => CommandParser.Parse(input));
                var expectedKind = Enum.Parse<CommandParseErrorKind>(error.GetString()!, ignoreCase: true);
                Assert.True(expectedKind == ex.Kind, $"{Name(v)}: kind {ex.Kind}");
                Assert.True(v.GetProperty("message").GetString() == ex.Message, $"{Name(v)}: message '{ex.Message}'");
                if (v.TryGetProperty("argument", out var argument)) Assert.Equal(argument.GetString(), ex.Argument);
            }
            else
            {
                var invocation = CommandParser.Parse(input);
                Assert.True(v.GetProperty("command").GetString() == invocation.Command.RawValue(), Name(v));
                Assert.True(Strings(v.GetProperty("arguments")).SequenceEqual(invocation.Arguments), $"{Name(v)}: [{string.Join("|", invocation.Arguments)}]");
            }
        }
    }

    [Fact]
    public void FilterMatchesVectors()
    {
        foreach (var v in Kind("filter"))
        {
            var actual = CommandDescriptor.Filter(v.GetProperty("token").GetString()!).Select(d => d.Command.RawValue());
            Assert.True(Strings(v.GetProperty("expected")).SequenceEqual(actual), $"{Name(v)}: [{string.Join(",", actual)}]");
        }
    }

    [Fact]
    public void SlashTriggerMatchesVectors()
    {
        foreach (var v in Kind("trigger"))
        {
            var range = v.GetProperty("range");
            var marked = v.TryGetProperty("markedText", out var m) && m.GetBoolean();
            var actual = SlashTrigger.IsInlineSlashTrigger(v.GetProperty("text").GetString()!, range[0].GetInt32(), range[1].GetInt32(),
                v.GetProperty("replacement").GetString()!, marked);
            Assert.True(v.GetProperty("expected").GetBoolean() == actual, Name(v));
        }
    }

    [Fact]
    public void EmptyLineMatchesVectors()
    {
        foreach (var v in Kind("emptyLine"))
        {
            var range = v.GetProperty("range");
            var actual = SlashTrigger.IsEmptySlashLine(v.GetProperty("text").GetString()!, range[0].GetInt32(), range[1].GetInt32());
            Assert.True(v.GetProperty("expected").GetBoolean() == actual, Name(v));
        }
    }

    [Fact]
    public void EmptyLineHandlesCrlfCaretBetweenCrAndLf()
    {
        Assert.True(SlashTrigger.IsEmptySlashLine("\r\n", 1, 0));
        Assert.False(SlashTrigger.IsEmptySlashLine("a\r\nb", 2, 0));
        Assert.True(SlashTrigger.IsEmptySlashLine("a\r\n\r\nb", 3, 0));
    }

    [Fact]
    public void PaletteMatchesVectors()
    {
        foreach (var v in Kind("palette"))
        {
            var palette = new CommandPalette();
            string? restored = null;
            palette.LiteralRestored += literal => restored = literal;
            palette.Present(Enum.Parse<CommandSource>(v.GetProperty("source").GetString()!, ignoreCase: true), v.GetProperty("query").GetString()!);

            CommandInvocation? invocation = null;
            foreach (var op in v.GetProperty("ops").EnumerateArray())
            {
                switch (op.GetProperty("op").GetString())
                {
                    case "update": palette.UpdateQuery(op.GetProperty("query").GetString()!); break;
                    case "move": palette.MoveSelection(op.GetProperty("by").GetInt32()); break;
                    case "perform": invocation = palette.PerformSelected(); break;
                    case "dismiss":
                        palette.Dismiss(!op.TryGetProperty("preserveLiteral", out var keep) || keep.GetBoolean());
                        break;
                    default: throw new InvalidOperationException(op.ToString());
                }
            }

            var expected = v.GetProperty("expected");
            var name = Name(v);
            Assert.True(expected.GetProperty("presented").GetBoolean() == palette.IsPresented, $"{name}: presented");
            Assert.True(expected.GetProperty("restored").GetString() == restored, $"{name}: restored '{restored}'");
            if (expected.TryGetProperty("query", out var query)) Assert.True(query.GetString() == palette.Query, $"{name}: query");
            if (expected.TryGetProperty("selection", out var selection)) Assert.True(selection.GetInt32() == palette.SelectionIndex, $"{name}: selection {palette.SelectionIndex}");
            if (expected.TryGetProperty("error", out var error)) Assert.True(error.GetString() == palette.ErrorMessage, $"{name}: error '{palette.ErrorMessage}'");
            if (expected.TryGetProperty("invocation", out var expectedInvocation))
            {
                if (expectedInvocation.ValueKind == JsonValueKind.Null) Assert.True(invocation is null, $"{name}: invocation");
                else
                {
                    Assert.True(invocation is not null, $"{name}: invocation missing");
                    Assert.True(expectedInvocation.GetProperty("command").GetString() == invocation!.Command.RawValue(), $"{name}: command");
                    Assert.True(Strings(expectedInvocation.GetProperty("arguments")).SequenceEqual(invocation.Arguments), $"{name}: arguments");
                }
            }
        }
    }

    [Fact]
    public void PlacementMatchesVectors()
    {
        foreach (var v in Kind("placement"))
        {
            var a = v.GetProperty("anchor");
            var w = v.GetProperty("window");
            var e = v.GetProperty("expected");
            var frame = PalettePlacement.FrameBelow(a[0].GetDouble(), a[1].GetDouble(), a[3].GetDouble(), w[0].GetDouble(), w[1].GetDouble());
            Assert.True(
                new PaletteFrame(e[0].GetDouble(), e[1].GetDouble(), e[2].GetDouble(), e[3].GetDouble()) == frame,
                $"{Name(v)}: {frame}");
        }
    }
}
