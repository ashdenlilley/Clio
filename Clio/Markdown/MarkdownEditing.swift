import AppKit

enum MarkdownWrapStyle: Equatable, Sendable {
    case emphasis
    case emphasisUnderscore
    case strong
    case strikethrough
    case code

    var marker: String {
        switch self {
        case .emphasis: return "*"
        case .emphasisUnderscore: return "_"
        case .strong: return "**"
        case .strikethrough: return "~~"
        case .code: return "`"
        }
    }
}

enum MarkdownIndentDirection: Sendable {
    case indent
    case outdent
}

enum MarkdownEditorAction: Sendable {
    case newline
    case indent
    case outdent
    case wrap(MarkdownWrapStyle)
    case paste(String)
}

struct MarkdownEditTransaction: Equatable, Sendable {
    let replacementRange: UTF16Range
    let replacement: String
    let selectionAfter: UTF16Range
    let actionName: String
}

enum MarkdownEditEngine {
    static func newline(in source: String, selection: UTF16Range) -> MarkdownEditTransaction? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        let caret = min(selection.location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location,
              text.character(at: contentEnd - 1) == 0x0A || text.character(at: contentEnd - 1) == 0x0D {
            contentEnd -= 1
        }
        let prefixSearch = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
        guard let regex = try? NSRegularExpression(
            pattern: #"^([ \t]*(?:> ?)*)([-+*]|([0-9]{1,9})([.)]))([ \t]+)(?:\[([ xX])\][ \t]+)?"#
        ), let match = regex.firstMatch(in: source, range: prefixSearch),
              match.range.location == lineRange.location,
              caret >= NSMaxRange(match.range) else { return nil }

        let bodyBeforeCaret = NSRange(
            location: NSMaxRange(match.range),
            length: caret - NSMaxRange(match.range)
        )
        if text.substring(with: bodyBeforeCaret).trimmingCharacters(in: .whitespaces).isEmpty,
           caret == contentEnd {
            let prefix = text.substring(with: match.range(at: 1))
            let replacementPrefix = outdentedEmptyItemPrefix(prefix)
            return MarkdownEditTransaction(
                replacementRange: match.range.utf16,
                replacement: replacementPrefix,
                selectionAfter: UTF16Range(
                    location: lineRange.location + (replacementPrefix as NSString).length,
                    length: 0
                ),
                actionName: "End List"
            )
        }

        let prefix = text.substring(with: match.range(at: 1))
        let markerRange = match.range(at: 2)
        let numberRange = match.range(at: 3)
        let delimiterRange = match.range(at: 4)
        let whitespace = text.substring(with: match.range(at: 5))
        let taskRange = match.range(at: 6)
        let marker: String
        if numberRange.location != NSNotFound,
           let number = Int(text.substring(with: numberRange)) {
            marker = "\(number + 1)" + text.substring(with: delimiterRange)
        } else {
            marker = text.substring(with: markerRange)
        }
        let task = taskRange.location == NSNotFound ? "" : "[ ] "
        let continuation = "\n" + prefix + marker + whitespace + task
        return MarkdownEditTransaction(
            replacementRange: UTF16Range(location: caret, length: 0),
            replacement: continuation,
            selectionAfter: UTF16Range(location: caret + (continuation as NSString).length, length: 0),
            actionName: "Continue List"
        )
    }

    static func wrap(
        _ style: MarkdownWrapStyle,
        in source: String,
        selection: UTF16Range
    ) -> MarkdownEditTransaction {
        let text = source as NSString
        let safe = selection.clamped(toUTF16Length: text.length)
        let marker = style.marker
        let markerLength = (marker as NSString).length
        let selected = text.substring(with: safe.nsRange)
        let replacement = marker + selected + marker
        let selectedAfter = selected.isEmpty
            ? UTF16Range(location: safe.location + markerLength, length: 0)
            : UTF16Range(location: safe.location + markerLength, length: safe.length)
        return MarkdownEditTransaction(
            replacementRange: safe,
            replacement: replacement,
            selectionAfter: selectedAfter,
            actionName: "Format Markdown"
        )
    }

    static func smartPaste(
        _ pasted: String,
        in source: String,
        selection: UTF16Range
    ) -> MarkdownEditTransaction? {
        let text = source as NSString
        let safe = selection.clamped(toUTF16Length: text.length)
        guard safe.length > 0,
              pasted.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: pasted),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme),
              scheme == "mailto" || components.host?.isEmpty == false else { return nil }
        let label = text.substring(with: safe.nsRange)
        let replacement = "[\(label)](\(pasted))"
        return MarkdownEditTransaction(
            replacementRange: safe,
            replacement: replacement,
            selectionAfter: UTF16Range(
                location: safe.location + (replacement as NSString).length,
                length: 0
            ),
            actionName: "Paste Link"
        )
    }

    static func indent(
        _ direction: MarkdownIndentDirection,
        in source: String,
        selection: UTF16Range
    ) -> MarkdownEditTransaction? {
        let text = source as NSString
        let safe = selection.clamped(toUTF16Length: text.length)
        let lineRange = text.lineRange(for: safe.nsRange)
        let original = text.substring(with: lineRange) as NSString
        let isListSelection = firstListMarker(in: original as String) != nil
        if !isListSelection {
            guard direction == .indent, safe.length == 0 else { return nil }
            return MarkdownEditTransaction(
                replacementRange: safe,
                replacement: "    ",
                selectionAfter: UTF16Range(location: safe.location + 4, length: 0),
                actionName: "Insert Spaces"
            )
        }
        let mutable = NSMutableString()
        var cursor = 0
        var removedBeforeSelection = 0
        var lineCount = 0
        while cursor < original.length {
            let localLine = original.lineRange(for: NSRange(location: cursor, length: 0))
            let value = original.substring(with: localLine)
            if direction == .indent {
                mutable.append("    " + value)
            } else {
                let valueText = value as NSString
                var remove = 0
                if valueText.length > 0, valueText.character(at: 0) == 0x09 {
                    remove = 1
                } else {
                    while remove < min(4, valueText.length), valueText.character(at: remove) == 0x20 {
                        remove += 1
                    }
                }
                mutable.append(valueText.substring(from: remove))
                if lineCount == 0 { removedBeforeSelection = remove }
            }
            cursor = NSMaxRange(localLine)
            lineCount += 1
        }
        guard lineCount > 0 else { return nil }
        let replacement = mutable as String
        let delta = (replacement as NSString).length - original.length
        let location: Int
        if direction == .indent {
            location = safe.location + 4
        } else {
            location = max(lineRange.location, safe.location - removedBeforeSelection)
        }
        return MarkdownEditTransaction(
            replacementRange: lineRange.utf16,
            replacement: replacement,
            selectionAfter: UTF16Range(
                location: location,
                length: safe.length == 0 ? 0 : max(0, safe.length + delta)
            ),
            actionName: direction == .indent ? "Indent List" : "Outdent List"
        )
    }

    private static func firstListMarker(in source: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*(?:> ?)*(?:[-+*]|[0-9]{1,9}[.)])(?:[ \t]+|$)"#
        ) else { return nil }
        return regex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        )
    }

    private static func outdentedEmptyItemPrefix(_ prefix: String) -> String {
        let value = prefix as NSString
        var whitespaceEnd = 0
        while whitespaceEnd < value.length {
            let scalar = value.character(at: whitespaceEnd)
            guard scalar == 0x20 || scalar == 0x09 else { break }
            whitespaceEnd += 1
        }
        let whitespace = value.substring(to: whitespaceEnd) as NSString
        let remainder = value.substring(from: whitespaceEnd)
        if whitespace.hasPrefix("\t") {
            return whitespace.substring(from: 1) + remainder
        }
        let removed = min(4, whitespace.length)
        return whitespace.substring(from: removed) + remainder
    }
}

@MainActor
final class MarkdownEditingController {
    func perform(_ action: MarkdownEditorAction, in textView: NSTextView) -> Bool {
        let source = textView.string
        let selection = textView.selectedRange().utf16
        let transaction: MarkdownEditTransaction?
        switch action {
        case .newline:
            transaction = MarkdownEditEngine.newline(in: source, selection: selection)
        case .indent:
            transaction = MarkdownEditEngine.indent(.indent, in: source, selection: selection)
        case .outdent:
            transaction = MarkdownEditEngine.indent(.outdent, in: source, selection: selection)
        case .wrap(let style):
            transaction = MarkdownEditEngine.wrap(style, in: source, selection: selection)
        case .paste(let value):
            transaction = MarkdownEditEngine.smartPaste(value, in: source, selection: selection)
        }
        guard let transaction,
              textView.shouldChangeText(
                  in: transaction.replacementRange.nsRange,
                  replacementString: transaction.replacement
              ), let storage = textView.textStorage else { return false }
        let range = transaction.replacementRange
            .clamped(toUTF16Length: storage.length)
            .nsRange
        let undoManager = textView.undoManager
        let ownsGroup = undoManager?.groupingLevel == 0
        if ownsGroup { undoManager?.beginUndoGrouping() }
        storage.replaceCharacters(in: range, with: transaction.replacement)
        textView.didChangeText()
        textView.setSelectedRange(transaction.selectionAfter.nsRange)
        undoManager?.setActionName(transaction.actionName)
        if ownsGroup { undoManager?.endUndoGrouping() }
        return true
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}
