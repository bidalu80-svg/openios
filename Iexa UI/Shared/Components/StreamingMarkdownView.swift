import UIKit
import SwiftUI
import Photos
import MarkdownView
import Charts
import WebKit
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
    private static let segmentParseCache: NSCache<NSString, SegmentCacheEntry> = {
        let cache = NSCache<NSString, SegmentCacheEntry>()
        cache.countLimit = 160
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

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
                        .codeAutoScroll(isStreaming)
                        .fixedSize(horizontal: false, vertical: true)
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
        let renderContent = normalizedInlineFenceOpenersAfterProse(
            in: Self.normalizedApostropheFenceMarkers(content)
        )
        guard !renderContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        if !isStreaming {
            let key = Self.segmentCacheKey(for: renderContent)
            if let cached = Self.segmentParseCache.object(forKey: key) {
                return cached.segments
            }
            let segments = resolveSegmentsUncached(renderContent)
            let cost = max(renderContent.utf8.count, segments.count * 128)
            Self.segmentParseCache.setObject(
                SegmentCacheEntry(segments: segments),
                forKey: key,
                cost: min(cost, 2 * 1_024 * 1_024)
            )
            return segments
        }

        return resolveSegmentsUncached(renderContent)
    }

    private func resolveSegmentsUncached(_ renderContent: String) -> [ContentSegment] {
        if InlineDataPayloadSanitizer.mayContainInlineDataURI(renderContent) {
            let safeText = Self.sanitizedMarkdownTextForDisplay(renderContent)
            return safeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [.markdown(safeText)]
        }

        if isStreaming {
            // ── VIZ marker path ───────────────────────────────────────────────
            let vizState = VizMarkerParser.streamingParse(renderContent)
            switch vizState {
            case .noMarkers:
                break   // fall through to code-block detection below

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
        }

        // Use the same unfinished-fence recovery in streaming and completed states
        // so a message does not reparse into loose Markdown when generation ends.
        if let streamingSeg = resolveStreamingCodeBlock(renderContent) {
            return streamingSeg
        }

        // No incomplete special block found — but there may be a complete block
        // (opening AND closing fence both arrived). Keep the existing final parser
        // for HTML/SVG/chart previews and normal fenced code blocks.
        return parseSpecialBlocks(renderContent)
    }

    private static func segmentCacheKey(for text: String) -> NSString {
        "\(text.utf8.count):\(text.hashValue)" as NSString
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

        var result: [ContentSegment] = []
        let before = String(text[text.startIndex..<openRange.lowerBound])
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(contentsOf: parseSpecialBlocks(before))
        }

        let recoveredBlock = recoveredStreamingCodeBlock(language: rawLanguage, content: rawPartialContent)
        if Self.isHiddenInternalToolBlock(language: recoveredBlock.language, code: recoveredBlock.content) {
            return result
        }
        guard Self.shouldRenderFenceAsCode(language: recoveredBlock.language, code: recoveredBlock.content) else {
            let demotedFence = Self.demotedRejectedFenceMarkdown(
                language: recoveredBlock.language,
                code: recoveredBlock.content
            )
            if !demotedFence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(demotedFence))
            }
            return result
        }

        result.append(streamingCodeSegment(
            language: recoveredBlock.language,
            code: recoveredBlock.content
        ))
        return result
    }

    private func findUnclosedOpeningFence(in text: String) -> Range<String.Index>? {
        var cursor = text.startIndex

        while let openRange = findOpeningFence(in: text[cursor..<text.endIndex]) {
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
        if let marker = recoverableLanguageLine(from: lines.first),
           isRecognizedCodeLanguage(marker) {
            lines.removeFirst()
            return ParsedBlock(language: marker, content: lines.joined(separator: "\n"))
        }

        return ParsedBlock(language: "text", content: content)
    }

    private func streamingCodeSegment(language: String, code: String) -> ContentSegment {
        codeSegmentForFence(
            language: language,
            code: code,
            isStreamingBlock: true
        )
    }

    private func codeSegmentForFence(
        language: String,
        code: String,
        isStreamingBlock: Bool
    ) -> ContentSegment {
        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if Self.isHiddenInternalToolBlock(language: normalizedLanguage, code: code) {
            return .markdown("")
        }
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
        if mathLanguageTags.contains(normalizedLanguage) {
            return .math(code, displayMode: true)
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
        if Self.isPlainTextFence(language: normalizedLanguage),
           !Self.looksLikeSourceCode(code) {
            return .markdown(code)
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
                    .codeAutoScroll(isStreaming)
                    .fixedSize(horizontal: false, vertical: true)
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
        case .math(let latex, let displayMode):
            KaTeXFormulaView(latex: latex, displayMode: displayMode, textColor: textColor)
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
    private let mathLanguageTags: Set<String> = ["math", "latex", "tex", "katex"]

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
        case math(String, displayMode: Bool)
        case markdownImage(imageURL: URL, altText: String, linkURL: URL?)
        case visualization(String)
    }

    private final class SegmentCacheEntry {
        let segments: [ContentSegment]

        init(segments: [ContentSegment]) {
            self.segments = segments
        }
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
        if trimmed.hasPrefix("data:image/") || trimmed.hasPrefix("image:data/") {
            return nil
        }
        return nil
    }

    private static func normalizedDataImageReference(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        if trimmed.hasPrefix("image:data/") {
            return "data:image/" + String(trimmed.dropFirst("image:data/".count))
        }
        return trimmed
    }

    private static func normalizedApostropheFenceMarkers(_ text: String) -> String {
        guard text.contains("'''") else { return text }
        return text.replacingOccurrences(
            of: #"(?m)^([ \t]*)'''([A-Za-z0-9_+.-]*)[ \t]*$"#,
            with: "$1```$2",
            options: .regularExpression
        )
    }

    private static func sanitizedMarkdownTextForDisplay(_ text: String) -> String {
        var cleaned = text
        if InlineDataPayloadSanitizer.mayContainLargeInlinePayload(cleaned)
            || Self.containsPartialInlineDataImageReference(cleaned) {
            cleaned = InlineDataPayloadSanitizer.sanitizedDisplayText(cleaned)
            cleaned = InlineDataPayloadSanitizer.removingHiddenPayloadArtifacts(from: cleaned)
        }
        cleaned = removeProviderCitationArtifacts(from: cleaned)
        cleaned = InlineDataPayloadSanitizer.sanitizedDisplayText(cleaned)
        cleaned = InlineDataPayloadSanitizer.removingHiddenPayloadArtifacts(from: cleaned)
        cleaned = normalizedDisplayLinks(in: cleaned)
        return cleaned
    }

    private static func containsPartialInlineDataImageReference(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("data:imag")
            || lower.contains("image:data")
            || (lower.contains("![") && lower.contains("](data:"))
            || (lower.contains("<img") && lower.contains("src=") && lower.contains("data:"))
    }

    private static func normalizedDisplayLinks(in text: String) -> String {
        transformOutsideFencedCode(in: text) { prose in
            let unwrapped = unwrapRedundantMarkdownLinkBrackets(in: prose)
            let compacted = compactBareLinks(in: unwrapped)
            return unwrapRedundantMarkdownLinkBrackets(in: compacted)
        }
    }

    private static func unwrapRedundantMarkdownLinkBrackets(in text: String) -> String {
        let pattern = #"(?<!\!)\[\s*(\[[^\]\n]+\]\([^\)\n]+\))\s*\]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: "$1"
        )
    }

    private static func compactBareLinks(in text: String) -> String {
        let text = compactMarkdownLinksWhoseTitleIsURL(in: text)
        let textWithBracketedLinks = compactBracketedBareLinks(in: text)
        let pattern = #"(?<![\]\(\[])https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return textWithBracketedLinks }
        let nsText = textWithBracketedLinks as NSString
        let matches = regex.matches(in: textWithBracketedLinks, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return textWithBracketedLinks }

        var result = textWithBracketedLinks
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

    private static func compactMarkdownLinksWhoseTitleIsURL(in text: String) -> String {
        let pattern = #"(?<!\!)\[\s*(https?://[^\]\s<>"']+)\s*\]\((https?://[^\)\s<>"']+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let destination = nsText.substring(with: match.range(at: 2))
            guard URL(string: destination) != nil,
                  let range = Range(match.range, in: result) else { continue }
            let title = compactLinkTitle(for: destination)
            result.replaceSubrange(range, with: "[\(title) ↗](\(destination))")
        }
        return result
    }

    private static func compactBracketedBareLinks(in text: String) -> String {
        let pattern = #"(?<!\!)\[\s*(https?://[^\]\s<>"']+)\s*\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let raw = nsText.substring(with: match.range(at: 1))
            let (url, trailing) = splitTrailingPunctuation(from: raw)
            guard !url.isEmpty,
                  URL(string: url) != nil,
                  let range = Range(match.range, in: result) else { continue }
            let title = compactLinkTitle(for: url)
            result.replaceSubrange(range, with: "[\(title) ↗](\(url))\(trailing)")
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
        if lowerHost.contains("xiaohongshu.com") || lowerHost.contains("xhslink.com") {
            return "小红书笔记"
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
                return fence.lowerBound..<lineEnd
            }
            cursor = fence.upperBound
        }
        return nil
    }

    private static func isLikelyDirtyClosingFenceSuffix(_ suffix: Substring) -> Bool {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("```") || trimmed.contains("~~~") {
            return true
        }
        if recognizedFenceLanguageTokens.contains(trimmed.lowercased()) {
            return true
        }

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
            "关键", "说明", "建议", "注意", "总结", "备注", "解析", "修复", "执行", "运行", "输出", "结果", "效果", "方式", "下一步",
            "示例", "预期", "命令", "使用", "保存", "文件", "代码", "之后", "最终", "测试", "如下", "例如", "比如",
            "然后", "接着", "继续", "再", "访问", "返回", "会返回", "得到", "打开", "查看",
            "但", "如果", "不过", "另外", "并且", "而且", "同时", "因此", "所以", "当前", "这里", "上面", "下面", "这个", "下面这个",
            "已通过", "通过", "语法检查", "运行测试", "测试结果",
            "key", "notes", "note", "summary", "explanation", "recommendation", "next", "example",
            "output", "result", "results", "stdout", "stderr", "command", "usage", "expected", "then", "after",
            "visit", "open", "returns", "return", "response",
            "but", "if", "however", "also", "therefore", "so", "because"
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
        if Self.isHiddenInternalToolBlock(language: "json", code: trimmed),
           looksLikeStandaloneJSON(trimmed) {
            return []
        }
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
        let parseText = normalizedInlineFenceOpenersAfterProse(in: text)
        guard parseText.contains("```") else { return parseMathSegments(parseText) }

        var units: [EitherContent] = []
        var removedInternalToolBlock = false
        var remaining = parseText[parseText.startIndex...]

        while let openRange = findOpeningFence(in: remaining) {
            let afterOpen = remaining[openRange.upperBound...]
            guard let newlineIdx = afterOpen.firstIndex(of: "\n") else {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                let rawLanguage = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isHiddenInternalToolBlock(language: rawLanguage, code: "") {
                    removedInternalToolBlock = true
                    if units.isEmpty { return [] }
                    return collapseParsedUnits(units, fallback: parseText)
                }
                guard Self.shouldRenderFenceAsCode(language: rawLanguage, code: "") else {
                    let demotedFence = Self.demotedRejectedFenceMarkdown(language: rawLanguage, code: "")
                    if !demotedFence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        units.append(.markdown(demotedFence))
                    }
                    return collapseParsedUnits(units, fallback: parseText)
                }
                units.append(.segment(.codeBlock(
                    language: rawLanguage.isEmpty ? "text" : rawLanguage,
                    code: ""
                )))
                return collapseParsedUnits(units, fallback: parseText)
            }
            let rawLanguage = afterOpen[afterOpen.startIndex..<newlineIdx]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let contentStart = afterOpen.index(after: newlineIdx)
            let searchArea = remaining[contentStart...]
            guard let closeRange = findClosingFence(in: searchArea, from: contentStart) else {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                let unclosedCode = String(searchArea)
                if Self.isHiddenInternalToolBlock(language: rawLanguage, code: unclosedCode) {
                    removedInternalToolBlock = true
                    if units.isEmpty { return [] }
                    return collapseParsedUnits(units, fallback: parseText)
                }
                if !unclosedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.segment(codeSegmentForFence(
                        language: rawLanguage.isEmpty ? "text" : rawLanguage,
                        code: unclosedCode,
                        isStreamingBlock: isStreaming
                    )))
                }
                return collapseParsedUnits(units, fallback: parseText)
            }
            let rawCodeContent = String(remaining[contentStart..<closeRange.lowerBound])
            let recoveredFence = recoveredMalformedFence(language: rawLanguage, content: rawCodeContent)
            let lang = displayLanguage(forFenceInfo: recoveredFence.language)
            let codeContent = recoveredFence.content
            if !Self.isRenderableClosedFenceLanguage(lang) {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                let demotedFence = Self.demotedRejectedFenceMarkdown(
                    language: recoveredFence.language,
                    code: codeContent
                )
                if !demotedFence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(demotedFence))
                }
                let blockEnd = closeRange.upperBound
                remaining = normalizedFenceTail(remaining[blockEnd...])
                continue
            }
            if Self.isHiddenInternalToolBlock(language: lang, code: codeContent) {
                removedInternalToolBlock = true
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                remaining = remaining[closeRange.upperBound...]
                continue
            }
            if !Self.shouldRenderFenceAsCode(language: recoveredFence.language, code: codeContent) {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                let demotedFence = Self.demotedRejectedFenceMarkdown(
                    language: recoveredFence.language,
                    code: codeContent
                )
                if !demotedFence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(demotedFence))
                }
                let blockEnd = closeRange.upperBound
                remaining = normalizedFenceTail(remaining[blockEnd...])
                continue
            }
            let normalizedBlock = normalizedCodeBlock(language: lang, content: codeContent)
            let isChart = chartLanguageTags.contains(lang) && looksLikeChartJSON(codeContent)
            let isHTML = lang == "html" && codeContent.contains("<") && codeContent.contains(">") && codeContent.count >= 10
            let isLinkedWebAsset = lang == "css" || lang == "js" || lang == "javascript"
            let isMermaid = lang == "mermaid" && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
            let isSVG = lang == "svg" && looksLikeSVG(codeContent)
            let isPython = pythonLanguageTags.contains(lang)
            let isMath = mathLanguageTags.contains(lang)
            let isCompactModule = shouldRenderCompactCodeModule(language: lang, code: codeContent)
            let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
            let isPlainTextFence = Self.isPlainTextFence(language: lang)
            let isStandardCodeBlock = normalizedBlock != nil
                && (!isPlainTextFence || Self.looksLikeSourceCode(codeContent))

            if isPlainTextFence && !Self.looksLikeSourceCode(codeContent) {
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                if !codeContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(codeContent))
                }
                remaining = normalizedFenceTail(remaining[closeRange.upperBound...])
            } else if isChart || isHTML || isLinkedWebAsset || isMermaid || isSVG || isPython || isMath || isCompactModule || isStandardCodeBlock {
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.markdown(preceding))
                }
                if isChart { units.append(.segment(.chart(codeContent))) }
                else if isMath { units.append(.segment(.math(codeContent, displayMode: true))) }
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
                remaining = normalizedFenceTail(remaining[closeRange.upperBound...])
            } else {
                let blockEnd = closeRange.upperBound
                units.append(.markdown(String(remaining[remaining.startIndex..<blockEnd])))
                remaining = normalizedFenceTail(remaining[blockEnd...])
            }
        }

        if !remaining.isEmpty {
            let s = String(remaining)
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                units.append(.markdown(s))
            }
        }

        if units.isEmpty && removedInternalToolBlock {
            return []
        }
        return collapseParsedUnits(units, fallback: parseText)
    }

    private func parseMathSegments(_ text: String) -> [ContentSegment] {
        guard text.contains("$$") || text.contains("\\[") || text.contains("$") || text.contains("\\(") else {
            return text.isEmpty ? [] : [.markdown(text)]
        }

        var segments: [ContentSegment] = []
        var cursor = text.startIndex

        func appendMarkdown(_ markdown: String) {
            guard !markdown.isEmpty else { return }
            segments.append(contentsOf: parseStandaloneInlineMathSegments(markdown))
        }

        while let match = nextDisplayMathRange(in: text, from: cursor) {
            if cursor < match.range.lowerBound {
                appendMarkdown(String(text[cursor..<match.range.lowerBound]))
            }

            let latex = match.latex.trimmingCharacters(in: .whitespacesAndNewlines)
            if latex.isEmpty {
                appendMarkdown(String(text[match.range]))
            } else {
                segments.append(.math(latex, displayMode: true))
            }
            cursor = match.range.upperBound
        }

        if cursor < text.endIndex {
            appendMarkdown(String(text[cursor..<text.endIndex]))
        }

        return segments.isEmpty ? [.markdown(text)] : segments
    }

    private func parseStandaloneInlineMathSegments(_ text: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        var markdown = ""
        let lines = text.components(separatedBy: "\n")

        func flushMarkdown() {
            guard !markdown.isEmpty else { return }
            segments.append(.markdown(markdown))
            markdown = ""
        }

        for index in lines.indices {
            let line = lines[index]
            let suffix = index < lines.count - 1 ? "\n" : ""
            if let math = standaloneInlineMath(in: line) {
                flushMarkdown()
                segments.append(.math(math.latex, displayMode: math.displayMode))
            } else {
                markdown += line + suffix
            }
        }
        flushMarkdown()

        return segments.isEmpty ? [.markdown(text)] : segments
    }

    private func standaloneInlineMath(in line: String) -> (latex: String, displayMode: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("$"),
           trimmed.hasSuffix("$"),
           !trimmed.hasPrefix("$$"),
           !trimmed.hasSuffix("$$"),
           trimmed.count > 2 {
            let latex = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return latex.isEmpty ? nil : (latex, false)
        }

        if trimmed.hasPrefix("\\("),
           trimmed.hasSuffix("\\)"),
           trimmed.count > 4 {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
            let latex = String(trimmed[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return latex.isEmpty ? nil : (latex, false)
        }

        return nil
    }

    private func nextDisplayMathRange(
        in text: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, latex: String)? {
        let dollar = nextPairedMathDelimiter(open: "$$", close: "$$", in: text, from: start, honorEscapes: true)
        let bracket = nextPairedMathDelimiter(open: "\\[", close: "\\]", in: text, from: start, honorEscapes: false)

        switch (dollar, bracket) {
        case (.some(let lhs), .some(let rhs)):
            return lhs.range.lowerBound <= rhs.range.lowerBound ? lhs : rhs
        case (.some(let match), .none), (.none, .some(let match)):
            return match
        case (.none, .none):
            return nil
        }
    }

    private func nextPairedMathDelimiter(
        open: String,
        close: String,
        in text: String,
        from start: String.Index,
        honorEscapes: Bool
    ) -> (range: Range<String.Index>, latex: String)? {
        var cursor = start
        while cursor < text.endIndex,
              let openRange = text.range(of: open, range: cursor..<text.endIndex) {
            if honorEscapes && Self.isEscaped(openRange.lowerBound, in: text) {
                cursor = openRange.upperBound
                continue
            }

            guard let closeRange = firstMathMarkerRange(
                of: close,
                in: text,
                from: openRange.upperBound,
                honorEscapes: honorEscapes
            ) else {
                return nil
            }

            return (
                openRange.lowerBound..<closeRange.upperBound,
                String(text[openRange.upperBound..<closeRange.lowerBound])
            )
        }
        return nil
    }

    private func firstMathMarkerRange(
        of marker: String,
        in text: String,
        from start: String.Index,
        honorEscapes: Bool
    ) -> Range<String.Index>? {
        var cursor = start
        while cursor < text.endIndex,
              let range = text.range(of: marker, range: cursor..<text.endIndex) {
            if !honorEscapes || !Self.isEscaped(range.lowerBound, in: text) {
                return range
            }
            cursor = range.upperBound
        }
        return nil
    }

    private static func isEscaped(_ index: String.Index, in text: String) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount % 2 == 1
    }

    private func normalizedInlineFenceOpenersAfterProse(in text: String) -> String {
        guard text.contains("```") else { return text }

        let lines = text.components(separatedBy: "\n")
        let repaired = lines.map { line -> String in
            guard let fence = line.range(of: "```") else { return line }
            let afterFence = line[fence.upperBound...]
            guard !afterFence.contains("```") else { return line }

            let beforeFence = line[line.startIndex..<fence.lowerBound]
            let beforeTrimmed = beforeFence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !beforeTrimmed.isEmpty,
                  Self.shouldSplitInlineFenceOpener(beforeFence) else {
                return line
            }

            let rawLanguage = afterFence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let fenceInfo = splitInlineFenceInfo(rawLanguage) else { return line }

            if let inlineCode = fenceInfo.inlineCode {
                return beforeTrimmed + "\n```" + fenceInfo.language + "\n" + inlineCode
            }
            return beforeTrimmed + "\n```" + fenceInfo.language
        }

        return repaired.joined(separator: "\n")
    }

    private func splitInlineFenceInfo(_ rawFenceInfo: String) -> (language: String, inlineCode: String?)? {
        let trimmed = rawFenceInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return ("", nil) }

        let language = displayLanguage(forFenceInfo: String(first))
        guard !language.isEmpty || String(first).isEmpty else { return nil }

        if parts.count == 1 {
            guard language.count <= 32 else { return nil }
            return (language, nil)
        }

        guard isRecognizedCodeLanguage(language) else { return nil }
        let inlineCode = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeInlineFenceCode(inlineCode) else { return nil }
        return (language, inlineCode)
    }

    private func findOpeningFence(in text: Substring) -> Range<String.Index>? {
        var cursor = text.startIndex
        while let candidate = text.range(of: "```", range: cursor..<text.endIndex) {
            let lineStart = startOfFenceLine(in: text, before: candidate.lowerBound, fallback: text.startIndex)
            let prefix = text[lineStart..<candidate.lowerBound]
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
            cursor = candidate.upperBound
        }
        return nil
    }

    private func normalizedFenceTail(_ tail: Substring) -> Substring {
        guard !tail.isEmpty else { return tail }
        let lineEnd = tail.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? tail.endIndex
        let firstLine = tail[tail.startIndex..<lineEnd]
        guard let inlineFence = firstLine.range(of: "```") else { return tail }

        let beforeFence = firstLine[firstLine.startIndex..<inlineFence.lowerBound]
        let beforeTrimmed = beforeFence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !beforeTrimmed.isEmpty,
              Self.shouldSplitInlineFenceOpener(beforeFence) else {
            return tail
        }

        let repaired = String(beforeFence) + "\n" + String(tail[inlineFence.lowerBound..<tail.endIndex])
        return repaired[repaired.startIndex...]
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
            let lineEnd = afterFence.firstIndex { $0 == "\n" || $0 == "\r" } ?? searchArea.endIndex
            let suffixBeforeNewline = afterFence[afterFence.startIndex..<lineEnd]
            let isFenceOnlyLine = suffixBeforeNewline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isAtFenceLineStart && isFenceOnlyLine {
                return lineStart..<fence.upperBound
            }
            if isAtFenceLineStart && Self.isLikelyDirtyClosingFenceSuffix(suffixBeforeNewline) {
                return lineStart..<lineEnd
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
        guard !units.isEmpty else { return parseMathSegments(text) }

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
                segments.append(contentsOf: parseMathSegments(markdown))
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

        return segments.isEmpty ? parseMathSegments(text) : segments
    }

    private func normalizedCodeBlock(language: String, content: String) -> ParsedBlock? {
        let trimmedLanguage = displayLanguage(forFenceInfo: language)
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
        if let marker = recoverableLanguageLine(from: lines.first),
           isRecognizedCodeLanguage(marker) {
            lines.removeFirst()
            let recoveredContent = lines.joined(separator: "\n")
            if !recoveredContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ParsedBlock(language: marker, content: recoveredContent)
            }
        }

        if !trimmedContent.isEmpty, trimmedLanguage.isEmpty {
            return ParsedBlock(language: "text", content: content)
        }
        return nil
    }

    private func recoveredMalformedFence(language: String, content: String) -> ParsedBlock {
        let originalLanguageLine = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLanguage = displayLanguage(forFenceInfo: originalLanguageLine)
        guard !normalizedLanguage.isEmpty else {
            return ParsedBlock(language: normalizedLanguage, content: content)
        }
        guard originalLanguageLine.contains(where: { $0.isWhitespace }) else {
            return ParsedBlock(language: normalizedLanguage, content: content)
        }

        let parts = originalLanguageLine.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else {
            return ParsedBlock(language: normalizedLanguage, content: content)
        }
        let languageToken = displayLanguage(forFenceInfo: String(parts[0]))
        let firstCommandLine = String(parts[1])
        guard looksLikeInlineFenceCode(firstCommandLine) else {
            return ParsedBlock(language: languageToken.isEmpty ? normalizedLanguage : languageToken, content: content)
        }

        let recoveredContent = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstCommandLine
            : firstCommandLine + "\n" + content
        return ParsedBlock(language: languageToken.isEmpty ? normalizedLanguage : languageToken, content: recoveredContent)
    }

    private func recoverableLanguageLine(from line: String?) -> String? {
        guard let line else { return nil }
        let marker = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !marker.isEmpty,
              marker.range(of: #"^[a-z0-9_+#.-]{1,32}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return marker
    }

    private func displayLanguage(forFenceInfo language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        let firstToken = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_+-#.")
        if firstToken.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return firstToken
        }
        return trimmed
    }

    private static func shouldRenderFenceAsCode(language: String, code: String) -> Bool {
        let rawLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = rawLanguage.lowercased()
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isHiddenInternalToolBlock(language: normalized, code: code) else { return false }
        guard !rawLanguage.isEmpty else { return !trimmedCode.isEmpty }

        let firstToken = normalized.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? normalized
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_+-#.")
        let firstTokenIsSafe = firstToken.unicodeScalars.allSatisfy { allowed.contains($0) }
        let wholeInfoIsSafe = normalized.unicodeScalars.allSatisfy { allowed.contains($0) }
        if wholeInfoIsSafe {
            return !trimmedCode.isEmpty || StreamingMarkdownView.recognizedFenceLanguageTokens.contains(normalized)
        }
        if firstTokenIsSafe,
           StreamingMarkdownView.recognizedFenceLanguageTokens.contains(firstToken),
           !trimmedCode.isEmpty {
            return true
        }
        return false
    }

    private static func demotedRejectedFenceMarkdown(language: String, code: String) -> String {
        let title = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return body }
        if body.isEmpty { return title }
        return title + "\n" + body
    }

    private static func isRenderableClosedFenceLanguage(_ language: String) -> Bool {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static let recognizedFenceLanguageTokens: Set<String> = [
        "bash", "sh", "shell", "zsh", "fish", "powershell", "ps1",
        "nginx", "conf", "ini", "toml", "yaml", "yml", "xml",
        "swift", "kotlin", "java", "javascript", "js", "typescript", "ts",
        "tsx", "jsx", "html", "css", "scss", "python", "python3", "py",
        "ruby", "rb", "go", "rust", "rs", "c", "cpp", "c++", "objc",
        "objective-c", "php", "lua", "sql", "dockerfile", "makefile",
        "json", "jsonc", "markdown", "md", "text", "txt", "dart", "r",
        "scala", "groovy", "gradle", "perl", "pl", "haskell", "hs",
        "elixir", "ex", "exs", "erlang", "erl", "clojure", "clj",
        "fsharp", "fs", "ocaml", "ml", "matlab", "julia", "jl",
        "racket", "scheme", "lisp", "vue", "svelte", "csharp", "cs",
        "solidity", "sol", "graphql", "gql", "proto", "protobuf",
        "bat", "cmd", "diff", "patch", "regex", "vim", "vimscript",
        "mermaid", "svg", "math", "latex"
    ]

    private func looksLikeInlineFenceCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        let codeSignals = [
            "(", ")", "{", "}", "[", "]", "=", ";", "&&", "||", "|", "<", ">",
            "import ", "from ", "def ", "class ", "function ", "const ", "let ", "var ",
            "package ", "func ", "type ", "struct ", "local ", "print", "echo ", "cat ", "python", "node ", "npm ", "pip ",
            "curl ", "wget ", "apk ", "swift ", "go ", "cargo ", "ruby ", "php "
        ]
        return codeSignals.contains { lowered.contains($0) }
    }

    private static func shouldSplitInlineFenceOpener(_ prefix: Substring) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isLikelyDirtyClosingFenceSuffix(prefix) {
            return true
        }

        let lowered = trimmed.lowercased()
        let inlineOpenSignals = [
            "例如", "比如", "如下", "运行方式", "执行方式", "使用方式",
            "命令", "示例", "访问", "返回", "会返回", "然后", "接着",
            "for example", "like this", "run", "command", "usage",
            "visit", "open", "returns", "response"
        ]
        if inlineOpenSignals.contains(where: { lowered.contains($0) }) {
            return true
        }

        return trimmed.hasSuffix(":") || trimmed.hasSuffix("：")
    }

    private static func isPlainTextFence(language: String) -> Bool {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "text" || normalized == "txt" || normalized == "markdown" || normalized == "md"
    }

    private static func looksLikeSourceCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        let codeSignals = [
            "function ", "const ", "let ", "var ", "def ", "class ", "import ", "from ",
            "return ", "if ", "else", "for ", "while ", "switch ", "case ", "struct ",
            "func ", "local ", "print(", "console.", "#include", "using namespace",
            "<html", "<script", "<style", "{", "}", "=>", "&&", "||", "==", ":="
        ]
        if codeSignals.contains(where: { lowered.contains($0) }) {
            return true
        }
        let lines = trimmed.components(separatedBy: .newlines)
        let indentedLines = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        return lines.count >= 3 && indentedLines >= 2
    }

    private func isRecognizedCodeLanguage(_ language: String) -> Bool {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return Self.recognizedFenceLanguageTokens.contains(normalized)
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

    private static func isHiddenInternalToolBlock(language: String, code: String) -> Bool {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hiddenTokens = [
            "iexa_alpine",
            "local_alpine_exec",
            "iexa_workspace",
            "iexa_native",
            "local_native_exec",
            "iexa_memory"
        ]
        if hiddenTokens.contains(where: { normalized.contains($0) }) {
            return true
        }

        let loweredCode = code.lowercased()
        return hiddenTokens.contains { token in
            loweredCode.contains("\"\(token)\"")
                || loweredCode.contains("`\(token)`")
                || loweredCode.contains("<\(token)>")
                || loweredCode.contains("</\(token)>")
                || loweredCode.contains("to=\(token)")
                || loweredCode.contains("to = \(token)")
        }
    }

    private func shouldRenderCompactCodeModule(language: String, code: String) -> Bool {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !Self.isHiddenInternalToolBlock(language: normalized, code: code) else {
            return false
        }
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

private struct KaTeXFormulaView: View {
    let latex: String
    let displayMode: Bool
    let textColor: SwiftUI.Color?

    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 28

    var body: some View {
        KaTeXWebView(
            html: html,
            baseURL: Self.resourceDirectory(),
            contentHeight: $contentHeight
        )
        .frame(maxWidth: .infinity, alignment: displayMode ? .center : .leading)
        .frame(height: max(contentHeight, displayMode ? 44 : 28))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(latex)
    }

    private var html: String {
        let encodedLatex = Data(latex.utf8).base64EncodedString()
        let display = displayMode ? "true" : "false"
        let color = Self.cssColor(textColor, scheme: colorScheme)
        let align = displayMode ? "center" : "left"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <link rel="stylesheet" href="katex.min.css">
        <script src="katex.min.js"></script>
        <script src="mhchem.min.js"></script>
        <style>
        html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body { color: \(color); font: 17px/1.35 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
        #math { display: inline-block; max-width: 100%; padding: 2px 0; text-align: \(align); }
        #wrap { width: 100%; text-align: \(align); }
        .fallback { white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 14px; opacity: 0.82; }
        .katex-display { margin: 0; overflow-x: auto; overflow-y: hidden; }
        </style>
        </head>
        <body>
        <div id="wrap"><span id="math"></span></div>
        <script>
        function decodeBase64(value) {
          var bytes = Uint8Array.from(atob(value), function(c) { return c.charCodeAt(0); });
          return new TextDecoder('utf-8').decode(bytes);
        }
        function reportHeight() {
          requestAnimationFrame(function() {
            requestAnimationFrame(function() {
              var height = Math.max(
                document.body.scrollHeight,
                document.documentElement.scrollHeight,
                document.getElementById('math').getBoundingClientRect().height
              );
              window.webkit.messageHandlers.heightHandler.postMessage(Math.ceil(height) + 2);
            });
          });
        }
        (function() {
          var latex = decodeBase64('\(encodedLatex)');
          var el = document.getElementById('math');
          try {
            if (!window.katex) { throw new Error('KaTeX unavailable'); }
            katex.render(latex, el, {
              displayMode: \(display),
              throwOnError: true,
              strict: false,
              trust: false,
              output: 'html'
            });
          } catch (error) {
            el.className = 'fallback';
            el.textContent = latex;
          }
          if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(reportHeight);
          } else {
            reportHeight();
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func resourceDirectory() -> URL? {
        for subdirectory in ["Resources/katex", "katex"] {
            if let url = Bundle.main.url(
                forResource: "katex.min",
                withExtension: "js",
                subdirectory: subdirectory
            ) {
                return url.deletingLastPathComponent()
            }
        }
        return Bundle.main.url(forResource: "katex.min", withExtension: "js")?.deletingLastPathComponent()
    }

    private static func cssColor(_ color: SwiftUI.Color?, scheme: ColorScheme) -> String {
        let uiColor: UIColor
        if let color {
            uiColor = UIColor(color)
        } else {
            uiColor = scheme == .dark ? .white : .black
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return scheme == .dark ? "#ffffff" : "#111111"
        }
        return "rgba(\(Int(red * 255)), \(Int(green * 255)), \(Int(blue * 255)), \(alpha))"
    }
}

private struct KaTeXWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightHandler")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false

        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "heightHandler")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding var contentHeight: CGFloat
        var lastHTML: String?

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let numericHeight: CGFloat?
            if let height = message.body as? CGFloat {
                numericHeight = height
            } else if let height = message.body as? Double {
                numericHeight = CGFloat(height)
            } else if let height = message.body as? Int {
                numericHeight = CGFloat(height)
            } else {
                numericHeight = nil
            }

            guard let numericHeight, numericHeight > 0 else { return }
            DispatchQueue.main.async {
                self.contentHeight = min(max(numericHeight, 24), 600)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

enum InlineDataPayloadSanitizer {
    private static let placeholder = "<已隐藏超长Base64内容>"

    static func sanitizedDisplayText(_ text: String) -> String {
        guard mayContainLargeInlinePayload(text) else {
            return text
        }

        var cleaned = replaceInlineDataURIs(in: text)
        cleaned = replaceLongBase64Runs(in: cleaned)
        return cleaned
    }

    static func mayContainLargeInlinePayload(_ text: String) -> Bool {
        text.range(of: "base64", options: .caseInsensitive) != nil
            || text.range(of: "data:image", options: .caseInsensitive) != nil
            || text.range(of: "data:imag", options: .caseInsensitive) != nil
            || text.range(of: "image:data", options: .caseInsensitive) != nil
            || text.range(of: "data:video", options: .caseInsensitive) != nil
            || text.range(of: "data:audio", options: .caseInsensitive) != nil
    }

    static func mayContainInlineDataURI(_ text: String) -> Bool {
        text.range(of: "data:imag", options: .caseInsensitive) != nil
            || text.range(of: "data:image", options: .caseInsensitive) != nil
            || text.range(of: "image:data", options: .caseInsensitive) != nil
            || text.range(of: "data:video", options: .caseInsensitive) != nil
            || text.range(of: "data:audio", options: .caseInsensitive) != nil
    }

    static func removingHiddenPayloadArtifacts(from text: String) -> String {
        guard text.contains(placeholder)
            || text.contains("![")
            || text.range(of: "<img", options: .caseInsensitive) != nil else {
            return text
        }

        var cleaned = text
        while let markerRange = cleaned.range(of: placeholder) {
            if let removalRange = markdownImageShellRange(around: markerRange, in: cleaned)
                ?? htmlImageShellRange(around: markerRange, in: cleaned) {
                cleaned.removeSubrange(removalRange)
            } else {
                cleaned.removeSubrange(markerRange)
            }
        }
        return collapseExcessBlankLines(in: cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceInlineDataURIs(in text: String) -> String {
        let markers = ["data:image/", "data:imag", "data:audio/", "data:video/", "image:data/", "image:data"]
        var result = ""
        var cursor = text.startIndex
        result.reserveCapacity(min(text.count, 8192))

        while cursor < text.endIndex {
            guard let markerRange = earliestRange(of: markers, in: text, from: cursor) else {
                result += String(text[cursor..<text.endIndex])
                break
            }

            result += String(text[cursor..<markerRange.lowerBound])

            guard let base64Range = text.range(
                of: ";base64,",
                options: .caseInsensitive,
                range: markerRange.upperBound..<text.endIndex
            ) else {
                result += placeholder
                cursor = endOfInlinePayloadCandidate(in: text, from: markerRange.upperBound)
                continue
            }

            result += placeholder
            var payloadCursor = base64Range.upperBound
            while payloadCursor < text.endIndex {
                let character = text[payloadCursor]
                guard isBase64PayloadCharacter(character) else { break }
                payloadCursor = text.index(after: payloadCursor)
            }
            cursor = payloadCursor
        }

        return result
    }

    private static func endOfInlinePayloadCandidate(in text: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == ")" || character == "\"" || character == "'" || character == ">" {
                break
            }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func markdownImageShellRange(
        around markerRange: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[markerRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        guard let open = text.range(of: "![", options: .backwards, range: lineStart..<markerRange.lowerBound),
              text.range(of: "](", options: [], range: open.upperBound..<markerRange.lowerBound) != nil else {
            return nil
        }
        let closeSearchEnd = lineEnd
        let close = text.range(of: ")", options: [], range: markerRange.upperBound..<closeSearchEnd)
        return open.lowerBound..<(close?.upperBound ?? markerRange.upperBound)
    }

    private static func htmlImageShellRange(
        around markerRange: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[markerRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        guard let open = text.range(of: "<img", options: [.caseInsensitive, .backwards], range: lineStart..<markerRange.lowerBound) else {
            return nil
        }
        let close = text.range(of: ">", options: [], range: markerRange.upperBound..<lineEnd)
        return open.lowerBound..<(close?.upperBound ?? markerRange.upperBound)
    }

    private static func collapseExcessBlankLines(in text: String) -> String {
        var result = ""
        var consecutiveNewlines = 0
        result.reserveCapacity(text.count)
        for character in text {
            if character == "\n" {
                consecutiveNewlines += 1
                if consecutiveNewlines <= 2 {
                    result.append(character)
                }
            } else {
                consecutiveNewlines = character.isWhitespace ? consecutiveNewlines : 0
                result.append(character)
            }
        }
        return result
    }

    private static func earliestRange(
        of markers: [String],
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for marker in markers {
            guard let range = text.range(of: marker, options: .caseInsensitive, range: start..<text.endIndex) else {
                continue
            }
            if best == nil || range.lowerBound < best!.lowerBound {
                best = range
            }
        }
        return best
    }

    private static func replaceLongBase64Runs(in text: String) -> String {
        var result = ""
        var run = ""
        result.reserveCapacity(min(text.count, 8192))

        func flushRun() {
            if run.count >= 512 {
                result += placeholder
            } else {
                result += run
            }
            run.removeAll(keepingCapacity: true)
        }

        for character in text {
            if isBase64PayloadCharacter(character), !character.isWhitespace {
                run.append(character)
            } else {
                flushRun()
                result.append(character)
            }
        }
        flushRun()
        return result
    }

    private static func isBase64PayloadCharacter(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 43, 47, 61, 95, 45:
            return true
        default:
            return false
        }
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
                wrapLines: false
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

private final class SourceCodeLayoutMetrics: NSObject {
    let lineCount: Int
    let contentWidth: CGFloat

    init(lineCount: Int, contentWidth: CGFloat) {
        self.lineCount = lineCount
        self.contentWidth = contentWidth
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

    private static let layoutMetricsCache: NSCache<NSString, SourceCodeLayoutMetrics> = {
        let cache = NSCache<NSString, SourceCodeLayoutMetrics>()
        cache.countLimit = 96
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    var body: some View {
        let metrics = Self.layoutMetrics(
            for: visibleCode,
            font: Self.codeFont,
            measureLineWidth: !wrapLines
        )
        let contentWidth = wrapLines
            ? ceil(UIScreen.main.bounds.width)
            : metrics.contentWidth
        let estimatedContentHeight = min(
            contentMaxHeight,
            max(48, CGFloat(metrics.lineCount) * 21 + 2)
        )
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

    private static func layoutMetrics(
        for code: String,
        font: UIFont,
        measureLineWidth: Bool
    ) -> SourceCodeLayoutMetrics {
        let key = "\(font.pointSize)|\(measureLineWidth ? 1 : 0)|\(code.utf8.count)|\(code.hashValue)" as NSString
        if let cached = layoutMetricsCache.object(forKey: key) {
            return cached
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        var lineCount = 0
        var maxLineWidth: CGFloat = 1
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        code.enumerateLines { line, _ in
            lineCount += 1
            guard measureLineWidth else { return }
            maxLineWidth = max(
                maxLineWidth,
                (line as NSString).size(withAttributes: attributes).width
            )
        }
        if code.last == "\n" {
            lineCount += 1
        }

        let metrics = SourceCodeLayoutMetrics(
            lineCount: max(1, lineCount),
            contentWidth: ceil(max(UIScreen.main.bounds.width, maxLineWidth + 96))
        )
        layoutMetricsCache.setObject(metrics, forKey: key, cost: min(code.utf8.count, 1_048_576))

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        if elapsedMs >= 12 {
            let duration = String(format: "%.1f", elapsedMs)
            DiagnosticLogManager.shared.warning(
                "SourceCode layout \(duration)ms chars=\(code.utf8.count) lines=\(metrics.lineCount) measuredWidth=\(measureLineWidth)",
                category: "Performance"
            )
        }
        return metrics
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
        textView.contentInsetAdjustmentBehavior = .never
        textView.contentInset = .zero
        textView.scrollIndicatorInsets = .zero
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
            width: preferredWidth
                + uiView.textContainerInset.left
                + uiView.textContainerInset.right,
            height: max(uiView.contentSize.height, 1)
        )
    }

    private static func configureScrollInsets(_ uiView: UITextView, wrapLines: Bool) {
        if uiView.contentInset != .zero {
            uiView.contentInset = .zero
        }
        if uiView.scrollIndicatorInsets != .zero {
            uiView.scrollIndicatorInsets = .zero
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

    private enum SourceSelectionAction: String, CaseIterable {
        case ask
        case lookUp
        case searchWeb
        case translate
        case share

        var title: String {
            switch self {
            case .ask: "询问 Iexa"
            case .lookUp: "查询"
            case .searchWeb: "搜索网页"
            case .translate: "翻译"
            case .share: "分享"
            }
        }

        var selector: Selector {
            switch self {
            case .ask: #selector(NoCaretSourceTextView.askSelectedSourceText)
            case .lookUp: #selector(NoCaretSourceTextView.lookUpSelectedSourceText)
            case .searchWeb: #selector(NoCaretSourceTextView.searchSelectedSourceTextOnWeb)
            case .translate: #selector(NoCaretSourceTextView.translateSelectedSourceText)
            case .share: #selector(NoCaretSourceTextView.shareSelectedSourceText)
            }
        }
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            installSourceSelectionMenuItems()
        }
        return didBecome
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
        let requiredContentWidth = minimumContentWidth
            + textContainerInset.left
            + textContainerInset.right
        if contentSize.width < requiredContentWidth {
            contentSize.width = requiredContentWidth
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard selectionEnabled else { return false }
        if Self.isSourceSelectionAction(action) {
            return selectedSourceText() != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    private func installSourceSelectionMenuItems() {
        let existing = UIMenuController.shared.menuItems ?? []
        var seen = Set(existing.map { NSStringFromSelector($0.action) })
        let customItems = SourceSelectionAction.allCases.compactMap { action -> UIMenuItem? in
            let selectorName = NSStringFromSelector(action.selector)
            guard !seen.contains(selectorName) else { return nil }
            seen.insert(selectorName)
            return UIMenuItem(title: action.title, action: action.selector)
        }
        guard !customItems.isEmpty else { return }
        UIMenuController.shared.menuItems = [customItems[0]] + existing + Array(customItems.dropFirst())
    }

    private static func isSourceSelectionAction(_ selector: Selector) -> Bool {
        SourceSelectionAction.allCases.contains { $0.selector == selector }
    }

    private func selectedSourceText() -> String? {
        guard let range = selectedTextRange, !range.isEmpty,
              let text = text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private func performSourceSelectionAction(_ action: TextSelectionAction) {
        guard let text = selectedSourceText() else { return }
        selectedTextRange = nil
        UIMenuController.shared.setMenuVisible(false, animated: true)
        TextSelectionActionBridge.post(action, text: text)
    }

    @objc private func askSelectedSourceText(_ sender: Any?) {
        performSourceSelectionAction(.ask)
    }

    @objc private func searchSelectedSourceTextOnWeb(_ sender: Any?) {
        performSourceSelectionAction(.searchWeb)
    }

    @objc private func shareSelectedSourceText(_ sender: Any?) {
        performSourceSelectionAction(.share)
    }

    @objc private func translateSelectedSourceText(_ sender: Any?) {
        performSourceSelectionAction(.translate)
    }

    @objc private func lookUpSelectedSourceText(_ sender: Any?) {
        guard let text = selectedSourceText() else { return }
        selectedTextRange = nil
        UIMenuController.shared.setMenuVisible(false, animated: true)
        if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text),
           let presenter = iexa_parentViewController {
            DispatchQueue.main.async {
                let lookup = UIReferenceLibraryViewController(term: text)
                presenter.present(lookup, animated: true)
            }
        } else {
            TextSelectionActionBridge.post(.lookUp, text: text)
        }
    }
}

private extension CGFloat {
    func nonZero(or fallback: CGFloat) -> CGFloat {
        self > 1 ? self : fallback
    }
}

private extension UIResponder {
    var iexa_parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

private enum SourceCodeHighlighter {
    private final class HighlightCacheEntry: NSObject {
        let value: NSAttributedString

        init(value: NSAttributedString) {
            self.value = value
        }
    }

    private static let highlightCache: NSCache<NSString, HighlightCacheEntry> = {
        let cache = NSCache<NSString, HighlightCacheEntry>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    static func highlighted(
        _ code: String,
        language: String,
        font: UIFont,
        baseColor: UIColor,
        isDarkMode: Bool,
        lineSpacing: CGFloat,
        lineBreakMode: NSLineBreakMode
    ) -> NSAttributedString {
        let cacheKey = [
            language,
            String(format: "%.2f", font.pointSize),
            String(isDarkMode ? 1 : 0),
            String(format: "%.2f", lineSpacing),
            String(lineBreakMode.rawValue),
            String(baseColor.hashValue),
            String(code.utf8.count),
            String(code.hashValue)
        ].joined(separator: "|") as NSString
        if let cached = highlightCache.object(forKey: cacheKey) {
            return cached.value
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            if elapsedMs >= 12 {
                let duration = String(format: "%.1f", elapsedMs)
                DiagnosticLogManager.shared.warning(
                    "SourceCode highlight \(duration)ms chars=\(code.utf8.count) language=\(language)",
                    category: "Performance"
                )
            }
        }

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
        guard fullRange.length > 0 else {
            let frozen = NSAttributedString(attributedString: output)
            highlightCache.setObject(
                HighlightCacheEntry(value: frozen),
                forKey: cacheKey,
                cost: min(code.utf8.count, 262_144)
            )
            return frozen
        }

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
        let frozen = NSAttributedString(attributedString: output)
        highlightCache.setObject(
            HighlightCacheEntry(value: frozen),
            forKey: cacheKey,
            cost: min(code.utf8.count * 2, 1_048_576)
        )
        return frozen
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
        if let loadedUIImage {
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

    nonisolated private static func dataURIImage(from dataURI: String) -> UIImage? {
        guard dataURI.hasPrefix("data:image/"),
              dataURI.count <= 7_000_000,
              let comma = dataURI.firstIndex(of: ",") else { return nil }
        let encoded = String(dataURI[dataURI.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return nil }
        guard data.count <= 5_000_000 else { return nil }
        return UIImage(data: data)
    }

    @MainActor
    private func loadRemoteImageIfNeeded() async {
        isLoading = true
        didFailToLoad = false

        if imageURL.scheme == "data" {
            let value = imageURL.absoluteString
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.dataURIImage(from: value)
            }.value
            loadedUIImage = decoded
            isLoading = false
            didFailToLoad = decoded == nil
            return
        }

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
        let image = loadedUIImage ?? Self.dataURIImage(from: imageURL.absoluteString)
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
                    wrapLines: false
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
