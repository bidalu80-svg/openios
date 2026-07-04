import Foundation
import WebKit
import UIKit
import OSLog

@MainActor
final class BrowserWebSearchService: NSObject {
    static let shared = BrowserWebSearchService()

    private let logger = Logger(subsystem: "com.openui", category: "BrowserWebSearch")
    private var webView: WKWebView?
    private var browserTabs: [Int: WKWebView] = [:]
    private var activeBrowserTabID = 1
    private var nextBrowserTabID = 2
    private var browserViewportSize = CGSize(width: 390, height: 720)
    private var browserUserAgentProfile = "mobile_safari"
    private var browserVisibleChallengeRefreshURLs: Set<String> = []
    private var browserHumanVerificationSeenTabs: Set<Int> = []
    private var browserHumanVerificationCompletedAtByTab: [Int: Date] = [:]
    private var browserHumanVerificationCompletedURLByTab: [Int: URL] = [:]
    private var lastBrowserNavigationReusedExistingPage = false
    private let humanVerificationPageReuseWindow: TimeInterval = 10 * 60
    private var navigationContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private weak var automationBrowserContainer: UIView?
    private weak var automationBrowserNavigationDelegate: WKNavigationDelegate?
    private weak var automationBrowserUIDelegate: WKUIDelegate?

    private override init() {
        super.init()
    }

    func search(queries: [String], originalQuery: String?) async -> WebSearchResponse {
        let baseQueries = queries
            .map(Self.normalizedQuery)
            .filter { !$0.isEmpty }
        let normalizedQueries = Self.freshnessExpandedQueries(
            baseQueries,
            originalQuery: originalQuery
        )
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
            let snapshot = await evaluateFullPageSnapshot(maxScrolls: 14)
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
               !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let doc = Self.fullPageDocument(
                    from: snapshot,
                    fallbackTitle: finalItems.first(where: { $0.link == firstLink })?.title,
                    fallbackURL: firstLink,
                    provider: "wkwebview_browser_full_page"
                )
                docs.removeAll { Self.documentMatches($0, url: firstLink, alternateURL: snapshot.url) }
                docs.insert(doc, at: 0)
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
        case "browser.use", "browser_use":
            return await executeNativeBrowserUse(call)
        case "browser.open", "browser.navigate", "browser_open", "browser.navigate_url", "navigate":
            return await executeNativeOpen(call, readable: false)
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
        case "browser.click", "browser_click", "click":
            return await executeNativeClick(call)
        case "browser.type", "browser_type", "type":
            return await executeNativeType(call)
        case "browser.hover", "browser_hover", "hover":
            return await executeNativeHover(call)
        case "browser.scroll", "browser_scroll", "scroll":
            return await executeNativeScroll(call)
        case "browser.scroll_and_collect", "browser_scroll_and_collect", "scroll_and_collect":
            return await executeNativeScrollAndCollect(call)
        case "browser.find_elements", "browser_find_elements", "find_elements":
            return await executeNativeFindElements(call)
        case "browser.get_backbone", "browser_get_backbone", "get_backbone":
            return await executeNativeBackbone(call)
        case "browser.execute_js", "browser_execute_js", "execute_js", "eval_js":
            return await executeNativeExecuteJavaScript(call)
        case "browser.set_viewport", "browser_set_viewport", "set_viewport":
            return await executeNativeSetViewport(call)
        case "browser.set_user_agent", "browser_set_user_agent", "set_user_agent":
            return executeNativeSetUserAgent(call)
        case "browser.get_cookies", "browser_get_cookies", "get_cookies":
            return await executeNativeCookies(call)
        case "browser.wait_for_dom_stable", "browser_wait_for_dom_stable", "wait_for_dom_stable":
            return await executeNativeWaitForDOMStable(call)
        case "browser.wait_for_image", "browser_wait_for_image", "wait_for_image", "wait_image", "image_result":
            return await executeNativeWaitForImage(call)
        case "browser.new_tab", "browser_new_tab", "new_tab":
            return await executeNativeNewTab(call)
        case "browser.close_tab", "browser_close_tab", "close_tab":
            return await executeNativeCloseTab(call)
        case "browser.list_tabs", "browser_list_tabs", "list_tabs":
            return await executeNativeListTabs(call)
        default:
            return [
                "action": rawAction,
                "ok": false,
                "error": "Unsupported browser action"
            ]
        }
    }

    private func executeNativeBrowserUse(_ call: [String: Any]) async -> [String: Any] {
        if let profile = Self.firstString(in: call, keys: ["user_agent", "userAgent"]) {
            applyBrowserUserAgent(profile)
        }
        if let tabID = Self.intValue(call["tab_id"] ?? call["tabId"]) {
            activateBrowserTab(tabID)
        }

        let requestedAction = Self.firstString(
            in: call,
            keys: ["browser_action", "browser_use_action", "operation", "op", "type", "action"]
        )
        let routedAction = Self.browserUseActionName(requestedAction, call: call)
        var payload = await executeNativeBrowserTool(action: routedAction, call: call)
        payload["action"] = "browser_use"
        payload["browser_action"] = routedAction
        payload["active_tab_id"] = activeBrowserTabID
        if payload["summary"] == nil {
            payload["summary"] = "浏览器动作已执行。"
        }
        return payload
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
        let includeScreenshot = Self.boolValue(call["screenshot"] ?? call["with_screenshot"] ?? call["thumbnail"] ?? call["attach_preview"] ?? call["attachPreview"]) ?? false
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
            let snapshot = await evaluateFullPageSnapshot(maxScrolls: 14)
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
                let doc = Self.fullPageDocument(
                    from: snapshot,
                    fallbackTitle: response.items.first(where: { $0.link == firstLink })?.title,
                    fallbackURL: firstLink,
                    provider: "wkwebview_browser_tool_full_page"
                )
                docsPayload.removeAll { Self.documentPayloadMatches($0, url: firstLink, alternateURL: snapshot.url) }
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
            "attach_file": false,
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
        let forceReload = Self.boolValue(call["force_reload"] ?? call["forceReload"] ?? call["reload"]) ?? false
        guard await load(url: url, timeout: min(max(timeout, 3), 30), forceReload: forceReload) else {
            return [
                "action": readable ? "browser.readable" : "browser.open",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        let reusedExistingPage = lastBrowserNavigationReusedExistingPage
        try? await Task.sleep(nanoseconds: 650_000_000)

        let maxLength = min(max(Self.intValue(call["max_length"] ?? call["limit"]) ?? 8_000, 800), 18_000)
        let includeScreenshot = Self.boolValue(call["screenshot"] ?? call["with_screenshot"] ?? call["thumbnail"] ?? call["attach_preview"] ?? call["attachPreview"]) ?? false
        let maxScrolls = min(max(Self.intValue(call["scroll_count"] ?? call["max_scrolls"] ?? call["maxScrolls"]) ?? 14, 1), 24)
        let snapshot = await evaluateFullPageSnapshot(maxScrolls: maxScrolls)
        let verification = await evaluateJSONObject(Self.visibleChallengeProbeScript()) ?? ["detected": false]
        let verificationDetected = Self.boolValue(verification["detected"]) == true
        let verificationCompleted = Self.boolValue(verification["completed"]) == true
        if verificationDetected && !verificationCompleted {
            _ = await scrollToVisibleHumanVerification()
        }
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
            "full_page": true,
            "max_scrolls": maxScrolls,
            "human_verification": verification,
            "requires_user_verification": verificationDetected && !verificationCompleted,
            "reused_existing_page": reusedExistingPage,
            "summary": verificationDetected && !verificationCompleted
                ? "网页需要先完成人机验证；请在弹出的共享浏览器中完成后继续。"
                : (reusedExistingPage
                    ? (text.isEmpty ? "已复用当前浏览器页面：\(title)" : "已复用当前浏览器页面并滚动读取全文：\(title)")
                    : (text.isEmpty ? "已打开网页：\(title)" : "已打开并滚动读取网页全文：\(title)"))
        ]
        if let thumbnail {
            payload["attach_file"] = false
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
           !(await load(url: url, timeout: 12)) {
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
        if let selector, !selector.isEmpty {
            let script = """
            (() => {
              const node = document.querySelector(\(Self.javascriptString(selector)));
              return JSON.stringify({
                title: document.title || '',
                url: location.href,
                text: ((node && (node.innerText || node.textContent)) || '').slice(0, \(maxLength))
              });
            })();
            """
            guard let json = await evaluateString(script),
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [
                    "action": "browser.text",
                    "ok": false,
                    "error": "Unable to read page text"
                ]
            }
            let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                "action": "browser.text",
                "ok": true,
                "title": object["title"] as? String ?? "",
                "url": object["url"] as? String ?? "",
                "selector": selector,
                "text": text,
                "text_truncated": text.count >= maxLength,
                "full_page": false,
                "summary": "已读取网页文本。"
            ]
        }

        guard let snapshot = await evaluateFullPageSnapshot(
            maxScrolls: min(max(Self.intValue(call["scroll_count"] ?? call["max_scrolls"] ?? call["maxScrolls"]) ?? 14, 1), 24)
        ) else {
            return [
                "action": "browser.text",
                "ok": false,
                "error": "Unable to read page text"
            ]
        }
        let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "action": "browser.text",
            "ok": true,
            "title": snapshot.title,
            "url": snapshot.url,
            "selector": "",
            "text": String(text.prefix(maxLength)),
            "text_truncated": text.count > maxLength,
            "full_page": true,
            "summary": "已滚动读取网页全文。"
        ]
    }

    private func executeNativePageInfo(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 12)) {
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
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.screenshot",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 650_000_000)

        let fullPage = Self.boolValue(call["full_page"] ?? call["fullPage"] ?? call["fullpage"] ?? call["entire_page"] ?? call["entirePage"]) ?? false
        let attachPreview = Self.boolValue(call["attach_preview"] ?? call["attachPreview"] ?? call["show_in_chat"] ?? call["showInChat"]) ?? false
        let screenshot = fullPage
            ? await captureFullPageScreenshot(prefix: "browser_full")
            : await capturePageThumbnail(prefix: "browser")
        guard let screenshot else {
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
            "screenshot_url": screenshot.absoluteString,
            "file_url": screenshot.absoluteString,
            "file_name": screenshot.lastPathComponent,
            "content_type": "image/png",
            "full_page": fullPage,
            "attach_preview": attachPreview,
            "attach_file": attachPreview,
            "preview_images": attachPreview ? [screenshot.absoluteString] : [],
            "items": [[
                "title": title,
                "link": url,
                "snippet": snapshot.map { String($0.text.prefix(260)) } ?? "",
                "thumbnail_url": attachPreview ? screenshot.absoluteString : ""
            ]],
            "summary": fullPage ? "已生成整页网页截图（仅供工具观察，不默认插入对话）。" : "已生成当前视口网页截图（仅供工具观察，不默认插入对话）。"
        ]
    }

    private func executeNativeFetch(_ call: [String: Any]) async -> [String: Any] {
        guard let url = Self.urlValue(in: call, allowLocalFiles: false) else {
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

    private func executeNativeClick(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.click",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let selector = Self.firstString(in: call, keys: ["selector", "css", "element"])
        let label = Self.firstString(in: call, keys: [
            "label", "button_text", "buttonText", "aria_label", "ariaLabel",
            "name", "title", "placeholder", "text"
        ])
        let x = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"])
        let y = Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"])
        let visualFallback = Self.boolValue(
            call["visual_fallback"] ?? call["visualFallback"] ?? call["screenshot_fallback"] ?? call["screenshotFallback"]
        ) ?? true
        guard selector != nil || label != nil || (x != nil && y != nil) else {
            return [
                "action": "browser.click",
                "ok": false,
                "error": "Missing selector, label, or coordinates"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const desiredLabel = \(Self.javascriptString(label ?? ""));
          const x = \(x.map(String.init) ?? "null");
          const y = \(y.map(String.init) ?? "null");
          const clickableSelector = [
            'button', 'a[href]', 'input', 'textarea', 'select', 'summary',
            '[role="button"]', '[role="link"]', '[onclick]', '[tabindex]',
            '[aria-label]', '[data-testid]', '[data-test]', '[data-cy]'
          ].join(',');
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function accessibleText(node) {
            if (!node) return '';
            const parts = [
              text(node),
              node.getAttribute ? node.getAttribute('aria-label') : '',
              node.getAttribute ? node.getAttribute('title') : '',
              node.getAttribute ? node.getAttribute('alt') : '',
              node.getAttribute ? node.getAttribute('name') : '',
              node.getAttribute ? node.getAttribute('value') : '',
              node.getAttribute ? node.getAttribute('placeholder') : '',
              node.getAttribute ? node.getAttribute('data-testid') : '',
              node.value || '',
              node.placeholder || ''
            ];
            return parts.filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim();
          }
          function rect(node) {
            if (!node || !node.getBoundingClientRect) return null;
            const r = node.getBoundingClientRect();
            return {
              x: Math.round(r.x),
              y: Math.round(r.y),
              width: Math.round(r.width),
              height: Math.round(r.height)
            };
          }
          function visible(node) {
            if (!node || !node.getBoundingClientRect) return false;
            if (node.hidden || (node.closest && node.closest('[hidden],[aria-hidden="true"]'))) return false;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) === 0) return false;
            const r = node.getBoundingClientRect();
            return r.width > 1 && r.height > 1;
          }
          function allRoots() {
            const roots = [document];
            for (let i = 0; i < roots.length; i += 1) {
              const root = roots[i];
              const nodes = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : [];
              for (const node of nodes) {
                if (node.shadowRoot) roots.push(node.shadowRoot);
              }
            }
            return roots;
          }
          function deepQuerySelector(raw) {
            for (const root of allRoots()) {
              try {
                const match = root.querySelector(raw);
                if (match) return match;
              } catch (_) {
                return null;
              }
            }
            return null;
          }
          function findNode(raw) {
            if (!raw) return null;
            try {
              if (raw.startsWith('/') || raw.startsWith('.//')) {
                const result = document.evaluate(raw, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                return result.singleNodeValue;
              }
              return deepQuerySelector(raw);
            } catch (_) {
              return null;
            }
          }
          function findByLabel(raw) {
            const wanted = norm(raw);
            if (!wanted) return null;
            const candidates = [];
            for (const root of allRoots()) {
              try {
                candidates.push(...Array.from(root.querySelectorAll(clickableSelector)));
              } catch (_) {}
            }
            let best = null;
            let bestScore = -1;
            for (const node of candidates) {
              if (!visible(node)) continue;
              const label = norm(accessibleText(node));
              if (!label) continue;
              let score = -1;
              if (label === wanted) score = 100;
              else if (label.startsWith(wanted)) score = 80;
              else if (label.includes(wanted)) score = 60;
              else if (wanted.includes(label) && label.length >= 2) score = 40;
              if (score > bestScore) {
                best = node;
                bestScore = score;
              }
            }
            return best;
          }
          function isEditable(node) {
            if (!node) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            return tag === 'input' || tag === 'textarea' || tag === 'select' || !!node.isContentEditable;
          }
          function humanVerificationState() {
            const turnstile = document.querySelector('[name="cf-turnstile-response"], input[id^="cf-chl-widget"], .cf-turnstile, [data-sitekey]');
            const recaptcha = document.querySelector('[name="g-recaptcha-response"], .g-recaptcha, iframe[src*="recaptcha"]');
            const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || frame.getAttribute('aria-label') || '').join(' ');
            const bodyText = norm(document.body && document.body.innerText || '');
            const textDetected = /prove you are human|verify you are human|checking if the site connection is secure|captcha|turnstile|recaptcha/.test(bodyText);
            const frameDetected = /turnstile|captcha|recaptcha|challenge/.test(frames.toLowerCase());
            const tokenNode = turnstile || recaptcha;
            const tokenLength = tokenNode && 'value' in tokenNode ? String(tokenNode.value || '').length : 0;
            const provider = turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (frameDetected || textDetected ? 'human_verification' : ''));
            return {
              detected: Boolean(provider),
              provider,
              token_length: tokenLength,
              completed: Boolean(tokenLength > 0),
              reason: provider && tokenLength === 0 ? 'Human verification is present but not completed.' : ''
            };
          }
          const node = findNode(selector)
            || findByLabel(desiredLabel)
            || ((Number.isFinite(x) && Number.isFinite(y)) ? document.elementFromPoint(x, y) : null);
          if (!node) {
            return JSON.stringify({
              ok: false,
              error: 'Element not found',
              title: document.title || '',
              url: location.href,
              selector: selector || '',
              label: desiredLabel || '',
              needs_visual_coordinates: true,
              recovery_hint: 'DOM/accessibility text did not expose the target. Inspect the current viewport screenshot and retry with coordinate_x/coordinate_y instead of concluding the button is absent.'
            });
          }
          if (node.scrollIntoView) {
            node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          }
          const target = node.closest && node.closest('button, a, input, textarea, select, [contenteditable], [role="button"], [onclick]') || node;
          const editableTarget = isEditable(target);
          const r = target.getBoundingClientRect ? target.getBoundingClientRect() : null;
          const cx = Number.isFinite(x) ? x : (r ? Math.round(r.left + r.width / 2) : 0);
          const cy = Number.isFinite(y) ? y : (r ? Math.round(r.top + r.height / 2) : 0);
          const verification = humanVerificationState();
          const disabled = Boolean(
            target.disabled ||
            target.getAttribute && target.getAttribute('aria-disabled') === 'true' ||
            node.disabled ||
            node.getAttribute && node.getAttribute('aria-disabled') === 'true'
          );
          if (disabled) {
            return JSON.stringify({
              ok: false,
              error: verification.detected && !verification.completed
                ? 'Element is disabled because human verification is not complete'
                : 'Element is disabled',
              disabled: true,
              requires_user_verification: verification.detected && !verification.completed,
              human_verification: verification,
              title: document.title || '',
              url: location.href,
              selector: selector || '',
              label: desiredLabel || '',
              tag: (target.tagName || target.nodeName || '').toLowerCase(),
              text: accessibleText(target).slice(0, 160),
              rect: rect(target),
              coordinate_x: cx,
              coordinate_y: cy
            });
          }
          const events = [
            ['pointerdown', { bubbles: true, cancelable: true, composed: true, clientX: cx, clientY: cy, pointerType: 'touch', isPrimary: true }],
            ['mousedown', { bubbles: true, cancelable: true, composed: true, clientX: cx, clientY: cy }],
            ['pointerup', { bubbles: true, cancelable: true, composed: true, clientX: cx, clientY: cy, pointerType: 'touch', isPrimary: true }],
            ['mouseup', { bubbles: true, cancelable: true, composed: true, clientX: cx, clientY: cy }],
            ['click', { bubbles: true, cancelable: true, composed: true, clientX: cx, clientY: cy }]
          ];
          for (const [name, init] of events) {
            try {
              const event = name.startsWith('pointer') && window.PointerEvent
                ? new PointerEvent(name, init)
                : new MouseEvent(name, init);
              target.dispatchEvent(event);
            } catch (_) {}
          }
          if (!editableTarget && typeof target.click === 'function') {
            try { target.click(); } catch (_) {}
          }
          if (editableTarget && document.activeElement && document.activeElement.blur) {
            try { document.activeElement.blur(); } catch (_) {}
          }
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            selector: selector || '',
            label: desiredLabel || '',
            tag: (target.tagName || target.nodeName || '').toLowerCase(),
            text: accessibleText(target).slice(0, 160),
            href: target.href || '',
            rect: rect(target),
            coordinate_x: cx,
            coordinate_y: cy,
            disabled: false,
            human_verification: verification
          });
        })();
        """

        guard let object = await evaluateJSONObject(script) else {
            return [
                "action": "browser.click",
                "ok": false,
                "error": "Unable to click element"
            ]
        }
        var payload = object
        payload["action"] = "browser.click"
        let requiresVerification = Self.boolValue(payload["requires_user_verification"]) == true
        let clicked = Self.boolValue(payload["ok"]) ?? false
        if requiresVerification {
            _ = await scrollToVisibleHumanVerification()
            payload["summary"] = "网页需要先完成人机验证，目标按钮当前不可点击。请在浏览器中完成验证后继续。"
        } else if clicked {
            payload["summary"] = "已点击网页元素。"
        } else {
            if visualFallback,
               Self.boolValue(payload["needs_visual_coordinates"]) == true,
               let screenshot = await captureViewportScreenshot(prefix: "browser_click_miss") {
                payload["screenshot_url"] = screenshot.absoluteString
                payload["attach_file"] = false
                payload["preview_images"] = [screenshot.absoluteString]
                payload["summary"] = "未在 DOM/可访问性文本中找到目标，已截取当前视口；请根据截图使用坐标点击重试，不要断定页面没有按钮。"
                return payload
            }
            payload["summary"] = (payload["error"] as? String) ?? "网页点击未完成。"
        }
        return payload
    }

    private func executeNativeType(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.type",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let selector = Self.firstString(in: call, keys: ["selector", "css", "element"])
        let label = Self.firstString(in: call, keys: [
            "label", "field_label", "fieldLabel", "aria_label", "ariaLabel",
            "name", "title", "placeholder", "target"
        ])
        let x = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"])
        let y = Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"])
        let text = Self.firstString(in: call, keys: ["text", "value", "input", "content", "message"]) ?? ""
        let clear = Self.boolValue(call["clear"] ?? call["replace"] ?? call["overwrite"]) ?? true
        let pressEnter = Self.boolValue(call["press_enter"] ?? call["enter"] ?? call["submit"]) ?? false
        guard selector != nil || label != nil || (x != nil && y != nil) else {
            return [
                "action": "browser.type",
                "ok": false,
                "error": "Missing selector, label, or coordinates"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const desiredLabel = \(Self.javascriptString(label ?? ""));
          const x = \(x.map(String.init) ?? "null");
          const y = \(y.map(String.init) ?? "null");
          const text = \(Self.javascriptString(text));
          const clear = \(clear ? "true" : "false");
          const pressEnter = \(pressEnter ? "true" : "false");
          const editableSelector = 'input:not([type="hidden"]), textarea, select, [contenteditable], [role="textbox"], [aria-label], [placeholder], [name]';
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
          function textOf(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function attr(node, name) {
            return node && node.getAttribute ? (node.getAttribute(name) || '') : '';
          }
          function accessibleText(node) {
            if (!node) return '';
            const parts = [
              textOf(node),
              attr(node, 'aria-label'),
              attr(node, 'title'),
              attr(node, 'alt'),
              attr(node, 'name'),
              attr(node, 'value'),
              attr(node, 'placeholder'),
              attr(node, 'data-testid'),
              node.value || '',
              node.placeholder || ''
            ];
            return parts.filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim();
          }
          function allRoots() {
            const roots = [document];
            for (let i = 0; i < roots.length; i += 1) {
              const root = roots[i];
              const nodes = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : [];
              for (const node of nodes) {
                if (node.shadowRoot) roots.push(node.shadowRoot);
              }
            }
            return roots;
          }
          function deepQuerySelector(raw) {
            for (const root of allRoots()) {
              try {
                const match = root.querySelector(raw);
                if (match) return match;
              } catch (_) {
                return null;
              }
            }
            return null;
          }
          function findNode(raw) {
            if (!raw) return null;
            try {
              if (raw.startsWith('/') || raw.startsWith('.//')) {
                const result = document.evaluate(raw, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                return result.singleNodeValue;
              }
              return deepQuerySelector(raw);
            } catch (_) {
              return null;
            }
          }
          function visible(node) {
            if (!node || !node.getBoundingClientRect) return false;
            if (node.hidden || (node.closest && node.closest('[hidden],[aria-hidden="true"]'))) return false;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) === 0) return false;
            const r = node.getBoundingClientRect();
            return r.width > 1 && r.height > 1;
          }
          function isEditable(node) {
            if (!node) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            return tag === 'input' || tag === 'textarea' || tag === 'select' || !!node.isContentEditable || attr(node, 'role') === 'textbox';
          }
          function editableTarget(node) {
            if (!node) return null;
            if (isEditable(node)) return node;
            const closest = node.closest && node.closest(editableSelector);
            if (closest) return closest;
            try {
              const descendant = node.querySelector && node.querySelector(editableSelector);
              if (descendant) return descendant;
            } catch (_) {}
            return null;
          }
          function scoreLabel(node, raw) {
            const wanted = norm(raw);
            if (!wanted) return -1;
            const label = norm(accessibleText(node));
            if (!label) return -1;
            if (label === wanted) return 100;
            if (label.startsWith(wanted)) return 80;
            if (label.includes(wanted)) return 65;
            if (wanted.includes(label) && label.length >= 2) return 45;
            const tokens = wanted.split(/[\\s,，、]+/).filter(Boolean);
            let score = 0;
            for (const token of tokens) {
              if (label.includes(token)) score += 12;
            }
            return score > 0 ? score : -1;
          }
          function findLabelControl(raw) {
            const wanted = norm(raw);
            if (!wanted) return null;
            for (const root of allRoots()) {
              let labels = [];
              try { labels = Array.from(root.querySelectorAll('label')); } catch (_) {}
              for (const labelNode of labels) {
                const score = scoreLabel(labelNode, raw);
                if (score < 0) continue;
                const forID = attr(labelNode, 'for');
                if (forID) {
                  const target = document.getElementById(forID);
                  if (target) return target;
                }
                const nested = editableTarget(labelNode);
                if (nested) return nested;
              }
            }
            return null;
          }
          function findByLabel(raw) {
            const labelTarget = findLabelControl(raw);
            if (labelTarget) return labelTarget;
            let best = null;
            let bestScore = -1;
            for (const root of allRoots()) {
              let nodes = [];
              try { nodes = Array.from(root.querySelectorAll(editableSelector)); } catch (_) {}
              for (const node of nodes) {
                if (!visible(node)) continue;
                const score = scoreLabel(node, raw);
                if (score > bestScore) {
                  best = node;
                  bestScore = score;
                }
              }
            }
            return best;
          }
          function humanVerificationState() {
            const turnstile = document.querySelector('[name="cf-turnstile-response"], input[id^="cf-chl-widget"], .cf-turnstile, [data-sitekey]');
            const recaptcha = document.querySelector('[name="g-recaptcha-response"], .g-recaptcha, iframe[src*="recaptcha"]');
            const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || frame.getAttribute('aria-label') || '').join(' ');
            const bodyText = norm(document.body && document.body.innerText || '');
            const textDetected = /prove you are human|verify you are human|checking if the site connection is secure|captcha|turnstile|recaptcha/.test(bodyText);
            const frameDetected = /turnstile|captcha|recaptcha|challenge/.test(frames.toLowerCase());
            const tokenNode = turnstile || recaptcha;
            const tokenLength = tokenNode && 'value' in tokenNode ? String(tokenNode.value || '').length : 0;
            const provider = turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (frameDetected || textDetected ? 'human_verification' : ''));
            return {
              detected: Boolean(provider),
              provider,
              token_length: tokenLength,
              completed: Boolean(tokenLength > 0),
              reason: provider && tokenLength === 0 ? 'Human verification is present but not completed.' : ''
            };
          }
          const coordinateNode = (Number.isFinite(x) && Number.isFinite(y)) ? document.elementFromPoint(x, y) : null;
          const node = editableTarget(findNode(selector))
            || editableTarget(findByLabel(desiredLabel))
            || editableTarget(coordinateNode);
          if (!node) {
            return JSON.stringify({ ok: false, error: 'Element not found' });
          }
          if (node.scrollIntoView) {
            try { node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          }
          const verification = humanVerificationState();
          const disabled = Boolean(
            node.disabled ||
            attr(node, 'aria-disabled') === 'true' ||
            node.closest && node.closest('[disabled],[aria-disabled="true"]')
          );
          if (disabled) {
            return JSON.stringify({
              ok: false,
              error: verification.detected && !verification.completed
                ? 'Element is disabled because human verification is not complete'
                : 'Element is disabled',
              disabled: true,
              requires_user_verification: verification.detected && !verification.completed,
              human_verification: verification,
              title: document.title || '',
              url: location.href,
              selector: selector || '',
              label: desiredLabel || '',
              tag: (node.tagName || node.nodeName || '').toLowerCase(),
              text: accessibleText(node).slice(0, 160)
            });
          }
          try { node.dispatchEvent(new FocusEvent('focusin', { bubbles: true, cancelable: false, composed: true })); } catch (_) {}
          try { node.dispatchEvent(new FocusEvent('focus', { bubbles: false, cancelable: false, composed: true })); } catch (_) {}
          const tag = (node.tagName || node.nodeName || '').toLowerCase();
          if (tag === 'select' && node.options) {
            const wanted = norm(text);
            const options = Array.from(node.options);
            const match = options.find(option => option.value === text)
              || options.find(option => norm(option.textContent) === wanted)
              || options.find(option => norm(option.textContent).includes(wanted));
            node.value = match ? match.value : text;
          } else if (node.isContentEditable || attr(node, 'role') === 'textbox') {
            if (clear) {
              node.innerText = '';
            }
            node.innerText = (clear ? '' : textOf(node)) + text;
          } else if ('value' in node) {
            const current = clear ? '' : (node.value || '');
            const nextValue = current + text;
            const descriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(node), 'value')
              || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')
              || Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
            if (descriptor && descriptor.set) {
              descriptor.set.call(node, nextValue);
            } else {
              node.value = nextValue;
            }
          } else {
            node.textContent = (clear ? '' : textOf(node)) + text;
          }
          try {
            node.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, composed: true, data: text, inputType: clear ? 'insertText' : 'insertText' }));
          } catch (_) {
            try { node.dispatchEvent(new Event('input', { bubbles: true, cancelable: true, composed: true })); } catch (_) {}
          }
          try { node.dispatchEvent(new Event('change', { bubbles: true, cancelable: true, composed: true })); } catch (_) {}
          if (pressEnter) {
            const events = [
              new KeyboardEvent('keydown', { bubbles: true, cancelable: true, composed: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 }),
              new KeyboardEvent('keypress', { bubbles: true, cancelable: true, composed: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 }),
              new KeyboardEvent('keyup', { bubbles: true, cancelable: true, composed: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 })
            ];
            for (const event of events) {
              try { node.dispatchEvent(event); } catch (_) {}
            }
          }
          try { node.dispatchEvent(new FocusEvent('blur', { bubbles: false, cancelable: false, composed: true })); } catch (_) {}
          try { node.dispatchEvent(new FocusEvent('focusout', { bubbles: true, cancelable: false, composed: true })); } catch (_) {}
          if (document.activeElement && document.activeElement.blur) {
            try { document.activeElement.blur(); } catch (_) {}
          }
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            selector: selector || '',
            label: desiredLabel || '',
            text: textOf(node).slice(0, 160),
            value: node.value || '',
            tag,
            human_verification: verification
          });
        })();
        """

        guard let object = await evaluateJSONObject(script) else {
            return [
                "action": "browser.type",
                "ok": false,
                "error": "Unable to type into element"
            ]
        }
        var payload = object
        payload["action"] = "browser.type"
        let requiresVerification = Self.boolValue(payload["requires_user_verification"]) == true
        let typed = Self.boolValue(payload["ok"]) ?? false
        if requiresVerification {
            _ = await scrollToVisibleHumanVerification()
            payload["summary"] = "网页需要先完成人机验证，目标输入框当前不可用。请在浏览器中完成验证后继续。"
        } else if typed {
            payload["summary"] = "已向网页元素输入文本。"
        } else {
            payload["summary"] = (payload["error"] as? String) ?? "网页输入未完成。"
        }
        return payload
    }

    private func executeNativeHover(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.hover",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let selector = Self.firstString(in: call, keys: ["selector", "css", "element"])
        let label = Self.firstString(
            in: call,
            keys: [
                "label", "button_text", "buttonText", "aria_label", "ariaLabel",
                "field_label", "fieldLabel", "placeholder", "name", "title", "target"
            ]
        )
        let x = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"])
        let y = Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"])
        guard selector != nil || label != nil || (x != nil && y != nil) else {
            return [
                "action": "browser.hover",
                "ok": false,
                "error": "Missing selector, label, or coordinates"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const label = \(Self.javascriptString(label ?? ""));
          const x = \(x.map(String.init) ?? "null");
          const y = \(y.map(String.init) ?? "null");
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function rect(node) {
            if (!node || !node.getBoundingClientRect) return null;
            const r = node.getBoundingClientRect();
            return { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) };
          }
          function allRoots(root = document) {
            const roots = [root];
            const nodes = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : [];
            for (const node of nodes) {
              if (node.shadowRoot) roots.push(...allRoots(node.shadowRoot));
            }
            return roots;
          }
          function findNode(raw) {
            if (!raw) return null;
            try {
              if (raw.startsWith('/') || raw.startsWith('.//')) {
                const result = document.evaluate(raw, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                return result.singleNodeValue;
              }
              for (const root of allRoots()) {
                const found = root.querySelector(raw);
                if (found) return found;
              }
            } catch (_) {
              return null;
            }
            return null;
          }
          function labelFor(node) {
            if (!node) return '';
            const id = node.getAttribute && node.getAttribute('id');
            const labelledBy = node.getAttribute && node.getAttribute('aria-labelledby');
            const pieces = [
              text(node),
              node.getAttribute && node.getAttribute('aria-label'),
              node.getAttribute && node.getAttribute('title'),
              node.getAttribute && node.getAttribute('placeholder'),
              node.getAttribute && node.getAttribute('name'),
              node.getAttribute && node.getAttribute('value'),
              labelledBy ? labelledBy.split(/\\s+/).map(part => text(document.getElementById(part))).join(' ') : '',
              id ? Array.from(document.querySelectorAll(`label[for="${CSS.escape(id)}"]`)).map(text).join(' ') : '',
              node.closest && text(node.closest('label'))
            ];
            return pieces.filter(Boolean).join(' ');
          }
          function visible(node) {
            if (!node || !node.getBoundingClientRect) return false;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
            const r = node.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          function findByLabel(rawLabel) {
            const target = norm(rawLabel);
            if (!target) return null;
            const candidates = [];
            const selectors = 'button, a, input, textarea, select, [role="button"], [role="link"], [role="textbox"], [onclick], [tabindex]';
            for (const root of allRoots()) {
              try { candidates.push(...Array.from(root.querySelectorAll(selectors))); } catch (_) {}
            }
            let best = null;
            let bestScore = 0;
            for (const node of candidates) {
              if (!visible(node)) continue;
              const hay = norm(labelFor(node));
              if (!hay) continue;
              let score = 0;
              if (hay === target) score = 100;
              else if (hay.includes(target)) score = 80;
              else if (target.includes(hay) && hay.length >= 2) score = 55;
              if (score > bestScore) {
                best = node;
                bestScore = score;
              }
            }
            return best;
          }
          const node = findNode(selector) || findByLabel(label) || ((Number.isFinite(x) && Number.isFinite(y)) ? document.elementFromPoint(x, y) : null);
          if (!node) {
            return JSON.stringify({ ok: false, error: 'Element not found' });
          }
          if (node.scrollIntoView) {
            try { node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          }
          const target = node.closest && node.closest('button, a, input, textarea, select, [role="button"], [onclick]') || node;
          for (const name of ['pointerover', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) {
            try { target.dispatchEvent(new MouseEvent(name, { bubbles: true, cancelable: true, composed: true })); } catch (_) {}
          }
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            selector: selector || '',
            tag: (target.tagName || target.nodeName || '').toLowerCase(),
            text: text(target).slice(0, 160),
            href: target.href || '',
            rect: rect(target)
          });
        })();
        """

        guard let object = await evaluateJSONObject(script) else {
            return [
                "action": "browser.hover",
                "ok": false,
                "error": "Unable to hover element"
            ]
        }
        var payload = object
        payload["action"] = "browser.hover"
        payload["summary"] = "已悬停网页元素。"
        return payload
    }

    private func executeNativeScroll(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.scroll",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let selector = Self.firstString(in: call, keys: ["selector", "css"])
        let direction = Self.firstString(in: call, keys: ["direction"])?.lowercased() ?? "down"
        let amount = Self.intValue(call["amount"] ?? call["distance"] ?? call["pixels"]) ?? 500
        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const direction = \(Self.javascriptString(direction));
          const amount = \(amount);
          function findNode(raw) {
            if (!raw) return null;
            try {
              if (raw.startsWith('/') || raw.startsWith('.//')) {
                const result = document.evaluate(raw, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                return result.singleNodeValue;
              }
              return document.querySelector(raw);
            } catch (_) {
              return null;
            }
          }
          function bestScrollable() {
            const nodes = Array.from(document.querySelectorAll('*'));
            for (const node of nodes) {
              const style = window.getComputedStyle(node);
              const scrollableY = /(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 20;
              const scrollableX = /(auto|scroll)/.test(style.overflowX) && node.scrollWidth > node.clientWidth + 20;
              if (scrollableY || scrollableX) return node;
            }
            return document.scrollingElement || document.documentElement;
          }
          const node = findNode(selector) || bestScrollable();
          const delta = direction === 'up' ? -amount : amount;
          if (node === document.scrollingElement || node === document.documentElement || node === document.body) {
            window.scrollBy({ top: delta, left: 0, behavior: 'auto' });
          } else if (node && node.scrollBy) {
            node.scrollBy({ top: delta, left: 0, behavior: 'auto' });
          } else {
            window.scrollBy({ top: delta, left: 0, behavior: 'auto' });
          }
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            selector: selector || '',
            direction,
            amount,
            scrollY: Math.round(window.scrollY || 0),
            scrollX: Math.round(window.scrollX || 0),
            page: { width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight },
            viewport: { width: window.innerWidth, height: window.innerHeight }
          });
        })();
        """

        guard let object = await evaluateJSONObject(script) else {
            return [
                "action": "browser.scroll",
                "ok": false,
                "error": "Unable to scroll page"
            ]
        }
        var payload = object
        if let context = await evaluateJSONObject(Self.viewportContextScript(textLimit: 2200, elementLimit: 18)) {
            payload["viewport_context"] = context
            payload["visible_text"] = context["visible_text"] as? String ?? ""
            payload["visible_elements"] = context["interactive_elements"] as? [[String: Any]] ?? []
        }
        payload["action"] = "browser.scroll"
        if let visibleText = payload["visible_text"] as? String, !visibleText.isEmpty {
            payload["summary"] = "已滚动网页，并读取当前视口可见内容。"
        } else {
            payload["summary"] = "已滚动网页。"
        }
        return payload
    }

    private func executeNativeScrollAndCollect(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.scroll_and_collect",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let amount = Self.intValue(call["amount"] ?? call["distance"] ?? call["pixels"]) ?? 500
        let scrollCount = min(max(Self.intValue(call["scroll_count"] ?? call["count"]) ?? 10, 1), 20)
        let direction = Self.firstString(in: call, keys: ["direction"])?.lowercased() ?? "down"
        let itemSelector = Self.firstString(in: call, keys: ["item_selector", "itemSelector", "selector"])
        let collectSelector = itemSelector ?? "article, [role='listitem'], li, .item, .card, .post, .result"
        var collected: [[String: Any]] = []
        var seen = Set<String>()

        for _ in 0..<scrollCount {
            let collectScript = Self.elementCollectionScript(selector: collectSelector, limit: 24)
            if let snapshot = await evaluateJSONObject(collectScript),
               let items = snapshot["items"] as? [[String: Any]] {
                for item in items {
                    let key = [
                        item["link"] as? String ?? "",
                        item["text"] as? String ?? "",
                        item["title"] as? String ?? ""
                    ]
                    .joined(separator: "|")
                    .lowercased()
                    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          seen.insert(key).inserted else {
                        continue
                    }
                    collected.append(item)
                    if collected.count >= 50 { break }
                }
            }
            if collected.count >= 50 { break }
            _ = await executeNativeScroll([
                "action": "browser.scroll",
                "direction": direction,
                "amount": amount
            ])
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        let title = await currentPageTitle() ?? "网页"
        let url = await currentPageURL()?.absoluteString ?? ""
        return [
            "action": "browser.scroll_and_collect",
            "ok": true,
            "title": title,
            "url": url,
            "count": collected.count,
            "items": collected,
            "summary": collected.isEmpty ? "未收集到更多内容。" : "已滚动并收集 \(collected.count) 项内容。"
        ]
    }

    private func executeNativeFindElements(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.find_elements",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let defaultSelector = "a, button, input, textarea, select, [role='button'], [role='link'], [onclick], [tabindex], [aria-label]"
        let selector = Self.firstString(in: call, keys: ["selector", "css"]) ?? defaultSelector
        let limit = min(max(Self.intValue(call["limit"] ?? call["max_results"]) ?? 30, 1), 100)
        let intent = Self.findElementsIntent(in: call)
        let scanPage = Self.boolValue(call["scan_page"] ?? call["scanPage"] ?? call["full_page"] ?? call["fullPage"]) ?? true
        if scanPage {
            let maxScrolls = min(max(Self.intValue(call["max_scrolls"] ?? call["maxScrolls"] ?? call["scroll_count"] ?? call["count"]) ?? 16, 1), 20)
            return await executeNativeFindElementsAcrossPage(
                selector: selector,
                limit: limit,
                maxScrolls: maxScrolls,
                intent: intent
            )
        }

        let script = Self.elementCollectionScript(selector: selector, limit: limit, intent: intent)
        guard let object = await evaluateJSONObject(script) else {
            return [
                "action": "browser.find_elements",
                "ok": false,
                "error": "Unable to inspect page elements"
            ]
        }
        var payload = object
        payload["action"] = "browser.find_elements"
        payload["summary"] = "已找到网页元素。"
        return payload
    }

    private func executeNativeFindElementsAcrossPage(
        selector: String,
        limit: Int,
        maxScrolls: Int,
        intent: String?
    ) async -> [String: Any] {
        guard let metrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) else {
            return [
                "action": "browser.find_elements",
                "ok": false,
                "error": "Unable to inspect page elements"
            ]
        }

        let originalY = Self.intValue(metrics["scroll_y"]) ?? 0
        let viewportHeight = max(Self.intValue(metrics["viewport_height"]) ?? 720, 240)
        let scrollHeight = max(Self.intValue(metrics["scroll_height"]) ?? viewportHeight, viewportHeight)
        let maxY = max(scrollHeight - viewportHeight, 0)
        let step = max(Int(Double(viewportHeight) * 0.78), 240)
        var offsets = [0]
        if maxY > 0 {
            var nextY = 0
            while nextY < maxY {
                offsets.append(nextY)
                nextY += step
            }
            offsets.append(maxY)
        }
        var uniqueOffsets: [Int] = []
        var seenOffsets = Set<Int>()
        for offset in offsets {
            let clamped = min(max(offset, 0), maxY)
            guard seenOffsets.insert(clamped).inserted else { continue }
            uniqueOffsets.append(clamped)
        }

        let scrollOffsets: [Int]
        if uniqueOffsets.count <= maxScrolls {
            scrollOffsets = uniqueOffsets
        } else if maxScrolls == 1 {
            scrollOffsets = [uniqueOffsets.first ?? 0]
        } else {
            var sampled: [Int] = []
            let lastIndex = uniqueOffsets.count - 1
            for index in 0..<maxScrolls {
                let rawIndex = Double(index) * Double(lastIndex) / Double(maxScrolls - 1)
                let sampleIndex = min(max(Int(rawIndex.rounded()), 0), lastIndex)
                sampled.append(uniqueOffsets[sampleIndex])
            }
            var seenSamples = Set<Int>()
            scrollOffsets = sampled.filter { seenSamples.insert($0).inserted }
        }
        var collected: [[String: Any]] = []
        var viewportContexts: [[String: Any]] = []
        var visualViewports: [[String: Any]] = []
        var seen = Set<String>()
        var humanVerification: [String: Any]?
        let viewportCount = max(scrollOffsets.count, 1)
        let perViewportLimit = max(6, min(24, ((limit + viewportCount - 1) / viewportCount) + 4))
        let visualStride = max(1, Int(ceil(Double(viewportCount) / 6.0)))

        for (viewportIndex, offset) in scrollOffsets.enumerated() {
            _ = await evaluateJSONObject(Self.scrollToPageYScript(offset))
            try? await Task.sleep(nanoseconds: viewportIndex == 0 ? 180_000_000 : 300_000_000)

            if viewportIndex == 0 || viewportIndex == viewportCount - 1 || viewportIndex % visualStride == 0 {
                if let screenshot = await captureViewportScreenshot(prefix: "browser_scan_\(viewportIndex)", scrollY: offset) {
                    visualViewports.append([
                        "viewport_index": viewportIndex,
                        "scroll_y": offset,
                        "screenshot_url": screenshot.absoluteString,
                        "file_url": screenshot.absoluteString
                    ])
                }
            }

            if var context = await evaluateJSONObject(Self.viewportContextScript(textLimit: 900, elementLimit: 8)) {
                context["viewport_index"] = viewportIndex
                context["scroll_y"] = offset
                viewportContexts.append(context)
            }

            guard let snapshot = await evaluateJSONObject(Self.elementCollectionScript(
                selector: selector,
                limit: min(max(perViewportLimit * 3, 36), 120),
                intent: intent
            )),
                  let items = snapshot["items"] as? [[String: Any]] else {
                continue
            }
            if let verification = snapshot["human_verification"] as? [String: Any],
               Self.boolValue(verification["detected"]) == true {
                humanVerification = verification
            }

            var addedInViewport = 0
            for rawItem in items {
                let key = Self.elementIdentityKey(rawItem)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }

                var item = rawItem
                item["index"] = collected.count
                item["viewport_index"] = viewportIndex
                item["scroll_y"] = offset
                if let rect = item["rect"] as? [String: Any] {
                    if let pageX = Self.intValue(rect["page_x"]) {
                        item["page_x"] = pageX
                    }
                    if let pageY = Self.intValue(rect["page_y"]) {
                        item["page_y"] = pageY
                    }
                    if let pageCenterX = Self.intValue(rect["page_center_x"]) {
                        item["page_center_x"] = pageCenterX
                    }
                    if let pageCenterY = Self.intValue(rect["page_center_y"]) {
                        item["page_center_y"] = pageCenterY
                    }
                }
                collected.append(item)
                addedInViewport += 1
                if addedInViewport >= perViewportLimit { break }
            }
        }

        _ = await evaluateJSONObject(Self.scrollToPageYScript(originalY))
        let returnedItems = Self.prioritizedElements(collected, limit: limit)
        let verification = humanVerification ?? ["detected": false]
        let verificationDetected = Self.boolValue(verification["detected"]) == true
        let verificationCompleted = Self.boolValue(verification["completed"]) == true
        let summary: String
        if verificationDetected && !verificationCompleted {
            _ = await scrollToVisibleHumanVerification()
            summary = collected.isEmpty
                ? "网页存在未完成的人机验证，整页扫描后未找到匹配网页元素。"
                : "网页存在未完成的人机验证；已滚动扫描整页并找到 \(collected.count) 个网页元素，返回其中 \(returnedItems.count) 个代表项。"
        } else {
            summary = collected.isEmpty
                ? "整页扫描后未找到匹配网页元素。"
                : "已滚动扫描整页并找到 \(collected.count) 个网页元素，返回其中 \(returnedItems.count) 个代表项。"
        }

        return [
            "action": "browser.find_elements",
            "ok": true,
            "title": metrics["title"] as? String ?? "",
            "url": metrics["url"] as? String ?? "",
            "selector": selector,
            "scan_page": true,
            "scroll_positions": scrollOffsets.count,
            "scroll_height": scrollHeight,
            "viewport_height": viewportHeight,
            "human_verification": verification,
            "requires_user_verification": verificationDetected && !verificationCompleted,
            "count": returnedItems.count,
            "total_count": collected.count,
            "viewport_contexts": viewportContexts,
            "visual_viewports": visualViewports,
            "attach_file": false,
            "preview_images": visualViewports.compactMap { $0["screenshot_url"] as? String },
            "items": returnedItems,
            "summary": visualViewports.isEmpty ? summary : "\(summary) 已同步截取 \(visualViewports.count) 个滚动视口用于视觉核对。"
        ]
    }

    private func executeNativeBackbone(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.get_backbone",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let maxDepth = min(max(Self.intValue(call["max_depth"] ?? call["depth"]) ?? 5, 1), 8)
        let script = Self.backboneScript(maxDepth: maxDepth)
        guard let object = await evaluateJSONObject(script) else {
            return [
                "action": "browser.get_backbone",
                "ok": false,
                "error": "Unable to build page backbone"
            ]
        }
        var payload = object
        payload["action"] = "browser.get_backbone"
        payload["summary"] = "已生成网页结构概览。"
        return payload
    }

    private func executeNativeExecuteJavaScript(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.execute_js",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        let script = Self.firstString(in: call, keys: ["script"])
        guard let script, !script.isEmpty else {
            return [
                "action": "browser.execute_js",
                "ok": false,
                "error": "Missing required field: script"
            ]
        }
        let wrapped = """
        (async () => {
          try {
            const result = await (async () => {
              \(script)
            })();
            const safe = result === undefined ? null : result;
            return JSON.stringify({
              ok: true,
              title: document.title || '',
              url: location.href,
              result: safe
            });
          } catch (error) {
            return JSON.stringify({
              ok: false,
              title: document.title || '',
              url: location.href,
              error: String(error && error.message ? error.message : error)
            });
          }
        })();
        """
        guard let object = await evaluateJSONObject(wrapped) else {
            return [
                "action": "browser.execute_js",
                "ok": false,
                "error": "Unable to execute JavaScript"
            ]
        }
        var payload = object
        payload["action"] = "browser.execute_js"
        payload["summary"] = (payload["ok"] as? Bool) == true ? "已执行网页脚本。" : "网页脚本执行失败。"
        return payload
    }

    private func executeNativeSetViewport(_ call: [String: Any]) async -> [String: Any] {
        if Self.boolValue(call["reset"] ?? call["clear"]) == true {
            browserViewportSize = CGSize(width: 390, height: 720)
        } else if let width = Self.intValue(call["viewport_width"] ?? call["width"]),
                  let height = Self.intValue(call["viewport_height"] ?? call["height"]) {
            browserViewportSize = CGSize(
                width: CGFloat(min(max(width, 240), 4096)),
                height: CGFloat(min(max(height, 240), 4096))
            )
        } else {
            return [
                "action": "browser.set_viewport",
                "ok": false,
                "error": "Missing viewport_width and viewport_height"
            ]
        }

        for tab in browserTabs.values {
            tab.frame = CGRect(
                x: -10_000,
                y: -10_000,
                width: browserViewportSize.width,
                height: browserViewportSize.height
            )
            tab.setNeedsLayout()
            tab.layoutIfNeeded()
        }
        webView?.frame = CGRect(
            x: -10_000,
            y: -10_000,
            width: browserViewportSize.width,
            height: browserViewportSize.height
        )
        return [
            "action": "browser.set_viewport",
            "ok": true,
            "viewport": [
                "width": Int(browserViewportSize.width.rounded()),
                "height": Int(browserViewportSize.height.rounded())
            ],
            "summary": "已更新浏览器视口。"
        ]
    }

    private func executeNativeCookies(_ call: [String: Any]) async -> [String: Any] {
        let wv = webViewReady()
        let currentURL = wv.url
        let host = currentURL?.host?.lowercased() ?? ""
        let siteRoot = Self.cookieSiteRoot(for: host)
        let keywords = Self.keywordList(in: call)
        let fuzzy = Self.boolValue(call["fuzzy"]) ?? true

        let cookies = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }

        let filtered = cookies.filter { cookie in
            guard Self.cookieMatchesSite(cookie.domain, host: host, siteRoot: siteRoot) else { return false }
            guard !keywords.isEmpty else { return true }
            let name = cookie.name.lowercased()
            if fuzzy {
                return keywords.allSatisfy { name.contains($0.lowercased()) }
            }
            return keywords.contains { name == $0.lowercased() }
        }

        let payloadCookies = filtered.prefix(50).map { cookie -> [String: Any] in
            var item: [String: Any] = [
                "name": cookie.name,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure
            ]
            if let expires = cookie.expiresDate {
                item["expires_at"] = ISO8601DateFormatter().string(from: expires)
            }
            if let httpOnly = cookie.properties?[HTTPCookiePropertyKey("HttpOnly")] {
                item["http_only"] = String(describing: httpOnly)
            }
            return item
        }

        return [
            "action": "browser.get_cookies",
            "ok": true,
            "url": currentURL?.absoluteString ?? "",
            "site_root": siteRoot,
            "cookies": payloadCookies,
            "count": payloadCookies.count,
            "summary": payloadCookies.isEmpty ? "当前站点没有可用 cookie。" : "已读取当前站点 cookie。"
        ]
    }

    private func executeNativeSetUserAgent(_ call: [String: Any]) -> [String: Any] {
        let profile = Self.firstString(in: call, keys: ["user_agent", "userAgent", "profile"]) ?? "mobile_safari"
        applyBrowserUserAgent(profile)
        return [
            "action": "browser.set_user_agent",
            "ok": true,
            "user_agent": browserUserAgentProfile,
            "summary": "已更新浏览器 User-Agent。"
        ]
    }

    private func executeNativeWaitForDOMStable(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.wait_for_dom_stable",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        let timeout = TimeInterval(Self.intValue(call["timeout"] ?? call["timeout_seconds"]) ?? 10)
        let deadline = Date().addingTimeInterval(min(max(timeout, 1), 30))
        var history: [String] = []
        var stableCount = 0

        while Date() < deadline {
            let script = """
            (() => JSON.stringify({
              title: document.title || '',
              url: location.href,
              readyState: document.readyState,
              textLength: (document.body && document.body.innerText ? document.body.innerText.length : 0),
              scrollHeight: document.documentElement.scrollHeight,
              childCount: document.body ? document.body.children.length : 0,
              resourceCount: performance.getEntriesByType ? performance.getEntriesByType('resource').length : 0
            }))();
            """
            guard let object = await evaluateJSONObject(script) else {
                break
            }
            let fingerprint = [
                object["readyState"] as? String ?? "",
                String(describing: object["textLength"] ?? 0),
                String(describing: object["scrollHeight"] ?? 0),
                String(describing: object["childCount"] ?? 0),
                String(describing: object["resourceCount"] ?? 0)
            ]
            .joined(separator: "|")
            history.append(fingerprint)
            if history.count >= 2, history[history.count - 1] == history[history.count - 2] {
                stableCount += 1
            } else {
                stableCount = 0
            }
            if (object["readyState"] as? String) == "complete" && stableCount >= 2 {
                var payload = object
                payload["action"] = "browser.wait_for_dom_stable"
                payload["ok"] = true
                payload["samples"] = Array(history.suffix(6))
                payload["summary"] = "网页 DOM 已稳定。"
                return payload
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return [
            "action": "browser.wait_for_dom_stable",
            "ok": false,
            "samples": Array(history.suffix(6)),
            "error": "Timed out waiting for DOM stability"
        ]
    }

    private func executeNativeWaitForImage(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14)) {
            return [
                "action": "browser.wait_for_image",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }

        let timeout = TimeInterval(Self.intValue(call["timeout"] ?? call["timeout_seconds"]) ?? 45)
        let deadline = Date().addingTimeInterval(min(max(timeout, 3), 90))
        let minWidth = max(Self.intValue(call["min_width"]) ?? 160, 32)
        let minHeight = max(Self.intValue(call["min_height"]) ?? 160, 32)
        let attachPreview = Self.boolValue(call["attach_preview"] ?? call["attachPreview"] ?? call["show_in_chat"] ?? call["showInChat"]) ?? false
        let query = Self.firstString(in: call, keys: ["query", "keywords", "hint"])
        var lastCandidates: [[String: Any]] = []

        while Date() < deadline {
            if let object = await evaluateJSONObject(Self.generatedImageCandidateScript(
                minWidth: minWidth,
                minHeight: minHeight,
                query: query
            )) {
                let candidates = object["candidates"] as? [[String: Any]] ?? []
                lastCandidates = candidates
                if let candidate = candidates.first,
                   let saved = await saveBrowserImageCandidate(candidate) {
                    return [
                        "action": "browser.wait_for_image",
                        "ok": true,
                        "title": object["title"] as? String ?? "生成图片",
                        "url": object["url"] as? String ?? "",
                        "file_url": saved.url.absoluteString,
                        "file_name": saved.url.lastPathComponent,
                        "content_type": saved.contentType,
                        "attach_file": true,
                        "bytes": saved.byteCount,
                        "image_width": candidate["width"] as? Int ?? 0,
                        "image_height": candidate["height"] as? Int ?? 0,
                        "source_url": candidate["src"] as? String ?? "",
                        "preview_images": [saved.url.absoluteString],
                        "items": [[
                            "title": "生成图片",
                            "link": saved.url.absoluteString,
                            "snippet": "已等待并保存网页生成的图片。",
                            "thumbnail_url": saved.url.absoluteString
                        ]],
                        "summary": "已等待到网页生成图片并保存为附件：\(saved.url.lastPathComponent)"
                    ]
                }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let thumbnail = attachPreview ? await capturePageThumbnail(prefix: "browser_image_timeout") : nil
        var payload: [String: Any] = [
            "action": "browser.wait_for_image",
            "ok": false,
            "attach_file": attachPreview,
            "candidate_count": lastCandidates.count,
            "candidates": Array(lastCandidates.prefix(5)),
            "error": "Timed out waiting for a generated image"
        ]
        if let thumbnail {
            payload["preview_images"] = [thumbnail.absoluteString]
            payload["items"] = [[
                "title": "页面截图",
                "link": thumbnail.absoluteString,
                "snippet": "等待图片超时，已保存当前页面截图。",
                "thumbnail_url": thumbnail.absoluteString
            ]]
        }
        return payload
    }

    private func saveBrowserImageCandidate(_ candidate: [String: Any]) async -> (url: URL, contentType: String, byteCount: Int)? {
        let source = [
            candidate["data_url"] as? String,
            candidate["src"] as? String,
            candidate["href"] as? String
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let data: Data
        let contentType: String
        if let decoded = Self.decodeDataURL(trimmed) {
            data = decoded.data
            contentType = decoded.contentType
        } else if let url = URL(string: trimmed),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            do {
                var request = URLRequest(url: url, timeoutInterval: 24)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                    forHTTPHeaderField: "User-Agent"
                )
                let (downloaded, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      downloaded.count > 512 else {
                    return nil
                }
                data = downloaded
                contentType = http.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first
                    ?? Self.imageContentType(fromURL: url)
                    ?? "image/png"
            } catch {
                return nil
            }
        } else {
            return nil
        }

        guard contentType.lowercased().hasPrefix("image/"),
              data.count > 512 else {
            return nil
        }

        do {
            let folder = try browserOutputDirectory()
            let suggested = (candidate["alt"] as? String)
                ?? (candidate["title"] as? String)
                ?? "generated-image"
            let fileName = Self.safeDownloadFileName(
                suggested,
                fallbackExtension: Self.fileExtension(for: contentType)
            )
            let stamped = "\(Int(Date().timeIntervalSince1970 * 1000))_\(fileName)"
            let fileURL = folder.appendingPathComponent(stamped)
            try data.write(to: fileURL, options: [.atomic])
            return (fileURL, contentType, data.count)
        } catch {
            return nil
        }
    }

    private func executeNativeNewTab(_ call: [String: Any]) async -> [String: Any] {
        guard browserTabs.count < 3 else {
            return [
                "action": "browser.new_tab",
                "ok": false,
                "error": "Maximum of 3 tabs reached"
            ]
        }
        let tabID = nextBrowserTabID
        nextBrowserTabID += 1
        let webView = makeBrowserWebView()
        browserTabs[tabID] = webView
        activeBrowserTabID = tabID
        self.webView = webView
        mountActiveBrowserIfPresented()

        if let url = Self.urlValue(in: call) {
            _ = await load(url: url, timeout: 14)
        }

        let title = await currentPageTitle() ?? "新标签页"
        return [
            "action": "browser.new_tab",
            "ok": true,
            "tab_id": tabID,
            "title": title,
            "url": await currentPageURL()?.absoluteString ?? "about:blank",
            "summary": "已打开新标签页。"
        ]
    }

    private func executeNativeCloseTab(_ call: [String: Any]) async -> [String: Any] {
        let tabID = Self.intValue(call["tab_id"] ?? call["tabId"]) ?? activeBrowserTabID
        guard let closing = browserTabs[tabID] else {
            return [
                "action": "browser.close_tab",
                "ok": false,
                "error": "Tab not found"
            ]
        }
        closing.removeFromSuperview()
        browserTabs.removeValue(forKey: tabID)
        browserHumanVerificationSeenTabs.remove(tabID)
        browserHumanVerificationCompletedAtByTab.removeValue(forKey: tabID)
        browserHumanVerificationCompletedURLByTab.removeValue(forKey: tabID)

        if browserTabs.isEmpty {
            let replacement = makeBrowserWebView()
            browserTabs[1] = replacement
            activeBrowserTabID = 1
            self.webView = replacement
            mountActiveBrowserIfPresented()
        } else if activeBrowserTabID == tabID {
            let nextTabID = browserTabs.keys.sorted().last ?? 1
            activeBrowserTabID = nextTabID
            self.webView = browserTabs[nextTabID]
            mountActiveBrowserIfPresented()
        }

        return [
            "action": "browser.close_tab",
            "ok": true,
            "tab_id": tabID,
            "active_tab_id": activeBrowserTabID,
            "tab_count": browserTabs.count,
            "summary": "已关闭标签页。"
        ]
    }

    private func executeNativeListTabs(_ call: [String: Any]) async -> [String: Any] {
        let tabs = browserTabs
            .sorted { $0.key < $1.key }
            .map { tabID, tab in
                [
                    "tab_id": tabID,
                    "title": tab.title ?? "",
                    "url": tab.url?.absoluteString ?? "",
                    "active": tabID == activeBrowserTabID
                ] as [String: Any]
            }
        return [
            "action": "browser.list_tabs",
            "ok": true,
            "active_tab_id": activeBrowserTabID,
            "tab_count": tabs.count,
            "tabs": tabs,
            "summary": "已列出标签页。"
        ]
    }

    private func currentPageTitle() async -> String? {
        guard let object = await evaluateJSONObject("""
        (() => JSON.stringify({ title: document.title || '', url: location.href }))();
        """) else {
            return webView?.title
        }
        return object["title"] as? String
    }

    private func currentPageURL() async -> URL? {
        if let object = await evaluateJSONObject("""
        (() => JSON.stringify({ url: location.href }))();
        """), let raw = object["url"] as? String {
            return URL(string: raw)
        }
        return webView?.url
    }

    private func evaluateJSONObject(_ script: String) async -> [String: Any]? {
        guard let json = await evaluateString(script),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func applyBrowserUserAgent(_ profile: String) {
        let normalized = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedProfile = normalized.isEmpty ? "mobile_safari" : normalized
        browserUserAgentProfile = resolvedProfile
        let userAgent = Self.browserUserAgentOverride(profile: resolvedProfile)
        for tab in browserTabs.values {
            tab.customUserAgent = userAgent
        }
        webView?.customUserAgent = userAgent
    }

    private func activateBrowserTab(_ tabID: Int) {
        guard let tab = browserTabs[tabID] else { return }
        activeBrowserTabID = tabID
        webView = tab
        mountActiveBrowserIfPresented()
    }

    private static func browserUserAgentOverride(profile: String) -> String? {
        switch profile.lowercased() {
        case "mobile_safari", "system", "system_default", "default":
            return nil
        case "mobile_chrome":
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0.6478.54 Mobile/15E148 Safari/604.1"
        case "desktop_chrome":
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        default:
            return nil
        }
    }

    private static func browserUseActionName(_ requestedAction: String?, call: [String: Any]) -> String {
        let normalized = requestedAction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let hasURL = urlValue(in: call) != nil
        let wantsSave = Self.firstString(in: call, keys: ["save_to", "output", "path"]) != nil
        let hasScript = Self.firstString(in: call, keys: ["script", "javascript", "js"]) != nil
        let hasTypedText = Self.firstString(in: call, keys: ["text", "value", "input", "content", "message"]) != nil
        let hasSelector = Self.firstString(in: call, keys: ["selector", "css", "element"]) != nil
        let hasLabel = Self.firstString(in: call, keys: [
            "label", "button_text", "buttonText", "aria_label", "ariaLabel",
            "name", "title", "placeholder", "target"
        ]) != nil
        let hasCoordinates = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"]) != nil
            && Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"]) != nil
        let wantsScreenshot = Self.boolValue(call["screenshot"] ?? call["with_screenshot"] ?? call["thumbnail"] ?? call["attach_preview"] ?? call["attachPreview"] ?? call["full_page"] ?? call["fullPage"]) == true

        switch normalized {
        case "", "browser_use", "browser.use":
            if wantsSave { return "browser.fetch" }
            if hasScript { return "browser.execute_js" }
            if hasTypedText && (hasSelector || hasLabel || hasCoordinates) { return "browser.type" }
            if hasLabel || hasCoordinates { return "browser.click" }
            if hasSelector && wantsScreenshot { return "browser.screenshot" }
            if hasSelector { return "browser.find_elements" }
            if wantsScreenshot { return "browser.screenshot" }
            if hasURL { return "browser.navigate" }
            return "browser.info"
        case "navigate", "open", "goto", "go", "go_to", "go_to_url", "browser.navigate", "browser.open":
            return "browser.navigate"
        case "readable", "get_readable", "read_webpage", "browser.readable":
            return "browser.readable"
        case "text", "get_text", "browser.text":
            return "browser.text"
        case "info", "get_page_info", "browser.info":
            return "browser.info"
        case "screenshot", "browser.screenshot":
            return "browser.screenshot"
        case "fetch", "download", "browser.fetch":
            return "browser.fetch"
        case "click", "browser.click":
            return "browser.click"
        case "type", "browser.type":
            return "browser.type"
        case "hover", "browser.hover":
            return "browser.hover"
        case "scroll", "browser.scroll":
            return "browser.scroll"
        case "scroll_and_collect", "browser.scroll_and_collect":
            return "browser.scroll_and_collect"
        case "find_elements", "browser.find_elements":
            return "browser.find_elements"
        case "get_backbone", "browser.get_backbone":
            return "browser.get_backbone"
        case "execute_js", "browser.execute_js":
            return "browser.execute_js"
        case "set_viewport", "browser.set_viewport":
            return "browser.set_viewport"
        case "set_user_agent", "browser.set_user_agent":
            return "browser.set_user_agent"
        case "get_cookies", "browser.get_cookies":
            return "browser.get_cookies"
        case "wait_for_dom_stable", "browser.wait_for_dom_stable":
            return "browser.wait_for_dom_stable"
        case "wait_for_image", "wait_image", "image_result", "browser.wait_for_image":
            return "browser.wait_for_image"
        case "new_tab", "browser.new_tab":
            return "browser.new_tab"
        case "close_tab", "browser.close_tab":
            return "browser.close_tab"
        case "list_tabs", "browser.list_tabs":
            return "browser.list_tabs"
        default:
            if wantsSave { return "browser.fetch" }
            if hasURL { return "browser.navigate" }
            return normalized.isEmpty ? "browser.info" : normalized
        }
    }

    private static func cookieSiteRoot(for host: String) -> String {
        guard !host.isEmpty else { return "" }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func cookieMatchesSite(_ cookieDomain: String, host: String, siteRoot: String) -> Bool {
        let domain = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let currentHost = host.lowercased()
        let root = siteRoot.lowercased()
        return currentHost == domain
            || currentHost.hasSuffix("." + domain)
            || domain.hasSuffix(currentHost)
            || (!root.isEmpty && (domain == root || domain.hasSuffix("." + root)))
    }

    private static func keywordList(in call: [String: Any]) -> [String] {
        let raw = firstString(in: call, keys: ["keywords", "keyword", "query"]) ?? ""
        return raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func pageScrollMetricsScript() -> String {
        """
        (() => {
          const doc = document.documentElement;
          const body = document.body || doc;
          const scrollHeight = Math.max(
            doc.scrollHeight || 0,
            body.scrollHeight || 0,
            doc.offsetHeight || 0,
            body.offsetHeight || 0,
            doc.clientHeight || 0
          );
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            scroll_y: Math.round(window.scrollY || doc.scrollTop || body.scrollTop || 0),
            scroll_x: Math.round(window.scrollX || doc.scrollLeft || body.scrollLeft || 0),
            scroll_height: Math.round(scrollHeight),
            scroll_width: Math.round(Math.max(doc.scrollWidth || 0, body.scrollWidth || 0, doc.clientWidth || 0)),
            viewport_height: Math.round(window.innerHeight || doc.clientHeight || 0),
            viewport_width: Math.round(window.innerWidth || doc.clientWidth || 0)
          });
        })();
        """
    }

    private static func scrollToPageYScript(_ y: Int) -> String {
        """
        (() => {
          const y = \(max(y, 0));
          const doc = document.scrollingElement || document.documentElement || document.body;
          if (doc && doc.scrollTo) {
            doc.scrollTo({ top: y, left: 0, behavior: 'auto' });
          } else {
            window.scrollTo(0, y);
          }
          return JSON.stringify({
            ok: true,
            scroll_y: Math.round(window.scrollY || (doc && doc.scrollTop) || 0)
          });
        })();
        """
    }

    private static func viewportContextScript(textLimit: Int, elementLimit: Int) -> String {
        """
        (() => {
          const textLimit = \(max(textLimit, 0));
          const elementLimit = \(max(elementLimit, 0));
          const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
          const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
          function clean(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim();
          }
          function visibleRect(el) {
            if (!el || !el.getBoundingClientRect) return null;
            const rect = el.getBoundingClientRect();
            const width = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
            const height = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
            if (width < 2 || height < 2) return null;
            return {
              x: Math.round(rect.left),
              y: Math.round(rect.top),
              page_x: Math.round(rect.left + (window.scrollX || 0)),
              page_y: Math.round(rect.top + (window.scrollY || 0)),
              width: Math.round(rect.width),
              height: Math.round(rect.height)
            };
          }
          function isVisible(el) {
            const rect = visibleRect(el);
            if (!rect) return false;
            const style = window.getComputedStyle(el);
            return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity || 1) > 0.01;
          }
          const interactiveSelector = [
            'a[href]', 'button', 'input', 'textarea', 'select', 'summary',
            '[role="button"]', '[role="link"]', '[role="menuitem"]',
            '[tabindex]:not([tabindex="-1"])', '[contenteditable="true"]'
          ].join(',');
          const elements = Array.from(document.querySelectorAll(interactiveSelector))
            .filter(isVisible)
            .slice(0, elementLimit)
            .map((el, index) => {
              const rect = visibleRect(el) || {};
              return {
                index,
                tag: (el.tagName || '').toLowerCase(),
                text: clean(el.innerText || el.textContent).slice(0, 180),
                aria_label: clean(el.getAttribute('aria-label')).slice(0, 180),
                title: clean(el.getAttribute('title')).slice(0, 180),
                placeholder: clean(el.getAttribute('placeholder')).slice(0, 180),
                href: clean(el.getAttribute('href')).slice(0, 300),
                role: clean(el.getAttribute('role')),
                id: clean(el.id),
                rect
              };
            });
          const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
              const value = clean(node.nodeValue);
              if (!value) return NodeFilter.FILTER_REJECT;
              const parent = node.parentElement;
              if (!parent || !isVisible(parent)) return NodeFilter.FILTER_REJECT;
              return NodeFilter.FILTER_ACCEPT;
            }
          });
          const chunks = [];
          let total = 0;
          while (walker.nextNode() && total < textLimit) {
            const value = clean(walker.currentNode.nodeValue);
            if (!value) continue;
            chunks.push(value);
            total += value.length + 1;
          }
          const visibleText = clean(chunks.join(' ')).slice(0, textLimit);
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            scroll_y: Math.round(window.scrollY || 0),
            viewport_width: Math.round(viewportWidth),
            viewport_height: Math.round(viewportHeight),
            visible_text: visibleText,
            interactive_elements: elements
          });
        })();
        """
    }

    private static func elementIdentityKey(_ item: [String: Any]) -> String {
        var semanticParts: [String] = []
        var tagPart: String?
        for key in ["href", "id", "aria_label", "name", "role", "title", "text", "tag"] {
            if let value = item[key] as? String {
                let normalized = value
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if !normalized.isEmpty {
                    if key == "tag" {
                        tagPart = "tag:\(normalized)"
                    } else {
                        semanticParts.append("\(key):\(normalized)")
                    }
                }
            }
        }
        if !semanticParts.isEmpty {
            if let tagPart {
                semanticParts.append(tagPart)
            }
            return semanticParts.joined(separator: "|")
        }
        if let rect = item["rect"] as? [String: Any] {
            let pageX = Self.intValue(rect["page_x"] ?? rect["x"]) ?? 0
            let pageY = Self.intValue(rect["page_y"] ?? rect["y"]) ?? 0
            let width = Self.intValue(rect["width"]) ?? 0
            let height = Self.intValue(rect["height"]) ?? 0
            return "\(tagPart ?? "node")|rect:\(pageX):\(pageY):\(width):\(height)"
        }
        return tagPart ?? ""
    }

    private static func evenlySampleElements(_ items: [[String: Any]], limit: Int) -> [[String: Any]] {
        guard limit > 0, items.count > limit else { return items }
        if limit == 1 { return [items[0]] }
        var sampled: [[String: Any]] = []
        let lastIndex = items.count - 1
        for index in 0..<limit {
            let rawIndex = Double(index) * Double(lastIndex) / Double(limit - 1)
            let sampleIndex = min(max(Int(rawIndex.rounded()), 0), lastIndex)
            var item = items[sampleIndex]
            item["index"] = sampled.count
            sampled.append(item)
        }
        return sampled
    }

    private static func prioritizedElements(_ items: [[String: Any]], limit: Int) -> [[String: Any]] {
        guard limit > 0, items.count > limit else { return items }
        let hasPositiveScore = items.contains { (Self.intValue($0["match_score"]) ?? 0) > 0 }
        guard hasPositiveScore else { return Self.evenlySampleElements(items, limit: limit) }
        let ranked = items.enumerated().sorted { lhs, rhs in
            let lhsScore = Self.intValue(lhs.element["match_score"]) ?? 0
            let rhsScore = Self.intValue(rhs.element["match_score"]) ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsY = Self.elementPageY(lhs.element) ?? Int.max
            let rhsY = Self.elementPageY(rhs.element) ?? Int.max
            if lhsY != rhsY { return lhsY < rhsY }
            return lhs.offset < rhs.offset
        }
        return ranked.prefix(limit).enumerated().map { index, rankedItem in
            var item = rankedItem.element
            item["index"] = index
            return item
        }
    }

    private static func elementPageY(_ item: [String: Any]) -> Int? {
        if let direct = Self.intValue(item["page_y"]) {
            return direct
        }
        if let rect = item["rect"] as? [String: Any] {
            return Self.intValue(rect["page_y"] ?? rect["y"])
        }
        return nil
    }

    private static func findElementsIntent(in call: [String: Any]) -> String? {
        let keys = [
            "query", "q", "keywords", "keyword", "label", "button_text", "buttonText",
            "aria_label", "ariaLabel", "name", "title", "text", "placeholder",
            "tool_title", "toolTitle", "description", "target"
        ]
        let parts = keys.compactMap { key -> String? in
            guard let value = call[key] else { return nil }
            if let string = value as? String { return string }
            if let strings = value as? [String] { return strings.joined(separator: " ") }
            return nil
        }
        let intent = parts
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return intent.isEmpty ? nil : intent
    }

    private static func elementCollectionScript(selector: String, limit: Int, intent: String? = nil) -> String {
        """
        (() => {
          const selector = \(Self.javascriptString(selector));
          const limit = \(limit);
          const intent = \(Self.javascriptString(intent ?? ""));
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
          function tokenize(value) {
            const normalized = norm(value);
            const tokens = normalized.split(/[\\s,，、]+/).map(token => token.trim()).filter(Boolean);
            return tokens.length ? tokens : (normalized ? [normalized] : []);
          }
          const intentNorm = norm(intent);
          const intentTokens = Array.from(new Set(tokenize(intentNorm)));
          function attr(node, name) {
            return node && node.getAttribute ? (node.getAttribute(name) || '') : '';
          }
          function href(node) {
            if (!node) return '';
            try {
              if (node.getAttribute) {
                const raw = node.getAttribute('href') || node.getAttribute('data-href') || node.getAttribute('data-url') || '';
                if (raw) return new URL(raw, location.href).href;
              }
              return node.href || '';
            } catch (_) {
              return '';
            }
          }
          function accessibleText(node) {
            if (!node) return '';
            const parts = [
              text(node),
              node.getAttribute ? node.getAttribute('aria-label') : '',
              node.getAttribute ? node.getAttribute('title') : '',
              node.getAttribute ? node.getAttribute('alt') : '',
              node.getAttribute ? node.getAttribute('name') : '',
              node.getAttribute ? node.getAttribute('value') : '',
              node.getAttribute ? node.getAttribute('placeholder') : '',
              node.getAttribute ? node.getAttribute('data-testid') : '',
              node.value || '',
              node.placeholder || ''
            ];
            return parts.filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim();
          }
          function rect(node) {
            if (!node || !node.getBoundingClientRect) return null;
            const r = node.getBoundingClientRect();
            const pageX = r.x + window.scrollX;
            const pageY = r.y + window.scrollY;
            return {
              x: Math.round(r.x),
              y: Math.round(r.y),
              page_x: Math.round(pageX),
              page_y: Math.round(pageY),
              page_center_x: Math.round(pageX + r.width / 2),
              page_center_y: Math.round(pageY + r.height / 2),
              width: Math.round(r.width),
              height: Math.round(r.height),
              center_x: Math.round(r.x + r.width / 2),
              center_y: Math.round(r.y + r.height / 2)
            };
          }
          function visible(node) {
            if (!node || !node.getBoundingClientRect) return false;
            if (node.hidden || (node.closest && node.closest('[hidden],[aria-hidden="true"]'))) return false;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) === 0) return false;
            const r = node.getBoundingClientRect();
            return r.width > 1 && r.height > 1 && r.bottom >= 0 && r.right >= 0 && r.top <= innerHeight && r.left <= innerWidth;
          }
          function allRoots() {
            const roots = [document];
            for (let i = 0; i < roots.length; i += 1) {
              const root = roots[i];
              const nodes = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : [];
              for (const node of nodes) {
                if (node.shadowRoot) roots.push(node.shadowRoot);
              }
            }
            return roots;
          }
          function findElements(raw) {
            const seen = new Set();
            const results = [];
            for (const root of allRoots()) {
              try {
                for (const node of Array.from(root.querySelectorAll(raw))) {
                  if (seen.has(node)) continue;
                  seen.add(node);
                  results.push(node);
                }
              } catch (_) {}
            }
            return results;
          }
          function disabledState(node) {
            if (!node) return false;
            return Boolean(
              node.disabled ||
              node.getAttribute && node.getAttribute('aria-disabled') === 'true' ||
              node.closest && node.closest('[disabled],[aria-disabled="true"]')
            );
          }
          function humanVerificationState() {
            const turnstile = document.querySelector('[name="cf-turnstile-response"], input[id^="cf-chl-widget"], .cf-turnstile, [data-sitekey]');
            const recaptcha = document.querySelector('[name="g-recaptcha-response"], .g-recaptcha, iframe[src*="recaptcha"]');
            const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || frame.getAttribute('aria-label') || '').join(' ');
            const bodyText = (document.body && document.body.innerText || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            const textDetected = /prove you are human|verify you are human|checking if the site connection is secure|captcha|turnstile|recaptcha/.test(bodyText);
            const frameDetected = /turnstile|captcha|recaptcha|challenge/.test(frames.toLowerCase());
            const tokenNode = turnstile || recaptcha;
            const tokenLength = tokenNode && 'value' in tokenNode ? String(tokenNode.value || '').length : 0;
            const provider = turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (frameDetected || textDetected ? 'human_verification' : ''));
            return {
              detected: Boolean(provider),
              provider,
              token_length: tokenLength,
              completed: Boolean(tokenLength > 0)
            };
          }
          function scoreElement(node, label, nodeHref) {
            if (!intentNorm) return 0;
            const tag = norm(node && (node.tagName || node.nodeName) || '');
            const role = norm(attr(node, 'role'));
            const type = norm(attr(node, 'type'));
            const strong = norm([
              label,
              attr(node, 'aria-label'),
              attr(node, 'title'),
              attr(node, 'alt'),
              attr(node, 'name'),
              attr(node, 'placeholder'),
              attr(node, 'value'),
              node && node.value || '',
              node && node.placeholder || ''
            ].join(' '));
            const weak = norm([
              nodeHref,
              node && node.id || '',
              node && typeof node.className === 'string' ? node.className : '',
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              tag,
              role,
              type
            ].join(' '));
            let score = 0;
            if (strong === intentNorm) score += 1000;
            else if (strong.startsWith(intentNorm)) score += 650;
            else if (strong.includes(intentNorm)) score += 450;
            if (weak === intentNorm) score += 220;
            else if (weak.includes(intentNorm)) score += 140;
            for (const token of intentTokens) {
              if (!token) continue;
              if (strong === token) score += 240;
              else if (strong.startsWith(token)) score += 170;
              else if (strong.includes(token)) score += 110;
              if (weak === token) score += 80;
              else if (weak.includes(token)) score += 35;
              if (tag === token || role === token || type === token) score += 30;
            }
            if (score > 0 && (tag === 'button' || tag === 'a' || role === 'button' || role === 'link' || attr(node, 'onclick'))) score += 10;
            if (score > 0 && disabledState(node)) score -= 10;
            return Math.max(0, Math.round(score));
          }
          function itemY(item) {
            const value = item && item.rect ? Number(item.rect.page_y) : NaN;
            return Number.isFinite(value) ? value : 1000000000;
          }
          function compareItems(a, b) {
            if (b.match_score !== a.match_score) return b.match_score - a.match_score;
            const ay = itemY(a);
            const by = itemY(b);
            if (ay !== by) return ay - by;
            return (a.source_index || 0) - (b.source_index || 0);
          }
          const humanVerification = humanVerificationState();
          const elements = findElements(selector).filter(visible);
          let items = elements.map((node, sourceIndex) => {
            const label = accessibleText(node);
            const nodeHref = href(node);
            const disabled = disabledState(node);
            return {
              index: sourceIndex,
              source_index: sourceIndex,
              tag: (node.tagName || node.nodeName || '').toLowerCase(),
              title: label.slice(0, 120),
              text: label.slice(0, 240),
              href: nodeHref,
              id: node.id || '',
              classes: typeof node.className === 'string' ? node.className : '',
              placeholder: node.placeholder || '',
              role: attr(node, 'role'),
              aria_label: attr(node, 'aria-label'),
              name: attr(node, 'name'),
              value: attr(node, 'value') || node.value || '',
              type: attr(node, 'type'),
              disabled,
              blocked_by_human_verification: disabled && humanVerification.detected && !humanVerification.completed,
              match_score: scoreElement(node, label, nodeHref),
              rect: rect(node)
            };
          });
          if (intentNorm) items.sort(compareItems);
          items = items.slice(0, limit).map((item, index) => {
            item.index = index;
            return item;
          });
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            selector,
            human_verification: humanVerification,
            count: items.length,
            items
          });
        })();
        """
    }

    private static func generatedImageCandidateScript(minWidth: Int, minHeight: Int, query: String?) -> String {
        let queryWords = (query ?? "")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
            .map(String.init)
            .filter { !$0.isEmpty }
        let queryJSON = (try? JSONSerialization.data(withJSONObject: queryWords))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
          const minWidth = \(minWidth);
          const minHeight = \(minHeight);
          const queryWords = \(queryJSON);
          const seen = new Set();
          function visible(node) {
            if (!node) return false;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) === 0) return false;
            const r = node.getBoundingClientRect();
            return r.width >= 20 && r.height >= 20 && r.bottom >= 0 && r.right >= 0 && r.top <= innerHeight * 2 && r.left <= innerWidth * 2;
          }
          function absoluteURL(value) {
            if (!value) return '';
            if (value.startsWith('data:image/')) return value;
            if (value.startsWith('blob:')) return value;
            try { return new URL(value, location.href).href; } catch (_) { return value; }
          }
          function imageLike(value) {
            const lower = String(value || '').toLowerCase();
            return lower.startsWith('data:image/') || lower.startsWith('blob:') || /\\.(png|jpe?g|webp|gif|bmp|avif|heic)(\\?|#|$)/.test(lower);
          }
          function text(node) {
            return ((node && (node.innerText || node.textContent)) || '').replace(/\\s+/g, ' ').trim();
          }
          function dataURLFromImage(img) {
            try {
              if (!img || !img.naturalWidth || !img.naturalHeight) return '';
              const canvas = document.createElement('canvas');
              canvas.width = img.naturalWidth;
              canvas.height = img.naturalHeight;
              const ctx = canvas.getContext('2d');
              if (!ctx) return '';
              ctx.drawImage(img, 0, 0);
              return canvas.toDataURL('image/png');
            } catch (_) {
              return '';
            }
          }
          function scoreCandidate(item) {
            let score = 0;
            if (item.width >= minWidth && item.height >= minHeight) score += 30;
            score += Math.min(30, Math.round((item.width * item.height) / 20000));
            const joined = [item.alt, item.title, item.text, item.src].join(' ').toLowerCase();
            if (/download|result|generated|output|image|photo|preview|保存|下载|生成|结果|图片|预览/.test(joined)) score += 20;
            for (const word of queryWords) if (word && joined.includes(word)) score += 5;
            if (item.src && item.src.startsWith('data:image/')) score += 10;
            if (item.src && item.src.startsWith('blob:')) score += 8;
            return score;
          }
          function push(items, raw) {
            const src = absoluteURL(raw.src || raw.href || raw.data_url || '');
            if (!src || !imageLike(src) || seen.has(src)) return;
            seen.add(src);
            const item = {
              src,
              href: raw.href ? absoluteURL(raw.href) : '',
              data_url: raw.data_url || '',
              width: Math.round(raw.width || 0),
              height: Math.round(raw.height || 0),
              alt: raw.alt || '',
              title: raw.title || '',
              text: raw.text || '',
              selector: raw.selector || ''
            };
            if (item.width < minWidth && item.height < minHeight && !src.startsWith('data:image/')) return;
            item.score = scoreCandidate(item);
            items.push(item);
          }
          const items = [];
          for (const img of Array.from(document.images || [])) {
            if (!visible(img)) continue;
            const r = img.getBoundingClientRect();
            const src = img.currentSrc || img.src || img.getAttribute('data-src') || img.getAttribute('data-original') || '';
            push(items, {
              src,
              data_url: String(src || '').startsWith('blob:') ? dataURLFromImage(img) : '',
              width: img.naturalWidth || r.width,
              height: img.naturalHeight || r.height,
              alt: img.alt || '',
              title: img.title || '',
              text: text(img.closest('figure, article, div, section') || img.parentElement),
              selector: img.id ? `#${img.id}` : ''
            });
          }
          for (const a of Array.from(document.querySelectorAll('a[href]'))) {
            const href = a.href || a.getAttribute('href') || '';
            if (!imageLike(href)) continue;
            const r = a.getBoundingClientRect();
            push(items, {
              src: href,
              href,
              width: r.width || minWidth,
              height: r.height || minHeight,
              title: a.title || '',
              text: text(a),
              selector: a.id ? `#${a.id}` : ''
            });
          }
          let canvasDataURLCount = 0;
          for (const canvas of Array.from(document.querySelectorAll('canvas'))) {
            if (!visible(canvas)) continue;
            const r = canvas.getBoundingClientRect();
            if (r.width < minWidth || r.height < minHeight) continue;
            if (canvasDataURLCount >= 2) continue;
            try {
              const dataURL = canvas.toDataURL('image/png');
              canvasDataURLCount += 1;
              push(items, {
                src: dataURL,
                data_url: dataURL,
                width: canvas.width || r.width,
                height: canvas.height || r.height,
                title: canvas.title || '',
                text: text(canvas.closest('figure, article, div, section') || canvas.parentElement),
                selector: canvas.id ? `#${canvas.id}` : 'canvas'
              });
            } catch (_) {}
          }
          items.sort((a, b) => b.score - a.score);
          return JSON.stringify({
            ok: items.length > 0,
            title: document.title || '',
            url: location.href,
            candidates: items.slice(0, 8)
          });
        })();
        """
    }

    private static func backboneScript(maxDepth: Int) -> String {
        """
        (() => {
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function simplify(node, depth) {
            if (!node || depth > \(maxDepth)) return null;
            const children = [];
            for (const child of Array.from(node.children || []).slice(0, 6)) {
              const item = simplify(child, depth + 1);
              if (item) children.push(item);
            }
            return {
              tag: (node.tagName || node.nodeName || '').toLowerCase(),
              id: node.id || '',
              role: node.getAttribute ? (node.getAttribute('role') || '') : '',
              text: text(node).slice(0, 120),
              children
            };
          }
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            backbone: simplify(document.body || document.documentElement, 0)
          });
        })();
        """
    }

    private func makeBrowserWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(
            frame: CGRect(
                x: -10_000,
                y: -10_000,
                width: browserViewportSize.width,
                height: browserViewportSize.height
            ),
            configuration: config
        )
        wv.customUserAgent = Self.browserUserAgentOverride(profile: browserUserAgentProfile)
        wv.isHidden = false
        wv.alpha = 1
        wv.navigationDelegate = self
        attachToWindow(wv)
        return wv
    }

    func attachAutomationBrowser(
        to container: UIView,
        initialURL: URL?,
        navigationDelegate: WKNavigationDelegate?,
        uiDelegate: WKUIDelegate?
    ) -> WKWebView {
        automationBrowserContainer = container
        automationBrowserNavigationDelegate = navigationDelegate
        automationBrowserUIDelegate = uiDelegate
        let tab = webViewReady()
        mountAutomationBrowser(tab, in: container)
        if tab.url == nil, let initialURL {
            loadInitialAutomationURL(initialURL, in: tab)
        }
        notifyActiveBrowserDidChange()
        return tab
    }

    func detachAutomationBrowser(_ detachedWebView: WKWebView?) {
        guard automationBrowserContainer != nil else { return }
        automationBrowserContainer = nil
        automationBrowserNavigationDelegate = nil
        automationBrowserUIDelegate = nil
        for tab in browserTabs.values {
            tab.navigationDelegate = self
            tab.uiDelegate = nil
        }
        let active = webView ?? detachedWebView
        if let active {
            attachToWindow(active)
        }
    }

    func updateAutomationBrowserViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        browserViewportSize = size
        if let container = automationBrowserContainer {
            syncAutomationBrowserViewport(to: container)
        }
        if let webView, isAutomationBrowserVisible(webView) {
            webView.frame = CGRect(origin: .zero, size: size)
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
            webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
        }
    }

    func browserWebViewDidFinishNavigation(_ source: WKWebView) {
        guard isKnownBrowserWebView(source) else { return }
        resolveNavigation(true)
        notifyActiveBrowserDidChange()
        notifyHumanVerificationStateIfNeeded(from: source)
    }

    func browserWebViewDidFailNavigation(_ source: WKWebView) {
        guard isKnownBrowserWebView(source) else { return }
        resolveNavigation(false)
        notifyActiveBrowserDidChange()
        notifyHumanVerificationStateIfNeeded(from: source)
    }

    func currentAutomationBrowserURL() -> URL {
        webView?.url ?? URL(string: "about:blank")!
    }

    func waitForVisibleHumanVerificationCompletion(timeout: TimeInterval = 120) async -> Bool {
        _ = await scrollToVisibleHumanVerification()
        let deadline = Date().addingTimeInterval(timeout)
        var sawChallenge = false
        var missingChallengeCount = 0
        while Date() < deadline {
            if let probe = await evaluateJSONObject(Self.visibleChallengeProbeScript()) {
                let detected = Self.boolValue(probe["detected"]) == true
                let completed = Self.boolValue(probe["completed"]) == true
                if detected {
                    sawChallenge = true
                    missingChallengeCount = 0
                } else if sawChallenge {
                    missingChallengeCount += 1
                }
                if completed || (sawChallenge && missingChallengeCount >= 2) {
                    var completedProbe = probe
                    completedProbe["completed"] = true
                    notifyHumanVerificationState(completedProbe)
                    return true
                }
                notifyHumanVerificationState(probe)
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        return false
    }

    private func resolveBrowserTab(for tabID: Int? = nil, createIfMissing: Bool = true) -> WKWebView {
        if let tabID, let tab = browserTabs[tabID] {
            activeBrowserTabID = tabID
            webView = tab
            mountActiveBrowserIfPresented()
            return tab
        }
        if let active = browserTabs[activeBrowserTabID] {
            webView = active
            mountActiveBrowserIfPresented()
            return active
        }
        if let last = browserTabs.keys.sorted().last, let tab = browserTabs[last] {
            activeBrowserTabID = last
            webView = tab
            mountActiveBrowserIfPresented()
            return tab
        }
        let tab = makeBrowserWebView()
        let newID = tabID ?? 1
        activeBrowserTabID = newID
        nextBrowserTabID = max(nextBrowserTabID, newID + 1)
        browserTabs[newID] = tab
        webView = tab
        mountActiveBrowserIfPresented()
        return tab
    }

    private func capturePageThumbnail(prefix: String) async -> URL? {
        let wv = webViewReady()
        let visibleInAutomationBrowser = isAutomationBrowserVisible(wv)
        let width = visibleInAutomationBrowser ? max(wv.bounds.width, 1) : browserViewportSize.width
        let height = visibleInAutomationBrowser ? max(wv.bounds.height, 1) : browserViewportSize.height
        wv.isHidden = false
        wv.alpha = 1
        if !visibleInAutomationBrowser {
            wv.frame = CGRect(x: -10_000, y: -10_000, width: width, height: height)
            wv.scrollView.setContentOffset(.zero, animated: false)
        }
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

    private func captureViewportScreenshot(prefix: String, scrollY: Int? = nil) async -> URL? {
        let wv = webViewReady()
        let visibleInAutomationBrowser = isAutomationBrowserVisible(wv)
        let width = visibleInAutomationBrowser ? max(wv.bounds.width, 1) : browserViewportSize.width
        let height = visibleInAutomationBrowser ? max(wv.bounds.height, 1) : browserViewportSize.height
        let originalOffset = wv.scrollView.contentOffset

        wv.isHidden = false
        wv.alpha = 1
        if !visibleInAutomationBrowser {
            wv.frame = CGRect(x: -10_000, y: -10_000, width: width, height: height)
        }
        if let scrollY {
            let maxY = max(wv.scrollView.contentSize.height - height, 0)
            let clampedY = min(max(CGFloat(scrollY), 0), maxY)
            wv.scrollView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
        }
        wv.setNeedsLayout()
        wv.layoutIfNeeded()
        wv.scrollView.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 120_000_000)

        guard let image = await captureVisibleWebViewImage(width: width, height: height),
              let data = image.pngData() else {
            if scrollY != nil {
                wv.scrollView.setContentOffset(originalOffset, animated: false)
            }
            return nil
        }

        if scrollY != nil {
            wv.scrollView.setContentOffset(originalOffset, animated: false)
        }
        do {
            let folder = try browserOutputDirectory()
            let fileURL = folder.appendingPathComponent("\(prefix)_\(Int(Date().timeIntervalSince1970 * 1000)).png")
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            logger.debug("Browser viewport snapshot write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func captureFullPageScreenshot(prefix: String) async -> URL? {
        let wv = webViewReady()
        let visibleInAutomationBrowser = isAutomationBrowserVisible(wv)
        let width = visibleInAutomationBrowser ? max(wv.bounds.width, 1) : browserViewportSize.width
        let viewportHeight = visibleInAutomationBrowser ? max(wv.bounds.height, 1) : browserViewportSize.height
        wv.isHidden = false
        wv.alpha = 1
        if !visibleInAutomationBrowser {
            wv.frame = CGRect(x: -10_000, y: -10_000, width: width, height: viewportHeight)
        }
        wv.setNeedsLayout()
        wv.layoutIfNeeded()

        let originalOffset = wv.scrollView.contentOffset
        let contentHeight = max(wv.scrollView.contentSize.height, viewportHeight)
        let maxCaptureHeight: CGFloat = 16_000
        let targetHeight = min(contentHeight, maxCaptureHeight)
        let stepHeight = max(viewportHeight * 0.86, 240)
        var offsets: [CGFloat] = [0]
        if targetHeight > viewportHeight {
            var nextY: CGFloat = 0
            while nextY < targetHeight - viewportHeight {
                offsets.append(nextY)
                nextY += stepHeight
            }
            offsets.append(max(targetHeight - viewportHeight, 0))
        }

        var uniqueOffsets: [CGFloat] = []
        var seenOffsets = Set<Int>()
        for offset in offsets {
            let clamped = min(max(offset, 0), max(targetHeight - viewportHeight, 0))
            let key = Int(clamped.rounded())
            guard seenOffsets.insert(key).inserted else { continue }
            uniqueOffsets.append(clamped)
        }

        var pieces: [(image: UIImage, offsetY: CGFloat)] = []
        for offset in uniqueOffsets.prefix(28) {
            wv.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            wv.scrollView.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let image = await captureVisibleWebViewImage(width: width, height: viewportHeight) else {
                continue
            }
            pieces.append((image, offset))
        }
        wv.scrollView.setContentOffset(originalOffset, animated: false)

        guard !pieces.isEmpty else { return nil }
        let scale = pieces.first?.image.scale ?? UIScreen.main.scale
        let outputSize = CGSize(width: width, height: targetHeight)
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = true
            return format
        }())
        let stitched = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            for piece in pieces {
                let drawHeight = min(viewportHeight, targetHeight - piece.offsetY)
                guard drawHeight > 0 else { continue }
                let destinationRect = CGRect(x: 0, y: piece.offsetY, width: width, height: piece.image.size.height)
                context.cgContext.saveGState()
                context.cgContext.clip(to: CGRect(x: 0, y: piece.offsetY, width: width, height: drawHeight))
                piece.image.draw(in: destinationRect, blendMode: .normal, alpha: 1)
                context.cgContext.restoreGState()
            }
        }
        guard let data = stitched.pngData() else { return nil }
        do {
            let folder = try browserOutputDirectory()
            let suffix = contentHeight > maxCaptureHeight ? "_truncated" : ""
            let fileURL = folder.appendingPathComponent("\(prefix)\(suffix)_\(Int(Date().timeIntervalSince1970 * 1000)).png")
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            logger.debug("Browser full-page snapshot write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func captureVisibleWebViewImage(width: CGFloat, height: CGFloat) async -> UIImage? {
        let wv = webViewReady()
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        config.snapshotWidth = NSNumber(value: Double(width))
        return await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: config) { image, error in
                if let error {
                    self.logger.debug("Browser visible snapshot failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
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

    private static func fullPageDocument(
        from snapshot: BrowserPageSnapshot,
        fallbackTitle: String?,
        fallbackURL: String,
        provider: String
    ) -> WebSearchDocument {
        let resolvedURL = snapshot.url.isEmpty ? fallbackURL : snapshot.url
        let resolvedTitle = snapshot.title.isEmpty
            ? ((fallbackTitle?.isEmpty == false ? fallbackTitle : nil) ?? resolvedURL)
            : snapshot.title
        let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = [
            "Title: \(resolvedTitle)",
            "URL: \(resolvedURL)"
        ]
        if !snapshot.description.isEmpty {
            sections.append("Description: \(snapshot.description)")
        }
        if !snapshot.published.isEmpty {
            sections.append("Published/Updated: \(snapshot.published)")
        }
        sections.append("Content excerpt:\n\(String(text.prefix(18_000)))")

        var metadata = [
            "title": resolvedTitle,
            "source": resolvedURL,
            "link": resolvedURL,
            "provider": provider,
            "full_page": "true",
            "searched_at": ISO8601DateFormatter().string(from: Date())
        ]
        if !snapshot.published.isEmpty {
            metadata["published_time"] = snapshot.published
        }
        return WebSearchDocument(content: sections.joined(separator: "\n"), metadata: metadata)
    }

    private static func documentMatches(_ document: WebSearchDocument, url: String, alternateURL: String?) -> Bool {
        let targets = [url, alternateURL].compactMap { normalizedURLKey($0) }
        guard !targets.isEmpty else { return false }
        return [document.metadata["source"], document.metadata["link"]]
            .compactMap { normalizedURLKey($0) }
            .contains { targets.contains($0) }
    }

    private static func documentPayloadMatches(_ payload: [String: Any], url: String, alternateURL: String?) -> Bool {
        let source: String?
        let link: String?
        if let metadata = payload["metadata"] as? [String: String] {
            source = metadata["source"]
            link = metadata["link"]
        } else if let metadata = payload["metadata"] as? [String: Any] {
            source = metadata["source"] as? String
            link = metadata["link"] as? String
        } else {
            return false
        }
        let targets = [url, alternateURL].compactMap { normalizedURLKey($0) }
        guard !targets.isEmpty else { return false }
        return [source, link]
            .compactMap { normalizedURLKey($0) }
            .contains { targets.contains($0) }
    }

    private static func normalizedURLKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }
        components.fragment = nil
        let normalized = components.string ?? trimmed
        return normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private static func urlValue(in call: [String: Any], allowLocalFiles: Bool = true) -> URL? {
        guard let raw = firstString(in: call, keys: ["url", "link", "href", "page_url", "source", "input_url"]),
              let url = URL(string: raw) else {
            return nil
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https"].contains(scheme) {
            return url
        }
        if allowLocalFiles, scheme == "file" {
            return url
        }
        return nil
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

    private static func decodeDataURL(_ value: String) -> (contentType: String, data: Data)? {
        guard value.lowercased().hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ",") else {
            return nil
        }
        let header = String(value[value.index(value.startIndex, offsetBy: "data:".count)..<comma])
        let body = String(value[value.index(after: comma)...])
        let contentType = header.components(separatedBy: ";").first ?? "image/png"
        let data: Data?
        if header.lowercased().contains(";base64") {
            data = Data(base64Encoded: body)
        } else {
            data = body.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data else { return nil }
        return (contentType, data)
    }

    private static func imageContentType(fromURL url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "bmp":
            return "image/bmp"
        case "avif":
            return "image/avif"
        case "heic":
            return "image/heic"
        default:
            return nil
        }
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
        let pattern = ##"filename\*?=(?:UTF-8''|")?([^";]+)"?"##
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

        guard let snapshot = await evaluateFullPageSnapshot(maxScrolls: 14),
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
        sections.append("Content excerpt:\n\(String(snapshot.text.prefix(12_000)))")

        var metadata = [
            "title": title,
            "source": snapshot.url.isEmpty ? rawLink : snapshot.url,
            "link": snapshot.url.isEmpty ? rawLink : snapshot.url,
            "provider": "wkwebview_browser_page",
            "full_page": "true",
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

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

    private func load(url: URL, timeout: TimeInterval, forceReload: Bool = false) async -> Bool {
        let wv = webViewReady()
        if !forceReload, shouldReuseCurrentPage(for: url, in: wv) {
            lastBrowserNavigationReusedExistingPage = true
            notifyActiveBrowserDidChange()
            return true
        }
        lastBrowserNavigationReusedExistingPage = false
        timeoutTask?.cancel()
        navigationContinuation?.resume(returning: false)
        navigationContinuation = nil

        let loaded: Bool = await withCheckedContinuation { continuation in
            navigationContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.logger.warning("Browser search navigation timed out: \(url.absoluteString, privacy: .public)")
                self.resolveNavigation(false)
            }
            if url.isFileURL {
                let readAccessURL = url.deletingLastPathComponent()
                wv.loadFileURL(url, allowingReadAccessTo: readAccessURL)
            } else {
                var request = URLRequest(url: url, timeoutInterval: timeout)
                request.cachePolicy = .useProtocolCachePolicy
                if let userAgent = Self.browserUserAgentOverride(profile: browserUserAgentProfile) {
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                }
                request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
                wv.load(request)
            }
        }
        return loaded
    }

    private func shouldReuseCurrentPage(for targetURL: URL, in webView: WKWebView) -> Bool {
        guard !targetURL.isFileURL,
              let currentURL = webView.url,
              Self.isHTTPBrowserURL(currentURL),
              Self.isHTTPBrowserURL(targetURL) else {
            return false
        }

        if Self.browserURLsAreEquivalent(currentURL, targetURL) {
            return true
        }

        guard let tabID = browserTabID(for: webView),
              let completedAt = browserHumanVerificationCompletedAtByTab[tabID],
              Date().timeIntervalSince(completedAt) <= humanVerificationPageReuseWindow,
              let completedURL = browserHumanVerificationCompletedURLByTab[tabID],
              Self.browserHostsMatch(completedURL, targetURL),
              Self.browserHostsMatch(currentURL, targetURL),
              Self.browserPathsAreCompatibleAfterVerification(currentURL, targetURL) else {
            return false
        }
        return true
    }

    private func browserTabID(for source: WKWebView?) -> Int? {
        guard let source else { return nil }
        return browserTabs.first { $0.value === source }?.key
    }

    private static func isHTTPBrowserURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func browserURLsAreEquivalent(_ lhs: URL, _ rhs: URL) -> Bool {
        guard browserHostsMatch(lhs, rhs),
              normalizedBrowserPath(lhs.path) == normalizedBrowserPath(rhs.path) else {
            return false
        }
        let lhsQuery = lhs.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rhsQuery = rhs.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rhsQuery.isEmpty || lhsQuery == rhsQuery
    }

    private static func browserHostsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              !lhsHost.isEmpty,
              !rhsHost.isEmpty else {
            return false
        }
        return lhsHost == rhsHost
            || lhsHost.hasSuffix(".\(rhsHost)")
            || rhsHost.hasSuffix(".\(lhsHost)")
    }

    private static func browserPathsAreCompatibleAfterVerification(_ currentURL: URL, _ targetURL: URL) -> Bool {
        let currentPath = normalizedBrowserPath(currentURL.path)
        let targetPath = normalizedBrowserPath(targetURL.path)
        return currentPath == targetPath || targetPath == "/"
    }

    private static func normalizedBrowserPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let withLeadingSlash = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        let withoutTrailingSlash = withLeadingSlash.count > 1 && withLeadingSlash.hasSuffix("/")
            ? String(withLeadingSlash.dropLast())
            : withLeadingSlash
        return withoutTrailingSlash.isEmpty ? "/" : withoutTrailingSlash
    }

    private func webViewReady() -> WKWebView {
        return resolveBrowserTab()
    }

    private func attachToWindow(_ webView: WKWebView) {
        guard !isAutomationBrowserVisible(webView) else { return }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        window?.addSubview(webView)
        window?.sendSubviewToBack(webView)
    }

    private func mountActiveBrowserIfPresented() {
        guard let container = automationBrowserContainer,
              let webView else {
            return
        }
        mountAutomationBrowser(webView, in: container)
        notifyActiveBrowserDidChange()
    }

    private func syncAutomationBrowserViewport(to container: UIView) {
        let size = container.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        browserViewportSize = size
        for tab in browserTabs.values {
            if tab.superview === container {
                tab.frame = container.bounds
                tab.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                tab.setNeedsLayout()
                tab.layoutIfNeeded()
            } else {
                tab.frame = CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height)
            }
        }
    }

    private func mountAutomationBrowser(_ webView: WKWebView, in container: UIView) {
        let movedFromBackgroundSession = webView.superview !== container
        for tab in browserTabs.values where tab !== webView && tab.superview === container {
            tab.removeFromSuperview()
            tab.navigationDelegate = self
            tab.uiDelegate = nil
            attachToWindow(tab)
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.navigationDelegate = automationBrowserNavigationDelegate ?? self
        webView.uiDelegate = automationBrowserUIDelegate
        webView.isHidden = false
        webView.alpha = 1
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = container.bounds
        syncAutomationBrowserViewport(to: container)
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        if movedFromBackgroundSession {
            refreshVisibleChallengePageIfNeeded(webView)
        }
    }

    private func refreshVisibleChallengePageIfNeeded(_ webView: WKWebView) {
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return
        }
        let key = url.absoluteString
        guard !browserVisibleChallengeRefreshURLs.contains(key) else { return }

        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, let webView,
                  self.webView === webView,
                  self.isAutomationBrowserVisible(webView),
                  webView.url?.absoluteString == key,
                  let probe = await self.evaluateJSONObject(Self.visibleChallengeProbeScript()) else {
                return
            }
            let detected = Self.boolValue(probe["detected"]) == true
            let completed = Self.boolValue(probe["completed"]) == true
            let failedState = Self.boolValue(probe["failed_state"]) == true
            guard detected, failedState, !completed else { return }
            if self.hasRecentHumanVerificationCompletion(in: webView, matching: url) {
                return
            }
            self.browserVisibleChallengeRefreshURLs.insert(key)
            webView.reload()
        }
    }

    private func hasRecentHumanVerificationCompletion(in webView: WKWebView, matching url: URL) -> Bool {
        guard let tabID = browserTabID(for: webView),
              let completedAt = browserHumanVerificationCompletedAtByTab[tabID],
              Date().timeIntervalSince(completedAt) <= humanVerificationPageReuseWindow,
              let completedURL = browserHumanVerificationCompletedURLByTab[tabID] else {
            return false
        }
        return Self.browserHostsMatch(completedURL, url)
    }

    private func scrollToVisibleHumanVerification() async -> Bool {
        guard let object = await evaluateJSONObject(Self.scrollToHumanVerificationScript()) else {
            return false
        }
        return Self.boolValue(object["scrolled"]) == true
    }

    private func notifyHumanVerificationStateIfNeeded(from source: WKWebView) {
        Task { @MainActor [weak self, weak source] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self,
                  let source,
                  self.webView === source,
                  let probe = await self.evaluateJSONObject(Self.visibleChallengeProbeScript()) else {
                return
            }
            self.notifyHumanVerificationState(probe)
        }
    }

    private func notifyHumanVerificationState(_ probe: [String: Any]) {
        let detected = Self.boolValue(probe["detected"]) == true
        let explicitCompleted = Self.boolValue(probe["completed"]) == true
        let completed = explicitCompleted || !detected
        if let tabID = browserTabID(for: webView) {
            if detected {
                browserHumanVerificationSeenTabs.insert(tabID)
            }
            if detected && !explicitCompleted {
                browserHumanVerificationCompletedAtByTab.removeValue(forKey: tabID)
                browserHumanVerificationCompletedURLByTab.removeValue(forKey: tabID)
                if let currentURL = webView?.url {
                    browserVisibleChallengeRefreshURLs.remove(currentURL.absoluteString)
                }
            }
            if completed,
               (explicitCompleted || browserHumanVerificationSeenTabs.contains(tabID)),
               let currentURL = webView?.url,
               Self.isHTTPBrowserURL(currentURL) {
                browserHumanVerificationCompletedAtByTab[tabID] = Date()
                browserHumanVerificationCompletedURLByTab[tabID] = currentURL
                browserVisibleChallengeRefreshURLs.insert(currentURL.absoluteString)
                if !detected {
                    browserHumanVerificationSeenTabs.remove(tabID)
                }
            }
        }
        NotificationCenter.default.post(
            name: .browserWebSearchServiceHumanVerificationStateDidChange,
            object: webView,
            userInfo: [
                "detected": detected,
                "completed": completed,
                "failed_state": Self.boolValue(probe["failed_state"]) == true,
                "url": webView?.url?.absoluteString ?? "",
                "title": webView?.title ?? ""
            ]
        )
    }

    private static func scrollToHumanVerificationScript() -> String {
        """
        (() => {
          const pattern = /prove you are human|verify you are human|checking if the site connection is secure|checking your browser|captcha|turnstile|recaptcha|cf-challenge|cloudflare|验证您是真人|请验证您是真人|正在检查|人机验证|验证失败|故障排除/i;
          const selectorList = [
            '[name="cf-turnstile-response"]',
            'input[id^="cf-chl-widget"]',
            '.cf-turnstile',
            '[data-sitekey]',
            '[name="g-recaptcha-response"]',
            '.g-recaptcha',
            '[class*="turnstile" i]',
            '[class*="captcha" i]',
            '[id*="turnstile" i]',
            '[id*="captcha" i]',
            '[id*="challenge" i]',
            'iframe[src*="turnstile" i]',
            'iframe[src*="recaptcha" i]',
            'iframe[src*="challenge" i]',
            'iframe[title*="challenge" i]',
            'iframe[title*="captcha" i]',
            'iframe[title*="verification" i]',
            'iframe[title*="cloudflare" i]'
          ];
          const viewportH = Math.max(window.innerHeight || 0, document.documentElement.clientHeight || 0, 1);
          const viewportW = Math.max(window.innerWidth || 0, document.documentElement.clientWidth || 0, 1);
          const textOf = node => [
            node.id || '',
            node.className || '',
            node.name || '',
            node.title || '',
            node.getAttribute && node.getAttribute('aria-label') || '',
            node.getAttribute && node.getAttribute('data-sitekey') || '',
            node.src || '',
            node.innerText || '',
            node.textContent || ''
          ].join(' ').replace(/\\s+/g, ' ').trim();
          const rectOf = node => {
            const r = node && node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            return r ? { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left } : null;
          };
          const visible = node => {
            const r = rectOf(node);
            if (!r) return false;
            const style = getComputedStyle(node);
            return r.width > 1 && r.height > 1 && style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
          };
          const centerDistancePenalty = node => {
            const r = rectOf(node);
            if (!r) return 0;
            const cx = r.left + r.width / 2;
            const cy = r.top + r.height / 2;
            return Math.abs(cx - viewportW / 2) / Math.max(viewportW, 1) + Math.abs(cy - viewportH / 2) / Math.max(viewportH, 1);
          };
          const candidates = [];
          const addCandidate = (node, reason, baseScore) => {
            if (!node || !visible(node)) return;
            const text = textOf(node);
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const r = rectOf(node);
            let score = baseScore || 0;
            if (pattern.test(text)) score += 35;
            if (/iframe/.test(tag)) score += 20;
            if (/cf-|cloudflare|turnstile|captcha|recaptcha|challenge/i.test(text)) score += 30;
            if (r.width >= 80 && r.height >= 40 && r.width <= viewportW * 1.1 && r.height <= viewportH * 0.9) score += 10;
            if (r.height > viewportH * 1.2 || r.width > viewportW * 1.4) score -= 30;
            score -= centerDistancePenalty(node) * 3;
            candidates.push({ node, reason, score, text, rect: r });
          };
          for (const selector of selectorList) {
            let nodes = [];
            try { nodes = Array.from(document.querySelectorAll(selector)).slice(0, 30); } catch (_) { nodes = []; }
            for (const node of nodes) {
              addCandidate(node, selector, 50);
              const box = node.closest && node.closest('.cf-turnstile, .g-recaptcha, form, section, main, [role="main"], div');
              if (box && box !== node) addCandidate(box, selector + ' container', 18);
            }
          }
          const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT);
          let walked = 0;
          let node;
          while ((node = walker.nextNode()) && walked < 1800) {
            walked += 1;
            if (!visible(node)) continue;
            const text = textOf(node);
            if (pattern.test(text)) addCandidate(node, 'text', 25);
          }
          candidates.sort((a, b) => b.score - a.score);
          const best = candidates[0];
          if (!best || best.score < 20) {
            return JSON.stringify({ scrolled: false, reason: 'verification target not found', url: location.href, candidates: candidates.slice(0, 3).map(c => ({ reason: c.reason, score: Math.round(c.score), text: c.text.slice(0, 120) })) });
          }
          const target = best.node;
          const targetRect = target.getBoundingClientRect();
          const pageX = targetRect.left + window.scrollX + targetRect.width / 2;
          const pageY = targetRect.top + window.scrollY + targetRect.height / 2;
          let parent = target.parentElement;
          while (parent && parent !== document.body && parent !== document.documentElement) {
            const style = getComputedStyle(parent);
            const canScrollY = /(auto|scroll|overlay)/i.test(style.overflowY) && parent.scrollHeight > parent.clientHeight + 8;
            if (canScrollY) {
              const pr = parent.getBoundingClientRect();
              const tr = target.getBoundingClientRect();
              parent.scrollTop += (tr.top + tr.height / 2) - (pr.top + pr.height / 2);
            }
            parent = parent.parentElement;
          }
          const maxY = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0) - viewportH;
          const nextY = Math.max(0, Math.min(maxY, pageY - viewportH * 0.42));
          try { window.scrollTo({ top: nextY, left: Math.max(0, pageX - viewportW / 2), behavior: 'smooth' }); }
          catch (_) { window.scrollTo(Math.max(0, pageX - viewportW / 2), nextY); }
          try { target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' }); } catch (_) {}
          const r = target.getBoundingClientRect();
          return JSON.stringify({
            scrolled: true,
            url: location.href,
            reason: best.reason,
            score: Math.round(best.score),
            scroll_y: Math.round(window.scrollY || 0),
            target_text: best.text.slice(0, 180),
            rect: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) }
          });
        })();
        """
    }

    private static func visibleChallengeProbeScript() -> String {
        """
        (() => {
          const bodyText = ((document.body && document.body.innerText) || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || frame.getAttribute('aria-label') || '').join(' ').toLowerCase();
          const turnstile = document.querySelector('[name="cf-turnstile-response"], input[id^="cf-chl-widget"], .cf-turnstile, [data-sitekey]');
          const recaptcha = document.querySelector('[name="g-recaptcha-response"], .g-recaptcha, iframe[src*="recaptcha"]');
          const tokenNode = turnstile || recaptcha;
          const tokenLength = tokenNode && 'value' in tokenNode ? String(tokenNode.value || '').length : 0;
          const challengeDetected = Boolean(
            turnstile ||
            recaptcha ||
            /turnstile|captcha|recaptcha|challenge/.test(frames) ||
            /prove you are human|verify you are human|checking if the site connection is secure|checking your browser|cf-challenge|captcha|turnstile|故障排除|验证失败|验证您是真人|请验证您是真人|正在检查|troubleshooting|verification failed/.test(bodyText)
          );
          const failedState = /故障排除|验证失败|troubleshooting|verification failed/.test(bodyText);
          const successState = /成功|success|verified|验证成功|已验证/.test(bodyText) && /cloudflare|captcha|turnstile|验证/.test(bodyText);
          return JSON.stringify({
            detected: challengeDetected,
            completed: tokenLength > 0 || successState,
            failed_state: failedState
          });
        })();
        """
    }

    private func isAutomationBrowserVisible(_ webView: WKWebView) -> Bool {
        guard let container = automationBrowserContainer else { return false }
        return webView.superview === container
    }

    private func isKnownBrowserWebView(_ source: WKWebView) -> Bool {
        if source === webView { return true }
        return browserTabs.values.contains { $0 === source }
    }

    private func notifyActiveBrowserDidChange() {
        NotificationCenter.default.post(
            name: .browserWebSearchServiceActiveBrowserDidChange,
            object: webView,
            userInfo: [
                "tab_id": activeBrowserTabID,
                "url": webView?.url?.absoluteString ?? "",
                "title": webView?.title ?? ""
            ]
        )
    }

    private func loadInitialAutomationURL(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
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

    private func evaluatePageSnapshot(textLimit: Int = 24_000) async -> BrowserPageSnapshot? {
        let script = """
        (() => {
          const textLimit = \(min(max(textLimit, 1_000), 48_000));
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
          return JSON.stringify({ title, url: location.href, description: desc, published, text: text.slice(0, textLimit) });
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

    private func evaluateVisibleTextSnapshot(textLimit: Int = 1_400) async -> BrowserPageSnapshot? {
        guard let object = await evaluateJSONObject(Self.viewportContextScript(
            textLimit: min(max(textLimit, 500), 6_000),
            elementLimit: 0
        )) else {
            return nil
        }
        return BrowserPageSnapshot(
            title: object["title"] as? String ?? "",
            url: object["url"] as? String ?? "",
            description: "",
            published: "",
            text: object["visible_text"] as? String ?? ""
        )
    }

    private func evaluateFullPageSnapshot(maxScrolls: Int = 14) async -> BrowserPageSnapshot? {
        guard let firstSnapshot = await evaluatePageSnapshot(textLimit: 24_000) else { return nil }
        guard let metrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) else {
            return firstSnapshot
        }

        let originalY = Self.intValue(metrics["scroll_y"]) ?? 0
        let viewportHeight = max(Self.intValue(metrics["viewport_height"]) ?? 720, 240)
        var scrollHeight = max(Self.intValue(metrics["scroll_height"]) ?? viewportHeight, viewportHeight)
        var maxY = max(scrollHeight - viewportHeight, 0)
        guard maxY > 80 else { return firstSnapshot }

        var pageSnapshots: [BrowserPageSnapshot] = [firstSnapshot]
        var viewportSnapshots: [BrowserPageSnapshot] = []
        let step = max(Int(Double(viewportHeight) * 0.82), 360)
        let maxSamples = min(max(maxScrolls, 1), 24)
        var offsets: [Int] = [0]
        var nextY = step
        while nextY < maxY {
            offsets.append(nextY)
            nextY += step
        }
        offsets.append(maxY)
        offsets = Self.sampledUniqueOffsets(offsets, limit: maxSamples)

        var offsetIndex = 0
        while offsetIndex < offsets.count {
            let offset = offsets[offsetIndex]
            _ = await evaluateJSONObject(Self.scrollToPageYScript(offset))
            try? await Task.sleep(nanoseconds: offsetIndex == 0 ? 220_000_000 : 380_000_000)

            if let visibleSnapshot = await evaluateVisibleTextSnapshot(textLimit: 1_400),
               !visibleSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewportSnapshots.append(visibleSnapshot)
            }

            if let snapshot = await evaluatePageSnapshot(textLimit: 24_000) {
                pageSnapshots.append(snapshot)
            }

            if let updatedMetrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) {
                let updatedHeight = max(Self.intValue(updatedMetrics["scroll_height"]) ?? scrollHeight, viewportHeight)
                if updatedHeight > scrollHeight + viewportHeight {
                    scrollHeight = updatedHeight
                    maxY = max(scrollHeight - viewportHeight, 0)
                    let tailOffset = maxY
                    if !offsets.contains(tailOffset), offsets.count < maxSamples {
                        offsets.append(tailOffset)
                    }
                }
            }
            offsetIndex += 1
        }

        _ = await evaluateJSONObject(Self.scrollToPageYScript(originalY))

        let best = pageSnapshots.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? firstSnapshot
        let mergedText = Self.mergedSnapshotText(viewportSnapshots + pageSnapshots)
        return BrowserPageSnapshot(
            title: best.title.isEmpty ? firstSnapshot.title : best.title,
            url: best.url.isEmpty ? firstSnapshot.url : best.url,
            description: best.description.isEmpty ? firstSnapshot.description : best.description,
            published: best.published.isEmpty ? firstSnapshot.published : best.published,
            text: mergedText.isEmpty ? firstSnapshot.text : mergedText
        )
    }

    private static func sampledUniqueOffsets(_ offsets: [Int], limit: Int) -> [Int] {
        var unique: [Int] = []
        var seen = Set<Int>()
        for offset in offsets.map({ max($0, 0) }) where seen.insert(offset).inserted {
            unique.append(offset)
        }
        guard limit > 0, unique.count > limit else { return unique }
        guard limit > 1 else { return [unique.first ?? 0] }

        var sampled: [Int] = []
        let lastIndex = unique.count - 1
        for index in 0..<limit {
            let rawIndex = Double(index) * Double(lastIndex) / Double(limit - 1)
            let sampleIndex = min(max(Int(rawIndex.rounded()), 0), lastIndex)
            sampled.append(unique[sampleIndex])
        }
        var sampleSeen = Set<Int>()
        return sampled.filter { sampleSeen.insert($0).inserted }
    }

    private static func mergedSnapshotText(_ snapshots: [BrowserPageSnapshot]) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for snapshot in snapshots {
            for rawLine in snapshot.text.components(separatedBy: .newlines) {
                let line = rawLine
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.count > 1 else { continue }
                let key = line.lowercased()
                guard seen.insert(key).inserted else { continue }
                lines.append(line)
            }
        }
        return String(lines.joined(separator: "\n").prefix(32_000))
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

    private static func freshnessExpandedQueries(
        _ queries: [String],
        originalQuery: String?
    ) -> [String] {
        let source = ([originalQuery].compactMap { $0 } + queries)
            .joined(separator: " ")
        guard searchNeedsFreshness(source) else {
            return unique(queries)
        }

        var expanded: [String] = []
        let now = Date()
        let dateText = localizedSearchDateText(now)
        let isoDateText = isoSearchDateText(now)
        let englishDateText = englishSearchDateText(now)
        let dayScoped = searchNeedsDayScope(source)

        for query in queries {
            let hasCJK = query.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
            if dayScoped {
                expanded.append(hasCJK ? "\(query) \(dateText) 最新" : "\(query) \(englishDateText) latest")
                expanded.append(hasCJK ? "\(query) \(isoDateText) 今天 24小时" : "\(query) \(isoDateText) past 24 hours")
            } else {
                expanded.append(hasCJK ? "\(query) 最新 \(dateText)" : "\(query) latest \(englishDateText)")
                expanded.append(hasCJK ? "\(query) 官方 更新 \(isoDateText)" : "\(query) official updated \(isoDateText)")
            }
            expanded.append(query)
        }
        return unique(expanded)
    }

    private static func searchNeedsFreshness(_ query: String) -> Bool {
        let normalized = query
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "最新", "今天", "今日", "现在", "目前", "刚刚", "新闻", "热搜", "实时",
            "现价", "价格", "油价", "天气", "气温", "股价", "汇率", "版本", "发布",
            "更新", "日期", "当天", "24小时", "一天内",
            "latest", "today", "current", "now", "news", "breaking", "price",
            "weather", "stock", "exchange", "rate", "release", "version",
            "updated", "last24hours", "past24hours"
        ].contains { normalized.contains($0) }
    }

    private static func searchNeedsDayScope(_ query: String) -> Bool {
        let normalized = query
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "今天", "今日", "现在", "目前", "刚刚", "实时", "当天", "24小时", "一天内",
            "today", "now", "current", "last24hours", "past24hours"
        ].contains { normalized.contains($0) }
    }

    private static func localizedSearchDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private static func isoSearchDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func englishSearchDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMMM d yyyy"
        return formatter.string(from: date)
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

extension Notification.Name {
    static let browserWebSearchServiceActiveBrowserDidChange =
        Notification.Name("BrowserWebSearchServiceActiveBrowserDidChange")
    static let browserWebSearchServiceHumanVerificationStateDidChange =
        Notification.Name("BrowserWebSearchServiceHumanVerificationStateDidChange")
}
