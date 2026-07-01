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
    private var browserUserAgentProfile = "desktop_chrome"
    private var navigationContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private weak var automationBrowserContainer: UIView?
    private weak var automationBrowserNavigationDelegate: WKNavigationDelegate?
    private weak var automationBrowserUIDelegate: WKUIDelegate?

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
        case "browser.use", "browser_use":
            return await executeNativeBrowserUse(call)
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
        let x = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"])
        let y = Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"])
        guard selector != nil || (x != nil && y != nil) else {
            return [
                "action": "browser.click",
                "ok": false,
                "error": "Missing selector or coordinates"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const x = \(x.map(String.init) ?? "null");
          const y = \(y.map(String.init) ?? "null");
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
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
          function isEditable(node) {
            if (!node) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            return tag === 'input' || tag === 'textarea' || tag === 'select' || !!node.isContentEditable;
          }
          const node = findNode(selector) || ((Number.isFinite(x) && Number.isFinite(y)) ? document.elementFromPoint(x, y) : null);
          if (!node) {
            return JSON.stringify({ ok: false, error: 'Element not found' });
          }
          if (node.scrollIntoView) {
            node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          }
          const target = node.closest && node.closest('button, a, input, textarea, select, [contenteditable], [role="button"], [onclick]') || node;
          const editableTarget = isEditable(target);
          const events = [
            ['pointerdown', { bubbles: true, cancelable: true, composed: true }],
            ['mousedown', { bubbles: true, cancelable: true, composed: true }],
            ['mouseup', { bubbles: true, cancelable: true, composed: true }],
            ['click', { bubbles: true, cancelable: true, composed: true }]
          ];
          for (const [name, init] of events) {
            try {
              target.dispatchEvent(new MouseEvent(name, init));
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
            tag: (target.tagName || target.nodeName || '').toLowerCase(),
            text: text(target).slice(0, 120),
            href: target.href || '',
            rect: rect(target)
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
        payload["summary"] = "已点击网页元素。"
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
        let text = Self.firstString(in: call, keys: ["text", "value", "input", "content", "message"]) ?? ""
        let clear = Self.boolValue(call["clear"] ?? call["replace"] ?? call["overwrite"]) ?? true
        let pressEnter = Self.boolValue(call["press_enter"] ?? call["enter"] ?? call["submit"]) ?? false
        guard let selector, !selector.isEmpty else {
            return [
                "action": "browser.type",
                "ok": false,
                "error": "Missing required field: selector"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector));
          const text = \(Self.javascriptString(text));
          const clear = \(clear ? "true" : "false");
          const pressEnter = \(pressEnter ? "true" : "false");
          function textOf(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function findNode(raw) {
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
          const node = findNode(selector);
          if (!node) {
            return JSON.stringify({ ok: false, error: 'Element not found' });
          }
          if (node.scrollIntoView) {
            try { node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          }
          try { node.dispatchEvent(new FocusEvent('focusin', { bubbles: true, cancelable: false, composed: true })); } catch (_) {}
          try { node.dispatchEvent(new FocusEvent('focus', { bubbles: false, cancelable: false, composed: true })); } catch (_) {}
          if (node.isContentEditable) {
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
            selector,
            text: textOf(node).slice(0, 160),
            tag: (node.tagName || node.nodeName || '').toLowerCase()
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
        payload["summary"] = "已向网页元素输入文本。"
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
        let x = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"])
        let y = Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"])
        guard selector != nil || (x != nil && y != nil) else {
            return [
                "action": "browser.hover",
                "ok": false,
                "error": "Missing selector or coordinates"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const x = \(x.map(String.init) ?? "null");
          const y = \(y.map(String.init) ?? "null");
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function rect(node) {
            if (!node || !node.getBoundingClientRect) return null;
            const r = node.getBoundingClientRect();
            return { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) };
          }
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
          const node = findNode(selector) || ((Number.isFinite(x) && Number.isFinite(y)) ? document.elementFromPoint(x, y) : null);
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
        payload["action"] = "browser.scroll"
        payload["summary"] = "已滚动网页。"
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

        let selector = Self.firstString(in: call, keys: ["selector", "css"]) ?? "a, button, input, textarea, select, [role='button'], [onclick]"
        let limit = min(max(Self.intValue(call["limit"] ?? call["max_results"]) ?? 30, 1), 100)
        let script = Self.elementCollectionScript(selector: selector, limit: limit)
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
        let profile = Self.firstString(in: call, keys: ["user_agent", "userAgent", "profile"]) ?? "desktop_chrome"
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
                    let thumbnail = await capturePageThumbnail(prefix: "browser_image_result")
                    return [
                        "action": "browser.wait_for_image",
                        "ok": true,
                        "title": object["title"] as? String ?? "生成图片",
                        "url": object["url"] as? String ?? "",
                        "file_url": saved.url.absoluteString,
                        "file_name": saved.url.lastPathComponent,
                        "content_type": saved.contentType,
                        "bytes": saved.byteCount,
                        "image_width": candidate["width"] as? Int ?? 0,
                        "image_height": candidate["height"] as? Int ?? 0,
                        "source_url": candidate["src"] as? String ?? "",
                        "preview_images": [saved.url.absoluteString] + (thumbnail.map { [$0.absoluteString] } ?? []),
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
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let thumbnail = await capturePageThumbnail(prefix: "browser_image_timeout")
        var payload: [String: Any] = [
            "action": "browser.wait_for_image",
            "ok": false,
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
        guard !normalized.isEmpty else { return }
        browserUserAgentProfile = normalized
        let userAgent = Self.browserUserAgentString(profile: normalized)
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

    private static func browserUserAgentString(profile: String) -> String {
        switch profile.lowercased() {
        case "mobile_chrome":
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0.6478.54 Mobile/15E148 Safari/604.1"
        default:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        }
    }

    private static func browserUseActionName(_ requestedAction: String?, call: [String: Any]) -> String {
        let normalized = requestedAction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let hasURL = urlValue(in: call) != nil
        let wantsSave = Self.firstString(in: call, keys: ["save_to", "output", "path"]) != nil

        switch normalized {
        case "", "browser_use", "browser.use":
            if wantsSave { return "browser.fetch" }
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

    private static func elementCollectionScript(selector: String, limit: Int) -> String {
        """
        (() => {
          const selector = \(Self.javascriptString(selector));
          const limit = \(limit);
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
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
          function findElements(raw) {
            try {
              return Array.from(document.querySelectorAll(raw));
            } catch (_) {
              return [];
            }
          }
          const elements = findElements(selector).slice(0, limit);
          const items = elements.map((node, index) => ({
            index,
            tag: (node.tagName || node.nodeName || '').toLowerCase(),
            title: text(node).slice(0, 120),
            text: text(node).slice(0, 240),
            href: href(node),
            id: node.id || '',
            classes: typeof node.className === 'string' ? node.className : '',
            placeholder: node.placeholder || '',
            role: node.getAttribute ? (node.getAttribute('role') || '') : '',
            type: node.getAttribute ? (node.getAttribute('type') || '') : '',
            rect: rect(node)
          }));
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            selector,
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
              data_url: dataURLFromImage(img),
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
          for (const canvas of Array.from(document.querySelectorAll('canvas'))) {
            if (!visible(canvas)) continue;
            const r = canvas.getBoundingClientRect();
            if (r.width < minWidth || r.height < minHeight) continue;
            try {
              const dataURL = canvas.toDataURL('image/png');
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
        config.websiteDataStore = .nonPersistent()
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
        wv.customUserAgent = Self.browserUserAgentString(profile: browserUserAgentProfile)
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
        if let webView, isAutomationBrowserVisible(webView) {
            webView.frame = CGRect(origin: .zero, size: size)
        }
    }

    func browserWebViewDidFinishNavigation(_ source: WKWebView) {
        guard isKnownBrowserWebView(source) else { return }
        resolveNavigation(true)
        notifyActiveBrowserDidChange()
    }

    func browserWebViewDidFailNavigation(_ source: WKWebView) {
        guard isKnownBrowserWebView(source) else { return }
        resolveNavigation(false)
        notifyActiveBrowserDidChange()
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

        return await withCheckedContinuation { continuation in
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
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue(Self.browserUserAgentString(profile: browserUserAgentProfile), forHTTPHeaderField: "User-Agent")
                request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                wv.load(request)
            }
        }
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

    private func mountAutomationBrowser(_ webView: WKWebView, in container: UIView) {
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
        browserViewportSize = container.bounds.size.width > 0 && container.bounds.size.height > 0
            ? container.bounds.size
            : browserViewportSize
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
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

extension Notification.Name {
    static let browserWebSearchServiceActiveBrowserDidChange =
        Notification.Name("BrowserWebSearchServiceActiveBrowserDidChange")
}
