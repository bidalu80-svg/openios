import Foundation

enum CodeSourceFormatter {
    struct PythonIndentationQuality {
        let hasPythonCode: Bool
        let nonEmptyLines: Int
        let indentedLines: Int
        let blockHeaders: Int
        let badHeaderTransitions: Int
    }

    struct GenericCodeIndentationQuality {
        let nonEmptyLines: Int
        let indentedLines: Int
    }

    static func shouldPreserveLocalCodeIndentation(local: String, incoming: String) -> Bool {
        guard !local.isEmpty, !incoming.isEmpty, local != incoming else { return false }
        let localQuality = pythonIndentationQuality(in: local)
        let incomingQuality = pythonIndentationQuality(in: incoming)
        if localQuality.hasPythonCode, incomingQuality.hasPythonCode,
           localQuality.nonEmptyLines >= 8, incomingQuality.nonEmptyLines >= 8,
           localQuality.blockHeaders >= 2, incomingQuality.blockHeaders >= 2 {
            let localLooksStructured = localQuality.indentedLines >= 3
                && localQuality.badHeaderTransitions <= max(1, localQuality.blockHeaders / 5)
            let incomingLooksFlattened = incomingQuality.badHeaderTransitions >= max(2, incomingQuality.blockHeaders / 3)
                || (incomingQuality.indentedLines + 6 < localQuality.indentedLines
                    && incomingQuality.badHeaderTransitions > localQuality.badHeaderTransitions)

            if localLooksStructured && incomingLooksFlattened {
                return true
            }
        }

        return shouldPreserveGenericCodeIndentation(local: local, incoming: incoming)
    }

    private static func shouldPreserveGenericCodeIndentation(local: String, incoming: String) -> Bool {
        guard let localCode = genericCodeForIndentationComparison(in: local),
              let incomingCode = genericCodeForIndentationComparison(in: incoming) else {
            return false
        }
        guard whitespaceInsensitiveCodeFingerprint(localCode) == whitespaceInsensitiveCodeFingerprint(incomingCode) else {
            return false
        }
        let localQuality = genericCodeIndentationQuality(in: localCode)
        let incomingQuality = genericCodeIndentationQuality(in: incomingCode)
        guard localQuality.nonEmptyLines >= 8,
              incomingQuality.nonEmptyLines >= 8,
              localQuality.indentedLines >= 3 else {
            return false
        }
        return incomingQuality.indentedLines + 6 < localQuality.indentedLines
    }

    private static func genericCodeForIndentationComparison(in content: String) -> String? {
        let codeBlocks = fencedCodeBlocks(in: content).compactMap { block -> String? in
            let language = normalizedLanguage(block.language)
            guard isIndentationSensitiveCodeLanguage(language) else { return nil }
            let trimmed = block.code.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if !codeBlocks.isEmpty {
            return codeBlocks.joined(separator: "\n\n")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeGenericCode(trimmed) else { return nil }
        return trimmed
    }

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

    private static func isIndentationSensitiveCodeLanguage(_ language: String) -> Bool {
        switch language {
        case "bash", "zsh", "fish", "powershell", "ps1",
             "javascript", "jsx", "typescript", "tsx",
             "lua", "swift", "kotlin", "java", "go", "rust",
             "c", "cpp", "c++", "objc", "objective-c",
             "ruby", "php", "html", "css", "scss", "sass",
             "yaml", "yml", "toml", "xml", "sql":
            return true
        default:
            return false
        }
    }

    private static func looksLikeGenericCode(_ source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count >= 8 else { return false }
        let joined = nonEmpty.joined(separator: "\n").lowercased()
        let codeSignals = [
            "function ", "class ", "struct ", "enum ", "func ", "let ", "const ", "var ",
            "local ", " then", " do", " end", "#!/bin/", "<?php", "<html", "{", "}", ";"
        ]
        return codeSignals.contains { joined.contains($0) }
    }

    private static func genericCodeIndentationQuality(in code: String) -> GenericCodeIndentationQuality {
        let lines = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return GenericCodeIndentationQuality(
            nonEmptyLines: nonEmpty.count,
            indentedLines: nonEmpty.map { splitLeadingWhitespace($0) }.filter { $0.columns > 0 }.count
        )
    }

    private static func whitespaceInsensitiveCodeFingerprint(_ code: String) -> String {
        String(code.filter { !$0.isWhitespace })
    }

    private static func pythonIndentationQuality(in content: String) -> PythonIndentationQuality {
        let blocks = fencedCodeBlocks(in: content)
        var hasPythonCode = false
        var nonEmptyLines = 0
        var indentedLines = 0
        var blockHeaders = 0
        var badHeaderTransitions = 0

        for block in blocks {
            let language = normalizedLanguage(block.language)
            let bodyLooksPython = language.isEmpty && looksLikePythonCode(block.code)
            guard language == "python" || bodyLooksPython else { continue }
            hasPythonCode = true
            let quality = pythonCodeQuality(block.code)
            nonEmptyLines += quality.nonEmptyLines
            indentedLines += quality.indentedLines
            blockHeaders += quality.blockHeaders
            badHeaderTransitions += quality.badHeaderTransitions
        }

        if !hasPythonCode, looksLikePythonCode(content) {
            hasPythonCode = true
            let quality = pythonCodeQuality(content)
            nonEmptyLines = quality.nonEmptyLines
            indentedLines = quality.indentedLines
            blockHeaders = quality.blockHeaders
            badHeaderTransitions = quality.badHeaderTransitions
        }

        return PythonIndentationQuality(
            hasPythonCode: hasPythonCode,
            nonEmptyLines: nonEmptyLines,
            indentedLines: indentedLines,
            blockHeaders: blockHeaders,
            badHeaderTransitions: badHeaderTransitions
        )
    }

    private static func fencedCodeBlocks(in content: String) -> [(language: String?, code: String)] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [(language: String?, code: String)] = []
        var activeFence: String?
        var activeLanguage: String?
        var activeLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                if trimmed.hasPrefix(fence) {
                    blocks.append((activeLanguage, activeLines.joined(separator: "\n")))
                    activeFence = nil
                    activeLanguage = nil
                    activeLines.removeAll(keepingCapacity: true)
                } else {
                    activeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
                activeFence = marker
                let info = String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                activeLanguage = info.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first
                    .map(String.init)
            }
        }

        if activeFence != nil, !activeLines.isEmpty {
            blocks.append((activeLanguage, activeLines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func looksLikePythonCode(_ source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count >= 6 else { return false }
        return nonEmpty.contains {
            isPythonBlockHeader(splitLeadingWhitespace($0).body.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func pythonCodeQuality(_ code: String) -> PythonIndentationQuality {
        let lines = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else {
            return PythonIndentationQuality(
                hasPythonCode: false,
                nonEmptyLines: 0,
                indentedLines: 0,
                blockHeaders: 0,
                badHeaderTransitions: 0
            )
        }

        let splitLines = nonEmpty.map { splitLeadingWhitespace($0) }
        var blockHeaders = 0
        var badHeaderTransitions = 0

        for index in splitLines.indices.dropLast() {
            let current = splitLines[index]
            let currentTrimmed = current.body.trimmingCharacters(in: .whitespaces)
            guard isPythonBlockHeader(currentTrimmed) else { continue }
            blockHeaders += 1

            let next = splitLines[index + 1]
            let nextTrimmed = next.body.trimmingCharacters(in: .whitespaces)
            if next.columns <= current.columns,
               !nextTrimmed.hasPrefix("#"),
               !isPythonDedentClause(nextTrimmed) {
                badHeaderTransitions += 1
            }
        }

        if let last = splitLines.last,
           isPythonBlockHeader(last.body.trimmingCharacters(in: .whitespaces)) {
            blockHeaders += 1
        }

        return PythonIndentationQuality(
            hasPythonCode: blockHeaders > 0,
            nonEmptyLines: nonEmpty.count,
            indentedLines: splitLines.filter { $0.columns > 0 }.count,
            blockHeaders: blockHeaders,
            badHeaderTransitions: badHeaderTransitions
        )
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

}
