import SwiftUI

struct LocalAlpineEnvironmentVariablesView: View {
    @Environment(\.theme) private var theme
    @State private var variables = LocalAlpineEnvironmentStore.shared.variables
    @State private var privacyMode = LocalAlpineEnvironmentStore.shared.privacyMode
    @State private var editor: LocalAlpineEnvironmentVariable?
    @State private var isAdding = false
    @State private var pendingDeletion: LocalAlpineEnvironmentVariable?

    var body: some View {
        List {
            Section {
                Toggle("隐私模式", isOn: $privacyMode)
                    .onChange(of: privacyMode) { _, enabled in
                        LocalAlpineEnvironmentStore.shared.privacyMode = enabled
                    }
            } header: {
                Text("隐私")
            } footer: {
                Text("开启后，shell_execute 输出中检测到的环境变量值会在送达模型前打码。少于 8 个字符的值会全部替换为 *；聊天中用户可见的命令输出保持不变。")
            }

            Section {
                if variables.isEmpty {
                    ContentUnavailableView(
                        "无环境变量",
                        systemImage: "terminal",
                        description: Text("点击右上角 + 添加。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(variables) { variable in
                        Button {
                            editor = variable
                        } label: {
                            variableRow(variable)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeletion = variable
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("变量")
            } footer: {
                Text("环境变量会在每次 Local Alpine 沙箱命令执行前注入。名称会自动转为大写，并且必须符合 POSIX shell 变量规则。")
            }
        }
        .navigationTitle("环境变量")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加环境变量")
            }
        }
        .sheet(isPresented: $isAdding) {
            LocalAlpineEnvironmentVariableEditor { reload() }
        }
        .sheet(item: $editor) { variable in
            LocalAlpineEnvironmentVariableEditor(variable: variable) { reload() }
        }
        .alert(
            "删除 \(pendingDeletion?.key ?? "")？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { variable in
            Button("删除", role: .destructive) {
                LocalAlpineEnvironmentStore.shared.delete(variable)
                reload()
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("这将永久删除该环境变量及其值。")
        }
        .onAppear(perform: reload)
    }

    private func variableRow(_ variable: LocalAlpineEnvironmentVariable) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 28, height: 28)
                .background(theme.brandPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(variable.key)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if !variable.note.isEmpty {
                    Text(variable.note)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("已安全保存")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 3)
    }

    private func reload() {
        variables = LocalAlpineEnvironmentStore.shared.variables
        privacyMode = LocalAlpineEnvironmentStore.shared.privacyMode
    }
}

private struct LocalAlpineEnvironmentVariableEditor: View {
    let variable: LocalAlpineEnvironmentVariable?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var value: String
    @State private var note: String
    @State private var isValueVisible = false
    @State private var errorMessage: String?

    init(
        variable: LocalAlpineEnvironmentVariable? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.variable = variable
        self.onSaved = onSaved
        _key = State(initialValue: variable?.key ?? "")
        _value = State(initialValue: variable.flatMap { LocalAlpineEnvironmentStore.shared.value(for: $0) } ?? "")
        _note = State(initialValue: variable?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    HStack(spacing: 8) {
                        Group {
                            if isValueVisible {
                                TextField("值", text: $value)
                            } else {
                                SecureField("值", text: $value)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            isValueVisible.toggle()
                        } label: {
                            Image(systemName: isValueVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("切换可见性")
                    }
                    TextField("备注（可选）", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("变量")
                } footer: {
                    Text("值只保存在设备 Keychain 中，不会写入聊天记录、设置配置或模型提示词。")
                }
            }
            .navigationTitle(variable == nil ? "添加变量" : "编辑变量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("无法保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            try LocalAlpineEnvironmentStore.shared.save(
                id: variable?.id,
                key: key,
                value: value,
                note: note
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
