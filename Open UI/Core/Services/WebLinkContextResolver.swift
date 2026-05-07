import Foundation

struct WebLinkContextResolution: Sendable {
    let context: String
    let videos: [ResolvedWebVideo]
    let successCount: Int
    let failureCount: Int

    var hasUsefulContext: Bool {
        !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !videos.isEmpty
    }
}

struct ResolvedWebVideo: Sendable, Hashable {
    let title: String
    let url: String
    let sourceURL: String
    let videoId: String?
}

struct WebLinkContextResolver: Sendable {
    private static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let maxPageCharacters = 6_000
    private static let maxCombinedCharacters = 16_000

    static func extractHTTPURLs(from text: String, limit: Int = 3) -> [URL] {
        let pattern = #"https?://[^\s<>"'\]\)）】》]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var urls: [URL] = []

        regex.enumerateMatches(in: text, range: nsRange) { match, _, stop in
            guard let match, let range = Range(match.range, in: text) else { return }
            let raw = String(text[range]).trimmingCharacters(in: Self.trailingURLTrimCharacters)
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }

            let key = url.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            urls.append(url)
            if urls.count >= limit {
                stop.pointee = true
            }
        }

        return urls
    }

    static func containsHTTPURL(_ text: String) -> Bool {
        !extractHTTPURLs(from: text, limit: 1).isEmpty
    }

    func resolve(from text: String, limit: Int = 3) async -> WebLinkContextResolution {
        let urls = Self.extractHTTPURLs(from: text, limit: limit)
        guard !urls.isEmpty else {
            return WebLinkContextResolution(context: "", videos: [], successCount: 0, failureCount: 0)
        }

        let outcomes = await withTaskGroup(of: LinkFetchOutcome.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        if Self.isDouyinURL(url) {
                            let result = try await resolveDouyin(url)
                            return LinkFetchOutcome(
                                index: index,
                                block: douyinContextBlock(result: result, index: index + 1),
                                video: result.video,
                                success: true
                            )
                        } else {
                            let page = try await resolveWebPage(url)
                            return LinkFetchOutcome(
                                index: index,
                                block: webPageContextBlock(page: page, index: index + 1),
                                video: nil,
                                success: true
                            )
                        }
                    } catch {
                        return LinkFetchOutcome(index: index, block: nil, video: nil, success: false)
                    }
                }
            }

            var collected: [LinkFetchOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected.sorted { $0.index < $1.index }
        }

        let blocks = outcomes.compactMap(\.block)
        let videos = outcomes.compactMap(\.video)
        let successCount = outcomes.filter(\.success).count
        let failureCount = outcomes.count - successCount

        let context = blocks.joined(separator: "\n\n")
        return WebLinkContextResolution(
            context: String(context.prefix(Self.maxCombinedCharacters)),
            videos: videos,
            successCount: successCount,
            failureCount: failureCount
        )
    }

    private func resolveWebPage(_ url: URL) async throws -> WebPageResult {
        let (data, response) = try await load(url, mobile: false)
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let decoded = Self.decodeText(data)

        if contentType.contains("text/html") || decoded.localizedCaseInsensitiveContains("<html") {
            let title = Self.firstMatch(in: decoded, pattern: #"<title[^>]*>(.*?)</title>"#)
                .map(Self.cleanupText)
            let description = Self.metaContent(in: decoded, name: "description")
                .map(Self.cleanupText)
            let body = Self.htmlToPlainText(decoded)
            return WebPageResult(
                url: response.url?.absoluteString ?? url.absoluteString,
                title: title,
                description: description,
                text: String(body.prefix(Self.maxPageCharacters))
            )
        }

        guard contentType.contains("text/")
                || contentType.contains("application/json")
                || contentType.contains("application/xml")
                || contentType.contains("+json")
                || contentType.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }

        return WebPageResult(
            url: response.url?.absoluteString ?? url.absoluteString,
            title: nil,
            description: nil,
            text: String(Self.cleanupText(decoded).prefix(Self.maxPageCharacters))
        )
    }

    private func resolveDouyin(_ url: URL) async throws -> DouyinResolveResult {
        let (_, shareResponse) = try await load(url, mobile: true)
        let finalURL = shareResponse.url ?? url
        let videoId = Self.videoId(from: finalURL) ?? Self.videoId(from: url)
        let pageURL = videoId
            .flatMap { URL(string: "https://www.iesdouyin.com/share/video/\($0)") }
            ?? finalURL

        let (data, _) = try await load(pageURL, mobile: true)
        let html = Self.decodeText(data)
        guard let routerJSON = Self.routerDataJSON(from: html),
              let item = Self.firstVideoItem(in: routerJSON) else {
            throw URLError(.cannotParseResponse)
        }

        let parsedVideoId = videoId ?? (item["aweme_id"] as? String) ?? (item["id"] as? String)
        let title = Self.cleanupText((item["desc"] as? String) ?? "douyin_\(parsedVideoId ?? UUID().uuidString)")
        let author = (item["author"] as? [String: Any]).flatMap { author -> String? in
            (author["nickname"] as? String) ?? (author["unique_id"] as? String)
        }

        guard let video = item["video"] as? [String: Any],
              let playAddr = video["play_addr"] as? [String: Any],
              let urlList = playAddr["url_list"] as? [String],
              let firstURL = urlList.first else {
            throw URLError(.cannotParseResponse)
        }

        let mp4URL = firstURL.replacingOccurrences(of: "playwm", with: "play")
        let resolvedVideo = ResolvedWebVideo(
            title: Self.safeVideoFileName(title),
            url: mp4URL,
            sourceURL: url.absoluteString,
            videoId: parsedVideoId
        )

        return DouyinResolveResult(
            sourceURL: url.absoluteString,
            pageURL: pageURL.absoluteString,
            video: resolvedVideo,
            title: title,
            author: author,
            description: title,
            videoId: parsedVideoId
        )
    }

    private func load(_ url: URL, mobile: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue(mobile ? Self.mobileUserAgent : Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private func webPageContextBlock(page: WebPageResult, index: Int) -> String {
        var lines = [
            "### Link \(index): Web Page",
            "URL: \(page.url)"
        ]
        if let title = page.title, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        if let description = page.description, !description.isEmpty {
            lines.append("Description: \(description)")
        }
        if !page.text.isEmpty {
            lines.append("Content excerpt:\n\(page.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func douyinContextBlock(result: DouyinResolveResult, index: Int) -> String {
        var lines = [
            "### Link \(index): Douyin Video",
            "Original URL: \(result.sourceURL)",
            "Resolved page: \(result.pageURL)"
        ]
        if let videoId = result.videoId {
            lines.append("Video ID: \(videoId)")
        }
        if let author = result.author, !author.isEmpty {
            lines.append("Author: \(author)")
        }
        lines.append("Title/description: \(result.description)")
        lines.append("MP4 URL: \(result.video.url)")
        lines.append("Client note: the MP4 is attached to this assistant response when possible. The parsed page supplied title/description metadata; no audio transcript is available unless the user provides or enables transcription separately.")
        return lines.joined(separator: "\n")
    }

    private static func isDouyinURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("douyin.com")
            || host.contains("iesdouyin.com")
            || host.contains("amemv.com")
    }

    private static func videoId(from url: URL) -> String? {
        let numeric = url.pathComponents.reversed().first { component in
            component.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil
        }
        if let numeric { return numeric }
        return url.pathComponents.last?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func routerDataJSON(from html: String) -> Any? {
        guard let raw = firstMatch(in: html, pattern: #"window\._ROUTER_DATA\s*=\s*(.*?)</script>"#) else {
            return nil
        }
        let jsonString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func firstVideoItem(in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let list = dict["item_list"] as? [[String: Any]], let first = list.first {
                return first
            }
            if let detail = dict["aweme_detail"] as? [String: Any] {
                return detail
            }
            for value in dict.values {
                if let found = firstVideoItem(in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = firstVideoItem(in: item) {
                    return found
                }
            }
        }
        return nil
    }

    private static func htmlToPlainText(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            (#"(?is)<script\b[^>]*>.*?</script>"#, " "),
            (#"(?is)<style\b[^>]*>.*?</style>"#, " "),
            (#"(?is)<noscript\b[^>]*>.*?</noscript>"#, " "),
            (#"(?is)<svg\b[^>]*>.*?</svg>"#, " "),
            (#"(?is)<br\s*/?>"#, "\n"),
            (#"(?is)</p\s*>"#, "\n"),
            (#"(?is)</div\s*>"#, "\n"),
            (#"(?is)<[^>]+>"#, " ")
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return cleanupText(decodeHTMLEntities(text))
    }

    private static func metaContent(in html: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            #"<meta[^>]+name=["']\#(escaped)["'][^>]+content=["']([^"']*)["'][^>]*>"#,
            #"<meta[^>]+content=["']([^"']*)["'][^>]+name=["']\#(escaped)["'][^>]*>"#,
            #"<meta[^>]+property=["']og:\#(escaped)["'][^>]+content=["']([^"']*)["'][^>]*>"#,
            #"<meta[^>]+content=["']([^"']*)["'][^>]+property=["']og:\#(escaped)["'][^>]*>"#
        ]
        for pattern in patterns {
            if let match = firstMatch(in: html, pattern: pattern) {
                return decodeHTMLEntities(match)
            }
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func decodeText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
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

    private static func safeVideoFileName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"[\\/:*?"<>|]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "douyin-video" : String(cleaned.prefix(80))
        return base.lowercased().hasSuffix(".mp4") ? base : "\(base).mp4"
    }

    private static var trailingURLTrimCharacters: CharacterSet {
        CharacterSet(charactersIn: ".,!?;:，。！？；：、")
    }
}

private struct WebPageResult {
    let url: String
    let title: String?
    let description: String?
    let text: String
}

private struct LinkFetchOutcome {
    let index: Int
    let block: String?
    let video: ResolvedWebVideo?
    let success: Bool
}

private struct DouyinResolveResult {
    let sourceURL: String
    let pageURL: String
    let video: ResolvedWebVideo
    let title: String
    let author: String?
    let description: String
    let videoId: String?
}
