import Foundation

enum AssistantFeedbackVote: String, Codable, Sendable {
    case liked
    case disliked
}

struct AssistantFeedbackPreference: Codable, Identifiable, Sendable {
    let id: String
    let messageId: String
    let conversationId: String?
    let vote: AssistantFeedbackVote
    let model: String?
    let summary: String
    let createdAt: Date
}

enum AssistantFeedbackPreferenceStore {
    private static let preferencesKey = "assistantFeedbackPreferences.v1"
    private static let voteMapKey = "assistantFeedbackVoteMap.v1"
    private static let maxStoredPreferences = 24
    private static let maxPromptPreferences = 8
    private static let maxSummaryLength = 700

    static func vote(for messageId: String) -> AssistantFeedbackVote? {
        voteMap()[messageId].flatMap(AssistantFeedbackVote.init(rawValue:))
    }

    static func setVote(
        _ vote: AssistantFeedbackVote,
        messageId: String,
        conversationId: String?,
        model: String?,
        content: String
    ) {
        var map = voteMap()
        map[messageId] = vote.rawValue
        saveVoteMap(map)

        let preference = AssistantFeedbackPreference(
            id: messageId,
            messageId: messageId,
            conversationId: conversationId,
            vote: vote,
            model: model,
            summary: summarized(content),
            createdAt: Date()
        )

        var items = preferences().filter { $0.messageId != messageId }
        items.insert(preference, at: 0)
        if items.count > maxStoredPreferences {
            items = Array(items.prefix(maxStoredPreferences))
        }
        savePreferences(items)
    }

    static func systemContext() -> String? {
        let items = Array(preferences().prefix(maxPromptPreferences))
        guard !items.isEmpty else { return nil }

        let lines = items.map { item -> String in
            let label: String
            switch item.vote {
            case .liked:
                label = "Liked"
            case .disliked:
                label = "Disliked"
            }
            let model = item.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelSuffix = (model?.isEmpty == false) ? " [model: \(model!)]" : ""
            return "- \(label)\(modelSuffix): \(item.summary)"
        }

        return """
        User feedback preferences from previous assistant replies. Treat them as guidance for future replies when relevant; do not mention this feedback unless asked.
        \(lines.joined(separator: "\n"))
        """
    }

    private static func summarized(_ content: String) -> String {
        var text = content
        if let detailsRegex = try? NSRegularExpression(
            pattern: #"<details[^>]*>.*?</details>"#,
            options: [.dotMatchesLineSeparators]
        ) {
            text = detailsRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        text = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count > maxSummaryLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxSummaryLength)
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func preferences() -> [AssistantFeedbackPreference] {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let decoded = try? JSONDecoder().decode([AssistantFeedbackPreference].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func savePreferences(_ preferences: [AssistantFeedbackPreference]) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    private static func voteMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: voteMapKey) as? [String: String] ?? [:]
    }

    private static func saveVoteMap(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: voteMapKey)
    }
}
