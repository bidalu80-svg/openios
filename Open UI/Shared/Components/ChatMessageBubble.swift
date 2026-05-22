import SwiftUI

// MARK: - Chat Message Bubble

/// A chat message bubble that adapts its appearance based on the
/// sender role (user vs assistant).
///
/// ## Design
/// - **User messages**: Right-aligned pill with brand accent color and
///   asymmetric corner radius (iMessage-style — smaller bottom-right corner
///   gives the classic "tail" feel without needing actual tail geometry).
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
                    .background(theme.chatBubbleUser)
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

// MARK: - User Bubble Shape (iMessage-style asymmetric corners)

/// A rounded rectangle with asymmetric corner radii that mimics the
/// iMessage bubble tail effect — all corners are 18pt except the
/// bottom-right which is 4pt, giving a subtle directional cue without
/// an actual tail/triangle.
private struct UserBubbleShape: Shape {
    // Standard corners
    private let largeRadius: CGFloat = 18
    // The "tail" corner — small to indicate message origin
    private let tailRadius: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        let tl = largeRadius   // top-left
        let tr = largeRadius   // top-right
        let bl = largeRadius   // bottom-left
        let br = tailRadius    // bottom-right (tail)

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
            // Right edge → bottom-right arc (tail)
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

    var body: some View {
        Group {
            if reduceMotion {
                indicator(progress: 0.12)
            } else {
                TimelineView(.periodic(from: Date(), by: 1.0 / 20.0)) { timeline in
                    indicator(progress: progress(for: timeline.date))
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .frame(width: 48, height: 30, alignment: .leading)
    }

    private func indicator(progress: Double) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.textPrimary)
                    .frame(width: 5.5, height: 5.5)
                    .opacity(dotOpacity(index: index, progress: progress))
                    .scaleEffect(dotScale(index: index, progress: progress))
                    .offset(dotOffset(index: index, progress: progress))
            }
        }
        .frame(width: 30, height: 20, alignment: .leading)
    }

    private func progress(for date: Date) -> Double {
        let period = 2.8
        let value = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }

    private func dotOffset(index: Int, progress: Double) -> CGSize {
        let blend = triangleBlend(progress)
        let line = CGPoint(x: CGFloat(index) * 9.5, y: 0)
        let triangle: [CGPoint] = [
            CGPoint(x: 0, y: -4.6),
            CGPoint(x: 8.8, y: 4.8),
            CGPoint(x: 17.6, y: -4.6)
        ]
        let target = triangle[index]
        let wavePhase = progress * .pi * 4 - Double(index) * 0.62
        let waveY = -sin(wavePhase) * 3.8
        let triangleBreath = sin(progress * .pi * 2 + Double(index) * 0.74) * 0.7

        return CGSize(
            width: line.x + (target.x - line.x) * blend,
            height: waveY * (1 - blend) + target.y * blend + triangleBreath * blend
        )
    }

    private func dotScale(index: Int, progress: Double) -> CGFloat {
        let blend = triangleBlend(progress)
        let wavePhase = progress * .pi * 4 - Double(index) * 0.62
        let waveScale = 0.86 + 0.16 * (0.5 + 0.5 * sin(wavePhase))
        let triangleScale = 0.92 + 0.08 * (0.5 + 0.5 * sin(progress * .pi * 2 + Double(index) * 0.42))
        return CGFloat(waveScale * (1 - blend) + triangleScale * blend)
    }

    private func dotOpacity(index: Int, progress: Double) -> Double {
        let blend = triangleBlend(progress)
        let wavePhase = progress * .pi * 4 - Double(index) * 0.62
        let waveOpacity = 0.68 + 0.32 * (0.5 + 0.5 * sin(wavePhase))
        return waveOpacity * (1 - blend) + 0.92 * blend
    }

    private func triangleBlend(_ progress: Double) -> Double {
        switch progress {
        case ..<0.34:
            return 0
        case ..<0.54:
            return smoothstep((progress - 0.34) / 0.20)
        case ..<0.74:
            return 1
        case ..<0.94:
            return 1 - smoothstep((progress - 0.74) / 0.20)
        default:
            return 0
        }
    }

    private func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
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

            // User message (iMessage-style bubble)
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
