import SwiftUI

struct LocalSkillsSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var service = LocalSkillsService.shared
    @State private var editingSkill: LocalSkill?
    @State private var showCreateSheet = false
    @State private var deletingSkill: LocalSkill?

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
            ToolbarItem(placement: .topBarTrailing) {
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
                Section("基础") {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("描述", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("启用", isOn: $isEnabled)
                }

                Section("内容") {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 260)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
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
