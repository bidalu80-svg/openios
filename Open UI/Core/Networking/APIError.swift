import Foundation

/// Categorized API error types for the Iexa native server networking layer.
enum APIError: LocalizedError, Sendable {
    /// The server returned an HTTP error status code.
    case httpError(statusCode: Int, message: String?, data: Data?)

    /// The request could not be encoded properly.
    case requestEncoding(underlying: Error)

    /// The response could not be decoded into the expected type.
    case responseDecoding(underlying: Error, data: Data?)

    /// The request URL was malformed or could not be constructed.
    case invalidURL(String)

    /// No authentication token is available for an authenticated request.
    case unauthorized

    /// The auth token was rejected by the server (401).
    case tokenExpired

    /// The server appears to be behind an authentication proxy.
    case proxyAuthRequired

    /// A network-level error occurred (DNS, timeout, connection refused, etc.).
    case networkError(underlying: Error)

    /// The SSL/TLS handshake failed, possibly due to a self-signed certificate.
    case sslError(underlying: Error)

    /// The streaming connection was interrupted or produced an error.
    case streamError(String)

    /// The server returned a redirect, possibly indicating misconfiguration.
    case redirectDetected(location: String?)

    /// A request was cancelled by the caller.
    case cancelled

    /// An unexpected or unclassified error.
    case unknown(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let message, _):
            return Self.friendlyHTTPMessage(statusCode: statusCode, serverMessage: message)

        case .requestEncoding:
            return "请求准备失败，请重试。"

        case .responseDecoding:
            return "服务器返回了无法识别的响应，请重试。"

        case .invalidURL:
            return "站点 URL 无效，请检查设置。"

        case .unauthorized:
            return "请先登录后继续。"

        case .tokenExpired:
            return "登录已过期，请重新登录。"

        case .proxyAuthRequired:
            return "当前网络需要代理认证，请先完成网络登录。"

        case .networkError(let error):
            return Self.friendlyNetworkMessage(error)

        case .sslError:
            return "无法建立安全连接。如果是私有站点，请在设置中允许自签名证书。"

        case .streamError:
            return "回复被中断，请重试。"

        case .redirectDetected:
            return "站点正在重定向请求，请检查站点 URL。"

        case .cancelled:
            return "请求已取消。"

        case .unknown:
            return "发生未知错误，请重试。"
        }
    }

    /// The raw detail message from the server, useful for debugging or power users.
    /// Returns `nil` for non-HTTP errors or when the server didn't provide a message.
    var serverDetail: String? {
        switch self {
        case .httpError(_, let message, _):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .streamError(let message):
            return message
        case .requestEncoding(let error):
            return error.localizedDescription
        case .responseDecoding(let error, _):
            return error.localizedDescription
        case .unknown(let error):
            return error?.localizedDescription
        default:
            return nil
        }
    }

    // MARK: - Friendly Message Helpers

    /// Maps HTTP status codes to user-friendly messages.
    /// For 400 errors, the server's `detail` field is usually already user-facing, so we show it directly.
    private static func friendlyHTTPMessage(statusCode: Int, serverMessage: String?) -> String {
        switch statusCode {
        case 400:
            // Server 400 "detail" messages are typically user-facing (e.g. "Email already registered")
            return serverMessage ?? "请求无效，请检查输入后重试。"
        case 401:
            return "登录已过期，请重新登录。"
        case 403:
            return serverMessage ?? "你没有权限执行此操作。"
        case 404:
            return "找不到请求的内容。"
        case 405:
            return "当前站点不支持这个请求方式。"
        case 409:
            return serverMessage ?? "与现有内容冲突，请换一个名称或 ID。"
        case 413:
            return "文件太大，请换一个更小的文件。"
        case 422:
            return serverMessage ?? "部分信息无效，请检查后重试。"
        case 429:
            return "请求过多，请稍等后重试。"
        case 500:
            return "服务器出错了，请稍后重试。"
        case 502:
            return "服务器暂时不可用，请稍后重试。"
        case 503:
            return "服务器正在维护，请稍后重试。"
        case 504:
            return "服务器响应超时，请重试。"
        default:
            if statusCode >= 500 {
                return "服务器出错（\(statusCode)），请稍后重试。"
            }
            // For other 4xx, show server message if available, otherwise generic
            return serverMessage ?? "请求失败（\(statusCode)），请重试。"
        }
    }

    /// Maps URLError codes to user-friendly network messages.
    private static func friendlyNetworkMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "当前离线，请检查网络后重试。"
            case .timedOut:
                return "请求超时，请检查网络后重试。"
            case .cannotFindHost:
                return "找不到站点，请检查 URL。"
            case .cannotConnectToHost:
                return "无法连接站点，请确认服务可访问。"
            case .networkConnectionLost:
                return "连接被中断，请保持 Iexa 在前台或稍后重试。"
            case .dnsLookupFailed:
                return "无法解析站点地址，请检查 URL。"
            case .internationalRoamingOff:
                return "国际漫游已关闭，请在系统设置中开启。"
            case .dataNotAllowed:
                return "蜂窝数据已关闭，请开启数据或连接 Wi-Fi。"
            default:
                return "网络错误，请检查连接后重试。"
            }
        }
        return "网络错误，请检查连接后重试。"
    }

    /// Whether this error indicates the user should re-authenticate.
    var requiresReauth: Bool {
        switch self {
        case .unauthorized, .tokenExpired:
            return true
        case .httpError(let statusCode, _, _):
            return statusCode == 401
        default:
            return false
        }
    }

    /// Whether this error indicates a connectivity issue (device offline,
    /// server unreachable, DNS failure, etc.) — as opposed to an app-logic
    /// error like 401 or a decoding failure.
    var isConnectivityError: Bool {
        switch self {
        case .networkError(let underlying):
            if let urlError = underlying as? URLError {
                switch urlError.code {
                case .notConnectedToInternet,
                     .cannotConnectToHost,
                     .cannotFindHost,
                     .networkConnectionLost,
                     .timedOut,
                     .dnsLookupFailed:
                    return true
                default:
                    return false
                }
            }
            return true
        case .sslError:
            return true
        default:
            return false
        }
    }

    /// Whether this error is recoverable by retrying.
    var isRetryable: Bool {
        switch self {
        case .networkError, .streamError:
            return true
        case .httpError(let statusCode, _, _):
            return statusCode >= 500 || statusCode == 429
        default:
            return false
        }
    }

    /// Creates an `APIError` from an arbitrary `Error`.
    static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .secureConnectionFailed:
                return .sslError(underlying: urlError)
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet:
                return .networkError(underlying: urlError)
            default:
                return .networkError(underlying: urlError)
            }
        }
        return .unknown(underlying: error)
    }
}

/// Result of a health check with proxy detection.
enum HealthCheckResult: Sendable {
    /// Server is healthy and responding normally.
    case healthy
    /// Server responded but not with expected status.
    case unhealthy
    /// Server appears to be behind an authentication proxy.
    case proxyAuthRequired
    /// Server is behind Cloudflare Bot Fight Mode / Browser Integrity Check.
    /// Requires a real browser (WKWebView) to complete the JS challenge.
    case cloudflareChallenge
    /// Server could not be reached.
    case unreachable
}
