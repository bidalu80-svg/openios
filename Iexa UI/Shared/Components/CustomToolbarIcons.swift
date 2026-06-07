import SwiftUI
import UIKit

private struct IexaNativeBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        view.contentView.backgroundColor = .clear
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
        uiView.backgroundColor = .clear
        uiView.contentView.backgroundColor = .clear
    }
}

struct IexaNativeGlassFill<S: InsettableShape>: View {
    @Environment(\.theme) private var theme

    let shape: S
    var lightTintOpacity: Double = 0.42
    var darkTintOpacity: Double = 0.18
    var highlightOpacity: Double = 0.52

    var body: some View {
        if #available(iOS 26.0, *) {
            shape.fill(.clear)
                .glassBackgroundEffect(in: shape)
                .overlay {
                    shape.strokeBorder(
                        Color.white.opacity(theme.isDark ? 0.12 : 0.42),
                        lineWidth: theme.isDark ? 0.55 : 0.5
                    )
                }
                .overlay {
                    shape.strokeBorder(
                        Color.black.opacity(theme.isDark ? 0.14 : 0.05),
                        lineWidth: 0.45
                    )
                    .blendMode(.multiply)
                }
                .clipShape(shape)
        } else {
            IexaNativeBlurView(style: fallbackBlurStyle)
                .overlay {
                    shape.fill(baseTint)
                }
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.28 : highlightOpacity),
                                Color.white.opacity(theme.isDark ? 0.11 : highlightOpacity * 0.40),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.04 : 0.08),
                                Color.clear,
                                Color.black.opacity(theme.isDark ? 0.10 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(theme.isDark ? .softLight : .screen)
                }
                .overlay {
                    shape.strokeBorder(
                        Color.white.opacity(theme.isDark ? 0.20 : 0.50),
                        lineWidth: theme.isDark ? 0.7 : 0.65
                    )
                }
                .overlay {
                    shape.strokeBorder(
                        Color.black.opacity(theme.isDark ? 0.12 : 0.06),
                        lineWidth: 0.5
                    )
                    .blendMode(.multiply)
                }
                .clipShape(shape)
        }
    }

    private var baseTint: Color {
        theme.isDark
            ? Color.white.opacity(darkTintOpacity * 0.42)
            : Color.white.opacity(lightTintOpacity)
    }

    private var fallbackBlurStyle: UIBlurEffect.Style {
        theme.isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
    }
}

private struct IexaToolbarGlassBackground: ViewModifier {
    @Environment(\.theme) private var theme

    let cornerRadius: CGFloat
    let compact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if compact && cornerRadius >= 20 {
            let shape = Capsule(style: .continuous)
            content
                .background {
                    IexaNativeGlassFill(
                        shape: shape,
                        lightTintOpacity: 0.11,
                        darkTintOpacity: 0.16,
                        highlightOpacity: 0.44
                    )
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(toolbarStrokeColor, lineWidth: 0.7)
                }
                .shadow(color: toolbarShadowColor, radius: compact ? 15 : 19, x: 0, y: 7)
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background {
                    IexaNativeGlassFill(
                        shape: shape,
                        lightTintOpacity: 0.12,
                        darkTintOpacity: 0.16,
                        highlightOpacity: 0.44
                    )
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(toolbarStrokeColor, lineWidth: 0.7)
                }
                .shadow(color: toolbarShadowColor, radius: compact ? 15 : 19, x: 0, y: 7)
        }
    }

    private var toolbarStrokeColor: Color {
        theme.isDark
            ? Color.white.opacity(0.18)
            : Color.white.opacity(0.48)
    }

    private var toolbarShadowColor: Color {
        Color.black.opacity(theme.isDark ? 0.24 : 0.08)
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
