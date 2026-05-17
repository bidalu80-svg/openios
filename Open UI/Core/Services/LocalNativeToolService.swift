import Foundation

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
        case "get_location":
            return executeGetLocation()
        case "list_calendar_events":
            return await executeListCalendarEvents(call)
        case "create_calendar_event":
            return await executeCreateCalendarEvent(call)
        case "delete_calendar_event":
            return await executeDeleteCalendarEvent(call)
        default:
            return [
                "action": action.isEmpty ? "unknown" : action,
                "ok": false,
                "error": "Unsupported local native action"
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
