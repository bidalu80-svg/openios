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

struct IexaNativeGlassFill<S: Shape>: View {
    @Environment(\.theme) private var theme

    let shape: S
    var lightTintOpacity: Double = 0.42
    var darkTintOpacity: Double = 0.18
    var highlightOpacity: Double = 0.52

    var body: some View {
        IexaNativeBlurView(style: theme.isDark ? .systemThinMaterialDark : .systemUltraThinMaterialLight)
            .overlay {
                shape.fill(baseTint)
            }
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(theme.isDark ? 0.10 : highlightOpacity),
                            Color.white.opacity(theme.isDark ? 0.03 : highlightOpacity * 0.34),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .clipShape(shape)
    }

    private var baseTint: Color {
        theme.isDark
            ? Color.black.opacity(darkTintOpacity)
            : Color.white.opacity(lightTintOpacity)
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
                        lightTintOpacity: 0.16,
                        darkTintOpacity: 0.20,
                        highlightOpacity: 0.34
                    )
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(toolbarStrokeColor, lineWidth: 0.65)
                }
                .shadow(color: toolbarShadowColor, radius: compact ? 18 : 22, x: 0, y: 9)
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background {
                    IexaNativeGlassFill(
                        shape: shape,
                        lightTintOpacity: 0.17,
                        darkTintOpacity: 0.20,
                        highlightOpacity: 0.34
                    )
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(toolbarStrokeColor, lineWidth: 0.65)
                }
                .shadow(color: toolbarShadowColor, radius: compact ? 18 : 22, x: 0, y: 9)
        }
    }

    private var toolbarStrokeColor: Color {
        theme.isDark
            ? Color.white.opacity(0.14)
            : Color.white.opacity(0.70)
    }

    private var toolbarShadowColor: Color {
        Color.black.opacity(theme.isDark ? 0.30 : 0.10)
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
