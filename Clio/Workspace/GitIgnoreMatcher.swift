import Foundation

struct GitIgnoreRule: @unchecked Sendable, Equatable {
    let pattern: String
    let baseRelativePath: String
    let isNegated: Bool
    let sourceURL: URL?
    let line: Int?
    let builtIn: BuiltInExclusion?

    private let expression: String
    private let exactExpression: String
    private let isDirectoryOnly: Bool
    private let regex: NSRegularExpression
    private let exactRegex: NSRegularExpression

    init?(
        line rawLine: String,
        baseRelativePath: String = "",
        sourceURL: URL? = nil,
        lineNumber: Int? = nil,
        builtIn: BuiltInExclusion? = nil
    ) {
        var line = Self.strippingUnescapedTrailingSpaces(from: rawLine)
        guard !line.isEmpty, !line.hasSuffix("\\") else { return nil }

        if line.first == "#" { return nil }
        if line.hasPrefix("\\#") { line.removeFirst() }

        var isNegated = false
        if line.first == "!" {
            isNegated = true
            line.removeFirst()
        } else if line.hasPrefix("\\!") {
            line.removeFirst()
        }

        guard !line.isEmpty else { return nil }

        pattern = line
        self.baseRelativePath = Self.normalizeBase(baseRelativePath)
        self.isNegated = isNegated
        self.sourceURL = sourceURL
        line = line.replacingOccurrences(of: "\\ ", with: " ")
        self.line = lineNumber
        self.builtIn = builtIn
        isDirectoryOnly = line.hasSuffix("/")
        let expression = Self.makeExpression(
            pattern: line,
            baseRelativePath: Self.normalizeBase(baseRelativePath),
            includesDescendants: true
        )
        let exactExpression = Self.makeExpression(
            pattern: line,
            baseRelativePath: Self.normalizeBase(baseRelativePath),
            includesDescendants: false
        )
        guard let regex = try? NSRegularExpression(pattern: expression),
              let exactRegex = try? NSRegularExpression(pattern: exactExpression) else {
            return nil
        }
        self.expression = expression
        self.exactExpression = exactExpression
        self.regex = regex
        self.exactRegex = exactRegex
    }

    func matches(relativePath: String, isDirectory: Bool) -> Bool {
        let normalizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return false }
        let path = normalizedPath as NSString
        let range = NSRange(location: 0, length: path.length)
        guard regex.firstMatch(in: normalizedPath, range: range) != nil else {
            return false
        }

        if isDirectoryOnly, !isDirectory,
           exactRegex.firstMatch(in: normalizedPath, range: range) != nil {
            return false
        }
        return true
    }

    var exclusionReason: ExclusionReason {
        ExclusionReason(
            pattern: pattern,
            sourceURL: sourceURL,
            line: line,
            builtIn: builtIn
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pattern == rhs.pattern
            && lhs.baseRelativePath == rhs.baseRelativePath
            && lhs.isNegated == rhs.isNegated
            && lhs.sourceURL == rhs.sourceURL
            && lhs.line == rhs.line
            && lhs.builtIn == rhs.builtIn
            && lhs.expression == rhs.expression
            && lhs.exactExpression == rhs.exactExpression
            && lhs.isDirectoryOnly == rhs.isDirectoryOnly
    }
}

struct GitIgnoreMatcher: Sendable {
    private(set) var gitRules: [GitIgnoreRule] = []
    private let builtInRules: [GitIgnoreRule]
    private let additionalRules: [GitIgnoreRule]

    init(policy: DiscoveryPolicy) {
        var builtIns: [GitIgnoreRule] = []
        for builtIn in policy.enabledBuiltIns {
            for pattern in Self.patterns(for: builtIn) {
                if let rule = GitIgnoreRule(line: pattern, builtIn: builtIn) {
                    builtIns.append(rule)
                }
            }
        }

        var additional: [GitIgnoreRule] = []
        for (line, pattern) in policy.additionalPatterns.enumerated() {
            if let rule = GitIgnoreRule(line: pattern, lineNumber: line + 1) {
                additional.append(rule)
            }
        }
        builtInRules = builtIns
        additionalRules = additional
    }

    mutating func appendGitIgnore(
        source: String,
        sourceURL: URL,
        baseRelativePath: String
    ) {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() {
            if let rule = GitIgnoreRule(
                line: line,
                baseRelativePath: baseRelativePath,
                sourceURL: sourceURL,
                lineNumber: offset + 1
            ) {
                gitRules.append(rule)
            }
        }
    }

    func exclusionReason(
        for relativePath: String,
        isDirectory: Bool
    ) -> ExclusionReason? {
        var ignoredReason: ExclusionReason?
        evaluate(gitRules, path: relativePath, isDirectory: isDirectory, reason: &ignoredReason)
        evaluate(builtInRules, path: relativePath, isDirectory: isDirectory, reason: &ignoredReason)
        evaluate(additionalRules, path: relativePath, isDirectory: isDirectory, reason: &ignoredReason)
        return ignoredReason
    }

    private func evaluate(
        _ rules: [GitIgnoreRule],
        path: String,
        isDirectory: Bool,
        reason: inout ExclusionReason?
    ) {
        for rule in rules where rule.matches(relativePath: path, isDirectory: isDirectory) {
            reason = rule.isNegated ? nil : rule.exclusionReason
        }
    }
}

private extension GitIgnoreMatcher {
    static func patterns(for exclusion: BuiltInExclusion) -> [String] {
        switch exclusion {
        case .gitMetadata:
            [".git/"]
        case .nodeModules:
            ["node_modules/"]
        case .buildOutput:
            ["build/", ".build/", "DerivedData/", "dist/", "out/"]
        case .caches:
            [".cache/", "Caches/", "__pycache__/", ".pytest_cache/"]
        }
    }
}

private extension GitIgnoreRule {
    static func normalizeBase(_ base: String) -> String {
        base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func strippingUnescapedTrailingSpaces(from input: String) -> String {
        var result = input
        while result.last == " " {
            let backslashCount = result.dropLast().reversed().prefix(while: { $0 == "\\" }).count
            if backslashCount.isMultiple(of: 2) {
                result.removeLast()
            } else {
                break
            }
        }
        return result
    }

    static func makeExpression(
        pattern rawPattern: String,
        baseRelativePath: String,
        includesDescendants: Bool
    ) -> String {
        var pattern = rawPattern
        let directoryOnly = pattern.hasSuffix("/")
        if directoryOnly { pattern.removeLast() }

        let anchored = pattern.hasPrefix("/")
        if anchored { pattern.removeFirst() }
        let containsSlash = pattern.contains("/")
        let glob = globExpression(pattern)
        let escapedBase = NSRegularExpression.escapedPattern(for: baseRelativePath)
        let basePrefix = escapedBase.isEmpty ? "" : "\(escapedBase)/"

        let body: String
        if anchored || containsSlash {
            body = "^\(basePrefix)\(glob)"
        } else if baseRelativePath.isEmpty {
            body = "^(?:.*/)?\(glob)"
        } else {
            body = "^\(basePrefix)(?:.*/)?\(glob)"
        }

        // A matched directory makes every descendant ignored. This suffix also
        // models Git's behavior for a slashless name that resolves to a folder.
        return body + (includesDescendants ? "(?:/.*)?$" : "$" )
    }

    static func globExpression(_ pattern: String) -> String {
        let characters = Array(pattern)
        var result = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                var end = index
                while end < characters.count, characters[end] == "*" {
                    end += 1
                }
                let count = end - index
                let previousIsBoundary = index == 0 || characters[index - 1] == "/"
                let nextIsSlash = end < characters.count && characters[end] == "/"
                let nextIsEnd = end == characters.count

                if count >= 2, previousIsBoundary, index == 0, nextIsSlash {
                    result += "(?:.*/)?"
                    index = end + 1
                    continue
                }
                if count >= 2, previousIsBoundary, index > 0, nextIsSlash {
                    result += "(?:[^/]+/)*"
                    index = end + 1
                    continue
                }
                if count >= 2, previousIsBoundary, index > 0, nextIsEnd {
                    result += ".*"
                    index = end
                    continue
                }
                result += "[^/]*"
                index = end
                continue
            } else if character == "?" {
                result += "[^/]"
            } else if character == "[" {
                var cursor = index + 1
                var content = ""
                if cursor < characters.count,
                   characters[cursor] == "!" || characters[cursor] == "^" {
                    content = "^"
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == "]" {
                    content += "\\]"
                    cursor += 1
                }
                while cursor < characters.count, characters[cursor] != "]" {
                    if characters[cursor] == "\\", cursor + 1 < characters.count {
                        cursor += 1
                        content += NSRegularExpression.escapedPattern(
                            for: String(characters[cursor])
                        )
                    } else {
                        content.append(characters[cursor])
                    }
                    cursor += 1
                }
                if cursor < characters.count {
                    result += "[\(content)]"
                    index = cursor
                } else {
                    result += "\\["
                }
            } else if character == "\\", index + 1 < characters.count {
                index += 1
                result += NSRegularExpression.escapedPattern(
                    for: String(characters[index])
                )
            } else {
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }

        return result
    }
}
