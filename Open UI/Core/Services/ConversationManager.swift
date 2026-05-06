import Foundation
import os.log

/// Wraps `APIClient` calls for conversation lifecycle operations.
final class ConversationManager: @unchecked Sendable {
    let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "ConversationManager")
    private let localStore: LocalConversationStore

    var usesLocalConversationStore: Bool {
        apiClient.providerType != .openWebUI
    }

    init(apiClient: APIClient, localStore: LocalConversationStore = .shared) {
        self.apiClient = apiClient
        self.localStore = localStore
    }

    // MARK: - Fetch

    func fetchConversations(limit: Int? = nil, skip: Int? = nil) async throws -> [Conversation] {
        if usesLocalConversationStore {
            let all = await localStore.list(serverURL: apiClient.baseURL)
            let start = max(0, skip ?? 0)
            guard start < all.count else { return [] }
            if let limit {
                return Array(all[start..<min(all.count, start + limit)])
            }
            return Array(all[start...])
        }
        return try await apiClient.getConversations(limit: limit, skip: skip)
    }

    /// Fetches a single page of conversations by 1-based page number.
    /// Returns an empty array when no more pages exist.
    func fetchConversationsPage(page: Int, pinnedIds: Set<String>? = nil) async throws -> [Conversation] {
        if usesLocalConversationStore {
            let pageSize = 50
            let all = await localStore.list(serverURL: apiClient.baseURL)
            let start = max(0, (max(1, page) - 1) * pageSize)
            guard start < all.count else { return [] }
            return Array(all[start..<min(all.count, start + pageSize)])
        }
        return try await apiClient.getConversationsPage(page: page, pinnedIds: pinnedIds)
    }

    func fetchConversation(id: String) async throws -> Conversation {
        if usesLocalConversationStore {
            return try await localStore.get(id: id, serverURL: apiClient.baseURL)
        }
        return try await apiClient.getConversation(id: id)
    }

    func searchConversations(query: String) async throws -> [Conversation] {
        if usesLocalConversationStore {
            return await localStore.search(serverURL: apiClient.baseURL, query: query)
        }
        return try await apiClient.searchConversations(query: query)
    }

    // MARK: - Create

    func createConversation(
        title: String,
        messages: [ChatMessage] = [],
        model: String? = nil,
        systemPrompt: String? = nil,
        folderId: String? = nil
    ) async throws -> Conversation {
        if usesLocalConversationStore {
            var conversation = Conversation(
                title: title,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                folderId: folderId
            )
            conversation.history = APIClient.buildHistoryFromFlatMessages(messages)
            await localStore.upsert(conversation, serverURL: apiClient.baseURL)
            return conversation
        }
        return try await apiClient.createConversation(
            title: title,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            folderId: folderId
        )
    }

    // MARK: - Update

    func renameConversation(id: String, title: String) async throws {
        if usesLocalConversationStore {
            await localStore.rename(id: id, title: title, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.updateConversation(id: id, title: title)
    }

    func updateSystemPrompt(id: String, systemPrompt: String) async throws {
        if usesLocalConversationStore {
            var conversation = try await localStore.get(id: id, serverURL: apiClient.baseURL)
            conversation.systemPrompt = systemPrompt
            await localStore.upsert(conversation, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.updateConversation(id: id, systemPrompt: systemPrompt)
    }

    func saveConversation(_ conversation: Conversation) async throws {
        if usesLocalConversationStore {
            await localStore.upsert(conversation, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.syncConversationMessages(
            id: conversation.id,
            messages: conversation.messages,
            model: conversation.model,
            systemPrompt: conversation.systemPrompt,
            title: conversation.title
        )
    }

    /// Syncs conversation using the tree-based history directly.
    /// Preferred over `saveConversation` when the history tree is the source of truth.
    func syncConversationHistory(_ conversation: Conversation) async throws {
        if usesLocalConversationStore {
            await localStore.upsert(conversation, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.syncConversationHistory(
            id: conversation.id,
            history: conversation.history,
            model: conversation.model,
            systemPrompt: conversation.systemPrompt,
            chatParams: conversation.chatParams,
            title: conversation.title
        )
    }

    // MARK: - Delete

    func deleteConversation(id: String) async throws {
        if usesLocalConversationStore {
            await localStore.delete(id: id, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.deleteConversation(id: id)
    }

    func deleteAllConversations() async throws {
        if usesLocalConversationStore {
            await localStore.deleteAll(serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.deleteAllConversations()
    }

    // MARK: - Pin / Archive

    func pinConversation(id: String, pinned: Bool) async throws {
        if usesLocalConversationStore {
            await localStore.setPinned(id: id, pinned: pinned, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.pinConversation(id: id, pinned: pinned)
    }

    func archiveConversation(id: String, archived: Bool) async throws {
        if usesLocalConversationStore {
            await localStore.setArchived(id: id, archived: archived, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.archiveConversation(id: id, archived: archived)
    }

    // MARK: - Share / Clone

    func shareConversation(id: String) async throws -> String? {
        try await apiClient.shareConversation(id: id)
    }

    func unshareConversation(id: String) async throws {
        try await apiClient.unshareConversation(id: id)
    }

    func cloneConversation(id: String) async throws -> Conversation {
        try await apiClient.cloneConversation(id: id)
    }

    // MARK: - Archive / Shared Chat Browsing

    func fetchArchivedChats(page: Int = 1, query: String? = nil) async throws -> [Conversation] {
        try await apiClient.getArchivedChats(page: page, query: query)
    }

    func unarchiveAllConversations() async throws {
        try await apiClient.unarchiveAllConversations()
    }

    func fetchSharedChats(page: Int = 1) async throws -> [Conversation] {
        try await apiClient.getSharedChats(page: page)
    }

    // MARK: - Models

    func fetchModels() async throws -> [AIModel] {
        try await apiClient.getModels()
    }

    func generateImage(prompt: String, model: String, size: String = "1024x1024") async throws -> String {
        try await apiClient.generateImage(prompt: prompt, model: model, size: size)
    }

    func editImage(
        prompt: String,
        model: String,
        imageData: Data,
        fileName: String,
        size: String = "1024x1024"
    ) async throws -> String {
        try await apiClient.editImage(
            prompt: prompt,
            model: model,
            imageData: imageData,
            fileName: fileName,
            size: size
        )
    }

    func fetchDefaultModel() async -> String? {
        await apiClient.getDefaultModel()
    }

    func fetchUserDefaultModel() async -> String? {
        await apiClient.getUserDefaultModel()
    }

    // MARK: - Tools & Terminals

    func fetchTerminalServers() async throws -> [TerminalServer] {
        try await apiClient.listTerminalServers()
    }

    func fetchTools() async throws -> [ToolItem] {
        let rawTools = try await apiClient.getTools()
        return rawTools.compactMap { raw -> ToolItem? in
            guard let id = raw["id"] as? String else { return nil }
            let name = raw["name"] as? String ?? id.replacingOccurrences(of: "_", with: " ").capitalized
            let meta = raw["meta"] as? [String: Any]
            let description = meta?["description"] as? String ?? raw["description"] as? String
            let isActive = raw["is_active"] as? Bool ?? meta?["enabled"] as? Bool ?? false
            return ToolItem(id: id, name: name, description: description, isEnabled: isActive)
        }
    }

    // MARK: - Chat Completion

    func sendMessageStreaming(request: ChatCompletionRequest) async throws -> SSEStream {
        try await apiClient.sendMessageStreaming(request: request)
    }

    func sendMessageHTTP(request: ChatCompletionRequest) async throws -> [String: Any] {
        try await apiClient.sendMessageHTTP(request: request)
    }

    func syncConversationMessages(
        id: String,
        messages: [ChatMessage],
        model: String?,
        systemPrompt: String? = nil,
        title: String? = nil,
        chatParams: ChatAdvancedParams? = nil
    ) async throws {
        if usesLocalConversationStore {
            var conversation = (try? await localStore.get(id: id, serverURL: apiClient.baseURL))
                ?? Conversation(title: title ?? "New Chat")
            conversation.id = id
            conversation.title = title ?? conversation.title
            conversation.model = model
            conversation.systemPrompt = systemPrompt ?? conversation.systemPrompt
            conversation.chatParams = chatParams ?? conversation.chatParams
            conversation.messages = messages
            conversation.history = APIClient.buildHistoryFromFlatMessages(messages)
            await localStore.upsert(conversation, serverURL: apiClient.baseURL)
            return
        }
        try await apiClient.syncConversationMessages(
            id: id,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            chatParams: chatParams,
            title: title
        )
    }

    func sendChatCompleted(
        chatId: String,
        messageId: String,
        model: String,
        sessionId: String,
        messages: [[String: Any]] = [],
        filterIds: [String] = []
    ) async {
        await apiClient.sendChatCompleted(
            chatId: chatId,
            messageId: messageId,
            model: model,
            sessionId: sessionId,
            messages: messages,
            filterIds: filterIds
        )
    }

    // MARK: - Files

    func uploadFile(data: Data, fileName: String, onUploaded: ((String) -> Void)? = nil) async throws -> (fileId: String, fileObject: [String: Any]) {
        try await apiClient.uploadFile(data: data, fileName: fileName, onUploaded: onUploaded)
    }

    /// Uploads a file without triggering individual server-side processing.
    /// Returns the raw file object (id, filename, etc.) needed by the batch endpoint.
    func uploadFileOnly(data: Data, fileName: String) async throws -> [String: Any] {
        try await apiClient.uploadFileOnly(data: data, fileName: fileName)
    }

    /// Sends a set of already-uploaded file objects to the batch processing endpoint.
    func processFilesBatch(
        fileObjects: [[String: Any]],
        collectionName: String
    ) async throws -> (successes: [String], errors: [(fileId: String, error: String?)]) {
        try await apiClient.processFilesBatch(fileObjects: fileObjects, collectionName: collectionName)
    }

    // MARK: - Knowledge

    func fetchKnowledgeItems() async throws -> [KnowledgeItem] {
        try await apiClient.getKnowledgeItems()
    }

    func fetchKnowledgeFileItems() async throws -> [KnowledgeItem] {
        try await apiClient.getKnowledgeFileItems()
    }

    func fetchFolderItems() async throws -> [KnowledgeItem] {
        try await apiClient.getFolderItems()
    }

    var baseURL: String { apiClient.baseURL }

    var providerType: ServerConfig.ProviderType { apiClient.providerType }
}

// MARK: - Local Conversation Store

/// Local chat history used by direct API providers (OpenAI-compatible, Gemini, Claude).
///
/// Those providers do not expose OpenWebUI's `/api/v1/chats` database, so the app
/// persists conversations on-device and keeps the same drawer/history UX.
actor LocalConversationStore {
    static let shared = LocalConversationStore()

    private let logger = Logger(subsystem: "com.openui", category: "LocalConversationStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func list(serverURL: String) async -> [Conversation] {
        let conversations = await loadAll(serverURL: serverURL)
        return conversations
            .filter { !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func search(serverURL: String, query: String) async -> [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return await list(serverURL: serverURL) }
        return await list(serverURL: serverURL).filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.messages.contains { $0.content.localizedCaseInsensitiveContains(needle) }
        }
    }

    func get(id: String, serverURL: String) async throws -> Conversation {
        guard let conversation = await loadAll(serverURL: serverURL).first(where: { $0.id == id }) else {
            throw APIError.httpError(
                statusCode: 404,
                message: "Local conversation not found.",
                data: Data()
            )
        }
        return conversation
    }

    func upsert(_ conversation: Conversation, serverURL: String) async {
        var conversations = await loadAll(serverURL: serverURL)
        var stored = conversation
        stored.updatedAt = .now
        if stored.history.isPopulated {
            stored.rederiveMessages()
        }
        if let index = conversations.firstIndex(where: { $0.id == stored.id }) {
            conversations[index] = stored
        } else {
            conversations.insert(stored, at: 0)
        }
        await saveAll(conversations, serverURL: serverURL)
    }

    func rename(id: String, title: String, serverURL: String) async {
        var conversations = await loadAll(serverURL: serverURL)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = title
        conversations[index].updatedAt = .now
        await saveAll(conversations, serverURL: serverURL)
    }

    func setPinned(id: String, pinned: Bool, serverURL: String) async {
        var conversations = await loadAll(serverURL: serverURL)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned = pinned
        conversations[index].updatedAt = .now
        await saveAll(conversations, serverURL: serverURL)
    }

    func setArchived(id: String, archived: Bool, serverURL: String) async {
        var conversations = await loadAll(serverURL: serverURL)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].archived = archived
        conversations[index].updatedAt = .now
        await saveAll(conversations, serverURL: serverURL)
    }

    func delete(id: String, serverURL: String) async {
        var conversations = await loadAll(serverURL: serverURL)
        conversations.removeAll { $0.id == id }
        await saveAll(conversations, serverURL: serverURL)
    }

    func deleteAll(serverURL: String) async {
        await saveAll([], serverURL: serverURL)
    }

    private func loadAll(serverURL: String) async -> [Conversation] {
        let url = storeURL(for: serverURL)
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try decoder.decode([Conversation].self, from: data)
        } catch {
            logger.error("Failed to decode local conversations: \(error.localizedDescription)")
            return []
        }
    }

    private func saveAll(_ conversations: [Conversation], serverURL: String) async {
        let url = storeURL(for: serverURL)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(conversations.sorted { $0.updatedAt > $1.updatedAt })
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save local conversations: \(error.localizedDescription)")
        }
    }

    private func storeURL(for serverURL: String) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("Iexa/LocalConversations", isDirectory: true)
        let filename = safeFilename(for: serverURL) + ".json"
        return directory.appendingPathComponent(filename)
    }

    private func safeFilename(for value: String) -> String {
        let data = Data(value.utf8)
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
