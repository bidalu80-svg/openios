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
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "jsx": return "jsx"
        case "swift": return "swift"
        case "json": return "json"
        case "html", "htm": return "html"
        case "css": return "css"
        case "md", "markdown": return "markdown"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash": return "bash"
        default: return "text"
        }
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
                var commandToExecute = shellCommand

                commandToExecute = commandToExecute.trimmingCharacters(in: .whitespacesAndNewlines)
                if let extracted = await extractPythonHeredocWrites(from: commandToExecute, cwd: effectiveCWD) {
                    stepLines.append(extracted.summary)
                    extracted.writtenPaths.forEach { editedFilePaths.insert($0) }
                    writtenFiles.append(contentsOf: extracted.writtenFiles)
                    if extracted.hadFailure {
                        let result = LocalAlpineCommandResult(
                            command: "python_heredoc_write",
                            output: extracted.summary,
                            exitCode: 125,
                            interactiveRequest: nil
                        )
                        commandResults.append(Self.commandResult(
                            command: "python_heredoc_write",
                            cwd: effectiveCWD,
                            result: result
                        ))
                        shouldRunShellCommand = false
                        stopRemainingCommands = true
                    } else {
                        commandToExecute = extracted.remainingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                guard shouldRunShellCommand else {
                    if !stepLines.isEmpty {
                        lines.append(stepLines.joined(separator: "\n\n"))
                    }
                    continue
                }
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
        var lines = ["写入文件（命令行直写）"]
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
        var content = file.content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var notes: [String] = []
        if target.lowercased().hasSuffix(".py") {
            let prepared = LocalAlpinePythonWriteGuard.normalizeGeneratedPython(
                content,
                source: file.source.guardSource
            )
            content = prepared.content
            notes = prepared.notes
        }
        guard let data = content.data(using: .utf8) else {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：内容不是有效 UTF-8"],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }
        if target.lowercased().hasSuffix(".py") {
            return await writeValidatedPythonFile(
                data: data,
                target: target,
                split: splitFilePath(target),
                cwd: cwd,
                source: file.source,
                notes: notes
            )
        }
        return await writeFileThroughShell(
            content: content,
            byteCount: data.count,
            target: target,
            cwd: cwd,
            source: file.source,
            notes: notes
        )
    }

    private func writeFileThroughShell(
        content: String,
        byteCount: Int,
        target: String,
        cwd: String,
        source: LocalAlpineAgentFileSource,
        notes: [String] = []
    ) async -> LocalAlpineProtectedWriteOutcome {
        let split = splitFilePath(target)
        let runtimeTarget = runtimePath(forSharedPath: target)
        let runtimeDirectory = runtimePath(forSharedPath: split.directory)
        let marker = Self.shellHereDocMarker(for: content)
        let body = content.hasSuffix("\n") ? content : content + "\n"
        let command = """
        mkdir -p \(shellSingleQuoted(runtimeDirectory))
        cat > \(shellSingleQuoted(runtimeTarget)) <<'\(marker)'
        \(body)\(marker)
        """

        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
        if result.exitCode == 0 {
            var lines = ["- `\(target)` (\(byteCount) B，命令行写入，来源：\(source.displayName))"]
            lines.append(contentsOf: notes.map { "  - \($0)" })
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: target,
                writtenFile: LocalAlpineWrittenFile(
                    path: target,
                    content: content,
                    source: source.displayName,
                    byteCount: byteCount
                ),
                hadFailure: false
            )
        }

        let exit = result.exitCode.map(String.init) ?? "unknown"
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["- `\(target)` 命令行写入失败：退出码 \(exit)"]
        if !output.isEmpty {
            lines.append("  - 输出：\(String(output.prefix(1_000)))")
        }
        return LocalAlpineProtectedWriteOutcome(lines: lines, writtenPath: nil, writtenFile: nil, hadFailure: true)
    }

    private func writeValidatedPythonFile(
        data: Data,
        target: String,
        split: (directory: String, fileName: String),
        cwd: String,
        source: LocalAlpineAgentFileSource,
        notes: [String]
    ) async -> LocalAlpineProtectedWriteOutcome {
        guard let content = String(data: data, encoding: .utf8) else {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：内容不是有效 UTF-8"],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }
        let temporaryPath = "\(split.directory == "/" ? "" : split.directory)/.iexa-write-\(UUID().uuidString)-\(split.fileName)"
        let draft = await writeFileThroughShell(
            content: content,
            byteCount: data.count,
            target: temporaryPath,
            cwd: cwd,
            source: source,
            notes: notes
        )
        guard !draft.hadFailure else { return draft }

        let runtimeDraftPath = runtimePath(forSharedPath: temporaryPath)
        let runtimeTargetPath = runtimePath(forSharedPath: target)

        var writeNotes = notes
        let formatterCommand = pythonFormatterCommand(for: runtimeDraftPath)
        let formatterResult = await LocalAlpineTerminalService.shared.execute(command: formatterCommand, cwd: cwd)
        guard formatterResult.exitCode == 0 else {
            let diagnostic = await pythonLineNumberDiagnostic(
                for: runtimeDraftPath,
                targetRuntimePath: runtimeTargetPath,
                cwd: cwd
            )
            return failedPythonWriteOutcome(
                target: target,
                targetRuntimePath: runtimeTargetPath,
                failedDraftRuntimePath: runtimeDraftPath,
                reason: "black 格式化失败，已阻止覆盖目标文件",
                command: formatterCommand,
                result: formatterResult,
                diagnosticOutput: diagnostic?.output
            )
        }

        writeNotes.append("已在临时文件中执行 black 格式化，并在格式化后再次通过语法检查。")

        let compileCommand = "python3 -m py_compile \(shellSingleQuoted(runtimeDraftPath))"
        let postFormatCompileResult = await LocalAlpineTerminalService.shared.execute(command: compileCommand, cwd: cwd)
        guard postFormatCompileResult.exitCode == 0 else {
            let diagnostic = await pythonLineNumberDiagnostic(
                for: runtimeDraftPath,
                targetRuntimePath: runtimeTargetPath,
                cwd: cwd
            )
            return failedPythonWriteOutcome(
                target: target,
                targetRuntimePath: runtimeTargetPath,
                failedDraftRuntimePath: runtimeDraftPath,
                reason: "Python 格式化后语法检查失败，已阻止覆盖目标文件",
                command: compileCommand,
                result: postFormatCompileResult,
                diagnosticOutput: diagnostic?.output
            )
        }

        let formattedData = (try? await LocalAlpineTerminalService.shared.readFile(path: temporaryPath)) ?? data
        let formattedContent = String(data: formattedData, encoding: .utf8) ?? content

        let moveCommand = """
        mkdir -p \(shellSingleQuoted(runtimePath(forSharedPath: split.directory)))
        mv \(shellSingleQuoted(runtimeDraftPath)) \(shellSingleQuoted(runtimeTargetPath))
        """
        let moveResult = await LocalAlpineTerminalService.shared.execute(command: moveCommand, cwd: cwd)
        guard moveResult.exitCode == 0 else {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：验证通过但移动临时文件失败：\(String(moveResult.output.prefix(1_000)))"],
                writtenPath: nil,
                writtenFile: nil,
                hadFailure: true
            )
        }

        var lines = ["- `\(target)` (\(formattedData.count) B，Python 验证后写入，来源：\(source.displayName))"]
        lines.append(contentsOf: writeNotes.map { "  - \($0)" })
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
    }

    private func pythonFormatterCommand(for runtimePath: String) -> String {
        """
        command -v black >/dev/null 2>&1 || { echo "IEXA_BLACK_MISSING"; exit 127; }
        black --quiet \(shellSingleQuoted(runtimePath))
        """
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
            lines.append("  - 下一步应读取失败草稿的完整行号内容，修正后用 shell heredoc 覆盖目标 Python 文件。")
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
        return LocalAlpineProtectedWriteOutcome(lines: lines, writtenPath: nil, writtenFile: nil, hadFailure: true)
    }

    private func extractPythonHeredocWrites(from command: String, cwd: String) async -> LocalAlpineExtractedWriteResult? {
        let commandLines = command.components(separatedBy: .newlines)
        var remainingLines: [String] = []
        var summaryLines = ["写入 Python heredoc（保护通道）"]
        var writtenPaths: [String] = []
        var writtenFiles: [LocalAlpineWrittenFile] = []
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

            var bodyLines: [String] = []
            var cursor = index + 1
            var foundTerminator = false
            while cursor < commandLines.count {
                let candidate = commandLines[cursor]
                if Self.isHeredocTerminator(candidate, marker: spec.marker) {
                    foundTerminator = true
                    break
                }
                bodyLines.append(candidate)
                cursor += 1
            }

            guard foundTerminator else {
                remainingLines.append(line)
                index += 1
                continue
            }

            extractedCount += 1
            let content = bodyLines.joined(separator: "\n")
            let file = LocalAlpineAgentFile(path: spec.path, content: content, source: .heredoc)
            let outcome = await writeProtectedFile(file, cwd: cwd)
            summaryLines.append(contentsOf: outcome.lines)
            if let writtenPath = outcome.writtenPath {
                writtenPaths.append(writtenPath)
            }
            if let writtenFile = outcome.writtenFile {
                writtenFiles.append(writtenFile)
            }
            if outcome.hadFailure {
                hadFailure = true
            }
            index = cursor + 1
        }

        guard extractedCount > 0 else { return nil }
        return LocalAlpineExtractedWriteResult(
            summary: summaryLines.joined(separator: "\n"),
            writtenPaths: writtenPaths,
            writtenFiles: writtenFiles,
            remainingCommand: remainingLines.joined(separator: "\n"),
            hadFailure: hadFailure
        )
    }

    private nonisolated static func repairPythonHeredocBodies(in command: String) -> String {
        let commandLines = command.components(separatedBy: .newlines)
        var repairedLines: [String] = []
        var index = 0

        while index < commandLines.count {
            let line = commandLines[index]
            guard let spec = pythonHeredocWriteSpec(from: line) else {
                repairedLines.append(line)
                index += 1
                continue
            }

            var bodyLines: [String] = []
            var cursor = index + 1
            var foundTerminator = false
            while cursor < commandLines.count {
                let candidate = commandLines[cursor]
                if isHeredocTerminator(candidate, marker: spec.marker) {
                    foundTerminator = true
                    break
                }
                bodyLines.append(candidate)
                cursor += 1
            }

            guard foundTerminator else {
                repairedLines.append(line)
                index += 1
                continue
            }

            let prepared = LocalAlpinePythonWriteGuard.normalizeGeneratedPython(
                bodyLines.joined(separator: "\n"),
                source: .heredoc
            ).content
            var preparedLines = prepared.components(separatedBy: "\n")
            if prepared.hasSuffix("\n"), preparedLines.last == "" {
                preparedLines.removeLast()
            }

            repairedLines.append(line)
            repairedLines.append(contentsOf: preparedLines)
            repairedLines.append(commandLines[cursor])
            index = cursor + 1
        }

        return repairedLines.joined(separator: "\n")
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

    private nonisolated static func shellHereDocMarker(for content: String, prefix: String = "IEXA_WRITE") -> String {
        var marker = prefix
        var suffix = 0
        let lines = Set(content.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        while lines.contains(marker) {
            suffix += 1
            marker = "\(prefix)_\(suffix)"
        }
        return marker
    }

    private func unsafeCodeFileWriteWarning(for _: String) -> String? {
        return nil
    }

    private nonisolated static func commandWritesCodeThroughShellText(_ command: String) -> Bool {
        let codeFileTarget = #"(?:['"]?)[^'"\s;|&>]*\.(?:py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonl|yaml|yml|toml|xml|md)(?:['"]?)"#
        let specialFileTarget = #"(?:['"]?)(?:[^'"\s;|&>]*/)?(?:makefile|dockerfile)(?:['"]?)"#
        let target = "(?:\(codeFileTarget)|\(specialFileTarget))"

        let redirectionWritePatterns = [
            #"(?is)\b(?:cat|printf|echo)\b[\s\S]{0,800}(?:^|[^0-9])(?:>>?|1>)\s*"# + target,
            #"(?is)\bcat\b\s+<<-?\s*['"]?[A-Za-z0-9_.-]+['"]?[\s\S]{0,1200}(?:^|[^0-9])(?:>>?|1>)\s*"# + target,
            #"(?is)(?:^|[;&|]\s*)tee\s+(?:-[A-Za-z]+\s+)*"# + target
        ]
        if redirectionWritePatterns.contains(where: {
            command.range(of: $0, options: .regularExpression) != nil
        }) {
            return true
        }

        let quotedCodeFile = #"['"][^'"]*\.(?:py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonl|yaml|yml|toml|xml|md)['"]"#
        let pythonHeredocWritePatterns = [
            #"(?is)\bpython3?\b[\s\S]{0,120}<<[\s\S]{0,2400}\bopen\s*\(\s*"# + quotedCodeFile + #"[\s\S]{0,160}['"][wax]\+?['"]"#,
            #"(?is)\bpython3?\b[\s\S]{0,120}<<[\s\S]{0,2400}\b(?:Path\s*\(\s*)"# + quotedCodeFile + #"[\s\S]{0,240}\.(?:write_text|write_bytes)\s*\("#
        ]

        return pythonHeredocWritePatterns.contains { pattern in
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
        source _: LocalAlpineAgentFileSource
    ) -> PythonWritePreparation {
        return .success(content: content, notes: [])
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
    let writtenFile: LocalAlpineWrittenFile?
    let hadFailure: Bool
}

private struct LocalAlpineWriteResult {
    let summary: String
    let writtenPaths: [String]
    let writtenFiles: [LocalAlpineWrittenFile]
    let hadFailure: Bool
}

private struct LocalAlpineExtractedWriteResult {
    let summary: String
    let writtenPaths: [String]
    let writtenFiles: [LocalAlpineWrittenFile]
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
