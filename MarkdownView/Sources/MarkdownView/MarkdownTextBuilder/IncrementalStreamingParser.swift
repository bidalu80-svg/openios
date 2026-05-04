//
//  IncrementalStreamingParser.swift
//  MarkdownView
//

import Foundation
import MarkdownParser

/// Incremental markdown parser for streaming content.
///
/// ## Problem
/// During streaming, `displayContent` grows by 1–4 characters per drain tick
/// (up to 60 times/sec). Without caching, this triggers a full
/// `MarkdownParser().parse(fullText)` call on every tick — O(n) work each
/// frame, O(n²) total. For a 3,000-word response that means tens of millions
/// of parse operations.
///
/// ## Solution
/// Maintain a "stable prefix" — everything before the last completed block
/// boundary (double-newline). The stable prefix is parsed once and cached.
/// On each subsequent tick, only the short "live tail" (from the last block
/// boundary onward) needs to be re-parsed and merged with the cached result.
///
/// ## Safety
/// No `String.Index` math is stored between calls. The only persistent state
/// is `cachedText: String` and `cachedResult`. All boundary detection uses
/// safe string searching (`range(of:options:range:)`) with no index arithmetic
/// that could go out of bounds if the text is reset or shortened.
///
/// When text is reset (regeneration, new message) — detected by
/// `!newText.hasPrefix(cachedText)` — the cache is cleared and a normal full
/// parse runs for that tick. The next tick will already benefit from caching.
final class IncrementalStreamingParser {

    // MARK: - Cached Stable Prefix

    /// The stable prefix text that has been cached (everything before the last
    /// completed block boundary). Plain `String` — no stored indices.
    private var cachedText: String = ""

    /// Pre-parsed blocks for `cachedText`.
    private var cachedBlocks: [MarkdownBlockNode] = []

    /// Pre-rendered math map for `cachedText`.
    private var cachedRendered: RenderedTextContent.Map = [:]

    /// The theme used when building `cachedBlocks`/`cachedRendered`.
    private var cachedTheme: MarkdownTheme = .default

    // MARK: - Tuning

    /// Minimum number of characters that must remain in the "live tail" after
    /// the stable boundary. A larger value means we cache more aggressively
    /// (fewer tail re-parses) at the cost of slightly stale block structure
    /// for the last few lines. 30 chars is roughly 1–2 sentences.
    private static let minTailLength: Int = 30

    // MARK: - Public API

    /// Clears all cached state. Call this when starting a new streaming session
    /// so stale stable-prefix data from the previous message doesn't leak.
    func reset() {
        cachedText = ""
        cachedBlocks = []
        cachedRendered = [:]
        // Note: keep cachedTheme — it will be validated on next parse() call.
    }

    /// Returns a `PreprocessedContent` for `newText`, reusing as much cached
    /// state as possible.
    ///
    /// - Parameters:
    ///   - newText: The full `displayContent` string for this tick.
    ///   - theme:   The current `MarkdownTheme`.
    func parse(
        _ newText: String,
        theme: MarkdownTheme
    ) -> MarkdownTextView.PreprocessedContent {

        // ── 1. Theme change → full reset ──────────────────────────────────
        if theme != cachedTheme {
            reset()
            cachedTheme = theme
        }

        // ── 2. Text reset / shrinkage → cache is invalid ──────────────────
        // `hasPrefix` is safe: returns false (never crashes) when lengths differ
        // or content changed. This covers regeneration, stop-and-restart, etc.
        if !newText.hasPrefix(cachedText) {
            reset()
            cachedTheme = theme
        }

        // ── 3. Find stable boundary in newText ───────────────────────────
        // We look for the last "\n\n" that leaves at least `minTailLength`
        // characters after it. Everything up to that boundary is "stable"
        // (won't change in future ticks unless the model backtracks, which
        // is caught by step 2 above). Everything from the boundary onward is
        // the "live tail" that we re-parse each tick.
        let stableBoundaryOffset = findStableBoundaryOffset(in: newText)

        // ── 4. Build tail text ────────────────────────────────────────────
        let tailText: String
        if stableBoundaryOffset == 0 {
            // No stable boundary found → entire text is the live tail
            tailText = newText
        } else {
            let boundaryIdx = newText.index(newText.startIndex, offsetBy: stableBoundaryOffset)
            tailText = String(newText[boundaryIdx...])
        }

        // ── 5. Parse the live tail (always small) ─────────────────────────
        let parser = MarkdownParser()
        let tailResult = parser.parse(tailText)
        let tailRendered: RenderedTextContent.Map = tailResult.render(theme: theme)

        // ── 6. Update stable cache if the boundary advanced ───────────────
        // Only re-parse and cache the new stable portion when the boundary
        // has moved forward past what we already have cached.
        if stableBoundaryOffset > cachedText.count {
            let newStableEndIdx = newText.index(newText.startIndex, offsetBy: stableBoundaryOffset)
            let newStableText = String(newText[..<newStableEndIdx])
            let stableResult = parser.parse(newStableText)
            cachedBlocks = stableResult.document
            cachedRendered = stableResult.render(theme: theme)
            cachedText = newStableText
        }

        // ── 7. Merge stable + tail ────────────────────────────────────────
        let allBlocks = cachedBlocks + tailResult.document
        let allRendered = cachedRendered.merging(tailRendered) { _, new in new }

        return MarkdownTextView.PreprocessedContent(
            blocks: allBlocks,
            rendered: allRendered,
            highlightMaps: [:]
        )
    }

    // MARK: - Private: Boundary Detection

    /// Returns the character offset (from `startIndex`) of the start of the
    /// live tail — i.e., the position right after the last `\n\n` that leaves
    /// at least `minTailLength` characters remaining.
    ///
    /// Only `\n\n` occurrences that fall **outside** a fenced code block are
    /// considered valid split points. Splitting inside a code fence would cause
    /// the cached prefix to contain an unclosed ``` block and the live tail to
    /// start mid-block, producing a "double code block" visual artifact during
    /// streaming.
    ///
    /// Returns `0` if no qualifying boundary exists (entire text is the tail).
    private func findStableBoundaryOffset(in text: String) -> Int {
        let minTail = Self.minTailLength
        let totalCount = text.count

        // Need at least (minTail + 2) characters for any boundary to exist
        guard totalCount > minTail + 2 else { return 0 }

        // ── Build a set of character offsets that are inside a code fence ──
        // We scan for ``` markers line-by-line (O(n), done once).
        // A line starting with ``` toggles the "inside fence" state.
        var insideFence = false
        // Stores (start, end) byte offsets of fenced regions so we can test
        // candidate \n\n positions cheaply.  We use Int offsets (not String.Index)
        // to avoid any index arithmetic pitfalls.
        var fencedRanges: [(Int, Int)] = []
        var fenceStart = 0
        var charOffset = 0

        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            // Find end of current line
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let lineOffsetStart = charOffset
            let lineLen = text.distance(from: lineStart, to: lineEnd)

            // Check if this line starts with ```
            let linePrefix = text[lineStart..<lineEnd]
            if linePrefix.hasPrefix("```") {
                if insideFence {
                    // Closing fence — record the fenced region up to and
                    // including this closing ``` line.
                    let fenceEnd = lineOffsetStart + lineLen
                    fencedRanges.append((fenceStart, fenceEnd))
                    insideFence = false
                } else {
                    // Opening fence
                    fenceStart = lineOffsetStart
                    insideFence = true
                }
            }

            charOffset += lineLen + 1  // +1 for the \n
            if lineEnd == text.endIndex { break }
            lineStart = text.index(after: lineEnd)
        }

        // If we are currently inside an open (unclosed) fence, treat
        // everything from fenceStart to end-of-text as fenced.
        if insideFence {
            fencedRanges.append((fenceStart, totalCount))
        }

        /// Returns true if `offset` (character index from startIndex) falls
        /// inside any fenced region.
        func isInsideFence(_ offset: Int) -> Bool {
            fencedRanges.contains { offset >= $0.0 && offset <= $0.1 }
        }

        // ── Walk \n\n positions backwards, skipping those inside a fence ──
        let searchEndOffset = totalCount - minTail
        guard searchEndOffset > 0 else { return 0 }
        let searchEndIdx = text.index(text.startIndex, offsetBy: searchEndOffset)
        let searchRange = text.startIndex ..< searchEndIdx

        // Collect all \n\n positions in the search range, then iterate
        // backwards to find the last one that is outside a code fence.
        var candidateOffset: Int? = nil
        var searchCursor = searchRange.lowerBound

        while let found = text.range(of: "\n\n", range: searchCursor..<searchRange.upperBound) {
            let foundOffset = text.distance(from: text.startIndex, to: found.upperBound)
            if !isInsideFence(foundOffset) {
                candidateOffset = foundOffset  // keep updating — last valid one wins
            }
            // Advance past this match
            guard found.upperBound < text.endIndex else { break }
            searchCursor = found.upperBound
        }

        return candidateOffset ?? 0
    }
}
