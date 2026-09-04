import Foundation

/// Small, audited lexer bundled with Clio. It intentionally styles lexical
/// tokens only; malformed or unknown languages remain fully editable source.
enum MarkdownCodeTokenizer {
    static func spans(
        in source: String,
        offset: Int,
        language: String?,
        cancellation: MarkdownBackgroundWork.CancellationProbe? = nil
    ) throws -> [MarkdownSpan] {
        let text = source as NSString
        let dialect = Dialect(language)
        var spans: [MarkdownSpan] = []
        var cursor = 0

        func span(_ kind: CodeTokenKind, _ start: Int, _ end: Int) -> MarkdownSpan {
            MarkdownSpan(
                kind: .codeFence,
                role: .codeToken(kind),
                range: UTF16Range(location: offset + start, length: end - start)
            )
        }

        while cursor < text.length {
            if cursor.isMultiple(of: 4_096) {
                try Task.checkCancellation()
                try cancellation?.check()
            }
            let scalar = text.character(at: cursor)
            if isSpace(scalar) { cursor += 1; continue }

            if dialect.hashComments, scalar == 0x23 {
                let end = try lineEnd(in: text, from: cursor, cancellation: cancellation)
                spans.append(span(.comment, cursor, end)); cursor = end; continue
            }
            if scalar == 0x2F, cursor + 1 < text.length {
                let next = text.character(at: cursor + 1)
                if next == 0x2F {
                    let end = try lineEnd(in: text, from: cursor, cancellation: cancellation)
                    spans.append(span(.comment, cursor, end)); cursor = end; continue
                }
                if next == 0x2A {
                    var end = cursor + 2
                    while end + 1 < text.length,
                          !(text.character(at: end) == 0x2A && text.character(at: end + 1) == 0x2F) {
                        end += 1
                        if end.isMultiple(of: 4_096) {
                            try Task.checkCancellation()
                            try cancellation?.check()
                        }
                    }
                    end = min(text.length, end + (end + 1 < text.length ? 2 : 0))
                    spans.append(span(.comment, cursor, end)); cursor = end; continue
                }
            }

            if scalar == 0x22 || scalar == 0x27 || scalar == 0x60 {
                let quote = scalar
                let start = cursor
                cursor += 1
                var escaped = false
                while cursor < text.length {
                    let current = text.character(at: cursor)
                    cursor += 1
                    if cursor.isMultiple(of: 4_096) {
                        try Task.checkCancellation()
                        try cancellation?.check()
                    }
                    if current == 0x5C, !escaped { escaped = true; continue }
                    if current == quote, !escaped { break }
                    escaped = false
                }
                spans.append(span(.string, start, cursor)); continue
            }

            if isDigit(scalar) {
                let start = cursor
                cursor += 1
                while cursor < text.length {
                    let current = text.character(at: cursor)
                    guard isDigit(current) || current == 0x2E || current == 0x5F
                            || (current >= 0x41 && current <= 0x46)
                            || (current >= 0x61 && current <= 0x66) else { break }
                    cursor += 1
                    if cursor.isMultiple(of: 4_096) {
                        try Task.checkCancellation()
                        try cancellation?.check()
                    }
                }
                spans.append(span(.number, start, cursor)); continue
            }

            if isIdentifierStart(scalar) {
                let start = cursor
                cursor += 1
                while cursor < text.length, isIdentifierPart(text.character(at: cursor)) {
                    cursor += 1
                    if cursor.isMultiple(of: 4_096) {
                        try Task.checkCancellation()
                        try cancellation?.check()
                    }
                }
                let word = text.substring(with: NSRange(location: start, length: cursor - start))
                let kind: CodeTokenKind
                if dialect.keywords.contains(word) {
                    kind = .keyword
                } else if word.first?.isUppercase == true {
                    kind = .type
                } else if try previousNonspace(
                    in: text,
                    before: start,
                    cancellation: cancellation
                ) == 0x2E {
                    kind = .property
                } else if try nextNonspace(
                    in: text,
                    after: cursor,
                    cancellation: cancellation
                ) == 0x28 {
                    kind = .function
                } else {
                    continue
                }
                spans.append(span(kind, start, cursor)); continue
            }

            let kind: CodeTokenKind
            if [0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3B].contains(scalar) {
                kind = .punctuation
            } else if "+-*/%=!<>|&^~?:.".utf16.contains(scalar) {
                kind = .operatorSymbol
            } else {
                cursor += 1; continue
            }
            spans.append(span(kind, cursor, cursor + 1)); cursor += 1
        }
        return spans
    }

    private struct Dialect {
        let hashComments: Bool
        let keywords: Set<String>

        init(_ rawLanguage: String?) {
            let language = rawLanguage?
                .split(whereSeparator: { $0.isWhitespace })
                .first.map(String.init)?.lowercased() ?? ""
            hashComments = ["py", "python", "rb", "ruby", "sh", "bash", "zsh", "yaml", "yml"].contains(language)
            let common = [
                "as", "async", "await", "break", "case", "catch", "class", "continue",
                "default", "do", "else", "enum", "export", "extends", "false", "finally",
                "for", "from", "func", "function", "guard", "if", "import", "in", "interface",
                "let", "nil", "null", "private", "protocol", "public", "return", "self", "static",
                "struct", "switch", "throw", "throws", "true", "try", "typealias", "var", "while",
            ]
            var words = Set(common)
            switch language {
            case "py", "python": words.formUnion(["def", "elif", "except", "lambda", "none", "pass", "with", "yield"])
            case "rs", "rust": words.formUnion(["crate", "impl", "match", "mod", "mut", "pub", "trait", "unsafe"])
            case "js", "javascript", "ts", "typescript": words.formUnion(["const", "new", "of", "this", "typeof", "undefined"])
            case "swift": words.formUnion(["actor", "associatedtype", "defer", "extension", "some", "where"])
            default: break
            }
            keywords = words
        }
    }

    private static func lineEnd(
        in text: NSString,
        from start: Int,
        cancellation: MarkdownBackgroundWork.CancellationProbe?
    ) throws -> Int {
        var cursor = start
        while cursor < text.length {
            let scalar = text.character(at: cursor)
            if scalar == 0x0A || scalar == 0x0D { break }
            cursor += 1
            if cursor.isMultiple(of: 4_096) {
                try Task.checkCancellation()
                try cancellation?.check()
            }
        }
        return cursor
    }

    private static func previousNonspace(
        in text: NSString,
        before offset: Int,
        cancellation: MarkdownBackgroundWork.CancellationProbe?
    ) throws -> unichar? {
        var cursor = offset
        while cursor > 0 {
            cursor -= 1
            if cursor.isMultiple(of: 4_096) {
                try Task.checkCancellation()
                try cancellation?.check()
            }
            let scalar = text.character(at: cursor)
            if !isSpace(scalar) { return scalar }
        }
        return nil
    }

    private static func nextNonspace(
        in text: NSString,
        after offset: Int,
        cancellation: MarkdownBackgroundWork.CancellationProbe?
    ) throws -> unichar? {
        var cursor = offset
        while cursor < text.length {
            let scalar = text.character(at: cursor)
            if !isSpace(scalar) { return scalar }
            cursor += 1
            if cursor.isMultiple(of: 4_096) {
                try Task.checkCancellation()
                try cancellation?.check()
            }
        }
        return nil
    }
}

private func isSpace(_ scalar: unichar) -> Bool {
    scalar == 0x20 || scalar == 0x09 || scalar == 0x0A || scalar == 0x0D
}

private func isDigit(_ scalar: unichar) -> Bool { scalar >= 0x30 && scalar <= 0x39 }

private func isIdentifierStart(_ scalar: unichar) -> Bool {
    (scalar >= 0x41 && scalar <= 0x5A) || (scalar >= 0x61 && scalar <= 0x7A) || scalar == 0x5F
}

private func isIdentifierPart(_ scalar: unichar) -> Bool {
    isIdentifierStart(scalar) || isDigit(scalar)
}
