import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import QuickLook
import PDFKit
import ImageIO
import MarkdownView
import Translation
import WebKit
import os.log
import Darwin

// MARK: - Chat Detail View

private let agentToolWebPreviewPrefix = "web-preview:"

private func agentToolWebPreviewReference(for target: String) -> String {
    agentToolWebPreviewPrefix + target
}

private func agentToolWebPreviewTarget(from reference: String) -> String? {
    let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix(agentToolWebPreviewPrefix) else { return nil }
    let value = String(trimmed.dropFirst(agentToolWebPreviewPrefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private struct MessageShareItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct LocalQuickLookPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

private func localAlpinePreviewShouldUseWebView(_ url: URL) -> Bool {
    ["html", "htm", "xhtml", "svg"].contains(url.pathExtension.lowercased())
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
    let sortOrder: Double
    let kind: Kind
    let title: String
    let detail: String
    let isRunning: Bool
    let failed: Bool
    let outputPreview: String
    let fullOutput: String?
    let outputReference: String?
    let outputByteCount: Int?
    let outputLineCount: Int?
    let file: LocalAlpineWrittenFile?
    let filePaths: [String]
    let command: String?
    let cwd: String?
    let durationText: String?
    let durationStartedAt: Date?
    let previewThumbnailReference: String?
    let previewOpenURL: String?
    let previewFile: ChatMessageFile?

    var hasInspectablePayload: Bool {
        file != nil
            || command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || fullOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || outputReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isLocalStatusPlaceholder: Bool {
        kind == .status && id.hasPrefix("local-status-")
    }

    var isInteractiveBrowserStatusStep: Bool {
        guard kind == .status else { return false }
        return Self.isInteractiveBrowserStatusId(id.lowercased())
    }

    var isWebSearchStatusStep: Bool {
        guard kind == .status else { return false }
        let normalizedId = id.lowercased()
        if Self.isInteractiveBrowserStatusId(normalizedId) {
            return false
        }
        return normalizedId.contains("web_search")
            || normalizedId.contains("websearch")
            || normalizedId.contains("browser_web_search")
            || normalizedId.contains("get_readable")
            || normalizedId.contains("readable")
    }

    private static func isInteractiveBrowserStatusId(_ value: String) -> Bool {
        [
            "browser.auto", "browser.use", "browser.workflow_state",
            "browser.open", "browser.navigate", "browser.find_elements",
            "browser.click", "browser.type", "browser.hover", "browser.scroll",
            "browser.scroll_and_collect", "browser.get_backbone", "browser.get_page_info",
            "browser.info", "browser.inspect",
            "browser.observe", "browser.get_state",
            "browser.screenshot", "browser.wait_for_dom_stable", "browser.wait_for_image",
            "browser.execute_js", "browser.fetch", "browser.new_tab", "browser.close_tab",
            "browser.list_tabs", "browser.set_viewport", "browser.set_user_agent", "browser.get_cookies"
        ].contains { value.contains($0) }
    }

    static func == (lhs: AgentActivityStep, rhs: AgentActivityStep) -> Bool {
        lhs.id == rhs.id
            && lhs.sortOrder == rhs.sortOrder
            && lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.isRunning == rhs.isRunning
            && lhs.failed == rhs.failed
            && lhs.outputReference == rhs.outputReference
            && lhs.outputByteCount == rhs.outputByteCount
            && lhs.outputLineCount == rhs.outputLineCount
            && lhs.file?.path == rhs.file?.path
            && lhs.file?.byteCount == rhs.file?.byteCount
            && lhs.file?.lineCount == rhs.file?.lineCount
            && lhs.filePaths == rhs.filePaths
            && lhs.command == rhs.command
            && lhs.cwd == rhs.cwd
            && lhs.durationText == rhs.durationText
            && lhs.durationStartedAt == rhs.durationStartedAt
            && lhs.previewThumbnailReference == rhs.previewThumbnailReference
            && lhs.previewOpenURL == rhs.previewOpenURL
            && lhs.previewFile?.url == rhs.previewFile?.url
            && lhs.previewFile?.name == rhs.previewFile?.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(sortOrder)
        hasher.combine(kind)
        hasher.combine(title)
        hasher.combine(detail)
        hasher.combine(isRunning)
        hasher.combine(failed)
        hasher.combine(outputReference)
        hasher.combine(outputByteCount)
        hasher.combine(outputLineCount)
        hasher.combine(file?.path)
        hasher.combine(file?.byteCount)
        hasher.combine(file?.lineCount)
        hasher.combine(filePaths)
        hasher.combine(command)
        hasher.combine(cwd)
        hasher.combine(durationText)
        hasher.combine(durationStartedAt)
        hasher.combine(previewThumbnailReference)
        hasher.combine(previewOpenURL)
        hasher.combine(previewFile?.url)
        hasher.combine(previewFile?.name)
    }
}

private enum AgentToolBlockStatus: String, Hashable {
    case streaming
    case pending
    case running
    case success
    case failed
    case cancelled
    case timeout

    var isRunning: Bool {
        self == .streaming || self == .pending || self == .running
    }

    var isFailure: Bool {
        self == .failed || self == .timeout || self == .cancelled
    }
}

private struct AgentToolBlock: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case thinking
        case text
        case toolUse
        case info
        case status
        case file
        case command
    }

    let id: String
    let kind: Kind
    let content: String
    let status: AgentToolBlockStatus?
    let title: String
    let toolName: String
    let toolArgs: String
    let sortOrder: Double
    let durationText: String?
    let browserURL: String?
    let imageFilePath: String?
    let outputReference: String?
    let outputByteCount: Int?
    let outputLineCount: Int?
    let file: LocalAlpineWrittenFile?
    let filePaths: [String]
    let command: String?
    let cwd: String?
    let previewThumbnailReference: String?
    let previewOpenURL: String?
    let previewFile: ChatMessageFile?
}

private struct CollapsedStatusGroup {
    let startIndex: Int
    let action: String
    let stepKey: String
    var subject: String
    var statuses: [ChatStatusUpdate]

    var key: String {
        let stepComponent = stepKey.isEmpty ? action : "\(action)::\(stepKey)"
        return subject.isEmpty ? stepComponent : "\(stepComponent)::\(subject)"
    }
}

private struct LocalAlpineInstructionSpan {
    let range: Range<String.Index>
    let body: String
}

private struct OrderedAgentTranscriptBlock: Identifiable {
    enum Content {
        case text(String)
        case steps(AgentActivityItem)
    }

    let id: String
    let content: Content
}

private struct AgentActivityItem: Identifiable, Hashable {
    private static let uiOutputPreviewLimit = 700
    private static let floatingOutputPreviewLimit = 480
    private static let floatingDetailLimit = 420
    private static let floatingCommandLimit = 900

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

    var hasInteractiveBrowserStatusSteps: Bool {
        steps.contains { $0.isInteractiveBrowserStatusStep }
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

    var firstPreviewThumbnailReference: String? {
        steps.compactMap { step in
            let reference = step.previewThumbnailReference?.trimmingCharacters(in: .whitespacesAndNewlines)
            return reference?.isEmpty == false ? reference : nil
        }.last
    }

    var firstPreviewOpenURL: String? {
        steps.compactMap { step in
            let value = step.previewOpenURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.normalizedPreviewTarget(value)
        }.last
    }

    var firstPreviewFile: ChatMessageFile? {
        steps.compactMap(\.previewFile).last
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

    static func liveLocalAlpine(
        messageId: String,
        toolCalls: [LocalAlpineToolCall],
        liveStatus: ChatStatusUpdate?
    ) -> AgentActivityItem? {
        let statusHistory = liveStatus.map { [$0] } ?? []
        let steps = steps(
            toolCalls: toolCalls,
            writtenFiles: [],
            commandResults: [],
            fullToolCalls: toolCalls,
            fullCommandResults: [],
            statusHistory: statusHistory,
            officePreviewReferences: [],
            officeDocumentFiles: [],
            generatedImageFiles: []
        )
        guard !steps.isEmpty else { return nil }

        let filePaths = Set(toolCalls.flatMap(\.filePaths))
        let commandCount = toolCalls.filter { call in
            if call.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return true
            }
            let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return name == "command" || name == "shell_execute" || name == "run_script"
        }.count
        let timestamp = toolCalls
            .compactMap { call -> Date? in
                guard call.startedAtMs > 0 else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(call.startedAtMs) / 1_000)
            }
            .min() ?? .now
        let isStreaming = toolCalls.contains { $0.isRunning } || (liveStatus != nil && liveStatus?.done != true)
        let summary = steps.last(where: { $0.isRunning })?.title
            ?? steps.last?.title
            ?? "本地步骤"

        return AgentActivityItem(
            id: "live-local-alpine-\(messageId)",
            timestamp: timestamp,
            isStreaming: isStreaming,
            summary: summary,
            fileCount: filePaths.count,
            commandCount: commandCount,
            hasFailure: toolCalls.contains { $0.failed },
            writtenFiles: [],
            commandResults: [],
            toolCalls: toolCalls,
            steps: steps
        )
    }

    func limitingSteps(to maxSteps: Int) -> AgentActivityItem {
        guard maxSteps > 0 else { return self }

        let limitedSteps = Array(steps.suffix(maxSteps)).map(Self.lightweightFloatingStep)
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
            summary: steps.count > maxSteps ? "最近 \(maxSteps) 个步骤" : summary,
            fileCount: limitedFileCount,
            commandCount: limitedCommandCount,
            hasFailure: limitedSteps.contains { $0.failed },
            writtenFiles: limitedSteps.compactMap(\.file),
            commandResults: [],
            toolCalls: [],
            steps: limitedSteps
        )
    }

    func retainingSteps(_ retainedSteps: [AgentActivityStep], idSuffix: String) -> AgentActivityItem? {
        guard !retainedSteps.isEmpty else { return nil }
        let stepIds = Set(retainedSteps.map(\.id))
        let retainedToolCalls = toolCalls.filter { stepIds.contains("tool-\($0.id)") }
        let retainedFiles = retainedSteps.compactMap(\.file)
        let retainedCommandCount = retainedSteps.filter { step in
            step.kind == .command
                || step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.count
        let retainedFileCount = retainedSteps.filter { step in
            step.kind == .file || step.file != nil
        }.count
        let retainedSummary = retainedSteps.last(where: { $0.isRunning })?.title
            ?? retainedSteps.last?.title
            ?? summary

        return AgentActivityItem(
            id: "\(id)::\(idSuffix)",
            timestamp: timestamp,
            isStreaming: isStreaming && retainedSteps.contains { $0.isRunning },
            summary: retainedSummary,
            fileCount: retainedFileCount,
            commandCount: retainedCommandCount,
            hasFailure: retainedSteps.contains { $0.failed },
            writtenFiles: retainedFiles,
            commandResults: [],
            toolCalls: retainedToolCalls,
            steps: retainedSteps
        )
    }

    private static func lightweightFloatingStep(_ step: AgentActivityStep) -> AgentActivityStep {
        AgentActivityStep(
            id: step.id,
            sortOrder: step.sortOrder,
            kind: step.kind,
            title: step.title,
            detail: clippedFloatingText(step.detail, limit: floatingDetailLimit),
            isRunning: step.isRunning,
            failed: step.failed,
            outputPreview: clippedFloatingText(step.outputPreview, limit: floatingOutputPreviewLimit),
            fullOutput: nil,
            outputReference: step.outputReference,
            outputByteCount: step.outputByteCount,
            outputLineCount: step.outputLineCount,
            file: step.file.map(lightweightFloatingFile),
            filePaths: step.filePaths,
            command: step.command.map { clippedFloatingText($0, limit: floatingCommandLimit) },
            cwd: step.cwd,
            durationText: step.durationText,
            durationStartedAt: step.durationStartedAt,
            previewThumbnailReference: lightweightThumbnailReference(step.previewThumbnailReference),
            previewOpenURL: step.previewOpenURL,
            previewFile: step.previewFile.map(lightweightPreviewFile)
        )
    }

    private static func lightweightFloatingFile(_ file: LocalAlpineWrittenFile) -> LocalAlpineWrittenFile {
        LocalAlpineWrittenFile(
            path: file.path,
            content: file.previewLines(limit: 8).joined(separator: "\n"),
            source: file.source,
            byteCount: file.byteCount,
            lineCountValue: file.lineCount,
            diffPreviewLines: file.diffPreviewLines
        )
    }

    private static func lightweightPreviewFile(_ file: ChatMessageFile) -> ChatMessageFile {
        ChatMessageFile(
            type: file.type,
            url: file.url,
            name: file.name,
            contentType: file.contentType,
            displayURL: nil
        )
    }

    private static func lightweightThumbnailReference(_ reference: String?) -> String? {
        let trimmed = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("data:image/") {
            return nil
        }
        return trimmed
    }

    private static func clippedFloatingText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n...（预览已截断）"
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

    private static func activityStep(from block: AgentToolBlock) -> AgentActivityStep {
        let stepKind: AgentActivityStep.Kind
        switch block.kind {
        case .toolUse:
            stepKind = .tool
        case .file:
            stepKind = .file
        case .command:
            stepKind = .command
        case .thinking, .text, .info, .status:
            stepKind = .status
        }

        let detail = block.toolArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? block.content
            : block.toolArgs

        return AgentActivityStep(
            id: block.id,
            sortOrder: block.sortOrder,
            kind: stepKind,
            title: block.title,
            detail: detail,
            isRunning: block.status?.isRunning == true,
            failed: block.status?.isFailure == true,
            outputPreview: block.content,
            fullOutput: block.outputReference == nil ? block.content : nil,
            outputReference: block.outputReference,
            outputByteCount: block.outputByteCount,
            outputLineCount: block.outputLineCount,
            file: block.file,
            filePaths: block.filePaths,
            command: block.command,
            cwd: block.cwd,
            durationText: block.durationText,
            durationStartedAt: nil,
            previewThumbnailReference: block.previewThumbnailReference,
            previewOpenURL: block.previewOpenURL,
            previewFile: block.previewFile
        )
    }

    private static func toolBlock(
        for call: LocalAlpineToolCall,
        file matchedFile: LocalAlpineWrittenFile?,
        fallbackIndex: Int
    ) -> AgentToolBlock {
        let title = displayTitle(for: call, file: matchedFile)
        let detail = call.displayDetail
        let output = call.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reference = call.outputReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputReference = reference?.isEmpty == false ? reference : nil

        return AgentToolBlock(
            id: "tool-\(call.id)",
            kind: .toolUse,
            content: output,
            status: toolBlockStatus(for: call),
            title: title,
            toolName: call.name,
            toolArgs: detail.isEmpty ? title : detail,
            sortOrder: toolSortOrder(call, fallbackIndex: fallbackIndex),
            durationText: durationText(for: call),
            browserURL: call.browserURL,
            imageFilePath: call.imageFilePath,
            outputReference: outputReference,
            outputByteCount: call.outputByteCount,
            outputLineCount: call.outputLineCount,
            file: matchedFile,
            filePaths: call.filePaths,
            command: call.command,
            cwd: call.cwd,
            previewThumbnailReference: toolCallThumbnailReference(for: call, file: matchedFile),
            previewOpenURL: toolCallPreviewOpenTarget(for: call, file: matchedFile),
            previewFile: nil
        )
    }

    private static func fileBlock(for file: LocalAlpineWrittenFile, fallbackIndex: Int) -> AgentToolBlock {
        AgentToolBlock(
            id: "file-\(file.path)",
            kind: .file,
            content: file.previewLines(limit: 10).joined(separator: "\n"),
            status: .success,
            title: "写入 \(file.fileName)",
            toolName: "file_write",
            toolArgs: file.path,
            sortOrder: fallbackStepSortOrder(index: fallbackIndex, bucket: 1),
            durationText: nil,
            browserURL: nil,
            imageFilePath: isImagePath(file.path) ? file.path : nil,
            outputReference: nil,
            outputByteCount: nil,
            outputLineCount: nil,
            file: file,
            filePaths: [file.path],
            command: nil,
            cwd: nil,
            previewThumbnailReference: isImagePath(file.path) ? file.path : nil,
            previewOpenURL: nil,
            previewFile: nil
        )
    }

    private static func commandBlock(for result: LocalAlpineAgentCommandResult, fallbackIndex: Int) -> AgentToolBlock? {
        let command = result.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.lowercased() != "write_files" else { return nil }
        let reference = result.outputReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputReference = reference?.isEmpty == false ? reference : nil

        return AgentToolBlock(
            id: "command-\(fallbackIndex)-\(command.hashValue)",
            kind: .command,
            content: result.outputPreview,
            status: result.failed ? .failed : .success,
            title: commandStepTitle(for: command, failed: result.failed),
            toolName: "shell_execute",
            toolArgs: command,
            sortOrder: fallbackStepSortOrder(index: fallbackIndex, bucket: 2),
            durationText: nil,
            browserURL: nil,
            imageFilePath: nil,
            outputReference: outputReference,
            outputByteCount: result.outputByteCount,
            outputLineCount: result.outputLineCount,
            file: nil,
            filePaths: [],
            command: command,
            cwd: result.cwd,
            previewThumbnailReference: nil,
            previewOpenURL: Self.localWebPreviewTarget(in: result.outputPreview),
            previewFile: nil
        )
    }

    private static func statusToolBlocks(
        from statusHistory: [ChatStatusUpdate],
        officePreviewReferences: [String],
        officeDocumentFiles: [ChatMessageFile],
        generatedImageFiles: [ChatMessageFile]
    ) -> [AgentToolBlock] {
        let groups = collapsedStatusGroups(from: statusHistory) { _, action in
            if action.contains("local_alpine_agent") || action.contains("local_alpine_tool") {
                return false
            }
            return action.contains("web_search")
                || action.contains("browser_web_search")
                || action == "browser_use"
                || action.hasPrefix("browser.")
                || action.contains("code_interpreter")
                || action.contains("image_generation")
                || action.contains("get_readable")
                || action.contains("readable")
                || action.contains("local_native_tool")
                || action.contains("local_office_agent")
        }

        return groups.compactMap { group -> AgentToolBlock? in
            guard let status = group.statuses.last else { return nil }
            let action = group.action
            let title = title(for: status, action: action)
            let detail = statusDetail(
                for: group.statuses,
                fallbackTitle: title
            )
            let output = statusPreviewText(for: group.statuses)
            let statusValue = statusBlockStatus(for: group.statuses)
            let previewFile = action.contains("local_office_agent") ? officeDocumentFiles.first : nil

            return AgentToolBlock(
                id: "status-\(group.startIndex)-\(group.key)",
                kind: .status,
                content: output.isEmpty ? detail : output,
                status: statusValue,
                title: title,
                toolName: action,
                toolArgs: detail,
                sortOrder: statusSortOrder(group),
                durationText: durationText(for: group.statuses, isRunning: statusValue.isRunning),
                browserURL: statusOpenURL(for: group.statuses, action: action),
                imageFilePath: nil,
                outputReference: nil,
                outputByteCount: nil,
                outputLineCount: nil,
                file: nil,
                filePaths: [],
                command: nil,
                cwd: nil,
                previewThumbnailReference: statusThumbnailReference(
                    for: group.statuses,
                    action: action,
                    officePreviewReferences: officePreviewReferences,
                    generatedImageFiles: generatedImageFiles
                ),
                previewOpenURL: statusOpenURL(for: group.statuses, action: action),
                previewFile: previewFile
            )
        }
    }

    private static func localStatusToolBlocks(from statusHistory: [ChatStatusUpdate]) -> [AgentToolBlock] {
        let groups = collapsedStatusGroups(from: statusHistory) { _, action in
            action == "local_alpine"
                || action == "local_alpine_agent"
                || action == "local_alpine_tool"
        }

        return groups.compactMap { group -> AgentToolBlock? in
            guard let status = group.statuses.last else { return nil }
            let action = group.action
            guard isConcreteLocalStatus(status, action: action) else { return nil }

            let title = title(for: status, action: action)
            let detail = status.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? status.status?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? title
            let statusValue = statusBlockStatus(for: group.statuses)

            return AgentToolBlock(
                id: "local-status-\(group.startIndex)-\(group.key)",
                kind: .status,
                content: detail,
                status: statusValue,
                title: title,
                toolName: action,
                toolArgs: detail == title ? "" : detail,
                sortOrder: statusSortOrder(group),
                durationText: durationText(for: group.statuses, isRunning: statusValue.isRunning),
                browserURL: nil,
                imageFilePath: nil,
                outputReference: nil,
                outputByteCount: nil,
                outputLineCount: nil,
                file: nil,
                filePaths: [],
                command: nil,
                cwd: nil,
                previewThumbnailReference: nil,
                previewOpenURL: nil,
                previewFile: nil
            )
        }
    }

    private static func toolBlockStatus(for call: LocalAlpineToolCall) -> AgentToolBlockStatus {
        if call.failed { return .failed }
        if call.isRunning { return .running }
        return .success
    }

    private static func statusBlockStatus(for statuses: [ChatStatusUpdate]) -> AgentToolBlockStatus {
        let text = statuses
            .map(statusText(_:))
            .joined(separator: " ")
            .lowercased()

        if containsAny(text, ["timeout", "timed out", "超时"]) {
            return .timeout
        }
        if containsAny(text, ["cancelled", "canceled", "已取消", "取消执行"]) {
            return .cancelled
        }
        if containsAny(text, ["failed", "failure", "error", "exception", "失败", "错误", "报错", "异常"]) {
            return .failed
        }
        guard let latest = statuses.last else { return .success }
        if latest.done != true {
            if containsAny(text, ["pending", "waiting", "queued", "等待", "排队"]) {
                return .pending
            }
            return .running
        }
        return .success
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func steps(
        toolCalls: [LocalAlpineToolCall],
        writtenFiles: [LocalAlpineWrittenFile],
        commandResults: [LocalAlpineAgentCommandResult],
        fullToolCalls: [LocalAlpineToolCall]? = nil,
        fullCommandResults: [LocalAlpineAgentCommandResult]? = nil,
        statusHistory: [ChatStatusUpdate],
        officePreviewReferences: [String],
        officeDocumentFiles: [ChatMessageFile],
        generatedImageFiles: [ChatMessageFile]
    ) -> [AgentActivityStep] {
        var blocks = statusToolBlocks(
            from: statusHistory,
            officePreviewReferences: officePreviewReferences,
            officeDocumentFiles: officeDocumentFiles,
            generatedImageFiles: generatedImageFiles
        )
        let localStatusPlaceholderBlocks = localStatusToolBlocks(from: statusHistory)

        blocks.append(contentsOf: toolCalls.enumerated().map { index, call in
            let matchedFile = file(for: call, in: writtenFiles)
            return toolBlock(for: call, file: matchedFile, fallbackIndex: index)
        })

        let existingFilePaths = Set(blocks.compactMap { $0.file?.path })
        for (index, file) in writtenFiles.filter({ !existingFilePaths.contains($0.path) }).enumerated() {
            blocks.append(fileBlock(for: file, fallbackIndex: index))
        }

        let existingCommands = Set(toolCalls.compactMap { call -> String? in
            let command = call.command?.trimmingCharacters(in: .whitespacesAndNewlines)
            return command?.isEmpty == false ? command : nil
        })
        let structuredToolPathsByName = Self.structuredToolPathsByName(from: toolCalls)
        for (index, result) in commandResults.enumerated() {
            let command = result.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, command.lowercased() != "write_files" else { continue }
            guard !existingCommands.contains(command) else { continue }
            guard !Self.commandDuplicatesStructuredTool(command, toolPathsByName: structuredToolPathsByName) else { continue }
            if let block = commandBlock(for: result, fallbackIndex: index) {
                blocks.append(block)
            }
        }

        let steps = blocks.map { activityStep(from: $0) }
        let concreteSteps = steps.filter { step in
            switch step.kind {
            case .status:
                return step.isRunning
                    || step.isInteractiveBrowserStatusStep
                    || (step.hasInspectablePayload && !step.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .tool:
                return true
            case .file, .command:
                return true
            }
        }
        let visibleSteps = concreteSteps.isEmpty
            ? localStatusPlaceholderBlocks.map { activityStep(from: $0) }
            : concreteSteps
        return orderedActivitySteps(visibleSteps)
    }

    private static func orderedActivitySteps(_ steps: [AgentActivityStep]) -> [AgentActivityStep] {
        steps.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.id < rhs.id
        }
    }

    private static func toolSortOrder(_ call: LocalAlpineToolCall, fallbackIndex: Int) -> Double {
        if call.startedAtMs > 0 {
            return Double(call.startedAtMs) / 1_000
        }
        if let completedAtMs = call.completedAtMs, completedAtMs > 0 {
            return Double(completedAtMs) / 1_000
        }
        return fallbackStepSortOrder(index: fallbackIndex, bucket: 0)
    }

    private static func statusSortOrder(_ group: CollapsedStatusGroup) -> Double {
        if let occurredAt = group.statuses.compactMap(\.occurredAt).first {
            return occurredAt.timeIntervalSince1970
        }
        return fallbackStepSortOrder(index: group.startIndex, bucket: -1)
    }

    private static func fallbackStepSortOrder(index: Int, bucket: Int) -> Double {
        9_000_000_000 + Double(bucket * 100_000 + index)
    }

    private static func structuredToolPathsByName(from toolCalls: [LocalAlpineToolCall]) -> [String: Set<String>] {
        var pathsByName: [String: Set<String>] = [:]
        for call in toolCalls {
            let names = structuredToolCommandNames(for: call.name)
            guard !names.isEmpty else { continue }
            let paths = call.filePaths
                .map(normalizedPath(_:))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !paths.isEmpty else { continue }
            for name in names {
                for path in paths {
                    pathsByName[name, default: []].formUnion(structuredToolPathAliases(for: path))
                }
            }
        }
        return pathsByName
    }

    private static func structuredToolCommandNames(for toolName: String) -> Set<String> {
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read_file", "read_files", "read", "file_read", "open_file", "cat":
            return ["read_file", "file_read", "open_file"]
        case "edit_file", "edit_files", "replace_file", "edit", "file_edit":
            return ["edit_file", "file_edit"]
        case "write_files", "write_file", "write", "file_write":
            return ["write_files", "write_file", "file_write"]
        case "patch_file", "patch_files", "apply_patch", "patch":
            return ["patch_file", "apply_patch"]
        case "delete_file", "delete_files", "remove_file", "remove_files", "file_delete":
            return ["delete_file", "delete_files", "remove_file", "remove_files", "file_delete"]
        default:
            return []
        }
    }

    private static func commandDuplicatesStructuredTool(
        _ command: String,
        toolPathsByName: [String: Set<String>]
    ) -> Bool {
        let parts = command
            .split(separator: " ", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let rawName = parts.first?.lowercased(),
              let paths = toolPathsByName[rawName],
              !paths.isEmpty else {
            return false
        }
        guard parts.count > 1 else { return false }
        let normalizedArgument = normalizedPath(parts[1])
        guard !normalizedArgument.isEmpty else { return false }
        return !structuredToolPathAliases(for: normalizedArgument).isDisjoint(with: paths)
    }

    private static func structuredToolPathAliases(for path: String) -> Set<String> {
        let normalized = normalizedPath(path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var aliases: Set<String> = [normalized, (normalized as NSString).lastPathComponent]
        if normalized.hasPrefix("/mnt/iexa/") {
            let relative = String(normalized.dropFirst("/mnt/iexa/".count))
            aliases.insert(relative)
            aliases.insert((relative as NSString).lastPathComponent)
        } else if !normalized.hasPrefix("/") {
            aliases.insert("/mnt/iexa/\(normalized)")
        }
        return aliases
    }

    private static func statusSteps(
        from statusHistory: [ChatStatusUpdate],
        officePreviewReferences: [String],
        officeDocumentFiles: [ChatMessageFile],
        generatedImageFiles: [ChatMessageFile] = []
    ) -> [AgentActivityStep] {
        let groups = collapsedStatusGroups(from: statusHistory) { _, action in
            if action.contains("local_alpine_agent") || action.contains("local_alpine_tool") {
                return false
            }
            return action.contains("web_search")
                || action.contains("browser_web_search")
                || action == "browser_use"
                || action.hasPrefix("browser.")
                || action.contains("code_interpreter")
                || action.contains("image_generation")
                || action.contains("get_readable")
                || action.contains("readable")
                || action.contains("local_native_tool")
                || action.contains("local_office_agent")
        }

        return groups.compactMap { group -> AgentActivityStep? in
            guard let status = group.statuses.last else { return nil }
            let action = group.action
            let title = title(for: status, action: action)
            let detail = statusDetail(
                for: group.statuses,
                fallbackTitle: title
            )
            let output = statusPreviewText(for: group.statuses)
            let previewThumbnail = statusThumbnailReference(
                for: group.statuses,
                action: action,
                officePreviewReferences: officePreviewReferences,
                generatedImageFiles: generatedImageFiles
            )
            let previewURL = statusOpenURL(for: group.statuses, action: action)
            let previewFile = action.contains("local_office_agent") ? officeDocumentFiles.first : nil
            let isRunning = status.done != true
            let startedAt: Date? = isRunning ? group.statuses.compactMap(\.occurredAt).first : nil
            let duration = durationText(for: group.statuses, isRunning: isRunning)
            return AgentActivityStep(
                id: "status-\(group.startIndex)-\(group.key)",
                sortOrder: statusSortOrder(group),
                kind: .status,
                title: title,
                detail: detail,
                isRunning: isRunning,
                failed: false,
                outputPreview: output.isEmpty ? detail : output,
                fullOutput: output.isEmpty ? detail : output,
                outputReference: nil,
                outputByteCount: nil,
                outputLineCount: nil,
                file: nil,
                filePaths: [],
                command: nil,
                cwd: nil,
                durationText: duration,
                durationStartedAt: startedAt,
                previewThumbnailReference: previewThumbnail,
                previewOpenURL: previewURL,
                previewFile: previewFile
            )
        }
    }

    private static func localStatusSteps(from statusHistory: [ChatStatusUpdate]) -> [AgentActivityStep] {
        let groups = collapsedStatusGroups(from: statusHistory) { _, action in
            action == "local_alpine"
                || action == "local_alpine_agent"
                || action == "local_alpine_tool"
        }

        return groups.compactMap { group -> AgentActivityStep? in
            guard let status = group.statuses.last else { return nil }
            let action = group.action
            guard isConcreteLocalStatus(status, action: action) else { return nil }

            let title = title(for: status, action: action)
            let detail = status.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? status.status?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? title
            let isRunning = status.done != true
            let startedAt: Date? = isRunning ? group.statuses.compactMap(\.occurredAt).first : nil
            let duration = durationText(for: group.statuses, isRunning: isRunning)
            return AgentActivityStep(
                id: "local-status-\(group.startIndex)-\(group.key)",
                sortOrder: statusSortOrder(group),
                kind: .status,
                title: title,
                detail: detail == title ? "" : detail,
                isRunning: isRunning,
                failed: false,
                outputPreview: detail,
                fullOutput: detail,
                outputReference: nil,
                outputByteCount: nil,
                outputLineCount: nil,
                file: nil,
                filePaths: [],
                command: nil,
                cwd: nil,
                durationText: duration,
                durationStartedAt: startedAt,
                previewThumbnailReference: nil,
                previewOpenURL: nil,
                previewFile: nil
            )
        }
    }

    private static func durationText(for statuses: [ChatStatusUpdate], isRunning: Bool) -> String? {
        let timestamps = statuses.compactMap(\.occurredAt)
        guard let startedAt = timestamps.first else { return nil }

        let endedAt: Date
        if isRunning {
            endedAt = Date()
        } else {
            guard let last = timestamps.last, last > startedAt else { return nil }
            endedAt = last
        }

        return durationText(seconds: endedAt.timeIntervalSince(startedAt))
    }

    private static func durationText(for call: LocalAlpineToolCall) -> String? {
        guard let completedAtMs = call.completedAtMs,
              call.startedAtMs > 0,
              completedAtMs >= call.startedAtMs else {
            return nil
        }
        let seconds = Double(completedAtMs - call.startedAtMs) / 1_000
        return durationText(seconds: seconds)
    }

    private static func durationText(seconds: TimeInterval) -> String? {
        guard seconds >= 0.05 else { return nil }
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        let total = Int(seconds.rounded())
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }

    private static func isConcreteLocalStatus(_ status: ChatStatusUpdate, action: String) -> Bool {
        guard !isReasoningOrThinkingStatus(status) else { return false }
        if action == "local_alpine" || action == "local_alpine_tool" {
            return true
        }
        let text = statusText(status)
        guard !text.isEmpty else { return false }
        let concreteMarkers = [
            "准备执行", "正在执行", "执行本地", "运行本地", "本地命令",
            "写入文件", "读取文件", "编辑文件", "删除文件", "创建文件",
            "安装本地", "更新本地", "工具调用", "命令",
            "executing", "calling", "running", "command", "tool"
        ]
        return concreteMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static let reasoningMarkupMarkers = [
        "<details", "</details>", "<think", "</think", "<thinking", "</thinking",
        "<reasoning", "</reasoning", "<thought", "</thought",
        "type=\"reasoning\"", "type='reasoning'",
        "思考中", "正在思考", "思考下一步", "分析下一步",
        "正在检查下一步", "检查下一步", "整理回答",
        "thinking", "reasoning", "thought"
    ]

    private static func isReasoningOrThinkingStatus(_ status: ChatStatusUpdate) -> Bool {
        let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let text = statusText(status)
        if action.contains("reason")
            || action.contains("think")
            || action.contains("thought") {
            return true
        }
        return reasoningMarkupMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func statusText(_ status: ChatStatusUpdate) -> String {
        [
            status.action,
            status.status,
            status.description,
            status.query,
            status.queries.joined(separator: " ")
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func statusGroupingSubject(for status: ChatStatusUpdate) -> String {
        let queryParts = ([status.query].compactMap { $0 } + status.queries)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if !queryParts.isEmpty {
            return "query:\(queryParts.joined(separator: "|"))"
        }

        let urlParts = status.urls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if !urlParts.isEmpty {
            return "url:\(urlParts.joined(separator: "|"))"
        }

        let itemLinks = status.items.compactMap { item -> String? in
            let value = item.link?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return value.isEmpty ? nil : value
        }
        if !itemLinks.isEmpty {
            return "item:\(itemLinks.joined(separator: "|"))"
        }

        return ""
    }

    private static func statusGroupingStepKey(for status: ChatStatusUpdate) -> String {
        var key = status.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        for suffix in [
            ".start",
            ".running",
            ".in_progress",
            ".waiting",
            ".waiting_verification",
            ".verification_completed",
            ".reading_results",
            ".success",
            ".completed",
            ".failed",
            ".error"
        ] where key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
            break
        }
        return key
    }

    private static func collapsedStatusGroups(
        from statusHistory: [ChatStatusUpdate],
        include: (ChatStatusUpdate, String) -> Bool
    ) -> [CollapsedStatusGroup] {
        var groups: [CollapsedStatusGroup] = []
        var currentGroup: CollapsedStatusGroup?

        for (index, status) in statusHistory.enumerated() {
            guard status.hidden != true else { continue }
            guard !isReasoningOrThinkingStatus(status) else { continue }

            let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard include(status, action) else { continue }

            let stepKey = statusGroupingStepKey(for: status)
            let subject = statusGroupingSubject(for: status)
            if var group = currentGroup,
               group.action == action,
               group.stepKey == stepKey {
                if !group.subject.isEmpty, !subject.isEmpty, group.subject != subject {
                    groups.append(group)
                    currentGroup = CollapsedStatusGroup(
                        startIndex: index,
                        action: action,
                        stepKey: stepKey,
                        subject: subject,
                        statuses: [status]
                    )
                    continue
                }

                if group.subject.isEmpty, !subject.isEmpty {
                    group.subject = subject
                }
                group.statuses.append(status)
                currentGroup = group
            } else {
                if let group = currentGroup {
                    groups.append(group)
                }
                currentGroup = CollapsedStatusGroup(
                    startIndex: index,
                    action: action,
                    stepKey: stepKey,
                    subject: subject,
                    statuses: [status]
                )
            }
        }

        if let group = currentGroup {
            groups.append(group)
        }

        return groups
    }

    private static func statusDetail(
        for statuses: [ChatStatusUpdate],
        fallbackTitle: String
    ) -> String {
        for status in statuses.reversed() {
            if let query = status.query?.trimmingCharacters(in: .whitespacesAndNewlines),
               !query.isEmpty {
                return query
            }
            if let description = status.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                return description
            }
            if let value = status.status?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return fallbackTitle
    }

    private static func statusPreviewText(for statuses: [ChatStatusUpdate]) -> String {
        for status in statuses.reversed() {
            let preview = statusPreview(status)
            if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return preview
            }
        }
        return ""
    }

    private static func statusThumbnailReference(
        for statuses: [ChatStatusUpdate],
        action: String,
        officePreviewReferences: [String],
        generatedImageFiles: [ChatMessageFile]
    ) -> String? {
        for status in statuses.reversed() {
            if let reference = statusThumbnailReference(
                for: status,
                action: action,
                officePreviewReferences: officePreviewReferences
            ) {
                return reference
            }
        }
        if action.contains("image_generation") {
            return generatedImageFiles
                .reversed()
                .compactMap(Self.imageReference(for:))
                .first
        }
        return nil
    }

    private static func statusOpenURL(
        for statuses: [ChatStatusUpdate],
        action: String
    ) -> String? {
        for status in statuses.reversed() {
            if let url = statusOpenURL(for: status, action: action) {
                return url
            }
        }
        return nil
    }

    private static func title(for status: ChatStatusUpdate, action: String) -> String {
        let description = status.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let step = status.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if step.contains("browser.open") || step.contains("browser.navigate") { return "打开网页" }
        if step.contains("browser.search") { return status.query?.isEmpty == false ? "搜索 \(status.query!)" : "搜索网页" }
        if step.contains("browser.readable") || step.contains("browser.text") { return "查看网页内容" }
        if step.contains("browser.observe") || step.contains("browser.get_state") { return "观察网页状态" }
        if step.contains("browser.find_elements") { return "识别网页元素" }
        if step.contains("browser.click") { return "点击网页控件" }
        if step.contains("browser.type") { return "输入网页内容" }
        if step.contains("browser.hover") { return "悬停网页控件" }
        if step.contains("browser.scroll_and_collect") { return "滚动收集网页内容" }
        if step.contains("browser.scroll") { return "滚动网页" }
        if step.contains("browser.screenshot") { return "截取网页画面" }
        if step.contains("browser.wait_for_dom_stable") { return "等待网页加载稳定" }
        if step.contains("browser.wait_for_image") { return "等待网页生成结果" }
        if step.contains("browser.get_backbone") || step.contains("browser.get_page_info") { return "分析网页结构" }
        if step.contains("browser.execute_js") { return "执行网页脚本" }
        if step.contains("browser.fetch") { return "下载网页资源" }
        if step.contains("browser.new_tab") { return "打开新标签页" }
        if step.contains("browser.close_tab") { return "关闭标签页" }
        if step.contains("browser.list_tabs") { return "查看标签页" }
        if step.contains("browser.set_viewport") { return "调整浏览器视口" }
        if step.contains("browser.set_user_agent") { return "切换浏览器标识" }
        if step.contains("browser.get_cookies") { return "读取站点 Cookie" }
        if action.contains("readable") { return "读取搜索结果摘要" }
        if action.contains("local_alpine_agent") || action.contains("local_alpine_tool") {
            if description.contains("重新请求") { return "准备下一步" }
            if description.contains("整理回答") { return "整理本地输出" }
            if description.contains("思考下一步") { return "分析下一步" }
            if description.contains("准备执行") { return "准备执行本地命令" }
            let cleaned = description.trimmingCharacters(in: CharacterSet(charactersIn: ".。… "))
            return cleaned.isEmpty ? "运行本地工具" : cleaned
        }
        if action.contains("local_office_agent") {
            let cleaned = description.trimmingCharacters(in: CharacterSet(charactersIn: ".。… "))
            return cleaned.isEmpty ? "生成 Office 文件" : cleaned
        }
        if action.contains("web_search") || action.contains("browser_web_search") {
            if description.contains("读取") || description.lowercased().contains("read") {
                return "读取搜索结果摘要"
            }
            return status.query?.isEmpty == false ? "搜索 \(status.query!)" : "搜索网页"
        }
        if action.contains("image_generation") { return "生成图片" }
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

    private static func statusThumbnailReference(
        for status: ChatStatusUpdate,
        action: String,
        officePreviewReferences: [String]
    ) -> String? {
        if action.contains("local_office_agent"),
           let reference = officePreviewReferences.first {
            return reference
        }
        if action.contains("web_search")
            || action.contains("browser_web_search")
            || action.contains("get_readable")
            || action.contains("readable") {
            if let thumbnail = status.items.compactMap({ item in
                let value = item.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }).first {
                return thumbnail
            }
            if let url = statusOpenURL(for: status, action: action) {
                return agentToolWebPreviewReference(for: url)
            }
        }
        if action.contains("image_generation") {
            if let thumbnail = status.items.compactMap({ item in
                let candidates = [
                    item.thumbnailURL,
                    item.link
                ]
                return candidates
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { value in
                        value.hasPrefix("data:image/")
                            || isImagePath(value)
                            || (URL(string: value)?.scheme?.lowercased()).map { ["http", "https", "file"].contains($0) } == true
                    }
            }).first {
                return thumbnail
            }
            if let url = status.urls
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { value in
                    value.hasPrefix("data:image/")
                        || isImagePath(value)
                        || (URL(string: value)?.scheme?.lowercased()).map { ["http", "https", "file"].contains($0) } == true
                }) {
                return url
            }
        }
        return nil
    }

    private static func statusOpenURL(for status: ChatStatusUpdate, action: String) -> String? {
        guard action.contains("web_search")
                || action.contains("browser_web_search")
                || action.contains("get_readable")
                || action.contains("readable") else {
            return nil
        }
        let candidates = status.items.compactMap(\.link) + status.urls
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { isHTTPURLString($0) }
    }

    private static func toolCallThumbnailReference(
        for call: LocalAlpineToolCall,
        file: LocalAlpineWrittenFile?
    ) -> String? {
        if let imageFilePath = call.imageFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !imageFilePath.isEmpty {
            return imageFilePath
        }
        if let file,
           isImagePath(file.path) {
            return file.path
        }
        let imagePath = call.filePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: isImagePath(_:))
        if let imagePath {
            return imagePath
        }
        if let browserURL = call.browserURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           let reference = webThumbnailReference(for: browserURL) {
            return reference
        }
        if let outputURL = localWebPreviewTarget(in: call.outputPreview),
           let reference = webThumbnailReference(for: outputURL) {
            return reference
        }
        if let outputTarget = localPreviewTarget(in: call.outputPreview),
           let reference = webThumbnailReference(for: outputTarget) {
            return reference
        }
        if let detailURL = localWebPreviewTarget(in: call.displayDetail),
           let reference = webThumbnailReference(for: detailURL) {
            return reference
        }
        if let detailTarget = localPreviewTarget(in: call.displayDetail),
           let reference = webThumbnailReference(for: detailTarget) {
            return reference
        }
        return call.filePaths
            .compactMap { webThumbnailReference(for: $0) }
            .first
    }

    private static func webThumbnailReference(for target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            let extensionName = url.pathExtension.lowercased()
            guard !["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"].contains(extensionName) else {
                return nil
            }
            return agentToolWebPreviewReference(for: trimmed)
        }

        let normalized = normalizedLocalPreviewPath(trimmed) ?? trimmed
        let extensionName = (normalized as NSString).pathExtension.lowercased()
        guard ["html", "htm", "xhtml", "svg"].contains(extensionName)
                || normalized.lowercased().hasPrefix("iexa://") else {
            return nil
        }
        return agentToolWebPreviewReference(for: normalized)
    }

    private static func toolCallPreviewOpenTarget(
        for call: LocalAlpineToolCall,
        file: LocalAlpineWrittenFile?
    ) -> String? {
        let normalizedToolName = call.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        if let browserURL = call.browserURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           let normalized = normalizedPreviewTarget(browserURL) {
            return normalized
        }
        if let imageFilePath = call.imageFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           let normalized = normalizedPreviewTarget(imageFilePath) {
            return normalized
        }
        if isDirectLocalPreviewToolName(normalizedToolName),
           let filePath = file?.path.trimmingCharacters(in: .whitespacesAndNewlines),
           let normalized = normalizedLocalPreviewPath(filePath) {
            return normalized
        }
        if let outputURL = localWebPreviewTarget(in: call.outputPreview) {
            return outputURL
        }
        if let outputLocalTarget = localPreviewTarget(in: call.outputPreview) {
            return outputLocalTarget
        }
        if let detailURL = localWebPreviewTarget(in: call.displayDetail) {
            return detailURL
        }
        if let detailLocalTarget = localPreviewTarget(in: call.displayDetail) {
            return detailLocalTarget
        }
        if call.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return nil
        }
        guard !["shell_execute", "bash", "shell", "sh", "run", "command", "exec"].contains(normalizedToolName) else {
            return nil
        }
        guard isDirectLocalPreviewToolName(normalizedToolName) else {
            return nil
        }
        return call.filePaths
            .compactMap(normalizedLocalPreviewPath(_:))
            .first
    }

    private static func isDirectLocalPreviewToolName(_ toolName: String) -> Bool {
        switch toolName {
        case "iexa_open", "open_preview", "browser.open", "browser_open", "browser.navigate", "browser_navigate", "browser.navigate_url":
            return true
        default:
            return false
        }
    }

    static func localWebPreviewTarget(in text: String?) -> String? {
        guard let text,
              let raw = firstRegexMatch(
                pattern: #"https?://(?:(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0)|\[[0-9a-f:]+\])(?::\d+)?[^\s"'`<>\[\]{}]*"#,
                in: text
              ),
              let normalized = normalizedPreviewTarget(raw),
              var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else {
            return nil
        }
        if host == "0.0.0.0" {
            components.host = "127.0.0.1"
        } else if host != "localhost"
                    && !host.hasPrefix("127.")
                    && host != "::1" {
            return nil
        }
        return components.string ?? normalized
    }

    static func localPreviewTarget(in text: String?) -> String? {
        guard let text else { return nil }
        let patterns = [
            #"iexa://[^\s"'`<>()\[\]{}]+"#,
            #"file://[^\s"'`<>()\[\]{}]+"#,
            #"/mnt/iexa/[^\s"'`<>()\[\]{}]+"#,
            #"/tmp/[^\s"'`<>()\[\]{}]+"#,
            #"/var/[^\s"'`<>()\[\]{}]+"#
        ]
        for pattern in patterns {
            if let raw = firstRegexMatch(pattern: pattern, in: text),
               let normalized = normalizedPreviewTarget(raw),
               isPreviewableLocalResource(normalized) {
                return normalized
            }
        }
        return nil
    }

    static func normalizedPreviewTarget(_ value: String?) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            return nil
        }

        if let httpURL = firstRegexMatch(
            pattern: #"https?://[^\s"'`<>()\[\]{}]+"#,
            in: trimmed
        ) {
            return trimmedPreviewURLCandidate(httpURL)
        }
        if let workspacePath = firstRegexMatch(
            pattern: #"/mnt/iexa/[^\s"'`<>()\[\]{}]+"#,
            in: trimmed
        ) {
            return trimmedPreviewURLCandidate(workspacePath)
        }

        trimmed = trimmedPreviewURLCandidate(trimmed)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("iexa://") || lower.hasPrefix("file://") {
            return trimmed
        }
        if trimmed.hasPrefix("/mnt/iexa/") || trimmed.hasPrefix("/tmp/") || trimmed.hasPrefix("/var/") {
            return trimmed
        }
        if (trimmed.hasPrefix("./") || trimmed.hasPrefix("../"))
            && !trimmed.contains(" ")
            && !trimmed.contains("\t") {
            return trimmed
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        if !ext.isEmpty && !trimmed.contains(" ") && !trimmed.contains("\t") {
            return trimmed
        }
        return nil
    }

    private static func isPreviewableLocalResource(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return false
        }
        if lower.hasPrefix("iexa://") || lower.hasPrefix("file://") {
            return true
        }
        if value.hasPrefix("/mnt/iexa/")
            || value.hasPrefix("/tmp/")
            || value.hasPrefix("/var/") {
            let ext = (value as NSString).pathExtension.lowercased()
            return [
                "html", "htm", "svg",
                "png", "jpg", "jpeg", "gif", "webp", "heic",
                "pdf", "md", "txt", "csv",
                "mp3", "wav", "m4a", "mp4", "mov", "webm"
            ].contains(ext)
        }
        return false
    }

    private static func trimmedPreviewURLCandidate(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingMarkdownOrPunctuation = CharacterSet(charactersIn: "\"'`*_~.,;:!?)[]{}<>，。！？；：、）】》」』")
        while let scalar = candidate.unicodeScalars.last,
              trailingMarkdownOrPunctuation.contains(scalar) {
            candidate.removeLast()
        }
        return candidate
    }

    private static func normalizedLocalPreviewPath(_ value: String?) -> String? {
        guard let normalized = normalizedPreviewTarget(value) else {
            return nil
        }
        let lower = normalized.lowercased()
        guard !lower.hasPrefix("http://"),
              !lower.hasPrefix("https://"),
              !lower.hasPrefix("iexa://"),
              !lower.hasPrefix("file://") else {
            return nil
        }
        if normalized.hasPrefix("/mnt/iexa/")
            || normalized.hasPrefix("/tmp/")
            || normalized.hasPrefix("/var/")
            || normalized.hasPrefix("./")
            || normalized.hasPrefix("../") {
            return normalized
        }
        guard !normalized.contains(" "),
              !normalized.contains("\t"),
              !normalized.contains("\n"),
              !normalized.contains("\r"),
              !(normalized as NSString).pathExtension.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func firstRegexMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return nsText.substring(with: match.range)
    }

    private static func isHTTPURLString(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private static func isImagePath(_ value: String) -> Bool {
        let ext = (value as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "avif"].contains(ext)
    }

    private static func officePreviewReferences(from files: [ChatMessageFile]) -> [String] {
        let hasOfficeDocument = files.contains(where: Self.isOfficeDocumentFile)
        guard hasOfficeDocument else { return [] }
        return files
            .filter(Self.isOfficePreviewImageFile)
            .compactMap(Self.imageReference)
    }

    private static func isOfficeDocumentFile(_ file: ChatMessageFile) -> Bool {
        let name = (file.name ?? file.url ?? "").lowercased()
        let contentType = (file.contentType ?? "").lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if ["xlsx", "xls", "pptx", "ppt", "docx", "doc", "pdf"].contains(ext) {
            return true
        }
        return contentType.contains("spreadsheetml")
            || contentType.contains("presentationml")
            || contentType.contains("wordprocessingml")
            || contentType == "application/pdf"
            || contentType.contains("officedocument")
    }

    private static func isOfficePreviewImageFile(_ file: ChatMessageFile) -> Bool {
        guard isImageFile(file) else { return false }
        let name = (file.name ?? file.url ?? "").lowercased()
        return name.contains("preview-")
            || name.contains("slide-")
            || name.contains("/office agent/")
            || name.contains("office%20agent")
    }

    private static func isImageFile(_ file: ChatMessageFile) -> Bool {
        if file.contentType?.lowercased().hasPrefix("image/") == true {
            return true
        }
        let name = (file.name ?? file.url ?? "").lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].contains(ext)
    }

    private static func imageReference(for file: ChatMessageFile) -> String? {
        if let displayReference = preferredDisplayImageReference(for: file.displayURL) {
            return displayReference
        }
        if let localAlpineReference = [file.url, file.displayURL]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.lowercased().hasPrefix("local-alpine:") }) {
            return localAlpineReference
        }
        return [file.displayURL, file.url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first {
                !$0.isEmpty && !$0.lowercased().hasPrefix("local-inline-image:")
            }
    }

    private static func preferredDisplayImageReference(for value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:image/") {
            guard trimmed.utf8.count <= 7_000_000 else { return nil }
            return trimmed
        }
        guard trimmed.utf8.count <= 4_096 else { return nil }
        if trimmed.hasPrefix("file://")
            || trimmed.hasPrefix("http://")
            || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return nil
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
        if let preferred = preferredDisplayTitle(for: call, fallbackTitle: display.title) {
            return call.failed ? "\(preferred)失败" : preferred
        }
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
        case "create_file", "create_files", "new_file", "touch":
            return fileName.map { "创建 \($0)" } ?? display.title
        case "create_directory", "create_dir", "make_directory", "make_dir", "mkdir":
            return fileName.map { "创建目录 \($0)" } ?? display.title
        case "write_files", "write_file", "write", "file_write":
            return fileName.map { "写入 \($0)" } ?? display.title
        case "delete_file", "delete_files", "remove_file", "remove_files", "delete", "rm", "file_delete":
            return fileName.map { "删除 \($0)" } ?? display.title
        case "copy_file", "copy_files", "cp":
            return fileName.map { "复制 \($0)" } ?? display.title
        case "move_file", "move_files", "rename_file", "rename", "mv":
            return fileName.map { "移动 \($0)" } ?? display.title
        case "verify", "check":
            return fileName.map { "校验 \($0)" } ?? display.title
        case "verify_absent", "verify_missing", "ensure_absent":
            return fileName.map { "校验删除 \($0)" } ?? display.title
        case "memory_write":
            return display.title
        case "memory_get":
            return display.title
        case "iexa_open", "open_preview":
            return fileName.map { "打开 \($0)" } ?? display.title
        case "command", "shell", "bash", "exec", "shell_execute":
            if let command = call.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               !command.isEmpty {
                return commandStepTitle(for: command, failed: call.failed)
            }
            return call.failed ? "\(display.title)失败" : display.title
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
            return display.title
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

    private static func preferredDisplayTitle(for call: LocalAlpineToolCall, fallbackTitle: String) -> String? {
        let title = oneLinePreview(call.title, limit: 28)
        guard !title.isEmpty, title != fallbackTitle else { return nil }
        let lowerTitle = title.lowercased()
        let normalizedName = call.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let genericTitles = [
            "tool", "call", "function", "command", "shell", "execute", "run",
            "工具", "调用工具", "执行工具", "命令", "执行命令"
        ]
        guard !genericTitles.contains(lowerTitle),
              lowerTitle != normalizedName,
              lowerTitle != normalizedName.replacingOccurrences(of: "_", with: " "),
              title.range(of: #"[{}\[\]<>`]"#, options: .regularExpression) == nil else {
            return nil
        }
        return title
    }

    private static func commandStepTitle(for command: String, failed: Bool) -> String {
        let normalized = command
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let title: String
        if normalized.range(of: #"(^|[;&|]\s*)(?:ls|find|pwd\s*&&\s*(?:ls|find)|du|stat)\b"#, options: .regularExpression) != nil {
            title = "列出目录"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:cat|sed|awk|head|tail|less|more)\b"#, options: .regularExpression) != nil {
            title = "读取文件"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:grep|rg|ag)\b"#, options: .regularExpression) != nil {
            title = "搜索文本"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:rm|rmdir)\b"#, options: .regularExpression) != nil {
            title = "删除文件"
        } else if normalized.range(of: #"(^|[;&|]\s*)mkdir\b"#, options: .regularExpression) != nil {
            title = "创建目录"
        } else if normalized.range(of: #"(^|[;&|]\s*)touch\b"#, options: .regularExpression) != nil {
            title = "创建文件"
        } else if normalized.range(of: #"(^|[;&|]\s*)cp\b"#, options: .regularExpression) != nil {
            title = "复制文件"
        } else if normalized.range(of: #"(^|[;&|]\s*)mv\b"#, options: .regularExpression) != nil {
            title = "移动文件"
        } else if normalized.contains("git diff --check")
                    || normalized.contains("swiftlint")
                    || normalized.contains("eslint")
                    || normalized.contains("tsc --noemit")
                    || normalized.range(of: #"(^|[;&|]\s*)(?:test|\[)\b"#, options: .regularExpression) != nil {
            title = "校验"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:pytest|python3?\s+-m\s+pytest|npm\s+test|pnpm\s+test|yarn\s+test|go\s+test|cargo\s+test)\b"#, options: .regularExpression) != nil {
            title = "测试"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:swift|xcodebuild|make|cmake|gcc|g\+\+|clang|cargo|go|npm|pnpm|yarn)\s+(?:build|compile|archive|run\s+build)\b"#, options: .regularExpression) != nil {
            title = "编译"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:apk|apt|brew|pip3?|npm|pnpm|yarn)\s+(?:add|install|i)\b"#, options: .regularExpression) != nil {
            title = "安装依赖"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:curl|wget)\s+"#, options: .regularExpression) != nil {
            title = "网络请求"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:ping|fping)\b"#, options: .regularExpression) != nil {
            title = "网络延迟"
        } else if normalized.range(of: #"(^|[;&|]\s*)(?:python3?|node|deno|bun|ruby|php|lua|go\s+run|cargo\s+run|swift\s+run)\b"#, options: .regularExpression) != nil {
            title = "运行脚本"
        } else {
            title = "运行命令"
        }
        return failed ? "\(title)失败" : title
    }

    static func isActivityMessage(_ message: ChatMessage) -> Bool {
        if message.metadata?["iexa_local_alpine_result"] == "true"
            || message.metadata?["iexa_local_alpine_tool_calls"] != nil
            || message.metadata?["iexa_local_browser_tool"] == "true"
            || message.metadata?["iexa_local_native_tool_parent"] == "true"
            || message.metadata?["iexa_local_native_hidden_tool_parent"] == "true"
            || message.content.hasPrefix("Local Alpine 执行结果")
            || message.model == "Local Alpine"
            || message.model == "Local Alpine Agent" {
            return true
        }
        return message.statusHistory.contains { status in
            let action = status.action?.lowercased() ?? ""
            if action == "local_alpine"
                || action == "local_alpine_agent"
                || action == "local_alpine_tool" {
                return Self.isConcreteLocalStatus(status, action: action)
            }
            guard !Self.isReasoningOrThinkingStatus(status) else { return false }
            return action.contains("web_search")
                || action.contains("browser_web_search")
                || action == "browser_use"
                || action.hasPrefix("browser.")
                || action.contains("code_interpreter")
                || action.contains("image_generation")
                || action.contains("get_readable")
                || action.contains("readable")
                || action.contains("local_native_tool")
                || action.contains("local_office_agent")
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
        if message.metadata?["iexa_local_native_continuation"] == "true"
            || message.metadata?["iexa_local_alpine_final_summary"] != nil
            || message.metadata?["iexa_local_alpine_continuation"] == "true"
            || message.metadata?["iexa_local_alpine_missing_tool_correction"] != nil
            || message.metadata?["iexa_local_alpine_hidden_correction_parent"] == "true" {
            return nil
        }
        guard Self.isActivityMessage(message) else {
            return nil
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let metadata = message.metadata
        let writtenFiles = LocalAlpineWrittenFile.decodeMetadata(metadata?["iexa_local_alpine_written_files"])
        let commandResults = LocalAlpineAgentCommandResult.decodeMetadata(metadata?["iexa_local_alpine_command_results"])
        let persistedToolCalls = LocalAlpineToolCall.decodeMetadata(metadata?["iexa_local_alpine_tool_calls"])
        let mergedToolCalls = Self.mergedToolCalls(persisted: persistedToolCalls, live: liveToolCalls)
        let toolCalls = Self.uiToolCalls(mergedToolCalls)
        let uiCommandResults = Self.uiCommandResults(commandResults)
        let statusHistory = liveStatus.map { message.statusHistory + [$0] } ?? message.statusHistory
        let officePreviewReferences = Self.officePreviewReferences(from: message.files)
        let officeDocumentFiles = message.files.filter(Self.isOfficeDocumentFile)
        let generatedImageFiles = message.files.filter { file in
            Self.isImageFile(file) && !file.isGeneratedImageFailurePlaceholder
        }
        let parsed = ParsedLocalAlpineResult(
            content: Self.lightweightActivityParseContent(
                message.content,
                writtenFiles: writtenFiles,
                commandResults: uiCommandResults,
                toolCalls: toolCalls
            ),
            metadata: metadata
        )
        let visibleCommands = uiCommandResults.filter {
            $0.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "write_files"
        }
        let visibleFullCommands = commandResults.filter {
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
        self.commandResults = uiCommandResults
        self.toolCalls = toolCalls
        self.steps = Self.steps(
            toolCalls: toolCalls,
            writtenFiles: writtenFiles,
            commandResults: visibleCommands,
            fullToolCalls: mergedToolCalls,
            fullCommandResults: visibleFullCommands,
            statusHistory: statusHistory,
            officePreviewReferences: officePreviewReferences,
            officeDocumentFiles: officeDocumentFiles,
            generatedImageFiles: generatedImageFiles
        )

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        if elapsedMs >= 8 {
            let duration = String(format: "%.1f", elapsedMs)
            DiagnosticLogManager.shared.warning(
                "AgentActivity parse \(duration)ms tools=\(toolCalls.count) files=\(writtenFiles.count) commands=\(commandResults.count) steps=\(self.steps.count)",
                category: "Performance"
            )
        }
    }

    private static func uiCommandResults(_ results: [LocalAlpineAgentCommandResult]) -> [LocalAlpineAgentCommandResult] {
        results.map { result in
            LocalAlpineAgentCommandResult(
                command: result.command,
                cwd: result.cwd,
                exitCode: result.exitCode,
                outputPreview: clippedUIPreview(result.outputPreview),
                outputReference: result.outputReference,
                outputByteCount: result.outputByteCount,
                outputLineCount: result.outputLineCount
            )
        }
    }

    private static func uiToolCalls(_ calls: [LocalAlpineToolCall]) -> [LocalAlpineToolCall] {
        calls.filter { !isReasoningOrMarkupToolCall($0) }.map { call in
            LocalAlpineToolCall(
                id: call.id,
                runId: call.runId,
                name: call.name,
                phase: call.phase,
                title: call.title,
                detail: call.detail,
                cwd: call.cwd,
                command: call.command,
                exitCode: call.exitCode,
                outputPreview: call.outputPreview.map { Self.clippedUIPreview($0) },
                outputReference: call.outputReference,
                outputByteCount: call.outputByteCount,
                outputLineCount: call.outputLineCount,
                filePaths: call.filePaths,
                lineDelta: call.lineDelta,
                startedAtMs: call.startedAtMs,
                completedAtMs: call.completedAtMs,
                browserURL: call.browserURL,
                imageFilePath: call.imageFilePath,
                failed: call.failed,
                contentOffset: call.contentOffset
            )
        }
    }

    private static func isReasoningOrMarkupToolCall(_ call: LocalAlpineToolCall) -> Bool {
        let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = call.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["thinking", "think", "reasoning", "reason", "thought"].contains(name)
            || ["思考", "思考中", "分析", "分析中"].contains(title) {
            return true
        }
        let detail = call.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = call.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = "\(title) \(detail.prefix(260)) \(output.prefix(260))"
        return reasoningMarkupMarkers.contains {
            text.localizedCaseInsensitiveContains($0)
        }
    }

    private static func clippedUIPreview(_ text: String) -> String {
        guard text.count > uiOutputPreviewLimit else { return text }
        return String(text.prefix(uiOutputPreviewLimit)) + "\n...（预览已截断，完整内容已保留在模型上下文/本地结果中）"
    }

    private static func lightweightActivityParseContent(
        _ content: String,
        writtenFiles: [LocalAlpineWrittenFile],
        commandResults: [LocalAlpineAgentCommandResult],
        toolCalls: [LocalAlpineToolCall]
    ) -> String {
        guard writtenFiles.isEmpty,
              commandResults.isEmpty,
              toolCalls.isEmpty else {
            return ""
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 12_000 else { return "" }
        return trimmed
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
                let key: String = {
                    switch step.kind {
                    case .tool:
                        return step.id
                    case .file:
                        return step.file?.path ?? step.id
                    case .command:
                        return step.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? step.id
                    case .status:
                        return "\(item.id)::\(step.id)"
                    }
                }()
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

private struct AgentActivityCacheEntry {
    let signature: Int
    let item: AgentActivityItem?
}

private final class AgentActivityItemCache {
    private var entries: [String: AgentActivityCacheEntry] = [:]

    func lookup(messageId: String, signature: Int) -> AgentActivityCacheEntry? {
        guard let entry = entries[messageId],
              entry.signature == signature else {
            return nil
        }
        return entry
    }

    func store(messageId: String, signature: Int, item: AgentActivityItem?) {
        entries[messageId] = AgentActivityCacheEntry(signature: signature, item: item)
        if entries.count > 120 {
            entries.removeAll(keepingCapacity: true)
            entries[messageId] = AgentActivityCacheEntry(signature: signature, item: item)
        }
    }
}

private struct TranscriptRenderSnapshot {
    let signature: Int
    let messages: [ChatMessage]
    let ids: [String]
    let turnGroups: [TranscriptMessageTurnGroup]
    let indexByMessageId: [String: Int]
    let lastTurnGroupId: String?
    let lastVisibleMessageId: String?
    let latestUserMessageId: String?
    let localAlpineAnyFinalSummaryAfter: Set<String>
    let localAlpineVisibleFinalSummaryAfter: Set<String>
    let mergedActivityAnchorIds: Set<String>
}

private struct TranscriptMessageTurnGroup: Identifiable {
    let id: String
    let messages: [ChatMessage]

    var containsUserMessage: Bool {
        messages.contains { $0.role == .user }
    }
}

private final class TranscriptMessagesCache {
    private var snapshot: TranscriptRenderSnapshot?

    func lookup(signature: Int) -> TranscriptRenderSnapshot? {
        guard snapshot?.signature == signature else {
            return nil
        }
        return snapshot
    }

    func store(_ snapshot: TranscriptRenderSnapshot) {
        self.snapshot = snapshot
    }
}

private final class AssistantVisibleTextCache {
    private var entries: [String: (signature: Int, value: String)] = [:]

    func lookup(messageId: String, signature: Int) -> String? {
        guard let entry = entries[messageId], entry.signature == signature else {
            return nil
        }
        return entry.value
    }

    func store(messageId: String, signature: Int, value: String) {
        entries[messageId] = (signature, value)
        if entries.count > 160 {
            entries.removeAll(keepingCapacity: true)
            entries[messageId] = (signature, value)
        }
    }
}

private struct CurrentTurnActivityItemsCacheEntry {
    let signature: Int
    let items: [AgentActivityItem]
}

private final class CurrentTurnActivityItemsCache {
    private var entries: [String: CurrentTurnActivityItemsCacheEntry] = [:]

    func lookup(key: String, signature: Int) -> [AgentActivityItem]? {
        guard let entry = entries[key], entry.signature == signature else {
            return nil
        }
        return entry.items
    }

    func store(key: String, signature: Int, items: [AgentActivityItem]) {
        entries[key] = CurrentTurnActivityItemsCacheEntry(signature: signature, items: items)
        if entries.count > 8 {
            entries.removeAll(keepingCapacity: true)
            entries[key] = CurrentTurnActivityItemsCacheEntry(signature: signature, items: items)
        }
    }
}

private struct CurrentTurnMergedActivityCacheEntry {
    let signature: Int
    let item: AgentActivityItem?
}

private final class CurrentTurnMergedActivityCache {
    private var entries: [String: CurrentTurnMergedActivityCacheEntry] = [:]

    func lookup(key: String, signature: Int) -> AgentActivityItem?? {
        guard let entry = entries[key], entry.signature == signature else {
            return nil
        }
        return entry.item
    }

    func store(key: String, signature: Int, item: AgentActivityItem?) {
        entries[key] = CurrentTurnMergedActivityCacheEntry(signature: signature, item: item)
        if entries.count > 8 {
            entries.removeAll(keepingCapacity: true)
            entries[key] = CurrentTurnMergedActivityCacheEntry(signature: signature, item: item)
        }
    }
}

private struct AssistantRenderableContentCacheEntry {
    let signature: Int
    let value: String
}

private final class AssistantRenderableContentCache {
    private var entries: [String: AssistantRenderableContentCacheEntry] = [:]

    func lookup(key: String, signature: Int) -> String? {
        guard let entry = entries[key], entry.signature == signature else {
            return nil
        }
        return entry.value
    }

    func store(key: String, signature: Int, value: String) {
        entries[key] = AssistantRenderableContentCacheEntry(signature: signature, value: value)
        if entries.count > 220 {
            entries.removeAll(keepingCapacity: true)
            entries[key] = AssistantRenderableContentCacheEntry(signature: signature, value: value)
        }
    }
}

private final class ChatScrollRuntimeState {
    var lastScrollOffset: CGFloat = 0
    var isNearBottom: Bool = true
}

struct ChatDetailView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    private let logger = Logger(subsystem: "com.openui", category: "ChatDetailView")

    private let initialConversationId: String?
    private let onNewChat: (() -> Void)?
    @State private var viewModel: ChatViewModel
    @State private var agentActivityCache = AgentActivityItemCache()
    @State private var transcriptCache = TranscriptMessagesCache()
    @State private var assistantVisibleTextCache = AssistantVisibleTextCache()
    @State private var currentTurnActivityCache = CurrentTurnActivityItemsCache()
    @State private var currentTurnMergedActivityCache = CurrentTurnMergedActivityCache()
    @State private var scrollRuntime = ChatScrollRuntimeState()

    // MARK: Model selector sheet
    @State private var isShowingModelSelectorSheet = false
    @State private var isShowingChatParams = false
    @AppStorage("chatWebSearchEnabled") private var chatWebSearchEnabled = false
    @AppStorage("localAlpineToolPreviewEnabled") private var localAlpineToolPreviewEnabled = true
    @State private var editingModelDetail: ModelDetail? = nil
    @State private var isLoadingModelDetail = false

    // MARK: Scroll state (iOS 18 ScrollPosition API)
    /// iOS 18+ declarative scroll position. Used with `.scrollPosition($scrollPosition)`
    /// to drive programmatic scrolling via `scrollTo(edge:)`.
    @State private var scrollPosition: ScrollPosition = .init()
    /// True when the user has manually scrolled away from the bottom.
    @State private var isScrolledUp = false
    // Last known contentOffset.y lives in `scrollRuntime` so scroll tracking
    // does not invalidate the entire chat view on every few pixels of drag.
    /// Cached distance from the scroll viewport bottom to the content bottom.
    /// Tracks "near bottom" state so IME/layout changes can re-pin only when
    /// the user was already following the latest message.
    @State private var distanceFromBottom: CGFloat = 0
    /// Cached scroll content height — updated via a separate onScrollGeometryChange.
    @State private var viewState_contentHeight: CGFloat = 0
    /// Cached scroll container height — updated via a separate onScrollGeometryChange.
    @State private var viewState_containerHeight: CGFloat = 0
    /// Keeps a newly sent turn anchored at the top of the viewport until
    /// the user explicitly follows the bottom again.
    @State private var pinCurrentTurnStartForLatestTurn = false
    /// Stable user-message anchor for the currently pinned turn. Without this,
    /// assistant placeholders/tool rows appended after send can re-resolve the
    /// "current turn" and occasionally fall back to bottom pinning.
    @State private var pinnedCurrentTurnStartMessageId: String?
    /// Set when the user explicitly follows the bottom during streaming.
    /// This prevents the current-turn-start pin from pulling the transcript
    /// back upward when the stream finishes.
    @State private var userRequestedBottomFollowDuringStreaming = false
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
    @State private var agentFloatingActivitySnapshot: AgentActivityItem?
    @State private var agentFloatingFilePreview: LocalAlpineWrittenFilePreviewItem?
    @State private var agentFloatingStepPreview: AgentFloatingStepPreviewItem?
    @State private var agentFloatingLoadingPath: String?
    @State private var localAlpineLiveToolRenderRevision = 0
    @State private var automationBrowserLivePreviewReference: String?
    @State private var hideAgentFloatingBarForKeyboard = false
    @State private var suppressStaleAgentFloatingBarAfterKeyboard = false
    @State private var pendingNewAgentFloatingSnapshotAfterKeyboard: AgentActivityItem?
    @State private var agentFloatingKeyboardHideGeneration = 0

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

    private var currentTurnAgentActivityItems: [AgentActivityItem] {
        currentTurnAgentActivityItems(includeInactive: false)
    }

    private func currentTurnAgentActivityItems(includeInactive: Bool) -> [AgentActivityItem] {
        let messages = viewModel.messages
        let isLive = hasLiveAgentActivityState(in: messages)
        guard isLive || includeInactive else { return [] }
        guard let turnMessages = currentTurnAgentActivityMessages(in: messages) else { return [] }

        let cacheKey = includeInactive ? "current-turn-include-inactive" : "current-turn-live-only"
        let signature = currentTurnAgentActivitySignature(messages: turnMessages, includeInactive: includeInactive, isLive: isLive)
        if let cached = currentTurnActivityCache.lookup(key: cacheKey, signature: signature) {
            return cached
        }

        let items = turnMessages
            .compactMap { activityItem(for: $0) }
            .filter { $0.hasConcreteSteps || $0.isActive }
        currentTurnActivityCache.store(key: cacheKey, signature: signature, items: items)
        return items
    }

    private func currentTurnAgentActivityMessages(in messages: [ChatMessage]) -> ArraySlice<ChatMessage>? {
        guard !messages.isEmpty else { return nil }
        let lastUserIndex = messages.lastIndex(where: { $0.role == .user })
        let startIndex = lastUserIndex.map { messages.index(after: $0) } ?? messages.startIndex
        guard startIndex < messages.endIndex else { return nil }
        return messages[startIndex...]
    }

    private func currentTurnAgentActivitySignature(
        messages: ArraySlice<ChatMessage>,
        includeInactive: Bool,
        isLive: Bool
    ) -> Int {
        var signature = messages.count &* 31
        signature &+= includeInactive ? 17 : 5
        signature &+= isLive ? 29 : 11
        for message in messages {
            signature &+= agentActivityCacheSignature(for: message)
            signature &+= localAlpineLiveActivitySignature(for: message)
        }
        return signature
    }

    private func hasLiveAgentActivityState(in messages: [ChatMessage]? = nil) -> Bool {
        let messages = messages ?? viewModel.messages
        if viewModel.isStreaming || viewModel.streamingStore.isActive {
            return true
        }
        return messages.contains { message in
            isMessageVisuallyStreaming(message)
                || !viewModel.localAlpineLiveToolCalls(for: message.id).isEmpty
                || viewModel.localAlpineLiveToolStatus(for: message.id) != nil
        }
    }

    private func localAlpineLiveActivitySignature(for message: ChatMessage) -> Int {
        let liveToolCalls = viewModel.localAlpineLiveToolCalls(for: message.id)
        let liveStatus = viewModel.localAlpineLiveToolStatus(for: message.id)
        guard !liveToolCalls.isEmpty || liveStatus != nil else { return 0 }

        var signature = liveToolCalls.count &* 31
        for call in liveToolCalls.suffix(8) {
            signature &+= call.id.hashValue
            signature &+= call.name.hashValue
            signature &+= call.isRunning ? 13 : 3
            signature &+= call.failed ? 17 : 5
            signature &+= call.startedAtMs.hashValue
            signature &+= (call.completedAtMs ?? 0).hashValue
            signature &+= Self.lightweightTranscriptTextSignature(call.command ?? "")
            signature &+= Self.lightweightTranscriptTextSignature(call.outputPreview ?? "")
            signature &+= Self.lightweightTranscriptTextSignature(call.browserURL ?? "")
        }
        if let liveStatus {
            let statusFragments: [String?] = [
                liveStatus.action,
                liveStatus.status,
                liveStatus.description,
                liveStatus.query,
                liveStatus.queries.joined(separator: " ")
            ]
            let statusText = statusFragments
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            signature &+= Self.lightweightTranscriptTextSignature(statusText)
            signature &+= (liveStatus.done == true ? 23 : 7)
        }
        return signature
    }

    private struct TranscriptVisibilityContext {
        var anyFinalSummaryAfter: Set<String> = []
        var visibleFinalSummaryAfter: Set<String> = []
        var laterLocalAlpineTurnMessageAfter: Set<String> = []
        var mergedActivityAnchorIds: Set<String> = []
        var hiddenMergedActivityMessageIds: Set<String> = []
    }

    private var transcriptSnapshot: TranscriptRenderSnapshot {
        let messages = viewModel.messages
        let signature = transcriptRenderSignature(for: messages)
        if let cached = transcriptCache.lookup(signature: signature) {
            return cached
        }

        let context = transcriptVisibilityContext(for: messages)
        let visibleMessages = messages.filter { !shouldHideFromTranscript($0, context: context) }
        let turnGroups = Self.messageTurnGroups(from: visibleMessages)
        let snapshot = TranscriptRenderSnapshot(
            signature: signature,
            messages: visibleMessages,
            ids: visibleMessages.map(\.id),
            turnGroups: turnGroups,
            indexByMessageId: Dictionary(
                visibleMessages.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            lastTurnGroupId: turnGroups.last(where: { $0.containsUserMessage })?.id,
            lastVisibleMessageId: visibleMessages.last?.id,
            latestUserMessageId: visibleMessages.last(where: { $0.role == .user })?.id,
            localAlpineAnyFinalSummaryAfter: context.anyFinalSummaryAfter,
            localAlpineVisibleFinalSummaryAfter: context.visibleFinalSummaryAfter,
            mergedActivityAnchorIds: context.mergedActivityAnchorIds
        )
        transcriptCache.store(snapshot)
        return snapshot
    }

    private var transcriptMessages: [ChatMessage] {
        transcriptSnapshot.messages
    }

    private var transcriptMessageIds: [String] {
        transcriptSnapshot.ids
    }

    private func transcriptRenderSignature(for messages: [ChatMessage]) -> Int {
        var signature = messages.count &* 31
        signature &+= localAlpineLiveToolRenderRevision &* 41
        for message in messages {
            signature &+= message.id.hashValue
            signature &+= message.role.rawValue.hashValue
            signature &+= Self.lightweightTranscriptTextSignature(message.content)
            signature &+= message.isStreaming ? 17 : 5
            signature &+= message.model?.hashValue ?? 0
            signature &+= message.statusHistory.count &* 13
            if let latestStatus = message.statusHistory.last {
                signature &+= latestStatus.action?.hashValue ?? 0
                signature &+= Self.lightweightTranscriptTextSignature(latestStatus.description ?? "")
                signature &+= latestStatus.done == true ? 11 : 3
                signature &+= latestStatus.hidden == true ? 19 : 7
            }
            signature &+= message.files.count &* 17
            signature &+= Self.lightweightTranscriptTextSignature(message.error?.content ?? "")
            if let metadata = message.metadata {
                signature &+= metadata.count &* 19
                for key in Self.transcriptMetadataSignatureKeys {
                    guard let value = metadata[key] else { continue }
                    signature &+= key.hashValue
                    signature &+= value.isEmpty ? 0 : 1
                    signature &+= Self.lightweightTranscriptTextSignature(value)
                }
            }
        }
        return signature
    }

    private static func lightweightTranscriptTextSignature(
        _ text: String,
        sampleBytes: Int = 32
    ) -> Int {
        guard !text.isEmpty else { return 0 }
        var signature = text.utf8.count &* 17
        var head = 0
        for byte in text.utf8.prefix(sampleBytes) {
            head = (head &* 31) &+ Int(byte)
        }
        var tail = 0
        for byte in text.utf8.suffix(sampleBytes) {
            tail = (tail &* 31) &+ Int(byte)
        }
        signature &+= head
        signature &+= tail &* 7
        return signature
    }

    private static let transcriptMetadataSignatureKeys = [
        "iexa_local_native_result",
        "iexa_local_native_hidden_tool_parent",
        "iexa_local_alpine_result",
        "iexa_local_alpine_tool_calls",
        "iexa_local_alpine_command_results",
        "iexa_local_alpine_written_files",
        "iexa_local_alpine_final_summary",
        "iexa_local_alpine_mirrored_parent",
        "iexa_local_alpine_mirrored_result_id",
        "iexa_local_alpine_continuation",
        "iexa_local_alpine_auto_verify",
        "iexa_local_alpine_missing_tool_correction",
        "iexa_local_alpine_hidden_correction_parent",
        "iexa_local_alpine_hidden_tool_parent"
    ]

    private func transcriptVisibilityContext(for messages: [ChatMessage]) -> TranscriptVisibilityContext {
        var context = TranscriptVisibilityContext()
        var seenAnyFinalSummaryInTurn = false
        var seenVisibleFinalSummaryInTurn = false
        var seenLaterLocalAlpineTurnMessage = false

        for message in messages.reversed() {
            if message.role == .user {
                seenAnyFinalSummaryInTurn = false
                seenVisibleFinalSummaryInTurn = false
                seenLaterLocalAlpineTurnMessage = false
                continue
            }

            if seenAnyFinalSummaryInTurn {
                context.anyFinalSummaryAfter.insert(message.id)
            }
            if seenVisibleFinalSummaryInTurn {
                context.visibleFinalSummaryAfter.insert(message.id)
            }
            if seenLaterLocalAlpineTurnMessage {
                context.laterLocalAlpineTurnMessageAfter.insert(message.id)
            }

            let isFinalSummary = message.metadata?["iexa_local_alpine_final_summary"] != nil
            if isFinalSummary {
                seenAnyFinalSummaryInTurn = true
            }
            let hasFinalSummaryContent = isFinalSummary
                && (message.error != nil
                    || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasFinalSummaryContent {
                seenVisibleFinalSummaryInTurn = true
            }
            if isLocalAlpineResultMessage(message)
                || (isFinalSummary && (message.isStreaming || hasFinalSummaryContent)) {
                seenLaterLocalAlpineTurnMessage = true
            }
        }

        applyMergedActivityVisibility(to: &context, messages: messages)
        return context
    }

    private func applyMergedActivityVisibility(
        to context: inout TranscriptVisibilityContext,
        messages: [ChatMessage]
    ) {
        var turnMessages: [ChatMessage] = []

        func flushTurn() {
            defer { turnMessages.removeAll(keepingCapacity: true) }
            guard !turnMessages.isEmpty else { return }

            let activityMessages = turnMessages.filter { message in
                message.role == .assistant && hasRenderableAgentActivity(for: message)
            }
            guard !activityMessages.isEmpty else { return }

            let anchor = turnMessages.first { message in
                guard message.role == .assistant else { return false }
                return hasRenderableAgentActivity(for: message)
                    || !visibleAssistantTextAfterToolProtocolCleanup(for: message)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    || isMessageVisuallyStreaming(message)
            } ?? activityMessages[0]

            context.mergedActivityAnchorIds.insert(anchor.id)
            for message in activityMessages where message.id != anchor.id {
                context.hiddenMergedActivityMessageIds.insert(message.id)
            }
        }

        for message in messages {
            if message.role == .user {
                flushTurn()
            }
            turnMessages.append(message)
        }
        flushTurn()
    }

    private func agentActivity(for message: ChatMessage) -> AgentActivityItem? {
        if message.metadata?["iexa_local_alpine_final_summary"] != nil {
            return nil
        }
        if isLocalAlpineResultMessage(message) {
            return activityItem(for: message)
        }
        return activityItem(for: message)
    }

    private func activityItem(for message: ChatMessage) -> AgentActivityItem? {
        let liveToolCalls = viewModel.localAlpineLiveToolCalls(for: message.id)
        let liveStatus = viewModel.localAlpineLiveToolStatus(for: message.id)
        if !liveToolCalls.isEmpty || liveStatus != nil {
            return AgentActivityItem(
                message: message,
                liveToolCalls: liveToolCalls,
                liveStatus: liveStatus
            )
        }

        let signature = agentActivityCacheSignature(for: message)
        if let cached = agentActivityCache.lookup(messageId: message.id, signature: signature) {
            return cached.item
        }

        let item = AgentActivityItem(
            message: message,
            liveToolCalls: [],
            liveStatus: nil
        )
        agentActivityCache.store(messageId: message.id, signature: signature, item: item)
        return item
    }

    private func transcriptAgentActivity(
        for message: ChatMessage,
        isMergedAnchor: Bool
    ) -> AgentActivityItem? {
        guard message.role == .assistant else { return nil }
        if isMergedAnchor {
            let items = agentActivityItemsInTurn(containing: message)
            if let merged = AgentActivityItem.mergedTurn(
                id: "turn-\(message.id)",
                items: items
            ), merged.hasConcreteSteps {
                return merged
            }
        }
        return agentActivity(for: message)
    }

    private func agentActivityItemsInTurn(containing message: ChatMessage) -> [AgentActivityItem] {
        let messages = viewModel.messages
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else {
            return agentActivity(for: message).map { [$0] } ?? []
        }

        let start = messages[..<index]
            .lastIndex(where: { $0.role == .user })
            .map { messages.index(after: $0) }
            ?? messages.startIndex
        let end = messages[messages.index(after: index)...]
            .firstIndex(where: { $0.role == .user })
            ?? messages.endIndex

        return messages[start..<end]
            .compactMap { activityItem(for: $0) }
            .filter { $0.hasConcreteSteps || $0.isActive }
    }

    private func agentActivityCacheSignature(for message: ChatMessage) -> Int {
        var signature = message.id.hashValue
        signature &+= Self.lightweightTranscriptTextSignature(message.content)
        signature &+= message.isStreaming ? 31 : 7
        signature &+= message.statusHistory.count &* 13
        signature &+= message.files.count &* 17
        signature &+= Self.lightweightTranscriptTextSignature(message.error?.content ?? "")
        if let metadata = message.metadata {
            signature &+= metadata.count &* 19
            for key in [
                "iexa_local_alpine_tool_calls",
                "iexa_local_alpine_command_results",
                "iexa_local_alpine_written_files",
                "iexa_local_alpine_result",
                "iexa_local_alpine_final_summary"
            ] {
                if let value = metadata[key] {
                    signature &+= key.hashValue
                    signature &+= value.isEmpty ? 0 : 1
                    signature &+= Self.lightweightTranscriptTextSignature(value)
                }
            }
        }
        return signature
    }

    private func hasRenderableAgentActivity(for message: ChatMessage, cachedItem: AgentActivityItem? = nil) -> Bool {
        guard let item = cachedItem ?? agentActivity(for: message), item.hasConcreteSteps else {
            return false
        }
        return true
    }

    private func shouldSuppressAssistantBubbleForActivityParent(_ message: ChatMessage, activityItem: AgentActivityItem? = nil) -> Bool {
        guard message.role == .assistant,
              hasRenderableAgentActivity(for: message, cachedItem: activityItem) else {
            return false
        }

        if isMessageVisuallyStreaming(message) {
            return false
        }

        let visibleText = visibleAssistantTextAfterToolProtocolCleanup(for: message)
        if !visibleText.isEmpty {
            return false
        }

        let metadata = message.metadata ?? [:]
        if metadata["iexa_local_native_hidden_tool_parent"] == "true"
            || metadata["iexa_local_alpine_hidden_tool_parent"] == "true" {
            return true
        }
        if contentContainsLocalAlpineInstruction(message.content) {
            return true
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && messageHasProcessOnlyStatus(message)
    }

    private func visibleAssistantTextAfterToolProtocolCleanup(for message: ChatMessage) -> String {
        let signature = visibleAssistantTextCacheSignature(for: message)
        if let cached = assistantVisibleTextCache.lookup(messageId: message.id, signature: signature) {
            return cached
        }
        let raw = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            assistantVisibleTextCache.store(messageId: message.id, signature: signature, value: "")
            return ""
        }
        let withoutAlpineProtocol = LocalAlpineAgentService.visibleContent(from: raw)
        let withoutNativeProtocol = stripNativeToolProtocolBlocks(
            from: LocalNativeToolService.visibleContent(from: withoutAlpineProtocol)
        )
        let visible = withoutNativeProtocol.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = visible == "正在准备本地执行，结果会自动回来。" ? "" : visible
        assistantVisibleTextCache.store(messageId: message.id, signature: signature, value: resolved)
        return resolved
    }

    private func visibleAssistantTextCacheSignature(for message: ChatMessage) -> Int {
        var signature = message.id.hashValue
        signature &+= Self.lightweightTranscriptTextSignature(message.content)
        if let metadata = message.metadata {
            for key in [
                "iexa_local_alpine_hidden_tool_parent",
                "iexa_local_native_hidden_tool_parent",
                "iexa_local_alpine_continuation"
            ] {
                if let value = metadata[key] {
                    signature &+= key.hashValue
                    signature &+= Self.lightweightTranscriptTextSignature(value)
                }
            }
        }
        return signature
    }

    private func assistantContentOverrideForActivityParent(_ message: ChatMessage, activityItem: AgentActivityItem? = nil) -> String? {
        guard message.role == .assistant,
              hasRenderableAgentActivity(for: message, cachedItem: activityItem),
              !isMessageVisuallyStreaming(message) else {
            return nil
        }
        let raw = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let visible = visibleAssistantTextAfterToolProtocolCleanup(for: message)
        guard !visible.isEmpty, visible != raw else { return nil }
        return visible
    }

    private func stripNativeToolProtocolBlocks(from content: String) -> String {
        var cleaned = content.replacingOccurrences(
            of: #"```iexa_native\s*[\s\S]*?```"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"<\s*(?:tool_call|tool_use|function_call|function|iexa_native)\b[^>]*>[\s\S]*?</\s*(?:tool_call|tool_use|function_call|function|iexa_native)\s*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(
            of: #"(?is)^\{[\s\S]*"(?:tool|name|function|function_call|tool_calls)"[\s\S]*"(?:arguments|args|input|tool|name)"[\s\S]*\}$"#,
            options: .regularExpression
        ) != nil {
            return ""
        }
        return trimmed
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
        if requireRenderableContent {
            return transcriptSnapshot.localAlpineVisibleFinalSummaryAfter.contains(message.id)
        }
        return transcriptSnapshot.localAlpineAnyFinalSummaryAfter.contains(message.id)
    }

    private func hasVisibleLocalAlpineFinalSummary(after message: ChatMessage) -> Bool {
        hasLocalAlpineFinalSummary(after: message, requireRenderableContent: true)
    }

    private func localAlpineFinalSummaryParentId(for message: ChatMessage) -> String? {
        guard let value = message.metadata?["iexa_local_alpine_final_summary"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "true" else {
            return nil
        }
        return value
    }

    private func attachedLocalAlpineFinalSummary(for resultMessage: ChatMessage) -> ChatMessage? {
        guard isLocalAlpineResultMessage(resultMessage) else {
            guard let mirroredResult = mirroredLocalAlpineResult(for: resultMessage) else { return nil }
            return attachedLocalAlpineFinalSummary(for: mirroredResult)
        }
        return viewModel.messages.first { candidate in
            guard candidate.role == .assistant,
                  candidate.error == nil,
                  localAlpineFinalSummaryParentId(for: candidate) == resultMessage.id else {
                return false
            }
            return candidate.isStreaming
                || !visibleAssistantTextAfterToolProtocolCleanup(for: candidate)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
        }
    }

    private func isAttachedLocalAlpineFinalSummary(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant,
              message.error == nil,
              let parentId = localAlpineFinalSummaryParentId(for: message),
              let parent = viewModel.messages.first(where: { $0.id == parentId }),
              isLocalAlpineResultMessage(parent) else {
            return false
        }
        return parent.metadata?["iexa_local_alpine_result"] == "true"
            || messageHasConcreteActivityMetadata(parent)
            || !viewModel.localAlpineLiveToolCalls(for: parent.id).isEmpty
            || viewModel.localAlpineLiveToolStatus(for: parent.id) != nil
    }

    private func localAlpineFallbackContent(for message: ChatMessage, activityItem: AgentActivityItem? = nil) -> String {
        guard isLocalAlpineResultMessage(message) else { return "" }
        guard !hasLocalAlpineFinalSummary(after: message, requireRenderableContent: false) else { return "" }
        if (activityItem ?? agentActivity(for: message))?.hasConcreteSteps == true {
            return ""
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldShowAssistantActionBar(for message: ChatMessage, activityItem: AgentActivityItem? = nil) -> Bool {
        if shouldSuppressAssistantBubbleForActivityParent(message, activityItem: activityItem) {
            return false
        }
        if isLocalAlpineResultMessage(message) {
            return !localAlpineFallbackContent(for: message, activityItem: activityItem).isEmpty
        }
        return true
    }

    private func agentActivityWindowPreview(includeInactive: Bool) -> AgentActivityItem? {
        let turnItems = currentTurnAgentActivityItems(includeInactive: includeInactive)
        let isLive = hasLiveAgentActivityState()
        let cacheKey = includeInactive ? "window-preview-include-inactive" : "window-preview-live-only"
        let signature = currentTurnMergedActivitySignature(items: turnItems, includeInactive: includeInactive, isLive: isLive)
        let merged: AgentActivityItem? = {
            if let cached = currentTurnMergedActivityCache.lookup(key: cacheKey, signature: signature) {
                return cached
            }
            let computed = AgentActivityItem.mergedTurn(
                id: "turn-\(viewModel.messages.last?.id ?? "latest")",
                items: turnItems
            )
            currentTurnMergedActivityCache.store(key: cacheKey, signature: signature, item: computed)
            return computed
        }()
        if let merged, merged.hasConcreteSteps {
            guard includeInactive || merged.isActive || isLive else { return nil }
            return merged
        }

        guard let item = turnItems.reversed().first(where: { $0.hasConcreteSteps }) ?? turnItems.last else { return nil }
        guard includeInactive || item.isActive || isLive else { return nil }
        return item
    }

    private func currentTurnMergedActivitySignature(
        items: [AgentActivityItem],
        includeInactive: Bool,
        isLive: Bool
    ) -> Int {
        var signature = items.count &* 31
        signature &+= includeInactive ? 17 : 5
        signature &+= isLive ? 29 : 11
        for item in items {
            signature &+= item.id.hashValue
            signature &+= item.steps.count &* 13
            signature &+= item.fileCount &* 7
            signature &+= item.commandCount &* 11
            signature &+= item.isStreaming ? 19 : 3
            signature &+= item.hasFailure ? 23 : 5
            signature &+= item.currentStepIndex &* 17
            for step in item.steps {
                signature &+= step.id.hashValue
                signature &+= step.title.hashValue
                signature &+= step.detail.hashValue
                signature &+= Self.lightweightTranscriptTextSignature(step.outputPreview)
                signature &+= Self.lightweightTranscriptTextSignature(step.fullOutput ?? "")
                signature &+= step.isRunning ? 31 : 7
                signature &+= step.failed ? 37 : 11
                signature &+= step.durationText?.hashValue ?? 0
            }
        }
        return signature
    }

    private var hasActiveAgentFloatingActivity: Bool {
        hasLiveAgentActivityState()
    }

    private var shouldHideAgentFloatingBarForKeyboard: Bool {
        hideAgentFloatingBarForKeyboard
    }

    private var agentFloatingDisplayItem: AgentActivityItem? {
        let windowItem = agentActivityWindowPreview(includeInactive: true)
        if let windowItem,
           let snapshot = agentFloatingActivitySnapshot {
            if windowItem.steps.count >= snapshot.steps.count {
                return windowItem
            }
            return AgentActivityItem.mergedTurn(
                id: windowItem.id,
                items: [windowItem, snapshot]
            ) ?? windowItem
        }
        return windowItem ?? agentFloatingActivitySnapshot
    }

    private func refreshAgentFloatingActivitySnapshotFromLatestMessage() {
        guard !keyboard.isVisible,
              !hideAgentFloatingBarForKeyboard,
              let message = viewModel.messages.last,
              AgentActivityItem.isActivityMessage(message) else {
            return
        }
        let resolvedItem = agentActivityWindowPreview(includeInactive: false) ?? agentActivity(for: message)
        guard let item = resolvedItem,
              item.hasConcreteSteps else {
            return
        }
        if suppressStaleAgentFloatingBarAfterKeyboard,
           !item.isActive,
           !hasActiveAgentFloatingActivity {
            return
        }
        agentFloatingActivitySnapshot = item
    }

    private func resolvedAgentFloatingActivityItem(
        messageId: String,
        notificationItem: AgentActivityItem?
    ) -> AgentActivityItem? {
        var candidates = currentTurnAgentActivityItems(includeInactive: true)
        if let message = viewModel.messages.first(where: { $0.id == messageId }),
           let messageItem = agentActivity(for: message) {
            candidates.append(messageItem)
        }
        if let existing = agentFloatingActivitySnapshot {
            candidates.append(existing)
        }
        if let notificationItem {
            candidates.append(notificationItem)
        }

        let merged = AgentActivityItem.mergedTurn(
            id: "turn-\(messageId)",
            items: candidates
        )
        if let merged, merged.hasConcreteSteps {
            return merged
        }
        return notificationItem
    }

    private func handleAgentFloatingLiveToolNotification(_ notification: Notification) {
        guard matchesAgentFloatingConversation(notification.userInfo?["conversationId"] as? String),
              let messageId = notification.userInfo?["messageId"] as? String else {
            return
        }
        guard !keyboard.isVisible else {
            return
        }
        let calls = notification.userInfo?["calls"] as? [LocalAlpineToolCall] ?? []
        let status = notification.userInfo?["status"] as? ChatStatusUpdate
        guard !calls.isEmpty || status != nil else { return }

        let notificationItem = AgentActivityItem.liveLocalAlpine(
            messageId: messageId,
            toolCalls: calls,
            liveStatus: status
        )
        guard let item = resolvedAgentFloatingActivityItem(
            messageId: messageId,
            notificationItem: notificationItem
        ),
              item.hasConcreteSteps else {
            return
        }

        pendingNewAgentFloatingSnapshotAfterKeyboard = nil
        suppressStaleAgentFloatingBarAfterKeyboard = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            agentFloatingActivitySnapshot = item
            hideAgentFloatingBarForKeyboard = false
        }
    }

    private func matchesAgentFloatingConversation(_ incomingConversationId: String?) -> Bool {
        let current = (viewModel.conversationId ?? viewModel.conversation?.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let incoming = incomingConversationId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return current.isEmpty || incoming.isEmpty || current == incoming
    }

    private func collapseTransientAgentViewsForBackground() {
        agentFloatingFilePreview = nil
        agentFloatingStepPreview = nil
        agentFloatingLoadingPath = nil
    }

    @MainActor
    private func openAgentFloatingPreview(item: AgentActivityItem, initialIndex: Int) {
        guard item.hasConcreteSteps else {
            return
        }
        let clampedIndex = min(max(initialIndex, 0), max(item.steps.count - 1, 0))
        let lightweightStep = item.steps.indices.contains(clampedIndex) ? item.steps[clampedIndex] : item.currentStep
        let candidateFullItem = agentActivityWindowPreview(includeInactive: true)
        let resolvedFullItem: AgentActivityItem
        let resolvedFullIndex: Int
        if let candidateFullItem,
           let lightweightStep,
           let matchedIndex = candidateFullItem.steps.firstIndex(where: { $0.id == lightweightStep.id }) {
            resolvedFullItem = candidateFullItem
            resolvedFullIndex = matchedIndex
        } else {
            resolvedFullItem = item
            resolvedFullIndex = clampedIndex
        }
        let fullItem = resolvedFullItem
        let fullIndex = min(max(resolvedFullIndex, 0), max(fullItem.steps.count - 1, 0))
        let fullStep = fullItem.steps.indices.contains(fullIndex) ? fullItem.steps[fullIndex] : lightweightStep
        if openAgentPreviewResult(step: fullStep, item: fullItem) {
            Haptics.play(.light)
            return
        }
        Haptics.play(.light)
        agentFloatingStepPreview = AgentFloatingStepPreviewItem(
            activity: fullItem,
            initialIndex: fullIndex
        )
    }

    @MainActor
    private func openAgentPreviewResult(step: AgentActivityStep?, item: AgentActivityItem) -> Bool {
        if let step {
            if let file = step.previewFile {
                openMessageFile(file)
                return true
            }
            if let urlString = step.previewOpenURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               openPreviewURLString(urlString) {
                return true
            }
            if step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return false
            }
            return false
        }

        if let file = item.firstPreviewFile {
            openMessageFile(file)
            return true
        }

        if let urlString = item.firstPreviewOpenURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           openPreviewURLString(urlString) {
            return true
        }

        return false
    }

    @MainActor
    private func openPreviewURLString(_ urlString: String) -> Bool {
        guard let trimmed = AgentActivityItem.normalizedPreviewTarget(urlString) else {
            return false
        }
        if let url = URL(string: trimmed),
           url.scheme != nil || url.isFileURL {
            if Self.canPreviewInApp(url) {
                previewWebURL = WebPreviewURL(url: url)
            } else {
                UIApplication.shared.open(url)
            }
            return true
        }
        handleLocalAlpineOpenRequest(LocalAlpineOpenRequest(target: trimmed))
        return true
    }

    @MainActor
    private func handleLocalAlpineOpenRequest(_ request: LocalAlpineOpenRequest?) {
        guard let request else { return }
        viewModel.consumeLocalAlpinePendingOpenRequest(request)
        if request.target == "iexa://automation-browser" {
            previewWebURL = WebPreviewURL(
                url: BrowserWebSearchService.shared.currentAutomationBrowserURL(),
                usesAutomationBrowser: true,
                dismissWhenHumanVerificationCompletes: false
            )
            return
        }
        if let url = request.webURL {
            previewWebURL = WebPreviewURL(url: url)
            return
        }

        Task {
            do {
                let url = try await LocalAlpineTerminalService.shared.materializePreviewURL(for: request)
                await MainActor.run {
                    if localAlpinePreviewShouldUseWebView(url) {
                        previewWebURL = WebPreviewURL(url: url)
                    } else {
                        previewFileURL = url
                    }
                }
            } catch {
                await MainActor.run {
                    downloadErrorMessage = "预览失败：\(error.localizedDescription)"
                    showDownloadError = true
                }
            }
        }
    }

    private func localAssistantPreviewTarget(for message: ChatMessage) -> String? {
        guard message.role == .assistant || message.role == .system else { return nil }
        let candidates: [String?] = [
            assistantContentOverride[message.id],
            attachedLocalAlpineFinalSummary(for: message).map { visibleAssistantTextAfterToolProtocolCleanup(for: $0) },
            assistantContentOverrideForActivityParent(message, activityItem: nil),
            localAlpineFallbackContent(for: message),
            visibleAssistantTextAfterToolProtocolCleanup(for: message),
            message.content
        ]
        for content in candidates {
            if let target = AgentActivityItem.localWebPreviewTarget(in: content) {
                return target
            }
            if let target = AgentActivityItem.localPreviewTarget(in: content) {
                return target
            }
        }
        return nil
    }

    private func assistantLocalPreviewDisplayText(_ target: String) -> String {
        if target.hasPrefix("/mnt/iexa/") || target.hasPrefix("/tmp/") || target.hasPrefix("/var/") {
            return (target as NSString).lastPathComponent.isEmpty ? target : (target as NSString).lastPathComponent
        }
        if target.lowercased().hasPrefix("iexa://") || target.lowercased().hasPrefix("file://") {
            return (URL(string: target)?.lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? target
        }
        guard let components = URLComponents(string: target) else { return target }
        let host = components.host ?? ""
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path.isEmpty ? "/" : components.path
        return "\(host)\(port)\(path)"
    }

    private func shouldHideFromTranscript(_ message: ChatMessage, context: TranscriptVisibilityContext) -> Bool {
        if isLocalNativeResultMessage(message) {
            return true
        }

        guard message.role == .assistant || message.role == .system else {
            return false
        }

        let metadata = message.metadata ?? [:]
        var cachedVisibleCleanedAssistantText: String?
        var cachedRenderableAgentActivity: Bool?
        func hasVisibleCleanedAssistantText() -> Bool {
            guard message.role == .assistant else { return false }
            if let cachedVisibleCleanedAssistantText {
                return !cachedVisibleCleanedAssistantText.isEmpty
            }
            let visible = visibleAssistantTextAfterToolProtocolCleanup(for: message)
            cachedVisibleCleanedAssistantText = visible
            return !visible.isEmpty
        }
        func hasRenderableAgentActivityCached() -> Bool {
            if let cachedRenderableAgentActivity {
                return cachedRenderableAgentActivity
            }
            let value = hasRenderableAgentActivity(for: message)
            cachedRenderableAgentActivity = value
            return value
        }

        if context.hiddenMergedActivityMessageIds.contains(message.id) {
            return true
        }
        if context.mergedActivityAnchorIds.contains(message.id),
           hasRenderableAgentActivityCached() {
            return false
        }

        if metadata["iexa_local_native_hidden_tool_parent"] == "true" {
            return !hasVisibleCleanedAssistantText() && !hasRenderableAgentActivityCached()
        }
        if isLocalAlpineResultMessage(message) {
            if isMirroredLocalAlpineResultMessage(message),
               let parentId = message.metadata?["iexa_local_alpine_mirrored_parent"],
               let parent = viewModel.messages.first(where: { $0.id == parentId }),
               hasRenderableAgentActivity(for: parent) {
                return true
            }
            let hasVisibleActivity = messageHasConcreteActivityMetadata(message)
                || !viewModel.localAlpineLiveToolCalls(for: message.id).isEmpty
                || viewModel.localAlpineLiveToolStatus(for: message.id) != nil
            if hasVisibleActivity {
                return false
            }
            if context.visibleFinalSummaryAfter.contains(message.id) {
                return true
            }
            if context.laterLocalAlpineTurnMessageAfter.contains(message.id) {
                return true
            }
            if isMessageVisuallyStreaming(message) {
                return false
            }
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && messageHasProcessOnlyStatus(message)
        }
        if metadata["iexa_local_alpine_final_summary"] != nil {
            if isAttachedLocalAlpineFinalSummary(message) {
                return true
            }
            return !isMessageVisuallyStreaming(message)
                && message.error == nil
                && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if metadata["iexa_local_alpine_continuation"] == "true",
           metadata["iexa_local_alpine_final_summary"] == nil {
            if metadata["iexa_local_alpine_auto_verify"] != nil
                || metadata["iexa_local_alpine_missing_tool_correction"] != nil {
                return !isMessageVisuallyStreaming(message) && !hasVisibleCleanedAssistantText()
            }
            if isMessageVisuallyStreaming(message) {
                return false
            }
            if hasVisibleCleanedAssistantText() {
                return false
            }
            if contentContainsLocalAlpineInstruction(message.content) {
                return !hasRenderableAgentActivityCached()
            }
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && messageHasProcessOnlyStatus(message)
        }
        if metadata["iexa_local_alpine_hidden_tool_parent"] == "true" {
            return !hasVisibleCleanedAssistantText() && !hasRenderableAgentActivityCached()
        }
        if metadata["iexa_local_alpine_auto_verify"] != nil
            || metadata["iexa_local_alpine_missing_tool_correction"] != nil
            || metadata["iexa_local_alpine_hidden_correction_parent"] == "true" {
            return !isMessageVisuallyStreaming(message) && !hasVisibleCleanedAssistantText()
        }
        if contentContainsLocalAlpineInstruction(message.content) {
            if isMessageVisuallyStreaming(message) {
                return false
            }
            if hasVisibleCleanedAssistantText() {
                return false
            }
            return !hasRenderableAgentActivityCached()
        }
        if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isMessageVisuallyStreaming(message),
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
                || action == "local_office_agent"
        }
    }

    private func messageHasConcreteActivityMetadata(_ message: ChatMessage) -> Bool {
        guard let metadata = message.metadata else {
            return false
        }
        let keys = [
            "iexa_local_alpine_tool_calls",
            "iexa_local_alpine_command_results",
            "iexa_local_alpine_written_files",
            "iexa_local_native_tool_calls",
            "iexa_local_native_command_results",
            "iexa_local_native_written_files"
        ]
        return keys.contains { key in
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !value.isEmpty && value != "[]"
        }
    }

    private func messageLatestVisibleStatusIsWebSearch(_ message: ChatMessage) -> Bool {
        guard let status = message.statusHistory.last(where: { $0.hidden != true }) else {
            return false
        }
        let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let step = status.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !step.isEmpty,
           !step.contains("browser.search"),
           !step.contains("browser.readable"),
           !step.contains("browser.text") {
            return false
        }
        return action == "web_search"
            || action == "websearch"
            || action == "web search"
            || action == "local_alpine_web_search"
            || action == "browser_web_search"
            || action == "get_readable"
            || action.contains("readable")
    }

    private func orderedAgentTranscriptBlocks(
        for message: ChatMessage,
        activityItem: AgentActivityItem?
    ) -> [OrderedAgentTranscriptBlock]? {
        guard message.role == .assistant,
              let activityItem,
              activityItem.hasConcreteSteps else {
            return nil
        }

        let visible = stripNativeToolProtocolBlocks(
            from: LocalAlpineAgentService.visibleContent(from: message.content)
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        if !activityItem.id.hasPrefix("turn-"),
           let orderedLocalBlocks = orderedLocalAlpineTranscriptBlocks(
                for: message,
                activityItem: activityItem
           ) {
            return orderedLocalBlocks
        }

        var blocks: [OrderedAgentTranscriptBlock] = []
        if isLocalAlpineResultMessage(message) {
            blocks.append(
                OrderedAgentTranscriptBlock(
                    id: "\(message.id)-agent-steps",
                    content: .steps(activityItem)
                )
            )
            if !visible.isEmpty,
               !shouldHideProcessOnlyAgentText(
                    message,
                    visibleText: visible,
                    activityItem: activityItem
               ) {
                blocks.append(
                    OrderedAgentTranscriptBlock(
                        id: "\(message.id)-agent-text",
                        content: .text(visible)
                    )
                )
            }
            return blocks
        }

        blocks.append(
            OrderedAgentTranscriptBlock(
                id: "\(message.id)-agent-steps",
                content: .steps(activityItem)
            )
        )
        if !visible.isEmpty,
           !shouldHideProcessOnlyAgentText(
                message,
                visibleText: visible,
                activityItem: activityItem
           ) {
            blocks.append(
                OrderedAgentTranscriptBlock(
                    id: "\(message.id)-agent-text",
                    content: .text(visible)
                )
            )
        }
        return blocks
    }

    private func shouldHideProcessOnlyAgentText(
        _ message: ChatMessage,
        visibleText: String,
        activityItem: AgentActivityItem
    ) -> Bool {
        if visibleText == "正在准备本地执行，结果会自动回来。" {
            return true
        }

        let metadata = message.metadata ?? [:]
        let isToolProcessParent = metadata["iexa_local_browser_tool"] == "true"
            || metadata["iexa_local_native_tool_parent"] == "true"
            || metadata["iexa_local_native_hidden_tool_parent"] == "true"
            || metadata["iexa_local_alpine_hidden_tool_parent"] == "true"
        guard isToolProcessParent else { return false }

        let normalizedVisible = normalizedProcessText(visibleText)
        guard !normalizedVisible.isEmpty else { return true }

        let candidateTexts = ([activityItem.summary, activityItem.currentStepTitle, activityItem.currentStepDetail]
            + activityItem.steps.flatMap { [$0.title, $0.detail] })
            .map { normalizedProcessText($0) }
            .filter { !$0.isEmpty }
        if candidateTexts.contains(normalizedVisible) {
            return true
        }

        let processMarkers = [
            "正在", "等待", "检测到", "继续操作", "人机验证",
            "网页操作暂停", "网页搜索完成", "网页操作完成", "网页已打开",
            "searching", "loading", "waiting", "completed"
        ]
        return normalizedVisible.count <= 120
            && processMarkers.contains { normalizedVisible.localizedCaseInsensitiveContains($0) }
    }

    private func normalizedProcessText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。…!！:： "))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func orderedLocalAlpineTranscriptBlocks(
        for message: ChatMessage,
        activityItem: AgentActivityItem?
    ) -> [OrderedAgentTranscriptBlock]? {
        guard message.role == .assistant,
              let activityItem,
              activityItem.hasConcreteSteps else {
            return nil
        }

        let spans = localAlpineInstructionSpans(in: message.content)
        guard !spans.isEmpty else {
            return orderedLocalAlpineTranscriptBlocksFromToolOffsets(
                for: message,
                activityItem: activityItem
            )
        }

        let stepGroups = localAlpineStepGroups(activityItem.steps, for: spans)
        var blocks: [OrderedAgentTranscriptBlock] = []
        var cursor = message.content.startIndex

        func appendTextBlock(_ rawText: String, ordinal: Int) {
            let visible = stripNativeToolProtocolBlocks(
                from: LocalAlpineAgentService.visibleContent(from: rawText)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !visible.isEmpty,
                  visible != "正在准备本地执行，结果会自动回来。" else {
                return
            }
            blocks.append(
                OrderedAgentTranscriptBlock(
                    id: "\(message.id)-ordered-text-\(ordinal)",
                    content: .text(visible)
                )
            )
        }

        for (index, span) in spans.enumerated() {
            if cursor < span.range.lowerBound {
                appendTextBlock(String(message.content[cursor..<span.range.lowerBound]), ordinal: blocks.count)
            }
            if stepGroups.indices.contains(index),
               let item = activityItem.retainingSteps(stepGroups[index], idSuffix: "ordered-\(index)") {
                blocks.append(
                    OrderedAgentTranscriptBlock(
                        id: "\(message.id)-ordered-steps-\(index)",
                        content: .steps(item)
                    )
                )
            }
            cursor = span.range.upperBound
        }

        if cursor < message.content.endIndex {
            appendTextBlock(String(message.content[cursor..<message.content.endIndex]), ordinal: blocks.count)
        }

        let hasText = blocks.contains { block in
            if case .text = block.content { return true }
            return false
        }
        let hasSteps = blocks.contains { block in
            if case .steps = block.content { return true }
            return false
        }
        guard hasText && hasSteps else { return nil }
        return blocks
    }

    private func orderedLocalAlpineTranscriptBlocksFromToolOffsets(
        for message: ChatMessage,
        activityItem: AgentActivityItem
    ) -> [OrderedAgentTranscriptBlock]? {
        let content = stripNativeToolProtocolBlocks(
            from: LocalAlpineAgentService.visibleContent(from: message.content)
        )
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var stepsByToolId: [String: AgentActivityStep] = [:]
        for step in activityItem.steps where step.id.hasPrefix("tool-") {
            let toolId = String(step.id.dropFirst("tool-".count))
            stepsByToolId[toolId] = stepsByToolId[toolId] ?? step
        }
        let orderedPairs = activityItem.toolCalls
            .compactMap { call -> (offset: Int, step: AgentActivityStep)? in
                guard let rawOffset = call.contentOffset,
                      let step = stepsByToolId[call.id] else {
                    return nil
                }
                return (max(0, min(rawOffset, content.count)), step)
            }
            .sorted {
                if $0.offset != $1.offset { return $0.offset < $1.offset }
                return $0.step.id < $1.step.id
            }
        guard !orderedPairs.isEmpty else { return nil }

        var blocks: [OrderedAgentTranscriptBlock] = []
        var cursorOffset = 0

        func stringIndex(for offset: Int) -> String.Index {
            content.index(
                content.startIndex,
                offsetBy: max(0, min(offset, content.count)),
                limitedBy: content.endIndex
            ) ?? content.endIndex
        }

        func appendTextRange(from startOffset: Int, to endOffset: Int, ordinal: Int) {
            guard endOffset > startOffset else { return }
            let text = String(content[stringIndex(for: startOffset)..<stringIndex(for: endOffset)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            blocks.append(
                OrderedAgentTranscriptBlock(
                    id: "\(message.id)-offset-text-\(ordinal)",
                    content: .text(text)
                )
            )
        }

        for (index, pair) in orderedPairs.enumerated() {
            appendTextRange(from: cursorOffset, to: pair.offset, ordinal: blocks.count)
            if let item = activityItem.retainingSteps([pair.step], idSuffix: "offset-\(index)") {
                blocks.append(
                    OrderedAgentTranscriptBlock(
                        id: "\(message.id)-offset-steps-\(index)",
                        content: .steps(item)
                    )
                )
            }
            cursorOffset = max(cursorOffset, pair.offset)
        }
        appendTextRange(from: cursorOffset, to: content.count, ordinal: blocks.count)

        let hasText = blocks.contains { block in
            if case .text = block.content { return true }
            return false
        }
        let hasSteps = blocks.contains { block in
            if case .steps = block.content { return true }
            return false
        }
        guard hasText && hasSteps else { return nil }
        return blocks
    }

    private func localAlpineInstructionSpans(in content: String) -> [LocalAlpineInstructionSpan] {
        guard content.range(of: "iexa_alpine", options: .caseInsensitive) != nil
                || content.range(of: "local_alpine_exec", options: .caseInsensitive) != nil else {
            return []
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var spans: [LocalAlpineInstructionSpan] = []

        func appendSpan(range: NSRange, body: String) {
            guard range.location != NSNotFound,
                  range.length > 0,
                  let swiftRange = Range(range, in: content) else {
                return
            }
            spans.append(LocalAlpineInstructionSpan(range: swiftRange, body: body))
        }

        if let fenceRegex = try? NSRegularExpression(
            pattern: #"```([^\n`]*)(?:\n([\s\S]*?))?```"#,
            options: [.caseInsensitive]
        ) {
            for match in fenceRegex.matches(in: content, range: fullRange) {
                let info = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? nsContent.substring(with: match.range(at: 1))
                    : ""
                let body = match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound
                    ? nsContent.substring(with: match.range(at: 2))
                    : ""
                let lowerInfo = info.lowercased()
                let lowerBody = body.lowercased()
                if lowerInfo.contains("iexa_alpine")
                    || lowerInfo.contains("local_alpine_exec")
                    || lowerBody.contains("\"iexa_alpine\"")
                    || lowerBody.contains("\"local_alpine_exec\"") {
                    appendSpan(range: match.range, body: body)
                }
            }
        }

        for pattern in [
            #"<iexa_alpine>([\s\S]*?)</iexa_alpine>"#,
            #"<local_alpine_exec>([\s\S]*?)</local_alpine_exec>"#
        ] {
            guard let tagRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for match in tagRegex.matches(in: content, range: fullRange) where match.numberOfRanges > 1 {
                let bodyRange = match.range(at: 1)
                let body = bodyRange.location != NSNotFound ? nsContent.substring(with: bodyRange) : ""
                appendSpan(range: match.range, body: body)
            }
        }

        var filtered: [LocalAlpineInstructionSpan] = []
        for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let previous = filtered.last,
               span.range.lowerBound < previous.range.upperBound {
                continue
            }
            filtered.append(span)
        }
        return filtered
    }

    private func localAlpineStepGroups(
        _ steps: [AgentActivityStep],
        for spans: [LocalAlpineInstructionSpan]
    ) -> [[AgentActivityStep]] {
        guard !spans.isEmpty else { return [] }
        guard spans.count > 1 else { return [steps] }

        let normalizedBodies = spans.map { normalizedLocalAlpineMatchText($0.body) }
        var matchedGroups = Array(repeating: [AgentActivityStep](), count: spans.count)
        var matchedCount = 0

        for step in steps {
            if let index = normalizedBodies.firstIndex(where: { localAlpineStep(step, matchesInstructionBody: $0) }) {
                matchedGroups[index].append(step)
                matchedCount += 1
            }
        }
        if matchedCount == steps.count {
            return matchedGroups
        }

        var groups = Array(repeating: [AgentActivityStep](), count: spans.count)
        var cursor = 0
        for index in spans.indices {
            let remainingSteps = steps.count - cursor
            let remainingGroups = spans.count - index
            guard remainingSteps > 0 else { break }
            let count = index == spans.count - 1
                ? remainingSteps
                : max(1, (remainingSteps + remainingGroups - 1) / remainingGroups)
            let end = min(steps.count, cursor + count)
            groups[index] = Array(steps[cursor..<end])
            cursor = end
        }
        return groups
    }

    private func localAlpineStep(
        _ step: AgentActivityStep,
        matchesInstructionBody body: String
    ) -> Bool {
        guard !body.isEmpty else { return false }
        var candidates = [
            step.command,
            step.detail,
            step.file?.path,
            step.file?.fileName
        ].compactMap { $0 }
        candidates.append(contentsOf: step.filePaths)
        return candidates.contains { candidate in
            let normalized = normalizedLocalAlpineMatchText(candidate)
            return normalized.count >= 4 && body.contains(normalized)
        }
    }

    private func normalizedLocalAlpineMatchText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func contentContainsLocalAlpineInstruction(_ content: String) -> Bool {
        let patterns = [
            #"(?is)```[ \t]*iexa_alpine\b.*?```"#,
            #"(?is)```[ \t]*local_alpine_exec\b.*?```"#,
            #"(?is)<iexa_alpine>.*?</iexa_alpine>"#,
            #"(?is)<local_alpine_exec>.*?</local_alpine_exec>"#
        ]
        return patterns.contains { pattern in
            content.range(of: pattern, options: .regularExpression) != nil
        }
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
    @State private var isPostSendWaitingUIDelayed = false
    @State private var postSendWaitingUIDelayGeneration = 0
    /// Latches only the first displayed assistant body token.  A dedicated
    /// probe observes streaming text so the full ChatDetailView does not become
    /// a per-token observer.
    @State private var firstTurnVisibleAssistantMessageId: String?

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
    /// Office previews use a UIKit QuickLook wrapper so the navigation bar
    /// keeps readable contrast in both app appearances.
    @State private var localQuickLookPreview: LocalQuickLookPreviewItem?
    /// Fullscreen image browser for images visible in the current chat window.
    @State private var imageGalleryPresentation: AuthenticatedImageGalleryPresentation?
    /// Message-level file preview sheet. Keeps sent files out of message text.
    @State private var previewingMessageFile: MessageFilePreviewItem?
    /// URL for in-app webpage preview from assistant markdown links.
    @State private var previewWebURL: WebPreviewURL?
    /// Code preview from MarkdownView's eye button (fullscreen code view)
    @State private var codePreviewCode: String?
    @State private var codePreviewLanguage: String = ""
    @State private var selectedTextForTranslation = ""
    @State private var showSelectedTextTranslation = false

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
        guard !hasCompletedFirstTurn else { return .normal }
        return hasActiveFirstTurnStream ? .activeFirstTurn : .idleFirstTurn
    }

    private var hasActiveFirstTurnStream: Bool {
        viewModel.isStreaming
            || viewModel.streamingStore.isActive
            || viewModel.messages.last(where: { $0.role == .assistant })?.isStreaming == true
    }

    /// The Gemini field is an entrance / first-response effect, not a permanent
    /// first-conversation wallpaper. The capture fades it as soon as the first
    /// visible assistant body token is displayed.
    private var hasCompletedFirstTurn: Bool {
        guard let firstAssistant = viewModel.messages.first(where: { $0.role == .assistant }) else {
            return false
        }
        if firstTurnVisibleAssistantMessageId == firstAssistant.id {
            return true
        }
        guard !isMessageVisuallyStreaming(firstAssistant) else { return false }
        return !firstAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            ChatAmbientBackgroundView(
                mode: ambientBackgroundMode,
                keyboardIsVisible: keyboard.isVisible
            )
            messageListArea
            if let firstAssistant = viewModel.messages.first(where: { $0.role == .assistant }) {
                FirstAssistantVisibleTokenProbe(
                    streamingStore: viewModel.streamingStore,
                    assistantMessageId: firstAssistant.id,
                    fallbackContent: firstAssistant.content
                ) { messageId in
                    guard self.firstTurnVisibleAssistantMessageId != messageId else { return }
                    self.firstTurnVisibleAssistantMessageId = messageId
                }
            }
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
            pinnedCurrentTurnStartMessageId = nil
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
        .onChange(of: keyboard.isVisible) { _, isVisible in
            if isVisible {
                hideAgentFloatingBarForKeyboardWillShow()
            } else {
                finishAgentFloatingBarKeyboardHide()
                releasePostSendWaitingUIDelayAfterKeyboardSettles()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localAlpineLiveToolStateUpdated)) { notification in
            localAlpineLiveToolRenderRevision &+= 1
            handleAgentFloatingLiveToolNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .localAlpineLiveToolStateCleared)) { notification in
            guard matchesAgentFloatingConversation(notification.userInfo?["conversationId"] as? String) else { return }
            localAlpineLiveToolRenderRevision &+= 1
            if let resolvedItem = agentActivityWindowPreview(includeInactive: true),
               resolvedItem.hasConcreteSteps {
                agentFloatingActivitySnapshot = resolvedItem
            }
            pendingNewAgentFloatingSnapshotAfterKeyboard = nil
            let hasResolvedSnapshot = agentFloatingActivitySnapshot?.hasConcreteSteps == true
            suppressStaleAgentFloatingBarAfterKeyboard = !hasResolvedSnapshot
            setAgentFloatingBarHiddenForKeyboard(keyboard.isVisible || !hasResolvedSnapshot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserWebSearchServiceLivePreviewDidChange)) { notification in
            guard let reference = notification.userInfo?["thumbnail_url"] as? String,
                  !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            automationBrowserLivePreviewReference = reference
            localAlpineLiveToolRenderRevision &+= 1
        }
        .onAppear {
            viewModel.syncOnEntry()
            setAgentFloatingBarHiddenForKeyboard(keyboard.isVisible)
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
            forceDismissInputAfterSend()
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

        let presentationView = lifecycleView
        // Toasts & banners
        .overlay(alignment: .top) {
            if showCopiedToast { copiedToastView }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                errorBannerView(error)
                    .padding(.bottom, 80)
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
        .onChange(of: viewModel.localAlpinePendingOpenRequest) { _, request in
            handleLocalAlpineOpenRequest(request)
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
        .sheet(item: $agentFloatingFilePreview) { item in
            LocalAlpineWrittenFilePreviewSheet(item: item)
                .themed()
        }
        .sheet(item: $agentFloatingStepPreview) { item in
            AgentFloatingStepPreviewSheet(
                item: item,
                liveActivity: agentFloatingDisplayItem
            )
                .themed()
        }
        .sheet(item: $previewWebURL) { item in
            InAppWebPreviewSheet(
                url: item.url,
                usesAutomationBrowser: item.usesAutomationBrowser,
                dismissWhenHumanVerificationCompletes: item.dismissWhenHumanVerificationCompletes
            )
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
            viewModel.inputText = text
            Task { await viewModel.sendMessage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .textSelectionActionRequested)) { notification in
            handleTextSelectionAction(notification)
        }
        .translationPresentation(
            isPresented: $showSelectedTextTranslation,
            text: selectedTextForTranslation
        )
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
        .fullScreenCover(item: $localQuickLookPreview) { item in
            LocalQuickLookPreviewController(url: item.url, title: item.title)
                .ignoresSafeArea()
        }
        // Chat advanced parameters sheet (slider icon in toolbar)
        .sheet(isPresented: $isShowingChatParams) {
            ChatAdvancedParamsSheet(
                params: Binding(
                    get: {
                        if viewModel.conversation != nil {
                            return viewModel.conversation?.chatParams ?? ChatAdvancedParams()
                        }
                        return viewModel.pendingChatParams
                            ?? ChatAdvancedParams.savedDefault
                            ?? ChatAdvancedParams()
                    },
                    set: { newParams in
                        let normalizedParams = newParams.hasAnyOverride ? newParams : nil
                        ChatAdvancedParams.saveDefault(normalizedParams)
                        if viewModel.conversation != nil {
                            viewModel.conversation?.chatParams = normalizedParams
                        } else {
                            viewModel.pendingChatParams = normalizedParams
                        }
                    }
                )
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
                        .foregroundStyle((viewModel.conversation != nil ? viewModel.conversation?.chatParams != nil : (viewModel.pendingChatParams != nil || ChatAdvancedParams.savedDefault != nil)) ? theme.brandPrimary : theme.textTertiary)
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

            if localAlpineToolPreviewEnabled && !shouldHideAgentFloatingBarForKeyboard {
                AgentStepFloatingBarHost(
                    conversationId: viewModel.conversationId ?? viewModel.conversation?.id,
                    fallbackItem: agentFloatingDisplayItem,
                    liveBrowserThumbnailReference: automationBrowserLivePreviewReference,
                    onPreviewTap: { item, index in
                        openAgentFloatingPreview(item: item, initialIndex: index)
                    }
                )
            }

            ChatInputField(
                text: $vm.inputText,
                attachments: $vm.attachments,
                placeholder: placeholderText,
                isEnabled: true,
                onSend: {
                    isScrolledUp = false
                    pinCurrentTurnStartForLatestTurn = true
                    pinnedCurrentTurnStartMessageId = nil
                    userRequestedBottomFollowDuringStreaming = false
                    beginPostSendWaitingUIDelayIfNeeded()
                    Task { await viewModel.sendMessage() }
                },
                onStopGenerating: vm.isStreaming ? { viewModel.stopStreaming() } : nil,
                contextBudgetStatus: vm.contextBudgetStatus,
                onContextBudgetPreviewUpdate: { viewModel.updateLiveContextBudgetPreview() },
                webSearchEnabled: $vm.webSearchEnabled,
                imageGenerationEnabled: $vm.imageGenerationEnabled,
                localOfficeEnabled: $vm.localOfficeEnabled,
                shortcutsEnabled: $vm.shortcutsEnabled,
                codeInterpreterEnabled: $vm.codeInterpreterEnabled,
                isWebSearchAvailable: chatWebSearchEnabled,
                isImageGenerationAvailable: viewModel.selectedModelCanGenerateImages || (
                    dependencies.authViewModel.featurePermissions.imageGeneration
                        && isFeatureAvailable("image_generation", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableImageGeneration)
                ),
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
    /// should be visible in the tools sheet. Server-level feature flags come
    /// from `/api/config`. Image generation is app-side, so it only needs the
    /// global image endpoint to be enabled; other provider tools still require
    /// selected-model capability metadata.
    private func isFeatureAvailable(_ capabilityKey: String, serverEnabled: Bool?) -> Bool {
        // Server must have the feature enabled globally
        guard serverEnabled == true else { return false }
        // Image generation is app-side: any chat model can ask Iexa to call the
        // server's image endpoint when this global feature is enabled.
        if capabilityKey == "image_generation" {
            return true
        }
        // Model must have the capability enabled
        guard let model = viewModel.selectedModel else {
            return serverEnabled == true
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
        let snapshot = transcriptSnapshot
        let snapshotMessages = snapshot.messages
        let snapshotIds = snapshot.ids

        return ZStack {
            scrollContent(snapshot: snapshot)

            // Welcome screen — shown when no messages and not loading
            if !viewModel.isLoadingConversation && snapshotMessages.isEmpty {
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
                pendingNewAgentFloatingSnapshotAfterKeyboard = nil
                resumeAgentFloatingBarForNewTask()
            } else {
                if hasActiveAgentFloatingActivity
                    || viewModel.messages.last.map({ AgentActivityItem.isActivityMessage($0) }) == true {
                    resumeAgentFloatingBarForNewTask()
                }
                refreshAgentFloatingActivitySnapshotFromLatestMessage()
            }
        }
        // Auto-scroll only when the rendered transcript changes. This avoids
        // scrolling to blank spacer space when hidden agent/tool messages are
        // appended or removed behind the visible conversation.
        .onChange(of: snapshotIds) { oldIds, newIds in
            guard !newIds.isEmpty else { return }
            let tailChanged = oldIds.last != newIds.last || newIds.count > oldIds.count
            guard tailChanged else { return }

            // ── ALWAYS bring the new visible turn into view ──
            // No matter where the user is scrolled, sending a message must
            // bring the new message into view. Re-engage auto-scroll so the
            // response streams in below it.
            isScrolledUp = false
            lastProgrammaticScrollTime = Date()

            let latestVisibleRole = snapshotMessages.last?.role
            if latestVisibleRole == .user {
                pinCurrentTurnStartForLatestTurn = true
                pinnedCurrentTurnStartMessageId = newIds.last
                userRequestedBottomFollowDuringStreaming = false
                if keyboard.isVisible {
                    repinToCurrentTurnStartIfFollowing(after: 0.06)
                } else {
                    withAnimation(.easeOut(duration: 0.28)) {
                        scrollToCurrentTurnStart(anchor: .top)
                    }
                }
            } else if oldIds.isEmpty && !keyboard.isVisible {
                // First visible assistant/content in a new chat — smooth ease-out.
                pinCurrentTurnStartForLatestTurn = false
                pinnedCurrentTurnStartMessageId = nil
                userRequestedBottomFollowDuringStreaming = false
                withAnimation(.easeOut(duration: 0.3)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else if keyboard.isVisible {
                // Keep the keyboard in place and pin the turn start, not the
                // ScrollView edge, so the viewport cannot land on spacer-only
                // space while the input bar is settling.
                repinToCurrentTurnStartIfFollowing(after: 0.06)
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
                resumeAgentFloatingBarForNewTask()
                if keyboard.isVisible {
                    return
                }
                // Already following the turn. If the keyboard is visible, or
                // the assistant placeholder has not become visible yet, keep
                // the user-sent turn start pinned instead of jumping to the
                // ScrollView bottom.
                if pinCurrentTurnStartForLatestTurn {
                    scrollToCurrentTurnStartWithoutAnimation(anchor: .top)
                } else if viewModel.messages.count <= 2 {
                    scrollToLatestMessageWithoutAnimation(anchor: .bottom)
                } else if keyboard.isVisible || snapshotMessages.last?.role == .user {
                    scrollToCurrentTurnStartWithoutAnimation(anchor: .top)
                } else {
                    scrollToLatestMessageWithoutAnimation(anchor: .bottom)
                }
            }
        }
        .onChange(of: viewModel.streamingStore.isActive) { wasActive, active in
            if active && !keyboard.isVisible {
                resumeAgentFloatingBarForNewTask()
            } else if wasActive && !active {
                repinToBottomAfterStreamingIfFollowing(after: 0.04)
            }
        }
        // Resume auto-scroll: when the user scrolls back to the bottom
        // (or taps the FAB) during an active stream, re-pin so new
        // tokens keep the view anchored at the bottom.
        .onChange(of: isScrolledUp) { oldValue, newValue in
            if oldValue == true && newValue == false && isAnyMessageVisuallyStreaming {
                userRequestedBottomFollowDuringStreaming = true
                pinCurrentTurnStartForLatestTurn = false
                pinnedCurrentTurnStartMessageId = nil
                lastProgrammaticScrollTime = Date()
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private func scrollContent(snapshot: TranscriptRenderSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isLoadingConversation {
                    loadingPlaceholders
                } else {
                    messagesList(snapshot: snapshot)
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
        .scrollPosition($scrollPosition)
        // Detect scroll position to show/hide FAB + auto-load pagination
        .onScrollGeometryChange(for: CGPoint.self) { geo in
            geo.contentOffset
        } action: { _, newOffset in
            let distanceFromBottom = max(0,
                viewState_contentHeight - newOffset.y - viewState_containerHeight)
            if distanceFromBottom <= 100 {
                // User scrolled very close to the bottom — re-engage auto-scroll.
                if isScrolledUp { isScrolledUp = false }
                if isAnyMessageVisuallyStreaming {
                    userRequestedBottomFollowDuringStreaming = true
                    pinCurrentTurnStartForLatestTurn = false
                    pinnedCurrentTurnStartMessageId = nil
                }
                if !scrollRuntime.isNearBottom {
                    scrollRuntime.isNearBottom = true
                    self.distanceFromBottom = 0
                }
            } else {
                if scrollRuntime.isNearBottom {
                    scrollRuntime.isNearBottom = false
                    self.distanceFromBottom = 101
                }
                // Suppress false "user scrolled up" detection after any programmatic
                // scroll. The scroll animation itself causes the offset to momentarily
                // move in various directions, which would otherwise trigger
                // isScrolledUp = true and break auto-scroll for streaming.
                // A strong upward drag (>30 pt in one callback) is unambiguously
                // intentional — bypass the time guard entirely so it registers
                // immediately even during the 0.1 s scroll-pump interval.
                // During active streaming, any upward movement at all breaks out
                // immediately so the scroll pump can't fight the user's finger.
                // Outside of streaming, require a small but intentional drag (8pt)
                // to avoid accidental break-out from bounce/inertia.
                let threshold: CGFloat = isAnyMessageVisuallyStreaming ? 2 : 8
                let previousOffset = scrollRuntime.lastScrollOffset
                let upwardDelta = previousOffset - newOffset.y
                if upwardDelta > threshold {
                    let isStrongDrag = upwardDelta > 30
                    if !isStrongDrag {
                        // Avoid allocating/checking time on every downward scroll tick.
                        let timeSinceProgrammatic = Date().timeIntervalSince(lastProgrammaticScrollTime)
                        let suppressionWindow: TimeInterval = isAnyMessageVisuallyStreaming ? 0.15 : 0.6
                        guard timeSinceProgrammatic > suppressionWindow else {
                            if abs(newOffset.y - previousOffset) > 2 {
                                scrollRuntime.lastScrollOffset = newOffset.y
                            }
                            return
                        }
                    }
                    if !isScrolledUp { isScrolledUp = true }
                    userRequestedBottomFollowDuringStreaming = false
                }
            }
            if abs(newOffset.y - scrollRuntime.lastScrollOffset) > 2 {
                scrollRuntime.lastScrollOffset = newOffset.y
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

            // Keep the bottom pinned during active streaming. This must be a
            // non-animated correction: repeatedly animating scrollTo(bottom)
            // fights SwiftUI's layout measurement and creates visible jitter.
            let grew = newSize.width > oldContentHeight + 1
            if grew
                && isAnyMessageVisuallyStreaming
                && !isScrolledUp
                && (!pinCurrentTurnStartForLatestTurn || userRequestedBottomFollowDuringStreaming) {
                if userRequestedBottomFollowDuringStreaming {
                    pinCurrentTurnStartForLatestTurn = false
                    pinnedCurrentTurnStartMessageId = nil
                }
                let now = Date()
                if now.timeIntervalSince(lastProgrammaticScrollTime) > 0.08 {
                    lastProgrammaticScrollTime = now
                    scrollToLatestMessageWithoutAnimation(anchor: .bottom)
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
                    pinnedCurrentTurnStartMessageId = nil
                    userRequestedBottomFollowDuringStreaming = true
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
        // viewport.
        return containerHeight
    }

    private static func messageTurnGroups(from messages: [ChatMessage]) -> [TranscriptMessageTurnGroup] {
        var groups: [TranscriptMessageTurnGroup] = []
        var currentMessages: [ChatMessage] = []
        var currentId: String?

        func flushCurrentGroup() {
            guard !currentMessages.isEmpty else { return }
            groups.append(TranscriptMessageTurnGroup(
                id: currentId ?? currentMessages[0].id,
                messages: currentMessages
            ))
            currentMessages.removeAll(keepingCapacity: true)
            currentId = nil
        }

        for message in messages {
            if message.role == .user || currentMessages.isEmpty {
                flushCurrentGroup()
                currentMessages = [message]
                currentId = message.id
            } else {
                currentMessages.append(message)
            }
        }

        flushCurrentGroup()
        return groups
    }

    private var isAnyMessageVisuallyStreaming: Bool {
        viewModel.isStreaming || viewModel.streamingStore.isActive
    }

    private func isMessageVisuallyStreaming(_ message: ChatMessage) -> Bool {
        message.isStreaming
            || (viewModel.streamingStore.streamingMessageId == message.id
                && viewModel.streamingStore.isActive)
    }

    private var visualizationRevealDelayNanoseconds: UInt64 {
        let delay = max(0.08, min(keyboard.animationDuration + 0.04, 0.45))
        return UInt64(delay * 1_000_000_000)
    }

    private func beginPostSendWaitingUIDelayIfNeeded() {
        postSendWaitingUIDelayGeneration += 1
        isPostSendWaitingUIDelayed = false
        if keyboard.isVisible {
            pendingNewAgentFloatingSnapshotAfterKeyboard = nil
            suppressStaleAgentFloatingBarAfterKeyboard = true
            agentFloatingActivitySnapshot = nil
            setAgentFloatingBarHiddenForKeyboard(true)
        }
    }

    private func releasePostSendWaitingUIDelayAfterKeyboardSettles() {
        guard isPostSendWaitingUIDelayed else { return }
        postSendWaitingUIDelayGeneration += 1
        let generation = postSendWaitingUIDelayGeneration
        let delay = max(0.08, min(keyboard.animationDuration + 0.04, 0.45))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard postSendWaitingUIDelayGeneration == generation else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPostSendWaitingUIDelayed = false
            }
        }
    }

    private func hideAgentFloatingBarForKeyboardWillShow() {
        agentFloatingKeyboardHideGeneration += 1
        suppressStaleAgentFloatingBarAfterKeyboard = true
        agentFloatingActivitySnapshot = nil
        pendingNewAgentFloatingSnapshotAfterKeyboard = nil
        setAgentFloatingBarHiddenForKeyboard(true)
    }

    private func finishAgentFloatingBarKeyboardHide() {
        guard !keyboard.isVisible else { return }
        agentFloatingKeyboardHideGeneration += 1
        if let resolvedItem = agentActivityWindowPreview(includeInactive: true),
           resolvedItem.hasConcreteSteps {
            agentFloatingActivitySnapshot = resolvedItem
            suppressStaleAgentFloatingBarAfterKeyboard = false
        } else {
            suppressStaleAgentFloatingBarAfterKeyboard = true
            agentFloatingActivitySnapshot = nil
        }
        pendingNewAgentFloatingSnapshotAfterKeyboard = nil
        setAgentFloatingBarHiddenForKeyboard(agentFloatingActivitySnapshot?.hasConcreteSteps != true)
    }

    private func resumeAgentFloatingBarForNewTask() {
        suppressStaleAgentFloatingBarAfterKeyboard = false
        agentFloatingActivitySnapshot = nil
        pendingNewAgentFloatingSnapshotAfterKeyboard = nil
        if keyboard.isVisible {
            setAgentFloatingBarHiddenForKeyboard(true)
        } else {
            setAgentFloatingBarHiddenForKeyboard(false)
        }
    }

    private func setAgentFloatingBarHiddenForKeyboard(_ hidden: Bool) {
        guard hideAgentFloatingBarForKeyboard != hidden else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hideAgentFloatingBarForKeyboard = hidden
        }
    }

    private func forceDismissInputAfterSend() {
        if keyboard.isVisible {
            pendingNewAgentFloatingSnapshotAfterKeyboard = nil
            suppressStaleAgentFloatingBarAfterKeyboard = true
            agentFloatingActivitySnapshot = nil
            setAgentFloatingBarHiddenForKeyboard(true)
        }
        NotificationCenter.default.post(name: .chatInputFieldDismissKeyboard, object: nil)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func shouldDelayWaitingUI(for message: ChatMessage) -> Bool {
        guard isPostSendWaitingUIDelayed,
              message.role == .assistant,
              message.isStreaming,
              message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.error == nil,
              message.files.isEmpty,
              message.sources.isEmpty,
              message.statusHistory.isEmpty else {
            return false
        }
        guard let messageIndex = viewModel.messages.firstIndex(where: { $0.id == message.id }),
              messageIndex > viewModel.messages.startIndex else {
            return false
        }
        let previousIndex = viewModel.messages.index(before: messageIndex)
        return viewModel.messages[previousIndex].role == .user
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
        let turnStartId = pinnedCurrentTurnStartMessageId.flatMap { pinnedId in
            transcriptMessages.contains(where: { $0.id == pinnedId }) ? pinnedId : nil
        } ?? transcriptMessages.last(where: { $0.role == .user })?.id
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

    private func repinToBottomAfterStreamingIfFollowing(after delay: TimeInterval = 0) {
        let action = {
            let shouldFollowBottom = userRequestedBottomFollowDuringStreaming || !pinCurrentTurnStartForLatestTurn
            guard !isScrolledUp, shouldFollowBottom, !transcriptMessages.isEmpty else { return }
            pinCurrentTurnStartForLatestTurn = false
            pinnedCurrentTurnStartMessageId = nil
            userRequestedBottomFollowDuringStreaming = false
            lastProgrammaticScrollTime = Date()
            scrollToBottomWithoutAnimation()
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
            guard pinCurrentTurnStartForLatestTurn, !transcriptMessages.isEmpty, !isScrolledUp else { return }
            lastProgrammaticScrollTime = Date()
            scrollToCurrentTurnStartWithoutAnimation(anchor: .top)
        }
        if delay <= 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    /// Groups messages by conversation turn.
    ///
    /// Each user message starts a stable `VStack` that owns the assistant/system
    /// messages following it. Keeping prior turns in their original container
    /// prevents LazyVStack from reparenting old rows when a new message is sent.
    /// The latest user turn still gets `minHeight: viewportHeight`, which keeps
    /// the user's sent message near the **top** of the viewport while the AI
    /// response streams in below it.
    ///
    /// All earlier messages render at their natural height.
    private func messagesList(snapshot: TranscriptRenderSnapshot) -> some View {
        return ForEach(snapshot.turnGroups) { group in
            VStack(spacing: 0) {
                ForEach(group.messages) { message in
                    let index = snapshot.indexByMessageId[message.id] ?? 0
                    messageRow(
                        message: message,
                        index: index,
                        lastVisibleMessageId: snapshot.lastVisibleMessageId,
                        latestUserMessageId: snapshot.latestUserMessageId,
                        isMergedActivityAnchor: snapshot.mergedActivityAnchorIds.contains(message.id)
                    )
                        .id(message.id)
                }
            }
            .frame(
                minHeight: group.id == snapshot.lastTurnGroupId ? lastTurnMinHeight : 0,
                alignment: .top
            )
        }
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(
        message: ChatMessage,
        index: Int,
        lastVisibleMessageId: String?,
        latestUserMessageId: String?,
        isMergedActivityAnchor: Bool
    ) -> some View {
        let isLastAssistant = message.role == .assistant && message.id == lastVisibleMessageId
        let userTextIsEmpty = message.role == .user
            && activeUserDisplayContent(for: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let waitingUIIsDelayed = shouldDelayWaitingUI(for: message)
        let rowAgentActivity = message.role == .assistant
            ? transcriptAgentActivity(
                for: message,
                isMergedAnchor: isMergedActivityAnchor
            )
            : nil
        let suppressAssistantBubble = shouldSuppressAssistantBubbleForActivityParent(message, activityItem: rowAgentActivity)
        let orderedAgentBlocks = orderedAgentTranscriptBlocks(
            for: message,
            activityItem: rowAgentActivity
        )
        let isLatestUserMessage = message.role == .user
            && message.id == latestUserMessageId

        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {

            // ── Assistant header (avatar + model name) ──
            if message.role == .assistant && !waitingUIIsDelayed {
                assistantHeader(for: message, animated: isLastAssistant || message.isStreaming)
            }

            if message.role == .user {
                userAttachmentArea(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
                    .contextMenu { messageContextMenu(for: message) }
                    .userAttachmentReveal(enabled: isLatestUserMessage)
            }

            if message.role == .assistant,
               let orderedAgentBlocks {
                orderedAgentTranscriptView(for: message, blocks: orderedAgentBlocks)

                if let attachedSummary = attachedLocalAlpineFinalSummary(for: message) {
                    attachedLocalAlpineFinalSummaryView(for: attachedSummary)
                        .transition(.opacity)
                }
            } else {
                if message.role == .assistant {
                    agentStepPreview(for: message, fallbackItem: rowAgentActivity)
                }

                // ── Streaming status indicators ──
                if message.role == .assistant
                    && !waitingUIIsDelayed
                    && !isLocalAlpineResultMessage(message)
                    && !hasAgentToolPreview(for: message, activityItem: rowAgentActivity)
                    && !messageHasProcessOnlyStatus(message) {
                    IsolatedStreamingStatus(
                        streamingStore: viewModel.streamingStore,
                        message: message
                    )
                }

                // ── Message bubble / content ──
                if !userTextIsEmpty && !waitingUIIsDelayed && !suppressAssistantBubble {
                    messageBubble(for: message, isLastAssistant: isLastAssistant, activityItem: rowAgentActivity)
                        .transition(.opacity)
                }

                if message.role == .assistant,
                   let attachedSummary = attachedLocalAlpineFinalSummary(for: message) {
                    attachedLocalAlpineFinalSummaryView(for: attachedSummary)
                        .transition(.opacity)
                }
            }

            if message.role == .assistant,
               !isMessageVisuallyStreaming(message),
               let target = localAssistantPreviewTarget(for: message) {
                AssistantLocalPreviewButton(
                    displayText: assistantLocalPreviewDisplayText(target),
                    onOpen: {
                        if openPreviewURLString(target) {
                            Haptics.play(.light)
                        }
                    }
                )
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            if shouldShowPendingInterjection(after: message),
               let pending = viewModel.pendingInterjection {
                pendingInterjectionBubble(text: pending.text)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }

            // ── Tool-generated images ──
            if message.role == .assistant && !isMessageVisuallyStreaming(message) {
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
                && !isMessageVisuallyStreaming(message)
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
            if message.role == .assistant && !isMessageVisuallyStreaming(message) && shouldShowAssistantActionBar(for: message, activityItem: rowAgentActivity) {
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
            if message.role == .user && !message.versions.isEmpty && !isAnyMessageVisuallyStreaming {
                userVersionSwitcher(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, 2)
            }

            // ── Follow-up suggestions (last assistant message only) ──
            if isLastAssistant && !isMessageVisuallyStreaming(message) {
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

    private func shouldShowPendingInterjection(after message: ChatMessage) -> Bool {
        guard viewModel.pendingInterjection != nil,
              message.role == .assistant,
              isMessageVisuallyStreaming(message) else {
            return false
        }
        if viewModel.streamingStore.isActive,
           let streamingMessageId = viewModel.streamingStore.streamingMessageId {
            return message.id == streamingMessageId
        }
        return message.id == viewModel.messages.last(where: { candidate in
            candidate.role == .assistant && candidate.isStreaming
        })?.id
    }

    private func pendingInterjectionBubble(text: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Spacer(minLength: 40)

            Text(text)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.background.opacity(theme.isDark ? 0.82 : 0.96), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            style: StrokeStyle(
                                lineWidth: 1,
                                lineCap: .round,
                                dash: [4, 4]
                            )
                        )
                        .foregroundStyle(theme.textTertiary.opacity(0.42))
                )

            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    viewModel.cancelPendingInterjection()
                }
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.red, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消插话")
        }
    }

    @ViewBuilder
    private func attachedLocalAlpineFinalSummaryView(for message: ChatMessage) -> some View {
        let content = visibleAssistantTextAfterToolProtocolCleanup(for: message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            assistantTextBubble(
                for: message,
                content: content,
                includeMessagePayload: true
            )
        } else if isMessageVisuallyStreaming(message) {
            ChatMessageBubble(
                role: .assistant,
                showTimestamp: activeActionMessageId == message.id,
                timestamp: message.timestamp
            ) {
                TypingIndicator()
            }
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

    @ViewBuilder
    private func assistantHeader(for message: ChatMessage, animated: Bool) -> some View {
        let model = resolveModel(for: message)
        let header = HStack(spacing: Spacing.sm) {
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

        if animated {
            header.assistantHeaderReveal()
        } else {
            header
        }
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func orderedAgentTranscriptView(
        for message: ChatMessage,
        blocks: [OrderedAgentTranscriptBlock]
    ) -> some View {
        let lastTextBlockId = blocks.reversed().first { block in
            if case .text = block.content { return true }
            return false
        }?.id

        ForEach(blocks) { block in
            switch block.content {
            case .text(let content):
                assistantTextBubble(
                    for: message,
                    content: content,
                    includeMessagePayload: block.id == lastTextBlockId
                )
                .transition(.opacity)
            case .steps(let item):
                AgentInlineStepsView(
                    item: item,
                    onStopRunningStep: { viewModel.stopStreaming() }
                )
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private func assistantTextBubble(
        for message: ChatMessage,
        content: String,
        includeMessagePayload: Bool
    ) -> some View {
        ChatMessageBubble(
            role: .assistant,
            showTimestamp: activeActionMessageId == message.id,
            timestamp: message.timestamp
        ) {
            AssistantMessageContent(
                content: content,
                isStreaming: false,
                messageEmbeds: includeMessagePayload ? message.embeds : [],
                localReasoningContent: includeMessagePayload ? message.metadata?["iexa_local_reasoning_content"] : nil,
                localReasoningDone: includeMessagePayload ? (message.metadata?["iexa_local_reasoning_done"] == "true") : nil,
                localStructuredPartsJSON: includeMessagePayload ? message.metadata?["iexa_local_content_parts"] : nil,
                authToken: viewModel.serverAuthToken,
                serverBaseURL: viewModel.serverBaseURL,
                apiClient: dependencies.apiClient
            )
        }
    }

    @ViewBuilder
    private func messageBubble(for message: ChatMessage, isLastAssistant: Bool, activityItem: AgentActivityItem? = nil) -> some View {
        if isLocalAlpineResultMessage(message) {
            let fallbackContent = localAlpineFallbackContent(for: message, activityItem: activityItem)
            if !fallbackContent.isEmpty {
                ChatMessageBubble(
                    role: .assistant,
                    showTimestamp: activeActionMessageId == message.id,
                    timestamp: message.timestamp
                ) {
                    AssistantMessageContent(
                        content: fallbackContent,
                        isStreaming: isMessageVisuallyStreaming(message),
                        messageEmbeds: message.embeds,
                        localReasoningContent: message.metadata?["iexa_local_reasoning_content"],
                        localReasoningDone: message.metadata?["iexa_local_reasoning_done"] == "true",
                        localStructuredPartsJSON: message.metadata?["iexa_local_content_parts"],
                        authToken: viewModel.serverAuthToken,
                        serverBaseURL: viewModel.serverBaseURL,
                        apiClient: dependencies.apiClient
                    )
                }
            } else if isMessageVisuallyStreaming(message) {
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
                messageContent(for: message, activityItem: activityItem)
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

    private func isMirroredLocalAlpineResultMessage(_ message: ChatMessage) -> Bool {
        guard isLocalAlpineResultMessage(message),
              let parentId = message.metadata?["iexa_local_alpine_mirrored_parent"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !parentId.isEmpty
    }

    private func mirroredLocalAlpineResult(for parentMessage: ChatMessage) -> ChatMessage? {
        guard !isLocalAlpineResultMessage(parentMessage) else { return nil }
        if let resultId = parentMessage.metadata?["iexa_local_alpine_mirrored_result_id"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !resultId.isEmpty,
           let result = viewModel.messages.first(where: { $0.id == resultId && isLocalAlpineResultMessage($0) }) {
            return result
        }
        return viewModel.messages.first { candidate in
            isLocalAlpineResultMessage(candidate)
                && candidate.metadata?["iexa_local_alpine_mirrored_parent"] == parentMessage.id
        }
    }

    private func hasAgentToolPreview(for message: ChatMessage, activityItem: AgentActivityItem? = nil) -> Bool {
        guard let item = activityItem ?? agentActivity(for: message), item.hasConcreteSteps else {
            return false
        }
        return true
    }

    @ViewBuilder
    private func agentStepPreview(for message: ChatMessage, fallbackItem: AgentActivityItem? = nil) -> some View {
        let fallbackItem = fallbackItem ?? agentActivity(for: message)
        if isLocalAlpineResultMessage(message) || fallbackItem?.hasConcreteSteps == true {
            if let fallbackItem,
               fallbackItem.hasConcreteSteps {
                AgentInlineStepsView(
                    item: fallbackItem,
                    onStopRunningStep: { viewModel.stopStreaming() }
                )
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }
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
        if message.role == .user && !isAnyMessageVisuallyStreaming {
            Button { beginInlineEdit(message: message) } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        if message.role == .assistant && !isAnyMessageVisuallyStreaming {
            Button { Task { await viewModel.regenerateResponse(messageId: message.id) } } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        if !isAnyMessageVisuallyStreaming {
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
    private func messageContent(for message: ChatMessage, activityItem: AgentActivityItem? = nil) -> some View {
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
                contentOverride: assistantContentOverride[message.id]
                    ?? assistantContentOverrideForActivityParent(message, activityItem: activityItem),
                showEmptyThinkingCapsule: true,
                keyboardIsVisible: keyboard.isVisible,
                visualizationRevealDelayNanoseconds: visualizationRevealDelayNanoseconds,
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
            // Copy
            Button { copyMessage(message) } label: {
                chatGPTPrimaryActionIcon(icon: "square.on.square")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy")

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
                    chatGPTPrimaryActionIcon(
                        icon: speakingMessageId == message.id ? "stop.fill" : "waveform",
                        isActive: speakingMessageId == message.id
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speakingMessageId == message.id ? "Stop speaking" : "Speak")

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
            if totalVersions > 1 && !isAnyMessageVisuallyStreaming && assistantContentOverride[message.id] == nil {
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
            if !isAnyMessageVisuallyStreaming {
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
            if !isAnyMessageVisuallyStreaming && totalVersions > 1 {
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
            if !isAnyMessageVisuallyStreaming {
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

    /// ChatGPT-style leading action icons for copy and read-aloud.
    private func chatGPTPrimaryActionIcon(
        icon: String,
        isActive: Bool = false,
        size: CGFloat = 13
    ) -> some View {
        Image(systemName: icon)
            .scaledFont(size: size, weight: .medium)
            .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary.opacity(0.72))
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
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

                if !isAnyMessageVisuallyStreaming {
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
                                chatImageView(fileId: fileId, allowsEditing: false, contentMode: .fill)
                                    .frame(width: thumbnailSize, height: thumbnailSize)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        let cornerRadius: CGFloat = size.width > 100 || size.height > 100 ? 22 : 14
        if file.isGeneratedImageFailurePlaceholder {
            GeneratedImageFailurePlaceholder()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if let fileId = imageReference(for: file) {
            chatImageView(fileId: fileId, allowsEditing: false, contentMode: .fill)
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
            guard encoded.utf8.count <= 2_000_000,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                return nil
            }
            return imagePixelSize(fromImageData: data)
        }

        if reference.hasPrefix("file://"),
           let url = URL(string: reference) {
            return imagePixelSize(fromImageURL: url)
        }

        return nil
    }

    private func imagePixelSize(fromImageData data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }
        return imagePixelSize(fromImageSource: source)
    }

    private func imagePixelSize(fromImageURL url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }
        return imagePixelSize(fromImageSource: source)
    }

    private func imagePixelSize(fromImageSource source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) as? [CFString: Any] else {
            return nil
        }
        let width = imagePixelDimension(properties[kCGImagePropertyPixelWidth])
        let height = imagePixelDimension(properties[kCGImagePropertyPixelHeight])
        guard let width,
              let height,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func imagePixelDimension(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let int = value as? Int {
            return CGFloat(int)
        }
        if let double = value as? Double {
            return CGFloat(double)
        }
        return nil
    }

    @ViewBuilder
    private func chatImageView(
        fileId: String,
        allowsEditing: Bool = true,
        contentMode: ContentMode = .fit,
        actionLayout: AuthenticatedImageActionLayout = .compactTopTrailing,
        adaptiveThumbnailWidth: CGFloat? = nil
    ) -> some View {
        if allowsEditing {
            AuthenticatedImageView(
                fileId: fileId,
                apiClient: dependencies.apiClient,
                onEdit: { image in
                    prepareGeneratedImageForEditing(image)
                },
                onPreview: {
                    openImageGallery(startingAt: fileId)
                },
                contentMode: contentMode,
                actionLayout: actionLayout,
                adaptiveThumbnailWidth: adaptiveThumbnailWidth
            )
        } else {
            AuthenticatedImageView(
                fileId: fileId,
                apiClient: dependencies.apiClient,
                onPreview: {
                    openImageGallery(startingAt: fileId)
                },
                contentMode: contentMode,
                actionLayout: actionLayout,
                adaptiveThumbnailWidth: adaptiveThumbnailWidth
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
            } else if message.role == .assistant && !isMessageVisuallyStreaming(message) {
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
        if let displayReference = Self.preferredDisplayImageReference(for: file.displayURL) {
            return displayReference
        }
        if let localAlpineReference = [file.url, file.displayURL]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.lowercased().hasPrefix("local-alpine:") }) {
            return localAlpineReference
        }
        let candidates = [file.displayURL, file.url].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        for candidate in candidates where !candidate.isEmpty {
            if candidate.lowercased().hasPrefix("local-inline-image:") {
                continue
            }
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
                || candidate.hasPrefix("https://")
                || candidate.hasPrefix("local-alpine:") {
                return candidate
            }
            let lowerCandidate = candidate.lowercased()
            if !candidate.contains("/"),
               lowerCandidate.range(of: #"\.(png|jpe?g|webp|gif|bmp|avif)$"#, options: .regularExpression) != nil {
                return "local-alpine:/shared/\(candidate)"
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

    private static func preferredDisplayImageReference(for value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:image/") {
            guard trimmed.utf8.count <= 7_000_000 else { return nil }
            return trimmed
        }
        guard trimmed.utf8.count <= 4_096 else { return nil }
        if trimmed.hasPrefix("file://")
            || trimmed.hasPrefix("http://")
            || trimmed.hasPrefix("https://") {
            return trimmed
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
            openMessageFile(file)
        } label: {
            if compact {
                compactFileAttachmentLabel(fileName: fileName, file: file, fileExt: fileExt, icon: icon)
            } else {
                regularFileAttachmentLabel(fileName: fileName, file: file, fileExt: fileExt, icon: icon)
            }
        }
        .buttonStyle(.plain)
    }

    private func openMessageFile(_ file: ChatMessageFile) {
        let fileName = file.name ?? file.url ?? "File"
        let fileExt = (fileName as NSString).pathExtension.lowercased()
        if let localURL = localPreviewURL(for: file),
           Self.canQuickLookLocalFile(fileExtension: fileExt) {
            if isOfficeDocumentFile(file) {
                localQuickLookPreview = LocalQuickLookPreviewItem(
                    url: localURL,
                    title: Self.previewTitle(for: fileName)
                )
            } else {
                previewFileURL = localURL
            }
        } else {
            previewingMessageFile = MessageFilePreviewItem(file: file)
        }
    }

    private func shareMessageFileForEditing(_ file: ChatMessageFile) {
        if let localURL = localPreviewURL(for: file) {
            downloadedFileURL = localURL
            Haptics.play(.light)
            return
        }

        let fileName = file.name ?? file.url ?? "File"
        let candidates = [file.displayURL, file.url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let fileId = candidates.compactMap(Self.serverFileId(from:)).first {
            Task { await downloadAndShareFile(fileId: fileId) }
            return
        }
        if let remote = candidates.compactMap(URL.init(string:)).first(where: { ["http", "https"].contains($0.scheme?.lowercased()) }) {
            Task { await downloadAndShareRemoteFile(url: remote, suggestedName: fileName) }
            return
        }

        openMessageFile(file)
    }

    private func shareMessageVideoFile(_ file: ChatMessageFile) {
        let fileName = file.name ?? file.url ?? "generated-video.mp4"
        if let localURL = localPreviewURL(for: file) {
            downloadedFileURL = localURL
            Haptics.play(.light)
            return
        }

        let candidates = [file.displayURL, file.url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let dataURL = candidates.first(where: { $0.hasPrefix("data:video/") }) {
            Task {
                do {
                    if let localURL = try await Self.localFileURL(fromDataURL: dataURL, fallbackName: fileName) {
                        downloadedFileURL = localURL
                        Haptics.play(.light)
                    } else {
                        openMessageFile(file)
                    }
                } catch {
                    downloadErrorMessage = "视频保存失败：\(error.localizedDescription)"
                    showDownloadError = true
                }
            }
            return
        }

        if let fileId = candidates.compactMap(Self.serverFileId(from:)).first {
            Task { await downloadAndShareFile(fileId: fileId) }
            return
        }

        if let remote = candidates.compactMap(URL.init(string:)).first(where: { ["http", "https"].contains($0.scheme?.lowercased()) }) {
            Task { await downloadAndShareRemoteFile(url: remote, suggestedName: fileName) }
            return
        }

        openMessageFile(file)
    }

    private func localPreviewURL(for file: ChatMessageFile) -> URL? {
        for value in [file.displayURL, file.url].compactMap({ $0 }) {
            if let url = URL(string: value), url.isFileURL {
                return url
            }
        }
        return nil
    }

    private static func previewTitle(for fileName: String) -> String {
        let name = (fileName as NSString).lastPathComponent
        let baseName = (name as NSString).deletingPathExtension
        return baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : baseName
    }

    private static func serverFileId(from ref: String) -> String? {
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

    private static func canQuickLookLocalFile(fileExtension ext: String) -> Bool {
        [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "numbers", "pages", "key", "rtf", "txt", "csv",
            "png", "jpg", "jpeg", "gif", "heic", "heif", "webp"
        ].contains(ext)
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
        let officeFiles = files.filter { isOfficeDocumentFile($0) }
        let officePreviewFiles = officeFiles.isEmpty ? [] : files.filter { isOfficePreviewImageFile($0) }
        let imageFiles = Array(files.filter { file in
            isImageFile(file)
                && !officePreviewFiles.contains(file)
                && (file.isGeneratedImageFailurePlaceholder || imageReference(for: file) != nil)
        }.prefix(9))
        let videoFiles = files.filter { isVideoFile($0) }
        let nonImageFiles = files.filter {
            !isImageFile($0)
                && !isVideoFile($0)
                && $0.type != "collection"
                && $0.type != "folder"
                && !isOfficeDocumentFile($0)
        }
        if !officeFiles.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(officeFiles.enumerated()), id: \.offset) { _, file in
                    officeDocumentAttachmentCard(file: file, previewFiles: officePreviewFiles)
                }
            }
        }
        if !imageFiles.isEmpty {
            if imageFiles.count == 1, let file = imageFiles.first {
                let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
                if file.isGeneratedImageFailurePlaceholder {
                    GeneratedImageFailurePlaceholder()
                        .frame(width: generatedImageGalleryMaxWidth, height: 220)
                        .clipShape(shape)
                        .contentShape(shape)
                } else if let fileId = imageReference(for: file) {
                    // A single result should feel like a full image card: retain the
                    // image's aspect ratio instead of turning a portrait into a crop.
                    chatImageView(fileId: fileId, actionLayout: .singleBottomOverlay)
                        .clipShape(shape)
                        .contentShape(shape)
                }
            } else {
                generatedAdaptiveImageGrid(files: imageFiles)
            }
        }
        if !videoFiles.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(videoFiles.enumerated()), id: \.offset) { _, file in
                    videoAttachmentCard(file: file)
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

    /// Mirrors the compact, rounded gallery used by ChatGPT: fewer images get
    /// generous cells, while 5–9 concurrent results remain scannable at a glance.
    private var generatedImageGalleryMaxWidth: CGFloat { 340 }

    private func generatedAdaptiveImageGrid(files: [ChatMessageFile]) -> some View {
        let columnCount = files.count <= 4 ? 2 : 3
        let spacing: CGFloat = 6
        let thumbnailWidth = floor((generatedImageGalleryMaxWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount))
        let rows = stride(from: 0, to: files.count, by: columnCount).map {
            Array(files[$0..<min($0 + columnCount, files.count)])
        }

        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowFiles in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(rowFiles.enumerated()), id: \.element) { _, file in
                        generatedAdaptiveImageTile(file: file, width: thumbnailWidth)
                    }
                }
            }
        }
        .frame(width: generatedImageGalleryMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private func generatedAdaptiveImageTile(file: ChatMessageFile, width: CGFloat) -> some View {
        if file.isGeneratedImageFailurePlaceholder {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            GeneratedImageFailurePlaceholder()
                .frame(width: width, height: width)
                .clipShape(shape)
                .contentShape(shape)
        } else if let fileId = imageReference(for: file) {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            chatImageView(
                fileId: fileId,
                contentMode: .fit,
                actionLayout: .none,
                adaptiveThumbnailWidth: width
            )
            .clipShape(shape)
            .contentShape(shape)
        }
    }

    private func isOfficeDocumentFile(_ file: ChatMessageFile) -> Bool {
        let name = (file.name ?? file.url ?? "").lowercased()
        let contentType = (file.contentType ?? "").lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if ["xlsx", "xls", "pptx", "ppt", "docx", "doc", "pdf"].contains(ext) {
            return true
        }
        return contentType.contains("spreadsheetml")
            || contentType.contains("presentationml")
            || contentType.contains("wordprocessingml")
            || contentType == "application/pdf"
            || contentType.contains("officedocument")
    }

    private func isOfficePreviewImageFile(_ file: ChatMessageFile) -> Bool {
        guard isImageFile(file) else { return false }
        let name = (file.name ?? file.url ?? "").lowercased()
        return name.contains("preview-")
            || name.contains("slide-")
            || name.contains("/office agent/")
            || name.contains("office%20agent")
    }

    private func isVideoFile(_ file: ChatMessageFile) -> Bool {
        let name = (file.name ?? file.url ?? file.displayURL ?? "").lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let contentType = (file.contentType ?? "").lowercased()
        return file.type == "video"
            || contentType.hasPrefix("video/")
            || ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext)
            || name.hasPrefix("data:video/")
    }

    private func videoAttachmentCard(file: ChatMessageFile) -> some View {
        let fileName = file.name ?? "generated-video.mp4"
        let fileExt = (fileName as NSString).pathExtension.lowercased()

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                VideoAttachmentThumbnail(file: file)
                    .frame(width: 300, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

                Button {
                    shareMessageVideoFile(file)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.54), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("保存或分享视频")
            }

            HStack(spacing: 9) {
                Image(systemName: "play.rectangle.fill")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                Text(fileName)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(fileAttachmentSubtitle(for: file, fallbackExtension: fileExt.isEmpty ? "mp4" : fileExt))
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(theme.surfaceContainer.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.42), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .onTapGesture {
            openMessageFile(file)
        }
    }

    private func officeDocumentAttachmentCard(
        file: ChatMessageFile,
        previewFiles: [ChatMessageFile]
    ) -> some View {
        let fileName = file.name ?? file.url ?? "Office 文件"
        let fileExt = (fileName as NSString).pathExtension.lowercased()
        let icon = fileIconName(for: fileExt)
        let kind = officeDocumentKindName(for: file, fallbackExtension: fileExt)
        let previewReference = previewFiles.first.flatMap { imageReference(for: $0) }
        let previewCount = previewFiles.count

        return HStack(spacing: 8) {
            Button {
                openMessageFile(file)
            } label: {
                HStack(spacing: 12) {
                    OfficeAttachmentThumbnail(
                        reference: previewReference,
                        fallbackIcon: icon,
                        pageCount: previewCount
                    )
                    .frame(width: 116, height: 74)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: icon)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(theme.brandPrimary)
                            Text(kind)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }

                        Text(fileName)
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(officeAttachmentSubtitle(for: file, previewCount: previewCount, fallbackExtension: fileExt))
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                shareMessageFileForEditing(file)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.up")
                        .scaledFont(size: 15, weight: .semibold)
                    Text("编辑")
                        .scaledFont(size: 10, weight: .semibold)
                }
                .foregroundStyle(theme.textSecondary)
                .frame(width: 46, height: 54)
                .background(theme.surfaceContainerHighest.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: 390, alignment: .leading)
        .background(theme.surfaceContainer.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.42), lineWidth: 0.5)
        )
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                openMessageFile(file)
            } label: {
                Label("打开文件", systemImage: "doc.viewfinder")
            }
            Button {
                shareMessageFileForEditing(file)
            } label: {
                Label("编辑或导出", systemImage: "square.and.arrow.up")
            }
            if let preview = previewFiles.first {
                Button {
                    openMessageFile(preview)
                } label: {
                    Label("查看缩略图", systemImage: "photo")
                }
            }
        }
    }

    private func officeDocumentKindName(for file: ChatMessageFile, fallbackExtension ext: String) -> String {
        let contentType = (file.contentType ?? "").lowercased()
        if ["xlsx", "xls"].contains(ext) || contentType.contains("spreadsheetml") { return "Excel 表格" }
        if ["pptx", "ppt"].contains(ext) || contentType.contains("presentationml") { return "PPT 演示稿" }
        if ["docx", "doc"].contains(ext) || contentType.contains("wordprocessingml") { return "Word 文档" }
        if ext == "pdf" || contentType == "application/pdf" { return "PDF 文档" }
        return ext.isEmpty ? "Office 文件" : ext.uppercased()
    }

    private func officeAttachmentSubtitle(
        for file: ChatMessageFile,
        previewCount: Int,
        fallbackExtension ext: String
    ) -> String {
        let previewText = previewCount > 0 ? "\(previewCount) 张缩略预览" : "可直接打开预览"
        let kind = officeDocumentKindName(for: file, fallbackExtension: ext)
        return "\(kind) · \(previewText)"
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
            if !isAnyMessageVisuallyStreaming {
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

    private func handleTextSelectionAction(_ notification: Notification) {
        guard let rawAction = notification.userInfo?["action"] as? String,
              let selectedText = notification.userInfo?["text"] as? String else {
            return
        }
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch TextSelectionAction(rawValue: rawAction) {
        case .ask:
            stageSelectedTextPrompt(
                "请基于下面选中的内容回答或解释：\n\n\(text)"
            )
        case .searchWeb, .lookUp:
            openSearchForSelectedText(text)
        case .translate:
            selectedTextForTranslation = text
            showSelectedTextTranslation = true
        case .share:
            messageShareItem = MessageShareItem(text: text)
            Haptics.play(.light)
        case .none:
            break
        }
    }

    private func stageSelectedTextPrompt(_ prompt: String) {
        viewModel.inputText = prompt
        Haptics.play(.light)
        NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
    }

    private func openSearchForSelectedText(_ text: String) {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        guard let url = URL(string: "https://cn.bing.com/search?q=\(encoded)&setlang=zh-Hans") else {
            stageSelectedTextPrompt("搜索网页：\(text)")
            return
        }
        previewWebURL = WebPreviewURL(url: url)
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

    private struct PreparedImageAttachmentPayload: Sendable {
        let uploadData: Data
        let fileName: String
        let thumbnailData: Data?
        let displayDataURL: String
        let displayImageReference: String?
    }

    private struct SendableUIImage: @unchecked Sendable {
        let image: UIImage
    }

    private static func prepareImageAttachmentPayload(
        data: Data,
        originalName: String
    ) async -> PreparedImageAttachmentPayload {
        await Task.detached(priority: .userInitiated) {
            let prepared = FileAttachmentService.prepareImageForUpload(data: data, originalName: originalName)
            return PreparedImageAttachmentPayload(
                uploadData: prepared.data,
                fileName: prepared.fileName,
                thumbnailData: FileAttachmentService.thumbnailJPEGData(from: prepared.data),
                displayDataURL: FileAttachmentService.imageDataURL(data: prepared.data, fileName: prepared.fileName),
                displayImageReference: FileAttachmentService.writeImagePreviewToCache(
                    data: prepared.data,
                    originalName: prepared.fileName
                )
            )
        }.value
    }

    private static func prepareImageAttachmentPayload(
        image: UIImage,
        originalName: String
    ) async -> PreparedImageAttachmentPayload {
        let sendableImage = SendableUIImage(image: image)
        return await Task.detached(priority: .userInitiated) {
            let uploadData = FileAttachmentService.downsampleForUpload(image: sendableImage.image)
            let fileName = FileAttachmentService.imageFileNamePreservingDetectedExtension(originalName: originalName, data: uploadData)
            return PreparedImageAttachmentPayload(
                uploadData: uploadData,
                fileName: fileName,
                thumbnailData: FileAttachmentService.thumbnailJPEGData(from: uploadData)
                    ?? FileAttachmentService.thumbnailJPEGData(from: sendableImage.image),
                displayDataURL: FileAttachmentService.imageDataURL(data: uploadData, fileName: fileName),
                displayImageReference: FileAttachmentService.writeImagePreviewToCache(
                    data: uploadData,
                    originalName: fileName
                )
            )
        }.value
    }

    private static func thumbnailImage(from data: Data?) -> Image? {
        guard let data,
              let image = UIImage(data: data) else {
            return nil
        }
        return Image(uiImage: image)
    }

    private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let fileName = FileAttachmentService.imageFileName(
                        baseName: "Photo_\(Int(Date.now.timeIntervalSince1970))",
                        data: data
                    )
                    let prepared = await Self.prepareImageAttachmentPayload(
                        data: data,
                        originalName: fileName
                    )
                    var attachment = ChatAttachment(
                        type: .image,
                        name: prepared.fileName,
                        thumbnail: Self.thumbnailImage(from: prepared.thumbnailData),
                        data: prepared.uploadData
                    )
                    attachment.displayDataURL = prepared.displayDataURL
                    attachment.displayImageReference = prepared.displayImageReference
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
            let prepared = await Self.prepareImageAttachmentPayload(
                data: data,
                originalName: url.lastPathComponent
            )
            var attachment = ChatAttachment(
                type: .image, name: prepared.fileName,
                thumbnail: Self.thumbnailImage(from: prepared.thumbnailData),
                data: prepared.uploadData
            )
            attachment.displayDataURL = prepared.displayDataURL
            attachment.displayImageReference = prepared.displayImageReference
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
        let fileName = "Camera_\(Int(Date.now.timeIntervalSince1970)).jpg"
        Task { @MainActor in
            let prepared = await Self.prepareImageAttachmentPayload(
                image: image,
                originalName: fileName
            )
            guard !prepared.uploadData.isEmpty else { return }
            var attachment = ChatAttachment(
                type: .image,
                name: prepared.fileName,
                thumbnail: Self.thumbnailImage(from: prepared.thumbnailData),
                data: prepared.uploadData
            )
            attachment.displayDataURL = prepared.displayDataURL
            attachment.displayImageReference = prepared.displayImageReference
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        }
    }

    private func prepareGeneratedImageForEditing(_ image: UIImage) {
        let fileName = "Edit_Source_\(Int(Date.now.timeIntervalSince1970)).jpg"
        Task { @MainActor in
            let prepared = await Self.prepareImageAttachmentPayload(
                image: image,
                originalName: fileName
            )
            guard !prepared.uploadData.isEmpty else {
                viewModel.errorMessage = "无法读取这张图片"
                return
            }

            var attachment = ChatAttachment(
                type: .image,
                name: prepared.fileName,
                thumbnail: Self.thumbnailImage(from: prepared.thumbnailData),
                data: prepared.uploadData
            )
            attachment.displayDataURL = prepared.displayDataURL
            attachment.displayImageReference = prepared.displayImageReference
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
            viewModel.imageGenerationEnabled = true
            if viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.inputText = "编辑这张图："
            }
        }
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

/// Keeps first-token observation isolated from ChatDetailView's large body.
/// The ambient background only needs one transition, so this reports once when
/// actual visible assistant prose begins to drain into the transcript.
private struct FirstAssistantVisibleTokenProbe: View {
    let streamingStore: StreamingContentStore
    let assistantMessageId: String
    let fallbackContent: String
    let onVisibleBodyToken: @MainActor (String) -> Void

    private var visibleContent: String {
        let isActiveMessage = streamingStore.isActive
            && streamingStore.streamingMessageId == assistantMessageId
        return isActiveMessage ? streamingStore.displayContent : fallbackContent
    }

    var body: some View {
        let content = visibleContent
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { reportIfVisible(content) }
            .onChange(of: content) { _, updatedContent in
                reportIfVisible(updatedContent)
            }
    }

    private func reportIfVisible(_ content: String) {
        guard Self.containsVisibleAssistantBodyToken(content) else { return }
        Task { @MainActor in
            onVisibleBodyToken(assistantMessageId)
        }
    }

    private static func containsVisibleAssistantBodyToken(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Do not fade for reasoning/tool details.  Only prose after a completed
        // details envelope is a user-visible assistant body token here.
        if trimmed.hasPrefix("<details") {
            guard let closing = trimmed.range(of: "</details>") else { return false }
            let body = trimmed[closing.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !body.isEmpty
        }
        return true
    }
}

private struct ChatAmbientBackgroundView: View {
    let mode: ChatAmbientBackgroundMode
    let keyboardIsVisible: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeGradientStartedAt = Date()
    @State private var idleFieldStartedAt: Date?

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
        .animation(.easeInOut(duration: 0.65), value: mode)
        .onAppear {
            if mode == .activeFirstTurn {
                activeGradientStartedAt = .now
            }
            beginIdleFieldIfNeeded()
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .activeFirstTurn {
                activeGradientStartedAt = .now
            }
            if newMode != .idleFirstTurn {
                idleFieldStartedAt = nil
            } else {
                beginIdleFieldIfNeeded()
            }
        }
        .onChange(of: keyboardIsVisible) { _, _ in
            beginIdleFieldIfNeeded()
        }
    }

    private var idleGradient: some View {
        Group {
            if reduceMotion {
                idleGradient(at: activeGradientStartedAt)
            } else {
                TimelineView(.animation) { timeline in
                    idleGradient(at: timeline.date)
                }
            }
        }
    }

    /// Before a first message is sent, Gemini's lower colour field stays
    /// behind the raised composer: lime/cyan at entry, then blue while the
    /// keyboard is open. This intentionally colours only the background; the
    /// composer remains the existing native glass component above it.
    private func idleGradient(at date: Date) -> some View {
        let tint = idleTint(at: date)
        let nextTint = idleTint(at: date.addingTimeInterval(0.45))
        let fieldProgress = idleFieldProgress(at: date)

        return LinearGradient(
            colors: [
                Color.clear,
                tint.opacity(theme.isDark ? 0.08 : 0.28),
                tint.opacity(theme.isDark ? 0.18 : 0.78)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottomLeading) {
            RadialGradient(
                colors: [
                    nextTint.opacity(theme.isDark ? 0.12 : 0.34),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 420
            )
        }
        // Gemini's first-screen field is not a flat wash.  A dense layer of
        // coloured scales rises from behind the composer, fading into the
        // quieter cyan/white area above it.
        .overlay {
            GeminiScaleField(
                isDark: theme.isDark,
                progress: fieldProgress,
                time: date.timeIntervalSinceReferenceDate
            )
        }
    }

    private var activeGradient: some View {
        Group {
            if reduceMotion {
                activeGradient(at: activeGradientStartedAt)
            } else {
                TimelineView(.animation) { timeline in
                    activeGradient(at: timeline.date)
                }
            }
        }
    }

    /// Gemini keeps the navigation and composer surfaces neutral while a broad,
    /// softly blurred colour field travels through the waiting conversation.
    /// The palette and timing below are sampled from the supplied full capture:
    /// blue → cyan → green → yellow → coral → pink → violet.
    private func activeGradient(at date: Date) -> some View {
        let tint = activeTint(at: date)
        let nextTint = activeTint(at: date.addingTimeInterval(0.75))
        let topOpacity = theme.isDark ? 0.28 : 0.52
        let middleOpacity = theme.isDark ? 0.20 : 0.34
        let bloomOpacity = theme.isDark ? 0.26 : 0.52

        return GeometryReader { proxy in
            let extent = max(proxy.size.width, proxy.size.height)
            let phase = activePhase(at: date)
            let centerX = 0.42 + 0.14 * sin(phase * .pi * 2)

            ZStack {
                // The reference field occupies the chat canvas, rather than
                // being a glow that is confined behind the composer.  Keep the
                // lower edge lighter, but establish its colour from the top of
                // the transcript as soon as the first response is waiting.
                LinearGradient(
                    colors: [
                        tint.opacity(topOpacity),
                        tint.opacity(middleOpacity),
                        nextTint.opacity(theme.isDark ? 0.16 : 0.22),
                        Color.white.opacity(theme.isDark ? 0.02 : 0.78)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [
                        tint.opacity(bloomOpacity),
                        nextTint.opacity(theme.isDark ? 0.10 : 0.25),
                        Color.clear
                    ],
                    center: UnitPoint(x: centerX, y: 0.28),
                    startRadius: 8,
                    endRadius: extent * 0.82
                )

                RadialGradient(
                    colors: [
                        nextTint.opacity(theme.isDark ? 0.10 : 0.18),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.72, y: 0.62),
                    startRadius: 0,
                    endRadius: extent * 0.62
                )

                // Gemini retains a soft white breathing space above the
                // composer, not a hard horizontal cutoff to the colour field.
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(theme.isDark ? 0.00 : 0.42)
                    ],
                    startPoint: UnitPoint(x: 0.5, y: 0.58),
                    endPoint: .bottom
                )
            }
        }
    }

    private func activeTint(at date: Date) -> Color {
        let elapsed = max(0, date.timeIntervalSince(activeGradientStartedAt))
        let position = elapsed.truncatingRemainder(dividingBy: Self.activeGradientCycle)
        let stops = Self.activeGradientStops

        for index in 0..<(stops.count - 1) {
            let start = stops[index]
            let end = stops[index + 1]
            guard position <= end.time else { continue }

            let rawProgress = (position - start.time) / (end.time - start.time)
            let progress = smoothPaletteProgress(rawProgress)
            return Color(
                red: start.red + (end.red - start.red) * progress,
                green: start.green + (end.green - start.green) * progress,
                blue: start.blue + (end.blue - start.blue) * progress
            )
        }

        guard let finalStop = stops.last else { return .clear }
        return Color(red: finalStop.red, green: finalStop.green, blue: finalStop.blue)
    }

    private func idleTint(at date: Date) -> Color {
        let elapsed = max(0, date.timeIntervalSince(activeGradientStartedAt))
        let position = elapsed.truncatingRemainder(dividingBy: Self.idleGradientCycle)
        let stops = Self.idleGradientStops

        for index in 0..<(stops.count - 1) {
            let start = stops[index]
            let end = stops[index + 1]
            guard position <= end.time else { continue }

            let rawProgress = (position - start.time) / (end.time - start.time)
            let progress = smoothPaletteProgress(rawProgress)
            return Color(
                red: start.red + (end.red - start.red) * progress,
                green: start.green + (end.green - start.green) * progress,
                blue: start.blue + (end.blue - start.blue) * progress
            )
        }

        guard let finalStop = stops.last else { return .clear }
        return Color(red: finalStop.red, green: finalStop.green, blue: finalStop.blue)
    }

    private func activePhase(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(activeGradientStartedAt))
        return elapsed.truncatingRemainder(dividingBy: Self.activeGradientCycle) / Self.activeGradientCycle
    }

    /// The colour-scale lattice belongs to the first idle/keyboard transition,
    /// not to the full waiting response. Start after the keyboard has settled:
    /// the capture keeps it visible through the completed keyboard rise, then
    /// grows in lime, shifts to cyan/blue, and only then contracts.
    private func idleFieldProgress(at date: Date) -> Double {
        guard let idleFieldStartedAt else { return 1 }
        let elapsed = date.timeIntervalSince(idleFieldStartedAt)
        let keyboardSettleDelay: TimeInterval = 0.30
        guard elapsed >= keyboardSettleDelay else { return -1 }
        return (elapsed - keyboardSettleDelay) / 1.50
    }

    private func beginIdleFieldIfNeeded() {
        guard mode == .idleFirstTurn, keyboardIsVisible else { return }
        guard idleFieldStartedAt == nil else { return }
        idleFieldStartedAt = .now
    }

    private func smoothPaletteProgress(_ value: Double) -> Double {
        let progress = min(1, max(0, value))
        return progress * progress * (3 - 2 * progress)
    }

    private struct GeminiGradientStop {
        let time: TimeInterval
        let red: Double
        let green: Double
        let blue: Double
    }

    private static let activeGradientCycle: TimeInterval = 7.20

    private static let idleGradientCycle: TimeInterval = 6.40

    private static let activeGradientStops: [GeminiGradientStop] = [
        GeminiGradientStop(time: 0.00, red: 0.66, green: 0.82, blue: 1.00),
        GeminiGradientStop(time: 0.80, red: 0.28, green: 0.69, blue: 1.00),
        GeminiGradientStop(time: 1.55, red: 0.31, green: 0.81, blue: 0.97),
        GeminiGradientStop(time: 2.35, red: 0.48, green: 0.90, blue: 0.72),
        GeminiGradientStop(time: 3.15, red: 0.80, green: 0.93, blue: 0.47),
        GeminiGradientStop(time: 3.90, red: 1.00, green: 0.90, blue: 0.42),
        GeminiGradientStop(time: 4.75, red: 1.00, green: 0.60, blue: 0.56),
        GeminiGradientStop(time: 5.65, red: 0.90, green: 0.52, blue: 0.92),
        GeminiGradientStop(time: 6.50, red: 0.53, green: 0.45, blue: 0.98),
        GeminiGradientStop(time: 7.20, red: 0.66, green: 0.82, blue: 1.00)
    ]

    private static let idleGradientStops: [GeminiGradientStop] = [
        GeminiGradientStop(time: 0.00, red: 0.72, green: 0.96, blue: 0.70),
        GeminiGradientStop(time: 0.45, red: 0.48, green: 0.91, blue: 0.85),
        GeminiGradientStop(time: 0.90, red: 0.43, green: 0.72, blue: 1.00),
        GeminiGradientStop(time: 2.00, red: 0.48, green: 0.75, blue: 1.00),
        GeminiGradientStop(time: 3.20, red: 0.58, green: 0.79, blue: 1.00),
        GeminiGradientStop(time: 4.30, red: 0.48, green: 0.87, blue: 0.98),
        GeminiGradientStop(time: 5.20, red: 0.62, green: 0.94, blue: 0.83),
        GeminiGradientStop(time: 6.40, red: 0.72, green: 0.96, blue: 0.70)
    ]
}

/// A short-lived, staggered scale lattice that follows the captured idle
/// timeline: grow in lime, sweep to cyan/blue, then contract and vanish before
/// the active first-response gradient begins.
private struct GeminiScaleField: View {
    let isDark: Bool
    let progress: Double
    let time: TimeInterval

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            render(context: &context, size: size)
        }
        .mask(scaleMask)
    }

    private var scaleMask: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.62), .white],
            startPoint: .top,
            endPoint: UnitPoint(x: 0.5, y: 0.70)
        )
    }

    private func render(context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }

        // `progress` is deliberately negative until the keyboard's opening
        // motion has finished. Do not draw a tiny early field below it.
        guard progress >= 0 else { return }
        let grow = smoothStep(progress / 0.36)
        let contract = smoothStep((progress - 0.68) / 0.32)
        let visibility = max(0, 1 - contract)
        guard visibility > 0.001 else { return }
        let fieldTop = size.height * (0.74 - grow * 0.37 + contract * 0.20)
        let fieldHeight = max(1, size.height - fieldTop)
        let rowSpacing: CGFloat = 8.2
        let columnSpacing: CGFloat = 8.6
        let rowCount = Int((fieldHeight / rowSpacing).rounded(.up)) + 1
        let columnCount = Int((size.width / columnSpacing).rounded(.up)) + 2
        let shimmer = 0.5 + 0.5 * sin(time * 1.45)

        for row in 0..<rowCount {
            let y = fieldTop + CGFloat(row) * rowSpacing
            let verticalProgress = Double(min(1, max(0, (y - fieldTop) / fieldHeight)))
            let rowOffset = row.isMultiple(of: 2) ? 0.0 : columnSpacing * 0.5

            for column in 0..<columnCount {
                let x = CGFloat(column) * columnSpacing + rowOffset
                guard x >= -columnSpacing, x <= size.width + columnSpacing else { continue }

                    // A diagonal hue sweep creates the yellow/green → cyan →
                    // blue/purple scales visible in Gemini's composer field.
                let horizontalProgress = Double(min(1, max(0, x / max(size.width, 1))))
                let hue = scaleHue(vertical: verticalProgress, horizontal: horizontalProgress)
                let stagger = 0.5 + 0.5 * sin(Double(row) * 0.61 + Double(column) * 0.38 + time * 1.3)
                let intensity = visibility * (0.30 + verticalProgress * 0.70) * (0.76 + stagger * 0.24)
                let dotRadius = CGFloat(1.08 + intensity * 1.34)
                let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(scaleColour(hue: hue, intensity: intensity, shimmer: shimmer)))
            }
        }
    }

    private func scaleHue(vertical: Double, horizontal: Double) -> Double {
        let colourShift = min(1, max(0, progress / 0.58))
        return 0.25 + colourShift * 0.30 + vertical * 0.06 + horizontal * 0.035
    }

    private func scaleColour(hue: Double, intensity: Double, shimmer: Double) -> Color {
        let alpha = (isDark ? 0.14 : 0.22) + intensity * (isDark ? 0.30 : 0.54)
        return Color(
            hue: hue,
            saturation: isDark ? 0.55 : 0.68,
            brightness: isDark ? 0.88 : 0.95,
            opacity: alpha * (0.88 + shimmer * 0.12)
        )
    }

    private func smoothStep(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

// MARK: - Image Generation Placeholder

/// A media placeholder is driven by the generation protocol's persisted
/// metadata, not by elapsed time. Its moving dot field and image-waiting copy
/// are indeterminate visual feedback; real completion still depends on a media
/// reference being returned and successfully attached to this message.
private struct MediaGenerationPlaceholderView: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: String
    let phase: String
    let title: String
    @State private var isActive = false
    @State private var isExpanded = false

    private var isVideo: Bool { kind == "video" }

    var body: some View {
        lifecycleConfiguredCard
    }

    /// Keep the modifiers in deliberately small opaque subtrees. This card is
    /// used inside the very large chat message renderer; keeping it monolithic
    /// makes Swift's View-builder type solver exceed its reasonable-time limit.
    private var lifecycleConfiguredCard: some View {
        entranceConfiguredCard
            .animation(.easeInOut(duration: 0.22), value: title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .onAppear {
                isActive = scenePhase == .active
                beginCardEntrance()
            }
            .onDisappear {
                isActive = false
                isExpanded = false
            }
            .onChange(of: scenePhase) { _, phase in
                isActive = phase == .active
            }
    }

    private var entranceConfiguredCard: some View {
        layoutConfiguredCard
            // The reference begins as a small, rounded seed at the assistant
            // card's top-leading corner, then grows down/right into the full
            // rendering surface. Scaling the card itself keeps the transcript
            // and its scroll anchors independent from this visual entrance.
            .scaleEffect(isExpanded ? 1 : 0.055, anchor: .topLeading)
            .opacity(isExpanded ? 1 : 0.90)
    }

    private func beginCardEntrance() {
        guard !reduceMotion else {
            isExpanded = true
            return
        }
        isExpanded = false
        DispatchQueue.main.async {
            // Gemini/ChatGPT-style entrance: a continuous, no-bounce scale
            // curve. `.smooth` is available on the app's iOS 18.1 target and
            // avoids the small terminal recoil a damped spring can still show.
            withAnimation(.smooth(duration: 0.40, extraBounce: 0)) {
                isExpanded = true
            }
        }
    }

    private var layoutConfiguredCard: some View {
        decoratedCard
            .aspectRatio(isVideo ? 16.0 / 9.0 : 1.0, contentMode: .fit)
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private var decoratedCard: some View {
        cardLayers
            .overlay {
                cardShape.strokeBorder(
                    Color.white.opacity(theme.isDark ? 0.09 : 0.58),
                    lineWidth: 0.75
                )
            }
            .background {
                cardShape
                    .fill(Color.black.opacity(theme.isDark ? 0.18 : 0.06))
                    .offset(y: 6)
                    .blur(radius: 11)
            }
    }

    private var cardLayers: some View {
        ZStack(alignment: .topLeading) {
            cardBackground
            animatedDots
                .allowsHitTesting(false)
                .clipShape(cardShape)
            cardTitle
        }
        .clipShape(cardShape)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 23, style: .continuous)
    }

    private var cardBackground: some View {
        theme.isDark
            ? Color.white.opacity(0.075)
            : Color(red: 0.955, green: 0.946, blue: 0.962)
    }

    @ViewBuilder
    private var animatedDots: some View {
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                MediaGenerationDotsCanvas(
                    isDark: theme.isDark,
                    isVideo: isVideo,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        } else {
            MediaGenerationDotsCanvas(isDark: theme.isDark, isVideo: isVideo, time: 0.4)
        }
    }

    private var cardTitle: some View {
        MediaGenerationProgressTitle(
            kind: kind,
            phase: phase,
            actualTitle: title
        )
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(theme.isDark ? Color.white.opacity(0.88) : Color.black.opacity(0.72))
            .lineLimit(1)
            .padding(.horizontal, 17)
            .padding(.top, 16)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Transport state remains truthful in `phase`. While a one-shot image API is
/// genuinely waiting, this mirrors the reference's indeterminate ChatGPT
/// status cadence: every segment types in, then holds until the next segment.
/// It does not decide completion; the placeholder is still removed only when a
/// real image reference has been attached to the assistant message.
private struct MediaGenerationProgressTitle: View {
    let kind: String
    let phase: String
    let actualTitle: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phaseStartedAt = Date()

    private static let imageWaitingStages = [
        "正在构思画面",
        "正在构想",
        "正在生成初稿",
        "正在设置场景",
        "润色细节",
        "即将完成",
        "正在进行最终润色"
    ]

    private var usesImageWaitingStoryboard: Bool {
        kind == "image" && phase == "waitingForResult"
    }

    var body: some View {
        Group {
            if usesImageWaitingStoryboard && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Text(storyboardText(at: timeline.date))
                }
            } else if usesImageWaitingStoryboard {
                Text(Self.imageWaitingStages[0])
            } else {
                Text(actualTitle)
            }
        }
        .onAppear { phaseStartedAt = .now }
        .onChange(of: phase) { _, _ in
            phaseStartedAt = .now
        }
    }

    private func storyboardText(at date: Date) -> String {
        let elapsed = max(0, date.timeIntervalSince(phaseStartedAt))
        let stageDuration: TimeInterval = 4.05
        let stageIndex = min(
            Int(elapsed / stageDuration),
            Self.imageWaitingStages.count - 1
        )
        let stageElapsed = elapsed - Double(stageIndex) * stageDuration
        let text = Self.imageWaitingStages[stageIndex]
        let characters = Array(text)
        let revealDuration = max(0.30, min(0.58, Double(characters.count) * 0.075))
        let visibleCount = min(
            characters.count,
            max(1, Int((stageElapsed / revealDuration) * Double(characters.count)))
        )
        return String(characters.prefix(visibleCount))
    }
}

private struct MediaGenerationDotsCanvas: View {
    let isDark: Bool
    let isVideo: Bool
    let time: TimeInterval

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            guard size.width > 1, size.height > 1 else { return }
            let period = isVideo ? 4.8 : 4.2
            let cycle = (time.truncatingRemainder(dividingBy: period) + period) / period
            let focusX = size.width * (0.50 + 0.22 * sin(cycle * .pi * 2.0))
            let focusY = size.height * (0.51 + 0.23 * cos(cycle * .pi * 2.0))
            let tint = isDark
                ? Color(red: 0.82, green: 0.80, blue: 0.89)
                : Color(red: 0.55, green: 0.52, blue: 0.63)
            let columns = isVideo ? 24 : 20
            let rows = isVideo ? 11 : 19
            let horizontalInset = size.width * 0.12
            let verticalInset = size.height * 0.21
            let usableWidth = size.width - horizontalInset * 2
            let usableHeight = size.height - verticalInset * 2

            for row in 0..<rows {
                for column in 0..<columns {
                    let x = horizontalInset + usableWidth * CGFloat(column) / CGFloat(max(columns - 1, 1))
                    let y = verticalInset + usableHeight * CGFloat(row) / CGFloat(max(rows - 1, 1))
                    let dx = Double((x - focusX) / max(size.width, 1))
                    let dy = Double((y - focusY) / max(size.height, 1))
                    let distance = sqrt(dx * dx + dy * dy)
                    let wave = 0.5 + 0.5 * sin(cycle * .pi * 2.0 + Double(row + column) * 0.44)
                    let intensity = max(0, 1 - distance * 3.25) * (0.58 + wave * 0.42)
                    guard intensity > 0.08 else { continue }
                    let radius = CGFloat(0.55 + intensity * 0.95)
                    let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(tint.opacity((isDark ? 0.11 : 0.08) + intensity * (isDark ? 0.32 : 0.28)))
                    )
                }
            }
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

private struct AssistantHeaderRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.985, anchor: .leading)
            .offset(y: appeared || reduceMotion ? 0 : 4)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(.easeOut(duration: 0.24).delay(0.03)) {
                        appeared = true
                    }
                }
            }
    }
}

private struct UserAttachmentRevealModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || appeared || reduceMotion ? 1 : 0)
            .scaleEffect(!enabled || appeared || reduceMotion ? 1 : 0.985, anchor: .trailing)
            .offset(y: !enabled || appeared || reduceMotion ? 0 : 5)
            .onAppear {
                guard enabled, !appeared else {
                    appeared = true
                    return
                }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        appeared = true
                    }
                }
            }
    }
}

private extension View {
    func assistantHeaderReveal() -> some View {
        modifier(AssistantHeaderRevealModifier())
    }

    func userAttachmentReveal(enabled: Bool) -> some View {
        modifier(UserAttachmentRevealModifier(enabled: enabled))
    }
}

private struct StreamingPlainTextTail: View {
    let content: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(content)
            .scaledFont(size: 16, context: .content)
            .foregroundStyle(theme.textPrimary)
            .lineSpacing(3.5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .transaction { $0.animation = nil }
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
    private static let renderCache = AssistantRenderableContentCache()
    let streamingStore: StreamingContentStore
    let message: ChatMessage
    let activeVersionIndex: Int
    /// When set, overrides all other content resolution (used when showing an older user message edit version).
    /// This allows the UI to show the paired AI response for an older user edit WITHOUT creating fake
    /// regeneration versions on the assistant message.
    var contentOverride: String? = nil
    /// Suppressed once real inline agent/tool steps are visible for the message.
    var showEmptyThinkingCapsule: Bool = true
    var keyboardIsVisible: Bool = false
    var visualizationRevealDelayNanoseconds: UInt64 = 120_000_000
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
        let renderableRawContent = Self.localAlpineFinalSummaryDisplayContent(
            rawContent,
            metadata: message.metadata
        )

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
                return Self.safeAssistantRenderableContent(renderableRawContent)
            }
            let signature = assistantRenderableContentSignature(
                rawContent: renderableRawContent,
                sources: effectiveSources,
                baseURL: serverBaseURL
            )
            let cacheKey = message.id + "::" + String(activeVersionIndex)
            if let cached = Self.renderCache.lookup(key: cacheKey, signature: signature) {
                return cached
            }
            let safeRawContent = Self.safeAssistantRenderableContent(renderableRawContent)
            let resolved = Self.resolveRelativeURLs(safeRawContent, baseURL: serverBaseURL)
            let preferDomain = UserDefaults.standard.object(forKey: "citationShowDomain") as? Bool ?? true
            let rendered = Self.preprocessCitations(resolved, sources: effectiveSources, preferDomain: preferDomain)
            Self.renderCache.store(key: cacheKey, signature: signature, value: rendered)
            return rendered
        }()

        let effectiveIsStreaming = isActivelyStreaming || message.isStreaming

        if effectiveIsStreaming && displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                MediaGenerationPlaceholderView(
                    kind: message.metadata?["iexa_media_generation_kind"] ?? "image",
                    phase: message.metadata?["iexa_media_generation_phase"] ?? "waitingForResult",
                    title: message.metadata?["iexa_media_generation_title"] ?? "正在等待图片服务返回"
                )
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
            let liveTail = isActivelyStreaming
                ? Self.safeAssistantRenderableContent(streamingStore.liveTextTail)
                : ""
            let liveTailHasSpecialContent = Self.requiresFullAssistantRouting(liveTail)
            if frozenBoundary > 0 && !liveTailHasSpecialContent {
                let dc = streamingStore.displayContent
                let frozenContent: String = {
                    guard dc.count >= frozenBoundary else { return dc }
                    return Self.safeAssistantRenderableContent(
                        String(dc[..<dc.index(dc.startIndex, offsetBy: frozenBoundary)])
                    )
                }()

                VStack(alignment: .leading, spacing: 0) {
                    // Frozen tool-call segments are stable; reasoning/details are stripped
                    // before rendering so provider HTML never leaks into the transcript.
                    if !frozenContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AssistantMessageContent(
                            content: frozenContent,
                            isStreaming: false,
                            messageEmbeds: message.embeds,
                            localReasoningContent: message.metadata?["iexa_local_reasoning_content"],
                            localReasoningDone: message.metadata?["iexa_local_reasoning_done"] == "true",
                            localStructuredPartsJSON: message.metadata?["iexa_local_content_parts"],
                            authToken: authToken,
                            serverBaseURL: serverBaseURL,
                            apiClient: apiClient
                        )
                    }
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
                                serverBaseURL: serverBaseURL,
                                deferVisualizationRevealUntilKeyboardDismissed: keyboardIsVisible,
                                deferVisualizationRevealDelayNanoseconds: visualizationRevealDelayNanoseconds
                            )
                            if !liveProsTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                streamingLiveTextView(
                                    content: liveProsTail,
                                    authToken: authToken,
                                    serverBaseURL: serverBaseURL
                                )
                            }
                        } else {
                            streamingLiveTextView(
                                content: liveTail,
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

                let canUseProseStreamingRenderer = isActivelyStreaming
                    && !Self.requiresFullAssistantRouting(displayContent)
                    && !Self.containsCodeFence(displayContent)

                if canUseProseStreamingRenderer {
                    let hasFrozenProse = proseFreezeOffset > 0
                        && displayContent.count >= proseFreezeOffset
                    VStack(alignment: .leading, spacing: 0) {
                        if hasFrozenProse {
                            let dc = displayContent
                            let splitIdx = dc.index(dc.startIndex, offsetBy: proseFreezeOffset)
                            let frozenProse = String(dc[..<splitIdx])
                            let liveProse = String(dc[splitIdx...])
                            // Frozen paragraphs: hash changes only when boundary advances (~every 400 chars).
                            StreamingMarkdownView(
                                content: frozenProse,
                                isStreaming: false,
                                authToken: authToken,
                                serverBaseURL: serverBaseURL,
                                deferVisualizationRevealUntilKeyboardDismissed: keyboardIsVisible,
                                deferVisualizationRevealDelayNanoseconds: visualizationRevealDelayNanoseconds
                            )
                            // Live tail: current paragraph only, changes every tick.
                            if !liveProse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                streamingLiveTextView(
                                    content: liveProse,
                                    authToken: authToken,
                                    serverBaseURL: serverBaseURL
                                )
                            }
                        } else {
                            streamingLiveTextView(
                                content: displayContent,
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
                        localReasoningContent: message.metadata?["iexa_local_reasoning_content"],
                        localReasoningDone: message.metadata?["iexa_local_reasoning_done"] == "true",
                        localStructuredPartsJSON: message.metadata?["iexa_local_content_parts"],
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
        guard text.contains("@@@VIZ-START")
            || text.contains("<")
            || text.contains("◁") else {
            return false
        }
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

    @ViewBuilder
    private func streamingLiveTextView(
        content: String,
        authToken: String?,
        serverBaseURL: String?
    ) -> some View {
        if Self.shouldUsePlainStreamingText(content) {
            StreamingPlainTextTail(content: content)
        } else {
            StreamingMarkdownView(
                content: content,
                isStreaming: true,
                authToken: authToken,
                serverBaseURL: serverBaseURL,
                deferVisualizationRevealUntilKeyboardDismissed: keyboardIsVisible,
                deferVisualizationRevealDelayNanoseconds: visualizationRevealDelayNanoseconds
            )
        }
    }

    private static func shouldUsePlainStreamingText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if lower.contains("@@@viz-start")
            || lower.contains("<details")
            || lower.contains("<think")
            || lower.contains("</think")
            || lower.contains("<table")
            || lower.contains("<pre")
            || lower.contains("<code") {
            return false
        }

        let inlineMarkers = ["```", "`", "](", "![", "|", "$$", "\\(", "\\[", "**", "__", "~~"]
        if inlineMarkers.contains(where: { trimmed.contains($0) }) {
            return false
        }

        let blockPrefixes = ["# ", "## ", "### ", "- ", "* ", "> "]
        if blockPrefixes.contains(where: { trimmed.hasPrefix($0) || trimmed.contains("\n\($0)") }) {
            return false
        }

        if trimmed.range(of: #"(^|\n)\d+\.\s"#, options: .regularExpression) != nil {
            return false
        }

        return true
    }

    private func assistantRenderableContentSignature(
        rawContent: String,
        sources: [ChatSourceReference],
        baseURL: String
    ) -> Int {
        var signature = Self.lightweightAssistantRenderSignature(rawContent)
        signature &+= Self.lightweightAssistantRenderSignature(baseURL)
        signature &+= sources.count &* 17
        for source in sources {
            signature &+= Self.lightweightAssistantRenderSignature(source.id ?? "")
            signature &+= Self.lightweightAssistantRenderSignature(source.url ?? "")
            signature &+= Self.lightweightAssistantRenderSignature(source.title ?? "")
        }
        return signature
    }

    private static func lightweightAssistantRenderSignature(_ text: String, sampleBytes: Int = 32) -> Int {
        guard !text.isEmpty else { return 0 }
        var signature = text.utf8.count &* 17
        var head = 0
        for byte in text.utf8.prefix(sampleBytes) {
            head = (head &* 31) &+ Int(byte)
        }
        var tail = 0
        for byte in text.utf8.suffix(sampleBytes) {
            tail = (tail &* 31) &+ Int(byte)
        }
        signature &+= head
        signature &+= tail &* 7
        return signature
    }

    private static func safeAssistantRenderableContent(_ content: String) -> String {
        let withoutReasoning = Self.removingReasoningArtifacts(from: content)
        guard InlineDataPayloadSanitizer.mayContainLargeInlinePayload(withoutReasoning) else {
            return withoutReasoning
        }
        let cleaned = InlineDataPayloadSanitizer.sanitizedDisplayText(withoutReasoning)
        return InlineDataPayloadSanitizer.removingHiddenPayloadArtifacts(from: cleaned)
    }

    private static func removingReasoningArtifacts(from content: String) -> String {
        guard mayContainReasoningMarkup(content) else { return content }
        var cleaned = removingReasoningDetailsBlocks(from: content)
        cleaned = removingTaggedReasoningBlocks(from: cleaned, opening: "<thinking", closing: "</thinking>")
        cleaned = removingTaggedReasoningBlocks(from: cleaned, opening: "<think", closing: "</think>")
        cleaned = removingTaggedReasoningBlocks(from: cleaned, opening: "<reasoning", closing: "</reasoning>")
        cleaned = removingTaggedReasoningBlocks(from: cleaned, opening: "<reason", closing: "</reason>")
        cleaned = removingTaggedReasoningBlocks(from: cleaned, opening: "<thought", closing: "</thought>")
        cleaned = removingTokenReasoningBlocks(from: cleaned, opening: "<|begin_of_thought|>", closing: "<|end_of_thought|>")
        cleaned = removingTokenReasoningBlocks(from: cleaned, opening: "◁think▷", closing: "◁/think▷")
        cleaned = removingOrphanDetailsClosers(from: cleaned)
        return cleaned
            .replacingOccurrences(of: "<|begin_of_thought|>", with: "")
            .replacingOccurrences(of: "<|end_of_thought|>", with: "")
            .replacingOccurrences(of: "◁think▷", with: "")
            .replacingOccurrences(of: "◁/think▷", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mayContainReasoningMarkup(_ content: String) -> Bool {
        guard !content.isEmpty else { return false }
        guard content.contains("<")
            || content.contains("◁")
            || content.contains("|begin_of_thought|")
            || content.contains("|end_of_thought|") else {
            return false
        }
        let lower = content.lowercased()
        return lower.contains("<details")
            || lower.contains("</details")
            || lower.contains("<summary")
            || lower.contains("</summary")
            || lower.contains("<think")
            || lower.contains("<reason")
            || lower.contains("<thought")
            || lower.contains("<|begin_of_thought|>")
            || content.contains("◁think▷")
    }

    private static func removingReasoningDetailsBlocks(from text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        while let openRange = text.range(of: "<details", options: [.caseInsensitive], range: cursor..<text.endIndex) {
            guard let tagEnd = text[openRange.lowerBound...].firstIndex(of: ">") else {
                result += text[cursor..<openRange.lowerBound]
                return result
            }
            let tag = String(text[openRange.lowerBound...tagEnd]).lowercased()
            let isReasoning = tag.contains("reasoning")
                || tag.contains("think")
                || tag.contains("thought")
            if !isReasoning {
                result += text[cursor...tagEnd]
                cursor = text.index(after: tagEnd)
                continue
            }

            result += text[cursor..<openRange.lowerBound]
            let afterTag = text.index(after: tagEnd)
            if let closeRange = text.range(of: "</details>", options: [.caseInsensitive], range: afterTag..<text.endIndex) {
                cursor = closeRange.upperBound
            } else {
                cursor = text.endIndex
                break
            }
        }
        result += text[cursor..<text.endIndex]
        return result
    }

    private static func removingOrphanDetailsClosers(from text: String) -> String {
        var result = text
        var searchStart = result.startIndex

        while searchStart < result.endIndex,
              let closeRange = result.range(
                of: "</details>",
                options: [.caseInsensitive],
                range: searchStart..<result.endIndex
              ) {
            let prefix = result[..<closeRange.lowerBound]
            let lastOpen = prefix.range(of: "<details", options: [.caseInsensitive, .backwards])
            let lastClose = prefix.range(of: "</details>", options: [.caseInsensitive, .backwards])

            if let lastOpen {
                if let lastClose {
                    if lastOpen.lowerBound > lastClose.lowerBound {
                        searchStart = closeRange.upperBound
                        continue
                    }
                } else {
                    searchStart = closeRange.upperBound
                    continue
                }
            }

            let paragraphStart = prefix.range(of: "\n\n", options: .backwards)?.upperBound
                ?? prefix.range(of: "\n", options: .backwards)?.upperBound
                ?? result.startIndex
            result.removeSubrange(paragraphStart..<closeRange.upperBound)
            searchStart = paragraphStart
        }

        return result
            .replacingOccurrences(of: #"</?summary[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingTaggedReasoningBlocks(
        from text: String,
        opening: String,
        closing: String
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        while let openRange = text.range(of: opening, options: [.caseInsensitive], range: cursor..<text.endIndex) {
            result += text[cursor..<openRange.lowerBound]
            if let closeRange = text.range(of: closing, options: [.caseInsensitive], range: openRange.upperBound..<text.endIndex) {
                cursor = closeRange.upperBound
            } else {
                cursor = text.endIndex
                break
            }
        }
        result += text[cursor..<text.endIndex]
        return result
    }

    private static func removingTokenReasoningBlocks(
        from text: String,
        opening: String,
        closing: String
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        while let openRange = text.range(of: opening, range: cursor..<text.endIndex) {
            result += text[cursor..<openRange.lowerBound]
            if let closeRange = text.range(of: closing, range: openRange.upperBound..<text.endIndex) {
                cursor = closeRange.upperBound
            } else {
                cursor = text.endIndex
                break
            }
        }
        result += text[cursor..<text.endIndex]
        return result
    }

    private static func localAlpineFinalSummaryDisplayContent(
        _ content: String,
        metadata: [String: String]?
    ) -> String {
        guard metadata?["iexa_local_alpine_final_summary"] != nil else {
            return content
        }
        let limit = 8_000
        guard content.count > limit else { return content }
        return String(content.prefix(limit))
            + "\n\n...（回复过长，前台显示已截断；完整工具结果保留在本地上下文中。）"
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
        ParsedLocalAlpineResult(content: lightweightParseContent, metadata: metadata)
    }

    private var hasFailure: Bool {
        parsed.hasNonZeroExit
            || commandResults.contains(where: { $0.failed })
            || toolCalls.contains(where: { $0.failed })
    }

    private var lightweightParseContent: String {
        guard writtenFiles.isEmpty,
              commandResults.isEmpty,
              toolCalls.isEmpty else {
            return ""
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 12_000 else { return "" }
        return trimmed
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
        if hasFailure { return .orange }
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

                        Image(systemName: isStreaming ? "terminal" : (hasFailure ? "exclamationmark" : "checkmark"))
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(statusColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(statusText)
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(hasFailure ? .orange : theme.textPrimary)
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
            if call.isRunning && !call.failed {
                AgentRotatingProgressIcon(size: 25, lineWidth: 3)
            } else {
                ZStack {
                    Circle()
                        .fill(tint.opacity(theme.isDark ? 0.20 : 0.13))
                        .frame(width: 25, height: 25)
                    Image(systemName: iconName)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(tint)
                }
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

private struct AgentRotatingProgressIcon: View {
    let size: CGFloat
    let lineWidth: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { timeline in
            let rotation = reduceMotion ? 35 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 0.95) / 0.95 * 360

            ZStack {
                Circle()
                    .fill(theme.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.92))
                    .shadow(color: theme.brandPrimary.opacity(theme.isDark ? 0.22 : 0.16), radius: 3, x: 0, y: 1)

                Circle()
                    .stroke(
                        theme.brandPrimary.opacity(theme.isDark ? 0.16 : 0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .padding(lineWidth / 2)

                Circle()
                    .trim(from: 0.05, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [
                                theme.brandPrimary,
                                Color.purple.opacity(0.95),
                                theme.brandPrimary.opacity(0.18)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .padding(lineWidth / 2)
                    .rotationEffect(.degrees(rotation))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
    let onStopRunningStep: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var leadingSteps: [AgentActivityStep] {
        let limit = 24
        guard item.steps.count > limit else { return item.steps }
        return Array(item.steps.prefix(12))
    }

    private var trailingSteps: [AgentActivityStep] {
        let limit = 24
        guard item.steps.count > limit else { return [] }
        return Array(item.steps.suffix(12))
    }

    private var hiddenMiddleStepCount: Int {
        max(0, item.steps.count - leadingSteps.count - trailingSteps.count)
    }

    private var visibleStepAnimationKey: String {
        (leadingSteps.map(\.id)
            + (hiddenMiddleStepCount > 0 ? ["hidden-\(hiddenMiddleStepCount)"] : [])
            + trailingSteps.map(\.id))
            .joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(leadingSteps, id: \.id) { step in
                stepPill(step)
            }

            if hiddenMiddleStepCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .scaledFont(size: 11, weight: .bold)
                    Text("省略 \(hiddenMiddleStepCount) 个中间步骤")
                        .scaledFont(size: 11, weight: .semibold)
                }
                .foregroundStyle(theme.textTertiary)
                .padding(.leading, 12)
                .transition(stepTransition)
            }

            ForEach(trailingSteps, id: \.id) { step in
                stepPill(step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0), value: visibleStepAnimationKey)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        .accessibilityLabel("步骤")
    }

    @ViewBuilder
    private func stepPill(_ step: AgentActivityStep) -> some View {
        AgentActivityStepPill(
            step: step,
            onStopRunningStep: item.isActive ? onStopRunningStep : nil
        )
        .equatable()
        .transition(stepTransition)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.98, anchor: .topLeading)),
            removal: .opacity
        )
    }
}

private struct AssistantLocalPreviewButton: View {
    let displayText: String
    let onOpen: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Image(systemName: "safari")
                    .scaledFont(size: 12, weight: .semibold)
                Text("打开预览")
                    .scaledFont(size: 12, weight: .semibold)
                Text(displayText)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(theme.brandPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(theme.brandPrimary.opacity(theme.isDark ? 0.18 : 0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(theme.brandPrimary.opacity(theme.isDark ? 0.24 : 0.20), lineWidth: 0.7)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct AgentStepFloatingBarHost: View {
    let conversationId: String?
    let fallbackItem: AgentActivityItem?
    let liveBrowserThumbnailReference: String?
    let onPreviewTap: (AgentActivityItem, Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayItem: AgentActivityItem? {
        fallbackItem?.hasConcreteSteps == true ? fallbackItem : nil
    }

    private var displayAnimationKey: String {
        guard let displayItem else { return "none" }
        return "\(displayItem.id)|\(displayItem.currentStep?.id ?? "")|\(displayItem.totalStepCount)|\(displayItem.hasFailure)"
    }

    var body: some View {
        Group {
            if let item = displayItem {
                AgentStepFloatingBar(
                    item: item,
                    taskCount: item.totalStepCount,
                    liveBrowserThumbnailReference: liveBrowserThumbnailReference,
                    onPreviewTap: onPreviewTap
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
                .transition(floatingBarTransition)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0), value: displayAnimationKey)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }

    private var floatingBarTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.985, anchor: .bottom)),
            removal: .opacity
        )
    }
}

private enum AgentStepFloatingMetrics {
    static let previewSize = CGSize(width: 86, height: 54)
    static let previewCornerRadius: CGFloat = 8
    static let previewOffset = CGSize(width: 6, height: 0)
    static let barHeight: CGFloat = 34
    static let barCornerRadius: CGFloat = 13
    static let barLeadingInset: CGFloat = 98
    static let layoutHeight: CGFloat = 39
}

private struct AgentStepFloatingBar: View {
    let item: AgentActivityItem
    let taskCount: Int
    let liveBrowserThumbnailReference: String?
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

    private var previewDiffLines: [LocalAlpineFileDiffLine] {
        guard let file = selectedStep?.file else { return [] }
        return Array(file.diffPreviewLines.prefix(5))
    }

    private var previewThumbnailReference: String? {
        let liveBrowser = liveBrowserThumbnailReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBrowserStep = (selectedStep?.isInteractiveBrowserStatusStep == true) || item.hasInteractiveBrowserStatusSteps
        if liveBrowser?.isEmpty == false,
           isBrowserStep {
            return liveBrowser
        }
        let selected = selectedStep?.previewThumbnailReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        if selected?.isEmpty == false {
            return selected
        }
        guard let selectedStep else {
            return item.firstPreviewThumbnailReference
        }
        let hasLocalPayload =
            selectedStep.file != nil
            || selectedStep.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || selectedStep.outputReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !hasLocalPayload else {
            return nil
        }
        if let current = item.currentStep?.previewThumbnailReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty {
            return current
        }
        return item.firstPreviewThumbnailReference
    }

    private var selectedTitle: String {
        selectedStep?.title ?? item.currentStepTitle
    }

    private var canMoveBackward: Bool {
        clampedIndex > 0
    }

    private var canMoveForward: Bool {
        clampedIndex < item.steps.count - 1
    }

    private var barFill: Color {
        theme.cardBackground.opacity(theme.isDark ? 0.90 : 0.98)
    }

    private var barStroke: Color {
        theme.cardBorder.opacity(theme.isDark ? 0.18 : 0.18)
    }

    private var barShadow: Color {
        .black.opacity(theme.isDark ? 0.18 : 0.08)
    }

    private var statusDot: AnyView {
        let isRunning = selectedStep?.isRunning == true
        let dotTint: Color = tint
        if isRunning {
            return AnyView(AgentRotatingProgressIcon(size: 17, lineWidth: 2.2))
        }
        return AnyView(
            ZStack {
                Circle()
                    .fill(dotTint.opacity(theme.isDark ? 0.16 : 0.12))
                    .frame(width: 17, height: 17)
                Image(systemName: icon)
                    .scaledFont(size: 9.5, weight: .bold)
                    .foregroundStyle(dotTint)
                    .frame(width: 13, height: 13)
            }
            .accessibilityHidden(true)
        )
    }

    private var pageControls: AnyView {
        AnyView(HStack(spacing: 0) {
            Button {
                movePage(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .scaledFont(size: 9.5, weight: .bold)
                    .foregroundStyle(canMoveBackward ? theme.textPrimary : theme.textTertiary.opacity(0.42))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveBackward)

            Text(pageText)
                .scaledFont(size: 10, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 36, alignment: .center)

            Button {
                movePage(1)
            } label: {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9.5, weight: .bold)
                    .foregroundStyle(canMoveForward ? theme.textPrimary : theme.textTertiary.opacity(0.42))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveForward)
        })
    }

    private var floatingBarBody: AnyView {
        AnyView(HStack(spacing: 6) {
            statusDot

            Text(selectedTitle)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.80)
                .layoutPriority(1)

            Spacer(minLength: 2)
            pageControls
        }
        .padding(.leading, AgentStepFloatingMetrics.barLeadingInset)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .frame(height: AgentStepFloatingMetrics.barHeight, alignment: .center)
        .frame(maxWidth: .infinity)
        .background(barFill)
        .clipShape(RoundedRectangle(cornerRadius: AgentStepFloatingMetrics.barCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AgentStepFloatingMetrics.barCornerRadius, style: .continuous)
                .strokeBorder(barStroke, lineWidth: 0.8)
        )
        .shadow(color: barShadow, radius: 5, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: AgentStepFloatingMetrics.barCornerRadius, style: .continuous)))
    }

    private var previewCardButton: AnyView {
        AnyView(
            Button {
                onPreviewTap(item, clampedIndex)
            } label: {
                AgentToolPreviewPop(
                    previewTitle: previewTitle,
                    previewSubtitle: previewSubtitle,
                    previewText: previewText,
                    diffLines: previewDiffLines,
                    thumbnailReference: previewThumbnailReference
                )
                .frame(
                    width: AgentStepFloatingMetrics.previewSize.width,
                    height: AgentStepFloatingMetrics.previewSize.height,
                    alignment: .topLeading
                )
                .clipShape(RoundedRectangle(cornerRadius: AgentStepFloatingMetrics.previewCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: AgentStepFloatingMetrics.previewCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .offset(
                x: AgentStepFloatingMetrics.previewOffset.width,
                y: AgentStepFloatingMetrics.previewOffset.height
            )
        )
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

    var body: AgentStepFloatingBarLayout {
        AgentStepFloatingBarLayout(
            floatingBarBody: floatingBarBody,
            previewCardButton: previewCardButton,
            taskCount: taskCount,
            itemId: item.id,
            currentStepIndex: item.currentStepIndex,
            stepCount: item.steps.count,
            selectedIndex: $selectedIndex
        )
    }
}

private struct AgentStepFloatingBarLayout: View {
    let floatingBarBody: AnyView
    let previewCardButton: AnyView
    let taskCount: Int
    let itemId: String
    let currentStepIndex: Int
    let stepCount: Int
    @Binding var selectedIndex: Int

    private var syncedIndex: Int {
        min(max(0, currentStepIndex - 1), max(0, stepCount - 1))
    }

    var body: AnyView {
        AnyView(
            ZStack(alignment: .bottomLeading) {
                floatingBarBody
                previewCardButton
            }
            .frame(height: AgentStepFloatingMetrics.layoutHeight, alignment: .bottom)
            .onAppear {
                selectedIndex = syncedIndex
            }
            .onChange(of: itemId) { _, _ in
                selectedIndex = syncedIndex
            }
            .onChange(of: currentStepIndex) { _, _ in
                selectedIndex = syncedIndex
            }
            .onChange(of: stepCount) { _, _ in
                selectedIndex = syncedIndex
            }
            .accessibilityLabel("步骤 \(taskCount)")
        )
    }
}

private struct AgentToolPreviewPop: View {
    let previewTitle: String
    let previewSubtitle: String
    let previewText: String
    let diffLines: [LocalAlpineFileDiffLine]
    let thumbnailReference: String?

    private let previewSize = AgentStepFloatingMetrics.previewSize
    private let cornerRadius = AgentStepFloatingMetrics.previewCornerRadius

    private var hasThumbnail: Bool {
        thumbnailReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let thumbnailReference,
               !thumbnailReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AgentToolPreviewThumbnail(reference: thumbnailReference)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .mask(Rectangle().frame(width: previewSize.width, height: previewSize.height))
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.72),
                                Color.black.opacity(0.40),
                                Color.black.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.90))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(previewTitle)
                    .font(.system(size: 6.1, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                Text(previewSubtitle)
                    .font(.system(size: 5.1, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)

                if !hasThumbnail, !diffLines.isEmpty {
                    AgentToolPreviewMiniDiff(lines: diffLines)
                } else if !hasThumbnail {
                    Text(previewText)
                        .font(.system(size: 5.0, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.30, green: 0.63, blue: 1.0))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                AgentToolResourceFooter(compact: true)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
        }
        .frame(width: previewSize.width, height: previewSize.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct AgentToolPreviewMiniDiff: View {
    let lines: [LocalAlpineFileDiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.prefix(5).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 2) {
                    Text(lineNumberText(for: line))
                        .font(.system(size: 4.8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 11, alignment: .trailing)
                    Text(prefix(for: line))
                        .font(.system(size: 5.4, weight: .bold, design: .monospaced))
                        .foregroundStyle(foreground(for: line))
                        .frame(width: 4, alignment: .center)
                    Text(String(line.text.prefix(54)))
                        .font(.system(size: 5.4, weight: .semibold, design: .monospaced))
                        .foregroundStyle(foreground(for: line))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 2)
                .frame(height: 6.4, alignment: .center)
                .background(background(for: line), in: RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineNumberText(for line: LocalAlpineFileDiffLine) -> String {
        let number = line.newLineNumber ?? line.oldLineNumber
        guard let number else { return "" }
        return String(number)
    }

    private func prefix(for line: LocalAlpineFileDiffLine) -> String {
        switch line.kind {
        case .added:
            return "+"
        case .deleted:
            return "-"
        case .context:
            return " "
        }
    }

    private func foreground(for line: LocalAlpineFileDiffLine) -> Color {
        switch line.kind {
        case .added:
            return Color(red: 0.38, green: 0.95, blue: 0.57)
        case .deleted:
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .context:
            return Color(red: 0.72, green: 0.78, blue: 0.86)
        }
    }

    private func background(for line: LocalAlpineFileDiffLine) -> Color {
        switch line.kind {
        case .added:
            return Color.green.opacity(0.18)
        case .deleted:
            return Color.red.opacity(0.18)
        case .context:
            return Color.white.opacity(0.035)
        }
    }
}

private struct AgentToolPreviewThumbnail: View {
    let reference: String

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            thumbnailContent(size: size)
                .frame(width: size.width, height: size.height)
                .clipped()
        }
        .contentShape(Rectangle())
        .clipped()
    }

    @ViewBuilder
    private func thumbnailContent(size: CGSize) -> some View {
        if let webTarget = agentToolWebPreviewTarget(from: reference) {
            AgentToolPreviewWebThumbnail(target: webTarget)
                .frame(width: size.width, height: size.height)
        } else if let image = Self.localImage(from: reference) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
        } else if let url = URL(string: reference),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            FallbackCachedAsyncImage(urls: [url], targetPixelSize: 220) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
            } placeholder: {
                fallback
                    .frame(width: size.width, height: size.height)
            }
        } else {
            fallback
                .frame(width: size.width, height: size.height)
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.08),
                    Color(red: 0.10, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "photo")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
        }
    }

    private static func localImage(from reference: String) -> UIImage? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:image/"),
           let comma = trimmed.firstIndex(of: ",") {
            let encoded = String(trimmed[trimmed.index(after: comma)...])
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters).flatMap(UIImage.init(data:))
        }
        if let url = URL(string: trimmed), url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }
        if FileManager.default.fileExists(atPath: trimmed) {
            return UIImage(contentsOfFile: trimmed)
        }
        return nil
    }
}

private struct AgentToolPreviewWebThumbnail: View {
    let target: String

    @State private var resolvedURL: URL?
    @State private var failed = false

    var body: some View {
        ZStack {
            fallback
            if let resolvedURL {
                AgentToolPreviewWebThumbnailView(url: resolvedURL)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "safari")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.55)
                    .tint(.white.opacity(0.72))
            }
        }
        .task(id: target) {
            await resolveTarget()
        }
    }

    private var fallback: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.08),
                Color(red: 0.10, green: 0.12, blue: 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @MainActor
    private func resolveTarget() async {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failed = true
            resolvedURL = nil
            return
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) {
            resolvedURL = url
            failed = false
            return
        }

        do {
            let url = try await LocalAlpineTerminalService.shared.materializePreviewURL(
                for: LocalAlpineOpenRequest(target: trimmed)
            )
            resolvedURL = url
            failed = false
        } catch {
            resolvedURL = nil
            failed = true
        }
    }
}

private struct AgentToolPreviewWebThumbnailView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.isUserInteractionEnabled = false
        webView.allowsLinkPreview = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8))
        }
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}

private struct AgentToolResourceFooter: View {
    let compact: Bool

    @State private var snapshot = AgentToolResourceSnapshot.current()

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            Text("CPU \(snapshot.cpuText)")
            Text("MEM \(snapshot.memoryText)")
        }
        .font(.system(size: compact ? 4.4 : 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(compact ? 0.52 : 0.66))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: alignment)
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            snapshot = AgentToolResourceSnapshot.current()
        }
    }

    private var alignment: Alignment {
        compact ? .leading : .trailing
    }
}

private struct AgentToolResourceSnapshot: Equatable {
    let cpuPercent: Double
    let residentBytes: UInt64
    let totalBytes: UInt64

    var cpuText: String {
        "\(Int(cpuPercent.rounded()))%"
    }

    var memoryText: String {
        "\(Self.memoryText(residentBytes))/\(Self.memoryText(totalBytes))"
    }

    static func current() -> AgentToolResourceSnapshot {
        AgentToolResourceSnapshot(
            cpuPercent: currentProcessCPUUsage(),
            residentBytes: currentResidentMemoryBytes(),
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private static func memoryText(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576.0
        return "\(Int(mb.rounded())) MB"
    }

    private static func currentResidentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    private static func currentProcessCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        var totalUsage: Double = 0
        for index in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info_data_t()
            var threadInfoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let infoResult = withUnsafeMutablePointer(to: &threadInfo) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) { reboundPointer in
                    thread_info(
                        threadList[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        reboundPointer,
                        &threadInfoCount
                    )
                }
            }
            guard infoResult == KERN_SUCCESS else { continue }
            guard (threadInfo.flags & TH_FLAGS_IDLE) == 0 else { continue }
            totalUsage += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }
        return min(max(totalUsage, 0), 999)
    }
}

private struct AgentActivityStepPill: View, Equatable {
    let step: AgentActivityStep
    let onStopRunningStep: (() -> Void)?

    @Environment(\.theme) private var theme

    static func == (lhs: AgentActivityStepPill, rhs: AgentActivityStepPill) -> Bool {
        lhs.step.id == rhs.step.id
            && lhs.step.kind == rhs.step.kind
            && lhs.step.title == rhs.step.title
            && lhs.step.isRunning == rhs.step.isRunning
            && lhs.step.failed == rhs.step.failed
            && lhs.step.durationText == rhs.step.durationText
            && lhs.step.durationStartedAt == rhs.step.durationStartedAt
            && (lhs.onStopRunningStep != nil) == (rhs.onStopRunningStep != nil)
    }

    private var tint: Color {
        if step.failed { return .orange }
        return step.isRunning ? theme.brandPrimary : theme.success
    }

    private var iconName: String {
        if step.failed { return "exclamationmark.circle.fill" }
        let title = step.title.lowercased()
        if title.contains("搜索") || title.contains("网页") || title.contains("browse") || title.contains("search") {
            return "globe"
        }
        if title.contains("读取") || title.contains("read") {
            return "doc.text"
        }
        if title.contains("编辑") || title.contains("写入") || title.contains("创建") {
            return "square.and.pencil"
        }
        if title.contains("打开") || title.contains("预览") || title.contains("open") {
            return "eye"
        }
        if title.contains("命令") || title.contains("脚本") || title.contains("shell") || title.contains("terminal") || title.contains("run") {
            return "terminal.fill"
        }
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

    private func displayDurationText(asOf date: Date) -> String {
        if step.isRunning, let startedAt = step.durationStartedAt {
            return Self.formattedDuration(seconds: date.timeIntervalSince(startedAt))
        }
        return step.durationText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func formattedDuration(seconds: TimeInterval) -> String {
        guard seconds >= 0.05 else { return "" }
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        let minutes = Int(seconds / 60)
        let remaining = Int(seconds) % 60
        return "\(minutes)m \(remaining)s"
    }

    private func durationLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
    }

    var body: some View {
        let fill = theme.surfaceContainerHighest.opacity(theme.isDark ? 0.22 : 0.58)
        let canStop = step.isRunning && onStopRunningStep != nil

        HStack(spacing: 8) {
            if step.isRunning && !step.failed {
                AgentRotatingProgressIcon(size: 17, lineWidth: 2.2)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 17, height: 17)
            }

            Text(step.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if step.isRunning, step.durationStartedAt != nil {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    let duration = displayDurationText(asOf: timeline.date)
                    if !duration.isEmpty {
                        durationLabel(duration)
                    }
                }
            } else {
                let duration = displayDurationText(asOf: .now)
                if !duration.isEmpty {
                    durationLabel(duration)
                }
            }

            if canStop {
                Button {
                    Haptics.play(.medium)
                    onStopRunningStep?()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.red.opacity(theme.isDark ? 0.22 : 0.16))
                            .frame(width: 17, height: 17)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.red)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止当前步骤")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, canStop ? 8 : 12)
        .frame(height: 34)
        .background(fill, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.20 : 0.24), lineWidth: 0.6)
        )
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 360, alignment: .leading)
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
                        wrapLines: false
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

private struct LocalAlpineLazyFilePreview: View {
    let path: String
    let fileName: String?
    let language: String?
    let fallbackLines: [String]
    let byteCount: Int?

    @Environment(\.theme) private var theme
    @State private var loadedCode: String?
    @State private var loadedByteCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var displayName: String {
        let trimmed = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return (path as NSString).lastPathComponent
    }

    private var displayCode: String {
        if let loadedCode { return loadedCode }
        let fallback = fallbackLines
            .map { $0.trimmingCharacters(in: .newlines) }
        return fallback.isEmpty ? path : fallback.joined(separator: "\n")
    }

    private var displayByteCount: Int? {
        loadedByteCount ?? byteCount
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading && loadedCode == nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取完整文件...")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(18)
            }
            if let errorMessage, loadedCode == nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }
            SourceCodeTextView(
                code: displayCode,
                language: language,
                maxHeight: 1_200,
                wrapLines: false
            )
            Divider()
            footer
        }
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.34 : 0.55), lineWidth: 0.7)
        )
        .task(id: path) {
            await loadFullFileIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(theme.textSecondary)
            Text(displayName)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let displayByteCount {
                Text("(\(displayByteCount) B)")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
            if loadedCode != nil {
                Text("完整")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(theme.success)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.42 : 0.72))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(theme.textTertiary)
            Text(path)
                .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let language,
               !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(language)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
    }

    private func loadFullFileIfNeeded() async {
        let shouldLoad = await MainActor.run { () -> Bool in
            guard !isLoading, loadedCode == nil else { return false }
            isLoading = true
            errorMessage = nil
            return true
        }
        guard shouldLoad else { return }

        do {
            let data = try await LocalAlpineTerminalService.shared.readFile(path: path)
            let content = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            await MainActor.run {
                loadedCode = content.isEmpty ? " " : content
                loadedByteCount = data.count
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "无法读取完整文件，正在显示步骤预览"
                isLoading = false
            }
        }
    }
}

private struct LocalAlpineFullTerminalOutputPreview: View {
    let path: String
    let command: String
    let fallbackOutput: String
    let isRunning: Bool
    let byteCount: Int?

    @Environment(\.theme) private var theme
    @State private var loadedOutput: String?
    @State private var loadedByteCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var output: String {
        if let loadedOutput { return loadedOutput }
        return fallbackOutput
    }

    private var terminalText: String {
        var lines: [String] = []
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCommand.isEmpty {
            lines.append("$ \(trimmedCommand)")
        }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutput.isEmpty {
            lines.append(trimmedOutput)
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading && loadedOutput == nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取完整终端输出...")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }

            if let errorMessage, loadedOutput == nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }

            AgentLazyOutputPreview(
                text: terminalText.isEmpty ? "（无输出）" : terminalText,
                style: .terminal,
                isRunning: isRunning
            )

            HStack(spacing: 8) {
                Image(systemName: loadedOutput == nil ? "doc.text" : "checkmark.circle.fill")
                    .foregroundStyle(loadedOutput == nil ? theme.textTertiary : theme.success)
                Text(path)
                    .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let count = loadedByteCount ?? byteCount {
                    Text("\(count) B")
                        .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: path) {
            await loadFullOutputIfNeeded()
        }
    }

    private func loadFullOutputIfNeeded() async {
        let shouldLoad = await MainActor.run { () -> Bool in
            guard !isLoading, loadedOutput == nil else { return false }
            isLoading = true
            errorMessage = nil
            return true
        }
        guard shouldLoad else { return }

        do {
            let data = try await LocalAlpineTerminalService.shared.readFile(path: path)
            let content = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            await MainActor.run {
                loadedOutput = content.isEmpty ? " " : content
                loadedByteCount = data.count
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "无法读取完整输出，正在显示前台预览"
                isLoading = false
            }
        }
    }
}

private struct AgentFloatingStepPreviewItem: Identifiable, Hashable {
    let id = UUID()
    let activity: AgentActivityItem
    let initialIndex: Int
}

private struct LocalAlpineDiffPreviewView: View {
    let file: LocalAlpineWrittenFile

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.diffPreviewLines.enumerated()), id: \.offset) { _, line in
                    diffLine(line)
                }
            }
            .padding(.vertical, 8)
            .background(Color.black.opacity(theme.isDark ? 0.32 : 0.04))
        }
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.34 : 0.55), lineWidth: 0.7)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(theme.textSecondary)
            Text(file.fileName)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("修改片段")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(theme.success)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.42 : 0.72))
    }

    private func diffLine(_ line: LocalAlpineFileDiffLine) -> some View {
        HStack(spacing: 8) {
            Text(lineNumberText(for: line))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 42, alignment: .trailing)
            Text(prefix(for: line))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(foreground(for: line))
                .frame(width: 12, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(foreground(for: line))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 24, alignment: .center)
        .background(background(for: line))
    }

    private func lineNumberText(for line: LocalAlpineFileDiffLine) -> String {
        let number = line.newLineNumber ?? line.oldLineNumber
        return number.map { "\($0)" } ?? ""
    }

    private func prefix(for line: LocalAlpineFileDiffLine) -> String {
        switch line.kind {
        case .added:
            return "+"
        case .deleted:
            return "-"
        case .context:
            return " "
        }
    }

    private func foreground(for line: LocalAlpineFileDiffLine) -> Color {
        switch line.kind {
        case .added:
            return theme.success
        case .deleted:
            return .red
        case .context:
            return theme.textSecondary
        }
    }

    private func background(for line: LocalAlpineFileDiffLine) -> Color {
        switch line.kind {
        case .added:
            return Color.green.opacity(theme.isDark ? 0.15 : 0.10)
        case .deleted:
            return Color.red.opacity(theme.isDark ? 0.16 : 0.10)
        case .context:
            return Color.clear
        }
    }
}

private struct AgentFloatingStepPreviewSheet: View {
    let item: AgentFloatingStepPreviewItem
    let liveActivity: AgentActivityItem?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var selectedIndex: Int
    @State private var copied = false

    init(item: AgentFloatingStepPreviewItem, liveActivity: AgentActivityItem?) {
        self.item = item
        self.liveActivity = liveActivity
        let maxIndex = max(0, item.activity.steps.count - 1)
        _selectedIndex = State(initialValue: min(max(item.initialIndex, 0), maxIndex))
    }

    private var activity: AgentActivityItem {
        guard let liveActivity,
              liveActivity.hasConcreteSteps,
              liveActivity.id == item.activity.id || liveActivity.steps.contains(where: { liveStep in
                  item.activity.steps.contains(where: { $0.id == liveStep.id })
              })
        else {
            return item.activity
        }
        return liveActivity
    }

    private var steps: [AgentActivityStep] {
        activity.steps
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
        .onChange(of: steps.count) { _, count in
            selectedIndex = min(max(selectedIndex, 0), max(count - 1, 0))
        }
    }

    private var title: String {
        "Iexa 电脑"
    }

    private var previewArea: some View {
        Group {
            if let step = selectedStep {
                ScrollViewReader { proxy in
                    ScrollView {
                        stepPreview(step)
                            .padding(16)
                        Color.clear
                            .frame(height: 1)
                            .id("agent-terminal-preview-bottom")
                    }
                    .onAppear {
                        scrollPreviewToBottom(proxy)
                    }
                    .onChange(of: previewScrollSignature) { _, _ in
                        guard selectedStep?.isRunning == true else { return }
                        scrollPreviewToBottom(proxy)
                    }
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
        if step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           let outputReference = step.outputReference?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !outputReference.isEmpty {
            LocalAlpineFullTerminalOutputPreview(
                path: outputReference,
                command: step.command ?? "",
                fallbackOutput: outputText(for: step),
                isRunning: step.isRunning,
                byteCount: step.outputByteCount
            )
        } else if step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            terminalPreview(step)
        } else if let file = step.file {
            filePreview(file)
        } else if let outputReference = step.outputReference?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !outputReference.isEmpty {
            LocalAlpineLazyFilePreview(
                path: outputReference,
                fileName: (outputReference as NSString).lastPathComponent,
                language: "text",
                fallbackLines: outputText(for: step).components(separatedBy: .newlines),
                byteCount: step.outputByteCount
            )
        } else if let path = lazyPreviewPath(for: step) {
            LocalAlpineLazyFilePreview(
                path: path,
                fileName: (path as NSString).lastPathComponent,
                language: LocalCodeWriteGuard.language(forPath: path),
                fallbackLines: outputText(for: step).components(separatedBy: .newlines),
                byteCount: nil
            )
        } else {
            textPreview(step)
        }
    }

    @ViewBuilder
    private func filePreview(_ file: LocalAlpineWrittenFile) -> some View {
        if !file.diffPreviewLines.isEmpty {
            LocalAlpineDiffPreviewView(file: file)
        } else {
            LocalAlpineLazyFilePreview(
                path: file.path,
                fileName: file.fileName,
                language: file.language,
                fallbackLines: file.previewLines(limit: 120),
                byteCount: file.byteCount
            )
        }
    }

    private func lazyPreviewPath(for step: AgentActivityStep) -> String? {
        let normalizedName = step.title.lowercased()
        let toolLooksLikeFileRead = normalizedName.contains("读取")
            || normalizedName.contains("read")
            || normalizedName.contains("file")
        guard toolLooksLikeFileRead else { return nil }
        return step.filePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func terminalPreview(_ step: AgentActivityStep) -> some View {
        AgentLazyOutputPreview(
            text: terminalText(for: step),
            style: .terminal,
            isRunning: step.isRunning
        )
    }

    private func textPreview(_ step: AgentActivityStep) -> some View {
        let text = copyText(for: step)
        return AgentLazyOutputPreview(
            text: text.isEmpty ? "（无内容）" : text,
            style: .plain
        )
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

    private var previewScrollSignature: Int {
        guard let step = selectedStep else { return 0 }
        var signature = step.id.hashValue
        signature &+= step.isRunning ? 31 : 7
        signature &+= step.outputPreview.hashValue
        signature &+= (step.fullOutput ?? "").hashValue
        signature &+= (step.outputReference ?? "").hashValue
        return signature
    }

    private func scrollPreviewToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("agent-terminal-preview-bottom", anchor: .bottom)
            }
        }
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

    private func outputText(for step: AgentActivityStep) -> String {
        let full = step.fullOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !full.isEmpty {
            return full
        }
        return step.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func terminalText(for step: AgentActivityStep) -> String {
        var lines: [String] = []
        if let command = step.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            lines.append("$ \(command)")
        }
        let output = outputText(for: step)
        if !output.isEmpty {
            lines.append(output)
        }
        return lines.joined(separator: "\n")
    }

    private func copyText(for step: AgentActivityStep?) -> String {
        guard let step else { return "" }
        if let file = step.file {
            if !file.diffPreviewLines.isEmpty {
                return diffCopyText(for: file)
            }
            return file.previewLines(limit: 120).joined(separator: "\n")
        }
        if step.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return terminalText(for: step)
        }
        let output = outputText(for: step)
        return output.isEmpty
            ? step.detail
            : output
    }

    private func diffCopyText(for file: LocalAlpineWrittenFile) -> String {
        var lines = ["# \(file.path)"]
        lines.append(contentsOf: file.diffPreviewLines.map { line in
            let prefix: String
            switch line.kind {
            case .added:
                prefix = "+"
            case .deleted:
                prefix = "-"
            case .context:
                prefix = " "
            }
            let number = line.newLineNumber ?? line.oldLineNumber
            let numberText = number.map(String.init) ?? ""
            return "\(numberText)\t\(prefix)\(line.text)"
        })
        return lines.joined(separator: "\n")
    }
}

private struct AgentLazyOutputPreview: View {
    enum Style {
        case terminal
        case plain
    }

    let lines: [String]
    let style: Style
    let isRunning: Bool

    @Environment(\.theme) private var theme

    init(text: String, style: Style, isRunning: Bool = false) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lines = Self.softWrappedLines(normalized.isEmpty ? "（无内容）" : normalized)
        self.style = style
        self.isRunning = isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isTerminal ? 9 : 2) {
            if isTerminal {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isRunning ? Color.green : Color.white.opacity(0.42))
                            .frame(width: 6, height: 6)
                        Text(isRunning ? "实时" : "完成")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.74))
                    }

                    Spacer(minLength: 8)

                    AgentToolResourceFooter(compact: false)
                        .frame(maxWidth: 210, alignment: .trailing)
                }
            }

            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(font)
                        .foregroundStyle(foreground)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(style == .terminal ? 18 : 16)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var isTerminal: Bool {
        if case .terminal = style { return true }
        return false
    }

    private var font: Font {
        switch style {
        case .terminal:
            return .system(size: 13, weight: .semibold, design: .monospaced)
        case .plain:
            return .system(size: 14, weight: .regular, design: .monospaced)
        }
    }

    private var foreground: Color {
        switch style {
        case .terminal:
            return Color(red: 0.32, green: 0.86, blue: 0.45)
        case .plain:
            return theme.textPrimary
        }
    }

    private var background: Color {
        switch style {
        case .terminal:
            return .black
        case .plain:
            return theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.98)
        }
    }

    private static func softWrappedLines(_ text: String, maxLineLength: Int = 240) -> [String] {
        var rendered: [String] = []
        rendered.reserveCapacity(min(text.count / 48 + 1, 512))

        for rawLine in text.components(separatedBy: .newlines) {
            guard !rawLine.isEmpty else {
                rendered.append(" ")
                continue
            }

            var start = rawLine.startIndex
            while start < rawLine.endIndex {
                let end = rawLine.index(start, offsetBy: maxLineLength, limitedBy: rawLine.endIndex)
                    ?? rawLine.endIndex
                rendered.append(String(rawLine[start..<end]))
                start = end
            }
        }

        return rendered.isEmpty ? ["（无内容）"] : rendered
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
            .mask {
                if shouldCollapse && !isExpanded {
                    collapsedTextMask
                } else {
                    Rectangle().fill(.white)
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

    private var collapsedTextMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0.0),
                .init(color: .white, location: 0.68),
                .init(color: .white.opacity(0.82), location: 0.82),
                .init(color: .clear, location: 1.0)
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

private struct OfficeAttachmentThumbnail: View {
    let reference: String?
    let fallbackIcon: String
    let pageCount: Int

    @Environment(\.theme) private var theme
    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.surfaceContainerHighest.opacity(0.92),
                                    theme.surfaceContainer.opacity(0.70)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Image(systemName: fallbackIcon)
                                .scaledFont(size: 24, weight: .semibold)
                                .foregroundStyle(theme.textTertiary.opacity(0.72))
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if pageCount > 1 {
                Text("\(pageCount)")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(6)
            }
        }
        .background(theme.surfaceContainerHighest.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.36), lineWidth: 0.5)
        )
        .task(id: reference ?? "") {
            guard !didAttemptLoad || image == nil else { return }
            didAttemptLoad = true
            image = await Self.loadImage(from: reference)
        }
    }

    private struct LoadedImage: @unchecked Sendable {
        let image: UIImage
    }

    private static func loadImage(from reference: String?) async -> UIImage? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else {
            return nil
        }

        if reference.hasPrefix("data:image/"),
           let comma = reference.firstIndex(of: ",") {
            let encoded = String(reference[reference.index(after: comma)...])
            let loaded = await Task.detached(priority: .utility) {
                Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
                    .flatMap(UIImage.init(data:))
                    .map { LoadedImage(image: $0) }
            }.value
            return loaded?.image
        }

        if let url = URL(string: reference), url.isFileURL {
            let loaded = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path).map { LoadedImage(image: $0) }
            }.value
            return loaded?.image
        }

        if let url = URL(string: reference),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let loaded = await Task.detached(priority: .utility) {
                    UIImage(data: data).map { LoadedImage(image: $0) }
                }.value
                return loaded?.image
            } catch {
                return nil
            }
        }

        return nil
    }
}

private struct VideoAttachmentThumbnail: View {
    let file: ChatMessageFile

    @Environment(\.theme) private var theme
    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    var body: some View {
        ZStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.92),
                            theme.brandPrimary.opacity(0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "film")
                            .scaledFont(size: 34, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
                .overlay {
                    Image(systemName: "play.fill")
                        .scaledFont(size: 18, weight: .bold)
                        .foregroundStyle(.black.opacity(0.82))
                        .offset(x: 1)
                }
        }
        .background(.black.opacity(0.86))
        .task(id: file.url ?? file.displayURL ?? file.name ?? "") {
            guard !didAttemptLoad || image == nil else { return }
            didAttemptLoad = true
            image = await Self.loadThumbnail(for: file)
        }
    }

    private struct LoadedVideoThumbnail: @unchecked Sendable {
        let image: UIImage
    }

    private static func loadThumbnail(for file: ChatMessageFile) async -> UIImage? {
        guard let url = await videoURL(for: file) else { return nil }
        let loaded = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let time = CMTime(seconds: 0.12, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil as LoadedVideoThumbnail?
            }
            return LoadedVideoThumbnail(image: UIImage(cgImage: cgImage))
        }.value
        return loaded?.image
    }

    private static func videoURL(for file: ChatMessageFile) async -> URL? {
        for reference in [file.displayURL, file.url].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if let url = URL(string: reference), url.isFileURL {
                return url
            }
            if let url = URL(string: reference),
               ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
            if let url = try? await localVideoURL(fromDataURL: reference, fallbackName: file.name ?? "generated-video.mp4") {
                return url
            }
        }
        return nil
    }

    private static func localVideoURL(fromDataURL dataURL: String, fallbackName: String) async throws -> URL? {
        try await Task.detached(priority: .utility) {
            guard dataURL.hasPrefix("data:video/"),
                  let comma = dataURL.firstIndex(of: ",") else { return nil }
            let header = String(dataURL[..<comma]).lowercased()
            let encoded = String(dataURL[dataURL.index(after: comma)...])
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return nil }
            let ext: String
            if header.contains("video/webm") {
                ext = "webm"
            } else if header.contains("video/quicktime") || header.contains("video/mov") {
                ext = "mov"
            } else {
                ext = (fallbackName as NSString).pathExtension.isEmpty
                    ? "mp4"
                    : (fallbackName as NSString).pathExtension
            }
            let baseName = ((fallbackName as NSString).deletingPathExtension)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = baseName.isEmpty ? "generated-video" : baseName
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("generated_video_cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let url = cacheDir.appendingPathComponent("\(safeName)-\(abs(dataURL.hashValue)).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url)
            }
            return url
        }.value
    }
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
    @State private var videoURL: URL?
    @State private var shareURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(file: ChatMessageFile, apiClient: APIClient?) {
        self.file = file
        self.apiClient = apiClient
        _selectedTab = State(initialValue: Self.initialPreviewTab(for: file))
    }

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
                if let videoURL {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            shareURL = videoURL
                            Haptics.play(.light)
                        } label: {
                            Label("保存或分享", systemImage: "square.and.arrow.up")
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
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
        .sheet(item: $shareURL) { url in
            ShareSheetView(activityItems: [url])
        }
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
        } else if let videoURL, isVideoLike {
            MessageVideoPlayerView(url: videoURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
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

    private var isVideoLike: Bool {
        Self.isVideoFile(file, loadedContentType: contentType)
    }

    private static func initialPreviewTab(for file: ChatMessageFile) -> PreviewTab {
        isVideoFile(file, loadedContentType: nil) ? .preview : .content
    }

    private static func isVideoFile(_ file: ChatMessageFile, loadedContentType: String?) -> Bool {
        let name = (file.name ?? file.url ?? file.displayURL ?? "").lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let fileContentType = (file.contentType ?? "").lowercased()
        let loadedType = (loadedContentType ?? "").lowercased()
        return file.type == "video"
            || fileContentType.hasPrefix("video/")
            || loadedType.hasPrefix("video/")
            || ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext)
            || name.hasPrefix("data:video/")
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
        guard data == nil && videoURL == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if Self.isVideoFile(file, loadedContentType: nil),
               let playableURL = try await resolveVideoURLForPreview() {
                videoURL = playableURL
                contentType = file.contentType ?? "video/mp4"
                previewImage = nil
                textContent = nil
                selectedTab = .preview
                return
            }

            let extractedText = try await loadExtractedTextIfAvailable()
            if let loaded = try await loadData() {
                data = loaded.data
                contentType = loaded.contentType
                if Self.isVideoFile(file, loadedContentType: loaded.contentType) {
                    videoURL = try await Self.writePreviewVideoData(
                        loaded.data,
                        contentType: loaded.contentType ?? file.contentType,
                        fallbackName: fileName
                    )
                    previewImage = nil
                    textContent = nil
                    selectedTab = .preview
                } else if isImageType(loaded.contentType) {
                    videoURL = nil
                    previewImage = await Self.decodePreviewImage(from: loaded.data)
                    textContent = extractedText ?? decodedText(from: loaded.data, contentType: loaded.contentType)
                } else {
                    videoURL = nil
                    previewImage = nil
                    textContent = extractedText ?? decodedText(from: loaded.data, contentType: loaded.contentType)
                }
            } else {
                textContent = extractedText
                previewImage = nil
                videoURL = nil
                errorMessage = "缺少可读取的文件地址。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveVideoURLForPreview() async throws -> URL? {
        let fallbackName = fileName

        for ref in fileReferenceCandidates {
            if ref.hasPrefix("data:video/") {
                let payload = try await dataURLPayload(ref)
                contentType = payload.contentType ?? file.contentType ?? "video/mp4"
                return try await Self.writePreviewVideoData(
                    payload.data,
                    contentType: payload.contentType ?? file.contentType,
                    fallbackName: fallbackName
                )
            }

            if let url = URL(string: ref), url.isFileURL {
                return url
            }

            if let apiClient, let fileId = serverFileId(from: ref) {
                let loaded = try await apiClient.getFileContent(id: fileId)
                contentType = loaded.1
                return try await Self.writePreviewVideoData(
                    loaded.0,
                    contentType: loaded.1,
                    fallbackName: fallbackName
                )
            }

            if let url = URL(string: ref),
               ["http", "https"].contains(url.scheme?.lowercased()) {
                let loaded = try await Self.downloadVideoForPreview(
                    from: url,
                    fallbackName: fallbackName
                )
                contentType = loaded.contentType ?? file.contentType ?? "video/mp4"
                return loaded.url
            }
        }

        return nil
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

    private static func writePreviewVideoData(
        _ data: Data,
        contentType: String?,
        fallbackName: String
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let ext: String
            let lowerType = (contentType ?? "").lowercased()
            if lowerType.contains("webm") {
                ext = "webm"
            } else if lowerType.contains("quicktime") || lowerType.contains("mov") {
                ext = "mov"
            } else {
                ext = (fallbackName as NSString).pathExtension.isEmpty
                    ? "mp4"
                    : (fallbackName as NSString).pathExtension
            }
            let baseName = ((fallbackName as NSString).deletingPathExtension)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = baseName.isEmpty ? "generated-video" : baseName
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("message_video_preview", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let url = cacheDir.appendingPathComponent("\(safeName)-\(data.count)-\(abs(data.hashValue)).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url)
            }
            return url
        }.value
    }

    private static func downloadVideoForPreview(
        from url: URL,
        fallbackName: String
    ) async throws -> (url: URL, contentType: String?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("video/mp4,video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        let ext: String
        let lowerType = (contentType ?? "").lowercased()
        if lowerType.contains("webm") {
            ext = "webm"
        } else if lowerType.contains("quicktime") || lowerType.contains("mov") {
            ext = "mov"
        } else {
            ext = (fallbackName as NSString).pathExtension.isEmpty
                ? "mp4"
                : (fallbackName as NSString).pathExtension
        }
        let baseName = ((fallbackName as NSString).deletingPathExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = baseName.isEmpty ? "generated-video" : baseName
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("message_video_preview", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let destination = cacheDir.appendingPathComponent("\(safeName)-remote-\(abs(url.absoluteString.hashValue)).\(ext)")
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }.value
        return (destination, contentType)
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

private struct MessageVideoPlayerView: View {
    let url: URL

    var body: some View {
        SystemVideoPlayerView(url: url)
            .id(url)
    }
}

private struct SystemVideoPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if (controller.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            controller.player = AVPlayer(url: url)
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
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

// MARK: - Local QuickLook Preview

private struct LocalQuickLookPreviewController: UIViewControllerRepresentable {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, title: title) {
            dismiss()
        }
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        previewController.navigationItem.title = title
        previewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: context.coordinator,
            action: #selector(Coordinator.share)
        )
        previewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: context.coordinator,
            action: #selector(Coordinator.close)
        )
        context.coordinator.previewController = previewController

        let navigationController = UINavigationController(rootViewController: previewController)
        navigationController.modalPresentationStyle = .fullScreen
        navigationController.overrideUserInterfaceStyle = .light
        previewController.overrideUserInterfaceStyle = .light
        Self.configureAppearance(for: navigationController.navigationBar)
        return navigationController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.update(url: url, title: title)
        Self.configureAppearance(for: uiViewController.navigationBar)
        if let previewController = uiViewController.viewControllers.first as? QLPreviewController {
            previewController.navigationItem.title = title
            previewController.reloadData()
        }
    }

    private static func configureAppearance(for navigationBar: UINavigationBar) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .white
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.12)
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        appearance.buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.black]
        appearance.buttonAppearance.highlighted.titleTextAttributes = [.foregroundColor: UIColor.darkGray]
        appearance.doneButtonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.black]
        appearance.doneButtonAppearance.highlighted.titleTextAttributes = [.foregroundColor: UIColor.darkGray]

        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.tintColor = .black
        navigationBar.isTranslucent = false
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private var item: PreviewItem
        private let onDismiss: () -> Void
        weak var previewController: QLPreviewController?

        init(url: URL, title: String, onDismiss: @escaping () -> Void) {
            self.item = PreviewItem(url: url, title: title)
            self.onDismiss = onDismiss
        }

        func update(url: URL, title: String) {
            item = PreviewItem(url: url, title: title)
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            item
        }

        @objc func close() {
            onDismiss()
        }

        @objc func share() {
            guard let previewController else { return }
            let activityController = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
            previewController.present(activityController, animated: true)
        }
    }

    private final class PreviewItem: NSObject, QLPreviewItem {
        let url: URL
        let title: String

        init(url: URL, title: String) {
            self.url = url
            self.title = title
        }

        var previewItemURL: URL? { url }
        var previewItemTitle: String? { title }
    }
}

// MARK: - ScrollView Horizontal Lock

/// A zero-size `UIViewRepresentable` that finds the enclosing `UIScrollView`
/// and installs a KVO observer on `contentOffset` to continuously snap
/// `contentOffset.x` back to 0. It only handles horizontal drift and does not
/// touch the vertical scroll offset, so keyboard resizing can use the native
/// `UIScrollView` behavior.
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

                    // KVO: snap contentOffset.x to 0 on every change.
                    observation = scrollView.observe(\.contentOffset, options: [.new]) { sv, change in
                        guard let offset = change.newValue else { return }
                        if abs(offset.x) > 0.5 {
                            // Use setContentOffset to avoid triggering another KVO notification loop
                            sv.contentOffset = CGPoint(x: 0, y: offset.y)
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
            if let blocker = panBlocker, let sv = observedScrollView {
                sv.removeGestureRecognizer(blocker)
            }
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
