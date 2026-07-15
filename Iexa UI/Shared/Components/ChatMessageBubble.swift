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
    @State private var motionStartedAt = Date()

    // Gemini's 8.5 px capture spacing maps to roughly 5.6 points in Iexa's
    // chat coordinate space on the recorded device.
    private let waveDotSpacing: CGFloat = 5.6

    var body: some View {
        Group {
            if reduceMotion {
                indicator(progress: 0)
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
            // A pending assistant turn always starts from the same visual
            // phase. Reference-date modulo made the old indicator appear in a
            // random part of its loop whenever the message view was created.
            motionStartedAt = .now
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.26)) {
                    appeared = true
                }
            }
        }
    }

    private func indicator(progress elapsed: TimeInterval) -> some View {
        Canvas { context, size in
            for index in 0..<3 {
                let point = dotPoint(index: index, elapsed: elapsed)
                let diameter: CGFloat = 3.4
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
                    with: .color(theme.textPrimary.opacity(0.94))
                )
            }
        }
        .frame(width: 34, height: 24)
    }

    private func progress(for date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(motionStartedAt))
    }

    /// Gemini's waiting mark has two visible phases in the supplied recording:
    /// fixed-x dots that travel through a vertical wave, then each dot follows
    /// its own arc while the line rotates into a collapsing / opening triangle.
    private func dotPoint(index: Int, elapsed: TimeInterval) -> CGPoint {
        if reduceMotion {
            return CGPoint(x: CGFloat(index - 1) * waveDotSpacing, y: 0)
        }

        // Measured from the complete Gemini capture: the fixed-x wave remains
        // visible for about three seconds before the triangle takes over.
        let lineDuration: TimeInterval = 3.0
        // The complete reference shows an eight-tenths-of-a-second turn into
        // the triangle. This is not a straight interpolation: each dot leaves
        // the wave on a different curved path.
        let handoffDuration: TimeInterval = 0.80

        if elapsed < lineDuration {
            return waveLinePoint(index: index, elapsed: elapsed)
        }

        let handoffElapsed = elapsed - lineDuration
        guard handoffElapsed < handoffDuration else {
            return trianglePoint(index: index, elapsed: handoffElapsed - handoffDuration)
        }
        return handoffPoint(index: index, elapsed: handoffElapsed)
    }

    private func waveLinePoint(index: Int, elapsed: TimeInterval) -> CGPoint {
        let wavePeriod: TimeInterval = 1.220
        // Independent terminal phases keep the moving line continuous with the
        // measured first handoff keyframe. A shared phase offset made the old
        // animation visibly jump just before it turned into the triangle.
        let handoffPhase = [3.86, 2.32, 1.31][index]
        let phase = handoffPhase + ((elapsed - 3.0) / wavePeriod) * .pi * 2
        return CGPoint(
            x: CGFloat(index - 1) * waveDotSpacing,
            y: CGFloat(sin(phase)) * 4.55
        )
    }

    private func handoffPoint(index: Int, elapsed: TimeInterval) -> CGPoint {
        keyframedPoint(
            index: index,
            elapsed: elapsed,
            duration: 0.80,
            keyframes: Self.handoffKeyframes
        )
    }

    private func trianglePoint(index: Int, elapsed: TimeInterval) -> CGPoint {
        // The reference does not leave a visible gap between the dots at the
        // tightest part of the cycle: they meet, turn, and reopen. The prior
        // baseline-radius formula could never make them meet, and the extra
        // settle delay shifted the entire triangle phase after the handoff.
        let pulsePeriod: TimeInterval = 0.581
        let pulsePhase = .pi * ((elapsed + 0.012) / pulsePeriod)
        let radius = CGFloat(8.45 * abs(cos(pulsePhase)))
        let triangleOrientation = -0.535 - 0.305 * cos(pulsePhase)
        let angle = triangleOrientation + Double(index) * (.pi * 2 / 3)
        return CGPoint(
            x: CGFloat(cos(angle)) * radius,
            y: CGFloat(sin(angle)) * radius
        )
    }

    /// Per-dot positions sampled from the supplied full Gemini capture.
    /// Catmull-Rom interpolation preserves the curved rotation between the
    /// samples instead of drawing a single rigid triangle into place.
    private func keyframedPoint(
        index: Int,
        elapsed: TimeInterval,
        duration: TimeInterval,
        keyframes: [[CGPoint]]
    ) -> CGPoint {
        let position = min(1, max(0, elapsed / duration)) * Double(keyframes.count - 1)
        let segment = min(keyframes.count - 2, Int(position))
        let t = CGFloat(position - Double(segment))
        let p0 = keyframes[max(0, segment - 1)][index]
        let p1 = keyframes[segment][index]
        let p2 = keyframes[segment + 1][index]
        let p3 = keyframes[min(keyframes.count - 1, segment + 2)][index]

        return CGPoint(
            x: catmullRom(p0.x, p1.x, p2.x, p3.x, progress: t),
            y: catmullRom(p0.y, p1.y, p2.y, p3.y, progress: t)
        )
    }

    private func catmullRom(
        _ previous: CGFloat,
        _ start: CGFloat,
        _ end: CGFloat,
        _ next: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        let t2 = progress * progress
        let t3 = t2 * progress
        let linear = (-previous + end) * progress
        let quadratic = (2 * previous - 5 * start + 4 * end - next) * t2
        let cubic = (-previous + 3 * start - 3 * end + next) * t3
        return 0.5 * (2 * start + linear + quadratic + cubic)
    }

    private static let handoffKeyframes: [[CGPoint]] = [
        [CGPoint(x: -5.67, y: -3.00), CGPoint(x: 0.33, y: 3.33), CGPoint(x: 5.60, y: 4.40)],
        [CGPoint(x: -5.81, y: -4.07), CGPoint(x: 1.00, y: 1.33), CGPoint(x: 5.60, y: 4.40)],
        [CGPoint(x: -5.93, y: -2.19), CGPoint(x: 1.00, y: -1.67), CGPoint(x: 5.84, y: 3.49)],
        [CGPoint(x: -4.59, y: 2.85), CGPoint(x: -1.15, y: -3.93), CGPoint(x: 5.92, y: 0.39)],
        [CGPoint(x: 0.67, y: 6.14), CGPoint(x: -5.33, y: -2.33), CGPoint(x: 3.76, y: -4.00)],
        [CGPoint(x: 6.43, y: 3.33), CGPoint(x: -6.07, y: 3.52), CGPoint(x: -1.26, y: -6.19)],
        [CGPoint(x: 7.83, y: -2.25), CGPoint(x: -2.33, y: 7.33), CGPoint(x: -5.50, y: -4.92)],
        [CGPoint(x: 6.46, y: -5.42), CGPoint(x: 1.00, y: 8.33), CGPoint(x: -7.50, y: -2.92)],
        [CGPoint(x: 5.67, y: -6.33), CGPoint(x: 2.19, y: 8.07), CGPoint(x: -8.00, y: -1.67)]
    ]

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
