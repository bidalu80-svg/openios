import Foundation

struct LocalAlpineAgentResult: Sendable {
    let didExecute: Bool
    let summary: String
    let interactiveRequest: LocalAlpineInteractiveRequest?
    let commandResults: [LocalAlpineAgentCommandResult]
    let executedCommandCount: Int
    let editedFileCount: Int
    let hadFailure: Bool

    init(
        didExecute: Bool,
        summary: String,
        interactiveRequest: LocalAlpineInteractiveRequest?,
        commandResults: [LocalAlpineAgentCommandResult] = [],
        executedCommandCount: Int = 0,
        editedFileCount: Int = 0,
        hadFailure: Bool = false
    ) {
        self.didExecute = didExecute
        self.summary = summary
        self.interactiveRequest = interactiveRequest
        self.commandResults = commandResults
        self.executedCommandCount = executedCommandCount
        self.editedFileCount = editedFileCount
        self.hadFailure = hadFailure
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
        var editedFilePaths = Set<String>()
        var stopRemainingCommands = false

        lines.insert("Local Alpine 执行结果", at: 0)
        lines.append("环境：内置 Alpine Linux，工作目录默认 `/mnt/iexa`")

        for command in trimmedCommands {
            guard !stopRemainingCommands else { break }

            let cwd = command.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveCWD = (cwd?.isEmpty == false) ? cwd! : defaultCWD
            var stepLines: [String] = []
            var shouldRunShellCommand = true
            if !command.writeFiles.isEmpty {
                let writeResult = await writeFiles(command.writeFiles, cwd: effectiveCWD)
                stepLines.append(writeResult.summary)
                writeResult.writtenPaths.forEach { editedFilePaths.insert($0) }
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
                    stopRemainingCommands = true
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
                        shouldRunShellCommand = false
                        stopRemainingCommands = true
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
                    extractedWrite.writtenPaths.forEach { editedFilePaths.insert($0) }
                    if extractedWrite.hadFailure {
                        extractedFilesPassedSyntaxCheck = false
                        let result = LocalAlpineCommandResult(
                            command: "python_heredoc_write",
                            output: extractedWrite.summary,
                            exitCode: 125,
                            interactiveRequest: nil
                        )
                        commandResults.append(Self.commandResult(
                            command: "python_heredoc_write",
                            cwd: effectiveCWD,
                            result: result
                        ))
                        commandToExecute = ""
                        stopRemainingCommands = true
                    }
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
                            stopRemainingCommands = true
                        }
                    }
                    if extractedFilesPassedSyntaxCheck {
                        commandToExecute = extractedWrite.remainingCommand
                    }
                }

                if let blockedOutput = unsafeCodeFileWriteWarning(for: commandToExecute) {
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
                            commandResults: commandResults,
                            executedCommandCount: Self.actualCommandCount(commandResults),
                            editedFileCount: editedFilePaths.count,
                            hadFailure: commandResults.contains { $0.failed }
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
            commandResults: commandResults,
            executedCommandCount: Self.actualCommandCount(commandResults),
            editedFileCount: editedFilePaths.count,
            hadFailure: commandResults.contains { $0.failed }
        )
    }

    private nonisolated static func actualCommandCount(_ results: [LocalAlpineAgentCommandResult]) -> Int {
        results.filter { result in
            let command = result.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return command != "write_files"
                && command != "python_heredoc_write"
        }.count
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
                writeFiles: parseWriteFilesForCommand(from: dict)
            )]
        }

        if let command = dict["cmd"] as? String {
            return [LocalAlpineAgentCommand(
                command: command,
                cwd: dict["cwd"] as? String,
                writeFiles: parseWriteFilesForCommand(from: dict)
            )]
        }

        let files = parseWriteFilesForCommand(from: dict)
        if !files.isEmpty {
            return [LocalAlpineAgentCommand(command: nil, cwd: dict["cwd"] as? String, writeFiles: files)]
        }

        return []
    }

    private func parseWriteFilesForCommand(from dict: [String: Any]) -> [LocalAlpineAgentFile] {
        let nestedFiles = parseWriteFiles(from: Self.writeFilesObject(from: dict))
        guard nestedFiles.isEmpty else { return nestedFiles }
        return parseWriteFile(from: dict).map { [$0] } ?? []
    }

    private nonisolated static func writeFilesObject(from dict: [String: Any]) -> Any? {
        dict["write_files"] ?? dict["write_file"] ?? dict["files"]
    }

    private func parseWriteFiles(from object: Any?) -> [LocalAlpineAgentFile] {
        if let array = object as? [Any] {
            return array.flatMap { parseWriteFiles(from: $0) }
        }
        if let dict = object as? [String: Any] {
            let nestedFiles = parseWriteFiles(from: Self.writeFilesObject(from: dict))
            guard nestedFiles.isEmpty else { return nestedFiles }
            return parseWriteFile(from: dict).map { [$0] } ?? []
        }
        return []
    }

    private func parseWriteFile(from object: Any) -> LocalAlpineAgentFile? {
        guard let dict = object as? [String: Any] else { return nil }
        guard let path = (dict["path"] as? String)
            ?? (dict["file"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["filename"] as? String)
            ?? (dict["write_file"] as? String)
            ?? (dict["target"] as? String),
            let payload = Self.writeFilePayload(from: dict) else {
            return nil
        }
        return LocalAlpineAgentFile(path: path, content: payload.content, source: payload.source)
    }

    private nonisolated static func writeFilePayload(
        from dict: [String: Any]
    ) -> (content: String, source: LocalAlpineAgentFileSource)? {
        if let base64 = (dict["content_base64"] as? String)
            ?? (dict["base64"] as? String),
           let data = Data(base64Encoded: base64),
           let content = String(data: data, encoding: .utf8) {
            return (content, .contentBase64)
        }

        if let lines = (dict["code_lines"] as? [String])
            ?? (dict["content_lines"] as? [String])
            ?? (dict["lines"] as? [String]) {
            var content = lines.joined(separator: "\n")
            let shouldAppendNewline = (dict["append_newline"] as? Bool)
                ?? (dict["trailing_newline"] as? Bool)
                ?? true
            if shouldAppendNewline, !content.hasSuffix("\n") {
                content += "\n"
            }
            let source: LocalAlpineAgentFileSource = dict["code_lines"] != nil ? .codeLines : .contentLines
            return (content, source)
        }

        if let content = (dict["content"] as? String)
            ?? (dict["contents"] as? String)
            ?? (dict["text"] as? String)
            ?? (dict["body"] as? String)
            ?? (dict["code"] as? String) {
            return (content, .content)
        }

        return nil
    }

    private func writeFiles(_ files: [LocalAlpineAgentFile], cwd: String) async -> LocalAlpineWriteResult {
        var lines = ["写入文件"]
        var writtenPaths: [String] = []
        var hadFailure = false
        for file in files.prefix(maxCommandsPerResponse) {
            let outcome = await writeProtectedFile(file, cwd: cwd)
            lines.append(contentsOf: outcome.lines)
            if let writtenPath = outcome.writtenPath {
                writtenPaths.append(writtenPath)
            }
            if outcome.hadFailure {
                hadFailure = true
            }
        }
        let skipped = max(0, files.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余文件，避免一次写入过多。")
        }
        return LocalAlpineWriteResult(summary: lines.joined(separator: "\n"), writtenPaths: writtenPaths, hadFailure: hadFailure)
    }

    private func writeProtectedFile(_ file: LocalAlpineAgentFile, cwd: String) async -> LocalAlpineProtectedWriteOutcome {
        let target = resolvedFilePath(file.path, cwd: cwd)
        let split = splitFilePath(target)
        let isPython = target.lowercased().hasSuffix(".py")

        let prepared: PythonWritePreparation
        if isPython {
            prepared = Self.preparePythonForProtectedWrite(file.content, source: file.source)
            if case .failure(let message) = prepared {
                return LocalAlpineProtectedWriteOutcome(
                    lines: [
                        "- `\(target)` 写入已拒绝：\(message)",
                        "  - 目标文件没有被覆盖。请改用 `code_lines` / `content_lines` / `content_base64` 提交完整源码，或先读取行号后用受保护写入重写整段。"
                    ],
                    writtenPath: nil,
                    hadFailure: true
                )
            }
        } else {
            prepared = .success(content: file.content, notes: [])
        }

        guard case .success(let content, let notes) = prepared,
              let data = content.data(using: .utf8) else {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：内容不是有效 UTF-8"],
                writtenPath: nil,
                hadFailure: true
            )
        }

        if isPython {
            return await writeValidatedPythonFile(
                data: data,
                target: target,
                split: split,
                cwd: cwd,
                source: file.source,
                notes: notes
            )
        }

        do {
            try await LocalAlpineTerminalService.shared.writeFile(
                data: data,
                fileName: split.fileName,
                destinationPath: split.directory
            )
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` (\(data.count) B，来源：\(file.source.displayName))"],
                writtenPath: target,
                hadFailure: false
            )
        } catch {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：\(error.localizedDescription)"],
                writtenPath: nil,
                hadFailure: true
            )
        }
    }

    private func writeValidatedPythonFile(
        data: Data,
        target: String,
        split: (directory: String, fileName: String),
        cwd: String,
        source: LocalAlpineAgentFileSource,
        notes: [String]
    ) async -> LocalAlpineProtectedWriteOutcome {
        let temporaryName = ".iexa-write-\(UUID().uuidString).py"
        let temporaryPath = split.directory == "/" ? "/\(temporaryName)" : "\(split.directory)/\(temporaryName)"
        let temporaryRuntimePath = runtimePath(forSharedPath: temporaryPath)
        let currentData = data
        let currentNotes = notes

        do {
            try await LocalAlpineTerminalService.shared.writeFile(
                data: currentData,
                fileName: temporaryName,
                destinationPath: split.directory
            )

            let targetRuntimePath = runtimePath(forSharedPath: target)
            let astBeforeCommand = pythonASTValidationCommand(for: temporaryRuntimePath)
            let astBefore = await LocalAlpineTerminalService.shared.execute(command: astBeforeCommand, cwd: cwd)
            if astBefore.exitCode != 0 {
                let diagnostic = await pythonLineNumberDiagnostic(
                    for: temporaryRuntimePath,
                    targetRuntimePath: targetRuntimePath,
                    cwd: cwd
                )
                let draftRuntimePath = await preserveFailedPythonDraft(
                    temporaryPath: temporaryPath,
                    fallbackData: currentData,
                    target: target
                )
                try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)
                return failedPythonWriteOutcome(
                    target: target,
                    targetRuntimePath: targetRuntimePath,
                    failedDraftRuntimePath: draftRuntimePath,
                    reason: "Python AST 校验失败，目标文件未覆盖",
                    command: astBeforeCommand,
                    result: astBefore,
                    diagnosticOutput: diagnostic?.output
                )
            }

            let blackCommand = pythonBlackFormatCommand(for: temporaryRuntimePath)
            let black = await LocalAlpineTerminalService.shared.execute(command: blackCommand, cwd: cwd)
            if black.exitCode != 0 {
                let diagnostic = await pythonLineNumberDiagnostic(
                    for: temporaryRuntimePath,
                    targetRuntimePath: targetRuntimePath,
                    cwd: cwd
                )
                let draftRuntimePath = await preserveFailedPythonDraft(
                    temporaryPath: temporaryPath,
                    fallbackData: currentData,
                    target: target
                )
                try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)
                return failedPythonWriteOutcome(
                    target: target,
                    targetRuntimePath: targetRuntimePath,
                    failedDraftRuntimePath: draftRuntimePath,
                    reason: "Black 自动格式化失败，目标文件未覆盖",
                    command: blackCommand,
                    result: black,
                    diagnosticOutput: diagnostic?.output
                )
            }

            let astAfterCommand = pythonASTValidationCommand(for: temporaryRuntimePath)
            let astAfter = await LocalAlpineTerminalService.shared.execute(command: astAfterCommand, cwd: cwd)
            if astAfter.exitCode != 0 {
                let diagnostic = await pythonLineNumberDiagnostic(
                    for: temporaryRuntimePath,
                    targetRuntimePath: targetRuntimePath,
                    cwd: cwd
                )
                let draftRuntimePath = await preserveFailedPythonDraft(
                    temporaryPath: temporaryPath,
                    fallbackData: currentData,
                    target: target
                )
                try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)
                return failedPythonWriteOutcome(
                    target: target,
                    targetRuntimePath: targetRuntimePath,
                    failedDraftRuntimePath: draftRuntimePath,
                    reason: "Python 二次 AST 校验失败，目标文件未覆盖",
                    command: astAfterCommand,
                    result: astAfter,
                    diagnosticOutput: diagnostic?.output
                )
            }

            let compileCommand = "python3 -m py_compile \(shellSingleQuoted(temporaryRuntimePath))"
            let compile = await LocalAlpineTerminalService.shared.execute(command: compileCommand, cwd: cwd)
            if compile.exitCode != 0 {
                let diagnostic = await pythonLineNumberDiagnostic(
                    for: temporaryRuntimePath,
                    targetRuntimePath: targetRuntimePath,
                    cwd: cwd
                )
                let draftRuntimePath = await preserveFailedPythonDraft(
                    temporaryPath: temporaryPath,
                    fallbackData: currentData,
                    target: target
                )
                try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)
                return failedPythonWriteOutcome(
                    target: target,
                    targetRuntimePath: targetRuntimePath,
                    failedDraftRuntimePath: draftRuntimePath,
                    reason: "Python 事务编译失败，目标文件未覆盖",
                    command: compileCommand,
                    result: compile,
                    diagnosticOutput: diagnostic?.output
                )
            }

            let semanticCommand = pythonSemanticValidationCommand(for: temporaryRuntimePath)
            let semantic = await LocalAlpineTerminalService.shared.execute(command: semanticCommand, cwd: cwd)
            if semantic.exitCode != 0 {
                let diagnostic = await pythonLineNumberDiagnostic(
                    for: temporaryRuntimePath,
                    targetRuntimePath: targetRuntimePath,
                    cwd: cwd
                )
                let draftRuntimePath = await preserveFailedPythonDraft(
                    temporaryPath: temporaryPath,
                    fallbackData: currentData,
                    target: target
                )
                try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)
                return failedPythonWriteOutcome(
                    target: target,
                    targetRuntimePath: targetRuntimePath,
                    failedDraftRuntimePath: draftRuntimePath,
                    reason: "Python 返回路径结构校验失败，目标文件未覆盖",
                    command: semanticCommand,
                    result: semantic,
                    diagnosticOutput: diagnostic?.output
                )
            }

            let formattedData = try await LocalAlpineTerminalService.shared.readFile(path: temporaryPath)
            try await LocalAlpineTerminalService.shared.writeFile(
                data: formattedData,
                fileName: split.fileName,
                destinationPath: split.directory
            )
            try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)

            var lines = [
                "- `\(target)` (\(formattedData.count) B，Python 完整文件事务写入已通过 AST、Black 可用时格式化、二次 AST、py_compile、返回路径校验，来源：\(source.displayName))"
            ]
            lines.append(contentsOf: currentNotes.map { "  - \($0)" })
            return LocalAlpineProtectedWriteOutcome(lines: lines, writtenPath: target, hadFailure: false)
        } catch {
            try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：\(error.localizedDescription)"],
                writtenPath: nil,
                hadFailure: true
            )
        }
    }

    private func pythonASTValidationCommand(for runtimePath: String) -> String {
        """
        python3 -c "import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')); print('IEXA_AST_PARSE_SUCCESS')" \(shellSingleQuoted(runtimePath))
        """
    }

    private func pythonSemanticValidationCommand(for runtimePath: String) -> String {
        """
        python3 - \(shellSingleQuoted(runtimePath)) <<'PY'
        import ast
        import pathlib
        import sys

        path = pathlib.Path(sys.argv[1])
        tree = ast.parse(path.read_text(encoding="utf-8"))

        def block_exits(statements):
            for statement in statements:
                if statement_exits(statement):
                    return True
            return False

        def statement_exits(statement):
            if isinstance(statement, (ast.Return, ast.Raise)):
                return True
            if isinstance(statement, ast.If):
                return bool(statement.orelse) and block_exits(statement.body) and block_exits(statement.orelse)
            if isinstance(statement, ast.Try):
                if block_exits(statement.finalbody):
                    return True
                if not statement.handlers:
                    return False
                normal_path = block_exits(statement.body + statement.orelse)
                handler_paths = all(block_exits(handler.body) for handler in statement.handlers)
                return normal_path and handler_paths
            return False

        class ReturnCollector(ast.NodeVisitor):
            def __init__(self):
                self.returns = []

            def visit_FunctionDef(self, node):
                return

            visit_AsyncFunctionDef = visit_FunctionDef

            def visit_Lambda(self, node):
                return

            def visit_Return(self, node):
                self.returns.append(node)

        class FunctionCollector(ast.NodeVisitor):
            def __init__(self):
                self.functions = {}

            def visit_FunctionDef(self, node):
                self._collect(node)
                self.generic_visit(node)

            def visit_AsyncFunctionDef(self, node):
                self._collect(node)
                self.generic_visit(node)

            def _collect(self, node):
                collector = ReturnCollector()
                for statement in node.body:
                    collector.visit(statement)
                tuple_arities = {
                    len(item.value.elts)
                    for item in collector.returns
                    if isinstance(item.value, ast.Tuple)
                }
                if tuple_arities:
                    self.functions[node.name] = {
                        "line": node.lineno,
                        "arities": tuple_arities,
                        "can_fall_through": not block_exits(node.body),
                    }

        def unpack_arity(target):
            if isinstance(target, (ast.Tuple, ast.List)):
                return len(target.elts)
            return 0

        def call_name(value):
            if isinstance(value, ast.Call) and isinstance(value.func, ast.Name):
                return value.func.id
            return None

        class UnpackCollector(ast.NodeVisitor):
            def __init__(self):
                self.unpacks = {}

            def _record(self, target, value, line):
                arity = unpack_arity(target)
                name = call_name(value)
                if arity and name:
                    self.unpacks.setdefault(name, []).append((line, arity))

            def visit_Assign(self, node):
                for target in node.targets:
                    self._record(target, node.value, node.lineno)
                self.generic_visit(node)

            def visit_AnnAssign(self, node):
                if node.value is not None:
                    self._record(node.target, node.value, node.lineno)
                self.generic_visit(node)

        functions = FunctionCollector()
        functions.visit(tree)
        unpacks = UnpackCollector()
        unpacks.visit(tree)

        errors = []
        for name, info in functions.functions.items():
            if not info["can_fall_through"]:
                continue
            for line, arity in unpacks.unpacks.get(name, []):
                if arity in info["arities"]:
                    errors.append(
                        f"{path}:{line}: function `{name}` is unpacked into {arity} values "
                        f"but can fall through without returning a value; check indentation/return placement near line {info['line']}."
                    )

        if errors:
            print("IEXA_PY_SEMANTIC_GUARD_FAILED")
            for error in errors:
                print(error)
            sys.exit(3)

        print("IEXA_PY_SEMANTIC_GUARD_SUCCESS")
        PY
        """
    }

    private func pythonBlackFormatCommand(for runtimePath: String) -> String {
        """
        export PATH="$HOME/.local/bin:$PATH"
        if command -v black >/dev/null 2>&1; then
          black --quiet \(shellSingleQuoted(runtimePath))
        elif python3 -m black --version >/dev/null 2>&1; then
          python3 -m black --quiet \(shellSingleQuoted(runtimePath))
        else
          printf 'IEXA_BLACK_SKIPPED: black is not installed; continuing with ast.parse and py_compile\\n'
        fi
        """
    }

    private func pythonLineNumberDiagnostic(
        for runtimePath: String,
        targetRuntimePath: String,
        cwd: String
    ) async -> LocalAlpineCommandResult? {
        let command = """
        file=\(shellSingleQuoted(runtimePath))
        target=\(shellSingleQuoted(targetRuntimePath))
        printf '== target Python file: %s ==\\n' "$target"
        printf '== failed draft with line numbers: %s ==\\n' "$file"
        if [ -f "$file" ]; then
          nl -ba "$file" | sed -n '1,220p'
        else
          printf 'missing: %s\\n' "$file"
        fi
        """
        return await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
    }

    private func preserveFailedPythonDraft(
        temporaryPath: String,
        fallbackData: Data,
        target: String
    ) async -> String? {
        let targetName = splitFilePath(target).fileName
        let safeTargetName = targetName
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let draftName = ".iexa-failed-\(safeTargetName)-\(UUID().uuidString).py"
        let draftPath = "/.iexa_failed_writes/\(draftName)"
        do {
            let data = (try? await LocalAlpineTerminalService.shared.readFile(path: temporaryPath)) ?? fallbackData
            try await LocalAlpineTerminalService.shared.writeFile(
                data: data,
                fileName: draftName,
                destinationPath: "/.iexa_failed_writes"
            )
            return runtimePath(forSharedPath: draftPath)
        } catch {
            return nil
        }
    }

    private func failedPythonWriteOutcome(
        target: String,
        targetRuntimePath: String,
        failedDraftRuntimePath: String?,
        reason: String,
        command: String,
        result: LocalAlpineCommandResult,
        diagnosticOutput: String? = nil
    ) -> LocalAlpineProtectedWriteOutcome {
        var lines = ["- `\(target)` 写入已拒绝：\(reason)。"]
        lines.append("  - 目标 Python 文件：`\(targetRuntimePath)`")
        if let failedDraftRuntimePath {
            lines.append("  - 失败草稿已保留：`\(failedDraftRuntimePath)`")
            lines.append("  - 下一步应读取失败草稿的完整行号内容，修正后用 `write_files` / `write_file` 覆盖目标 Python 文件。")
        }
        lines.append("  - 验证命令：`\(command.trimmingCharacters(in: .whitespacesAndNewlines))`")
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            lines.append("  - 输出：\(String(output.prefix(600)))")
        }
        if let diagnostic = diagnosticOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
           !diagnostic.isEmpty {
            lines.append("  - 候选文件定位：\(String(diagnostic.prefix(1_500)))")
        }
        return LocalAlpineProtectedWriteOutcome(lines: lines, writtenPath: nil, hadFailure: true)
    }

    private func extractPythonHeredocWrites(from command: String, cwd: String) async -> LocalAlpineExtractedWriteResult? {
        let commandLines = command.components(separatedBy: .newlines)
        var remainingLines: [String] = []
        var summaryLines = ["写入文件（已自动保护 Python 缩进）"]
        var writtenPaths: [String] = []
        var hadFailure = false
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
            let prepared = Self.preparePythonForProtectedWrite(content, source: .heredoc)
            guard case .success(let preparedContent, let prepareNotes) = prepared else {
                let reason: String
                if case .failure(let message) = prepared {
                    reason = message
                } else {
                    reason = "Python 内容无法正规化"
                }
                summaryLines.append("- `\(target)` 写入已拒绝：\(reason)")
                summaryLines.append("  - 这个文件没有被覆盖。请提交完整源码；App 会先写入临时文件并用 AST/py_compile 校验，通过后才覆盖目标。")
                hadFailure = true
                continue
            }
            content = preparedContent
            guard let data = content.data(using: .utf8) else {
                summaryLines.append("- `\(target)` 写入失败：内容不是有效 UTF-8")
                hadFailure = true
                continue
            }

            let outcome = await writeValidatedPythonFile(
                data: data,
                target: target,
                split: split,
                cwd: cwd,
                source: .heredoc,
                notes: prepareNotes
            )
            summaryLines.append(contentsOf: outcome.lines)
            if outcome.writtenPath != nil {
                writtenPaths.append(target)
            }
            if outcome.hadFailure {
                hadFailure = true
            }
        }

        guard extractedCount > 0 else { return nil }
        let remainingCommand = writtenPaths.count == extractedCount
            ? remainingLines.joined(separator: "\n")
            : ""
        return LocalAlpineExtractedWriteResult(
            summary: summaryLines.joined(separator: "\n"),
            writtenPaths: writtenPaths,
            remainingCommand: remainingCommand,
            hadFailure: hadFailure
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

    private func unsafeCodeFileWriteWarning(for command: String) -> String? {
        guard Self.commandWritesCodeThroughShellText(command) else { return nil }
        return """
        Unsafe code file write blocked.

        This command writes a code or indentation-sensitive text file through shell text redirection/heredoc (`cat`, `tee`, `printf`, `echo`, or `python - <<`). In this chat UI that path can corrupt leading spaces, tabs, quotes, or multi-line blocks.

        Use `iexa_alpine` JSON `write_files` / `write_file` with `code_lines`, `content_lines`, or `content_base64`. For Python files the app additionally writes transactionally, validates with `ast.parse`, formats with Black when available, validates again, runs `python3 -m py_compile`, and checks high-risk return paths before overwriting the target.
        """
    }

    private nonisolated static func commandWritesCodeThroughShellText(_ command: String) -> Bool {
        let normalized = command.lowercased()
        guard commandTargetsCodeOrIndentationSensitiveFile(normalized) else { return false }

        let patterns = [
            #"(?is)\bcat\s+>+"#,
            #"(?is)\bcat\s+<<[\s\S]{0,240}>+"#,
            #"(?is)\btee\s+(?:-a\s+)?"#,
            #"(?is)\b(?:printf|echo)\b[\s\S]{0,400}>+"#
        ]

        return patterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private nonisolated static func commandTargetsCodeOrIndentationSensitiveFile(_ normalizedCommand: String) -> Bool {
        let filePatterns = [
            #"\.(py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonl|yaml|yml|toml|xml|md|dockerfile|makefile)(?:['"\s;|&>]|$)"#,
            #"(^|[/\s])makefile(?:['"\s;|&>]|$)"#,
            #"(^|[/\s])dockerfile(?:['"\s;|&>]|$)"#
        ]
        return filePatterns.contains { pattern in
            normalizedCommand.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private nonisolated static func preparePythonForProtectedWrite(
        _ content: String,
        source: LocalAlpineAgentFileSource
    ) -> PythonWritePreparation {
        switch LocalAlpinePythonWriteGuard.prepare(content, source: source.guardSource) {
        case .success(let content, let notes):
            return .success(content: content, notes: notes)
        case .failure(let message):
            return .failure(message)
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
            let matches = regex.matches(in: combined, range: range)
            for match in matches where match.numberOfRanges >= 2 {
                let candidate = nsCombined.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { continue }
                let path = normalizedRuntimePythonPath(candidate, cwd: cwd)
                if isUserPythonRuntimePath(path) {
                    return path
                }
            }
        }

        return nil
    }

    private nonisolated static func normalizedRuntimePythonPath(_ path: String, cwd: String) -> String {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !cleaned.isEmpty else { return cleaned }
        if cleaned.hasPrefix("/mnt/iexa/") {
            return cleaned
        }
        if cleaned.hasPrefix("/usr/lib/python") || cleaned.hasPrefix("/usr/local/lib/python") {
            return cleaned
        }
        if cleaned.hasPrefix("/") {
            return "/mnt/iexa\(cleaned)"
        }
        let normalizedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let base = normalizedCWD.isEmpty ? "/mnt/iexa" : normalizedCWD
        return base.hasSuffix("/") ? base + cleaned : base + "/" + cleaned
    }

    private nonisolated static func isUserPythonRuntimePath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard normalized.lowercased().hasSuffix(".py") else { return false }
        if normalized.hasPrefix("/usr/lib/python") || normalized.hasPrefix("/usr/local/lib/python") {
            return false
        }
        if normalized.hasPrefix("/mnt/iexa/usr/lib/python")
            || normalized.hasPrefix("/mnt/iexa/usr/local/lib/python") {
            return false
        }
        if normalized.contains("/site-packages/") || normalized.contains("/dist-packages/") {
            return false
        }
        if normalized.contains("/.iexa-write-") || normalized.hasPrefix("/mnt/iexa/.iexa_failed_writes/") {
            return false
        }
        return normalized.hasPrefix("/mnt/iexa/")
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

private enum LocalAlpineAgentFileSource: Equatable {
    case content
    case codeLines
    case contentLines
    case contentBase64
    case heredoc

    var displayName: String {
        switch self {
        case .content: return "content"
        case .codeLines: return "code_lines"
        case .contentLines: return "content_lines"
        case .contentBase64: return "content_base64"
        case .heredoc: return "heredoc"
        }
    }

    var guardSource: LocalAlpinePythonWriteGuard.Source {
        switch self {
        case .content: return .content
        case .codeLines: return .codeLines
        case .contentLines: return .contentLines
        case .contentBase64: return .contentBase64
        case .heredoc: return .heredoc
        }
    }
}

private enum PythonWritePreparation {
    case success(content: String, notes: [String])
    case failure(String)
}

private struct LocalAlpineProtectedWriteOutcome {
    let lines: [String]
    let writtenPath: String?
    let hadFailure: Bool
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
    let hadFailure: Bool
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
