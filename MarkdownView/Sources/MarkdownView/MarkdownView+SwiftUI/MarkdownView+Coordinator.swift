//
//  MarkdownView+Coordinator.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2026/2/1.
//

import Foundation

final class MarkdownViewCoordinator {
    var lastText: String = ""
    var lastPreprocessedContent: MarkdownTextView.PreprocessedContent?
    var lastTheme: MarkdownTheme = .default

    /// Incremental parser used only during streaming (`codeBlockAutoScroll == true`).
    /// Maintains a cached stable prefix so only the short live tail is re-parsed
    /// each drain tick rather than the full accumulated text.
    let incrementalParser = IncrementalStreamingParser()

    // Height-measurement throttle: during streaming we skip the expensive
    // `boundingSize(for:)` call if we measured less than `heightThrottleInterval`
    // seconds ago. This avoids a full O(n) CoreText layout pass on every token.
    // Set to ~1 frame (16ms) so height updates per-frame — smooth streaming
    // without clipping text — while still protecting against pathological
    // back-to-back SwiftUI layout passes within the same frame.
    var lastHeightMeasureTime: CFAbsoluteTime = 0
    /// Minimum interval between height measurements when streaming (seconds).
    /// ~16ms ≈ one 60 Hz frame — effectively per-frame updates, no visible chunking.
    static let heightThrottleInterval: CFAbsoluteTime = 0.016
}
