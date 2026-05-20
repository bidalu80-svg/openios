import SwiftUI

// MARK: - Animated Background

/// Floating orbs that create a subtle, living background.
private struct FloatingOrb: View {
    let color: Color
    let size: CGFloat
    @State private var offset: CGSize = .zero
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .blur(radius: size * 0.4)
            .offset(offset)
            .onAppear {
                let randomX = CGFloat.random(in: -120...120)
                let randomY = CGFloat.random(in: -120...120)
                withAnimation(.easeInOut(duration: Double.random(in: 6...10)).repeatForever(autoreverses: true)) {
                    offset = CGSize(width: randomX, height: randomY)
                }
                withAnimation(.easeInOut(duration: 2)) {
                    opacity = Double.random(in: 0.15...0.35)
                }
            }
    }
}

/// Animated mesh-like background with floating orbs.
private struct AnimatedAuthBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            FloatingOrb(color: theme.brandPrimary, size: 200)
                .offset(x: -80, y: -200)

            FloatingOrb(color: theme.brandPrimary.opacity(0.6), size: 160)
                .offset(x: 100, y: -100)

            FloatingOrb(color: theme.brandPrimary.opacity(0.4), size: 120)
                .offset(x: -60, y: 180)

            FloatingOrb(color: theme.info.opacity(0.3), size: 140)
                .offset(x: 80, y: 250)
        }
    }
}

// MARK: - Modern Text Field

/// A modern text field with floating label and focus ring.
struct ModernTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var onSubmit: (() -> Void)?

    @State private var isPasswordVisible = false
    @FocusState private var isFocused: Bool
    @Environment(\.theme) private var theme

    private var showFloatingLabel: Bool {
        isFocused || !text.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                // Floating label
                Text(label)
                    .font(showFloatingLabel ? AppTypography.captionFont : AppTypography.bodyMediumFont)
                    .foregroundStyle(isFocused ? theme.brandPrimary : theme.textTertiary)
                    .offset(y: showFloatingLabel ? -24 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showFloatingLabel)

                HStack(spacing: Spacing.sm) {
                    if isSecure && !isPasswordVisible {
                        SecureField("", text: $text, prompt: isFocused ? Text(placeholder).foregroundStyle(theme.textTertiary.opacity(0.5)) : nil)
                            .focused($isFocused)
                            .textContentType(textContentType)
                            .onSubmit { onSubmit?() }
                    } else {
                        TextField("", text: $text, prompt: isFocused ? Text(placeholder).foregroundStyle(theme.textTertiary.opacity(0.5)) : nil)
                            .focused($isFocused)
                            .keyboardType(keyboardType)
                            .textContentType(textContentType)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { onSubmit?() }
                    }

                    if isSecure {
                        Button {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                isPasswordVisible.toggle()
                            }
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textTertiary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                }
                .scaledFont(size: 16)
                .foregroundStyle(theme.textPrimary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Bottom border
            Rectangle()
                .fill(isFocused ? theme.brandPrimary : theme.divider)
                .frame(height: isFocused ? 2 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Primary Auth Button

/// A large, animated primary action button for auth flows.
struct AuthPrimaryButton: View {
    let title: String
    let icon: String?
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isPressed = false

    init(
        title: String,
        icon: String? = nil,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(theme.buttonPrimaryText)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    if let icon {
                        Image(systemName: icon)
                            .scaledFont(size: 16, weight: .semibold)
                    }
                    Text(title)
                        .scaledFont(size: 16, weight: .medium)
                }
            }
            .foregroundStyle(theme.buttonPrimaryText)
            .frame(maxWidth: .infinity)
            .frame(height: TouchTarget.large)
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.button + 4, style: .continuous)
                .fill(theme.buttonPrimary)
                .shadow(color: theme.buttonPrimary.opacity(0.3), radius: isPressed ? 4 : 12, y: isPressed ? 2 : 6)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button + 4, style: .continuous))
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? OpacityLevel.disabled : 1.0)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}

// MARK: - Server Connection View

/// View for connecting to an Iexa server or an OpenAI-compatible endpoint.
struct ServerConnectionView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var showAdvancedOptions = false
    @State private var appeared = false
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0

    var body: some View {
        ZStack {
            AnimatedAuthBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: Spacing.xl) {
                    Spacer(minLength: 60)

                    // App branding with animated entrance
                    VStack(spacing: Spacing.md) {
                        // Animated logo
                        ZStack {
                            Circle()
                                .fill(theme.brandPrimary.opacity(0.1))
                                .frame(width: 100, height: 100)
                                .scaleEffect(logoScale * 1.3)

                            Circle()
                                .fill(theme.brandPrimary.opacity(0.05))
                                .frame(width: 130, height: 130)
                                .scaleEffect(logoScale * 1.1)

                            IexaLogoMark(size: 78)
                                .scaleEffect(logoScale)
                        }
                        .opacity(logoOpacity)

                        Text("Iexa")
                            .scaledFont(size: 36, weight: .bold, design: .rounded)
                            .foregroundStyle(theme.textPrimary)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)

                        Text("连接 Iexa 原生站点或任意兼容 API")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textSecondary)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)
                    }

                    // Connection form card
                    VStack(spacing: Spacing.lg) {
                        ModernTextField(
                            label: "用户名（可选）",
                            placeholder: "例如：Blank",
                            text: $viewModel.localUserName,
                            textContentType: .name,
                            onSubmit: {
                                if !viewModel.serverURL.isEmpty {
                                    Task { await viewModel.connect() }
                                }
                            }
                        )

                        ModernTextField(
                            label: "BASEURL",
                            placeholder: "https://api.example.com",
                            text: $viewModel.serverURL,
                            keyboardType: .URL,
                            textContentType: .URL,
                            onSubmit: {
                                if !viewModel.serverURL.isEmpty {
                                    Task { await viewModel.connect() }
                                }
                            }
                        )

                        ModernTextField(
                            label: "APIKEY（可选）",
                            placeholder: "原生站点可选，直连 API 必填",
                            text: $viewModel.apiKey,
                            isSecure: true,
                            textContentType: .password,
                            onSubmit: {
                                if !viewModel.serverURL.isEmpty {
                                    Task { await viewModel.connect() }
                                }
                            }
                        )

                        // Advanced options
                        DisclosureGroup(isExpanded: $showAdvancedOptions) {
                            VStack(spacing: Spacing.lg) {
                                HStack {
                                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                                        Text("自签名证书")
                                            .scaledFont(size: 14)
                                            .foregroundStyle(theme.textPrimary)

                                        Text("适用于使用自定义证书的私有站点")
                                            .scaledFont(size: 12, weight: .medium)
                                            .foregroundStyle(theme.textTertiary)
                                    }

                                    Spacer()

                                    Toggle("", isOn: $viewModel.allowSelfSignedCerts)
                                        .labelsHidden()
                                        .tint(theme.brandPrimary)
                                }

                                // Custom Headers
                                CustomHeadersEditor(entries: $viewModel.customHeaderEntries)
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

                        // Error message
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
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.95).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }

                        // Connect button
                        AuthPrimaryButton(
                            title: viewModel.isConnecting ? "正在连接..." : "连接",
                            icon: viewModel.isConnecting ? nil : "link",
                            isLoading: viewModel.isConnecting,
                            isDisabled: viewModel.serverURL.isEmpty
                        ) {
                            Task { await viewModel.connect() }
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
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 30)

                    // Saved servers — shown when the user has previously connected servers
                    if !viewModel.savedServers.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            CompactSavedServersSection(viewModel: viewModel)
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
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 30)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Spacer(minLength: 40)

                    // Help text
                    VStack(spacing: Spacing.sm) {
                        Text("需要帮助？")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)

                        Text("Iexa 原生站点填 URL 即可（API Key 可选）。OpenAI/Gemini/Claude 兼容 API 请填写服务商 Base URL 和 API Key，Iexa 会自动补全所需 API 后缀。")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .opacity(appeared ? 0.8 : 0)
                    .padding(.bottom, Spacing.xl)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3)) {
                appeared = true
            }
        }
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
        .fullScreenCover(isPresented: $viewModel.showProxyAuthChallenge) {
            ProxyAuthView(
                serverURL: viewModel.serverURL,
                allowsManualCompletion: viewModel.isDirectWebSessionLogin,
                onSuccess: { cookies, userAgent in
                    viewModel.resumeAfterProxyAuth(cookies, userAgent: userAgent)
                },
                onDismiss: {
                    viewModel.dismissProxyAuthChallenge()
                }
            )
        }
    }
}
