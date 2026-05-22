import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import UIKit

struct LocalWorkspaceFileBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var currentPath = "/"
    @State private var pathHistory: [String] = []
    @State private var items: [TerminalFileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var previewItem: TerminalFileItem?
    @State private var shareURL: URL?
    @State private var confirmDeleteItem: TerminalFileItem?

    private var runtimePath: String {
        currentPath == "/" ? "/mnt/iexa" : "/mnt/iexa\(currentPath)"
    }

    private var pathSegments: [(name: String, path: String)] {
        let components = currentPath.split(separator: "/").map(String.init)
        var segments: [(name: String, path: String)] = [("mnt", "/"), ("iexa", "/")]
        var accumulated = ""
        for component in components {
            accumulated += "/\(component)"
            segments.append((component, accumulated))
        }
        return segments
    }

    private var filteredItems: [TerminalFileItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    workspaceHeader
                    breadcrumbBar
                    Divider().foregroundStyle(theme.cardBorder.opacity(0.35))
                    content
                }
            }
            .navigationTitle("浏览文件")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索文件")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadDirectory() }
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                }
            }
        }
        .task {
            await loadDirectory()
        }
        .sheet(item: $previewItem) { item in
            LocalWorkspaceFilePreviewSheet(
                item: item,
                onDeleted: {
                    previewItem = nil
                    Task { await loadDirectory() }
                }
            )
        }
        .sheet(item: $shareURL, onDismiss: { shareURL = nil }) { url in
            ShareSheetView(activityItems: [url])
        }
        .confirmationDialog(
            "删除 \(confirmDeleteItem?.name ?? "")？",
            isPresented: Binding(
                get: { confirmDeleteItem != nil },
                set: { if !$0 { confirmDeleteItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = confirmDeleteItem {
                    Task { await delete(item) }
                }
                confirmDeleteItem = nil
            }
            Button("取消", role: .cancel) {
                confirmDeleteItem = nil
            }
        } message: {
            Text("这个操作会从当前 /mnt/iexa 工作区移除该项目，无法撤销。")
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 42, height: 42)
                .background(theme.brandPrimary.opacity(theme.isDark ? 0.18 : 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("/mnt/iexa")
                    .scaledFont(size: 17, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                Text("当前本地 Alpine 工作区")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 0)

            if currentPath != "/" {
                Button {
                    navigateBack()
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "chevron.backward")
                        .scaledFont(size: 13, weight: .bold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(theme.surfaceContainer.opacity(0.7))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pathSegments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 9, weight: .bold)
                            .foregroundStyle(theme.textTertiary)
                    }
                    Button {
                        navigateToPath(segment.path)
                        Haptics.play(.light)
                    } label: {
                        Text(segment.name)
                            .scaledFont(size: 12, weight: segment.path == currentPath ? .bold : .medium)
                            .foregroundStyle(segment.path == currentPath ? theme.brandPrimary : theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(segment.path == currentPath ? theme.brandPrimary.opacity(0.11) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            emptyState(icon: "folder", title: "正在读取工作区", subtitle: "正在加载 \(runtimePath)")
        } else if let errorMessage {
            VStack(spacing: 12) {
                emptyState(icon: "exclamationmark.triangle", title: "无法读取文件", subtitle: errorMessage)
                Button("重新加载") {
                    Task { await loadDirectory() }
                }
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            }
        } else if filteredItems.isEmpty {
            emptyState(
                icon: searchText.isEmpty ? "folder" : "magnifyingglass",
                title: searchText.isEmpty ? "这个目录是空的" : "没有找到文件",
                subtitle: searchText.isEmpty ? "AI 写入的文件会出现在这里。" : "换个关键词再试试。"
            )
        } else {
            List {
                Section {
                    ForEach(filteredItems) { item in
                        fileRow(item)
                            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(theme.cardBorder.opacity(0.28))
                    }
                } footer: {
                    Text("\(filteredItems.count) 个项目 · \(runtimePath)")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, 4)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await loadDirectory() }
        }
    }

    private func fileRow(_ item: TerminalFileItem) -> some View {
        Button {
            if item.isDirectory {
                navigateToDirectory(item.path)
            } else {
                previewItem = item
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 12) {
                fileIcon(for: item)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(fileSubtitle(for: item))
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: item.isDirectory ? "chevron.right" : "eye")
                    .scaledFont(size: item.isDirectory ? 12 : 13, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDeleteItem = item
            } label: {
                Label("删除", systemImage: "trash")
            }

            if !item.isDirectory {
                Button {
                    Task { shareURL = await temporaryURL(for: item) }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .tint(theme.brandPrimary)
            }
        }
        .contextMenu {
            if item.isDirectory {
                Button {
                    navigateToDirectory(item.path)
                } label: {
                    Label("打开", systemImage: "folder")
                }
            } else {
                Button {
                    previewItem = item
                } label: {
                    Label("预览", systemImage: "eye")
                }

                Button {
                    Task { shareURL = await temporaryURL(for: item) }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                UIPasteboard.general.string = "/mnt/iexa\(item.path == "/" ? "" : item.path)"
                Haptics.notify(.success)
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                confirmDeleteItem = item
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func fileIcon(for item: TerminalFileItem) -> some View {
        Image(systemName: item.iconName)
            .scaledFont(size: 19, weight: .semibold)
            .foregroundStyle(item.isDirectory ? theme.brandPrimary : iconColor(for: item))
            .frame(width: 42, height: 42)
            .background(iconColor(for: item).opacity(item.isDirectory ? 0.10 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .scaledFont(size: 30, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
            Text(title)
                .scaledFont(size: 16, weight: .bold)
                .foregroundStyle(theme.textPrimary)
            Text(subtitle)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await LocalAlpineTerminalService.shared.listFiles(path: currentPath, includeHidden: true)
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func navigateToDirectory(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        searchText = ""
        Task { await loadDirectory() }
    }

    private func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        pathHistory.append(currentPath)
        currentPath = path
        searchText = ""
        Task { await loadDirectory() }
    }

    private func navigateBack() {
        if let previous = pathHistory.popLast() {
            currentPath = previous
        } else {
            let parent = (currentPath as NSString).deletingLastPathComponent
            currentPath = parent.isEmpty ? "/" : parent
        }
        searchText = ""
        Task { await loadDirectory() }
    }

    private func delete(_ item: TerminalFileItem) async {
        do {
            try await LocalAlpineTerminalService.shared.deleteItem(path: item.path)
            items.removeAll { $0.path == item.path }
            Haptics.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
    }

    private func temporaryURL(for item: TerminalFileItem) async -> URL? {
        guard !item.isDirectory else { return nil }
        do {
            let data = try await LocalAlpineTerminalService.shared.readFile(path: item.path)
            return try Self.writeTemporaryFile(data: data, fileName: item.name)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
            return nil
        }
    }

    private func fileSubtitle(for item: TerminalFileItem) -> String {
        if item.isDirectory { return "文件夹" }
        let kind = LocalWorkspaceFileKind(fileName: item.name)
        if let size = item.formattedSize {
            return "\(kind.label) · \(size)"
        }
        return kind.label
    }

    private func iconColor(for item: TerminalFileItem) -> Color {
        if item.isDirectory { return theme.brandPrimary }
        switch LocalWorkspaceFileKind(fileName: item.name) {
        case .code: return .orange
        case .text, .csv: return theme.textSecondary
        case .spreadsheet: return .green
        case .image: return .pink
        case .archive: return .brown
        case .pdf: return .red
        case .other: return theme.textTertiary
        }
    }

    private static func writeTemporaryFile(data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_workspace_browser", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = fileName.isEmpty ? "file" : fileName
        let url = directory.appendingPathComponent(safeName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct LocalWorkspaceFilePreviewSheet: View {
    let item: TerminalFileItem
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var data: Data?
    @State private var text: String?
    @State private var temporaryFileURL: URL?
    @State private var quickLookURL: URL?
    @State private var shareURL: URL?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var confirmDelete = false

    private var kind: LocalWorkspaceFileKind {
        LocalWorkspaceFileKind(fileName: item.name)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    previewHeader
                    Divider().foregroundStyle(theme.cardBorder.opacity(0.35))
                    previewBody
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let text {
                            Button {
                                UIPasteboard.general.string = text
                                copied = true
                                Haptics.notify(.success)
                                resetCopiedState()
                            } label: {
                                Label(copied ? "已复制" : "复制内容", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                        }

                        Button {
                            Task { await shareCurrentFile() }
                        } label: {
                            Label("分享文件", systemImage: "square.and.arrow.up")
                        }

                        if temporaryFileURL != nil || data != nil {
                            Button {
                                Task { await openQuickLook() }
                            } label: {
                                Label("系统预览", systemImage: "eye")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .scaledFont(size: 18, weight: .semibold)
                    }
                }
            }
        }
        .task {
            await loadFile()
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $shareURL, onDismiss: { shareURL = nil }) { url in
            ShareSheetView(activityItems: [url])
        }
        .confirmationDialog("删除 \(item.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await deleteFile() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这个操作会从当前 /mnt/iexa 工作区删除该文件，无法撤销。")
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(iconColor)
                .frame(width: 42, height: 42)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(previewSubtitle)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var previewBody: some View {
        if isLoading {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("正在读取文件")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .scaledFont(size: 30, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                Text(errorMessage)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
                Button("重新读取") {
                    Task { await loadFile() }
                }
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if kind == .csv, let text {
            LocalWorkspaceCSVPreview(text: text)
        } else if kind.isTextPreviewable, let text {
            GeometryReader { proxy in
                ScrollView {
                    SourceCodeTextView(
                        code: text,
                        language: LocalWorkspaceFileKind.languageHint(for: item.name),
                        maxHeight: max(280, proxy.size.height - 24),
                        wrapLines: true
                    )
                    .background(theme.surfaceContainer.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.cardBorder.opacity(0.45), lineWidth: 0.5)
                    )
                    .padding(16)
                }
            }
        } else {
            nativePreviewPrompt
        }
    }

    private var nativePreviewPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: kind == .spreadsheet ? "tablecells" : item.iconName)
                .scaledFont(size: 42, weight: .semibold)
                .foregroundStyle(iconColor)
                .frame(width: 76, height: 76)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text(kind == .spreadsheet ? "使用系统方式预览表格" : "使用系统方式预览文件")
                .scaledFont(size: 17, weight: .bold)
                .foregroundStyle(theme.textPrimary)
            Text("支持 Excel、PDF、图片和其它 iOS 可识别的文件类型。")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 42)
            Button {
                Task { await openQuickLook() }
            } label: {
                Label("打开预览", systemImage: "eye")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundStyle(theme.brandOnPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(theme.brandPrimary))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var iconColor: Color {
        switch kind {
        case .code: return .orange
        case .text, .csv: return theme.textSecondary
        case .spreadsheet: return .green
        case .image: return .pink
        case .archive: return .brown
        case .pdf: return .red
        case .other: return theme.textTertiary
        }
    }

    private var previewSubtitle: String {
        var parts = [kind.label]
        if let size = item.formattedSize { parts.append(size) }
        parts.append("/mnt/iexa\(item.path == "/" ? "" : item.path)")
        return parts.joined(separator: " · ")
    }

    private func loadFile() async {
        isLoading = true
        errorMessage = nil
        do {
            let fileData = try await LocalAlpineTerminalService.shared.readFile(path: item.path)
            data = fileData
            if kind.isTextPreviewable {
                text = Self.decodeText(fileData)
            }
            if !kind.isTextPreviewable || kind == .spreadsheet {
                temporaryFileURL = try Self.writeTemporaryFile(data: fileData, fileName: item.name)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func shareCurrentFile() async {
        do {
            if let temporaryFileURL {
                shareURL = temporaryFileURL
                Haptics.play(.light)
                return
            }
            let fileData: Data
            if let data {
                fileData = data
            } else {
                fileData = try await LocalAlpineTerminalService.shared.readFile(path: item.path)
            }
            shareURL = try Self.writeTemporaryFile(data: fileData, fileName: item.name)
            Haptics.play(.light)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
    }

    private func openQuickLook() async {
        do {
            let fileURL: URL
            if let temporaryFileURL {
                fileURL = temporaryFileURL
            } else {
                let fileData = data ?? try await LocalAlpineTerminalService.shared.readFile(path: item.path)
                let writtenURL = try Self.writeTemporaryFile(data: fileData, fileName: item.name)
                temporaryFileURL = writtenURL
                fileURL = writtenURL
            }
            quickLookURL = fileURL
            Haptics.play(.light)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
    }

    private func deleteFile() async {
        do {
            try await LocalAlpineTerminalService.shared.deleteItem(path: item.path)
            Haptics.notify(.success)
            onDeleted()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
    }

    private func resetCopiedState() {
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                withAnimation(MicroAnimation.snappy) {
                    copied = false
                }
            }
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .ascii) { return text }
        return nil
    }

    private static func writeTemporaryFile(data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_workspace_preview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = fileName.isEmpty ? "file" : fileName
        let url = directory.appendingPathComponent(safeName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct LocalWorkspaceCSVPreview: View {
    let text: String

    @Environment(\.theme) private var theme

    private var rows: [[String]] {
        let parsed = text
            .split(whereSeparator: \.isNewline)
            .prefix(120)
            .map { line in
                line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        return Array(parsed)
    }

    private var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    var body: some View {
        if rows.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "tablecells")
                    .scaledFont(size: 32, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                Text("表格为空")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(0..<columnCount, id: \.self) { columnIndex in
                                Text(columnIndex < row.count ? row[columnIndex] : "")
                                    .font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(3)
                                    .frame(width: 132, minHeight: 38, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(rowIndex == 0 ? theme.surfaceContainerHighest.opacity(0.8) : theme.cardBackground.opacity(0.55))
                                    .border(theme.cardBorder.opacity(0.45), width: 0.5)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(theme.surfaceContainer.opacity(0.28))
        }
    }
}

private enum LocalWorkspaceFileKind: Equatable {
    case code
    case text
    case csv
    case spreadsheet
    case image
    case pdf
    case archive
    case other

    init(fileName: String) {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        let codeExtensions: Set<String> = [
            "py", "js", "ts", "jsx", "tsx", "swift", "java", "kt", "c", "h", "cpp", "hpp",
            "m", "mm", "go", "rs", "rb", "php", "sh", "bash", "zsh", "html", "css", "scss",
            "json", "yaml", "yml", "xml", "toml", "sql", "dockerfile", ".gitignore", ".env"
        ]
        let textExtensions: Set<String> = ["txt", "md", "log", "rtf", "ini", "cfg", "conf"]
        let spreadsheetExtensions: Set<String> = ["xls", "xlsx", "numbers"]
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "ico"]
        let archiveExtensions: Set<String> = ["zip", "tar", "gz", "rar", "7z", "bz2", "xz"]

        if ext == "csv" {
            self = .csv
        } else if codeExtensions.contains(ext) || codeExtensions.contains(name) {
            self = .code
        } else if textExtensions.contains(ext) {
            self = .text
        } else if spreadsheetExtensions.contains(ext) {
            self = .spreadsheet
        } else if imageExtensions.contains(ext) {
            self = .image
        } else if ext == "pdf" {
            self = .pdf
        } else if archiveExtensions.contains(ext) {
            self = .archive
        } else {
            self = .other
        }
    }

    var isTextPreviewable: Bool {
        switch self {
        case .code, .text, .csv:
            return true
        case .spreadsheet, .image, .pdf, .archive, .other:
            return false
        }
    }

    static func languageHint(for fileName: String) -> String {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext.isEmpty ? name : ext {
        case "py": return "python"
        case "js", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "swift": return "swift"
        case "java": return "java"
        case "kt": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "hpp", "mm": return "cpp"
        case "go": return "go"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "php": return "php"
        case "sh", "bash", "zsh": return "bash"
        case "html": return "html"
        case "css", "scss": return "css"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "xml": return "xml"
        case "toml": return "toml"
        case "sql": return "sql"
        case "md": return "markdown"
        case "csv": return "csv"
        case "dockerfile": return "dockerfile"
        case ".env": return "bash"
        case ".gitignore": return "text"
        default: return "text"
        }
    }

    var label: String {
        switch self {
        case .code: return "代码文件"
        case .text: return "文本文件"
        case .csv: return "CSV 表格"
        case .spreadsheet: return "Excel 表格"
        case .image: return "图片"
        case .pdf: return "PDF"
        case .archive: return "压缩包"
        case .other: return "文件"
        }
    }
}
