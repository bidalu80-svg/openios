import SwiftUI

struct LocalMCPAgentSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var service = LocalMCPAgentService.shared
    @State private var editingConnection: LocalMCPAgentConnection?
    @State private var showCreateSheet = false
    @State private var showGuide = true
    @State private var deletingConnection: LocalMCPAgentConnection?
    @State private var verificationMessage: String?

    var body: some View {
        List {
            Section {
                introCard
            } footer: {
                Text("这里不连接后端，配置只保存在当前设备。HTTP MCP 只允许 localhost 和局域网地址；Local Alpine 命令只做入口检测，不会自动启动长驻服务。")
            }

            Section {
                guideCard
            } header: {
                Text("怎么接入")
            } footer: {
                Text("如果只是想让 AI 扮演某个角色，优先用“技能”写角色卡；需要角色库、长期记忆、文件工具时，再接本地 MCP。")
            }

            Section {
                if service.connections.isEmpty {
                    emptyState
                } else {
                    ForEach(service.connections) { connection in
                        connectionRow(connection)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deletingConnection = connection
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("本地连接")
            } footer: {
                Text("适合接 DollhouseMCP 这类角色/Persona MCP，或接你自己在本机、局域网、Local Alpine 里启动的 MCP Server。")
            }

            Section {
                roleplayTemplate
            } header: {
                Text("角色类 MCP")
            } footer: {
                Text("角色扮演建议优先用本地技能/角色卡注入，MCP 只扩展记忆、文件、检索和工具。这样即使没有后端，也能保持稳定。")
            }
        }
        .navigationTitle("MCP 智能体")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增 MCP 智能体")
            }
        }
        .sheet(item: $editingConnection) { connection in
            LocalMCPAgentEditorView(connection: connection) { updated in
                service.upsert(updated)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            LocalMCPAgentEditorView(connection: nil) { created in
                service.upsert(created)
            }
        }
        .confirmationDialog(
            "删除“\(deletingConnection?.displayName ?? "")”？",
            isPresented: Binding(
                get: { deletingConnection != nil },
                set: { if !$0 { deletingConnection = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let deletingConnection {
                    service.delete(deletingConnection)
                }
                deletingConnection = nil
            }
            Button("取消", role: .cancel) {
                deletingConnection = nil
            }
        } message: {
            Text("删除后只会移除本机配置，不会删除外部 MCP 服务或 Alpine 文件。")
        }
        .alert("检测结果", isPresented: Binding(
            get: { verificationMessage != nil },
            set: { if !$0 { verificationMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(verificationMessage ?? "")
        }
    }

    private var introCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 42, height: 42)
                .background(theme.brandPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("本地 MCP 智能体")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text("管理角色、记忆、文件和工具类 MCP 的本地入口。当前阶段只保存配置和检测连接，不改动聊天主链路。")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showGuide.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .scaledFont(size: 18, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地 MCP 使用流程")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text("安装、启动、填写地址、检测连接")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(showGuide ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if showGuide {
                VStack(alignment: .leading, spacing: 10) {
                    guideStep(
                        index: 1,
                        title: "先准备一个本地 MCP",
                        detail: "例如 DollhouseMCP 这类 Persona/角色库 MCP，或 memory/filesystem/search 类 MCP。它需要在本机、局域网电脑，或 App 的 Local Alpine 里运行。"
                    )
                    guideStep(
                        index: 2,
                        title: "能跑 HTTP 就填 HTTP MCP",
                        detail: "启动 MCP 后，把 http://127.0.0.1:端口/路径 或局域网地址填进来。为了安全，这里不会接受公网地址。"
                    )
                    guideStep(
                        index: 3,
                        title: "只想记录命令就选 Local Alpine",
                        detail: "例如 npx、python、node 启动命令。当前版本只检测命令入口，不会自动拉包或自动常驻运行。"
                    )
                    guideStep(
                        index: 4,
                        title: "点检测，确认可用后启用",
                        detail: "启用后这条连接会保存在本机。后续要真正让聊天调用 MCP，再把它接入工具执行链路。"
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("角色扮演推荐")
                            .scaledFont(size: 13, weight: .bold)
                            .foregroundStyle(theme.textPrimary)
                        Text("普通角色扮演：设置 > 技能，新建角色卡。复杂角色库：用 DollhouseMCP/Persona MCP 管理角色，再在这里保存本地连接。")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("DollhouseMCP 引导安装示例：npx @dollhousemcp/mcp-server@latest --web")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, 2)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .background(theme.brandPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    private func guideStep(index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(theme.brandOnPrimary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.brandPrimary))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .scaledFont(size: 30, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            Text("还没有本地 MCP 智能体")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("点右上角加号，先添加一个 DollhouseMCP、memory MCP 或你自己的本地 MCP 服务。")
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var roleplayTemplate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("推荐方向：DollhouseMCP / Persona MCP", systemImage: "theatermasks")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("它们更像“角色和人格资产库”，可以让模型读取指定人格、语气、背景设定和记忆片段。接入时建议先在 Local Alpine 里安装并启动，再把本地 HTTP 地址或启动命令填到这里。")
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showCreateSheet = true
            } label: {
                Label("添加角色类 MCP", systemImage: "plus.circle.fill")
                    .scaledFont(size: 15, weight: .semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.brandPrimary)
        }
        .padding(.vertical, 4)
    }

    private func connectionRow(_ connection: LocalMCPAgentConnection) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(statusColor(connection.lastStatus).opacity(0.13))
                    .frame(width: 38, height: 38)
                Image(systemName: connection.transport == .streamableHTTP ? "network" : "terminal")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(statusColor(connection.lastStatus))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(connection.displayName)
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    statusPill(connection.lastStatus)
                }
                Text(connection.summary)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                if !connection.description.isEmpty {
                    Text(connection.description)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task {
                    let result = await service.verify(connection)
                    verificationMessage = result.message
                }
            } label: {
                if service.verifyingIDs.contains(connection.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.seal")
                        .scaledFont(size: 18, weight: .medium)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.brandPrimary)
            .accessibilityLabel("检测 MCP 连接")

            Toggle("", isOn: Binding(
                get: { connection.isEnabled },
                set: { _ in service.toggle(connection) }
            ))
            .labelsHidden()
            .tint(theme.brandPrimary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingConnection = connection
        }
    }

    private func statusPill(_ status: LocalMCPAgentStatus) -> some View {
        Text(status.label)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.12))
            .clipShape(Capsule())
    }

    private func statusColor(_ status: LocalMCPAgentStatus) -> Color {
        switch status {
        case .untested:
            return theme.textTertiary
        case .available:
            return .green
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }
}

private struct LocalMCPAgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let original: LocalMCPAgentConnection?
    let onSave: (LocalMCPAgentConnection) -> Void

    @State private var name: String
    @State private var description: String
    @State private var transport: LocalMCPAgentTransport
    @State private var endpoint: String
    @State private var command: String
    @State private var headersText: String
    @State private var isEnabled: Bool
    @State private var validationError: String?

    init(connection: LocalMCPAgentConnection?, onSave: @escaping (LocalMCPAgentConnection) -> Void) {
        self.original = connection
        self.onSave = onSave
        _name = State(initialValue: connection?.name ?? "")
        _description = State(initialValue: connection?.description ?? "")
        _transport = State(initialValue: connection?.transport ?? .streamableHTTP)
        _endpoint = State(initialValue: connection?.endpoint ?? "")
        _command = State(initialValue: connection?.command ?? "")
        _headersText = State(initialValue: Self.headersText(from: connection?.headers ?? [:]))
        _isEnabled = State(initialValue: connection?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如 DollhouseMCP", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("描述，例如 角色卡和 Persona 管理", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("启用", isOn: $isEnabled)
                        .tint(theme.brandPrimary)
                } header: {
                    Text("基础")
                }

                Section {
                    Picker("类型", selection: $transport) {
                        ForEach(LocalMCPAgentTransport.allCases) { item in
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.subtitle)
                            }
                            .tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("连接方式")
                }

                if transport == .streamableHTTP {
                    Section {
                        TextField("http://127.0.0.1:3000/mcp", text: $endpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("请求头，每行 Key: Value", text: $headersText, axis: .vertical)
                            .lineLimit(3...8)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("HTTP MCP")
                    } footer: {
                        Text("纯本地模式只允许 localhost、127.0.0.1、192.168.x.x、10.x.x.x、172.16-31.x.x 和 .local 地址。")
                    }
                } else {
                    Section {
                        TextField("例如 npx -y @dollhousemcp/mcp-server", text: $command, axis: .vertical)
                            .lineLimit(2...6)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    } header: {
                        Text("Local Alpine 命令")
                    } footer: {
                        Text("保存后只检测命令入口是否存在，不会自动运行长驻 MCP。你可以先在终端安装依赖，再回这里检测。")
                    }
                }
            }
            .navigationTitle(original == nil ? "新增 MCP" : "编辑 MCP")
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
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationError = "名称不能为空。"
            return
        }
        if transport == .streamableHTTP, trimmedEndpoint.isEmpty {
            validationError = "HTTP MCP 端点不能为空。"
            return
        }
        if transport == .localAlpineCommand, trimmedCommand.isEmpty {
            validationError = "Local Alpine 命令不能为空。"
            return
        }

        var next = original ?? LocalMCPAgentConnection()
        next.name = trimmedName
        next.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        next.transport = transport
        next.endpoint = trimmedEndpoint
        next.command = trimmedCommand
        next.headers = Self.headers(from: headersText)
        next.isEnabled = isEnabled
        onSave(next)
        dismiss()
    }

    private static func headersText(from headers: [String: String]) -> String {
        headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func headers(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
