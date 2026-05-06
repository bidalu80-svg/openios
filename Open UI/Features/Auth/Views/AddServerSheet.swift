import SwiftUI

/// A modal sheet for adding a new server while staying authenticated on the current one.
///
/// Reuses the full `AuthViewModel.connect()` flow — including Cloudflare Bot Fight Mode
/// detection, auth proxy detection, HTTP→HTTPS redirect detection, and API key auth.
/// If the user taps Cancel, the current session is completely unaffected.
///
/// **One server per URL:** Each URL maps to exactly one saved session. To use a
/// different account on the same server, switch to it and sign out / sign in again.
struct AddServerSheet: View {
    @Bindable var viewModel: AuthViewModel
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    /// Local copy of the URL so we can reset viewModel.serverURL on cancel.
    @State private var url: String = ""
    @State private var apiKey: String = ""
    @State private var allowSelfSigned: Bool = false
    @State private var showAdvanced = false

    /// The URL the user was connected to before opening this sheet.
    /// Restored if the user cancels without completing the new connection.
    @State private var previousURL: String = ""
    @State private var previousApiKey: String = ""
    @State private var previousAllowSelfSigned: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: Spacing.xl) {
                    // Info banner
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.brandPrimary)
                        Text("每个服务器地址会保存一个会话。要在同一服务器使用不同账号，请先切换过去并退出登录。")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Spacing.md)
                    .background(theme.brandPrimary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.md)

                    // Connection form — delegates entirely to the same ServerConnectionView UI
                    VStack(spacing: Spacing.lg) {
                        ModernTextField(
                            label: "服务器 URL",
                            placeholder: "https://your-server.com 或 https://api.example.com",
                            text: $url,
                            keyboardType: .URL,
                            textContentType: .URL,
                            onSubmit: { startConnect() }
                        )

                        DisclosureGroup(isExpanded: $showAdvanced) {
                            VStack(spacing: Spacing.lg) {
                                ModernTextField(
                                    label: "API Key（可选）",
                                    placeholder: "Open WebUI 可选；OpenAI/Gemini/Claude 端点必填",
                                    text: $apiKey,
                                    isSecure: true
                                )
                                HStack {
                                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                                        Text("自签名证书")
                                            .scaledFont(size: 14)
                                            .foregroundStyle(theme.textPrimary)
                                        Text("适用于使用自定义证书的私有服务器")
                                            .scaledFont(size: 12, weight: .medium)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $allowSelfSigned)
                                        .labelsHidden()
                                        .tint(theme.brandPrimary)
                                }
                            }
                            .padding(.top, Spacing.md)
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "gearshape")
                                    .scaledFont(size: 14)
                                Text("高级")
                                    .scaledFont(size: 14, weight: .medium)
                            }
                            .foregroundStyle(theme.textTertiary)
                        }

                        if let error = viewModel.errorMessage {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(theme.error)
                                Text(error)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.error)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.md)
                            .background(theme.errorBackground)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        }

                        AuthPrimaryButton(
                            title: viewModel.isConnecting ? "正在连接..." : "连接",
                            icon: viewModel.isConnecting ? nil : "link",
                            isLoading: viewModel.isConnecting,
                            isDisabled: url.isEmpty
                        ) {
                            startConnect()
                        }
                    }
                    .padding(Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                            .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
                    )
                    .padding(.horizontal, Spacing.screenPadding)
                }
            }
            .background(theme.background)
            .navigationTitle("添加服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelAndRestore()
                    }
                }
            }
            // Cloudflare Bot Fight Mode challenge — reuses full existing flow
            .fullScreenCover(isPresented: $viewModel.showCloudflareChallenge) {
                CloudflareChallengeView(
                    serverURL: viewModel.serverURL,
                    onClearance: { cookieValue, userAgent, expiry in
                        viewModel.resumeAfterCloudflareClearance(cookieValue, userAgent: userAgent, expiry: expiry)
                    },
                    onDismiss: {
                        viewModel.dismissCloudflareChallenge()
                    }
                )
            }
            // Auth proxy challenge — reuses full existing flow
            .fullScreenCover(isPresented: $viewModel.showProxyAuthChallenge) {
                ProxyAuthView(
                    serverURL: viewModel.serverURL,
                    onSuccess: { cookies, userAgent in
                        viewModel.resumeAfterProxyAuth(cookies, userAgent: userAgent)
                    },
                    onDismiss: {
                        viewModel.dismissProxyAuthChallenge()
                    }
                )
            }
            // When connect succeeds (phase moves to authMethodSelection or authenticated),
            // the sheet should close since the main UI will update.
            .onChange(of: viewModel.phase) { _, newPhase in
                switch newPhase {
                case .authMethodSelection, .authenticated, .credentialLogin, .ldapLogin, .ssoLogin:
                    // Connection succeeded — dismiss the sheet; main UI will show login or chat
                    onDismiss()
                default:
                    break
                }
            }
        }
        .onAppear {
            // Snapshot the current URL/settings so Cancel can restore them
            previousURL = viewModel.serverURL
            previousApiKey = viewModel.apiKey
            previousAllowSelfSigned = viewModel.allowSelfSignedCerts
            // Clear error from any previous attempt
            viewModel.errorMessage = nil
        }
    }

    // MARK: - Connect

    /// Copies local fields into viewModel and triggers the full connect() flow.
    /// This reuses ALL existing logic: health check, CF detection, proxy detection,
    /// HTTP→HTTPS redirect, API key auth, etc.
    private func startConnect() {
        guard !url.isEmpty else { return }
        viewModel.serverURL = url
        viewModel.apiKey = apiKey
        viewModel.allowSelfSignedCerts = allowSelfSigned
        viewModel.errorMessage = nil
        Task { await viewModel.connect() }
    }

    /// Cancels the add-server flow and restores the previous URL.
    private func cancelAndRestore() {
        viewModel.isConnecting = false
        viewModel.errorMessage = nil
        // Restore previous server URL so the auth screen for the original server is correct
        viewModel.serverURL = previousURL
        viewModel.apiKey = previousApiKey
        viewModel.allowSelfSignedCerts = previousAllowSelfSigned
        onDismiss()
    }
}
