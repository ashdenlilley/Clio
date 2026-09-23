import Foundation

/// Reconstructs Markdown from plain text that lost its formatting.
///
/// Text pasted out of an email, a terminal or a plain-text export arrives hard
/// wrapped mid-sentence, with no heading markers and no list bullets. Two
/// passes put the structure back:
///
/// 1. **Stitch.** One yes/no question per adjacent pair of lines, asking whether
///    the line break tore a sentence in half. Continuation lines merge back into
///    blocks.
/// 2. **Classify.** One question per merged block choosing what kind of content
///    it is, with companion questions for heading level, step order and callout
///    kind asked up front and read only where they apply. The blocks do not
///    exist until the first pass has answered, which is why this is a second
///    request rather than more questions in the first.
///
/// The model never writes text. It answers questions about the paste, and the
/// renderer below assembles the result, so every character of the output came
/// from the input.
enum StructureRecovery {
    // MARK: - Reading the text

    struct Line: Hashable, Sendable {
        let text: String
        /// Whether a blank line separated this from the line before it. Blank
        /// lines are direct evidence, read in code and never sent for the model
        /// to reconsider.
        let precededByGap: Bool
    }

    struct Block: Hashable, Sendable {
        var text: String
        var lineIndices: [Int]
        var precededByGap: Bool
    }

    enum BlockKind: String, CaseIterable, Hashable, Sendable {
        case heading, paragraph, listItem = "list_item", quote, code, callout
    }

    enum HeadingLevel: String, Hashable, Sendable {
        case title, section, subsection

        var marker: String {
            switch self {
            case .title: return "#"
            case .section: return "##"
            case .subsection: return "###"
            }
        }
    }

    struct Judgment: Hashable, Sendable {
        var kind: BlockKind
        var confidence: Double
        var headingLevel: HeadingLevel
        var stepProbability: Double
        var calloutKind: String
    }

    // MARK: - Gates

    /// Longer blocks cannot read as a heading, so the heading-level companion
    /// question is not worth asking about them.
    static let headingMaxCharacters = 90
    /// A join this likely merges the pair when the previous line trailed off
    /// without punctuation.
    static let joinAfterDangling = 0.2
    /// After a full stop the bar is higher: a new sentence usually is one.
    static let joinAfterTerminal = 0.5
    /// A run of list items is numbered when its items' mean step probability
    /// reaches this. Whether a list is ordered is a property of the group, which
    /// no single question asked about directly.
    static let stepThreshold = 0.5
    /// Below this many characters a paste is not worth a round trip.
    static let minimumCharacters = 240
    /// Above this, the paste would crowd the model's per-request budget.
    static let maximumCharacters = 40_000

    /// Whether a paste is worth sending at all.
    ///
    /// Text that already carries Markdown markers is already structured, and a
    /// single unwrapped line has no line breaks to heal. Deciding this in code
    /// keeps the network quiet for the ordinary paste.
    static func shouldAttempt(_ pasted: String) -> Bool {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters,
              trimmed.count <= maximumCharacters else { return false }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 3 else { return false }
        return !carriesMarkdownMarkers(lines.map(String.init))
    }

    /// Direct evidence that the text kept its markup. One stray line starting
    /// with a dash is not enough; a document that kept its structure shows it
    /// repeatedly.
    static func carriesMarkdownMarkers(_ lines: [String]) -> Bool {
        let pattern = #"^\s{0,3}(#{1,6}\s|[-+*]\s|\d{1,9}[.)]\s|>\s?|```|~~~|\|)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let marked = lines.filter { line in
            let range = NSRange(location: 0, length: (line as NSString).length)
            return regex.firstMatch(in: line, range: range) != nil
        }
        return marked.count * 4 >= lines.count
    }

    static func lines(in text: String) -> [Line] {
        var lines: [Line] = []
        var gap = false
        for raw in text.components(separatedBy: .newlines) {
            let collapsed = raw.replacingOccurrences(
                of: "[\t ]+",
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            if collapsed.isEmpty {
                // A blank run before any content is not a separator.
                gap = !lines.isEmpty
                continue
            }
            lines.append(Line(text: collapsed, precededByGap: gap))
            gap = false
        }
        return lines
    }

    static func lineID(_ index: Int) -> String { String(format: "L%03d", index) }
    static func blockID(_ index: Int) -> String { String(format: "B%03d", index) }

    /// Renders the state the model reads. Each entry carries a short id, and the
    /// questions refer to those ids, so an answer names a specific line or block.
    static func tagged(_ items: [(text: String, gap: Bool)], prefix: String) -> String {
        items.enumerated().map { index, item in
            let lead = item.gap ? "\n" : ""
            return "\(lead)\(prefix)\(String(format: "%03d", index))| \(item.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Pass 1: stitch

    static func stitchRequest(for lines: [Line]) -> TypeSafeRequest {
        var questions: [String: TypeSafeQuestion] = [:]
        for index in lines.indices where index > 0 && !lines[index].precededByGap {
            questions[lineID(index)] = .noul(
                instructions: .string(
                    "Does line \(lineID(index)) pick up mid-sentence, continuing a sentence left unfinished at the end of line \(lineID(index - 1))?"
                ),
                criteria: NoulCriteria(
                    true: "The line starts in the middle of a sentence that began on the previous line - the line break tore the sentence apart.",
                    false: "The line begins a new sentence, item, heading, or thought of its own."
                )
            )
        }
        let state = tagged(lines.map { ($0.text, $0.precededByGap) }, prefix: "L")
        return TypeSafeRequest(state: .string(state), questions: questions)
    }

    static func joins(from response: TypeSafeResponse, lineCount: Int) -> [Double] {
        (0..<lineCount).map { response[lineID($0)]?.noulValue ?? 0 }
    }

    static func endsTerminally(_ text: String) -> Bool {
        text.range(of: #"[.!?:;…]["')\]]*$"#, options: .regularExpression) != nil
    }

    static func merge(_ lines: [Line], joins: [Double]) -> [Block] {
        var blocks: [Block] = []
        for (index, line) in lines.enumerated() {
            let bar = index > 0 && endsTerminally(lines[index - 1].text)
                ? joinAfterTerminal
                : joinAfterDangling
            let join = index < joins.count ? joins[index] : 0
            if !blocks.isEmpty, !line.precededByGap, join >= bar {
                blocks[blocks.count - 1].text += " " + line.text
                blocks[blocks.count - 1].lineIndices.append(index)
            } else {
                blocks.append(Block(
                    text: line.text,
                    lineIndices: [index],
                    precededByGap: line.precededByGap
                ))
            }
        }
        return blocks
    }

    // MARK: - Pass 2: classify

    static let kindCriteria: [String: String] = [
        BlockKind.heading.rawValue:
            "A short label or title naming the document or the section that follows it - not a full sentence of content.",
        BlockKind.paragraph.rawValue:
            "Running prose: one or more complete sentences of explanatory or narrative text.",
        BlockKind.listItem.rawValue:
            "One entry in a list of parallel items - a task, a feature, a name; it reads as one of several sibling entries.",
        BlockKind.quote.rawValue:
            "Words attributed to a person or source - quoted speech, a citation, an excerpt someone else wrote.",
        BlockKind.code.rawValue:
            "Computer code, a shell command, terminal output, or a config snippet meant to be read verbatim.",
        BlockKind.callout.rawValue:
            "A warning, tip, or important note interrupting the flow to flag something the reader must not miss.",
    ]

    static let headingLevelCriteria: [String: String] = [
        HeadingLevel.title.rawValue: "The title of the whole document.",
        HeadingLevel.section.rawValue: "A major section heading within the document.",
        HeadingLevel.subsection.rawValue: "A minor heading nested under a section.",
    ]

    static let calloutCriteria: [String: String] = [
        "note": "Neutral extra information the reader should be aware of.",
        "tip": "A helpful suggestion or shortcut that makes things easier.",
        "warning": "A caution about something that can go wrong or cause harm.",
    ]

    static func classifyRequest(for blocks: [Block]) -> TypeSafeRequest {
        var questions: [String: TypeSafeQuestion] = [:]
        for (index, block) in blocks.enumerated() {
            let id = blockID(index)
            questions["type_\(id)"] = .choice(
                instructions: .string("What kind of content is block \(id)?"),
                criteria: kindCriteria
            )
            if block.text.count <= headingMaxCharacters {
                questions["hlevel_\(id)"] = .choice(
                    instructions: .string(
                        "As a heading, what level would block \(id) occupy in this document's structure?"
                    ),
                    criteria: headingLevelCriteria
                )
            }
            questions["step_\(id)"] = .noul(
                instructions: .string(
                    "Is block \(id) an instruction in a sequence where the order of the items matters?"
                ),
                criteria: NoulCriteria(
                    true: "It is one step of a procedure - the items around it must happen in order.",
                    false: "Order is irrelevant - it is a loose collection, or not a list item at all."
                )
            )
            questions["callout_\(id)"] = .choice(
                instructions: .string("What kind of aside is block \(id)?"),
                criteria: calloutCriteria
            )
        }
        let state = tagged(blocks.map { ($0.text, $0.precededByGap) }, prefix: "B")
        return TypeSafeRequest(state: .string(state), questions: questions)
    }

    static func judgments(from response: TypeSafeResponse, blockCount: Int) -> [Judgment] {
        (0..<blockCount).map { index in
            let id = blockID(index)
            let kindAnswer = response["type_\(id)"]?.choiceValue
            let kind = kindAnswer.flatMap { BlockKind(rawValue: $0.choice) } ?? .paragraph
            let level = response["hlevel_\(id)"]?.choiceValue
                .flatMap { HeadingLevel(rawValue: $0.choice) } ?? .section
            return Judgment(
                kind: kind,
                confidence: kindAnswer?.confidence ?? 0,
                headingLevel: level,
                stepProbability: response["step_\(id)"]?.noulValue ?? 0,
                calloutKind: response["callout_\(id)"]?.choiceValue?.choice ?? "note"
            )
        }
    }

    // MARK: - Rendering

    /// Assembles Markdown from the blocks and their judgments.
    ///
    /// Callouts render as a labelled blockquote rather than an alert directive,
    /// because a blockquote is plain CommonMark and survives every one of
    /// Clio's exporters.
    static func render(_ blocks: [Block], judgments: [Judgment]) -> String {
        var output: [String] = []
        var index = 0
        while index < blocks.count {
            let judgment = judgments[index]
            switch judgment.kind {
            case .heading:
                output.append("\(judgment.headingLevel.marker) \(blocks[index].text)")
                index += 1
            case .listItem:
                var run: [Int] = []
                while index < blocks.count, judgments[index].kind == .listItem {
                    run.append(index)
                    index += 1
                }
                let mean = run.reduce(0.0) { $0 + judgments[$1].stepProbability } / Double(run.count)
                let ordered = mean >= stepThreshold
                output.append(run.enumerated().map { position, block in
                    let marker = ordered ? "\(position + 1)." : "-"
                    return "\(marker) \(blocks[block].text)"
                }.joined(separator: "\n"))
            case .code:
                var run: [Int] = []
                while index < blocks.count, judgments[index].kind == .code {
                    run.append(index)
                    index += 1
                }
                let body = run.map { blocks[$0].text }.joined(separator: "\n")
                output.append("```\n\(body)\n```")
            case .quote:
                output.append(quoted(blocks[index].text))
                index += 1
            case .callout:
                let label = judgment.calloutKind.prefix(1).uppercased()
                    + judgment.calloutKind.dropFirst()
                output.append(quoted("**\(label):** \(blocks[index].text)"))
                index += 1
            case .paragraph:
                output.append(blocks[index].text)
                index += 1
            }
        }
        return output.joined(separator: "\n\n")
    }

    private static func quoted(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
    }
}
