import Foundation

enum CalendarDisplayLocalizer {
    static func calendarName(_ calendar: OWCalendar?) -> String {
        guard let calendar else { return "日历" }
        return calendarName(calendar.name)
    }

    static func calendarName(_ name: String) -> String {
        let key = normalized(name)
        if let mapped = calendarNameMap[key] {
            return mapped
        }
        if key.contains("holidays in united states") || key.contains("us holidays") || key.contains("u.s. holidays") {
            return "美国节假日"
        }
        if key.contains("chinese mainland holidays") || key.contains("holidays in china") {
            return "中国大陆节假日"
        }
        return name
    }

    static func eventTitle(_ event: CalendarEvent) -> String {
        eventTitle(event.title)
    }

    static func eventTitle(_ title: String) -> String {
        let key = normalized(title)
        return eventTitleMap[key] ?? title
    }

    static func note(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return phraseMap[normalized(value)] ?? value
    }

    static func location(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return phraseMap[normalized(value)] ?? value
    }

    static func recurrence(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let key = normalized(value)
        if let mapped = phraseMap[key] {
            return mapped
        }
        if key.contains("freq=daily") || key.contains("daily") {
            return "每天"
        }
        if key.contains("freq=weekly") || key.contains("weekly") {
            return "每周"
        }
        if key.contains("freq=monthly") || key.contains("monthly") {
            return "每月"
        }
        if key.contains("freq=yearly") || key.contains("annually") || key.contains("yearly") {
            return "每年"
        }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static let calendarNameMap: [String: String] = [
        "birthdays": "生日",
        "birthday": "生日",
        "calendar": "日历",
        "home": "家庭",
        "work": "工作",
        "personal": "个人",
        "family": "家庭",
        "school": "学校",
        "holidays": "节假日",
        "holidays in united states": "美国节假日",
        "united states holidays": "美国节假日",
        "us holidays": "美国节假日",
        "u.s. holidays": "美国节假日",
        "chinese mainland holidays": "中国大陆节假日",
        "holidays in china": "中国节假日",
        "contacts": "通讯录",
        "siri suggestions": "Siri 建议",
        "found in apps": "App 中找到的事件"
    ]

    private static let phraseMap: [String: String] = [
        "public holiday": "公共假日",
        "federal holiday": "联邦假日",
        "local holiday": "当地节假日",
        "observance": "纪念日",
        "bank holiday": "银行假日",
        "all day": "全天",
        "none": "无",
        "never": "永不"
    ]

    private static let eventTitleMap: [String: String] = [
        "new year's day": "元旦",
        "new year’s day": "元旦",
        "new years day": "元旦",
        "new year's eve": "跨年夜",
        "new year’s eve": "跨年夜",
        "martin luther king jr. day": "马丁·路德·金纪念日",
        "martin luther king, jr. day": "马丁·路德·金纪念日",
        "presidents' day": "总统日",
        "presidents’ day": "总统日",
        "president's day": "总统日",
        "memorial day": "阵亡将士纪念日",
        "juneteenth": "六月节",
        "juneteenth national independence day": "六月节",
        "independence day": "独立日",
        "labor day": "劳动节",
        "columbus day": "哥伦布日",
        "indigenous peoples' day": "原住民日",
        "indigenous peoples’ day": "原住民日",
        "veterans day": "退伍军人节",
        "veterans' day": "退伍军人节",
        "veterans’ day": "退伍军人节",
        "thanksgiving day": "感恩节",
        "thanksgiving": "感恩节",
        "day after thanksgiving": "感恩节翌日",
        "black friday": "黑色星期五",
        "christmas eve": "平安夜",
        "christmas day": "圣诞节",
        "christmas": "圣诞节",
        "valentine's day": "情人节",
        "valentine’s day": "情人节",
        "st. patrick's day": "圣帕特里克节",
        "st. patrick’s day": "圣帕特里克节",
        "easter": "复活节",
        "easter sunday": "复活节",
        "easter monday": "复活节星期一",
        "good friday": "耶稣受难日",
        "mother's day": "母亲节",
        "mother’s day": "母亲节",
        "father's day": "父亲节",
        "father’s day": "父亲节",
        "halloween": "万圣夜",
        "flag day": "国旗日",
        "patriot day": "爱国者日",
        "patriots' day": "爱国者日",
        "patriots’ day": "爱国者日",
        "cinco de mayo": "五月五日节",
        "election day": "选举日",
        "inauguration day": "就职日",
        "washington's birthday": "华盛顿诞辰纪念日",
        "washington’s birthday": "华盛顿诞辰纪念日"
    ]
}
