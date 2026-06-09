import Foundation

@Observable
final class AppAccountAuthViewModel {
    var mode: AppAccountAuthMode = .login
    var baseURL: String
    var account: String = ""
    var password: String = ""
    var activationCode: String = ""
    var isSubmitting: Bool = false
    var statusMessage: String = ""
    var errorMessage: String?
    private(set) var session: AppAccountAuthSession?

    private let service: AppAccountAuthService

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
        if mode == .register && !AppAccountAuthService.isActivationCodeValid(normalizedActivationCode) {
            errorMessage = "请填写有效激活码。"
            return
        }

        errorMessage = nil
        statusMessage = ""
        isSubmitting = true
        defer { isSubmitting = false }

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
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func signOut() async {
        let existingSession = session
        let endpoint = AppAccountAuthSessionStore.normalizedBaseURL(baseURL)
        signOutLocal()
        if let existingSession, !endpoint.isEmpty {
            Task {
                await service.logout(baseURL: endpoint, token: existingSession.token)
            }
        }
    }

    func signOutLocal() {
        AppAccountAuthSessionStore.clearSession()
        session = nil
        password = ""
        activationCode = ""
        statusMessage = "已退出登录"
        errorMessage = nil
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
}
