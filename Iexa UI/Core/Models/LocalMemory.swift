import Foundation

/// A local memory item used when the app is connected directly to model APIs.
struct LocalMemory: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        content: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var dictionary: [String: Any] {
        [
            "id": id,
            "content": content,
            "created_at": createdAt.timeIntervalSince1970,
            "updated_at": updatedAt.timeIntervalSince1970
        ]
    }

    init?(dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String,
              let content = dictionary["content"] as? String else { return nil }
        self.id = id
        self.content = content
        let created = dictionary["created_at"] as? Double ?? Date.now.timeIntervalSince1970
        let updated = dictionary["updated_at"] as? Double ?? created
        self.createdAt = Date(timeIntervalSince1970: created)
        self.updatedAt = Date(timeIntervalSince1970: updated)
    }
}
