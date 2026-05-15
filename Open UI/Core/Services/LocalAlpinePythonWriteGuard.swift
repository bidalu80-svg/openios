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
                notes: ["结构化 Python 源码已走原样写入通道，未执行 Markdown 提取、缩进修复或格式化。"]
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

        let tinyIndentRepair = normalizeTinyPythonIndents(in: prepared)
        prepared = tinyIndentRepair.content
        notes.append(contentsOf: tinyIndentRepair.notes)

        let indentWidthRepair = normalizeIndentWidthToFourSpaces(in: prepared)
        prepared = indentWidthRepair.content
        notes.append(contentsOf: indentWidthRepair.notes)

        let blockBodyRepair = repairFlatPythonBlocks(in: prepared)
        prepared = blockBodyRepair.content
        notes.append(contentsOf: blockBodyRepair.notes)

        return (ensureTrailingNewline(prepared), notes)
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

    static func indentationPreflightWarning(for content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        let significant = lines.enumerated().compactMap { index, rawLine -> (number: Int, indent: Int, text: String)? in
            let text = stripHorizontalWhitespace(rawLine)
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            return (index + 1, leadingIndentCount(rawLine), text)
        }

        guard significant.count >= 2 else { return nil }

        for index in significant.indices.dropLast() {
            let current = significant[index]
            guard lineOpensBlock(current.text) else { continue }
            guard let next = significant[(index + 1)..<significant.endIndex].first else { continue }
            if next.indent <= current.indent {
                return "第 \(current.number) 行以 `:` 开启代码块，但第 \(next.number) 行没有增加缩进。"
            }
        }

        let hasPythonBlocks = significant.contains { lineOpensBlock($0.text) }
        let maxIndent = significant.map { $0.indent }.max() ?? 0
        if hasPythonBlocks, maxIndent == 1 {
            return "检测到 Python 代码块但最大缩进只有 1 个空格，这通常是模型输出缩进被压平。"
        }

        return nil
    }

    static func lineOpensBlock(_ text: String) -> Bool {
        guard text.hasSuffix(":") else { return false }
        let lowered = text.lowercased()
        let starters = [
            "def ", "class ", "if ", "elif ", "else:", "for ", "while ",
            "try:", "except", "finally:", "with ", "async def ", "async with ",
            "match ", "case "
        ]
        return starters.contains { lowered.hasPrefix($0) }
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

    private static func normalizeTinyPythonIndents(in content: String) -> (content: String, notes: [String]) {
        let lines = content.components(separatedBy: .newlines)
        let significant = lines.compactMap { rawLine -> (indent: Int, text: String)? in
            let text = stripHorizontalWhitespace(rawLine)
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            return (leadingIndentCount(rawLine), text)
        }
        guard significant.contains(where: { lineOpensBlock($0.text) }) else {
            return (content, [])
        }

        let positiveIndents = Set(significant.map(\.indent).filter { $0 > 0 })
        guard !positiveIndents.isEmpty,
              positiveIndents.allSatisfy({ $0 <= 3 }) else {
            return (content, [])
        }

        let indentLevels = positiveIndents.sorted()
        var indentMap: [Int: Int] = [:]
        for (offset, indent) in indentLevels.enumerated() {
            indentMap[indent] = (offset + 1) * 4
        }

        var changedLines: [Int] = []
        let normalized = lines.enumerated().map { offset, rawLine in
            let indent = leadingIndentCount(rawLine)
            guard let mappedIndent = indentMap[indent] else { return rawLine }
            changedLines.append(offset + 1)
            return String(repeating: " ", count: mappedIndent) + stripHorizontalWhitespace(rawLine)
        }

        guard !changedLines.isEmpty else { return (content, []) }
        let note = "已将疑似被压缩的 Python 缩进恢复为 4 空格层级：第 \(changedLines.prefix(12).map(String.init).joined(separator: ", ")) 行"
        return (normalized.joined(separator: "\n"), [note])
    }

    private static func normalizeIndentWidthToFourSpaces(in content: String) -> (content: String, notes: [String]) {
        let lines = content.components(separatedBy: .newlines)
        let significantIndents = lines.compactMap { rawLine -> Int? in
            let text = stripHorizontalWhitespace(rawLine)
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            let indent = leadingIndentCount(rawLine)
            return indent > 0 ? indent : nil
        }

        let positiveIndents = Array(Set(significantIndents)).sorted()
        guard let minIndent = positiveIndents.first,
              positiveIndents.contains(where: { $0 % 4 != 0 }) else {
            return (content, [])
        }

        let unit = positiveIndents.reduce(minIndent) { gcd($0, $1) }
        guard unit > 0,
              unit == minIndent,
              unit != 4,
              unit <= 3,
              positiveIndents.allSatisfy({ $0 % unit == 0 }) else {
            return (content, [])
        }

        var changedLines: [Int] = []
        let normalized = lines.enumerated().map { offset, rawLine in
            let indent = leadingIndentCount(rawLine)
            guard indent > 0, indent % unit == 0 else { return rawLine }
            let mappedIndent = (indent / unit) * 4
            guard mappedIndent != indent else { return rawLine }
            changedLines.append(offset + 1)
            return String(repeating: " ", count: mappedIndent) + stripHorizontalWhitespace(rawLine)
        }

        guard !changedLines.isEmpty else { return (content, []) }
        let note = "已按 VS Code/Python 默认设置将 \(unit) 空格缩进转换为 4 空格层级：第 \(changedLines.prefix(12).map(String.init).joined(separator: ", ")) 行"
        return (normalized.joined(separator: "\n"), [note])
    }

    private static func gcd(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }

    private static func repairFlatPythonBlocks(in content: String) -> (content: String, notes: [String]) {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return (content, []) }

        struct ActiveBlock {
            let rawIndent: Int
            let indent: Int
            let keyword: String
            let openedByFlatRepair: Bool
            var hasRepairedBody: Bool
            var hasNativeIndentedBody: Bool
        }

        struct SignificantLine {
            let rawIndent: Int
            let indent: Int
            let text: String
            let opensBlock: Bool
            let isTerminating: Bool
        }

        func matchingPeerBlock(for text: String, in stack: [ActiveBlock]) -> (index: Int, indent: Int, keepMatchedBlock: Bool)? {
            let keyword = blockKeyword(text)
            let allowed: [String]
            switch keyword {
            case "elif":
                allowed = ["if", "elif"]
            case "else":
                allowed = ["if", "elif", "for", "while", "try", "except"]
            case "except":
                allowed = ["try", "except"]
            case "finally":
                allowed = ["try", "except", "else"]
            case "case":
                allowed = ["case", "match"]
            default:
                return nil
            }

            for index in stack.indices.reversed() where allowed.contains(stack[index].keyword) {
                if keyword == "case", stack[index].keyword == "match" {
                    return (index, stack[index].indent + 4, true)
                }
                return (index, stack[index].indent, false)
            }
            return nil
        }

        func shouldCloseFlatBlock(
            _ active: ActiveBlock,
            before text: String,
            originalIndent: Int,
            previous: SignificantLine?
        ) -> Bool {
            guard originalIndent <= active.rawIndent else { return false }
            let lowered = text.lowercased()
            if lowered.hasPrefix("if __name__") || lowered.hasPrefix("class ") {
                return true
            }
            if lowered.hasPrefix("def ") || lowered.hasPrefix("async def ") {
                if active.keyword == "class" {
                    return active.hasNativeIndentedBody
                        || (active.hasRepairedBody && previous?.isTerminating == true)
                }
                return true
            }
            return false
        }

        func markNearestParentBody(for desiredIndent: Int, originalIndent: Int, in stack: inout [ActiveBlock]) {
            guard let index = stack.indices.reversed().first(where: { desiredIndent > stack[$0].indent }) else {
                return
            }
            stack[index].hasRepairedBody = true
            if originalIndent > stack[index].rawIndent {
                stack[index].hasNativeIndentedBody = true
            }
        }

        var repaired: [String] = []
        var stack: [ActiveBlock] = []
        var changedLines: [Int] = []
        var previousSignificant: SignificantLine?

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let text = stripHorizontalWhitespace(rawLine)
            guard !text.isEmpty, !text.hasPrefix("#") else {
                repaired.append(rawLine)
                continue
            }

            let originalIndent = leadingIndentCount(rawLine)
            while let last = stack.last, originalIndent < last.rawIndent {
                stack.removeLast()
            }

            var desiredIndent = originalIndent
            var openedByFlatRepair = false

            if startsPeerOrDedentKeyword(text) {
                if let peer = matchingPeerBlock(for: text, in: stack) {
                    desiredIndent = peer.indent
                    let removalStart = peer.keepMatchedBlock ? peer.index + 1 : peer.index
                    if removalStart < stack.endIndex {
                        stack.removeSubrange(removalStart..<stack.endIndex)
                    }
                    openedByFlatRepair = desiredIndent != originalIndent
                }
            }

            if !startsPeerOrDedentKeyword(text) || desiredIndent == originalIndent {
                if let previousSignificant,
                   previousSignificant.opensBlock,
                   originalIndent <= previousSignificant.rawIndent {
                    desiredIndent = previousSignificant.indent + 4
                    openedByFlatRepair = true
                } else {
                    while let active = stack.last,
                          shouldCloseFlatBlock(active, before: text, originalIndent: originalIndent, previous: previousSignificant) {
                        stack.removeLast()
                    }

                    while let active = stack.last,
                          active.openedByFlatRepair,
                          active.hasRepairedBody,
                          previousSignificant?.isTerminating == true,
                          originalIndent <= active.rawIndent,
                          !startsPeerOrDedentKeyword(text),
                          !shouldCloseFlatBlock(active, before: text, originalIndent: originalIndent, previous: previousSignificant) {
                        stack.removeLast()
                    }

                    if let active = stack.last,
                       originalIndent <= active.rawIndent,
                       active.hasRepairedBody,
                       isProbablyBlockBodyLine(text) {
                        desiredIndent = active.indent + 4
                        openedByFlatRepair = true
                    }
                }
            }

            if desiredIndent != originalIndent {
                repaired.append(String(repeating: " ", count: desiredIndent) + text)
                changedLines.append(lineNumber)
            } else {
                repaired.append(rawLine)
            }

            markNearestParentBody(for: desiredIndent, originalIndent: originalIndent, in: &stack)

            if lineOpensBlock(text) {
                stack.append(ActiveBlock(
                    rawIndent: originalIndent,
                    indent: desiredIndent,
                    keyword: blockKeyword(text),
                    openedByFlatRepair: openedByFlatRepair,
                    hasRepairedBody: false,
                    hasNativeIndentedBody: false
                ))
            }

            previousSignificant = SignificantLine(
                rawIndent: originalIndent,
                indent: desiredIndent,
                text: text,
                opensBlock: lineOpensBlock(text),
                isTerminating: isTerminatingStatement(text)
            )
        }

        guard !changedLines.isEmpty else { return (content, []) }
        let note = "已在写入前自动修复明显缺失的 Python 块缩进：第 \(changedLines.prefix(12).map(String.init).joined(separator: ", ")) 行"
        return (repaired.joined(separator: "\n"), [note])
    }

    private static func isLikelyFlatRepairBoundary(_ text: String, originalIndent: Int, blockIndent: Int) -> Bool {
        guard originalIndent <= blockIndent else { return false }
        let lowered = text.lowercased()
        return lowered.hasPrefix("def ")
            || lowered.hasPrefix("class ")
            || lowered.hasPrefix("async def ")
            || lowered.hasPrefix("if __name__")
    }

    private static func isTerminatingStatement(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered == "pass"
            || lowered.hasPrefix("return")
            || lowered.hasPrefix("raise")
            || lowered.hasPrefix("break")
            || lowered.hasPrefix("continue")
    }

    private static func fillMissingPythonBlockBodies(in content: String) -> (content: String, notes: [String]) {
        var lines = content.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return (content, []) }

        struct BlockState {
            let indent: Int
            var hasBody: Bool
        }

        var stack: [BlockState] = []
        var insertedLineNumbers: [Int] = []
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let text = stripHorizontalWhitespace(rawLine)
            if text.isEmpty || text.hasPrefix("#") {
                index += 1
                continue
            }

            let indent = leadingIndentCount(rawLine)

            while let last = stack.last, indent <= last.indent {
                if !last.hasBody {
                    let passLine = String(repeating: " ", count: last.indent + 4) + "pass"
                    lines.insert(passLine, at: index)
                    insertedLineNumbers.append(index + 1)
                    index += 1
                }
                _ = stack.popLast()
            }

            if !stack.isEmpty, indent > stack[stack.count - 1].indent {
                var parent = stack.removeLast()
                parent.hasBody = true
                stack.append(parent)
            }

            if lineOpensBlock(text) {
                stack.append(BlockState(indent: indent, hasBody: false))
            }

            index += 1
        }

        while let last = stack.popLast() {
            guard !last.hasBody else { continue }
            lines.append(String(repeating: " ", count: last.indent + 4) + "pass")
            insertedLineNumbers.append(lines.count)
        }

        guard !insertedLineNumbers.isEmpty else { return (content, []) }
        let note = "已为缺失代码体的 Python 块自动补全 `pass`：第 \(insertedLineNumbers.prefix(12).map(String.init).joined(separator: ", ")) 行"
        return (lines.joined(separator: "\n"), [note])
    }

    private static func completeDanglingTryBlocks(in content: String) -> (content: String, notes: [String]) {
        var lines = content.components(separatedBy: .newlines)
        guard lines.contains(where: { blockKeyword(stripHorizontalWhitespace($0)) == "try" }) else {
            return (content, [])
        }

        struct TryState {
            let indent: Int
            let line: Int
            var hasHandler: Bool
        }

        var stack: [TryState] = []
        var fixedTryLines: [Int] = []
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let text = stripHorizontalWhitespace(rawLine)
            if text.isEmpty || text.hasPrefix("#") {
                index += 1
                continue
            }

            let indent = leadingIndentCount(rawLine)
            if let last = stack.last,
               indent == last.indent,
               isTryHandlerKeyword(text) {
                stack[stack.count - 1].hasHandler = true
                index += 1
                continue
            }

            while let last = stack.last, indent <= last.indent {
                if !last.hasHandler {
                    insertGenericTryHandler(into: &lines, at: index, indent: last.indent)
                    fixedTryLines.append(last.line)
                    index += 2
                }
                _ = stack.popLast()
            }

            if blockKeyword(text) == "try" {
                stack.append(TryState(indent: indent, line: index + 1, hasHandler: false))
            }

            index += 1
        }

        while let last = stack.popLast() {
            guard !last.hasHandler else { continue }
            insertGenericTryHandler(into: &lines, at: lines.count, indent: last.indent)
            fixedTryLines.append(last.line)
        }

        guard !fixedTryLines.isEmpty else { return (content, []) }
        let note = "已为缺少 except/finally 的 Python try 块补全异常处理：第 \(fixedTryLines.prefix(12).map(String.init).joined(separator: ", ")) 行"
        return (lines.joined(separator: "\n"), [note])
    }

    private static func insertGenericTryHandler(into lines: inout [String], at index: Int, indent: Int) {
        let prefix = String(repeating: " ", count: indent)
        let bodyPrefix = String(repeating: " ", count: indent + 4)
        lines.insert(prefix + "except Exception as exc:", at: index)
        lines.insert(bodyPrefix + "print(f\"Unhandled error: {exc}\")", at: index + 1)
    }

    private static func isTryHandlerKeyword(_ text: String) -> Bool {
        let keyword = blockKeyword(text)
        return keyword == "except" || keyword == "finally"
    }

    private static func startsPeerOrDedentKeyword(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("elif ")
            || lowered.hasPrefix("else:")
            || lowered.hasPrefix("except")
            || lowered.hasPrefix("finally:")
            || lowered.hasPrefix("case ")
    }

    private static func isProbablyBlockBodyLine(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if startsPeerOrDedentKeyword(text) { return false }
        if lowered.hasPrefix("def ") || lowered.hasPrefix("class ") || lowered.hasPrefix("async def ") {
            return true
        }
        let bodyPrefixes = [
            "return", "raise", "yield", "await ", "print", "import ", "from ",
            "if ", "for ", "while ", "with ", "async with ", "try:", "pass",
            "break", "continue", "assert ", "del ", "global ", "nonlocal "
        ]
        if bodyPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }
        let assignableOrCallable = #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\])*(\s*[:+\-*/%]?=|\s*\()"#
        if text.range(of: assignableOrCallable, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func structuralWarning(for content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        var activeBlocks: [(keyword: String, indent: Int, line: Int)] = []

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let text = stripHorizontalWhitespace(rawLine)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            let indent = leadingIndentCount(rawLine)

            let keyword = blockKeyword(text)
            if keyword == "elif" || keyword == "else" || keyword == "except" || keyword == "finally" {
                let allowed: [String]
                switch keyword {
                case "elif":
                    allowed = ["if", "elif"]
                case "else":
                    allowed = ["if", "elif", "for", "while", "try", "except"]
                case "except":
                    allowed = ["try", "except"]
                case "finally":
                    allowed = ["try", "except", "else"]
                default:
                    allowed = []
                }
                let sameIndentHasPeer = activeBlocks.contains {
                    $0.indent == indent && allowed.contains($0.keyword)
                }
                guard sameIndentHasPeer else {
                    return "第 \(lineNumber) 行 `\(firstToken(text))` 没有匹配到同级代码块。"
                }
                while let last = activeBlocks.last, indent < last.indent {
                    activeBlocks.removeLast()
                }
            } else {
                while let last = activeBlocks.last, indent <= last.indent {
                    activeBlocks.removeLast()
                }
            }

            if lineOpensBlock(text) {
                activeBlocks.append((keyword, indent, lineNumber))
            }
        }

        return nil
    }

    private static func blockKeyword(_ text: String) -> String {
        let lowered = text.lowercased()
        if lowered.hasPrefix("async def ") { return "def" }
        if lowered.hasPrefix("def ") { return "def" }
        if lowered.hasPrefix("class ") { return "class" }
        if lowered.hasPrefix("if ") { return "if" }
        if lowered.hasPrefix("elif ") { return "elif" }
        if lowered.hasPrefix("else:") { return "else" }
        if lowered.hasPrefix("for ") { return "for" }
        if lowered.hasPrefix("while ") { return "while" }
        if lowered.hasPrefix("try:") { return "try" }
        if lowered.hasPrefix("except") { return "except" }
        if lowered.hasPrefix("finally:") { return "finally" }
        if lowered.hasPrefix("with ") || lowered.hasPrefix("async with ") { return "with" }
        if lowered.hasPrefix("match ") { return "match" }
        if lowered.hasPrefix("case ") { return "case" }
        return ""
    }

    private static func firstToken(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).first.map(String.init) ?? text
    }

    private static func stripHorizontalWhitespace(_ line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func leadingIndentCount(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
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
