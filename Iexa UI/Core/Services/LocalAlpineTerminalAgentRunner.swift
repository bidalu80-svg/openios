import Foundation

enum LocalAlpineTerminalAgentToolUse: Sendable {
    case executableContent(String)
    case shellCommand(String)
}

struct LocalAlpineTerminalAgentToolResult: Sendable {
    let toolUse: LocalAlpineTerminalAgentToolUse
    let result: LocalAlpineAgentResult
}

enum LocalAlpineTerminalAgentRunner {
    static func run(
        _ toolUse: LocalAlpineTerminalAgentToolUse,
        persistentSessionKey: String? = nil,
        inputProvider: (@MainActor (LocalAlpineInteractiveRequest) async -> String?)? = nil,
        eventHandler: LocalAlpineToolEventHandler? = nil
    ) async -> LocalAlpineTerminalAgentToolResult {
        let executableContent: String
        switch toolUse {
        case .executableContent(let content):
            executableContent = content
        case .shellCommand(let command):
            executableContent = Self.fencedShellCommand(command)
        }

        let result = await LocalAlpineAgentService.shared.executeBlocks(
            in: executableContent,
            persistentSessionKey: persistentSessionKey,
            inputProvider: inputProvider,
            eventHandler: eventHandler
        )
        return LocalAlpineTerminalAgentToolResult(toolUse: toolUse, result: result)
    }

    private static func fencedShellCommand(_ command: String) -> String {
        """
        ```iexa_alpine
        \(command.trimmingCharacters(in: .whitespacesAndNewlines))
        ```
        """
    }
}
