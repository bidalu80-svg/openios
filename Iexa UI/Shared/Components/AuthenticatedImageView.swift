import SwiftUI
import Photos

/// Loads and displays an image from the server using authenticated API calls.
/// Supports:
/// - Tap to view full screen with pinch-to-zoom
/// - Long press context menu with Copy and Share options
struct AuthenticatedImageView: View {
    let fileId: String
    let apiClient: APIClient?
    let onEdit: ((UIImage) -> Void)?
    let onPreview: (() -> Void)?

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
    }

    init(
        fileId: String,
        apiClient: APIClient?,
        onEdit: ((UIImage) -> Void)? = nil,
        onPreview: (() -> Void)? = nil
    ) {
        self.fileId = fileId
        self.apiClient = apiClient
        self.onEdit = onEdit
        self.onPreview = onPreview
    }

    /// In-memory cache for file-based images. Prevents re-fetching when
    /// scrolling back through the chat, which causes layout shifts and
    /// scroll position jumps in the LazyVStack.
    private static let imageCache = NSCache<NSString, UIImage>()
    static func configureCache() {
        imageCache.countLimit = 80
        imageCache.totalCostLimit = 60 * 1024 * 1024 // 60 MB
    }

    var body: some View {
        // Use a fixed-height container for ALL states (loading, loaded, error)
        // to prevent layout shifts that cause scroll position jumps.
        // The image is constrained to the same height as the placeholder
        // so the scroll view never needs to re-layout when images finish loading.
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(imageIsRevealed ? 1 : 0)
                        .scaleEffect(imageIsRevealed || reduceMotion ? 1 : 0.985)
                        .onTapGesture {
                            openPreview()
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.image = image
                                Haptics.notify(.success)
                            } label: {
                                Label("复制图片", systemImage: "doc.on.doc")
                            }

                            Button {
                                Task { await saveImageToPhotos() }
                            } label: {
                                Label("保存到相册", systemImage: "photo")
                            }

                            Button {
                                shareImage(image)
                            } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }

                            if let onEdit {
                                Button {
                                    onEdit(image)
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

            if let image = loadedImage {
                HStack(spacing: 4) {
                    if let onEdit {
                        Button {
                            onEdit(image)
                            Haptics.play(.light)
                        } label: {
                            imageActionLabel(icon: "wand.and.stars", accessibilityLabel: "编辑图片")
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        Task { await saveImageToPhotos() }
                    } label: {
                        imageActionLabel(
                            icon: saveIcon,
                            accessibilityLabel: saveLabel,
                            isLoading: saveState == .saving
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(5)
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
            if let image = loadedImage {
                FullScreenImageView(image: image)
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

    private func imageActionLabel(
        icon: String,
        accessibilityLabel: String,
        isLoading: Bool = false
    ) -> some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else {
                Image(systemName: icon)
                    .scaledFont(size: 12, weight: .semibold)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
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
                authToken: authTokenForRemoteURL(remoteURL)
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
                let loaded = try await Self.decodeImageData(data)
                guard !Task.isCancelled else { return }
                Self.imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
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

    static func loadImageValue(fileId: String, apiClient: APIClient?) async -> UIImage? {
        if let cached = imageCache.object(forKey: fileId as NSString) {
            return cached
        }

        if let inlineImage = await inlineDataImage(from: fileId) {
            imageCache.setObject(inlineImage.image, forKey: fileId as NSString, cost: inlineImage.cost)
            return inlineImage.image
        }

        if let localURL = localImageURL(from: fileId) {
            do {
                let loaded = try await loadLocalImage(from: localURL)
                imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
                return loaded.image
            } catch {
                return nil
            }
        }

        if let remoteURL = remoteImageURL(from: fileId) {
            let image = await ImageCacheService.shared.loadImage(
                from: remoteURL,
                authToken: authTokenForRemoteURL(remoteURL, apiClient: apiClient)
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
                let loaded = try await decodeImageData(data)
                guard !Task.isCancelled else { return nil }
                imageCache.setObject(loaded.image, forKey: fileId as NSString, cost: loaded.cost)
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

    private static func inlineDataImage(from dataURL: String) async -> LoadedLocalImage? {
        guard dataURL.hasPrefix("data:image/"),
              dataURL.count <= 7_000_000,
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        return await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  data.count <= 5_000_000,
                  let image = UIImage(data: data) else {
                return nil
            }
            return LoadedLocalImage(image: image, cost: data.count)
        }.value
    }

    private static func loadLocalImage(from url: URL) async throws -> LoadedLocalImage {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            guard let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            return LoadedLocalImage(image: image, cost: data.count)
        }.value
    }

    private static func decodeImageData(_ data: Data) async throws -> LoadedLocalImage {
        try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            return LoadedLocalImage(image: image, cost: data.count)
        }.value
    }

    private static func localImageURL(from value: String) -> URL? {
        guard value.hasPrefix("file://") else { return nil }
        return URL(string: value)
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
        guard let image = loadedImage else {
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

struct FullScreenImageGalleryView: View {
    let items: [AuthenticatedImageGalleryItem]
    let initialItemId: String
    let apiClient: APIClient?

    @Environment(\.dismiss) private var dismiss
    @State private var currentItemId: String
    @State private var loadedImages: [String: UIImage] = [:]

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
            let pageSize = geometry.size

            ZStack {
                Color.black.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                FullScreenImageGalleryPage(
                                    item: item,
                                    apiClient: apiClient,
                                    pageSize: pageSize,
                                    onLoaded: { image in
                                        loadedImages[item.id] = image
                                    }
                                )
                                .frame(width: pageSize.width, height: pageSize.height, alignment: .center)
                                .id(item.id)
                                .onAppear {
                                    currentItemId = item.id
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                    .ignoresSafeArea()
                    .onAppear {
                        currentItemId = initialItemId
                        DispatchQueue.main.async {
                            proxy.scrollTo(initialItemId, anchor: .top)
                        }
                    }
                }

                VStack {
                    HStack {
                        Spacer()

                        Button {
                            Task { await shareCurrentImage() }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .scaledFont(size: 18, weight: .medium)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .scaledFont(size: 16, weight: .bold)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()
                }
            }
        }
        .statusBarHidden()
    }

    @MainActor
    private func shareCurrentImage() async {
        guard let item = items.first(where: { $0.id == currentItemId }) ?? items.first else { return }
        let image: UIImage?
        if let cached = loadedImages[item.id] {
            image = cached
        } else {
            image = await AuthenticatedImageView.loadImageValue(fileId: item.fileId, apiClient: apiClient)
            if let image {
                loadedImages[item.id] = image
            }
        }
        guard let image else { return }
        presentShareSheet(for: image)
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
    let pageSize: CGSize
    let onLoaded: (UIImage) -> Void

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack(alignment: .center) {
            Color.clear

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: pageSize.width, height: pageSize.height, alignment: .center)
            } else if didFail {
                Image(systemName: "photo")
                    .scaledFont(size: 34, weight: .medium)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: pageSize.width, height: pageSize.height, alignment: .center)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(width: pageSize.width, height: pageSize.height, alignment: .center)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .center)
        .clipped()
        .task(id: item.fileId) {
            guard image == nil else { return }
            if let loaded = await AuthenticatedImageView.loadImageValue(
                fileId: item.fileId,
                apiClient: apiClient
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
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Zoomable image using UIScrollView for proper pinch-to-zoom
            ZoomableImageView(image: image)
                .ignoresSafeArea()

            // Top bar with close and share buttons
            VStack {
                HStack {
                    Spacer()

                    // Share button
                    Button {
                        shareImage()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .scaledFont(size: 18, weight: .medium)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    // Close button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 16, weight: .bold)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()
            }
        }
        .statusBarHidden()
    }

    private func shareImage() {
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

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
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

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Recalculate zoom scales when the view size changes
        DispatchQueue.main.async {
            context.coordinator.updateZoomScale()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let image: UIImage
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private var hasSetInitialZoom = false

        init(image: UIImage) {
            self.image = image
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImageInScrollView()
        }

        func updateZoomScale() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0 && boundsSize.height > 0 else { return }

            let imageSize = image.size
            guard imageSize.width > 0 && imageSize.height > 0 else { return }

            // Calculate the scale that fits the image within the scroll view
            let xScale = boundsSize.width / imageSize.width
            let yScale = boundsSize.height / imageSize.height
            let minScale = min(xScale, yScale)

            scrollView.minimumZoomScale = minScale
            scrollView.maximumZoomScale = max(minScale * 5, 5.0)

            // Set the image view frame to the actual image size
            imageView.frame = CGRect(
                origin: .zero,
                size: imageSize
            )
            scrollView.contentSize = imageSize

            if !hasSetInitialZoom {
                hasSetInitialZoom = true
                scrollView.zoomScale = minScale
            }

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

            if scrollView.zoomScale > minScale {
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
