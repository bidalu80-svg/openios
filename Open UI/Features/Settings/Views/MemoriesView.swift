import SwiftUI

/// Displays and manages the user's AI memories.
///
/// Memories are persistent context that the AI uses across conversations.
/// Users can view, add, edit, and delete memories from this screen.
/// Matches the WebUI's Settings → Personalization → Memory section.
struct MemoriesView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var memories: [[String: Any]] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newMemoryText = ""
    @State private var isAddingMemory = false
    @State private var editingMemoryId: String?
    @State private var editText = ""
    @State private var showClearAllConfirmation = false
    @State private var isClearingAll = false
    @State private var memoryEnabled = false
    @State private var isLoadingMemoryToggle = false

    private var usesLocalMemories: Bool {
        dependencies.apiClient?.providerType != .openWebUI
    }

    private var memoryServerURL: String {
        dependencies.apiClient?.baseURL ?? "local"
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: Spacing.lg) {
                    ProgressView()
                    Text("正在加载记忆…")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                memoryList
            }
        }
        .background(theme.background)
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { isAddingMemory = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await loadMemories()
            await loadMemoryToggle()
        }
        .destructiveConfirmation(
            isPresented: $showClearAllConfirmation,
            title: "清空所有记忆",
            message: "这会永久删除你的所有记忆，AI 将不再使用这些上下文。",
            destructiveTitle: "全部清空"
        ) {
            Task { await clearAllMemories() }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无记忆", systemImage: "brain")
        } description: {
            Text("记忆可以让 AI 在不同对话中记住与你有关的重要信息。添加一条记忆即可开始使用。")
        } actions: {
            Button {
                withAnimation { isAddingMemory = true }
            } label: {
                Text("添加记忆")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.brandPrimary)
        }
    }

    // MARK: - Memory List

    private var memoryList: some View {
        List {
            // Memory enabled toggle
            Section {
                Toggle(isOn: $memoryEnabled) {
                    Label("启用记忆", systemImage: "brain")
                }
                .tint(theme.brandPrimary)
                .disabled(isLoadingMemoryToggle)
                .onChange(of: memoryEnabled) { _, newValue in
                    Task { await updateMemoryToggle(newValue) }
                }
            } header: {
                Text("记忆")
            } footer: {
                Text("开启后，AI 会在不同对话中记住与你有关的上下文。")
            }

            // Add new memory section
            if isAddingMemory {
                Section {
                    VStack(spacing: Spacing.sm) {
                        TextField("希望 AI 记住什么？", text: $newMemoryText, axis: .vertical)
                            .lineLimit(3...6)
                            .scaledFont(size: 16)

                        HStack {
                            Button("取消") {
                                withAnimation {
                                    isAddingMemory = false
                                    newMemoryText = ""
                                }
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button {
                                Task { await addMemory() }
                            } label: {
                                Text("保存")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.brandPrimary)
                            .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } header: {
                    Text("新增记忆")
                }
            }

            // Error
            if let error = errorMessage {
                Section {
                    Text(error)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.error)
                }
            }

            // Existing memories or empty message
            Section {
                if memories.isEmpty && !isAddingMemory {
                    // Empty state inside the list
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "brain")
                            .scaledFont(size: 48)
                            .foregroundStyle(theme.textTertiary.opacity(0.5))
                            .padding(.top, Spacing.lg)
                        
                        Text("暂无记忆")
                            .scaledFont(size: 20, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        
                        Text("记忆可以让 AI 在不同对话中记住与你有关的重要信息。")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.lg)
                        
                        Button {
                            withAnimation { isAddingMemory = true }
                        } label: {
                            Text("添加记忆")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.brandPrimary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.xl)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                ForEach(memories, id: \.memoryId) { memory in
                    let memId = memory["id"] as? String ?? ""
                    let content = memory["content"] as? String ?? ""

                    if editingMemoryId == memId {
                        // Edit mode
                        VStack(spacing: Spacing.sm) {
                            TextField("记忆内容", text: $editText, axis: .vertical)
                                .lineLimit(3...6)
                                .scaledFont(size: 16)

                            HStack {
                                Button("取消") {
                                    withAnimation { editingMemoryId = nil }
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button {
                                    Task { await updateMemory(id: memId) }
                                } label: {
                                    Text("保存")
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(theme.brandPrimary)
                                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                    } else {
                        // Display mode
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(content)
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textPrimary)

                            if let createdAt = memory["created_at"] as? Double {
                                Text(Date(timeIntervalSince1970: createdAt).formatted(.relative(presentation: .named)))
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .padding(.vertical, Spacing.xxs)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                editText = content
                                withAnimation { editingMemoryId = memId }
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                Task { await deleteMemory(id: memId) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteMemory(id: memId) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                editText = content
                                withAnimation { editingMemoryId = memId }
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(theme.brandPrimary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("\(memories.count) 条记忆")
                    Spacer()
                }
            }

            // Clear all
            if !memories.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text(isClearingAll ? "正在清空…" : "清空所有记忆")
                        }
                    }
                    .disabled(isClearingAll)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func loadMemories() async {
        guard let api = dependencies.apiClient else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil

        do {
            if usesLocalMemories {
                memories = await LocalMemoryStore.shared
                    .list(serverURL: memoryServerURL)
                    .map(\.dictionary)
            } else {
                memories = try await api.getMemories()
            }
        } catch {
            errorMessage = "加载记忆失败。"
        }

        isLoading = false
    }

    private func addMemory() async {
        guard let api = dependencies.apiClient else { return }
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            let newMemory: [String: Any]
            if usesLocalMemories {
                newMemory = await LocalMemoryStore.shared
                    .add(content: text, serverURL: memoryServerURL)
                    .dictionary
            } else {
                newMemory = try await api.addMemory(content: text)
            }
            withAnimation {
                memories.insert(newMemory, at: 0)
                newMemoryText = ""
                isAddingMemory = false
            }
        } catch {
            errorMessage = "添加记忆失败。"
        }
    }

    private func updateMemory(id: String) async {
        guard let api = dependencies.apiClient else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            let updated: [String: Any]
            if usesLocalMemories {
                guard let local = await LocalMemoryStore.shared
                    .update(id: id, content: text, serverURL: memoryServerURL) else { return }
                updated = local.dictionary
            } else {
                updated = try await api.updateMemory(id: id, content: text)
            }
            if let idx = memories.firstIndex(where: { ($0["id"] as? String) == id }) {
                memories[idx] = updated
            }
            withAnimation { editingMemoryId = nil }
        } catch {
            errorMessage = "更新记忆失败。"
        }
    }

    private func deleteMemory(id: String) async {
        guard let api = dependencies.apiClient else { return }

        do {
            if usesLocalMemories {
                await LocalMemoryStore.shared.delete(id: id, serverURL: memoryServerURL)
            } else {
                try await api.deleteMemory(id: id)
            }
            withAnimation {
                memories.removeAll { ($0["id"] as? String) == id }
            }
        } catch {
            errorMessage = "删除记忆失败。"
        }
    }

    private func clearAllMemories() async {
        guard let api = dependencies.apiClient else { return }
        isClearingAll = true

        do {
            if usesLocalMemories {
                await LocalMemoryStore.shared.deleteAll(serverURL: memoryServerURL)
            } else {
                try await api.resetMemories()
            }
            withAnimation { memories.removeAll() }
        } catch {
            errorMessage = "清空记忆失败。"
        }

        isClearingAll = false
    }

    private func loadMemoryToggle() async {
        guard let api = dependencies.apiClient else { return }
        isLoadingMemoryToggle = true
        if usesLocalMemories {
            memoryEnabled = await LocalMemoryStore.shared.isEnabled(serverURL: memoryServerURL)
        } else {
            if let settings = try? await api.getUserSettings(),
               let ui = settings["ui"] as? [String: Any],
               let enabled = ui["memory"] as? Bool {
                memoryEnabled = enabled
            }
        }
        isLoadingMemoryToggle = false
    }

    private func updateMemoryToggle(_ enabled: Bool) async {
        guard let api = dependencies.apiClient else { return }
        isLoadingMemoryToggle = true
        if usesLocalMemories {
            await LocalMemoryStore.shared.setEnabled(enabled, serverURL: memoryServerURL)
        } else {
            // Use merge helper so we ONLY update `memory` without overwriting
            // `models`, `pinnedModels`, or any other ui keys.
            try? await api.mergeUserUISettings(["memory": enabled])
        }
        isLoadingMemoryToggle = false
        // Notify all active ChatViewModels so they update immediately
        // without waiting for the next server fetch on model switch/reload.
        NotificationCenter.default.post(name: .memorySettingChanged, object: enabled)
    }
}

// MARK: - Helper

private extension Dictionary where Key == String, Value == Any {
    var memoryId: String {
        (self["id"] as? String) ?? UUID().uuidString
    }
}
