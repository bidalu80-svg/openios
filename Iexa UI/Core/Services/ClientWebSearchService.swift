import CryptoKit
import Foundation

struct ClientWebSearchService: Sendable {
    private let apiClient: APIClient?

    init(apiClient: APIClient? = nil) {
        self.apiClient = apiClient
    }

    func search(queries: [String], originalQuery: String?) async throws -> WebSearchResponse {
        let normalizedQueries = Self.unique(queries.map(Self.normalizedQuery))
        guard !normalizedQueries.isEmpty else { return WebSearchResponse() }

        if let configured = await configuredSearchResponse(
            queries: Array(normalizedQueries.prefix(4)),
            originalQuery: originalQuery ?? normalizedQueries.first
        ) {
            return configured
        }

        return await BrowserWebSearchService.shared.search(
            queries: Array(normalizedQueries.prefix(4)),
            originalQuery: originalQuery ?? normalizedQueries.first
        )
    }

    private func configuredSearchResponse(queries: [String], originalQuery: String?) async -> WebSearchResponse? {
        guard let apiClient else { return nil }
        let config: WebSearchConfig
        do {
            config = try await apiClient.getRetrievalConfig().web
        } catch {
            return nil
        }
        guard config.enableWebSearch else { return nil }

        let engines = Self.domesticConfiguredEngines(for: config)
        guard !engines.isEmpty else { return nil }

        let count = min(max(config.searchResultCount, 1), 8)
        for engine in engines {
            let items = await configuredSearchItems(
                engine: engine,
                config: config,
                queries: queries,
                count: count
            )
            guard !items.isEmpty else { continue }
            return await BrowserWebSearchService.shared.responseFromConfiguredSearchItems(
                items,
                originalQuery: originalQuery,
                provider: "configured_\(engine.rawValue)"
            )
        }
        return nil
    }

    private func configuredSearchItems(
        engine: ConfiguredSearchEngine,
        config: WebSearchConfig,
        queries: [String],
        count: Int
    ) async -> [WebSearchResultItem] {
        var collected: [WebSearchResultItem] = []
        var seenLinks = Set<String>()

        for query in queries {
            let items: [WebSearchResultItem]
            switch engine {
            case .bocha:
                items = await Self.searchBocha(query: query, count: count, apiKey: config.bochaSearchAPIKey)
            case .external:
                items = await Self.searchExternal(
                    query: query,
                    count: count,
                    endpoint: config.externalSearchURL,
                    apiKey: config.externalSearchAPIKey
                )
            case .sougou:
                items = await Self.searchSougou(
                    query: query,
                    count: count,
                    secretID: config.sougouAPISID,
                    secretKey: config.sougouAPISK
                )
            case .searxng:
                items = await Self.searchSearXNG(
                    query: query,
                    count: count,
                    queryURL: config.searxngQueryURL,
                    language: config.searxngLanguage
                )
            case .yacy:
                items = await Self.searchYacy(
                    query: query,
                    count: count,
                    queryURL: config.yacyQueryURL,
                    username: config.yacyUsername,
                    password: config.yacyPassword
                )
            }

            for item in items {
                let linkKey = item.link?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard let linkKey, !linkKey.isEmpty, seenLinks.insert(linkKey).inserted else {
                    continue
                }
                collected.append(item)
                if collected.count >= count { return collected }
            }
        }

        return collected
    }

    private static func domesticConfiguredEngines(for config: WebSearchConfig) -> [ConfiguredSearchEngine] {
        var engines: [ConfiguredSearchEngine] = []
        let selected = normalizedEngine(config.webSearchEngine)
        if let selectedEngine = ConfiguredSearchEngine(rawValue: selected),
           selectedEngine.isConfigured(config) {
            engines.append(selectedEngine)
        }

        for engine in ConfiguredSearchEngine.priority {
            guard engine.isConfigured(config) else { continue }
            if !engines.contains(engine) {
                engines.append(engine)
            }
        }
        return engines
    }

    private static func normalizedEngine(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func searchBocha(query: String, count: Int, apiKey: String) async -> [WebSearchResultItem] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let url = URL(string: "https://api.bochaai.com/v1/web-search?utm_source=iexa_ios") else { return [] }

        let payload: [String: Any] = [
            "query": query,
            "summary": true,
            "freshness": "noLimit",
            "count": count
        ]
        let json = await jsonRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json"
            ],
            jsonBody: payload
        )

        let pages = ((json?["data"] as? [String: Any])?["webPages"] as? [String: Any])?["value"] as? [[String: Any]] ?? []
        return pages.prefix(count).compactMap { item in
            WebSearchResultItem(json: [
                "title": item["name"] as? String ?? item["title"] as? String ?? "",
                "link": item["url"] as? String ?? "",
                "snippet": item["summary"] as? String ?? item["snippet"] as? String ?? "",
                "thumbnail_url": item["siteIcon"] as? String ?? ""
            ])
        }
    }

    private static func searchExternal(
        query: String,
        count: Int,
        endpoint: String,
        apiKey: String
    ) async -> [WebSearchResultItem] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        var headers = [
            "User-Agent": "Iexa iOS Web Search",
            "Content-Type": "application/json"
        ]
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            headers["Authorization"] = "Bearer \(trimmedKey)"
        }

        let json = await jsonRequest(
            url: url,
            method: "POST",
            headers: headers,
            jsonBody: [
                "query": query,
                "count": count
            ]
        )
        return searchItems(from: json).prefix(count).map { $0 }
    }

    private static func searchSearXNG(
        query: String,
        count: Int,
        queryURL: String,
        language: String
    ) async -> [WebSearchResultItem] {
        let trimmedURL = queryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return [] }
        let baseURL = trimmedURL.contains("<query>")
            ? String(trimmedURL.split(separator: "?", maxSplits: 1).first ?? "")
            : trimmedURL
        guard var components = URLComponents(string: baseURL) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageno", value: "1"),
            URLQueryItem(name: "safesearch", value: "1"),
            URLQueryItem(name: "language", value: language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "all" : language),
            URLQueryItem(name: "theme", value: "simple"),
            URLQueryItem(name: "image_proxy", value: "0")
        ]
        guard let url = components.url else { return [] }

        let json = await jsonRequest(
            url: url,
            method: "GET",
            headers: [
                "User-Agent": "Iexa iOS Web Search",
                "Accept": "application/json"
            ],
            jsonBody: nil
        )
        let results = (json?["results"] as? [[String: Any]] ?? [])
            .sorted { (lhs, rhs) in
                doubleValue(lhs["score"]) > doubleValue(rhs["score"])
            }
        return results.prefix(count).compactMap { item in
            WebSearchResultItem(json: [
                "title": item["title"] as? String ?? "",
                "link": item["url"] as? String ?? "",
                "snippet": item["content"] as? String ?? item["snippet"] as? String ?? ""
            ])
        }
    }

    private static func searchSougou(
        query: String,
        count: Int,
        secretID: String,
        secretKey: String
    ) async -> [WebSearchResultItem] {
        let sid = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty, !sk.isEmpty else { return [] }
        guard let url = URL(string: "https://tms.tencentcloudapi.com") else { return [] }

        let payload: [String: Any] = [
            "Query": query,
            "Cnt": min(max(count, 1), 20)
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return [] }
        let timestamp = Int(Date().timeIntervalSince1970)
        let authorization = tencentCloudAuthorization(
            secretID: sid,
            secretKey: sk,
            service: "tms",
            host: "tms.tencentcloudapi.com",
            action: "SearchPro",
            version: "2020-12-29",
            timestamp: timestamp,
            body: body
        )
        let json = await jsonRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": authorization,
                "Content-Type": "application/json; charset=utf-8",
                "Host": "tms.tencentcloudapi.com",
                "X-TC-Action": "SearchPro",
                "X-TC-Version": "2020-12-29",
                "X-TC-Timestamp": "\(timestamp)",
                "X-TC-Language": "zh-CN"
            ],
            body: body
        )

        let pages = ((json?["Response"] as? [String: Any])?["Pages"] as? [Any]) ?? []
        return pages.compactMap { page -> [String: Any]? in
            if let string = page as? String,
               let data = string.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return page as? [String: Any]
        }
        .sorted { doubleValue($0["scour"]) > doubleValue($1["scour"]) }
        .prefix(count)
        .compactMap { item in
            WebSearchResultItem(json: [
                "title": item["title"] as? String ?? "",
                "link": item["url"] as? String ?? "",
                "snippet": item["passage"] as? String ?? item["snippet"] as? String ?? ""
            ])
        }
    }

    private static func searchYacy(
        query: String,
        count: Int,
        queryURL: String,
        username: String,
        password: String
    ) async -> [WebSearchResultItem] {
        let trimmedURL = queryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return [] }
        let endpoint = trimmedURL.hasSuffix("yacysearch.json")
            ? trimmedURL
            : trimmedURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/yacysearch.json"
        guard var components = URLComponents(string: endpoint) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "contentdom", value: "text"),
            URLQueryItem(name: "resource", value: "global"),
            URLQueryItem(name: "maximumRecords", value: "\(count)"),
            URLQueryItem(name: "nav", value: "none")
        ]
        guard let url = components.url else { return [] }

        var headers = [
            "User-Agent": "Iexa iOS Web Search",
            "Accept": "application/json"
        ]
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty || !pass.isEmpty {
            let raw = "\(user):\(pass)"
            if let encoded = raw.data(using: .utf8)?.base64EncodedString() {
                headers["Authorization"] = "Basic \(encoded)"
            }
        }

        let json = await jsonRequest(url: url, method: "GET", headers: headers, jsonBody: nil)
        let items = (((json?["channels"] as? [[String: Any]])?.first)?["items"] as? [[String: Any]] ?? [])
            .sorted { doubleValue($0["ranking"]) > doubleValue($1["ranking"]) }
        return items.prefix(count).compactMap { item in
            WebSearchResultItem(json: [
                "title": item["title"] as? String ?? "",
                "link": item["link"] as? String ?? "",
                "snippet": item["description"] as? String ?? item["snippet"] as? String ?? ""
            ])
        }
    }

    private static func jsonRequest(
        url: URL,
        method: String,
        headers: [String: String],
        jsonBody: [String: Any]?
    ) async -> [String: Any]? {
        let body = jsonBody.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return await jsonRequest(url: url, method: method, headers: headers, body: body)
    }

    private static func jsonRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func searchItems(from json: [String: Any]?) -> [WebSearchResultItem] {
        guard let json else { return [] }
        if let array = json["results"] as? [[String: Any]] {
            return array.compactMap(WebSearchResultItem.init(json:))
        }
        if let array = json["items"] as? [[String: Any]] {
            return array.compactMap(WebSearchResultItem.init(json:))
        }
        if let array = json["data"] as? [[String: Any]] {
            return array.compactMap(WebSearchResultItem.init(json:))
        }
        if let data = json["data"] as? [String: Any] {
            return searchItems(from: data)
        }
        if let webPages = json["webPages"] as? [String: Any],
           let array = webPages["value"] as? [[String: Any]] {
            return array.compactMap(WebSearchResultItem.init(json:))
        }
        if let array = json["value"] as? [[String: Any]] {
            return array.compactMap(WebSearchResultItem.init(json:))
        }
        if let array = json["webPages"] as? [[String: Any]] {
            return array.compactMap(WebSearchResultItem.init(json:))
        }
        return []
    }

    private static func tencentCloudAuthorization(
        secretID: String,
        secretKey: String,
        service: String,
        host: String,
        action: String,
        version: String,
        timestamp: Int,
        body: Data
    ) -> String {
        let contentType = "application/json; charset=utf-8"
        let hashedPayload = sha256Hex(body)
        let canonicalRequest = [
            "POST",
            "/",
            "",
            "content-type:\(contentType)\nhost:\(host)\n",
            "content-type;host",
            hashedPayload
        ].joined(separator: "\n")
        let date = utcDateString(from: TimeInterval(timestamp))
        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            "\(timestamp)",
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let secretDate = hmacSHA256(Data(date.utf8), key: Data("TC3\(secretKey)".utf8))
        let secretService = hmacSHA256(Data(service.utf8), key: secretDate)
        let secretSigning = hmacSHA256(Data("tc3_request".utf8), key: secretService)
        let signature = hmacSHA256Hex(Data(stringToSign.utf8), key: secretSigning)

        return "TC3-HMAC-SHA256 Credential=\(secretID)/\(credentialScope), SignedHeaders=content-type;host, Signature=\(signature)"
    }

    private static func utcDateString(from timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(_ data: Data, key: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hmacSHA256Hex(_ data: Data, key: Data) -> String {
        hmacSHA256(data, key: key).map { String(format: "%02x", $0) }.joined()
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }
}

private enum ConfiguredSearchEngine: String, CaseIterable {
    case bocha
    case external
    case sougou
    case searxng
    case yacy

    static let priority: [ConfiguredSearchEngine] = [.bocha, .external, .sougou, .searxng, .yacy]

    func isConfigured(_ config: WebSearchConfig) -> Bool {
        switch self {
        case .bocha:
            return !config.bochaSearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .external:
            return URL(string: config.externalSearchURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .sougou:
            return !config.sougouAPISID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !config.sougouAPISK.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .searxng:
            return URL(string: config.searxngQueryURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .yacy:
            return URL(string: config.yacyQueryURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }
}
