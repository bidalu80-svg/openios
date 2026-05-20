import SwiftUI

// MARK: - Iexa Logo Mark

struct IexaLogoMark: View {
    static let blue = Color(hex: 0x2563EB)

    let size: CGFloat
    var color: Color = IexaLogoMark.blue

    var body: some View {
        ZStack {
            IexaGhostOutline()
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: max(1.4, size * 0.095),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            Capsule()
                .fill(color)
                .frame(width: size * 0.10, height: size * 0.17)
                .position(x: size * 0.43, y: size * 0.43)

            Capsule()
                .fill(color)
                .frame(width: size * 0.10, height: size * 0.17)
                .position(x: size * 0.58, y: size * 0.43)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct IexaGhostOutline: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 100,
                y: rect.minY + rect.height * y / 100
            )
        }

        var path = Path()
        path.move(to: point(22, 78))
        path.addLine(to: point(27, 61))
        path.addCurve(to: point(19, 54), control1: point(23, 59), control2: point(20, 57))
        path.addCurve(to: point(27, 47), control1: point(20, 51), control2: point(24, 49))
        path.addCurve(to: point(33, 36), control1: point(31, 44), control2: point(31, 39))
        path.addCurve(to: point(39, 22), control1: point(34, 30), control2: point(35, 26))
        path.addCurve(to: point(50, 16), control1: point(42, 18), control2: point(45, 16))
        path.addCurve(to: point(61, 16), control1: point(54, 15), control2: point(58, 15))
        path.addCurve(to: point(72, 22), control1: point(66, 16), control2: point(70, 18))
        path.addCurve(to: point(78, 36), control1: point(75, 27), control2: point(76, 31))
        path.addCurve(to: point(84, 47), control1: point(79, 40), control2: point(80, 44))
        path.addCurve(to: point(92, 54), control1: point(87, 50), control2: point(91, 51))
        path.addCurve(to: point(84, 61), control1: point(91, 57), control2: point(88, 59))
        path.addLine(to: point(89, 78))
        path.addLine(to: point(73, 78))
        path.addLine(to: point(58, 82))
        path.addLine(to: point(44, 78))
        path.closeSubpath()
        return path
    }
}

// MARK: - Model Avatar

/// Displays a model's avatar image with automatic fallback UI and image caching.
///
/// Iexa uses a consistent ghost mark for model avatars so provider/model
/// initials do not make the chat header feel visually noisy.
///
/// Usage:
/// ```swift
/// ModelAvatar(size: 32, imageURL: model.avatarURL, label: model.name)
/// ```
struct ModelAvatar: View {
    let size: CGFloat
    var imageURL: URL?
    var label: String?
    /// Optional Bearer token for authenticated model avatar endpoints.
    var authToken: String?

    @Environment(\.theme) private var theme

    var body: some View {
        iexaAvatar
            .accessibilityLabel(Text(label ?? String(localized: "AI Model")))
    }

    private var iexaAvatar: some View {
        IexaLogoMark(size: size, color: IexaLogoMark.blue)
    }

    private var shimmerPlaceholder: some View {
        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
            .fill(theme.shimmerBase)
            .frame(width: size, height: size)
            .shimmer()
    }
}

// MARK: - User Avatar

/// Displays a user avatar with an image or initials fallback.
///
/// Uses ``ImageCacheService`` for efficient image loading and caching.
/// Supports `data:` URI strings (base64-encoded images) via `dataURIString`.
struct UserAvatar: View {
    let size: CGFloat
    var imageURL: URL?
    var name: String?
    /// Optional Bearer token for authenticated user avatar endpoints.
    var authToken: String?
    /// Optional base64 data URI string (e.g. "data:image/jpeg;base64,...").
    /// When set, this takes priority over `imageURL` — no network request needed.
    var dataURIString: String?

    @Environment(\.theme) private var theme

    /// Decodes the `dataURIString` into a UIImage synchronously.
    /// Returns nil if string is not a valid data URI or decoding fails.
    private var dataURIImage: UIImage? {
        guard let dataURI = dataURIString,
              dataURI.hasPrefix("data:"),
              let commaIndex = dataURI.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURI[dataURI.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        if let uiImage = dataURIImage {
            // Fast path: data URI decoded inline — no network, no shimmer
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityLabel(Text(name ?? String(localized: "User")))
        } else if let imageURL {
            CachedAsyncImage(
                url: imageURL,
                authToken: authToken,
                targetPixelSize: Int(size * UIScreen.main.scale)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } placeholder: {
                initialsView
            }
            .accessibilityLabel(Text(name ?? String(localized: "User")))
        } else {
            initialsView
        }
    }

    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(theme.brandPrimary.opacity(0.15))
            Circle()
                .strokeBorder(theme.brandPrimary.opacity(0.3), lineWidth: 0.5)

            if let initial = name?.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(initial).uppercased())
                    .scaledFont(size: size * 0.4, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.brandPrimary)
            } else {
                Image(systemName: "person.fill")
                    .scaledFont(size: size * 0.4, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(name ?? String(localized: "User")))
    }
}

// MARK: - Previews

#Preview("Avatars") {
    HStack(spacing: Spacing.md) {
        ModelAvatar(size: 40, label: "GPT-4")
        ModelAvatar(size: 40, label: nil)
        ModelAvatar(size: 32, label: "Claude")
        UserAvatar(size: 40, name: "Alice")
        UserAvatar(size: 40, name: nil)
    }
    .padding()
    .themed()
}
