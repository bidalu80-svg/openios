import SwiftUI

// MARK: - Tool Item Model

/// 表示溢出菜单里可用的工具。
struct ToolItem: Identifiable, Hashable {
    let id: String
    var name: String
    var description: String?
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
    }
}

// MARK: - Tools Menu Sheet

/// 用于展示附件入口、功能开关（网页搜索）和可展开工具列表的底部弹窗。
struct ToolsMenuSheet: View {
    @Binding var webSearchEnabled: Bool
    @Binding var imageGenerationEnabled: Bool
    @Binding var codeInterpreterEnabled: Bool
    @Binding var openAIFileSearchEnabled: Bool
    @Binding var openAIMCPEnabled: Bool
    @Binding var openAIToolSearchEnabled: Bool
    var isWebSearchAvailable: Bool = true
    var isImageGenerationAvailable: Bool = true
    var isCodeInterpreterAvailable: Bool = true
    var isOpenAINativeToolsAvailable: Bool = false
    var tools: [ToolItem]
    @Binding var selectedToolIds: Set<String>
    var isLoadingTools: Bool = false
    var onFileAttachment: (() -> Void)?
    var onPhotoAttachment: (() -> Void)?
    var onCameraCapture: (() -> Void)?
    var onWebAttachment: (() -> Void)?
    var onReferenceChatAttachment: (() -> Void)?
    /// 可选的自定义照片选择器视图（例如 SwiftUI PhotosPicker）。
    var photoPicker: AnyView?

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var toolsExpanded = true
    @State private var showOpenAINativeToolSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // 拖拽把手
            sheetHandle
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)

            ScrollView {
                VStack(spacing: Spacing.md) {
                    // 附件操作行
                    attachmentActionsRow
                        .padding(.horizontal, Spacing.md)

                    // 引用聊天入口
                    if let onReferenceChatAttachment {
                        referenceChatRow(action: onReferenceChatAttachment)
                            .padding(.horizontal, Spacing.md)
                    }

                    // 内置工具区（网页搜索、生图、代码解释器）
                    let hasBuiltins = isWebSearchAvailable || isImageGenerationAvailable || isCodeInterpreterAvailable
                    if hasBuiltins {
                        builtinToolsSection
                            .padding(.horizontal, Spacing.md)
                    }

                    if isOpenAINativeToolsAvailable {
                        openAINativeToolsSection
                            .padding(.horizontal, Spacing.md)
                    }

                    // 工具区
                    toolsSection
                        .padding(.horizontal, Spacing.md)
                }
                .padding(.bottom, Spacing.lg)
            }
        }
        .background(theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(CornerRadius.modal)
        .sheet(isPresented: $showOpenAINativeToolSettings) {
            OpenAINativeToolsSettingsSheet()
        }
    }

    // MARK: - Sheet Handle

    private var sheetHandle: some View {
        Capsule()
            .fill(theme.textTertiary.opacity(0.4))
            .frame(width: 36, height: 5)
    }

    // MARK: - Attachment Actions Row

    private var attachmentActionsRow: some View {
        HStack(spacing: Spacing.sm) {
            attachmentActionButton(
                icon: "doc",
                label: String(localized: "File"),
                action: onFileAttachment
            )

            // Use custom PhotosPicker if provided, otherwise fall back to callback
            if let photoPicker {
                photoPicker
            } else {
                attachmentActionButton(
                    icon: "photo",
                    label: String(localized: "Photo"),
                    action: onPhotoAttachment
                )
            }

            attachmentActionButton(
                icon: "camera",
                label: String(localized: "Camera"),
                action: onCameraCapture
            )
            attachmentActionButton(
                icon: "globe",
                label: String(localized: "Webpage"),
                action: onWebAttachment
            )
        }
    }

    private func attachmentActionButton(
        icon: String,
        label: String,
        action: (() -> Void)?
    ) -> some View {
        let isEnabled = action != nil

        return Button {
            // Dismiss the tools sheet first, then trigger the action
            // after a small delay to avoid sheet presentation conflicts.
            dismiss()
            if let action {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    action()
                }
            }
        } label: {
            VStack(spacing: Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.brandPrimary.opacity(isEnabled ? 0.2 : 0.08),
                                    theme.brandPrimary.opacity(isEnabled ? 0.12 : 0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(
                            isEnabled
                                ? theme.brandPrimary
                                : theme.iconDisabled
                        )
                }

                Text(label)
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        isEnabled
                            ? theme.textPrimary
                            : theme.textDisabled
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.92))
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(
                        theme.cardBorder.opacity(isEnabled ? 0.5 : 0.25),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : OpacityLevel.disabled)
        .accessibilityLabel(label)
    }

    // MARK: - Feature Toggles

    private var webSearchToggle: some View {
        featureToggleTile(
            icon: "magnifyingglass",
            title: "网页搜索",
            subtitle: "联网搜索并在回复中引用来源",
            isOn: $webSearchEnabled
        )
    }

    private var imageGenerationToggle: some View {
        featureToggleTile(
            icon: "photo.badge.plus",
            title: "图像生成",
            subtitle: "根据文字描述生成图片",
            isOn: $imageGenerationEnabled
        )
    }

    private var codeInterpreterToggle: some View {
        featureToggleTile(
            icon: "chevron.left.forwardslash.chevron.right",
            title: "代码解释器",
            subtitle: "内联运行代码并分析数据",
            isOn: $codeInterpreterEnabled
        )
    }

    private func featureToggleTile(
        icon: String,
        title: String,
        subtitle: String?,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(MicroAnimation.snappy) {
                isOn.wrappedValue.toggle()
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                // Icon glyph
                toolGlyph(
                    systemImage: icon,
                    isSelected: isOn.wrappedValue
                )

                // Title and subtitle
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .scaledFont(size: 14)
                        .fontWeight(isOn.wrappedValue ? .semibold : .medium)
                        .foregroundStyle(theme.textPrimary)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Toggle pill
                togglePill(isOn: isOn.wrappedValue)
            }
            .padding(Spacing.sm)
            .background(tileBackground(isOn: isOn.wrappedValue))
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(
                        tileBorderColor(isOn: isOn.wrappedValue),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Reference Chat Row

    private func referenceChatRow(action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
        } label: {
            HStack(spacing: Spacing.sm) {
                toolGlyph(systemImage: "bubble.left.and.bubble.right", isSelected: false)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("引用聊天")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                    Text("把之前的对话作为上下文")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(Spacing.sm)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.55), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Built-in Tools Section

    private var builtinToolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("内置工具")
                .scaledFont(size: 11, weight: .semibold)
                .textCase(.uppercase)
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, 2)

            if isWebSearchAvailable {
                webSearchToggle
            }

            if isImageGenerationAvailable {
                imageGenerationToggle
            }

            if isCodeInterpreterAvailable {
                codeInterpreterToggle
            }
        }
    }

    // MARK: - OpenAI Native Tools Section

    private var openAINativeToolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("OpenAI 原生")
                .scaledFont(size: 11, weight: .semibold)
                .textCase(.uppercase)
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, 2)

            featureToggleTile(
                icon: "doc.text.magnifyingglass",
                title: "文件搜索",
                subtitle: openAIFileSearchConfigured
                    ? "使用 OpenAI vector store 检索文件"
                    : "先填写 vector store id",
                isOn: $openAIFileSearchEnabled
            )

            featureToggleTile(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Remote MCP",
                subtitle: openAIMCPConfigured
                    ? "连接一个 OpenAI 可访问的 MCP Server"
                    : "先填写公开 MCP 地址",
                isOn: $openAIMCPEnabled
            )

            featureToggleTile(
                icon: "text.magnifyingglass",
                title: "工具搜索",
                subtitle: "按需加载 MCP 工具定义",
                isOn: $openAIToolSearchEnabled
            )

            Button {
                showOpenAINativeToolSettings = true
            } label: {
                HStack(spacing: Spacing.sm) {
                    toolGlyph(systemImage: "slider.horizontal.3", isSelected: false)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("原生工具配置")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text("搜索、文件、代码和 MCP 参数")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(Spacing.sm)
                .background(theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.55), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var openAIFileSearchConfigured: Bool {
        !OpenAIResponsesNativeToolSettings.vectorStoreIDs().isEmpty
    }

    private var openAIMCPConfigured: Bool {
        OpenAIResponsesNativeToolSettings.validMCPServerURL(
            OpenAIResponsesNativeToolSettings.stringValue(
                for: OpenAIResponsesNativeToolSettings.mcpServerURLKey
            )
        ) != nil
    }

    // MARK: - Tools Section

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Section header with expand/collapse
            Button {
                withAnimation(MicroAnimation.snappy) {
                    toolsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("工具")
                        .scaledFont(size: 14, weight: .medium)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.textSecondary)

                    Spacer()

                    Image(systemName: toolsExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if toolsExpanded {
                if isLoadingTools {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载工具…")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(theme.cardBackground)
                    .clipShape(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
                    )
                } else if tools.isEmpty {
                    localCapabilitiesSection
                } else {
                    ForEach(tools) { tool in
                        toolTile(tool: tool)
                    }
                }
            }
        }
    }

    private func toolTile(tool: ToolItem) -> some View {
        let isSelected = selectedToolIds.contains(tool.id)

        return Button {
            withAnimation(MicroAnimation.snappy) {
                if isSelected {
                    selectedToolIds.remove(tool.id)
                } else {
                    selectedToolIds.insert(tool.id)
                }
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                toolGlyph(
                    systemImage: toolIcon(for: tool),
                    isSelected: isSelected
                )

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(tool.name)
                        .scaledFont(size: 14)
                        .fontWeight(isSelected ? .semibold : .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let desc = tool.description, !desc.isEmpty {
                        Text(desc)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                togglePill(isOn: isSelected)
            }
            .padding(Spacing.sm)
            .background(tileBackground(isOn: isSelected))
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(
                        tileBorderColor(isOn: isSelected),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.name)
        .accessibilityValue(isSelected ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Shared Sub-Views

    private var localCapabilitiesSection: some View {
        VStack(spacing: Spacing.xs) {
            localCapabilityRow(
                icon: "folder.badge.gearshape",
                title: "本地工作区",
                subtitle: "可在应用文档内创建、读取、写入和删除文件"
            )
            localCapabilityRow(
                icon: "play.rectangle",
                title: "代码预览与运行",
                subtitle: "支持 HTML、SVG、Python 等代码块预览或运行"
            )
            localCapabilityRow(
                icon: "doc.text.magnifyingglass",
                title: "文件理解",
                subtitle: "图片、PDF、文档和二进制文件都可作为上下文"
            )
            localCapabilityRow(
                icon: "link",
                title: "网页上下文",
                subtitle: "可把网页链接发送给模型分析"
            )
        }
    }

    private func localCapabilityRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Spacing.sm) {
            toolGlyph(systemImage: icon, isSelected: false)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(Spacing.sm)
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.55), lineWidth: 0.5)
        )
    }

    private func toolGlyph(systemImage: String, isSelected: Bool) -> some View {
        let accentStart = theme.brandPrimary.opacity(
            isSelected ? 0.7 : 0.15
        )
        let accentEnd = theme.brandPrimary.opacity(
            isSelected ? 0.5 : 0.08
        )
        let iconColor = isSelected
            ? theme.brandOnPrimary
            : theme.iconPrimary.opacity(OpacityLevel.strong)

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accentStart, accentEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)

            Image(systemName: systemImage)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(iconColor)
        }
    }

    private func togglePill(isOn: Bool) -> some View {
        let trackColor = isOn
            ? theme.brandPrimary.opacity(0.9)
            : theme.cardBorder.opacity(0.5)
        let thumbColor = isOn
            ? theme.brandOnPrimary
            : theme.background.opacity(0.9)

        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackColor)
                .frame(width: 42, height: 22)

            Circle()
                .fill(thumbColor)
                .frame(width: 18, height: 18)
                .shadow(
                    color: theme.brandPrimary.opacity(0.25),
                    radius: 3,
                    y: 1
                )
                .padding(.horizontal, 2)
        }
        .animation(MicroAnimation.snappy, value: isOn)
    }

    private func tileBackground(isOn: Bool) -> Color {
        isOn
            ? theme.brandPrimary.opacity(theme.isDark ? 0.28 : 0.16)
            : theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12)
    }

    private func tileBorderColor(isOn: Bool) -> Color {
        isOn
            ? theme.brandPrimary.opacity(0.7)
            : theme.cardBorder.opacity(0.55)
    }

    private func infoCard(message: String) -> some View {
        Text(message)
            .scaledFont(size: 14)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(theme.cardBackground)
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
            )
    }

    private func toolIcon(for tool: ToolItem) -> String {
        let name = tool.name.lowercased()
        if name.contains("image") || name.contains("vision") {
            return "photo"
        }
        if name.contains("code") || name.contains("python") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("calc") || name.contains("math") {
            return "function"
        }
        if name.contains("file") || name.contains("document") {
            return "doc"
        }
        if name.contains("api") || name.contains("request") {
            return "cloud"
        }
        if name.contains("search") {
            return "magnifyingglass"
        }
        return "square.grid.2x2"
    }
}

private struct OpenAINativeToolsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(OpenAIResponsesNativeToolSettings.fileSearchVectorStoreIDsKey)
    private var vectorStoreIDs = ""
    @AppStorage(OpenAIResponsesNativeToolSettings.webSearchContextSizeKey)
    private var webSearchContextSize = OpenAIResponsesNativeToolSettings.defaultWebSearchContextSize
    @AppStorage(OpenAIResponsesNativeToolSettings.webSearchExternalAccessKey)
    private var webSearchExternalAccess = true
    @AppStorage(OpenAIResponsesNativeToolSettings.codeInterpreterMemoryLimitKey)
    private var codeInterpreterMemoryLimit = OpenAIResponsesNativeToolSettings.defaultCodeInterpreterMemoryLimit
    @AppStorage(OpenAIResponsesNativeToolSettings.imageGenerationSizeKey)
    private var imageGenerationSize = OpenAIResponsesNativeToolSettings.defaultImageGenerationSize
    @AppStorage(OpenAIResponsesNativeToolSettings.imageGenerationQualityKey)
    private var imageGenerationQuality = OpenAIResponsesNativeToolSettings.defaultImageGenerationQuality
    @AppStorage(OpenAIResponsesNativeToolSettings.mcpServerLabelKey)
    private var mcpServerLabel = "mcp_server"
    @AppStorage(OpenAIResponsesNativeToolSettings.mcpServerURLKey)
    private var mcpServerURL = ""
    @AppStorage(OpenAIResponsesNativeToolSettings.mcpServerDescriptionKey)
    private var mcpServerDescription = ""
    @AppStorage(OpenAIResponsesNativeToolSettings.mcpRequireApprovalKey)
    private var mcpRequireApproval = OpenAIResponsesNativeToolSettings.defaultMCPRequireApproval

    var body: some View {
        NavigationStack {
            Form {
                Section("网页搜索") {
                    Picker("上下文", selection: $webSearchContextSize) {
                        Text("低").tag("low")
                        Text("中").tag("medium")
                        Text("高").tag("high")
                    }
                    Toggle("允许实时网页访问", isOn: $webSearchExternalAccess)
                }

                Section("文件搜索") {
                    TextField("vs_xxx, vs_yyy", text: $vectorStoreIDs, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                    Text("填写 OpenAI vector store id，多个可用逗号或空格分隔。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("代码解释器") {
                    Picker("内存", selection: $codeInterpreterMemoryLimit) {
                        Text("默认").tag("default")
                        Text("1 GB").tag("1g")
                        Text("4 GB").tag("4g")
                    }
                }

                Section("图像生成") {
                    Picker("尺寸", selection: $imageGenerationSize) {
                        Text("自动").tag("auto")
                        Text("1024x1024").tag("1024x1024")
                        Text("1024x1536").tag("1024x1536")
                        Text("1536x1024").tag("1536x1024")
                    }
                    Picker("质量", selection: $imageGenerationQuality) {
                        Text("自动").tag("auto")
                        Text("低").tag("low")
                        Text("中").tag("medium")
                        Text("高").tag("high")
                    }
                }

                Section("Remote MCP") {
                    TextField("server_label", text: $mcpServerLabel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("https://example.com/sse", text: $mcpServerURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("描述", text: $mcpServerDescription, axis: .vertical)
                        .lineLimit(2...3)
                    Picker("审批", selection: $mcpRequireApproval) {
                        Text("不要求").tag("never")
                        Text("始终要求").tag("always")
                    }
                    Text("这里填写的是 OpenAI 服务器可访问的远程 MCP 地址；本机 localhost 或局域网地址通常不能被 OpenAI 访问。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("OpenAI 原生工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Tools Menu Sheet") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ToolsMenuSheet(
                webSearchEnabled: .constant(false),
                imageGenerationEnabled: .constant(false),
                codeInterpreterEnabled: .constant(false),
                openAIFileSearchEnabled: .constant(false),
                openAIMCPEnabled: .constant(false),
                openAIToolSearchEnabled: .constant(false),
                isOpenAINativeToolsAvailable: true,
                tools: [
                    ToolItem(
                        name: "Web Search",
                        description: "Search the web for fresh context."
                    ),
                    ToolItem(
                        name: "Code Interpreter",
                        description: "Execute code snippets inline."
                    ),
                    ToolItem(
                        name: "Image Generator",
                        description: "Generate images from text."
                    ),
                ],
                selectedToolIds: .constant(["1"]),
                onFileAttachment: {},
                onPhotoAttachment: {},
                onCameraCapture: {},
                onWebAttachment: {}
            )
        }
        .themed()
}
