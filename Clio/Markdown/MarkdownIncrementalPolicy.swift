import Foundation

/// Cheap edit validation and conservative structural invalidation. It avoids
/// reconstructing or hashing the complete buffer on each keystroke.
enum MarkdownIncrementalPolicy {
    private static let anchorLength = 64

    static func isContinuous(
        _ edit: MarkdownTextEdit,
        oldSource: String,
        newSource: String
    ) -> Bool {
        let old = oldSource as NSString
        let new = newSource as NSString
        let range = edit.replacedRange
        guard range.location <= old.length,
              range.upperBound <= old.length else { return false }
        let replacementLength = (edit.replacement as NSString).length
        guard old.length - range.length + replacementLength == new.length else { return false }
        guard new.substring(with: NSRange(
            location: range.location,
            length: replacementLength
        )) == edit.replacement else { return false }

        let prefixLength = min(anchorLength, range.location)
        let oldPrefix = NSRange(location: range.location - prefixLength, length: prefixLength)
        guard old.substring(with: oldPrefix) == new.substring(with: oldPrefix) else { return false }

        let oldSuffixStart = range.upperBound
        let newSuffixStart = range.location + replacementLength
        let suffixLength = min(anchorLength, old.length - oldSuffixStart)
        return old.substring(with: NSRange(location: oldSuffixStart, length: suffixLength))
            == new.substring(with: NSRange(location: newSuffixStart, length: suffixLength))
    }

    static func requiresFullReparse(
        _ edit: MarkdownTextEdit,
        oldSource: String,
        newSource: String
    ) -> Bool {
        let old = oldSource as NSString
        let removed = old.substring(with: edit.replacedRange.nsRange)
        if containsLineBreak(removed) || containsLineBreak(edit.replacement) { return true }
        if containsStructuralPunctuation(removed) || containsStructuralPunctuation(edit.replacement) {
            return true
        }
        return linesTouchStructure(edit, oldSource: oldSource, newSource: newSource)
    }

    private static func containsLineBreak(_ value: String) -> Bool {
        value.contains("\n") || value.contains("\r")
    }

    private static func containsStructuralPunctuation(_ value: String) -> Bool {
        value.unicodeScalars.contains { "`|#>=-+".unicodeScalars.contains($0) }
    }

    private static func linesTouchStructure(
        _ edit: MarkdownTextEdit,
        oldSource: String,
        newSource: String
    ) -> Bool {
        let replacementLength = (edit.replacement as NSString).length
        return neighborhood(
            around: edit.replacedRange.nsRange,
            in: oldSource
        ).contains(where: isStructuralLine)
            || neighborhood(
                around: NSRange(location: edit.replacedRange.location, length: replacementLength),
                in: newSource
            ).contains(where: isStructuralLine)
    }

    private static func neighborhood(around range: NSRange, in source: String) -> [String] {
        let text = source as NSString
        guard text.length > 0 else { return [""] }
        let location = min(range.location, text.length)
        let probe = NSRange(location: max(0, min(location, text.length - 1)), length: 0)
        var lineRange = text.lineRange(for: probe)
        if lineRange.location > 0 {
            lineRange = NSUnionRange(
                text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0)),
                lineRange
            )
        }
        if NSMaxRange(lineRange) < text.length {
            lineRange = NSUnionRange(
                lineRange,
                text.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0))
            )
        }
        return text.substring(with: lineRange).components(separatedBy: .newlines)
    }

    private static func isStructuralLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return true }
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("#") { return true }
        if trimmed.hasPrefix("---") || trimmed.hasPrefix("===") { return true }
        if trimmed.hasPrefix("[^"), trimmed.contains("]:") { return true }
        if trimmed.contains("|") { return true }
        if trimmed.range(of: #"^([-+*]|\d+[.)])\s"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}
