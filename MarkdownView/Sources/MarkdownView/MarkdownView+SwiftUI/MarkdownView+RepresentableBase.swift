//
//  MarkdownView+RepresentableBase.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2026/2/1.
//

import MarkdownParser
import SwiftUI

protocol MarkdownViewRepresentableBase {
    var contentSource: MarkdownView.ContentSource { get }
    var theme: MarkdownTheme { get }
    /// When true, this view is inside an actively-streaming message.
    /// Used to select the throttled update path and stabilize height.
    var codeBlockAutoScroll: Bool { get }
    /// When true, the built-in code block header bar is hidden for all code blocks.
    var codeBlockBarHidden: Bool { get }
    var width: CGFloat { get }
    var heightBinding: Binding<CGFloat> { get }
}

extension MarkdownViewRepresentableBase {
    // Default implementation so AppKit conformers don't need to declare this.
    var codeBlockBarHidden: Bool { false }

    func createMarkdownTextView() -> MarkdownTextView {
        let view = MarkdownTextView()
        view.theme = theme
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        #if canImport(UIKit)
        view.linkHandler = { payload, _, _ in
            let url: URL?
            switch payload {
            case .url(let u): url = u
            case .string(let s): url = URL(string: s)
            }
            if let url {
                NotificationCenter.default.post(
                    name: .markdownLinkTapped,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }
        view.codePreviewHandler = { language, attributedString in
            let code = attributedString.string
            NotificationCenter.default.post(
                name: .markdownCodePreview,
                object: nil,
                userInfo: ["code": code, "language": language ?? ""]
            )
        }
        #endif
        return view
    }

    func updateMarkdownTextView(_ view: MarkdownTextView, coordinator: MarkdownViewCoordinator) {
        let needsUpdate: Bool
        let content: MarkdownTextView.PreprocessedContent

        let isStreaming = codeBlockAutoScroll

        switch contentSource {
        case let .text(text):
            needsUpdate = coordinator.lastText != text
                || coordinator.lastTheme != theme
            if needsUpdate {
                if isStreaming {
                    // Incremental path: only re-parse the short live tail each tick.
                    // The parser caches the stable prefix (text before the last \n\n)
                    // so cost per tick is O(tail length) rather than O(full text).
                    // Reset detection (hasPrefix guard inside the parser) handles
                    // regeneration and stop/restart without any index arithmetic.
                    content = coordinator.incrementalParser.parse(text, theme: theme)
                } else {
                    // Full parse for non-streaming (final render, previews, etc.)
                    coordinator.incrementalParser.reset()
                    let parser = MarkdownParser()
                    let result = parser.parse(text)
                    content = MarkdownTextView.PreprocessedContent(parserResult: result, theme: theme)
                }
                coordinator.lastText = text
                coordinator.lastPreprocessedContent = nil
            } else {
                content = view.document
            }

        case let .preprocessed(preprocessedContent):
            needsUpdate = coordinator.lastPreprocessedContent !== preprocessedContent
                || coordinator.lastTheme != theme
            content = preprocessedContent
            if needsUpdate {
                coordinator.lastText = ""
                coordinator.lastPreprocessedContent = preprocessedContent
            }
        }

        if needsUpdate {
            view.theme = theme
            view.setMarkdownManually(content)
            view.invalidateIntrinsicContentSize()
            coordinator.lastTheme = theme
            // Content just changed — reset the height throttle timestamp so the
            // very first measurement after a content change is never skipped.
            coordinator.lastHeightMeasureTime = 0
        }
        #if canImport(UIKit)
        view.setCodeBlockAutoScroll(isStreaming)
        view.setCodeBlockBarHidden(codeBlockBarHidden)
        #endif
        updateMeasuredHeight(for: view, coordinator: coordinator, isStreaming: isStreaming)
    }

    func updateMeasuredHeight(
        for view: MarkdownTextView,
        coordinator: MarkdownViewCoordinator,
        isStreaming: Bool = false
    ) {
        guard width.isFinite, width > 0 else { return }

        // During streaming, calling `boundingSize(for:)` on every token causes
        // a full O(n) CoreText layout pass on the entire growing attributed string.
        // Throttle to at most once per `heightThrottleInterval` seconds while
        // streaming; always measure immediately when streaming ends or content changes.
        if isStreaming {
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - coordinator.lastHeightMeasureTime
            guard elapsed >= MarkdownViewCoordinator.heightThrottleInterval else { return }
            coordinator.lastHeightMeasureTime = now
        }

        let size = view.boundingSize(for: width)
        let height = ceil(size.height)
        let current = heightBinding.wrappedValue

        guard abs(height - current) > 0.5 else { return }
        // Wrap in a nil-animation transaction so SwiftUI never animates the
        // height change. Without this, advancing the paragraph-freeze boundary
        // causes a bounce: the frozen view grows (async height +) while the
        // live tail shrinks (async height -) and the two deferred updates
        // play as an animated spring rather than an instant no-op.
        DispatchQueue.main.async {
            var tx = Transaction(animation: nil)
            tx.disablesAnimations = true
            withTransaction(tx) {
                self.heightBinding.wrappedValue = height
            }
        }
    }
}
