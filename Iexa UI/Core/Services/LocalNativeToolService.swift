import Foundation
import UIKit
import UserNotifications

struct LocalNativeToolRunResult: Sendable {
    let didExecute: Bool
    let summary: String
    let files: [ChatMessageFile]
    let officeDocument: LocalNativeOfficeDocument?
    let browserDocument: LocalNativeBrowserDocument?
    let openRequests: [LocalAlpineOpenRequest]

    var requiresBrowserUserVerification: Bool {
        false
    }
}

enum LocalNativeOfficeKind: String, Sendable, Equatable {
    case excel
    case powerPoint
    case word
    case pdf

    var displayName: String {
        switch self {
        case .excel:
            return "Excel"
        case .powerPoint:
            return "PPT"
        case .word:
            return "Word"
        case .pdf:
            return "PDF"
        }
    }

    var creatingTitle: String {
        switch self {
        case .excel:
            return "正在生成本地 Excel..."
        case .powerPoint:
            return "正在生成本地 PPT..."
        case .word:
            return "正在生成本地 Word..."
        case .pdf:
            return "正在生成本地 PDF..."
        }
    }
}

struct LocalNativeOfficeDocument: Sendable {
    let kind: LocalNativeOfficeKind
    let ok: Bool
    let title: String
    let fileName: String
    let summary: String
    let previewText: String
    let previewCount: Int
    let error: String?
}

struct LocalNativeBrowserDocument: Sendable {
    let ok: Bool
    let action: String
    let title: String
    let url: String?
    let query: String?
    let summary: String
    let items: [ChatStatusItem]
    let previewImages: [String]
    let error: String?
    let requiresUserVerification: Bool
}

enum LocalOfficeProgressPhase: Sendable {
    case parsedDemand
    case generatedFile
    case generatedPreview
}

typealias LocalOfficeProgressHandler = @MainActor (LocalOfficeProgressPhase) async -> Void

@MainActor
final class LocalNativeToolService {
    static let shared = LocalNativeToolService()

    private var latestConvertibleOfficeFileURL: String?
    private var latestConvertibleOfficeFileName: String?

    private init() {}

    func executeBlocks(
        in content: String,
        officeProgress: LocalOfficeProgressHandler? = nil
    ) async -> LocalNativeToolRunResult {
        let calls = Self.parsedToolCalls(in: content)
        guard !calls.isEmpty else {
            return LocalNativeToolRunResult(
                didExecute: false,
                summary: "",
                files: [],
                officeDocument: nil,
                browserDocument: nil,
                openRequests: []
            )
        }

        var results: [[String: Any]] = []
        for call in calls {
            let result = await execute(call, officeProgress: officeProgress)
            results.append(result)
        }

        let payload: [String: Any] = [
            "tool": "iexa_native",
            "results": results
        ]
        return LocalNativeToolRunResult(
            didExecute: true,
            summary: prettyJSON(payload),
            files: results.flatMap(Self.files(from:)),
            officeDocument: Self.officeDocument(from: results),
            browserDocument: Self.browserDocument(from: results),
            openRequests: Self.openRequests(from: results)
        )
    }

    static func visibleContent(from content: String) -> String {
        let visible = stripNativeToolBlocks(from: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isToolResultPayloadOnly(visible) ? "" : visible
    }

    private static func isToolResultPayloadOnly(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return false }
        let lower = trimmed.lowercased()
        guard lower.contains(#""results""#) || lower.contains(#""browser_action""#) || lower.contains(#""browser_use_action""#) else {
            return false
        }
        let toolMarkers = [
            #""action"\s*:\s*"browser_use""#,
            #""action"\s*:\s*"browser\.use""#,
            #""browser_action"\s*:\s*"browser\."#,
            #""browser_use_action"\s*:\s*"browser\."#,
            #""focused_element"\s*:"#
        ]
        return toolMarkers.contains { pattern in
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static func containsNativeToolBlock(_ content: String) -> Bool {
        content.range(of: #"```iexa_native\s*[\s\S]*?```"#, options: [.regularExpression, .caseInsensitive]) != nil
            || taggedNativeToolBodies(in: content).isEmpty == false
            || plainLineNativeToolCalls(in: content).isEmpty == false
            || looseNativeToolBodies(in: content).isEmpty == false
            || dsmlToolCallObjects(in: content).isEmpty == false
    }

    static func officeActionKind(in content: String) -> LocalNativeOfficeKind? {
        let lower = content.lowercased()
        if lower.contains("office.create_pdf")
            || lower.contains("office_create_pdf")
            || lower.contains("create_pdf")
            || lower.contains("pdf.create")
            || lower.range(of: #""action"\s*:\s*"pdf""#, options: .regularExpression) != nil
            || lower.range(of: #""name"\s*:\s*"pdf""#, options: .regularExpression) != nil {
            return .pdf
        }
        if lower.contains("office.create_ppt")
            || lower.contains("office.create_powerpoint")
            || lower.contains("office_create_ppt")
            || lower.contains("create_ppt")
            || lower.contains("create_powerpoint")
            || lower.contains("ppt.create")
            || lower.contains("powerpoint.create")
            || lower.range(of: #""action"\s*:\s*"ppt""#, options: .regularExpression) != nil
            || lower.range(of: #""name"\s*:\s*"ppt""#, options: .regularExpression) != nil {
            return .powerPoint
        }
        if lower.contains("office.create_excel")
            || lower.contains("office_create_excel")
            || lower.contains("create_excel")
            || lower.contains("excel.create")
            || lower.range(of: #""action"\s*:\s*"excel""#, options: .regularExpression) != nil
            || lower.range(of: #""name"\s*:\s*"excel""#, options: .regularExpression) != nil {
            return .excel
        }
        if lower.contains("office.create_word")
            || lower.contains("office.create_docx")
            || lower.contains("office_create_word")
            || lower.contains("create_word")
            || lower.contains("create_docx")
            || lower.contains("word.create")
            || lower.contains("docx.create")
            || lower.range(of: #""action"\s*:\s*"word""#, options: .regularExpression) != nil
            || lower.range(of: #""name"\s*:\s*"word""#, options: .regularExpression) != nil {
            return .word
        }
        return nil
    }

    static func officeActionName(in content: String) -> String? {
        if officeDeleteActionName(in: content) != nil {
            return "office.delete"
        }
        guard let kind = officeActionKind(in: content) else {
            return nil
        }
        switch kind {
        case .excel:
            return "office.create_excel"
        case .powerPoint:
            return "office.create_ppt"
        case .word:
            return "office.create_word"
        case .pdf:
            return "office.create_pdf"
        }
    }

    static func officeDeleteActionName(in content: String) -> String? {
        let lower = content.lowercased()
        let actions = [
            "office.delete", "office_delete", "delete_office", "office.remove",
            "office_remove", "delete_office_document", "remove_office_document",
            "delete_document", "remove_document"
        ]
        return actions.first { action in
            lower.contains(action)
                || lower.range(
                    of: #""(?:action|name|tool|function)"\s*:\s*""# + NSRegularExpression.escapedPattern(for: action) + #"""#,
                    options: .regularExpression
                ) != nil
        }
    }

    static func browserActionName(in content: String) -> String? {
        let lower = content.lowercased()
        let actions = [
            "web.search", "web_search", "search_web", "browser.search", "browser_search",
            "browser.use", "browser_use",
            "browser.open", "browser_open", "browser.navigate", "navigate",
            "browser.readable", "browser_readable", "browser.get_readable", "get_readable",
            "browser.text", "browser_text", "browser.get_text", "get_text",
            "browser.info", "browser_info", "browser.get_page_info", "get_page_info",
            "browser.inspect", "browser_inspect", "inspect", "page_inspect", "inspect_page", "browser.page_state", "browser_page_state",
            "browser.auto", "browser_auto", "auto", "complete_task", "browser.complete_task",
            "browser.observe", "browser_observe", "browser.get_state", "browser_get_state", "observe", "get_state",
            "browser.screenshot", "browser_screenshot",
            "browser.fetch", "browser_fetch",
            "browser.click", "browser_click", "click",
            "browser.type", "browser_type", "type",
            "browser.hover", "browser_hover", "hover",
            "browser.scroll", "browser_scroll", "scroll",
            "browser.scroll_and_collect", "browser_scroll_and_collect", "scroll_and_collect",
            "browser.find_elements", "browser_find_elements", "find_elements",
            "browser.get_backbone", "browser_get_backbone", "get_backbone",
            "browser.execute_js", "browser_execute_js", "execute_js", "eval_js",
            "browser.set_viewport", "browser_set_viewport", "set_viewport",
            "browser.set_user_agent", "browser_set_user_agent", "set_user_agent",
            "browser.get_cookies", "browser_get_cookies", "get_cookies",
            "browser.wait_for_dom_stable", "browser_wait_for_dom_stable", "wait_for_dom_stable",
            "browser.wait_for_image", "browser_wait_for_image", "wait_for_image", "wait_image", "image_result",
            "browser.new_tab", "browser_new_tab", "new_tab",
            "browser.close_tab", "browser_close_tab", "close_tab",
            "browser.list_tabs", "browser_list_tabs", "list_tabs"
        ]
        return actions.first { action in
            if action.contains(".") || action.contains("_") || action.hasPrefix("browser") || action.hasPrefix("web") {
                return lower.contains(action)
            }
            let escaped = NSRegularExpression.escapedPattern(for: action)
            let pattern = #""(?:action|name|browser_action|browser_use_action|operation|op)"\s*:\s*""# + escaped + #"""#
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func shortcutsActionName(in content: String) -> String? {
        let lower = content.lowercased()
        let actions = [
            "shortcuts.run", "shortcut.run", "shortcuts_run", "run_shortcut",
            "shortcuts.open", "shortcut.open", "shortcuts_open", "open_shortcut",
            "shortcuts.edit", "shortcut.edit", "shortcuts_edit", "edit_shortcut",
            "shortcuts.create", "shortcut.create", "shortcuts_create", "create_shortcut"
        ]
        return actions.first { action in
            lower.contains(action)
                || lower.contains(action.replacingOccurrences(of: ".", with: "\\."))
        }
    }

    private func execute(
        _ call: [String: Any],
        officeProgress: LocalOfficeProgressHandler?
    ) async -> [String: Any] {
        let action = (call["action"] as? String ?? call["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "get_location", "location.get", "location_get", "ios.location", "ios_location", "device.location", "device_location":
            return executeGetLocation()
        case "get_weather", "weather.get":
            return await executeGetWeather()
        case "list_calendar_events", "calendar.list_events":
            return await executeListCalendarEvents(call)
        case "create_calendar_event", "calendar.create_event":
            return await executeCreateCalendarEvent(call)
        case "delete_calendar_event", "calendar.delete_event":
            return await executeDeleteCalendarEvent(call)
        case "update_calendar_event", "calendar.update_event":
            return await executeUpdateCalendarEvent(call)
        case "calendar.free_busy", "calendar.freebusy", "calendar.availability":
            return await executeCalendarFreeBusy(call)
        case "list_calendars", "calendar.list_calendars":
            return await executeListCalendars()
        case "contacts.list", "contacts_list", "list_contacts",
             "contacts.search", "contacts_search", "search_contacts":
            return await executeListContacts(call)
        case "contacts.get", "contacts_get", "get_contact":
            return await executeGetContact(call)
        case "device.status", "device_status", "get_device_status":
            return executeDeviceStatus()
        case "device.info", "device_info", "get_device_info":
            return executeDeviceInfo()
        case "clipboard.read", "clipboard_read", "read_clipboard":
            return executeClipboardRead()
        case "clipboard.write", "clipboard_write", "write_clipboard":
            return executeClipboardWrite(call)
        case "system.notify", "system_notify", "notify", "show_notification":
            return await executeSystemNotify(call)
        case "web.search", "web_search", "search_web", "browser.search", "browser_search",
             "browser.use", "browser_use",
             "browser.open", "browser_open", "browser.navigate", "browser.navigate_url", "navigate",
             "browser.readable", "browser_readable", "browser.get_readable", "get_readable", "read_webpage",
             "browser.text", "browser_text", "browser.get_text", "get_text",
             "browser.info", "browser_info", "browser.get_page_info", "get_page_info",
             "browser.inspect", "browser_inspect", "inspect", "page_inspect", "inspect_page", "browser.page_state", "browser_page_state",
             "browser.auto", "browser_auto", "auto", "complete_task", "browser.complete_task",
             "browser.observe", "browser_observe", "browser.get_state", "browser_get_state", "observe", "get_state",
             "browser.screenshot", "browser_screenshot", "screenshot",
             "browser.fetch", "browser_fetch", "fetch",
             "browser.click", "browser_click", "click",
             "browser.type", "browser_type", "type",
             "browser.hover", "browser_hover", "hover",
             "browser.scroll", "browser_scroll", "scroll",
             "browser.scroll_and_collect", "browser_scroll_and_collect", "scroll_and_collect",
             "browser.find_elements", "browser_find_elements", "find_elements",
             "browser.get_backbone", "browser_get_backbone", "get_backbone",
             "browser.execute_js", "browser_execute_js", "execute_js", "eval_js",
             "browser.set_viewport", "browser_set_viewport", "set_viewport",
             "browser.set_user_agent", "browser_set_user_agent", "set_user_agent",
             "browser.get_cookies", "browser_get_cookies", "get_cookies",
             "browser.wait_for_dom_stable", "browser_wait_for_dom_stable", "wait_for_dom_stable",
             "browser.wait_for_image", "browser_wait_for_image", "wait_for_image", "wait_image", "image_result",
             "browser.new_tab", "browser_new_tab", "new_tab",
             "browser.close_tab", "browser_close_tab", "close_tab",
             "browser.list_tabs", "browser_list_tabs", "list_tabs":
            return await executeBrowserTool(action: action, call)
        case "shortcuts.run", "shortcut.run", "shortcuts_run", "run_shortcut",
             "shortcuts.open", "shortcut.open", "shortcuts_open", "open_shortcut",
             "shortcuts.edit", "shortcut.edit", "shortcuts_edit", "edit_shortcut",
             "shortcuts.create", "shortcut.create", "shortcuts_create", "create_shortcut":
            return await executeShortcutsTool(action: action, call)
        case "office.create_excel", "office_create_excel", "create_excel", "excel.create", "excel":
            return await executeCreateExcel(call, progress: officeProgress)
        case "office.create_ppt", "office.create_powerpoint", "office_create_ppt", "create_ppt", "create_powerpoint", "ppt.create", "powerpoint.create", "ppt":
            return await executeCreatePowerPoint(call, progress: officeProgress)
        case "office.create_word", "office.create_docx", "office_create_word", "create_word", "create_docx", "word.create", "docx.create", "word", "docx":
            return await executeCreateWord(call, progress: officeProgress)
        case "office.create_pdf", "office_create_pdf", "create_pdf", "pdf.create", "pdf":
            return await executeCreatePDF(call, progress: officeProgress)
        case "office.delete", "office_delete", "delete_office", "office.remove", "office_remove", "delete_office_document", "remove_office_document", "delete_document", "remove_document":
            return await executeDeleteOffice(call)
        default:
            return [
                "action": action.isEmpty ? "unknown" : action,
                "ok": false,
                "error": "Unsupported local native action"
            ]
        }
    }

    private func executeBrowserTool(action: String, _ call: [String: Any]) async -> [String: Any] {
        if let request = Self.localPreviewOpenRequest(from: call) {
            return [
                "action": action,
                "ok": true,
                "title": "本地网页预览",
                "url": request.target,
                "summary": "已打开本地网页预览。",
                "open_preview_target": request.target
            ]
        }
        var payload = await BrowserWebSearchService.shared.executeNativeBrowserTool(action: action, call: call)
        if payload["action"] == nil {
            payload["action"] = action
        }
        return payload
    }

    private func executeShortcutsTool(action: String, _ call: [String: Any]) async -> [String: Any] {
        let normalized = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.contains("run") {
            let name = Self.firstString(
                in: call,
                keys: ["name", "shortcut_name", "shortcut", "title"]
            )
            guard let name, !name.isEmpty else {
                return [
                    "action": "shortcuts.run",
                    "ok": false,
                    "error": "Missing required field: name"
                ]
            }
            let input = Self.firstString(
                in: call,
                keys: ["input", "text", "content", "message", "value"]
            )
            guard let url = Self.shortcutsRunURL(name: name, input: input) else {
                return [
                    "action": "shortcuts.run",
                    "ok": false,
                    "shortcut": name,
                    "error": "Unable to build Shortcuts run URL"
                ]
            }
            let didOpen = await openShortcutsURL(url)
            return [
                "action": "shortcuts.run",
                "ok": didOpen,
                "shortcut": name,
                "input_provided": input?.isEmpty == false,
                "summary": didOpen
                    ? "已请求 iOS 运行快捷指令「\(name)」。如果系统需要权限或确认，会由快捷指令 App 处理。"
                    : "无法打开 iOS 快捷指令。请确认系统已安装快捷指令 App。"
            ]
        }

        if normalized.contains("create") || Self.boolValue(call["create"]) {
            guard let url = URL(string: "shortcuts://create-shortcut") else {
                return [
                    "action": "shortcuts.create",
                    "ok": false,
                    "error": "Unable to build Shortcuts create URL"
                ]
            }
            let didOpen = await openShortcutsURL(url)
            return [
                "action": "shortcuts.create",
                "ok": didOpen,
                "summary": didOpen
                    ? "已打开 iOS 快捷指令创建界面。系统不允许第三方 App 静默写入完整快捷指令，用户需要在快捷指令 App 内确认并保存。"
                    : "无法打开 iOS 快捷指令创建界面。请确认系统已安装快捷指令 App。",
                "requires_user_confirmation": true
            ]
        }

        let name = Self.firstString(
            in: call,
            keys: ["name", "shortcut_name", "shortcut", "title"]
        )
        let url: URL?
        if let name, !name.isEmpty {
            url = Self.shortcutsOpenURL(name: name)
        } else {
            url = URL(string: "shortcuts://")
        }
        guard let url else {
            return [
                "action": "shortcuts.open",
                "ok": false,
                "error": "Unable to build Shortcuts open URL"
            ]
        }
        let didOpen = await openShortcutsURL(url)
        return [
            "action": "shortcuts.open",
            "ok": didOpen,
            "shortcut": name ?? "",
            "summary": didOpen
                ? (name?.isEmpty == false
                    ? "已打开 iOS 快捷指令「\(name ?? "")」编辑界面，用户可在系统 App 内修改。"
                    : "已打开 iOS 快捷指令 App。")
                : "无法打开 iOS 快捷指令。请确认系统已安装快捷指令 App。",
            "requires_user_confirmation": name?.isEmpty == false
        ]
    }

    private static func firstString(in call: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = call[key] else { continue }
            let text: String?
            if let string = value as? String {
                text = string
            } else if let number = value as? NSNumber {
                text = number.stringValue
            } else {
                text = String(describing: value)
            }
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return ["1", "true", "yes", "y", "on"].contains(normalized)
        }
        return false
    }

    private static func shortcutsRunURL(name: String, input: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var queryItems = [URLQueryItem(name: "name", value: name)]
        if let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "input", value: "text"))
            queryItems.append(URLQueryItem(name: "text", value: input))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func shortcutsOpenURL(name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    private func openShortcutsURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { didOpen in
                continuation.resume(returning: didOpen)
            }
        }
    }

    private func executeCreateExcel(
        _ call: [String: Any],
        progress: LocalOfficeProgressHandler?
    ) async -> [String: Any] {
        do {
            let result = try await LocalOfficeDocumentService.shared.createExcel(from: call, progress: progress)
            var payload = result.payload
            payload["action"] = "office.create_excel"
            rememberConvertibleOfficeResult(payload)
            return payload
        } catch {
            return [
                "action": "office.create_excel",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeCreatePowerPoint(
        _ call: [String: Any],
        progress: LocalOfficeProgressHandler?
    ) async -> [String: Any] {
        do {
            let result = try await LocalOfficeDocumentService.shared.createPowerPoint(from: call, progress: progress)
            var payload = result.payload
            payload["action"] = "office.create_ppt"
            rememberConvertibleOfficeResult(payload)
            return payload
        } catch {
            return [
                "action": "office.create_ppt",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeCreateWord(
        _ call: [String: Any],
        progress: LocalOfficeProgressHandler?
    ) async -> [String: Any] {
        do {
            let result = try await LocalOfficeDocumentService.shared.createWord(from: call, progress: progress)
            var payload = result.payload
            payload["action"] = "office.create_word"
            rememberConvertibleOfficeResult(payload)
            return payload
        } catch {
            return [
                "action": "office.create_word",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeCreatePDF(
        _ call: [String: Any],
        progress: LocalOfficeProgressHandler?
    ) async -> [String: Any] {
        do {
            let result = try await LocalOfficeDocumentService.shared.createPDF(
                from: callWithLatestOfficeSourceIfNeeded(call),
                progress: progress
            )
            var payload = result.payload
            payload["action"] = "office.create_pdf"
            return payload
        } catch {
            return [
                "action": "office.create_pdf",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeDeleteOffice(_ call: [String: Any]) async -> [String: Any] {
        do {
            let result = try LocalOfficeDocumentService.shared.deleteDocument(
                from: callWithLatestOfficeDeleteTargetIfNeeded(call)
            )
            var payload = result.payload
            payload["action"] = "office.delete"
            clearRememberedOfficeResultIfDeleted(payload)
            return payload
        } catch {
            return [
                "action": "office.delete",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func rememberConvertibleOfficeResult(_ payload: [String: Any]) {
        guard (payload["ok"] as? Bool) == true,
              let url = payload["file_url"] as? String,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        latestConvertibleOfficeFileURL = url
        latestConvertibleOfficeFileName = payload["file_name"] as? String
    }

    private func clearRememberedOfficeResultIfDeleted(_ payload: [String: Any]) {
        guard (payload["ok"] as? Bool) == true else { return }
        let deletedURL = (payload["deleted_file_url"] as? String) ?? ""
        let deletedName = (payload["file_name"] as? String) ?? ""
        if !deletedURL.isEmpty, deletedURL == latestConvertibleOfficeFileURL {
            latestConvertibleOfficeFileURL = nil
            latestConvertibleOfficeFileName = nil
            return
        }
        if !deletedName.isEmpty, deletedName == latestConvertibleOfficeFileName {
            latestConvertibleOfficeFileURL = nil
            latestConvertibleOfficeFileName = nil
        }
    }

    private func callWithLatestOfficeSourceIfNeeded(_ call: [String: Any]) -> [String: Any] {
        guard !hasPDFSource(in: call),
              let latestConvertibleOfficeFileURL,
              !latestConvertibleOfficeFileURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return call
        }
        var enriched = call
        enriched["source_url"] = latestConvertibleOfficeFileURL
        if enriched["title"] == nil,
           let latestConvertibleOfficeFileName,
           !latestConvertibleOfficeFileName.isEmpty {
            enriched["title"] = (latestConvertibleOfficeFileName as NSString).deletingPathExtension
        }
        return enriched
    }

    private func callWithLatestOfficeDeleteTargetIfNeeded(_ call: [String: Any]) -> [String: Any] {
        guard !hasOfficeDeleteTarget(in: call),
              let latestConvertibleOfficeFileURL,
              !latestConvertibleOfficeFileURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return call
        }
        var enriched = call
        enriched["file_url"] = latestConvertibleOfficeFileURL
        enriched["latest"] = true
        if enriched["file_name"] == nil,
           let latestConvertibleOfficeFileName,
           !latestConvertibleOfficeFileName.isEmpty {
            enriched["file_name"] = latestConvertibleOfficeFileName
        }
        return enriched
    }

    private func hasPDFSource(in call: [String: Any]) -> Bool {
        [
            "source_file",
            "source_url",
            "input_file",
            "input_url",
            "file_url",
            "from"
        ].contains { key in
            guard let value = call[key] else { return false }
            return !String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func hasOfficeDeleteTarget(in call: [String: Any]) -> Bool {
        [
            "file_url",
            "source_file",
            "source_url",
            "input_file",
            "input_url",
            "url",
            "path",
            "file",
            "target",
            "from",
            "file_name",
            "filename",
            "name",
            "title"
        ].contains { key in
            guard let value = call[key] else { return false }
            return !String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func files(from result: [String: Any]) -> [ChatMessageFile] {
        guard (result["ok"] as? Bool) == true else { return [] }
        var files: [ChatMessageFile] = []
        let attachFile = result.keys.contains("attach_file") ? Self.boolValue(result["attach_file"]) : true
        if attachFile,
           let fileURL = result["file_url"] as? String,
           let fileName = result["file_name"] as? String {
            let contentType = result["content_type"] as? String
            files.append(ChatMessageFile(
                type: contentType?.lowercased().hasPrefix("image/") == true ? "image" : "file",
                url: fileURL,
                name: fileName,
                contentType: contentType,
                displayURL: contentType?.lowercased().hasPrefix("image/") == true ? fileURL : nil
            ))
        }
        if attachFile, let previews = result["preview_images"] as? [String] {
            for (index, preview) in previews.prefix(6).enumerated() {
                let lowercasedPreview = preview.lowercased()
                let previewIsJPEG = lowercasedPreview.hasSuffix(".jpg") || lowercasedPreview.hasSuffix(".jpeg")
                let previewExtension = previewIsJPEG ? "jpg" : "png"
                files.append(ChatMessageFile(
                    type: "image",
                    url: preview,
                    name: "preview-\(index + 1).\(previewExtension)",
                    contentType: previewIsJPEG ? "image/jpeg" : "image/png"
                ))
            }
        }
        return files
    }

    private static func browserDocument(from results: [[String: Any]]) -> LocalNativeBrowserDocument? {
        for result in results.reversed() {
            let action = (
                (result["browser_action"] as? String)
                ?? (result["browser_use_action"] as? String)
                ?? (result["operation"] as? String)
                ?? (result["op"] as? String)
                ?? (result["action"] as? String)
                ?? ""
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard action.contains("browser")
                    || action.contains("web.search")
                    || action.contains("web_search")
                    || action.contains("search_web")
                    || action.contains("get_readable")
                    || action == "browser_use"
                    || action == "inspect"
                    || action == "page_inspect"
                    || action == "inspect_page"
                    || action == "auto"
                    || action == "complete_task"
                    || action == "navigate"
                    || action == "fetch"
                    || action == "click"
                    || action == "type"
                    || action == "hover"
                    || action == "scroll"
                    || action == "scroll_and_collect"
                    || action == "find_elements"
                    || action == "get_backbone"
                    || action == "observe"
                    || action == "get_state"
                    || action == "execute_js"
                    || action == "set_viewport"
                    || action == "set_user_agent"
                    || action == "get_cookies"
                    || action == "wait_for_dom_stable"
                    || action == "wait_for_image"
                    || action == "wait_image"
                    || action == "image_result"
                    || action == "new_tab"
                    || action == "close_tab"
                    || action == "list_tabs"
                    || action == "screenshot" else {
                continue
            }

            let ok = result["ok"] as? Bool ?? false
            let title = (result["title"] as? String)
                ?? (result["query"] as? String)
                ?? "网页工具"
            let url = (result["url"] as? String)
                ?? (result["link"] as? String)
            let query = result["query"] as? String
            let summary = (result["summary"] as? String)
                ?? (ok ? "搜索完成。" : "搜索失败。")
            let previewImages = result["preview_images"] as? [String] ?? []
            var items = browserItems(from: result["items"])
            if items.isEmpty, let url {
                items = [
                    ChatStatusItem(
                        title: title,
                        link: url,
                        snippet: result["description"] as? String ?? result["text"] as? String,
                        thumbnailURL: previewImages.first
                    )
                ]
            }

            return LocalNativeBrowserDocument(
                ok: ok,
                action: action,
                title: title,
                url: url,
                query: query,
                summary: summary,
                items: items,
                previewImages: previewImages,
                error: result["error"] as? String,
                requiresUserVerification: false
            )
        }
        return nil
    }

    private static func browserItems(from value: Any?) -> [ChatStatusItem] {
        guard let rawItems = value as? [[String: Any]] else { return [] }
        return rawItems.compactMap { raw in
            let title = (raw["title"] as? String)
                ?? (raw["name"] as? String)
            let link = (raw["link"] as? String)
                ?? (raw["url"] as? String)
                ?? (raw["href"] as? String)
                ?? (raw["source"] as? String)
            let snippet = (raw["snippet"] as? String)
                ?? (raw["description"] as? String)
                ?? (raw["text"] as? String)
            let thumbnail = (raw["thumbnail_url"] as? String)
                ?? (raw["thumbnailURL"] as? String)
                ?? (raw["image"] as? String)
            guard title?.isEmpty == false || link?.isEmpty == false || snippet?.isEmpty == false else {
                return nil
            }
            return ChatStatusItem(
                title: title,
                link: link,
                snippet: snippet.map { String($0.prefix(320)) },
                thumbnailURL: thumbnail
            )
        }
    }

    private static func openRequests(from results: [[String: Any]]) -> [LocalAlpineOpenRequest] {
        var requests = results.compactMap { result in
            firstString(in: result, keys: ["open_preview_target", "preview_target", "local_preview"])
                .map { LocalAlpineOpenRequest(target: $0) }
        }
        return requests
    }

    private static func localPreviewOpenRequest(from call: [String: Any]) -> LocalAlpineOpenRequest? {
        let candidates = [
            firstString(in: call, keys: ["url", "link", "href", "page_url", "source", "input_url", "path", "file"]),
            firstString(in: call, keys: ["open_preview_target", "preview_target", "local_preview"])
        ].compactMap { $0 }

        for candidate in candidates {
            if let target = normalizedLocalPreviewTarget(candidate) {
                return LocalAlpineOpenRequest(target: target)
            }
        }
        return nil
    }

    private static func normalizedLocalPreviewTarget(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        if trimmed.hasPrefix("/mnt/iexa") || trimmed.hasPrefix("/tmp/") || trimmed.hasPrefix("/var/") {
            return trimmed
        }
        if lowered.hasPrefix("file://") || lowered.hasPrefix("iexa://") {
            return trimmed
        }
        if let relativeTarget = relativeWorkspacePreviewTarget(from: trimmed) {
            return relativeTarget
        }
        let webCandidate = sanitizedWebPreviewCandidate(trimmed)
        if let loopbackTarget = normalizedLoopbackWebPreviewTarget(webCandidate) {
            return loopbackTarget
        }

        guard let url = URL(string: webCandidate),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              (url.host ?? "").caseInsensitiveCompare("iexa.preview") == .orderedSame else {
            return nil
        }

        let decodedPath = url.path.removingPercentEncoding ?? url.path
        let withoutLeadingSlash = decodedPath.hasPrefix("/")
            ? String(decodedPath.dropFirst())
            : decodedPath
        if withoutLeadingSlash.lowercased().hasPrefix("file://") {
            return withoutLeadingSlash
        }
        if decodedPath.hasPrefix("/mnt/iexa") {
            return decodedPath
        }
        if decodedPath.hasPrefix("/workspace/") {
            return "iexa://workspace/" + String(decodedPath.dropFirst("/workspace/".count))
        }
        if decodedPath.hasPrefix("/file/") {
            return "/" + String(decodedPath.dropFirst("/file/".count))
        }
        return nil
    }

    private static func normalizedLoopbackWebPreviewTarget(_ rawTarget: String) -> String? {
        var candidate = rawTarget
        if isBareLoopbackWebTarget(candidate) {
            candidate = "http://\(candidate)"
        }
        guard var components = URLComponents(string: candidate),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(),
              isLoopbackPreviewHost(host) else {
            return nil
        }
        if host == "0.0.0.0" {
            components.host = "127.0.0.1"
        }
        return components.string ?? candidate
    }

    private static func sanitizedWebPreviewCandidate(_ rawTarget: String) -> String {
        var candidate = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let embedded = firstMatch(
            pattern: #"https?://[^\s"'`<>()\[\]{}]+"#,
            in: candidate
        ) ?? firstMatch(
            pattern: #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d{1,5}[^\s"'`<>()\[\]{}]*"#,
            in: candidate
        ) {
            candidate = embedded
        }
        let trailingCharacters = CharacterSet(charactersIn: "\"'`*_~.,;:!?)[]{}<>，。！？；：、）】》」』")
        while let scalar = candidate.unicodeScalars.last,
              trailingCharacters.contains(scalar) {
            candidate.removeLast()
        }
        return candidate
    }

    private static func isBareLoopbackWebTarget(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("localhost:")
            || lowercased.hasPrefix("127.0.0.1:")
            || lowercased.hasPrefix("0.0.0.0:")
            || lowercased.hasPrefix("[::1]:")
    }

    private static func isLoopbackPreviewHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "::1"
            || host == "0.0.0.0"
            || host.hasPrefix("127.")
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    private static func relativeWorkspacePreviewTarget(from rawTarget: String) -> String? {
        let normalized = rawTarget.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"),
              !normalized.hasPrefix("./"),
              !normalized.hasPrefix("../"),
              !normalized.contains("://"),
              normalized.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        let lowercased = normalized.lowercased()
        guard lowercased.hasSuffix(".html")
            || lowercased.hasSuffix(".htm")
            || lowercased.hasSuffix(".svg") else {
            return nil
        }
        return "iexa://workspace/\(normalized)"
    }

    private static func officeDocument(from results: [[String: Any]]) -> LocalNativeOfficeDocument? {
        for result in results {
            let action = (result["action"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let documentType = (result["document_type"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let kind: LocalNativeOfficeKind?
            if action.contains("ppt") || action.contains("powerpoint") || documentType == "ppt" {
                kind = .powerPoint
            } else if action.contains("excel") || documentType == "excel" {
                kind = .excel
            } else if action.contains("word") || action.contains("docx") || documentType == "word" {
                kind = .word
            } else if action.contains("pdf") || documentType == "pdf" {
                kind = .pdf
            } else {
                kind = nil
            }
            guard let kind else { continue }

            let ok = result["ok"] as? Bool ?? false
            let previews = result["preview_images"] as? [String] ?? []
            return LocalNativeOfficeDocument(
                kind: kind,
                ok: ok,
                title: result["title"] as? String ?? kind.displayName,
                fileName: result["file_name"] as? String ?? "",
                summary: result["summary"] as? String ?? "",
                previewText: result["preview_text"] as? String ?? "",
                previewCount: previews.count,
                error: result["error"] as? String
            )
        }
        return nil
    }

    private func executeDeviceStatus() -> [String: Any] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        var payload: [String: Any] = [
            "action": "device.status",
            "ok": true,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "model": device.model,
            "localized_model": device.localizedModel,
            "app_state": applicationStateString(UIApplication.shared.applicationState),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermal_state": thermalStateString(ProcessInfo.processInfo.thermalState),
            "timezone": TimeZone.current.identifier,
            "locale": Locale.current.identifier
        ]
        if device.batteryLevel >= 0 {
            payload["battery_percent"] = Int((device.batteryLevel * 100).rounded())
            payload["battery_state"] = batteryStateString(device.batteryState)
        }
        return payload
    }

    private func executeDeviceInfo() -> [String: Any] {
        var payload = executeDeviceStatus()
        let screen = UIScreen.main
        payload["action"] = "device.info"
        payload["screen_bounds"] = [
            "width": Double(screen.bounds.width),
            "height": Double(screen.bounds.height),
            "scale": Double(screen.scale)
        ]
        payload["processor_count"] = ProcessInfo.processInfo.processorCount
        payload["active_processor_count"] = ProcessInfo.processInfo.activeProcessorCount
        payload["physical_memory_bytes"] = Int64(ProcessInfo.processInfo.physicalMemory)
        payload["os_version_string"] = ProcessInfo.processInfo.operatingSystemVersionString
        return payload
    }

    private func executeClipboardRead() -> [String: Any] {
        let text = UIPasteboard.general.string ?? ""
        return [
            "action": "clipboard.read",
            "ok": true,
            "has_text": !text.isEmpty,
            "text": String(text.prefix(8_000)),
            "truncated": text.count > 8_000
        ]
    }

    private func executeClipboardWrite(_ call: [String: Any]) -> [String: Any] {
        let text = ((call["text"] as? String)
                    ?? (call["content"] as? String)
                    ?? (call["value"] as? String)
                    ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return [
                "action": "clipboard.write",
                "ok": false,
                "error": "Missing required field: text"
            ]
        }
        UIPasteboard.general.string = text
        return [
            "action": "clipboard.write",
            "ok": true,
            "character_count": text.count
        ]
    }

    private func executeSystemNotify(_ call: [String: Any]) async -> [String: Any] {
        let title = ((call["title"] as? String) ?? "Iexa")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ((call["body"] as? String)
                    ?? (call["message"] as? String)
                    ?? (call["text"] as? String)
                    ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return [
                "action": "system.notify",
                "ok": false,
                "error": "Missing required field: body"
            ]
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = await NotificationService.shared.requestPermission()
            guard granted else {
                return [
                    "action": "system.notify",
                    "ok": false,
                    "error": "Notification permission was not granted"
                ]
            }
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return [
                "action": "system.notify",
                "ok": false,
                "error": "Notification permission is disabled"
            ]
        }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Iexa" : String(title.prefix(80))
        content.body = String(body.prefix(240))
        content.sound = .default

        let identifier = "native-tool-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return [
                "action": "system.notify",
                "ok": true,
                "id": identifier
            ]
        } catch {
            return [
                "action": "system.notify",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeGetLocation() -> [String: Any] {
        let manager = LocationManager.shared
        if !manager.isLocationEnabled {
            manager.isLocationEnabled = true
            manager.requestPermissionAndStart()
        } else {
            manager.requestPermissionAndStart()
        }

        if let location = manager.currentLocationString ?? manager.locationString {
            return [
                "action": "get_location",
                "ok": true,
                "location": location
            ]
        }

        return [
            "action": "get_location",
            "ok": false,
            "error": "Location is not available yet. The user may need to grant permission or wait for a GPS fix."
        ]
    }

    private func executeGetWeather() async -> [String: Any] {
        do {
            let snapshot = try await LocalWeatherService.shared.currentWeather()
            var payload: [String: Any] = [
                "action": "get_weather",
                "ok": true,
                "date": isoString(snapshot.date),
                "condition": snapshot.condition,
                "symbol": snapshot.symbolName,
                "temperature_celsius": roundOne(snapshot.temperatureCelsius),
                "apparent_temperature_celsius": roundOne(snapshot.apparentTemperatureCelsius),
                "humidity_percent": Int((snapshot.humidity * 100).rounded()),
                "wind_speed_kph": roundOne(snapshot.windSpeedKPH),
                "latitude": snapshot.latitude,
                "longitude": snapshot.longitude,
                "attribution": snapshot.attributionServiceName,
                "attribution_legal_url": snapshot.attributionLegalURL.absoluteString
            ]
            if let locationName = snapshot.locationName {
                payload["location"] = locationName
            }
            if let precipitationChance = snapshot.precipitationChance {
                payload["precipitation_chance_percent"] = Int((precipitationChance * 100).rounded())
            }
            return payload
        } catch {
            return [
                "action": "get_weather",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeListCalendarEvents(_ call: [String: Any]) async -> [String: Any] {
        do {
            let start = parseDate(call["start"]) ?? Calendar.current.startOfDay(for: Date())
            let end = parseDate(call["end"]) ?? Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
            let events = try await LocalCalendarService.shared.loadEvents(start: start, end: end)
            return [
                "action": "list_calendar_events",
                "ok": true,
                "start": isoString(start),
                "end": isoString(end),
                "count": events.count,
                "events": events.map(calendarEventPayload)
            ]
        } catch {
            return [
                "action": "list_calendar_events",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeCreateCalendarEvent(_ call: [String: Any]) async -> [String: Any] {
        do {
            let calendars = try await LocalCalendarService.shared.loadCalendars()
            guard let calendarId = (call["calendar_id"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                    ?? calendars.first(where: { !$0.isSystem })?.id
                    ?? calendars.first?.id else {
                throw LocalCalendarError.noWritableCalendar
            }
            let title = (call["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else {
                return [
                    "action": "create_calendar_event",
                    "ok": false,
                    "error": "Missing required field: title"
                ]
            }
            guard let start = parseDate(call["start"]) else {
                return [
                    "action": "create_calendar_event",
                    "ok": false,
                    "error": "Missing or invalid required field: start"
                ]
            }
            let allDay = call["all_day"] as? Bool ?? false
            let fallbackEnd = Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3600)
            let end = parseDate(call["end"]) ?? fallbackEnd
            let alertMinutes = call["alert_minutes"] as? Int
            let request = CalendarEventCreateRequest(
                calendarId: calendarId,
                title: title,
                description: call["description"] as? String,
                startAt: Int64(start.timeIntervalSince1970 * 1_000_000_000),
                endAt: allDay ? nil : Int64(end.timeIntervalSince1970 * 1_000_000_000),
                allDay: allDay,
                location: call["location"] as? String,
                meta: alertMinutes.map { CalendarEventMeta(alertMinutes: $0) }
            )
            let created = try await LocalCalendarService.shared.createEvent(request)
            return [
                "action": "create_calendar_event",
                "ok": true,
                "event": calendarEventPayload(created)
            ]
        } catch {
            return [
                "action": "create_calendar_event",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeDeleteCalendarEvent(_ call: [String: Any]) async -> [String: Any] {
        guard let id = call["id"] as? String, !id.isEmpty else {
            return [
                "action": "delete_calendar_event",
                "ok": false,
                "error": "Missing required field: id"
            ]
        }
        do {
            try await LocalCalendarService.shared.deleteEvent(id: id)
            return [
                "action": "delete_calendar_event",
                "ok": true,
                "id": id
            ]
        } catch {
            return [
                "action": "delete_calendar_event",
                "ok": false,
                "id": id,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeUpdateCalendarEvent(_ call: [String: Any]) async -> [String: Any] {
        guard let id = Self.firstString(in: call, keys: ["id", "event_id"]), !id.isEmpty else {
            return [
                "action": "update_calendar_event",
                "ok": false,
                "error": "Missing required field: id"
            ]
        }
        let title = Self.firstString(in: call, keys: ["title"])
        if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return [
                "action": "update_calendar_event",
                "ok": false,
                "id": id,
                "error": "Title cannot be empty when provided"
            ]
        }

        do {
            let updated = try await LocalCalendarService.shared.updateEvent(
                id: id,
                request: CalendarEventUpdateRequest(
                    calendarId: Self.firstString(in: call, keys: ["calendar_id"]),
                    title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: Self.firstString(in: call, keys: ["description", "notes"]),
                    startAt: parseDate(call["start"]),
                    endAt: parseDate(call["end"]),
                    allDay: Self.boolValue(call["all_day"]),
                    location: Self.firstString(in: call, keys: ["location"]),
                    alertMinutes: Self.integerValue(call["alert_minutes"]),
                    clearAlerts: Self.boolValue(call["clear_alerts"]) ?? false
                )
            )
            return [
                "action": "update_calendar_event",
                "ok": true,
                "event": calendarEventPayload(updated)
            ]
        } catch {
            return [
                "action": "update_calendar_event",
                "ok": false,
                "id": id,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeCalendarFreeBusy(_ call: [String: Any]) async -> [String: Any] {
        guard let start = parseDate(call["start"]), let end = parseDate(call["end"]), end > start else {
            return [
                "action": "calendar.free_busy",
                "ok": false,
                "error": "Provide start and end ISO 8601 dates, with end after start"
            ]
        }
        do {
            let events = try await LocalCalendarService.shared.loadEvents(start: start, end: end)
            return [
                "action": "calendar.free_busy",
                "ok": true,
                "start": isoString(start),
                "end": isoString(end),
                "is_free": events.isEmpty,
                "busy_events": events.map(calendarEventPayload)
            ]
        } catch {
            return [
                "action": "calendar.free_busy",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeListCalendars() async -> [String: Any] {
        do {
            let calendars = try await LocalCalendarService.shared.loadCalendars()
            return [
                "action": "list_calendars",
                "ok": true,
                "calendars": calendars.map {
                    [
                        "id": $0.id,
                        "name": $0.name,
                        "color": $0.color,
                        "is_default": $0.isDefault,
                        "is_system": $0.isSystem
                    ] as [String: Any]
                }
            ]
        } catch {
            return [
                "action": "list_calendars",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeListContacts(_ call: [String: Any]) async -> [String: Any] {
        let action = ((call["action"] as? String) ?? "contacts.list").lowercased()
        let query = Self.firstString(in: call, keys: ["query", "search", "name"])
        let limit = Self.integerValue(call["limit"]) ?? 50
        do {
            let contacts = try await LocalContactsService.shared.listContacts(query: query, limit: limit)
            return [
                "action": action.contains("search") ? "contacts.search" : "contacts.list",
                "ok": true,
                "query": query ?? "",
                "count": contacts.count,
                "contacts": contacts.map(contactPayload)
            ]
        } catch {
            return [
                "action": action.contains("search") ? "contacts.search" : "contacts.list",
                "ok": false,
                "error": error.localizedDescription
            ]
        }
    }

    private func executeGetContact(_ call: [String: Any]) async -> [String: Any] {
        guard let id = Self.firstString(in: call, keys: ["id", "contact_id"]), !id.isEmpty else {
            return [
                "action": "contacts.get",
                "ok": false,
                "error": "Missing required field: id"
            ]
        }
        do {
            let contact = try await LocalContactsService.shared.contact(id: id)
            return ["action": "contacts.get", "ok": true, "contact": contactPayload(contact)]
        } catch {
            return ["action": "contacts.get", "ok": false, "id": id, "error": error.localizedDescription]
        }
    }

    static func parsedToolCalls(in content: String) -> [[String: Any]] {
        let pattern = #"```iexa_native\s*([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            var calls = looseNativeToolBodies(in: content)
                .flatMap { parseJSONCalls($0) }
                .filter { isSupportedNativeCall($0) }
            calls.append(contentsOf: dsmlToolCallObjects(in: content).map(Self.normalizedNativeCall(_:)).filter { isSupportedNativeCall($0) })
            return calls
        }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        var calls = matches.flatMap { match -> [[String: Any]] in
            guard match.numberOfRanges >= 2 else { return [] }
            let body = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return parseJSONCalls(body)
        }
        let fencedRanges = matches.map(\.range)
        let looseBodies = Self.looseNativeToolBodies(in: content, excluding: fencedRanges)
        calls.append(contentsOf: looseBodies.flatMap { parseJSONCalls($0) })
        calls.append(contentsOf: plainLineNativeToolCalls(in: content, excluding: fencedRanges))
        calls.append(contentsOf: dsmlToolCallObjects(in: content).map(Self.normalizedNativeCall(_:)))
        return calls.map(Self.normalizedNativeCall(_:)).filter { Self.isSupportedNativeCall($0) }
    }

    private static func dsmlToolCallObjects(in content: String) -> [[String: Any]] {
        let lines = content.components(separatedBy: .newlines)
        var calls: [[String: Any]] = []
        var currentCall: [String: Any]?
        var currentParameterName: String?
        var currentParameterLines: [String] = []

        func finalizeParameter() {
            guard let name = currentParameterName else { return }
            let value = currentParameterLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                currentCall?[name] = value
            }
            currentParameterName = nil
            currentParameterLines.removeAll(keepingCapacity: true)
        }

        func finalizeCall() {
            finalizeParameter()
            guard let call = currentCall, !call.isEmpty else {
                currentCall = nil
                return
            }
            calls.append(call)
            currentCall = nil
        }

        for line in lines {
            guard let marker = dsmlMarkerBody(from: line) else {
                if currentParameterName != nil {
                    currentParameterLines.append(line)
                }
                continue
            }

            let lowered = marker.lowercased()
            if lowered.hasPrefix("tool_calls") {
                continue
            }
            if lowered.hasPrefix("invoke") {
                finalizeCall()
                if let name = firstDSMLAttribute(named: "name", in: marker) {
                    currentCall = ["name": name]
                }
                continue
            }
            if lowered.hasPrefix("parameter") {
                finalizeParameter()
                guard currentCall != nil,
                      let name = firstDSMLAttribute(named: "name", in: marker) else {
                    continue
                }
                currentParameterName = name
                if let inlineValue = marker.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first {
                    let text = String(inlineValue).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        currentParameterLines.append(text)
                    }
                }
            }
        }

        finalizeCall()
        return calls
    }

    private static func dsmlMarkerBody(from line: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*<\|\s*\|\s*DSML\s*\|\s*\|\s*(.+?)\s*$"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsLine.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstDSMLAttribute(named name: String, in text: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func parseJSONCalls(_ body: String) -> [[String: Any]] {
        if let object = jsonObject(from: body) as? [String: Any] {
            if let calls = object["calls"] as? [[String: Any]] {
                return calls.map(Self.normalizedNativeCall(_:))
            }
            if let calls = object["tool_calls"] as? [[String: Any]] {
                return calls.flatMap(Self.parseToolCallObject(_:))
            }
            if let calls = object["toolCalls"] as? [[String: Any]] {
                return calls.flatMap(Self.parseToolCallObject(_:))
            }
            if let single = object["iexa_native"] as? [String: Any] {
                return [Self.normalizedNativeCall(single)]
            }
            if let single = object["iexaNative"] as? [String: Any] {
                return [Self.normalizedNativeCall(single)]
            }
            if let single = object["tool_call"] as? [String: Any] {
                return [Self.normalizedNativeCall(single)]
            }
            if let single = object["toolCall"] as? [String: Any] {
                return [Self.normalizedNativeCall(single)]
            }
            if let function = object["function"] as? [String: Any] {
                var merged = function
                for (key, value) in object where merged[key] == nil {
                    merged[key] = value
                }
                return [Self.normalizedNativeCall(merged)]
            }
            return [Self.normalizedNativeCall(object)]
        }
        if let array = jsonObject(from: body) as? [[String: Any]] {
            return array.map(Self.normalizedNativeCall(_:))
        }
        return []
    }

    private static func parseToolCallObject(_ object: [String: Any]) -> [[String: Any]] {
        if let function = object["function"] as? [String: Any] {
            var merged = function
            for (key, value) in object where key != "function" && merged[key] == nil {
                merged[key] = value
            }
            return [Self.normalizedNativeCall(merged)]
        }
        return [Self.normalizedNativeCall(object)]
    }

    private static func stripNativeToolBlocks(from content: String) -> String {
        var withoutNativeFence = content.replacingOccurrences(
            of: #"```iexa_native\s*[\s\S]*?```"#,
            with: "",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"<\s*(?:tool_call|tool_use|function_call|function|iexa_native)\b[^>]*>[\s\S]*?</\s*(?:tool_call|tool_use|function_call|function|iexa_native)\s*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).replacingOccurrences(
            of: #"(?im)^\s*</\s*(?:tool_calls?|tool_use|function_call|function|iexa_native)\s*>\s*$"#,
            with: "",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"(?i)</\s*(?:tool_calls?|tool_use|function_call|function|iexa_native)\s*>"#,
            with: "",
            options: .regularExpression
        )
        for item in looseNativeToolFenceRanges(in: withoutNativeFence).reversed() {
            guard let swiftRange = Range(item.range, in: withoutNativeFence) else { continue }
            withoutNativeFence.removeSubrange(swiftRange)
        }
        for range in plainLineNativeToolRanges(in: withoutNativeFence).reversed() {
            guard let swiftRange = Range(range, in: withoutNativeFence) else { continue }
            withoutNativeFence.removeSubrange(swiftRange)
        }
        let looseBodies = looseNativeToolBodies(in: withoutNativeFence)
        guard !looseBodies.isEmpty else { return withoutNativeFence }
        var stripped = withoutNativeFence
        for body in looseBodies where stripped.trimmingCharacters(in: .whitespacesAndNewlines) == body {
            stripped = ""
        }
        return stripped
    }

    private static func looseNativeToolBodies(
        in content: String,
        excluding excludedRanges: [NSRange] = []
    ) -> [String] {
        var bodies: [String] = []

        bodies.append(contentsOf: looseNativeToolFenceRanges(in: content, excluding: excludedRanges).map { $0.body })

        bodies.append(contentsOf: taggedNativeToolBodies(in: content))

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if bodyLooksLikeNativeToolJSON(trimmed) {
            bodies.append(trimmed)
        }

        var seen: Set<String> = []
        return bodies.filter { body in
            guard !seen.contains(body) else { return false }
            seen.insert(body)
            return true
        }
    }

    private static func looseNativeToolFenceRanges(
        in content: String,
        excluding excludedRanges: [NSRange] = []
    ) -> [(range: NSRange, body: String)] {
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#, options: [.caseInsensitive]) else {
            return []
        }
        return regex.matches(in: content, range: fullRange).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
                return nil
            }
            let info = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard info == "json" || info == "javascript" || info == "js" || info.isEmpty else {
                return nil
            }
            let body = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard bodyLooksLikeNativeToolJSON(body) else { return nil }
            return (match.range, body)
        }
    }

    private static func plainLineNativeToolCalls(
        in content: String,
        excluding excludedRanges: [NSRange] = []
    ) -> [[String: Any]] {
        plainLineNativeToolMatches(in: content, excluding: excludedRanges).compactMap { match in
            plainLineNativeToolCall(
                rawName: match.rawName,
                body: match.body
            )
        }
    }

    private static func plainLineNativeToolRanges(in content: String) -> [NSRange] {
        plainLineNativeToolMatches(in: content).compactMap { match in
            guard plainLineNativeToolCall(rawName: match.rawName, body: match.body) != nil else {
                return nil
            }
            return match.range
        }
    }

    private static func plainLineNativeToolMatches(
        in content: String,
        excluding excludedRanges: [NSRange] = []
    ) -> [(range: NSRange, rawName: String?, body: String)] {
        let pattern = #"<\s*(?:tool_call|tool_use|function_call|function|iexa_native)\b[^>]*>\s*([A-Za-z0-9_.-]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: content, range: fullRange)
        guard !matches.isEmpty else { return [] }

        var results: [(range: NSRange, rawName: String?, body: String)] = []
        for (index, match) in matches.enumerated() {
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
                continue
            }
            let bodyStart = match.range.location + match.range.length
            let nextStart = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let rawBodyRange = NSRange(location: bodyStart, length: max(0, nextStart - bodyStart))
            var body = ns.substring(with: rawBodyRange)
            if let closing = body.range(of: #"</\s*(?:tool_call|tool_use|function_call|function|iexa_native)\s*>"#, options: [.regularExpression, .caseInsensitive]) {
                body = String(body[..<closing.lowerBound])
            }
            let rawName: String?
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                let name = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                rawName = name.isEmpty ? nil : name
            } else {
                rawName = nil
            }
            let end = rawBodyRange.location + rawBodyRange.length
            let range = NSRange(location: match.range.location, length: max(0, end - match.range.location))
            results.append((range, rawName, body))
        }
        return results
    }

    private static func plainLineNativeToolCall(rawName: String?, body: String) -> [String: Any]? {
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("</") && !$0.hasPrefix("```") }
        guard rawName?.isEmpty == false || !lines.isEmpty else { return nil }

        var remaining = lines
        var toolName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if toolName == nil, let first = remaining.first,
           isSupportedNativeAction(first) {
            toolName = first
            remaining.removeFirst()
        }

        var parsed: [String: Any] = [:]
        var index = 0
        while index < remaining.count {
            let line = remaining[index]
            if let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                let key = String(line[..<separator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !value.isEmpty {
                    parsed[key] = scalarNativeToolValue(value)
                }
                index += 1
                continue
            }
            guard index + 1 < remaining.count else { break }
            let key = line
            let value = remaining[index + 1]
            parsed[key] = scalarNativeToolValue(value)
            index += 2
        }

        if let toolName, !toolName.isEmpty {
            let normalizedTool = normalizedActionName(toolName)
            if normalizedTool == "browser_use" || normalizedTool == "browser.use" {
                if let browserAction = parsed["action"] {
                    parsed["browser_use_action"] = browserAction
                }
                parsed["action"] = "browser_use"
            } else {
                parsed["action"] = normalizedTool
            }
        }

        let normalized = normalizedNativeCall(parsed)
        return isSupportedNativeCall(normalized) ? normalized : nil
    }

    private static func scalarNativeToolValue(_ value: String) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if ["true", "yes", "on"].contains(lower) { return true }
        if ["false", "no", "off"].contains(lower) { return false }
        if let int = Int(trimmed) { return int }
        if let double = Double(trimmed), trimmed.contains(".") { return double }
        return trimmed
    }

    private static func taggedNativeToolBodies(in content: String) -> [String] {
        let pattern = #"<\s*(?:tool_call|tool_use|function_call|function|iexa_native)\b[^>]*>([\s\S]*?)</\s*(?:tool_call|tool_use|function_call|function|iexa_native)\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        var seen: Set<String> = []
        return matches.compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            let body = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard bodyLooksLikeNativeToolJSON(body), !seen.contains(body) else { return nil }
            seen.insert(body)
            return body
        }
    }

    private static func bodyLooksLikeNativeToolJSON(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        guard let object = jsonObject(from: trimmed) else {
            return false
        }
        return objectContainsSupportedNativeTool(object)
    }

    private static func objectContainsSupportedNativeTool(_ object: Any) -> Bool {
        if let array = object as? [Any] {
            return array.contains { objectContainsSupportedNativeTool($0) }
        }
        guard let dictionary = object as? [String: Any] else { return false }
        if let calls = dictionary["calls"] as? [Any], objectContainsSupportedNativeTool(calls) {
            return true
        }
        if let calls = dictionary["tool_calls"] as? [Any], objectContainsSupportedNativeTool(calls) {
            return true
        }
        if let calls = dictionary["toolCalls"] as? [Any], objectContainsSupportedNativeTool(calls) {
            return true
        }
        for key in ["iexa_native", "iexaNative", "tool_call", "toolCall", "function"] {
            if let value = dictionary[key], objectContainsSupportedNativeTool(value) {
                return true
            }
        }
        return isSupportedNativeCall(normalizedNativeCall(dictionary))
    }

    private static func normalizedNativeCall(_ call: [String: Any]) -> [String: Any] {
        var normalized = call
        let wrapperName = firstString(in: normalized, keys: ["name", "tool", "functionName", "function_name", "toolName", "tool_name"])
            .map(normalizedActionName(_:))
        let isBrowserUseWrapper = wrapperName == "browser_use"

        if let arguments = firstDictionary(in: normalized, keys: ["arguments", "args", "parameters", "params", "input"]) {
            for (key, value) in arguments where normalized[key] == nil {
                if isBrowserUseWrapper && key == "action" {
                    normalized["browser_use_action"] = value
                    continue
                }
                normalized[key] = value
            }
        }
        if isBrowserUseWrapper {
            normalized["action"] = "browser_use"
        } else if let rawName = firstString(in: normalized, keys: ["action", "name", "tool", "functionName", "function_name", "toolName", "tool_name"]) {
            normalized["action"] = normalizedActionName(rawName)
        }
        if normalized["action"] as? String == "browser_use",
           normalized["browser_use_action"] == nil,
           let rawBrowserAction = firstString(in: normalized, keys: ["browser_action", "operation", "op"]) {
            normalized["browser_use_action"] = rawBrowserAction
        }
        return normalized
    }

    private static func normalizedActionName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased() {
        case "image_generation", "image.generate", "image_generate", "generate_image":
            return "image_generation"
        case "memory.write", "memory_write":
            return "memory_write"
        case "memory.get", "memory_get":
            return "memory_get"
        case "web.search", "web_search", "search_web", "browser.search", "browser_search":
            return "web.search"
        case "browser.readable", "browser_readable", "browser.get_readable", "browser_get_readable", "get_readable":
            return "browser.readable"
        case "browser.use", "browser_use":
            return "browser_use"
        case "browser.observe", "browser_observe", "browser.get_state", "browser_get_state", "observe", "get_state":
            return "browser.observe"
        case "browser.wait_for_image", "browser_wait_for_image", "wait_for_image", "wait_image", "image_result":
            return "browser.wait_for_image"
        case "get_location", "location.get", "location_get", "ios.location", "ios_location", "device.location", "device_location":
            return "get_location"
        case "update_calendar_event", "calendar.update_event":
            return "calendar.update_event"
        case "calendar.free_busy", "calendar.freebusy", "calendar.availability":
            return "calendar.free_busy"
        case "list_calendars", "calendar.list_calendars":
            return "calendar.list_calendars"
        case "contacts.list", "contacts_list", "list_contacts":
            return "contacts.list"
        case "contacts.search", "contacts_search", "search_contacts":
            return "contacts.search"
        case "contacts.get", "contacts_get", "get_contact":
            return "contacts.get"
        case "shortcuts.run", "shortcut.run", "shortcuts_run", "run_shortcut":
            return "shortcuts.run"
        case "shortcuts.open", "shortcut.open", "shortcuts_open", "open_shortcut":
            return "shortcuts.open"
        case "shortcuts.create", "shortcut.create", "shortcuts_create", "create_shortcut":
            return "shortcuts.create"
        case "office.create_excel", "office_create_excel", "create_excel", "excel.create", "excel":
            return "office.create_excel"
        case "office.create_ppt", "office.create_powerpoint", "office_create_ppt", "create_ppt", "create_powerpoint", "ppt.create", "powerpoint.create", "ppt":
            return "office.create_ppt"
        case "office.create_word", "office.create_docx", "office_create_word", "create_word", "create_docx", "word.create", "docx.create", "word", "docx":
            return "office.create_word"
        case "office.create_pdf", "office_create_pdf", "create_pdf", "pdf.create", "pdf":
            return "office.create_pdf"
        case "office.delete", "office_delete", "delete_office", "office.remove", "office_remove", "delete_office_document", "remove_office_document", "delete_document", "remove_document":
            return "office.delete"
        default:
            return raw
        }
    }

    static func isSupportedNativeAction(_ raw: String) -> Bool {
        isSupportedNativeCall(["action": normalizedActionName(raw)])
    }

    private static func isSupportedNativeCall(_ call: [String: Any]) -> Bool {
        let action = (call["action"] as? String ?? call["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return false }
        switch action {
        case "image_generation", "memory_write", "memory_get",
             "get_location", "location.get", "location_get", "ios.location", "ios_location", "device.location", "device_location",
             "get_weather", "weather.get",
             "list_calendar_events", "calendar.list_events",
             "create_calendar_event", "calendar.create_event",
             "delete_calendar_event", "calendar.delete_event",
             "update_calendar_event", "calendar.update_event",
             "calendar.free_busy", "calendar.freebusy", "calendar.availability",
             "list_calendars", "calendar.list_calendars",
             "contacts.list", "contacts_list", "list_contacts",
             "contacts.search", "contacts_search", "search_contacts",
             "contacts.get", "contacts_get", "get_contact",
             "device.status", "device_status", "get_device_status",
             "device.info", "device_info", "get_device_info",
             "clipboard.read", "clipboard_read", "read_clipboard",
             "clipboard.write", "clipboard_write", "write_clipboard",
             "system.notify", "system_notify", "notify", "show_notification",
             "web.search", "web_search", "search_web", "browser.search", "browser_search",
             "browser.use", "browser_use",
             "browser.open", "browser_open", "browser.navigate", "browser.navigate_url", "navigate",
             "browser.readable", "browser_readable", "browser.get_readable", "get_readable", "read_webpage",
             "browser.text", "browser_text", "browser.get_text", "get_text",
             "browser.info", "browser_info", "browser.get_page_info", "get_page_info",
             "browser.observe", "browser_observe", "browser.get_state", "browser_get_state", "observe", "get_state",
             "browser.screenshot", "browser_screenshot", "screenshot",
             "browser.fetch", "browser_fetch", "fetch",
             "browser.click", "browser_click", "click",
             "browser.type", "browser_type", "type",
             "browser.hover", "browser_hover", "hover",
             "browser.scroll", "browser_scroll", "scroll",
             "browser.scroll_and_collect", "browser_scroll_and_collect", "scroll_and_collect",
             "browser.find_elements", "browser_find_elements", "find_elements",
             "browser.get_backbone", "browser_get_backbone", "get_backbone",
             "browser.execute_js", "browser_execute_js", "execute_js", "eval_js",
             "browser.set_viewport", "browser_set_viewport", "set_viewport",
             "browser.set_user_agent", "browser_set_user_agent", "set_user_agent",
             "browser.get_cookies", "browser_get_cookies", "get_cookies",
             "browser.wait_for_dom_stable", "browser_wait_for_dom_stable", "wait_for_dom_stable",
             "browser.wait_for_image", "browser_wait_for_image", "wait_for_image", "wait_image", "image_result",
             "browser.new_tab", "browser_new_tab", "new_tab",
             "browser.close_tab", "browser_close_tab", "close_tab",
             "browser.list_tabs", "browser_list_tabs", "list_tabs",
             "shortcuts.run", "shortcut.run", "shortcuts_run", "run_shortcut",
             "shortcuts.open", "shortcut.open", "shortcuts_open", "open_shortcut",
             "shortcuts.edit", "shortcut.edit", "shortcuts_edit", "edit_shortcut",
             "shortcuts.create", "shortcut.create", "shortcuts_create", "create_shortcut",
             "office.create_excel", "office_create_excel", "create_excel", "excel.create", "excel",
             "office.create_ppt", "office.create_powerpoint", "office_create_ppt", "create_ppt", "create_powerpoint", "ppt.create", "powerpoint.create", "ppt",
             "office.create_word", "office.create_docx", "office_create_word", "create_word", "create_docx", "word.create", "docx.create", "word", "docx",
             "office.create_pdf", "office_create_pdf", "create_pdf", "pdf.create", "pdf",
             "office.delete", "office_delete", "delete_office", "office.remove", "office_remove", "delete_office_document", "remove_office_document", "delete_document", "remove_document":
            return true
        default:
            return false
        }
    }

    private static func firstDictionary(in call: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let dictionary = call[key] as? [String: Any] {
                return dictionary
            }
            if let string = call[key] as? String,
               let data = string.data(using: .utf8),
               let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }

    private static func jsonObject(from body: String) -> Any? {
        let candidates = [
            body,
            repairedLooseJSONString(body)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

        for candidate in candidates where !candidate.isEmpty {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            return object
        }
        return nil
    }

    private static func repairedLooseJSONString(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        var repaired = trimmed.replacingOccurrences(of: "'", with: "\"")
        repaired = regexReplace(
            in: repaired,
            pattern: #"([\{\[,]\s*)([A-Za-z_][A-Za-z0-9_\.\-]*)\s*:"#,
            replacement: #"$1"$2":"#
        )
        repaired = regexReplace(
            in: repaired,
            pattern: #"("(?:action|name|tool|path|file|file_path|cwd|command|cmd|old|new|old_text|new_text|content|text|url|href|link|query|keywords|selector|label|field_label|fieldLabel|button_text|buttonText|aria_label|ariaLabel|placeholder|target|browser_use_action|browser_action|operation|op|functionName|function_name|toolName|tool_name)"\s*:\s*)(?!["\{\[])([^,\}\n]+)(\s*[,}])"#,
            replacement: #"$1"$2"$3"#
        )
        return repaired == trimmed ? nil : repaired
    }

    private static func regexReplace(
        in text: String,
        pattern: String,
        replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    private func calendarEventPayload(_ event: CalendarEvent) -> [String: Any] {
        var payload: [String: Any] = [
            "id": event.id,
            "calendar_id": event.calendarId,
            "title": event.title,
            "start": isoString(event.startAt),
            "all_day": event.allDay
        ]
        if let end = event.endAt { payload["end"] = isoString(end) }
        if let description = event.description { payload["description"] = description }
        if let location = event.location { payload["location"] = location }
        if let alertMinutes = event.meta?.alertMinutes { payload["alert_minutes"] = alertMinutes }
        return payload
    }

    private func contactPayload(_ contact: LocalContact) -> [String: Any] {
        var payload: [String: Any] = [
            "id": contact.id,
            "display_name": contact.displayName,
            "given_name": contact.givenName,
            "family_name": contact.familyName,
            "phone_numbers": contact.phoneNumbers.map { ["label": $0.label, "value": $0.value] },
            "email_addresses": contact.emailAddresses.map { ["label": $0.label, "value": $0.value] }
        ]
        if let organizationName = contact.organizationName {
            payload["organization"] = organizationName
        }
        return payload
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let date = Self.isoFormatter.date(from: trimmed) {
            return date
        }
        if let date = Self.isoNoFractionFormatter.date(from: trimmed) {
            return date
        }
        if let date = Self.looseDateTimeFormatter.date(from: trimmed) {
            return date
        }
        if let date = Self.looseDateFormatter.date(from: trimmed) {
            return Calendar.current.startOfDay(for: date)
        }
        return nil
    }

    private static func integerValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private func isoString(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    private func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(object)"
        }
        return string
    }

    private func roundOne(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func applicationStateString(_ state: UIApplication.State) -> String {
        switch state {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .unplugged:
            return "unplugged"
        case .charging:
            return "charging"
        case .full:
            return "full"
        @unknown default:
            return "unknown"
        }
    }

    private func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoNoFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let looseDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let looseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
