using System.Text.Json.Nodes;
using Clio.Editor.Commands;

namespace Clio.Intelligence;

/// <summary>
/// The plain-language specification behind assisted command matching (macOS <c>CommandIntentSpec</c>). Option keys are
/// <see cref="CommandId"/> raw values, so an answer maps straight onto a command. The descriptions name the idea
/// behind each command rather than the words a writer might use, because the match is on meaning.
/// </summary>
public static class CommandIntentSpec
{
    /// <summary>Returned when nothing in the palette fits. Without it the model must name a command for any input.</summary>
    public const string NoMatch = "__none__";

    public const string CommandQuestionId = "command";
    public const string ExportFormatQuestionId = "export_format";
    public const string ExportFormatStatedQuestionId = "export_format_stated";

    public static IReadOnlyDictionary<string, string> CommandCriteria { get; } = new Dictionary<string, string>
    {
        [CommandId.New.RawValue()] = "Start a fresh, empty document to write something new in.",
        [CommandId.Open.RawValue()] = "Open an existing file that already exists on disk, chosen from a file picker.",
        [CommandId.Search.RawValue()] = "Find writing somewhere in the workspace by what it says - looking for a document, a passage, or a phrase the writer half-remembers.",
        [CommandId.Rename.RawValue()] = "Give the document being written a different name.",
        [CommandId.Delete.RawValue()] = "Get rid of the document being written, moving it to the Recycle Bin.",
        [CommandId.Reveal.RawValue()] = "See where the document sits on disk, showing the actual file in File Explorer.",
        [CommandId.Folder.RawValue()] = "Let Clio see a new folder of writing that it does not know about yet, adding it to the searchable workspace.",
        [CommandId.Export.RawValue()] = "Turn the document into some other file format to send, print, publish or hand to someone who does not use Clio.",
        [CommandId.Focus.RawValue()] = "Change whether the text away from the writing position is dimmed, to quiet the surrounding page.",
        [CommandId.Typewriter.RawValue()] = "Change whether the line being typed stays pinned at one height on screen instead of drifting down the page.",
        [CommandId.Sidebar.RawValue()] = "Show or hide the list of documents alongside the writing area.",
        [CommandId.Settings.RawValue()] = "Change how Clio itself looks or behaves - its font, colours, folders or preferences.",
        [NoMatch] = "Nothing Clio can do: the text is something to write down, a question, or a request for a capability Clio does not have.",
    };

    /// <summary><c>/export</c> is the one command taking a closed-set argument, so it is the one argument worth filling.</summary>
    public static IReadOnlyDictionary<string, string> ExportFormatCriteria { get; } = new Dictionary<string, string>
    {
        ["pdf"] = "A fixed page layout for printing or sending, looking the same everywhere it opens.",
        ["docx"] = "An editable Word document, for someone who will make changes or leave comments in Word.",
        ["html"] = "A self-contained web page that opens in a browser.",
        ["txt"] = "Stripped-down plain text with no formatting at all.",
    };

    /// <summary>Formats <see cref="CommandParser"/> accepts for <c>/export</c>.</summary>
    public static IReadOnlyList<string> ExportFormats { get; } = ["pdf", "html", "docx", "txt"];
}

/// <summary>
/// What the editor window looks like when a request is made. Only booleans travel: the document's text, its name and
/// its path stay on the machine.
/// </summary>
public sealed record CommandIntentContext(
    bool HasOpenDocument,
    bool DocumentExistsOnDisk,
    bool IsFocusModeEnabled,
    bool IsTypewriterEnabled,
    bool IsSidebarVisible)
{
    public JsonObject ToJson() => new()
    {
        ["has_open_document"] = HasOpenDocument,
        ["document_saved_to_disk"] = DocumentExistsOnDisk,
        ["focus_mode_on"] = IsFocusModeEnabled,
        ["typewriter_on"] = IsTypewriterEnabled,
        ["sidebar_visible"] = IsSidebarVisible,
    };
}

/// <summary>A matched command, ready for the palette to preselect.</summary>
/// <param name="Confidence">The least certain judgment behind this call: one wrong argument spoils the result.</param>
/// <param name="CommandProbability">How much probability the command choice put on the winner alone.</param>
/// <param name="Ranked">Every plausible command ordered by probability, so the palette can list alternatives under the top match.</param>
public sealed record CommandIntentResult(CommandInvocation Invocation, double Confidence, double CommandProbability, IReadOnlyList<CommandId> Ranked);

/// <summary>
/// Turns a natural-language palette request into a <see cref="CommandInvocation"/> (macOS <c>CommandIntentResolver</c>).
/// One request carries the command choice and <c>/export</c>'s argument together: a speculative question costs only its
/// own tokens, while a second round trip would cost a whole request of latency.
/// </summary>
public static class CommandIntentResolver
{
    /// <summary>Below this the match is too weak to show and the palette keeps its literal substring behaviour.</summary>
    public const double MinimumConfidence = 0.45;

    /// <summary>A command needs to win outright, not merely lead a scattered field.</summary>
    public const double MinimumCommandProbability = 0.35;

    /// <summary>A command the model all but ruled out is noise in a palette, not a useful second guess.</summary>
    public const double MinimumAlternativeProbability = 0.02;

    public const int MaximumAlternatives = 4;

    /// <summary>Requests shorter than this are never sent.</summary>
    public const int MinimumRequestCharacters = 3;

    public static JsonObject State(string request, CommandIntentContext context) => new()
    {
        ["request"] = request,
        ["editor"] = context.ToJson(),
    };

    public static IReadOnlyDictionary<string, TypeSafeQuestion> Questions() => new Dictionary<string, TypeSafeQuestion>
    {
        [CommandIntentSpec.CommandQuestionId] = TypeSafeQuestion.Choice(
            "The writer typed `request` into the command bar of a Markdown writing app. What are they asking the app to do? Judge it against what the editor currently looks like, given in `editor`.",
            CommandIntentSpec.CommandCriteria),
        [CommandIntentSpec.ExportFormatQuestionId] = TypeSafeQuestion.Choice(
            "If the writer in `request` is asking to turn the document into another file format, which format do they want?",
            CommandIntentSpec.ExportFormatCriteria),
        [CommandIntentSpec.ExportFormatStatedQuestionId] = TypeSafeQuestion.Noul(
            "Does `request` say anything about which file format or program the result should be for?",
            new NoulCriteria(
                "The request names a format, a program, or a purpose that implies one - Word, a web page, printing, plain text.",
                "The request asks only to get the document out, leaving the format open.")),
    };

    public static TypeSafeRequest Request(string text, CommandIntentContext context) => new(State(text, context), Questions());

    /// <summary>
    /// Reads the answers back into a command call, or null when nothing matched well enough to show. Null is the common
    /// case for ordinary typing and always leaves the palette's own filtering in charge.
    /// </summary>
    public static CommandIntentResult? Resolve(TypeSafeResponse response)
    {
        if (response[CommandIntentSpec.CommandQuestionId]?.ChoiceValue is not { } command) return null;

        var ranked = command.Probabilities
            .OrderByDescending(p => p.Value).ThenBy(p => p.Key, StringComparer.Ordinal)
            .Where(p => p.Key == command.Choice || p.Value >= MinimumAlternativeProbability)
            .Take(MaximumAlternatives)
            .Select(p => CommandIds.TryParse(p.Key, out var id) ? (CommandId?)id : null)
            .OfType<CommandId>()
            .ToList();

        if (command.Choice == CommandIntentSpec.NoMatch
            || !CommandIds.TryParse(command.Choice, out var matched)
            || command.Confidence < MinimumConfidence
            || command.Probability < MinimumCommandProbability)
            return null;

        var confidence = Math.Min(command.Confidence, command.Probability);
        var arguments = new List<string>();

        if (matched == CommandId.Export)
        {
            var stated = response[CommandIntentSpec.ExportFormatStatedQuestionId]?.NoulValue ?? 0;
            // Below the midpoint the request left the format open, so the argument is omitted and Clio's own export
            // picker decides.
            if (stated >= 0.5
                && response[CommandIntentSpec.ExportFormatQuestionId]?.ChoiceValue is { } format
                && CommandIntentSpec.ExportFormats.Contains(format.Choice))
            {
                arguments.Add(format.Choice);
                confidence = Math.Min(confidence, format.Probability);
            }
        }

        return new CommandIntentResult(new CommandInvocation(matched, arguments), confidence, command.Probability, ranked);
    }
}
