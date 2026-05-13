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
                if writeResult.hadFailure {
                    let result = LocalAlpineCommandResult(
                        command: "write_files",
                        output: writeResult.summary,
                        exitCode: 125,
                        interactiveRequest: nil
                    )
                    commandResults.append(Self.commandResult(
                        command: "write_files",
                        cwd: effectiveCWD,
                        result: result
                    ))
                    shouldRunShellCommand = false
                }
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
                        let repairs = await pythonSyntaxAutoRepair(
                            command: syntaxCheck.command,
                            output: syntaxCheck.result.output,
                            cwd: effectiveCWD
                        )
                        for repair in repairs {
                            stepLines.append(format(command: repair.command, cwd: effectiveCWD, result: repair.result))
                            commandResults.append(Self.commandResult(
                                command: repair.command,
                                cwd: effectiveCWD,
                                result: repair.result
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
                            let repairs = await pythonSyntaxAutoRepair(
                                command: syntaxCheck.command,
                                output: syntaxCheck.result.output,
                                cwd: effectiveCWD
                            )
                            for repair in repairs {
                                stepLines.append(format(command: repair.command, cwd: effectiveCWD, result: repair.result))
                                commandResults.append(Self.commandResult(
                                    command: repair.command,
                                    cwd: effectiveCWD,
                                    result: repair.result
                                ))
                            }
                            commandToExecute = ""
                        }
                    }
                    if extractedFilesPassedSyntaxCheck {
                        commandToExecute = extractedWrite.remainingCommand
                    }
                }

                if let blockedOutput = unsafePythonFileWriteWarning(for: commandToExecute) {
                    let result = LocalAlpineCommandResult(
                        command: commandToExecute,
                        output: blockedOutput,
                        exitCode: 125,
                        interactiveRequest: nil
                    )
                    stepLines.append(format(command: commandToExecute, cwd: effectiveCWD, result: result))
                    commandResults.append(Self.commandResult(
                        command: commandToExecute,
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
                let repairs = await pythonSyntaxAutoRepair(
                    command: commandToExecute,
                    output: result.output,
                    cwd: effectiveCWD
                )
                for repair in repairs {
                    stepLines.append(format(command: repair.command, cwd: effectiveCWD, result: repair.result))
                    commandResults.append(Self.commandResult(
                        command: repair.command,
                        cwd: effectiveCWD,
                        result: repair.result
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
            let payload = Self.writeFilePayload(from: dict) else {
            return nil
        }
        return LocalAlpineAgentFile(path: path, content: payload.content, source: payload.source)
    }

    private nonisolated static func writeFilePayload(
        from dict: [String: Any]
    ) -> (content: String, source: LocalAlpineAgentFileSource)? {
        if let content = (dict["content"] as? String)
            ?? (dict["text"] as? String)
            ?? (dict["body"] as? String) {
            return (content, .content)
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
            return (content, .contentLines)
        }

        if let base64 = (dict["content_base64"] as? String)
            ?? (dict["base64"] as? String),
           let data = Data(base64Encoded: base64),
           let content = String(data: data, encoding: .utf8) {
            return (content, .contentBase64)
        }

        return nil
    }

    private func writeFiles(_ files: [LocalAlpineAgentFile], cwd: String) async -> LocalAlpineWriteResult {
        var lines = ["写入文件"]
        var writtenPaths: [String] = []
        var hadFailure = false
        for file in files.prefix(maxCommandsPerResponse) {
            let target = resolvedFilePath(file.path, cwd: cwd)
            let split = splitFilePath(target)
            var content = file.content
            var repairNote: String?
            if target.lowercased().hasSuffix(".py"),
               let warning = Self.pythonIndentationPreflightWarning(for: content) {
                if let repaired = Self.repairFlattenedPythonIndentation(content),
                   Self.pythonIndentationPreflightWarning(for: repaired) == nil {
                    content = repaired
                    repairNote = "  - 已自动修复明显被压平的 Python 缩进：\(warning)"
                } else {
                    hadFailure = true
                    lines.append("- `\(target)` 写入已拒绝：Python 缩进预检失败。\(warning)")
                    lines.append("  - 这个文件没有被覆盖。请先读取现有文件行号，或用 `content_lines` / `content_base64` 重新提交带 4 空格缩进的内容。")
                    continue
                }
            }
            guard let data = content.data(using: .utf8) else {
                hadFailure = true
                lines.append("- `\(target)` 写入失败：内容不是有效 UTF-8")
                continue
            }
            do {
                try await LocalAlpineTerminalService.shared.writeFile(
                    data: data,
                    fileName: split.fileName,
                    destinationPath: split.directory
                )
                lines.append("- `\(target)` (\(data.count) B，来源：\(file.source.displayName))")
                if let repairNote {
                    lines.append(repairNote)
                }
                writtenPaths.append(target)
            } catch {
                hadFailure = true
                lines.append("- `\(target)` 写入失败：\(error.localizedDescription)")
            }
        }
        let skipped = max(0, files.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余文件，避免一次写入过多。")
        }
        return LocalAlpineWriteResult(summary: lines.joined(separator: "\n"), writtenPaths: writtenPaths, hadFailure: hadFailure)
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
            if let warning = Self.pythonIndentationPreflightWarning(for: content) {
                if let repaired = Self.repairFlattenedPythonIndentation(content),
                   Self.pythonIndentationPreflightWarning(for: repaired) == nil {
                    content = repaired
                    summaryLines.append("  - 已自动修复明显被压平的 Python 缩进：\(warning)")
                } else {
                    summaryLines.append("- `\(target)` 写入已拒绝：Python 缩进预检失败。\(warning)")
                    summaryLines.append("  - 这个文件没有被覆盖。请先读取现有文件行号，或改用 `write_files.content_lines` / `content_base64` 提交带 4 空格缩进的内容。")
                    continue
                }
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

    private func pythonSyntaxAutoRepair(
        command: String,
        output: String,
        cwd: String
    ) async -> [(command: String, result: LocalAlpineCommandResult)] {
        guard Self.outputHasPythonSyntaxIssue(output),
              let issueFile = Self.pythonFilePath(command: command, output: output, cwd: cwd) else {
            return []
        }

        let sharedPath = resolvedFilePath(issueFile, cwd: cwd)
        let runtimeFile = runtimePathForIssueFile(issueFile, sharedPath: sharedPath)

        do {
            let originalData = try await LocalAlpineTerminalService.shared.readFile(path: issueFile)
            guard let original = String(data: originalData, encoding: .utf8),
                  let repaired = Self.repairFlattenedPythonIndentation(original, force: true),
                  repaired != original,
                  let repairedData = repaired.data(using: .utf8) else {
                return []
            }

            let split = splitFilePath(sharedPath)
            try await LocalAlpineTerminalService.shared.writeFile(
                data: repairedData,
                fileName: split.fileName,
                destinationPath: split.directory
            )

            var results: [(command: String, result: LocalAlpineCommandResult)] = []
            let note = LocalAlpineCommandResult(
                command: "iexa_auto_python_repair \(shellSingleQuoted(runtimeFile))",
                output: """
                已根据 SyntaxError/IndentationError 自动修复疑似被压平的 Python 缩进。
                文件：\(runtimeFile)
                下一步自动运行 py_compile 验证；如果验证失败，会恢复原文件。
                """,
                exitCode: 0,
                interactiveRequest: nil
            )
            results.append((note.command, note))

            let compileCommand = "python3 -m py_compile \(shellSingleQuoted(runtimeFile))"
            let compile = await LocalAlpineTerminalService.shared.execute(command: compileCommand, cwd: cwd)
            if compile.exitCode != 0 {
                try? await LocalAlpineTerminalService.shared.writeFile(
                    data: originalData,
                    fileName: split.fileName,
                    destinationPath: split.directory
                )
                let restored = LocalAlpineCommandResult(
                    command: compileCommand,
                    output: """
                    \(compile.output)

                    自动缩进修复未通过 py_compile，已恢复原文件，避免把错误内容越修越乱。
                    """,
                    exitCode: compile.exitCode,
                    interactiveRequest: nil
                )
                results.append((compileCommand, restored))
                return results
            }

            let verified = LocalAlpineCommandResult(
                command: compileCommand,
                output: compile.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "IEXA_AUTO_REPAIR_PY_COMPILE_SUCCESS"
                    : compile.output + "\nIEXA_AUTO_REPAIR_PY_COMPILE_SUCCESS",
                exitCode: compile.exitCode,
                interactiveRequest: compile.interactiveRequest
            )
            results.append((compileCommand, verified))

            if let verificationCommand = postRepairVerificationCommand(originalCommand: command, runtimeFile: runtimeFile) {
                let verification = await LocalAlpineTerminalService.shared.execute(command: verificationCommand, cwd: cwd)
                let output = verification.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (verification.exitCode == 0 ? "IEXA_AUTO_REPAIR_VERIFIED_SUCCESS" : "")
                    : verification.output + (verification.exitCode == 0 ? "\nIEXA_AUTO_REPAIR_VERIFIED_SUCCESS" : "")
                let wrapped = LocalAlpineCommandResult(
                    command: verificationCommand,
                    output: output,
                    exitCode: verification.exitCode,
                    interactiveRequest: verification.interactiveRequest
                )
                results.append((verificationCommand, wrapped))
            }

            return results
        } catch {
            return []
        }
    }

    private func runtimePathForIssueFile(_ issueFile: String, sharedPath: String) -> String {
        let normalized = issueFile.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if normalized == "/mnt/iexa" || normalized.hasPrefix("/mnt/iexa/") {
            return normalized
        }
        return runtimePath(forSharedPath: sharedPath)
    }

    private func postRepairVerificationCommand(originalCommand: String, runtimeFile: String) -> String? {
        let normalized = originalCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.contains("&&") || normalized.contains(";") {
            return originalCommand
        }

        if normalized.contains("-m py_compile") {
            return "python3 \(shellSingleQuoted(runtimeFile))"
        }

        if normalized.contains("python") && normalized.contains(".py") {
            return originalCommand
        }

        return nil
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
            #"(?is)\b(?:printf|echo)\b[\s\S]{0,400}>+[^;&|]*\.py\b"#
        ]

        return patterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private nonisolated static func pythonIndentationPreflightWarning(for content: String) -> String? {
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
            guard pythonLineOpensBlock(current.text) else { continue }
            guard let next = significant[(index + 1)..<significant.endIndex].first else { continue }
            if next.indent <= current.indent {
                return "第 \(current.number) 行以 `:` 开启代码块，但第 \(next.number) 行没有增加缩进。写入模块会原样保存模型给出的内容，请改用正确缩进的 content_lines 或 content_base64。"
            }
        }

        let hasPythonBlocks = significant.contains { pythonLineOpensBlock($0.text) }
        let maxIndent = significant.map { $0.indent }.max() ?? 0
        if hasPythonBlocks, maxIndent == 1 {
            return "检测到 Python 代码块但最大缩进只有 1 个空格，这通常是模型输出缩进被压平。"
        }

        return nil
    }

    private nonisolated static func pythonLineOpensBlock(_ text: String) -> Bool {
        guard text.hasSuffix(":") else { return false }
        let lowered = text.lowercased()
        let starters = [
            "def ", "class ", "if ", "elif ", "else:", "for ", "while ",
            "try:", "except", "finally:", "with ", "async def ", "async with ",
            "match ", "case "
        ]
        return starters.contains { lowered.hasPrefix($0) }
    }

    private nonisolated static func repairFlattenedPythonIndentation(_ content: String, force: Bool = false) -> String? {
        guard force || pythonIndentationPreflightWarning(for: content) != nil else { return nil }
        let rawLines = content.components(separatedBy: .newlines)
        let significantIndents = rawLines.compactMap { line -> Int? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            return line.prefix { $0 == " " || $0 == "\t" }.count
        }
        guard !significantIndents.isEmpty,
              (significantIndents.max() ?? 0) <= 8 else {
            return nil
        }

        var repaired: [String] = []
        var indentLevel = 0
        var previousOpenedBlock = false
        var blankBefore = false

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                repaired.append("")
                blankBefore = true
                continue
            }

            if trimmed.hasPrefix("#") {
                repaired.append(String(repeating: " ", count: indentLevel * 4) + trimmed)
                blankBefore = false
                continue
            }

            if blankBefore {
                indentLevel = pythonIndentationLevelAfterBlankLine(current: indentLevel, text: trimmed)
            }
            if isLikelyTopLevelPythonLine(trimmed, rawIndent: rawLine.prefix { $0 == " " || $0 == "\t" }.count, previousOpenedBlock: previousOpenedBlock) {
                indentLevel = 0
            }
            if pythonLineClosesBlock(trimmed), indentLevel > 0 {
                indentLevel -= 1
            }

            repaired.append(String(repeating: " ", count: max(0, indentLevel) * 4) + trimmed)

            if pythonLineOpensBlock(trimmed) {
                indentLevel += 1
                previousOpenedBlock = true
            } else {
                previousOpenedBlock = false
                if pythonLineTerminatesCurrentBlock(trimmed), indentLevel > 0 {
                    indentLevel -= 1
                }
            }
            blankBefore = false
        }

        let joined = repaired.joined(separator: "\n")
        guard joined != content,
              pythonIndentationPreflightWarning(for: joined) == nil else {
            return nil
        }
        return joined
    }

    private nonisolated static func isLikelyTopLevelPythonLine(_ text: String, rawIndent: Int, previousOpenedBlock: Bool) -> Bool {
        guard rawIndent == 0, !previousOpenedBlock else { return false }
        let lowered = text.lowercased()
        if lowered.hasPrefix("if __name__") { return true }
        if lowered.hasPrefix("def ") || lowered.hasPrefix("class ") { return true }
        if lowered.hasPrefix("import ") || lowered.hasPrefix("from ") { return true }
        if lowered.hasPrefix("@") { return true }
        return false
    }

    private nonisolated static func pythonIndentationLevelAfterBlankLine(current: Int, text: String) -> Int {
        guard current > 1 else { return current }
        let lowered = text.lowercased()
        if lowered.hasPrefix("return")
            || lowered.hasPrefix("yield")
            || lowered.hasPrefix("raise ")
            || lowered.hasPrefix("print(")
            || lowered.hasPrefix("result =")
            || lowered.hasPrefix("total =")
            || lowered.hasPrefix("count =") {
            return 1
        }
        return current
    }

    private nonisolated static func pythonLineClosesBlock(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("elif ")
            || lowered.hasPrefix("else:")
            || lowered.hasPrefix("except")
            || lowered.hasPrefix("finally:")
            || lowered.hasPrefix("case ")
    }

    private nonisolated static func pythonLineTerminatesCurrentBlock(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered == "pass"
            || lowered == "break"
            || lowered == "continue"
            || lowered.hasPrefix("return")
            || lowered.hasPrefix("yield")
            || lowered.hasPrefix("raise ")
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

        return cleaned
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
    let source: LocalAlpineAgentFileSource
}

private enum LocalAlpineAgentFileSource {
    case content
    case contentLines
    case contentBase64

    var displayName: String {
        switch self {
        case .content: return "content"
        case .contentLines: return "content_lines"
        case .contentBase64: return "content_base64"
        }
    }
}

private struct LocalAlpineWriteResult {
    let summary: String
    let writtenPaths: [String]
    let hadFailure: Bool
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
