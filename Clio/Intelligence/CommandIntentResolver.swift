import Foundation

/// What the editor window looks like when a request is made.
///
/// Only booleans travel. The document's text, its name and its path stay on the
/// machine; this is enough for the model to know that "get rid of this" cannot
/// mean `delete` when nothing is open, without sending any of the writing.
struct CommandIntentContext: Hashable, Sendable {
    var hasOpenDocument: Bool
    var documentExistsOnDisk: Bool
    var isFocusModeEnabled: Bool
    var isTypewriterEnabled: Bool
    var isSidebarVisible: Bool

    var stateValue: JSONValue {
        .object([
            "has_open_document": .bool(hasOpenDocument),
            "document_saved_to_disk": .bool(documentExistsOnDisk),
            "focus_mode_on": .bool(isFocusModeEnabled),
            "typewriter_on": .bool(isTypewriterEnabled),
            "sidebar_visible": .bool(isSidebarVisible),
        ])
    }
}

/// A matched command, ready for the palette to preselect.
struct CommandIntentResult: Hashable, Sendable {
    let invocation: ClioCommandInvocation
    /// The least certain judgment behind this call. One wrong argument spoils
    /// the result, so the weakest link is reported rather than a product, which
    /// would sag as a command takes more arguments whether or not any single
    /// judgment is shaky.
    let confidence: Double
    /// How much probability the command choice put on the winner alone.
    let commandProbability: Double
    /// Every candidate command ordered by probability, so the palette can list
    /// plausible alternatives under the top match.
    let ranked: [ClioCommandID]
}

/// Turns a natural-language palette request into a `ClioCommandInvocation`.
///
/// One request carries the command choice and `/export`'s argument together,
/// including when the request turns out not to be an export. Asking a question
/// whose answer may go unread costs only that question's tokens, while a second
/// round trip would cost a whole request of latency.
enum CommandIntentResolver {
    /// Below this, the match is too weak to put in front of the writer and the
    /// palette keeps its literal substring behaviour.
    static let minimumConfidence = 0.45
    /// A command needs to win outright, not merely lead a scattered field.
    static let minimumCommandProbability = 0.35
    /// Alternatives worth listing under the top match. A command the model all
    /// but ruled out is noise in a palette, not a useful second guess.
    static let minimumAlternativeProbability = 0.02
    static let maximumAlternatives = 4

    static func state(for request: String, context: CommandIntentContext) -> JSONValue {
        .object([
            "request": .string(request),
            "editor": context.stateValue,
        ])
    }

    static func questions() -> [String: TypeSafeQuestion] {
        [
            CommandIntentSpec.commandQuestionID: .choice(
                instructions: .string(
                    "The writer typed `request` into the command bar of a Markdown writing app. What are they asking the app to do? Judge it against what the editor currently looks like, given in `editor`."
                ),
                criteria: CommandIntentSpec.commandCriteria
            ),
            CommandIntentSpec.exportFormatQuestionID: .choice(
                instructions: .string(
                    "If the writer in `request` is asking to turn the document into another file format, which format do they want?"
                ),
                criteria: CommandIntentSpec.exportFormatCriteria
            ),
            CommandIntentSpec.exportFormatStatedQuestionID: .noul(
                instructions: .string(
                    "Does `request` say anything about which file format or program the result should be for?"
                ),
                criteria: NoulCriteria(
                    true: "The request names a format, a program, or a purpose that implies one - Word, a web page, printing, plain text.",
                    false: "The request asks only to get the document out, leaving the format open."
                )
            ),
        ]
    }

    static func request(for text: String, context: CommandIntentContext) -> TypeSafeRequest {
        TypeSafeRequest(state: state(for: text, context: context), questions: questions())
    }

    /// Reads the answers back into a command call, or nil when nothing matched
    /// well enough to show. Returning nil is the common case for ordinary
    /// typing and always leaves the palette's own filtering in charge.
    static func resolve(_ response: TypeSafeResponse) -> CommandIntentResult? {
        guard let command = response[CommandIntentSpec.commandQuestionID]?.choiceValue else {
            return nil
        }
        let ranked = command.probabilities
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .filter { $0.key == command.choice || $0.value >= minimumAlternativeProbability }
            .prefix(maximumAlternatives)
            .compactMap { ClioCommandID(rawValue: $0.key) }

        guard command.choice != CommandIntentSpec.noMatch,
              let matched = ClioCommandID(rawValue: command.choice),
              command.confidence >= minimumConfidence,
              command.probability >= minimumCommandProbability else { return nil }

        var confidence = min(command.confidence, command.probability)
        var arguments: [String] = []

        if matched == .export {
            let stated = response[CommandIntentSpec.exportFormatStatedQuestionID]?.noulValue ?? 0
            // Below the midpoint the request left the format open, so the
            // argument is omitted and Clio's own export picker decides.
            if stated >= 0.5, let format = response[CommandIntentSpec.exportFormatQuestionID]?.choiceValue,
               CommandIntentSpec.exportFormats.contains(format.choice) {
                arguments = [format.choice]
                confidence = min(confidence, format.probability)
            }
        }

        return CommandIntentResult(
            invocation: ClioCommandInvocation(command: matched, arguments: arguments),
            confidence: confidence,
            commandProbability: command.probability,
            ranked: ranked
        )
    }
}
