import Foundation
import CoreFoundation
import os.log
import SwiftUI

extension Notification.Name {
    static let conversationTitleUpdated = Notification.Name("conversationTitleUpdated")
    static let navigateToChannel = Notification.Name("navigateToChannel")
    static let conversationListNeedsRefresh = Notification.Name("conversationListNeedsRefresh")
    /// Posted by MemoriesView when the user toggles the Enable Memory switch.
    /// `object` is the new Bool value so ChatViewModel updates immediately.
    static let memorySettingChanged = Notification.Name("memorySettingChanged")
    /// Posted by AdminConsoleView when a user's chat is cloned.
    static let adminClonedChat = Notification.Name("adminClonedChat")
    /// Posted by the audio attachment thumbnail's retry button.
    /// `object` is the `UUID` of the attachment to retry uploading.
    static let retryAttachmentUpload = Notification.Name("retryAttachmentUpload")
    /// Posted when function config changes (toggle active/global in Admin, or model editor save).
    /// ChatViewModel observes this to re-resolve actions/filters for the current model immediately.
    static let functionsConfigChanged = Notification.Name("functionsConfigChanged")
    /// Posted by Agent step previews when the user wants to jump into the terminal/file panel.
    static let openIexaTerminalBrowser = Notification.Name("openIexaTerminalBrowser")
}

private struct LocalAlpineAgentCommandFailure {
    let command: String
    let cwd: String
    let exitCode: Int?
    let outputPreview: String
}

private struct LocalAlpineAgentCompletedCommand {
    let command: String
    let cwd: String
    let exitCode: Int?
    let outputPreview: String
}

private struct ParsedLocalAlpineCommand {
    let command: String
    let cwd: String
    let hasWriteFiles: Bool
    let writeFilePaths: [String]
}

private struct LocalAlpineToolCapability {
    let name: String
    let description: String
    let arguments: [String]
}

private enum GeneratedImageSlot {
    case image(imageReference: String, displayReference: String)
    case failure

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

struct ChatContextBudgetStatus: Sendable, Equatable {
    var modelId: String = ""
    var usedTokens: Int = 0
    var windowTokens: Int = 0
    var isWindowEstimated: Bool = true
    var isCompressed: Bool = false
    var originalTokens: Int?
    var compressedTokens: Int?

    static let empty = ChatContextBudgetStatus()

    var hasWindow: Bool {
        windowTokens > 0
    }

    var usageRatio: Double {
        guard windowTokens > 0 else { return 0 }
        return min(1.5, max(0, Double(usedTokens) / Double(windowTokens)))
    }

    var isNearLimit: Bool {
        usageRatio >= 0.75
    }

    var isOverLimit: Bool {
        usageRatio >= 1
    }

    var percentageText: String {
        "\(Int((usageRatio * 100).rounded()))%"
    }
}

private enum LocalContextOffloadStore {
    private static let maximumStoredFiles = 24
    private static let maximumFileAge: TimeInterval = 60 * 60 * 24 * 7

    static func modelText(label: String, text: String, maxInlineCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxInlineCharacters else { return text }

        let referencePath = write(label: label, text: trimmed)
        let metadataBudget = 700
        let excerptBudget = max(800, maxInlineCharacters - metadataBudget)
        let headCount = max(400, excerptBudget / 2)
        let tailCount = max(400, excerptBudget - headCount)
        let head = String(trimmed.prefix(headCount))
        let tail = String(trimmed.suffix(tailCount))
        let displayPath = referencePath ?? "unavailable"

        return """
        [context offload: \(label)]
        full_content_saved_locally: \(displayPath)
        original_characters: \(trimmed.count)
        inline_excerpt: head \(head.count) chars + tail \(tail.count) chars
        --- head ---
        \(head)
        --- tail ---
        \(tail)
        [/context offload]
        """
    }

    private static func write(label: String, text: String) -> String? {
        do {
            let directory = try offloadDirectory()
            cleanup(directory: directory.url)
            let fileName = "\(slug(label))-\(stableHash(text)).txt"
            let fileURL = directory.url.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            return "\(directory.displayPath)/\(fileName)"
        } catch {
            return nil
        }
    }

    private static func cleanup(directory: URL) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let files = urls.compactMap { url -> (url: URL, modified: Date)? in
            guard url.pathExtension.lowercased() == "txt",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        for file in files where now.timeIntervalSince(file.modified) > maximumFileAge {
            try? fileManager.removeItem(at: file.url)
        }

        let remaining = files
            .filter { now.timeIntervalSince($0.modified) <= maximumFileAge }
            .sorted { $0.modified > $1.modified }
        for file in remaining.dropFirst(maximumStoredFiles) {
            try? fileManager.removeItem(at: file.url)
        }
    }

    private static func offloadDirectory() throws -> (url: URL, displayPath: String) {
        let fileManager = FileManager.default
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let shared = documents
                .appendingPathComponent("Iexa Alpine", isDirectory: true)
                .appendingPathComponent("shared", isDirectory: true)
                .appendingPathComponent(".iexa-context-offload", isDirectory: true)
            try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
            return (shared, "/mnt/iexa/.iexa-context-offload")
        }

        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let fallback = base.appendingPathComponent("IexaContextOffloads", isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return (fallback, fallback.path)
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func slug(_ label: String) -> String {
        var result = ""
        let safePunctuation = CharacterSet(charactersIn: "-_")
        let separators = CharacterSet(charactersIn: " /.")
        for scalar in label.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || safePunctuation.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if separators.contains(scalar) {
                result.append("-")
            }
            if result.count >= 48 { break }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty
            ? "context"
            : result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}

/// Manages state and logic for a single chat conversation.
/// Handles sending/streaming messages via Socket.IO, loading history, and model selection.
/// Instances are held by `ActiveChatStore` so they survive navigation transitions.
@MainActor @Observable
final class ChatViewModel {
    // MARK: - Published State

    private static let chatWebSearchEnabledKey = "chatWebSearchEnabled"
    private static let directImageGenerationMaxConcurrency = 3

    /// Isolated store for streaming content. Only the actively streaming
    /// message view observes this — all other message views read from
    /// `conversation.messages` which stays frozen during streaming.
    /// This breaks the observation chain that was causing ALL messages
    /// to re-evaluate on every token.
    let streamingStore = StreamingContentStore()

    var conversation: Conversation?
    var availableModels: [AIModel] = []

    // MARK: - Folder Context

    /// When set, new chats will be created inside this folder and use this system prompt.
    var folderContextId: String?
    var folderContextSystemPrompt: String?
    var folderContextModelIds: [String] = []

    /// Sets or clears the folder workspace context.
    /// Called when the user taps a folder name in the drawer.
    func setFolderContext(folderId: String?, systemPrompt: String?, modelIds: [String] = []) {
        folderContextId = folderId
        folderContextSystemPrompt = systemPrompt
        folderContextModelIds = modelIds
        // If the folder has default model IDs and we have no model selected, pick the first
        if let firstModel = modelIds.first, !firstModel.isEmpty {
            let available = availableModels.map(\.id)
            if available.contains(firstModel) {
                selectModel(firstModel)
            }
        }
    }
    var selectedModelId: String?
    var contextBudgetStatus = ChatContextBudgetStatus.empty
    var isStreaming: Bool = false
    var isLoadingConversation: Bool = false
    var isLoadingModels: Bool = false
    /// Tasks managed by the model's built-in task tools (create_tasks / update_task).
    /// Populated from the server on load and updated in real-time during streaming.
    var tasks: [ChatTask] = []
    var errorMessage: String?
    var inputText: String = ""
    var attachments: [ChatAttachment] = []
    private var lastContextBudgetRefreshSignature: String = ""
    func updateLiveContextBudgetPreview() {
        let signature = [
            selectedModelId ?? "",
            conversation?.id ?? "",
            "\(conversation?.messages.count ?? 0)",
            "\(inputText.count)",
            "\(attachments.count)"
        ].joined(separator: "|")
        guard signature != lastContextBudgetRefreshSignature else { return }
        lastContextBudgetRefreshSignature = signature
        let modelId = selectedModelId ?? conversation?.model
        let visibleTokens = Self.estimatedTokensForVisibleConversation(conversation)
        let draftTokens = Self.estimatedTokenCount(for: inputText)
            + attachments.reduce(0) { $0 + Self.estimatedAttachmentTokens(for: $1) }
        contextBudgetStatus = Self.contextStatus(
            model: selectedModel,
            modelId: modelId,
            usedTokens: visibleTokens + draftTokens
        )
    }
    var webSearchEnabled: Bool = false {
        didSet {
            guard !suppressBuiltinFeatureTracking else { return }
            if webSearchEnabled && !isChatWebSearchAllowed {
                suppressBuiltinFeatureTracking = true
                webSearchEnabled = false
                suppressBuiltinFeatureTracking = false
                return
            }
            if webSearchEnabled {
                userDisabledBuiltinFeatures.remove("web_search")
            } else {
                userDisabledBuiltinFeatures.insert("web_search")
            }
        }
    }
    var imageGenerationEnabled: Bool = false {
        didSet {
            guard !suppressBuiltinFeatureTracking else { return }
            if imageGenerationEnabled {
                userDisabledBuiltinFeatures.remove("image_generation")
            } else {
                userDisabledBuiltinFeatures.insert("image_generation")
            }
        }
    }
    var codeInterpreterEnabled: Bool = false {
        didSet {
            guard !suppressBuiltinFeatureTracking else { return }
            if codeInterpreterEnabled {
                userDisabledBuiltinFeatures.remove("code_interpreter")
            } else {
                userDisabledBuiltinFeatures.insert("code_interpreter")
            }
        }
    }
    /// Whether memory is enabled for this chat session.
    /// Persisted to server user settings (`ui.memory`) so the web UI stays in sync.
    var memoryEnabled: Bool = false
    /// Pinned model IDs synced with server `ui.pinnedModels`.
    var pinnedModelIds: [String] = []
    var isTemporaryChat: Bool = false
    /// Chat params set before the conversation is created (new-chat flow).
    /// Applied to `conversation.chatParams` as soon as the conversation is created.
    var pendingChatParams: ChatAdvancedParams?
    var availableTools: [ToolItem] = []
    var selectedToolIds: Set<String> = [] {
        didSet {
            // Track tools the user explicitly disabled (were in old set but not new)
            let removed = oldValue.subtracting(selectedToolIds)
            let added = selectedToolIds.subtracting(oldValue)
            userDisabledToolIds.formUnion(removed)
            userDisabledToolIds.subtract(added)
        }
    }
    /// Tools the user has explicitly toggled OFF during this chat session.
    /// Prevents `syncToolSelectionWithDefaults()` from re-enabling them.
    private var userDisabledToolIds: Set<String> = []
    /// Built-in features (web_search, image_generation, code_interpreter) the user
    /// has explicitly toggled OFF during this session. Prevents
    /// `applyIncrementalModelDefaults()` from re-enabling them before each send.
    private var userDisabledBuiltinFeatures: Set<String> = []
    /// When `true`, mutations to `webSearchEnabled`, `imageGenerationEnabled`, and
    /// `codeInterpreterEnabled` do NOT update `userDisabledBuiltinFeatures`.
    /// Set during `syncUIWithModelDefaults()` and `restoreBuiltinFeatureState()`
    /// so those internal resets aren't misinterpreted as explicit user overrides.
    private var suppressBuiltinFeatureTracking: Bool = false
    var selectedKnowledgeItems: [KnowledgeItem] = []
    var knowledgeItems: [KnowledgeItem] = []
    /// Reference chat conversations selected for context in the next message.
    var selectedReferenceChats: [ReferenceChatItem] = []
    var isLoadingTools: Bool = false
    /// Available terminal servers fetched from the backend.
    var availableTerminalServers: [TerminalServer] = []
    /// Whether the user has enabled terminal for this chat session.
    var terminalEnabled: Bool = false
    /// The currently selected terminal server (auto-selects first if only one).
    var selectedTerminalServer: TerminalServer?
    var selectedTerminalIsLocalAlpine: Bool {
        selectedTerminalServer?.isLocalAlpine == true
    }
    var isLoadingKnowledge: Bool = false
    var isShowingKnowledgePicker: Bool = false
    var knowledgeSearchQuery: String = ""

    // Prompt slash command state
    /// Cached prompts from the server. Fetched lazily on first `/` trigger.
    var availablePrompts: [PromptItem] = []
    /// Whether the prompt picker overlay is visible.
    var isShowingPromptPicker: Bool = false
    /// The current filter query (text typed after `/`).
    var promptSearchQuery: String = ""
    /// Whether prompts are currently being loaded from the server.
    var isLoadingPrompts: Bool = false
    // Skill $ trigger state
    /// Cached skills from the server. Fetched lazily on first `$` trigger.
    var availableSkills: [SkillItem] = []
    /// Whether the skill picker overlay is visible.
    var isShowingSkillPicker: Bool = false
    /// The current filter query (text typed after `$`).
    var skillSearchQuery: String = ""
    /// Whether skills are currently being loaded from the server.
    var isLoadingSkills: Bool = false
    /// Skills selected via the `$` picker for the current message.
    /// Sent as `skill_ids` in the API request and cleared after each send.
    var selectedSkillIds: [String] = []

    /// The prompt selected by the user that has variables requiring input.
    /// When set, the variable input sheet is presented.
    var pendingPromptForVariables: PromptItem?
    /// The parsed variables for the pending prompt.
    var pendingPromptVariables: [PromptVariable] = []
    /// The model ID selected via `@` mention in the chat input.
    /// Persists across messages until the user explicitly clears it.
    var mentionedModelId: String?
    /// Suggested emoji for the last assistant message (generated by server).
    var suggestedEmoji: String?
    private(set) var hasLoaded: Bool = false

    /// Whether an external client (website, another app tab) is currently
    /// streaming a response to this chat. When `true`, the app is passively
    /// observing socket events it did not initiate.
    private(set) var isExternallyStreaming: Bool = false

    /// Set to `true` after the initial load completes so that new messages
    /// arriving during a session get an appear animation, while the full
    /// history loaded on first launch does not.
    private(set) var shouldAnimateNewMessages: Bool = false

    // MARK: - Private State

    let conversationId: String?
    private var manager: ConversationManager?
    private var socketService: SocketIOService?
    /// Weak reference to the shared ASR service, set via configure().
    private weak var asrService: OnDeviceASRService?
    private var streamingTask: Task<Void, Never>?
    private var directMediaGenerationTasks: [String: Task<Void, Never>] = [:]
    private var directMediaGenerationTaskOrder: [String] = []
    /// Active transcription tasks keyed by attachment ID.
    /// Stored here so they survive navigation — the VM lives in ActiveChatStore
    /// and is never destroyed when the user switches chats.
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    /// The post-streaming completion task (chatCompleted + file polling + metadata refresh).
    /// Cancelled when a new message is sent so it doesn't overwrite newer messages.
    private var completionTask: Task<Void, Never>?
    private var generatedTitleConversationIds: Set<String> = []
    private var titleGenerationInFlightConversationIds: Set<String> = []
    private var initialAutoTitlesByConversationId: [String: String] = [:]
    /// In-flight model config fetch from selectModel(). Stored so
    /// sendMessage/regenerateResponse can await it before reading
    /// functionCallingMode — prevents the race where the user selects
    /// a model and immediately sends before the config fetch completes.
    private var modelConfigTask: Task<Void, Never>?
    private var chatSubscription: SocketSubscription?
    private var channelSubscription: SocketSubscription?
    /// Persistent passive socket listener that observes events for this chat
    /// regardless of who initiated the generation. Mirrors the website's
    /// `Chat.svelte` `socket.on("events", chatEventHandler)` pattern.
    private var passiveSubscription: SocketSubscription?
    /// True when this VM initiated the current streaming session (sendMessage/regenerate).
    /// The passive listener skips processing when this is true to avoid conflicts.
    private var selfInitiatedStream: Bool = false
    /// Guards against flooding syncForExternalStream with duplicate fetch tasks
    /// when many socket tokens arrive before the first fetch completes.
    private var isSyncingExternalStream: Bool = false
    /// Raw text for passive socket streams. The visible message content is
    /// sanitized on every event so huge inline image payloads never enter SwiftUI.
    private var externalRawContentByMessageId: [String: String] = [:]
    private(set) var sessionId: String = UUID().uuidString
    private let logger = Logger(subsystem: "com.openui", category: "ChatViewModel")
    private let webLinkContextResolver = WebLinkContextResolver()
    private var webLinkContextsByMessageId: [String: String] = [:]
    private var webSearchContextsByMessageId: [String: String] = [:]
    private var attachmentContextsByMessageId: [String: String] = [:]
    private var hasFinishedStreaming = false
    /// Tracks the content length at the last `extractAndApplyTasksFromContent` call.
    /// Prevents the O(n) task-extraction scan from running on every single token;
    /// it only fires when the content has grown by ≥ 100 chars since the last scan.
    private var lastTaskExtractionLength: Int = 0
    /// Cached value of the "streamingHaptics" UserDefaults preference.
    /// Updated whenever UserDefaults.didChangeNotification fires so toggling in
    /// Settings takes effect immediately without a per-token UserDefaults read.
    private var streamingHapticsEnabled: Bool = true
    private var isChatWebSearchAllowed: Bool = false
    @ObservationIgnored nonisolated(unsafe) private var chatWebSearchSettingsObserver: NSObjectProtocol?
    private var activeTaskId: String?
    private var recoveryTimer: Timer?
    /// Cancellable delay task for the initial recovery timer delay.
    /// Replaces `DispatchQueue.main.asyncAfter` so it can be cancelled
    /// when the user navigates away or sends a new message.
    private var recoveryDelayTask: Task<Void, Never>?
    private var emptyPollCount = 0
    /// Tracks whether the socket has received at least one content token.
    /// Used by the recovery timer to avoid overwriting an active stream.
    private var socketHasReceivedContent = false
    /// Assistant message IDs whose local workspace instructions have already
    /// been applied. Prevents duplicate writes when a completion is refreshed
    /// or retried after streaming finishes.
    private var localWorkspaceAgentExecutedMessageIds: Set<String> = []
    /// Assistant message IDs whose Local Alpine command blocks have already
    /// been executed. Keeps refresh/retry paths from running shell commands twice.
    private var localAlpineAgentExecutedMessageIds: Set<String> = []
    /// Executable Local Alpine instruction payloads already accepted in the
    /// current user turn. Message-id de-dupe alone cannot catch the same tool
    /// block being emitted again inside a follow-up assistant continuation.
    private var localAlpineExecutedExecutableFingerprints: Set<String> = []
    /// Assistant message IDs whose local native iOS tool blocks have already run.
    private var localNativeToolExecutedMessageIds: Set<String> = []
    /// Local files generated by native tools, keyed by the tool-result system message id.
    private var localNativeGeneratedFilesByResultMessageId: [String: [ChatMessageFile]] = [:]
    /// Visible tool statuses that should be moved from a hidden native tool parent
    /// onto the final assistant answer.
    private var localNativeInheritedStatusByResultMessageId: [String: [ChatStatusUpdate]] = [:]
    /// Assistant message IDs whose Local Alpine native tool calls have already run.
    /// Prevents the Markdown fallback parser from executing the same model step again.
    private var localAlpineNativeToolExecutedMessageIds: Set<String> = []
    private var localAlpineAgentTask: Task<Void, Never>?
    private var localAlpineContinuationTask: Task<Void, Never>?
    private var localAlpineAgentStopRequested = false
    private var localAlpineAutoExecutionPaused = false
    private var localAlpineFailedCommands: [String: LocalAlpineAgentCommandFailure] = [:]
    private var localAlpineCompletedCommands: [String: LocalAlpineAgentCompletedCommand] = [:]
    private var localAlpineFailureSignatures: [String: Int] = [:]
    private var localAlpineNoProgressSignatures: [String: Int] = [:]
    private var localAlpineBlockedRepeatCommands: [String: Int] = [:]
    private var localAlpineFinalSummaryParentIds: Set<String> = []
    private var localAlpineContinuationParentIds: Set<String> = []
    private var localAlpineFinishedContinuationMessageIds: Set<String> = []
    private var localAlpineContinuationRetryCounts: [String: Int] = [:]
    private var localAlpineMissingToolCorrectionParentIds: Set<String> = []
    private var localAlpineContinuationWatchdogTask: Task<Void, Never>?
    private var localAlpineNativeToolsUnsupportedModels: Set<String> = []
    private var localAlpineActiveRunIdsByMessageId: [String: String] = [:]
    private var localAlpineLiveToolCallsByMessageId: [String: [LocalAlpineToolCall]] = [:]
    private var localAlpineLastLiveToolStatusByMessageId: [String: ChatStatusUpdate] = [:]
    @ObservationIgnored private var localAlpinePendingToolCallsByMessageId: [String: [LocalAlpineToolCall]] = [:]
    @ObservationIgnored private var localAlpinePendingToolStatusByMessageId: [String: ChatStatusUpdate] = [:]
    @ObservationIgnored private var localAlpineToolEventFlushTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var localAlpineLastToolEventFlushAtByMessageId: [String: Date] = [:]
    private let localAlpineAgentMaxSteps = 10
    private let localAlpineNoProgressRepeatLimit = 2
    private let localAlpineToolEventFlushInterval: TimeInterval = 0.22
    var localAlpineInputRequest: LocalAlpineInteractiveRequest?
    var localAlpineInputText: String = ""
    @ObservationIgnored private var localAlpineInputContinuation: CheckedContinuation<String?, Never>?
    private(set) var serverBaseURL: String = ""
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var tokenUsageRecordedMessageIds: Set<String> = []
    /// Separate background task assertion for on-device ASR transcription.
    /// Independent from backgroundTaskId (which covers streaming completion).
    @ObservationIgnored nonisolated(unsafe) private var transcriptionBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    private var isOpenAICompatibleProvider: Bool {
        guard let providerType = manager?.providerType else { return false }
        return providerType != .iexa
    }

    private var currentProviderType: ServerConfig.ProviderType? {
        manager?.providerType
    }

    @MainActor
    private func beginStreamingBackgroundTaskIfNeeded() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let content = self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await self.sendCompletionNotificationIfNeeded(content: content)
                }
                self.endBackgroundTask()
            }
        }
    }

    private func startRunLiveActivity(id: String, modelId: String, prompt: String) async {
        let kind = runLiveActivityKind(modelId: modelId, prompt: prompt)
        guard kind != "chat" else { return }
        await RunLiveActivityService.shared.start(
            id: id,
            kind: kind,
            model: modelId,
            title: runLiveActivityTitle(kind: kind),
            detail: runLiveActivityDetail(prompt),
            phase: "准备",
            progress: 0.08,
            isIndeterminate: true
        )
    }

    private func startLocalAlpineLiveActivity(id: String, command: String, detail: String) async {
        await RunLiveActivityService.shared.start(
            id: id,
            kind: localAlpineLiveActivityKind(for: command),
            model: "Local Alpine",
            title: "本地 Alpine",
            detail: detail,
            phase: "执行",
            progress: 0.18,
            isIndeterminate: true
        )
    }

    private func runLiveActivityKind(modelId: String, prompt: String) -> String {
        if shouldUseDirectVideoGeneration(modelId: modelId) { return "video" }
        if shouldUseDirectImageGeneration(modelId: modelId)
            || shouldPreferChatNativeImageGeneration(modelId: modelId) {
            return "image"
        }
        return "chat"
    }

    private func runLiveActivityTitle(kind: String) -> String {
        switch kind {
        case "image": return "正在创建图片"
        case "video": return "正在生成视频"
        case "terminal", "install": return "本地 Alpine"
        default: return "Iexa 正在回复"
        }
    }

    private func localAlpineLiveActivityKind(for command: String) -> String {
        let lowercased = command.lowercased()
        if lowercased.contains("apk add ")
            || lowercased.contains("apk upgrade")
            || lowercased.contains("apk fix")
            || lowercased.contains("npm i")
            || lowercased.contains("npm install")
            || lowercased.contains("pip install") {
            return "install"
        }
        return "terminal"
    }

    private func runLiveActivityDetail(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "任务进行中" : cleaned
    }

    private func updateRunLiveActivity(
        id: String,
        content: String,
        isStreaming: Bool,
        statusHistory: [ChatStatusUpdate]?,
        error: ChatMessageError?
    ) {
        let latestStatus = statusHistory?.last
        if isStreaming && error == nil {
            let detail = latestStatus?.description ?? liveActivityStreamingDetail(for: content)
            let progress = liveActivityProgress(for: content)
            Task {
                await RunLiveActivityService.shared.update(
                    id: id,
                    detail: detail,
                    phase: "运行中",
                    progress: progress,
                    isIndeterminate: progress < 0.85
                )
            }
        } else {
            let success = error == nil
            let detail = latestStatus?.description
                ?? error?.content
                ?? liveActivityFinishedDetail(for: content, success: success)
            Task {
                await RunLiveActivityService.shared.finish(
                    id: id,
                    success: success,
                    detail: detail
                )
            }
        }
    }

    private func liveActivityStreamingDetail(for content: String) -> String {
        let count = content.trimmingCharacters(in: .whitespacesAndNewlines).count
        if count == 0 { return "正在连接模型" }
        return "已接收 \(count) 字"
    }

    private func liveActivityFinishedDetail(for content: String, success: Bool) -> String {
        if !success { return "运行失败" }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("已生成图片") { return "图片已生成" }
        if trimmed.contains("已生成视频") { return "视频已生成" }
        if trimmed.contains("Local Alpine") || trimmed.contains("exit:") { return "本地命令已完成" }
        return "回复已完成"
    }

    private func liveActivityProgress(for content: String) -> Double {
        let count = Double(content.trimmingCharacters(in: .whitespacesAndNewlines).count)
        guard count > 0 else { return 0.18 }
        return min(0.9, 0.2 + count / 4_000)
    }

    /// Pending transcriptions that were interrupted when the app moved to the background
    /// (iOS < 26 only — no GPU access in background). Keyed by attachment ID.
    /// Re-started automatically when the app returns to foreground.
    private var pendingResumeTranscriptions: [UUID: (audioData: Data, fileName: String)] = [:]

    /// Timestamp of the last successful server sync. Used to debounce
    /// redundant syncs when the app rapidly transitions foreground ↔ background.
    private var lastSyncTime: Date = .distantPast

    /// Minimum interval (seconds) between server syncs to avoid redundant fetches.
    private let syncDebounceInterval: TimeInterval = 3.0

    /// Timestamp of the last time the chat view appeared (navigation entry).
    /// Used by syncOnEntry() to debounce SwiftUI's double-appear during transitions.
    private var lastEntryTime: Date = .distantPast

    /// Timestamp when the app entered the background. Used to skip
    /// sync when the background duration was trivially short.
    @ObservationIgnored nonisolated(unsafe) private var backgroundEnteredAt: Date?

    /// Debounces lifecycle snapshot persistence because UIKit can emit
    /// will-resign and did-enter-background back to back.
    @ObservationIgnored nonisolated(unsafe) private var lastLifecycleSnapshotPersistAt: Date = .distantPast
    @ObservationIgnored private var localConversationAutosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastLocalConversationAutosaveAt: Date = .distantPast
    private let localConversationAutosaveInterval: TimeInterval = 1.5

    /// The current auth token for authenticated image requests (model avatars).
    var serverAuthToken: String? {
        manager?.apiClient.network.authToken
    }

    var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    func localAlpineLiveToolCalls(for messageId: String) -> [LocalAlpineToolCall] {
        localAlpineLiveToolCallsByMessageId[messageId] ?? []
    }

    func localAlpineLiveToolStatus(for messageId: String) -> ChatStatusUpdate? {
        localAlpineLastLiveToolStatusByMessageId[messageId]
    }

    private func clearLocalAlpineLiveToolState(for messageId: String) {
        localAlpineToolEventFlushTasks[messageId]?.cancel()
        localAlpineToolEventFlushTasks.removeValue(forKey: messageId)
        localAlpineActiveRunIdsByMessageId.removeValue(forKey: messageId)
        localAlpineLiveToolCallsByMessageId.removeValue(forKey: messageId)
        localAlpineLastLiveToolStatusByMessageId.removeValue(forKey: messageId)
        localAlpinePendingToolCallsByMessageId.removeValue(forKey: messageId)
        localAlpinePendingToolStatusByMessageId.removeValue(forKey: messageId)
        localAlpineLastToolEventFlushAtByMessageId.removeValue(forKey: messageId)
    }

    private func clearAllLocalAlpineLiveToolState() {
        for task in localAlpineToolEventFlushTasks.values {
            task.cancel()
        }
        localAlpineToolEventFlushTasks.removeAll()
        localAlpineActiveRunIdsByMessageId.removeAll()
        localAlpineLiveToolCallsByMessageId.removeAll()
        localAlpineLastLiveToolStatusByMessageId.removeAll()
        localAlpinePendingToolCallsByMessageId.removeAll()
        localAlpinePendingToolStatusByMessageId.removeAll()
        localAlpineLastToolEventFlushAtByMessageId.removeAll()
    }

    // MARK: - Tree Sync Helpers

    /// Syncs the conversation to the server using the tree-based history.
    /// The history tree is always kept in sync by all tree-mutating operations,
    /// so this just serializes the current tree state to the server.
    /// Copies content and metadata from the flat `conversation.messages` list back into
    /// their corresponding tree nodes.
    ///
    /// The history tree nodes are created with empty content (e.g. assistant nodes are
    /// created at send/edit time before streaming begins). Streaming content flows into
    /// `conversation.messages` but the tree nodes are never updated in-place.
    /// Calling this before any `syncToServerViaTree()` ensures we never overwrite the
    /// server's good data with stale/empty tree nodes.
    private func syncFlatMessagesToTreeNodes() {
        guard conversation?.history.isPopulated == true else { return }
        for msg in conversation?.messages ?? [] {
            // Only update if this node actually exists in the tree
            guard conversation?.history.nodes[msg.id] != nil else { continue }
            conversation?.history.updateNode(id: msg.id) { node in
                // Don't overwrite non-empty tree node content with an empty flat message
                // (this protects nodes on inactive branches that are absent from flat messages)
                if !msg.content.isEmpty {
                    node.content = msg.content
                }
                node.done = !msg.isStreaming
                if !msg.sources.isEmpty { node.sources = msg.sources }
                if !msg.statusHistory.isEmpty { node.statusHistory = msg.statusHistory }
                if let error = msg.error { node.error = error }
                if let metadata = msg.metadata { node.metadata = metadata }
                if !msg.files.isEmpty {
                    let files = isOpenAICompatibleProvider ? msg.files : Self.serverPersistableFiles(msg.files)
                    if !files.isEmpty { node.files = files }
                }
                if let usage = msg.usage { node.usage = usage }
            }
        }
    }

    private func syncToServerViaTree() async {
        // Ensure tree nodes have up-to-date content from the flat messages list before
        // syncing to the server. Tree nodes are created with empty content at send/edit time
        // and streaming content only flows into conversation.messages — without this step,
        // syncToServerViaTree() would overwrite the server's good data with empty strings.
        syncFlatMessagesToTreeNodes()

        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        let modelId = selectedModelId ?? conversation?.model ?? ""

        guard let conv = conversation, conv.history.isPopulated else {
            // Tree not populated — fall back to flat-list sync
            try? await manager.syncConversationMessages(
                id: chatId, messages: conversation?.messages ?? [], model: modelId,
                title: conversation?.title, chatParams: conversation?.chatParams)
            return
        }

        try? await manager.syncConversationHistory(conv)
    }

    /// Saves a best-effort snapshot before iOS suspends the app.
    ///
    /// During streaming, token content lives in `StreamingContentStore` instead of
    /// `conversation.messages` for performance. If the app backgrounds before a
    /// normal completion event, the conversation list/history can miss the latest
    /// user turn or partial assistant text. This mirrors the live stream into the
    /// conversation and persists it once at the lifecycle boundary.
    func persistLifecycleConversationSnapshot() {
        let hasStreamingMessage = conversation?.messages.contains(where: { $0.isStreaming }) == true
        let wasStreaming = isStreaming || streamingStore.isActive || hasStreamingMessage
        let didSnapshot = snapshotActiveStreamingMessageToConversation()
        guard conversation != nil else { return }
        guard wasStreaming || didSnapshot else { return }

        let now = Date()
        guard now.timeIntervalSince(lastLifecycleSnapshotPersistAt) >= 0.8 else { return }
        lastLifecycleSnapshotPersistAt = now

        Task { [weak self] in
            await self?.persistConversationSnapshotForLifecycle()
        }
    }

    /// Rehydrates the stream display after returning from the background.
    func restoreLifecycleConversationSnapshot() {
        guard streamingStore.isActive,
              let messageId = streamingStore.streamingMessageId,
              let message = conversation?.messages.first(where: { $0.id == messageId }),
              !message.content.isEmpty
        else { return }

        streamingStore.restoreSnapshotContent(message.content)
    }

    @discardableResult
    private func snapshotActiveStreamingMessageToConversation() -> Bool {
        guard streamingStore.isActive,
              let messageId = streamingStore.streamingMessageId,
              let index = conversation?.messages.firstIndex(where: { $0.id == messageId })
        else { return false }

        var didChange = false
        let snapshot = streamingStore.snapshotContent

        if !snapshot.isEmpty,
           snapshot.count >= (conversation?.messages[index].content.count ?? 0) {
            conversation?.messages[index].content = snapshot
            didChange = true

            conversation?.history.updateNode(id: messageId) { node in
                node.content = snapshot
                node.done = false
            }
        }

        if !streamingStore.streamingStatusHistory.isEmpty {
            conversation?.messages[index].statusHistory = streamingStore.streamingStatusHistory
            didChange = true

            conversation?.history.updateNode(id: messageId) { node in
                node.statusHistory = streamingStore.streamingStatusHistory
            }
        }

        if !streamingStore.streamingSources.isEmpty {
            for source in streamingStore.streamingSources {
                if conversation?.messages[index].sources.contains(where: {
                    ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
                }) != true {
                    conversation?.messages[index].sources.append(source)
                    didChange = true
                }
            }

            let sources = conversation?.messages[index].sources ?? []
            conversation?.history.updateNode(id: messageId) { node in
                node.sources = sources
            }
        }

        if let error = streamingStore.streamingError {
            conversation?.messages[index].error = error
            conversation?.history.updateNode(id: messageId) { node in
                node.error = error
            }
            didChange = true
        }

        return didChange
    }

    private func persistConversationSnapshotForLifecycle() async {
        conversation?.updatedAt = Date()
        syncFlatMessagesToTreeNodes()

        guard let manager, let conversation else { return }
        guard !isTemporaryChat else { return }

        do {
            if manager.usesLocalConversationStore {
                try await manager.saveConversation(conversation)
            } else if conversation.history.isPopulated {
                try await manager.syncConversationHistory(conversation)
            } else {
                try await manager.saveConversation(conversation)
            }
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        } catch {
            logger.error("Failed to persist lifecycle conversation snapshot: \(error.localizedDescription)")
        }
    }

    private func scheduleLocalConversationAutosave(immediate: Bool = false) {
        guard manager?.usesLocalConversationStore == true,
              conversation != nil,
              !isTemporaryChat
        else { return }

        if immediate {
            localConversationAutosaveTask?.cancel()
            localConversationAutosaveTask = nil
        } else if localConversationAutosaveTask != nil {
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastLocalConversationAutosaveAt)
        let delay = immediate || elapsed >= localConversationAutosaveInterval
            ? 0
            : UInt64((localConversationAutosaveInterval - elapsed) * 1_000_000_000)

        localConversationAutosaveTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.lastLocalConversationAutosaveAt = Date()
            await self?.persistLocalConversationIfNeeded()
            self?.localConversationAutosaveTask = nil
        }
    }

    var selectedModel: AIModel? {
        guard let id = selectedModelId else { return nil }
        return availableModels.first { $0.id == id }
    }

    var effectiveContextWindowTokens: Int {
        Self.contextWindowTokens(for: selectedModel, modelId: selectedModelId ?? conversation?.model)
    }

    var canSend: Bool {
        (!isStreaming || isOnlyDirectMediaGenerationActive)
            && !attachments.contains(where: { $0.type == .audio && $0.isTranscribing })
            && !attachments.contains(where: { $0.isUploading && !canSendAttachmentWithoutCompletedUpload($0) })
            && !attachments.contains(where: { $0.uploadStatus == .error && !canSendAttachmentWithoutCompletedUpload($0) })
            && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    private var hasActiveDirectMediaGeneration: Bool {
        !directMediaGenerationTasks.isEmpty
    }

    var canSendWhileStreaming: Bool {
        isOnlyDirectMediaGenerationActive
    }

    private var isOnlyDirectMediaGenerationActive: Bool {
        hasActiveDirectMediaGeneration && conversation?.messages.contains(where: { message in
            message.isStreaming && message.metadata?["iexa_direct_media_generation"] != "true"
        }) != true
    }

    /// True if any transcription Task is currently running.
    /// Used by ActiveChatStore to prevent evicting a VM that is still working.
    var hasActiveTranscriptions: Bool {
        !transcriptionTasks.isEmpty
    }

    /// Whether any attachment is still uploading or being processed.
    var hasUploadingAttachments: Bool {
        attachments.contains { $0.isUploading }
    }

    var isNewConversation: Bool {
        conversationId == nil && conversation == nil
    }

    // MARK: - Immediate File Upload

    /// Uploads an attachment to the server immediately after it's added.
    /// Call this right after appending an attachment to `self.attachments`.
    /// The attachment's `uploadStatus` will progress: uploading → completed/error.
    /// The send button is blocked while any attachment has `isUploading == true`.
    /// Scrapes a webpage URL and turns it into a text attachment.
    /// Direct API providers do not expose Iexa/Iexa native server retrieval endpoints, so
    /// they keep the text inline and send it with the next model request.
    func processWebURL(urlString: String) {
        var normalised = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return }
        if !normalised.hasPrefix("http://") && !normalised.hasPrefix("https://") {
            normalised = "https://\(normalised)"
        }

        // Derive a short filename from the domain
        let host = URL(string: normalised)?.host ?? "webpage"
        let fileName = "\(host).txt"

        // Add a placeholder attachment immediately so the user sees the pill
        var attachment = ChatAttachment(
            type: .file,
            name: fileName,
            thumbnail: nil,
            data: nil
        )
        attachment.uploadStatus = .uploading
        attachments.append(attachment)
        let attachmentId = attachment.id

        Task {
            do {
                let content: String
                if let apiClient = manager?.apiClient, apiClient.providerType == .iexa {
                    do {
                        content = try await apiClient.processWebPage(url: normalised)
                    } catch {
                        // Some compatible servers do not enable the retrieval API.
                        // Fall back to a local scrape instead of making the feature fail.
                        content = try await Self.fetchWebPageTextLocally(from: normalised)
                    }
                } else {
                    content = try await Self.fetchWebPageTextLocally(from: normalised)
                }

                guard let textData = content.data(using: .utf8), !textData.isEmpty else {
                    if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                        attachments[idx].uploadStatus = .error
                        attachments[idx].uploadError = "没有从网页提取到内容"
                    }
                    return
                }

                // Store data on the attachment for either inline sending or upload.
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].data = textData
                }

                guard let mgr = manager, mgr.providerType == .iexa else {
                    if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                        attachments[idx].uploadStatus = .completed
                        attachments[idx].uploadError = nil
                    }
                    logger.info("Web page \(normalised) scraped locally for inline sending")
                    return
                }

                // Iexa native server/Iexa server mode: upload through the normal files pipeline
                // so server-side RAG can process it.
                let fileResult: (String, [String: Any])
                do {
                    fileResult = try await mgr.uploadFile(
                        data: textData,
                        fileName: fileName,
                        onUploaded: { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                                    self.attachments[idx].uploadStatus = .processing
                                }
                            }
                        }
                    )
                } catch {
                    let apiError = APIError.from(error)
                    if case .httpError(let code, _, _) = apiError, code == 404 || code == 405 {
                        if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                            attachments[idx].uploadStatus = .completed
                            attachments[idx].uploadError = nil
                        }
                        logger.info("Web page \(normalised) upload endpoint unavailable; using inline text")
                        return
                    }
                    throw error
                }
                let (fileId, fileObject) = fileResult

                // Phase 3: Mark completed
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .completed
                    attachments[idx].uploadedFileId = fileId
                    attachments[idx].uploadedFileObject = fileObject
                    attachments[idx].data = nil
                }
                logger.info("Web page \(normalised) scraped + uploaded: \(fileId)")
            } catch {
                let errorMessage: String
                if let apiError = error as? APIError,
                   case .httpError(_, let msg, _) = apiError,
                   let msg, !msg.isEmpty {
                    errorMessage = msg
                } else {
                    errorMessage = error.localizedDescription.isEmpty
                        ? "网页链接处理失败"
                        : error.localizedDescription
                }
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = errorMessage
                }
                logger.error("Web page attachment failed: \(errorMessage)")
            }
        }
    }

    nonisolated private static func fetchWebPageTextLocally(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let encodingName = (response.textEncodingName ?? "").lowercased()
        let encoding: String.Encoding = {
            switch encodingName {
            case "gbk", "gb2312", "gb18030":
                return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            case "iso-8859-1":
                return .isoLatin1
            default:
                return .utf8
            }
        }()
        let raw = String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let title = extractHTMLTitle(from: raw)
        let text = extractReadableText(from: raw)
        let limited = text.count > 80_000 ? String(text.prefix(80_000)) + "\n\n[网页内容已截断]" : text
        return """
        Source URL: \(urlString)
        \(title.isEmpty ? "" : "Title: \(title)\n")
        \(limited)
        """
    }

    nonisolated private static func extractHTMLTitle(from html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return ""
        }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return "" }
        return decodeHTMLEntities(ns.substring(with: match.range(at: 1)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func extractReadableText(from html: String) -> String {
        var text = html
        let removalPatterns = [
            #"<script\b[^>]*>.*?</script>"#,
            #"<style\b[^>]*>.*?</style>"#,
            #"<noscript\b[^>]*>.*?</noscript>"#,
            #"<!--.*?-->"#
        ]
        for pattern in removalPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"</(p|div|section|article|header|footer|li|h[1-6]|br|tr)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: #"[ \t\f\r]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
        let named: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'"
        ]
        for (entity, replacement) in named {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        guard let numericRegex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else {
            return decoded
        }
        let ns = decoded as NSString
        let matches = numericRegex.matches(in: decoded, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            let raw = ns.substring(with: match.range(at: 1))
            let radix = raw.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(raw.dropFirst()) : raw
            if let scalarValue = UInt32(digits, radix: radix),
               let scalar = UnicodeScalar(scalarValue) {
                decoded = (decoded as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return decoded
    }

    func uploadAttachmentImmediately(attachmentId: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == attachmentId }) else { return }
        if isOpenAICompatibleProvider,
           canSendAttachmentInline(attachments[index]) || attachments[index].type == .file {
            if attachments[index].type == .image,
               let data = attachments[index].data,
               attachments[index].displayDataURL == nil {
                attachments[index].displayDataURL = inlineImageDataURL(
                    data: data,
                    fileName: attachments[index].name
                )
            }
            attachments[index].uploadStatus = .completed
            attachments[index].uploadError = nil
            return
        }
        // Skip audio only when in on-device transcription mode — server mode uploads audio like any file
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        guard !(attachments[index].type == .audio && audioFileMode == "device") else { return }

        attachments[index].uploadStatus = .uploading

        Task {
            guard let manager else {
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = "Not connected to server"
                }
                return
            }

            guard let idx = attachments.firstIndex(where: { $0.id == attachmentId }) else { return }
            guard let data = attachments[idx].data else {
                attachments[idx].uploadStatus = .error
                attachments[idx].uploadError = "Failed to read attachment data"
                return
            }

            let fileName = attachments[idx].name

            do {
                // APIClient.uploadFile handles ?process=true + SSE polling.
                // onUploaded fires after the file is stored on the server but BEFORE
                // SSE processing completes — we switch the chip from "uploading" to
                // "processing" so the user sees the two-phase status.
                let uploadResult: (fileId: String, fileObject: [String: Any])
                if attachments[idx].type == .file && Self.shouldUploadWithoutServerProcessing(fileName) {
                    let fileObject = try await manager.uploadFileOnly(data: data, fileName: fileName)
                    guard let fileId = fileObject["id"] as? String else {
                        throw APIError.responseDecoding(
                            underlying: NSError(
                                domain: "APIError",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Missing file ID in upload response"]
                            ),
                            data: nil
                        )
                    }
                    uploadResult = (fileId: fileId, fileObject: fileObject)
                } else {
                    uploadResult = try await manager.uploadFile(
                        data: data,
                        fileName: fileName,
                        onUploaded: { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                                    self.attachments[idx].uploadStatus = .processing
                                }
                            }
                        }
                    )
                }
                let (fileId, fileObject) = uploadResult
                // Update on success
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .completed
                    attachments[idx].uploadedFileId = fileId
                    attachments[idx].uploadedFileObject = fileObject
                    if attachments[idx].type == .image {
                        attachments[idx].displayDataURL = self.inlineImageDataURL(
                            data: data,
                            fileName: fileName
                        )
                    }
                    // STORAGE FIX: Release raw file data after successful upload.
                    // The file ID is sufficient for referencing the file going forward.
                    // Holding multi-MB image data in memory indefinitely causes bloat.
                    attachments[idx].data = nil
                }

                logger.info("Attachment \(fileName) uploaded + processed: \(fileId)")
            } catch {
                // Extract the clean server error message when available.
                // APIClient.waitForFileProcessing throws APIError.httpError with
                // the stripped server error text (e.g. "Error transcribing chunk…"
                // cleaned to just the relevant message).
                let errorMessage: String
                if let apiError = error as? APIError,
                   case .httpError(_, let msg, _) = apiError,
                   let msg, !msg.isEmpty {
                    errorMessage = msg
                } else {
                    errorMessage = error.localizedDescription
                }
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = errorMessage
                }
                logger.error("Attachment upload failed for \(fileName): \(errorMessage)")
            }
        }
    }

    private func canSendAttachmentInline(_ attachment: ChatAttachment) -> Bool {
        guard attachment.data != nil else { return false }
        if attachment.type == .image { return true }
        guard attachment.type == .file else { return false }
        return Self.isInlineTextFile(attachment.name)
    }

    private func canSendAttachmentWithoutCompletedUpload(_ attachment: ChatAttachment) -> Bool {
        guard attachment.data != nil else { return false }
        if canSendAttachmentInline(attachment) { return true }
        return isOpenAICompatibleProvider && attachment.type == .file
    }

    private static func isInlineTextFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return [
            "txt", "md", "markdown", "csv", "json", "jsonl", "yaml", "yml",
            "xml", "html", "htm", "css", "scss", "sass", "less", "js", "jsx",
            "ts", "tsx", "py", "swift", "java", "kt", "kts", "c", "h", "cpp",
            "hpp", "cs", "go", "rs", "rb", "php", "sh", "bash", "zsh", "ps1",
            "bat", "cmd", "sql", "toml", "ini", "cfg", "conf", "env", "log"
        ].contains(ext)
    }

    private static func shouldUploadWithoutServerProcessing(_ name: String) -> Bool {
        guard !isInlineTextFile(name) else { return false }
        let mime = mimeType(for: name)
        if mime.hasPrefix("text/") { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return [
            "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
            "exe", "dll", "dylib", "so", "apk", "ipa", "app",
            "bin", "dat", "db", "sqlite", "sqlite3",
            "psd", "ai", "sketch", "fig",
            "ttf", "otf", "woff", "woff2",
            "mp3", "m4a", "aac", "flac", "wav", "ogg",
            "mp4", "mov", "avi", "mkv", "webm",
            "doc", "docx", "xls", "xlsx", "ppt", "pptx"
        ].contains(ext)
    }

    private static func isImageFile(_ file: ChatMessageFile) -> Bool {
        file.type == "image" || (file.contentType ?? "").hasPrefix("image/")
    }

    private static func isRenderableImageReference(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if value.hasPrefix("data:image/")
            || value.hasPrefix("image:data/")
            || value.hasPrefix("file://")
            || value.hasPrefix("http://")
            || value.hasPrefix("https://") {
            return true
        }
        guard value.utf8.count <= 4_096 else { return false }
        let lower = value.lowercased()
        return [".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".avif", ".svg"].contains { lower.contains($0) }
    }

    private static func isLocalOnlyFileReference(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let lower = value.lowercased()
        return lower.hasPrefix("local-inline:")
            || lower.hasPrefix("local-binary:")
            || lower.hasPrefix("local-alpine:")
            || lower.hasPrefix("data:")
            || lower.hasPrefix("file://")
    }

    private static func preservingInlineImageFiles(
        local: [ChatMessageFile],
        incoming: [ChatMessageFile]
    ) -> [ChatMessageFile] {
        let localFiles = sanitizedMessageFiles(local)
        let incomingFiles = sanitizedMessageFiles(incoming)
        let localDisplayImages = localFiles.filter { file in
            isImageFile(file)
                && (file.displayURL?.hasPrefix("data:image/") == true
                    || file.displayURL?.hasPrefix("image:data/") == true
                    || file.displayURL?.hasPrefix("file://") == true
                    || file.url?.hasPrefix("data:image/") == true
                    || file.url?.hasPrefix("image:data/") == true
                    || file.url?.hasPrefix("file://") == true)
        }
        guard !localDisplayImages.isEmpty else { return incomingFiles }

        var merged = incomingFiles
        for image in localDisplayImages {
            let displayURL = image.displayURL ?? image.url
            if let name = image.name,
               let index = merged.firstIndex(where: { candidate in
                   candidate.name == name && isImageFile(candidate)
               }) {
                merged[index].displayURL = displayURL
                if merged[index].contentType == nil { merged[index].contentType = image.contentType }
                if merged[index].type == nil { merged[index].type = image.type }
            } else if let url = image.url,
                      let index = merged.firstIndex(where: { $0.url == url }) {
                merged[index].displayURL = displayURL
            } else if !merged.contains(where: { $0.url == image.url || $0.displayURL == displayURL }) {
                var fallback = image
                fallback.displayURL = displayURL
                merged.append(fallback)
            }
        }
        return merged
    }

    private static func serverPersistableFiles(_ files: [ChatMessageFile]) -> [ChatMessageFile] {
        sanitizedMessageFiles(files).compactMap { file in
            if isLocalOnlyFileReference(file.url) {
                return nil
            }
            if isImageFile(file)
                && (file.url?.hasPrefix("data:image/") == true
                    || file.url?.hasPrefix("image:data/") == true
                    || file.url?.hasPrefix("file://") == true) {
                return nil
            }
            var persistable = file
            persistable.displayURL = nil
            return persistable
        }
    }

    private static func sanitizedMessageFiles(_ files: [ChatMessageFile]) -> [ChatMessageFile] {
        files.compactMap(sanitizedMessageFile)
    }

    private static func sanitizedMessageForDisplay(_ message: ChatMessage) -> ChatMessage {
        var sanitized = message
        if sanitized.role == .assistant {
            sanitized.content = safeAssistantDisplayContent(
                cleanedProviderCitationArtifacts(sanitized.content)
            )
        }
        sanitized.files = sanitizedMessageFiles(sanitized.files)
        sanitized.versions = sanitized.versions.map(sanitizedMessageVersionForDisplay)
        return sanitized
    }

    private static func sanitizedConversationForDisplay(_ conversation: Conversation) -> Conversation {
        var sanitized = conversation
        sanitized.messages = sanitized.messages.map(sanitizedMessageForDisplay)
        sanitized.history.nodes = sanitized.history.nodes.mapValues(sanitizedHistoryNodeForDisplay)
        return sanitized
    }

    private static func sanitizedHistoryNodeForDisplay(_ node: HistoryNode) -> HistoryNode {
        var sanitized = node
        if sanitized.role == .assistant {
            sanitized.content = safeAssistantDisplayContent(
                cleanedProviderCitationArtifacts(sanitized.content)
            )
        }
        sanitized.files = sanitizedMessageFiles(sanitized.files)
        return sanitized
    }

    private static func sanitizedMessageVersionForDisplay(_ version: ChatMessageVersion) -> ChatMessageVersion {
        var sanitized = version
        sanitized.content = safeAssistantDisplayContent(
            cleanedProviderCitationArtifacts(sanitized.content)
        )
        sanitized.files = sanitizedMessageFiles(sanitized.files)
        return sanitized
    }

    private static func sanitizedMessageFile(_ file: ChatMessageFile) -> ChatMessageFile? {
        var sanitized = file

        if let url = sanitized.url {
            sanitized.url = safeMessageFileReference(url, isImage: isImageFile(sanitized))
        }
        if let displayURL = sanitized.displayURL {
            sanitized.displayURL = safeMessageFileReference(displayURL, isImage: isImageFile(sanitized))
        }

        if isImageFile(sanitized),
           sanitized.displayURL == nil,
           let url = sanitized.url,
           url.hasPrefix("file://") {
            sanitized.displayURL = url
        }

        if sanitized.url == nil && sanitized.displayURL == nil {
            return nil
        }
        return sanitized
    }

    private static func safeMessageFileReference(_ value: String, isImage: Bool) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isImage, let dataURI = normalizedImageDataURI(trimmed) {
            guard let compact = compactImageDataURI(dataURI) else { return nil }
            return writeGeneratedImageToCache(dataURL: compact)
        }

        if trimmed.hasPrefix("data:") || trimmed.hasPrefix("image:data/") {
            return nil
        }

        if trimmed.utf8.count > 4_096 {
            return nil
        }

        return trimmed
    }

    private static func initialConversationTitle(
        from text: String,
        files: [ChatMessageFile] = [],
        fallback: String = "新对话"
    ) -> String {
        let seed = normalizedConversationTitleSeed(text)
        guard !seed.isEmpty else {
            return initialConversationTitleFromFile(files.first) ?? fallback
        }

        let lower = seed.lowercased()
        func has(_ keywords: [String]) -> Bool {
            keywords.contains { lower.contains($0.lowercased()) }
        }
        func title(_ value: String) -> String {
            clampedConversationTitle(value, fallback: fallback)
        }

        if has(["你好", "您好", "hello", "hi", "在吗"]) && seed.count <= 12 {
            return "回复问候"
        }
        if has(["你会什么", "能做什么", "可以做什么"]) {
            return "询问能力"
        }
        if has(["天气", "weather"]) {
            if let location = conversationTitleKeywordPrefix(in: seed, keyword: "天气") {
                return title("查询\(location)天气")
            }
            return "查询天气"
        }
        if has(["小红书", "xhs", "xhslink"]) && has(["解析", "无水印", "下载", "链接", "视频", "图文"]) {
            return has(["无水印"]) ? "解析小红书无水印" : "解析小红书链接"
        }
        if has(["抖音", "douyin"]) && has(["解析", "口令", "无水印", "下载", "链接", "视频"]) {
            return has(["口令"]) ? "解析抖音口令" : "解析抖音链接"
        }
        if has(["minis"]) && has(["源码", "兼容", "对比", "怎么做"]) {
            return "对比 Minis 源码"
        }
        if has(["agent", "智能体", "local alpine", "busybox", "工具调用"]) {
            if has(["兼容", "busybox"]) { return "优化 Agent 兼容" }
            if has(["重复", "两遍"]) { return "修复 Agent 重复执行" }
            return "优化 Agent 体验"
        }
        if has(["闪屏", "白屏", "卡顿", "掉帧", "看不见", "空白", "滑动才回来", "键盘"]) {
            return "修复聊天 UI"
        }
        if has(["崩溃", "闪退", "crash"]) {
            return "修复崩溃问题"
        }
        if has(["修复", "报错", "bug", "错误"]) {
            return has(["代码", ".py", ".swift", "lua", "python"]) ? "修复代码问题" : "修复问题"
        }
        if has(["画", "生图", "生成图片", "生成一张", "改图", "图生图", "编辑图片"]) {
            return has(["改图", "图生图", "编辑图片", "换成"]) ? "编辑图片" : "生成图片"
        }
        if has(["apk", "反编译"]) {
            return "分析 APK 功能"
        }
        if has(["编译", "github actions", "actions", "run"]) {
            return "编译测试"
        }
        if has(["联网", "搜索", "查一下", "查询", "最新", "来源"]) {
            return compactIntentTitle(from: seed, defaultTitle: "联网查询", leadingVerb: "查询")
        }
        if has(["翻译", "translate"]) {
            return "翻译内容"
        }
        if has(["总结", "整理", "归纳"]) {
            return "总结内容"
        }
        if has(["删除", "删掉", "移除"]) {
            return "删除文件"
        }
        if has(["爬虫"]) {
            return "编写爬虫"
        }
        if has(["写", "创建", "生成", "运行", "脚本", "代码", "python", "lua", "swift", ".py", ".lua", ".swift"]) {
            if let language = conversationTitleCodeLanguage(in: lower) {
                if has(["运行", "执行"]) { return "运行\(language)脚本" }
                if has(["修改", "改写", "重构"]) { return "修改\(language)代码" }
                return "编写\(language)代码"
            }
            return has(["运行", "执行"]) ? "运行脚本" : "编写代码"
        }
        if has(["pwd", "ls ", "ls -", "目录", "文件列表"]) {
            return "列出目录"
        }

        return title(compactConversationTitleSeed(seed))
    }

    private static func normalizedConversationTitleSeed(_ text: String) -> String {
        var seed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return "" }

        let replacements: [(String, String)] = [
            (#"```[\s\S]*?```"#, " "),
            (#"!\[[^\]]*\]\([^)]+\)"#, " "),
            (#"\[([^\]]{1,48})\]\([^)]+\)"#, "$1"),
            (#"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=\r\n]+"#, " "),
            (#"https?://[^\s，。！？!?)）\]]+"#, " "),
            (#"\s+"#, " ")
        ]
        for (pattern, replacement) in replacements {
            seed = seed.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        let sentenceSeparators = CharacterSet(charactersIn: "\n\r。！？!?；;")
        let firstSentence = seed
            .components(separatedBy: sentenceSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? seed
        return removeConversationTitleFillers(firstSentence)
    }

    private static func initialConversationTitleFromFile(_ file: ChatMessageFile?) -> String? {
        guard let file else { return nil }
        let name = file.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        let base = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)

        if file.type == "image" || file.contentType?.hasPrefix("image/") == true {
            return "查看图片"
        }
        if ext == "pdf" {
            return "阅读 PDF"
        }
        if ["py", "lua", "swift", "js", "ts", "java", "kt", "go", "rs", "cpp", "c", "h", "html", "css", "json", "md"].contains(ext) {
            return base.isEmpty ? "查看代码文件" : clampedConversationTitle("查看\(base)", fallback: "查看代码文件")
        }
        return base.isEmpty ? "查看文件" : clampedConversationTitle("查看\(base)", fallback: "查看文件")
    }

    private static func conversationTitleCodeLanguage(in lowercasedText: String) -> String? {
        let pairs: [(String, String)] = [
            ("python", "Python"), (".py", "Python"),
            ("lua", "Lua"), (".lua", "Lua"),
            ("swift", "Swift"), (".swift", "Swift"),
            ("javascript", "JavaScript"), ("js", "JavaScript"),
            ("typescript", "TypeScript"), ("ts", "TypeScript"),
            ("java", "Java"), ("kotlin", "Kotlin"),
            ("shell", "Shell"), ("bash", "Shell"), ("sh", "Shell")
        ]
        return pairs.first { lowercasedText.contains($0.0) }?.1
    }

    private static func conversationTitleKeywordPrefix(in seed: String, keyword: String) -> String? {
        guard let range = seed.range(of: keyword) else { return nil }
        let prefix = removeConversationTitleFillers(String(seed[..<range.lowerBound]))
            .replacingOccurrences(of: "预报", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.count >= 2, prefix.count <= 10 else { return nil }
        return prefix
    }

    private static func compactIntentTitle(from seed: String, defaultTitle: String, leadingVerb: String) -> String {
        let compact = compactConversationTitleSeed(seed)
        guard !compact.isEmpty else { return defaultTitle }
        if compact.hasPrefix(leadingVerb) {
            return clampedConversationTitle(compact, fallback: defaultTitle)
        }
        return clampedConversationTitle("\(leadingVerb)\(compact)", fallback: defaultTitle)
    }

    private static func compactConversationTitleSeed(_ seed: String) -> String {
        var value = removeConversationTitleFillers(seed)
        let separators = CharacterSet(charactersIn: "，,：:、|/\\()（）[]【】{}<>《》\"“”'‘’")
        value = value.components(separatedBy: separators).first ?? value
        value = removeConversationTitleFillers(value)
        return clampedConversationTitle(value, fallback: "")
    }

    private static func removeConversationTitleFillers(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "帮我", "给我", "请帮我", "请", "麻烦你", "麻烦", "你能不能", "能不能",
            "我想", "我要", "我需要", "把这个", "把那个", "把", "这个", "那个",
            "查一下", "查下", "查询一下", "查询", "搜索一下", "搜索", "看一下", "看看",
            "一下", "继续", "然后", "还有就是", "还有"
        ]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count)
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return value
    }

    private static func clampedConversationTitle(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= 18 { return trimmed }
        return String(trimmed.prefix(18))
    }

    private func inlineImageDataURL(data: Data, fileName: String) -> String {
        let capped = FileAttachmentService.downsampleForUpload(data: data)
        return "data:image/jpeg;base64,\(capped.base64EncodedString())"
    }

    private func inlineImageDisplayReference(dataURL: String) -> String {
        Self.safeMessageFileReference(dataURL, isImage: true) ?? dataURL
    }

    private func inlineTextContext(for attachment: ChatAttachment, data: Data) -> String {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? String(data: data, encoding: .utf16)
            ?? ""
        let trimmed = text.count > 60_000 ? String(text.prefix(60_000)) + "\n\n[File truncated]" : text
        return """
        Attached file: \(attachment.name)
        ```\(Self.inlineFenceLanguage(for: attachment.name))
        \(trimmed)
        ```
        """
    }

    private func inlineBinaryContext(for attachment: ChatAttachment, data: Data) -> String {
        let contentType = mimeType(for: attachment.name)
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let maxInlineBytes = 192_000
        let previewBytes = 64_000

        if data.count <= maxInlineBytes {
            let encoded = data.base64EncodedString(options: [.lineLength64Characters])
            return """
            Attached binary file: \(attachment.name)
            MIME type: \(contentType)
            Size: \(sizeText)
            Encoding: base64
            ```base64
            \(encoded)
            ```
            """
        }

        let head = data.subdata(in: 0..<previewBytes).base64EncodedString(options: [.lineLength64Characters])
        let tail = data.subdata(in: (data.count - previewBytes)..<data.count).base64EncodedString(options: [.lineLength64Characters])
        return """
        Attached binary file: \(attachment.name)
        MIME type: \(contentType)
        Size: \(sizeText)
        The file is too large to inline fully. The first and last \(previewBytes) bytes are included as base64 previews.
        ```base64
        [first \(previewBytes) bytes]
        \(head)

        [last \(previewBytes) bytes]
        \(tail)
        ```
        """
    }

    private static func inlineFenceLanguage(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "js", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "swift": return "swift"
        case "html", "htm": return "html"
        case "css": return "css"
        case "json", "jsonl": return "json"
        case "yaml", "yml": return "yaml"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "ps1": return "powershell"
        default: return ext
        }
    }

    private static func isLocalWorkspaceAgentResult(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_workspace_result"] == "true"
            || (message.role == .system && message.content.hasPrefix("本地工作区执行结果"))
    }

    private static func isLocalAlpineAgentResult(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_alpine_result"] == "true"
            || message.content.hasPrefix("Local Alpine 执行结果")
            || message.model == "Local Alpine"
            || message.statusHistory.contains { $0.action?.lowercased() == "local_alpine" }
    }

    private static func isLocalAlpineProtocolCorrectionMessage(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_alpine_protocol_correction"] == "true"
    }

    private static func isLocalAlpineHiddenCorrectionParent(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_alpine_hidden_correction_parent"] == "true"
    }

    private static func isLocalAlpineHiddenToolParent(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_alpine_hidden_tool_parent"] == "true"
    }

    private static func isLocalNativeToolResult(_ message: ChatMessage) -> Bool {
        message.metadata?["iexa_local_native_result"] == "true"
            || message.model == "Local Native"
    }

    private static let localAlpineToolCapabilities: [LocalAlpineToolCapability] = [
        LocalAlpineToolCapability(
            name: "read_file",
            description: "Read workspace/rootfs files without shell text parsing.",
            arguments: ["path", "start_line?", "line_count?", "max_bytes?", "alias: file_read"]
        ),
        LocalAlpineToolCapability(
            name: "edit_file",
            description: "Modify an existing file by exact same-path replacements.",
            arguments: ["path", "old_text/old_string", "new_text/new_string", "replacements?", "replace_all?", "expected_count?", "alias: file_edit"]
        ),
        LocalAlpineToolCapability(
            name: "patch_file",
            description: "Modify an existing file by a unified diff.",
            arguments: ["path", "patch or patch_lines"]
        ),
        LocalAlpineToolCapability(
            name: "write_files",
            description: "Create files or perform complete same-path rewrites.",
            arguments: ["path/file_path", "content/code_lines/content_lines/content_base64", "aliases: write_file/create_file/create_files/file_write"]
        ),
        LocalAlpineToolCapability(
            name: "delete_file",
            description: "Delete workspace files with structured tool events; directories require recursive:true.",
            arguments: ["path", "recursive?", "missing_ok?", "aliases: delete_files/remove_file/remove_files/file_delete"]
        ),
        LocalAlpineToolCapability(
            name: "list_dir",
            description: "List a directory and bounded child paths using Alpine-safe commands.",
            arguments: ["path?", "max_depth?", "hidden?", "aliases: file_list/directory_list"]
        ),
        LocalAlpineToolCapability(
            name: "glob",
            description: "Find files by name pattern without hand-writing find syntax.",
            arguments: ["pattern", "path?", "max_depth?", "aliases: find_files"]
        ),
        LocalAlpineToolCapability(
            name: "grep",
            description: "Search text recursively with bounded output.",
            arguments: ["pattern/query/text", "path?", "include?", "case_sensitive?", "aliases: search_files/file_search"]
        ),
        LocalAlpineToolCapability(
            name: "verify",
            description: "Run the appropriate bounded check for a file or explicit verification command.",
            arguments: ["path? or command/cmd", "cwd?"]
        ),
        LocalAlpineToolCapability(
            name: "command",
            description: "Run one bounded shell command for list/search/run/install/build/test/verify.",
            arguments: ["command/cmd/shell/bash/exec/run/shell_execute", "cwd/workdir/working_dir/directory/dir?", "delay/delay_seconds?"]
        ),
        LocalAlpineToolCapability(
            name: "browser_use",
            description: "Fetch an HTTP/HTTPS URL from the Alpine shell with bounded output, or save it to a workspace file for preview/offload.",
            arguments: ["url/href/link", "save_to/output/path optional", "open_preview optional", "max_lines optional", "aliases: web_fetch/fetch_url/open_url"]
        )
    ]

    private static let localAlpineBusyBoxCompatibilityNotes = """
        BusyBox/ash compatibility:
        - Prefer structured wrappers (`list_dir`, `glob`, `grep`, `verify`, `browser_use`) for common list/search/check/fetch work; the host converts them into bounded BusyBox-safe commands.
        - If raw `command` is necessary, write POSIX sh/ash only. Avoid GNU/macOS/bash-only syntax unless a prior command proves support.
        - Known bad patterns here: `find -printf`, `grep -P`, `sed -i ''`, Bash `[[ ... ]]`, `source`, `mapfile`, `readarray`, and process substitution `<(...)` or `>(...)`.
        - Safe replacements: `find PATH -type f -print | sed -n '1,200p'`, `grep -E`, `. ./script.sh`, `[ ... ]`, and `while IFS= read -r line; do ...; done`.
        - Waiting/polling: use the JSON `delay`/`delay_seconds` field on a `command`/`shell_execute` step instead of putting `sleep` in shell text or `time.sleep()` in generated scripts/tests.
        - iSH/Python runtime quirk: `time.sleep()` can raise `OSError: [Errno 38] Function not implemented`; make generated Python tests deterministic and delay between tool steps through `delay`. The host also auto-repairs common Python `time.sleep(...)` file writes/runs into an iSH-compatible helper instead of asking the user to fix it.
        """

    private static func localAlpineNativeToolSchemas() -> [[String: Any]] {
        [
            [
                "type": "function",
                "function": [
                    "name": "shell_execute",
                    "description": "Run one bounded POSIX sh/BusyBox ash command in the local Alpine workspace. Use only for list/search/run/install/build/test/verify work. Do not use shell heredocs, echo, printf, cat, tee, or inline writer scripts to create source files; use file_write/file_edit instead. Use the delay argument instead of shell sleep or Python time.sleep().",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "tool_title": ["type": "string", "description": "Short user-facing title for this step."],
                            "command": ["type": "string", "description": "POSIX sh/BusyBox ash command under 1000 characters."],
                            "cwd": ["type": "string", "description": "Working directory. Defaults to /mnt/iexa."],
                            "timeout": ["type": "integer", "description": "Timeout in seconds for the command."],
                            "delay": ["type": "number", "description": "Optional host-side delay before running the command, in seconds."]
                        ],
                        "required": ["command"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "file_read",
                    "description": "Read a UTF-8 text file from /mnt/iexa or the Alpine rootfs before editing or inspecting it.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "tool_title": ["type": "string", "description": "Short user-facing title for this step."],
                            "path": ["type": "string", "description": "File path, relative to /mnt/iexa or absolute."],
                            "offset": ["type": "integer", "description": "Zero-based line offset."],
                            "lines": ["type": "integer", "description": "Maximum number of lines to read."],
                            "max_length": ["type": "integer", "description": "Maximum characters to return."],
                            "direction": ["type": "string", "enum": ["forward", "backward"]]
                        ],
                        "required": ["path"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "file_write",
                    "description": "Create or overwrite a UTF-8 text file directly. Use this for new source files or complete same-path rewrites so indentation and code structure are preserved.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "tool_title": ["type": "string", "description": "Short user-facing title for this step."],
                            "path": ["type": "string", "description": "Target file path, relative to /mnt/iexa or absolute."],
                            "content": ["type": "string", "description": "Complete UTF-8 file content."],
                            "append": ["type": "boolean", "description": "Append instead of overwrite."],
                            "create_dirs": ["type": "boolean", "description": "Create parent directories when missing."]
                        ],
                        "required": ["path", "content"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "file_edit",
                    "description": "Modify an existing UTF-8 text file by exact replacement. Always read the file first, then replace the precise old_string. Use replace_all only when every match should change.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "tool_title": ["type": "string", "description": "Short user-facing title for this step."],
                            "path": ["type": "string", "description": "Target file path, relative to /mnt/iexa or absolute."],
                            "old_string": ["type": "string", "description": "Exact text to replace."],
                            "new_string": ["type": "string", "description": "Replacement text."],
                            "replace_all": ["type": "boolean", "description": "Replace all matches instead of exactly one."]
                        ],
                        "required": ["path", "old_string", "new_string"]
                    ]
                ]
            ]
        ]
    }

    private static func localAlpineNativeAgentSystemContext() -> String {
        """
        [Local Alpine native tools]
        Use the provided native tools for local work: `file_read`, `file_write`, `file_edit`, and `shell_execute`. The iOS host executes each tool call in the local Alpine workspace and returns the real tool result to this same model turn. Do not fake results.

        Environment:
        - Workspace: `/mnt/iexa`; relative paths resolve there.
        - Shell: Alpine Linux with BusyBox/ash, not bash/macOS/Ubuntu.
        - Package manager: `apk`; never use `apt`, `yum`, `dnf`, `brew`, `sudo`, `systemctl`, or macOS-only commands.

        Tool rules:
        - Create source files with `file_write`. Modify existing files with `file_read` followed by `file_edit` or a complete same-path `file_write`.
        - Never write source code through `shell_execute` using heredocs, redirection, `echo`, `printf`, `cat`, `tee`, or inline Python writer scripts.
        - Use `shell_execute` only for bounded list/search/run/install/build/test/verify commands.
        - Commands must be POSIX sh/BusyBox ash compatible. Avoid `find -printf`, `grep -P`, Bash `[[ ... ]]`, `source`, arrays, process substitution, and GNU/macOS-only flags.
        - If a delay is needed, use the tool `delay` argument. Avoid shell `sleep` and generated Python `time.sleep()`.
        - One step should finish before the next decision. A file write plus one matching verification command is allowed; unrelated follow-up work waits for the returned result.
        - If a tool result shows success and the user goal is complete, stop tool use and answer normally with a concise real summary.
        - If native tools are rejected by the provider, fallback is one fenced `iexa_alpine` block using the same structured JSON shape.
        [/Local Alpine native tools]
        """
    }

    private static var localAlpineToolManifest: String {
        let capabilities = localAlpineToolCapabilities
            .map { capability in
                "  - `\(capability.name)`: \(capability.description) Args: \(capability.arguments.joined(separator: ", "))."
            }
            .joined(separator: "\n")
        return """
        Local Alpine tool manifest:
        - Transport: emit exactly one fenced Markdown block with language `iexa_alpine`. The app parses that block, runs it locally, and appends the real result as a later Local Alpine observation.
        - This is a client-side Markdown tool bridge, not a provider/native function. Do not check provider tool availability. Never call `iexa_alpine` through function-call syntax and never say the provider tool does not exist.
        - Valid call shape:
          ```iexa_alpine
          {"command":"pwd && ls -la","cwd":"/mnt/iexa"}
          ```
        - Invalid call shapes: `<tool iexa_alpine ...>`, `tool iexa_alpine`, function-call JSON outside a fenced block, or any sentence saying `iexa_alpine` is missing.
        - Workspace: `/mnt/iexa`. Relative paths resolve there unless the user names an absolute rootfs path.
        - Shell fallback: plain POSIX shell is allowed for bounded list/search/run/install commands. Accepted JSON keys are `command`, `cmd`, `shell`, `bash`, `exec`, `run`, or `shell_execute`; they all map to the same Local Alpine shell runner. Accepted cwd keys are `cwd`, `workdir`, `working_dir`, `directory`, or `dir`. Accepted delay keys are `delay`, `delay_seconds`, or `delaySeconds`; use them instead of shell/Python sleeps.
        - Compatibility aliases inside the `iexa_alpine` JSON are accepted: `file_read` -> `read_file`, `file_write` -> `write_files`, `file_edit` -> `edit_file`, `shell_execute` -> `command`, and `browser_use`/`web_fetch` -> bounded HTTP fetch. Keep the outer Markdown fence as `iexa_alpine`.
        - Structured shell wrappers: use top-level `list_dir`, `glob`, `grep`, `verify`, and `browser_use` for common list/search/check/fetch work. The host converts them into Alpine-safe bounded commands and records them as tool calls. `browser_use` supports optional `save_to`/`output` plus `open_preview:true` so large HTML/SVG/JSON responses can be written under `/mnt/iexa` and opened through the preview bridge instead of being pasted into chat.
        - In-app preview bridge: after creating a user-viewable file, run `iexa-open /mnt/iexa/<file>` or `iexa-open iexa://workspace/<file>`. HTTP/HTTPS opens in the built-in browser; HTML/SVG workspace files open in WebView with relative resources; other files open through native preview.
        - Command dialect: this is Alpine Linux with BusyBox/ash. Generate POSIX sh/ash-compatible commands, not Ubuntu/Debian/macOS commands.
        \(localAlpineBusyBoxCompatibilityNotes)
        - Package commands: use `apk info -e <pkg>` to check an installed package, `apk search <pkg>` to search, and `apk add --no-cache <pkg>` to install. Do not use `apt`, `apt-get`, `yum`, `dnf`, `pacman`, `brew`, `sudo`, `systemctl`, `launchctl`, or macOS-only utilities.
        - Rootfs/environment/dependency checks: if the user asks whether Python/Lua/Node/C++ or dependencies exist, inspect the running Alpine rootfs/runtime/toolchain directly with bounded `command -v`, `--version`, `apk info`, `python3 -m pip list`, `find /usr/lib /usr/local/lib`, or small module-list commands. Do not invent `/mnt/iexa/rootfs`; `/mnt/iexa` is only the workspace mount. Do not only search `/mnt/iexa` project dependency files unless the user specifically asks for project dependency files.
        - Service/process commands: prefer foreground commands and bounded verification. Do not assume OpenRC/system services are available unless a prior command proves it.
        - `command`/`shell_execute` is shell text only. For structured tools, use top-level keys such as `read_file`, `file_read`, `write_files`, `file_write`, `edit_file`, `patch_file`, `delete_file`, `delete_files`, `list_dir`, `glob`, `grep`, `verify`, or `browser_use`.
        - Hard protocol rule: for any intermediate local-work step, pure prose means "stop and answer normally"; it will not be auto-upgraded into execution. Emit a real tool block only when you are intentionally requesting local execution.
        - JSON tool capabilities:
        \(capabilities)
        - Source file writes: all code files (`.py`, `.js`, `.ts`, `.lua`, `.sh`, `.html`, `.css`, `.swift`, `.java`, `.go`, `.rs`, etc.) are indentation/escaping-sensitive. Never write them through shell text redirection, heredocs, `echo`, `printf`, `cat`, `tee`, or inline writer scripts. Use structured `write_files`/`file_write` with `code_lines`, `content_lines`, or `content_base64`; use same-path `edit_file`/`file_edit` or `patch_file` for targeted modifications.
        - Generated scripts must be runtime-compatible before execution: Python should avoid `time.sleep()`; shell scripts must be BusyBox ash/POSIX, not bash. If a delay is needed, set `delay` on the next command step.
        - Code write validation: source files must be written as exact UTF-8 bytes through structured tools. Python additionally gets AST/compile validation, but the structured-write rule applies to every programming language, not only `.py`.
        - Markdown hygiene: when showing code to the user, put the closing ``` fence alone on its own line. Never append headings, bullets, or prose to the same line as a closing fence.
        - Tool loop: one assistant turn emits at most one `iexa_alpine` block for one meaningful bounded step; the next turn must read the returned stdout/stderr/exit code before deciding whether to continue. For code creation, a structured file write plus one bounded syntax/run verification may share the same block only when they validate the same change.
        - Tool-call turn output: when emitting an `iexa_alpine` block, do not append success claims, guessed stdout, file contents, or final summaries after the block. The host will return the real Local Alpine observation in the next turn.
        - Visible preface: prefer no prose before the block. If needed, write one short progress sentence only. Never ask the user to send back local execution results; the host app returns results automatically.
        """
    }

    private static func localAlpineExecutionStateSystemContext(from messages: [ChatMessage]) -> String? {
        let alpineMessages = messages.filter {
            isLocalAlpineAgentResult($0) && !isLocalAlpineProtocolCorrectionMessage($0)
        }
        let latestUserGoal = messages.last(where: {
            $0.role == .user && !Self.isLocalAlpineAgentResult($0)
        })?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alpineMessages.isEmpty else {
            return """
            [Local Alpine execution state]
            No Local Alpine tool_result has been observed yet for this turn. Treat this as the start of a Codex CLI style local agent session.

            Current user goal:
            \(indentForSystemContext(clippedForSystemContext(latestUserGoal ?? "（未提供）", maxCharacters: 1_500)))

            First-turn bootstrap policy:
            - Do not spend a turn only restating that you will inspect the environment. If inspection is needed, emit the actual `iexa_alpine` block immediately.
            - If the user asks for rootfs/system/runtime dependencies, check the Alpine rootfs directly (`apk info`, `command -v`, version commands, `/usr/lib`, Python site-packages, pip list). Do not limit the answer to `/mnt/iexa` project files.
            - Treat imperative shorthand as local work in this mode: write/create/run/test/check/read/list/modify/change/replace/delete/rerun/continue and 写/创建/运行/跑/测试/检查/看下/读/改/换/删/再跑/继续 mean emit `iexa_alpine` when they refer to code, files, dependencies, runtime, terminal, or prior Local Alpine work.
            - If demo details are missing, choose safe defaults and execute: `example.com` or `example.org` for crawler URLs, `test.lua`/`main.cpp`/`simple_spider.py` for demo filenames, and small hello/test input data.
            - If the user is asking a capability question, explanation, example, comparison, or "can this run" style question, answer normally and do not emit `iexa_alpine`.
            - If the task depends on unknown current files, first get a small workspace listing, then continue from that observation.
            - If the task depends on compilers or packages, use one focused probe only when the toolchain has not already been observed.
            - Use the BusyBox/ash command dialect. Prefer structured wrappers (`list_dir`, `glob`, `grep`, `verify`) over raw `find`/`grep`; never use known GNU/bash-only patterns like `find -printf`, `grep -P`, Bash `[[ ... ]]`, `source`, or process substitution.
            - If the user asked to write/create/build/run code, do one meaningful bounded step at a time. A structured file write plus one bounded syntax/run verification may share the same tool block only when they validate the same change; do not bundle unrelated follow-up work into the same block.
            - If the user gave an explicit simple file operation target, combine the operation with a minimal `pwd`/`ls` verification instead of running a separate bootstrap.
            - Do not ask for confirmation for explicit operations bounded to `/mnt/iexa`; user wording such as delete/remove/modify/run/test/read/check is already confirmation. Ask only for paths outside `/mnt/iexa` or multiple unsafe targets.
            - Only treat run/test/build/fix/install/read/write/delete/search as an operation request when the user asks you to actually perform it. If the wording is asking for advice or feasibility, do not use the tool.
            - For "run this code" follow-ups, use the latest runnable code block, write it under `/mnt/iexa`, run the matching interpreter/compiler, and summarize the real output.
            - Do not ask the user how to operate the environment. Use one fenced `iexa_alpine` block as the first tool_use.
            [/Local Alpine execution state]
            """
        }

        let blocks = alpineMessages.suffix(2).map { message -> String in
            let metadata = message.metadata ?? [:]
            let status = message.statusHistory.last?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let state = message.isStreaming ? "running" : "completed"
            let command = metadata["iexa_local_alpine_display_command"]
            let cwd = metadata["iexa_local_alpine_cwd"]
            let rawResult = metadata["iexa_local_alpine_raw_result"]
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let commandResults = LocalAlpineAgentCommandResult.decodeMetadata(metadata["iexa_local_alpine_command_results"])
            let writtenFiles = LocalAlpineWrittenFile.decodeMetadata(metadata["iexa_local_alpine_written_files"])

            var lines = ["- state: \(state)"]
            if let latestUserGoal, !latestUserGoal.isEmpty {
                lines.append("  user_goal:")
                lines.append(indentForSystemContext(clippedForSystemContext(latestUserGoal, maxCharacters: 1_500)))
            }
            if let status, !status.isEmpty {
                lines.append("  status: \(status)")
            }
            if let cwd, !cwd.isEmpty {
                lines.append("  cwd: \(cwd)")
            }
            if let command, !command.isEmpty {
                lines.append("  command/request:")
                lines.append(indentForSystemContext(clippedForSystemContext(
                    redactedLocalAlpineInternalPaths(in: command),
                    maxCharacters: 1_500
                )))
            }
            if !content.isEmpty {
                lines.append(message.isStreaming ? "  partial output:" : "  result:")
                lines.append(indentForSystemContext(contextTextForModel(
                    redactedLocalAlpineInternalPaths(in: content),
                    label: "local-alpine-result",
                    maxInlineCharacters: 4_000
                )))
            }
            if let rawResult, !rawResult.isEmpty, rawResult != content {
                lines.append("  raw result:")
                lines.append(indentForSystemContext(contextTextForModel(
                    redactedLocalAlpineInternalPaths(in: rawResult),
                    label: "local-alpine-raw-result",
                    maxInlineCharacters: 4_000
                )))
            }
            if !commandResults.isEmpty {
                lines.append("  command observations:")
                for result in commandResults.suffix(3) {
                    let exit = result.exitCode.map(String.init) ?? "unknown"
                    lines.append(indentForSystemContext("""
                    command: \(result.command)
                    cwd: \(result.cwd)
                    exit_code: \(exit)
                    output:
                    \(result.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（无输出）" : contextTextForModel(redactedLocalAlpineInternalPaths(in: result.outputPreview), label: "local-alpine-command-output", maxInlineCharacters: 4_000))
                    """))
                }
            }
            if !writtenFiles.isEmpty {
                lines.append("  written files:")
                let fileLines = writtenFiles.map { file in
                    "- \(file.path) (\(file.lineCount) 行, \(file.byteCount) bytes)"
                }.joined(separator: "\n")
                lines.append(indentForSystemContext(fileLines))
            }
            if localAlpineOutputHasPythonSyntaxIssue(content + "\n" + (rawResult ?? "")) {
                lines.append("  required next action:")
                lines.append(indentForSystemContext("Code syntax/indentation error detected. Inspect the target project file, then repair the original path in place through byte-preserving iexa_alpine JSON edit_file/patch_file/write_files and run a language-appropriate bounded verification command. For Python, keep the full file exact when the Python write gate requires a complete-file write. Do not create a replacement filename or repeat only the same failed command."))
            }
            if localAlpineOutputHasBusyBoxCompatibilityIssue(content + "\n" + (rawResult ?? "")) {
                lines.append("  required next action:")
                lines.append(indentForSystemContext("BusyBox/ash compatibility issue detected. Do not repeat the same command. Use structured wrappers such as list_dir/glob/grep/verify, or rewrite as POSIX sh/ash without GNU/bash-only flags such as find -printf, grep -P, [[ ... ]], source, or process substitution."))
            }
            let observationText = [content, rawResult].compactMap { $0 }.joined(separator: "\n")
            let normalizedObservation = normalizedLocalAlpineResultTextForFollowUpCheck(observationText)
            let toolCalls = LocalAlpineToolCall.decodeMetadata(metadata["iexa_local_alpine_tool_calls"])
            let needsFollowUp = localAlpineResultNeedsFollowUp(
                observationText,
                commandResults: commandResults,
                toolCalls: toolCalls,
                latestUserText: latestUserGoal
            )
            let verdict: String
            let controllerPolicy: String
            if message.isStreaming {
                verdict = "tool_running"
                controllerPolicy = "Wait for the Local Alpine result before making another tool call."
            } else if needsFollowUp {
                verdict = containsLocalAlpineFailureMarker(normalizedObservation)
                    ? "needs_next_tool_after_failure"
                    : "needs_next_tool_after_incomplete_observation"
                controllerPolicy = "Inspect the observation, choose one different bounded iexa_alpine step, and continue the agent loop."
            } else {
                verdict = "ready_for_final_summary"
                controllerPolicy = "Do not emit another iexa_alpine block unless the user asks for more work. Summarize the verified result."
            }
            lines.append("  controller_verdict: \(verdict)")
            lines.append("  controller_policy:")
            lines.append(indentForSystemContext(controllerPolicy))
            return lines.joined(separator: "\n")
        }

        return """
        [Local Alpine execution state]
        The iOS host app simulates a Codex CLI tool loop. A fenced `iexa_alpine` block is the local tool_use, and each Local Alpine result below is the tool_result/observation. This state is real host-side execution state, even if the command block itself is no longer visible in chat.

        \(blocks.joined(separator: "\n\n"))

        Rules for this state:
        - If state is running, tell the user the Local Alpine command is still running or ask whether to stop it; do not apologize that no executable block was emitted.
        - If result output is present, answer from that output as the source of truth.
        - Follow controller_verdict: `needs_next_tool_*` means continue with exactly one new `iexa_alpine` block; `ready_for_final_summary` means stop tool use and summarize; `tool_running` means wait or report running status.
        - Missing `iexa_alpine` on a `needs_next_tool_*` state is invalid. Use the structured tools (`read_file`, `write_files`, `edit_file`, `patch_file`, `list_dir`, `glob`, `grep`, `verify`, `command`) instead of prose.
        - If prior observations already prove a tool/package exists, do not repeat a generic environment probe. Move to the user's concrete task.
        - If the latest result shows the task is incomplete or failed, emit one next bounded `iexa_alpine` block to inspect, fix, or verify. Do not repeat the exact same command unless the output gives a clear reason.
        - Treat each tool turn as one ordered step. A structured write/edit plus one verification command is OK; do not pack multiple repair/run cycles into one block.
        - Treat `.iexa-terminal-scripts/command-*.sh` paths as internal one-shot host temp scripts. Never read, edit, verify, or mention them as user files.
        - If the latest user message is an interruption/meta question about the failure, answer that question and wait; do not auto-run another `iexa_alpine` block until the user explicitly asks to continue/fix/run.
        - If the latest result contains a code syntax/indentation error, inspect the target project file, then emit a same-path fix through byte-preserving `iexa_alpine` JSON `edit_file`, `patch_file`, or `write_files`, then run a language-appropriate bounded verification command. Python still requires AST/compile-safe full-file writes when the Python write gate asks for them; do not create a sibling replacement file and do not repeat only the same failed command.
        - If the latest result contains a BusyBox/ash compatibility error, rewrite the command using `list_dir`, `glob`, `grep`, `verify`, or POSIX sh/ash syntax. Do not repeat GNU/bash-only syntax.
        [/Local Alpine execution state]
        """
    }

    private func inlineTextDisplayFile(for attachment: ChatAttachment, data: Data) -> ChatMessageFile {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let preview = text.count > 120_000 ? String(text.prefix(120_000)) + "\n\n[Preview truncated]" : text
        let contentType = inlineTextContentType(for: attachment.name)
        let previewData = preview.data(using: .utf8) ?? data
        return ChatMessageFile(
            type: "file",
            url: "local-inline:\(attachment.id.uuidString)",
            name: attachment.name,
            contentType: contentType,
            displayURL: "data:\(contentType);base64,\(previewData.base64EncodedString())"
        )
    }

    private func inlineTextContentType(for name: String) -> String {
        let detected = mimeType(for: name)
        return detected == "application/octet-stream" ? "text/plain" : detected
    }

    private static func clippedForSystemContext(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n...（内容过长，已截断）"
    }

    private static func redactedLocalAlpineInternalPaths(in text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)(?:/mnt/iexa/)?\.iexa-terminal-scripts/command-[A-Za-z0-9-]+\.sh"#,
            with: ".iexa-terminal-scripts/<internal-command-script>",
            options: .regularExpression
        )
    }

    private static func indentForSystemContext(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    private static func localAlpineCommandPreview(from content: String) -> String {
        if let preview = localAlpineInstructionPreview(from: content) {
            return preview
        }

        let cleaned = content
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 1_000 else { return cleaned }
        return String(cleaned.prefix(1_000)) + "..."
    }

    private static func localAlpineInstructionPreview(from content: String) -> String? {
        for block in localAlpineInstructionBlocks(from: content) {
            if let data = block.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let preview = localAlpineInstructionPreview(from: object) {
                return clipLocalAlpinePreview(preview)
            }

            let shell = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shell.isEmpty {
                return clipLocalAlpinePreview(shell)
            }
        }
        return nil
    }

    private static func localAlpineInstructionPreview(from object: Any) -> String? {
        if let array = object as? [Any] {
            let previews = array.compactMap { localAlpineInstructionPreview(from: $0) }
            return previews.isEmpty ? nil : previews.prefix(4).joined(separator: "\n---\n")
        }

        if let command = object as? String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let dict = object as? [String: Any] else { return nil }
        if let nested = dict["iexa_alpine"] ?? dict["commands"] {
            return localAlpineInstructionPreview(from: nested)
        }
        if let runArray = dict["run"] as? [Any],
           let preview = localAlpineInstructionPreview(from: runArray) {
            return preview
        }
        for key in ["command", "cmd", "shell", "bash", "exec"] where dict[key] is [Any] {
            if let preview = localAlpineInstructionPreview(from: dict[key] as Any) {
                return preview
            }
        }

        var lines: [String] = []
        if let cwd = dict["cwd"] as? String, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("cwd: \(cwd.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        lines.append(contentsOf: localAlpineWriteFilePreviews(from: dict))
        if let command = localAlpineCommandString(from: dict),
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("command: \(command.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let op = localAlpineStringValue(dict["op"] ?? dict["operation"] ?? dict["type"]) {
            lines.append("operation: \(op)")
        } else if let tool = localAlpineStringValue(dict["tool"] ?? dict["function"] ?? dict["action"] ?? dict["name"]) {
            lines.append("tool: \(tool)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func localAlpineWriteFilePreviews(from object: Any?) -> [String] {
        guard let object else { return [] }
        let values: [Any]
        if let array = object as? [Any] {
            values = array
        } else {
            values = [object]
        }

        return values.compactMap { value in
            guard let dict = value as? [String: Any] else { return nil }
            if let nested = localAlpineWriteFilesObject(from: dict) {
                let nestedPreviews = localAlpineWriteFilePreviews(from: nested)
                if !nestedPreviews.isEmpty {
                    return nestedPreviews.joined(separator: "\n")
                }
            }
            guard let path = ((dict["path"] as? String)
                ?? (dict["file_path"] as? String)
                ?? (dict["file"] as? String)
                ?? (dict["name"] as? String)
                ?? (dict["filename"] as? String)
                ?? (dict["write_file"] as? String)
                ?? (dict["target"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            let size: Int?
            if let content = (dict["content"] as? String)
                ?? (dict["contents"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["body"] as? String)
                ?? (dict["code"] as? String) {
                size = content.utf8.count
            } else if let lines = (dict["code_lines"] as? [String])
                ?? (dict["content_lines"] as? [String])
                ?? (dict["lines"] as? [String]) {
                size = lines.joined(separator: "\n").utf8.count
            } else if let base64 = (dict["content_base64"] as? String) ?? (dict["base64"] as? String) {
                size = (base64.count * 3) / 4
            } else {
                size = nil
            }
            if let size {
                return "write_file: \(path) (\(size) B)"
            }
            return "write_file: \(path)"
        }
    }

    private static func clipLocalAlpinePreview(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: #""content_base64"\s*:\s*"[^"]+""#, with: #""content_base64":"<hidden>""#, options: .regularExpression)
            .replacingOccurrences(of: #""base64"\s*:\s*"[^"]+""#, with: #""base64":"<hidden>""#, options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 1_000 else { return cleaned }
        return String(cleaned.prefix(1_000)) + "..."
    }

    private static func firstLocalAlpineCommand(in content: String) -> ParsedLocalAlpineCommand? {
        localAlpineCommands(in: content).first
    }

    private static func localAlpineCommands(in content: String) -> [ParsedLocalAlpineCommand] {
        var commands: [ParsedLocalAlpineCommand] = []
        for block in localAlpineInstructionBlocks(from: content) {
            if let data = block.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                commands.append(contentsOf: localAlpineCommands(from: object))
                continue
            }

            let shell = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shell.isEmpty {
                commands.append(ParsedLocalAlpineCommand(
                    command: shell,
                    cwd: "/mnt/iexa",
                    hasWriteFiles: false,
                    writeFilePaths: []
                ))
            }
        }
        return commands
    }

    private static func localAlpineInstructionBlocks(from content: String) -> [String] {
        LocalAlpineAgentService.instructionBlocks(from: content)
    }

    private static func contentContainsLocalAlpineInstruction(_ content: String) -> Bool {
        !localAlpineInstructionBlocks(from: content).isEmpty
    }

    private static func localAlpineExecutableFingerprint(from content: String) -> String {
        let blocks = localAlpineInstructionBlocks(from: content)
        let candidates = blocks.isEmpty ? [content] : blocks
        let parts = candidates.compactMap { block -> String? in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(object),
               let normalizedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let normalized = String(data: normalizedData, encoding: .utf8) {
                return "json:\(normalized)"
            }
            return "text:\(trimmed)"
        }
        return parts.joined(separator: "\n---iexa-alpine-block---\n")
    }

    private static func firstLocalAlpineCommand(from object: Any) -> ParsedLocalAlpineCommand? {
        localAlpineCommands(from: object).first
    }

    private static func localAlpineCommands(from object: Any) -> [ParsedLocalAlpineCommand] {
        if let array = object as? [Any] {
            return array.flatMap { localAlpineCommands(from: $0) }
        }

        if let command = object as? String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [ParsedLocalAlpineCommand(
                command: trimmed,
                cwd: "/mnt/iexa",
                hasWriteFiles: false,
                writeFilePaths: []
            )]
        }

        guard let dict = object as? [String: Any] else { return [] }
        if let nested = dict["iexa_alpine"] {
            return localAlpineCommands(from: nested)
        }
        var nestedCommands = dict["commands"].map { localAlpineCommands(from: $0) } ?? []
        if let runArray = dict["run"] as? [Any] {
            nestedCommands.append(contentsOf: localAlpineCommands(from: runArray))
        }
        for key in ["command", "cmd", "shell", "bash", "exec"] where dict[key] is [Any] {
            nestedCommands.append(contentsOf: localAlpineCommands(from: dict[key] as Any))
        }

        let command = localAlpineCommandString(from: dict)
        let writeFilePaths = Self.localAlpineWriteFilePaths(from: dict)
        guard command?.isEmpty == false || !writeFilePaths.isEmpty else { return nestedCommands }
        let cwd = localAlpineCWDString(from: dict)
        return [ParsedLocalAlpineCommand(
            command: command ?? "",
            cwd: cwd?.isEmpty == false ? cwd! : "/mnt/iexa",
            hasWriteFiles: !writeFilePaths.isEmpty,
            writeFilePaths: writeFilePaths
        )] + nestedCommands
    }

    private static func localAlpineCommandString(from dict: [String: Any]) -> String? {
        for key in ["command", "cmd", "shell", "bash", "exec", "run"] {
            if dict[key] is [Any] {
                continue
            }
            if let value = localAlpineCommandString(fromValue: dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func localAlpineCommandString(fromValue value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = value as? [Any] {
            if array.contains(where: { $0 is [String: Any] }) {
                return nil
            }
            let parts = array.compactMap { localAlpineStringValue($0) }
            guard !parts.isEmpty, parts.count == array.count else { return nil }
            return parts.map(localAlpineShellQuote).joined(separator: " ")
        }
        guard let dict = value as? [String: Any] else { return nil }
        let args = localAlpineArgumentString(from: dict["args"] ?? dict["arguments"] ?? dict["argv"])
        for key in ["command", "cmd", "shell", "bash", "exec", "run"] {
            guard let command = localAlpineStringValue(dict[key]) else { continue }
            return args.map { "\(command) \($0)" } ?? command
        }
        if let executable = localAlpineStringValue(dict["program"])
            ?? localAlpineStringValue(dict["binary"])
            ?? localAlpineStringValue(dict["executable"]) {
            return [localAlpineShellQuote(executable), args].compactMap { $0 }.joined(separator: " ")
        }
        return nil
    }

    private static func localAlpineArgumentString(from value: Any?) -> String? {
        if let string = localAlpineStringValue(value) {
            return string
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { argument -> String? in
                if let string = localAlpineStringValue(argument) { return localAlpineShellQuote(string) }
                if let int = argument as? Int { return localAlpineShellQuote(String(int)) }
                if let double = argument as? Double { return localAlpineShellQuote(String(double)) }
                if let bool = argument as? Bool { return localAlpineShellQuote(bool ? "true" : "false") }
                return nil
            }
            guard !parts.isEmpty, parts.count == array.count else { return nil }
            return parts.joined(separator: " ")
        }
        return nil
    }

    private static func localAlpineStringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func localAlpineCWDString(from dict: [String: Any]) -> String? {
        for key in ["cwd", "workdir", "working_dir", "directory", "dir"] {
            if let value = localAlpineStringValue(dict[key]) {
                return value
            }
        }
        for key in ["command", "cmd", "shell", "bash", "exec", "run", "verify", "check"] {
            if let nested = dict[key] as? [String: Any],
               let value = localAlpineCWDString(from: nested) {
                return value
            }
        }
        return nil
    }

    private static func hasLocalAlpineWriteFiles(_ object: Any?) -> Bool {
        !localAlpineWriteFilePaths(from: object).isEmpty
    }

    private static func localAlpineWriteFilesObject(from dict: [String: Any]) -> Any? {
        dict["write_files"] ?? dict["write_file"] ?? dict["files"]
    }

    private static func localAlpineWriteFilePaths(from object: Any?) -> [String] {
        guard let object else { return [] }
        if let array = object as? [Any] {
            return array.flatMap { localAlpineWriteFilePaths(from: $0) }
        }
        guard let dict = object as? [String: Any] else { return [] }
        if let nested = localAlpineWriteFilesObject(from: dict) {
            let nestedPaths = localAlpineWriteFilePaths(from: nested)
            if !nestedPaths.isEmpty { return nestedPaths }
        }
        guard let path = ((dict["path"] as? String)
            ?? (dict["file_path"] as? String)
            ?? (dict["file"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["filename"] as? String)
            ?? (dict["write_file"] as? String)
            ?? (dict["target"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return []
        }
        let hasContent = dict["content"] != nil
            || dict["contents"] != nil
            || dict["text"] != nil
            || dict["body"] != nil
            || dict["code"] != nil
            || dict["code_lines"] != nil
            || dict["content_lines"] != nil
            || dict["lines"] != nil
            || dict["content_base64"] != nil
            || dict["base64"] != nil
        return hasContent ? [path] : []
    }

    private static func localAlpineRuntimePath(for path: String, cwd: String) -> String {
        let cleanedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !cleanedPath.isEmpty else { return "/mnt/iexa/untitled.py" }
        if cleanedPath.hasPrefix("/mnt/iexa/") || cleanedPath == "/mnt/iexa" {
            return cleanedPath
        }
        if cleanedPath.hasPrefix("/") {
            return "/mnt/iexa\(cleanedPath)"
        }
        let cleanedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let base = cleanedCWD.isEmpty ? "/mnt/iexa" : cleanedCWD
        return base.hasSuffix("/") ? base + cleanedPath : base + "/" + cleanedPath
    }

    private static func localAlpineShellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func localAlpineWorkspaceRelativePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/mnt/iexa/") {
            normalized = String(normalized.dropFirst("/mnt/iexa/".count))
        } else if normalized == "/mnt/iexa" {
            normalized = "."
        } else if normalized.hasPrefix("/") {
            normalized = String(normalized.dropFirst())
        }
        return normalized.isEmpty ? "." : normalized
    }

    private static func localAlpineCommandKey(command: String, cwd: String) -> String {
        let normalizedCommand = command
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedCWD = cwd
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(normalizedCWD.isEmpty ? "/mnt/iexa" : normalizedCWD)\n\(normalizedCommand)"
    }

    private static func localAlpineFailureSignature(_ result: LocalAlpineAgentCommandResult) -> String {
        let lines = result.outputPreview
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(8)
            .joined(separator: "\n")
        let clipped = String(lines.prefix(1_500)).lowercased()
        return "\(result.exitCode.map(String.init) ?? "unknown")\n\(clipped)"
    }

    private static func localAlpineOutputHasPythonSyntaxIssue(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("indentationerror")
            || lowercased.contains("syntaxerror")
            || lowercased.contains("taberror")
    }

    private static func localAlpineOutputHasBusyBoxCompatibilityIssue(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        let markers = [
            "busybox/ash compatibility guard",
            "busybox compatibility",
            "not supported by busybox",
            "find: unrecognized: -printf",
            "grep: unrecognized option: p",
            "bad substitution",
            "syntax error: unexpected \"(\"",
            "syntax error: unexpected \"[[\"",
            "oserror: [errno 38] function not implemented"
        ]
        return markers.contains { lowercased.contains($0) }
    }

    private static func localAlpineCommandIsPythonSyntaxCheckOnly(_ command: String) -> Bool {
        let normalized = command
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("python3 -m py_compile")
            || normalized.contains("python -m py_compile")
    }

    private static func localAlpineCommandInspectsPythonFile(_ command: String) -> Bool {
        let normalized = command
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains(".py") else { return false }
        return normalized.contains("nl -ba")
            || normalized.contains("cat -n")
            || normalized.contains("sed -n")
            || normalized.contains("awk")
            || normalized.contains("python3 - <<")
            || normalized.contains("python - <<")
    }

    private static func localAlpineCommandInspectsSystemPythonFile(_ command: String) -> Bool {
        let normalized = command
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard localAlpineCommandInspectsPythonFile(normalized) else { return false }
        return normalized.contains("/usr/lib/python")
            || normalized.contains("/usr/local/lib/python")
            || normalized.contains("/site-packages/")
            || normalized.contains("/dist-packages/")
    }

    private static func localAlpineCommandWritesCodeWithHeredoc(_ command: String) -> Bool {
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

    private static func localAlpineCommandMutatesState(_ command: String) -> Bool {
        let normalized = command
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if localAlpineCommandWritesCodeWithHeredoc(normalized) {
            return true
        }
        let mutationPatterns = [
            #"(?m)(^|[;&|]\s*)apk\s+add\b"#,
            #"(?m)(^|[;&|]\s*)(?:python3?\s+-m\s+pip|pip3?|npm|yarn|pnpm)\s+(?:install|i|add)\b"#,
            #"(?m)(^|[;&|]\s*)(?:rm|mv|cp|mkdir|touch|chmod|chown|ln)\b"#,
            #"(?m)(^|[;&|]\s*)(?:git\s+(?:checkout|switch|merge|pull|reset|clean|apply|am)|patch)\b"#,
            #"(?m)(^|[;&|]\s*)(?:sed|perl)\s+[^;&|]*\s-i\b"#,
            #"(?:^|[^0-9])(?:>>?|1>)\s*[^;&|]+"#
        ]
        return mutationPatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func localAlpineCommandTargetsCodeOrIndentationSensitiveFile(_ normalizedCommand: String) -> Bool {
        let filePatterns = [
            #"\.(py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonl|yaml|yml|toml|xml|md|dockerfile|makefile)(?:['"\s;|&>]|$)"#,
            #"(^|[/\s])makefile(?:['"\s;|&>]|$)"#,
            #"(^|[/\s])dockerfile(?:['"\s;|&>]|$)"#
        ]
        return filePatterns.contains { pattern in
            normalizedCommand.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func localAlpinePythonFilePath(command: String, output: String, cwd: String) -> String? {
        let combined = output + "\n" + command
        if let failedDraft = firstLocalAlpinePythonPath(
            in: combined,
            pattern: #"失败草稿已保留：`([^`]+\.py)`"#,
            allowFailedDraft: true
        ) {
            return failedDraft
        }

        if let explicitTarget = firstLocalAlpinePythonPath(
            in: combined,
            pattern: #"目标 Python 文件：`([^`]+\.py)`"#
        ) ?? firstLocalAlpinePythonPath(
            in: combined,
            pattern: #"== target Python file:\s*([^\n]+\.py)"#
        ) ?? firstLocalAlpinePythonPath(
            in: combined,
            pattern: #"`([^`]+\.py)`\s*写入已拒绝"#
        ) {
            return explicitTarget
        }

        let commandPaths = localAlpineCommands(in: command)
            .flatMap(\.writeFilePaths)
            .map { localAlpineRuntimePath(for: $0, cwd: cwd) }
            .filter { isUserPythonPath($0) }
        if let first = commandPaths.first {
            return first
        }

        let patterns = [
            #"File\s+\"([^\"]+\.py)\""#,
            #"\(([A-Za-z0-9_./\-]+\.py),\s*line\s+\d+\)"#,
            #"([/A-Za-z0-9_.\-]+\.py)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let nsCombined = combined as NSString
            let range = NSRange(location: 0, length: nsCombined.length)
            let matches = regex.matches(in: combined, range: range)
            for match in matches where match.numberOfRanges >= 2 {
                let candidate = nsCombined.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty { continue }
                let path = normalizedLocalAlpinePythonPath(candidate, cwd: cwd)
                if isUserPythonPath(path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func firstLocalAlpinePythonPath(
        in text: String,
        pattern: String,
        allowFailedDraft: Bool = false
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }
        let candidate = nsText.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = normalizedLocalAlpinePythonPath(candidate, cwd: "/mnt/iexa")
        return isUserPythonPath(path, allowFailedDraft: allowFailedDraft) ? path : nil
    }

    private static func localAlpinePythonTargetPath(output: String, command: String, cwd: String) -> String? {
        let combined = output + "\n" + command
        if let explicitTarget = firstLocalAlpinePythonPath(
            in: combined,
            pattern: #"目标 Python 文件：`([^`]+\.py)`"#
        ) ?? firstLocalAlpinePythonPath(
            in: combined,
            pattern: #"== target Python file:\s*([^\n]+\.py)"#
        ) ?? firstLocalAlpinePythonPath(
            in: combined,
            pattern: #"`([^`]+\.py)`\s*写入已拒绝"#
        ) {
            return explicitTarget
        }

        return localAlpineCommands(in: command)
            .flatMap(\.writeFilePaths)
            .map { localAlpineRuntimePath(for: $0, cwd: cwd) }
            .first { isUserPythonPath($0) }
    }

    private static func normalizedLocalAlpinePythonPath(_ path: String, cwd: String) -> String {
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

    private static func isUserPythonPath(_ path: String, allowFailedDraft: Bool = false) -> Bool {
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
        if normalized.contains("/.iexa-write-") {
            return false
        }
        if allowFailedDraft, normalized.hasPrefix("/mnt/iexa/.iexa_failed_writes/") {
            return true
        }
        if normalized.hasPrefix("/mnt/iexa/.iexa_failed_writes/") {
            return false
        }
        return normalized.hasPrefix("/mnt/iexa/")
    }

    private static func localAlpineInspectCommand(forPythonFile path: String?) -> String {
        let file = (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? path!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "/mnt/iexa/script.py"
        let quoted = "'" + file.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "printf '== file with line numbers ==\\n' && nl -ba \(quoted) | sed -n '1,160p'"
    }

    private static func isLocalAlpineInterjection(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if isExplicitLocalAlpineResumeRequest(normalized) { return false }
        let terms = [
            "怎么还报错", "怎么老是报错", "为什么一直", "怎么回事", "什么问题",
            "哪里错", "哪里错误", "原因是什么", "为啥", "为什么", "你在干嘛",
            "别执行", "不要执行", "先别执行", "停一下", "先停", "停止", "暂停",
            "不要再跑", "别再跑", "别继续", "不要继续", "先解释", "解释一下",
            "说清楚", "别动", "先别动"
        ]
        return terms.contains { normalized.contains($0) }
    }

    private static func isExplicitLocalAlpineResumeRequest(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let terms = [
            "继续修复", "继续执行", "继续运行", "继续跑", "继续调试",
            "修复并运行", "修好再运行", "自动修复", "直接修复", "你来修复",
            "直接改", "直接写入", "直接执行", "直接运行", "写入运行", "写入并运行",
            "写入执行", "写入并执行", "修改执行", "修改并执行", "修改运行", "修改并运行",
            "帮我修改执行", "帮我修改运行", "你直接写入运行", "修复它", "把它修好",
            "继续 agent", "继续agent", "继续处理", "继续操作", "接着修", "接着跑", "继续",
            "修好", "修改代码", "改代码", "修代码", "修复代码", "重新运行",
            "再运行", "重跑", "改完运行", "改完再跑"
        ]
        return terms.contains { normalized.contains($0) }
    }

    // MARK: - Initialisation

    init(conversationId: String) {
        self.conversationId = conversationId
    }

    init() {
        self.conversationId = nil
    }

    // MARK: - Setup

    /// Weak reference to the shared store — used to write back model cache.
    private weak var activeChatStore: ActiveChatStore?

    func configure(with manager: ConversationManager, socket: SocketIOService? = nil, store: ActiveChatStore? = nil, asr: OnDeviceASRService? = nil) {
        self.manager = manager
        self.socketService = socket
        self.serverBaseURL = manager.baseURL
        self.activeChatStore = store
        self.asrService = asr
        setupRetryAttachmentObserver()
        setupMemorySettingObserver()
        setupFunctionsConfigObserver()
        setupStreamingHapticsObserver()
        setupChatWebSearchSettingsObserver()
    }

    /// Registers the observer that handles retry requests posted by the
    /// audio attachment thumbnail's retry button.
    ///
    /// When the user taps the retry button on a failed audio upload chip,
    /// `ChatInputField` posts `.retryAttachmentUpload` with the attachment
    /// UUID as the `object`. This observer picks it up and re-runs
    /// `uploadAttachmentImmediately` so the status cycles back through
    /// uploading → processing → completed/error without requiring a new configure().
    private func setupRetryAttachmentObserver() {
        NotificationCenter.default.addObserver(
            forName: .retryAttachmentUpload,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let attachmentId = notification.object as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Reset to pending so the thumbnail immediately shows a spinner
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].uploadStatus = .pending
                    self.attachments[idx].uploadError = nil
                }
                self.uploadAttachmentImmediately(attachmentId: attachmentId)
            }
        }
    }

    /// Registers an observer for `.memorySettingChanged` so that when the user
    /// toggles memory in Settings → Personalization → Memories, all active
    /// ChatViewModels update `memoryEnabled` immediately without a server refetch.
    private func setupMemorySettingObserver() {
        NotificationCenter.default.addObserver(
            forName: .memorySettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let newValue = notification.object as? Bool else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryEnabled = newValue
            }
        }
    }

    /// Seeds `streamingHapticsEnabled` from UserDefaults and keeps it in sync.
    /// Using a cached Bool avoids a per-token UserDefaults read (the hot path
    /// calls `triggerStreamingHaptic()` on every token at up to 60 Hz).
    private func setupStreamingHapticsObserver() {
        // Seed initial value
        streamingHapticsEnabled = UserDefaults.standard.object(forKey: "streamingHaptics") as? Bool ?? true
        // Keep in sync when Settings changes the preference
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let newValue = UserDefaults.standard.object(forKey: "streamingHaptics") as? Bool ?? true
            Task { @MainActor [weak self] in
                self?.streamingHapticsEnabled = newValue
            }
        }
    }

    private func setupChatWebSearchSettingsObserver() {
        syncChatWebSearchPermission()
        guard chatWebSearchSettingsObserver == nil else { return }
        chatWebSearchSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncChatWebSearchPermission()
            }
        }
    }

    private func syncChatWebSearchPermission() {
        let allowed = UserDefaults.standard.object(forKey: Self.chatWebSearchEnabledKey) as? Bool ?? false
        let changed = allowed != isChatWebSearchAllowed
        isChatWebSearchAllowed = allowed
        if !allowed, webSearchEnabled {
            suppressBuiltinFeatureTracking = true
            webSearchEnabled = false
            suppressBuiltinFeatureTracking = false
        } else if allowed, changed, !userDisabledBuiltinFeatures.contains("web_search") {
            webSearchEnabled = true
        }
    }

    /// Observes `.functionsConfigChanged` to re-resolve actions/filters for the
    /// current model immediately when function config changes (admin toggles
    /// active/global, or model editor saves). This ensures action buttons and
    /// filter IDs update in the chat UI without requiring a model picker open
    /// or app restart.
    private func setupFunctionsConfigObserver() {
        NotificationCenter.default.addObserver(
            forName: .functionsConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshSelectedModelConfig()
                self.logger.info("Functions config changed — re-resolved actions/filters for current model")
            }
        }
    }

    // MARK: - Audio Transcription (Navigation-Persistent)

    /// Starts transcription for an audio attachment and stores the Task on the VM.
    ///
    /// Because the VM lives in `ActiveChatStore` and survives navigation, the Task
    /// stored here will NOT be cancelled when the user navigates to another chat,
    /// the welcome screen, or anywhere else in the app. When the user returns to
    /// this chat, the attachment's `isTranscribing` state reflects the live status
    /// and `transcribedText` is populated as soon as the model finishes.
    ///
    /// - Parameters:
    ///   - attachmentId: The UUID of the `ChatAttachment` to transcribe.
    ///   - audioData: Raw audio file bytes.
    ///   - fileName: Original filename (used for the temp file extension).
    func transcribeAudioAttachment(attachmentId: UUID, audioData: Data, fileName: String) {
        guard let asr = asrService, asr.isAvailable, asr.autoTranscribeEnabled else { return }

        // Cancel any existing task for this attachment (e.g., user re-added the same file)
        transcriptionTasks[attachmentId]?.cancel()

        // Begin a background task the first time transcription starts (if not already running).
        // This requests ~30 seconds of extra CPU time from iOS when the app moves to the
        // background. If transcription finishes before the time expires, we end it early.
        // If it takes longer (e.g. large file), iOS will suspend (NOT terminate) the process
        // after the grant expires, and the Task resumes naturally when the user returns.
        if transcriptionBackgroundTaskId == .invalid {
            transcriptionBackgroundTaskId = UIApplication.shared.beginBackgroundTask(
                withName: "OnDeviceASRTranscription"
            ) { [weak self] in
                // Expiry handler — iOS is about to suspend us; end the assertion gracefully.
                // The Task itself is NOT cancelled — it will resume when the app foregrounds.
                guard let self else { return }
                Task { @MainActor in self.endTranscriptionBackgroundTask() }
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            // Mark as transcribing
            if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                self.attachments[idx].isTranscribing = true
            }

            do {
                let transcript = try await asr.transcribe(audioData: audioData, fileName: fileName)

                // Only update if attachment still exists (user may have removed it)
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].transcribedText = transcript
                    self.attachments[idx].isTranscribing = false
                }
                // Clear any pending resume record — transcription succeeded
                self.pendingResumeTranscriptions.removeValue(forKey: attachmentId)
                self.logger.info("Transcription complete for \(fileName): \(transcript.count) chars")
            } catch ASRError.backgroundInterrupted {
                // iOS < 26: The app moved to the background and Metal GPU access
                // was revoked. The task was cancelled gracefully (no crash).
                // Keep the attachment in "transcribing" state and store the audio
                // data so we can restart automatically when the app foregrounds.
                self.logger.info("Transcription paused for background: \(fileName) — will auto-resume on foreground")
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    // Keep isTranscribing = true so the chip still shows a spinner
                    // (transcription resumes; user doesn't need to do anything).
                    self.attachments[idx].isTranscribing = true
                }
                // Store audio data + filename so foreground sync can restart it
                self.pendingResumeTranscriptions[attachmentId] = (audioData: audioData, fileName: fileName)
                // Remove from active tasks — the task has ended; a new one will be started on resume
                self.transcriptionTasks.removeValue(forKey: attachmentId)
                self.endTranscriptionBackgroundTask()
                return
            } catch {
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].isTranscribing = false
                }
                // Only surface the error if the task wasn't explicitly cancelled
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                    self.logger.error("Transcription failed for \(fileName): \(error.localizedDescription)")
                }
            }

            // Clean up the task reference once complete
            self.transcriptionTasks.removeValue(forKey: attachmentId)

            // If all transcriptions are done, unload the model to free ~400-600 MB of RAM.
            // The model will reload automatically on the next transcription request.
            // Also end the iOS background task assertion (no more CPU work needed).
            if self.transcriptionTasks.isEmpty {
                asr.unloadModel()
                self.logger.info("All transcriptions complete — ASR model unloaded to free memory")
                self.endTranscriptionBackgroundTask()
            }
        }

        transcriptionTasks[attachmentId] = task
    }

    /// Ends the iOS background task assertion for on-device transcription.
    private func endTranscriptionBackgroundTask() {
        guard transcriptionBackgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transcriptionBackgroundTaskId)
        transcriptionBackgroundTaskId = .invalid
    }

    func resolvedImageURL(for model: AIModel?) -> URL? {
        guard let model else { return nil }
        return model.resolveAvatarURL(baseURL: serverBaseURL)
    }

    // MARK: - Loading

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        let isNew = conversationId == nil

        // Models & tools are NOT fetched here — they load lazily:
        //  • Models: pre-populated from ActiveChatStore cache. Refreshed
        //    when user opens model picker or before each send.
        //  • Tools: fetched fresh every time user opens the tools section.
        //
        // If this is the very first VM and the cache is empty, do an initial
        // model fetch so the user has something to select.
        let needsModelFetch = availableModels.isEmpty

        if isNew {
            // ── New chat fast path ──
            // Skip conversation fetch, passive listener, and external stream
            // check — they are all no-ops when there is no conversation ID.
            if needsModelFetch {
                await loadModels()
            } else if selectedModelId == nil {
                await resolveDefaultModelSelection()
            } else {
                syncUIWithModelDefaults()
            }
        } else {
            // ── Existing chat path ──
            // Run model fetch (if needed) and conversation fetch in parallel.
            if needsModelFetch {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.loadModels() }
                    group.addTask { await self.loadConversation() }
                }
            } else {
                if selectedModelId == nil {
                    await resolveDefaultModelSelection()
                } else {
                    syncUIWithModelDefaults()
                }
                await loadConversation()
            }
        }

        // Ensure socket is connected — fire-and-forget so it never blocks
        // the UI. The socket will be ready by the time the user sends a
        // message; if not, sendMessage() can await it at that point.
        if let socket = socketService, !socket.isConnected {
            Task {
                let connected = await socket.ensureConnected(timeout: 5.0)
                self.logger.info("Socket connect on load: \(connected)")
                // Start passive listener once socket is actually connected
                // (only meaningful for existing conversations).
                if connected && !isNew {
                    self.startPassiveSocketListener()
                }
            }
        } else if !isNew {
            // Socket already connected — start passive listener immediately
            startPassiveSocketListener()
        }

        // Start listening for app foreground events to sync with server
        startForegroundSyncListener()

        // Check if an external client is currently streaming to this chat
        // (only meaningful for existing conversations)
        if !isNew {
            await checkForActiveExternalStream()
        }

        // Fetch terminal servers in the background (fire-and-forget).
        // This is lightweight and determines whether to show the terminal pill.
        Task { await loadTerminalServers() }

        // Now that all initial data is loaded, enable message appear animations.
        // New messages sent/received during this session will animate in smoothly.
        shouldAnimateNewMessages = true
    }

    /// Re-fetches the conversation from the server and updates the local state.
    /// Called after an action button invocation to pick up content changes
    /// made by the action's server-side event emitters.
    func reloadConversation() async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        do {
            let refreshed = try await manager.fetchConversation(id: chatId)
            adoptServerMessages(serverConversation: refreshed)
        } catch {
            logger.warning("reloadConversation failed: \(error.localizedDescription)")
        }
    }

    func loadConversation() async {
        guard let conversationId, let manager else { return }
        isLoadingConversation = true
        errorMessage = nil
        do {
            let fetched = try await manager.fetchConversation(id: conversationId)
            // Always use server data as the source of truth.
            // Versions are now stored as sibling messages on the server,
            // so server-fetched data already contains them.
            conversation = Self.sanitizedConversationForDisplay(fetched)
            // Populate tasks from the server conversation
            tasks = fetched.tasks
            // Always adopt the last-used model for existing chats.
            // Priority: last assistant message's model (the actual model used
            // most recently) > conversation-level model > fallback.
            // This ensures returning to a chat uses the model from the most
            // recent response, even if it was changed mid-conversation from
            // the web UI or another client.
            if let lastAssistantModel = conversation?.messages.last(where: { $0.role == .assistant })?.model,
               !lastAssistantModel.isEmpty {
                selectedModelId = lastAssistantModel
            } else if let conversationModel = fetched.model, !conversationModel.isEmpty {
                selectedModelId = conversationModel
            } else if selectedModelId == nil {
                await resolveDefaultModelSelection()
            }
        } catch {
            logger.error("Failed to load conversation: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        // Clear stale override tracking so the model's server defaults apply cleanly
        // when the user opens an existing chat. We don't persist per-chat feature state,
        // so starting fresh here is the correct behaviour (Bug 2 fix).
        userDisabledBuiltinFeatures = []
        isLoadingConversation = false
    }

    /// Syncs local conversation state with the server.
    ///
    /// This is the key mechanism for detecting external changes (e.g., when
    /// a response is regenerated from the website). Matches the Flutter app's
    /// `_syncRemoteTaskStatus` and `activeConversationProvider` listener pattern.
    ///
    /// It compares local messages with server messages and adopts server data
    /// when:
    /// - Server has more messages than local
    /// - Server's last assistant message has different/more content
    /// - Server's last assistant message has different files (regenerated images)
    ///
    /// Uses debouncing to avoid redundant syncs when the app rapidly transitions
    /// between foreground and background states.
    func syncWithServer() async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }

        // Debounce: skip if we synced very recently (e.g., foreground observer
        // + .task both firing within the same second)
        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) >= syncDebounceInterval else {
            logger.debug("Server sync debounced (last sync \(self.lastSyncTime.formatted()))")
            return
        }

        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            lastSyncTime = Date()

            let serverMessages = serverConversation.messages
            let localMessages = conversation?.messages ?? []

            // Skip if no server messages
            guard !serverMessages.isEmpty else { return }

            // Fast path: if message IDs, counts, and content fingerprints match,
            // nothing changed — only update lightweight metadata (title/tags).
            if localMessages.count == serverMessages.count && !localMessages.isEmpty {
                let allMatch = zip(localMessages, serverMessages).allSatisfy { local, server in
                    local.id == server.id
                    && local.content.utf8.count == server.content.utf8.count // Fast O(1) reject
                    && local.content == server.content // Full compare only if lengths match
                    && local.files.count == server.files.count
                    && local.sources.count == server.sources.count
                    && local.followUps.count == server.followUps.count
                }
                if allMatch {
                    // Only update title if changed — no structural changes to messages
                    if !serverConversation.title.isEmpty
                        && serverConversation.title != "New Chat"
                        && serverConversation.title != conversation?.title {
                        conversation?.title = serverConversation.title
                    }
                    logger.debug("Server sync: no changes detected, skipping")
                    return
                }
            }

            // Case 1: Server has more messages than local — adopt surgically
            if serverMessages.count > localMessages.count {
                logger.info("Server sync: server has \(serverMessages.count) msgs vs local \(localMessages.count)")
                adoptServerMessages(serverConversation: serverConversation)
                return
            }

            // Case 2: Same message count — check if last assistant changed
            if !localMessages.isEmpty && !serverMessages.isEmpty {
                let localLast = localMessages.last!
                let serverLast = serverMessages.last!

                // Find matching message by ID
                if localLast.id == serverLast.id && localLast.role == .assistant {
                    let localContent = localLast.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let serverContent = serverLast.content.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Server has different content (regenerated from website)
                    let contentChanged = !serverContent.isEmpty && serverContent != localContent

                    // Server has different files (e.g., regenerated images from tool)
                    let filesChanged = serverLast.files != Self.serverPersistableFiles(localLast.files)

                    // Server has different sources
                    let sourcesChanged = serverLast.sources.count != localLast.sources.count

                    if contentChanged || filesChanged || sourcesChanged {
                        logger.info("Server sync: detected external change (content:\(contentChanged) files:\(filesChanged) sources:\(sourcesChanged))")

                        // Save current local state as a version before adopting server state
                        // (only if the content actually differs and has meaningful content)
                        if contentChanged && !localContent.isEmpty {
                            if let idx = conversation?.messages.lastIndex(where: { $0.id == localLast.id }) {
                                let version = ChatMessageVersion(
                                    content: localLast.content,
                                    timestamp: localLast.timestamp,
                                    model: localLast.model,
                                    error: localLast.error,
                                    files: localLast.files,
                                    sources: localLast.sources,
                                    followUps: localLast.followUps,
                                    metadata: localLast.metadata
                                )
                                // Only add if we don't already have this version
                                let isDuplicate = conversation?.messages[idx].versions.contains(where: {
                                    $0.content == version.content && $0.timestamp == version.timestamp
                                }) ?? false
                                if !isDuplicate {
                                    conversation?.messages[idx].versions.append(version)
                                }
                            }
                        }

                        adoptServerMessages(serverConversation: serverConversation)
                        return
                    }
                }

                // Case 3: Last messages have different IDs — server has a different
                // message chain (e.g., regeneration created a new message ID)
                if localLast.id != serverLast.id && serverLast.role == .assistant {
                    logger.info("Server sync: different last message IDs (local:\(localLast.id) server:\(serverLast.id))")
                    adoptServerMessages(serverConversation: serverConversation)
                    return
                }
            }

            // Update title if changed
            if !serverConversation.title.isEmpty && serverConversation.title != "New Chat" {
                conversation?.title = serverConversation.title
            }

        } catch {
            logger.warning("Server sync failed: \(error.localizedDescription)")
        }
    }

    /// Adopts server messages using **surgical in-place updates** to preserve
    /// SwiftUI identity tracking and scroll position in the inverted ScrollView.
    ///
    /// Instead of replacing the entire `conversation` object (which causes
    /// SwiftUI to rebuild the full LazyVStack and lose scroll position), this
    /// method:
    /// 1. Updates existing messages in-place by matching on ID
    /// 2. Appends only truly new messages
    /// 3. Removes only messages deleted server-side
    /// 4. Merges local-only versions that haven't been synced
    ///
    /// This eliminates the flicker/jump and scroll-stuck issues that occurred
    /// when returning from background, because SwiftUI's identity tracking
    /// (via `.id(message.id)`) remains stable throughout the update.
    private func adoptServerMessages(serverConversation: Conversation) {
        guard conversation != nil else {
            // No local conversation yet — just assign directly
            conversation = Self.sanitizedConversationForDisplay(serverConversation)
            if let serverModel = serverConversation.model, selectedModelId != serverModel {
                selectedModelId = serverModel
            }
            return
        }

        // Merge the server's history tree into our local history.
        // The server tree is authoritative for all non-streaming nodes.
        if serverConversation.history.isPopulated {
            for (id, serverNode) in serverConversation.history.nodes {
                if let localNode = conversation?.history.nodes[id] {
                    // Node exists locally — update content fields but keep local
                    // content if we're actively streaming this message.
                    let isActivelyStreaming = streamingStore.streamingMessageId == id && streamingStore.isActive
                    if !isActivelyStreaming {
                        var updated = serverNode
                        // Preserve local childrenIds if they have more entries
                        // (local may have new branches not yet on server)
                        if localNode.childrenIds.count > serverNode.childrenIds.count {
                            updated.childrenIds = localNode.childrenIds
                        }
                        // CRITICAL: Never overwrite a non-empty local tree node content
                        // with empty server content. This prevents adoptServerMessages()
                        // from undoing the content we wrote to the tree node in
                        // updateAssistantMessage(isStreaming:false).
                        //
                        // How this bug occurs:
                        // 1. editMessage() syncs tree to server with empty assistant node
                        // 2. Streaming completes → updateAssistantMessage writes content to local tree node
                        // 3. refreshConversationMetadata() → adoptServerMessages() runs
                        // 4. Server still has the empty assistant node from step 1
                        // 5. WITHOUT this guard: server's empty node overwrites our good local node
                        // 6. Now the tree node is empty again; any future sync sends empty to server
                        if !localNode.content.isEmpty && updated.content.isEmpty {
                            updated.content = localNode.content
                            updated.done = true
                        } else if CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                            local: localNode.content,
                            incoming: updated.content
                        ) {
                            updated.content = localNode.content
                            updated.done = true
                        }
                        conversation?.history.nodes[id] = Self.sanitizedHistoryNodeForDisplay(updated)
                    }
                } else {
                    // New node from server — add directly
                    conversation?.history.nodes[id] = Self.sanitizedHistoryNodeForDisplay(serverNode)
                }
            }
            // Update currentId from server unless we're actively streaming
            if !isStreaming, let serverCurrentId = serverConversation.history.currentId {
                conversation?.history.currentId = serverCurrentId
            }
        }

        let serverMessages = serverConversation.messages

        // Build a set of server message IDs for removal detection
        let serverMessageIds = Set(serverMessages.map(\.id))

        // Phase 1: Remove local messages that no longer exist on server
        // Iterate in reverse to preserve indices during removal
        for i in (0..<(conversation!.messages.count)).reversed() {
            let localId = conversation!.messages[i].id
            if !serverMessageIds.contains(localId) {
                conversation!.messages.remove(at: i)
            }
        }

        // Phase 2: Update existing messages in-place and insert new ones
        for (serverIdx, rawServerMsg) in serverMessages.enumerated() {
            let serverMsg = Self.sanitizedMessageForDisplay(rawServerMsg)
            if let localIdx = conversation!.messages.firstIndex(where: { $0.id == serverMsg.id }) {
                // Message exists locally — update only changed fields in-place
                let local = conversation!.messages[localIdx]

                // GUARD: During active streaming, do NOT overwrite content of
                // already-completed (non-streaming) assistant messages. The server
                // may return stale/corrupted data during streaming that would
                // replace the first message's content with the second message's
                // streaming content — causing the "duplicate stream" bug.
                let isLocallyComplete = !local.isStreaming && local.role == .assistant
                    && !local.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let skipContentUpdate = isLocallyComplete && isStreaming

                let preserveLocalCodeIndentation = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                    local: local.content,
                    incoming: serverMsg.content
                )
                if !skipContentUpdate && !preserveLocalCodeIndentation && local.content != serverMsg.content {
                    conversation!.messages[localIdx].content = serverMsg.content
                }
                let mergedFiles = Self.preservingInlineImageFiles(
                    local: local.files,
                    incoming: serverMsg.files
                )
                if local.files != mergedFiles || serverMsg.files.contains(where: { $0.displayURL != nil }) {
                    conversation!.messages[localIdx].files = mergedFiles
                }
                if local.sources.count != serverMsg.sources.count || local.sources != serverMsg.sources {
                    conversation!.messages[localIdx].sources = serverMsg.sources
                }
                if local.followUps != serverMsg.followUps {
                    conversation!.messages[localIdx].followUps = serverMsg.followUps
                }
                if local.metadata != serverMsg.metadata {
                    conversation!.messages[localIdx].metadata = serverMsg.metadata ?? local.metadata
                }
                if local.error != serverMsg.error {
                    conversation!.messages[localIdx].error = serverMsg.error
                }
                if local.isStreaming != serverMsg.isStreaming {
                    conversation!.messages[localIdx].isStreaming = serverMsg.isStreaming
                }
                // CRITICAL: Sync parentId from server. Locally-created messages
                // always have parentId = nil (it's not set in the UI layer when
                // the user sends a message). The server's tree has the correct
                // parentId for every node. Without this, downstream messages
                // captured by regenerateResponse/restoreAssistantVersion retain
                // nil parentId, causing editMessage's fallback to pick the wrong
                // parent (the currently-displayed message instead of the real
                // tree parent).
                if local.parentId == nil, let serverParentId = serverMsg.parentId {
                    conversation!.messages[localIdx].parentId = serverParentId
                }

                // Merge versions: keep local-only versions + server versions.
                // The tree is the source of truth — versions are just sibling nodes
                // for the UI version counter. Server content wins; local-only versions
                // (not yet synced) are appended.
                var mergedVersions: [ChatMessageVersion] = []
                let serverVersionIds = Set(serverMsg.versions.map(\.id))
                // Start with server versions (authoritative)
                mergedVersions = serverMsg.versions
                // Append any local-only versions (not yet on server)
                for localVersion in local.versions {
                    if !serverVersionIds.contains(localVersion.id) {
                        mergedVersions.append(localVersion)
                    }
                }
                if mergedVersions.count != local.versions.count || mergedVersions != local.versions {
                    conversation!.messages[localIdx].versions = mergedVersions
                }

                // Preserve usage data from server — never overwrite with nil
                if local.usage == nil,
                   let serverUsage = serverMsg.usage, !serverUsage.isEmpty {
                    conversation!.messages[localIdx].usage = serverUsage
                }
                // Preserve embeds from server — never overwrite non-empty embeds with empty
                if local.embeds.isEmpty && !serverMsg.embeds.isEmpty {
                    conversation!.messages[localIdx].embeds = serverMsg.embeds
                }
            } else {
                // New message from server — insert at correct position
                let insertIdx = min(serverIdx, conversation!.messages.count)
                conversation!.messages.insert(serverMsg, at: insertIdx)
            }
        }

        // Phase 3: Ensure message order matches server order
        // (only reorder if the IDs don't match sequence — avoids unnecessary mutation)
        let currentIds = conversation!.messages.map(\.id)
        let serverIds = serverMessages.map(\.id)
        if currentIds != serverIds {
            // Reorder by building a new array in server order, preserving local mutations
            let localMap = Dictionary(conversation!.messages.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            var reordered: [ChatMessage] = []
            for serverId in serverIds {
                if let msg = localMap[serverId] {
                    reordered.append(msg)
                }
            }
            // Append any remaining local messages not in server (shouldn't happen, but safety)
            for msg in conversation!.messages where !serverMessageIds.contains(msg.id) {
                reordered.append(msg)
            }
            conversation!.messages = reordered
        }

        // Phase 4: Update conversation metadata (non-message fields)
        if !serverConversation.title.isEmpty && serverConversation.title != "New Chat" {
            conversation?.title = serverConversation.title
        }
        // NOTE: Do NOT override selectedModelId here. The user's model picker
        // selection is authoritative once the conversation is loaded. Overwriting
        // it from the server would revert a deliberate model change the user made
        // (e.g., picking a different model before regenerating). The initial load
        // case at the top of this method already sets selectedModelId when
        // conversation is nil.
        if serverConversation.tags != conversation?.tags {
            conversation?.tags = serverConversation.tags
        }
        // Sync tasks from server — ensures task list stays current after
        // syncWithServer() / reloadConversation() calls.
        if !serverConversation.tasks.isEmpty || !tasks.isEmpty {
            tasks = serverConversation.tasks
            conversation?.tasks = serverConversation.tasks
        }
    }

    // MARK: - Entry Sync (navigation re-entry)

    /// Syncs with the server every time the user navigates INTO this chat.
    ///
    /// Unlike `syncWithServer()` (which has a 3-second debounce designed to
    /// guard against rapid foreground/background transitions), this method uses
    /// a much shorter 1.5-second guard — just enough to absorb SwiftUI's
    /// double-appear during push/pop navigation transitions.
    ///
    /// Called from `ChatDetailView.onAppear` so that even when the view model
    /// is cached (`hasLoaded == true`) and no foreground transition occurs,
    /// we still pick up any messages changed externally (e.g. a response
    /// regenerated from the web while this chat was in the background pane).
    func syncOnEntry() {
        guard hasLoaded else { return } // load() handles the first appearance
        guard !isStreaming else { return } // never interrupt an active stream
        let now = Date()
        guard now.timeIntervalSince(lastEntryTime) >= 1.5 else { return }
        lastEntryTime = now
        // Reset lastSyncTime so syncWithServer() is not blocked by its own debounce
        lastSyncTime = .distantPast
        Task { await syncWithServer() }
    }

    // MARK: - Foreground Sync

    /// Listens for app becoming active to trigger a server sync,
    /// and for app entering background to start completion monitoring.
    /// This catches changes made externally (e.g., regeneration from website)
    /// and ensures tool-generated files/images are picked up after backgrounding.
    private func startForegroundSyncListener() {
        // Remove any existing observers to prevent duplicates
        if let existing = foregroundObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        if let existing = backgroundObserver {
            NotificationCenter.default.removeObserver(existing)
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Skip sync if the app was only backgrounded for a trivially
                // short period (< 2s). This prevents unnecessary flicker when
                // the user accidentally swipes to the app switcher and back.
                let bgDuration: TimeInterval
                if let bgStart = self.backgroundEnteredAt {
                    bgDuration = Date().timeIntervalSince(bgStart)
                } else {
                    bgDuration = .infinity // Unknown — assume long
                }
                self.backgroundEnteredAt = nil

                if self.isStreaming {
                    // App was backgrounded during streaming — socket events may
                    // have been missed. Check server for actual completion state.
                    await self.recoverFromBackgroundStreaming()
                } else if bgDuration >= 10.0 {
                    // Only sync if we were backgrounded long enough for
                    // something to have changed on the server (10s threshold
                    // avoids triggering on quick app-switcher glances which
                    // would cause scroll position loss and a flicker).
                    await self.syncWithServer()
                } else {
                    self.logger.debug("Foreground sync skipped — background duration \(bgDuration)s < 10s")
                }

                self.restoreLifecycleConversationSnapshot()

                // Auto-resume any transcriptions that were paused when the app
                // went to background on iOS < 26 (where GPU access is forbidden
                // in the background). The audio data was saved in
                // pendingResumeTranscriptions at pause time; restart them now.
                if !self.pendingResumeTranscriptions.isEmpty {
                    let pending = self.pendingResumeTranscriptions
                    self.pendingResumeTranscriptions = [:]
                    self.logger.info("Resuming \(pending.count) paused transcription(s) after foreground return")
                    for (attachmentId, info) in pending {
                        self.transcribeAudioAttachment(
                            attachmentId: attachmentId,
                            audioData: info.audioData,
                            fileName: info.fileName
                        )
                    }
                }
            }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.backgroundEnteredAt = Date()
                self.persistLifecycleConversationSnapshot()
                guard self.isStreaming else { return }
                if !self.isOpenAICompatibleProvider {
                    self.startBackgroundCompletionPolling()
                } else {
                    self.beginStreamingBackgroundTaskIfNeeded()
                }
            }
        }
    }

    /// Removes the foreground/background sync listeners.
    func removeForegroundSyncListener() {
        if let existing = foregroundObserver {
            NotificationCenter.default.removeObserver(existing)
            foregroundObserver = nil
        }
        if let existing = backgroundObserver {
            NotificationCenter.default.removeObserver(existing)
            backgroundObserver = nil
        }
    }

    deinit {
        let fgObserver = foregroundObserver
        let bgObserver = backgroundObserver
        if let fgObserver {
            NotificationCenter.default.removeObserver(fgObserver)
        }
        if let bgObserver {
            NotificationCenter.default.removeObserver(bgObserver)
        }
        if let chatWebSearchSettingsObserver {
            NotificationCenter.default.removeObserver(chatWebSearchSettingsObserver)
        }
    }

    // MARK: - Background Completion Polling

    /// Starts a background task that polls the server for streaming completion.
    /// iOS grants ~30s of background execution. If the generation completes within
    /// that window, we fire a local notification and adopt the server state.
    private func startBackgroundCompletionPolling() {
        beginStreamingBackgroundTaskIfNeeded()
        guard backgroundTaskId != .invalid else { return }

        let chatId = conversationId ?? conversation?.id

        Task { @MainActor [weak self] in
            guard let self, let chatId, let manager = self.manager else {
                self?.endBackgroundTask()
                return
            }

            // Fix 4: Poll every 1.5s (was 3s), up to 20 times (~30s — near iOS limit)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.isStreaming else {
                    self.endBackgroundTask()
                    return
                }

                do {
                    let refreshed = try await manager.fetchConversation(id: chatId)
                    if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }),
                       !serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.logger.info("Background poll: server completed (\(serverAssistant.content.count) chars)")
                        self.adoptServerMessages(serverConversation: refreshed)
                        let finalAssistantContent = self.conversation?.messages
                            .first(where: { $0.id == serverAssistant.id })?.content ?? serverAssistant.content
                        let lastUser = self.conversation?.messages.last(where: { $0.role == .user && !Self.isLocalWorkspaceAgentResult($0) })
                        self.recordTokenUsageForCompletedTurn(
                            assistantMessageId: serverAssistant.id,
                            userText: lastUser?.content ?? "",
                            assistantText: finalAssistantContent,
                            userAttachments: [],
                            usage: serverAssistant.usage
                        )
                        await self.sendCompletionNotificationIfNeeded(content: finalAssistantContent)
                        self.cleanupStreaming()
                        self.endBackgroundTask()
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                        return
                    }
                } catch {
                    self.logger.warning("Background poll failed: \(error.localizedDescription)")
                }
            }

            self.endBackgroundTask()
        }
    }

    /// Ends the iOS background task.
    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    /// Recovers streaming state when the app returns to foreground.
    /// Socket events may have been missed while backgrounded, so we check
    /// the server for the actual completion state and adopt it.
    private func recoverFromBackgroundStreaming() async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }

        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            guard let serverAssistant = serverConversation.messages.last(where: { $0.role == .assistant }) else { return }

            let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // If server has content, the generation completed while we were backgrounded
            if !serverContent.isEmpty {
                logger.info("Foreground recovery: server has completed content (\(serverContent.count) chars, \(serverAssistant.files.count) files)")

                // Adopt server state fully (includes files from tool calls)
                adoptServerMessages(serverConversation: serverConversation)

                // Safety net: if server didn't populate files but tool results
                // contain file references, extract them from the message content.
                // This is the primary fix for the "backgrounded during image gen" scenario.
                if let lastAssistantId = conversation?.messages.last(where: { $0.role == .assistant })?.id {
                    populateFilesFromToolResults(messageId: lastAssistantId)
                }
                let lastUser = conversation?.messages.last(where: { $0.role == .user && !Self.isLocalWorkspaceAgentResult($0) })
                recordTokenUsageForCompletedTurn(
                    assistantMessageId: serverAssistant.id,
                    userText: lastUser?.content ?? "",
                    assistantText: serverAssistant.content,
                    userAttachments: [],
                    usage: serverAssistant.usage
                )

                // Fix 3: Set bypass flag so the notification shows even if the
                // user has already returned to this chat. The response completed
                // while they were away — they deserve to know it's ready.
                NotificationService.shared.bypassActiveConversationSuppression = true
                // Send notification — generation completed while we were away
                await sendCompletionNotificationIfNeeded(content: serverContent)

                // Cleanup streaming state
                cleanupStreaming()

                // Notify conversation list
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

                // Schedule a delayed re-sync to pick up title, follow-ups, and tags.
                // These background tasks run asynchronously on the server and may not
                // be ready when we first recover. A 3s + 8s poll catches most cases.
                Task {
                    for delay: UInt64 in [3, 8] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        await self.syncWithServer()
                    }
                }
            }
            // If server content is still empty, streaming may still be in progress.
            // The existing socket handlers / recovery timer will handle it when
            // the socket reconnects.
        } catch {
            logger.warning("Foreground recovery failed: \(error.localizedDescription)")
        }
    }

    func loadModels() async {
        guard let manager else { return }
        isLoadingModels = true
        do {
            availableModels = try await manager.fetchModels()
            let currentSelectionIsAvailable = selectedModelId.flatMap { selected in
                availableModels.first(where: { $0.id == selected })
            } != nil
            if selectedModelId == nil || !currentSelectionIsAvailable {
                await resolveDefaultModelSelection()
            }
            // Write back to shared cache so subsequent VMs are pre-populated
            activeChatStore?.updateModelCache(models: availableModels, selectedId: selectedModelId)
            refreshContextBudgetStatus()
        } catch {
            logger.error("Failed to load models: \(error.localizedDescription)")
        }
        isLoadingModels = false
        // Sync UI toggles with model defaults after models are loaded
        syncUIWithModelDefaults()
    }

    private func resolveDefaultModelSelection() async {
        let localModelId = ActiveChatStore.persistedPreferredModelId()
        if let localModelId,
           !localModelId.isEmpty,
           availableModels.isEmpty || availableModels.contains(where: { $0.id == localModelId }) {
            selectedModelId = localModelId
            activeChatStore?.updateModelCache(models: availableModels, selectedId: selectedModelId)
            syncUIWithModelDefaults()
            return
        }

        guard let manager else {
            selectedModelId = availableModels.first?.id
            syncUIWithModelDefaults()
            return
        }

        if let def = await manager.fetchDefaultModel(),
           availableModels.isEmpty || availableModels.contains(where: { $0.id == def }) {
            selectedModelId = def
        } else {
            selectedModelId = availableModels.first?.id
        }
        activeChatStore?.updateModelCache(models: availableModels, selectedId: selectedModelId)
        syncUIWithModelDefaults()
    }

    /// Silently refreshes the model list from the server in the background.
    /// Called when the user opens the model picker to pick up admin-added models.
    func refreshModelsInBackground() {
        guard !isLoadingModels else { return }
        Task { await loadModels() }
    }

    /// Fetches terminal servers available to the user.
    ///
    /// Called once at chat load time. If any terminals are available, the
    /// user can toggle them on via the terminal pill in the input field.
    func loadTerminalServers() async {
        if isOpenAICompatibleProvider {
            availableTerminalServers = [TerminalServer.localAlpine]
            if selectedTerminalServer == nil || selectedTerminalServer?.isLocalAlpine != true {
                selectedTerminalServer = TerminalServer.localAlpine
            }
            return
        }
        guard let manager else {
            availableTerminalServers = [TerminalServer.localAlpine]
            if selectedTerminalServer == nil {
                selectedTerminalServer = TerminalServer.localAlpine
            }
            return
        }
        do {
            let remoteServers = try await manager.fetchTerminalServers()
            availableTerminalServers = remoteServers + [TerminalServer.localAlpine]
            if selectedTerminalServer?.isLocalAlpine != true,
               let selected = selectedTerminalServer,
               !remoteServers.contains(where: { $0.id == selected.id }) {
                selectedTerminalServer = nil
            }
            // Auto-select first remote terminal when available; otherwise fall back to Local Alpine.
            if selectedTerminalServer == nil, let first = availableTerminalServers.first {
                selectedTerminalServer = first
            }
        } catch {
            availableTerminalServers = [TerminalServer.localAlpine]
            if selectedTerminalServer == nil {
                selectedTerminalServer = TerminalServer.localAlpine
            }
            logger.debug("Terminal servers fetch failed: \(error.localizedDescription)")
        }
    }

    /// Toggles the terminal on/off. When turning on, auto-selects the first
    /// server if none is selected. When multiple servers are available,
    /// the caller should set `selectedTerminalServer` before enabling.
    func toggleTerminal() {
        if terminalEnabled {
            terminalEnabled = false
        } else {
            if selectedTerminalServer == nil, let first = availableTerminalServers.first {
                selectedTerminalServer = first
            }
            terminalEnabled = true
        }
    }

    func loadTools() async {
        guard !isOpenAICompatibleProvider else {
            availableTools = []
            selectedToolIds = []
            isLoadingTools = false
            return
        }
        guard let manager else { return }
        isLoadingTools = true
        do {
            var allItems = try await manager.fetchTools()

            // Also fetch toggle-filter functions (meta.toggle: true) from /api/v1/functions/
            // These are filter functions that can be toggled per-message, like
            // "OpenRouter Search" or "Direct Uploads". They show as toggleable
            // tools in the ToolsMenuSheet alongside regular tools.
            do {
                let functions = try await manager.apiClient.getFunctions()
                let toggleFilters = functions.filter { $0.type == "filter" && $0.isActive && $0.hasToggle }
                for fn in toggleFilters {
                    // Avoid duplicates (a filter could theoretically have the same ID as a tool)
                    if !allItems.contains(where: { $0.id == fn.id }) {
                        allItems.append(ToolItem(
                            id: fn.id,
                            name: fn.name,
                            description: fn.description.isEmpty ? nil : fn.description,
                            isEnabled: fn.isGlobal // Global toggle-filters are enabled by default
                        ))
                    }
                }
            }

            if !allItems.isEmpty {
                availableTools = allItems
                syncToolSelectionWithDefaults()
                isLoadingTools = false
                return
            }
        } catch {
            logger.warning("Failed to fetch tools: \(error.localizedDescription)")
        }
        var seen = Set<String>()
        var items: [ToolItem] = []
        for model in availableModels {
            for toolId in model.toolIds where !seen.contains(toolId) {
                seen.insert(toolId)
                items.append(ToolItem(
                    id: toolId,
                    name: toolId.replacingOccurrences(of: "_", with: " ").capitalized,
                    description: nil
                ))
            }
        }
        availableTools = items
        syncToolSelectionWithDefaults()
        isLoadingTools = false
    }

    /// Adds globally-enabled tools (server `is_active`) and model-assigned
    /// tools to `selectedToolIds` so the toggles show as on by default.
    /// Respects `userDisabledToolIds` — tools the user explicitly toggled
    /// OFF during this session are NOT re-enabled by server defaults.
    private func syncToolSelectionWithDefaults() {
        // 1. Globally-enabled tools (server admin marked as active)
        for tool in availableTools where tool.isEnabled {
            if !userDisabledToolIds.contains(tool.id) {
                selectedToolIds.insert(tool.id)
            }
        }
        // 2. Model-assigned tools (admin attached to the selected model)
        if let model = selectedModel {
            for toolId in model.toolIds {
                if !userDisabledToolIds.contains(toolId) {
                    selectedToolIds.insert(toolId)
                }
            }
        }
    }

    // MARK: - Knowledge

    /// Timestamp of the last knowledge fetch — used for stale-while-revalidate.
    private var lastKnowledgeFetchTime: Date = .distantPast

    /// Fetches knowledge bases and user files for the `#` picker.
    ///
    /// Uses a **stale-while-revalidate** strategy:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    /// - Cache is refreshed every time the picker opens (async).
    func loadKnowledgeItems() {
        guard !isOpenAICompatibleProvider else {
            knowledgeItems = []
            isLoadingKnowledge = false
            return
        }
        // If we already have cached items, show them immediately
        // and refresh in the background (stale-while-revalidate)
        if !knowledgeItems.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchKnowledgeItemsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingKnowledge = true
        Task {
            await fetchKnowledgeItemsFromServer()
            isLoadingKnowledge = false
        }
    }

    /// Fetches folders + knowledge bases + knowledge files from the server
    /// and updates the cache. All 3 APIs are called concurrently.
    private func fetchKnowledgeItemsFromServer() async {
        guard !isOpenAICompatibleProvider else { return }
        guard let manager else { return }

        // Fetch all 3 sources concurrently — each is independent and
        // a single failure shouldn't prevent the others from showing.
        async let foldersReq: [KnowledgeItem] = {
            (try? await manager.fetchFolderItems()) ?? []
        }()
        async let collectionsReq: [KnowledgeItem] = {
            (try? await manager.fetchKnowledgeItems()) ?? []
        }()
        async let filesReq: [KnowledgeItem] = {
            (try? await manager.fetchKnowledgeFileItems()) ?? []
        }()

        let (folders, collections, files) = await (foldersReq, collectionsReq, filesReq)

        // Only update if we got at least something
        let combined = folders + collections + files
        if !combined.isEmpty || knowledgeItems.isEmpty {
            knowledgeItems = combined
        }
        lastKnowledgeFetchTime = Date()
    }

    /// Called when a knowledge item is selected from the `#` picker.
    ///
    /// Adds the item to the selected list (if not already there),
    /// removes the `#query` from the input text, and dismisses the picker.
    func selectKnowledgeItem(_ item: KnowledgeItem) {
        // Avoid duplicates
        guard !selectedKnowledgeItems.contains(where: { $0.id == item.id }) else {
            dismissKnowledgePicker()
            return
        }
        selectedKnowledgeItems.append(item)

        // Remove the `#query` token from input text
        removeHashToken()
        dismissKnowledgePicker()
    }

    /// Removes the `#...` token from the input text (the text from the last `#`
    /// at a word boundary up to the cursor position).
    private func removeHashToken() {
        let text = inputText
        // Find the last `#` at a word boundary
        guard let hashIndex = text.lastIndex(of: "#") else { return }
        let hashPos = text.distance(from: text.startIndex, to: hashIndex)
        let isAtStart = hashPos == 0
        let precededBySpace = hashPos > 0 && {
            let beforeIdx = text.index(before: hashIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            // Remove from `#` to the end of the current token (no whitespace after #)
            let afterHash = text[hashIndex...]
            let tokenEnd = afterHash.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<hashIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Removes the `@...` token from the input text (the text from the last `@`
    /// at a word boundary up to the cursor position).
    func removeMentionToken() {
        let text = inputText
        guard let atIndex = text.lastIndex(of: "@") else { return }
        let atPos = text.distance(from: text.startIndex, to: atIndex)
        let isAtStart = atPos == 0
        let precededBySpace = atPos > 0 && {
            let beforeIdx = text.index(before: atIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterAt = text[atIndex...]
            let tokenEnd = afterAt.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<atIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Dismisses the knowledge picker popup.
    func dismissKnowledgePicker() {
        isShowingKnowledgePicker = false
        knowledgeSearchQuery = ""
    }

    // MARK: - 引用聊天

    /// Called when a reference chat is selected from the picker.
    /// Adds the chat to the selected list (avoiding duplicates).
    func selectReferenceChat(_ item: ReferenceChatItem) {
        guard !selectedReferenceChats.contains(where: { $0.id == item.id }) else { return }
        selectedReferenceChats.append(item)
        Haptics.play(.light)
    }

    // MARK: - Prompt Slash Commands

    /// Fetches the prompt library from the server.
    ///
    /// Uses a **stale-while-revalidate** strategy like knowledge items:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    /// - Only fetches active prompts (is_active == true) from `GET /api/v1/prompts/`.
    func loadPrompts() {
        if !availablePrompts.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchPromptsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingPrompts = true
        Task {
            await fetchPromptsFromServer()
            isLoadingPrompts = false
        }
    }

    /// Fetches prompts from the server API.
    private func fetchPromptsFromServer() async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let raw = try await apiClient.getPrompts()
            let parsed = raw.compactMap { PromptItem(json: $0) }
            // Only cache active prompts — disabled prompts don't appear in slash commands
            availablePrompts = parsed.filter(\.isActive)
            logger.info("Loaded \(self.availablePrompts.count) active prompts")
        } catch {
            logger.warning("Failed to load prompts: \(error.localizedDescription)")
        }
    }

    /// Called when the user selects a prompt from the `/` picker.
    ///
    /// 1. Removes the `/query` token from the input text
    /// 2. Dismisses the picker
    /// 3. Extracts custom variables from the prompt content
    /// 4. If variables exist → presents the variable input sheet
    /// 5. If no variables → processes and inserts the prompt directly
    func selectPrompt(_ prompt: PromptItem) {
        // Remove the `/command` token from input text
        removeSlashToken()
        dismissPromptPicker()

        // Extract custom input variables (skips system variables)
        let variables = PromptService.extractCustomVariables(from: prompt.content)

        if variables.isEmpty {
            // No variables — process system variables and insert directly
            let processed = PromptService.resolveSystemVariables(
                in: prompt.content,
                userName: nil,
                userEmail: nil
            )
            // Append prompt text to whatever the user already typed (after slash token removal)
            let remaining = inputText.trimmingCharacters(in: .whitespaces)
            inputText = remaining.isEmpty ? processed : remaining + " " + processed
        } else {
            // Has variables — present the variable input sheet
            pendingPromptForVariables = prompt
            pendingPromptVariables = variables
        }

        Haptics.play(.light)
    }

    /// Called when the user submits variable values from the PromptVariableSheet.
    func submitPromptVariables(values: [String: String]) {
        guard let prompt = pendingPromptForVariables else { return }
        let variables = pendingPromptVariables

        let processed = PromptService.processPrompt(
            content: prompt.content,
            userValues: values,
            variables: variables,
            userName: nil,
            userEmail: nil
        )

        // Append prompt text to whatever the user already typed (after slash token removal)
        let remaining = inputText.trimmingCharacters(in: .whitespaces)
        inputText = remaining.isEmpty ? processed : remaining + " " + processed
        pendingPromptForVariables = nil
        pendingPromptVariables = []

        Haptics.play(.light)
    }

    /// Called when the user cancels the variable input sheet.
    func cancelPromptVariables() {
        pendingPromptForVariables = nil
        pendingPromptVariables = []
    }

    /// Removes the `/...` token from the input text (the text from the last `/`
    /// at a word boundary up to the cursor position).
    private func removeSlashToken() {
        let text = inputText
        guard let slashIndex = text.lastIndex(of: "/") else { return }
        let slashPos = text.distance(from: text.startIndex, to: slashIndex)
        let isAtStart = slashPos == 0
        let precededBySpace = slashPos > 0 && {
            let beforeIdx = text.index(before: slashIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterSlash = text[slashIndex...]
            let tokenEnd = afterSlash.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<slashIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Dismisses the prompt picker popup.
    func dismissPromptPicker() {
        isShowingPromptPicker = false
        promptSearchQuery = ""
    }

    // MARK: - Skills Dollar Commands

    /// Fetches active skills from the server for the `$` picker.
    ///
    /// Uses a **stale-while-revalidate** strategy like prompts:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    func loadSkills() {
        if !availableSkills.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchSkillsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingSkills = true
        Task {
            await fetchSkillsFromServer()
            isLoadingSkills = false
        }
    }

    /// Fetches skills from the server API.
    private func fetchSkillsFromServer() async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let items = try await apiClient.getSkills()
            // Only cache active skills — disabled skills don't appear in $ commands
            availableSkills = items.filter(\.isActive)
            logger.info("Loaded \(self.availableSkills.count) active skills")
        } catch {
            logger.warning("Failed to load skills: \(error.localizedDescription)")
        }
    }

    /// Called when the user selects a skill from the `$` picker.
    ///
    /// Replaces the `$query` token with `<$slug|slug> ` in the input text
    /// (matching the Iexa native server wire format), and records the skill ID in
    /// `selectedSkillIds` so it is sent as `skill_ids` in the API request.
    func selectSkill(_ skill: SkillItem) {
        // Use the web UI format: <$slug|slug>
        replaceDollarTokenWith("<$\(skill.id)|\(skill.id)> ")
        dismissSkillPicker()

        if !selectedSkillIds.contains(skill.id) {
            selectedSkillIds.append(skill.id)
        }

        Haptics.play(.light)
    }

    /// Replaces the `$...` token in the input text with `replacement`.
    /// The token is the text from the last bare `$` (at start or preceded by
    /// whitespace) up to the next whitespace or end of string.
    private func replaceDollarTokenWith(_ replacement: String) {
        let text = inputText
        guard let dollarIndex = text.lastIndex(of: "$") else { return }
        let dollarPos = text.distance(from: text.startIndex, to: dollarIndex)
        let isAtStart = dollarPos == 0
        let precededBySpace = dollarPos > 0 && {
            let beforeIdx = text.index(before: dollarIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterDollar = text[dollarIndex...]
            let tokenEnd = afterDollar.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<dollarIndex]) + replacement + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Removes the `$...` token from the input text (replaces with empty string).
    private func removeDollarToken() {
        replaceDollarTokenWith("")
    }

    /// Dismisses the skill picker popup.
    func dismissSkillPicker() {
        isShowingSkillPicker = false
        skillSearchQuery = ""
    }

    /// Restores `selectedKnowledgeItems` from the conversation's user messages.
    ///
    /// When loading an existing conversation, scans user messages for files
    /// with `type == "collection"`, `"folder"`, or knowledge `"file"` entries
    /// and rebuilds the knowledge chips so they persist across navigation.
    private func restoreKnowledgeItemsFromConversation() {
        guard let conversation, selectedKnowledgeItems.isEmpty else { return }

        // Collect unique knowledge files from the most recent user message
        // that has them. Knowledge files are stored with type "collection"/"folder"/"file".
        let knowledgeTypes: Set<String> = ["collection", "folder"]
        var restored: [KnowledgeItem] = []
        var seenIds = Set<String>()

        // Scan from newest to oldest — find the first user message with knowledge files
        for message in conversation.messages.reversed() where message.role == .user {
            let knowledgeFiles = message.files.filter { f in
                guard let type = f.type else { return false }
                return knowledgeTypes.contains(type)
            }
            if !knowledgeFiles.isEmpty {
                for file in knowledgeFiles {
                    guard let id = file.url, !seenIds.contains(id) else { continue }
                    seenIds.insert(id)
                    let knowledgeType: KnowledgeItem.KnowledgeType
                    switch file.type {
                    case "folder": knowledgeType = .folder
                    case "collection": knowledgeType = .collection
                    default: knowledgeType = .file
                    }
                    restored.append(KnowledgeItem(
                        id: id,
                        name: file.name ?? id,
                        description: nil,
                        type: knowledgeType,
                        fileCount: nil
                    ))
                }
                break // Only restore from the most recent user message
            }
        }

        if !restored.isEmpty {
            selectedKnowledgeItems = restored
            logger.info("Restored \(restored.count) knowledge item(s) from conversation history")
        }
    }

    // MARK: - Passive Socket Listener (Cross-Client Stream Observation)
    private func startPassiveSocketListener() {
        // Only for existing conversations with a known ID
        guard let chatId = conversationId ?? conversation?.id else { return }
        guard let socket = socketService, socket.isConnected else { return }

        // Dispose any previous passive subscription
        passiveSubscription?.dispose()

        passiveSubscription = socket.addChatEventHandler(
            conversationId: chatId,
            sessionId: nil // No session filter — observe ALL events for this chat
        ) { [weak self] event, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handlePassiveEvent(event)
            }
        }

        logger.info("Passive socket listener registered for chat \(chatId)")
    }

    /// Handles a socket event received by the passive listener.
    private func handlePassiveEvent(_ event: [String: Any]) {
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]
        let messageId = event["message_id"] as? String
        let chatId = conversationId ?? conversation?.id

        // --- Metadata events: ALWAYS process (title, tags, follow-ups) ---
        switch type {
        case "chat:title":
            var newTitle: String?
            if let titleStr = data["data"] as? String, !titleStr.isEmpty {
                newTitle = titleStr
            } else if let p = payload, let t = p["title"] as? String, !t.isEmpty {
                newTitle = t
            }
            if let newTitle {
                applyGeneratedConversationTitle(newTitle, chatId: chatId)
            }
            return

        case "chat:tags":
            if let chatId, let msgId = messageId {
                Task { try? await refreshConversationMetadata(chatId: chatId, assistantMessageId: msgId) }
            }
            return

        case "chat:message:follow_ups":
            if let msgId = messageId {
                var followUps: [String] = []
                if let payload {
                    followUps = payload["follow_ups"] as? [String]
                        ?? payload["followUps"] as? [String]
                        ?? payload["suggestions"] as? [String] ?? []
                }
                if followUps.isEmpty, let directArray = data["data"] as? [String] {
                    followUps = directArray
                }
                let trimmed = followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !trimmed.isEmpty {
                    appendFollowUps(id: msgId, followUps: trimmed)
                }
            }
            return

        default:
            break
        }

        // --- Content/streaming events: only process when NOT self-initiated ---
        guard !selfInitiatedStream else { return }

        // Extract content from events. Handle both message AND chat:completion
        // event types, using replace-if-longer to prevent duplication.
        var contentDelta: String?
        var isReplace = false
        
        switch type {
        case "chat:message:delta", "event:message:delta":
            contentDelta = payload?["content"] as? String
        case "message", "chat:message", "replace":
            contentDelta = payload?["content"] as? String
            isReplace = true
        case "chat:completion":
            if let choices = payload?["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let c = delta["content"] as? String, !c.isEmpty {
                contentDelta = c
            } else if let c = payload?["content"] as? String, !c.isEmpty {
                contentDelta = c
                isReplace = true
            }
        default:
            break
        }

        // If this is a content event with actual text
        if let contentDelta, !contentDelta.isEmpty {
            guard let msgId = messageId else { return }

            // If message doesn't exist locally, do ONE sync (guarded by flag)
            if conversation?.messages.first(where: { $0.id == msgId }) == nil {
                guard !isSyncingExternalStream else { return }
                isSyncingExternalStream = true
                isExternallyStreaming = true
                isStreaming = true
                // Reset hasFinishedStreaming so self-initiated cleanup guards
                // don't interfere with this new external stream
                hasFinishedStreaming = false
                Task {
                    await self.syncOnceForExternalStream(messageId: msgId)
                    self.isSyncingExternalStream = false
                }
                return
            }

            // Message exists — append content directly (real-time socket streaming)
            if !isExternallyStreaming {
                isExternallyStreaming = true
                isStreaming = true
                // Reset hasFinishedStreaming for each new external stream session
                hasFinishedStreaming = false
                logger.info("External stream: first token for message \(msgId)")
            }
            if let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                let previousRawContent = externalRawContentByMessageId[msgId]
                    ?? conversation?.messages[index].content
                    ?? ""
                let rawContent: String
                if isReplace {
                    // Full content replacement (message, chat:message, replace, chat:completion fallback)
                    rawContent = contentDelta
                } else {
                    // Delta/token append (chat:message:delta, chat:completion choices.delta)
                    rawContent = previousRawContent + contentDelta
                }
                externalRawContentByMessageId[msgId] = rawContent
                let displayContent = Self.safeAssistantDisplayContent(
                    Self.cleanedProviderCitationArtifacts(rawContent)
                )
                conversation?.messages[index].content = displayContent
                conversation?.messages[index].isStreaming = true
                triggerStreamingHaptic()
            }

            // Also check for done signal within content events (chat:completion
            // can carry both content AND done:true in the same event)
            if type == "chat:completion", let payload, payload["done"] as? Bool == true {
                let finalContent = externalRawContentByMessageId[msgId]
                    ?? conversation?.messages.first(where: { $0.id == msgId })?.content
                    ?? ""
                isExternallyStreaming = false
                isStreaming = false
                isSyncingExternalStream = false
                if let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                    attachInlineImages(from: finalContent, to: index)
                    conversation?.messages[index].isStreaming = false
                }
                normalizeAssistantGeneratedMedia(messageId: msgId)
                externalRawContentByMessageId[msgId] = nil
                let normalizedContent = conversation?.messages
                    .first(where: { $0.id == msgId })?.content ?? finalContent
                let chatId = conversationId ?? conversation?.id
                Task {
                    await self.sendCompletionNotificationIfNeeded(content: normalizedContent)
                    if let chatId {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let manager = self.manager else { return }
                        if let serverConv = try? await manager.fetchConversation(id: chatId) {
                            self.adoptServerMessages(serverConversation: serverConv)
                            self.normalizeAssistantGeneratedMedia(messageId: msgId)
                        }
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                    }
                }
            }
            return
        }

        // Handle done signal (when no content in the event)
        if type == "chat:completion", let payload, payload["done"] as? Bool == true {
            let finalContent = messageId.flatMap { id in
                externalRawContentByMessageId[id]
                    ?? conversation?.messages.first(where: { $0.id == id })?.content
            } ?? ""
            isExternallyStreaming = false
            isStreaming = false
            isSyncingExternalStream = false
            if let msgId = messageId,
               let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                attachInlineImages(from: finalContent, to: index)
                conversation?.messages[index].isStreaming = false
                normalizeAssistantGeneratedMedia(messageId: msgId)
                externalRawContentByMessageId[msgId] = nil
            }
            // Final sync to pick up complete content, files, sources
            let chatId = conversationId ?? conversation?.id
            Task {
                await self.sendCompletionNotificationIfNeeded(content: finalContent)
                if let chatId {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let manager = self.manager else { return }
                    if let serverConv = try? await manager.fetchConversation(id: chatId) {
                        self.adoptServerMessages(serverConversation: serverConv)
                        if let msgId = messageId {
                            self.normalizeAssistantGeneratedMedia(messageId: msgId)
                        }
                    }
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
            return
        }

        // Handle errors and cancellation
        if type == "chat:message:error" || type == "chat:tasks:cancel" {
            isExternallyStreaming = false
                isStreaming = false
            isSyncingExternalStream = false
            if let msgId = messageId,
               let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                conversation?.messages[index].isStreaming = false
                externalRawContentByMessageId[msgId] = nil
            }
            return
        }
    }

    /// Fetches conversation from server ONCE to pick up the message structure
    /// (user + assistant messages) that an external client created. After this
    /// sync, the message exists locally and subsequent socket tokens can be
    /// appended directly without needing another fetch.
    private func syncOnceForExternalStream(messageId: String) async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            adoptServerMessages(serverConversation: serverConversation)

            // After syncing, mark the target message as streaming
            if let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) {
                conversation?.messages[index].isStreaming = true
            }
            logger.info("External stream: synced messages, now tracking \(messageId)")
        } catch {
            logger.warning("External stream sync failed: \(error.localizedDescription)")
        }
    }

    /// Task for the external stream polling loop.
    private var externalStreamPollTask: Task<Void, Never>?

    /// Starts a polling loop that fetches conversation content from the server
    /// every 1.5 seconds during an external stream. The server persists streamed
    /// content to the database in real-time, so each poll gets the latest
    /// accumulated text — giving a near-real-time streaming effect.
    private func startExternalStreamPolling() {
        // Cancel any existing poll task
        externalStreamPollTask?.cancel()

        let chatId = conversationId ?? conversation?.id
        externalStreamPollTask = Task { @MainActor [weak self] in
            guard let self, let chatId, let manager = self.manager else { return }

            // Initial fetch to pick up new messages (user + assistant from website)
            do {
                let serverConv = try await manager.fetchConversation(id: chatId)
                self.adoptServerMessages(serverConversation: serverConv)
                // Mark last assistant as streaming for UI
                if let lastIdx = self.conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
                    self.conversation?.messages[lastIdx].isStreaming = true
                }
            } catch {
                self.logger.warning("External stream initial fetch failed: \(error.localizedDescription)")
            }

            while !Task.isCancelled && self.isExternallyStreaming {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, self.isExternallyStreaming else { break }

                do {
                    let serverConv = try await manager.fetchConversation(id: chatId)
                    if let serverAssistant = serverConv.messages.last(where: { $0.role == .assistant }),
                       let localIdx = self.conversation?.messages.firstIndex(where: { $0.id == serverAssistant.id }) {
                        let localContent = self.conversation?.messages[localIdx].content ?? ""
                        if !CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                            local: localContent,
                            incoming: serverAssistant.content
                        ) {
                            self.conversation?.messages[localIdx].content = serverAssistant.content
                        }
                        self.conversation?.messages[localIdx].isStreaming = true
                    }
                    // Also update title if changed
                    if !serverConv.title.isEmpty && serverConv.title != "New Chat" {
                        self.conversation?.title = serverConv.title
                    }
                } catch {
                    self.logger.warning("External stream poll failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stops the external stream polling loop and does a final sync.
    private func stopExternalStreamPolling() {
        externalStreamPollTask?.cancel()
        externalStreamPollTask = nil
        isExternallyStreaming = false
                isStreaming = false

        // Mark last assistant as not streaming
        if let lastIdx = conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
            conversation?.messages[lastIdx].isStreaming = false
        }

        logger.info("External stream completed — final sync")

        // Final sync to pick up complete content, files, sources
        let chatId = conversationId ?? conversation?.id
        if let chatId {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let manager = self.manager else { return }
                if let serverConv = try? await manager.fetchConversation(id: chatId) {
                    self.adoptServerMessages(serverConversation: serverConv)
                    if let lastAssistant = self.conversation?.messages.last(where: { $0.role == .assistant }) {
                        self.normalizeAssistantGeneratedMedia(messageId: lastAssistant.id)
                    }
                }
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            }
        }
    }

    /// Checks whether an external client is currently streaming to this chat.
    ///
    /// Uses the `POST /api/v1/tasks/active/chats` endpoint to detect in-progress
    /// generations. If active, sets isExternallyStreaming and isStreaming to true, and marks
    /// the last assistant message as streaming so the UI shows the correct state.
    private func checkForActiveExternalStream() async {
        guard let chatId = conversationId ?? conversation?.id else { return }
        guard let apiClient = manager?.apiClient else { return }

        do {
            let activeChats = try await apiClient.checkActiveChats(chatIds: [chatId])
            if activeChats.contains(chatId) {
                // This chat has an active generation from another client
                if let lastAssistant = conversation?.messages.last(where: { $0.role == .assistant }) {
                    // Only mark as externally streaming if the message looks incomplete
                    // (empty or the server is still producing content)
                    let content = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if content.isEmpty || lastAssistant.isStreaming {
                        isExternallyStreaming = true
                isStreaming = true
                        if let index = conversation?.messages.firstIndex(where: { $0.id == lastAssistant.id }) {
                            conversation?.messages[index].isStreaming = true
                        }
                        logger.info("Detected active external stream on chat open")
                    }
                }
            }
        } catch {
            // Non-critical — passive listener will catch events anyway
            logger.debug("Active chat check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - New Conversation

    func startNewConversation() {
        conversation = nil
        inputText = ""
        attachments = []
        errorMessage = nil
        refreshContextBudgetStatus()
        cleanupStreaming()
        webSearchEnabled = false
        imageGenerationEnabled = false
        codeInterpreterEnabled = false
        isTemporaryChat = UserDefaults.standard.bool(forKey: "temporaryChatDefault")
        userDisabledToolIds = []
        userDisabledBuiltinFeatures = []
        selectedToolIds = []
        selectedKnowledgeItems = []
        selectedSkillIds = []
        // Sync UI toggles with the selected model's server-configured defaults.
        syncUIWithModelDefaults()
    }

    /// Converts a temporary chat into a permanent one by saving it to the server.
    func saveTemporaryChat() async {
        guard isTemporaryChat, let conversation, let manager else { return }
        let modelId = selectedModelId ?? conversation.model ?? ""
        do {
            let created = try await manager.createConversation(
                title: conversation.title, messages: [], model: modelId,
                folderId: folderContextId)
            // Update the conversation ID to the server-assigned one
            self.conversation?.id = created.id
            // Sync all messages
            try await manager.syncConversationMessages(
                id: created.id, messages: conversation.messages, model: modelId,
                chatParams: conversation.chatParams)
            isTemporaryChat = false
            logger.info("Temporary chat saved as \(created.id)")
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        } catch {
            logger.error("Failed to save temporary chat: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sending Messages

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let manager else { return }
        let isLocalAlpineInterjection = Self.isLocalAlpineInterjection(text)
        let isExplicitLocalAlpineResume = Self.isExplicitLocalAlpineResumeRequest(text)
        if isLocalAlpineInterjection && !isExplicitLocalAlpineResume {
            pauseLocalAlpineAgentLoopForUserInterjection()
        } else {
            resetLocalAlpineAgentLoopForNewTurn()
        }
        if attachments.contains(where: { $0.uploadStatus == .error && !canSendAttachmentWithoutCompletedUpload($0) }) {
            errorMessage = "One or more attachments failed to upload. Retry or remove them before sending."
            return
        }
        if attachments.contains(where: { $0.isUploading && !canSendAttachmentWithoutCompletedUpload($0) }) {
            errorMessage = "Please wait for attachments to finish uploading."
            return
        }
        // Use mentioned model (@ override) if set, otherwise the chat's selected model
        guard let modelId = mentionedModelId ?? selectedModelId else {
            errorMessage = "Please select a model first."
            return
        }
        if isStreaming {
            guard canSendWhileStreaming else { return }
            guard canStartIndependentDirectMediaGeneration(modelId: modelId) else {
                errorMessage = "当前仍有图片/视频生成任务在进行；可以继续提交新的图片/视频生成请求，普通对话请先停止或等待完成。"
                return
            }
        }
        if isChatWebSearchAllowed && !userDisabledBuiltinFeatures.contains("web_search") {
            webSearchEnabled = true
        }

        // Process audio attachments depending on transcription mode.
        // Server mode: audio was already uploaded via /api/v1/files/?process=true —
        //   treat it like any other uploaded file (pass through with its uploadedFileId).
        // Device mode: on-device transcription produced transcribedText — convert that
        //   to a .txt file attachment so the model can read it as a document.
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        var processedAttachments: [ChatAttachment] = []

        for attachment in attachments {
            if attachment.type == .audio {
                if audioFileMode == "server" {
                    // Server already transcribed the file — pass it through so
                    // the uploadedFileId is included in the message payload.
                    processedAttachments.append(attachment)
                } else {
                    // On-device mode: convert transcription to a text file attachment.
                    if let transcript = attachment.transcribedText, !transcript.isEmpty {
                        let baseName = (attachment.name as NSString).deletingPathExtension
                        let transcriptFileName = "\(baseName)_transcript.txt"
                        let transcriptData = transcript.data(using: .utf8) ?? Data()

                        let textAttachment = ChatAttachment(
                            type: .file,
                            name: transcriptFileName,
                            thumbnail: nil,
                            data: transcriptData
                        )
                        processedAttachments.append(textAttachment)
                    }
                    // Don't include the raw audio file in device mode — only the transcript
                }
            } else {
                processedAttachments.append(attachment)
            }
        }

        // Capture and clear knowledge items — they attach to this message only.
        // The server handles RAG retrieval per-message from the files array.
        let currentKnowledgeItems = selectedKnowledgeItems
        selectedKnowledgeItems = []
        // Capture and clear reference chats — they attach to this message only.
        let currentReferenceChats = selectedReferenceChats
        selectedReferenceChats = []

        // Capture and clear skill IDs — sent as skill_ids in the API request.
        let currentSkillIds = selectedSkillIds
        selectedSkillIds = []

        let currentText = text
        let currentAttachments = processedAttachments
        errorMessage = nil
        DiagnosticLogManager.shared.info(
            "Sending message provider=\(currentProviderType?.rawValue ?? "unknown") model=\(modelId) chars=\(currentText.count) attachments=\(currentAttachments.count) temporary=\(isTemporaryChat)",
            category: "Chat"
        )

        await persistExplicitMemoryRequestIfNeeded(from: currentText)

        let normalizedLocalAlpineText = Self.normalizedLocalAlpineCommand(currentText)
        let shouldKeepMediaRoute = shouldKeepMediaGenerationRequestOffLocalAlpine(
            currentText,
            modelId: modelId
        )
        let shouldKeepNativeLinkRoute = Self.shouldKeepNativeLinkResolverOffLocalAlpine(currentText)
        let localAlpineModeForThisTurn = terminalEnabled && selectedTerminalIsLocalAlpine
        if !shouldKeepMediaRoute,
           !shouldKeepNativeLinkRoute,
           processedAttachments.isEmpty,
           shouldSendTextDirectlyToLocalAlpine(normalizedLocalAlpineText),
           localAlpineModeForThisTurn {
            DiagnosticLogManager.shared.info(
                "Routing message directly to Local Alpine model=\(modelId) chars=\(currentText.count)",
                category: "Chat"
            )
            await sendDirectLocalAlpineCommand(currentText, modelId: modelId)
            return
        }

        // Build file references from pre-uploaded attachments.
        // Files are uploaded at attach time (uploadAttachmentImmediately),
        // so we just collect the already-assigned file IDs here.
        // Only fall back to uploading at send time for attachments that
        // somehow don't have a file ID yet (e.g., audio transcription text files).
        var fileRefs: [[String: Any]] = []
        var inlineImageFiles: [ChatMessageFile] = []
        var inlineTextFiles: [ChatMessageFile] = []
        var inlineTextSnippets: [String] = []
        var fallbackUploadFailure: String?
        for attachment in currentAttachments {
            if isOpenAICompatibleProvider, let data = attachment.data, attachment.type == .image {
                let dataURL = attachment.displayDataURL ?? inlineImageDataURL(data: data, fileName: attachment.name)
                let displayURL = inlineImageDisplayReference(dataURL: dataURL)
                inlineImageFiles.append(ChatMessageFile(
                    type: "image",
                    url: dataURL,
                    name: attachment.name,
                    contentType: "image/jpeg",
                    displayURL: displayURL
                ))
            } else if let fileId = attachment.uploadedFileId {
                // Already uploaded + processed — build rich web-UI-format ref
                let fileObject = attachment.uploadedFileObject ?? [:]
                let isImage = attachment.type == .image
                let contentType: String = isImage ? "image/jpeg" : mimeType(for: attachment.name)
                let payloadType = isImage ? "image" : "file"
                let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                fileRefs.append([
                    "type": payloadType,
                    "file": fileObject.isEmpty ? [
                        "id": fileId,
                        "filename": attachment.name,
                        "meta": ["name": attachment.name, "content_type": contentType, "size": size]
                    ] : fileObject,
                    "id": fileId,
                    "url": fileId,
                    "name": attachment.name,
                    "status": "uploaded",
                    "size": size,
                    "error": "",
                    "content_type": contentType
                ])
                if isImage,
                   let dataURL = attachment.displayDataURL
                    ?? attachment.data.map({ inlineImageDataURL(data: $0, fileName: attachment.name) }) {
                    let displayURL = inlineImageDisplayReference(dataURL: dataURL)
                    inlineImageFiles.append(ChatMessageFile(
                        type: "image",
                        url: fileId,
                        name: attachment.name,
                        contentType: contentType,
                        displayURL: displayURL
                    ))
                }
            } else if let data = attachment.data, attachment.type == .image {
                let dataURL = inlineImageDataURL(data: data, fileName: attachment.name)
                let displayURL = inlineImageDisplayReference(dataURL: dataURL)
                inlineImageFiles.append(ChatMessageFile(
                    type: "image",
                    url: dataURL,
                    name: attachment.name,
                    contentType: "image/jpeg",
                    displayURL: displayURL
                ))
            } else if let data = attachment.data, canSendAttachmentInline(attachment) {
                inlineTextSnippets.append(inlineTextContext(for: attachment, data: data))
                inlineTextFiles.append(inlineTextDisplayFile(for: attachment, data: data))
            } else if isOpenAICompatibleProvider, let data = attachment.data, attachment.type == .file {
                inlineTextSnippets.append(inlineBinaryContext(for: attachment, data: data))
                fileRefs.append([
                    "type": "file",
                    "id": "local-binary:\(attachment.id.uuidString)",
                    "url": "local-binary:\(attachment.id.uuidString)",
                    "name": attachment.name,
                    "status": "inline",
                    "size": data.count,
                    "error": "",
                    "content_type": mimeType(for: attachment.name)
                ])
            } else if let data = attachment.data, attachment.uploadStatus != .error {
                // Fallback: upload now (e.g., audio transcript text files that don't go
                // through uploadAttachmentImmediately). Skip attachments that previously
                // failed — the error chip is already shown; the user must retry or remove.
                do {
                    let uploadResult: (fileId: String, fileObject: [String: Any])
                    if attachment.type == .file && Self.shouldUploadWithoutServerProcessing(attachment.name) {
                        let fileObject = try await manager.uploadFileOnly(data: data, fileName: attachment.name)
                        guard let fileId = fileObject["id"] as? String else {
                            throw APIError.responseDecoding(
                                underlying: NSError(
                                    domain: "APIError",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Missing file ID in upload response"]
                                ),
                                data: nil
                            )
                        }
                        uploadResult = (fileId: fileId, fileObject: fileObject)
                    } else {
                        uploadResult = try await manager.uploadFile(data: data, fileName: attachment.name)
                    }
                    let (fileId, fileObject) = uploadResult
                    let isImage = attachment.type == .image
                    let contentType: String = isImage ? "image/jpeg" : mimeType(for: attachment.name)
                    let payloadType = isImage ? "image" : "file"
                    let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                    fileRefs.append([
                        "type": payloadType,
                        "file": fileObject.isEmpty ? [
                            "id": fileId,
                            "filename": attachment.name,
                            "meta": ["name": attachment.name, "content_type": contentType, "size": size]
                        ] : fileObject,
                        "id": fileId,
                        "url": fileId,
                        "name": attachment.name,
                        "status": "uploaded",
                        "size": size,
                        "error": "",
                        "content_type": contentType
                    ])
                    if isImage {
                        let dataURL = inlineImageDataURL(data: data, fileName: attachment.name)
                        let displayURL = inlineImageDisplayReference(dataURL: dataURL)
                        inlineImageFiles.append(ChatMessageFile(
                            type: "image",
                            url: fileId,
                            name: attachment.name,
                            contentType: contentType,
                            displayURL: displayURL
                        ))
                    }
                } catch {
                    fallbackUploadFailure = error.localizedDescription
                    logger.error("Upload failed: \(error.localizedDescription)")
                    DiagnosticLogManager.shared.error(
                        "Fallback attachment upload failed attachments=\(currentAttachments.count) error=\(error.localizedDescription)",
                        category: "Chat"
                    )
                    break
                }
            }
            // Note: attachments with uploadStatus == .error and no uploadedFileId are
            // intentionally skipped — they failed at attach-time and must be retried or removed.
        }
        if let fallbackUploadFailure {
            errorMessage = "Attachment upload failed: \(fallbackUploadFailure)"
            return
        }

        inputText = ""
        attachments = []

        let messageText = currentText
        let modelAttachmentContext = inlineTextSnippets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let modelPromptText: String = {
            guard !modelAttachmentContext.isEmpty else { return messageText }
            if messageText.isEmpty { return modelAttachmentContext }
            return messageText + "\n\n" + modelAttachmentContext
        }()

        // Create user message - store file IDs (not base64) matching Flutter behavior
        let uploadedAttachmentIds = fileRefs.compactMap { $0["id"] as? String }
        var messageFiles: [ChatMessageFile] = fileRefs.map { ref in
            // Derive content_type from filename so the Iexa native server web client
            // knows to append `/content` to the file URL. Without content_type,
            // the web client constructs `/files/{id}` (returns JSON metadata)
            // instead of `/files/{id}/content` (returns actual file bytes).
            // This affects images (broken thumbnails), PDFs, docs, and all files.
            let name = ref["name"] as? String
            let contentType: String? = mimeType(for: name ?? "file")
            let normalizedType: String = {
                let rawType = (ref["type"] as? String) ?? "file"
                if rawType == "image" || (contentType ?? "").hasPrefix("image/") {
                    return "image"
                }
                return rawType
            }()
            var displayURL: String?
            if normalizedType == "image", let fileId = ref["id"] as? String {
                displayURL = inlineImageFiles.first(where: {
                    $0.url == fileId || ($0.name == name && Self.isImageFile($0))
                })?.displayURL
            }
            return ChatMessageFile(
                type: normalizedType,
                url: ref["id"] as? String,  // Store file ID, not base64
                name: name,
                contentType: contentType,
                displayURL: displayURL
            )
        }
        for inlineImage in inlineImageFiles where inlineImage.url?.hasPrefix("data:image/") == true {
            messageFiles.append(inlineImage)
        }
        messageFiles.append(contentsOf: inlineTextFiles)
        // Also store knowledge items (collection/folder/file) on the user message
        // so they persist in conversation history and appear on reload.
        for knowledgeItem in currentKnowledgeItems {
            messageFiles.append(ChatMessageFile(
                type: knowledgeItem.type.rawValue,
                url: knowledgeItem.id,
                name: knowledgeItem.name,
                contentType: nil
            ))
        }
        let userMessage = ChatMessage(
            role: .user,
            content: messageText,
            timestamp: .now,
            attachmentIds: uploadedAttachmentIds,
            files: messageFiles
        )

        // Capture the ID of the last message before appending the user message.
        // This becomes the user message's parentId in the history tree.
        let userMessageParentId = conversation?.messages.last(where: {
            !Self.isLocalWorkspaceAgentResult($0) && !Self.isLocalAlpineAgentResult($0)
        })?.id

        // Ensure conversation exists on server (skip for temporary chats)
        if conversation == nil {
            let chatTitle = Self.initialConversationTitle(from: messageText, files: messageFiles)
            var serverId: String?
            if !isTemporaryChat && !isOpenAICompatibleProvider {
                do {
                    let created = try await manager.createConversation(
                        title: chatTitle, messages: [], model: modelId,
                        folderId: folderContextId)
                    serverId = created.id
                } catch {
                    logger.warning("Pre-create failed: \(error.localizedDescription)")
                }
            }
            let localId = isTemporaryChat ? "local:\(UUID().uuidString)" : (serverId ?? UUID().uuidString)
            var newConv = Conversation(
                id: localId,
                title: chatTitle, model: modelId, messages: [userMessage])
            // Apply any chat params that were set before the conversation existed
            if let pending = pendingChatParams {
                newConv.chatParams = pending
                pendingChatParams = nil
            }
            conversation = newConv
            if isOpenAICompatibleProvider {
                activeChatStore?.promoteNewChat(to: localId)
            }
            initialAutoTitlesByConversationId[localId] = chatTitle
            // Update active conversation ID so notifications are suppressed
            // while the user is viewing this newly created chat
            NotificationService.shared.activeConversationId = localId
        } else {
            conversation?.messages.append(userMessage)
        }

        // Assistant placeholder
        let assistantMessageId = UUID().uuidString
        let isDirectImageGenerationPlaceholder = canUseDirectImageEndpointProvider
            && shouldUseDirectImageGeneration(modelId: modelId)
            && !shouldPreferChatNativeImageGeneration(modelId: modelId)
        conversation?.messages.append(ChatMessage(
            id: assistantMessageId, role: .assistant, content: "",
            timestamp: .now, model: modelId, isStreaming: true,
            metadata: isDirectImageGenerationPlaceholder
                ? ["iexa_image_generation_placeholder": "true"]
                : nil))

        // ── Build / update the history tree ─────────────────────────────────
        // This ensures the tree is always populated with correct parentId /
        // childrenIds from the very first message, so that later calls to
        // editMessage() (which bootstraps the tree if empty) see a proper
        // branching structure instead of an orphaned root node.
        let userNodeModels = [modelId]
        let userHistoryNode = HistoryNode(
            id: userMessage.id,
            parentId: userMessageParentId,
            childrenIds: [assistantMessageId],
            role: .user,
            content: messageText,
            timestamp: userMessage.timestamp,
            files: isOpenAICompatibleProvider ? messageFiles : Self.serverPersistableFiles(messageFiles),
            models: userNodeModels
        )
        let assistantHistoryNode = HistoryNode(
            id: assistantMessageId,
            parentId: userMessage.id,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: userMessage.timestamp,
            model: modelId,
            done: false
        )
        conversation?.history.nodes[userMessage.id] = userHistoryNode
        conversation?.history.nodes[assistantMessageId] = assistantHistoryNode
        // Wire user node as a child of its parent (if parent exists in tree)
        if let pid = userMessageParentId {
            conversation?.history.appendChildId(userMessage.id, to: pid)
        }
        conversation?.history.currentId = assistantMessageId
        scheduleLocalConversationAutosave(immediate: true)
        // ────────────────────────────────────────────────────────────────────

        if !modelAttachmentContext.isEmpty {
            attachmentContextsByMessageId[userMessage.id] = modelAttachmentContext
        }

        await resolveWebLinkContextIfNeeded(
            userMessageId: userMessage.id,
            assistantMessageId: assistantMessageId,
            text: modelPromptText
        )

        await resolveWebSearchContextIfNeeded(
            userMessageId: userMessage.id,
            assistantMessageId: assistantMessageId,
            text: modelPromptText,
            modelId: modelId,
            hasAttachments: !currentAttachments.isEmpty
        )

        // Build API messages with image content fetched from server
        let imageCanvasInstructionMessageId = (imageGenerationEnabled
            || shouldUseDirectImageGeneration(modelId: modelId)
            || shouldPreferChatNativeImageGeneration(modelId: modelId))
            && Self.looksLikeImageGenerationRequest(modelPromptText)
            ? userMessage.id
            : nil
        let useLocalAlpineNativeToolsForThisTurn =
            localAlpineModeForThisTurn && shouldUseLocalAlpineNativeTools(for: modelId)
        let apiMessages = await buildAPIMessagesAsync(
            imageCanvasInstructionMessageId: imageCanvasInstructionMessageId,
            preferLocalAlpineNativeTools: useLocalAlpineNativeToolsForThisTurn
        )
        appendContextCompressionStatusIfNeeded(to: assistantMessageId)
        let parentId = userMessage.id
        sessionId = UUID().uuidString
        let effectiveChatId = conversationId ?? conversation?.id

        // Cancel any previous message's completion task that may still be
        // running delayed polls — prevents it from overwriting this new
        // message's content via adoptServerMessages/refreshConversationMetadata.
        completionTask?.cancel()
        completionTask = nil

        let shouldUseIndependentDirectMediaGeneration = canStartIndependentDirectMediaGeneration(modelId: modelId)

        if shouldUseIndependentDirectMediaGeneration {
            startIndependentDirectMediaGeneration(
                assistantMessageId: assistantMessageId,
                modelId: modelId,
                modelPromptText: modelPromptText,
                messageText: messageText,
                currentAttachments: currentAttachments,
                manager: manager
            )
            return
        }

        isStreaming = true
        hasFinishedStreaming = false
        socketHasReceivedContent = false
        selfInitiatedStream = true
        beginStreamingBackgroundTaskIfNeeded()

        // Activate the isolated streaming store so token updates bypass
        // conversation.messages and only invalidate the streaming message view.
        let initialStatusHistory = conversation?.messages.first(where: { $0.id == assistantMessageId })?.statusHistory ?? []
        let initialSources = conversation?.messages.first(where: { $0.id == assistantMessageId })?.sources ?? []
        streamingStore.beginStreaming(
            messageId: assistantMessageId,
            modelId: modelId,
            initialStatusHistory: initialStatusHistory,
            initialSources: initialSources
        )
        appendContextCompressionStatusIfNeeded(to: assistantMessageId)
        await startRunLiveActivity(id: assistantMessageId, modelId: modelId, prompt: modelPromptText)

        if isOpenAICompatibleProvider {
            streamingTask = Task { [weak self] in
                guard let self else { return }
                let acc = ContentAccumulator()
                var exactUsage: [String: Any]?

                do {
                    if self.shouldUseDirectVideoGeneration(modelId: modelId) {
                        let videoPrompt = modelPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !videoPrompt.isEmpty else {
                            throw APIError.unknown(
                                underlying: NSError(
                                    domain: "ChatViewModel",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "请输入视频生成提示词。"]
                                )
                            )
                        }
                        let requestedVideoSize = Self.requestedImageSize(from: videoPrompt)
                        let videoSeedImage = self.firstEditableImage(from: currentAttachments)
                        await RunLiveActivityService.shared.update(
                            id: assistantMessageId,
                            title: "正在生成视频",
                            detail: videoPrompt,
                            phase: "生成",
                            progress: 0.35,
                            isIndeterminate: true,
                            force: true
                        )
                        let videoReference = try await self.runMediaRequestWithRetry {
                            try await manager.generateVideo(
                                prompt: videoPrompt,
                                model: modelId,
                                size: requestedVideoSize,
                                duration: Self.requestedVideoDuration(from: videoPrompt),
                                imageData: videoSeedImage?.data,
                                imageFileName: videoSeedImage?.fileName ?? "image.png"
                            )
                        }
                        self.updateAssistantMessage(
                            id: assistantMessageId,
                            content: "已生成视频",
                            isStreaming: false
                        )
                        self.attachGeneratedVideoFile(
                            messageId: assistantMessageId,
                            videoReference: videoReference
                        )
                        self.recordTokenUsageForCompletedTurn(
                            assistantMessageId: assistantMessageId,
                            userText: messageText,
                            assistantText: "已生成视频",
                            userAttachments: currentAttachments,
                            mediaKind: .video,
                            mediaCount: 1
                        )
                        self.hasFinishedStreaming = true
                        self.isStreaming = false
                        self.selfInitiatedStream = false
                        self.activeTaskId = nil
                        self.lastTaskExtractionLength = 0
                        await self.persistLocalConversationIfNeeded()
                        await self.sendCompletionNotificationIfNeeded(content: "已生成视频")
                        self.endBackgroundTask()
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                        return
                    }

                    if self.shouldUseDirectImageGeneration(modelId: modelId),
                       !self.shouldPreferChatNativeImageGeneration(modelId: modelId) {
                        do {
                            guard self.currentProviderType != .anthropic else {
                                throw APIError.unknown(
                                    underlying: NSError(
                                        domain: "ChatViewModel",
                                        code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Claude/Anthropic 不提供图片生成端点。"]
                                    )
                                )
                            }
                            let imagePrompt = modelPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let requestedImageCount = Self.requestedImageCount(from: imagePrompt)
                            let requestedCanvasSize = Self.requestedImageCanvasSize(from: imagePrompt)
                            let requestedImageSize = Self.imageEndpointSize(for: requestedCanvasSize)
                            let editImages = self.editableImages(from: currentAttachments)
                            let imagePromptForAPI = Self.promptWithImageSizeInstruction(
                                imagePrompt.isEmpty
                                    ? (editImages.count > 1 ? "Use all attached images as references and combine or edit them according to the user's request." : "Edit this image.")
                                    : imagePrompt,
                                canvasSize: requestedCanvasSize,
                                endpointSize: requestedImageSize
                            )
                            let imagePrompts = Self.imageVariantPrompts(
                                basePrompt: imagePromptForAPI,
                                requestedCount: requestedImageCount
                            )
                            await RunLiveActivityService.shared.update(
                                id: assistantMessageId,
                                title: "正在创建图片",
                                detail: requestedImageCount > 1
                                    ? "正在生成 \(requestedImageCount) 张不同图片"
                                    : (imagePrompt.isEmpty ? "正在编辑图片" : imagePrompt),
                                phase: "生成",
                                progress: 0.35,
                                isIndeterminate: true,
                                force: true
                            )
                            let generatedImageSlots = try await self.generateDirectImageSlots(
                                prompts: imagePrompts,
                                modelId: modelId,
                                requestedImageSize: requestedImageSize,
                                requestedCanvasSize: requestedCanvasSize,
                                editImages: editImages,
                                manager: manager,
                                originalPromptWasEmpty: imagePrompt.isEmpty
                            )
                            if generatedImageSlots.isEmpty {
                                throw APIError.unknown(
                                    underlying: NSError(
                                        domain: "ChatViewModel",
                                        code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "没有成功生成图片。"]
                                    )
                                )
                            }
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: "",
                                isStreaming: false
                            )
                            for (slotIndex, slot) in generatedImageSlots.enumerated() {
                                switch slot {
                                case .image(let imageReference, let displayReference):
                                    self.attachGeneratedImageFile(
                                        messageId: assistantMessageId,
                                        imageReference: imageReference,
                                        displayReference: displayReference
                                    )
                                case .failure:
                                    self.attachGeneratedImageFailurePlaceholder(
                                        messageId: assistantMessageId,
                                        index: slotIndex + 1
                                    )
                                }
                            }
                            self.recordTokenUsageForCompletedTurn(
                                assistantMessageId: assistantMessageId,
                                userText: messageText,
                                assistantText: "",
                                userAttachments: currentAttachments,
                                mediaKind: .image,
                                mediaCount: max(generatedImageSlots.count, 1)
                            )
                            self.hasFinishedStreaming = true
                            self.isStreaming = false
                            self.selfInitiatedStream = false
                            self.activeTaskId = nil
                            self.lastTaskExtractionLength = 0
                            await self.persistLocalConversationIfNeeded()
                            await self.sendCompletionNotificationIfNeeded(content: "图片生成已结束")
                            self.endBackgroundTask()
                            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                            return
                        } catch {
                            guard self.shouldFallbackToChatForImageGeneration(error) else { throw error }
                            self.logger.warning("Direct image endpoint failed; falling back to chat-native image output: \(error.localizedDescription)")
                            DiagnosticLogManager.shared.warning(
                                "Direct image endpoint failed; falling back to chat-native output model=\(modelId) error=\(error.localizedDescription)",
                                category: "Chat"
                            )
                        }
                    }

                    var request = ChatCompletionRequest(model: modelId, messages: apiMessages, stream: true)
                    if !fileRefs.isEmpty { request.files = fileRefs }
                    await self.populateCommonRequestFields(&request)
                    if !currentSkillIds.isEmpty { request.skillIds = currentSkillIds }
                    if useLocalAlpineNativeToolsForThisTurn {
                        do {
                            exactUsage = try await self.streamOpenAICompatibleLocalAlpineNativeLoop(
                                manager: manager,
                                initialRequest: request,
                                assistantMessageId: assistantMessageId,
                                acc: acc
                            )
                        } catch {
                            guard Self.errorLooksLikeUnsupportedNativeTools(error) else { throw error }
                            self.localAlpineNativeToolsUnsupportedModels.insert(modelId)
                            self.logger.warning("Provider rejected native Local Alpine tools; falling back to Markdown bridge: \(error.localizedDescription)")
                            var fallbackRequest = request
                            fallbackRequest.messages = await self.buildAPIMessagesAsync(
                                imageCanvasInstructionMessageId: imageCanvasInstructionMessageId,
                                preferLocalAlpineNativeTools: false
                            )
                            fallbackRequest.tools = nil
                            fallbackRequest.toolChoice = nil
                            let sseStream = try await manager.sendPreferredOpenAIStreaming(request: fallbackRequest)
                            for try await event in sseStream {
                                if Task.isCancelled { break }
                                if let usage = event.usage, !usage.isEmpty {
                                    exactUsage = usage
                                }
                                self.applyStreamingEventDelta(
                                    event,
                                    to: acc,
                                    assistantMessageId: assistantMessageId
                                )
                                if event.isFinished { break }
                            }
                        }
                    } else {
                        let sseStream = try await manager.sendPreferredOpenAIStreaming(
                            request: request
                        )

                        for try await event in sseStream {
                            if Task.isCancelled { break }

                            if let usage = event.usage, !usage.isEmpty {
                                exactUsage = usage
                            }

                            self.applyStreamingEventDelta(
                                event,
                                to: acc,
                                assistantMessageId: assistantMessageId
                            )

                            if event.isFinished { break }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        DiagnosticLogManager.shared.error(
                            "OpenAI-compatible stream failed model=\(modelId) error=\(Self.localizedGenerationError(error))",
                            category: "Chat"
                        )
                        self.updateAssistantMessage(
                            id: assistantMessageId,
                            content: acc.content,
                            isStreaming: false,
                            error: ChatMessageError(content: Self.localizedGenerationError(error))
                        )
                        self.cleanupStreaming()
                        await self.persistLocalConversationIfNeeded()
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                    }
                    return
                }

                if Task.isCancelled { return }

                acc.markReasoningDone()
                if acc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: "未收到模型回复或图片数据，请重试。")
                    )
                    self.cleanupStreaming()
                    return
                }

                self.updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
                self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                let normalizedContent = self.conversation?.messages.first(where: { $0.id == assistantMessageId })?.content ?? acc.content
                self.applyUsage(exactUsage, toMessageId: assistantMessageId)
                self.recordTokenUsageForCompletedTurn(
                    assistantMessageId: assistantMessageId,
                    userText: messageText,
                    assistantText: normalizedContent,
                    userAttachments: currentAttachments,
                    usage: exactUsage
                )
                self.hasFinishedStreaming = true
                self.isStreaming = false
                self.selfInitiatedStream = false
                self.activeTaskId = nil
                self.lastTaskExtractionLength = 0
                await self.persistLocalConversationIfNeeded()
                await self.sendCompletionNotificationIfNeeded(content: normalizedContent)
                self.endBackgroundTask()
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            }
            return
        }

        // Ensure socket connected with resilient retry.
        // For Cloudflare-protected servers, WebSocket connections may be blocked
        // entirely. In that case, we fall back to SSE streaming (normal HTTPS).
        let socket = socketService
        var socketConnected = socket?.isConnected ?? false

        if let socket, !socketConnected {
            // Show "Reconnecting..." status while we wait
            appendStatusUpdate(id: assistantMessageId,
                status: ChatStatusUpdate(action: "reconnecting", description: "Reconnecting to server…", done: false))

            // Try up to 3 times with increasing timeouts (5s, 8s, 12s)
            for (attempt, timeout) in [(1, 5.0), (2, 8.0), (3, 12.0)] as [(Int, TimeInterval)] {
                socketConnected = await socket.ensureConnected(timeout: timeout)
                if socketConnected { break }
                logger.warning("Socket connect attempt \(attempt) failed, retrying…")
            }

            if socketConnected {
                appendStatusUpdate(id: assistantMessageId,
                    status: ChatStatusUpdate(action: "reconnecting", description: "Connected", done: true))
            } else {
                // Socket failed — will use SSE fallback below
                appendStatusUpdate(id: assistantMessageId,
                    status: ChatStatusUpdate(action: "reconnecting", description: "Using direct connection", done: true))
                logger.info("Socket unavailable — falling back to SSE streaming")
            }
        }

        let useSSEFallback = !socketConnected
        let socketSessionId = socket?.sid ?? sessionId

        // Register socket handlers BEFORE HTTP POST (only if socket is connected)
        if socketConnected, let socket {
            registerSocketHandlers(
                socket: socket, assistantMessageId: assistantMessageId,
                modelId: modelId, socketSessionId: socketSessionId,
                effectiveChatId: effectiveChatId)
        }

        // Sync conversation to server — this writes the complete message tree
        // (with proper parentId/childrenIds) so the server has the full branching
        // structure before the generation starts. Uses tree-based sync now that the
        // history tree is always populated in sendMessage().
        await syncToServerViaTree()

        // Send message to server. When socket is connected, use HTTP POST + socket events.
        // When socket is unavailable (e.g., Cloudflare blocking WebSocket), fall back to
        // SSE streaming which uses normal HTTPS and passes through CF with cookie + UA.
        let capturedUseSSEFallback = useSSEFallback
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: assistantMessageId, parentId: parentId)

                // Merge file attachment refs + knowledge item refs into request.files
                var allFileRefs = fileRefs
                for knowledgeItem in currentKnowledgeItems {
                    allFileRefs.append(knowledgeItem.toChatFileRef())
                }
                for refChat in currentReferenceChats {
                    allFileRefs.append(refChat.toChatFileRef())
                }
                if !allFileRefs.isEmpty { request.files = allFileRefs }

                // Build the user_message node required by updated Iexa native server servers.
                // Without this, the server doesn't link the user message into the history
                // tree, causing it to disappear when the chat is re-opened.
                var userMsgDict: [String: Any] = [
                    "id": userMessage.id,
                    "parentId": (userMessageParentId as Any?) ?? NSNull(),
                    "childrenIds": [assistantMessageId],
                    "role": "user",
                    "content": messageText,
                    "timestamp": Int(userMessage.timestamp.timeIntervalSince1970),
                    "models": [modelId]
                ]
                if !allFileRefs.isEmpty { userMsgDict["files"] = allFileRefs }
                request.userMessage = userMsgDict

                // Populate all common request fields (model metadata, features, params,
                // system variables, tool IDs, terminal, background tasks, etc.)
                await self.populateCommonRequestFields(&request)

                // Include skill IDs selected via the `$` picker.
                // Sent as `skill_ids` in the top-level request body (separate from tool_ids).
                if !currentSkillIds.isEmpty { request.skillIds = currentSkillIds }

                if capturedUseSSEFallback {
                    // ── HTTP + POLLING FALLBACK ──
                    // Socket.IO is unavailable (e.g., Cloudflare blocks WebSocket).
                    // Iexa native server delivers content via socket events, not SSE — so we
                    // use HTTP POST + aggressive server polling to pick up content
                    // in near-real-time. Poll every 1.5s with no initial delay.
                    self.logger.info("Using HTTP + polling fallback (no socket)")
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: detail))
                        self.cleanupStreaming()
                        return
                    }
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    // Aggressive polling: start immediately, poll every 1.5s
                    // Content is being generated server-side and persisted to DB
                    // in real-time. Each poll picks up the latest accumulated text.
                    self.logger.info("HTTP POST done – starting aggressive polling (no socket)")
                    guard let chatId = effectiveChatId else {
                        self.cleanupStreaming()
                        return
                    }
                    var lastContentLength = 0
                    var staleCount = 0
                    for _ in 0..<40 { // up to ~60s of polling
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if Task.isCancelled { break }

                        do {
                            let refreshed = try await manager.fetchConversation(id: chatId)
                            if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !serverContent.isEmpty {
                                    let localContent = self.conversation?.messages
                                        .first(where: { $0.id == assistantMessageId })?.content ?? ""
                                    let protectedContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                                        local: localContent,
                                        incoming: serverAssistant.content
                                    ) ? localContent : serverAssistant.content
                                    self.updateAssistantMessage(id: assistantMessageId, content: protectedContent, isStreaming: true)
                                    // Check if content is still growing
                                    if serverContent.count > lastContentLength {
                                        lastContentLength = serverContent.count
                                        staleCount = 0
                                    } else {
                                        staleCount += 1
                                    }
                                    // If content hasn't changed for 3 consecutive polls (4.5s), it's done
                                    if staleCount >= 3 {
                                        self.logger.info("Polling: content stable at \(serverContent.count) chars — finalizing")
                                        self.updateAssistantMessage(id: assistantMessageId, content: protectedContent, isStreaming: false)
                                        self.hasFinishedStreaming = true
                                        self.isStreaming = false
                                        // Post-completion
                                        self.adoptServerMessages(serverConversation: refreshed)
                                        self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                                        await manager.sendChatCompleted(chatId: chatId, messageId: assistantMessageId, model: modelId, sessionId: socketSessionId, messages: self.buildSimpleAPIMessages())
                                        try? await self.refreshConversationMetadata(chatId: chatId, assistantMessageId: assistantMessageId)
                                        self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                                        Task { @MainActor [weak self] in
                                            await self?.ensureGeneratedConversationTitle(chatId: chatId, modelId: modelId)
                                        }
                                        self.cleanupStreaming()
                                        let finalContent = self.conversation?.messages
                                            .first(where: { $0.id == assistantMessageId })?.content ?? serverContent
                                        await self.sendCompletionNotificationIfNeeded(content: finalContent)
                                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                                        return
                                    }
                                }
                            }
                        } catch {
                            self.logger.warning("Polling failed: \(error.localizedDescription)")
                        }
                    }
                    // Polling exhausted — finalize with whatever we have
                    self.updateAssistantMessage(id: assistantMessageId,
                        content: self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? "",
                        isStreaming: false)
                    self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                    self.cleanupStreaming()
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                } else if request.isPipeModel {
                    // ── PIPE MODEL SSE PATH ──
                    // Pipe/function models bypass the Redis async-task queue when
                    // session_id, chat_id, and id are absent. Content streams directly
                    // from the HTTP response body as standard OpenAI SSE.
                    self.logger.info("Using pipe model SSE path for \(modelId)")
                    let acc = ContentAccumulator()
                    var exactUsage: [String: Any]?

                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }

                            if let usage = event.usage, !usage.isEmpty {
                                exactUsage = usage
                            }

                            // Content and reasoning delta tokens
                            self.applyStreamingEventDelta(
                                event,
                                to: acc,
                                assistantMessageId: assistantMessageId
                            )

                            // Stream finished
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: acc.content.isEmpty ? "" : acc.content,
                                isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription)
                            )
                            self.cleanupStreaming()
                            return
                        }
                    }

                    if Task.isCancelled { return }

                    // Finalize — sync the completed message to server, then do
                    // metadata refresh to pick up any tool-generated files/sources.
                    self.finishStreamingSuccessfully(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        socketSessionId: socketSessionId,
                        effectiveChatId: effectiveChatId,
                        acc: acc,
                        usage: exactUsage
                    )
                } else {
                    // ── SOCKET PATH (normal) ──
                    // HTTP POST returns immediately; content delivered via socket events
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: detail))
                        self.cleanupStreaming()
                        return
                    }

                    // Capture the server's task_id for server-side stop
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    self.logger.info("HTTP POST done – waiting for socket events")
                    self.startRecoveryTimer(assistantMessageId: assistantMessageId, chatId: effectiveChatId)
                }
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                 isStreaming: false,
                                                 error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    private func shouldSendTextDirectlyToLocalAlpine(_ text: String) -> Bool {
        Self.shouldSendRawTextDirectlyToLocalAlpine(text)
    }

    private static func shouldKeepNativeLinkResolverOffLocalAlpine(_ text: String) -> Bool {
        isNativeMediaLinkRequest(text) && !hasExplicitLocalAlpineRouteIntent(text.lowercased())
    }

    private static func isNativeMediaLinkRequest(_ text: String) -> Bool {
        let urls = WebLinkContextResolver.extractHTTPURLs(from: text, limit: 5)
        return urls.contains { url in
            WebLinkContextResolver.isDouyinURL(url) || WebLinkContextResolver.isXiaohongshuURL(url)
        }
    }

    private func shouldKeepMediaGenerationRequestOffLocalAlpine(_ text: String, modelId: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        if Self.hasStrongLocalAlpineIntent(normalized) {
            return false
        }

        if shouldUseDirectImageGeneration(modelId: modelId)
            || shouldPreferChatNativeImageGeneration(modelId: modelId) {
            return true
        }
        if imageGenerationEnabled && Self.looksLikeImageGenerationRequest(normalized) {
            return true
        }
        return shouldUseDirectVideoGeneration(modelId: modelId)
    }

    private enum LocalAlpineUserIntent: Equatable {
        case none
        case explicitLocalAlpine
        case shellCommand
        case inspectLocalState
        case mutateLocalState
        case executeOrVerify
        case setupDependency
        case networkFetch
        case generatedFile

        var requiresHostExecution: Bool {
            self != .none
        }

        var isStrongHostExecution: Bool {
            switch self {
            case .explicitLocalAlpine, .shellCommand, .mutateLocalState,
                 .executeOrVerify, .setupDependency, .networkFetch, .generatedFile:
                return true
            case .inspectLocalState, .none:
                return false
            }
        }

        var isInspectionOnly: Bool {
            self == .inspectLocalState
        }
    }

    private static func hasStrongLocalAlpineIntent(_ normalized: String) -> Bool {
        localAlpineIntent(forNormalized: normalized).isStrongHostExecution
    }

    private static func localAlpineIntent(for text: String) -> LocalAlpineUserIntent {
        localAlpineIntent(forNormalized: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func localAlpineIntent(forNormalized normalized: String) -> LocalAlpineUserIntent {
        let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return .none }

        if hasExplicitLocalAlpineRouteIntent(text) {
            return .explicitLocalAlpine
        }
        if shouldSendRawTextDirectlyToLocalAlpine(text) {
            return .shellCommand
        }

        let generatedFileTerms = [
            "创建文件", "新建文件", "生成文件", "写入文件", "写文件", "保存文件",
            "落盘", "发文件", "发送文件", "创建脚本", "生成脚本", "写脚本", "创建项目", "生成项目",
            "create file", "write file", "save file", "generate file", "send file",
            "create script", "generate script", "write script", "create project", "generate project"
        ]
        if containsAny(text, generatedFileTerms) {
            return .generatedFile
        }

        let mutationTerms = [
            "修改", "编辑", "改一下", "修复代码", "替换", "删除", "清理", "重命名",
            "复制", "移动", "保存", "改成", "换成", "换个", "换一个", "更换",
            "加上", "补上", "删掉", "删了", "移除",
            "modify", "edit", "patch", "replace",
            "delete", "remove", "clean", "rename", "copy", "move", "save"
        ]
        let localObjectTerms = [
            "目录", "文件", "文件夹", "项目", "路径", "脚本", "代码", "仓库",
            "directory", "folder", "file", "files", "project", "path", "script",
            "code", "repo", "repository", "workspace"
        ]
        if containsAnyPair(text, actions: mutationTerms, objects: localObjectTerms)
            || (containsAny(text, mutationTerms) && localAlpineMentionsCodeArtifact(text)) {
            return .mutateLocalState
        }

        let setupTerms = [
            "安装依赖", "装依赖", "安装包", "装包", "安装环境", "配置环境",
            "pip install", "npm install", "apk add", "install dependencies",
            "install deps", "install package", "setup dependency", "setup dependencies"
        ]
        if containsAny(text, setupTerms) {
            return .setupDependency
        }

        let environmentInspectionActions = [
            "检查有没有", "有没有", "是否安装", "是否有", "能不能用", "可不可用",
            "查一下", "看一下", "看看", "列一下", "列出",
            "check whether", "check if", "is installed", "installed", "available",
            "list installed", "what dependencies", "dependencies installed"
        ]
        let environmentInspectionObjects = [
            "依赖", "环境", "包", "模块", "库", "rootfs", "系统", "运行时",
            "python", "pip", "lua", "node", "npm",
            "gcc", "g++", "clang", "make", "编译器", "解释器", "版本",
            "dependency", "dependencies", "environment", "rootfs", "system", "runtime", "package", "packages",
            "module", "modules", "library", "libraries", "compiler", "runtime", "version"
        ]
        if containsAnyPair(text, actions: environmentInspectionActions, objects: environmentInspectionObjects) {
            return .inspectLocalState
        }

        let executionTerms = [
            "执行", "运行", "帮我跑", "给我跑", "跑一下", "跑一遍", "跑这个", "跑这段", "跑上面",
            "跑脚本", "跑代码", "跑测试", "跑项目", "跑起来", "跑通", "测试", "验证", "调试",
            "修复", "修一下", "帮我修", "修这个", "解决", "编译", "构建", "执行脚本", "运行脚本",
            "帮我做", "给我做", "做一下", "处理一下", "搞一下", "弄一下", "实现", "优化",
            "完善", "新增", "补齐", "完成这个", "直接做", "你来做",
            "继续", "继续执行", "继续跑", "继续做", "重跑", "重新跑", "再跑",
            "run", "execute", "test", "verify", "debug", "fix", "compile",
            "build", "implement", "optimize", "complete", "continue", "rerun",
            "run script", "execute script"
        ]
        if containsAny(text, executionTerms) {
            return .executeOrVerify
        }

        let networkActions = [
            "抓取", "爬取", "访问", "请求", "下载",
            "fetch", "scrape", "crawl", "download"
        ]
        let networkObjects = [
            "http://", "https://", "网址", "网站", "网页", "接口", "页面",
            "url", "api", "endpoint"
        ]
        if containsAny(text, ["curl ", "wget "])
            || containsAnyPair(text, actions: networkActions, objects: networkObjects) {
            return .networkFetch
        }

        let diagnosticTerms = [
            "报错", "错误", "失败", "崩溃", "闪退", "不能用", "用不了", "问题", "异常",
            "error", "fail", "failure", "failed", "issue", "bug", "crash",
            "broken", "not working"
        ]
        if containsAny(text, diagnosticTerms), containsAny(text, localObjectTerms) {
            return .executeOrVerify
        }

        let inspectionActions = [
            "读取", "读一下", "读", "查看", "看一下", "看下", "看看", "列出", "列一下",
            "列", "检查", "检查一下", "搜索", "查找", "查一下", "打开", "扫一下", "分析一下",
            "read", "view", "show", "list", "check", "inspect", "search",
            "find", "open", "scan"
        ]
        let inspectionObjects = localObjectTerms + [
            "当前目录", "文件列表", "内容", "这里", "这个项目", "当前项目",
            "current directory", "file list", "contents", "this project"
        ]
        if containsAnyPair(text, actions: inspectionActions, objects: inspectionObjects) {
            return .inspectLocalState
        }

        return .none
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { term in
            !term.isEmpty && text.contains(term)
        }
    }

    private static func containsAnyPair(_ text: String, actions: [String], objects: [String]) -> Bool {
        containsAny(text, actions) && containsAny(text, objects)
    }

    private static func localAlpineMentionsCodeArtifact(_ text: String) -> Bool {
        let normalized = text.lowercased()
        if !localAlpinePathCandidates(in: normalized, limit: 1).isEmpty {
            return true
        }
        let terms = [
            "lua", ".lua", "python", ".py", "javascript", ".js", "typescript", ".ts",
            "c++", "cpp", ".cpp", "c语言", "c 语言", "golang", ".go", "rust", ".rs",
            "java", ".java", "shell", "bash", ".sh", "node", "php", ".php", "ruby", ".rb",
            "swift", ".swift", "kotlin", ".kt", "c#", "csharp", ".cs"
        ]
        if terms.contains(where: { normalized.contains($0) }) {
            return true
        }
        let shortTokens = ["go", "js", "ts", "py", "rs", "sh", "kt", "cs"]
        return shortTokens.contains { localAlpineContainsSeparatedToken(normalized, $0) }
    }

    private static func localAlpineContainsSeparatedToken(_ text: String, _ token: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])\#(escaped)(?![A-Za-z0-9_])"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func hasExplicitLocalAlpineRouteIntent(_ normalized: String) -> Bool {
        let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        let explicitTerms = [
            "iexa_alpine", "local alpine", "/mnt/iexa", "alpine 执行", "alpine运行",
            "用终端", "在终端", "终端里", "终端执行", "终端运行",
            "用命令", "命令执行", "执行命令", "运行命令", "shell", "bash",
            "terminal", "command line", "run command", "execute command"
        ]
        return explicitTerms.contains { text.contains($0) }
    }

    private static func isLocalAlpineManualRunOrRefusalResponse(_ content: String) -> Bool {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let refusalTerms = [
            "tool iexa_alpine does not exist", "tool iexa_alpine does not exists",
            "iexa_alpine does not exist", "iexa_alpine does not exists",
            "无法直接执行", "不能直接执行", "无法执行 shell", "不能执行 shell",
            "无法直接运行", "不能直接运行", "无法在 /mnt/iexa", "不能在 /mnt/iexa",
            "无法代你", "不能代你", "不能落盘", "无法落盘",
            "我无法直接执行", "我不能直接执行", "我可以模拟运行",
            "模拟运行上述", "模拟运行这段", "模拟执行上述", "模拟执行这段",
            "请手动", "手动运行", "手动执行", "复制下面", "复制以下",
            "在终端运行", "到终端运行", "运行以下命令", "执行以下命令",
            "cannot directly execute", "can't directly execute", "cannot execute shell",
            "unable to execute", "unable to run", "cannot run commands",
            "i cannot directly execute", "i can't directly execute",
            "simulate running", "simulate the output",
            "run manually", "manually run", "copy and paste", "paste into terminal"
        ]
        if refusalTerms.contains(where: { normalized.contains($0) }) {
            return true
        }
        let askUserToProvideTerms = [
            "请告诉我", "告诉我项目目录", "告诉我目录", "告诉我路径",
            "请提供项目目录", "请提供目录", "请提供路径", "需要你提供",
            "把路径发给我", "发给我路径", "requirements.txt 的位置", "pyproject.toml 的位置",
            "please tell me", "please provide", "tell me the project directory",
            "tell me the path", "provide the path", "provide the project directory"
        ]
        let localActionTerms = [
            "安装", "依赖", "运行", "执行", "修复", "检查", "项目", "目录",
            "install", "dependency", "dependencies", "run", "execute", "fix", "check",
            "project", "directory", "requirements", "pyproject"
        ]
        return askUserToProvideTerms.contains { normalized.contains($0) }
            && localActionTerms.contains { normalized.contains($0) }
    }

    private static func localAlpineUserRequestRequiresHostExecution(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if isLocalAlpineExecutionBlockedRequest(normalized) {
            return false
        }
        let intent = localAlpineIntent(forNormalized: normalized)
        switch intent {
        case .explicitLocalAlpine, .shellCommand:
            return true
        case .none:
            return false
        case .inspectLocalState, .mutateLocalState, .executeOrVerify, .setupDependency, .networkFetch, .generatedFile:
            return !isLocalAlpineExplanationOnlyRequest(normalized)
        }
    }

    private static func isLocalAlpineExecutionBlockedRequest(_ normalized: String) -> Bool {
        let blockedTerms = [
            "不要执行", "不用执行", "别执行", "先别执行", "不要运行", "不用运行", "别运行",
            "不要真的执行", "别真的执行", "不要操作", "别操作",
            "do not execute", "don't execute", "do not run", "don't run",
            "no need to run", "don't actually execute", "do not actually execute"
        ]
        return blockedTerms.contains { normalized.contains($0) }
    }

    private static func isLocalAlpineExplanationOnlyRequest(_ normalized: String) -> Bool {
        let explanationOnlyTerms = [
            "只解释", "解释一下", "讲解", "说明一下", "示例", "例子", "怎么写", "如何写",
            "只给命令", "给我命令",
            "explain", "show example", "example only", "just show", "only show",
            "just give me the command", "give me the command"
        ]
        return explanationOnlyTerms.contains { normalized.contains($0) }
    }

    private static func normalizedLocalAlpineExecutableContent(from content: String) -> String? {
        var normalizedBlocks: [Any] = []
        var shellBlocks: [String] = []
        for block in localAlpineInstructionBlocks(from: content) {
            if let data = block.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                var changed = false
                let normalized = normalizedLocalAlpineObject(object, changed: &changed)
                normalizedBlocks.append(contentsOf: localAlpineCommandObjects(fromNormalized: normalized))
                continue
            }

            let shell = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shell.isEmpty {
                shellBlocks.append(shell)
            }
        }
        if !shellBlocks.isEmpty, normalizedBlocks.isEmpty {
            return """
            ```iexa_alpine
            \(shellBlocks.joined(separator: "\n\n"))
            ```
            """
        }
        normalizedBlocks.append(contentsOf: shellBlocks.map { ["command": $0, "cwd": "/mnt/iexa"] })
        guard !normalizedBlocks.isEmpty else { return nil }

        let object: [String: Any] = ["iexa_alpine": normalizedBlocks]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return """
        ```iexa_alpine
        \(json)
        ```
        """
    }

    private static func localAlpineExecutableContent(from commands: [[String: Any]]) -> String? {
        guard !commands.isEmpty else { return nil }
        let object: [String: Any] = ["iexa_alpine": commands]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return """
        ```iexa_alpine
        \(json)
        ```
        """
    }

    private func localAlpineTaskPathCandidates(
        latestUserText: String?,
        parent: ChatMessage,
        rawResult: String,
        commandResults: [LocalAlpineAgentCommandResult],
        writtenFiles: [LocalAlpineWrittenFile]
    ) -> [String] {
        var paths: [String] = []
        if let latestUserText {
            paths.append(contentsOf: Self.localAlpinePathCandidates(in: latestUserText))
        }
        paths.append(contentsOf: writtenFiles.map(\.path))
        paths.append(contentsOf: Self.localAlpinePathCandidates(in: rawResult))
        for result in commandResults {
            paths.append(contentsOf: Self.localAlpinePathCandidates(in: result.command))
            paths.append(contentsOf: Self.localAlpinePathCandidates(in: result.outputPreview))
        }
        let messages = conversation?.messages ?? []
        for message in messages.reversed().prefix(8) where Self.isLocalAlpineAgentResult(message) || message.id == parent.id {
            let metadata = message.metadata ?? [:]
            paths.append(contentsOf: LocalAlpineWrittenFile.decodeMetadata(metadata["iexa_local_alpine_written_files"]).map(\.path))
            let results = LocalAlpineAgentCommandResult.decodeMetadata(metadata["iexa_local_alpine_command_results"])
            for result in results {
                paths.append(contentsOf: Self.localAlpinePathCandidates(in: result.command))
                paths.append(contentsOf: Self.localAlpinePathCandidates(in: result.outputPreview))
            }
            paths.append(contentsOf: Self.localAlpinePathCandidates(in: metadata["iexa_local_alpine_raw_result"] ?? ""))
        }
        return Self.localAlpineUniquePaths(paths)
    }

    private func recentLocalAlpinePathCandidates(limit: Int = 16) -> [String] {
        guard let messages = conversation?.messages else { return [] }
        var paths: [String] = []

        for message in messages.reversed()
        where Self.isLocalAlpineAgentResult(message) && !Self.isLocalAlpineProtocolCorrectionMessage(message) {
            let metadata = message.metadata ?? [:]
            paths.append(contentsOf: LocalAlpineWrittenFile.decodeMetadata(
                metadata["iexa_local_alpine_written_files"]
            ).map(\.path))
            paths.append(contentsOf: Self.localAlpinePathCandidates(
                in: metadata["iexa_local_alpine_raw_result"] ?? ""
            ))
            paths.append(contentsOf: Self.localAlpinePathCandidates(in: message.content))

            let results = LocalAlpineAgentCommandResult.decodeMetadata(
                metadata["iexa_local_alpine_command_results"]
            )
            for result in results {
                paths.append(contentsOf: Self.localAlpinePathCandidates(in: result.command))
                paths.append(contentsOf: Self.localAlpinePathCandidates(in: result.outputPreview))
            }

            let unique = Self.localAlpineUniquePaths(paths)
            if unique.count >= limit {
                return Array(unique.prefix(limit))
            }
        }

        return Array(Self.localAlpineUniquePaths(paths).prefix(limit))
    }

    private static func localAlpineSynthesizedInspectionCommands(
        userText: String,
        targetPaths: [String]
    ) -> [[String: Any]] {
        if let query = localAlpineSearchQuery(from: userText) {
            return [["grep": ["path": ".", "pattern": query, "include": "*"], "cwd": "/mnt/iexa"]]
        }
        if !targetPaths.isEmpty {
            return targetPaths.prefix(4).map {
                ["read_file": ["path": localAlpineWorkspaceRelativePath($0), "max_bytes": 120_000], "cwd": "/mnt/iexa"]
            }
        }
        return [["list_dir": ["path": ".", "max_depth": 3], "cwd": "/mnt/iexa"]]
    }

    private static func localAlpineSynthesizedBootstrapCommands(
        userText: String,
        targetPaths: [String]
    ) -> [[String: Any]] {
        var commands: [[String: Any]] = []
        if !targetPaths.isEmpty {
            if localAlpineUserRequestWantsModification(userText) {
                commands.append(contentsOf: targetPaths.prefix(3).map {
                    ["read_file": ["path": localAlpineWorkspaceRelativePath($0), "max_bytes": 160_000], "cwd": "/mnt/iexa"]
                })
            }
            commands.append(contentsOf: localAlpineVerificationCommands(
                for: targetPaths,
                latestUserText: userText,
                force: false
            ))
            if commands.isEmpty {
                commands.append(contentsOf: targetPaths.prefix(3).map {
                    ["read_file": ["path": localAlpineWorkspaceRelativePath($0), "max_bytes": 120_000], "cwd": "/mnt/iexa"]
                })
            }
            return commands
        }

        commands.append(["list_dir": ["path": ".", "max_depth": 3], "cwd": "/mnt/iexa"])
        commands.append(["command": localAlpineProjectProbeCommand(), "cwd": "/mnt/iexa"])
        return commands
    }

    private static func localAlpineCodeFenceWriteCommands(
        from text: String,
        preferredPaths: [String],
        latestUserText: String?
    ) -> [[String: Any]] {
        let fences = localAlpineCodeFences(in: text)
        guard !fences.isEmpty else { return [] }

        var commands: [[String: Any]] = []
        var usedPaths = Set<String>()
        for (index, fence) in fences.enumerated() {
            guard let path = localAlpinePathForCodeFence(
                fenceInfo: fence.info,
                language: fence.language,
                preferredPaths: preferredPaths,
                usedPaths: usedPaths,
                index: index
            ) else {
                continue
            }
            usedPaths.insert(path)
            let normalizedBody = fence.body
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard !normalizedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            commands.append([
                "write_files": [[
                    "path": localAlpineWorkspaceRelativePath(path),
                    "code_lines": normalizedBody.components(separatedBy: "\n")
                ]],
                "cwd": "/mnt/iexa"
            ])
        }

        let writtenPaths = commands.compactMap { command -> String? in
            guard let files = command["write_files"] as? [[String: Any]],
                  let path = files.first?["path"] as? String else { return nil }
            return path
        }
        commands.append(contentsOf: localAlpineVerificationCommands(
            for: writtenPaths,
            latestUserText: latestUserText,
            force: true
        ))
        return commands
    }

    private static func localAlpineCodeFences(in text: String) -> [(info: String, language: String, body: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#, options: [.caseInsensitive]) else {
            return []
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let info = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let language = info
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first
                .map { String($0).lowercased() } ?? ""
            guard !["iexa_alpine", "local_alpine_exec", "bash", "sh", "shell", "console", "terminal", "text", "txt", "plaintext", "markdown", "md", "json"].contains(language) else {
                return nil
            }
            let body = nsText.substring(with: match.range(at: 2))
            guard localAlpineLanguageExtension(language) != nil || localAlpineBodyLooksLikeCode(body) else {
                return nil
            }
            return (info, language, body)
        }
    }

    private static func localAlpinePathForCodeFence(
        fenceInfo: String,
        language: String,
        preferredPaths: [String],
        usedPaths: Set<String>,
        index: Int
    ) -> String? {
        if let path = localAlpinePathCandidates(in: fenceInfo).first(where: { !usedPaths.contains($0) }) {
            return path
        }
        if let path = preferredPaths.first(where: {
            !usedPaths.contains($0) && localAlpinePath($0, matchesLanguage: language)
        }) {
            return path
        }
        if let path = preferredPaths.first(where: { !usedPaths.contains($0) }) {
            return path
        }
        guard let ext = localAlpineLanguageExtension(language) else { return nil }
        let base = index == 0 ? "main" : "main_\(index + 1)"
        return "\(base).\(ext)"
    }

    private static func localAlpineLiteralRewriteCommands(
        from userText: String,
        preferredPaths: [String]
    ) -> [[String: Any]] {
        guard localAlpineUserRequestWantsModification(userText),
              let replacement = localAlpineLiteralReplacementBody(from: userText),
              let path = localAlpinePreferredPath(forUserText: userText, preferredPaths: preferredPaths)
        else {
            return []
        }

        let normalizedBody = replacement
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalizedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var commands: [[String: Any]] = [[
            "write_files": [[
                "path": localAlpineWorkspaceRelativePath(path),
                "code_lines": normalizedBody.components(separatedBy: "\n")
            ]],
            "cwd": "/mnt/iexa"
        ]]
        commands.append(contentsOf: localAlpineVerificationCommands(
            for: [path],
            latestUserText: userText,
            force: true
        ))
        return commands
    }

    private static func localAlpinePreferredPath(
        forUserText userText: String,
        preferredPaths: [String]
    ) -> String? {
        let paths = localAlpineUniquePaths(preferredPaths)
        guard !paths.isEmpty else { return nil }
        for language in localAlpineMentionedLanguages(in: userText) {
            if let path = paths.first(where: { localAlpinePath($0, matchesLanguage: language) }) {
                return path
            }
        }
        return paths.first
    }

    private static func localAlpineUserRequestWantsDeletion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let deleteTerms = [
            "删除", "删掉", "移除", "清理掉", "删了", "干掉",
            "delete", "remove", "unlink"
        ]
        guard deleteTerms.contains(where: { lower.contains($0) }) else { return false }
        let confirmationOnlyTerms = [
            "要不要", "是否", "可以吗", "能不能", "能否", "可不可以",
            "should i", "can i", "may i"
        ]
        return !confirmationOnlyTerms.contains { lower.contains($0) }
    }

    private static func localAlpineMentionedLanguages(in text: String) -> [String] {
        let lower = text.lowercased()
        let languageTerms: [(String, [String])] = [
            ("python", ["python", ".py", "py"]),
            ("lua", ["lua", ".lua"]),
            ("cpp", ["c++", "cpp", ".cpp", ".cc", ".cxx"]),
            ("c", ["c语言", "c 语言", ".c "]),
            ("go", ["golang", "go", ".go"]),
            ("rust", ["rust", ".rs"]),
            ("javascript", ["javascript", "node", ".js", ".mjs", ".cjs"]),
            ("typescript", ["typescript", ".ts"]),
            ("java", ["java", ".java"]),
            ("shell", ["shell", "bash", ".sh"]),
            ("ruby", ["ruby", ".rb"]),
            ("php", ["php", ".php"]),
            ("swift", ["swift", ".swift"]),
            ("csharp", ["c#", "csharp", ".cs"]),
            ("kotlin", ["kotlin", ".kt", ".kts"])
        ]
        return languageTerms.compactMap { language, terms in
            terms.contains { localAlpineLanguageTermMatches(lower, $0) } ? language : nil
        }
    }

    private static func localAlpineLanguageTermMatches(_ text: String, _ term: String) -> Bool {
        let asciiAlnum = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let scalars = term.unicodeScalars
        if term.count <= 3, scalars.allSatisfy({ asciiAlnum.contains($0) }) {
            return localAlpineContainsSeparatedToken(text, term)
        }
        return text.contains(term)
    }

    private static func localAlpineLiteralReplacementBody(from userText: String) -> String? {
        let markers = [
            "改成", "改为", "修改成", "修改为", "换成", "替换成", "替换为", "设为", "变成",
            "change to", "replace with", "set to", "make it"
        ]
        guard let range = markers.compactMap({
            userText.range(of: $0, options: [.caseInsensitive])
        }).first else {
            return nil
        }

        var body = String(userText[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。；;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let fenced = localAlpineCodeFences(in: body).first {
            return fenced.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        body = localAlpineTrimTrailingExecutionPhrase(body)
        if body.hasPrefix("`"), body.hasSuffix("`"), body.count >= 2 {
            body = String(body.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if body.range(of: #"(?i)\bhttps?://"#, options: .regularExpression) != nil,
           !localAlpineBodyLooksLikeCode(body) {
            return nil
        }
        guard body.count <= 20_000 else { return nil }
        return body.isEmpty ? nil : body
    }

    private static func localAlpineTrimTrailingExecutionPhrase(_ body: String) -> String {
        let delimiters = [
            "，并运行", " 并运行", "并运行",
            "，然后运行", " 然后运行", "然后运行",
            "，再运行", " 再运行", "再运行",
            "，并测试", " 并测试", "并测试",
            "，然后测试", " 然后测试", "然后测试",
            " and run", " then run", " and test", " then test"
        ]
        let cutIndexes = delimiters.compactMap { delimiter -> String.Index? in
            body.range(of: delimiter, options: [.caseInsensitive])?.lowerBound
        }
        guard let cutIndex = cutIndexes.min() else {
            return body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "。；;")
            ))
        }
        return String(body[..<cutIndex])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "。；;")
            ))
    }

    private static func localAlpinePath(_ path: String, matchesLanguage language: String) -> Bool {
        guard let ext = localAlpineLanguageExtension(language) else { return true }
        let lower = path.lowercased()
        if ext == "js" {
            return lower.hasSuffix(".js") || lower.hasSuffix(".mjs") || lower.hasSuffix(".cjs")
        }
        if ext == "html" {
            return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
        }
        return lower.hasSuffix(".\(ext)")
    }

    private static func localAlpineLanguageExtension(_ language: String) -> String? {
        switch language.lowercased() {
        case "python", "py":
            return "py"
        case "javascript", "js", "node":
            return "js"
        case "typescript", "ts":
            return "ts"
        case "html":
            return "html"
        case "css":
            return "css"
        case "swift":
            return "swift"
        case "lua":
            return "lua"
        case "shell", "sh", "bash", "ash":
            return "sh"
        case "json":
            return "json"
        case "yaml", "yml":
            return "yml"
        case "toml":
            return "toml"
        case "go":
            return "go"
        case "rust", "rs":
            return "rs"
        case "java":
            return "java"
        case "c":
            return "c"
        case "cpp", "c++":
            return "cpp"
        case "csharp", "c#":
            return "cs"
        case "kotlin", "kt":
            return "kt"
        default:
            return nil
        }
    }

    private static func localAlpineBodyLooksLikeCode(_ body: String) -> Bool {
        let lower = body.lowercased()
        let markers = [
            "def ", "class ", "import ", "from ", "function ", "const ", "let ", "var ",
            "print(", "console.log", "fmt.println", "#include", "public class",
            "package main", "func main", "fn main", "<html", "<!doctype"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func localAlpineVerificationCommands(
        for paths: [String],
        latestUserText: String?,
        force: Bool
    ) -> [[String: Any]] {
        let runnable = localAlpineRunnablePaths(from: paths)
        guard force || localAlpineUserRequestWantsVerification(latestUserText ?? "") else { return [] }
        return runnable.prefix(3).map {
            ["verify": ["path": localAlpineWorkspaceRelativePath($0)], "cwd": "/mnt/iexa"]
        }
    }

    private static func localAlpineRunnablePaths(from paths: [String]) -> [String] {
        localAlpineUniquePaths(paths).filter { path in
            let lower = path.lowercased()
            return lower.hasSuffix(".py")
                || lower.hasSuffix(".pyw")
                || lower.hasSuffix(".js")
                || lower.hasSuffix(".mjs")
                || lower.hasSuffix(".cjs")
                || lower.hasSuffix(".ts")
                || lower.hasSuffix(".lua")
                || lower.hasSuffix(".cpp")
                || lower.hasSuffix(".cc")
                || lower.hasSuffix(".cxx")
                || lower.hasSuffix(".c")
                || lower.hasSuffix(".sh")
                || lower.hasSuffix(".go")
                || lower.hasSuffix(".rs")
                || lower.hasSuffix(".rb")
                || lower.hasSuffix(".php")
                || lower.hasSuffix(".java")
                || lower.hasSuffix("package.json")
        }
    }

    private static func localAlpinePathCandidates(in text: String, limit: Int = 12) -> [String] {
        guard !text.isEmpty else { return [] }
        let searchableText = text.replacingOccurrences(
            of: #"(?i)\bhttps?://[^\s`"'“”‘’<>]+"#,
            with: " ",
            options: .regularExpression
        )
        let extensions = "py|pyw|js|jsx|ts|tsx|mjs|cjs|html|htm|css|scss|sass|swift|kt|kts|java|c|cc|cpp|cxx|h|hpp|cs|go|rs|rb|php|sh|bash|zsh|fish|pl|lua|r|sql|json|jsonc|jsonl|yaml|yml|toml|xml|md|txt"
        let patterns = [
            #"`([^`]+(?:\.(?:\#(extensions))|package\.json|Makefile|Dockerfile))`"#,
            #"["'“”‘’]([^"'“”‘’]+(?:\.(?:\#(extensions))|package\.json|Makefile|Dockerfile))["'“”‘’]"#,
            #"((?:/mnt/iexa/|\.{0,2}/)?[A-Za-z0-9_.@+/\-]+?\.(?:\#(extensions)))"#,
            #"((?:/mnt/iexa/|\.{0,2}/)?[A-Za-z0-9_.@+/\-]*(?:package\.json|Makefile|Dockerfile))"#
        ]
        var paths: [String] = []
        let nsText = searchableText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: searchableText, range: fullRange) where match.numberOfRanges >= 2 {
                let candidate = nsText.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'“”‘’，。；：、）)]}")))
                guard !candidate.isEmpty,
                      !candidate.contains("://"),
                      !candidate.hasPrefix("http"),
                      localAlpinePathLooksUseful(candidate) else {
                    continue
                }
                paths.append(candidate)
                if paths.count >= limit { return localAlpineUniquePaths(paths) }
            }
        }
        return localAlpineUniquePaths(paths)
    }

    private static func localAlpinePathLooksUseful(_ path: String) -> Bool {
        let lower = path.lowercased()
        let ignoredFragments = [
            "/usr/lib/python", "/usr/local/lib/python", "/site-packages/", "/dist-packages/",
            ".iexa_failed_writes/", ".iexa-write-", ".iexa-terminal-scripts/"
        ]
        return !ignoredFragments.contains { lower.contains($0) }
    }

    private static func localAlpineUniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let normalized = path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            guard !normalized.isEmpty else { continue }
            let key = normalized.hasPrefix("./") ? String(normalized.dropFirst(2)) : normalized
            guard seen.insert(key.lowercased()).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func localAlpineSearchQuery(from text: String) -> String? {
        extractWorkspaceSearchQuery(from: text)
    }

    private static func localAlpineUserRequestWantsModification(_ text: String) -> Bool {
        let lower = text.lowercased()
        let terms = [
            "修改", "改成", "改一下", "编辑", "修复", "修一下", "优化", "完善",
            "新增", "补齐", "替换", "删除", "重写", "保存", "写入",
            "modify", "edit", "fix", "repair", "optimize", "complete", "improve",
            "replace", "rewrite", "save", "write"
        ]
        return terms.contains { lower.contains($0) }
    }

    private static func localAlpineUserRequestWantsVerification(_ text: String) -> Bool {
        let lower = text.lowercased()
        let terms = [
            "运行", "执行", "跑", "测试", "验证", "编译", "构建", "重新运行",
            "run", "execute", "test", "verify", "compile", "build", "rerun"
        ]
        return terms.contains { lower.contains($0) }
    }

    private static func localAlpineDependencyRepairCommand(from output: String) -> String? {
        let lower = output.lowercased()
        if let module = firstRegexCapture(in: output, pattern: #"No module named ['"]([^'"]+)['"]"#)
            ?? firstRegexCapture(in: output, pattern: #"ModuleNotFoundError:\s*No module named ['"]([^'"]+)['"]"#) {
            let package = localAlpinePythonPackageName(forModule: module)
            return """
            command -v pip3 >/dev/null 2>&1 || apk add --no-cache py3-pip
            python3 -m pip install --break-system-packages --no-cache-dir \(localAlpineShellQuote(package)) || python3 -m pip install --no-cache-dir \(localAlpineShellQuote(package))
            """
        }
        if let missingCommand = firstRegexCapture(in: lower, pattern: #"(?:^|\n)\s*([a-z0-9_+.-]+):\s+not found"#)
            ?? firstRegexCapture(in: lower, pattern: #"command not found:?\s*([a-z0-9_+.-]+)"#),
           let package = localAlpineApkPackageName(forCommand: missingCommand) {
            return "apk add --no-cache \(package)"
        }
        return nil
    }

    private static func localAlpinePythonPackageName(forModule module: String) -> String {
        let normalized = module.split(separator: ".").first.map(String.init) ?? module
        switch normalized.lowercased() {
        case "bs4":
            return "beautifulsoup4"
        case "pil":
            return "pillow"
        case "cv2":
            return "opencv-python-headless"
        case "yaml":
            return "pyyaml"
        case "dotenv":
            return "python-dotenv"
        case "sklearn":
            return "scikit-learn"
        default:
            return normalized
        }
    }

    private static func localAlpineApkPackageName(forCommand command: String) -> String? {
        switch command.lowercased() {
        case "bash":
            return "bash"
        case "curl":
            return "curl"
        case "wget":
            return "wget"
        case "git":
            return "git"
        case "node":
            return "nodejs npm"
        case "npm", "npx":
            return "npm"
        case "python", "python3":
            return "python3 py3-pip"
        case "pip", "pip3":
            return "py3-pip"
        case "gcc", "g++", "make":
            return "build-base"
        default:
            return nil
        }
    }

    private static func localAlpineProjectProbeCommand() -> String {
        """
        printf '== pwd ==\\n' && pwd
        printf '\\n== candidate source files ==\\n'
        find . -maxdepth 4 -type f \\( -name '*.py' -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.html' -o -name '*.css' -o -name 'package.json' -o -name 'requirements.txt' -o -name 'pyproject.toml' \\) 2>/dev/null | sort | sed -n '1,160p'
        first=$(find . -maxdepth 4 -type f \\( -name '*.py' -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.html' \\) 2>/dev/null | sort | head -n 1)
        if [ -n "$first" ]; then
          printf '\\n== preview: %s ==\\n' "$first"
          sed -n '1,220p' "$first"
        fi
        """
    }

    private static func localAlpineNumberedPreviewCommand(for path: String) -> String {
        "printf '== numbered preview: %s ==\\n' \(localAlpineShellQuote(path)) && nl -ba \(localAlpineShellQuote(path)) | sed -n '1,240p'"
    }

    private static func localAlpineFailureDiagnosticCommand() -> String {
        """
        printf '== workspace ==\\n' && pwd && find . -maxdepth 3 -type f | sort | sed -n '1,160p'
        printf '\\n== dependency files ==\\n'
        for f in requirements.txt pyproject.toml package.json Makefile; do [ -f "$f" ] && { printf '\\n-- %s --\\n' "$f"; sed -n '1,180p' "$f"; }; done
        """
    }

    private static func localAlpineCommandObjects(fromNormalized object: Any) -> [Any] {
        if let dict = object as? [String: Any] {
            let nestedKeys = [
                "iexa_alpine",
                "local_alpine_exec",
                "tool_calls",
                "toolCalls",
                "function_call",
                "functionCall",
                "tool_use",
                "toolUse",
                "tool_call",
                "toolCall",
                "calls",
                "commands"
            ]
            for key in nestedKeys {
                if let nested = dict[key] {
                    return localAlpineCommandObjects(fromNormalized: nested)
                }
            }
        }
        if let array = object as? [Any] {
            return array.flatMap { localAlpineCommandObjects(fromNormalized: $0) }
        }
        return [object]
    }

    private static func normalizedLocalAlpineObject(
        _ object: Any,
        changed: inout Bool,
        compatibleToolEnvelope: Bool = false
    ) -> Any {
        if let array = object as? [Any] {
            return array.map {
                normalizedLocalAlpineObject(
                    $0,
                    changed: &changed,
                    compatibleToolEnvelope: compatibleToolEnvelope
                )
            }
        }

        guard var dict = object as? [String: Any] else { return object }
        let currentIsCompatibleEnvelope = compatibleToolEnvelope
            || localAlpineObjectLooksLikeCompatibleToolEnvelope(dict)
        for key in Array(dict.keys) {
            if let value = dict[key] {
                dict[key] = normalizedLocalAlpineObject(
                    value,
                    changed: &changed,
                    compatibleToolEnvelope: currentIsCompatibleEnvelope
                        || localAlpineCompatibleToolEnvelopeKey(key)
                )
            }
        }
        return normalizedPythonWriteFilePayload(
            in: dict,
            changed: &changed,
            compatibleToolEnvelope: currentIsCompatibleEnvelope
        )
    }

    private static func normalizedPythonWriteFilePayload(
        in dict: [String: Any],
        changed: inout Bool,
        compatibleToolEnvelope: Bool
    ) -> [String: Any] {
        guard let path = localAlpineWriteFilePath(from: dict),
              path.lowercased().hasSuffix(".py"),
              !hasStructuredLocalAlpinePayload(dict),
              let plainContent = plainLocalAlpineContent(from: dict) else {
            return dict
        }

        var updated = dict
        ["content", "contents", "text", "body", "code"].forEach {
            updated.removeValue(forKey: $0)
        }
        if compatibleToolEnvelope {
            let normalized = plainContent
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            updated["code_lines"] = normalized.components(separatedBy: "\n")
        } else {
            updated["iexa_rejected_python_plain_content"] = true
        }
        changed = true
        return updated
    }

    private static func localAlpineCompatibleToolEnvelopeKey(_ key: String) -> Bool {
        switch key {
        case "tool_calls", "toolCalls", "calls",
             "function_call", "functionCall",
             "tool_use", "toolUse",
             "tool_call", "toolCall":
            return true
        default:
            return false
        }
    }

    private static func localAlpineObjectLooksLikeCompatibleToolEnvelope(_ dict: [String: Any]) -> Bool {
        if let type = (dict["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased(),
           ["tooluse", "tool_use", "toolcall", "tool_call", "function_call", "function"].contains(type) {
            return true
        }
        if dict["function"] is [String: Any],
           (dict["name"] != nil || dict["tool"] != nil || dict["tool_name"] != nil || dict["toolName"] != nil) {
            return true
        }
        if let toolName = localAlpineCompatibleToolName(in: dict),
           localAlpineCompatibleToolNameLooksStructured(toolName) {
            return true
        }
        return false
    }

    private static func localAlpineCompatibleToolName(in dict: [String: Any]) -> String? {
        let keys = [
            "name", "tool", "action", "operation", "op",
            "toolName", "tool_name", "functionName", "function_name",
        ]
        for key in keys {
            guard let value = dict[key] as? String else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func localAlpineCompatibleToolNameLooksStructured(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return [
            "bash", "shell", "sh", "exec", "run", "command", "shell_execute",
            "read", "read_file", "read_files", "cat", "open_file", "file_read",
            "write", "write_file", "write_files", "create_file", "create_files", "save_file", "save_files", "file_write",
            "edit", "edit_file", "edit_files", "replace_file",
            "patch", "patch_file", "patch_files", "apply_patch",
            "delete", "delete_file", "delete_files", "remove_file", "remove_files", "delete_dir", "remove_dir", "rm", "rmdir", "file_delete",
            "list", "list_dir", "list_directory", "ls", "file_list", "directory_list",
            "grep", "search", "search_files", "file_search",
            "append", "append_file", "append_and_read",
            "move_file", "rename_file", "copy_file", "mkdir",
            "glob", "find", "find_files",
            "verify", "check",
            "browser_use", "browser", "browse", "web_fetch", "fetch_url", "open_url"
        ].contains(normalized)
    }

    private static func localAlpineWriteFilePath(from dict: [String: Any]) -> String? {
        ((dict["path"] as? String)
            ?? (dict["file_path"] as? String)
            ?? (dict["file"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["filename"] as? String)
            ?? (dict["write_file"] as? String)
            ?? (dict["target"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasStructuredLocalAlpinePayload(_ dict: [String: Any]) -> Bool {
        dict["code_lines"] != nil
            || dict["content_lines"] != nil
            || dict["lines"] != nil
            || dict["content_base64"] != nil
            || dict["base64"] != nil
    }

    private static func plainLocalAlpineContent(from dict: [String: Any]) -> String? {
        (dict["content"] as? String)
            ?? (dict["contents"] as? String)
            ?? (dict["text"] as? String)
            ?? (dict["body"] as? String)
            ?? (dict["code"] as? String)
    }

    private static func firstURL(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: fullRange) else { return nil }
        return nsText.substring(with: match.range)
    }

    private static func shouldSendRawTextDirectlyToLocalAlpine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("\n") {
            return shouldAutoRouteRawShellTextToLocalAlpine(trimmed)
        }
        return isShellLikeCommandLine(trimmed)
    }

    private static func shouldAutoRouteRawShellTextToLocalAlpine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let nonEmptyLines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !nonEmptyLines.isEmpty else { return false }
        return nonEmptyLines.allSatisfy { Self.isShellLikeCommandLine($0) }
    }

    private static func isShellLikeCommandLine(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("$ ") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("sudo ") {
            trimmed = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("/") { return true }
        if ["then", "else", "do", "done", "fi", "esac", "}", "{"].contains(trimmed) { return true }

        let words = trimmed.split(separator: " ").map(String.init)
        guard let firstCommand = words.first(where: { word in
            word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*"#, options: .regularExpression) == nil
        }) else {
            return false
        }
        let command = firstCommand.trimmingCharacters(in: CharacterSet(charactersIn: "(){}"))
        let shellControlCommands: Set<String> = [
            "if", "elif", "else", "then", "fi", "for", "while", "until", "do", "done", "case", "esac"
        ]
        return shellControlCommands.contains(command) || isKnownLocalAlpineShellCommand(command)
    }

    private static func localAlpineShellCommandIsInspectionOnly(_ text: String) -> Bool {
        let singleLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty, !singleLine.contains("\n") else { return false }
        var commandLine = singleLine
        if commandLine.hasPrefix("$ ") {
            commandLine = String(commandLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if commandLine.hasPrefix("sudo ") {
            commandLine = String(commandLine.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard isShellLikeCommandLine(commandLine) else { return false }
        if commandLine.contains(">") || commandLine.contains(">>") {
            return false
        }
        let words = commandLine.split(separator: " ").map(String.init)
        guard let firstCommand = words.first(where: { word in
            word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*"#, options: .regularExpression) == nil
        }) else {
            return false
        }
        let command = firstCommand.trimmingCharacters(in: CharacterSet(charactersIn: "(){}"))
        let inspectionCommands: Set<String> = [
            "cat", "date", "df", "du", "env", "find", "free", "grep", "head",
            "id", "ls", "pwd", "rg", "sed", "tail", "uname", "wc", "whoami"
        ]
        return inspectionCommands.contains(command)
    }

    private static func isKnownLocalAlpineShellCommand(_ command: String) -> Bool {
        let knownCommands: Set<String> = [
            "apk", "ash", "sh", "bash", "cat", "cd", "chmod", "chown", "command", "cp", "date",
            "curl", "df", "du", "echo", "env", "find", "free", "gcc", "g++", "git", "grep", "head",
            "id", "java", "javac", "go", "cargo", "rustc", "ls", "lua", "make", "cmake", "mkdir",
            "mv", "node", "npm", "npx", "perl", "php", "pip", "pip3", "printf", "ps", "pwd",
            "python", "python3", "rm", "rmdir", "ruby", "sed", "sleep", "tail", "tar", "test",
            "top", "touch", "type", "uname", "unset", "vi", "vim", "wget", "which", "whoami"
        ]
        return knownCommands.contains(command)
    }

    private func sendDirectLocalAlpineCommand(_ rawCommand: String, modelId: String) async {
        let command = Self.normalizedLocalAlpineCommand(rawCommand)
        guard !command.isEmpty else { return }
        resetLocalAlpineAgentLoopForNewTurn()
        localAlpineAgentStopRequested = true
        let displayCommand = rawCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\$\s+"#, with: "", options: .regularExpression)

        inputText = ""
        attachments = []
        errorMessage = nil

        let userMessage = ChatMessage(
            role: .user,
            content: displayCommand.isEmpty ? command : displayCommand,
            timestamp: .now
        )
        let assistantMessageId = UUID().uuidString
        let userMessageParentId = conversation?.messages.last(where: {
            !Self.isLocalWorkspaceAgentResult($0) && !Self.isLocalAlpineAgentResult($0)
        })?.id

        if conversation == nil {
            let chatTitle = Self.initialConversationTitle(from: userMessage.content, fallback: "本地命令")
            conversation = Conversation(
                id: isTemporaryChat ? "local:\(UUID().uuidString)" : UUID().uuidString,
                title: chatTitle,
                model: modelId,
                messages: [userMessage]
            )
            if let pending = pendingChatParams {
                conversation?.chatParams = pending
                pendingChatParams = nil
            }
            if isOpenAICompatibleProvider, let id = conversation?.id {
                activeChatStore?.promoteNewChat(to: id)
            }
            NotificationService.shared.activeConversationId = conversation?.id
        } else {
            conversation?.messages.append(userMessage)
        }

        let initialStatus = localAlpineInitialStatus(for: command)
        conversation?.messages.append(ChatMessage(
            id: assistantMessageId,
            role: .assistant,
            content: "",
            timestamp: .now,
            model: "Local Alpine",
            isStreaming: true,
            statusHistory: [initialStatus],
            metadata: [
                "iexa_local_alpine_direct": "true",
                "iexa_local_alpine_result": "true",
                "iexa_local_alpine_command_preview": command,
                "iexa_local_alpine_display_command": userMessage.content,
                "iexa_local_alpine_cwd": "/mnt/iexa"
            ]
        ))
        localAlpineAgentExecutedMessageIds.insert(assistantMessageId)

        let userHistoryNode = HistoryNode(
            id: userMessage.id,
            parentId: userMessageParentId,
            childrenIds: [assistantMessageId],
            role: .user,
            content: userMessage.content,
            timestamp: userMessage.timestamp,
            models: [modelId]
        )
        let assistantHistoryNode = HistoryNode(
            id: assistantMessageId,
            parentId: userMessage.id,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: userMessage.timestamp,
            model: "Local Alpine",
            done: false,
            statusHistory: [initialStatus]
        )
        conversation?.history.nodes[userMessage.id] = userHistoryNode
        conversation?.history.nodes[assistantMessageId] = assistantHistoryNode
        if let pid = userMessageParentId {
            conversation?.history.appendChildId(userMessage.id, to: pid)
        }
        conversation?.history.currentId = assistantMessageId

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        beginStreamingBackgroundTaskIfNeeded()
        await startLocalAlpineLiveActivity(
            id: assistantMessageId,
            command: command,
            detail: initialStatus.description ?? localAlpineRunningDescription(for: command)
        )
        let progressHeartbeat = startLocalAlpineProgressHeartbeat(
            messageId: assistantMessageId,
            command: command
        )
        defer { progressHeartbeat.cancel() }

        let directToolRunId = UUID().uuidString
        let directToolCallId = UUID().uuidString
        let directToolDisplay = LocalAlpineToolDisplayRegistry.display(for: "command")
        let directStartedAtMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let directToolDetail = Self.localAlpineCommandPreview(from: command)
        let directStartCall = LocalAlpineToolCall(
            id: directToolCallId,
            runId: directToolRunId,
            name: "command",
            phase: .start,
            title: directToolDisplay.title,
            detail: directToolDetail,
            cwd: "/mnt/iexa",
            command: command,
            exitCode: nil,
            outputPreview: nil,
            filePaths: [],
            startedAtMs: directStartedAtMs,
            completedAtMs: nil,
            failed: false
        )
        applyLocalAlpineToolEvent(
            LocalAlpineToolEvent(runId: directToolRunId, call: directStartCall),
            messageId: assistantMessageId
        )

        var result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: "/mnt/iexa")
        while let request = result.interactiveRequest {
            updateAssistantMessage(
                id: assistantMessageId,
                content: formatDirectLocalAlpineOutput(command: userMessage.content, result: result),
                isStreaming: true,
                statusHistory: [localAlpineStatus(description: "等待输入以继续执行...", done: false)]
            )

            guard let stdinInput = await requestLocalAlpineInput(request) else {
                break
            }

            updateAssistantMessage(
                id: assistantMessageId,
                content: "已收到输入，正在继续执行...",
                isStreaming: true,
                statusHistory: [localAlpineStatus(description: "已收到输入，继续执行...", done: false)]
            )
            result = await LocalAlpineTerminalService.shared.execute(
                command: request.command,
                cwd: request.cwd,
                stdinInput: stdinInput
            )
        }
        let output = formatDirectLocalAlpineOutput(command: userMessage.content, result: result)
        let doneDescription: String
        if result.interactiveRequest != nil {
            doneDescription = "本地输入已取消"
        } else if result.exitCode == 0 {
            doneDescription = "本地命令已完成"
        } else {
            doneDescription = "本地命令已结束，退出码 \(result.exitCode.map(String.init) ?? "unknown")"
        }
        updateAssistantMessage(
            id: assistantMessageId,
            content: output,
            isStreaming: false,
            statusHistory: [localAlpineStatus(description: doneDescription, done: true)]
        )
        let directCommandResult = LocalAlpineAgentCommandResult(
            command: command,
            cwd: "/mnt/iexa",
            exitCode: result.exitCode,
            outputPreview: String(result.output.prefix(8_000))
        )
        let directCompletedAtMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let directToolCall = LocalAlpineToolCall(
            id: directToolCallId,
            runId: directToolRunId,
            name: "command",
            phase: .result,
            title: directToolDisplay.title,
            detail: directToolDetail,
            cwd: "/mnt/iexa",
            command: command,
            exitCode: result.exitCode,
            outputPreview: String(result.output.prefix(4_000)),
            filePaths: [],
            startedAtMs: directStartedAtMs,
            completedAtMs: directCompletedAtMs,
            failed: result.exitCode != 0 || result.interactiveRequest != nil
        )
        applyLocalAlpineToolEvent(
            LocalAlpineToolEvent(runId: directToolRunId, call: directToolCall),
            messageId: assistantMessageId
        )
        if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
            var metadata = conversation?.messages[index].metadata ?? [:]
            conversation?.messages[index].isStreaming = false
            metadata["iexa_local_alpine_raw_result"] = result.output
            metadata["iexa_local_alpine_tool_run_id"] = directToolRunId
            if let toolCalls = LocalAlpineToolCall.metadataString(for: [directToolCall]) {
                metadata["iexa_local_alpine_tool_calls"] = toolCalls
            }
            if let commandResults = LocalAlpineAgentCommandResult.metadataString(for: [directCommandResult]) {
                metadata["iexa_local_alpine_command_results"] = commandResults
            }
            conversation?.messages[index].metadata = metadata
        }
        let resultMetadata = conversation?.messages.first(where: { $0.id == assistantMessageId })?.metadata
        conversation?.history.updateNode(id: assistantMessageId) { node in
            node.content = output
            node.done = true
            node.statusHistory = [localAlpineStatus(description: doneDescription, done: true)]
            node.metadata = resultMetadata
        }

        hasFinishedStreaming = true
        isStreaming = false
        selfInitiatedStream = false
        clearLocalAlpineLiveToolState(for: assistantMessageId)
        activeTaskId = nil
        lastTaskExtractionLength = 0

        await persistLocalConversationIfNeeded()
        endBackgroundTask()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

        if result.interactiveRequest == nil {
            localAlpineAgentStopRequested = false
            if !scheduleLocalAlpineFinalSummary(after: assistantMessageId) {
                localAlpineAgentStopRequested = true
                localAlpineContinuationTask = nil
            }
        } else {
            localAlpineAgentStopRequested = true
            localAlpineContinuationTask = nil
        }
    }

    private func sendDirectLocalAlpineAgentBlock(
        userText: String,
        executableContent: String,
        modelId: String
    ) async {
        resetLocalAlpineAgentLoopForNewTurn()
        localAlpineAgentStopRequested = false
        localAlpineAutoExecutionPaused = false

        inputText = ""
        attachments = []
        errorMessage = nil

        let userMessage = ChatMessage(
            role: .user,
            content: userText.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: .now
        )
        let userMessageParentId = conversation?.messages.last(where: {
            !Self.isLocalWorkspaceAgentResult($0) && !Self.isLocalAlpineAgentResult($0)
        })?.id

        if conversation == nil {
            let title = Self.initialConversationTitle(from: userMessage.content, fallback: "运行代码")
            conversation = Conversation(
                id: isTemporaryChat ? "local:\(UUID().uuidString)" : UUID().uuidString,
                title: title,
                model: modelId,
                messages: [userMessage]
            )
            if let pending = pendingChatParams {
                conversation?.chatParams = pending
                pendingChatParams = nil
            }
            if isOpenAICompatibleProvider, let id = conversation?.id {
                activeChatStore?.promoteNewChat(to: id)
            }
            NotificationService.shared.activeConversationId = conversation?.id
        } else {
            conversation?.messages.append(userMessage)
        }

        let userHistoryNode = HistoryNode(
            id: userMessage.id,
            parentId: userMessageParentId,
            childrenIds: [],
            role: .user,
            content: userMessage.content,
            timestamp: userMessage.timestamp,
            models: [modelId]
        )
        conversation?.history.nodes[userMessage.id] = userHistoryNode
        if let pid = userMessageParentId {
            conversation?.history.appendChildId(userMessage.id, to: pid)
        }
        conversation?.history.currentId = userMessage.id

        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        await executeLocalAlpineAgent(messageId: userMessage.id, content: executableContent)
    }

    private func localAlpineInitialStatus(for command: String) -> ChatStatusUpdate {
        localAlpineStatus(description: localAlpineRunningDescription(for: command), done: false)
    }

    private func localAlpineRunningDescription(for command: String) -> String {
        let lowercased = command.lowercased()
        if lowercased.contains("\"write_files\"")
            || lowercased.contains("\"write_file\"")
            || lowercased.contains("\"files\"") {
            return "正在写入文件并执行..."
        }
        if lowercased.contains("cat >")
            || lowercased.contains("tee ")
            || lowercased.contains("<<'") {
            return "正在用命令行写入文件并执行..."
        }
        if lowercased.contains("apk add ")
            || lowercased.contains("apk upgrade")
            || lowercased.contains("apk fix") {
            return "正在安装本地软件包..."
        }
        if lowercased.contains("apk update") {
            return "正在更新本地软件源..."
        }
        if shouldLocalAlpineCheckDependencies(for: lowercased) {
            return "正在确认本地环境并执行命令..."
        }
        return "正在执行本地命令..."
    }

    private func localAlpineCompletedDescription(for result: LocalAlpineAgentResult) -> String {
        var parts: [String] = []
        if result.editedFileCount > 0 {
            parts.append("已编辑 \(result.editedFileCount) 个文件")
        }
        if result.executedCommandCount > 0 {
            parts.append("已运行 \(result.executedCommandCount) 条命令")
        }
        if parts.isEmpty {
            parts.append("本地任务已完成")
        }
        if result.hadFailure {
            parts.append("有错误")
        }
        return parts.joined(separator: "  ")
    }

    private func shouldLocalAlpineCheckDependencies(for lowercasedCommand: String) -> Bool {
        [
            "python3", "python ", ".py", "pip ",
            "node ", "node\n", "npm ", ".js",
            "gcc", "g++", " cc ", "make ", "cmake", ".c ", ".cpp",
            "vim ", "vi ", "curl ", "git ", "bash "
        ].contains { lowercasedCommand.contains($0) }
    }

    private func localAlpineStatus(description: String, done: Bool) -> ChatStatusUpdate {
        ChatStatusUpdate(
            action: "local_alpine",
            description: description,
            done: done,
            occurredAt: .now
        )
    }

    private func localAlpineStatusHistory(messageId: String, appending status: ChatStatusUpdate) -> [ChatStatusUpdate] {
        var existing = conversation?.messages.first(where: { $0.id == messageId })?.statusHistory ?? []
        if existing.last?.description == status.description && existing.last?.done == status.done {
            existing[existing.count - 1] = status
        } else {
            existing.append(status)
        }
        return existing
    }

    private func startLocalAlpineProgressHeartbeat(
        messageId: String,
        command: String,
        startedAt: Date = .now
    ) -> Task<Void, Never> {
        Task { [weak self] in
            var tick = 0
            let maxHeartbeatDuration: TimeInterval = 300
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { break }
                let elapsed = Date().timeIntervalSince(startedAt)
                guard elapsed <= maxHeartbeatDuration else { break }
                await MainActor.run {
                    guard let self,
                          let index = self.conversation?.messages.firstIndex(where: { $0.id == messageId }),
                          self.conversation?.messages[index].isStreaming == true else { return }
                    tick += 1
                    let description = self.localAlpineHeartbeatDescription(
                        command: command,
                        elapsed: elapsed,
                        tick: tick
                    )
                    let status = self.localAlpineStatus(description: description, done: false)
                    let history = self.localAlpineStatusHistory(messageId: messageId, appending: status)
                    self.conversation?.messages[index].statusHistory = history
                    self.conversation?.history.updateNode(id: messageId) { node in
                        node.statusHistory = history
                    }
                }
            }
        }
    }

    private func localAlpineHeartbeatDescription(command: String, elapsed: TimeInterval, tick: Int) -> String {
        let lowercased = command.lowercased()
        let seconds = max(1, Int(elapsed.rounded()))
        if lowercased.contains("apk add") || lowercased.contains("pip install") || lowercased.contains("npm install") {
            return "正在安装依赖，已运行 \(seconds) 秒..."
        }
        if lowercased.contains("apk ") || lowercased.contains("pip ") || lowercased.contains("npm ") {
            return "正在处理软件包，已运行 \(seconds) 秒..."
        }
        if shouldLocalAlpineCheckDependencies(for: lowercased) {
            return "正在执行命令，已运行 \(seconds) 秒..."
        }
        return tick.isMultiple(of: 2)
            ? "命令仍在运行，已运行 \(seconds) 秒..."
            : "正在等待本地结果，已运行 \(seconds) 秒..."
    }

    private func requestLocalAlpineInput(_ request: LocalAlpineInteractiveRequest) async -> String? {
        localAlpineInputContinuation?.resume(returning: nil)
        localAlpineInputContinuation = nil
        localAlpineInputText = request.defaultValue
        localAlpineInputRequest = request
        return await withCheckedContinuation { continuation in
            localAlpineInputContinuation = continuation
        }
    }

    func submitLocalAlpineInput(_ input: String) {
        guard let continuation = localAlpineInputContinuation else {
            localAlpineInputRequest = nil
            localAlpineInputText = ""
            return
        }
        localAlpineInputContinuation = nil
        localAlpineInputRequest = nil
        localAlpineInputText = ""
        continuation.resume(returning: input)
    }

    func cancelLocalAlpineInput() {
        guard let continuation = localAlpineInputContinuation else {
            localAlpineInputRequest = nil
            localAlpineInputText = ""
            return
        }
        localAlpineInputContinuation = nil
        localAlpineInputRequest = nil
        localAlpineInputText = ""
        continuation.resume(returning: nil)
    }

    private func resetLocalAlpineAgentLoopForNewTurn() {
        localAlpineAgentTask?.cancel()
        localAlpineAgentTask = nil
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = nil
        localAlpineContinuationWatchdogTask?.cancel()
        localAlpineContinuationWatchdogTask = nil
        cancelLocalAlpineInput()
        localAlpineAgentStopRequested = false
        localAlpineAutoExecutionPaused = false
        localAlpineFailedCommands.removeAll()
        localAlpineCompletedCommands.removeAll()
        localAlpineExecutedExecutableFingerprints.removeAll()
        localAlpineNativeToolExecutedMessageIds.removeAll()
        localAlpineFailureSignatures.removeAll()
        localAlpineNoProgressSignatures.removeAll()
        localAlpineBlockedRepeatCommands.removeAll()
        localAlpineFinalSummaryParentIds.removeAll()
        localAlpineContinuationParentIds.removeAll()
        localAlpineFinishedContinuationMessageIds.removeAll()
        localAlpineContinuationRetryCounts.removeAll()
        localAlpineMissingToolCorrectionParentIds.removeAll()
        clearAllLocalAlpineLiveToolState()
    }

    private func cancelLocalAlpineAgentLoop() {
        localAlpineAgentStopRequested = true
        localAlpineAutoExecutionPaused = true
        localAlpineAgentTask?.cancel()
        localAlpineAgentTask = nil
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = nil
        localAlpineContinuationWatchdogTask?.cancel()
        localAlpineContinuationWatchdogTask = nil
        cancelLocalAlpineInput()
        localAlpineContinuationParentIds.removeAll()
        localAlpineContinuationRetryCounts.removeAll()
        localAlpineMissingToolCorrectionParentIds.removeAll()
        clearAllLocalAlpineLiveToolState()
    }

    private func pauseLocalAlpineAgentLoopForUserInterjection() {
        localAlpineAgentStopRequested = true
        localAlpineAutoExecutionPaused = true
        localAlpineAgentTask?.cancel()
        localAlpineAgentTask = nil
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = nil
        localAlpineContinuationWatchdogTask?.cancel()
        localAlpineContinuationWatchdogTask = nil
        cancelLocalAlpineInput()
        localAlpineContinuationParentIds.removeAll()
        localAlpineContinuationRetryCounts.removeAll()
        localAlpineMissingToolCorrectionParentIds.removeAll()
        clearAllLocalAlpineLiveToolState()
    }

    private func formatDirectLocalAlpineOutput(command: String, result: LocalAlpineCommandResult) -> String {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "（无输出）"
            : result.output
        let exit = result.exitCode.map(String.init) ?? "unknown"
        return """
        Local Alpine 执行结果

        命令

        ```bash
        \(command)
        ```

        退出码：`\(exit)`

        输出

        ```text
        \(output)
        ```
        """
    }

    private static func normalizedLocalAlpineCommand(_ rawCommand: String) -> String {
        var command = rawCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\$\s+"#, with: "", options: .regularExpression)
        let lowercased = command.lowercased()
        for prefix in [
            "帮我执行一下", "帮我运行一下", "帮我执行", "帮我运行",
            "帮我在终端执行", "帮我在终端运行", "在终端执行", "在终端运行",
            "用终端执行", "用终端运行", "在alpine执行", "在 alpine 执行",
            "执行命令：", "执行命令:", "运行命令：", "运行命令:",
            "执行命令 ", "运行命令 ", "执行#", "执行：", "执行:", "执行 ",
            "运行#", "运行：", "运行:", "运行 ",
            "run command:", "run command ", "execute command:", "execute command ",
            "run:", "execute:"
        ] where lowercased.hasPrefix(prefix) {
            let candidate = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldSendRawTextDirectlyToLocalAlpine(candidate) {
                command = candidate
            }
            break
        }
        return command
    }

    private static func localAlpineDiagnosticCommand(for lowercasedText: String) -> String? {
        let trimmed = lowercasedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnosticIntents = [
            "检查当前环境", "检测当前环境", "测试当前环境", "检查环境", "检测环境", "测试环境",
            "检查沙盒环境", "检测沙盒环境", "测试沙盒环境", "帮我测试一下当前沙盒环境",
            "帮我测试当前沙盒环境", "当前环境", "沙盒环境", "alpine环境", "alpine 环境"
        ]
        if isIPDiagnosticRequest(trimmed) {
            return """
            printf '== local interfaces ==\\n'
            (ip -o -4 addr show 2>/dev/null || ifconfig 2>/dev/null || hostname -I 2>/dev/null || true)
            printf '\\n== default route ==\\n'
            (ip route 2>/dev/null || route -n 2>/dev/null || true)
            printf '\\n== public ip ==\\n'
            (curl -fsS https://api.ipify.org 2>/dev/null || wget -qO- https://api.ipify.org 2>/dev/null || true)
            printf '\\n'
            """
        }
        guard diagnosticIntents.contains(where: { trimmed.contains($0) }) else { return nil }
        return """
        printf '== system ==\\n' && cat /etc/alpine-release 2>/dev/null && uname -a && id && pwd && printf '\\n== workspace ==\\n' && ls -la /mnt/iexa 2>/dev/null && printf '\\n== dns ==\\n' && cat /etc/resolv.conf 2>/dev/null && printf '\\n== tools ==\\n' && for x in sh ash busybox apk wget curl python3 node npm gcc g++ git vim; do printf '%-8s: ' "$x"; command -v "$x" || echo missing; done
        """
    }

    private static func isIPDiagnosticRequest(_ text: String) -> Bool {
        let mentionsIP = text.contains("ip")
            || text.contains("公网")
            || text.contains("本机地址")
            || text.contains("网络地址")
            || text.contains("出口地址")
        let asksToInspect = text.contains("查看")
            || text.contains("查询")
            || text.contains("检查")
            || text.contains("查一下")
            || text.contains("查下")
            || text.contains("看一下")
            || text.contains("看看")
        return mentionsIP && asksToInspect
    }

    private func startIndependentDirectMediaGeneration(
        assistantMessageId: String,
        modelId: String,
        modelPromptText: String,
        messageText: String,
        currentAttachments: [ChatAttachment],
        manager: ConversationManager
    ) {
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        beginStreamingBackgroundTaskIfNeeded()

        if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
            var metadata = conversation?.messages[index].metadata ?? [:]
            metadata["iexa_direct_media_generation"] = "true"
            metadata["iexa_image_generation_placeholder"] = "true"
            conversation?.messages[index].metadata = metadata
            conversation?.history.updateNode(id: assistantMessageId) { node in
                node.metadata = metadata
            }
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.startRunLiveActivity(id: assistantMessageId, modelId: modelId, prompt: modelPromptText)
            do {
                if self.shouldUseDirectVideoGeneration(modelId: modelId) {
                    try Task.checkCancellation()
                    let videoPrompt = modelPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !videoPrompt.isEmpty else {
                        throw APIError.unknown(
                            underlying: NSError(
                                domain: "ChatViewModel",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "请输入视频生成提示词。"]
                            )
                        )
                    }
                    let requestedVideoSize = Self.requestedImageSize(from: videoPrompt)
                    let videoSeedImage = self.firstEditableImage(from: currentAttachments)
                    await RunLiveActivityService.shared.update(
                        id: assistantMessageId,
                        title: "正在生成视频",
                        detail: videoPrompt,
                        phase: "生成",
                        progress: 0.35,
                        isIndeterminate: true,
                        force: true
                    )
                    let videoReference = try await self.runMediaRequestWithRetry {
                        try await manager.generateVideo(
                            prompt: videoPrompt,
                            model: modelId,
                            size: requestedVideoSize,
                            duration: Self.requestedVideoDuration(from: videoPrompt),
                            imageData: videoSeedImage?.data,
                            imageFileName: videoSeedImage?.fileName ?? "image.png"
                        )
                    }
                    try Task.checkCancellation()
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "已生成视频",
                        isStreaming: false
                    )
                    self.attachGeneratedVideoFile(
                        messageId: assistantMessageId,
                        videoReference: videoReference
                    )
                    self.recordTokenUsageForCompletedTurn(
                        assistantMessageId: assistantMessageId,
                        userText: messageText,
                        assistantText: "已生成视频",
                        userAttachments: currentAttachments,
                        mediaKind: .video,
                        mediaCount: 1
                    )
                    await self.persistLocalConversationIfNeeded()
                    await self.sendCompletionNotificationIfNeeded(content: "已生成视频")
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                    self.finishDirectMediaGenerationTask(messageId: assistantMessageId)
                    return
                }

                try Task.checkCancellation()
                guard self.currentProviderType != .anthropic else {
                    throw APIError.unknown(
                        underlying: NSError(
                            domain: "ChatViewModel",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Claude/Anthropic 不提供图片生成端点。"]
                        )
                    )
                }
                let imagePrompt = modelPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                let requestedImageCount = Self.requestedImageCount(from: imagePrompt)
                let requestedCanvasSize = Self.requestedImageCanvasSize(from: imagePrompt)
                let requestedImageSize = Self.imageEndpointSize(for: requestedCanvasSize)
                let editImages = self.editableImages(from: currentAttachments)
                let imagePromptForAPI = Self.promptWithImageSizeInstruction(
                    imagePrompt.isEmpty
                        ? (editImages.count > 1 ? "Use all attached images as references and combine or edit them according to the user's request." : "Edit this image.")
                        : imagePrompt,
                    canvasSize: requestedCanvasSize,
                    endpointSize: requestedImageSize
                )
                let imagePrompts = Self.imageVariantPrompts(
                    basePrompt: imagePromptForAPI,
                    requestedCount: requestedImageCount
                )
                await RunLiveActivityService.shared.update(
                    id: assistantMessageId,
                    title: "正在创建图片",
                    detail: requestedImageCount > 1
                        ? "正在生成 \(requestedImageCount) 张不同图片"
                        : (imagePrompt.isEmpty ? "正在编辑图片" : imagePrompt),
                    phase: "生成",
                    progress: 0.35,
                    isIndeterminate: true,
                    force: true
                )
                let generatedImageSlots = try await self.generateDirectImageSlots(
                    prompts: imagePrompts,
                    modelId: modelId,
                    requestedImageSize: requestedImageSize,
                    requestedCanvasSize: requestedCanvasSize,
                    editImages: editImages,
                    manager: manager,
                    originalPromptWasEmpty: imagePrompt.isEmpty
                )
                try Task.checkCancellation()
                if generatedImageSlots.isEmpty {
                    throw APIError.unknown(
                        underlying: NSError(
                            domain: "ChatViewModel",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "没有成功生成图片。"]
                        )
                    )
                }
                self.updateAssistantMessage(
                    id: assistantMessageId,
                    content: "",
                    isStreaming: false
                )
                for (slotIndex, slot) in generatedImageSlots.enumerated() {
                    switch slot {
                    case .image(let imageReference, let displayReference):
                        self.attachGeneratedImageFile(
                            messageId: assistantMessageId,
                            imageReference: imageReference,
                            displayReference: displayReference
                        )
                    case .failure:
                        self.attachGeneratedImageFailurePlaceholder(
                            messageId: assistantMessageId,
                            index: slotIndex + 1
                        )
                    }
                }
                self.recordTokenUsageForCompletedTurn(
                    assistantMessageId: assistantMessageId,
                    userText: messageText,
                    assistantText: "",
                    userAttachments: currentAttachments,
                    mediaKind: .image,
                    mediaCount: max(generatedImageSlots.count, 1)
                )
                await self.persistLocalConversationIfNeeded()
                await self.sendCompletionNotificationIfNeeded(content: "图片生成已结束")
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                self.finishDirectMediaGenerationTask(messageId: assistantMessageId)
            } catch {
                guard !Task.isCancelled else {
                    self.finishDirectMediaGenerationTask(messageId: assistantMessageId)
                    return
                }
                self.updateAssistantMessage(
                    id: assistantMessageId,
                    content: "",
                    isStreaming: false,
                    error: ChatMessageError(content: Self.localizedGenerationError(error))
                )
                await self.persistLocalConversationIfNeeded()
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                self.finishDirectMediaGenerationTask(messageId: assistantMessageId)
            }
        }
        registerDirectMediaGenerationTask(task, messageId: assistantMessageId)
    }

    /// Stops the current streaming response by cancelling the server-side task
    /// via `/api/tasks/stop/{taskId}` and cleaning up local state.
    func stopStreaming() {
        if stopLatestDirectMediaGenerationTask() {
            return
        }

        cancelLocalAlpineAgentLoop()

        // Cancel the local HTTP task
        streamingTask?.cancel()
        streamingTask = nil

        // Stop the server-side task.
        // For self-initiated streams we already have the task_id from the HTTP POST response.
        // For externally-initiated streams (another device/browser) activeTaskId is nil,
        // so we query /api/tasks/chat/{chat_id} to discover and stop all active tasks.
        let chatId = conversationId ?? conversation?.id
        if let taskId = activeTaskId, let apiClient = manager?.apiClient {
            Task {
                try? await apiClient.stopTask(taskId: taskId)
                logger.info("Server task stopped: \(taskId)")
            }
        } else if let chatId, let apiClient = manager?.apiClient {
            Task {
                do {
                    let taskIds = try await apiClient.getTasksForChat(chatId: chatId)
                    for taskId in taskIds {
                        try? await apiClient.stopTask(taskId: taskId)
                        logger.info("External server task stopped: \(taskId)")
                    }
                } catch {
                    logger.warning("Failed to fetch tasks for chat \(chatId): \(error.localizedDescription)")
                }
            }
        }

        // Flush streaming store content back to conversation.messages
        // before cleanup so the partial content is preserved for server sync.
        if streamingStore.isActive, let msgId = streamingStore.streamingMessageId,
           let idx = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
            let result = streamingStore.abortStreaming()
            conversation?.messages[idx].content = result.content
            conversation?.messages[idx].isStreaming = false
            if !result.statusHistory.isEmpty {
                conversation?.messages[idx].statusHistory = result.statusHistory
            }
            if !result.sources.isEmpty {
                conversation?.messages[idx].sources = result.sources
            }
            // Also write partial content into the history tree node so that
            // when regenerateResponse() later calls rederiveMessages() (which
            // rebuilds the flat list FROM the tree), the stopped version
            // retains its partial content instead of showing empty.
            conversation?.history.updateNode(id: msgId) { node in
                node.content = result.content
                if !result.statusHistory.isEmpty {
                    node.statusHistory = result.statusHistory
                }
                if !result.sources.isEmpty {
                    node.sources = result.sources
                }
            }
        } else if let idx = conversation?.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            conversation?.messages[idx].isStreaming = false
        }

        cleanupStreaming()

        // Sync partial content to server so the chat isn't blank.
        // Use tree-based sync so the history node (with partial content) is
        // what gets persisted — this ensures version switching works correctly.
        Task {
            await self.syncToServerViaTree()
        }
    }

    @discardableResult
    private func stopLatestDirectMediaGenerationTask() -> Bool {
        while let messageId = directMediaGenerationTaskOrder.last {
            directMediaGenerationTaskOrder.removeLast()
            guard let task = directMediaGenerationTasks.removeValue(forKey: messageId) else {
                continue
            }
            task.cancel()
            markDirectMediaGenerationStopped(messageId: messageId)
            return true
        }
        return false
    }

    private func registerDirectMediaGenerationTask(_ task: Task<Void, Never>, messageId: String) {
        directMediaGenerationTasks[messageId]?.cancel()
        directMediaGenerationTasks[messageId] = task
        directMediaGenerationTaskOrder.removeAll { $0 == messageId }
        directMediaGenerationTaskOrder.append(messageId)
    }

    private func finishDirectMediaGenerationTask(messageId: String) {
        directMediaGenerationTasks.removeValue(forKey: messageId)
        directMediaGenerationTaskOrder.removeAll { $0 == messageId }
        if directMediaGenerationTasks.isEmpty {
            isStreaming = false
            hasFinishedStreaming = true
            selfInitiatedStream = false
            activeTaskId = nil
            endBackgroundTask()
        }
    }

    private func markDirectMediaGenerationStopped(messageId: String) {
        let status = ChatStatusUpdate(
            action: "image_generation",
            description: "已停止生成",
            done: true,
            occurredAt: .now
        )
        updateAssistantMessage(
            id: messageId,
            content: "",
            isStreaming: false,
            statusHistory: [status],
            error: ChatMessageError(content: "已停止生成")
        )
        conversation?.history.updateNode(id: messageId) { node in
            node.done = true
            node.statusHistory = [status]
        }
        finishDirectMediaGenerationTask(messageId: messageId)
        Task { await persistLocalConversationIfNeeded() }
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    /// Regenerates the last assistant response. Convenience wrapper
    /// around ``regenerateResponse(messageId:)`` for the most common case.
    func regenerateLastResponse() async {
        guard let lastAssistant = conversation?.messages.last(where: { $0.role == .assistant }) else { return }
        await regenerateResponse(messageId: lastAssistant.id)
    }

    /// Regenerates a specific assistant response by its message ID.
    ///
    /// If the targeted message is NOT the last assistant message, all messages
    /// after it are removed first (truncating the conversation to that point),
    /// matching the Iexa native server web client's regeneration behavior for mid-conversation
    /// messages.
    func regenerateResponse(messageId: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation != nil else { return }

        // ── Tree-first regeneration (replicates Iexa native server exactly) ──────────
        // 1. Look up the old assistant node in the history tree.
        //    If the tree isn't populated yet, bootstrap it from the flat list.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }
        guard let oldNode = conversation!.history.nodes[messageId], oldNode.role == .assistant else { return }

        // 2. The parent of the old assistant node (the user message).
        guard let parentId = oldNode.parentId else {
            // Root-level assistant with no parent — can't regenerate without a user message
            return
        }

        // 3. Create a NEW assistant placeholder node (new UUID) as a sibling of the old one.
        //    Both are children of the same user node.
        let newAssistantId = UUID().uuidString
        let modelId = selectedModelId ?? conversation?.model ?? ""
        let newAssistantNode = HistoryNode(
            id: newAssistantId,
            parentId: parentId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: .now,
            model: modelId,
            done: false
        )
        conversation!.history.nodes[newAssistantId] = newAssistantNode

        // 4. Add the new assistant as a child of the user node (sibling to old assistant).
        if conversation!.history.nodes[parentId] != nil {
            if !conversation!.history.nodes[parentId]!.childrenIds.contains(newAssistantId) {
                conversation!.history.nodes[parentId]!.childrenIds.append(newAssistantId)
            }
        }

        // 5. Update currentId to the new assistant.
        conversation!.history.currentId = newAssistantId

        // 6. Re-derive the flat messages list from the tree.
        conversation!.rederiveMessages()
        if let newAssistantIndex = conversation?.messages.firstIndex(where: { $0.id == newAssistantId }) {
            conversation?.messages[newAssistantIndex].isStreaming = true
        }

        // Reset the task list — the new regen branch starts with no tasks.
        tasks = []
        conversation?.tasks = []

        // 7. Sync to server via tree-based API before streaming.
        await syncToServerViaTree()

        // 8. Get the user message (parentId) for the API messages build.
        guard conversation?.messages.contains(where: { $0.role == .user }) == true else { return }
        guard let userNode = conversation!.history.nodes[parentId] else { return }
        let apiMessages = await buildAPIMessagesAsync()
        appendContextCompressionStatusIfNeeded(to: newAssistantId)
        let effectiveChatId = conversationId ?? conversation?.id
        sessionId = UUID().uuidString

        // Reset streaming state
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true

        // Activate the isolated streaming store for the regenerated message
        streamingStore.beginStreaming(messageId: newAssistantId, modelId: modelId)
        appendContextCompressionStatusIfNeeded(to: newAssistantId)

        // Cancel any previous subscriptions/timers
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        if isOpenAICompatibleProvider {
            let capturedNewAssistantId = newAssistantId
            let capturedUserNode = userNode

            streamingTask = Task { [weak self] in
                guard let self, let manager = self.manager else { return }
                let acc = ContentAccumulator()
                var exactUsage: [String: Any]?

                do {
                    var request = ChatCompletionRequest(model: modelId, messages: apiMessages, stream: true)
                    await self.populateCommonRequestFields(&request)
                    let sseStream = try await manager.sendPreferredOpenAIStreaming(
                        request: request
                    )

                    for try await event in sseStream {
                        if Task.isCancelled { break }

                        if let usage = event.usage, !usage.isEmpty {
                            exactUsage = usage
                        }

                        self.applyStreamingEventDelta(
                            event,
                            to: acc,
                            assistantMessageId: capturedNewAssistantId
                        )

                        if event.isFinished { break }
                    }
                } catch {
                    if !Task.isCancelled {
                        self.updateAssistantMessage(
                            id: capturedNewAssistantId,
                            content: acc.content,
                            isStreaming: false,
                            error: ChatMessageError(content: Self.localizedGenerationError(error))
                        )
                        self.cleanupStreaming()
                        await self.persistLocalConversationIfNeeded()
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                    }
                    return
                }

                if Task.isCancelled { return }

                acc.markReasoningDone()
                if acc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.updateAssistantMessage(
                        id: capturedNewAssistantId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: "未收到模型回复或图片数据，请重试。")
                    )
                    self.cleanupStreaming()
                    await self.persistLocalConversationIfNeeded()
                    return
                }

                self.updateAssistantMessage(id: capturedNewAssistantId, content: acc.content, isStreaming: false)
                self.normalizeAssistantGeneratedMedia(messageId: capturedNewAssistantId)
                let normalizedContent = self.conversation?.messages
                    .first(where: { $0.id == capturedNewAssistantId })?.content ?? acc.content
                self.applyUsage(exactUsage, toMessageId: capturedNewAssistantId)
                self.recordTokenUsageForCompletedTurn(
                    assistantMessageId: capturedNewAssistantId,
                    userText: capturedUserNode.content,
                    assistantText: normalizedContent,
                    userAttachments: [],
                    usage: exactUsage
                )
                self.hasFinishedStreaming = true
                self.isStreaming = false
                self.selfInitiatedStream = false
                self.activeTaskId = nil
                self.lastTaskExtractionLength = 0
                await self.persistLocalConversationIfNeeded()
                await self.sendCompletionNotificationIfNeeded(content: normalizedContent)
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            }
            return
        }

        let socket = socketService
        var socketConnected = socket?.isConnected ?? false

        if let socket, !socketConnected {
            appendStatusUpdate(id: newAssistantId,
                status: ChatStatusUpdate(action: "reconnecting", description: "Reconnecting to server...", done: false))

            for (attempt, timeout) in [(1, 5.0), (2, 8.0), (3, 12.0)] as [(Int, TimeInterval)] {
                socketConnected = await socket.ensureConnected(timeout: timeout)
                if socketConnected { break }
                logger.warning("Regenerate socket connect attempt \(attempt) failed, retrying...")
            }

            appendStatusUpdate(id: newAssistantId,
                status: ChatStatusUpdate(
                    action: "reconnecting",
                    description: socketConnected ? "Connected" : "Using direct connection",
                    done: true
                ))
        }

        let usePollingFallback = !socketConnected
        let socketSessionId = socket?.sid ?? sessionId

        if socketConnected, let socket {
            registerSocketHandlers(
                socket: socket, assistantMessageId: newAssistantId,
                modelId: modelId, socketSessionId: socketSessionId,
                effectiveChatId: effectiveChatId)
        }

        let capturedNewAssistantId = newAssistantId
        let capturedParentId = parentId
        let capturedUserNode = userNode
        let capturedUsePollingFallback = usePollingFallback

        streamingTask = Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: capturedNewAssistantId, parentId: capturedParentId)

                // Build the user_message node for the server's history tree.
                // childrenIds = all children of the user node (includes old + new assistant).
                let allChildrenIds = self.conversation?.history.nodes[capturedParentId]?.childrenIds ?? [capturedNewAssistantId]
                let userGrandParentId = capturedUserNode.parentId
                let userMsgDict: [String: Any] = [
                    "id": capturedParentId,
                    "parentId": (userGrandParentId as Any?) ?? NSNull(),
                    "childrenIds": allChildrenIds,
                    "role": "user",
                    "content": capturedUserNode.content,
                    "timestamp": Int(capturedUserNode.timestamp.timeIntervalSince1970),
                    "models": capturedUserNode.models.isEmpty ? [modelId] : capturedUserNode.models
                ]
                request.userMessage = userMsgDict

                // Populate all common request fields
                await self.populateCommonRequestFields(&request)

                if capturedUsePollingFallback {
                    self.logger.info("Regenerate: using HTTP + polling fallback (no socket)")
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                        self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: detail))
                        self.cleanupStreaming()
                        return
                    }
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    await self.pollRegeneratedAssistantUntilStable(
                        assistantMessageId: capturedNewAssistantId,
                        modelId: modelId,
                        socketSessionId: socketSessionId,
                        effectiveChatId: effectiveChatId
                    )
                } else if request.isPipeModel {
                    // ── PIPE MODEL SSE PATH (regeneration) ──
                    self.logger.info("Regenerate: using pipe model SSE path for \(modelId)")
                    let acc = ContentAccumulator()
                    var exactUsage: [String: Any]?

                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }
                            if let usage = event.usage, !usage.isEmpty {
                                exactUsage = usage
                            }
                            self.applyStreamingEventDelta(
                                event,
                                to: acc,
                                assistantMessageId: capturedNewAssistantId
                            )
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(
                                id: capturedNewAssistantId,
                                content: acc.content.isEmpty ? "" : acc.content,
                                isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription))
                            self.cleanupStreaming()
                            return
                        }
                    }

                    if Task.isCancelled { return }

                    self.finishStreamingSuccessfully(
                        assistantMessageId: capturedNewAssistantId,
                        modelId: modelId,
                        socketSessionId: socketSessionId,
                        effectiveChatId: effectiveChatId,
                        acc: acc,
                        usage: exactUsage
                    )
                } else {
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }

                    // Capture the server's task_id for server-side stop
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    self.logger.info("Regenerate HTTP POST done – waiting for socket events")
                    self.startRecoveryTimer(assistantMessageId: capturedNewAssistantId, chatId: effectiveChatId)
                }
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                 isStreaming: false,
                                                 error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
        refreshContextBudgetStatus()
        activeChatStore?.updateLastSelectedModel(modelId)
        // Switching models is a deliberate user action — reset disabled tools
        // so the new model's defaults apply cleanly without stale overrides.
        userDisabledToolIds = []
        userDisabledBuiltinFeatures = []
        syncUIWithModelDefaults()
        conversation?.model = modelId
        // Fetch full model config from single-model endpoint to get params.function_calling,
        // toolIds, defaultFeatureIds, and capabilities — which /api/models doesn't return.
        // Store the task so sendMessage/regenerate can await it if the user sends
        // before this completes.
        modelConfigTask?.cancel()
        modelConfigTask = Task { [weak self] in
            await self?.refreshSelectedModelConfig()
        }
    }

    // MARK: - Edit & Delete Messages

    /// Edits a user message by creating a proper new branch.
    ///
    /// This matches Iexa native server's tree model exactly:
    /// - The OLD user message becomes a "version" (sibling node) storing its content,
    ///   the old assistant response, any regeneration versions on that assistant,
    ///   and ALL downstream messages (messages after the user+assistant pair).
    /// - A NEW assistant message is created with a NEW UUID (not reused) so that
    ///   the WebUI tree has distinct nodes for each branch.
    /// - The current flat list is updated to show: existing messages up to and
    ///   including the (mutated) user message + new assistant placeholder.
    ///
    /// This ensures:
    /// - AI version indicators only show on their own branch's assistant
    /// - WebUI can navigate branches (each branch has unique assistant IDs)
    /// - Switching back to an old branch restores all downstream messages
    func editMessage(id: String, newContent: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation != nil else { return }

        // ── Tree-first edit (replicates Iexa native server exactly) ─────────────────
        // 1. Look up the old user node in the history tree.
        //    If the tree isn't populated yet, bootstrap it from the flat list.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }
        guard let oldNode = conversation!.history.nodes[id], oldNode.role == .user else { return }

        // 2. The parent of the old user node (an assistant node, or nil for root).
        let parentId = oldNode.parentId

        // 3. Create a NEW user node (new UUID) with the edited content.
        //    This is a sibling of the old user node under the same parent.
        let newUserId = UUID().uuidString
        let newUserNode = HistoryNode(
            id: newUserId,
            parentId: parentId,
            childrenIds: [],   // will get the assistant ID below
            role: .user,
            content: newContent,
            timestamp: .now,
            files: oldNode.files,
            models: oldNode.models
        )
        conversation!.history.nodes[newUserId] = newUserNode

        // 4. Add the new user node as a child of the parent (if parent exists).
        if let pid = parentId {
            if conversation!.history.nodes[pid] != nil {
                if !(conversation!.history.nodes[pid]!.childrenIds.contains(newUserId)) {
                    conversation!.history.nodes[pid]!.childrenIds.append(newUserId)
                }
            }
        }
        // For root-level user edits (parentId == nil), both nodes are root siblings.
        // The server treats all null-parentId nodes as root siblings automatically.

        // 5. Create a NEW assistant placeholder node.
        let newAssistantId = UUID().uuidString
        let assistantModel = selectedModelId ?? conversation?.model ?? ""
        let newAssistantNode = HistoryNode(
            id: newAssistantId,
            parentId: newUserId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: .now,
            model: assistantModel,
            done: false
        )
        conversation!.history.nodes[newAssistantId] = newAssistantNode

        // 6. Wire the assistant as a child of the new user node.
        conversation!.history.nodes[newUserId]!.childrenIds.append(newAssistantId)

        // 7. Update currentId to the new assistant (deepest leaf of the new branch).
        conversation!.history.currentId = newAssistantId

        // 8. Re-derive the flat messages list from the tree.
        conversation!.rederiveMessages()

        // Reset the task list — the new edit branch starts fresh.
        tasks = []
        conversation?.tasks = []

        // 9. Sync to server via tree-based API (lossless, no buildChatPayload).
        await syncToServerViaTree()

        // 10. Stream the AI response into the new assistant placeholder.
        await regenerateIntoExistingMessage(assistantMessageId: newAssistantId)
    }

    /// Restores an old user message branch by switching `history.currentId` to the
    /// selected sibling's deepest leaf, then re-deriving the flat message list from
    /// the tree. Matches Iexa native server's `showMessage()` function exactly.
    ///
    /// - Parameters:
    ///   - userMessageId: The ID of the user message currently on the active branch.
    ///   - version: The sibling version to switch to (nil = latest / `userMessageId` itself).
    func restoreUserVersion(userMessageId: String, version: ChatMessageVersion?) {
        guard conversation != nil else { return }

        // Determine the target user node to switch to.
        // `version.id` is the sibling user node the user wants to view.
        // nil means "go back to the current/latest user node".
        let targetUserId = version?.id ?? userMessageId

        // Ensure the tree is populated.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        // Walk to the deepest leaf of the target user node's branch and set currentId.
        let leaf = conversation!.history.deepestLeaf(from: targetUserId)
        conversation!.history.currentId = leaf

        // Re-derive the flat message list from the new active branch.
        conversation!.rederiveMessages()

        // Navigation-only: use syncCurrentIdToServer to avoid corrupting tree order.
        Task { await syncCurrentIdToServer() }
    }

    /// Navigates to a specific assistant regeneration version by switching
    /// `history.currentId` to the selected sibling's deepest leaf, then
    /// re-deriving the flat message list from the tree.
    ///
    /// Matches Iexa native server's `showMessage()` function: change currentId, re-derive.
    ///
    /// - Parameters:
    ///   - assistantMessageId: The ID of the assistant message currently active.
    ///   - versionIndex: -1 = stay on current (`assistantMessageId`), 0...N-1 = sibling version
    func restoreAssistantVersion(assistantMessageId: String, versionIndex: Int) {
        guard conversation != nil else { return }

        // Ensure the tree is populated.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        // Determine the target assistant node ID.
        // versionIndex == -1: stay on the current node (assistantMessageId).
        // versionIndex >= 0: switch to that sibling from message.versions[].id
        let targetAssistantId: String
        if versionIndex >= 0,
           let msgIdx = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }),
           versionIndex < (conversation?.messages[msgIdx].versions.count ?? 0) {
            targetAssistantId = conversation!.messages[msgIdx].versions[versionIndex].id
        } else {
            targetAssistantId = assistantMessageId
        }

        // Walk to the deepest leaf of the target assistant node's branch and set currentId.
        let leaf = conversation!.history.deepestLeaf(from: targetAssistantId)
        conversation!.history.currentId = leaf

        // Re-derive the flat message list from the new active branch.
        conversation!.rederiveMessages()

        // Navigation-only: use syncCurrentIdToServer to avoid corrupting tree order.
        Task { await syncCurrentIdToServer() }
    }

    /// Navigates to a specific assistant version by its sibling node ID directly.
    ///
    /// This is the preferred navigation method for the UI ← → version arrows.
    /// Unlike `restoreAssistantVersion(versionIndex:)`, this does NOT depend on
    /// `message.versions[]` index arithmetic — it works correctly regardless of
    /// which sibling is currently the "main" message (i.e. after any branch switch
    /// that rebuilds the flat message list via `rederiveMessages()`).
    ///
    /// - Parameters:
    ///   - targetSiblingId: The ID of the sibling assistant node to switch to.
    func restoreAssistantVersionById(targetSiblingId: String) {
        guard conversation != nil else { return }

        // Ensure the tree is populated.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        // Walk to the deepest leaf of the target node and set currentId.
        let leaf = conversation!.history.deepestLeaf(from: targetSiblingId)
        conversation!.history.currentId = leaf

        // Re-derive the flat message list from the new active branch.
        conversation!.rederiveMessages()

        // Sync ONLY currentId to server — do NOT call syncFlatMessagesToTreeNodes()
        // first. Version switching is navigation-only: no content changed, so copying
        // the flat list back into tree nodes would risk corrupting inactive-branch nodes.
        Task { await syncCurrentIdToServer() }
    }

    /// Navigates to a specific user version by its sibling node ID directly.
    ///
    /// This is the preferred navigation method for the UI user ← → version arrows.
    /// Unlike `restoreUserVersion(version:)`, this always switches to the target
    /// regardless of which sibling is currently the main message.
    ///
    /// - Parameters:
    ///   - targetSiblingId: The ID of the sibling user node to switch to.
    func restoreUserVersionById(targetSiblingId: String) {
        guard conversation != nil else { return }

        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        let leaf = conversation!.history.deepestLeaf(from: targetSiblingId)
        conversation!.history.currentId = leaf
        conversation!.rederiveMessages()

        // Same as restoreAssistantVersionById — navigation only, skip flat→tree copy.
        Task { await syncCurrentIdToServer() }
    }

    /// Sends the full history tree to the server WITHOUT first copying the flat
    /// message list back into tree nodes.
    ///
    /// Used exclusively by version-switch operations (restoreAssistantVersionById /
    /// restoreUserVersionById) where only `currentId` changed and all tree node
    /// content/childrenIds are already correct from the original server data.
    /// Calling syncFlatMessagesToTreeNodes() in these cases risks overwriting
    /// metadata on inactive-branch nodes with stale/empty flat-list data,
    /// which can cause the server to reorder childrenIds.
    private func syncCurrentIdToServer() async {
        guard let manager else { return }

        guard let conv = conversation, conv.history.isPopulated else {
            return
        }

        try? await manager.syncConversationHistory(conv)
    }

    /// Regenerates content for an existing assistant message placeholder.
    /// Called after `editMessage()` when the assistant message already exists in the list.
    private func regenerateIntoExistingMessage(assistantMessageId: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation?.messages.contains(where: { $0.id == assistantMessageId && $0.role == .assistant }) == true else { return }

        let modelId = selectedModelId ?? conversation?.model ?? ""
        guard let lastUser = conversation?.messages.last(where: { $0.role == .user }) else { return }

        let apiMessages = await buildAPIMessagesAsync()
        appendContextCompressionStatusIfNeeded(to: assistantMessageId)
        let parentId = lastUser.id
        let effectiveChatId = conversationId ?? conversation?.id

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true

        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)
        appendContextCompressionStatusIfNeeded(to: assistantMessageId)

        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        guard let socket = socketService else {
            updateAssistantMessage(id: assistantMessageId, content: "No connection available.",
                                   isStreaming: false, error: ChatMessageError(content: "No socket"))
            isStreaming = false
            return
        }
        if !socket.isConnected {
            let ok = await socket.ensureConnected(timeout: 10.0)
            if !ok {
                updateAssistantMessage(id: assistantMessageId, content: "Unable to connect.",
                    isStreaming: false, error: ChatMessageError(content: "Connection failed"))
                isStreaming = false
                return
            }
        }

        sessionId = UUID().uuidString
        let socketSessionId = socket.sid ?? sessionId

        // Sync the full tree (not just the active branch flat-list) so the original
        // branch's assistant node is preserved on the server.
        await syncToServerViaTree()

        registerSocketHandlers(
            socket: socket, assistantMessageId: assistantMessageId,
            modelId: modelId, socketSessionId: socketSessionId,
            effectiveChatId: effectiveChatId)

        streamingTask = Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: assistantMessageId, parentId: parentId)

                // Build the user_message node for the server's history tree.
                // For edit-regeneration, the user message already exists on the server.
                let editUserParentId: String? = {
                    guard let idx = self.conversation?.messages.firstIndex(where: { $0.id == lastUser.id }),
                          idx > 0 else { return nil }
                    return self.conversation?.messages[idx - 1].id
                }()
                let editUserMsgDict: [String: Any] = [
                    "id": lastUser.id,
                    "parentId": (editUserParentId as Any?) ?? NSNull(),
                    // Send ALL children from the tree, not just the new assistant.
                    // This preserves all existing regeneration siblings on the server.
                    "childrenIds": self.conversation?.history.nodes[lastUser.id]?.childrenIds ?? [assistantMessageId],
                    "role": "user",
                    "content": lastUser.content,
                    "timestamp": Int(lastUser.timestamp.timeIntervalSince1970),
                    "models": [modelId]
                ]
                request.userMessage = editUserMsgDict

                // Populate all common request fields (model metadata, features, params,
                // system variables, tool IDs, terminal, background tasks, etc.)
                await self.populateCommonRequestFields(&request)

                if request.isPipeModel {
                    let acc = ContentAccumulator()
                    var exactUsage: [String: Any]?
                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }
                            if let usage = event.usage, !usage.isEmpty {
                                exactUsage = usage
                            }
                            self.applyStreamingEventDelta(
                                event,
                                to: acc,
                                assistantMessageId: assistantMessageId
                            )
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription))
                            self.cleanupStreaming()
                            return
                        }
                    }
                    if Task.isCancelled { return }
                    self.finishStreamingSuccessfully(assistantMessageId: assistantMessageId, modelId: modelId,
                        socketSessionId: socketSessionId, effectiveChatId: effectiveChatId, acc: acc, usage: exactUsage)
                } else {
                    let json = try await manager.sendMessageHTTP(request: request)
                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                            error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let taskId = json["task_id"] as? String { self.activeTaskId = taskId }
                    self.logger.info("Edit-regen HTTP POST done – waiting for socket events")
                }
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                        error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    /// Deletes a specific message (and its entire descendant subtree) from the
    /// conversation tree. Matches Iexa native server's tree-based `deleteMessage()`:
    ///
    /// 1. Remove the node from its parent's `childrenIds`
    /// 2. Remove the node and all descendants from `history.nodes`
    /// 3. Navigate to the deepest leaf of the parent node (or any remaining root)
    /// 4. Re-derive the flat message list from the updated tree
    /// 5. Sync to server via the tree-based API
    ///
    /// The `activeVersionIndex` parameter is kept for call-site compatibility
    /// but is no longer used — versions are sibling nodes in the tree, so
    /// deleting "the active version" just means removing the node we're currently on.
    func deleteMessage(id: String, activeVersionIndex: Int? = nil) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation != nil else { return }

        // Ensure tree is populated
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        guard conversation!.history.nodes[id] != nil else { return }
        let parentId = conversation!.history.nodes[id]!.parentId

        // Remove the node and its entire subtree (also cleans up parent's childrenIds)
        conversation!.history.removeSubtree(rootId: id)

        // Recalculate the active branch pointer
        if let parentId, conversation!.history.nodes[parentId] != nil {
            // Navigate into parent's remaining children (if any), or stay on parent
            conversation!.history.currentId = conversation!.history.deepestLeaf(from: parentId)
        } else if let anyRoot = conversation!.history.nodes.values
            .filter({ $0.parentId == nil })
            .sorted(by: { $0.timestamp < $1.timestamp })
            .first {
            // No parent — find any remaining root node
            conversation!.history.currentId = conversation!.history.deepestLeaf(from: anyRoot.id)
        } else {
            // Tree is now empty
            conversation!.history.currentId = nil
        }

        // Re-derive the flat message list from the updated tree
        conversation!.rederiveMessages()

        // Sync tree to server
        await syncToServerViaTree()

        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    // MARK: - WebSocket Event Handlers

    private func registerSocketHandlers(
        socket: SocketIOService,
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?
    ) {
        chatSubscription?.dispose()
        channelSubscription?.dispose()
        let acc = ContentAccumulator()

        // Wire up the immediate UI update callback.
        // The accumulator coalesces concurrent token arrivals into a single
        // pending MainActor Task — preventing main actor flooding while still
        // delivering each token as fast as Swift's task scheduler allows.
        let msgId = assistantMessageId
        acc.onUpdate = { [weak self] content in
            // Guard: if streaming already finished (done:true processed),
            // ignore late-arriving accumulated content dispatches.
            guard let self, !self.hasFinishedStreaming else { return }
            self.socketHasReceivedContent = true
            self.updateAssistantMessage(id: msgId, content: content, isStreaming: true)
        }

        chatSubscription = socket.addChatEventHandler(
            conversationId: effectiveChatId,
            sessionId: socketSessionId
        ) { [weak self] event, ack in
            guard let self else { return }
            // Fast-path: check if this is a content delta we can handle
            // entirely through the throttled accumulator WITHOUT scheduling
            // a @MainActor task per token.
            let data = event["data"] as? [String: Any] ?? event
            let type = data["type"] as? String
            if type == "chat:message:delta" || type == "message" || type == "event:message:delta" {
                let payload = data["data"] as? [String: Any] ?? data
                var didAppend = false
                if let reasoning = Self.reasoningDelta(from: payload) {
                    acc.appendReasoning(reasoning)
                    didAppend = true
                }
                let content = payload["content"] as? String ?? ""
                if !content.isEmpty {
                    // Append directly — the accumulator dispatches to
                    // the main actor immediately on every token.
                    acc.append(content)
                    didAppend = true
                }
                if didAppend {
                    return
                }
            }
            // For all other event types, dispatch to main actor normally
            Task { @MainActor in
                self.handleChatEvent(
                    event, ack: ack, assistantMessageId: assistantMessageId,
                    modelId: modelId, socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId, acc: acc)
            }
        }

        channelSubscription = socket.addChannelEventHandler(
            conversationId: effectiveChatId,
            sessionId: socketSessionId
        ) { [weak self] event, _ in
            guard let self else { return }
            // Fast-path for channel content deltas
            let data = event["data"] as? [String: Any] ?? event
            let type = data["type"] as? String
            let payload = data["data"] as? [String: Any] ?? data
            if type == "message" {
                var didAppend = false
                if let reasoning = Self.reasoningDelta(from: payload) {
                    acc.appendReasoning(reasoning)
                    didAppend = true
                }
                if let content = payload["content"] as? String, !content.isEmpty {
                    acc.append(content)
                    didAppend = true
                }
                if didAppend {
                    return
                }
            }
            Task { @MainActor in
                self.handleChannelEvent(event, assistantMessageId: assistantMessageId, acc: acc)
            }
        }
    }

    @discardableResult
    private func applyStreamingEventDelta(
        _ event: SSEEvent,
        to acc: ContentAccumulator,
        assistantMessageId: String
    ) -> Bool {
        var didUpdate = false

        if let reasoning = event.reasoningDelta,
           !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            acc.appendReasoning(reasoning)
            didUpdate = true
        }

        if let delta = event.contentDelta, !delta.isEmpty {
            acc.append(delta)
            didUpdate = true
        }

        if didUpdate {
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }
        return didUpdate
    }

    private struct LocalAlpineNativeToolCall {
        let id: String
        let name: String
        let arguments: String
    }

    private final class LocalAlpineNativeToolCallAccumulator {
        private struct Partial {
            var id: String = ""
            var name: String = ""
            var arguments: String = ""
        }

        private var partials: [Int: Partial] = [:]
        private var order: [Int] = []
        private(set) var sawToolFinish = false

        func absorb(_ event: SSEEvent) {
            guard case .json(let json) = event else { return }

            if let choices = json["choices"] as? [[String: Any]] {
                for choice in choices {
                    if let delta = choice["delta"] as? [String: Any] {
                        absorbToolCalls(delta["tool_calls"], replaceArguments: false)
                    }
                    if let message = choice["message"] as? [String: Any] {
                        absorbToolCalls(message["tool_calls"], replaceArguments: true)
                    }
                    if let finishReason = choice["finish_reason"] as? String,
                       finishReason == "tool_calls" {
                        sawToolFinish = true
                    }
                }
            }

            absorbToolCalls(json["tool_calls"], replaceArguments: true)
        }

        func completedCalls() -> [LocalAlpineNativeToolCall] {
            order.compactMap { index in
                guard let partial = partials[index],
                      !partial.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let id = partial.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let arguments = partial.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                return LocalAlpineNativeToolCall(
                    id: id.isEmpty ? "call_\(index)" : id,
                    name: partial.name,
                    arguments: arguments.isEmpty ? "{}" : arguments
                )
            }
        }

        private func absorbToolCalls(_ value: Any?, replaceArguments: Bool) {
            guard let value else { return }
            let calls: [[String: Any]]
            if let array = value as? [[String: Any]] {
                calls = array
            } else if let array = value as? [Any] {
                calls = array.compactMap { $0 as? [String: Any] }
            } else if let dict = value as? [String: Any] {
                calls = [dict]
            } else {
                return
            }

            for (fallbackIndex, call) in calls.enumerated() {
                let index = Self.intValue(call["index"]) ?? fallbackIndex
                if !order.contains(index) {
                    order.append(index)
                }
                var partial = partials[index] ?? Partial()
                if let id = Self.stringValue(call["id"]), !id.isEmpty {
                    partial.id = id
                }
                if let type = Self.stringValue(call["type"]),
                   type == "function",
                   partial.name.isEmpty,
                   let name = Self.stringValue(call["name"]) {
                    partial.name = name
                }

                if let function = call["function"] as? [String: Any] {
                    if let name = Self.stringValue(function["name"]), !name.isEmpty {
                        partial.name = name
                    }
                    if let arguments = Self.argumentString(function["arguments"]) {
                        if replaceArguments {
                            partial.arguments = arguments
                        } else {
                            partial.arguments += arguments
                        }
                    }
                } else {
                    if let name = Self.stringValue(call["name"] ?? call["tool"] ?? call["function_name"]), !name.isEmpty {
                        partial.name = name
                    }
                    if let arguments = Self.argumentString(call["arguments"] ?? call["args"] ?? call["input"]) {
                        if replaceArguments {
                            partial.arguments = arguments
                        } else {
                            partial.arguments += arguments
                        }
                    }
                }
                partials[index] = partial
            }
        }

        private static func stringValue(_ value: Any?) -> String? {
            switch value {
            case let string as String:
                return string
            case let number as NSNumber:
                return number.stringValue
            default:
                return nil
            }
        }

        private static func intValue(_ value: Any?) -> Int? {
            switch value {
            case let int as Int:
                return int
            case let number as NSNumber:
                return number.intValue
            case let string as String:
                return Int(string)
            default:
                return nil
            }
        }

        private static func argumentString(_ value: Any?) -> String? {
            guard let value else { return nil }
            if let string = value as? String { return string }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        }
    }

    private func streamOpenAICompatibleLocalAlpineNativeLoop(
        manager: ConversationManager,
        initialRequest: ChatCompletionRequest,
        assistantMessageId: String,
        acc: ContentAccumulator
    ) async throws -> [String: Any]? {
        var request = initialRequest
        var apiMessages = initialRequest.messages
        var exactUsage: [String: Any]?

        for _ in 0..<localAlpineAgentMaxSteps {
            request.messages = apiMessages
            let toolAccumulator = LocalAlpineNativeToolCallAccumulator()
            let sseStream = try await manager.sendPreferredOpenAIStreaming(request: request)

            for try await event in sseStream {
                if Task.isCancelled { break }
                if let usage = event.usage, !usage.isEmpty {
                    exactUsage = usage
                }
                toolAccumulator.absorb(event)
                applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                if event.isFinished { break }
            }
            if Task.isCancelled { return exactUsage }

            let calls = toolAccumulator.completedCalls()
            guard !calls.isEmpty else { return exactUsage }

            apiMessages.append(Self.openAIToolCallAssistantMessage(for: calls))
            for call in calls {
                let result = await executeLocalAlpineNativeToolCall(call, assistantMessageId: assistantMessageId)
                apiMessages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": Self.localAlpineNativeToolResultContent(result)
                ])
            }
        }

        throw APIError.unknown(
            underlying: NSError(
                domain: "ChatViewModel",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "本地 Agent 已达到最大步骤数，已停止以避免重复执行。"]
            )
        )
    }

    private func executeLocalAlpineNativeToolCall(
        _ call: LocalAlpineNativeToolCall,
        assistantMessageId: String
    ) async -> LocalAlpineAgentResult {
        localAlpineNativeToolExecutedMessageIds.insert(assistantMessageId)
        let content = Self.localAlpineNativeToolEnvelopeContent(for: call)
        let toolResult = await LocalAlpineTerminalAgentRunner.run(
            .executableContent(content),
            inputProvider: { request in
                guard !Task.isCancelled else { return nil }
                return await self.requestLocalAlpineInput(request)
            },
            eventHandler: { [weak self] event in
                self?.applyLocalAlpineToolEvent(event, messageId: assistantMessageId)
            }
        )
        let result = toolResult.result
        mergeLocalAlpineNativeToolResultMetadata(messageId: assistantMessageId, result: result)
        recordLocalAlpineFailures(from: result)
        recordLocalAlpineCompletedCommands(from: result)
        await attachLocalAlpineGeneratedMediaIfNeeded(messageId: assistantMessageId)
        return result
    }

    private func mergeLocalAlpineNativeToolResultMetadata(messageId: String, result: LocalAlpineAgentResult) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var metadata = conversation?.messages[index].metadata ?? [:]
        let raw = [metadata["iexa_local_alpine_raw_result"], result.summary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !raw.isEmpty {
            metadata["iexa_local_alpine_raw_result"] = raw
        }
        if let toolRunId = result.toolRunId {
            metadata["iexa_local_alpine_tool_run_id"] = toolRunId
        }

        let existingCalls = LocalAlpineToolCall.decodeMetadata(metadata["iexa_local_alpine_tool_calls"])
        let mergedCalls = existingCalls + result.toolCalls.filter { incoming in
            !existingCalls.contains(where: { $0.id == incoming.id })
        }
        if let toolCalls = LocalAlpineToolCall.metadataString(for: mergedCalls) {
            metadata["iexa_local_alpine_tool_calls"] = toolCalls
        }

        let existingFiles = LocalAlpineWrittenFile.decodeMetadata(metadata["iexa_local_alpine_written_files"])
        let mergedFiles = existingFiles + result.writtenFiles.filter { incoming in
            !existingFiles.contains(where: { $0.path == incoming.path && $0.byteCount == incoming.byteCount })
        }
        if let writtenFiles = LocalAlpineWrittenFile.metadataString(for: mergedFiles) {
            metadata["iexa_local_alpine_written_files"] = writtenFiles
        }

        let existingResults = LocalAlpineAgentCommandResult.decodeMetadata(metadata["iexa_local_alpine_command_results"])
        let mergedResults = existingResults + result.commandResults
        if let commandResults = LocalAlpineAgentCommandResult.metadataString(for: mergedResults) {
            metadata["iexa_local_alpine_command_results"] = commandResults
        }
        conversation?.messages[index].metadata = metadata
        conversation?.history.updateNode(id: messageId) { node in
            node.metadata = metadata
        }
    }

    private static func openAIToolCallAssistantMessage(for calls: [LocalAlpineNativeToolCall]) -> [String: Any] {
        [
            "role": "assistant",
            "content": "",
            "tool_calls": calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ]
            }
        ]
    }

    private static func localAlpineNativeToolEnvelopeContent(for call: LocalAlpineNativeToolCall) -> String {
        let argumentsObject: Any
        if let data = call.arguments.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            argumentsObject = json
        } else {
            argumentsObject = ["value": call.arguments]
        }

        let object: [String: Any] = [
            "tool": call.name,
            "arguments": argumentsObject
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data()
        let json = String(data: data, encoding: .utf8) ?? #"{"tool":"\#(call.name)","arguments":{}}"#
        return """
        ```iexa_alpine
        \(json)
        ```
        """
    }

    private static func localAlpineNativeToolResultContent(_ result: LocalAlpineAgentResult) -> String {
        let body = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.didExecute ? "Local Alpine tool completed." : "Local Alpine tool did not execute."
        return String((body.isEmpty ? fallback : body).prefix(16_000))
    }

    private func shouldUseLocalAlpineNativeTools(for modelId: String?) -> Bool {
        guard isOpenAICompatibleProvider else { return false }
        let key = (modelId ?? selectedModelId ?? conversation?.model ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return true }
        return !localAlpineNativeToolsUnsupportedModels.contains(key)
    }

    private static func errorLooksLikeUnsupportedNativeTools(_ error: Error) -> Bool {
        let nsError = error as NSError
        let text = [
            String(describing: error),
            nsError.localizedDescription,
            nsError.userInfo.values.map { String(describing: $0) }.joined(separator: " ")
        ]
            .joined(separator: " ")
            .lowercased()
        let mentionsTools = text.contains("tool")
            || text.contains("function_call")
            || text.contains("function call")
            || text.contains("tool_choice")
            || text.contains("tools")
        let unsupported = text.contains("unsupported")
            || text.contains("not support")
            || text.contains("unknown parameter")
            || text.contains("invalid parameter")
            || text.contains("unrecognized")
            || text.contains("not allowed")
            || text.contains("400")
            || text.contains("422")
        return mentionsTools && unsupported
    }

    nonisolated private static func reasoningDelta(from value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }

        if let array = value as? [Any] {
            let rendered = array.compactMap { reasoningDelta(from: $0) }.joined()
            return rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rendered
        }

        guard let dict = value as? [String: Any] else { return nil }

        if let type = dict["type"] as? String,
           [
            "response.reasoning_text.delta",
            "response.reasoning.delta",
            "response.output_reasoning.delta"
           ].contains(type),
           let delta = dict["delta"] as? String,
           !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return delta
        }

        if dict["type"] as? String == "content_block_delta",
           let delta = dict["delta"] as? [String: Any],
           ["thinking_delta", "reasoning_delta"].contains(delta["type"] as? String ?? ""),
           let text = (delta["thinking"] as? String) ?? (delta["text"] as? String),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let choices = dict["choices"] as? [[String: Any]],
           let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let reasoning = reasoningDelta(from: delta) {
                return reasoning
            }
            if let message = first["message"] as? [String: Any],
               let reasoning = reasoningDelta(from: message) {
                return reasoning
            }
        }

        for key in [
            "reasoning_content", "reasoningContent",
            "reasoning_text", "reasoningText",
            "thinking_content", "thinkingContent",
            "thinking", "think",
            "thought", "thoughts",
            "reasoning"
        ] {
            if let rendered = reasoningDelta(from: dict[key]) {
                return rendered
            }
        }

        return nil
    }

    private func handleChatEvent(
        _ event: [String: Any], ack: ((Any?) -> Void)?,
        assistantMessageId: String, modelId: String,
        socketSessionId: String, effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]

        // Title, tags, follow-ups, and sources can arrive AFTER done:true
        // so we must NOT guard on hasFinishedStreaming for those event types.
        // Only guard for content-producing events.

        switch type {
        // --- Events that MUST work after streaming finishes ---

        case "chat:title":
            // Title can be a direct string or nested in payload
            var newTitle: String?
            if let titleStr = data["data"] as? String, !titleStr.isEmpty {
                newTitle = titleStr
            } else if let p = payload, let t = p["title"] as? String, !t.isEmpty {
                newTitle = t
            } else if let p = payload {
                for (_, value) in p {
                    if let s = value as? String, !s.isEmpty && s.count < 200 {
                        newTitle = s
                        break
                    }
                }
            }
            if let newTitle {
                applyGeneratedConversationTitle(newTitle, chatId: effectiveChatId)
                logger.info("Title updated: \(newTitle)")
                // NOTE: We do NOT persist the title back to the server here.
                // The server generated this title via background_tasks and already
                // has it stored. Writing it back would be redundant and could race
                // with the server's own save.
            }

        case "chat:tags":
            // Refresh conversation from server to get tags
            if let chatId = effectiveChatId {
                Task {
                    try? await refreshConversationMetadata(chatId: chatId, assistantMessageId: assistantMessageId)
                }
            }

        case "chat:message:follow_ups":
            // Follow-ups can arrive in various formats:
            // 1. { data: { follow_ups: [...] } }
            // 2. { data: { followUps: [...] } }
            // 3. { data: [...] } (direct array)
            var followUps: [String] = []
            if let payload {
                followUps = payload["follow_ups"] as? [String]
                    ?? payload["followUps"] as? [String]
                    ?? payload["suggestions"] as? [String] ?? []
            }
            // Try direct array format
            if followUps.isEmpty, let directArray = data["data"] as? [String] {
                followUps = directArray
            }
            if !followUps.isEmpty {
                let trimmed = followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !trimmed.isEmpty {
                    logger.info("Received \(trimmed.count) follow-ups")
                    appendFollowUps(id: assistantMessageId, followUps: trimmed)
                }
            }

        case "source", "citation", "annotation":
            if let payload, let sources = parseSources([payload]) {
                appendSources(id: assistantMessageId, sources: sources)
            }

        case "notification":
            if let msg = payload?["content"] as? String { logger.info("Notification: \(msg)") }

        case "confirmation":
            ack?(true)

        case "execute":
            logger.info("🔧 [Socket] Acknowledging execute event for tool pipeline")
            ack?(true)

        // --- Events that should only work during active streaming ---

        default:
            guard !hasFinishedStreaming else { return }

            switch type {
            case "chat:completion":
                guard let payload else { break }
                handleChatCompletion(payload, assistantMessageId: assistantMessageId,
                                      modelId: modelId, socketSessionId: socketSessionId,
                                      effectiveChatId: effectiveChatId, acc: acc)

            case "chat:message:delta", "message", "event:message:delta":
                let content = payload?["content"] as? String ?? ""
                var didUpdate = false
                if let reasoning = Self.reasoningDelta(from: payload ?? data) {
                    acc.appendReasoning(reasoning)
                    didUpdate = true
                }
                if !content.isEmpty {
                    acc.append(content)
                    didUpdate = true
                }
                if didUpdate {
                    updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                }

            case "chat:message", "replace":
                let content = payload?["content"] as? String ?? ""
                var didUpdate = false
                if let reasoning = Self.reasoningDelta(from: payload ?? data) {
                    acc.appendReasoning(reasoning)
                    didUpdate = true
                }
                if !content.isEmpty {
                    let localBody = acc.bodyContent
                    let protectedContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                        local: localBody,
                        incoming: content
                    ) ? localBody : content
                    acc.replace(protectedContent)
                    didUpdate = true
                }
                if didUpdate {
                    updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                }

            case "status", "event:status":
                if let payload {
                    let su = parseStatusData(payload)
                    appendStatusUpdate(id: assistantMessageId, status: su)
                }

            case "chat:message:error":
                let errContent = extractErrorContent(from: payload ?? data)
                updateAssistantMessage(id: assistantMessageId, content: acc.content,
                                        isStreaming: false, error: ChatMessageError(content: errContent))
                cleanupStreaming()

            case "chat:tasks:cancel":
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
                cleanupStreaming()

            case "request:chat:completion":
                if let ch = payload?["channel"] as? String, !ch.isEmpty {
                    logger.info("Channel request: \(ch)")
                }

            case "execute:tool":
                if let name = payload?["name"] as? String, !name.isEmpty {
                    let su = ChatStatusUpdate(action: name, description: "Executing \(name)…", done: false)
                    appendStatusUpdate(id: assistantMessageId, status: su)
                }

            default:
                break
            }
        }
    }

    private func handleChatCompletion(
        _ payload: [String: Any],
        assistantMessageId: String, modelId: String,
        socketSessionId: String, effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        // OpenAI choices format
        if let choices = payload["choices"] as? [[String: Any]],
           let first = choices.first,
           let delta = first["delta"] as? [String: Any] {
            var didUpdate = false
            if let reasoning = Self.reasoningDelta(from: delta) {
                acc.appendReasoning(reasoning)
                didUpdate = true
            }
            if let c = delta["content"] as? String, !c.isEmpty {
                acc.append(c)
                didUpdate = true
            }
            if didUpdate {
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let fn = call["function"] as? [String: Any],
                       let name = fn["name"] as? String, !name.isEmpty {
                        appendStatusUpdate(id: assistantMessageId,
                            status: ChatStatusUpdate(action: name, description: "Calling \(name)…", done: false))
                    }
                }
            }
            if let status = delta["status"] as? [String: Any] {
                appendStatusUpdate(id: assistantMessageId, status: parseStatusData(status))
            }
            if let sourcesArray = delta["sources"] as? [[String: Any]],
               let sources = parseSources(sourcesArray) {
                appendSources(id: assistantMessageId, sources: sources)
            }
            if let citations = delta["citations"] as? [[String: Any]],
               let sources = parseSources(citations) {
                appendSources(id: assistantMessageId, sources: sources)
            }
            if let annotations = delta["annotations"] as? [[String: Any]],
               let sources = parseSources(annotations) {
                appendSources(id: assistantMessageId, sources: sources)
            }
        }

        if payload["choices"] == nil,
           let reasoning = Self.reasoningDelta(from: payload) {
            acc.appendReasoning(reasoning)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }

        // Direct content field
        if let content = payload["content"] as? String, !content.isEmpty {
            let localBody = acc.bodyContent
            let protectedContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                local: localBody,
                incoming: content
            ) ? localBody : content
            acc.replace(protectedContent)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }

        // Top-level tool_calls
        if let toolCalls = payload["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                if let fn = call["function"] as? [String: Any],
                   let name = fn["name"] as? String, !name.isEmpty {
                    appendStatusUpdate(id: assistantMessageId,
                        status: ChatStatusUpdate(action: name, description: "Calling \(name)…", done: false))
                }
            }
        }

        // Top-level sources
        if let rawSources = payload["sources"] as? [[String: Any]]
            ?? payload["citations"] as? [[String: Any]]
            ?? payload["annotations"] as? [[String: Any]],
           let sources = parseSources(rawSources) {
            appendSources(id: assistantMessageId, sources: sources)
        }

        // Done signal
        if payload["done"] as? Bool == true {
            logger.info("Received done:true – finalizing streaming")
            let usage = SSEEvent.json(payload).usage
            finishStreamingSuccessfully(
                assistantMessageId: assistantMessageId,
                modelId: modelId,
                socketSessionId: socketSessionId,
                effectiveChatId: effectiveChatId,
                acc: acc,
                usage: usage
            )
        }

        // Error in completion payload
        if let err = payload["error"] as? String, !err.isEmpty {
            updateAssistantMessage(id: assistantMessageId, content: acc.content,
                                    isStreaming: false, error: ChatMessageError(content: err))
            cleanupStreaming()
        }
    }

    /// Handles channel events (secondary streaming channel).
    private func handleChannelEvent(
        _ event: [String: Any],
        assistantMessageId: String,
        acc: ContentAccumulator
    ) {
        guard !hasFinishedStreaming else { return }
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]

        if type == "message" {
            var didUpdate = false
            if let reasoning = Self.reasoningDelta(from: payload ?? data) {
                acc.appendReasoning(reasoning)
                didUpdate = true
            }
            if let content = payload?["content"] as? String, !content.isEmpty {
                acc.append(content)
                didUpdate = true
            }
            if didUpdate {
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
            }
        }
    }

    // MARK: - Streaming Completion

    private func finishStreamingSuccessfully(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        acc: ContentAccumulator,
        usage: [String: Any]? = nil
    ) {
        acc.markReasoningDone()

        // If content is empty, poll server for it
        if acc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await pollAndFinish(
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId,
                    acc: acc,
                    usage: usage
                )
            }
            return
        }

        if conversation?.messages.first(where: { $0.id == assistantMessageId })?
            .metadata?["iexa_local_alpine_continuation"] == "true" {
            Task {
                await finishLocalAlpineContinuation(
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    content: acc.content,
                    usage: usage
                )
            }
            return
        }

        // Finalize the message — mark as not streaming but DON'T dispose
        // socket subscriptions yet. Follow-ups, title, and tags arrive
        // AFTER done:true via socket events, so we need to keep listening.
        updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
        normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
        let finalAssistantContent = conversation?.messages
            .first(where: { $0.id == assistantMessageId })?.content ?? acc.content
        applyUsage(usage, toMessageId: assistantMessageId)
        let lastUser = conversation?.messages.last(where: { $0.role == .user && !Self.isLocalWorkspaceAgentResult($0) })
        recordTokenUsageForCompletedTurn(
            assistantMessageId: assistantMessageId,
            userText: lastUser?.content ?? "",
            assistantText: finalAssistantContent,
            userAttachments: [],
            usage: usage
        )
        hasFinishedStreaming = true
        isStreaming = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDelayTask?.cancel()
        recoveryDelayTask = nil
        emptyPollCount = 0
        // NOTE: endBackgroundTask() is intentionally called INSIDE the
        // completionTask below, AFTER the notification has been awaited.
        // Calling it here (before the Task) causes iOS to immediately suspend
        // the process, preventing the notification from ever being scheduled.

        // Capture the current subscriptions by value so the async Task below
        // disposes ONLY the subscriptions that belong to this streaming session.
        //
        // Without this capture, if the user sends a 2nd message before this
        // Task completes (which can take 10+ seconds due to file-poll sleeps),
        // the Task would dispose the NEW subscriptions created for the 2nd
        // message — killing live socket delivery mid-stream and causing all
        // text to appear at once at the end instead of token-by-token.
        let capturedChatSub = chatSubscription
        let capturedChannelSub = channelSubscription
        chatSubscription = nil
        channelSubscription = nil

        // Send chatCompleted, refresh metadata immediately for files/images,
        // then poll for tool-generated files before final cleanup.
        // Store as completionTask so it can be cancelled if user sends a new
        // message before it finishes (prevents content overwrite bug).
        completionTask = Task {
            // Send notification first, THEN end the background task.
            // This ordering is critical: if endBackgroundTask() is called first,
            // iOS may immediately suspend the process before the notification
            // is scheduled — causing the banner to never appear.
            await sendCompletionNotificationIfNeeded(content: finalAssistantContent)
            // Now it is safe to release the background time assertion.
            self.endBackgroundTask()

            if let chatId = effectiveChatId {
                await manager?.sendChatCompleted(
                    chatId: chatId, messageId: assistantMessageId,
                    model: modelId, sessionId: socketSessionId,
                    messages: buildSimpleAPIMessages())

                // Immediately refresh metadata to pick up tool-generated files/images
                try? await refreshConversationMetadata(
                    chatId: chatId, assistantMessageId: assistantMessageId)

                // Short delay re-fetch to catch server-side post-processing that happens
                // AFTER chatCompleted (e.g. filter functions that append timing/performance
                // stats like "⏱ 12.2s · ⚡ 77.7 t/s" to the message content).
                // The filter runs asynchronously after chatCompleted finishes, so the
                // immediate refresh above may miss it — this 1.5s delay catches it.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                try? await refreshConversationMetadata(
                    chatId: chatId, assistantMessageId: assistantMessageId)

                // Check if files are still missing (tool outputs take time to process).
                // Poll with increasing delays specifically for files.
                let needsFilePoll = self.conversation?.messages
                    .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true
                if needsFilePoll {
                    for delay: UInt64 in [2, 3, 5] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        try? await refreshConversationMetadata(
                            chatId: chatId, assistantMessageId: assistantMessageId)
                        let hasFiles = !(self.conversation?.messages
                            .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true)
                        if hasFiles { break }
                    }

                    // Last resort: if server still hasn't provided files, extract
                    // file IDs directly from tool call results in the message content.
                    // This handles the case where the server metadata doesn't include
                    // files but the tool response clearly references generated images.
                    self.populateFilesFromToolResults(messageId: assistantMessageId)
                    self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                } else {
                    // Files already present — just wait for follow-ups/title
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    try? await refreshConversationMetadata(
                        chatId: chatId, assistantMessageId: assistantMessageId)
                    self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                }
                Task { @MainActor [weak self] in
                    await self?.ensureGeneratedConversationTitle(chatId: chatId, modelId: modelId)
                }
            }
            // NOTE: Do NOT call saveConversationToServer() here.
            // The server already has the authoritative state after chatCompleted
            // processed tool results (web search, image gen). Saving our local
            // copy back would overwrite the server's clean format with raw
            // streamed content containing <details> blocks, causing the chat
            // to appear blank on the web client.

            // Dispose only the subscriptions captured at the start of THIS
            // completion handler — not the instance vars (which may already
            // belong to a newer streaming session).
            capturedChatSub?.dispose()
            capturedChannelSub?.dispose()

            // Notify the conversation list to refresh
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

            // Generate a suggested emoji for the response (fire-and-forget)
            await self.generateSuggestedEmoji(for: finalAssistantContent)
        }
    }

    /// Generates a suggested emoji for the assistant's response via the server's
    /// emoji completions endpoint. Fire-and-forget — failure just means no emoji.
    private func generateSuggestedEmoji(for content: String) async {
        guard let apiClient = manager?.apiClient,
              let modelId = selectedModelId else { return }
        // Only generate if content is meaningful
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return }
        // Use first 200 chars as prompt to keep it fast
        let prompt = String(trimmed.prefix(200))
        do {
            if let emoji = try await apiClient.generateEmoji(model: modelId, prompt: prompt) {
                // Only accept single emoji or very short strings
                let cleaned = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.count <= 4 {
                    suggestedEmoji = cleaned
                }
            }
        } catch {
            // Non-critical — just skip the emoji suggestion
            logger.debug("Emoji generation failed: \(error.localizedDescription)")
        }
    }

    private func ensureGeneratedConversationTitle(chatId: String, modelId: String) async {
        let titleGenerationEnabled = UserDefaults.standard.object(forKey: "titleGenerationEnabled") as? Bool ?? true
        guard titleGenerationEnabled else { return }
        guard let manager else { return }
        guard conversation?.id == chatId else { return }
        guard !isTemporaryChat else { return }
        guard !generatedTitleConversationIds.contains(chatId),
              !titleGenerationInFlightConversationIds.contains(chatId) else {
            return
        }
        guard shouldReplaceConversationTitleAutomatically(chatId: chatId) else { return }
        guard let messages = conversationTitleSourceMessages() else { return }

        titleGenerationInFlightConversationIds.insert(chatId)
        defer { titleGenerationInFlightConversationIds.remove(chatId) }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard !Task.isCancelled else { return }
        guard conversation?.id == chatId,
              shouldReplaceConversationTitleAutomatically(chatId: chatId),
              !generatedTitleConversationIds.contains(chatId) else {
            return
        }

        do {
            guard let rawTitle = try await manager.apiClient.generateConversationTitle(
                model: modelId,
                messages: messages
            ) else {
                return
            }
            guard let title = sanitizedGeneratedConversationTitle(rawTitle),
                  shouldReplaceConversationTitleAutomatically(chatId: chatId) else {
                return
            }

            conversation?.title = title
            generatedTitleConversationIds.insert(chatId)
            initialAutoTitlesByConversationId.removeValue(forKey: chatId)

            try? await manager.renameConversation(id: chatId, title: title)
            NotificationCenter.default.post(
                name: .conversationTitleUpdated,
                object: nil,
                userInfo: ["conversationId": chatId, "title": title]
            )
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        } catch {
            logger.debug("Conversation title generation failed: \(error.localizedDescription)")
        }
    }

    private func conversationTitleSourceMessages() -> [[String: Any]]? {
        guard let messages = conversation?.messages else { return nil }
        let visibleMessages = messages.filter {
            !$0.isStreaming
                && !Self.isLocalWorkspaceAgentResult($0)
                && !Self.isLocalAlpineAgentResult($0)
                && !Self.isLocalNativeToolResult($0)
        }
        guard visibleMessages.filter({ $0.role == .user }).count == 1,
              let firstUser = visibleMessages.first(where: { $0.role == .user }),
              let firstAssistant = visibleMessages.first(where: { $0.role == .assistant }) else {
            return nil
        }

        let userText = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistantText = Self.safeAssistantDisplayContent(firstAssistant.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty, assistantText.count >= 20 else { return nil }

        return [
            ["role": "user", "content": Self.clippedForSystemContext(userText, maxCharacters: 1_200)],
            ["role": "assistant", "content": Self.clippedForSystemContext(assistantText, maxCharacters: 2_000)]
        ]
    }

    private func shouldReplaceConversationTitleAutomatically(chatId: String) -> Bool {
        let currentTitle = conversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !currentTitle.isEmpty else { return true }
        if let initialTitle = initialAutoTitlesByConversationId[chatId] {
            return currentTitle == initialTitle
        }

        let genericTitles: Set<String> = [
            "新对话", "New Chat", "Untitled Chat", "Chat",
            "回复问候", "询问能力"
        ]
        return genericTitles.contains(currentTitle)
    }

    private func applyGeneratedConversationTitle(_ value: String, chatId: String?) {
        guard let title = sanitizedGeneratedConversationTitle(value) else { return }
        let previousTitle = conversation?.title
        if previousTitle != title {
            conversation?.title = title
        }
        if let chatId {
            if initialAutoTitlesByConversationId[chatId] != title {
                generatedTitleConversationIds.insert(chatId)
                initialAutoTitlesByConversationId.removeValue(forKey: chatId)
            }
            if previousTitle != title {
                NotificationCenter.default.post(
                    name: .conversationTitleUpdated,
                    object: nil,
                    userInfo: ["conversationId": chatId, "title": title]
                )
            }
        }
    }

    private func sanitizedGeneratedConversationTitle(_ value: String) -> String? {
        var title = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = ["标题：", "标题:", "Title:", "title:"]
        for prefix in prefixes where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var trimSet = CharacterSet.whitespacesAndNewlines
        trimSet.formUnion(CharacterSet(charactersIn: "\"'“”‘’`*_#"))
        title = title.trimmingCharacters(in: trimSet)

        guard !title.isEmpty else { return nil }
        let lowercased = title.lowercased()
        guard lowercased != "new chat",
              lowercased != "untitled chat",
              lowercased != "chat" else {
            return nil
        }
        return title.count > 32 ? String(title.prefix(32)) : title
    }

    /// Polls the server for content when the done signal arrives with empty content.
    private func pollAndFinish(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        acc: ContentAccumulator,
        usage: [String: Any]? = nil
    ) async {
        acc.markReasoningDone()

        let isLocalAlpineContinuationMessage = conversation?.messages
            .first(where: { $0.id == assistantMessageId })?
            .metadata?["iexa_local_alpine_continuation"] == "true"

        guard let chatId = effectiveChatId, let manager else {
            if isLocalAlpineContinuationMessage {
                await finishLocalAlpineContinuation(
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    content: acc.content,
                    usage: usage
                )
                return
            }
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
            cleanupStreaming()
            return
        }

        // Poll up to 5 times with 1s delay
        for attempt in 1...5 {
            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                let refreshedAssistant = refreshed.messages.first(where: { $0.id == assistantMessageId })
                    ?? (isLocalAlpineContinuationMessage
                        ? nil
                        : refreshed.messages.last(where: { $0.role == .assistant }))
                if let refreshedAssistant,
                   !refreshedAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let localBody = acc.bodyContent
                    let localContent = localBody.isEmpty
                        ? (conversation?.messages.first(where: { $0.id == assistantMessageId })?.content ?? "")
                        : localBody
                    let protectedContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                        local: localContent,
                        incoming: refreshedAssistant.content
                    ) ? localContent : refreshedAssistant.content
                    acc.replace(protectedContent)
                    logger.info("Server poll \(attempt): got content (\(refreshedAssistant.content.count) chars)")
                    break
                }
            } catch {
                logger.warning("Poll attempt \(attempt) failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if isLocalAlpineContinuationMessage {
            await finishLocalAlpineContinuation(
                assistantMessageId: assistantMessageId,
                modelId: modelId,
                content: acc.content,
                usage: usage
            )
            return
        }

        updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
        normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
        var finalAssistantContent = conversation?.messages
            .first(where: { $0.id == assistantMessageId })?.content ?? acc.content
        if finalAssistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateAssistantMessage(
                id: assistantMessageId,
                content: "",
                isStreaming: false,
                error: ChatMessageError(content: "未收到模型回复或图片数据，请重试。")
            )
            cleanupStreaming()
            return
        }
        let lastUser = conversation?.messages.last(where: { $0.role == .user && !Self.isLocalWorkspaceAgentResult($0) })
        applyUsage(usage, toMessageId: assistantMessageId)
        recordTokenUsageForCompletedTurn(
            assistantMessageId: assistantMessageId,
            userText: lastUser?.content ?? "",
            assistantText: finalAssistantContent,
            userAttachments: [],
            usage: usage
        )

        // Send background notification if app is not active
        await sendCompletionNotificationIfNeeded(content: finalAssistantContent)

        await manager.sendChatCompleted(
            chatId: chatId, messageId: assistantMessageId,
            model: modelId, sessionId: socketSessionId,
            messages: buildSimpleAPIMessages())

        // Refresh metadata to pick up tool-generated files/images.
        // Poll with retries since tool outputs may take time to process.
        for delay: UInt64 in [1, 2, 3] {
            try? await refreshConversationMetadata(
                chatId: chatId, assistantMessageId: assistantMessageId)
            let hasFiles = !(conversation?.messages
                .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true)
            if hasFiles { break }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }

        // Last resort: extract file IDs from tool call results in content
        populateFilesFromToolResults(messageId: assistantMessageId)
        normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
        finalAssistantContent = conversation?.messages
            .first(where: { $0.id == assistantMessageId })?.content ?? finalAssistantContent

        Task { @MainActor [weak self] in
            await self?.ensureGeneratedConversationTitle(chatId: chatId, modelId: modelId)
        }

        // NOTE: Do NOT call saveConversationToServer() here — same reason
        // as finishStreamingSuccessfully. The server's chatCompleted has the
        // authoritative state; pushing our local copy would corrupt tool results.
        cleanupStreaming()
    }

    private func pollRegeneratedAssistantUntilStable(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?
    ) async {
        guard let chatId = effectiveChatId, let manager else {
            updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                                   error: ChatMessageError(content: "No connection available."))
            cleanupStreaming()
            return
        }

        var lastContentLength = 0
        var staleCount = 0
        var latestRefreshed: Conversation?

        for _ in 0..<40 {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }

            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                latestRefreshed = refreshed
                if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                    let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !serverContent.isEmpty {
                        let localContent = conversation?.messages
                            .first(where: { $0.id == assistantMessageId })?.content ?? ""
                        let protectedContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                            local: localContent,
                            incoming: serverAssistant.content
                        ) ? localContent : serverAssistant.content
                        updateAssistantMessage(id: assistantMessageId, content: protectedContent, isStreaming: true)

                        if serverContent.count > lastContentLength {
                            lastContentLength = serverContent.count
                            staleCount = 0
                        } else {
                            staleCount += 1
                        }

                        if staleCount >= 3 {
                            updateAssistantMessage(id: assistantMessageId, content: protectedContent, isStreaming: false)
                            if let latestRefreshed {
                                adoptServerMessages(serverConversation: latestRefreshed)
                            }
                            normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                            await manager.sendChatCompleted(
                                chatId: chatId,
                                messageId: assistantMessageId,
                                model: modelId,
                                sessionId: socketSessionId,
                                messages: buildSimpleAPIMessages()
                            )
                            try? await refreshConversationMetadata(
                                chatId: chatId,
                                assistantMessageId: assistantMessageId
                            )
                            cleanupStreaming()
                            let finalContent = conversation?.messages
                                .first(where: { $0.id == assistantMessageId })?.content ?? protectedContent
                            await sendCompletionNotificationIfNeeded(content: finalContent)
                            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                            return
                        }
                    }
                }
            } catch {
                logger.warning("Regenerate polling failed: \(error.localizedDescription)")
            }
        }

        let finalContent = conversation?.messages
            .first(where: { $0.id == assistantMessageId })?.content ?? ""
        if finalContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateAssistantMessage(
                id: assistantMessageId,
                content: "",
                isStreaming: false,
                error: ChatMessageError(content: "未收到模型回复或图片数据，请重试。")
            )
        } else {
            updateAssistantMessage(id: assistantMessageId, content: finalContent, isStreaming: false)
            normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
        }
        cleanupStreaming()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    // MARK: - Recovery Timer

    /// Starts a timer that polls the server periodically to recover from stuck streaming.
    ///
    /// The first poll is delayed by 8 seconds to give socket streaming time to
    /// begin. The previous 3-second initial fire competed with socket events for
    /// main actor time and sometimes caused the "all text at once" symptom by
    /// triggering a full conversation fetch right when tokens were starting to flow.
    private func startRecoveryTimer(assistantMessageId: String, chatId: String?) {
        recoveryTimer?.invalidate()
        recoveryDelayTask?.cancel()
        emptyPollCount = 0

        // Use a cancellable Task for the initial delay instead of
        // DispatchQueue.main.asyncAfter, which cannot be cancelled when
        // the user navigates away or sends a new message.
        recoveryDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.isStreaming, !self.hasFinishedStreaming else { return }

            self.recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.runRecoveryPoll(assistantMessageId: assistantMessageId, chatId: chatId)
                }
            }
            // Also run the first poll immediately after the delay
            self.runRecoveryPoll(assistantMessageId: assistantMessageId, chatId: chatId)
        }
    }

    /// Extracted recovery poll logic (called by the recovery timer).
    private func runRecoveryPoll(assistantMessageId: String, chatId: String?) {
        Task { @MainActor in
            guard self.isStreaming, !self.hasFinishedStreaming else {
                self.recoveryTimer?.invalidate()
                self.recoveryTimer = nil
                return
            }
            guard let chatId, let manager = self.manager else { return }

            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                if let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                    let serverContent = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let localContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    // Server has more content than local — but ONLY update
                    // if the socket has NOT been delivering tokens. If the
                    // socket is actively streaming, let it continue token-by-token
                    // rather than dumping the entire server content at once.
                    if !serverContent.isEmpty && serverContent.count > localContent.count && !self.socketHasReceivedContent {
                        self.logger.info("Recovery: adopting server content (socket silent)")
                        if !CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                            local: localContent,
                            incoming: lastAssistant.content
                        ) {
                            self.updateAssistantMessage(
                                id: assistantMessageId, content: lastAssistant.content, isStreaming: true)
                        }
                    }

                    // Server says streaming is done
                    if !lastAssistant.isStreaming && !serverContent.isEmpty {
                        self.logger.info("Recovery: server says done with \(serverContent.count) chars")
                        let doneContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                            local: localContent,
                            incoming: lastAssistant.content
                        ) ? localContent : lastAssistant.content
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: doneContent, isStreaming: false)
                        Task { await self.sendCompletionNotificationIfNeeded(content: doneContent) }
                        self.cleanupStreaming()
                        return
                    }
                }
            } catch {
                self.logger.warning("Recovery poll failed: \(error.localizedDescription)")
            }

            // Check if there are active (pending) tool statuses — if so, tools
            // are still executing on the server. Do NOT count these polls toward
            // the give-up threshold. The server will eventually finish or error;
            // the user can also cancel manually via the stop button.
            let hasActiveToolStatus: Bool = {
                guard let msgIdx = self.conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) else { return false }
                let statuses = self.conversation?.messages[msgIdx].statusHistory ?? []
                return statuses.contains { $0.done != true && $0.hidden != true }
            }()

            if hasActiveToolStatus {
                // Tools still running — reset the empty poll counter so we
                // never give up while the server is actively processing.
                self.emptyPollCount = 0
                self.logger.debug("Recovery: tools still active, resetting poll count")
            } else {
                self.emptyPollCount += 1
            }

            // After 60s (12 polls at 5s) with NO active tools, give up.
            // When tools ARE active, emptyPollCount stays at 0 so we wait
            // indefinitely until the server finishes or the user cancels.
            if self.emptyPollCount >= 12 {
                self.logger.warning("Recovery: giving up after \(self.emptyPollCount) polls (no active tools)")
                let giveUpContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                self.updateAssistantMessage(
                    id: assistantMessageId,
                    content: giveUpContent,
                    isStreaming: false)
                Task { await self.sendCompletionNotificationIfNeeded(content: giveUpContent) }
                self.cleanupStreaming()
            }
        }
    }

    // MARK: - Cleanup

    /// Sends a local notification when generation completes.
    /// Always schedules the notification — the `UNUserNotificationCenterDelegate`
    /// controls presentation (banner vs silent) based on foreground state.
    private func sendCompletionNotificationIfNeeded(content: String) async {
        // Check if user has disabled generation notifications
        let notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard notificationsEnabled else { return }

        // Always schedule the notification. The UNUserNotificationCenterDelegate
        // (willPresent) handles foreground suppression — if the user is viewing
        // this conversation, it returns [] (no banner). This avoids stale
        // UIApplication.shared.connectedScenes state when called from background tasks.
        let chatId = conversationId ?? conversation?.id ?? ""
        let title = conversation?.title ?? "Chat"
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return }

        await NotificationService.shared.notifyGenerationComplete(
            conversationId: chatId,
            title: title,
            preview: preview
        )
    }

    /// Updates a task status locally and syncs to server.
    /// Called from TaskListView when the user taps a task row.
    func updateTaskStatus(taskId: String, newStatus: String) {
        // Update locally immediately (optimistic)
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[idx].status = newStatus
        }
        if let idx = conversation?.tasks.firstIndex(where: { $0.id == taskId }) {
            conversation?.tasks[idx].status = newStatus
        }
        // Sync to server
        guard let chatId = conversationId ?? conversation?.id,
              let apiClient = manager?.apiClient else { return }
        Task {
            _ = try? await apiClient.updateChatTask(chatId: chatId, taskId: taskId, status: newStatus)
        }
    }

    private func cleanupStreaming() {
        guard !hasFinishedStreaming else { return }
        Task {
            await RunLiveActivityService.shared.finishCurrent(success: false, detail: "运行已结束")
        }
        hasFinishedStreaming = true
        isStreaming = false
        isExternallyStreaming = false
        selfInitiatedStream = false
        activeTaskId = nil
        lastTaskExtractionLength = 0

        // Always fire the notification — the UNUserNotificationCenterDelegate's
        // willPresent handler suppresses the banner when the user is actively
        // viewing this chat. Checking applicationState here is unreliable because
        // this method is called from async Task contexts where the app state value
        // may already be stale or incorrect at the time of the call.
        // The notification service de-duplicates by conversation ID, so a second
        // call within the same second from a path that already called
        // sendCompletionNotificationIfNeeded is a no-op.
        let content = conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await self.sendCompletionNotificationIfNeeded(content: content)
            }
        }

        // CRITICAL: Flush the streaming store if it's still active.
        // Without this, background recovery paths (recoverFromBackgroundStreaming,
        // startBackgroundCompletionPolling) bypass updateAssistantMessage(isStreaming:false)
        // and go directly to adoptServerMessages → cleanupStreaming. The store's
        // isActive stays true, causing IsolatedAssistantMessage to remain stuck
        // in the fixed-height streaming container forever.
        if streamingStore.isActive, let msgId = streamingStore.streamingMessageId,
           let idx = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
            let result = streamingStore.abortStreaming()
            // Only overwrite content if the store has meaningful content
            // (adoptServerMessages may have already set the correct content)
            if !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               conversation?.messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                conversation?.messages[idx].content = result.content
            }
            conversation?.messages[idx].isStreaming = false
            if !result.sources.isEmpty && (conversation?.messages[idx].sources.isEmpty ?? true) {
                conversation?.messages[idx].sources = result.sources
            }
            if !result.statusHistory.isEmpty {
                conversation?.messages[idx].statusHistory = result.statusHistory
            }
        } else if streamingStore.isActive {
            // Store is active but message not found — just flush it
            streamingStore.abortStreaming()
        }
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        emptyPollCount = 0
        // or remove them if they never produced meaningful output
        if let lastIdx = conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
            let statuses = conversation?.messages[lastIdx].statusHistory ?? []
            let hasContent = !(conversation?.messages[lastIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if hasContent {
                // Mark any incomplete statuses as done
                for (i, status) in statuses.enumerated() {
                    if status.done != true {
                        conversation?.messages[lastIdx].statusHistory[i].done = true
                    }
                }
            }

            // Remove statuses that are all incomplete and have no meaningful info
            // (they were just transient placeholders that never completed)
            let allIncomplete = statuses.allSatisfy { $0.done != true }
            if allIncomplete && !statuses.isEmpty {
                conversation?.messages[lastIdx].statusHistory = []
            }
        }
        endBackgroundTask()
    }

    // MARK: - Private Helpers

    /// Timestamp of the last model metadata refresh. Used to throttle
    /// the per-send refresh so we don't add 100-500ms of network latency
    /// to every message when the models haven't changed.
    private var lastModelMetadataRefreshTime: Date = .distantPast

    /// Fetches full model config from `/api/v1/models/model?id={id}` for the selected model.
    ///
    /// This is the authoritative source for:
    /// - `params.function_calling` ("native" | absent) — which /api/models never returns
    /// - `meta.capabilities`, `meta.toolIds`, `meta.defaultFeatureIds`
    ///
    /// Called when a model is selected (selectModel) so the UI always reflects
    /// the server's actual config. Updates the model in `availableModels` and
    /// re-syncs UI defaults.
    private func refreshSelectedModelConfig() async {
        guard !isOpenAICompatibleProvider else { return }
        guard let modelId = selectedModelId, let manager else { return }
        do {
            if var fullModel = try await manager.apiClient.fetchModelConfig(modelId: modelId) {
                // Preserve pipe fields from the list endpoint — the single-model endpoint
                // (/api/v1/models/model) returns workspace-model schema which lacks
                // pipe/filters fields. Overwriting them would destroy isPipeModel=true,
                // filterIds, and the correct rawModelItem needed for pipe routing.
                if let existingModel = availableModels.first(where: { $0.id == modelId }) {
                    if existingModel.isPipeModel {
                        fullModel.isPipeModel = existingModel.isPipeModel
                        fullModel.filterIds = existingModel.filterIds
                    }
                    if existingModel.rawModelItem != nil {
                        fullModel.rawModelItem = existingModel.rawModelItem
                    }
                }
                // Resolve actions and filters from IDs + global functions.
                // The single-model endpoint returns actionIds/filterIds but not full objects.
                // Fetch functions to build proper entries with name/icon.
                await resolveActionsForModel(&fullModel)
                await resolveFiltersForModel(&fullModel)
                if let idx = availableModels.firstIndex(where: { $0.id == modelId }) {
                    availableModels[idx] = fullModel
                } else {
                    availableModels.append(fullModel)
                }
                lastModelMetadataRefreshTime = Date()
                syncUIWithModelDefaults()
                logger.info("Model config loaded: \(modelId) function_calling=\(fullModel.functionCallingMode ?? "(absent)") isPipe=\(fullModel.isPipeModel)")
            }
        } catch {
            logger.debug("Model config fetch failed for \(modelId): \(error.localizedDescription)")
        }
    }

    /// Refreshes the selected model's metadata (capabilities, defaultFeatureIds, toolIds)
    /// from the server. Called before each message send to pick up live admin changes
    /// without requiring the user to restart the chat.
    ///
    /// Throttled to at most once per 60 seconds to avoid adding unnecessary
    /// network latency to every send operation. Uses the single-model endpoint
    /// (/api/v1/models/model) which also returns params.function_calling.
    ///
    /// IMPORTANT: Uses `applyIncrementalModelDefaults` instead of `syncUIWithModelDefaults`
    /// to avoid wiping tools/features the user has manually toggled during the session.
    private func refreshSelectedModelMetadata() async {
        guard !isOpenAICompatibleProvider else { return }
        guard let modelId = selectedModelId, let manager else { return }
        do {
            if var fullModel = try await manager.apiClient.fetchModelConfig(modelId: modelId) {
                lastModelMetadataRefreshTime = Date()
                // Preserve pipe fields from the list endpoint — the single-model endpoint
                // (/api/v1/models/model) returns workspace-model schema which lacks
                // pipe/filters fields. Overwriting them would destroy isPipeModel=true,
                // filterIds, and the correct rawModelItem needed for pipe routing.
                if let existingModel = availableModels.first(where: { $0.id == modelId }) {
                    if existingModel.isPipeModel {
                        fullModel.isPipeModel = existingModel.isPipeModel
                        fullModel.filterIds = existingModel.filterIds
                    }
                    if existingModel.rawModelItem != nil {
                        fullModel.rawModelItem = existingModel.rawModelItem
                    }
                }
                // Resolve actions and filters from IDs + global functions (fresh every time).
                await resolveActionsForModel(&fullModel)
                await resolveFiltersForModel(&fullModel)
                if let idx = availableModels.firstIndex(where: { $0.id == modelId }) {
                    availableModels[idx] = fullModel
                }
                // Use incremental sync — only ADD new defaults; never wipe user selections.
                // syncUIWithModelDefaults() resets selectedToolIds = [] which would discard
                // any tools the user manually enabled this session.
                applyIncrementalModelDefaults(for: fullModel)
            }
        } catch {
            // Non-critical — proceed with cached model data
            logger.debug("Model metadata refresh failed: \(error.localizedDescription)")
        }
    }

    /// Resolves action buttons for a model by combining:
    /// 1. Global action functions (is_global == true, is_active == true) → always included
    /// 2. Per-model action IDs (model.actionIds) → included if active
    ///
    /// Fetches the functions list from `/api/v1/functions/` to get full action
    /// metadata (name, icon) and global/active status. This ensures actions are
    /// always fresh and correctly reflect admin changes (e.g., turning global off).
    private func resolveActionsForModel(_ model: inout AIModel) async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let functions = try await apiClient.getFunctions()
            let actionFunctions = functions.filter { $0.type == "action" && $0.isActive }

            var resolvedActions: [AIModelAction] = []
            var seenIds = Set<String>()

            for fn in actionFunctions {
                // Include if globally enabled OR if the model has this action in its actionIds
                let isGlobal = fn.isGlobal
                let isPerModel = model.actionIds.contains(fn.id)

                if isGlobal || isPerModel {
                    guard !seenIds.contains(fn.id) else { continue }
                    seenIds.insert(fn.id)
                    resolvedActions.append(AIModelAction(
                        id: fn.id,
                        name: fn.name,
                        description: fn.description,
                        icon: fn.iconURL
                    ))
                }
            }

            model.actions = resolvedActions
        } catch {
            // Non-critical — keep whatever actions the model already has
            logger.debug("Failed to resolve actions: \(error.localizedDescription)")
        }
    }

    /// Resolves filter IDs for a model by combining:
    /// 1. Global filter functions (is_global == true, is_active == true) → always included
    /// 2. Per-model filter IDs (model.filterIds from meta.filterIds) → included if active
    ///
    /// Fetches the functions list from `/api/v1/functions/` to get global/active status.
    /// This ensures filterIds sent in chat requests always reflect the current server state.
    private func resolveFiltersForModel(_ model: inout AIModel) async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let functions = try await apiClient.getFunctions()
            let filterFunctions = functions.filter { $0.type == "filter" && $0.isActive }

            var resolvedFilterIds: [String] = []
            var seenIds = Set<String>()

            for fn in filterFunctions {
                let isGlobal = fn.isGlobal
                let isPerModel = model.filterIds.contains(fn.id)

                if isGlobal || isPerModel {
                    guard !seenIds.contains(fn.id) else { continue }
                    seenIds.insert(fn.id)
                    resolvedFilterIds.append(fn.id)
                }
            }

            model.filterIds = resolvedFilterIds
        } catch {
            // Non-critical — keep whatever filterIds the model already has
            logger.debug("Failed to resolve filters: \(error.localizedDescription)")
        }
    }

    /// Incrementally applies server-side model defaults to the current session
    /// **without** clearing existing user selections.
    ///
    /// Unlike `syncUIWithModelDefaults()` (which is a full reset intended for
    /// model switches and new conversations), this method only ADDS newly-discovered
    /// defaults. It respects `userDisabledToolIds` so tools the user explicitly
    /// toggled off stay off, and it never removes tools/features the user turned on.
    ///
    /// Called by `refreshSelectedModelMetadata()` before each message send.
    private func applyIncrementalModelDefaults(for model: AIModel) {
        let defaults = model.defaultFeatureIds
        let caps = model.capabilities ?? [:]

        func isTruthy(_ key: String) -> Bool {
            guard let value = caps[key] else { return false }
            return ["1", "true"].contains(value.lowercased())
        }

        // Only enable features if admin has them on AND the user hasn't explicitly
        // turned them off this session. Never force-disable ones the user turned on.
        if isChatWebSearchAllowed
            && !userDisabledBuiltinFeatures.contains("web_search") {
            webSearchEnabled = true
        }
        let nameSuggestsImageGeneration = shouldUseDirectImageGeneration(modelId: model.id)
            || shouldPreferChatNativeImageGeneration(modelId: model.id)

        if (model.supportsImageGeneration
            || (defaults.contains("image_generation") && isTruthy("image_generation"))
            || nameSuggestsImageGeneration)
            && !userDisabledBuiltinFeatures.contains("image_generation") {
            imageGenerationEnabled = true
        }
        if defaults.contains("code_interpreter") && isTruthy("code_interpreter")
            && !userDisabledBuiltinFeatures.contains("code_interpreter") {
            codeInterpreterEnabled = true
        }

        // Add model-assigned tools (admin attached to this model) that aren't
        // user-disabled and aren't already selected.
        for toolId in model.toolIds {
            if !userDisabledToolIds.contains(toolId) {
                selectedToolIds.insert(toolId)
            }
        }

        // Add any globally-enabled tools (is_active) that aren't user-disabled.
        for tool in availableTools where tool.isEnabled {
            if !userDisabledToolIds.contains(tool.id) {
                selectedToolIds.insert(tool.id)
            }
        }
    }

    /// Memory is local-first, so it does not depend on a provider/backend memory tool.
    /// The app injects saved memories into the request context when enabled.
    var isMemoryAvailable: Bool {
        true
    }

    /// Syncs the UI toggles (web search pill, selected tools) with the selected
    /// model's server-configured defaults. Matches the Iexa native server web client's
    /// `setDefaults()` which pre-enables features and tools from model metadata.
    ///
    /// Called on:
    /// - Initial model load (`loadModels`)
    /// - Model switch (`selectModel`)
    /// - New conversation (`startNewConversation`)
    private func syncUIWithModelDefaults() {
        guard let model = selectedModel else { return }
        let defaults = model.defaultFeatureIds
        let caps = model.capabilities ?? [:]

        func isTruthy(_ key: String) -> Bool {
            guard let value = caps[key] else { return false }
            return ["1", "true"].contains(value.lowercased())
        }

        // Reset all feature toggles to match THIS model's config.
        // Each toggle is set to true only if the model has it as a
        // default AND the capability is enabled. This ensures switching
        // models correctly reflects per-model feature availability.
        // Suppress tracking so these internal resets don't pollute userDisabledBuiltinFeatures.
        suppressBuiltinFeatureTracking = true
        webSearchEnabled = isChatWebSearchAllowed
        let nameSuggestsImageGeneration = shouldUseDirectImageGeneration(modelId: model.id)
            || shouldPreferChatNativeImageGeneration(modelId: model.id)
        imageGenerationEnabled = model.supportsImageGeneration
            || (defaults.contains("image_generation") && isTruthy("image_generation"))
            || nameSuggestsImageGeneration
        codeInterpreterEnabled = defaults.contains("code_interpreter") && isTruthy("code_interpreter")
        suppressBuiltinFeatureTracking = false

        // Memory is local-first. Fetch the local setting once for all models.
        Task { await fetchMemorySettingFromServer() }

        // Reset and re-populate tool selections for this model.
        // Clear first so tools from a previous model don't persist.
        selectedToolIds = []
        if !model.toolIds.isEmpty {
            for toolId in model.toolIds {
                selectedToolIds.insert(toolId)
            }
        }
        // Also re-add globally-enabled tools (server admin marked as active)
        for tool in availableTools where tool.isEnabled {
            selectedToolIds.insert(tool.id)
        }
    }

    /// Fetches the user's local memory preference.
    func fetchMemorySettingFromServer() async {
        if let cached = activeChatStore?.cachedMemorySetting {
            memoryEnabled = cached
            return
        }
        guard let manager else { return }
        let enabled = await LocalMemoryStore.shared.isEnabled(serverURL: manager.baseURL)
        memoryEnabled = enabled
        activeChatStore?.cachedMemorySetting = enabled
    }

    /// Persists the memory toggle state locally.
    func updateMemorySettingOnServer(enabled: Bool) {
        guard let manager else { return }
        Task {
            await LocalMemoryStore.shared.setEnabled(enabled, serverURL: manager.baseURL)
            self.activeChatStore?.cachedMemorySetting = enabled
        }
    }

    // MARK: - Pinned Models

    /// Fetches the user's pinned model IDs from the server.
    ///
    /// Reads `ui.pinnedModels` from `GET /api/v1/users/user/settings`.
    /// Uses session-level cache to avoid redundant fetches.
    func fetchPinnedModels() async {
        // Use session-level cache
        if let cached = activeChatStore?.cachedPinnedModelIds {
            pinnedModelIds = cached
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let settings = try await apiClient.getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let pinned = ui["pinnedModels"] as? [String] {
                pinnedModelIds = pinned
                activeChatStore?.cachedPinnedModelIds = pinned
                logger.debug("Pinned models fetched: \(pinned)")
            }
        } catch {
            logger.debug("Failed to fetch pinned models: \(error.localizedDescription)")
        }
    }

    /// Toggles a model's pinned state and syncs to the server.
    ///
    /// Calls `POST /api/v1/users/user/settings/update` with
    /// `{"ui": {"models": [...], "pinnedModels": [...]}}` matching the web UI format.
    func togglePinModel(_ modelId: String) {
        if pinnedModelIds.contains(modelId) {
            pinnedModelIds.removeAll { $0 == modelId }
        } else {
            pinnedModelIds.append(modelId)
        }
        // Update cache immediately
        activeChatStore?.cachedPinnedModelIds = pinnedModelIds

        // Sync to server (fire-and-forget).
        // Use merge helper so we ONLY update `pinnedModels` — previously this
        // also wrote `models` (the default model key) with the pinned IDs array,
        // which overwrote the user's default model selection on every pin action.
        let currentPinned = pinnedModelIds
        guard let apiClient = manager?.apiClient else { return }
        Task {
            do {
                try await apiClient.mergeUserUISettings(["pinnedModels": currentPinned])
                logger.debug("Pinned models saved to server: \(currentPinned)")
            } catch {
                logger.debug("Failed to save pinned models: \(error.localizedDescription)")
            }
        }
    }

    /// Populates all common request fields that are shared across sendMessage,
    /// regenerateResponse, and regenerateIntoExistingMessage.
    ///
    /// This is the single source of truth for:
    /// - model metadata (modelItem, filterIds, isPipeModel)
    /// - features, params (system prompt + function_calling)
    /// - stream_options, variables (system vars + substitution into system prompt)
    /// - toolIds, skillIds, terminalId, backgroundTasks
    ///
    /// Call this after constructing the basic ChatCompletionRequest and before sending.
    private func populateCommonRequestFields(_ request: inout ChatCompletionRequest) async {
        // Refresh model metadata to pick up live admin changes
        await refreshSelectedModelMetadata()
        request.modelItem = selectedModel?.rawModelItem

        // Flag pipe/function models so toJSON() omits session_id/chat_id/id
        if selectedModel?.isPipeModel == true {
            request.isPipeModel = true
        }

        // Filter IDs from model's server-configured filter list
        let filterIds = selectedModel?.filterIds ?? []
        if !filterIds.isEmpty { request.filterIds = filterIds }

        // Always send the full features object with explicit true/false values
        request.features = buildChatFeatures()

        // Await any pending model config fetch (ensures functionCallingMode is populated)
        await modelConfigTask?.value

        // Build request params: chat-level overrides + system prompt + function_calling
        var params: [String: Any] = [:]
        if let chatP = conversation?.chatParams {
            params = chatP.mergedOver(base: params)
        }
        let effectiveSP: String? = {
            if let cp = conversation?.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            return conversation?.systemPrompt
        }()
        if let sp = effectiveSP, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            params["system"] = sp
        }
        let localAlpineClientSideTask = terminalEnabled && selectedTerminalIsLocalAlpine

        if localAlpineClientSideTask {
            params.removeValue(forKey: "function_calling")
            params.removeValue(forKey: "tool_choice")
            params.removeValue(forKey: "tools")
            Self.applyLocalAlpineOutputTokenCap(to: &params)
            let nativeToolsDisabled = request.toolChoice?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "none"
            if shouldUseLocalAlpineNativeTools(for: request.model), request.tools == nil, !nativeToolsDisabled {
                request.tools = Self.localAlpineNativeToolSchemas()
                request.toolChoice = "auto"
            }
            if var modelItem = request.modelItem,
               var info = modelItem["info"] as? [String: Any],
               var modelParams = info["params"] as? [String: Any] {
                modelParams.removeValue(forKey: "function_calling")
                info["params"] = modelParams
                modelItem["info"] = info
                request.modelItem = modelItem
            }
            request.toolIds = []
            request.toolServers = []
            request.terminalId = nil
        }

        applyOpenAIResponsesNativeTools(to: &request)

        if let fc = selectedModel?.functionCallingMode, fc == "native", !localAlpineClientSideTask {
            params["function_calling"] = "native"
        }
        if !params.isEmpty { request.params = params }

        // Always include usage stats in streaming response
        request.streamOptions = ["include_usage": true]

        // Build and merge system variables ({{USER_LOCATION}}, {{USER_NAME}}, etc.)
        // Keys use {{VARIABLE_NAME}} format — the server does literal find-and-replace
        // on the model's system prompt. Also nested in metadata.variables (where the
        // server's apply_system_prompt_to_body() actually reads them).
        let sysVars = PromptService.buildSystemVariablesDict(
            userName: activeChatStore?.cachedUserName,
            userEmail: activeChatStore?.cachedUserEmail
        )
        var mergedVars = request.variables ?? [:]
        for (k, v) in sysVars { mergedVars[k] = v }
        request.variables = mergedVars

        // Also substitute directly into the overridden system prompt string.
        // The server uses params.system as-is without re-substituting variables,
        // so we must resolve them here for client-side system prompt overrides.
        if let rawSP = params["system"] as? String {
            var resolved = rawSP
            for (placeholder, value) in sysVars {
                if let strValue = value as? String {
                    resolved = resolved.replacingOccurrences(of: placeholder, with: strValue)
                }
            }
            if resolved != rawSP {
                params["system"] = resolved
                request.params = params
            }
        }

        // Tool IDs (user selection respects manual toggles via userDisabledToolIds)
        let allToolIds = localAlpineClientSideTask ? [] : Array(selectedToolIds)
        if !allToolIds.isEmpty { request.toolIds = allToolIds }

        // Terminal ID if enabled
        if terminalEnabled, let terminalServer = selectedTerminalServer, !terminalServer.isLocalAlpine {
            request.terminalId = terminalServer.id
        }

        // Background tasks — respect both server config and user settings.
        // Web search is handled on-device by ClientWebSearchService.
        // Do not ask the server to run its older web_search task; it produces stale
        // results and can race the local search context.
        let serverConfig = activeChatStore?.serverTaskConfig ?? .default
        let titleGenEnabled = (UserDefaults.standard.object(forKey: "titleGenerationEnabled") as? Bool ?? true)
            && serverConfig.enableTitleGeneration
        let suggestionsEnabled = (UserDefaults.standard.object(forKey: "suggestionsEnabled") as? Bool ?? true)
            && serverConfig.enableFollowUpGeneration
        let tagsEnabled = serverConfig.enableTagsGeneration
        let isFirst = (conversation?.messages.filter { !$0.isStreaming }.count ?? 0) <= 2

        var bgTasks: [String: Any] = [:]
        if suggestionsEnabled { bgTasks["follow_up_generation"] = true }
        if isFirst && titleGenEnabled { bgTasks["title_generation"] = true }
        if isFirst && tagsEnabled { bgTasks["tags_generation"] = true }
        if !bgTasks.isEmpty { request.backgroundTasks = bgTasks }
    }

    private static func applyLocalAlpineOutputTokenCap(to params: inout [String: Any]) {
        let cap = 8_192
        let keys = ["max_tokens", "max_completion_tokens", "max_output_tokens"]
        var foundExisting = false
        for key in keys {
            guard let existing = params[key] else { continue }
            foundExisting = true
            if let value = numericTokenLimit(existing), value > cap {
                params[key] = cap
            }
        }
        if !foundExisting {
            params["max_tokens"] = cap
        }
    }

    private static func numericTokenLimit(_ value: Any) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    /// Builds chat features by merging user toggles with the model's admin-configured
    /// default features. Matches the Iexa native server web client's `setDefaults()` + `getFeatures()`.
    ///
    /// Memory is local-first in the app: saved memories are injected into the
    /// request context by `localMemorySystemContext()`, so we do not rely on a
    /// provider/backend memory tool being available.
    private func buildChatFeatures() -> ChatCompletionRequest.ChatFeatures {
        var features = ChatCompletionRequest.ChatFeatures()
        let modelAllowsImageGeneration = selectedModel.map {
            Self.modelSupportsBuiltinFeature($0, key: "image_generation")
        } ?? false
        let modelNameSuggestsImageGeneration = selectedModelId.map {
            shouldUseDirectImageGeneration(modelId: $0) || shouldPreferChatNativeImageGeneration(modelId: $0)
        } ?? false
        let shouldEnableImageGeneration = !userDisabledBuiltinFeatures.contains("image_generation")
            && (imageGenerationEnabled || modelAllowsImageGeneration || modelNameSuggestsImageGeneration)

        // Use ONLY the current toggle state. Server defaults are already applied
        // to these toggles at init time via syncUIWithModelDefaults() — which runs
        // on model load, model switch, and new-conversation. By the time we build
        // the request, the toggle reflects either the server default OR the user's
        // explicit override. Checking server defaults again here would ignore the
        // user toggling a feature OFF mid-chat (the original bug).
        // Keep server-side web_search disabled. The UI toggle now means
        // "inject client-side browser search context before sending".
        features.webSearch = false
        if shouldEnableImageGeneration {
            features.imageGeneration = true
        }
        if codeInterpreterEnabled {
            features.codeInterpreter = true
        }
        features.memory = false

        return features
    }

    private func applyOpenAIResponsesNativeTools(to request: inout ChatCompletionRequest) {
        guard currentProviderType == .openAICompatible else { return }
        guard !(terminalEnabled && selectedTerminalIsLocalAlpine) else { return }
        guard request.tools?.isEmpty != false else { return }

        var tools: [[String: Any]] = []

        // Web search is handled by the local WKWebView browser pipeline so the
        // app can show clickable source cards and thumbnails consistently.

        if shouldEnableOpenAIResponsesImageGenerationTool(modelId: request.model) {
            tools.append(["type": "image_generation"])
            if Self.looksLikeImageGenerationRequest(Self.lastUserText(in: request.messages)) {
                request.responsesToolChoice = ["type": "image_generation"]
            }
        }

        if codeInterpreterEnabled {
            tools.append([
                "type": "code_interpreter",
                "container": ["type": "auto"]
            ])
        }

        guard !tools.isEmpty else { return }
        request.responsesTools = tools
        if request.responsesToolChoice == nil {
            request.responsesToolChoice = "auto"
        }
    }

    private func shouldEnableOpenAIResponsesImageGenerationTool(modelId: String) -> Bool {
        guard imageGenerationEnabled else { return false }
        if selectedModel?.supportsImageGeneration == true { return true }
        if selectedModel?.defaultFeatureIds.contains("image_generation") == true { return true }
        if selectedModel?.builtinTools["image_generation"] == true { return true }
        return shouldPreferChatNativeImageGeneration(modelId: modelId)
    }

    private static func lastUserText(in messages: [[String: Any]]) -> String {
        guard let message = messages.last(where: {
            (($0["role"] as? String)?.lowercased() ?? "") == "user"
        }) else {
            return ""
        }
        return renderedText(from: message["content"])
    }

    private static func renderedText(from value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String { return text }
            if let content = dict["content"] { return renderedText(from: content) }
            return ""
        }
        if let array = value as? [Any] {
            return array.map { renderedText(from: $0) }.joined(separator: "\n")
        }
        return "\(value)"
    }

    private static func modelSupportsBuiltinFeature(_ model: AIModel, key: String) -> Bool {
        guard key == "image_generation" else {
            if model.defaultFeatureIds.contains(key) { return true }
            if model.builtinTools[key] == true { return true }
            if let value = model.capabilities?[key]?.lowercased(),
               ["1", "true", "yes", "enabled"].contains(value) {
                return true
            }
            return false
        }
        return model.supportsImageGeneration
    }

    private var canUseDirectImageEndpointProvider: Bool {
        guard let providerType = currentProviderType else { return false }
        return providerType != .anthropic
    }

    private var canUseDirectVideoEndpointProvider: Bool {
        guard let providerType = currentProviderType else { return false }
        return providerType != .iexa && providerType != .anthropic
    }

    private func canStartIndependentDirectMediaGeneration(modelId: String) -> Bool {
        (canUseDirectVideoEndpointProvider && shouldUseDirectVideoGeneration(modelId: modelId))
            || (canUseDirectImageEndpointProvider
                && shouldUseDirectImageGeneration(modelId: modelId)
                && !shouldPreferChatNativeImageGeneration(modelId: modelId))
    }

    private func shouldUseDirectImageGeneration(modelId: String) -> Bool {
        let haystack = "\(modelId) \(selectedModel?.name ?? "") \(selectedModel?.tags.joined(separator: " ") ?? "")"
            .lowercased()
        let directEndpointTokens = [
            "gpt-image", "dall-e", "dalle", "flux", "sdxl",
            "stable-diffusion", "midjourney", "mj-", "minimax-image",
            "qwen-image", "imagen", "seedream", "jimeng", "kolors",
            "grok-imagine", "imagine-image", "image-lite", "plus-image",
            "image-01", "image-02", "image-03", "image-generation"
        ]
        let chatModelTokens = [
            "gpt-5", "gpt-4", "gpt-3", "claude", "gemini", "qwen3",
            "qwen-plus", "qwen-max", "grok-4", "grok-3", "mini",
            "chat", "reasoning", "vision", "vl", "ocr"
        ]
        let endpointStyleImageName = haystack
            .split(whereSeparator: \.isWhitespace)
            .contains { token in
                token.hasSuffix("-image")
                    || token.hasSuffix("_image")
                    || token.hasSuffix(".image")
            }
        if directEndpointTokens.contains(where: { haystack.contains($0) }) || endpointStyleImageName {
            return true
        }
        if chatModelTokens.contains(where: { haystack.contains($0) }) {
            return false
        }
        if let selectedModel,
           selectedModel.defaultFeatureIds.contains("image_generation")
            || selectedModel.builtinTools["image_generation"] == true {
            return false
        }
        return false
    }

    private func shouldPreferChatNativeImageGeneration(modelId: String) -> Bool {
        let haystack = "\(modelId) \(selectedModel?.name ?? "") \(selectedModel?.description ?? "") \(selectedModel?.tags.joined(separator: " ") ?? "")"
            .lowercased()

        // These are usually image-only OpenAI-compatible endpoints.
        let directEndpointModels = [
            "gpt-image", "dall-e", "dalle", "flux", "sdxl",
            "stable-diffusion", "midjourney", "mj-",
            "minimax-image", "qwen-image", "seedream", "jimeng",
            "kolors", "grok-imagine", "imagine-image", "image-lite", "plus-image"
        ]
        let endpointStyleImageName = haystack
            .split(whereSeparator: \.isWhitespace)
            .contains { token in
                token.hasSuffix("-image")
                    || token.hasSuffix("_image")
                    || token.hasSuffix(".image")
            }
        if directEndpointModels.contains(where: { haystack.contains($0) }) || endpointStyleImageName {
            return false
        }

        // Some providers expose image generation through chat completions, but
        // plain chat models (grok/qwen/etc.) must not be treated as image models
        // just because the user mentions "图片" in the prompt.
        if haystack.contains("gemini") && (haystack.contains("image") || haystack.contains("banana")) {
            return true
        }
        if haystack.contains("qwen")
            && (haystack.contains("image") || haystack.contains("imagen") || haystack.contains("图像") || haystack.contains("生图")) {
            return true
        }
        if haystack.contains("grok")
            && (haystack.contains("imagine") || haystack.contains("image") || haystack.contains("图像") || haystack.contains("生图")) {
            return true
        }
        return false
    }

    private func shouldUseDirectVideoGeneration(modelId: String) -> Bool {
        let haystack = "\(modelId) \(selectedModel?.name ?? "") \(selectedModel?.description ?? "") \(selectedModel?.tags.joined(separator: " ") ?? "")"
            .lowercased()
        let positives = [
            "video", "videos", "veo", "sora", "wan", "kling", "hailuo",
            "runway", "luma", "pika", "vidu", "seedance", "minimax-video",
            "qwen-video", "wanx", "hunyuan-video", "cogvideo", "jimeng",
            "即梦", "可灵", "海螺", "文生视频", "图生视频",
            "text-to-video", "image-to-video", "i2v", "t2v", "生视频", "视频生成"
        ]
        let negatives = ["vision", "ocr", "vl", "video-chat", "videochat"]
        return positives.contains(where: { haystack.contains($0) })
            && !negatives.contains(where: { haystack.contains($0) })
    }

    private func firstEditableImage(from attachments: [ChatAttachment]) -> (data: Data, fileName: String)? {
        guard let image = editableImages(from: attachments, limit: 1).first else { return nil }
        return (image.data, image.fileName)
    }

    private func editableImages(from attachments: [ChatAttachment], limit: Int = 16) -> [ImageEditSource] {
        var images: [ImageEditSource] = []
        for attachment in attachments where attachment.type == .image {
            let outputFileName = Self.jpegFileName(for: attachment.name)
            if let data = attachment.data {
                let jpegData = FileAttachmentService.downsampleForUpload(data: data)
                images.append(ImageEditSource(data: jpegData.isEmpty ? data : jpegData, fileName: outputFileName))
            } else if let dataURL = attachment.displayDataURL,
                      let data = Self.imageData(fromDataURL: dataURL) {
                let jpegData = FileAttachmentService.downsampleForUpload(data: data)
                images.append(ImageEditSource(data: jpegData.isEmpty ? data : jpegData, fileName: outputFileName))
            }
            if images.count >= limit {
                break
            }
        }
        return images
    }

    private static func jpegFileName(for originalName: String) -> String {
        let base = (originalName as NSString).deletingPathExtension
        let safeBase = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "image" : base
        return safeBase + ".jpg"
    }

    private static func imageData(fromDataURL dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:image/"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let encoded = dataURL[dataURL.index(after: comma)...]
        guard encoded.utf8.count <= 24_000_000 else { return nil }
        guard let data = Data(base64Encoded: String(encoded), options: .ignoreUnknownCharacters),
              data.count <= 18_000_000 else {
            return nil
        }
        return data
    }

    private static func compactImageDataURI(_ dataURI: String) -> String? {
        let normalized = normalizedImageDataURI(dataURI)
        guard let normalized,
              normalized.hasPrefix("data:image/"),
              let comma = normalized.firstIndex(of: ",") else {
            return nil
        }
        let header = String(normalized[..<normalized.index(after: comma)])
        let body = normalized[normalized.index(after: comma)...]
        guard body.utf8.count <= 24_000_000 else { return nil }

        var compactBody = ""
        compactBody.reserveCapacity(min(body.count, 24_000_000))
        for character in body where !character.isWhitespace {
            guard isBase64PayloadCharacter(character) else { return nil }
            compactBody.append(character)
        }
        guard compactBody.count >= 128 else { return nil }
        return header + compactBody
    }

    private static func isBase64PayloadCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 43, 47, 61, 95, 45:
            return true
        default:
            return false
        }
    }

    private static func requestedImageSize(from prompt: String) -> String {
        imageEndpointSize(for: requestedImageCanvasSize(from: prompt))
    }

    private static func requestedImageCanvasSize(from prompt: String) -> String {
        let defaultSize = "1024x1024"
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return defaultSize }

        if let exactSize = firstExactImageSize(in: text) {
            return exactSize
        }

        if let aspectSize = firstAspectRatioSize(in: text) {
            return aspectSize
        }

        let lowercased = text.lowercased()
        let squareScore = keywordScore(
            in: lowercased,
            keywords: ["方图", "正方形", "头像", "logo", "标志", "图标", "app icon", "icon", "贴纸", "表情包", "专辑封面", "album cover", "square"]
        )
        let portraitScore = keywordScore(
            in: lowercased,
            keywords: ["竖屏", "纵向", "手机壁纸", "手机", "锁屏", "海报", "人像", "肖像", "半身", "全身", "人物", "角色", "女孩", "男孩", "女生", "男生", "模特", "穿搭", "服装", "portrait", "poster", "phone wallpaper", "story", "vertical"]
        )
        let landscapeScore = keywordScore(
            in: lowercased,
            keywords: ["横屏", "宽屏", "全景", "风景", "场景", "城市", "建筑", "汽车", "跑车", "车辆", "小米 su7", "su7", "山脉", "海边", "湖边", "街景", "电影感", "剧照", "桌面壁纸", "电脑壁纸", "landscape", "wide", "widescreen", "panorama", "cinematic", "banner", "vehicle", "automotive", "desktop wallpaper"]
        )

        if squareScore > 0 && portraitScore == 0 && landscapeScore == 0 {
            return defaultSize
        }
        if portraitScore > landscapeScore {
            return "1024x1792"
        }
        if landscapeScore > portraitScore {
            return "1792x1024"
        }
        if squareScore > 0 {
            return defaultSize
        }

        return stableImageCanvasSizeFallback(for: text)
    }

    private static func keywordScore(in text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { score, keyword in
            score + (text.contains(keyword) ? 1 : 0)
        }
    }

    private static func stableImageCanvasSizeFallback(for text: String) -> String {
        let choices = ["1024x1024", "1792x1024", "1024x1792"]
        var hash: UInt64 = 1469598103934665603
        for byte in text.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return choices[Int(hash % UInt64(choices.count))]
    }

    private static func imageEndpointSize(for canvasSize: String) -> String {
        let parts = canvasSize.split(separator: "x", maxSplits: 1).compactMap { Double(String($0)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            return "1024x1024"
        }

        let ratio = parts[0] / parts[1]
        if abs(ratio - 1.0) < 0.08 {
            return "1024x1024"
        }
        return ratio > 1.0 ? "1792x1024" : "1024x1792"
    }

    private static func firstExactImageSize(in text: String) -> String? {
        let pattern = #"(?<!\d)(\d{2,5})\s*[xX×＊*]\s*(\d{2,5})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text),
              let width = Int(String(text[widthRange])),
              let height = Int(String(text[heightRange])),
              (64...4096).contains(width),
              (64...4096).contains(height)
        else { return nil }
        return "\(width)x\(height)"
    }

    private static func firstAspectRatioSize(in text: String) -> String? {
        let pattern = #"(?<!\d)(\d{1,3})\s*[:：]\s*(\d{1,3})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text),
              let width = Double(String(text[widthRange])),
              let height = Double(String(text[heightRange])),
              width > 0,
              height > 0
        else { return nil }

        let ratio = width / height
        if abs(ratio - 1.0) < 0.08 {
            return "1024x1024"
        }
        return ratio > 1.0 ? "1792x1024" : "1024x1792"
    }

    private static func promptWithImageSizeInstruction(_ prompt: String, canvasSize: String, endpointSize: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactRequirement = canvasSize == endpointSize
            ? "exactly \(canvasSize) pixels"
            : "\(canvasSize) pixels, preserving that aspect ratio"
        return """
        \(trimmed)

        Canvas requirement: generate the image at \(exactRequirement). Do not crop into a square unless the requested size is square.
        """
    }

    private static func requestedImageCount(from prompt: String) -> Int {
        let maxImageCount = 9
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 1 }
        let patterns = [
            #"(?<!\d)(\d{1,2})\s*(?:张|幅|个|款|版|images?|pictures?|pics?|photos?|variants?|versions?)(?!\w)"#,
            #"(?:生成|画|绘制|做|create|generate|make|draw)\s*(\d{1,2})\s*(?:张|幅|个|款|版|images?|pictures?|pics?|photos?|variants?|versions?)(?!\w)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: nsRange),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: text),
               let count = Int(String(text[range])) {
                return min(max(count, 1), maxImageCount)
            }
        }

        let chineseNumbers: [(String, Int)] = [
            ("十", 10), ("九", 9), ("八", 8), ("七", 7), ("六", 6),
            ("五", 5), ("四", 4), ("三", 3), ("两", 2), ("二", 2), ("一", 1)
        ]
        for (token, value) in chineseNumbers where containsChineseImageCountToken(text, token: token) {
            return min(max(value, 1), maxImageCount)
        }
        return 1
    }

    private static func containsChineseImageCountToken(_ text: String, token: String) -> Bool {
        ["张", "幅", "个", "款", "版"].contains { suffix in
            text.contains("\(token)\(suffix)")
        }
    }

    private static func imageVariantPrompts(basePrompt: String, requestedCount: Int) -> [String] {
        let count = min(max(requestedCount, 1), 9)
        guard count > 1 else { return [basePrompt] }
        return (1...count).map { index in
            """
            \(basePrompt)

            Variant \(index) of \(count): create a distinct image, not a duplicate. Keep the user's core subject and requirements, but vary composition, camera angle, lighting, background details, color accents, and small visual details from the other variants.
            """
        }
    }

    private static func looksLikeImageGenerationRequest(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let keywords = [
            "生图", "生成图", "生成一张", "生成图片", "生成图像", "画一张", "画个", "绘制", "做一张",
            "图片", "图像", "照片", "插画", "海报", "壁纸", "头像", "logo",
            "generate an image", "create an image", "make an image", "draw", "illustration", "poster", "wallpaper", "photo"
        ]
        return keywords.contains { lowercased.contains($0) }
    }

    private static func requestedVideoDuration(from prompt: String) -> Int? {
        let pattern = #"(?<!\d)(\d{1,3})\s*(秒|s|sec|seconds)(?![A-Za-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = regex.firstMatch(in: prompt, range: nsRange),
              let range = Range(match.range(at: 1), in: prompt),
              let seconds = Int(String(prompt[range]))
        else { return nil }
        return min(max(seconds, 1), 60)
    }

    private func runImageRequestWithRateLimitRetry(
        maxAttempts: Int = 3,
        operation: @escaping () async throws -> String
    ) async throws -> String {
        try await runMediaRequestWithRetry(maxAttempts: maxAttempts, operation: operation)
    }

    private func generateDirectImageSlots(
        prompts: [String],
        modelId: String,
        requestedImageSize: String,
        requestedCanvasSize: String?,
        editImages: [ImageEditSource],
        manager: ConversationManager,
        originalPromptWasEmpty: Bool
    ) async throws -> [GeneratedImageSlot] {
        guard !prompts.isEmpty else { return [] }
        if editImages.isEmpty && originalPromptWasEmpty {
            throw APIError.unknown(
                underlying: NSError(
                    domain: "ChatViewModel",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "请输入图片生成提示词。"]
                )
            )
        }

        let maxConcurrent = min(Self.directImageGenerationMaxConcurrency, prompts.count)
        var iterator = prompts.enumerated().makeIterator()
        var slots = Array(repeating: GeneratedImageSlot.failure, count: prompts.count)

        try await withThrowingTaskGroup(of: (Int, Result<String, Error>).self) { group in
            for _ in 0..<maxConcurrent {
                guard let next = iterator.next() else { break }
                let index = next.offset
                let prompt = next.element
                group.addTask { [manager, editImages] in
                    let result = await Self.generateDirectImageReference(
                        prompt: prompt,
                        modelId: modelId,
                        requestedImageSize: requestedImageSize,
                        editImages: editImages,
                        manager: manager
                    )
                    return (index, result)
                }
            }

            while let (index, result) = try await group.next() {
                switch result {
                case .success(let imageReference):
                    let displayReference = await localDisplayImageReference(
                        from: imageReference,
                        canvasSize: requestedCanvasSize
                    ) ?? imageReference
                    slots[index] = .image(imageReference: imageReference, displayReference: displayReference)
                case .failure(let error):
                    if Task.isCancelled || error is CancellationError {
                        throw error
                    }
                    slots[index] = .failure
                    self.logger.warning("One image generation request failed: \(error.localizedDescription)")
                }

                if let next = iterator.next() {
                    let index = next.offset
                    let prompt = next.element
                    group.addTask { [manager, editImages] in
                        let result = await Self.generateDirectImageReference(
                            prompt: prompt,
                            modelId: modelId,
                            requestedImageSize: requestedImageSize,
                            editImages: editImages,
                            manager: manager
                        )
                        return (index, result)
                    }
                }
            }
        }

        return slots
    }

    nonisolated private static func generateDirectImageReference(
        prompt: String,
        modelId: String,
        requestedImageSize: String,
        editImages: [ImageEditSource],
        manager: ConversationManager
    ) async -> Result<String, Error> {
        do {
            try Task.checkCancellation()
            let imageReference: String
            if editImages.isEmpty {
                imageReference = try await runDirectImageRequestWithRetry {
                    try await manager.generateImage(
                        prompt: prompt,
                        model: modelId,
                        size: requestedImageSize
                    )
                }
            } else {
                imageReference = try await runDirectImageRequestWithRetry {
                    try await manager.editImage(
                        prompt: prompt,
                        model: modelId,
                        images: editImages,
                        size: requestedImageSize
                    )
                }
            }
            return .success(imageReference)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func runDirectImageRequestWithRetry(
        maxAttempts: Int = 3,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard directImageErrorIsRetryable(error),
                      attempt < maxAttempts - 1 else { throw error }
                let delay = min(18.0, 3.0 * pow(2.0, Double(attempt)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? APIError.unknown(underlying: nil)
    }

    nonisolated private static func directImageErrorIsRetryable(_ error: Error) -> Bool {
        if let apiError = error as? APIError,
           case .httpError(let statusCode, let message, _) = apiError {
            return statusCode == 429 || (message?.localizedCaseInsensitiveContains("too many") == true)
        }
        if error.localizedDescription.localizedCaseInsensitiveContains("too many requests") {
            return true
        }
        let apiError = APIError.from(error)
        guard apiError.isRetryable else { return false }
        if case .networkError(let underlying) = apiError,
           let urlError = underlying as? URLError {
            return [.networkConnectionLost, .timedOut].contains(urlError.code)
        }
        return true
    }

    private func runMediaRequestWithRetry(
        maxAttempts: Int = 3,
        operation: @escaping () async throws -> String
    ) async throws -> String {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard (isRateLimitError(error) || isTransientMediaNetworkError(error)),
                      attempt < maxAttempts - 1 else { throw error }
                let delay = min(18.0, 3.0 * pow(2.0, Double(attempt)))
                logger.warning("Media endpoint failed with retryable error; retrying in \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? APIError.unknown(underlying: nil)
    }

    private func isRateLimitError(_ error: Error) -> Bool {
        if let apiError = error as? APIError,
           case .httpError(let statusCode, let message, _) = apiError {
            return statusCode == 429 || (message?.localizedCaseInsensitiveContains("too many") == true)
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("too many requests")
    }

    private func isTransientMediaNetworkError(_ error: Error) -> Bool {
        let apiError = APIError.from(error)
        if case .cancelled = apiError {
            return UIApplication.shared.applicationState != .active
        }
        guard apiError.isRetryable else { return false }
        if case .networkError(let underlying) = apiError,
           let urlError = underlying as? URLError {
            return [.networkConnectionLost, .timedOut].contains(urlError.code)
        }
        return false
    }

    private func localDisplayImageReference(from imageReference: String, canvasSize: String? = nil) async -> String? {
        if let normalized = Self.normalizedImageDataURI(imageReference) {
            let resized = Self.resizedImageDataURL(from: normalized, canvasSize: canvasSize) ?? normalized
            guard let compact = Self.compactImageDataURI(resized) else { return nil }
            return Self.writeGeneratedImageToCache(dataURL: compact)
        }
        return nil
    }

    private static func writeGeneratedImageToCache(dataURL: String) -> String? {
        guard let data = imageData(fromDataURL: dataURL) else { return nil }
        let contentType = imageContentType(for: dataURL)
        let fileExtension = fileExtension(forImageContentType: contentType)
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("iexa-generated-images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("\(stableImageHash(data)).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: [.atomic])
            }
            return fileURL.absoluteString
        } catch {
            return nil
        }
    }

    private static func stableImageHash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func resizedImageDataURL(from dataURL: String, canvasSize: String?) -> String? {
        guard let canvasSize,
              let size = imagePixelSize(from: canvasSize),
              let data = imageData(fromDataURL: dataURL),
              let image = UIImage(data: data),
              size.width > 0,
              size.height > 0
        else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let pngData = resized.pngData() else { return nil }
        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }

    private static func imagePixelSize(from size: String) -> CGSize? {
        let parts = size.split(separator: "x", maxSplits: 1).compactMap { Double(String($0)) }
        guard parts.count == 2,
              (64...4096).contains(parts[0]),
              (64...4096).contains(parts[1])
        else { return nil }
        return CGSize(width: CGFloat(parts[0]), height: CGFloat(parts[1]))
    }

    private func attachGeneratedImageFile(
        messageId: String,
        imageReference: String,
        displayReference: String
    ) {
        let normalizedImageData = Self.normalizedImageDataURI(imageReference)
        let normalizedDisplayData = Self.normalizedImageDataURI(displayReference)
        let localDisplayReference = (normalizedDisplayData ?? normalizedImageData).flatMap {
            Self.compactImageDataURI($0).flatMap { compactDataURL in
                Self.writeGeneratedImageToCache(dataURL: compactDataURL)
            }
        }
        let resolvedDisplayReference = localDisplayReference ?? displayReference
        let contentType = Self.imageContentType(for: normalizedDisplayData ?? normalizedImageData ?? resolvedDisplayReference)
        let safeURL = normalizedImageData != nil ? resolvedDisplayReference : imageReference
        let fileName = Self.imageFileName(for: displayReference, contentType: contentType)
        let rawFile = ChatMessageFile(
            type: "image",
            url: safeURL,
            name: fileName,
            contentType: contentType,
            displayURL: resolvedDisplayReference
        )
        guard let file = Self.sanitizedMessageFile(rawFile) else { return }
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if conversation?.messages[index].files.contains(where: {
            $0.url == file.url || $0.displayURL == file.displayURL
        }) != true {
            conversation?.messages[index].files.append(file)
        }
        conversation?.history.updateNode(id: messageId) { node in
            if !node.files.contains(where: { $0.url == file.url || $0.displayURL == file.displayURL }) {
                node.files.append(file)
            }
        }
    }

    private func attachGeneratedImageFailurePlaceholder(messageId: String, index: Int) {
        let file = ChatMessageFile.generatedImageFailurePlaceholder(index: index)
        guard let messageIndex = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if conversation?.messages[messageIndex].files.contains(where: { $0.url == file.url }) != true {
            conversation?.messages[messageIndex].files.append(file)
        }
        conversation?.history.updateNode(id: messageId) { node in
            if !node.files.contains(where: { $0.url == file.url }) {
                node.files.append(file)
            }
        }
    }

    private func shouldFallbackToChatForImageGeneration(_ error: Error) -> Bool {
        let apiError = APIError.from(error)
        if case .httpError(let statusCode, _, _) = apiError {
            return [400, 404, 405, 422].contains(statusCode)
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("does not support")
            || message.contains("invalid_model")
            || message.contains("没有返回图片")
            || message.contains("no image")
            || message.contains("not support")
    }

    private static func imageContentType(for reference: String) -> String {
        let lower = reference.lowercased()
        if lower.hasPrefix("data:image/") {
            let afterPrefix = lower.dropFirst("data:".count)
            if let semicolon = afterPrefix.firstIndex(of: ";") {
                return String(afterPrefix[..<semicolon])
            }
        }
        if lower.hasPrefix("image:data/") {
            let afterPrefix = lower.dropFirst("image:data/".count)
            if let semicolon = afterPrefix.firstIndex(of: ";") {
                return "image/\(afterPrefix[..<semicolon])"
            }
        }
        if lower.contains(".png") { return "image/png" }
        if lower.contains(".webp") { return "image/webp" }
        if lower.contains(".gif") { return "image/gif" }
        if lower.contains(".avif") { return "image/avif" }
        if lower.contains(".svg") { return "image/svg+xml" }
        return "image/jpeg"
    }

    private static func imageFileName(for reference: String, contentType: String) -> String {
        if let url = URL(string: reference),
           let last = url.pathComponents.last,
           !last.isEmpty,
           last.contains(".") {
            return last
        }
        switch contentType {
        case "image/png": return "generated-image.png"
        case "image/webp": return "generated-image.webp"
        case "image/gif": return "generated-image.gif"
        case "image/avif": return "generated-image.avif"
        case "image/svg+xml": return "generated-image.svg"
        default: return "generated-image.jpg"
        }
    }

    private static func fileExtension(forImageContentType contentType: String) -> String {
        switch contentType {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/avif": return "avif"
        case "image/svg+xml": return "svg"
        default: return "jpg"
        }
    }

    private func attachGeneratedVideoFile(
        messageId: String,
        videoReference: String
    ) {
        let fileName = videoReference.hasPrefix("data:video/")
            ? "generated-video.mp4"
            : ((URL(string: videoReference)?.lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? "generated-video.mp4")
        let contentType: String = {
            let lower = fileName.lowercased()
            if lower.hasSuffix(".mov") { return "video/quicktime" }
            if lower.hasSuffix(".webm") { return "video/webm" }
            return "video/mp4"
        }()
        let file = ChatMessageFile(
            type: "video",
            url: videoReference,
            name: fileName,
            contentType: contentType,
            displayURL: nil
        )
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if conversation?.messages[index].files.contains(where: { $0.url == file.url }) != true {
            conversation?.messages[index].files.append(file)
        }
        conversation?.history.updateNode(id: messageId) { node in
            if !node.files.contains(where: { $0.url == file.url }) {
                node.files.append(file)
            }
        }
    }

    private enum GeneratedMediaKind {
        case none
        case image
        case video
    }

    private func applyUsage(_ usage: [String: Any]?, toMessageId messageId: String) {
        guard let usage, !usage.isEmpty else { return }
        if let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) {
            conversation?.messages[index].usage = usage
        }
        conversation?.history.updateNode(id: messageId) { node in
            node.usage = usage
        }
    }

    private func recordTokenUsageForCompletedTurn(
        assistantMessageId: String? = nil,
        userText: String,
        assistantText: String,
        userAttachments: [ChatAttachment],
        usage: [String: Any]? = nil,
        mediaKind: GeneratedMediaKind = .none,
        mediaCount: Int = 0
    ) {
        if let assistantMessageId {
            guard !tokenUsageRecordedMessageIds.contains(assistantMessageId) else { return }
            tokenUsageRecordedMessageIds.insert(assistantMessageId)
        }

        let exactInput = Self.firstIntValue(in: usage, keys: [
            "prompt_tokens", "input_tokens", "promptTokens", "inputTokens"
        ])
        let exactOutput = Self.firstIntValue(in: usage, keys: [
            "completion_tokens", "output_tokens", "completionTokens", "outputTokens"
        ])
        let exactCached = Self.firstIntValue(in: usage, keys: [
            "cached_tokens", "cachedTokens", "cache_read_input_tokens",
            "cacheReadInputTokens", "input_cached_tokens"
        ])

        let estimatedInput = Self.estimatedTokenCount(for: userText)
            + userAttachments.reduce(0) { total, attachment in
                total + Self.estimatedAttachmentTokens(for: attachment)
            }
        let estimatedOutput = Self.estimatedTokenCount(for: assistantText)
        let mediaTokens: Int = {
            switch mediaKind {
            case .none: return 0
            case .image: return max(1, mediaCount) * 1_500
            case .video: return max(1, mediaCount) * 12_000
            }
        }()
        let resolvedInputTokens = exactInput ?? estimatedInput
        let resolvedOutputTokens = exactOutput ?? estimatedOutput
        let resolvedCachedTokens = exactCached ?? 0
        let usageIsExact = exactInput != nil || exactOutput != nil
        let providerName = currentProviderType?.rawValue ?? "unknown"
        let usageModelName = selectedModel?.shortName ?? selectedModel?.name ?? selectedModelId ?? conversation?.model ?? "unknown"

        TokenUsageHistoryStore.shared.record(
            provider: providerName,
            model: usageModelName,
            inputTokens: resolvedInputTokens,
            outputTokens: resolvedOutputTokens,
            cachedTokens: resolvedCachedTokens,
            mediaTokens: mediaTokens,
            imageCount: mediaKind == .image ? mediaCount : 0,
            videoCount: mediaKind == .video ? mediaCount : 0,
            isExact: usageIsExact,
            usage: usage
        )
        DiagnosticLogManager.shared.info(
            "Turn completed provider=\(providerName) model=\(usageModelName) input=\(resolvedInputTokens) output=\(resolvedOutputTokens) cached=\(resolvedCachedTokens) media=\(mediaTokens) exact=\(usageIsExact)",
            category: "Chat"
        )
    }

    private static func estimatedTokenCount(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let cjkCount = trimmed.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
        let otherCount = max(0, trimmed.count - cjkCount)
        return max(1, cjkCount + Int(ceil(Double(otherCount) / 4.0)))
    }

    private static func estimatedAttachmentTokens(for attachment: ChatAttachment) -> Int {
        switch attachment.type {
        case .image:
            return 900
        case .audio:
            return estimatedTokenCount(for: attachment.transcribedText ?? "")
        case .file:
            if let data = attachment.data {
                return min(8_000, max(64, data.count / 4))
            }
            return 256
        }
    }

    private static func contextWindowTokens(for model: AIModel?, modelId: String?) -> Int {
        guard model != nil || modelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return 0
        }
        if let contextLength = LocalModelCapabilityRegistry.contextLength(for: model, modelId: modelId), contextLength > 0 {
            return contextLength
        }
        return 32_000
    }

    private static func contextStatus(
        model: AIModel?,
        modelId: String?,
        usedTokens: Int,
        isCompressed: Bool = false,
        originalTokens: Int? = nil,
        compressedTokens: Int? = nil
    ) -> ChatContextBudgetStatus {
        let window = contextWindowTokens(for: model, modelId: modelId)
        return ChatContextBudgetStatus(
            modelId: modelId ?? model?.id ?? "",
            usedTokens: usedTokens,
            windowTokens: window,
            isWindowEstimated: LocalModelCapabilityRegistry.declaredContextLength(for: model) == nil,
            isCompressed: isCompressed,
            originalTokens: originalTokens,
            compressedTokens: compressedTokens
        )
    }

    private static func estimatedTokens(in apiMessages: [[String: Any]]) -> Int {
        apiMessages.reduce(0) { total, message in
            total + 4 + estimatedTokens(inContent: message["content"])
                + estimatedTokens(inFiles: message["files"])
        }
    }

    private static func estimatedTokens(inContent content: Any?) -> Int {
        if let text = content as? String {
            return estimatedTokenCount(for: text)
        }
        if let parts = content as? [[String: Any]] {
            return parts.reduce(0) { total, part in
                if let text = part["text"] as? String {
                    return total + estimatedTokenCount(for: text)
                }
                if let image = part["image_url"] as? [String: Any],
                   let url = image["url"] as? String,
                   url.hasPrefix("data:image/") {
                    return total + 1_200
                }
                return total + 80
            }
        }
        return 0
    }

    private static func estimatedTokens(inFiles files: Any?) -> Int {
        guard let fileArray = files as? [[String: Any]] else { return 0 }
        return fileArray.count * 256
    }

    private static func contextTextForModel(
        _ text: String,
        label: String,
        maxInlineCharacters: Int
    ) -> String {
        LocalContextOffloadStore.modelText(
            label: label,
            text: text,
            maxInlineCharacters: maxInlineCharacters
        )
    }

    private static func offloadOversizedMessageContentIfNeeded(
        _ messages: [[String: Any]]
    ) -> [[String: Any]] {
        messages.map { message in
            var prepared = message
            let role = (prepared["role"] as? String) ?? "message"
            if let text = prepared["content"] as? String {
                prepared["content"] = contextTextForModel(
                    text,
                    label: "\(role)-message",
                    maxInlineCharacters: 12_000
                )
            } else if var parts = prepared["content"] as? [[String: Any]] {
                for index in parts.indices {
                    if let text = parts[index]["text"] as? String {
                        parts[index]["text"] = contextTextForModel(
                            text,
                            label: "\(role)-message-part",
                            maxInlineCharacters: 12_000
                        )
                    }
                }
                prepared["content"] = parts
            }
            return prepared
        }
    }

    private static func messageTextForContextSummary(_ message: [String: Any]) -> String {
        let role = (message["role"] as? String) ?? "message"
        let content: String = {
            if let text = message["content"] as? String {
                return text
            }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { part in
                    if let text = part["text"] as? String { return text }
                    if part["image_url"] != nil { return "[image]" }
                    return nil
                }.joined(separator: "\n")
            }
            return ""
        }()
        let cleaned = content
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "\(role): [empty]" }
        return "\(role): \(String(cleaned.prefix(900)))"
    }

    private static func compactMessagesIfNeeded(
        _ messages: [[String: Any]],
        model: AIModel?,
        modelId: String?
    ) -> (messages: [[String: Any]], status: ChatContextBudgetStatus) {
        let window = contextWindowTokens(for: model, modelId: modelId)
        let originalTokens = estimatedTokens(in: messages)
        let preparedMessages = offloadOversizedMessageContentIfNeeded(messages)
        let preparedTokens = estimatedTokens(in: preparedMessages)
        var status = contextStatus(
            model: model,
            modelId: modelId,
            usedTokens: preparedTokens
        )

        let softLimit = Int(Double(window) * 0.82)
        guard window > 0, preparedTokens > softLimit, preparedMessages.count > 4 else {
            return (preparedMessages, status)
        }

        let leadingSystemCount = messages.prefix {
            ($0["role"] as? String) == "system"
        }.count
        let leadingSystemMessages = Array(preparedMessages.prefix(leadingSystemCount))
        let chronologicalMessages = Array(preparedMessages.dropFirst(leadingSystemCount))
        guard chronologicalMessages.count > 3 else {
            return (preparedMessages, status)
        }

        let keepTailCount = min(max(4, chronologicalMessages.count / 3), 12)
        let splitIndex = max(0, chronologicalMessages.count - keepTailCount)
        let olderMessages = Array(chronologicalMessages.prefix(splitIndex))
        let recentMessages = Array(chronologicalMessages.suffix(keepTailCount))
        guard !olderMessages.isEmpty else {
            return (messages, status)
        }

        let summaryBudget = max(900, min(4_000, Int(Double(window) * 0.04)))
        var summaryLines: [String] = []
        var usedSummaryTokens = 0
        for message in olderMessages {
            let line = messageTextForContextSummary(message)
            let tokens = estimatedTokenCount(for: line)
            if usedSummaryTokens + tokens > summaryBudget { break }
            summaryLines.append("- \(line)")
            usedSummaryTokens += tokens
        }
        if summaryLines.count < olderMessages.count {
            summaryLines.append("- 其余较早消息已省略，只保留关键顺序和最近完整上下文。")
        }

        let summary = """
        [自动压缩的较早对话上下文]
        因当前会话接近模型上下文窗口，客户端在发送前把较早消息压缩为摘要。请把下面摘要作为历史背景，最近几轮消息仍保持完整原文。

        \(summaryLines.joined(separator: "\n"))
        [/自动压缩的较早对话上下文]
        """

        let compacted = leadingSystemMessages
            + [["role": "system", "content": summary]]
            + recentMessages
        let compactedTokens = estimatedTokens(in: compacted)
        status.usedTokens = compactedTokens
        status.isCompressed = true
        status.originalTokens = originalTokens
        status.compressedTokens = compactedTokens
        return (compacted, status)
    }

    private func refreshContextBudgetStatus(
        from messages: [[String: Any]]? = nil,
        compressed: Bool = false,
        originalTokens: Int? = nil,
        compressedTokens: Int? = nil
    ) {
        let modelId = selectedModelId ?? conversation?.model
        let used = messages.map(Self.estimatedTokens(in:)) ?? Self.estimatedTokensForVisibleConversation(conversation)
        contextBudgetStatus = Self.contextStatus(
            model: selectedModel,
            modelId: modelId,
            usedTokens: used,
            isCompressed: compressed,
            originalTokens: originalTokens,
            compressedTokens: compressedTokens
        )
    }

    private func appendContextCompressionStatusIfNeeded(to assistantMessageId: String) {
        guard contextBudgetStatus.isCompressed else { return }
        appendStatusUpdate(
            id: assistantMessageId,
            status: ChatStatusUpdate(
                action: "context_compaction",
                description: "已自动压缩上下文",
                done: true,
                count: contextBudgetStatus.compressedTokens
            )
        )
    }

    private static func estimatedTokensForVisibleConversation(_ conversation: Conversation?) -> Int {
        guard let conversation else { return 0 }
        return conversation.messages.reduce(0) { total, message in
            guard !message.isStreaming,
                  !isLocalWorkspaceAgentResult(message),
                  !isLocalAlpineAgentResult(message) else {
                return total
            }
            return total + 4 + estimatedTokenCount(for: message.content)
                + message.files.count * 256
        }
    }

    private static func firstIntValue(in usage: [String: Any]?, keys: [String]) -> Int? {
        guard let usage else { return nil }
        for key in keys {
            if let intValue = usage[key] as? Int {
                return intValue
            }
            if let doubleValue = usage[key] as? Double {
                return Int(doubleValue)
            }
            if let number = usage[key] as? NSNumber {
                return number.intValue
            }
            if let string = usage[key] as? String, let intValue = Int(string) {
                return intValue
            }
        }
        for value in usage.values {
            if let nested = value as? [String: Any],
               let nestedValue = firstIntValue(in: nested, keys: keys) {
                return nestedValue
            }
        }
        return nil
    }

    private static func localizedGenerationError(_ error: Error) -> String {
        let apiError = APIError.from(error)
        if apiError.requiresReauth {
            return apiError.errorDescription ?? "登录已过期，请重新登录。"
        }
        if case .httpError(let statusCode, let message, _) = apiError,
           statusCode == 401 || statusCode == 403 {
            let detail = cleanedProviderErrorMessage(message ?? "")
                ?? message?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return "上游鉴权失败（HTTP \(statusCode)）：\(detail)"
            }
            return apiError.errorDescription ?? "上游鉴权失败（HTTP \(statusCode)）。请检查 API Key、模型权限或额度。"
        }
        if apiError.isConnectivityError {
            return apiError.errorDescription ?? error.localizedDescription
        }
        return cleanedProviderErrorMessage(apiError.serverDetail ?? error.localizedDescription)
            ?? apiError.errorDescription
            ?? error.localizedDescription
    }

    private static func cleanedProviderErrorMessage(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowercased = text.lowercased()
        if lowercased.contains("model_not_supported") || text.contains("不受支持") {
            let model = firstRegexCapture(in: text, pattern: #"['\"]model['\"]\s*:\s*['\"]([^'\"]+)['\"]"#)
                ?? firstRegexCapture(in: text, pattern: #"模型\s*['\"]([^'\"]+)['\"]\s*不受支持"#)
            if let model, !model.isEmpty {
                return "当前提供方不支持模型 \(model)。请切换到模型列表里的可用模型后重试。"
            }
            return "当前提供方不支持所选模型。请切换到模型列表里的可用模型后重试。"
        }
        if lowercased.contains("invalid_api_key") || lowercased.contains("invalid api key") {
            return "上游返回 API Key 无效。请检查当前站点配置里的 API Key。"
        }
        if lowercased.contains("insufficient_quota") || lowercased.contains("quota") || lowercased.contains("余额") {
            return "上游返回额度不足或请求超限。请检查当前提供方账户额度。"
        }
        if lowercased.hasPrefix("{\"error\"") || lowercased.hasPrefix("{'error'") {
            return parsedProviderJSONErrorMessage(from: text)
                ?? "提供方返回了错误响应，请检查当前模型和提供方配置后重试。"
        }
        return nil
    }

    private static func parsedProviderJSONErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return providerMessage(from: json)
    }

    private static func providerMessage(from value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = value as? [String: Any] {
            for key in ["message", "detail", "error_description", "error", "reason", "code"] {
                if let value = dict[key],
                   let message = providerMessage(from: value) {
                    return message
                }
            }
        }
        if let array = value as? [Any] {
            return array.compactMap { providerMessage(from: $0) }.first
        }
        return nil
    }

    @MainActor
    private func stopLocalAlpineAutoContinuationForAuthenticationFailure() {
        localAlpineAgentStopRequested = true
        localAlpineAutoExecutionPaused = true
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = nil
        localAlpineContinuationWatchdogTask?.cancel()
        localAlpineContinuationWatchdogTask = nil
        cancelLocalAlpineInput()
        localAlpineContinuationParentIds.removeAll()
        localAlpineContinuationRetryCounts.removeAll()
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private func localMemorySystemContext() async -> String? {
        guard memoryEnabled, let manager else { return nil }
        guard await LocalMemoryStore.shared.isEnabled(serverURL: manager.baseURL) else { return nil }
        let memoryContents = await LocalMemoryStore.shared
            .list(serverURL: manager.baseURL)
            .map(\.content)
        let trimmedMemories = memoryContents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedMemories.isEmpty else { return nil }
        let lines = trimmedMemories.prefix(30).map { "- \($0)" }.joined(separator: "\n")
        return """
        User memories to consider across conversations:
        \(lines)
        """
    }

    private func persistExplicitMemoryRequestIfNeeded(from text: String) async {
        guard memoryEnabled,
              let manager,
              let memory = Self.explicitMemoryContent(from: text) else {
            return
        }
        await LocalMemoryStore.shared.addIfAbsent(content: memory, serverURL: manager.baseURL)
    }

    private static func explicitMemoryContent(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()
        let questionMarkers = ["记得什么", "记住什么", "记忆是什么", "有哪些记忆", "查看记忆", "列出记忆", "what do you remember", "show memories", "list memories"]
        if questionMarkers.contains(where: { lowercased.contains($0) }) {
            return nil
        }

        let patterns = [
            #"(?i)^\s*(?:请|帮我|麻烦你)?记住[：:，,\s]*(.+)$"#,
            #"(?i)^\s*(?:请|帮我|麻烦你)?记一下[：:，,\s]*(.+)$"#,
            #"(?i)^\s*以后(?:你)?(?:要)?记得[：:，,\s]*(.+)$"#,
            #"(?i)^\s*(?:你)?(?:要)?记得[：:，,\s]*(.+)$"#,
            #"(?i)^\s*remember(?:\s+that)?[：:,\s]+(.+)$"#,
            #"(?i)^\s*please\s+remember(?:\s+that)?[：:,\s]+(.+)$"#,
            #"(?i)^\s*keep\s+in\s+mind(?:\s+that)?[：:,\s]+(.+)$"#,
            #"(?i)^\s*save\s+this\s+(?:as\s+)?memory[：:,\s]+(.+)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = trimmed as NSString
            let range = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  match.numberOfRanges > 1 else { continue }
            var memory = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`，,。.!！ "))
            if memory.count > 1_000 {
                memory = String(memory.prefix(1_000))
            }
            return memory.count >= 2 ? memory : nil
        }
        return nil
    }

    private static func projectContinuitySystemContext() -> String {
        """
        When generating code projects, treat every file as part of one connected project:
        - Use exact relative file names and matching imports, links, entrypoints, and package/config files.
        - For HTML/CSS/JavaScript projects split across index.html, style.css, and script.js, the HTML must link ./style.css and ./script.js, and the CSS/JS must be written for that same UI.
        - For other languages, include the folder tree, entry file, dependency/config files, and imports so the project can run as a coherent whole instead of unrelated snippets.
        - If the user only asks to "show", "preview", "write a page", or wants a single-file demo, return normal code blocks with an inline preview-friendly HTML file. Do not create workspace operations unless the user explicitly asks to save/create/modify/read/search/list/delete local files or folders.

        Iexa has a local workspace agent. Use it only when the user explicitly asks for the app's Documents/Iexa Workspace. If Local Alpine terminal mode is enabled, do not use `iexa_workspace`; local project files are in `/mnt/iexa` and must be operated with `iexa_alpine`.
        When the user asks you to create, modify, read, search, list, or delete local project files in Documents/Iexa Workspace, include exactly one fenced block with language `iexa_workspace` containing JSON. Paths are relative to the app's Documents/Iexa Workspace folder and must never be absolute or use `..`.
        Do not claim that a local file operation has been completed unless you emit the `iexa_workspace` block for the app to execute. The app will append the real execution result; treat that appended result as the source of truth.
        Supported operations:
        ```iexa_workspace
        {
          "iexa_workspace": [
            {"action": "mkdir", "path": "demo"},
            {"action": "write", "path": "demo/index.html", "content_lines": ["<!doctype html>", "<html>", "</html>"]},
            {"action": "append", "path": "demo/README.md", "content": "\\nMore notes"},
            {"action": "read", "path": "demo/index.html"},
            {"action": "search", "path": "demo", "query": "button"},
            {"action": "list", "path": "demo"},
            {"action": "delete", "path": "demo/old.txt"}
          ]
        }
        ```
        For `iexa_workspace` JSON operations, prefer `content_lines`, `code_lines`, or `content_base64` so indentation stays intact. If Local Alpine terminal mode is handling files, prefer `iexa_alpine` JSON `write_files` for exact file content, then verify with a bounded command. For multi-file projects, write all connected files together so the UI, styles, scripts, imports, and dependencies stay linked.
        If the user asks to run/check/verify the project after writing files and Local Alpine terminal mode is available, also emit a bounded `iexa_alpine` block in the same answer for the concrete verification command.
        """
    }

    private static func workspaceGuardSystemContext() -> String {
        """
        Iexa can execute local workspace file operations, but only when the user explicitly asks to save/create/modify/read/search/list/delete files or folders in the local workspace.
        If the user asks to write, show, preview, or demonstrate a webpage/app/component/code without explicitly asking to save it into local files, return normal Markdown code blocks and any preview-friendly single-file code. Do not output an `iexa_workspace` block in that case.
        """
    }

    private static func workspaceDisabledForLocalAlpineSystemContext() -> String {
        """
        Legacy Documents/Iexa Workspace operations are disabled for this turn. For local files, directories, scripts, dependencies, builds, tests, reads, writes, deletes, and searches, use Local Alpine at `/mnt/iexa` only. Do not emit `iexa_workspace`.
        """
    }

    private static func localNativeToolSystemContext() -> String {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(86_400)
        let exampleEventEnd = calendar.date(byAdding: .hour, value: 1, to: now)
            ?? now.addingTimeInterval(3_600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        let nowText = formatter.string(from: now)
        let todayStartText = formatter.string(from: startOfToday)
        let todayEndText = formatter.string(from: endOfToday)
        let exampleEndText = formatter.string(from: exampleEventEnd)
        let timezoneName = TimeZone.current.identifier
        return """
        Iexa has on-device native iOS tools for device info, clipboard, local notifications, location, weather, calendar, local browser/web reading, and local Office/PDF document generation. These run locally on the user's device and do not require the remote server.

        Current device time: \(nowText), timezone: \(timezoneName). For relative requests such as "今天", "现在", "明天", or "查看日历", calculate the date range from this current device time. Do not reuse stale sample dates.

        Use them only when the user asks to read device status/info, read/write clipboard text, show a local notification, get/use their current location, query current local weather, query local calendar events, create/delete a calendar event, search/open/read/screenshot/download webpages, or directly create an Excel/PPT/Word/PDF file. Do not emit this tool for ordinary conversation.
        For code execution, Python scripts, package installs, project edits, or "write/run Python to generate a file", use Local Alpine when available instead of the Office actions. The Office actions are for productized file creation from a document draft, not for replacing the Python/terminal agent.
        To call a local native tool, output exactly one fenced `iexa_native` JSON block and no fake tool-call syntax.

        Supported actions:
        ```iexa_native
        {"action":"device.status"}
        ```
        ```iexa_native
        {"action":"device.info"}
        ```
        ```iexa_native
        {"action":"clipboard.read"}
        ```
        ```iexa_native
        {"action":"clipboard.write","text":"要复制的文本"}
        ```
        ```iexa_native
        {"action":"system.notify","title":"Iexa","body":"提醒内容"}
        ```
        ```iexa_native
        {"action":"get_location"}
        ```
        ```iexa_native
        {"action":"get_weather"}
        ```
        ```iexa_native
        {"action":"list_calendar_events","start":"\(todayStartText)","end":"\(todayEndText)"}
        ```
        ```iexa_native
        {"action":"create_calendar_event","title":"会议","start":"\(nowText)","end":"\(exampleEndText)","location":"办公室","description":"讨论项目","alert_minutes":10}
        ```
        ```iexa_native
        {"action":"delete_calendar_event","id":"event-id-from-list"}
        ```
        ```iexa_native
        {"action":"web.search","query":"OpenAI 最新 Responses API 工具","limit":6,"screenshot":true}
        ```
        ```iexa_native
        {"action":"browser.readable","url":"https://example.com/article","screenshot":true,"max_length":8000}
        ```
        ```iexa_native
        {"action":"browser.screenshot","url":"https://example.com"}
        ```
        ```iexa_native
        {"action":"browser.fetch","url":"https://example.com/file.pdf"}
        ```
        ```iexa_native
        {"action":"office.create_excel","title":"销售周报","file_name":"销售周报.xlsx","sheets":[{"name":"汇总","headers":["指标","数值","备注"],"rows":[["销售额","128000","环比增长"],["订单数","342","本周新增"]]}]}
        ```
        ```iexa_native
        {"action":"office.create_ppt","title":"产品介绍","file_name":"产品介绍.pptx","subtitle":"本地生成演示稿","theme":{"style":"deep_blue_tech","layout":"dashboard","decoration":"grid","background":"071326","background_2":"102A6B","surface":"12213D","accent":"22D3EE","text":"F8FAFC","subtle":"B6C6E3"},"slides":[{"layout":"cover","title":"产品介绍","subtitle":"2026 年规划"},{"layout":"dashboard","title":"核心能力","bullets":["本地自动化","多模型接入","文件生成"]},{"layout":"table","title":"计划","table":[["阶段","目标"],["MVP","生成并预览"],["增强","模板和图片"]]}]}
        ```
        ```iexa_native
        {"action":"office.create_word","title":"产品方案","file_name":"产品方案.docx","subtitle":"本地生成文档","theme":{"style":"minimal","accent":"111827"},"sections":[{"heading":"背景","paragraphs":["目标用户需要一个本地优先的智能工作流。"]},{"heading":"核心能力","bullets":["多模型接入","本地文件生成","移动端预览和分享"]}]}
        ```
        ```iexa_native
        {"action":"office.create_pdf","title":"项目汇报","file_name":"项目汇报.pdf","format":"slides","theme":{"style":"warm_business","layout":"split","decoration":"diagonal","background":"FFF7ED","background_2":"FED7AA","accent":"EA580C","text":"1F2937","subtle":"78716C"},"slides":[{"layout":"cover","title":"项目汇报","subtitle":"本地生成 PDF"},{"layout":"split","title":"关键进展","bullets":["目标清晰","风险可控","下一步明确"]}]}
        ```

        For browser/web actions, when these tools are present, you may proactively use them. Use `web.search` before answering whenever the answer depends on information that may have changed after training or that you are not confident is still true: current/latest/recent facts, software/app/game versions, patch notes, releases, prices, stocks, laws/policies, schedules, sports, weather, news, rankings, product availability, official announcements, live website content, or "what is it now / has it changed / which version" style questions. If you are unsure whether your knowledge is stale, search first; do not wait for the user to literally say 搜、查、搜索, or 联网. Do not use the browser for stable writing, translation, math, coding, or brainstorming unless the user asks for current/source-backed information.
        Use `web.search` when there is no exact URL. Use `browser.readable` when a URL is known or after search results need verification. Set `screenshot:true` when the user may benefit from seeing the page; Iexa will show a clickable webpage source card with thumbnail in the chat. Use `browser.screenshot` for visual page checks and `browser.fetch` for downloadable files. After Iexa appends the real browser result, answer from that result; cite page titles/URLs plainly and do not claim you cannot browse.

        For Office/PDF actions, build a concise structured draft from the user's natural language and attachments. Always translate visual requests into a concrete `theme`: `style`, `layout`, `decoration`, `background`, `background_2`, `surface`, `accent`, `text`, and `subtle`. Supported style/layout/decoration hints include `deep_blue_tech`, `minimal`, `dark`, `warm_business`, `green`, `violet`, `editorial`, `luxury`, `playful`, `split`, `centered`, `card`, `dashboard`, `poster`, `sidebar`, `diagonal`, `circle`, `grid`, `dots`, `frame`, and `wave`. For "黑金", "金色商务", "高级商务", "奢华", or "premium/luxury", use `style:"luxury"` with a near-black `background`, a second dark `background_2`, gold `accent`, light `text`, and `decoration:"frame"` or `layout:"poster"`/`card`; never output a white minimal Word/PPT/PDF for those requests. If the user attaches a screenshot/template image, inspect it and approximate its visual fingerprint: dominant colors, dark/light mood, title placement, card/sidebar/split/dashboard/poster composition, border/shape/grid/dot/circle/wave decoration, and typography density. Put that fingerprint into `theme` and per-slide `layout`; do not reuse the default blue template when a different visual style was requested. If exact screenshot replication is impossible, still generate the closest local approximation instead of saying the tool cannot do it.

        If a `[Latest local Office document for revision]` context is present and the user asks to modify, regenerate, restyle, improve, rewrite, or "改方案/换方案/按这个改", you must emit a fresh Office/PDF `iexa_native` block using the previous structured draft as the base. Preserve useful existing content, apply the requested changes, and generate a new file. Do not answer with only a plan, explanation, or promise.

        For PDF, use `office.create_pdf`; use `format:"slides"` with `slides` for deck-like PDFs, `format:"document"` with `sections` for report-like PDFs, or sheets/rows for table PDFs. If the user asks to convert the latest generated Office file to PDF, emit `office.create_pdf`; include the latest file URL as `source_url` when it is visible in context, otherwise the app will use the most recent local Office result automatically. If a key requirement is missing, choose a safe default instead of asking many setup questions. After Iexa appends the native tool result, continue from that real result and answer normally. If permissions are denied, location is not ready, notification permission is disabled, WeatherKit entitlement is unavailable, or Office/PDF generation fails, explain the exact local permission/state issue.
        """
    }

    private static func localAlpineAgentSystemContext() -> String {
        """
        [Local Alpine client tool registry]
        Iexa has an on-device Alpine Linux workspace tool named `iexa_alpine`. It is available in this chat when this registry is present.
        To call it, emit one fenced Markdown block with language `iexa_alpine`. The iOS host app executes that block locally and then returns the real result as a later observation.
        This is not a provider/native function-call tool and it is not plain text. Do not search a provider tool list for it. Never say `iexa_alpine` does not exist; use the fenced block form below.
        If your model runtime says tools/functions are unavailable, ignore that for Local Alpine: the host app reads the Markdown fence and runs it after your message.

        \(localAlpineToolManifest)

        Environment:
        - Workspace: `/mnt/iexa`. Relative paths resolve there.
        - Shell: Alpine Linux BusyBox/ash. Prefer portable POSIX `sh` syntax; avoid Bash-only arrays, process substitution, and Debian/macOS assumptions unless the needed tool is first proven installed.
        - Package manager: `apk`. Check first with `apk info -e <pkg>` or `command -v <tool>`; install only packages proven missing with `apk add --no-cache <pkg>`.
        - Unsupported command families here: `apt`, `apt-get`, `yum`, `dnf`, `pacman`, `brew`, `sudo`, `systemctl`, `launchctl`, and macOS-only utilities. Translate those intentions to Alpine/BusyBox equivalents.
        - Rootfs paths like `/bin`, `/etc`, `/usr`, `/lib`, and `/var` are system paths. Inspect them when useful; do not edit them except through package-manager operations or explicit user requests.
        - Do not check `/mnt/iexa/rootfs` unless the user explicitly created that folder; the Local Alpine commands already execute inside the Alpine rootfs.

        Tool-selection policy:
        - Use the tool only for explicit operation requests that require current local state or mutation: read/list/search files, create/edit/delete/rename/move/copy files, install dependencies, run/test/build/compile/debug/fix code, inspect the Alpine environment, fetch/scrape a URL from the local shell, or verify real output.
        - Do not use the tool for ordinary conversation, explanations, design discussion, capability/feasibility questions, dependency advice, code samples the user did not ask you to write/run, or questions about what the previous error means. Answer normally in those cases.
        - For any intermediate local-work step, emit one `iexa_alpine` block only when you intentionally want the host to run it. If you answer with prose only, the host treats it as a normal final answer and will not synthesize or execute anything.
        - Treat imperative shorthand as execution requests here: 写/创建/运行/跑/测试/检查/看下/读/改/换/删/再跑/继续 and write/create/run/test/check/read/modify/change/delete/rerun/continue should operate on `/mnt/iexa` or the latest relevant Local Alpine file/command when the context points there.
        - For follow-ups like "this", "it", "这个", "它", "删了", "换一个", "再跑", or "继续", infer the latest written file or executed command from the Local Alpine observation instead of asking the user to restate it.
        - If a demo request omits a URL, filename, or sample input, choose safe defaults and proceed: `example.com`/`example.org` for network demos and simple names like `test.lua`, `main.cpp`, or `simple_spider.py`.
        - Do not ask for confirmation for explicit `/mnt/iexa` deletes, edits, reads, checks, runs, or reruns. Ask only when the target is outside `/mnt/iexa`, destructive across many files, or genuinely unknown.
        - If the user asks you to write/run/fix/check a project or script, operate under `/mnt/iexa`, verify with a bounded command, and then summarize the real result.
        - For existing source files, read the target first and prefer same-path `edit_file`/`patch_file`; use `write_files` for new files or large same-path rewrites. For deletes, use `delete_file`/`delete_files` instead of shell `rm`; set `recursive:true` only when deleting a directory.
        - Prefer structured `list_dir`, `glob`, `grep`, and `verify` wrappers over ad-hoc `find`/`grep`/run syntax when they fit.
        - If the user asks to run recent code from the conversation, save the latest runnable code block under `/mnt/iexa`, run it with the right interpreter/compiler, and summarize the real output.
        - If the user asks to generate, save, show, display, or send images, write each final image under `/mnt/iexa` and print every final path, preferably one `READY: /mnt/iexa/<name>.png` line per image. If the user requests multiple images, create distinct variants rather than duplicating one file: vary composition, angle, lighting, background details, colors, or small visual details while preserving the user's core prompt. The host app will read PNG/JPEG/WebP/GIF/BMP/AVIF files from `/mnt/iexa` and attach them to the chat bubble automatically. Do not claim you cannot send or display images after creating them.
        - If a tool result shows failure, choose one different bounded fix/diagnostic step or stop with the concrete blocker. Never repeat the exact same failed command.
        - If a tool result shows success and the user goal is complete, stop tool use and answer normally.
        [/Local Alpine client tool registry]
        """
    }

    /// Builds API messages array, fetching image base64 from server for vision.
    /// Matches Flutter's `_buildMessagePayloadWithAttachments` which calls
    /// `api.getFileContent(fileId)` to get base64 data URLs for the LLM.
    /// Builds a lightweight `[{role, content}]` message array from the current
    /// conversation without fetching image data from the server.
    /// Used for `/api/chat/completed` so filter outlets receive the full
    /// conversation history and can run their post-processing logic.
    private func buildSimpleAPIMessages() -> [[String: Any]] {
        guard let conversation else { return [] }
        var msgs: [[String: Any]] = []
        let simpleEffectiveSP: String? = {
            if let cp = conversation.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            return conversation.systemPrompt
        }()
        if let sp = simpleEffectiveSP, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            msgs.append(["role": "system", "content": sp])
        }
        for msg in conversation.messages where !msg.isStreaming
            && !Self.isLocalWorkspaceAgentResult(msg) {
            msgs.append(["role": msg.role.rawValue, "content": msg.content])
        }
        return Self.compactMessagesIfNeeded(
            msgs,
            model: selectedModel,
            modelId: selectedModelId ?? conversation.model
        ).messages
    }

    private func resolveWebLinkContextIfNeeded(
        userMessageId: String,
        assistantMessageId: String,
        text: String
    ) async {
        guard WebLinkContextResolver.containsHTTPURL(text) else { return }

        appendStatusUpdate(
            id: assistantMessageId,
            status: ChatStatusUpdate(
                action: "link_context",
                description: "正在读取链接内容...",
                done: false
            )
        )

        let result = await webLinkContextResolver.resolve(from: text, limit: 3)
        if !result.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webLinkContextsByMessageId[userMessageId] = modelLinkContextPrompt(result.context)
        }
        for video in result.videos {
            attachResolvedVideoFile(messageId: assistantMessageId, video: video)
        }
        for image in result.images {
            attachResolvedImageFile(messageId: assistantMessageId, image: image)
        }

        let description: String
        if result.successCount > 0 {
            let mediaParts = [
                result.videos.isEmpty ? nil : "\(result.videos.count) 个 MP4",
                result.images.isEmpty ? nil : "\(result.images.count) 张图片"
            ].compactMap { $0 }
            description = mediaParts.isEmpty
                ? "已读取 \(result.successCount) 个链接"
                : "已解析 \(result.successCount) 个链接，找到 \(mediaParts.joined(separator: "、"))"
        } else {
            description = "链接读取失败，已按原文发送"
        }

        appendStatusUpdate(
            id: assistantMessageId,
            status: ChatStatusUpdate(
                action: "link_context",
                description: description,
                done: true,
                count: result.successCount
            )
        )
    }

    private func modelLinkContextPrompt(_ context: String) -> String {
        """

        [客户端已读取的链接上下文]
        用户消息里包含链接。以下内容由 iOS 客户端在发送前读取，用来帮助你回答；请把它当作该链接的可用上下文。若包含 MP4 URL 或图片 URL，请直接返还给用户并结合页面标题/描述概括内容。
        \(context)
        [/客户端已读取的链接上下文]
        """
    }

    private func resolveWebSearchContextIfNeeded(
        userMessageId: String,
        assistantMessageId: String,
        text: String,
        modelId: String,
        hasAttachments: Bool
    ) async {
        guard isChatWebSearchAllowed else { return }
        guard !hasAttachments else { return }
        guard !WebLinkContextResolver.containsHTTPURL(text) else { return }
        guard !shouldUseDirectImageGeneration(modelId: modelId),
              !shouldPreferChatNativeImageGeneration(modelId: modelId),
              !shouldUseDirectVideoGeneration(modelId: modelId) else {
            return
        }
        guard shouldResolveWebSearchContext(for: text) else { return }

        let query = webSearchQuery(from: text)
        guard !query.isEmpty else { return }

        if shouldUseOpenAIResponsesWebSearchTool(modelId: modelId) {
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "web_search",
                    description: "将使用 Responses 原生网页搜索",
                    done: true,
                    count: 0,
                    query: query,
                    queries: [query]
                )
            )
            return
        }

        if let currentTimeContext = modelCurrentTimeContextPrompt(for: text) {
            webSearchContextsByMessageId[userMessageId] = currentTimeContext
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "browser_web_search",
                    description: "已获取当前时间",
                    done: true,
                    count: 0,
                    query: query,
                    queries: [query]
                )
            )
            return
        }

        if isWebSearchCapabilityQuestion(text) {
            webSearchContextsByMessageId[userMessageId] = modelWebSearchAvailabilityPrompt()
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "browser_web_search",
                    description: "内置浏览器搜索已可用",
                    done: true,
                    count: 0,
                    query: query,
                    queries: [query]
                )
            )
            return
        }

        appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "browser_web_search",
                    description: "正在用内置浏览器搜索...",
                    done: false,
                    query: query,
                    queries: [query]
                )
        )

        do {
            let queries: [String]
            if let apiClient = manager?.apiClient {
                queries = await webSearchQueries(for: query, userText: text, apiClient: apiClient, modelId: modelId)
            } else {
                queries = Self.freshnessAwareWebSearchQueries(
                    userText: text,
                    originalQuery: query,
                    generated: Self.fallbackWebSearchQueries(for: text, originalQuery: query),
                    limit: 4
                )
            }
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "browser_web_search",
                    description: "正在用内置浏览器搜索...",
                    done: false,
                    query: query,
                    queries: queries
                )
            )

            let searchOutput = try await runAgenticWebSearch(
                query: query,
                queries: queries,
                assistantMessageId: assistantMessageId
            )
            let result = searchOutput.result
            let usedQueries = searchOutput.queries
            Self.prefetchFavicons(for: result)
            guard result.loadedCount > 0 || !result.items.isEmpty || !result.docs.isEmpty else {
                appendStatusUpdate(
                    id: assistantMessageId,
                    status: ChatStatusUpdate(
                        action: "browser_web_search",
                        description: "联网搜索没有返回结果，已按原问题发送",
                        done: true,
                        count: 0,
                        query: query,
                        queries: usedQueries
                    )
                )
                return
            }
            let context = modelWebSearchContextPrompt(result: result, query: query, queries: usedQueries)
            let sources = webSearchSources(from: result)

            if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                webSearchContextsByMessageId[userMessageId] = context
            }
            if !sources.isEmpty {
                appendSources(id: assistantMessageId, sources: sources)
                if streamingStore.streamingMessageId == assistantMessageId && streamingStore.isActive {
                    streamingStore.appendSources(sources)
                }
            }

            let urls = Array(Set(result.filenames + result.items.compactMap(\.link))).prefix(8)
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "browser_web_search",
                    description: result.loadedCount > 0
                        ? "内置浏览器已读取 \(result.loadedCount) 个网页"
                        : "内置浏览器已搜索 \(max(sources.count, result.items.count)) 个来源",
                    done: true,
                    urls: Array(urls),
                    items: result.items.prefix(6).map {
                        ChatStatusItem(
                            title: $0.title,
                            link: $0.link,
                            snippet: $0.snippet,
                            thumbnailURL: $0.thumbnailURL
                        )
                    },
                    count: max(result.loadedCount, sources.count),
                    query: query,
                    queries: usedQueries
                )
            )
        } catch {
            logger.warning("Web search failed: \(error.localizedDescription)")
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "browser_web_search",
                    description: "内置浏览器搜索失败，已按原问题发送",
                    done: true,
                    count: 0,
                    query: query,
                    queries: [query]
                )
            )
        }
    }

    private func webSearchQueries(for query: String, userText: String, apiClient: APIClient, modelId: String) async -> [String] {
        let serverConfig = activeChatStore?.serverTaskConfig ?? .default
        let fallbackQueries = Self.fallbackWebSearchQueries(for: userText, originalQuery: query)
        guard serverConfig.enableSearchQueryGeneration else {
            return Self.freshnessAwareWebSearchQueries(
                userText: userText,
                originalQuery: query,
                generated: fallbackQueries,
                limit: 4
            )
        }

        let taskModel = [
            serverConfig.taskModelExternal,
            serverConfig.taskModel,
            modelId
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? modelId

        do {
            let generated = try await apiClient.generateSearchQueries(
                model: taskModel,
                query: query,
                context: recentUserContextForSearch(excluding: query),
                maxQueries: 3
            )
            return Self.freshnessAwareWebSearchQueries(
                userText: userText,
                originalQuery: query,
                generated: generated + fallbackQueries,
                limit: 4
            )
        } catch {
            logger.debug("Search query generation failed: \(error.localizedDescription)")
            return Self.freshnessAwareWebSearchQueries(
                userText: userText,
                originalQuery: query,
                generated: fallbackQueries,
                limit: 4
            )
        }
    }

    private func recentUserContextForSearch(excluding query: String) -> String? {
        guard let conversation else { return nil }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = conversation.messages
            .filter { $0.role == .user && !$0.isStreaming }
            .suffix(4)
            .map(\.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != normalizedQuery }
            .suffix(3)
            .joined(separator: "\n")
        return context.isEmpty ? nil : String(context.prefix(2_000))
    }

    private func runAgenticWebSearch(
        query: String,
        queries: [String],
        assistantMessageId: String
    ) async throws -> (result: WebSearchResponse, queries: [String]) {
        let result = try await ClientWebSearchService().search(queries: queries, originalQuery: query)
        return (result, queries)
    }

    private static func freshnessAwareWebSearchQueries(userText: String, originalQuery: String, generated: [String], limit: Int) -> [String] {
        let precise = preciseFallbackSearchQuery(for: userText, originalQuery: originalQuery)
        guard webSearchNeedsFreshness(userText) || webSearchNeedsFreshness(originalQuery) else {
            return mergeSearchQueries(original: precise, generated: generated, limit: limit)
        }

        let currentYear = Calendar.current.component(.year, from: Date())
        let hasCJK = containsCJK(precise)
        var freshGenerated = hasCJK
            ? [
                "\(precise) 最新",
                "\(precise) 官方 更新 \(currentYear)",
                "\(precise) \(currentYear)"
            ]
            : [
                "\(precise) latest",
                "\(precise) official updated \(currentYear)",
                "\(precise) \(currentYear)"
            ]
        if webSearchNeedsDayScope(userText) || webSearchNeedsDayScope(originalQuery) {
            freshGenerated.insert(hasCJK ? "\(precise) 今天" : "\(precise) today", at: 0)
        }
        return mergeSearchQueries(original: precise, generated: freshGenerated + generated, limit: limit)
    }

    private static func webSearchNeedsFreshness(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return [
            "最新", "今天", "今日", "现在", "目前", "刚刚", "新闻", "热搜", "实时", "现价",
            "油价", "天气", "气温", "股价", "汇率", "版本", "发布", "更新",
            "latest", "today", "current", "now", "news", "breaking", "price", "weather",
            "stock", "exchange", "rate", "release", "version", "updated"
        ].contains { normalized.contains($0) }
    }

    private static func webSearchNeedsDayScope(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return [
            "今天", "今日", "24小时", "一天内", "当天", "today", "last24hours", "past24hours"
        ].contains { normalized.contains($0) }
    }

    private static func webSearchTimestampText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss zzz"
        return formatter.string(from: Date())
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private static func mergeSearchQueries(original: String, generated: [String], limit: Int) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let trimmed = raw
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(trimmed)
        }

        append(original)
        generated.forEach(append)
        return Array(result.prefix(limit))
    }

    private static func preciseFallbackSearchQuery(for userText: String, originalQuery: String) -> String {
        let cleaned = originalQuery
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = cleaned.isEmpty ? userText : cleaned
        var query = source

        let removablePatterns = [
            #"(?i)\b(can you|could you|please|help me|search for|search|lookup|find out|tell me about)\b"#,
            #"(帮我|替我|给我)?(联网)?(搜索|搜一下|搜搜|查一下|查询一下|查查看|看一下)"#,
            #"(你知道|我想知道|请问|一下|看看|吗|么|呢|？|\?)"#
        ]
        for pattern in removablePatterns {
            query = query.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        query = query
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,。.!！")))

        guard !query.isEmpty else { return cleaned.isEmpty ? userText : cleaned }
        if query.count <= 80 { return query }

        let tokens = query
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。；;：:")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                guard token.count >= 2 else { return false }
                let stopwords = ["这个", "那个", "怎么", "为什么", "是不是", "能不能", "有没有", "what", "why", "how", "the", "and"]
                return !stopwords.contains(token.lowercased())
            }
        let compact = tokens.prefix(8).joined(separator: " ")
        return compact.isEmpty ? String(query.prefix(80)) : compact
    }

    private static func fallbackWebSearchQueries(for userText: String, originalQuery: String) -> [String] {
        let normalized = userText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let precise = preciseFallbackSearchQuery(for: userText, originalQuery: originalQuery)
        var generated: [String] = []

        func add(_ query: String) {
            let trimmed = query
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            generated.append(trimmed)
        }

        let asksWeather = ["天气", "气温", "降雨", "下雨", "weather", "temperature"].contains(where: { normalized.contains($0) })
        let asksFuelPrice = ["油价", "汽油", "柴油", "92", "95", "98", "gas price", "fuel price"].contains(where: { normalized.contains($0) })
        let asksNews = ["新闻", "热搜", "最新消息", "刚刚", "latest", "news", "breaking"].contains(where: { normalized.contains($0) })
            || (normalized.contains("最新") && !asksWeather && !asksFuelPrice)

        if precise != originalQuery {
            add(precise)
        }

        if asksWeather {
            add("\(precise) 实时天气")
            if Self.webSearchNeedsDayScope(userText) {
                add("\(precise) 今天 温度 降雨 风力")
            }
            add("中国天气 \(precise)")
        }

        if asksFuelPrice {
            add("\(precise) 今日油价 92 95 98 柴油")
            add("\(precise) 最新油价")
        }

        if asksNews {
            add("\(precise) 最新消息")
            if Self.webSearchNeedsDayScope(userText) {
                add("\(precise) 今天 新闻 24小时")
            }
        }

        if ["价格", "股价", "汇率", "版本", "发布", "release", "version", "price", "stock"].contains(where: { normalized.contains($0) }) {
            add("\(precise) 最新")
            add("\(precise) 官方 最新")
        }

        return generated
    }

    private func webSearchQuery(from text: String) -> String {
        var query = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "你搜一下", "帮我搜一下", "帮我搜索一下", "帮我搜索", "帮我搜",
            "替我搜一下", "替我搜索一下", "搜索一下", "搜一下", "联网搜索一下",
            "联网搜索", "上网搜一下", "上网搜索一下", "查一下", "帮我查一下",
            "帮我查", "查询一下", "搜搜", "search for", "search", "lookup"
        ]
        var changed = true
        while changed {
            changed = false
            let lowered = query.lowercased()
            for prefix in prefixes where lowered.hasPrefix(prefix.lowercased()) {
                query = String(query.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,。.?？")))
                changed = true
                break
            }
        }
        let suffixes = ["一下", "看看", "给我", "吗", "么", "？", "?"]
        for suffix in suffixes where query.hasSuffix(suffix) && query.count > suffix.count + 1 {
            query = String(query.dropLast(suffix.count))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,。.?？")))
        }
        if query == "当前时间" || query == "现在时间" || query == "现在几点" {
            return "北京时间 当前时间"
        }
        return query
    }

    private func shouldUseOpenAIResponsesWebSearchTool(modelId: String) -> Bool {
        false
    }

    private func modelCurrentTimeContextPrompt(for text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let timeTerms = [
            "当前时间", "现在时间", "现在几点", "几点了", "今天几号",
            "今天日期", "现在日期", "currenttime", "whatstime", "whattime"
        ]
        guard timeTerms.contains(where: { normalized.contains($0) }) else { return nil }

        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm:ss"
        let timeText = formatter.string(from: now)
        let zone = TimeZone.current.identifier
        return """

        [客户端当前时间]
        当前设备时间：\(timeText)
        时区：\(zone)
        用户在询问当前时间/日期时，请直接使用上面的客户端时间回答，不要再搜索网页，也不要说无法实时获取。
        [/客户端当前时间]
        """
    }

    private func shouldResolveWebSearchContext(for text: String) -> Bool {
        isChatWebSearchAllowed
            && webSearchEnabled
            && (Self.userExplicitlyRequestsWebSearch(text) || Self.shouldUseWebSearchForKnowledgeSensitiveQuestion(text))
    }

    private static func userExplicitlyRequestsWebSearch(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("搜") || normalized.contains("查")
    }

    private static func shouldUseWebSearchForKnowledgeSensitiveQuestion(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let generationIntents = [
            "写", "生成", "做一个", "做个", "创建", "制作", "翻译", "润色", "改写",
            "总结", "解释一下", "代码", "编译", "运行", "excel", "ppt", "word", "pdf",
            "画", "图片", "文案", "方案", "简历"
        ]
        if generationIntents.contains(where: { normalized.contains($0) }),
           !userExplicitlyRequestsWebSearch(normalized) {
            return false
        }

        let freshnessSignals = [
            "现在", "目前", "当前", "今天", "今日", "最近", "近期", "最新", "实时", "截至",
            "新版", "版本", "更新", "补丁", "发布", "上线", "公告", "赛季", "活动",
            "价格", "股价", "汇率", "利率", "天气", "新闻", "榜单", "排名", "政策", "法规",
            "current", "latest", "recent", "today", "now", "version", "release", "price", "news"
        ]
        if freshnessSignals.contains(where: { normalized.contains($0) }) {
            return true
        }

        let questionSignals = [
            "哪个", "哪一个", "多少", "什么时候", "是否", "有没有", "了吗", "了没",
            "是什么", "怎么样了", "到哪", "到哪个", "进展", "情况",
            "which", "what", "when", "where", "howmany", "whether"
        ]
        let looksLikeFactualQuestion = questionSignals.contains { normalized.contains($0) }
            || normalized.hasSuffix("?")
            || normalized.hasSuffix("？")
        guard looksLikeFactualQuestion else { return false }

        let stableQuestionStarts = ["为什么", "怎么做", "如何写", "怎么写", "原理", "定义"]
        if stableQuestionStarts.contains(where: { normalized.hasPrefix($0) }) {
            return false
        }

        return true
    }

    private func isWebSearchCapabilityQuestion(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let asksCapability = [
            "你能联网", "你可以联网", "能联网吗", "可以联网吗", "能上网吗", "可以上网吗",
            "你能搜索", "你可以搜索", "能搜索吗", "可以搜索吗", "能联网搜索吗", "可以联网搜索吗",
            "canyousearch", "canyoubrowse", "websearchavailable"
        ].contains { normalized.contains($0) }

        guard asksCapability else { return false }

        let concreteTaskTerms = [
            "帮我", "替我", "给我", "查一下", "查查看", "搜一下", "搜索一下",
            "最新", "今天", "今日", "新闻", "价格", "天气", "股价", "现在的",
            "searchfor", "lookup", "latest", "today", "news", "price", "weather"
        ]
        return !concreteTaskTerms.contains { normalized.contains($0) }
    }

    private func modelWebSearchAvailabilityPrompt() -> String {
        """

        [客户端联网搜索能力]
        Iexa 客户端已接入内置 WKWebView 浏览器联网搜索。用户询问你是否能联网、能搜索、能查最新信息时，请明确回答：可以，并说明搜索由 iOS 内置浏览器工具执行。用户明确要求搜索时，客户端会先用 WKWebView 打开搜索页并读取网页内容；当本轮系统提示里提供 `iexa_native` 浏览器工具时，你也可以主动调用 `web.search` 或 `browser.readable`。联网搜索会优先找较新的结果，但不会只限制到当天，除非用户明确要求今天或 24 小时内。不要声称你无法联网或无法实时搜索。
        [/客户端联网搜索能力]
        """
    }

    private func modelWebSearchContextPrompt(
        result: WebSearchResponse,
        query: String,
        queries: [String] = []
    ) -> String {
        var blocks: [String] = []
        var docsByURL: [String: WebSearchDocument] = [:]
        for doc in result.docs {
            guard let url = doc.metadata["source"] ?? doc.metadata["link"],
                  docsByURL[url] == nil else { continue }
            docsByURL[url] = doc
        }

        for (index, item) in result.items.prefix(6).enumerated() {
            let url = item.link ?? result.filenames.dropFirst(index).first ?? ""
            var lines = [
                "### Result \(index + 1)",
                "Title: \(item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled")"
            ]
            if !url.isEmpty { lines.append("URL: \(url)") }
            if let snippet = item.snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                lines.append("Snippet: \(String(snippet.prefix(600)))")
            }
            if let doc = docsByURL[url] {
                let excerpt = doc.content
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !excerpt.isEmpty {
                    lines.append("Page excerpt: \(String(excerpt.prefix(1200)))")
                }
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        if blocks.isEmpty {
            for (index, doc) in result.docs.prefix(4).enumerated() {
                let url = doc.metadata["source"] ?? doc.metadata["link"] ?? ""
                let title = doc.metadata["title"] ?? doc.metadata["name"] ?? url
                let excerpt = doc.content
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var lines = [
                    "### Result \(index + 1)",
                    "Title: \(title)"
                ]
                if !url.isEmpty { lines.append("URL: \(url)") }
                lines.append("Page excerpt: \(String(excerpt.prefix(1200)))")
                blocks.append(lines.joined(separator: "\n"))
            }
        }

        guard !blocks.isEmpty else { return "" }
        let queryLines = Self.mergeSearchQueries(original: query, generated: queries, limit: 4)
            .map { "- \($0)" }
            .joined(separator: "\n")

        return """

        [内置浏览器联网搜索结果]
        查询：\(query)
        搜索时间：\(Self.webSearchTimestampText())
        实际搜索词：
        \(queryLines)

        以下结果由 Iexa 客户端在发送本轮消息前，通过内置 WKWebView 浏览器搜索/读取网页取得。请基于这些资料回答；涉及最新信息时优先使用这些搜索结果。回答要求：
        - 先直接给结论，再补充必要来源和时间。
        - 天气、油价、新闻、价格、版本等实时问题，必须说清楚信息日期/发布时间；如果结果没有当前日期/当前年份证据，先继续细化搜索，仍没有就明确说“未在搜索结果中找到精确值”，不要编。
        - 如果结果只是搜索页/中转页/摘要，或没有打开到可用正文，请明确说明缺少可验证来源，不要输出任何搜索工具块。
        - 如果用户明确让你“那你搜啊/你自己搜”，不要回答操作步骤给用户；应当直接基于搜索资料回答，资料不足就继续细化搜索。
        - 引用来源时使用普通链接或来源标题，不要输出 cite turn0search 之类隐藏引用标记，也不要输出无法显示的方框字符。
        - 不要声称你无法联网。

        \(blocks.joined(separator: "\n\n"))
        [/内置浏览器联网搜索结果]
        """
    }

    private func webSearchSources(from result: WebSearchResponse) -> [ChatSourceReference] {
        var sources: [ChatSourceReference] = []
        var seen = Set<String>()

        for item in result.items {
            let url = item.link
            let key = url ?? item.title ?? UUID().uuidString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            sources.append(ChatSourceReference(
                id: url ?? key,
                title: item.title,
                url: url,
                snippet: item.snippet,
                type: "web",
                metadata: nil
            ))
        }

        for doc in result.docs {
            let url = doc.metadata["source"] ?? doc.metadata["link"]
            let title = doc.metadata["title"] ?? doc.metadata["name"] ?? url
            let key = url ?? title ?? UUID().uuidString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let excerpt = doc.content
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sources.append(ChatSourceReference(
                id: url ?? key,
                title: title,
                url: url,
                snippet: excerpt.isEmpty ? nil : String(excerpt.prefix(240)),
                type: "web",
                metadata: doc.metadata.isEmpty ? nil : doc.metadata
            ))
        }

        return sources
    }

    private nonisolated static func prefetchFavicons(for result: WebSearchResponse) {
        var faviconURLs: [URL] = []
        var seen = Set<String>()

        func appendCandidates(for rawURL: String?) {
            guard let rawURL, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let candidates = WebsiteFaviconResolver.candidateURLs(for: rawURL, size: 96)
            for candidate in candidates.prefix(4) where seen.insert(candidate.absoluteString).inserted {
                faviconURLs.append(candidate)
            }
        }

        for item in result.items.prefix(8) {
            appendCandidates(for: item.link)
        }
        for doc in result.docs.prefix(8) {
            appendCandidates(for: doc.metadata["source"] ?? doc.metadata["link"])
        }

        guard !faviconURLs.isEmpty else { return }
        Task {
            await ImageCacheService.shared.prefetch(urls: faviconURLs)
        }
    }

    private func contentForModel(
        message: ChatMessage,
        includeImageCanvasInstruction: Bool = false
    ) -> String {
        if Self.isLocalAlpineAgentResult(message) {
            return Self.localAlpineObservationContent(for: message)
        }
        guard message.role == .user else {
            return message.content
        }
        var content = message.content
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeImageCanvasInstruction,
           !trimmedContent.isEmpty,
           Self.looksLikeImageGenerationRequest(trimmedContent) {
            let canvasSize = Self.requestedImageCanvasSize(from: trimmedContent)
            let endpointSize = Self.imageEndpointSize(for: canvasSize)
            content = Self.promptWithImageSizeInstruction(trimmedContent, canvasSize: canvasSize, endpointSize: endpointSize)
        }

        let extraContexts = [
            attachmentContextsByMessageId[message.id],
            webLinkContextsByMessageId[message.id],
            webSearchContextsByMessageId[message.id]
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !extraContexts.isEmpty else {
            return content
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return extraContexts.joined(separator: "\n\n")
        }
        return content + "\n\n" + extraContexts.joined(separator: "\n\n")
    }

    private struct LocalOfficeRevisionSnapshot {
        let kind: LocalNativeOfficeKind
        let fileName: String
        let summary: String
        let draftJSON: String?
    }

    private func localOfficeRevisionSystemContext(for userText: String) -> String? {
        guard Self.looksLikeLocalOfficeRevisionRequest(userText),
              let snapshot = latestLocalOfficeRevisionSnapshot() else {
            return nil
        }

        let actionName: String = {
            switch snapshot.kind {
            case .excel:
                return "office.create_excel"
            case .powerPoint:
                return "office.create_ppt"
            case .word:
                return "office.create_word"
            case .pdf:
                return "office.create_pdf"
            }
        }()
        let draft = snapshot.draftJSON
            .map { Self.contextTextForModel(Self.redactedLocalOfficeDraft($0), label: "latest-office-draft-json", maxInlineCharacters: 10_000) }
            ?? "（未找到 draft.json；请根据上一版摘要和当前用户修改要求重新生成同类型文件。）"

        return """
        [Latest local Office document for revision]
        The user appears to be asking to revise/regenerate the most recent local Office/PDF artifact. Treat this as a file regeneration task, not as ordinary advice.
        Previous document type: \(snapshot.kind.displayName)
        Previous file name: \(snapshot.fileName)
        Previous result summary:
        \(Self.indentForSystemContext(Self.clippedForSystemContext(snapshot.summary, maxCharacters: 2_000)))

        Previous structured draft:
        \(draft)

        If the current user asks to 修改/改/重做/换风格/优化/完善/按截图模板改/重新生成/换成另一版, emit exactly one `iexa_native` JSON block. Use action `\(actionName)` unless the user explicitly asks to convert to another format. Start from the previous structured draft, apply the user's requested changes, keep useful existing content, and update `title`, `file_name`, `theme`, `slides`, `sections`, `sheets`, or PDF `format` as needed.
        Do not merely describe a plan or say what you would change. Regenerate the file.
        [/Latest local Office document for revision]
        """
    }

    private func latestLocalOfficeRevisionSnapshot() -> LocalOfficeRevisionSnapshot? {
        guard let messages = conversation?.messages else { return nil }
        for message in messages.reversed() {
            if let file = message.files.first(where: Self.isLocalOfficeDocumentFile),
               let kind = Self.localOfficeKind(for: file) {
                let draftJSON = Self.localOfficeDraftJSON(for: file)
                return LocalOfficeRevisionSnapshot(
                    kind: kind,
                    fileName: file.name ?? Self.localOfficeFallbackFileName(for: kind),
                    summary: message.content,
                    draftJSON: draftJSON
                )
            }

            if Self.isLocalNativeToolResult(message),
               message.content.range(of: #""document_type"\s*:"#, options: .regularExpression) != nil,
               let payload = Self.firstJSONObjectString(in: message.content),
               let kind = Self.localOfficeKind(fromPayloadJSON: payload) {
                return LocalOfficeRevisionSnapshot(
                    kind: kind,
                    fileName: Self.localOfficeFileName(fromPayloadJSON: payload) ?? Self.localOfficeFallbackFileName(for: kind),
                    summary: message.content,
                    draftJSON: Self.localOfficeDraftJSON(fromPayloadJSON: payload) ?? payload
                )
            }
        }
        return nil
    }

    private static func looksLikeLocalOfficeRevisionRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let revisionMarkers = [
            "改", "修改", "调整", "优化", "完善", "重做", "重新做", "重新生成", "再生成",
            "再做", "换成", "改成", "换风格", "换个", "换一个", "套用", "参考", "照着",
            "按这个", "按截图", "模板", "不对", "不是这样", "不满意", "继续完善",
            "revise", "revision", "modify", "change", "update", "regenerate", "redo",
            "recreate", "restyle", "use this template", "make it like"
        ]
        guard revisionMarkers.contains(where: { lower.contains($0) }) else { return false }
        return true
    }

    private static func isLocalOfficeDocumentFile(_ file: ChatMessageFile) -> Bool {
        if localOfficeKind(for: file) != nil { return true }
        return false
    }

    private static func localOfficeKind(for file: ChatMessageFile) -> LocalNativeOfficeKind? {
        let name = (file.name ?? file.url ?? "").lowercased()
        let contentType = (file.contentType ?? "").lowercased()
        if name.hasSuffix(".pptx") || name.hasSuffix(".ppt") || contentType.contains("presentationml") {
            return .powerPoint
        }
        if name.hasSuffix(".xlsx") || name.hasSuffix(".xls") || contentType.contains("spreadsheetml") {
            return .excel
        }
        if name.hasSuffix(".docx") || name.hasSuffix(".doc") || contentType.contains("wordprocessingml") {
            return .word
        }
        if name.hasSuffix(".pdf") || contentType == "application/pdf" {
            return .pdf
        }
        return nil
    }

    private static func localOfficeFallbackFileName(for kind: LocalNativeOfficeKind) -> String {
        switch kind {
        case .excel:
            return "工作表.xlsx"
        case .powerPoint:
            return "演示文稿.pptx"
        case .word:
            return "文档.docx"
        case .pdf:
            return "文档.pdf"
        }
    }

    private static func localOfficeDraftJSON(for file: ChatMessageFile) -> String? {
        guard let url = localFileURL(from: file.url) else { return nil }
        let draftURL = url.deletingLastPathComponent().appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return nil }
        return try? String(contentsOf: draftURL, encoding: .utf8)
    }

    private static func localFileURL(from reference: String?) -> URL? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else { return nil }
        if let url = URL(string: reference), url.isFileURL {
            return url
        }
        if reference.hasPrefix("/") || reference.contains(":\\") {
            return URL(fileURLWithPath: reference)
        }
        return nil
    }

    private static func firstJSONObjectString(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        return String(text[start...end])
    }

    private static func localOfficeKind(fromPayloadJSON json: String) -> LocalNativeOfficeKind? {
        let documentType = valueFromJSONObjectString(json, key: "document_type")?.lowercased() ?? ""
        let action = valueFromJSONObjectString(json, key: "action")?.lowercased() ?? ""
        if documentType == "ppt" || documentType == "powerpoint" || action.contains("ppt") || action.contains("powerpoint") {
            return .powerPoint
        }
        if documentType == "excel" || action.contains("excel") {
            return .excel
        }
        if documentType == "word" || documentType == "docx" || action.contains("word") || action.contains("docx") {
            return .word
        }
        if documentType == "pdf" || action.contains("pdf") {
            return .pdf
        }
        return nil
    }

    private static func localOfficeFileName(fromPayloadJSON json: String) -> String? {
        valueFromJSONObjectString(json, key: "file_name")
    }

    private static func localOfficeDraftJSON(fromPayloadJSON json: String) -> String? {
        guard let draft = valueFromJSONObjectString(json, key: "draft_url"),
              let url = localFileURL(from: draft),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func valueFromJSONObjectString(_ json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any] else {
            return nil
        }
        if let value = object[key] as? String, !value.isEmpty {
            return value
        }
        if let results = object["results"] as? [[String: Any]] {
            for result in results {
                if let value = result[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func redactedLocalOfficeDraft(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"file://[^"\s,}]+"#,
                with: "local-file",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([A-Za-z]:\\)[^"\n,}]+"#,
                with: "local-file",
                options: .regularExpression
            )
    }

    private static func localAlpineObservationContent(for message: ChatMessage) -> String {
        let metadata = message.metadata ?? [:]
        let command = metadata["iexa_local_alpine_display_command"]
            ?? metadata["iexa_local_alpine_command_preview"]
            ?? ""
        let cwd = metadata["iexa_local_alpine_cwd"] ?? "/mnt/iexa"
        let commandResults = LocalAlpineAgentCommandResult.decodeMetadata(metadata["iexa_local_alpine_command_results"])
        let writtenFiles = LocalAlpineWrittenFile.decodeMetadata(metadata["iexa_local_alpine_written_files"])
        let rawResult = metadata["iexa_local_alpine_raw_result"] ?? message.content

        var lines: [String] = [
            "[Local Alpine observation]",
            "This is real on-device Local Alpine output. Use it as the source of truth.",
            "cwd: \(cwd)"
        ]
        if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("request/command:")
            lines.append(clippedForSystemContext(redactedLocalAlpineInternalPaths(in: command), maxCharacters: 4_000))
        }
        if !commandResults.isEmpty {
            lines.append("command_results:")
            for result in commandResults.suffix(6) {
                let exit = result.exitCode.map(String.init) ?? "unknown"
                let redactedCommand = redactedLocalAlpineInternalPaths(in: result.command)
                let redactedOutput = redactedLocalAlpineInternalPaths(in: result.outputPreview)
                let output = redactedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "（无输出）"
                    : contextTextForModel(
                        redactedOutput,
                        label: "local-alpine-command-output",
                        maxInlineCharacters: 8_000
                    )
                lines.append("""
                - command: \(redactedCommand)
                  cwd: \(result.cwd)
                  exit_code: \(exit)
                  output:
                \(indentForSystemContext(output))
                """)
            }
        } else if !rawResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("raw_output:")
            lines.append(contextTextForModel(
                redactedLocalAlpineInternalPaths(in: rawResult),
                label: "local-alpine-raw-output",
                maxInlineCharacters: 10_000
            ))
        }
        if !writtenFiles.isEmpty {
            lines.append("written_files:")
            lines.append(writtenFiles.map { "- \($0.path) (\($0.lineCount) 行, \($0.byteCount) bytes)" }.joined(separator: "\n"))
        }
        lines.append("[/Local Alpine observation]")
        return lines.joined(separator: "\n")
    }

    private func attachResolvedVideoFile(messageId: String, video: ResolvedWebVideo) {
        let file = ChatMessageFile(
            type: "video",
            url: video.url,
            name: video.title,
            contentType: "video/mp4",
            displayURL: nil
        )
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if conversation?.messages[index].files.contains(where: { $0.url == file.url }) != true {
            conversation?.messages[index].files.append(file)
        }
        conversation?.history.updateNode(id: messageId) { node in
            if !node.files.contains(where: { $0.url == file.url }) {
                node.files.append(file)
            }
        }
    }

    private func attachResolvedImageFile(messageId: String, image: ResolvedWebImage) {
        let file = ChatMessageFile(
            type: "image",
            url: image.url,
            name: image.title,
            contentType: Self.imageContentType(for: image.url),
            displayURL: nil
        )
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if conversation?.messages[index].files.contains(where: { $0.url == file.url }) != true {
            conversation?.messages[index].files.append(file)
        }
        conversation?.history.updateNode(id: messageId) { node in
            if !node.files.contains(where: { $0.url == file.url }) {
                node.files.append(file)
            }
        }
    }

    private func attachLocalAlpineGeneratedMediaIfNeeded(messageId: String) async {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let message = conversation!.messages[index]
        guard Self.isLocalAlpineAgentResult(message) else { return }

        let paths = Self.localAlpineGeneratedMediaPaths(from: message)
        guard !paths.isEmpty else { return }

        var appended: [ChatMessageFile] = []
        for path in paths {
            guard let file = await localAlpineGeneratedImageFile(for: path) else { continue }
            if appended.contains(where: { $0.url == file.url || $0.displayURL == file.displayURL }) {
                continue
            }
            appended.append(file)
        }
        guard !appended.isEmpty,
              let currentIndex = conversation?.messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        var files = conversation?.messages[currentIndex].files ?? []
        var didAppend = false
        for file in appended {
            guard !files.contains(where: {
                $0.url == file.url
                    || $0.displayURL == file.displayURL
                    || ($0.name == file.name && Self.isImageFile($0))
            }) else { continue }
            files.append(file)
            didAppend = true
        }
        guard didAppend else { return }

        conversation?.messages[currentIndex].files = files
        conversation?.history.updateNode(id: messageId) { node in
            node.files = files
            node.done = true
        }
    }

    private func localAlpineGeneratedImageFile(for path: String) async -> ChatMessageFile? {
        let normalizedPath = Self.normalizedLocalAlpineSharedMediaPath(path)
        guard let normalizedPath,
              Self.localAlpinePathLooksLikeImage(normalizedPath),
              let data = try? await LocalAlpineTerminalService.shared.readFile(path: normalizedPath),
              !data.isEmpty else {
            return nil
        }

        let contentType = Self.imageContentType(for: normalizedPath)
        let displayURL = Self.writeLocalAlpineImageToDisplayCache(
            data: data,
            sourcePath: normalizedPath,
            contentType: contentType
        ) ?? "data:\(contentType);base64,\(data.base64EncodedString())"
        let fileName = (normalizedPath as NSString).lastPathComponent
        return ChatMessageFile(
            type: "image",
            url: "local-alpine:\(normalizedPath)",
            name: fileName.isEmpty ? Self.imageFileName(for: normalizedPath, contentType: contentType) : fileName,
            contentType: contentType,
            displayURL: displayURL
        )
    }

    private static func writeLocalAlpineImageToDisplayCache(
        data: Data,
        sourcePath: String,
        contentType: String
    ) -> String? {
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("iexa-local-alpine-images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = (sourcePath as NSString).pathExtension
            let fallbackExt = Self.fileExtension(forImageContentType: contentType)
            let fileURL = directory.appendingPathComponent("\(UUID().uuidString).\(ext.isEmpty ? fallbackExt : ext)")
            try data.write(to: fileURL, options: [.atomic])
            return fileURL.absoluteString
        } catch {
            return nil
        }
    }

    private static func localAlpineGeneratedMediaPaths(from message: ChatMessage) -> [String] {
        let metadata = message.metadata ?? [:]
        let writtenFiles = LocalAlpineWrittenFile.decodeMetadata(metadata["iexa_local_alpine_written_files"])
        var candidates = writtenFiles.map(\.path)

        let commandResults = LocalAlpineAgentCommandResult.decodeMetadata(metadata["iexa_local_alpine_command_results"])
        candidates.append(contentsOf: commandResults.flatMap { localAlpineImagePaths(in: $0.outputPreview) })
        candidates.append(contentsOf: localAlpineImagePaths(in: metadata["iexa_local_alpine_raw_result"] ?? ""))
        candidates.append(contentsOf: localAlpineImagePaths(in: message.content))

        var seen = Set<String>()
        return candidates.compactMap { rawPath in
            guard let path = normalizedLocalAlpineSharedMediaPath(rawPath),
                  localAlpinePathLooksLikeImage(path),
                  seen.insert(path).inserted else {
                return nil
            }
            return path
        }
    }

    private static func localAlpineImagePaths(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let patterns = [
            #"(?:^|[\s`'"])(/mnt/iexa/[^\s`'"]+\.(?:png|jpe?g|webp|gif|bmp|avif))(?:$|[\s`'".,;:!?)\]])"#,
            #"(?:^|[\s`'"])([A-Za-z0-9._/\-]+?\.(?:png|jpe?g|webp|gif|bmp|avif))(?:$|[\s`'".,;:!?)\]])"#
        ]
        var paths: [String] = []
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                paths.append(nsText.substring(with: match.range(at: 1)))
            }
        }
        return paths
    }

    private static func normalizedLocalAlpineSharedMediaPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'“”‘’，。；：、）)]}")))
        guard !path.isEmpty else { return nil }
        path = path.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("file://") {
            guard let url = URL(string: path) else { return nil }
            path = url.path
        }
        if path.hasPrefix("/mnt/iexa/") {
            path = String(path.dropFirst("/mnt/iexa".count))
        } else if path == "/mnt/iexa" {
            path = "/"
        } else if path.hasPrefix("./") {
            path = String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = "/" + path
        }
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        guard !path.contains("../"), !path.contains("/..") else { return nil }
        return path
    }

    private static func localAlpinePathLooksLikeImage(_ path: String) -> Bool {
        path.lowercased().range(of: #"\.(png|jpe?g|webp|gif|bmp|avif)$"#, options: .regularExpression) != nil
    }

    private func buildAPIMessagesAsync(
        imageCanvasInstructionMessageId: String? = nil,
        includeLocalAlpineExecutionContext: Bool? = nil,
        preferLocalAlpineNativeTools: Bool? = nil
    ) async -> [[String: Any]] {
        guard let conversation else { return [] }
        var apiMessages: [[String: Any]] = []
        let asyncEffectiveSP: String? = {
            if let cp = conversation.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            return conversation.systemPrompt
        }()
        let latestUserTextForLocalAlpine = conversation.messages.last(where: {
            $0.role == .user && !Self.isLocalAlpineAgentResult($0)
        })?.content
        let localAlpineModelId = selectedModelId ?? conversation.model ?? ""
        let localAlpineTerminalApplies = terminalEnabled && selectedTerminalIsLocalAlpine
            && !(latestUserTextForLocalAlpine.map {
                shouldKeepMediaGenerationRequestOffLocalAlpine($0, modelId: localAlpineModelId)
            } ?? false)
            && !(latestUserTextForLocalAlpine.map(Self.shouldKeepNativeLinkResolverOffLocalAlpine) ?? false)
        let shouldIncludeLocalAlpineContext: Bool = {
            if let includeLocalAlpineExecutionContext {
                return includeLocalAlpineExecutionContext
            }
            return localAlpineTerminalApplies
        }()
        let memoryContext = await localMemorySystemContext()
        let workspaceContext: String? = {
            if shouldIncludeLocalAlpineContext || localAlpineTerminalApplies {
                return Self.workspaceDisabledForLocalAlpineSystemContext()
            }
            return shouldExecuteLocalWorkspaceAgentForCurrentRequest()
                ? Self.projectContinuitySystemContext()
                : Self.workspaceGuardSystemContext()
        }()
        let shouldPreferNativeLocalAlpineTools =
            preferLocalAlpineNativeTools
            ?? (shouldIncludeLocalAlpineContext && shouldUseLocalAlpineNativeTools(for: selectedModelId ?? conversation.model))
        let alpineContext = shouldIncludeLocalAlpineContext
            ? (shouldPreferNativeLocalAlpineTools
                ? Self.localAlpineNativeAgentSystemContext()
                : Self.localAlpineAgentSystemContext())
            : nil
        let alpineExecutionStateContext = shouldIncludeLocalAlpineContext
            ? Self.localAlpineExecutionStateSystemContext(from: conversation.messages)
            : nil
        let webSearchToolContext: String? = nil
        let localSoulContext = LocalSoulService.shared.contextPrompt()
        let localSkillsContext = LocalSkillsService.shared.contextPrompt()
        let localNativeToolContext: String? = {
            guard let latestUserTextForLocalAlpine else { return nil }
            let officeRevisionContext = localOfficeRevisionSystemContext(for: latestUserTextForLocalAlpine)
            let shouldExposeBrowserTools = isChatWebSearchAllowed
                && webSearchEnabled
            let shouldExpose = Self.shouldExposeLocalNativeTools(latestUserTextForLocalAlpine)
                || shouldExposeBrowserTools
                || officeRevisionContext != nil
            guard shouldExpose else { return nil }
            return [Self.localNativeToolSystemContext(), officeRevisionContext]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }()
        let modelCapabilityContext = Self.modelCapabilitySystemContext(
            model: selectedModel,
            modelId: selectedModelId ?? conversation.model
        )
        let feedbackPreferenceContext = AssistantFeedbackPreferenceStore.systemContext()
        let combinedSystemPrompt = [asyncEffectiveSP, modelCapabilityContext, workspaceContext, alpineContext, alpineExecutionStateContext, webSearchToolContext, localNativeToolContext, localSoulContext, localSkillsContext, memoryContext, feedbackPreferenceContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !combinedSystemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": combinedSystemPrompt])
        }
        for message in conversation.messages where !message.isStreaming
            && !Self.isLocalWorkspaceAgentResult(message) {
            let isNativeToolResult = Self.isLocalNativeToolResult(message)
            let isLocalAlpineResult = Self.isLocalAlpineAgentResult(message)
            if isNativeToolResult {
                let modelContent = contentForModel(
                    message: message,
                    includeImageCanvasInstruction: false
                )
                apiMessages.append(["role": "system", "content": modelContent])
                continue
            }
            if isLocalAlpineResult && Self.isLocalAlpineProtocolCorrectionMessage(message) {
                continue
            }
            if Self.isLocalAlpineHiddenCorrectionParent(message)
                || Self.isLocalAlpineHiddenToolParent(message) {
                continue
            }
            if isLocalAlpineResult {
                // Local Alpine results are represented once in the structured execution-state
                // system section above. Re-sending every result as a separate system message
                // duplicates tool output, slows agent turns, and makes continuation policy noisier.
                continue
            }
            let modelContent = contentForModel(
                message: message,
                includeImageCanvasInstruction: message.id == imageCanvasInstructionMessageId
            )
            let modelRole = isLocalAlpineResult ? "system" : message.role.rawValue
            let imageFiles = message.files.filter { f in
                f.type == "image" || (f.contentType ?? "").hasPrefix("image/")
            }
            let nonImageFiles = message.files.filter { f in
                f.type != "image" && !(f.contentType ?? "").hasPrefix("image/")
            }

            if !imageFiles.isEmpty && message.role == .user {
                // Build multimodal content array (OpenAI vision format)
                // Fetch image base64 from server, matching Flutter behavior
                var contentArray: [[String: Any]] = []
                if !modelContent.isEmpty {
                    contentArray.append(["type": "text", "text": modelContent])
                }
                for imgFile in imageFiles {
                    if let fileId = imgFile.url, !fileId.isEmpty {
                        if let displayURL = imgFile.displayURL, displayURL.hasPrefix("data:image/") {
                            contentArray.append([
                                "type": "image_url",
                                "image_url": ["url": displayURL]
                            ])
                        } else if fileId.hasPrefix("data:image/") {
                            // Already a data URL
                            contentArray.append([
                                "type": "image_url",
                                "image_url": ["url": fileId]
                            ])
                        } else {
                            // Fetch from server, downsample to ≤ 2 MP, then base64-encode.
                            // The server stores the original full-resolution file; without
                            // downsampling here, the base64 payload easily exceeds the
                            // vision API's 5 MB per-image limit.
                            if let apiClient = manager?.apiClient {
                                do {
                                    let (rawData, contentType) = try await apiClient.getFileContent(id: fileId)
                                    let data = FileAttachmentService.downsampleForUpload(data: rawData)
                                    let base64 = data.base64EncodedString()
                                    let mimeType = contentType.hasPrefix("image/") ? contentType : "image/jpeg"
                                    let dataUrl = "data:\(mimeType);base64,\(base64)"
                                    contentArray.append([
                                        "type": "image_url",
                                        "image_url": ["url": dataUrl]
                                    ])
                                } catch {
                                    logger.warning("Failed to fetch image content for \(fileId): \(error)")
                                    // Fallback: send file ID, server may resolve it
                                    contentArray.append([
                                        "type": "image_url",
                                        "image_url": ["url": fileId]
                                    ])
                                }
                            }
                        }
                    }
                }

                var msgDict: [String: Any] = [
                    "role": modelRole,
                    "content": contentArray
                ]

                if !nonImageFiles.isEmpty {
                    msgDict["files"] = nonImageFiles.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        guard !Self.isLocalOnlyFileReference(id) else { return nil }
                        return ["type": "file", "id": id, "url": id]
                    }
                }

                apiMessages.append(msgDict)
            } else {
                var msgDict: [String: Any] = [
                    "role": modelRole,
                    "content": modelContent
                ]

                if !message.files.isEmpty {
                    msgDict["files"] = message.files.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        guard !Self.isLocalOnlyFileReference(id) else { return nil }
                        return ["type": f.type ?? "file", "id": id, "url": id]
                    }
                } else if !message.attachmentIds.isEmpty {
                    msgDict["files"] = message.attachmentIds.map { id -> [String: Any] in
                        ["type": "file", "id": id, "url": id]
                    }
                }

                apiMessages.append(msgDict)
            }
        }
        let compacted = Self.compactMessagesIfNeeded(
            apiMessages,
            model: selectedModel,
            modelId: selectedModelId ?? conversation.model
        )
        contextBudgetStatus = compacted.status
        return compacted.messages
    }

    private func parseStatusData(_ data: [String: Any]) -> ChatStatusUpdate {
        // Parse queries from various formats (array of strings, or single string)
        var queries: [String] = []
        if let qArray = data["queries"] as? [String] {
            queries = qArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else if let qStr = data["queries"] as? String, !qStr.isEmpty {
            queries = [qStr]
        }

        var items: [ChatStatusItem] = []
        if let rawItems = data["items"] as? [[String: Any]] {
            items = rawItems.compactMap { item in
                let title = item["title"] as? String
                    ?? item["name"] as? String
                    ?? item["label"] as? String
                let link = item["link"] as? String
                    ?? item["url"] as? String
                    ?? item["source"] as? String
                let snippet = item["snippet"] as? String
                    ?? item["description"] as? String
                let thumbnail = item["thumbnailURL"] as? String
                    ?? item["thumbnail_url"] as? String
                    ?? item["image"] as? String
                guard title != nil || link != nil else { return nil }
                return ChatStatusItem(
                    title: title,
                    link: link,
                    snippet: snippet,
                    thumbnailURL: thumbnail
                )
            }
        }

        return ChatStatusUpdate(
            action: data["action"] as? String,
            description: data["description"] as? String,
            done: data["done"] as? Bool,
            hidden: data["hidden"] as? Bool,
            urls: (data["urls"] as? [String]) ?? [],
            occurredAt: .now,
            items: items,
            count: data["count"] as? Int ?? (data["count"] as? Double).map { Int($0) },
            query: data["query"] as? String,
            queries: queries
        )
    }

    /// Parses Iexa native server source payloads into ChatSourceReference objects.
    /// Matches the Flutter `parseIexa native serverSourceList` logic which handles
    /// nested `source`, `document`, `metadata`, `distances` arrays.
    ///
    /// Iexa native server sends sources as:
    /// ```json
    /// [{ "source": {...}, "document": ["...","..."],
    ///    "metadata": [{"source":"url1","name":"..."}, {"source":"url2",...}],
    ///    "distances": [0.5, 0.7] }]
    /// ```
    /// Each metadata item = one unique source reference. The Flutter parser
    /// groups by metadata.source key and creates one ChatSourceReference per
    /// unique URL.
    private func parseSources(_ array: [[String: Any]]) -> [ChatSourceReference]? {
        func expandedSourceEntries(from entries: [[String: Any]]) -> [[String: Any]] {
            var expanded: [[String: Any]] = []

            func append(_ entry: [String: Any]) {
                if let annotations = entry["annotations"] as? [[String: Any]] {
                    for annotation in annotations {
                        append(annotation)
                    }
                    let hasOwnSourceFields = entry["source"] != nil
                        || entry["url"] != nil
                        || entry["link"] != nil
                        || entry["metadata"] != nil
                        || entry["document"] != nil
                        || entry["id"] != nil
                        || entry["title"] != nil
                        || entry["name"] != nil
                    if !hasOwnSourceFields {
                        return
                    }
                }

                if let citation = entry["url_citation"] as? [String: Any] {
                    var normalized = citation
                    normalized["type"] = normalized["type"] ?? entry["type"] ?? "url_citation"
                    if normalized["source"] == nil, let url = normalized["url"] {
                        normalized["source"] = url
                    }
                    expanded.append(normalized)
                    return
                }

                if (entry["type"] as? String) == "url_citation" {
                    expanded.append(entry)
                    return
                }

                expanded.append(entry)
            }

            for entry in entries {
                append(entry)
            }
            return expanded
        }

        // Accumulate by unique key (URL or fallback index)
        var accumulated: [(key: String, url: String?, title: String?, snippet: String?, type: String?, meta: [String: String])] = []
        var seenKeys = Set<String>()
        var fallbackIdx = 0

        for entry in expandedSourceEntries(from: array) {
            // Extract nested source object
            var baseSource = (entry["source"] as? [String: Any]) ?? [:]
            if let sourceValue = entry["source"], !(sourceValue is [String: Any]) {
                baseSource["source"] = sourceValue
            }
            for key in ["id", "name", "title", "url", "link", "source", "type"] {
                if let value = entry[key], baseSource[key] == nil {
                    baseSource[key] = value
                }
            }

            let documents = (entry["document"] as? [Any]) ?? []
            let metadataRaw = entry["metadata"]
            let metadataList: [[String: Any]]
            if let list = metadataRaw as? [[String: Any]] {
                metadataList = list
            } else if let single = metadataRaw as? [String: Any] {
                metadataList = [single]
            } else {
                metadataList = []
            }

            // Determine iteration count — max of documents, metadata, distances
            let loopCount = max(1, max(documents.count, metadataList.count))

            for i in 0..<loopCount {
                let meta = i < metadataList.count ? metadataList[i] : [:]
                let document = i < documents.count ? documents[i] : nil

                // Resolve unique key for this source (usually the URL)
                let idCandidate: String? = {
                    for k in ["source", "id"] {
                        if let v = meta[k] as? String, !v.isEmpty { return v }
                    }
                    if let v = baseSource["id"] as? String, !v.isEmpty { return v }
                    if let v = baseSource["source"] as? String, !v.isEmpty { return v }
                    return nil
                }()

                let key = idCandidate ?? "__fallback_\(fallbackIdx)"
                if idCandidate == nil { fallbackIdx += 1 }

                // Skip duplicates with the same key
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)

                // Resolve URL
                let url: String? = {
                    for k in ["source", "url", "link"] {
                        if let v = meta[k] as? String, v.hasPrefix("http") { return v }
                    }
                    for k in ["source", "url", "link"] {
                        if let v = baseSource[k] as? String, v.hasPrefix("http") { return v }
                    }
                    if let v = baseSource["url"] as? String, v.hasPrefix("http") { return v }
                    if let id = idCandidate, id.hasPrefix("http") { return id }
                    return nil
                }()

                // Resolve title
                let title: String? = {
                    if let n = meta["name"] as? String, !n.isEmpty { return n }
                    if let t = meta["title"] as? String, !t.isEmpty { return t }
                    if let n = baseSource["name"] as? String, !n.isEmpty { return n }
                    if let t = baseSource["title"] as? String, !t.isEmpty { return t }
                    if let id = idCandidate, !id.isEmpty { return id }
                    return nil
                }()

                // Extract snippet from document
                let snippet: String? = {
                    if let doc = document {
                        if let s = doc as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                            return String(s.trimmingCharacters(in: .whitespaces).prefix(200))
                        }
                    }
                    return nil
                }()

                let type = (baseSource["type"] as? String) ?? (meta["type"] as? String)

                // Build metadata dict
                var metaDict: [String: String] = [:]
                for (k, v) in meta {
                    if let s = v as? String { metaDict[k] = s }
                }

                accumulated.append((
                    key: key,
                    url: url,
                    title: title,
                    snippet: snippet,
                    type: type,
                    meta: metaDict
                ))
            }
        }

        let results = accumulated.map { item in
            ChatSourceReference(
                id: item.key.hasPrefix("__fallback_") ? nil : item.key,
                title: item.title,
                url: item.url,
                snippet: item.snippet,
                type: item.type,
                metadata: item.meta.isEmpty ? nil : item.meta
            )
        }

        return results.isEmpty ? nil : results
    }

    private func extractErrorContent(from data: [String: Any]) -> String {
        // Try multiple error formats used by Iexa native server/LiteLLM
        if let err = data["error"] {
            if let errMap = err as? [String: Any] {
                if let content = errMap["content"] as? String, !content.isEmpty { return content }
                if let message = errMap["message"] as? String, !message.isEmpty { return message }
            }
            if let errStr = err as? String, !errStr.isEmpty { return errStr }
        }
        if let msg = data["message"] as? String, !msg.isEmpty { return msg }
        if let detail = data["detail"] as? String, !detail.isEmpty { return detail }
        // Try to extract from nested content
        if let content = data["content"] as? String, !content.isEmpty { return content }
        // Last resort: serialize entire payload for debugging
        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8), !jsonStr.isEmpty {
            return jsonStr
        }
        return "An unexpected error occurred"
    }

    /// Extracts and updates tasks from a create_tasks or update_task tool call block
    /// embedded in the streaming assistant message content.
    /// Only processes tool calls that are fully complete (isDone == true) to avoid
    /// parsing truncated/invalid JSON that arrives token-by-token during streaming.
    private func extractAndApplyTasksFromContent(_ content: String) {
        guard content.contains("create_tasks") || content.contains("update_task") else { return }

        let ordered = ToolCallParser.parseOrdered(content)
        for segment in ordered.segments {
            guard case .toolCall(let tc) = segment else { continue }
            guard tc.name == "create_tasks" || tc.name == "update_task" else { continue }
            // Only process complete tool calls — streaming delivers truncated JSON
            // in the arguments attribute which JSONSerialization cannot parse.
            guard tc.isDone else { continue }

            if tc.name == "create_tasks" {
                // Prefer tc.result (server-authoritative, contains assigned IDs),
                // fall back to tc.arguments using robust multi-strategy parsing.
                let taskDict = parseTaskJSON(tc.result) ?? parseTaskJSON(tc.arguments)
                if let taskArray = taskDict?["tasks"] as? [[String: Any]] {
                    let parsed = taskArray.compactMap { t -> ChatTask? in
                        guard let id = t["id"] as? String,
                              let content = t["content"] as? String,
                              let status = t["status"] as? String
                        else { return nil }
                        return ChatTask(id: id, content: content, status: status)
                    }
                    if !parsed.isEmpty {
                        tasks = parsed
                        conversation?.tasks = parsed
                    }
                }
            } else if tc.name == "update_task" {
                // Prefer tc.result — server returns the full updated task list after each update_task call.
                // Fall back to single-task delta from tc.arguments if result is unavailable.
                if let resultDict = parseTaskJSON(tc.result),
                   let taskArray = resultDict["tasks"] as? [[String: Any]] {
                    let parsed = taskArray.compactMap { t -> ChatTask? in
                        guard let id = t["id"] as? String,
                              let content = t["content"] as? String,
                              let status = t["status"] as? String
                        else { return nil }
                        return ChatTask(id: id, content: content, status: status)
                    }
                    if !parsed.isEmpty {
                        tasks = parsed
                        conversation?.tasks = parsed
                    }
                } else {
                    // Fallback: apply a single-task status change from arguments
                    let argsDict = parseTaskJSON(tc.arguments)
                    if let json = argsDict,
                       let taskId = json["id"] as? String ?? json["task_id"] as? String,
                       let newStatus = json["status"] as? String {
                        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
                            tasks[idx].status = newStatus
                        }
                        if let convIdx = conversation?.tasks.firstIndex(where: { $0.id == taskId }) {
                            conversation?.tasks[convIdx].status = newStatus
                        }
                    }
                }
            }
        }
    }

    /// Robustly parses a JSON string into a `[String: Any]` dictionary.
    /// Handles four encoding variations seen in server-sent tool call attributes:
    /// 1. Plain JSON object string
    /// 2. Double-encoded: outer JSON is a string whose value is a JSON object
    /// 3. Backslash-escaped quotes (`\"`) that must be stripped before parsing
    /// 4. Regex extraction of individual task objects as a last resort
    private func parseTaskJSON(_ source: String?) -> [String: Any]? {
        guard let source, !source.isEmpty else { return nil }

        // Strategy 1: direct parse
        if let data = source.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Strategy 2: double-encoded — outer value is a JSON string wrapping another JSON object
        if let data = source.data(using: .utf8),
           let str = try? JSONSerialization.jsonObject(with: data) as? String,
           let innerData = str.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
            return json
        }

        // Strategy 3: strip backslash-escaped quotes produced by HTML attribute encoding
        let unescaped = source.replacingOccurrences(of: "\\\"", with: "\"")
        if let data = unescaped.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Strategy 4: regex extraction — pull task objects directly from the raw string
        let taskPattern = #"\{[^{}]*"id"\s*:\s*"[^"]+[^{}]*"content"\s*:\s*"[^"]+[^{}]*"status"\s*:\s*"[^"]+"[^{}]*\}"#
        if let regex = try? NSRegularExpression(pattern: taskPattern),
           let tasksRange = source.range(of: #""tasks"\s*:\s*\["#, options: .regularExpression) {
            let searchString = String(source[tasksRange.lowerBound...])
            let nsSearch = searchString as NSString
            let matches = regex.matches(in: searchString, range: NSRange(location: 0, length: nsSearch.length))
            let taskDicts: [[String: Any]] = matches.compactMap { match in
                let raw = nsSearch.substring(with: match.range)
                guard let d = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return nil }
                return obj
            }
            if !taskDicts.isEmpty {
                return ["tasks": taskDicts]
            }
        }

        return nil
    }

    private func scheduleLocalWorkspaceAgentIfNeeded(messageId: String, content: String, error: ChatMessageError?) {
        guard error == nil else { return }
        guard let role = conversation?.messages.first(where: { $0.id == messageId })?.role, role == .assistant else { return }
        guard shouldExecuteLocalWorkspaceAgentForCurrentRequest() else { return }
        guard !localWorkspaceAgentExecutedMessageIds.contains(messageId) else { return }

        let executableContent: String
        if content.localizedCaseInsensitiveContains("iexa_workspace") {
            executableContent = content
        } else if let fallback = fallbackWorkspaceAgentBlockForCurrentRequest() {
            executableContent = fallback
        } else {
            return
        }

        localWorkspaceAgentExecutedMessageIds.insert(messageId)
        Task { [weak self] in
            await self?.executeLocalWorkspaceAgent(messageId: messageId, content: executableContent)
        }
    }

    @discardableResult
    private func scheduleLocalAlpineMissingToolCorrectionIfNeeded(
        messageId: String,
        content: String,
        error: ChatMessageError?
    ) -> Bool {
        guard error == nil else { return false }
        guard terminalEnabled && selectedTerminalIsLocalAlpine else { return false }
        guard !localAlpineAgentStopRequested else { return false }
        guard !localAlpineAutoExecutionPaused else { return false }
        let promptLeakDetected = Self.containsInternalPromptLeak(content)
        guard promptLeakDetected || !Self.contentContainsLocalAlpineInstruction(content) else { return false }
        guard let message = conversation?.messages.first(where: { $0.id == messageId }),
              message.role == .assistant,
              message.metadata?["iexa_local_alpine_final_summary"] == nil,
              message.metadata?["iexa_local_alpine_missing_tool_correction"] == nil else {
            return false
        }
        if message.metadata?["iexa_local_alpine_continuation"] == "true" {
            return false
        }
        guard let latestUserText = conversation?.messages.last(where: {
            $0.role == .user && !Self.isLocalAlpineAgentResult($0)
        })?.content,
              Self.localAlpineUserRequestRequiresHostExecution(latestUserText) else {
            return false
        }
        let effectiveModelId = selectedModelId ?? message.model ?? conversation?.model ?? ""
        if shouldKeepMediaGenerationRequestOffLocalAlpine(latestUserText, modelId: effectiveModelId) {
            return false
        }
        guard !localAlpineMissingToolCorrectionParentIds.contains(messageId) else {
            return false
        }
        localAlpineMissingToolCorrectionParentIds.insert(messageId)
        localAlpineContinuationParentIds.insert(messageId)
        markLocalAlpineCorrectionParentHidden(messageId: messageId)
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = Task { [weak self] in
            await self?.startLocalAlpineMissingToolCorrection(
                parentId: messageId,
                assistantContent: content,
                latestUserText: latestUserText
            )
        }
        return true
    }

    private func markLocalAlpineCorrectionParentHidden(messageId: String) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        var metadata = conversation?.messages[index].metadata ?? [:]
        metadata["iexa_local_alpine_hidden_correction_parent"] = "true"
        conversation?.messages[index].metadata = metadata
        conversation?.history.updateNode(id: messageId) { node in
            var nodeMetadata = node.metadata ?? [:]
            nodeMetadata["iexa_local_alpine_hidden_correction_parent"] = "true"
            node.metadata = nodeMetadata
        }
    }

    private func startLocalAlpineMissingToolCorrection(
        parentId: String,
        assistantContent: String,
        latestUserText: String
    ) async {
        guard !localAlpineAgentStopRequested,
              let manager,
              let conversation,
              conversation.messages.contains(where: { $0.id == parentId }),
              let modelId = selectedModelId ?? conversation.model,
              !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localAlpineContinuationParentIds.remove(parentId)
            return
        }

        let assistantMessageId = UUID().uuidString
        let status = ChatStatusUpdate(
            action: "local_alpine_agent",
            description: "正在准备本地执行...",
            done: false
        )
        let message = ChatMessage(
            id: assistantMessageId,
            role: .assistant,
            content: "",
            timestamp: .now,
            model: modelId,
            isStreaming: true,
            statusHistory: [status],
            metadata: [
                "iexa_local_alpine_continuation": "true",
                "iexa_local_alpine_missing_tool_correction": parentId
            ]
        )
        let node = HistoryNode(
            id: assistantMessageId,
            parentId: parentId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: message.timestamp,
            model: modelId,
            done: false,
            statusHistory: [status]
        )
        self.conversation?.messages.append(message)
        self.conversation?.history.addNode(node)
        self.conversation?.history.appendChildId(assistantMessageId, to: parentId)
        self.conversation?.history.currentId = assistantMessageId
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

        var apiMessages = await buildAPIMessagesAsync(
            includeLocalAlpineExecutionContext: true,
            preferLocalAlpineNativeTools: false
        )
        Self.appendLocalAlpineMissingToolCorrectionInstruction(
            to: &apiMessages,
            userGoal: latestUserText,
            assistantContent: assistantContent
        )

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        activeTaskId = nil
        sessionId = UUID().uuidString
        beginStreamingBackgroundTaskIfNeeded()
        streamingStore.beginStreaming(
            messageId: assistantMessageId,
            modelId: modelId,
            initialStatusHistory: [status]
        )
        startLocalAlpineContinuationWatchdog(
            assistantMessageId: assistantMessageId,
            parentId: parentId,
            modelId: modelId,
            finalSummaryOnly: false
        )

        let effectiveChatId = conversationId ?? self.conversation?.id
        let socket = socketService
        var socketConnected = socket?.isConnected ?? false
        if !isOpenAICompatibleProvider, let socket, !socketConnected {
            socketConnected = await socket.ensureConnected(timeout: 8.0)
        }
        let socketSessionId = socket?.sid ?? sessionId
        let usePollingFallback = !isOpenAICompatibleProvider && !socketConnected

        if !isOpenAICompatibleProvider {
            await syncToServerViaTree()
            if socketConnected, let socket {
                registerSocketHandlers(
                    socket: socket,
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId
                )
            }
        }

        streamingTask = Task { [weak self] in
            guard let self else { return }
            let acc = ContentAccumulator()
            var exactUsage: [String: Any]?

            do {
                var request = ChatCompletionRequest(
                    model: modelId,
                    messages: apiMessages,
                    stream: true,
                    chatId: effectiveChatId,
                    sessionId: socketSessionId,
                    messageId: assistantMessageId,
                    parentId: parentId
                )
                request.toolChoice = "none"
                await self.populateCommonRequestFields(&request)

                if self.isOpenAICompatibleProvider {
                    let sseStream = try await manager.sendPreferredOpenAIStreaming(request: request)
                    for try await event in sseStream {
                        if Task.isCancelled { break }
                        if let usage = event.usage, !usage.isEmpty {
                            exactUsage = usage
                        }
                        self.applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                        if event.isFinished { break }
                    }
                    if Task.isCancelled { return }
                    acc.markReasoningDone()
                    await self.finishLocalAlpineContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: acc.content,
                        usage: exactUsage
                    )
                    return
                }

                if request.isPipeModel {
                    let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                    for try await event in sseStream {
                        if Task.isCancelled { break }
                        if let usage = event.usage, !usage.isEmpty {
                            exactUsage = usage
                        }
                        self.applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                        if event.isFinished { break }
                    }
                    if Task.isCancelled { return }
                    acc.markReasoningDone()
                    await self.finishLocalAlpineContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: acc.content,
                        usage: exactUsage
                    )
                    return
                }

                let json = try await manager.sendMessageHTTP(request: request)
                if let err = json["error"] as? String, !err.isEmpty {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: Self.cleanedProviderErrorMessage(err) ?? err)
                    )
                    self.cleanupStreaming()
                    return
                }
                if let taskId = json["task_id"] as? String {
                    self.activeTaskId = taskId
                }
                if usePollingFallback, let chatId = effectiveChatId {
                    await self.pollLocalAlpineContinuation(
                        chatId: chatId,
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        socketSessionId: socketSessionId
                    )
                } else if usePollingFallback {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: "当前会话无法继续本地任务。")
                    )
                    self.cleanupStreaming()
                } else {
                    self.logger.info("Local Alpine missing-tool correction HTTP POST done - waiting for socket events")
                }
            } catch {
                if !Task.isCancelled {
                    let message = Self.localizedGenerationError(error)
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: acc.content,
                        isStreaming: false,
                        error: ChatMessageError(content: message)
                    )
                    self.cleanupStreaming()
                    await self.persistLocalConversationIfNeeded()
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
        }
    }

    private func scheduleLocalAlpineAgentIfNeeded(messageId: String, content: String, error: ChatMessageError?) {
        guard error == nil else { return }
        guard terminalEnabled && selectedTerminalIsLocalAlpine else { return }
        guard !localAlpineAgentStopRequested else { return }
        guard !localAlpineAutoExecutionPaused else { return }
        guard let message = conversation?.messages.first(where: { $0.id == messageId }),
              message.role == .assistant else { return }
        if message.metadata?["iexa_local_alpine_final_summary"] != nil {
            return
        }
        guard !localAlpineAgentExecutedMessageIds.contains(messageId) else { return }
        guard !Self.containsInternalPromptLeak(content) else { return }
        if localAlpineStepsSinceLastUser() >= localAlpineAgentMaxSteps {
            localAlpineAgentExecutedMessageIds.insert(messageId)
            appendLocalAlpineAgentLimitMessage(parentId: messageId)
            return
        }
        let latestUserText = conversation?.messages.last(where: {
            $0.role == .user && !Self.isLocalAlpineAgentResult($0)
        })?.content
        let effectiveModelId = selectedModelId ?? message.model ?? conversation?.model ?? ""
        if let latestUserText,
           shouldKeepMediaGenerationRequestOffLocalAlpine(latestUserText, modelId: effectiveModelId) {
            return
        }
        let executableContent: String?
        if Self.contentContainsLocalAlpineInstruction(content) {
            executableContent = Self.normalizedLocalAlpineExecutableContent(from: content)
        } else {
            return
        }
        guard let executableContent else {
            return
        }

        let executableFingerprint = Self.localAlpineExecutableFingerprint(from: executableContent)
        if !executableFingerprint.isEmpty,
           localAlpineExecutedExecutableFingerprints.contains(executableFingerprint) {
            localAlpineAgentExecutedMessageIds.insert(messageId)
            localAlpineAgentStopRequested = true
            return
        }
        if !executableFingerprint.isEmpty {
            localAlpineExecutedExecutableFingerprints.insert(executableFingerprint)
        }

        localAlpineAgentExecutedMessageIds.insert(messageId)
        localAlpineAgentTask = Task { [weak self] in
            let hasExecutableBlocks = await LocalAlpineAgentService.shared.hasExecutableBlocks(in: executableContent)
            guard hasExecutableBlocks else {
                self?.localAlpineAgentExecutedMessageIds.remove(messageId)
                if !executableFingerprint.isEmpty {
                    self?.localAlpineExecutedExecutableFingerprints.remove(executableFingerprint)
                }
                return
            }
            await self?.executeLocalAlpineAgent(messageId: messageId, content: executableContent)
        }
    }

    private func scheduleLocalNativeToolIfNeeded(messageId: String, content: String, error: ChatMessageError?) {
        guard error == nil else { return }
        guard LocalNativeToolService.containsNativeToolBlock(content) else { return }
        guard conversation?.messages.first(where: { $0.id == messageId }).map(Self.isLocalNativeToolResult) != true else {
            return
        }
        guard !localNativeToolExecutedMessageIds.contains(messageId) else { return }
        localNativeToolExecutedMessageIds.insert(messageId)
        Task { [weak self] in
            await self?.executeLocalNativeTool(messageId: messageId, content: content)
        }
    }

    private func executeLocalNativeTool(messageId: String, content: String) async {
        let officeKind = LocalNativeToolService.officeActionKind(in: content)
        let browserAction = LocalNativeToolService.browserActionName(in: content)
        if let officeKind {
            markLocalOfficeGenerationStarted(messageId: messageId, kind: officeKind)
        } else if let browserAction {
            markLocalBrowserToolStarted(messageId: messageId, actionName: browserAction)
        }
        let result = await LocalNativeToolService.shared.executeBlocks(
            in: content,
            officeProgress: { [weak self] phase in
                guard let self = self, let officeKind = officeKind else { return }
                await self.updateLocalOfficeGenerationProgress(
                    messageId: messageId,
                    kind: officeKind,
                    phase: phase
                )
            }
        )
        guard result.didExecute else {
            if let officeKind {
                await finishLocalOfficeGeneration(
                    messageId: messageId,
                    document: LocalNativeOfficeDocument(
                        kind: officeKind,
                        ok: false,
                        title: officeKind.displayName,
                        fileName: "",
                        summary: "",
                        previewText: "",
                        previewCount: 0,
                        error: "模型返回的 Office 生成指令无法解析。"
                    ),
                    files: []
                )
            } else if let browserAction {
                finishLocalBrowserTool(
                    messageId: messageId,
                    document: LocalNativeBrowserDocument(
                        ok: false,
                        action: browserAction,
                        title: "本地浏览器",
                        url: nil,
                        query: nil,
                        summary: "模型返回的浏览器工具指令无法解析。",
                        items: [],
                        error: "模型返回的浏览器工具指令无法解析。"
                    )
                )
            }
            return
        }
        guard conversation?.messages.contains(where: { $0.id == messageId }) == true else { return }

        if let officeDocument = result.officeDocument {
            await finishLocalOfficeGeneration(
                messageId: messageId,
                document: officeDocument,
                files: result.files
            )
            return
        }
        if let officeKind {
            await finishLocalOfficeGeneration(
                messageId: messageId,
                document: LocalNativeOfficeDocument(
                    kind: officeKind,
                    ok: false,
                    title: officeKind.displayName,
                    fileName: "",
                    summary: "",
                    previewText: "",
                    previewCount: 0,
                    error: "本地 Office 工具没有返回文件结果。"
                ),
                files: []
            )
            return
        }
        var inheritedStatusHistory: [ChatStatusUpdate] = []
        if let browserDocument = result.browserDocument {
            finishLocalBrowserTool(
                messageId: messageId,
                document: browserDocument
            )
            inheritedStatusHistory = localNativeContinuationStatusHistory(from: messageId)
        } else if browserAction != nil {
            finishLocalBrowserTool(
                messageId: messageId,
                document: LocalNativeBrowserDocument(
                    ok: false,
                    action: browserAction ?? "browser",
                    title: "本地浏览器",
                    url: nil,
                    query: nil,
                    summary: "本地浏览器工具没有返回可用结果。",
                    items: [],
                    error: "本地浏览器工具没有返回可用结果。"
                )
            )
            inheritedStatusHistory = localNativeContinuationStatusHistory(from: messageId)
        }
        if !inheritedStatusHistory.isEmpty {
            markLocalNativeToolParentHidden(messageId: messageId)
        }

        let resultMessage = ChatMessage(
            role: .system,
            content: "本地 iOS 工具执行结果\n\n\(result.summary)",
            timestamp: .now,
            model: "Local Native",
            isStreaming: false,
            metadata: ["iexa_local_native_result": "true"]
        )
        let resultNode = HistoryNode(
            id: resultMessage.id,
            parentId: messageId,
            childrenIds: [],
            role: .system,
            content: resultMessage.content,
            timestamp: resultMessage.timestamp,
            model: "Local Native",
            done: true,
            metadata: resultMessage.metadata
        )

        conversation?.messages.append(resultMessage)
        conversation?.history.addNode(resultNode)
        conversation?.history.appendChildId(resultMessage.id, to: messageId)
        conversation?.history.currentId = resultMessage.id
        if !result.files.isEmpty {
            localNativeGeneratedFilesByResultMessageId[resultMessage.id] = result.files
        }
        if !inheritedStatusHistory.isEmpty {
            localNativeInheritedStatusByResultMessageId[resultMessage.id] = inheritedStatusHistory
        }

        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        await startLocalNativeContinuation(parentId: resultMessage.id)
    }

    private func markLocalBrowserToolStarted(messageId: String, actionName: String) {
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        activeTaskId = nil
        let title = localBrowserToolRunningTitle(for: actionName)
        updateLocalBrowserToolMessage(
            messageId: messageId,
            content: title,
            isStreaming: true,
            status: ChatStatusUpdate(
                action: "browser_web_search",
                description: title,
                done: false,
                occurredAt: .now
            )
        )
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func finishLocalBrowserTool(
        messageId: String,
        document: LocalNativeBrowserDocument
    ) {
        var urls = document.items.compactMap(\.link)
        if let url = document.url, !urls.contains(url) {
            urls.insert(url, at: 0)
        }
        let status = ChatStatusUpdate(
            action: "browser_web_search",
            description: document.ok ? document.summary : (document.error ?? document.summary),
            done: true,
            urls: urls,
            occurredAt: .now,
            items: document.items,
            count: max(document.items.count, urls.count),
            query: document.query,
            queries: document.query.map { [$0] } ?? []
        )
        updateLocalBrowserToolMessage(
            messageId: messageId,
            content: document.ok ? "本地浏览器已完成：\(document.title)" : "本地浏览器失败：\(document.error ?? document.summary)",
            isStreaming: false,
            status: status
        )
    }

    private func updateLocalBrowserToolMessage(
        messageId: String,
        content: String,
        isStreaming: Bool,
        status: ChatStatusUpdate
    ) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var metadata = conversation?.messages[index].metadata ?? [:]
        metadata["iexa_local_browser_tool"] = "true"
        metadata["iexa_local_native_tool_parent"] = "true"

        conversation?.messages[index].content = content
        conversation?.messages[index].isStreaming = isStreaming
        conversation?.messages[index].statusHistory = [status]
        conversation?.messages[index].metadata = metadata
        conversation?.history.updateNode(id: messageId) { node in
            node.content = content
            node.done = !isStreaming
            node.statusHistory = [status]
            node.metadata = metadata
        }
        conversation?.history.currentId = messageId
    }

    private func localNativeContinuationStatusHistory(from messageId: String) -> [ChatStatusUpdate] {
        guard let statusHistory = conversation?.messages.first(where: { $0.id == messageId })?.statusHistory else {
            return []
        }
        return statusHistory.filter { status in
            guard status.hidden != true,
                  let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !action.isEmpty else {
                return false
            }
            return Self.isLocalNativeSearchStatusAction(action)
        }
    }

    private func markLocalNativeToolParentHidden(messageId: String) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var metadata = conversation?.messages[index].metadata ?? [:]
        metadata["iexa_local_native_hidden_tool_parent"] = "true"
        conversation?.messages[index].metadata = metadata
        conversation?.history.updateNode(id: messageId) { node in
            node.metadata = metadata
        }
    }

    private static func isLocalNativeSearchStatusAction(_ action: String) -> Bool {
        action == "browser_web_search"
            || action == "web_search"
            || action == "websearch"
            || action == "web search"
            || action == "local_alpine_web_search"
            || action == "get_readable"
            || action.contains("readable")
    }

    private func localBrowserToolRunningTitle(for actionName: String) -> String {
        let action = actionName.lowercased()
        if action.contains("search") || action.contains("搜索") || action.contains("web.search") {
            return "本地浏览器正在搜索网页..."
        }
        if action.contains("screenshot") {
            return "本地浏览器正在生成网页缩略图..."
        }
        if action.contains("fetch") {
            return "本地浏览器正在下载网页资源..."
        }
        return "本地浏览器正在读取网页..."
    }

    private func markLocalOfficeGenerationStarted(messageId: String, kind: LocalNativeOfficeKind) {
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        activeTaskId = nil
        let statuses = localOfficeStatusHistory(
            kind: kind,
            visibleThrough: .parseDemand,
            completedThrough: nil
        )
        updateLocalOfficeGenerationMessage(
            messageId: messageId,
            content: kind.creatingTitle,
            isStreaming: true,
            statusHistory: statuses,
            files: []
        )
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func updateLocalOfficeGenerationProgress(
        messageId: String,
        kind: LocalNativeOfficeKind,
        phase: LocalOfficeProgressPhase
    ) async {
        guard conversation?.messages.contains(where: { $0.id == messageId }) == true else { return }
        let visibleThrough: LocalOfficeGenerationStep
        let completedThrough: LocalOfficeGenerationStep
        switch phase {
        case .parsedDemand:
            visibleThrough = .generateFile
            completedThrough = .parseDemand
        case .generatedFile:
            visibleThrough = .generatePreview
            completedThrough = .generateFile
        case .generatedPreview:
            visibleThrough = .attachToChat
            completedThrough = .generatePreview
        }
        updateLocalOfficeGenerationMessage(
            messageId: messageId,
            content: kind.creatingTitle,
            isStreaming: true,
            statusHistory: localOfficeStatusHistory(
                kind: kind,
                visibleThrough: visibleThrough,
                completedThrough: completedThrough
            ),
            files: []
        )
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func finishLocalOfficeGeneration(
        messageId: String,
        document: LocalNativeOfficeDocument,
        files: [ChatMessageFile]
    ) async {
        let content = localOfficeFinalContent(for: document, fileCount: files.count)
        updateLocalOfficeGenerationMessage(
            messageId: messageId,
            content: content,
            isStreaming: false,
            statusHistory: localOfficeStatusHistory(
                kind: document.kind,
                visibleThrough: .attachToChat,
                completedThrough: document.ok ? .attachToChat : nil,
                failed: !document.ok
            ),
            files: files
        )
        hasFinishedStreaming = true
        isStreaming = false
        isExternallyStreaming = false
        selfInitiatedStream = false
        activeTaskId = nil
        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        await sendCompletionNotificationIfNeeded(content: content)
    }

    private enum LocalOfficeGenerationStep: Int, CaseIterable {
        case parseDemand
        case generateFile
        case generatePreview
        case attachToChat

        func description(kind: LocalNativeOfficeKind, failed: Bool) -> String {
            switch self {
            case .parseDemand:
                return "解析生成需求"
            case .generateFile:
                return "生成\(kind.displayName)文件"
            case .generatePreview:
                return failed ? "生成失败" : "生成预览图"
            case .attachToChat:
                return failed ? "请调整需求后重试" : "附加到聊天"
            }
        }
    }

    private func localOfficeStatusHistory(
        kind: LocalNativeOfficeKind,
        visibleThrough: LocalOfficeGenerationStep,
        completedThrough: LocalOfficeGenerationStep?,
        failed: Bool = false
    ) -> [ChatStatusUpdate] {
        return LocalOfficeGenerationStep.allCases
            .filter { $0.rawValue <= visibleThrough.rawValue }
            .map { step in
                ChatStatusUpdate(
                    action: "local_office_agent",
                    description: step.description(kind: kind, failed: failed),
                    done: completedThrough.map { step.rawValue <= $0.rawValue } ?? false,
                    occurredAt: .now
                )
            }
    }

    private func localOfficeFinalContent(
        for document: LocalNativeOfficeDocument,
        fileCount: Int
    ) -> String {
        guard document.ok else {
            let detail = document.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason: String
            if let detail, !detail.isEmpty {
                reason = "：\(detail)"
            } else {
                reason = "。"
            }
            return "本地\(document.kind.displayName)生成失败\(reason)"
        }

        let fileName = document.fileName.isEmpty
            ? "\(document.title).\(localOfficeFileExtension(for: document.kind))"
            : document.fileName
        let titleLine = "已生成本地\(document.kind.displayName)：\(fileName)"
        let attachmentLine = fileCount > 0 ? "文件卡片已附在下方，可直接打开或预览。" : "文件已保存到本地工作区。"
        return [titleLine, attachmentLine]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private func localOfficeFileExtension(for kind: LocalNativeOfficeKind) -> String {
        switch kind {
        case .excel:
            return "xlsx"
        case .powerPoint:
            return "pptx"
        case .word:
            return "docx"
        case .pdf:
            return "pdf"
        }
    }

    private func updateLocalOfficeGenerationMessage(
        messageId: String,
        content: String,
        isStreaming: Bool,
        statusHistory: [ChatStatusUpdate],
        files: [ChatMessageFile]
    ) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var metadata = conversation?.messages[index].metadata ?? [:]
        metadata["iexa_local_office_document"] = "true"
        metadata["iexa_local_native_tool_parent"] = "true"

        conversation?.messages[index].content = content
        conversation?.messages[index].isStreaming = isStreaming
        conversation?.messages[index].statusHistory = statusHistory
        conversation?.messages[index].metadata = metadata
        if !files.isEmpty {
            conversation?.messages[index].files = files
        }
        conversation?.history.updateNode(id: messageId) { node in
            node.content = content
            node.done = !isStreaming
            node.statusHistory = statusHistory
            node.metadata = metadata
            if !files.isEmpty {
                node.files = files
            }
        }
        conversation?.history.currentId = messageId
    }

    private func startLocalNativeContinuation(parentId: String) async {
        guard let manager else { return }
        guard let conversation, conversation.messages.contains(where: { $0.id == parentId }) else { return }
        guard let modelId = selectedModelId ?? conversation.model else { return }

        let assistantMessageId = UUID().uuidString
        let inheritedStatusHistory = localNativeInheritedStatusByResultMessageId[parentId] ?? []
        let thinkingStatus = ChatStatusUpdate(
            action: "local_native_tool",
            description: "本地 iOS 工具已返回，正在整理回答...",
            done: false,
            hidden: !inheritedStatusHistory.isEmpty
        )
        let initialStatusHistory = inheritedStatusHistory + [thinkingStatus]
        let assistantMessage = ChatMessage(
            id: assistantMessageId,
            role: .assistant,
            content: "",
            timestamp: .now,
            model: modelId,
            isStreaming: true,
            statusHistory: initialStatusHistory,
            metadata: ["iexa_local_native_continuation": "true"]
        )
        let assistantNode = HistoryNode(
            id: assistantMessageId,
            parentId: parentId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: assistantMessage.timestamp,
            model: modelId,
            done: false,
            statusHistory: initialStatusHistory,
            metadata: assistantMessage.metadata
        )

        self.conversation?.messages.append(assistantMessage)
        self.conversation?.history.addNode(assistantNode)
        self.conversation?.history.appendChildId(assistantMessageId, to: parentId)
        self.conversation?.history.currentId = assistantMessageId
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

        var apiMessages = await buildAPIMessagesAsync(includeLocalAlpineExecutionContext: false)
        Self.appendLocalNativeResultInstruction(to: &apiMessages)

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        activeTaskId = nil
        sessionId = UUID().uuidString
        streamingStore.beginStreaming(
            messageId: assistantMessageId,
            modelId: modelId,
            initialStatusHistory: initialStatusHistory
        )
        beginStreamingBackgroundTaskIfNeeded()

        let effectiveChatId = conversationId ?? self.conversation?.id
        let socket = socketService
        var socketConnected = socket?.isConnected ?? false
        if !isOpenAICompatibleProvider, let socket, !socketConnected {
            socketConnected = await socket.ensureConnected(timeout: 8.0)
        }
        let socketSessionId = socket?.sid ?? sessionId
        let usePollingFallback = !isOpenAICompatibleProvider && !socketConnected

        if !isOpenAICompatibleProvider {
            await syncToServerViaTree()
            if socketConnected, let socket {
                registerSocketHandlers(
                    socket: socket,
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId
                )
            }
        }

        streamingTask = Task { [weak self] in
            guard let self else { return }
            let acc = ContentAccumulator()
            var exactUsage: [String: Any]?

            do {
                var request = ChatCompletionRequest(
                    model: modelId,
                    messages: apiMessages,
                    stream: true,
                    chatId: effectiveChatId,
                    sessionId: socketSessionId,
                    messageId: assistantMessageId,
                    parentId: parentId
                )
                await self.populateCommonRequestFields(&request)

                if self.isOpenAICompatibleProvider {
                    let stream = try await manager.sendPreferredOpenAIStreaming(
                        request: request
                    )
                    for try await event in stream {
                        if Task.isCancelled { break }
                        if let usage = event.usage, !usage.isEmpty {
                            exactUsage = usage
                        }
                        self.applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                        if event.isFinished { break }
                    }
                    if Task.isCancelled { return }
                    acc.markReasoningDone()
                    await self.finishLocalNativeContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: acc.content,
                        usage: exactUsage
                    )
                    return
                }

                if request.isPipeModel {
                    let stream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                    for try await event in stream {
                        if Task.isCancelled { break }
                        if let usage = event.usage, !usage.isEmpty {
                            exactUsage = usage
                        }
                        self.applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                        if event.isFinished { break }
                    }
                    if Task.isCancelled { return }
                    acc.markReasoningDone()
                    await self.finishLocalNativeContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: acc.content,
                        usage: exactUsage
                    )
                    return
                }

                let json = try await manager.sendMessageHTTP(request: request)
                if let err = json["error"] as? String, !err.isEmpty {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: Self.cleanedProviderErrorMessage(err) ?? err)
                    )
                    self.cleanupStreaming()
                    return
                }
                if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: detail)
                    )
                    self.cleanupStreaming()
                    return
                }
                if let taskId = json["task_id"] as? String {
                    self.activeTaskId = taskId
                }
                if usePollingFallback, let chatId = effectiveChatId {
                    await self.pollLocalNativeContinuation(
                        chatId: chatId,
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        socketSessionId: socketSessionId
                    )
                } else if usePollingFallback {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: "当前会话没有可轮询的 chatId，无法继续整理本地 iOS 工具结果。")
                    )
                    self.cleanupStreaming()
                } else {
                    self.logger.info("Local native continuation HTTP POST done - waiting for socket events")
                }
            } catch {
                if !Task.isCancelled {
                    let message = Self.localizedGenerationError(error)
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: acc.content,
                        isStreaming: false,
                        error: ChatMessageError(content: message)
                    )
                    self.cleanupStreaming()
                    await self.persistLocalConversationIfNeeded()
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
        }
    }

    private func finishLocalNativeContinuation(
        assistantMessageId: String,
        modelId: String,
        content: String,
        usage: [String: Any]? = nil
    ) async {
        let finalContent = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "本地 iOS 工具已执行完成。"
            : content
        let existingStatusHistory = conversation?.messages.first(where: { $0.id == assistantMessageId })?.statusHistory ?? []
        let hasInheritedSearchStatus = existingStatusHistory.contains { status in
            guard status.hidden != true,
                  let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !action.isEmpty else {
                return false
            }
            return Self.isLocalNativeSearchStatusAction(action)
        }
        let finalStatusHistory: [ChatStatusUpdate]? = hasInheritedSearchStatus
            ? nil
            : [
                ChatStatusUpdate(
                    action: "local_native_tool",
                    description: "已根据本地 iOS 工具结果完成回答",
                    done: true,
                    occurredAt: .now
                )
            ]
        updateAssistantMessage(
            id: assistantMessageId,
            content: finalContent,
            isStreaming: false,
            statusHistory: finalStatusHistory
        )
        attachLocalNativeGeneratedFiles(to: assistantMessageId)
        normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
        applyUsage(usage, toMessageId: assistantMessageId)
        if let parentId = conversation?.messages.first(where: { $0.id == assistantMessageId })?.parentId {
            localNativeInheritedStatusByResultMessageId[parentId] = nil
        }
        let lastUser = conversation?.messages.last(where: {
            $0.role == .user && $0.metadata?["iexa_local_native_result"] != "true"
        })
        recordTokenUsageForCompletedTurn(
            assistantMessageId: assistantMessageId,
            userText: lastUser?.content ?? "",
            assistantText: finalContent,
            userAttachments: [],
            usage: usage
        )
        hasFinishedStreaming = true
        isStreaming = false
        isExternallyStreaming = false
        selfInitiatedStream = false
        activeTaskId = nil
        lastTaskExtractionLength = 0
        await sendCompletionNotificationIfNeeded(content: finalContent)
        endBackgroundTask()
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDelayTask?.cancel()
        recoveryDelayTask = nil
        emptyPollCount = 0
        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func attachLocalNativeGeneratedFiles(to assistantMessageId: String) {
        guard let parentId = conversation?.messages.first(where: { $0.id == assistantMessageId })?.parentId,
              let files = localNativeGeneratedFilesByResultMessageId[parentId],
              !files.isEmpty else {
            return
        }
        guard let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) else {
            return
        }
        var merged = conversation?.messages[index].files ?? []
        for file in files where !merged.contains(where: { $0.url == file.url && $0.name == file.name }) {
            merged.append(file)
        }
        conversation?.messages[index].files = merged
        conversation?.history.updateNode(id: assistantMessageId) { node in
            node.files = merged
        }
        localNativeGeneratedFilesByResultMessageId[parentId] = nil
    }

    private func pollLocalNativeContinuation(
        chatId: String,
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String
    ) async {
        guard let manager else {
            cleanupStreaming()
            return
        }
        var lastContentLength = 0
        var staleCount = 0
        for _ in 0..<40 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }

            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                guard let serverAssistant = refreshed.messages.first(where: { $0.id == assistantMessageId }) else {
                    continue
                }
                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !serverContent.isEmpty else { continue }
                let localContent = conversation?.messages
                    .first(where: { $0.id == assistantMessageId })?.content ?? ""
                let protectedContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                    local: localContent,
                    incoming: serverAssistant.content
                ) ? localContent : serverAssistant.content
                updateAssistantMessage(id: assistantMessageId, content: protectedContent, isStreaming: true)
                if serverContent.count > lastContentLength {
                    lastContentLength = serverContent.count
                    staleCount = 0
                } else {
                    staleCount += 1
                }
                if staleCount >= 3 {
                    await finishLocalNativeContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: protectedContent,
                        usage: nil
                    )
                    await manager.sendChatCompleted(
                        chatId: chatId,
                        messageId: assistantMessageId,
                        model: modelId,
                        sessionId: socketSessionId,
                        messages: buildSimpleAPIMessages()
                    )
                    return
                }
            } catch {
                logger.warning("Local native continuation polling failed: \(error.localizedDescription)")
            }
        }

        updateAssistantMessage(
            id: assistantMessageId,
            content: conversation?.messages.first(where: { $0.id == assistantMessageId })?.content ?? "",
            isStreaming: false
        )
        cleanupStreaming()
    }

    private static func appendSystemInstruction(
        _ instruction: String,
        marker: String,
        to messages: inout [[String: Any]]
    ) {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else { return }

        if !messages.isEmpty, messages[0]["role"] as? String == "system" {
            var system = messages[0]
            let existing = system["content"] as? String ?? ""
            if existing.contains(marker) { return }
            system["content"] = [existing, trimmedInstruction]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            messages[0] = system
        } else {
            messages.insert(["role": "system", "content": trimmedInstruction], at: 0)
        }
    }

    private static func appendLocalNativeResultInstruction(to messages: inout [[String: Any]]) {
        let instruction = """
        [Local native tool result]
        The latest Local Native message above is a real on-device iOS tool result for device info, clipboard, local notification, location, weather, calendar, local browser/web reading, or local Office document generation. Do not emit another `iexa_native` block in this turn.
        Reply to the user in normal language only. If the local browser tool succeeded, answer from the returned page/search content and cite page titles/URLs plainly. If an Office document was generated, tell the user the file and previews are attached in the chat. If it failed, explain the permission/state problem and the next user action.
        [/Local native tool result]
        """
        appendSystemInstruction(instruction, marker: "[Local native tool result]", to: &messages)
    }

    private static func shouldExposeLocalNativeTools(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "设备状态", "设备信息", "电量", "电池", "系统信息", "手机信息",
            "剪贴板", "复制到剪贴板", "读取剪贴板", "粘贴板",
            "通知", "提醒我", "发个通知", "本地通知",
            "定位", "位置", "我在哪", "附近", "坐标", "经纬度",
            "天气", "气温", "温度", "下雨", "降雨", "风速", "湿度", "冷不冷", "热不热",
            "日历", "日程", "行程", "事件", "提醒", "会议", "预约", "安排",
            "excel", "xlsx", "表格文件", "电子表格", "报表文件", "生成报表", "做报表",
            "ppt", "pptx", "powerpoint", "slides", "幻灯片", "演示文稿", "汇报文件", "课件",
            "pdf", "pdf文件", "pdf文档", "生成pdf", "做成pdf", "转成pdf",
            "word", "docx", "文档", "word文档", "写文档", "生成文档", "产品方案",
            "方案文件", "做方案", "生成方案", "改方案", "重做方案", "换方案",
            "修改方案", "优化方案", "完善方案", "重新生成方案",
            "device status", "device info", "battery", "clipboard", "pasteboard",
            "copy to clipboard", "read clipboard", "notification", "notify me",
            "calendar", "event", "schedule", "reminder", "location", "where am i",
            "weather", "temperature", "rain", "wind", "humidity",
            "spreadsheet", "presentation", "slide deck", "make a deck", "word document", "docx", "document", "pdf"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func shouldExposeLocalBrowserTools(_ text: String) -> Bool {
        let lower = text.lowercased()
        let compact = lower.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let markers = [
            "联网", "搜索", "搜一下", "查一下", "查询", "网页", "网站", "链接",
            "网址", "打开网页", "阅读网页", "读取网页", "浏览器", "来源",
            "最新", "今天", "今日", "现在", "实时", "新闻", "资料",
            "web", "search", "browse", "browser", "website", "webpage", "url",
            "link", "latest", "current", "today", "news", "source"
        ]
        return markers.contains { lower.contains($0) || compact.contains($0) }
    }

    private func localAlpineStepsSinceLastUser() -> Int {
        guard let messages = conversation?.messages,
              let lastUserIndex = messages.lastIndex(where: {
                  $0.role == .user && !Self.isLocalAlpineAgentResult($0)
              }) else { return 0 }
        let startIndex = messages.index(after: lastUserIndex)
        guard startIndex < messages.endIndex else { return 0 }
        return messages[startIndex...].filter {
            Self.isLocalAlpineAgentResult($0) && !Self.isLocalAlpineProtocolCorrectionMessage($0)
        }.count
    }

    private func appendLocalAlpineAgentLimitMessage(parentId: String) {
        let content = """
        Local Alpine 执行结果

        已达到本轮 Agent 自动执行上限（\(localAlpineAgentMaxSteps) 步）。我先停在这里，避免循环执行拖慢 App。
        """
        let message = ChatMessage(
            role: .assistant,
            content: content,
            timestamp: .now,
            model: "Local Alpine",
            isStreaming: false,
            metadata: ["iexa_local_alpine_result": "true"]
        )
        let node = HistoryNode(
            id: message.id,
            parentId: parentId,
            childrenIds: [],
            role: .assistant,
            content: content,
            timestamp: message.timestamp,
            model: "Local Alpine",
            done: true
        )
        conversation?.messages.append(message)
        conversation?.history.addNode(node)
        conversation?.history.appendChildId(message.id, to: parentId)
        conversation?.history.currentId = message.id
        localAlpineAgentStopRequested = true
        Task { await persistLocalConversationIfNeeded() }
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func repeatedLocalAlpineFailure(for content: String) -> LocalAlpineAgentCommandFailure? {
        let commands = Self.localAlpineCommands(in: content)
        guard !commands.isEmpty else { return nil }

        func recordBlockedAttempt(for key: String) {
            let count = (localAlpineBlockedRepeatCommands[key] ?? 0) + 1
            localAlpineBlockedRepeatCommands[key] = count
            if count >= 3 {
                localAlpineAgentStopRequested = true
            }
        }

        if commands.contains(where: {
            $0.hasWriteFiles || Self.localAlpineCommandWritesCodeWithHeredoc($0.command)
        }) {
            return nil
        }

        guard let command = commands.first(where: {
            localAlpineFailedCommands[Self.localAlpineCommandKey(command: $0.command, cwd: $0.cwd)] != nil
        }) else { return nil }
        let key = Self.localAlpineCommandKey(command: command.command, cwd: command.cwd)
        guard let failure = localAlpineFailedCommands[key] else { return nil }
        recordBlockedAttempt(for: key)
        return failure
    }

    private func repeatedCompletedLocalAlpineCommand(for content: String) -> LocalAlpineAgentCompletedCommand? {
        let commands = Self.localAlpineCommands(in: content)
        guard !commands.isEmpty else { return nil }
        if commands.contains(where: {
            $0.hasWriteFiles || Self.localAlpineCommandWritesCodeWithHeredoc($0.command)
        }) {
            return nil
        }
        guard let command = commands.first(where: {
            localAlpineCompletedCommands[Self.localAlpineCommandKey(command: $0.command, cwd: $0.cwd)] != nil
        }) else { return nil }
        return localAlpineCompletedCommands[
            Self.localAlpineCommandKey(command: command.command, cwd: command.cwd)
        ]
    }

    private func appendLocalAlpinePythonInspectionGuardIfNeeded(
        attemptedMessageId _: String,
        content _: String
    ) -> String? {
        return nil
    }

    private func latestLocalAlpinePythonSyntaxIssue() -> (path: String?, targetPath: String?, cwd: String?)? {
        guard let messages = conversation?.messages else { return nil }
        for message in messages.reversed() where Self.isLocalAlpineAgentResult(message) {
            let text = message.content + "\n" + (message.metadata?["iexa_local_alpine_raw_result"] ?? "")
            if Self.localAlpineOutputHasPythonSyntaxIssue(text) {
                let command = message.metadata?["iexa_local_alpine_display_command"] ?? ""
                let cwd = message.metadata?["iexa_local_alpine_cwd"] ?? "/mnt/iexa"
                let targetPath = Self.localAlpinePythonTargetPath(output: text, command: command, cwd: cwd)
                return (
                    Self.localAlpinePythonFilePath(command: command, output: text, cwd: cwd),
                    targetPath,
                    cwd
                )
            }
            if text.localizedCaseInsensitiveContains("Local Alpine 执行结果"),
               text.contains("退出码：`0`") {
                return nil
            }
        }
        return nil
    }

    private func recordLocalAlpineFailures(from result: LocalAlpineAgentResult) {
        for commandResult in result.commandResults where commandResult.failed {
            let key = Self.localAlpineCommandKey(command: commandResult.command, cwd: commandResult.cwd)
            localAlpineFailedCommands[key] = LocalAlpineAgentCommandFailure(
                command: commandResult.command,
                cwd: commandResult.cwd,
                exitCode: commandResult.exitCode,
                outputPreview: commandResult.outputPreview
            )
            let signature = Self.localAlpineFailureSignature(commandResult)
            localAlpineFailureSignatures[signature] = (localAlpineFailureSignatures[signature] ?? 0) + 1
        }
    }

    private func recordLocalAlpineCompletedCommands(from result: LocalAlpineAgentResult) {
        if result.editedFileCount > 0 || !result.writtenFiles.isEmpty {
            localAlpineCompletedCommands.removeAll()
            localAlpineExecutedExecutableFingerprints.removeAll()
            return
        }
        for commandResult in result.commandResults where !commandResult.failed {
            if Self.localAlpineCommandMutatesState(commandResult.command) {
                localAlpineCompletedCommands.removeAll()
                localAlpineExecutedExecutableFingerprints.removeAll()
                continue
            }
            let key = Self.localAlpineCommandKey(command: commandResult.command, cwd: commandResult.cwd)
            localAlpineCompletedCommands[key] = LocalAlpineAgentCompletedCommand(
                command: commandResult.command,
                cwd: commandResult.cwd,
                exitCode: commandResult.exitCode,
                outputPreview: commandResult.outputPreview
            )
        }
    }

    private func repeatedLocalAlpineErrorShouldStop(after result: LocalAlpineAgentResult, parentId: String) -> Bool {
        let loweredSummary = result.summary.lowercased()
        if loweredSummary.contains("iexa_auto_repair_verified_success") {
            return false
        }
        guard let repeated = result.commandResults
            .filter({ $0.failed })
            .first(where: { (localAlpineFailureSignatures[Self.localAlpineFailureSignature($0)] ?? 0) >= 2 }) else {
            return false
        }
        appendLocalAlpineRepeatedErrorStopMessage(parentId: parentId, result: repeated)
        return true
    }

    private func repeatedLocalAlpineNoProgressShouldStop(after result: LocalAlpineAgentResult, parentId: String) -> Bool {
        guard result.interactiveRequest == nil, result.hadFailure == false else { return false }
        if result.editedFileCount > 0 || !result.writtenFiles.isEmpty {
            localAlpineNoProgressSignatures.removeAll()
            return false
        }

        let executableCommands = result.commandResults
            .map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "write_files" }
        let combinedCommands = executableCommands.joined(separator: "\n")
        guard !combinedCommands.isEmpty else { return false }

        let isLowProgressStep = Self.localAlpineCommandsAreInspectionOnly(combinedCommands)
            || Self.localAlpineActionWasOnlyInstallOrWrite(combinedCommands)
        guard isLowProgressStep else {
            localAlpineNoProgressSignatures.removeAll()
            return false
        }

        let signature = Self.localAlpineNoProgressSignature(for: result)
        let count = (localAlpineNoProgressSignatures[signature] ?? 0) + 1
        localAlpineNoProgressSignatures[signature] = count
        guard count >= localAlpineNoProgressRepeatLimit else { return false }

        appendLocalAlpineNoProgressStopMessage(
            parentId: parentId,
            reason: "连续 \(count) 次得到相同的检查/安装观察结果，但没有写入、编辑或新的验证进展。"
        )
        return true
    }

    private static func localAlpineCommandsAreInspectionOnly(_ combinedCommands: String) -> Bool {
        let commands = combinedCommands
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !commands.isEmpty else { return false }
        let inspectionPatterns = [
            #"^(?:pwd|ls\b|find\b|grep\b|rg\b|cat\b|sed\s+-n\b|head\b|tail\b|wc\b|stat\b|file\b|tree\b)"#,
            #"^(?:command\s+-v|which\b|apk\s+info\b|apk\s+search\b)"#,
            #"^(?:python3?|pip3?|node|npm|lua(?:5\.\d)?|gcc|g\+\+|clang|make)\s+(?:--version|-v|version|list|show|freeze)\b"#
        ]
        return commands.allSatisfy { command in
            inspectionPatterns.contains {
                command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
    }

    private static func localAlpineNoProgressSignature(for result: LocalAlpineAgentResult) -> String {
        let commands = result.commandResults.map { commandResult in
            let command = commandResult.command
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let cwd = commandResult.cwd
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let output = commandResult.outputPreview
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(cwd)|\(command)|\(commandResult.exitCode.map(String.init) ?? "nil")|\(output.hashValue)"
        }
        let tools = result.toolCalls.map { call in
            "\(call.name)|\(call.phase.rawValue)|\(call.exitCode.map(String.init) ?? "nil")|\(call.filePaths.joined(separator: ","))"
        }
        return (commands + tools).joined(separator: "\n")
    }

    private func appendLocalAlpineRepeatedCommandMessage(parentId: String, failure: LocalAlpineAgentCommandFailure) -> String {
        let repeatCount = localAlpineBlockedRepeatCommands[
            Self.localAlpineCommandKey(command: failure.command, cwd: failure.cwd)
        ] ?? 1
        let shouldStop = repeatCount >= 3
        let pythonSyntaxIssue = Self.localAlpineOutputHasPythonSyntaxIssue(failure.outputPreview)
        let pythonFile = Self.localAlpinePythonFilePath(
            command: failure.command,
            output: failure.outputPreview,
            cwd: failure.cwd
        )
        let pythonRepairInstruction: String
        if pythonSyntaxIssue {
            pythonRepairInstruction = """

        Code syntax/indentation guard
        已检测到代码缩进/语法错误。下一步不要只重复同一个失败命令。
        必须先定位并读取用户项目文件，然后修复同一个路径：
        1. 用 JSON `read_file` 读取目标文件（或执行带行号读取命令：`\(Self.localAlpineInspectCommand(forPythonFile: pythonFile))`）。
        2. 优先用 JSON `edit_file`/`patch_file` 修改原文件；只有大段重写时才用 `write_files` 写回同一路径。
        3. 修改后直接运行脚本或一个有界验证命令。Python 仍需要额外的 AST/编译检查。
        """
        } else if failure.outputPreview.lowercased().contains("unsafe python file write blocked")
            || failure.outputPreview.lowercased().contains("unsafe code file write blocked") {
            pythonRepairInstruction = """

        Code file write retry
        之前的写入命令被保护层拦过。下一步应改用结构化 `edit_file`/`patch_file` 修复原文件，或用 `write_files` 写回同一路径，并运行实际验证命令。
        """
        } else if Self.localAlpineOutputHasBusyBoxCompatibilityIssue(failure.outputPreview) {
            pythonRepairInstruction = """

        BusyBox/ash compatibility retry
        之前命令使用了当前 Local Alpine 不兼容的 GNU/bash/Python 运行时写法。下一步不要重复原命令，优先改用 `list_dir`/`glob`/`grep`/`verify` 结构化工具；必须写 shell 时只用 POSIX sh/ash 和 BusyBox 兼容参数。
        """
        } else {
            pythonRepairInstruction = ""
        }
        let content = """
        Local Alpine 执行结果

        已拦截重复失败命令，避免死循环。

        命令

        ```bash
        \(failure.command)
        ```

        工作目录：`\(failure.cwd)`
        上次退出码：`\(failure.exitCode.map(String.init) ?? "unknown")`

        上次输出摘要

        ```text
        \(failure.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（无输出）" : failure.outputPreview)
        ```

        Agent guard
        \(shouldStop ? "模型连续重复同一条失败命令，我已停止本轮自动执行。请总结已尝试的路径、最后错误和需要用户补充的线索。" : "Stuck Detection: 同一条失败命令已被拦截。下一轮必须 Strategy Switch：换文件检查、依赖检查、最小复现、语法检查或联网查资料，禁止再次重复同一条命令。")
        \(pythonRepairInstruction)
        """
        return appendLocalAlpineSystemResult(parentId: parentId, content: content)
    }

    private func appendLocalAlpineRepeatedCompletedCommandMessage(
        parentId: String,
        completed: LocalAlpineAgentCompletedCommand
    ) {
        let content = """
        Local Alpine 执行结果

        已拦截重复命令，避免把同一个脚本再次运行。

        已完成的命令：

        ```bash
        \(completed.command)
        ```

        工作目录：`\(completed.cwd)`
        退出码：`\(completed.exitCode.map(String.init) ?? "unknown")`

        上次输出摘要：

        ```text
        \(completed.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（无输出）" : completed.outputPreview)
        ```

        这条命令已经执行过；后续只需要总结结果或换一个不同的检查步骤。
        """
        appendLocalAlpineSystemResult(parentId: parentId, content: content)
    }

    private func appendLocalAlpineRepeatedErrorStopMessage(parentId: String, result: LocalAlpineAgentCommandResult) {
        let pythonRepairInstruction: String
        if Self.localAlpineOutputHasPythonSyntaxIssue(result.outputPreview) {
            pythonRepairInstruction = """

            Code repair required:
            不要让用户手动复制或敲命令。下一步必须由你自己发出 `iexa_alpine` JSON：
            1. 先 `read_file` 读取目标 `.py` 文件。
            2. 优先 `edit_file`/`patch_file` 修复原路径；大段重写才用 `write_files` 写回同一路径。
            3. 同一条 action 里运行适合该语言的有界验证命令。Python 用 `python3 -m py_compile <file> && python3 <file>`。
            """
        } else {
            pythonRepairInstruction = ""
        }
        let content = """
        我先停下，避免继续死循环。

        同类错误已经连续出现多次，最后一次命令退出码是 `\(result.exitCode.map(String.init) ?? "unknown")`。

        最后执行的命令：

        ```bash
        \(result.command)
        ```

        输出摘要：

        ```text
        \(result.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（无输出）" : result.outputPreview)
        ```

        当前判断：需要换一个定位路径，而不是继续重复执行同类命令。
        \(pythonRepairInstruction)
        """
        appendAssistantResult(parentId: parentId, model: selectedModelId ?? "Local Alpine Agent", content: content)
    }

    private func appendLocalAlpineNoProgressStopMessage(parentId: String, reason: String) {
        let content = """
        Local Alpine 执行结果

        我先停下，避免继续空转。

        原因：\(reason)

        下一步需要模型换一种更明确的本地操作，比如读取目标文件、列目录、运行一个有界验证命令，或直接总结当前已完成的结果。
        """
        appendLocalAlpineSystemResult(parentId: parentId, content: content)
    }

    private func appendLocalAlpineSystemResult(parentId: String, content: String) -> String {
        appendAssistantResult(parentId: parentId, model: "Local Alpine", content: content, metadata: [
            "iexa_local_alpine_result": "true",
            "iexa_local_alpine_raw_result": content
        ])
    }

    @discardableResult
    private func appendAssistantResult(
        parentId: String,
        model: String,
        content: String,
        metadata: [String: String]? = nil
    ) -> String {
        let message = ChatMessage(
            role: .assistant,
            content: content,
            timestamp: .now,
            model: model,
            isStreaming: false,
            metadata: metadata
        )
        let node = HistoryNode(
            id: message.id,
            parentId: parentId,
            childrenIds: [],
            role: .assistant,
            content: content,
            timestamp: message.timestamp,
            model: model,
            done: true,
            metadata: metadata
        )
        conversation?.messages.append(message)
        conversation?.history.addNode(node)
        conversation?.history.appendChildId(message.id, to: parentId)
        conversation?.history.currentId = message.id
        Task { await persistLocalConversationIfNeeded() }
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        return message.id
    }

    private func shouldExecuteLocalWorkspaceAgentForCurrentRequest() -> Bool {
        // Ordinary chat must never start a local file executor on keyword guesses.
        // Local project/file/command work is isolated behind the explicit Terminal Agent mode.
        return false
    }

    private func fallbackWorkspaceAgentBlockForCurrentRequest() -> String? {
        guard let userText = conversation?.messages.last(where: {
            $0.role == .user && !Self.isLocalWorkspaceAgentResult($0)
        })?.content else { return nil }

        let lowercased = userText.lowercased()
        let operation: String
        if ["列出", "列表", "目录", "文件列表", "ls ", "list"].contains(where: { lowercased.contains($0) }) {
            operation = "list"
        } else if ["读取", "打开文件", "查看文件", "cat ", "read"].contains(where: { lowercased.contains($0) }) {
            operation = "read"
        } else if ["搜索", "查找", "grep", "find in files", "search"].contains(where: { lowercased.contains($0) }) {
            operation = "search"
        } else if ["删除文件", "删除文件夹", "删除目录", "delete", "remove", "rm "].contains(where: { lowercased.contains($0) }) {
            operation = "delete"
        } else {
            return nil
        }

        let path = Self.extractWorkspacePath(from: userText) ?? "."
        var object: [String: Any] = [
            "action": operation,
            "path": path
        ]
        if operation == "search" {
            guard let query = Self.extractWorkspaceSearchQuery(from: userText) else { return nil }
            object["query"] = query
        }

        guard let data = try? JSONSerialization.data(withJSONObject: ["iexa_workspace": [object]], options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return """
        ```iexa_workspace
        \(json)
        ```
        """
    }

    private static func extractWorkspacePath(from text: String) -> String? {
        let patterns = [
            #"`([^`]+)`"#,
            #""([^"]+)""#,
            #"['“”‘’]([^'“”‘’]+)['“”‘’]"#,
            #"((?:[\w.-]+/)+[\w.-]+)"#,
            #"([\w.-]+\.(?:swift|json|md|txt|html|css|js|ts|tsx|py|rs|go|java|kt|xml|yml|yaml|toml))"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: nsRange),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }
        return nil
    }

    private static func extractWorkspaceSearchQuery(from text: String) -> String? {
        let patterns = [
            #"搜索(?:内容|文本)?[：:\s]+(.+?)(?:\s+(?:在|from|in)\s+.+)?$"#,
            #"查找(?:内容|文本)?[：:\s]+(.+?)(?:\s+(?:在|from|in)\s+.+)?$"#,
            #"grep\s+["']?([^"'\s]+)["']?"#,
            #"search\s+["']?([^"']+)["']?"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: nsRange),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'“”‘’")))
                if !candidate.isEmpty { return candidate }
            }
        }
        return nil
    }

    private func executeLocalWorkspaceAgent(messageId: String, content: String) async {
        let result = await LocalWorkspaceAgentService.shared.executeBlocks(in: content)
        guard conversation?.messages.contains(where: { $0.id == messageId }) == true else { return }

        let finalSummary = result.didExecute
            ? result.summary
            : "本地工作区没有检测到可执行操作。"

        let resultMessage = ChatMessage(
            role: .system,
            content: finalSummary,
            timestamp: .now,
            isStreaming: false,
            metadata: ["iexa_local_workspace_result": "true"]
        )
        let resultNode = HistoryNode(
            id: resultMessage.id,
            parentId: messageId,
            childrenIds: [],
            role: .system,
            content: finalSummary,
            timestamp: resultMessage.timestamp,
            done: true
        )

        conversation?.messages.append(resultMessage)
        conversation?.history.addNode(resultNode)
        conversation?.history.appendChildId(resultMessage.id, to: messageId)
        conversation?.history.currentId = resultMessage.id

        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func executeLocalAlpineAgent(messageId: String, content: String) async {
        guard !localAlpineAgentStopRequested else { return }
        guard conversation?.messages.contains(where: { $0.id == messageId }) == true else { return }

        let hasExecutableBlocks = await LocalAlpineAgentService.shared.hasExecutableBlocks(in: content)
        guard hasExecutableBlocks else { return }

        if let completedCommand = repeatedCompletedLocalAlpineCommand(for: content) {
            appendLocalAlpineRepeatedCompletedCommandMessage(parentId: messageId, completed: completedCommand)
            localAlpineAgentStopRequested = true
            return
        }

        if let repeatedFailure = repeatedLocalAlpineFailure(for: content) {
            let guardMessageId = appendLocalAlpineRepeatedCommandMessage(parentId: messageId, failure: repeatedFailure)
            if !localAlpineAgentStopRequested {
                scheduleLocalAlpineContinuationIfNeeded(after: guardMessageId, forceContinue: true)
            }
            return
        }

        let resultMessageId = UUID().uuidString
        let initialStatus = localAlpineStatus(description: localAlpineRunningDescription(for: content), done: false)
        let placeholderMessage = ChatMessage(
            id: resultMessageId,
            role: .assistant,
            content: "",
            timestamp: .now,
            model: "Local Alpine",
            isStreaming: true,
            statusHistory: [initialStatus],
            metadata: [
                "iexa_local_alpine_result": "true",
                "iexa_local_alpine_command_preview": Self.localAlpineCommandPreview(from: content),
                "iexa_local_alpine_display_command": Self.localAlpineCommandPreview(from: content),
                "iexa_local_alpine_cwd": "/mnt/iexa"
            ]
        )
        let placeholderNode = HistoryNode(
            id: resultMessageId,
            parentId: messageId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: placeholderMessage.timestamp,
            model: "Local Alpine",
            done: false,
            statusHistory: [initialStatus]
        )

        conversation?.messages.append(placeholderMessage)
        conversation?.history.addNode(placeholderNode)
        conversation?.history.appendChildId(resultMessageId, to: messageId)
        conversation?.history.currentId = resultMessageId
        localAlpineAgentExecutedMessageIds.insert(resultMessageId)
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

        beginStreamingBackgroundTaskIfNeeded()
        await startLocalAlpineLiveActivity(
            id: resultMessageId,
            command: content,
            detail: initialStatus.description ?? "正在执行本地命令..."
        )
        let progressHeartbeat = startLocalAlpineProgressHeartbeat(
            messageId: resultMessageId,
            command: content
        )
        defer {
            progressHeartbeat.cancel()
            endBackgroundTask()
        }

        let toolResult = await LocalAlpineTerminalAgentRunner.run(
            .executableContent(content),
            inputProvider: { request in
                guard !Task.isCancelled else { return nil }
                return await self.requestLocalAlpineInput(request)
            },
            eventHandler: { [weak self] event in
                self?.applyLocalAlpineToolEvent(event, messageId: resultMessageId)
            }
        )
        let result = toolResult.result
        guard conversation?.messages.contains(where: { $0.id == resultMessageId }) == true else {
            clearLocalAlpineLiveToolState(for: resultMessageId)
            return
        }
        guard !Task.isCancelled else {
            let stoppedStatus = localAlpineStatus(description: "本地任务已停止", done: true)
            updateAssistantMessage(
                id: resultMessageId,
                content: "",
                isStreaming: false,
                statusHistory: [stoppedStatus],
                error: ChatMessageError(content: "已停止本地任务")
            )
            conversation?.history.updateNode(id: resultMessageId) { node in
                node.done = true
                node.statusHistory = [stoppedStatus]
            }
            clearLocalAlpineLiveToolState(for: resultMessageId)
            await persistLocalConversationIfNeeded()
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            return
        }
        guard result.didExecute else {
            clearLocalAlpineLiveToolState(for: resultMessageId)
            conversation?.messages.removeAll { $0.id == resultMessageId }
            conversation?.history.removeSubtree(rootId: resultMessageId)
            await persistLocalConversationIfNeeded()
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            return
        }

        let doneStatus = localAlpineStatus(
            description: result.interactiveRequest == nil
                ? localAlpineCompletedDescription(for: result)
                : "本地输入已取消",
            done: true
        )
        updateAssistantMessage(
            id: resultMessageId,
            content: result.summary,
            isStreaming: false,
            statusHistory: [doneStatus]
        )
        if let index = conversation?.messages.firstIndex(where: { $0.id == resultMessageId }) {
            var metadata = conversation?.messages[index].metadata ?? [:]
            metadata["iexa_local_alpine_raw_result"] = result.summary
            if let toolRunId = result.toolRunId {
                metadata["iexa_local_alpine_tool_run_id"] = toolRunId
            }
            if let toolCalls = LocalAlpineToolCall.metadataString(for: result.toolCalls) {
                metadata["iexa_local_alpine_tool_calls"] = toolCalls
            }
            if let writtenFiles = LocalAlpineWrittenFile.metadataString(for: result.writtenFiles) {
                metadata["iexa_local_alpine_written_files"] = writtenFiles
            }
            if let commandResults = LocalAlpineAgentCommandResult.metadataString(for: result.commandResults) {
                metadata["iexa_local_alpine_command_results"] = commandResults
            }
            conversation?.messages[index].metadata = metadata
        }
        await attachLocalAlpineGeneratedMediaIfNeeded(messageId: resultMessageId)
        clearLocalAlpineLiveToolState(for: resultMessageId)
        let resultMessageSnapshot = conversation?.messages.first(where: { $0.id == resultMessageId })
        let resultMetadata = resultMessageSnapshot?.metadata
        let resultFiles = resultMessageSnapshot?.files
        recordLocalAlpineFailures(from: result)
        recordLocalAlpineCompletedCommands(from: result)
        conversation?.history.updateNode(id: resultMessageId) { node in
            node.content = result.summary
            node.done = true
            node.statusHistory = [doneStatus]
            node.metadata = resultMetadata
            if let files = resultFiles {
                node.files = files
            }
        }

        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

        if repeatedLocalAlpineErrorShouldStop(after: result, parentId: resultMessageId) {
            localAlpineAgentStopRequested = true
        } else if repeatedLocalAlpineNoProgressShouldStop(after: result, parentId: resultMessageId) {
            localAlpineAgentStopRequested = true
        } else if result.interactiveRequest == nil,
                  !localAlpineAgentStopRequested,
                  Self.localAlpineToolCallsShowCompletedGoal(
                      result.toolCalls,
                      commandResults: result.commandResults,
                      latestUserText: conversation?.messages.last(where: {
                          $0.role == .user && !Self.isLocalAlpineAgentResult($0)
                      })?.content
                  ) {
            if !scheduleLocalAlpineFinalSummary(after: resultMessageId) {
                localAlpineAgentStopRequested = true
            }
        } else if result.interactiveRequest == nil,
                  !localAlpineAgentStopRequested,
                  localAlpineResultNeedsFollowUp(after: resultMessageId) {
            scheduleLocalAlpineContinuationIfNeeded(after: resultMessageId, forceContinue: true)
        } else if result.interactiveRequest == nil,
                  !localAlpineAgentStopRequested {
            if !scheduleLocalAlpineFinalSummary(after: resultMessageId) {
                localAlpineAgentStopRequested = true
            }
        } else {
            localAlpineAgentStopRequested = true
        }
    }

    @discardableResult
    private func scheduleLocalAlpineFinalSummary(after resultMessageId: String) -> Bool {
        guard conversation?.messages.contains(where: { $0.id == resultMessageId }) == true else { return false }
        guard !localAlpineFinalSummaryParentIds.contains(resultMessageId) else { return false }
        guard !localAlpineContinuationParentIds.contains(resultMessageId) else { return false }
        guard conversation?.messages.contains(where: {
            $0.metadata?["iexa_local_alpine_final_summary"] == resultMessageId
        }) != true else { return false }
        guard !hasLaterNonResultAssistant(after: resultMessageId) else { return false }

        localAlpineFinalSummaryParentIds.insert(resultMessageId)
        localAlpineContinuationParentIds.insert(resultMessageId)
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = Task { [weak self] in
            await self?.startLocalAlpineContinuation(
                parentId: resultMessageId,
                forceContinue: true,
                finalSummaryOnly: true
            )
        }
        return true
    }

    private func hasLaterNonResultAssistant(after messageId: String) -> Bool {
        guard let messages = conversation?.messages,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return false
        }
        let nextIndex = messages.index(after: index)
        guard nextIndex < messages.endIndex else { return false }
        return messages[nextIndex...].contains {
            $0.role == .assistant && !Self.isLocalAlpineAgentResult($0)
        }
    }

    private func scheduleLocalAlpineContinuationIfNeeded(after resultMessageId: String, forceContinue: Bool = false) {
        guard !localAlpineAgentStopRequested else { return }
        guard conversation?.messages.contains(where: { $0.id == resultMessageId }) == true else { return }
        if localAlpineStepsSinceLastUser() >= localAlpineAgentMaxSteps {
            appendLocalAlpineAgentLimitMessage(parentId: resultMessageId)
            return
        }
        guard !localAlpineContinuationParentIds.contains(resultMessageId) else { return }
        guard forceContinue || isLocalAlpineAgentStillNeeded(after: resultMessageId) else { return }

        localAlpineContinuationParentIds.insert(resultMessageId)
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = Task { [weak self] in
            await self?.startLocalAlpineContinuation(parentId: resultMessageId, forceContinue: forceContinue)
        }
    }

    private func isLocalAlpineAgentStillNeeded(after resultMessageId: String) -> Bool {
        guard let messages = conversation?.messages,
              let resultIndex = messages.firstIndex(where: { $0.id == resultMessageId }) else { return false }
        if let resultNode = conversation?.history.nodes[resultMessageId],
           let parentId = resultNode.parentId,
           let nodes = conversation?.history.nodes,
           let parentNode = nodes[parentId],
           Self.contentContainsLocalAlpineInstruction(parentNode.content) {
            return true
        }
        let laterMessages = messages[messages.index(after: resultIndex)...]
        if laterMessages.contains(where: { $0.role == .assistant && !Self.isLocalAlpineAgentResult($0) }) {
            return false
        }
        let resultText = Self.normalizedLocalAlpineResultTextForFollowUpCheck(
            messages[resultIndex].content + "\n" + (messages[resultIndex].statusHistory.last?.description ?? "")
        )
        if Self.containsLocalAlpineFailureMarker(resultText) {
            return true
        }
        if let lastUser = messages.last(where: { $0.role == .user && !Self.isLocalAlpineAgentResult($0) }) {
            let userText = lastUser.content.lowercased()
            let actionMarkers = [
                "修", "改", "写", "创建", "生成", "安装", "编译", "构建", "测试", "运行", "验证",
                "检查", "查看", "分析", "诊断", "搜索", "抓取", "联网", "依赖",
                "fix", "write", "create", "build", "compile", "test", "run", "verify", "install",
                "check", "inspect", "diagnose", "search", "fetch", "dependency"
            ]
            return actionMarkers.contains(where: { userText.contains($0) })
        }
        return false
    }

    private func startLocalAlpineContinuation(
        parentId: String,
        forceContinue: Bool = false,
        finalSummaryOnly: Bool = false
    ) async {
        if !finalSummaryOnly {
            guard !localAlpineAgentStopRequested else { return }
            guard forceContinue || isLocalAlpineAgentStillNeeded(after: parentId) else { return }
            guard localAlpineStepsSinceLastUser() < localAlpineAgentMaxSteps else {
                appendLocalAlpineAgentLimitMessage(parentId: parentId)
                return
            }
        }
        guard let manager else { return }
        guard let conversation, conversation.messages.contains(where: { $0.id == parentId }) else { return }
        guard let modelId = selectedModelId ?? conversation.model else { return }
        guard !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let assistantMessageId = UUID().uuidString
        let thinkingDescription = finalSummaryOnly
            ? "本地结果已返回，正在整理回答..."
            : "本地结果已返回，正在检查下一步..."
        let thinkingStatus = ChatStatusUpdate(
            action: "local_alpine_agent",
            description: thinkingDescription,
            done: false
        )
        let assistantMessage = ChatMessage(
            id: assistantMessageId,
            role: .assistant,
            content: "",
            timestamp: .now,
            model: modelId,
            isStreaming: true,
            statusHistory: [thinkingStatus],
            metadata: finalSummaryOnly
                ? [
                    "iexa_local_alpine_continuation": "true",
                    "iexa_local_alpine_final_summary": parentId
                ]
                : ["iexa_local_alpine_continuation": "true"]
        )
        let assistantNode = HistoryNode(
            id: assistantMessageId,
            parentId: parentId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: assistantMessage.timestamp,
            model: modelId,
            done: false,
            statusHistory: [thinkingStatus],
            metadata: assistantMessage.metadata
        )

        self.conversation?.messages.append(assistantMessage)
        self.conversation?.history.addNode(assistantNode)
        self.conversation?.history.appendChildId(assistantMessageId, to: parentId)
        self.conversation?.history.currentId = assistantMessageId
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

        let useLocalAlpineNativeToolsForContinuation =
            !finalSummaryOnly && shouldUseLocalAlpineNativeTools(for: modelId)
        var apiMessages = await buildAPIMessagesAsync(
            includeLocalAlpineExecutionContext: true,
            preferLocalAlpineNativeTools: useLocalAlpineNativeToolsForContinuation
        )
        appendContextCompressionStatusIfNeeded(to: assistantMessageId)
        if finalSummaryOnly {
            Self.appendLocalAlpineFinalSummaryInstruction(to: &apiMessages)
        } else {
            Self.appendLocalAlpineContinuationInstruction(to: &apiMessages)
        }

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        activeTaskId = nil
        sessionId = UUID().uuidString
        beginStreamingBackgroundTaskIfNeeded()
        streamingStore.beginStreaming(
            messageId: assistantMessageId,
            modelId: modelId,
            initialStatusHistory: [thinkingStatus]
        )
        startLocalAlpineContinuationWatchdog(
            assistantMessageId: assistantMessageId,
            parentId: parentId,
            modelId: modelId,
            finalSummaryOnly: finalSummaryOnly
        )
        appendContextCompressionStatusIfNeeded(to: assistantMessageId)

        let effectiveChatId = conversationId ?? self.conversation?.id
        let socket = socketService
        var socketConnected = socket?.isConnected ?? false
        if !isOpenAICompatibleProvider, let socket, !socketConnected {
            socketConnected = await socket.ensureConnected(timeout: 8.0)
        }
        let socketSessionId = socket?.sid ?? sessionId
        let usePollingFallback = !isOpenAICompatibleProvider && !socketConnected

        if !isOpenAICompatibleProvider {
            await syncToServerViaTree()
            if socketConnected, let socket {
                registerSocketHandlers(
                    socket: socket,
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId
                )
            }
        }

        streamingTask = Task { [weak self] in
            guard let self else { return }
            let acc = ContentAccumulator()
            var exactUsage: [String: Any]?

            do {
                var request = ChatCompletionRequest(
                    model: modelId,
                    messages: apiMessages,
                    stream: true,
                    chatId: effectiveChatId,
                    sessionId: socketSessionId,
                    messageId: assistantMessageId,
                    parentId: parentId
                )
                if finalSummaryOnly {
                    request.toolChoice = "none"
                }
                await self.populateCommonRequestFields(&request)

                if self.isOpenAICompatibleProvider {
                    if !useLocalAlpineNativeToolsForContinuation {
                        let sseStream = try await manager.sendPreferredOpenAIStreaming(
                            request: request
                        )
                        for try await event in sseStream {
                            if Task.isCancelled { break }
                            if let usage = event.usage, !usage.isEmpty {
                                exactUsage = usage
                            }
                            self.applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                            if event.isFinished { break }
                        }
                    } else {
                        do {
                            exactUsage = try await self.streamOpenAICompatibleLocalAlpineNativeLoop(
                                manager: manager,
                                initialRequest: request,
                                assistantMessageId: assistantMessageId,
                                acc: acc
                            )
                        } catch {
                            guard Self.errorLooksLikeUnsupportedNativeTools(error) else { throw error }
                            self.localAlpineNativeToolsUnsupportedModels.insert(modelId)
                            var fallbackRequest = request
                            fallbackRequest.messages = await self.buildAPIMessagesAsync(
                                includeLocalAlpineExecutionContext: true,
                                preferLocalAlpineNativeTools: false
                            )
                            fallbackRequest.tools = nil
                            fallbackRequest.toolChoice = nil
                            let sseStream = try await manager.sendPreferredOpenAIStreaming(request: fallbackRequest)
                            for try await event in sseStream {
                                if Task.isCancelled { break }
                                if let usage = event.usage, !usage.isEmpty {
                                    exactUsage = usage
                                }
                                self.applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                                if event.isFinished { break }
                            }
                        }
                    }
                    if Task.isCancelled { return }
                    acc.markReasoningDone()
                    await self.finishLocalAlpineContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: acc.content,
                        usage: exactUsage
                    )
                    return
                }

                if request.isPipeModel {
                    let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                    for try await event in sseStream {
                        if Task.isCancelled { break }
                        if let usage = event.usage, !usage.isEmpty {
                            exactUsage = usage
                        }
                        self.applyStreamingEventDelta(event, to: acc, assistantMessageId: assistantMessageId)
                        if event.isFinished { break }
                    }
                    if Task.isCancelled { return }
                    acc.markReasoningDone()
                    await self.finishLocalAlpineContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: acc.content,
                        usage: exactUsage
                    )
                    return
                }

                let json = try await manager.sendMessageHTTP(request: request)
                if let err = json["error"] as? String, !err.isEmpty {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: Self.cleanedProviderErrorMessage(err) ?? err)
                    )
                    self.cleanupStreaming()
                    return
                }
                if let taskId = json["task_id"] as? String {
                    self.activeTaskId = taskId
                }
                if usePollingFallback, let chatId = effectiveChatId {
                    await self.pollLocalAlpineContinuation(
                        chatId: chatId,
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        socketSessionId: socketSessionId
                    )
                } else if usePollingFallback {
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: "",
                        isStreaming: false,
                        error: ChatMessageError(content: "当前会话无法继续本地任务。")
                    )
                    self.cleanupStreaming()
                } else {
                    self.logger.info("Local Alpine continuation HTTP POST done – waiting for socket events")
                }
            } catch {
                if !Task.isCancelled {
                    let apiError = APIError.from(error)
                    let continuationStatus: [ChatStatusUpdate]?
                    if apiError.requiresReauth {
                        self.stopLocalAlpineAutoContinuationForAuthenticationFailure()
                        continuationStatus = [
                            ChatStatusUpdate(
                                action: "local_alpine_agent",
                                description: "登录已过期，已停止自动续跑",
                                done: true,
                                occurredAt: .now
                            )
                        ]
                    } else {
                        continuationStatus = nil
                    }
                    let message = Self.localizedGenerationError(error)
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: acc.content,
                        isStreaming: false,
                        statusHistory: continuationStatus,
                        error: ChatMessageError(content: message)
                    )
                    self.cleanupStreaming()
                    await self.persistLocalConversationIfNeeded()
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
        }
    }

    private func startLocalAlpineContinuationWatchdog(
        assistantMessageId: String,
        parentId: String,
        modelId: String,
        finalSummaryOnly: Bool
    ) {
        localAlpineContinuationWatchdogTask?.cancel()
        localAlpineContinuationWatchdogTask = Task { [weak self] in
            let delay: UInt64 = finalSummaryOnly ? 35_000_000_000 : 45_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.handleLocalAlpineContinuationTimeout(
                assistantMessageId: assistantMessageId,
                parentId: parentId,
                modelId: modelId,
                finalSummaryOnly: finalSummaryOnly
            )
        }
    }

    @MainActor
    private func handleLocalAlpineContinuationTimeout(
        assistantMessageId: String,
        parentId: String,
        modelId: String,
        finalSummaryOnly: Bool
    ) async {
        guard let message = conversation?.messages.first(where: { $0.id == assistantMessageId }),
              message.isStreaming else { return }
        let currentContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentContent.isEmpty {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled,
                  let refreshed = conversation?.messages.first(where: { $0.id == assistantMessageId }),
                  refreshed.isStreaming else { return }
            let refreshedContent = refreshed.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if refreshedContent.count > currentContent.count {
                startLocalAlpineContinuationWatchdog(
                    assistantMessageId: assistantMessageId,
                    parentId: parentId,
                    modelId: modelId,
                    finalSummaryOnly: finalSummaryOnly
                )
                return
            }
            streamingTask?.cancel()
            streamingTask = nil
            localAlpineContinuationTask?.cancel()
            localAlpineContinuationTask = nil
            await finishLocalAlpineContinuation(
                assistantMessageId: assistantMessageId,
                modelId: modelId,
                content: refreshedContent,
                usage: nil
            )
            return
        }

        streamingTask?.cancel()
        streamingTask = nil
        localAlpineContinuationTask?.cancel()
        localAlpineContinuationTask = nil

        let retryCount = localAlpineContinuationRetryCounts[parentId] ?? 0
        if retryCount < 1 {
            localAlpineContinuationRetryCounts[parentId] = retryCount + 1
            conversation?.messages.removeAll { $0.id == assistantMessageId }
            conversation?.history.removeSubtree(rootId: assistantMessageId)
            localAlpineContinuationParentIds.remove(parentId)
            if finalSummaryOnly {
                localAlpineFinalSummaryParentIds.remove(parentId)
            }
            localAlpineFinishedContinuationMessageIds.remove(assistantMessageId)
            cleanupStreaming()
            await persistLocalConversationIfNeeded()
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            if finalSummaryOnly {
                _ = scheduleLocalAlpineFinalSummary(after: parentId)
            } else {
                scheduleLocalAlpineContinuationIfNeeded(after: parentId, forceContinue: true)
            }
            return
        }

        conversation?.messages.removeAll { $0.id == assistantMessageId }
        conversation?.history.removeSubtree(rootId: assistantMessageId)
        localAlpineAgentStopRequested = true
        localAlpineContinuationTask = nil
        localAlpineContinuationWatchdogTask = nil
        cleanupStreaming()
        appendLocalAlpineNoProgressStopMessage(
            parentId: parentId,
            reason: finalSummaryOnly
                ? "模型长时间没有整理出可展示的最终结果。"
                : "模型长时间没有给出新的本地工具步骤。"
        )
        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func finishLocalAlpineContinuation(
        assistantMessageId: String,
        modelId: String,
        content: String,
        usage: [String: Any]?
    ) async {
        let isFinalSummary = conversation?.messages.first(where: { $0.id == assistantMessageId })?
            .metadata?["iexa_local_alpine_final_summary"] != nil
        localAlpineContinuationWatchdogTask?.cancel()
        localAlpineContinuationWatchdogTask = nil

        guard !localAlpineAgentStopRequested || isFinalSummary else {
            cleanupStreaming()
            return
        }
        let parentResultId = conversation?.history.nodes[assistantMessageId]?.parentId
        let parentNeedsFollowUp = parentResultId.map { self.localAlpineParentNeedsToolFollowUp($0) } ?? false
        let visibleFinalSummaryContent = isFinalSummary
            ? Self.localAlpineFinalSummaryVisibleContent(from: content)
            : nil
        let trimmed = (visibleFinalSummaryContent ?? content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            conversation?.messages.removeAll { $0.id == assistantMessageId }
            conversation?.history.removeSubtree(rootId: assistantMessageId)
            cleanupStreaming()
            if isFinalSummary, let parentResultId {
                let retryCount = localAlpineContinuationRetryCounts[parentResultId] ?? 0
                if retryCount < 1 {
                    localAlpineContinuationRetryCounts[parentResultId] = retryCount + 1
                    localAlpineContinuationParentIds.remove(parentResultId)
                    localAlpineFinalSummaryParentIds.remove(parentResultId)
                    localAlpineFinishedContinuationMessageIds.remove(assistantMessageId)
                    await persistLocalConversationIfNeeded()
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                    if scheduleLocalAlpineFinalSummary(after: parentResultId) {
                        return
                    }
                }
                localAlpineAgentStopRequested = true
                localAlpineContinuationTask = nil
                appendLocalAlpineNoProgressStopMessage(
                    parentId: parentResultId,
                    reason: "模型返回了空总结，没有生成最终回答。"
                )
                await persistLocalConversationIfNeeded()
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            } else if parentNeedsFollowUp {
                localAlpineAgentStopRequested = true
                localAlpineContinuationTask = nil
                if let parentResultId {
                    appendLocalAlpineNoProgressStopMessage(
                        parentId: parentResultId,
                        reason: "模型返回了空内容，没有给出下一步工具调用。"
                    )
                }
            }
            return
        }
        guard !localAlpineFinishedContinuationMessageIds.contains(assistantMessageId) else {
            cleanupStreaming()
            return
        }
        localAlpineFinishedContinuationMessageIds.insert(assistantMessageId)

        let rawContent = isFinalSummary
            ? (visibleFinalSummaryContent ?? "")
            : content
        let emittedLocalAlpineInstruction = !isFinalSummary && Self.contentContainsLocalAlpineInstruction(content)
        let doneDescription: String
        if isFinalSummary {
            doneDescription = "已整理本地回答"
        } else if emittedLocalAlpineInstruction {
            doneDescription = "已决定继续执行下一步"
        } else {
            doneDescription = "已整理本地结果"
        }
        let doneStatus = ChatStatusUpdate(
            action: "local_alpine_agent",
            description: doneDescription,
            done: true,
            occurredAt: .now
        )
        let finalContent: String
        updateAssistantMessage(
            id: assistantMessageId,
            content: rawContent,
            isStreaming: false,
            statusHistory: [doneStatus]
        )
        normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
        finalContent = conversation?.messages.first(where: { $0.id == assistantMessageId })?.content ?? rawContent
        applyUsage(usage, toMessageId: assistantMessageId)
        let lastUser = conversation?.messages.last(where: {
            $0.role == .user && !Self.isLocalAlpineAgentResult($0)
        })
        recordTokenUsageForCompletedTurn(
            assistantMessageId: assistantMessageId,
            userText: lastUser?.content ?? "",
            assistantText: finalContent,
            userAttachments: [],
            usage: usage
        )
        hasFinishedStreaming = true
        isStreaming = false
        isExternallyStreaming = false
        selfInitiatedStream = false
        activeTaskId = nil
        lastTaskExtractionLength = 0
        await persistLocalConversationIfNeeded()
        await sendCompletionNotificationIfNeeded(content: finalContent)
        endBackgroundTask()
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDelayTask?.cancel()
        recoveryDelayTask = nil
        emptyPollCount = 0
        if isFinalSummary {
            localAlpineAgentStopRequested = true
            localAlpineContinuationTask = nil
            if let parentResultId {
                localAlpineContinuationRetryCounts.removeValue(forKey: parentResultId)
            }
        } else if emittedLocalAlpineInstruction {
            localAlpineContinuationTask = nil
            if let parentResultId {
                localAlpineContinuationRetryCounts.removeValue(forKey: parentResultId)
            }
            scheduleLocalAlpineAgentIfNeeded(
                messageId: assistantMessageId,
                content: rawContent,
                error: nil
            )
        } else {
            localAlpineAgentStopRequested = true
            localAlpineContinuationTask = nil
        }
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func localAlpineParentNeedsToolFollowUp(_ parentMessageId: String) -> Bool {
        guard let parent = conversation?.messages.first(where: { $0.id == parentMessageId }) else {
            return false
        }
        if Self.isLocalAlpineAgentResult(parent) {
            return localAlpineResultNeedsFollowUp(after: parentMessageId)
        }
        if parent.role == .user {
            return Self.localAlpineUserRequestRequiresHostExecution(parent.content)
        }
        return false
    }

    private func localAlpineResultNeedsFollowUp(after resultMessageId: String) -> Bool {
        guard let message = conversation?.messages.first(where: { $0.id == resultMessageId }) else { return false }
        let rawResult = message.metadata?["iexa_local_alpine_raw_result"] ?? message.content
        let commandResults = LocalAlpineAgentCommandResult.decodeMetadata(message.metadata?["iexa_local_alpine_command_results"])
        let toolCalls = LocalAlpineToolCall.decodeMetadata(message.metadata?["iexa_local_alpine_tool_calls"])
        let latestUserText = conversation?.messages.last(where: {
            $0.role == .user && !Self.isLocalAlpineAgentResult($0)
        })?.content
        return Self.localAlpineResultNeedsFollowUp(
            rawResult,
            commandResults: commandResults,
            toolCalls: toolCalls,
            latestUserText: latestUserText
        )
    }

    private static func localAlpineResultNeedsFollowUp(
        _ text: String,
        commandResults: [LocalAlpineAgentCommandResult] = [],
        toolCalls: [LocalAlpineToolCall] = [],
        latestUserText: String? = nil
    ) -> Bool {
        let normalized = normalizedLocalAlpineResultTextForFollowUpCheck(text)
        if normalized.contains("iexa_auto_repair_verified_success") {
            return false
        }
        if commandResults.contains(where: { $0.failed })
            || toolCalls.contains(where: { $0.phase == .result && $0.failed }) {
            return true
        }
        if normalized.contains("已暂缓") && normalized.contains("单步 agent") {
            return true
        }
        if localAlpineToolCallsShowCompletedGoal(
            toolCalls,
            commandResults: commandResults,
            latestUserText: latestUserText
        ) {
            return false
        }
        if let latestUserText,
           isLocalAlpineGoalActionRequest(latestUserText),
           localAlpineResultIsOnlyPreflightOrQuestion(
               normalized,
               commandResults: commandResults,
               latestUserText: latestUserText
           ) {
            return true
        }
        if containsSuccessfulLocalAlpineExit(normalized)
            && !containsCriticalLocalAlpineFailureMarker(normalized) {
            return false
        }
        return containsLocalAlpineFailureMarker(normalized)
    }

    private static func localAlpineToolCallsShowCompletedGoal(
        _ toolCalls: [LocalAlpineToolCall],
        commandResults: [LocalAlpineAgentCommandResult],
        latestUserText: String?
    ) -> Bool {
        let completed = toolCalls.filter { $0.phase == .result && !$0.failed }
        guard !completed.isEmpty else { return false }
        let toolNames = Set(completed.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if !toolNames.isDisjoint(with: ["verify", "verify_absent", "test", "compile", "build", "run", "run_script"]) {
            return true
        }
        let latestUserText = latestUserText ?? ""
        if localAlpineUserRequestWantsDeletion(latestUserText),
           toolNames.contains("delete_files") || toolNames.contains("delete_file") {
            return true
        }
        let commandText = commandResults.map { $0.command.lowercased() }.joined(separator: "\n")
        if localAlpineCommandsContainGoalVerification(commandText) {
            return true
        }
        if localAlpineUserRequestWantsModification(latestUserText),
           !toolNames.isDisjoint(with: ["write_files", "write_file", "edit_file", "patch_file"]) {
            if localAlpineUserRequestWantsVerification(latestUserText) {
                return localAlpineCommandsContainGoalVerification(commandText)
            }
            return true
        }
        return false
    }

    private static func isLocalAlpineGoalActionRequest(_ text: String) -> Bool {
        let intent = localAlpineIntent(for: text)
        if intent.requiresHostExecution {
            return true
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let explanationOnlyTerms = [
            "为什么", "原因", "怎么回事", "这是什么", "解释一下", "说明一下",
            "why", "reason", "what happened", "explain"
        ]
        if containsAny(normalized, explanationOnlyTerms) {
            return false
        }
        let actionTerms = [
            "安装", "装", "运行", "执行", "跑", "测试", "验证", "修复", "修改",
            "写", "创建", "生成", "编译", "构建", "依赖", "读取", "查看",
            "列出", "搜索", "查找", "删除", "清理", "重命名", "复制", "移动",
            "解决", "报错", "错误", "失败", "崩溃", "闪退", "不能用", "用不了",
            "异常", "代码", "脚本", "程序", "项目", "爬虫", "抓取",
            "访问", "请求", "联网", "保存", "输出",
            "install", "run", "execute", "test", "verify", "fix", "modify",
            "write", "create", "generate", "compile", "build", "dependency", "dependencies",
            "read", "list", "search", "find", "delete", "remove", "rename", "copy", "move",
            "error", "fail", "failure", "failed", "issue", "bug", "crash", "broken", "not working",
            "code", "script", "program", "project", "crawler", "spider", "scrape", "fetch",
            "request", "url", "website", "api", "save", "output"
        ]
        return actionTerms.contains { normalized.contains($0) }
    }

    private static func localAlpineResultIsOnlyPreflightOrQuestion(
        _ normalized: String,
        commandResults: [LocalAlpineAgentCommandResult],
        latestUserText: String? = nil
    ) -> Bool {
        if normalized.contains("iexa_agent_task_complete")
            || normalized.contains("iexa_auto_repair_verified_success") {
            return false
        }
        if normalized.contains("请告诉我")
            || normalized.contains("需要你提供")
            || normalized.contains("你可以")
            || normalized.contains("请手动")
            || normalized.contains("手动运行")
            || normalized.contains("复制以下命令")
            || normalized.contains("please provide")
            || normalized.contains("please tell me")
            || normalized.contains("tell me the path")
            || normalized.contains("provide the path")
            || normalized.contains("run this command")
            || normalized.contains("copy and paste") {
            return true
        }
        let combinedCommands = commandResults
            .map { $0.command.lowercased() }
            .joined(separator: "\n")
        guard !combinedCommands.isEmpty else { return false }
        let preflightTerms = [
            "command -v", "which ", " apk info", "apk info", " ls ", "ls -",
            " find ", "grep ", "cat /etc/alpine-release", "uname", "python3 --version",
            "pip3 --version", "node --version", "npm --version", "gcc --version",
            "g++ --version", "make --version", "pwd"
        ]
        let realActionPatterns = [
            #"(?m)(^|[;&|{]\s*)apk\s+add\b"#,
            #"(?m)(^|[;&|{]\s*)(?:python3\s+-m\s+pip|pip3?|npm)\s+(?:install|i|add)\b"#,
            #"(?m)(^|[;&|{]\s*)python3\s+(?:/|\./|[\w.-]+\.py\b|-m\b|-c\b|-\s)"#,
            #"(?m)(^|[;&|{]\s*)node\s+(?:/|\./|[\w.-]+\.m?js\b)"#,
            #"(?m)(^|[;&|{]\s*)gcc\s+(?!--version\b|--help\b)"#,
            #"(?m)(^|[;&|{]\s*)g\+\+\s+(?!--version\b|--help\b)"#,
            #"(?m)(^|[;&|{]\s*)make(?:\s+(?!--version\b|--help\b)|$)"#,
            #"(?m)(^|[;&|{]\s*)rm\s+(?:-|/mnt/iexa|\./)"#,
            #"(?m)(^|[;&|{]\s*)mv\s+"#,
            #"(?m)(^|[;&|{]\s*)cp\s+"#,
            #"(?m)(^|[;&|{]\s*)mkdir\s+"#,
            #"(?m)(^|[;&|{]\s*)touch\s+"#,
            #"(?m)(^|[;&|{]\s*)chmod\s+"#,
            #"\bwrite_files\b"#
        ]
        let didRealAction = realActionPatterns.contains {
            combinedCommands.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if didRealAction {
            if let latestUserText,
               localAlpineUserRequestNeedsVerificationAfterSetup(latestUserText),
               !localAlpineUserRequestIsSetupOnly(latestUserText),
               localAlpineActionWasOnlyInstallOrWrite(combinedCommands) {
                return true
            }
            return false
        }
        let onlyPreflightCommands = commandResults.allSatisfy { result in
            let command = result.command.lowercased()
            return preflightTerms.contains { command.contains($0) }
        }
        if onlyPreflightCommands {
            if let latestUserText,
               localAlpineUserRequestIsInspectionOnly(latestUserText),
               localAlpineInspectionCommandSatisfiesRequest(combinedCommands) {
                return false
            }
            return true
        }
        return preflightTerms.contains { combinedCommands.contains($0) }
    }

    private static func localAlpineUserRequestIsInspectionOnly(_ text: String) -> Bool {
        let intent = localAlpineIntent(for: text)
        if intent.isInspectionOnly {
            return true
        }
        return localAlpineShellCommandIsInspectionOnly(text)
    }

    private static func localAlpineInspectionCommandSatisfiesRequest(_ combinedCommands: String) -> Bool {
        let inspectionPatterns = [
            #"(?m)(^|[;&|]\s*)pwd\b"#,
            #"(?m)(^|[;&|]\s*)ls\b"#,
            #"(?m)(^|[;&|]\s*)find\b"#,
            #"(?m)(^|[;&|]\s*)cat\b"#,
            #"(?m)(^|[;&|]\s*)sed\s+-n\b"#,
            #"(?m)(^|[;&|]\s*)head\b"#,
            #"(?m)(^|[;&|]\s*)tail\b"#,
            #"(?m)(^|[;&|]\s*)grep\b"#,
            #"(?m)(^|[;&|]\s*)rg\b"#,
            #"(?m)(^|[;&|]\s*)command\s+-v\b"#,
            #"(?m)(^|[;&|]\s*)which\b"#,
            #"(?m)(^|[;&|]\s*)apk\s+info\b"#,
            #"(?m)(^|[;&|]\s*)python3?\s+--version\b"#,
            #"(?m)(^|[;&|]\s*)python3?\s+-m\s+pip\b"#,
            #"(?m)(^|[;&|]\s*)pip3?\s+(?:--version|list|show|freeze)\b"#,
            #"(?m)(^|[;&|]\s*)lua(?:5\.\d)?\s+-v\b"#,
            #"(?m)(^|[;&|]\s*)node\s+--version\b"#,
            #"(?m)(^|[;&|]\s*)npm\s+--version\b"#,
            #"(?m)(^|[;&|]\s*)gcc\s+--version\b"#,
            #"(?m)(^|[;&|]\s*)g\+\+\s+--version\b"#,
            #"(?m)(^|[;&|]\s*)clang\s+--version\b"#,
            #"(?m)(^|[;&|]\s*)make\s+--version\b"#
        ]
        return inspectionPatterns.contains {
            combinedCommands.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func localAlpineUserRequestNeedsVerificationAfterSetup(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let postSetupTerms = [
            "运行", "执行", "跑", "测试", "验证", "修复", "调试", "编译", "构建",
            "解决", "报错", "错误", "失败", "崩溃", "闪退", "不能用", "用不了",
            "问题", "异常", "修", "改", "写", "创建", "生成", "代码", "脚本",
            "程序", "项目", "爬虫", "抓取", "访问", "请求", "联网", "网站",
            "接口", "页面", "解析", "保存", "输出", "检查",
            "跑一下", "执行一下", "运行一下", "测试一下", "验证一下",
            "run", "execute", "test", "verify", "fix", "debug", "compile", "build",
            "error", "fail", "failure", "failed", "issue", "bug", "crash", "broken", "not working",
            "code", "script", "program", "project", "crawler", "spider", "scrape",
            "fetch", "request", "http", "url", "website", "api", "parse", "save", "output"
        ]
        return postSetupTerms.contains { normalized.contains($0) }
    }

    private static func localAlpineUserRequestIsSetupOnly(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let setupTerms = [
            "安装", "装一下", "装个", "装上", "添加依赖", "安装依赖", "配置环境",
            "install", "install dependency", "install dependencies", "setup dependency",
            "add package", "apk add", "pip install", "npm install"
        ]
        guard setupTerms.contains(where: { normalized.contains($0) }) else { return false }

        let goalTerms = [
            "运行", "执行", "跑", "测试", "验证", "修复", "调试", "编译", "构建",
            "解决", "报错", "错误", "失败", "崩溃", "闪退", "不能用", "用不了",
            "写", "创建", "生成", "代码", "脚本", "程序", "项目", "爬虫", "抓取",
            "访问", "请求", "联网", "保存", "输出",
            "run", "execute", "test", "verify", "fix", "debug", "compile", "build",
            "error", "fail", "failure", "failed", "issue", "bug", "crash", "broken", "not working",
            "write", "create", "generate", "code", "script", "program", "project",
            "crawler", "spider", "scrape", "fetch", "request", "url", "website", "api"
        ]
        return !goalTerms.contains { normalized.contains($0) }
    }

    private static func localAlpineActionWasOnlyInstallOrWrite(_ combinedCommands: String) -> Bool {
        if localAlpineCommandsContainGoalVerification(combinedCommands) {
            return false
        }
        let actionCommands = combinedCommands
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !actionCommands.isEmpty else { return false }
        return actionCommands.allSatisfy { command in
            command == "write_files"
                || command.contains("apk add")
                || command.contains("pip install")
                || command.contains("pip3 install")
                || command.contains("npm install")
                || command.hasPrefix("command -v")
                || command.hasPrefix("which ")
                || command.hasPrefix("apk info")
                || command.contains("--version")
        }
    }

    private static func localAlpineCommandsContainGoalVerification(_ combinedCommands: String) -> Bool {
        let verificationPatterns = [
            #"(?m)(^|[;&|]\s*)python3\s+(?:/|\./|[\w.-]+\.py\b|-m\s+(?!pip\b)|-\s)"#,
            #"(?m)(^|[;&|]\s*)python\s+(?:/|\./|[\w.-]+\.py\b|-m\s+(?!pip\b)|-\s)"#,
            #"(?m)(^|[;&|]\s*)(?:lua|lua5(?:\.[1-4])?|luajit|ruby|php|perl|Rscript|julia|deno|bun)\s+(?:/|\./|[\w./-]+\.(?:lua|rb|php|pl|r|jl|m?js|cjs|ts|tsx)\b|-e\b|-c\b|-\s)"#,
            #"(?m)(^|[;&|]\s*)(?:sh|bash|zsh|fish)\s+(?:/|\./|[\w./-]+\.(?:sh|bash|zsh|fish)\b|-c\b|-\s)"#,
            #"(?m)(^|[;&|]\s*)java\s+(?:-jar\s+\S+\.jar\b|[\w.$]+)\b"#,
            #"(?m)(^|[;&|]\s*)(?:javac|kotlinc|swift|ts-node|tsx)\s+(?!--version\b|--help\b)"#,
            #"(?m)(^|[;&|]\s*)node\s+(?:/|\./|[\w.-]+\.m?js\b)"#,
            #"(?m)(^|[;&|]\s*)npm\s+(?:test|run|start)\b"#,
            #"(?m)(^|[;&|]\s*)pytest\b"#,
            #"(?m)(^|[;&|]\s*)go\s+(?:test|run|build)\b"#,
            #"(?m)(^|[;&|]\s*)cargo\s+(?:test|run|build)\b"#,
            #"(?m)(^|[;&|]\s*)make(?:\s+(?!--version\b|--help\b)|$)"#,
            #"(?m)(^|[;&|]\s*)gcc\s+(?!--version\b|--help\b)"#,
            #"(?m)(^|[;&|]\s*)g\+\+\s+(?!--version\b|--help\b)"#,
            #"(?m)(^|[;&|]\s*)curl\s+(?!--version\b|--help\b)"#,
            #"(?m)(^|[;&|]\s*)wget\s+(?!--version\b|--help\b)"#
        ]
        return verificationPatterns.contains {
            combinedCommands.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func normalizedLocalAlpineResultTextForFollowUpCheck(_ text: String) -> String {
        var normalized = text.lowercased()
        // Local Alpine may list this internal folder on success paths.
        // Its name contains "failed", but that must not be treated as a task failure signal.
        let harmlessTokens = [
            ".iexa_failed_writes",
            "/.iexa_failed_writes",
            "iexa_failed_writes/"
        ]
        for token in harmlessTokens {
            normalized = normalized.replacingOccurrences(of: token, with: ".iexa_draft_writes")
        }
        return normalized
    }

    private static func containsSuccessfulLocalAlpineExit(_ normalized: String) -> Bool {
        normalized.contains("退出码：`0`")
            || normalized.contains("退出码: `0`")
            || normalized.contains("exit code 0")
            || normalized.contains("exit code: 0")
    }

    private static func containsCriticalLocalAlpineFailureMarker(_ normalized: String) -> Bool {
        let markers = [
            "traceback", "syntaxerror", "indentationerror", "modulenotfounderror",
            "写入已拒绝", "写入失败", "缩进预检失败", "语法校验失败",
            "python 写入已拒绝", "语法/缩进校验未通过", "目标文件未被覆盖"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private static func containsLocalAlpineFailureMarker(_ normalized: String) -> Bool {
        let markers = [
            "退出码：`1`", "退出码：`2`", "退出码：`125`", "退出码：`126`", "退出码：`127`", "退出码：`124`",
            "not found", "error", "missing", "no such file", "traceback", "exception",
            "command not found", "permission denied", "syntaxerror", "indentationerror",
            "module not found", "no module named", "输入已取消", "存在错误输出",
            "写入已拒绝", "写入失败", "缩进预检失败", "语法校验失败",
            "python 写入已拒绝", "语法/缩进校验未通过", "目标文件未被覆盖"
        ]
        if markers.contains(where: { normalized.contains($0.lowercased()) }) {
            return true
        }
        let failureRegexes = [
            #"\bfailed to\b"#,
            #"\bcommand failed\b"#,
            #"\bbuild failed\b"#,
            #"\barchive failed\b"#
        ]
        return failureRegexes.contains {
            normalized.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func pollLocalAlpineContinuation(
        chatId: String,
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String
    ) async {
        guard let manager else {
            cleanupStreaming()
            return
        }
        var lastContentLength = 0
        var staleCount = 0
        for _ in 0..<40 {
            if Task.isCancelled || localAlpineAgentStopRequested { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled || localAlpineAgentStopRequested { return }

            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                guard let serverAssistant = refreshed.messages.first(where: { $0.id == assistantMessageId }) else {
                    continue
                }
                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !serverContent.isEmpty else { continue }
                let localContent = conversation?.messages
                    .first(where: { $0.id == assistantMessageId })?.content ?? ""
                let protectedContent = CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                    local: localContent,
                    incoming: serverAssistant.content
                ) ? localContent : serverAssistant.content
                updateAssistantMessage(id: assistantMessageId, content: protectedContent, isStreaming: true)
                if serverContent.count > lastContentLength {
                    lastContentLength = serverContent.count
                    staleCount = 0
                } else {
                    staleCount += 1
                }
                if staleCount >= 3 {
                    await finishLocalAlpineContinuation(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        content: protectedContent,
                        usage: nil
                    )
                    await manager.sendChatCompleted(
                        chatId: chatId,
                        messageId: assistantMessageId,
                        model: modelId,
                        sessionId: socketSessionId,
                        messages: buildSimpleAPIMessages()
                    )
                    return
                }
            } catch {
                logger.warning("Local Alpine continuation polling failed: \(error.localizedDescription)")
            }
        }

        let latestContent = conversation?.messages
            .first(where: { $0.id == assistantMessageId })?
            .content ?? ""
        await finishLocalAlpineContinuation(
            assistantMessageId: assistantMessageId,
            modelId: modelId,
            content: latestContent,
            usage: nil
        )
    }

    private static func appendLocalAlpineContinuationInstruction(to messages: inout [[String: Any]]) {
        let instruction = """
        [Local Alpine continuation]
        You are in a continuous Local Alpine agent loop. Read the latest real Local Alpine result above.

        Controller policy:
        - Follow the `controller_verdict` in `[Local Alpine execution state]`.
        - If it is `ready_for_final_summary`, do not emit `iexa_alpine`; summarize the result normally.
        - If it is `needs_next_tool_*`, emit exactly one meaningful bounded `iexa_alpine` step and wait for the next observation. A write plus one direct verification is allowed only when it validates the same file/change.
        - If it is `tool_running`, report that the local command is still running or ask whether to stop it.
        - `iexa_alpine` is a Markdown fence intercepted by the host app, not a provider function. Never say it does not exist.
        - Never ask the user to send back local output; the host app returns Local Alpine output automatically.
        - Use BusyBox/ash-compatible commands. Prefer `list_dir`, `glob`, `grep`, `verify`, and `browser_use` wrappers; if raw shell is necessary, avoid GNU/bash-only syntax such as `find -printf`, `grep -P`, `[[ ... ]]`, `source`, `mapfile`, and process substitution.
        - Keep visible text before a tool block empty or one short progress sentence.
        [/Local Alpine continuation]
        """
        appendSystemInstruction(instruction, marker: "[Local Alpine continuation]", to: &messages)
    }

    private static func appendLocalAlpineMissingToolCorrectionInstruction(
        to messages: inout [[String: Any]],
        userGoal: String,
        assistantContent: String
    ) {
        let instruction = """
        [Local Alpine missing tool correction]
        The user asked for a concrete local Alpine operation, but the previous assistant turn answered in prose without a usable `iexa_alpine` block. Correct that now.

        User goal:
        \(clippedForSystemContext(userGoal, maxCharacters: 1_500))

        Previous assistant prose:
        \(clippedForSystemContext(assistantContent, maxCharacters: 2_000))

        Correction policy:
        - Emit exactly one fenced Markdown block with language `iexa_alpine`.
        - Do not ask for confirmation when the user already used imperative wording such as read, check, delete, modify, change, replace, run, rerun, test, or execute.
        - Resolve "this/it/这个/它/删了/换一个/再跑/继续" from the latest Local Alpine observation and recent written files.
        - For reads/checks, use `read_file`, `list_dir`, `grep`, `verify`, or bounded `command` as appropriate.
        - For deletes, use structured `delete_file`/`delete_files`, then verify absence in the same block.
        - For modification, read the relevant file if needed, then use `edit_file`, `patch_file`, or `write_files` and verify when the user asked to run/test.
        - Use BusyBox/ash-compatible commands. Prefer structured wrappers for list/search/check/fetch work; do not use GNU/bash-only syntax such as `find -printf`, `grep -P`, `[[ ... ]]`, `source`, or process substitution.
        - Do not append guessed success, stdout, file contents, or final summaries after the `iexa_alpine` block.
        - Keep visible text before the block empty or one short progress sentence.
        [/Local Alpine missing tool correction]
        """
        appendSystemInstruction(instruction, marker: "[Local Alpine missing tool correction]", to: &messages)
    }

    private static func appendLocalAlpineFinalSummaryInstruction(to messages: inout [[String: Any]]) {
        let instruction = """
        [Local Alpine final summary]
        The latest Local Alpine message above is a real command execution result. Do not emit `iexa_alpine` in this turn.
        Reply to the user in normal language only.
        Summarize the completed operation concisely:
        - For inspection/listing commands, state the concrete result the user asked for.
        - For script/project commands, say what ran, whether it succeeded, and the key output.
        - If files were created or changed, mention their paths.
        - If the command failed, explain the immediate error and the next fix path, but do not run another command until the user asks.
        Keep it short and based only on the real Local Alpine output.
        Always output at least one visible sentence. Do not output JSON, code fences, tool blocks, or protocol tags.
        [/Local Alpine final summary]
        """
        appendSystemInstruction(instruction, marker: "[Local Alpine final summary]", to: &messages)
    }

    private static func modelCapabilitySystemContext(model: AIModel?, modelId: String?) -> String? {
        let resolvedModelId = (modelId ?? model?.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard model != nil || !resolvedModelId.isEmpty else { return nil }

        let capability = model?.resolvedCapabilities
        let contextLength = LocalModelCapabilityRegistry.contextLength(for: model, modelId: resolvedModelId)
        let input = capability?.inputModalities.sorted().joined(separator: ", ") ?? "unknown"
        let output = capability?.outputModalities.sorted().joined(separator: ", ") ?? "unknown"
        let endpointTypes = capability?.endpointTypes.sorted().joined(separator: ", ") ?? ""

        var lines = [
            "[Current model capability]",
            "model_id: \(resolvedModelId.isEmpty ? model?.id ?? "unknown" : resolvedModelId)"
        ]
        if let name = model?.name, !name.isEmpty {
            lines.append("model_name: \(name)")
        }
        if let contextLength, contextLength > 0 {
            lines.append("context_window_tokens: \(contextLength)")
        }
        lines.append("input_modalities: \(input)")
        lines.append("output_modalities: \(output)")
        if !endpointTypes.isEmpty {
            lines.append("endpoint_types: \(endpointTypes)")
        }
        if let model {
            lines.append("supports_image_input: \(model.supportsImageInput)")
            lines.append("supports_image_generation: \(model.supportsImageGeneration)")
            lines.append("supports_reasoning: \(model.supportsReasoning)")
            lines.append("supports_tool_calling: \(model.supportsToolCalling)")
            lines.append("supports_structured_output: \(model.supportsStructuredOutput)")
            if !model.tags.isEmpty {
                lines.append("tags: \(model.tags.joined(separator: ", "))")
            }
        }
        lines.append("Use this capability data when deciding whether a user request should use chat, image generation, attachments, Local Alpine, or a different model.")
        lines.append("[/Current model capability]")
        return lines.joined(separator: "\n")
    }

    private static func localAlpineFinalSummaryVisibleContent(from content: String) -> String {
        let visible = LocalAlpineAgentService.visibleContent(from: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible
    }

    private func updateAssistantMessage(
        id: String, content: String, isStreaming: Bool,
        sources: [ChatSourceReference]? = nil,
        statusHistory: [ChatStatusUpdate]? = nil,
        error: ChatMessageError? = nil
    ) {
        let showInlineImageReceiveState = isStreaming
            && Self.shouldShowInlineImageReceiveState(for: content)
        let displayContent = showInlineImageReceiveState
            ? ""
            : Self.cleanedProviderCitationArtifacts(content)
        let safeDisplayContent = showInlineImageReceiveState
            ? ""
            : Self.safeAssistantDisplayContent(displayContent)
        let shouldHandleLocalAlpineDisplay = terminalEnabled && selectedTerminalIsLocalAlpine
        let visibleAlpineDisplayContent: String? = {
            guard shouldHandleLocalAlpineDisplay else { return nil }
            var visible = LocalAlpineAgentService.visibleContent(from: safeDisplayContent)
            if displayContent.localizedCaseInsensitiveContains("iexa_workspace")
                || visible.localizedCaseInsensitiveContains("iexa_workspace") {
                let workspaceVisible = LocalWorkspaceAgentService.visibleContent(from: visible)
                visible = workspaceVisible == "正在执行本地工作区操作..."
                    ? "正在改用本地执行..."
                    : workspaceVisible
            }
            return isStreaming
                ? Self.localAlpineDisplayContentForStreaming(visible, raw: safeDisplayContent)
                : visible
        }()
        let baseRenderedDisplayContent = visibleAlpineDisplayContent ?? safeDisplayContent
        let localAlpineInstructionDetected = shouldHandleLocalAlpineDisplay
            && (
                Self.contentContainsLocalAlpineInstruction(content)
                    || Self.contentContainsLocalAlpineInstruction(displayContent)
            )
        let localAlpinePromptLeakDetected = shouldHandleLocalAlpineDisplay
            && (
                Self.containsInternalPromptLeak(content)
                    || Self.containsInternalPromptLeak(displayContent)
                    || Self.containsInternalPromptLeak(baseRenderedDisplayContent)
            )
        let localAlpineDisplayIsHidden = shouldHandleLocalAlpineDisplay
            && visibleAlpineDisplayContent != nil
            && baseRenderedDisplayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (localAlpineInstructionDetected || localAlpinePromptLeakDetected)
        let renderedDisplayContent = (localAlpinePromptLeakDetected || localAlpineDisplayIsHidden)
            ? Self.localAlpinePromptLeakPlaceholder
            : baseRenderedDisplayContent
        let alpineInstructionIsHidden = localAlpineDisplayIsHidden
            || (shouldHandleLocalAlpineDisplay && localAlpinePromptLeakDetected)
        let effectiveStatusHistory = statusHistory ?? (alpineInstructionIsHidden ? [
            ChatStatusUpdate(
                action: "local_alpine_agent",
                description: isStreaming ? "正在准备执行本地命令..." : "已决定继续执行下一步",
                done: isStreaming ? false : true,
                occurredAt: .now
            )
        ] : nil)
        // Tool execution must see the raw assistant content; display cleanup can rewrite spaces inside JSON strings.
        var completedAssistantContentForAgent: String?
        var completedAssistantDisplayContent: String?

        if isStreaming && streamingStore.streamingMessageId == id {
            // ── STREAMING PATH ──
            // Route content to the isolated StreamingContentStore.
            // This avoids mutating conversation.messages on every token,
            // which would invalidate ALL message views via @Observable.
            streamingStore.updateContent(content, displayContent: renderedDisplayContent)
            if let sources { streamingStore.appendSources(sources) }
            if let statusHistory = effectiveStatusHistory {
                for s in statusHistory { streamingStore.appendStatus(s) }
            }
            if let error { streamingStore.setError(error) }
        } else {
            // ── COMPLETION / ERROR PATH ──
            // Write final content back to conversation.messages ONCE.
            // If transitioning from streaming → done, also flush the store.
            guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }

            if !isStreaming && streamingStore.streamingMessageId == id {
                // Streaming just ended — flush store to conversation
                let result = streamingStore.endStreaming()
                let finalRawContent = content.isEmpty ? result.content : content
                let resolvedFinalContent = safeDisplayContent.isEmpty
                    ? Self.safeAssistantDisplayContent(result.content)
                    : safeDisplayContent
                let finalPromptLeakDetected = localAlpinePromptLeakDetected
                    || Self.containsInternalPromptLeak(finalRawContent)
                    || Self.containsInternalPromptLeak(resolvedFinalContent)
                let finalLocalAlpineInstructionDetected = localAlpineInstructionDetected
                    || Self.contentContainsLocalAlpineInstruction(finalRawContent)
                    || Self.contentContainsLocalAlpineInstruction(resolvedFinalContent)
                let finalVisibleAlpineContent = shouldHandleLocalAlpineDisplay
                    ? LocalAlpineAgentService.visibleContent(from: resolvedFinalContent)
                    : resolvedFinalContent
                let finalAlpineDisplayIsHidden = shouldHandleLocalAlpineDisplay
                    && finalVisibleAlpineContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (finalPromptLeakDetected || finalLocalAlpineInstructionDetected)
                let finalContent: String
                if finalPromptLeakDetected || finalAlpineDisplayIsHidden {
                    finalContent = Self.localAlpinePromptLeakPlaceholder
                } else if shouldHandleLocalAlpineDisplay {
                    finalContent = finalVisibleAlpineContent
                } else {
                    finalContent = resolvedFinalContent
                }
                let agentContent = finalRawContent
                let shouldHideToolParent = shouldHandleLocalAlpineDisplay
                    && finalLocalAlpineInstructionDetected
                conversation?.messages[index].content = finalContent
                conversation?.messages[index].isStreaming = false
                if shouldHideToolParent {
                    var metadata = conversation?.messages[index].metadata ?? [:]
                    metadata["iexa_local_alpine_hidden_tool_parent"] = "true"
                    conversation?.messages[index].metadata = metadata
                }
                attachInlineImages(from: finalRawContent, to: index)
                // Merge sources from store into message
                if !result.sources.isEmpty {
                    for source in result.sources {
                        if !conversation!.messages[index].sources.contains(where: {
                            ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
                        }) {
                            conversation?.messages[index].sources.append(source)
                        }
                    }
                }
                // Merge status history
                if !result.statusHistory.isEmpty {
                    conversation?.messages[index].statusHistory = result.statusHistory
                }
                if let storeError = result.error {
                    conversation?.messages[index].error = storeError
                }
                // ── CRITICAL: Write final content into the history tree node NOW ──
                // This is the ONLY correct place to do this. The flat messages list
                // (`conversation.messages`) only contains the ACTIVE branch. As soon as
                // the user edits this message, `rederiveMessages()` switches to the new
                // branch and this message disappears from the flat list. Any subsequent
                // `syncToServerViaTree()` call (which iterates the flat list) will never
                // see this node again and can't update it — causing the empty-content bug.
                // By writing to the tree node here (at the moment streaming completes,
                // while the message is still on the active branch), the node is permanently
                // up-to-date in the tree regardless of any future branch switches.
                if !finalContent.isEmpty {
                    conversation?.history.updateNode(id: id) { node in
                        node.content = finalContent
                        node.done = true
                        if !result.sources.isEmpty { node.sources = result.sources }
                        if !result.statusHistory.isEmpty { node.statusHistory = result.statusHistory }
                        if shouldHideToolParent {
                            var metadata = node.metadata ?? [:]
                            metadata["iexa_local_alpine_hidden_tool_parent"] = "true"
                            node.metadata = metadata
                        }
                    }
                }
                completedAssistantContentForAgent = agentContent
                completedAssistantDisplayContent = finalContent
            } else {
                // Normal non-streaming update (e.g., error before streaming started)
                conversation?.messages[index].content = renderedDisplayContent
                conversation?.messages[index].isStreaming = isStreaming
                if !isStreaming {
                    attachInlineImages(from: content, to: index)
                }
                // Also update tree node for non-streaming completions (e.g., error paths)
                if !isStreaming && !renderedDisplayContent.isEmpty {
                    conversation?.history.updateNode(id: id) { node in
                        node.content = renderedDisplayContent
                        node.done = true
                    }
                }
                if !isStreaming {
                    completedAssistantContentForAgent = content.isEmpty ? displayContent : content
                    completedAssistantDisplayContent = renderedDisplayContent
                }
            }
            if let sources { conversation?.messages[index].sources = sources }
            if let sources {
                conversation?.history.updateNode(id: id) { node in
                    node.sources = sources
                }
            }
            if let statusHistory = effectiveStatusHistory {
                conversation?.messages[index].statusHistory = statusHistory
                conversation?.history.updateNode(id: id) { node in
                    node.statusHistory = statusHistory
                }
            }
            if let error {
                conversation?.messages[index].error = error
                conversation?.history.updateNode(id: id) { node in
                    node.error = error
                }
            }
        }

        if shouldHandleLocalAlpineDisplay,
           completedAssistantContentForAgent != nil,
           let alpineDisplayContent = completedAssistantDisplayContent {
            let visibleAlpineContent = LocalAlpineAgentService.visibleContent(from: alpineDisplayContent)
            if visibleAlpineContent != alpineDisplayContent,
               let index = conversation?.messages.firstIndex(where: { $0.id == id }) {
                conversation?.messages[index].content = visibleAlpineContent
                conversation?.history.updateNode(id: id) { node in
                    node.content = visibleAlpineContent
                    node.done = true
                }
            }
        }

        if shouldHandleLocalAlpineDisplay,
           let workspaceContent = completedAssistantContentForAgent,
           workspaceContent.localizedCaseInsensitiveContains("iexa_workspace") {
            let workspaceDisplayContent = completedAssistantDisplayContent ?? displayContent
            var visibleWorkspaceContent = LocalWorkspaceAgentService.visibleContent(from: workspaceDisplayContent)
            if visibleWorkspaceContent == "正在执行本地工作区操作..." {
                visibleWorkspaceContent = "正在改用本地执行..."
            }
            if visibleWorkspaceContent != workspaceDisplayContent,
               let index = conversation?.messages.firstIndex(where: { $0.id == id }) {
                conversation?.messages[index].content = visibleWorkspaceContent
                conversation?.history.updateNode(id: id) { node in
                    node.content = visibleWorkspaceContent
                    node.done = true
                }
            }
        }

        if let workspaceContent = completedAssistantContentForAgent,
           workspaceContent.localizedCaseInsensitiveContains("iexa_workspace"),
           shouldExecuteLocalWorkspaceAgentForCurrentRequest() {
            let workspaceDisplayContent = completedAssistantDisplayContent ?? displayContent
            let visibleWorkspaceContent = LocalWorkspaceAgentService.visibleContent(from: workspaceDisplayContent)
            if visibleWorkspaceContent != workspaceDisplayContent,
               let index = conversation?.messages.firstIndex(where: { $0.id == id }) {
                conversation?.messages[index].content = visibleWorkspaceContent
                conversation?.history.updateNode(id: id) { node in
                    node.content = visibleWorkspaceContent
                    node.done = true
                }
            }
        }

        if let nativeToolContent = completedAssistantContentForAgent,
           LocalNativeToolService.containsNativeToolBlock(nativeToolContent) {
            let nativeDisplayContent = completedAssistantDisplayContent ?? displayContent
            let visibleNativeContent = LocalNativeToolService.visibleContent(from: nativeDisplayContent)
            if visibleNativeContent != nativeDisplayContent,
               let index = conversation?.messages.firstIndex(where: { $0.id == id }) {
                conversation?.messages[index].content = visibleNativeContent
                conversation?.history.updateNode(id: id) { node in
                    node.content = visibleNativeContent
                    node.done = true
                }
            }
        }

        // Extract and apply task list updates live from the streaming content.
        // Gate on a 100-char delta to avoid the O(n) string scan on every token.
        // The function also guards internally (only fires when the magic keywords are present),
        // so normal messages pay only the cheap length comparison.
        if displayContent.count - lastTaskExtractionLength >= 100 {
            lastTaskExtractionLength = displayContent.count
            extractAndApplyTasksFromContent(displayContent)
        }

        // Trigger streaming haptic feedback (throttled to ~10 Hz to avoid
        // overwhelming the Taptic Engine while still feeling responsive)
        if isStreaming && error == nil {
            triggerStreamingHaptic()
        }
        updateRunLiveActivity(
            id: id,
            content: displayContent,
            isStreaming: isStreaming,
            statusHistory: statusHistory,
            error: error
        )
        scheduleLocalConversationAutosave(immediate: !isStreaming || error != nil)

        if let completedAssistantContentForAgent {
            scheduleLocalNativeToolIfNeeded(messageId: id, content: completedAssistantContentForAgent, error: error)
            let didScheduleNativeTool = localNativeToolExecutedMessageIds.contains(id)
            let didScheduleLocalAlpineNativeTool = localAlpineNativeToolExecutedMessageIds.contains(id)
            let completedMessage = conversation?.messages.first(where: { $0.id == id })
            if !didScheduleNativeTool,
               !didScheduleLocalAlpineNativeTool,
               completedMessage.map(Self.isLocalAlpineAgentResult) != true,
               completedMessage?.metadata?["iexa_local_alpine_final_summary"] == nil {
                scheduleLocalAlpineAgentIfNeeded(messageId: id, content: completedAssistantContentForAgent, error: error)
                if localAlpineAgentExecutedMessageIds.contains(id) != true {
                    _ = scheduleLocalAlpineMissingToolCorrectionIfNeeded(
                        messageId: id,
                        content: completedAssistantContentForAgent,
                        error: error
                    )
                }
            }
            if completedMessage.map(Self.isLocalWorkspaceAgentResult) != true {
                scheduleLocalWorkspaceAgentIfNeeded(messageId: id, content: completedAssistantContentForAgent, error: error)
            }
        }
    }

    private static func cleanedProviderCitationArtifacts(_ text: String) -> String {
        cleanedInternalPromptArtifacts(
            StreamingMarkdownView.removeProviderCitationArtifacts(from: text)
        )
    }

    private static func safeAssistantDisplayContent(_ text: String) -> String {
        let withoutLocalToolEcho = cleanedLocalAlpineMissingToolEchoes(text)
        if shouldShowInlineImageReceiveState(for: withoutLocalToolEcho) {
            return cleanedAssistantInlineImagePayloads(withoutLocalToolEcho)
        }
        guard withoutLocalToolEcho.range(of: "data:image/", options: .caseInsensitive) != nil
            || withoutLocalToolEcho.range(of: "image:data/", options: .caseInsensitive) != nil
            || withoutLocalToolEcho.range(of: "data:video/", options: .caseInsensitive) != nil
            || withoutLocalToolEcho.range(of: "data:audio/", options: .caseInsensitive) != nil
            || withoutLocalToolEcho.range(of: "base64", options: .caseInsensitive) != nil else {
            return withoutLocalToolEcho
        }
        return transformProseOutsideFencedCode(in: withoutLocalToolEcho) { prose in
            InlineDataPayloadSanitizer.sanitizedDisplayText(
                cleanedAssistantInlineImagePayloads(prose)
            )
        }
    }

    private static func shouldShowInlineImageReceiveState(for text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("data:image/")
            || lower.contains("image:data/")
            || lower.contains("data:imag")
            || lower.contains("image:data")
            || (lower.contains("![") && lower.contains("](data:"))
            || (lower.contains("<img") && lower.contains("src=") && lower.contains("data:")) {
            return true
        }
        guard text.utf8.count > 2_048 else { return false }
        return lower.contains("b64_json")
            || lower.contains("image_base64")
    }

    private static func cleanedLocalAlpineMissingToolEchoes(_ text: String) -> String {
        guard text.range(of: "iexa_alpine", options: .caseInsensitive) != nil else { return text }
        var cleaned = text.replacingOccurrences(
            of: #"(?i)(?:\s*tool\s+iexa_alpine\s+does\s+not\s+exists?\.?){1,}"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)\biexa_alpine\s+does\s+not\s+exists?\.?"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^\s*[^。\n.!?]*\biexa_alpine\b[^。\n.!?]*(?:cannot|can't|can\s+not|do\s+not|don't|unable\s+to)\s+(?:call|invoke|use|access|execute)[^。\n.!?]*[。.!?]*\s*"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^\s*[^。\n.!?]*\biexa_alpine\b[^。\n.!?]*(?:not\s+available|unavailable|unsupported|unknown\s+tool)[^。\n.!?]*[。.!?]*\s*"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^\s*[^。\n.!?]*`?iexa_alpine`?[^。\n.!?]*(?:工具不存在|不存在|不可用|无法调用|不能调用|不支持|未知工具)[^。\n.!?]*[。.!?]*\s*"#,
            with: "\n",
            options: .regularExpression
        )
        guard cleaned != text else { return text }
        cleaned = cleaned
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? Self.localAlpinePromptLeakPlaceholder : cleaned
    }

    private static func localAlpineDisplayContentForStreaming(_ visible: String, raw: String) -> String {
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.contentContainsLocalAlpineInstruction(raw) {
            return ""
        }
        let lower = trimmed.lowercased()
        let deferredMarkers = [
            "请继续执行", "我不能再凭印象猜", "继续执行目录查询",
            "不能直接执行", "无法直接执行", "请手动", "手动运行",
            "please continue", "run manually", "copy and paste"
        ]
        if deferredMarkers.contains(where: { lower.contains($0.lowercased()) }) {
            return ""
        }
        return visible
    }

    private static let localAlpinePromptLeakPlaceholder = "正在准备本地执行，结果会自动回来。"

    private static func containsInternalPromptLeak(_ text: String) -> Bool {
        let normalized = text.lowercased()
        guard normalized.contains("local alpine")
            || normalized.contains("iexa_alpine")
            || normalized.contains("[current model capability]") else {
            return false
        }

        let strongMarkers = [
            "[local alpine tool protocol]",
            "[/local alpine tool protocol]",
            "[local alpine client tool registry]",
            "[/local alpine client tool registry]",
            "[local alpine execution state]",
            "[/local alpine execution state]",
            "[local alpine observation]",
            "[/local alpine observation]",
            "[local alpine continuation]",
            "[/local alpine continuation]",
            "[local alpine missing tool correction]",
            "[/local alpine missing tool correction]",
            "[current model capability]",
            "[/current model capability]",
            "structured json keys:",
            "host executes the block after your message",
            "this is not provider/native function-calling",
            "pure prose means final answer",
            "call exactly one fenced markdown block",
            "read the next observation before continuing",
            "controller_verdict"
        ]
        return strongMarkers.contains { normalized.contains($0) }
    }

    private static func cleanedInternalPromptArtifacts(_ text: String) -> String {
        var cleaned = text
        let blockNames = [
            "Current model capability",
            "Local Alpine tool protocol",
            "Local Alpine client tool registry",
            "Local Alpine execution state",
            "Local Alpine observation",
            "Local Alpine continuation",
            "Local Alpine missing tool correction",
            "Local Alpine final summary",
            "Local native tool result"
        ]
        for name in blockNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let pattern = #"(?is)\[\s*\#(escaped)\s*\][\s\S]*?\[\s*/\s*\#(escaped)\s*\]"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                    withTemplate: ""
                )
            }
        }
        if cleaned != text {
            cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private func attachInlineImages(from rawContent: String, to messageIndex: Int) {
        guard conversation?.messages.indices.contains(messageIndex) == true else { return }

        let extractedImages = Self.extractInlineImageReferences(from: rawContent)
        var merged = conversation?.messages[messageIndex].files ?? []
        var appended = false
        for image in extractedImages {
            if !merged.contains(where: { $0.url == image.url || $0.displayURL == image.displayURL }) {
                merged.append(image)
                appended = true
            }
        }
        if extractedImages.isEmpty,
           Self.contentLikelyContainsExtractableImageReference(rawContent),
           !merged.contains(where: { Self.isImageFile($0) }) {
            merged.append(ChatMessageFile.generatedImageFailurePlaceholder(index: 1))
            appended = true
        }
        merged = Self.sanitizedMessageFiles(merged)

        let cleanedContent = Self.cleanedAssistantContentAfterImageExtraction(rawContent)
        let previousContent = conversation?.messages[messageIndex].content ?? ""
        let contentChanged = cleanedContent != previousContent
        guard appended || contentChanged else { return }

        if appended {
            conversation?.messages[messageIndex].files = merged
        }
        if contentChanged {
            conversation?.messages[messageIndex].content = cleanedContent
        }
        let messageId = conversation?.messages[messageIndex].id
        let messageContent = conversation?.messages[messageIndex].content
        let messageFiles = conversation?.messages[messageIndex].files ?? merged
        if let messageId {
            conversation?.history.updateNode(id: messageId) { node in
                node.content = messageContent ?? node.content
                node.files = messageFiles
                node.done = true
            }
        }
    }

    /// Fires a subtle haptic pulse during token streaming, throttled via
    /// the centralized `Haptics` service to avoid excessive motor usage.
    /// Uses the cached `streamingHapticsEnabled` flag (updated via
    /// UserDefaults.didChangeNotification) to avoid a per-token UserDefaults read.
    private func triggerStreamingHaptic() {
        guard streamingHapticsEnabled else { return }
        Haptics.streamingTick()
    }

    private func appendStatusUpdate(id: String, status: ChatStatusUpdate) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }

        // Deduplicate: update existing in-progress status with same action
        if let existingIdx = conversation?.messages[index].statusHistory.firstIndex(
            where: { $0.action == status.action && $0.done != true }
        ) {
            conversation?.messages[index].statusHistory[existingIdx] = status
        } else {
            // Don't add duplicate done statuses with the same action
            let isDuplicate = conversation?.messages[index].statusHistory.contains(where: {
                $0.action == status.action && $0.done == true && status.done == true
            }) ?? false
            if !isDuplicate {
                conversation?.messages[index].statusHistory.append(status)
            }
        }

        // Also write to the streaming store so the isolated streaming status
        // view sees the update in real-time (it reads from streamingStore,
        // not conversation.messages, during active streaming).
        if streamingStore.streamingMessageId == id && streamingStore.isActive {
            streamingStore.appendStatus(status)
        }
        if let description = status.description {
            Task {
                await RunLiveActivityService.shared.update(
                    id: id,
                    detail: description,
                    phase: status.done == true ? "完成" : "运行中",
                    progress: status.done == true ? 0.92 : nil,
                    isIndeterminate: status.done != true,
                    force: true
                )
            }
        }
    }

    private func appendFollowUps(id: String, followUps: [String]) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        // Use direct in-place mutation. The @Observable macro on ChatViewModel
        // tracks mutations to `conversation` itself — mutating through the
        // optional chain works because `conversation` is a var on an @Observable
        // class. Avoid full `conversation = conv` reassignment which can cause
        // "setting value during update" crashes if a navigation event (e.g.,
        // new chat) fires concurrently.
        conversation?.messages[index].followUps = followUps
    }

    private func applyLocalAlpineToolEvent(
        _ event: LocalAlpineToolEvent,
        messageId: String
    ) {
        guard conversation?.messages.contains(where: { $0.id == messageId }) == true else {
            clearLocalAlpineLiveToolState(for: messageId)
            return
        }

        if let activeRunId = localAlpineActiveRunIdsByMessageId[messageId],
           activeRunId != event.runId {
            return
        }
        localAlpineActiveRunIdsByMessageId[messageId] = event.runId

        var calls = localAlpinePendingToolCallsByMessageId[messageId]
            ?? localAlpineLiveToolCallsByMessageId[messageId]
            ?? []
        if let existingIndex = calls.firstIndex(where: { $0.id == event.call.id }) {
            calls[existingIndex] = event.call
        } else {
            calls.append(event.call)
        }
        localAlpinePendingToolCallsByMessageId[messageId] = calls

        let status = ChatStatusUpdate(
            action: "local_alpine_tool",
            description: event.call.statusDescription,
            done: event.call.phase == .result,
            occurredAt: .now
        )
        localAlpinePendingToolStatusByMessageId[messageId] = status

        flushLocalAlpineToolEventIfNeeded(messageId: messageId, immediate: event.call.phase == .start || event.call.phase == .result)

        Task {
            await RunLiveActivityService.shared.update(
                id: messageId,
                detail: event.call.statusDescription,
                phase: event.call.phase == .result ? "完成" : "运行中",
                progress: event.call.phase == .result ? 0.72 : nil,
                isIndeterminate: event.call.phase != .result,
                force: true
            )
        }
    }

    private func flushLocalAlpineToolEventIfNeeded(messageId: String, immediate: Bool) {
        if immediate {
            flushLocalAlpineToolEvent(messageId: messageId)
            return
        }

        let now = Date()
        if let lastFlush = localAlpineLastToolEventFlushAtByMessageId[messageId],
           now.timeIntervalSince(lastFlush) < localAlpineToolEventFlushInterval {
            scheduleLocalAlpineToolEventFlush(messageId: messageId)
            return
        }
        flushLocalAlpineToolEvent(messageId: messageId)
    }

    private func scheduleLocalAlpineToolEventFlush(messageId: String) {
        guard localAlpineToolEventFlushTasks[messageId] == nil else { return }
        let interval = localAlpineToolEventFlushInterval
        localAlpineToolEventFlushTasks[messageId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.localAlpineToolEventFlushTasks.removeValue(forKey: messageId)
                self?.flushLocalAlpineToolEvent(messageId: messageId)
            }
        }
    }

    private func flushLocalAlpineToolEvent(messageId: String) {
        localAlpineToolEventFlushTasks[messageId]?.cancel()
        localAlpineToolEventFlushTasks.removeValue(forKey: messageId)
        if let pendingCalls = localAlpinePendingToolCallsByMessageId.removeValue(forKey: messageId) {
            localAlpineLiveToolCallsByMessageId[messageId] = pendingCalls
        }
        if let pendingStatus = localAlpinePendingToolStatusByMessageId.removeValue(forKey: messageId) {
            localAlpineLastLiveToolStatusByMessageId[messageId] = pendingStatus
        }
        localAlpineLastToolEventFlushAtByMessageId[messageId] = Date()
    }

    /// Refreshes conversation metadata (title, sources, follow-ups, files) from server.
    private func refreshConversationMetadata(chatId: String, assistantMessageId: String) async throws {
        guard let manager else { return }
        let refreshed = try await manager.fetchConversation(id: chatId)

        // Update title
        if !refreshed.title.isEmpty && refreshed.title != "New Chat" {
            applyGeneratedConversationTitle(refreshed.title, chatId: chatId)
        }

        // Update sources, follow-ups, and files from refreshed assistant message.
        // Match by EXACT message ID only — do NOT fall back to last assistant.
        // The fallback previously caused the "duplicate stream" bug: when the
        // first message's completion task was still running its delayed polls
        // while the second message was streaming, the fallback would pick up
        // the second message's content and write it into the first message.
        let serverAssistant = refreshed.messages.first(where: { $0.id == assistantMessageId })
        if let serverAssistant {
            if !serverAssistant.sources.isEmpty {
                appendSources(id: assistantMessageId, sources: serverAssistant.sources)
            }
            if !serverAssistant.followUps.isEmpty {
                appendFollowUps(id: assistantMessageId, followUps: serverAssistant.followUps)
            }
            // Copy files from server (tool-generated images etc.)
            if !serverAssistant.files.isEmpty {
                if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    conversation?.messages[index].files = Self.preservingInlineImageFiles(
                        local: conversation?.messages[index].files ?? [],
                        incoming: serverAssistant.files
                    )
                }
            }
            // Also update content if server has different content (e.g., tool appended text,
            // server-side filter functions that add timing/performance stats after completion)
            if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                let localContent = conversation?.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let serverDisplayContent = Self.safeAssistantDisplayContent(
                    Self.cleanedProviderCitationArtifacts(serverAssistant.content)
                )
                let serverContent = serverDisplayContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawLocalContent = conversation?.messages[index].content ?? ""
                if !serverContent.isEmpty
                    && serverContent != localContent
                    && !CodeSourceFormatter.shouldPreserveLocalCodeIndentation(
                        local: rawLocalContent,
                        incoming: serverDisplayContent
                    ) {
                    conversation?.messages[index].content = serverDisplayContent
                }
                // Copy usage stats from server — the server stores them after
                // sendChatCompleted processes the chat. This is how app-sent
                // messages pick up usage data (the /api/chat/completed endpoint
                // doesn't return usage directly, but the stored message has it).
                if conversation?.messages[index].usage == nil,
                   let serverUsage = serverAssistant.usage, !serverUsage.isEmpty {
                    conversation?.messages[index].usage = serverUsage
                }
                // Copy embeds from server — never overwrite non-empty embeds
                if conversation?.messages[index].embeds.isEmpty == true,
                   !serverAssistant.embeds.isEmpty {
                    conversation?.messages[index].embeds = serverAssistant.embeds
                }
            }
        }
        // Sync tasks from server after a metadata refresh — catches tasks that
        // were created/updated during streaming and are now stored server-side.
        if !refreshed.tasks.isEmpty && refreshed.tasks != tasks {
            tasks = refreshed.tasks
            conversation?.tasks = refreshed.tasks
        }
    }

    /// Ensures the assistant message has its file references populated.
    ///
    /// This is a safety net for when the server's `files` array is empty but
    /// the message content contains tool call results with file references
    /// (e.g., image generation tool returned a file ID). This can happen when:
    /// - The app was backgrounded during generation and missed socket events
    /// - Network issues prevented the server metadata refresh from completing
    /// - The server hasn't yet populated the files array on its side
    ///
    /// Uses `ToolCallParser.extractFileReferences` to scan the `<details>` blocks
    /// in the message content for file IDs, then adds them to `message.files`.
    private func populateFilesFromToolResults(messageId: String) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let message = conversation!.messages[index]

        guard message.role == .assistant else { return }
        let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let extractedFiles = hasContent ? ToolCallParser.extractFileReferences(from: message.content) : []
        let extractedImages = hasContent ? Self.extractInlineImageReferences(from: message.content) : []
        var appendedFile = false
        var mergedFiles = message.files
        if !extractedFiles.isEmpty {
            logger.info("Extracted \(extractedFiles.count) file(s) from tool results for message \(messageId)")
            for file in extractedFiles {
                guard let url = file.url else { continue }
                if !mergedFiles.contains(where: { $0.url == url || $0.displayURL == url }) {
                    mergedFiles.append(file)
                    appendedFile = true
                }
            }
        }
        if !extractedImages.isEmpty {
            for image in extractedImages {
                if !mergedFiles.contains(where: { $0.url == image.url || $0.displayURL == image.displayURL }) {
                    mergedFiles.append(image)
                    appendedFile = true
                }
            }
        }
        if hasContent,
           extractedImages.isEmpty,
           Self.contentLikelyContainsExtractableImageReference(message.content),
           !mergedFiles.contains(where: { Self.isImageFile($0) }) {
            mergedFiles.append(ChatMessageFile.generatedImageFailurePlaceholder(index: 1))
            appendedFile = true
        }
        if appendedFile {
            conversation?.messages[index].files = Self.sanitizedMessageFiles(mergedFiles)
        }

        let cleanedContent = Self.cleanedAssistantContentAfterImageExtraction(message.content)
        if cleanedContent != message.content {
            conversation?.messages[index].content = cleanedContent
        }
        if appendedFile || cleanedContent != message.content {
            let files = conversation?.messages[index].files ?? []
            conversation?.history.updateNode(id: messageId) { node in
                node.content = cleanedContent
                node.files = files
                node.done = true
            }
        }
    }

    private func normalizeAssistantGeneratedMedia(messageId: String) {
        populateFilesFromToolResults(messageId: messageId)

        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let currentFiles = conversation!.messages[index].files
        let sanitizedFiles = Self.sanitizedMessageFiles(currentFiles)
        if sanitizedFiles != currentFiles {
            conversation?.messages[index].files = sanitizedFiles
            conversation?.history.updateNode(id: messageId) { node in
                node.files = sanitizedFiles
            }
        }
        let message = conversation!.messages[index]
        guard message.role == .assistant else { return }

        let hasRenderableImage = message.files.contains { file in
            Self.isImageFile(file)
                && (Self.isRenderableImageReference(file.displayURL)
                    || Self.isRenderableImageReference(file.url))
        }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, hasRenderableImage {
            conversation?.messages[index].content = ""
            conversation?.history.updateNode(id: messageId) { node in
                node.content = ""
                node.files = message.files
                node.done = true
            }
        }
    }

    private static func extractInlineImageReferences(from content: String) -> [ChatMessageFile] {
        let refs = extractImageReferenceStrings(from: content)
        var seen = Set<String>()
        var files: [ChatMessageFile] = []

        for rawRef in refs {
            let ref = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ref.isEmpty, !seen.contains(ref) else { continue }
            seen.insert(ref)
            let contentType = imageContentType(for: ref)
            files.append(ChatMessageFile(
                type: "image",
                url: ref,
                name: imageFileName(for: ref, contentType: contentType),
                contentType: contentType,
                displayURL: ref
            ))
        }

        return files
    }

    private static func extractImageReferenceStrings(from content: String) -> [String] {
        var results: [String] = extractInlineDataImageDataURIs(from: content).compactMap {
            writeGeneratedImageToCache(dataURL: $0)
        }

        func addMatches(_ pattern: String, captureIndex: Int = 1) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let nsContent = content as NSString
            let range = NSRange(location: 0, length: nsContent.length)
            for match in regex.matches(in: content, range: range) where match.numberOfRanges > captureIndex {
                let value = nsContent.substring(with: match.range(at: captureIndex))
                results.append(value)
            }
        }

        if content.utf8.count <= 240_000 {
            addMatches(#"!?\[[^\]]*\]\(\s*(https?://[^)\s]+)(?:\s+["'][^)]*["'])?\s*\)"#)
            addMatches(#"<img[^>]+src=["'](https?://[^"']+)["']"#)
            addMatches(#"(?:"b64_json"|"base64"|"image_base64"|"imageBase64")\s*:\s*"([A-Za-z0-9+/=_\-\s]{128,})""#)
            addMatches(#"(?:"url"|"image_url"|"display_url"|"download_url"|"image")\s*:\s*"(https?:\\?/\\?/[^"]+)""#)
            addMatches(#"(https?://[^\s"'<>`)]+)"#)
        }

        let normalizedResults = results.compactMap { value -> String? in
            let trimmed = sanitizedImageReferenceCandidate(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDataImage = normalizedImageDataURI(trimmed)
            if let normalizedDataImage {
                guard let compact = compactImageDataURI(normalizedDataImage) else { return nil }
                return writeGeneratedImageToCache(dataURL: compact)
            }
            if trimmed.hasPrefix("file://") {
                return trimmed
            }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return isLikelyImageURL(trimmed) ? trimmed : nil
            }
            let compact = compactBase64Payload(trimmed)
            guard looksLikeBase64Image(compact) else { return nil }
            return writeGeneratedImageToCache(dataURL: "data:image/png;base64,\(compact)")
        }

        var seen = Set<String>()
        return normalizedResults.filter { seen.insert($0).inserted }
    }

    private static func extractInlineDataImageDataURIs(from content: String) -> [String] {
        guard content.range(of: "data:image/", options: .caseInsensitive) != nil
            || content.range(of: "image:data/", options: .caseInsensitive) != nil else {
            return []
        }

        var results: [String] = []
        var cursor = content.startIndex

        while cursor < content.endIndex, results.count < 4 {
            guard let markerRange = firstDataImageMarkerRange(in: content, from: cursor) else {
                break
            }
            guard let commaRange = content.range(
                of: ",",
                range: markerRange.upperBound..<content.endIndex
            ) else {
                break
            }

            let header = String(content[markerRange.lowerBound..<commaRange.lowerBound]).lowercased()
            guard header.contains(";base64") else {
                cursor = markerRange.upperBound
                continue
            }

            var payloadEnd = commaRange.upperBound
            var payloadLength = 0
            while payloadEnd < content.endIndex {
                let character = content[payloadEnd]
                guard isBase64PayloadCharacter(character) else { break }
                payloadLength += 1
                guard payloadLength <= 24_000_000 else { break }
                payloadEnd = content.index(after: payloadEnd)
            }
            guard payloadLength >= 128 else {
                cursor = payloadEnd
                continue
            }

            let rawURI = String(content[markerRange.lowerBound..<payloadEnd])
            if let compact = compactImageDataURI(rawURI) {
                results.append(compact)
            }
            cursor = payloadEnd
        }

        return results
    }

    private static func firstDataImageMarkerRange(in text: String, from start: String.Index) -> Range<String.Index>? {
        let markers = ["data:image/", "image:data/"]
        var best: Range<String.Index>?
        for marker in markers {
            guard let range = text.range(of: marker, options: .caseInsensitive, range: start..<text.endIndex) else {
                continue
            }
            if best == nil || range.lowerBound < best!.lowerBound {
                best = range
            }
        }
        return best
    }

    private static func compactBase64Payload(_ value: String) -> String {
        var compact = ""
        compact.reserveCapacity(min(value.count, 24_000_000))
        for character in value where !character.isWhitespace {
            guard isBase64PayloadCharacter(character) else { return value }
            compact.append(character)
        }
        return compact
    }

    private static func sanitizedImageReferenceCandidate(_ value: String) -> String {
        var candidate = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")

        let trailing = CharacterSet(charactersIn: ".,;:)]}\"'")
        while let scalar = candidate.unicodeScalars.last, trailing.contains(scalar) {
            candidate.removeLast()
        }
        return candidate
    }

    private static func normalizedImageDataURI(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:image/") {
            return trimmed
        }
        if trimmed.hasPrefix("image:data/") {
            return "data:image/" + String(trimmed.dropFirst("image:data/".count))
        }
        return nil
    }

    private static func looksLikeBase64Image(_ value: String) -> Bool {
        let compact = value
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 128,
              compact.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil else {
            return false
        }

        return compact.hasPrefix("/9j/")
            || compact.hasPrefix("iVBORw0KGgo")
            || compact.hasPrefix("R0lGOD")
            || compact.hasPrefix("UklGR")
    }

    private static func isLikelyImageURL(_ value: String) -> Bool {
        guard value.utf8.count <= 4_096 else { return false }
        guard let url = URL(string: value),
              let host = url.host?.lowercased() else { return false }
        let lower = value.lowercased()
        if lower.range(of: #"\.(png|jpe?g|webp|gif|bmp|avif|svg)(\?|$)"#, options: .regularExpression) != nil {
            return true
        }
        if lower.contains("data:image") || lower.contains("image/") {
            return true
        }
        let generatedImageHosts = [
            "assets.grok.com",
            "replicate.delivery",
            "fal.media"
        ]
        if generatedImageHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }
        if host.contains("blob.core.windows.net") || host.contains("oaidalle") {
            return true
        }
        let imageHosts = ["image", "img", "cdn", "asset", "media", "static", "file", "files"]
        if imageHosts.contains(where: { host.contains($0) }) {
            return true
        }
        let imagePathHints = ["/image", "/images", "/img-", "/generated", "/media", "/asset", "/assets", "/file", "/files"]
        return imagePathHints.contains(where: { lower.contains($0) })
    }

    private static func cleanedAssistantContentAfterImageExtraction(_ content: String) -> String {
        let cleaned = transformProseOutsideFencedCode(in: content) { prose in
            cleanedAssistantInlineImagePayloads(prose)
        }

        if contentLikelyContainsExtractableImageReference(content) {
            let startsLikeRawJSON = cleaned.hasPrefix("{") || cleaned.hasPrefix("[")
            let mostlyRequestJSON = startsLikeRawJSON
                && (cleaned.contains("\"prompt\"") || cleaned.contains("\"size\"") || cleaned.contains("\"model\""))
            if cleaned.isEmpty || mostlyRequestJSON {
                return ""
            }
            if cleaned.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
                return ""
            }
        }

        return cleaned
    }

    private static func contentLikelyContainsExtractableImageReference(_ content: String) -> Bool {
        content.range(of: "data:image/", options: .caseInsensitive) != nil
            || content.range(of: "image:data/", options: .caseInsensitive) != nil
            || content.range(of: "b64_json", options: .caseInsensitive) != nil
            || content.range(of: "image_base64", options: .caseInsensitive) != nil
            || content.range(of: "image_url", options: .caseInsensitive) != nil
            || content.range(of: "display_url", options: .caseInsensitive) != nil
            || content.range(of: "download_url", options: .caseInsensitive) != nil
    }

    private static func transformProseOutsideFencedCode(
        in text: String,
        transform: (String) -> String
    ) -> String {
        guard text.contains("```") else {
            return transform(text)
        }

        var result = ""
        var cursor = text.startIndex

        while let openRange = text.range(of: "```", range: cursor..<text.endIndex) {
            if cursor < openRange.lowerBound {
                result += transform(String(text[cursor..<openRange.lowerBound]))
            }

            let afterOpen = text[openRange.upperBound...]
            guard let newlineIdx = afterOpen.firstIndex(of: "\n") else {
                result += String(text[openRange.lowerBound..<text.endIndex])
                return result
            }

            let contentStart = afterOpen.index(after: newlineIdx)
            if let closeRange = findClosingFence(in: text[contentStart...], from: contentStart) {
                result += String(text[openRange.lowerBound..<closeRange.upperBound])
                cursor = closeRange.upperBound
            } else {
                result += String(text[openRange.lowerBound..<text.endIndex])
                return result
            }
        }

        if cursor < text.endIndex {
            result += transform(String(text[cursor..<text.endIndex]))
        }
        return result
    }

    private static func findClosingFence(
        in substring: Substring,
        from start: String.Index
    ) -> Range<String.Index>? {
        var searchStart = start
        while searchStart < substring.endIndex {
            guard let range = substring.range(of: "```", range: searchStart..<substring.endIndex) else {
                return nil
            }
            let linePrefix = substring[substring.startIndex..<range.lowerBound]
            if linePrefix.isEmpty || linePrefix.last == "\n" {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func cleanedAssistantInlineImagePayloads(_ content: String) -> String {
        var cleaned = InlineDataPayloadSanitizer.sanitizedDisplayText(content)
        cleaned = InlineDataPayloadSanitizer.removingHiddenPayloadArtifacts(from: cleaned)
        let patterns = [
            #"(?m)^\s*!?\[[^\]]*\]\(\s*$"#,
            #"!?\[[^\]]*\]\(\s*$"#,
            #"\!\[[^\]]*\]\(\s*https?://[^)\s]+(?:\s+["'][^)]*["'])?\s*\)"#,
            #"<img[^>]+src=["']https?://[^"']+["'][^>]*>"#,
            #"(?:"url"|"image_url"|"display_url"|"download_url"|"image")\s*:\s*"https?:\\?/\\?/[^"]+""#
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendSources(id: String, sources: [ChatSourceReference]) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        for source in sources {
            if !conversation!.messages[index].sources.contains(where: {
                ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
            }) {
                conversation?.messages[index].sources.append(source)
            }
        }
    }

    private func saveConversationToServer() async {
        guard let manager, let conversation else { return }
        // Skip server persistence for temporary chats
        guard !isTemporaryChat else { return }
        // Always sync messages to existing conversation — never create a new one.
        // The conversation is already created in sendMessage() when conversation == nil.
        // Calling createConversation again would produce a duplicate entry.
        do {
            try await manager.saveConversation(conversation)
        } catch {
            logger.error("Failed to save conversation: \(error.localizedDescription)")
        }

        // Notify history to refresh
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func persistLocalConversationIfNeeded() async {
        guard let manager, manager.usesLocalConversationStore else { return }
        guard !isTemporaryChat else { return }
        _ = snapshotActiveStreamingMessageToConversation()
        syncFlatMessagesToTreeNodes()
        guard var conversation else { return }
        conversation.updatedAt = Date()
        self.conversation = conversation
        do {
            try await manager.saveConversation(conversation)
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        } catch {
            logger.error("Failed to save local conversation: \(error.localizedDescription)")
        }
    }
}

// MARK: - Content Accumulator

/// Thread-safe token accumulator with immediate main-actor dispatch.
///
/// Accumulates token deltas from background socket/SSE callbacks into a
/// single string and dispatches every token to the main actor immediately,
/// giving smooth character-by-character streaming in the UI.
final class ContentAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _content: String = ""
    private nonisolated(unsafe) var _reasoningContent: String = ""
    private nonisolated(unsafe) var _reasoningDone: Bool = false
    private nonisolated(unsafe) var _onUpdate: (@MainActor @Sendable (_ content: String) -> Void)?

    /// Guards against flooding the main actor with redundant Tasks.
    /// When true, a Task is already queued and will read the latest content
    /// when it executes — no need to create another one.
    private nonisolated(unsafe) var _pendingUpdate: Bool = false

    /// Callback invoked on the main actor with the latest accumulated
    /// content. Set by the view model when socket handlers are registered.
    nonisolated var onUpdate: (@MainActor @Sendable (_ content: String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onUpdate
        }
        set {
            lock.lock()
            _onUpdate = newValue
            lock.unlock()
        }
    }

    nonisolated var content: String {
        lock.lock()
        let value = renderedContentLocked()
        lock.unlock()
        return value
    }

    nonisolated var bodyContent: String {
        lock.lock()
        let value = _content
        lock.unlock()
        return value
    }

    /// Clears the pending-update flag after the queued Task executes.
    /// Extracted as a synchronous nonisolated helper so NSLock is never
    /// acquired from an async context (avoids Swift 6 strict-concurrency warnings).
    nonisolated private func clearPendingFlag() {
        lock.lock()
        _pendingUpdate = false
        lock.unlock()
    }

    nonisolated func append(_ text: String) {
        lock.lock()
        if !_content.isEmpty, text == _content {
            lock.unlock()
            return
        } else if !_content.isEmpty, text.hasPrefix(_content) {
            // Some providers send cumulative content in a streaming field
            // (often as a final `message.content`) instead of a true delta.
            // Replacing prevents the completed answer from appearing twice.
            _content = text
        } else {
            _content += text
        }
        // Only enqueue a new MainActor Task if none is already in-flight.
        // The in-flight Task will read _content at execution time, so it will
        // always deliver the very latest accumulated text — even if many tokens
        // arrived while it was waiting for MainActor scheduling.
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        dispatchIfNeeded(needsDispatch, callback: callback)
    }

    nonisolated func appendReasoning(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        _reasoningDone = false
        if !_reasoningContent.isEmpty, trimmed == _reasoningContent {
            lock.unlock()
            return
        } else if !_reasoningContent.isEmpty, trimmed.hasPrefix(_reasoningContent) {
            // Some providers send cumulative reasoning instead of a true delta.
            _reasoningContent = trimmed
        } else {
            _reasoningContent += text
        }
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        dispatchIfNeeded(needsDispatch, callback: callback)
    }

    nonisolated func replace(_ text: String) {
        lock.lock()
        _content = text
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        dispatchIfNeeded(needsDispatch, callback: callback)
    }

    nonisolated func markReasoningDone() {
        lock.lock()
        guard !_reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lock.unlock()
            return
        }
        _reasoningDone = true
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        dispatchIfNeeded(needsDispatch, callback: callback)
    }

    private nonisolated func dispatchIfNeeded(
        _ needsDispatch: Bool,
        callback: (@MainActor @Sendable (_ content: String) -> Void)?
    ) {
        guard needsDispatch else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let latest = self.content
            callback?(latest)
            self.clearPendingFlag()
        }
    }

    private nonisolated func renderedContentLocked() -> String {
        let reasoning = _reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return _content }

        let escaped = Self.escapeReasoningHTML(reasoning)
        let block = """
        <details type="reasoning" done="\(_reasoningDone ? "true" : "false")"><summary>\(_reasoningDone ? "思考" : "思考中…")</summary>
        \(escaped)
        </details>
        """
        if _content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return block
        }
        return block + "\n\n" + _content
    }

    private nonisolated static func escapeReasoningHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
