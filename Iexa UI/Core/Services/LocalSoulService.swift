import Foundation

struct LocalSoulProfile: Codable, Hashable, Sendable {
    var name: String
    var content: String
    var isEnabled: Bool
    var updatedAt: Date

    init(
        name: String = "SOUL",
        content: String = "",
        isEnabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.content = content
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

@MainActor
@Observable
final class LocalSoulService {
    static let shared = LocalSoulService()

    private let storageKey = "iexa.local.soul.profile.v1"
    private(set) var profile = LocalSoulProfile()

    private init() {
        load()
    }

    var hasContent: Bool {
        !profile.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var statusText: String {
        guard hasContent else { return "未设置" }
        return profile.isEnabled ? "已启用" : "已关闭"
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(LocalSoulProfile.self, from: data) else {
            profile = LocalSoulProfile()
            return
        }
        profile = decoded
    }

    func setEnabled(_ enabled: Bool) {
        profile.isEnabled = enabled
        profile.updatedAt = Date()
        save()
    }

    func update(name: String? = nil, content: String? = nil) {
        if let name {
            profile.name = name
        }
        if let content {
            profile.content = content
        }
        profile.updatedAt = Date()
        save()
    }

    func importMarkdown(_ markdown: String, fallbackName: String = "SOUL") {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let inferredName = Self.firstMarkdownHeading(in: trimmed) ?? fallbackName
        profile = LocalSoulProfile(
            name: inferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "SOUL" : inferredName,
            content: trimmed,
            isEnabled: true,
            updatedAt: Date()
        )
        save()
    }

    func reset() {
        profile = LocalSoulProfile()
        save()
    }

    func markdownDocument() -> String {
        let title = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "SOUL"
            : profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = profile.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "# \(title)\n" }
        if body.hasPrefix("#") {
            return body
        }
        return "# \(title)\n\n\(body)\n"
    }

    func contextPrompt() -> String? {
        guard profile.isEnabled else { return nil }
        let content = profile.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "SOUL" : name
        return """

        [SOUL]
        以下是用户在 Iexa 本地配置的长期人设文件。它用于稳定你的身份、语气、偏好和边界；它不依赖服务器，也不代表临时用户消息。请在不违背用户当前请求和安全规则的前提下遵循。

        # \(title)
        \(content)
        [/SOUL]
        """
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func firstMarkdownHeading(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }
}
