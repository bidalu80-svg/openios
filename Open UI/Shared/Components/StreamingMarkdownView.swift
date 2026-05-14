import UIKit
import SwiftUI
import Photos
import MarkdownView
import Charts
import os.log

private let vizLog = Logger(subsystem: "com.openui", category: "VizPipeline")

// MARK: - Streaming Markdown View

/// Renders markdown using MarkdownView (UIKit-backed).
///
/// During streaming, a single `MarkdownView` renders the `displayContent` string
/// which is smoothly drained from the raw server tokens by `StreamingContentStore`.
/// This gives a typewriter effect — characters flow in at a readable pace rather
/// than bursting in large chunks.
///
/// ## Parse Throttling
/// During streaming, the underlying MarkdownView (which runs a full CommonMark
/// parse + CoreText layout pass on every update) is throttled via the MarkdownView
/// library's built-in `lastHeightMeasureTime` coordinator — updated at most once
/// per frame (16ms). On top of that, SwiftUI's own coalescing means view updates
/// are already capped at display refresh rate.
///
/// ## Animated Height
/// The container height is animated with a spring so content grows smoothly
/// instead of jumping as new lines appear.
///
/// When streaming ends, `finalBody` takes over for special block detection
/// (charts, HTML, Mermaid, SVG, images).
struct StreamingMarkdownView: View {
    let content: String
    let isStreaming: Bool
    let textColor: SwiftUI.Color?
    let authToken: String?
    let serverBaseURL: String?

    @Environment(\.accessibilityScale) private var accessibilityScale

    /// Base body font size used by MarkdownTheme.default (UIFont.preferredFont(.body)).
    /// We scale relative to this so the user's content text scale applies correctly.
    private static let baseBodyFontSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize

    init(
        content: String,
        isStreaming: Bool,
        textColor: SwiftUI.Color? = nil,
        authToken: String? = nil,
        serverBaseURL: String? = nil
    ) {
        self.content = content
        self.isStreaming = isStreaming
        self.textColor = textColor
        self.authToken = authToken
        self.serverBaseURL = serverBaseURL
    }

    /// Returns a MarkdownTheme with fonts scaled by the user's accessibility content scale,
    /// and optionally with the body text color overridden (for rendering on coloured backgrounds
    /// like the blue "sent" bubble in channels — UIKit-backed MarkdownView ignores SwiftUI
    /// foregroundStyle, so we must set the color directly in the theme).
    private var scaledTheme: MarkdownTheme {
        let scale = accessibilityScale.scale(for: .content)
        var theme = MarkdownTheme.default
        if abs(scale - 1.0) > 0.01 {
            theme.align(to: Self.baseBodyFontSize * scale)
        }
        if let swiftUIColor = textColor {
            let uiColor = UIColor(swiftUIColor)
            theme.colors.body = uiColor
            theme.colors.code = uiColor
        }
        return theme
    }

    var body: some View {
        unifiedBody
    }

    // MARK: - Unified Body
    //
    // A single render path is used for both streaming and final states.
    // Keeping the same VStack+ForEach structure throughout ensures that
    // InlineVisualizerView keeps a stable identity in the SwiftUI view tree
    // across the streaming→final transition, so the WKWebView is never
    // destroyed and recreated (which was the cause of the visible flash).

    @ViewBuilder
    private var unifiedBody: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            let segments = resolveSegments()
            if segments.isEmpty {
                EmptyView()
            } else if segments.count == 1, case .markdown(let text) = segments[0] {
                // Fast path: plain markdown only — no viz, no ForEach overhead.
                let safeText = Self.sanitizedMarkdownTextForDisplay(text)
                if !safeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownView(safeText, theme: scaledTheme)
                        .codeAutoScroll(true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(for: segment)
                    }
                }
            }
        }
    }

    /// Resolves the current content into renderable segments.
    ///
    /// During streaming, we use `streamingParse` to get a partial segment list
    /// so that `InlineVisualizerView` appears at the same `ForEach` offset it will
    /// occupy once streaming ends. This prevents SwiftUI from rebuilding the view
    /// tree when `isStreaming` flips to `false`.
    ///
    /// ## Performance: VIZ streaming optimisation
    /// The `<details type="tool_calls">` block that used to appear before VIZ
    /// markers is now stripped upstream by `ToolCallParser.parseOrdered()` inside
    /// `AssistantMessageContent` before the text ever reaches `StreamingMarkdownView`.
    /// By the time we see the content, the pre-VIZ prose is just a short settled
    /// string (e.g. "Here's a cute little pig for you! 🐷") — safe to pass to
    /// MarkdownView on every tick with negligible cost.
    ///
    /// We therefore pass the real pre-VIZ prose through rather than an empty
    /// placeholder. This fixes the visible flash where the prose text disappeared
    /// during VIZ streaming and only reappeared once the stream finished.
    private func resolveSegments() -> [ContentSegment] {
        let renderContent = Self.sanitizedMarkdownTextForDisplay(content)
        guard !renderContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        if isStreaming {
            // ── VIZ marker path ───────────────────────────────────────────────
            let vizState = VizMarkerParser.streamingParse(renderContent)
            switch vizState {
            case .noMarkers:
                break   // fall through to streaming code-block detection below

            case .streaming(let proseBeforeMarker, let vizContent):
                let _ = vizLog.debug("StreamingMarkdownView: .streaming — proseLen=\(proseBeforeMarker.count), vizLen=\(vizContent.count)")
                return [.markdown(proseBeforeMarker), .visualization(vizContent)]

            case .complete:
                let preViz = extractPreVizText(renderContent)
                let postViz = extractPostVizText(renderContent)
                let _ = vizLog.debug("StreamingMarkdownView: .complete during streaming — preVizLen=\(preViz.count), postVizLen=\(postViz.count)")
                var result: [ContentSegment] = []
                result.append(.markdown(preViz))
                let vizContent = extractVizContent(renderContent)
                result.append(.visualization(vizContent))
                if !postViz.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(postViz))
                }
                return result
            }

            // ── Streaming code-block detection (html / svg) ───────────────────
            // If the model is mid-way through a ```html or ```svg block (opening
            // fence seen, closing fence not yet arrived), render a live preview
            // instead of raw monospace text. This is the streaming analogue of
            // parseCodeBlocks — it only fires when isStreaming=true and the block
            // is incomplete. Once the closing ``` arrives, resolveSegments() falls
            // through to parseSpecialBlocks() which handles the complete block.
            if let streamingSeg = resolveStreamingCodeBlock(renderContent) {
                return streamingSeg
            }

            // No incomplete special block found — but there may be a *complete* block
            // (opening AND closing fence both arrived) while post-block prose is still
            // streaming. Use parseSpecialBlocks so HTML/SVG/chart blocks already closed
            // render as previews instead of flashing to raw code text until streaming ends.
            return parseSpecialBlocks(renderContent)

        } else {
            return parseSpecialBlocks(renderContent)
        }
    }

    /// Detects an incomplete (unclosed) special code block in `text` during
    /// streaming and returns a segment list with a lightweight native preview.
    ///
    /// Returns `nil` when no incomplete special block is found, letting the caller
    /// fall back to plain markdown rendering.
    private func resolveStreamingCodeBlock(_ text: String) -> [ContentSegment]? {
        // We only care about html and svg — mermaid needs complete syntax to render.
        let candidates: [(tag: String, makeSeg: (String) -> ContentSegment)] = [
            ("```html\n",  { .html($0, isStreaming: true) }),
            ("```svg\n",   { .svg($0, isStreaming: true) }),
        ]

        for (tag, makeSeg) in candidates {
            guard let openRange = text.range(of: tag, options: .caseInsensitive) else { continue }

            let contentStart = openRange.upperBound
            let afterOpen = text[contentStart...]

            // If the closing fence is already present, this is a complete block —
            // parseSpecialBlocks (non-streaming path) handles it. Skip here.
            if findClosingFence(in: text[contentStart...], from: contentStart) != nil { continue }

            // Incomplete block — extract partial content
            let partialContent = String(afterOpen)
            // Anything before the opening fence is plain markdown
            let before = String(text[text.startIndex..<openRange.lowerBound])

            var result: [ContentSegment] = []
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(before))
            }
            if !partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(makeSeg(partialContent))
            }
            return result.isEmpty ? nil : result
        }

        guard let openRange = text.range(of: "```", options: .backwards) else { return nil }
        let afterOpen = text[openRange.upperBound...]
        guard findClosingFence(in: text[openRange.upperBound...], from: openRange.upperBound) == nil,
              let newlineIdx = afterOpen.firstIndex(of: "\n") else { return nil }

        let lang = afterOpen[afterOpen.startIndex..<newlineIdx]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let partialContent = String(afterOpen[afterOpen.index(after: newlineIdx)...])
        guard shouldRenderCompactCodeModule(language: lang, code: partialContent) else { return nil }

        let before = String(text[text.startIndex..<openRange.lowerBound])
        var result: [ContentSegment] = []
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.markdown(before))
        }
        result.append(.codeModule(language: lang, code: partialContent))
        return result
    }

    /// Extracts the text that appears before `@@@VIZ-START` in the content.
    /// Returns the full text if the start marker is not present.
    private func extractPreVizText(_ text: String) -> String {
        guard let startRange = text.range(of: "@@@VIZ-START") else { return text }
        return String(text[text.startIndex..<startRange.lowerBound])
    }

    /// Extracts the text that appears after `\n@@@VIZ-END` in the content.
    /// Returns an empty string if the end marker is not present.
    private func extractPostVizText(_ text: String) -> String {
        let endMarker = "\n@@@VIZ-END"
        guard let endRange = text.range(of: endMarker) else { return "" }
        let afterEnd = String(text[endRange.upperBound...])
        // Strip leading newline that typically follows @@@VIZ-END
        if afterEnd.hasPrefix("\n") {
            return String(afterEnd.dropFirst())
        }
        return afterEnd
    }

    /// Extracts the HTML/SVG content between `@@@VIZ-START` and `\n@@@VIZ-END`.
    /// Returns an empty string if the start marker is not present.
    private func extractVizContent(_ text: String) -> String {
        let startMarker = "@@@VIZ-START"
        let endMarker = "\n@@@VIZ-END"
        guard let startRange = text.range(of: startMarker) else { return "" }
        var contentStart = startRange.upperBound
        if contentStart < text.endIndex, text[contentStart] == "\n" {
            contentStart = text.index(after: contentStart)
        }
        if let endRange = text.range(of: endMarker, range: contentStart..<text.endIndex) {
            return String(text[contentStart..<endRange.lowerBound])
        }
        return String(text[contentStart...])
    }

    /// Returns the SwiftUI view for a single content segment.
    /// `isStreaming` is forwarded to `InlineVisualizerView` so the existing WKWebView
    /// continues receiving `reconcileContent` / `finalizeContent` JS calls without
    /// being recreated.
    @ViewBuilder
    private func segmentView(for segment: ContentSegment) -> some View {
        switch segment {
        case .markdown(let text):
            let safeText = Self.sanitizedMarkdownTextForDisplay(text)
            if !safeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownView(safeText, theme: scaledTheme)
                    .codeAutoScroll(true)
            }
        case .chart(let code):
            if let spec = tryParseChart(code: code) {
                ChartPreviewView(spec: spec, rawCode: code, language: "json")
            } else {
                MarkdownView("```json\n\(code)\n```", theme: scaledTheme)
            }
        case .html(let code, let streaming):
            HTMLPreviewView(html: code, isStreaming: streaming)
        case .mermaid(let code):
            MermaidPreviewView(code: code)
        case .svg(let code, let streaming):
            SVGPreviewView(code: code, isStreaming: streaming)
        case .python(let code):
            PythonCodeBlockView(code: code)
        case .codeModule(let language, let code):
            CompactCodeModuleView(code: code, language: language)
        case .codeBlock(let language, let code):
            StandardCodeBlockView(code: code, language: language)
        case .markdownImage(let imageURL, let altText, let linkURL):
            MarkdownInlineImageView(
                imageURL: imageURL,
                altText: altText,
                linkURL: linkURL,
                authToken: authToken,
                serverBaseURL: serverBaseURL
            )
        case .visualization(let html):
            // Pass isStreaming only while the VIZ block itself is still open.
            // Once \n@@@VIZ-END has arrived in the content the visualization is
            // complete — pass false so InlineVisualizerView calls finalizeContent()
            // and stops the spinner, even if the overall message stream is still active
            // (e.g. post-VIZ prose is still draining character-by-character).
            let vizComplete = content.contains("\n@@@VIZ-END")
            let vizIsStreaming = isStreaming && !vizComplete
            let _ = vizLog.debug("StreamingMarkdownView: rendering InlineVisualizerView isStreaming=\(vizIsStreaming) (vizComplete=\(vizComplete)), htmlLen=\(html.count)")
            InlineVisualizerView(content: html, isStreaming: vizIsStreaming)
        }
    }

    // MARK: - Special Block Detection (final render only)

    private let chartLanguageTags: Set<String> = [
        "json", "chart", "chartjs", "echarts", "highcharts",
        "vega-lite", "vegalite", "plotly"
    ]

    private let pythonLanguageTags: Set<String> = ["python", "python3", "py"]

    private enum ContentSegment {
        case markdown(String)
        case chart(String)
        /// `isStreaming` — true while the closing ``` fence has not yet arrived.
        case html(String, isStreaming: Bool)
        case mermaid(String)
        /// `isStreaming` — true while the closing ``` fence has not yet arrived.
        case svg(String, isStreaming: Bool)
        case python(String)
        case codeModule(language: String, code: String)
        case codeBlock(language: String, code: String)
        case markdownImage(imageURL: URL, altText: String, linkURL: URL?)
        case visualization(String)
    }

    private struct ParsedBlock {
        let language: String
        let content: String
    }

    private enum EitherContent {
        case markdown(String)
        case block(_ block: ParsedBlock)
        case segment(_ segment: ContentSegment)
    }

    // MARK: - Markdown Image Regex Patterns

    /// Matches linked images: [![alt](imageUrl)](linkUrl)
    /// Group 1: alt text, Group 2: image URL, Group 3: link URL
    private static let linkedImagePattern: NSRegularExpression? = {
        // [![...](...)](#...)  — the link wraps the image
        try? NSRegularExpression(
            pattern: #"\[!\[([^\]]*)\]\(([^)]+)\)\]\(([^)]+)\)"#,
            options: []
        )
    }()

    /// Matches standalone images: ![alt](imageUrl)
    /// Group 1: alt text, Group 2: image URL
    /// Negative lookbehind ensures we don't match images already captured as linked images.
    private static let standaloneImagePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?<!\[)!\[([^\]]*)\]\(([^)]+)\)"#,
            options: []
        )
    }()

    private static let directDataImagePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{128,})"#,
            options: [.caseInsensitive]
        )
    }()

    private static let dataImageMarkdownPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(\s*data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{48,}(?:\s+[^)]*)?\)"#,
            options: [.caseInsensitive]
        )
    }()

    private static let partialDataImageMarkdownPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(\s*data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{48,}"#,
            options: [.caseInsensitive]
        )
    }()

    private static let partialMarkdownImagePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\([^)]*$"#,
            options: [.caseInsensitive]
        )
    }()

    /// Data model for a parsed markdown image occurrence.
    private struct ParsedImage {
        let range: Range<String.Index>
        let imageURL: URL
        let altText: String
        let linkURL: URL?
    }

    /// Scans `text` for markdown image syntax and returns all occurrences with their ranges.
    private func findMarkdownImages(in text: String) -> [ParsedImage] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var results: [ParsedImage] = []

        // 1) Find linked images first  [![alt](img)](link)
        if let pattern = Self.linkedImagePattern {
            let matches = pattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                guard match.numberOfRanges >= 4,
                      let swiftRange = Range(match.range, in: text),
                      let altRange = Range(match.range(at: 1), in: text),
                      let imgRange = Range(match.range(at: 2), in: text),
                      let linkRange = Range(match.range(at: 3), in: text),
                      let imgURL = Self.makeImageURL(from: String(text[imgRange]))
                else { continue }

                let linkURLStr = String(text[linkRange])
                let linkURL = URL(string: linkURLStr)

                results.append(ParsedImage(
                    range: swiftRange,
                    imageURL: imgURL,
                    altText: String(text[altRange]),
                    linkURL: linkURL
                ))
            }
        }

        // 2) Find standalone images  ![alt](img)  — skip any that overlap with linked images
        if let pattern = Self.standaloneImagePattern {
            let matches = pattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let swiftRange = Range(match.range, in: text),
                      let altRange = Range(match.range(at: 1), in: text),
                      let imgRange = Range(match.range(at: 2), in: text),
                      let imgURL = Self.makeImageURL(from: String(text[imgRange]))
                else { continue }

                // Skip if this overlaps with any linked image already found
                let overlaps = results.contains { $0.range.overlaps(swiftRange) }
                if overlaps { continue }

                results.append(ParsedImage(
                    range: swiftRange,
                    imageURL: imgURL,
                    altText: String(text[altRange]),
                    linkURL: nil
                ))
            }
        }

        // Sort by position in the string (earliest first)
        results.sort { $0.range.lowerBound < $1.range.lowerBound }
        if let pattern = Self.directDataImagePattern {
            let matches = pattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                guard match.numberOfRanges >= 2,
                      let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                let ref = Self.normalizedDataImageReference(String(text[swiftRange]))
                guard let imgURL = Self.makeImageURL(from: ref) else { continue }
                if results.contains(where: { $0.range.overlaps(swiftRange) }) { continue }
                results.append(ParsedImage(
                    range: swiftRange,
                    imageURL: imgURL,
                    altText: "",
                    linkURL: nil
                ))
            }
            results.sort { $0.range.lowerBound < $1.range.lowerBound }
        }
        return results
    }

    private static func makeImageURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 80_000,
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("data:image/") {
            return URL(string: trimmed)
        }
        return nil
    }

    private static func normalizedDataImageReference(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func sanitizedMarkdownTextForDisplay(_ text: String) -> String {
        var cleaned = text
        cleaned = removeProviderCitationArtifacts(from: cleaned)
        if let pattern = dataImageMarkdownPattern {
            cleaned = pattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: ""
            )
        }
        if let pattern = partialDataImageMarkdownPattern {
            cleaned = pattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: ""
            )
        }
        if let pattern = partialMarkdownImagePattern,
           cleaned.lowercased().contains("data:image/") {
            cleaned = pattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: ""
            )
        }
        if let pattern = directDataImagePattern {
            cleaned = pattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: ""
            )
        }
        cleaned = compactBareLinks(in: cleaned)
        return cleaned
    }

    private static func compactBareLinks(in text: String) -> String {
        let pattern = #"(?<![\]\(])https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let raw = nsText.substring(with: match.range)
            let (url, trailing) = splitTrailingPunctuation(from: raw)
            guard !url.isEmpty,
                  URL(string: url) != nil else { continue }
            let title = compactLinkTitle(for: url)
            let replacement = "[\(title) ↗](\(url))\(trailing)"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func splitTrailingPunctuation(from raw: String) -> (url: String, trailing: String) {
        var url = raw
        var trailing = ""
        while let last = url.last, ".,，。；;：:)）]】".contains(last) {
            trailing.insert(last, at: trailing.startIndex)
            url.removeLast()
        }
        return (url, trailing)
    }

    private static func compactLinkTitle(for rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return "链接" }
        let host = (url.host ?? "链接")
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let lowerHost = host.lowercased()
        if lowerHost.contains("github.com") {
            let parts = url.path.split(separator: "/").prefix(2).map(String.init)
            if parts.count >= 2 { return "\(parts[1]) GitHub" }
            return "GitHub"
        }
        if lowerHost.contains("douyin.com") || lowerHost.contains("iesdouyin.com") {
            return "抖音视频"
        }
        if lowerHost.contains("snssdk.com") {
            return "MP4 播放地址"
        }
        let name = host
            .split(separator: ".")
            .first
            .map(String.init) ?? host
        return name.isEmpty ? "链接" : name
    }

    static func removeProviderCitationArtifacts(from text: String) -> String {
        var cleaned = text
        cleaned = removePrivateUseCharacters(from: cleaned)
        let patterns = [
            #"(?is)\b(?:cite|citation)\s*turn\d+(?:search|news|source)\d+\b"#,
            #"(?is)\bturn\d+(?:search|news|source)\d+\b"#,
            #"\[\s*cite\s+turn\d+(?:search|news|source)\d+\s*\]"#
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        cleaned = cleaned
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]+\n"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return cleaned
    }

    private static func removePrivateUseCharacters(from text: String) -> String {
        let filteredScalars = text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !((0xE000...0xF8FF).contains(value)
                || (0xF0000...0xFFFFD).contains(value)
                || (0x100000...0x10FFFD).contains(value))
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    /// Detects a bare image URL in plain text so providers that return
    /// "done text + image link" still render as an inline image.
    private func findBareImageURLs(in text: String) -> [ParsedImage] {
        let pattern = #"(?<![\(\["'])((?:https?:)?//[^\s<>"']+\.(?:png|jpg|jpeg|gif|webp|bmp|svg|avif)(?:\?[^\s<>"']*)?|https?://assets\.grok\.com/[^\s<>"']+)(?![\)"'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let urlRange = Range(match.range(at: 1), in: text) else { return nil }
            let raw = String(text[urlRange])
            let normalized = raw.hasPrefix("//") ? "https:\(raw)" : raw
            guard let imageURL = Self.makeImageURL(from: normalized) else { return nil }
            return ParsedImage(range: urlRange, imageURL: imageURL, altText: "", linkURL: imageURL)
        }
    }

    private func parseSpecialBlocks(_ text: String) -> [ContentSegment] {
        // 0) First check for VIZ markers and expand them into segments.
        //    Each text chunk from the VIZ parse is then processed for images + code blocks.
        let vizSegments = VizMarkerParser.parse(text)
        let hasViz = vizSegments.contains { if case .visualization = $0 { return true }; return false }
        if hasViz {
            var result: [ContentSegment] = []
            for seg in vizSegments {
                switch seg {
                case .text(let chunk):
                    result.append(contentsOf: parseImagesAndCodeBlocks(chunk))
                case .visualization(let html):
                    result.append(.visualization(html))
                }
            }
            return result.isEmpty ? [.markdown(text)] : result
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldRenderCompactCodeModule(language: "json", code: trimmed),
           looksLikeStandaloneJSON(trimmed) {
            return [.codeModule(language: "json", code: trimmed)]
        }

        // 1) Extract markdown images first, splitting the text around them.
        //    This runs before code-block detection so images inside prose are found.
        var images = findMarkdownImages(in: text)
        let bareImages = findBareImageURLs(in: text)
        for bare in bareImages where !images.contains(where: { $0.range.overlaps(bare.range) }) {
            images.append(bare)
        }
        images.sort { $0.range.lowerBound < $1.range.lowerBound }

        if images.isEmpty {
            // No images — fall through to code-block parsing directly.
            return parseCodeBlocks(text)
        }

        var segments: [ContentSegment] = []
        var cursor = text.startIndex

        for img in images {
            // Text before this image
            if cursor < img.range.lowerBound {
                let preceding = String(text[cursor..<img.range.lowerBound])
                // Parse code blocks within the preceding text chunk
                segments.append(contentsOf: parseCodeBlocks(preceding))
            }
            // The image itself
            segments.append(.markdownImage(imageURL: img.imageURL, altText: img.altText, linkURL: img.linkURL))
            cursor = img.range.upperBound
        }

        // Remaining text after the last image
        if cursor < text.endIndex {
            let remaining = String(text[cursor..<text.endIndex])
            segments.append(contentsOf: parseCodeBlocks(remaining))
        }

        return segments.isEmpty ? [.markdown(text)] : segments
    }

    /// Convenience combining markdown-image extraction and code-block parsing.
    /// Used by `parseSpecialBlocks` when splitting text chunks from VIZ segments.
    private func parseImagesAndCodeBlocks(_ text: String) -> [ContentSegment] {
        let images = findMarkdownImages(in: text)
        guard !images.isEmpty else { return parseCodeBlocks(text) }

        var segments: [ContentSegment] = []
        var cursor = text.startIndex
        for img in images {
            if cursor < img.range.lowerBound {
                segments.append(contentsOf: parseCodeBlocks(String(text[cursor..<img.range.lowerBound])))
            }
            segments.append(.markdownImage(imageURL: img.imageURL, altText: img.altText, linkURL: img.linkURL))
            cursor = img.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(contentsOf: parseCodeBlocks(String(text[cursor..<text.endIndex])))
        }
        return segments.isEmpty ? [.markdown(text)] : segments
    }

    /// Parses code blocks (chart/html/mermaid/svg/python) from a text chunk that
    /// has already had markdown images extracted.
    private func parseCodeBlocks(_ text: String) -> [ContentSegment] {
        guard text.contains("```") else { return [.markdown(text)] }

        var units: [EitherContent] = []
        var remaining = text[text.startIndex...]

        while let openRange = remaining.range(of: "```") {
            let afterOpen = remaining[openRange.upperBound...]
            guard let newlineIdx = afterOpen.firstIndex(of: "\n") else {
                units.append(.markdown(String(remaining)))
                return collapseParsedUnits(units, fallback: text)
            }
            let lang = afterOpen[afterOpen.startIndex..<newlineIdx]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let contentStart = afterOpen.index(after: newlineIdx)
            let searchArea = remaining[contentStart...]
            guard let closeRange = findClosingFence(in: searchArea, from: contentStart) else {
                units.append(.markdown(String(remaining)))
                return collapseParsedUnits(units, fallback: text)
            }
            let codeContent = String(remaining[contentStart..<closeRange.lowerBound])
            let normalizedBlock = normalizedCodeBlock(language: lang, content: codeContent)
            let isChart = chartLanguageTags.contains(lang) && looksLikeChartJSON(codeContent)
            let isHTML = lang == "html" && codeContent.contains("<") && codeContent.contains(">") && codeContent.count >= 10
            let isLinkedWebAsset = lang == "css" || lang == "js" || lang == "javascript"
            let isMermaid = lang == "mermaid" && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
            let isSVG = lang == "svg" && looksLikeSVG(codeContent)
            let isPython = pythonLanguageTags.contains(lang) && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            let isCompactModule = shouldRenderCompactCodeModule(language: lang, code: codeContent)
            let isStandardCodeBlock = normalizedBlock != nil

            if isChart || isHTML || isLinkedWebAsset || isMermaid || isSVG || isPython || isCompactModule || isStandardCodeBlock {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                if isChart { units.append(.segment(.chart(codeContent))) }
                else if isCompactModule { units.append(.segment(.codeModule(language: lang, code: codeContent))) }
                else if isMermaid { units.append(.segment(.mermaid(codeContent))) }
                else if isSVG { units.append(.segment(.svg(codeContent, isStreaming: false))) }
                else if isPython { units.append(.segment(.python(codeContent))) }
                else if isHTML || isLinkedWebAsset { units.append(.block(ParsedBlock(language: lang, content: codeContent))) }
                else if let normalizedBlock {
                    units.append(.segment(.codeBlock(language: normalizedBlock.language, code: normalizedBlock.content)))
                }
                else { units.append(.block(ParsedBlock(language: lang, content: codeContent))) }
                remaining = remaining[closeRange.upperBound...]
            } else {
                let blockEnd = closeRange.upperBound
                units.append(.markdown(String(remaining[remaining.startIndex..<blockEnd])))
                remaining = remaining[blockEnd...]
            }
        }

        if !remaining.isEmpty {
            let s = String(remaining)
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                units.append(.markdown(s))
            }
        }

        return collapseParsedUnits(units, fallback: text)
    }

    private func findClosingFence(
        in searchArea: Substring,
        from searchStart: String.Index
    ) -> Range<String.Index>? {
        var cursor = searchArea.startIndex
        while let fence = searchArea.range(of: "```", range: cursor..<searchArea.endIndex) {
            let isAtLineStart = fence.lowerBound == searchStart
                || searchArea[searchArea.index(before: fence.lowerBound)] == "\n"
                || searchArea[searchArea.index(before: fence.lowerBound)] == "\r"
            let afterFence = searchArea[fence.upperBound...]
            let suffixBeforeNewline = afterFence.prefix { $0 != "\n" && $0 != "\r" }
            let isFenceOnlyLine = suffixBeforeNewline.trimmingCharacters(in: .whitespaces).isEmpty
            if isAtLineStart && isFenceOnlyLine {
                return fence
            }
            cursor = fence.upperBound
        }
        return nil
    }

    private func collapseParsedUnits(_ units: [EitherContent], fallback text: String) -> [ContentSegment] {
        guard !units.isEmpty else { return [.markdown(text)] }

        var segments: [ContentSegment] = []
        var index = 0

        func isWebBlock(_ block: ParsedBlock) -> Bool {
            block.language == "html"
                || block.language == "css"
                || block.language == "js"
                || block.language == "javascript"
        }

        func markdownBlock(_ block: ParsedBlock) -> ContentSegment {
            .codeBlock(language: block.language, code: block.content)
        }

        func nextNonMarkdownWebBlockIndex(after start: Int) -> Int? {
            var lookahead = start
            while lookahead < units.count {
                switch units[lookahead] {
                case .markdown(_):
                    lookahead += 1
                case .block(let block) where isWebBlock(block):
                    return lookahead
                default:
                    return nil
                }
            }
            return nil
        }

        while index < units.count {
            switch units[index] {
            case .markdown(let markdown):
                segments.append(.markdown(markdown))
                index += 1
            case .segment(let segment):
                segments.append(segment)
                index += 1
            case .block(let block):
                guard isWebBlock(block) else {
                    segments.append(markdownBlock(block))
                    index += 1
                    continue
                }

                var webBlocks: [ParsedBlock] = []
                var cursor = index
                scanWebBlocks: while cursor < units.count {
                    switch units[cursor] {
                    case .block(let linkedBlock) where isWebBlock(linkedBlock):
                        webBlocks.append(linkedBlock)
                        cursor += 1
                    case .markdown(_):
                        guard let nextWebIndex = nextNonMarkdownWebBlockIndex(after: cursor + 1) else {
                            break scanWebBlocks
                        }
                        cursor = nextWebIndex
                    default:
                        break scanWebBlocks
                    }
                }

                guard let htmlBlock = webBlocks.first(where: { $0.language == "html" }) else {
                    segments.append(markdownBlock(block))
                    index += 1
                    continue
                }

                var html = htmlBlock.content
                for linkedBlock in webBlocks where linkedBlock.language == "css" {
                    html = injectCSS(linkedBlock.content, into: html)
                }
                for linkedBlock in webBlocks where linkedBlock.language == "js" || linkedBlock.language == "javascript" {
                    html = injectJS(linkedBlock.content, into: html)
                }

                segments.append(.html(html, isStreaming: false))
                index = max(cursor, index + 1)
            }
        }

        return segments.isEmpty ? [.markdown(text)] : segments
    }

    private func normalizedCodeBlock(language: String, content: String) -> ParsedBlock? {
        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedContent.isEmpty, !trimmedLanguage.isEmpty {
            return ParsedBlock(language: trimmedLanguage, content: content)
        }

        // Some providers stream malformed fences as:
        // ```
        // bash
        // command...
        // ```
        // Recover that into one real code block instead of leaving "bash" and the
        // commands as loose Markdown text.
        guard trimmedLanguage.isEmpty else { return nil }
        var lines = content.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        if let marker = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           isRecognizedCodeLanguage(marker) {
            lines.removeFirst()
            let recoveredContent = lines.joined(separator: "\n")
            if !recoveredContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ParsedBlock(language: marker, content: recoveredContent)
            }
        }

        if !trimmedContent.isEmpty, trimmedLanguage.isEmpty, content.contains("\n") {
            return ParsedBlock(language: "text", content: content)
        }
        return nil
    }

    private func isRecognizedCodeLanguage(_ language: String) -> Bool {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let languages: Set<String> = [
            "bash", "sh", "shell", "zsh", "fish", "powershell", "ps1",
            "nginx", "conf", "ini", "toml", "yaml", "yml", "xml",
            "swift", "kotlin", "java", "javascript", "js", "typescript", "ts",
            "tsx", "jsx", "html", "css", "scss", "python", "py", "ruby", "rb",
            "go", "rust", "rs", "c", "cpp", "c++", "objc", "objective-c",
            "php", "sql", "dockerfile", "makefile", "json", "jsonc",
            "markdown", "md", "text", "txt"
        ]
        return languages.contains(normalized)
    }

    private func injectCSS(_ css: String, into html: String) -> String {
        let styleTag = "<style>\n\(css)\n</style>"
        if let headRange = html.range(of: "</head>", options: .caseInsensitive) {
            var updated = html
            updated.insert(contentsOf: styleTag + "\n", at: headRange.lowerBound)
            return updated
        }
        return styleTag + "\n" + html
    }

    private func injectJS(_ js: String, into html: String) -> String {
        let scriptTag = "<script>\n\(js)\n</script>"
        if let bodyRange = html.range(of: "</body>", options: .caseInsensitive) {
            var updated = html
            updated.insert(contentsOf: scriptTag + "\n", at: bodyRange.lowerBound)
            return updated
        }
        return html + "\n" + scriptTag
    }

    private func looksLikeChartJSON(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") && t.hasSuffix("}")
            && (t.contains("\"data\"") || t.contains("\"datasets\"")
                || t.contains("\"series\"") || t.contains("\"values\"")
                || t.contains("\"labels\"") || t.contains("\"type\""))
    }

    private func looksLikeStandaloneJSON(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("{") && t.hasSuffix("}"))
            || (t.hasPrefix("[") && t.hasSuffix("]"))
    }

    private func shouldRenderCompactCodeModule(language: String, code: String) -> Bool {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("iexa_workspace")
            || normalized.contains("iexa_alpine")
            || code.contains("\"iexa_workspace\"")
            || code.contains("\"iexa_alpine\"") {
            return true
        }

        let compactLanguages: Set<String> = [
            "json", "jsonc", "text", "txt", "log", "output", "stdout", "stderr"
        ]
        guard compactLanguages.contains(normalized) else { return false }

        let lineCount = code.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        return code.count > 900 || lineCount > 18
    }

    private func looksLikeSVG(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("<svg") || t.contains("<svg ")
            || t.contains("xmlns=\"http://www.w3.org/2000/svg\"")
    }

    private func tryParseChart(code: String) -> USpec? {
        guard let data = code.data(using: .utf8) else { return nil }
        return try? parseUSpec(from: data)
    }
}

// MARK: - Standard Code Block

private struct StandardCodeBlockView: View {
    let code: String
    let language: String

    @Environment(\.theme) private var theme
    @State private var didCopy = false
    @State private var showFullCode = false

    private var displayLanguage: String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "text" : value
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Text(displayLanguage)
                    .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    showFullCode = true
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "eye")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button {
                    UIPasteboard.general.string = code
                    Haptics.notify(.success)
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        didCopy = true
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                didCopy = false
                            }
                        }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(didCopy ? theme.success : theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.72 : 0.90))

            HighlightedSourceView(
                code: code.trimmingCharacters(in: .newlines),
                language: displayLanguage,
                truncate: true,
                maxHeight: 360
            )
            .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.22 : 0.42))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.50 : 0.65), lineWidth: 0.8)
        )
        .sheet(isPresented: $showFullCode) {
            FullCodeView(code: code, language: displayLanguage)
        }
    }
}

// MARK: - Compact Code Module

private struct CompactCodeModuleView: View {
    let code: String
    let language: String

    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    @State private var didCopy = false

    private let collapsedPreviewLineLimit = 6
    private let expandedLineLimit = 420
    private let expandedCharacterLimit = 12_000

    private var normalizedLanguage: String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? "text" : value
    }

    private var lineCount: Int {
        code.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
    }

    private var moduleTitle: String {
        if isWorkspaceModule { return "项目写入模块" }
        if isAlpineModule { return "本地执行模块" }
        if normalizedLanguage == "json" || normalizedLanguage == "jsonc" { return "JSON 数据模块" }
        return "执行输出模块"
    }

    private var moduleIcon: String {
        if isWorkspaceModule { return "folder.fill" }
        if isAlpineModule { return "terminal.fill" }
        if normalizedLanguage == "json" || normalizedLanguage == "jsonc" { return "curlybraces" }
        return "doc.text.fill"
    }

    private var moduleSubtitle: String {
        let byteCount = code.utf8.count
        if isWorkspaceModule, !workspacePaths.isEmpty {
            return "\(workspacePaths.count) 个文件 · \(lineCount) 行 · 默认折叠"
        }
        return "\(lineCount) 行 · \(byteCount.formatted()) B · 默认折叠"
    }

    private var isWorkspaceModule: Bool {
        normalizedLanguage.contains("iexa_workspace") || code.contains("\"iexa_workspace\"")
    }

    private var isAlpineModule: Bool {
        normalizedLanguage.contains("iexa_alpine") || code.contains("\"iexa_alpine\"")
    }

    private var workspacePaths: [String] {
        guard let object = parsedJSONObject else { return [] }
        return Array(collectPaths(from: object).prefix(8))
    }

    private var commandRows: [String] {
        guard isAlpineModule, let object = parsedJSONObject else { return [] }
        return Array(collectCommands(from: object).prefix(6))
    }

    private var parsedJSONObject: Any? {
        guard let data = code.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private var previewLines: [String] {
        let source = isExpanded ? visibleExpandedCode : code
        let limit = isExpanded ? expandedLineLimit : collapsedPreviewLineLimit
        return Array(source.components(separatedBy: "\n").prefix(limit))
    }

    private var visibleExpandedCode: String {
        guard code.count > expandedCharacterLimit else { return code }
        return String(code.prefix(expandedCharacterLimit))
    }

    private var isExpandedCodeTruncated: Bool {
        code.count > expandedCharacterLimit || lineCount > expandedLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.brandPrimary.opacity(theme.isDark ? 0.16 : 0.10))
                        .frame(width: 34, height: 34)

                    Image(systemName: moduleIcon)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(moduleTitle)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                    Text(moduleSubtitle)
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    UIPasteboard.general.string = code
                    Haptics.notify(.success)
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        didCopy = true
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                didCopy = false
                            }
                        }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(didCopy ? theme.success : theme.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(MicroAnimation.snappy) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }

            if !isExpanded, !workspacePaths.isEmpty {
                moduleRows(workspacePaths, icon: "doc.text")
            } else if !isExpanded, !commandRows.isEmpty {
                moduleRows(commandRows, icon: "terminal")
            } else {
                codePreview
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.55 : 0.75), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.16 : 0.05), radius: 10, x: 0, y: 5)
    }

    private var codePreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: isExpanded) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .scaledFont(size: 12, design: .monospaced)
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if isExpanded && isExpandedCodeTruncated {
                        Text("... 内联预览已截断，复制按钮会复制完整内容")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.top, 6)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: isExpanded ? 260 : 118)
        }
        .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.34 : 0.56))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func moduleRows(_ rows: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 14)
                    Text(row)
                        .scaledFont(size: 12, weight: .medium, design: .monospaced)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
            if (isWorkspaceModule && workspacePaths.count >= 8) || (isAlpineModule && commandRows.count >= 6) {
                Text("展开可查看模块源码，复制按钮保留完整内容")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(10)
        .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.34 : 0.56))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func collectPaths(from object: Any) -> [String] {
        if let array = object as? [Any] {
            return array.flatMap { collectPaths(from: $0) }
        }
        guard let dict = object as? [String: Any] else { return [] }

        if let nested = dict["iexa_workspace"] ?? dict["operations"] ?? dict["files"] {
            return collectPaths(from: nested)
        }
        if let path = (dict["path"] as? String)
            ?? (dict["file"] as? String)
            ?? (dict["folder"] as? String)
            ?? (dict["name"] as? String) {
            return [path]
        }
        return []
    }

    private func collectCommands(from object: Any) -> [String] {
        if let array = object as? [Any] {
            return array.flatMap { collectCommands(from: $0) }
        }
        if let command = object as? String {
            return [command.replacingOccurrences(of: "\n", with: " && ")]
        }
        guard let dict = object as? [String: Any] else { return [] }

        if let nested = dict["iexa_alpine"] ?? dict["commands"] {
            return collectCommands(from: nested)
        }
        if let command = (dict["command"] as? String) ?? (dict["cmd"] as? String) {
            return [command.replacingOccurrences(of: "\n", with: " && ")]
        }
        return []
    }
}

// MARK: - Markdown Inline Image View

/// Renders a markdown image as a native SwiftUI async image with caching.
/// Supports optional link wrapping — tapping opens the link URL in Safari.
private struct MarkdownInlineImageView: View {
    let imageURL: URL
    let altText: String
    let linkURL: URL?
    let authToken: String?
    let serverBaseURL: String?

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var loadedUIImage: UIImage?
    @State private var isLoading = false
    @State private var didFailToLoad = false
    @State private var retryTrigger = 0
    @State private var saveState: SaveState = .idle

    private static let maxAutoRetries = 4

    private enum SaveState {
        case idle
        case saving
        case saved
        case failed
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            imageContent
                .contextMenu {
                    Button {
                        Task { await saveImageToPhotos() }
                    } label: {
                        Label("保存到相册", systemImage: "photo")
                    }
                }

            Button {
                Task { await saveImageToPhotos() }
            } label: {
                HStack(spacing: 4) {
                    if saveState == .saving {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: saveIcon)
                            .scaledFont(size: 12, weight: .semibold)
                    }
                    Text(saveLabel)
                        .scaledFont(size: 11, weight: .semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.black.opacity(0.62), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .accessibilityLabel(altText.isEmpty ? "图片" : altText)
        .accessibilityAddTraits(.isImage)
        .task(id: "\(imageURL.absoluteString)-\(retryTrigger)") {
            await loadRemoteImageIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if loadedUIImage == nil {
                retryTrigger += 1
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if imageURL.scheme == "data",
           let image = dataURIImage(from: imageURL.absoluteString) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onAppear { loadedUIImage = image }
        } else if let loadedUIImage {
            Image(uiImage: loadedUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture {
                    openURL(linkURL ?? imageURL)
                }
                .accessibilityAddTraits(.isLink)
        } else if didFailToLoad {
            VStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle")
                    .scaledFont(size: 28, weight: .medium)
                    .foregroundStyle(theme.brandPrimary.opacity(0.78))
                Text("点击重试")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                if !altText.isEmpty {
                    Text(altText)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                didFailToLoad = false
                retryTrigger += 1
            }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.surfaceContainer.opacity(0.5))
                .frame(height: 160)
                .overlay {
                    VStack(spacing: 6) {
                        ProgressView()
                            .tint(theme.brandPrimary)
                        if !altText.isEmpty {
                            Text(altText)
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
        }
    }

    private var saveIcon: String {
        switch saveState {
        case .saved: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .idle, .saving: return "square.and.arrow.down"
        }
    }

    private var saveLabel: String {
        switch saveState {
        case .idle: return "保存"
        case .saving: return "保存中"
        case .saved: return "已保存"
        case .failed: return "失败"
        }
    }

    private func dataURIImage(from dataURI: String) -> UIImage? {
        guard dataURI.hasPrefix("data:image/"),
              dataURI.count <= 7_000_000,
              let comma = dataURI.firstIndex(of: ",") else { return nil }
        let encoded = String(dataURI[dataURI.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        guard data.count <= 5_000_000 else { return nil }
        return UIImage(data: data)
    }

    @MainActor
    private func loadRemoteImageIfNeeded() async {
        guard imageURL.scheme != "data" else { return }
        isLoading = true
        didFailToLoad = false

        let token = authTokenForImageURL()
        for attempt in 0..<Self.maxAutoRetries {
            guard !Task.isCancelled else { return }
            if let image = await ImageCacheService.shared.loadImage(from: imageURL, authToken: token) {
                loadedUIImage = image
                isLoading = false
                didFailToLoad = false
                return
            }
            if attempt < Self.maxAutoRetries - 1 {
                let seconds = min(6.0, pow(1.8, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }

        isLoading = false
        didFailToLoad = true
    }

    private func authTokenForImageURL() -> String? {
        guard let authToken, !authToken.isEmpty else { return nil }
        guard let serverBaseURL,
              let base = URL(string: serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let imageHost = imageURL.host?.lowercased(),
              let baseHost = base.host?.lowercased() else { return nil }
        return imageHost == baseHost ? authToken : nil
    }

    @MainActor
    private func saveImageToPhotos() async {
        guard saveState != .saving else { return }
        saveState = .saving
        let image = loadedUIImage ?? dataURIImage(from: imageURL.absoluteString)
        guard let image else {
            saveState = .failed
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }
}

// MARK: - Full Code View (Fullscreen)

struct FullCodeView: View {
    let code: String
    let language: String

    @State private var codeCopied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HighlightedSourceView(code: code, language: language, truncate: false, maxHeight: .infinity)
                .navigationTitle(language)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { dismiss() }
                            .fontWeight(.semibold)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = code
                            Haptics.notify(.success)
                            withAnimation(.spring()) { codeCopied = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                withAnimation(.spring()) { codeCopied = false }
                            }
                        } label: {
                            Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                                .scaledFont(size: 14, weight: .medium)
                        }
                    }
                }
        }
    }
}

// MARK: - Markdown With Loading

struct MarkdownWithLoading: View {
    let content: String?
    let isLoading: Bool
    var authToken: String? = nil
    var serverBaseURL: String? = nil

    var body: some View {
        let text = content ?? ""
        if isLoading && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TypingIndicator()
        } else {
            StreamingMarkdownView(
                content: text,
                isStreaming: isLoading,
                authToken: authToken,
                serverBaseURL: serverBaseURL
            )
        }
    }
}

// MARK: - Preview

#Preview("Streaming Markdown") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
            StreamingMarkdownView(
                content: """
                ## Hello World

                This is a **bold** statement with `inline code`.

                ```python
                def fibonacci(n):
                    if n <= 1:
                        return n
                    return fibonacci(n-1) + fibonacci(n-2)

                for i in range(20):
                    print(fibonacci(i))
                ```

                > A blockquote for good measure.

                Here is an image:

                ![Cat](https://ts3.mm.bing.net/th?id=OIP.aSMukwrEsjGt9XxJFvxdxQHaEo&pid=15.1)
                """,
                isStreaming: false
            )
        }
        .padding()
    }
    .themed()
}
