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
                content: normalizeNewlines(content),
                notes: ["结构化 Python 源码已按完整文件写入，并交给内置 Python 格式化器做安全归一化。"]
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
            extracted = ExtractedCode(content: normalizeNewlines(content), notes: [])
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

        return (ensureTrailingNewline(prepared), notes)
    }

    static func repairCollapsedIndentationIfNeeded(_ content: String) -> (content: String, notes: [String])? {
        let normalized = normalizeNewlines(content).trimmingCharacters(in: .newlines)
        guard looksCollapsedIndentation(normalized) else { return nil }

        let repaired = rebuildIndentation(from: normalized)
        guard repaired != normalized else { return nil }
        return (
            ensureTrailingNewline(repaired),
            ["检测到 Python 块缩进被压扁，客户端已按冒号块/def/class/else 结构自动恢复 4 空格缩进。"]
        )
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

    private enum PythonBlockKind: Equatable {
        case `class`
        case function
        case `if`
        case `try`
        case other
    }

    private static func rebuildIndentation(from content: String) -> String {
        let rawLines = content.components(separatedBy: "\n")
        var rebuilt: [String] = []
        var stack: [PythonBlockKind] = []
        var continuationClosers: [Character] = []
        var blankRun = 0
        var previousOpenedBlock = false

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
                    collapseToDefinitionParent(&stack)
                } else if stripped.hasPrefix("elif ") {
                    popUntilContinuationParent(&stack, matching: .if, fallback: .other)
                } else if stripped.hasPrefix("except") || stripped.hasPrefix("finally:") {
                    popUntilContinuationParent(&stack, matching: .try, fallback: .other)
                } else if stripped.hasPrefix("else:") {
                    popUntilContinuationParent(&stack, matching: nearestElseParent(in: stack), fallback: .other)
                } else if startsNewIfSibling(stripped, previousOpenedBlock: previousOpenedBlock, stack: stack) {
                    _ = stack.popLast()
                }
            }

            rebuilt.append(String(repeating: " ", count: (stack.count + continuationDepth) * 4) + stripped)

            if !isContinuationLine && opensPythonBlock(stripped) {
                stack.append(blockKind(for: stripped))
            }
            updateContinuationClosers(&continuationClosers, with: stripped)
            previousOpenedBlock = opensPythonBlock(stripped)
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

    private static func collapseToDefinitionParent(_ stack: inout [PythonBlockKind]) {
        let keepClass = stack.lastIndex(of: .class)
        if let keepClass, keepClass == 0 {
            stack = [.class]
        } else {
            stack.removeAll()
        }
    }

    private static func popUntilContinuationParent(
        _ stack: inout [PythonBlockKind],
        matching kind: PythonBlockKind,
        fallback: PythonBlockKind
    ) {
        guard stack.contains(kind) else {
            if stack.last == fallback {
                _ = stack.popLast()
            }
            return
        }
        while let last = stack.last {
            stack.removeLast()
            if last == kind { break }
        }
    }

    private static func nearestElseParent(in stack: [PythonBlockKind]) -> PythonBlockKind {
        for kind in stack.reversed() where kind == .if || kind == .try {
            return kind
        }
        return .other
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
        return .other
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
