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
    /// Posted after a response completes so app-wide token counters can accumulate
    /// across chats without resetting on new conversations.
    static let chatTokenUsageDidAccumulate = Notification.Name("chatTokenUsageDidAccumulate")
}

/// Manages state and logic for a single chat conversation.
/// Handles sending/streaming messages via Socket.IO, loading history, and model selection.
/// Instances are held by `ActiveChatStore` so they survive navigation transitions.
@MainActor @Observable
final class ChatViewModel {
    // MARK: - Published State

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
    var isStreaming: Bool = false
    var isLoadingConversation: Bool = false
    var isLoadingModels: Bool = false
    /// Tasks managed by the model's built-in task tools (create_tasks / update_task).
    /// Populated from the server on load and updated in real-time during streaming.
    var tasks: [ChatTask] = []
    var errorMessage: String?
    var inputText: String = ""
    var attachments: [ChatAttachment] = []
    var webSearchEnabled: Bool = false {
        didSet {
            guard !suppressBuiltinFeatureTracking else { return }
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
    /// Active transcription tasks keyed by attachment ID.
    /// Stored here so they survive navigation — the VM lives in ActiveChatStore
    /// and is never destroyed when the user switches chats.
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    /// The post-streaming completion task (chatCompleted + file polling + metadata refresh).
    /// Cancelled when a new message is sent so it doesn't overwrite newer messages.
    private var completionTask: Task<Void, Never>?
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
    private(set) var sessionId: String = UUID().uuidString
    private let logger = Logger(subsystem: "com.openui", category: "ChatViewModel")
    private let webLinkContextResolver = WebLinkContextResolver()
    private var webLinkContextsByMessageId: [String: String] = [:]
    private var webSearchContextsByMessageId: [String: String] = [:]
    private var hasFinishedStreaming = false
    /// Tracks the content length at the last `extractAndApplyTasksFromContent` call.
    /// Prevents the O(n) task-extraction scan from running on every single token;
    /// it only fires when the content has grown by ≥ 100 chars since the last scan.
    private var lastTaskExtractionLength: Int = 0
    /// Cached value of the "streamingHaptics" UserDefaults preference.
    /// Updated whenever UserDefaults.didChangeNotification fires so toggling in
    /// Settings takes effect immediately without a per-token UserDefaults read.
    private var streamingHapticsEnabled: Bool = true
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

    /// The current auth token for authenticated image requests (model avatars).
    var serverAuthToken: String? {
        manager?.apiClient.network.authToken
    }

    var messages: [ChatMessage] {
        conversation?.messages ?? []
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

    var selectedModel: AIModel? {
        guard let id = selectedModelId else { return nil }
        return availableModels.first { $0.id == id }
    }

    var canSend: Bool {
        !isStreaming
            && !attachments.contains(where: { $0.type == .audio && $0.isTranscribing })
            && !attachments.contains(where: { $0.isUploading && !canSendAttachmentWithoutCompletedUpload($0) })
            && !attachments.contains(where: { $0.uploadStatus == .error && !canSendAttachmentWithoutCompletedUpload($0) })
            && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
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
            || value.hasPrefix("file://")
            || value.hasPrefix("http://")
            || value.hasPrefix("https://") {
            return true
        }
        let lower = value.lowercased()
        return [".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".avif", ".svg"].contains { lower.contains($0) }
    }

    private static func preservingInlineImageFiles(
        local: [ChatMessageFile],
        incoming: [ChatMessageFile]
    ) -> [ChatMessageFile] {
        let localDisplayImages = local.filter { file in
            isImageFile(file)
                && (file.displayURL?.hasPrefix("data:image/") == true
                    || file.displayURL?.hasPrefix("file://") == true
                    || file.url?.hasPrefix("data:image/") == true)
        }
        guard !localDisplayImages.isEmpty else { return incoming }

        var merged = incoming
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
        files.compactMap { file in
            if isImageFile(file)
                && (file.url?.hasPrefix("data:image/") == true
                    || file.url?.hasPrefix("file://") == true) {
                return nil
            }
            var persistable = file
            persistable.displayURL = nil
            return persistable
        }
    }

    private func inlineImageDataURL(data: Data, fileName: String) -> String {
        let capped = FileAttachmentService.downsampleForUpload(data: data)
        return "data:image/jpeg;base64,\(capped.base64EncodedString())"
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

    private static func localAlpineExecutionStateSystemContext(from messages: [ChatMessage]) -> String? {
        let alpineMessages = messages.filter { isLocalAlpineAgentResult($0) }
        guard !alpineMessages.isEmpty else { return nil }

        let blocks = alpineMessages.suffix(4).map { message -> String in
            let metadata = message.metadata ?? [:]
            let status = message.statusHistory.last?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let state = message.isStreaming ? "running" : "completed"
            let command = metadata["iexa_local_alpine_display_command"]
                ?? metadata["iexa_local_alpine_command_preview"]
            let cwd = metadata["iexa_local_alpine_cwd"]
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)

            var lines = ["- state: \(state)"]
            if let status, !status.isEmpty {
                lines.append("  status: \(status)")
            }
            if let cwd, !cwd.isEmpty {
                lines.append("  cwd: \(cwd)")
            }
            if let command, !command.isEmpty {
                lines.append("  command/request:")
                lines.append(indentForSystemContext(clippedForSystemContext(command, maxCharacters: 2_000)))
            }
            if !content.isEmpty {
                lines.append(message.isStreaming ? "  partial output:" : "  result:")
                lines.append(indentForSystemContext(clippedForSystemContext(content, maxCharacters: 8_000)))
            }
            return lines.joined(separator: "\n")
        }

        return """
        [Local Alpine execution state]
        The iOS host app runs `iexa_alpine` blocks asynchronously. This state is real host-side execution state, even if the command block itself is no longer visible in chat.

        \(blocks.joined(separator: "\n\n"))

        Rules for this state:
        - If state is running, tell the user the Local Alpine command is still running or ask whether to stop it; do not apologize that no executable block was emitted.
        - If result output is present, answer from that output as the source of truth.
        - Do not emit a duplicate `iexa_alpine` block for the same request unless the user clearly asks to rerun or run a different command.
        [/Local Alpine execution state]
        """
    }

    private static func clippedForSystemContext(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n...（内容过长，已截断）"
    }

    private static func indentForSystemContext(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    private static func localAlpineCommandPreview(from content: String) -> String {
        let cleaned = content
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 1_000 else { return cleaned }
        return String(cleaned.prefix(1_000)) + "..."
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
            conversation = fetched
            // Populate tasks from the server conversation
            tasks = fetched.tasks
            // Always adopt the last-used model for existing chats.
            // Priority: last assistant message's model (the actual model used
            // most recently) > conversation-level model > fallback.
            // This ensures returning to a chat uses the model from the most
            // recent response, even if it was changed mid-conversation from
            // the web UI or another client.
            if let lastAssistantModel = fetched.messages.last(where: { $0.role == .assistant })?.model,
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
                                    followUps: localLast.followUps
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
            conversation = serverConversation
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
                        }
                        conversation?.history.nodes[id] = updated
                    }
                } else {
                    // New node from server — add directly
                    conversation?.history.nodes[id] = serverNode
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
        for (serverIdx, serverMsg) in serverMessages.enumerated() {
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

                if !skipContentUpdate && local.content != serverMsg.content {
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
                        let lastUser = self.conversation?.messages.last(where: { $0.role == .user && !Self.isLocalWorkspaceAgentResult($0) })
                        self.recordTokenUsageForCompletedTurn(
                            assistantMessageId: serverAssistant.id,
                            userText: lastUser?.content ?? "",
                            assistantText: serverAssistant.content,
                            userAttachments: [],
                            usage: serverAssistant.usage
                        )
                        await self.sendCompletionNotificationIfNeeded(content: serverAssistant.content)
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
                conversation?.title = newTitle
                if let chatId {
                    NotificationCenter.default.post(
                        name: .conversationTitleUpdated,
                        object: nil,
                        userInfo: ["conversationId": chatId, "title": newTitle]
                    )
                }
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
                if isReplace {
                    // Full content replacement (message, chat:message, replace, chat:completion fallback)
                    conversation?.messages[index].content = contentDelta
                } else {
                    // Delta/token append (chat:message:delta, chat:completion choices.delta)
                    conversation?.messages[index].content += contentDelta
                }
                conversation?.messages[index].isStreaming = true
                triggerStreamingHaptic()
            }

            // Also check for done signal within content events (chat:completion
            // can carry both content AND done:true in the same event)
            if type == "chat:completion", let payload, payload["done"] as? Bool == true {
                let finalContent = conversation?.messages.first(where: { $0.id == msgId })?.content ?? ""
                isExternallyStreaming = false
                isStreaming = false
                isSyncingExternalStream = false
                if let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                    conversation?.messages[index].isStreaming = false
                }
                normalizeAssistantGeneratedMedia(messageId: msgId)
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
                conversation?.messages.first(where: { $0.id == id })?.content
            } ?? ""
            isExternallyStreaming = false
            isStreaming = false
            isSyncingExternalStream = false
            if let msgId = messageId,
               let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                conversation?.messages[index].isStreaming = false
                normalizeAssistantGeneratedMedia(messageId: msgId)
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
                        self.conversation?.messages[localIdx].content = serverAssistant.content
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

        let normalizedLocalAlpineText = Self.normalizedLocalAlpineCommand(currentText)
        let shouldAutoUseLocalAlpine = shouldAutoRouteExplicitLocalAlpineCommand(normalizedLocalAlpineText)
            || Self.isExplicitLocalAlpineRequest(currentText)
        if shouldAutoUseLocalAlpine {
            selectedTerminalServer = .localAlpine
            terminalEnabled = true
        }
        if processedAttachments.isEmpty,
           shouldSendTextDirectlyToLocalAlpine(normalizedLocalAlpineText),
           (terminalEnabled && selectedTerminalIsLocalAlpine || shouldAutoUseLocalAlpine) {
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
        var inlineTextSnippets: [String] = []
        var fallbackUploadFailure: String?
        for attachment in currentAttachments {
            if isOpenAICompatibleProvider, let data = attachment.data, attachment.type == .image {
                let dataURL = attachment.displayDataURL ?? inlineImageDataURL(data: data, fileName: attachment.name)
                inlineImageFiles.append(ChatMessageFile(
                    type: "image",
                    url: dataURL,
                    name: attachment.name,
                    contentType: "image/jpeg",
                    displayURL: dataURL
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
                    inlineImageFiles.append(ChatMessageFile(
                        type: "image",
                        url: fileId,
                        name: attachment.name,
                        contentType: contentType,
                        displayURL: dataURL
                    ))
                }
            } else if let data = attachment.data, attachment.type == .image {
                let dataURL = inlineImageDataURL(data: data, fileName: attachment.name)
                inlineImageFiles.append(ChatMessageFile(
                    type: "image",
                    url: dataURL,
                    name: attachment.name,
                    contentType: "image/jpeg"
                ))
            } else if let data = attachment.data, canSendAttachmentInline(attachment) {
                inlineTextSnippets.append(inlineTextContext(for: attachment, data: data))
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
                        inlineImageFiles.append(ChatMessageFile(
                            type: "image",
                            url: fileId,
                            name: attachment.name,
                            contentType: contentType,
                            displayURL: inlineImageDataURL(data: data, fileName: attachment.name)
                        ))
                    }
                } catch {
                    fallbackUploadFailure = error.localizedDescription
                    logger.error("Upload failed: \(error.localizedDescription)")
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

        let messageText: String = {
            guard !inlineTextSnippets.isEmpty else { return currentText }
            let joined = inlineTextSnippets.joined(separator: "\n\n")
            if currentText.isEmpty { return joined }
            return currentText + "\n\n" + joined
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
            let chatTitle = String(messageText.prefix(50))
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
            // Update active conversation ID so notifications are suppressed
            // while the user is viewing this newly created chat
            NotificationService.shared.activeConversationId = localId
        } else {
            conversation?.messages.append(userMessage)
        }

        // Assistant placeholder
        let assistantMessageId = UUID().uuidString
        let isDirectImageGenerationPlaceholder = isOpenAICompatibleProvider
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
        // ────────────────────────────────────────────────────────────────────

        await resolveWebLinkContextIfNeeded(
            userMessageId: userMessage.id,
            assistantMessageId: assistantMessageId,
            text: messageText
        )

        await resolveWebSearchContextIfNeeded(
            userMessageId: userMessage.id,
            assistantMessageId: assistantMessageId,
            text: messageText,
            modelId: modelId,
            hasAttachments: !currentAttachments.isEmpty
        )

        // Build API messages with image content fetched from server
        let imageCanvasInstructionMessageId = (imageGenerationEnabled
            || shouldUseDirectImageGeneration(modelId: modelId)
            || shouldPreferChatNativeImageGeneration(modelId: modelId))
            && Self.looksLikeImageGenerationRequest(messageText)
            ? userMessage.id
            : nil
        let apiMessages = await buildAPIMessagesAsync(
            imageCanvasInstructionMessageId: imageCanvasInstructionMessageId
        )
        let parentId = userMessage.id
        sessionId = UUID().uuidString
        let effectiveChatId = conversationId ?? conversation?.id

        // Cancel any previous message's completion task that may still be
        // running delayed polls — prevents it from overwriting this new
        // message's content via adoptServerMessages/refreshConversationMetadata.
        completionTask?.cancel()
        completionTask = nil

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
        await startRunLiveActivity(id: assistantMessageId, modelId: modelId, prompt: messageText)

        if isOpenAICompatibleProvider {
            streamingTask = Task { [weak self] in
                guard let self else { return }
                let acc = ContentAccumulator()
                var exactUsage: [String: Any]?

                do {
                    if self.shouldUseDirectVideoGeneration(modelId: modelId) {
                        let videoPrompt = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                            let imagePrompt = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let requestedCanvasSize = Self.requestedImageCanvasSize(from: imagePrompt)
                            let requestedImageSize = Self.imageEndpointSize(for: requestedCanvasSize)
                            let imagePromptForAPI = Self.promptWithImageSizeInstruction(
                                imagePrompt.isEmpty ? "Edit this image." : imagePrompt,
                                canvasSize: requestedCanvasSize,
                                endpointSize: requestedImageSize
                            )
                            await RunLiveActivityService.shared.update(
                                id: assistantMessageId,
                                title: "正在创建图片",
                                detail: imagePrompt.isEmpty ? "正在编辑图片" : imagePrompt,
                                phase: "生成",
                                progress: 0.35,
                                isIndeterminate: true,
                                force: true
                            )
                            let imageReference: String
                            if let editImage = self.firstEditableImage(from: currentAttachments) {
                                imageReference = try await self.runImageRequestWithRateLimitRetry {
                                    try await manager.editImage(
                                        prompt: imagePromptForAPI,
                                        model: modelId,
                                        imageData: editImage.data,
                                        fileName: editImage.fileName,
                                        size: requestedImageSize
                                    )
                                }
                            } else {
                                guard !imagePrompt.isEmpty else {
                                    throw APIError.unknown(
                                        underlying: NSError(
                                            domain: "ChatViewModel",
                                            code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "请输入图片生成提示词。"]
                                        )
                                    )
                                }
                                imageReference = try await self.runImageRequestWithRateLimitRetry {
                                    try await manager.generateImage(
                                        prompt: imagePromptForAPI,
                                        model: modelId,
                                        size: requestedImageSize
                                    )
                                }
                            }
                            let displayReference = await self.localDisplayImageReference(
                                from: imageReference,
                                canvasSize: requestedCanvasSize
                            ) ?? imageReference
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: "已生成图片",
                                isStreaming: false
                            )
                            self.attachGeneratedImageFile(
                                messageId: assistantMessageId,
                                imageReference: imageReference,
                                displayReference: displayReference
                            )
                            self.recordTokenUsageForCompletedTurn(
                                assistantMessageId: assistantMessageId,
                                userText: messageText,
                                assistantText: "已生成图片",
                                userAttachments: currentAttachments,
                                mediaKind: .image,
                                mediaCount: 1
                            )
                            self.hasFinishedStreaming = true
                            self.isStreaming = false
                            self.selfInitiatedStream = false
                            self.activeTaskId = nil
                            self.lastTaskExtractionLength = 0
                            await self.persistLocalConversationIfNeeded()
                            await self.sendCompletionNotificationIfNeeded(content: "已生成图片")
                            self.endBackgroundTask()
                            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                            return
                        } catch {
                            guard self.shouldFallbackToChatForImageGeneration(error) else { throw error }
                            self.logger.warning("Direct image endpoint failed; falling back to chat-native image output: \(error.localizedDescription)")
                        }
                    }

                    var request = ChatCompletionRequest(model: modelId, messages: apiMessages, stream: true)
                    if !fileRefs.isEmpty { request.files = fileRefs }
                    await self.populateCommonRequestFields(&request)
                    if !currentSkillIds.isEmpty { request.skillIds = currentSkillIds }
                    let sseStream = try await manager.sendMessageStreaming(request: request)

                    for try await event in sseStream {
                        if Task.isCancelled { break }

                        if let usage = event.usage, !usage.isEmpty {
                            exactUsage = usage
                        }

                        if let delta = event.contentDelta, !delta.isEmpty {
                            acc.append(delta)
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: acc.content,
                                isStreaming: true
                            )
                        }

                        if event.isFinished { break }
                    }
                } catch {
                    if !Task.isCancelled {
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
                                    self.updateAssistantMessage(id: assistantMessageId, content: serverAssistant.content, isStreaming: true)
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
                                        self.updateAssistantMessage(id: assistantMessageId, content: serverAssistant.content, isStreaming: false)
                                        self.hasFinishedStreaming = true
                                        self.isStreaming = false
                                        // Post-completion
                                        self.adoptServerMessages(serverConversation: refreshed)
                                        self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
                                        await manager.sendChatCompleted(chatId: chatId, messageId: assistantMessageId, model: modelId, sessionId: socketSessionId, messages: self.buildSimpleAPIMessages())
                                        try? await self.refreshConversationMetadata(chatId: chatId, assistantMessageId: assistantMessageId)
                                        self.normalizeAssistantGeneratedMedia(messageId: assistantMessageId)
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

                            // Content delta tokens
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(
                                    id: assistantMessageId,
                                    content: acc.content,
                                    isStreaming: true
                                )
                            }

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

    private func shouldAutoRouteExplicitLocalAlpineCommand(_ text: String) -> Bool {
        let lowercased = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercased.isEmpty else { return false }
        if Self.localAlpineDiagnosticCommand(for: lowercased) != nil { return true }
        let alpineTerms = [
            "alpine", "apk ", "/etc/alpine-release", "python3", "gcc", "vim", "node",
            "curl ", "uname", "whoami", "ls /", "pwd", "/mnt/iexa"
        ]
        return alpineTerms.contains { lowercased.contains($0) }
    }

    private static func isExplicitLocalAlpineRequest(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        let terms = [
            "在终端执行", "在终端运行", "用终端执行", "用终端运行",
            "执行命令", "运行命令", "帮我执行", "帮我运行",
            "写个脚本运行", "写一个脚本运行", "写个项目运行", "写一个项目运行",
            "创建项目并运行", "创建脚本并运行", "测试项目", "运行项目",
            "跑一下", "跑下", "执行一下", "运行一下",
            "local alpine", "alpine 执行", "alpine运行",
            "run command", "execute command", "run script", "run project"
        ]
        return terms.contains { normalized.contains($0) }
    }

    private static func fallbackLocalAlpineBlock(for text: String) -> String? {
        let command = normalizedLocalAlpineCommand(text)
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard isExplicitLocalAlpineRequest(text)
            || shouldSendRawTextDirectlyToLocalAlpine(command)
        else { return nil }

        let object: [String: Any] = [
            "iexa_alpine": [
                [
                    "command": command,
                    "cwd": "/mnt/iexa"
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return """
        ```iexa_alpine
        \(json)
        ```
        """
    }

    private static func shouldSendRawTextDirectlyToLocalAlpine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("\n") { return true }
        if trimmed.hasPrefix("$ ") { return true }
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("/") { return true }
        if trimmed.range(of: #"[;&|`$<>]"#, options: .regularExpression) != nil { return true }

        let command = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        let knownCommands: Set<String> = [
            "apk", "ash", "sh", "bash", "cat", "cd", "chmod", "chown", "cp", "date",
            "curl", "df", "du", "echo", "env", "find", "free", "gcc", "grep", "head", "id", "ls",
            "mkdir", "mv", "node", "npm", "ps", "pwd", "python", "python3", "rm", "rmdir",
            "sed", "sleep", "tail", "tar", "top", "touch", "uname", "vi", "vim", "wget",
            "which", "whoami"
        ]
        return knownCommands.contains(command)
    }

    private func sendDirectLocalAlpineCommand(_ rawCommand: String, modelId: String) async {
        let command = Self.normalizedLocalAlpineCommand(rawCommand)
        guard !command.isEmpty else { return }
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
            let chatTitle = String(userMessage.content.prefix(50))
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
            doneDescription = "本地 Alpine 输入已取消"
        } else if result.exitCode == 0 {
            doneDescription = "本地 Alpine 执行完成"
        } else {
            doneDescription = "本地 Alpine 执行结束，退出码 \(result.exitCode.map(String.init) ?? "unknown")"
        }
        updateAssistantMessage(
            id: assistantMessageId,
            content: output,
            isStreaming: false,
            statusHistory: [localAlpineStatus(description: doneDescription, done: true)]
        )
        conversation?.history.updateNode(id: assistantMessageId) { node in
            node.content = output
            node.done = true
            node.statusHistory = [localAlpineStatus(description: doneDescription, done: true)]
        }

        hasFinishedStreaming = true
        isStreaming = false
        selfInitiatedStream = false
        activeTaskId = nil
        lastTaskExtractionLength = 0

        await persistLocalConversationIfNeeded()
        endBackgroundTask()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func localAlpineInitialStatus(for command: String) -> ChatStatusUpdate {
        localAlpineStatus(description: localAlpineRunningDescription(for: command), done: false)
    }

    private func localAlpineRunningDescription(for command: String) -> String {
        let lowercased = command.lowercased()
        if lowercased.contains("apk add ")
            || lowercased.contains("apk upgrade")
            || lowercased.contains("apk fix") {
            return "正在安装 Alpine 软件包..."
        }
        if lowercased.contains("apk update") {
            return "正在更新 Alpine 软件源..."
        }
        if shouldLocalAlpineCheckDependencies(for: lowercased) {
            return "正在确认 Alpine 环境并执行命令..."
        }
        return "正在执行本地 Alpine 命令..."
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self,
                          let index = self.conversation?.messages.firstIndex(where: { $0.id == messageId }),
                          self.conversation?.messages[index].isStreaming == true else { return }
                    tick += 1
                    let description = self.localAlpineHeartbeatDescription(
                        command: command,
                        elapsed: Date().timeIntervalSince(startedAt),
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
            : "正在等待本地 Alpine 返回结果，已运行 \(seconds) 秒..."
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
        if let diagnosticCommand = localAlpineDiagnosticCommand(for: command.lowercased()) {
            return diagnosticCommand
        }
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
            command = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard diagnosticIntents.contains(where: { trimmed.contains($0) }) else { return nil }
        return """
        printf '== system ==\\n' && cat /etc/alpine-release 2>/dev/null && uname -a && id && pwd && printf '\\n== workspace ==\\n' && ls -la /mnt/iexa 2>/dev/null && printf '\\n== dns ==\\n' && cat /etc/resolv.conf 2>/dev/null && printf '\\n== tools ==\\n' && for x in sh ash busybox apk wget curl python3 node npm gcc g++ git vim; do printf '%-8s: ' "$x"; command -v "$x" || echo missing; done
        """
    }

    /// Stops the current streaming response by cancelling the server-side task
    /// via `/api/tasks/stop/{taskId}` and cleaning up local state.
    func stopStreaming() {
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

        // Reset the task list — the new regen branch starts with no tasks.
        tasks = []
        conversation?.tasks = []

        // 7. Sync to server via tree-based API before streaming.
        await syncToServerViaTree()

        // 8. Get the user message (parentId) for the API messages build.
        guard conversation?.messages.contains(where: { $0.role == .user }) == true else { return }
        let apiMessages = await buildAPIMessagesAsync()
        let effectiveChatId = conversationId ?? conversation?.id
        sessionId = UUID().uuidString

        // Reset streaming state
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true

        // Activate the isolated streaming store for the regenerated message
        streamingStore.beginStreaming(messageId: newAssistantId, modelId: modelId)

        // Cancel any previous subscriptions/timers
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        guard let socket = socketService else {
            updateAssistantMessage(id: newAssistantId, content: "No connection available.",
                                   isStreaming: false, error: ChatMessageError(content: "No socket"))
            isStreaming = false
            return
        }
        if !socket.isConnected {
            let ok = await socket.ensureConnected(timeout: 10.0)
            if !ok {
                updateAssistantMessage(
                    id: newAssistantId,
                    content: "Unable to connect. Check your connection.",
                    isStreaming: false,
                    error: ChatMessageError(content: "Connection failed"))
                isStreaming = false
                return
            }
        }

        let socketSessionId = socket.sid ?? sessionId

        // Get the user message node to build user_message dict for the request.
        // The parentId of the new assistant IS the user message ID.
        guard let userNode = conversation!.history.nodes[parentId] else { return }

        registerSocketHandlers(
            socket: socket, assistantMessageId: newAssistantId,
            modelId: modelId, socketSessionId: socketSessionId,
            effectiveChatId: effectiveChatId)

        let capturedNewAssistantId = newAssistantId
        let capturedParentId = parentId
        let capturedUserNode = userNode

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

                if request.isPipeModel {
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
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(
                                    id: capturedNewAssistantId, content: acc.content, isStreaming: true)
                            }
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
        let parentId = lastUser.id
        let effectiveChatId = conversationId ?? conversation?.id

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true

        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)

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
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                            }
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
                let payload = data["data"] as? [String: Any]
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    // Append directly — the accumulator dispatches to
                    // the main actor immediately on every token.
                    acc.append(content)
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
            let payload = data["data"] as? [String: Any]
            if type == "message", let content = payload?["content"] as? String, !content.isEmpty {
                acc.append(content)
                return
            }
            Task { @MainActor in
                self.handleChannelEvent(event, assistantMessageId: assistantMessageId, acc: acc)
            }
        }
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
                conversation?.title = newTitle
                logger.info("Title updated: \(newTitle)")
                // NOTE: We do NOT persist the title back to the server here.
                // The server generated this title via background_tasks and already
                // has it stored. Writing it back would be redundant and could race
                // with the server's own save.
                if let chatId = effectiveChatId {
                    // Notify the conversation list to update
                    NotificationCenter.default.post(
                        name: .conversationTitleUpdated,
                        object: nil,
                        userInfo: ["conversationId": chatId, "title": newTitle]
                    )
                }
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

        case "source", "citation":
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
                if !content.isEmpty {
                    acc.append(content)
                    updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                }

            case "chat:message", "replace":
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    acc.replace(content)
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
            if let c = delta["content"] as? String, !c.isEmpty {
                acc.append(c)
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
        }

        // Direct content field
        if let content = payload["content"] as? String, !content.isEmpty {
            acc.replace(content)
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
        if let rawSources = payload["sources"] as? [[String: Any]] ?? payload["citations"] as? [[String: Any]],
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

        if type == "message", let content = payload?["content"] as? String, !content.isEmpty {
            acc.append(content)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
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

    /// Polls the server for content when the done signal arrives with empty content.
    private func pollAndFinish(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        acc: ContentAccumulator,
        usage: [String: Any]? = nil
    ) async {
        guard let chatId = effectiveChatId, let manager else {
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
            cleanupStreaming()
            return
        }

        // Poll up to 5 times with 1s delay
        for attempt in 1...5 {
            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                if let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }),
                   !lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    acc.replace(lastAssistant.content)
                    logger.info("Server poll \(attempt): got content (\(lastAssistant.content.count) chars)")
                    break
                }
            } catch {
                logger.warning("Poll attempt \(attempt) failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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

        // NOTE: Do NOT call saveConversationToServer() here — same reason
        // as finishStreamingSuccessfully. The server's chatCompleted has the
        // authoritative state; pushing our local copy would corrupt tool results.
        cleanupStreaming()
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
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: lastAssistant.content, isStreaming: true)
                    }

                    // Server says streaming is done
                    if !lastAssistant.isStreaming && !serverContent.isEmpty {
                        self.logger.info("Recovery: server says done with \(serverContent.count) chars")
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: lastAssistant.content, isStreaming: false)
                        let doneContent = lastAssistant.content
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
        if defaults.contains("web_search") && isTruthy("web_search")
            && !userDisabledBuiltinFeatures.contains("web_search") {
            webSearchEnabled = true
        }
        if defaults.contains("image_generation") && isTruthy("image_generation")
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

    /// Whether the selected model supports the memory builtin tool.
    /// Controls visibility of the memory toggle in ToolsMenuSheet.
    var isMemoryAvailable: Bool {
        isOpenAICompatibleProvider || (selectedModel?.supportsMemory ?? false)
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
        webSearchEnabled = defaults.contains("web_search") && isTruthy("web_search")
        imageGenerationEnabled = defaults.contains("image_generation") && isTruthy("image_generation")
        codeInterpreterEnabled = defaults.contains("code_interpreter") && isTruthy("code_interpreter")
        suppressBuiltinFeatureTracking = false

        // Memory is an account-level preference stored server-side (ui.memory).
        // Fetch it once for all models (not just memory-capable ones) so the
        // value is cached for when a capable model is selected later.
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

    /// Fetches the user's memory preference from the server.
    ///
    /// Calls `GET /api/v1/users/user/settings` and reads `ui.memory`.
    /// This is the same endpoint the web UI writes to when the user
    /// toggles memory in Settings → Personalization. Fire-and-forget
    /// — failure just leaves `memoryEnabled` at its last known value.
    func fetchMemorySettingFromServer() async {
        if isOpenAICompatibleProvider, let manager {
            let enabled = await LocalMemoryStore.shared.isEnabled(serverURL: manager.baseURL)
            memoryEnabled = enabled
            activeChatStore?.cachedMemorySetting = enabled
            return
        }
        // Use session-level cache — avoids a redundant GET /api/v1/users/user/settings
        // on every model load/switch. Cache is cleared by ActiveChatStore.clear()
        // on logout or server switch, ensuring a fresh fetch each session.
        if let cached = activeChatStore?.cachedMemorySetting {
            memoryEnabled = cached
            logger.debug("Memory setting from cache: \(cached)")
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let settings = try await apiClient.getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let memory = ui["memory"] as? Bool {
                memoryEnabled = memory
                activeChatStore?.cachedMemorySetting = memory
                logger.debug("Memory setting fetched from server: \(memory)")
            }
        } catch {
            logger.debug("Failed to fetch memory setting: \(error.localizedDescription)")
        }
    }

    /// Persists the memory toggle state to the server user settings.
    ///
    /// Calls `POST /api/v1/users/user/settings/update` with `{"ui":{"memory":enabled}}`
    /// so the web UI and app stay in sync. Fire-and-forget — the toggle
    /// is already updated locally.
    func updateMemorySettingOnServer(enabled: Bool) {
        guard let apiClient = manager?.apiClient else { return }
        Task {
            do {
                if self.isOpenAICompatibleProvider {
                    await LocalMemoryStore.shared.setEnabled(enabled, serverURL: apiClient.baseURL)
                } else {
                    // Use merge helper so we only update `memory` without
                    // overwriting `models`, `pinnedModels`, or any other ui keys.
                    try await apiClient.mergeUserUISettings(["memory": enabled])
                }
                logger.debug("Memory setting saved to server: \(enabled)")
            } catch {
                logger.debug("Failed to save memory setting: \(error.localizedDescription)")
            }
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
        if let fc = selectedModel?.functionCallingMode, fc == "native" {
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
        let allToolIds = Array(selectedToolIds)
        if !allToolIds.isEmpty { request.toolIds = allToolIds }

        // Terminal ID if enabled
        if terminalEnabled, let terminalServer = selectedTerminalServer, !terminalServer.isLocalAlpine {
            request.terminalId = terminalServer.id
        }

        // Background tasks — respect both server config and user settings
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
        if webSearchEnabled { bgTasks["web_search"] = true }
        if !bgTasks.isEmpty { request.backgroundTasks = bgTasks }
    }

    /// Builds chat features by merging user toggles with the model's admin-configured
    /// default features. Matches the Iexa native server web client's `setDefaults()` + `getFeatures()`.
    ///
    /// Memory is based solely on the user's account setting (`memoryEnabled`), matching
    /// the web client which sends `features.memory` based on `$user.settings.ui.memory`
    /// without gating on per-model `builtinTools`. The server already knows which models
    /// support memory and ignores the flag for models that don't.
    private func buildChatFeatures() -> ChatCompletionRequest.ChatFeatures {
        var features = ChatCompletionRequest.ChatFeatures()
        let modelAllowsImageGeneration = selectedModel.map {
            Self.modelSupportsBuiltinFeature($0, key: "image_generation")
        } ?? false
        let modelNameSuggestsImageGeneration = selectedModelId.map {
            shouldUseDirectImageGeneration(modelId: $0) || shouldPreferChatNativeImageGeneration(modelId: $0)
        } ?? false
        let shouldEnableImageGeneration = modelNameSuggestsImageGeneration
            && (imageGenerationEnabled || modelAllowsImageGeneration)

        // Use ONLY the current toggle state. Server defaults are already applied
        // to these toggles at init time via syncUIWithModelDefaults() — which runs
        // on model load, model switch, and new-conversation. By the time we build
        // the request, the toggle reflects either the server default OR the user's
        // explicit override. Checking server defaults again here would ignore the
        // user toggling a feature OFF mid-chat (the original bug).
        if webSearchEnabled {
            features.webSearch = true
        }
        if shouldEnableImageGeneration {
            features.imageGeneration = true
        }
        if codeInterpreterEnabled {
            features.codeInterpreter = true
        }
        // Memory: send based on account-level setting only (matches web client).
        // No gate on selectedModel?.supportsMemory — the server decides per-model
        // whether to inject the memory tool; we just relay the user's preference.
        if memoryEnabled {
            features.memory = true
        }

        return features
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

    private func shouldUseDirectImageGeneration(modelId: String) -> Bool {
        let haystack = "\(modelId) \(selectedModel?.name ?? "") \(selectedModel?.tags.joined(separator: " ") ?? "")"
            .lowercased()
        let directEndpointTokens = [
            "gpt-image", "dall-e", "dalle", "flux", "sdxl",
            "stable-diffusion", "midjourney", "mj-", "minimax-image",
            "qwen-image", "imagen", "seedream", "jimeng", "kolors",
            "image-01", "image-02", "image-03", "image-generation"
        ]
        let chatModelTokens = [
            "gpt-5", "gpt-4", "gpt-3", "claude", "gemini", "qwen3",
            "qwen-plus", "qwen-max", "grok-4", "grok-3", "mini",
            "chat", "reasoning", "vision", "vl", "ocr"
        ]
        if directEndpointTokens.contains(where: { haystack.contains($0) }) {
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
            "minimax-image"
        ]
        if directEndpointModels.contains(where: { haystack.contains($0) }) {
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
        for attachment in attachments where attachment.type == .image {
            let outputFileName = Self.jpegFileName(for: attachment.name)
            if let data = attachment.data {
                let jpegData = FileAttachmentService.downsampleForUpload(data: data)
                return (jpegData.isEmpty ? data : jpegData, outputFileName)
            }
            if let dataURL = attachment.displayDataURL,
               let data = Self.imageData(fromDataURL: dataURL) {
                let jpegData = FileAttachmentService.downsampleForUpload(data: data)
                return (jpegData.isEmpty ? data : jpegData, outputFileName)
            }
        }
        return nil
    }

    private static func jpegFileName(for originalName: String) -> String {
        let base = (originalName as NSString).deletingPathExtension
        let safeBase = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "image" : base
        return safeBase + ".jpg"
    }

    private static func imageData(fromDataURL dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:image/"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return Data(base64Encoded: base64)
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
        if imageReference.hasPrefix("data:image/") {
            let resized = Self.resizedImageDataURL(from: imageReference, canvasSize: canvasSize) ?? imageReference
            return Self.writeGeneratedImageToCache(dataURL: resized)
        }
        return nil
    }

    private static func writeGeneratedImageToCache(dataURL: String) -> String? {
        guard let data = imageData(fromDataURL: dataURL) else { return nil }
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("iexa-generated-images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("\(UUID().uuidString).png")
            try data.write(to: fileURL, options: [.atomic])
            return fileURL.absoluteString
        } catch {
            return nil
        }
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
        let contentType = Self.imageContentType(for: displayReference)
        let safeURL = imageReference.hasPrefix("data:image/") ? displayReference : imageReference
        let fileName = Self.imageFileName(for: displayReference, contentType: contentType)
        let file = ChatMessageFile(
            type: "image",
            url: safeURL,
            name: fileName,
            contentType: contentType,
            displayURL: displayReference
        )
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

        NotificationCenter.default.post(
            name: .chatTokenUsageDidAccumulate,
            object: nil,
            userInfo: [
                "input": exactInput ?? estimatedInput,
                "output": exactOutput ?? estimatedOutput,
                "cached": exactCached ?? 0,
                "image": mediaTokens,
                "imageCount": mediaKind == .image ? mediaCount : 0,
                "videoCount": mediaKind == .video ? mediaCount : 0,
                "exact": (exactInput != nil || exactOutput != nil) ? 1 : 0,
                "estimated": (exactInput == nil && exactOutput == nil) ? 1 : 0
            ]
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
        return apiError.errorDescription ?? error.localizedDescription
    }

    private func localMemorySystemContext() async -> String? {
        guard isOpenAICompatibleProvider, memoryEnabled, let manager else { return nil }
        guard await LocalMemoryStore.shared.isEnabled(serverURL: manager.baseURL) else { return nil }
        let memories = await LocalMemoryStore.shared.list(serverURL: manager.baseURL)
        guard !memories.isEmpty else { return nil }
        let lines = memories.prefix(30).map { "- \($0.content)" }.joined(separator: "\n")
        return """
        User memories to consider across conversations:
        \(lines)
        """
    }

    private static func projectContinuitySystemContext() -> String {
        """
        When generating code projects, treat every file as part of one connected project:
        - Use exact relative file names and matching imports, links, entrypoints, and package/config files.
        - For HTML/CSS/JavaScript projects split across index.html, style.css, and script.js, the HTML must link ./style.css and ./script.js, and the CSS/JS must be written for that same UI.
        - For other languages, include the folder tree, entry file, dependency/config files, and imports so the project can run as a coherent whole instead of unrelated snippets.
        - If the user only asks to "show", "preview", "write a page", or wants a single-file demo, return normal code blocks with an inline preview-friendly HTML file. Do not create workspace operations unless the user explicitly asks to save/create/modify/read/search/list/delete local files or folders.

        Iexa has a local workspace agent. When the user asks you to create, modify, read, search, list, or delete local project files, include exactly one fenced block with language `iexa_workspace` containing JSON. Paths are relative to the app's Documents/Iexa Workspace folder and must never be absolute or use `..`.
        Do not claim that a local file operation has been completed unless you emit the `iexa_workspace` block for the app to execute. The app will append the real execution result; treat that appended result as the source of truth.
        Supported operations:
        ```iexa_workspace
        {
          "iexa_workspace": [
            {"action": "mkdir", "path": "demo"},
            {"action": "write", "path": "demo/index.html", "content": "<!doctype html>..."},
            {"action": "append", "path": "demo/README.md", "content": "\\nMore notes"},
            {"action": "read", "path": "demo/index.html"},
            {"action": "search", "path": "demo", "query": "button"},
            {"action": "list", "path": "demo"},
            {"action": "delete", "path": "demo/old.txt"}
          ]
        }
        ```
        For multi-file projects, write all connected files in the same workspace block so the UI, styles, scripts, imports, and dependencies stay linked.
        If the user asks to run/check/verify the project after writing files and Local Alpine terminal mode is available, also emit a bounded `iexa_alpine` block in the same answer for the concrete verification command.
        """
    }

    private static func workspaceGuardSystemContext() -> String {
        """
        Iexa can execute local workspace file operations, but only when the user explicitly asks to save/create/modify/read/search/list/delete files or folders in the local workspace.
        If the user asks to write, show, preview, or demonstrate a webpage/app/component/code without explicitly asking to save it into local files, return normal Markdown code blocks and any preview-friendly single-file code. Do not output an `iexa_workspace` block in that case.
        """
    }

    private static func localAlpineAgentSystemContext() -> String {
        """
        Iexa has an on-device Local Alpine Linux terminal. You can really operate that local Alpine environment for the user by emitting `iexa_alpine` blocks; do not tell the user that this chat lacks terminal/file-system execution when this instruction is present.

        Environment facts:
        - Shell: Alpine Linux ash/busybox style shell. Prefer POSIX sh syntax.
        - Default working directory: `/mnt/iexa`.
        - `/mnt/iexa` is the shared writable project directory. Create project files there.
        - Package manager: `apk`. Use `apk update` and `apk add --no-cache ...` when a missing dependency is needed.
        - Common tools may include or be installable as: python3/py3-pip, nodejs/npm, build-base, curl, wget, git, vim.
        - The execution is non-interactive. Do not rely on prompts, REPLs, `input()`, `read`, `scanf`, `cin`, `npm init` prompts, editors waiting for input, or long-running servers that never exit.

        Operational rules:
        - If the user asks you to run, execute, test, verify, inspect the environment, install packages, write a runnable script/project, crawl a website, or diagnose command output, use `iexa_alpine`.
        - Do not merely explain commands when the user wants action. Emit the block so the app executes it.
        - Do not claim that a command was executed, tested, installed, fixed, or that a file exists unless you emit the `iexa_alpine` block and then use the real output appended by the app as the source of truth.
        - For a project/script, write files with `cat > file <<'EOF' ... EOF`, then run a bounded verification command.
        - If the user wants to test Python `input()` / shell `read` with their own text, do not invent sample stdin and do not pipe a fixed `printf` value. Leave the input/read command unpiped; the app will pause, ask the user for stdin, feed that exact text to the program, and append the real output.
        - For unattended tests where the user did not ask to type input themselves, avoid interactive prompts by using constants, command-line args, environment variables, or an explicit `printf 'value\n' | python3 script.py`.
        - For Node/Python dependency installs, use bounded commands and print versions/errors. Avoid background daemons unless the user explicitly asks.
        - Keep commands safe and scoped to `/mnt/iexa`; do not use destructive commands outside that workspace.

        To execute commands, include exactly one fenced block with language `iexa_alpine` containing JSON. The app will run those commands locally on the device and append the real output. Do not output this block unless command execution is actually needed.

        Example:
        ```iexa_alpine
        {
          "iexa_alpine": [
            {"command": "cat /etc/alpine-release && uname -m && pwd", "cwd": "/mnt/iexa"},
            {"command": "cat > hello.py <<'EOF'\\nprint('hello from Iexa Alpine')\\nEOF\\npython3 hello.py", "cwd": "/mnt/iexa"}
          ]
        }
        ```
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
        return msgs
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

        let description: String
        if result.successCount > 0 {
            description = result.videos.isEmpty
                ? "已读取 \(result.successCount) 个链接"
                : "已解析 \(result.successCount) 个链接，找到 \(result.videos.count) 个 MP4"
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
        用户消息里包含链接。以下内容由 iOS 客户端在发送前读取，用来帮助你回答；请把它当作该链接的可用上下文。若包含 MP4 URL，请直接返还给用户并结合页面标题/描述概括视频内容。
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

        if let currentTimeContext = modelCurrentTimeContextPrompt(for: text) {
            webSearchContextsByMessageId[userMessageId] = currentTimeContext
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "web_search",
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
                    action: "web_search",
                    description: "联网搜索已可用",
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
                action: "web_search",
                description: "正在联网搜索...",
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
                queries = Self.mergeSearchQueries(
                    original: query,
                    generated: Self.fallbackWebSearchQueries(for: text, originalQuery: query),
                    limit: 4
                )
            }
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "web_search",
                    description: "正在联网搜索...",
                    done: false,
                    query: query,
                    queries: queries
                )
            )

            let result = try await ClientWebSearchService().search(queries: queries, originalQuery: query)
            guard result.loadedCount > 0 || !result.items.isEmpty || !result.docs.isEmpty else {
                appendStatusUpdate(
                    id: assistantMessageId,
                    status: ChatStatusUpdate(
                        action: "web_search",
                        description: "联网搜索没有返回结果，已按原问题发送",
                        done: true,
                        count: 0,
                        query: query,
                        queries: queries
                    )
                )
                return
            }
            let context = modelWebSearchContextPrompt(result: result, query: query, queries: queries)
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
                    action: "web_search",
                    description: result.loadedCount > 0
                        ? "已读取 \(result.loadedCount) 个网页"
                        : "已搜索 \(max(sources.count, result.items.count)) 个来源",
                    done: true,
                    urls: Array(urls),
                    items: result.items.prefix(6).map {
                        ChatStatusItem(title: $0.title, link: $0.link)
                    },
                    count: max(result.loadedCount, sources.count),
                    query: query,
                    queries: queries
                )
            )
        } catch {
            logger.warning("Web search failed: \(error.localizedDescription)")
            appendStatusUpdate(
                id: assistantMessageId,
                status: ChatStatusUpdate(
                    action: "web_search",
                    description: "联网搜索失败，已按原问题发送",
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
            return Self.mergeSearchQueries(original: query, generated: fallbackQueries, limit: 4)
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
            return Self.mergeSearchQueries(original: query, generated: generated + fallbackQueries, limit: 4)
        } catch {
            logger.debug("Search query generation failed: \(error.localizedDescription)")
            return Self.mergeSearchQueries(original: query, generated: fallbackQueries, limit: 4)
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

    private static func fallbackWebSearchQueries(for userText: String, originalQuery: String) -> [String] {
        let normalized = userText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
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

        if asksWeather {
            add("\(originalQuery) 实时天气")
            add("\(originalQuery) 今天 温度 降雨 风力")
            add("中国天气 \(originalQuery)")
        }

        if asksFuelPrice {
            add("\(originalQuery) 今日油价 92 95 98 柴油")
            add("\(originalQuery) 最新油价 \(today)")
        }

        if asksNews {
            add("\(originalQuery) 最新消息 \(today)")
            add("\(originalQuery) 今天 新闻 24小时")
        }

        if ["价格", "股价", "汇率", "版本", "发布", "release", "version", "price", "stock"].contains(where: { normalized.contains($0) }) {
            add("\(originalQuery) 最新 \(today)")
            add("\(originalQuery) 官方 最新")
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
        if webSearchEnabled { return true }

        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let explicitSearchTerms = [
            "联网搜索", "联网查", "上网搜索", "上网查", "网络搜索", "搜索一下", "搜一下",
            "帮我搜", "帮我查", "查一下", "查查看", "实时搜索", "实时查询",
            "最新", "今天", "今日", "现在", "目前", "刚刚", "新闻", "热搜",
            "能联网", "可以联网", "能搜索", "可以搜索", "联网吗", "搜索吗",
            "web search", "search the web", "internet search", "browse", "browser",
            "google", "bing", "latest", "today", "current", "news"
        ]
        return explicitSearchTerms.contains { normalized.contains($0) }
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
        Iexa 客户端已接入联网搜索。用户询问你是否能联网、能搜索、能查最新信息时，请明确回答：可以。当用户要求“搜索、联网查、最新、今天、实时、新闻”等内容时，客户端会先搜索网页，并把搜索结果附加到本轮消息里给你使用。不要声称你无法联网或无法实时搜索。
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

        [客户端联网搜索结果]
        查询：\(query)
        实际搜索词：
        \(queryLines)

        以下结果由 Iexa 客户端在发送本轮消息前联网搜索取得。请基于这些资料回答；涉及最新信息时优先使用这些搜索结果。回答要求：
        - 先直接给结论，再补充必要来源和时间。
        - 天气、油价、新闻、价格、版本等实时问题，必须说清楚信息日期/发布时间；资料不够精确就明确说“未在搜索结果中找到精确值”，不要编。
        - 引用来源时使用普通链接或来源标题，不要输出 cite turn0search 之类隐藏引用标记，也不要输出无法显示的方框字符。
        - 不要声称你无法联网。

        \(blocks.joined(separator: "\n\n"))
        [/客户端联网搜索结果]
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

    private func contentForModel(
        message: ChatMessage,
        includeImageCanvasInstruction: Bool = false
    ) -> String {
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

    private func buildAPIMessagesAsync(imageCanvasInstructionMessageId: String? = nil) async -> [[String: Any]] {
        guard let conversation else { return [] }
        var apiMessages: [[String: Any]] = []
        let asyncEffectiveSP: String? = {
            if let cp = conversation.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            return conversation.systemPrompt
        }()
        let memoryContext = await localMemorySystemContext()
        let workspaceContext = shouldExecuteLocalWorkspaceAgentForCurrentRequest()
            ? Self.projectContinuitySystemContext()
            : Self.workspaceGuardSystemContext()
        let alpineContext = selectedTerminalIsLocalAlpine && terminalEnabled
            ? Self.localAlpineAgentSystemContext()
            : nil
        let alpineExecutionStateContext = Self.localAlpineExecutionStateSystemContext(from: conversation.messages)
        let combinedSystemPrompt = [asyncEffectiveSP, workspaceContext, alpineContext, alpineExecutionStateContext, memoryContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !combinedSystemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": combinedSystemPrompt])
        }
        for message in conversation.messages where !message.isStreaming
            && !Self.isLocalWorkspaceAgentResult(message) {
            let modelContent = contentForModel(
                message: message,
                includeImageCanvasInstruction: message.id == imageCanvasInstructionMessageId
            )
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
                    "role": message.role.rawValue,
                    "content": contentArray
                ]

                if !nonImageFiles.isEmpty {
                    msgDict["files"] = nonImageFiles.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        guard !id.hasPrefix("local-binary:") else { return nil }
                        return ["type": "file", "id": id, "url": id]
                    }
                }

                apiMessages.append(msgDict)
            } else {
                var msgDict: [String: Any] = [
                    "role": message.role.rawValue,
                    "content": modelContent
                ]

                if !message.files.isEmpty {
                    msgDict["files"] = message.files.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        guard !id.hasPrefix("local-binary:") else { return nil }
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
        return apiMessages
    }

    private func parseStatusData(_ data: [String: Any]) -> ChatStatusUpdate {
        // Parse queries from various formats (array of strings, or single string)
        var queries: [String] = []
        if let qArray = data["queries"] as? [String] {
            queries = qArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else if let qStr = data["queries"] as? String, !qStr.isEmpty {
            queries = [qStr]
        }

        return ChatStatusUpdate(
            action: data["action"] as? String,
            description: data["description"] as? String,
            done: data["done"] as? Bool,
            hidden: data["hidden"] as? Bool,
            urls: (data["urls"] as? [String]) ?? [],
            occurredAt: .now,
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
        // Accumulate by unique key (URL or fallback index)
        var accumulated: [(key: String, url: String?, title: String?, snippet: String?, type: String?, meta: [String: String])] = []
        var seenKeys = Set<String>()
        var fallbackIdx = 0

        for entry in array {
            // Extract nested source object
            var baseSource = (entry["source"] as? [String: Any]) ?? [:]
            for key in ["id", "name", "title", "url", "link", "type"] {
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

    private func scheduleLocalAlpineAgentIfNeeded(messageId: String, content: String, error: ChatMessageError?) {
        guard error == nil else { return }
        guard terminalEnabled, selectedTerminalIsLocalAlpine else { return }
        guard let role = conversation?.messages.first(where: { $0.id == messageId })?.role, role == .assistant else { return }
        guard !localAlpineAgentExecutedMessageIds.contains(messageId) else { return }
        let userRequestedExecution = conversation?.messages.last(where: {
            $0.role == .user && !Self.isLocalAlpineAgentResult($0)
        }).map { Self.isExplicitLocalAlpineRequest($0.content) } ?? false

        let executableContent: String
        if content.localizedCaseInsensitiveContains("iexa_alpine") {
            executableContent = content
        } else if userRequestedExecution,
                  let userText = conversation?.messages.last(where: {
                      $0.role == .user && !Self.isLocalAlpineAgentResult($0)
                  })?.content,
                  let fallback = Self.fallbackLocalAlpineBlock(for: userText) {
            executableContent = fallback
        } else {
            return
        }

        localAlpineAgentExecutedMessageIds.insert(messageId)
        Task { [weak self] in
            await self?.executeLocalAlpineAgent(messageId: messageId, content: executableContent)
        }
    }

    private func shouldExecuteLocalWorkspaceAgentForCurrentRequest() -> Bool {
        guard let userText = conversation?.messages.last(where: {
            $0.role == .user && !Self.isLocalWorkspaceAgentResult($0)
        })?.content.lowercased() else { return false }

        let strongWorkspaceIntent = [
            "本地工作区", "工作区", "保存到", "保存为", "写入文件", "创建文件", "新建文件",
            "修改文件", "删除文件", "删除文件夹", "创建文件夹", "新建文件夹", "读取文件",
            "列出文件", "生成项目", "创建项目", "项目文件", "workspace", "save file",
            "write file", "create file", "modify file", "delete file", "mkdir", "append",
            "落地到本地", "落地项目", "直接写到", "帮我保存", "存到工作区", "写入工作区",
            "保存成文件", "搜索文件", "搜索内容", "查找文件", "查找内容", "搜文件",
            "全文搜索", "grep", "find in files", "search files", "search workspace",
            "create project", "save to workspace", "write to workspace"
        ].contains { userText.contains($0) }

        let previewOnlyIntent = [
            "给我看", "看看", "预览", "展示", "单文件", "不要创建", "不用创建",
            "不需要创建", "不要保存", "不用保存", "只看", "直接给代码", "写一个",
            "写个", "做一个给我看", "先看看", "先预览", "不要落地", "不要写入",
            "不要生成项目", "别创建文件", "show me", "preview", "single file",
            "don't create", "do not create", "just show", "only show"
        ].contains { userText.contains($0) }

        return strongWorkspaceIntent && !previewOnlyIntent
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
        guard conversation?.messages.contains(where: { $0.id == messageId }) == true else { return }

        let hasExecutableBlocks = await LocalAlpineAgentService.shared.hasExecutableBlocks(in: content)
        guard hasExecutableBlocks else { return }

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
            detail: initialStatus.description ?? "正在执行本地 Alpine 命令..."
        )
        let progressHeartbeat = startLocalAlpineProgressHeartbeat(
            messageId: resultMessageId,
            command: content
        )
        defer {
            progressHeartbeat.cancel()
            endBackgroundTask()
        }

        let result = await LocalAlpineAgentService.shared.executeBlocks(in: content) { request in
            await self.requestLocalAlpineInput(request)
        }
        guard conversation?.messages.contains(where: { $0.id == resultMessageId }) == true else { return }
        guard result.didExecute else {
            conversation?.messages.removeAll { $0.id == resultMessageId }
            conversation?.history.removeSubtree(rootId: resultMessageId)
            await persistLocalConversationIfNeeded()
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            return
        }

        let doneStatus = localAlpineStatus(
            description: result.interactiveRequest == nil ? "本地 Alpine 执行完成" : "本地 Alpine 输入已取消",
            done: true
        )
        updateAssistantMessage(
            id: resultMessageId,
            content: result.summary,
            isStreaming: false,
            statusHistory: [doneStatus]
        )
        conversation?.history.updateNode(id: resultMessageId) { node in
            node.content = result.summary
            node.done = true
            node.statusHistory = [doneStatus]
        }

        await persistLocalConversationIfNeeded()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    private func updateAssistantMessage(
        id: String, content: String, isStreaming: Bool,
        sources: [ChatSourceReference]? = nil,
        statusHistory: [ChatStatusUpdate]? = nil,
        error: ChatMessageError? = nil
    ) {
        let displayContent = Self.cleanedProviderCitationArtifacts(content)
        var completedAssistantContentForAgent: String?

        if isStreaming && streamingStore.streamingMessageId == id {
            // ── STREAMING PATH ──
            // Route content to the isolated StreamingContentStore.
            // This avoids mutating conversation.messages on every token,
            // which would invalidate ALL message views via @Observable.
            streamingStore.updateContent(displayContent)
            if let sources { streamingStore.appendSources(sources) }
            if let statusHistory {
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
                let finalContent = displayContent.isEmpty ? result.content : displayContent
                conversation?.messages[index].content = finalContent
                conversation?.messages[index].isStreaming = false
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
                    }
                }
                completedAssistantContentForAgent = finalContent
            } else {
                // Normal non-streaming update (e.g., error before streaming started)
                conversation?.messages[index].content = displayContent
                conversation?.messages[index].isStreaming = isStreaming
                // Also update tree node for non-streaming completions (e.g., error paths)
                if !isStreaming && !displayContent.isEmpty {
                    conversation?.history.updateNode(id: id) { node in
                        node.content = displayContent
                        node.done = true
                    }
                }
                if !isStreaming {
                    completedAssistantContentForAgent = displayContent
                }
            }
            if let sources { conversation?.messages[index].sources = sources }
            if let statusHistory { conversation?.messages[index].statusHistory = statusHistory }
            if let error { conversation?.messages[index].error = error }
        }

        if terminalEnabled, selectedTerminalIsLocalAlpine,
           let alpineContent = completedAssistantContentForAgent {
            let visibleAlpineContent = LocalAlpineAgentService.visibleContent(from: alpineContent)
            if visibleAlpineContent != alpineContent,
               let index = conversation?.messages.firstIndex(where: { $0.id == id }) {
                conversation?.messages[index].content = visibleAlpineContent
                conversation?.history.updateNode(id: id) { node in
                    node.content = visibleAlpineContent
                    node.done = true
                }
            }
        }

        if let workspaceContent = completedAssistantContentForAgent,
           workspaceContent.localizedCaseInsensitiveContains("iexa_workspace"),
           shouldExecuteLocalWorkspaceAgentForCurrentRequest() {
            let visibleWorkspaceContent = LocalWorkspaceAgentService.visibleContent(from: workspaceContent)
            if visibleWorkspaceContent != workspaceContent,
               let index = conversation?.messages.firstIndex(where: { $0.id == id }) {
                conversation?.messages[index].content = visibleWorkspaceContent
                conversation?.history.updateNode(id: id) { node in
                    node.content = visibleWorkspaceContent
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

        if let completedAssistantContentForAgent {
            if conversation?.messages.first(where: { $0.id == id }).map(Self.isLocalAlpineAgentResult) != true {
                scheduleLocalAlpineAgentIfNeeded(messageId: id, content: completedAssistantContentForAgent, error: error)
            }
            if conversation?.messages.first(where: { $0.id == id }).map(Self.isLocalWorkspaceAgentResult) != true {
                scheduleLocalWorkspaceAgentIfNeeded(messageId: id, content: completedAssistantContentForAgent, error: error)
            }
        }
    }

    private static func cleanedProviderCitationArtifacts(_ text: String) -> String {
        StreamingMarkdownView.removeProviderCitationArtifacts(from: text)
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

    /// Refreshes conversation metadata (title, sources, follow-ups, files) from server.
    private func refreshConversationMetadata(chatId: String, assistantMessageId: String) async throws {
        guard let manager else { return }
        let refreshed = try await manager.fetchConversation(id: chatId)

        // Update title
        if !refreshed.title.isEmpty && refreshed.title != "New Chat" {
            conversation?.title = refreshed.title
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
                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !serverContent.isEmpty && serverContent != localContent {
                    conversation?.messages[index].content = serverAssistant.content
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
        if !extractedFiles.isEmpty {
            logger.info("Extracted \(extractedFiles.count) file(s) from tool results for message \(messageId)")
            var merged = message.files
            for file in extractedFiles {
                guard let url = file.url else { continue }
                if !merged.contains(where: { $0.url == url || $0.displayURL == url }) {
                    merged.append(file)
                    appendedFile = true
                }
            }
            conversation?.messages[index].files = merged
        }
        if !extractedImages.isEmpty {
            var merged = conversation?.messages[index].files ?? message.files
            for image in extractedImages {
                if !merged.contains(where: { $0.url == image.url || $0.displayURL == image.displayURL }) {
                    merged.append(image)
                    appendedFile = true
                }
            }
            conversation?.messages[index].files = merged
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
        let message = conversation!.messages[index]
        guard message.role == .assistant else { return }

        let hasRenderableImage = message.files.contains { file in
            Self.isImageFile(file)
                && (Self.isRenderableImageReference(file.displayURL)
                    || Self.isRenderableImageReference(file.url))
        }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, hasRenderableImage {
            conversation?.messages[index].content = "已生成图片"
            conversation?.history.updateNode(id: messageId) { node in
                node.content = "已生成图片"
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
        var results: [String] = []
        func addMatches(_ pattern: String, captureIndex: Int = 1) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let nsContent = content as NSString
            let range = NSRange(location: 0, length: nsContent.length)
            for match in regex.matches(in: content, range: range) where match.numberOfRanges > captureIndex {
                let value = nsContent.substring(with: match.range(at: captureIndex))
                results.append(value)
            }
        }

        addMatches(#"!\[[^\]]*\]\((data:image/[^)\s]+)\)"#)
        addMatches(#"<img[^>]+src=["'](data:image/[^"']+)["']"#)
        addMatches(#"(data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_-]{128,})"#)
        addMatches(#"(?:"b64_json"|"base64"|"image_base64"|"imageBase64")\s*:\s*"([A-Za-z0-9+/=_-]{128,})""#)

        return results.compactMap { value -> String? in
            let trimmed = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            if trimmed.hasPrefix("data:image/") {
                return writeGeneratedImageToCache(dataURL: trimmed)
            }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return nil
            }
            guard looksLikeBase64Image(trimmed) else { return nil }
            return writeGeneratedImageToCache(dataURL: "data:image/png;base64,\(trimmed)")
        }
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
        guard let url = URL(string: value),
              let host = url.host?.lowercased() else { return false }
        let lower = value.lowercased()
        if lower.range(of: #"\.(png|jpe?g|webp|gif|bmp|avif|svg)(\?|$)"#, options: .regularExpression) != nil {
            return true
        }
        if lower.contains("data:image") || lower.contains("image/") {
            return true
        }
        if ["assets.grok.com"].contains(host) {
            return true
        }
        let imageHosts = ["image", "img", "cdn", "asset", "media", "static", "file", "files"]
        if imageHosts.contains(where: { host.contains($0) }) {
            return true
        }
        let imagePathHints = ["/image", "/images", "/generated", "/media", "/asset", "/assets", "/file", "/files"]
        return imagePathHints.contains(where: { lower.contains($0) })
    }

    private static func cleanedAssistantContentAfterImageExtraction(_ content: String) -> String {
        var cleaned = content
        let patterns = [
            #"!\[[^\]]*\]\(\s*data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{48,}(?:\s+[^)]*)?\)"#,
            #"!\[[^\]]*\]\(\s*data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{48,}"#,
            #"<img[^>]+src=["']data:image/[^"']+["'][^>]*>"#,
            #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{128,}"#,
            #"(?:"b64_json"|"base64"|"image_base64"|"imageBase64")\s*:\s*"[A-Za-z0-9+/=_-]{128,}""#
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !extractImageReferenceStrings(from: content).isEmpty {
            let startsLikeRawJSON = cleaned.hasPrefix("{") || cleaned.hasPrefix("[")
            let mostlyRequestJSON = startsLikeRawJSON
                && (cleaned.contains("\"prompt\"") || cleaned.contains("\"size\"") || cleaned.contains("\"model\""))
            if cleaned.isEmpty || mostlyRequestJSON {
                return "已生成图片"
            }
            if cleaned.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
                return "已生成图片"
            }
        }

        return cleaned
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
        guard let manager, manager.usesLocalConversationStore, let conversation else { return }
        guard !isTemporaryChat else { return }
        do {
            try await manager.saveConversation(conversation)
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
        _content += text
        // Only enqueue a new MainActor Task if none is already in-flight.
        // The in-flight Task will read _content at execution time, so it will
        // always deliver the very latest accumulated text — even if many tokens
        // arrived while it was waiting for MainActor scheduling.
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        guard needsDispatch else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Read the LATEST content — may include tokens that arrived
            // after append() returned but before this Task executed.
            let latest = self.content
            callback?(latest)
            // Clear the flag so the next token can enqueue a new Task.
            self.clearPendingFlag()
        }
    }

    nonisolated func replace(_ text: String) {
        lock.lock()
        _content = text
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        guard needsDispatch else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let latest = self.content
            callback?(latest)
            self.clearPendingFlag()
        }
    }
}
