import Foundation

enum LocalAlpinePythonWriteGuard {
    enum Source: String, Sendable {
        case content
        case codeLines = "code_lines"
        case contentLines = "content_lines"
        case contentBase64 = "content_base64"
        case heredoc
        case codeBlock = "code_block"

        var displayName: String { rawValue }
    }

    enum Preparation: Sendable {
        case success(content: String, notes: [String])
        case failure(String)
    }

    struct SyntaxRepair: Sendable {
        let content: String
        let notes: [String]
    }

    private struct ExtractedCode {
        let content: String
        let notes: [String]
    }

    private enum Extraction {
        case success(ExtractedCode)
        case failure(String)
    }

    static func prepare(_ content: String, source: Source) -> Preparation {
        let extracted: ExtractedCode
        switch source {
        case .codeLines, .contentLines, .contentBase64:
            extracted = ExtractedCode(
                content: content,
                notes: ["结构化 Python 源码按工具参数原样接收，未经过 Markdown 清洗或缩进重排。"]
            )
        case .content, .heredoc, .codeBlock:
            switch extractPythonCode(from: content, source: source) {
            case .success(let value):
                extracted = value
            case .failure(let message):
                return .failure(message)
            }
        }

        guard !extracted.content.trimmingCharacters(in: .newlines).isEmpty else {
            return .failure("Python 文件内容为空")
        }

        let preparedContent = normalizeNewlines(extracted.content)
        return .success(content: ensureTrailingNewline(preparedContent), notes: extracted.notes)
    }

    static func normalizeGeneratedPython(_ content: String, source: Source) -> (content: String, notes: [String]) {
        let extracted: ExtractedCode
        switch source {
        case .codeLines, .contentLines, .contentBase64:
            extracted = ExtractedCode(
                content: content,
                notes: ["结构化 Python 源码按工具参数原样接收，未经过 Markdown 清洗或缩进重排。"]
            )
        case .content, .heredoc, .codeBlock:
            switch extractPythonCode(from: content, source: source) {
            case .success(let value):
                extracted = value
            case .failure:
                extracted = ExtractedCode(
                    content: normalizeNewlines(content).trimmingCharacters(in: .newlines),
                    notes: []
                )
            }
        }

        var prepared = normalizeNewlines(extracted.content).trimmingCharacters(in: .newlines)
        var notes = extracted.notes

        let mojibakeRepair = repairCommonUTF8Mojibake(in: prepared)
        prepared = mojibakeRepair.content
        notes.append(contentsOf: mojibakeRepair.notes)

        let tabRepair = normalizeLeadingTabs(in: prepared)
        prepared = tabRepair.content
        notes.append(contentsOf: tabRepair.notes)

        let topLevelRepair = repairCommonTopLevelPythonEntryPoints(in: prepared)
        prepared = topLevelRepair.content
        notes.append(contentsOf: topLevelRepair.notes)

        return (ensureTrailingNewline(prepared), notes)
    }

    static func repairCollapsedIndentationIfNeeded(_ content: String) -> (content: String, notes: [String])? {
        let normalized = normalizeNewlines(content).trimmingCharacters(in: .newlines)
        guard looksCollapsedIndentation(normalized) else { return nil }
        let rebuilt = rebuildIndentation(from: normalized)
        guard rebuilt != normalized,
              !rebuilt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (
            content: ensureTrailingNewline(rebuilt),
            notes: ["检测到 Python 代码块缩进几乎全部丢失，已在写入层按 Python 语法块重建缩进。"]
        )
    }

    static func repairForSyntaxIssue(_ content: String, diagnosticOutput: String) -> SyntaxRepair? {
        repairCandidatesForSyntaxIssue(content, diagnosticOutput: diagnosticOutput).first
    }

    static func repairCandidatesForSyntaxIssue(_ content: String, diagnosticOutput: String) -> [SyntaxRepair] {
        let normalized = normalizeNewlines(content).trimmingCharacters(in: .newlines)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var candidates: [SyntaxRepair] = []
        if let collapsed = repairCollapsedIndentationIfNeeded(normalized) {
            candidates.append(SyntaxRepair(content: collapsed.content, notes: collapsed.notes))
        }
        candidates.append(contentsOf: syntaxRepairCandidates(for: normalized, diagnosticOutput: diagnosticOutput).map {
            SyntaxRepair(
                content: ensureTrailingNewline($0.trimmingCharacters(in: .newlines)),
                notes: ["根据 Python 语法错误定位，将疑似丢失缩进的代码块向内缩进后重新校验。"]
            )
        })

        var seen = Set<String>()
        return candidates.filter { candidate in
            guard !seen.contains(candidate.content) else { return false }
            seen.insert(candidate.content)
            return true
        }
    }

    private static func extractPythonCode(from content: String, source: Source) -> Extraction {
        guard content.range(of: #"(?m)^\s*```"#, options: .regularExpression) != nil else {
            return .success(ExtractedCode(content: normalizeNewlines(content).trimmingCharacters(in: .newlines), notes: []))
        }

        guard let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#) else {
            return .failure("Python 代码块解析器不可用")
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = regex.matches(in: content, range: fullRange)
        guard !matches.isEmpty else {
            return .failure("检测到未闭合的 markdown 代码块，拒绝保存不完整 Python 文件")
        }

        var fallback: ExtractedCode?
        for match in matches where match.numberOfRanges >= 3 {
            let info = nsContent.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let body = nsContent.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .newlines)
            let extracted = ExtractedCode(
                content: body,
                notes: ["已从 markdown 代码块提取 Python 源码，未保存回复说明文本"]
            )
            if fallback == nil {
                fallback = extracted
            }
            if info.isEmpty || info == "python" || info == "py" || info.hasPrefix("python ") {
                return .success(extracted)
            }
        }

        if let fallback {
            return .success(fallback)
        }
        return .failure("未找到可保存的 Python 代码块")
    }

    private static func normalizeLeadingTabs(in content: String) -> (content: String, notes: [String]) {
        let lines = content.components(separatedBy: .newlines)
        var changedLines: [Int] = []

        let normalized = lines.enumerated().map { offset, rawLine in
            var prefix = ""
            var index = rawLine.startIndex
            var changed = false

            while index < rawLine.endIndex {
                let character = rawLine[index]
                if character == "\t" {
                    prefix += "    "
                    changed = true
                } else if character == " " {
                    prefix.append(character)
                } else {
                    break
                }
                index = rawLine.index(after: index)
            }

            guard changed else { return rawLine }
            changedLines.append(offset + 1)
            return prefix + String(rawLine[index...])
        }

        guard !changedLines.isEmpty else { return (content, []) }
        let note = "已按 VS Code/Python 默认设置将行首 Tab 转换为 4 个空格：第 \(changedLines.prefix(12).map(String.init).joined(separator: ", ")) 行"
        return (normalized.joined(separator: "\n"), [note])
    }

    private static func repairCommonTopLevelPythonEntryPoints(in content: String) -> (content: String, notes: [String]) {
        let lines = content.components(separatedBy: "\n")
        var repaired = lines
        var changed = false
        var notes: [String] = []

        if let hoisted = hoistMisnestedMainFunctionIfNeeded(repaired) {
            repaired = hoisted.lines
            changed = true
            notes.append(hoisted.note)
        }

        for index in repaired.indices {
            let stripped = repaired[index].trimmingCharacters(in: .whitespaces)
            if stripped == "if __name__ == '__main__':"
                || stripped == #"if __name__ == "__main__":"# {
                let currentIndent = repaired[index].prefix { $0 == " " || $0 == "\t" }.count
                if currentIndent > 0 {
                    repaired[index] = stripped
                    changed = true
                    if index + 1 < repaired.count {
                        let next = repaired[index + 1].trimmingCharacters(in: .whitespaces)
                        if next == "main()" {
                            repaired[index + 1] = "    main()"
                            changed = true
                        }
                    }
                }
            }
        }

        guard changed else { return (content, []) }
        if notes.isEmpty {
            notes.append("已将常见 Python 入口 `if __name__ == '__main__': main()` 修正为文件顶层，避免被误缩进进 class/function。")
        }
        return (
            repaired.joined(separator: "\n"),
            notes
        )
    }

    private static func hoistMisnestedMainFunctionIfNeeded(_ lines: [String]) -> (lines: [String], note: String)? {
        guard hasTopLevelMainCall(lines), !hasTopLevelMainDefinition(lines) else { return nil }
        guard let functionStart = lines.firstIndex(where: { line in
            leadingWhitespaceWidth(line) > 0
                && line.trimmingCharacters(in: .whitespaces).hasPrefix("def main(")
        }) else { return nil }

        let baseIndent = leadingWhitespaceWidth(lines[functionStart])
        var end = functionStart + 1
        while end < lines.count {
            let line = lines[end]
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty {
                end += 1
                continue
            }
            if leadingWhitespaceWidth(line) <= baseIndent {
                break
            }
            end += 1
        }

        var mainBlock = Array(lines[functionStart..<end]).map { removeIndentPrefix(baseIndent, from: $0) }
        while mainBlock.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            mainBlock.removeLast()
        }
        guard !mainBlock.isEmpty else { return nil }

        var repaired = lines
        repaired.removeSubrange(functionStart..<end)
        while repaired.indices.contains(functionStart),
              repaired[functionStart].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              repaired.indices.contains(functionStart + 1),
              repaired[functionStart + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            repaired.remove(at: functionStart)
        }

        let insertIndex = repaired.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("if __name__")
        }) ?? repaired.count
        var insertion = mainBlock
        if insertIndex > 0,
           repaired[insertIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            insertion.insert("", at: 0)
        }
        if insertIndex < repaired.count,
           repaired[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            insertion.append("")
        }
        repaired.insert(contentsOf: insertion, at: insertIndex)

        return (
            repaired,
            "检测到 `def main()` 被误缩进在 class/function 内，但文件顶层调用了 `main()`；已将 `main()` 函数提升到文件顶层。"
        )
    }

    private static func hasTopLevelMainCall(_ lines: [String]) -> Bool {
        for index in lines.indices {
            let stripped = lines[index].trimmingCharacters(in: .whitespaces)
            guard stripped == "if __name__ == '__main__':"
                    || stripped == #"if __name__ == "__main__":"# else {
                continue
            }
            let nextIndex = index + 1
            if lines.indices.contains(nextIndex),
               lines[nextIndex].trimmingCharacters(in: .whitespaces) == "main()" {
                return true
            }
        }
        return false
    }

    private static func hasTopLevelMainDefinition(_ lines: [String]) -> Bool {
        lines.contains { line in
            leadingWhitespaceWidth(line) == 0
                && line.trimmingCharacters(in: .whitespaces).hasPrefix("def main(")
        }
    }

    private static func leadingWhitespaceWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private static func removeIndentPrefix(_ width: Int, from line: String) -> String {
        var remaining = width
        var index = line.startIndex
        while index < line.endIndex, remaining > 0 {
            let character = line[index]
            if character == " " {
                remaining -= 1
            } else if character == "\t" {
                remaining -= 4
            } else {
                break
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    private static func looksCollapsedIndentation(_ content: String) -> Bool {
        let meaningfulLines = content
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard meaningfulLines.count >= 4 else { return false }
        let colonLines = meaningfulLines.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(":")
                && !trimmed.hasPrefix("#")
                && !trimmed.hasPrefix("case ")
        }
        guard !colonLines.isEmpty else { return false }

        let leadingWidths = meaningfulLines.map { line -> Int in
            line.prefix { $0 == " " || $0 == "\t" }.count
        }
        guard let maxLeading = leadingWidths.max(), maxLeading <= 1 else { return false }

        for index in 0..<(meaningfulLines.count - 1) {
            let current = meaningfulLines[index].trimmingCharacters(in: .whitespaces)
            let next = meaningfulLines[index + 1]
            guard current.hasSuffix(":") else { continue }
            let nextLeading = next.prefix { $0 == " " || $0 == "\t" }.count
            if nextLeading <= leadingWidths[index] {
                return true
            }
        }
        return false
    }

    private static func firstDiagnosticLineNumber(in output: String) -> Int? {
        let preferredPatterns = [
            #"File\s+"<unknown>",\s*line\s+(\d+)"#,
            #"\(<unknown>,\s*line\s+(\d+)\)"#
        ]
        for pattern in preferredPatterns {
            if let line = firstLineNumber(matching: pattern, in: output) {
                return line
            }
        }
        if output.lowercased().contains("expected an indented block"),
           let parentLine = lastLineNumber(matching: #"after\s+['"][^'"]+['"]\s+statement\s+on\s+line\s+(\d+)"#, in: output) {
            return parentLine + 1
        }
        return lastLineNumber(matching: #"\bline\s+(\d+)\b"#, in: output)
    }

    private static func firstLineNumber(matching pattern: String, in output: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges >= 2,
              let swiftRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Int(String(output[swiftRange]))
    }

    private static func lastLineNumber(matching pattern: String, in output: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var lineNumber: Int?
        regex.enumerateMatches(in: output, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 2,
                  let swiftRange = Range(match.range(at: 1), in: output),
                  let line = Int(String(output[swiftRange])) else {
                return
            }
            lineNumber = line
        }
        return lineNumber
    }

    private static func syntaxRepairCandidates(for content: String, diagnosticOutput: String) -> [String] {
        guard let lineNumber = firstDiagnosticLineNumber(in: diagnosticOutput) else { return [] }
        let lines = content.components(separatedBy: "\n")
        guard lineNumber > 1, lineNumber <= lines.count else { return [] }

        let currentIndex = lineNumber - 1
        var candidates: [String] = []
        for previousIndex in stride(from: currentIndex - 1, through: 0, by: -1) {
            let previous = lines[previousIndex].trimmingCharacters(in: .whitespaces)
            guard !previous.isEmpty else { continue }
            if previous.hasSuffix(":") {
                candidates.append(reindentLineRange(lines, startIndex: currentIndex, baseIndex: previousIndex))
            }
            break
        }
        return candidates
    }

    private static func reindentLineRange(_ lines: [String], startIndex: Int, baseIndex: Int) -> String {
        var repaired = lines
        let baseIndent = lines[baseIndex].prefix { $0 == " " || $0 == "\t" }
        let nestedIndent = String(baseIndent) + "    "
        let originalIndentWidth = lines[startIndex].prefix { $0 == " " || $0 == "\t" }.count

        for index in startIndex..<lines.count {
            let stripped = lines[index].trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let currentIndentWidth = lines[index].prefix { $0 == " " || $0 == "\t" }.count
            if index > startIndex && currentIndentWidth < originalIndentWidth {
                break
            }
            if startsBlockPeer(stripped) && currentIndentWidth <= originalIndentWidth {
                break
            }
            repaired[index] = nestedIndent + stripped
            if stripped.hasPrefix("except") || stripped.hasPrefix("finally:") {
                break
            }
        }

        return repaired.joined(separator: "\n")
    }

    private static func startsBlockPeer(_ line: String) -> Bool {
        startsDefinition(line)
            || line.hasPrefix("except")
            || line.hasPrefix("finally:")
            || line.hasPrefix("elif ")
            || line.hasPrefix("else:")
    }

    private enum PythonBlockKind: Hashable {
        case `class`
        case function
        case `if`
        case `try`
        case loop
        case with
        case except
        case `else`
        case other
    }

    private static func rebuildIndentation(from content: String) -> String {
        let rawLines = content.components(separatedBy: "\n")
        var rebuilt: [String] = []
        var stack: [PythonBlockKind] = []
        var continuationClosers: [Character] = []
        var blankRun = 0
        var previousOpenedBlock = false
        var previousSignificant = ""

        for rawLine in rawLines {
            let stripped = rawLine.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else {
                rebuilt.append("")
                blankRun += 1
                previousOpenedBlock = false
                continue
            }

            let continuationDepth = continuationDepthForIndent(line: stripped, stack: continuationClosers)
            let isContinuationLine = continuationDepth > 0 || startsWithClosingDelimiter(stripped)

            if !isContinuationLine {
                if startsAlwaysTopLevel(stripped) || (blankRun >= 2 && startsLikelyTopLevel(stripped)) {
                    stack.removeAll()
                } else if startsDefinition(stripped) {
                    stack = definitionParent(for: stack, blankRun: blankRun)
                } else if stripped.hasPrefix("elif ") {
                    popUntilContinuationParent(&stack, matching: .if, fallback: .other)
                } else if stripped.hasPrefix("except") || stripped.hasPrefix("finally:") {
                    popUntilContinuationParent(&stack, matchingAny: [.try, .except], fallback: .other)
                } else if stripped.hasPrefix("else:") {
                    popUntilContinuationParent(&stack, matchingAny: [.if, .try, .loop, .except, .else], fallback: .other)
                } else if startsNewIfSibling(stripped, previousOpenedBlock: previousOpenedBlock, stack: stack) {
                    _ = stack.popLast()
                } else {
                    if isTerminalStatement(previousSignificant) {
                        popOneCompletedBlock(&stack)
                    } else if blankRun > 0 {
                        popOneCompletedBlock(&stack)
                    }
                }
            }

            rebuilt.append(String(repeating: " ", count: (stack.count + continuationDepth) * 4) + stripped)

            if !isContinuationLine && opensPythonBlock(stripped) {
                stack.append(blockKind(for: stripped))
            }
            updateContinuationClosers(&continuationClosers, with: stripped)
            previousOpenedBlock = opensPythonBlock(stripped)
            previousSignificant = stripped
            blankRun = 0
        }

        return rebuilt.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func startsLikelyTopLevel(_ line: String) -> Bool {
        startsDefinition(line) || line.hasPrefix("if __name__")
    }

    private static func startsAlwaysTopLevel(_ line: String) -> Bool {
        line.hasPrefix("if __name__")
    }

    private static func startsDefinition(_ line: String) -> Bool {
        line.hasPrefix("def ")
            || line.hasPrefix("async def ")
            || line.hasPrefix("class ")
    }

    private static func startsNewIfSibling(
        _ line: String,
        previousOpenedBlock: Bool,
        stack: [PythonBlockKind]
    ) -> Bool {
        line.hasPrefix("if ")
            && previousOpenedBlock == false
            && stack.last == .if
    }

    private static func definitionParent(for stack: [PythonBlockKind], blankRun: Int) -> [PythonBlockKind] {
        if blankRun >= 2 {
            return []
        }
        if let classIndex = stack.lastIndex(of: .class) {
            return Array(stack.prefix(through: classIndex))
        }
        if blankRun == 0 {
            return stack
        }
        return []
    }

    private static func popOneCompletedBlock(_ stack: inout [PythonBlockKind]) {
        guard let last = stack.last,
              last != .class,
              last != .function else {
            return
        }
        _ = stack.popLast()
    }

    private static func popUntilContinuationParent(
        _ stack: inout [PythonBlockKind],
        matching kind: PythonBlockKind,
        fallback: PythonBlockKind
    ) {
        popUntilContinuationParent(&stack, matchingAny: [kind], fallback: fallback)
    }

    private static func popUntilContinuationParent(
        _ stack: inout [PythonBlockKind],
        matchingAny kinds: Set<PythonBlockKind>,
        fallback: PythonBlockKind
    ) {
        guard stack.contains(where: { kinds.contains($0) }) else {
            if stack.last == fallback {
                _ = stack.popLast()
            }
            return
        }
        while let last = stack.last {
            stack.removeLast()
            if kinds.contains(last) { break }
        }
    }

    private static func continuationDepthForIndent(line: String, stack: [Character]) -> Int {
        var depth = stack.count
        for character in line {
            guard isClosingDelimiter(character) else { break }
            depth = max(0, depth - 1)
        }
        return depth
    }

    private static func startsWithClosingDelimiter(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return isClosingDelimiter(first)
    }

    private static func updateContinuationClosers(_ stack: inout [Character], with line: String) {
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character == "#" {
                break
            }
            if let closer = closerForOpeningDelimiter(character) {
                stack.append(closer)
            } else if isClosingDelimiter(character) {
                if stack.last == character {
                    _ = stack.popLast()
                } else if !stack.isEmpty {
                    _ = stack.popLast()
                }
            }
        }
    }

    private static func closerForOpeningDelimiter(_ character: Character) -> Character? {
        switch character {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        default: return nil
        }
    }

    private static func isClosingDelimiter(_ character: Character) -> Bool {
        character == ")" || character == "]" || character == "}"
    }

    private static func opensPythonBlock(_ line: String) -> Bool {
        line.hasSuffix(":") && !line.hasPrefix("#")
    }

    private static func blockKind(for line: String) -> PythonBlockKind {
        if line.hasPrefix("class ") { return .class }
        if line.hasPrefix("def ") || line.hasPrefix("async def ") { return .function }
        if line.hasPrefix("if ") || line.hasPrefix("elif ") { return .if }
        if line.hasPrefix("try:") { return .try }
        if line.hasPrefix("except") || line.hasPrefix("finally:") { return .except }
        if line.hasPrefix("else:") { return .else }
        if line.hasPrefix("for ") || line.hasPrefix("while ") { return .loop }
        if line.hasPrefix("with ") || line.hasPrefix("async with ") { return .with }
        return .other
    }

    private static func isTerminalStatement(_ line: String) -> Bool {
        let head = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return ["return", "raise", "break", "continue", "pass"].contains(head)
    }

    private static func repairCommonUTF8Mojibake(in content: String) -> (content: String, notes: [String]) {
        guard looksLikeUTF8Mojibake(content),
              let latin1Data = content.data(using: .isoLatin1),
              let repaired = String(data: latin1Data, encoding: .utf8),
              repaired != content,
              repaired.unicodeScalars.contains(where: { $0.value > 0x7F }) else {
            return (content, [])
        }

        return (repaired, ["已自动修复疑似 UTF-8 被按 Latin-1 解码造成的中文乱码。"])
    }

    private static func looksLikeUTF8Mojibake(_ content: String) -> Bool {
        let suspiciousMarkers = ["Ã", "Â", "â", "ä", "å", "æ", "ç", "è", "é", "ï"]
        let markerCount = suspiciousMarkers.reduce(0) { count, marker in
            count + content.components(separatedBy: marker).count - 1
        }
        guard markerCount >= 3 else { return false }

        let commonUTF8LeadPattern = #"(?s).*[ÃÂâäåæçèéï][\u0080-\u00BF].*"#
        return content.range(of: commonUTF8LeadPattern, options: .regularExpression) != nil
            || content.contains("å­")
            || content.contains("ç¬")
            || content.contains("é¡")
            || content.contains("æ")
    }

    private static func ensureTrailingNewline(_ content: String) -> String {
        content.hasSuffix("\n") ? content : content + "\n"
    }

    private static func normalizeNewlines(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

enum LocalCodeWriteGuard {
    struct Result: Sendable {
        let content: String
        let notes: [String]
    }

    static func language(forPath path: String) -> String {
        switch fileExtension(forPath: path) {
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "jsx": return "jsx"
        case "swift": return "swift"
        case "json", "jsonc": return "json"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "md", "markdown": return "markdown"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash", "zsh": return "bash"
        case "xml": return "xml"
        case "sql": return "sql"
        case "rb": return "ruby"
        case "php": return "php"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "go": return "go"
        case "rs": return "rust"
        case "c": return "c"
        case "cc", "cpp", "cxx", "hpp", "h": return "cpp"
        case "cs": return "csharp"
        case "lua": return "lua"
        default: return "text"
        }
    }

    static func normalizeGeneratedCode(_ content: String, path: String) -> Result {
        let ext = fileExtension(forPath: path)
        var working = normalizeNewlines(content)
        var notes: [String] = []

        if working.hasPrefix("\u{FEFF}") {
            working.removeFirst()
            notes.append("已移除 UTF-8 BOM。")
        }

        if shouldStripOuterCodeFence(forExtension: ext),
           let extracted = extractSingleFencedCodeBlock(from: working) {
            working = extracted
            notes.append("已从 markdown 代码块提取可写入源码。")
        }

        guard isCodeLikeExtension(ext) else {
            return Result(content: working, notes: deduplicated(notes))
        }

        let tabRepair = normalizeLeadingTabs(
            in: working,
            spacesPerTab: indentationWidth(forExtension: ext)
        )
        working = tabRepair.content
        notes.append(contentsOf: tabRepair.notes)

        if let braceRepair = repairCollapsedBraceIndentationIfNeeded(working, fileExtension: ext) {
            working = braceRepair.content
            notes.append(contentsOf: braceRepair.notes)
        }

        if ext == "json",
           let prettyJSON = prettyPrintedJSON(from: working),
           prettyJSON != working {
            working = prettyJSON
            notes.append("JSON 文件已按内置格式化器重排。")
        }

        if !working.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            working = ensureTrailingNewline(working.trimmingCharacters(in: .newlines))
        }

        return Result(content: working, notes: deduplicated(notes))
    }

    private static func fileExtension(forPath path: String) -> String {
        ((path as NSString).pathExtension).lowercased()
    }

    private static func shouldStripOuterCodeFence(forExtension ext: String) -> Bool {
        isCodeLikeExtension(ext) && !["md", "markdown", "txt"].contains(ext)
    }

    private static func isCodeLikeExtension(_ ext: String) -> Bool {
        [
            "py", "js", "ts", "tsx", "jsx", "swift", "json", "jsonc",
            "html", "htm", "css", "scss", "less",
            "yml", "yaml", "toml",
            "sh", "bash", "zsh",
            "xml", "sql", "rb", "php", "java", "kt", "kts",
            "go", "rs", "c", "cc", "cpp", "cxx", "hpp", "h", "cs",
            "lua"
        ].contains(ext)
    }

    private static func indentationWidth(forExtension ext: String) -> Int {
        switch ext {
        case "json", "jsonc", "yml", "yaml", "html", "htm", "xml", "css", "scss", "less":
            return 2
        default:
            return 4
        }
    }

    private static func extractSingleFencedCodeBlock(from content: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)^\s*```[^\n`]*\n([\s\S]*?)\n?```\s*$"#
        ) else {
            return nil
        }
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        guard let match = regex.firstMatch(in: content, range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return nsContent.substring(with: match.range(at: 1))
    }

    private static func normalizeLeadingTabs(
        in content: String,
        spacesPerTab: Int
    ) -> (content: String, notes: [String]) {
        let lines = content.components(separatedBy: .newlines)
        var changedLines: [Int] = []

        let normalized = lines.enumerated().map { offset, rawLine in
            var prefix = ""
            var index = rawLine.startIndex
            var changed = false

            while index < rawLine.endIndex {
                let character = rawLine[index]
                if character == "\t" {
                    prefix += String(repeating: " ", count: spacesPerTab)
                    changed = true
                } else if character == " " {
                    prefix.append(character)
                } else {
                    break
                }
                index = rawLine.index(after: index)
            }

            guard changed else { return rawLine }
            changedLines.append(offset + 1)
            return prefix + String(rawLine[index...])
        }

        guard !changedLines.isEmpty else { return (content, []) }
        let listedLines = changedLines.prefix(12).map(String.init).joined(separator: ", ")
        let note = "已将行首 Tab 转为 \(spacesPerTab) 个空格：第 \(listedLines) 行"
        return (normalized.joined(separator: "\n"), [note])
    }

    private static func repairCollapsedBraceIndentationIfNeeded(
        _ content: String,
        fileExtension ext: String
    ) -> (content: String, notes: [String])? {
        guard supportsBraceIndentRepair(ext) else { return nil }

        let meaningfulLines = content
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard meaningfulLines.count >= 4 else { return nil }

        let leadingWidths = meaningfulLines.map { line in
            line.prefix { $0 == " " || $0 == "\t" }.count
        }
        guard let maxLeading = leadingWidths.max(), maxLeading <= 1 else { return nil }
        guard meaningfulLines.contains(where: {
            $0.contains("{") || $0.contains("}") || $0.contains("[") || $0.contains("]")
        }) else {
            return nil
        }

        let rebuilt = rebuildBraceIndentation(from: content)
        guard rebuilt != content else { return nil }
        return (
            content: ensureTrailingNewline(rebuilt.trimmingCharacters(in: .newlines)),
            notes: ["检测到括号风格代码缩进几乎全部丢失，客户端已按内置缩进规则重排。"]
        )
    }

    private static func supportsBraceIndentRepair(_ ext: String) -> Bool {
        [
            "js", "ts", "tsx", "jsx", "swift", "json", "jsonc",
            "css", "scss", "less", "java", "kt", "kts",
            "go", "rs", "c", "cc", "cpp", "cxx", "hpp", "h", "cs", "php"
        ].contains(ext)
    }

    private static func rebuildBraceIndentation(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var indent = 0
        var rebuilt: [String] = []

        for rawLine in lines {
            let stripped = rawLine.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else {
                rebuilt.append("")
                continue
            }

            let leadingClosers = leadingBraceCloserCount(in: stripped)
            let lineIndent = max(0, indent - leadingClosers)
            rebuilt.append(String(repeating: " ", count: lineIndent * 4) + stripped)

            let counts = braceCounts(in: stripped)
            indent = max(0, indent + counts.opens - counts.closes)
        }

        return rebuilt.joined(separator: "\n")
    }

    private static func leadingBraceCloserCount(in line: String) -> Int {
        var count = 0
        for character in line {
            if character == "}" || character == "]" {
                count += 1
            } else if character == " " || character == "\t" {
                continue
            } else {
                break
            }
        }
        return count
    }

    private static func braceCounts(in line: String) -> (opens: Int, closes: Int) {
        var opens = 0
        var closes = 0
        var insideSingleQuote = false
        var insideDoubleQuote = false
        var escaped = false
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if escaped {
                escaped = false
                index += 1
                continue
            }

            if character == "\\" {
                escaped = true
                index += 1
                continue
            }

            if insideSingleQuote {
                if character == "'" { insideSingleQuote = false }
                index += 1
                continue
            }

            if insideDoubleQuote {
                if character == "\"" { insideDoubleQuote = false }
                index += 1
                continue
            }

            if character == "'" {
                insideSingleQuote = true
                index += 1
                continue
            }

            if character == "\"" {
                insideDoubleQuote = true
                index += 1
                continue
            }

            if character == "#" {
                break
            }

            if character == "/",
               index + 1 < characters.count,
               characters[index + 1] == "/" {
                break
            }

            switch character {
            case "{", "[":
                opens += 1
            case "}", "]":
                closes += 1
            default:
                break
            }

            index += 1
        }

        return (opens, closes)
    }

    private static func prettyPrintedJSON(from content: String) -> String? {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted]
              ),
              var pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }

        if !pretty.hasSuffix("\n") {
            pretty += "\n"
        }
        return pretty
    }

    private static func normalizeNewlines(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func ensureTrailingNewline(_ content: String) -> String {
        content.hasSuffix("\n") ? content : content + "\n"
    }

    private static func deduplicated(_ notes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for note in notes where seen.insert(note).inserted {
            result.append(note)
        }
        return result
    }
}
