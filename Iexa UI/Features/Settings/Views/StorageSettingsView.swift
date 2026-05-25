import SwiftUI

/// Full storage browser that shows every file and directory the app has ever
/// written — Documents, Application Support, Caches, and Temp — with sizes
/// and the ability to delete individual items or run bulk cleanup actions.
struct StorageSettingsView: View {
    @Environment(\.theme) private var theme

    // MARK: - State

    @State private var storageLocations: [(label: String, icon: String, color: String, url: URL)] = []
    @State private var locationEntries: [String: [StorageManager.StorageEntry]] = [:]
    @State private var locationSizes: [String: Int64] = [:]
    @State private var isLoading = true
    @State private var expandedLocations: Set<String> = ["Documents"]
    @State private var expandedDirectories: Set<String> = []
    @State private var showDeleteAllModelsConfirm = false
    @State private var showClearCachesConfirm = false
    @State private var showClearHubCacheConfirm = false
    @State private var showClearTempConfirm = false
    @State private var deletedBytesTotal: Int64 = 0
    @State private var actionFeedback: String? = nil

    // MARK: - Computed

    private var totalSize: Int64 {
        locationSizes.values.reduce(0, +)
    }

    private var hasHubCache: Bool {
        // Documents/Models contains any models-- folder
        guard let docs = storageLocations.first(where: { $0.label == "Documents" }) else { return false }
        let modelsDir = docs.url.appendingPathComponent("Models")
        guard let entries = locationEntries["Documents"] else { return false }
        // Find the Models folder entry and look at its children
        if let modelsEntry = entries.first(where: { $0.name == "Models" }),
           let children = modelsEntry.children {
            return children.contains { $0.name.hasPrefix("models--") }
        }
        // Also check directly
        if let items = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            return items.contains { $0.lastPathComponent.hasPrefix("models--") }
        }
        return false
    }

    private var hubCacheSize: Int64 {
        guard let entries = locationEntries["Documents"],
              let modelsEntry = entries.first(where: { $0.name == "Models" }),
              let children = modelsEntry.children else { return 0 }
        return children
            .filter { $0.name.hasPrefix("models--") }
            .reduce(0) { $0 + $1.size }
    }

    // MARK: - Body

    var body: some View {
        List {
            // Summary header
            summarySection

            // Quick action buttons
            quickActionsSection

            // Per-location file browser
            ForEach(storageLocations, id: \.label) { location in
                locationSection(location)
            }
        }
        .navigationTitle("存储")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await loadStorage() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await loadStorage() }
        .confirmationDialog(
            "删除所有本地模型",
            isPresented: $showDeleteAllModelsConfirm,
            titleVisibility: .visible
        ) {
            Button("删除所有模型", role: .destructive) {
                let freed = StorageManager.shared.deleteAllMLModelFiles()
                showActionFeedback("已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
                Task { await loadStorage() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除所有已下载的 TTS 和 ASR 模型文件。下次使用相关功能时需要重新下载。")
        }
        .confirmationDialog(
            "清理 Hub 缓存",
            isPresented: $showClearHubCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("清理 Hub 缓存", role: .destructive) {
                let freed = StorageManager.shared.cleanupHubCache()
                showActionFeedback("已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
                Task { await loadStorage() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("HuggingFace Hub 会在已下载模型旁边保留一份重复缓存。清理它是安全的，不会影响正在使用的模型文件。")
        }
        .confirmationDialog(
            "清理缓存",
            isPresented: $showClearCachesConfirm,
            titleVisibility: .visible
        ) {
            Button("清理缓存", role: .destructive) {
                let freed = StorageManager.shared.clearCachesDirectory()
                showActionFeedback("已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
                Task { await loadStorage() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会清理图片缓存、HTTP 缓存和其他缓存数据。App 会在需要时重新缓存。")
        }
        .confirmationDialog(
            "清理临时文件",
            isPresented: $showClearTempConfirm,
            titleVisibility: .visible
        ) {
            Button("清理临时文件", role: .destructive) {
                let freed = StorageManager.shared.clearTempDirectory()
                showActionFeedback("已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
                Task { await loadStorage() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除 App 临时目录中的所有文件。需要时会自动重新创建。")
        }
        .overlay(alignment: .bottom) {
            if let feedback = actionFeedback {
                feedbackBanner(feedback)
            }
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        Section {
            if isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在计算存储…")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                // Total storage usage
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("应用总存储")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                        Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                            .scaledFont(size: 28, weight: .bold)
                            .foregroundStyle(theme.textPrimary)
                    }
                    Spacer()
                    Image(systemName: "internaldrive.fill")
                        .scaledFont(size: 32)
                        .foregroundStyle(theme.brandPrimary.opacity(0.7))
                }
                .padding(.vertical, 4)

                // Per-location breakdown
                ForEach(storageLocations, id: \.label) { location in
                    let size = locationSizes[location.label] ?? 0
                    if size > 0 {
                        HStack(spacing: 12) {
                            Image(systemName: location.icon)
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(colorForString(location.color))
                                .frame(width: 28, height: 28)
                                .background(colorForString(location.color).opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text(displayLocationLabel(location.label))
                                .scaledFont(size: 15)
                                .foregroundStyle(theme.textPrimary)

                            Spacer()

                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        } header: {
            Text("存储占用")
        }
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        Section {
            // Delete Hub cache (only show if hub cache exists)
            if hasHubCache {
                Button {
                    showClearHubCacheConfirm = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("删除 Hub 重复缓存")
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.error)
                            Text("HuggingFace 留下的重复模型数据，可以安全删除")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    } icon: {
                        Image(systemName: "trash.circle.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(.red)
                    }
                }

            }

            // Clear Caches
            Button {
                showClearCachesConfirm = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清理缓存")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        let cacheSize = locationSizes["Caches"] ?? 0
                        Text(cacheSize > 0
                             ? "图片缓存、HTTP 缓存 · \(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))"
                             : "图片缓存、HTTP 缓存")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                } icon: {
                    Image(systemName: "cylinder.split.1x2.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(.orange)
                }
            }

            // Clear Temp Files
            let tempSize = locationSizes["Temporary Files"] ?? 0
            if tempSize > 0 {
                Button {
                    showClearTempConfirm = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("清理临时文件")
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.textPrimary)
                            Text("临时文件 · \(ByteCountFormatter.string(fromByteCount: tempSize, countStyle: .file))")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    } icon: {
                        Image(systemName: "wind")
                            .scaledFont(size: 20)
                            .foregroundStyle(.teal)
                    }
                }
            }

            // Delete all ML models
            let mlSize = StorageManager.shared.mlModelCacheSize()
            if mlSize > 0 {
                Button {
                    showDeleteAllModelsConfirm = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("删除所有本地模型")
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.error)
                            Text("语音合成和识别模型 · \(ByteCountFormatter.string(fromByteCount: mlSize, countStyle: .file))")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    } icon: {
                        Image(systemName: "cpu.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("快捷操作")
        } footer: {
            Text("这些操作会立即释放空间。需要模型的功能下次使用时会自动重新下载。")
        }
    }

    // MARK: - Location Section

    @ViewBuilder
    private func locationSection(_ location: (label: String, icon: String, color: String, url: URL)) -> some View {
        let size = locationSizes[location.label] ?? 0
        let entries = locationEntries[location.label] ?? []
        let isExpanded = expandedLocations.contains(location.label)

        Section {
            // Location header row (tap to expand/collapse)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedLocations.remove(location.label)
                    } else {
                        expandedLocations.insert(location.label)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: location.icon)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(colorForString(location.color))
                        .frame(width: 32, height: 32)
                        .background(colorForString(location.color).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayLocationLabel(location.label))
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text(location.url.path.replacingOccurrences(
                            of: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.deletingLastPathComponent().path ?? "",
                            with: "~"
                        ))
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(size > 0 ? theme.textSecondary : theme.textTertiary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            // File entries (only when expanded)
            if isExpanded {
                if entries.isEmpty {
                    Text("空")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                } else {
                    let flatEntries = flattenEntries(entries)
                    ForEach(flatEntries, id: \.id) { entry in
                        entryRowContent(entry, locationLabel: location.label)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteEntry(entry, inLocation: location.label)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        } header: {
            Text(displayLocationLabel(location.label))
        }
    }

    // MARK: - Flatten entries

    /// Recursively flattens a tree of StorageEntry into a flat array,
    /// respecting the expandedDirectories state so only expanded dirs show children.
    private func flattenEntries(_ entries: [StorageManager.StorageEntry]) -> [StorageManager.StorageEntry] {
        var result: [StorageManager.StorageEntry] = []
        for entry in entries {
            result.append(entry)
            if entry.isDirectory, expandedDirectories.contains(entry.id), let children = entry.children {
                result.append(contentsOf: flattenEntries(children))
            }
        }
        return result
    }

    // MARK: - Entry Row Content (no swipeActions — applied at ForEach level)

    @ViewBuilder
    private func entryRowContent(_ entry: StorageManager.StorageEntry, locationLabel: String) -> some View {
        let isExpanded = expandedDirectories.contains(entry.id)
        let indent = CGFloat(entry.depth) * 16

        HStack(spacing: 10) {
            // Indentation
            if indent > 0 {
                Spacer().frame(width: indent)
            }

            // Icon
            Image(systemName: entry.systemImage)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(iconColorForEntry(entry))
                .frame(width: 28, height: 28)
                .background(iconColorForEntry(entry).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Name + size
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if entry.isDirectory, let children = entry.children {
                    Text("\(children.count) 项")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            // Size
            Text(entry.formattedSize)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(entry.size > 100_000_000 ? theme.error.opacity(0.8) : theme.textSecondary)
                .fixedSize()

            // Expand chevron for directories with children
            if entry.isDirectory, let children = entry.children, !children.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            expandedDirectories.remove(entry.id)
                        } else {
                            expandedDirectories.insert(entry.id)
                        }
                    }
                    Haptics.play(.light)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Feedback Banner

    private func feedbackBanner(_ message: String) -> some View {
        Text(message)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.black.opacity(0.8))
            )
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: actionFeedback)
    }

    // MARK: - Actions

    private func deleteEntry(_ entry: StorageManager.StorageEntry, inLocation locationLabel: String) {
        let freed = StorageManager.shared.deleteItem(at: entry.url)
        if freed > 0 {
            showActionFeedback("已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        }
        Haptics.play(.medium)
        // Refresh storage data
        Task { await loadStorage() }
    }

    private func showActionFeedback(_ message: String) {
        withAnimation {
            actionFeedback = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 seconds
            await MainActor.run {
                withAnimation {
                    actionFeedback = nil
                }
            }
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadStorage() async {
        isLoading = true
        let manager = StorageManager.shared
        let locations = manager.allStorageLocations()
        storageLocations = locations

        // Calculate sizes and enumerate entries concurrently
        var sizes: [String: Int64] = [:]
        var entries: [String: [StorageManager.StorageEntry]] = [:]

        await withTaskGroup(of: (String, Int64, [StorageManager.StorageEntry]).self) { group in
            for location in locations {
                group.addTask {
                    let size: Int64
                    switch location.label {
                    case "Documents":
                        size = manager.documentDirectorySize()
                    case "Application Support":
                        size = manager.appSupportDirectorySize()
                    case "Caches":
                        size = manager.cacheDirectorySize()
                    case "Temporary Files":
                        size = manager.tempDirectorySize()
                    default:
                        size = 0
                    }
                    let locationEntries = manager.enumerateDirectory(location.url)
                    return (location.label, size, locationEntries)
                }
            }
            for await (label, size, locationEntryList) in group {
                sizes[label] = size
                entries[label] = locationEntryList
            }
        }

        locationSizes = sizes
        locationEntries = entries
        isLoading = false
    }

    // MARK: - Helpers

    private func colorForString(_ colorName: String) -> Color {
        switch colorName {
        case "blue":   return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "green":  return .green
        case "red":    return .red
        default:       return .secondary
        }
    }

    private func displayLocationLabel(_ label: String) -> String {
        switch label {
        case "Documents": return "文稿"
        case "Application Support": return "应用支持"
        case "Caches": return "缓存"
        case "Temporary Files": return "临时文件"
        default: return label
        }
    }

    private func iconColorForEntry(_ entry: StorageManager.StorageEntry) -> Color {
        if entry.isDirectory { return .blue }
        let ext = entry.url.pathExtension.lowercased()
        switch ext {
        case "safetensors", "gguf", "bin", "pt", "pth": return .purple
        case "json":                                      return .orange
        case "jpg", "jpeg", "png", "gif", "webp":        return .green
        case "m4a", "wav", "mp3":                         return .pink
        case "sqlite", "db":                              return .teal
        default:                                          return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        StorageSettingsView()
    }
}
