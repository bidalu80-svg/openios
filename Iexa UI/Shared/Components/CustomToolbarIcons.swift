import SwiftUI

private struct IexaToolbarGlassBackground: ViewModifier {
    @Environment(\.theme) private var theme

    let cornerRadius: CGFloat
    let compact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if compact && cornerRadius >= 20 {
                content
                    .glassEffect(.regular, in: Capsule(style: .continuous))
            } else {
                content
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(theme.cardBackground.opacity(theme.isDark ? 0.10 : (compact ? 0.18 : 0.24)))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(theme.isDark ? 0.14 : 0.42), lineWidth: 0.5)
                        }
                        .shadow(color: Color.black.opacity(theme.isDark ? 0.18 : 0.07), radius: compact ? 8 : 10, x: 0, y: 5)
                }
        }
    }
}

extension View {
    func iexaToolbarGlass(cornerRadius: CGFloat = 18, compact: Bool = false) -> some View {
        modifier(IexaToolbarGlassBackground(cornerRadius: cornerRadius, compact: compact))
    }
}

struct NewConversationIcon: View {
    let size: CGFloat

    init(size: CGFloat = 16) {
        self.size = size
    }

    var body: some View {
        ZStack {
            ForEach(Self.dotOffsets.indices, id: \.self) { index in
                let offset = Self.dotOffsets[index]
                Circle()
                    .frame(width: size * 0.105, height: size * 0.105)
                    .offset(
                        x: offset.width * size,
                        y: offset.height * size
                    )
            }

            Capsule(style: .continuous)
                .frame(width: size * 0.23, height: size * 0.66)
                .rotationEffect(.degrees(45))
                .offset(x: size * 0.18, y: -size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let dotOffsets: [CGSize] = [
        CGSize(width: 0.36, height: 0.12),
        CGSize(width: 0.25, height: 0.29),
        CGSize(width: 0.07, height: 0.37),
        CGSize(width: -0.12, height: 0.36),
        CGSize(width: -0.29, height: 0.25),
        CGSize(width: -0.37, height: 0.07),
        CGSize(width: -0.36, height: -0.12),
        CGSize(width: -0.25, height: -0.29),
        CGSize(width: -0.07, height: -0.37),
        CGSize(width: 0.12, height: -0.36)
    ]
}

struct SettingsGearIcon: View {
    var body: some View {
        Image(systemName: "gearshape")
            .symbolRenderingMode(.monochrome)
            .accessibilityHidden(true)
    }
}

struct TemporaryChatIcon: View {
    let isEnabled: Bool
    let size: CGFloat

    @Environment(\.theme) private var theme

    init(isEnabled: Bool, size: CGFloat = 13) {
        self.isEnabled = isEnabled
        self.size = size
    }

    var body: some View {
        Image(isEnabled ? "TemporaryChatOn" : "TemporaryChatOff")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(theme.isDark ? Color.white : Color.black)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
