import SwiftUI
import WebKit
import AVKit

struct WebPreviewURL: Identifiable, Equatable {
    let url: URL

    var id: String { url.absoluteString }
}

struct InAppWebPreviewSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var state = InAppWebPreviewState()
    @State private var resolvedDouyinVideo: ResolvedWebVideo?
    @State private var isResolvingDouyin = false
    @State private var isDownloadingDouyin = false
    @State private var douyinErrorMessage: String?
    @State private var playingVideo: WebPreviewVideoItem?
    @State private var downloadedVideoURL: WebPreviewDownloadedFile?
    @State private var resolvedDouyinSourceID = ""

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
            await resolveDouyinIfNeeded()
        }
        .onChange(of: state.pageVideoURL) { _, _ in
            if resolvedDouyinVideo == nil {
                douyinErrorMessage = nil
            }
        }
        .onChange(of: activeURL) { _, newURL in
            guard !WebLinkContextResolver.isDouyinURL(newURL) else { return }
            resolvedDouyinVideo = nil
            resolvedDouyinSourceID = ""
            douyinErrorMessage = nil
        }
        .sheet(item: $playingVideo) { item in
            WebPreviewVideoPlayerSheet(url: item.url)
        }
        .sheet(item: $downloadedVideoURL) { item in
            ShareSheetView(activityItems: [item.url])
        }
        .alert("抖音解析失败", isPresented: Binding(
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
        guard WebLinkContextResolver.isDouyinURL(activeURL) else { return "" }
        return activeURL.absoluteString
    }

    private var shouldShowDouyinControls: Bool {
        WebLinkContextResolver.isDouyinURL(activeURL)
            || resolvedDouyinVideo != nil
            || state.pageVideoURL != nil
    }

    private var playableVideoURL: URL? {
        if let raw = resolvedDouyinVideo?.url, let url = URL(string: raw) {
            return url
        }
        return state.pageVideoURL
    }

    private var douyinControlBar: some View {
        HStack(spacing: 10) {
            Image(systemName: playableVideoURL == nil ? "link.badge.plus" : "play.rectangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(playableVideoURL == nil ? theme.textSecondary : theme.brandPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedDouyinVideo?.title ?? "抖音视频")
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
                    Task { await resolveDouyinIfNeeded(force: true) }
                    return
                }
                playingVideo = WebPreviewVideoItem(url: url)
            } label: {
                Image(systemName: playableVideoURL == nil ? "arrow.clockwise" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isResolvingDouyin)

            Button {
                Task { await downloadDouyinVideo() }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(playableVideoURL == nil || isDownloadingDouyin)
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
        return "打开抖音链接后自动解析"
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
            let video = try await WebLinkContextResolver().resolveDouyinVideo(activeURL)
            resolvedDouyinVideo = video
            resolvedDouyinSourceID = sourceID
            douyinErrorMessage = nil
        } catch {
            if force, state.pageVideoURL == nil {
                douyinErrorMessage = "当前页面没有解析到可播放视频地址。你可以先让页面加载完成，再点刷新解析。"
            }
        }
    }

    @MainActor
    private func downloadDouyinVideo() async {
        guard let videoURL = playableVideoURL else { return }
        guard !isDownloadingDouyin else { return }

        isDownloadingDouyin = true
        defer { isDownloadingDouyin = false }

        do {
            var request = URLRequest(url: videoURL, timeoutInterval: 300)
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue(activeURL.absoluteString, forHTTPHeaderField: "Referer")
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(downloadFileName(response: response, url: videoURL))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            downloadedVideoURL = WebPreviewDownloadedFile(url: destination)
        } catch {
            douyinErrorMessage = "下载失败：\(error.localizedDescription)"
        }
    }

    private func downloadFileName(response: URLResponse, url: URL) -> String {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           let filename = filenameFromContentDisposition(disposition) {
            return filename
        }

        let title = resolvedDouyinVideo?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title.lowercased().hasSuffix(".mp4") ? title : "\(title).mp4"
        }

        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last != "/" {
            return (last as NSString).pathExtension.isEmpty ? "\(last).mp4" : last
        }
        return "douyin-video.mp4"
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

    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
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

private struct WebPreviewDownloadedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct WebPreviewVideoPlayerSheet: View {
    let url: URL

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
            let player = AVPlayer(url: url)
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
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
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
            guard let url = webView.url, WebLinkContextResolver.isDouyinURL(url) else { return }
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
              return urls.find(u => /\\.mp4|aweme\\/v1\\/play|video/i.test(u)) || urls[0] || '';
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
