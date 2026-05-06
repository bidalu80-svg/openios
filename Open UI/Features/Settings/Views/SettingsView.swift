import SwiftUI
import AVFoundation
import Speech
import UserNotifications

/// Main settings view with profile, appearance, server, privacy, and about sections.
/// Matches the Flutter app's "You" / profile page layout with all customization options.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @Bindable var viewModel: AuthViewModel
    @Bindable var appearanceManager: AppearanceManager
    @State private var showSignOutConfirmation = false
    @State private var navigationPath = NavigationPath()
    @State private var showDefaultModelPicker = false
    @State private var showLanguagePicker = false
    @State private var showRestartAlert = false
    @State private var availableModels: [AIModel] = []
    @State private var defaultModelId: String?
    @State private var isLoadingModels = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: Spacing.sectionGap) {
                    // Profile header
                    if let user = viewModel.currentUser {
                        SettingsSection(header: "账号") {
                            SettingsProfileHeader(
                                name: user.displayName,
                                email: user.email,
                                avatarURL: profileImageURL(for: user),
                                authToken: dependencies.apiClient?.network.authToken
                            ) {
                                navigationPath.append(SettingsDestination.profile)
                            }
                        }
                    }

                    // Admin Console (only visible to admin users — placed prominently)
                    if viewModel.currentUser?.role == .admin {
                        SettingsSection(header: "管理") {
                            SettingsCell(
                                icon: "shield.lefthalf.filled",
                                title: "管理员控制台",
                                subtitle: "管理用户和角色",
                                iconColor: .orange,
                                showDivider: false,
                                accessory: .chevron
                            ) {
                                navigationPath.append(SettingsDestination.adminConsole)
                            }
                        }
                    }

                    // Default Model
                    SettingsSection(header: "默认模型") {
                        SettingsCell(
                            icon: "cpu",
                            title: "默认模型",
                            subtitle: defaultModelDisplayName,
                            showDivider: false,
                            accessory: isLoadingModels ? .loading : .chevron
                        ) {
                            showDefaultModelPicker = true
                        }
                    }

                                    // Display & Customization
                    SettingsSection(header: "显示") {
                        SettingsCell(
                            icon: "paintbrush",
                            title: "外观",
                            subtitle: appearanceManager.colorSchemeMode.displayName,
                            showDivider: true,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.appearance)
                        }
                        SettingsCell(
                            icon: "textformat.size",
                            title: "辅助功能",
                            subtitle: dependencies.accessibilityManager.isCustomized
                                ? (dependencies.accessibilityManager.matchingPreset?.displayName ?? "自定义")
                                : "标准",
                            iconColor: .purple,
                            showDivider: true,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.accessibility)
                        }
                        SettingsCell(
                            icon: "globe",
                            title: "语言",
                            subtitle: currentLanguageDisplayName,
                            iconColor: .blue,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            showLanguagePicker = true
                        }
                    }

                    // Chat Settings
                    SettingsSection(header: "聊天") {
                        SettingsCell(
                            icon: "bubble.left.and.bubble.right",
                            title: "聊天行为",
                            subtitle: "触感、标题、建议",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.chatSettings)
                        }
                    }

                    // Voice
                    SettingsSection(header: "语音") {
                        SettingsCell(
                            icon: "waveform",
                            title: "文本转语音",
                            subtitle: "语音和速度设置",
                            showDivider: true,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.ttsSettings)
                        }
                        SettingsCell(
                            icon: "mic",
                            title: "语音转文字",
                            subtitle: "语音输入设置",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.sttSettings)
                        }
                    }

                    // Notifications
                    SettingsSection(header: "通知") {
                        SettingsCell(
                            icon: "bell.badge",
                            title: "通知",
                            subtitle: notificationStatusSubtitle,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.notifications)
                        }
                    }

                    // Site & Connection
                    SettingsSection(header: "站点") {
                        SettingsCell(
                            icon: "server.rack",
                            title: "站点配置",
                            subtitle: viewModel.serverURL,
                            showDivider: true,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.serverManagement)
                        }

                        SettingsCell(
                            icon: "arrow.left.arrow.right.circle",
                            title: "管理站点",
                            subtitle: viewModel.savedServers.count == 1
                                ? "已保存 1 个站点"
                                : "已保存 \(viewModel.savedServers.count) 个站点",
                            iconColor: .teal,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.serverSwitcher)
                        }
                    }

                    // Personalization
                    SettingsSection(header: "个性化") {
                        SettingsCell(
                            icon: "brain",
                            title: "记忆",
                            subtitle: "AI 记住的与你有关的信息",
                            iconColor: .purple,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.memories)
                        }
                    }

                    // Storage
                    SettingsSection(header: "存储") {
                        SettingsCell(
                            icon: "internaldrive",
                            title: "存储",
                            subtitle: "文件、模型和缓存",
                            iconColor: .blue,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.storage)
                        }
                    }

                    // Privacy & Security
                    SettingsSection(header: "隐私与安全") {
                        SettingsCell(
                            icon: "lock.shield",
                            title: "隐私与安全",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.privacySecurity)
                        }
                    }

                    // About
                    SettingsSection(header: "关于") {
                        SettingsCell(
                            icon: "info.circle",
                            title: "关于 Iexa",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.about)
                        }
                    }

                    // Sign out
                    SettingsSection {
                        DestructiveSettingsCell(
                            icon: "rectangle.portrait.and.arrow.right",
                            title: "退出登录"
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showSignOutConfirmation = true
                            }
                            Haptics.play(.medium)
                        }
                    }
                }
                .padding(.vertical, Spacing.lg)
            }
            .background(theme.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(Color.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .systemGray5).opacity(0.6))
                            .clipShape(Circle())
                    }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .profile:
                    ProfileView(viewModel: viewModel)
                case .appearance:
                    AppearanceSettingsView(manager: appearanceManager)
                case .accessibility:
                    AccessibilitySettingsView(manager: dependencies.accessibilityManager)
                case .serverManagement:
                    ServerManagementView(viewModel: viewModel)
                case .serverSwitcher:
                    ScrollView {
                        SavedServersView(viewModel: viewModel, showAddServerButton: true)
                    }
                    .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                    .navigationTitle("管理站点")
                    .navigationBarTitleDisplayMode(.inline)
                case .privacySecurity:
                    PrivacySecurityView()
                case .about:
                    AboutView(viewModel: viewModel)
                case .chatSettings:
                    ChatSettingsView()
                case .ttsSettings:
                    TTSSettingsView()
                case .sttSettings:
                    STTSettingsView()
                case .notifications:
                    NotificationSettingsView()
                case .adminConsole:
                    AdminConsoleView()
                case .memories:
                    MemoriesView()
                case .storage:
                    StorageSettingsView()
                }
            }
            .sheet(isPresented: $showDefaultModelPicker) {
                DefaultModelPickerView(
                    models: availableModels,
                    selectedModelId: $defaultModelId,
                    onSave: saveDefaultModel
                )
            }
            .sheet(isPresented: $showLanguagePicker) {
                LanguagePickerView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSignOutConfirmation) {
                SignOutConfirmationSheet(
                    onSignOut: {
                        showSignOutConfirmation = false
                        Task {
                            await viewModel.signOut()
                            dismiss()
                        }
                    },
                    onSignOutAndRemove: {
                        showSignOutConfirmation = false
                        Task {
                            await viewModel.signOutAndDisconnect()
                            dismiss()
                        }
                    },
                    onCancel: {
                        showSignOutConfirmation = false
                    }
                )
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
            }
            .task {
                await loadModels()
            }
        }
    }

    /// The display name of the currently active app language.
    private var currentLanguageDisplayName: String {
        let langs = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        if let first = langs.first, !first.hasPrefix("en") {
            let locale = Locale(identifier: first)
            // Show native name in that language
            if let native = locale.localizedString(forIdentifier: first) {
                return native
            }
        }
        return "跟随系统"
    }

    private var notificationStatusSubtitle: String {
        NotificationService.shared.isAuthorized ? "已开启" : "已关闭"
    }

    private var defaultModelDisplayName: String {
        if isLoadingModels { return "加载中..." }
        if let id = defaultModelId, let model = availableModels.first(where: { $0.id == id }) {
            return model.name
        }
        return "自动选择"
    }

    private func loadModels() async {
        guard let manager = dependencies.conversationManager else { return }
        isLoadingModels = true
        do {
            availableModels = try await manager.fetchModels()
            if let localDefaultModelId = ActiveChatStore.persistedExplicitDefaultModelId() {
                defaultModelId = localDefaultModelId
            } else if manager.usesLocalConversationStore {
                defaultModelId = nil
            } else {
                defaultModelId = await manager.fetchUserDefaultModel()
            }
        } catch {}
        isLoadingModels = false
    }

    private func saveDefaultModel(_ modelId: String?) {
        defaultModelId = modelId
        dependencies.activeChatStore.updateDefaultModelSelection(modelId)

        if dependencies.conversationManager?.usesLocalConversationStore == true {
            return
        }

        // Save to user settings on server.
        // Use merge helper so we ONLY update `models` without overwriting
        // `memory`, `pinnedModels`, or any other ui keys.
        Task {
            guard let api = dependencies.apiClient else { return }
            do {
                let models: [String] = modelId.map { [$0] } ?? []
                try await api.mergeUserUISettings(["models": models])
                await MainActor.run {
                    defaultModelId = modelId
                    dependencies.activeChatStore.updateDefaultModelSelection(modelId)
                }
            } catch {
                await MainActor.run {
                    // Keep the user's choice working locally even if this server build
                    // rejects the settings endpoint; surface the failure instead of
                    // silently making Save look broken.
                    defaultModelId = modelId
                    dependencies.activeChatStore.updateDefaultModelSelection(modelId)
                }
            }
        }
    }

    private func profileImageURL(for user: User) -> URL? {
        guard let baseURL = dependencies.apiClient?.baseURL,
              !user.id.isEmpty, !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/api/v1/users/\(user.id)/profile/image?v=\(viewModel.profileImageVersion)")
    }
}

// MARK: - Settings Navigation Destinations

enum SettingsDestination: Hashable {
    case profile
    case appearance
    case accessibility
    case serverManagement
    case serverSwitcher
    case privacySecurity
    case about
    case chatSettings
    case ttsSettings
    case sttSettings
    case notifications
    case adminConsole
    case memories
    case storage
}

// MARK: - Default Model Picker

struct DefaultModelPickerView: View {
    let models: [AIModel]
    @Binding var selectedModelId: String?
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @State private var localSelection: String?

    private var filteredModels: [AIModel] {
        if searchText.isEmpty { return models }
        let q = searchText.lowercased()
        return models.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Auto-select option
                Button {
                    localSelection = nil
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(theme.brandPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动选择")
                                .scaledFont(size: 16)
                                .fontWeight(.semibold)
                            Text("使用服务器默认模型。")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                        Spacer()
                        if localSelection == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.brandPrimary)
                        }
                    }
                }
                .listRowBackground(
                    localSelection == nil ? theme.brandPrimary.opacity(0.08) : Color.clear
                )

                // Model list
                ForEach(filteredModels) { model in
                    Button {
                        localSelection = model.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                                HStack(spacing: 4) {
                                    if model.isMultimodal {
                                        Label("视觉", systemImage: "photo")
                                            .scaledFont(size: 10)
                                            .foregroundStyle(theme.brandPrimary)
                                    }
                                }
                            }
                            Spacer()
                            if localSelection == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.brandPrimary)
                            }
                        }
                    }
                    .listRowBackground(
                        localSelection == model.id ? theme.brandPrimary.opacity(0.08) : Color.clear
                    )
                }
            }
            .searchable(text: $searchText, prompt: "搜索模型")
            .navigationTitle("默认模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(localSelection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            localSelection = selectedModelId
        }
    }
}

// MARK: - Chat Settings View

struct ChatSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @AppStorage("sendOnEnter") private var sendOnEnter = true
    @AppStorage("streamingHaptics") private var streamingHaptics = true
    @AppStorage("titleGenerationEnabled") private var titleGenerationEnabled = true
    @AppStorage("suggestionsEnabled") private var suggestionsEnabled = true
    @AppStorage("temporaryChatDefault") private var temporaryChatDefault = false
    @AppStorage("expandThinkingWhileStreaming") private var expandThinkingWhileStreaming = true
    @AppStorage("citationShowDomain") private var citationShowDomain: Bool = true
    @AppStorage("quickPills") private var quickPillsData: String = ""
    @State private var availableTools: [ToolItem] = []
    @State private var isLoadingTools = false

    /// Whether the server admin has enabled title generation globally.
    private var serverTitleGenEnabled: Bool {
        dependencies.taskConfig.enableTitleGeneration
    }

    /// Whether the server admin has enabled follow-up generation globally.
    private var serverFollowUpGenEnabled: Bool {
        dependencies.taskConfig.enableFollowUpGeneration
    }

    private var selectedPillIds: Set<String> {
        Set(quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private func togglePill(_ id: String) {
        var ids = quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty }
        if ids.contains(id) {
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
        quickPillsData = ids.joined(separator: ",")
        Haptics.play(.light)
    }

    var body: some View {
        List {
            Section("输入行为") {
                Toggle("回车发送", isOn: $sendOnEnter)
                    .tint(theme.brandPrimary)
                Text("开启后按回车会发送消息；关闭后回车会换行。")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .listRowSeparator(.hidden)
            }

            Section {
                Toggle("流式输出时触感反馈", isOn: $streamingHaptics)
                    .tint(theme.brandPrimary)
            } header: {
                Text("触感")
            } footer: {
                Text("模型逐字输出时会有轻微触感反馈。")
            }

            Section {
                Toggle("自动生成聊天标题", isOn: $titleGenerationEnabled)
                    .tint(theme.brandPrimary)
                    .disabled(!serverTitleGenEnabled)
                Toggle("显示追问建议", isOn: $suggestionsEnabled)
                    .tint(theme.brandPrimary)
                    .disabled(!serverFollowUpGenEnabled)
            } header: {
                Text("生成")
            } footer: {
                if !serverTitleGenEnabled || !serverFollowUpGenEnabled {
                    Text("部分选项已被服务器管理员禁用。")
                } else {
                    Text("关闭标题生成可降低服务器负载；追问建议会显示在回复末尾。")
                }
            }

            Section {
                Toggle("默认临时聊天", isOn: $temporaryChatDefault)
                    .tint(theme.brandPrimary)
            } header: {
                Text("隐私")
            } footer: {
                Text("临时聊天不会保存到服务器，也可以手动保存。")
            }

            Section {
                Toggle("思考时自动展开", isOn: $expandThinkingWhileStreaming)
                    .tint(theme.brandPrimary)
            } header: {
                Text("思考过程")
            } footer: {
                Text("开启后模型思考时会自动展开推理内容，完成后收起；关闭后需要手动点开。")
            }

            Section {
                Toggle("引用显示域名", isOn: $citationShowDomain)
                    .tint(theme.brandPrimary)
            } header: {
                Text("引用")
            } footer: {
                Text("开启后引用徽标显示网站域名；关闭后显示页面标题。")
            }

            Section {
                Text("选择消息输入框下方显示的快捷操作，点击可切换。")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .listRowSeparator(.hidden)

                // Built-in pills
                quickPillToggle(id: "web", icon: "magnifyingglass", name: "网页搜索")
                quickPillToggle(id: "image", icon: "photo", name: "图像生成")

                // Server tools
                if isLoadingTools {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在加载工具…")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                } else {
                    ForEach(availableTools, id: \.id) { tool in
                        quickPillToggle(id: tool.id, icon: "wrench", name: tool.name)
                    }
                }

                if !selectedPillIds.isEmpty {
                    Button(role: .destructive) {
                        quickPillsData = ""
                        Haptics.play(.medium)
                    } label: {
                        Label("清空所有快捷操作", systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text("快捷操作")
            } footer: {
                Text("已选择 \(selectedPillIds.count) 个操作")
            }
        }
        .navigationTitle("聊天设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTools()
        }
    }

    private func quickPillToggle(id: String, icon: String, name: String) -> some View {
        let isSelected = selectedPillIds.contains(id)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                togglePill(id)
            }
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        (isSelected ? theme.brandPrimary : theme.textSecondary).opacity(0.12)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(name)
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 20)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadTools() async {
        guard let manager = dependencies.conversationManager else { return }
        isLoadingTools = true
        do {
            availableTools = try await manager.fetchTools()
        } catch {}
        isLoadingTools = false
    }
}

// MARK: - TTS Settings View

struct TTSSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @AppStorage("ttsSpeechRate") private var speechRate = 1.0
    @AppStorage("ttsVoiceIdentifier") private var voiceIdentifier: String = ""
    @AppStorage("ttsEngine") private var selectedEngine: String = "system"
    @AppStorage("ttsOnDeviceModel") private var onDeviceModelRaw: String = "kokoro"
    @AppStorage("ttsKokoroVoice") private var kokoroVoice: String = "af_heart"
    @AppStorage("ttsKokoroSpeed") private var kokoroSpeed: Double = 1.0
    @AppStorage("ttsQwen3Voice") private var qwen3Voice: String = "Aiden"
    @AppStorage("ttsQwen3Language") private var qwen3Language: String = "auto"
    @AppStorage("ttsServerVoiceId") private var serverVoiceId: String = ""
    @State private var isSpeaking = false
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var isDownloadingModel = false
    @State private var kokoroModelSize: String = "–"
    @State private var qwen3ModelSize: String = "–"
    @State private var serverVoices: [(id: String, name: String)] = []
    @State private var isLoadingServerVoices = false
    /// Model name configured on the server (from /api/v1/audio/config).
    @State private var serverConfiguredModel: String = ""
    /// Whether we're currently loading the audio config from the server.
    @State private var isLoadingServerConfig = false

    private var ttsService: TextToSpeechService {
        dependencies.textToSpeechService
    }

    private var selectedOnDeviceModel: OnDeviceTTSModel {
        OnDeviceTTSModel(rawValue: onDeviceModelRaw) ?? .kokoro
    }

    private var engineOptions: [(String, String, String)] {
        var options: [(String, String, String)] = [
            ("auto",     "自动",           "最佳可用：本地 → 服务器 → 系统"),
            ("system",   "系统（Apple）", "内置 AVSpeechSynthesizer"),
        ]
        if ttsService.isServerAvailable {
            options.insert(
                ("server", "服务器", "服务器端 TTS"),
                at: options.count - 1
            )
        }
        if ttsService.isKokoroAvailable {
            options.insert(
                ("ondevice", "本地", "在设备上运行的神经语音"),
                at: 1
            )
        }
        return options
    }

    var body: some View {
        List {
            // Engine Selection
            Section {
                ForEach(engineOptions, id: \.0) { value, label, description in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedEngine = value
                        }
                        syncEngineToService()
                        Haptics.play(.light)
                    } label: {
                        HStack(spacing: Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Spacing.xs) {
                                    Text(label)
                                        .scaledFont(size: 16)
                                        .fontWeight(.medium)
                                        .foregroundStyle(theme.textPrimary)

                                    if value == "qwen3" {
                                        Text("新")
                                            .scaledFont(size: 9, weight: .heavy)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(
                                                    LinearGradient(
                                                        colors: [theme.brandPrimary, theme.brandPrimary.opacity(0.7)],
                                                        startPoint: .leading,
                                                        endPoint: .trailing
                                                    )
                                                )
                                            )
                                    }
                                }

                                Text(description)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }

                            Spacer()

                            Image(systemName: selectedEngine == value ? "checkmark.circle.fill" : "circle")
                                .scaledFont(size: 22)
                                .foregroundStyle(
                                    selectedEngine == value ? theme.brandPrimary : theme.textTertiary.opacity(0.4)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("语音合成引擎")
            } footer: {
                if selectedEngine == "auto" {
                    Text("自动模式会优先使用已加载的本地模型，否则回退到服务器或系统语音。")
                } else if selectedEngine == "kokoro" {
                    Text("Kokoro 在本机运行，支持 9 种语言共 54 个声音。")
                } else if selectedEngine == "qwen3" {
                    Text("Qwen3 在本机运行，支持英语、韩语、德语、西班牙语等 11 种语言。")
                }
            }

            // On-Device Model Settings (unified section with model picker)
            if selectedEngine == "ondevice" && ttsService.isKokoroAvailable {
                let isKokoro = selectedOnDeviceModel == .kokoro

                Section {
                    // Model selector — segmented picker inside the section
                    Picker("模型", selection: $onDeviceModelRaw) {
                        Text("Kokoro").tag(OnDeviceTTSModel.kokoro.rawValue)
                        Text("Qwen3").tag(OnDeviceTTSModel.qwen3.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                    .onChange(of: onDeviceModelRaw) { _, _ in syncEngineToService() }

                    // Model status
                    HStack {
                        Text("状态")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        onDeviceStatusBadge
                    }

                    if isKokoro {
                        // Kokoro: Voice picker grouped by language
                        Picker("声音", selection: $kokoroVoice) {
                            ForEach(KokoroVoiceCatalog.groups, id: \.language) { group in
                                Section(header: Text("\(group.flag) \(group.language)")) {
                                    ForEach(group.voices, id: \.id) { voice in
                                        Text(voice.name).tag(voice.id)
                                    }
                                }
                            }
                        }
                        .onChange(of: kokoroVoice) { _, _ in syncKokoroConfig() }

                        // Speed slider (Kokoro only)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack {
                                Text("速度")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(String(format: "%.1f×", kokoroSpeed))
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Slider(value: $kokoroSpeed, in: 0.5...2.0, step: 0.1)
                                .tint(theme.brandPrimary)
                                .onChange(of: kokoroSpeed) { _, _ in syncKokoroConfig() }
                        }
                    } else {
                        // Qwen3: Speaker picker
                        Picker("说话人", selection: $qwen3Voice) {
                            ForEach(Qwen3VoiceCatalog.groups, id: \.language) { group in
                                Section(header: Text("\(group.flag) \(group.language)")) {
                                    ForEach(group.voices, id: \.id) { voice in
                                        Text(voice.name).tag(voice.id)
                                    }
                                }
                            }
                        }
                        .onChange(of: qwen3Voice) { _, _ in syncQwen3Config() }

                        // Qwen3: Language picker
                        Picker("语言", selection: $qwen3Language) {
                            ForEach(Qwen3VoiceCatalog.supportedLanguages, id: \.id) { lang in
                                Text(lang.name).tag(lang.id)
                            }
                        }
                        .onChange(of: qwen3Language) { _, _ in syncQwen3Config() }

                    }

                    // Load / Download / Unload controls
                    onDeviceModelControls(isKokoro: isKokoro)

                } header: {
                    Text("本地神经语音")
                } footer: {
                    if isKokoro {
                        Text("Kokoro · 54 个声音 · 9 种语言。首次使用会从 HuggingFace 下载。")
                    } else {
                        Text("Qwen3 · 7 个说话人 · 11 种语言。说话人决定音色，任意说话人都可朗读任意语言。")
                    }
                }
            }

            // Server TTS Settings (shown when server engine is selected)
            if selectedEngine == "server" && ttsService.isServerAvailable {
                // --- Model info (from /api/v1/audio/config) ---
                Section {
                    if isLoadingServerConfig {
                        HStack(spacing: Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("正在加载服务器配置…")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                        }
                    } else {
                        HStack {
                            Text("模型")
                            Spacer()
                            Text(serverConfiguredModel.isEmpty ? "未配置" : serverConfiguredModel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Button {
                            Task { await loadServerConfig() }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .scaledFont(size: 14, weight: .medium)
                                Text("刷新配置")
                                    .scaledFont(size: 14)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                    }
                } header: {
                    Text("服务器 TTS 模型")
                } footer: {
                    Text("当前服务器上配置的语音合成模型（/api/v1/audio/config）。")
                }

                // --- Voice picker ---
                Section {
                    if isLoadingServerVoices {
                        HStack(spacing: Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("正在从服务器加载声音…")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                        }
                    } else if serverVoices.isEmpty {
                        HStack {
                            Text("声音")
                            Spacer()
                            Text(serverVoiceId.isEmpty ? "服务器默认" : serverVoiceId)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Button {
                            Task { await loadServerVoices() }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .scaledFont(size: 14, weight: .medium)
                                Text("加载可用声音")
                                    .scaledFont(size: 14)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                    } else {
                        Picker("声音", selection: $serverVoiceId) {
                            Text("服务器默认").tag("")
                            ForEach(serverVoices, id: \.id) { voice in
                                Text(voice.name).tag(voice.id)
                            }
                        }
                        .onChange(of: serverVoiceId) { _, newValue in
                            ttsService.serverVoiceId = newValue.isEmpty ? nil : newValue
                        }
                    }
                } header: {
                    Text("服务器声音")
                } footer: {
                    Text("当前服务器可用的声音。默认值会使用服务器配置的声音。")
                }
            }

            // System Voice Settings (only when system engine is selected)
            if selectedEngine == "system" || selectedEngine == "auto" {
                Section {
                    NavigationLink {
                        TTSVoicePickerView(
                            voiceIdentifier: $voiceIdentifier,
                            voices: availableVoices
                        )
                        .onChange(of: voiceIdentifier) { _, _ in
                            syncSettingsToService()
                        }
                    } label: {
                        HStack {
                            Text("声音")
                            Spacer()
                            Text(
                                voiceIdentifier.isEmpty
                                    ? "自动（检测语言）"
                                    : (AVSpeechSynthesisVoice(identifier: voiceIdentifier)?.name ?? voiceIdentifier)
                            )
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("速度")
                            Spacer()
                            Text("\(Int(speechRate * 100))%")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        Slider(value: $speechRate, in: 0.25...2.0, step: 0.05)
                            .tint(theme.brandPrimary)
                            .onChange(of: speechRate) { _, _ in
                                syncSettingsToService()
                            }
                    }
                } header: {
                    Text("系统语音")
                } footer: {
                    Text("这些设置会在使用 Apple 内置语音合成器时生效。")
                }
            }

            // Preview
            Section {
                Button {
                    previewVoice()
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: isSpeaking ? "stop.fill" : "play.fill")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(isSpeaking ? theme.error : theme.brandPrimary)
                        Text(isSpeaking ? "停止试听" : "试听语音")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if isSpeaking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            let engineLabel: String = {
                                switch selectedEngine {
                                case "ondevice": return selectedOnDeviceModel == .qwen3 ? "Qwen3" : "Kokoro"
                                case "kokoro":   return "Kokoro"
                                case "qwen3":    return "Qwen3"
                                case "server":   return "服务器"
                                case "system":   return "系统"
                                default:         return "自动"
                                }
                            }()
                            Text(engineLabel)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            } footer: {
                Text("点击试听，听听当前声音效果。")
            }

            // Model Storage Management
            Section {
                HStack {
                    Text("Kokoro 语音模型")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(kokoroModelSize)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        ttsService.kokoroService.config.activeModel = .kokoro
                        ttsService.kokoroService.unloadAndDeleteModel()
                        refreshModelSizes()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }

                HStack {
                    Text("Qwen3 语音模型")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(qwen3ModelSize)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        ttsService.kokoroService.config.activeModel = .qwen3
                        ttsService.kokoroService.unloadAndDeleteModel()
                        refreshModelSizes()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            } header: {
                Text("模型存储")
            } footer: {
                Text("在模型行上向左滑动即可从磁盘删除并释放空间。")
            }
        }
        .navigationTitle("文本转语音")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            availableVoices = dependencies.textToSpeechService.availableVoices()
            syncSettingsToService()
            syncEngineToService()
            syncKokoroConfig()
            syncQwen3Config()
            refreshModelSizes()
        }
        .task {
            // Always fetch fresh config from server when the user opens this screen
            if ttsService.isServerAvailable {
                await loadServerConfig()
                await loadServerVoices()
            }
        }
    }

    // MARK: - On-Device Status Badge

    @ViewBuilder
    private var onDeviceStatusBadge: some View {
        switch ttsService.kokoroState {
        case .unloaded:
            statusPill("未加载", color: theme.textTertiary)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("正在下载…")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.warning)
            }
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("加载中...")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        case .ready:
            statusPill("已就绪", color: theme.success)
        case .generating:
            statusPill("生成中...", color: theme.brandPrimary)
        case .error(let msg):
            statusPill("错误", color: theme.error)
                .help(msg)
        }
    }

    @ViewBuilder
    private func onDeviceModelControls(isKokoro: Bool) -> some View {
        switch ttsService.kokoroState {
        case .unloaded:
            Button {
                preloadOnDeviceModel()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "arrow.down.circle")
                        .scaledFont(size: 16, weight: .medium)
                    Text("下载并加载模型")
                        .scaledFont(size: 16)
                        .fontWeight(.medium)
                }
                .foregroundStyle(theme.brandPrimary)
            }
        case .downloading:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在下载模型…")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                ProgressView()
                    .tint(theme.brandPrimary)
                Text("请保持 App 打开")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
        case .ready:
            Button(role: .destructive) {
                ttsService.unloadKokoroModel()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "xmark.circle")
                        .scaledFont(size: 16, weight: .medium)
                    Text("卸载模型（释放内存）")
                        .scaledFont(size: 16)
                        .fontWeight(.medium)
                }
            }
            Button(role: .destructive) {
                ttsService.kokoroService.unloadAndDeleteModel()
                refreshModelSizes()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "trash.circle")
                        .scaledFont(size: 16, weight: .medium)
                    Text("删除已下载模型")
                        .scaledFont(size: 16)
                        .fontWeight(.medium)
                }
            }
        case .error:
            Button {
                retryOnDeviceLoad()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "arrow.clockwise.circle")
                        .scaledFont(size: 16, weight: .medium)
                    Text("重新下载")
                        .scaledFont(size: 16)
                        .fontWeight(.medium)
                }
                .foregroundStyle(theme.warning)
            }
        case .loading, .generating:
            EmptyView()
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text))
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func syncSettingsToService() {
        let service = dependencies.textToSpeechService
        service.speechRate = Float(speechRate) * AVSpeechUtteranceDefaultSpeechRate
        service.voiceIdentifier = voiceIdentifier.isEmpty ? nil : voiceIdentifier
        service.serverVoiceId = serverVoiceId.isEmpty ? nil : serverVoiceId
    }

    /// Fetches the server's audio config from `/api/v1/audio/config`.
    @MainActor
    private func loadServerConfig() async {
        guard let apiClient = dependencies.apiClient else { return }
        isLoadingServerConfig = true
        defer { isLoadingServerConfig = false }
        do {
            let config = try await apiClient.getAudioConfig()
            if let tts = config["tts"] as? [String: Any] {
                let model = (tts["MODEL"] as? String) ?? ""
                serverConfiguredModel = model
                let configVoice = (tts["VOICE"] as? String) ?? ""
                if !configVoice.isEmpty {
                    ttsService.serverDefaultVoice = configVoice
                    if serverVoiceId.isEmpty {
                        ttsService.serverVoiceId = configVoice
                    }
                }
            }
        } catch {
            // Non-critical — keep whatever was there before
        }
    }

    /// Fetches available voices from the server's `/api/v1/audio/voices` endpoint.
    @MainActor
    private func loadServerVoices() async {
        guard let apiClient = dependencies.apiClient else { return }
        isLoadingServerVoices = true
        defer { isLoadingServerVoices = false }
        do {
            let raw = try await apiClient.getVoices()
            serverVoices = raw.compactMap { entry -> (id: String, name: String)? in
                guard let id = entry["id"] as? String else { return nil }
                let name = entry["name"] as? String ?? id
                return (id: id, name: name)
            }
        } catch {
            // Non-critical — leave serverVoices empty so the fallback text input shows
        }
    }

    private func syncEngineToService() {
        let service = dependencies.textToSpeechService
        switch selectedEngine {
        case "ondevice":
            // Sub-model is governed by onDeviceModelRaw (Kokoro or Qwen3)
            let model = OnDeviceTTSModel(rawValue: onDeviceModelRaw) ?? .kokoro
            service.kokoroService.config.activeModel = model
            if model == .qwen3 {
                service.preferredEngine = .qwen3
            } else {
                service.preferredEngine = .kokoro
            }
        case "kokoro", "marvis", "mlx":
            service.preferredEngine = .kokoro
            service.kokoroService.config.activeModel = .kokoro
            onDeviceModelRaw = "kokoro"
        case "qwen3":
            service.preferredEngine = .qwen3
            service.kokoroService.config.activeModel = .qwen3
            onDeviceModelRaw = "qwen3"
        case "server":
            service.preferredEngine = .server
        case "system":
            service.preferredEngine = .system
        default:
            service.preferredEngine = .auto
        }
        UserDefaults.standard.set(selectedEngine, forKey: "ttsEngine")
    }

    private func syncKokoroConfig() {
        let service = dependencies.textToSpeechService
        service.kokoroConfig.voice = kokoroVoice
        service.kokoroConfig.speed = Float(kokoroSpeed)
        UserDefaults.standard.set(kokoroVoice, forKey: "ttsKokoroVoice")
        UserDefaults.standard.set(Float(kokoroSpeed), forKey: "ttsKokoroSpeed")
        service.kokoroService.prepareG2PForVoice(kokoroVoice)
    }

    private func syncQwen3Config() {
        let service = dependencies.textToSpeechService
        service.kokoroService.config.qwen3Voice = qwen3Voice
        service.kokoroService.config.qwen3Language = qwen3Language
        service.kokoroService.config.qwen3Speed = 1.1
        UserDefaults.standard.set(qwen3Voice, forKey: "ttsQwen3Voice")
        UserDefaults.standard.set(qwen3Language, forKey: "ttsQwen3Language")
    }

    private func preloadOnDeviceModel() {
        isDownloadingModel = true
        Task {
            await ttsService.preloadKokoroModel()
            isDownloadingModel = false
            refreshModelSizes()
        }
    }

    private func retryOnDeviceLoad() {
        ttsService.unloadKokoroModel()
        isDownloadingModel = true
        Task {
            await ttsService.preloadKokoroModel()
            isDownloadingModel = false
        }
    }

    private func refreshModelSizes() {
        let kokoro = StorageManager.shared.kokoroTTSModelSize()
        let qwen3  = StorageManager.shared.qwen3TTSModelSize()
        kokoroModelSize = kokoro > 0 ? ByteCountFormatter.string(fromByteCount: kokoro, countStyle: .file) : "未下载"
        qwen3ModelSize  = qwen3  > 0 ? ByteCountFormatter.string(fromByteCount: qwen3,  countStyle: .file) : "未下载"
    }

    private func previewVoice() {
        let service = dependencies.textToSpeechService
        if isSpeaking {
            service.stop()
            isSpeaking = false
        } else {
            syncSettingsToService()
            syncEngineToService()
            syncKokoroConfig()
            syncQwen3Config()
            isSpeaking = true
            service.onComplete = { [self] in
                isSpeaking = false
            }
            service.speak(
                "你好！这是文本转语音的试听。我可以把 AI 助手的回复朗读出来。"
            )
        }
    }

    private func refreshKokoroModelSize() {
        let size = StorageManager.shared.kokoroTTSModelSize()
        if size > 0 {
            kokoroModelSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } else {
            kokoroModelSize = "未下载"
        }
    }

}

// MARK: - STT Settings View

struct STTSettingsView: View {
@Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @AppStorage("sttEngine") private var selectedSTTEngine: String = "device"
    @AppStorage("audioFileTranscriptionMode") private var audioFileMode: String = "server"
    @AppStorage("voiceSilenceDuration") private var silenceDuration: Double = 2.0
    @AppStorage("sttLocale") private var sttLocale: String = ""
    @State private var micPermissionGranted = false
    @State private var speechPermissionGranted = false
    @State private var asrModelSize: String = "–"

    /// True when ASR model files are already cached on disk (but not necessarily loaded into memory).
    private var asrFilesOnDisk: Bool {
        asrModelSize != "–" && asrModelSize != "未下载"
    }

    private var asr: OnDeviceASRService { dependencies.asrService }

    /// All locales supported by Apple's on-device speech recognizer, sorted by display name.
    private var supportedSTTLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted {
                (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                    < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
            }
    }

    private var hasServerSTT: Bool {
        dependencies.apiClient != nil
    }

    var body: some View {
        List {
            // Live Voice Transcription (microphone / call)
            Section {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedSTTEngine = "device"
                    }
                    Haptics.play(.light)
                } label: {
                    engineRow(
                        value: "device",
                        label: "本地（Apple）",
                        description: "Apple 语音识别框架",
                        selected: selectedSTTEngine == "device"
                    )
                }
                .buttonStyle(.plain)

                if hasServerSTT {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedSTTEngine = "server"
                        }
                        Haptics.play(.light)
                    } label: {
                        engineRow(
                            value: "server",
                            label: "服务器",
                            description: "通过服务器端 /api/v1/audio/transcriptions 转写",
                            selected: selectedSTTEngine == "server"
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("语音转写引擎")
            } footer: {
                if selectedSTTEngine == "device" {
                    Text("用于实时麦克风输入。Apple 语音识别框架可离线工作，不会发送到外部服务器。")
                } else if selectedSTTEngine == "server" {
                    Text("用于实时麦克风输入。会把音频发送到当前服务器转写，需要网络。")
                } else {
                    Text("选择实时麦克风输入和语音通话使用的转写引擎。")
                }
            }

            // Audio File Transcription (attach audio file in chat)
            Section {
                // Server option (default)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        audioFileMode = "server"
                    }
                    Haptics.play(.light)
                } label: {
                    engineRow(
                        value: "server",
                        label: "服务器",
                        description: "上传音频到当前服务器并自动转写",
                        selected: audioFileMode == "server"
                    )
                }
                .buttonStyle(.plain)

                // On-device option (only shown if Parakeet is available)
                if asr.isAvailable {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            audioFileMode = "device"
                            asr.switchVariant(.qwen3ASR)
                        }
                        Haptics.play(.light)
                    } label: {
                        HStack(spacing: Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本地（Qwen3 ASR）")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                                    .foregroundStyle(theme.textPrimary)
                                Text("多语言自动检测，全程在本机处理")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: audioFileMode == "device" ? "checkmark.circle.fill" : "circle")
                                .scaledFont(size: 22)
                                .foregroundStyle(
                                    audioFileMode == "device" ? theme.brandPrimary : theme.textTertiary.opacity(0.4)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("音频文件转写")
            } footer: {
                if audioFileMode == "server" {
                    Text("聊天中附加的音频文件会上传到服务器并自动转写，无需额外下载。")
                } else {
                    Text("音频文件会使用 Qwen3 ASR 在本机转写。更私密，不会把音频发送到服务器，并支持多语言自动检测。")
                }
            }

            // On-Device Model Settings (Qwen3 ASR) — only when device mode is selected
            if audioFileMode == "device" && asr.isAvailable {
                let activeVariant: ASRModelVariant = .qwen3ASR
                let currentModelSize = asrModelSize
                let modelLabel = activeVariant.displayName
                Section {
                    HStack {
                        Text("状态")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        asrStatusBadge
                    }

                    if currentModelSize != "–" {
                        HStack {
                            Text("磁盘占用")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(currentModelSize)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }

                    if case .unloaded = asr.state {
                        Button {
                            Task { try? await asr.loadModel() }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: asrFilesOnDisk ? "bolt.circle" : "arrow.down.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text(asrFilesOnDisk ? "加载模型" : "下载并加载模型")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                    } else if case .loading = asr.state {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在加载模型…")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textSecondary)
                        }
                    } else if case .ready = asr.state {
                        Button(role: .destructive) {
                            asr.unloadModel()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "xmark.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("卸载模型（释放内存）")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                        }

                        Button(role: .destructive) {
                            asr.unloadAndDeleteVariant(activeVariant)
                            refreshModelSizes()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "trash.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("删除已下载模型")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                        }
                    } else if case .error = asr.state {
                        Button {
                            asr.unloadModel()
                            Task { try? await asr.loadModel() }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("重新下载")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(theme.warning)
                        }
                    }
                } header: {
                    Text("\(modelLabel)")
                } footer: {
                    Text("模型首次使用会从 HuggingFace 下载并缓存在本地。卸载可释放内存，删除会移除下载文件。")
                }
            }

            // Language (only for on-device Apple STT)
            if selectedSTTEngine == "device" {
                Section {
                    NavigationLink {
                        STTLanguagePickerView(
                            sttLocale: $sttLocale,
                            locales: supportedSTTLocales
                        )
                        .onChange(of: sttLocale) { _, newValue in
                            dependencies.speechRecognitionService.updateLocale(newValue)
                        }
                    } label: {
                        HStack {
                            Text("语言")
                            Spacer()
                            Text(
                                sttLocale.isEmpty
                                    ? "自动"
                                    : (Locale.current.localizedString(forIdentifier: sttLocale) ?? sttLocale)
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("语言")
                } footer: {
                    Text("选择你要说的语言。“自动”会使用设备当前语言。")
                }
            }

            // Voice Activity Detection
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("静音时长")
                        Spacer()
                        Text("\(String(format: "%.1f", silenceDuration))s")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                    }
                    Slider(value: $silenceDuration, in: 0.5...5.0, step: 0.5)
                        .tint(theme.brandPrimary)
                }
            } header: {
                Text("语音活动检测")
            } footer: {
                Text("停止说话后等待多久再结束转写。越短越快，越长越能捕捉句中停顿。")
            }

            // Permissions
            Section {
                HStack {
                    Image(systemName: "mic.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("麦克风")
                        .scaledFont(size: 16)
                    Spacer()
                    if micPermissionGranted {
                        statusPill("已授权", color: theme.success)
                    } else {
                        statusPill("未授权", color: theme.warning)
                    }
                }

                HStack {
                    Image(systemName: "waveform")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("语音识别")
                        .scaledFont(size: 16)
                    Spacer()
                    if speechPermissionGranted {
                        statusPill("已授权", color: theme.success)
                    } else {
                        statusPill("未授权", color: theme.warning)
                    }
                }

                if !micPermissionGranted || !speechPermissionGranted {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "gear")
                                .scaledFont(size: 14, weight: .medium)
                            Text("打开设置授权")
                                .scaledFont(size: 16)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
            } header: {
                Text("权限")
            }
            // Model Storage Management
            Section {
                HStack {
                    Text("Qwen3 语音识别模型")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(asrModelSize)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        asr.unloadAndDeleteVariant(.qwen3ASR)
                        refreshModelSizes()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }

            } header: {
                Text("模型存储")
            } footer: {
                Text("在模型行上向左滑动即可从磁盘删除并释放空间。")
            }
        }
        .navigationTitle("语音与转写")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshPermissions()
            refreshModelSizes()
        }
    }

    /// Checks microphone and speech recognition permissions independently.
    private func refreshPermissions() {
        // Check microphone permission
        if #available(iOS 17.0, *) {
            micPermissionGranted = AVAudioApplication.shared.recordPermission == .granted
        } else {
            micPermissionGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        }

        // Check speech recognition permission
        speechPermissionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - ASR Status Badge (shared for both variants)

    @ViewBuilder
    private var asrStatusBadge: some View {
        switch asr.state {
        case .unloaded:
            statusPill(asrFilesOnDisk ? "未加载" : "未下载", color: theme.textTertiary)
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("加载中...")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        case .ready:
            statusPill("已就绪", color: theme.success)
        case .transcribing:
            statusPill("转写中…", color: theme.brandPrimary)
        case .paused:
            statusPill("已暂停", color: theme.textTertiary)
        case .error(let msg):
            statusPill("错误", color: theme.error)
                .help(msg)
        }
    }

    private func engineRow(value: String, label: String, description: String, selected: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .scaledFont(size: 16)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textPrimary)
                Text(description)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .scaledFont(size: 22)
                .foregroundStyle(selected ? theme.brandPrimary : theme.textTertiary.opacity(0.4))
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text))
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func refreshModelSizes() {
        let p = asr.modelSize(for: .qwen3ASR)
        asrModelSize = p > 0 ? ByteCountFormatter.string(fromByteCount: p, countStyle: .file) : "未下载"
    }

}

// MARK: - STT Language Picker

/// Full-screen scrollable list of all SFSpeechRecognizer-supported locales.
/// Uses a plain List so there's no nested-scroll conflict with the parent.
struct STTLanguagePickerView: View {
    @Binding var sttLocale: String
    let locales: [Locale]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredLocales: [Locale] {
        guard !searchText.isEmpty else { return locales }
        let q = searchText.lowercased()
        return locales.filter { locale in
            let name = (Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).lowercased()
            return name.contains(q) || locale.identifier.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Button {
                    sttLocale = ""
                    dismiss()
                } label: {
                    HStack {
                        Text("自动（设备语言）")
                        Spacer()
                        if sttLocale.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }

            ForEach(filteredLocales, id: \.identifier) { locale in
                Button {
                    sttLocale = locale.identifier
                    dismiss()
                } label: {
                    HStack {
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        Spacer()
                        if sttLocale == locale.identifier {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $searchText, prompt: "搜索语言…")
        .navigationTitle("语音识别语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TTS Voice Picker

/// Full-screen scrollable list of all installed AVSpeechSynthesisVoice entries.
/// Uses a plain List so there's no nested-scroll conflict with the parent.
struct TTSVoicePickerView: View {
    @Binding var voiceIdentifier: String
    let voices: [AVSpeechSynthesisVoice]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        guard !searchText.isEmpty else { return voices }
        let q = searchText.lowercased()
        return voices.filter { voice in
            voice.name.lowercased().contains(q) || voice.language.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Button {
                    voiceIdentifier = ""
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动（检测语言）")
                                .fontWeight(.medium)
                            Text("根据每条消息的语言选择最合适的声音")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if voiceIdentifier.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }

            ForEach(filteredVoices, id: \.identifier) { voice in
                Button {
                    voiceIdentifier = voice.identifier
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                                .fontWeight(.medium)
                            Text(voice.language)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if voiceIdentifier == voice.identifier {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $searchText, prompt: "搜索声音或语言…")
        .navigationTitle("语音声音")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Notification Settings View

struct NotificationSettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("notificationShowResponsePreview") private var showResponsePreview = false
    @State private var systemPermissionGranted = NotificationService.shared.isAuthorized

    var body: some View {
        List {
            Section {
                Toggle("生成完成", isOn: $notificationsEnabled)
                    .tint(theme.brandPrimary)
                Toggle("显示回复预览", isOn: $showResponsePreview)
                    .tint(theme.brandPrimary)
                    .disabled(!notificationsEnabled)
            } header: {
                Text("通知类型")
            } footer: {
                Text("AI 回复生成完成时发送通知。开启“显示回复预览”后，通知会显示回复开头内容。")
            }

            Section {
                HStack {
                    Image(systemName: "bell.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("系统权限")
                        .scaledFont(size: 16)
                    Spacer()
                    if systemPermissionGranted {
                        permissionPill("已授权", color: theme.success)
                    } else {
                        permissionPill("未授权", color: theme.warning)
                    }
                }

                if !systemPermissionGranted {
                    Button {
                        Task {
                            let granted = await NotificationService.shared.requestPermission()
                            systemPermissionGranted = granted
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "bell.badge")
                                .scaledFont(size: 14, weight: .medium)
                            Text("请求权限")
                                .scaledFont(size: 16)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "gear")
                                .scaledFont(size: 14, weight: .medium)
                            Text("打开 iOS 设置")
                                .scaledFont(size: 16)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(theme.textSecondary)
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                if systemPermissionGranted {
                    Text("通知已授权。你可以在 iOS 设置中管理通知样式。")
                } else {
                    Text("通知需要系统权限。请点击“请求权限”，或在 iOS 设置 → Iexa → 通知中开启。")
                }
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Refresh permission state
            Task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                systemPermissionGranted = settings.authorizationStatus == .authorized
            }
        }
    }

    private func permissionPill(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Sign Out Confirmation Sheet

/// A beautiful bottom sheet for sign-out confirmation, replacing the system confirmationDialog.
struct SignOutConfirmationSheet: View {
    let onSignOut: () -> Void
    let onSignOutAndRemove: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(theme.error.opacity(0.1))
                        .frame(width: 56, height: 56)
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .scaledFont(size: 22, weight: .medium)
                        .foregroundStyle(theme.error)
                }
                .scaleEffect(appeared ? 1 : 0.7)
                .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.05), value: appeared)

                Text("退出登录")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Text("确定要退出登录吗？")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.2).delay(0.05), value: appeared)

            Divider()
                .background(theme.divider)
                .padding(.horizontal, Spacing.screenPadding)

            // Action buttons
            VStack(spacing: Spacing.sm) {
                signOutButton(
                    title: "退出登录",
                    subtitle: "保留站点连接",
                    icon: "arrow.right.circle",
                    action: onSignOut,
                    index: 0
                )

                signOutButton(
                    title: "退出并移除站点",
                    subtitle: "清除所有连接数据",
                    icon: "trash.circle",
                    action: onSignOutAndRemove,
                    index: 1
                )

                // Cancel
                Button(action: onCancel) {
                    Text("取消")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.2).delay(0.25), value: appeared)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.md)
        }
        .background(theme.background)
        .onAppear { appeared = true }
    }

    private func signOutButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void,
        index: Int
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundStyle(theme.error)
                    .frame(width: 36, height: 36)
                    .background(theme.error.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.error)
                    Text(subtitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(theme.error.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                    .strokeBorder(theme.error.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.98)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8).delay(0.1 + Double(index) * 0.05), value: appeared)
    }
}
