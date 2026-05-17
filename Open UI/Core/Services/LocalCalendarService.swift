import EventKit
import Foundation
import UIKit

enum LocalCalendarError: LocalizedError {
    case accessDenied
    case noWritableCalendar
    case eventNotFound

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "需要日历权限才能读取和创建本地日历事件。"
        case .noWritableCalendar:
            return "没有可写入的本地日历。"
        case .eventNotFound:
            return "找不到这个本地日历事件。"
        }
    }
}

@MainActor
final class LocalCalendarService {
    static let shared = LocalCalendarService()

    private let eventStore = EKEventStore()
    private let appCalendarIdKey = "iexa.local.eventkit.calendar.id"

    private init() {}

    func loadCalendars() async throws -> [OWCalendar] {
        try await ensureFullAccess()
        if writableCalendars().isEmpty {
            _ = try createAppCalendar()
        }

        return eventStore.calendars(for: .event)
            .sorted { lhs, rhs in
                if lhs.allowsContentModifications != rhs.allowsContentModifications {
                    return lhs.allowsContentModifications && !rhs.allowsContentModifications
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map { calendar in
                OWCalendar(
                    id: calendar.calendarIdentifier,
                    userId: "local",
                    name: calendar.title,
                    color: hexString(from: calendar.cgColor),
                    isDefault: calendar.calendarIdentifier == eventStore.defaultCalendarForNewEvents?.calendarIdentifier,
                    isSystem: !calendar.allowsContentModifications
                )
            }
    }

    func loadEvents(start: Date, end: Date) async throws -> [CalendarEvent] {
        try await ensureFullAccess()
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate)
            .map(mapEvent)
            .sorted { $0.startAt < $1.startAt }
    }

    func createEvent(_ request: CalendarEventCreateRequest) async throws -> CalendarEvent {
        try await ensureFullAccess()

        let event = EKEvent(eventStore: eventStore)
        event.calendar = try writableCalendar(id: request.calendarId)
        event.title = request.title
        event.notes = request.description
        event.startDate = date(fromNanoseconds: request.startAt)
        event.endDate = request.endAt.map(date(fromNanoseconds:)) ?? event.startDate.addingTimeInterval(3600)
        event.isAllDay = request.allDay
        event.location = request.location

        if let minutes = request.meta?.alertMinutes {
            event.alarms = [EKAlarm(relativeOffset: -Double(minutes * 60))]
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        return mapEvent(event)
    }

    func deleteEvent(id: String) async throws {
        try await ensureFullAccess()
        guard let event = eventStore.event(withIdentifier: id) else {
            throw LocalCalendarError.eventNotFound
        }
        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func ensureFullAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)

        if #available(iOS 17.0, *) {
            switch status {
            case .fullAccess, .authorized:
                return
            case .notDetermined, .writeOnly:
                let granted = try await requestFullAccessToEvents()
                if granted { return }
                throw LocalCalendarError.accessDenied
            case .denied, .restricted:
                throw LocalCalendarError.accessDenied
            @unknown default:
                throw LocalCalendarError.accessDenied
            }
        } else {
            switch status {
            case .authorized:
                return
            case .notDetermined:
                let granted = try await requestLegacyEventAccess()
                if granted { return }
                throw LocalCalendarError.accessDenied
            case .denied, .restricted:
                throw LocalCalendarError.accessDenied
            @unknown default:
                throw LocalCalendarError.accessDenied
            }
        }
    }

    @available(iOS 17.0, *)
    private func requestFullAccessToEvents() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func requestLegacyEventAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func writableCalendar(id: String) throws -> EKCalendar {
        if let calendar = eventStore.calendar(withIdentifier: id), calendar.allowsContentModifications {
            return calendar
        }
        if let defaultCalendar = eventStore.defaultCalendarForNewEvents, defaultCalendar.allowsContentModifications {
            return defaultCalendar
        }
        if let firstWritable = writableCalendars().first {
            return firstWritable
        }
        return try createAppCalendar()
    }

    private func writableCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter(\.allowsContentModifications)
    }

    private func createAppCalendar() throws -> EKCalendar {
        if let savedId = UserDefaults.standard.string(forKey: appCalendarIdKey),
           let savedCalendar = eventStore.calendar(withIdentifier: savedId),
           savedCalendar.allowsContentModifications {
            return savedCalendar
        }

        guard let source = bestSource() else {
            throw LocalCalendarError.noWritableCalendar
        }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "Iexa"
        calendar.cgColor = UIColor.systemIndigo.cgColor
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: appCalendarIdKey)
        return calendar
    }

    private func bestSource() -> EKSource? {
        if let defaultSource = eventStore.defaultCalendarForNewEvents?.source {
            return defaultSource
        }
        return eventStore.sources.first(where: { $0.sourceType == .local })
            ?? eventStore.sources.first(where: { $0.sourceType == .calDAV })
            ?? eventStore.sources.first
    }

    private func mapEvent(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarId: event.calendar.calendarIdentifier,
            userId: "local",
            title: event.title ?? "Untitled Event",
            description: event.notes,
            startAt: event.startDate,
            endAt: event.endDate,
            allDay: event.isAllDay,
            rrule: event.recurrenceRules?.map(\.description).joined(separator: "\n"),
            color: hexString(from: event.calendar.cgColor),
            location: event.location,
            isCancelled: false,
            meta: CalendarEventMeta(alertMinutes: alertMinutes(from: event), automationId: nil, runId: nil, chatId: nil, status: nil),
            instanceId: nil
        )
    }

    private func alertMinutes(from event: EKEvent) -> Int? {
        guard let offset = event.alarms?.first?.relativeOffset else { return nil }
        return max(0, Int((-offset / 60).rounded()))
    }

    private func date(fromNanoseconds value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1_000_000_000)
    }

    private func hexString(from cgColor: CGColor) -> String {
        let color = UIColor(cgColor: cgColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#5E5CE6"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}
