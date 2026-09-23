import Foundation

/// The plain-language specification behind assisted command matching.
///
/// Everything the model knows about Clio's commands is in this file. The option
/// keys are `ClioCommandID.rawValue`, so an answer maps straight onto a command
/// with nothing to translate afterwards.
///
/// The descriptions name the *idea* behind each command rather than the words a
/// writer might use for it, because the match is on meaning: "put this away
/// somewhere I can email it" should reach `export` even though none of those
/// words appear here.
enum CommandIntentSpec {
    /// Returned by the Choice when nothing in the palette fits. Without a
    /// no-match option the model must name some command for every input, and it
    /// would name one confidently.
    static let noMatch = "__none__"

    static let commandCriteria: [String: String] = [
        ClioCommandID.new.rawValue:
            "Start a fresh, empty document to write something new in.",
        ClioCommandID.open.rawValue:
            "Open an existing file that already exists on disk, chosen from a file picker.",
        ClioCommandID.search.rawValue:
            "Find writing somewhere in the workspace by what it says - looking for a document, a passage, or a phrase the writer half-remembers.",
        ClioCommandID.rename.rawValue:
            "Give the document being written a different name.",
        ClioCommandID.delete.rawValue:
            "Get rid of the document being written, moving it to the Trash.",
        ClioCommandID.reveal.rawValue:
            "See where the document sits on disk, showing the actual file in Finder.",
        ClioCommandID.folder.rawValue:
            "Let Clio see a new folder of writing that it does not know about yet, adding it to the searchable workspace.",
        ClioCommandID.export.rawValue:
            "Turn the document into some other file format to send, print, publish or hand to someone who does not use Clio.",
        ClioCommandID.focus.rawValue:
            "Change whether the text away from the writing position is dimmed, to quiet the surrounding page.",
        ClioCommandID.typewriter.rawValue:
            "Change whether the line being typed stays pinned at one height on screen instead of drifting down the page.",
        ClioCommandID.sidebar.rawValue:
            "Show or hide the list of documents alongside the writing area.",
        ClioCommandID.settings.rawValue:
            "Change how Clio itself looks or behaves - its font, colours, folders or preferences.",
        noMatch:
            "Nothing Clio can do: the text is something to write down, a question, or a request for a capability Clio does not have.",
    ]

    /// `/export` is the one command taking a closed-set argument, so it is the
    /// one argument worth filling from the request.
    static let exportFormatCriteria: [String: String] = [
        "pdf": "A fixed page layout for printing or sending, looking the same everywhere it opens.",
        "docx": "An editable Word document, for someone who will make changes or leave comments in Word.",
        "html": "A self-contained web page that opens in a browser.",
        "txt": "Stripped-down plain text with no formatting at all.",
    ]

    static let commandQuestionID = "command"
    static let exportFormatQuestionID = "export_format"
    static let exportFormatStatedQuestionID = "export_format_stated"

    /// Formats `ClioCommandParser` accepts for `/export`. Kept alongside the
    /// criteria so the two cannot drift apart unnoticed.
    static let exportFormats = ["pdf", "html", "docx", "txt"]
}
