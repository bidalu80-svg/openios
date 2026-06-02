import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import QuickLook
import PDFKit
import MarkdownView
import os.log

// MARK: - Chat Detail View

private struct MessageShareItem: Identifiable {
    let id = UUID()
    let text: String
}

private func localAlpineContentType(for file: LocalAlpineWrittenFile) -> String {
    switch (file.fileName as NSString).pathExtension.lowercased() {
    case "py":
        return "text/x-python"
    case "swift":
        return "text/x-swift"
    case "js":
        return "text/javascript"
    case "ts":
        return "text/typescript"
    case "json":
        return "application/json"
    case "yaml", "yml":
        return "application/yaml"
    case "xml":
        return "application/xml"
    case "html", "htm":
        return "text/html"
    case "css", "scss", "sh", "md", "txt", "toml", "ini", "cfg", "conf":
        return "text/plain"
    default:
        return "application/octet-stream"
    }
}

private struct AgentActivityStep: Identifiable, Hashable {
    enum Kind: Hashable {
        case tool
        case file
        case command
        case status
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let isRunning: Bool
    let failed: Bool
    let outputPreview: String
    let file: LocalAlpineWrittenFile?
    let command: String?
    let cwd: String?

    var hasInspectablePayload: Bool {
        file != nil
            || command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isLocalStatusPlaceholder: Bool {
        kind == .status && id.hasPrefix("local-status-")
    }

    var isWebSearchStatusStep: Bool {
        guard kind == .status else { return false }
        let normalizedId = id.lowercased()
        return normalizedId.contains("web_search")
            || normalizedId.contains("websearch")
            || normalizedId.contains("browser_web_search")
            || normalizedId.contains("get_readable")
            || normalizedId.contains("readable")
    }
}

private struct AgentActivityItem: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let isStreaming: Bool
    let summary: String
    let fileCount: Int
    let commandCount: Int
    let hasFailure: Bool
    let writtenFiles: [LocalAlpineWrittenFile]
    let commandResults: [LocalAlpineAgentCommandResult]
    let toolCalls: [LocalAlpineToolCall]
    let steps: [AgentActivityStep]

    init(
        id: String,
        timestamp: Date,
        isStreaming: Bool,
        summary: String,
        fileCount: Int,
        commandCount: Int,
        hasFailure: Bool,
        writtenFiles: [LocalAlpineWrittenFile],
        commandResults: [LocalAlpineAgentCommandResult],
        toolCalls: [LocalAlpineToolCall],
        steps: [AgentActivityStep]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.summary = summary
        self.fileCount = fileCount
        self.commandCount = commandCount
        self.hasFailure = hasFailure
        self.writtenFiles = writtenFiles
        self.commandResults = commandResults
        self.toolCalls = toolCalls
        self.steps = steps
    }

    var isActive: Bool {
        isStreaming || steps.contains { $0.isRunning } || toolCalls.contains { $0.isRunning }
    }

    var completedStepCount: Int {
        let completed = steps.filter { !$0.isRunning }.count
        if completed > 0 { return completed }
        return isActive ? 0 : min(totalStepCount, 1)
    }

    var totalStepCount: Int {
        max(steps.count, 1)
    }

    var currentStepTitle: String {
        currentStep?.title ?? summary
    }

    var currentStepDetail: String {
        currentStep?.detail ?? summary
    }

    var hasConcreteSteps: Bool {
        !steps.isEmpty
    }

    var hasOnlyWebSearchStatusSteps: Bool {
        hasConcreteSteps && steps.allSatisfy(\.isWebSearchStatusStep)
    }

    var currentStep: AgentActivityStep? {
        steps.last(where: { $0.isRunning }) ?? steps.last
    }

    var currentToolCall: LocalAlpineToolCall? {
        toolCalls.last(where: { $0.isRunning }) ?? toolCalls.last
    }

    var currentStepIndex: Int {
        guard let currentStep,
              let index = steps.firstIndex(where: { $0.id == currentStep.id }) else {
            return min(max(completedStepCount, 1), totalStepCount)
        }
        return index + 1
    }

    var currentStepPreview: String {
        guard let currentStep else { return currentStepDetail }
        if !currentStep.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.previewSnippet(currentStep.outputPreview)
        }
        return Self.previewSnippet(currentStep.detail)
    }

    var currentPreviewFile: LocalAlpineWrittenFile? {
        currentStep?.file
    }

    var currentPreviewTitle: String {
        if let file = currentPreviewFile {
            return file.fileName
        }
        return currentStep?.title ?? summary
    }

    var currentPreviewSubtitle: String {
        if let file = currentPreviewFile {
            return localAlpineContentType(for: file)
        }
        return currentStep?.detail ?? summary
    }

    var currentPreviewText: String {
        if let file = currentPreviewFile {
            let lines = file.previewLines(limit: 7)
            return lines.isEmpty
                ? file.path
                : lines.map { String($0.prefix(96)) }.joined(separator: "\n")
        }
        let text = Self.multilinePreview(currentStepPreview, maxLines: 4, maxLineLength: 96)
        return text.isEmpty ? currentStepTitle : text
    }

    func limitingSteps(to maxSteps: Int) -> AgentActivityItem {
        guard maxSteps > 0, steps.count > maxSteps else { return self }

        let limitedSteps = Array(steps.suffix(maxSteps))
        let limitedFileCount = limitedSteps.filter { step in
            step.kind == .file || step.file != nil
        }.count
        let limitedCommandCount = limitedSteps.filter { step in
            step.kind == .command
                || step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.count

        return AgentActivityItem(
            id: id,
            timestamp: timestamp,
            isStreaming: isStreaming,
            summary: "最近 \(maxSteps) 个步骤",
            fileCount: limitedFileCount,
            commandCount: limitedCommandCount,
            hasFailure: limitedSteps.contains { $0.failed },
            writtenFiles: limitedSteps.compactMap(\.file),
            commandResults: commandResults,
            toolCalls: toolCalls,
            steps: limitedSteps
        )
    }

    private static func file(for call: LocalAlpineToolCall, in files: [LocalAlpineWrittenFile]) -> LocalAlpineWrittenFile? {
        guard !files.isEmpty else { return nil }
        let pathCandidates = Set(call.filePaths.map(normalizedPath(_:)))
        if let matched = files.reversed().first(where: { file in
            let normalized = normalizedPath(file.path)
            return pathCandidates.contains(normalized) || pathCandidates.contains(file.fileName)
        }) {
            return matched
        }
        return nil
    }

    private static func steps(
        toolCalls: [LocalAlpineToolCall],
        writtenFiles: [LocalAlpineWrittenFile],
        commandResults: [LocalAlpineAgentCommandResult],
        statusHistory: [ChatStatusUpdate]
    ) -> [AgentActivityStep] {
        var steps: [AgentActivityStep] = statusSteps(from: statusHistory)
        let localStatusPlaceholders = localStatusSteps(from: statusHistory)

        steps.append(contentsOf: toolCalls.map { call in
            let matchedFile = file(for: call, in: writtenFiles)
            let title = displayTitle(for: call, file: matchedFile)
            let detail = call.displayDetail
            let output = call.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AgentActivityStep(
                id: "tool-\(call.id)",
                kind: .tool,
                title: title,
                detail: detail.isEmpty ? title : detail,
                isRunning: call.isRunning,
                failed: call.failed,
                outputPreview: output,
                file: matchedFile,
                command: call.command,
                cwd: call.cwd
            )
        })

        let existingFilePaths = Set(steps.compactMap { $0.file?.path })
        for file in writtenFiles where !existingFilePaths.contains(file.path) {
            steps.append(
                AgentActivityStep(
                    id: "file-\(file.path)",
                    kind: .file,
                    title: "写入 \(file.fileName)",
                    detail: file.path,
                    isRunning: false,
                    failed: false,
                    outputPreview: file.previewLines(limit: 10).joined(separator: "\n"),
                    file: file,
                    command: nil,
                    cwd: nil
                )
            )
        }

        let existingCommands = Set(toolCalls.compactMap { call -> String? in
            let command = call.command?.trimmingCharacters(in: .whitespacesAndNewlines)
            return command?.isEmpty == false ? command : nil
        })
        for (index, result) in commandResults.enumerated() {
            let command = result.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, command.lowercased() != "write_files" else { continue }
            guard !existingCommands.contains(command) else { continue }
            steps.append(
                AgentActivityStep(
                    id: "command-\(index)-\(command.hashValue)",
                    kind: .command,
                    title: result.failed ? "命令失败" : "运行命令",
                    detail: command,
                    isRunning: false,
                    failed: result.failed,
                    outputPreview: result.outputPreview,
                    file: nil,
                    command: command,
                    cwd: result.cwd
                )
            )
        }

        let concreteSteps = steps.filter { step in
            switch step.kind {
            case .status:
                return step.hasInspectablePayload && !step.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tool:
                return step.hasInspectablePayload || !step.isRunning
            case .file, .command:
                return true
            }
        }
        return concreteSteps.isEmpty ? localStatusPlaceholders : concreteSteps
    }

    private static func statusSteps(from statusHistory: [ChatStatusUpdate]) -> [AgentActivityStep] {
        statusHistory.enumerated().compactMap { index, status in
            guard status.hidden != true else { return nil }
            let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if action.contains("local_alpine_agent") || action.contains("local_alpine_tool") {
                return nil
            }
            guard action.contains("web_search")
                    || action.contains("browser_web_search")
                    || action.contains("code_interpreter")
                    || action.contains("get_readable")
                    || action.contains("readable")
                    || action.contains("local_native_tool") else {
                return nil
            }

            let title = title(for: status, action: action)
            let detail = status.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? status.query!
                : (status.description ?? status.status ?? title)
            let output = statusPreview(status)
            return AgentActivityStep(
                id: "status-\(index)-\(action)-\(detail.hashValue)",
                kind: .status,
                title: title,
                detail: detail,
                isRunning: status.done != true,
                failed: false,
                outputPreview: output.isEmpty ? detail : output,
                file: nil,
                command: nil,
                cwd: nil
            )
        }
    }

    private static func localStatusSteps(from statusHistory: [ChatStatusUpdate]) -> [AgentActivityStep] {
        statusHistory.enumerated().compactMap { index, status in
            guard status.hidden != true else { return nil }
            let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard action == "local_alpine"
                    || action == "local_alpine_agent"
                    || action == "local_alpine_tool" else {
                return nil
            }

            let title = title(for: status, action: action)
            let detail = status.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? status.status?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? title
            return AgentActivityStep(
                id: "local-status-\(index)-\(action)-\(detail.hashValue)",
                kind: .status,
                title: title,
                detail: detail == title ? "" : detail,
                isRunning: status.done != true,
                failed: false,
                outputPreview: detail,
                file: nil,
                command: nil,
                cwd: nil
            )
        }
    }

    private static func title(for status: ChatStatusUpdate, action: String) -> String {
        let description = status.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if action.contains("readable") { return "读取搜索结果摘要" }
        if action.contains("local_alpine_agent") || action.contains("local_alpine_tool") {
            if description.contains("重新请求") { return "准备下一步" }
            if description.contains("整理回答") { return "整理本地输出" }
            if description.contains("思考下一步") { return "分析下一步" }
            if description.contains("准备执行") { return "准备执行本地命令" }
            let cleaned = description.trimmingCharacters(in: CharacterSet(charactersIn: ".。… "))
            return cleaned.isEmpty ? "运行本地工具" : cleaned
        }
        if action.contains("web_search") || action.contains("browser_web_search") {
            if description.contains("读取") || description.lowercased().contains("read") {
                return "读取搜索结果摘要"
            }
            return status.query?.isEmpty == false ? "搜索 \(status.query!)" : "搜索网页"
        }
        if action.contains("code_interpreter") { return "运行代码" }
        return description.isEmpty ? "运行工具" : description
    }

    private static func statusPreview(_ status: ChatStatusUpdate) -> String {
        var lines: [String] = []
        if !status.queries.isEmpty {
            lines.append(contentsOf: status.queries.prefix(4).map { "query: \($0)" })
        } else if let query = status.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("query: \(query)")
        }
        if let count = status.count {
            lines.append("count: \(count)")
        }
        lines.append(contentsOf: status.items.prefix(4).compactMap { item in
            item.title ?? item.link
        })
        lines.append(contentsOf: status.urls.prefix(4))
        if let description = status.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(description)
        }
        return lines.joined(separator: "\n")
    }

    static func previewSnippet(_ text: String, limit: Int = 220) -> String {
        var result = ""
        result.reserveCapacity(min(limit + 3, 256))
        var emitted = 0
        var lastWasSpace = true

        for scalar in text.unicodeScalars {
            let isSpace = scalar.value == 9
                || scalar.value == 10
                || scalar.value == 11
                || scalar.value == 12
                || scalar.value == 13
                || scalar.value == 32
            if isSpace {
                guard !lastWasSpace, emitted < limit else { continue }
                result.append(" ")
                emitted += 1
                lastWasSpace = true
                continue
            }

            guard emitted < limit else {
                result.append("...")
                return result
            }
            result.unicodeScalars.append(scalar)
            emitted += 1
            lastWasSpace = false
        }

        if result.last == " " {
            result.removeLast()
        }
        return result
    }

    static func multilinePreview(_ text: String, maxLines: Int = 4, maxLineLength: Int = 96) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxLines > 0 else { return "" }
        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let selected = Array(lines.suffix(maxLines))
        return selected
            .map { line in
                line.count > maxLineLength ? String(line.prefix(maxLineLength)) : line
            }
            .joined(separator: "\n")
    }

    static func oneLinePreview(_ text: String, limit: Int = 96) -> String {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit))
    }

    static func displayTitle(for call: LocalAlpineToolCall, file: LocalAlpineWrittenFile? = nil) -> String {
        let display = LocalAlpineToolDisplayRegistry.display(for: call.name)
        let normalizedToolName = call.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fileName: String? = {
            if let fileName = file?.fileName.trimmingCharacters(in: .whitespacesAndNewlines),
               !fileName.isEmpty {
                return fileName
            }
            guard let path = call.filePaths.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            let name = (path as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? path : name
        }()

        switch normalizedToolName {
        case "read_file", "read_files", "read", "file_read":
            return fileName.map { "读取 \($0)" } ?? "读取文件"
        case "edit_file", "edit_files", "replace_file", "edit", "patch_file", "patch_files", "apply_patch", "patch":
            return fileName.map { "编辑 \($0)" } ?? display.title
        case "write_files", "write_file", "write", "file_write":
            return fileName.map { "写入 \($0)" } ?? display.title
        case "delete_file", "delete_files", "remove_file", "remove_files", "delete", "rm", "file_delete":
            return fileName.map { "删除 \($0)" } ?? display.title
        default:
            break
        }

        let actionHaystack = [
            call.name,
            call.title,
            call.detail,
            call.command ?? ""
        ].joined(separator: " ").lowercased()
        let haystack = [
            call.name,
            call.title,
            call.detail,
            call.command ?? "",
            call.outputPreview ?? ""
        ].joined(separator: " ").lowercased()

        if haystack.contains("get_readable") || haystack.contains("readable") {
            return "读取搜索结果摘要"
        }
        if haystack.contains("web_search")
            || haystack.contains("browser search")
            || haystack.contains("search query")
            || haystack.contains("搜索") {
            return call.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "搜索网页"
                : call.detail
        }
        if actionHaystack.contains("fetch ")
            || actionHaystack.contains("navigate ")
            || actionHaystack.contains("browser:")
            || actionHaystack.contains("http://")
            || actionHaystack.contains("https://") {
            return "读取网页内容"
        }
        return call.failed ? "\(display.title)失败" : display.title
    }

    static func isActivityMessage(_ message: ChatMessage) -> Bool {
        if message.metadata?["iexa_local_alpine_result"] == "true"
            || message.metadata?["iexa_local_alpine_tool_calls"] != nil
            || message.content.hasPrefix("Local Alpine 执行结果")
            || message.model == "Local Alpine"
            || message.model == "Local Alpine Agent" {
            return true
        }
        return message.statusHistory.contains { status in
            let action = status.action?.lowercased() ?? ""
            return action == "local_alpine"
                || action == "local_alpine_agent"
                || action == "local_alpine_tool"
                || action.contains("web_search")
                || action.contains("browser_web_search")
                || action.contains("code_interpreter")
                || action.contains("get_readable")
                || action.contains("readable")
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    init?(
        message: ChatMessage,
        liveToolCalls: [LocalAlpineToolCall] = [],
        liveStatus: ChatStatusUpdate? = nil
    ) {
        if message.metadata?["iexa_local_alpine_final_summary"] != nil
            || message.metadata?["iexa_local_alpine_continuation"] == "true"
            || message.metadata?["iexa_local_alpine_missing_tool_correction"] != nil
            || message.metadata?["iexa_local_alpine_hidden_correction_parent"] == "true" {
            return nil
        }
        guard Self.isActivityMessage(message) else {
            return nil
        }
        let metadata = message.metadata
        let writtenFiles = LocalAlpineWrittenFile.decodeMetadata(metadata?["iexa_local_alpine_written_files"])
        let commandResults = LocalAlpineAgentCommandResult.decodeMetadata(metadata?["iexa_local_alpine_command_results"])
        let persistedToolCalls = LocalAlpineToolCall.decodeMetadata(metadata?["iexa_local_alpine_tool_calls"])
        let toolCalls = Self.mergedToolCalls(persisted: persistedToolCalls, live: liveToolCalls)
        let statusHistory = liveStatus.map { message.statusHistory + [$0] } ?? message.statusHistory
        let parsed = ParsedLocalAlpineResult(content: message.content, metadata: metadata)
        let visibleCommands = commandResults.filter {
            $0.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "write_files"
        }
        let hasError = parsed.hasNonZeroExit || commandResults.contains { $0.failed } || toolCalls.contains { $0.failed }
        let visibleCommandCount = visibleCommands.count
        let completedToolCalls = toolCalls.filter { !$0.isRunning }
        let fileToolCount = completedToolCalls.filter { ["read_file", "edit_file", "patch_file", "write_files"].contains($0.name) }.count
        let commandToolCount = completedToolCalls.filter { ["command", "diagnostic"].contains($0.name) }.count
        let summaryFileCount = toolCalls.isEmpty ? writtenFiles.count : fileToolCount
        let summaryCommandCount = toolCalls.isEmpty ? visibleCommandCount : commandToolCount

        self.id = message.id
        self.timestamp = message.timestamp
        self.isStreaming = message.isStreaming
        self.summary = message.isStreaming
            ? "正在处理本地任务"
            : parsed.activitySummary(
                editedFileCount: summaryFileCount == 0 ? nil : summaryFileCount,
                commandCount: summaryCommandCount == 0 ? nil : summaryCommandCount,
                hasError: hasError
            )
        self.fileCount = summaryFileCount
        self.commandCount = summaryCommandCount
        self.hasFailure = hasError
        self.writtenFiles = writtenFiles
        self.commandResults = commandResults
        self.toolCalls = toolCalls
        self.steps = Self.steps(
            toolCalls: toolCalls,
            writtenFiles: writtenFiles,
            commandResults: visibleCommands,
            statusHistory: statusHistory
        )
    }

    private static func mergedToolCalls(
        persisted: [LocalAlpineToolCall],
        live: [LocalAlpineToolCall]
    ) -> [LocalAlpineToolCall] {
        guard !live.isEmpty else { return persisted }
        var merged = persisted
        for call in live {
            if let index = merged.firstIndex(where: { $0.id == call.id }) {
                merged[index] = call
            } else {
                merged.append(call)
            }
        }
        return merged.sorted {
            if $0.startedAtMs == $1.startedAtMs {
                return $0.id < $1.id
            }
            return $0.startedAtMs < $1.startedAtMs
        }
    }

    static func mergedTurn(id: String, items: [AgentActivityItem]) -> AgentActivityItem? {
        let activeOrConcreteItems = items.filter { $0.hasConcreteSteps || $0.isActive }
        guard !activeOrConcreteItems.isEmpty else { return nil }

        var seenStepIds = Set<String>()
        var mergedSteps: [AgentActivityStep] = []
        for item in activeOrConcreteItems {
            for step in item.steps {
                let key = "\(item.id)::\(step.id)"
                guard seenStepIds.insert(key).inserted else { continue }
                mergedSteps.append(step)
            }
        }
        if mergedSteps.contains(where: { !$0.isLocalStatusPlaceholder }) {
            mergedSteps.removeAll { $0.isLocalStatusPlaceholder }
        }

        let fileCount = activeOrConcreteItems.reduce(0) { $0 + $1.fileCount }
        let commandCount = activeOrConcreteItems.reduce(0) { $0 + $1.commandCount }
        let summaryParts = [
            fileCount > 0 ? "文件 \(fileCount)" : nil,
            commandCount > 0 ? "命令 \(commandCount)" : nil
        ].compactMap { $0 }
        let isStreaming = activeOrConcreteItems.contains { $0.isActive || $0.isStreaming }

        return AgentActivityItem(
            id: id,
            timestamp: activeOrConcreteItems.map(\.timestamp).max() ?? .now,
            isStreaming: isStreaming,
            summary: summaryParts.isEmpty ? (activeOrConcreteItems.last?.summary ?? "本地步骤") : summaryParts.joined(separator: " · "),
            fileCount: fileCount,
            commandCount: commandCount,
            hasFailure: activeOrConcreteItems.contains { $0.hasFailure },
            writtenFiles: activeOrConcreteItems.flatMap(\.writtenFiles),
            commandResults: activeOrConcreteItems.flatMap(\.commandResults),
            toolCalls: activeOrConcreteItems.flatMap(\.toolCalls),
            steps: mergedSteps
        )
    }
}

struct ChatDetailView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    private static let agentFloatingPreviewStepLimit = 24
    private let logger = Logger(subsystem: "com.openui", category: "ChatDetailView")

    private let initialConversationId: String?
    private let onNewChat: (() -> Void)?
    @State private var viewModel: ChatViewModel

    // MARK: Model selector sheet
    @State private var isShowingModelSelectorSheet = false
    @State private var isShowingChatParams = false
    @AppStorage("tokenUsageInputTotal") private var tokenUsageInputTotal: Int = 0
    @AppStorage("tokenUsageOutputTotal") private var tokenUsageOutputTotal: Int = 0
    @AppStorage("tokenUsageCachedTotal") private var tokenUsageCachedTotal: Int = 0
    @AppStorage("tokenUsageImageTotal") private var tokenUsageImageTotal: Int = 0
    @AppStorage("tokenUsageImageCountTotal") private var tokenUsageImageCountTotal: Int = 0
    @AppStorage("tokenUsageVideoCountTotal") private var tokenUsageVideoCountTotal: Int = 0
    @AppStorage("tokenUsageExactMessagesTotal") private var tokenUsageExactMessagesTotal: Int = 0
    @AppStorage("tokenUsageEstimatedMessagesTotal") private var tokenUsageEstimatedMessagesTotal: Int = 0
    @AppStorage("chatWebSearchEnabled") private var chatWebSearchEnabled = false
    @State private var editingModelDetail: ModelDetail? = nil
    @State private var isLoadingModelDetail = false

    // MARK: Scroll state (iOS 18 ScrollPosition API)
    /// iOS 18+ declarative scroll position. Used with `.scrollPosition($scrollPosition)`
    /// to drive programmatic scrolling via `scrollTo(edge:)`.
    @State private var scrollPosition: ScrollPosition = .init()
    /// True when the user has manually scrolled away from the bottom.
    @State private var isScrolledUp = false
    /// Last known contentOffset.y — used to detect user-initiated upward drags.
    @State private var lastScrollOffset: CGFloat = 0
    /// Cached distance from the scroll viewport bottom to the content bottom.
    /// Tracks "near bottom" state so IME/layout changes can re-pin only when
    /// the user was already following the latest message.
    @State private var distanceFromBottom: CGFloat = 0
    /// Cached scroll content height — updated via a separate onScrollGeometryChange.
    @State private var viewState_contentHeight: CGFloat = 0
    /// Cached scroll container height — updated via a separate onScrollGeometryChange.
    @State private var viewState_containerHeight: CGFloat = 0
    /// Last time a layout/IME correction repinned the transcript.
    @State private var lastLayoutRepinTime: Date = .distantPast
    /// Keeps a newly sent turn anchored at the top of the viewport until
    /// the user explicitly follows the bottom again.
    @State private var pinCurrentTurnStartForLatestTurn = false
    /// Timestamp of the last *programmatic* scroll-to-bottom.
    /// Used both as a streaming throttle guard (prevent pump-scroll more than 10hz)
    /// and as a suppressor to prevent the offset-change handler from falsely
    /// interpreting a programmatic scroll animation as a manual upward drag.
    @State private var lastProgrammaticScrollTime: Date = .distantPast

    private static func canPreviewInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: UI state
    @State private var showCopiedToast = false
    @State private var activeActionMessageId: String?
    @State private var activeVersionIndex: [String: Int] = [:]
    @State private var assistantFeedbackVoteOverrides: [String: AssistantFeedbackVote] = [:]

    // MARK: Action event handling (dynamic input/confirmation/notification)

    /// Pending `__event_call__` input prompt waiting for user text.
    @State private var actionInputRequest: ActionInputRequest? = nil
    /// Pending `__event_call__` confirmation waiting for user yes/no.
    @State private var actionConfirmRequest: ActionConfirmRequest? = nil
    /// Toast message from `__event_emitter__` notification events.
    @State private var actionNotificationToast: String? = nil
    /// Continuation used to resume the streaming task with the user's input/confirmation response.
    @State private var actionCallContinuation: CheckedContinuation<ActionCallResponse, Never>? = nil
    /// Bound to the TextField inside the action input alert.
    @State private var actionInputText: String = ""
    @State private var speakingMessageId: String?
    @State private var ttsGeneratingMessageId: String?
    @State private var usagePopoverMessageId: String?
    @State private var sourcesSheetMessage: ChatMessage?
    @State private var randomPrompts: [SuggestedPrompt] = []
    @State private var showAgentTaskPanel = false
    @State private var agentActivitySnapshot: [AgentActivityItem] = []
    @State private var agentFloatingActivitySnapshot: AgentActivityItem?
    @State private var agentFloatingFilePreview: LocalAlpineWrittenFilePreviewItem?
    @State private var agentFloatingStepPreview: AgentFloatingStepPreviewItem?
    @State private var agentFloatingLoadingPath: String?

    private var tokenUsageTotalsSnapshot: ChatTokenUsageSnapshot {
        ChatTokenUsageSnapshot(
            inputTokens: tokenUsageInputTotal,
            outputTokens: tokenUsageOutputTotal,
            cachedTokens: tokenUsageCachedTotal,
            imageTokens: tokenUsageImageTotal,
            imageCount: tokenUsageImageCountTotal,
            videoCount: tokenUsageVideoCountTotal,
            exactUsageMessages: tokenUsageExactMessagesTotal,
            estimatedMessages: tokenUsageEstimatedMessagesTotal
        )
    }

    private var toolbarControlsMinWidth: CGFloat {
        var buttonCount = 1
        if onNewChat != nil { buttonCount += 1 }
        if viewModel.messages.isEmpty { buttonCount += 1 }
        let buttonWidth = 34
        let buttonSpacing = 2
        let horizontalPadding = 12
        let spacingWidth = max(0, buttonCount - 1) * buttonSpacing
        return CGFloat(buttonCount * buttonWidth + spacingWidth + horizontalPadding)
    }

    private var recentAgentActivityItems: [AgentActivityItem] {
        viewModel.messages
            .suffix(40)
            .compactMap { activityItem(for: $0) }
    }

    private var currentTurnAgentActivityItems: [AgentActivityItem] {
        currentTurnAgentActivityItems(includeInactive: false)
    }

    private func currentTurnAgentActivityItems(includeInactive: Bool) -> [AgentActivityItem] {
        guard viewModel.isStreaming || viewModel.streamingStore.isActive else {
            if !includeInactive { return [] }
            let messages = viewModel.messages
            guard !messages.isEmpty else { return [] }
            let lastUserIndex = messages.lastIndex(where: { $0.role == .user })
            let startIndex = lastUserIndex.map { messages.index(after: $0) } ?? messages.startIndex
            guard startIndex < messages.endIndex else { return [] }
            return messages[startIndex...]
                .compactMap { activityItem(for: $0) }
                .filter { $0.hasConcreteSteps || $0.isActive }
        }
        let messages = viewModel.messages
        guard !messages.isEmpty else { return [] }
        let lastUserIndex = messages.lastIndex(where: { $0.role == .user })
        let startIndex = lastUserIndex.map { messages.index(after: $0) } ?? messages.startIndex
        guard startIndex < messages.endIndex else { return [] }
        return messages[startIndex...]
            .compactMap { activityItem(for: $0) }
            .filter { $0.hasConcreteSteps || $0.isActive }
    }

    private var transcriptMessages: [ChatMessage] {
        viewModel.messages.filter { !shouldHideFromTranscript($0) }
    }

    private var transcriptMessageIds: [String] {
        transcriptMessages.map(\.id)
    }

    private func agentActivity(for message: ChatMessage) -> AgentActivityItem? {
        if message.metadata?["iexa_local_alpine_final_summary"] != nil {
            return mergedLocalAlpineTurnActivity(through: message)
        }
        if isLocalAlpineResultMessage(message) {
            return mergedLocalAlpineTurnActivity(through: message) ?? activityItem(for: message)
        }
        return activityItem(for: message)
    }

    private func activityItem(for message: ChatMessage) -> AgentActivityItem? {
        AgentActivityItem(
            message: message,
            liveToolCalls: viewModel.localAlpineLiveToolCalls(for: message.id),
            liveStatus: viewModel.localAlpineLiveToolStatus(for: message.id)
        )
    }

    private func mergedLocalAlpineTurnActivity(through message: ChatMessage) -> AgentActivityItem? {
        guard let endIndex = viewModel.messages.firstIndex(where: { $0.id == message.id }) else {
            return nil
        }
        let endExclusive: Array<ChatMessage>.Index = isLocalAlpineResultMessage(message)
            ? viewModel.messages.index(after: endIndex)
            : endIndex
        let priorMessages = viewModel.messages[..<endExclusive]
        let lastUserIndex = priorMessages.lastIndex(where: { $0.role == .user })
        let startIndex = lastUserIndex.map { viewModel.messages.index(after: $0) } ?? viewModel.messages.startIndex
        guard startIndex < endExclusive else { return nil }

        let turnItems = viewModel.messages[startIndex..<endExclusive]
            .compactMap { activityItem(for: $0) }
        return AgentActivityItem.mergedTurn(id: "inline-\(message.id)", items: turnItems)
    }

    private func hasLaterLocalAlpineTurnMessage(after message: ChatMessage) -> Bool {
        guard let index = viewModel.messages.firstIndex(where: { $0.id == message.id }) else {
            return false
        }
        let start = viewModel.messages.index(after: index)
        guard start < viewModel.messages.endIndex else { return false }

        for later in viewModel.messages[start...] {
            if later.role == .user { return false }
            if isLocalAlpineResultMessage(later) {
                return true
            }
            if later.metadata?["iexa_local_alpine_final_summary"] != nil {
                return later.isStreaming
                    || later.error != nil
                    || !later.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return false
    }

    private func hasLocalAlpineFinalSummary(after message: ChatMessage, requireRenderableContent: Bool) -> Bool {
        guard let index = viewModel.messages.firstIndex(where: { $0.id == message.id }) else {
            return false
        }
        let start = viewModel.messages.index(after: index)
        guard start < viewModel.messages.endIndex else { return false }

        for later in viewModel.messages[start...] {
            if later.role == .user { return false }
            guard later.metadata?["iexa_local_alpine_final_summary"] != nil else { continue }
            if !requireRenderableContent {
                return true
            }
            if later.error != nil
                || !later.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    private func hasVisibleLocalAlpineFinalSummary(after message: ChatMessage) -> Bool {
        hasLocalAlpineFinalSummary(after: message, requireRenderableContent: true)
    }

    private func localAlpineFallbackContent(for message: ChatMessage) -> String {
        guard isLocalAlpineResultMessage(message) else { return "" }
        guard !hasLocalAlpineFinalSummary(after: message, requireRenderableContent: false) else { return "" }
        if activityItem(for: message)?.hasConcreteSteps == true {
            return ""
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldShowAssistantActionBar(for message: ChatMessage) -> Bool {
        if isLocalAlpineResultMessage(message) {
            return !localAlpineFallbackContent(for: message).isEmpty
        }
        return true
    }

    private var latestVisibleAgentActivity: AgentActivityItem? {
        agentActivityWindowPreview(includeInactive: false)
    }

    private func agentActivityWindowPreview(includeInactive: Bool) -> AgentActivityItem? {
        let turnItems = currentTurnAgentActivityItems(includeInactive: includeInactive)
        let isLive = viewModel.isStreaming || viewModel.streamingStore.isActive
        if let merged = AgentActivityItem.mergedTurn(
            id: "turn-\(viewModel.messages.last?.id ?? "latest")",
            items: turnItems
        ), merged.hasConcreteSteps {
            guard includeInactive || merged.isActive || isLive else { return nil }
            return merged
        }

        guard let item = turnItems.reversed().first(where: { $0.hasConcreteSteps }) ?? turnItems.last else { return nil }
        guard includeInactive || item.isActive || isLive else { return nil }
        return item
    }

    private var visibleAgentActivityWindowPreview: AgentActivityItem? {
        if let live = agentActivityWindowPreview(includeInactive: false)?.limitingSteps(to: Self.agentFloatingPreviewStepLimit) {
            return live
        }
        return agentFloatingActivitySnapshot
    }

    private func refreshAgentFloatingActivitySnapshot(includeInactive: Bool) {
        guard let item = agentActivityWindowPreview(includeInactive: includeInactive),
              item.hasConcreteSteps else { return }
        agentFloatingActivitySnapshot = item.limitingSteps(to: Self.agentFloatingPreviewStepLimit)
    }

    private func refreshAgentActivitySnapshot() {
        agentActivitySnapshot = recentAgentActivityItems
    }

    private func openAgentTaskPanel() {
        Haptics.play(.light)
        refreshAgentActivitySnapshot()
        showAgentTaskPanel = true
    }

    private func collapseTransientAgentViewsForBackground() {
        showAgentTaskPanel = false
        agentFloatingFilePreview = nil
        agentFloatingStepPreview = nil
        agentFloatingLoadingPath = nil
    }

    @MainActor
    private func openAgentFloatingPreview(item: AgentActivityItem, initialIndex: Int) {
        guard item.hasConcreteSteps else {
            openAgentTaskPanel()
            return
        }
        Haptics.play(.light)
        agentFloatingStepPreview = AgentFloatingStepPreviewItem(
            activity: item,
            initialIndex: initialIndex
        )
    }

    private func shouldHideFromTranscript(_ message: ChatMessage) -> Bool {
        if isLocalNativeResultMessage(message) {
            return true
        }

        guard message.role == .assistant || message.role == .system else {
            return false
        }

        let metadata = message.metadata ?? [:]
        if isLocalAlpineResultMessage(message) {
            if hasVisibleLocalAlpineFinalSummary(after: message) {
                return true
            }
            if hasLaterLocalAlpineTurnMessage(after: message) {
                return true
            }
            let hasVisibleActivity = activityItem(for: message)?.hasConcreteSteps == true
            if hasVisibleActivity {
                return false
            }
            if message.isStreaming {
                return false
            }
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && messageHasProcessOnlyStatus(message)
        }
        if metadata["iexa_local_alpine_final_summary"] != nil {
            return !message.isStreaming
                && message.error == nil
                && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if metadata["iexa_local_alpine_continuation"] == "true",
           metadata["iexa_local_alpine_final_summary"] == nil {
            if metadata["iexa_local_alpine_auto_verify"] != nil
                || metadata["iexa_local_alpine_missing_tool_correction"] != nil {
                return true
            }
            if message.isStreaming {
                return false
            }
            if contentContainsLocalAlpineInstruction(message.content) {
                return true
            }
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && messageHasProcessOnlyStatus(message)
        }
        if metadata["iexa_local_alpine_hidden_tool_parent"] == "true" {
            return true
        }
        if metadata["iexa_local_alpine_auto_verify"] != nil
            || metadata["iexa_local_alpine_missing_tool_correction"] != nil
            || metadata["iexa_local_alpine_hidden_correction_parent"] == "true" {
            return true
        }
        if contentContainsLocalAlpineInstruction(message.content) {
            return true
        }
        if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !message.isStreaming,
           messageHasProcessOnlyStatus(message) {
            return true
        }
        return false
    }

    private func messageHasProcessOnlyStatus(_ message: ChatMessage) -> Bool {
        message.statusHistory.contains { status in
            let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return action == "local_alpine"
                || action == "local_alpine_agent"
                || action == "local_alpine_tool"
                || action == "local_native_tool"
        }
    }

    private func messageLatestVisibleStatusIsWebSearch(_ message: ChatMessage) -> Bool {
        guard let status = message.statusHistory.last(where: { $0.hidden != true }) else {
            return false
        }
        let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return action == "web_search"
            || action == "websearch"
            || action == "web search"
            || action == "local_alpine_web_search"
            || action == "browser_web_search"
            || action == "get_readable"
            || action.contains("readable")
    }

    private func contentContainsLocalAlpineInstruction(_ content: String) -> Bool {
        content.range(
            of: #"(?is)```[ \t]*iexa_alpine\b.*?```"#,
            options: .regularExpression
        ) != nil
    }

    private func resetTokenUsageTotals() {
        tokenUsageInputTotal = 0
        tokenUsageOutputTotal = 0
        tokenUsageCachedTotal = 0
        tokenUsageImageTotal = 0
        tokenUsageImageCountTotal = 0
        tokenUsageVideoCountTotal = 0
        tokenUsageExactMessagesTotal = 0
        tokenUsageEstimatedMessagesTotal = 0
        Haptics.play(.medium)
    }

    // MARK: Model mention (@ trigger)
    @State private var isShowingModelPicker = false
    @State private var modelPickerQuery = ""
    @State private var mentionedModel: AIModel? = nil

    // MARK: Inline edit
    @State private var editingMessageId: String?
    @State private var editingMessageText = ""
    @FocusState private var isEditFieldFocused: Bool

    // MARK: User message version navigation
    /// Tracks the active version index for user messages (edit history).
    /// -1 means the current (latest) user message content. 0...N-1 = an older version.
    @State private var activeUserVersionIndex: [String: Int] = [:]

    /// Maps assistant message ID → content override when viewing an older user version.
    /// When nil, the assistant shows its own current content.
    /// When set, the assistant displays this overridden content instead.
    @State private var assistantContentOverride: [String: String] = [:]

    // MARK: Dictation
    @State private var isDictating = false

    // MARK: Keyboard
    @State private var keyboard = KeyboardTracker()

    // MARK: Attachment pickers
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showFilePicker = false
    @State private var showPhotosPicker = false
    @State private var showAudioPicker = false
    @State private var showCameraPicker = false
    @State private var showWebURLAlert = false
    @State private var webURLInput = ""
    @State private var showReferenceChatPicker = false

    // MARK: #URL inline suggestion
    @State private var detectedWebURL: String?


    // MARK: File download & preview
    @State private var isDownloadingFile = false
    @State private var downloadedFileURL: URL?
    @State private var messageShareItem: MessageShareItem?
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""
    /// URL for QuickLook in-app file preview (PDF, images, docs, etc.)
    @State private var previewFileURL: URL?
    /// Fullscreen image browser for images visible in the current chat window.
    @State private var imageGalleryPresentation: AuthenticatedImageGalleryPresentation?
    /// Message-level file preview sheet. Keeps sent files out of message text.
    @State private var previewingMessageFile: MessageFilePreviewItem?
    /// URL for in-app webpage preview from assistant markdown links.
    @State private var previewWebURL: WebPreviewURL?
    /// Code preview from MarkdownView's eye button (fullscreen code view)
    @State private var codePreviewCode: String?
    @State private var codePreviewLanguage: String = ""

    // MARK: Init

    init(conversationId: String, viewModel: ChatViewModel, onNewChat: (() -> Void)? = nil) {
        self.initialConversationId = conversationId
        self.onNewChat = onNewChat
        self._viewModel = State(initialValue: viewModel)
    }

    init(viewModel: ChatViewModel, onNewChat: (() -> Void)? = nil) {
        self.initialConversationId = nil
        self.onNewChat = onNewChat
        self._folderWorkspace = nil
        self._viewModel = State(initialValue: viewModel)
    }

    // MARK: - Folder Workspace Init

    /// Creates a ChatDetailView in "folder workspace" mode.
    /// When `folderWorkspace` is set, the welcome/empty state shows the folder
    /// icon + name centered (matching the web UI). New chats are created inside
    /// the folder with its system prompt injected.
    init(viewModel: ChatViewModel, folderWorkspace: ChatFolder?, onNewChat: (() -> Void)? = nil) {
        self.initialConversationId = nil
        self.onNewChat = onNewChat
        self._folderWorkspace = folderWorkspace
        self._viewModel = State(initialValue: viewModel)
    }

    private var _folderWorkspace: ChatFolder?

    private var ambientBackgroundMode: ChatAmbientBackgroundMode {
        let isFirstTurn = viewModel.messages.count <= 2
        guard isFirstTurn else { return .normal }
        return hasActiveFirstTurnStream ? .activeFirstTurn : .idleFirstTurn
    }

    private var hasActiveFirstTurnStream: Bool {
        viewModel.isStreaming
            || viewModel.streamingStore.isActive
            || viewModel.messages.last(where: { $0.role == .assistant })?.isStreaming == true
    }

    // MARK: - Body

    var body: some View {
        @Bindable var vm = viewModel

        let localAlpineInputRequestBinding = Binding(
            get: { vm.localAlpineInputRequest },
            set: { if $0 == nil, vm.localAlpineInputRequest != nil { vm.cancelLocalAlpineInput() } }
        )
        let localAlpineInputTextBinding = Binding(
            get: { vm.localAlpineInputText },
            set: { vm.localAlpineInputText = $0 }
        )
        let localAlpineConfirm: () -> Void = {
            vm.submitLocalAlpineInput(vm.localAlpineInputText)
        }
        let localAlpineCancel: () -> Void = {
            vm.cancelLocalAlpineInput()
        }

        let baseView = ZStack {
            ChatAmbientBackgroundView(mode: ambientBackgroundMode)
            messageListArea
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editingMessageId != nil {
                editInputBar
            } else {
                inputFieldArea(vm: vm)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }

        let lifecycleView = baseView
        .task {
            keyboard.start()
            if let manager = dependencies.conversationManager {
                viewModel.configure(with: manager, socket: dependencies.socketService, store: dependencies.activeChatStore, asr: dependencies.asrService)
            }
            // Perform non-async setup before awaiting load() so the UI
            // populates prompts and temporary-chat state instantly.
            if viewModel.isNewConversation {
                viewModel.isTemporaryChat = UserDefaults.standard.bool(forKey: "temporaryChatDefault")
            }
            randomPrompts = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: viewModel.selectedModel?.suggestionPrompts,
                count: promptCardCount
            )
            NotificationService.shared.activeConversationId =
                viewModel.conversationId ?? viewModel.conversation?.id
        await viewModel.load()
        // After messages load, ensure we're pinned to the latest message and
        // scroll to the bottom. The 60ms delay lets the ScrollView finish
        // laying out the newly-populated content before we issue the scroll.
        let loadedCount = viewModel.messages.count
        if loadedCount > 0 {
            isScrolledUp = false
            pinCurrentTurnStartForLatestTurn = false
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms layout settle
            scrollPosition.scrollTo(edge: .bottom)
        }
        await viewModel.fetchPinnedModels()
        // Rebuild prompts after load() — models are now fetched with fresh
            // suggestion_prompts from the server. The pre-load resolve above
            // uses cached data for instant display; this post-load resolve
            // ensures prompts reflect the latest server state.
            randomPrompts = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: viewModel.selectedModel?.suggestionPrompts,
                count: promptCardCount
            )
        }
        // Reactive fallback: if backendConfig wasn't ready when .task ran
        // (first app launch), rebuild prompts as soon as the config arrives.
        // Watch the suggestion count (Int?) — always Equatable, avoids
        // asking the type-checker to diff the entire BackendConfig struct.
        .onChange(of: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions?.count) { _, _ in
            // Always rebuild when the server config changes — this handles both the
            // first-launch timing case (randomPrompts is empty) AND the case where
            // the admin updates suggestions on the server while the app is running.
            randomPrompts = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: viewModel.selectedModel?.suggestionPrompts,
                count: promptCardCount
            )
        }
        // Also rebuild prompts when the selected model changes — the new model may
        // have per-model suggestion_prompts that should show as a fallback when the
        // admin hasn't set global prompts.
        .onChange(of: viewModel.selectedModelId) { _, _ in
            randomPrompts = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: viewModel.selectedModel?.suggestionPrompts,
                count: promptCardCount
            )
        }
        .onAppear {
            viewModel.syncOnEntry()
        }
        .onDisappear {
            keyboard.stop()
            // Stop TTS playback and clear state when navigating away from chat
            if speakingMessageId != nil || ttsGeneratingMessageId != nil {
                dependencies.textToSpeechService.stop()
                speakingMessageId = nil
                ttsGeneratingMessageId = nil
            }
            NotificationService.shared.activeConversationId = nil
        }
        // Stop TTS when app enters background to prevent Metal GPU crashes
        // and keep the speakingMessageId state in sync with actual playback.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            viewModel.persistLifecycleConversationSnapshot()
            collapseTransientAgentViewsForBackground()
            if speakingMessageId != nil || ttsGeneratingMessageId != nil {
                dependencies.textToSpeechService.stop()
                speakingMessageId = nil
                ttsGeneratingMessageId = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            viewModel.persistLifecycleConversationSnapshot()
            collapseTransientAgentViewsForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            viewModel.restoreLifecycleConversationSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            collapseTransientAgentViewsForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatTokenUsageDidAccumulate)) { notification in
            tokenUsageInputTotal += notification.userInfo?["input"] as? Int ?? 0
            tokenUsageOutputTotal += notification.userInfo?["output"] as? Int ?? 0
            tokenUsageCachedTotal += notification.userInfo?["cached"] as? Int ?? 0
            tokenUsageImageTotal += notification.userInfo?["image"] as? Int ?? 0
            tokenUsageImageCountTotal += notification.userInfo?["imageCount"] as? Int ?? 0
            tokenUsageVideoCountTotal += notification.userInfo?["videoCount"] as? Int ?? 0
            tokenUsageExactMessagesTotal += notification.userInfo?["exact"] as? Int ?? 0
            tokenUsageEstimatedMessagesTotal += notification.userInfo?["estimated"] as? Int ?? 0
        }

        let presentationView = lifecycleView
        // Toasts & banners
        .overlay(alignment: .top) {
            if showCopiedToast { copiedToastView }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                errorBannerView(error)
                    .padding(.bottom, keyboard.height + 80)
            }
        }
        // Sheets & alerts
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { urls in
                Task {
                    for url in urls {
                        let ext = url.pathExtension.lowercased()
                        let audioExts = ["mp3","wav","m4a","aac","flac","ogg","caf","aiff","wma"]
                        if audioExts.contains(ext) {
                            await processAudioFileURL(url)
                        } else {
                            await processFileURL(url)
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView { image in processCameraImage(image) }
                .ignoresSafeArea()
        }
        .alert("添加网页链接", isPresented: $showWebURLAlert) {
            TextField("https://example.com", text: $webURLInput)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocapitalization(.none)
            Button("取消", role: .cancel) { webURLInput = "" }
            Button("添加") { processWebURL() }
        } message: {
            Text("输入网址后，Iexa 会把网页内容作为上下文附加到下一条消息。")
        }
        .onChange(of: selectedPhotos) { _, newItems in
            Task { await processSelectedPhotos(newItems); selectedPhotos = [] }
        }
        // Pick up files shared from other apps via "Open In" / document import.
        // The version counter fires this even when the view is already visible.
        .onChange(of: dependencies.pendingIncomingFileVersion) { _, _ in
            if let file = dependencies.pendingIncomingFile {
                viewModel.attachments.append(file)
                // Trigger immediate upload for shared files (via "Open In")
                viewModel.uploadAttachmentImmediately(attachmentId: file.id)
                dependencies.pendingIncomingFile = nil
            }
        }
        .sheet(item: $sourcesSheetMessage) { message in
            SourcesDetailSheet(sources: message.sources)
        }
        .sheet(isPresented: $showAgentTaskPanel, onDismiss: {
            agentActivitySnapshot = []
        }) {
            AgentTaskPanelView(items: agentActivitySnapshot)
                .themed()
        }
        .sheet(item: $agentFloatingFilePreview) { item in
            LocalAlpineWrittenFilePreviewSheet(item: item)
                .themed()
        }
        .sheet(item: $agentFloatingStepPreview) { item in
            AgentFloatingStepPreviewSheet(item: item)
                .themed()
        }
        .sheet(item: $previewWebURL) { item in
            InAppWebPreviewSheet(url: item.url)
                .themed()
        }
        .sheet(item: $previewingMessageFile) { item in
            MessageFilePreviewSheet(file: item.file, apiClient: dependencies.apiClient)
                .themed()
        }
        .fullScreenCover(item: $imageGalleryPresentation) { presentation in
            FullScreenImageGalleryView(
                items: presentation.items,
                initialItemId: presentation.initialItemId,
                apiClient: dependencies.apiClient
            )
        }
        // Prompt variable input sheet — shown when a selected prompt has {{variables}}
        .sheet(isPresented: Binding<Bool>(
            get: { viewModel.pendingPromptForVariables != nil },
            set: { if !$0 { viewModel.cancelPromptVariables() } }
        )) {
            if let prompt = viewModel.pendingPromptForVariables {
                PromptVariableSheet(
                    promptName: prompt.name,
                    variables: viewModel.pendingPromptVariables,
                    onSave: { values in
                        viewModel.submitPromptVariables(values: values)
                    },
                    onCancel: {
                        viewModel.cancelPromptVariables()
                    }
                )
            }
        }
        // Intercept link taps from MarkdownView: download server file URLs
        // with auth instead of opening Safari (the user may not be logged in
        // to the browser). MarkdownView posts a notification instead of
        // calling UIApplication.shared.open directly, so we can route the
        // URL through our authenticated download flow.
        .onReceive(NotificationCenter.default.publisher(for: .markdownLinkTapped)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            let urlString = url.absoluteString
            let base = viewModel.serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // Server file URL → download with auth token and present share sheet
            if !base.isEmpty, urlString.hasPrefix(base), urlString.contains("/api/v1/files/"),
               urlString.hasSuffix("/content") {
                let parts = urlString.split(separator: "/")
                if let filesIdx = parts.firstIndex(of: "files"),
                   filesIdx + 1 < parts.count {
                    let fileId = String(parts[filesIdx + 1])
                    Task { await downloadAndShareFile(fileId: fileId) }
                    return
                }
            }

            if isDownloadableMediaURL(url) {
                Task { await downloadAndShareRemoteFile(url: url, suggestedName: suggestedFileName(from: url)) }
                return
            }

            if Self.canPreviewInApp(url) {
                previewWebURL = WebPreviewURL(url: url)
                return
            }

            UIApplication.shared.open(url)
        }
        // Handle sendPrompt bridge calls from InlineVisualizerView.
        // Populates the chat input and sends immediately — same pattern as suggestion taps.
        .onReceive(NotificationCenter.default.publisher(for: .vizSendPrompt)) { notification in
            guard let text = notification.userInfo?["text"] as? String, !text.isEmpty else { return }
            if viewModel.isStreaming {
                // Queue the prompt — set input but don't send while the model is busy
                viewModel.inputText = text
            } else {
                viewModel.inputText = text
                Task { await viewModel.sendMessage() }
            }
        }
        .overlay {
            if isDownloadingFile {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("下载中…")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.white)
                    }
                    .padding(Spacing.lg)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .alert("下载失败", isPresented: $showDownloadError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(downloadErrorMessage)
        }
        // MARK: Action event modifiers (input dialog, confirmation, notification toast)
        .applyActionEventModifiers(
            actionInputRequest: $actionInputRequest,
            actionConfirmRequest: $actionConfirmRequest,
            actionNotificationToast: $actionNotificationToast,
            actionCallContinuation: $actionCallContinuation,
            actionInputText: $actionInputText,
            localAlpineInputRequest: localAlpineInputRequestBinding,
            localAlpineInputText: localAlpineInputTextBinding,
            onLocalAlpineConfirm: localAlpineConfirm,
            onLocalAlpineCancel: localAlpineCancel
        )
        .sheet(item: $downloadedFileURL) { url in
            ShareSheetView(activityItems: [url])
        }
        .sheet(item: $messageShareItem) { item in
            ShareSheetView(activityItems: [item.text])
        }
        // In-app file preview using QuickLook (PDFs, images, docs, etc.)
        .quickLookPreview($previewFileURL)
        // Chat advanced parameters sheet (slider icon in toolbar)
        .sheet(isPresented: $isShowingChatParams) {
            ChatAdvancedParamsSheet(
                params: Binding(
                    get: { viewModel.conversation?.chatParams ?? viewModel.pendingChatParams ?? ChatAdvancedParams() },
                    set: { newParams in
                        if viewModel.conversation != nil {
                            viewModel.conversation?.chatParams = newParams
                        } else {
                            viewModel.pendingChatParams = newParams
                        }
                    }
                ),
                tokenUsage: tokenUsageTotalsSnapshot,
                onResetTokenUsage: resetTokenUsageTotals
            )
            .themed()
        }
        .sheet(item: $editingModelDetail) { detail in
            NavigationStack {
                ModelEditorView(existingModel: detail) { _ in
                    Task { viewModel.refreshModelsInBackground() }
                    editingModelDetail = nil
                }
            }
            .themed()
        }
        .applyWidgetAndPickerHandlers(
            showCameraPicker: $showCameraPicker,
            showPhotosPicker: $showPhotosPicker,
            showFilePicker: $showFilePicker,
            showWebURLAlert: $showWebURLAlert,
            selectedPhotos: $selectedPhotos,
            codePreviewCode: $codePreviewCode,
            codePreviewLanguage: $codePreviewLanguage,
            onDismissOverlays: { dismissAllPickers() }
        )

        return presentationView
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: Spacing.sm) {
                modelSelectorButton
            }
            // Force SwiftUI to fully re-layout the toolbar principal slot when
            // the selected model changes. Without this, the toolbar caches the
            // intrinsic width from the previous (possibly longer) model name
            // and never shrinks back even when a shorter name is selected.
            .id(viewModel.selectedModelId ?? "none")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            HStack(spacing: 2) {
                if let onNewChat {
                    Button {
                        onNewChat()
                    } label: {
                        NewConversationIcon(size: 18)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新对话")
                }
                Button {
                    Haptics.play(.light)
                    isShowingChatParams = true
                } label: {
                    SettingsGearIcon()
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle((viewModel.conversation?.chatParams != nil || viewModel.pendingChatParams != nil) ? theme.brandPrimary : theme.textTertiary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chat parameters")
                if viewModel.messages.isEmpty {
                    Button {
                        withAnimation(MicroAnimation.snappy) {
                            viewModel.isTemporaryChat.toggle()
                        }
                        Haptics.play(.light)
                    } label: {
                        TemporaryChatIcon(isEnabled: viewModel.isTemporaryChat, size: 18)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.isTemporaryChat ? "Temporary chat on" : "Temporary chat off")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minWidth: toolbarControlsMinWidth, minHeight: 40)
            .iexaToolbarGlass(cornerRadius: 20, compact: true)
            .clipShape(Capsule(style: .continuous))
        }
    }

    private var modelSelectorButton: some View {
        Group {
            if viewModel.availableModels.isEmpty {
                Text(viewModel.conversation?.title ?? String(localized: "新对话"))
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Button {
                    Haptics.play(.light)
                    viewModel.refreshModelsInBackground()
                    isShowingModelSelectorSheet = true
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if let model = viewModel.selectedModel {
                            ModelAvatar(
                                size: 21,
                                imageURL: viewModel.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: viewModel.serverAuthToken
                            )
                            .fixedSize()
                        }
                        Text(viewModel.selectedModel?.shortName ?? String(localized: "选择模型"))
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40)
                    .iexaToolbarGlass(cornerRadius: 22, compact: true)
                    .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingModelSelectorSheet) {
                    ModelSelectorSheet(
                        models: viewModel.availableModels,
                        selectedModelId: viewModel.selectedModelId,
                        serverBaseURL: viewModel.serverBaseURL,
                        authToken: viewModel.serverAuthToken,
                        isAdmin: dependencies.authViewModel.currentUser?.role == .admin,
                        pinnedModelIds: viewModel.pinnedModelIds,
                        onEdit: dependencies.authViewModel.currentUser?.role == .admin ? { model in
                            isShowingModelSelectorSheet = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await openModelEditorFromPicker(model)
                            }
                        } : nil,
                        onTogglePin: { modelId in
                            viewModel.togglePinModel(modelId)
                        },
                        onSelect: { model in
                            withAnimation(MicroAnimation.snappy) {
                                viewModel.selectModel(model.id)
                            }
                        }
                    )
                    .themed()
                    .presentationBackgroundInteraction(.disabled)
                    .onDisappear {
                        Task { await ImageCacheService.shared.clearMemory() }
                    }
                }
            }
        }
        // Cap the model selector width so long names truncate
        // instead of pushing into trailing toolbar buttons.
        .frame(maxWidth: 220)
    }

    // MARK: - Input Field Area

    private var temporaryChatPillForeground: Color {
        theme.isDark ? theme.brandPrimary : theme.brandPrimary.blend(with: .black, amount: 0.25)
    }

    @ViewBuilder
    private func inputFieldArea(vm: ChatViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            // Picker overlays — rendered above the input field so input stays visible
            if let url = detectedWebURL {
                webURLSuggestionPill(url: url)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if vm.isShowingKnowledgePicker {
                KnowledgePickerView(
                    query: vm.knowledgeSearchQuery,
                    items: vm.knowledgeItems,
                    isLoading: vm.isLoadingKnowledge,
                    keyboardHeight: keyboard.height,
                    onSelect: { item in
                        viewModel.selectKnowledgeItem(item)
                    },
                    onDismiss: {
                        viewModel.dismissKnowledgePicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if vm.isShowingPromptPicker {
                PromptPickerView(
                    query: vm.promptSearchQuery,
                    prompts: vm.availablePrompts,
                    isLoading: vm.isLoadingPrompts,
                    keyboardHeight: keyboard.height,
                    onSelect: { prompt in
                        viewModel.selectPrompt(prompt)
                    },
                    onDismiss: {
                        viewModel.dismissPromptPicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if vm.isShowingSkillPicker {
                SkillPickerView(
                    query: vm.skillSearchQuery,
                    skills: vm.availableSkills,
                    isLoading: vm.isLoadingSkills,
                    keyboardHeight: keyboard.height,
                    onSelect: { skill in
                        viewModel.selectSkill(skill)
                    },
                    onDismiss: {
                        viewModel.dismissSkillPicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if isShowingModelPicker {
                ModelPickerView(
                    query: modelPickerQuery,
                    models: vm.availableModels,
                    serverBaseURL: vm.serverBaseURL,
                    authToken: vm.serverAuthToken,
                    keyboardHeight: keyboard.height,
                    onSelect: { model in
                        withAnimation(.easeOut(duration: 0.15)) {
                            mentionedModel = model
                            viewModel.mentionedModelId = model.id
                        }
                        viewModel.removeMentionToken()
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                        Haptics.play(.light)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            // ── Task List Panel (above input field) ──
            if !vm.tasks.isEmpty {
                TaskListView(
                    tasks: vm.tasks,
                    isStreaming: vm.isStreaming,
                    onToggleStatus: { taskId, newStatus in
                        viewModel.updateTaskStatus(taskId: taskId, newStatus: newStatus)
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if let item = visibleAgentActivityWindowPreview, item.hasConcreteSteps {
                AgentStepFloatingBar(
                    item: item,
                    taskCount: item.totalStepCount,
                    onOpenAgentLog: openAgentTaskPanel,
                    onPreviewTap: { item, index in
                        openAgentFloatingPreview(item: item, initialIndex: index)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            ChatInputField(
                text: $vm.inputText,
                attachments: $vm.attachments,
                placeholder: placeholderText,
                isEnabled: !vm.isStreaming || vm.canSendWhileStreaming,
                onSend: { Task { await viewModel.sendMessage() } },
                onStopGenerating: vm.isStreaming ? { viewModel.stopStreaming() } : nil,
                contextBudgetStatus: vm.contextBudgetStatus,
                onContextBudgetPreviewUpdate: { viewModel.updateLiveContextBudgetPreview() },
                webSearchEnabled: $vm.webSearchEnabled,
                imageGenerationEnabled: $vm.imageGenerationEnabled,
                codeInterpreterEnabled: $vm.codeInterpreterEnabled,
                isWebSearchAvailable: chatWebSearchEnabled,
                isImageGenerationAvailable: dependencies.authViewModel.featurePermissions.imageGeneration && isFeatureAvailable("image_generation", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableImageGeneration),
                isCodeInterpreterAvailable: dependencies.authViewModel.featurePermissions.codeInterpreter && isFeatureAvailable("code_interpreter", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableCodeInterpreter),
                tools: vm.availableTools,
                selectedToolIds: $vm.selectedToolIds,
                isLoadingTools: vm.isLoadingTools,
                terminalEnabled: vm.terminalEnabled,
                isTerminalAvailable: !vm.availableTerminalServers.isEmpty,
                terminalServerName: vm.selectedTerminalServer?.displayName ?? "",
                availableTerminalServers: vm.availableTerminalServers,
                onTerminalToggle: { viewModel.toggleTerminal() },
                onTerminalServerSelected: { server in
                    viewModel.selectedTerminalServer = server
                },
                onBrowseFiles: nil,
                mentionedModel: $mentionedModel,
                mentionedModelImageURL: mentionedModel.flatMap { viewModel.resolvedImageURL(for: $0) },
                mentionedModelAuthToken: viewModel.serverAuthToken,
                onAtTrigger: { query in
                    modelPickerQuery = query
                    if !isShowingModelPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isShowingModelPicker = true
                        }
                        viewModel.refreshModelsInBackground()
                    }
                },
                onAtDismiss: {
                    if isShowingModelPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                    }
                },
                selectedKnowledgeItems: $vm.selectedKnowledgeItems,
                selectedReferenceChats: $vm.selectedReferenceChats,
                onHashTrigger: { query in
                    // Detect if the query looks like a URL → show inline suggestion pill
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("www.") {
                        // Dismiss knowledge picker if it was showing
                        if viewModel.isShowingKnowledgePicker {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissKnowledgePicker()
                            }
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            detectedWebURL = trimmed
                        }
                    } else {
                        // Not a URL → normal knowledge picker behavior
                        if detectedWebURL != nil {
                            withAnimation(.easeOut(duration: 0.15)) {
                                detectedWebURL = nil
                            }
                        }
                        viewModel.knowledgeSearchQuery = query
                        if !viewModel.isShowingKnowledgePicker {
                            withAnimation(.easeOut(duration: 0.2)) {
                                viewModel.isShowingKnowledgePicker = true
                            }
                            viewModel.loadKnowledgeItems()
                        }
                    }
                },
                onHashDismiss: {
                    if detectedWebURL != nil {
                        withAnimation(.easeOut(duration: 0.15)) {
                            detectedWebURL = nil
                        }
                    }
                    if viewModel.isShowingKnowledgePicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissKnowledgePicker()
                        }
                    }
                },
                onSlashTrigger: { query in
                    viewModel.promptSearchQuery = query
                    if !viewModel.isShowingPromptPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.isShowingPromptPicker = true
                        }
                        viewModel.loadPrompts()
                    }
                },
                onSlashDismiss: {
                    if viewModel.isShowingPromptPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissPromptPicker()
                        }
                    }
                },
                onDollarTrigger: { query in
                    viewModel.skillSearchQuery = query
                    if !viewModel.isShowingSkillPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.isShowingSkillPicker = true
                        }
                        viewModel.loadSkills()
                    }
                },
                onDollarDismiss: {
                    if viewModel.isShowingSkillPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissSkillPicker()
                        }
                    }
                },
                onFileAttachment: { showFilePicker = true },
                onPhotoAttachment: { showPhotosPicker = true },
                onCameraCapture: { showCameraPicker = true },
                onWebAttachment: { showWebURLAlert = true },
                onReferenceChatAttachment: { showReferenceChatPicker = true },
                onVoiceInput: { toggleVoiceInput() },
                onDictationStart: { startDictation() },
                onDictationStop: { stopDictation() },
                onDictationCancel: { cancelDictation() },
                isDictating: isDictating,
                dictationService: dependencies.dictationService,
                onToolsSheetPresented: {
                    Task { await viewModel.loadTools() }
                }
            )
        }
        .animation(.easeOut(duration: 0.2), value: vm.isShowingKnowledgePicker)
        .animation(.easeOut(duration: 0.15), value: vm.selectedKnowledgeItems.count)
        .animation(.easeOut(duration: 0.15), value: vm.selectedReferenceChats.count)
        .animation(.easeOut(duration: 0.25), value: vm.tasks.count)
        .sheet(isPresented: $showReferenceChatPicker) {
            ReferenceChatPickerView(
                isPresented: $showReferenceChatPicker,
                conversationManager: dependencies.conversationManager
            ) { item in
                viewModel.selectReferenceChat(item)
            }
        }
        // Sync mentionedModel → viewModel.mentionedModelId when user taps × on chip
        .onChange(of: mentionedModel) { _, newModel in
            viewModel.mentionedModelId = newModel?.id
        }
    }

    private var photoPickerLabel: some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [theme.brandPrimary.opacity(0.2), theme.brandPrimary.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 36, height: 36)
                Image(systemName: "photo")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
            Text("图片")
                .scaledFont(size: 12, weight: .medium)
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var placeholderText: String {
        if let model = viewModel.selectedModel {
            return "询问 \(model.shortName)"
        }
        return "发送消息"
    }

    /// Checks whether a feature (web_search, image_generation, code_interpreter)
    /// should be visible in the tools sheet. A feature is available only when:
    /// 1. The server-level feature flag is enabled (from `/api/config`), AND
    /// 2. The selected model has that capability enabled (from `info.meta.capabilities`).
    ///
    /// If the admin unchecks a capability on the model, the toggle disappears
    /// from the app — the model simply can't use it.
    private func isFeatureAvailable(_ capabilityKey: String, serverEnabled: Bool?) -> Bool {
        // Server must have the feature enabled globally
        guard serverEnabled == true else { return false }
        // Model must have the capability enabled
        guard let model = viewModel.selectedModel else {
            return serverEnabled == true
        }
        if capabilityKey == "image_generation" && model.supportsImageGeneration {
            return true
        }
        if model.defaultFeatureIds.contains(capabilityKey) || model.builtinTools[capabilityKey] == true {
            return true
        }
        guard let caps = model.capabilities,
              let value = caps[capabilityKey] else {
            // If model has no capabilities dict at all, default to showing
            // (backward compat — older servers may not send capabilities)
            return serverEnabled == true
        }
        return ["1", "true"].contains(value.lowercased())
    }
    
    // MARK: - iPad Layout Helpers

    /// Maximum reading width for iPad. Content is centered in the available space.
    /// On iPhone, this is effectively unlimited (fills the screen).
    private var iPadMaxContentWidth: CGFloat { .infinity }

    /// Number of columns in the welcome prompt grid.
    private var promptColumnCount: Int {
        horizontalSizeClass == .regular ? 4 : 2
    }

    /// Number of prompt cards to show (4 cols needs 8, 2 cols needs 4).
    private var promptCardCount: Int {
        horizontalSizeClass == .regular ? 8 : 4
    }

    // MARK: - Message List Area

    private var messageListArea: some View {
        ZStack {
            scrollContent

            // Welcome screen — shown when no messages and not loading
            if !viewModel.isLoadingConversation && viewModel.messages.isEmpty {
                if let folder = _folderWorkspace {
                    folderWelcomeView(folder: folder)
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                } else {
                    welcomeView
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }
        }
        // FAB overlay
        .overlay(alignment: .bottomTrailing) {
            scrollToBottomFAB
        }
        .onAppear {
            // Snap instantly to bottom on chat open.
            scrollPosition.scrollTo(edge: .bottom)
        }
        // Keep agent activity state in sync with hidden/system messages.
        // Actual transcript scrolling is driven by transcriptMessageIds below,
        // because Local Alpine can append messages that are not rendered.
        .onChange(of: viewModel.messages.count) { old, new in
            guard new > old else { return }
            if viewModel.messages.last?.role == .user {
                agentFloatingActivitySnapshot = nil
            } else {
                refreshAgentFloatingActivitySnapshot(includeInactive: !viewModel.isStreaming && !viewModel.streamingStore.isActive)
            }
        }
        // Auto-scroll only when the rendered transcript changes. This avoids
        // scrolling to blank spacer space when hidden agent/tool messages are
        // appended or removed behind the visible conversation.
        .onChange(of: transcriptMessageIds) { oldIds, newIds in
            guard !newIds.isEmpty else { return }
            let tailChanged = oldIds.last != newIds.last || newIds.count > oldIds.count
            guard tailChanged else { return }

            // ── ALWAYS bring the new visible turn into view ──
            // No matter where the user is scrolled, sending a message must
            // bring the new message into view. Re-engage auto-scroll so the
            // response streams in below it.
            isScrolledUp = false
            lastProgrammaticScrollTime = Date()

            let latestVisibleRole = transcriptMessages.last?.role
            if latestVisibleRole == .user {
                pinCurrentTurnStartForLatestTurn = true
                if keyboard.isVisible {
                    if oldIds.isEmpty {
                        repinToCurrentTurnStartIfFollowing(after: 0.06)
                        repinToCurrentTurnStartIfFollowing(after: 0.18)
                    } else {
                        repinToCurrentTurnStartIfFollowing(after: 0.06)
                        repinToCurrentTurnStartIfFollowing(after: 0.18)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.28)) {
                        scrollToCurrentTurnStart(anchor: .top)
                    }
                }
            } else if oldIds.isEmpty && !keyboard.isVisible {
                // First visible assistant/content in a new chat — smooth ease-out.
                pinCurrentTurnStartForLatestTurn = false
                withAnimation(.easeOut(duration: 0.3)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else if keyboard.isVisible {
                // Keep the keyboard in place and pin the turn start, not the
                // ScrollView edge, so the viewport cannot land on spacer-only
                // space while the input bar is settling.
                repinToCurrentTurnStartIfFollowing(after: 0.06)
                repinToCurrentTurnStartIfFollowing(after: 0.18)
            } else if pinCurrentTurnStartForLatestTurn {
                smoothRepinToCurrentTurnStartIfFollowing(after: 0.04)
            } else {
                // Keyboard already hidden (follow-ups, etc.) — scroll now.
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
        // Streaming: when streaming starts, only clear the scrolledUp flag
        // if the user is already near the bottom. If they've manually
        // scrolled up, respect that position and don't yank them back.
        .onChange(of: viewModel.isStreaming) { _, streaming in
            if streaming && !isScrolledUp {
                refreshAgentFloatingActivitySnapshot(includeInactive: false)
                // Already following the turn. If the keyboard is visible, or
                // the assistant placeholder has not become visible yet, keep
                // the user-sent turn start pinned instead of jumping to the
                // ScrollView bottom.
                if pinCurrentTurnStartForLatestTurn {
                    scrollToCurrentTurnStartWithoutAnimation(anchor: .top)
                } else if viewModel.messages.count <= 2 {
                    scrollToLatestMessageWithoutAnimation(anchor: .bottom)
                } else if keyboard.isVisible || transcriptMessages.last?.role == .user {
                    scrollToCurrentTurnStartWithoutAnimation(anchor: .top)
                } else {
                    scrollToLatestMessageWithoutAnimation(anchor: .bottom)
                }
            } else if !streaming {
                refreshAgentFloatingActivitySnapshot(includeInactive: true)
            }
        }
        .onChange(of: viewModel.streamingStore.isActive) { _, active in
            if active {
                refreshAgentFloatingActivitySnapshot(includeInactive: false)
            } else {
                refreshAgentFloatingActivitySnapshot(includeInactive: true)
            }
        }
        // Resume auto-scroll: when the user scrolls back to the bottom
        // (or taps the FAB) during an active stream, re-pin so new
        // tokens keep the view anchored at the bottom.
        .onChange(of: isScrolledUp) { oldValue, newValue in
            if oldValue == true && newValue == false && viewModel.isStreaming {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: keyboard.height) { oldHeight, height in
            guard abs(height - oldHeight) > 1, !viewModel.messages.isEmpty else { return }
            let maxValidOffset = max(0, viewState_contentHeight - viewState_containerHeight)
            let offsetIsPastContent = lastScrollOffset > maxValidOffset + 24
            let wasFollowingBottom = !isScrolledUp || distanceFromBottom <= 140 || offsetIsPastContent
            guard wasFollowingBottom else { return }
            isScrolledUp = false

            // Opening the keyboard should not force the transcript to the
            // bottom. With the last-turn spacer that can align blank spacer
            // space into the viewport, making the conversation look empty
            // until the user drags. Repin to the last real message instead
            // of the ScrollView's edge while the keyboard is visible.
            let settleDelay = max(0.12, keyboard.animationDuration + 0.08)
            if offsetIsPastContent {
                forceRepinToPinnedTranscriptTarget(after: 0.01)
                forceRepinToPinnedTranscriptTarget(after: settleDelay)
                forceRepinToPinnedTranscriptTarget(after: settleDelay + 0.18)
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isLoadingConversation {
                    loadingPlaceholders
                } else {
                    messagesList
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: iPadMaxContentWidth)
            .frame(maxWidth: .infinity)
            .transaction { $0.animation = nil }
        }
        .background(ScrollViewHorizontalLock())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(editingMessageId != nil ? .never : .interactively)
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition, anchor: .bottom)
        // Detect scroll position to show/hide FAB + auto-load pagination
        .onScrollGeometryChange(for: CGPoint.self) { geo in
            geo.contentOffset
        } action: { _, newOffset in
            let distanceFromBottom = max(0,
                viewState_contentHeight - newOffset.y - viewState_containerHeight)
            self.distanceFromBottom = distanceFromBottom
            if distanceFromBottom <= 100 {
                // User scrolled very close to the bottom — re-engage auto-scroll.
                if isScrolledUp { isScrolledUp = false }
            } else {
                // Suppress false "user scrolled up" detection after any programmatic
                // scroll. The scroll animation itself causes the offset to momentarily
                // move in various directions, which would otherwise trigger
                // isScrolledUp = true and break auto-scroll for streaming.
                let timeSinceProgrammatic = Date().timeIntervalSince(lastProgrammaticScrollTime)
                // During streaming the scroll pump fires every 0.1 s, so we use a
                // shorter suppression window (0.15 s) to still catch animation bounce
                // from each pump cycle, while giving the user a window to register
                // an intentional upward drag.  Outside streaming, keep 0.6 s.
                let suppressionWindow: TimeInterval = viewModel.isStreaming ? 0.15 : 0.6
                // A strong upward drag (>30 pt in one callback) is unambiguously
                // intentional — bypass the time guard entirely so it registers
                // immediately even during the 0.1 s scroll-pump interval.
                let dragDelta = lastScrollOffset - newOffset.y  // positive = upward
                let isStrongDrag = dragDelta > 30
                if !isStrongDrag {
                    guard timeSinceProgrammatic > suppressionWindow else { return }
                }

                // During active streaming, any upward movement at all breaks out
                // immediately so the scroll pump can't fight the user's finger.
                // Outside of streaming, require a small but intentional drag (8pt)
                // to avoid accidental break-out from bounce/inertia.
                let threshold: CGFloat = viewModel.isStreaming ? 2 : 8
                if newOffset.y < lastScrollOffset - threshold {
                    if !isScrolledUp { isScrolledUp = true }
                }
            }
            if abs(newOffset.y - lastScrollOffset) > 2 {
                lastScrollOffset = newOffset.y
            }
        }
        .onScrollGeometryChange(for: CGSize.self) { geo in
            CGSize(width: geo.contentSize.height, height: geo.containerSize.height)
        } action: { oldSize, newSize in
            let oldContentHeight = viewState_contentHeight
            let contentChanged = abs(newSize.width - viewState_contentHeight) > 1
            let containerChanged = abs(newSize.height - viewState_containerHeight) > 1
            if contentChanged {
                viewState_contentHeight = newSize.width
            }
            if containerChanged {
                viewState_containerHeight = newSize.height
            }

            // Correct IME and layout drift whenever the viewport is known to
            // be outside the real content. During keyboard resize, keep the
            // active target stable instead of switching between turn-start
            // and bottom anchors.
            let maxValidOffset = max(0, newSize.width - newSize.height)
            let offsetIsPastContent = lastScrollOffset > maxValidOffset + 24
            if (contentChanged || containerChanged), offsetIsPastContent {
                let now = Date()
                if now.timeIntervalSince(lastLayoutRepinTime) > 0.08 {
                    lastLayoutRepinTime = now
                    forceRepinToPinnedTranscriptTarget(after: 0.01)
                }
            }

            // Smooth scroll-to-bottom during active streaming:
            // When the content height grows (new tokens pushed layout taller)
            // and the user hasn't scrolled up, animate to the bottom so new
            // content slides in smoothly instead of snapping.
            let grew = newSize.width > oldContentHeight + 1
            if grew && viewModel.isStreaming && !isScrolledUp && !pinCurrentTurnStartForLatestTurn {
                let now = Date()
                if now.timeIntervalSince(lastProgrammaticScrollTime) > 0.2 {
                    lastProgrammaticScrollTime = now
                    if keyboard.height > 1 {
                        scrollToLatestMessageWithoutAnimation(anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scroll-to-Bottom FAB

    @ViewBuilder
    private var scrollToBottomFAB: some View {
        if (isScrolledUp || (pinCurrentTurnStartForLatestTurn && distanceFromBottom > 100))
            && !viewModel.messages.isEmpty
            && !viewModel.isLoadingConversation {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                Circle()
                    .strokeBorder(theme.cardBorder.opacity(0.35), lineWidth: 0.5)
                    .frame(width: 38, height: 38)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
            }
            .contentShape(Circle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    // Disengage auto-scroll lock first so the streaming pump
                    // doesn't fight the scroll animation we're about to start.
                    pinCurrentTurnStartForLatestTurn = false
                    isScrolledUp = false
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                    Haptics.play(.light)
                }
            )
            .padding(.trailing, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.7).combined(with: .opacity),
                    removal: .scale(scale: 0.7).combined(with: .opacity)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7))
            )
            .accessibilityLabel("Scroll to bottom")
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - Loading Placeholders

    private var loadingPlaceholders: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                SkeletonChatMessage(isUser: i % 2 == 1, lineCount: i == 0 ? 2 : i == 2 ? 3 : 2)
                    .padding(.vertical, 4)
            }
        }
        .padding(.top, Spacing.lg)
    }

    // MARK: - Messages List

    private var lastTurnMinHeight: CGFloat {
        let containerHeight = max(viewState_containerHeight, 0)
        guard containerHeight > 1 else { return 0 }

        // Keep the last turn filling the currently visible ScrollView
        // viewport. Collapsing this while the keyboard is visible makes the
        // transcript jump because SwiftUI keeps the old scroll offset while
        // the content height changes.
        return containerHeight
    }

    private func scrollToBottomWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func scrollToLatestMessageWithoutAnimation(anchor: UnitPoint = .bottom) {
        guard let lastMessageId = transcriptMessages.last?.id else {
            scrollToBottomWithoutAnimation()
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(id: lastMessageId, anchor: anchor)
        }
    }

    private func scrollToCurrentTurnStart(anchor: UnitPoint = .top) {
        let turnStartId = transcriptMessages.last(where: { $0.role == .user })?.id
            ?? transcriptMessages.last?.id
        guard let turnStartId = turnStartId else {
            scrollToBottomWithoutAnimation()
            return
        }
        scrollPosition.scrollTo(id: turnStartId, anchor: anchor)
    }

    private func scrollToCurrentTurnStartWithoutAnimation(anchor: UnitPoint = .top) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollToCurrentTurnStart(anchor: anchor)
        }
    }

    private func repinToLatestMessageIfFollowing(after delay: TimeInterval = 0) {
        let action = {
            guard !viewModel.messages.isEmpty, !isScrolledUp else { return }
            lastProgrammaticScrollTime = Date()
            scrollToLatestMessageWithoutAnimation(anchor: .bottom)
        }
        if delay <= 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private func forceRepinToLatestMessage(after delay: TimeInterval = 0) {
        let action = {
            guard !transcriptMessages.isEmpty else { return }
            isScrolledUp = false
            lastProgrammaticScrollTime = Date()
            scrollToLatestMessageWithoutAnimation(anchor: .bottom)
        }
        if delay <= 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private func forceRepinToPinnedTranscriptTarget(after delay: TimeInterval = 0) {
        let action = {
            if pinCurrentTurnStartForLatestTurn {
                guard !transcriptMessages.isEmpty else { return }
                isScrolledUp = false
                lastProgrammaticScrollTime = Date()
                scrollToCurrentTurnStartWithoutAnimation(anchor: .top)
            } else {
                guard !transcriptMessages.isEmpty else { return }
                isScrolledUp = false
                lastProgrammaticScrollTime = Date()
                scrollToLatestMessageWithoutAnimation(anchor: .bottom)
            }
        }
        if delay <= 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private func smoothRepinToCurrentTurnStartIfFollowing(after delay: TimeInterval = 0) {
        let action = {
            guard pinCurrentTurnStartForLatestTurn, !transcriptMessages.isEmpty, !isScrolledUp else { return }
            lastProgrammaticScrollTime = Date()
            withAnimation(.easeOut(duration: 0.22)) {
                scrollToCurrentTurnStart(anchor: .top)
            }
        }
        if delay <= 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private func repinToCurrentTurnStartIfFollowing(after delay: TimeInterval = 0) {
        let action = {
            guard !transcriptMessages.isEmpty, !isScrolledUp else { return }
            lastProgrammaticScrollTime = Date()
            scrollToCurrentTurnStartWithoutAnimation(anchor: .top)
        }
        if delay <= 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    /// Splits messages into two groups around the last conversation turn.
    ///
    /// The **last turn** is defined as the last user message plus any
    /// assistant/system messages that follow it. This group is wrapped in a
    /// `VStack` with `minHeight: viewportHeight, alignment: .top` — the
    /// ChatGPT-style trick that makes scroll-to-bottom place the user's
    /// sent message near the **top** of the viewport, with the AI response
    /// streaming in below it.
    ///
    /// All earlier messages render at their natural height.
    private var messagesList: some View {
        let messages = transcriptMessages

        let indexMap = Dictionary(messages.enumerated().map { ($1.id, $0) },
                                  uniquingKeysWith: { first, _ in first })

        // Split point: index of the last user message within the rendered list.
        // Everything from here to the end is the "last turn".
        // If there are no user messages, splitAt == count → no split, all normal.
        let lastUserIdx = messages.lastIndex(where: { $0.role == .user })
        let splitAt = lastUserIdx ?? messages.count

        return Group {
            // ── Messages before the last turn (natural height) ──
            ForEach(Array(messages.prefix(splitAt))) { message in
                let index = indexMap[message.id] ?? 0
                messageRow(message: message, index: index)
                    .id(message.id)
            }

            // ── Last turn (user msg + assistant reply) with minHeight ──
            if splitAt < messages.count {
                VStack(spacing: 0) {
                    ForEach(Array(messages.suffix(from: splitAt))) { message in
                        let index = indexMap[message.id] ?? 0
                        messageRow(message: message, index: index)
                            .id(message.id)
                    }
                }
                .frame(minHeight: lastTurnMinHeight, alignment: .top)
            }
        }
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(message: ChatMessage, index: Int) -> some View {
        let lastVisibleMessageId = transcriptMessages.last?.id
        let isLastAssistant = message.role == .assistant && message.id == lastVisibleMessageId
        let userTextIsEmpty = message.role == .user
            && activeUserDisplayContent(for: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {

            // ── Assistant header (avatar + model name) ──
            if message.role == .assistant {
                assistantHeader(for: message)
            }

            if message.role == .user {
                userAttachmentArea(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
                    .contextMenu { messageContextMenu(for: message) }
            }

            if message.role == .assistant {
                agentStepPreview(for: message)
            }

            // ── Streaming status indicators ──
            if message.role == .assistant
                && !isLocalAlpineResultMessage(message)
                && !hasAgentToolPreview(for: message)
                && !messageHasProcessOnlyStatus(message) {
                IsolatedStreamingStatus(
                    streamingStore: viewModel.streamingStore,
                    message: message
                )
            }

            // ── Message bubble / content ──
            if !userTextIsEmpty {
                messageBubble(for: message, isLastAssistant: isLastAssistant)
            }

            // ── Tool-generated images ──
            if message.role == .assistant && !message.isStreaming {
                let vIdx = activeVersionIndex[message.id] ?? -1
                let displayFiles: [ChatMessageFile] = {
                    if vIdx >= 0 && vIdx < message.versions.count {
                        return message.versions[vIdx].files
                    }
                    return message.files
                }()
                if !displayFiles.isEmpty {
                    messageFilesView(files: displayFiles)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)
                }
            }

            // ── Sources bar ──
            if message.role == .assistant
                && !message.isStreaming
                && !messageLatestVisibleStatusIsWebSearch(message) {
                let vIdx = activeVersionIndex[message.id] ?? -1
                let displaySources: [ChatSourceReference] = {
                    if vIdx >= 0 && vIdx < message.versions.count {
                        return message.versions[vIdx].sources
                    }
                    return message.sources
                }()
                if !displaySources.isEmpty {
                    sourcesBar(sources: displaySources, messageId: message.id)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)
                }
            }

            // ── Inline error ──
            if let error = message.error {
                messageErrorView(
                    error.content ?? String(localized: "An error occurred"),
                    retryMessageId: message.id
                )
                    .padding(.horizontal, Spacing.screenPadding)
            }

            // ── Assistant action bar (always visible) ──
            if message.role == .assistant && !message.isStreaming && shouldShowAssistantActionBar(for: message) {
                assistantActionBar(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
                    .padding(.bottom, Spacing.sm)
                    // Popover must live at the row level (not inside the ForEach action bar)
                    // so that every message gets its own independent popover anchor.
                    // Attaching it inside assistantActionBar (which is called inside ForEach)
                    // causes SwiftUI to only register the last one.
                    .popover(isPresented: Binding(
                        get: { usagePopoverMessageId == message.id },
                        set: { if !$0 { usagePopoverMessageId = nil } }
                    ), arrowEdge: .bottom) {
                        let vIdx = activeVersionIndex[message.id] ?? -1
                        let popoverUsage: [String: Any] = {
                            if vIdx >= 0 && vIdx < message.versions.count {
                                return message.versions[vIdx].usage ?? [:]
                            }
                            return message.usage ?? [:]
                        }()
                        UsageInfoPopover(usage: popoverUsage)
                            .themed()
                            .presentationCompactAdaptation(.popover)
                    }
            }

            // ── User message version arrows (always visible when edit history exists) ──
            if message.role == .user && !message.versions.isEmpty && !viewModel.isStreaming {
                userVersionSwitcher(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, 2)
            }

            // ── Follow-up suggestions (last assistant message only) ──
            if isLastAssistant && !message.isStreaming {
                let vIdx = activeVersionIndex[message.id] ?? -1
                let displayFollowUps: [String] = {
                    if vIdx >= 0 && vIdx < message.versions.count {
                        return message.versions[vIdx].followUps
                    }
                    return message.followUps
                }()
                if !displayFollowUps.isEmpty {
                    followUpSuggestions(displayFollowUps)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.sm)
                        // Use simple opacity transition — .move(edge: .bottom) triggers
                        // a layout re-measurement during animation that can temporarily
                        // make the scroll content wider than the screen, enabling 2D pan.
                        .transition(.opacity)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(message.role == .user ? "You" : "Assistant"): \(message.content.prefix(200))"))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    // MARK: - Assistant Header

    private func resolveModel(for message: ChatMessage) -> AIModel? {
        if let mid = message.model,
           let model = viewModel.availableModels.first(where: { $0.id == mid }) {
            return model
        }
        return viewModel.selectedModel
    }

    private func assistantHeader(for message: ChatMessage) -> some View {
        let model = resolveModel(for: message)
        return HStack(spacing: Spacing.sm) {
            if let m = model {
                ModelAvatar(size: 22, imageURL: viewModel.resolvedImageURL(for: m),
                            label: m.shortName, authToken: viewModel.serverAuthToken)
            } else {
                ModelAvatar(size: 22, label: message.model)
            }
            Text(model?.shortName ?? message.model ?? String(localized: "Assistant"))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, 4)
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func messageBubble(for message: ChatMessage, isLastAssistant: Bool) -> some View {
        if isLocalAlpineResultMessage(message) {
            let fallbackContent = localAlpineFallbackContent(for: message)
            if !fallbackContent.isEmpty {
                ChatMessageBubble(
                    role: .assistant,
                    showTimestamp: activeActionMessageId == message.id,
                    timestamp: message.timestamp
                ) {
                    AssistantMessageContent(
                        content: fallbackContent,
                        isStreaming: message.isStreaming,
                        messageEmbeds: message.embeds,
                        authToken: viewModel.serverAuthToken,
                        serverBaseURL: viewModel.serverBaseURL,
                        apiClient: dependencies.apiClient
                    )
                }
            } else if message.isStreaming {
                ChatMessageBubble(
                    role: .assistant,
                    showTimestamp: activeActionMessageId == message.id,
                    timestamp: message.timestamp
                ) {
                    TypingIndicator()
                }
            }
        } else {
            ChatMessageBubble(
                role: message.role,
                showTimestamp: activeActionMessageId == message.id,
                timestamp: message.timestamp
            ) {
                messageContent(for: message)
            }
            // Only apply tap gesture to user bubbles — assistant content contains
            // interactive elements (links, text selection) that onTapGesture would block.
            // Assistant action bar is always visible so no tap-reveal is needed.
            .if(message.role == .user) { view in
                view.onTapGesture {
                    withAnimation(MicroAnimation.snappy) {
                        activeActionMessageId = activeActionMessageId == message.id ? nil : message.id
                    }
                    Haptics.play(.light)
                }
            }
            .if(message.role != .assistant) { view in
                view.contextMenu { messageContextMenu(for: message) }
            }
        }
    }

    private func isLocalAlpineResultMessage(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_alpine_result"] == "true"
            || message.content.hasPrefix("Local Alpine 执行结果")
            || (message.model == "Local Alpine" && message.statusHistory.contains {
                $0.action?.lowercased() == "local_alpine"
            })
    }

    private func hasAgentToolPreview(for message: ChatMessage) -> Bool {
        guard let item = agentActivity(for: message), item.hasConcreteSteps else {
            return false
        }
        return !item.hasOnlyWebSearchStatusSteps
    }

    @ViewBuilder
    private func agentStepPreview(for message: ChatMessage) -> some View {
        if let item = agentActivity(for: message),
           item.hasConcreteSteps,
           !item.hasOnlyWebSearchStatusSteps {
            AgentInlineStepsView(item: item, onTap: openAgentTaskPanel)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.xs)
        }
    }

    private func isLocalNativeResultMessage(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_native_result"] == "true"
            || message.model == "Local Native"
    }

    @ViewBuilder
    private func messageContextMenu(for message: ChatMessage) -> some View {
        Button { copyMessage(message) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if message.role == .user && !viewModel.isStreaming {
            Button { beginInlineEdit(message: message) } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        if message.role == .assistant && !viewModel.isStreaming {
            Button { Task { await viewModel.regenerateResponse(messageId: message.id) } } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        if !viewModel.isStreaming {
            Button(role: .destructive) {
                let userVIdx = activeUserVersionIndex[message.id] ?? -1
                Task { await viewModel.deleteMessage(id: message.id, activeVersionIndex: message.role == .user ? userVIdx : nil) }
                // Clean up local navigation state after deletion
                if message.role == .user {
                    if !message.versions.isEmpty {
                        if userVIdx < 0 {
                            // Deleted main — reset to main (last version promoted)
                            activeUserVersionIndex.removeValue(forKey: message.id)
                        } else if message.versions.count <= 1 {
                            // Deleted last version — back to main
                            activeUserVersionIndex.removeValue(forKey: message.id)
                            // Clear AI override since we're back to main
                            if let userIdx = viewModel.messages.firstIndex(where: { $0.id == message.id }),
                               userIdx + 1 < viewModel.messages.count,
                               viewModel.messages[userIdx + 1].role == .assistant {
                                assistantContentOverride.removeValue(forKey: viewModel.messages[userIdx + 1].id)
                            }
                        } else if userVIdx >= message.versions.count - 1 {
                            activeUserVersionIndex[message.id] = max(0, userVIdx - 1)
                        }
                    }
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Message Content

    @ViewBuilder
    private func messageContent(for message: ChatMessage) -> some View {
        if message.role == .user {
            let displayContent = activeUserDisplayContent(for: message)
            VStack(alignment: .trailing, spacing: Spacing.sm) {
                // Text content
                if !displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    UserMessageContentView(content: displayContent)
                        .lineSpacing(2)
                }
            }
        } else {
            // ── STREAMING ISOLATION ──
            // All streaming store reads (streamingContent, streamingSources,
            // isActive, streamingMessageId) are moved into IsolatedAssistantMessage
            // — a separate struct whose body is the only thing that re-evaluates
            // on every token. ChatDetailView.body never touches these properties,
            // so it stays completely inert during streaming.
            IsolatedAssistantMessage(
                streamingStore: viewModel.streamingStore,
                message: message,
                activeVersionIndex: activeVersionIndex[message.id] ?? -1,
                contentOverride: assistantContentOverride[message.id],
                showEmptyThinkingCapsule: true,
                serverBaseURL: viewModel.serverBaseURL,
                authToken: viewModel.serverAuthToken,
                apiClient: dependencies.apiClient
            )
        }
    }



    // MARK: - iMessage-Style Edit Input Bar

    /// Replaces the normal input bar when editing a message.
    /// Lives in the safeAreaInset bottom slot — exactly where the normal
    /// ChatInputField sits — so iOS keyboard avoidance just works.
    private var editInputBar: some View {
        HStack(spacing: 10) {
            // Cancel button
            Button {
                cancelInlineEdit()
            } label: {
                ZStack {
                    Circle()
                        .fill(theme.surfaceContainer)
                        .frame(width: 34, height: 34)
                    Image(systemName: "xmark")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel edit")

            // Text field — fills remaining space, grows vertically up to 6 lines
            TextField("Edit message…", text: $editingMessageText, axis: .vertical)
                .scaledFont(size: 16)
                .foregroundStyle(theme.textPrimary)
                .tint(theme.brandPrimary)
                .lineLimit(1...6)
                .focused($isEditFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    if !editingMessageText.contains("\n") { submitInlineEdit() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            // Send / confirm button
            Button {
                submitInlineEdit()
            } label: {
                ZStack {
                    Circle()
                        .fill(editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              ? theme.textTertiary.opacity(0.3)
                              : theme.brandPrimary)
                        .frame(width: 34, height: 34)
                    Image(systemName: "arrow.up")
                        .scaledFont(size: 14, weight: .bold)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Save and resend")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(theme.background)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        .onAppear {
            isEditFieldFocused = true
        }
    }

    private func beginInlineEdit(message: ChatMessage) {
        editingMessageId = message.id
        editingMessageText = message.content
        // Focus immediately — no delay needed since we're not fighting scroll layout
        isEditFieldFocused = true
        Haptics.play(.light)
    }

    private func cancelInlineEdit() {
        isEditFieldFocused = false
        withAnimation(.easeInOut(duration: 0.18)) {
            editingMessageId = nil
            editingMessageText = ""
        }
    }

    private func submitInlineEdit() {
        guard let id = editingMessageId else { return }
        let trimmed = editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isEditFieldFocused = false
        withAnimation(.easeInOut(duration: 0.18)) {
            editingMessageId = nil
        }
        editingMessageText = ""
        Task { await viewModel.editMessage(id: id, newContent: trimmed) }
        Haptics.play(.medium)
    }

    // MARK: - Welcome View

    private struct SuggestedPrompt: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        private let _fullText: String?
        var fullText: String { _fullText ?? "\(title) \(subtitle)" }

        init(title: String, subtitle: String, fullText: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self._fullText = fullText
        }
    }

    /// Converts server-provided `default_prompt_suggestions` into display models.
    ///
    /// Returns an empty array when the server has no suggestions configured
    /// (admin turned them off or the field is absent), which collapses the
    /// entire prompt grid and shows a clean hero-only welcome screen.
    private static func buildServerPrompts(
        from suggestions: [BackendConfig.PromptSuggestion]?,
        count: Int
    ) -> [SuggestedPrompt] {
        guard let suggestions, !suggestions.isEmpty else { return [] }

        let mapped: [SuggestedPrompt] = suggestions.compactMap { suggestion in
            // title[0] = bold heading, title[1] = subtitle (may be absent)
            guard let titleParts = suggestion.title, !titleParts.isEmpty else { return nil }
            let title = titleParts[0]
            let subtitle = titleParts.count > 1 ? titleParts[1] : ""
            // Use the server's `content` field as the sent message; fall back
            // to joining the title parts if content is missing.
            let content = suggestion.content ?? titleParts.joined(separator: " ")
            return SuggestedPrompt(title: title, subtitle: subtitle, fullText: content)
        }

        // Shuffle so a different subset appears each time, then cap to `count`
        // (4 cards on iPhone, 8 on iPad).
        return Array(mapped.shuffled().prefix(count))
    }

    /// Resolves which prompt suggestions to show on the welcome screen.
    ///
    /// Priority:
    /// 1. Per-model `suggestion_prompts` (from the selected model's `meta.suggestion_prompts`) — if non-empty, use those.
    /// 2. Admin-level `default_prompt_suggestions` (from `/api/config`) — fallback if the model has none.
    /// 3. Neither → empty array (no prompt cards shown).
    private static func resolvePromptSuggestions(
        adminSuggestions: [BackendConfig.PromptSuggestion]?,
        modelSuggestions: [BackendConfig.PromptSuggestion]?,
        count: Int
    ) -> [SuggestedPrompt] {
        // 1. Per-model prompts take priority
        if let model = modelSuggestions, !model.isEmpty {
            return buildServerPrompts(from: model, count: count)
        }
        // 2. Fall back to admin-configured prompts
        if let admin = adminSuggestions, !admin.isEmpty {
            return buildServerPrompts(from: admin, count: count)
        }
        // 3. Neither → no prompts
        return []
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 60).layoutPriority(1)

                // ── Hero: avatar + greeting ──
                VStack(spacing: Spacing.sm) {
                ZStack {
                    if let model = viewModel.selectedModel {
                        ModelAvatar(
                            size: 55,
                            imageURL: viewModel.resolvedImageURL(for: model),
                            label: model.shortName,
                            authToken: viewModel.serverAuthToken
                        )
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        ModelAvatar(size: 55, label: nil)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                VStack(spacing: 4) {
                    Text("How can I help?")
                        .scaledFont(size: 24, weight: .bold)
                        .foregroundStyle(theme.textPrimary)

                    if let model = viewModel.selectedModel {
                        Text(model.shortName)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                if viewModel.isTemporaryChat {
                    HStack(spacing: 0) {
                        Text("Temporary Chat")
                            .scaledFont(size: 11, weight: .semibold)
                    }
                    .foregroundStyle(temporaryChatPillForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(Capsule())
                }
            }

            // ── Suggested prompt cards ──
            // Only shown when the server has configured suggestions.
            // If the admin clears all suggestions (or the server doesn't
            // return any), this entire block is hidden and the welcome
            // screen shows only the hero avatar + "How can I help?".
            if !randomPrompts.isEmpty {
                Spacer().frame(height: 32)

                // Adaptive grid: 2-col iPhone, 4-col iPad
                let cols = promptColumnCount
                let rows = stride(from: 0, to: randomPrompts.count, by: cols).map { i in
                    Array(randomPrompts[i..<min(i + cols, randomPrompts.count)])
                }
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            ForEach(row) { prompt in
                                promptCard(prompt)
                            }
                            // Fill empty slots if row has fewer items than column count
                            ForEach(0..<(cols - row.count), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, Spacing.screenPadding)
                    }
                }
                .frame(maxWidth: iPadMaxContentWidth)
            }

                Spacer(minLength: 60).layoutPriority(1)
            }
            .frame(minHeight: max(viewState_containerHeight, 0))
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Folder Welcome View

    private func folderWelcomeView(folder: ChatFolder) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60).layoutPriority(1)

            VStack(spacing: Spacing.md) {
                // Folder icon
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "folder.fill")
                        .scaledFont(size: 34, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }

                // Folder name
                Text(folder.name)
                    .scaledFont(size: 26, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // Subtitle hint
                Text("New chats will be saved to this folder")
                    .scaledFont(size: 13, weight: .regular)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)

                // Show system prompt badge if the folder has one
                if let systemPrompt = folder.systemPrompt,
                   !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "text.bubble")
                            .scaledFont(size: 11, weight: .medium)
                        Text("Custom system prompt active")
                            .scaledFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(Capsule())
                }

                // Show configured model badge if the folder has default models
                if let firstModel = folder.modelIds.first, !firstModel.isEmpty {
                    let modelName = viewModel.availableModels.first(where: { $0.id == firstModel })?.shortName ?? firstModel
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "cpu")
                            .scaledFont(size: 11, weight: .medium)
                        Text(modelName)
                            .scaledFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(theme.surfaceContainer.opacity(0.6))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
                    )
                }
            }
            .padding(.horizontal, Spacing.screenPadding)

            Spacer(minLength: 60).layoutPriority(1)
        }
        .frame(maxWidth: iPadMaxContentWidth)
        .frame(maxWidth: .infinity)
        .onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    @ViewBuilder
    private func promptCard(_ prompt: SuggestedPrompt) -> some View {
        Button {
            viewModel.inputText = prompt.fullText
            Task { await viewModel.sendMessage() }
            Haptics.play(.light)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.subtitle)
                    .scaledFont(size: 12, weight: .regular)
                    .foregroundStyle(theme.textSecondary.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.isDark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(PromptCardButtonStyle())
    }

    // MARK: - Assistant Action Bar

    private func assistantActionBar(for message: ChatMessage) -> some View {
        // Build a timestamp-sorted list of ALL sibling IDs (current main + versions).
        // This is the single source of truth for position — it never gets stale
        // because it is derived fresh from the message object on every render.
        // After any rederiveMessages() call (branch switch, edit, regen), the
        // message object is replaced with the new active sibling, so its
        // .timestamp and .versions[] are always authoritative.
        let allSiblings: [(id: String, timestamp: Date)] = {
            var sibs: [(id: String, timestamp: Date)] = [(message.id, message.timestamp)]
            for v in message.versions { sibs.append((v.id, v.timestamp)) }
            sibs.sort { $0.timestamp < $1.timestamp }
            return sibs
        }()
        let totalVersions = allSiblings.count
        // The current active sibling is the main message (message.id).
        // Its 1-based position in the sorted siblings list is the displayIndex.
        let displayIndex: Int = (allSiblings.firstIndex(where: { $0.id == message.id }) ?? 0) + 1

        return HStack(spacing: 6) {
            // Speak
            Button {
                toggleSpeech(for: message)
                Haptics.play(.light)
            } label: {
                if ttsGeneratingMessageId == message.id {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.65)
                        .frame(width: 28, height: 28)
                        .tint(theme.brandPrimary)
                } else {
                    compactActionIcon(
                        icon: speakingMessageId == message.id ? "stop.fill" : "speaker.wave.2",
                        isActive: speakingMessageId == message.id
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speakingMessageId == message.id ? "Stop speaking" : "Speak")

            // Copy
            Button { copyMessage(message) } label: {
                compactActionIcon(icon: "doc.on.doc", isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy")

            let feedbackVote = assistantFeedbackVoteOverrides[message.id]
                ?? AssistantFeedbackPreferenceStore.vote(for: message.id)
            Button {
                recordAssistantFeedback(.liked, for: message)
            } label: {
                compactActionIcon(icon: "hand.thumbsup", isActive: feedbackVote == .liked)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Like")

            Button {
                recordAssistantFeedback(.disliked, for: message)
            } label: {
                compactActionIcon(icon: "hand.thumbsdown", isActive: feedbackVote == .disliked)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dislike")

            Button {
                shareMessage(message)
            } label: {
                compactActionIcon(icon: "square.and.arrow.up", isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")

            // Version switcher (only when siblings exist and not overriding with a user edit version)
            if totalVersions > 1 && !viewModel.isStreaming && assistantContentOverride[message.id] == nil {
                HStack(spacing: 2) {
                    Button {
                        // Navigate to the sibling BEFORE the current one in sorted order.
                        let currentPos = displayIndex - 1 // 0-based
                        let targetPos = currentPos - 1
                        if targetPos >= 0 {
                            let targetId = allSiblings[targetPos].id
                            // restoreAssistantVersionById() calls rederiveMessages() which
                            // replaces the message object entirely. After that, the target
                            // sibling IS the main message and all state is correct.
                            viewModel.restoreAssistantVersionById(targetSiblingId: targetId)
                            Haptics.play(.light)
                        }
                    } label: {
                        compactActionIcon(icon: "chevron.left", isActive: false, size: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(displayIndex == 1)
                    .opacity(displayIndex == 1 ? 0.35 : 1)

                    Text("\(displayIndex)/\(totalVersions)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 28)

                    Button {
                        // Navigate to the sibling AFTER the current one in sorted order.
                        let currentPos = displayIndex - 1 // 0-based
                        let targetPos = currentPos + 1
                        if targetPos < allSiblings.count {
                            let targetId = allSiblings[targetPos].id
                            viewModel.restoreAssistantVersionById(targetSiblingId: targetId)
                            Haptics.play(.light)
                        }
                    } label: {
                        compactActionIcon(icon: "chevron.right", isActive: false, size: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(displayIndex == totalVersions)
                    .opacity(displayIndex == totalVersions ? 0.35 : 1)
                }
            }

            // Regenerate
            if !viewModel.isStreaming {
                Button {
                    Task { await viewModel.regenerateResponse(messageId: message.id) }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "arrow.clockwise", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate")
            }

            // Delete (only shown when there are multiple versions / regeneration history)
            if !viewModel.isStreaming && totalVersions > 1 {
                Button {
                    Task { await viewModel.deleteMessage(id: message.id) }
                    // After deletion, rederiveMessages() replaces the message list —
                    // no index tracking needed. Just clear any stale state.
                    activeVersionIndex.removeValue(forKey: message.id)
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "trash", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete Version")
            }

            // Usage info — always show from the current active message (message.usage).
            // The current message IS the active sibling after any rederiveMessages() call.
            let displayUsage: [String: Any]? = message.usage
            if let usage = displayUsage, !usage.isEmpty {
                Button {
                    withAnimation(MicroAnimation.snappy) {
                        usagePopoverMessageId = usagePopoverMessageId == message.id ? nil : message.id
                    }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(
                        icon: "info.circle",
                        isActive: usagePopoverMessageId == message.id
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Token usage")
            }

            // Action buttons (from model's configured actions — e.g. Generate Image)
            if !viewModel.isStreaming {
                let model = resolveModel(for: message)
                if let actions = model?.actions, !actions.isEmpty {
                    ForEach(actions) { action in
                        Button {
                            Task { await invokeActionButton(action: action, message: message) }
                            Haptics.play(.medium)
                        } label: {
                            actionButtonIcon(action: action)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(action.name)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Compact action icon for the always-visible action bar.
    private func compactActionIcon(icon: String, isActive: Bool, size: CGFloat = 12) -> some View {
        Image(systemName: icon)
            .scaledFont(size: size, weight: .medium)
            .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary.opacity(0.7))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }

    // MARK: - User Version Switcher (always-visible when edit history exists)

    /// Compact ← N/N → version arrows shown directly below the user bubble.
    /// Navigates user edit branches by sibling ID (not index), matching the same
    /// approach as assistantActionBar. This ensures switching the user message
    /// ALSO switches the paired assistant — because restoreUserVersionById walks
    /// to the deepest leaf of the target user branch (which includes the assistant).
    private func userVersionSwitcher(for message: ChatMessage) -> some View {
        // Build a timestamp-sorted list of ALL sibling IDs (current + versions),
        // identical to the approach in assistantActionBar. This avoids stale index
        // state and is always correct even after rederiveMessages() rebuilds the list.
        let allSiblings: [(id: String, timestamp: Date)] = {
            var sibs: [(id: String, timestamp: Date)] = [(message.id, message.timestamp)]
            for v in message.versions { sibs.append((v.id, v.timestamp)) }
            sibs.sort { $0.timestamp < $1.timestamp }
            return sibs
        }()
        let totalVersions = allSiblings.count
        // Current active sibling is message.id. Its 1-based position = displayIndex.
        let displayIndex: Int = (allSiblings.firstIndex(where: { $0.id == message.id }) ?? 0) + 1

        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button {
                    // Navigate to the sibling BEFORE the current one.
                    let currentPos = displayIndex - 1 // 0-based
                    let targetPos = currentPos - 1
                    if targetPos >= 0 {
                        let targetId = allSiblings[targetPos].id
                        // restoreUserVersionById navigates to the deepest leaf of the
                        // target user branch — this switches BOTH user AND assistant.
                        assistantContentOverride = [:]
                        activeVersionIndex = [:]
                        viewModel.restoreUserVersionById(targetSiblingId: targetId)
                        Haptics.play(.light)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(displayIndex == 1)
                .opacity(displayIndex == 1 ? 0.35 : 1)

                Text("\(displayIndex)/\(totalVersions)")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .frame(minWidth: 28)

                Button {
                    // Navigate to the sibling AFTER the current one.
                    let currentPos = displayIndex - 1 // 0-based
                    let targetPos = currentPos + 1
                    if targetPos < allSiblings.count {
                        let targetId = allSiblings[targetPos].id
                        assistantContentOverride = [:]
                        activeVersionIndex = [:]
                        viewModel.restoreUserVersionById(targetSiblingId: targetId)
                        Haptics.play(.light)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(displayIndex == totalVersions)
                .opacity(displayIndex == totalVersions ? 0.35 : 1)
            }
            .padding(.trailing, 2)
        }
    }

    // MARK: - User Action Bar (kept for backward compat — no longer shown in messageRow)

    private func userActionBar(for message: ChatMessage) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: Spacing.xs) {
                Button { copyMessage(message) } label: {
                    Image(systemName: "doc.on.doc")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                if !viewModel.isStreaming {
                    Button { beginInlineEdit(message: message) } label: {
                        Image(systemName: "pencil")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - User Attachment Images

    @ViewBuilder
    private func userAttachmentArea(for message: ChatMessage) -> some View {
        let files = activeUserDisplayFiles(for: message)
        let imageFiles = files.filter { isImageFile($0) }
        let nonImageFiles = files.filter {
            !isImageFile($0)
                && $0.type != "collection"
                && $0.type != "folder"
        }

        if !imageFiles.isEmpty || !nonImageFiles.isEmpty {
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                if !imageFiles.isEmpty {
                    let displayImageFiles = Array(imageFiles.prefix(9))
                    if displayImageFiles.count == 1, let file = displayImageFiles.first {
                        HStack {
                            Spacer(minLength: 0)
                            userImageThumbnail(file: file, size: userSingleImageThumbnailSize(for: file))
                        }
                    } else {
                        let columnCount = min(displayImageFiles.count, 3)
                        let thumbnailSize: CGFloat = 88
                        let gridWidth = CGFloat(columnCount) * thumbnailSize + CGFloat(columnCount - 1) * Spacing.sm
                        let columns = Array(
                            repeating: GridItem(.fixed(thumbnailSize), spacing: Spacing.sm),
                            count: columnCount
                        )

                        HStack {
                            Spacer(minLength: 0)
                            LazyVGrid(columns: columns, alignment: .trailing, spacing: Spacing.sm) {
                                ForEach(Array(displayImageFiles.enumerated()), id: \.offset) { _, file in
                                    userImageThumbnail(file: file, size: CGSize(width: thumbnailSize, height: thumbnailSize))
                                }
                            }
                            .frame(width: gridWidth, alignment: .trailing)
                        }
                    }
                }
                if !nonImageFiles.isEmpty {
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        ForEach(Array(nonImageFiles.enumerated()), id: \.offset) { _, file in
                            fileAttachmentCard(file: file, compact: false)
                        }
                    }
                    .frame(maxWidth: 280, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func userAttachmentImages(for message: ChatMessage) -> some View {
        let imageFiles = message.files.filter { isImageFile($0) }
        let nonImageFiles = message.files.filter { !isImageFile($0) }

        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if !imageFiles.isEmpty {
                let displayImageFiles = Array(imageFiles.prefix(9))
                let columnCount = min(displayImageFiles.count, 3)
                let thumbnailSize: CGFloat = displayImageFiles.count == 1 ? 200 : 88
                let gridWidth = displayImageFiles.count == 1
                    ? thumbnailSize
                    : CGFloat(columnCount) * thumbnailSize + CGFloat(columnCount - 1) * Spacing.sm
                let columns = Array(
                    repeating: GridItem(.fixed(thumbnailSize), spacing: Spacing.sm),
                    count: columnCount
                )

                HStack {
                    Spacer(minLength: 0)
                    LazyVGrid(columns: columns, alignment: .trailing, spacing: Spacing.sm) {
                        ForEach(Array(displayImageFiles.enumerated()), id: \.offset) { _, file in
                            if file.isGeneratedImageFailurePlaceholder {
                                GeneratedImageFailurePlaceholder()
                                    .frame(width: thumbnailSize, height: thumbnailSize)
                                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                            } else if let fileId = imageReference(for: file) {
                                chatImageView(fileId: fileId, allowsEditing: false)
                                    .frame(width: thumbnailSize, height: thumbnailSize)
                                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                            }
                        }
                    }
                    .frame(width: gridWidth, alignment: .trailing)
                }
            }
            if !nonImageFiles.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Spacer()
                    ForEach(Array(nonImageFiles.enumerated()), id: \.offset) { _, file in
                        fileAttachmentCard(file: file, compact: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func userImageThumbnail(file: ChatMessageFile, size: CGSize) -> some View {
        let cornerRadius: CGFloat = size.width > 100 || size.height > 100 ? 14 : 10
        if file.isGeneratedImageFailurePlaceholder {
            GeneratedImageFailurePlaceholder()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if let fileId = imageReference(for: file) {
            chatImageView(fileId: fileId, allowsEditing: false)
                .frame(width: size.width, height: size.height)
                .background(theme.surfaceContainer.opacity(theme.isDark ? 0.35 : 0.18))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private func userSingleImageThumbnailSize(for file: ChatMessageFile) -> CGSize {
        let maxWidth: CGFloat = 280
        let maxHeight: CGFloat = 220
        let fallback = CGSize(width: 240, height: 160)
        guard let pixelSize = localImagePixelSize(for: file),
              pixelSize.width > 0,
              pixelSize.height > 0 else {
            return fallback
        }

        let aspect = pixelSize.width / pixelSize.height
        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }

        width = min(max(width, 96), maxWidth)
        height = min(max(height, 96), maxHeight)
        return CGSize(width: round(width), height: round(height))
    }

    private func localImagePixelSize(for file: ChatMessageFile) -> CGSize? {
        let candidates = [file.displayURL, file.url].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        for candidate in candidates {
            if let size = imagePixelSize(fromDisplayReference: candidate) {
                return size
            }
        }
        return nil
    }

    private func imagePixelSize(fromDisplayReference reference: String) -> CGSize? {
        if reference.hasPrefix("data:image/"),
           let comma = reference.firstIndex(of: ",") {
            let encoded = String(reference[reference.index(after: comma)...])
            guard let data = Data(base64Encoded: encoded),
                  let image = UIImage(data: data),
                  image.size.width > 0,
                  image.size.height > 0 else {
                return nil
            }
            return image.size
        }

        if reference.hasPrefix("file://"),
           let url = URL(string: reference),
           let image = UIImage(contentsOfFile: url.path),
           image.size.width > 0,
           image.size.height > 0 {
            return image.size
        }

        return nil
    }

    @ViewBuilder
    private func chatImageView(fileId: String, allowsEditing: Bool = true) -> some View {
        if allowsEditing {
            AuthenticatedImageView(
                fileId: fileId,
                apiClient: dependencies.apiClient,
                onEdit: { image in
                    prepareGeneratedImageForEditing(image)
                },
                onPreview: {
                    openImageGallery(startingAt: fileId)
                }
            )
        } else {
            AuthenticatedImageView(
                fileId: fileId,
                apiClient: dependencies.apiClient,
                onPreview: {
                    openImageGallery(startingAt: fileId)
                }
            )
        }
    }

    private func openImageGallery(startingAt fileId: String) {
        let items = currentChatImageGalleryItems()
        guard !items.isEmpty else { return }
        let initialId = items.first(where: { $0.fileId == fileId })?.id ?? items[0].id
        imageGalleryPresentation = AuthenticatedImageGalleryPresentation(
            items: items,
            initialItemId: initialId
        )
    }

    private func currentChatImageGalleryItems() -> [AuthenticatedImageGalleryItem] {
        var items: [AuthenticatedImageGalleryItem] = []
        var ordinal = 0

        func appendImageFiles(_ files: [ChatMessageFile], messageId: String) {
            for file in files where isImageFile(file) && !file.isGeneratedImageFailurePlaceholder {
                guard let fileId = imageReference(for: file) else { continue }
                items.append(AuthenticatedImageGalleryItem(
                    id: "\(messageId)-image-\(ordinal)",
                    fileId: fileId
                ))
                ordinal += 1
            }
        }

        for message in transcriptMessages {
            if message.role == .user {
                let imageFiles = activeUserDisplayFiles(for: message).filter { isImageFile($0) }
                appendImageFiles(Array(imageFiles.prefix(9)), messageId: message.id)
            } else if message.role == .assistant && !message.isStreaming {
                let versionIndex = activeVersionIndex[message.id] ?? -1
                let displayFiles: [ChatMessageFile]
                if versionIndex >= 0 && versionIndex < message.versions.count {
                    displayFiles = message.versions[versionIndex].files
                } else {
                    displayFiles = message.files
                }
                appendImageFiles(Array(displayFiles.filter { isImageFile($0) }.prefix(9)), messageId: message.id)
            }
        }

        return items
    }

    private func activeUserDisplayContent(for message: ChatMessage) -> String {
        let userVIdx = activeUserVersionIndex[message.id] ?? -1
        if userVIdx >= 0 && userVIdx < message.versions.count {
            return message.versions[userVIdx].content
        }
        return message.content
    }

    private func activeUserDisplayFiles(for message: ChatMessage) -> [ChatMessageFile] {
        let userVIdx = activeUserVersionIndex[message.id] ?? -1
        if userVIdx >= 0 && userVIdx < message.versions.count {
            return message.versions[userVIdx].files
        }
        return message.files
    }

    private func imageReference(for file: ChatMessageFile) -> String? {
        let candidates = [file.displayURL, file.url].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        for candidate in candidates where !candidate.isEmpty {
            if candidate.hasPrefix("data:image/") {
                guard candidate.utf8.count <= 7_000_000 else { continue }
                return candidate
            }
            if candidate.hasPrefix("image:data/") {
                continue
            }
            guard candidate.utf8.count <= 4_096 else {
                continue
            }
            if candidate.hasPrefix("file://")
                || candidate.hasPrefix("http://")
                || candidate.hasPrefix("https://") {
                return candidate
            }
            if !candidate.contains("/") {
                return candidate
            }
            let parts = candidate.split(separator: "/")
            if let idx = parts.firstIndex(of: "files"), idx + 1 < parts.count {
                return String(parts[idx + 1])
            }
        }
        return nil
    }

    private func isImageFile(_ file: ChatMessageFile) -> Bool {
        file.type == "image" || (file.contentType ?? "").hasPrefix("image/")
    }

    private func fileAttachmentCard(file: ChatMessageFile, compact: Bool) -> some View {
        let fileName = file.name ?? file.url ?? "File"
        let fileExt = (fileName as NSString).pathExtension.lowercased()
        let icon = fileIconName(for: fileExt)

        return Button {
            previewingMessageFile = MessageFilePreviewItem(file: file)
        } label: {
            if compact {
                compactFileAttachmentLabel(fileName: fileName, file: file, fileExt: fileExt, icon: icon)
            } else {
                regularFileAttachmentLabel(fileName: fileName, file: file, fileExt: fileExt, icon: icon)
            }
        }
        .buttonStyle(.plain)
    }

    private func compactFileAttachmentLabel(
        fileName: String,
        file: ChatMessageFile,
        fileExt: String,
        icon: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 26, height: 26)
                .background(theme.brandPrimary.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(fileName)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileAttachmentSubtitle(for: file, fallbackExtension: fileExt))
                    .scaledFont(size: 10, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 170, alignment: .leading)

            Image(systemName: "chevron.right")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(theme.surfaceContainer.opacity(0.78))
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func regularFileAttachmentLabel(
        fileName: String,
        file: ChatMessageFile,
        fileExt: String,
        icon: String
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 30, height: 30)
                .background(theme.brandPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .scaledFont(size: 13)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileAttachmentSubtitle(for: file, fallbackExtension: fileExt))
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 8)
        .background(theme.surfaceContainer.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func fileIconName(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.stack"
        case "json", "yaml", "yml", "xml", "conf", "toml", "ini", "cfg": return "curlybraces"
        case "txt", "md", "rtf": return "doc.plaintext"
        case "js", "ts", "py", "swift", "dart", "java", "cpp", "c", "h", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "html", "htm", "css", "scss": return "globe"
        case "zip", "tar", "gz", "rar", "7z": return "archivebox"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film"
        default: return "doc"
        }
    }

    private static func localFileURL(fromDataURL dataURL: String, fallbackName: String) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            guard dataURL.hasPrefix("data:"),
                  let comma = dataURL.firstIndex(of: ",") else { return nil }
            let header = String(dataURL[..<comma]).lowercased()
            let base64 = String(dataURL[dataURL.index(after: comma)...])
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }

            let ext: String
            if header.contains("video/webm") {
                ext = "webm"
            } else if header.contains("video/quicktime") || header.contains("video/mov") {
                ext = "mov"
            } else if header.contains("image/png") {
                ext = "png"
            } else if header.contains("image/jpeg") || header.contains("image/jpg") {
                ext = "jpg"
            } else if header.contains("application/pdf") {
                ext = "pdf"
            } else {
                ext = (fallbackName as NSString).pathExtension.isEmpty
                    ? "mp4"
                    : (fallbackName as NSString).pathExtension
            }

            let baseName = ((fallbackName as NSString).deletingPathExtension)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = baseName.isEmpty ? "generated-media" : baseName
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("generated_media_cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let url = cacheDir.appendingPathComponent("\(safeName)-\(abs(dataURL.hashValue)).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url)
            }
            return url
        }.value
    }

    // MARK: - Tool-Generated Images

    @ViewBuilder
    private func messageFilesView(files: [ChatMessageFile]) -> some View {
        let imageFiles = Array(files.filter { isImageFile($0) }.prefix(9))
        let nonImageFiles = files.filter {
            !isImageFile($0)
                && $0.type != "collection"
                && $0.type != "folder"
        }
        if !imageFiles.isEmpty {
            let columnCount = imageFiles.count >= 5 ? 3 : 2
            let generatedImageTileHeight: CGFloat = imageFiles.count == 1
                ? 200
                : (imageFiles.count >= 5 ? 92 : 130)
            let columns = imageFiles.count == 1
                ? [GridItem(.flexible())]
                : Array(
                    repeating: GridItem(.flexible(), spacing: Spacing.sm),
                    count: columnCount
                )

            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                ForEach(Array(imageFiles.enumerated()), id: \.element) { _, file in
                    if file.isGeneratedImageFailurePlaceholder {
                        GeneratedImageFailurePlaceholder()
                            .frame(maxWidth: .infinity)
                            .frame(height: generatedImageTileHeight)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    } else if let fileId = imageReference(for: file) {
                        chatImageView(fileId: fileId)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    }
                }
            }
        }
        if !nonImageFiles.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(nonImageFiles.enumerated()), id: \.offset) { _, file in
                    fileAttachmentCard(file: file, compact: false)
                }
            }
        }
    }

    // MARK: - Sources Bar

    private func sourcesBar(sources: [ChatSourceReference], messageId: String) -> some View {
        Button {
            if let msg = viewModel.messages.first(where: { $0.id == messageId }) {
                sourcesSheetMessage = msg
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: -6) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.offset) { _, source in
                        sourceFavicon(source, size: 24)
                    }
                }
                Text("\(sources.count) 个来源")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.surfaceContainer.opacity(0.55))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func fileAttachmentSubtitle(for file: ChatMessageFile, fallbackExtension: String) -> String {
        if let contentType = file.contentType, !contentType.isEmpty {
            return contentType
        }
        return fallbackExtension.isEmpty ? "文件" : fallbackExtension.uppercased()
    }

    @ViewBuilder
    private func sourceFavicon(_ source: ChatSourceReference, size: CGFloat) -> some View {
        let targetPixelSize = Int(size * UIScreen.main.scale)
        let urls = source.resolvedURL
            .map { WebsiteFaviconResolver.candidateURLs(for: $0, size: max(64, targetPixelSize)) }
            ?? []
        FallbackCachedAsyncImage(urls: urls, targetPixelSize: targetPixelSize) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Image(systemName: "globe")
                .scaledFont(size: max(9, size * 0.46), weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .frame(width: size, height: size)
                .background(theme.surfaceContainer)
        }
        .frame(width: size, height: size)
        .background(theme.surfaceContainer)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(theme.background.opacity(0.85), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
    }

    // MARK: - Follow-Up Suggestions

    private func followUpSuggestions(_ followUps: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "lightbulb").scaledFont(size: 12).foregroundStyle(theme.brandPrimary)
                Text("Continue with")
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(followUps, id: \.self) { suggestion in
                Button {
                    viewModel.inputText = suggestion
                    Task { await viewModel.sendMessage() }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "arrow.right")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                        Text(suggestion)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.brandPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(theme.brandPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(theme.brandPrimary.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Message Error View

    private func messageErrorView(_ text: String, retryMessageId: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
            Text(text)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
            Spacer()
            if !viewModel.isStreaming {
                Button { Task { await viewModel.regenerateResponse(messageId: retryMessageId) } } label: {
                    Text("重试").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.brandPrimary)
                }
            }
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - Error Banner

    private func errorBannerView(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                withAnimation(MicroAnimation.snappy) { viewModel.errorMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
        }
        .padding(Spacing.md)
        .background(theme.errorBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(MicroAnimation.gentle, value: viewModel.errorMessage != nil)
    }

    // MARK: - Copied Toast

    private var copiedToastView: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.on.doc.fill").scaledFont(size: 12)
            Text("Copied to clipboard").scaledFont(size: 12, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
        .padding(.top, Spacing.md)
        .transition(.toastTransition)
        .animation(MicroAnimation.gentle, value: showCopiedToast)
    }


    // MARK: - Actions

    /// Fetches the full model detail and opens the ModelEditorView sheet.
    /// Called when an admin taps the edit button in the model selector sheet.
    private func openModelEditorFromPicker(_ model: AIModel) async {
        guard let apiClient = dependencies.apiClient else { return }
        isLoadingModelDetail = true
        do {
            let detail = try await apiClient.getWorkspaceModelDetail(id: model.id)
            isLoadingModelDetail = false
            editingModelDetail = detail
        } catch {
            // Base models (not yet customized as workspace models) return 404.
            // Construct a default ModelDetail so the editor opens in "create" mode.
            isLoadingModelDetail = false
            editingModelDetail = ModelDetail(
                id: model.id,
                name: model.name,
                description: model.description,
                profileImageURL: model.profileImageURL
            )
        }
    }

    /// Dismiss all picker/overlay states so a new quick action doesn't stack.
    private func dismissAllPickers() {
        showCameraPicker = false
        showFilePicker = false
        showPhotosPicker = false
        showAudioPicker = false
        showWebURLAlert = false
    }

    // MARK: - Dictation

    private func startDictation() {
        let service = dependencies.dictationService
        service.onTranscriptReady = { [weak viewModel] text in
            guard let vm = viewModel else { return }
            if vm.inputText.isEmpty {
                vm.inputText = text
            } else {
                vm.inputText += " " + text
            }
        }
        service.onError = { _ in
            Task { @MainActor in isDictating = false }
        }
        isDictating = true
        Task { await service.startDictation() }
    }

    private func stopDictation() {
        dependencies.dictationService.stopDictation()
        isDictating = false
    }

    private func cancelDictation() {
        dependencies.dictationService.cancelDictation()
        isDictating = false
    }

    private func toggleVoiceInput() {
        Haptics.play(.medium)
        let voiceCallVM = dependencies.makeVoiceCallViewModel()
        if let manager = dependencies.conversationManager {
            voiceCallVM.configure(
                conversationManager: manager,
                chatViewModel: viewModel,
                modelName: viewModel.selectedModel?.name ?? "AI Assistant"
            )
        }
        router.presentVoiceCall(viewModel: voiceCallVM)
    }

    private func toggleSpeech(for message: ChatMessage) {
        let tts = dependencies.textToSpeechService
        if speakingMessageId == message.id || ttsGeneratingMessageId == message.id {
            tts.stop()
            speakingMessageId = nil
            ttsGeneratingMessageId = nil
        } else {
            tts.stop()
            speakingMessageId = nil
            ttsGeneratingMessageId = nil
            let rate = UserDefaults.standard.double(forKey: "ttsSpeechRate")
            if rate > 0 { tts.speechRate = Float(rate) * AVSpeechUtteranceDefaultSpeechRate }
            let voiceId = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier") ?? ""
            tts.voiceIdentifier = voiceId.isEmpty ? nil : voiceId
            let messageId = message.id
            tts.onStart = {
                speakingMessageId = messageId
                ttsGeneratingMessageId = nil
            }
            tts.onComplete = {
                speakingMessageId = nil
                ttsGeneratingMessageId = nil
            }

            let vIdx = activeVersionIndex[message.id] ?? -1
            let content: String = {
                if vIdx >= 0 && vIdx < message.versions.count { return message.versions[vIdx].content }
                return message.content
            }()
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ttsGeneratingMessageId = message.id
            tts.speak(content)
        }
    }

    // MARK: - Action Button Helpers

    /// Renders the icon for an action button.
    /// Handles three icon formats:
    ///  1. Base64 SVG data URI  (`data:image/svg+xml;base64,...`) — decoded inline.
    ///  2. Inline SVG string    (starts with `<svg`) — rendered directly.
    ///  3. HTTP/HTTPS URL       — fetched remotely by RemoteSVGIconView.
    ///  4. Everything else      — bolt.fill SF Symbol fallback.
    @ViewBuilder
    private func actionButtonIcon(action: AIModelAction) -> some View {
        if let iconStr = action.icon, !iconStr.isEmpty {
            if iconStr.hasPrefix("data:image/svg+xml;base64,"),
               let base64 = iconStr.components(separatedBy: ",").last,
               let svgData = Data(base64Encoded: base64),
               let svgString = String(data: svgData, encoding: .utf8) {
                // Base64-encoded SVG data URI
                SVGIconView(svgString: svgString)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            } else if iconStr.hasPrefix("<svg") || iconStr.hasPrefix("<?xml") {
                // Raw SVG string
                SVGIconView(svgString: iconStr)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            } else if iconStr.hasPrefix("http://") || iconStr.hasPrefix("https://") {
                // Remote URL (e.g., https://www.svgrepo.com/show/…/pdf-file.svg)
                RemoteSVGIconView(url: iconStr)
            } else {
                // Unknown format — fallback
                Image(systemName: "bolt.fill")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
        } else {
            Image(systemName: "bolt.fill")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
    }

    /// Invokes a function-based action button on an assistant message.
    ///
    /// Iexa native server action protocol:
    /// - POST `/api/chat/actions/{id}` is **plain JSON** (not SSE). The HTTP response
    ///   arrives only after the entire action finishes.
    /// - While the HTTP request is pending the server emits events via **Socket.IO**
    ///   on the `"events"` channel targeted at `session_id` (which must equal `socket.sid`):
    ///   - `__event_emitter__`: fire-and-forget status/notification/replace/message updates.
    ///   - `__event_call__`:    bidirectional call via `sio.call()` — carries a Socket.IO
    ///     ack ID. The client must respond via the ack callback to unblock the server.
    private func invokeActionButton(action: AIModelAction, message: ChatMessage) async {
        logger.info("🔵 [Action] invokeActionButton: action=\(action.id, privacy: .public) messageId=\(message.id, privacy: .public)")
        guard let apiClient = dependencies.apiClient else { return }

        // Show initial "Running…" status pill
        let statusUpdate = ChatStatusUpdate(action: action.name, description: "\(action.name)…", done: false)
        if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
            viewModel.conversation?.messages[idx].statusHistory.append(statusUpdate)
        }

        // Build request body. session_id MUST be socket.sid so the server can target
        // this Socket.IO session for __event_call__ and __event_emitter__ events.
        let messageArray: [[String: Any]] = viewModel.messages.map { msg in
            var dict: [String: Any] = [
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": Int(msg.timestamp.timeIntervalSince1970)
            ]
            if !msg.id.isEmpty { dict["id"] = msg.id }
            return dict
        }
        let modelItem: [String: Any] = viewModel.selectedModel?.rawModelItem ?? [:]
        var body: [String: Any] = [
            "model": viewModel.selectedModelId ?? "",
            "messages": messageArray,
            "id": message.id
        ]
        if let chatId = viewModel.conversationId ?? viewModel.conversation?.id {
            body["chat_id"] = chatId
        }

        // Ensure the Socket.IO connection is live before we commit a session_id to the
        // POST body. If the socket is not connected (e.g., after backgrounding), the
        // server cannot route __event_call__ / __event_emitter__ events back to us.
        let socket = dependencies.socketService
        if let socket {
            let initialState = socket.connectionState
            logger.info("🔵 [Action] Socket state before action: \(String(describing: initialState), privacy: .public), sid=\(socket.sid ?? "nil", privacy: .public)")
            if initialState != .connected {
                logger.info("🔵 [Action] Socket not connected — attempting ensureConnected...")
                let connected = await socket.ensureConnected(timeout: 5.0)
                logger.info("🔵 [Action] ensureConnected result: \(connected, privacy: .public), sid=\(socket.sid ?? "nil", privacy: .public)")
            }
        } else {
            logger.warning("⚠️ [Action] No socket service available — action events will not be received")
        }

        // Use socket.sid — must be captured AFTER ensureConnected so we have a live SID.
        let socketSid = socket?.sid
        let socketSessionId = socketSid ?? viewModel.sessionId
        body["session_id"] = socketSessionId
        if !modelItem.isEmpty { body["model_item"] = modelItem }

        logger.info("🔵 [Action] Using session_id=\(socketSessionId, privacy: .public) (socket.sid=\(socketSid ?? "nil", privacy: .public))")

        // Register Socket.IO handler BEFORE sending the POST so no events are missed.
        // Scope to session_id so only events destined for this action are delivered.
        let subscription = socket?.addChatEventHandler(sessionId: socketSessionId) { socketEvent, ack in
            Task { @MainActor in
                await self.handleActionSocketEvent(
                    socketEvent: socketEvent,
                    ack: ack,
                    action: action,
                    message: message
                )
            }
        }
        logger.info("🔵 [Action] Socket handler registered (subscription=\(subscription != nil, privacy: .public))")

        do {
            logger.info("🔵 [Action] Sending POST /api/chat/actions/\(action.id, privacy: .public)")
            // Plain JSON POST — not SSE. Blocks until the full action completes on the server.
            let actionResponse = try await apiClient.network.requestJSONOrVoid(
                path: "/api/chat/actions/\(action.id)",
                method: .post,
                body: body,
                authenticated: true,
                timeout: 300
            )
            logger.info("✅ [Action] POST completed successfully")
            viewModel.isStreaming = false

            // If the action returned a file result, download it in-app via the authenticated API.
            // e.g. PDF Export returns { "result": { "success": true, "filename": "…pdf" } }
            if let result = actionResponse["result"] as? [String: Any],
               (result["success"] as? Bool) == true,
               let filename = result["filename"] as? String, !filename.isEmpty {
                logger.info("📎 [Action] Result contains file: \(filename, privacy: .public) — fetching from server")
                isDownloadingFile = true
                let fileId = await resolveFileId(forFilename: filename, apiClient: apiClient)
                isDownloadingFile = false
                if let fileId {
                    await downloadAndShareFile(fileId: fileId)
                } else {
                    logger.warning("⚠️ [Action] Could not resolve file ID for '\(filename, privacy: .public)'")
                    downloadErrorMessage = "Could not find the generated file on the server."
                    showDownloadError = true
                }
            }

            await viewModel.reloadConversation()
        } catch {
            logger.error("❌ [Action] POST failed: \(error.localizedDescription, privacy: .public)")
            viewModel.errorMessage = error.localizedDescription
        }

        // Clean up socket handler
        subscription?.dispose()

        // Clear the running status pill
        if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
            viewModel.conversation?.messages[idx].statusHistory.removeAll {
                $0.action == action.name && $0.done != true
            }
        }
    }

    /// Processes a single Socket.IO `"events"` packet arriving during an action invocation.
    ///
    /// - `__event_emitter__` packets are dispatched immediately (no ack required).
    /// - `__event_call__` packets suspend until the user responds, then call `ack` so the
    ///   server's `await sio.call()` can resume.
    @MainActor
    private func handleActionSocketEvent(
        socketEvent: [String: Any],
        ack: ((Any?) -> Void)?,
        action: AIModelAction,
        message: ChatMessage
    ) async {
        // Iexa native server does NOT wrap events in "__event_emitter__" / "__event_call__" envelopes
        // at the socket event level. The actual event type lives at data.type (e.g. "status",
        // "input", "confirmation", "execute"). Whether the event requires an ack response is
        // determined by whether ack != nil (set by the server via sio.call vs sio.emit).
        let dataPayload = (socketEvent["data"] as? [String: Any]) ?? socketEvent
        let innerType = (dataPayload["data"] as? [String: Any])?["type"] as? String
            ?? dataPayload["type"] as? String ?? ""
        let inner = (dataPayload["data"] as? [String: Any]) ?? dataPayload

        logger.info("🎯 [Action] handleActionSocketEvent innerType=\(innerType, privacy: .public) ack=\(ack != nil, privacy: .public)")

        if ack == nil {
            // Fire-and-forget event from __event_emitter__ (status, notification, replace, message)
            switch innerType {
            case "status":
                let description = inner["description"] as? String ?? ""
                let done = inner["done"] as? Bool ?? false
                let name = inner["action"] as? String ?? action.name
                if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                    if let existingIdx = viewModel.conversation?.messages[idx].statusHistory.firstIndex(where: { $0.action == name && $0.done != true }) {
                        viewModel.conversation?.messages[idx].statusHistory[existingIdx] = ChatStatusUpdate(action: name, description: description, done: done)
                    } else {
                        viewModel.conversation?.messages[idx].statusHistory.append(
                            ChatStatusUpdate(action: name, description: description, done: done)
                        )
                    }
                }
            case "notification":
                let msg = inner["content"] as? String ?? inner["message"] as? String ?? ""
                actionNotificationToast = msg
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    actionNotificationToast = nil
                }
            case "replace":
                let content = inner["content"] as? String ?? ""
                if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                    viewModel.conversation?.messages[idx].content = content
                }
            case "message":
                let content = inner["content"] as? String ?? ""
                if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                    viewModel.conversation?.messages[idx].content += content
                }
            default:
                break
            }
        } else {
            // Bidirectional call from __event_call__ (execute, input, confirmation) — must ack.
            // For "execute" we don't need user input — handle directly and ack.
            if innerType == "execute" {
                let code = inner["code"] as? String ?? inner["script"] as? String ?? ""
                let result = await handleExecuteEvent(code: code)
                let ackValue: Any?
                switch result {
                case .string(let s): ackValue = s
                case .bool(let b):   ackValue = b
                case .cancelled:     ackValue = false
                }
                ack?(ackValue)
                return
            }

            // For "input" / "confirmation" show a sheet, suspend until user responds,
            // then call the Socket.IO ack so the server's sio.call() can resume.
            let userResponse = await withCheckedContinuation { (continuation: CheckedContinuation<ActionCallResponse, Never>) in
                actionCallContinuation = continuation
                switch innerType {
                case "input":
                    let title   = inner["title"] as? String ?? "Input Required"
                    let msg     = inner["message"] as? String ?? inner["description"] as? String ?? ""
                    let placeholder = inner["placeholder"] as? String ?? ""
                    let defaultVal  = inner["value"] as? String ?? ""
                    actionInputText = defaultVal
                    actionInputRequest = ActionInputRequest(
                        title: title,
                        message: msg,
                        placeholder: placeholder,
                        defaultValue: defaultVal
                    )
                case "confirmation":
                    let title = inner["title"] as? String ?? "确认"
                    let msg   = inner["message"] as? String ?? inner["description"] as? String ?? "Are you sure?"
                    actionConfirmRequest = ActionConfirmRequest(title: title, message: msg)
                default:
                    // Unknown call type — resolve immediately so the server doesn't hang.
                    continuation.resume(returning: .bool(true))
                }
            }

            let ackValue: Any?
            switch userResponse {
            case .string(let s): ackValue = s
            case .bool(let b):   ackValue = b
            case .cancelled:     ackValue = false
            }
            ack?(ackValue)
        }
    }

    /// Resolves a file ID from a filename by querying the user's file list.
    /// Falls back to the most recently created file with the same extension if exact name not found.
    private func resolveFileId(forFilename filename: String, apiClient: APIClient) async -> String? {
        guard let files = try? await apiClient.getUserFiles(), !files.isEmpty else {
            logger.warning("⚠️ [Action] getUserFiles() returned nil or empty")
            return nil
        }
        logger.info("📂 [Action] getUserFiles returned \(files.count, privacy: .public) files")
        for f in files.prefix(5) {
            logger.info("  file id=\(f.id, privacy: .public) filename=\(f.filename ?? "nil", privacy: .public)")
        }

        // Exact match first
        if let exact = files.first(where: { $0.filename == filename }) {
            logger.info("✅ [Action] Exact file match: id=\(exact.id, privacy: .public)")
            return exact.id
        }

        // Fallback: match by extension, pick newest (highest createdAt)
        let ext = (filename as NSString).pathExtension.lowercased()
        let byExt = files.filter { ($0.filename as NSString?)?.pathExtension.lowercased() == ext }
        let newest = byExt.max(by: { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) })
        if let newest {
            logger.info("✅ [Action] Fallback to newest '\(ext, privacy: .public)' file: id=\(newest.id, privacy: .public) filename=\(newest.filename ?? "nil", privacy: .public)")
            return newest.id
        }

        return nil
    }

    /// Handles `__event_call__` `execute` events.
    /// Tries proven regex fast-paths first (instant, no WKWebView overhead).
    /// Falls back to ActionJSExecutor (hidden WKWebView) for unknown JS patterns.
    private func handleExecuteEvent(code: String) async -> ActionCallResponse {
        logger.info("🟡 [Execute] code length=\(code.count, privacy: .public)")

        // ── Fast path 1: server file download URL (/api/v1/files/{id}) ──────────────
        let serverBase = viewModel.serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filesUrlPattern = #"['"]((https?://[^\s'"]+/api/v1/files/[^\s'"]+|/api/v1/files/[^\s'"]+))['"]"#
        if let regex = try? NSRegularExpression(pattern: filesUrlPattern),
           let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
           let urlRange = Range(match.range(at: 1), in: code) {
            let urlStr = String(code[urlRange])
            let fullURL = urlStr.hasPrefix("/") ? "\(serverBase)\(urlStr)" : urlStr
            let parts = fullURL.split(separator: "/")
            if let filesIdx = parts.firstIndex(of: "files"), filesIdx + 1 < parts.count {
                let fileId = String(parts[filesIdx + 1])
                logger.info("🟡 [Execute] Fast-path 1: server file id=\(fileId, privacy: .public)")
                isDownloadingFile = true
                await downloadAndShareFile(fileId: fileId)
                isDownloadingFile = false
                return .bool(true)
            }
        }

        // Extract filename from JS for use in fast paths 2 & 3
        var fileName = "export.pdf"
        let filenamePatterns = [
            #"(?:fileName|filename|name)\s*=\s*['"]([^'"]+\.[a-zA-Z0-9]+)['"]"#,
            #"saveAs\([^,]+,\s*['"]([^'"]+\.[a-zA-Z0-9]+)['"]\)"#,
            #"download\s*=\s*['"]([^'"]+\.[a-zA-Z0-9]+)['"]"#,
        ]
        for pattern in filenamePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
               let fnRange = Range(match.range(at: 1), in: code) {
                fileName = String(code[fnRange])
                logger.info("🟡 [Execute] Extracted filename: \(fileName, privacy: .public)")
                break
            }
        }

        // ── Fast path 2: `const base64 = "..."` / `base64 = "..."` ──────────────────
        // Iexa native server PDF export embeds the file as a base64 variable in the execute JS.
        let base64VarPattern = #"(?:const\s+|let\s+|var\s+)?base64\s*=\s*['"]([A-Za-z0-9+/=\r\n]{20,})['"]"#
        if let regex = try? NSRegularExpression(pattern: base64VarPattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
           let b64Range = Range(match.range(at: 1), in: code) {
            let rawB64 = String(code[b64Range])
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            if let data = Data(base64Encoded: rawB64), !data.isEmpty {
                logger.info("✅ [Execute] Fast-path 2: base64 var → \(data.count, privacy: .public) bytes as \(fileName, privacy: .public)")
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try? await Self.writeData(data, to: tempFile)
                downloadedFileURL = tempFile
                return .bool(true)
            }
        }

        // ── Fast path 3: atob("...") call ────────────────────────────────────────────
        let atobPattern = #"atob\(['"]([A-Za-z0-9+/=]{20,})['"]\)"#
        if let regex = try? NSRegularExpression(pattern: atobPattern),
           let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
           let b64Range = Range(match.range(at: 1), in: code) {
            let b64 = String(code[b64Range])
            if let data = Data(base64Encoded: b64), !data.isEmpty {
                logger.info("✅ [Execute] Fast-path 3: atob → \(data.count, privacy: .public) bytes as \(fileName, privacy: .public)")
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try? await Self.writeData(data, to: tempFile)
                downloadedFileURL = tempFile
                return .bool(true)
            }
        }

        // ── Fallback: WKWebView execution (catches unknown patterns) ─────────────────
        // Skip scripts that are clearly browser-only (CDN imports, html2canvas, etc.)
        let isBrowserOnlyScript = code.contains("import(") || code.contains("html2canvas") || code.contains("cdn.jsdelivr")
        guard !isBrowserOnlyScript, let baseURL = URL(string: serverBase) else {
            logger.info("🟡 [Execute] Skipping browser-only or unparseable script, unblocking server")
            return .bool(true)
        }

        logger.info("🟡 [Execute] No regex match — delegating to ActionJSExecutor")
        isDownloadingFile = true
        let download = await ActionJSExecutor.shared.execute(code: code, baseURL: baseURL)
        isDownloadingFile = false

        if let download {
            logger.info("✅ [Execute] ActionJSExecutor captured: \(download.filename, privacy: .public) \(download.data.count, privacy: .public) bytes")
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(download.filename)
            try? await Self.writeData(download.data, to: tempFile)
            downloadedFileURL = tempFile
        } else {
            logger.warning("⚠️ [Execute] ActionJSExecutor returned nil (timeout or error)")
        }

        return .bool(true)
    }

    private func cleanedMessageTextForSharing(_ message: ChatMessage) -> String {
        var clean = message.content
        if let re = try? NSRegularExpression(pattern: #"<details[^>]*>.*?</details>"#, options: [.dotMatchesLineSeparators]) {
            clean = re.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        }
        clean = clean
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.sources.isEmpty {
            clean += "\n\nSources:"
            for (i, src) in message.sources.enumerated() {
                clean += "\n[\(i+1)] \(src.resolvedURL ?? src.title ?? "Source \(i+1)")"
            }
        }
        return clean
    }

    private func copyMessage(_ message: ChatMessage) {
        let clean = cleanedMessageTextForSharing(message)
        UIPasteboard.general.string = clean
        Haptics.notify(.success)
        withAnimation(MicroAnimation.gentle) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(MicroAnimation.gentle) { showCopiedToast = false }
        }
    }

    private func shareMessage(_ message: ChatMessage) {
        let text = cleanedMessageTextForSharing(message)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messageShareItem = MessageShareItem(text: text)
        Haptics.play(.light)
    }

    private func recordAssistantFeedback(_ vote: AssistantFeedbackVote, for message: ChatMessage) {
        assistantFeedbackVoteOverrides[message.id] = vote
        AssistantFeedbackPreferenceStore.setVote(
            vote,
            messageId: message.id,
            conversationId: viewModel.conversation?.id,
            model: message.model ?? viewModel.selectedModelId,
            content: message.content
        )
        Haptics.notify(.success)
    }

    // MARK: - Attachment Processing

    private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
                    let resized = await Self.downsampleDataForUpload(data)
                    let thumbnail = UIImage(data: resized).map { Image(uiImage: $0) }
                    let attachment = ChatAttachment(
                        type: .image, name: "Photo_\(Int(Date.now.timeIntervalSince1970)).jpg",
                        thumbnail: thumbnail, data: resized
                    )
                    viewModel.attachments.append(attachment)
                    // Start uploading immediately so it's ready by send time
                    viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func processFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? await Task.detached(priority: .userInitiated, operation: {
            try Data(contentsOf: url)
        }).value else {
            viewModel.errorMessage = "Failed to read file."
            return
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        if isImage {
            // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
            let resized = await Self.downsampleDataForUpload(data)
            let thumbnail: Image? = UIImage(data: resized).map { Image(uiImage: $0) }
            let attachment = ChatAttachment(
                type: .image, name: url.lastPathComponent,
                thumbnail: thumbnail, data: resized
            )
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        } else {
            let attachment = ChatAttachment(
                type: .file, name: url.lastPathComponent,
                thumbnail: nil, data: data
            )
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        }
    }

    private func processCameraImage(_ image: UIImage?) {
        guard let image else { return }
        // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
        let data = FileAttachmentService.downsampleForUpload(image: image)
        guard !data.isEmpty else { return }
        let attachment = ChatAttachment(
            type: .image, name: "Camera_\(Int(Date.now.timeIntervalSince1970)).jpg",
            thumbnail: Image(uiImage: image), data: data
        )
        viewModel.attachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
    }

    private func prepareGeneratedImageForEditing(_ image: UIImage) {
        let data = FileAttachmentService.downsampleForUpload(image: image)
        guard !data.isEmpty else {
            viewModel.errorMessage = "无法读取这张图片"
            return
        }

        let attachment = ChatAttachment(
            type: .image,
            name: "Edit_Source_\(Int(Date.now.timeIntervalSince1970)).jpg",
            thumbnail: Image(uiImage: image),
            data: data
        )
        viewModel.attachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        viewModel.imageGenerationEnabled = true
        if viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.inputText = "编辑这张图："
        }
    }

    private static func downsampleDataForUpload(_ data: Data) async -> Data {
        await Task.detached(priority: .userInitiated) {
            FileAttachmentService.downsampleForUpload(data: data)
        }.value
    }

    private func processAudioFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? await Task.detached(priority: .userInitiated, operation: {
            try Data(contentsOf: url)
        }).value else {
            viewModel.errorMessage = "Failed to read audio file."
            return
        }
        let attachment = ChatAttachment(type: .audio, name: url.lastPathComponent, thumbnail: nil, data: data)
        viewModel.attachments.append(attachment)

        // Route to the user-selected transcription engine.
        // "device" and "server" are live-speech engines, not file transcription — skip ML for those.
        // Route based on the audio file transcription mode setting.
        // "server" (default): upload the audio file to the server via the files API —
        //   the server handles transcription/processing automatically (?process=true).
        //   No on-device work needed; the user can navigate away freely.
        // "device": use on-device Parakeet/Qwen3 ASR (existing behavior).
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        if audioFileMode == "server" {
            // Treat audio exactly like any other file attachment — upload immediately.
            // The server processes the audio via ?process=true and handles transcription.
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        } else {
            // On-device mode: delegate to ViewModel so the Task survives navigation.
            viewModel.transcribeAudioAttachment(attachmentId: attachment.id, audioData: data, fileName: url.lastPathComponent)
        }
    }

    /// Opens a file in an in-app QuickLook preview.
    /// Uses a local cache keyed by file ID so files that were just uploaded
    /// don't need to be re-downloaded from the server.
    private func previewFileInApp(fileId: String, fileName: String) async {
        // Check cache first — if we already have this file locally, show it instantly
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let cachedFile = cacheDir.appendingPathComponent("\(fileId)_\(fileName)")
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            previewFileURL = cachedFile
            return
        }

        // Not cached — download from server
        guard let apiClient = dependencies.apiClient else { return }
        withAnimation { isDownloadingFile = true }

        do {
            let (data, _) = try await apiClient.getFileContent(id: fileId)
            try await Self.writeData(data, to: cachedFile)
            withAnimation { isDownloadingFile = false }
            previewFileURL = cachedFile
        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "文件加载失败：\(error.localizedDescription)"
            showDownloadError = true
        }
    }

    private func previewFileReference(fileId: String, fileName: String) async {
        if fileId.hasPrefix("data:") {
            do {
                previewFileURL = try await Self.localFileURL(fromDataURL: fileId, fallbackName: fileName)
            } catch {
                downloadErrorMessage = "媒体预览失败：\(error.localizedDescription)"
                showDownloadError = true
            }
            return
        }

        if let url = URL(string: fileId), url.isFileURL {
            previewFileURL = url
            return
        }

        await previewFileInApp(fileId: fileId, fileName: fileName)
    }

    private static func writeData(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try data.write(to: url)
        }.value
    }

    private static func replaceFile(at sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }.value
    }

    /// Downloads a file from the server using the authenticated API client,
    /// saves it to a temp directory, and presents the iOS share sheet.
    private func downloadAndShareFile(fileId: String) async {
        guard let apiClient = dependencies.apiClient else {
            downloadErrorMessage = "尚未连接站点。"
            showDownloadError = true
            return
        }

        withAnimation { isDownloadingFile = true }

        do {
            let (data, contentType) = try await apiClient.getFileContent(id: fileId)

            // Try to get the file name from file info
            var fileName = "download"
            if let info = try? await apiClient.getFileInfo(id: fileId) {
                if let meta = info["meta"] as? [String: Any], let name = meta["name"] as? String {
                    fileName = name
                } else if let name = info["filename"] as? String {
                    fileName = name
                } else if let name = info["name"] as? String {
                    fileName = name
                }
            }

            // If no extension, try to infer from content type
            if (fileName as NSString).pathExtension.isEmpty {
                let ext: String
                switch contentType {
                case let ct where ct.contains("pdf"): ext = "pdf"
                case let ct where ct.contains("word") || ct.contains("docx"): ext = "docx"
                case let ct where ct.contains("spreadsheet") || ct.contains("xlsx"): ext = "xlsx"
                case let ct where ct.contains("presentation") || ct.contains("pptx"): ext = "pptx"
                case let ct where ct.contains("plain"): ext = "txt"
                case let ct where ct.contains("json"): ext = "json"
                case let ct where ct.contains("png"): ext = "png"
                case let ct where ct.contains("jpeg") || ct.contains("jpg"): ext = "jpg"
                default: ext = "bin"
                }
                fileName = "\(fileName).\(ext)"
            }

            // Save to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(fileName)
            try await Self.writeData(data, to: tempFile)

            withAnimation { isDownloadingFile = false }

            // Present share sheet
            downloadedFileURL = tempFile

        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "下载失败：\(error.localizedDescription)"
            showDownloadError = true
        }
    }

    private func downloadAndShareRemoteFile(url: URL, suggestedName: String? = nil) async {
        withAnimation { isDownloadingFile = true }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            applyRemoteMediaDownloadHeaders(to: &request, sourceURL: url)

            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            try validateDownloadedRemoteMedia(at: temporaryURL, response: response, sourceURL: url)
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let fileName = resolvedDownloadFileName(
                suggestedName: suggestedName,
                response: response,
                contentType: contentType,
                url: url
            )
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try await Self.replaceFile(at: temporaryURL, to: destination)

            withAnimation { isDownloadingFile = false }
            downloadedFileURL = destination
        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "下载失败：\(error.localizedDescription)"
            showDownloadError = true
        }
    }

    private func validateDownloadedRemoteMedia(at fileURL: URL, response: URLResponse, sourceURL: URL) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw URLError(.badServerResponse)
        }

        let values = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (values[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 1_024 else {
            try? FileManager.default.removeItem(at: fileURL)
            throw URLError(.cannotDecodeContentData)
        }

        if shouldValidateRemoteMediaAsMP4(sourceURL: sourceURL, response: response) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { handle.closeFile() }
            let data = handle.readData(ofLength: 12)
            guard data.count >= 12,
                  data.subdata(in: 4..<8) == Data("ftyp".utf8) else {
                try? FileManager.default.removeItem(at: fileURL)
                throw URLError(.cannotDecodeContentData)
            }
        }
    }

    private func shouldValidateRemoteMediaAsMP4(sourceURL: URL, response: URLResponse) -> Bool {
        let lower = sourceURL.absoluteString.lowercased()
        let contentType = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return sourceURL.pathExtension.lowercased() == "mp4"
            || lower.contains("sns-video")
            || lower.contains("sns-bak")
            || lower.contains("xhs-video")
            || lower.contains("downloader-api.bhwa233.com/api/download")
            || lower.contains("aweme/v1/play")
            || contentType.contains("video/mp4")
    }

    private func isDownloadableMediaURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        let pathExt = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm", "avi", "mkv", "mp3", "wav", "m4a", "flac"].contains(pathExt) {
            return true
        }
        return lower.contains("aweme.snssdk.com/aweme/v1/play")
            || lower.contains("mime_type=video")
            || lower.contains("video_id=")
            || lower.contains("sns-video")
            || lower.contains("sns-bak")
            || lower.contains("xhs-video")
            || lower.contains("downloader-api.bhwa233.com/api/download")
    }

    private func applyRemoteMediaDownloadHeaders(to request: inout URLRequest, sourceURL: URL) {
        if Self.isXiaohongshuCDNMediaURL(sourceURL) {
            request.setValue(Self.xiaohongshuMediaUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(
                "image/avif,image/webp,image/apng,image/*,video/mp4,video/*,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://www.xiaohongshu.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
            if Self.isRemoteVideoMediaURL(sourceURL) {
                request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            }
            return
        }

        request.setValue(Self.mediaDownloadUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(sourceURL.host.map { "https://\($0)" } ?? "https://www.iesdouyin.com", forHTTPHeaderField: "Referer")
    }

    private static func isXiaohongshuCDNMediaURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "ci.xiaohongshu.com" || host == "xhscdn.com" || host.hasSuffix(".xhscdn.com")
    }

    private static func isRemoteVideoMediaURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
            || lower.contains("sns-video")
            || lower.contains("sns-bak")
            || lower.contains("xhs-video")
    }

    private func suggestedFileName(from url: URL) -> String {
        let decoded = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !decoded.isEmpty, decoded != "/" {
            return decoded
        }
        return isDownloadableMediaURL(url) ? "download.mp4" : "download"
    }

    private func resolvedDownloadFileName(
        suggestedName: String?,
        response: URLResponse,
        contentType: String,
        url: URL
    ) -> String {
        if let httpResponse = response as? HTTPURLResponse,
           let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
           let name = filenameFromContentDisposition(disposition),
           !name.isEmpty {
            return name
        }

        let trimmed = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseName = trimmed.isEmpty ? suggestedFileName(from: url) : trimmed
        if !(baseName as NSString).pathExtension.isEmpty {
            return baseName
        }

        let ext: String
        let lowerContentType = contentType.lowercased()
        if lowerContentType.contains("video/mp4") {
            ext = "mp4"
        } else if lowerContentType.contains("quicktime") {
            ext = "mov"
        } else if lowerContentType.contains("webm") {
            ext = "webm"
        } else if lowerContentType.contains("mpeg") {
            ext = "mp3"
        } else if lowerContentType.contains("audio") {
            ext = "m4a"
        } else if isDownloadableMediaURL(url) {
            ext = "mp4"
        } else {
            ext = "bin"
        }
        return "\(baseName).\(ext)"
    }

    private func filenameFromContentDisposition(_ disposition: String) -> String? {
        let patterns = [
            #"filename\*=UTF-8''([^;]+)"#,
            #"filename="([^"]+)""#,
            #"filename=([^;]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: disposition) else { continue }
            return String(disposition[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;"))
                .removingPercentEncoding
        }
        return nil
    }

    private static let mediaDownloadUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let xiaohongshuMediaUserAgent =
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36 xiaohongshu"

    // MARK: - #URL Suggestion Pill

    /// Floating pill shown when the user types `#https://...` in the input field.
    /// Tapping the pill triggers the web scraping pipeline and strips the `#URL`
    /// token from the input text. Dismissing (deleting the `#`) hides the pill
    /// and leaves the text as-is.
    private func webURLSuggestionPill(url: String) -> some View {
        Button {
            // 1. Strip the #URL token from the input text
            let token = "#\(url)"
            if let range = viewModel.inputText.range(of: token) {
                viewModel.inputText.removeSubrange(range)
                viewModel.inputText = viewModel.inputText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 2. Trigger the web scraping → upload → file attachment pipeline
            viewModel.processWebURL(urlString: url)
            // 3. Clear the suggestion state
            withAnimation(.easeOut(duration: 0.15)) {
                detectedWebURL = nil
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "globe")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
                Text(url)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.85 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.brandPrimary.opacity(0.3), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.sm)
    }

    private func processWebURL() {
        let urlString = webURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        viewModel.processWebURL(urlString: urlString)
        webURLInput = ""
    }
}

// MARK: - Isolated Streaming Status (Observation Isolation)

/// Isolates streaming status reads into its own view body so that
/// `StreamingContentStore` property accesses (streamingStatusHistory,
/// streamingContent, isActive) are attributed to THIS struct's body —
/// not to ChatDetailView.body. Without this, every token arrival would
/// re-evaluate the entire 800+ line ChatDetailView.
private struct IsolatedStreamingStatus: View {
    let streamingStore: StreamingContentStore
    let message: ChatMessage

    private func shouldShowInlineStatus(_ status: ChatStatusUpdate) -> Bool {
        guard status.hidden != true else { return false }
        let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return action != "local_alpine"
            && action != "local_alpine_agent"
            && action != "local_alpine_tool"
            && action != "local_native_tool"
    }

    var body: some View {
        let isActiveStore = streamingStore.streamingMessageId == message.id
            && streamingStore.isActive
        let effectiveStatusHistory = isActiveStore
            ? streamingStore.streamingStatusHistory
            : message.statusHistory
        let effectiveIsStreaming = isActiveStore || message.isStreaming

        if !effectiveStatusHistory.isEmpty {
            let visible = effectiveStatusHistory.filter(shouldShowInlineStatus)
            if !visible.isEmpty {
                let hasPending = visible.contains { $0.done != true }
                StreamingStatusView(
                    statusHistory: visible,
                    isStreaming: effectiveIsStreaming && hasPending
                )
                .padding(.bottom, Spacing.xs)
                .transition(.opacity)
            }
        }
    }
}

private enum ChatAmbientBackgroundMode: Equatable {
    case normal
    case idleFirstTurn
    case activeFirstTurn
}

private struct ChatAmbientBackgroundView: View {
    let mode: ChatAmbientBackgroundMode

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background

            switch mode {
            case .normal:
                Color.clear
            case .idleFirstTurn:
                idleGradient
                    .transition(.opacity)
            case .activeFirstTurn:
                activeGradient
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: mode)
    }

    private var idleGradient: some View {
        LinearGradient(
            colors: [
                Color.clear,
                Color(red: 0.94, green: 0.98, blue: 1.00).opacity(theme.isDark ? 0.08 : 0.32),
                Color(red: 0.60, green: 0.82, blue: 1.00).opacity(theme.isDark ? 0.18 : 0.78)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottomLeading) {
            RadialGradient(
                colors: [
                    Color(red: 0.52, green: 0.77, blue: 1.00).opacity(theme.isDark ? 0.12 : 0.28),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 420
            )
        }
    }

    private var activeGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.38, green: 0.88, blue: 0.76).opacity(theme.isDark ? 0.22 : 0.76),
                Color(red: 0.58, green: 0.83, blue: 1.00).opacity(theme.isDark ? 0.20 : 0.70),
                Color(red: 0.88, green: 1.00, blue: 0.82).opacity(theme.isDark ? 0.12 : 0.50),
                Color.white.opacity(theme.isDark ? 0.00 : 0.72)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [
                    Color(red: 0.46, green: 0.95, blue: 0.74).opacity(theme.isDark ? 0.18 : 0.35),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 8,
                endRadius: 360
            )
        }
        .overlay {
            RadialGradient(
                colors: [
                    Color(red: 0.46, green: 0.75, blue: 1.00).opacity(theme.isDark ? 0.14 : 0.30),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 420
            )
        }
    }
}

// MARK: - Image Generation Placeholder

private struct ImageGenerationPlaceholderView: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isActive = false
    @State private var hasEntered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return DynamicImageGenerationGradient(
            isDark: theme.isDark,
            isActive: isActive && !reduceMotion
        )
        .allowsHitTesting(false)
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(Color.white.opacity(theme.isDark ? 0.08 : 0.16), lineWidth: 0.75)
        }
        .background {
            shape
                .fill(Color.black.opacity(theme.isDark ? 0.16 : 0.05))
                .offset(y: 6)
                .blur(radius: 10)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(hasEntered ? 1 : 0)
        .scaleEffect(hasEntered ? 1 : 0.985, anchor: .topLeading)
        .offset(y: hasEntered ? 0 : 8)
        .animation(
            reduceMotion ? nil : .interactiveSpring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.08),
            value: hasEntered
        )
        .onAppear {
            isActive = scenePhase == .active
            beginEntranceIfNeeded()
        }
        .onDisappear { isActive = false }
        .onChange(of: scenePhase) { _, phase in
            isActive = phase == .active
        }
    }

    private func beginEntranceIfNeeded() {
        guard !hasEntered else { return }
        if reduceMotion {
            hasEntered = true
            return
        }
        DispatchQueue.main.async {
            hasEntered = true
        }
    }
}

private struct DynamicImageGenerationGradient: View {
    let isDark: Bool
    let isActive: Bool

    var body: some View {
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    ImageGenerationGradientCanvas(
                        isDark: isDark,
                        time: Self.animationTime(for: timeline.date)
                    )
                }
            } else {
                ImageGenerationGradientCanvas(isDark: isDark, time: 0.18)
            }
        }
    }

    private static func animationTime(for date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }
}

private struct ImageGenerationGradientCanvas: View {
    let isDark: Bool
    let time: Double

    var body: some View {
        Canvas(opaque: true, colorMode: .linear, rendersAsynchronously: true) { context, size in
            guard size.width > 1, size.height > 1 else { return }

            let rect = CGRect(origin: .zero, size: size)
            var rectPath = Path()
            rectPath.addRect(rect)
            context.fill(
                rectPath,
                with: .linearGradient(
                    Gradient(colors: baseColors),
                    startPoint: movingPoint(x: -0.10, y: 0.12, scale: size, phaseOffset: 0.00),
                    endPoint: movingPoint(x: 1.12, y: 0.92, scale: size, phaseOffset: 0.42)
                )
            )

            let shortEdge = min(size.width, size.height)
            drawPatch(
                in: &context,
                size: size,
                base: CGPoint(x: 0.20, y: 0.20),
                radius: shortEdge * 0.70,
                color: Color(red: 1.00, green: 0.72, blue: 0.28),
                speed: 0.88,
                offset: 0.03,
                opacity: isDark ? 0.44 : 0.38
            )
            drawPatch(
                in: &context,
                size: size,
                base: CGPoint(x: 0.76, y: 0.22),
                radius: shortEdge * 0.78,
                color: Color(red: 0.24, green: 0.78, blue: 1.00),
                speed: 0.96,
                offset: 0.24,
                opacity: isDark ? 0.48 : 0.40
            )
            drawPatch(
                in: &context,
                size: size,
                base: CGPoint(x: 0.30, y: 0.74),
                radius: shortEdge * 0.82,
                color: Color(red: 0.78, green: 0.44, blue: 1.00),
                speed: 0.82,
                offset: 0.53,
                opacity: isDark ? 0.48 : 0.42
            )
            drawPatch(
                in: &context,
                size: size,
                base: CGPoint(x: 0.84, y: 0.78),
                radius: shortEdge * 0.70,
                color: Color(red: 0.20, green: 1.00, blue: 0.62),
                speed: 0.92,
                offset: 0.79,
                opacity: isDark ? 0.40 : 0.36
            )
            drawPatch(
                in: &context,
                size: size,
                base: CGPoint(x: 0.54, y: 0.48),
                radius: shortEdge * 0.66,
                color: Color(red: 1.00, green: 0.42, blue: 0.68),
                speed: 1.10,
                offset: 0.41,
                opacity: isDark ? 0.36 : 0.32
            )
        }
        .saturation(isDark ? 1.12 : 1.06)
        .contrast(isDark ? 1.04 : 1.01)
        .opacity(isDark ? 0.92 : 0.96)
    }

    private var baseColors: [Color] {
        isDark
            ? [
                Color(red: 0.12, green: 0.24, blue: 0.32),
                Color(red: 0.18, green: 0.28, blue: 0.48),
                Color(red: 0.34, green: 0.22, blue: 0.48),
                Color(red: 0.28, green: 0.34, blue: 0.20)
            ]
            : [
                Color(red: 0.50, green: 0.92, blue: 0.86),
                Color(red: 0.58, green: 0.78, blue: 1.00),
                Color(red: 0.84, green: 0.68, blue: 1.00),
                Color(red: 1.00, green: 0.78, blue: 0.64)
            ]
    }

    private func movingPoint(x: Double, y: Double, scale size: CGSize, phaseOffset: Double) -> CGPoint {
        let angle = time * 0.68 + phaseOffset * .pi * 2
        return CGPoint(
            x: size.width * CGFloat(x + 0.18 * sin(angle) + 0.07 * cos(angle * 1.7)),
            y: size.height * CGFloat(y + 0.14 * cos(angle * 0.8) + 0.05 * sin(angle * 1.3))
        )
    }

    private func drawPatch(
        in context: inout GraphicsContext,
        size: CGSize,
        base: CGPoint,
        radius: CGFloat,
        color: Color,
        speed: Double,
        offset: Double,
        opacity: Double
    ) {
        let angle = time * speed + offset * .pi * 2
        let driftX = 0.25 * sin(angle) + 0.08 * cos(angle * 0.73)
        let driftY = 0.22 * cos(angle * 0.82 + 0.35) + 0.08 * sin(angle * 1.17)
        let pulse = 1.0 + 0.10 * sin(angle * 1.3 + 0.4)
        let center = CGPoint(
            x: size.width * min(1.12, max(-0.12, base.x + CGFloat(driftX))),
            y: size.height * min(1.12, max(-0.12, base.y + CGFloat(driftY)))
        )
        let effectiveRadius = radius * CGFloat(pulse)
        let rect = CGRect(
            x: center.x - effectiveRadius,
            y: center.y - effectiveRadius,
            width: effectiveRadius * 2,
            height: effectiveRadius * 2
        )
        let path = Path(ellipseIn: rect)
        let secondary = color.opacity(opacity * 0.62)
        let resolved = GraphicsContext.Shading.radialGradient(
            Gradient(colors: [
                color.opacity(opacity),
                secondary,
                color.opacity(0.0)
            ]),
            center: center,
            startRadius: 0,
            endRadius: effectiveRadius
        )
        context.fill(path, with: resolved)
    }
}

private struct ImageGenerationTitleShimmer: View {
    let text: String

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        titleText
            .foregroundStyle(theme.textPrimary.opacity(theme.isDark ? 0.82 : 0.72))
            .overlay {
                if reduceMotion || scenePhase != .active {
                    titleText.foregroundStyle(theme.textPrimary)
                } else {
                    GeometryReader { geometry in
                        let width = max(geometry.size.width, 1)
                        let sweepWidth = max(width * 0.72, 86)

                        LinearGradient(
                            colors: [
                                .clear,
                                theme.textPrimary.opacity(theme.isDark ? 0.42 : 0.30),
                                Color.white.opacity(theme.isDark ? 0.86 : 0.95),
                                theme.textPrimary.opacity(theme.isDark ? 0.36 : 0.24),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: sweepWidth)
                        .offset(x: -sweepWidth + shimmerPhase * (width + sweepWidth * 2))
                    }
                    .mask(titleText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .accessibilityLabel(Text(text))
            .onAppear {
                startShimmerIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    startShimmerIfNeeded()
                } else {
                    shimmerPhase = -1
                }
            }
    }

    private var titleText: some View {
        Text(text)
            .scaledFont(size: 18, weight: .semibold, context: .content)
    }

    private func startShimmerIfNeeded() {
        guard !reduceMotion, scenePhase == .active else {
            shimmerPhase = -1
            return
        }
        shimmerPhase = -1
        withAnimation(.linear(duration: 1.85).repeatForever(autoreverses: false)) {
            shimmerPhase = 1
        }
    }
}

// MARK: - Isolated Assistant Message (Observation Isolation)

/// Isolates ALL streaming store reads for assistant message content into
/// its own view body. This is the single most impactful performance fix:
///
/// **Before:** `streamingStore.streamingContent` was read inside
/// `ChatDetailView.messageContent()` which is called from `body`.
/// Swift's @Observable macro attributes that read to ChatDetailView,
/// causing the ENTIRE view (800+ lines, all messages, toolbar, input)
/// to re-evaluate on every token (~15-20x/sec).
///
/// **After:** Only this small struct re-evaluates per token. All other
/// message views, the toolbar, input field, and scroll infrastructure
/// remain completely inert during streaming.
///
/// ## Fixed-Height Streaming Container (VStack Re-layout Fix)
/// During active streaming, the content is wrapped in a fixed-height
/// (400pt) container with internal scrolling. This prevents the parent
/// VStack from re-measuring ALL sibling message rows when the streaming
/// content grows in height. When streaming completes, the fixed height
/// is removed and full content renders at its natural height.
private struct IsolatedAssistantMessage: View {
    let streamingStore: StreamingContentStore
    let message: ChatMessage
    let activeVersionIndex: Int
    /// When set, overrides all other content resolution (used when showing an older user message edit version).
    /// This allows the UI to show the paired AI response for an older user edit WITHOUT creating fake
    /// regeneration versions on the assistant message.
    var contentOverride: String? = nil
    /// Suppressed once real inline agent/tool steps are visible for the message.
    var showEmptyThinkingCapsule: Bool = true
    let serverBaseURL: String
    /// Auth token passed down to Rich UI embed webviews for localStorage injection.
    var authToken: String? = nil
    /// APIClient for rendering inline images via AuthenticatedImageView.
    var apiClient: APIClient? = nil

    var body: some View {
        let isActivelyStreaming = streamingStore.streamingMessageId == message.id
            && streamingStore.isActive

        let vIdx = activeVersionIndex
        let rawContent: String = {
            // During streaming, use displayContent (the smoothly-drained version)
            // rather than streamingContent (raw server tokens). This gives the
            // typewriter effect — characters flow in at a smooth, readable rate
            // instead of bursting in large chunks.
            if isActivelyStreaming { return streamingStore.displayContent }
            // If there's a content override (older user edit version), use it
            if let override = contentOverride { return override }
            if vIdx >= 0 && vIdx < message.versions.count { return message.versions[vIdx].content }
            return message.content
        }()

        let baseSources: [ChatSourceReference] = isActivelyStreaming
            ? streamingStore.streamingSources : message.sources
        let effectiveSources = Self.effectiveCitationSources(
            baseSources: baseSources,
            statusHistory: isActivelyStreaming
                ? streamingStore.streamingStatusHistory
                : message.statusHistory
        )

        // During streaming: pass raw content through (zero processing per token).
        // After streaming: apply URL resolution and citation linking.
        // Note: soft breaks are now handled natively by MarkdownView (renders
        // \n as line breaks instead of spaces), so no convertSoftBreaksToHard needed.
        let displayContent: String = {
            if isActivelyStreaming {
                return Self.safeAssistantRenderableContent(rawContent)
            }
            let safeRawContent = Self.safeAssistantRenderableContent(rawContent)
            let resolved = Self.resolveRelativeURLs(safeRawContent, baseURL: serverBaseURL)
            let preferDomain = UserDefaults.standard.object(forKey: "citationShowDomain") as? Bool ?? true
            return Self.preprocessCitations(resolved, sources: effectiveSources, preferDomain: preferDomain)
        }()

        let effectiveIsStreaming = isActivelyStreaming || message.isStreaming

        if effectiveIsStreaming && rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if message.metadata?["iexa_local_alpine_result"] == "true"
                || (message.model == "Local Alpine" && message.statusHistory.contains(where: {
                    $0.action?.lowercased() == "local_alpine"
                })) {
                if showEmptyThinkingCapsule {
                    TypingIndicator()
                } else {
                    EmptyView()
                }
            } else if message.metadata?["iexa_image_generation_placeholder"] == "true" {
                ImageGenerationPlaceholderView()
            } else if showEmptyThinkingCapsule {
                TypingIndicator()
            } else {
                EmptyView()
            }
        } else {
            // Perf optimisation: when a tool-call block has been fully closed and
            // the frozen boundary is known, split the content so the heavy tool-call
            // HTML is never re-parsed after it finishes streaming.
            //
            // frozenContent — everything up to & including the last </details> close —
            // has a stable hashValue between display-link ticks. AssistantMessageContent's
            // ParseCache hits on every frame (zero re-parse cost).
            //
            // liveTextTail — the small prose that the user is currently reading —
            // is passed to a lightweight standalone StreamingMarkdownView so only
            // the handful of characters that changed this tick are re-rendered.
            let frozenBoundary = isActivelyStreaming ? streamingStore.frozenToolBoundaryOffset : 0
            // Only use the split-render path when the live tail is plain text.
            // VIZ markers (@@@VIZ-START) and <details blocks require AssistantMessageContent's
            // full routing (InlineVisualizerView, tool-call renderer, embed injection).
            // When those are present, fall through to the normal full-content path below.
            let liveTail = isActivelyStreaming ? streamingStore.liveTextTail : ""
            let liveTailHasSpecialContent = Self.requiresFullAssistantRouting(liveTail)
            if frozenBoundary > 0 && !liveTailHasSpecialContent {
                let dc = streamingStore.displayContent
                let frozenContent: String = {
                    guard dc.count >= frozenBoundary else { return dc }
                    return String(dc[..<dc.index(dc.startIndex, offsetBy: frozenBoundary)])
                }()

                VStack(alignment: .leading, spacing: 0) {
                    // Frozen tool-call / reasoning segments — hash is stable, cache always hits.
                    AssistantMessageContent(
                        content: frozenContent,
                        isStreaming: false,
                        messageEmbeds: message.embeds,
                        authToken: authToken,
                        serverBaseURL: serverBaseURL,
                        apiClient: apiClient
                    )
                    // Live tail — split further at the prose freeze boundary if available,
                    // so post-tool prose also benefits from paragraph-boundary freezing.
                    if !liveTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let proseBoundaryAbs = streamingStore.frozenProseBoundaryOffset
                        let relProseBoundary = proseBoundaryAbs > frozenBoundary
                            ? proseBoundaryAbs - frozenBoundary : 0
                        if relProseBoundary > 0 && liveTail.count >= relProseBoundary {
                            let splitIdx = liveTail.index(liveTail.startIndex, offsetBy: relProseBoundary)
                            let frozenTailProse = String(liveTail[..<splitIdx])
                            let liveProsTail   = String(liveTail[splitIdx...])
                            StreamingMarkdownView(
                                content: frozenTailProse,
                                isStreaming: false,
                                authToken: authToken,
                                serverBaseURL: serverBaseURL
                            )
                            if !liveProsTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                StreamingMarkdownView(
                                    content: liveProsTail,
                                    isStreaming: true,
                                    authToken: authToken,
                                    serverBaseURL: serverBaseURL
                                )
                            }
                        } else {
                            StreamingMarkdownView(
                                content: liveTail,
                                isStreaming: true,
                                authToken: authToken,
                                serverBaseURL: serverBaseURL
                            )
                        }
                    }
                }
                .transaction { $0.animation = nil }
            } else {
                // Fix D: paragraph-boundary freezing for pure prose streaming.
                //
                // When no tool calls or VIZ markers are present AND the message is long
                // enough (> 300 chars), split at the last completed paragraph boundary
                // (\n\n in the safe zone ≥200 chars from the current end).
                //
                // frozenProse  — everything up to the last \n\n — is rendered with
                //   isStreaming=false. Its content only changes when a new paragraph
                //   completes (~every few seconds) rather than on every display-link tick.
                //
                // liveProse    — the current in-progress paragraph, typically 50–200
                //   chars — is re-rendered every tick, but is tiny so MarkdownView's
                //   CommonMark parse is negligible (~20-40× cheaper than parsing the
                //   full multi-KB string at 60fps).
                //
                // Safety guards: skip if <details or @@@VIZ-START are present (those
                // need AssistantMessageContent's full routing), and skip if we are not
                // actively streaming (no benefit for already-completed messages).
                let proseFreezeOffset = isActivelyStreaming
                    ? streamingStore.frozenProseBoundaryOffset
                    : 0

                if proseFreezeOffset > 0,
                   displayContent.count >= proseFreezeOffset,
                   !Self.requiresFullAssistantRouting(displayContent),
                   !Self.containsCodeFence(displayContent) {
                    let dc = displayContent
                    let splitIdx = dc.index(dc.startIndex, offsetBy: proseFreezeOffset)
                    let frozenProse = String(dc[..<splitIdx])
                    let liveProse   = String(dc[splitIdx...])
                    VStack(alignment: .leading, spacing: 0) {
                        // Frozen paragraphs: hash changes only when boundary advances (~every 400 chars).
                        StreamingMarkdownView(
                            content: frozenProse,
                            isStreaming: false,
                            authToken: authToken,
                            serverBaseURL: serverBaseURL
                        )
                        // Live tail: current paragraph only, changes every tick.
                        if !liveProse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            StreamingMarkdownView(
                                content: liveProse,
                                isStreaming: true,
                                authToken: authToken,
                                serverBaseURL: serverBaseURL
                            )
                        }
                    }
                    .transaction { $0.animation = nil }
                } else {
                    AssistantMessageContent(
                        content: displayContent,
                        isStreaming: effectiveIsStreaming,
                        messageEmbeds: message.embeds,
                        authToken: authToken,
                        serverBaseURL: serverBaseURL,
                        apiClient: apiClient
                    )
                }
            }
        }
    }

    private static func requiresFullAssistantRouting(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        return lower.contains("@@@viz-start")
            || lower.contains("<details")
            || lower.contains("<think")
            || lower.contains("</think")
            || lower.contains("<thinking")
            || lower.contains("</thinking")
            || lower.contains("<reasoning")
            || lower.contains("</reasoning")
            || lower.contains("<reason")
            || lower.contains("</reason")
            || lower.contains("<thought")
            || lower.contains("</thought")
            || lower.contains("<|begin_of_thought|>")
            || lower.contains("<|end_of_thought|>")
            || text.contains("◁think▷")
            || text.contains("◁/think▷")
    }

    private static func safeAssistantRenderableContent(_ content: String) -> String {
        guard InlineDataPayloadSanitizer.mayContainLargeInlinePayload(content) else {
            return content
        }
        let cleaned = InlineDataPayloadSanitizer.sanitizedDisplayText(content)
        return InlineDataPayloadSanitizer.removingHiddenPayloadArtifacts(from: cleaned)
    }

    private static func containsCodeFence(_ text: String) -> Bool {
        text.contains("```")
    }

    // MARK: - Static Preprocessing (no ChatDetailView dependency)

    static func preprocessCitations(_ content: String, sources: [ChatSourceReference], preferDomain: Bool = true) -> String {
        var expanded = Self.preprocessLinkedCitationDestinations(content)
        guard !sources.isEmpty else { return expanded }

        // --- Pass 1: expand [1, 2, 3] → [1][2][3] so the single-number pass handles them ---
        let multiPattern = #"\[(\d+(?:\s*,\s*\d+)+)\](?!\()"#
        if let multiRegex = try? NSRegularExpression(pattern: multiPattern) {
            let nsExpanded = expanded as NSString
            let multiMatches = multiRegex.matches(in: expanded, range: NSRange(location: 0, length: nsExpanded.length))
            // Process in reverse to preserve indices
            for match in multiMatches.reversed() {
                guard let innerRange = Range(match.range(at: 1), in: expanded) else { continue }
                let numbers = expanded[innerRange]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let replacement = numbers.map { "[\($0)]" }.joined()
                if let fullRange = Range(match.range, in: expanded) {
                    expanded.replaceSubrange(fullRange, with: replacement)
                }
            }
        }

        // --- Pass 2: replace each [N] with a pill markdown link ---
        let pattern = #"\[(\d+)\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return expanded }
        var result = ""
        var searchStart = expanded.startIndex
        let nsContent = expanded as NSString
        let matches = regex.matches(in: expanded, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard let fullRange = Range(match.range, in: expanded),
                  let numberRange = Range(match.range(at: 1), in: expanded) else { continue }
            guard let index = Int(expanded[numberRange]) else { continue }
            result += expanded[searchStart..<fullRange.lowerBound]
            let sourceIdx = index - 1
            if sourceIdx >= 0 && sourceIdx < sources.count,
               let url = sources[sourceIdx].resolvedURL, !url.isEmpty {
                let label = sources[sourceIdx].displayLabel(preferDomain: preferDomain) ?? "\(index)"
                result += " [\(label)](\(url)#cite) "
            } else {
                result += expanded[fullRange]
            }
            searchStart = fullRange.upperBound
        }
        result += expanded[searchStart...]
        return result
    }

    private static func effectiveCitationSources(
        baseSources: [ChatSourceReference],
        statusHistory: [ChatStatusUpdate]
    ) -> [ChatSourceReference] {
        guard !statusHistory.isEmpty else { return baseSources }
        var merged = baseSources
        var seen = Set<String>()

        func sourceKey(_ source: ChatSourceReference) -> String? {
            if let url = source.resolvedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !url.isEmpty {
                return url.lowercased()
            }
            if let id = source.id?.trimmingCharacters(in: .whitespacesAndNewlines),
               !id.isEmpty {
                return id.lowercased()
            }
            return nil
        }

        for source in merged {
            if let key = sourceKey(source) {
                seen.insert(key)
            }
        }

        func appendSource(title: String?, url: String) {
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedURL.hasPrefix("http") else { return }
            let key = trimmedURL.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            merged.append(ChatSourceReference(
                id: trimmedURL,
                title: cleanTitle?.isEmpty == false ? cleanTitle : nil,
                url: trimmedURL
            ))
        }

        for status in statusHistory where status.hidden != true {
            for item in status.items {
                if let link = item.link {
                    appendSource(title: item.title, url: link)
                }
            }
            for url in status.urls {
                appendSource(title: nil, url: url)
            }
        }

        return merged
    }

    private static func preprocessLinkedCitationDestinations(_ content: String) -> String {
        let pattern = #"(?<!!)\[(\d+)\]\((https?://[^\s\)]+)(?:\s+["'][^"']*["'])?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return content }

        var result = content
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result),
                  let urlRange = Range(match.range(at: 2), in: result) else { continue }
            let number = String(result[numberRange])
            let url = String(result[urlRange])
            let destination = url.hasSuffix("#cite") ? url : "\(url)#cite"
            result.replaceSubrange(fullRange, with: "[\(number)](\(destination))")
        }
        return result
    }

    // Keep old signature body intact but redirect to the new implementation above
    private static func _preprocessCitationsOld(_ content: String, sources: [ChatSourceReference], preferDomain: Bool = true) -> String {
        guard !sources.isEmpty else { return content }
        let pattern = #"\[(\d+)\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        var result = ""
        var searchStart = content.startIndex
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard let fullRange = Range(match.range, in: content),
                  let numberRange = Range(match.range(at: 1), in: content) else { continue }
            guard let index = Int(content[numberRange]) else { continue }
            result += content[searchStart..<fullRange.lowerBound]
            let sourceIdx = index - 1
            if sourceIdx >= 0 && sourceIdx < sources.count,
               let url = sources[sourceIdx].resolvedURL, !url.isEmpty {
                let label = sources[sourceIdx].displayLabel(preferDomain: preferDomain) ?? "\(index)"
                // #cite suffix triggers small pill badge rendering in MarkdownView
                result += " [\(label)](\(url)#cite) "
            } else {
                result += content[fullRange]
            }
            searchStart = fullRange.upperBound
        }
        result += content[searchStart...]
        return result
    }

    static func resolveRelativeURLs(_ content: String, baseURL: String) -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return content }
        let pattern = #"((?:\]\(|src=["']|href=["']))(/api/[^\s\)"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return content }
        var result = ""
        var currentIndex = 0
        for match in matches {
            let fullRange = match.range
            if fullRange.location > currentIndex {
                result += nsContent.substring(with: NSRange(location: currentIndex, length: fullRange.location - currentIndex))
            }
            let prefixRange = match.range(at: 1)
            let prefix = nsContent.substring(with: prefixRange)
            let pathRange = match.range(at: 2)
            let relativePath = nsContent.substring(with: pathRange)
            result += "\(prefix)\(base)\(relativePath)"
            currentIndex = fullRange.location + fullRange.length
        }
        if currentIndex < nsContent.length {
            result += nsContent.substring(from: currentIndex)
        }
        return result
    }

}

private struct LocalAlpineResultCard: View {
    let content: String
    let metadata: [String: String]?
    let isStreaming: Bool
    let statusHistory: [ChatStatusUpdate]
    let liveToolCalls: [LocalAlpineToolCall]

    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    private let writtenFiles: [LocalAlpineWrittenFile]
    private let commandResults: [LocalAlpineAgentCommandResult]
    private let toolCalls: [LocalAlpineToolCall]

    init(
        content: String,
        metadata: [String: String]?,
        isStreaming: Bool,
        statusHistory: [ChatStatusUpdate],
        liveToolCalls: [LocalAlpineToolCall] = []
    ) {
        self.content = content
        self.metadata = metadata
        self.isStreaming = isStreaming
        self.statusHistory = statusHistory
        self.liveToolCalls = liveToolCalls
        self.writtenFiles = LocalAlpineWrittenFile.decodeMetadata(metadata?["iexa_local_alpine_written_files"])
        self.commandResults = LocalAlpineAgentCommandResult.decodeMetadata(metadata?["iexa_local_alpine_command_results"])
        let persistedToolCalls = LocalAlpineToolCall.decodeMetadata(metadata?["iexa_local_alpine_tool_calls"])
        self.toolCalls = liveToolCalls.isEmpty ? persistedToolCalls : liveToolCalls
    }

    private var parsed: ParsedLocalAlpineResult {
        ParsedLocalAlpineResult(content: content, metadata: metadata)
    }

    private var statusText: String {
        if isStreaming {
            if let running = toolCalls.last(where: { $0.isRunning }) {
                return running.statusDescription
            }
            return parsed.streamingSummary(statusDetail: statusDetail)
        }
        if !toolCalls.isEmpty {
            var parts: [String] = []
            let completedToolCount = toolCalls.filter { !$0.isRunning }.count
            if completedToolCount > 0 {
                parts.append("已执行 \(completedToolCount) 个工具步骤")
            }
            if effectiveCommandCount > 0 {
                parts.append("已运行 \(effectiveCommandCount) 条命令")
            }
            if parts.isEmpty {
                parts.append("本地任务已完成")
            }
            if parsed.hasNonZeroExit || commandResults.contains(where: { $0.failed }) || toolCalls.contains(where: { $0.failed }) {
                parts.append("有错误")
            }
            return parts.joined(separator: "  ")
        }
        return parsed.activitySummary(
            editedFileCount: writtenFiles.isEmpty ? nil : writtenFiles.count,
            commandCount: effectiveCommandCount == 0 ? nil : effectiveCommandCount,
            hasError: parsed.hasNonZeroExit || commandResults.contains { $0.failed } || toolCalls.contains { $0.failed }
        )
    }

    private var statusColor: Color {
        if isStreaming { return theme.brandPrimary }
        if parsed.hasNonZeroExit { return .orange }
        return theme.textTertiary
    }

    private var statusDetail: String {
        statusHistory.last?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var executableCommandResults: [LocalAlpineAgentCommandResult] {
        commandResults.filter { result in
            result.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "write_files"
        }
    }

    private var hiddenActivityCount: Int {
        if !toolCalls.isEmpty {
            return 0
        }
        return max(0, writtenFiles.count - 4) + max(0, executableCommandResults.count - 5)
    }

    private var effectiveCommandCount: Int {
        guard !toolCalls.isEmpty else { return executableCommandResults.count }
        return toolCalls.filter {
            ["command", "diagnostic", "compile", "test", "run_script", "install_dependency", "network_fetch", "verify"].contains($0.name)
                && !$0.isRunning
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(MicroAnimation.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(theme.isDark ? 0.18 : 0.12))
                            .frame(width: 26, height: 26)

                        Image(systemName: isStreaming ? "terminal" : (parsed.hasNonZeroExit ? "exclamationmark" : "checkmark"))
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(statusColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(statusText)
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(parsed.hasNonZeroExit ? .orange : theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if !statusDetail.isEmpty && isStreaming {
                            Text(statusDetail)
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.34 : 0.72))
            )

            if !toolCalls.isEmpty || !writtenFiles.isEmpty || !executableCommandResults.isEmpty {
                inlineStepPills
            }

            if isExpanded {
                if !parsed.commandText.isEmpty {
                    LocalAlpineCodeSection(title: "命令", text: parsed.commandText, maxHeight: 140)
                }
                LocalAlpineCodeSection(title: "输出", text: parsed.outputText, maxHeight: 240)
            }
        }
        .padding(.vertical, 3)
    }

    private var inlineStepPills: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !toolCalls.isEmpty {
                ForEach(Array(toolCalls.suffix(4)), id: \.id) { call in
                    AgentToolStepPill(call: call, detail: activityDetail(for: call))
                }
            } else {
                ForEach(Array(writtenFiles.prefix(4).enumerated()), id: \.offset) { _, file in
                    AgentFallbackStepPill(
                        icon: "square.and.pencil",
                        title: "已编辑文件",
                        value: file.path,
                        detail: "\(file.lineCount) 行 · \(file.byteCount) B",
                        tint: theme.brandPrimary
                    )
                }

                ForEach(Array(executableCommandResults.prefix(5).enumerated()), id: \.offset) { _, result in
                    AgentFallbackStepPill(
                        icon: result.failed ? "exclamationmark.circle.fill" : "terminal.fill",
                        title: result.failed ? "运行出错" : "运行完成",
                        value: oneLineCommand(result.command),
                        detail: "退出码 \(result.exitCode.map(String.init) ?? "unknown") · \(result.cwd)",
                        tint: result.failed ? .orange : theme.textTertiary
                    )
                }
            }

            if hiddenActivityCount > 0 {
                Text("还有 \(hiddenActivityCount) 项，展开可查看完整命令和输出")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 22)
            }
        }
    }

    private func activityDetail(for call: LocalAlpineToolCall) -> String {
        var parts: [String] = []
        if let exitCode = call.exitCode {
            parts.append("退出码 \(exitCode)")
        } else if call.isRunning {
            parts.append("执行中")
        }
        if !call.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(call.cwd)
        }
        if let output = call.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty,
           !call.isRunning {
            parts.append(oneLineCommand(output))
        }
        return parts.joined(separator: " · ")
    }

    private func oneLineCommand(_ command: String) -> String {
        command
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private struct AgentToolStepPill: View {
    let call: LocalAlpineToolCall
    var detail: String = ""

    @Environment(\.theme) private var theme

    private var display: LocalAlpineToolDisplay {
        LocalAlpineToolDisplayRegistry.display(for: call.name)
    }

    private var title: String {
        AgentActivityItem.displayTitle(for: call)
    }

    private var tint: Color {
        if call.failed { return .orange }
        return call.isRunning ? theme.brandPrimary : theme.success
    }

    private var iconName: String {
        if call.failed { return "exclamationmark.circle.fill" }
        if title.contains("搜索") || title.contains("网页") || title.contains("摘要") {
            return "globe"
        }
        if call.isRunning { return display.icon }
        return "checkmark.circle.fill"
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(tint.opacity(theme.isDark ? 0.20 : 0.13))
                    .frame(width: 25, height: 25)
                Image(systemName: iconName)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(tint)
            }

            Text(title)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if !call.displayLineDelta.isEmpty {
                Text(call.displayLineDelta)
                    .scaledFont(size: 11, weight: .bold, design: .monospaced)
                    .foregroundStyle(call.displayLineDelta.contains("-") ? .orange : .green)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 45)
        .background(
            Capsule(style: .continuous)
                .fill(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.42 : 0.78))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.24 : 0.42), lineWidth: 0.7)
        )
    }
}

private struct AgentFallbackStepPill: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let tint: Color

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(tint.opacity(theme.isDark ? 0.20 : 0.13))
                    .frame(width: 25, height: 25)
                Image(systemName: icon)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(tint)
            }

            Text(title)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 45)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            Capsule(style: .continuous)
                .fill(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.42 : 0.78))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.24 : 0.42), lineWidth: 0.7)
        )
    }
}

private struct AgentInlineStepsView: View {
    let item: AgentActivityItem
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    private var visibleSteps: [AgentActivityStep] {
        let limit = item.isActive ? 6 : 8
        return Array(item.steps.suffix(limit))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(visibleSteps, id: \.id) { step in
                    AgentActivityStepPill(step: step)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }

                if item.steps.count > visibleSteps.count {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis")
                            .scaledFont(size: 11, weight: .bold)
                        Text("还有 \(item.steps.count - visibleSteps.count) 个较早步骤")
                            .scaledFont(size: 11, weight: .semibold)
                    }
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityLabel("查看步骤")
    }
}

private struct AgentTaskPanelView: View {
    let items: [AgentActivityItem]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("暂无步骤", systemImage: "checklist")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            AgentTaskPanelSummary(items: items)
                            ForEach(items.reversed()) { item in
                                AgentTaskCard(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(theme.background)
                }
            }
            .navigationTitle("步骤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct AgentTaskPanelSummary: View {
    let items: [AgentActivityItem]

    @Environment(\.theme) private var theme

    private var commandCount: Int {
        items.reduce(0) { $0 + $1.commandCount }
    }

    private var fileCount: Int {
        items.reduce(0) { $0 + $1.fileCount }
    }

    private var failedCount: Int {
        items.filter { $0.hasFailure }.count
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                AgentTaskMetricPill(icon: "checklist", title: "任务", value: "\(items.count)", tint: theme.brandPrimary)
                AgentTaskMetricPill(icon: "terminal.fill", title: "命令", value: "\(commandCount)", tint: theme.textSecondary)
                AgentTaskMetricPill(icon: "square.and.pencil", title: "文件", value: "\(fileCount)", tint: theme.brandPrimary)
                if failedCount > 0 {
                    AgentTaskMetricPill(icon: "exclamationmark.circle.fill", title: "错误", value: "\(failedCount)", tint: .orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentTaskMetricPill: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .scaledFont(size: 11, weight: .semibold)
            Text(title)
                .scaledFont(size: 11, weight: .semibold)
            Text(value)
                .scaledFont(size: 11, weight: .bold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.34 : 0.70))
        .clipShape(Capsule(style: .continuous))
    }
}

private struct AgentTaskCard: View {
    let item: AgentActivityItem

    @Environment(\.theme) private var theme

    private var statusIcon: String {
        if item.isStreaming { return "progress.indicator" }
        return item.hasFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if item.isStreaming { return theme.brandPrimary }
        return item.hasFailure ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(theme.isDark ? 0.18 : 0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: statusIcon)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.currentStepTitle)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)

                    Text(item.currentStepDetail)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Text("\(item.completedStepCount)/\(item.totalStepCount)")
                    .scaledFont(size: 12, weight: .semibold, design: .rounded)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(statusColor.opacity(theme.isDark ? 0.14 : 0.10))
                    .clipShape(Capsule(style: .continuous))
            }

            HStack(spacing: 8) {
                Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                if item.commandCount > 0 {
                    Label("\(item.commandCount)", systemImage: "terminal.fill")
                }
                if item.fileCount > 0 {
                    Label("\(item.fileCount)", systemImage: "square.and.pencil")
                }
            }
            .scaledFont(size: 11, weight: .medium)
            .foregroundStyle(theme.textTertiary)

            if !item.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.steps.prefix(6)), id: \.id) { step in
                        AgentActivityStepPill(step: step)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.30 : 0.45), lineWidth: 0.7)
        )
    }
}

private struct AgentStepFloatingBar: View {
    let item: AgentActivityItem
    let taskCount: Int
    let onOpenAgentLog: () -> Void
    let onPreviewTap: (AgentActivityItem, Int) -> Void

    @Environment(\.theme) private var theme
    @State private var selectedIndex: Int = 0

    private var tint: Color {
        if selectedStep?.failed == true || item.hasFailure { return .orange }
        return item.isActive || selectedStep?.isRunning == true ? theme.brandPrimary : theme.success
    }

    private var icon: String {
        if selectedStep?.failed == true || item.hasFailure { return "exclamationmark.circle.fill" }
        return selectedStep?.isRunning == true ? "progress.indicator" : "checkmark.circle.fill"
    }

    private var clampedIndex: Int {
        guard !item.steps.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), item.steps.count - 1)
    }

    private var selectedStep: AgentActivityStep? {
        guard !item.steps.isEmpty else { return nil }
        return item.steps[clampedIndex]
    }

    private var pageText: String {
        "\(clampedIndex + 1)/\(max(item.steps.count, 1))"
    }

    private var previewTitle: String {
        return selectedStep?.title ?? item.currentStepTitle
    }

    private var previewSubtitle: String {
        if let file = selectedStep?.file {
            return file.path
        }
        if selectedStep?.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let cwd = selectedStep?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return cwd.isEmpty ? "终端输出" : cwd
        }
        return selectedStep?.detail ?? item.currentStepDetail
    }

    private var previewText: String {
        guard let selectedStep else { return item.currentPreviewText }
        if let file = selectedStep.file {
            let lines = file.previewLines(limit: 4)
            return lines.isEmpty ? file.path : lines.map { String($0.prefix(96)) }.joined(separator: "\n")
        }
        if !selectedStep.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AgentActivityItem.multilinePreview(selectedStep.outputPreview, maxLines: 4, maxLineLength: 88)
        }
        if let command = selectedStep.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return "$ \(AgentActivityItem.oneLinePreview(command, limit: 88))"
        }
        return AgentActivityItem.multilinePreview(selectedStep.detail, maxLines: 4, maxLineLength: 88)
    }

    private var selectedTitle: String {
        selectedStep?.title ?? item.currentStepTitle
    }

    private func movePage(_ delta: Int) {
        guard !item.steps.isEmpty else { return }
        let next = min(max(clampedIndex + delta, 0), item.steps.count - 1)
        guard next != selectedIndex else { return }
        Haptics.play(.light)
        withAnimation(MicroAnimation.snappy) {
            selectedIndex = next
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)

                Text(selectedTitle)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpenAgentLog)

                Spacer(minLength: 6)

                Button {
                    movePage(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(clampedIndex > 0 ? theme.textPrimary : theme.textTertiary.opacity(0.45))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(clampedIndex == 0)

                Text(pageText)
                    .scaledFont(size: 10.5, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 36, alignment: .center)

                Button {
                    movePage(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(clampedIndex < item.steps.count - 1 ? theme.textPrimary : theme.textTertiary.opacity(0.45))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(clampedIndex >= item.steps.count - 1)
            }
            .padding(.leading, 104)
            .padding(.trailing, 8)
            .frame(height: 36)
            .frame(maxWidth: 560)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.28 : 0.42), lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(theme.isDark ? 0.18 : 0.08), radius: 8, x: 0, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxHeight: .infinity, alignment: .bottom)

            Button {
                onPreviewTap(item, clampedIndex)
            } label: {
                AgentToolPreviewPop(
                    previewTitle: previewTitle,
                    previewSubtitle: previewSubtitle,
                    previewText: previewText
                )
                .frame(width: 96, height: 54)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.bottom, 0)
        }
        .frame(height: 58, alignment: .bottom)
        .frame(maxWidth: 560)
        .onAppear {
            selectedIndex = max(0, item.currentStepIndex - 1)
        }
        .onChange(of: item.id) { _, _ in
            selectedIndex = max(0, item.currentStepIndex - 1)
        }
        .onChange(of: item.steps.count) { _, count in
            selectedIndex = min(max(0, item.currentStepIndex - 1), max(0, count - 1))
        }
        .accessibilityLabel("步骤 \(taskCount)")
    }
}

private struct AgentToolPreviewPop: View {
    let previewTitle: String
    let previewSubtitle: String
    let previewText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(previewTitle)
                .font(.system(size: 8.2, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Text(previewSubtitle)
                .font(.system(size: 6.8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)

            Text(previewText)
                .font(.system(size: 7.0, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.30, green: 0.63, blue: 1.0))
                .lineLimit(3)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .shadow(color: .black.opacity(0.20), radius: 6, x: 0, y: 3)
    }
}

private struct AgentActivityStepPill: View {
    let step: AgentActivityStep

    @Environment(\.theme) private var theme

    private var tint: Color {
        if step.failed { return .orange }
        return step.isRunning ? theme.brandPrimary : theme.success
    }

    private var iconName: String {
        if step.failed { return "exclamationmark.circle.fill" }
        if step.isRunning { return "progress.indicator" }
        switch step.kind {
        case .file:
            return "doc.text"
        case .command:
            return "terminal.fill"
        case .status:
            return step.title.contains("搜索") || step.title.contains("网页") ? "globe" : "checkmark.circle.fill"
        case .tool:
            return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(tint.opacity(theme.isDark ? 0.20 : 0.13))
                    .frame(width: 25, height: 25)
                Image(systemName: iconName)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if step.isRunning {
                        AgentStepWaitingDots(tint: tint)
                            .frame(width: 22, height: 10)
                    }
                }
                if !step.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(step.detail)
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 45)
        .background(
            Capsule(style: .continuous)
                .fill(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.42 : 0.78))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.24 : 0.42), lineWidth: 0.7)
        )
    }
}

private struct AgentStepWaitingDots: View {
    let tint: Color
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || scenePhase != .active {
                dots(progress: 0.2)
            } else {
                TimelineView(.animation) { timeline in
                    dots(progress: progress(for: timeline.date))
                }
            }
        }
    }

    private func dots(progress: Double) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(opacity(index: index, progress: progress)))
                    .frame(width: 4, height: 4)
                    .offset(y: yOffset(index: index, progress: progress))
            }
        }
    }

    private func progress(for date: Date) -> Double {
        let period = 1.15
        let value = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }

    private func opacity(index: Int, progress: Double) -> Double {
        let phase = progress * .pi * 2 - Double(index) * 0.72
        return 0.35 + 0.65 * (0.5 + 0.5 * sin(phase))
    }

    private func yOffset(index: Int, progress: Double) -> CGFloat {
        let phase = progress * .pi * 2 - Double(index) * 0.72
        return CGFloat(-sin(phase) * 2.2)
    }
}

private struct LocalAlpineWrittenFilesCard: View {
    let files: [LocalAlpineWrittenFile]

    @Environment(\.theme) private var theme
    @State private var codeCache: [String: String] = [:]
    @State private var loadingPaths: Set<String> = []
    @State private var previewItem: LocalAlpineWrittenFilePreviewItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files, id: \.path) { file in
                fileCard(for: file)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $previewItem) { item in
            LocalAlpineWrittenFilePreviewSheet(item: item)
        }
    }

    private func fileCard(for file: LocalAlpineWrittenFile) -> some View {
        Button {
            openPreview(for: file)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .frame(width: 26, height: 26)
                    .background(theme.brandPrimary.opacity(theme.isDark ? 0.18 : 0.10))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.fileName)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(contentType(for: file))
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 170, alignment: .leading)

                if loadingPaths.contains(file.path) {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.74 : 0.86))
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.46 : 0.42), lineWidth: 0.5)
            )
            .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(loadingPaths.contains(file.path))
    }

    @MainActor
    private func openPreview(for file: LocalAlpineWrittenFile) {
        Haptics.play(.light)
        if let cached = codeCache[file.path] {
            previewItem = LocalAlpineWrittenFilePreviewItem(file: file, code: cached)
            return
        }
        if loadingPaths.contains(file.path) {
            return
        }
        loadingPaths.insert(file.path)
        Task {
            let code = await loadFullCode(for: file)
            await MainActor.run {
                codeCache[file.path] = code
                loadingPaths.remove(file.path)
                previewItem = LocalAlpineWrittenFilePreviewItem(file: file, code: code)
            }
        }
    }

    private func loadFullCode(for file: LocalAlpineWrittenFile) async -> String {
        do {
            let data = try await LocalAlpineTerminalService.shared.readFile(path: file.path)
            return String(data: data, encoding: .utf8) ?? file.previewTailLines.joined(separator: "\n")
        } catch {
            return file.previewTailLines.joined(separator: "\n")
        }
    }

    private func contentType(for file: LocalAlpineWrittenFile) -> String {
        switch (file.fileName as NSString).pathExtension.lowercased() {
        case "py":
            return "text/x-python"
        case "swift":
            return "text/x-swift"
        case "js":
            return "text/javascript"
        case "ts":
            return "text/typescript"
        case "json":
            return "application/json"
        case "yaml", "yml":
            return "application/yaml"
        case "xml":
            return "application/xml"
        case "html", "htm":
            return "text/html"
        case "css", "scss", "sh", "md", "txt", "toml", "ini", "cfg", "conf":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }
}

private struct LocalAlpineWrittenFilePreviewItem: Identifiable {
    let file: LocalAlpineWrittenFile
    let code: String

    var id: String { file.path }
}

private struct LocalAlpineWrittenFilePreviewSheet: View {
    let item: LocalAlpineWrittenFilePreviewItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewHeader
                Divider()
                GeometryReader { proxy in
                    SourceCodeTextView(
                        code: item.code,
                        language: item.file.language,
                        maxHeight: max(240, proxy.size.height),
                        wrapLines: true
                    )
                }
            }
            .background(theme.background)
            .navigationTitle(item.file.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = item.code
                        Haptics.notify(.success)
                        withAnimation(MicroAnimation.snappy) { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run {
                                withAnimation(MicroAnimation.snappy) { copied = false }
                            }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .scaledFont(size: 14, weight: .medium)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var previewHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 32, height: 32)
                .background(theme.brandPrimary.opacity(theme.isDark ? 0.16 : 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.file.path)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.file.lineCount) 行 · \(item.file.byteCount) B")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct AgentFloatingStepPreviewItem: Identifiable, Hashable {
    let id = UUID()
    let activity: AgentActivityItem
    let initialIndex: Int
}

private struct AgentFloatingStepPreviewSheet: View {
    let item: AgentFloatingStepPreviewItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var selectedIndex: Int
    @State private var copied = false

    init(item: AgentFloatingStepPreviewItem) {
        self.item = item
        let maxIndex = max(0, item.activity.steps.count - 1)
        _selectedIndex = State(initialValue: min(max(item.initialIndex, 0), maxIndex))
    }

    private var steps: [AgentActivityStep] {
        item.activity.steps
    }

    private var clampedIndex: Int {
        guard !steps.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), steps.count - 1)
    }

    private var selectedStep: AgentActivityStep? {
        guard !steps.isEmpty else { return nil }
        return steps[clampedIndex]
    }

    private var pageText: String {
        "\(clampedIndex + 1) / \(max(steps.count, 1))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewArea
                Divider()
                controlPanel
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 16, weight: .bold)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let step = selectedStep,
                       let command = step.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !command.isEmpty {
                        Button {
                            NotificationCenter.default.post(
                                name: .openIexaTerminalBrowser,
                                object: nil,
                                userInfo: [
                                    "command": command,
                                    "cwd": step.cwd ?? ""
                                ]
                            )
                            dismiss()
                        } label: {
                            Image(systemName: "terminal.fill")
                                .scaledFont(size: 14, weight: .medium)
                        }
                    }
                    Button {
                        UIPasteboard.general.string = copyText(for: selectedStep)
                        Haptics.notify(.success)
                        withAnimation(MicroAnimation.snappy) { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run {
                                withAnimation(MicroAnimation.snappy) { copied = false }
                            }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .scaledFont(size: 14, weight: .medium)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private var title: String {
        "Iexa 电脑"
    }

    private var previewArea: some View {
        Group {
            if let step = selectedStep {
                ScrollView {
                    stepPreview(step)
                        .padding(16)
                }
            } else {
                ContentUnavailableView("暂无步骤", systemImage: "checklist")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    @ViewBuilder
    private func stepPreview(_ step: AgentActivityStep) -> some View {
        if let file = step.file {
            filePreview(file)
        } else if step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            terminalPreview(step)
        } else {
            textPreview(step)
        }
    }

    private func filePreview(_ file: LocalAlpineWrittenFile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(theme.textSecondary)
                Text(file.fileName)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("(\(file.byteCount) B)")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.42 : 0.72))

            Divider()

            Text(file.previewLines(limit: 120).joined(separator: "\n").isEmpty ? file.path : file.previewLines(limit: 120).joined(separator: "\n"))
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(theme.textTertiary)
                Text(file.path)
                    .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(file.byteCount) B")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(12)
        }
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.34 : 0.55), lineWidth: 0.7)
        )
    }

    private func terminalPreview(_ step: AgentActivityStep) -> some View {
        Text(terminalText(for: step))
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(red: 0.32, green: 0.86, blue: 0.45))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func textPreview(_ step: AgentActivityStep) -> some View {
        Text(copyText(for: step).isEmpty ? "（无内容）" : copyText(for: step))
            .font(.system(size: 14, weight: .regular, design: .monospaced))
            .foregroundStyle(theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.98))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controlPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: selectedStep?.failed == true ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .scaledFont(size: 27, weight: .semibold)
                    .foregroundStyle(selectedStep?.failed == true ? .orange : theme.success)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Iexa is using \(toolCategory(for: selectedStep))")
                        .scaledFont(size: 17, weight: .bold)
                        .foregroundStyle(theme.textPrimary)
                    Text(selectedStep?.title ?? item.activity.summary)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }

            HStack {
                Button {
                    movePage(-1)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .scaledFont(size: 24, weight: .bold)
                        .foregroundStyle(clampedIndex > 0 ? theme.textPrimary : theme.textTertiary.opacity(0.35))
                        .frame(width: 60, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(clampedIndex == 0)

                Spacer(minLength: 0)

                Text(pageText)
                    .scaledFont(size: 17, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()

                Spacer(minLength: 0)

                Button {
                    movePage(1)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .scaledFont(size: 24, weight: .bold)
                        .foregroundStyle(clampedIndex < steps.count - 1 ? theme.textPrimary : theme.textTertiary.opacity(0.35))
                        .frame(width: 60, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(clampedIndex >= steps.count - 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.92 : 0.98))
    }

    private func movePage(_ delta: Int) {
        guard !steps.isEmpty else { return }
        let next = min(max(clampedIndex + delta, 0), steps.count - 1)
        guard next != selectedIndex else { return }
        Haptics.play(.light)
        withAnimation(MicroAnimation.snappy) {
            selectedIndex = next
        }
    }

    private func toolCategory(for step: AgentActivityStep?) -> String {
        guard let step else { return "Agent" }
        if step.file != nil { return "Editor" }
        if step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return "Shell" }
        return "Tool"
    }

    private func terminalText(for step: AgentActivityStep) -> String {
        var lines: [String] = []
        if let command = step.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            lines.append("$ \(command)")
        }
        let output = step.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            lines.append(output)
        }
        return lines.joined(separator: "\n")
    }

    private func copyText(for step: AgentActivityStep?) -> String {
        guard let step else { return "" }
        if let file = step.file {
            return file.previewLines(limit: 120).joined(separator: "\n")
        }
        if step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return terminalText(for: step)
        }
        return step.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? step.detail
            : step.outputPreview
    }
}

private struct LocalAlpineCodeSection: View {
    let title: String
    let text: String
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.vertical) {
                Text(text.isEmpty ? "（无输出）" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: maxHeight)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct ParsedLocalAlpineResult {
    let commandCount: Int
    let editedFileCount: Int
    let commandText: String
    let outputText: String
    let hasNonZeroExit: Bool

    init(content: String, metadata: [String: String]?) {
        let boundaryTrimmed = content.trimmingCharacters(in: .newlines)
        let searchable = boundaryTrimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandFromMetadata = metadata?["iexa_local_alpine_display_command"]
            ?? ""
        let commandBlocks = Self.codeBlocks(in: boundaryTrimmed, preferredLanguage: "bash").joined(separator: "\n\n---\n\n")
        let textBlocks = Self.codeBlocks(in: boundaryTrimmed, preferredLanguage: "text").joined(separator: "\n\n---\n\n")

        commandText = Self.clip(
            commandFromMetadata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? commandBlocks
                : commandFromMetadata,
            limit: 8_000
        )
        outputText = Self.clip(textBlocks.isEmpty ? boundaryTrimmed : textBlocks, limit: 20_000)
        let metadataHasCommand = !commandFromMetadata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commandCount = max(Self.headingCount(in: searchable, heading: "命令"), metadataHasCommand ? 1 : 0)
        editedFileCount = Self.editedFileCount(in: searchable)
        hasNonZeroExit = Self.containsNonZeroExit(in: searchable)
    }

    func streamingSummary(statusDetail: String) -> String {
        statusDetail.isEmpty ? "正在处理本地任务" : statusDetail
    }

    func activitySummary(editedFileCount overrideEditedFileCount: Int? = nil, commandCount overrideCommandCount: Int? = nil, hasError: Bool) -> String {
        var parts: [String] = []
        let effectiveEditedFileCount = overrideEditedFileCount ?? editedFileCount
        let effectiveCommandCount = overrideCommandCount ?? commandCount
        if effectiveEditedFileCount > 0 {
            parts.append("已编辑 \(effectiveEditedFileCount) 个文件")
        }
        if effectiveCommandCount > 0 {
            parts.append("已运行 \(effectiveCommandCount) 条命令")
        }
        if parts.isEmpty {
            parts.append("本地任务已完成")
        }
        if hasError {
            parts.append("有错误")
        }
        return parts.joined(separator: "  ")
    }

    private static func codeBlocks(in content: String, preferredLanguage: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#) else {
            return []
        }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        var blocks: [String] = []
        for match in matches where match.numberOfRanges >= 3 {
            let language = nsContent.substring(with: match.range(at: 1)).lowercased()
            let body = nsContent.substring(with: match.range(at: 2)).trimmingCharacters(in: .newlines)
            if language.contains(preferredLanguage) {
                blocks.append(body)
            }
        }
        return blocks
    }

    private static func headingCount(in content: String, heading: String) -> Int {
        let escapedHeading = NSRegularExpression.escapedPattern(for: heading)
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*"# + escapedHeading + #"\s*$"#) else {
            return 0
        }
        return regex.numberOfMatches(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content))
    }

    private static func containsNonZeroExit(in content: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"退出码：`?([A-Za-z0-9_-]+)`?"#) else {
            return false
        }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content))
        for match in matches where match.numberOfRanges >= 2 {
            guard let range = Range(match.range(at: 1), in: content) else { continue }
            let value = String(content[range]).lowercased()
            if value != "0" { return true }
        }
        return false
    }

    private static func editedFileCount(in content: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*-\s+`[^`]+`"#) else {
            return 0
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.numberOfMatches(in: content, range: range)
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n...（内容过长，已折叠）"
    }
}

// MARK: - Superscript Number Helper

/// Converts an integer to its Unicode superscript representation.
/// e.g., 1 → "¹", 12 → "¹²", 9 → "⁹"
private func superscriptNumber(_ n: Int) -> String {
    let superDigits: [Character] = ["\u{2070}", "\u{00B9}", "\u{00B2}", "\u{00B3}", "\u{2074}", "\u{2075}", "\u{2076}", "\u{2077}", "\u{2078}", "\u{2079}"]
    return String(String(n).compactMap { c in
        guard let digit = c.wholeNumberValue, digit < superDigits.count else { return nil }
        return superDigits[digit]
    })
}

// MARK: - User Message Content View

/// Renders a user message, parsing `<$slug|slug>` skill tags as inline
/// styled chips and displaying the surrounding plain text normally.
///
/// The web UI stores skill references in message content as `<$slug|slug>`
/// (e.g. `<$sde|sde>`). This view splits the content into alternating
/// plain-text and skill-tag segments, then renders each chip with the
/// same accent styling used in the input field's skill chips.
struct UserMessageContentView: View {
    let content: String
    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    private static let collapseCharacterThreshold = 700
    private static let collapseLineThreshold = 12
    private static let collapsedLineLimit = 10

    private var shouldCollapse: Bool {
        content.count > Self.collapseCharacterThreshold
            || content.components(separatedBy: .newlines).count > Self.collapseLineThreshold
    }

    /// Parses `content` into alternating text / skill segments.
    /// Pattern: `<$slug|slug>` — captures the slug before `|`.
    private var segments: [UserMessageContentView_SegmentType] {
        let pattern = #"<\$([^|>]+)\|[^>]+>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(content)]
        }
        var result: [UserMessageContentView_SegmentType] = []
        var searchStart = content.startIndex
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        for match in matches {
            guard let fullRange = Range(match.range, in: content),
                  let slugRange = Range(match.range(at: 1), in: content) else { continue }
            let prefix = String(content[searchStart..<fullRange.lowerBound])
            if !prefix.isEmpty { result.append(.text(prefix)) }
            result.append(.skill(slug: String(content[slugRange])))
            searchStart = fullRange.upperBound
        }
        let suffix = String(content[searchStart...])
        if !suffix.isEmpty { result.append(.text(suffix)) }
        return result.isEmpty ? [.text(content)] : result
    }

    var body: some View {
        let segs = segments
        let hasChips = segs.contains { if case .skill = $0 { return true }; return false }

        VStack(alignment: .trailing, spacing: 8) {
            Group {
                if !hasChips {
                    Text(content)
                        .scaledFont(size: 15, context: .content)
                        .lineLimit(shouldCollapse && !isExpanded ? Self.collapsedLineLimit : nil)
                } else {
                    SkillTaggedTextView(
                        segments: segs,
                        lineLimit: shouldCollapse && !isExpanded ? Self.collapsedLineLimit : nil
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if shouldCollapse && !isExpanded {
                    collapsedTextFade
                        .frame(height: 46)
                        .allowsHitTesting(false)
                }
            }

            if shouldCollapse {
                Button {
                    withAnimation(MicroAnimation.snappy) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(isExpanded ? "收起" : "展开全文")
                            .scaledFont(size: 12, weight: .semibold)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .scaledFont(size: 11, weight: .bold)
                        Text("\(content.count) 字")
                            .scaledFont(size: 11, weight: .medium)
                            .opacity(0.76)
                    }
                    .foregroundStyle(theme.chatBubbleUserText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.chatBubbleUserText.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起长文本" : "展开长文本")
            }
        }
    }

    private var collapsedTextFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: theme.chatBubbleUser.opacity(theme.isDark ? 0.14 : 0.20), location: 0.34),
                .init(color: theme.chatBubbleUser.opacity(theme.isDark ? 0.46 : 0.68), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct MessageFilePreviewItem: Identifiable {
    let id = UUID()
    let file: ChatMessageFile
}

private struct MessageFilePreviewSheet: View {
    let file: ChatMessageFile
    let apiClient: APIClient?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var selectedTab: PreviewTab = .content
    @State private var data: Data?
    @State private var contentType: String?
    @State private var textContent: String?
    @State private var previewImage: UIImage?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private enum PreviewTab: CaseIterable, Hashable {
        case content
        case preview

        var title: String {
            switch self {
            case .content: return "内容"
            case .preview: return "预览"
            }
        }
    }

    private var fileName: String {
        file.name ?? file.url ?? "File"
    }

    private var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    private var copyableText: String? {
        guard let textContent,
              !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return textContent
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                Picker("标签页", selection: $selectedTab) {
                    ForEach(PreviewTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                Group {
                    if selectedTab == .content {
                        contentTab
                    } else {
                        previewTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background)
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(theme.brandPrimary)
                }
                if let copyableText {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            UIPasteboard.general.string = copyableText
                            Haptics.play(.light)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadFileIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .scaledFont(size: 26, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 42, height: 42)
                .background(theme.brandPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(fileName)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(contentType ?? file.contentType ?? (fileExtension.isEmpty ? "文件" : fileExtension.uppercased()))
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                    if let data {
                        Text("·")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var contentTab: some View {
        if isLoading {
            ProgressView("正在加载内容…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(theme.textSecondary)
        } else if let text = copyableText {
            ScrollView {
                Text(text)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
        } else if let errorMessage {
            ContentUnavailableView(
                "无法加载内容",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .padding(.top, 40)
        } else {
            ContentUnavailableView(
                "暂无文本内容",
                systemImage: "doc.text",
                description: Text("这个文件没有可复制的文本内容。")
            )
            .padding(.top, 40)
        }
    }

    @ViewBuilder
    private var previewTab: some View {
        if isLoading {
            ProgressView("正在加载预览…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(theme.textSecondary)
        } else if let image = previewImage, isImageLike {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
        } else if let data, let pdf = PDFDocument(data: data), fileExtension == "pdf" || contentType?.contains("pdf") == true {
            MessagePDFKitView(document: pdf)
        } else if let text = textContent, !text.isEmpty {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
        } else {
            ContentUnavailableView(
                "无法预览",
                systemImage: "eye.slash",
                description: Text("这种文件类型暂不支持预览。")
            )
            .padding(.top, 40)
        }
    }

    private var isImageLike: Bool {
        isImageType(contentType)
    }

    private func isImageType(_ loadedContentType: String?) -> Bool {
        file.type == "image"
            || file.contentType?.hasPrefix("image/") == true
            || loadedContentType?.hasPrefix("image/") == true
            || ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"].contains(fileExtension)
    }

    private var iconName: String {
        switch fileExtension {
        case "pdf": return "doc.richtext"
        case "doc", "docx", "txt", "md", "rtf": return "doc.text"
        case "json", "yaml", "yml", "xml", "toml", "ini", "cfg": return "curlybraces"
        case "csv", "xls", "xlsx": return "tablecells"
        case "html", "htm", "css", "scss": return "globe"
        case "zip", "tar", "gz", "rar", "7z": return "archivebox"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        case "mp4", "mov", "avi", "mkv", "webm": return "film"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif": return "photo"
        case "js", "ts", "py", "swift", "dart", "java", "cpp", "c", "h", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    @MainActor
    private func loadFileIfNeeded() async {
        guard data == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let extractedText = try await loadExtractedTextIfAvailable()
            if let loaded = try await loadData() {
                data = loaded.data
                contentType = loaded.contentType
                if isImageType(loaded.contentType) {
                    previewImage = await Self.decodePreviewImage(from: loaded.data)
                } else {
                    previewImage = nil
                }
                textContent = extractedText ?? decodedText(from: loaded.data, contentType: loaded.contentType)
            } else {
                textContent = extractedText
                previewImage = nil
                errorMessage = "缺少可读取的文件地址。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadExtractedTextIfAvailable() async throws -> String? {
        guard let apiClient,
              let fileId = fileReferenceCandidates.compactMap(serverFileId(from:)).first else {
            return nil
        }
        let info = try await apiClient.getFileInfo(id: fileId)
        if let data = info["data"] as? [String: Any],
           let content = data["content"] as? String,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        return nil
    }

    private struct DecodedPreviewImage: @unchecked Sendable {
        let image: UIImage
    }

    private static func decodePreviewImage(from data: Data) async -> UIImage? {
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(data: data).map { DecodedPreviewImage(image: $0) }
        }.value
        return decoded?.image
    }

    private func loadData() async throws -> (data: Data, contentType: String?)? {
        guard let ref = fileReferenceCandidates.first else {
            return nil
        }

        if ref.hasPrefix("data:") {
            return try await dataURLPayload(ref)
        }

        if let url = URL(string: ref), url.isFileURL {
            let data = try await Task.detached(priority: .userInitiated, operation: {
                try Data(contentsOf: url)
            }).value
            return (data, file.contentType)
        }

        if let apiClient, let fileId = serverFileId(from: ref) {
            let (data, responseType) = try await apiClient.getFileContent(id: fileId)
            return (data, responseType)
        }

        if let url = URL(string: ref),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            let (data, response) = try await URLSession.shared.data(from: url)
            let responseType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            return (data, responseType ?? file.contentType)
        }

        guard let apiClient else {
            throw NSError(domain: "MessageFilePreview", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "尚未连接站点，无法加载文件。"
            ])
        }
        let (data, responseType) = try await apiClient.getFileContent(id: ref)
        return (data, responseType)
    }

    private var fileReferenceCandidates: [String] {
        [file.displayURL, file.url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func serverFileId(from ref: String) -> String? {
        if ref.hasPrefix("data:") || ref.hasPrefix("file://") {
            return nil
        }
        let parts = ref.split(separator: "/", omittingEmptySubsequences: true)
        if let filesIndex = parts.firstIndex(of: "files"),
           filesIndex + 1 < parts.endIndex {
            return String(parts[filesIndex + 1])
        }
        if ref.contains("/") || ref.contains(":") {
            return nil
        }
        return ref
    }

    private func dataURLPayload(_ value: String) async throws -> (data: Data, contentType: String?) {
        try await Task.detached(priority: .userInitiated) {
            guard let comma = value.firstIndex(of: ",") else {
                throw NSError(domain: "MessageFilePreview", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "文件 data URL 格式无效。"
                ])
            }
            let header = String(value[..<comma])
            let body = String(value[value.index(after: comma)...])
            let mime = header
                .replacingOccurrences(of: "data:", with: "")
                .components(separatedBy: ";")
                .first
            if header.lowercased().contains(";base64") {
                guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
                    throw NSError(domain: "MessageFilePreview", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "文件 base64 内容无法解码。"
                    ])
                }
                return (data, mime)
            }
            let decoded = body.removingPercentEncoding ?? body
            return (Data(decoded.utf8), mime)
        }.value
    }

    private func decodedText(from data: Data, contentType: String?) -> String? {
        let lowerType = (contentType ?? file.contentType ?? "").lowercased()
        let textExtensions = [
            "txt", "md", "csv", "json", "yaml", "yml", "xml", "html", "htm",
            "css", "scss", "js", "ts", "py", "swift", "java", "c", "h", "cpp",
            "go", "rs", "rb", "php", "sh", "ps1", "toml", "ini", "cfg", "log"
        ]
        guard lowerType.hasPrefix("text/")
            || lowerType.contains("json")
            || lowerType.contains("xml")
            || textExtensions.contains(fileExtension) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }
}

private struct MessagePDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemBackground
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = document
    }
}

/// Renders a mix of text and skill chips in a flowing layout.
/// Uses `Layout` to flow content left-to-right, wrapping as needed.
private struct SkillTaggedTextView: View {
    let segments: [UserMessageContentView_Segment]
    var lineLimit: Int? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        // Build one or more lines. We use a simple VStack + HStack wrap
        // by splitting on newlines first, then rendering each line's chips inline.
        let allLines = buildLines()
        let lines = lineLimit.map { Array(allLines.prefix($0)) } ?? allLines
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                FlowRow(segments: line, theme: theme)
            }
        }
    }

    /// Splits segments into lines (splitting on newlines in text segments).
    private func buildLines() -> [[UserMessageContentView_Segment]] {
        var lines: [[UserMessageContentView_Segment]] = [[]]
        for seg in segments {
            switch seg {
            case .skill:
                lines[lines.count - 1].append(seg)
            case .text(let str):
                let parts = str.components(separatedBy: "\n")
                for (i, part) in parts.enumerated() {
                    if i > 0 { lines.append([]) }
                    if !part.isEmpty {
                        lines[lines.count - 1].append(.text(part))
                    }
                }
            }
        }
        return lines.filter { !$0.isEmpty }
    }
}

// Type alias to share the enum with SkillTaggedTextView
private typealias UserMessageContentView_Segment = UserMessageContentView_SegmentType

enum UserMessageContentView_SegmentType {
    case text(String)
    case skill(slug: String)
}

/// A single row of mixed text + skill chips, wrapping as needed.
private struct FlowRow: View {
    let segments: [UserMessageContentView_Segment]
    let theme: AppTheme

    var body: some View {
        // Concatenate text and chip views in an HStack that wraps.
        // We use ViewThatFits + LazyHStack fallback for wrapping behavior.
        // For simplicity, render as a single HStack (most messages are short).
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let str):
                    Text(str)
                        .scaledFont(size: 15, context: .content)
                        .fixedSize(horizontal: false, vertical: true)
                case .skill(let slug):
                    SkillChipView(slug: slug, theme: theme)
                }
            }
        }
    }
}

/// A single skill chip rendered in the user bubble.
/// Styled as a small rounded badge matching the web UI's `$slug` pill.
private struct SkillChipView: View {
    let slug: String
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 3) {
            Text("$")
                .scaledFont(size: 12, weight: .bold)
            Text(slug)
                .scaledFont(size: 12, weight: .semibold)
        }
        .foregroundStyle(theme.chatBubbleUserText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(theme.chatBubbleUserText.opacity(0.18))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(theme.chatBubbleUserText.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Prompt Card Button Style

struct PromptCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Document Picker (UIKit Wrapper)

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .pdf, .plainText, .text, .json, .image, .png, .jpeg,
            .spreadsheet, .presentation, .audio, .mp3, .wav, .aiff, .data
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - Camera Picker (UIKit Wrapper)

struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, dismiss: dismiss) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}

// MARK: - Share Sheet (UIKit Wrapper)

/// Wraps UIActivityViewController for presenting the iOS share sheet.
struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ScrollView Horizontal Lock

/// A zero-size `UIViewRepresentable` that finds the enclosing `UIScrollView`
/// and installs a KVO observer on `contentOffset` to continuously snap
/// `contentOffset.x` back to 0. This is the nuclear option for preventing
/// horizontal panning — no matter what triggers it (animated insertions,
/// transient layout overflow, MarkdownView intrinsic size, etc.), the
/// horizontal offset is immediately corrected on the very next frame.
///
/// Also sets `alwaysBounceHorizontal = false` and `isDirectionalLockEnabled = true`
/// as static configuration, and uses a pan gesture recognizer delegate to
/// prevent horizontal pan recognition entirely.
private struct ScrollViewHorizontalLock: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-attach if the scroll view was recreated
        if context.coordinator.observedScrollView == nil {
            DispatchQueue.main.async {
                context.coordinator.attach(to: uiView)
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var observation: NSKeyValueObservation?
        weak var observedScrollView: UIScrollView?
        private var panBlocker: UIPanGestureRecognizer?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var preservedOffsetY: CGFloat?
        private var preserveOffsetUntil: Date?
        private var previousInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior?
        private var previousAutomaticallyAdjustsScrollIndicatorInsets: Bool?

        func attach(to view: UIView) {
            guard observedScrollView == nil else { return }
            var current: UIView? = view.superview
            while let sv = current {
                if let scrollView = sv as? UIScrollView {
                    observedScrollView = scrollView

                    // Static configuration
                    scrollView.alwaysBounceHorizontal = false
                    scrollView.showsHorizontalScrollIndicator = false
                    scrollView.isDirectionalLockEnabled = true
                    previousInsetAdjustmentBehavior = scrollView.contentInsetAdjustmentBehavior
                    previousAutomaticallyAdjustsScrollIndicatorInsets = scrollView.automaticallyAdjustsScrollIndicatorInsets
                    scrollView.contentInsetAdjustmentBehavior = .never
                    scrollView.automaticallyAdjustsScrollIndicatorInsets = false

                    installKeyboardOffsetPreservation(for: scrollView)

                    // KVO: snap contentOffset.x to 0 on every change and keep
                    // the vertical offset stable during keyboard frame changes.
                    observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, change in
                        guard let self, let offset = change.newValue else { return }
                        if abs(offset.x) > 0.5 {
                            // Use setContentOffset to avoid triggering another KVO notification loop
                            sv.contentOffset = CGPoint(x: 0, y: offset.y)
                        } else if self.shouldPreserveVerticalOffset(in: sv),
                                  let preservedY = self.preservedOffsetY,
                                  abs(offset.y - preservedY) > 0.5 {
                            sv.setContentOffset(
                                CGPoint(x: 0, y: self.clampedOffsetY(preservedY, in: sv)),
                                animated: false
                            )
                        }
                    }

                    // Add a pan gesture recognizer that blocks horizontal panning
                    let blocker = UIPanGestureRecognizer(target: nil, action: nil)
                    blocker.delegate = self
                    blocker.cancelsTouchesInView = false
                    scrollView.addGestureRecognizer(blocker)
                    panBlocker = blocker

                    break
                }
                current = sv.superview
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
            keyboardObservers.removeAll()
            preservedOffsetY = nil
            preserveOffsetUntil = nil
            if let blocker = panBlocker, let sv = observedScrollView {
                sv.removeGestureRecognizer(blocker)
                if let previousInsetAdjustmentBehavior {
                    sv.contentInsetAdjustmentBehavior = previousInsetAdjustmentBehavior
                }
                if let previousAutomaticallyAdjustsScrollIndicatorInsets {
                    sv.automaticallyAdjustsScrollIndicatorInsets = previousAutomaticallyAdjustsScrollIndicatorInsets
                }
            }
            previousInsetAdjustmentBehavior = nil
            previousAutomaticallyAdjustsScrollIndicatorInsets = nil
            panBlocker = nil
            observedScrollView = nil
        }

        // MARK: UIGestureRecognizerDelegate

        /// Allow our blocker to recognize simultaneously with all other gestures
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// Block any pan gesture that is primarily horizontal
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            // Only block if it's our custom blocker AND the pan is horizontal
            if pan === panBlocker {
                return false // never let our blocker actually begin
            }
            return true
        }

        private func installKeyboardOffsetPreservation(for scrollView: UIScrollView) {
            guard keyboardObservers.isEmpty else { return }
            let names: [Notification.Name] = [
                UIResponder.keyboardWillShowNotification,
                UIResponder.keyboardWillHideNotification,
                UIResponder.keyboardWillChangeFrameNotification
            ]
            keyboardObservers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self, weak scrollView] notification in
                    guard let self, let scrollView else { return }
                    self.beginPreservingVerticalOffset(for: scrollView, notification: notification)
                }
            }
        }

        private func beginPreservingVerticalOffset(for scrollView: UIScrollView, notification: Notification) {
            guard !scrollView.isDragging, !scrollView.isTracking, !scrollView.isDecelerating else { return }
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            preservedOffsetY = scrollView.contentOffset.y
            preserveOffsetUntil = Date().addingTimeInterval(duration + 0.18)

            restorePreservedVerticalOffset(in: scrollView)
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.restorePreservedVerticalOffset(in: scrollView)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.06) { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.restorePreservedVerticalOffset(in: scrollView)
            }
        }

        private func shouldPreserveVerticalOffset(in scrollView: UIScrollView) -> Bool {
            guard let until = preserveOffsetUntil, Date() < until else {
                preservedOffsetY = nil
                preserveOffsetUntil = nil
                return false
            }
            return !scrollView.isDragging && !scrollView.isTracking && !scrollView.isDecelerating
        }

        private func restorePreservedVerticalOffset(in scrollView: UIScrollView) {
            guard shouldPreserveVerticalOffset(in: scrollView),
                  let preservedY = preservedOffsetY else { return }
            let targetY = clampedOffsetY(preservedY, in: scrollView)
            guard abs(scrollView.contentOffset.y - targetY) > 0.5 else { return }
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }

        private func clampedOffsetY(_ y: CGFloat, in scrollView: UIScrollView) -> CGFloat {
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(
                minY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            return min(max(y, minY), maxY)
        }
    }
}

// MARK: - Action Event Modifiers (Type-Checker Relief)

/// Extracted into a View extension to reduce the expression complexity of
/// ChatDetailView.body. Applying these three modifiers inline in body
/// pushed the expression past the Swift type-checker limit.
private extension View {
    func applyActionEventModifiers(
        actionInputRequest: Binding<ActionInputRequest?>,
        actionConfirmRequest: Binding<ActionConfirmRequest?>,
        actionNotificationToast: Binding<String?>,
        actionCallContinuation: Binding<CheckedContinuation<ActionCallResponse, Never>?>,
        actionInputText: Binding<String>,
        localAlpineInputRequest: Binding<LocalAlpineInteractiveRequest?>,
        localAlpineInputText: Binding<String>,
        onLocalAlpineConfirm: @escaping () -> Void,
        onLocalAlpineCancel: @escaping () -> Void
    ) -> some View {
        self
            // MARK: __event_call__ — input dialog (presented as a sheet for reliability)
            .sheet(isPresented: Binding(
                get: { actionInputRequest.wrappedValue != nil },
                set: { if !$0 { } }
            )) {
                ActionInputSheet(
                    request: actionInputRequest.wrappedValue!,
                    text: actionInputText,
                    onConfirm: {
                        actionCallContinuation.wrappedValue?.resume(returning: .string(actionInputText.wrappedValue))
                        actionCallContinuation.wrappedValue = nil
                        actionInputRequest.wrappedValue = nil
                        actionInputText.wrappedValue = ""
                    },
                    onCancel: {
                        actionCallContinuation.wrappedValue?.resume(returning: .cancelled)
                        actionCallContinuation.wrappedValue = nil
                        actionInputRequest.wrappedValue = nil
                        actionInputText.wrappedValue = ""
                    }
                )
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            }
            // MARK: __event_call__ — confirmation dialog
            .confirmationDialog(
                actionConfirmRequest.wrappedValue?.title ?? "确认",
                isPresented: Binding(
                    get: { actionConfirmRequest.wrappedValue != nil },
                    set: { if !$0 { } }
                ),
                titleVisibility: .visible
            ) {
                Button("确认") {
                    actionCallContinuation.wrappedValue?.resume(returning: .bool(true))
                    actionCallContinuation.wrappedValue = nil
                    actionConfirmRequest.wrappedValue = nil
                }
                Button("取消", role: .cancel) {
                    actionCallContinuation.wrappedValue?.resume(returning: .bool(false))
                    actionCallContinuation.wrappedValue = nil
                    actionConfirmRequest.wrappedValue = nil
                }
            } message: {
                if let req = actionConfirmRequest.wrappedValue { Text(req.message) }
            }
            // MARK: __event_emitter__ — notification toast
            .overlay(alignment: .top) {
                if let toastMsg = actionNotificationToast.wrappedValue {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill").font(.system(size: 11, weight: .medium))
                        Text(toastMsg).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.label).opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 14 + 44) // clear navigation bar
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .allowsHitTesting(false)
                }
            }
            .sheet(item: localAlpineInputRequest) { request in
                ActionInputSheet(
                    request: ActionInputRequest(
                        title: request.title,
                        message: request.message,
                        placeholder: request.placeholder,
                        defaultValue: request.defaultValue
                    ),
                    text: localAlpineInputText,
                    onConfirm: onLocalAlpineConfirm,
                    onCancel: onLocalAlpineCancel
                )
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            }
    }
}

// MARK: - Widget & Picker Notification Handlers (Type-Checker Relief)

/// Extracted into a View extension to reduce the expression complexity of
/// ChatDetailView.body, which was hitting the Swift type-checker limit.
private extension View {
    func applyWidgetAndPickerHandlers(
        showCameraPicker: Binding<Bool>,
        showPhotosPicker: Binding<Bool>,
        showFilePicker: Binding<Bool>,
        showWebURLAlert: Binding<Bool>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        codePreviewCode: Binding<String?>,
        codePreviewLanguage: Binding<String>,
        onDismissOverlays: @escaping () -> Void
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .markdownCodePreview)) { notification in
                if let code = notification.userInfo?["code"] as? String {
                    codePreviewLanguage.wrappedValue = notification.userInfo?["language"] as? String ?? ""
                    codePreviewCode.wrappedValue = code
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIDismissOverlays)) { _ in
                onDismissOverlays()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUICameraChat)) { _ in
                showCameraPicker.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIPhotosChat)) { _ in
                showPhotosPicker.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIFileChat)) { _ in
                showFilePicker.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIWebChat)) { _ in
                showWebURLAlert.wrappedValue = true
            }
            .photosPicker(
                isPresented: showPhotosPicker,
                selection: selectedPhotos,
                maxSelectionCount: 5,
                matching: .images,
                photoLibrary: .shared()
            )
            .sheet(item: codePreviewCode) { code in
                FullCodeView(code: code, language: codePreviewLanguage.wrappedValue)
            }
    }
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Action Event UI Models

/// Carries the data for a pending `__event_call__` input prompt.
/// Setting this on `@State` triggers the `.alert` modifier in the view body.
struct ActionInputRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let placeholder: String
    let defaultValue: String
}

/// Carries the data for a pending `__event_call__` confirmation dialog.
/// Setting this on `@State` triggers the `.confirmationDialog` modifier in the view body.
struct ActionConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - ActionInputSheet

/// A bottom sheet that prompts the user for text input in response to a `__event_call__` input event.
/// Shown in place of a `.alert`-based dialog because SwiftUI alerts with TextFields are unreliable.
struct ActionInputSheet: View {
    let request: ActionInputRequest
    @Binding var text: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Drag handle is shown via .presentationDragIndicator(.visible)

            Text(request.title)
                .font(.headline)
                .foregroundStyle(.primary)

            if !request.message.isEmpty {
                Text(request.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty, !request.placeholder.isEmpty {
                    Text(request.placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 74, maxHeight: 92)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text("确认")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.primary)
                        .foregroundStyle(Color(.systemBackground))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}
