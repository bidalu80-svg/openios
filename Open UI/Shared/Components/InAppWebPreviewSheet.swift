import SwiftUI
import WebKit

struct WebPreviewURL: Identifiable, Equatable {
    let url: URL

    var id: String { url.absoluteString }
}

struct InAppWebPreviewSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var state = InAppWebPreviewState()

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
    }

    private var hostLabel: String {
        guard var host = url.host, !host.isEmpty else { return "网页预览" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

@Observable
final class InAppWebPreviewState {
    var isLoading = true
    var estimatedProgress = 0.05
    var title = ""
    var currentURL: URL?
    var canGoBack = false
    @ObservationIgnored
    weak var webView: WKWebView?
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
    }
}
