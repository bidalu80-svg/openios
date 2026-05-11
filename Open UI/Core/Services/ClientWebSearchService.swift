import Foundation

struct ClientWebSearchService: Sendable {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let maxResultsPerQuery = 5
    private static let maxFetchedPages = 4
    private static let maxPageCharacters = 5_000
    private static let maxCombinedDocumentCharacters = 18_000

    func search(queries: [String], originalQuery: String?) async throws -> WebSearchResponse {
        let normalizedQueries = Self.unique(queries.map(Self.normalizedQuery))
        guard !normalizedQueries.isEmpty else { return WebSearchResponse() }

        let outcomes = await withTaskGroup(of: [WebSearchResultItem].self) { group in
            for query in normalizedQueries.prefix(3) {
                group.addTask {
                    if let rss = try? await Self.searchBingRSS(query: query), !rss.isEmpty {
                        return rss
                    }
                    if let html = try? await Self.searchBingHTML(query: query, host: "www.bing.com"), !html.isEmpty {
                        return html
                    }
                    if let cnHTML = try? await Self.searchBingHTML(query: query, host: "cn.bing.com"), !cnHTML.isEmpty {
                        return cnHTML
                    }
                    if let google = try? await Self.searchGoogleHTML(query: query), !google.isEmpty {
                        return google
                    }
                    if let baidu = try? await Self.searchBaiduHTML(query: query), !baidu.isEmpty {
                        return baidu
                    }
                    if let simple = try? await Self.searchBingLite(query: query), !simple.isEmpty {
                        return simple
                    }
                    return []
                }
            }

            var collected: [WebSearchResultItem] = []
            for await items in group {
                collected.append(contentsOf: items)
            }
            return collected
        }

        let items = Array(Self.rank(
            Self.deduplicate(outcomes),
            query: originalQuery ?? normalizedQueries.first ?? ""
        ).prefix(8))
        let fetchedDocs = await Self.fetchWebDocuments(from: items)
        let docs = fetchedDocs.isEmpty ? Self.searchSummaryDocuments(from: items) : fetchedDocs
        let loadedPageCount = docs.filter { $0.metadata["provider"] == "client_search_page" }.count
        return WebSearchResponse(
            status: !items.isEmpty,
            filenames: items.compactMap(\.link),
            items: Array(items),
            docs: docs,
            loadedCount: loadedPageCount
        )
    }

    private static func searchBingRSS(query: String) async throws -> [WebSearchResultItem] {
        var components = URLComponents(string: "https://www.bing.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "setlang", value: "zh-Hans")
        ]
        guard let url = components?.url else { return [] }
        let data = try await load(url)
        return parseRSS(decodeText(data))
    }

    private static func searchBingHTML(query: String, host: String) async throws -> [WebSearchResultItem] {
        var components = URLComponents(string: "https://\(host)/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "setlang", value: "zh-Hans")
        ]
        guard let url = components?.url else { return [] }
        let data = try await load(url)
        return parseBingHTML(decodeText(data))
    }

    private static func searchBingLite(query: String) async throws -> [WebSearchResultItem] {
        var components = URLComponents(string: "https://www.bing.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "ensearch", value: "1")
        ]
        guard let url = components?.url else { return [] }
        let data = try await load(url)
        return parseGenericSearchHTML(decodeText(data), provider: "bing_lite")
    }

    private static func searchGoogleHTML(query: String) async throws -> [WebSearchResultItem] {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: "zh-CN"),
            URLQueryItem(name: "num", value: "\(maxResultsPerQuery)")
        ]
        guard let url = components?.url else { return [] }
        let data = try await load(url)
        return parseGoogleHTML(decodeText(data))
    }

    private static func searchBaiduHTML(query: String) async throws -> [WebSearchResultItem] {
        var components = URLComponents(string: "https://www.baidu.com/s")
        components?.queryItems = [
            URLQueryItem(name: "wd", value: query),
            URLQueryItem(name: "rn", value: "\(maxResultsPerQuery)")
        ]
        guard let url = components?.url else { return [] }
        let data = try await load(url)
        return parseBaiduHTML(decodeText(data))
    }

    private static func load(_ url: URL) async throws -> Data {
        let (data, _) = try await loadResponse(url, timeout: 12, resourceTimeout: 18)
        return data
    }

    private static func loadResponse(
        _ url: URL,
        timeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,application/json;q=0.7,*/*;q=0.4", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private static func fetchWebDocuments(from items: [WebSearchResultItem]) async -> [WebSearchDocument] {
        let candidates = items.enumerated().compactMap { index, item -> PageFetchCandidate? in
            guard let link = item.link,
                  let url = URL(string: link),
                  isFetchableWebURL(url),
                  !isSearchNavigationURL(link) else {
                return nil
            }
            return PageFetchCandidate(index: index, item: item, url: url)
        }.prefix(maxFetchedPages)

        guard !candidates.isEmpty else { return [] }

        let outcomes = await withTaskGroup(of: PageFetchOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        let doc = try await fetchWebDocument(candidate)
                        return PageFetchOutcome(index: candidate.index, document: doc)
                    } catch {
                        let fallback = searchSummaryDocument(from: candidate.item)
                        return PageFetchOutcome(index: candidate.index, document: fallback)
                    }
                }
            }

            var collected: [PageFetchOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected.sorted { $0.index < $1.index }
        }

        var usedCharacters = 0
        var docs: [WebSearchDocument] = []
        for outcome in outcomes {
            guard var doc = outcome.document else { continue }
            let remaining = maxCombinedDocumentCharacters - usedCharacters
            guard remaining > 400 else { break }
            if doc.content.count > remaining {
                doc.content = String(doc.content.prefix(remaining))
            }
            usedCharacters += doc.content.count
            docs.append(doc)
        }
        return docs
    }

    private static func fetchWebDocument(_ candidate: PageFetchCandidate) async throws -> WebSearchDocument {
        let (data, response) = try await loadResponse(candidate.url, timeout: 10, resourceTimeout: 16)
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard isReadableContentType(contentType, data: data) else {
            throw URLError(.cannotDecodeContentData)
        }

        let decoded = decodeText(data)
        let finalURL = response.url?.absoluteString ?? candidate.url.absoluteString
        let title: String?
        let description: String?
        let pageText: String
        let publishedTime: String?

        if contentType.contains("text/html") || decoded.localizedCaseInsensitiveContains("<html") {
            title = firstMatch(in: decoded, pattern: #"(?is)<title[^>]*>(.*?)</title>"#).map(htmlToPlainText)
                ?? candidate.item.title
            description = metaContent(in: decoded, names: ["description", "og:description", "twitter:description"])
                ?? candidate.item.snippet
            publishedTime = metaContent(in: decoded, names: [
                "article:published_time", "article:modified_time", "og:updated_time",
                "date", "pubdate", "publishdate", "publish_date"
            ])
            pageText = readableHTMLText(decoded)
        } else {
            title = candidate.item.title
            description = candidate.item.snippet
            publishedTime = nil
            pageText = cleanupMultilineText(decoded)
        }

        let excerpt = String(pageText.prefix(maxPageCharacters))
        guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        var sections: [String] = []
        if let title, !title.isEmpty { sections.append("Title: \(title)") }
        sections.append("URL: \(finalURL)")
        if let publishedTime, !publishedTime.isEmpty { sections.append("Published/Updated: \(publishedTime)") }
        if let description, !description.isEmpty { sections.append("Description: \(description)") }
        sections.append("Content excerpt:\n\(excerpt)")

        var metadata = [
            "title": title ?? candidate.item.title ?? "",
            "source": finalURL,
            "link": finalURL,
            "provider": "client_search_page"
        ].filter { !$0.value.isEmpty }
        if let publishedTime, !publishedTime.isEmpty {
            metadata["published_time"] = publishedTime
        }
        if let snippet = candidate.item.snippet, !snippet.isEmpty {
            metadata["search_snippet"] = snippet
        }

        return WebSearchDocument(
            content: sections.joined(separator: "\n"),
            metadata: metadata
        )
    }

    private static func parseRSS(_ xml: String) -> [WebSearchResultItem] {
        let items = matches(in: xml, pattern: #"(?is)<item\b[^>]*>(.*?)</item>"#)
        return items.prefix(maxResultsPerQuery).compactMap { block in
            let title = firstMatch(in: block, pattern: #"(?is)<title[^>]*>(.*?)</title>"#).map(cleanupText)
            let link = firstMatch(in: block, pattern: #"(?is)<link[^>]*>(.*?)</link>"#).map(cleanupText)
            let description = firstMatch(in: block, pattern: #"(?is)<description[^>]*>(.*?)</description>"#).map { htmlToPlainText($0) }
            return webSearchItem(title: title, link: link, snippet: description)
        }
    }

    private static func parseBingHTML(_ html: String) -> [WebSearchResultItem] {
        let blocks = matches(in: html, pattern: #"(?is)<li[^>]+class=["'][^"']*\bb_algo\b[^"']*["'][^>]*>(.*?)</li>"#)
        return blocks.prefix(maxResultsPerQuery).compactMap { block in
            let titleHTML = firstMatch(in: block, pattern: #"(?is)<h2[^>]*>\s*<a[^>]+href=["'][^"']+["'][^>]*>(.*?)</a>"#)
            let href = firstMatch(in: block, pattern: #"(?is)<h2[^>]*>\s*<a[^>]+href=["']([^"']+)["']"#)
            let snippetHTML = firstMatch(in: block, pattern: #"(?is)<p[^>]*>(.*?)</p>"#)
            return webSearchItem(
                title: titleHTML.map(htmlToPlainText),
                link: href.flatMap(normalizedBingURL),
                snippet: snippetHTML.map(htmlToPlainText)
            )
        }
    }

    private static func parseGoogleHTML(_ html: String) -> [WebSearchResultItem] {
        let blocks = matches(in: html, pattern: #"(?is)<div[^>]+class=["'][^"']*\bg\b[^"']*["'][^>]*>(.*?)</div>\s*</div>"#)
        let parsed = blocks.prefix(maxResultsPerQuery).compactMap { block -> WebSearchResultItem? in
            let href = firstMatch(in: block, pattern: #"(?is)<a[^>]+href=["'](?:/url\?q=)?([^"'&]+)[^"']*["']"#)
            let title = firstMatch(in: block, pattern: #"(?is)<h3[^>]*>(.*?)</h3>"#).map(htmlToPlainText)
            let snippet = firstMatch(in: block, pattern: #"(?is)<div[^>]+(?:data-sncf|class=["'][^"']*(?:VwiC3b|IsZvec|kb0PBd))[^>]*>(.*?)</div>"#).map(htmlToPlainText)
            return webSearchItem(title: title, link: href.flatMap(normalizedGoogleURL), snippet: snippet)
        }
        return parsed.isEmpty ? parseGenericSearchHTML(html, provider: "google") : parsed
    }

    private static func parseBaiduHTML(_ html: String) -> [WebSearchResultItem] {
        let blocks = matches(in: html, pattern: #"(?is)<div[^>]+class=["'][^"']*\bresult\b[^"']*["'][^>]*>(.*?)</div>\s*</div>"#)
        let parsed = blocks.prefix(maxResultsPerQuery).compactMap { block -> WebSearchResultItem? in
            let href = firstMatch(in: block, pattern: #"(?is)<a[^>]+href=["']([^"']+)["'][^>]*>"#)
            let title = firstMatch(in: block, pattern: #"(?is)<h3[^>]*>(.*?)</h3>"#).map(htmlToPlainText)
                ?? firstMatch(in: block, pattern: #"(?is)<a[^>]+href=["'][^"']+["'][^>]*>(.*?)</a>"#).map(htmlToPlainText)
            let snippet = firstMatch(in: block, pattern: #"(?is)<span[^>]+class=["'][^"']*(?:content-right|c-abstract|c-span-last)[^"']*["'][^>]*>(.*?)</span>"#).map(htmlToPlainText)
                ?? firstMatch(in: block, pattern: #"(?is)<div[^>]+class=["'][^"']*(?:c-abstract|c-span-last)[^"']*["'][^>]*>(.*?)</div>"#).map(htmlToPlainText)
            return webSearchItem(title: title, link: href.flatMap(normalizedBaiduURL), snippet: snippet)
        }
        return parsed.isEmpty ? parseGenericSearchHTML(html, provider: "baidu") : parsed
    }

    private static func parseGenericSearchHTML(_ html: String, provider: String) -> [WebSearchResultItem] {
        let anchors = matchGroups(in: html, pattern: #"(?is)<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>"#)
        var items: [WebSearchResultItem] = []
        for anchor in anchors {
            guard items.count < maxResultsPerQuery else { break }
            guard anchor.count >= 2 else { continue }
            let href = anchor[0]
            let title = htmlToPlainText(anchor[1])
            guard title.count >= 2,
                  let link = normalizedGenericURL(href),
                  !isSearchNavigationURL(link) else { continue }
            if let item = webSearchItem(title: title, link: link, snippet: provider) {
                items.append(item)
            }
        }
        return deduplicate(items)
    }

    private static func webSearchItem(title: String?, link: String?, snippet: String?) -> WebSearchResultItem? {
        let json: [String: Any] = [
            "title": title ?? "",
            "link": link ?? "",
            "snippet": snippet ?? ""
        ]
        return WebSearchResultItem(json: json)
    }

    private static func normalizedBingURL(_ raw: String) -> String? {
        let decoded = cleanupText(raw)
        guard let url = URL(string: decoded) else { return decoded.isEmpty ? nil : decoded }
        if url.host?.contains("bing.com") == true,
           url.path == "/ck/a",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value {
            let stripped = encoded.hasPrefix("a1") ? String(encoded.dropFirst(2)) : encoded
            if let data = Data(base64Encoded: stripped),
               let actual = String(data: data, encoding: .utf8),
               !actual.isEmpty {
                return actual
            }
        }
        return decoded
    }

    private static func normalizedGoogleURL(_ raw: String) -> String? {
        let decoded = cleanupText(raw)
        if decoded.hasPrefix("/url?"),
           let components = URLComponents(string: "https://www.google.com\(decoded)"),
           let q = components.queryItems?.first(where: { $0.name == "q" })?.value {
            return q
        }
        return normalizedGenericURL(decoded)
    }

    private static func normalizedBaiduURL(_ raw: String) -> String? {
        let decoded = cleanupText(raw)
        if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
            return decoded
        }
        if decoded.hasPrefix("/") {
            return "https://www.baidu.com\(decoded)"
        }
        return nil
    }

    private static func normalizedGenericURL(_ raw: String) -> String? {
        var decoded = cleanupText(raw)
        decoded = decoded.removingPercentEncoding ?? decoded
        if decoded.hasPrefix("//") { return "https:\(decoded)" }
        if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") { return decoded }
        return nil
    }

    private static func isSearchNavigationURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url),
              let host = parsed.host?.lowercased() else { return true }
        let blockedHosts = ["google.com", "www.google.com", "bing.com", "www.bing.com", "cn.bing.com", "baidu.com", "www.baidu.com"]
        let path = parsed.path.lowercased()
        if blockedHosts.contains(host), ["/search", "/s", "/url", "/preferences", "/advanced_search"].contains(path) {
            return true
        }
        return false
    }

    private static func isFetchableWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else { return false }

        let blockedHosts = [
            "google.com", "www.google.com", "bing.com", "www.bing.com",
            "cn.bing.com", "baidu.com", "www.baidu.com"
        ]
        if blockedHosts.contains(host), ["/search", "/s", "/url", "/ck/a"].contains(url.path.lowercased()) {
            return false
        }

        let blockedExtensions = [
            ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg",
            ".mp4", ".mov", ".m4v", ".mp3", ".zip", ".rar", ".7z", ".ipa", ".apk", ".dmg"
        ]
        let path = url.path.lowercased()
        return !blockedExtensions.contains { path.hasSuffix($0) }
    }

    private static func isReadableContentType(_ contentType: String, data: Data) -> Bool {
        if contentType.isEmpty {
            let prefix = decodeText(Data(data.prefix(512)))
            return prefix.localizedCaseInsensitiveContains("<html")
                || prefix.range(of: #"^[\s\S]{20,}"#, options: .regularExpression) != nil
        }
        return contentType.contains("text/html")
            || contentType.contains("text/plain")
            || contentType.contains("application/json")
            || contentType.contains("application/xml")
            || contentType.contains("+json")
            || contentType.contains("+xml")
    }

    private static func searchSummaryDocuments(from items: [WebSearchResultItem]) -> [WebSearchDocument] {
        items.prefix(6).compactMap(searchSummaryDocument(from:))
    }

    private static func searchSummaryDocument(from item: WebSearchResultItem) -> WebSearchDocument? {
        let content = [
            item.title.map { "Title: \($0)" },
            item.link.map { "URL: \($0)" },
            item.snippet.map { "Search snippet: \($0)" }
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return WebSearchDocument(
            content: content,
            metadata: [
                "title": item.title ?? "",
                "source": item.link ?? "",
                "link": item.link ?? "",
                "provider": "client_search_summary"
            ].filter { !$0.value.isEmpty }
        )
    }

    private static func readableHTMLText(_ html: String) -> String {
        let articleCandidates = [
            firstMatch(in: html, pattern: #"(?is)<article\b[^>]*>(.*?)</article>"#),
            firstMatch(in: html, pattern: #"(?is)<main\b[^>]*>(.*?)</main>"#),
            firstMatch(in: html, pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#)
        ]
        let selected = articleCandidates.compactMap { $0 }.max { $0.count < $1.count } ?? html
        return cleanupMultilineText(htmlToPlainText(selected))
    }

    private static func cleanupMultilineText(_ text: String) -> String {
        var value = decodeHTMLEntities(text)
        let replacements: [(String, String)] = [
            (#"\r\n?"#, "\n"),
            (#"[ \t\u{00a0}]+"#, " "),
            (#"\n{3,}"#, "\n\n")
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let lines = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count >= 2 else { return false }
                let lowered = line.lowercased()
                let boilerplate = [
                    "javascript", "cookie", "cookies", "privacy policy", "terms of use",
                    "版权所有", "隐私政策", "用户协议", "广告", "登录", "注册"
                ]
                return !boilerplate.contains { lowered == $0 || lowered.hasPrefix($0) }
            }
        return lines.joined(separator: "\n")
    }

    private static func metaContent(in html: String, names: [String]) -> String? {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let patterns = [
                #"<meta[^>]+name=["']\#(escaped)["'][^>]+content=["']([^"']*)["'][^>]*>"#,
                #"<meta[^>]+content=["']([^"']*)["'][^>]+name=["']\#(escaped)["'][^>]*>"#,
                #"<meta[^>]+property=["']\#(escaped)["'][^>]+content=["']([^"']*)["'][^>]*>"#,
                #"<meta[^>]+content=["']([^"']*)["'][^>]+property=["']\#(escaped)["'][^>]*>"#
            ]
            for pattern in patterns {
                if let value = firstMatch(in: html, pattern: pattern).map(htmlToPlainText),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        matches(in: text, pattern: pattern).first
    }

    private static func matchGroups(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsText = text as NSString
        let nsRange = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: nsRange).map { match in
            guard match.numberOfRanges > 1 else { return [] }
            return (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return "" }
                return nsText.substring(with: range)
            }
        }
    }

    private static func htmlToPlainText(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            (#"(?is)<script\b[^>]*>.*?</script>"#, " "),
            (#"(?is)<style\b[^>]*>.*?</style>"#, " "),
            (#"(?is)<br\s*/?>"#, "\n"),
            (#"(?is)</p\s*>"#, "\n"),
            (#"(?is)<[^>]+>"#, " ")
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return cleanupText(text)
    }

    private static func cleanupText(_ text: String) -> String {
        decodeHTMLEntities(text)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var value = text
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value
    }

    private static func decodeText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
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

    private static func deduplicate(_ items: [WebSearchResultItem]) -> [WebSearchResultItem] {
        var seen = Set<String>()
        var result: [WebSearchResultItem] = []
        for item in items {
            let key = (item.link ?? item.title ?? item.snippet ?? UUID().uuidString).lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(item)
        }
        return result
    }

    private static func rank(_ items: [WebSearchResultItem], query: String) -> [WebSearchResultItem] {
        let terms = query
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }

        func score(_ item: WebSearchResultItem) -> Int {
            var value = 0
            let haystack = [item.title, item.snippet, item.link]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            for term in terms where haystack.contains(term) {
                value += 3
            }
            if let link = item.link, let url = URL(string: link), isFetchableWebURL(url) {
                value += 4
            }
            if let snippet = item.snippet, snippet.count > 20 {
                value += 1
            }
            return value
        }

        return items.sorted { lhs, rhs in
            let l = score(lhs)
            let r = score(rhs)
            if l == r { return (lhs.title ?? "") < (rhs.title ?? "") }
            return l > r
        }
    }
}

private struct PageFetchCandidate: Sendable {
    let index: Int
    let item: WebSearchResultItem
    let url: URL
}

private struct PageFetchOutcome: Sendable {
    let index: Int
    let document: WebSearchDocument?
}
