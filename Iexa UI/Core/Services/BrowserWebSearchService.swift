import Foundation
import WebKit
import UIKit
import OSLog

@MainActor
final class BrowserWebSearchService: NSObject {
    static let shared = BrowserWebSearchService()

    private let logger = Logger(subsystem: "com.openui", category: "BrowserWebSearch")
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

        let githubSearchSeed = Self.githubSearchSeed(
            originalQuery: originalQuery,
            queries: normalizedQueries
        )
        let githubSearchTask = githubSearchSeed.map { seed in
            Task { await Self.githubRepositoryResults(for: seed) }
        }

        var items: [WebSearchResultItem] = []
        var seenLinks = Set<String>()

        for query in normalizedQueries.prefix(3) {
            let resultItems = await searchItems(for: query)
            for item in resultItems {
                guard let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !link.isEmpty,
                      seenLinks.insert(link.lowercased()).inserted else {
                    continue
                }
                items.append(item)
                if items.count >= 8 { break }
            }
            if items.count >= 8 { break }
        }

        if let githubItems = await githubSearchTask?.value, !githubItems.isEmpty {
            var githubCollected: [WebSearchResultItem] = []

            for item in githubItems {
                guard let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !link.isEmpty,
                      seenLinks.insert(link.lowercased()).inserted else {
                    continue
                }
                githubCollected.append(item)
                if githubCollected.count >= 8 { break }
            }

            if !githubCollected.isEmpty {
                items = Array((githubCollected + items).prefix(8))
            }
        }

        var docs = await fetchDocuments(for: Array(items.prefix(4)))
        var finalItems = Array(items.prefix(8))
        if let firstLink = finalItems.compactMap(\.link).first,
           let url = URL(string: firstLink),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           await load(url: url, timeout: 8) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            let snapshot = await evaluatePageSnapshot()
            let thumbnail = await capturePageThumbnail(prefix: "search")
            if let index = finalItems.firstIndex(where: { $0.link == firstLink }) {
                if let snapshot, finalItems[index].snippet?.isEmpty != false {
                    finalItems[index].snippet = String(snapshot.text.prefix(260))
                }
                if let thumbnail {
                    finalItems[index].thumbnailURL = thumbnail.absoluteString
                }
            }
            if let snapshot,
               !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !docs.contains(where: { ($0.metadata["source"] ?? $0.metadata["link"]) == firstLink }) {
                docs.insert(WebSearchDocument(
                    content: [
                        "Title: \(snapshot.title.isEmpty ? firstLink : snapshot.title)",
                        "URL: \(snapshot.url.isEmpty ? firstLink : snapshot.url)",
                        snapshot.description.isEmpty ? nil : "Description: \(snapshot.description)",
                        "Content excerpt:\n\(String(snapshot.text.prefix(4_000)))"
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                    metadata: [
                        "title": snapshot.title.isEmpty ? firstLink : snapshot.title,
                        "source": snapshot.url.isEmpty ? firstLink : snapshot.url,
                        "link": snapshot.url.isEmpty ? firstLink : snapshot.url,
                        "provider": "wkwebview_browser_thumbnail"
                    ]
                ), at: 0)
            }
        }

        guard !items.isEmpty || !docs.isEmpty else { return WebSearchResponse() }
        let filenames = finalItems.compactMap(\.link)
        return WebSearchResponse(
            status: true,
            collectionNames: ["browser_web_search"],
            filenames: filenames,
            items: finalItems,
            docs: docs,
            loadedCount: docs.count
        )
    }

    func executeNativeBrowserTool(action rawAction: String, call: [String: Any]) async -> [String: Any] {
        let action = rawAction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch action {
        case "web.search", "web_search", "search_web", "browser.search", "browser_search":
            return await executeNativeSearch(call)
        case "browser.open", "browser.navigate", "browser_open", "browser.navigate_url", "navigate":
            return await executeNativeOpen(call, readable: true)
        case "browser.readable", "browser.get_readable", "browser_readable", "get_readable", "read_webpage":
            return await executeNativeOpen(call, readable: true)
        case "browser.text", "browser.get_text", "browser_text", "get_text":
            return await executeNativeText(call)
        case "browser.info", "browser.get_page_info", "browser_info", "get_page_info":
            return await executeNativePageInfo(call)
        case "browser.screenshot", "browser_screenshot", "screenshot":
            return await executeNativeScreenshot(call)
        case "browser.fetch", "browser_fetch", "fetch":
            return await executeNativeFetch(call)
        default:
            return [
                "action": rawAction,
                "ok": false,
                "error": "Unsupported browser action"
            ]
        }
    }

    private func executeNativeSearch(_ call: [String: Any]) async -> [String: Any] {
        let query = Self.firstString(in: call, keys: ["query", "q", "text", "keyword", "keywords"])
        guard let query, !query.isEmpty else {
            return [
                "action": "web.search",
                "ok": false,
                "error": "Missing required field: query"
            ]
        }

        let extraQueries = Self.stringArray(in: call, keys: ["queries", "search_queries"])
        let limit = min(max(Self.intValue(call["limit"] ?? call["count"] ?? call["max_results"]) ?? 6, 1), 8)
        let includeScreenshot = Self.boolValue(call["screenshot"] ?? call["with_screenshot"] ?? call["thumbnail"]) ?? true
        let queries = Self.unique(([query] + extraQueries).map(Self.normalizedQuery))
        let response = await search(queries: Array(queries.prefix(4)), originalQuery: query)

        var itemsPayload = response.items.prefix(limit).map(Self.itemPayload(from:))
        var docsPayload = response.docs.prefix(4).map(Self.documentPayload(from:))
        var previewImages: [String] = []

        if includeScreenshot,
           let existingThumbnail = itemsPayload.compactMap({ $0["thumbnail_url"] as? String }).first {
            previewImages.append(existingThumbnail)
        } else if includeScreenshot,
           let firstLink = response.items.compactMap(\.link).first,
           let url = URL(string: firstLink),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           await load(url: url, timeout: 10) {
            try? await Task.sleep(nanoseconds: 550_000_000)
            let snapshot = await evaluatePageSnapshot()
            let thumbnail = await capturePageThumbnail(prefix: "search")
            if let thumbnail {
                previewImages.append(thumbnail.absoluteString)
            }
            if !itemsPayload.isEmpty {
                let currentSnippet = itemsPayload[0]["snippet"] as? String
                if let snapshot, currentSnippet?.isEmpty != false {
                    itemsPayload[0]["snippet"] = String(snapshot.text.prefix(260))
                }
                if let thumbnail {
                    itemsPayload[0]["thumbnail_url"] = thumbnail.absoluteString
                }
            }
            if let snapshot, !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let doc = WebSearchDocument(
                    content: [
                        "Title: \(snapshot.title.isEmpty ? firstLink : snapshot.title)",
                        "URL: \(snapshot.url.isEmpty ? firstLink : snapshot.url)",
                        snapshot.description.isEmpty ? nil : "Description: \(snapshot.description)",
                        "Content excerpt:\n\(String(snapshot.text.prefix(4_000)))"
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                    metadata: [
                        "title": snapshot.title.isEmpty ? firstLink : snapshot.title,
                        "source": snapshot.url.isEmpty ? firstLink : snapshot.url,
                        "link": snapshot.url.isEmpty ? firstLink : snapshot.url,
                        "provider": "wkwebview_browser_tool"
                    ]
                )
                docsPayload.insert(Self.documentPayload(from: doc), at: 0)
            }
        }

        return [
            "action": "web.search",
            "ok": !response.items.isEmpty || !response.docs.isEmpty,
            "query": query,
            "queries": queries,
            "count": itemsPayload.count,
            "items": itemsPayload,
            "docs": Array(docsPayload.prefix(4)),
            "preview_images": previewImages,
            "summary": itemsPayload.isEmpty ? "未找到可用搜索结果。" : "已搜索 \(itemsPayload.count) 个网页来源。"
        ]
    }

    private func executeNativeOpen(_ call: [String: Any], readable: Bool) async -> [String: Any] {
        guard let url = Self.urlValue(in: call) else {
            return [
                "action": readable ? "browser.readable" : "browser.open",
                "ok": false,
                "error": "Missing required field: url"
            ]
        }

        let timeout = TimeInterval(Self.intValue(call["timeout"] ?? call["timeout_seconds"]) ?? 14)
        guard await load(url: url, timeout: min(max(timeout, 3), 30)) else {
            return [
                "action": readable ? "browser.readable" : "browser.open",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 650_000_000)

        let maxLength = min(max(Self.intValue(call["max_length"] ?? call["limit"]) ?? 8_000, 800), 18_000)
        let includeScreenshot = Self.boolValue(call["screenshot"] ?? call["with_screenshot"] ?? call["thumbnail"]) ?? true
        let snapshot = await evaluatePageSnapshot()
        let thumbnail = includeScreenshot ? await capturePageThumbnail(prefix: "browser") : nil
        let title = snapshot?.title.isEmpty == false ? snapshot!.title : (url.host ?? url.absoluteString)
        let finalURL = snapshot?.url.isEmpty == false ? snapshot!.url : url.absoluteString
        let text = snapshot?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var payload: [String: Any] = [
            "action": readable ? "browser.readable" : "browser.open",
            "ok": true,
            "title": title,
            "url": finalURL,
            "description": snapshot?.description ?? "",
            "text": String(text.prefix(maxLength)),
            "text_truncated": text.count > maxLength,
            "summary": text.isEmpty ? "已打开网页：\(title)" : "已打开并读取网页：\(title)"
        ]
        if let thumbnail {
            payload["preview_images"] = [thumbnail.absoluteString]
            payload["items"] = [[
                "title": title,
                "link": finalURL,
                "snippet": String(text.prefix(260)),
                "thumbnail_url": thumbnail.absoluteString
            ]]
        } else {
            payload["items"] = [[
                "title": title,
                "link": finalURL,
                "snippet": String(text.prefix(260))
            ]]
        }
        return payload
    }

    private func executeNativeText(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !await load(url: url, timeout: 12) {
            return [
                "action": "browser.text",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 350_000_000)

        let selector = Self.firstString(in: call, keys: ["selector", "css"])
        let maxLength = min(max(Self.intValue(call["max_length"] ?? call["limit"]) ?? 8_000, 500), 18_000)
        let script: String
        if let selector, !selector.isEmpty {
            script = """
            (() => {
              const node = document.querySelector(\(Self.javascriptString(selector)));
              return JSON.stringify({
                title: document.title || '',
                url: location.href,
                text: ((node && (node.innerText || node.textContent)) || '').slice(0, \(maxLength))
              });
            })();
            """
        } else {
            script = """
            (() => JSON.stringify({
              title: document.title || '',
              url: location.href,
              text: ((document.body && document.body.innerText) || '').slice(0, \(maxLength))
            }))();
            """
        }

        guard let json = await evaluateString(script),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "action": "browser.text",
                "ok": false,
                "error": "Unable to read page text"
            ]
        }
        return [
            "action": "browser.text",
            "ok": true,
            "title": object["title"] as? String ?? "",
            "url": object["url"] as? String ?? "",
            "selector": selector ?? "",
            "text": object["text"] as? String ?? "",
            "summary": "已读取网页文本。"
        ]
    }

    private func executeNativePageInfo(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !await load(url: url, timeout: 12) {
            return [
                "action": "browser.info",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 350_000_000)

        let script = """
        (() => {
          const text = n => ((n && (n.innerText || n.textContent)) || '').replace(/\\s+/g, ' ').trim();
          const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 30).map(a => ({
            text: text(a).slice(0, 120),
            href: new URL(a.getAttribute('href'), location.href).href
          }));
          const forms = Array.from(document.forms).slice(0, 10).map(f => ({
            action: f.action || '',
            method: f.method || 'get',
            inputs: Array.from(f.querySelectorAll('input, textarea, select')).slice(0, 20).map(i => ({
              name: i.name || '',
              type: i.type || i.tagName.toLowerCase(),
              placeholder: i.placeholder || ''
            }))
          }));
          return JSON.stringify({
            title: document.title || '',
            url: location.href,
            readyState: document.readyState,
            scrollY: Math.round(scrollY),
            viewport: { width: innerWidth, height: innerHeight },
            page: { width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight },
            links,
            forms
          });
        })();
        """
        guard let json = await evaluateString(script),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "action": "browser.info",
                "ok": false,
                "error": "Unable to inspect page"
            ]
        }
        var payload = object
        payload["action"] = "browser.info"
        payload["ok"] = true
        payload["summary"] = "已读取网页结构。"
        return payload
    }

    private func executeNativeScreenshot(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !await load(url: url, timeout: 14) {
            return [
                "action": "browser.screenshot",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 650_000_000)

        guard let screenshot = await capturePageThumbnail(prefix: "browser") else {
            return [
                "action": "browser.screenshot",
                "ok": false,
                "error": "Failed to capture webpage screenshot"
            ]
        }
        let snapshot = await evaluatePageSnapshot()
        let title = snapshot?.title.isEmpty == false ? snapshot!.title : "网页截图"
        let url = snapshot?.url ?? webView?.url?.absoluteString ?? ""
        return [
            "action": "browser.screenshot",
            "ok": true,
            "title": title,
            "url": url,
            "preview_images": [screenshot.absoluteString],
            "items": [[
                "title": title,
                "link": url,
                "snippet": snapshot.map { String($0.text.prefix(260)) } ?? "",
                "thumbnail_url": screenshot.absoluteString
            ]],
            "summary": "已生成网页截图。"
        ]
    }

    private func executeNativeFetch(_ call: [String: Any]) async -> [String: Any] {
        guard let url = Self.urlValue(in: call) else {
            return [
                "action": "browser.fetch",
                "ok": false,
                "error": "Missing required field: url"
            ]
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8,*;q=0.6", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return [
                    "action": "browser.fetch",
                    "ok": false,
                    "url": url.absoluteString,
                    "error": "Fetch failed"
                ]
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first ?? "application/octet-stream"
            let fileName = Self.fetchFileName(for: url, contentType: contentType, headers: http.allHeaderFields)
            let folder = try browserOutputDirectory()
            let fileURL = folder.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: [.atomic])
            return [
                "action": "browser.fetch",
                "ok": true,
                "url": url.absoluteString,
                "file_url": fileURL.absoluteString,
                "file_name": fileName,
                "content_type": contentType,
                "bytes": data.count,
                "summary": "已下载网页资源：\(fileName)"
            ]
        } catch {
            return [
                "action": "browser.fetch",
                "ok": false,
                "url": url.absoluteString,
                "error": error.localizedDescription
            ]
        }
    }

    private func capturePageThumbnail(prefix: String) async -> URL? {
        let wv = webViewReady()
        let width: CGFloat = 390
        let height: CGFloat = 720
        wv.isHidden = false
        wv.alpha = 1
        wv.frame = CGRect(x: -10_000, y: -10_000, width: width, height: height)
        wv.scrollView.setContentOffset(.zero, animated: false)
        wv.setNeedsLayout()
        wv.layoutIfNeeded()

        let config = WKSnapshotConfiguration()
        let contentHeight = max(height, min(wv.scrollView.contentSize.height, 1_200))
        config.rect = CGRect(x: 0, y: 0, width: width, height: min(contentHeight, 1_200))
        config.snapshotWidth = NSNumber(value: Double(width))

        return await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: config) { image, error in
                if let error {
                    self.logger.debug("Browser snapshot failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let image, let data = image.pngData() else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let folder = try self.browserOutputDirectory()
                    let fileURL = folder.appendingPathComponent("\(prefix)_\(Int(Date().timeIntervalSince1970 * 1000)).png")
                    try data.write(to: fileURL, options: [.atomic])
                    continuation.resume(returning: fileURL)
                } catch {
                    self.logger.debug("Browser snapshot write failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated func browserOutputDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base
            .appendingPathComponent("iexa-browser-tool", isDirectory: true)
            .appendingPathComponent(Self.dateFolderName(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func itemPayload(from item: WebSearchResultItem) -> [String: Any] {
        var payload: [String: Any] = [
            "title": item.title ?? "",
            "link": item.link ?? "",
            "snippet": item.snippet ?? ""
        ]
        if let thumbnailURL = item.thumbnailURL, !thumbnailURL.isEmpty {
            payload["thumbnail_url"] = thumbnailURL
        }
        return payload
    }

    private static func documentPayload(from document: WebSearchDocument) -> [String: Any] {
        [
            "content": document.content,
            "metadata": document.metadata
        ]
    }

    private static func urlValue(in call: [String: Any]) -> URL? {
        guard let raw = firstString(in: call, keys: ["url", "link", "href", "page_url", "source", "input_url"]),
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }

    private static func firstString(in call: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = call[key] else { continue }
            if let string = raw as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let number = raw as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func stringArray(in call: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            if let values = call[key] as? [String] {
                return values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let values = call[key] as? [Any] {
                return values.compactMap { value in
                    if let string = value as? String {
                        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    return nil
                }
            }
        }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func javascriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }

    private static func fetchFileName(for url: URL, contentType: String, headers: [AnyHashable: Any]) -> String {
        if let disposition = headers.first(where: { "\($0.key)".lowercased() == "content-disposition" })?.value as? String,
           let fileName = dispositionFileName(disposition) {
            return safeDownloadFileName(fileName, fallbackExtension: fileExtension(for: contentType))
        }
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, last != "/" {
            return safeDownloadFileName(last, fallbackExtension: fileExtension(for: contentType))
        }
        return "download_\(Int(Date().timeIntervalSince1970)).\(fileExtension(for: contentType))"
    }

    private static func dispositionFileName(_ disposition: String) -> String? {
        let pattern = #"filename\*?=(?:UTF-8''|")?([^";]+)"?#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..<disposition.endIndex, in: disposition)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: disposition) else {
            return nil
        }
        return String(disposition[range]).removingPercentEncoding
            ?? String(disposition[range])
    }

    private static func safeDownloadFileName(_ raw: String, fallbackExtension: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "download" : cleaned
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(name).\(fallbackExtension)" : name
    }

    private static func fileExtension(for contentType: String) -> String {
        let type = contentType.lowercased()
        if type.contains("html") { return "html" }
        if type.contains("json") { return "json" }
        if type.contains("pdf") { return "pdf" }
        if type.contains("png") { return "png" }
        if type.contains("jpeg") || type.contains("jpg") { return "jpg" }
        if type.contains("webp") { return "webp" }
        if type.contains("text") { return "txt" }
        return "bin"
    }

    private nonisolated static func dateFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    private func searchItems(for query: String) async -> [WebSearchResultItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let timestamp = Int(Date().timeIntervalSince1970)
        let needsFreshness = Self.searchNeedsFreshness(query)
        var pages: [SearchPage] = [
            SearchPage(
                url: needsFreshness
                    ? "https://cn.bing.com/search?q=\(encoded)&setlang=zh-Hans&filters=ex1%3a%22ez1%22&_=\(timestamp)"
                    : "https://cn.bing.com/search?q=\(encoded)&setlang=zh-Hans&_=\(timestamp)",
                timeout: 5,
                settleDelay: 350_000_000,
                resultLimit: 3
            ),
            SearchPage(url: "https://www.baidu.com/s?wd=\(encoded)&rn=10&ie=utf-8&_=\(timestamp)", timeout: 5, settleDelay: 350_000_000, resultLimit: 3),
            SearchPage(url: "https://www.so.com/s?q=\(encoded)&ie=utf-8&_=\(timestamp)", timeout: 5, settleDelay: 350_000_000, resultLimit: 2),
            SearchPage(
                url: needsFreshness
                    ? "https://duckduckgo.com/html/?q=\(encoded)&df=d"
                    : "https://duckduckgo.com/html/?q=\(encoded)",
                timeout: 5,
                settleDelay: 350_000_000,
                resultLimit: 2
            ),
            SearchPage(url: "https://www.sogou.com/web?query=\(encoded)&ie=utf8&_=\(timestamp)", timeout: 6, settleDelay: 450_000_000, resultLimit: 1)
        ]
        if needsFreshness {
            pages.append(SearchPage(url: "https://so.toutiao.com/search?keyword=\(encoded)&pd=information&dvpf=pc&_=\(timestamp)", timeout: 6, settleDelay: 450_000_000, resultLimit: 1))
        }

        var pageBuckets: [[WebSearchResultItem]] = []
        var seenLinks = Set<String>()

        for page in pages {
            guard let url = URL(string: page.url),
                  await load(url: url, timeout: page.timeout) else {
                continue
            }
            try? await Task.sleep(nanoseconds: page.settleDelay)
            let items = await evaluateSearchItems().filter { item in
                guard let link = item.link, let url = URL(string: link) else { return false }
                return !Self.isBlockedDocumentURL(url)
                    && !Self.isLowValueSearchResult(item)
            }
            var pageItems: [WebSearchResultItem] = []
            for item in items {
                guard let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !link.isEmpty,
                      seenLinks.insert(link.lowercased()).inserted else {
                    continue
                }
                pageItems.append(item)
                if pageItems.count >= page.resultLimit {
                    break
                }
            }
            if !pageItems.isEmpty {
                pageBuckets.append(pageItems)
                let collectedCount = pageBuckets.reduce(0) { $0 + $1.count }
                if collectedCount >= 8 || (pageBuckets.count >= 3 && collectedCount >= 6) {
                    break
                }
            }
        }

        var collected: [WebSearchResultItem] = []
        var round = 0
        while collected.count < 8 {
            var appendedAny = false
            for bucket in pageBuckets {
                guard round < bucket.count else { continue }
                collected.append(bucket[round])
                appendedAny = true
                if collected.count >= 8 {
                    return collected
                }
            }
            if !appendedAny { break }
            round += 1
        }
        return collected
    }

    private func fetchDocuments(for items: [WebSearchResultItem]) async -> [WebSearchDocument] {
        guard !items.isEmpty else { return [] }

        let fetched = await withTaskGroup(of: (Int, WebSearchDocument?).self) { group in
            for (index, item) in items.prefix(4).enumerated() {
                group.addTask {
                    (index, await Self.fastDocument(for: item))
                }
            }

            var values: [(Int, WebSearchDocument)] = []
            for await (index, document) in group {
                if let document {
                    values.append((index, document))
                }
            }
            return values
        }

        return fetched
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    private func fetchDocument(for item: WebSearchResultItem) async -> WebSearchDocument? {
        guard let rawLink = item.link,
              let url = URL(string: rawLink),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !Self.isBlockedDocumentURL(url) else {
            return nil
        }

        if Self.isGitHubRepositoryURL(url) {
            return Self.summaryDocument(for: item)
        }

        guard await load(url: url, timeout: 16) else {
            return Self.summaryDocument(for: item)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)

        guard let snapshot = await evaluatePageSnapshot(),
              !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.summaryDocument(for: item)
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

    private nonisolated static func summaryDocument(for item: WebSearchResultItem) -> WebSearchDocument? {
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

    private nonisolated static func firstHTMLCapture(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[captureRange])
    }

    private nonisolated static func decodeHTMLEntities(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var decoded = value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        let numericPattern = #"&#x?([0-9A-Fa-f]+);"#
        if let regex = try? NSRegularExpression(pattern: numericPattern) {
            let source = decoded
            var result = ""
            var current = source.startIndex
            for match in regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) {
                guard let fullRange = Range(match.range(at: 0), in: source),
                      let valueRange = Range(match.range(at: 1), in: source) else {
                    continue
                }
                result += String(source[current..<fullRange.lowerBound])
                let token = String(source[valueRange])
                let isHex = source[fullRange].lowercased().hasPrefix("&#x")
                let scalarValue = UInt32(token, radix: isHex ? 16 : 10)
                if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                    result += String(Character(scalar))
                } else {
                    result += String(source[fullRange])
                }
                current = fullRange.upperBound
            }
            result += String(source[current..<source.endIndex])
            decoded = result
        }
        return decoded
    }

    private nonisolated static func cleanHTMLText(_ value: String) -> String {
        decodeHTMLEntities(value)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func plainText(fromHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style\b[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<noscript\b[^>]*>.*?</noscript>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</(p|div|section|article|main|header|footer|aside|li|ul|ol|h[1-6]|br|tr|table)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)

        text = decodeHTMLEntities(text)
        let lines = text
            .components(separatedBy: .newlines)
            .map(cleanHTMLText)
            .filter { $0.count > 1 }
        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func fastDocument(for item: WebSearchResultItem) async -> WebSearchDocument? {
        guard let rawLink = item.link,
              let url = URL(string: rawLink),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !isBlockedDocumentURL(url),
              !isGitHubRepositoryURL(url) else {
            return summaryDocument(for: item)
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return summaryDocument(for: item)
            }
            let limitedData = Data(data.prefix(1_500_000))
            guard let html = String(data: limitedData, encoding: .utf8)
                    ?? String(data: limitedData, encoding: .isoLatin1) else {
                return summaryDocument(for: item)
            }
            let title = firstHTMLCapture(#"(?is)<title[^>]*>(.*?)</title>"#, in: html)
                .map(decodeHTMLEntities)
                .map(cleanHTMLText)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? item.title
                ?? rawLink
            let description = firstHTMLCapture(#"(?is)<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["'][^>]*>"#, in: html)
                ?? firstHTMLCapture(#"(?is)<meta[^>]+content=["']([^"']+)["'][^>]+name=["']description["'][^>]*>"#, in: html)
                ?? item.snippet
                ?? ""
            let text = plainText(fromHTML: html)
            guard text.count >= 160 else {
                return summaryDocument(for: item)
            }

            var sections = [
                "Title: \(title)",
                "URL: \(rawLink)"
            ]
            let cleanedDescription = cleanHTMLText(decodeHTMLEntities(description))
            if !cleanedDescription.isEmpty {
                sections.append("Description: \(cleanedDescription)")
            }
            sections.append("Content excerpt:\n\(String(text.prefix(4_000)))")

            var metadata = [
                "title": title,
                "source": rawLink,
                "link": rawLink,
                "provider": "urlsession_web_page",
                "searched_at": ISO8601DateFormatter().string(from: Date())
            ]
            if !cleanedDescription.isEmpty {
                metadata["search_snippet"] = cleanedDescription
            }
            return WebSearchDocument(content: sections.joined(separator: "\n"), metadata: metadata)
        } catch {
            return summaryDocument(for: item)
        }
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

        let wv = WKWebView(frame: CGRect(x: -10_000, y: -10_000, width: 390, height: 720), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        wv.isHidden = false
        wv.alpha = 1
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

    private func evaluateSearchItems() async -> [WebSearchResultItem] {
        let script = """
        (() => {
          const blockedHosts = new Set([
            'duckduckgo.com', 'www.duckduckgo.com',
            'bing.com', 'www.bing.com', 'cn.bing.com',
            'google.com', 'www.google.com',
            'baidu.com', 'www.baidu.com',
            'so.com', 'www.so.com', 'm.so.com',
            'sogou.com', 'www.sogou.com', 'm.sogou.com',
            'so.toutiao.com',
            'metaso.cn', 'www.metaso.cn',
            'quark.sm.cn', 'm.sm.cn', 'sm.cn'
          ]);
          function text(node) {
            return (node && node.innerText || node && node.textContent || '').replace(/\\s+/g, ' ').trim();
          }
          function cleanHTML(raw) {
            const div = document.createElement('div');
            div.innerHTML = raw || '';
            return text(div);
          }
          function parseDataTools(node) {
            let current = node;
            while (current && current !== document.body) {
              const raw = current.getAttribute && (current.getAttribute('data-tools') || current.getAttribute('data-log') || current.getAttribute('data-item'));
              if (raw) {
                try {
                  const data = JSON.parse(raw.replace(/&quot;/g, '"'));
                  const value = data.url || data.href || data.link || data.linkUrl || data.source_url || data.article_url;
                  if (value) return value;
                } catch (_) {}
              }
              current = current.parentElement;
            }
            return '';
          }
          function absolutize(raw) {
            try {
              if (!raw) return '';
              const url = new URL(raw, location.href);
              if (url.hostname.endsWith('duckduckgo.com') && url.pathname.startsWith('/l/')) {
                const uddg = url.searchParams.get('uddg');
                if (uddg) return decodeURIComponent(uddg);
              }
              if ((url.hostname.includes('bing.com') || url.hostname.includes('google.com')) && (url.pathname === '/url' || url.pathname === '/ck/a')) {
                const q = url.searchParams.get('q') || url.searchParams.get('u');
                if (q && /^https?:/i.test(q)) return q;
              }
              if (url.hostname.endsWith('baidu.com')) {
                const q = url.searchParams.get('url') || url.searchParams.get('target') || url.searchParams.get('wd');
                if (q && /^https?:/i.test(q)) return q;
                return '';
              }
              if (url.hostname.endsWith('so.com') || url.hostname.endsWith('sogou.com')) {
                const q = url.searchParams.get('url') || url.searchParams.get('u') || url.searchParams.get('target') || url.searchParams.get('link');
                if (q && /^https?:/i.test(q)) return decodeURIComponent(q);
                if (['/s', '/web', '/link', '/link2url'].includes(url.pathname)) return '';
              }
              if (url.hostname === 'so.toutiao.com') return '';
              if (url.hostname.endsWith('metaso.cn') && (url.pathname === '/' || url.pathname.startsWith('/search'))) return '';
              if (url.hostname.endsWith('sm.cn') && (url.pathname === '/s' || url.pathname.includes('punish'))) return '';
              return url.href;
            } catch (_) {
              return '';
            }
          }
          function linkFor(anchor, node) {
            const attrs = ['href', 'data-url', 'data-href', 'data-link', 'data-pcurl', 'data-mu'];
            for (const attr of attrs) {
              const raw = anchor && anchor.getAttribute && anchor.getAttribute(attr);
              const link = absolutize(raw);
              if (link) return link;
            }
            const toolLink = absolutize(parseDataTools(node || anchor));
            if (toolLink) return toolLink;
            return '';
          }
          function blocked(raw) {
            try {
              const url = new URL(raw);
              const text = decodeURIComponent((url.href || '').toLowerCase());
              if (!/^https?:$/.test(url.protocol)) return true;
              if (url.hostname.endsWith('baidu.com')) return true;
              if (blockedHosts.has(url.hostname) && ['/search', '/html/', '/', '/s', '/web', '/link', '/link2url', '/url', '/ck/a'].includes(url.pathname)) return true;
              if (/(feedback|complain|jubao|report|login|passport|captcha|punish|help|service|privacy|agreement)/i.test(text)) return true;
              return /\\.(jpg|jpeg|png|gif|webp|avif|svg|mp4|mov|mp3|zip|rar|7z|ipa|apk|dmg|pdf)(\\?|$)/i.test(url.pathname);
            } catch (_) {
              return true;
            }
          }
          function lowValue(item) {
            const value = `${item.title || ''} ${item.link || ''} ${item.snippet || ''}`.toLowerCase();
            return /意见反馈|用户反馈|反馈中心|投诉|举报|登录|注册|验证码|captcha|punish|隐私政策|服务协议|帮助中心|下载客户端|打开app|打开 app/i.test(value);
          }
          const candidates = [];
          const selectors = [
            '.result',
            '.c-container',
            '.result-op',
            '.res-list',
            '.vrResult',
            '.resultLink',
            '.s-result-list [data-druid-card-data-id]',
            '.search-result',
            '.search-result-card',
            '.result-item',
            '.results_links',
            'li.b_algo',
            'article',
            '[data-testid="result"]',
            'a.result__a',
            'h2 a',
            'h3 a'
          ];
          for (const selector of selectors) {
            for (const node of document.querySelectorAll(selector)) {
              let anchor = node.matches && node.matches('a[href]') ? node : node.querySelector && node.querySelector('a[href]');
              if (!anchor) continue;
              const link = linkFor(anchor, node);
              if (!link || blocked(link)) continue;
              const title = text(anchor) || text(node.querySelector && node.querySelector('h2,h3')) || link;
              const snippetNode = node.querySelector && node.querySelector('.result__snippet, .b_caption p, .c-abstract, .content-right, .c-span-last, .cos-color-text, p, .snippet, .content, .result-snippet, .res-desc, .summary, .abstract, .text-default');
              const dateNode = node.querySelector && node.querySelector('time, .news_dt, .c-color-gray2, .result__timestamp, .b_factrow, [aria-label*="Published"], [aria-label*="Updated"]');
              const dateText = text(dateNode);
              const snippet = [dateText, text(snippetNode)].filter(Boolean).join(' - ');
              candidates.push({ title, link, snippet });
            }
          }
          for (const script of document.querySelectorAll('script[type="application/json"], script[data-druid-card-data-id]')) {
            try {
              const raw = script.textContent || '';
              if (!raw.includes('article_url') && !raw.includes('source_url') && !raw.includes('open_url')) continue;
              const object = JSON.parse(raw);
              const data = object.data || object;
              const display = data.display || {};
              const title = cleanHTML(data.title || data.emphasized?.title || display.title?.text || display.title?.marked || '');
              const link = absolutize(data.article_url || data.source_url || data.open_url || data.share_url || data.ttsearch_msite_url || display.info?.url || '');
              const snippet = cleanHTML(data.abstract || data.summary || data.emphasized?.summary || display.summary?.text || display.summary?.marked || '');
              if (title && link && !blocked(link)) {
                candidates.push({ title, link, snippet });
              }
            } catch (_) {}
          }
          if (candidates.length === 0) {
            for (const anchor of document.querySelectorAll('a[href]')) {
              const link = linkFor(anchor, anchor);
              const title = text(anchor);
              if (!link || !title || title.length < 3 || blocked(link)) continue;
              candidates.push({ title, link, snippet: '' });
            }
          }
          const out = [];
          const seen = new Set();
          for (const item of candidates) {
            const key = item.link.toLowerCase();
            if (seen.has(key)) continue;
            if (lowValue(item)) continue;
            seen.add(key);
            out.push(item);
            if (out.length >= 8) break;
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
          function removeNoise(root) {
            root.querySelectorAll('script,style,noscript,svg,canvas,iframe,nav,footer,header,aside,form,button,input,select,textarea').forEach(n => n.remove());
          }
          const clone = document.body ? document.body.cloneNode(true) : document.documentElement.cloneNode(true);
          removeNoise(clone);
          const main = clone.querySelector('article, main, [role="main"]') || clone;
          const title = clean(document.title || document.querySelector('h1')?.innerText || '');
          const desc = clean(document.querySelector('meta[name="description"]')?.content || document.querySelector('meta[property="og:description"]')?.content || '');
          const published = clean(
            document.querySelector('meta[property="article:published_time"]')?.content ||
            document.querySelector('meta[property="article:modified_time"]')?.content ||
            document.querySelector('meta[name="date"]')?.content ||
            document.querySelector('meta[name="pubdate"]')?.content ||
            document.querySelector('meta[itemprop="datePublished"]')?.content ||
            document.querySelector('meta[itemprop="dateModified"]')?.content ||
            document.querySelector('time[datetime]')?.getAttribute('datetime') ||
            document.querySelector('time')?.innerText ||
            ''
          );
          let text = (main.innerText || main.textContent || '').replace(/\\n{3,}/g, '\\n\\n');
          text = text.split('\\n').map(line => line.trim()).filter(line => line.length > 1).join('\\n');
          return JSON.stringify({ title, url: location.href, description: desc, published, text: text.slice(0, 9000) });
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

    private nonisolated static func isBlockedDocumentURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let absolute = url.absoluteString.lowercased()
        let lowValuePathTokens = [
            "feedback", "complain", "jubao", "report", "login", "passport",
            "captcha", "punish", "help", "service", "privacy", "agreement"
        ]
        if lowValuePathTokens.contains(where: { absolute.contains($0) }) {
            return true
        }
        if host == "baidu.com" || host.hasSuffix(".baidu.com") {
            return true
        }
        if host == "so.com" || host.hasSuffix(".so.com") {
            return ["/s", "/search", "/link", "/link2url", "/"].contains(url.path.lowercased())
        }
        if host == "sogou.com" || host.hasSuffix(".sogou.com") {
            return ["/web", "/link", "/link2url", "/"].contains(url.path.lowercased())
        }
        if host == "so.toutiao.com" {
            return true
        }
        if host == "metaso.cn" || host.hasSuffix(".metaso.cn") {
            let path = url.path.lowercased()
            return path == "/" || path.hasPrefix("/search")
        }
        if host == "sm.cn" || host.hasSuffix(".sm.cn") {
            let path = url.path.lowercased()
            return path == "/s" || path.contains("punish")
        }
        if ["duckduckgo.com", "www.duckduckgo.com", "bing.com", "www.bing.com", "cn.bing.com", "google.com", "www.google.com"].contains(host),
           ["/search", "/html/", "/", "/s", "/link", "/url", "/ck/a"].contains(url.path.lowercased()) {
            return true
        }
        let path = url.path.lowercased()
        let blockedExt = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".mp4", ".mov", ".mp3", ".zip", ".rar", ".7z", ".ipa", ".apk", ".dmg", ".pdf"]
        return blockedExt.contains { path.hasSuffix($0) }
    }

    private nonisolated static func isLowValueSearchResult(_ item: WebSearchResultItem) -> Bool {
        let value = [
            item.title ?? "",
            item.link ?? "",
            item.snippet ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        let tokens = [
            "意见反馈", "用户反馈", "反馈中心", "投诉", "举报",
            "登录", "注册", "验证码", "隐私政策", "服务协议", "帮助中心",
            "下载客户端", "打开app", "打开 app",
            "feedback", "complain", "report", "login", "passport", "captcha", "punish"
        ]
        return tokens.contains { value.contains($0) }
    }

    private static func githubSearchSeed(originalQuery: String?, queries: [String]) -> String? {
        let candidates = [originalQuery]
            .compactMap { $0 }
            + queries
        for candidate in candidates {
            let normalized = normalizedQuery(candidate)
            guard !normalized.isEmpty,
                  shouldUseGitHubSearch(for: normalized) else {
                continue
            }
            return normalized
        }
        return nil
    }

    private static func shouldUseGitHubSearch(for query: String) -> Bool {
        let normalized = query
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let triggers = [
            "github", "github.com",
            "开源", "源码", "源代码",
            "仓库", "代码仓库",
            "open source", "source code",
            "repository"
        ]
        return triggers.contains { normalized.contains($0) }
    }

    private nonisolated static func isGitHubRepositoryURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return false }
        let first = components[0].lowercased()
        let reserved = [
            "search", "topics", "about", "pricing", "login", "join", "orgs",
            "apps", "collections", "features", "marketplace", "sponsors",
            "settings", "contact", "site", "explore", "trending"
        ]
        return !reserved.contains(first)
    }

    private static func githubRepositoryResults(for query: String) async -> [WebSearchResultItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: normalized),
            URLQueryItem(name: "per_page", value: "5")
        ]
        if searchNeedsFreshness(normalized) {
            components?.queryItems?.append(URLQueryItem(name: "sort", value: "updated"))
            components?.queryItems?.append(URLQueryItem(name: "order", value: "desc"))
        }
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenRelay/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                return []
            }

            return items.compactMap { entry in
                let fullName = (entry["full_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                let htmlURL = (entry["html_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                guard !fullName.isEmpty || !htmlURL.isEmpty else { return nil }

                let description = (entry["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let language = (entry["language"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stars = entry["stargazers_count"] as? Int ?? 0
                let updatedAt = (entry["updated_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                var snippetParts: [String] = []
                if !description.isEmpty { snippetParts.append(description) }
                if stars > 0 { snippetParts.append("stars \(stars)") }
                if !language.isEmpty { snippetParts.append(language) }
                if !updatedAt.isEmpty { snippetParts.append(updatedAt) }

                return WebSearchResultItem(json: [
                    "title": fullName.isEmpty ? htmlURL : fullName,
                    "link": htmlURL,
                    "snippet": snippetParts.joined(separator: " · ")
                ])
            }
        } catch {
            return []
        }
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

private struct SearchPage {
    let url: String
    let timeout: TimeInterval
    let settleDelay: UInt64
    let resultLimit: Int
}
