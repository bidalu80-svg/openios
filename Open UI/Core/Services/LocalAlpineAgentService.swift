import Foundation

struct LocalAlpineAgentResult: Sendable {
    let didExecute: Bool
    let summary: String
    let interactiveRequest: LocalAlpineInteractiveRequest?
    let commandResults: [LocalAlpineAgentCommandResult]
    let writtenFiles: [LocalAlpineWrittenFile]
    let executedCommandCount: Int
    let editedFileCount: Int
    let hadFailure: Bool

    init(
        didExecute: Bool,
        summary: String,
        interactiveRequest: LocalAlpineInteractiveRequest?,
        commandResults: [LocalAlpineAgentCommandResult] = [],
        writtenFiles: [LocalAlpineWrittenFile] = [],
        executedCommandCount: Int = 0,
        editedFileCount: Int = 0,
        hadFailure: Bool = false
    ) {
        self.didExecute = didExecute
        self.summary = summary
        self.interactiveRequest = interactiveRequest
        self.commandResults = commandResults
        self.writtenFiles = writtenFiles
        self.executedCommandCount = executedCommandCount
        self.editedFileCount = editedFileCount
        self.hadFailure = hadFailure
    }
}

struct LocalAlpineWrittenFile: Codable, Hashable, Sendable {
    let path: String
    let source: String
    let byteCount: Int
    let lineCountValue: Int
    let previewTailLines: [String]

    init(
        path: String,
        content: String,
        source: String,
        byteCount: Int,
        lineCountValue: Int? = nil
    ) {
        self.path = path
        self.source = source
        self.byteCount = byteCount
        self.lineCountValue = lineCountValue ?? Self.countLines(in: content)
        self.previewTailLines = Self.tailLines(in: content, limit: 120)
    }

    private enum CodingKeys: String, CodingKey {
        case path, content, source, byteCount, lineCountValue, previewTailLines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        let legacyContent = (try? container.decode(String.self, forKey: .content)) ?? ""
        source = (try? container.decode(String.self, forKey: .source)) ?? "unknown"
        byteCount = (try? container.decode(Int.self, forKey: .byteCount))
            ?? (legacyContent.data(using: .utf8)?.count ?? 0)
        lineCountValue = (try? container.decode(Int.self, forKey: .lineCountValue))
            ?? Self.countLines(in: legacyContent)
        previewTailLines = (try? container.decode([String].self, forKey: .previewTailLines))
            ?? Self.tailLines(in: legacyContent, limit: 120)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(source, forKey: .source)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(lineCountValue, forKey: .lineCountValue)
        try container.encode(previewTailLines, forKey: .previewTailLines)
    }

    var fileName: String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? path
    }

    var language: String {
        LocalCodeWriteGuard.language(forPath: fileName)
    }

    var lineCount: Int {
        lineCountValue
    }

    private static func countLines(in content: String) -> Int {
        if content.isEmpty { return 0 }
        var count = 0
        content.enumerateLines { _, _ in
            count += 1
        }
        return count
    }

    func previewLines(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        if previewTailLines.count <= limit {
            return previewTailLines
        }
        return Array(previewTailLines.suffix(limit))
    }

    private static func tailLines(in content: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var buffer: [String] = []
        buffer.reserveCapacity(limit)
        var writeIndex = 0

        content.enumerateLines { line, _ in
            if buffer.count < limit {
                buffer.append(line)
            } else {
                buffer[writeIndex] = line
                writeIndex = (writeIndex + 1) % limit
            }
        }

        guard buffer.count == limit, writeIndex != 0 else {
            return buffer
        }

        var ordered: [String] = []
        ordered.reserveCapacity(limit)
        ordered.append(contentsOf: buffer[writeIndex...])
        if writeIndex > 0 {
            ordered.append(contentsOf: buffer[..<writeIndex])
        }
        return ordered
    }

    static func metadataString(for files: [LocalAlpineWrittenFile]) -> String? {
        guard !files.isEmpty else { return nil }
        let limitedFiles = files.prefix(8).map { file in
            LocalAlpineWrittenFile(
                path: file.path,
                previewLines: file.previewTailLines,
                source: file.source,
                byteCount: file.byteCount,
                lineCountValue: file.lineCount
            )
        }
        guard let data = try? JSONEncoder().encode(Array(limitedFiles)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeMetadata(_ value: String?) -> [LocalAlpineWrittenFile] {
        guard let value,
              let data = value.data(using: .utf8),
              let files = try? JSONDecoder().decode([LocalAlpineWrittenFile].self, from: data) else {
            return []
        }
        return files
    }

    private init(
        path: String,
        previewLines: [String],
        source: String,
        byteCount: Int,
        lineCountValue: Int
    ) {
        self.path = path
        self.source = source
        self.byteCount = byteCount
        self.lineCountValue = lineCountValue
        self.previewTailLines = Array(previewLines.suffix(120))
    }
}

struct LocalAlpineAgentCommandResult: Codable, Hashable, Sendable {
    let command: String
    let cwd: String
    let exitCode: Int?
    let outputPreview: String

    var failed: Bool {
        guard let exitCode else { return true }
        return exitCode != 0
    }

    static func metadataString(for results: [LocalAlpineAgentCommandResult]) -> String? {
        let limitedResults = results.prefix(12).map { result in
            LocalAlpineAgentCommandResult(
                command: result.command,
                cwd: result.cwd,
                exitCode: result.exitCode,
                outputPreview: String(result.outputPreview.prefix(8_000))
            )
        }
        guard !limitedResults.isEmpty,
              let data = try? JSONEncoder().encode(Array(limitedResults)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func decodeMetadata(_ value: String?) -> [LocalAlpineAgentCommandResult] {
        guard let value,
              let data = value.data(using: .utf8),
              let results = try? JSONDecoder().decode([LocalAlpineAgentCommandResult].self, from: data) else {
            return []
        }
        return results
    }
}

actor LocalAlpineAgentService {
    static let shared = LocalAlpineAgentService()

    private let maxCommandsPerResponse = 12
    private let maxOutputCharactersPerCommand = 20_000
    private let defaultCWD = "/mnt/iexa"

    private init() {}

    func runPythonCodeBlock(
        _ code: String,
        fileName: String,
        cwd: String = "/mnt/iexa",
        arguments: [String] = [],
        stdinInput: String? = nil
    ) async -> LocalAlpineAgentResult {
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "codeblock.py"
            : fileName
        let file = LocalAlpineAgentFile(
            path: normalizedFileName,
            content: code,
            source: .codeBlock
        )
        let writeResult = await writeFiles([file], cwd: cwd)
        var lines = [
            "Local Alpine 执行结果",
            "环境：内置 Alpine Linux，工作目录默认 `/mnt/iexa`",
            writeResult.summary
        ]
        var commandResults: [LocalAlpineAgentCommandResult] = []
        let writtenFiles = writeResult.writtenFiles
        if writeResult.hadFailure {
            let result = LocalAlpineCommandResult(
                command: "write_files",
                output: writeResult.summary,
                exitCode: 125,
                interactiveRequest: nil
            )
            commandResults.append(Self.commandResult(command: "write_files", cwd: cwd, result: result))
            return LocalAlpineAgentResult(
                didExecute: true,
                summary: lines.joined(separator: "\n\n"),
                interactiveRequest: nil,
                commandResults: commandResults,
                writtenFiles: writtenFiles,
                executedCommandCount: 0,
                editedFileCount: writeResult.writtenPaths.isEmpty ? 0 : 1,
                hadFailure: true
            )
        }

        let runtimeFile = runtimePath(forSharedPath: resolvedFilePath(normalizedFileName, cwd: cwd))
        let argumentString = arguments
            .map { shellSingleQuoted($0) }
            .joined(separator: " ")
        let command = [
            "python3 -m py_compile \(shellSingleQuoted(runtimeFile))",
            "python3 \(shellSingleQuoted(runtimeFile))\(argumentString.isEmpty ? "" : " \(argumentString)")"
        ].joined(separator: " && ")
        let result = await LocalAlpineTerminalService.shared.execute(
            command: command,
            cwd: cwd,
            stdinInput: stdinInput
        )
        lines.append(format(command: command, cwd: cwd, result: result))
        commandResults.append(Self.commandResult(command: command, cwd: cwd, result: result))

        if let interactiveRequest = result.interactiveRequest {
            return LocalAlpineAgentResult(
                didExecute: true,
                summary: lines.joined(separator: "\n\n"),
                interactiveRequest: interactiveRequest,
                commandResults: commandResults,
                writtenFiles: writtenFiles,
                executedCommandCount: Self.actualCommandCount(commandResults),
                editedFileCount: writeResult.writtenPaths.isEmpty ? 0 : 1,
                hadFailure: true
            )
        }

        let cleanupCommand = "rm -f \(shellSingleQuoted(runtimeFile))"
        let cleanupResult = await LocalAlpineTerminalService.shared.execute(command: cleanupCommand, cwd: cwd)
        if cleanupResult.exitCode != 0 {
            lines.append(format(command: cleanupCommand, cwd: cwd, result: cleanupResult))
            commandResults.append(Self.commandResult(command: cleanupCommand, cwd: cwd, result: cleanupResult))
        }

        return LocalAlpineAgentResult(
            didExecute: true,
            summary: lines.joined(separator: "\n\n"),
            interactiveRequest: nil,
            commandResults: commandResults,
            writtenFiles: writtenFiles,
            executedCommandCount: Self.actualCommandCount(commandResults),
            editedFileCount: writeResult.writtenPaths.isEmpty ? 0 : 1,
            hadFailure: commandResults.contains { $0.failed }
        )
    }

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
        var writtenFiles: [LocalAlpineWrittenFile] = []
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
                writtenFiles.append(contentsOf: writeResult.writtenFiles)
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
            }

            if let shellCommand = command.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               !shellCommand.isEmpty,
               shouldRunShellCommand {
                let commandToExecute = shellCommand

                guard !commandToExecute.isEmpty else {
                    if !stepLines.isEmpty {
                        lines.append(stepLines.joined(separator: "\n\n"))
                    }
                    continue
                }

                if let warning = unsafeCodeFileWriteWarning(for: commandToExecute) {
                    let result = LocalAlpineCommandResult(
                        command: commandToExecute,
                        output: warning,
                        exitCode: 126,
                        interactiveRequest: nil
                    )
                    stepLines.append(format(command: commandToExecute, cwd: effectiveCWD, result: result))
                    commandResults.append(Self.commandResult(
                        command: commandToExecute,
                        cwd: effectiveCWD,
                        result: result
                    ))
                    stopRemainingCommands = true
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
                            writtenFiles: writtenFiles,
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
            writtenFiles: writtenFiles,
            executedCommandCount: Self.actualCommandCount(commandResults),
            editedFileCount: editedFilePaths.count,
            hadFailure: commandResults.contains { $0.failed }
        )
    }

    private nonisolated static func actualCommandCount(_ results: [LocalAlpineAgentCommandResult]) -> Int {
        results.filter { result in
            let command = result.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return command != "write_files"
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
            outputPreview: String(result.output.prefix(8_000))
        )
    }

    private func extractInstructionBlocks(from content: String) -> [String] {
        Self.instructionBlocks(from: content)
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
        guard Self.looksLikeShellBlock(shell) else { throw LocalAlpineAgentError.noCommands }
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

        if let nested = dict["iexa_alpine"] ?? dict["local_alpine_exec"] ?? dict["commands"] {
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
        if dict["iexa_rejected_python_plain_content"] as? Bool == true,
           let path = (dict["path"] as? String)
            ?? (dict["file_path"] as? String)
            ?? (dict["file"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["filename"] as? String)
            ?? (dict["write_file"] as? String)
            ?? (dict["target"] as? String) {
            return LocalAlpineAgentFile(
                path: path,
                content: "",
                source: .rejectedPythonPlainContent
            )
        }
        guard let path = (dict["path"] as? String)
            ?? (dict["file_path"] as? String)
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
        var lines = ["写入文件（结构化写入）"]
        var writtenPaths: [String] = []
        var writtenFiles: [LocalAlpineWrittenFile] = []
        var hadFailure = false
        for file in files.prefix(maxCommandsPerResponse) {
            let outcome = await writeProtectedFile(file, cwd: cwd)
            lines.append(contentsOf: outcome.lines)
            if let writtenPath = outcome.writtenPath {
                writtenPaths.append(writtenPath)
            }
            if let writtenFile = outcome.writtenFile {
                writtenFiles.append(writtenFile)
            }
            if outcome.hadFailure {
                hadFailure = true
            }
        }
        let skipped = max(0, files.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余文件，避免一次写入过多。")
        }
        return LocalAlpineWriteResult(
            summary: lines.joined(separator: "\n"),
            writtenPaths: writtenPaths,
            writtenFiles: writtenFiles,
            hadFailure: hadFailure
        )
    }

    private func writeProtectedFile(_ file: LocalAlpineAgentFile, cwd: String) async -> LocalAlpineProtectedWriteOutcome {
        let target = resolvedFilePath(file.path, cwd: cwd)
        if Self.isPythonTarget(target), !file.source.isAllowedPythonWriteSource {
            return LocalAlpineProtectedWriteOutcome(
                lines: [
                    "- `\(target)` Python 写入已拒绝：`.py` 文件不能使用 `\(file.source.displayName)` 来源写入。请重新输出完整 `iexa_alpine` JSON，并用 `write_files.code_lines` 或 `content_base64` 携带文件内容。目标文件未被覆盖。"
                ],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }
        if Self.isCodeTarget(target), !file.source.isAllowedCodeWriteSource {
            return LocalAlpineProtectedWriteOutcome(
                lines: [
                    "- `\(target)` 代码文件写入已拒绝：不能使用 `\(file.source.displayName)` 来源写入代码文件。请改用 `write_files.code_lines`、`content_lines` 或 `content_base64`，目标文件未被覆盖。"
                ],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }
        let content = file.content
        let language = LocalCodeWriteGuard.language(forPath: target)
        let normalizedContent = Self.isCodeTarget(target)
            ? CodeSourceFormatter.formattedForWrite(content, language: language)
            : content
        guard let data = normalizedContent.data(using: .utf8) else {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：内容不是有效 UTF-8"],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }
        if Self.isPythonTarget(target) {
            return await writeValidatedPythonFile(
                data: data,
                target: target,
                cwd: cwd,
                source: file.source,
                initialNotes: writeNotes(
                    original: content,
                    normalized: normalizedContent,
                    target: target,
                    language: language
                )
            )
        }

        let writeOutcome = await writeFileBytes(
            data: data,
            content: normalizedContent,
            target: target,
            source: file.source,
            notes: writeNotes(
                original: content,
                normalized: normalizedContent,
                target: target,
                language: language
            )
        )
        guard !writeOutcome.hadFailure else { return writeOutcome }
        return await formatWrittenCodeFileIfPossible(
            writeOutcome,
            target: target,
            cwd: cwd,
            source: file.source,
            language: language
        )
    }

    private nonisolated static func isPythonTarget(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".py") || lowercased.hasSuffix(".pyw")
    }

    private nonisolated static func isCodeTarget(_ path: String) -> Bool {
        let language = LocalCodeWriteGuard.language(forPath: path)
        return language != "text" && language != "markdown"
    }

    private nonisolated func writeNotes(
        original: String,
        normalized: String,
        target: String,
        language: String
    ) -> [String] {
        guard Self.isCodeTarget(target) else {
            return ["按结构化写入内容原样落盘。"]
        }
        if original == normalized {
            return ["代码文件按结构化 UTF-8 字节写入；源码缩进已保持原样。"]
        }
        return [
            "代码文件写入前已按 \(language) 走 APP 侧源码规范化入口。",
            "已统一换行、去掉代码块外层共同缩进；内部源码缩进保持可运行结构。"
        ]
    }

    private func writeFileBytes(
        data: Data,
        content: String,
        target: String,
        source: LocalAlpineAgentFileSource,
        notes: [String] = []
    ) async -> LocalAlpineProtectedWriteOutcome {
        let split = splitFilePath(target)
        do {
            try await LocalAlpineTerminalService.shared.writeFile(
                data: data,
                fileName: split.fileName,
                destinationPath: split.directory
            )
            let writtenData = try await LocalAlpineTerminalService.shared.readFile(path: target)
            guard writtenData == data else {
                return LocalAlpineProtectedWriteOutcome(
                    lines: [
                        "- `\(target)` 写入失败：写入后读回字节不一致（expected \(data.count) B, got \(writtenData.count) B），已阻止继续执行。"
                    ],
                    writtenPath: nil,
                    writtenFile: nil,
                    hadFailure: true
                )
            }
            var lines = ["- `\(target)` (\(data.count) B，已写入，来源：\(source.displayName))"]
            lines.append(contentsOf: notes.map { "  - \($0)" })
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: target,
                writtenFile: LocalAlpineWrittenFile(
                    path: target,
                    content: content,
                    source: source.displayName,
                    byteCount: data.count
                ),
                hadFailure: false
            )
        } catch {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：\(error.localizedDescription)"],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }
    }

    private func formatWrittenCodeFileIfPossible(
        _ outcome: LocalAlpineProtectedWriteOutcome,
        target: String,
        cwd: String,
        source: LocalAlpineAgentFileSource,
        language: String
    ) async -> LocalAlpineProtectedWriteOutcome {
        guard !outcome.hadFailure,
              let command = formatterCommand(for: target, language: language) else {
            return outcome
        }

        let runtimeFile = runtimePath(forSharedPath: target)
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
        if result.exitCode != 0 {
            var lines = outcome.lines
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.contains("IEXA_FORMATTER_NOT_FOUND") {
                lines.append("  - 未找到 \(language) formatter，已保持结构化写入后的源码缩进。")
                return LocalAlpineProtectedWriteOutcome(
                    lines: lines,
                    writtenPath: outcome.writtenPath,
                    writtenFile: outcome.writtenFile,
                    hadFailure: false
                )
            }
            lines.append("  - \(language) formatter 运行失败，已保留写入内容：\(String(output.prefix(600)))")
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: outcome.writtenPath,
                writtenFile: outcome.writtenFile,
                hadFailure: false
            )
        }

        do {
            let formattedData = try await LocalAlpineTerminalService.shared.readFile(path: target)
            guard let formattedContent = String(data: formattedData, encoding: .utf8) else {
                return outcome
            }
            var lines = outcome.lines
            let formatterChangedBytes = outcome.writtenFile
                .map { formattedData.count != $0.byteCount } ?? true
            if formatterChangedBytes {
                lines.append("  - 已用 \(language) formatter 格式化：\(splitFilePath(runtimeFile).fileName)。")
            } else {
                lines.append("  - \(language) formatter 已检查，源码格式无需调整。")
            }
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: target,
                writtenFile: LocalAlpineWrittenFile(
                    path: target,
                    content: formattedContent,
                    source: source.displayName,
                    byteCount: formattedData.count
                ),
                hadFailure: false
            )
        } catch {
            var lines = outcome.lines
            lines.append("  - formatter 后读回失败，已保留写入状态：\(error.localizedDescription)")
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: outcome.writtenPath,
                writtenFile: outcome.writtenFile,
                hadFailure: false
            )
        }
    }

    private func formatterCommand(for target: String, language: String) -> String? {
        let file = shellSingleQuoted(runtimePath(forSharedPath: target))
        switch language.lowercased() {
        case "python":
            return """
            if command -v black >/dev/null 2>&1; then black --quiet \(file); else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "javascript", "typescript", "tsx", "jsx", "json", "html", "css", "scss", "less", "yaml", "toml", "markdown":
            return """
            if command -v prettier >/dev/null 2>&1; then prettier --write \(file) >/dev/null; else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "swift":
            return """
            if command -v swift-format >/dev/null 2>&1; then swift-format --in-place \(file); elif command -v swiftformat >/dev/null 2>&1; then swiftformat \(file); else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "go":
            return """
            if command -v gofmt >/dev/null 2>&1; then gofmt -w \(file); else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "rust":
            return """
            if command -v rustfmt >/dev/null 2>&1; then rustfmt \(file); else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "c", "cpp", "java", "csharp":
            return """
            if command -v clang-format >/dev/null 2>&1; then clang-format -i \(file); else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "bash":
            return """
            if command -v shfmt >/dev/null 2>&1; then shfmt -w \(file); else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "ruby":
            return """
            if command -v rufo >/dev/null 2>&1; then rufo \(file) >/dev/null; elif command -v rubocop >/dev/null 2>&1; then rubocop -A \(file) >/dev/null; else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        case "php":
            return """
            if command -v php-cs-fixer >/dev/null 2>&1; then php-cs-fixer fix \(file) --quiet; else echo IEXA_FORMATTER_NOT_FOUND; exit 127; fi
            """
        default:
            return nil
        }
    }

    private func writeValidatedPythonFile(
        data: Data,
        target: String,
        cwd: String,
        source: LocalAlpineAgentFileSource,
        initialNotes: [String] = []
    ) async -> LocalAlpineProtectedWriteOutcome {
        guard let content = String(data: data, encoding: .utf8) else {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：内容不是有效 UTF-8"],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }

        let validationResult = await validatePythonContent(content, cwd: cwd)
        guard validationResult.exitCode == 0 else {
            if let normalizedContent = CodeSourceFormatter.normalizedForWrite(content, language: "python"),
               normalizedContent != content,
               let normalizedData = normalizedContent.data(using: .utf8) {
                let normalizedValidation = await validatePythonContent(normalizedContent, cwd: cwd)
                if normalizedValidation.exitCode == 0 {
                    let normalizedWrite = await writeFileBytes(
                        data: normalizedData,
                        content: normalizedContent,
                        target: target,
                        source: source,
                        notes: initialNotes + [
                            "Python 原始内容语法/缩进校验失败；APP 已在写入前进行本地源码缩进规范化。",
                            "规范化内容已重新通过 AST 语法校验并按 UTF-8 字节写入。"
                        ]
                    )
                    guard !normalizedWrite.hadFailure else { return normalizedWrite }

                    let formattedWrite = await formatWrittenCodeFileIfPossible(
                        normalizedWrite,
                        target: target,
                        cwd: cwd,
                        source: source,
                        language: "python"
                    )
                    guard !formattedWrite.hadFailure else { return formattedWrite }

                    var normalizedLines = formattedWrite.lines
                    normalizedLines.append("  - Python 语法校验通过。")
                    return LocalAlpineProtectedWriteOutcome(
                        lines: normalizedLines,
                        writtenPath: formattedWrite.writtenPath,
                        writtenFile: formattedWrite.writtenFile,
                        hadFailure: false
                    )
                }
            }

            var lines = [
                "- `\(target)` Python 写入已拒绝：原始内容语法/缩进校验未通过，目标文件未被覆盖。"
            ]
            if let draftPath = await writeFailedPythonDraft(
                data: data,
                target: target
            ) {
                lines.append("  - 已把失败草稿保存到 `\(draftPath)`，用于下一轮诊断；原目标文件保持不变。")
            }
            let output = validationResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                lines.append("  - Python 语法/缩进校验失败：\(String(output.prefix(1_000)))")
            }
            let errorLine = Self.pythonValidationLineNumber(from: output)
            let snippet = Self.numberedPythonSnippet(content, around: errorLine, radius: 5)
            if !snippet.isEmpty {
                lines.append("  - 失败草稿片段：\n\(snippet)")
            }
            lines.append("  - NEXT_ACTION_REQUIRED: rewrite the complete Python file through structured write_files/code_lines or content_base64, then verify again.")
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }

        let directWrite = await writeFileBytes(
            data: data,
            content: content,
            target: target,
            source: source,
            notes: initialNotes.isEmpty
                ? ["Python 文件按源码内容通过 AST 语法校验后写入。"]
                : initialNotes + ["Python 文件通过 AST 语法校验后写入。"]
        )
        guard !directWrite.hadFailure else { return directWrite }

        let formattedWrite = await formatWrittenCodeFileIfPossible(
            directWrite,
            target: target,
            cwd: cwd,
            source: source,
            language: "python"
        )
        guard !formattedWrite.hadFailure else { return formattedWrite }

        var lines = formattedWrite.lines
        lines.append("  - Python 语法校验通过。")

        return LocalAlpineProtectedWriteOutcome(
            lines: lines,
            writtenPath: formattedWrite.writtenPath,
            writtenFile: formattedWrite.writtenFile,
            hadFailure: false
        )
    }

    private nonisolated static func pythonValidationLineNumber(from output: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"line\s+(\d+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsOutput = output as NSString
        let range = NSRange(location: 0, length: nsOutput.length)
        let matches = regex.matches(in: output, range: range)
        guard let match = matches.last, match.numberOfRanges >= 2 else { return nil }
        return Int(nsOutput.substring(with: match.range(at: 1)))
    }

    private nonisolated static func numberedPythonSnippet(_ content: String, around lineNumber: Int?, radius: Int) -> String {
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }
        let center = max(1, min(lineNumber ?? 1, lines.count))
        let start = max(1, center - radius)
        let end = min(lines.count, center + radius)
        return (start...end)
            .map { index in
                let marker = (lineNumber.map { $0 == index } ?? false) ? ">" : " "
                return "    \(marker) \(index): \(lines[index - 1])"
            }
            .joined(separator: "\n")
    }

    private func validatePythonContent(_ content: String, cwd: String) async -> LocalAlpineCommandResult {
        guard let data = content.data(using: .utf8) else {
            return LocalAlpineCommandResult(
                command: "write_files",
                output: "Python validation failed: content is not valid UTF-8",
                exitCode: 125,
                interactiveRequest: nil
            )
        }

        let temporaryPath = "/.iexa-write-\(UUID().uuidString).py"
        let split = splitFilePath(temporaryPath)
        do {
            try await LocalAlpineTerminalService.shared.writeFile(
                data: data,
                fileName: split.fileName,
                destinationPath: split.directory
            )
        } catch {
            return LocalAlpineCommandResult(
                command: "write_files",
                output: "Python validation temp write failed: \(error.localizedDescription)",
                exitCode: 125,
                interactiveRequest: nil
            )
        }

        let command = pythonASTValidationCommand(for: runtimePath(forSharedPath: temporaryPath))
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
        try? await LocalAlpineTerminalService.shared.deleteItem(path: temporaryPath)
        return result
    }

    private func writeFailedPythonDraft(data: Data, target: String) async -> String? {
        let targetName = splitFilePath(target).fileName
        let baseName = targetName.isEmpty ? "script.py" : targetName
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let draftPath = "/.iexa_failed_writes/\(baseName)-\(suffix).py"
        let split = splitFilePath(draftPath)
        do {
            try await LocalAlpineTerminalService.shared.writeFile(
                data: data,
                fileName: split.fileName,
                destinationPath: split.directory
            )
            return draftPath
        } catch {
            return nil
        }
    }

    private func pythonASTValidationCommand(for runtimePath: String) -> String {
        """
        python3 -c "import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')); print('IEXA_AST_PARSE_SUCCESS')" \(shellSingleQuoted(runtimePath))
        """
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

        Code files are indentation/escaping-sensitive. Do not write source files through shell text redirection, heredocs, `echo`, `printf`, `cat`, `tee`, or inline writer scripts.
        Re-send the complete file through structured `iexa_alpine` JSON `write_files` using `code_lines`, `content_lines`, or `content_base64`, then run a bounded verification command before executing it.
        """
    }

    private nonisolated static func commandWritesCodeThroughShellText(_ command: String) -> Bool {
        let codeFileTarget = #"(?:['"]?)[^'"\s;|&>]*\.(?:py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonc|yaml|yml|toml|xml)(?:['"]?)"#
        let redirectionWritePatterns = [
            #"(?is)\b(?:cat|printf|echo)\b[\s\S]{0,800}(?:^|[^0-9])(?:>>?|1>)\s*"# + codeFileTarget,
            #"(?is)\bcat\b\s+<<-?\s*['"]?[A-Za-z0-9_.-]+['"]?[\s\S]{0,1200}(?:^|[^0-9])(?:>>?|1>)\s*"# + codeFileTarget,
            #"(?is)(?:^|[;&|]\s*)tee\s+(?:-[A-Za-z]+\s+)*"# + codeFileTarget
        ]
        if redirectionWritePatterns.contains(where: {
            command.range(of: $0, options: .regularExpression) != nil
        }) {
            return true
        }

        let quotedCodeFile = #"['"][^'"]*\.(?:py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonc|yaml|yml|toml|xml)['"]"#
        let pythonHeredocWritePatterns = [
            #"(?is)\bpython3?\b[\s\S]{0,120}<<[\s\S]{0,2400}\bopen\s*\(\s*"# + quotedCodeFile + #"[\s\S]{0,160}['"][wax]\+?['"]"#,
            #"(?is)\bpython3?\b[\s\S]{0,120}<<[\s\S]{0,2400}\b(?:Path\s*\(\s*)"# + quotedCodeFile + #"[\s\S]{0,240}\.(?:write_text|write_bytes)\s*\("#
        ]

        return pythonHeredocWritePatterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private nonisolated static func looksLikeShellBlock(_ block: String) -> Bool {
        let lines = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            if line.hasPrefix("#") || line.hasPrefix("#!") { return true }
            if line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*$"#, options: .regularExpression) != nil {
                return true
            }
            if line.range(of: #"^(if|then|else|elif|fi|for|while|do|done|case|esac|function|\{|\}|set|export|trap|exit|return|break|continue)\b"#, options: .regularExpression) != nil {
                return true
            }
            if line.range(of: #"[;&|`$<>]"#, options: .regularExpression) != nil {
                return true
            }
            let command = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            return knownShellCommands.contains(command)
        }
    }

    private static let knownShellCommands: Set<String> = [
        "apk", "ash", "awk", "bash", "bunzip2", "busybox", "bzcat", "bzip2", "cat", "cd",
        "chmod", "chown", "cmake", "cp", "curl", "date", "df", "dirname", "du", "echo",
        "env", "find", "free", "g++", "gcc", "git", "grep", "gunzip", "gzip", "head",
        "id", "install", "ln", "ls", "lua", "make", "mkdir", "mv", "nc", "node", "npm",
        "npx", "patch", "perl", "pip", "pip3", "printf", "ps", "pwd", "python", "python3",
        "rm", "rmdir", "sed", "sh", "sleep", "sort", "tail", "tar", "tee", "test", "top",
        "touch", "tr", "uname", "uniq", "unzip", "vi", "vim", "wget", "which", "whoami",
        "xargs", "xz", "zip"
    ]

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
                    || info.contains("local_alpine_exec")
                    || (info.trimmingCharacters(in: .whitespacesAndNewlines) == "json"
                        && (body.contains("\"iexa_alpine\"") || body.contains("\"local_alpine_exec\""))) {
                    removalRanges.append(match.range)
                }
            }
        }

        if let tagRegex = try? NSRegularExpression(pattern: #"<iexa_alpine>[\s\S]*?</iexa_alpine>"#, options: [.caseInsensitive]) {
            removalRanges.append(contentsOf: tagRegex.matches(in: content, range: fullRange).map(\.range))
        }
        if let tagRegex = try? NSRegularExpression(pattern: #"<local_alpine_exec>[\s\S]*?</local_alpine_exec>"#, options: [.caseInsensitive]) {
            removalRanges.append(contentsOf: tagRegex.matches(in: content, range: fullRange).map(\.range))
        }
        removalRanges.append(contentsOf: pseudoToolCallRanges(in: content, includeIncomplete: true))

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
        for range in mergedRanges(removalRanges).sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: "")
        }

        let cleaned = (mutable as String)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    nonisolated static func instructionBlocks(from content: String) -> [String] {
        var blocks: [String] = []
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        if let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#, options: [.caseInsensitive]) {
            let matches = regex.matches(in: content, range: fullRange)
            for match in matches where match.numberOfRanges >= 3 {
                let info = nsContent.substring(with: match.range(at: 1)).lowercased()
                let body = nsContent.substring(with: match.range(at: 2)).trimmingCharacters(in: .newlines)
                if info.contains("iexa_alpine")
                    || info.contains("local_alpine_exec")
                    || (info.trimmingCharacters(in: .whitespacesAndNewlines) == "json"
                        && (body.contains("\"iexa_alpine\"") || body.contains("\"local_alpine_exec\""))) {
                    blocks.append(body)
                }
            }
        }

        if let tagRegex = try? NSRegularExpression(pattern: #"<iexa_alpine>([\s\S]*?)</iexa_alpine>"#, options: [.caseInsensitive]) {
            let matches = tagRegex.matches(in: content, range: fullRange)
            for match in matches where match.numberOfRanges >= 2 {
                blocks.append(nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .newlines))
            }
        }
        if let tagRegex = try? NSRegularExpression(pattern: #"<local_alpine_exec>([\s\S]*?)</local_alpine_exec>"#, options: [.caseInsensitive]) {
            let matches = tagRegex.matches(in: content, range: fullRange)
            for match in matches where match.numberOfRanges >= 2 {
                blocks.append(nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .newlines))
            }
        }

        for range in pseudoToolCallPayloadRanges(in: content) {
            blocks.append(nsContent.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return blocks
    }

    nonisolated private static func pseudoToolCallRanges(in content: String, includeIncomplete: Bool) -> [NSRange] {
        pseudoToolCallRangesWithPayload(in: content, includeIncomplete: includeIncomplete).map(\.full)
    }

    nonisolated private static func pseudoToolCallPayloadRanges(in content: String) -> [NSRange] {
        pseudoToolCallRangesWithPayload(in: content, includeIncomplete: false).map(\.payload)
    }

    nonisolated private static func pseudoToolCallRangesWithPayload(
        in content: String,
        includeIncomplete: Bool
    ) -> [(full: NSRange, payload: NSRange)] {
        let pattern = #"(?m)(?:^|\n)\s*(?:to\s*=\s*)?local_alpine_exec(?:\s+code)?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var ranges: [(full: NSRange, payload: NSRange)] = []
        for match in regex.matches(in: content, range: fullRange) {
            guard let markerRange = Range(match.range, in: content),
                  let payloadRange = balancedJSONRange(in: content, after: markerRange.upperBound) else {
                if includeIncomplete,
                   let markerRange = Range(match.range, in: content) {
                    let full = NSRange(markerRange.lowerBound..<content.endIndex, in: content)
                    ranges.append((full: full, payload: full))
                }
                continue
            }
            ranges.append((
                full: NSRange(markerRange.lowerBound..<payloadRange.upperBound, in: content),
                payload: NSRange(payloadRange, in: content)
            ))
        }
        return ranges
    }

    nonisolated private static func balancedJSONRange(
        in content: String,
        after markerEnd: String.Index
    ) -> Range<String.Index>? {
        var start = markerEnd
        while start < content.endIndex, content[start].isWhitespace {
            start = content.index(after: start)
        }
        guard start < content.endIndex else {
            return nil
        }
        let opener = content[start]
        guard opener == "{" || opener == "[" else { return nil }

        var expectedClosers: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < content.endIndex {
            let char = content[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                expectedClosers.append("}")
            } else if char == "[" {
                expectedClosers.append("]")
            } else if let expected = expectedClosers.last, char == expected {
                expectedClosers.removeLast()
                if expectedClosers.isEmpty {
                    return start..<content.index(after: index)
                }
            }
            index = content.index(after: index)
        }
        return nil
    }

    nonisolated private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted {
            if $0.location == $1.location { return $0.length < $1.length }
            return $0.location < $1.location
        }
        var merged: [NSRange] = []
        for range in sorted {
            guard range.location != NSNotFound else { continue }
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            let lastEnd = last.location + last.length
            let rangeEnd = range.location + range.length
            if range.location <= lastEnd {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(lastEnd, rangeEnd) - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    nonisolated private static func incompleteInstructionFenceRange(in content: String) -> NSRange? {
        let markerRange = content.range(of: "```iexa_alpine", options: [.caseInsensitive, .backwards])
            ?? content.range(of: "```local_alpine_exec", options: [.caseInsensitive, .backwards])
        guard let markerRange else {
            return nil
        }

        let afterMarker = content[markerRange.upperBound...]
        guard afterMarker.range(of: "```") == nil else {
            return nil
        }

        return NSRange(markerRange.lowerBound..<content.endIndex, in: content)
    }

    nonisolated private static func incompleteInstructionTagRange(in content: String) -> NSRange? {
        let markerRange = content.range(of: "<iexa_alpine>", options: [.caseInsensitive, .backwards])
            ?? content.range(of: "<local_alpine_exec>", options: [.caseInsensitive, .backwards])
        guard let markerRange else {
            return nil
        }

        let afterMarker = content[markerRange.upperBound...]
        guard afterMarker.range(of: "</iexa_alpine>", options: .caseInsensitive) == nil,
              afterMarker.range(of: "</local_alpine_exec>", options: .caseInsensitive) == nil else {
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
    case codeBlock
    case rejectedPythonPlainContent

    var isAllowedPythonWriteSource: Bool {
        switch self {
        case .codeLines, .contentBase64, .codeBlock:
            return true
        case .content, .contentLines, .heredoc, .rejectedPythonPlainContent:
            return false
        }
    }

    var isAllowedCodeWriteSource: Bool {
        switch self {
        case .codeLines, .contentLines, .contentBase64, .codeBlock:
            return true
        case .content, .heredoc, .rejectedPythonPlainContent:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .content: return "content"
        case .codeLines: return "code_lines"
        case .contentLines: return "content_lines"
        case .contentBase64: return "content_base64"
        case .heredoc: return "heredoc"
        case .codeBlock: return "code_block"
        case .rejectedPythonPlainContent: return "rejected_python_plain_content"
        }
    }

}

private struct LocalAlpineProtectedWriteOutcome {
    let lines: [String]
    let writtenPath: String?
    let writtenFile: LocalAlpineWrittenFile?
    let hadFailure: Bool
}

private struct LocalAlpineWriteResult {
    let summary: String
    let writtenPaths: [String]
    let writtenFiles: [LocalAlpineWrittenFile]
    let hadFailure: Bool
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
