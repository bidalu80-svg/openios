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
        switch extractPythonCode(from: content, source: source) {
        case .success(let value):
            extracted = value
        case .failure(let message):
            return .failure(message)
        }

        if source == .content || source == .heredoc {
            return .failure("为保证 Python 缩进，`.py` 写入只接受 `code_lines` / `content_lines` / `content_base64`；已拒绝 `\(source.displayName)` 写入。")
        }

        guard !extracted.content.trimmingCharacters(in: .newlines).isEmpty else {
            return .failure("Python 文件内容为空")
        }

        let withoutOuterNewlines = extracted.content.trimmingCharacters(in: .newlines)
        let normalizedTabs = withoutOuterNewlines.replacingOccurrences(of: "\t", with: "    ")
        var notes = extracted.notes
        if withoutOuterNewlines.contains("\t") {
            notes.append("已将 Tab 统一替换为 4 个空格")
        }

        if let warning = indentationPreflightWarning(for: normalizedTabs) {
            return .failure("Python 缩进预检失败：\(warning)")
        }
        if let warning = structuralWarning(for: normalizedTabs) {
            return .failure("Python 结构预检失败：\(warning)")
        }

        return .success(content: ensureTrailingNewline(normalizedTabs), notes: notes)
    }

    private static func extractPythonCode(from content: String, source: Source) -> Extraction {
        guard content.range(of: #"(?m)^\s*```"#, options: .regularExpression) != nil else {
            return .success(ExtractedCode(content: content.trimmingCharacters(in: .newlines), notes: []))
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
}
