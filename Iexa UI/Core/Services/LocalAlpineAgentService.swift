import Foundation

struct LocalAlpineAgentResult: Sendable {
    let didExecute: Bool
    let summary: String
    let interactiveRequest: LocalAlpineInteractiveRequest?
    let commandResults: [LocalAlpineAgentCommandResult]
    let writtenFiles: [LocalAlpineWrittenFile]
    let toolRunId: String?
    let toolCalls: [LocalAlpineToolCall]
    let executedCommandCount: Int
    let editedFileCount: Int
    let hadFailure: Bool

    init(
        didExecute: Bool,
        summary: String,
        interactiveRequest: LocalAlpineInteractiveRequest?,
        commandResults: [LocalAlpineAgentCommandResult] = [],
        writtenFiles: [LocalAlpineWrittenFile] = [],
        toolRunId: String? = nil,
        toolCalls: [LocalAlpineToolCall] = [],
        executedCommandCount: Int = 0,
        editedFileCount: Int = 0,
        hadFailure: Bool = false
    ) {
        self.didExecute = didExecute
        self.summary = summary
        self.interactiveRequest = interactiveRequest
        self.commandResults = commandResults
        self.writtenFiles = writtenFiles
        self.toolRunId = toolRunId
        self.toolCalls = toolCalls
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

struct LocalAlpineLineDelta: Codable, Hashable, Sendable {
    let added: Int
    let deleted: Int

    var isEmpty: Bool {
        added == 0 && deleted == 0
    }

    var displayText: String {
        var parts: [String] = []
        if added > 0 {
            parts.append("+\(added)")
        }
        if deleted > 0 {
            parts.append("-\(deleted)")
        }
        return parts.joined(separator: " ")
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

enum LocalAlpineToolCallPhase: String, Codable, Hashable, Sendable {
    case start
    case result
}

struct LocalAlpineToolDisplay: Hashable, Sendable {
    let icon: String
    let title: String
}

enum LocalAlpineToolDisplayRegistry {
    static func display(for toolName: String) -> LocalAlpineToolDisplay {
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read_file", "read_files", "read":
            return LocalAlpineToolDisplay(icon: "doc.text", title: "读取文件")
        case "edit_file", "edit_files", "replace_file", "edit":
            return LocalAlpineToolDisplay(icon: "square.and.pencil", title: "编辑文件")
        case "patch_file", "patch_files", "apply_patch", "patch":
            return LocalAlpineToolDisplay(icon: "doc.on.doc", title: "应用补丁")
        case "write_files", "write_file", "write":
            return LocalAlpineToolDisplay(icon: "doc.badge.plus", title: "写入文件")
        case "delete_file", "delete_files", "remove_file", "remove_files", "delete", "rm":
            return LocalAlpineToolDisplay(icon: "trash", title: "删除文件")
        case "list_dir", "list", "ls":
            return LocalAlpineToolDisplay(icon: "folder", title: "列出目录")
        case "glob", "find_files":
            return LocalAlpineToolDisplay(icon: "doc.text.magnifyingglass", title: "匹配文件")
        case "grep", "search_files":
            return LocalAlpineToolDisplay(icon: "magnifyingglass", title: "搜索文本")
        case "verify", "check":
            return LocalAlpineToolDisplay(icon: "checkmark.seal", title: "验证")
        case "verify_absent", "verify_missing", "ensure_absent":
            return LocalAlpineToolDisplay(icon: "checkmark.seal", title: "验证删除")
        case "compile", "build":
            return LocalAlpineToolDisplay(icon: "hammer", title: "编译")
        case "test":
            return LocalAlpineToolDisplay(icon: "checklist", title: "测试")
        case "run_script", "run":
            return LocalAlpineToolDisplay(icon: "play.circle", title: "运行脚本")
        case "install_dependency", "install":
            return LocalAlpineToolDisplay(icon: "shippingbox", title: "安装依赖")
        case "network_fetch", "fetch":
            return LocalAlpineToolDisplay(icon: "network", title: "网络请求")
        case "command", "shell", "bash", "exec":
            return LocalAlpineToolDisplay(icon: "terminal.fill", title: "运行命令")
        case "diagnostic":
            return LocalAlpineToolDisplay(icon: "magnifyingglass", title: "诊断")
        default:
            return LocalAlpineToolDisplay(icon: "wrench.and.screwdriver", title: toolName)
        }
    }
}

struct LocalAlpineToolCall: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let runId: String
    let name: String
    let phase: LocalAlpineToolCallPhase
    let title: String
    let detail: String
    let cwd: String
    let command: String?
    let exitCode: Int?
    let outputPreview: String?
    let filePaths: [String]
    let lineDelta: LocalAlpineLineDelta?
    let startedAtMs: Int64
    let completedAtMs: Int64?
    let failed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, runId, name, phase, title, detail, cwd, command, exitCode, outputPreview
        case filePaths, lineDelta, startedAtMs, completedAtMs, failed
    }

    init(
        id: String,
        runId: String,
        name: String,
        phase: LocalAlpineToolCallPhase,
        title: String,
        detail: String,
        cwd: String,
        command: String?,
        exitCode: Int?,
        outputPreview: String?,
        filePaths: [String],
        lineDelta: LocalAlpineLineDelta? = nil,
        startedAtMs: Int64,
        completedAtMs: Int64?,
        failed: Bool
    ) {
        self.id = id
        self.runId = runId
        self.name = name
        self.phase = phase
        self.title = title
        self.detail = detail
        self.cwd = cwd
        self.command = command
        self.exitCode = exitCode
        self.outputPreview = outputPreview
        self.filePaths = filePaths
        self.lineDelta = lineDelta
        self.startedAtMs = startedAtMs
        self.completedAtMs = completedAtMs
        self.failed = failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        runId = try container.decode(String.self, forKey: .runId)
        name = try container.decode(String.self, forKey: .name)
        phase = try container.decode(LocalAlpineToolCallPhase.self, forKey: .phase)
        title = try container.decode(String.self, forKey: .title)
        detail = (try? container.decode(String.self, forKey: .detail)) ?? ""
        cwd = (try? container.decode(String.self, forKey: .cwd)) ?? ""
        command = try? container.decode(String.self, forKey: .command)
        exitCode = try? container.decode(Int.self, forKey: .exitCode)
        outputPreview = try? container.decode(String.self, forKey: .outputPreview)
        filePaths = (try? container.decode([String].self, forKey: .filePaths)) ?? []
        lineDelta = try? container.decode(LocalAlpineLineDelta.self, forKey: .lineDelta)
        startedAtMs = (try? container.decode(Int64.self, forKey: .startedAtMs)) ?? 0
        completedAtMs = try? container.decode(Int64.self, forKey: .completedAtMs)
        failed = (try? container.decode(Bool.self, forKey: .failed)) ?? false
    }

    var isRunning: Bool {
        phase == .start
    }

    var displayDetail: String {
        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return command
        }
        return filePaths.joined(separator: ", ")
    }

    var displayLineDelta: String {
        lineDelta?.displayText ?? ""
    }

    var statusDescription: String {
        if isRunning {
            return "正在\(title)"
        }
        if failed {
            return "\(title)失败"
        }
        return "\(title)完成"
    }

    static func metadataString(for calls: [LocalAlpineToolCall]) -> String? {
        let limitedCalls = calls.suffix(40).map { call in
            LocalAlpineToolCall(
                id: call.id,
                runId: call.runId,
                name: call.name,
                phase: call.phase,
                title: call.title,
                detail: String(call.detail.prefix(500)),
                cwd: call.cwd,
                command: call.command.map { String($0.prefix(1_000)) },
                exitCode: call.exitCode,
                outputPreview: call.outputPreview.map { String($0.prefix(4_000)) },
                filePaths: Array(call.filePaths.prefix(12)),
                lineDelta: call.lineDelta,
                startedAtMs: call.startedAtMs,
                completedAtMs: call.completedAtMs,
                failed: call.failed
            )
        }
        guard !limitedCalls.isEmpty,
              let data = try? JSONEncoder().encode(Array(limitedCalls)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func decodeMetadata(_ value: String?) -> [LocalAlpineToolCall] {
        guard let value,
              let data = value.data(using: .utf8),
              let calls = try? JSONDecoder().decode([LocalAlpineToolCall].self, from: data) else {
            return []
        }
        return calls
    }
}

struct LocalAlpineToolEvent: Sendable {
    let runId: String
    let call: LocalAlpineToolCall
}

typealias LocalAlpineToolEventHandler = @MainActor @Sendable (LocalAlpineToolEvent) async -> Void

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
        inputProvider: (@MainActor (LocalAlpineInteractiveRequest) async -> String?)? = nil,
        eventHandler: LocalAlpineToolEventHandler? = nil
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

        let (preparedCommands, skippedUnsafeShellWriteCount) = Self.commandsBySkippingSupersededUnsafeShellWrites(commands)
        guard !preparedCommands.isEmpty else {
            return LocalAlpineAgentResult(didExecute: false, summary: lines.joined(separator: "\n"), interactiveRequest: nil)
        }

        let uniqueCommands = Self.deduplicatedCommands(preparedCommands, defaultCWD: defaultCWD)
        let duplicateCount = max(0, preparedCommands.count - uniqueCommands.count)
        let trimmedCommands = Array(uniqueCommands.prefix(maxCommandsPerResponse))
        let skippedCount = max(0, uniqueCommands.count - trimmedCommands.count)
        let toolRunId = UUID().uuidString
        var commandResults: [LocalAlpineAgentCommandResult] = []
        var writtenFiles: [LocalAlpineWrittenFile] = []
        var toolCalls: [LocalAlpineToolCall] = []
        var editedFilePaths = Set<String>()
        var stopRemainingCommands = false

        lines.insert("Local Alpine 执行结果", at: 0)
        lines.append("环境：内置 Alpine Linux，工作目录默认 `/mnt/iexa`")

        func emitTool(_ call: LocalAlpineToolCall) async {
            if let index = toolCalls.firstIndex(where: { $0.id == call.id }) {
                toolCalls[index] = call
            } else {
                toolCalls.append(call)
            }
            if let eventHandler {
                await eventHandler(LocalAlpineToolEvent(runId: toolRunId, call: call))
            }
        }

        for command in trimmedCommands {
            guard !stopRemainingCommands else { break }

            let cwd = command.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveCWD = (cwd?.isEmpty == false) ? cwd! : defaultCWD
            var stepLines: [String] = []
            var shouldRunShellCommand = true
            if !command.readFiles.isEmpty {
                let context = Self.toolCallContext(
                    runId: toolRunId,
                    name: "read_file",
                    detail: Self.toolDetail(forReadFiles: command.readFiles),
                    cwd: effectiveCWD,
                    filePaths: command.readFiles.map(\.path)
                )
                await emitTool(Self.toolCallStart(context))
                let readResult = await readFiles(command.readFiles, cwd: effectiveCWD)
                stepLines.append(readResult.summary)
                commandResults.append(contentsOf: readResult.commandResults)
                await emitTool(Self.toolCallResult(
                    context,
                    exitCode: readResult.hadFailure ? 1 : 0,
                    outputPreview: readResult.summary,
                    lineDelta: readResult.lineDelta,
                    failed: readResult.hadFailure
                ))
                if readResult.hadFailure {
                    shouldRunShellCommand = false
                    stopRemainingCommands = true
                }
            }

            if !command.editFiles.isEmpty {
                let context = Self.toolCallContext(
                    runId: toolRunId,
                    name: "edit_file",
                    detail: Self.toolDetail(forEditFiles: command.editFiles),
                    cwd: effectiveCWD,
                    filePaths: command.editFiles.map(\.path)
                )
                await emitTool(Self.toolCallStart(context))
                let editResult = await editFiles(command.editFiles, cwd: effectiveCWD)
                stepLines.append(editResult.summary)
                commandResults.append(contentsOf: editResult.commandResults)
                editResult.editedPaths.forEach { editedFilePaths.insert($0) }
                writtenFiles.append(contentsOf: editResult.writtenFiles)
                await emitTool(Self.toolCallResult(
                    context,
                    exitCode: editResult.hadFailure ? 1 : 0,
                    outputPreview: editResult.summary,
                    lineDelta: editResult.lineDelta,
                    failed: editResult.hadFailure
                ))
                if editResult.hadFailure {
                    shouldRunShellCommand = false
                    stopRemainingCommands = true
                }
            }

            if !command.patchFiles.isEmpty {
                let context = Self.toolCallContext(
                    runId: toolRunId,
                    name: "patch_file",
                    detail: Self.toolDetail(forPatchFiles: command.patchFiles),
                    cwd: effectiveCWD,
                    filePaths: command.patchFiles.compactMap(\.path)
                )
                await emitTool(Self.toolCallStart(context))
                let patchResult = await patchFiles(command.patchFiles, cwd: effectiveCWD)
                stepLines.append(patchResult.summary)
                commandResults.append(contentsOf: patchResult.commandResults)
                patchResult.editedPaths.forEach { editedFilePaths.insert($0) }
                writtenFiles.append(contentsOf: patchResult.writtenFiles)
                await emitTool(Self.toolCallResult(
                    context,
                    exitCode: patchResult.hadFailure ? 1 : 0,
                    outputPreview: patchResult.summary,
                    lineDelta: patchResult.lineDelta,
                    failed: patchResult.hadFailure
                ))
                if patchResult.hadFailure {
                    shouldRunShellCommand = false
                    stopRemainingCommands = true
                }
            }

            if !command.writeFiles.isEmpty {
                let context = Self.toolCallContext(
                    runId: toolRunId,
                    name: "write_files",
                    detail: Self.toolDetail(forWriteFiles: command.writeFiles),
                    cwd: effectiveCWD,
                    filePaths: command.writeFiles.map(\.path)
                )
                await emitTool(Self.toolCallStart(context))
                let writeResult = await writeFiles(command.writeFiles, cwd: effectiveCWD)
                stepLines.append(writeResult.summary)
                writeResult.writtenPaths.forEach { editedFilePaths.insert($0) }
                writtenFiles.append(contentsOf: writeResult.writtenFiles)
                let writeCommandResult = LocalAlpineCommandResult(
                    command: "write_files",
                    output: writeResult.summary,
                    exitCode: writeResult.hadFailure ? 125 : 0,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(
                    command: "write_files",
                    cwd: effectiveCWD,
                    result: writeCommandResult
                ))
                await emitTool(Self.toolCallResult(
                    context,
                    exitCode: writeResult.hadFailure ? 125 : 0,
                    outputPreview: writeResult.summary,
                    lineDelta: writeResult.lineDelta,
                    failed: writeResult.hadFailure
                ))
                if writeResult.hadFailure {
                    shouldRunShellCommand = false
                    stopRemainingCommands = true
                }
            }

            if !command.deleteFiles.isEmpty {
                let context = Self.toolCallContext(
                    runId: toolRunId,
                    name: "delete_files",
                    detail: Self.toolDetail(forDeleteFiles: command.deleteFiles),
                    cwd: effectiveCWD,
                    filePaths: command.deleteFiles.map(\.path)
                )
                await emitTool(Self.toolCallStart(context))
                let deleteResult = await deleteFiles(command.deleteFiles, cwd: effectiveCWD)
                stepLines.append(deleteResult.summary)
                commandResults.append(contentsOf: deleteResult.commandResults)
                deleteResult.editedPaths.forEach { editedFilePaths.insert($0) }
                await emitTool(Self.toolCallResult(
                    context,
                    exitCode: deleteResult.hadFailure ? 1 : 0,
                    outputPreview: deleteResult.summary,
                    lineDelta: deleteResult.lineDelta,
                    failed: deleteResult.hadFailure
                ))
                if deleteResult.hadFailure {
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

                let classifiedShellTool = Self.shellToolClassification(
                    for: commandToExecute,
                    fallbackName: command.shellToolName,
                    fallbackDetail: command.shellToolDetail
                )
                let context = Self.toolCallContext(
                    runId: toolRunId,
                    name: classifiedShellTool.name,
                    detail: classifiedShellTool.detail,
                    cwd: effectiveCWD,
                    command: commandToExecute,
                    filePaths: command.shellToolFilePaths
                )
                await emitTool(Self.toolCallStart(context))
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
                        await emitTool(Self.toolCallResult(
                            context,
                            exitCode: result.exitCode,
                            outputPreview: result.output,
                            failed: true
                        ))
                        lines.append(stepLines.joined(separator: "\n\n"))
                        return LocalAlpineAgentResult(
                            didExecute: true,
                            summary: lines.joined(separator: "\n\n"),
                            interactiveRequest: request,
                            commandResults: commandResults,
                            writtenFiles: writtenFiles,
                            toolRunId: toolRunId,
                            toolCalls: toolCalls,
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
                await emitTool(Self.toolCallResult(
                    context,
                    exitCode: result.exitCode,
                    outputPreview: result.output,
                    failed: result.exitCode != 0 || result.interactiveRequest != nil
                ))
                if let diagnostic = await pythonSyntaxDiagnostic(
                    command: commandToExecute,
                    output: result.output,
                    cwd: effectiveCWD
                ) {
                    let diagnosticContext = Self.toolCallContext(
                        runId: toolRunId,
                        name: "diagnostic",
                        detail: Self.oneLine(diagnostic.command),
                        cwd: effectiveCWD,
                        command: diagnostic.command,
                        filePaths: []
                    )
                    await emitTool(Self.toolCallStart(diagnosticContext))
                    stepLines.append(format(command: diagnostic.command, cwd: effectiveCWD, result: diagnostic.result))
                    commandResults.append(Self.commandResult(
                        command: diagnostic.command,
                        cwd: effectiveCWD,
                        result: diagnostic.result
                    ))
                    await emitTool(Self.toolCallResult(
                        diagnosticContext,
                        exitCode: diagnostic.result.exitCode,
                        outputPreview: diagnostic.result.output,
                        failed: diagnostic.result.exitCode != 0
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
        if skippedUnsafeShellWriteCount > 0 {
            lines.append("- 已跳过 \(skippedUnsafeShellWriteCount) 条被结构化写入覆盖的 shell 文本写代码命令，避免 heredoc/重定向破坏源码缩进。")
        }
        if duplicateCount > 0 {
            lines.append("- 已跳过 \(duplicateCount) 条重复命令，避免同一批工具调用重复执行。")
        }

        return LocalAlpineAgentResult(
            didExecute: true,
            summary: lines.joined(separator: "\n\n"),
            interactiveRequest: nil,
            commandResults: commandResults,
            writtenFiles: writtenFiles,
            toolRunId: toolRunId,
            toolCalls: toolCalls,
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

    private nonisolated static func commandsBySkippingSupersededUnsafeShellWrites(
        _ commands: [LocalAlpineAgentCommand]
    ) -> ([LocalAlpineAgentCommand], Int) {
        let hasStructuredWrite = commands.contains {
            !$0.writeFiles.isEmpty || !$0.editFiles.isEmpty || !$0.patchFiles.isEmpty
        }
        guard hasStructuredWrite else { return (commands, 0) }

        var skippedCount = 0
        let filtered = commands.filter { command in
            let hasStructuredOperation = !command.writeFiles.isEmpty
                || !command.readFiles.isEmpty
                || !command.editFiles.isEmpty
                || !command.patchFiles.isEmpty
            guard !hasStructuredOperation,
                  let shell = command.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !shell.isEmpty,
                  commandWritesCodeThroughShellText(shell) else {
                return true
            }
            skippedCount += 1
            return false
        }
        return (filtered, skippedCount)
    }

    private nonisolated static func deduplicatedCommands(
        _ commands: [LocalAlpineAgentCommand],
        defaultCWD: String
    ) -> [LocalAlpineAgentCommand] {
        var seen = Set<String>()
        var deduplicated: [LocalAlpineAgentCommand] = []
        for command in commands {
            let key = commandDedupeKey(command, defaultCWD: defaultCWD)
            guard seen.insert(key).inserted else { continue }
            deduplicated.append(command)
        }
        return deduplicated
    }

    private nonisolated static func commandDedupeKey(
        _ command: LocalAlpineAgentCommand,
        defaultCWD: String
    ) -> String {
        let cwd = (command.cwd ?? defaultCWD)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let shell = (command.command ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let files = command.writeFiles
            .map { file in
                let path = file.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return "\(path):\(file.content.hashValue):\(file.source.displayName)"
            }
            .joined(separator: "|")
        let reads = command.readFiles
            .map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
        let edits = command.editFiles
            .map { edit in
                let path = edit.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let replacements = edit.replacements.map { "\($0.oldText.hashValue):\($0.newText.hashValue)" }.joined(separator: ",")
                return "\(path):\(replacements)"
            }
            .joined(separator: "|")
        let patches = command.patchFiles
            .map { "\(($0.path ?? "").lowercased()):\($0.patch.hashValue)" }
            .joined(separator: "|")
        let deletes = command.deleteFiles
            .map { delete in
                let path = delete.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return "\(path):\(delete.recursive):\(delete.missingOK)"
            }
            .joined(separator: "|")
        let shellTool = [
            command.shellToolName ?? "",
            command.shellToolDetail ?? "",
            command.shellToolFilePaths.joined(separator: "|")
        ].joined(separator: ":")
        return "\(cwd)\n\(shell)\n\(files)\n\(reads)\n\(edits)\n\(patches)\n\(deletes)\n\(shellTool)"
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

    private nonisolated static func toolCallContext(
        runId: String,
        name: String,
        detail: String,
        cwd: String,
        command: String? = nil,
        filePaths: [String]
    ) -> LocalAlpineToolCallContext {
        let display = LocalAlpineToolDisplayRegistry.display(for: name)
        return LocalAlpineToolCallContext(
            id: UUID().uuidString,
            runId: runId,
            name: name,
            title: display.title,
            detail: String(detail.prefix(500)),
            cwd: cwd,
            command: command,
            filePaths: filePaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            startedAtMs: Self.nowMs()
        )
    }

    private nonisolated static func toolCallStart(_ context: LocalAlpineToolCallContext) -> LocalAlpineToolCall {
        LocalAlpineToolCall(
            id: context.id,
            runId: context.runId,
            name: context.name,
            phase: .start,
            title: context.title,
            detail: context.detail,
            cwd: context.cwd,
            command: context.command,
            exitCode: nil,
            outputPreview: nil,
            filePaths: context.filePaths,
            lineDelta: nil,
            startedAtMs: context.startedAtMs,
            completedAtMs: nil,
            failed: false
        )
    }

    private nonisolated static func toolCallResult(
        _ context: LocalAlpineToolCallContext,
        exitCode: Int?,
        outputPreview: String?,
        lineDelta: LocalAlpineLineDelta? = nil,
        failed: Bool
    ) -> LocalAlpineToolCall {
        LocalAlpineToolCall(
            id: context.id,
            runId: context.runId,
            name: context.name,
            phase: .result,
            title: context.title,
            detail: context.detail,
            cwd: context.cwd,
            command: context.command,
            exitCode: exitCode,
            outputPreview: outputPreview.map { String($0.prefix(4_000)) },
            filePaths: context.filePaths,
            lineDelta: lineDelta?.isEmpty == true ? nil : lineDelta,
            startedAtMs: context.startedAtMs,
            completedAtMs: Self.nowMs(),
            failed: failed
        )
    }

    private nonisolated static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func toolDetail(forReadFiles requests: [LocalAlpineReadFileRequest]) -> String {
        requests.map(\.path).prefix(3).joined(separator: ", ")
    }

    private nonisolated static func toolDetail(forEditFiles requests: [LocalAlpineEditFileRequest]) -> String {
        requests.map(\.path).prefix(3).joined(separator: ", ")
    }

    private nonisolated static func toolDetail(forPatchFiles requests: [LocalAlpinePatchFileRequest]) -> String {
        requests.map { $0.path ?? "(diff header)" }.prefix(3).joined(separator: ", ")
    }

    private nonisolated static func toolDetail(forWriteFiles files: [LocalAlpineAgentFile]) -> String {
        files.map(\.path).prefix(3).joined(separator: ", ")
    }

    private nonisolated static func toolDetail(forDeleteFiles requests: [LocalAlpineDeleteFileRequest]) -> String {
        requests.map(\.path).prefix(3).joined(separator: ", ")
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
        if let convertedCommands = Self.commandsByConvertingCatHeredocWrites(from: shell),
           !convertedCommands.isEmpty {
            return convertedCommands
        }
        if let convertedCommands = Self.commandsByConvertingSimpleRedirectionWrites(from: shell),
           !convertedCommands.isEmpty {
            return convertedCommands
        }
        if let convertedCommands = Self.commandsByConvertingPythonHeredocWrites(from: shell),
           !convertedCommands.isEmpty {
            return convertedCommands
        }
        guard Self.looksLikeShellBlock(shell) else { throw LocalAlpineAgentError.noCommands }
        return [LocalAlpineAgentCommand(command: shell, cwd: nil)]
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

        if let opCommands = parseOperationAliasShape(from: dict), !opCommands.isEmpty {
            return opCommands
        }
        if let toolCommands = parseToolCallShape(from: dict), !toolCommands.isEmpty {
            return toolCommands
        }
        if let nested = dict["iexa_alpine"] {
            return parseCommands(from: nested)
        }
        let leadingCommands = parseTopLevelSpecialToolCommands(from: dict)
        var nestedCommands: [LocalAlpineAgentCommand] = []
        for key in ["commands", "plan", "steps", "actions", "tasks"] {
            if let value = dict[key] {
                nestedCommands.append(contentsOf: parseCommands(from: value))
            }
        }
        if let runArray = dict["run"] as? [Any] {
            nestedCommands.append(contentsOf: parseCommands(from: runArray))
        }
        for key in ["verify", "check"] {
            if let array = dict[key] as? [Any] {
                for item in array {
                    var wrapper: [String: Any] = [key: item]
                    if let cwd = Self.cwdString(from: dict) {
                        wrapper["cwd"] = cwd
                    }
                    nestedCommands.append(contentsOf: parseCommands(from: wrapper))
                }
            }
        }
        for key in ["command", "cmd", "shell", "bash", "exec"] {
            if let array = dict[key] as? [Any],
               array.contains(where: { $0 is [String: Any] }) {
                nestedCommands.append(contentsOf: parseCommands(from: array))
            }
        }
        var files = parseWriteFilesForCommand(from: dict)
        files.append(contentsOf: parseEditRewriteFilesForCommand(from: dict))
        var readFiles = parseReadFilesForCommand(from: dict)
        var editFiles = parseEditFilesForCommand(from: dict)
        var patchFiles = parsePatchFilesForCommand(from: dict)
        var deleteFiles = parseDeleteFilesForCommand(from: dict)

        let shellCommand = Self.shellCommandString(from: dict)
        if let shellCommand,
           let convertedCommands = Self.commandsByConvertingCatHeredocWrites(
            from: shellCommand,
            cwd: Self.cwdString(from: dict)
           ),
           !convertedCommands.isEmpty {
            return leadingCommands + convertedCommands + nestedCommands
        }
        if let shellCommand,
           let convertedCommands = Self.commandsByConvertingSimpleRedirectionWrites(
            from: shellCommand,
            cwd: Self.cwdString(from: dict)
           ),
           !convertedCommands.isEmpty {
            return leadingCommands + convertedCommands + nestedCommands
        }
        if let shellCommand,
           let convertedCommands = Self.commandsByConvertingPythonHeredocWrites(
            from: shellCommand,
            cwd: Self.cwdString(from: dict)
           ),
           !convertedCommands.isEmpty {
            return leadingCommands + convertedCommands + nestedCommands
        }
        let generatedInput = Self.dictionaryByRemovingArrayOnlyToolWrappers(from: dict)
        if let generatedToolCommand = Self.generatedShellCommand(from: generatedInput, shellCommand: shellCommand) {
            return leadingCommands + [LocalAlpineAgentCommand(
                command: generatedToolCommand.command,
                cwd: generatedToolCommand.cwd ?? Self.cwdString(from: dict),
                writeFiles: files,
                readFiles: readFiles,
                editFiles: editFiles,
                patchFiles: patchFiles,
                deleteFiles: deleteFiles,
                shellToolName: generatedToolCommand.toolName,
                shellToolDetail: generatedToolCommand.detail,
                shellToolFilePaths: generatedToolCommand.filePaths
            )] + nestedCommands
        }

        if let command = shellCommand {
            let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let specialCommands = parseSpecialToolShape(tool: normalizedCommand, arguments: dict),
               !specialCommands.isEmpty {
                return leadingCommands + specialCommands + nestedCommands
            }
            if let selector = Self.structuredToolSelector(command) {
                switch selector {
                case "read":
                    if readFiles.isEmpty { readFiles = parseReadFiles(from: dict) }
                case "edit":
                    if editFiles.isEmpty { editFiles = parseEditFiles(from: dict) }
                case "patch":
                    if patchFiles.isEmpty { patchFiles = parsePatchFiles(from: dict) }
                case "write":
                    if files.isEmpty { files = parseWriteFiles(from: dict) }
                case "delete":
                    if deleteFiles.isEmpty { deleteFiles = parseDeleteFiles(from: dict) }
                default:
                    break
                }
                guard !files.isEmpty || !readFiles.isEmpty || !editFiles.isEmpty || !patchFiles.isEmpty || !deleteFiles.isEmpty else {
                    return leadingCommands + nestedCommands
                }
                return leadingCommands + [LocalAlpineAgentCommand(
                    command: nil,
                    cwd: Self.cwdString(from: dict),
                    writeFiles: files,
                    readFiles: readFiles,
                    editFiles: editFiles,
                    patchFiles: patchFiles,
                    deleteFiles: deleteFiles
                )] + nestedCommands
            }
            return leadingCommands + [LocalAlpineAgentCommand(
                command: command,
                cwd: Self.cwdString(from: dict),
                writeFiles: files,
                readFiles: readFiles,
                editFiles: editFiles,
                patchFiles: patchFiles,
                deleteFiles: deleteFiles
            )] + nestedCommands
        }

        if !files.isEmpty || !readFiles.isEmpty || !editFiles.isEmpty || !patchFiles.isEmpty || !deleteFiles.isEmpty {
            return leadingCommands + [LocalAlpineAgentCommand(
                command: nil,
                cwd: Self.cwdString(from: dict),
                writeFiles: files,
                readFiles: readFiles,
                editFiles: editFiles,
                patchFiles: patchFiles,
                deleteFiles: deleteFiles
            )] + nestedCommands
        }

        return leadingCommands + nestedCommands
    }

    private func parseOperationAliasShape(from dict: [String: Any]) -> [LocalAlpineAgentCommand]? {
        let op = Self.stringValue(dict["op"] ?? dict["operation"] ?? dict["type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let op, Self.knownStructuredToolNames.contains(op) else { return nil }
        if let special = parseSpecialToolShape(tool: op, arguments: dict) {
            return special
        }
        var merged = dict
        merged.removeValue(forKey: "op")
        merged.removeValue(forKey: "operation")
        merged.removeValue(forKey: "type")
        let arguments = merged
        switch op {
        case "bash", "shell", "sh", "exec", "run", "command":
            if Self.shellCommandString(from: merged) == nil {
                if op == "run" {
                    merged["run"] = arguments
                } else {
                    merged["command"] = dict["command"] ?? dict["cmd"] ?? dict["shell"] ?? dict["run"]
                }
            }
        case "read", "read_file", "read_files", "cat", "open_file":
            merged["read_file"] = arguments
        case "write", "write_file", "write_files", "create_file", "create_files", "save_file", "save_files":
            merged["write_file"] = arguments
        case "edit", "edit_file", "edit_files", "replace_file":
            merged["edit_file"] = arguments
        case "patch", "patch_file", "patch_files", "apply_patch":
            merged["patch_file"] = arguments
        case "delete", "delete_file", "delete_files", "remove_file", "remove_files", "rm", "rmdir":
            merged["delete_file"] = arguments
        case "list", "list_dir", "list_directory", "ls":
            merged["list_dir"] = arguments
        case "grep", "search", "search_files":
            merged["grep"] = arguments
        case "glob", "find", "glob/find", "find_files":
            merged["glob"] = arguments
        case "verify", "check":
            merged["verify"] = arguments
        default:
            return nil
        }
        return parseCommands(from: merged)
    }

    private nonisolated static func shellCommandString(from dict: [String: Any]) -> String? {
        for key in ["command", "cmd", "shell", "bash", "exec", "run"] {
            if let command = stringValue(dict[key]) {
                if ["cmd", "command", "run"].contains(command.lowercased()),
                   let argsCommand = shellCommandString(fromValue: dict["args"] ?? dict["arguments"] ?? dict["argv"]) {
                    return argsCommand
                }
                let args = shellArgumentsString(from: dict["args"] ?? dict["arguments"] ?? dict["argv"])
                return args.map { "\(command) \($0)" } ?? command
            }
            if let array = dict[key] as? [Any],
               !array.contains(where: { $0 is [String: Any] }),
               let command = shellCommandString(fromValue: array) {
                return command
            }
            if let command = shellCommandString(fromValue: dict[key]) {
                return command
            }
        }
        return nil
    }

    private func parseToolCallShape(from dict: [String: Any]) -> [LocalAlpineAgentCommand]? {
        let tool = Self.stringValue(dict["tool"] ?? dict["function"] ?? dict["action"] ?? dict["name"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rawArguments = dict["arguments"] ?? dict["args"] ?? dict["input"] ?? dict["parameters"] ?? dict
        guard let tool,
              Self.knownStructuredToolNames.contains(tool) else {
            return nil
        }
        let arguments = Self.dictionaryValue(rawArguments) ?? ["value": rawArguments]
        if let special = parseSpecialToolShape(tool: tool, arguments: arguments) {
            return special
        }
        var merged = arguments
        merged.removeValue(forKey: "tool")
        merged.removeValue(forKey: "function")
        merged.removeValue(forKey: "action")
        merged.removeValue(forKey: "name")
        merged.removeValue(forKey: "arguments")
        merged.removeValue(forKey: "args")
        merged.removeValue(forKey: "input")
        merged.removeValue(forKey: "parameters")
        switch tool {
        case "bash", "shell", "sh", "exec", "run", "command":
            if Self.shellCommandString(from: merged) == nil {
                if tool == "run" {
                    merged["run"] = arguments
                } else {
                    merged["command"] = arguments["command"]
                        ?? arguments["cmd"]
                        ?? arguments["shell"]
                        ?? arguments["run"]
                        ?? arguments["value"]
                }
            }
        case "read", "read_file", "read_files", "cat", "open_file":
            merged["read_file"] = arguments["value"] ?? arguments
        case "write", "write_file", "write_files", "create_file", "create_files", "save_file", "save_files":
            merged["write_file"] = arguments
        case "edit", "edit_file", "edit_files", "replace_file":
            merged["edit_file"] = arguments
        case "patch", "patch_file", "patch_files", "apply_patch":
            merged["patch_file"] = arguments
        case "delete", "delete_file", "delete_files", "remove_file", "remove_files", "rm", "rmdir":
            merged["delete_file"] = arguments["value"] ?? arguments
        case "list", "list_dir", "list_directory", "ls":
            merged["list_dir"] = arguments["value"] ?? arguments
        case "grep", "search", "search_files":
            merged["grep"] = arguments
        case "glob", "find", "glob/find", "find_files":
            merged["glob"] = arguments
        case "verify", "check":
            merged["verify"] = arguments
        default:
            return nil
        }
        return parseCommands(from: merged)
    }

    private func parseTopLevelSpecialToolCommands(from dict: [String: Any]) -> [LocalAlpineAgentCommand] {
        var commands: [LocalAlpineAgentCommand] = []
        for tool in ["mkdir", "append_file", "append", "append_and_read", "delete_dir", "remove_dir", "move_file", "rename_file", "copy_file"] {
            guard let raw = dict[tool] else { continue }
            let items = (raw as? [Any]) ?? [raw]
            for item in items {
                var arguments = Self.dictionaryValue(item) ?? ["path": item]
                if Self.cwdString(from: arguments) == nil,
                   let cwd = Self.cwdString(from: dict) {
                    arguments["cwd"] = cwd
                }
                commands.append(contentsOf: parseSpecialToolShape(tool: tool, arguments: arguments) ?? [])
            }
        }
        return commands
    }

    private static let knownStructuredToolNames: Set<String> = [
        "bash", "shell", "sh", "exec", "run", "command",
        "read", "read_file", "read_files", "cat", "open_file",
        "write", "write_file", "write_files", "create_file", "create_files", "save_file", "save_files",
        "edit", "edit_file", "edit_files", "replace_file",
        "patch", "patch_file", "patch_files", "apply_patch",
        "delete", "delete_file", "delete_files", "remove_file", "remove_files", "delete_dir", "remove_dir", "rm", "rmdir",
        "list", "list_dir", "list_directory", "ls",
        "grep", "search", "search_files",
        "append", "append_file", "append_and_read",
        "move_file", "rename_file", "copy_file", "mkdir",
        "glob", "find", "glob/find", "find_files",
        "verify", "check"
    ]

    private func parseSpecialToolShape(
        tool: String,
        arguments: [String: Any]
    ) -> [LocalAlpineAgentCommand]? {
        switch tool {
        case "append", "append_file", "append_and_read":
            guard let path = Self.pathString(from: arguments),
                  let content = Self.textPayload(
                    from: arguments,
                    keys: ["append", "content", "text", "body", "line"],
                    lineKeys: ["append_lines", "content_lines", "lines"],
                    base64Keys: ["append_base64", "content_base64", "base64"]
                  ) else {
                return []
            }
            let cwd = Self.cwdString(from: arguments) ?? "/mnt/iexa"
            let write: [String: Any] = [
                "write_file": [
                    "path": path,
                    "content": content,
                    "mode": "append"
                ],
                "cwd": cwd
            ]
            var sequence: [[String: Any]] = [write]
            if Self.boolValue(arguments["read_back"] ?? arguments["readBack"] ?? arguments["read"]) == true
                || tool == "append_and_read" {
                sequence.append([
                    "read_file": path,
                    "cwd": cwd
                ])
            }
            return parseCommands(from: sequence)

        case "delete_dir", "remove_dir", "rmdir":
            guard let path = Self.pathString(from: arguments) else { return [] }
            let cwd = Self.cwdString(from: arguments) ?? "/mnt/iexa"
            var sequence: [[String: Any]] = [[
                "delete_file": [
                    "path": path,
                    "recursive": true,
                    "missing_ok": true
                ],
                "cwd": cwd
            ]]
            if Self.boolValue(arguments["verify"] ?? arguments["check"]) == true {
                sequence.append([
                    "verify": [
                        "path": path,
                        "exists": false
                    ],
                    "cwd": cwd
                ])
            }
            return parseCommands(from: sequence)

        case "move_file", "rename_file":
            guard let source = Self.stringValue(arguments["from"] ?? arguments["source"] ?? arguments["src"])
                    ?? Self.pathString(from: arguments),
                  let destination = Self.stringValue(
                    arguments["to"] ?? arguments["dest"] ?? arguments["destination"] ?? arguments["new_path"] ?? arguments["newPath"]
                  ) else {
                return []
            }
            let command = "mv \(Self.shellSingleQuotedStatic(source)) \(Self.shellSingleQuotedStatic(destination)) && test -e \(Self.shellSingleQuotedStatic(destination))"
            return [LocalAlpineAgentCommand(command: command, cwd: Self.cwdString(from: arguments) ?? "/mnt/iexa")]

        case "copy_file":
            guard let source = Self.stringValue(arguments["from"] ?? arguments["source"] ?? arguments["src"])
                    ?? Self.pathString(from: arguments),
                  let destination = Self.stringValue(
                    arguments["to"] ?? arguments["dest"] ?? arguments["destination"] ?? arguments["new_path"] ?? arguments["newPath"]
                  ) else {
                return []
            }
            let command = "cp \(Self.shellSingleQuotedStatic(source)) \(Self.shellSingleQuotedStatic(destination)) && test -e \(Self.shellSingleQuotedStatic(destination))"
            return [LocalAlpineAgentCommand(command: command, cwd: Self.cwdString(from: arguments) ?? "/mnt/iexa")]

        case "mkdir":
            guard let path = Self.pathString(from: arguments) else { return [] }
            let command = "mkdir -p \(Self.shellSingleQuotedStatic(path)) && test -d \(Self.shellSingleQuotedStatic(path))"
            return [LocalAlpineAgentCommand(command: command, cwd: Self.cwdString(from: arguments) ?? "/mnt/iexa")]

        default:
            return nil
        }
    }

    private nonisolated static func shellCommandString(fromValue value: Any?) -> String? {
        if let value = stringValue(value) {
            return value
        }
        if let array = value as? [Any] {
            if array.contains(where: { $0 is [String: Any] }) {
                return nil
            }
            let parts = array.compactMap { stringValue($0) }
            guard !parts.isEmpty, parts.count == array.count else { return nil }
            return parts.map(shellSingleQuotedStatic).joined(separator: " ")
        }
        guard let dict = value as? [String: Any] else { return nil }
        let commandKeys = ["command", "cmd", "shell", "bash", "exec", "run"]
        let args = shellArgumentsString(from: dict["args"] ?? dict["arguments"] ?? dict["argv"])
        for key in commandKeys {
            if let command = stringValue(dict[key]) {
                if ["cmd", "command", "run"].contains(command.lowercased()),
                   let argsCommand = shellCommandString(fromValue: dict["args"] ?? dict["arguments"] ?? dict["argv"]) {
                    return argsCommand
                }
                return args.map { "\(command) \($0)" } ?? command
            }
            if let array = dict[key] as? [Any],
               !array.contains(where: { $0 is [String: Any] }),
               let command = shellCommandString(fromValue: array) {
                return command
            }
        }
        if let executable = stringValue(dict["program"])
            ?? stringValue(dict["binary"])
            ?? stringValue(dict["executable"]) {
            return [shellSingleQuotedStatic(executable), args].compactMap { $0 }.joined(separator: " ")
        }
        return nil
    }

    private nonisolated static func shellArgumentsString(from value: Any?) -> String? {
        if let value = stringValue(value) {
            return value
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { argument -> String? in
                if let string = stringValue(argument) { return shellSingleQuotedStatic(string) }
                if let int = argument as? Int { return shellSingleQuotedStatic(String(int)) }
                if let double = argument as? Double { return shellSingleQuotedStatic(String(double)) }
                if let bool = argument as? Bool { return shellSingleQuotedStatic(bool ? "true" : "false") }
                return nil
            }
            guard !parts.isEmpty, parts.count == array.count else { return nil }
            return parts.joined(separator: " ")
        }
        return nil
    }

    private nonisolated static func dictionaryByRemovingArrayOnlyToolWrappers(
        from dict: [String: Any]
    ) -> [String: Any] {
        var copy = dict
        for key in ["verify", "check"] where copy[key] is [Any] {
            copy.removeValue(forKey: key)
        }
        return copy
    }

    private nonisolated static func structuredToolSelector(_ command: String) -> String? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "read_file", "read_files", "read", "cat", "open_file":
            return "read"
        case "edit_file", "edit_files", "replace_file", "edit":
            return "edit"
        case "patch_file", "patch_files", "apply_patch", "patch":
            return "patch"
        case "write_files", "write_file", "write":
            return "write"
        case "delete_file", "delete_files", "remove_file", "remove_files", "delete", "rm", "rmdir":
            return "delete"
        case "append", "append_file", "append_and_read":
            return "append"
        case "delete_dir", "remove_dir":
            return "delete_dir"
        case "move_file", "rename_file":
            return "move"
        case "copy_file":
            return "copy"
        case "mkdir":
            return "mkdir"
        default:
            return nil
        }
    }

    private nonisolated static func shellToolClassification(
        for command: String,
        fallbackName: String?,
        fallbackDetail: String?
    ) -> (name: String, detail: String) {
        let detail = fallbackDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmedCommand
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()

        if let fallbackName,
           !fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "command" {
            return (fallbackName, detail?.isEmpty == false ? detail! : oneLine(trimmedCommand))
        }

        let classifiedName: String
        if normalized.range(of: #"(^|[;&|]\s*)(?:apk|apt|brew|pip3?|npm|pnpm|yarn)\s+(?:add|install|i)\b"#, options: .regularExpression) != nil {
            classifiedName = "install_dependency"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:swift|xcodebuild|make|cmake|gcc|g\+\+|clang|cargo|go|npm|pnpm|yarn)\s+(?:build|compile|archive|run\s+build)\b"#, options: .regularExpression) != nil
            || normalized.contains(" py_compile ")
            || normalized.hasPrefix("python3 -m py_compile")
            || normalized.hasPrefix("python -m py_compile") {
            classifiedName = "compile"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:pytest|python3?\s+-m\s+pytest|npm\s+test|pnpm\s+test|yarn\s+test|go\s+test|cargo\s+test)\b"#, options: .regularExpression) != nil {
            classifiedName = "test"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:curl|wget)\s+"#, options: .regularExpression) != nil {
            classifiedName = "network_fetch"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:python3?|node|deno|bun|ruby|php|lua|go\s+run|cargo\s+run|swift\s+run)\b"#, options: .regularExpression) != nil {
            classifiedName = "run_script"
        } else {
            classifiedName = "command"
        }

        return (
            classifiedName,
            detail?.isEmpty == false ? detail! : oneLine(trimmedCommand)
        )
    }

    private nonisolated static func generatedShellCommand(
        from dict: [String: Any],
        shellCommand: String?
    ) -> (command: String, toolName: String, detail: String, filePaths: [String], cwd: String?)? {
        let selector = shellCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let cwd = cwdString(from: dict)

        if let shellCommand,
           let path = runnablePathFromNaturalRunCommand(shellCommand) {
            let verifyObject: [String: Any] = [
                "verify": ["path": path],
                "cwd": cwd ?? "/mnt/iexa"
            ]
            return generatedShellCommand(from: verifyObject, shellCommand: "verify")
        }

        if selector == "glob" || selector == "find" || selector == "glob/find" || selector == "find_files" {
            var object = dict
            object.removeValue(forKey: "cmd")
            object.removeValue(forKey: "command")
            let pattern = normalizedGlobPattern(
                stringValue(value(for: ["pattern", "query", "name"], in: object))
                    ?? firstString(in: value(for: ["pattern", "patterns", "query", "name"], in: object))
                    ?? "*"
            )
            let path = directoryPathString(from: object) ?? "."
            let depth = max(1, min(intValue(value(for: ["max_depth", "depth"], in: object)) ?? 20, 30))
            let command = "find \(shellSingleQuotedStatic(path)) -maxdepth \(depth) -name \(shellSingleQuotedStatic(pattern)) 2>/dev/null | sed -n '1,240p'"
            return (command, "glob", pattern, [path], cwd)
        }

        if dict["list_dir"] != nil || dict["list_directory"] != nil || dict["ls"] != nil || dict["list"] != nil
            || selector == "list_dir" || selector == "list_directory" || selector == "ls" || selector == "list" {
            let object = dict["list_dir"] ?? dict["list_directory"] ?? dict["ls"] ?? dict["list"] ?? dict
            let path = pathString(from: object) ?? pathString(from: dict) ?? "."
            let depth = max(1, min(intValue(value(for: ["max_depth", "depth"], in: object)) ?? 2, 8))
            let includeHidden = boolValue(value(for: ["hidden", "include_hidden", "all"], in: object)) ?? true
            let quotedPath = shellSingleQuotedStatic(path)
            let visibleFilter = includeHidden ? "" : " | grep -v '/\\.'"
            let command = """
            printf '== pwd ==\\n' && pwd && printf '\\n== list: %s ==\\n' \(quotedPath) && ls -la \(quotedPath) 2>/dev/null || true
            printf '\\n== find maxdepth \(depth): %s ==\\n' \(quotedPath) && find \(quotedPath) -maxdepth \(depth) -mindepth 1 2>/dev/null\(visibleFilter) | sed -n '1,240p'
            """
            return (command, "list_dir", path, [path], cwd)
        }

        if dict["glob"] != nil || dict["find"] != nil || dict["find_files"] != nil
            || selector == "glob" || selector == "find" || selector == "glob/find" || selector == "find_files" {
            let object = dict["glob"] ?? dict["find"] ?? dict["find_files"] ?? dict
            let pattern = normalizedGlobPattern(
                stringValue(object)
                    ?? firstString(in: object)
                    ?? stringValue(value(for: ["pattern", "query", "name"], in: object))
                    ?? firstString(in: value(for: ["pattern", "patterns", "query", "name"], in: object))
                    ?? "*"
            )
            let path = directoryPathString(from: object) ?? directoryPathString(from: dict) ?? "."
            let depth = max(1, min(intValue(value(for: ["max_depth", "depth"], in: object)) ?? 8, 20))
            let command = "find \(shellSingleQuotedStatic(path)) -maxdepth \(depth) -name \(shellSingleQuotedStatic(pattern)) 2>/dev/null | sed -n '1,240p'"
            return (command, "glob", pattern, [path], cwd)
        }

        if dict["grep"] != nil || dict["search_files"] != nil || dict["search"] != nil
            || selector == "grep" || selector == "search_files" || selector == "search" {
            let object = dict["grep"] ?? dict["search_files"] ?? dict["search"] ?? dict
            guard let pattern = (stringValue(object) ?? stringValue(value(for: ["pattern", "query", "text", "regex"], in: object)))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !pattern.isEmpty else {
                return nil
            }
            let path = directoryPathString(from: object) ?? directoryPathString(from: dict) ?? "."
            let includeValue = stringValue(value(for: ["include", "name"], in: object))
                ?? stringValue(value(for: ["include", "name"], in: dict))
                ?? firstString(in: value(for: ["include", "includes"], in: object))
                ?? firstString(in: value(for: ["include", "includes"], in: dict))
            let include = includeValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let caseSensitive = boolValue(value(for: ["case_sensitive", "caseSensitive"], in: object))
                ?? boolValue(value(for: ["case_sensitive", "caseSensitive"], in: dict))
                ?? true
            let grepFlag = caseSensitive ? "-RIn" : "-RIni"
            if let include, !include.isEmpty {
                let command = """
                find \(shellSingleQuotedStatic(path)) -type f -name \(shellSingleQuotedStatic(include)) -exec grep \(grepFlag) -- \(shellSingleQuotedStatic(pattern)) {} \\; 2>/dev/null | sed -n '1,240p'
                """
                return (command, "grep", pattern, [path], cwd)
            } else {
                let command = "grep \(grepFlag) -- \(shellSingleQuotedStatic(pattern)) \(shellSingleQuotedStatic(path)) 2>/dev/null | sed -n '1,240p'"
                return (command, "grep", pattern, [path], cwd)
            }
        }

        if dict["verify"] != nil || dict["check"] != nil
            || selector == "verify" || selector == "check" {
            let object = dict["verify"] ?? dict["check"] ?? dict
            if let objectDict = object as? [String: Any],
               let command = shellCommandString(from: objectDict)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !command.isEmpty,
               !["verify", "check"].contains(command.lowercased()) {
                return (command, "verify", oneLine(command), [], cwd)
            }
            if let missingPath = absentPathString(from: object) {
                let command = "test ! -e \(shellSingleQuotedStatic(missingPath)) && printf '%s absent\\n' \(shellSingleQuotedStatic(missingPath))"
                return (command, "verify_absent", missingPath, [missingPath], cwd)
            }
            if let dictObject = object as? [String: Any],
               boolValue(dictObject["exists"]) == false,
               let path = pathString(from: dictObject) {
                let command = "test ! -e \(shellSingleQuotedStatic(path)) && printf '%s absent\\n' \(shellSingleQuotedStatic(path))"
                return (command, "verify_absent", path, [path], cwd)
            }
            guard let path = pathString(from: object) else {
                return ("pwd && find . -maxdepth 2 -type f | sed -n '1,120p'", "verify", "workspace", [], cwd)
            }
            let deletedPathKeys = Set(pathStrings(from: deleteFilesObject(from: dict)).map(normalizedPathKey))
            if !deletedPathKeys.isEmpty,
               deletedPathKeys.contains(normalizedPathKey(path)) {
                let command = "test ! -e \(shellSingleQuotedStatic(path)) && printf '%s absent\\n' \(shellSingleQuotedStatic(path))"
                return (command, "verify_absent", path, [path], cwd)
            }
            let command: String
            let lower = path.lowercased()
            let quotedPath = shellSingleQuotedStatic(path)
            if lower.hasSuffix(".py") || lower.hasSuffix(".pyw") {
                command = "python3 -m py_compile \(quotedPath) && python3 \(quotedPath)"
            } else if lower.hasSuffix(".lua") {
                command = "if command -v lua >/dev/null 2>&1; then lua \(quotedPath); elif command -v lua5.4 >/dev/null 2>&1 || apk add --no-cache lua5.4; then lua5.4 \(quotedPath); else apk add --no-cache lua && lua \(quotedPath); fi"
            } else if lower.hasSuffix(".cpp") || lower.hasSuffix(".cc") || lower.hasSuffix(".cxx") {
                command = "if command -v g++ >/dev/null 2>&1 || apk add --no-cache g++; then g++ \(quotedPath) -std=c++17 -O0 -o /tmp/iexa_verify_cpp && /tmp/iexa_verify_cpp; fi"
            } else if lower.hasSuffix(".c") {
                command = "if command -v gcc >/dev/null 2>&1 || apk add --no-cache gcc musl-dev; then gcc \(quotedPath) -O0 -o /tmp/iexa_verify_c && /tmp/iexa_verify_c; fi"
            } else if lower.hasSuffix(".sh") {
                command = "sh \(quotedPath)"
            } else if lower.hasSuffix(".go") {
                if lower.hasSuffix("_test.go") {
                    let directory = pathDirectory(for: path)
                    command = "if command -v go >/dev/null 2>&1 || apk add --no-cache go; then cd \(shellSingleQuotedStatic(directory)) && go test ./...; fi"
                } else {
                    command = "if command -v go >/dev/null 2>&1 || apk add --no-cache go; then go run \(quotedPath); fi"
                }
            } else if lower.hasSuffix(".rs") {
                command = "if command -v rustc >/dev/null 2>&1 || apk add --no-cache rust; then rustc \(quotedPath) -o /tmp/iexa_verify_rs && /tmp/iexa_verify_rs; fi"
            } else if lower.hasSuffix(".rb") {
                command = "if command -v ruby >/dev/null 2>&1 || apk add --no-cache ruby; then ruby \(quotedPath); fi"
            } else if lower.hasSuffix(".php") {
                command = "if command -v php >/dev/null 2>&1 || apk add --no-cache php-cli; then php \(quotedPath); fi"
            } else if lower.hasSuffix(".java") {
                let className = pathBaseName(for: path).replacingOccurrences(of: ".java", with: "")
                command = "if command -v javac >/dev/null 2>&1 || apk add --no-cache openjdk17; then javac \(quotedPath) && java -cp \(shellSingleQuotedStatic(pathDirectory(for: path))) \(shellSingleQuotedStatic(className)); fi"
            } else if lower.hasSuffix(".js") || lower.hasSuffix(".mjs") || lower.hasSuffix(".cjs") {
                command = "node \(quotedPath)"
            } else if lower.hasSuffix(".ts") {
                command = "command -v npx >/dev/null 2>&1 && npx tsc --noEmit \(quotedPath) || cat \(quotedPath) >/dev/null"
            } else if lower.hasSuffix("package.json") {
                command = "node -e \"const p=require('./package.json'); console.log(p.scripts||{})\" && { npm test -- --watch=false 2>/dev/null || npm run build 2>/dev/null || true; }"
            } else {
                command = "test -e \(quotedPath) && ls -la \(quotedPath)"
            }
            return (command, "verify", path, [path], cwd)
        }

        if dict["verify_absent"] != nil || dict["verify_missing"] != nil || dict["ensure_absent"] != nil {
            let object = dict["verify_absent"] ?? dict["verify_missing"] ?? dict["ensure_absent"]
            let paths = pathStrings(from: object)
            guard !paths.isEmpty else { return nil }
            let command = paths
                .map { "test ! -e \(shellSingleQuotedStatic($0)) && printf '%s absent\\n' \(shellSingleQuotedStatic($0))" }
                .joined(separator: "\n")
            return (command, "verify_absent", paths.prefix(3).joined(separator: ", "), paths, cwd)
        }

        if let runObject = dict["run"] as? [String: Any],
           let path = pathString(from: runObject) {
            let lower = path.lowercased()
            let quotedPath = shellSingleQuotedStatic(path)
            let command: String
            if lower.hasSuffix(".lua") {
                command = "if command -v lua >/dev/null 2>&1; then lua \(quotedPath); elif command -v lua5.4 >/dev/null 2>&1 || apk add --no-cache lua5.4; then lua5.4 \(quotedPath); else apk add --no-cache lua && lua \(quotedPath); fi"
            } else if lower.hasSuffix(".py") || lower.hasSuffix(".pyw") {
                command = "python3 \(quotedPath)"
            } else if lower.hasSuffix(".js") || lower.hasSuffix(".mjs") || lower.hasSuffix(".cjs") {
                command = "node \(quotedPath)"
            } else if lower.hasSuffix(".sh") {
                command = "sh \(quotedPath)"
            } else {
                command = "test -e \(quotedPath) && chmod +x \(quotedPath) 2>/dev/null || true; \(quotedPath)"
            }
            return (command, "run_script", path, [path], cwdString(from: runObject) ?? cwd)
        }

        return nil
    }

    private nonisolated static func cwdString(from dict: [String: Any]) -> String? {
        for key in ["cwd", "workdir", "working_dir", "directory", "dir"] {
            if let value = dict[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        for key in ["command", "cmd", "shell", "bash", "exec", "run", "verify", "check"] {
            if let nested = dict[key] as? [String: Any],
               let value = cwdString(from: nested) {
                return value
            }
        }
        return nil
    }

    private func parseReadFilesForCommand(from dict: [String: Any]) -> [LocalAlpineReadFileRequest] {
        parseReadFiles(from: Self.readFilesObject(from: dict))
    }

    private nonisolated static func readFilesObject(from dict: [String: Any]) -> Any? {
        dict["read_file"] ?? dict["read_files"] ?? dict["read"] ?? dict["open_file"] ?? dict["cat"]
    }

    private func parseReadFiles(from object: Any?) -> [LocalAlpineReadFileRequest] {
        if let array = object as? [Any] {
            return array.flatMap { parseReadFiles(from: $0) }
        }
        if let path = object as? String {
            return [LocalAlpineReadFileRequest(path: path)]
        }
        if let dict = object as? [String: Any] {
            let nestedFiles = parseReadFiles(from: Self.readFilesObject(from: dict))
            guard nestedFiles.isEmpty else { return nestedFiles }
            if let paths = (dict["paths"] ?? dict["files"]) as? [Any] {
                return paths.compactMap { Self.pathString(from: $0) }.map {
                    LocalAlpineReadFileRequest(
                        path: $0,
                        startLine: Self.intValue(dict["start_line"] ?? dict["line_start"] ?? dict["from_line"]),
                        lineCount: Self.intValue(dict["line_count"] ?? dict["max_lines"] ?? dict["lines"]),
                        maxBytes: Self.intValue(dict["max_bytes"])
                    )
                }
            }
            guard let path = Self.pathString(from: dict) else { return [] }
            return [LocalAlpineReadFileRequest(
                path: path,
                startLine: Self.intValue(dict["start_line"] ?? dict["line_start"] ?? dict["from_line"]),
                lineCount: Self.intValue(dict["line_count"] ?? dict["max_lines"] ?? dict["lines"]),
                maxBytes: Self.intValue(dict["max_bytes"])
            )]
        }
        return []
    }

    private func parseEditFilesForCommand(from dict: [String: Any]) -> [LocalAlpineEditFileRequest] {
        parseEditFiles(from: Self.editFilesObject(from: dict))
    }

    private nonisolated static func editFilesObject(from dict: [String: Any]) -> Any? {
        if let object = dict["edit_file"] ?? dict["edit_files"] ?? dict["replace_file"] ?? dict["modify_file"] {
            return object
        }
        if pathString(from: dict) == nil,
           let object = dict["replace"] {
            return object
        }
        return nil
    }

    private func parseEditFiles(from object: Any?) -> [LocalAlpineEditFileRequest] {
        if let array = object as? [Any] {
            return array.flatMap { parseEditFiles(from: $0) }
        }
        guard let dict = object as? [String: Any] else { return [] }
        let nestedEdits = parseEditFiles(from: Self.editFilesObject(from: dict))
        guard nestedEdits.isEmpty else { return nestedEdits }
        guard let path = Self.pathString(from: dict) else { return [] }
        if Self.editRewritePayload(from: dict) != nil {
            return []
        }
        let replacements = parseEditReplacements(from: dict)
        guard !replacements.isEmpty else { return [] }
        return [LocalAlpineEditFileRequest(path: path, replacements: replacements)]
    }

    private func parseEditReplacements(from dict: [String: Any]) -> [LocalAlpineEditReplacement] {
        if let array = (dict["replacements"] ?? dict["edits"]) as? [Any] {
            return array.compactMap { parseEditReplacement(from: $0) }
        }
        return parseEditReplacement(from: dict).map { [$0] } ?? []
    }

    private func parseEditReplacement(from object: Any) -> LocalAlpineEditReplacement? {
        guard let dict = object as? [String: Any] else { return nil }

        if let range = dict["range"] as? [String: Any],
           let startLine = Self.intValue(range["start_line"] ?? range["startLine"] ?? range["line"]),
           let newText = Self.textPayload(
            from: dict,
            keys: ["text", "new_text", "new", "replacement", "replace", "with"],
            lineKeys: ["text_lines", "new_lines", "replace_lines"],
            base64Keys: ["text_base64", "new_text_base64", "new_base64"]
           ) {
            return LocalAlpineEditReplacement(
                oldText: "",
                newText: newText,
                replaceAll: false,
                expectedCount: nil,
                startLine: startLine,
                endLine: Self.intValue(range["end_line"] ?? range["endLine"])
            )
        }

        let hasExplicitWith = dict["with"] != nil || dict["to"] != nil
        let oldKeys = hasExplicitWith
            ? ["old_text", "old_string", "old", "find", "search", "before", "from", "match", "replace"]
            : ["old_text", "old_string", "old", "find", "search", "before", "from", "match"]
        let newKeys = hasExplicitWith
            ? ["new_text", "new_string", "new", "with", "to", "replacement", "after"]
            : ["new_text", "new_string", "new", "replace", "replacement", "after", "to", "with"]
        guard let oldText = Self.textPayload(
                from: dict,
                keys: oldKeys,
                lineKeys: ["old_lines", "find_lines", "before_lines"],
                base64Keys: ["old_text_base64", "old_base64"]
              ),
              let newText = Self.textPayload(
                from: dict,
                keys: newKeys,
                lineKeys: ["new_lines", "replace_lines", "after_lines"],
                base64Keys: ["new_text_base64", "new_base64"]
              ) else {
            return nil
        }
        return LocalAlpineEditReplacement(
            oldText: oldText,
            newText: newText,
            replaceAll: (dict["replace_all"] as? Bool) ?? false,
            expectedCount: Self.intValue(dict["expected_count"] ?? dict["count"])
        )
    }

    private func parseEditRewriteFilesForCommand(from dict: [String: Any]) -> [LocalAlpineAgentFile] {
        parseEditRewriteFiles(from: Self.editFilesObject(from: dict))
    }

    private func parseEditRewriteFiles(from object: Any?) -> [LocalAlpineAgentFile] {
        if let array = object as? [Any] {
            return array.flatMap { parseEditRewriteFiles(from: $0) }
        }
        guard let dict = object as? [String: Any] else { return [] }
        let nestedFiles = parseEditRewriteFiles(from: Self.editFilesObject(from: dict))
        guard nestedFiles.isEmpty else { return nestedFiles }
        guard let path = Self.pathString(from: dict),
              let payload = Self.editRewritePayload(from: dict) else { return [] }
        return [LocalAlpineAgentFile(path: path, content: payload, source: .editFile)]
    }

    private nonisolated static func editRewritePayload(from dict: [String: Any]) -> String? {
        if let replaceAllText = dict["replace_all"] as? String {
            return replaceAllText
        }
        if let payload = textPayload(
            from: dict,
            keys: ["rewrite", "content", "contents", "text", "body", "source", "data", "code"],
            lineKeys: ["rewrite_lines", "content_lines", "code_lines", "lines"],
            base64Keys: ["content_base64", "rewrite_base64", "code_base64", "base64"]
        ) {
            return payload
        }
        return nil
    }

    private func parsePatchFilesForCommand(from dict: [String: Any]) -> [LocalAlpinePatchFileRequest] {
        parsePatchFiles(from: Self.patchFilesObject(from: dict))
    }

    private nonisolated static func patchFilesObject(from dict: [String: Any]) -> Any? {
        dict["patch_file"] ?? dict["patch_files"] ?? dict["apply_patch"] ?? dict["patch"]
    }

    private func parsePatchFiles(from object: Any?) -> [LocalAlpinePatchFileRequest] {
        if let array = object as? [Any] {
            return array.flatMap { parsePatchFiles(from: $0) }
        }
        if let patch = object as? String {
            return [LocalAlpinePatchFileRequest(path: nil, patch: patch)]
        }
        if let dict = object as? [String: Any] {
            let nestedPatches = parsePatchFiles(from: Self.patchFilesObject(from: dict))
            guard nestedPatches.isEmpty else { return nestedPatches }
            guard let patch = Self.textPayload(
                from: dict,
                keys: ["patch", "diff", "unified_diff"],
                lineKeys: ["patch_lines", "diff_lines"],
                base64Keys: ["patch_base64", "diff_base64"]
            ) else { return [] }
            return [LocalAlpinePatchFileRequest(path: Self.pathString(from: dict), patch: patch)]
        }
        return []
    }

    private func parseDeleteFilesForCommand(from dict: [String: Any]) -> [LocalAlpineDeleteFileRequest] {
        parseDeleteFiles(from: Self.deleteFilesObject(from: dict))
    }

    private nonisolated static func deleteFilesObject(from dict: [String: Any]) -> Any? {
        dict["delete_file"] ?? dict["delete_files"] ?? dict["remove_file"] ?? dict["remove_files"] ?? dict["delete"] ?? dict["rm"] ?? dict["unlink"]
    }

    private func parseDeleteFiles(from object: Any?) -> [LocalAlpineDeleteFileRequest] {
        if let array = object as? [Any] {
            return array.flatMap { parseDeleteFiles(from: $0) }
        }
        if let dict = object as? [String: Any] {
            let nestedDeletes = parseDeleteFiles(from: Self.deleteFilesObject(from: dict))
            guard nestedDeletes.isEmpty else { return nestedDeletes }
            if let paths = (dict["paths"] ?? dict["files"]) as? [Any] {
                return paths.compactMap { Self.pathString(from: $0) }.map {
                    LocalAlpineDeleteFileRequest(
                        path: $0,
                        recursive: Self.boolValue(dict["recursive"] ?? dict["recurse"] ?? dict["directory"] ?? dict["dir"]) ?? false,
                        missingOK: Self.boolValue(dict["missing_ok"] ?? dict["missingOK"] ?? dict["ignore_missing"] ?? dict["force"]) ?? true
                    )
                }
            }
            guard let path = Self.pathString(from: dict) else { return [] }
            return [LocalAlpineDeleteFileRequest(
                path: path,
                recursive: Self.boolValue(dict["recursive"] ?? dict["recurse"] ?? dict["directory"] ?? dict["dir"]) ?? false,
                missingOK: Self.boolValue(dict["missing_ok"] ?? dict["missingOK"] ?? dict["ignore_missing"] ?? dict["force"]) ?? true
            )]
        }
        if let path = Self.pathString(from: object ?? "") {
            return [LocalAlpineDeleteFileRequest(path: path, recursive: false, missingOK: true)]
        }
        return []
    }

    private nonisolated static func pathString(from dict: [String: Any]) -> String? {
        let pathKeys = [
            "path", "file_path", "file", "name", "filename",
            "filepath", "filePath", "full_path", "target"
        ]
        for key in pathKeys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        for key in ["paths", "files"] {
            if let value = firstString(in: dict[key]) {
                return value
            }
        }
        return nil
    }

    private nonisolated static func pathString(from object: Any) -> String? {
        if let path = object as? String {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = object as? [String: Any] {
            return pathString(from: dict)
        }
        return nil
    }

    private nonisolated static func pathStrings(from object: Any?) -> [String] {
        guard let object else { return [] }
        if let array = object as? [Any] {
            return array.flatMap { pathStrings(from: $0) }
        }
        if let dict = object as? [String: Any],
           let paths = (dict["paths"] ?? dict["files"]) as? [Any] {
            return paths.flatMap { pathStrings(from: $0) }
        }
        if let path = pathString(from: object) {
            return [path]
        }
        return []
    }

    private nonisolated static func pathDirectory(for path: String) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return "." }
        guard let slashIndex = normalized.lastIndex(of: "/") else { return "." }
        let directory = String(normalized[..<slashIndex])
        return directory.isEmpty ? "/" : directory
    }

    private nonisolated static func pathBaseName(for path: String) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard let slashIndex = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slashIndex)...])
    }

    private nonisolated static func absentPathString(from object: Any) -> String? {
        if let dict = object as? [String: Any] {
            if let type = stringValue(dict["type"] ?? dict["check"] ?? dict["kind"])?.lowercased(),
               ["not_exists", "not_exist", "missing", "absent", "deleted", "removed"].contains(type),
               let path = pathString(from: dict) {
                return path
            }
            if boolValue(dict["exists"]) == false,
               let path = pathString(from: dict) {
                return path
            }
            for key in ["missing", "absent", "not_exists", "not_exist", "deleted", "removed"] {
                if let value = pathString(from: dict[key] as Any) {
                    return value
                }
            }
        }
        return nil
    }

    private nonisolated static func normalizedPathKey(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        if normalized.hasPrefix("/mnt/iexa/") {
            normalized = String(normalized.dropFirst("/mnt/iexa/".count))
        } else if normalized == "/mnt/iexa" {
            normalized = "."
        } else if normalized.hasPrefix("/") {
            normalized = String(normalized.dropFirst())
        }
        while normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        return normalized
    }

    private nonisolated static func normalizedGlobPattern(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("**/") {
            return String(trimmed.dropFirst(3))
        }
        if trimmed.hasPrefix("./**/") {
            return String(trimmed.dropFirst(5))
        }
        return trimmed.isEmpty ? "*" : trimmed
    }

    private nonisolated static func firstString(in value: Any?) -> String? {
        if let string = stringValue(value) {
            return string
        }
        if let array = value as? [Any] {
            return array.compactMap { stringValue($0) }.first
        }
        return nil
    }

    private nonisolated static func directoryPathString(from object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        for key in ["path", "dir", "directory", "root", "cwd", "workdir", "base"] {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        for key in ["paths", "dirs", "directories", "roots", "files"] {
            if let value = firstString(in: dict[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private nonisolated static func value(for keys: [String], in object: Any) -> Any? {
        guard let dict = object as? [String: Any] else { return nil }
        for key in keys {
            if let value = dict[key] {
                return value
            }
        }
        return nil
    }

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private nonisolated static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let string = stringValue(value),
           let data = string.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String { return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool { return boolValue }
        if let intValue = value as? Int { return intValue != 0 }
        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1", "on":
                return true
            case "false", "no", "n", "0", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private nonisolated static func textPayload(
        from dict: [String: Any],
        keys: [String],
        lineKeys: [String],
        base64Keys: [String]
    ) -> String? {
        for key in base64Keys {
            if let base64 = dict[key] as? String,
               let data = Data(base64Encoded: base64),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        for key in lineKeys {
            if let lines = dict[key] as? [String] {
                var text = lines.joined(separator: "\n")
                if (dict["append_newline"] as? Bool) ?? true, !text.hasSuffix("\n") {
                    text += "\n"
                }
                return text
            }
        }
        for key in keys {
            if let text = dict[key] as? String {
                return text
            }
        }
        return nil
    }

    private func parseWriteFilesForCommand(from dict: [String: Any]) -> [LocalAlpineAgentFile] {
        let nestedFiles = parseWriteFiles(from: Self.writeFilesObject(from: dict))
        guard nestedFiles.isEmpty else { return nestedFiles }
        return parseWriteFile(from: dict).map { [$0] } ?? []
    }

    private nonisolated static func writeFilesObject(from dict: [String: Any]) -> Any? {
        if let files = dict["files"] as? [Any],
           !files.contains(where: { file in
               guard let fileDict = file as? [String: Any] else { return false }
               return pathString(from: fileDict) == nil || writeFilePayload(from: fileDict) == nil
           }) {
            return files
        }
        return dict["write_files"] ?? dict["write_file"] ?? dict["create_file"] ?? dict["create_files"]
            ?? dict["save_file"] ?? dict["save_files"] ?? dict["files"]
    }

    private func parseWriteFiles(from object: Any?) -> [LocalAlpineAgentFile] {
        if let array = object as? [Any] {
            return array.flatMap { parseWriteFiles(from: $0) }
        }
        if let dict = object as? [String: Any] {
            let nestedFiles = parseWriteFiles(from: Self.writeFilesObject(from: dict))
            guard nestedFiles.isEmpty else { return nestedFiles }
            if let file = parseWriteFile(from: dict) {
                return [file]
            }
            return Self.writeFileMapEntries(from: dict)
        }
        return []
    }

    private nonisolated static func writeFileMapEntries(from dict: [String: Any]) -> [LocalAlpineAgentFile] {
        dict.compactMap { key, value -> LocalAlpineAgentFile? in
            let path = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty,
                  pathLooksLikeFileTarget(path),
                  let content = value as? String else {
                return nil
            }
            let source: LocalAlpineAgentFileSource = isCodeTarget(path) ? .codeLines : .content
            return LocalAlpineAgentFile(path: path, content: content, source: source)
        }
    }

    private nonisolated static func pathLooksLikeFileTarget(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.contains("\n"),
              normalized.contains(".") || normalized.hasPrefix("/") || normalized.contains("/") else {
            return false
        }
        let reserved = Set([
            "path", "file", "files", "content", "contents", "text", "body", "source",
            "data", "code", "mode", "cwd", "workdir", "args", "arguments"
        ])
        return !reserved.contains(normalized.lowercased())
    }

    private func parseWriteFile(from object: Any) -> LocalAlpineAgentFile? {
        guard let dict = object as? [String: Any] else { return nil }
        if dict["iexa_rejected_python_plain_content"] as? Bool == true,
           let path = Self.pathString(from: dict) ?? (dict["write_file"] as? String) {
            return LocalAlpineAgentFile(
                path: path,
                content: "",
                source: .rejectedPythonPlainContent
            )
        }
        guard let path = Self.pathString(from: dict) ?? (dict["write_file"] as? String),
            let payload = Self.writeFilePayload(from: dict) else {
            return nil
        }
        let source: LocalAlpineAgentFileSource = payload.source == .content && Self.isCodeTarget(path)
            ? .codeLines
            : payload.source
        return LocalAlpineAgentFile(
            path: path,
            content: payload.content,
            source: source,
            mode: Self.writeFileMode(from: dict)
        )
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
            ?? (dict["source"] as? String)
            ?? (dict["data"] as? String)
            ?? (dict["code"] as? String) {
            return (content, .content)
        }

        return nil
    }

    private nonisolated static func writeFileMode(from dict: [String: Any]) -> LocalAlpineAgentFileMode {
        let raw = stringValue(dict["mode"] ?? dict["write_mode"] ?? dict["writeMode"])
            ?? (boolValue(dict["append"]) == true ? "append" : nil)
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "append", "a", ">>":
            return .append
        default:
            return .overwrite
        }
    }

    private func writeFiles(_ files: [LocalAlpineAgentFile], cwd: String) async -> LocalAlpineWriteResult {
        var lines = ["写入文件（结构化写入）"]
        var writtenPaths: [String] = []
        var writtenFiles: [LocalAlpineWrittenFile] = []
        var lineDelta = LocalAlpineLineDelta(added: 0, deleted: 0)
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
            if let delta = outcome.lineDelta {
                lineDelta = Self.combinedLineDelta(lineDelta, delta)
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
            lineDelta: lineDelta.isEmpty ? nil : lineDelta,
            hadFailure: hadFailure
        )
    }

    private func readFiles(_ requests: [LocalAlpineReadFileRequest], cwd: String) async -> LocalAlpineStructuredToolResult {
        var lines = ["读取文件（read_file）"]
        var commandResults: [LocalAlpineAgentCommandResult] = []
        var hadFailure = false

        for request in requests.prefix(maxCommandsPerResponse) {
            let target = resolvedFilePath(request.path, cwd: cwd)
            let maxBytes = max(1, min(request.maxBytes ?? 32_000, 256_000))
            do {
                let data = try await LocalAlpineTerminalService.shared.readFile(path: target)
                let output: String
                if let content = String(data: data, encoding: .utf8) {
                    output = Self.numberedText(
                        content,
                        path: target,
                        byteCount: data.count,
                        startLine: request.startLine,
                        lineCount: request.lineCount,
                        maxBytes: maxBytes
                    )
                } else {
                    output = "== file ==\n\(target)\n\nbinary file: \(data.count) B"
                }
                lines.append(output)
                let result = LocalAlpineCommandResult(
                    command: "read_file \(target)",
                    output: output,
                    exitCode: 0,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(command: "read_file \(target)", cwd: cwd, result: result))
            } catch {
                let output = "read_file failed for `\(target)`: \(error.localizedDescription)"
                lines.append("- \(output)")
                let result = LocalAlpineCommandResult(
                    command: "read_file \(target)",
                    output: output,
                    exitCode: 1,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(command: "read_file \(target)", cwd: cwd, result: result))
                hadFailure = true
            }
        }

        let skipped = max(0, requests.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余读取请求，避免一次读取过多。")
        }

        return LocalAlpineStructuredToolResult(
            summary: lines.joined(separator: "\n\n"),
            commandResults: commandResults,
            writtenFiles: [],
            editedPaths: [],
            lineDelta: nil,
            hadFailure: hadFailure
        )
    }

    private nonisolated static func numberedText(
        _ content: String,
        path: String,
        byteCount: Int,
        startLine: Int?,
        lineCount: Int?,
        maxBytes: Int
    ) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let allLines = normalized.components(separatedBy: "\n")
        let totalLines = normalized.isEmpty ? 0 : (normalized.hasSuffix("\n") ? allLines.count - 1 : allLines.count)
        let firstLine = max(1, startLine ?? 1)
        let count = max(1, min(lineCount ?? 240, 1_000))
        let startIndex = min(max(0, firstLine - 1), max(0, totalLines))
        let endIndex = min(totalLines, startIndex + count)
        var body = (startIndex..<endIndex)
            .map { index in "\(index + 1)\t\(allLines[index])" }
            .joined(separator: "\n")
        if (body.data(using: .utf8)?.count ?? 0) > maxBytes {
            body = String(body.prefix(maxBytes)) + "\n...（read_file 输出过长，已截断）"
        }
        if body.isEmpty {
            body = "（空文件或请求范围无内容）"
        }
        return """
        == file ==
        \(path)
        bytes: \(byteCount)
        lines: \(totalLines)
        range: \(startIndex + 1)-\(endIndex)

        == content ==
        \(body)
        """
    }

    private func editFiles(_ requests: [LocalAlpineEditFileRequest], cwd: String) async -> LocalAlpineStructuredToolResult {
        var lines = ["编辑文件（edit_file）"]
        var commandResults: [LocalAlpineAgentCommandResult] = []
        var writtenFiles: [LocalAlpineWrittenFile] = []
        var editedPaths: [String] = []
        var lineDelta = LocalAlpineLineDelta(added: 0, deleted: 0)
        var hadFailure = false

        for request in requests.prefix(maxCommandsPerResponse) {
            let target = resolvedFilePath(request.path, cwd: cwd)
            do {
                let data = try await LocalAlpineTerminalService.shared.readFile(path: target)
                guard let originalContent = String(data: data, encoding: .utf8) else {
                    throw LocalAlpineAgentEditError.binaryFile(target)
                }
                var content = originalContent

                var replacementNotes: [String] = []
                for replacement in request.replacements {
                    if let startLine = replacement.startLine {
                        content = try Self.replacingLineRange(
                            startLine: startLine,
                            endLine: replacement.endLine,
                            with: replacement.newText,
                            in: content
                        )
                        let endLine = replacement.endLine ?? startLine
                        replacementNotes.append("  - 替换第 \(startLine)-\(endLine) 行。")
                        continue
                    }
                    let count = Self.occurrenceCount(of: replacement.oldText, in: content)
                    if let expected = replacement.expectedCount, count != expected {
                        throw LocalAlpineAgentEditError.unexpectedMatchCount(
                            path: target,
                            expected: expected,
                            actual: count
                        )
                    }
                    if count == 0 {
                        throw LocalAlpineAgentEditError.noMatch(path: target)
                    }
                    if !replacement.replaceAll && count != 1 {
                        throw LocalAlpineAgentEditError.ambiguousMatch(path: target, count: count)
                    }
                    content = replacement.replaceAll
                        ? content.replacingOccurrences(of: replacement.oldText, with: replacement.newText)
                        : Self.replacingFirstOccurrence(
                            of: replacement.oldText,
                            with: replacement.newText,
                            in: content
                        )
                    replacementNotes.append("  - 替换 \(replacement.replaceAll ? count : 1) 处。")
                }

                let outcome = await writeProtectedFile(
                    LocalAlpineAgentFile(path: target, content: content, source: .editFile),
                    cwd: cwd
                )
                let delta = outcome.lineDelta ?? Self.lineDelta(from: originalContent, to: content)
                lines.append("- `\(target)`")
                lines.append(contentsOf: replacementNotes)
                lines.append(contentsOf: outcome.lines.map { "  \($0)" })
                if let writtenFile = outcome.writtenFile {
                    writtenFiles.append(writtenFile)
                }
                if let writtenPath = outcome.writtenPath {
                    editedPaths.append(writtenPath)
                }
                if !outcome.hadFailure {
                    lineDelta = Self.combinedLineDelta(lineDelta, delta)
                }
                hadFailure = hadFailure || outcome.hadFailure
                let result = LocalAlpineCommandResult(
                    command: "edit_file \(target)",
                    output: outcome.lines.joined(separator: "\n"),
                    exitCode: outcome.hadFailure ? 125 : 0,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(command: "edit_file \(target)", cwd: cwd, result: result))
            } catch {
                let output = "edit_file failed for `\(target)`: \(error.localizedDescription)"
                lines.append("- \(output)")
                let result = LocalAlpineCommandResult(
                    command: "edit_file \(target)",
                    output: output,
                    exitCode: 1,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(command: "edit_file \(target)", cwd: cwd, result: result))
                hadFailure = true
            }
        }

        let skipped = max(0, requests.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余编辑请求，避免一次编辑过多。")
        }

        return LocalAlpineStructuredToolResult(
            summary: lines.joined(separator: "\n"),
            commandResults: commandResults,
            writtenFiles: writtenFiles,
            editedPaths: editedPaths,
            lineDelta: lineDelta.isEmpty ? nil : lineDelta,
            hadFailure: hadFailure
        )
    }

    private nonisolated static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private nonisolated static func replacingFirstOccurrence(
        of oldText: String,
        with newText: String,
        in content: String
    ) -> String {
        guard let range = content.range(of: oldText) else { return content }
        var updated = content
        updated.replaceSubrange(range, with: newText)
        return updated
    }

    private nonisolated static func replacingLineRange(
        startLine: Int,
        endLine: Int?,
        with newText: String,
        in content: String
    ) throws -> String {
        guard startLine > 0 else {
            throw LocalAlpineAgentEditError.patchMismatch("invalid start_line \(startLine)")
        }
        let hadTrailingNewline = content.hasSuffix("\n")
        var lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if hadTrailingNewline {
            lines.removeLast()
        }
        let startIndex = startLine - 1
        let safeEndLine = max(startLine, endLine ?? startLine)
        let endIndex = min(safeEndLine, lines.count)
        guard startIndex <= lines.count else {
            throw LocalAlpineAgentEditError.patchMismatch("start_line outside file")
        }
        let replacementLines = sourceLines(newText)
        lines.replaceSubrange(startIndex..<max(startIndex, endIndex), with: replacementLines)
        var updated = lines.joined(separator: "\n")
        if hadTrailingNewline || newText.hasSuffix("\n") {
            updated += "\n"
        }
        return updated
    }

    private func existingTextFileContent(path: String) async -> String? {
        guard let data = try? await LocalAlpineTerminalService.shared.readFile(path: path) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func lineCountBeforeDelete(path: String) async -> Int {
        guard let content = await existingTextFileContent(path: path) else {
            return 0
        }
        return Self.sourceLineCount(content)
    }

    private nonisolated static func combinedLineDelta(
        _ lhs: LocalAlpineLineDelta,
        _ rhs: LocalAlpineLineDelta
    ) -> LocalAlpineLineDelta {
        LocalAlpineLineDelta(
            added: lhs.added + rhs.added,
            deleted: lhs.deleted + rhs.deleted
        )
    }

    private nonisolated static func lineDelta(from oldContent: String, to newContent: String) -> LocalAlpineLineDelta {
        let oldLines = sourceLines(oldContent)
        let newLines = sourceLines(newContent)
        let common = longestCommonSubsequenceLength(oldLines, newLines)
        return LocalAlpineLineDelta(
            added: max(0, newLines.count - common),
            deleted: max(0, oldLines.count - common)
        )
    }

    private nonisolated static func sourceLineCount(_ content: String) -> Int {
        sourceLines(content).count
    }

    private nonisolated static func sourceLines(_ content: String) -> [String] {
        if content.isEmpty { return [] }
        var normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        if normalized.isEmpty { return [] }
        return normalized.components(separatedBy: "\n")
    }

    private nonisolated static func longestCommonSubsequenceLength(_ oldLines: [String], _ newLines: [String]) -> Int {
        guard !oldLines.isEmpty, !newLines.isEmpty else { return 0 }
        if oldLines.count * newLines.count > 250_000 {
            let oldSet = Set(oldLines)
            return newLines.reduce(into: 0) { count, line in
                if oldSet.contains(line) {
                    count += 1
                }
            }
        }

        var previous = Array(repeating: 0, count: newLines.count + 1)
        var current = previous
        for oldLine in oldLines {
            current[0] = 0
            for index in 0..<newLines.count {
                if oldLine == newLines[index] {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(previous[index + 1], current[index])
                }
            }
            swap(&previous, &current)
        }
        return previous[newLines.count]
    }

    private func patchFiles(_ requests: [LocalAlpinePatchFileRequest], cwd: String) async -> LocalAlpineStructuredToolResult {
        var lines = ["修补文件（patch_file）"]
        var commandResults: [LocalAlpineAgentCommandResult] = []
        var writtenFiles: [LocalAlpineWrittenFile] = []
        var editedPaths: [String] = []
        var lineDelta = LocalAlpineLineDelta(added: 0, deleted: 0)
        var hadFailure = false

        for request in requests.prefix(maxCommandsPerResponse) {
            do {
                let patchTarget = request.path ?? Self.pathFromUnifiedDiff(request.patch)
                guard let patchTarget, !patchTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LocalAlpineAgentEditError.missingPatchPath
                }
                let target = resolvedFilePath(patchTarget, cwd: cwd)
                let data = try await LocalAlpineTerminalService.shared.readFile(path: target)
                guard let content = String(data: data, encoding: .utf8) else {
                    throw LocalAlpineAgentEditError.binaryFile(target)
                }
                let patched = try Self.applyUnifiedDiff(request.patch, to: content)
                let outcome = await writeProtectedFile(
                    LocalAlpineAgentFile(path: target, content: patched, source: .patchFile),
                    cwd: cwd
                )
                let delta = outcome.lineDelta ?? Self.lineDelta(from: content, to: patched)
                lines.append("- `\(target)`")
                lines.append(contentsOf: outcome.lines.map { "  \($0)" })
                if let writtenFile = outcome.writtenFile {
                    writtenFiles.append(writtenFile)
                }
                if let writtenPath = outcome.writtenPath {
                    editedPaths.append(writtenPath)
                }
                if !outcome.hadFailure {
                    lineDelta = Self.combinedLineDelta(lineDelta, delta)
                }
                hadFailure = hadFailure || outcome.hadFailure
                let result = LocalAlpineCommandResult(
                    command: "patch_file \(target)",
                    output: outcome.lines.joined(separator: "\n"),
                    exitCode: outcome.hadFailure ? 125 : 0,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(command: "patch_file \(target)", cwd: cwd, result: result))
            } catch {
                let target = request.path ?? "(diff header)"
                let output = "patch_file failed for `\(target)`: \(error.localizedDescription)"
                lines.append("- \(output)")
                let result = LocalAlpineCommandResult(
                    command: "patch_file \(target)",
                    output: output,
                    exitCode: 1,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(command: "patch_file \(target)", cwd: cwd, result: result))
                hadFailure = true
            }
        }

        let skipped = max(0, requests.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余补丁请求，避免一次编辑过多。")
        }

        return LocalAlpineStructuredToolResult(
            summary: lines.joined(separator: "\n"),
            commandResults: commandResults,
            writtenFiles: writtenFiles,
            editedPaths: editedPaths,
            lineDelta: lineDelta.isEmpty ? nil : lineDelta,
            hadFailure: hadFailure
        )
    }

    private func deleteFiles(_ requests: [LocalAlpineDeleteFileRequest], cwd: String) async -> LocalAlpineStructuredToolResult {
        var lines = ["删除文件（delete_file）"]
        var commandResults: [LocalAlpineAgentCommandResult] = []
        var editedPaths: [String] = []
        var lineDelta = LocalAlpineLineDelta(added: 0, deleted: 0)
        var hadFailure = false

        for request in requests.prefix(maxCommandsPerResponse) {
            let target = resolvedFilePath(request.path, cwd: cwd)
            let command = request.recursive ? "delete_file --recursive \(target)" : "delete_file \(target)"
            do {
                let deletedLineCount = await lineCountBeforeDelete(path: target)
                let didDelete = try await LocalAlpineTerminalService.shared.deleteItem(
                    path: target,
                    recursive: request.recursive
                )
                if didDelete {
                    let output = "deleted: \(target)"
                    lines.append("- `\(target)` 已删除\(request.recursive ? "（recursive）" : "")。")
                    if deletedLineCount > 0 {
                        let delta = LocalAlpineLineDelta(added: 0, deleted: deletedLineCount)
                        lineDelta = Self.combinedLineDelta(lineDelta, delta)
                        lines.append("  - 行数变化：\(delta.displayText)")
                    }
                    editedPaths.append(target)
                    let result = LocalAlpineCommandResult(
                        command: command,
                        output: output,
                        exitCode: 0,
                        interactiveRequest: nil
                    )
                    commandResults.append(Self.commandResult(command: command, cwd: cwd, result: result))
                } else if request.missingOK {
                    let output = "missing: \(target) (ignored)"
                    lines.append("- `\(target)` 不存在，已忽略。")
                    let result = LocalAlpineCommandResult(
                        command: command,
                        output: output,
                        exitCode: 0,
                        interactiveRequest: nil
                    )
                    commandResults.append(Self.commandResult(command: command, cwd: cwd, result: result))
                } else {
                    let output = "delete_file failed for `\(target)`: file does not exist"
                    lines.append("- \(output)")
                    let result = LocalAlpineCommandResult(
                        command: command,
                        output: output,
                        exitCode: 1,
                        interactiveRequest: nil
                    )
                    commandResults.append(Self.commandResult(command: command, cwd: cwd, result: result))
                    hadFailure = true
                }
            } catch {
                let output = "delete_file failed for `\(target)`: \(error.localizedDescription)"
                lines.append("- \(output)")
                let result = LocalAlpineCommandResult(
                    command: command,
                    output: output,
                    exitCode: 1,
                    interactiveRequest: nil
                )
                commandResults.append(Self.commandResult(command: command, cwd: cwd, result: result))
                hadFailure = true
            }
        }

        let skipped = max(0, requests.count - maxCommandsPerResponse)
        if skipped > 0 {
            lines.append("- 已跳过 \(skipped) 个多余删除请求，避免一次删除过多。")
        }

        return LocalAlpineStructuredToolResult(
            summary: lines.joined(separator: "\n"),
            commandResults: commandResults,
            writtenFiles: [],
            editedPaths: editedPaths,
            lineDelta: lineDelta.isEmpty ? nil : lineDelta,
            hadFailure: hadFailure
        )
    }

    private nonisolated static func pathFromUnifiedDiff(_ patch: String) -> String? {
        if let path = pathFromCodexPatch(patch) {
            return path
        }
        let lines = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in lines where line.hasPrefix("+++ ") {
            var path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if path == "/dev/null" { continue }
            path = path.components(separatedBy: "\t").first ?? path
            if path.hasPrefix("b/") || path.hasPrefix("a/") {
                path.removeFirst(2)
            }
            return path
        }
        return nil
    }

    private nonisolated static func pathFromCodexPatch(_ patch: String) -> String? {
        let lines = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("*** Update File: ") || line.hasPrefix("*** Add File: ") {
                let marker = line.hasPrefix("*** Update File: ") ? "*** Update File: " : "*** Add File: "
                let path = String(line.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return nil
    }

    private nonisolated static func runnablePathFromNaturalRunCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("run ") || lower.hasPrefix("execute ") || lower.hasPrefix("运行 ") {
            return firstCodePath(in: trimmed)
        }
        return nil
    }

    private nonisolated static func firstCodePath(in text: String) -> String? {
        let extensions = "py|pyw|js|jsx|ts|tsx|mjs|cjs|java|c|cc|cpp|cxx|go|rs|rb|php|sh|bash|lua"
        let pattern = #"((?:/mnt/iexa/|\.{0,2}/)?[A-Za-z0-9_.@+/\-]+?\.(?:\#(extensions)))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches where match.numberOfRanges >= 2 {
            let candidate = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "`\"'“”‘’，。；：、）)]}")
                ))
            if isCodeTarget(candidate) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func applyUnifiedDiff(_ patch: String, to content: String) throws -> String {
        if patch.contains("*** Begin Patch") {
            return try applyCodexPatch(patch, to: content)
        }
        let normalizedPatch = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let patchLines = normalizedPatch.components(separatedBy: "\n")
        let hadTrailingNewline = content.hasSuffix("\n")
        var original = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if hadTrailingNewline {
            original.removeLast()
        }

        var result: [String] = []
        var originalIndex = 0
        var patchIndex = 0
        var sawHunk = false

        while patchIndex < patchLines.count {
            let line = patchLines[patchIndex]
            guard line.hasPrefix("@@ ") else {
                patchIndex += 1
                continue
            }
            sawHunk = true
            let oldStart = try Self.oldStartLine(fromHunkHeader: line)
            let copyUntil = max(0, oldStart - 1)
            guard copyUntil >= originalIndex, copyUntil <= original.count else {
                throw LocalAlpineAgentEditError.patchMismatch("hunk starts outside file")
            }
            result.append(contentsOf: original[originalIndex..<copyUntil])
            originalIndex = copyUntil
            patchIndex += 1

            while patchIndex < patchLines.count {
                let patchLine = patchLines[patchIndex]
                if patchLine.hasPrefix("@@ ") || patchLine.hasPrefix("diff ") || patchLine.hasPrefix("--- ") || patchLine.hasPrefix("+++ ") {
                    break
                }
                if patchLine.hasPrefix("\\") {
                    patchIndex += 1
                    continue
                }
                guard let marker = patchLine.first else {
                    patchIndex += 1
                    continue
                }
                let text = String(patchLine.dropFirst())
                switch marker {
                case " ":
                    guard originalIndex < original.count, original[originalIndex] == text else {
                        throw LocalAlpineAgentEditError.patchMismatch("context mismatch near original line \(originalIndex + 1)")
                    }
                    result.append(text)
                    originalIndex += 1
                case "-":
                    guard originalIndex < original.count, original[originalIndex] == text else {
                        throw LocalAlpineAgentEditError.patchMismatch("removal mismatch near original line \(originalIndex + 1)")
                    }
                    originalIndex += 1
                case "+":
                    result.append(text)
                default:
                    throw LocalAlpineAgentEditError.patchMismatch("unsupported patch line: \(patchLine)")
                }
                patchIndex += 1
            }
        }

        guard sawHunk else {
            throw LocalAlpineAgentEditError.patchMismatch("no unified diff hunk found")
        }

        result.append(contentsOf: original[originalIndex...])
        var updated = result.joined(separator: "\n")
        if hadTrailingNewline {
            updated += "\n"
        }
        return updated
    }

    private nonisolated static func applyCodexPatch(_ patch: String, to content: String) throws -> String {
        let normalizedPatch = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let patchLines = normalizedPatch.components(separatedBy: "\n")
        var minusLines: [String] = []
        var plusLines: [String] = []
        var sawChange = false

        for line in patchLines {
            if line.hasPrefix("*** ") || line.hasPrefix("@@") {
                continue
            }
            if line.hasPrefix("-") {
                minusLines.append(String(line.dropFirst()))
                sawChange = true
            } else if line.hasPrefix("+") {
                plusLines.append(String(line.dropFirst()))
                sawChange = true
            }
        }

        guard sawChange else {
            throw LocalAlpineAgentEditError.patchMismatch("no codex patch change found")
        }

        let oldText = minusLines.joined(separator: "\n")
        let newText = plusLines.joined(separator: "\n")
        if oldText.isEmpty {
            let separator = content.isEmpty || content.hasSuffix("\n") ? "" : "\n"
            return content + separator + newText + (newText.hasSuffix("\n") ? "" : "\n")
        }
        guard content.contains(oldText) else {
            throw LocalAlpineAgentEditError.patchMismatch("codex patch old text not found")
        }
        return replacingFirstOccurrence(of: oldText, with: newText, in: content)
    }

    private nonisolated static func oldStartLine(fromHunkHeader header: String) throws -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"^@@\s+-(\d+)(?:,\d+)?\s+\+\d+(?:,\d+)?\s+@@"#),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..<header.endIndex, in: header)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: header),
              let value = Int(header[range]) else {
            throw LocalAlpineAgentEditError.patchMismatch("invalid hunk header: \(header)")
        }
        return value
    }

    private func writeProtectedFile(_ file: LocalAlpineAgentFile, cwd: String) async -> LocalAlpineProtectedWriteOutcome {
        let target = resolvedFilePath(file.path, cwd: cwd)
        if Self.isPythonTarget(target), !file.source.isAllowedPythonWriteSource {
            return LocalAlpineProtectedWriteOutcome(
                lines: [
                    "- `\(target)` Python 写入已拒绝：`.py` 文件不能使用 `\(file.source.displayName)` 来源写入。请改用 `edit_file`/`patch_file` 修复原路径，或用 `write_files.code_lines` / `content_base64` 写回同一路径。目标文件未被覆盖。"
                ],
                writtenPath: nil,
                writtenFile: nil,
                lineDelta: nil,
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
                lineDelta: nil,
                hadFailure: true
            )
        }
        let originalContent = await existingTextFileContent(path: target)
        let content: String
        if file.mode == .append {
            let prefix = originalContent ?? ""
            content = prefix + file.content
        } else {
            content = file.content
        }
        guard let data = content.data(using: .utf8) else {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：内容不是有效 UTF-8"],
                writtenPath: nil,
                writtenFile: nil,
                lineDelta: nil,
                hadFailure: true
            )
        }
        if Self.isPythonTarget(target) {
            if file.source == .editFile || file.source == .patchFile {
                return await writePythonEditPatchFile(
                    data: data,
                    target: target,
                    cwd: cwd,
                    source: file.source,
                    initialNotes: writeNotes(target: target)
                )
            }
            return await writeValidatedPythonFile(
                data: data,
                target: target,
                cwd: cwd,
                source: file.source,
                initialNotes: writeNotes(target: target)
            )
        }

        let writeOutcome = await writeFileBytes(
            data: data,
            content: content,
            target: target,
            source: file.source,
            notes: writeNotes(target: target)
        )
        return writeOutcome
    }

    private nonisolated static func isPythonTarget(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".py") || lowercased.hasSuffix(".pyw")
    }

    private nonisolated static func isCodeTarget(_ path: String) -> Bool {
        let language = LocalCodeWriteGuard.language(forPath: path)
        return language != "text" && language != "markdown"
    }

    private nonisolated func writeNotes(target: String) -> [String] {
        guard Self.isCodeTarget(target) else {
            return ["按结构化写入内容原样落盘。"]
        }
        return ["代码文件按结构化 UTF-8 字节原样写入；APP 不再重排源码缩进。"]
    }

    private func writeFileBytes(
        data: Data,
        content: String,
        target: String,
        source: LocalAlpineAgentFileSource,
        notes: [String] = []
    ) async -> LocalAlpineProtectedWriteOutcome {
        let split = splitFilePath(target)
        let originalContent = await existingTextFileContent(path: target)
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
                    lineDelta: nil,
                    hadFailure: true
                )
            }
            let delta = Self.lineDelta(from: originalContent ?? "", to: content)
            var lines = ["- `\(target)` (\(data.count) B，已写入，来源：\(source.displayName))"]
            if !delta.isEmpty {
                lines.append("  - 行数变化：\(delta.displayText)")
            }
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
                lineDelta: delta.isEmpty ? nil : delta,
                hadFailure: false
            )
        } catch {
            return LocalAlpineProtectedWriteOutcome(
                lines: ["- `\(target)` 写入失败：\(error.localizedDescription)"],
                writtenPath: nil,
                writtenFile: nil,
                lineDelta: nil,
                hadFailure: true
            )
        }
    }

    private func writePythonEditPatchFile(
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
                lineDelta: nil,
                hadFailure: true
            )
        }

        let validationResult = await validatePythonContent(content, cwd: cwd)
        if validationResult.exitCode == 0 {
            let directWrite = await writeFileBytes(
                data: data,
                content: content,
                target: target,
                source: source,
                notes: initialNotes + ["Python 局部修复通过 AST 语法校验后写入。"]
            )
            guard !directWrite.hadFailure else { return directWrite }

            var lines = directWrite.lines
            lines.append("  - Python 语法校验通过。")
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: directWrite.writtenPath,
                writtenFile: directWrite.writtenFile,
                lineDelta: directWrite.lineDelta,
                hadFailure: false
            )
        }

        let directWrite = await writeFileBytes(
            data: data,
            content: content,
            target: target,
            source: source,
            notes: initialNotes + [
                "Python 局部修复已写回原路径；完整文件语法/缩进校验仍未通过，允许继续逐步修复。"
            ]
        )
        guard !directWrite.hadFailure else { return directWrite }

        var lines = directWrite.lines
        let output = validationResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            lines.append("  - Python 语法/缩进校验仍未通过：\(String(output.prefix(1_000)))")
        }
        let errorLine = Self.pythonValidationLineNumber(from: output)
        let snippet = Self.numberedPythonSnippet(content, around: errorLine, radius: 5)
        if !snippet.isEmpty {
            lines.append("  - 当前失败片段：\n\(snippet)")
        }
        lines.append("  - 下一步：继续读取并修复这个同一路径的 Python 文件，优先使用 read_file/edit_file/patch_file，然后重新验证。")

        return LocalAlpineProtectedWriteOutcome(
            lines: lines,
            writtenPath: directWrite.writtenPath,
            writtenFile: directWrite.writtenFile,
            lineDelta: directWrite.lineDelta,
            hadFailure: true
        )
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
                lineDelta: nil,
                hadFailure: true
            )
        }

        let validationResult = await validatePythonContent(content, cwd: cwd)
        guard validationResult.exitCode == 0 else {
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
            lines.append("  - 下一步：先读取目标文件，再用 edit_file、patch_file 或同路径 write_files/code_lines/content_base64 修复同一个 Python 文件，然后重新验证。")
            return LocalAlpineProtectedWriteOutcome(
                lines: lines,
                writtenPath: nil,
                writtenFile: nil,
                lineDelta: nil,
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

        var lines = directWrite.lines
        lines.append("  - Python 语法校验通过。")

        return LocalAlpineProtectedWriteOutcome(
            lines: lines,
            writtenPath: directWrite.writtenPath,
            writtenFile: directWrite.writtenFile,
            lineDelta: directWrite.lineDelta,
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

    private nonisolated static func shellSingleQuotedStatic(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func unsafeCodeFileWriteWarning(for command: String) -> String? {
        guard Self.commandWritesCodeThroughShellText(command) else { return nil }
        return """
        Unsafe code file write blocked.

        Code files are indentation/escaping-sensitive. Do not write source files through shell text redirection, heredocs, `echo`, `printf`, `cat`, `tee`, or inline writer scripts.
        Re-send the change through structured `iexa_alpine` JSON using `edit_file`, `patch_file`, or same-path `write_files` with `code_lines`, `content_lines`, or `content_base64`, then run a bounded verification command before executing it.
        """
    }

    private nonisolated static func commandsByConvertingCatHeredocWrites(
        from shell: String,
        cwd: String? = nil
    ) -> [LocalAlpineAgentCommand]? {
        let normalized = shell
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.contains(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("cat ") && trimmed.contains("<<") && trimmed.contains(">")
        }) else {
            return nil
        }

        var commands: [LocalAlpineAgentCommand] = []
        var pendingShellLines: [String] = []
        var convertedCount = 0
        var index = 0

        func flushPendingShell() {
            let shell = pendingShellLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingShellLines.removeAll(keepingCapacity: true)
            guard !shell.isEmpty, looksLikeShellBlock(shell) else { return }
            commands.append(LocalAlpineAgentCommand(command: shell, cwd: cwd))
        }

        while index < lines.count {
            let line = lines[index]
            guard let opening = catHeredocOpening(from: line) else {
                pendingShellLines.append(line)
                index += 1
                continue
            }

            var bodyLines: [String] = []
            var closingIndex: Int?
            var bodyIndex = index + 1
            while bodyIndex < lines.count {
                if lines[bodyIndex].trimmingCharacters(in: .whitespacesAndNewlines) == opening.delimiter {
                    closingIndex = bodyIndex
                    break
                }
                bodyLines.append(lines[bodyIndex])
                bodyIndex += 1
            }
            guard let closingIndex else {
                return nil
            }

            flushPendingShell()
            var content = bodyLines.joined(separator: "\n")
            if !bodyLines.isEmpty {
                content += "\n"
            }
            commands.append(LocalAlpineAgentCommand(
                command: nil,
                cwd: cwd,
                writeFiles: [
                    LocalAlpineAgentFile(
                        path: opening.path,
                        content: content,
                        source: Self.isPythonTarget(opening.path) ? .codeLines : .contentLines
                    )
                ]
            ))
            convertedCount += 1
            index = closingIndex + 1
        }

        flushPendingShell()
        return convertedCount > 0 ? commands : nil
    }

    private nonisolated static func commandsByConvertingSimpleRedirectionWrites(
        from shell: String,
        cwd: String? = nil
    ) -> [LocalAlpineAgentCommand]? {
        if let commands = commandsByConvertingPrintfFormatRedirectionWrites(from: shell, cwd: cwd) {
            return commands
        }
        let pattern = #"(?is)^\s*(?:cd\s+(['"]?)([^'"\s;&|]+)\1\s*&&\s*)?(printf|echo)(?:\s+-e)?\s+(['"])(.*?)\4\s*(?:>>?|1>)\s*(['"]?)([^'"\s;&|]+)\6(?:\s*(?:&&|;)\s*([\s\S]+))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsShell = shell as NSString
        let fullRange = NSRange(location: 0, length: nsShell.length)
        guard let match = regex.firstMatch(in: shell, range: fullRange) else { return nil }

        let cdCwd: String? = match.range(at: 2).location == NSNotFound
            ? nil
            : nsShell.substring(with: match.range(at: 2))
        let tool = nsShell.substring(with: match.range(at: 3)).lowercased()
        var content = decodeShellPrintfLiteral(nsShell.substring(with: match.range(at: 5)))
        if tool == "echo", !content.hasSuffix("\n") {
            content += "\n"
        }
        let path = nsShell.substring(with: match.range(at: 7))
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let effectiveCWD = cwd ?? cdCwd
        var commands: [LocalAlpineAgentCommand] = [
            LocalAlpineAgentCommand(
                command: nil,
                cwd: effectiveCWD,
                writeFiles: [
                    LocalAlpineAgentFile(
                        path: path,
                        content: content,
                        source: .codeLines
                    )
                ]
            )
        ]
        if match.range(at: 8).location != NSNotFound {
            let remainder = nsShell.substring(with: match.range(at: 8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                commands.append(LocalAlpineAgentCommand(command: remainder, cwd: effectiveCWD))
            }
        }
        return commands
    }

    private nonisolated static func commandsByConvertingPrintfFormatRedirectionWrites(
        from shell: String,
        cwd: String?
    ) -> [LocalAlpineAgentCommand]? {
        let pattern = #"(?is)^\s*(?:cd\s+(['"]?)([^'"\s;&|]+)\1\s*&&\s*)?printf(?:\s+-e)?\s+(['"])(%[sb](?:\\n)?)\3\s+(['"])(.*?)\5\s*(?:>>?|1>)\s*(['"]?)([^'"\s;&|]+)\7(?:\s*(?:&&|;)\s*([\s\S]+))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsShell = shell as NSString
        let fullRange = NSRange(location: 0, length: nsShell.length)
        guard let match = regex.firstMatch(in: shell, range: fullRange) else { return nil }

        let cdCwd: String? = match.range(at: 2).location == NSNotFound
            ? nil
            : nsShell.substring(with: match.range(at: 2))
        let format = nsShell.substring(with: match.range(at: 4))
        var content = decodeShellPrintfLiteral(nsShell.substring(with: match.range(at: 6)))
        if format.contains("\\n"), !content.hasSuffix("\n") {
            content += "\n"
        }
        let path = nsShell.substring(with: match.range(at: 8))
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let effectiveCWD = cwd ?? cdCwd
        var commands: [LocalAlpineAgentCommand] = [
            LocalAlpineAgentCommand(
                command: nil,
                cwd: effectiveCWD,
                writeFiles: [
                    LocalAlpineAgentFile(
                        path: path,
                        content: content,
                        source: .codeLines
                    )
                ]
            )
        ]
        if match.range(at: 9).location != NSNotFound {
            let remainder = nsShell.substring(with: match.range(at: 9))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                commands.append(LocalAlpineAgentCommand(command: remainder, cwd: effectiveCWD))
            }
        }
        return commands
    }

    private nonisolated static func decodeShellPrintfLiteral(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append("\\")
                break
            }
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
    }

    private nonisolated static func commandsByConvertingPythonHeredocWrites(
        from shell: String,
        cwd: String? = nil
    ) -> [LocalAlpineAgentCommand]? {
        let pattern = #"(?is)^\s*(?:python3?|python)\s+-\s+<<['"]?([A-Za-z0-9_]+)['"]?\s*\n([\s\S]*?)\n\1\s*(?:\n|\s)*(?:&&|;)?\s*([\s\S]*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsShell = shell as NSString
        let fullRange = NSRange(location: 0, length: nsShell.length)
        guard let match = regex.firstMatch(in: shell, range: fullRange) else { return nil }

        let script = nsShell.substring(with: match.range(at: 2))
        let remainder = match.range(at: 3).location == NSNotFound
            ? ""
            : nsShell.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)

        var commands = commandsFromPythonPathWrites(script, cwd: cwd)
        guard !commands.isEmpty else { return nil }
        if !remainder.isEmpty {
            commands.append(LocalAlpineAgentCommand(command: remainder, cwd: cwd))
        }
        return commands
    }

    private nonisolated static func commandsFromPythonPathWrites(
        _ script: String,
        cwd: String?
    ) -> [LocalAlpineAgentCommand] {
        if let command = commandFromPythonPathLiteralWrite(script, cwd: cwd) {
            return [command]
        }
        if let command = commandFromPythonPathReplaceWrite(script, cwd: cwd) {
            return [command]
        }
        return []
    }

    private nonisolated static func commandFromPythonPathLiteralWrite(
        _ script: String,
        cwd: String?
    ) -> LocalAlpineAgentCommand? {
        let pattern = #"(?is)(?:Path\s*\(\s*['"]([^'"]+)['"]\s*\)|open\s*\(\s*['"]([^'"]+)['"][^)]*\))\s*\.write_text\s*\(\s*(['"])(.*?)\3"#
        guard let match = firstRegexMatch(pattern: pattern, in: script),
              let path = regexCapture(match, in: script, at: 1) ?? regexCapture(match, in: script, at: 2),
              let rawContent = regexCapture(match, in: script, at: 4) else {
            return nil
        }
        return LocalAlpineAgentCommand(
            command: nil,
            cwd: cwd,
            writeFiles: [
                LocalAlpineAgentFile(
                    path: path,
                    content: decodeShellPrintfLiteral(rawContent),
                    source: .codeLines
                )
            ]
        )
    }

    private nonisolated static func commandFromPythonPathReplaceWrite(
        _ script: String,
        cwd: String?
    ) -> LocalAlpineAgentCommand? {
        let pathPattern = #"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*Path\s*\(\s*['"]([^'"]+)['"]\s*\)"#
        guard let pathMatch = firstRegexMatch(pattern: pathPattern, in: script),
              let variable = regexCapture(pathMatch, in: script, at: 1),
              let path = regexCapture(pathMatch, in: script, at: 2) else {
            return nil
        }
        let escapedVariable = NSRegularExpression.escapedPattern(for: variable)
        guard script.range(
            of: #"(?is)\#(escapedVariable)\s*\.write_text\s*\("#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let replacePattern = #"(?is)\.replace\s*\(\s*(['"])(.*?)\1\s*,\s*(['"])(.*?)\3\s*\)"#
        guard let replaceMatch = firstRegexMatch(pattern: replacePattern, in: script),
              let oldText = regexCapture(replaceMatch, in: script, at: 2),
              let newText = regexCapture(replaceMatch, in: script, at: 4) else {
            return nil
        }
        return LocalAlpineAgentCommand(
            command: nil,
            cwd: cwd,
            editFiles: [
                LocalAlpineEditFileRequest(
                    path: path,
                    replacements: [
                        LocalAlpineEditReplacement(
                            oldText: decodeShellPrintfLiteral(oldText),
                            newText: decodeShellPrintfLiteral(newText),
                            replaceAll: false,
                            expectedCount: nil
                        )
                    ]
                )
            ]
        )
    }

    private nonisolated static func firstRegexMatch(
        pattern: String,
        in text: String
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private nonisolated static func regexCapture(
        _ match: NSTextCheckingResult,
        in text: String,
        at index: Int
    ) -> String? {
        guard index < match.numberOfRanges,
              match.range(at: index).location != NSNotFound else {
            return nil
        }
        return (text as NSString).substring(with: match.range(at: index))
    }

    private nonisolated static func catHeredocOpening(
        from line: String
    ) -> (path: String, delimiter: String)? {
        let words = shellWords(in: line)
        guard words.first == "cat" else { return nil }

        var path: String?
        var delimiter: String?
        var index = 1
        while index < words.count {
            let word = words[index]
            if word == ">" || word == "1>" {
                let next = index + 1
                guard next < words.count else { return nil }
                path = words[next]
                index += 2
                continue
            }
            if word.hasPrefix(">"), word != ">", word != ">>" {
                path = String(word.dropFirst())
                index += 1
                continue
            }
            if word == "<<" || word == "<<-" {
                let next = index + 1
                guard next < words.count else { return nil }
                delimiter = words[next]
                index += 2
                continue
            }
            if word.hasPrefix("<<") {
                var marker = String(word.dropFirst(2))
                if marker.hasPrefix("-") {
                    marker.removeFirst()
                }
                if !marker.isEmpty {
                    delimiter = marker
                }
                index += 1
                continue
            }
            index += 1
        }

        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              let delimiter = delimiter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              !delimiter.isEmpty,
              !path.contains("*"),
              !path.contains("?"),
              !path.contains("["),
              path.lowercased().range(
                of: #"\.(?:py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonc|yaml|yml|toml|xml)$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return (path, delimiter)
    }

    private nonisolated static func shellWords(in line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
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
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private nonisolated static func commandWritesCodeThroughShellText(_ command: String) -> Bool {
        let codeFileTarget = #"(?:['"]?)[^'"\s;|&>]*\.(?:py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonc|yaml|yml|toml|xml)(?:['"]?)"#
        let redirectionWritePatterns = [
            #"(?is)\b(?:cat|printf|echo)\b[\s\S]{0,800}(?:^|[^0-9])(?:>>?|1>)\s*"# + codeFileTarget,
            #"(?is)\bcat\b\s+<<-?\s*['"]?[A-Za-z0-9_.-]+['"]?[\s\S]{0,1200}(?:^|[^0-9])(?:>>?|1>)\s*"# + codeFileTarget,
            #"(?is)(?:^|[;&|]\s*)tee\s+(?:-[A-Za-z]+\s+)*"# + codeFileTarget,
            #"(?is)\bsed\s+-i\b[\s\S]{0,600}\s+"# + codeFileTarget,
            #"(?is)\bperl\s+-pi(?:\s+-e)?\b[\s\S]{0,600}\s+"# + codeFileTarget
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
        "cargo", "deno", "env", "find", "free", "g++", "gcc", "git", "go", "grep",
        "gunzip", "gzip", "head", "id", "install", "java", "javac", "ln", "ls", "lua",
        "make", "mkdir", "mv", "nc", "node", "npm", "npx", "patch", "perl", "php",
        "pip", "pip3", "printf", "ps", "pwd", "python", "python3", "rm", "rmdir", "ruby",
        "rustc", "sed", "sh", "sleep", "sort", "tail", "tar", "tee", "test", "top",
        "touch", "tr", "uname", "uniq", "unzip", "vi", "vim", "wget", "which", "whoami",
        "xargs", "xz", "zip"
    ]

    private nonisolated static func isInstructionFence(info: String, body: String) -> Bool {
        let parsed = parsedInstructionFence(info: info, body: body)
        let token = parsed.token
        if token == "iexa_alpine" {
            return true
        }
        guard token == "json" else { return false }
        return parsed.body.contains("\"iexa_alpine\"")
    }

    private nonisolated static func parsedInstructionFence(info: String, body: String) -> (token: String, body: String) {
        let trimmedInfo = info.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedInfo.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let token = parts.first.map { String($0).lowercased() } ?? ""
        guard parts.count > 1, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (token, body)
        }
        return (token, String(parts[1]))
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

        if let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)(?:\n([\s\S]*?))?```"#, options: [.caseInsensitive]) {
            let matches = regex.matches(in: content, range: fullRange)
            for match in matches where match.numberOfRanges >= 2 {
                let info = nsContent.substring(with: match.range(at: 1))
                let body = match.numberOfRanges >= 3 && match.range(at: 2).location != NSNotFound
                    ? nsContent.substring(with: match.range(at: 2))
                    : ""
                if isInstructionFence(info: info, body: body) {
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
            return cleanedVisibleProtocolNoise(from: content)
        }

        let mutable = NSMutableString(string: content)
        for range in mergedRanges(removalRanges).sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: "")
        }

        return cleanedVisibleToolPreface(from: mutable as String)
    }

    nonisolated private static func cleanedVisibleToolPreface(from content: String) -> String {
        var cleaned = content
            .replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleanedVisibleProtocolNoise(from: cleaned)

        let handoffPatterns = [
            #"请[^\n。！？!?]{0,12}本地执行结果[^\n。！？!?]{0,100}[。！？!?]?"#,
            #"我再根据结果[^\n。！？!?]{0,100}[。！？!?]?"#,
            #"please\s+(?:send|return|provide)[^\n.?!]{0,80}(?:result|output)[^\n.?!]{0,80}[.?!]?"#
        ]
        for pattern in handoffPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                    withTemplate: ""
                )
            }
        }

        cleaned = cleaned
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sentences = visibleSentences(from: cleaned)
        guard !sentences.isEmpty else { return cleaned }

        var seen = Set<String>()
        let unique = sentences.filter { sentence in
            let key = sentence
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
                .lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
        guard let first = unique.first else { return "" }
        if unique.count == 1 {
            return first
        }
        if cleaned.contains("正在") || cleaned.localizedCaseInsensitiveContains("local alpine") {
            return first
        }
        return unique.joined(separator: " ")
    }

    nonisolated private static func cleanedVisibleProtocolNoise(from content: String) -> String {
        var cleaned = content
            .replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)

        let protocolNoisePatterns = [
            #"(?im)^\s*<?/?(?:tool|ool)?\s*`?iexa_alpine`?[^。\n.!?]*(?:does\s+not\s+exists?|not\s+exist|not\s+available)[^。\n.!?]*[。.!?]*\s*"#,
            #"(?im)^\s*[^。\n.!?]*`?iexa_alpine`?[^。\n.!?]*(?:工具不存在|不存在|不可用|无法调用|不能调用)[^。\n.!?]*[。.!?]*\s*"#,
            #"(?im)<+/?(?:tool|ool)\s*`?iexa_alpine`?[^。\n.!?]*[。.!?]*"#
        ]
        for pattern in protocolNoisePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                    withTemplate: ""
                )
            }
        }

        return cleaned
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func visibleSentences(from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[^。！？!?\n]+[。！？!?]?"#) else {
            return content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        return regex.matches(in: content, range: fullRange)
            .map { nsContent.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func instructionBlocks(from content: String) -> [String] {
        var blocks: [String] = []
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        if let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)(?:\n([\s\S]*?))?```"#, options: [.caseInsensitive]) {
            let matches = regex.matches(in: content, range: fullRange)
            for match in matches where match.numberOfRanges >= 2 {
                let info = nsContent.substring(with: match.range(at: 1))
                let rawBody = match.numberOfRanges >= 3 && match.range(at: 2).location != NSNotFound
                    ? nsContent.substring(with: match.range(at: 2))
                    : ""
                let parsed = parsedInstructionFence(info: info, body: rawBody)
                let body = parsed.body.trimmingCharacters(in: .newlines)
                if isInstructionFence(info: info, body: body) {
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
        return blocks
    }

    nonisolated private static func pseudoToolCallRanges(in content: String, includeIncomplete: Bool) -> [NSRange] {
        pseudoToolCallRangesWithPayload(in: content, includeIncomplete: includeIncomplete).map(\.full)
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
        if let markerRange {
            let afterMarker = content[markerRange.upperBound...]
            guard afterMarker.range(of: "```") == nil else {
                return nil
            }

            return NSRange(markerRange.lowerBound..<content.endIndex, in: content)
        }

        guard let fenceRange = content.range(of: "```", options: [.backwards]) else {
            return nil
        }
        let afterFence = content[fenceRange.upperBound...]
        guard afterFence.range(of: "```") == nil else { return nil }

        let parts = afterFence.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let info = parts.first.map(String.init) ?? ""
        let body = parts.count > 1 ? String(parts[1]) : ""
        let token = info
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map { String($0).lowercased() } ?? ""
        guard isPartialInstructionFenceToken(token, body: body) else {
            return nil
        }
        return NSRange(fenceRange.lowerBound..<content.endIndex, in: content)
    }

    nonisolated private static func isPartialInstructionFenceToken(_ token: String, body: String) -> Bool {
        guard !token.isEmpty else { return false }
        let instructionTokens = ["iexa_alpine", "local_alpine_exec"]
        if instructionTokens.contains(where: { $0.hasPrefix(token) || token.hasPrefix($0) }) {
            return true
        }
        if token == "json" {
            let loweredBody = body.lowercased()
            return loweredBody.contains("\"iexa")
                || loweredBody.contains("iexa_alpine")
                || loweredBody.contains("local_alpine_exec")
        }
        return false
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

private struct LocalAlpineAgentCommand: Sendable {
    let command: String?
    let cwd: String?
    let writeFiles: [LocalAlpineAgentFile]
    let readFiles: [LocalAlpineReadFileRequest]
    let editFiles: [LocalAlpineEditFileRequest]
    let patchFiles: [LocalAlpinePatchFileRequest]
    let deleteFiles: [LocalAlpineDeleteFileRequest]
    let shellToolName: String?
    let shellToolDetail: String?
    let shellToolFilePaths: [String]

    init(
        command: String?,
        cwd: String?,
        writeFiles: [LocalAlpineAgentFile] = [],
        readFiles: [LocalAlpineReadFileRequest] = [],
        editFiles: [LocalAlpineEditFileRequest] = [],
        patchFiles: [LocalAlpinePatchFileRequest] = [],
        deleteFiles: [LocalAlpineDeleteFileRequest] = [],
        shellToolName: String? = nil,
        shellToolDetail: String? = nil,
        shellToolFilePaths: [String] = []
    ) {
        self.command = command
        self.cwd = cwd
        self.writeFiles = writeFiles
        self.readFiles = readFiles
        self.editFiles = editFiles
        self.patchFiles = patchFiles
        self.deleteFiles = deleteFiles
        self.shellToolName = shellToolName
        self.shellToolDetail = shellToolDetail
        self.shellToolFilePaths = shellToolFilePaths
    }
}

private struct LocalAlpineToolCallContext: Sendable {
    let id: String
    let runId: String
    let name: String
    let title: String
    let detail: String
    let cwd: String
    let command: String?
    let filePaths: [String]
    let startedAtMs: Int64
}

private struct LocalAlpineAgentFile: Sendable {
    let path: String
    let content: String
    let source: LocalAlpineAgentFileSource
    let mode: LocalAlpineAgentFileMode

    init(
        path: String,
        content: String,
        source: LocalAlpineAgentFileSource,
        mode: LocalAlpineAgentFileMode = .overwrite
    ) {
        self.path = path
        self.content = content
        self.source = source
        self.mode = mode
    }
}

private enum LocalAlpineAgentFileMode: Sendable {
    case overwrite
    case append
}

private struct LocalAlpineReadFileRequest: Sendable {
    let path: String
    let startLine: Int?
    let lineCount: Int?
    let maxBytes: Int?

    init(path: String, startLine: Int? = nil, lineCount: Int? = nil, maxBytes: Int? = nil) {
        self.path = path
        self.startLine = startLine
        self.lineCount = lineCount
        self.maxBytes = maxBytes
    }
}

private struct LocalAlpineEditFileRequest: Sendable {
    let path: String
    let replacements: [LocalAlpineEditReplacement]
}

private struct LocalAlpineEditReplacement: Sendable {
    let oldText: String
    let newText: String
    let replaceAll: Bool
    let expectedCount: Int?
    let startLine: Int?
    let endLine: Int?

    init(
        oldText: String,
        newText: String,
        replaceAll: Bool,
        expectedCount: Int?,
        startLine: Int? = nil,
        endLine: Int? = nil
    ) {
        self.oldText = oldText
        self.newText = newText
        self.replaceAll = replaceAll
        self.expectedCount = expectedCount
        self.startLine = startLine
        self.endLine = endLine
    }
}

private struct LocalAlpinePatchFileRequest: Sendable {
    let path: String?
    let patch: String
}

private struct LocalAlpineDeleteFileRequest: Sendable {
    let path: String
    let recursive: Bool
    let missingOK: Bool
}

private enum LocalAlpineAgentFileSource: Equatable, Sendable {
    case content
    case codeLines
    case contentLines
    case contentBase64
    case heredoc
    case codeBlock
    case editFile
    case patchFile
    case rejectedPythonPlainContent

    var isAllowedPythonWriteSource: Bool {
        switch self {
        case .codeLines, .contentBase64, .codeBlock, .editFile, .patchFile:
            return true
        case .content, .contentLines, .heredoc, .rejectedPythonPlainContent:
            return false
        }
    }

    var isAllowedCodeWriteSource: Bool {
        switch self {
        case .content, .codeLines, .contentLines, .contentBase64, .codeBlock, .editFile, .patchFile:
            return true
        case .heredoc, .rejectedPythonPlainContent:
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
        case .editFile: return "edit_file"
        case .patchFile: return "patch_file"
        case .rejectedPythonPlainContent: return "rejected_python_plain_content"
        }
    }

}

private struct LocalAlpineProtectedWriteOutcome {
    let lines: [String]
    let writtenPath: String?
    let writtenFile: LocalAlpineWrittenFile?
    let lineDelta: LocalAlpineLineDelta?
    let hadFailure: Bool
}

private struct LocalAlpineWriteResult {
    let summary: String
    let writtenPaths: [String]
    let writtenFiles: [LocalAlpineWrittenFile]
    let lineDelta: LocalAlpineLineDelta?
    let hadFailure: Bool
}

private struct LocalAlpineStructuredToolResult {
    let summary: String
    let commandResults: [LocalAlpineAgentCommandResult]
    let writtenFiles: [LocalAlpineWrittenFile]
    let editedPaths: [String]
    let lineDelta: LocalAlpineLineDelta?
    let hadFailure: Bool
}

private enum LocalAlpineAgentEditError: LocalizedError {
    case binaryFile(String)
    case noMatch(path: String)
    case ambiguousMatch(path: String, count: Int)
    case unexpectedMatchCount(path: String, expected: Int, actual: Int)
    case missingPatchPath
    case patchMismatch(String)

    var errorDescription: String? {
        switch self {
        case .binaryFile(let path):
            return "`\(path)` 不是 UTF-8 文本文件。"
        case .noMatch(let path):
            return "`\(path)` 未找到 old_text，未修改文件。"
        case .ambiguousMatch(let path, let count):
            return "`\(path)` 找到 \(count) 处 old_text。为避免误改，请提供更精确上下文或设置 replace_all。"
        case .unexpectedMatchCount(let path, let expected, let actual):
            return "`\(path)` 匹配数量不符合预期：expected \(expected), actual \(actual)。"
        case .missingPatchPath:
            return "patch_file 缺少 path，且 unified diff 里没有可用的 +++ 文件路径。"
        case .patchMismatch(let detail):
            return "补丁上下文不匹配：\(detail)。"
        }
    }
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
