import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct SoulDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}

private struct SoulShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SoulSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var service = LocalSoulService.shared
    @State private var draftName = ""
    @State private var draftContent = ""
    @State private var showImportPicker = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showResetConfirmation = false
    @State private var importErrorMessage: String?

    private var hasChanges: Bool {
        draftName != service.profile.name || draftContent != service.profile.content
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { service.profile.isEnabled },
                    set: { service.setEnabled($0) }
                )) {
                    Label("启用 SOUL", systemImage: "sparkles")
                }
                .tint(theme.brandPrimary)

                TextField("名称", text: $draftName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("人设文件")
            } footer: {
                Text("SOUL 会作为本地长期人设注入聊天上下文，用来稳定 AI 的身份、语气、边界和偏好。")
            }

            Section {
                soulEditor
            } header: {
                Text("内容")
            } footer: {
                Text("建议写成 Markdown。当前用户消息、会话系统提示词和安全规则仍然优先。")
            }

            Section {
                Button {
                    saveDraft()
                    showImportPicker = true
                } label: {
                    Label("导入 SOUL.md", systemImage: "doc.badge.plus")
                }

                Button {
                    saveDraft()
                    exportSoul()
                } label: {
                    Label("导出 SOUL.md", systemImage: "square.and.arrow.up")
                }
                .disabled(!service.hasContent && draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("清空 SOUL", systemImage: "trash")
                }
                .disabled(!service.hasContent && draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("文件")
            }
        }
        .navigationTitle("SOUL 人设")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    saveDraft()
                    Haptics.play(.light)
                }
                .disabled(!hasChanges)
            }
        }
        .onAppear {
            syncDraft()
        }
        .onDisappear {
            saveDraft()
        }
        .sheet(isPresented: $showImportPicker) {
            SoulDocumentPicker(types: Self.importDocumentTypes) { url in
                importSoul(from: url)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            SoulShareSheet(items: shareItems)
        }
        .confirmationDialog(
            "清空 SOUL？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                service.reset()
                syncDraft()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后本地人设不会再注入聊天上下文。")
        }
        .alert("无法导入 SOUL", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    private var soulEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draftContent)
                .font(.body)
                .frame(minHeight: 300)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -4)

            if draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("写下长期人设、说话风格、使用偏好、边界和需要长期遵守的规则…")
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, 8)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private static var importDocumentTypes: [UTType] {
        var types: [UTType] = []
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        if let markdownLong = UTType(filenameExtension: "markdown") {
            types.append(markdownLong)
        }
        types.append(.plainText)
        return types
    }

    private func syncDraft() {
        draftName = service.profile.name
        draftContent = service.profile.content
    }

    private func saveDraft() {
        guard hasChanges else { return }
        let cleanName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        service.update(
            name: cleanName.isEmpty ? "SOUL" : cleanName,
            content: draftContent
        )
    }

    private func importSoul(from url: URL) {
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
                importErrorMessage = "文件编码无法识别，请使用 UTF-8 Markdown 文件。"
                return
            }
            service.importMarkdown(text, fallbackName: url.deletingPathExtension().lastPathComponent)
            syncDraft()
            Haptics.play(.light)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func exportSoul() {
        do {
            let filename = "\(safeFilename(service.profile.name)).md"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try service.markdownDocument().write(to: url, atomically: true, encoding: .utf8)
            shareItems = [url]
            showShareSheet = true
            Haptics.play(.light)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func safeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "SOUL" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let sanitized = base.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return sanitized.isEmpty
            ? "SOUL"
            : sanitized
    }
}
