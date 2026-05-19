import Foundation
import SwiftUI
import UIKit
import WebKit

// MARK: - Code Web Renderer

/// Renders fenced code through the same browser semantics used by web chat UIs:
/// markdown-it identifies the fence, highlight.js colors tokens, and CSS keeps
/// the underlying `<pre><code>` text as literal source with horizontal scrolling.
struct CodeWebRendererView: View {
    let code: String
    let language: String
    var maxHeight: CGFloat = 420
    var autoFollowTail: Bool = false

    @Environment(\.theme) private var theme
    @State private var contentHeight: CGFloat = 72

    private var displayCode: String {
        code.isEmpty ? " " : code
    }

    private var normalizedLanguage: String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.normalizedLanguage(value)
    }

    private static func normalizedLanguage(_ language: String) -> String {
        switch language.lowercased() {
        case "py", "python3":
            return "python"
        case "js", "mjs", "cjs":
            return "javascript"
        case "ts":
            return "typescript"
        case "sh", "shell", "zsh", "fish":
            return "bash"
        case "txt", "":
            return "text"
        default:
            return language
        }
    }

    private var frameHeight: CGFloat {
        let capped = maxHeight.isFinite ? min(maxHeight, contentHeight) : contentHeight
        return max(56, capped)
    }

    var body: some View {
        CodeWebViewRepresentable(
            code: displayCode,
            language: normalizedLanguage,
            isDarkMode: theme.isDark,
            textColor: UIColor(theme.codeText),
            autoFollowTail: autoFollowTail,
            maxHeight: maxHeight,
            contentHeight: $contentHeight
        )
        .frame(height: frameHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .onChange(of: displayCode) { _ in
            contentHeight = 72
        }
    }
}

private struct CodeWebViewRepresentable: UIViewRepresentable {
    let code: String
    let language: String
    let isDarkMode: Bool
    let textColor: UIColor
    let autoFollowTail: Bool
    let maxHeight: CGFloat
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "heightHandler")

        let config = WKWebViewConfiguration()
        config.userContentController = userController
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceHorizontal = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.showsHorizontalScrollIndicator = true
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.currentWebView = webView
        context.coordinator.lastCode = code
        context.coordinator.lastLanguage = language
        context.coordinator.lastIsDarkMode = isDarkMode
        context.coordinator.lastTextColor = textColor
        context.coordinator.lastAutoFollowTail = autoFollowTail
        context.coordinator.lastMaxHeight = normalizedMaxHeight

        webView.loadHTMLString(
            Self.shellHTML(
                code: code,
                language: language,
                isDarkMode: isDarkMode,
                textColor: textColor,
                autoFollowTail: autoFollowTail
            ),
            baseURL: URL(string: "https://localhost")
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceHorizontal = true
        webView.scrollView.showsHorizontalScrollIndicator = true

        let coordinator = context.coordinator
        let nextMaxHeight = normalizedMaxHeight
        let changed = coordinator.lastCode != code
            || coordinator.lastLanguage != language
            || coordinator.lastIsDarkMode != isDarkMode
            || !coordinator.lastTextColor.isEqual(textColor)
            || coordinator.lastAutoFollowTail != autoFollowTail
            || coordinator.lastMaxHeight != nextMaxHeight
        guard changed else { return }

        coordinator.lastCode = code
        coordinator.lastLanguage = language
        coordinator.lastIsDarkMode = isDarkMode
        coordinator.lastTextColor = textColor
        coordinator.lastAutoFollowTail = autoFollowTail
        coordinator.lastMaxHeight = nextMaxHeight

        guard coordinator.shellLoaded else {
            coordinator.pendingRender = RenderPayload(
                code: code,
                language: language,
                isDarkMode: isDarkMode,
                textColor: textColor,
                autoFollowTail: autoFollowTail
            )
            return
        }
        webView.evaluateJavaScript(
            Self.renderCall(
                code: code,
                language: language,
                isDarkMode: isDarkMode,
                textColor: textColor,
                autoFollowTail: autoFollowTail
            ),
            completionHandler: nil
        )
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "heightHandler")
        uiView.navigationDelegate = nil
    }

    private var normalizedMaxHeight: CGFloat {
        maxHeight.isFinite ? maxHeight : -1
    }

    private static func shellHTML(
        code: String,
        language: String,
        isDarkMode: Bool,
        textColor: UIColor,
        autoFollowTail: Bool
    ) -> String {
        let markdownIt = bundledScript(named: "code-renderer-markdown-it.min") ?? ""
        let highlight = bundledScript(named: "code-renderer-highlight.min") ?? ""
        let initialCall = renderCall(
            code: code,
            language: language,
            isDarkMode: isDarkMode,
            textColor: textColor,
            autoFollowTail: autoFollowTail
        )

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
          <style>
            :root {
              color-scheme: light dark;
              --code-text: \(cssRGBA(textColor));
              --plain: \(isDarkMode ? "#d7dde7" : "#111318");
              --keyword: \(isDarkMode ? "#ff7ad9" : "#b000b8");
              --string: \(isDarkMode ? "#ffb86b" : "#9f2626");
              --number: \(isDarkMode ? "#a3e635" : "#147d64");
              --comment: \(isDarkMode ? "#8a958f" : "#6b7280");
              --function: \(isDarkMode ? "#7dd3fc" : "#7a5b1d");
              --type: \(isDarkMode ? "#5eead4" : "#247d91");
            }
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              color: var(--code-text);
              overflow-x: auto;
              overflow-y: auto;
              -webkit-text-size-adjust: 100%;
              -webkit-overflow-scrolling: touch;
            }
            body {
              min-width: 100%;
            }
            #root {
              min-width: 100%;
            }
            pre, code {
              font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
              font-size: 13px;
              line-height: 1.62;
              letter-spacing: 0;
              tab-size: 4;
              -moz-tab-size: 4;
            }
            pre {
              box-sizing: border-box;
              margin: 0;
              padding: 14px 16px;
              min-width: 100%;
              width: max-content;
              max-width: none;
              background: transparent;
              white-space: pre !important;
              overflow: visible;
              word-break: normal !important;
              overflow-wrap: normal !important;
            }
            pre code {
              display: block;
              min-width: max-content;
              white-space: pre !important;
              word-break: normal !important;
              overflow-wrap: normal !important;
              color: var(--plain);
            }
            .hljs { color: var(--plain); background: transparent; }
            .hljs-keyword, .hljs-selector-tag, .hljs-built_in { color: var(--keyword); font-weight: 700; }
            .hljs-string, .hljs-attr, .hljs-symbol, .hljs-template-variable { color: var(--string); }
            .hljs-number, .hljs-literal { color: var(--number); }
            .hljs-comment, .hljs-quote { color: var(--comment); }
            .hljs-title, .hljs-title.function_, .hljs-function .hljs-title { color: var(--function); }
            .hljs-title.class_, .hljs-type, .hljs-class .hljs-title { color: var(--type); }
          </style>
          <script>
          \(markdownIt)
          </script>
          <script>
          \(highlight)
          </script>
        </head>
        <body>
          <div id="root"></div>
          <script>
            function escapeHtml(value) {
              return String(value)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
            }
            const md = window.markdownit ? window.markdownit({
              html: false,
              linkify: false,
              typographer: false,
              breaks: false,
              highlight: function(source, lang) {
                const normalized = (lang || '').toLowerCase();
                if (window.hljs && normalized && window.hljs.getLanguage(normalized)) {
                  try {
                    return window.hljs.highlight(source, { language: normalized, ignoreIllegals: true }).value;
                  } catch (error) {}
                }
                return escapeHtml(source);
              }
            }) : null;
            function fenceFor(source) {
              const matches = String(source).match(/`+/g) || [];
              const longest = matches.reduce((max, run) => Math.max(max, run.length), 0);
              return '`'.repeat(Math.max(3, longest + 1));
            }
            function sanitizeInfo(language) {
              return String(language || 'text').replace(/[^A-Za-z0-9_+.#-]/g, '').trim() || 'text';
            }
            function reportHeight() {
              requestAnimationFrame(function() {
                const root = document.getElementById('root');
                const height = Math.max(
                  1,
                  root ? root.scrollHeight : 0,
                  document.body.scrollHeight,
                  document.documentElement.scrollHeight
                );
                window.webkit?.messageHandlers?.heightHandler?.postMessage(height);
              });
            }
            function renderCode(source, language, dark, color, autoFollow) {
              document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
              document.documentElement.style.setProperty('--code-text', color);
              const normalizedSource = String(source).replace(/\\r\\n/g, '\\n').replace(/\\r/g, '\\n');
              const info = sanitizeInfo(language);
              const fence = fenceFor(normalizedSource);
              const markdown = fence + info + '\\n' + normalizedSource + (normalizedSource.endsWith('\\n') ? '' : '\\n') + fence;
              const root = document.getElementById('root');
              if (md) {
                root.innerHTML = md.render(markdown);
              } else {
                root.innerHTML = '<pre><code>' + escapeHtml(normalizedSource) + '</code></pre>';
              }
              if (autoFollow) {
                requestAnimationFrame(function() {
                  window.scrollTo(window.scrollX, document.body.scrollHeight);
                });
              }
              reportHeight();
            }
            window.addEventListener('resize', reportHeight);
            \(initialCall);
          </script>
        </body>
        </html>
        """
    }

    private static func renderCall(
        code: String,
        language: String,
        isDarkMode: Bool,
        textColor: UIColor,
        autoFollowTail: Bool
    ) -> String {
        """
        renderCode(\(jsonLiteral(code)), \(jsonLiteral(language)), \(isDarkMode ? "true" : "false"), \(jsonLiteral(cssRGBA(textColor))), \(autoFollowTail ? "true" : "false"))
        """
    }

    private static func bundledScript(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return content
    }

    private static func jsonLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           var string = String(data: data, encoding: .utf8) {
            string = string.replacingOccurrences(
                of: "</script",
                with: "<\\/script",
                options: [.caseInsensitive]
            )
            string = string
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            return string
        }
        return "\"\""
    }

    private static func cssRGBA(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return "rgba(\(Int(red * 255)), \(Int(green * 255)), \(Int(blue * 255)), \(String(format: "%.3f", Double(alpha))))"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding var contentHeight: CGFloat
        weak var currentWebView: WKWebView?
        var shellLoaded = false
        var pendingRender: RenderPayload?
        var lastCode = ""
        var lastLanguage = ""
        var lastIsDarkMode = false
        var lastTextColor: UIColor = .clear
        var lastAutoFollowTail = false
        var lastMaxHeight: CGFloat = -1

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "heightHandler" else { return }
            let height: CGFloat
            if let value = message.body as? CGFloat, value > 0 {
                height = value
            } else if let value = message.body as? Double, value > 0 {
                height = CGFloat(value)
            } else if let value = message.body as? Int, value > 0 {
                height = CGFloat(value)
            } else {
                return
            }
            DispatchQueue.main.async {
                self.contentHeight = min(height, 12_000)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellLoaded = true
            guard let pendingRender else { return }
            self.pendingRender = nil
            webView.evaluateJavaScript(
                CodeWebViewRepresentable.renderCall(
                    code: pendingRender.code,
                    language: pendingRender.language,
                    isDarkMode: pendingRender.isDarkMode,
                    textColor: pendingRender.textColor,
                    autoFollowTail: pendingRender.autoFollowTail
                ),
                completionHandler: nil
            )
        }
    }

    struct RenderPayload {
        let code: String
        let language: String
        let isDarkMode: Bool
        let textColor: UIColor
        let autoFollowTail: Bool
    }
}
