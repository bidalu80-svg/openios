import SwiftUI
import WebKit
import AVKit
import AVFoundation

struct WebPreviewURL: Identifiable, Equatable {
    let url: URL

    var id: String { url.absoluteString }
}

struct InAppWebPreviewSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var state = InAppWebPreviewState()
    @State private var resolvedDouyinPost: ResolvedDouyinPost?
    @State private var resolvedXiaohongshuPost: ResolvedXiaohongshuPost?
    @State private var isResolvingDouyin = false
    @State private var isDownloadingDouyin = false
    @State private var douyinErrorMessage: String?
    @State private var playingVideo: WebPreviewVideoItem?
    @State private var downloadedMedia: WebPreviewDownloadedMedia?
    @State private var resolvedDouyinSourceID = ""
    @State private var resolvedXiaohongshuSourceID = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                InAppWebPreviewRepresentable(url: url, state: state)
                    .ignoresSafeArea(edges: .bottom)

                if state.isLoading {
                    ProgressView(value: state.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(theme.brandPrimary)
                        .frame(maxWidth: .infinity)
                }

                if shouldShowDouyinControls {
                    VStack {
                        Spacer()
                        douyinControlBar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                    }
                }
            }
            .navigationTitle(state.title.isEmpty ? hostLabel : state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        state.webView?.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!state.canGoBack)

                    Button {
                        state.webView?.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        UIApplication.shared.open(state.currentURL ?? url)
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
        .task(id: douyinTaskID) {
            await resolveSocialMediaIfNeeded()
        }
        .onChange(of: state.pageVideoURL) { _, _ in
            if resolvedDouyinPost?.video == nil && resolvedXiaohongshuPost?.video == nil {
                douyinErrorMessage = nil
            }
        }
        .onChange(of: activeURL) { _, newURL in
            guard !isSupportedSocialMediaURL(newURL) else { return }
            resolvedDouyinPost = nil
            resolvedXiaohongshuPost = nil
            resolvedDouyinSourceID = ""
            resolvedXiaohongshuSourceID = ""
            douyinErrorMessage = nil
        }
        .sheet(item: $playingVideo) { item in
            WebPreviewVideoPlayerSheet(url: item.url, refererURL: activeURL)
        }
        .sheet(item: $downloadedMedia) { item in
            ShareSheetView(activityItems: item.urls)
        }
        .alert("\(activeSocialPlatformName)解析失败", isPresented: Binding(
            get: { douyinErrorMessage != nil },
            set: { if !$0 { douyinErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(douyinErrorMessage ?? "")
        }
    }

    private var hostLabel: String {
        guard var host = url.host, !host.isEmpty else { return "网页预览" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private var activeURL: URL {
        state.currentURL ?? url
    }

    private var douyinTaskID: String {
        guard isSupportedSocialMediaURL(activeURL) else { return "" }
        return activeURL.absoluteString
    }

    private var shouldShowDouyinControls: Bool {
        isSupportedSocialMediaURL(activeURL)
            || resolvedDouyinPost?.hasMedia == true
            || resolvedXiaohongshuPost?.hasMedia == true
            || state.pageVideoURL != nil
    }

    private var playableVideoURL: URL? {
        if WebLinkContextResolver.isXiaohongshuURL(activeURL) {
            if let raw = resolvedXiaohongshuPost?.videoCandidates.first?.url ?? resolvedXiaohongshuPost?.video?.url,
               let url = URL(string: raw) {
                return url
            }
            return safePageVideoURL(state.pageVideoURL)
        }
        if WebLinkContextResolver.isDouyinURL(activeURL) {
            if let raw = resolvedDouyinPost?.video?.url, let url = URL(string: raw) {
                return url
            }
            return safePageVideoURL(state.pageVideoURL)
        }
        if let raw = resolvedDouyinPost?.video?.url, let url = URL(string: raw) {
            return url
        }
        if let raw = resolvedXiaohongshuPost?.video?.url, let url = URL(string: raw) {
            return url
        }
        return safePageVideoURL(state.pageVideoURL)
    }

    private func safePageVideoURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        if WebLinkContextResolver.isXiaohongshuURL(activeURL),
           Self.isUnsignedXiaohongshuCDNVideoURL(url) {
            return nil
        }
        return url
    }

    private static func isUnsignedXiaohongshuCDNVideoURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains("sns-video-v")
            && lower.contains(".mp4")
            && (url.query?.isEmpty ?? true)
    }

    private var resolvedImageCount: Int {
        activeResolvedImages.count
    }

    private var activeResolvedImages: [ResolvedWebImage] {
        if WebLinkContextResolver.isXiaohongshuURL(activeURL) {
            return resolvedXiaohongshuPost?.images ?? []
        }
        if WebLinkContextResolver.isDouyinURL(activeURL) {
            return resolvedDouyinPost?.images ?? []
        }
        return resolvedXiaohongshuPost?.images ?? resolvedDouyinPost?.images ?? []
    }

    private var activeResolvedVideoTitle: String? {
        if WebLinkContextResolver.isXiaohongshuURL(activeURL) {
            return resolvedXiaohongshuPost?.video?.title
        }
        if WebLinkContextResolver.isDouyinURL(activeURL) {
            return resolvedDouyinPost?.video?.title
        }
        return resolvedXiaohongshuPost?.video?.title ?? resolvedDouyinPost?.video?.title
    }

    private var activeResolvedVideoURLs: [URL] {
        if WebLinkContextResolver.isXiaohongshuURL(activeURL) {
            let candidateURLs = resolvedXiaohongshuPost?.videoCandidates.compactMap { URL(string: $0.url) } ?? []
            if !candidateURLs.isEmpty { return candidateURLs }
        }
        if let url = playableVideoURL {
            return [url]
        }
        return []
    }

    private var activeSocialPlatformName: String {
        WebLinkContextResolver.isXiaohongshuURL(activeURL) ? "小红书" : "抖音"
    }

    private func isSupportedSocialMediaURL(_ url: URL) -> Bool {
        WebLinkContextResolver.isDouyinURL(url) || WebLinkContextResolver.isXiaohongshuURL(url)
    }

    private var douyinControlBar: some View {
        HStack(spacing: 10) {
            Image(systemName: douyinLeadingIconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(hasDownloadableDouyinMedia ? theme.brandPrimary : theme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedDouyinTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(douyinStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isResolvingDouyin || isDownloadingDouyin {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                guard let url = playableVideoURL else {
                    Task { await resolveSocialMediaIfNeeded(force: true) }
                    return
                }
                playingVideo = WebPreviewVideoItem(url: url)
            } label: {
                Image(systemName: playableVideoURL == nil ? "arrow.clockwise" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isResolvingDouyin || (playableVideoURL == nil && resolvedImageCount > 0))
            .opacity(playableVideoURL == nil && resolvedImageCount > 0 ? 0.45 : 1)

            Button {
                Task { await downloadDouyinMedia() }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!hasDownloadableDouyinMedia || isDownloadingDouyin)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.28 : 0.12), radius: 12, y: 4)
    }

    private var douyinStatusText: String {
        if isResolvingDouyin { return "正在解析可播放地址..." }
        if isDownloadingDouyin { return "正在下载..." }
        if playableVideoURL != nil { return "可在 App 内播放或下载" }
        if resolvedImageCount > 0 { return "已解析 \(resolvedImageCount) 张图片，可下载保存" }
        return "打开\(activeSocialPlatformName)链接后自动解析"
    }

    private var douyinLeadingIconName: String {
        if playableVideoURL != nil { return "play.rectangle.fill" }
        if resolvedImageCount > 0 { return "photo.on.rectangle.angled" }
        return "link.badge.plus"
    }

    private var resolvedDouyinTitle: String {
        if let title = activeResolvedVideoTitle, playableVideoURL != nil {
            return title
        }
        if let imageTitle = activeResolvedImages.first?.title, resolvedImageCount > 0 {
            return imageTitle
        }
        return activeResolvedVideoTitle ?? "\(activeSocialPlatformName)内容"
    }

    private var hasDownloadableDouyinMedia: Bool {
        playableVideoURL != nil || resolvedImageCount > 0
    }

    @MainActor
    private func resolveDouyinIfNeeded(force: Bool = false) async {
        guard WebLinkContextResolver.isDouyinURL(activeURL) else { return }
        let sourceID = activeURL.absoluteString
        guard force || resolvedDouyinSourceID != sourceID else { return }
        guard !isResolvingDouyin else { return }

        isResolvingDouyin = true
        defer { isResolvingDouyin = false }

        do {
            let post = try await WebLinkContextResolver().resolveDouyinPost(activeURL)
            resolvedDouyinPost = post
            resolvedDouyinSourceID = sourceID
            douyinErrorMessage = nil
        } catch {
            if force, state.pageVideoURL == nil {
                douyinErrorMessage = "当前页面没有解析到可播放视频地址。你可以先让页面加载完成，再点刷新解析。"
            }
        }
    }

    @MainActor
    private func resolveXiaohongshuIfNeeded(force: Bool = false) async {
        guard WebLinkContextResolver.isXiaohongshuURL(activeURL) else { return }
        let sourceID = activeURL.absoluteString
        guard force || resolvedXiaohongshuSourceID != sourceID else { return }
        guard !isResolvingDouyin else { return }

        isResolvingDouyin = true
        defer { isResolvingDouyin = false }

        do {
            let post = try await WebLinkContextResolver().resolveXiaohongshuPost(activeURL)
            resolvedXiaohongshuPost = post
            resolvedXiaohongshuSourceID = sourceID
            douyinErrorMessage = nil
        } catch {
            if force, state.pageVideoURL == nil {
                douyinErrorMessage = "当前页面没有解析到可播放视频地址。你可以先让页面加载完成，再点刷新解析。"
            }
        }
    }

    @MainActor
    private func resolveSocialMediaIfNeeded(force: Bool = false) async {
        if WebLinkContextResolver.isXiaohongshuURL(activeURL) {
            await resolveXiaohongshuIfNeeded(force: force)
        } else {
            await resolveDouyinIfNeeded(force: force)
        }
    }

    @MainActor
    private func downloadDouyinMedia() async {
        guard hasDownloadableDouyinMedia else { return }
        guard !isDownloadingDouyin else { return }

        isDownloadingDouyin = true
        defer { isDownloadingDouyin = false }

        do {
            if WebLinkContextResolver.isXiaohongshuURL(activeURL) {
                await resolveXiaohongshuIfNeeded(force: true)
            }

            let videoURLs = activeResolvedVideoURLs
            if !videoURLs.isEmpty {
                var lastError: Error?
                for videoURL in videoURLs {
                    do {
                        let (temporaryURL, response) = try await downloadMediaFile(from: videoURL)
                        let destination = FileManager.default.temporaryDirectory
                            .appendingPathComponent(downloadFileName(response: response, url: videoURL))
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporaryURL, to: destination)
                        downloadedMedia = WebPreviewDownloadedMedia(urls: [destination])
                        return
                    } catch {
                        lastError = error
                    }
                }
                throw lastError ?? URLError(.cannotDecodeContentData)
            }

            let images = activeResolvedImages
            if !images.isEmpty {
                let urls = try await downloadDouyinImages(images)
                downloadedMedia = WebPreviewDownloadedMedia(urls: urls)
            }
        } catch {
            douyinErrorMessage = "下载失败：\(error.localizedDescription)"
        }
    }

    private func downloadMediaFile(from url: URL) async throws -> (URL, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 300)
        applyMediaDownloadHeaders(to: &request, sourceURL: url)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try validateDownloadedMedia(at: temporaryURL, response: response, sourceURL: url)
        return (temporaryURL, response)
    }

    private func applyMediaDownloadHeaders(to request: inout URLRequest, sourceURL: URL) {
        if WebLinkContextResolver.isXiaohongshuURL(activeURL),
           Self.isXiaohongshuCDNMediaURL(sourceURL) {
            request.setValue(Self.xiaohongshuMediaUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(
                "image/avif,image/webp,image/apng,image/*,video/mp4,video/*,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://www.xiaohongshu.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
            if Self.isVideoMediaURL(sourceURL) {
                request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            }
            return
        }

        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(activeURL.absoluteString, forHTTPHeaderField: "Referer")
    }

    private func validateDownloadedMedia(at fileURL: URL, response: URLResponse, sourceURL: URL) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw URLError(.badServerResponse)
        }

        let values = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (values[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 1_024 else {
            try? FileManager.default.removeItem(at: fileURL)
            throw URLError(.cannotDecodeContentData)
        }

        if shouldValidateAsMP4(sourceURL: sourceURL, response: response) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { handle.closeFile() }
            let data = handle.readData(ofLength: 12)
            guard data.count >= 12,
                  data.subdata(in: 4..<8) == Data("ftyp".utf8) else {
                try? FileManager.default.removeItem(at: fileURL)
                throw URLError(.cannotDecodeContentData)
            }
        }
    }

    private func shouldValidateAsMP4(sourceURL: URL, response: URLResponse) -> Bool {
        let lower = sourceURL.absoluteString.lowercased()
        let contentType = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return Self.isVideoMediaURL(sourceURL)
            || lower.contains("sns-video")
            || lower.contains("sns-bak")
            || lower.contains("xhs-video")
            || lower.contains("aweme/v1/play")
            || contentType.contains("video/mp4")
    }

    private static func isXiaohongshuCDNMediaURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "ci.xiaohongshu.com" || host == "xhscdn.com" || host.hasSuffix(".xhscdn.com")
    }

    private static func isVideoMediaURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(pathExtension) { return true }
        let lower = url.absoluteString.lowercased()
        return lower.contains("sns-video")
            || lower.contains("sns-bak")
            || lower.contains("xhs-video")
            || lower.contains("downloader-api.bhwa233.com/api/download")
    }

    @MainActor
    private func downloadDouyinImages(_ images: [ResolvedWebImage]) async throws -> [URL] {
        let platformDirectoryPrefix = WebLinkContextResolver.isXiaohongshuURL(activeURL) ? "xiaohongshu" : "douyin"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(platformDirectoryPrefix)-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var downloaded: [URL] = []
        for image in images {
            guard let imageURL = URL(string: image.url) else { continue }
            var request = URLRequest(url: imageURL, timeoutInterval: 120)
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue(activeURL.absoluteString, forHTTPHeaderField: "Referer")
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            let destination = directory.appendingPathComponent(downloadImageFileName(image: image, response: response, url: imageURL))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            downloaded.append(destination)
        }

        guard !downloaded.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        return downloaded
    }

    private func downloadFileName(response: URLResponse, url: URL) -> String {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           let filename = filenameFromContentDisposition(disposition) {
            return filename
        }

        let title = activeResolvedVideoTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title.lowercased().hasSuffix(".mp4") ? title : "\(title).mp4"
        }

        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last != "/" {
            return (last as NSString).pathExtension.isEmpty ? "\(last).mp4" : last
        }
        return WebLinkContextResolver.isXiaohongshuURL(activeURL) ? "xiaohongshu-video.mp4" : "douyin-video.mp4"
    }

    private func downloadImageFileName(image: ResolvedWebImage, response: URLResponse, url: URL) -> String {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           let filename = filenameFromContentDisposition(disposition) {
            return filename
        }

        let title = image.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last != "/" {
            return (last as NSString).pathExtension.isEmpty ? "\(last).jpg" : last
        }
        let prefix = WebLinkContextResolver.isXiaohongshuURL(activeURL) ? "xiaohongshu-image" : "douyin-image"
        return "\(prefix)-\(image.index).jpg"
    }

    private func filenameFromContentDisposition(_ disposition: String) -> String? {
        let patterns = [
            #"filename\*=UTF-8''([^;]+)"#,
            #"filename="([^"]+)""#,
            #"filename=([^;]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: disposition) else { continue }
            return String(disposition[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;"))
                .removingPercentEncoding
        }
        return nil
    }

    fileprivate static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    fileprivate static let xiaohongshuMediaUserAgent =
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36 xiaohongshu"
}

@Observable
final class InAppWebPreviewState {
    var isLoading = true
    var estimatedProgress = 0.05
    var title = ""
    var currentURL: URL?
    var canGoBack = false
    var pageVideoURL: URL?
    @ObservationIgnored
    weak var webView: WKWebView?
}

private struct WebPreviewVideoItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct WebPreviewDownloadedMedia: Identifiable {
    let urls: [URL]
    let id = UUID().uuidString
}

private struct WebPreviewVideoPlayerSheet: View {
    let url: URL
    let refererURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("视频预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": InAppWebPreviewSheet.mobileUserAgent,
                    "Referer": refererURL.absoluteString
                ]
            ])
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct InAppWebPreviewRepresentable: UIViewRepresentable {
    let url: URL
    let state: InAppWebPreviewState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

        context.coordinator.webView = webView
        state.webView = webView
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [.new], context: nil)
        load(url, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            load(url, in: webView)
        }
    }

    private func load(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.removeObserver(coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: InAppWebPreviewState
        weak var webView: WKWebView?

        init(state: InAppWebPreviewState) {
            self.state = state
        }

        override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard keyPath == #keyPath(WKWebView.estimatedProgress),
                  let webView = object as? WKWebView else {
                return
            }
            state.estimatedProgress = webView.estimatedProgress
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.isLoading = true
            state.currentURL = webView.url
            state.canGoBack = webView.canGoBack
            state.pageVideoURL = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            state.estimatedProgress = 1
            state.title = webView.title ?? ""
            state.currentURL = webView.url
            state.canGoBack = webView.canGoBack
            extractPlayableVideoURL(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            state.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            state.canGoBack = webView.canGoBack
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func extractPlayableVideoURL(from webView: WKWebView) {
            guard let url = webView.url,
                  WebLinkContextResolver.isDouyinURL(url) || WebLinkContextResolver.isXiaohongshuURL(url) else { return }
            let script = """
            (() => {
              const urls = [];
              const push = value => {
                if (typeof value === 'string' && /^https?:\\/\\//i.test(value)) urls.push(value);
              };
              document.querySelectorAll('video, source').forEach(el => {
                push(el.currentSrc);
                push(el.src);
              });
              document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[name="twitter:player:stream"]').forEach(el => {
                push(el.content);
              });
              return urls.find(u => /\\.mp4|aweme\\/v1\\/play|sns-video|xhs-video|video/i.test(u)) || urls[0] || '';
            })();
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let raw = result as? String,
                      let videoURL = URL(string: raw),
                      ["http", "https"].contains(videoURL.scheme?.lowercased() ?? "") else {
                    return
                }
                self?.state.pageVideoURL = videoURL
            }
        }
    }
}
