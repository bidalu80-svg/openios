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
        theme.colors.selectionBackground = UIColor.systemBlue.withAlphaComponent(0.22)
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
        // Keep raw content for structural parsing so fenced code blocks preserve
        // exact bytes (especially Python indentation). Markdown-only segments are
        // sanitized later at render time in `segmentView`.
        let renderContent = content
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

            // ── Streaming code-block detection ────────────────────────────────
            // If the model is mid-way through an unclosed fenced code block,
            // render it through the same native code-block component used after
            // completion. This prevents MarkdownView from temporarily showing
            // its own code view with line numbers and different indentation.
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
        guard let openRange = findUnclosedOpeningFence(in: text) else { return nil }
        let afterOpen = text[openRange.upperBound...]

        let rawLanguage: String
        let rawPartialContent: String
        if let newlineIdx = afterOpen.firstIndex(of: "\n") {
            rawLanguage = afterOpen[afterOpen.startIndex..<newlineIdx]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            rawPartialContent = String(afterOpen[afterOpen.index(after: newlineIdx)...])
        } else {
            rawLanguage = afterOpen
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            rawPartialContent = ""
        }

        let recoveredBlock = recoveredStreamingCodeBlock(language: rawLanguage, content: rawPartialContent)

        var result: [ContentSegment] = []
        let before = String(text[text.startIndex..<openRange.lowerBound])
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(contentsOf: parseSpecialBlocks(before))
        }

        result.append(streamingCodeSegment(language: recoveredBlock.language, code: recoveredBlock.content))
        return result
    }

    private func findUnclosedOpeningFence(in text: String) -> Range<String.Index>? {
        var cursor = text.startIndex

        while let openRange = text.range(of: "```", range: cursor..<text.endIndex) {
            let afterOpen = text[openRange.upperBound...]
            guard let newlineIdx = afterOpen.firstIndex(of: "\n") else {
                return openRange
            }

            let contentStart = afterOpen.index(after: newlineIdx)
            if let closeRange = findClosingFence(in: text[contentStart...], from: contentStart) {
                cursor = closeRange.upperBound
            } else {
                return openRange
            }
        }

        return nil
    }

    private func recoveredStreamingCodeBlock(language: String, content: String) -> ParsedBlock {
        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedLanguage.isEmpty else {
            return ParsedBlock(language: trimmedLanguage, content: content)
        }

        var lines = content.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        if let marker = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           isRecognizedCodeLanguage(marker) {
            lines.removeFirst()
            return ParsedBlock(language: marker, content: lines.joined(separator: "\n"))
        }

        return ParsedBlock(language: "text", content: content)
    }

    private func streamingCodeSegment(language: String, code: String) -> ContentSegment {
        codeSegmentForFence(language: language, code: code, isStreamingBlock: true)
    }

    private func codeSegmentForFence(language: String, code: String, isStreamingBlock: Bool) -> ContentSegment {
        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if chartLanguageTags.contains(normalizedLanguage), looksLikeChartJSON(code) {
            return .chart(code)
        }
        if normalizedLanguage == "html" {
            return .html(code, isStreaming: isStreamingBlock)
        }
        if normalizedLanguage == "svg" {
            return .svg(code, isStreaming: isStreamingBlock)
        }
        if normalizedLanguage == "mermaid" {
            return .mermaid(code)
        }
        if shouldRenderCompactCodeModule(language: normalizedLanguage, code: code) {
            return .codeModule(
                language: normalizedLanguage,
                code: code
            )
        }
        if pythonLanguageTags.contains(normalizedLanguage) {
            return .python(code)
        }
        if !normalizedLanguage.isEmpty {
            return .codeBlock(
                language: normalizedLanguage,
                code: code
            )
        }
        return .codeBlock(language: "text", code: code)
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
            PythonCodeBlockView(code: code, isStreaming: isStreaming)
        case .codeModule(let language, let code):
            CompactCodeModuleView(code: code, language: language)
        case .codeBlock(let language, let code):
            StandardCodeBlockView(code: code, language: language, isStreaming: isStreaming)
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
            pattern: #"!?\[[^\]]*\]\(\s*data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{48,}(?:\s+[^)]*)?\)"#,
            options: [.caseInsensitive]
        )
    }()

    private static let partialDataImageMarkdownPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"!?\[[^\]]*\]\(\s*data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_\-\s]{48,}"#,
            options: [.caseInsensitive]
        )
    }()

    private static let partialMarkdownImagePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"!?\[[^\]]*\]\([^)]*$"#,
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
        cleaned = InlineDataPayloadSanitizer.sanitizedDisplayText(cleaned)
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
        return transformOutsideFencedCode(in: text) { prose in
            removeProviderCitationArtifactsFromProse(prose)
        }
    }

    private static func removeProviderCitationArtifactsFromProse(_ text: String) -> String {
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

    private static func transformOutsideFencedCode(
        in text: String,
        transform: (String) -> String
    ) -> String {
        var result = ""
        var cursor = text.startIndex

        while let opening = nextFenceOpening(in: text, range: cursor..<text.endIndex) {
            if cursor < opening.range.lowerBound {
                result += transform(String(text[cursor..<opening.range.lowerBound]))
            }

            if let closing = closingFenceRange(
                in: text,
                marker: opening.marker,
                searchStart: opening.range.upperBound
            ) {
                result += String(text[opening.range.lowerBound..<closing.upperBound])
                cursor = closing.upperBound
            } else {
                result += String(text[opening.range.lowerBound..<text.endIndex])
                return result
            }
        }

        if cursor < text.endIndex {
            result += transform(String(text[cursor..<text.endIndex]))
        }
        return result
    }

    private static func nextFenceOpening(
        in text: String,
        range: Range<String.Index>
    ) -> (range: Range<String.Index>, marker: String)? {
        var cursor = range.lowerBound
        while cursor < range.upperBound,
              let candidate = nextFenceMarker(in: text, range: cursor..<range.upperBound) {
            let lineStart = startOfLine(in: text, before: candidate.range.lowerBound)
            let prefix = text[lineStart..<candidate.range.lowerBound]
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
            cursor = candidate.range.upperBound
        }
        return nil
    }

    private static func nextFenceMarker(
        in text: String,
        range: Range<String.Index>
    ) -> (range: Range<String.Index>, marker: String)? {
        let backtickRange = text.range(of: "```", range: range)
        let tildeRange = text.range(of: "~~~", range: range)

        switch (backtickRange, tildeRange) {
        case let (.some(backtick), .some(tilde)):
            return backtick.lowerBound <= tilde.lowerBound ? (backtick, "```") : (tilde, "~~~")
        case let (.some(backtick), .none):
            return (backtick, "```")
        case let (.none, .some(tilde)):
            return (tilde, "~~~")
        case (.none, .none):
            return nil
        }
    }

    private static func closingFenceRange(
        in text: String,
        marker: String,
        searchStart: String.Index
    ) -> Range<String.Index>? {
        var cursor = searchStart
        while let fence = text.range(of: marker, range: cursor..<text.endIndex) {
            let lineStart = startOfLine(in: text, before: fence.lowerBound)
            let lineEnd = text[fence.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let prefix = text[lineStart..<fence.lowerBound]
            let suffix = text[fence.upperBound..<lineEnd]
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fence
            }
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               isLikelyDirtyClosingFenceSuffix(suffix) {
                return fence
            }
            cursor = fence.upperBound
        }
        return nil
    }

    private static func isLikelyDirtyClosingFenceSuffix(_ suffix: Substring) -> Bool {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let markdownBlockStarters = [
            #"^#{1,6}(?:\s|$)"#,
            #"^(?:[-*+])\s+"#,
            #"^\d+[.)]\s+"#,
            #"^>\s+"#,
            #"^(?:---|\*\*\*|___)\s*$"#,
            #"^</?(?:details|summary|table|ul|ol|li|p|div|section)\b"#
        ]
        if markdownBlockStarters.contains(where: {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) {
            return true
        }

        let proseLeadWords = [
            "关键", "说明", "建议", "注意", "总结", "备注", "解析", "修复", "执行", "结果", "下一步",
            "key", "notes", "note", "summary", "explanation", "recommendation", "next"
        ]
        let lowered = trimmed.lowercased()
        return proseLeadWords.contains { lowered.hasPrefix($0) }
    }

    private static func startOfLine(in text: String, before index: String.Index) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if text[previous] == "\n" {
                return cursor
            }
            cursor = previous
        }
        return text.startIndex
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
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                let rawLanguage = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
                units.append(.segment(.codeBlock(
                    language: rawLanguage.isEmpty ? "text" : rawLanguage,
                    code: ""
                )))
                return collapseParsedUnits(units, fallback: text)
            }
            let lang = afterOpen[afterOpen.startIndex..<newlineIdx]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let contentStart = afterOpen.index(after: newlineIdx)
            let searchArea = remaining[contentStart...]
            guard let closeRange = findClosingFence(in: searchArea, from: contentStart) else {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                let unclosedCode = String(searchArea)
                if !unclosedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.segment(codeSegmentForFence(
                        language: lang.isEmpty ? "text" : lang,
                        code: unclosedCode,
                        isStreamingBlock: isStreaming
                    )))
                }
                return collapseParsedUnits(units, fallback: text)
            }
            let codeContent = String(remaining[contentStart..<closeRange.lowerBound])
            let normalizedBlock = normalizedCodeBlock(language: lang, content: codeContent)
            let isChart = chartLanguageTags.contains(lang) && looksLikeChartJSON(codeContent)
            let isHTML = lang == "html" && codeContent.contains("<") && codeContent.contains(">") && codeContent.count >= 10
            let isLinkedWebAsset = lang == "css" || lang == "js" || lang == "javascript"
            let isMermaid = lang == "mermaid" && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
            let isSVG = lang == "svg" && looksLikeSVG(codeContent)
            let isPython = pythonLanguageTags.contains(lang)
            let isCompactModule = shouldRenderCompactCodeModule(language: lang, code: codeContent)
            let isStandardCodeBlock = normalizedBlock != nil

            if isChart || isHTML || isLinkedWebAsset || isMermaid || isSVG || isPython || isCompactModule || isStandardCodeBlock {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                if isChart { units.append(.segment(.chart(codeContent))) }
                else if isCompactModule {
                    units.append(.segment(.codeModule(
                        language: lang,
                        code: codeContent
                    )))
                }
                else if isMermaid { units.append(.segment(.mermaid(codeContent))) }
                else if isSVG { units.append(.segment(.svg(codeContent, isStreaming: false))) }
                else if isPython {
                    units.append(.segment(.python(codeContent)))
                }
                else if isHTML || isLinkedWebAsset { units.append(.block(ParsedBlock(language: lang, content: codeContent))) }
                else if let normalizedBlock {
                    units.append(.segment(.codeBlock(
                        language: normalizedBlock.language,
                        code: normalizedBlock.content
                    )))
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
            let lineStart = startOfFenceLine(in: searchArea, before: fence.lowerBound, fallback: searchStart)
            let prefixBeforeFence = searchArea[lineStart..<fence.lowerBound]
            let isAtFenceLineStart = prefixBeforeFence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let afterFence = searchArea[fence.upperBound...]
            let suffixBeforeNewline = afterFence.prefix { $0 != "\n" && $0 != "\r" }
            let isFenceOnlyLine = suffixBeforeNewline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isAtFenceLineStart && isFenceOnlyLine {
                return lineStart..<fence.upperBound
            }
            if isAtFenceLineStart && Self.isLikelyDirtyClosingFenceSuffix(suffixBeforeNewline) {
                return lineStart..<fence.upperBound
            }
            cursor = fence.upperBound
        }
        return nil
    }

    private func startOfFenceLine(
        in text: Substring,
        before index: String.Index,
        fallback: String.Index
    ) -> String.Index {
        guard index > text.startIndex else { return text.startIndex }

        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if text[previous] == "\n" || text[previous] == "\r" {
                return cursor
            }
            cursor = previous
        }
        return fallback
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
            .codeBlock(
                language: block.language,
                code: block.content
            )
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
            || normalized.contains("local_alpine_exec")
            || code.contains("\"iexa_workspace\"")
            || code.contains("\"iexa_alpine\"")
            || code.contains("\"local_alpine_exec\"") {
            return true
        }
        return false
    }

    private func isLikelyRunnablePythonSource(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowercased = trimmed.lowercased()
        let markers = [
            "def ", "class ", "import ", "from ", "print(", "input(",
            "for ", "while ", "if ", "elif ", "else:", "try:", "except",
            "with ", "return ", "async def ", "await ", "lambda "
        ]
        if markers.contains(where: { lowercased.contains($0) }) {
            return true
        }

        let assignmentPattern = #"(?m)^\s*[A-Za-z_][A-Za-z0-9_]*\s*=[^=]"#
        return trimmed.range(of: assignmentPattern, options: .regularExpression) != nil
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

enum InlineDataPayloadSanitizer {
    private static let inlineDataURIPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"data:((?:image|audio|video)/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=_\-\s]{256,})"#,
            options: [.caseInsensitive]
        )
    }()

    private static let base64FieldPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"("(?:(?:b64_json)|(?:base64)|(?:image_base64)|(?:imageBase64)|(?:content_base64))"\s*:\s*")([A-Za-z0-9+/=_\-\s]{256,})(")"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"((?m)^[A-Za-z0-9+/=]{1024,}\s*$)"#,
            options: []
        )
    ]

    static func sanitizedDisplayText(_ text: String) -> String {
        guard text.range(of: "base64", options: .caseInsensitive) != nil
            || text.range(of: "data:image", options: .caseInsensitive) != nil
            || text.range(of: "data:video", options: .caseInsensitive) != nil
            || text.range(of: "data:audio", options: .caseInsensitive) != nil else {
            return text
        }

        var cleaned = text

        if let pattern = inlineDataURIPattern {
            cleaned = pattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: "data:$1;base64,<已隐藏超长Base64内容>"
            )
        }

        if base64FieldPatterns.count >= 1 {
            cleaned = base64FieldPatterns[0].stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: "$1<已隐藏超长Base64内容>$3"
            )
        }

        if base64FieldPatterns.count >= 2 {
            cleaned = base64FieldPatterns[1].stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: "<已隐藏超长Base64内容>"
            )
        }

        return cleaned
    }
}

// MARK: - Standard Code Block

private struct StandardCodeBlockView: View {
    let code: String
    let language: String
    var isStreaming: Bool = false

    @Environment(\.theme) private var theme
    @State private var didCopy = false
    @State private var showFullCode = false

    private var displayLanguage: String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "text" : value
    }

    private var displayTitle: String {
        switch displayLanguage.lowercased() {
        case "bash", "sh", "shell", "zsh", "fish":
            return "Bash"
        case "python", "python3", "py":
            return "Python"
        case "javascript", "js":
            return "JavaScript"
        case "typescript", "ts":
            return "TypeScript"
        case "html":
            return "HTML"
        case "css":
            return "CSS"
        case "json", "jsonc":
            return "JSON"
        case "swift":
            return "Swift"
        case "text", "txt":
            return "Text"
        default:
            return displayLanguage
        }
    }

    private var visibleCode: String {
        InlineDataPayloadSanitizer.sanitizedDisplayText(displayCode)
    }

    private var displayCode: String {
        code
    }

    private var codeViewMaxHeight: CGFloat {
        let lineCount = max(1, visibleCode.components(separatedBy: "\n").count)
        if lineCount <= 8 {
            return min(220, max(96, CGFloat(lineCount) * 22 + 48))
        }
        if lineCount <= 18 {
            return min(360, CGFloat(lineCount) * 22 + 52)
        }
        return 480
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(displayTitle)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    UIPasteboard.general.string = displayCode
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

                Button {
                    showFullCode = true
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.94))

            SourceCodeTextView(
                code: visibleCode,
                language: displayLanguage,
                maxHeight: codeViewMaxHeight,
                autoFollowTail: isStreaming,
                wrapLines: true
            )
                .background(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.22 : 0.42))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.50 : 0.65), lineWidth: 0.8)
        )
        .sheet(isPresented: $showFullCode) {
            FullCodeView(code: displayCode, language: displayLanguage)
        }
    }
}

struct SourceCodeTextView: View {
    let code: String
    var language: String? = nil
    var maxHeight: CGFloat = 420
    var autoFollowTail: Bool = false
    var wrapLines: Bool = false

    @Environment(\.theme) private var theme
    @State private var measuredContentHeight: CGFloat = 0

    private var visibleCode: String {
        code.isEmpty ? " " : code
    }

    private var normalizedLanguage: String {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "text" : value
    }

    private var verticalPadding: CGFloat { 14 }
    private static let codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private var contentMaxHeight: CGFloat {
        max(48, maxHeight - verticalPadding * 2)
    }

    private var estimatedContentHeight: CGFloat {
        let lineCount = max(1, visibleCode.components(separatedBy: "\n").count)
        let lineHeight: CGFloat = 21
        return min(contentMaxHeight, max(48, CGFloat(lineCount) * lineHeight + 2))
    }

    var body: some View {
        let contentWidth = Self.contentWidth(for: visibleCode, font: Self.codeFont)
        let contentHeight = min(
            contentMaxHeight,
            max(48, measuredContentHeight > 0 ? measuredContentHeight : estimatedContentHeight)
        )

        HighlightedSourceTextView(
            text: visibleCode,
            language: normalizedLanguage,
            textColor: UIColor(theme.codeText),
            font: Self.codeFont,
            lineSpacing: 3.5,
            isDarkMode: theme.isDark,
            maximumHeight: contentMaxHeight,
            contentWidth: contentWidth,
            autoFollowTail: autoFollowTail,
            wrapLines: wrapLines,
            onHeightChange: { height in
                let nextHeight = min(contentMaxHeight, max(48, height))
                guard abs(measuredContentHeight - nextHeight) > 0.5 else { return }
                measuredContentHeight = nextHeight
            }
        )
        .frame(height: contentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: contentHeight + verticalPadding * 2)
    }

    private static func contentWidth(for code: String, font: UIFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let maxLineWidth = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (String($0) as NSString).size(withAttributes: attributes).width }
            .max() ?? 1
        return ceil(max(UIScreen.main.bounds.width, maxLineWidth + 96))
    }
}

private struct HighlightedSourceTextView: UIViewRepresentable {
    let text: String
    let language: String
    let textColor: UIColor
    let font: UIFont
    let lineSpacing: CGFloat
    let isDarkMode: Bool
    let maximumHeight: CGFloat
    let contentWidth: CGFloat
    let autoFollowTail: Bool
    let wrapLines: Bool
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = NoCaretSourceTextView()
        textView.selectionEnabled = true
        textView.backgroundColor = .clear
        textView.tintColor = .systemBlue
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.scrollsToTop = false
        textView.dataDetectorTypes = []
        textView.showsVerticalScrollIndicator = true
        textView.showsHorizontalScrollIndicator = true
        textView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 24)
        textView.scrollIndicatorInsets = textView.contentInset
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.layoutManager.allowsNonContiguousLayout = false
        textView.adjustsFontForContentSizeCategory = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.panGestureRecognizer.isEnabled = true
        textView.alwaysBounceHorizontal = true
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let renderedText = text.isEmpty ? " " : text
        let normalizedMaximumHeight = maximumHeight.isFinite ? maximumHeight : -1
        let shouldResetScrollToTop = !autoFollowTail && coordinator.lastAutoFollowTail
        let shouldRebuild =
            coordinator.lastText != renderedText
            || coordinator.lastLanguage != language
            || coordinator.lastFontPointSize != font.pointSize
            || coordinator.lastLineSpacing != lineSpacing
            || coordinator.lastIsDarkMode != isDarkMode
            || coordinator.lastMaximumHeight != normalizedMaximumHeight
            || coordinator.lastContentWidth != contentWidth
            || coordinator.lastAutoFollowTail != autoFollowTail
            || coordinator.lastWrapLines != wrapLines
            || !coordinator.lastTextColor.isEqual(textColor)

        guard shouldRebuild else { return }

        uiView.selectedTextRange = nil
        let previousText = coordinator.lastText
        let didAppendToExistingText = !previousText.isEmpty
            && renderedText.hasPrefix(previousText)
            && coordinator.lastLanguage == language
            && coordinator.lastFontPointSize == font.pointSize
            && coordinator.lastLineSpacing == lineSpacing
            && coordinator.lastIsDarkMode == isDarkMode
            && coordinator.lastMaximumHeight == normalizedMaximumHeight
            && coordinator.lastContentWidth == contentWidth
            && coordinator.lastWrapLines == wrapLines
            && coordinator.lastTextColor.isEqual(textColor)
        Self.configureTextContainer(uiView, preferredWidth: contentWidth, wrapLines: wrapLines)
        uiView.textContainer.heightTracksTextView = false
        Self.configureScrollInsets(uiView, wrapLines: wrapLines)
        if let sourceTextView = uiView as? NoCaretSourceTextView {
            sourceTextView.wrapLines = wrapLines
            sourceTextView.minimumContentWidth = contentWidth
        }
        uiView.isScrollEnabled = true
        uiView.tintColor = .systemBlue
        uiView.showsVerticalScrollIndicator = true
        uiView.showsHorizontalScrollIndicator = !wrapLines
        uiView.alwaysBounceVertical = true
        uiView.alwaysBounceHorizontal = !wrapLines

        if didAppendToExistingText {
            let suffix = String(renderedText.dropFirst(previousText.count))
            if !suffix.isEmpty {
                uiView.textStorage.append(
                    SourceCodeHighlighter.highlighted(
                        suffix,
                        language: language,
                        font: font,
                        baseColor: textColor,
                        isDarkMode: isDarkMode,
                        lineSpacing: lineSpacing,
                        lineBreakMode: wrapLines ? .byCharWrapping : .byClipping
                    )
                )
            }
        } else {
            uiView.attributedText = SourceCodeHighlighter.highlighted(
                renderedText,
                language: language,
                font: font,
                baseColor: textColor,
                isDarkMode: isDarkMode,
                lineSpacing: lineSpacing,
                lineBreakMode: wrapLines ? .byCharWrapping : .byClipping
            )
            uiView.setContentOffset(.zero, animated: false)
        }
        Self.updateHorizontalContentMetrics(uiView, preferredWidth: contentWidth, wrapLines: wrapLines)

        coordinator.lastText = renderedText
        coordinator.lastLanguage = language
        coordinator.lastFontPointSize = font.pointSize
        coordinator.lastLineSpacing = lineSpacing
        coordinator.lastIsDarkMode = isDarkMode
        coordinator.lastMaximumHeight = normalizedMaximumHeight
        coordinator.lastContentWidth = contentWidth
        coordinator.lastAutoFollowTail = autoFollowTail
        coordinator.lastWrapLines = wrapLines
        coordinator.lastTextColor = textColor

        if shouldResetScrollToTop {
            DispatchQueue.main.async {
                guard uiView.isScrollEnabled else { return }
                UIView.performWithoutAnimation {
                    uiView.layoutIfNeeded()
                    uiView.setContentOffset(
                        CGPoint(
                            x: -uiView.adjustedContentInset.left,
                            y: -uiView.adjustedContentInset.top
                        ),
                        animated: false
                    )
                }
            }
        } else if autoFollowTail {
            DispatchQueue.main.async {
                guard uiView.isScrollEnabled else { return }
                UIView.performWithoutAnimation {
                    uiView.layoutIfNeeded()
                    let bottomOffsetY = max(
                        -uiView.adjustedContentInset.top,
                        uiView.contentSize.height - uiView.bounds.height + uiView.adjustedContentInset.bottom
                    )
                    uiView.setContentOffset(
                        CGPoint(x: uiView.contentOffset.x, y: bottomOffsetY),
                        animated: false
                    )
                }
            }
        }

        DispatchQueue.main.async {
            let measuredHeight = Self.measuredHeight(
                for: uiView,
                maximumHeight: maximumHeight,
                wrapLines: wrapLines
            )
            onHeightChange(measuredHeight)
            Self.updateHorizontalContentMetrics(uiView, preferredWidth: contentWidth, wrapLines: wrapLines)
            let needsVerticalScroll = measuredHeight >= maximumHeight - 0.5
            uiView.isScrollEnabled = true
            uiView.alwaysBounceVertical = needsVerticalScroll
            uiView.showsVerticalScrollIndicator = needsVerticalScroll
            uiView.alwaysBounceHorizontal = !wrapLines
            uiView.showsHorizontalScrollIndicator = !wrapLines
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let fallbackWidth = UIScreen.main.bounds.width - 64
        let width = max(1, proposal.width ?? uiView.bounds.width.nonZero(or: fallbackWidth))
        let fittingSize = uiView.sizeThatFits(
            CGSize(
                width: wrapLines ? width : contentWidth,
                height: UIView.layoutFittingExpandedSize.height
            )
        )
        let cappedHeight = maximumHeight.isFinite ? min(fittingSize.height, maximumHeight) : fittingSize.height
        return CGSize(width: width, height: max(1, cappedHeight))
    }

    private static func measuredHeight(for uiView: UITextView, maximumHeight: CGFloat, wrapLines: Bool) -> CGFloat {
        let width = wrapLines
            ? max(1, uiView.bounds.width)
            : max(uiView.textContainer.size.width, uiView.bounds.width)
        uiView.layoutIfNeeded()
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        let usedHeight = ceil(
            uiView.layoutManager.usedRect(for: uiView.textContainer).height
            + uiView.textContainerInset.top
            + uiView.textContainerInset.bottom
        )
        if usedHeight > 1 {
            return maximumHeight.isFinite ? min(usedHeight, maximumHeight) : usedHeight
        }
        let fittingSize = uiView.sizeThatFits(CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
        if maximumHeight.isFinite {
            return min(fittingSize.height, maximumHeight)
        }
        return fittingSize.height
    }

    private static func configureTextContainer(_ uiView: UITextView, preferredWidth: CGFloat, wrapLines: Bool) {
        uiView.textContainer.widthTracksTextView = wrapLines
        uiView.textContainer.heightTracksTextView = false
        uiView.textContainer.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
        if wrapLines {
            uiView.textContainer.size = CGSize(
                width: max(1, uiView.bounds.width),
                height: UIView.layoutFittingExpandedSize.height
            )
            return
        }
        uiView.textContainer.size = CGSize(
            width: preferredWidth,
            height: UIView.layoutFittingExpandedSize.height
        )
        uiView.contentSize = CGSize(
            width: preferredWidth + uiView.adjustedContentInset.right,
            height: max(uiView.contentSize.height, 1)
        )
    }

    private static func configureScrollInsets(_ uiView: UITextView, wrapLines: Bool) {
        let inset = wrapLines
            ? UIEdgeInsets.zero
            : UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 24)
        if uiView.contentInset != inset {
            uiView.contentInset = inset
            uiView.scrollIndicatorInsets = inset
        }
    }

    private static func updateHorizontalContentMetrics(_ uiView: UITextView, preferredWidth: CGFloat, wrapLines: Bool) {
        if wrapLines {
            uiView.textContainer.widthTracksTextView = true
            uiView.textContainer.lineBreakMode = .byCharWrapping
            uiView.alwaysBounceHorizontal = false
            uiView.showsHorizontalScrollIndicator = false
            let viewportWidth = max(1, uiView.bounds.width)
            uiView.textContainer.size = CGSize(
                width: viewportWidth,
                height: UIView.layoutFittingExpandedSize.height
            )
            if abs(uiView.contentSize.width - viewportWidth) > 0.5 {
                uiView.contentSize.width = viewportWidth
            }
            let leftOffset = -uiView.adjustedContentInset.left
            if abs(uiView.contentOffset.x - leftOffset) > 0.5 {
                uiView.setContentOffset(
                    CGPoint(x: leftOffset, y: uiView.contentOffset.y),
                    animated: false
                )
            }
            return
        }

        uiView.layoutManager.ensureLayout(for: uiView.textContainer)

        let measuredWidth = measuredLineWidth(for: uiView.attributedText)
        let viewportWidth = max(1, uiView.bounds.width)
        let trailingPadding: CGFloat = 96
        let requiredWidth = ceil(max(preferredWidth, measuredWidth + trailingPadding, viewportWidth + 1))

        uiView.textContainer.widthTracksTextView = false
        uiView.textContainer.size = CGSize(
            width: requiredWidth,
            height: UIView.layoutFittingExpandedSize.height
        )
        if let sourceTextView = uiView as? NoCaretSourceTextView {
            sourceTextView.minimumContentWidth = requiredWidth
        }

        let scrollableWidth = requiredWidth
            + uiView.textContainerInset.left
            + uiView.textContainerInset.right
        if abs(uiView.contentSize.width - scrollableWidth) > 0.5 {
            uiView.contentSize.width = scrollableWidth
        }

        let maximumOffsetX = max(
            -uiView.adjustedContentInset.left,
            uiView.contentSize.width - uiView.bounds.width + uiView.adjustedContentInset.right
        )
        if uiView.contentOffset.x > maximumOffsetX {
            uiView.setContentOffset(
                CGPoint(x: maximumOffsetX, y: uiView.contentOffset.y),
                animated: false
            )
        }
    }

    private static func measuredLineWidth(for attributedText: NSAttributedString?) -> CGFloat {
        guard let attributedText, attributedText.length > 0 else { return 1 }
        var maxWidth: CGFloat = 1
        let fullText = attributedText.string as NSString
        fullText.enumerateSubstrings(
            in: NSRange(location: 0, length: fullText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            guard range.length > 0 else { return }
            let line = attributedText.attributedSubstring(from: range)
            let width = line.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).width
            maxWidth = max(maxWidth, width)
        }
        return ceil(maxWidth)
    }

    final class Coordinator: NSObject {
        var lastText = ""
        var lastLanguage = ""
        var lastFontPointSize: CGFloat = 0
        var lastLineSpacing: CGFloat = 0
        var lastIsDarkMode = false
        var lastMaximumHeight: CGFloat = -1
        var lastContentWidth: CGFloat = 0
        var lastAutoFollowTail = false
        var lastWrapLines = true
        var lastTextColor: UIColor = .clear
    }
}

private final class NoCaretSourceTextView: UITextView {
    var selectionEnabled = true
    var minimumContentWidth: CGFloat = 0
    var wrapLines = true

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !wrapLines else {
            textContainer.widthTracksTextView = true
            textContainer.lineBreakMode = .byCharWrapping
            let viewportWidth = max(1, bounds.width)
            textContainer.size = CGSize(
                width: viewportWidth,
                height: UIView.layoutFittingExpandedSize.height
            )
            if abs(contentSize.width - viewportWidth) > 0.5 {
                contentSize.width = viewportWidth
            }
            let leftOffset = -adjustedContentInset.left
            if abs(contentOffset.x - leftOffset) > 0.5 {
                setContentOffset(CGPoint(x: leftOffset, y: contentOffset.y), animated: false)
            }
            return
        }
        guard minimumContentWidth > bounds.width else { return }
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(
            width: minimumContentWidth,
            height: UIView.layoutFittingExpandedSize.height
        )
        if contentSize.width < minimumContentWidth {
            contentSize.width = minimumContentWidth
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard selectionEnabled else { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

private extension CGFloat {
    func nonZero(or fallback: CGFloat) -> CGFloat {
        self > 1 ? self : fallback
    }
}

private enum SourceCodeHighlighter {
    static func highlighted(
        _ code: String,
        language: String,
        font: UIFont,
        baseColor: UIColor,
        isDarkMode: Bool,
        lineSpacing: CGFloat,
        lineBreakMode: NSLineBreakMode
    ) -> NSAttributedString {
        let palette = SourceSyntaxPalette.palette(isDarkMode: isDarkMode, fallback: baseColor)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = lineBreakMode

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.plain,
            .paragraphStyle: paragraphStyle
        ]
        let output = NSMutableAttributedString(string: code, attributes: attributes)
        let fullRange = NSRange(code.startIndex..<code.endIndex, in: code)
        guard fullRange.length > 0 else { return output }

        let keywords = keywordSet(for: language)
        apply(color: palette.comment, pattern: #"(?m)#.*$|//.*$"#, in: output)
        apply(color: palette.comment, pattern: #"(?s)/\*.*?\*/"#, in: output)
        apply(color: palette.string, pattern: #""(\\.|[^"])*"|'(\\.|[^'])*'"#, in: output)
        apply(color: palette.number, pattern: #"\b\d+(\.\d+)?\b"#, in: output)
        if !keywords.isEmpty {
            apply(color: palette.keyword, pattern: #"\b(\#(keywords.joined(separator: "|")))\b"#, in: output)
        }
        apply(color: palette.type, pattern: #"\b([A-Z][A-Za-z0-9_]*)\b"#, in: output)
        apply(color: palette.function, pattern: #"\b([a-zA-Z_][A-Za-z0-9_]*)\s*(?=\()"#, in: output)

        return output
    }

    private static func apply(color: UIColor, pattern: String, in output: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let source = output.string
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: fullRange) {
            output.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func keywordSet(for language: String) -> [String] {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "swift":
            return ["let", "var", "func", "struct", "class", "enum", "if", "else", "guard", "return", "import", "protocol", "extension"]
        case "python", "py":
            return ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "try", "except", "with", "as"]
        case "javascript", "js", "typescript", "ts":
            return ["const", "let", "var", "function", "class", "if", "else", "return", "import", "export", "async", "await"]
        case "json":
            return ["true", "false", "null"]
        default:
            return ["if", "else", "for", "while", "return", "class", "func", "def", "const", "let", "var", "import"]
        }
    }
}

private struct SourceSyntaxPalette {
    let plain: UIColor
    let keyword: UIColor
    let string: UIColor
    let number: UIColor
    let comment: UIColor
    let function: UIColor
    let type: UIColor

    static func palette(isDarkMode: Bool, fallback: UIColor) -> SourceSyntaxPalette {
        if isDarkMode {
            return SourceSyntaxPalette(
                plain: UIColor(red: 0.83, green: 0.84, blue: 0.86, alpha: 1),
                keyword: UIColor(red: 0.63, green: 0.96, blue: 0.70, alpha: 1),
                string: UIColor(red: 0.93, green: 0.80, blue: 0.48, alpha: 1),
                number: UIColor(red: 0.76, green: 0.95, blue: 0.60, alpha: 1),
                comment: UIColor(red: 0.58, green: 0.69, blue: 0.61, alpha: 1),
                function: UIColor(red: 0.79, green: 0.95, blue: 0.67, alpha: 1),
                type: UIColor(red: 0.55, green: 0.93, blue: 0.82, alpha: 1)
            )
        }
        return SourceSyntaxPalette(
            plain: fallback,
            keyword: UIColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1),
            string: UIColor(red: 0.64, green: 0.08, blue: 0.08, alpha: 1),
            number: UIColor(red: 0.04, green: 0.53, blue: 0.34, alpha: 1),
            comment: UIColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1),
            function: UIColor(red: 0.47, green: 0.37, blue: 0.15, alpha: 1),
            type: UIColor(red: 0.15, green: 0.50, blue: 0.60, alpha: 1)
        )
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
        normalizedLanguage.contains("iexa_alpine")
            || normalizedLanguage.contains("local_alpine_exec")
            || code.contains("\"iexa_alpine\"")
            || code.contains("\"local_alpine_exec\"")
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

        if let nested = dict["iexa_alpine"] ?? dict["local_alpine_exec"] ?? dict["commands"] {
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
            GeometryReader { proxy in
                SourceCodeTextView(
                    code: code,
                    language: language,
                    maxHeight: max(240, proxy.size.height),
                    wrapLines: true
                )
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
