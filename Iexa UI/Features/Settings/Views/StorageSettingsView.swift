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
            NavigationLink {
                LocalWorkspaceFileBrowserView(showDoneButton: false, wrapInNavigationStack: false)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("浏览 Local Alpine 文件")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text("/mnt/iexa 工作区、本地 Alpine rootfs、共享目录和挂载点")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                } icon: {
                    Image(systemName: "folder.badge.gearshape")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.brandPrimary)
                }
            }

            NavigationLink {
                LocalAlpineRootFSManagementView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rootfs 管理")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text("查看 Local Alpine 状态，配置 APK 与 Python pip 镜像")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                } icon: {
                    Image(systemName: "shippingbox.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(.blue)
                }
            }

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

private struct LocalAlpineRootFSManagementView: View {
    @Environment(\.theme) private var theme

    @State private var settings = LocalAlpineMirrorStore.load()
    @State private var status: LocalAlpineRootFSManagementStatus?
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var feedback: String?

    var body: some View {
        List {
            statusSection
            mirrorSection
        }
        .navigationTitle("Rootfs 管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isLoading || isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await loadStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await loadStatus() }
        .overlay(alignment: .bottom) {
            if let feedback {
                Text(feedback)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.82), in: Capsule(style: .continuous))
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var statusSection: some View {
        Section("状态") {
            statusRow(
                title: "已安装",
                value: status?.isRuntimeRootFSInstalled == true ? "是" : "尚未初始化",
                icon: "checkmark.circle.fill",
                color: status?.isRuntimeRootFSInstalled == true ? .green : .orange
            )
            statusRow(
                title: "大小",
                value: ByteCountFormatter.string(
                    fromByteCount: status?.rootFSSizeBytes ?? 0,
                    countStyle: .file
                ),
                icon: "internaldrive.fill",
                color: .blue
            )
            statusRow(
                title: "路径",
                value: status?.rootFSDisplayPath ?? "Documents/Iexa Alpine/rootfs.fakefs",
                icon: "folder.fill",
                color: .gray
            )
            statusRow(
                title: "运行时",
                value: status?.isRuntimeLinked == true ? "已链接 iSH" : "未链接",
                icon: "terminal.fill",
                color: status?.isRuntimeLinked == true ? .green : .orange
            )
        }
    }

    private var mirrorSection: some View {
        Section("镜像") {
            Button {
                Task { await detectFastMirrors() }
            } label: {
                Label {
                    Text("检测快速镜像")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                } icon: {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.orange)
                }
            }
            .disabled(isApplying)

            NavigationLink {
                LocalAlpineMirrorPickerView(
                    title: "Alpine APK",
                    kind: .apk,
                    options: LocalAlpineMirrorStore.apkMirrors,
                    settings: settings,
                    onSettingsChanged: applySettings
                )
            } label: {
                mirrorRow(
                    icon: "mountain.2.fill",
                    iconColor: .blue,
                    title: "Alpine APK",
                    subtitle: LocalAlpineMirrorStore.selectedAPKMirror(settings: settings).name
                )
            }

            NavigationLink {
                LocalAlpineMirrorPickerView(
                    title: "Python pip",
                    kind: .pip,
                    options: LocalAlpineMirrorStore.pipMirrors,
                    settings: settings,
                    onSettingsChanged: applySettings
                )
            } label: {
                mirrorRow(
                    icon: "cube.box.fill",
                    iconColor: .green,
                    title: "Python pip",
                    subtitle: LocalAlpineMirrorStore.selectedPipMirror(settings: settings).name
                )
            }

            NavigationLink {
                LocalAlpineMirrorPickerView(
                    title: "Node.js npm",
                    kind: .npm,
                    options: LocalAlpineMirrorStore.npmMirrors,
                    settings: settings,
                    onSettingsChanged: applySettings
                )
            } label: {
                mirrorRow(
                    icon: "cube.transparent.fill",
                    iconColor: .red,
                    title: "Node.js npm",
                    subtitle: LocalAlpineMirrorStore.selectedNpmMirror(settings: settings).name
                )
            }
        } footer: {
            Text("镜像会写入当前 Local Alpine rootfs：APK 使用 /etc/apk/repositories，pip 使用 pip.conf，npm 使用 npmrc。")
        }
    }

    private func statusRow(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: Circle())
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func mirrorRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12), in: Circle())
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(subtitle)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        }
    }

    @MainActor
    private func loadStatus() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await LocalAlpineTerminalService.shared.rootFSManagementStatus()
        } catch {
            showFeedback("Rootfs 状态读取失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func applySettings(_ next: LocalAlpineMirrorSettings) {
        settings = next
        isApplying = true
        Task {
            do {
                try await LocalAlpineTerminalService.shared.applyMirrorSettings(next)
                await MainActor.run {
                    showFeedback("镜像配置已应用")
                    isApplying = false
                }
                await loadStatus()
            } catch {
                await MainActor.run {
                    showFeedback("镜像配置失败：\(error.localizedDescription)")
                    isApplying = false
                }
            }
        }
    }

    @MainActor
    private func detectFastMirrors() async {
        isApplying = true
        let fastestAPK = await fastestMirror(
            options: LocalAlpineMirrorStore.apkMirrors.filter { !$0.isOfficial },
            kind: .apk
        )
        let fastestPip = await fastestMirror(
            options: LocalAlpineMirrorStore.pipMirrors.filter { !$0.isOfficial },
            kind: .pip
        )
        let fastestNpm = await fastestMirror(
            options: LocalAlpineMirrorStore.npmMirrors.filter { !$0.isOfficial },
            kind: .npm
        )

        var next = settings
        if let apk = fastestAPK {
            next.apkMirrorsEnabled = true
            next.selectedAPKMirrorID = apk.id
        }
        if let pip = fastestPip {
            next.pipMirrorsEnabled = true
            next.selectedPipMirrorID = pip.id
        }
        if let npm = fastestNpm {
            next.npmMirrorsEnabled = true
            next.selectedNpmMirrorID = npm.id
        }
        applySettings(next)
    }

    private func fastestMirror(
        options: [LocalAlpineMirrorOption],
        kind: LocalAlpineMirrorKind
    ) async -> LocalAlpineMirrorOption? {
        var best: (option: LocalAlpineMirrorOption, elapsed: TimeInterval)?
        for option in options {
            guard let elapsed = await LocalAlpineTerminalService.shared.testMirror(option, kind: kind) else {
                continue
            }
            if best == nil || elapsed < best!.elapsed {
                best = (option, elapsed)
            }
        }
        return best?.option
    }

    @MainActor
    private func showFeedback(_ text: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            feedback = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.18)) {
                    if feedback == text {
                        feedback = nil
                    }
                }
            }
        }
    }
}

private struct LocalAlpineMirrorPickerView: View {
    let title: String
    let kind: LocalAlpineMirrorKind
    let options: [LocalAlpineMirrorOption]
    let settings: LocalAlpineMirrorSettings
    let onSettingsChanged: @MainActor (LocalAlpineMirrorSettings) -> Void

    @Environment(\.theme) private var theme
    @State private var speedResults: [String: TimeInterval] = [:]
    @State private var isTesting = false

    private var mirrorsEnabled: Bool {
        switch kind {
        case .apk:
            return settings.apkMirrorsEnabled
        case .pip:
            return settings.pipMirrorsEnabled
        case .npm:
            return settings.npmMirrorsEnabled
        }
    }

    private var selectedID: String {
        switch kind {
        case .apk:
            return settings.apkMirrorsEnabled ? settings.selectedAPKMirrorID : "official"
        case .pip:
            return settings.pipMirrorsEnabled ? settings.selectedPipMirrorID : "official"
        case .npm:
            return settings.npmMirrorsEnabled ? settings.selectedNpmMirrorID : "official"
        }
    }

    private var selectedOption: LocalAlpineMirrorOption {
        options.first(where: { $0.id == selectedID }) ?? options[0]
    }

    var body: some View {
        List {
            Section("当前") {
                Toggle("使用镜像", isOn: Binding(
                    get: { mirrorsEnabled },
                    set: { enabled in
                        var next = settings
                        switch kind {
                        case .apk:
                            next.apkMirrorsEnabled = enabled
                        case .pip:
                            next.pipMirrorsEnabled = enabled
                        case .npm:
                            next.npmMirrorsEnabled = enabled
                        }
                        onSettingsChanged(next)
                    }
                ))
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedOption.name)
                        .scaledFont(size: 17, weight: .bold)
                    Text(selectedOption.url)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
            }

            Section("镜像") {
                ForEach(options) { option in
                    Button {
                        var next = settings
                        switch kind {
                        case .apk:
                            next.apkMirrorsEnabled = !option.isOfficial
                            next.selectedAPKMirrorID = option.id
                        case .pip:
                            next.pipMirrorsEnabled = !option.isOfficial
                            next.selectedPipMirrorID = option.id
                        case .npm:
                            next.npmMirrorsEnabled = !option.isOfficial
                            next.selectedNpmMirrorID = option.id
                        }
                        onSettingsChanged(next)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedID == option.id ? "checkmark.circle.fill" : "circle")
                                .scaledFont(size: 20, weight: .semibold)
                                .foregroundStyle(selectedID == option.id ? theme.brandPrimary : theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(option.name)
                                        .scaledFont(size: 16, weight: .bold)
                                        .foregroundStyle(theme.textPrimary)
                                    if option.isOfficial {
                                        Text("官方")
                                            .scaledFont(size: 11, weight: .bold)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    Text(option.region)
                                        .scaledFont(size: 12, weight: .medium)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Text(option.url)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if let elapsed = speedResults[option.id] {
                                Text(String(format: "%.0f ms", elapsed * 1_000))
                                    .scaledFont(size: 12, weight: .semibold)
                                    .foregroundStyle(theme.textTertiary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await testSpeeds() }
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                }
                .disabled(isTesting)
            }
        }
    }

    @MainActor
    private func testSpeeds() async {
        isTesting = true
        defer { isTesting = false }
        var results: [String: TimeInterval] = [:]
        for option in options {
            if let elapsed = await LocalAlpineTerminalService.shared.testMirror(option, kind: kind) {
                results[option.id] = elapsed
            }
        }
        speedResults = results
    }
}

#Preview {
    NavigationStack {
        StorageSettingsView()
    }
}
