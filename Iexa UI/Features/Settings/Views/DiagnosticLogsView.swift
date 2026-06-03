import SwiftUI
import UIKit

struct DiagnosticLogsView: View {
    @Environment(\.theme) private var theme
    @State private var files: [DiagnosticLogFile] = []
    @State private var shareURL: URL?
    @State private var showingShareSheet = false
    @State private var showingClearAlert = false
    @State private var exportErrorMessage: String?

    private let manager = DiagnosticLogManager.shared

    private var displayFiles: [DiagnosticLogFile] {
        files.sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if files.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(displayFiles) { file in
                            NavigationLink {
                                DiagnosticLogFileView(file: file)
                            } label: {
                                DiagnosticLogFileRow(file: file)
                            }
                        }
                        .onDelete(perform: deleteFiles)
                    } header: {
                        Text(manager.summaryText)
                    } footer: {
                        Text("日志仅记录运行状态、网络状态和错误摘要；常见 token、key、cookie 会在写入前脱敏。")
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    reload()
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        shareAllLogs()
                    } label: {
                        Label("分享全部日志", systemImage: "square.and.arrow.up")
                    }
                    .disabled(files.isEmpty)

                    Button(role: .destructive) {
                        showingClearAlert = true
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                    .disabled(files.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showingShareSheet, onDismiss: cleanupShareURL) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("清空诊断日志？", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                manager.clear()
                reload()
            }
        } message: {
            Text("这会删除本机保存的所有诊断日志。")
        }
        .alert(
            "无法导出日志",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .scaledFont(size: 40, weight: .regular)
                .foregroundStyle(theme.textTertiary)

            VStack(spacing: Spacing.xs) {
                Text("暂无诊断日志")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text("应用运行后会自动记录网络、聊天和错误摘要，最多保留 7 天。")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        files = manager.logFiles()
    }

    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            manager.deleteFile(displayFiles[index])
        }
        reload()
    }

    private func shareAllLogs() {
        guard let url = manager.exportAllURL() else {
            exportErrorMessage = "没有可导出的日志文件。"
            return
        }
        shareURL = url
        showingShareSheet = true
    }

    private func cleanupShareURL() {
        if let shareURL {
            try? FileManager.default.removeItem(at: shareURL)
        }
        shareURL = nil
    }
}

private struct DiagnosticLogFileRow: View {
    let file: DiagnosticLogFile

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "doc.text")
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(.blue)
                .frame(width: IconSize.lg, height: IconSize.lg)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(file.displayName)
                        .scaledFont(size: 16, weight: .medium)
                    if !file.sessionLabel.isEmpty {
                        Text(file.sessionLabel)
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(file.sizeText)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DiagnosticLogFileView: View {
    let file: DiagnosticLogFile

    @Environment(\.theme) private var theme
    @State private var entries: [DiagnosticLogEntry] = []
    @State private var selectedLevel: DiagnosticLogLevel?
    @State private var shareURL: URL?
    @State private var showingShareSheet = false
    @State private var exportErrorMessage: String?

    private let manager = DiagnosticLogManager.shared

    private var filteredEntries: [DiagnosticLogEntry] {
        guard let selectedLevel else { return entries }
        return entries.filter { $0.level == selectedLevel }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        filterBar
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                        ForEach(filteredEntries) { entry in
                            NavigationLink {
                                DiagnosticLogEntryDetailView(entry: entry)
                            } label: {
                                DiagnosticLogEntryRow(entry: entry)
                            }
                        }
                    } footer: {
                        Text("日志内容已在写入时脱敏。分享前仍建议快速检查一次。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(file.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        copyAllEntries()
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    .disabled(entries.isEmpty)

                    Button {
                        shareFile()
                    } label: {
                        Label("分享此文件", systemImage: "square.and.arrow.up")
                    }
                    .disabled(entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showingShareSheet, onDismiss: cleanupShareURL) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert(
            "无法导出日志",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .scaledFont(size: 36, weight: .regular)
                .foregroundStyle(theme.textTertiary)
            Text("这个日志文件还没有可显示的条目")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                DiagnosticLogFilterChip(
                    title: "全部",
                    count: entries.count,
                    isSelected: selectedLevel == nil,
                    tint: .blue
                ) {
                    selectedLevel = nil
                }

                ForEach(DiagnosticLogLevel.allCases, id: \.self) { level in
                    DiagnosticLogFilterChip(
                        title: level.label,
                        count: entries.filter { $0.level == level }.count,
                        isSelected: selectedLevel == level,
                        tint: level.color
                    ) {
                        selectedLevel = level
                    }
                }
            }
        }
    }

    private func reload() {
        entries = manager.entries(for: file)
    }

    private func copyAllEntries() {
        UIPasteboard.general.string = entries
            .map { DiagnosticLogFormatter.line($0) }
            .joined(separator: "\n")
    }

    private func shareFile() {
        guard let url = manager.exportSingleFileURL(file) else {
            exportErrorMessage = "无法生成分享文件。"
            return
        }
        shareURL = url
        showingShareSheet = true
    }

    private func cleanupShareURL() {
        if let shareURL {
            try? FileManager.default.removeItem(at: shareURL)
        }
        shareURL = nil
    }
}

private struct DiagnosticLogFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .fontWeight(.semibold)
            }
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(isSelected ? .white : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? tint : tint.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DiagnosticLogEntryRow: View {
    let entry: DiagnosticLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(entry.level.shortLabel)
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(entry.level.color)
                    .clipShape(Circle())

                Text(entry.category)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.primary)

                Spacer()

                Text(DiagnosticLogFormatter.timeString(from: entry.date))
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .scaledFont(size: 13)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

private struct DiagnosticLogEntryDetailView: View {
    let entry: DiagnosticLogEntry

    var body: some View {
        List {
            Section("信息") {
                LabeledContent("级别", value: entry.level.label)
                LabeledContent("分类", value: entry.category)
                LabeledContent("时间", value: DiagnosticLogFormatter.fullString(from: entry.date))
            }

            Section("内容") {
                Text(entry.message)
                    .scaledFont(size: 14)
                    .textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("日志详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = DiagnosticLogFormatter.line(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("复制日志")
            }
        }
    }
}

private enum DiagnosticLogFormatter {
    static func timeString(from date: Date) -> String {
        formatter("HH:mm:ss").string(from: date)
    }

    static func fullString(from date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss.SSS").string(from: date)
    }

    static func line(_ entry: DiagnosticLogEntry) -> String {
        "[\(fullString(from: entry.date))] [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
    }

    private static func formatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

private extension DiagnosticLogLevel {
    var color: Color {
        switch self {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
