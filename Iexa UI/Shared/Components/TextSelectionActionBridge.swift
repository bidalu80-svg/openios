import Foundation

enum TextSelectionAction: String {
    case ask
    case lookUp
    case searchWeb
    case translate
    case share
}

extension Notification.Name {
    static let textSelectionActionRequested = Notification.Name("com.openui.textSelection.actionRequested")
}

enum TextSelectionActionBridge {
    static func post(_ action: TextSelectionAction, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        NotificationCenter.default.post(
            name: .textSelectionActionRequested,
            object: nil,
            userInfo: [
                "action": action.rawValue,
                "text": trimmed
            ]
        )
    }
}
