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
                notes: ["结构化 Python 源码已按完整文件写入，随后会执行 black 整体格式化。"]
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
