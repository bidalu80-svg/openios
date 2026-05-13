import Foundation

struct LocalAlpineAgentResult: Sendable {
    let didExecute: Bool
    let summary: String
    let interactiveRequest: LocalAlpineInteractiveRequest?
    let commandResults: [LocalAlpineAgentCommandResult]

    init(
        didExecute: Bool,
        summary: String,
        interactiveRequest: LocalAlpineInteractiveRequest?,
        commandResults: [LocalAlpineAgentCommandResult] = []
    ) {
        self.didExecute = didExecute
        self.summary = summary
        self.interactiveRequest = interactiveRequest
        self.commandResults = commandResults
    }
}

struct LocalAlpineAgentCommandResult: Sendable {
    let command: String
    let cwd: String
    let exitCode: Int?
    let outputPreview: String

    var failed: Bool {
        guard let exitCode else { return true }
        return exitCode != 0
    }
}

actor LocalAlpineAgentService {
    static let shared = LocalAlpineAgentService()

    private let maxCommandsPerResponse = 12
    private let maxOutputCharactersPerCommand = 20_000
    private let defaultCWD = "/mnt/iexa"

    private init() {}

    func hasExecutableBlocks(in content: String) -> Bool {
        let blocks = extractInstructionBlocks(from: content)
        guard !blocks.isEmpty else { return false }
        for block in blocks {
            if let commands = try? parseCommands(from: block), !commands.isEmpty {
                return true
            }
        }
        return false
    }

    func executeBlocks(
        in content: String,
        inputProvider: (@MainActor (LocalAlpineInteractiveRequest) async -> String?)? = nil
    ) async -> LocalAlpineAgentResult {
        let blocks = extractInstructionBlocks(from: content)
        guard !blocks.isEmpty else {
            return LocalAlpineAgentResult(didExecute: false, summary: "", interactiveRequest: nil)
        }

        var commands: [LocalAlpineAgentCommand] = []
        var lines: [String] = []

        for block in blocks {
            do {
                let blockCommands = try parseCommands(from: block)
                commands.append(contentsOf: blockCommands)
            } catch {
                lines.append("- 指令解析失败：\(error.localizedDescription)")
            }
        }

        if commands.isEmpty {
            return LocalAlpineAgentResult(didExecute: false, summary: lines.joined(separator: "\n"), interactiveRequest: nil)
        }

        let trimmedCommands = Array(commands.prefix(maxCommandsPerResponse))
        let skippedCount = max(0, commands.count - trimmedCommands.count)
        var commandResults: [LocalAlpineAgentCommandResult] = []

        lines.insert("Local Alpine 执行结果", at: 0)
        lines.append("环境：内置 Alpine Linux，工作目录默认 `/mnt/iexa`")

        for command in trimmedCommands {
            let cwd = command.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveCWD = (cwd?.isEmpty == false) ? cwd! : defaultCWD
            var stepLines: [String] = []
            var shouldRunShellCommand = true
            if !command.writeFiles.isEmpty {
                let writeResult = await writeFiles(command.writeFiles, cwd: effectiveCWD)
                stepLines.append(writeResult.summary)
                if let syntaxCheck = await pythonSyntaxCheck(for: writeResult.writtenPaths, cwd: effectiveCWD) {
                    stepLines.append(format(command: syntaxCheck.command, cwd: effectiveCWD, result: syntaxCheck.result))
                    commandResults.append(Self.commandResult(
                        command: syntaxCheck.command,
                        cwd: effectiveCWD,
                        result: syntaxCheck.result
                    ))
                    if syntaxCheck.result.exitCode != 0 {
                        if let diagnostic = await pythonSyntaxDiagnostic(for: writeResult.writtenPaths, cwd: effectiveCWD) {
                            stepLines.append(format(command: diagnostic.command, cwd: effectiveCWD, result: diagnostic.result))
                            commandResults.append(Self.commandResult(
                                command: diagnostic.command,
                                cwd: effectiveCWD,
                                result: diagnostic.result
                            ))
                        }
                        shouldRunShellCommand = false
                    }
                }
            }

            if let shellCommand = command.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               !shellCommand.isEmpty,
               shouldRunShellCommand {
                var commandToExecute = shellCommand

                if let extractedWrite = await extractPythonHeredocWrites(from: shellCommand, cwd: effectiveCWD) {
                    var extractedFilesPassedSyntaxCheck = true
                    stepLines.append(extractedWrite.summary)
                    if let syntaxCheck = await pythonSyntaxCheck(for: extractedWrite.writtenPaths, cwd: effectiveCWD) {
                        stepLines.append(format(command: syntaxCheck.command, cwd: effectiveCWD, result: syntaxCheck.result))
                        commandResults.append(Self.commandResult(
                            command: syntaxCheck.command,
                            cwd: effectiveCWD,
                            result: syntaxCheck.result
                        ))
                        if syntaxCheck.result.exitCode != 0 {
                            extractedFilesPassedSyntaxCheck = false
                            if let diagnostic = await pythonSyntaxDiagnostic(for: extractedWrite.writtenPaths, cwd: effectiveCWD) {
                                stepLines.append(format(command: diagnostic.command, cwd: effectiveCWD, result: diagnostic.result))
                                commandResults.append(Self.commandResult(
                                    command: diagnostic.command,
                                    cwd: effectiveCWD,
                                    result: diagnostic.result
                                ))
                            }
                            commandToExecute = ""
                        }
                    }
                    if extractedFilesPassedSyntaxCheck {
                        commandToExecute = extractedWrite.remainingCommand
                    }
                } else if let blockedOutput = unsafePythonFileWriteWarning(for: shellCommand) {
                    let result = LocalAlpineCommandResult(
                        command: shellCommand,
                        output: blockedOutput,
                        exitCode: 125,
                        interactiveRequest: nil
                    )
                    stepLines.append(format(command: shellCommand, cwd: effectiveCWD, result: result))
                    commandResults.append(Self.commandResult(
                        command: shellCommand,
                        cwd: effectiveCWD,
                        result: result
                    ))
                    if !stepLines.isEmpty {
                        lines.append(stepLines.joined(separator: "\n\n"))
                    }
                    continue
                }

                commandToExecute = commandToExecute.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !commandToExecute.isEmpty else {
                    if !stepLines.isEmpty {
                        lines.append(stepLines.joined(separator: "\n\n"))
                    }
                    continue
                }

                var result = await LocalAlpineTerminalService.shared.execute(
                    command: commandToExecute,
                    cwd: effectiveCWD
                )
                while let request = result.interactiveRequest {
                    if let inputProvider,
                       let stdinInput = await inputProvider(request) {
                        result = await LocalAlpineTerminalService.shared.execute(
                            command: request.command,
                            cwd: request.cwd,
                            stdinInput: stdinInput
                        )
                    } else {
                        stepLines.append(format(command: commandToExecute, cwd: effectiveCWD, result: result))
                        commandResults.append(Self.commandResult(
                            command: commandToExecute,
                            cwd: effectiveCWD,
                            result: result
                        ))
                        lines.append(stepLines.joined(separator: "\n\n"))
                        return LocalAlpineAgentResult(
                            didExecute: true,
                            summary: lines.joined(separator: "\n\n"),
                            interactiveRequest: request,
                            commandResults: commandResults
                        )
                    }
                }
                stepLines.append(format(command: commandToExecute, cwd: effectiveCWD, result: result))
                commandResults.append(Self.commandResult(
                    command: commandToExecute,
                    cwd: effectiveCWD,
                    result: result
                ))
                if let diagnostic = await pythonSyntaxDiagnostic(
                    command: commandToExecute,
                    output: result.output,
                    cwd: effectiveCWD
                ) {
                    stepLines.append(format(command: diagnostic.command, cwd: effectiveCWD, result: diagnostic.result))
                    commandResults.append(Self.commandResult(
                        command: diagnostic.command,
                        cwd: effectiveCWD,
                        result: diagnostic.result
                    ))
                }
            }

            if !stepLines.isEmpty {
                lines.append(stepLines.joined(separator: "\n\n"))
            }
        }

        if skippedCount > 0 {
            lines.append("- 已跳过 \(skippedCount) 条多余命令，避免一次执行过多。")
        }

        return LocalAlpineAgentResult(
            didExecute: true,
            summary: lines.joined(separator: "\n\n"),
            interactiveRequest: nil,
            commandResults: commandResults
        )
    }

    private nonisolated static func commandResult(
        command: String,
        cwd: String,
        result: LocalAlpineCommandResult
    ) -> LocalAlpineAgentCommandResult {
        LocalAlpineAgentCommandResult(
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: result.exitCode,
            outputPreview: String(result.output.prefix(2_000))
        )
    }

    private func extractInstructionBlocks(from content: String) -> [String] {
        var blocks: [String] = []
        let nsContent = content as NSString

        if let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#, options: [.caseInsensitive]) {
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for match in matches where match.numberOfRanges >= 3 {
                let info = nsContent.substring(with: match.range(at: 1)).lowercased()
                let body = nsContent.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if info.contains("iexa_alpine")
                    || (info.trimmingCharacters(in: .whitespacesAndNewlines) == "json" && body.contains("\"iexa_alpine\"")) {
                    blocks.append(body)
                }
            }
        }

        if let tagRegex = try? NSRegularExpression(pattern: #"<iexa_alpine>([\s\S]*?)</iexa_alpine>"#, options: [.caseInsensitive]) {
            let matches = tagRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for match in matches where match.numberOfRanges >= 2 {
                blocks.append(nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return blocks
    }

    private func parseCommands(from block: String) throws -> [LocalAlpineAgentCommand] {
        if let data = block.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []) {
            let commands = parseCommands(from: object)
            if !commands.isEmpty { return commands }
            throw LocalAlpineAgentError.noCommands
        }

        let shell = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shell.isEmpty else { throw LocalAlpineAgentError.noCommands }
        return [LocalAlpineAgentCommand(command: shell, cwd: nil, writeFiles: [])]
    }

    private func parseCommands(from object: Any) -> [LocalAlpineAgentCommand] {
        if let array = object as? [Any] {
            return array.flatMap { parseCommands(from: $0) }
        }

        guard let dict = object as? [String: Any] else {
            if let command = object as? String {
                return [LocalAlpineAgentCommand(command: command, cwd: nil, writeFiles: [])]
            }
            return []
        }

        if let nested = dict["iexa_alpine"] ?? dict["commands"] {
            return parseCommands(from: nested)
        }

        if let command = dict["command"] as? String {
            return [LocalAlpineAgentCommand(
                command: command,
                cwd: dict["cwd"] as? String,
                writeFiles: parseWriteFiles(from: dict["write_files"] ?? dict["files"])
            )]
        }

        if let command = dict["cmd"] as? String {
            return [LocalAlpineAgentCommand(
                command: command,
                cwd: dict["cwd"] as? String,
                writeFiles: parseWriteFiles(from: dict["write_files"] ?? dict["files"])
            )]
        }

        let files = parseWriteFiles(from: dict["write_files"] ?? dict["files"])
        if !files.isEmpty {
            return [LocalAlpineAgentCommand(command: nil, cwd: dict["cwd"] as? String, writeFiles: files)]
        }

        return []
    }

    private func parseWriteFiles(from object: Any?) -> [LocalAlpineAgentFile] {
        if let array = object as? [Any] {
            return array.compactMap(parseWriteFile(from:))
        }
        if let object {
            return parseWriteFile(from: object).map { [$0] } ?? []
        }
        return []
    }

    private func parseWriteFile(from object: Any) -> LocalAlpineAgentFile? {
        guard let dict = object as? [String: Any] else { return nil }
        guard let path = (dict["path"] as? String)
            ?? (dict["file"] as? String)
            ?? (dict["name"] as? String),
            let content = Self.writeFileContent(from: dict) else {
            return nil
        }
        return LocalAlpineAgentFile(path: path, content: content)
    }

    private nonisolated static func writeFileContent(from dict: [String: Any]) -> String? {
        if let content = (dict["content"] as? String)
            ?? (dict["text"] as? String)
            ?? (dict["body"] as? String) {
            return content
        }

        if let lines = (dict["content_lines"] as? [String])
            ?? (dict["lines"] as? [String]) {
            var content = lines.joined(separator: "\n")
            let shouldAppendNewline = (dict["append_newline"] as? Bool)
                ?? (dict["trailing_newline"] as? Bool)
                ?? true
            if shouldAppendNewline, !content.hasSuffix("\n") {
                content += "\n"
            }
            return content
        }

        if let base64 = (dict["content_base64"] as? String)
            ?? (dict["base64"] as? String),
           let data = Data(base64Encoded: base64),
           let content = String(data: data, encoding: .utf8) {
            return content
        }

        return nil
    }

    private func writeFiles(_ files: [LocalAlpineAgentFile], cwd: String) async -> LocalAlpineWriteResult {
        var lines = ["写入文件"]
        var writtenPaths: [String] = []
        for file in files.prefix(maxCommandsPerResponse) {
            let target = resolvedFilePath(file.path, cwd: cwd)
            let split = splitFilePath(target)
            guard let data = file.content.data(using: .utf8) else {
                lines.append("- `\(target)` 写入失败：内容不是有效 UTF-8")
                continue
            }
            do {
                try await LocalAlpineTerminalService.shared.writeFile(
                    data: data,
                    fileName: split.fileName,
                    destinationPath: split.directory
                )
                lines.append("- `\(target)` (\(data.count) B)")
                writtenPaths.append(target)
            } catch {
                lines.append("- `\(target)` 写入失败：\(error.localizedDescription)")
            }
        }
        let skipped = max(0, files.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余文件，避免一次写入过多。")
        }
        return LocalAlpineWriteResult(summary: lines.joined(separator: "\n"), writtenPaths: writtenPaths)
    }

    private func extractPythonHeredocWrites(from command: String, cwd: String) async -> LocalAlpineExtractedWriteResult? {
        let commandLines = command.components(separatedBy: .newlines)
        var remainingLines: [String] = []
        var summaryLines = ["写入文件（已自动保护 Python 缩进）"]
        var writtenPaths: [String] = []
        var extractedCount = 0
        var index = 0

        while index < commandLines.count {
            let line = commandLines[index]
            guard let spec = Self.pythonHeredocWriteSpec(from: line) else {
                remainingLines.append(line)
                index += 1
                continue
            }

            extractedCount += 1
            index += 1
            var bodyLines: [String] = []
            var foundTerminator = false
            while index < commandLines.count {
                let candidate = commandLines[index]
                if Self.isHeredocTerminator(candidate, marker: spec.marker) {
                    foundTerminator = true
                    index += 1
                    break
                }
                bodyLines.append(candidate)
                index += 1
            }

            guard foundTerminator else {
                return nil
            }

            let target = resolvedFilePath(spec.path, cwd: cwd)
            let split = splitFilePath(target)
            var content = bodyLines.joined(separator: "\n")
            if !content.hasSuffix("\n") {
                content += "\n"
            }
            guard let data = content.data(using: .utf8) else {
                summaryLines.append("- `\(target)` 写入失败：内容不是有效 UTF-8")
                continue
            }

            do {
                try await LocalAlpineTerminalService.shared.writeFile(
                    data: data,
                    fileName: split.fileName,
                    destinationPath: split.directory
                )
                summaryLines.append("- `\(target)` (\(data.count) B，保留原始缩进)")
                writtenPaths.append(target)
            } catch {
                summaryLines.append("- `\(target)` 写入失败：\(error.localizedDescription)")
            }
        }

        guard extractedCount > 0 else { return nil }
        let remainingCommand = writtenPaths.count == extractedCount
            ? remainingLines.joined(separator: "\n")
            : ""
        return LocalAlpineExtractedWriteResult(
            summary: summaryLines.joined(separator: "\n"),
            writtenPaths: writtenPaths,
            remainingCommand: remainingCommand
        )
    }

    private func pythonSyntaxCheck(for paths: [String], cwd: String) async -> (command: String, result: LocalAlpineCommandResult)? {
        let pythonFiles = paths.filter { $0.lowercased().hasSuffix(".py") }
        guard !pythonFiles.isEmpty else { return nil }
        let quotedPaths = pythonFiles
            .map { runtimePath(forSharedPath: $0) }
            .map(shellSingleQuoted)
            .joined(separator: " ")
        let command = "python3 -m py_compile \(quotedPaths)"
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
        return (command, result)
    }

    private func pythonSyntaxDiagnostic(for paths: [String], cwd: String) async -> (command: String, result: LocalAlpineCommandResult)? {
        let pythonFiles = paths.filter { $0.lowercased().hasSuffix(".py") }
        guard !pythonFiles.isEmpty else { return nil }
        let quotedPaths = pythonFiles
            .map { runtimePath(forSharedPath: $0) }
            .map(shellSingleQuoted)
            .joined(separator: " ")
        let command = """
        for file in \(quotedPaths); do
          printf '== file with line numbers: %s ==\\n' "$file"
          if [ -f "$file" ]; then
            nl -ba "$file" | sed -n '1,160p'
          else
            printf 'missing: %s\\n' "$file"
          fi
        done
        """
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
        return (command, result)
    }

    private func pythonSyntaxDiagnostic(
        command: String,
        output: String,
        cwd: String
    ) async -> (command: String, result: LocalAlpineCommandResult)? {
        guard Self.outputHasPythonSyntaxIssue(output),
              let file = Self.pythonFilePath(command: command, output: output, cwd: cwd) else {
            return nil
        }

        let quotedFile = shellSingleQuoted(file)
        let command = """
        file=\(quotedFile)
        printf '== python file with line numbers: %s ==\\n' "$file"
        if [ -f "$file" ]; then
          nl -ba "$file" | sed -n '1,220p'
        else
          printf 'missing: %s\\n' "$file"
        fi
        """
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
        return (command, result)
    }

    private func format(command: String, cwd: String, result: LocalAlpineCommandResult) -> String {
        let output = truncated(result.output)
        let renderedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "（无输出）"
            : output
        let exit = result.exitCode.map(String.init) ?? "unknown"
        let commandBlock = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        命令

        ```bash
        \(commandBlock)
        ```

        工作目录：`\(cwd)`
        退出码：`\(exit)`

        输出

        ```text
        \(renderedOutput)
        ```
        """
    }

    private func truncated(_ output: String) -> String {
        guard output.count > maxOutputCharactersPerCommand else { return output }
        let prefix = String(output.prefix(maxOutputCharactersPerCommand))
        return prefix + "\n...（输出过长，已截断）"
    }

    private func resolvedFilePath(_ path: String, cwd: String) -> String {
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !raw.isEmpty else { return "/untitled.txt" }
        if raw.hasPrefix("/mnt/iexa/") {
            return "/" + raw.dropFirst("/mnt/iexa/".count)
        }
        if raw == "/mnt/iexa" {
            return "/"
        }
        if raw.hasPrefix("/") {
            return raw
        }

        let normalizedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let base: String
        if normalizedCWD == "/mnt/iexa" || normalizedCWD.isEmpty {
            base = "/"
        } else if normalizedCWD.hasPrefix("/mnt/iexa/") {
            base = "/" + normalizedCWD.dropFirst("/mnt/iexa/".count)
        } else if normalizedCWD.hasPrefix("/") {
            base = normalizedCWD
        } else {
            base = "/" + normalizedCWD
        }
        return (base == "/" ? "/" : base + "/") + raw
    }

    private func splitFilePath(_ path: String) -> (directory: String, fileName: String) {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard let slashIndex = normalized.lastIndex(of: "/") else {
            return ("/", normalized)
        }
        let fileName = String(normalized[normalized.index(after: slashIndex)...])
        let directory = String(normalized[..<slashIndex])
        return (directory.isEmpty ? "/" : directory, fileName.isEmpty ? "untitled.txt" : fileName)
    }

    private func runtimePath(forSharedPath path: String) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if normalized == "/" { return "/mnt/iexa" }
        if normalized.hasPrefix("/") { return "/mnt/iexa\(normalized)" }
        return "/mnt/iexa/\(normalized)"
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func unsafePythonFileWriteWarning(for command: String) -> String? {
        guard Self.commandWritesPythonThroughShellText(command) else { return nil }
        return """
        Unsafe Python file write blocked.

        This command writes a `.py` file through shell text redirection/heredoc (`cat`, `tee`, `printf`, `echo`, or `python - <<`). In this chat UI that path can corrupt leading spaces and cause Python IndentationError.

        Use `iexa_alpine` JSON `write_files` with `content_lines` or `content_base64` for new Python files. When fixing an existing file, inspect line numbers first and patch the smallest broken block, then run `python3 -m py_compile`.
        """
    }

    private nonisolated static func commandWritesPythonThroughShellText(_ command: String) -> Bool {
        let normalized = command.lowercased()
        guard normalized.contains(".py") else { return false }

        let patterns = [
            #"(?is)\bcat\s+>+[^;&|]*\.py\b"#,
            #"(?is)\bcat\s+<<[\s\S]{0,240}>+[^;&|]*\.py\b"#,
            #"(?is)\btee\s+(?:-a\s+)?[^;&|]*\.py\b"#,
            #"(?is)\b(?:printf|echo)\b[\s\S]{0,400}>+[^;&|]*\.py\b"#,
            #"(?is)\bpython3?\s+-\s*<<"#
        ]

        return patterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private nonisolated static func pythonHeredocWriteSpec(from line: String) -> PythonHeredocWriteSpec? {
        let patterns: [(pattern: String, pathRange: Int, markerRange: Int)] = [
            (#"^\s*cat\s+>+\s*(['"]?)([^'">\s;|&]+\.py)\1\s*<<-?\s*(['"]?)([A-Za-z0-9_.-]+)\3\s*$"#, 2, 4),
            (#"^\s*cat\s*<<-?\s*(['"]?)([A-Za-z0-9_.-]+)\1\s*>+\s*(['"]?)([^'">\s;|&]+\.py)\3\s*$"#, 4, 2),
            (#"^\s*tee\s+(?:-a\s+)?(['"]?)([^'">\s;|&]+\.py)\1(?:\s*>\s*/dev/null)?\s*<<-?\s*(['"]?)([A-Za-z0-9_.-]+)\3\s*$"#, 2, 4),
            (#"^\s*tee\s+(?:-a\s+)?(['"]?)([^'">\s;|&]+\.py)\1\s*<<-?\s*(['"]?)([A-Za-z0-9_.-]+)\3(?:\s*>\s*/dev/null)?\s*$"#, 2, 4)
        ]

        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, range: fullRange),
                  match.numberOfRanges > max(entry.pathRange, entry.markerRange) else {
                continue
            }

            let path = nsLine.substring(with: match.range(at: entry.pathRange))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = nsLine.substring(with: match.range(at: entry.markerRange))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !marker.isEmpty else { continue }
            return PythonHeredocWriteSpec(path: path, marker: marker)
        }

        return nil
    }

    private nonisolated static func isHeredocTerminator(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == marker
    }

    private nonisolated static func outputHasPythonSyntaxIssue(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("indentationerror")
            || lowercased.contains("syntaxerror")
            || lowercased.contains("taberror")
    }

    private nonisolated static func pythonFilePath(command: String, output: String, cwd: String) -> String? {
        let combined = output + "\n" + command
        let patterns = [
            #"File\s+\"([^\"]+\.py)\""#,
            #"\(([A-Za-z0-9_./\-]+\.py),\s*line\s+\d+\)"#,
            #"([/A-Za-z0-9_.\-]+\.py)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsCombined = combined as NSString
            let range = NSRange(location: 0, length: nsCombined.length)
            guard let match = regex.firstMatch(in: combined, range: range),
                  match.numberOfRanges >= 2 else {
                continue
            }

            let candidate = nsCombined.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            if candidate.hasPrefix("/") {
                return candidate
            }

            let normalizedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = normalizedCWD.isEmpty ? "/mnt/iexa" : normalizedCWD
            return base.hasSuffix("/") ? base + candidate : base + "/" + candidate
        }

        return nil
    }

    nonisolated static func visibleContent(from content: String) -> String {
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var removalRanges: [NSRange] = []

        if let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#, options: [.caseInsensitive]) {
            let matches = regex.matches(in: content, range: fullRange)
            for match in matches where match.numberOfRanges >= 3 {
                let info = nsContent.substring(with: match.range(at: 1)).lowercased()
                let body = nsContent.substring(with: match.range(at: 2))
                if info.contains("iexa_alpine")
                    || (info.trimmingCharacters(in: .whitespacesAndNewlines) == "json"
                        && body.contains("\"iexa_alpine\"")) {
                    removalRanges.append(match.range)
                }
            }
        }

        if let tagRegex = try? NSRegularExpression(pattern: #"<iexa_alpine>[\s\S]*?</iexa_alpine>"#, options: [.caseInsensitive]) {
            removalRanges.append(contentsOf: tagRegex.matches(in: content, range: fullRange).map(\.range))
        }

        if let incompleteFenceRange = incompleteInstructionFenceRange(in: content) {
            removalRanges.append(incompleteFenceRange)
        }

        if let incompleteTagRange = incompleteInstructionTagRange(in: content) {
            removalRanges.append(incompleteTagRange)
        }

        guard !removalRanges.isEmpty else {
            return content
        }

        let mutable = NSMutableString(string: content)
        for range in removalRanges.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: "")
        }

        let cleaned = (mutable as String)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "正在执行本地 Alpine 命令..." : cleaned
    }

    nonisolated private static func incompleteInstructionFenceRange(in content: String) -> NSRange? {
        guard let markerRange = content.range(
            of: "```iexa_alpine",
            options: [.caseInsensitive, .backwards]
        ) else {
            return nil
        }

        let afterMarker = content[markerRange.upperBound...]
        guard afterMarker.range(of: "```") == nil else {
            return nil
        }

        return NSRange(markerRange.lowerBound..<content.endIndex, in: content)
    }

    nonisolated private static func incompleteInstructionTagRange(in content: String) -> NSRange? {
        guard let markerRange = content.range(
            of: "<iexa_alpine>",
            options: [.caseInsensitive, .backwards]
        ) else {
            return nil
        }

        let afterMarker = content[markerRange.upperBound...]
        guard afterMarker.range(of: "</iexa_alpine>", options: .caseInsensitive) == nil else {
            return nil
        }

        return NSRange(markerRange.lowerBound..<content.endIndex, in: content)
    }
}

private struct LocalAlpineAgentCommand {
    let command: String?
    let cwd: String?
    let writeFiles: [LocalAlpineAgentFile]
}

private struct LocalAlpineAgentFile {
    let path: String
    let content: String
}

private struct LocalAlpineWriteResult {
    let summary: String
    let writtenPaths: [String]
}

private struct LocalAlpineExtractedWriteResult {
    let summary: String
    let writtenPaths: [String]
    let remainingCommand: String
}

private struct PythonHeredocWriteSpec {
    let path: String
    let marker: String
}

private enum LocalAlpineAgentError: LocalizedError {
    case noCommands

    var errorDescription: String? {
        switch self {
        case .noCommands:
            return "没有找到可执行的 Alpine 命令。"
        }
    }
}
