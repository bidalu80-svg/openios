import SwiftUI
import Photos
import ImageIO

enum AuthenticatedImageActionLayout: Equatable {
    case none
    case compactTopTrailing
    case compactBottomTrailing
    case singleBottomOverlay
}

/// Loads and displays an image from the server using authenticated API calls.
/// Supports:
/// - Tap to view full screen with pinch-to-zoom
/// - Long press context menu with Copy and Share options
struct AuthenticatedImageView: View {
    let fileId: String
    let apiClient: APIClient?
    let onEdit: ((UIImage) -> Void)?
    let onPreview: (() -> Void)?
    /// `.fill` is used by compact image grids; the default keeps a full generated image visible.
    let contentMode: ContentMode
    let actionLayout: AuthenticatedImageActionLayout
    let adaptiveThumbnailWidth: CGFloat?

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var hasError = false
    @State private var imageIsRevealed = false
    @State private var showFullScreen = false
    @State private var saveState: SaveState = .idle
    /// Incrementing trigger to force `.task` re-evaluation on retry.
    /// Changing this value causes SwiftUI to cancel the old task and
    /// start a new one, which re-runs `loadImage()`.
    @State private var retryTrigger: Int = 0

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum SaveState {
        case idle
        case saving
        case saved
        case failed
    }

    private struct LoadedLocalImage: @unchecked Sendable {
        let image: UIImage
        let cost: Int
        let originalData: Data?
    }

    private struct LoadedImageData: @unchecked Sendable {
        let displayImage: UIImage
        let displayCost: Int
    }

    private struct CompactActionMetrics {
        let isVertical: Bool
        let buttonSize: CGFloat
        let iconSize: CGFloat
        let spacing: CGFloat
        let containerPadding: CGFloat
        let backgroundOpacity: Double
    }

    init(
        fileId: String,
        apiClient: APIClient?,
        onEdit: ((UIImage) -> Void)? = nil,
        onPreview: (() -> Void)? = nil,
        contentMode: ContentMode = .fit,
        actionLayout: AuthenticatedImageActionLayout = .compactTopTrailing,
        adaptiveThumbnailWidth: CGFloat? = nil
    ) {
        self.fileId = fileId
        self.apiClient = apiClient
        self.onEdit = onEdit
        self.onPreview = onPreview
        self.contentMode = contentMode
        self.actionLayout = actionLayout
        self.adaptiveThumbnailWidth = adaptiveThumbnailWidth
    }

    /// In-memory cache for file-based images. Prevents re-fetching when
    /// scrolling back through the chat, which causes layout shifts and
    /// scroll position jumps in the LazyVStack.
    private static let imageCache = NSCache<NSString, UIImage>()
    private static let originalImageDataCache = NSCache<NSString, NSData>()
    private static let originalImageURLCache = NSCache<NSString, NSURL>()
    private static let displayMaxPixelSize = 2200
    static func configureCache() {
        imageCache.countLimit = 80
        imageCache.totalCostLimit = 60 * 1024 * 1024 // 60 MB
        originalImageDataCache.countLimit = 24
        originalImageDataCache.totalCostLimit = 180 * 1024 * 1024
        originalImageURLCache.countLimit = 120
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                let thumbnailSize = adaptiveThumbnailSize(for: image) ?? singlePortraitThumbnailSize(for: image)
                displayImage(image, thumbnailSize: thumbnailSize)
                    .opacity(imageIsRevealed ? 1 : 0)
                    .scaleEffect(imageIsRevealed || reduceMotion ? 1 : 0.985)
                    .onTapGesture {
                        openPreview()
                    }
                    .contextMenu {
                        Button {
                            Task {
                                let imageForAction = await loadOriginalImageForAction() ?? image
                                await MainActor.run {
                                    UIPasteboard.general.image = imageForAction
                                    Haptics.notify(.success)
                                }
                            }
                        } label: {
                            Label("复制图片", systemImage: "doc.on.doc")
                        }

                        Button {
                            Task { await saveImageToPhotos() }
                        } label: {
                            Label("保存到相册", systemImage: "photo")
                        }

                        Button {
                            Task {
                                await shareImage(await loadOriginalImageForAction() ?? image)
                            }
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }

                        if let onEdit {
                            Button {
                                Task {
                                    let imageForAction = await loadOriginalImageForAction() ?? image
                                    await MainActor.run {
                                        onEdit(imageForAction)
                                    }
                                }
                            } label: {
                                Label("编辑", systemImage: "wand.and.stars")
                            }
                        }

                        Button {
                            openPreview()
                        } label: {
                            Label("全屏查看", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    .overlay {
                        if actionLayout != .none {
                            GeometryReader { geometry in
                                imageActions(for: image, availableSize: geometry.size)
                                    .padding(actionOverlayPadding(for: geometry.size))
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: actionOverlayAlignment(for: geometry.size)
                                    )
                            }
                        }
                    }
            } else if isLoading {
                imageLoadingPlaceholder
            } else if hasError {
                // Tap-to-retry error state — tapping bumps the retryTrigger
                // which causes the `.task(id:)` to re-fire and attempt loading again.
                VStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.clockwise.circle")
                        .scaledFont(size: 28)
                        .foregroundStyle(theme.brandPrimary.opacity(0.7))
                    Text("点击重试")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(height: placeholderHeight)
                .frame(maxWidth: .infinity)
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .onTapGesture {
                    retryTrigger += 1
                }
            }
        }
        // Combine fileId + retryTrigger so that:
        // 1. A new fileId triggers a fresh load (normal case)
        // 2. Incrementing retryTrigger forces a retry for the same fileId (tap-to-retry / foreground recovery)
        .task(id: "\(fileId)_\(retryTrigger)") {
            await loadImage()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: imageIsRevealed)
        // When the app returns to the foreground, retry any failed images automatically.
        // This handles the case where images failed because the app was backgrounded
        // during generation (slow network, tool-generated images not yet available).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if hasError && loadedImage == nil {
                retryTrigger += 1
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if loadedImage != nil {
                FullScreenImageView(fileId: fileId, apiClient: apiClient)
            }
        }
    }

    /// Consistent placeholder height used for loading and error states.
    /// Prevents the view from jumping between 0 → 200 → actual image height
    /// which causes scroll position shifts (bouncing).
    private var placeholderHeight: CGFloat { 200 }

    private var imageLoadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
            .fill(theme.shimmerBase.opacity(theme.isDark ? 0.72 : 0.82))
            .frame(height: placeholderHeight)
            .overlay {
                LinearGradient(
                    colors: [
                        theme.shimmerBase.opacity(0.12),
                        theme.shimmerHighlight.opacity(theme.isDark ? 0.18 : 0.42),
                        theme.shimmerBase.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.shimmerHighlight.opacity(theme.isDark ? 0.20 : 0.55))
                        .frame(width: 84, height: 7)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.shimmerHighlight.opacity(theme.isDark ? 0.14 : 0.34))
                        .frame(width: 48, height: 7)
                }
                .padding(16)
            }
            .overlay {
                Image(systemName: "photo")
                    .scaledFont(size: 24, weight: .medium)
                    .foregroundStyle(theme.textTertiary.opacity(0.16))
            }
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func displayImage(_ image: UIImage, thumbnailSize: CGSize?) -> some View {
        if let thumbnailSize {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        }
    }

    private func adaptiveThumbnailSize(for image: UIImage) -> CGSize? {
        guard let targetWidth = adaptiveThumbnailWidth, targetWidth > 0 else { return nil }
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return nil }
        let aspectRatio = width / height
        guard aspectRatio > 0 else { return nil }
        return CGSize(width: targetWidth, height: targetWidth / aspectRatio)
    }

    private func singlePortraitThumbnailSize(for image: UIImage) -> CGSize? {
        guard actionLayout == .singleBottomOverlay, contentMode == .fit else { return nil }
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return nil }
        let aspectRatio = width / height
        guard aspectRatio > 0 else { return nil }

        let targetWidth: CGFloat = 340
        return CGSize(width: targetWidth, height: targetWidth / aspectRatio)
    }

    /// Maximum number of automatic retry attempts before showing the error state.
    /// Each attempt uses exponential backoff (1s, 2s, 4s) to avoid hammering
    /// the server while still recovering quickly from transient failures.
    private static let maxAutoRetries = 3

    private var saveIcon: String {
        switch saveState {
        case .saved: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .idle, .saving: return "square.and.arrow.down"
        }
    }

    private var saveLabel: String {
        switch saveState {
        case .idle: return "保存"
        case .saving: return "保存中"
        case .saved: return "已保存"
        case .failed: return "失败"
        }
    }

    private func actionOverlayAlignment(for size: CGSize) -> Alignment {
        switch actionLayout {
        case .none:
            return .center
        case .compactTopTrailing:
            return .topTrailing
        case .compactBottomTrailing, .singleBottomOverlay:
            return .bottomTrailing
        }
    }

    private func actionOverlayPadding(for size: CGSize) -> CGFloat {
        switch actionLayout {
        case .none:
            return 0
        case .compactTopTrailing:
            return compactActionMetrics(for: size).buttonSize <= 18 ? 6 : 10
        case .compactBottomTrailing:
            let metrics = compactActionMetrics(for: size)
            return metrics.buttonSize <= 18 ? 6 : 9
        case .singleBottomOverlay:
            return 14
        }
    }

    @ViewBuilder
    private func imageActions(for image: UIImage, availableSize: CGSize) -> some View {
        switch actionLayout {
        case .none:
            EmptyView()
        case .compactTopTrailing, .compactBottomTrailing:
            compactImageActionButtons(for: image, availableSize: availableSize)
        case .singleBottomOverlay:
            HStack(alignment: .bottom) {
                if let onEdit {
                    Button {
                        Task {
                            let imageForAction = await loadOriginalImageForAction() ?? image
                            await MainActor.run {
                                onEdit(imageForAction)
                                Haptics.play(.light)
                            }
                        }
                    } label: {
                        Text("编辑")
                            .scaledFont(size: 17, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(height: 48)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                Button {
                    Task {
                        await shareImage(await loadOriginalImageForAction() ?? image)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .scaledFont(size: 22, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func compactImageActionButtons(for image: UIImage, availableSize: CGSize) -> some View {
        let metrics = compactActionMetrics(for: availableSize)
        Group {
            if metrics.isVertical {
                VStack(spacing: metrics.spacing) {
                    compactImageActionButtonContent(for: image, metrics: metrics)
                }
            } else {
                HStack(spacing: metrics.spacing) {
                    compactImageActionButtonContent(for: image, metrics: metrics)
                }
            }
        }
        .padding(metrics.containerPadding)
        .background(.black.opacity(metrics.backgroundOpacity), in: Capsule())
    }

    @ViewBuilder
    private func compactImageActionButtonContent(for image: UIImage, metrics: CompactActionMetrics) -> some View {
        if let onEdit {
            Button {
                Task {
                    let imageForAction = await loadOriginalImageForAction() ?? image
                    await MainActor.run {
                        onEdit(imageForAction)
                        Haptics.play(.light)
                    }
                }
            } label: {
                imageActionLabel(
                    icon: "wand.and.stars",
                    accessibilityLabel: "编辑图片",
                    iconSize: metrics.iconSize,
                    buttonSize: metrics.buttonSize
                )
            }
            .buttonStyle(.plain)
        }

        Button {
            Task { await saveImageToPhotos() }
        } label: {
            imageActionLabel(
                icon: saveIcon,
                accessibilityLabel: saveLabel,
                isLoading: saveState == .saving,
                iconSize: metrics.iconSize,
                buttonSize: metrics.buttonSize
            )
        }
        .buttonStyle(.plain)
    }

    private func compactActionMetrics(for size: CGSize) -> CompactActionMetrics {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let isTiny = width < 116 || height < 112
        let isCompact = width < 150 || height < 138
        let isTallNarrow = width < 136 && height > width * 1.18

        if isTiny {
            return CompactActionMetrics(
                isVertical: isTallNarrow,
                buttonSize: 18,
                iconSize: 8.5,
                spacing: 1,
                containerPadding: 2.5,
                backgroundOpacity: 0.20
            )
        }

        if isCompact {
            return CompactActionMetrics(
                isVertical: isTallNarrow,
                buttonSize: 21,
                iconSize: 9.5,
                spacing: 2,
                containerPadding: 3,
                backgroundOpacity: 0.22
            )
        }

        return CompactActionMetrics(
            isVertical: false,
            buttonSize: 24,
            iconSize: 10.5,
            spacing: 3,
            containerPadding: 4,
            backgroundOpacity: 0.24
        )
    }

    private func imageActionLabel(
        icon: String,
        accessibilityLabel: String,
        isLoading: Bool = false,
        iconSize: CGFloat? = nil,
        buttonSize: CGFloat = 28
    ) -> some View {
        let resolvedIconSize = iconSize ?? (buttonSize <= 24 ? 10.5 : 12)
        return Group {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else {
                Image(systemName: icon)
                    .scaledFont(size: resolvedIconSize, weight: .semibold)
            }
        }
        .foregroundStyle(.white)
        .frame(width: buttonSize, height: buttonSize)
        .background(.black.opacity(0.58), in: Capsule())
        .accessibilityLabel(accessibilityLabel)
    }

    private func loadImage() async {
        if let cached = Self.imageCache.object(forKey: fileId as NSString) {
            setLoadedImage(cached, animated: false)
            return
        }

        if let inlineImage = await Self.inlineDataImage(from: fileId) {
            Self.imageCache.setObject(inlineImage.image, forKey: fileId as NSString, cost: inlineImage.cost)
            Self.cacheOriginalData(inlineImage.originalData, for: fileId)
            setLoadedImage(inlineImage.image)
            return
        }

        if let localURL = Self.localImageURL(from: fileId) {
            if let cached = Self.imageCache.object(forKey: fileId as NSString) {
                setLoadedImage(cached, animated: false)
                return
            }
            do {
                let loaded = try await Self.loadLocalImage(from: localURL)
                guard !Task.isCancelled else { return }
                Self.imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
                Self.cacheOriginalData(loaded.originalData, for: fileId)
                setLoadedImage(loaded.image)
                return
            } catch {
                hasError = true
                isLoading = false
                return
            }
        }

        if let localAlpinePath = Self.localAlpineImagePath(from: fileId) {
            do {
                let loaded = try await Self.loadLocalAlpineImage(from: localAlpinePath)
                guard !Task.isCancelled else { return }
                Self.imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
                Self.cacheOriginalData(loaded.originalData, for: fileId)
                setLoadedImage(loaded.image)
                return
            } catch {
                hasError = true
                isLoading = false
                return
            }
        }

        if let remoteURL = Self.remoteImageURL(from: fileId) {
            if loadedImage == nil {
                isLoading = true
            }
            let image = await ImageCacheService.shared.loadImage(
                from: remoteURL,
                authToken: authTokenForRemoteURL(remoteURL),
                targetPixelSize: Self.displayMaxPixelSize
            )
            if let image {
                setLoadedImage(image)
            } else {
                hasError = true
                isLoading = false
            }
            return
        }

        // Check in-memory cache first — if the image is cached, display it
        // instantly without resetting to the loading placeholder. This prevents
        // the height change (200px placeholder → actual image) that causes
        // scroll position jumps when scrolling up through a LazyVStack.
        if let cached = Self.imageCache.object(forKey: fileId as NSString) {
            if loadedImage !== cached {
                setLoadedImage(cached, animated: false)
            }
            isLoading = false
            hasError = false
            return
        }

        // Only show loading state if we don't already have an image.
        // When .task(id:) re-fires for the same fileId (e.g., scrolling back),
        // keeping the previous image prevents a flash to the placeholder.
        if loadedImage == nil {
            isLoading = true
        }
        hasError = false

        guard let apiClient else {
            hasError = true
            isLoading = false
            return
        }

        // Retry with exponential backoff — handles transient network failures,
        // app returning from background, and tool-generated images that aren't
        // immediately available on the server.
        for attempt in 0..<Self.maxAutoRetries {
            // Check for cancellation between retries (e.g., view disappeared)
            guard !Task.isCancelled else { break }

            do {
                let (data, _) = try await apiClient.getFileContent(id: fileId)
                let loaded = try await Self.decodeImageData(data, cacheKey: fileId)
                guard !Task.isCancelled else { return }
                Self.imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
                Self.cacheOriginalData(loaded.originalData, for: fileId)
                setLoadedImage(loaded.image)
                return
            } catch {
                // On last attempt, fall through to error state.
                // Otherwise wait with exponential backoff before retrying.
                if attempt < Self.maxAutoRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // 1s, 2s, 4s
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        // All retries exhausted — show tap-to-retry error state
        hasError = true
        isLoading = false
    }

    private func openPreview() {
        if let onPreview {
            onPreview()
        } else {
            showFullScreen = true
        }
    }

    static func loadImageValue(
        fileId: String,
        apiClient: APIClient?,
        preferOriginal: Bool = false
    ) async -> UIImage? {
        if preferOriginal,
           let original = await originalImageValue(fileId: fileId, apiClient: apiClient) {
            return original
        }

        if let cached = imageCache.object(forKey: fileId as NSString) {
            return cached
        }

        if let inlineImage = await inlineDataImage(from: fileId) {
            imageCache.setObject(inlineImage.image, forKey: fileId as NSString, cost: inlineImage.cost)
            cacheOriginalData(inlineImage.originalData, for: fileId)
            return inlineImage.image
        }

        if let localURL = localImageURL(from: fileId) {
            do {
                let loaded = try await loadLocalImage(from: localURL)
                imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
                cacheOriginalData(loaded.originalData, for: fileId)
                return loaded.image
            } catch {
                return nil
            }
        }

        if let localAlpinePath = localAlpineImagePath(from: fileId) {
            do {
                let loaded = try await loadLocalAlpineImage(from: localAlpinePath)
                imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
                cacheOriginalData(loaded.originalData, for: fileId)
                return loaded.image
            } catch {
                return nil
            }
        }

        if let remoteURL = remoteImageURL(from: fileId) {
            let image = await ImageCacheService.shared.loadImage(
                from: remoteURL,
                authToken: authTokenForRemoteURL(remoteURL, apiClient: apiClient),
                targetPixelSize: preferOriginal ? 0 : displayMaxPixelSize
            )
            if let image {
                imageCache.setObject(image, forKey: fileId as NSString)
            }
            return image
        }

        guard let apiClient else { return nil }
        for attempt in 0..<maxAutoRetries {
            guard !Task.isCancelled else { return nil }
            do {
                let (data, _) = try await apiClient.getFileContent(id: fileId)
                let loaded = try await decodeImageData(data, cacheKey: fileId)
                guard !Task.isCancelled else { return nil }
                imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
                cacheOriginalData(loaded.originalData, for: fileId)
                return loaded.image
            } catch {
                if attempt < maxAutoRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        return nil
    }

    private func setLoadedImage(_ image: UIImage, animated: Bool = true) {
        if animated && !reduceMotion {
            imageIsRevealed = false
            loadedImage = image
            hasError = false
            isLoading = false
            withAnimation(.easeOut(duration: 0.22)) {
                imageIsRevealed = true
            }
        } else {
            imageIsRevealed = true
            loadedImage = image
            hasError = false
            isLoading = false
        }
    }

    private func loadOriginalImageForAction() async -> UIImage? {
        await Self.originalImageValue(fileId: fileId, apiClient: apiClient)
    }

    private static func inlineDataImage(from dataURL: String) async -> LoadedLocalImage? {
        guard dataURL.hasPrefix("data:image/"),
              dataURL.count <= 80_000_000,
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        return await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  data.count <= 60_000_000,
                  let decoded = decodeDisplayImage(from: data, cacheKey: dataURL) else {
                return nil
            }
            return LoadedLocalImage(image: decoded.displayImage, cost: decoded.displayCost, originalData: data)
        }.value
    }

    private static func loadLocalImage(from url: URL) async throws -> LoadedLocalImage {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            guard let decoded = decodeDisplayImage(from: data, cacheKey: url.absoluteString) else {
                throw URLError(.cannotDecodeContentData)
            }
            return LoadedLocalImage(image: decoded.displayImage, cost: decoded.displayCost, originalData: data)
        }.value
    }

    private static func loadLocalAlpineImage(from path: String) async throws -> LoadedLocalImage {
        let data = try await LocalAlpineTerminalService.shared.readFile(path: path)
        return try await decodeImageData(data, cacheKey: "local-alpine:\(path)")
    }

    private static func decodeImageData(_ data: Data, cacheKey: String) async throws -> LoadedLocalImage {
        try await Task.detached(priority: .userInitiated) {
            guard let decoded = decodeDisplayImage(from: data, cacheKey: cacheKey) else {
                throw URLError(.cannotDecodeContentData)
            }
            return LoadedLocalImage(image: decoded.displayImage, cost: decoded.displayCost, originalData: data)
        }.value
    }

    private static func decodeDisplayImage(from data: Data, cacheKey: String) -> LoadedImageData? {
        let image = downsampledImage(data: data, maxPixelSize: displayMaxPixelSize)
            ?? UIImage(data: data)
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return LoadedImageData(
            displayImage: image,
            displayCost: bitmapCost(for: image, fallbackDataCount: data.count)
        )
    }

    private static func downsampledImage(data: Data, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0 else { return UIImage(data: data) }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func bitmapCost(for image: UIImage, fallbackDataCount: Int = 0) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let pixelCount = Int(image.size.width * image.scale) * Int(image.size.height * image.scale)
        return max(fallbackDataCount, pixelCount * 4)
    }

    private static func cacheOriginalData(_ data: Data?, for key: String) {
        guard let data else { return }
        let nsData = data as NSData
        originalImageDataCache.setObject(nsData, forKey: key as NSString, cost: data.count)
        if let url = try? writeOriginalImageDataToTemporaryCache(data, key: key) {
            originalImageURLCache.setObject(url as NSURL, forKey: key as NSString)
        }
    }

    private static func originalImageValue(fileId: String, apiClient: APIClient?) async -> UIImage? {
        if let cachedData = originalImageDataCache.object(forKey: fileId as NSString) {
            return await decodeOriginalImageData(cachedData as Data)
        }
        if let cachedURL = originalImageURLCache.object(forKey: fileId as NSString),
           let data = try? await loadOriginalData(from: cachedURL as URL) {
            originalImageDataCache.setObject(data as NSData, forKey: fileId as NSString, cost: data.count)
            return await decodeOriginalImageData(data)
        }
        if let localURL = localImageURL(from: fileId),
           let data = try? await loadOriginalData(from: localURL) {
            cacheOriginalData(data, for: fileId)
            return await decodeOriginalImageData(data)
        }
        if let localAlpinePath = localAlpineImagePath(from: fileId),
           let data = try? await LocalAlpineTerminalService.shared.readFile(path: localAlpinePath) {
            cacheOriginalData(data, for: fileId)
            return await decodeOriginalImageData(data)
        }
        if let remoteURL = remoteImageURL(from: fileId) {
            if let data = try? await loadRemoteOriginalData(
                from: remoteURL,
                authToken: authTokenForRemoteURL(remoteURL, apiClient: apiClient)
            ) {
                cacheOriginalData(data, for: fileId)
                return await decodeOriginalImageData(data)
            }
            return await loadImageValue(fileId: fileId, apiClient: apiClient, preferOriginal: false)
        }
        guard let apiClient else { return nil }
        do {
            let (data, _) = try await apiClient.getFileContent(id: fileId)
            cacheOriginalData(data, for: fileId)
            return await decodeOriginalImageData(data)
        } catch {
            return nil
        }
    }

    private static func loadOriginalData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    private static func loadRemoteOriginalData(from url: URL, authToken: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...399).contains(httpResponse.statusCode),
              !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func decodeOriginalImageData(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }

    private static func writeOriginalImageDataToTemporaryCache(_ data: Data, key: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iexa-original-image-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeScalars = key.unicodeScalars.map { scalar -> UnicodeScalar in
            CharacterSet.alphanumerics.contains(scalar) ? scalar : "-"
        }
        let fileName = String(String.UnicodeScalarView(safeScalars)).prefix(96)
        let url = directory.appendingPathComponent("\(fileName)-\(abs(key.hashValue)).img")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func localImageURL(from value: String) -> URL? {
        guard value.hasPrefix("file://") else { return nil }
        return URL(string: value)
    }

    private static func localAlpineImagePath(from value: String) -> String? {
        guard value.lowercased().hasPrefix("local-alpine:") else { return nil }
        var path = String(value.dropFirst("local-alpine:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("//") {
            path.removeFirst()
        }
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? path : "/mnt/iexa/\(path)"
    }

    private static func remoteImageURL(from value: String) -> URL? {
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        return URL(string: value)
    }

    private func authTokenForRemoteURL(_ remoteURL: URL) -> String? {
        Self.authTokenForRemoteURL(remoteURL, apiClient: apiClient)
    }

    private static func authTokenForRemoteURL(_ remoteURL: URL, apiClient: APIClient?) -> String? {
        guard let apiClient else { return nil }
        guard let token = apiClient.network.authToken, !token.isEmpty else { return nil }
        guard let baseURL = URL(string: apiClient.baseURL),
              remoteURL.host?.lowercased() == baseURL.host?.lowercased() else {
            return nil
        }
        return token
    }

    @MainActor
    private func saveImageToPhotos() async {
        guard saveState != .saving else { return }
        guard let image = await loadOriginalImageForAction() ?? loadedImage else {
            saveState = .failed
            return
        }

        saveState = .saving
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }

    @MainActor
    private func shareImage(_ image: UIImage) {
        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            // Find the topmost presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }
}

// MARK: - Full Screen Image Viewer

struct AuthenticatedImageGalleryItem: Identifiable, Hashable {
    let id: String
    let fileId: String
}

struct AuthenticatedImageGalleryPresentation: Identifiable {
    let id = UUID()
    let items: [AuthenticatedImageGalleryItem]
    let initialItemId: String
}

private enum FullScreenImageSaveState {
    case idle
    case saving
    case saved
    case failed
}

private func fullScreenSaveIcon(for state: FullScreenImageSaveState) -> String {
    switch state {
    case .idle, .saving: return "square.and.arrow.down"
    case .saved: return "checkmark"
    case .failed: return "exclamationmark.triangle"
    }
}

@ViewBuilder
private func fullScreenImageActionButton(
    icon: String,
    size: CGFloat = 18,
    weight: Font.Weight = .medium,
    isLoading: Bool = false,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: icon)
                    .scaledFont(size: size, weight: weight)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
    }
    .buttonStyle(.plain)
}

private func fullScreenImageControlsTopPadding(safeAreaTop: CGFloat) -> CGFloat {
    max(safeAreaTop + 14, 72)
}

struct FullScreenImageGalleryView: View {
    let items: [AuthenticatedImageGalleryItem]
    let initialItemId: String
    let apiClient: APIClient?

    @Environment(\.dismiss) private var dismiss
    @State private var currentItemId: String?
    @State private var zoomResetGeneration = 0
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var saveState: FullScreenImageSaveState = .idle

    init(
        items: [AuthenticatedImageGalleryItem],
        initialItemId: String,
        apiClient: APIClient?
    ) {
        self.items = items
        self.initialItemId = initialItemId
        self.apiClient = apiClient
        self._currentItemId = State(initialValue: initialItemId)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                FullScreenImageGalleryPage(
                                    item: item,
                                    apiClient: apiClient,
                                    resetToken: "\(item.id)-\(currentItemId == item.id ? zoomResetGeneration : 0)",
                                    onLoaded: { image in
                                        loadedImages[item.id] = image
                                    }
                                )
                                .containerRelativeFrame([.horizontal, .vertical], alignment: .center)
                                .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $currentItemId)
                    .ignoresSafeArea()
                    .onAppear {
                        currentItemId = initialItemId
                        zoomResetGeneration += 1
                        DispatchQueue.main.async {
                            proxy.scrollTo(initialItemId, anchor: .center)
                        }
                    }
                    .onChange(of: currentItemId) { _, newValue in
                        if newValue != nil {
                            zoomResetGeneration += 1
                            saveState = .idle
                        }
                    }
                }

                VStack {
                    HStack {
                        Spacer()

                        fullScreenImageActionButton(
                            icon: fullScreenSaveIcon(for: saveState),
                            isLoading: saveState == .saving
                        ) {
                            Task { await saveCurrentImage() }
                        }

                        fullScreenImageActionButton(icon: "square.and.arrow.up") {
                            Task { await shareCurrentImage() }
                        }

                        fullScreenImageActionButton(icon: "xmark", size: 16, weight: .bold) {
                            dismiss()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, fullScreenImageControlsTopPadding(safeAreaTop: geometry.safeAreaInsets.top))

                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }

    @MainActor
    private func currentImageForAction() async -> UIImage? {
        let selectedId = currentItemId ?? initialItemId
        guard let item = items.first(where: { $0.id == selectedId }) ?? items.first else { return nil }
        if let cached = loadedImages[item.id] {
            return cached
        }
        let image = await AuthenticatedImageView.loadImageValue(
            fileId: item.fileId,
            apiClient: apiClient,
            preferOriginal: true
        )
        if let image {
            loadedImages[item.id] = image
        }
        return image
    }

    @MainActor
    private func shareCurrentImage() async {
        guard let image = await currentImageForAction() else { return }
        presentShareSheet(for: image)
    }

    @MainActor
    private func saveCurrentImage() async {
        guard saveState != .saving else { return }
        saveState = .saving
        guard let image = await currentImageForAction() else {
            saveState = .failed
            return
        }
        await saveImageToPhotoLibrary(image)
    }

    @MainActor
    private func saveImageToPhotoLibrary(_ image: UIImage) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }

    @MainActor
    private func presentShareSheet(for image: UIImage) {
        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }
}

private struct FullScreenImageGalleryPage: View {
    let item: AuthenticatedImageGalleryItem
    let apiClient: APIClient?
    let resetToken: String
    let onLoaded: (UIImage) -> Void

    @State private var image: UIImage?
    @State private var didFail = false
    @State private var appearResetGeneration = 0

    private var effectiveResetToken: String {
        "\(resetToken)-appear-\(appearResetGeneration)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .center) {
                Color.clear

                if let image {
                    ZoomableImageView(image: image, resetToken: effectiveResetToken)
                        .id(effectiveResetToken)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                } else if didFail {
                    Image(systemName: "photo")
                        .scaledFont(size: 34, weight: .medium)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .clipped()
        }
        .onAppear {
            appearResetGeneration += 1
        }
        .task(id: item.fileId) {
            guard image == nil else { return }
            if let loaded = await AuthenticatedImageView.loadImageValue(
                fileId: item.fileId,
                apiClient: apiClient,
                preferOriginal: true
            ) {
                image = loaded
                onLoaded(loaded)
            } else {
                didFail = true
            }
        }
    }
}

/// A full-screen image viewer with pinch-to-zoom, double-tap-to-zoom,
/// dismiss gesture, and share button.
struct FullScreenImageView: View {
    let fileId: String
    let apiClient: APIClient?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var didFail = false
    @State private var saveState: FullScreenImageSaveState = .idle

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    // Zoomable image using UIScrollView for proper pinch-to-zoom
                    ZoomableImageView(image: image)
                        .ignoresSafeArea()
                } else if didFail {
                    Image(systemName: "photo")
                        .scaledFont(size: 34, weight: .medium)
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                // Top bar with save, share, and close buttons
                VStack {
                    HStack {
                        Spacer()

                        fullScreenImageActionButton(
                            icon: fullScreenSaveIcon(for: saveState),
                            isLoading: saveState == .saving
                        ) {
                            Task { await saveImage() }
                        }

                        fullScreenImageActionButton(icon: "square.and.arrow.up") {
                            shareImage()
                        }

                        fullScreenImageActionButton(icon: "xmark", size: 16, weight: .bold) {
                            dismiss()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, fullScreenImageControlsTopPadding(safeAreaTop: proxy.safeAreaInsets.top))

                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task(id: fileId) {
            await loadImage()
        }
    }

    private func shareImage() {
        guard let image else { return }
        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }

    @MainActor
    private func saveImage() async {
        guard saveState != .saving else { return }
        saveState = .saving
        let imageForSaving = await AuthenticatedImageView.loadImageValue(
            fileId: fileId,
            apiClient: apiClient,
            preferOriginal: true
        ) ?? image
        guard let imageForSaving else {
            saveState = .failed
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: imageForSaving)
            }
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }

    private func loadImage() async {
        guard image == nil else { return }
        if let loaded = await AuthenticatedImageView.loadImageValue(
            fileId: fileId,
            apiClient: apiClient,
            preferOriginal: true
        ) {
            image = loaded
        } else {
            didFail = true
        }
    }
}

// MARK: - Zoomable Image View (UIKit-backed)

/// A `UIViewRepresentable` that wraps `UIScrollView` to provide native
/// pinch-to-zoom and double-tap-to-zoom for images.
///
/// - Minimum zoom: fits the image to the screen (aspect fit)
/// - Maximum zoom: 5×
/// - Double-tap toggles between 1× and 2.5× zoom
/// - Image is centered when zoomed out below the viewport size
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let resetToken: String?

    init(image: UIImage, resetToken: String? = nil) {
        self.image = image
        self.resetToken = resetToken
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomLayoutScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.tag = 100
        scrollView.addSubview(imageView)

        // Double-tap gesture to toggle zoom
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        let coordinator = context.coordinator
        scrollView.onLayout = { [weak coordinator] in
            coordinator?.layoutDidChange()
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let imageChanged = context.coordinator.image !== image
        if imageChanged {
            context.coordinator.image = image
            context.coordinator.imageView?.image = image
            context.coordinator.invalidateInitialZoom()
        }
        let shouldReset = imageChanged || context.coordinator.consumeResetToken(resetToken)

        if shouldReset {
            context.coordinator.resetZoom(animated: false)
        } else {
            context.coordinator.updateZoomScale()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var image: UIImage
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private var hasSetInitialZoom = false
        private var lastResetToken: String?
        private var lastBoundsSize: CGSize = .zero
        private var needsResetAfterLayout = true

        init(image: UIImage) {
            self.image = image
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImageInScrollView()
        }

        func invalidateInitialZoom() {
            hasSetInitialZoom = false
            needsResetAfterLayout = true
        }

        func consumeResetToken(_ token: String?) -> Bool {
            guard let token else { return false }
            guard lastResetToken != token else { return false }
            lastResetToken = token
            return true
        }

        func resetZoom(animated: Bool) {
            needsResetAfterLayout = true
            updateZoomScale(forceReset: true, animated: animated)
        }

        func layoutDidChange() {
            guard let scrollView else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0 && boundsSize.height > 0 else { return }
            let boundsChanged = abs(boundsSize.width - lastBoundsSize.width) > 0.5
                || abs(boundsSize.height - lastBoundsSize.height) > 0.5
            if needsResetAfterLayout {
                updateZoomScale(forceReset: true, animated: false)
            } else if boundsChanged {
                updateZoomScale()
            }
        }

        func updateZoomScale(forceReset: Bool = false, animated: Bool = false) {
            guard let scrollView, let imageView else { return }
            let shouldForceReset = forceReset || needsResetAfterLayout
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0 && boundsSize.height > 0 else {
                if shouldForceReset {
                    needsResetAfterLayout = true
                }
                return
            }

            let imageSize = image.size
            guard imageSize.width > 0 && imageSize.height > 0 else { return }

            // Treat the fitted image size as the 1x baseline. This avoids
            // carrying a UIScrollView zoomScale from one paged image to another.
            let xScale = boundsSize.width / imageSize.width
            let yScale = boundsSize.height / imageSize.height
            let fitScale = min(xScale, yScale)
            let fittedSize = CGSize(
                width: imageSize.width * fitScale,
                height: imageSize.height * fitScale
            )

            scrollView.minimumZoomScale = 1.0
            let nativeScale = max(imageSize.width / max(fittedSize.width, 1), imageSize.height / max(fittedSize.height, 1))
            scrollView.maximumZoomScale = max(5.0, min(nativeScale * 1.5, 12.0))

            imageView.frame = CGRect(
                origin: .zero,
                size: fittedSize
            )
            scrollView.contentSize = fittedSize

            if shouldForceReset || !hasSetInitialZoom || scrollView.zoomScale < scrollView.minimumZoomScale {
                hasSetInitialZoom = true
                needsResetAfterLayout = false
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
                scrollView.contentOffset = .zero
            }
            lastBoundsSize = boundsSize

            centerImageInScrollView()
        }

        /// Centers the image when it is smaller than the scroll view bounds.
        private func centerImageInScrollView() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            var frameToCenter = imageView.frame

            // Center horizontally
            if frameToCenter.size.width < boundsSize.width {
                frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
            } else {
                frameToCenter.origin.x = 0
            }

            // Center vertically
            if frameToCenter.size.height < boundsSize.height {
                frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
            } else {
                frameToCenter.origin.y = 0
            }

            imageView.frame = frameToCenter
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let minScale = scrollView.minimumZoomScale

            if scrollView.zoomScale > minScale + 0.01 {
                // Zoom out to fit
                scrollView.setZoomScale(minScale, animated: true)
            } else {
                // Zoom in to 2.5× at the tapped point
                let targetScale = min(minScale * 2.5, scrollView.maximumZoomScale)
                let location = gesture.location(in: scrollView.subviews.first)
                let zoomRect = zoomRectForScale(targetScale, center: location, in: scrollView)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        private func zoomRectForScale(
            _ scale: CGFloat,
            center: CGPoint,
            in scrollView: UIScrollView
        ) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            let origin = CGPoint(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2
            )
            return CGRect(origin: origin, size: size)
        }
    }
}

private final class ZoomLayoutScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
