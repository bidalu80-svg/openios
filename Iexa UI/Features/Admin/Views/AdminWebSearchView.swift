import SwiftUI

// MARK: - Admin Web Search View

/// The admin "Web Search" tab — configure web search engines, loaders, and YouTube settings.
struct AdminWebSearchView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminWebSearchViewModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    generalSection
                    loaderSection
                    youtubeSection
                    Spacer(minLength: 100)
                }
                .padding(.top, Spacing.md)
            }
            .background(theme.background)

            floatingSaveButton
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.load()
        }
    }

    // MARK: - Floating Save Button

    private var floatingSaveButton: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if let error = viewModel.error {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .scaledFont(size: 11)
                    Text(error)
                        .scaledFont(size: 12)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 6)
                .background(theme.error)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                Task { await viewModel.save() }
                Haptics.play(.light)
            } label: {
                HStack(spacing: Spacing.xs) {
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else if viewModel.success {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 14)
                        Text("Saved")
                            .scaledFont(size: 14, weight: .semibold)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Save")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 10)
                .background(
                    viewModel.success
                        ? Color.green
                        : theme.brandPrimary,
                    in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
            .animation(.easeInOut(duration: 0.2), value: viewModel.success)
        }
        .padding(.trailing, Spacing.screenPadding)
        .padding(.bottom, Spacing.lg)
    }

    // MARK: - General Section

    private var generalSection: some View {
        SettingsSection(header: "General") {
            inlineToggleRow(
                title: "Web Search",
                isOn: $viewModel.retrievalConfig.web.enableWebSearch,
                showDivider: true
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Browser Agent Search")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Text("聊天联网搜索现在使用内置浏览器 Agent：先打开真实搜索页，再由模型继续打开、滚动、读取来源网页。第三方搜索 API 配置不再作为普通聊天搜索主路径。")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            Divider().padding(.leading, Spacing.md)
        }
        .padding(.horizontal, Spacing.sm)
    }

    // MARK: - Loader Section

    private var loaderSection: some View {
        SettingsSection(header: "Loader") {
            inlinePickerRow(
                title: "Web Loader Engine",
                selection: $viewModel.retrievalConfig.web.webLoaderEngine,
                options: [
                    (value: "", label: "Default"),
                    (value: "playwright", label: "Playwright"),
                    (value: "firecrawl", label: "Firecrawl"),
                    (value: "tavily", label: "Tavily"),
                    (value: "external", label: "External"),
                ]
            )

            // Loader-engine-specific fields
            loaderEngineSpecificFields

            inlineTextFieldRow(
                title: "Timeout",
                placeholder: "15",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.webLoaderTimeout) },
                    set: { viewModel.retrievalConfig.web.webLoaderTimeout = Int($0) ?? 15 }
                ),
                keyboardType: .numberPad
            )

            inlineToggleRow(
                title: "Verify SSL Certificate",
                isOn: $viewModel.retrievalConfig.web.webLoaderVerifySSL,
                showDivider: true
            )

            inlineTextFieldRow(
                title: "Concurrent Requests",
                placeholder: "10",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.webLoaderConcurrentRequests) },
                    set: { viewModel.retrievalConfig.web.webLoaderConcurrentRequests = Int($0) ?? 10 }
                ),
                keyboardType: .numberPad,
                showDivider: false
            )
        }
        .padding(.horizontal, Spacing.sm)
    }

    @ViewBuilder
    private var loaderEngineSpecificFields: some View {
        let engine = viewModel.retrievalConfig.web.webLoaderEngine

        switch engine {
        case "playwright":
            inlineTextFieldRow(title: "WebSocket URL", placeholder: "ws://...", text: $viewModel.retrievalConfig.web.playwrightWSURL)
            inlineTextFieldRow(
                title: "Timeout (ms)",
                placeholder: "60000",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.playwrightTimeout) },
                    set: { viewModel.retrievalConfig.web.playwrightTimeout = Int($0) ?? 60000 }
                ),
                keyboardType: .numberPad
            )

        case "firecrawl":
            inlineSecureRow(title: "API Key", placeholder: "Enter Firecrawl Loader API Key", text: $viewModel.retrievalConfig.web.firecrawlLoaderAPIKey, isVisible: viewModel.showFirecrawlLoaderKey) { viewModel.showFirecrawlLoaderKey.toggle() }
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.firecrawl.dev", text: $viewModel.retrievalConfig.web.firecrawlLoaderAPIBaseURL)
            inlineTextFieldRow(
                title: "Timeout (ms)",
                placeholder: "60000",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.firecrawlLoaderTimeout) },
                    set: { viewModel.retrievalConfig.web.firecrawlLoaderTimeout = Int($0) ?? 60000 }
                ),
                keyboardType: .numberPad
            )

        case "tavily":
            inlineSecureRow(title: "API Key", placeholder: "Enter Tavily Loader API Key", text: $viewModel.retrievalConfig.web.tavilyLoaderAPIKey, isVisible: viewModel.showTavilyLoaderKey) { viewModel.showTavilyLoaderKey.toggle() }
            inlineTextFieldRow(title: "Extract Depth", placeholder: "basic", text: $viewModel.retrievalConfig.web.tavilyLoaderExtractDepth)

        case "external":
            inlineTextFieldRow(title: "External Loader URL", placeholder: "http://...", text: $viewModel.retrievalConfig.web.externalLoaderURL)
            inlineSecureRow(title: "API Key", placeholder: "Enter External Loader API Key", text: $viewModel.retrievalConfig.web.externalLoaderAPIKey, isVisible: viewModel.showExternalLoaderKey) { viewModel.showExternalLoaderKey.toggle() }

        default:
            EmptyView()
        }
    }

    // MARK: - YouTube Section

    private var youtubeSection: some View {
        SettingsSection(header: "YouTube") {
            inlineTextFieldRow(
                title: "Youtube Language",
                placeholder: "en",
                text: $viewModel.retrievalConfig.web.youtubeLanguage
            )

            inlineTextFieldRow(
                title: "Youtube Proxy URL",
                placeholder: "http://...",
                text: $viewModel.retrievalConfig.web.youtubeProxyURL,
                showDivider: false
            )
        }
        .padding(.horizontal, Spacing.sm)
    }

    // MARK: - Row Builders

    private func inlineToggleRow(
        title: String,
        isOn: Binding<Bool>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlineTextFieldRow(
        title: String,
        placeholder: String,
        subtitle: String? = nil,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                TextField(placeholder, text: text)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlinePickerRow(
        title: String,
        selection: Binding<String>,
        options: [(value: String, label: String)]
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Text(title)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .layoutPriority(1)

            Spacer(minLength: Spacing.xs)

            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection.wrappedValue = option.value
                    } label: {
                        if selection.wrappedValue == option.value {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first(where: { $0.value == selection.wrappedValue })?.label ?? "")
                        .scaledFont(size: 15)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 10)
                }
                .foregroundStyle(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    private func inlineSecureRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isVisible: Bool,
        onToggleVisibility: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                Group {
                    if isVisible {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Spacer()

            Button(action: onToggleVisibility) {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }
}
