import Foundation

enum LocalMCPAgentTransport: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case streamableHTTP
    case localAlpineCommand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .streamableHTTP:
            return "HTTP MCP"
        case .localAlpineCommand:
            return "Local Alpine"
        }
    }

    var subtitle: String {
        switch self {
        case .streamableHTTP:
            return "连接本机或局域网 MCP Server"
        case .localAlpineCommand:
            return "记录在 /mnt/iexa 中运行的 MCP 命令"
        }
    }
}

enum LocalMCPAgentStatus: String, Codable, Hashable, Sendable {
    case untested
    case available
    case warning
    case failed

    var label: String {
        switch self {
        case .untested: return "未检测"
        case .available: return "可用"
        case .warning: return "可达"
        case .failed: return "失败"
        }
    }
}

struct LocalMCPAgentConnection: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var description: String
    var transport: LocalMCPAgentTransport
    var endpoint: String
    var command: String
    var headers: [String: String]
    var isEnabled: Bool
    var updatedAt: Date
    var lastCheckedAt: Date?
    var lastStatus: LocalMCPAgentStatus
    var lastMessage: String

    init(
        id: String = UUID().uuidString,
        name: String = "",
        description: String = "",
        transport: LocalMCPAgentTransport = .streamableHTTP,
        endpoint: String = "",
        command: String = "",
        headers: [String: String] = [:],
        isEnabled: Bool = true,
        updatedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        lastStatus: LocalMCPAgentStatus = .untested,
        lastMessage: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.transport = transport
        self.endpoint = endpoint
        self.command = command
        self.headers = headers
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
        self.lastStatus = lastStatus
        self.lastMessage = lastMessage
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch transport {
        case .streamableHTTP:
            return endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名 MCP" : endpoint
        case .localAlpineCommand:
            return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名 MCP" : command
        }
    }

    var summary: String {
        switch transport {
        case .streamableHTTP:
            return endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写端点" : endpoint
        case .localAlpineCommand:
            return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写启动命令" : command
        }
    }
}

struct LocalMCPAgentVerificationResult: Sendable {
    let status: LocalMCPAgentStatus
    let message: String
}

@MainActor
@Observable
final class LocalMCPAgentService {
    static let shared = LocalMCPAgentService()

    private let storageKey = "iexa.local.mcp.agents.v1"

    private(set) var connections: [LocalMCPAgentConnection] = []
    private(set) var verifyingIDs: Set<String> = []

    private init() {
        load()
    }

    var enabledConnections: [LocalMCPAgentConnection] {
        connections.filter(\.isEnabled)
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LocalMCPAgentConnection].self, from: data) else {
            connections = []
            return
        }
        connections = decoded
    }

    func upsert(_ connection: LocalMCPAgentConnection) {
        var next = connection
        next.updatedAt = Date()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = next
        } else {
            connections.append(next)
        }
        save()
    }

    func delete(_ connection: LocalMCPAgentConnection) {
        connections.removeAll { $0.id == connection.id }
        save()
    }

    func toggle(_ connection: LocalMCPAgentConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index].isEnabled.toggle()
        connections[index].updatedAt = Date()
        save()
    }

    @discardableResult
    func verify(_ connection: LocalMCPAgentConnection) async -> LocalMCPAgentVerificationResult {
        verifyingIDs.insert(connection.id)
        defer { verifyingIDs.remove(connection.id) }

        let result: LocalMCPAgentVerificationResult
        switch connection.transport {
        case .streamableHTTP:
            result = await verifyHTTP(connection)
        case .localAlpineCommand:
            result = await verifyLocalAlpineCommand(connection)
        }

        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index].lastStatus = result.status
            connections[index].lastMessage = result.message
            connections[index].lastCheckedAt = Date()
            connections[index].updatedAt = Date()
            save()
        }
        return result
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func verifyHTTP(_ connection: LocalMCPAgentConnection) async -> LocalMCPAgentVerificationResult {
        let rawEndpoint = connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawEndpoint), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return LocalMCPAgentVerificationResult(status: .failed, message: "请输入 http:// 或 https:// 开头的 MCP 端点。")
        }
        guard let host = url.host, Self.isLocalOrPrivateHost(host) else {
            return LocalMCPAgentVerificationResult(status: .failed, message: "当前为纯本地模式，只允许连接 localhost、本机或局域网 MCP 地址。")
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in connection.headers where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let clientInfo: [String: Any] = [
            "name": "Iexa Local MCP Agent",
            "version": "0.1"
        ]
        let params: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": clientInfo
        ]
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": params
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return LocalMCPAgentVerificationResult(status: .warning, message: "端点有响应，但不是标准 HTTP 响应。")
            }
            if (200..<300).contains(http.statusCode) {
                let preview = String(decoding: data.prefix(240), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if preview.localizedCaseInsensitiveContains("jsonrpc")
                    || preview.localizedCaseInsensitiveContains("capabilities")
                    || preview.localizedCaseInsensitiveContains("serverInfo") {
                    return LocalMCPAgentVerificationResult(status: .available, message: "MCP 初始化响应正常。")
                }
                return LocalMCPAgentVerificationResult(status: .warning, message: "端点可达，但响应不像标准 MCP 初始化结果。")
            }
            if [400, 404, 405, 406].contains(http.statusCode) {
                return LocalMCPAgentVerificationResult(status: .warning, message: "端点可达，HTTP \(http.statusCode)。请确认 MCP path 是否正确。")
            }
            return LocalMCPAgentVerificationResult(status: .failed, message: "端点返回 HTTP \(http.statusCode)。")
        } catch {
            return LocalMCPAgentVerificationResult(status: .failed, message: error.localizedDescription)
        }
    }

    private func verifyLocalAlpineCommand(_ connection: LocalMCPAgentConnection) async -> LocalMCPAgentVerificationResult {
        let command = connection.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return LocalMCPAgentVerificationResult(status: .failed, message: "请输入 Local Alpine MCP 启动命令。")
        }
        guard let executable = Self.firstShellToken(in: command) else {
            return LocalMCPAgentVerificationResult(status: .failed, message: "无法识别命令入口。")
        }

        let probe = "command -v \(Self.shellSingleQuoted(executable)) >/dev/null 2>&1 && echo IEXA_MCP_COMMAND_OK || echo IEXA_MCP_COMMAND_MISSING"
        let result = await LocalAlpineTerminalService.shared.execute(command: probe, cwd: "/mnt/iexa")
        if result.output.contains("IEXA_MCP_COMMAND_OK") {
            return LocalMCPAgentVerificationResult(status: .available, message: "Local Alpine 中可找到 \(executable)。")
        }
        if result.output.contains("IEXA_MCP_COMMAND_MISSING") {
            return LocalMCPAgentVerificationResult(status: .failed, message: "Local Alpine 中找不到 \(executable)。")
        }
        return LocalMCPAgentVerificationResult(status: .warning, message: result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "命令检测没有返回输出。" : result.output)
    }

    private static func firstShellToken(in command: String) -> String? {
        var token = ""
        var quote: Character?
        var isEscaped = false
        for char in command {
            if isEscaped {
                token.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    token.append(char)
                }
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                continue
            }
            if char.isWhitespace {
                break
            }
            token.append(char)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if host == "localhost" || host == "0.0.0.0" || host == "::1" {
            return true
        }
        if host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
            return true
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        if host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return true
        }
        return false
    }
}
