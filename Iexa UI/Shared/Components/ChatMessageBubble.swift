import SwiftUI

// MARK: - Chat Message Bubble

/// A chat message bubble that adapts its appearance based on the
/// sender role (user vs assistant).
///
/// ## Design
/// - **User messages**: Right-aligned glassy accent capsule that wraps its
///   content without stretching to the full row.
/// - **Assistant messages**: Full-width, no background — clean like
///   Claude.ai and ChatGPT native. Only a subtle label/avatar above.
/// - **System messages**: Center-aligned muted label.
struct ChatMessageBubble<Content: View>: View {
    let role: MessageRole
    let showTimestamp: Bool
    let timestamp: Date?
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        role: MessageRole,
        showTimestamp: Bool = false,
        timestamp: Date? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.role = role
        self.showTimestamp = showTimestamp
        self.timestamp = timestamp
        self.content = content
    }

    var body: some View {
        Group {
            switch role {
            case .user:
                userBubble
            case .assistant:
                assistantContent
            case .system:
                systemContent
            }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 64)

            VStack(alignment: .trailing, spacing: 4) {
                content()
                    .foregroundStyle(theme.chatBubbleUserText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        UserBubbleShape()
                            .fill(userBubbleGlassFill)
                    }
                    .overlay {
                        UserBubbleShape()
                            .stroke(userBubbleGlassBorder, lineWidth: 0.7)
                    }
                    .shadow(color: userBubbleGlassShadow, radius: 5, x: 0, y: 2)
                    .clipShape(UserBubbleShape())

                if showTimestamp, let ts = timestamp {
                    Text(ts, style: .time)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.trailing, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 2)
    }

    private var userBubbleGlassFill: LinearGradient {
        LinearGradient(
            colors: [
                theme.chatBubbleUser.opacity(theme.isDark ? 0.60 : 0.82),
                theme.chatBubbleUser.opacity(theme.isDark ? 0.44 : 0.66)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var userBubbleGlassBorder: Color {
        Color.white.opacity(theme.isDark ? 0.18 : 0.36)
    }

    private var userBubbleGlassShadow: Color {
        Color.black.opacity(theme.isDark ? 0.20 : 0.08)
    }

    // MARK: - Assistant Content (no bubble — clean full-width)

    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
                .foregroundStyle(theme.chatBubbleAssistantText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showTimestamp, let ts = timestamp {
                Text(ts, style: .time)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 2)
    }

    // MARK: - System Content

    private var systemContent: some View {
        HStack {
            Spacer()
            content()
                .foregroundStyle(theme.textTertiary)
                .scaledFont(size: 12)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(theme.surfaceContainer.opacity(0.6))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - User Bubble Shape (glass capsule)

/// A rounded shape that keeps short user messages pill-like while long
/// messages remain compact rounded rectangles.
private struct UserBubbleShape: Shape {
    private let radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let tl = radius
        let tr = radius
        let bl = radius
        let br = radius

        return Path { p in
            // Start at top-left arc
            p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
            // Top edge → top-right arc
            p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
            p.addArc(
                center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                radius: tr,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
            // Right edge -> bottom-right arc
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            p.addArc(
                center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                radius: br,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            // Bottom edge → bottom-left arc
            p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            p.addArc(
                center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                radius: bl,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            // Left edge → top-left arc
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
            p.addArc(
                center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                radius: tl,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            p.closeSubpath()
        }
    }
}

// MARK: - Typing Indicator

/// An animated typing indicator shown while the assistant is composing.
struct TypingIndicator: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Group {
            if reduceMotion {
                indicator(progress: 0.08)
            } else {
                TimelineView(.animation) { timeline in
                    indicator(progress: progress(for: timeline.date))
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .frame(width: 48, height: 30, alignment: .leading)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.94, anchor: .leading)
        .offset(y: appeared ? 0 : 5)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.26)) {
                    appeared = true
                }
            }
        }
    }

    private func indicator(progress: Double) -> some View {
        Canvas { context, size in
            for index in 0..<3 {
                let point = dotPoint(index: index, progress: progress)
                let diameter = CGFloat(5.2) * dotScale(index: index, progress: progress)
                let center = CGPoint(
                    x: size.width / 2 + point.x,
                    y: size.height / 2 + point.y
                )
                let rect = CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )

                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(theme.textPrimary.opacity(dotOpacity(index: index, progress: progress)))
                )
            }
        }
        .frame(width: 34, height: 24)
    }

    private func progress(for date: Date) -> Double {
        let period = 3.75
        let value = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }

    private func dotPoint(index: Int, progress: Double) -> CGPoint {
        switch progress {
        case ..<0.30:
            return waveLinePoint(index: index, progress: progress / 0.30)
        case ..<0.54:
            return crossingPoint(index: index, progress: (progress - 0.30) / 0.24)
        case ..<0.78:
            return orbitToLinePoint(index: index, progress: (progress - 0.54) / 0.24)
        case ..<0.90:
            return fallingLinePoint(index: index, progress: (progress - 0.78) / 0.12)
        default:
            return waveLinePoint(index: index, progress: (progress - 0.90) / 0.10)
        }
    }

    private func waveLinePoint(index: Int, progress: Double) -> CGPoint {
        let t = clamped(progress)
        let base = linePoint(index)
        let rise = smoothstep(t / 0.16)
        let settle = 1 - smoothstep((t - 0.76) / 0.24)
        let amplitude = 3.8 * rise * settle
        let phase = t * .pi * 3.7 - Double(index) * 0.68
        let drift = CGFloat(cos(phase * 0.52)) * 0.28 * CGFloat(rise * settle)
        return CGPoint(
            x: base.x + drift,
            y: base.y - CGFloat(sin(phase)) * CGFloat(amplitude)
        )
    }

    private func crossingPoint(index: Int, progress: Double) -> CGPoint {
        let t = smoothstep(progress)
        let start = linePoint(index)
        let end = swappedLinePoint(index)
        let arc: CGFloat
        switch index {
        case 0:
            arc = -5.6
        case 2:
            arc = 5.6
        default:
            arc = 3.2 * CGFloat(sin(.pi * 2 * t))
        }
        return CGPoint(
            x: start.x + (end.x - start.x) * CGFloat(t),
            y: start.y + (end.y - start.y) * CGFloat(t) + CGFloat(sin(.pi * t)) * arc
        )
    }

    private func orbitToLinePoint(index: Int, progress: Double) -> CGPoint {
        let t = smoothstep(progress)
        let start = swappedLinePoint(index)
        let end = raisedLinePoint(index)
        let base = interpolate(start, end, t)
        let radius = 6.2 * sin(.pi * t)
        let angle = Double(index) * (.pi * 2 / 3) + t * .pi * 2.15 - .pi / 8
        return CGPoint(
            x: base.x + CGFloat(cos(angle) * radius),
            y: base.y + CGFloat(sin(angle) * radius * 0.72)
        )
    }

    private func fallingLinePoint(index: Int, progress: Double) -> CGPoint {
        let t = clamped(progress)
        let start = raisedLinePoint(index)
        let end = linePoint(index)
        let y = start.y + (end.y - start.y) * CGFloat(easeOutCubic(t))
        let rebound = CGFloat(sin(.pi * t) * (1 - t)) * 2.4
        return CGPoint(
            x: start.x + (end.x - start.x) * CGFloat(smoothstep(t)),
            y: y + rebound
        )
    }

    private func linePoint(_ index: Int) -> CGPoint {
        CGPoint(x: CGFloat(index - 1) * 9.2, y: 0)
    }

    private func swappedLinePoint(_ index: Int) -> CGPoint {
        linePoint(2 - index)
    }

    private func raisedLinePoint(_ index: Int) -> CGPoint {
        let point = linePoint(index)
        return CGPoint(x: point.x, y: point.y - 4.2)
    }

    private func interpolate(_ from: CGPoint, _ to: CGPoint, _ progress: Double) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * CGFloat(progress),
            y: from.y + (to.y - from.y) * CGFloat(progress)
        )
    }

    private func dotScale(index: Int, progress: Double) -> CGFloat {
        let phase = progress * .pi * 2 - Double(index) * 0.72
        let fallPulse: Double
        if progress >= 0.78 && progress < 0.90 {
            fallPulse = sin(.pi * ((progress - 0.78) / 0.12)) * 0.08
        } else {
            fallPulse = 0
        }
        return CGFloat(0.92 + fallPulse + 0.12 * (0.5 + 0.5 * sin(phase)))
    }

    private func dotOpacity(index: Int, progress: Double) -> Double {
        let phase = progress * .pi * 2 - Double(index) * 0.72
        return 0.74 + 0.26 * (0.5 + 0.5 * sin(phase))
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func smoothstep(_ value: Double) -> Double {
        let t = clamped(value)
        return t * t * (3 - 2 * t)
    }

    private func easeOutCubic(_ value: Double) -> Double {
        let t = 1 - clamped(value)
        return 1 - t * t * t
    }
}

// MARK: - Message Action Bar

/// A horizontal bar of action buttons shown beneath a message bubble.
struct MessageActionBar: View {
    let onCopy: () -> Void
    var onRegenerate: (() -> Void)?
    var onEdit: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.xs) {
            actionButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy", action: onCopy)
            if let onRegenerate {
                actionButton(systemImage: "arrow.clockwise", accessibilityLabel: "Regenerate", action: onRegenerate)
            }
            if let onEdit {
                actionButton(systemImage: "pencil", accessibilityLabel: "Edit", action: onEdit)
            }
        }
    }

    private func actionButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Previews

#Preview("Chat Bubbles") {
    ScrollView {
        VStack(spacing: 0) {
            // Assistant message (no bubble)
            ChatMessageBubble(role: .assistant) {
                Text("Hello! How can I help you today? I'm ready to assist with anything you need.")
            }

            // User message (glass capsule)
            ChatMessageBubble(role: .user) {
                Text("Tell me about SwiftUI theming")
            }

            // Assistant message with longer text
            ChatMessageBubble(role: .assistant) {
                Text("SwiftUI provides a powerful theming system through Environment values and custom ViewModifiers. You can create a design token system and inject it via `.environment`.")
            }

            // User message with timestamp
            ChatMessageBubble(role: .user, showTimestamp: true, timestamp: .now) {
                Text("That's really helpful!")
            }

            // Typing indicator
            HStack {
                VStack(alignment: .leading) {
                    TypingIndicator()
                }
                .padding(.horizontal, Spacing.screenPadding)
                Spacer()
            }

            // Skeleton messages
            SkeletonChatMessage(isUser: false, lineCount: 3)
            SkeletonChatMessage(isUser: true, lineCount: 2)
        }
        .padding(.vertical)
    }
    .themed()
}
