import Foundation

struct ClientWebSearchService: Sendable {
    func search(queries: [String], originalQuery: String?) async throws -> WebSearchResponse {
        let normalizedQueries = Self.unique(queries.map(Self.normalizedQuery))
        guard !normalizedQueries.isEmpty else { return WebSearchResponse() }

        let searchQueries = Array(normalizedQueries.prefix(4))
        let browserResult = await BrowserWebSearchService.shared.search(
            queries: searchQueries,
            originalQuery: originalQuery ?? normalizedQueries.first
        )
        if browserResult.loadedCount > 0 || browserResult.items.count >= 3 || browserResult.docs.count >= 2 {
            return browserResult
        }

        do {
            let alpineResult = try await Self.searchWithLocalAlpine(
                queries: searchQueries,
                originalQuery: originalQuery ?? normalizedQueries.first
            )
            return Self.merge(primary: browserResult, fallback: alpineResult)
        } catch {
            if browserResult.status || !browserResult.items.isEmpty || !browserResult.docs.isEmpty {
                return browserResult
            }
            throw error
        }
    }

    private static func searchWithLocalAlpine(queries: [String], originalQuery: String?) async throws -> WebSearchResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let scriptName = "iexa-search-\(suffix).py"
        let inputName = "iexa-search-\(suffix).json"
        let inputData = try JSONSerialization.data(
            withJSONObject: [
                "queries": queries,
                "original_query": originalQuery ?? queries.first ?? ""
            ],
            options: []
        )

        try await LocalAlpineTerminalService.shared.writeFile(
            data: Data(Self.localAlpineSearchScript().utf8),
            fileName: scriptName,
            destinationPath: "/"
        )
        try await LocalAlpineTerminalService.shared.writeFile(
            data: inputData,
            fileName: inputName,
            destinationPath: "/"
        )

        let command = "python3 \(scriptName) \(inputName)"
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: "/mnt/iexa")
        let exitCode = result.exitCode ?? 1
        guard exitCode == 0 else {
            throw LocalAlpineSearchError(
                message: "Local Alpine search failed with exit code \(exitCode): \(String(result.output.prefix(600)))"
            )
        }
        guard let jsonText = Self.extractLocalAlpineSearchJSON(from: result.output),
              let data = jsonText.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalAlpineSearchError(
                message: "Local Alpine search returned unreadable output: \(String(result.output.prefix(600)))"
            )
        }

        return WebSearchResponse(json: json)
    }

    private static func extractLocalAlpineSearchJSON(from output: String) -> String? {
        let begin = "IEXA_SEARCH_JSON_BEGIN"
        let end = "IEXA_SEARCH_JSON_END"
        if let beginRange = output.range(of: begin),
           let endRange = output.range(of: end, range: beginRange.upperBound..<output.endIndex) {
            return String(output[beginRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        return trimmed
    }

    private static func localAlpineSearchScript() -> String {
        #"""
import html
import json
import re
import socket
import sys
import time
import urllib.parse
import urllib.request

socket.setdefaulttimeout(8)

USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) IexaLocalAlpineSearch/1.0 Safari/537.36"
MAX_RESULTS = 8
MAX_DOCS = 4
MAX_PAGE_CHARS = 5000
MAX_COMBINED_DOC_CHARS = 18000
DEADLINE = time.time() + 38
SEARCHED_AT = time.strftime("%Y-%m-%dT%H:%M:%S%z")


def time_left(default=6):
    return max(1, min(default, int(DEADLINE - time.time())))


def clean_text(value):
    value = html.unescape(value or "")
    value = re.sub(r"(?is)<script\b[^>]*>.*?</script>", " ", value)
    value = re.sub(r"(?is)<style\b[^>]*>.*?</style>", " ", value)
    value = re.sub(r"(?is)<[^>]+>", " ", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def search_needs_freshness(query):
    text = re.sub(r"\s+", "", query or "").lower()
    terms = [
        "今天", "今日", "24小时", "一天内", "当天",
        "today", "last24hours", "past24hours",
    ]
    return any(term in text for term in terms)


def multiline_text(value):
    value = html.unescape(value or "")
    value = re.sub(r"(?is)<script\b[^>]*>.*?</script>", " ", value)
    value = re.sub(r"(?is)<style\b[^>]*>.*?</style>", " ", value)
    value = re.sub(r"(?is)<br\s*/?>", "\n", value)
    value = re.sub(r"(?is)</p\s*>", "\n", value)
    value = re.sub(r"(?is)<[^>]+>", " ", value)
    value = re.sub(r"[ \t\xa0]+", " ", value)
    value = re.sub(r"\n{3,}", "\n\n", value)
    lines = []
    for line in value.splitlines():
        line = line.strip()
        if len(line) < 2:
            continue
        lowered = line.lower()
        if lowered in ("javascript", "cookie", "cookies", "privacy policy", "terms of use"):
            continue
        lines.append(line)
    return "\n".join(lines).strip()


def fetch(url, limit=900000):
    if time.time() >= DEADLINE:
        raise TimeoutError("search budget exhausted")
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,application/json;q=0.7,*/*;q=0.4",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )
    with urllib.request.urlopen(request, timeout=time_left()) as response:
        data = response.read(limit)
        ctype = response.headers.get("content-type", "")
        final_url = response.geturl()
    charset = "utf-8"
    match = re.search(r"charset=([\w.-]+)", ctype, re.I)
    if match:
        charset = match.group(1)
    text = data.decode(charset, "replace")
    return text, final_url, ctype


def normalize_url(raw):
    raw = html.unescape(raw or "").strip()
    if not raw:
        return ""
    raw = urllib.parse.unquote(raw)
    if raw.startswith("//"):
        return "https:" + raw
    if raw.startswith("/url?"):
        parsed = urllib.parse.urlparse("https://www.google.com" + raw)
        qs = urllib.parse.parse_qs(parsed.query)
        return qs.get("q", [""])[0]
    parsed = urllib.parse.urlparse(raw)
    if parsed.netloc.endswith("duckduckgo.com") and parsed.path.startswith("/l/"):
        qs = urllib.parse.parse_qs(parsed.query)
        return qs.get("uddg", [raw])[0]
    if parsed.netloc.endswith("baidu.com"):
        qs = urllib.parse.parse_qs(parsed.query)
        for key in ("url", "target"):
            value = qs.get(key, [""])[0]
            if value.startswith(("http://", "https://")):
                return value
        return ""
    return raw if raw.startswith(("http://", "https://")) else ""


def item(title, link, snippet):
    link = normalize_url(link)
    title = clean_text(title)
    snippet = clean_text(snippet)
    if not (title or link or snippet):
        return None
    if link and is_search_navigation(link):
        return None
    return {"title": title, "link": link, "snippet": snippet}


def is_search_navigation(url):
    parsed = urllib.parse.urlparse(url)
    host = (parsed.netloc or "").lower()
    path = (parsed.path or "").lower()
    blocked = {"www.google.com", "google.com", "www.bing.com", "bing.com", "cn.bing.com", "www.baidu.com", "baidu.com"}
    if host.endswith("baidu.com"):
        return True
    return host in blocked and path in {"/search", "/s", "/url", "/ck/a", "/link", "/html/"}


def search_bing_rss(query):
    params = {"q": query, "format": "rss", "setlang": "zh-Hans", "_": str(int(time.time()))}
    if search_needs_freshness(query):
        params["filters"] = 'ex1:"ez1"'
    url = "https://www.bing.com/search?" + urllib.parse.urlencode(params)
    text, _, _ = fetch(url, limit=350000)
    found = []
    for block in re.findall(r"(?is)<item\b[^>]*>(.*?)</item>", text):
        title = first(block, r"(?is)<title[^>]*>(.*?)</title>")
        link = first(block, r"(?is)<link[^>]*>(.*?)</link>")
        snippet = first(block, r"(?is)<description[^>]*>(.*?)</description>")
        published = clean_text(first(block, r"(?is)<pubDate[^>]*>(.*?)</pubDate>"))
        if published and snippet:
            snippet = f"{published} - {snippet}"
        parsed = item(title, link, snippet)
        if parsed:
            if published:
                parsed["published_time"] = published
            found.append(parsed)
    return found


def search_duckduckgo(query):
    params = {"q": query}
    if search_needs_freshness(query):
        params["df"] = "d"
    url = "https://lite.duckduckgo.com/lite/?" + urllib.parse.urlencode(params)
    text, _, _ = fetch(url, limit=450000)
    found = []
    for href, body in re.findall(r'(?is)<a[^>]+class=["\']result-link["\'][^>]+href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', text):
        parsed = item(body, href, "")
        if parsed:
            found.append(parsed)
    if found:
        return found
    for href, body in re.findall(r'(?is)<a[^>]+href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', text):
        parsed = item(body, href, "")
        if parsed:
            found.append(parsed)
    return found


def search_baidu(query):
    url = "https://www.baidu.com/s?" + urllib.parse.urlencode({"wd": query, "rn": "8", "ie": "utf-8", "_": str(int(time.time()))})
    text, _, _ = fetch(url, limit=500000)
    found = []
    blocks = re.findall(r'(?is)<div[^>]+class=["\'][^"\']*\bresult\b[^"\']*["\'][^>]*>(.*?)</div>\s*</div>', text)
    for block in blocks:
        href = first(block, r'(?is)<a[^>]+href=["\']([^"\']+)["\']')
        title = first(block, r"(?is)<h3[^>]*>(.*?)</h3>") or first(block, r'(?is)<a[^>]+href=["\'][^"\']+["\'][^>]*>(.*?)</a>')
        snippet = first(block, r'(?is)<span[^>]+class=["\'][^"\']*(?:content-right|c-abstract|c-span-last)[^"\']*["\'][^>]*>(.*?)</span>')
        parsed = item(title, href, snippet)
        if parsed:
            found.append(parsed)
    return found


def first(text, pattern):
    match = re.search(pattern, text or "")
    return match.group(1) if match else ""


def dedupe(items):
    result = []
    seen = set()
    for value in items:
        key = (value.get("link") or value.get("title") or value.get("snippet") or "").lower()
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


def blocked_document_url(url):
    parsed = urllib.parse.urlparse(url or "")
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return True
    lowered = parsed.path.lower()
    blocked_ext = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".mp4", ".mov", ".mp3", ".zip", ".rar", ".7z", ".ipa", ".apk", ".dmg", ".pdf")
    return lowered.endswith(blocked_ext) or is_search_navigation(url)


def fetch_document(search_item):
    url = search_item.get("link") or ""
    if blocked_document_url(url):
        return None
    text, final_url, ctype = fetch(url, limit=1000000)
    title = clean_text(first(text, r"(?is)<title[^>]*>(.*?)</title>")) or search_item.get("title") or final_url
    desc = (
        clean_text(first(text, r'(?is)<meta[^>]+name=["\']description["\'][^>]+content=["\']([^"\']*)["\']'))
        or clean_text(first(text, r'(?is)<meta[^>]+property=["\']og:description["\'][^>]+content=["\']([^"\']*)["\']'))
        or search_item.get("snippet")
        or ""
    )
    published = (
        clean_text(first(text, r'(?is)<meta[^>]+property=["\']article:published_time["\'][^>]+content=["\']([^"\']*)["\']'))
        or clean_text(first(text, r'(?is)<meta[^>]+name=["\']date["\'][^>]+content=["\']([^"\']*)["\']'))
        or ""
    )
    body = first(text, r"(?is)<article\b[^>]*>(.*?)</article>") or first(text, r"(?is)<main\b[^>]*>(.*?)</main>") or first(text, r"(?is)<body\b[^>]*>(.*?)</body>") or text
    excerpt = multiline_text(body)[:MAX_PAGE_CHARS]
    if not excerpt:
        return None
    sections = []
    if title:
        sections.append("Title: " + title)
    sections.append("URL: " + final_url)
    if published:
        sections.append("Published/Updated: " + published)
    if desc:
        sections.append("Description: " + desc)
    if search_item.get("published_time"):
        sections.append("Search result time: " + search_item.get("published_time", ""))
    sections.append("Content excerpt:\n" + excerpt)
    metadata = {
        "title": title,
        "source": final_url,
        "link": final_url,
        "provider": "local_alpine_search_page",
        "searched_at": SEARCHED_AT,
    }
    if published:
        metadata["published_time"] = published
    elif search_item.get("published_time"):
        metadata["published_time"] = search_item.get("published_time", "")
    if search_item.get("snippet"):
        metadata["search_snippet"] = search_item.get("snippet", "")
    return {"content": "\n".join(sections), "metadata": metadata}


def summary_doc(search_item):
    lines = []
    if search_item.get("title"):
        lines.append("Title: " + search_item["title"])
    if search_item.get("link"):
        lines.append("URL: " + search_item["link"])
    if search_item.get("snippet"):
        lines.append("Search snippet: " + search_item["snippet"])
    if search_item.get("published_time"):
        lines.append("Search result time: " + search_item["published_time"])
    if not lines:
        return None
    metadata = {
        "title": search_item.get("title", ""),
        "source": search_item.get("link", ""),
        "link": search_item.get("link", ""),
        "provider": "local_alpine_search_summary",
        "searched_at": SEARCHED_AT,
    }
    if search_item.get("published_time"):
        metadata["published_time"] = search_item.get("published_time", "")
    return {
        "content": "\n".join(lines),
        "metadata": metadata,
    }


def rank(items, query):
    terms = [part.lower() for part in re.split(r"\W+", query or "") if len(part) >= 2]
    def score(value):
        haystack = " ".join([value.get("title", ""), value.get("snippet", ""), value.get("link", "")]).lower()
        points = sum(3 for term in terms if term in haystack)
        if value.get("link") and not blocked_document_url(value.get("link")):
            points += 4
        if len(value.get("snippet", "")) > 20:
            points += 1
        return -points, value.get("title", "")
    return sorted(items, key=score)


def run():
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    queries = [str(q).strip() for q in payload.get("queries", []) if str(q).strip()]
    original = str(payload.get("original_query") or (queries[0] if queries else ""))
    items = []
    errors = []
    for query in queries[:4]:
        for provider in (search_bing_rss, search_duckduckgo, search_baidu):
            if time.time() >= DEADLINE or len(items) >= MAX_RESULTS:
                break
            try:
                items.extend(provider(query)[:5])
            except Exception as exc:
                errors.append(f"{provider.__name__}: {type(exc).__name__}: {exc}")
        items = dedupe(items)
        if len(items) >= MAX_RESULTS:
            break
    items = rank(dedupe(items), original)[:MAX_RESULTS]
    docs = []
    used = 0
    for search_item in items[:MAX_DOCS]:
        if time.time() >= DEADLINE:
            break
        doc = None
        try:
            doc = fetch_document(search_item)
        except Exception as exc:
            errors.append(f"fetch: {type(exc).__name__}: {exc}")
        if doc is None:
            doc = summary_doc(search_item)
        if not doc:
            continue
        remaining = MAX_COMBINED_DOC_CHARS - used
        if remaining <= 400:
            break
        content = doc.get("content", "")
        if len(content) > remaining:
            doc["content"] = content[:remaining]
        used += len(doc.get("content", ""))
        docs.append(doc)
    result = {
        "status": bool(items or docs),
        "collection_names": ["local_alpine_search"],
        "filenames": [value.get("link", "") for value in items if value.get("link")],
        "items": items,
        "docs": docs,
        "loaded_count": sum(1 for doc in docs if doc.get("metadata", {}).get("provider") == "local_alpine_search_page"),
    }
    if errors:
        result["debug"] = errors[:6]
    print("IEXA_SEARCH_JSON_BEGIN")
    print(json.dumps(result, ensure_ascii=False))
    print("IEXA_SEARCH_JSON_END")


if __name__ == "__main__":
    run()
"""#
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

    private static func merge(primary: WebSearchResponse, fallback: WebSearchResponse) -> WebSearchResponse {
        var filenames: [String] = []
        var seenFilenames = Set<String>()
        for filename in primary.filenames + fallback.filenames {
            let key = filename.lowercased()
            guard !key.isEmpty, seenFilenames.insert(key).inserted else { continue }
            filenames.append(filename)
        }

        var items: [WebSearchResultItem] = []
        var seenItems = Set<String>()
        for item in primary.items + fallback.items {
            let key = (item.link ?? item.title ?? item.snippet ?? UUID().uuidString).lowercased()
            guard seenItems.insert(key).inserted else { continue }
            items.append(item)
        }

        var docs: [WebSearchDocument] = []
        var seenDocs = Set<String>()
        for doc in primary.docs + fallback.docs {
            let key = (doc.metadata["source"] ?? doc.metadata["link"] ?? String(doc.content.prefix(160))).lowercased()
            guard seenDocs.insert(key).inserted else { continue }
            docs.append(doc)
        }

        return WebSearchResponse(
            status: primary.status || fallback.status || !items.isEmpty || !docs.isEmpty,
            collectionNames: Array(Set(primary.collectionNames + fallback.collectionNames)),
            filenames: filenames,
            items: Array(items.prefix(10)),
            docs: Array(docs.prefix(8)),
            loadedCount: primary.loadedCount + fallback.loadedCount
        )
    }

}

private struct LocalAlpineSearchError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
