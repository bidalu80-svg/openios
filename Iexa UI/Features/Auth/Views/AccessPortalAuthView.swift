import SwiftUI
import UIKit

/// First-run IEXA account gate.
///
/// This is intentionally separate from the server/site login flow. Once the
/// app account is authenticated, RootView continues into ServerConnectionView
/// or the saved server session exactly as before.
struct AccessPortalAuthView: View {
    @Bindable var viewModel: AppAccountAuthViewModel
    @FocusState private var focusedField: Field?
    @State private var panelPulse = false
    @State private var shakeCount = 0

    private enum Field: Hashable {
        case account
        case password
        case activation
    }

    private var normalizedAccount: String {
        AppAccountAuthService.normalizedAccount(viewModel.account)
    }

    private var canLogin: Bool {
        viewModel.canLogin
    }

    private var canRegister: Bool {
        viewModel.canRegister
    }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let safeBottom = proxy.safeAreaInsets.bottom

            ZStack {
                accessPortalBackground
                    .ignoresSafeArea()

                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 42)
                            hero
                            Spacer(minLength: 22)
                            authPanel
                            bottomPolicyText
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, safeTop + 8)
                        .padding(.bottom, max(24, safeBottom + 18))
                        .frame(minHeight: proxy.size.height, alignment: .center)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedField = nil
                    }
                    .onChange(of: focusedField) { _, field in
                        scrollFocusedField(field, using: scrollProxy)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    focusedField = nil
                }
            }
        }
        .onAppear {
            viewModel.errorMessage = nil
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                panelPulse = true
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            heroBadge

            VStack(spacing: 10) {
                Text("IEXA")
                    .font(.custom("AvenirNext-Bold", size: 72))
                    .tracking(3.2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.96),
                                Color.black.opacity(0.70)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 2)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                AccessPortalSweepRevealText(
                    text: "目前的你 尚未发掘",
                    sweepDuration: 1.05,
                    holdAtEnd: 1.25,
                    holdAtStart: 0.22
                )
                .font(.system(size: 22, weight: .regular, design: .monospaced))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .foregroundStyle(Color.black.opacity(0.70))
                .frame(height: 28)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.18),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 132, height: 3)
                    .blur(radius: 0.4)

                Text("智能聊天 · 代码协作 · 多模态工作流")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.42))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var heroBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.black.opacity(0.78))
                .frame(width: 7, height: 7)
                .shadow(color: Color.black.opacity(0.16), radius: 4, x: 0, y: 0)

            Text("SECURE ACCESS")
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .lineLimit(1)
        }
        .foregroundStyle(Color.black.opacity(0.78))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.86))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                )
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    private var authPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access Portal")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.92))
                    Text("连接你的智能工作区")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.46))
                }
                Spacer()
                statusChip(
                    title: viewModel.hasAuthEndpoint ? "READY" : "SETUP",
                    tint: viewModel.hasAuthEndpoint
                        ? Color.black.opacity(0.72)
                        : Color.black.opacity(0.46)
                )
            }

            VStack(spacing: 11) {
                credentialField(
                    icon: "person.crop.circle.fill",
                    placeholder: "账号（可填手机号）",
                    text: $viewModel.account,
                    isFocused: focusedField == .account
                )
                .focused($focusedField, equals: .account)
                .id(Field.account)

                secureCredentialField(
                    icon: "lock.fill",
                    placeholder: "密码（至少 6 位）",
                    text: $viewModel.password,
                    isFocused: focusedField == .password
                )
                .focused($focusedField, equals: .password)
                .id(Field.password)

                if viewModel.requiresActivationCode {
                    credentialField(
                        icon: "key.fill",
                        placeholder: "激活码（注册必填）",
                        text: $viewModel.activationCode,
                        keyboardType: .asciiCapable,
                        textContentType: nil,
                        submitLabel: .go,
                        nextField: nil,
                        isFocused: focusedField == .activation
                    )
                    .focused($focusedField, equals: .activation)
                    .id(Field.activation)
                }
            }

            VStack(spacing: 12) {
                capsuleActionButton(
                    title: buttonTitle(for: .login),
                    systemIcon: "person.fill",
                    highlighted: true,
                    disabled: !canLogin
                ) {
                    submit(.login)
                }

                capsuleActionButton(
                    title: buttonTitle(for: .register),
                    systemIcon: "person.badge.plus.fill",
                    highlighted: false,
                    disabled: !canRegister
                ) {
                    submit(.register)
                }
            }
            .padding(.top, 2)

            if let error = viewModel.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.34, blue: 0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .modifier(AccessPortalShakeEffect(animatableData: CGFloat(shakeCount)))
            }

            VStack(spacing: 5) {
                Text("IEXA 为你提供简洁高效的智能助手体验")
                Text("支持聊天、图像与代码能力，登录后即可开始使用")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.black.opacity(0.48))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.975, green: 0.975, blue: 0.972)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.9)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.70),
                            Color.clear,
                            Color.black.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blur(radius: 7)
                .opacity(0.7)
                .allowsHitTesting(false)
        }
        .overlay {
            AccessPortalPanelSweepBorder(progress: panelPulse ? 1 : 0)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private func buttonTitle(for mode: AppAccountAuthMode) -> String {
        if viewModel.isSubmitting && viewModel.mode == mode {
            return mode == .login ? "登录中..." : "注册中..."
        }
        return mode == .login ? "登录使用" : "注册使用"
    }

    private func submit(_ mode: AppAccountAuthMode) {
        guard mode == .login ? canLogin : canRegister else { return }
        focusedField = nil
        viewModel.account = normalizedAccount
        viewModel.activationCode = AppAccountAuthService.normalizedActivationCode(viewModel.activationCode)
        Task {
            await viewModel.submit(as: mode)
            if viewModel.errorMessage != nil {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    shakeCount += 1
                }
            }
        }
    }

    private func scrollFocusedField(_ field: Field?, using proxy: ScrollViewProxy) {
        guard let field else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                proxy.scrollTo(field, anchor: .center)
            }
        }
    }

    private func credentialField(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .emailAddress,
        textContentType: UITextContentType? = .username,
        submitLabel: SubmitLabel = .next,
        nextField: Field? = .password,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.black.opacity(isFocused ? 0.84 : 0.62))
                .frame(width: 24)

            TextField(placeholder, text: text)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.92))
                .submitLabel(submitLabel)
                .onSubmit {
                    if let nextField {
                        focusedField = nextField
                    } else {
                        submit(.register)
                    }
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(fieldBackground(isFocused: isFocused))
        .shadow(color: isFocused ? Color.black.opacity(0.06) : .clear, radius: 10, x: 0, y: 0)
    }

    private func secureCredentialField(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.black.opacity(isFocused ? 0.84 : 0.62))
                .frame(width: 24)

            SecureField(placeholder, text: text)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.92))
                .submitLabel(.go)
                .onSubmit {
                    if viewModel.requiresActivationCode {
                        focusedField = .activation
                    } else {
                        submit(.login)
                    }
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(fieldBackground(isFocused: isFocused))
        .shadow(color: isFocused ? Color.black.opacity(0.06) : .clear, radius: 10, x: 0, y: 0)
    }

    private func fieldBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isFocused
                            ? Color.black.opacity(0.30)
                            : Color.black.opacity(0.08),
                        lineWidth: isFocused ? 1.15 : 0.9
                    )
            )
    }

    private func capsuleActionButton(
        title: String,
        systemIcon: String,
        highlighted: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if viewModel.isSubmitting
                    && ((highlighted && viewModel.mode == .login) || (!highlighted && viewModel.mode == .register)) {
                    ProgressView()
                        .tint(highlighted ? Color.white : Color.black.opacity(0.72))
                } else {
                    Image(systemName: systemIcon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(highlighted ? Color.white : Color.black.opacity(0.86))
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(buttonBackground(highlighted: highlighted))
            .overlay {
                if highlighted {
                    AccessPortalOrbitingCapsuleStroke(
                        lineWidth: 1.4,
                        cyclesPerSecond: 0.05,
                        segmentFraction: 0.15,
                        gradient: LinearGradient(
                            colors: [
                                Color.white.opacity(0.92),
                                Color.white.opacity(0.58),
                                Color.white.opacity(0.22)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        glowColor: Color.black.opacity(0.08)
                    )
                    .padding(-1.15)
                }
            }
            .shadow(
                color: highlighted ? Color.black.opacity(0.12) : .black.opacity(0.05),
                radius: 9,
                x: 0,
                y: 3
            )
            .opacity(disabled ? 0.48 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func buttonBackground(highlighted: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(
                highlighted
                    ? LinearGradient(
                        colors: [
                            Color.black.opacity(0.92),
                            Color.black.opacity(0.78)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    : LinearGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.985, green: 0.985, blue: 0.982)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        highlighted
                            ? Color.black.opacity(0.18)
                            : Color.black.opacity(0.12),
                        lineWidth: highlighted ? 1.35 : 0.9
                    )
            )
    }

    private func statusChip(title: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint.opacity(0.45), radius: 3, x: 0, y: 0)
            Text(title)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(Color.black.opacity(0.72))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.92))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    private var accessPortalBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white,
                    Color(red: 0.985, green: 0.985, blue: 0.982),
                    Color(red: 0.975, green: 0.975, blue: 0.970)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.black.opacity(0.04),
                    Color.clear
                ],
                center: .init(x: 0.20, y: 0.18),
                startRadius: 20,
                endRadius: 300
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [
                    Color.black.opacity(0.025),
                    Color.clear
                ],
                center: .init(x: 0.82, y: 0.72),
                startRadius: 16,
                endRadius: 260
            )
            .blendMode(.screen)

            AccessPortalTechGridField()
                .opacity(0.30)

            AccessPortalSlowScanBeam()
                .opacity(0.28)

            AccessPortalSignalParticles()
                .opacity(0.72)
        }
    }

    private var bottomPolicyText: some View {
        Text("继续即表示你同意服务条款和隐私政策")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.black.opacity(0.38))
            .padding(.top, 10)
    }
}

private struct AccessPortalTechGridField: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, _ in
                var path = Path()
                let spacing: CGFloat = 28
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(Color.black.opacity(0.045)), lineWidth: 0.5)

                var circuit = Path()
                let lanes: [CGFloat] = [0.12, 0.27, 0.44, 0.62, 0.79]
                for (index, lane) in lanes.enumerated() {
                    let baseY = size.height * lane
                    let startX = CGFloat(index % 3) * 38 + 18
                    circuit.move(to: CGPoint(x: startX, y: baseY))
                    circuit.addLine(to: CGPoint(x: size.width * 0.28, y: baseY))
                    circuit.addLine(to: CGPoint(x: size.width * 0.28, y: baseY + 22))
                    circuit.addLine(to: CGPoint(x: size.width * 0.64, y: baseY + 22))
                    circuit.addLine(to: CGPoint(x: size.width * 0.64, y: baseY - 16))
                    circuit.addLine(to: CGPoint(x: size.width - startX, y: baseY - 16))
                }
                context.stroke(circuit, with: .color(Color.black.opacity(0.05)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct AccessPortalSlowScanBeam: View {
    @State private var phase: CGFloat = -0.25

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.60),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: proxy.size.width * 0.34)
                .rotationEffect(.degrees(-12))
                .offset(x: proxy.size.width * phase, y: 0)
                .blur(radius: 5)
                .onAppear {
                    withAnimation(.linear(duration: 6.5).repeatForever(autoreverses: false)) {
                        phase = 1.25
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

private struct AccessPortalSignalParticles: View {
    private let points: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.20),
        CGPoint(x: 0.82, y: 0.16),
        CGPoint(x: 0.28, y: 0.56),
        CGPoint(x: 0.72, y: 0.64),
        CGPoint(x: 0.46, y: 0.78),
        CGPoint(x: 0.08, y: 0.42),
        CGPoint(x: 0.90, y: 0.36)
    ]
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            ForEach(points.indices, id: \.self) { index in
                Circle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: index.isMultiple(of: 2) ? 4 : 3, height: index.isMultiple(of: 2) ? 4 : 3)
                    .position(
                        x: proxy.size.width * points[index].x,
                        y: proxy.size.height * points[index].y + (animate ? CGFloat(index % 3) * 4 : 0)
                    )
                    .opacity(animate ? 0.38 : 0.18)
                    .animation(
                        .easeInOut(duration: 2.4 + Double(index) * 0.18).repeatForever(autoreverses: true),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
    }
}

private struct AccessPortalSweepRevealText: View {
    let text: String
    let sweepDuration: Double
    let holdAtEnd: Double
    let holdAtStart: Double

    private let fadeDuration = 0.34

    var body: some View {
        let cycle = holdAtStart + sweepDuration + holdAtEnd + fadeDuration

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle)
            let phase = revealPhase(at: time, cycle: cycle)

            ZStack(alignment: .leading) {
                Text(text)
                    .hidden()

                Text(text)
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            Rectangle()
                                .frame(width: max(0, proxy.size.width * phase.progress))
                        }
                    }
                    .opacity(phase.opacity)
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .leading) {
                if phase.showScanner {
                    GeometryReader { proxy in
                        scanBar
                            .frame(width: 10, height: 24)
                            .offset(x: max(0, proxy.size.width * phase.progress - 5))
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var scanBar: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.black.opacity(0.92))
            .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 0)
    }

    private func revealPhase(
        at time: Double,
        cycle: Double
    ) -> (progress: CGFloat, opacity: Double, showScanner: Bool) {
        if time < holdAtStart {
            return (0, 0.06, false)
        }

        let sweepEnd = holdAtStart + sweepDuration
        if time < sweepEnd {
            let progress = eased((time - holdAtStart) / max(sweepDuration, 0.001))
            return (progress, 1, true)
        }

        let holdEnd = sweepEnd + holdAtEnd
        if time < holdEnd {
            return (1, 1, false)
        }

        let fadeProgress = min(max((time - holdEnd) / max(fadeDuration, 0.001), 0), 1)
        let fade = Double(eased(fadeProgress))
        return (1, 1 - fade, false)
    }

    private func eased(_ raw: Double) -> CGFloat {
        let clamped = min(max(raw, 0), 1)
        let eased = clamped * clamped * (3 - 2 * clamped)
        return CGFloat(eased)
    }
}

private struct AccessPortalPanelSweepBorder: View {
    let progress: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .trim(from: max(0, progress - 0.18), to: progress)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.88),
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
    }
}

private struct AccessPortalOrbitingCapsuleStroke: View {
    let lineWidth: CGFloat
    let cyclesPerSecond: Double
    let segmentFraction: CGFloat
    let gradient: LinearGradient
    let glowColor: Color

    @State private var progress: CGFloat = 0

    var body: some View {
        Capsule(style: .continuous)
            .trim(from: max(0, progress - segmentFraction), to: progress)
            .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .shadow(color: glowColor, radius: 4, x: 0, y: 0)
            .onAppear {
                progress = 0
                withAnimation(.linear(duration: 1 / max(cyclesPerSecond, 0.01)).repeatForever(autoreverses: false)) {
                    progress = 1
                }
            }
    }
}

private struct AccessPortalShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(animatableData * .pi * 2.0) * 7
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
