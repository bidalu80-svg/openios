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
        let period = 4.05
        let value = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }

    private func dotPoint(index: Int, progress: Double) -> CGPoint {
        let waveEnd = 0.34
        let crossEnd = 0.68

        if progress < waveEnd {
            return waveLinePoint(index: index, progress: progress / waveEnd)
        }
        if progress < crossEnd {
            return pentagonCrossPoint(
                index: index,
                progress: (progress - waveEnd) / (crossEnd - waveEnd)
            )
        }
        return orbitDropPoint(
            index: index,
            progress: (progress - crossEnd) / (1 - crossEnd)
        )
    }

    private func waveLinePoint(index: Int, progress: Double) -> CGPoint {
        let t = clamped(progress)
        let handoffStart = 0.78
        if t >= handoffStart {
            let from = waveMotionPoint(index: index, progress: handoffStart)
            let to = pentagonEntryPoint(index)
            return interpolate(from, to, smootherstep((t - handoffStart) / (1 - handoffStart)))
        }
        return waveMotionPoint(index: index, progress: t)
    }

    private func waveMotionPoint(index: Int, progress: Double) -> CGPoint {
        let t = clamped(progress)
        let base = linePoint(index)
        let envelope = smootherstep(t / 0.10) * (1 - smootherstep((t - 0.72) / 0.16))
        let phase = t * .pi * 3.25 - Double(index) * 0.82
        let lift = sin(phase) * 4.7
        let swell = sin(.pi * t) * 0.95
        return CGPoint(
            x: base.x + CGFloat(cos(phase * 0.56)) * 0.45 * CGFloat(envelope),
            y: base.y - CGFloat((lift + swell) * envelope)
        )
    }

    private func pentagonCrossPoint(index: Int, progress: Double) -> CGPoint {
        let t = clamped(progress)
        let split = 0.52
        if t < split {
            return quadraticPoint(
                from: pentagonEntryPoint(index),
                control: pentagonCrossControlIn(index),
                to: pentagonCrossMidpoint(index),
                progress: smootherstep(t / split)
            )
        }
        return quadraticPoint(
            from: pentagonCrossMidpoint(index),
            control: pentagonCrossControlOut(index),
            to: pentagonExitPoint(index),
            progress: smootherstep((t - split) / (1 - split))
        )
    }

    private func orbitDropPoint(index: Int, progress: Double) -> CGPoint {
        let t = clamped(progress)
        if t < 0.56 {
            return upperSemicircleArcPoint(
                index: index,
                progress: easeInOutSine(t / 0.56)
            )
        }

        if t < 0.70 {
            let u = (t - 0.56) / 0.14
            let point = raisedLinePoint(index)
            return CGPoint(
                x: point.x,
                y: point.y + CGFloat(sin(.pi * u)) * 0.28
            )
        }

        let u = clamped((t - 0.70) / 0.30)
        let delayed = clamped((u - Double(index) * 0.045) / 0.91)
        let start = raisedLinePoint(index)
        let end = linePoint(index)
        let fall = delayed * delayed * (3 - 2 * delayed)
        let rebound = sin(.pi * delayed) * (1 - delayed) * 1.55
        return CGPoint(
            x: start.x + (end.x - start.x) * CGFloat(smootherstep(delayed)),
            y: start.y + (end.y - start.y) * CGFloat(fall) - CGFloat(rebound)
        )
    }

    private var dotSpacing: CGFloat { 9.2 }

    private func linePoint(_ index: Int) -> CGPoint {
        CGPoint(x: CGFloat(index - 1) * dotSpacing, y: 0)
    }

    private func raisedLinePoint(_ index: Int) -> CGPoint {
        let point = linePoint(index)
        return CGPoint(x: point.x, y: point.y - 5.1)
    }

    private func pentagonEntryPoint(_ index: Int) -> CGPoint {
        switch index {
        case 0: return pentagonVertex(4)
        case 1: return pentagonVertex(0)
        default: return pentagonVertex(1)
        }
    }

    private func pentagonExitPoint(_ index: Int) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: 5.4, y: 5.6)
        case 1: return CGPoint(x: 0, y: 6.6)
        default: return CGPoint(x: -5.4, y: 5.6)
        }
    }

    private func pentagonCrossMidpoint(_ index: Int) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: 0.2, y: -0.5)
        case 1: return CGPoint(x: 0, y: 2.2)
        default: return CGPoint(x: -0.2, y: -0.5)
        }
    }

    private func pentagonCrossControlIn(_ index: Int) -> CGPoint {
        switch index {
        case 0: return pentagonVertex(0)
        case 1: return CGPoint(x: -7.0, y: 1.2)
        default: return pentagonVertex(0)
        }
    }

    private func pentagonCrossControlOut(_ index: Int) -> CGPoint {
        switch index {
        case 0: return pentagonVertex(1)
        case 1: return CGPoint(x: 7.0, y: 1.2)
        default: return pentagonVertex(4)
        }
    }

    private func pentagonVertex(_ position: Int) -> CGPoint {
        let angle = -Double.pi / 2 + Double(position) * (Double.pi * 2 / 5)
        return CGPoint(
            x: CGFloat(cos(angle) * 8.2),
            y: CGFloat(-1.0 + sin(angle) * 7.2)
        )
    }

    private func upperSemicircleArcPoint(index: Int, progress: Double) -> CGPoint {
        let u = clamped(progress)
        let start = pentagonExitPoint(index)
        let end = raisedLinePoint(index)
        let base = interpolate(start, end, u)
        let distance = hypot(Double(end.x - start.x), Double(end.y - start.y))
        let lift = sin(.pi * u) * distance * 0.36
        let centerSweep: CGFloat = index == 1 ? CGFloat(sin(.pi * u)) * 3.2 : 0
        return CGPoint(
            x: base.x + centerSweep,
            y: base.y - CGFloat(lift)
        )
    }

    private func quadraticPoint(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        progress: Double
    ) -> CGPoint {
        let t = CGFloat(clamped(progress))
        let inv = 1 - t
        return CGPoint(
            x: inv * inv * start.x + 2 * inv * t * control.x + t * t * end.x,
            y: inv * inv * start.y + 2 * inv * t * control.y + t * t * end.y
        )
    }

    private func interpolate(_ from: CGPoint, _ to: CGPoint, _ progress: Double) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * CGFloat(progress),
            y: from.y + (to.y - from.y) * CGFloat(progress)
        )
    }

    private func dotScale(index: Int, progress: Double) -> CGFloat {
        let phase = progress * .pi * 6 - Double(index) * 0.7
        return CGFloat(0.94 + 0.08 * (0.5 + 0.5 * sin(phase)))
    }

    private func dotOpacity(index: Int, progress: Double) -> Double {
        let phase = progress * .pi * 6 - Double(index) * 0.7
        return 0.76 + 0.24 * (0.5 + 0.5 * sin(phase))
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func smoothstep(_ value: Double) -> Double {
        let t = clamped(value)
        return t * t * (3 - 2 * t)
    }

    private func smootherstep(_ value: Double) -> Double {
        let t = clamped(value)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func easeInOutSine(_ value: Double) -> Double {
        let t = clamped(value)
        return -(cos(.pi * t) - 1) / 2
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
