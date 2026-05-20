import Foundation
import WebKit
import UIKit
import OSLog

@MainActor
final class BrowserWebSearchService: NSObject {
    static let shared = BrowserWebSearchService()

    private let logger = Logger(subsystem: "com.openui", category: "BrowserWebSearch")
    private let maxQueries = 4
    private let maxSearchItems = 10
    private let maxDocuments = 5
    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func search(queries: [String], originalQuery: String?) async -> WebSearchResponse {
        let normalizedQueries = queries
            .map(Self.normalizedQuery)
            .filter { !$0.isEmpty }
        guard !normalizedQueries.isEmpty else { return WebSearchResponse() }

        var collectedItems: [WebSearchResultItem] = []
        var seenLinks = Set<String>()

        for query in normalizedQueries.prefix(maxQueries) {
            let resultItems = await searchItems(for: query)
            for item in resultItems {
                guard let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !link.isEmpty,
                      seenLinks.insert(link.lowercased()).inserted else {
                    continue
                }
                collectedItems.append(item)
                if collectedItems.count >= maxSearchItems * 2 { break }
            }
            if collectedItems.count >= maxSearchItems * 2 { break }
        }

        let rankedItems = Array(Self.rank(collectedItems, query: originalQuery ?? normalizedQueries.first ?? "").prefix(maxSearchItems))
        var docs: [WebSearchDocument] = []
        var seenDocs = Set<String>()
        var loadedCount = 0
        for item in rankedItems {
            guard docs.count < maxDocuments,
                  let doc = await fetchDocument(for: item) else {
                continue
            }
            let key = (doc.metadata["source"] ?? doc.metadata["link"] ?? String(doc.content.prefix(160))).lowercased()
            guard seenDocs.insert(key).inserted else { continue }
            if doc.metadata["provider"] == "wkwebview_browser_page" {
                loadedCount += 1
            }
            docs.append(doc)
        }

        guard !rankedItems.isEmpty || !docs.isEmpty else { return WebSearchResponse() }
        let filenames = rankedItems.compactMap(\.link)
        return WebSearchResponse(
            status: true,
            collectionNames: ["browser_web_search"],
            filenames: filenames,
            items: rankedItems,
            docs: docs,
            loadedCount: loadedCount
        )
    }

    private func searchItems(for query: String) async -> [WebSearchResultItem] {
        var items: [WebSearchResultItem] = []
        var seenLinks = Set<String>()

        for (index, rawURL) in Self.searchURLs(for: query).enumerated() {
            guard let url = URL(string: rawURL),
                  await load(url: url, timeout: 14) else {
                continue
            }
            await settleLoadedPage(scroll: false)
            let pageItems = await evaluateSearchItems().filter { item in
                guard let link = item.link, let url = URL(string: link) else { return false }
                return !Self.isBlockedDocumentURL(url)
            }
            for item in pageItems {
                guard let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !link.isEmpty,
                      seenLinks.insert(link.lowercased()).inserted else {
                    continue
                }
                items.append(item)
                if items.count >= maxSearchItems * 2 { break }
            }
            if items.count >= maxSearchItems * 2 { break }
            if index >= 1 && items.count >= maxSearchItems { break }
        }
        return items
    }

    private static func searchURLs(for query: String) -> [String] {
        let encoded = Self.encodedSearchQuery(query)
        let timestamp = Int(Date().timeIntervalSince1970)
        let needsDayScope = searchNeedsFreshness(query)

        return [
            needsDayScope
                ? "https://www.bing.com/search?q=\(encoded)&setlang=zh-Hans&count=10&filters=ex1%3a%22ez1%22&_=\(timestamp)"
                : "https://www.bing.com/search?q=\(encoded)&setlang=zh-Hans&count=10&_=\(timestamp)",
            needsDayScope
                ? "https://duckduckgo.com/html/?q=\(encoded)&df=d"
                : "https://duckduckgo.com/html/?q=\(encoded)",
            needsDayScope
                ? "https://lite.duckduckgo.com/lite/?q=\(encoded)&df=d"
                : "https://lite.duckduckgo.com/lite/?q=\(encoded)",
            needsDayScope
                ? "https://www.google.com/search?q=\(encoded)&hl=zh-CN&num=10&tbs=qdr:d"
                : "https://www.google.com/search?q=\(encoded)&hl=zh-CN&num=10",
            "https://www.baidu.com/s?wd=\(encoded)&rn=10&ie=utf-8&_=\(timestamp)"
        ]
    }

    private static func encodedSearchQuery(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }

    private func fetchDocument(for item: WebSearchResultItem) async -> WebSearchDocument? {
        guard let rawLink = item.link,
              let url = URL(string: rawLink),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !Self.isBlockedDocumentURL(url) else {
            return nil
        }

        guard await load(url: url, timeout: 16) else {
            return summaryDocument(for: item)
        }
        await settleLoadedPage(scroll: true)

        guard let snapshot = await evaluatePageSnapshot(),
              !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return summaryDocument(for: item)
        }

        var sections: [String] = []
        let title = snapshot.title.isEmpty ? (item.title ?? rawLink) : snapshot.title
        sections.append("Title: \(title)")
        sections.append("URL: \(snapshot.url.isEmpty ? rawLink : snapshot.url)")
        if !snapshot.description.isEmpty {
            sections.append("Description: \(snapshot.description)")
        } else if let snippet = item.snippet, !snippet.isEmpty {
            sections.append("Search snippet: \(snippet)")
        }
        if !snapshot.published.isEmpty {
            sections.append("Published/Updated: \(snapshot.published)")
        }
        sections.append("Content excerpt:\n\(String(snapshot.text.prefix(5_000)))")

        var metadata = [
            "title": title,
            "source": snapshot.url.isEmpty ? rawLink : snapshot.url,
            "link": snapshot.url.isEmpty ? rawLink : snapshot.url,
            "provider": "wkwebview_browser_page",
            "searched_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let snippet = item.snippet, !snippet.isEmpty {
            metadata["search_snippet"] = snippet
        }
        if !snapshot.published.isEmpty {
            metadata["published_time"] = snapshot.published
        }
        return WebSearchDocument(content: sections.joined(separator: "\n"), metadata: metadata)
    }

    private func summaryDocument(for item: WebSearchResultItem) -> WebSearchDocument? {
        var lines: [String] = []
        if let title = item.title, !title.isEmpty { lines.append("Title: \(title)") }
        if let link = item.link, !link.isEmpty { lines.append("URL: \(link)") }
        if let snippet = item.snippet, !snippet.isEmpty { lines.append("Search snippet: \(snippet)") }
        guard !lines.isEmpty else { return nil }
        return WebSearchDocument(
            content: lines.joined(separator: "\n"),
            metadata: [
                "title": item.title ?? item.link ?? "Search result",
                "source": item.link ?? "",
                "link": item.link ?? "",
                "provider": "wkwebview_browser_summary",
                "searched_at": ISO8601DateFormatter().string(from: Date())
            ]
        )
    }

    private func load(url: URL, timeout: TimeInterval) async -> Bool {
        let wv = webViewReady()
        timeoutTask?.cancel()
        navigationContinuation?.resume(returning: false)
        navigationContinuation = nil

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        return await withCheckedContinuation { continuation in
            navigationContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.logger.warning("Browser search navigation timed out: \(url.absoluteString, privacy: .public)")
                self.resolveNavigation(false)
            }
            wv.load(request)
        }
    }

    private func webViewReady() -> WKWebView {
        if let webView { return webView }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        wv.isHidden = true
        wv.navigationDelegate = self
        webView = wv
        attachToWindow(wv)
        return wv
    }

    private func attachToWindow(_ webView: WKWebView) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        window?.addSubview(webView)
        window?.sendSubviewToBack(webView)
    }

    private func resolveNavigation(_ success: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = navigationContinuation
        navigationContinuation = nil
        continuation?.resume(returning: success)
    }

    private func settleLoadedPage(scroll: Bool) async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard scroll else { return }
        _ = await evaluateString(
            """
            (() => {
              try {
                const height = Math.max(
                  document.body && document.body.scrollHeight || 0,
                  document.documentElement && document.documentElement.scrollHeight || 0
                );
                window.scrollTo(0, Math.min(height, 1800));
              } catch (_) {}
              return "ok";
            })();
            """
        )
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func evaluateSearchItems() async -> [WebSearchResultItem] {
        let script = """
        (() => {
          const blockedHosts = new Set([
            'duckduckgo.com', 'www.duckduckgo.com', 'lite.duckduckgo.com',
            'bing.com', 'www.bing.com', 'cn.bing.com',
            'google.com', 'www.google.com',
            'baidu.com', 'www.baidu.com'
          ]);
          function text(node) {
            return (node && node.innerText || node && node.textContent || '').replace(/\\s+/g, ' ').trim();
          }
          function absolutize(raw) {
            try {
              if (!raw) return '';
              const url = new URL(raw, location.href);
              if (url.hostname.endsWith('duckduckgo.com') && url.pathname.startsWith('/l/')) {
                const uddg = url.searchParams.get('uddg');
                if (uddg) return decodeURIComponent(uddg);
              }
              if ((url.hostname.includes('bing.com') || url.hostname.includes('google.com')) && (url.pathname === '/url' || url.pathname === '/ck/a' || url.pathname === '/link')) {
                let q = url.searchParams.get('q') || url.searchParams.get('url') || url.searchParams.get('u');
                if (q && q.startsWith('/url?')) {
                  q = new URL(q, location.href).searchParams.get('q');
                }
                if (q && /^https?:/i.test(q)) return q;
                const wrapped = url.searchParams.get('r') || url.searchParams.get('RU');
                if (wrapped && /^https?:/i.test(wrapped)) return wrapped;
              }
              if (url.hostname.includes('bing.com') && url.pathname === '/aclick') {
                const q = url.searchParams.get('u') || url.searchParams.get('url');
                if (q && /^https?:/i.test(q)) return q;
              }
              if (url.hostname.endsWith('baidu.com')) {
                const q = url.searchParams.get('url') || url.searchParams.get('target') || url.searchParams.get('wd');
                if (q && /^https?:/i.test(q)) return q;
                return '';
              }
              return url.href;
            } catch (_) {
              return '';
            }
          }
          function blocked(raw) {
            try {
              const url = new URL(raw);
              if (!/^https?:$/.test(url.protocol)) return true;
              if (url.hostname.endsWith('baidu.com')) return true;
              if (blockedHosts.has(url.hostname) && ['/search', '/html/', '/lite/', '/', '/s', '/link', '/url', '/ck/a', '/aclick'].includes(url.pathname)) return true;
              return /\\.(jpg|jpeg|png|gif|webp|avif|svg|mp4|mov|mp3|zip|rar|7z|ipa|apk|dmg|pdf)(\\?|$)/i.test(url.pathname);
            } catch (_) {
              return true;
            }
          }
          function nearestResult(anchor) {
            return anchor.closest(
              '.b_algo, .result, .results_links, .c-container, .result-op, .g, div[data-sokoban-container], article, tr, li, section'
            ) || anchor;
          }
          const candidates = [];
          const selectors = [
            'li.b_algo',
            '.b_ans',
            '.result',
            '.c-container',
            '.result-op',
            '.results_links',
            '.web-result',
            '.g',
            'article',
            '[data-testid="result"]',
            'tr',
            'a.result__a',
            'a.result-link',
            'h2 a',
            'h3 a'
          ];
          for (const selector of selectors) {
            for (const node of document.querySelectorAll(selector)) {
              let anchor = node.matches && node.matches('a[href]') ? node : node.querySelector && node.querySelector('a[href]');
              if (!anchor) continue;
              const link = absolutize(anchor.getAttribute('href') || anchor.href);
              if (!link || blocked(link)) continue;
              const title = text(anchor) || text(node.querySelector && node.querySelector('h2,h3')) || link;
              const snippetNode = node.querySelector && node.querySelector([
                '.result__snippet',
                '.result-snippet',
                '.b_caption p',
                '.b_snippet',
                '.c-abstract',
                '.content-right',
                '.c-span-last',
                '.cos-color-text',
                '.VwiC3b',
                '.IsZvec',
                '.st',
                '.snippet',
                '.content',
                'td.result-snippet',
                'p'
              ].join(', '));
              const dateNode = node.querySelector && node.querySelector('time, .news_dt, .c-color-gray2, .result__timestamp, .b_factrow, .MUxGbd.wuQ4Ob.WZ8Tjf, [aria-label*="Published"], [aria-label*="Updated"]');
              const dateText = text(dateNode);
              const snippet = [dateText, text(snippetNode)].filter(Boolean).join(' - ');
              candidates.push({ title, link, snippet });
            }
          }
          for (const anchor of document.querySelectorAll('a[href]')) {
            const link = absolutize(anchor.getAttribute('href') || anchor.href);
            const title = text(anchor);
            if (!link || !title || title.length < 3 || blocked(link)) continue;
            const node = nearestResult(anchor);
            const whole = text(node);
            let snippet = whole.replace(title, '').replace(/\\s+/g, ' ').trim();
            if (snippet.length > 420) snippet = snippet.slice(0, 420);
            candidates.push({ title, link, snippet });
          }
          const out = [];
          const seen = new Set();
          for (const item of candidates) {
            const key = item.link.toLowerCase();
            if (seen.has(key)) continue;
            if ((item.title || '').length > 180) item.title = item.title.slice(0, 180);
            if ((item.snippet || '').length > 700) item.snippet = item.snippet.slice(0, 700);
            seen.add(key);
            out.push(item);
            if (out.length >= 12) break;
          }
          return JSON.stringify(out);
        })();
        """

        guard let json = await evaluateString(script),
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return values.compactMap(WebSearchResultItem.init(json:))
    }

    private func evaluatePageSnapshot() async -> BrowserPageSnapshot? {
        let script = """
        (() => {
          function clean(value) {
            return (value || '').replace(/\\s+/g, ' ').trim();
          }
          function contentText(node) {
            if (!node) return '';
            let value = node.innerText || node.textContent || '';
            value = value.replace(/\\r/g, '\\n').replace(/[ \\t\\u00a0]+/g, ' ');
            value = value.split('\\n').map(line => line.trim()).filter(line => {
              if (line.length < 2) return false;
              const lowered = line.toLowerCase();
              if (['javascript', 'cookie', 'cookies', 'privacy policy', 'terms of use'].includes(lowered)) return false;
              if (/^(share|subscribe|login|sign in|advertisement|广告)$/.test(lowered)) return false;
              return true;
            }).join('\\n');
            return value.replace(/\\n{3,}/g, '\\n\\n').trim();
          }
          function removeNoise(root) {
            root.querySelectorAll([
              'script',
              'style',
              'noscript',
              'svg',
              'canvas',
              'iframe',
              'nav',
              'footer',
              'header',
              'aside',
              'form',
              'button',
              'input',
              'select',
              'textarea',
              '[role="navigation"]',
              '[role="banner"]',
              '[role="contentinfo"]',
              '[aria-label*="cookie" i]',
              '[class*="cookie" i]',
              '[class*="advert" i]',
              '[id*="advert" i]'
            ].join(',')).forEach(n => n.remove());
          }
          const clone = document.body ? document.body.cloneNode(true) : document.documentElement.cloneNode(true);
          removeNoise(clone);
          const main = clone.querySelector([
            'article',
            'main',
            '[role="main"]',
            '.article',
            '.post',
            '.entry-content',
            '.article-content',
            '.content',
            '#content'
          ].join(',')) || clone;
          const title = clean(document.title || document.querySelector('h1')?.innerText || '');
          const desc = clean(
            document.querySelector('meta[name="description"]')?.content ||
            document.querySelector('meta[property="og:description"]')?.content ||
            document.querySelector('meta[name="twitter:description"]')?.content ||
            ''
          );
          const published = clean(
            document.querySelector('meta[property="article:published_time"]')?.content ||
            document.querySelector('meta[property="article:modified_time"]')?.content ||
            document.querySelector('meta[name="date"]')?.content ||
            document.querySelector('meta[name="pubdate"]')?.content ||
            document.querySelector('meta[name="publishdate"]')?.content ||
            document.querySelector('meta[name="lastmod"]')?.content ||
            document.querySelector('meta[itemprop="datePublished"]')?.content ||
            document.querySelector('meta[itemprop="dateModified"]')?.content ||
            document.querySelector('[itemprop="datePublished"]')?.getAttribute('content') ||
            document.querySelector('[itemprop="dateModified"]')?.getAttribute('content') ||
            document.querySelector('time[datetime]')?.getAttribute('datetime') ||
            document.querySelector('time')?.innerText ||
            ''
          );
          let text = contentText(main);
          if (text.length < 600 && clone !== main) {
            const fallback = contentText(clone);
            if (fallback.length > text.length) text = fallback;
          }
          return JSON.stringify({ title, url: location.href, description: desc, published, text: text.slice(0, 12000) });
        })();
        """
        guard let json = await evaluateString(script),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return BrowserPageSnapshot(
            title: object["title"] as? String ?? "",
            url: object["url"] as? String ?? "",
            description: object["description"] as? String ?? "",
            published: object["published"] as? String ?? "",
            text: object["text"] as? String ?? ""
        )
    }

    private func evaluateString(_ script: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    self.logger.debug("Browser search JS failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result as? String)
            }
        }
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchNeedsFreshness(_ query: String) -> Bool {
        let normalized = query
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "今天", "今日", "24小时", "一天内", "当天",
            "today", "last24hours", "past24hours"
        ].contains { normalized.contains($0) }
    }

    private static func rank(_ items: [WebSearchResultItem], query: String) -> [WebSearchResultItem] {
        let normalized = Self.normalizedQuery(query).lowercased()
        var terms = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        if containsCJK(normalized), !terms.contains(normalized) {
            terms.append(normalized)
        }

        func score(_ item: WebSearchResultItem) -> Int {
            let title = (item.title ?? "").lowercased()
            let snippet = (item.snippet ?? "").lowercased()
            let link = (item.link ?? "").lowercased()
            let haystack = "\(title) \(snippet) \(link)"
            var value = 0
            for term in terms where haystack.contains(term) {
                value += title.contains(term) ? 8 : 0
                value += snippet.contains(term) ? 4 : 0
                value += link.contains(term) ? 2 : 0
            }
            if let url = item.link.flatMap(URL.init(string:)),
               !isBlockedDocumentURL(url) {
                value += 6
            }
            if (item.snippet ?? "").count > 40 {
                value += 2
            }
            return value
        }

        return items.enumerated().sorted { left, right in
            let leftScore = score(left.element)
            let rightScore = score(right.element)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
                || (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private static func isBlockedDocumentURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host == "baidu.com" || host.hasSuffix(".baidu.com") {
            return true
        }
        if ["duckduckgo.com", "www.duckduckgo.com", "lite.duckduckgo.com", "bing.com", "www.bing.com", "cn.bing.com", "google.com", "www.google.com"].contains(host),
           ["/search", "/html/", "/lite/", "/", "/s", "/link", "/url", "/ck/a", "/aclick"].contains(url.path.lowercased()) {
            return true
        }
        let path = url.path.lowercased()
        let blockedExt = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".mp4", ".mov", ".mp3", ".zip", ".rar", ".7z", ".ipa", ".apk", ".dmg", ".pdf"]
        return blockedExt.contains { path.hasSuffix($0) }
    }
}

extension BrowserWebSearchService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.resolveNavigation(true)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.resolveNavigation(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.resolveNavigation(false)
        }
    }
}

private struct BrowserPageSnapshot {
    let title: String
    let url: String
    let description: String
    let published: String
    let text: String
}
