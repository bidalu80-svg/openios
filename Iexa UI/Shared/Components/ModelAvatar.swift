import SwiftUI

// MARK: - Iexa Logo Mark

struct IexaLogoMark: View {
    let size: CGFloat

    var body: some View {
        Image("IexaLogoBlue")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
        IexaGradientLogoMark(size: size)
    }

    private var shimmerPlaceholder: some View {
        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
            .fill(theme.shimmerBase)
            .frame(width: size, height: size)
            .shimmer()
    }
}

// MARK: - Gradient Model Mark

private struct IexaGradientLogoMark: View {
    let size: CGFloat

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.42, blue: 1.00),
                Color(red: 0.36, green: 0.35, blue: 1.00),
                Color(red: 0.04, green: 0.72, blue: 0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        Rectangle()
            .fill(gradient)
            .frame(width: size, height: size)
            .mask {
                Image("IexaLogoBlue")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
            .accessibilityHidden(true)
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
