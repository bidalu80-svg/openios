import Foundation
import WebKit
import UIKit
import OSLog

struct BrowserWebSearchTabSnapshot: Identifiable, Equatable {
    let id: Int
    let title: String
    let url: String
    let isActive: Bool
}

@MainActor
final class BrowserWebSearchService: NSObject {
    static let shared = BrowserWebSearchService()

    private let logger = Logger(subsystem: "com.openui", category: "BrowserWebSearch")
    private var webView: WKWebView?
    private var browserTabs: [Int: WKWebView] = [:]
    private var activeBrowserTabID = 1
    private var nextBrowserTabID = 2
    private static let defaultMobileBrowserViewport = CGSize(width: 390, height: 720)
    private var browserViewportSize = BrowserWebSearchService.defaultMobileBrowserViewport
    private var browserUserAgentProfile = "mobile_safari"
    private var browserDesktopModeExplicitlyEnabled = false
    private var browserVisibleChallengeRefreshURLs: Set<String> = []
    private var browserHumanVerificationSeenTabs: Set<Int> = []
    private var browserHumanVerificationCompletedAtByTab: [Int: Date] = [:]
    private var browserHumanVerificationCompletedURLByTab: [Int: URL] = [:]
    private var browserLastUserInteractionAt = Date.distantPast
    private var browserLastUserInteractionKind = ""
    private var browserLivePreviewLastPublishedAt = Date.distantPast
    private var browserLivePreviewRevision = 0
    private var browserLivePreviewTask: Task<Void, Never>?
    private var browserLivePreviewFileURL: URL?
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

    var hasActiveBrowserPageForContinuation: Bool {
        guard let webView = browserTabs[activeBrowserTabID] ?? webView,
              let url = webView.url,
              Self.isHTTPBrowserURL(url) else {
            return false
        }
        return true
    }

    var currentTabSnapshots: [BrowserWebSearchTabSnapshot] {
        browserTabSnapshots()
    }

    func createAutomationBrowserTab(initialURL: URL? = nil) {
        guard browserTabs.count < 3 else { return }
        let tabID = nextBrowserTabID
        nextBrowserTabID += 1
        let tab = makeBrowserWebView()
        browserTabs[tabID] = tab
        activeBrowserTabID = tabID
        webView = tab
        mountActiveBrowserIfPresented()
        if let initialURL {
            loadInitialAutomationURL(initialURL, in: tab)
        }
        notifyActiveBrowserDidChange()
    }

    func activateAutomationBrowserTab(_ tabID: Int) {
        activateBrowserTab(tabID)
    }

    func closeAutomationBrowserTab(_ tabID: Int) {
        guard browserTabs[tabID] != nil else { return }
        Task { @MainActor in
            _ = await executeNativeCloseTab(["tab_id": tabID])
            notifyActiveBrowserDidChange()
        }
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
        let sanitizedCall = browserCallWithMobileDefaultsIfNeeded(call, action: action)
        if Self.browserCallAllowsDesktopMode(sanitizedCall) {
            browserDesktopModeExplicitlyEnabled = true
        } else if !browserDesktopModeExplicitlyEnabled {
            applyMobileBrowserDefaultsIfNeeded()
        }
        let publishesLivePreview = Self.browserActionPublishesLivePreview(action)
        if publishesLivePreview {
            scheduleLiveBrowserPreview(reason: "before_\(action)", minimumInterval: 0.35)
        }
        defer {
            if publishesLivePreview {
                scheduleLiveBrowserPreview(reason: "after_\(action)", minimumInterval: 0.9)
            }
        }
        var payload: [String: Any]
        switch action {
        case "web.search", "web_search", "search_web", "browser.search", "browser_search":
            payload = await executeNativeSearch(sanitizedCall)
        case "browser.use", "browser_use":
            payload = await executeNativeBrowserUse(sanitizedCall)
        case "browser.auto", "browser_auto", "auto", "complete_task", "browser.complete_task":
            payload = await executeNativeAutoWorkflow(sanitizedCall)
        case "browser.open", "browser.navigate", "browser_open", "browser.navigate_url", "navigate":
            payload = await executeNativeOpen(sanitizedCall, readable: false)
        case "browser.readable", "browser.get_readable", "browser_readable", "get_readable", "read_webpage":
            payload = await executeNativeOpen(sanitizedCall, readable: true)
        case "browser.text", "browser.get_text", "browser_text", "get_text":
            payload = await executeNativeText(sanitizedCall)
        case "browser.info", "browser.get_page_info", "browser_info", "get_page_info":
            payload = await executeNativePageInfo(sanitizedCall)
        case "browser.inspect", "browser_inspect", "inspect", "page_inspect", "inspect_page", "browser.page_state", "browser_page_state":
            payload = await executeNativeInspect(sanitizedCall)
        case "browser.observe", "browser_observe", "observe", "browser.get_state", "browser_get_state", "get_state":
            payload = await executeNativeObserve(sanitizedCall)
        case "browser.screenshot", "browser_screenshot", "screenshot":
            payload = await executeNativeScreenshot(sanitizedCall)
        case "browser.fetch", "browser_fetch", "fetch":
            payload = await executeNativeFetch(sanitizedCall)
        case "browser.click", "browser_click", "click":
            payload = await executeNativeClick(sanitizedCall)
        case "browser.type", "browser_type", "type":
            payload = await executeNativeType(sanitizedCall)
        case "browser.hover", "browser_hover", "hover":
            payload = await executeNativeHover(sanitizedCall)
        case "browser.scroll", "browser_scroll", "scroll":
            payload = await executeNativeScroll(sanitizedCall)
        case "browser.scroll_and_collect", "browser_scroll_and_collect", "scroll_and_collect":
            payload = await executeNativeScrollAndCollect(sanitizedCall)
        case "browser.find_elements", "browser_find_elements", "find_elements":
            payload = await executeNativeFindElements(sanitizedCall)
        case "browser.get_backbone", "browser_get_backbone", "get_backbone":
            payload = await executeNativeBackbone(sanitizedCall)
        case "browser.execute_js", "browser_execute_js", "execute_js", "eval_js":
            payload = await executeNativeExecuteJavaScript(sanitizedCall)
        case "browser.set_viewport", "browser_set_viewport", "set_viewport":
            payload = await executeNativeSetViewport(sanitizedCall)
        case "browser.set_user_agent", "browser_set_user_agent", "set_user_agent":
            payload = executeNativeSetUserAgent(sanitizedCall)
        case "browser.get_cookies", "browser_get_cookies", "get_cookies":
            payload = await executeNativeCookies(sanitizedCall)
        case "browser.wait_for_dom_stable", "browser_wait_for_dom_stable", "wait_for_dom_stable":
            payload = await executeNativeWaitForDOMStable(sanitizedCall)
        case "browser.wait_for_image", "browser_wait_for_image", "wait_for_image", "wait_image", "image_result":
            payload = await executeNativeWaitForImage(sanitizedCall)
        case "browser.new_tab", "browser_new_tab", "new_tab":
            payload = await executeNativeNewTab(sanitizedCall)
        case "browser.close_tab", "browser_close_tab", "close_tab":
            payload = await executeNativeCloseTab(sanitizedCall)
        case "browser.list_tabs", "browser_list_tabs", "list_tabs":
            payload = await executeNativeListTabs(sanitizedCall)
        default:
            payload = [
                "action": rawAction,
                "ok": false,
                "error": "Unsupported browser action"
            ]
        }
        if Self.boolValue(sanitizedCall["desktop_mode_blocked"]) == true
            || Self.boolValue(sanitizedCall["desktop_viewport_blocked"]) == true {
            payload["mobile_defaults_enforced"] = true
            payload["desktop_mode_blocked"] = Self.boolValue(sanitizedCall["desktop_mode_blocked"]) == true
            payload["desktop_viewport_blocked"] = Self.boolValue(sanitizedCall["desktop_viewport_blocked"]) == true
        }
        payload["desktop_mode_active"] = browserDesktopModeExplicitlyEnabled
        return await enrichNativeBrowserToolPayload(payload, requestedAction: action, call: sanitizedCall)
    }

    private static func browserActionPublishesLivePreview(_ action: String) -> Bool {
        if action.hasPrefix("browser.") || action.hasPrefix("browser_") {
            return action != "browser.search" && action != "browser_search"
        }
        return [
            "open", "navigate", "read_webpage", "get_readable",
            "observe", "get_state", "inspect", "page_inspect",
            "click", "type", "hover", "scroll", "scroll_and_collect",
            "find_elements", "get_backbone", "execute_js", "eval_js",
            "wait_for_dom_stable", "wait_for_image", "screenshot",
            "new_tab", "close_tab", "list_tabs", "set_viewport"
        ].contains(action)
    }

    private static func browserCallAllowsDesktopMode(_ call: [String: Any]) -> Bool {
        boolValue(call["allow_desktop"] ?? call["allowDesktop"] ?? call["desktop_mode"] ?? call["desktopMode"] ?? call["force_desktop"] ?? call["forceDesktop"]) == true
    }

    private func browserCallWithMobileDefaultsIfNeeded(_ call: [String: Any], action: String) -> [String: Any] {
        guard !Self.browserCallAllowsDesktopMode(call), !browserDesktopModeExplicitlyEnabled else { return call }

        var sanitized = call
        if let rawProfile = Self.firstString(in: sanitized, keys: ["user_agent", "userAgent", "profile"])?.lowercased(),
           rawProfile.contains("desktop") || rawProfile == "desktop_chrome" {
            sanitized["user_agent"] = "mobile_safari"
            sanitized["userAgent"] = "mobile_safari"
            sanitized["profile"] = "mobile_safari"
            sanitized["desktop_mode_blocked"] = true
        }

        let width = Self.intValue(sanitized["viewport_width"] ?? sanitized["viewportWidth"] ?? sanitized["width"])
        let height = Self.intValue(sanitized["viewport_height"] ?? sanitized["viewportHeight"] ?? sanitized["height"])
        let isViewportAction = [
            "browser.set_viewport", "browser_set_viewport", "set_viewport"
        ].contains(action)
        if isViewportAction || width != nil || height != nil {
            if (width ?? 0) >= 700 || (height ?? 0) >= 1200 {
                sanitized["viewport_width"] = Int(Self.defaultMobileBrowserViewport.width.rounded())
                sanitized["viewport_height"] = Int(Self.defaultMobileBrowserViewport.height.rounded())
                sanitized["width"] = Int(Self.defaultMobileBrowserViewport.width.rounded())
                sanitized["height"] = Int(Self.defaultMobileBrowserViewport.height.rounded())
                sanitized["reset"] = false
                sanitized["desktop_viewport_blocked"] = true
            }
        }

        return sanitized
    }

    private func applyMobileBrowserDefaultsIfNeeded() {
        if browserUserAgentProfile.lowercased().contains("desktop") {
            applyBrowserUserAgent("mobile_safari")
        }

        let width = Int(browserViewportSize.width.rounded())
        let height = Int(browserViewportSize.height.rounded())
        guard width >= 700 || height >= 1200 else { return }

        browserViewportSize = Self.defaultMobileBrowserViewport
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
    }

    private func enrichNativeBrowserToolPayload(
        _ payload: [String: Any],
        requestedAction: String,
        call: [String: Any]
    ) async -> [String: Any] {
        if payload["post_action_observation"] != nil {
            return payload
        }
        guard shouldAttachBrowserAutomationObservation(
            requestedAction: requestedAction,
            payload: payload
        ) else {
            return payload
        }

        var enriched = payload
        if shouldAutoWaitAfterBrowserAction(requestedAction),
           Self.boolValue(call["auto_wait"] ?? call["autoWait"]) != false {
            let wait = await waitForBrowserAutomationSettle(
                timeout: TimeInterval(Self.intValue(call["auto_wait_timeout"] ?? call["autoWaitTimeout"]) ?? 5)
            )
            enriched["auto_wait"] = wait
        }

        if let state = await evaluateJSONObject(Self.browserAutomationStateScript(
            elementLimit: min(max(Self.intValue(call["observation_limit"] ?? call["observationLimit"] ?? call["element_limit"] ?? call["limit"]) ?? 36, 8), 80),
            textLimit: min(max(Self.intValue(call["observation_text_limit"] ?? call["observationTextLimit"]) ?? 1800, 400), 5000)
        )) {
            enriched["post_action_observation"] = state
            enriched["next_action_candidates"] = state["action_candidates"] as? [[String: Any]] ?? []
            enriched["next_action_candidate_count"] = Self.intValue(state["action_candidate_count"]) ?? 0
            enriched["browser_state_label"] = state["state_label"] as? String ?? ""
            enriched["browser_ready_state"] = state["ready_state"] as? String ?? ""
            enriched["browser_scroll"] = state["scroll"] as? [String: Any] ?? [:]
            enriched["active_tab_id"] = activeBrowserTabID
            enriched["tabs"] = browserTabSnapshots().map { snapshot in
                [
                    "id": snapshot.id,
                    "title": snapshot.title,
                    "url": snapshot.url,
                    "is_active": snapshot.isActive
                ] as [String: Any]
            }
            if let candidates = state["action_candidates"] as? [[String: Any]], !candidates.isEmpty {
                enriched["next_action_required"] = Self.boolValue(enriched["next_action_required"]) ?? true
                if enriched["suggested_next_browser_action"] == nil {
                    enriched["suggested_next_browser_action"] = candidates.first?["action"] as? String ?? "browser.observe"
                }
            }
        }
        return enriched
    }

    private func shouldAttachBrowserAutomationObservation(
        requestedAction: String,
        payload: [String: Any]
    ) -> Bool {
        guard hasActiveBrowserPageForContinuation else { return false }
        guard Self.boolValue(payload["ok"]) != false else {
            return ["browser.observe", "browser.find_elements", "browser.inspect"].contains(requestedAction)
        }
        let skipped: Set<String> = [
            "web.search", "web_search", "search_web", "browser.search", "browser_search",
            "browser.fetch", "browser_fetch", "fetch",
            "browser.wait_for_image", "browser_wait_for_image", "wait_for_image", "wait_image", "image_result",
            "browser.get_cookies", "browser_get_cookies", "get_cookies",
            "browser.list_tabs", "browser_list_tabs", "list_tabs",
            "browser.close_tab", "browser_close_tab", "close_tab",
            "browser.auto", "browser_auto", "auto", "complete_task", "browser.complete_task"
        ]
        return !skipped.contains(requestedAction)
    }

    private func shouldAutoWaitAfterBrowserAction(_ action: String) -> Bool {
        [
            "browser.open", "browser.navigate", "browser_open", "browser.navigate_url", "navigate",
            "browser.click", "browser_click", "click",
            "browser.type", "browser_type", "type",
            "browser.scroll", "browser_scroll", "scroll",
            "browser.execute_js", "browser_execute_js", "execute_js", "eval_js",
            "browser.new_tab", "browser_new_tab", "new_tab",
            "browser.set_viewport", "browser_set_viewport", "set_viewport",
            "browser.set_user_agent", "browser_set_user_agent", "set_user_agent"
        ].contains(action)
    }

    private func waitForBrowserAutomationSettle(timeout: TimeInterval) async -> [String: Any] {
        let deadline = Date().addingTimeInterval(min(max(timeout, 1), 12))
        var previousFingerprint = ""
        var stableSamples = 0
        var samples: [[String: Any]] = []

        while Date() < deadline {
            let script = """
            (() => JSON.stringify({
              ready_state: document.readyState || '',
              url: location.href,
              title: document.title || '',
              text_length: (document.body && (document.body.innerText || document.body.textContent) || '').length,
              child_count: document.body ? document.body.getElementsByTagName('*').length : 0,
              scroll_height: Math.max(document.documentElement.scrollHeight || 0, document.body ? document.body.scrollHeight || 0 : 0),
              resource_count: performance.getEntriesByType ? performance.getEntriesByType('resource').length : 0
            }))();
            """
            guard let object = await evaluateJSONObject(script) else { break }
            samples.append(object)
            let fingerprint = [
                object["ready_state"] as? String ?? "",
                object["url"] as? String ?? "",
                String(describing: object["text_length"] ?? 0),
                String(describing: object["child_count"] ?? 0),
                String(describing: object["scroll_height"] ?? 0),
                String(describing: object["resource_count"] ?? 0)
            ].joined(separator: "|")
            if fingerprint == previousFingerprint {
                stableSamples += 1
            } else {
                stableSamples = 0
                previousFingerprint = fingerprint
            }
            if (object["ready_state"] as? String) == "complete", stableSamples >= 2 {
                return [
                    "ok": true,
                    "stable": true,
                    "samples": Array(samples.suffix(5)),
                    "summary": "页面已在动作后稳定。"
                ]
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return [
            "ok": true,
            "stable": false,
            "samples": Array(samples.suffix(5)),
            "summary": "动作后已等待页面变化，但未完全稳定；仍返回当前可操作状态。"
        ]
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
        let queries = Self.deviceDateAwareQueries(([query] + extraQueries).map(Self.normalizedQuery))
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
        let requestedURL = Self.urlValue(in: call)
        guard let url = requestedURL ?? await currentPageURL() else {
            return [
                "action": readable ? "browser.readable" : "browser.open",
                "ok": false,
                "error": "Missing required field: url (and there is no active browser page to reuse)"
            ]
        }

        let timeout = TimeInterval(Self.intValue(call["timeout"] ?? call["timeout_seconds"]) ?? 14)
        let forceReload = Self.boolValue(call["force_reload"] ?? call["forceReload"] ?? call["reload"]) ?? false
        // `open` and `readable` are also used as continuation primitives. When
        // a model omits URL on an already-open page, keep that page in place
        // instead of failing or reloading it.
        if requestedURL != nil,
           !(await load(url: url, timeout: min(max(timeout, 3), 30), forceReload: forceReload)) {
            return [
                "action": readable ? "browser.readable" : "browser.open",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        let reusedExistingPage = requestedURL == nil || lastBrowserNavigationReusedExistingPage
        try? await Task.sleep(nanoseconds: 650_000_000)

        let maxLength = min(max(Self.intValue(call["max_length"] ?? call["limit"]) ?? 8_000, 800), 18_000)
        let includeScreenshot = Self.boolValue(call["screenshot"] ?? call["with_screenshot"] ?? call["thumbnail"] ?? call["attach_preview"] ?? call["attachPreview"]) ?? false
        let maxScrolls = min(max(Self.intValue(call["scroll_count"] ?? call["max_scrolls"] ?? call["maxScrolls"]) ?? 14, 1), 24)
        let snapshot = await evaluateFullPageSnapshot(maxScrolls: maxScrolls)
        let verification = await evaluateJSONObject(Self.visibleChallengeProbeScript()) ?? ["detected": false]
        let verificationRequiresUser = Self.humanVerificationRequiresUser(verification)
        if verificationRequiresUser {
            _ = await scrollToVisibleHumanVerification()
        }
        let thumbnail = includeScreenshot ? await capturePageThumbnail(prefix: "browser_viewport") : nil
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
            "requires_user_verification": verificationRequiresUser,
            "next_action_required": !readable && !verificationRequiresUser,
            "suggested_next_browser_action": !readable && !verificationRequiresUser ? "browser.find_elements" : "",
            "next_action_reason": !readable && !verificationRequiresUser
                ? "browser.open only navigated to the page. Continue with find_elements/screenshot/click/type/scroll until the user's page task is complete."
                : "",
            "reused_existing_page": reusedExistingPage,
            "summary": verificationRequiresUser
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
        return await addingViewportVisualObservation(
            to: payload,
            call: call,
            prefix: readable ? "browser_readable_after" : "browser_open_after",
            note: "Tool-only current viewport after opening/navigating. Use it as the primary visual state for the next browser action."
        )
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

    private func executeNativeInspect(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(
               url: url,
               timeout: 14,
               forceReload: Self.boolValue(call["force_reload"] ?? call["forceReload"] ?? call["reload"]) ?? false
           )) {
            return [
                "action": "browser.inspect",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 350_000_000)

        let maxScrolls = min(max(Self.intValue(call["max_scrolls"] ?? call["maxScrolls"] ?? call["scroll_count"] ?? call["count"]) ?? 14, 1), 24)
        let maxTextLength = min(max(Self.intValue(call["max_length"] ?? call["limit"]) ?? 10_000, 1_000), 24_000)
        let maxDepth = min(max(Self.intValue(call["max_depth"] ?? call["depth"]) ?? 4, 1), 8)
        let elementLimit = min(max(Self.intValue(call["element_limit"] ?? call["elements"] ?? call["limit"]) ?? 48, 12), 100)

        let originalMetrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) ?? [:]
        let originalY = Self.intValue(originalMetrics["scroll_y"]) ?? 0
        var verification = await evaluateJSONObject(Self.visibleChallengeProbeScript()) ?? ["detected": false]
        var verificationVisible = false
        if Self.humanVerificationRequiresUser(verification) {
            verificationVisible = await scrollToVisibleHumanVerification()
            try? await Task.sleep(nanoseconds: 180_000_000)
            verification = await evaluateJSONObject(Self.visibleChallengeProbeScript()) ?? verification
        }

        let pageInfo = await executeNativePageInfo(Self.browserContinuationCall(from: call))
        let viewportContext = await evaluateJSONObject(Self.viewportContextScript(textLimit: 2_600, elementLimit: 32)) ?? [:]
        let backbone = await evaluateJSONObject(Self.backboneScript(maxDepth: maxDepth)) ?? [:]
        let snapshot = await evaluateFullPageSnapshot(maxScrolls: maxScrolls)

        var findCall = Self.browserContinuationCall(from: call)
        findCall["scan_page"] = true
        findCall["full_page"] = true
        findCall["limit"] = elementLimit
        findCall["max_scrolls"] = maxScrolls
        findCall["capture_visuals"] = false
        findCall["screenshot"] = false
        let elements = await executeNativeFindElements(findCall)
        _ = await evaluateJSONObject(Self.scrollToPageYScript(originalY))

        let metrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) ?? originalMetrics
        let title = (snapshot?.title.isEmpty == false ? snapshot?.title : nil)
            ?? (metrics["title"] as? String)
            ?? webView?.title
            ?? ""
        let finalURL = (snapshot?.url.isEmpty == false ? snapshot?.url : nil)
            ?? (metrics["url"] as? String)
            ?? webView?.url?.absoluteString
            ?? ""
        let text = snapshot?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scrollY = Self.intValue(metrics["scroll_y"] ?? viewportContext["scroll_y"]) ?? 0
        let scrollHeight = Self.intValue(metrics["scroll_height"]) ?? 0
        let viewportHeight = Self.intValue(metrics["viewport_height"] ?? viewportContext["viewport_height"]) ?? 0
        let nearBottom = scrollHeight > 0 && viewportHeight > 0 && scrollY + viewportHeight >= scrollHeight - 24
        let canScrollDown = scrollHeight > 0 && viewportHeight > 0 && !nearBottom
        let requiresVerification = Self.humanVerificationRequiresUser(verification)

        return [
            "action": "browser.inspect",
            "ok": true,
            "title": title,
            "url": finalURL,
            "description": snapshot?.description ?? "",
            "published": snapshot?.published ?? "",
            "full_page": true,
            "max_scrolls": maxScrolls,
            "text": String(text.prefix(maxTextLength)),
            "text_length": text.count,
            "text_truncated": text.count > maxTextLength,
            "page_info": pageInfo,
            "viewport_context": viewportContext,
            "backbone": backbone["backbone"] ?? NSNull(),
            "elements": elements["items"] as? [[String: Any]] ?? [],
            "element_count": Self.intValue(elements["count"]) ?? 0,
            "total_element_count": Self.intValue(elements["total_count"] ?? elements["count"]) ?? 0,
            "scroll_y": scrollY,
            "scroll_height": scrollHeight,
            "viewport_height": viewportHeight,
            "can_scroll_down": canScrollDown,
            "near_bottom": nearBottom,
            "human_verification": verification,
            "requires_user_verification": requiresVerification,
            "verification_scrolled_into_view": verificationVisible,
            "attach_file": false,
            "preview_images": [],
            "summary": requiresVerification
                ? "已检查网页整页结构并定位到人机验证区域；请先在同一浏览器页面完成验证。"
                : "已按 Minis 风格检查网页：读取整页文本、结构骨架、当前视口和可交互元素。"
        ]
    }

    private func executeNativeObserve(_ call: [String: Any]) async -> [String: Any] {
        if let url = Self.urlValue(in: call),
           !(await load(url: url, timeout: 14, forceReload: Self.boolValue(call["force_reload"] ?? call["forceReload"] ?? call["reload"]) ?? false)) {
            return [
                "action": "browser.observe",
                "ok": false,
                "url": url.absoluteString,
                "error": "Failed to load webpage"
            ]
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let verification = await evaluateJSONObject(Self.visibleChallengeProbeScript()) ?? ["detected": false]
        let verificationRequiresUser = Self.humanVerificationRequiresUser(verification)
        var verificationVisible = false
        if verificationRequiresUser {
            verificationVisible = await scrollToVisibleHumanVerification()
            try? await Task.sleep(nanoseconds: 180_000_000)
        }

        let automationContext = await evaluateJSONObject(Self.browserAutomationStateScript(
            elementLimit: min(max(Self.intValue(call["observation_limit"] ?? call["observationLimit"] ?? call["element_limit"] ?? call["limit"]) ?? 48, 12), 100),
            textLimit: min(max(Self.intValue(call["observation_text_limit"] ?? call["observationTextLimit"] ?? call["max_length"]) ?? 2600, 600), 6000)
        )) ?? [:]
        let legacyContext = automationContext.isEmpty
            ? (await evaluateJSONObject(Self.viewportContextScript(textLimit: 2600, elementLimit: 32)) ?? [:])
            : [:]
        let context = automationContext.isEmpty ? legacyContext : automationContext
        let metrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) ?? [:]
        let includeScreenshot = Self.browserVisualObservationEnabled(in: call)
        let screenshot = includeScreenshot ? await captureViewportScreenshot(prefix: "browser_observe") : nil
        let title = (context["title"] as? String)
            ?? (metrics["title"] as? String)
            ?? webView?.title
            ?? ""
        let finalURL = (context["url"] as? String)
            ?? (metrics["url"] as? String)
            ?? webView?.url?.absoluteString
            ?? ""
        let visibleText = context["visible_text"] as? String ?? ""
        let visibleElements = (context["visible_elements"] as? [[String: Any]])
            ?? (context["interactive_elements"] as? [[String: Any]])
            ?? []
        let nextActionCandidates = context["action_candidates"] as? [[String: Any]] ?? []
        let scrollInfo = context["scroll"] as? [String: Any] ?? [:]
        let scrollY = Self.intValue(scrollInfo["y"] ?? context["scroll_y"] ?? metrics["scroll_y"]) ?? 0
        let scrollHeight = Self.intValue(scrollInfo["height"] ?? metrics["scroll_height"]) ?? 0
        let viewportHeight = Self.intValue(scrollInfo["viewport_height"] ?? metrics["viewport_height"] ?? context["viewport_height"]) ?? 0
        let nearBottom = scrollHeight > 0 && viewportHeight > 0 && scrollY + viewportHeight >= scrollHeight - 24
        let canScrollDown = (Self.boolValue(scrollInfo["can_scroll_down"]) ?? false)
            || (scrollHeight > 0 && viewportHeight > 0 && !nearBottom)
        let stateLabel: String
        if verificationRequiresUser {
            stateLabel = "needs_user_verification"
        } else if visibleElements.contains(where: { (($0["tag"] as? String) ?? "").lowercased() == "input" || (($0["tag"] as? String) ?? "").lowercased() == "textarea" }) {
            stateLabel = "form_available"
        } else if !nextActionCandidates.isEmpty {
            stateLabel = "actionable"
        } else if canScrollDown {
            stateLabel = "needs_more_scroll"
        } else {
            stateLabel = "ready"
        }

        let summaryText: String
        if verificationRequiresUser {
            summaryText = "已观察当前网页：发现人机验证，并已尝试滚动定位验证区域；等待用户在同一浏览器页面完成。"
        } else if !nextActionCandidates.isEmpty {
            summaryText = "已观察当前网页并找到 \(nextActionCandidates.count) 个可继续操作入口。"
        } else if canScrollDown {
            summaryText = "已观察当前网页视口；页面仍可继续向下滚动，继续任务前应按需滚动/扫描。"
        } else {
            summaryText = "已观察当前网页视口；页面已接近底部，可基于当前状态继续。"
        }

        var payload: [String: Any] = [
            "action": "browser.observe",
            "ok": true,
            "title": title,
            "url": finalURL,
            "ready_state": await evaluateString("document.readyState") ?? "",
            "scroll_y": scrollY,
            "scroll_height": scrollHeight,
            "viewport_height": viewportHeight,
            "viewport_width": Self.intValue(scrollInfo["viewport_width"] ?? metrics["viewport_width"] ?? context["viewport_width"]) ?? 0,
            "can_scroll_down": canScrollDown,
            "near_bottom": nearBottom,
            "visible_text": visibleText,
            "visible_elements": visibleElements,
            "visible_element_count": visibleElements.count,
            "next_action_candidates": nextActionCandidates,
            "next_action_candidate_count": Self.intValue(context["action_candidate_count"]) ?? nextActionCandidates.count,
            "post_action_observation": context,
            "viewport_context": context,
            "human_verification": verification,
            "requires_user_verification": verificationRequiresUser,
            "verification_scrolled_into_view": verificationVisible,
            "state_label": stateLabel,
            "attach_file": false,
            "preview_images": [],
            "summary": summaryText
        ]
        if let screenshot {
            payload["visual_observation"] = [
                "screenshot_url": screenshot.absoluteString,
                "file_path": screenshot.path,
                "tool_only": true,
                "note": "Tool-only current viewport screenshot. Do not show in chat unless the user explicitly asks."
            ]
        }
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
            : await capturePageThumbnail(prefix: "browser_viewport")
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
        var payload: [String: Any] = [
            "action": "browser.screenshot",
            "ok": true,
            "title": title,
            "url": url,
            "full_page": fullPage,
            "attach_preview": attachPreview,
            "attach_file": attachPreview,
            "preview_images": attachPreview ? [screenshot.absoluteString] : [],
            "visual_observation": [
                "screenshot_url": screenshot.absoluteString,
                "file_url": screenshot.absoluteString,
                "file_path": screenshot.path,
                "image_path": screenshot.path,
                "tool_only": true,
                "note": fullPage
                    ? "Tool-only full-page browser screenshot. Use it to decide the next browser action; do not show in chat unless the user asks."
                    : "Tool-only current viewport browser screenshot. Use it to decide the next browser action; do not show in chat unless the user asks."
            ],
            "items": [[
                "title": title,
                "link": url,
                "snippet": snapshot.map { String($0.text.prefix(260)) } ?? "",
                "thumbnail_url": attachPreview ? screenshot.absoluteString : ""
            ]],
            "summary": fullPage ? "已生成整页网页截图（仅供工具观察，不默认插入对话）。" : "已生成当前视口网页截图（仅供工具观察，不默认插入对话）。"
        ]
        if attachPreview {
            payload["screenshot_url"] = screenshot.absoluteString
            payload["file_url"] = screenshot.absoluteString
            payload["image_path"] = screenshot.path
            payload["file_path"] = screenshot.path
            payload["file_name"] = screenshot.lastPathComponent
            payload["content_type"] = "image/png"
        }
        return payload
    }

    private func executeNativeFetch(_ call: [String: Any]) async -> [String: Any] {
        let requestedURL = Self.urlValue(in: call, allowLocalFiles: false)
        guard let url = requestedURL ?? await currentPageURL(),
              Self.isHTTPBrowserURL(url) else {
            return [
                "action": "browser.fetch",
                "ok": false,
                "error": "Missing required field: url (and there is no active browser page to fetch)"
            ]
        }
        let wv = webViewReady()
        let targetLiteral = Self.javaScriptStringLiteral(url.absoluteString)
        let pageFetchScript = """
        (async () => {
          try {
            const resp = await fetch(\(targetLiteral), {
              credentials: 'include',
              cache: 'no-store',
              referrer: location.href
            });
            const buf = await resp.arrayBuffer();
            const bytes = new Uint8Array(buf);
            let binary = '';
            const chunk = 0x8000;
            for (let i = 0; i < bytes.length; i += chunk) {
              binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
            }
            return JSON.stringify({
              ok: true,
              base64: btoa(binary),
              contentType: resp.headers.get('content-type') || '',
              contentDisposition: resp.headers.get('content-disposition') || '',
              status: resp.status,
              statusText: resp.statusText || '',
              url: resp.url || \(targetLiteral),
              size: bytes.length,
              pageUrl: location.href,
              title: document.title || ''
            });
          } catch (error) {
            return JSON.stringify({
              ok: false,
              error: String(error && error.message ? error.message : error),
              pageUrl: location.href,
              title: document.title || ''
            });
          }
        })();
        """
        let evaluation = await evaluateJavaScriptString(pageFetchScript)
        var pageFetchError = evaluation.error ?? ""
        if let json = evaluation.string,
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if (object["ok"] as? Bool) != true {
                pageFetchError = object["error"] as? String ?? pageFetchError
            }
            if (object["ok"] as? Bool) == true,
               let base64 = object["base64"] as? String,
               let fetchedData = Data(base64Encoded: base64) {
                let status = Self.intValue(object["status"]) ?? 0
                let contentType = ((object["contentType"] as? String) ?? "application/octet-stream")
                    .components(separatedBy: ";")
                    .first ?? "application/octet-stream"
                let finalURL = URL(string: object["url"] as? String ?? "") ?? url
                let contentDisposition = object["contentDisposition"] as? String ?? ""
                let fileName = Self.fetchFileName(
                    for: finalURL,
                    contentType: contentType,
                    headers: contentDisposition.isEmpty ? [:] : ["Content-Disposition": contentDisposition]
                )
                do {
                    let folder = try browserOutputDirectory()
                    let fileURL = folder.appendingPathComponent(fileName)
                    try fetchedData.write(to: fileURL, options: [.atomic])
                    return [
                        "action": "browser.fetch",
                        "ok": (200..<300).contains(status),
                        "url": finalURL.absoluteString,
                        "requested_url": requestedURL?.absoluteString ?? url.absoluteString,
                        "page_url": object["pageUrl"] as? String ?? wv.url?.absoluteString ?? "",
                        "status": status,
                        "status_text": object["statusText"] as? String ?? "",
                        "file_url": fileURL.absoluteString,
                        "file_name": fileName,
                        "content_type": contentType,
                        "bytes": fetchedData.count,
                        "via": "wkwebview_fetch",
                        "summary": (200..<300).contains(status)
                            ? "已通过当前浏览器会话下载网页资源：\(fileName)"
                            : "网页返回 HTTP \(status)，已保存响应内容：\(fileName)"
                    ]
                } catch {
                    return [
                        "action": "browser.fetch",
                        "ok": false,
                        "url": finalURL.absoluteString,
                        "status": status,
                        "content_type": contentType,
                        "bytes": fetchedData.count,
                        "via": "wkwebview_fetch",
                        "error": "Failed to save fetched resource: \(error.localizedDescription)"
                    ]
                }
            }
        }

        var request = URLRequest(url: url, timeoutInterval: 24)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let userAgent = Self.browserUserAgentOverride(profile: browserUserAgentProfile) {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
        }
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8,*;q=0.6", forHTTPHeaderField: "Accept-Language")
        if let referer = wv.url?.absoluteString {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let cookies = await browserCookieHeader(for: url, webView: wv) {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return [
                    "action": "browser.fetch",
                    "ok": false,
                    "url": url.absoluteString,
                    "error": "Fetch failed: non-HTTP response",
                    "page_fetch_error": pageFetchError
                ]
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first ?? "application/octet-stream"
            let fileName = Self.fetchFileName(for: url, contentType: contentType, headers: http.allHeaderFields)
            let folder = try browserOutputDirectory()
            let fileURL = folder.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: [.atomic])
            return [
                "action": "browser.fetch",
                "ok": (200..<300).contains(http.statusCode),
                "url": url.absoluteString,
                "page_url": wv.url?.absoluteString ?? "",
                "status": http.statusCode,
                "file_url": fileURL.absoluteString,
                "file_name": fileName,
                "content_type": contentType,
                "bytes": data.count,
                "via": "urlsession_with_browser_session",
                "page_fetch_error": pageFetchError,
                "summary": (200..<300).contains(http.statusCode)
                    ? "已使用浏览器会话下载网页资源：\(fileName)"
                    : "网页返回 HTTP \(http.statusCode)，已保存响应内容：\(fileName)"
            ]
        } catch {
            return [
                "action": "browser.fetch",
                "ok": false,
                "url": url.absoluteString,
                "page_url": wv.url?.absoluteString ?? "",
                "page_fetch_error": pageFetchError,
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
        let nodeID = Self.firstString(in: call, keys: ["node_id", "nodeId", "accessibility_id", "accessibilityId"])
        let label = Self.firstString(in: call, keys: [
            "label", "button_text", "buttonText", "aria_label", "ariaLabel",
            "name", "title", "placeholder", "text"
        ])
        let x = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"])
        let y = Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"])
        let visualFallback = Self.boolValue(
            call["visual_fallback"] ?? call["visualFallback"] ?? call["screenshot_fallback"] ?? call["screenshotFallback"]
        ) ?? true
        guard selector != nil || nodeID != nil || label != nil || (x != nil && y != nil) else {
            return [
                "action": "browser.click",
                "ok": false,
                "error": "Missing selector, node_id, label, or coordinates"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const nodeId = \(Self.javascriptString(nodeID ?? ""));
          const desiredLabel = \(Self.javascriptString(label ?? ""));
          const x = \(x.map(String.init) ?? "null");
          const y = \(y.map(String.init) ?? "null");
          const clickableSelector = [
            'button', 'a[href]', 'input', 'textarea', 'select', 'summary', 'label', 'iframe',
            '[role="button"]', '[role="link"]', '[role="menuitem"]', '[role="tab"]',
            '[role="option"]', '[role="checkbox"]', '[role="radio"]', '[role="switch"]',
            '[onclick]', '[tabindex]', '[contenteditable]', '[jsaction]',
            '[aria-label]', '[aria-labelledby]', '[aria-describedby]',
            '[title]', '[alt]', '[data-testid]', '[data-test]', '[data-cy]'
          ].join(',');
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function accessibleText(node) {
            if (!node) return '';
            const labelledBy = attr(node, 'aria-labelledby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(id => document.getElementById(id))
              .map(text)
              .join(' ');
            const describedBy = attr(node, 'aria-describedby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(id => document.getElementById(id))
              .map(text)
              .join(' ');
            const id = attr(node, 'id');
            let labels = '';
            if (id && window.CSS && CSS.escape) {
              try {
                labels = Array.from(document.querySelectorAll(`label[for="${CSS.escape(id)}"]`)).map(text).join(' ');
              } catch (_) {}
            }
            const parts = [
              text(node),
              labelledBy,
              describedBy,
              labels,
              node.getAttribute ? node.getAttribute('aria-label') : '',
              node.getAttribute ? node.getAttribute('aria-description') : '',
              node.getAttribute ? node.getAttribute('title') : '',
              node.getAttribute ? node.getAttribute('alt') : '',
              node.getAttribute ? node.getAttribute('name') : '',
              node.getAttribute ? node.getAttribute('value') : '',
              node.getAttribute ? node.getAttribute('placeholder') : '',
              node.getAttribute ? node.getAttribute('data-testid') : '',
              node.getAttribute ? node.getAttribute('data-test') : '',
              node.getAttribute ? node.getAttribute('data-cy') : '',
              node.getAttribute ? node.getAttribute('jsaction') : '',
              node.getAttribute ? node.getAttribute('src') : '',
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
          function attr(node, name) {
            return node && node.getAttribute ? (node.getAttribute(name) || '') : '';
          }
          function isDisabled(node) {
            return Boolean(
              node &&
              (node.disabled ||
                attr(node, 'aria-disabled') === 'true' ||
                node.closest && node.closest('[disabled],[aria-disabled="true"]'))
            );
          }
          function clickTarget(node) {
            if (!node) return null;
            return node.closest && node.closest('button, a, input, textarea, select, summary, label, [contenteditable], [role="button"], [role="link"], [role="menuitem"], [role="tab"], [role="option"], [role="checkbox"], [role="radio"], [role="switch"], [onclick], [tabindex], [jsaction]')
              || node;
          }
          function clickableCandidates() {
            const nodes = [];
            for (const root of allRoots()) {
              try { nodes.push(...Array.from(root.querySelectorAll(clickableSelector))); } catch (_) {}
            }
            return nodes
              .map(clickTarget)
              .filter((node, index, list) => node && list.indexOf(node) === index && visible(node) && !isDisabled(node));
          }
          function hasValuedSearchEditable(form) {
            if (!form || !form.querySelectorAll) return false;
            try {
              return Array.from(form.querySelectorAll('input:not([type="hidden"]), textarea, [contenteditable], [role="textbox"]')).some(input => {
                if (!visible(input)) return false;
                const type = norm(attr(input, 'type'));
                if (['button', 'submit', 'reset', 'checkbox', 'radio', 'file', 'image', 'password'].includes(type)) return false;
                const key = norm([input.id || '', attr(input, 'name'), attr(input, 'class'), attr(input, 'placeholder'), attr(input, 'aria-label'), type, attr(input, 'role')].join(' '));
                const value = norm(input.value || text(input));
                return value.length > 0 && (/搜索|搜一下|百度一下|search|query|keyword|关键词|查找|请输入|输入|(^|[\\s_-])(q|kw|wd|word|query|search)([\\s_-]|$)/.test(key));
              });
            } catch (_) {
              return false;
            }
          }
          function clickableScore(node) {
            if (!node || !visible(node) || isDisabled(node)) return -100000;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = norm(attr(node, 'type'));
            const role = norm(attr(node, 'role'));
            const label = norm(accessibleText(node));
            const key = norm([
              node.id || '',
              attr(node, 'name'),
              attr(node, 'class'),
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              attr(node, 'formaction'),
              type,
              role,
              label
            ].join(' '));
            if ((tag === 'input' || tag === 'textarea') && !['submit', 'button', 'reset', 'image'].includes(type)) {
              return -10000;
            }
            let score = 0;
            const wanted = norm(desiredLabel);
            if (wanted) {
              if (label === wanted || key === wanted) score += 600;
              else if (label.startsWith(wanted) || key.includes(wanted)) score += 420;
              else if (label.includes(wanted) || wanted.includes(label)) score += 300;
              const tokens = wanted.split(/[\\s,，、]+/).filter(Boolean);
              for (const token of tokens) {
                if (token.length >= 2 && (label.includes(token) || key.includes(token))) score += 45;
              }
            }
            if (tag === 'button') score += 120;
            if (tag === 'input' && ['submit', 'button', 'image'].includes(type)) score += 130;
            if (role === 'button') score += 90;
            if (['menuitem', 'tab', 'option', 'checkbox', 'radio', 'switch'].includes(role)) score += 60;
            if (tag === 'a') score += 35;
            if (/百度一下|搜索|搜一下|查找|提交|确定|确认|继续|下一步|完成|发送|生成|打开|search|submit|go|continue|next|ok|confirm|send|generate/.test(label + ' ' + key)) score += 260;
            const form = node.closest && node.closest('form');
            if (hasValuedSearchEditable(form)) score += 420;
            if (form) {
              const formText = norm([attr(form, 'role'), attr(form, 'action'), attr(form, 'id'), attr(form, 'class'), attr(form, 'name')].join(' '));
              if (/search|query|百度|baidu|搜索|wd=|q=/.test(formText)) score += 120;
            }
            const r = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            if (r) {
              if (r.width >= 36 && r.height >= 24) score += 40;
              if (r.top >= -20 && r.top <= (innerHeight || 800) * 0.9) score += 20;
            }
            return score;
          }
          function bestClickableFallback() {
            const ranked = clickableCandidates()
              .map(node => ({ node, score: clickableScore(node) }))
              .sort((a, b) => b.score - a.score);
            if (!ranked.length) return null;
            if (ranked[0].score >= 180 || (ranked.length === 1 && ranked[0].score >= 40)) return ranked[0].node;
            return null;
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
            const successState = /成功|success|verified|验证成功|已验证/.test(bodyText);
            const hasChallengeWidget = Boolean(turnstile || recaptcha || frameDetected);
            const pendingText = /checking if the site connection is secure|checking your browser|正在检查/.test(bodyText);
            const completed = Boolean(tokenLength > 0 || successState || (!hasChallengeWidget && !textDetected && !pendingText));
            const detected = !completed && (hasChallengeWidget || textDetected || pendingText);
            const provider = turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (detected ? 'human_verification' : ''));
            return {
              detected,
              provider,
              token_length: tokenLength,
              completed,
              reason: provider && !completed ? 'Human verification is present but not completed.' : ''
            };
          }
          const storedNode = (() => {
            if (!nodeId || !window.__iexaNodeStore) return null;
            const item = window.__iexaNodeStore[nodeId];
            if (!item) return null;
            if (item.expiresAt && item.expiresAt < Date.now()) {
              try { delete window.__iexaNodeStore[nodeId]; } catch (_) {}
              return null;
            }
            const candidate = item.node;
            if (candidate) {
              const ownerRoot = candidate.ownerDocument && candidate.ownerDocument.documentElement;
              if ((document.documentElement && document.documentElement.contains(candidate)) ||
                  (ownerRoot && ownerRoot.contains(candidate))) return candidate;
            }
            try { delete window.__iexaNodeStore[nodeId]; } catch (_) {}
            return null;
          })();
          const explicitNode = storedNode
            || findNode(selector)
            || findByLabel(desiredLabel)
            || ((Number.isFinite(x) && Number.isFinite(y)) ? document.elementFromPoint(x, y) : null);
          const fallbackNode = explicitNode ? null : bestClickableFallback();
          const node = explicitNode || fallbackNode;
          if (!node) {
            return JSON.stringify({
              ok: false,
              error: 'Element not found',
              title: document.title || '',
              url: location.href,
              selector: selector || '',
              node_id: nodeId || '',
              label: desiredLabel || '',
              needs_visual_coordinates: true,
              searched_visible_clickables: true,
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
            isDisabled(target) ||
            isDisabled(node)
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
            fallback_click_selected: Boolean(fallbackNode && node === fallbackNode),
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
        let requiresVerification = Self.toolPayloadRequiresHumanVerification(payload)
        let clicked = Self.boolValue(payload["ok"]) ?? false
        if requiresVerification {
            _ = await scrollToVisibleHumanVerification()
            payload["summary"] = "网页需要先完成人机验证，目标按钮当前不可点击。请在浏览器中完成验证后继续。"
        } else if clicked {
            payload["summary"] = "已点击网页元素。"
        } else {
            if x == nil,
               y == nil,
               (selector != nil || label != nil),
               let recovered = await attemptClickByScanningPage(selector: selector, label: label) {
                return recovered
            }
            if visualFallback,
               Self.boolValue(payload["needs_visual_coordinates"]) == true,
               let screenshot = await captureViewportScreenshot(prefix: "browser_click_miss") {
                payload["attach_file"] = false
                payload["preview_images"] = []
                payload["visual_observation"] = [
                    "screenshot_url": screenshot.absoluteString,
                    "file_path": screenshot.path,
                    "tool_only": true,
                    "note": "Tool-only current viewport screenshot. Do not show in chat unless the user explicitly asks."
                ]
                payload["summary"] = "未在 DOM/可访问性文本中找到目标，已截取当前视口；请根据截图使用坐标点击重试，不要断定页面没有按钮。"
                return payload
            }
            payload["summary"] = (payload["error"] as? String) ?? "网页点击未完成。"
        }
        return await addingViewportVisualObservation(
            to: payload,
            call: call,
            prefix: "browser_click_after",
            note: "Tool-only current viewport after click. Use it as the primary visual state for the next browser action."
        )
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
        let nodeID = Self.firstString(in: call, keys: ["node_id", "nodeId", "accessibility_id", "accessibilityId"])
        let label = Self.firstString(in: call, keys: [
            "label", "field_label", "fieldLabel", "aria_label", "ariaLabel",
            "name", "title", "placeholder", "target"
        ])
        let x = Self.intValue(call["coordinate_x"] ?? call["x"] ?? call["client_x"])
        let y = Self.intValue(call["coordinate_y"] ?? call["y"] ?? call["client_y"])
        let text = Self.firstString(in: call, keys: ["text", "value", "input", "content", "message"]) ?? ""
        let clear = Self.boolValue(call["clear"] ?? call["replace"] ?? call["overwrite"]) ?? true
        let pressEnter = Self.boolValue(call["press_enter"] ?? call["enter"] ?? call["submit"]) ?? false
        guard selector != nil || label != nil || (x != nil && y != nil) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [
                "action": "browser.type",
                "ok": false,
                "error": "Missing selector, label, or coordinates"
            ]
        }

        let script = """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const nodeId = \(Self.javascriptString(nodeID ?? ""));
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
          function findStoredNode(raw) {
            if (!raw || !window.__iexaNodeStore) return null;
            const item = window.__iexaNodeStore[raw];
            if (!item) return null;
            if (item.expiresAt && item.expiresAt < Date.now()) {
              try { delete window.__iexaNodeStore[raw]; } catch (_) {}
              return null;
            }
            const node = item.node;
            if (node) {
              const ownerRoot = node.ownerDocument && node.ownerDocument.documentElement;
              if ((document.documentElement && document.documentElement.contains(node)) ||
                  (ownerRoot && ownerRoot.contains(node))) return node;
            }
            try { delete window.__iexaNodeStore[raw]; } catch (_) {}
            return null;
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
          function usableEditable(node) {
            if (!node || !isEditable(node) || !visible(node)) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = norm(attr(node, 'type'));
            if (tag === 'input' && ['button', 'submit', 'reset', 'checkbox', 'radio', 'hidden', 'file', 'image'].includes(type)) return false;
            return !Boolean(node.disabled || attr(node, 'aria-disabled') === 'true' || node.closest && node.closest('[disabled],[aria-disabled="true"]'));
          }
          function editableScore(node) {
            if (!usableEditable(node)) return -100000;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = norm(attr(node, 'type'));
            const role = norm(attr(node, 'role'));
            const label = norm(accessibleText(node));
            const key = norm([
              node.id || '',
              attr(node, 'name'),
              attr(node, 'class'),
              attr(node, 'autocomplete'),
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              type,
              role
            ].join(' '));
            let score = 0;
            if (document.activeElement === node) score += 500;
            if (tag === 'textarea') score += 70;
            if (tag === 'input') score += 50;
            if (node.isContentEditable || role === 'textbox') score += 60;
            if (type === 'search' || role === 'searchbox') score += 260;
            if (/(^|[\\s_-])(q|kw|wd|query|keyword|word|search|s)([\\s_-]|$)/.test(key)) score += 240;
            if (/搜索|搜一下|百度一下|search|query|keyword|关键词|查找|请输入|输入/.test(label + ' ' + key)) score += 220;
            const form = node.closest && node.closest('form');
            if (form) {
              const formText = norm([attr(form, 'role'), attr(form, 'action'), attr(form, 'id'), attr(form, 'class'), attr(form, 'name')].join(' '));
              if (/search|query|百度|baidu|搜索|wd=|q=/.test(formText)) score += 120;
            }
            const desired = norm(desiredLabel);
            const typed = norm(text);
            if (desired && desired !== typed) {
              score += Math.max(0, scoreLabel(node, desired));
            }
            const r = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            if (r) {
              if (r.width >= 120 && r.height >= 24) score += 80;
              if (r.width >= 220) score += 35;
              if (r.top >= -20 && r.top <= (innerHeight || 800) * 0.8) score += 25;
              score -= Math.max(0, Math.round(r.top / 1200));
            }
            if (!String(node.value || '').trim()) score += 25;
            if (type === 'password') score -= 10000;
            return score;
          }
          function bestEditableFallback() {
            const nodes = [];
            for (const root of allRoots()) {
              try { nodes.push(...Array.from(root.querySelectorAll(editableSelector))); } catch (_) {}
            }
            const ranked = nodes
              .filter(usableEditable)
              .map(node => ({ node, score: editableScore(node) }))
              .sort((a, b) => b.score - a.score);
            if (!ranked.length) return null;
            if (ranked[0].score >= 80 || ranked.length === 1) return ranked[0].node;
            return null;
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
            const successState = /成功|success|verified|验证成功|已验证/.test(bodyText);
            const hasChallengeWidget = Boolean(turnstile || recaptcha || frameDetected);
            const pendingText = /checking if the site connection is secure|checking your browser|正在检查/.test(bodyText);
            const completed = Boolean(tokenLength > 0 || successState || (!hasChallengeWidget && !textDetected && !pendingText));
            const detected = !completed && (hasChallengeWidget || textDetected || pendingText);
            const provider = turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (detected ? 'human_verification' : ''));
            return {
              detected,
              provider,
              token_length: tokenLength,
              completed,
              reason: provider && !completed ? 'Human verification is present but not completed.' : ''
            };
          }
          const coordinateNode = (Number.isFinite(x) && Number.isFinite(y)) ? document.elementFromPoint(x, y) : null;
          const explicitNode = editableTarget(findStoredNode(nodeId))
            || editableTarget(findNode(selector))
            || editableTarget(findByLabel(desiredLabel))
            || editableTarget(coordinateNode);
          const fallbackNode = explicitNode ? null : bestEditableFallback();
          const node = explicitNode || fallbackNode;
          if (!node) {
            return JSON.stringify({
              ok: false,
              error: 'Element not found',
              searched_visible_editables: true,
              recovery_hint: 'No label/selector matched and no usable visible input/search box fallback was safe to select.'
            });
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
              node_id: nodeId || '',
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
            try {
              const form = node.form || (node.closest && node.closest('form'));
              if (form) {
                const submitter = Array.from(form.querySelectorAll('button, input[type="submit"], input[type="image"], [role="button"]'))
                  .find(candidate => visible(candidate) && !Boolean(candidate.disabled || attr(candidate, 'aria-disabled') === 'true'));
                if (submitter && typeof submitter.click === 'function') submitter.click();
                else if (typeof form.requestSubmit === 'function') form.requestSubmit();
                else if (typeof form.submit === 'function') form.submit();
              }
            } catch (_) {}
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
            node_id: nodeId || '',
            label: desiredLabel || '',
            text: textOf(node).slice(0, 160),
            value: node.value || '',
            tag,
            fallback_input_selected: Boolean(fallbackNode && node === fallbackNode),
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
        let requiresVerification = Self.toolPayloadRequiresHumanVerification(payload)
        let typed = Self.boolValue(payload["ok"]) ?? false
        if requiresVerification {
            _ = await scrollToVisibleHumanVerification()
            payload["summary"] = "网页需要先完成人机验证，目标输入框当前不可用。请在浏览器中完成验证后继续。"
        } else if typed {
            payload["summary"] = "已向网页元素输入文本。"
        } else {
            if x == nil,
               y == nil,
               (selector != nil || label != nil),
               let recovered = await attemptTypeByScanningPage(
                   selector: selector,
                   label: label,
                   text: text,
                   clear: clear,
                   pressEnter: pressEnter
               ) {
                return recovered
            }
            payload["summary"] = (payload["error"] as? String) ?? "网页输入未完成。"
        }
        return await addingViewportVisualObservation(
            to: payload,
            call: call,
            prefix: "browser_type_after",
            note: "Tool-only current viewport after typing. Use it as the primary visual state for the next browser action."
        )
    }

    private func executeNativeAutoWorkflow(_ call: [String: Any]) async -> [String: Any] {
        var steps: [[String: Any]] = []
        var continuationCall = Self.browserContinuationCall(from: call)
        if continuationCall["screenshot"] == nil,
           continuationCall["visual_observation"] == nil,
           continuationCall["visual"] == nil,
           continuationCall["include_visual"] == nil,
           continuationCall["includeVisual"] == nil {
            continuationCall["visual_observation"] = true
        }
        let maxLoops = min(max(Self.intValue(call["max_loops"] ?? call["maxLoops"] ?? call["retries"]) ?? 6, 1), 12)
        let text = Self.firstString(in: call, keys: ["text", "value", "input", "content", "message", "prompt"])
        let isImageWorkflow = Self.browserAutoWorkflowLooksLikeImageGeneration(call: call, text: text)
        let isSearchWorkflow = Self.browserAutoWorkflowLooksLikeSearch(call: call, text: text)
        let requestedClickLabel = Self.firstString(in: call, keys: ["button_text", "buttonText", "button", "submit_label", "submitLabel", "click_label", "clickLabel"])
        let hasExplicitPostSearchClickTarget = isSearchWorkflow
            && requestedClickLabel.map { !Self.browserAutoClickLabelLooksLikeSearchSubmit($0) } == true
        let shouldWaitForImage = Self.boolValue(call["wait_for_image"] ?? call["waitForImage"] ?? call["image_result"] ?? call["imageResult"]) ?? isImageWorkflow
        let explicitResultPolling = Self.boolValue(
            call["poll_result"]
                ?? call["pollResult"]
                ?? call["wait_for_result"]
                ?? call["waitForResult"]
                ?? call["async_result"]
                ?? call["asyncResult"]
        )
        let shouldPollForAsyncResult = explicitResultPolling ?? (!shouldWaitForImage && !isSearchWorkflow)
        let resultPollTimeout = min(max(Self.intValue(
            call["poll_timeout"]
                ?? call["pollTimeout"]
                ?? call["result_timeout"]
                ?? call["resultTimeout"]
                ?? call["async_timeout"]
                ?? call["asyncTimeout"]
        ) ?? 45, 5), 180)
        let resultPollIntervalMS = min(max(Self.intValue(
            call["poll_interval_ms"]
                ?? call["pollIntervalMs"]
                ?? call["result_poll_interval_ms"]
                ?? call["resultPollIntervalMs"]
        ) ?? 1200, 500), 5000)
        var imageBaselineSources: [String] = []
        var submittedAction = false

        func appendStep(_ name: String, _ payload: [String: Any]) {
            steps.append(Self.workflowStep(name, payload))
        }

        func imageSources(from payload: [String: Any]) -> [String] {
            var sources = Self.stringArray(in: payload, keys: ["image_sources", "imageSources", "candidate_sources", "candidateSources"])
            if let candidates = payload["candidates"] as? [[String: Any]] {
                sources.append(contentsOf: candidates.compactMap { candidate in
                    (candidate["source_key"] as? String) ?? (candidate["src"] as? String)
                })
            }
            return Self.unique(sources)
        }

        func recordImageBaseline(from payload: [String: Any]) {
            imageBaselineSources = Self.unique(imageBaselineSources + imageSources(from: payload))
        }

        func probeWorkflowState(name: String) async -> [String: Any] {
            let state = await evaluateJSONObject(Self.generationWorkflowStateScript(
                expectedPrompt: text,
                excludeSources: imageBaselineSources
            )) ?? [
                "action": "browser.workflow_state",
                "ok": false,
                "error": "Unable to inspect workflow state"
            ]
            appendStep(name, state)
            return state
        }

        func generationFailedStopIfNeeded(_ payload: [String: Any]) -> [String: Any]? {
            let state = (payload["generation_state"] as? String ?? "").lowercased()
            guard ["failed", "retry"].contains(state) else { return nil }
            let retryVisible = Self.boolValue(payload["retry_visible"]) == true
            let generateEnabled = Self.boolValue(payload["generate_button_enabled"]) == true
            if retryVisible || generateEnabled || state == "retry" {
                return nil
            }
            let failure = payload["failure_text"] as? String
            let failureText = failure ?? ""
            let summary = !failureText.isEmpty
                ? "网页返回生成失败状态：\(failureText)"
                : "网页返回生成失败/重试状态，自动流程已停止。"
            return Self.workflowPayload(
                ok: false,
                steps: steps,
                summary: summary
            )
        }

        func promptVerified(_ payload: [String: Any], fallback: [String: Any]? = nil) -> Bool {
            if Self.boolValue(payload["prompt_value_verified"]) == true {
                return true
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.boolValue(fallback.flatMap { $0["ok"] }) == true
            }
            let expected = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let values = [
                payload["prompt_value"] as? String,
                fallback.flatMap { $0["value"] as? String },
                fallback.flatMap { $0["text"] as? String }
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return values.contains { value in
                !value.isEmpty && (value.contains(expected) || expected.contains(value))
            }
        }

        func afterClickLooksStarted(_ payload: [String: Any]) -> Bool {
            let state = (payload["generation_state"] as? String ?? "").lowercased()
            if ["generating", "waiting", "success"].contains(state) {
                return true
            }
            return (Self.intValue(payload["new_candidate_count"] ?? payload["candidate_count"]) ?? 0) > 0
        }

        func asyncResultLooksReady(state: [String: Any], textPayload: [String: Any]?, sawBusy: Bool) -> Bool {
            if Self.boolValue(state["async_result_detected"]) == true {
                return true
            }
            if (Self.intValue(state["new_candidate_count"] ?? state["candidate_count"]) ?? 0) > 0 {
                return true
            }
            if (Self.intValue(state["download_link_count"]) ?? 0) > 0 {
                return true
            }
            guard let textPayload,
                  Self.boolValue(textPayload["ok"]) == true else {
                return false
            }
            let pageText = (textPayload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageText.count >= 240 && sawBusy {
                return true
            }
            return false
        }

        func textSignature(_ payload: [String: Any]?) -> String {
            guard let payload else { return "" }
            let title = payload["title"] as? String ?? ""
            let url = payload["url"] as? String ?? ""
            let pageText = (payload["text"] as? String ?? "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return [
                title,
                url,
                String(pageText.count),
                String(pageText.prefix(180)),
                String(pageText.suffix(180))
            ].joined(separator: "|")
        }

        func pollForAsyncPageResult() async -> [String: Any]? {
            let deadline = Date().addingTimeInterval(TimeInterval(resultPollTimeout))
            let pollSleep = UInt64(resultPollIntervalMS) * 1_000_000
            var attempt = 0
            var sawBusy = false
            var stableReadySamples = 0
            var lastSignature = ""
            var bestText: [String: Any]?

            while Date() < deadline {
                let state = await probeWorkflowState(name: attempt == 0 ? "browser.workflow_state.poll_result" : "browser.workflow_state.poll_result_\(attempt)")
                if let stop = verificationStopIfNeeded(state) {
                    return stop
                }
                if let stop = generationFailedStopIfNeeded(state) {
                    return stop
                }

                let generationState = (state["generation_state"] as? String ?? "").lowercased()
                let busy = Self.boolValue(state["loading_visible"]) == true
                    || ["generating", "waiting", "queued", "processing"].contains(generationState)
                sawBusy = sawBusy || busy

                var textCall = continuationCall
                textCall["max_length"] = Self.intValue(call["max_length"] ?? call["limit"]) ?? 12_000
                textCall["max_scrolls"] = min(Self.intValue(call["max_scrolls"] ?? call["maxScrolls"] ?? call["scroll_count"] ?? call["count"]) ?? 8, 12)
                let textPayload = await executeNativeText(textCall)
                appendStep(attempt == 0 ? "browser.text.poll_result" : "browser.text.poll_result_\(attempt)", textPayload)
                if let stop = verificationStopIfNeeded(textPayload) {
                    return stop
                }
                if Self.boolValue(textPayload["ok"]) == true {
                    bestText = textPayload
                }

                let signature = textSignature(textPayload)
                let changed = !lastSignature.isEmpty && signature != lastSignature
                let ready = asyncResultLooksReady(state: state, textPayload: textPayload, sawBusy: sawBusy)
                if ready && (!busy || changed || stableReadySamples > 0) {
                    stableReadySamples += 1
                } else if ready && busy {
                    stableReadySamples = max(stableReadySamples, 1)
                } else {
                    stableReadySamples = 0
                }

                if stableReadySamples >= 2 || (ready && !busy && (sawBusy || changed) && explicitResultPolling != true) {
                    appendStep("browser.poll_result.completed", [
                        "ok": true,
                        "attempts": attempt + 1,
                        "saw_busy_state": sawBusy,
                        "summary": "已轮询到网页异步结果。"
                    ])
                    return textPayload
                }

                lastSignature = signature
                attempt += 1
                try? await Task.sleep(nanoseconds: pollSleep)
            }

            appendStep("browser.poll_result.timeout", [
                "ok": false,
                "attempts": attempt,
                "timeout": resultPollTimeout,
                "summary": "异步结果轮询超时，继续读取当前页面。"
            ])
            return bestText
        }

        func verificationStopIfNeeded(
            _ payload: [String: Any],
            summary: String = "网页需要先完成人机验证，已定位到验证区域。"
        ) -> [String: Any]? {
            guard Self.toolPayloadRequiresHumanVerification(payload) else { return nil }
            return Self.workflowPayload(
                ok: false,
                steps: steps,
                requiresVerification: true,
                summary: summary
            )
        }

        func scanPage(intent: String?, name: String, limit: Int = 48) async -> [String: Any] {
            var scanCall = continuationCall
            scanCall["scan_page"] = true
            scanCall["full_page"] = true
            scanCall["limit"] = limit
            scanCall["max_scrolls"] = Self.intValue(call["max_scrolls"] ?? call["maxScrolls"] ?? call["scroll_count"] ?? call["count"]) ?? 18
            if Self.browserMultiViewportVisualSamplingEnabled(in: call) {
                scanCall["capture_visuals"] = true
            } else {
                scanCall.removeValue(forKey: "capture_visuals")
            }
            scanCall["screenshot"] = false
            if let intent, !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scanCall["target"] = intent
                scanCall["query"] = intent
            }
            let scan = await executeNativeFindElements(scanCall)
            appendStep(name, scan)
            return scan
        }

        if let url = Self.urlValue(in: call) {
            let opened = await executeNativeOpen(call, readable: false)
            appendStep("browser.open", opened)
            if let stop = verificationStopIfNeeded(
                opened,
                summary: "网页需要先完成人机验证，已打开浏览器并定位验证区域。"
            ) {
                return stop
            }
            if Self.boolValue(opened["ok"]) != true {
                return Self.workflowPayload(
                    ok: false,
                    steps: steps,
                    summary: opened["error"] as? String ?? "自动浏览器流程未能打开网页。"
                )
            }
            var stableCall = continuationCall
            stableCall["timeout"] = min(Self.intValue(call["dom_timeout"] ?? call["domTimeout"] ?? call["timeout"]) ?? 8, 12)
            let stable = await executeNativeWaitForDOMStable(stableCall)
            appendStep("browser.wait_for_dom_stable.after_open", stable)
            if let stop = verificationStopIfNeeded(
                stable,
                summary: "网页需要先完成人机验证，已打开浏览器并定位验证区域。"
            ) {
                return stop
            }
            let observed = await executeNativeObserve(continuationCall)
            appendStep("browser.observe.after_open", observed)
            if let stop = verificationStopIfNeeded(
                observed,
                summary: "网页需要先完成人机验证，已打开浏览器并定位验证区域。"
            ) {
                return stop
            }
        } else {
            let observed = await executeNativeObserve(continuationCall)
            appendStep("browser.observe.initial", observed)
            if let stop = verificationStopIfNeeded(observed) {
                return stop
            }
        }

        let initialState = await probeWorkflowState(name: "browser.workflow_state.initial")
        if let stop = verificationStopIfNeeded(initialState) {
            return stop
        }
        recordImageBaseline(from: initialState)

        var inputScan: [String: Any]?
        var searchResultDetectedAfterTyping = false
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let inputIntent = Self.firstString(in: call, keys: ["field_hint", "fieldHint", "input_hint", "inputHint", "target", "field_label", "fieldLabel"])
                ?? "prompt description text input textarea"
            inputScan = await scanPage(intent: inputIntent, name: "browser.find_elements.before_type")
            if let scan = inputScan,
               let stop = verificationStopIfNeeded(scan) {
                return stop
            }

            let beforeType = await executeNativeObserve(continuationCall)
            appendStep("browser.observe.before_type", beforeType)
            if let stop = verificationStopIfNeeded(beforeType) {
                return stop
            }
            var typeCall = continuationCall
            typeCall["text"] = text
            if isSearchWorkflow,
               typeCall["press_enter"] == nil,
               typeCall["enter"] == nil,
               typeCall["submit"] == nil {
                typeCall["press_enter"] = true
            }
            if typeCall["label"] == nil,
               typeCall["field_label"] == nil,
               typeCall["placeholder"] == nil,
               typeCall["selector"] == nil {
                typeCall["target"] = Self.firstString(in: call, keys: ["field_hint", "fieldHint", "input_hint", "inputHint"])
                    ?? "prompt description text input"
            }
            if let rect = initialState["prompt_rect"] as? [String: Any],
               let coordinateCall = await browserCoordinateCall(from: ["rect": rect], baseCall: typeCall) {
                typeCall = coordinateCall
                typeCall["text"] = text
            }
            var typedOK = false
            var lastTyped: [String: Any]?
            for attempt in 0..<maxLoops {
                let typed = await executeNativeType(typeCall)
                appendStep(attempt == 0 ? "browser.type" : "browser.type.retry_\(attempt)", typed)
                lastTyped = typed
                if let stop = verificationStopIfNeeded(typed) {
                    return stop
                }
                if isSearchWorkflow,
                   Self.boolValue(typed["ok"]) == true {
                    let stableAfterSubmit = await executeNativeWaitForDOMStable(continuationCall)
                    appendStep(attempt == 0 ? "browser.wait_for_dom_stable.after_search_enter" : "browser.wait_for_dom_stable.after_search_enter_retry_\(attempt)", stableAfterSubmit)
                    if let stop = verificationStopIfNeeded(stableAfterSubmit) {
                        return stop
                    }
                    if await browserCurrentPageLooksLikeSearchResult(text: text) {
                        appendStep(attempt == 0 ? "browser.search_result.after_type" : "browser.search_result.after_type_retry_\(attempt)", [
                            "ok": true,
                            "summary": "输入并提交后已进入搜索结果页。"
                        ])
                        submittedAction = true
                        searchResultDetectedAfterTyping = true
                        typedOK = true
                        break
                    }
                }
                let afterType = await executeNativeObserve(continuationCall)
                appendStep(attempt == 0 ? "browser.observe.after_type" : "browser.observe.after_type_retry_\(attempt)", afterType)
                if let stop = verificationStopIfNeeded(afterType) {
                    return stop
                }
                let stateAfterType = await probeWorkflowState(name: attempt == 0 ? "browser.workflow_state.after_type" : "browser.workflow_state.after_type_retry_\(attempt)")
                if let stop = verificationStopIfNeeded(stateAfterType) {
                    return stop
                }
                recordImageBaseline(from: stateAfterType)
                if promptVerified(stateAfterType, fallback: typed) {
                    typedOK = true
                    break
                }
                if attempt == 0 {
                    inputScan = await scanPage(intent: inputIntent, name: "browser.find_elements.type_retry")
                    if let scan = inputScan,
                       let stop = verificationStopIfNeeded(scan) {
                        return stop
                    }
                    if let element = Self.bestScannedInputElement(in: inputScan),
                       let coordinateCall = await browserCoordinateCall(from: element, baseCall: typeCall) {
                        typeCall = coordinateCall
                        typeCall["text"] = text
                    }
                }
            }
            if !typedOK {
                return Self.workflowPayload(
                    ok: false,
                    steps: steps,
                    summary: lastTyped?["error"] as? String ?? lastTyped?["summary"] as? String ?? "自动流程未能输入文本。"
                )
            }
        }

        let shouldSkipClickAfterSearchResult = isSearchWorkflow
            && searchResultDetectedAfterTyping
            && !hasExplicitPostSearchClickTarget
        var buttonLabel = shouldSkipClickAfterSearchResult ? nil : requestedClickLabel
        if buttonLabel == nil && !shouldSkipClickAfterSearchResult {
            if text == nil {
                buttonLabel = Self.firstString(in: call, keys: ["target", "label"])
            } else if isImageWorkflow {
                buttonLabel = "generate create submit send start run continue next 免费生成 生成图片 立即生成 开始生成"
            } else if isSearchWorkflow {
                buttonLabel = "百度一下 搜索 搜一下 search submit go 确定"
            } else {
                buttonLabel = "submit send search start run continue next 提交 搜索 确定 继续 下一步 发送"
            }
        }
        if let buttonLabel {
            var clickScan = await scanPage(intent: buttonLabel, name: "browser.find_elements.before_click")
            if let stop = verificationStopIfNeeded(clickScan) {
                return stop
            }
            let beforeClickState = await probeWorkflowState(name: "browser.workflow_state.before_click")
            if let stop = verificationStopIfNeeded(beforeClickState) {
                return stop
            }
            recordImageBaseline(from: beforeClickState)
            if text != nil && !promptVerified(beforeClickState) {
                if isImageWorkflow {
                    return Self.workflowPayload(
                        ok: false,
                        steps: steps,
                        summary: "自动流程没有验证到提示词已进入网页输入框，已停止，避免误点生成。"
                    )
                }
            }
            let beforeClick = await executeNativeObserve(continuationCall)
            appendStep("browser.observe.before_click", beforeClick)
            if let stop = verificationStopIfNeeded(beforeClick) {
                return stop
            }
            var clickCall = continuationCall
            clickCall["label"] = buttonLabel
            clickCall["button_text"] = buttonLabel
            clickCall["visual_fallback"] = false
            if let rect = beforeClickState["generate_button_rect"] as? [String: Any],
               let coordinateCall = await browserCoordinateCall(from: ["rect": rect], baseCall: clickCall) {
                clickCall = coordinateCall
            }
            var clickedOK = false
            var lastClicked: [String: Any]?
            for attempt in 0..<maxLoops {
                let clicked = await executeNativeClick(clickCall)
                appendStep(attempt == 0 ? "browser.click" : "browser.click.retry_\(attempt)", clicked)
                lastClicked = clicked
                if let stop = verificationStopIfNeeded(clicked) {
                    return stop
                }
                let afterClick = await executeNativeObserve(continuationCall)
                appendStep(attempt == 0 ? "browser.observe.after_click" : "browser.observe.after_click_retry_\(attempt)", afterClick)
                if let stop = verificationStopIfNeeded(afterClick) {
                    return stop
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                let stateAfterClick = await probeWorkflowState(name: attempt == 0 ? "browser.workflow_state.after_click" : "browser.workflow_state.after_click_retry_\(attempt)")
                if let stop = verificationStopIfNeeded(stateAfterClick) {
                    return stop
                }
                if let stop = generationFailedStopIfNeeded(stateAfterClick) {
                    return stop
                }
                if shouldWaitForImage {
                    if afterClickLooksStarted(stateAfterClick) || Self.boolValue(clicked["ok"]) == true {
                        submittedAction = true
                        clickedOK = true
                        break
                    }
                } else if Self.boolValue(clicked["ok"]) == true {
                    submittedAction = true
                    clickedOK = true
                    break
                }
                if attempt == 0 {
                    clickScan = await scanPage(intent: buttonLabel, name: "browser.find_elements.click_retry")
                    if let stop = verificationStopIfNeeded(clickScan) {
                        return stop
                    }
                    if let element = Self.bestScannedClickableElement(in: clickScan),
                       let coordinateCall = await browserCoordinateCall(from: element, baseCall: clickCall) {
                        clickCall = coordinateCall
                    }
                }
            }
            if !clickedOK {
                if isSearchWorkflow,
                   await browserCurrentPageLooksLikeSearchResult(text: text) {
                    appendStep("browser.search_result.detected_after_type", [
                        "ok": true,
                        "summary": "输入后页面已进入搜索结果状态，跳过额外点击。"
                    ])
                    submittedAction = true
                } else {
                    return Self.workflowPayload(
                        ok: false,
                        steps: steps,
                        summary: shouldWaitForImage
                            ? "点击后没有验证到生成已开始或出现新结果，自动流程已停止。"
                            : (lastClicked?["error"] as? String ?? lastClicked?["summary"] as? String ?? "自动流程未能点击目标按钮。")
                    )
                }
            }
        }

        if shouldWaitForImage {
            var lastImage: [String: Any]?
            var lastState: [String: Any]?
            for waitAttempt in 0..<maxLoops {
                var waitCall = continuationCall
                if waitCall["timeout"] == nil {
                    waitCall["timeout"] = waitAttempt == 0 ? 90 : 60
                }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    waitCall["query"] = text
                    waitCall["expected_prompt"] = text
                }
                if !imageBaselineSources.isEmpty {
                    waitCall["exclude_sources"] = imageBaselineSources
                }
                let image = await executeNativeWaitForImage(waitCall)
                appendStep(waitAttempt == 0 ? "browser.wait_for_image" : "browser.wait_for_image.retry_\(waitAttempt)", image)
                lastImage = image
                let afterImageWait = await executeNativeObserve(continuationCall)
                appendStep(waitAttempt == 0 ? "browser.observe.after_wait_for_image" : "browser.observe.after_wait_for_image_retry_\(waitAttempt)", afterImageWait)
                if let stop = verificationStopIfNeeded(image) {
                    return stop
                }
                if let stop = verificationStopIfNeeded(afterImageWait) {
                    return stop
                }
                if Self.boolValue(image["ok"]) == true {
                    return Self.workflowPayload(
                        ok: true,
                        steps: steps,
                        fileURL: image["file_url"] as? String,
                        summary: image["summary"] as? String ?? "自动浏览器流程已完成。"
                    )
                }

                let state = await probeWorkflowState(name: waitAttempt == 0 ? "browser.workflow_state.after_wait_for_image" : "browser.workflow_state.after_wait_for_image_retry_\(waitAttempt)")
                lastState = state
                if let stop = verificationStopIfNeeded(state) {
                    return stop
                }
                if let stop = generationFailedStopIfNeeded(state) {
                    return stop
                }
                guard waitAttempt + 1 < maxLoops else { break }

                let retryVisible = Self.boolValue(state["retry_visible"]) == true
                let generateEnabled = Self.boolValue(state["generate_button_enabled"]) == true
                let generationState = (state["generation_state"] as? String ?? "").lowercased()
                guard retryVisible || generateEnabled || ["ready", "retry", "failed", "unknown", "idle"].contains(generationState) else {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }

                var retryClickCall = continuationCall
                let retryLabel = retryVisible
                    ? "点击重试 重试 try again retry"
                    : (buttonLabel ?? "generate create submit send start run continue next 免费生成 生成图片 立即生成 开始生成")
                retryClickCall["label"] = retryLabel
                retryClickCall["button_text"] = retryLabel
                retryClickCall["visual_fallback"] = false
                if let rect = state["generate_button_rect"] as? [String: Any],
                   let coordinateCall = await browserCoordinateCall(from: ["rect": rect], baseCall: retryClickCall) {
                    retryClickCall = coordinateCall
                }
                let retryClick = await executeNativeClick(retryClickCall)
                appendStep("browser.click.retry_generation_\(waitAttempt + 1)", retryClick)
                if let stop = verificationStopIfNeeded(retryClick) {
                    return stop
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                let retryObserve = await executeNativeObserve(continuationCall)
                appendStep("browser.observe.retry_generation_\(waitAttempt + 1)", retryObserve)
                if let stop = verificationStopIfNeeded(retryObserve) {
                    return stop
                }
            }

            let summary = lastImage?["summary"] as? String
                ?? lastImage?["error"] as? String
                ?? lastState?["summary"] as? String
                ?? "自动流程已持续尝试，但还没有拿到最终图片结果。"
            return Self.workflowPayload(
                ok: false,
                steps: steps,
                summary: summary
            )
        }

        var polledFinalText: [String: Any]?
        if shouldPollForAsyncResult && submittedAction {
            if let polled = await pollForAsyncPageResult() {
                if (polled["action"] as? String) == "browser.auto" {
                    return polled
                }
                polledFinalText = polled
            }
        }

        let stable = await executeNativeWaitForDOMStable(continuationCall)
        appendStep("browser.wait_for_dom_stable", stable)
        let finalObserve = await executeNativeObserve(continuationCall)
        appendStep("browser.observe.final", finalObserve)
        if let stop = verificationStopIfNeeded(stable) {
            return stop
        }
        if let stop = verificationStopIfNeeded(finalObserve) {
            return stop
        }
        var textCall = continuationCall
        textCall["max_length"] = Self.intValue(call["max_length"] ?? call["limit"]) ?? 12_000
        textCall["max_scrolls"] = Self.intValue(call["max_scrolls"] ?? call["maxScrolls"] ?? call["scroll_count"] ?? call["count"]) ?? 14
        let finalText: [String: Any]
        if let polledFinalText {
            finalText = polledFinalText
            appendStep("browser.text.final.from_poll", polledFinalText)
        } else {
            finalText = await executeNativeText(textCall)
            appendStep("browser.text.final", finalText)
        }
        if let stop = verificationStopIfNeeded(finalText) {
            return stop
        }

        var payload = Self.workflowPayload(
            ok: true,
            steps: steps,
            summary: isSearchWorkflow
                ? "自动搜索流程已完成，并已滚动读取结果页。"
                : "自动浏览器流程已完成，并已滚动读取最终页面。"
        )
        let title = finalText["title"] as? String ?? finalObserve["title"] as? String ?? ""
        let url = finalText["url"] as? String ?? finalObserve["url"] as? String ?? ""
        let pageText = finalText["text"] as? String ?? finalObserve["visible_text"] as? String ?? ""
        payload["title"] = title
        payload["url"] = url
        payload["text"] = pageText
        payload["full_page"] = Self.boolValue(finalText["full_page"]) ?? true
        payload["text_truncated"] = Self.boolValue(finalText["text_truncated"]) ?? false
        payload["attach_file"] = false
        payload["preview_images"] = []
        if !title.isEmpty || !url.isEmpty || !pageText.isEmpty {
            payload["items"] = [[
                "title": title.isEmpty ? "网页自动化结果" : title,
                "link": url,
                "snippet": String(pageText.prefix(360))
            ]]
        }
        return payload
    }

    private static func browserAutoWorkflowLooksLikeImageGeneration(call: [String: Any], text: String?) -> Bool {
        if Self.boolValue(call["wait_for_image"] ?? call["waitForImage"] ?? call["image_result"] ?? call["imageResult"]) == true {
            return true
        }
        let joined = [
            text,
            Self.firstString(in: call, keys: ["target", "label", "button_text", "buttonText", "submit_label", "submitLabel", "click_label", "clickLabel"]),
            Self.firstString(in: call, keys: ["url", "link", "href", "page_url", "source", "input_url"])
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let imageWords = ["生图", "生成图片", "图片生成", "画图", "出图", "image generation", "generate image", "text to image", "imagefree", "image-free"]
        let imageButtonWords = ["generate", "生成", "立即生成", "免费生成", "开始生成"]
        return imageWords.contains { joined.contains($0) }
            || (joined.contains("image") && imageButtonWords.contains { joined.contains($0) })
    }

    private static func browserAutoWorkflowLooksLikeSearch(call: [String: Any], text: String?) -> Bool {
        guard text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        if browserAutoWorkflowLooksLikeImageGeneration(call: call, text: text) {
            return false
        }
        let joined = [
            Self.firstString(in: call, keys: ["target", "label", "button_text", "buttonText", "submit_label", "submitLabel", "click_label", "clickLabel"]),
            Self.firstString(in: call, keys: ["field_hint", "fieldHint", "input_hint", "inputHint"]),
            Self.firstString(in: call, keys: ["url", "link", "href", "page_url", "source", "input_url"])
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if joined.contains("baidu")
            || joined.contains("bing")
            || joined.contains("google")
            || joined.contains("sogou")
            || joined.contains("so.com")
            || joined.contains("duckduckgo")
            || joined.contains("搜索")
            || joined.contains("搜一下")
            || joined.contains("百度一下")
            || joined.contains("search")
            || joined.contains("query") {
            return true
        }
        return Self.firstString(in: call, keys: ["query", "q", "keyword", "keywords"]) != nil
    }

    private static func browserAutoClickLabelLooksLikeSearchSubmit(_ label: String) -> Bool {
        let normalized = label
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }
        let submitWords = [
            "搜索", "搜一下", "百度一下", "查询", "检索",
            "search", "submit", "go", "query", "确定"
        ]
        let tokens = normalized
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
        if tokens.isEmpty {
            return submitWords.contains(normalized)
        }
        return tokens.allSatisfy { token in
            submitWords.contains { word in token == word || word == token }
        }
    }

    private func browserCurrentPageLooksLikeSearchResult(text: String?) async -> Bool {
        guard let object = await evaluateJSONObject(Self.searchResultStateScript(expectedText: text)) else {
            return false
        }
        return Self.boolValue(object["looks_like_search_result"]) == true
    }

    private static func browserContinuationCall(from call: [String: Any]) -> [String: Any] {
        var copy = call
        for key in ["url", "link", "href", "page_url", "source", "input_url"] {
            copy.removeValue(forKey: key)
        }
        copy["force_reload"] = false
        copy["forceReload"] = false
        copy["reload"] = false
        return copy
    }

    private func browserCoordinateCall(
        from item: [String: Any],
        baseCall: [String: Any]
    ) async -> [String: Any]? {
        guard let pageCenterX = Self.scannedElementPageCenterX(item),
              let pageCenterY = Self.scannedElementPageCenterY(item),
              let metrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) else {
            return nil
        }
        let viewportHeight = max(Self.intValue(metrics["viewport_height"]) ?? 720, 240)
        let maxY = max((Self.intValue(metrics["scroll_height"]) ?? viewportHeight) - viewportHeight, 0)
        let targetY = min(max(pageCenterY - viewportHeight / 2, 0), maxY)
        _ = await evaluateJSONObject(Self.scrollToPageYScript(targetY))
        try? await Task.sleep(nanoseconds: 220_000_000)
        let updatedMetrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) ?? metrics
        let scrollX = Self.intValue(updatedMetrics["scroll_x"]) ?? 0
        let scrollY = Self.intValue(updatedMetrics["scroll_y"]) ?? targetY

        var call = baseCall
        for key in [
            "selector", "css", "element", "label", "button_text", "buttonText",
            "aria_label", "ariaLabel", "name", "title", "placeholder", "target"
        ] {
            call.removeValue(forKey: key)
        }
        call["coordinate_x"] = max(pageCenterX - scrollX, 1)
        call["coordinate_y"] = max(pageCenterY - scrollY, 1)
        call["visual_fallback"] = false
        call["force_reload"] = false
        call["reload"] = false
        return call
    }

    private static func bestScannedInputElement(in payload: [String: Any]?) -> [String: Any]? {
        guard let items = payload?["items"] as? [[String: Any]] else { return nil }
        return rankedScannedElements(items).first { item in
            guard !isScannedElementDisabled(item) else { return false }
            let tag = ((item["tag"] as? String) ?? "").lowercased()
            let role = ((item["role"] as? String) ?? "").lowercased()
            let type = ((item["type"] as? String) ?? "").lowercased()
            if tag == "textarea" || tag == "select" { return true }
            if role == "textbox" { return true }
            if tag == "input" {
                return !["button", "submit", "reset", "checkbox", "radio", "hidden", "file"].contains(type)
            }
            return false
        }
    }

    private static func bestScannedClickableElement(in payload: [String: Any]?) -> [String: Any]? {
        guard let items = payload?["items"] as? [[String: Any]] else { return nil }
        return rankedScannedElements(items).first { item in
            guard !isScannedElementDisabled(item) else { return false }
            let tag = ((item["tag"] as? String) ?? "").lowercased()
            let role = ((item["role"] as? String) ?? "").lowercased()
            let type = ((item["type"] as? String) ?? "").lowercased()
            if tag == "button" || tag == "a" || role == "button" || role == "link" {
                return true
            }
            if tag == "input", ["button", "submit", "reset"].contains(type) {
                return true
            }
            return Self.scannedElementPageCenterX(item) != nil && Self.scannedElementPageCenterY(item) != nil
        }
    }

    private static func rankedScannedElements(_ items: [[String: Any]]) -> [[String: Any]] {
        items.sorted { lhs, rhs in
            let lhsScore = Self.intValue(lhs["match_score"]) ?? 0
            let rhsScore = Self.intValue(rhs["match_score"]) ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsY = Self.scannedElementPageCenterY(lhs) ?? Int.max
            let rhsY = Self.scannedElementPageCenterY(rhs) ?? Int.max
            if lhsY != rhsY { return lhsY < rhsY }
            let lhsIndex = Self.intValue(lhs["index"]) ?? Int.max
            let rhsIndex = Self.intValue(rhs["index"]) ?? Int.max
            return lhsIndex < rhsIndex
        }
    }

    private static func isScannedElementDisabled(_ item: [String: Any]) -> Bool {
        Self.boolValue(item["disabled"]) == true
            || Self.boolValue(item["blocked_by_human_verification"]) == true
    }

    private static func scannedElementPageCenterX(_ item: [String: Any]) -> Int? {
        if let direct = Self.intValue(item["page_center_x"]) {
            return direct
        }
        if let rect = item["rect"] as? [String: Any] {
            if let center = Self.intValue(rect["page_center_x"]) {
                return center
            }
            if let x = Self.intValue(rect["page_x"] ?? rect["x"]),
               let width = Self.intValue(rect["width"]) {
                return x + width / 2
            }
        }
        return nil
    }

    private static func scannedElementPageCenterY(_ item: [String: Any]) -> Int? {
        if let direct = Self.intValue(item["page_center_y"]) {
            return direct
        }
        if let rect = item["rect"] as? [String: Any] {
            if let center = Self.intValue(rect["page_center_y"]) {
                return center
            }
            if let y = Self.intValue(rect["page_y"] ?? rect["y"]),
               let height = Self.intValue(rect["height"]) {
                return y + height / 2
            }
        }
        return nil
    }

    private static func workflowStep(_ name: String, _ payload: [String: Any]) -> [String: Any] {
        var step: [String: Any] = [
            "step": name,
            "ok": Self.boolValue(payload["ok"]) ?? false,
            "summary": payload["summary"] as? String ?? payload["error"] as? String ?? "",
            "requires_user_verification": Self.toolPayloadRequiresHumanVerification(payload),
            "url": payload["url"] as? String ?? "",
            "title": payload["title"] as? String ?? "",
            "file_url": payload["file_url"] as? String ?? ""
        ]
        if let stateLabel = payload["state_label"] as? String, !stateLabel.isEmpty {
            step["state_label"] = stateLabel
        }
        if let visibleText = payload["visible_text"] as? String, !visibleText.isEmpty {
            step["visible_text_preview"] = String(visibleText.prefix(420))
        }
        if let visibleElementCount = Self.intValue(payload["visible_element_count"]) {
            step["visible_element_count"] = visibleElementCount
        }
        if let canScrollDown = Self.boolValue(payload["can_scroll_down"]) {
            step["can_scroll_down"] = canScrollDown
        }
        if let generationState = payload["generation_state"] as? String, !generationState.isEmpty {
            step["generation_state"] = generationState
        }
        if let promptVerified = Self.boolValue(payload["prompt_value_verified"]) {
            step["prompt_value_verified"] = promptVerified
        }
        if let generateEnabled = Self.boolValue(payload["generate_button_enabled"]) {
            step["generate_button_enabled"] = generateEnabled
        }
        if let newCandidateCount = Self.intValue(payload["new_candidate_count"]) {
            step["new_candidate_count"] = newCandidateCount
        }
        if let candidateCount = Self.intValue(payload["candidate_count"]) {
            step["candidate_count"] = candidateCount
        }
        if let failureText = payload["failure_text"] as? String, !failureText.isEmpty {
            step["failure_text"] = String(failureText.prefix(180))
        }
        if let screenshotURL = payload["screenshot_url"] as? String, !screenshotURL.isEmpty {
            step["screenshot_url"] = screenshotURL
        }
        if let screenshotPath = payload["screenshot_path"] as? String, !screenshotPath.isEmpty {
            step["screenshot_path"] = screenshotPath
        }
        if let visualObservation = payload["visual_observation"] as? [String: Any] {
            step["visual_observation"] = visualObservation
        }
        if let visualViewports = payload["visual_viewports"] as? [[String: Any]], !visualViewports.isEmpty {
            step["visual_viewports"] = visualViewports
        }
        return step
    }

    private static func workflowPayload(
        ok: Bool,
        steps: [[String: Any]],
        requiresVerification: Bool = false,
        fileURL: String? = nil,
        summary: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "action": "browser.auto",
            "ok": ok,
            "steps": steps,
            "step_count": steps.count,
            "requires_user_verification": requiresVerification,
            "summary": summary
        ]
        if let fileURL, !fileURL.isEmpty {
            payload["file_url"] = fileURL
            payload["attach_file"] = true
            payload["preview_images"] = [fileURL]
            payload["items"] = [[
                "title": "自动浏览器结果",
                "link": fileURL,
                "snippet": summary,
                "thumbnail_url": fileURL
            ]]
        }
        if let visual = Self.latestWorkflowVisualReference(in: steps) {
            payload["visual_observation"] = visual
        }
        return payload
    }

    private static func browserVisualObservationEnabled(in call: [String: Any]) -> Bool {
        for key in [
            "screenshot",
            "with_screenshot",
            "capture_screenshot",
            "captureScreenshot",
            "visual",
            "visual_observation",
            "include_visual",
            "includeVisual",
            "live_visual",
            "liveVisual",
            "vision"
        ] {
            if let value = Self.boolValue(call[key]) {
                return value
            }
        }
        return true
    }

    private static func browserMultiViewportVisualSamplingEnabled(in call: [String: Any]) -> Bool {
        for key in [
            "capture_visuals",
            "captureVisuals",
            "with_screenshots",
            "withScreenshots",
            "visual_viewports",
            "visualViewports",
            "full_page_visual",
            "fullPageVisual"
        ] {
            if let value = Self.boolValue(call[key]) {
                return value
            }
        }
        return false
    }

    private static func latestWorkflowVisualReference(in steps: [[String: Any]]) -> [String: Any]? {
        for step in steps.reversed() {
            if let visual = step["visual_observation"] as? [String: Any] {
                return visual
            }
            if let viewports = step["visual_viewports"] as? [[String: Any]],
               let visual = viewports.last {
                return visual
            }
            if let screenshotPath = step["screenshot_path"] as? String, !screenshotPath.isEmpty {
                var visual: [String: Any] = [
                    "file_path": screenshotPath,
                    "tool_only": true,
                    "note": "Tool-only browser screenshot for visual decision making."
                ]
                if let screenshotURL = step["screenshot_url"] as? String, !screenshotURL.isEmpty {
                    visual["screenshot_url"] = screenshotURL
                }
                return visual
            }
        }
        return nil
    }

    private func addingViewportVisualObservation(
        to payload: [String: Any],
        call: [String: Any],
        prefix: String,
        note: String
    ) async -> [String: Any] {
        guard Self.browserVisualObservationEnabled(in: call),
              payload["visual_observation"] == nil,
              let screenshot = await captureViewportScreenshot(prefix: prefix) else {
            return payload
        }
        var updated = payload
        updated["attach_file"] = false
        updated["preview_images"] = []
        updated["visual_observation"] = [
            "screenshot_url": screenshot.absoluteString,
            "file_path": screenshot.path,
            "tool_only": true,
            "note": note
        ]
        return updated
    }

    private func attemptTypeByScanningPage(
        selector: String?,
        label: String?,
        text: String,
        clear: Bool,
        pressEnter: Bool
    ) async -> [String: Any]? {
        guard let metrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) else {
            return nil
        }
        let originalY = Self.intValue(metrics["scroll_y"]) ?? 0
        let viewportHeight = max(Self.intValue(metrics["viewport_height"]) ?? 720, 240)
        let scrollHeight = max(Self.intValue(metrics["scroll_height"]) ?? viewportHeight, viewportHeight)
        let maxY = max(scrollHeight - viewportHeight, 0)
        let step = max(Int(Double(viewportHeight) * 0.72), 220)
        var offsets = [0]
        if maxY > 0 {
            var nextY = 0
            while nextY < maxY {
                offsets.append(nextY)
                nextY += step
            }
            offsets.append(maxY)
        }
        offsets = Self.sampledUniqueOffsets(offsets, limit: 22)

        for (index, offset) in offsets.enumerated() {
            _ = await evaluateJSONObject(Self.scrollToPageYScript(offset))
            try? await Task.sleep(nanoseconds: index == 0 ? 180_000_000 : 320_000_000)

            guard var object = await evaluateJSONObject(Self.typeVisibleElementScript(
                selector: selector,
                label: label,
                text: text,
                clear: clear,
                pressEnter: pressEnter
            )) else {
                continue
            }
            if Self.toolPayloadRequiresHumanVerification(object) {
                _ = await scrollToVisibleHumanVerification()
                object["action"] = "browser.type"
                object["auto_scanned_page"] = true
                object["scroll_positions"] = offsets.count
                object["summary"] = "网页需要先完成人机验证，已滚动到验证区域。"
                return object
            }
            if Self.boolValue(object["ok"]) == true {
                object["action"] = "browser.type"
                object["auto_scanned_page"] = true
                object["scroll_positions"] = offsets.count
                object["scroll_y"] = offset
                object["summary"] = "已自动滚动整页并向匹配输入框输入文本。"
                return object
            }
        }

        _ = await evaluateJSONObject(Self.scrollToPageYScript(originalY))
        return nil
    }

    private func attemptClickByScanningPage(selector: String?, label: String?) async -> [String: Any]? {
        guard let metrics = await evaluateJSONObject(Self.pageScrollMetricsScript()) else {
            return nil
        }
        let originalY = Self.intValue(metrics["scroll_y"]) ?? 0
        let viewportHeight = max(Self.intValue(metrics["viewport_height"]) ?? 720, 240)
        let scrollHeight = max(Self.intValue(metrics["scroll_height"]) ?? viewportHeight, viewportHeight)
        let maxY = max(scrollHeight - viewportHeight, 0)
        let step = max(Int(Double(viewportHeight) * 0.72), 220)
        var offsets = [0]
        if maxY > 0 {
            var nextY = 0
            while nextY < maxY {
                offsets.append(nextY)
                nextY += step
            }
            offsets.append(maxY)
        }
        offsets = Self.sampledUniqueOffsets(offsets, limit: 22)

        for (index, offset) in offsets.enumerated() {
            _ = await evaluateJSONObject(Self.scrollToPageYScript(offset))
            try? await Task.sleep(nanoseconds: index == 0 ? 180_000_000 : 320_000_000)

            guard var object = await evaluateJSONObject(Self.clickVisibleElementScript(selector: selector, label: label)) else {
                continue
            }
            if Self.toolPayloadRequiresHumanVerification(object) {
                _ = await scrollToVisibleHumanVerification()
                object["action"] = "browser.click"
                object["auto_scanned_page"] = true
                object["scroll_positions"] = offsets.count
                object["summary"] = "网页需要先完成人机验证，已滚动到验证区域。"
                return object
            }
            if Self.boolValue(object["ok"]) == true {
                object["action"] = "browser.click"
                object["auto_scanned_page"] = true
                object["scroll_positions"] = offsets.count
                object["scroll_y"] = offset
                object["summary"] = "已自动滚动整页并点击匹配的网页元素。"
                return object
            }
        }

        _ = await evaluateJSONObject(Self.scrollToPageYScript(originalY))
        return nil
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
          function visibleBox(node) {
            if (!node || !node.getBoundingClientRect) return null;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) === 0) return null;
            const rect = node.getBoundingClientRect();
            const width = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
            const height = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
            if (width < 8 || height < 8) return null;
            return { width, height, centerY: rect.top + rect.height / 2 };
          }
          function bestScrollable() {
            const doc = document.scrollingElement || document.documentElement || document.body;
            const documentScrollHeight = Math.max(
              document.documentElement.scrollHeight || 0,
              document.body ? document.body.scrollHeight || 0 : 0
            );
            const documentClientHeight = Math.max(
              window.innerHeight || 0,
              document.documentElement.clientHeight || 0,
              document.body ? document.body.clientHeight || 0 : 0
            );
            if (doc && documentScrollHeight > documentClientHeight + 20) {
              return doc;
            }
            let best = null;
            let bestScore = -1;
            const nodes = Array.from(document.querySelectorAll('*')).slice(0, 2000);
            for (const node of nodes) {
              if (node === document.documentElement || node === document.body) continue;
              const style = window.getComputedStyle(node);
              const scrollableY = /(auto|scroll|overlay)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 20;
              const scrollableX = /(auto|scroll)/.test(style.overflowX) && node.scrollWidth > node.clientWidth + 20;
              if (!scrollableY && !scrollableX) continue;
              const box = visibleBox(node);
              if (!box) continue;
              const scrollRange = Math.max(node.scrollHeight - node.clientHeight, node.scrollWidth - node.clientWidth, 0);
              const visibleArea = box.width * box.height;
              const centerPenalty = Math.abs(box.centerY - (innerHeight / 2)) / 8;
              const score = scrollRange + visibleArea / 20 - centerPenalty;
              if (score > bestScore) {
                best = node;
                bestScore = score;
              }
            }
            return best || doc || document.documentElement;
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
            target_kind: (node === document.scrollingElement || node === document.documentElement || node === document.body) ? 'document' : 'scroll_container',
            target_tag: (node && (node.tagName || node.nodeName) || '').toLowerCase(),
            scrollY: Math.round(window.scrollY || 0),
            scrollX: Math.round(window.scrollX || 0),
            target_scroll_top: Math.round(node && node.scrollTop || 0),
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
        return await addingViewportVisualObservation(
            to: payload,
            call: call,
            prefix: "browser_scroll_after",
            note: "Tool-only current viewport after scroll. Use it as the primary visual state for the next browser action."
        )
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

        let defaultSelector = """
        a[href], button, input, textarea, select, summary, label, iframe,
        [role='button'], [role='link'], [role='menuitem'], [role='tab'], [role='option'],
        [role='checkbox'], [role='radio'], [role='switch'], [role='textbox'], [role='searchbox'],
        [onclick], [tabindex], [contenteditable],
        [aria-label], [aria-labelledby], [aria-describedby], [title], [alt],
        [data-testid], [data-test], [data-cy], [jsaction],
        [data-click], [data-clickable], [data-href], [data-url], [data-link],
        [class*="btn"], [class*="button"], [class*="link"], [class*="tab"],
        [class*="nav"], [class*="menu"], [class*="item"], [class*="card"],
        [class*="result"], [class*="select"], [class*="dropdown"]
        """
        let selector = Self.firstString(in: call, keys: ["selector", "css"]) ?? defaultSelector
        let limit = min(max(Self.intValue(call["limit"] ?? call["max_results"]) ?? 30, 1), 100)
        let intent = Self.findElementsIntent(in: call)
        let filters = Self.findElementsFilters(in: call)
        let scanPage = Self.boolValue(call["scan_page"] ?? call["scanPage"] ?? call["full_page"] ?? call["fullPage"]) ?? true
        var captureVisuals = intent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        for key in [
            "capture_visuals", "captureVisuals",
            "with_screenshots", "withScreenshots",
            "screenshots", "visual", "visual_observation",
            "include_visuals", "includeVisuals", "screenshot"
        ] {
            if let value = Self.boolValue(call[key]) {
                captureVisuals = value
                break
            }
        }
        if scanPage {
            let maxScrolls = min(max(Self.intValue(call["max_scrolls"] ?? call["maxScrolls"] ?? call["scroll_count"] ?? call["count"]) ?? 16, 1), 20)
            return await executeNativeFindElementsAcrossPage(
                selector: selector,
                limit: limit,
                maxScrolls: maxScrolls,
                intent: intent,
                filters: filters,
                captureVisuals: captureVisuals
            )
        }

        let script = Self.elementCollectionScript(selector: selector, limit: limit, intent: intent, filters: filters)
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
        intent: String?,
        filters: [String: Any],
        captureVisuals: Bool
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
        let visualSampleLimit = min(4, viewportCount)
        let visualSampleIndexes: Set<Int> = {
            guard captureVisuals, viewportCount > 0 else { return [] }
            guard visualSampleLimit > 1 else { return [0] }
            let lastIndex = viewportCount - 1
            var indexes = Set<Int>()
            for index in 0..<visualSampleLimit {
                let rawIndex = Double(index) * Double(lastIndex) / Double(visualSampleLimit - 1)
                indexes.insert(min(max(Int(rawIndex.rounded()), 0), lastIndex))
            }
            return indexes
        }()

        for (viewportIndex, offset) in scrollOffsets.enumerated() {
            _ = await evaluateJSONObject(Self.scrollToPageYScript(offset))
            try? await Task.sleep(nanoseconds: viewportIndex == 0 ? 180_000_000 : 300_000_000)

            if captureVisuals && visualSampleIndexes.contains(viewportIndex) {
                if let screenshot = await captureViewportScreenshot(prefix: "browser_scan_\(viewportIndex)", scrollY: offset) {
                    visualViewports.append([
                        "viewport_index": viewportIndex,
                        "scroll_y": offset,
                        "screenshot_url": screenshot.absoluteString,
                        "file_path": screenshot.path,
                        "tool_only": true,
                        "note": "Tool-only viewport sample from full-page scan. Use with DOM/text samples to choose the next browser action."
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
                intent: intent,
                filters: filters
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

        let returnedItems = Self.prioritizedElements(collected, limit: limit)
        let verification = humanVerification ?? ["detected": false]
        let verificationRequiresUser = Self.humanVerificationRequiresUser(verification)
        var focusedElement: [String: Any]?
        var focusedScrollY: Int?
        var focusedVisual: [String: Any]?
        let summary: String
        if verificationRequiresUser {
            _ = await scrollToVisibleHumanVerification()
            summary = collected.isEmpty
                ? "网页存在未完成的人机验证，整页扫描后未找到匹配网页元素。"
                : "网页存在未完成的人机验证；已滚动扫描整页并找到 \(collected.count) 个网页元素，返回其中 \(returnedItems.count) 个代表项。"
        } else {
            if let first = returnedItems.first,
               let targetCenterY = Self.elementPageCenterY(first) ?? Self.elementPageY(first) {
                let targetY = min(max(targetCenterY - viewportHeight / 2, 0), maxY)
                _ = await evaluateJSONObject(Self.scrollToPageYScript(targetY))
                try? await Task.sleep(nanoseconds: 220_000_000)
                focusedElement = first
                focusedScrollY = targetY
                if captureVisuals,
                   let screenshot = await captureViewportScreenshot(prefix: "browser_find_focus", scrollY: targetY) {
                    focusedVisual = [
                        "screenshot_url": screenshot.absoluteString,
                        "file_path": screenshot.path,
                        "scroll_y": targetY,
                        "tool_only": true,
                        "note": "Tool-only focused viewport after full-page element scan. The browser is left near the best matching element so the next click/type/coordinate action can operate on the visible page."
                    ]
                }
            } else {
                _ = await evaluateJSONObject(Self.scrollToPageYScript(originalY))
            }
            summary = collected.isEmpty
                ? "整页扫描后未找到匹配网页元素。"
                : "已滚动扫描整页并找到 \(collected.count) 个网页元素，返回其中 \(returnedItems.count) 个代表项。"
        }

        var payload: [String: Any] = [
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
            "requires_user_verification": verificationRequiresUser,
            "count": returnedItems.count,
            "total_count": collected.count,
            "viewport_contexts": viewportContexts,
            "visual_viewports": visualViewports,
            "attach_file": false,
            "preview_images": [],
            "items": returnedItems,
            "summary": visualViewports.isEmpty ? summary : "\(summary) 已同步截取 \(visualViewports.count) 个滚动视口用于视觉核对。"
        ]
        if let focusedElement {
            payload["focused_element"] = focusedElement
        }
        if let focusedScrollY {
            payload["focused_scroll_y"] = focusedScrollY
            payload["current_scroll_y"] = focusedScrollY
            payload["summary"] = "\(payload["summary"] as? String ?? summary) 已停在最匹配元素附近。"
        }
        if let focusedVisual {
            payload["visual_observation"] = focusedVisual
        }
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
        let scriptLiteral = Self.javaScriptStringLiteral(script)
        let serializer = Self.safeJavaScriptResultSerializer()
        let asyncBody = """
        \(serializer)
        try {
          const source = \(scriptLiteral);
          const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
          const result = await AsyncFunction(source)();
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            result: __iexaSerializeJavaScriptResult(result)
          });
        } catch (error) {
          return JSON.stringify({
            ok: false,
            title: document.title || '',
            url: location.href,
            error: String(error && error.message ? error.message : error)
          });
        }
        """
        let syncWrapped = """
        (() => {
          \(serializer)
          try {
            const source = \(scriptLiteral);
            const result = Function(source)();
            if (result && typeof result.then === 'function') {
              return JSON.stringify({
                ok: false,
                title: document.title || '',
                url: location.href,
                error: 'JavaScript returned a Promise, but async JavaScript execution is unavailable in this WebKit context.'
              });
            }
            return JSON.stringify({
              ok: true,
              title: document.title || '',
              url: location.href,
              result: __iexaSerializeJavaScriptResult(result)
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
        let evaluation = await evaluateAsyncJavaScriptString(asyncBody, fallbackScript: syncWrapped)
        guard let json = evaluation.string,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "action": "browser.execute_js",
                "ok": false,
                "error": evaluation.error ?? "Unable to execute JavaScript",
                "result_type": evaluation.resultType ?? "",
                "result_preview": evaluation.resultPreview ?? ""
            ]
        }
        var payload = object
        payload["action"] = "browser.execute_js"
        payload["summary"] = (payload["ok"] as? Bool) == true ? "已执行网页脚本。" : "网页脚本执行失败。"
        return payload
    }

    private func executeNativeSetViewport(_ call: [String: Any]) async -> [String: Any] {
        if Self.boolValue(call["reset"] ?? call["clear"]) == true {
            browserViewportSize = Self.defaultMobileBrowserViewport
            browserDesktopModeExplicitlyEnabled = false
        } else if let width = Self.intValue(call["viewport_width"] ?? call["width"]),
                  let height = Self.intValue(call["viewport_height"] ?? call["height"]) {
            if Self.browserCallAllowsDesktopMode(call) {
                browserDesktopModeExplicitlyEnabled = true
            }
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
        if Self.browserCallAllowsDesktopMode(call) {
            browserDesktopModeExplicitlyEnabled = true
        }
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
            if let verification = await currentBlockingHumanVerification() {
                return await browserHumanVerificationPayload(
                    action: "browser.wait_for_dom_stable",
                    verification: verification,
                    summary: "网页需要先完成人机验证，已定位到验证区域。"
                )
            }
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
                return await addingViewportVisualObservation(
                    to: payload,
                    call: call,
                    prefix: "browser_dom_stable_after",
                    note: "Tool-only current viewport after DOM became stable. Use it as the primary visual state for the next browser action."
                )
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return await addingViewportVisualObservation(
            to: [
            "action": "browser.wait_for_dom_stable",
            "ok": false,
            "samples": Array(history.suffix(6)),
            "error": "Timed out waiting for DOM stability"
            ],
            call: call,
            prefix: "browser_dom_stable_timeout",
            note: "Tool-only current viewport after waiting for DOM stability timed out. Use it to decide whether to continue, click, scroll, or report a real blocker."
        )
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
        let query = Self.firstString(in: call, keys: ["query", "keywords", "hint", "expected_prompt", "expectedPrompt"])
        let excludeSources = Self.stringArray(in: call, keys: ["exclude_sources", "excludeSources", "baseline_sources", "baselineSources"])
        var lastCandidates: [[String: Any]] = []
        var lastState = ""
        var lastFailureText = ""

        while Date() < deadline {
            if let verification = await currentBlockingHumanVerification() {
                return await browserHumanVerificationPayload(
                    action: "browser.wait_for_image",
                    verification: verification,
                    summary: "网页需要先完成人机验证，已定位到验证区域。"
                )
            }
            if let object = await evaluateJSONObject(Self.generatedImageCandidateScript(
                minWidth: minWidth,
                minHeight: minHeight,
                query: query,
                excludeSources: excludeSources
            )) {
                lastState = object["generation_state"] as? String ?? lastState
                lastFailureText = object["failure_text"] as? String ?? lastFailureText
                if ["failed", "retry"].contains(lastState) {
                    return [
                        "action": "browser.wait_for_image",
                        "ok": false,
                        "title": object["title"] as? String ?? "",
                        "url": object["url"] as? String ?? "",
                        "generation_state": lastState,
                        "failure_text": lastFailureText,
                        "candidate_count": (object["candidate_count"] as? Int) ?? 0,
                        "error": lastFailureText.isEmpty ? "Page reported image generation failure" : lastFailureText,
                        "summary": lastFailureText.isEmpty
                            ? "网页返回生成失败状态，未保存旧图片。"
                            : "网页返回生成失败状态：\(lastFailureText)"
                    ]
                }
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
                        "source_key": candidate["source_key"] as? String ?? "",
                        "generation_state": object["generation_state"] as? String ?? "",
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
            "generation_state": lastState,
            "failure_text": lastFailureText,
            "excluded_source_count": excludeSources.count,
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
        notifyActiveBrowserDidChange()
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

        notifyActiveBrowserDidChange()
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

    private struct JavaScriptEvaluation {
        let string: String?
        let error: String?
        let resultType: String?
        let resultPreview: String?
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    private static func safeJavaScriptResultSerializer() -> String {
        """
        function __iexaSerializeJavaScriptResult(value) {
          const seen = typeof WeakSet === 'function' ? new WeakSet() : null;
          function textOf(input, limit) {
            return String(input == null ? '' : input).replace(/\\s+/g, ' ').trim().slice(0, limit || 1200);
          }
          function serialize(input, depth) {
            if (input === undefined || input === null) return null;
            const type = typeof input;
            if (type === 'string') return input.slice(0, 12000);
            if (type === 'boolean') return input;
            if (type === 'number') return Number.isFinite(input) ? input : String(input);
            if (type === 'bigint' || type === 'symbol' || type === 'function') return String(input);
            if (depth > 4) return textOf(input, 1000);
            if (input instanceof Date) return input.toISOString();
            if (typeof Node !== 'undefined' && input instanceof Node) {
              const element = input.nodeType === 1 ? input : input.parentElement;
              const rect = element && element.getBoundingClientRect ? element.getBoundingClientRect() : null;
              return {
                node_type: input.nodeType,
                tag: element && element.tagName ? element.tagName.toLowerCase() : '',
                id: element && element.id ? element.id : '',
                class: element && element.className ? textOf(element.className, 500) : '',
                text: textOf(input.innerText || input.textContent || '', 2000),
                value: element && 'value' in element ? textOf(element.value, 1000) : '',
                href: element && element.href ? String(element.href).slice(0, 2000) : '',
                rect: rect ? {
                  x: Math.round(rect.x),
                  y: Math.round(rect.y),
                  width: Math.round(rect.width),
                  height: Math.round(rect.height)
                } : null
              };
            }
            if (Array.isArray(input)) {
              return input.slice(0, 80).map(item => serialize(item, depth + 1));
            }
            if (type === 'object') {
              if (seen) {
                if (seen.has(input)) return '[Circular]';
                seen.add(input);
              }
              const output = {};
              const keys = Object.keys(input).slice(0, 80);
              for (const key of keys) {
                try {
                  output[key] = serialize(input[key], depth + 1);
                } catch (error) {
                  output[key] = String(error && error.message ? error.message : error);
                }
              }
              return output;
            }
            return textOf(input, 1000);
          }
          return serialize(value, 0);
        }
        """
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

    private func browserCookieHeader(for url: URL, webView: WKWebView) async -> String? {
        let cookies = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let host = url.host?.lowercased() ?? ""
        let siteRoot = Self.cookieSiteRoot(for: host)
        let pairs = cookies.compactMap { cookie -> String? in
            guard Self.cookieMatchesSite(cookie.domain, host: host, siteRoot: siteRoot) else { return nil }
            let path = url.path.isEmpty ? "/" : url.path
            guard path.hasPrefix(cookie.path) || cookie.path == "/" else { return nil }
            if cookie.isSecure, url.scheme?.lowercased() != "https" { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }

    private func activateBrowserTab(_ tabID: Int) {
        guard let tab = browserTabs[tabID] else { return }
        activeBrowserTabID = tabID
        webView = tab
        mountActiveBrowserIfPresented()
        notifyActiveBrowserDidChange()
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
            // A generic output/path hint is common in tool continuations. It
            // must not turn a current-page read into a download unless a URL
            // was explicitly supplied; explicit `fetch` still routes below.
            if wantsSave && hasURL { return "browser.fetch" }
            if hasScript { return "browser.execute_js" }
            if hasTypedText && (hasSelector || hasLabel || hasCoordinates) { return "browser.type" }
            if hasLabel || hasCoordinates { return "browser.click" }
            if hasSelector && wantsScreenshot { return "browser.screenshot" }
            if hasSelector { return "browser.find_elements" }
            if wantsScreenshot { return "browser.screenshot" }
            if hasURL { return "browser.navigate" }
            return "browser.screenshot"
        case "observe", "get_state", "state", "browser.observe", "browser.get_state":
            return "browser.observe"
        case "navigate", "open", "goto", "go", "go_to", "go_to_url", "browser.navigate", "browser.open":
            return "browser.navigate"
        case "readable", "get_readable", "read_webpage", "browser.readable":
            return "browser.readable"
        case "text", "get_text", "browser.text":
            return "browser.text"
        case "info", "get_page_info", "browser.info":
            return "browser.info"
        case "inspect", "page_inspect", "inspect_page", "page_state", "browser.inspect", "browser.page_state":
            return "browser.get_backbone"
        case "screenshot", "browser.screenshot":
            return "browser.screenshot"
        case "fetch", "download", "browser.fetch":
            return "browser.fetch"
        case "click", "browser.click":
            return "browser.click"
        case "type", "browser.type":
            return "browser.type"
        case "auto", "complete_task", "browser.auto", "browser.complete_task":
            return "browser.auto"
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
            if wantsSave && hasURL { return "browser.fetch" }
            if hasURL { return "browser.navigate" }
            return normalized.isEmpty ? "browser.screenshot" : normalized
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
          const scrollY = Math.round(window.scrollY || (document.documentElement && document.documentElement.scrollTop) || 0);
          const scrollHeight = Math.max(
            document.documentElement && document.documentElement.scrollHeight || 0,
            document.body && document.body.scrollHeight || 0,
            viewportHeight
          );
          const maxScrollY = Math.max(0, Math.round(scrollHeight - viewportHeight));
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
            'a[href]', 'button', 'input', 'textarea', 'select', 'summary', 'label', 'iframe',
            '[role="button"]', '[role="link"]', '[role="menuitem"]', '[role="tab"]', '[role="option"]',
            '[role="checkbox"]', '[role="radio"]', '[role="switch"]', '[role="textbox"]', '[role="searchbox"]',
            '[onclick]', '[tabindex]:not([tabindex="-1"])', '[contenteditable]',
            '[aria-label]', '[aria-labelledby]', '[aria-describedby]', '[title]', '[alt]',
            '[data-testid]', '[data-test]', '[data-cy]', '[jsaction]',
            '[data-click]', '[data-clickable]', '[data-href]', '[data-url]', '[data-link]',
            '[class*="btn"]', '[class*="button"]', '[class*="link"]', '[class*="tab"]',
            '[class*="nav"]', '[class*="menu"]', '[class*="item"]', '[class*="card"]',
            '[class*="result"]', '[class*="select"]', '[class*="dropdown"]'
          ].join(',');
          let rawElements = [];
          try { rawElements = Array.from(document.querySelectorAll(interactiveSelector)); } catch (_) { rawElements = []; }
          const elements = rawElements
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
            scroll_y: scrollY,
            scroll_height: Math.round(scrollHeight),
            max_scroll_y: maxScrollY,
            can_scroll_up: scrollY > 2,
            can_scroll_down: scrollY < maxScrollY - 2,
            scroll_progress: maxScrollY > 0 ? Math.max(0, Math.min(1, scrollY / maxScrollY)) : 1,
            viewport_width: Math.round(viewportWidth),
            viewport_height: Math.round(viewportHeight),
            visible_text: visibleText,
            interactive_elements: elements
          });
        })();
        """
    }

    private static func browserAutomationStateScript(elementLimit: Int, textLimit: Int) -> String {
        """
        (() => {
          const elementLimit = \(max(elementLimit, 0));
          const textLimit = \(max(textLimit, 0));
          const now = Date.now();
          const expiresAt = now + 10 * 60 * 1000;
          window.__iexaNodeStore = window.__iexaNodeStore || {};
          window.__iexaNodeSeq = Number(window.__iexaNodeSeq || 0);

          const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
          const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
          const doc = document.scrollingElement || document.documentElement || document.body;
          const scrollY = Math.round(window.scrollY || (doc && doc.scrollTop) || 0);
          const scrollX = Math.round(window.scrollX || (doc && doc.scrollLeft) || 0);
          const scrollHeight = Math.max(
            document.documentElement && document.documentElement.scrollHeight || 0,
            document.body && document.body.scrollHeight || 0,
            viewportHeight
          );
          const maxScrollY = Math.max(0, Math.round(scrollHeight - viewportHeight));
          const interactiveSelector = [
            'a[href]', 'button', 'input:not([type="hidden"])', 'textarea', 'select', 'summary', 'label', 'iframe',
            '[role="button"]', '[role="link"]', '[role="menuitem"]', '[role="tab"]', '[role="option"]',
            '[role="checkbox"]', '[role="radio"]', '[role="switch"]', '[role="textbox"]', '[role="searchbox"]',
            '[onclick]', '[tabindex]:not([tabindex="-1"])', '[contenteditable]',
            '[aria-label]', '[aria-labelledby]', '[aria-describedby]', '[title]', '[alt]',
            '[data-testid]', '[data-test]', '[data-cy]', '[jsaction]',
            '[data-click]', '[data-clickable]', '[data-href]', '[data-url]', '[data-link]',
            '[class*="btn"]', '[class*="button"]', '[class*="link"]', '[class*="tab"]',
            '[class*="nav"]', '[class*="menu"]', '[class*="item"]', '[class*="card"]',
            '[class*="result"]', '[class*="select"]', '[class*="dropdown"]'
          ].join(',');

          function clean(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim();
          }
          function attr(node, name) {
            return node && node.getAttribute ? clean(node.getAttribute(name)) : '';
          }
          function text(node) {
            return clean(node && (node.innerText || node.textContent) || '');
          }
          function allRoots() {
            const roots = [document];
            for (let i = 0; i < roots.length; i += 1) {
              const root = roots[i];
              let nodes = [];
              try { nodes = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : []; } catch (_) { nodes = []; }
              for (const node of nodes) {
                if (node.shadowRoot) roots.push(node.shadowRoot);
                const tag = (node.tagName || '').toLowerCase();
                if (tag === 'iframe') {
                  try {
                    if (node.contentDocument) roots.push(node.contentDocument);
                  } catch (_) {}
                }
              }
            }
            return roots;
          }
          function rectFor(node) {
            if (!node || !node.getBoundingClientRect) return null;
            const r = node.getBoundingClientRect();
            return {
              x: Math.round(r.left),
              y: Math.round(r.top),
              width: Math.round(r.width),
              height: Math.round(r.height),
              center_x: Math.round(r.left + r.width / 2),
              center_y: Math.round(r.top + r.height / 2),
              page_x: Math.round(r.left + scrollX),
              page_y: Math.round(r.top + scrollY),
              page_center_x: Math.round(r.left + scrollX + r.width / 2),
              page_center_y: Math.round(r.top + scrollY + r.height / 2)
            };
          }
          function visible(node) {
            if (!node || !node.getBoundingClientRect) return false;
            if (node.hidden || (node.closest && node.closest('[hidden],[aria-hidden="true"]'))) return false;
            const style = getComputedStyle(node);
            if (!style || style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) <= 0.01) return false;
            const r = node.getBoundingClientRect();
            const width = Math.max(0, Math.min(r.right, viewportWidth) - Math.max(r.left, 0));
            const height = Math.max(0, Math.min(r.bottom, viewportHeight) - Math.max(r.top, 0));
            return width > 2 && height > 2;
          }
          function disabled(node) {
            return Boolean(
              node &&
              (node.disabled ||
                attr(node, 'aria-disabled') === 'true' ||
                (node.closest && node.closest('[disabled],[aria-disabled="true"]')))
            );
          }
          function accessibleText(node) {
            if (!node) return '';
            const ownerDoc = node.ownerDocument || document;
            let labels = '';
            const id = attr(node, 'id');
            if (id && window.CSS && CSS.escape) {
              try {
                labels = Array.from(ownerDoc.querySelectorAll('label[for="' + CSS.escape(id) + '"]')).map(text).join(' ');
              } catch (_) {}
            }
            const labelledBy = attr(node, 'aria-labelledby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(idValue => ownerDoc.getElementById(idValue))
              .map(text)
              .join(' ');
            const describedBy = attr(node, 'aria-describedby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(idValue => ownerDoc.getElementById(idValue))
              .map(text)
              .join(' ');
            return clean([
              text(node),
              labels,
              labelledBy,
              describedBy,
              attr(node, 'aria-label'),
              attr(node, 'aria-description'),
              attr(node, 'placeholder'),
              attr(node, 'title'),
              attr(node, 'alt'),
              attr(node, 'name'),
              attr(node, 'value'),
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              node.value || ''
            ].filter(Boolean).join(' '));
          }
          function cssPath(node) {
            if (!node || !node.nodeType || node.nodeType !== 1) return '';
            if (node.id && window.CSS && CSS.escape) return '#' + CSS.escape(node.id);
            const ownerRoot = node.ownerDocument && node.ownerDocument.documentElement;
            const parts = [];
            let current = node;
            while (current && current.nodeType === 1 && current !== ownerRoot && current !== document.documentElement && parts.length < 5) {
              let name = (current.tagName || '').toLowerCase();
              if (!name) break;
              const cls = String(current.className || '').split(/\\s+/).filter(Boolean).slice(0, 2);
              if (window.CSS && CSS.escape) {
                for (const c of cls) name += '.' + CSS.escape(c);
              }
              const parent = current.parentElement;
              if (parent) {
                const siblings = Array.from(parent.children).filter(child => child.tagName === current.tagName);
                if (siblings.length > 1) name += ':nth-of-type(' + (siblings.indexOf(current) + 1) + ')';
              }
              parts.unshift(name);
              current = parent;
            }
            return parts.join(' > ');
          }
          function isEditable(node) {
            if (!node) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = attr(node, 'type').toLowerCase();
            if (tag === 'textarea' || tag === 'select') return true;
            if (tag === 'input') return !['button', 'submit', 'reset', 'checkbox', 'radio', 'hidden', 'file', 'image'].includes(type);
            return Boolean(node.isContentEditable || attr(node, 'role') === 'textbox' || attr(node, 'role') === 'searchbox');
          }
          function isClickable(node) {
            if (!node) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const role = attr(node, 'role').toLowerCase();
            const type = attr(node, 'type').toLowerCase();
            const className = String(node.className || '').toLowerCase();
            const id = attr(node, 'id').toLowerCase();
            const dataTarget = attr(node, 'data-click') || attr(node, 'data-clickable') || attr(node, 'data-href') || attr(node, 'data-url') || attr(node, 'data-link');
            if (tag === 'a' && attr(node, 'href')) return true;
            if (tag === 'button' || tag === 'summary' || tag === 'label' || tag === 'iframe') return true;
            if (tag === 'input' && ['button', 'submit', 'reset', 'image'].includes(type)) return true;
            if (['button', 'link', 'menuitem', 'tab', 'option', 'checkbox', 'radio', 'switch'].includes(role)) return true;
            if (dataTarget) return true;
            if (attr(node, 'onclick') || attr(node, 'jsaction') || attr(node, 'tabindex')) return true;
            if (/(^|[-_\\s])(btn|button|link|tab|nav|menu|item|card|result|select|dropdown)([-_\\s]|$)/.test(className + ' ' + id)) return true;
            try {
              const style = getComputedStyle(node);
              if (style && style.cursor === 'pointer') return true;
            } catch (_) {}
            return false;
          }
          function nodeKind(node) {
            if (isEditable(node)) return 'input';
            if ((node.tagName || '').toLowerCase() === 'iframe') return 'iframe';
            if (isClickable(node)) return 'clickable';
            return 'element';
          }
          function scoreNode(node) {
            const label = accessibleText(node).toLowerCase();
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const role = attr(node, 'role').toLowerCase();
            let score = 0;
            if (isEditable(node)) score += 500;
            if (isClickable(node)) score += 360;
            if (tag === 'iframe') score += 180;
            if (tag === 'button' || role === 'button') score += 140;
            if (/搜索|搜一下|百度一下|查找|输入|请输入|search|query|keyword|prompt|message/.test(label)) score += 220;
            if (/生成|提交|发送|继续|下一步|确认|登录|下载|打开|generate|submit|send|continue|next|confirm|login|download|open/.test(label)) score += 180;
            const r = rectFor(node);
            if (r) {
              if (r.width >= 32 && r.height >= 20) score += 20;
              score -= Math.max(0, Math.round(Math.abs(r.center_y - viewportHeight / 2) / 80));
            }
            if (disabled(node)) score -= 1000;
            return score;
          }
          function storeNode(node) {
            const id = 'dom-' + (++window.__iexaNodeSeq);
            window.__iexaNodeStore[id] = { node, expiresAt };
            return id;
          }
          function humanVerificationState() {
            const turnstile = document.querySelector('[name="cf-turnstile-response"], input[id^="cf-chl-widget"], .cf-turnstile, [data-sitekey]');
            const recaptcha = document.querySelector('[name="g-recaptcha-response"], .g-recaptcha, iframe[src*="recaptcha"]');
            const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || attr(frame, 'aria-label')).join(' ');
            const bodyText = clean(document.body && document.body.innerText || '').toLowerCase();
            const textDetected = /prove you are human|verify you are human|checking if the site connection is secure|captcha|turnstile|recaptcha|验证你是真人|人机验证/.test(bodyText);
            const frameDetected = /turnstile|captcha|recaptcha|challenge/.test(frames.toLowerCase());
            const tokenNode = turnstile || recaptcha;
            const tokenLength = tokenNode && 'value' in tokenNode ? String(tokenNode.value || '').length : 0;
            const completed = Boolean(tokenLength > 0 || (!turnstile && !recaptcha && !textDetected && !frameDetected));
            const detected = !completed && (Boolean(turnstile || recaptcha) || textDetected || frameDetected);
            return {
              detected,
              completed,
              provider: turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (detected ? 'human_verification' : '')),
              token_length: tokenLength
            };
          }

          const seen = new Set();
          const elements = [];
          for (const root of allRoots()) {
            let nodes = [];
            try { nodes = Array.from(root.querySelectorAll(interactiveSelector)); } catch (_) { nodes = []; }
            try {
              for (const candidate of Array.from(root.querySelectorAll('div, span, li, p, section, article, header, footer'))) {
                if (isEditable(candidate) || isClickable(candidate)) nodes.push(candidate);
              }
            } catch (_) {}
            for (const node of nodes) {
              if (!visible(node)) continue;
              const key = [
                (node.tagName || '').toLowerCase(),
                attr(node, 'id'),
                attr(node, 'href'),
                attr(node, 'name'),
                attr(node, 'aria-label'),
                attr(node, 'placeholder'),
                accessibleText(node).slice(0, 80),
                JSON.stringify(rectFor(node) || {})
              ].join('|').toLowerCase();
              if (seen.has(key)) continue;
              seen.add(key);
              const nodeId = storeNode(node);
              const kind = nodeKind(node);
              const item = {
                node_id: nodeId,
                nodeId: nodeId,
                kind,
                tag: (node.tagName || node.nodeName || '').toLowerCase(),
                role: attr(node, 'role'),
                type: attr(node, 'type'),
                text: text(node).slice(0, 180),
                label: accessibleText(node).slice(0, 240),
                aria_label: attr(node, 'aria-label').slice(0, 180),
                placeholder: attr(node, 'placeholder').slice(0, 180),
                title: attr(node, 'title').slice(0, 180),
                href: attr(node, 'href').slice(0, 500),
                src: attr(node, 'src').slice(0, 500),
                id: attr(node, 'id'),
                name: attr(node, 'name'),
                selector: cssPath(node),
                rect: rectFor(node) || {},
                clickable: isClickable(node),
                editable: isEditable(node),
                disabled: disabled(node),
                score: scoreNode(node)
              };
              elements.push(item);
            }
          }
          elements.sort((a, b) => (b.score - a.score) || ((a.rect.page_y || 0) - (b.rect.page_y || 0)));
          const visibleElements = elements.slice(0, elementLimit).map((item, index) => Object.assign({ index }, item));
          const candidates = [];
          for (const item of visibleElements) {
            if (item.disabled) continue;
            if (item.editable) {
              candidates.push({
                action: 'browser.type',
                node_id: item.node_id,
                selector: item.selector,
                label: item.label || item.placeholder || item.name || item.id,
                reason: 'visible editable field',
                confidence: Math.min(0.98, Math.max(0.55, item.score / 900))
              });
            } else if (item.clickable) {
              candidates.push({
                action: 'browser.click',
                node_id: item.node_id,
                selector: item.selector,
                label: item.label || item.text || item.title || item.id,
                reason: 'visible clickable element',
                confidence: Math.min(0.98, Math.max(0.50, item.score / 850))
              });
            }
          }
          if (scrollY > 2) {
            candidates.push({ action: 'browser.scroll', direction: 'up', amount: 500, reason: 'page can scroll up', confidence: 0.55 });
          }
          if (scrollY < maxScrollY - 2) {
            candidates.push({ action: 'browser.scroll', direction: 'down', amount: 650, reason: 'page can scroll down', confidence: 0.72 });
          }

          const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
              const value = clean(node.nodeValue);
              if (!value) return NodeFilter.FILTER_REJECT;
              const parent = node.parentElement;
              if (!parent || !visible(parent)) return NodeFilter.FILTER_REJECT;
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
          const verification = humanVerificationState();
          const readyState = document.readyState || '';
          let stateLabel = 'ready';
          if (verification.detected && !verification.completed) stateLabel = 'needs_user_verification';
          else if (readyState !== 'complete') stateLabel = 'loading';
          else if (visibleElements.some(item => item.editable)) stateLabel = 'form_available';
          else if (scrollY < maxScrollY - 2) stateLabel = 'can_scroll';

          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            ready_state: readyState,
            state_label: stateLabel,
            scroll: {
              x: scrollX,
              y: scrollY,
              max_y: maxScrollY,
              height: Math.round(scrollHeight),
              viewport_width: Math.round(viewportWidth),
              viewport_height: Math.round(viewportHeight),
              can_scroll_up: scrollY > 2,
              can_scroll_down: scrollY < maxScrollY - 2,
              progress: maxScrollY > 0 ? Math.max(0, Math.min(1, scrollY / maxScrollY)) : 1
            },
            visible_text: clean(chunks.join(' ')).slice(0, textLimit),
            visible_elements: visibleElements,
            visible_element_count: visibleElements.length,
            total_detected_element_count: elements.length,
            action_candidates: candidates.slice(0, Math.max(1, Math.min(12, elementLimit))),
            action_candidate_count: candidates.length,
            human_verification: verification,
            requires_user_verification: verification.detected && !verification.completed
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

    private static func elementPageCenterY(_ item: [String: Any]) -> Int? {
        if let direct = Self.intValue(item["page_center_y"]) {
            return direct
        }
        if let rect = item["rect"] as? [String: Any] {
            if let center = Self.intValue(rect["page_center_y"] ?? rect["center_y"]) {
                return center
            }
            if let y = Self.intValue(rect["page_y"] ?? rect["y"]) {
                let height = Self.intValue(rect["height"]) ?? 0
                return y + max(height / 2, 0)
            }
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

    private static func findElementsFilters(in call: [String: Any]) -> [String: Any] {
        var filters: [String: Any] = [:]
        let stringAliases: [(String, [String])] = [
            ("text", ["text"]),
            ("text_contains", ["text_contains", "text-contains", "contains_text", "containsText"]),
            ("desc", ["desc", "contentDesc", "content_desc", "aria_label", "ariaLabel"]),
            ("desc_contains", ["desc_contains", "desc-contains", "content_desc_contains", "contentDescContains"]),
            ("id", ["id", "resourceId", "resource_id", "resource-id"]),
            ("class", ["class", "className", "class_name", "classes"]),
            ("package", ["package", "packageName", "package_name", "host", "hostname"])
        ]
        for (canonical, aliases) in stringAliases {
            guard let value = Self.firstString(in: call, keys: aliases),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            filters[canonical] = value
        }
        let boolAliases: [(String, [String])] = [
            ("clickable", ["clickable"]),
            ("editable", ["editable"]),
            ("scrollable", ["scrollable"]),
            ("checked", ["checked"]),
            ("enabled", ["enabled"]),
            ("visible", ["visible"]),
            ("checkable", ["checkable"]),
            ("selected", ["selected"])
        ]
        for (canonical, aliases) in boolAliases {
            for alias in aliases {
                if let value = Self.boolValue(call[alias]) {
                    filters[canonical] = value
                    break
                }
            }
        }
        return filters
    }

    private static func javascriptObject(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func clickVisibleElementScript(selector: String?, label: String?) -> String {
        """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const desiredLabel = \(Self.javascriptString(label ?? ""));
          const clickableSelector = [
            'button', 'a[href]', 'input', 'textarea', 'select', 'summary', 'label', 'iframe',
            '[role="button"]', '[role="link"]', '[role="menuitem"]', '[role="tab"]',
            '[role="option"]', '[role="checkbox"]', '[role="radio"]', '[role="switch"]',
            '[onclick]', '[tabindex]', '[contenteditable]', '[jsaction]',
            '[aria-label]', '[aria-labelledby]', '[aria-describedby]',
            '[title]', '[alt]', '[data-testid]', '[data-test]', '[data-cy]'
          ].join(',');
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
          function text(node) {
            return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim();
          }
          function accessibleText(node) {
            if (!node) return '';
            const labelledBy = attr(node, 'aria-labelledby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(id => document.getElementById(id))
              .map(text)
              .join(' ');
            const describedBy = attr(node, 'aria-describedby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(id => document.getElementById(id))
              .map(text)
              .join(' ');
            const id = attr(node, 'id');
            let labels = '';
            if (id && window.CSS && CSS.escape) {
              try {
                labels = Array.from(document.querySelectorAll(`label[for="${CSS.escape(id)}"]`)).map(text).join(' ');
              } catch (_) {}
            }
            const parts = [
              text(node),
              labelledBy,
              describedBy,
              labels,
              node.getAttribute ? node.getAttribute('aria-label') : '',
              node.getAttribute ? node.getAttribute('aria-description') : '',
              node.getAttribute ? node.getAttribute('title') : '',
              node.getAttribute ? node.getAttribute('alt') : '',
              node.getAttribute ? node.getAttribute('name') : '',
              node.getAttribute ? node.getAttribute('value') : '',
              node.getAttribute ? node.getAttribute('placeholder') : '',
              node.getAttribute ? node.getAttribute('data-testid') : '',
              node.getAttribute ? node.getAttribute('data-test') : '',
              node.getAttribute ? node.getAttribute('data-cy') : '',
              node.getAttribute ? node.getAttribute('jsaction') : '',
              node.value || '',
              node.placeholder || ''
            ];
            return parts.filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim();
          }
          function attr(node, name) {
            return node && node.getAttribute ? (node.getAttribute(name) || '') : '';
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
          function findStoredNode(raw) {
            if (!raw || !window.__iexaNodeStore) return null;
            const item = window.__iexaNodeStore[raw];
            if (!item) return null;
            if (item.expiresAt && item.expiresAt < Date.now()) {
              try { delete window.__iexaNodeStore[raw]; } catch (_) {}
              return null;
            }
            const node = item.node;
            if (node) {
              const ownerRoot = node.ownerDocument && node.ownerDocument.documentElement;
              if ((document.documentElement && document.documentElement.contains(node)) ||
                  (ownerRoot && ownerRoot.contains(node))) return node;
            }
            try { delete window.__iexaNodeStore[raw]; } catch (_) {}
            return null;
          }
          function deepQuerySelector(raw) {
            if (!raw) return null;
            for (const root of allRoots()) {
              try {
                const match = root.querySelector(raw);
                if (match && visible(match)) return match;
              } catch (_) {
                return null;
              }
            }
            return null;
          }
          function findByLabel(raw) {
            const wanted = norm(raw);
            if (!wanted) return null;
            const candidates = [];
            for (const root of allRoots()) {
              try { candidates.push(...Array.from(root.querySelectorAll(clickableSelector))); } catch (_) {}
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
          function isDisabled(node) {
            return Boolean(
              node &&
              (node.disabled ||
                attr(node, 'aria-disabled') === 'true' ||
                node.closest && node.closest('[disabled],[aria-disabled="true"]'))
            );
          }
          function clickTarget(node) {
            if (!node) return null;
            return node.closest && node.closest('button, a, input, textarea, select, summary, label, [contenteditable], [role="button"], [role="link"], [role="menuitem"], [role="tab"], [role="option"], [role="checkbox"], [role="radio"], [role="switch"], [onclick], [tabindex], [jsaction]')
              || node;
          }
          function clickableCandidates() {
            const nodes = [];
            for (const root of allRoots()) {
              try { nodes.push(...Array.from(root.querySelectorAll(clickableSelector))); } catch (_) {}
            }
            return nodes
              .map(clickTarget)
              .filter((node, index, list) => node && list.indexOf(node) === index && visible(node) && !isDisabled(node));
          }
          function hasValuedSearchEditable(form) {
            if (!form || !form.querySelectorAll) return false;
            try {
              return Array.from(form.querySelectorAll('input:not([type="hidden"]), textarea, [contenteditable], [role="textbox"]')).some(input => {
                if (!visible(input)) return false;
                const type = norm(attr(input, 'type'));
                if (['button', 'submit', 'reset', 'checkbox', 'radio', 'file', 'image', 'password'].includes(type)) return false;
                const key = norm([input.id || '', attr(input, 'name'), attr(input, 'class'), attr(input, 'placeholder'), attr(input, 'aria-label'), type, attr(input, 'role')].join(' '));
                const value = norm(input.value || text(input));
                return value.length > 0 && (/搜索|搜一下|百度一下|search|query|keyword|关键词|查找|请输入|输入|(^|[\\s_-])(q|kw|wd|word|query|search)([\\s_-]|$)/.test(key));
              });
            } catch (_) {
              return false;
            }
          }
          function clickableScore(node) {
            if (!node || !visible(node) || isDisabled(node)) return -100000;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = norm(attr(node, 'type'));
            const role = norm(attr(node, 'role'));
            const label = norm(accessibleText(node));
            const key = norm([
              node.id || '',
              attr(node, 'name'),
              attr(node, 'class'),
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              attr(node, 'formaction'),
              type,
              role,
              label
            ].join(' '));
            if ((tag === 'input' || tag === 'textarea') && !['submit', 'button', 'reset', 'image'].includes(type)) {
              return -10000;
            }
            let score = 0;
            const wanted = norm(desiredLabel);
            if (wanted) {
              if (label === wanted || key === wanted) score += 600;
              else if (label.startsWith(wanted) || key.includes(wanted)) score += 420;
              else if (label.includes(wanted) || wanted.includes(label)) score += 300;
              const tokens = wanted.split(/[\\s,，、]+/).filter(Boolean);
              for (const token of tokens) {
                if (token.length >= 2 && (label.includes(token) || key.includes(token))) score += 45;
              }
            }
            if (tag === 'button') score += 120;
            if (tag === 'input' && ['submit', 'button', 'image'].includes(type)) score += 130;
            if (role === 'button') score += 90;
            if (['menuitem', 'tab', 'option', 'checkbox', 'radio', 'switch'].includes(role)) score += 60;
            if (tag === 'a') score += 35;
            if (/百度一下|搜索|搜一下|查找|提交|确定|确认|继续|下一步|完成|发送|生成|打开|search|submit|go|continue|next|ok|confirm|send|generate/.test(label + ' ' + key)) score += 260;
            const form = node.closest && node.closest('form');
            if (hasValuedSearchEditable(form)) score += 420;
            if (form) {
              const formText = norm([attr(form, 'role'), attr(form, 'action'), attr(form, 'id'), attr(form, 'class'), attr(form, 'name')].join(' '));
              if (/search|query|百度|baidu|搜索|wd=|q=/.test(formText)) score += 120;
            }
            const r = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            if (r) {
              if (r.width >= 36 && r.height >= 24) score += 40;
              if (r.top >= -20 && r.top <= (innerHeight || 800) * 0.9) score += 20;
            }
            return score;
          }
          function bestClickableFallback() {
            const ranked = clickableCandidates()
              .map(node => ({ node, score: clickableScore(node) }))
              .sort((a, b) => b.score - a.score);
            if (!ranked.length) return null;
            if (ranked[0].score >= 180 || (ranked.length === 1 && ranked[0].score >= 40)) return ranked[0].node;
            return null;
          }
          function humanVerificationState() {
            const turnstile = document.querySelector('[name="cf-turnstile-response"], input[id^="cf-chl-widget"], .cf-turnstile, [data-sitekey]');
            const recaptcha = document.querySelector('[name="g-recaptcha-response"], .g-recaptcha, iframe[src*="recaptcha"]');
            const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || frame.getAttribute('aria-label') || '').join(' ');
            const bodyText = norm(document.body && document.body.innerText || '');
            const textDetected = /prove you are human|verify you are human|checking if the site connection is secure|captcha|turnstile|recaptcha|人机验证|验证您是真人|请验证您是真人|正在检查/.test(bodyText);
            const frameDetected = /turnstile|captcha|recaptcha|challenge/.test(frames.toLowerCase());
            const tokenNode = turnstile || recaptcha;
            const tokenLength = tokenNode && 'value' in tokenNode ? String(tokenNode.value || '').length : 0;
            const successState = /成功|success|verified|验证成功|已验证/.test(bodyText);
            const hasChallengeWidget = Boolean(turnstile || recaptcha || frameDetected);
            const pendingText = /checking if the site connection is secure|checking your browser|正在检查/.test(bodyText);
            const completed = Boolean(tokenLength > 0 || successState || (!hasChallengeWidget && !textDetected && !pendingText));
            const detected = !completed && (hasChallengeWidget || textDetected || pendingText);
            const provider = turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (detected ? 'human_verification' : ''));
            return { detected, provider, token_length: tokenLength, completed };
          }
          const explicitNode = deepQuerySelector(selector) || findByLabel(desiredLabel);
          const fallbackNode = explicitNode ? null : bestClickableFallback();
          const node = explicitNode || fallbackNode;
          if (!node) {
            const verification = humanVerificationState();
            return JSON.stringify({
              ok: false,
              error: 'Element not found in current viewport',
              title: document.title || '',
              url: location.href,
              human_verification: verification,
              needs_visual_coordinates: true,
              searched_visible_clickables: true
            });
          }
          try { node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          const target = clickTarget(node);
          const r = target.getBoundingClientRect ? target.getBoundingClientRect() : null;
          const cx = r ? Math.round(r.left + r.width / 2) : 0;
          const cy = r ? Math.round(r.top + r.height / 2) : 0;
          const disabled = isDisabled(target);
          if (disabled) {
            return JSON.stringify({ ok: false, disabled: true, title: document.title || '', url: location.href, text: accessibleText(target).slice(0, 160) });
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
              const event = name.startsWith('pointer') && window.PointerEvent ? new PointerEvent(name, init) : new MouseEvent(name, init);
              target.dispatchEvent(event);
            } catch (_) {}
          }
          if (typeof target.click === 'function') {
            try { target.click(); } catch (_) {}
          }
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            tag: (target.tagName || target.nodeName || '').toLowerCase(),
            text: accessibleText(target).slice(0, 160),
            coordinate_x: cx,
            coordinate_y: cy,
            fallback_click_selected: Boolean(fallbackNode && node === fallbackNode)
          });
        })();
        """
    }

    private static func typeVisibleElementScript(
        selector: String?,
        label: String?,
        text: String,
        clear: Bool,
        pressEnter: Bool
    ) -> String {
        """
        (() => {
          const selector = \(Self.javascriptString(selector ?? ""));
          const desiredLabel = \(Self.javascriptString(label ?? ""));
          const text = \(Self.javascriptString(text));
          const clear = \(clear ? "true" : "false");
          const pressEnter = \(pressEnter ? "true" : "false");
          const editableSelector = 'input:not([type="hidden"]), textarea, select, [contenteditable], [role="textbox"], [aria-label], [placeholder], [name]';
          function norm(value) { return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
          function textOf(node) { return (node && (node.innerText || node.textContent) || '').replace(/\\s+/g, ' ').trim(); }
          function attr(node, name) { return node && node.getAttribute ? (node.getAttribute(name) || '') : ''; }
          function accessibleText(node) {
            if (!node) return '';
            return [
              textOf(node), attr(node, 'aria-label'), attr(node, 'title'), attr(node, 'alt'),
              attr(node, 'name'), attr(node, 'value'), attr(node, 'placeholder'), attr(node, 'data-testid'),
              node.value || '', node.placeholder || ''
            ].filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim();
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
          function deepQuerySelector(raw) {
            if (!raw) return null;
            for (const root of allRoots()) {
              try {
                const match = root.querySelector(raw);
                const editable = editableTarget(match);
                if (editable && visible(editable)) return editable;
              } catch (_) {
                return null;
              }
            }
            return null;
          }
          function findByLabel(raw) {
            const wanted = norm(raw);
            if (!wanted) return null;
            let best = null;
            let bestScore = -1;
            for (const root of allRoots()) {
              let nodes = [];
              try { nodes = Array.from(root.querySelectorAll(editableSelector)); } catch (_) {}
              for (const node of nodes) {
                if (!visible(node)) continue;
                const label = norm(accessibleText(node));
                if (!label) continue;
                let score = -1;
                if (label === wanted) score = 100;
                else if (label.startsWith(wanted)) score = 80;
                else if (label.includes(wanted)) score = 65;
                else if (wanted.includes(label) && label.length >= 2) score = 45;
                if (score > bestScore) {
                  best = node;
                  bestScore = score;
                }
              }
            }
            return best;
          }
          function usableEditable(node) {
            if (!node || !isEditable(node) || !visible(node)) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = norm(attr(node, 'type'));
            if (tag === 'input' && ['button', 'submit', 'reset', 'checkbox', 'radio', 'hidden', 'file', 'image'].includes(type)) return false;
            return !Boolean(node.disabled || attr(node, 'aria-disabled') === 'true' || node.closest && node.closest('[disabled],[aria-disabled="true"]'));
          }
          function editableScore(node) {
            if (!usableEditable(node)) return -100000;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = norm(attr(node, 'type'));
            const role = norm(attr(node, 'role'));
            const label = norm(accessibleText(node));
            const key = norm([
              node.id || '',
              attr(node, 'name'),
              attr(node, 'class'),
              attr(node, 'autocomplete'),
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              type,
              role
            ].join(' '));
            let score = 0;
            if (document.activeElement === node) score += 500;
            if (tag === 'textarea') score += 70;
            if (tag === 'input') score += 50;
            if (node.isContentEditable || role === 'textbox') score += 60;
            if (type === 'search' || role === 'searchbox') score += 260;
            if (/(^|[\\s_-])(q|kw|wd|query|keyword|word|search|s)([\\s_-]|$)/.test(key)) score += 240;
            if (/搜索|搜一下|百度一下|search|query|keyword|关键词|查找|请输入|输入/.test(label + ' ' + key)) score += 220;
            const form = node.closest && node.closest('form');
            if (form) {
              const formText = norm([attr(form, 'role'), attr(form, 'action'), attr(form, 'id'), attr(form, 'class'), attr(form, 'name')].join(' '));
              if (/search|query|百度|baidu|搜索|wd=|q=/.test(formText)) score += 120;
            }
            const desired = norm(desiredLabel);
            const typed = norm(text);
            if (desired && desired !== typed) {
              const nodeLabel = norm(accessibleText(node));
              if (nodeLabel === desired) score += 100;
              else if (nodeLabel.includes(desired) || desired.includes(nodeLabel)) score += 45;
            }
            const r = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            if (r) {
              if (r.width >= 120 && r.height >= 24) score += 80;
              if (r.width >= 220) score += 35;
              if (r.top >= -20 && r.top <= (innerHeight || 800) * 0.8) score += 25;
              score -= Math.max(0, Math.round(r.top / 1200));
            }
            if (!String(node.value || '').trim()) score += 25;
            if (type === 'password') score -= 10000;
            return score;
          }
          function bestEditableFallback() {
            const nodes = [];
            for (const root of allRoots()) {
              try { nodes.push(...Array.from(root.querySelectorAll(editableSelector))); } catch (_) {}
            }
            const ranked = nodes
              .filter(usableEditable)
              .map(node => ({ node, score: editableScore(node) }))
              .sort((a, b) => b.score - a.score);
            if (!ranked.length) return null;
            if (ranked[0].score >= 80 || ranked.length === 1) return ranked[0].node;
            return null;
          }
          function humanVerificationState() {
            const turnstile = document.querySelector('[name="cf-turnstile-response"], input[id^="cf-chl-widget"], .cf-turnstile, [data-sitekey]');
            const recaptcha = document.querySelector('[name="g-recaptcha-response"], .g-recaptcha, iframe[src*="recaptcha"]');
            const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || frame.getAttribute('aria-label') || '').join(' ');
            const bodyText = norm(document.body && document.body.innerText || '');
            const textDetected = /prove you are human|verify you are human|checking if the site connection is secure|captcha|turnstile|recaptcha|人机验证|验证您是真人|请验证您是真人|正在检查/.test(bodyText);
            const frameDetected = /turnstile|captcha|recaptcha|challenge/.test(frames.toLowerCase());
            const successState = /成功|success|verified|验证成功|已验证/.test(bodyText);
            const hasChallengeWidget = Boolean(turnstile || recaptcha || frameDetected);
            const pendingText = /checking if the site connection is secure|checking your browser|正在检查/.test(bodyText);
            const completed = Boolean(successState || (!hasChallengeWidget && !textDetected && !pendingText));
            const detected = !completed && (hasChallengeWidget || textDetected || pendingText);
            const provider = recaptcha ? 'recaptcha' : (turnstile ? 'cloudflare_turnstile' : (detected ? 'human_verification' : ''));
            return { detected, provider, completed };
          }
          const explicitNode = deepQuerySelector(selector) || findByLabel(desiredLabel);
          const fallbackNode = explicitNode ? null : bestEditableFallback();
          const node = explicitNode || fallbackNode;
          if (!node) {
            const verification = humanVerificationState();
            return JSON.stringify({
              ok: false,
              error: 'Element not found in current viewport',
              title: document.title || '',
              url: location.href,
              human_verification: verification,
              needs_visual_coordinates: true,
              searched_visible_editables: true
            });
          }
          try { node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          const disabled = Boolean(node.disabled || attr(node, 'aria-disabled') === 'true' || node.closest('[disabled],[aria-disabled="true"]'));
          if (disabled) {
            return JSON.stringify({ ok: false, disabled: true, title: document.title || '', url: location.href, text: accessibleText(node).slice(0, 160) });
          }
          const tag = (node.tagName || node.nodeName || '').toLowerCase();
          try { node.dispatchEvent(new FocusEvent('focusin', { bubbles: true, composed: true })); } catch (_) {}
          try { node.focus && node.focus(); } catch (_) {}
          if (tag === 'select' && node.options) {
            const wanted = norm(text);
            const options = Array.from(node.options);
            const match = options.find(option => option.value === text)
              || options.find(option => norm(option.textContent) === wanted)
              || options.find(option => norm(option.textContent).includes(wanted));
            node.value = match ? match.value : text;
          } else if (node.isContentEditable || attr(node, 'role') === 'textbox') {
            node.innerText = (clear ? '' : textOf(node)) + text;
          } else if ('value' in node) {
            const nextValue = (clear ? '' : (node.value || '')) + text;
            const descriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(node), 'value')
              || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')
              || Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
            if (descriptor && descriptor.set) descriptor.set.call(node, nextValue);
            else node.value = nextValue;
          }
          try { node.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, composed: true, data: text, inputType: 'insertText' })); }
          catch (_) { try { node.dispatchEvent(new Event('input', { bubbles: true, cancelable: true, composed: true })); } catch (_) {} }
          try { node.dispatchEvent(new Event('change', { bubbles: true, cancelable: true, composed: true })); } catch (_) {}
          if (pressEnter) {
            for (const event of [
              new KeyboardEvent('keydown', { bubbles: true, cancelable: true, composed: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 }),
              new KeyboardEvent('keypress', { bubbles: true, cancelable: true, composed: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 }),
              new KeyboardEvent('keyup', { bubbles: true, cancelable: true, composed: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 })
            ]) {
              try { node.dispatchEvent(event); } catch (_) {}
            }
          }
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            tag,
            text: textOf(node).slice(0, 160),
            value: node.value || '',
            fallback_input_selected: Boolean(fallbackNode && node === fallbackNode)
          });
        })();
        """
    }

    private static func elementCollectionScript(selector: String, limit: Int, intent: String? = nil, filters: [String: Any] = [:]) -> String {
        """
        (() => {
          const selector = \(Self.javascriptString(selector));
          const limit = \(limit);
          const intent = \(Self.javascriptString(intent ?? ""));
          const filters = \(Self.javascriptObject(filters));
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
          function attr(node, name) {
            return node && node.getAttribute ? (node.getAttribute(name) || '') : '';
          }
          function rect(node) {
            if (!node || !node.getBoundingClientRect) return null;
            const r = node.getBoundingClientRect();
            const pageX = r.x + window.scrollX;
            const pageY = r.y + window.scrollY;
            return {
              x: Math.round(r.x),
              y: Math.round(r.y),
              left: Math.round(r.left),
              top: Math.round(r.top),
              right: Math.round(r.right),
              bottom: Math.round(r.bottom),
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
          function clickableState(node) {
            if (!node) return false;
            const tag = norm(node.tagName || node.nodeName || '');
            const role = norm(attr(node, 'role'));
            const type = norm(attr(node, 'type'));
            const className = norm(typeof node.className === 'string' ? node.className : '');
            const id = norm(node.id || '');
            const dataTarget = attr(node, 'data-click') || attr(node, 'data-clickable') || attr(node, 'data-href') || attr(node, 'data-url') || attr(node, 'data-link');
            let cursorPointer = false;
            try {
              const style = getComputedStyle(node);
              cursorPointer = Boolean(style && style.cursor === 'pointer');
            } catch (_) {}
            return tag === 'button'
              || tag === 'a'
              || tag === 'summary'
              || tag === 'label'
              || (tag === 'input' && ['button', 'submit', 'reset', 'image', 'checkbox', 'radio'].includes(type))
              || ['button', 'link', 'menuitem', 'tab', 'option', 'checkbox', 'radio', 'switch'].includes(role)
              || Boolean(dataTarget)
              || Boolean(attr(node, 'onclick') || attr(node, 'jsaction'))
              || (attr(node, 'tabindex') && attr(node, 'tabindex') !== '-1')
              || /(^|[-_\\s])(btn|button|link|tab|nav|menu|item|card|result|select|dropdown)([-_\\s]|$)/.test(className + ' ' + id)
              || cursorPointer;
          }
          function editableState(node) {
            if (!node) return false;
            const tag = norm(node.tagName || node.nodeName || '');
            const role = norm(attr(node, 'role'));
            const type = norm(attr(node, 'type'));
            if (node.isContentEditable || role === 'textbox' || role === 'searchbox') return true;
            if (tag === 'textarea' || tag === 'select') return true;
            if (tag !== 'input') return false;
            return !['button', 'submit', 'reset', 'checkbox', 'radio', 'hidden', 'file', 'image'].includes(type);
          }
          function scrollableState(node) {
            if (!node) return false;
            try {
              const style = getComputedStyle(node);
              return /(auto|scroll)/.test(style.overflow + style.overflowY + style.overflowX)
                && (node.scrollHeight > node.clientHeight + 2 || node.scrollWidth > node.clientWidth + 2);
            } catch (_) {
              return false;
            }
          }
          function longClickableState(node) {
            if (!node) return false;
            return Boolean(attr(node, 'oncontextmenu') || attr(node, 'aria-haspopup') || attr(node, 'contextmenu'));
          }
          function domDepth(node) {
            let depth = 0;
            let current = node;
            while (current && current.parentElement) {
              depth += 1;
              current = current.parentElement;
            }
            return depth;
          }
          function resourceId(node) {
            return node && (
              node.id ||
              attr(node, 'data-testid') ||
              attr(node, 'data-test') ||
              attr(node, 'data-cy') ||
              attr(node, 'name') ||
              ''
            );
          }
          function actionHints(node) {
            const hints = [];
            if (clickableState(node)) hints.push('click');
            if (editableState(node)) hints.push('type');
            if (scrollableState(node)) hints.push('scroll');
            const role = norm(attr(node, 'role'));
            const type = norm(attr(node, 'type'));
            if (['checkbox', 'radio', 'switch'].includes(role) || ['checkbox', 'radio'].includes(type)) hints.push('toggle');
            return hints;
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
            const successState = /成功|success|verified|验证成功|已验证/.test(bodyText);
            const hasChallengeWidget = Boolean(turnstile || recaptcha || frameDetected);
            const pendingText = /checking if the site connection is secure|checking your browser|正在检查/.test(bodyText);
            const completed = Boolean(tokenLength > 0 || successState || (!hasChallengeWidget && !textDetected && !pendingText));
            const detected = !completed && (hasChallengeWidget || textDetected || pendingText);
            const provider = turnstile ? 'cloudflare_turnstile' : (recaptcha ? 'recaptcha' : (detected ? 'human_verification' : ''));
            return {
              detected,
              provider,
              token_length: tokenLength,
              completed,
              success_state: successState
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
              attr(node, 'aria-labelledby'),
              attr(node, 'aria-describedby'),
              attr(node, 'title'),
              attr(node, 'alt'),
              attr(node, 'name'),
              attr(node, 'placeholder'),
              attr(node, 'value'),
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              attr(node, 'jsaction'),
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
          function matchesText(actual, expected, contains) {
            if (expected === undefined || expected === null || String(expected).trim() === '') return true;
            const haystack = norm(actual);
            const needle = norm(expected);
            return contains ? haystack.includes(needle) : haystack === needle;
          }
          function matchesBoolean(actual, expected) {
            if (expected === undefined || expected === null) return true;
            return Boolean(actual) === Boolean(expected);
          }
          function matchesFilters(node, label, nodeHref) {
            const role = attr(node, 'role');
            const desc = [
              attr(node, 'aria-label'),
              attr(node, 'aria-labelledby'),
              attr(node, 'aria-describedby'),
              attr(node, 'title'),
              attr(node, 'alt'),
              attr(node, 'placeholder')
            ].join(' ');
            const idValue = resourceId(node);
            const classValue = typeof node.className === 'string' ? node.className : '';
            const packageValue = location.hostname || 'wkwebview';
            const checked = Boolean(node.checked || attr(node, 'aria-checked') === 'true');
            const selected = Boolean(node.selected || attr(node, 'aria-selected') === 'true');
            const clickable = clickableState(node);
            const editable = editableState(node);
            const scrollable = scrollableState(node);
            const checkable = ['checkbox', 'radio', 'switch'].includes(norm(role)) || ['checkbox', 'radio'].includes(norm(attr(node, 'type')));
            const enabled = !disabledState(node);
            if (!matchesText(label, filters.text, false)) return false;
            if (!matchesText(label, filters.text_contains, true)) return false;
            if (!matchesText(desc, filters.desc, false)) return false;
            if (!matchesText(desc, filters.desc_contains, true)) return false;
            if (!matchesText(idValue, filters.id, false) && !matchesText(idValue, filters.id, true)) return false;
            if (!matchesText(classValue, filters.class, true)) return false;
            if (!matchesText(packageValue, filters.package, true)) return false;
            if (!matchesBoolean(clickable, filters.clickable)) return false;
            if (!matchesBoolean(editable, filters.editable)) return false;
            if (!matchesBoolean(scrollable, filters.scrollable)) return false;
            if (!matchesBoolean(checkable, filters.checkable)) return false;
            if (!matchesBoolean(checked, filters.checked)) return false;
            if (!matchesBoolean(selected, filters.selected)) return false;
            if (!matchesBoolean(enabled, filters.enabled)) return false;
            if (!matchesBoolean(true, filters.visible)) return false;
            return true;
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
          window.__iexaNodeStore = window.__iexaNodeStore || {};
          const expiresAt = Date.now() + 60000;
          for (const key of Object.keys(window.__iexaNodeStore)) {
            const item = window.__iexaNodeStore[key];
            if (!item || item.expiresAt < Date.now()) {
              try { delete window.__iexaNodeStore[key]; } catch (_) {}
            }
          }
          const rawElements = findElements(selector);
          for (const node of findElements('div, span, li, p, section, article, header, footer')) {
            if ((clickableState(node) || editableState(node)) && !rawElements.includes(node)) {
              rawElements.push(node);
            }
          }
          const elements = rawElements
            .filter(visible)
            .filter(node => matchesFilters(node, accessibleText(node), href(node)));
          let items = elements.map((node, sourceIndex) => {
            const nodeId = `dom-${sourceIndex}`;
            window.__iexaNodeStore[nodeId] = { node, expiresAt };
            const label = accessibleText(node);
            const nodeHref = href(node);
            const disabled = disabledState(node);
            const nodeRect = rect(node);
            const clickable = clickableState(node);
            const editable = editableState(node);
            const scrollable = scrollableState(node);
            const role = attr(node, 'role');
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            return {
              index: sourceIndex,
              source_index: sourceIndex,
              node_id: nodeId,
              nodeId,
              tag,
              className: tag,
              title: label.slice(0, 120),
              text: label.slice(0, 240),
              contentDesc: label.slice(0, 240),
              resourceId: resourceId(node),
              packageName: location.hostname || 'wkwebview',
              href: nodeHref,
              id: node.id || '',
              classes: typeof node.className === 'string' ? node.className : '',
              placeholder: node.placeholder || '',
              role,
              aria_label: attr(node, 'aria-label'),
              aria_labelledby: attr(node, 'aria-labelledby'),
              aria_describedby: attr(node, 'aria-describedby'),
              name: attr(node, 'name'),
              title_attr: attr(node, 'title'),
              data_testid: attr(node, 'data-testid'),
              data_test: attr(node, 'data-test'),
              data_cy: attr(node, 'data-cy'),
              jsaction: attr(node, 'jsaction'),
              value: attr(node, 'value') || node.value || '',
              type: attr(node, 'type'),
              disabled,
              enabled: !disabled,
              visible: true,
              clickable,
              longClickable: longClickableState(node),
              editable,
              scrollable,
              checkable: ['checkbox', 'radio', 'switch'].includes(norm(role)) || ['checkbox', 'radio'].includes(norm(attr(node, 'type'))),
              checked: Boolean(node.checked || attr(node, 'aria-checked') === 'true'),
              selected: Boolean(node.selected || attr(node, 'aria-selected') === 'true'),
              focusable: Boolean(attr(node, 'tabindex') || clickable || editable),
              focused: document.activeElement === node,
              depth: domDepth(node),
              childCount: node.childElementCount || 0,
              action_hints: actionHints(node),
              actions: actionHints(node),
              blocked_by_human_verification: disabled && humanVerification.detected && !humanVerification.completed,
              match_score: scoreElement(node, label, nodeHref),
              center: nodeRect ? { x: nodeRect.center_x, y: nodeRect.center_y } : null,
              bounds: nodeRect ? { left: nodeRect.left, top: nodeRect.top, right: nodeRect.right, bottom: nodeRect.bottom } : null,
              rect: nodeRect
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

    private static func generationWorkflowStateScript(expectedPrompt: String?, excludeSources: [String]) -> String {
        let excludedJSON = (try? JSONSerialization.data(withJSONObject: excludeSources))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
          const expectedPrompt = \(Self.javascriptString(expectedPrompt ?? ""));
          const excludedRaw = \(excludedJSON);
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
          function text(node) {
            return ((node && (node.innerText || node.textContent)) || '').replace(/\\s+/g, ' ').trim();
          }
          function attr(node, name) {
            return node && node.getAttribute ? (node.getAttribute(name) || '') : '';
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
          function findElements(selector) {
            const seen = new Set();
            const results = [];
            for (const root of allRoots()) {
              try {
                for (const node of Array.from(root.querySelectorAll(selector))) {
                  if (seen.has(node)) continue;
                  seen.add(node);
                  results.push(node);
                }
              } catch (_) {}
            }
            return results;
          }
          function absoluteURL(value) {
            if (!value) return '';
            const raw = String(value);
            if (raw.startsWith('data:image/')) return raw;
            if (raw.startsWith('blob:')) return raw;
            try { return new URL(raw, location.href).href; } catch (_) { return raw; }
          }
          function sourceKey(value) {
            const raw = absoluteURL(value);
            if (!raw) return '';
            const lower = raw.toLowerCase();
            if (lower.startsWith('data:image/')) return lower.slice(0, 260);
            if (lower.startsWith('blob:')) return lower;
            try {
              const url = new URL(raw, location.href);
              url.hash = '';
              return url.href.replace(/\\/+$/, '').toLowerCase();
            } catch (_) {
              return lower.replace(/#.*$/, '').replace(/\\/+$/, '');
            }
          }
          const excluded = new Set((Array.isArray(excludedRaw) ? excludedRaw : []).map(sourceKey).filter(Boolean));
          function imageLike(value) {
            const lower = String(value || '').toLowerCase();
            return lower.startsWith('data:image/') || lower.startsWith('blob:') || /\\.(png|jpe?g|webp|gif|bmp|avif|heic)(\\?|#|$)/.test(lower);
          }
          function accessibleText(node) {
            if (!node) return '';
            const labelledBy = attr(node, 'aria-labelledby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(id => document.getElementById(id))
              .map(text)
              .join(' ');
            const describedBy = attr(node, 'aria-describedby')
              .split(/\\s+/)
              .filter(Boolean)
              .map(id => document.getElementById(id))
              .map(text)
              .join(' ');
            const id = attr(node, 'id');
            let labels = '';
            if (id && window.CSS && CSS.escape) {
              try {
                labels = Array.from(document.querySelectorAll(`label[for="${CSS.escape(id)}"]`)).map(text).join(' ');
              } catch (_) {}
            }
            return [
              text(node),
              labelledBy,
              describedBy,
              labels,
              attr(node, 'aria-label'),
              attr(node, 'aria-description'),
              attr(node, 'title'),
              attr(node, 'alt'),
              attr(node, 'name'),
              attr(node, 'value'),
              attr(node, 'placeholder'),
              attr(node, 'data-testid'),
              attr(node, 'data-test'),
              attr(node, 'data-cy'),
              attr(node, 'jsaction'),
              node.value || '',
              node.placeholder || ''
            ].filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim();
          }
          function editableValue(node) {
            if (!node) return '';
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            if (tag === 'select' && node.selectedOptions && node.selectedOptions.length) {
              return Array.from(node.selectedOptions).map(option => option.textContent || option.value || '').join(' ');
            }
            if ('value' in node) return String(node.value || '');
            return text(node);
          }
          function disabledState(node) {
            return Boolean(
              node &&
              (node.disabled ||
                attr(node, 'aria-disabled') === 'true' ||
                (node.closest && node.closest('[disabled],[aria-disabled="true"]')))
            );
          }
          function isEditable(node) {
            if (!node) return false;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            return tag === 'textarea' ||
              tag === 'select' ||
              tag === 'input' ||
              node.isContentEditable ||
              attr(node, 'role') === 'textbox';
          }
          function rectPayload(node) {
            const r = node && node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            if (!r) return null;
            return {
              x: Math.round(r.x),
              y: Math.round(r.y),
              width: Math.round(r.width),
              height: Math.round(r.height),
              page_center_x: Math.round(r.left + window.scrollX + r.width / 2),
              page_center_y: Math.round(r.top + window.scrollY + r.height / 2)
            };
          }
          function promptScore(node) {
            if (!isEditable(node)) return -1;
            const tag = (node.tagName || node.nodeName || '').toLowerCase();
            const type = norm(attr(node, 'type'));
            if (tag === 'input' && ['button', 'submit', 'reset', 'checkbox', 'radio', 'hidden', 'file'].includes(type)) return -1;
            let score = 0;
            if (tag === 'textarea') score += 80;
            if (tag === 'input') score += 35;
            if (node.isContentEditable || attr(node, 'role') === 'textbox') score += 55;
            const label = norm(accessibleText(node));
            if (/prompt|describe|description|textarea|message|输入|提示词|描述|关键词|内容/.test(label)) score += 90;
            const value = norm(editableValue(node));
            const expected = norm(expectedPrompt);
            if (expected && value.includes(expected)) score += 1000;
            if (value.length > 0) score += Math.min(80, value.length);
            const r = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            if (r && r.width > 180 && r.height > 36) score += 20;
            if (disabledState(node)) score -= 200;
            return score;
          }
          const editables = findElements('textarea, input:not([type="hidden"]), select, [contenteditable], [role="textbox"]')
            .filter(visible)
            .map(node => ({ node, score: promptScore(node) }))
            .filter(item => item.score >= 0)
            .sort((a, b) => b.score - a.score);
          const promptNode = editables.length ? editables[0].node : null;
          const promptValue = editableValue(promptNode);
          const expectedNorm = norm(expectedPrompt);
          const promptNorm = norm(promptValue);
          const promptVerified = Boolean(expectedNorm && promptNorm && (promptNorm.includes(expectedNorm) || expectedNorm.includes(promptNorm)));
          const actionPattern = /generate|create|submit|start|run|continue|next|send|free image|生成|开始|提交|继续|下一步|立即生成|生成图片|免费生成|发送|确定|查询|搜索/i;
          const clickables = findElements('button, a[href], input[type="submit"], input[type="button"], [role="button"], [role="link"], [role="menuitem"], [role="tab"], [role="option"], [onclick], [tabindex], summary, label')
            .filter(visible)
            .map(node => {
              const label = accessibleText(node);
              let score = actionPattern.test(label) ? 100 : 0;
              const tag = (node.tagName || node.nodeName || '').toLowerCase();
              if (tag === 'button' || attr(node, 'role') === 'button') score += 20;
              if (disabledState(node)) score -= 80;
              return { node, label, score };
            })
            .filter(item => item.score > 0)
            .sort((a, b) => b.score - a.score);
          const generateItem = clickables.length ? clickables[0] : null;
          const generateNode = generateItem && generateItem.node;
          const generateDisabled = disabledState(generateNode);
          const imageSources = [];
          const seenImages = new Set();
          function pushSource(value) {
            const src = absoluteURL(value);
            const key = sourceKey(src);
            if (!key || seenImages.has(key) || !imageLike(src)) return;
            seenImages.add(key);
            imageSources.push(key);
          }
          for (const img of Array.from(document.images || [])) {
            if (!visible(img)) continue;
            pushSource(img.currentSrc || img.src || attr(img, 'data-src') || attr(img, 'data-original') || '');
          }
          for (const a of Array.from(document.querySelectorAll('a[href]'))) {
            const href = a.href || attr(a, 'href');
            if (imageLike(href)) pushSource(href);
          }
          const canvasNodes = Array.from(document.querySelectorAll('canvas')).filter(visible).slice(0, 3);
          for (const canvas of canvasNodes) {
            const r = canvas.getBoundingClientRect();
            if (r.width >= 80 && r.height >= 80) {
              try { pushSource(canvas.toDataURL('image/png')); } catch (_) {}
            }
          }
          const newImageSources = imageSources.filter(src => !excluded.has(src));
          const bodyText = norm(document.body && document.body.innerText || '');
          const busyPattern = /生成中|正在生成|处理中|排队|队列|等待中|请稍候|加载中|正在加载|提交中|上传中|分析中|执行中|运行中|正在运行|loading|generating|processing|queued|queue|in progress|pending|running|submitting|uploading|analyzing|working|please wait/i;
          const visibleFailureNodes = findElements('button, [role="button"], a, div, section, article, p, span')
            .filter(visible)
            .map(node => text(node))
            .filter(value => value.length > 0 && value.length <= 320 && /点击重试|重试|try again|retry|生成失败|失败|failed|failure|error|出错|无法生成|出了点问题|审核未通过|违规/.test(value))
            .slice(0, 4);
          const failureText = visibleFailureNodes.join(' | ').slice(0, 240);
          const retryVisible = visibleFailureNodes.some(value => /点击重试|重试|try again|retry/i.test(value));
          const loadingVisible = Boolean(
            busyPattern.test(bodyText) ||
            findElements('[aria-busy="true"], [role="progressbar"], [role="status"], progress, .loading, .spinner, .progress, [class*="loading"], [class*="spinner"], [class*="progress"], [class*="skeleton"], [data-state="loading"], [data-loading="true"]')
              .some(visible)
          );
          const downloadNodes = findElements('a[href], button, [role="button"], [role="link"], [download]')
            .filter(visible)
            .filter(node => {
              const label = norm(accessibleText(node) + ' ' + attr(node, 'href') + ' ' + attr(node, 'download'));
              return /download|export|save|result|output|view|open|下载|导出|保存|结果|输出|查看|打开/.test(label);
            })
            .slice(0, 8);
          const resultContainers = findElements([
            '[aria-live]',
            '[role="status"]',
            '[role="log"]',
            '[data-testid*="result"]',
            '[data-testid*="output"]',
            '[data-testid*="answer"]',
            '[class*="result"]',
            '[class*="output"]',
            '[class*="answer"]',
            '[class*="response"]',
            '[class*="preview"]',
            'main article',
            'main section',
            'article',
            'section'
          ].join(','))
            .filter(visible)
            .map(node => text(node))
            .filter(value => value.length >= 80 && !busyPattern.test(value))
            .slice(0, 5);
          const asyncResultDetected = Boolean(downloadNodes.length > 0 || resultContainers.length > 0);
          const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || attr(frame, 'aria-label') || '').join(' ').toLowerCase();
          const challengeDetected = /turnstile|captcha|recaptcha|challenge/.test(frames) ||
            /prove you are human|verify you are human|checking if the site connection is secure|checking your browser|cf-challenge|captcha|turnstile|验证您是真人|请验证您是真人|正在检查|人机验证/.test(bodyText);
          const promptReady = Boolean(promptNode && !disabledState(promptNode));
          const challengePendingText = /checking if the site connection is secure|checking your browser|正在检查/.test(bodyText);
          const challengeBlocking = challengeDetected && newImageSources.length === 0 && !loadingVisible && !promptReady && !(generateNode && !generateDisabled) && challengePendingText;
          let generationState = 'unknown';
          if (challengeBlocking) generationState = 'blocked_verification';
          else if (newImageSources.length > 0 && excluded.size > 0) generationState = 'success';
          else if (asyncResultDetected && !loadingVisible) generationState = 'success';
          else if (loadingVisible || (promptVerified && generateNode && generateDisabled)) generationState = 'generating';
          else if (retryVisible) generationState = 'retry';
          else if (failureText) generationState = 'failed';
          else if (promptVerified && generateNode && !generateDisabled) generationState = 'ready';
          else if (promptNode) generationState = 'idle';
          return JSON.stringify({
            action: 'browser.workflow_state',
            ok: true,
            title: document.title || '',
            url: location.href,
            prompt_field_found: Boolean(promptNode),
            prompt_value: promptValue,
            prompt_value_verified: promptVerified,
            prompt_rect: rectPayload(promptNode),
            generate_button_found: Boolean(generateNode),
            generate_button_enabled: Boolean(generateNode && !generateDisabled),
            generate_button_text: generateItem ? generateItem.label.slice(0, 160) : '',
            generate_button_rect: rectPayload(generateNode),
            generation_state: generationState,
            retry_visible: retryVisible,
            failure_text: failureText,
            loading_visible: loadingVisible,
            async_result_detected: asyncResultDetected,
            download_link_count: downloadNodes.length,
            result_container_count: resultContainers.length,
            result_text_preview: resultContainers.join(' | ').slice(0, 360),
            image_sources: imageSources.slice(0, 16),
            candidate_count: imageSources.length,
            new_candidate_count: newImageSources.length,
            new_image_sources: newImageSources.slice(0, 8),
            requires_user_verification: challengeBlocking,
            summary: generationState === 'ready'
              ? '页面已准备好生成。'
              : generationState === 'generating'
                ? '页面正在生成或等待结果。'
                : generationState === 'success'
                  ? '页面出现了新的结果图片。'
                  : generationState === 'failed' || generationState === 'retry'
                    ? (failureText || '页面显示生成失败/重试状态。')
                    : generationState === 'blocked_verification'
                      ? '页面需要人机验证。'
                      : '已读取当前网页流程状态。'
          });
        })();
        """
    }

    private static func searchResultStateScript(expectedText: String?) -> String {
        """
        (() => {
          const expected = \(Self.javascriptString(expectedText ?? ""));
          const bodyText = ((document.body && document.body.innerText) || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          const href = location.href.toLowerCase();
          const title = (document.title || '').toLowerCase();
          const expectedNorm = String(expected || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 120);
          const resultLinks = links.filter(a => {
            const text = ((a.innerText || a.textContent || '') + ' ' + (a.href || '')).replace(/\\s+/g, ' ').trim().toLowerCase();
            if (!text) return false;
            if (/意见反馈|用户反馈|登录|注册|隐私|服务协议|设置|图片|视频|地图|贴吧/.test(text)) return false;
            return a.href && /^https?:/i.test(a.href) && text.length >= 4;
          });
          const searchURL = /[?&](q|wd|word|query|keyword)=/.test(href) ||
            /\\/s\\?|\\/search\\?|\\/web\\?|\\/html\\?/.test(href);
          const searchText = /搜索结果|百度为您找到|相关搜索|全部结果|网页结果|search results|results for/.test(bodyText + ' ' + title);
          const encodedExpected = expectedNorm ? encodeURIComponent(expectedNorm).toLowerCase() : '';
          const expectedVisible = expectedNorm.length === 0 || bodyText.includes(expectedNorm) || title.includes(expectedNorm) || (encodedExpected && href.includes(encodedExpected));
          return JSON.stringify({
            ok: true,
            title: document.title || '',
            url: location.href,
            looks_like_search_result: Boolean(expectedVisible && (searchURL || searchText || resultLinks.length >= 3)),
            result_link_count: resultLinks.length,
            expected_visible: expectedVisible
          });
        })();
        """
    }

    private static func generatedImageCandidateScript(minWidth: Int, minHeight: Int, query: String?, excludeSources: [String]) -> String {
        let queryWords = (query ?? "")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
            .map(String.init)
            .filter { !$0.isEmpty }
        let queryJSON = (try? JSONSerialization.data(withJSONObject: queryWords))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let excludedJSON = (try? JSONSerialization.data(withJSONObject: excludeSources))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
          const minWidth = \(minWidth);
          const minHeight = \(minHeight);
          const queryWords = \(queryJSON);
          const excludedRaw = \(excludedJSON);
          const seen = new Set();
          function sourceKey(value) {
            const raw = absoluteURL(value);
            if (!raw) return '';
            const lower = raw.toLowerCase();
            if (lower.startsWith('data:image/')) return lower.slice(0, 260);
            if (lower.startsWith('blob:')) return lower;
            try {
              const url = new URL(raw, location.href);
              url.hash = '';
              return url.href.replace(/\\/+$/, '').toLowerCase();
            } catch (_) {
              return lower.replace(/#.*$/, '').replace(/\\/+$/, '');
            }
          }
          const excluded = new Set((Array.isArray(excludedRaw) ? excludedRaw : []).map(sourceKey).filter(Boolean));
          function norm(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          }
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
          function failureState() {
            const bodyText = norm(document.body && document.body.innerText || '');
            const busyPattern = /生成中|正在生成|处理中|排队|队列|等待中|请稍候|加载中|正在加载|提交中|上传中|分析中|执行中|运行中|正在运行|loading|generating|processing|queued|queue|in progress|pending|running|submitting|uploading|analyzing|working|please wait/i;
            const frames = Array.from(document.querySelectorAll('iframe')).map(frame => frame.src || frame.title || frame.getAttribute('aria-label') || '').join(' ').toLowerCase();
            const challengeDetected = /turnstile|captcha|recaptcha|challenge/.test(frames) ||
              /prove you are human|verify you are human|checking if the site connection is secure|checking your browser|cf-challenge|captcha|turnstile|验证您是真人|请验证您是真人|正在检查|人机验证/.test(bodyText);
            const failureNodes = Array.from(document.querySelectorAll('button, [role="button"], a, div, section, article, p, span'))
              .filter(visible)
              .map(node => text(node))
              .filter(value => value.length > 0 && value.length <= 320 && /点击重试|重试|try again|retry|生成失败|失败|failed|failure|error|出错|无法生成|出了点问题|审核未通过|违规/.test(value))
              .slice(0, 4);
            const failureText = failureNodes.join(' | ').slice(0, 240);
            const retryVisible = failureNodes.some(value => /点击重试|重试|try again|retry/i.test(value));
            const loadingVisible = busyPattern.test(bodyText) ||
              Array.from(document.querySelectorAll('[aria-busy="true"], [role="progressbar"], [role="status"], progress, .loading, .spinner, .progress, [class*="loading"], [class*="spinner"], [class*="progress"], [class*="skeleton"], [data-state="loading"], [data-loading="true"]')).some(visible);
            return {
              challengeDetected,
              retryVisible,
              failureText,
              loadingVisible
            };
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
            const key = sourceKey(src);
            if (!src || !key || !imageLike(src) || seen.has(key) || excluded.has(key)) return;
            seen.add(key);
            const item = {
              src,
              source_key: key,
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
          const failure = failureState();
          let generationState = 'unknown';
          if (items.length > 0) generationState = 'success';
          else if (failure.loadingVisible) generationState = 'generating';
          else if (failure.challengeDetected) generationState = 'blocked_verification';
          else if (failure.retryVisible) generationState = 'retry';
          else if (failure.failureText) generationState = 'failed';
          return JSON.stringify({
            ok: items.length > 0,
            title: document.title || '',
            url: location.href,
            generation_state: generationState,
            retry_visible: failure.retryVisible,
            failure_text: failure.failureText,
            excluded_source_count: excluded.size,
            candidate_count: items.length,
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
        wv.uiDelegate = self
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
            tab.uiDelegate = self
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

    func recordAutomationBrowserUserInteraction(kind: String) {
        browserLastUserInteractionAt = Date()
        browserLastUserInteractionKind = kind
        scheduleLiveBrowserPreview(reason: "user_\(kind)", minimumInterval: 0.25)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self,
                  let probe = await self.evaluateJSONObject(Self.visibleChallengeProbeScript()) else {
                return
            }
            var enrichedProbe = probe
            enrichedProbe["user_interaction_kind"] = kind
            enrichedProbe["user_interaction_at"] = ISO8601DateFormatter().string(from: self.browserLastUserInteractionAt)
            self.notifyHumanVerificationState(enrichedProbe)
        }
    }

    func browserWebViewDidFinishNavigation(_ source: WKWebView) {
        guard isKnownBrowserWebView(source) else { return }
        resolveNavigation(true)
        notifyActiveBrowserDidChange()
        notifyHumanVerificationStateIfNeeded(from: source)
        scheduleLiveBrowserPreview(reason: "navigation_finished", minimumInterval: 0.25)
    }

    func browserWebViewDidFailNavigation(_ source: WKWebView) {
        guard isKnownBrowserWebView(source) else { return }
        resolveNavigation(false)
        notifyActiveBrowserDidChange()
        notifyHumanVerificationStateIfNeeded(from: source)
        scheduleLiveBrowserPreview(reason: "navigation_failed", minimumInterval: 0.25)
    }

    func currentAutomationBrowserURL() -> URL {
        webView?.url ?? URL(string: "about:blank")!
    }

    func waitForVisibleHumanVerificationCompletion(
        timeout: TimeInterval = 300,
        onUserInteraction: ((String) -> Void)? = nil
    ) async -> Bool {
        var sawChallenge = true
        var completedSamples = 0
        var clearSamples = 0
        var lastScrollAt = Date.distantPast
        var lastSeenUserInteractionAt = browserLastUserInteractionAt
        _ = await scrollToVisibleHumanVerification()
        lastScrollAt = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            scheduleLiveBrowserPreview(reason: "verification_poll", minimumInterval: 1.2)
            if let probe = await evaluateJSONObject(Self.visibleChallengeProbeScript()) {
                let detected = Self.boolValue(probe["detected"]) == true
                let completed = Self.boolValue(probe["completed"]) == true
                let failed = Self.boolValue(probe["failed_state"]) == true
                let pending = Self.boolValue(probe["pending_state"]) == true
                let pageUsable = Self.boolValue(probe["page_usable"]) == true
                let challengeVisible = Self.boolValue(probe["challenge_visible"]) == true
                let effectivelyCompleted = completed || (sawChallenge && pageUsable && !challengeVisible && !pending && !failed)
                if detected {
                    sawChallenge = true
                    clearSamples = 0
                    if !effectivelyCompleted && Date().timeIntervalSince(lastScrollAt) >= 4 {
                        _ = await scrollToVisibleHumanVerification()
                        lastScrollAt = Date()
                    }
                }

                if sawChallenge && effectivelyCompleted && !failed {
                    completedSamples += 1
                } else {
                    completedSamples = 0
                }
                if completedSamples >= 2 {
                    var completedProbe = probe
                    completedProbe["completed"] = true
                    completedProbe["detected"] = false
                    notifyHumanVerificationState(completedProbe)
                    scheduleLiveBrowserPreview(reason: "verification_completed", minimumInterval: 0.2)
                    return true
                }

                if sawChallenge && !detected {
                    clearSamples += 1
                } else if detected {
                    clearSamples = 0
                }
                if clearSamples >= 2 {
                    var completedProbe = probe
                    completedProbe["detected"] = false
                    completedProbe["completed"] = true
                    notifyHumanVerificationState(completedProbe)
                    scheduleLiveBrowserPreview(reason: "verification_completed", minimumInterval: 0.2)
                    return true
                }

                notifyHumanVerificationState(probe)
            }
            let sawNewUserInteraction = browserLastUserInteractionAt > lastSeenUserInteractionAt
            if sawNewUserInteraction {
                lastSeenUserInteractionAt = browserLastUserInteractionAt
                onUserInteraction?(browserLastUserInteractionKind)
                try? await Task.sleep(nanoseconds: 240_000_000)
            } else {
                await waitForAutomationBrowserUserInteractionOrDelay(nanoseconds: 900_000_000)
            }
        }
        return false
    }

    private func waitForAutomationBrowserUserInteractionOrDelay(nanoseconds: UInt64) async {
        let startedAt = browserLastUserInteractionAt
        let slice: UInt64 = 300_000_000
        var elapsed: UInt64 = 0
        while elapsed < nanoseconds {
            try? await Task.sleep(nanoseconds: min(slice, nanoseconds - elapsed))
            if browserLastUserInteractionAt > startedAt {
                return
            }
            elapsed += slice
        }
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

    private func scheduleLiveBrowserPreview(reason: String, minimumInterval: TimeInterval = 1.0) {
        guard webView != nil else { return }
        guard browserLivePreviewTask == nil else { return }
        let delay = max(0, minimumInterval - Date().timeIntervalSince(browserLivePreviewLastPublishedAt))
        browserLivePreviewTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self else { return }
            await self.publishLiveBrowserPreview(reason: reason)
            self.browserLivePreviewTask = nil
        }
    }

    private func publishLiveBrowserPreview(reason: String) async {
        guard let wv = webView else { return }
        let visibleInAutomationBrowser = isAutomationBrowserVisible(wv)
        let width = visibleInAutomationBrowser ? max(wv.bounds.width, 1) : browserViewportSize.width
        let height = visibleInAutomationBrowser ? max(wv.bounds.height, 1) : browserViewportSize.height
        wv.isHidden = false
        wv.alpha = 1
        if !visibleInAutomationBrowser {
            wv.frame = CGRect(x: -10_000, y: -10_000, width: width, height: height)
        }
        wv.setNeedsLayout()
        wv.layoutIfNeeded()
        wv.scrollView.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 80_000_000)

        guard let image = await captureVisibleWebViewImage(width: width, height: height),
              let data = Self.liveBrowserPreviewImageData(from: image) else {
            return
        }

        do {
            let folder = try browserOutputDirectory()
            let revision = browserLivePreviewRevision + 1
            let fileURL = folder.appendingPathComponent("browser_live_\(activeBrowserTabID)_\(revision).jpg")
            try data.write(to: fileURL, options: [.atomic])
            if let previous = browserLivePreviewFileURL, previous != fileURL {
                try? FileManager.default.removeItem(at: previous)
            }
            browserLivePreviewRevision = revision
            browserLivePreviewLastPublishedAt = Date()
            browserLivePreviewFileURL = fileURL
            NotificationCenter.default.post(
                name: .browserWebSearchServiceLivePreviewDidChange,
                object: wv,
                userInfo: [
                    "thumbnail_url": fileURL.absoluteString,
                    "thumbnail_path": fileURL.path,
                    "revision": revision,
                    "reason": reason,
                    "tab_id": activeBrowserTabID,
                    "url": wv.url?.absoluteString ?? "",
                    "title": wv.title ?? ""
                ]
            )
        } catch {
            logger.debug("Browser live preview write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func liveBrowserPreviewImageData(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 520
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longestSide, 1))
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.58)
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
              let data = Self.lightweightBrowserViewportImageData(from: image) else {
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
            let fileURL = folder.appendingPathComponent("\(prefix)_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            logger.debug("Browser viewport snapshot write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func lightweightBrowserViewportImageData(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 900
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longestSide, 1))
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.66)
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
        let root = base.appendingPathComponent("iexa-browser-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Self.pruneTemporaryBrowserOutputFiles(in: root)
        let folder = root
            .appendingPathComponent(Self.dateFolderName(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private nonisolated static func pruneTemporaryBrowserOutputFiles(in root: URL) throws {
        let fileManager = FileManager.default
        let tempPrefixes = [
            "browser_live_",
            "browser_viewport_",
            "browser_observe_",
            "browser_scan_",
            "browser_click_miss_",
            "browser_click_after_",
            "browser_type_after_",
            "browser_scroll_after_",
            "browser_open_after_",
            "browser_readable_after_",
            "browser_dom_stable_after_",
            "browser_dom_stable_timeout_",
            "browser_find_focus_",
            "browser_full_",
            "browser_image_timeout_",
            "search_"
        ]
        let maxTemporaryFiles = 80
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var directories: [URL] = []
        var temporaryFiles: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                directories.append(url)
                continue
            }
            guard tempPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) else {
                continue
            }
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate else {
                continue
            }
            temporaryFiles.append((url, modified))
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
        let retained = temporaryFiles
            .filter { $0.modified >= cutoff }
            .sorted { $0.modified > $1.modified }
        if retained.count > maxTemporaryFiles {
            for item in retained.dropFirst(maxTemporaryFiles) {
                try? fileManager.removeItem(at: item.url)
            }
        }
        for directory in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            guard (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
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

    private static func humanVerificationRequiresUser(_ verification: [String: Any]) -> Bool {
        let detected = boolValue(verification["detected"]) == true
        let completed = boolValue(verification["completed"]) == true
        guard detected && !completed else { return false }

        if boolValue(verification["blocking"] ?? verification["challenge_blocking"]) == true {
            return true
        }

        let hasDetailedProbe = verification.keys.contains("page_usable")
            || verification.keys.contains("challenge_visible")
            || verification.keys.contains("pending_state")
            || verification.keys.contains("failed_state")
        guard hasDetailedProbe else {
            return false
        }

        let failed = boolValue(verification["failed_state"]) == true
        let pending = boolValue(verification["pending_state"]) == true
        let pageUsable = boolValue(verification["page_usable"]) == true
        let challengeVisible = boolValue(verification["challenge_visible"]) == true
        return !(pageUsable && !challengeVisible && !pending && !failed)
    }

    private static func toolPayloadRequiresHumanVerification(_ payload: [String: Any]) -> Bool {
        guard boolValue(payload["requires_user_verification"]) == true else { return false }
        if let verification = payload["human_verification"] as? [String: Any] {
            if boolValue(payload["disabled"]) == true,
               boolValue(verification["detected"]) == true,
               boolValue(verification["completed"]) != true {
                return true
            }
            return humanVerificationRequiresUser(verification)
        }
        return true
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
            tab.uiDelegate = self
            attachToWindow(tab)
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.navigationDelegate = automationBrowserNavigationDelegate ?? self
        webView.uiDelegate = automationBrowserUIDelegate ?? self
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

    private func currentBlockingHumanVerification() async -> [String: Any]? {
        guard var probe = await evaluateJSONObject(Self.visibleChallengeProbeScript()) else {
            return nil
        }
        let detected = Self.boolValue(probe["detected"]) == true
        let completed = Self.boolValue(probe["completed"]) == true
        let failed = Self.boolValue(probe["failed_state"]) == true
        let pending = Self.boolValue(probe["pending_state"]) == true
        let pageUsable = Self.boolValue(probe["page_usable"]) == true
        let challengeVisible = Self.boolValue(probe["challenge_visible"]) == true
        guard detected && !completed && !(pageUsable && !challengeVisible && !pending && !failed) else { return nil }
        _ = await scrollToVisibleHumanVerification()
        scheduleLiveBrowserPreview(reason: "verification_required", minimumInterval: 0.2)
        probe["requires_user_verification"] = true
        return probe
    }

    private func browserHumanVerificationPayload(
        action: String,
        verification: [String: Any],
        summary: String
    ) async -> [String: Any] {
        [
            "action": action,
            "ok": false,
            "title": await currentPageTitle() ?? webView?.title ?? "",
            "url": await currentPageURL()?.absoluteString ?? webView?.url?.absoluteString ?? "",
            "requires_user_verification": true,
            "human_verification": verification,
            "summary": summary
        ]
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
        let failed = Self.boolValue(probe["failed_state"]) == true
        let pending = Self.boolValue(probe["pending_state"]) == true
        let pageUsable = Self.boolValue(probe["page_usable"]) == true
        let challengeVisible = Self.boolValue(probe["challenge_visible"]) == true
        let completed = explicitCompleted || (pageUsable && !challengeVisible && !pending && !failed)
        if let tabID = browserTabID(for: webView) {
            if detected {
                browserHumanVerificationSeenTabs.insert(tabID)
            }
            if detected && !completed {
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
                "failed_state": failed,
                "pending_state": pending,
                "page_usable": pageUsable,
                "challenge_visible": challengeVisible,
                "user_interaction_kind": probe["user_interaction_kind"] as? String ?? "",
                "user_interaction_at": probe["user_interaction_at"] as? String ?? "",
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
            '[class*="turnstile"]',
            '[class*="captcha"]',
            '[id*="turnstile"]',
            '[id*="captcha"]',
            '[id*="challenge"]',
            'iframe[src*="turnstile"]',
            'iframe[src*="recaptcha"]',
            'iframe[src*="challenge"]',
            'iframe[title*="challenge"]',
            'iframe[title*="captcha"]',
            'iframe[title*="verification"]',
            'iframe[title*="cloudflare"]'
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
          try { window.scrollTo({ top: nextY, left: Math.max(0, pageX - viewportW / 2), behavior: 'instant' }); }
          catch (_) { window.scrollTo(Math.max(0, pageX - viewportW / 2), nextY); }
          try { target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
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
          function visible(node) {
            if (!node || !node.getBoundingClientRect) return false;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) === 0) return false;
            const r = node.getBoundingClientRect();
            return r.width > 12 && r.height > 12 && r.bottom >= 0 && r.right >= 0 && r.top <= innerHeight * 1.25 && r.left <= innerWidth;
          }
          function challengeElementVisible() {
            const selectors = [
              '[name="cf-turnstile-response"]',
              'input[id^="cf-chl-widget"]',
              '.cf-turnstile',
              '[data-sitekey]',
              '[name="g-recaptcha-response"]',
              '.g-recaptcha',
              'iframe[src*="turnstile"]',
              'iframe[src*="recaptcha"]',
              'iframe[src*="challenge"]',
              '[class*="turnstile"]',
              '[class*="captcha"]',
              '[id*="turnstile"]',
              '[id*="captcha"]',
              '[id*="challenge"]'
            ];
            return selectors.some(selector => {
              try { return Array.from(document.querySelectorAll(selector)).some(visible); }
              catch (_) { return false; }
            });
          }
          function pageUsableEvidence() {
            const selector = 'button, a[href], input:not([type="hidden"]), textarea, select, [contenteditable], [role="button"], [role="link"], [role="textbox"], [onclick], [tabindex]';
            const challengePattern = /turnstile|captcha|recaptcha|challenge|cf-chl|cloudflare|验证|人机|verify you are human|prove you are human/i;
            let controlCount = 0;
            try {
              for (const node of Array.from(document.querySelectorAll(selector)).slice(0, 240)) {
                if (!visible(node)) continue;
                const disabled = Boolean(node.disabled || node.getAttribute && node.getAttribute('aria-disabled') === 'true' || node.closest && node.closest('[disabled],[aria-disabled="true"]'));
                if (disabled) continue;
                const signature = [
                  node.id || '',
                  node.name || '',
                  node.className || '',
                  node.getAttribute && node.getAttribute('aria-label') || '',
                  node.getAttribute && node.getAttribute('title') || '',
                  node.getAttribute && node.getAttribute('placeholder') || '',
                  node.innerText || '',
                  node.textContent || ''
                ].join(' ');
                if (!challengePattern.test(signature)) {
                  controlCount += 1;
                }
              }
            } catch (_) {
              controlCount = 0;
            }
            const titleText = String(document.title || '');
            const nonChallengeTitle = titleText.length > 0 && !challengePattern.test(titleText);
            const strippedBodyText = bodyText
              .replace(/prove you are human|verify you are human|checking if the site connection is secure|checking your browser|cf-challenge|captcha|turnstile|故障排除|验证失败|验证您是真人|请验证您是真人|正在检查|troubleshooting|verification failed/g, ' ')
              .replace(/\\s+/g, ' ')
              .trim();
            const usefulText = nonChallengeTitle && strippedBodyText.length >= 320;
            return {
              usable: controlCount > 0 || usefulText,
              control_count: controlCount,
              content_text_length: strippedBodyText.length
            };
          }
          const hasChallengeWidget = Boolean(
            turnstile ||
            recaptcha ||
            /turnstile|captcha|recaptcha|challenge/.test(frames)
          );
          const textChallenge = /prove you are human|verify you are human|checking if the site connection is secure|checking your browser|cf-challenge|captcha|turnstile|故障排除|验证失败|验证您是真人|请验证您是真人|正在检查|troubleshooting|verification failed/.test(bodyText);
          const failedState = /故障排除|验证失败|troubleshooting|verification failed/.test(bodyText);
          const successState = /verified|验证成功|已验证/.test(bodyText)
            || (/成功|success/.test(bodyText) && /cloudflare|captcha|turnstile|验证/.test(bodyText));
          const pendingText = /checking if the site connection is secure|checking your browser|正在检查/.test(bodyText);
          const challengeVisible = challengeElementVisible();
          const usableEvidence = pageUsableEvidence();
          const pageUsable = Boolean(usableEvidence.usable);
          const textOnlyChallenge = textChallenge && !challengeVisible && !hasChallengeWidget && !pendingText && !failedState;
          const completedState = tokenLength > 0 || successState || (!challengeVisible && !pendingText && !failedState && (!textChallenge || pageUsable));
          const challengeDetected = !completedState && (hasChallengeWidget || challengeVisible || pendingText || failedState || (textOnlyChallenge && !pageUsable));
          const blocking = challengeDetected && !(pageUsable && !challengeVisible && !pendingText && !failedState);
          return JSON.stringify({
            detected: challengeDetected,
            completed: completedState,
            blocking,
            failed_state: failedState && !completedState,
            pending_state: pendingText && !completedState,
            success_state: successState,
            challenge_visible: challengeVisible,
            page_usable: pageUsable,
            page_usable_control_count: usableEvidence.control_count,
            page_usable_text_length: usableEvidence.content_text_length,
            text_only_challenge: textOnlyChallenge,
            token_length: tokenLength
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
                "title": webView?.title ?? "",
                "tabs": browserTabSnapshots()
            ]
        )
        NotificationCenter.default.post(
            name: .browserWebSearchServiceTabsDidChange,
            object: webView,
            userInfo: [
                "active_tab_id": activeBrowserTabID,
                "tabs": browserTabSnapshots()
            ]
        )
        scheduleLiveBrowserPreview(reason: "active_browser_changed", minimumInterval: 0.45)
    }

    private func browserTabSnapshots() -> [BrowserWebSearchTabSnapshot] {
        browserTabs
            .sorted { $0.key < $1.key }
            .map { tabID, tab in
                let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let host = tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
                return BrowserWebSearchTabSnapshot(
                    id: tabID,
                    title: title?.isEmpty == false ? title! : (host.isEmpty ? "新标签页" : host),
                    url: tab.url?.absoluteString ?? "",
                    isActive: tabID == activeBrowserTabID
                )
            }
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
        (await evaluateJavaScriptString(script)).string
    }

    private func evaluateAsyncJavaScriptString(_ script: String, fallbackScript: String) async -> JavaScriptEvaluation {
        guard let webView else {
            return JavaScriptEvaluation(
                string: nil,
                error: "Browser web view is not available",
                resultType: nil,
                resultPreview: nil
            )
        }
        if #available(iOS 14.0, *) {
            do {
                let value = try await webView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
                if let string = value as? String {
                    return JavaScriptEvaluation(
                        string: string,
                        error: nil,
                        resultType: "string",
                        resultPreview: nil
                    )
                }
                return JavaScriptEvaluation(
                    string: nil,
                    error: nil,
                    resultType: String(describing: type(of: value)),
                    resultPreview: String(String(describing: value).prefix(500))
                )
            } catch {
                self.logger.debug("Browser async JS failed: \(error.localizedDescription, privacy: .public)")
                return JavaScriptEvaluation(
                    string: nil,
                    error: error.localizedDescription,
                    resultType: nil,
                    resultPreview: nil
                )
            }
        }
        return await evaluateJavaScriptString(fallbackScript)
    }

    private func evaluateJavaScriptString(_ script: String) async -> JavaScriptEvaluation {
        guard let webView else {
            return JavaScriptEvaluation(
                string: nil,
                error: "Browser web view is not available",
                resultType: nil,
                resultPreview: nil
            )
        }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    self.logger.debug("Browser search JS failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: JavaScriptEvaluation(
                        string: nil,
                        error: error.localizedDescription,
                        resultType: nil,
                        resultPreview: nil
                    ))
                    return
                }
                if let string = result as? String {
                    continuation.resume(returning: JavaScriptEvaluation(
                        string: string,
                        error: nil,
                        resultType: "string",
                        resultPreview: nil
                    ))
                    return
                }
                continuation.resume(returning: JavaScriptEvaluation(
                    string: nil,
                    error: nil,
                    resultType: result.map { String(describing: type(of: $0)) },
                    resultPreview: result.map { String(String(describing: $0).prefix(500)) }
                ))
            }
        }
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deviceDateAwareQueries(_ queries: [String]) -> [String] {
        let normalized = unique(queries.map(normalizedQuery))
        guard !normalized.isEmpty else { return [] }

        let source = normalized.joined(separator: " ")
        let now = Date()
        let currentYear = Calendar.current.component(.year, from: now)
        let isoDateText = isoSearchDateText(now)
        let dateText = localizedSearchDateText(now)
        let englishDateText = englishSearchDateText(now)
        let hasExplicitRecentYear = source.range(
            of: #"\b20(2[4-9]|3[0-9])\b"#,
            options: .regularExpression
        ) != nil
        let forceDayScope = searchNeedsDayScope(source)
        let forceFreshness = searchNeedsFreshness(source)

        var expanded: [String] = []
        for query in normalized {
            let hasCJK = query.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
            expanded.append(query)
            if forceDayScope {
                expanded.append(hasCJK ? "\(query) \(isoDateText) 今天 24小时" : "\(query) \(isoDateText) today past 24 hours")
                expanded.append(hasCJK ? "\(query) \(dateText) 最新" : "\(query) \(englishDateText) latest")
            } else if forceFreshness {
                expanded.append(hasCJK ? "\(query) 最新 \(dateText)" : "\(query) latest \(englishDateText)")
                expanded.append(hasCJK ? "\(query) 官方 更新 \(isoDateText)" : "\(query) official updated \(isoDateText)")
            } else if !hasExplicitRecentYear {
                expanded.append("\(query) \(currentYear)")
            }
        }
        return unique(expanded)
    }

    private static func freshnessExpandedQueries(
        _ queries: [String],
        originalQuery: String?
    ) -> [String] {
        let source = ([originalQuery].compactMap { $0 } + queries)
            .joined(separator: " ")
        guard searchNeedsFreshness(source) else {
            return deviceDateAwareQueries(queries)
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

extension BrowserWebSearchService: WKNavigationDelegate, WKUIDelegate {
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

    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let requestedURL = navigationAction.request.url
        let opensInNewWindow = navigationAction.targetFrame == nil
            || navigationAction.targetFrame?.isMainFrame == false
        Task { @MainActor [weak self, weak webView] in
            guard let self else { return }
            guard let source = webView,
                  self.isKnownBrowserWebView(source),
                  let url = requestedURL else {
                return
            }
            if opensInNewWindow, self.browserTabs.count < 3 {
                let tabID = self.nextBrowserTabID
                self.nextBrowserTabID += 1
                let tab = self.makeBrowserWebView()
                self.browserTabs[tabID] = tab
                self.activeBrowserTabID = tabID
                self.webView = tab
                self.mountActiveBrowserIfPresented()
                tab.load(URLRequest(url: url))
                self.notifyActiveBrowserDidChange()
                self.scheduleLiveBrowserPreview(reason: "popup_new_tab", minimumInterval: 0.25)
            } else {
                source.load(URLRequest(url: url))
                self.scheduleLiveBrowserPreview(reason: "popup_same_tab", minimumInterval: 0.25)
            }
        }
        return nil
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
    static let browserWebSearchServiceTabsDidChange =
        Notification.Name("BrowserWebSearchServiceTabsDidChange")
    static let browserWebSearchServiceHumanVerificationStateDidChange =
        Notification.Name("BrowserWebSearchServiceHumanVerificationStateDidChange")
    static let browserWebSearchServiceLivePreviewDidChange =
        Notification.Name("BrowserWebSearchServiceLivePreviewDidChange")
}
