import Foundation

struct WebLinkContextResolution: Sendable {
    let context: String
    let videos: [ResolvedWebVideo]
    let images: [ResolvedWebImage]
    let successCount: Int
    let failureCount: Int

    var hasUsefulContext: Bool {
        !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !videos.isEmpty || !images.isEmpty
    }
}

struct ResolvedWebVideo: Sendable, Hashable, Identifiable {
    let title: String
    let url: String
    let sourceURL: String
    let videoId: String?

    var id: String { url }
}

struct ResolvedWebImage: Sendable, Hashable, Identifiable {
    let title: String
    let url: String
    let sourceURL: String
    let imageId: String?
    let index: Int

    var id: String { "\(url)#\(index)" }
}

struct ResolvedDouyinPost: Sendable, Hashable {
    let sourceURL: String
    let pageURL: String
    let video: ResolvedWebVideo?
    let images: [ResolvedWebImage]
    let title: String
    let author: String?
    let description: String
    let videoId: String?

    var hasMedia: Bool {
        video != nil || !images.isEmpty
    }
}

struct ResolvedXiaohongshuPost: Sendable, Hashable {
    let sourceURL: String
    let pageURL: String
    let video: ResolvedWebVideo?
    let videoCandidates: [ResolvedWebVideo]
    let images: [ResolvedWebImage]
    let title: String
    let author: String?
    let description: String
    let noteId: String?

    var hasMedia: Bool {
        video != nil || !videoCandidates.isEmpty || !images.isEmpty
    }
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

    func resolveDouyinVideo(_ url: URL) async throws -> ResolvedWebVideo {
        let result = try await resolveDouyin(url)
        guard let video = result.video else {
            throw URLError(.cannotParseResponse)
        }
        return video
    }

    func resolveDouyinPost(_ url: URL) async throws -> ResolvedDouyinPost {
        try await resolveDouyin(url)
    }

    func resolveXiaohongshuVideo(_ url: URL) async throws -> ResolvedWebVideo {
        let result = try await resolveXiaohongshu(url)
        guard let video = result.video else {
            throw URLError(.cannotParseResponse)
        }
        return video
    }

    func resolveXiaohongshuPost(_ url: URL) async throws -> ResolvedXiaohongshuPost {
        try await resolveXiaohongshu(url)
    }

    func resolve(from text: String, limit: Int = 3) async -> WebLinkContextResolution {
        let urls = Self.extractHTTPURLs(from: text, limit: limit)
        guard !urls.isEmpty else {
            return WebLinkContextResolution(context: "", videos: [], images: [], successCount: 0, failureCount: 0)
        }

        let outcomes = await withTaskGroup(of: LinkFetchOutcome.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        if Self.isDouyinURL(url) {
                            let result = try await self.resolveDouyin(url)
                            return LinkFetchOutcome(
                                index: index,
                                block: self.douyinContextBlock(result: result, index: index + 1),
                                video: result.video,
                                images: result.images,
                                success: true
                            )
                        } else if Self.isXiaohongshuURL(url) {
                            let result = try await self.resolveXiaohongshu(url)
                            return LinkFetchOutcome(
                                index: index,
                                block: self.xiaohongshuContextBlock(result: result, index: index + 1),
                                video: result.video,
                                images: result.images,
                                success: true
                            )
                        } else {
                            let page = try await self.resolveWebPage(url)
                            return LinkFetchOutcome(
                                index: index,
                                block: self.webPageContextBlock(page: page, index: index + 1),
                                video: nil,
                                images: [],
                                success: true
                            )
                        }
                    } catch {
                        return LinkFetchOutcome(index: index, block: nil, video: nil, images: [], success: false)
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
        let images = outcomes.flatMap(\.images)
        let successCount = outcomes.filter(\.success).count
        let failureCount = outcomes.count - successCount

        let context = blocks.joined(separator: "\n\n")
        return WebLinkContextResolution(
            context: String(context.prefix(Self.maxCombinedCharacters)),
            videos: videos,
            images: images,
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

    private func resolveDouyin(_ url: URL) async throws -> ResolvedDouyinPost {
        let (_, shareResponse) = try await load(url, mobile: true)
        let finalURL = shareResponse.url ?? url
        let videoId = Self.videoId(from: finalURL) ?? Self.videoId(from: url)
        let itemType = Self.douyinItemType(from: finalURL) ?? Self.douyinItemType(from: url) ?? "video"
        let pageURL = videoId
            .flatMap { URL(string: "https://www.iesdouyin.com/share/\(itemType)/\($0)") }
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

        let resolvedVideo: ResolvedWebVideo?
        if let video = item["video"] as? [String: Any],
           let playAddr = video["play_addr"] as? [String: Any],
           let urlList = playAddr["url_list"] as? [String],
           let firstURL = urlList.first {
            let mp4URL = firstURL.replacingOccurrences(of: "playwm", with: "play")
            resolvedVideo = ResolvedWebVideo(
                title: Self.safeVideoFileName(title),
                url: mp4URL,
                sourceURL: url.absoluteString,
                videoId: parsedVideoId
            )
        } else {
            resolvedVideo = nil
        }

        let images = Self.resolvedImages(
            from: item,
            title: title,
            sourceURL: url.absoluteString,
            videoId: parsedVideoId
        )

        guard resolvedVideo != nil || !images.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        return ResolvedDouyinPost(
            sourceURL: url.absoluteString,
            pageURL: pageURL.absoluteString,
            video: resolvedVideo,
            images: images,
            title: title,
            author: author,
            description: title,
            videoId: parsedVideoId
        )
    }

    private func resolveXiaohongshu(_ url: URL) async throws -> ResolvedXiaohongshuPost {
        let (initialData, initialResponse) = try await load(url, mobile: true)
        var pageURL = initialResponse.url ?? url
        var html = Self.decodeText(initialData)

        if Self.isXiaohongshuShortURL(pageURL),
           let embeddedURL = Self.firstEmbeddedXiaohongshuPageURL(in: html) {
            let (pageData, pageResponse) = try await load(embeddedURL, mobile: true)
            pageURL = pageResponse.url ?? embeddedURL
            html = Self.decodeText(pageData)
        }

        let noteId = Self.xiaohongshuNoteId(from: pageURL) ?? Self.xiaohongshuNoteId(from: url)
        let jsonObjects = Self.xiaohongshuJSONObjects(from: html)
        let noteObject = jsonObjects.compactMap { Self.xiaohongshuNoteObject(in: $0, noteId: noteId) }.first
        let primaryObject: Any? = noteObject ?? jsonObjects.first

        let rawTitle = primaryObject.flatMap { Self.firstUsefulString(in: $0, keys: ["title", "desc", "description", "content"]) }
            ?? Self.metaContent(in: html, name: "title")
            ?? Self.metaContent(in: html, name: "description")
            ?? Self.firstMatch(in: html, pattern: #"<title[^>]*>(.*?)</title>"#)
            ?? "xiaohongshu_\(noteId ?? UUID().uuidString)"
        let title = Self.cleanupText(rawTitle)
        let description = Self.cleanupText(
            primaryObject.flatMap { Self.firstUsefulString(in: $0, keys: ["desc", "description", "content", "title"]) }
                ?? title
        )
        let author = primaryObject.flatMap { Self.firstUsefulString(in: $0, keys: ["nickname", "nickName", "userName", "authorName"]) }
            .map(Self.cleanupText)

        var originalVideoCandidates: [String] = []
        var detectedVideoCandidates: [String] = []
        if let noteObject {
            originalVideoCandidates.append(contentsOf: Self.generatedXiaohongshuOriginVideoURLs(in: noteObject))
            detectedVideoCandidates.append(contentsOf: originalVideoCandidates)
            detectedVideoCandidates.append(contentsOf: Self.preferredXiaohongshuStreamURLs(in: noteObject))
            detectedVideoCandidates.append(contentsOf: Self.xiaohongshuURLs(in: noteObject, kind: .video))
        } else {
            for object in jsonObjects {
                let originURLs = Self.generatedXiaohongshuOriginVideoURLs(in: object)
                originalVideoCandidates.append(contentsOf: originURLs)
                detectedVideoCandidates.append(contentsOf: originURLs)
                detectedVideoCandidates.append(contentsOf: Self.preferredXiaohongshuStreamURLs(in: object))
                detectedVideoCandidates.append(contentsOf: Self.xiaohongshuURLs(in: object, kind: .video))
            }
        }
        if detectedVideoCandidates.isEmpty {
            detectedVideoCandidates.append(contentsOf: Self.mediaURLCandidates(in: html, kind: .video))
        }

        var videoCandidates: [String] = []
        if !detectedVideoCandidates.isEmpty,
           let downloadProxyURL = Self.xiaohongshuDownloadProxyURL(
                sourceURL: pageURL.absoluteString,
                title: title
           ) {
            videoCandidates.append(downloadProxyURL)
        }
        videoCandidates.append(contentsOf: originalVideoCandidates)
        videoCandidates = Self.sortedXiaohongshuVideoURLs(Self.uniqueMediaURLs(videoCandidates, preservingQuery: true))

        let resolvedVideos = videoCandidates.map { mediaURL in
            ResolvedWebVideo(
                title: Self.safeVideoFileName(title, fallback: "xiaohongshu-video"),
                url: mediaURL,
                sourceURL: url.absoluteString,
                videoId: noteId
            )
        }
        let resolvedVideo = resolvedVideos.first

        let imageCandidates = noteObject.map {
            Self.xiaohongshuOriginalImageURLs(in: $0)
        } ?? []
        let images = Self.resolvedXiaohongshuImages(
            from: Self.uniqueMediaURLs(imageCandidates),
            title: title,
            sourceURL: url.absoluteString,
            noteId: noteId
        )

        guard resolvedVideo != nil || !images.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        return ResolvedXiaohongshuPost(
            sourceURL: url.absoluteString,
            pageURL: pageURL.absoluteString,
            video: resolvedVideo,
            videoCandidates: resolvedVideos,
            images: images,
            title: title,
            author: author,
            description: description,
            noteId: noteId
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

    private func douyinContextBlock(result: ResolvedDouyinPost, index: Int) -> String {
        var lines = [
            result.images.isEmpty ? "### Link \(index): Douyin Video" : "### Link \(index): Douyin Image Post",
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
        if let video = result.video {
            lines.append("MP4 URL: \(video.url)")
        }
        if !result.images.isEmpty {
            lines.append("Image count: \(result.images.count)")
            for image in result.images.prefix(20) {
                lines.append("Image \(image.index): \(image.url)")
            }
        }
        lines.append("Client note: parsed Douyin media is attached to this assistant response when possible. Image posts can include multiple image URLs; video posts include an MP4 URL. No audio transcript is available unless the user provides or enables transcription separately.")
        return lines.joined(separator: "\n")
    }

    private func xiaohongshuContextBlock(result: ResolvedXiaohongshuPost, index: Int) -> String {
        var lines = [
            result.images.isEmpty ? "### Link \(index): Xiaohongshu Video" : "### Link \(index): Xiaohongshu Image Post",
            "Original URL: \(result.sourceURL)",
            "Resolved page: \(result.pageURL)"
        ]
        if let noteId = result.noteId {
            lines.append("Note ID: \(noteId)")
        }
        if let author = result.author, !author.isEmpty {
            lines.append("Author: \(author)")
        }
        lines.append("Title/description: \(result.description)")
        if let video = result.video {
            lines.append("Video URL: \(video.url)")
        }
        if !result.images.isEmpty {
            lines.append("Image count: \(result.images.count)")
            for image in result.images.prefix(20) {
                lines.append("Image \(image.index): \(image.url)")
            }
        }
        lines.append("Client note: parsed Xiaohongshu media is attached to this assistant response when possible. Image posts can include multiple image URLs; video posts include a playable video URL when the page exposes one.")
        return lines.joined(separator: "\n")
    }

    static func isDouyinURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("douyin.com")
            || host.contains("iesdouyin.com")
            || host.contains("amemv.com")
    }

    static func isXiaohongshuURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("xiaohongshu.com")
            || host.contains("xhslink.com")
            || host.contains("rednote.com")
    }

    private static func isXiaohongshuShortURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("xhslink.com")
    }

    private static func videoId(from url: URL) -> String? {
        let numeric = url.pathComponents.reversed().first { component in
            component.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil
        }
        if let numeric { return numeric }
        return url.pathComponents.last?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func douyinItemType(from url: URL) -> String? {
        let components = url.pathComponents.map { $0.lowercased() }
        if components.contains("note") { return "note" }
        if components.contains("video") { return "video" }
        return nil
    }

    private enum XiaohongshuMediaKind {
        case video
        case image
    }

    private static func xiaohongshuNoteId(from url: URL) -> String? {
        for component in url.pathComponents.reversed() {
            let cleaned = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleaned.isEmpty else { continue }
            if cleaned.range(of: #"^[0-9a-fA-F]{16,40}$"#, options: .regularExpression) != nil {
                return cleaned
            }
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for name in ["note_id", "noteId", "id"] {
                if let value = components.queryItems?.first(where: { $0.name == name })?.value,
                   value.range(of: #"^[0-9a-fA-F]{16,40}$"#, options: .regularExpression) != nil {
                    return value
                }
            }
        }
        return nil
    }

    private static func firstEmbeddedXiaohongshuPageURL(in html: String) -> URL? {
        mediaURLStrings(in: normalizedEmbeddedText(html))
            .compactMap(URL.init(string:))
            .first { url in
                guard isXiaohongshuURL(url), !isXiaohongshuShortURL(url) else { return false }
                let path = url.path.lowercased()
                return path.contains("/explore/")
                    || path.contains("/discovery/item/")
                    || path.contains("/search_result/")
            }
    }

    private static func xiaohongshuJSONObjects(from html: String) -> [Any] {
        let patterns = [
            #"window\.__INITIAL_STATE__\s*=\s*(\{.*?\})\s*;?\s*</script>"#,
            #"window\.__INITIAL_SSR_STATE__\s*=\s*(\{.*?\})\s*;?\s*</script>"#,
            #"window\.__SETUP_SERVER_STATE__\s*=\s*(\{.*?\})\s*;?\s*</script>"#,
            #"<script[^>]+id=["']__NEXT_DATA__["'][^>]*>\s*(\{.*?\})\s*</script>"#
        ]

        var objects: [Any] = []
        for pattern in patterns {
            for raw in matches(in: html, pattern: pattern) {
                if let object = jsonObject(fromJavaScriptObjectLiteral: raw) {
                    objects.append(object)
                }
            }
        }
        return objects
    }

    private static func jsonObject(fromJavaScriptObjectLiteral raw: String) -> Any? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"(?<=[:\[,])\s*undefined(?=\s*[,}\]])"#, with: "null", options: .regularExpression)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func xiaohongshuNoteObject(in object: Any, noteId: String?) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let noteId,
               let detailMap = dict["noteDetailMap"] as? [String: Any],
               let detail = detailMap[noteId] as? [String: Any] {
                if let note = detail["note"] as? [String: Any] {
                    return note
                }
                return detail
            }

            let idValue = (dict["noteId"] as? String) ?? (dict["id"] as? String)
            let hasNoteShape = dict["imageList"] != nil
                || dict["video"] != nil
                || dict["videoInfo"] != nil
                || dict["media"] != nil
            if hasNoteShape, noteId == nil || idValue == noteId {
                return dict
            }

            if let note = dict["note"] as? [String: Any],
               let found = xiaohongshuNoteObject(in: note, noteId: noteId) {
                return found
            }

            for value in dict.values {
                if let found = xiaohongshuNoteObject(in: value, noteId: noteId) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = xiaohongshuNoteObject(in: item, noteId: noteId) {
                    return found
                }
            }
        }
        return nil
    }

    private static func firstUsefulString(in object: Any, keys: [String]) -> String? {
        if let dict = object as? [String: Any] {
            for key in keys {
                if let value = dict[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            for value in dict.values {
                if let found = firstUsefulString(in: value, keys: keys) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = firstUsefulString(in: item, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private static func xiaohongshuURLs(in object: Any, kind: XiaohongshuMediaKind) -> [String] {
        var urls: [String] = []

        func walk(_ value: Any) {
            if let string = value as? String {
                urls.append(contentsOf: mediaURLCandidates(in: string, kind: kind))
                return
            }

            if let list = value as? [Any] {
                for item in list {
                    walk(item)
                }
                return
            }

            if let dict = value as? [String: Any] {
                for value in dict.values {
                    walk(value)
                }
            }
        }

        walk(object)
        return uniqueMediaURLs(urls, preservingQuery: kind == .video)
    }

    private static func xiaohongshuOriginalImageURLs(in note: [String: Any]) -> [String] {
        let urls = xiaohongshuImageList(in: note).compactMap { image -> String? in
            guard let selected = selectedXiaohongshuImageURL(from: image) else { return nil }
            return originalXiaohongshuImageURL(from: selected)
        }.filter {
            isCanonicalXiaohongshuImageURL($0)
        }
        return uniqueMediaURLs(urls)
    }

    private static func xiaohongshuImageList(in note: [String: Any]) -> [[String: Any]] {
        if let list = note["imageList"] as? [[String: Any]] {
            return list
        }
        if let list = note["imageList"] as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        if let list = note["images"] as? [[String: Any]] {
            return list
        }
        if let list = note["images"] as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        if let image = note["image"] as? [String: Any] {
            return [image]
        }
        return []
    }

    private static func selectedXiaohongshuImageURL(from image: [String: Any]) -> String? {
        if let url = image["urlDefault"] as? String, !url.isEmpty {
            return url
        }
        if let url = image["url"] as? String, !url.isEmpty {
            return url
        }

        let infoList: [[String: Any]]
        if let list = image["infoList"] as? [[String: Any]] {
            infoList = list
        } else if let list = image["infoList"] as? [Any] {
            infoList = list.compactMap { $0 as? [String: Any] }
        } else {
            infoList = []
        }

        if let preferred = infoList.first(where: { info in
            let scene = ((info["imageScene"] as? String) ?? (info["scene"] as? String) ?? (info["type"] as? String) ?? "")
                .lowercased()
            return scene.range(of: #"(origin|original|default|dft|wb_dft)"#, options: .regularExpression) != nil
                && ((info["url"] as? String)?.isEmpty == false)
        }),
           let url = preferred["url"] as? String {
            return url
        }

        if let first = infoList.first(where: { (($0["url"] as? String)?.isEmpty == false) }),
           let url = first["url"] as? String {
            return url
        }

        if let traceId = image["traceId"] as? String, !traceId.isEmpty {
            return "https://ci.xiaohongshu.com/\(traceId)"
        }
        return nil
    }

    private static func originalXiaohongshuImageURL(from rawURL: String) -> String {
        let normalized = normalizedXiaohongshuMediaURLProtocol(normalizedEmbeddedText(rawURL))
        let lower = normalized.lowercased()
        guard lower.contains("xhscdn.com"),
              !lower.contains("video"),
              let url = URL(string: normalized) else {
            return normalized
        }

        let tokenPath = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(whereSeparator: { $0 == "!" || $0 == "?" })
            .first
            .map(String.init) ?? ""
        let segments = tokenPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let mediaToken = segments.count >= 3 ? segments.dropFirst(2).joined(separator: "/") : tokenPath
        guard !mediaToken.isEmpty else { return normalized }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "ci.xiaohongshu.com"
        components.path = "/\(mediaToken)"
        return components.url?.absoluteString ?? "https://ci.xiaohongshu.com/\(mediaToken)"
    }

    private static func isCanonicalXiaohongshuImageURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "ci.xiaohongshu.com",
              !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            return false
        }
        return !isXiaohongshuVideoURL(rawURL)
    }

    private static func normalizedXiaohongshuMediaURLProtocol(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              host == "ci.xiaohongshu.com" || host.hasSuffix(".xhscdn.com") || host == "xhscdn.com" else {
            return rawURL
        }
        components.scheme = "https"
        return components.url?.absoluteString ?? rawURL
    }

    private static func generatedXiaohongshuOriginVideoURLs(in object: Any) -> [String] {
        var urls: [String] = []

        func appendOriginVideoKey(_ raw: String) {
            let key = normalizedEmbeddedText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            if key.hasPrefix("http://") || key.hasPrefix("https://") {
                urls.append(key)
            } else {
                urls.append("https://sns-video-bd.xhscdn.com/\(key.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
            }
        }

        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let key = dict["originVideoKey"] as? String {
                    appendOriginVideoKey(key)
                }
                for nested in dict.values {
                    walk(nested)
                }
            } else if let list = value as? [Any] {
                for item in list {
                    walk(item)
                }
            }
        }

        walk(object)
        return uniqueMediaURLs(urls, preservingQuery: true)
    }

    private static func preferredXiaohongshuStreamURLs(in object: Any) -> [String] {
        var items: [(score: Int, order: Int, urls: [String])] = []
        var order = 0

        func intValue(_ value: Any?) -> Int {
            if let value = value as? Int { return value }
            if let value = value as? Double { return Int(value) }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) ?? 0 }
            return 0
        }

        func normalizedURLStrings(_ value: Any?) -> [String] {
            if let string = value as? String {
                return mediaURLCandidates(in: string, kind: .video)
            }
            if let list = value as? [String] {
                return list.flatMap { mediaURLCandidates(in: $0, kind: .video) }
            }
            if let list = value as? [Any] {
                return list.compactMap { $0 as? String }.flatMap { mediaURLCandidates(in: $0, kind: .video) }
            }
            return []
        }

        func appendStreamItem(_ dict: [String: Any]) {
            let backupURLs = normalizedURLStrings(dict["backupUrls"] ?? dict["backup_urls"])
            let masterURLs = normalizedURLStrings(dict["masterUrl"] ?? dict["master_url"])
            let urls = backupURLs + masterURLs
            guard !urls.isEmpty else { return }

            let codec = (dict["videoCodec"] as? String)?.lowercased() ?? ""
            let streamType = intValue(dict["streamType"])
            var score = 0
            score += intValue(dict["height"])
            score += intValue(dict["width"]) / 2
            score += intValue(dict["videoBitrate"]) / 1_000
            score += intValue(dict["size"]) / 10_000
            if codec.contains("h264") || codec.contains("avc") {
                score += 5_000
            }
            if streamType == 259 {
                score += 2_000
            }
            items.append((score, order, urls))
            order += 1
        }

        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if dict["backupUrls"] != nil
                    || dict["backup_urls"] != nil
                    || dict["masterUrl"] != nil
                    || dict["master_url"] != nil
                {
                    appendStreamItem(dict)
                }
                for nested in dict.values {
                    walk(nested)
                }
            } else if let list = value as? [Any] {
                for item in list {
                    walk(item)
                }
            }
        }

        walk(object)
        let ordered = items.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }
        return uniqueMediaURLs(ordered.flatMap { $0.urls }, preservingQuery: true)
    }

    private static func mediaURLCandidates(in text: String, kind: XiaohongshuMediaKind) -> [String] {
        mediaURLStrings(in: normalizedEmbeddedText(text)).filter { raw in
            let lower = raw.lowercased()
            switch kind {
            case .video:
                return lower.contains("sns-video")
                    || lower.contains("xhs-video")
                    || lower.contains("xhscdn.com/spectrum")
                    || lower.contains(".mp4")
                    || (lower.contains("xhscdn.com") && lower.contains("video"))
            case .image:
                guard !isXiaohongshuVideoURL(raw) else { return false }
                return lower.contains("sns-img")
                    || lower.contains("sns-webpic")
                    || lower.contains("imageview2")
                    || lower.contains(".jpg")
                    || lower.contains(".jpeg")
                    || lower.contains(".png")
                    || lower.contains(".webp")
                    || lower.contains(".avif")
            }
        }
    }

    private static func isXiaohongshuVideoURL(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("sns-video")
            || lower.contains("xhs-video")
            || lower.contains("xhscdn.com/spectrum")
            || lower.contains(".mp4")
    }

    private static func mediaURLStrings(in text: String) -> [String] {
        let pattern = #"https?://[^\s"'<>\\\]\[{}]+"#
        let trimmingCharacters = trailingURLTrimCharacters.union(CharacterSet(charactersIn: "\"'`),;"))
        return matches(in: text, pattern: pattern).map { raw in
            raw.trimmingCharacters(in: trimmingCharacters)
        }
    }

    private static func normalizedEmbeddedText(_ text: String) -> String {
        var value = decodeHTMLEntities(text)
        let replacements: [(String, String)] = [
            ("\\u002F", "/"),
            ("\\u002f", "/"),
            ("\\/", "/"),
            ("\\u003A", ":"),
            ("\\u003a", ":"),
            ("\\u0026", "&"),
            ("\\u003D", "="),
            ("\\u003d", "="),
            ("\\u003F", "?"),
            ("\\u003f", "?")
        ]
        for (needle, replacement) in replacements {
            value = value.replacingOccurrences(of: needle, with: replacement)
        }
        return value
    }

    private static func uniqueMediaURLs(_ urls: [String], preservingQuery: Bool = false) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in urls {
            let normalized = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\u0026", with: "&")
            guard let url = URL(string: normalized),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            let key = canonicalMediaURLKey(normalized, preservingQuery: preservingQuery)
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private static func sortedXiaohongshuVideoURLs(_ urls: [String]) -> [String] {
        urls.enumerated()
            .sorted { left, right in
                let leftRank = xiaohongshuVideoURLRank(left.element)
                let rightRank = xiaohongshuVideoURLRank(right.element)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private static func xiaohongshuVideoURLRank(_ raw: String) -> Int {
        let lower = raw.lowercased()
        var rank = 50
        if lower.contains("downloader-api.bhwa233.com/api/download") {
            rank -= 60
        } else if lower.contains("sns-video-bd.xhscdn.com") {
            rank -= 45
        } else if lower.contains("sns-video-v") && lower.contains(".mp4") && lower.contains("?") {
            rank -= 35
        } else if lower.contains("sns-bak") {
            rank -= 25
        } else if lower.contains("sns-video-v2.xhscdn.com") {
            rank -= 20
        } else if lower.contains("sns-video") || lower.contains("xhs-video") {
            rank -= 15
        }
        if lower.contains("/259/") || lower.contains("_259.mp4") {
            rank -= 10
        }
        if lower.contains("sns-video-v") && lower.contains(".mp4") && !lower.contains("?") {
            rank += 80
        }
        if lower.contains("watermark") || lower.contains("wm") {
            rank += 30
        }
        return rank
    }

    private static func xiaohongshuDownloadProxyURL(sourceURL: String, title: String) -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "downloader-api.bhwa233.com"
        components.path = "/api/download"
        components.queryItems = [
            URLQueryItem(name: "url", value: sourceURL),
            URLQueryItem(name: "raw", value: "1"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "filename", value: safeBaseFileName(title, fallback: "xiaohongshu-video"))
        ]
        return components.url?.absoluteString
    }

    private static func resolvedXiaohongshuImages(
        from urls: [String],
        title: String,
        sourceURL: String,
        noteId: String?
    ) -> [ResolvedWebImage] {
        let baseTitle = safeBaseFileName(title, fallback: "xiaohongshu-image")
        return urls.prefix(40).enumerated().map { offset, url in
            let ext = imageFileExtension(from: url)
            return ResolvedWebImage(
                title: "\(baseTitle)-\(offset + 1).\(ext)",
                url: url,
                sourceURL: sourceURL,
                imageId: noteId,
                index: offset + 1
            )
        }
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

    private static func resolvedImages(
        from item: [String: Any],
        title: String,
        sourceURL: String,
        videoId: String?
    ) -> [ResolvedWebImage] {
        let imageContainers = [
            item["images"],
            (item["aweme_detail"] as? [String: Any])?["images"]
        ]

        var urls: [String] = []
        var seenImageKeys = Set<String>()
        for container in imageContainers {
            guard let images = container as? [[String: Any]] else { continue }
            for image in images {
                guard let selectedURL = imageURLCandidates(from: image).first else { continue }
                let imageKey = imageDeduplicationKey(from: image, selectedURL: selectedURL)
                if seenImageKeys.insert(imageKey).inserted {
                    urls.append(selectedURL)
                }
            }
        }

        let baseTitle = safeBaseFileName(title, fallback: "douyin-image")
        return urls.enumerated().map { offset, url in
            let ext = imageFileExtension(from: url)
            let imageTitle = "\(baseTitle)-\(offset + 1).\(ext)"
            return ResolvedWebImage(
                title: imageTitle,
                url: url,
                sourceURL: sourceURL,
                imageId: videoId,
                index: offset + 1
            )
        }
    }

    private static func imageDeduplicationKey(from image: [String: Any], selectedURL: String) -> String {
        for value in imageIdentityCandidates(from: image) {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\u0026", with: "&")
            guard !normalized.isEmpty else { continue }
            return "id:\(normalized.lowercased())"
        }
        return "url:\(canonicalImageURLKey(selectedURL))"
    }

    private static func imageIdentityCandidates(from image: [String: Any]) -> [String] {
        var values: [String] = []
        for key in ["uri", "id", "image_id", "imageId", "oid", "url_key", "urlKey"] {
            if let value = image[key] as? String, !value.isEmpty {
                values.append(value)
            }
        }
        for key in ["download_addr", "origin_url", "large", "cover"] {
            if let nested = image[key] as? [String: Any],
               let uri = nested["uri"] as? String,
               !uri.isEmpty {
                values.append(uri)
            }
        }
        return values
    }

    private static func canonicalImageURLKey(_ raw: String) -> String {
        canonicalMediaURLKey(raw, preservingQuery: false)
    }

    private static func canonicalMediaURLKey(_ raw: String, preservingQuery: Bool) -> String {
        guard var components = URLComponents(string: raw) else {
            return raw
                .replacingOccurrences(of: "\\u0026", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        if !preservingQuery {
            components.query = nil
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string?.lowercased() ?? raw.lowercased()
    }

    private static func imageURLCandidates(from image: [String: Any]) -> [String] {
        var candidates: [String] = []
        appendImageURLs(from: image["download_addr"], to: &candidates)
        appendImageURLs(from: image["url_list"], to: &candidates)
        appendImageURLs(from: image["uri"], to: &candidates)
        appendImageURLs(from: image["origin_url"], to: &candidates)
        appendImageURLs(from: image["large"], to: &candidates)
        appendImageURLs(from: image["cover"], to: &candidates)
        return candidates
            .map { $0.replacingOccurrences(of: "\\u0026", with: "&") }
            .filter { raw in
                guard let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { return false }
                return true
            }
    }

    private static func appendImageURLs(from value: Any?, to candidates: inout [String]) {
        if let string = value as? String, !string.isEmpty {
            candidates.append(string)
            return
        }

        if let list = value as? [String] {
            candidates.append(contentsOf: list.filter { !$0.isEmpty })
            return
        }

        if let dict = value as? [String: Any] {
            appendImageURLs(from: dict["url_list"], to: &candidates)
            appendImageURLs(from: dict["uri"], to: &candidates)
        }
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

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            let captureIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let range = Range(match.range(at: captureIndex), in: text) else { return nil }
            return String(text[range])
        }
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
        let base = safeBaseFileName(title, fallback: "douyin-video")
        return base.lowercased().hasSuffix(".mp4") ? base : "\(base).mp4"
    }

    private static func safeVideoFileName(_ title: String, fallback: String) -> String {
        let base = safeBaseFileName(title, fallback: fallback)
        return base.lowercased().hasSuffix(".mp4") ? base : "\(base).mp4"
    }

    private static func safeBaseFileName(_ title: String, fallback: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"[\\/:*?"<>|]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(80))
    }

    private static func imageFileExtension(from rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return "jpg" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif":
            return ext
        default:
            return "jpg"
        }
    }

    private static var trailingURLTrimCharacters: CharacterSet {
        CharacterSet(charactersIn: ".,!?;:，。！？；：、")
    }
}

private struct WebPageResult: Sendable {
    let url: String
    let title: String?
    let description: String?
    let text: String
}

private struct LinkFetchOutcome: Sendable {
    let index: Int
    let block: String?
    let video: ResolvedWebVideo?
    let images: [ResolvedWebImage]
    let success: Bool
}
