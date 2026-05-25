import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct LocalSkillDocumentPicker: UIViewControllerRepresentable {
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

struct LocalSkillsSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var service = LocalSkillsService.shared
    @State private var editingSkill: LocalSkill?
    @State private var showCreateSheet = false
    @State private var showImportPicker = false
    @State private var deletingSkill: LocalSkill?
    @State private var importErrorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(service.skills) { skill in
                    Button {
                        editingSkill = skill
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(skill.isBuiltin ? Color.green.opacity(0.14) : theme.brandPrimary.opacity(0.12))
                                    .frame(width: 38, height: 38)
                                Image(systemName: skill.isBuiltin ? "cube.box.fill" : "brain")
                                    .scaledFont(size: 16, weight: .semibold)
                                    .foregroundStyle(skill.isBuiltin ? .green : theme.brandPrimary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(skill.name)
                                        .scaledFont(size: 16, weight: .semibold)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    if skill.isBuiltin {
                                        Image(systemName: "cube.box")
                                            .scaledFont(size: 13, weight: .medium)
                                            .foregroundStyle(.green)
                                    }
                                }
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .scaledFont(size: 13)
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 8)

                            Toggle("", isOn: Binding(
                                get: { skill.isEnabled },
                                set: { _ in service.toggle(skill) }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !skill.isBuiltin {
                            Button(role: .destructive) {
                                deletingSkill = skill
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        } else {
                            Button {
                                service.resetBuiltin(skill)
                            } label: {
                                Label("重置", systemImage: "arrow.counterclockwise")
                            }
                            .tint(.orange)
                        }
                    }
                }
            } header: {
                Text("本地技能")
            } footer: {
                Text("启用后的技能会直接注入本轮模型上下文，不依赖服务器。适合保存固定工作流、项目规则和工具使用习惯。")
            }
        }
        .navigationTitle("技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showImportPicker = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .accessibilityLabel("从 Markdown 导入技能")

                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建技能")
            }
        }
        .sheet(item: $editingSkill) { skill in
            LocalSkillEditorView(skill: skill) { updated in
                service.upsert(updated)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            LocalSkillEditorView(skill: nil) { created in
                service.upsert(created)
            }
        }
        .sheet(isPresented: $showImportPicker) {
            LocalSkillDocumentPicker(types: Self.importDocumentTypes) { url in
                importMarkdownSkill(from: url)
            }
        }
        .confirmationDialog(
            "删除“\(deletingSkill?.name ?? "")”？",
            isPresented: Binding(
                get: { deletingSkill != nil },
                set: { if !$0 { deletingSkill = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let deletingSkill {
                    service.delete(deletingSkill)
                }
                deletingSkill = nil
            }
            Button("取消", role: .cancel) {
                deletingSkill = nil
            }
        } message: {
            Text("删除后无法恢复。")
        }
        .alert("无法导入技能", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
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

    private func importMarkdownSkill(from url: URL) {
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
            guard let parsed = LocalSkillMarkdownImportParser.parse(
                text: text,
                filename: url.deletingPathExtension().lastPathComponent
            ) else {
                importErrorMessage = "没有找到可导入的技能内容。"
                return
            }
            service.upsert(uniqueSkill(from: parsed))
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func uniqueSkill(from skill: LocalSkill) -> LocalSkill {
        let existingIds = Set(service.skills.map(\.id))
        guard existingIds.contains(skill.id) else { return skill }

        var next = skill
        var suffix = 2
        while existingIds.contains("\(skill.id)-\(suffix)") {
            suffix += 1
        }
        next.id = "\(skill.id)-\(suffix)"
        next.name = "\(skill.name) \(suffix)"
        return next
    }
}

private enum LocalSkillMarkdownImportParser {
    static func parse(text: String, filename: String) -> LocalSkill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let (metadata, body) = splitFrontmatter(from: normalized)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return nil }

        let fallbackName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredName = metadata["name"]
            ?? firstMarkdownHeading(in: trimmedBody)
            ?? (fallbackName.isEmpty ? "本地技能" : fallbackName)
        let name = inferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let description = metadata["description"]
            ?? firstPlainParagraph(in: trimmedBody)
            ?? ""

        return LocalSkill(
            id: slug(from: name),
            name: name,
            description: description,
            content: trimmedBody,
            isEnabled: true,
            isBuiltin: false,
            updatedAt: Date()
        )
    }

    private static func splitFrontmatter(from text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ([:], text)
        }

        var closingIndex: Int?
        for index in lines.indices.dropFirst() {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" || trimmed == "..." {
                closingIndex = index
                break
            }
        }

        guard let closingIndex else {
            return ([:], text)
        }

        var metadata: [String: String] = [:]
        for line in lines[1..<closingIndex] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "name" || key == "description" {
                metadata[key] = unquote(value)
            }
        }

        let body = lines.dropFirst(closingIndex + 1).joined(separator: "\n")
        return (metadata, body)
    }

    private static func firstMarkdownHeading(in text: String) -> String? {
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#") else { continue }
            let title = line
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private static func firstPlainParagraph(in text: String) -> String? {
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("#"), !line.hasPrefix("```"), !line.hasPrefix("---") else { continue }
            line = line.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if line.count > 120 {
                return String(line.prefix(117)) + "..."
            }
            return line
        }
        return nil
    }

    private static func slug(from value: String) -> String {
        let base = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fa5}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? "skill-\(UUID().uuidString.prefix(8).lowercased())" : base
    }

    private static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2,
           let first = text.first,
           let last = text.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            text.removeFirst()
            text.removeLast()
        }
        return text
    }
}

private struct LocalSkillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let original: LocalSkill?
    let onSave: (LocalSkill) -> Void

    @State private var name: String
    @State private var description: String
    @State private var content: String
    @State private var isEnabled: Bool
    @State private var validationError: String?

    init(skill: LocalSkill?, onSave: @escaping (LocalSkill) -> Void) {
        self.original = skill
        self.onSave = onSave
        _name = State(initialValue: skill?.name ?? "")
        _description = State(initialValue: skill?.description ?? "")
        _content = State(initialValue: skill?.content ?? "")
        _isEnabled = State(initialValue: skill?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("描述", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("启用", isOn: $isEnabled)
                } header: {
                    Text("基础")
                }

                Section {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 260)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                } header: {
                    Text("内容")
                } footer: {
                    Text("写清楚什么时候使用、怎么执行、怎么验证。内容会作为系统上下文注入给模型。")
                }
            }
            .navigationTitle(original == nil ? "新建技能" : original?.name ?? "编辑技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .alert("无法保存", isPresented: Binding(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(validationError ?? "")
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "名称不能为空。"
            return
        }
        guard !trimmedContent.isEmpty else {
            validationError = "内容不能为空。"
            return
        }

        let id = original?.id ?? Self.slug(from: trimmedName)
        onSave(LocalSkill(
            id: id,
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            content: trimmedContent,
            isEnabled: isEnabled,
            isBuiltin: original?.isBuiltin ?? false,
            updatedAt: Date()
        ))
        dismiss()
    }

    private static func slug(from value: String) -> String {
        let base = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fa5}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? "skill-\(UUID().uuidString.prefix(8).lowercased())" : base
    }
}
