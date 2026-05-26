import Foundation

enum LocalAlpineAgentExecutionStatus: String, Codable, Sendable {
    case idle
    case planning
    case running
    case waitingForConfirmation
    case finished
    case failed
    case stuck
}

enum LocalAlpineAgentRiskLevel: String, Codable, Sendable {
    case low
    case medium
    case high

    var requiresConfirmation: Bool {
        self == .high
    }
}

enum LocalAlpineAgentActionKind: String, Codable, CaseIterable, Sendable {
    case listDir = "list_dir"
    case readFile = "read_file"
    case writeFiles = "write_files"
    case editFile = "edit_file"
    case patchFile = "patch_file"
    case deleteFile = "delete_file"
    case glob
    case grep
    case installDependency = "install_dependency"
    case compile
    case test
    case runScript = "run_script"
    case verify
    case command
    case finish
    case askUser = "ask_user"
}

struct LocalAlpineAgentAction: Identifiable, Codable, Sendable {
    let id: String
    let kind: LocalAlpineAgentActionKind
    let summary: String
    let risk: LocalAlpineAgentRiskLevel
    let payloadPreview: String?

    init(
        id: String = UUID().uuidString,
        kind: LocalAlpineAgentActionKind,
        summary: String,
        risk: LocalAlpineAgentRiskLevel = .low,
        payloadPreview: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.risk = risk
        self.payloadPreview = payloadPreview
    }
}

struct LocalAlpineAgentCommandObservation: Sendable {
    let command: String
    let cwd: String
    let exitCode: String
    let outputPreview: String
}

struct LocalAlpineAgentPlanningState: Sendable {
    let focusPaths: [String]
    let writtenFiles: [String]
    let latestCommand: LocalAlpineAgentCommandObservation?
    let latestObservation: String?
}

struct LocalAlpineAgentObservation: Sendable {
    let didExecute: Bool
    let hadFailure: Bool
    let needsUserInput: Bool
    let summaryPreview: String
    let writtenFiles: [String]
    let latestCommand: LocalAlpineAgentCommandObservation?
    let executedCommandCount: Int
    let editedFileCount: Int
}

struct LocalAlpineAgentDecision: Sendable {
    enum Kind: Sendable {
        case finish
        case continuePlanning
        case askUser
        case stopForConfirmation
        case stuck
    }

    let kind: Kind
    let reason: String
}

struct LocalAlpineAgentPlan: Sendable {
    let rawContent: String
    let executableContent: String
    let risk: LocalAlpineAgentRiskLevel
    let visibleContent: String
}

struct LocalAlpineAgentClarification: Sendable {
    let rawContent: String
    let question: String
}

struct LocalAlpineAgentSimulationCase: Sendable {
    let userText: String
    let rawPlan: String
    let shouldProduceExecutablePlan: Bool
}

struct LocalAlpineAgentSimulationResult: Sendable {
    let userText: String
    let producedExecutablePlan: Bool
    let risk: LocalAlpineAgentRiskLevel?
    let passed: Bool
}

enum LocalAlpineAgentCore {
    private static let workspace = "/mnt/iexa"
    private static let maxObservationCharacters = 1_200
    private static let maxRuntimeLines = 8

    static func planningMessages(
        userText: String,
        state: LocalAlpineAgentPlanningState,
        runtimeCapabilities: String?
    ) -> [[String: Any]] {
        let user = """
        \(renderState(state))

        User task:
        \(userText)
        """
        return [
            ["role": "system", "content": systemContext(runtimeCapabilities: runtimeCapabilities)],
            ["role": "user", "content": user]
        ]
    }

    static func configurePlanningRequest(_ request: inout ChatCompletionRequest) {
        configurePlanningRequest(&request, requireStructuredOutput: true)
    }

    static func configurePlanningRequest(
        _ request: inout ChatCompletionRequest,
        requireStructuredOutput: Bool
    ) {
        request.chatId = nil
        request.sessionId = nil
        request.messageId = nil
        request.parentId = nil
        request.userMessage = nil
        request.files = nil
        request.skillIds = nil
        request.filterIds = nil
        request.toolIds = []
        request.toolServers = []
        request.terminalId = nil
        request.backgroundTasks = [:]
        request.variables = [:]
        request.features = ChatCompletionRequest.ChatFeatures()
        request.streamOptions = ["include_usage": true]

        var params = request.params ?? [:]
        for key in [
            "system", "tools", "tool_choice", "functions", "function_call", "function_calling",
            "response_format", "text", "format"
        ] {
            params.removeValue(forKey: key)
        }
        if requireStructuredOutput {
            params["response_format"] = ["type": "json_object"]
        }
        request.params = params.isEmpty ? nil : params
    }

    static func executableContent(
        from rawPlan: String,
        normalizeContent: (String) -> String?,
        commandObjectsFromJSON: (Any) -> [Any],
        fenceJSONObject: (Any) -> String?
    ) -> String? {
        if let normalized = normalizeContent(rawPlan) {
            return normalized
        }

        for fragment in jsonFragments(in: rawPlan) {
            guard let data = fragment.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            let commandObjects = commandObjectsFromJSON(object)
            if let executable = executableContent(
                fromCommandObjects: commandObjects,
                fenceJSONObject: fenceJSONObject
            ) {
                return executable
            }
        }
        return nil
    }

    static func plan(
        from rawPlan: String,
        normalizeContent: (String) -> String?,
        commandObjectsFromJSON: (Any) -> [Any],
        fenceJSONObject: (Any) -> String?,
        preview: (String) -> String
    ) -> LocalAlpineAgentPlan? {
        let trimmed = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executableContent = executableContent(
            from: trimmed,
            normalizeContent: normalizeContent,
            commandObjectsFromJSON: commandObjectsFromJSON,
            fenceJSONObject: fenceJSONObject
        ) else {
            return nil
        }

        return LocalAlpineAgentPlan(
            rawContent: trimmed,
            executableContent: executableContent,
            risk: risk(in: executableContent),
            visibleContent: visiblePlanContent(from: executableContent, preview: preview)
        )
    }

    static func clarificationQuestion(from rawPlan: String) -> LocalAlpineAgentClarification? {
        let trimmed = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        for fragment in jsonFragments(in: trimmed) {
            guard let data = fragment.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let rawQuestion = question(from: object) else {
                continue
            }
            let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else {
                continue
            }
            return LocalAlpineAgentClarification(rawContent: trimmed, question: question)
        }
        return nil
    }

    static func risk(in executableContent: String) -> LocalAlpineAgentRiskLevel {
        let lower = executableContent.lowercased()
        let highRiskStructuredKeys = [
            "\"delete_file\"", "\"delete_files\"", "\"remove_file\"", "\"remove_files\""
        ]
        if highRiskStructuredKeys.contains(where: { lower.contains($0) }) {
            return .high
        }

        let highRiskShellPatterns = [
            #"(?m)(^|[;&|]\s*)rm\s+(-[^\n]*r|-[^\n]*f)"#,
            #"(?m)(^|[;&|]\s*)mv\s+"#,
            #"(?m)(^|[;&|]\s*)dd\s+"#,
            #"(?m)(^|[;&|]\s*)mkfs\."#,
            #">\s*/dev/"#
        ]
        if highRiskShellPatterns.contains(where: { pattern in
            lower.range(of: pattern, options: .regularExpression) != nil
        }) {
            return .high
        }

        let mediumRiskPatterns = [
            #"(?m)(^|[;&|]\s*)chmod\s+(-r\s+)?777"#,
            #"(?m)(^|[;&|]\s*)chown\s+(-r\s+)?"#,
            #"(?m)(^|[;&|]\s*)apk\s+del\s+"#
        ]
        if mediumRiskPatterns.contains(where: { pattern in
            lower.range(of: pattern, options: .regularExpression) != nil
        }) {
            return .medium
        }

        return .low
    }

    static func visiblePlanContent(
        from executableContent: String,
        preview: (String) -> String
    ) -> String {
        let text = preview(executableContent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "已生成本地执行计划，开始执行。"
        }
        return "已生成本地执行计划：\(text)"
    }

    static func observation(from result: LocalAlpineAgentResult) -> LocalAlpineAgentObservation {
        let latestCommand = result.commandResults.last.map {
            LocalAlpineAgentCommandObservation(
                command: $0.command,
                cwd: $0.cwd,
                exitCode: $0.exitCode.map(String.init) ?? "unknown",
                outputPreview: clip($0.outputPreview, maxCharacters: maxObservationCharacters)
            )
        }

        return LocalAlpineAgentObservation(
            didExecute: result.didExecute,
            hadFailure: result.hadFailure || result.commandResults.contains { $0.failed },
            needsUserInput: result.interactiveRequest != nil,
            summaryPreview: clip(result.summary, maxCharacters: maxObservationCharacters),
            writtenFiles: result.writtenFiles.map(\.path),
            latestCommand: latestCommand,
            executedCommandCount: result.executedCommandCount,
            editedFileCount: result.editedFileCount
        )
    }

    static func decision(
        after observation: LocalAlpineAgentObservation,
        stepCount: Int,
        maxSteps: Int
    ) -> LocalAlpineAgentDecision {
        if observation.needsUserInput {
            return LocalAlpineAgentDecision(kind: .askUser, reason: "tool requested user input")
        }
        if stepCount >= maxSteps {
            return LocalAlpineAgentDecision(kind: .stuck, reason: "max local agent steps reached")
        }
        if observation.hadFailure {
            return LocalAlpineAgentDecision(kind: .continuePlanning, reason: "latest tool observation failed")
        }
        return LocalAlpineAgentDecision(kind: .finish, reason: "latest tool observation completed")
    }

    static func simulatePlanning(
        cases: [LocalAlpineAgentSimulationCase],
        normalizeContent: (String) -> String?,
        commandObjectsFromJSON: (Any) -> [Any],
        fenceJSONObject: (Any) -> String?,
        preview: (String) -> String
    ) -> [LocalAlpineAgentSimulationResult] {
        cases.map { testCase in
            let plan = plan(
                from: testCase.rawPlan,
                normalizeContent: normalizeContent,
                commandObjectsFromJSON: commandObjectsFromJSON,
                fenceJSONObject: fenceJSONObject,
                preview: preview
            )
            let produced = plan != nil
            return LocalAlpineAgentSimulationResult(
                userText: testCase.userText,
                producedExecutablePlan: produced,
                risk: plan?.risk,
                passed: produced == testCase.shouldProduceExecutablePlan
            )
        }
    }

    private static func systemContext(runtimeCapabilities: String?) -> String {
        let runtime = runtimeCapabilities?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maxRuntimeLines)
            .map(String.init)
            .joined(separator: "\n") ?? ""
        let runtimeBlock = runtime.isEmpty ? "" : "\nRuntime:\n\(runtime)"
        let actions = LocalAlpineAgentActionKind.allCases
            .filter { $0 != .finish && $0 != .askUser }
            .map(\.rawValue)
            .joined(separator: ", ")

        return """
        You are Iexa Local Alpine agent core. Decide the next local action for the user's task.
        Return only one JSON object. Do not wrap it in Markdown.

        JSON shape: {"iexa_alpine":[ACTION,...]}.
        Allowed ACTION keys: \(actions).
        Workspace: \(workspace).

        Rules:
        - Act on natural-language local tasks; do not answer with a future promise when a tool action is possible.
        - Use state paths for follow-ups such as this, it, current, above, 上面, 这个.
        - For code creation, write complete file content with `code_lines`.
        - If the user asks to run, check, test, compile, or see output, include the verification step in the same plan.
        - For missing compilers or runtimes, check first and install with apk only when needed.
        - If an operation is destructive or the path is unclear, return {"ask_user":"one concise question"}.
        \(runtimeBlock)
        """
    }

    private static func renderState(_ state: LocalAlpineAgentPlanningState) -> String {
        var lines = [
            "[Local Alpine state]",
            "workspace: \(workspace)"
        ]
        if !state.focusPaths.isEmpty {
            lines.append("current_focus_paths:")
            lines.append(contentsOf: state.focusPaths.map { "- \($0)" })
        }
        if !state.writtenFiles.isEmpty {
            lines.append("recent_written_files:")
            lines.append(contentsOf: state.writtenFiles.map { "- \($0)" })
        }
        if let command = state.latestCommand {
            lines.append("latest_command:")
            lines.append(indent("""
            command: \(command.command)
            cwd: \(command.cwd)
            exit_code: \(command.exitCode)
            output:
            \(clip(command.outputPreview, maxCharacters: maxObservationCharacters))
            """))
        } else if let rawObservation = state.latestObservation {
            let observation = rawObservation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !observation.isEmpty {
                lines.append("latest_observation:")
                lines.append(indent(clip(observation, maxCharacters: maxObservationCharacters)))
            }
        }
        lines.append("[/Local Alpine state]")
        return lines.joined(separator: "\n")
    }

    private static func jsonFragments(in text: String) -> [String] {
        var fragments: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            fragments.append(trimmed)
        }
        let pattern = #"```(?:json|iexa_alpine)?\s*\n([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges >= 2 {
                fragments.append(nsText.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return fragments
    }

    private static func executableContent(
        fromCommandObjects commands: [Any],
        fenceJSONObject: (Any) -> String?
    ) -> String? {
        let filtered = commands.filter { command in
            if let string = command as? String {
                return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return JSONSerialization.isValidJSONObject(["value": command])
        }
        guard !filtered.isEmpty else { return nil }
        return fenceJSONObject(["iexa_alpine": filtered])
    }

    private static func question(from object: Any) -> String? {
        if let string = object as? String {
            return string
        }
        if let dict = object as? [String: Any] {
            for key in ["ask_user", "question", "clarification"] {
                if let value = dict[key] {
                    return question(from: value)
                }
            }
            if !hasExecutablePlanKey(dict), let value = dict["message"] {
                return question(from: value)
            }
        }
        return nil
    }

    private static func hasExecutablePlanKey(_ dict: [String: Any]) -> Bool {
        let executableKeys = [
            "iexa_alpine", "commands", "steps", "actions", "plan",
            "tool_calls", "toolCalls", "tool_uses", "toolUses",
            "command", "cmd", "shell", "list_dir", "read_file", "read_files",
            "write_file", "write_files", "edit_file", "edit_files",
            "patch_file", "patch_files", "delete_file", "delete_files",
            "glob", "grep", "verify", "run_script", "run_program",
            "compile", "build", "test", "run_tests", "install_dependency",
            "install_dependencies", "install"
        ]
        return executableKeys.contains { dict[$0] != nil }
    }

    private static func clip(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n...truncated"
    }

    private static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
