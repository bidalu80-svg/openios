import Foundation
import UIKit
import UserNotifications

struct LocalNativeToolRunResult: Sendable {
    let didExecute: Bool
    let summary: String
}

@MainActor
final class LocalNativeToolService {
    static let shared = LocalNativeToolService()

    private init() {}

    func executeBlocks(in content: String) async -> LocalNativeToolRunResult {
        let calls = parseToolCalls(in: content)
        guard !calls.isEmpty else {
            return LocalNativeToolRunResult(didExecute: false, summary: "")
        }

        var results: [[String: Any]] = []
        for call in calls {
            let result = await execute(call)
            results.append(result)
        }

        let payload: [String: Any] = [
            "tool": "iexa_native",
            "results": results
        ]
        return LocalNativeToolRunResult(
            didExecute: true,
            summary: prettyJSON(payload)
        )
    }

    static func visibleContent(from content: String) -> String {
        stripNativeToolBlocks(from: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsNativeToolBlock(_ content: String) -> Bool {
        content.range(of: #"```iexa_native\s*[\s\S]*?```"#, options: .regularExpression) != nil
    }

    private func execute(_ call: [String: Any]) async -> [String: Any] {
        let action = (call["action"] as? String ?? call["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "get_location", "location.get":
            return executeGetLocation()
        case "get_weather", "weather.get":
            return await executeGetWeather()
        case "list_calendar_events", "calendar.list_events":
            return await executeListCalendarEvents(call)
        case "create_calendar_event", "calendar.create_event":
            return await executeCreateCalendarEvent(call)
        case "delete_calendar_event", "calendar.delete_event":
            return await executeDeleteCalendarEvent(call)
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
        default:
            return [
                "action": action.isEmpty ? "unknown" : action,
                "ok": false,
                "error": "Unsupported local native action"
            ]
        }
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

    private func parseToolCalls(in content: String) -> [[String: Any]] {
        let pattern = #"```iexa_native\s*([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        return matches.flatMap { match -> [[String: Any]] in
            guard match.numberOfRanges >= 2 else { return [] }
            let body = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return parseJSONCalls(body)
        }
    }

    private func parseJSONCalls(_ body: String) -> [[String: Any]] {
        guard let data = body.data(using: .utf8) else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let calls = object["calls"] as? [[String: Any]] {
                return calls
            }
            if let single = object["iexa_native"] as? [String: Any] {
                return [single]
            }
            return [object]
        }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    private static func stripNativeToolBlocks(from content: String) -> String {
        content.replacingOccurrences(
            of: #"```iexa_native\s*[\s\S]*?```"#,
            with: "",
            options: .regularExpression
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
