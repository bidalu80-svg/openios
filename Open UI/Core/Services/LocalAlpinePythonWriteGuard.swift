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

    static func prepare(_ content: String, source: Source) -> Preparation {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Python 文件内容为空")
        }

        let normalizedTabs = content.replacingOccurrences(of: "\t", with: "    ")
        if let structureWarning = structuralWarning(for: normalizedTabs) {
            if let rebuilt = rebuildIndentation(normalizedTabs),
               Self.structuralWarning(for: rebuilt) == nil,
               indentationPreflightWarning(for: rebuilt) == nil {
                return .success(
                    content: ensureTrailingNewline(rebuilt),
                    notes: ["已由写入模块重建 Python 缩进结构：\(structureWarning)"]
                )
            }
            return .failure("Python 结构预检失败：\(structureWarning)")
        }

        if let warning = indentationPreflightWarning(for: normalizedTabs) {
            if let rebuilt = rebuildIndentation(normalizedTabs),
               structuralWarning(for: rebuilt) == nil,
               indentationPreflightWarning(for: rebuilt) == nil {
                return .success(
                    content: ensureTrailingNewline(rebuilt),
                    notes: ["已由写入模块重建 Python 缩进结构：\(warning)"]
                )
            }
            return .failure("Python 缩进预检失败：\(warning)")
        }

        if source == .content || source == .codeBlock,
           normalizedTabs.components(separatedBy: .newlines).contains(where: { line in
               let trimmed = line.trimmingCharacters(in: .whitespaces)
               return lineOpensBlock(trimmed) && line.prefix { $0 == " " }.count == 0
           }),
           let rebuilt = rebuildIndentation(normalizedTabs),
           rebuilt != normalizedTabs,
           structuralWarning(for: rebuilt) == nil,
           indentationPreflightWarning(for: rebuilt) == nil {
            return .success(
                content: ensureTrailingNewline(rebuilt),
                notes: ["普通文本已标准化为 4 空格 Python 缩进"]
            )
        }

        return .success(content: ensureTrailingNewline(normalizedTabs), notes: [])
    }

    static func indentationPreflightWarning(for content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        let significant = lines.enumerated().compactMap { index, rawLine -> (number: Int, indent: Int, text: String)? in
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
            return (index + 1, indent, text)
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

    static func repairFlattenedIndentation(_ content: String, force: Bool = false) -> String? {
        guard force || indentationPreflightWarning(for: content) != nil else { return nil }
        return rebuildIndentation(content)
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
        var stack: [(keyword: String, indent: Int, line: Int)] = []

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count

            while let last = stack.last, indent < last.indent {
                stack.removeLast()
            }

            let keyword = blockKeyword(text)
            if keyword == "except" || keyword == "finally" {
                while let last = stack.last, indent <= last.indent, last.keyword != "try" {
                    stack.removeLast()
                }
                guard stack.last?.keyword == "try", stack.last?.indent == indent else {
                    return "第 \(lineNumber) 行 `\(firstToken(text))` 没有匹配到同级 try。"
                }
            } else if keyword == "elif" || keyword == "else" {
                while let last = stack.last,
                      indent <= last.indent,
                      !["if", "elif", "for", "while", "try", "except"].contains(last.keyword) {
                    stack.removeLast()
                }
                guard let last = stack.last,
                      last.indent == indent,
                      ["if", "elif", "for", "while", "try", "except"].contains(last.keyword) else {
                    return "第 \(lineNumber) 行 `\(firstToken(text))` 没有匹配到同级代码块。"
                }
            }

            if lineOpensBlock(text) {
                stack.append((keyword, indent, lineNumber))
            }
        }
        return nil
    }

    private static func rebuildIndentation(_ content: String) -> String? {
        let rawLines = content.components(separatedBy: .newlines)
        let meaningfulIndents = rawLines.compactMap { line -> Int? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return line.prefix { $0 == " " || $0 == "\t" }.count
        }
        guard !meaningfulIndents.isEmpty,
              (meaningfulIndents.max() ?? 0) <= 12 else {
            return nil
        }

        var output: [String] = []
        var stack: [String] = []
        var previousOpenedBlock = false
        var pendingDecoratorIndent: Int?
        var blankBefore = false

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                output.append("")
                blankBefore = true
                continue
            }

            if trimmed.hasPrefix("#") {
                output.append(String(repeating: " ", count: stack.count * 4) + trimmed)
                blankBefore = false
                continue
            }

            if blankBefore, stack.count > 1, shouldDedentAfterBlankLine(trimmed) {
                stack.removeLast()
            }

            let rawIndent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
            let keyword = blockKeyword(trimmed)
            if isTopLevelLine(trimmed, rawIndent: rawIndent, previousOpenedBlock: previousOpenedBlock) {
                stack.removeAll()
            } else if isBlockContinuation(keyword) {
                alignContinuation(keyword, stack: &stack)
            }

            let indentLevel = pendingDecoratorIndent ?? stack.count
            output.append(String(repeating: " ", count: indentLevel * 4) + trimmed)
            pendingDecoratorIndent = nil

            if trimmed.hasPrefix("@") {
                pendingDecoratorIndent = indentLevel
                previousOpenedBlock = false
                blankBefore = false
                continue
            }

            if lineOpensBlock(trimmed) {
                stack.append(keyword)
                previousOpenedBlock = true
            } else {
                previousOpenedBlock = false
                if lineTerminatesCurrentBlock(trimmed), !stack.isEmpty {
                    stack.removeLast()
                }
            }
            blankBefore = false
        }

        let rebuilt = output.joined(separator: "\n")
        guard rebuilt != content else { return nil }
        return rebuilt
    }

    private static func alignContinuation(_ keyword: String, stack: inout [String]) {
        switch keyword {
        case "except", "finally":
            while let last = stack.last, last != "try" {
                stack.removeLast()
            }
            if stack.last == "try" {
                stack.removeLast()
            }
        case "elif":
            while let last = stack.last, last != "if" && last != "elif" {
                stack.removeLast()
            }
            if stack.last == "if" || stack.last == "elif" {
                stack.removeLast()
            }
        case "else":
            while let last = stack.last,
                  !["if", "elif", "for", "while", "try", "except"].contains(last) {
                stack.removeLast()
            }
            if let last = stack.last,
               ["if", "elif", "for", "while", "try", "except"].contains(last) {
                stack.removeLast()
            }
        default:
            break
        }
    }

    private static func isTopLevelLine(_ text: String, rawIndent: Int, previousOpenedBlock: Bool) -> Bool {
        guard rawIndent == 0, !previousOpenedBlock else { return false }
        let lowered = text.lowercased()
        return lowered.hasPrefix("import ")
            || lowered.hasPrefix("from ")
            || lowered.hasPrefix("def ")
            || lowered.hasPrefix("async def ")
            || lowered.hasPrefix("class ")
            || lowered.hasPrefix("if __name__")
            || lowered.hasPrefix("@")
    }

    private static func isBlockContinuation(_ keyword: String) -> Bool {
        ["elif", "else", "except", "finally"].contains(keyword)
    }

    private static func shouldDedentAfterBlankLine(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("return")
            || lowered.hasPrefix("yield")
            || lowered.hasPrefix("raise ")
            || lowered.hasPrefix("print(")
            || lowered.contains(" = ")
            || lowered.hasPrefix("result =")
            || lowered.hasPrefix("elapsed =")
            || lowered.hasPrefix("total =")
            || lowered.hasPrefix("count =")
    }

    private static func lineTerminatesCurrentBlock(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered == "pass"
            || lowered == "break"
            || lowered == "continue"
            || lowered.hasPrefix("return")
            || lowered.hasPrefix("yield")
            || lowered.hasPrefix("raise ")
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

    private static func ensureTrailingNewline(_ content: String) -> String {
        content.hasSuffix("\n") ? content : content + "\n"
    }
}
