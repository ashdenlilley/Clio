using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Clio.Intelligence;

/// <summary>
/// Reconstructs Markdown from plain text that lost its formatting (macOS <c>StructureRecovery</c>). Text pasted out of
/// an email, a terminal or a plain-text export arrives hard wrapped mid-sentence, with no heading markers and no list
/// bullets. Two passes put the structure back:
/// <list type="number">
/// <item><b>Stitch.</b> One yes/no question per adjacent pair of lines, asking whether the break tore a sentence in half.</item>
/// <item><b>Classify.</b> One question per merged block choosing what kind of content it is, with companion questions for
/// heading level, step order and callout kind.</item>
/// </list>
/// The model never writes text. It answers questions about the paste and the renderer assembles the result, so every
/// character of the output came from the input.
/// </summary>
public static partial class StructureRecovery
{
    // ---- types ------------------------------------------------------------------------------------

    /// <param name="PrecededByGap">A blank line separated this from the line before it. Read in code, never sent for the model to reconsider.</param>
    public readonly record struct Line(string Text, bool PrecededByGap);

    public sealed class Block(string text, List<int> lineIndices, bool precededByGap)
    {
        public string Text { get; set; } = text;
        public List<int> LineIndices { get; } = lineIndices;
        public bool PrecededByGap { get; } = precededByGap;
    }

    public enum BlockKind { Heading, Paragraph, ListItem, Quote, Code, Callout }

    public enum HeadingLevel { Title, Section, Subsection }

    public readonly record struct Judgment(BlockKind Kind, double Confidence, HeadingLevel HeadingLevel, double StepProbability, string CalloutKind);

    public static string RawValue(this BlockKind kind) => kind switch
    {
        BlockKind.Heading => "heading",
        BlockKind.Paragraph => "paragraph",
        BlockKind.ListItem => "list_item",
        BlockKind.Quote => "quote",
        BlockKind.Code => "code",
        _ => "callout",
    };

    public static string RawValue(this HeadingLevel level) => level switch
    {
        HeadingLevel.Title => "title",
        HeadingLevel.Section => "section",
        _ => "subsection",
    };

    public static string Marker(this HeadingLevel level) => level switch
    {
        HeadingLevel.Title => "#",
        HeadingLevel.Section => "##",
        _ => "###",
    };

    // ---- gates ------------------------------------------------------------------------------------

    /// <summary>Longer blocks cannot read as a heading, so the heading-level question is not asked about them.</summary>
    public const int HeadingMaxCharacters = 90;

    /// <summary>A join this likely merges the pair when the previous line trailed off without punctuation.</summary>
    public const double JoinAfterDangling = 0.2;

    /// <summary>After a full stop the bar is higher: a new sentence usually is one.</summary>
    public const double JoinAfterTerminal = 0.5;

    /// <summary>A run of list items is numbered when its mean step probability reaches this.</summary>
    public const double StepThreshold = 0.5;

    /// <summary>Below this many characters a paste is not worth a round trip.</summary>
    public const int MinimumCharacters = 240;

    /// <summary>Above this the paste would crowd the model's per-request budget.</summary>
    public const int MaximumCharacters = 40_000;

    private static int Count(string text) => new StringInfo(text).LengthInTextElements;

    /// <summary>
    /// Whether a paste is worth sending at all. Text that already carries Markdown markers is already structured, and a
    /// single unwrapped line has no breaks to heal. Deciding this in code keeps the network quiet for the ordinary paste.
    /// </summary>
    public static bool ShouldAttempt(string pasted)
    {
        var trimmed = pasted.Trim();
        var count = Count(trimmed);
        if (count < MinimumCharacters || count > MaximumCharacters) return false;
        var lines = trimmed.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        return lines.Length >= 3 && !CarriesMarkdownMarkers(lines);
    }

    /// <summary>Direct evidence that the text kept its markup. One stray dash is not enough; a structured document shows it repeatedly.</summary>
    public static bool CarriesMarkdownMarkers(IReadOnlyList<string> lines)
    {
        var marked = lines.Count(line => MarkerRegex().IsMatch(line));
        return marked * 4 >= lines.Count;
    }

    [GeneratedRegex(@"^\s{0,3}(#{1,6}\s|[-+*]\s|\d{1,9}[.)]\s|>\s?|```|~~~|\|)")]
    private static partial Regex MarkerRegex();

    [GeneratedRegex(@"[\t ]+")]
    private static partial Regex HorizontalSpaceRegex();

    [GeneratedRegex(@"[.!?:;…][""')\]]*$")]
    private static partial Regex TerminalRegex();

    private static readonly char[] LineBreaks = ['\n', '\r', '\u0085', '\u2028', '\u2029'];

    /// <summary>
    /// Reads the text into lines. Whitespace runs collapse to one space and a blank run before any content is not a
    /// separator. A CRLF pair counts as one break (macOS would see two and read a blank line between them; pastes are
    /// normalised to LF before they reach here).
    /// </summary>
    public static List<Line> Lines(string text)
    {
        var lines = new List<Line>();
        var gap = false;
        foreach (var raw in SplitLines(text))
        {
            var collapsed = HorizontalSpaceRegex().Replace(raw, " ").Trim();
            if (collapsed.Length == 0)
            {
                gap = lines.Count > 0;
                continue;
            }
            lines.Add(new Line(collapsed, gap));
            gap = false;
        }
        return lines;
    }

    private static IEnumerable<string> SplitLines(string text)
    {
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (Array.IndexOf(LineBreaks, text[i]) < 0) continue;
            yield return text[start..i];
            if (text[i] == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
            start = i + 1;
        }
        yield return text[start..];
    }

    public static string LineId(int index) => $"L{index:000}";

    public static string BlockId(int index) => $"B{index:000}";

    /// <summary>Renders the state the model reads. Each entry carries a short id and the questions refer to those ids.</summary>
    public static string Tagged(IReadOnlyList<(string Text, bool Gap)> items, string prefix) =>
        string.Join("\n", items.Select((item, index) => $"{(item.Gap ? "\n" : "")}{prefix}{index:000}| {item.Text}"));

    // ---- pass 1: stitch ---------------------------------------------------------------------------

    public static TypeSafeRequest StitchRequest(IReadOnlyList<Line> lines)
    {
        var questions = new Dictionary<string, TypeSafeQuestion>();
        for (var index = 1; index < lines.Count; index++)
        {
            if (lines[index].PrecededByGap) continue;
            questions[LineId(index)] = TypeSafeQuestion.Noul(
                $"Does line {LineId(index)} pick up mid-sentence, continuing a sentence left unfinished at the end of line {LineId(index - 1)}?",
                new NoulCriteria(
                    "The line starts in the middle of a sentence that began on the previous line - the line break tore the sentence apart.",
                    "The line begins a new sentence, item, heading, or thought of its own."));
        }
        var state = Tagged([.. lines.Select(l => (l.Text, l.PrecededByGap))], "L");
        return TypeSafeRequest.WithState(state, questions);
    }

    public static List<double> Joins(TypeSafeResponse response, int lineCount) =>
        [.. Enumerable.Range(0, lineCount).Select(i => response[LineId(i)]?.NoulValue ?? 0)];

    public static bool EndsTerminally(string text) => TerminalRegex().IsMatch(text);

    public static List<Block> Merge(IReadOnlyList<Line> lines, IReadOnlyList<double> joins)
    {
        var blocks = new List<Block>();
        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index];
            var bar = index > 0 && EndsTerminally(lines[index - 1].Text) ? JoinAfterTerminal : JoinAfterDangling;
            var join = index < joins.Count ? joins[index] : 0;
            if (blocks.Count > 0 && !line.PrecededByGap && join >= bar)
            {
                var last = blocks[^1];
                last.Text += " " + line.Text;
                last.LineIndices.Add(index);
            }
            else
            {
                blocks.Add(new Block(line.Text, [index], line.PrecededByGap));
            }
        }
        return blocks;
    }

    // ---- pass 2: classify -------------------------------------------------------------------------

    public static IReadOnlyDictionary<string, string> KindCriteria { get; } = new Dictionary<string, string>
    {
        [BlockKind.Heading.RawValue()] = "A short label or title naming the document or the section that follows it - not a full sentence of content.",
        [BlockKind.Paragraph.RawValue()] = "Running prose: one or more complete sentences of explanatory or narrative text.",
        [BlockKind.ListItem.RawValue()] = "One entry in a list of parallel items - a task, a feature, a name; it reads as one of several sibling entries.",
        [BlockKind.Quote.RawValue()] = "Words attributed to a person or source - quoted speech, a citation, an excerpt someone else wrote.",
        [BlockKind.Code.RawValue()] = "Computer code, a shell command, terminal output, or a config snippet meant to be read verbatim.",
        [BlockKind.Callout.RawValue()] = "A warning, tip, or important note interrupting the flow to flag something the reader must not miss.",
    };

    public static IReadOnlyDictionary<string, string> HeadingLevelCriteria { get; } = new Dictionary<string, string>
    {
        [HeadingLevel.Title.RawValue()] = "The title of the whole document.",
        [HeadingLevel.Section.RawValue()] = "A major section heading within the document.",
        [HeadingLevel.Subsection.RawValue()] = "A minor heading nested under a section.",
    };

    public static IReadOnlyDictionary<string, string> CalloutCriteria { get; } = new Dictionary<string, string>
    {
        ["note"] = "Neutral extra information the reader should be aware of.",
        ["tip"] = "A helpful suggestion or shortcut that makes things easier.",
        ["warning"] = "A caution about something that can go wrong or cause harm.",
    };

    public static TypeSafeRequest ClassifyRequest(IReadOnlyList<Block> blocks)
    {
        var questions = new Dictionary<string, TypeSafeQuestion>();
        for (var index = 0; index < blocks.Count; index++)
        {
            var id = BlockId(index);
            questions[$"type_{id}"] = TypeSafeQuestion.Choice($"What kind of content is block {id}?", KindCriteria);
            if (Count(blocks[index].Text) <= HeadingMaxCharacters)
                questions[$"hlevel_{id}"] = TypeSafeQuestion.Choice(
                    $"As a heading, what level would block {id} occupy in this document's structure?", HeadingLevelCriteria);
            questions[$"step_{id}"] = TypeSafeQuestion.Noul(
                $"Is block {id} an instruction in a sequence where the order of the items matters?",
                new NoulCriteria(
                    "It is one step of a procedure - the items around it must happen in order.",
                    "Order is irrelevant - it is a loose collection, or not a list item at all."));
            questions[$"callout_{id}"] = TypeSafeQuestion.Choice($"What kind of aside is block {id}?", CalloutCriteria);
        }
        var state = Tagged([.. blocks.Select(b => (b.Text, b.PrecededByGap))], "B");
        return TypeSafeRequest.WithState(state, questions);
    }

    public static List<Judgment> Judgments(TypeSafeResponse response, int blockCount) =>
        [.. Enumerable.Range(0, blockCount).Select(index =>
        {
            var id = BlockId(index);
            var kindAnswer = response[$"type_{id}"]?.ChoiceValue;
            var kind = kindAnswer is not null ? ParseKind(kindAnswer.Choice) : null;
            var level = response[$"hlevel_{id}"]?.ChoiceValue is { } l ? ParseLevel(l.Choice) : null;
            return new Judgment(
                kind ?? BlockKind.Paragraph,
                kindAnswer?.Confidence ?? 0,
                level ?? HeadingLevel.Section,
                response[$"step_{id}"]?.NoulValue ?? 0,
                response[$"callout_{id}"]?.ChoiceValue?.Choice ?? "note");
        })];

    public static BlockKind? ParseKind(string raw) =>
        Enum.GetValues<BlockKind>().Select(k => (BlockKind?)k).FirstOrDefault(k => k!.Value.RawValue() == raw);

    public static HeadingLevel? ParseLevel(string raw) =>
        Enum.GetValues<HeadingLevel>().Select(l => (HeadingLevel?)l).FirstOrDefault(l => l!.Value.RawValue() == raw);

    // ---- rendering --------------------------------------------------------------------------------

    /// <summary>
    /// Assembles Markdown from the blocks and their judgments. Callouts render as a labelled blockquote rather than an
    /// alert directive, because a blockquote is plain CommonMark and survives every one of Clio's exporters.
    /// </summary>
    public static string Render(IReadOnlyList<Block> blocks, IReadOnlyList<Judgment> judgments)
    {
        var output = new List<string>();
        var index = 0;
        while (index < blocks.Count)
        {
            var judgment = judgments[index];
            switch (judgment.Kind)
            {
                case BlockKind.Heading:
                    output.Add($"{judgment.HeadingLevel.Marker()} {blocks[index].Text}");
                    index++;
                    break;
                case BlockKind.ListItem:
                {
                    var run = new List<int>();
                    while (index < blocks.Count && judgments[index].Kind == BlockKind.ListItem) run.Add(index++);
                    var mean = run.Sum(i => judgments[i].StepProbability) / run.Count;
                    var ordered = mean >= StepThreshold;
                    output.Add(string.Join("\n", run.Select((block, position) =>
                        $"{(ordered ? $"{position + 1}." : "-")} {blocks[block].Text}")));
                    break;
                }
                case BlockKind.Code:
                {
                    var run = new List<int>();
                    while (index < blocks.Count && judgments[index].Kind == BlockKind.Code) run.Add(index++);
                    output.Add($"```\n{string.Join("\n", run.Select(i => blocks[i].Text))}\n```");
                    break;
                }
                case BlockKind.Quote:
                    output.Add(Quoted(blocks[index].Text));
                    index++;
                    break;
                case BlockKind.Callout:
                {
                    var kind = judgment.CalloutKind;
                    var label = kind.Length == 0 ? kind : char.ToUpperInvariant(kind[0]) + kind[1..];
                    output.Add(Quoted($"**{label}:** {blocks[index].Text}"));
                    index++;
                    break;
                }
                default:
                    output.Add(blocks[index].Text);
                    index++;
                    break;
            }
        }
        return string.Join("\n\n", output);
    }

    private static string Quoted(string text) => string.Join("\n", text.Split('\n').Select(l => $"> {l}"));
}
