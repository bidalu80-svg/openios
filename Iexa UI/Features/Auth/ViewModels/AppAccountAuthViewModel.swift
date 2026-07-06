import Foundation

@Observable
final class AppAccountAuthViewModel {
    var mode: AppAccountAuthMode = .login
    var baseURL: String
    var account: String = ""
    var password: String = ""
    var activationCode: String = ""
    var isSubmitting: Bool = false
    var isValidatingSession: Bool = false
    var statusMessage: String = ""
    var errorMessage: String?
    private(set) var session: AppAccountAuthSession?

    private let service: AppAccountAuthService
    private var sessionValidationTask: Task<Void, Never>?
    private var lastSessionValidationAt: Date?
    private let sessionValidationCooldown: TimeInterval = 5
    private let sessionValidationInterval: TimeInterval = 30

    init(service: AppAccountAuthService = AppAccountAuthService()) {
        self.service = service
        self.baseURL = AppAccountAuthSessionStore.loadBaseURL()
        self.session = AppAccountAuthSessionStore.loadSession()
        if let session {
            self.account = session.user.loginID
        }
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var currentLoginID: String {
        session?.user.loginID ?? ""
    }

    var currentDisplayName: String {
        session?.user.displayName ?? "未登录"
    }

    var hasAuthEndpoint: Bool {
        !AppAccountAuthSessionStore.normalizedBaseURL(baseURL).isEmpty
    }

    var requiresActivationCode: Bool {
        Self.requiresActivationCode
    }

    var canLogin: Bool {
        guard !isSubmitting else { return false }
        let endpoint = AppAccountAuthSessionStore.normalizedBaseURL(baseURL)
        let normalizedAccount = AppAccountAuthService.normalizedAccount(account)
        return !endpoint.isEmpty
            && AppAccountAuthService.isAccountValid(normalizedAccount)
            && AppAccountAuthService.isPasswordValid(password)
    }

    var canRegister: Bool {
        guard canLogin else { return false }
        guard Self.requiresActivationCode else { return true }
        let normalizedActivationCode = AppAccountAuthService.normalizedActivationCode(activationCode)
        return AppAccountAuthService.isActivationCodeValid(normalizedActivationCode)
    }

    var canSubmit: Bool {
        mode == .register ? canRegister : canLogin
    }

    func submit(as mode: AppAccountAuthMode) async {
        guard !isSubmitting else { return }
        self.mode = mode

        let endpoint = AppAccountAuthSessionStore.normalizedBaseURL(baseURL)
        guard !endpoint.isEmpty else {
            errorMessage = "认证服务地址不可用。"
            return
        }

        let normalizedAccount = AppAccountAuthService.normalizedAccount(account)
        guard AppAccountAuthService.isAccountValid(normalizedAccount) else {
            errorMessage = "账号格式无效。"
            return
        }

        guard AppAccountAuthService.isPasswordValid(password) else {
            errorMessage = "密码至少 6 位。"
            return
        }
        let normalizedActivationCode = AppAccountAuthService.normalizedActivationCode(activationCode)
        if mode == .register,
           Self.requiresActivationCode,
           !AppAccountAuthService.isActivationCodeValid(normalizedActivationCode) {
            errorMessage = "请填写有效激活码。"
            return
        }

        errorMessage = nil
        statusMessage = ""
        isSubmitting = true
        defer { isSubmitting = false }

        if Self.temporaryOfflineAccessEnabled {
            let result = Self.makeTemporaryOfflineSession(account: normalizedAccount)
            AppAccountAuthSessionStore.saveBaseURL(endpoint)
            AppAccountAuthSessionStore.saveSession(result)
            baseURL = endpoint
            session = result
            account = result.user.loginID
            password = ""
            activationCode = ""
            statusMessage = "认证服务暂不可用，已进入本地临时模式"
            lastSessionValidationAt = Date()
            return
        }

        do {
            let result: AppAccountAuthSession
            switch mode {
            case .login:
                result = try await service.login(baseURL: endpoint, account: normalizedAccount, password: password)
            case .register:
                result = try await service.register(
                    baseURL: endpoint,
                    account: normalizedAccount,
                    password: password,
                    activationCode: normalizedActivationCode
                )
            }
            AppAccountAuthSessionStore.saveBaseURL(endpoint)
            AppAccountAuthSessionStore.saveSession(result)
            baseURL = endpoint
            session = result
            account = result.user.loginID
            password = ""
            activationCode = ""
            statusMessage = mode == .login ? "登录成功" : "注册并登录成功"
            startSessionValidationTimer()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func signOut() async {
        let existingSession = session
        let endpoint = AppAccountAuthSessionStore.normalizedBaseURL(baseURL)
        signOutLocal()
        if let existingSession, !existingSession.isTemporaryOfflineAccess, !endpoint.isEmpty {
            Task {
                await service.logout(baseURL: endpoint, token: existingSession.token)
            }
        }
    }

    func signOutLocal(statusMessage: String = "已退出登录", errorMessage: String? = nil) {
        stopSessionValidationTimer()
        AppAccountAuthSessionStore.clearSession()
        session = nil
        password = ""
        activationCode = ""
        self.statusMessage = statusMessage
        self.errorMessage = errorMessage
        lastSessionValidationAt = nil
    }

    func startSessionValidationTimer() {
        guard session != nil else { return }
        stopSessionValidationTimer()
        let interval = sessionValidationInterval
        sessionValidationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.validateCurrentSession(force: true)
            }
        }
    }

    func stopSessionValidationTimer() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
    }

    func validateCurrentSession(force: Bool = false) async {
        guard let currentSession = session else { return }
        if currentSession.isTemporaryOfflineAccess {
            guard Self.temporaryOfflineAccessEnabled else {
                signOutLocal(statusMessage: "临时通行已关闭", errorMessage: "服务器认证已恢复，请重新登录。")
                return
            }
            lastSessionValidationAt = Date()
            return
        }
        let endpoint = AppAccountAuthSessionStore.normalizedBaseURL(baseURL)
        guard !endpoint.isEmpty else { return }
        guard !isValidatingSession else { return }
        if !force,
           let lastSessionValidationAt,
           Date().timeIntervalSince(lastSessionValidationAt) < sessionValidationCooldown {
            return
        }

        isValidatingSession = true
        defer { isValidatingSession = false }

        do {
            let validated = try await service.validateSession(baseURL: endpoint, session: currentSession)
            guard session?.token == currentSession.token else { return }
            AppAccountAuthSessionStore.saveBaseURL(endpoint)
            AppAccountAuthSessionStore.saveSession(validated)
            baseURL = endpoint
            session = validated
            account = validated.user.loginID
            lastSessionValidationAt = Date()
        } catch {
            lastSessionValidationAt = Date()
            guard session?.token == currentSession.token else { return }
            guard shouldInvalidateSession(for: error) else { return }
            signOutLocal(
                statusMessage: "账号状态已失效",
                errorMessage: sessionInvalidationMessage(for: error)
            )
        }
    }

    private func sessionInvalidationMessage(for error: Error) -> String {
        if let serviceError = error as? AppAccountAuthServiceError,
           case .http(_, let message) = serviceError,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        return friendlyMessage(for: error)
    }

    private func shouldInvalidateSession(for error: Error) -> Bool {
        if let serviceError = error as? AppAccountAuthServiceError {
            switch serviceError {
            case .http(let status, _):
                return status == 401 || status == 403
            case .server:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func friendlyMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let text = error.localizedDescription
        return text.isEmpty ? "登录失败，请稍后重试。" : text
    }

    private static let temporaryOfflineAccessEnabled = true
    private static let requiresActivationCode = false

    private static func makeTemporaryOfflineSession(account: String) -> AppAccountAuthSession {
        let loginID = AppAccountAuthService.normalizedAccount(account)
        let fallbackID = loginID.isEmpty ? "local-user" : loginID
        return AppAccountAuthSession(
            token: "iexa-temporary-offline-\(UUID().uuidString)",
            expiresAt: nil,
            user: AppAccountAuthUser(
                id: "local-\(fallbackID)",
                phone: fallbackID,
                email: fallbackID.contains("@") ? fallbackID : nil,
                name: fallbackID,
                role: "local",
                profileImageURL: nil,
                createdAt: Date()
            )
        )
    }
}
