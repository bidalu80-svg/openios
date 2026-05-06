import Foundation

// MARK: - Reference Chat Item

/// 表示可以作为上下文附加到新消息里的聊天记录。
///
/// 当用户从“引用聊天”选择器（通过 `+` 菜单）选择对话时，
/// 选中的聊天会在输入框里显示为标签，并加入聊天请求的 `files` 数组。
struct ReferenceChatItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let createdAt: Date

    /// A human-readable relative time string, e.g. "24 分钟前".
    var relativeTime: String {
        let now = Date()
        let diff = now.timeIntervalSince(updatedAt)
        if diff < 60 {
            return "刚刚"
        } else if diff < 3600 {
            let mins = Int(diff / 60)
            return "\(mins) 分钟前"
        } else if diff < 86400 {
            let hours = Int(diff / 3600)
            return "\(hours) 小时前"
        } else {
            let days = Int(diff / 86400)
            return "\(days) 天前"
        }
    }

    /// The time-range bucket label shown in the picker.
    var timeRange: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(updatedAt) {
            return "今天"
        } else if calendar.isDateInYesterday(updatedAt) {
            return "昨天"
        } else if let daysAgo = calendar.dateComponents([.day], from: updatedAt, to: Date()).day {
            if daysAgo <= 7 {
                return "过去 7 天"
            } else if daysAgo <= 30 {
                return "过去 30 天"
            }
        }
        return "更早"
    }

    /// Converts this item to the `files` array entry format expected by
    /// the `/api/chat/completions` endpoint, matching the Iexa native server web client format.
    func toChatFileRef() -> [String: Any] {
        return [
            "type": "chat",
            "id": id,
            "name": title,
            "title": title,
            "description": relativeTime,
            "status": "processed",
            "updated_at": Int(updatedAt.timeIntervalSince1970),
            "created_at": Int(createdAt.timeIntervalSince1970)
        ]
    }
}
