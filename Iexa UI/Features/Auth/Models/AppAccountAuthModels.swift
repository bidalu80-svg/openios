import Foundation

enum AppAccountAuthMode: String, CaseIterable, Identifiable {
    case login
    case register

    var id: String { rawValue }
}

struct AppAccountAuthUser: Codable, Equatable {
    let id: String
    let phone: String
    let email: String?
    let name: String?
    let role: String?
    let profileImageURL: String?
    let createdAt: Date?

    var loginID: String {
        let preferred = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preferred.isEmpty ? phone.trimmingCharacters(in: .whitespacesAndNewlines) : preferred
    }

    var displayName: String {
        let preferred = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preferred.isEmpty ? loginID : preferred
    }
}

struct AppAccountAuthSession: Codable, Equatable {
    let token: String
    let expiresAt: Date?
    let user: AppAccountAuthUser

    var isTemporaryOfflineAccess: Bool {
        token.hasPrefix("iexa-temporary-offline-")
    }
}

enum AppAccountAuthSessionStore {
    private static let sessionKey = "iexa.app_account_auth.session"
    private static let endpointKey = "iexa.app_account_auth.base_url"
    private static let defaultBaseURL = "http://8.218.177.114"

    static func loadSession(defaults: UserDefaults = .standard) -> AppAccountAuthSession? {
        guard let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? decoder.decode(AppAccountAuthSession.self, from: data)
    }

    static func saveSession(_ session: AppAccountAuthSession, defaults: UserDefaults = .standard) {
        guard let data = try? encoder.encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
    }

    static func clearSession(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: sessionKey)
    }

    static func loadBaseURL(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: endpointKey),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizedBaseURL(saved)
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "AUTH_API_URL") as? String,
           !bundled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizedBaseURL(bundled)
        }
        return defaultBaseURL
    }

    static func saveBaseURL(_ raw: String, defaults: UserDefaults = .standard) {
        defaults.set(normalizedBaseURL(raw), forKey: endpointKey)
    }

    static func normalizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
