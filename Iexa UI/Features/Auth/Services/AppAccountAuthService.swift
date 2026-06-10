import Foundation

enum AppAccountAuthServiceError: LocalizedError {
    case invalidBaseURL
    case invalidAccount
    case weakPassword
    case invalidActivationCode
    case invalidResponse
    case http(status: Int, message: String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "认证服务地址无效。"
        case .invalidAccount:
            return "账号格式无效。"
        case .weakPassword:
            return "密码至少需要 6 位。"
        case .invalidActivationCode:
            return "请填写有效激活码。"
        case .invalidResponse:
            return "认证服务返回了无法识别的响应。"
        case .http(let status, let message):
            if message.isEmpty {
                return "认证请求失败（HTTP \(status)）。"
            }
            return "认证请求失败（HTTP \(status)）：\(message)"
        case .server(let message):
            return message
        }
    }
}

final class AppAccountAuthService {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": Self.appUserAgent
        ]
        self.session = URLSession(configuration: config)
    }

    func login(baseURL: String, account: String, password: String) async throws -> AppAccountAuthSession {
        let normalizedAccount = Self.normalizedAccount(account)
        guard Self.isAccountValid(normalizedAccount) else {
            throw AppAccountAuthServiceError.invalidAccount
        }
        guard Self.isPasswordValid(password) else {
            throw AppAccountAuthServiceError.weakPassword
        }

        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/login",
            method: "POST",
            body: [
                "phone": normalizedAccount,
                "account": normalizedAccount,
                "password": password
            ],
            bearerToken: nil
        )
        guard let session = try parseSession(from: object, fallbackLoginID: normalizedAccount) else {
            throw AppAccountAuthServiceError.invalidResponse
        }
        return session
    }

    func register(baseURL: String, account: String, password: String, activationCode: String) async throws -> AppAccountAuthSession {
        let normalizedAccount = Self.normalizedAccount(account)
        let normalizedActivationCode = Self.normalizedActivationCode(activationCode)
        guard Self.isAccountValid(normalizedAccount) else {
            throw AppAccountAuthServiceError.invalidAccount
        }
        guard Self.isPasswordValid(password) else {
            throw AppAccountAuthServiceError.weakPassword
        }
        guard Self.isActivationCodeValid(normalizedActivationCode) else {
            throw AppAccountAuthServiceError.invalidActivationCode
        }

        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/register",
            method: "POST",
            body: [
                "phone": normalizedAccount,
                "account": normalizedAccount,
                "name": normalizedAccount,
                "username": normalizedAccount,
                "password": password,
                "activationCode": normalizedActivationCode,
                "activation_code": normalizedActivationCode,
                "inviteCode": normalizedActivationCode
            ],
            bearerToken: nil
        )
        guard let session = try parseSession(from: object, fallbackLoginID: normalizedAccount) else {
            throw AppAccountAuthServiceError.invalidResponse
        }
        return session
    }

    func validateSession(baseURL: String, session: AppAccountAuthSession) async throws -> AppAccountAuthSession {
        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/me",
            method: "GET",
            body: nil,
            bearerToken: session.token
        )
        guard let validated = try parseSession(
            from: object,
            fallbackLoginID: session.user.loginID,
            fallbackToken: session.token,
            fallbackExpiresAt: session.expiresAt
        ) else {
            throw AppAccountAuthServiceError.invalidResponse
        }
        return validated
    }

    func logout(baseURL: String, token: String) async {
        _ = try? await sendRequest(
            baseURL: baseURL,
            path: "/auth/logout",
            method: "POST",
            body: [:],
            bearerToken: token
        )
    }

    static func normalizedAccount(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedActivationCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    static func isAccountValid(_ raw: String) -> Bool {
        let pattern = #"^[A-Za-z0-9_.+\-@]{2,64}$"#
        return raw.range(of: pattern, options: .regularExpression) != nil
    }

    static func isActivationCodeValid(_ raw: String) -> Bool {
        let pattern = #"^[A-Z0-9][A-Z0-9\-]{3,63}$"#
        return raw.range(of: pattern, options: .regularExpression) != nil
    }

    static func isPasswordValid(_ raw: String) -> Bool {
        raw.count >= 6 && raw.count <= 64
    }

    private func sendRequest(
        baseURL: String,
        path: String,
        method: String,
        body: [String: Any]?,
        bearerToken: String?
    ) async throws -> [String: Any] {
        let normalized = AppAccountAuthSessionStore.normalizedBaseURL(baseURL)
        guard !normalized.isEmpty, let url = URL(string: normalized + path) else {
            throw AppAccountAuthServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(AppDeviceInstallIdentity.currentID(), forHTTPHeaderField: "X-Device-Install-ID")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppAccountAuthServiceError.invalidResponse
        }

        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (200...299).contains(http.statusCode) {
            if let ok = object["ok"] as? Bool, !ok {
                let message = (object["message"] as? String) ?? "认证服务返回失败。"
                throw AppAccountAuthServiceError.server(message)
            }
            return object
        }

        let message = (object["message"] as? String)
            ?? (object["detail"] as? String)
            ?? String(data: data, encoding: .utf8)
            ?? ""
        throw AppAccountAuthServiceError.http(status: http.statusCode, message: message)
    }

    private func parseSession(
        from object: [String: Any],
        fallbackLoginID: String,
        fallbackToken: String? = nil,
        fallbackExpiresAt: Date? = nil
    ) throws -> AppAccountAuthSession? {
        let payload = (object["data"] as? [String: Any]) ?? object
        try Self.ensureAccountIsAllowed(payload)

        let token = Self.firstString(in: payload, keys: ["token", "accessToken", "access_token", "jwt"]) ?? fallbackToken
        guard let token, !token.isEmpty else { return nil }

        let expiresAt = Self.parseDate(payload["expiresAt"]) ?? Self.parseDate(payload["expires_at"]) ?? fallbackExpiresAt
        if let userObject = payload["user"] as? [String: Any],
           let user = parseUser(from: userObject, fallbackLoginID: fallbackLoginID) {
            try Self.ensureAccountIsAllowed(userObject)
            return AppAccountAuthSession(token: token, expiresAt: expiresAt, user: user)
        }
        guard let user = parseUser(from: payload, fallbackLoginID: fallbackLoginID) else { return nil }
        return AppAccountAuthSession(token: token, expiresAt: expiresAt, user: user)
    }

    private func parseUser(from object: [String: Any], fallbackLoginID: String) -> AppAccountAuthUser? {
        let payload = (object["data"] as? [String: Any])
            ?? (object["user"] as? [String: Any])
            ?? object

        let loginID = Self.firstString(in: payload, keys: ["email", "phone", "username", "name"]) ?? fallbackLoginID
        let id = Self.firstString(in: payload, keys: ["id", "_id", "uid"]) ?? loginID
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return AppAccountAuthUser(
            id: id,
            phone: loginID,
            email: Self.firstString(in: payload, keys: ["email"]) ?? loginID,
            name: Self.firstString(in: payload, keys: ["name", "username"]) ?? loginID,
            role: Self.firstString(in: payload, keys: ["role"]),
            profileImageURL: Self.firstString(in: payload, keys: ["profileImageURL", "profileImageUrl", "profile_image_url"]),
            createdAt: Self.parseDate(payload["createdAt"]) ?? Self.parseDate(payload["created_at"])
        )
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func ensureAccountIsAllowed(_ payload: [String: Any]) throws {
        if truthy(payload["banned"]) || truthy(payload["isBanned"]) || truthy(payload["is_banned"]) {
            throw AppAccountAuthServiceError.server("账号已被封禁，请联系管理员。")
        }
        if truthy(payload["disabled"]) || truthy(payload["isDisabled"]) || truthy(payload["is_disabled"]) {
            throw AppAccountAuthServiceError.server("账号已被停用，请联系管理员。")
        }
        if let active = boolValue(payload["active"] ?? payload["isActive"] ?? payload["is_active"]),
           active == false {
            throw AppAccountAuthServiceError.server("账号状态已失效，请重新登录。")
        }
        let bannedAt = firstString(in: payload, keys: ["bannedAt", "banned_at"])
        if bannedAt != nil {
            throw AppAccountAuthServiceError.server("账号已被封禁，请联系管理员。")
        }
        let deletedAt = firstString(in: payload, keys: ["deletedAt", "deleted_at"])
        if deletedAt != nil {
            throw AppAccountAuthServiceError.server("账号已被删除，请重新注册。")
        }
        if let status = firstString(in: payload, keys: ["status", "state"])?.lowercased(),
           ["banned", "blocked", "disabled", "deleted", "inactive", "suspended"].contains(status) {
            throw AppAccountAuthServiceError.server("账号状态已失效，请重新登录。")
        }
    }

    private static func truthy(_ raw: Any?) -> Bool {
        boolValue(raw) == true
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let text = raw as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let text = raw as? String {
            if let date = iso8601WithFractional.date(from: text) ?? iso8601.date(from: text) {
                return date
            }
            if let value = TimeInterval(text) {
                return Date(timeIntervalSince1970: value)
            }
        }
        if let value = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = raw as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        return nil
    }

    private static var appUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "Iexa-iOS/\(version) (\(build))"
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
