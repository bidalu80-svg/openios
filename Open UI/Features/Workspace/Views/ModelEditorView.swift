import SwiftUI
import PhotosUI
import os.log

// MARK: - ModelEditorView

/// Sheet for creating or editing a custom Model.
/// Mirrors SkillEditorView/KnowledgeEditorView in structure and access-grant UI.
struct ModelEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let logger = Logger(subsystem: "com.openui", category: "ModelEditor")

    // MARK: - Input

    var existingModel: ModelDetail?
    var onSave: ((ModelDetail) -> Void)?

    // MARK: - Basic Info

    @State private var name = ""
    @State private var modelId = ""
    @State private var baseModelId = ""
    @State private var baseModelDisplayName = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var idManuallyEdited = false
    @State private var isAutoSettingId = false

    // MARK: - Profile Image

    @State private var profileImageURL: String? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedImageData: Data? = nil
    @State private var isUploadingProfileImage = false

    // MARK: - System Prompt

    @State private var systemPrompt = ""
    @State private var isSystemPromptExpanded = false

    // MARK: - Active

    @State private var isActive = true
    @State private var initialIsActive = true
    @State private var isTogglingActive = false

    // MARK: - Capabilities

    @State private var capVision = true
    @State private var capFileUpload = true
    @State private var capFileContext = true
    @State private var capWebSearch = true
    @State private var capImageGeneration = true
    @State private var capCodeInterpreter = true
    @State private var capUsage = true
    @State private var capCitations = true
    @State private var capStatusUpdates = true
    @State private var capBuiltinTools = true

    // MARK: - Default Features

    @State private var defaultWebSearch = true
    @State private var defaultImageGen = false
    @State private var defaultCodeInterpreter = false

    // MARK: - Builtin Tools

    @State private var builtinTime = true
    @State private var builtinMemory = true
    @State private var builtinChats = true
    @State private var builtinNotes = true
    @State private var builtinKnowledge = true
    @State private var builtinChannels = true
    @State private var builtinTaskManagement = true
    @State private var builtinAutomations = true
    @State private var builtinCalendar = true
    @State private var builtinWebSearch = true
    @State private var builtinImageGen = true
    @State private var builtinCodeInterpreter = true

    // MARK: - Knowledge

    @State private var knowledgeItems: [ModelKnowledgeEntry] = []
    @State private var showKnowledgePicker = false

    // MARK: - Tools, Skills, Filters

    @State private var selectedToolIds: Set<String> = []
    @State private var selectedFilterIds: Set<String> = []
    @State private var defaultFilterIds: Set<String> = []
    @State private var selectedActionIds: Set<String> = []
    @State private var allTools: [(id: String, name: String)] = []
    @State private var allFilters: [(id: String, name: String, isGlobal: Bool)] = []
    @State private var allActions: [(id: String, name: String)] = []
    /// Action-type functions (type == "action") with global/active state.
    /// Used for the "Actions" section with global lock support.
    @State private var allActionFunctions: [(id: String, name: String, isGlobal: Bool)] = []
    @State private var selectedActionFunctionIds: Set<String> = []
    @State private var isFetchingToolsAndFunctions = false

    // MARK: - Suggestion Prompts

    @State private var suggestionPrompts: [SuggestionPrompt] = []
    @State private var useCustomPrompts: Bool = false

    // MARK: - TTS Voice

    @State private var ttsVoice = ""

    // MARK: - Base Model Picker

    @State private var availableModels: [AIModel] = []
    @State private var showBaseModelPicker = false
    @State private var isFetchingModels = false

    // MARK: - Advanced Params

    @State private var showAdvancedParams = false

    @State private var advStreamResponse: Bool? = nil
    @State private var advStreamDeltaChunkSize: Int? = nil
    @State private var advFunctionCalling: String? = nil
    @State private var advReasoningEffort: String? = nil
    @State private var advReasoningTagsEnabled: Bool? = nil
    @State private var advReasoningTagStart: String? = nil
    @State private var advReasoningTagEnd: String? = nil
    @State private var advSeed: Int? = nil
    @State private var advStopSequences: String? = nil
    @State private var advTemperature: Double? = nil
    @State private var advLogitBias: String? = nil
    @State private var advMaxTokens: Int? = nil
    @State private var advTopK: Int? = nil
    @State private var advTopP: Double? = nil
    @State private var advMinP: Double? = nil
    @State private var advFrequencyPenalty: Double? = nil
    @State private var advPresencePenalty: Double? = nil
    @State private var advMirostat: Int? = nil
    @State private var advMirostatEta: Double? = nil
    @State private var advMirostatTau: Double? = nil
    @State private var advRepeatLastN: Int? = nil
    @State private var advTfsZ: Double? = nil
    @State private var advRepeatPenalty: Double? = nil
    @State private var advUseMmap: Bool? = nil
    @State private var advUseMlock: Bool? = nil
    @State private var advThink: Bool? = nil
    @State private var advThinkCustom: String? = nil
    @State private var advFormat: String? = nil
    @State private var advNumKeep: Int? = nil
    @State private var advNumCtx: Int? = nil
    @State private var advNumBatch: Int? = nil
    @State private var advNumThread: Int? = nil
    @State private var advNumGpu: Int? = nil
    @State private var advKeepAlive: String? = nil
    @State private var customParams: [(key: String, value: String)] = []

    // MARK: - Access Control

    @State private var isPrivate = true
    @State private var localAccessGrants: [AccessGrant] = []
    @State private var resolvedGroups: [String: GroupResponse] = [:]
    @State private var isUpdatingAccess = false
    @State private var accessUpdateError: String?

    // MARK: - UI State

    @State private var isSaving = false
    @State private var validationError: String? = nil
    @State private var showDiscardConfirm = false

    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, modelId, description, systemPrompt, ttsVoice, newSuggestion }

    // MARK: - Computed

    private var manager: ModelManager? { dependencies.modelManager }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }
    private var isEditing: Bool { existingModel != nil }
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }


    /// Whether this is a provider model (not a custom model wrapping another).
    /// Provider models have no base_model_id. The web UI hides the base model
    /// picker for these models since they ARE the base model.
    private var isProviderModel: Bool {
        isEditing && existingModel?.baseModelId == nil
    }

    private var hasChanges: Bool {
        guard let existing = existingModel else {
            return !name.isEmpty || !modelId.isEmpty || !systemPrompt.isEmpty
        }
        return name != existing.name
            || modelId != existing.id
            || systemPrompt != existing.systemPrompt
            || description != (existing.description ?? "")
    }

    // Resolved profile image URL for displaying in the editor.
    // Returns nil for data URIs (handled via selectedImageData / dataURIImage).
    private var resolvedProfileImageURL: URL? {
        let urlString = profileImageURL ?? ""
        if urlString.hasPrefix("data:image") { return nil }
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return URL(string: urlString)
        }
        // For an existing model use the model avatar endpoint
        if let id = existingModel?.id, !id.isEmpty {
            let normalizedBase = serverBaseURL.hasSuffix("/") ? String(serverBaseURL.dropLast()) : serverBaseURL
            var comps = URLComponents(string: "\(normalizedBase)/api/v1/models/model/profile/image")
            comps?.queryItems = [URLQueryItem(name: "id", value: id)]
            return comps?.url
        }
        // New model with no user-picked image → show server default favicon
        let normalizedBase = serverBaseURL.hasSuffix("/") ? String(serverBaseURL.dropLast()) : serverBaseURL
        if !normalizedBase.isEmpty {
            return URL(string: "\(normalizedBase)/static/favicon.png")
        }
        return nil
    }

    // UIImage decoded from an existing data URI profileImageURL (edit mode, no new photo picked)
    private var dataURIImage: UIImage? {
        guard let urlString = profileImageURL, urlString.hasPrefix("data:image") else { return nil }
        guard selectedImageData == nil else { return nil } // already showing via selectedImageData
        if let commaIdx = urlString.firstIndex(of: ",") {
            let base64 = String(urlString[urlString.index(after: commaIdx)...])
            if let data = Data(base64Encoded: base64) {
                return UIImage(data: data)
            }
        }
        return nil
    }

    // MARK: - Slugify helper

    /// Converts a display name into a URL-safe slug: "Abhi AI" → "abhi-ai"
    static func slugify(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    profileImageSection
                    basicInfoSection
                    systemPromptSection
                    // Advanced params extracted into a child struct to prevent stack overflow
                    ModelAdvancedParamsSection(
                        showAdvancedParams: $showAdvancedParams,
                        advStreamResponse: $advStreamResponse,
                        advStreamDeltaChunkSize: $advStreamDeltaChunkSize,
                        advFunctionCalling: $advFunctionCalling,
                        advReasoningEffort: $advReasoningEffort,
                        advReasoningTagsEnabled: $advReasoningTagsEnabled,
                        advReasoningTagStart: $advReasoningTagStart,
                        advReasoningTagEnd: $advReasoningTagEnd,
                        advSeed: $advSeed,
                        advStopSequences: $advStopSequences,
                        advTemperature: $advTemperature,
                        advLogitBias: $advLogitBias,
                        advMaxTokens: $advMaxTokens,
                        advTopK: $advTopK,
                        advTopP: $advTopP,
                        advMinP: $advMinP,
                        advFrequencyPenalty: $advFrequencyPenalty,
                        advPresencePenalty: $advPresencePenalty,
                        advMirostat: $advMirostat,
                        advMirostatEta: $advMirostatEta,
                        advMirostatTau: $advMirostatTau,
                        advRepeatLastN: $advRepeatLastN,
                        advTfsZ: $advTfsZ,
                        advRepeatPenalty: $advRepeatPenalty,
                        advUseMmap: $advUseMmap,
                        advUseMlock: $advUseMlock,
                        advThink: $advThink,
                        advFormat: $advFormat,
                        advNumKeep: $advNumKeep,
                        advNumCtx: $advNumCtx,
                        advNumBatch: $advNumBatch,
                        advNumThread: $advNumThread,
                        advNumGpu: $advNumGpu,
                        advKeepAlive: $advKeepAlive,
                        customParams: $customParams
                    )
                    suggestionPromptsSection
                    knowledgeSection
                    ModelToolsAndCapabilitiesSection(
                        selectedToolIds: $selectedToolIds,
                        allTools: $allTools,
                        isFetchingToolsAndFunctions: $isFetchingToolsAndFunctions,
                        selectedActionIds: $selectedActionIds,
                        allActions: $allActions,
                        allActionFunctions: $allActionFunctions,
                        selectedActionFunctionIds: $selectedActionFunctionIds,
                        selectedFilterIds: $selectedFilterIds,
                        defaultFilterIds: $defaultFilterIds,
                        allFilters: $allFilters,
                        capVision: $capVision, capFileUpload: $capFileUpload,
                        capFileContext: $capFileContext, capWebSearch: $capWebSearch,
                        capImageGeneration: $capImageGeneration, capCodeInterpreter: $capCodeInterpreter,
                        capUsage: $capUsage, capCitations: $capCitations,
                        capStatusUpdates: $capStatusUpdates, capBuiltinTools: $capBuiltinTools,
                        defaultWebSearch: $defaultWebSearch, defaultImageGen: $defaultImageGen,
                        defaultCodeInterpreter: $defaultCodeInterpreter,
                        builtinTime: $builtinTime, builtinMemory: $builtinMemory,
                        builtinChats: $builtinChats, builtinNotes: $builtinNotes,
                        builtinKnowledge: $builtinKnowledge, builtinChannels: $builtinChannels,
                        builtinTaskManagement: $builtinTaskManagement, builtinAutomations: $builtinAutomations, builtinCalendar: $builtinCalendar,
                        builtinWebSearch: $builtinWebSearch, builtinImageGen: $builtinImageGen,
                        builtinCodeInterpreter: $builtinCodeInterpreter
                    )
                    ttsVoiceSection
                    settingsSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "编辑模型" : "新建模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $isSystemPromptExpanded) {
                FullscreenContentEditor(
                    title: "系统提示词",
                    placeholder: "输入系统提示词…",
                    content: $systemPrompt
                )
            }
            .sheet(isPresented: $showBaseModelPicker) {
                BaseModelPickerSheet(
                    availableModels: availableModels.filter { model in
                        // Exclude self
                        guard model.id != modelId else { return false }
                        // Exclude workspace models — models that have a base_model_id set
                        // are custom models wrapping another model, not provider models.
                        if let info = model.rawModelItem?["info"] as? [String: Any],
                           let baseId = info["base_model_id"] as? String,
                           !baseId.isEmpty {
                            return false
                        }
                        return true
                    },
                    selectedModelId: baseModelId,
                    serverBaseURL: serverBaseURL,
                    authToken: authToken,
                    onSelect: { model in
                        baseModelId = model.id
                        baseModelDisplayName = model.name
                        showBaseModelPicker = false
                        logger.info("[BaseModelPicker] Selected base model: id='\(model.id)' name='\(model.name)'")
                    },
                    onClear: {
                        baseModelId = ""
                        baseModelDisplayName = ""
                        showBaseModelPicker = false
                        logger.info("[BaseModelPicker] Cleared base model selection")
                    },
                    onDismiss: { showBaseModelPicker = false }
                )
                .environment(dependencies)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "放弃更改？",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("放弃", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("未保存的更改会丢失。")
            }
            .alert("校验错误", isPresented: .init(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: { Text(validationError ?? "") }
            .alert("权限错误", isPresented: .init(
                get: { accessUpdateError != nil },
                set: { if !$0 { accessUpdateError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: { Text(accessUpdateError ?? "") }
        }
        .onAppear {
            populateIfEditing()
            Task {
                await manager?.fetchAllUsers()
                await fetchAvailableModels()
                await fetchToolsAndFunctions()
                await resolveGroupNames()
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await handlePhotoSelection(newItem) }
        }
    }

    // MARK: - Profile Image Section

    private var profileImageSection: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            HStack {
                Spacer()
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        // Priority: 1) newly picked photo, 2) existing data URI, 3) resolved URL, 4) fallback
                        if let imageData = selectedImageData, let uiImage = UIImage(data: imageData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if let uiImage = dataURIImage {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if let avatarURL = resolvedProfileImageURL {
                            CachedAsyncImage(url: avatarURL, authToken: authToken) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.shimmerBase)
                                    .frame(width: 72, height: 72)
                                    .shimmer()
                            }
                        } else {
                            // Fallback avatar
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.brandPrimary.opacity(0.12))
                                    .frame(width: 72, height: 72)
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 1)
                                    .frame(width: 72, height: 72)
                                if let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                                    Text(String(initial).uppercased())
                                        .scaledFont(size: 28, weight: .semibold, design: .rounded)
                                        .foregroundStyle(theme.brandPrimary)
                                } else {
                                    Image(systemName: "brain")
                                        .scaledFont(size: 28, weight: .medium)
                                        .foregroundStyle(theme.brandPrimary)
                                }
                            }
                        }

                        // Edit badge overlay
                        ZStack {
                            Circle()
                                .fill(theme.brandPrimary)
                                .frame(width: 22, height: 22)
                            Image(systemName: "pencil")
                                .scaledFont(size: 11, weight: .bold)
                                .foregroundStyle(.white)
                        }
                        .offset(x: 4, y: 4)
                    }
                }
                .buttonStyle(.plain)
                .overlay(
                    Group {
                        if isUploadingProfileImage {
                            ProgressView()
                                .tint(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.black.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                )
                Spacer()
            }
            Text("点按更换模型头像")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Basic Info Section

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("模型信息")
            fieldCard {
                VStack(spacing: 0) {
                    // Name
                    HStack {
                        Text("名称")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("例如 AWS 聊天助手", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .onChange(of: name) { _, newValue in
                                // Auto-fill Model ID with slugified name unless user edited it manually.
                                // isAutoSettingId is intentionally left true here; it is cleared in the
                                // modelId onChange handler which fires in the same render pass after the
                                // binding is updated, ensuring the flag is still set when that fires.
                                if !idManuallyEdited {
                                    isAutoSettingId = true
                                    modelId = Self.slugify(newValue)
                                }
                            }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Model ID
                    HStack {
                        Text("模型 ID")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("例如 aws-chatbot", text: $modelId)
                            .scaledFont(size: 15)
                            .foregroundStyle(isEditing ? theme.textSecondary : theme.textPrimary)
                            .focused($focusedField, equals: .modelId)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .disabled(isEditing)
                            .onChange(of: modelId) { _, _ in
                                if isAutoSettingId {
                                    // This change was triggered programmatically by the name field.
                                    // Clear the flag here (correct render cycle) so future user
                                    // edits are correctly detected.
                                    isAutoSettingId = false
                                } else {
                                    idManuallyEdited = true
                                }
                            }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    if !isProviderModel {
                    // Base Model — Picker button
                    Button {
                        Haptics.play(.light)
                        showBaseModelPicker = true
                        logger.info("[BaseModelPicker] Opening base model picker (available models: \(availableModels.count))")
                    } label: {
                        HStack {
                            Text("基础模型")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 90, alignment: .leading)
                            if isFetchingModels {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .padding(.leading, 4)
                            } else if baseModelId.isEmpty {
                                Text("选择模型")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textTertiary)
                            } else {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(baseModelDisplayName.isEmpty ? baseModelId : baseModelDisplayName)
                                        .scaledFont(size: 15)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    if !baseModelDisplayName.isEmpty && baseModelDisplayName != baseModelId {
                                        Text(baseModelId)
                                            .scaledFont(size: 11)
                                            .foregroundStyle(theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))
                    } // end if !isProviderModel

                    // Description
                    HStack {
                        Text("描述")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("可选描述", text: $description)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .description)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Tags
                    HStack {
                        Text("标签")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("例如 aws, chat（用英文逗号分隔）", text: $tags)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)
                }
            }
        }
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("系统提示词")
                Spacer()
                Button {
                    Haptics.play(.light)
                    isSystemPromptExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(6)
                        .background(theme.surfaceContainer.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            fieldCard {
                TextEditor(text: $systemPrompt)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 120, maxHeight: 300)
                    .focused($focusedField, equals: .systemPrompt)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
            }
        }
    }

    // MARK: - Suggestion Prompts Section

    private var suggestionPromptsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header row: "PROMPTS" label + Default/Custom toggle button
            HStack {
                sectionHeader("快捷提示")
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        useCustomPrompts.toggle()
                        if !useCustomPrompts { suggestionPrompts = [] }
                    }
                    Haptics.play(.light)
                } label: {
                    Text(useCustomPrompts ? "自定义" : "默认")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(useCustomPrompts ? theme.brandPrimary : theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(useCustomPrompts ? theme.brandPrimary.opacity(0.12) : theme.surfaceContainer)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Only show the card when Custom mode is active
            if useCustomPrompts {
                fieldCard {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestionPrompts.enumerated()), id: \.offset) { idx, _ in
                            VStack(spacing: 0) {
                                // Title field
                                HStack {
                                    Text("标题")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("可选标题", text: Binding(
                                        get: { suggestionPrompts[idx].title },
                                        set: { suggestionPrompts[idx].title = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                    Spacer()
                                    Button {
                                        suggestionPrompts.remove(at: idx)
                                        Haptics.play(.light)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .scaledFont(size: 16)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                                // Subtitle field
                                HStack {
                                    Text("副标题")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("可选副标题", text: Binding(
                                        get: { suggestionPrompts[idx].subtitle },
                                        set: { suggestionPrompts[idx].subtitle = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.bottom, 4)

                                // Prompt content field
                                HStack {
                                    Text("提示词")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("提示词内容", text: Binding(
                                        get: { suggestionPrompts[idx].content },
                                        set: { suggestionPrompts[idx].content = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.bottom, 10)
                            }
                            Divider().background(theme.inputBorder.opacity(0.3))
                        }

                        // Add new prompt button
                        Button {
                            suggestionPrompts.append(SuggestionPrompt())
                            Haptics.play(.light)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                                Text("添加提示词")
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - Knowledge Section

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("知识库")
            Text("给这个模型挂载知识集合或文件。")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)

            fieldCard {
                VStack(spacing: 0) {
                    ForEach(knowledgeItems) { entry in
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: entry.icon)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.brandPrimary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundStyle(theme.textPrimary)
                                Text(entry.type == .collection ? "知识集合" : "文件")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Button {
                                logger.info("[Knowledge] Removing entry: id='\(entry.id)' name='\(entry.name)' type=\(entry.type.rawValue)")
                                knowledgeItems.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                        Divider().background(theme.inputBorder.opacity(0.3))
                    }

                    Button {
                        Haptics.play(.light)
                        showKnowledgePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                            Text("添加知识")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                }
            }
        }
        .sheet(isPresented: $showKnowledgePicker) {
            WorkspaceKnowledgePickerSheet(
                selectedIds: Set(knowledgeItems.map { $0.id }),
                onSelectCollection: { item in
                    if !knowledgeItems.contains(where: { $0.id == item.id }) {
                        let entry = ModelKnowledgeEntry(
                            id: item.id,
                            name: item.name,
                            description: item.description,
                            type: .collection
                        )
                        knowledgeItems.append(entry)
                        logger.info("[Knowledge] Added collection: id='\(item.id)' name='\(item.name)'")
                    }
                    showKnowledgePicker = false
                },
                onSelectFile: { item in
                    if !knowledgeItems.contains(where: { $0.id == item.id }) {
                        let entry = ModelKnowledgeEntry(
                            id: item.id,
                            name: item.name,
                            description: item.description,
                            type: .file
                        )
                        knowledgeItems.append(entry)
                        logger.info("[Knowledge] Added file: id='\(item.id)' name='\(item.name)'")
                    }
                    showKnowledgePicker = false
                },
                onDismiss: { showKnowledgePicker = false }
            )
            .environment(dependencies)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Tools Section

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("工具")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("正在加载工具…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allTools.isEmpty {
                fieldCard {
                    Text("暂无可用工具。请先到“工具”工作区添加。")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                }
            } else {
                fieldCard {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                            ForEach(allTools, id: \.id) { tool in
                                setCheckbox(tool.name, id: tool.id, selection: $selectedToolIds)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }
                Text("要在这里选择工具包，请先到“工具”工作区添加。")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - Skills Section

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("技能")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("正在加载技能…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allActions.isEmpty {
                fieldCard {
                    Text("暂无可用技能。请先到“技能”工作区添加。")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allActions, id: \.id) { action in
                            setCheckbox(action.name, id: action.id, selection: $selectedActionIds)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
                Text("要在这里选择技能，请先到“技能”工作区添加。")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - Filters Section

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("过滤器")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("正在加载过滤器…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allFilters.isEmpty {
                fieldCard {
                    Text("暂无可用过滤器。")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allFilters, id: \.id) { filter in
                            setCheckbox(filter.name, id: filter.id, selection: $selectedFilterIds)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }

                // Default Filters — only shows filters that are currently selected above
                let checkedFilters = allFilters.filter { selectedFilterIds.contains($0.id) }
                if !checkedFilters.isEmpty {
                    sectionHeader("默认过滤器")
                    fieldCard {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                            ForEach(checkedFilters, id: \.id) { filter in
                                setCheckbox(filter.name, id: filter.id, selection: $defaultFilterIds)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    // MARK: - Capabilities Section

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("能力")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("视觉识图", systemImage: "eye", value: $capVision)
                    capCheckbox("文件上传", systemImage: "doc.badge.plus", value: $capFileUpload)
                    capCheckbox("文件上下文", systemImage: "doc.text.magnifyingglass", value: $capFileContext)
                    capCheckbox("联网搜索", systemImage: "magnifyingglass", value: $capWebSearch)
                    capCheckbox("图像生成", systemImage: "photo.badge.plus", value: $capImageGeneration)
                    capCheckbox("代码解释器", systemImage: "chevron.left.forwardslash.chevron.right", value: $capCodeInterpreter)
                    capCheckbox("用量统计", systemImage: "chart.bar", value: $capUsage)
                    capCheckbox("引用来源", systemImage: "quote.bubble", value: $capCitations)
                    capCheckbox("状态更新", systemImage: "info.circle", value: $capStatusUpdates)
                    capCheckbox("内置工具", systemImage: "wrench.and.screwdriver", value: $capBuiltinTools)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Default Features Section

    private var defaultFeaturesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("默认功能")
            fieldCard {
                HStack(spacing: 0) {
                    capCheckbox("联网搜索", systemImage: "magnifyingglass", value: $defaultWebSearch)
                    capCheckbox("图像生成", systemImage: "photo.badge.plus", value: $defaultImageGen)
                    capCheckbox("代码解释器", systemImage: "chevron.left.forwardslash.chevron.right", value: $defaultCodeInterpreter)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Builtin Tools Section

    private var builtinToolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("内置工具")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("时间和计算", systemImage: "clock", value: $builtinTime)
                    capCheckbox("记忆", systemImage: "brain", value: $builtinMemory)
                    capCheckbox("聊天记录", systemImage: "bubble.left.and.bubble.right", value: $builtinChats)
                    capCheckbox("笔记", systemImage: "note.text", value: $builtinNotes)
                    capCheckbox("知识库", systemImage: "cylinder.split.1x2", value: $builtinKnowledge)
                    capCheckbox("频道", systemImage: "antenna.radiowaves.left.and.right", value: $builtinChannels)
                    capCheckbox("任务管理", systemImage: "checklist", value: $builtinTaskManagement)
                    capCheckbox("自动化", systemImage: "gearshape.2", value: $builtinAutomations)
                    capCheckbox("日历", systemImage: "calendar", value: $builtinCalendar)
                    capCheckbox("联网搜索", systemImage: "magnifyingglass", value: $builtinWebSearch)
                    capCheckbox("图像生成", systemImage: "photo.badge.plus", value: $builtinImageGen)
                    capCheckbox("代码解释器", systemImage: "chevron.left.forwardslash.chevron.right", value: $builtinCodeInterpreter)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - TTS Voice Section

    private var ttsVoiceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("语音合成声音")
            fieldCard {
                HStack {
                    TextField("例如 alloy、echo、shimmer", text: $ttsVoice)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .focused($focusedField, equals: .ttsVoice)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Settings Section (Active + Access Control)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("设置")
            fieldCard {
                VStack(spacing: 0) {
                    Toggle(isOn: $isActive) {
                        HStack(spacing: Spacing.sm) {
                            if isTogglingActive {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("启用")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                Text("停用后不会出现在模型选择器里。")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    .tint(theme.brandPrimary)
                    .disabled(isTogglingActive)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .onChange(of: isActive) { oldVal, newVal in
                        guard isEditing, newVal != initialIsActive else { return }
                        initialIsActive = newVal
                        Task { await persistActiveToggle(id: existingModel?.id) }
                    }

                    Divider().background(theme.inputBorder.opacity(0.4))
                    accessControlSection
                }
            }
        }
    }

    // MARK: - Access Control Section

    @ViewBuilder
    private var accessControlSection: some View {
        AccessControlSection(
            localAccessGrants: $localAccessGrants,
            isPrivate: $isPrivate,
            allUsers: allUsers,
            resolvedGroups: resolvedGroups,
            isUpdating: isUpdatingAccess,
            serverBaseURL: serverBaseURL,
            authToken: authToken,
            apiClient: dependencies.apiClient,
            onAccessModeChange: { newVal in
                await handleAccessModeChange(isPrivate: newVal)
            },
            onTogglePermission: { principalId, isGroup, currentlyWrite in
                await togglePermission(principalId: principalId, isGroup: isGroup, currentlyWrite: currentlyWrite)
            },
            onRemoveGrant: { principalId, isGroup in
                await removeGrant(principalId: principalId, isGroup: isGroup)
            },
            onAddGrants: { userIds, groupIds in
                await addGrants(userIds: userIds, groupIds: groupIds)
            }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("取消") {
                if hasChanges { showDiscardConfirm = true } else { dismiss() }
            }
            .scaledFont(size: 16)
            .foregroundStyle(theme.textSecondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView().tint(theme.brandPrimary)
            } else {
                Button("保存") {
                    Task { await save() }
                }
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || modelId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Set-based Checkbox (for Tools, Skills, Filters)

    @ViewBuilder
    private func setCheckbox(_ label: String, id: String, selection: Binding<Set<String>>) -> some View {
        let isSelected = selection.wrappedValue.contains(id)
        Button {
            if isSelected {
                selection.wrappedValue.remove(id)
            } else {
                selection.wrappedValue.insert(id)
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                Text(label)
                    .scaledFont(size: 13)
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Capability Checkbox

    @ViewBuilder
    private func capCheckbox(_ label: String, systemImage: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(value.wrappedValue ? theme.brandPrimary : theme.textTertiary)
                Text(label)
                    .scaledFont(size: 13)
                    .foregroundStyle(value.wrappedValue ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
            )
    }

    // MARK: - Populate

    private func populateIfEditing() {
        guard let model = existingModel else { return }
        logger.info("[Populate] Loading existing model: id='\(model.id)' name='\(model.name)'")
        name = model.name
        modelId = model.id
        baseModelId = model.baseModelId ?? ""
        baseModelDisplayName = "" // will be resolved from available models after fetch
        description = model.description ?? ""
        tags = model.tags.joined(separator: ", ")
        isActive = model.isActive
        initialIsActive = model.isActive
        systemPrompt = model.systemPrompt
        ttsVoice = model.ttsVoice
        suggestionPrompts = model.suggestionPrompts
        useCustomPrompts = !model.suggestionPrompts.isEmpty
        knowledgeItems = model.knowledgeItems
        profileImageURL = model.profileImageURL

        capVision = model.capVision; capFileUpload = model.capFileUpload
        capFileContext = model.capFileContext; capWebSearch = model.capWebSearch
        capImageGeneration = model.capImageGeneration; capCodeInterpreter = model.capCodeInterpreter
        capUsage = model.capUsage; capCitations = model.capCitations
        capStatusUpdates = model.capStatusUpdates; capBuiltinTools = model.capBuiltinTools

        defaultWebSearch = model.defaultFeatureWebSearch
        defaultImageGen = model.defaultFeatureImageGen
        defaultCodeInterpreter = model.defaultFeatureCodeInterpreter

        builtinTime = model.builtinTime; builtinMemory = model.builtinMemory
        builtinChats = model.builtinChats; builtinNotes = model.builtinNotes
        builtinKnowledge = model.builtinKnowledge; builtinChannels = model.builtinChannels
        builtinTaskManagement = model.builtinTaskManagement
        builtinAutomations = model.builtinAutomations
        builtinCalendar = model.builtinCalendar
        builtinWebSearch = model.builtinWebSearch; builtinImageGen = model.builtinImageGen
        builtinCodeInterpreter = model.builtinCodeInterpreter

        advStreamResponse = model.advStreamResponse
        advStreamDeltaChunkSize = model.advStreamDeltaChunkSize
        advFunctionCalling = model.advFunctionCalling
        advReasoningEffort = model.advReasoningEffort
        advReasoningTagsEnabled = model.advReasoningTagsEnabled
        advReasoningTagStart = model.advReasoningTagStart
        advReasoningTagEnd = model.advReasoningTagEnd
        advSeed = model.advSeed
        advStopSequences = model.advStopSequences?.joined(separator: ", ")
        advTemperature = model.advTemperature
        advLogitBias = model.advLogitBias
        advMaxTokens = model.advMaxTokens
        advTopK = model.advTopK
        advTopP = model.advTopP
        advMinP = model.advMinP
        advFrequencyPenalty = model.advFrequencyPenalty
        advPresencePenalty = model.advPresencePenalty
        advMirostat = model.advMirostat
        advMirostatEta = model.advMirostatEta
        advMirostatTau = model.advMirostatTau
        advRepeatLastN = model.advRepeatLastN
        advTfsZ = model.advTfsZ
        advRepeatPenalty = model.advRepeatPenalty
        advUseMmap = model.advUseMmap
        advUseMlock = model.advUseMlock
        advThink = model.advThink
        advFormat = model.advFormat
        advNumKeep = model.advNumKeep
        advNumCtx = model.advNumCtx
        advNumBatch = model.advNumBatch
        advNumThread = model.advNumThread
        advNumGpu = model.advNumGpu
        advKeepAlive = model.advKeepAlive
        customParams = model.customParams

        let hasWildcard = model.accessGrants.contains { $0.userId == "*" }
        localAccessGrants = model.accessGrants.filter { $0.userId != "*" }
        // Tools, Skills, Filters
        selectedToolIds = Set(model.toolIds)
        selectedFilterIds = Set(model.filterIds)
        defaultFilterIds = Set(model.defaultFilterIds)
        selectedActionIds = Set(model.actionIds)

        isPrivate = !hasWildcard
        idManuallyEdited = true

        logger.info("[Populate] Done. baseModelId='\(model.baseModelId ?? "none")' knowledgeItems=\(model.knowledgeItems.count) toolIds=\(model.toolIds.count) filterIds=\(model.filterIds.count) actionIds=\(model.actionIds.count)")
    }

    // MARK: - Fetch Available Models

    private func fetchAvailableModels() async {
        guard let api = dependencies.apiClient else { return }
        isFetchingModels = true
        logger.info("[BaseModelPicker] Fetching available models...")
        do {
            let models = try await api.getModels()
            availableModels = models
            logger.info("[BaseModelPicker] Fetched \(models.count) models")
            // Resolve display name for the current baseModelId
            if !baseModelId.isEmpty {
                if let match = models.first(where: { $0.id == baseModelId }) {
                    baseModelDisplayName = match.name
                    logger.info("[BaseModelPicker] Resolved base model display name: '\(match.name)' for id='\(baseModelId)'")
                }
            }
        } catch {
            logger.error("[BaseModelPicker] Failed to fetch models: \(error.localizedDescription)")
        }
        isFetchingModels = false
    }

    // MARK: - Fetch Tools & Functions

    private func fetchToolsAndFunctions() async {
        guard let api = dependencies.apiClient else { return }
        isFetchingToolsAndFunctions = true
        logger.info("[ToolsFunctions] Fetching tools, skills, and functions…")
        do {
            // Fetch tools from /api/v1/tools/ (returns [[String: Any]])
            let tools = try await api.getTools()
            allTools = tools.compactMap { dict -> (id: String, name: String)? in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                return (id: id, name: name)
            }
            logger.info("[ToolsFunctions] Fetched \(allTools.count) tools")

            // Fetch filters and action functions from /api/v1/functions/
            let functions = try await api.getFunctions()
            allFilters = functions
                .filter { $0.type == "filter" }
                .map { (id: $0.id, name: $0.name, isGlobal: $0.isGlobal) }
            logger.info("[ToolsFunctions] Fetched \(allFilters.count) filters from functions")

            // Pre-select global filters (always enabled, non-editable)
            for fn in allFilters where fn.isGlobal {
                selectedFilterIds.insert(fn.id)
            }
            // Also select per-model filter IDs from the existing model
            if let model = existingModel {
                for filterId in model.filterIds {
                    selectedFilterIds.insert(filterId)
                }
            }

            // Extract action-type functions with global state for the Actions section
            allActionFunctions = functions
                .filter { $0.type == "action" && $0.isActive }
                .map { (id: $0.id, name: $0.name, isGlobal: $0.isGlobal) }
            logger.info("[ToolsFunctions] Fetched \(allActionFunctions.count) active action functions")

            // Pre-select action functions: global ones are always selected,
            // per-model ones come from the model's actionIds
            for fn in allActionFunctions where fn.isGlobal {
                selectedActionFunctionIds.insert(fn.id)
            }
            // Also select per-model action IDs from the existing model
            if let model = existingModel {
                for actionId in model.actionIds {
                    selectedActionFunctionIds.insert(actionId)
                }
            }

            // Fetch skills from /api/v1/skills/list (separate paginated endpoint)
            let skills = try await api.getSkills()
            allActions = skills.map { (id: $0.id, name: $0.name) }
            logger.info("[ToolsFunctions] Fetched \(allActions.count) skills")
        } catch {
            logger.error("[ToolsFunctions] Failed to fetch: \(error.localizedDescription)")
        }
        isFetchingToolsAndFunctions = false
    }

    // MARK: - Handle Photo Selection

    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        logger.info("[ProfileImage] Photo selected, loading data...")
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                logger.error("[ProfileImage] Failed to load photo data — nil result")
                return
            }
            // Resize to reasonable size (max 512x512) before encoding
            guard let uiImage = UIImage(data: data) else {
                logger.error("[ProfileImage] Failed to create UIImage from data (size: \(data.count) bytes)")
                return
            }
            let resized = resizeImage(uiImage, maxDimension: 512)
            guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
                logger.error("[ProfileImage] Failed to encode image as JPEG")
                return
            }
            let base64 = jpegData.base64EncodedString()
            let dataURI = "data:image/jpeg;base64,\(base64)"

            selectedImageData = jpegData
            profileImageURL = dataURI
            logger.info("[ProfileImage] Photo encoded as data URI — original size: \(data.count) bytes, jpeg size: \(jpegData.count) bytes, data URI length: \(dataURI.count) chars")
        } catch {
            logger.error("[ProfileImage] Error loading photo: \(error.localizedDescription)")
        }
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxCurrent = max(size.width, size.height)
        guard maxCurrent > maxDimension else { return image }
        let scale = maxDimension / maxCurrent
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Build Detail from Form State

    private func buildDetail(id: String) -> ModelDetail {
        var detail = ModelDetail(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            baseModelId: baseModelId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : baseModelId.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description.trimmingCharacters(in: .whitespaces),
            profileImageURL: profileImageURL,
            tags: tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            isActive: isActive,
            accessGrants: localAccessGrants,
            writeAccess: existingModel?.writeAccess ?? true,
            userId: existingModel?.userId ?? "",
            createdAt: existingModel?.createdAt,
            updatedAt: existingModel?.updatedAt,
            systemPrompt: systemPrompt,
            capVision: capVision, capFileUpload: capFileUpload, capFileContext: capFileContext,
            capWebSearch: capWebSearch, capImageGeneration: capImageGeneration, capCodeInterpreter: capCodeInterpreter,
            capUsage: capUsage, capCitations: capCitations, capStatusUpdates: capStatusUpdates, capBuiltinTools: capBuiltinTools,
            defaultFeatureWebSearch: defaultWebSearch, defaultFeatureImageGen: defaultImageGen, defaultFeatureCodeInterpreter: defaultCodeInterpreter,
            builtinTime: builtinTime, builtinMemory: builtinMemory, builtinChats: builtinChats,
            builtinNotes: builtinNotes, builtinKnowledge: builtinKnowledge, builtinChannels: builtinChannels,
            builtinTaskManagement: builtinTaskManagement, builtinAutomations: builtinAutomations, builtinCalendar: builtinCalendar,
            builtinWebSearch: builtinWebSearch, builtinImageGen: builtinImageGen, builtinCodeInterpreter: builtinCodeInterpreter,
            knowledgeItems: knowledgeItems,
            suggestionPrompts: suggestionPrompts,
            ttsVoice: ttsVoice.trimmingCharacters(in: .whitespaces)
        )
        detail.advStreamResponse = advStreamResponse
        detail.advStreamDeltaChunkSize = advStreamDeltaChunkSize
        detail.advFunctionCalling = advFunctionCalling
        detail.advReasoningEffort = advReasoningEffort
        detail.advReasoningTagsEnabled = advReasoningTagsEnabled
        detail.advReasoningTagStart = advReasoningTagStart
        detail.advReasoningTagEnd = advReasoningTagEnd
        detail.advSeed = advSeed
        detail.advStopSequences = advStopSequences.map {
            $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        detail.advTemperature = advTemperature
        detail.advLogitBias = advLogitBias
        detail.advMaxTokens = advMaxTokens
        detail.advTopK = advTopK
        detail.advTopP = advTopP
        detail.advMinP = advMinP
        detail.advFrequencyPenalty = advFrequencyPenalty
        detail.advPresencePenalty = advPresencePenalty
        detail.advMirostat = advMirostat
        detail.advMirostatEta = advMirostatEta
        detail.advMirostatTau = advMirostatTau
        detail.advRepeatLastN = advRepeatLastN
        detail.advTfsZ = advTfsZ
        detail.advRepeatPenalty = advRepeatPenalty
        detail.advUseMmap = advUseMmap
        detail.advUseMlock = advUseMlock
        detail.advThink = advThink
        detail.advFormat = advFormat
        detail.advNumKeep = advNumKeep
        detail.advNumCtx = advNumCtx
        detail.advNumBatch = advNumBatch
        detail.advNumThread = advNumThread
        detail.advNumGpu = advNumGpu
        detail.advKeepAlive = advKeepAlive
        detail.customParams = customParams.filter { !$0.key.isEmpty }
        // Tools, Skills, Filters
        detail.toolIds = Array(selectedToolIds)
        // Filter IDs: exclude global filters (server applies them automatically).
        // Only save per-model filter selections.
        let globalFilterIds = Set(allFilters.filter(\.isGlobal).map(\.id))
        detail.filterIds = Array(selectedFilterIds.subtracting(globalFilterIds))
        detail.defaultFilterIds = Array(defaultFilterIds)
        // Action IDs: merge skill selections with non-global action function selections.
        // Global action functions are excluded — the server applies them automatically.
        // Filter out any action function IDs from selectedActionIds to avoid double-counting
        // (populateIfEditing puts all model.actionIds into selectedActionIds before we
        // know which ones are skills vs action functions).
        let allActionFunctionIds = Set(allActionFunctions.map(\.id))
        let globalActionIds = Set(allActionFunctions.filter(\.isGlobal).map(\.id))
        let skillOnlyIds = selectedActionIds.subtracting(allActionFunctionIds)
        let perModelActionFunctionIds = selectedActionFunctionIds.subtracting(globalActionIds)
        detail.actionIds = Array(skillOnlyIds) + Array(perModelActionFunctionIds)
        return detail
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedId = modelId.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the model."
            isSaving = false; return
        }
        guard !trimmedId.isEmpty else {
            validationError = "Please enter a Model ID."
            isSaving = false; return
        }

        var allGrants = localAccessGrants.filter { $0.userId != "*" }
        if !isPrivate {
            allGrants.append(AccessGrant(id: UUID().uuidString, userId: "*", groupId: nil, read: true, write: false))
        }

        do {
            if let existing = existingModel {
                var detail = buildDetail(id: existing.id)
                detail.accessGrants = allGrants

                let payload = detail.toUpdatePayload()
                logger.info("[Save] Updating model id='\(existing.id)' name='\(trimmedName)'")
                if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    logger.debug("[Save] Update payload:\n\(jsonString)")
                }

                var updated = try await manager.update(detail)
                logger.info("[Save] Model updated successfully: id='\(updated.id)'")

                let updatedGrants = try await manager.updateAccessGrants(
                    modelId: existing.id,
                    modelName: trimmedName,
                    grants: localAccessGrants.filter { $0.userId != "*" },
                    isPublic: !isPrivate
                )
                updated.accessGrants = updatedGrants
                onSave?(updated)
                NotificationCenter.default.post(name: .functionsConfigChanged, object: nil)
            } else {
                var detail = buildDetail(id: trimmedId)
                detail.accessGrants = allGrants

                let payload = detail.toCreatePayload()
                logger.info("[Save] Creating model id='\(trimmedId)' name='\(trimmedName)' baseModelId='\(baseModelId)'")
                if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    logger.debug("[Save] Create payload:\n\(jsonString)")
                }

                let created = try await manager.create(from: detail)
                logger.info("[Save] Model created successfully: id='\(created.id)' name='\(created.name)'")
                onSave?(created)
            }
            dismiss()
        } catch {
            logger.error("[Save] Error saving model: \(error.localizedDescription)")
            validationError = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Access Control Actions

    private func handleAccessModeChange(isPrivate: Bool) async {
        guard let id = existingModel?.id, let manager else { return }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: localAccessGrants,
                isPublic: !isPrivate
            )
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            self.isPrivate = !isPrivate
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func addGrants(userIds: [String], groupIds: [String]) async {
        guard let id = existingModel?.id, let manager else {
            for userId in userIds {
                if !localAccessGrants.contains(where: { $0.userId == userId }) {
                    localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
                }
            }
            for groupId in groupIds {
                if !localAccessGrants.contains(where: { $0.groupId == groupId }) {
                    localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: groupId, read: true, write: false))
                }
            }
            Haptics.notify(.success)
            return
        }
        isUpdatingAccess = true
        var newGrants = localAccessGrants
        for userId in userIds {
            if !newGrants.contains(where: { $0.userId == userId }) {
                newGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
            }
        }
        for groupId in groupIds {
            if !newGrants.contains(where: { $0.groupId == groupId }) {
                newGrants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: groupId, read: true, write: false))
            }
        }
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: newGrants
            )
            localAccessGrants = updated
            await resolveGroupNames()
            Haptics.notify(.success)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func togglePermission(principalId: String, isGroup: Bool, currentlyWrite: Bool) async {
        let idx: Array<AccessGrant>.Index?
        if isGroup {
            idx = localAccessGrants.firstIndex(where: { $0.groupId == principalId })
        } else {
            idx = localAccessGrants.firstIndex(where: { $0.userId == principalId })
        }
        guard let idx else { return }
        let old = localAccessGrants[idx]
        let newGrant = AccessGrant(id: old.id, userId: old.userId, groupId: old.groupId, read: true, write: !currentlyWrite)
        var newGrants = localAccessGrants
        newGrants[idx] = newGrant
        guard let id = existingModel?.id, let manager else {
            localAccessGrants = newGrants
            Haptics.play(.light)
            return
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: newGrants
            )
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func removeGrant(principalId: String, isGroup: Bool) async {
        guard let id = existingModel?.id, let manager else {
            if isGroup {
                localAccessGrants.removeAll { $0.groupId == principalId }
            } else {
                localAccessGrants.removeAll { $0.userId == principalId }
            }
            Haptics.play(.light)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            if isGroup {
                localAccessGrants.removeAll { $0.groupId == principalId }
            } else {
                localAccessGrants.removeAll { $0.userId == principalId }
            }
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: localAccessGrants
            )
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            if let detail = try? await manager.getDetail(id: id) {
                localAccessGrants = detail.accessGrants.filter { $0.userId != "*" }
            }
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func resolveGroupNames() async {
        guard let api = dependencies.apiClient else { return }
        let groupIds = Set(localAccessGrants.compactMap(\.groupId))
        let unknownIds = groupIds.subtracting(resolvedGroups.keys)
        guard !unknownIds.isEmpty else { return }
        do {
            let groups = try await api.getGroups()
            for g in groups where unknownIds.contains(g.id) {
                resolvedGroups[g.id] = g
            }
        } catch {}
    }

    private func persistActiveToggle(id: String?) async {
        guard let id, let manager else { return }
        logger.info("[Toggle] Toggling active state for model='\(id)' to isActive=\(isActive)")
        isTogglingActive = true
        do {
            try await manager.toggle(id: id)
            logger.info("[Toggle] Active state toggled successfully")
            Haptics.play(.light)
        } catch {
            isActive = !isActive
            initialIsActive = isActive
            accessUpdateError = error.localizedDescription
            logger.error("[Toggle] Error toggling active state: \(error.localizedDescription)")
            Haptics.notify(.error)
        }
        isTogglingActive = false
    }
}

// MARK: - BaseModelPickerSheet

struct BaseModelPickerSheet: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    var availableModels: [AIModel]
    var selectedModelId: String
    var serverBaseURL: String
    var authToken: String?
    var onSelect: (AIModel) -> Void
    var onClear: () -> Void
    var onDismiss: () -> Void

    @State private var searchText = ""

    private let logger = Logger(subsystem: "com.openui", category: "ModelEditor")

    private var filtered: [AIModel] {
        guard !searchText.isEmpty else { return availableModels }
        return availableModels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if availableModels.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "cpu")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(theme.textTertiary)
                        Text("未找到模型")
                            .scaledFont(size: 17, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text("无法从服务器加载可用模型。")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !selectedModelId.isEmpty {
                            Section {
                                Button {
                                    onClear()
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color.red.opacity(0.12))
                                                .frame(width: 36, height: 36)
                                            Image(systemName: "xmark")
                                                .scaledFont(size: 14, weight: .medium)
                                                .foregroundStyle(.red)
                                        }
                                        Text("无（清除选择）")
                                            .scaledFont(size: 15)
                                            .foregroundStyle(.red)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(theme.surfaceContainer.opacity(0.4))
                            }
                        }

                        Section {
                            ForEach(filtered) { model in
                                Button {
                                    logger.info("[BaseModelPicker] User selected model: id='\(model.id)' name='\(model.name)'")
                                    onSelect(model)
                                } label: {
                                    HStack(spacing: 12) {
                                        ModelAvatar(
                                            size: 36,
                                            imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                                            label: model.name,
                                            authToken: authToken
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(model.name)
                                                .scaledFont(size: 15, weight: .medium)
                                                .foregroundStyle(theme.textPrimary)
                                                .lineLimit(1)
                                            Text(model.id)
                                                .scaledFont(size: 12)
                                                .foregroundStyle(theme.textTertiary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if model.id == selectedModelId {
                                            Image(systemName: "checkmark.circle.fill")
                                                .scaledFont(size: 18)
                                                .foregroundStyle(theme.brandPrimary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(model.id == selectedModelId
                                    ? theme.brandPrimary.opacity(0.08)
                                    : theme.surfaceContainer.opacity(0.4))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle("选择基础模型")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索模型")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { onDismiss() }
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .onAppear {
            logger.info("[BaseModelPicker] Sheet opened. Available models: \(availableModels.count). Currently selected: '\(selectedModelId)'")
        }
    }
}

// MARK: - ModelAdvancedParamsSection (extracted child struct to prevent stack overflow)

/// All 30+ advanced parameter rows are in this separate struct so the Swift
/// compiler/runtime evaluates them in their own stack frame rather than
/// contributing to the parent's already-deep body evaluation.
struct ModelAdvancedParamsSection: View {
    @Environment(\.theme) private var theme

    @Binding var showAdvancedParams: Bool

    @Binding var advStreamResponse: Bool?
    @Binding var advStreamDeltaChunkSize: Int?
    @Binding var advFunctionCalling: String?
    @Binding var advReasoningEffort: String?
    @Binding var advReasoningTagsEnabled: Bool?
    @Binding var advReasoningTagStart: String?
    @Binding var advReasoningTagEnd: String?
    @Binding var advSeed: Int?
    @Binding var advStopSequences: String?
    @Binding var advTemperature: Double?
    @Binding var advLogitBias: String?
    @Binding var advMaxTokens: Int?
    @Binding var advTopK: Int?
    @Binding var advTopP: Double?
    @Binding var advMinP: Double?
    @Binding var advFrequencyPenalty: Double?
    @Binding var advPresencePenalty: Double?
    @Binding var advMirostat: Int?
    @Binding var advMirostatEta: Double?
    @Binding var advMirostatTau: Double?
    @Binding var advRepeatLastN: Int?
    @Binding var advTfsZ: Double?
    @Binding var advRepeatPenalty: Double?
    @Binding var advUseMmap: Bool?
    @Binding var advUseMlock: Bool?
    @Binding var advThink: Bool?
    @Binding var advFormat: String?
    @Binding var advNumKeep: Int?
    @Binding var advNumCtx: Int?
    @Binding var advNumBatch: Int?
    @Binding var advNumThread: Int?
    @Binding var advNumGpu: Int?
    @Binding var advKeepAlive: String?
    @Binding var customParams: [(key: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvancedParams.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack {
                    Text("高级参数")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 4)
                    Spacer()
                    Image(systemName: showAdvancedParams ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if showAdvancedParams {
                advancedParamsContent
            }
        }
    }

    // Split into two halves to keep individual body depth low
    private var advancedParamsContent: some View {
        VStack(spacing: 0) {
            advParamsFirstHalf
            advParamsSecondHalf
        }
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
        )
    }

    // First half: stream, function calling, reasoning, seed, stop, temperature, logit, max_tokens, top_k, top_p, min_p, freq, presence
    private var advParamsFirstHalf: some View {
        VStack(spacing: 0) {
            advBoolRow(label: "流式输出（stream）", value: $advStreamResponse)
            divider
            advIntSliderRow(label: "流式分块大小（stream_delta_chunk_size）", value: $advStreamDeltaChunkSize, range: 1...128, step: 1, defaultValue: 1)
            divider
            advNativeToggleRow(label: "函数调用（function_calling）", value: $advFunctionCalling)
            divider
            advTextRow(label: "推理强度（reasoning_effort）", placeholder: "例如 low、medium、high", value: $advReasoningEffort)
            divider
            advReasoningTagsRow
            divider
            advIntSliderRow(label: "随机种子（seed）", value: $advSeed, range: 0...9999, step: 1)
            divider
            advTextRow(label: "停止序列（stop）", placeholder: "多个值用英文逗号分隔", value: $advStopSequences)
            divider
            advDoubleSliderRow(label: "温度（temperature）", tooltip: "控制回答的随机性。数值越高越有创意，也更容易发散。", value: $advTemperature, range: 0...2, step: 0.05)
            divider
            advTextRow(label: "Token 偏置（logit_bias）", placeholder: "输入 token:bias_value，多个值用英文逗号分隔，例如 5432:100, 413:-100", value: $advLogitBias)
            divider
            advIntSliderRow(label: "最大 Token（max_tokens）", value: $advMaxTokens, range: 0...131072, step: 128)
            divider
            advIntSliderRow(label: "采样候选数（top_k）", tooltip: "每次只从概率最高的前 K 个候选词里挑选。数值越小越保守。", value: $advTopK, range: 0...1000, step: 1)
            divider
            advDoubleSliderRow(label: "核心采样概率（top_p）", tooltip: "只从累计概率最高的一组候选词里采样。数值越低越稳，越高越发散。", value: $advTopP, range: 0...1, step: 0.05)
            divider
            advDoubleSliderRow(label: "最小概率阈值（min_p）", tooltip: "过滤掉概率过低的候选词，减少跑偏和怪词。", value: $advMinP, range: 0...1, step: 0.05)
            divider
            advDoubleSliderRow(label: "频率惩罚（frequency_penalty）", tooltip: "降低已经频繁出现词语的概率，数值越高越少重复。", value: $advFrequencyPenalty, range: -2...2, step: 0.05)
            divider
            advDoubleSliderRow(label: "话题新鲜度惩罚（presence_penalty）", tooltip: "鼓励模型引入新内容，数值越高越容易换话题。", value: $advPresencePenalty, range: -2...2, step: 0.05)
        }
    }

    // Second half: mirostat, repeat, use_mmap, use_mlock, think, format, num_keep, num_ctx, num_batch, num_thread, num_gpu, keep_alive, custom
    private var advParamsSecondHalf: some View {
        VStack(spacing: 0) {
            divider
            VStack(alignment: .leading, spacing: 4) {
                Text("启用 Mirostat 采样，用来控制困惑度和输出稳定性。")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            advIntSliderRow(label: "困惑度控制模式（mirostat）", value: $advMirostat, range: 0...2, step: 1)
            divider
            advDoubleSliderRow(label: "困惑度学习率（mirostat_eta）", tooltip: nil, value: $advMirostatEta, range: 0...1, step: 0.01)
            divider
            advDoubleSliderRow(label: "困惑度目标值（mirostat_tau）", tooltip: nil, value: $advMirostatTau, range: 0...10, step: 0.1)
            divider
            advIntSliderRow(label: "重复检查范围（repeat_last_n）", value: $advRepeatLastN, range: 0...128, step: 1)
            divider
            advDoubleSliderRow(label: "尾部采样强度（tfs_z）", tooltip: nil, value: $advTfsZ, range: 0...2, step: 0.05)
            divider
            advDoubleSliderRow(label: "重复惩罚（repeat_penalty）", tooltip: nil, value: $advRepeatPenalty, range: 0...2, step: 0.01)
            divider
            advBoolRow(label: "使用内存映射（use_mmap）", value: $advUseMmap, defaultValue: true)
            divider
            advBoolRow(label: "锁定模型内存（use_mlock）", value: $advUseMlock, defaultValue: false)
            divider
            advBoolRow(label: "思考模式（think / Ollama）", value: $advThink)
            divider
            advTextRow(label: "输出格式（format / Ollama）", placeholder: "例如 json", value: $advFormat)
            divider
            advIntSliderRow(label: "保留上下文数（num_keep / Ollama）", value: $advNumKeep, range: 0...10240000, step: 1)
            divider
            advIntSliderRow(label: "上下文长度（num_ctx / Ollama）", value: $advNumCtx, range: 512...10240000, step: 512)
            divider
            advIntSliderRow(label: "批处理大小（num_batch / Ollama）", value: $advNumBatch, range: 256...8192, step: 256)
            divider
            advIntSliderRow(label: "线程数（num_thread / Ollama）", value: $advNumThread, range: 1...256, step: 1)
            divider
            VStack(alignment: .leading, spacing: 4) {
                Text("设置要卸载到 GPU 的层数。数值越高可能显著提升支持 GPU 加速模型的性能，但也会消耗更多电量和 GPU 资源。")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            advIntSliderRow(label: "GPU 层数（num_gpu / Ollama）", value: $advNumGpu, range: 0...256, step: 1)
            divider
            advTextRow(label: "保活时间（keep_alive / Ollama）", placeholder: "例如 5m", value: $advKeepAlive)
            divider
            customParamsSection
        }
    }

    private var divider: some View {
        Divider().background(theme.inputBorder.opacity(0.3))
    }

    // MARK: - Reasoning Tags Row
    // 4 states matching Iexa native server (cycling pill pattern):
    //   Default  → advReasoningTagsEnabled == nil && advReasoningTagStart == nil
    //   Enabled  → advReasoningTagsEnabled == true
    //   Disabled → advReasoningTagsEnabled == false
    //   Custom   → advReasoningTagStart != nil (advReasoningTagsEnabled ignored)

    private var currentReasoningIsCustom: Bool {
        advReasoningTagStart != nil
    }

    private var currentReasoningModeLabel: String {
        if currentReasoningIsCustom { return "自定义" }
        guard let enabled = advReasoningTagsEnabled else { return "默认" }
        return enabled ? "开启" : "关闭"
    }

    private var reasoningTagsIsActive: Bool {
        advReasoningTagsEnabled != nil || currentReasoningIsCustom
    }

    /// Cycle: Enabled → Disabled → Custom → Enabled
    private func cycleReasoningMode() {
        if currentReasoningIsCustom {
            // Custom → Enabled
            advReasoningTagStart = nil
            advReasoningTagEnd = nil
            advReasoningTagsEnabled = true
        } else if let enabled = advReasoningTagsEnabled {
            if enabled {
                // Enabled → Disabled
                advReasoningTagsEnabled = false
            } else {
                // Disabled → Custom
                advReasoningTagsEnabled = nil
                advReasoningTagStart = ""
                advReasoningTagEnd = ""
            }
        } else {
            // Default → Enabled (via initial activation)
            advReasoningTagsEnabled = true
        }
        Haptics.play(.light)
    }

    private var advReasoningTagsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("推理标签（Reasoning Tags）")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // Single pill cycles: Default → Enabled → Disabled → Custom → Default
                Button {
                    cycleReasoningMode()
                } label: {
                    Text(reasoningTagsIsActive ? currentReasoningModeLabel : "默认")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)

            // Custom text fields (only shown in Custom mode)
            if currentReasoningIsCustom {
                HStack(spacing: Spacing.md) {
                    TextField("<think>", text: Binding(
                        get: { advReasoningTagStart ?? "" },
                        set: { advReasoningTagStart = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    TextField("</think>", text: Binding(
                        get: { advReasoningTagEnd ?? "" },
                        set: { advReasoningTagEnd = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Custom Params Section

    private var customParamsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("自定义参数")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    customParams.append((key: "", value: ""))
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "plus.circle")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)

            ForEach(Array(customParams.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: Spacing.sm) {
                    TextField("键", text: Binding(
                        get: { customParams[idx].key },
                        set: { customParams[idx].key = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .frame(maxWidth: .infinity)

                    Text(":").foregroundStyle(theme.textTertiary)

                    TextField("值", text: Binding(
                        get: { customParams[idx].value },
                        set: { customParams[idx].value = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .frame(maxWidth: .infinity)

                    Button {
                        customParams.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)
                Divider().background(theme.inputBorder.opacity(0.3))
            }
        }
    }

    // MARK: - Reusable Pill

    private var defaultPill: some View {
        Text("默认")
            .scaledFont(size: 11)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.surfaceContainer)
            .clipShape(Capsule())
    }

    // MARK: - Row Builders

    /// Single cycling pill: Default → On → Off → Default
    @ViewBuilder
    private func advBoolRow(label: String, value: Binding<Bool?>, defaultValue: Bool = false) -> some View {
        let current = value.wrappedValue
        let currentLabel: String = {
            switch current {
            case .some(true):  return "开启"
            case .some(false): return "关闭"
            case .none:        return "默认"
            }
        }()
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                // Cycle: nil (Default) → true (On) → false (Off) → nil
                switch current {
                case .none:        value.wrappedValue = true
                case .some(true):  value.wrappedValue = false
                case .some(false): value.wrappedValue = nil
                }
                Haptics.play(.light)
            } label: {
                Text(currentLabel)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func advDoubleSliderRow(label: String, tooltip: String?, value: Binding<Double?>, range: ClosedRange<Double>, step: Double) -> some View {
        let isCustom = value.wrappedValue != nil
        VStack(alignment: .leading, spacing: 4) {
            if let tip = tooltip {
                Text(tip)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            HStack {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                Spacer()
                if isCustom {
                    Text(String(format: "%.2f", value.wrappedValue ?? 0))
                        .scaledFont(size: 12, weight: .semibold).foregroundStyle(theme.brandPrimary).monospacedDigit()
                    Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                } else {
                    Button { value.wrappedValue = (range.lowerBound + range.upperBound) / 2; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, tooltip == nil ? 10 : 2)

            if isCustom {
                Slider(value: Binding(get: { value.wrappedValue ?? range.lowerBound }, set: { value.wrappedValue = $0 }), in: range, step: step)
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }

    @ViewBuilder
    private func advIntSliderRow(label: String, tooltip: String? = nil, value: Binding<Int?>, range: ClosedRange<Double>, step: Double, defaultValue: Int? = nil) -> some View {
        let isCustom = value.wrappedValue != nil
        let activationValue = defaultValue ?? Int((range.lowerBound + range.upperBound) / 2)
        VStack(alignment: .leading, spacing: 4) {
            if let tooltip, !tooltip.isEmpty {
                Text(tooltip)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            HStack {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                Spacer()
                if isCustom {
                    Text("\(value.wrappedValue ?? 0)")
                        .scaledFont(size: 12, weight: .semibold).foregroundStyle(theme.brandPrimary).monospacedDigit()
                    Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                } else {
                    Button { value.wrappedValue = activationValue; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, tooltip == nil ? 10 : 2)

            if isCustom {
                Slider(value: Binding(get: { Double(value.wrappedValue ?? Int(range.lowerBound)) }, set: { value.wrappedValue = Int($0) }), in: range, step: step)
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }

    @ViewBuilder
    private func advTextRow(label: String, placeholder: String, value: Binding<String?>) -> some View {
        let isCustom = value.wrappedValue != nil
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                if isCustom {
                    TextField(placeholder, text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 }))
                        .scaledFont(size: 13).foregroundStyle(theme.textSecondary)
                        .autocorrectionDisabled().autocapitalization(.none)
                } else {
                    Text(placeholder).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            if isCustom {
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = ""; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    /// Single cycling pill for function_calling: Default → Native → Default
    @ViewBuilder
    private func advNativeToggleRow(label: String, value: Binding<String?>) -> some View {
        let isNative = value.wrappedValue == "native"
        let currentLabel = isNative ? "原生" : "默认"
        HStack {
            Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                value.wrappedValue = isNative ? nil : "native"
                Haptics.play(.light)
            } label: {
                Text(currentLabel)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func advPickerRow(label: String, value: Binding<String?>, options: [String]) -> some View {
        let isCustom = value.wrappedValue != nil
        HStack {
            Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
            Spacer()
            if isCustom {
                Picker("", selection: Binding(get: { value.wrappedValue ?? options.first ?? "" }, set: { value.wrappedValue = $0 })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).tint(theme.brandPrimary).scaledFont(size: 14)
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = options.first ?? ""; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }
}

// MARK: - ModelToolsAndCapabilitiesSection (extracted to prevent stack overflow)

/// Tools, Skills, Filters, Capabilities, Default Features, and Builtin Tools
/// are extracted into their own struct so they evaluate in a separate stack frame.
struct ModelToolsAndCapabilitiesSection: View {
    @Environment(\.theme) private var theme

    // Tools, Skills, Filters
    @Binding var selectedToolIds: Set<String>
    @Binding var allTools: [(id: String, name: String)]
    @Binding var isFetchingToolsAndFunctions: Bool
    @Binding var selectedActionIds: Set<String>
    @Binding var allActions: [(id: String, name: String)]
    /// Action-type functions with global/active state for the "Actions" section.
    @Binding var allActionFunctions: [(id: String, name: String, isGlobal: Bool)]
    @Binding var selectedActionFunctionIds: Set<String>
    @Binding var selectedFilterIds: Set<String>
    @Binding var defaultFilterIds: Set<String>
    @Binding var allFilters: [(id: String, name: String, isGlobal: Bool)]

    // Capabilities
    @Binding var capVision: Bool
    @Binding var capFileUpload: Bool
    @Binding var capFileContext: Bool
    @Binding var capWebSearch: Bool
    @Binding var capImageGeneration: Bool
    @Binding var capCodeInterpreter: Bool
    @Binding var capUsage: Bool
    @Binding var capCitations: Bool
    @Binding var capStatusUpdates: Bool
    @Binding var capBuiltinTools: Bool

    // Default Features
    @Binding var defaultWebSearch: Bool
    @Binding var defaultImageGen: Bool
    @Binding var defaultCodeInterpreter: Bool

    // Builtin Tools
    @Binding var builtinTime: Bool
    @Binding var builtinMemory: Bool
    @Binding var builtinChats: Bool
    @Binding var builtinNotes: Bool
    @Binding var builtinKnowledge: Bool
    @Binding var builtinChannels: Bool
    @Binding var builtinTaskManagement: Bool
    @Binding var builtinAutomations: Bool
    @Binding var builtinCalendar: Bool
    @Binding var builtinWebSearch: Bool
    @Binding var builtinImageGen: Bool
    @Binding var builtinCodeInterpreter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            toolsSectionView
            skillsSectionView
            filtersSectionView
            actionFunctionsSectionView
            capabilitiesSectionView
            defaultFeaturesSectionView
            builtinToolsSectionView
        }
    }

    // MARK: - Tools

    private var toolsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("工具")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("正在加载工具…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allTools.isEmpty {
                fieldCard {
                    Text("暂无可用工具。请先到“工具”工作区添加。")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary).padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allTools, id: \.id) { tool in
                            setCheckbox(tool.name, id: tool.id, selection: $selectedToolIds)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
                Text("要在这里选择工具包，请先到“工具”工作区添加。")
                    .scaledFont(size: 12).foregroundStyle(theme.textTertiary).padding(.leading, 4)
            }
        }
    }

    // MARK: - Skills

    private var skillsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("技能")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("正在加载技能…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allActions.isEmpty {
                fieldCard {
                    Text("暂无可用技能。请先到“技能”工作区添加。")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary).padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allActions, id: \.id) { action in
                            setCheckbox(action.name, id: action.id, selection: $selectedActionIds)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
                Text("要在这里选择技能，请先到“技能”工作区添加。")
                    .scaledFont(size: 12).foregroundStyle(theme.textTertiary).padding(.leading, 4)
            }
        }
    }

    // MARK: - Filters

    /// Shows filter functions with global lock support.
    /// Global filters are always checked and disabled (non-editable) with a 🔒 icon.
    /// Per-model filters are editable checkboxes.
    private var filtersSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("过滤器")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("正在加载过滤器…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allFilters.isEmpty {
                fieldCard {
                    Text("暂无可用过滤器。")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary).padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allFilters, id: \.id) { filter in
                            let isGlobal = filter.isGlobal
                            let isSelected = selectedFilterIds.contains(filter.id)
                            Button {
                                guard !isGlobal else { return }
                                if isSelected {
                                    selectedFilterIds.remove(filter.id)
                                } else {
                                    selectedFilterIds.insert(filter.id)
                                }
                                Haptics.play(.light)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .scaledFont(size: 16)
                                        .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                                    Text(filter.name).scaledFont(size: 13)
                                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    if isGlobal {
                                        Image(systemName: "lock.fill")
                                            .scaledFont(size: 9)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isGlobal)
                            .opacity(isGlobal ? 0.7 : 1.0)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
                let checkedFilters = allFilters.filter { selectedFilterIds.contains($0.id) }
                if !checkedFilters.isEmpty {
                    sectionHeader("默认过滤器")
                    fieldCard {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                            ForEach(checkedFilters, id: \.id) { filter in
                                setCheckbox(filter.name, id: filter.id, selection: $defaultFilterIds)
                            }
                        }
                        .padding(.vertical, 4).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    // MARK: - Action Functions

    /// Shows action-type functions (e.g. "Generate Image") with global lock support.
    /// Global actions are always checked and disabled (non-editable).
    /// Per-model actions are editable checkboxes.
    private var actionFunctionsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !allActionFunctions.isEmpty {
                sectionHeader("动作")
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allActionFunctions, id: \.id) { fn in
                            let isGlobal = fn.isGlobal
                            let isSelected = selectedActionFunctionIds.contains(fn.id)
                            Button {
                                guard !isGlobal else { return } // Global actions cannot be toggled
                                if isSelected {
                                    selectedActionFunctionIds.remove(fn.id)
                                } else {
                                    selectedActionFunctionIds.insert(fn.id)
                                }
                                Haptics.play(.light)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .scaledFont(size: 16)
                                        .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                                    Text(fn.name).scaledFont(size: 13)
                                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    if isGlobal {
                                        Image(systemName: "lock.fill")
                                            .scaledFont(size: 9)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isGlobal)
                            .opacity(isGlobal ? 0.7 : 1.0)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
            }
        }
    }

    // MARK: - Capabilities

    private var capabilitiesSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("能力")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("视觉识图", value: $capVision)
                    capCheckbox("文件上传", value: $capFileUpload)
                    capCheckbox("文件上下文", value: $capFileContext)
                    capCheckbox("联网搜索", value: $capWebSearch)
                    capCheckbox("图像生成", value: $capImageGeneration)
                    capCheckbox("代码解释器", value: $capCodeInterpreter)
                    capCheckbox("用量统计", value: $capUsage)
                    capCheckbox("引用来源", value: $capCitations)
                    capCheckbox("状态更新", value: $capStatusUpdates)
                    capCheckbox("内置工具", value: $capBuiltinTools)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Default Features

    private var defaultFeaturesSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("默认功能")
            fieldCard {
                HStack(spacing: 0) {
                    capCheckbox("联网搜索", value: $defaultWebSearch)
                    capCheckbox("图像生成", value: $defaultImageGen)
                    capCheckbox("代码解释器", value: $defaultCodeInterpreter)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Builtin Tools

    private var builtinToolsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("内置工具")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("时间和计算", value: $builtinTime)
                    capCheckbox("记忆", value: $builtinMemory)
                    capCheckbox("聊天记录", value: $builtinChats)
                    capCheckbox("笔记", value: $builtinNotes)
                    capCheckbox("知识库", value: $builtinKnowledge)
                    capCheckbox("频道", value: $builtinChannels)
                    capCheckbox("任务管理", value: $builtinTaskManagement)
                    capCheckbox("自动化", value: $builtinAutomations)
                    capCheckbox("日历", value: $builtinCalendar)
                    capCheckbox("联网搜索", value: $builtinWebSearch)
                    capCheckbox("图像生成", value: $builtinImageGen)
                    capCheckbox("代码解释器", value: $builtinCodeInterpreter)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func setCheckbox(_ label: String, id: String, selection: Binding<Set<String>>) -> some View {
        let isSelected = selection.wrappedValue.contains(id)
        Button {
            if isSelected { selection.wrappedValue.remove(id) } else { selection.wrappedValue.insert(id) }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                Text(label).scaledFont(size: 13)
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func capCheckbox(_ label: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(value.wrappedValue ? theme.brandPrimary : theme.textTertiary)
                Text(label).scaledFont(size: 13)
                    .foregroundStyle(value.wrappedValue ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
            )
    }
}
