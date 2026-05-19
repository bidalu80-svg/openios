import Foundation

enum CodeSourceFormatter {
    static func formattedForDisplay(_ source: String, language: String?) -> String {
        let boundaryNormalized = trimBoundaryBlankLinesAndSharedIndent(source)
        let language = normalizedLanguage(language)

        if language == "python",
           shouldRepairPythonIndentation(boundaryNormalized) {
            return pythonIndentationCandidate(boundaryNormalized) ?? boundaryNormalized
        }
        if language == "json",
           let prettyJSON = prettyPrintedJSON(boundaryNormalized) {
            return prettyJSON
        }
        if braceIndentLanguages.contains(language),
           shouldRepairBraceIndentation(boundaryNormalized) {
            return braceIndentationCandidate(boundaryNormalized) ?? boundaryNormalized
        }
        return boundaryNormalized
    }

    static func formattedForWrite(_ source: String, language: String?) -> String {
        formattedForDisplay(source, language: language)
    }

    static func normalizedForWrite(_ source: String, language: String?) -> String? {
        let formatted = formattedForWrite(source, language: language)
        return formatted == source ? nil : formatted
    }

    private static let braceIndentLanguages: Set<String> = [
        "javascript", "typescript", "tsx", "jsx", "swift", "java", "kotlin",
        "go", "rust", "c", "cpp", "csharp", "php", "css", "scss", "less", "lua"
    ]

    private static func normalizedLanguage(_ language: String?) -> String {
        let normalized = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "py", "python3":
            return "python"
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "sh", "shell":
            return "bash"
        default:
            return normalized
        }
    }

    private static func trimBoundaryBlankLinesAndSharedIndent(_ source: String) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        let lines = normalized.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }

        var start = 0
        var end = lines.count - 1
        while start <= end, lines[start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start += 1
        }
        while end >= start, lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        guard start <= end else { return "" }

        let trimmedLines = Array(lines[start...end])
        let nonEmptyLines = trimmedLines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let sharedIndent = nonEmptyLines
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0

        let dedentedLines: [String]
        if sharedIndent > 0 {
            dedentedLines = trimmedLines.map { removeLeadingWhitespace(from: $0, count: sharedIndent) }
        } else {
            dedentedLines = trimmedLines
        }

        var result = dedentedLines.joined(separator: "\n")
        if hadTrailingNewline, !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    private static func prettyPrintedJSON(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              var pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        if source.hasSuffix("\n"), !pretty.hasSuffix("\n") {
            pretty += "\n"
        }
        return pretty
    }

    private static func shouldRepairBraceIndentation(_ source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count >= 3,
              nonEmpty.contains(where: { $0.contains("{") || $0.contains("(") || $0.contains("[") }) else {
            return false
        }
        let alreadyIndentedCount = nonEmpty.filter {
            splitLeadingWhitespace($0).columns > 0
        }.count
        return Double(alreadyIndentedCount) / Double(nonEmpty.count) < 0.25
    }

    private static func shouldRepairPythonIndentation(_ source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count >= 3 else { return false }

        let hasBlockHeader = nonEmpty.contains {
            isPythonBlockHeader(splitLeadingWhitespace($0).body.trimmingCharacters(in: .whitespaces))
        }
        guard hasBlockHeader else { return false }

        let alreadyIndentedCount = nonEmpty.filter {
            splitLeadingWhitespace($0).columns > 0
        }.count
        if Double(alreadyIndentedCount) / Double(nonEmpty.count) < 0.25 {
            return true
        }

        for index in nonEmpty.indices.dropLast() {
            let current = splitLeadingWhitespace(nonEmpty[index])
            let currentTrimmed = current.body.trimmingCharacters(in: .whitespaces)
            guard isPythonBlockHeader(currentTrimmed) else { continue }

            let next = splitLeadingWhitespace(nonEmpty[index + 1])
            let nextTrimmed = next.body.trimmingCharacters(in: .whitespaces)
            if next.columns <= current.columns,
               !nextTrimmed.hasPrefix("#"),
               !isPythonDedentClause(nextTrimmed) {
                return true
            }
        }
        return false
    }

    private static func braceIndentationCandidate(_ source: String) -> String? {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var rawLines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline {
            rawLines.removeLast()
        }

        var level = 0
        var changed = false
        var output: [String] = []
        output.reserveCapacity(rawLines.count)

        for rawLine in rawLines {
            let parts = splitLeadingWhitespace(rawLine)
            let body = parts.body
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                output.append("")
                continue
            }

            let startedWithClosingDelimiter = startsWithClosingDelimiter(trimmed)
            if startedWithClosingDelimiter {
                level = max(0, level - 1)
            }

            let targetColumns = max(0, level) * 4
            let useColumns: Int
            if parts.columns == 0, targetColumns > 0 {
                useColumns = targetColumns
                changed = true
            } else if parts.hadTabs {
                useColumns = max(parts.columns, targetColumns)
                changed = true
            } else {
                useColumns = parts.columns
            }
            output.append(String(repeating: " ", count: useColumns) + body)

            let delta = continuationDelta(trimmed)
            let compensatedDelta = delta + (startedWithClosingDelimiter ? 1 : 0)
            level = max(0, level + compensatedDelta)
        }

        guard changed else { return nil }
        var result = output.joined(separator: "\n")
        if hadTrailingNewline {
            result += "\n"
        }
        return result
    }

    private static func pythonIndentationCandidate(_ source: String) -> String? {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var rawLines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline {
            rawLines.removeLast()
        }

        var blockStack: [(kind: String, level: Int)] = []
        var repairedLines: [String] = []
        repairedLines.reserveCapacity(rawLines.count)
        var expectedLevel = 0
        var continuationLevel = 0
        var previousOpenedBlock = false
        var previousClosedInnerBlock = false
        var changed = false

        for rawLine in rawLines {
            let parts = splitLeadingWhitespace(rawLine)
            let body = parts.body
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                repairedLines.append("")
                continue
            }

            var targetLevel = expectedLevel
            if isClosingContinuationLine(trimmed), continuationLevel > 0 {
                continuationLevel = max(0, continuationLevel - 1)
            }
            if isPythonDedentClause(trimmed) {
                targetLevel = max(0, expectedLevel - 1)
                while let last = blockStack.last, last.level >= targetLevel {
                    blockStack.removeLast()
                }
                expectedLevel = targetLevel
            } else if parts.columns > 0,
                      expectedLevel > 0,
                      !previousOpenedBlock,
                      !previousClosedInnerBlock {
                let sourceLevel = max(0, parts.columns / 4)
                if sourceLevel < expectedLevel {
                    targetLevel = sourceLevel
                    while let last = blockStack.last, last.level >= targetLevel {
                        blockStack.removeLast()
                    }
                    expectedLevel = blockStack.last.map { $0.level + 1 } ?? 0
                    targetLevel = expectedLevel
                }
            } else if parts.columns == 0,
                      expectedLevel > 0,
                      !previousOpenedBlock,
                      let structuralLevel = pythonStructuralLevelForFlattenedLine(trimmed, stack: blockStack) {
                targetLevel = structuralLevel
                while let last = blockStack.last, last.level >= targetLevel {
                    blockStack.removeLast()
                }
                expectedLevel = targetLevel
            }
            targetLevel += continuationLevel

            let targetColumns = targetLevel * 4
            let useColumns: Int
            if parts.columns == 0, targetColumns > 0 {
                useColumns = targetColumns
                changed = true
            } else if parts.hadTabs {
                useColumns = max(parts.columns, targetColumns)
                changed = true
            } else if previousOpenedBlock, parts.columns < targetColumns {
                useColumns = targetColumns
                changed = true
            } else if previousClosedInnerBlock, parts.columns < targetColumns {
                useColumns = targetColumns
                changed = true
            } else {
                useColumns = parts.columns
            }

            repairedLines.append(String(repeating: " ", count: useColumns) + body)

            if isPythonBlockHeader(trimmed) {
                let blockLevel = useColumns / 4
                blockStack.append((kind: pythonBlockKind(trimmed), level: blockLevel))
                expectedLevel = blockLevel + 1
                previousOpenedBlock = true
                previousClosedInnerBlock = false
            } else {
                if isPythonTerminalStatement(trimmed),
                   let last = blockStack.last,
                   last.kind != "def",
                   last.kind != "class" {
                    blockStack.removeLast()
                    expectedLevel = blockStack.last.map { $0.level + 1 } ?? 0
                    previousClosedInnerBlock = true
                } else {
                    expectedLevel = blockStack.last.map { $0.level + 1 } ?? 0
                    previousClosedInnerBlock = false
                }
                previousOpenedBlock = false
            }

            let delta = continuationDelta(trimmed)
            if delta > 0 {
                continuationLevel += delta
            } else if delta < 0 {
                continuationLevel = max(0, continuationLevel + delta)
            }
        }

        guard changed else { return nil }
        var result = repairedLines.joined(separator: "\n")
        if hadTrailingNewline {
            result += "\n"
        }
        return result
    }

    private static func splitLeadingWhitespace(_ line: String) -> (body: String, columns: Int, hadTabs: Bool) {
        var columns = 0
        var hadTabs = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
                hadTabs = true
            } else {
                break
            }
            index = line.index(after: index)
        }
        return (String(line[index...]), columns, hadTabs)
    }

    private static func removeLeadingWhitespace(from line: String, count: Int) -> String {
        guard count > 0 else { return line }
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < count {
            let character = line[index]
            guard character == " " || character == "\t" else { break }
            removed += 1
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    private static func startsWithClosingDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("}") || trimmed.hasPrefix(")") || trimmed.hasPrefix("]")
    }

    private static func isPythonBlockHeader(_ line: String) -> Bool {
        let lowered = pythonLineWithoutTrailingComment(line).lowercased()
        guard lowered.hasSuffix(":") else { return false }
        if lowered.hasPrefix("#") { return false }
        return lowered.range(
            of: #"^(?:async\s+def|def|class|if|elif|else|for|async\s+for|while|try|except|finally|with|async\s+with|match|case)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isPythonDedentClause(_ line: String) -> Bool {
        line.range(
            of: #"^(?:elif\b.*|else|except\b.*|finally|case\b.*)\s*:\s*(?:#.*)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isPythonTerminalStatement(_ line: String) -> Bool {
        let lowered = pythonLineWithoutTrailingComment(line).lowercased()
        return lowered.range(
            of: #"^(?:return\b.*|raise\b.*|break\b|continue\b|pass\b)$"#,
            options: .regularExpression
        ) != nil
    }

    private static func pythonLineWithoutTrailingComment(_ line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        var result = ""

        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                escaped = true
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                result.append(character)
                continue
            }
            if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                result.append(character)
                continue
            }
            if character == "#", !inSingleQuote, !inDoubleQuote {
                break
            }
            result.append(character)
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func pythonStructuralLevelForFlattenedLine(
        _ line: String,
        stack: [(kind: String, level: Int)]
    ) -> Int? {
        let lowered = line.lowercased()
        if lowered.hasPrefix("@") {
            if let classBlock = stack.last(where: { $0.kind == "class" }) {
                return classBlock.level + 1
            }
            return 0
        }
        if lowered.range(
            of: #"^(?:from\s+\S+\s+import\b|import\s+\S+|class\s+\w|if\s+__name__\s*==)"#,
            options: .regularExpression
        ) != nil {
            return 0
        }
        if lowered.range(of: #"^(?:async\s+def|def)\s+\w"#, options: .regularExpression) != nil {
            if let classBlock = stack.last(where: { $0.kind == "class" }) {
                return classBlock.level + 1
            }
            return 0
        }
        return nil
    }

    private static func pythonBlockKind(_ line: String) -> String {
        let lowered = line.lowercased()
        if lowered.hasPrefix("class ") { return "class" }
        if lowered.hasPrefix("def ") || lowered.hasPrefix("async def ") { return "def" }
        if lowered.hasPrefix("try") || lowered.hasPrefix("except") || lowered.hasPrefix("finally") { return "try" }
        if lowered.hasPrefix("if ") || lowered.hasPrefix("elif ") || lowered.hasPrefix("else") { return "if" }
        if lowered.hasPrefix("for ") || lowered.hasPrefix("async for ") || lowered.hasPrefix("while ") { return "loop" }
        if lowered.hasPrefix("with ") || lowered.hasPrefix("async with ") { return "with" }
        if lowered.hasPrefix("match ") || lowered.hasPrefix("case ") { return "match" }
        return "block"
    }

    private static func isClosingContinuationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(")") || trimmed.hasPrefix("]") || trimmed.hasPrefix("}")
    }

    private static func continuationDelta(_ line: String) -> Int {
        let code = stripLineComment(line)
        var delta = 0
        var quote: Character?
        var escaped = false
        for character in code {
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" || character == "[" || character == "{" {
                delta += 1
            } else if character == ")" || character == "]" || character == "}" {
                delta -= 1
            }
        }
        return delta
    }

    private static func stripLineComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if let activeQuote = quote {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                result.append(character)
            } else if character == "#" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }
}
