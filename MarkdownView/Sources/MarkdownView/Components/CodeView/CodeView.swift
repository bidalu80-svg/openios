//
//  Created by ktiays on 2025/1/22.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext

#if canImport(UIKit)
    import UIKit

    final class CodeView: UIView {
        // MARK: - CONTENT

        var theme: MarkdownTheme = .default {
            didSet {
                languageLabel.font = theme.fonts.code
                textView.selectionBackgroundColor = theme.colors.selectionBackground
                updateLineNumberView()
            }
        }

        var language: String = "" {
            didSet {
                languageLabel.text = language.isEmpty ? "</>" : language
            }
        }

        var highlightMap: CodeHighlighter.HighlightMap = .init() {
            didSet {
                // Re-render the visible window at the current scroll position.
                applyWindowedText(at: scrollView.contentOffset.y)
            }
        }

        // MARK: - Bar Hidden

        /// When true, the built-in header bar (language label + copy/preview buttons)
        /// is hidden so that a container view (e.g. PythonCodeBlockView) can supply
        /// its own header without producing a "double header" stacked appearance.
        /// All other features (highlighting, line numbers, scrolling) are preserved.
        var barHidden: Bool = false {
            didSet {
                guard barHidden != oldValue else { return }
                barView.isHidden = barHidden
                setNeedsLayout()
                invalidateIntrinsicContentSize()
            }
        }

        // MARK: - Streaming / Auto-Scroll State

        /// True while the parent MarkdownView is actively streaming content.
        /// Setting this to `true` enables auto-scroll (unless the user has scrolled
        /// away). Setting it to `false` disables auto-scroll and hides the FAB.
        var isStreaming: Bool = false {
            didSet {
                guard isStreaming != oldValue else { return }
                if isStreaming {
                    // Starting a new stream — enable auto-scroll and reset the
                    // user-override flag so the block starts scrolling from top.
                    userScrolledAway = false
                    autoScrollEnabled = true
                    // Trigger an immediate scroll to bottom so we don't stay stuck.
                    needsScrollToBottomOnLayout = true
                    setNeedsLayout()
                } else {
                    // Stream ended — disable auto-scroll.
                    autoScrollEnabled = false
                    userScrolledAway = false
                    // Trigger syntax highlighting now that the full code is available.
                    // During streaming, triggerAsyncHighlight() is suppressed to prevent
                    // the epileptic flicker caused by partial highlights firing mid-stream.
                    triggerAsyncHighlight()
                }
            }
        }

        /// True once the user has dragged the scroll view upward, breaking out of
        /// auto-scroll. Reset to false when streaming starts, or when the user
        /// scrolls back to the bottom (or taps the FAB).
        private var userScrolledAway: Bool = false

        /// When true, the code block scrolls to the bottom whenever new content arrives.
        /// Managed internally; controlled via `isStreaming` and user scroll gestures.
        private(set) var autoScrollEnabled: Bool = false {
            didSet { updateScrollFABVisibility() }
        }

        // MARK: - FAB

        private lazy var scrollFAB: UIButton = {
            let btn = UIButton(type: .system)
            let img = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
            btn.setImage(img, for: .normal)
            btn.tintColor = .white
            btn.backgroundColor = UIColor.systemGray.withAlphaComponent(0.7)
            btn.layer.cornerRadius = 13
            btn.layer.cornerCurve = .continuous
            btn.clipsToBounds = true
            btn.addTarget(self, action: #selector(scrollFABTapped), for: .touchUpInside)
            btn.alpha = 0
            return btn
        }()

        @objc private func scrollFABTapped() {
            userScrolledAway = false
            autoScrollEnabled = true
            scrollToBottom(animated: true)
        }

        private func scrollToBottom(animated: Bool) {
            let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            guard maxOffset > 0 else { return }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: maxOffset), animated: animated)
        }

        private func updateScrollFABVisibility() {
            let shouldShow = !autoScrollEnabled && scrollView.contentSize.height > scrollView.bounds.height
            UIView.animate(withDuration: 0.2) {
                self.scrollFAB.alpha = shouldShow ? 1 : 0
            }
        }

        // MARK: - Pending Scroll Cancellation

        /// Tracks the pending async scrollToBottom work item so we can cancel it
        /// if the user starts dragging before it fires.
        private var pendingScrollWorkItem: DispatchWorkItem?

        /// Set by the streaming append path; consumed once in layoutSubviews so we
        /// only perform one scrollToBottom per layout pass instead of once per token.
        private var needsScrollToBottomOnLayout: Bool = false

        // MARK: - Virtual Line Windowing State

        /// Pre-split lines for O(1) window computation.
        private var contentLines: [String] = []
        /// Character offset of each line's start within `content`. Pre-computed once.
        private var lineCharOffsets: [Int] = []
        /// The character offset of the currently-rendered window start.
        private var currentWindowCharOffset: Int = 0
        /// The scroll offset at which we last updated the window (hysteresis tracking).
        private var lastWindowUpdateScrollY: CGFloat = -CGViewConfiguration.windowingHysteresis - 1

        // MARK: - Content

        var content: String = "" {
            didSet {
                guard oldValue != content else { return }

                // Detect streaming append: new content is old content + more characters.
                // This is the common case during streaming — take a fast incremental path.
                let isStreamingAppend = !oldValue.isEmpty && content.hasPrefix(oldValue)

                if isStreamingAppend {
                    // FAST PATH: only update changed/new lines, preserve window state.
                    appendToLineIndex(oldContent: oldValue)

                    // Render at the *current* scroll position so the visible window
                    // stays in place (typically bottom if auto-scrolling).
                    let currentScrollY = scrollView.contentOffset.y
                    applyWindowedText(at: currentScrollY)
                    // Nudge layout so contentSize reflects the extra lines.
                    setNeedsLayout()

                    lineNumberView.updateForContent(content)
                    updateLineNumberView()

                    // During streaming we suppress highlighting to avoid flicker.
                    // Always cancel any in-flight highlight task first (regardless of
                    // whether highlightMap is empty) to prevent a stale task firing.
                    highlightTask?.cancel()
                    // Clear any stale highlight map so the code renders cleanly
                    // (without leftover colouring from a previous partial highlight).
                    // The triggerAsyncHighlight() call in isStreaming didSet will
                    // fire once streaming is complete and produce the final colouring.
                    if !highlightMap.isEmpty {
                        // Setting highlightMap triggers one applyWindowedText via didSet —
                        // that's acceptable (replaces stale colours with plain text).
                        highlightMap = .init()
                    }

                    // Coalesce scroll-to-bottom to once per layout pass.
                    // This prevents per-token DispatchWorkItems piling up and
                    // blocking gesture recognisers from firing during streaming.
                    if autoScrollEnabled && !userScrolledAway {
                        needsScrollToBottomOnLayout = true
                        setNeedsLayout()
                    }
                } else {
                    // FULL REBUILD PATH: content was replaced (not just appended).
                    // Re-compute everything from scratch.
                    rebuildLineIndex()

                    currentWindowCharOffset = 0
                    lastWindowUpdateScrollY = -CodeViewConfiguration.windowingHysteresis - 1

                    applyWindowedText(at: 0)

                    lineNumberView.updateForContent(content)
                    updateLineNumberView()
                    triggerAsyncHighlight()

                    if autoScrollEnabled && !userScrolledAway {
                        DispatchQueue.main.async { [weak self] in
                            self?.scrollToBottom(animated: false)
                        }
                    }
                }
            }
        }

        // MARK: - Line Index Helpers

        private func rebuildLineIndex() {
            let lines = content.components(separatedBy: .newlines)
            contentLines = lines
            var offsets: [Int] = []
            offsets.reserveCapacity(lines.count)
            var charOffset = 0
            for line in lines {
                offsets.append(charOffset)
                // +1 for the newline character
                charOffset += line.utf16.count + 1
            }
            lineCharOffsets = offsets
        }

        /// Incremental line index update for streaming appends.
        /// Only touches the last (incomplete) line of `oldContent` and any new
        /// lines that follow it — O(delta) instead of O(n).
        private func appendToLineIndex(oldContent: String) {
            guard !contentLines.isEmpty else {
                // Safety fallback: no existing index — do a full rebuild.
                rebuildLineIndex()
                return
            }

            // The last line in the old index may have grown (partial line being
            // extended) or new newlines may have been added.
            let lastOldLineIdx = contentLines.count - 1
            let lastOldLineCharOffset = lineCharOffsets[lastOldLineIdx]

            // Extract the suffix of content starting at the last old line's offset.
            let utf16 = content.utf16
            let suffixStart = utf16.index(utf16.startIndex, offsetBy: min(lastOldLineCharOffset, utf16.count))
            let suffix = String(utf16[suffixStart...]) ?? String(content[content.index(content.startIndex, offsetBy: min(lastOldLineCharOffset, content.count))...])

            // Split the suffix into lines.
            let suffixLines = suffix.components(separatedBy: .newlines)

            // Replace the last old line and append any genuinely new ones.
            contentLines.removeLast()
            lineCharOffsets.removeLast()

            var charOffset = lastOldLineCharOffset
            for line in suffixLines {
                contentLines.append(line)
                lineCharOffsets.append(charOffset)
                charOffset += line.utf16.count + 1
            }
        }

        /// Returns a slice of `content` covering `lineStart ..< lineEnd` (line indices),
        /// plus the character offset of that slice's first character.
        private func contentSlice(lineStart: Int, lineEnd: Int) -> (slice: String, charOffset: Int) {
            guard !contentLines.isEmpty else { return (content, 0) }
            let clampedStart = max(0, min(lineStart, contentLines.count - 1))
            let clampedEnd = max(clampedStart + 1, min(lineEnd, contentLines.count))
            let charStart = lineCharOffsets[clampedStart]
            // charEnd: start of first line AFTER our slice, or end of content
            let charEnd: Int
            if clampedEnd < contentLines.count {
                charEnd = lineCharOffsets[clampedEnd]
            } else {
                charEnd = content.utf16.count
            }
            let startIdx = content.utf16.index(content.utf16.startIndex, offsetBy: min(charStart, content.utf16.count))
            let endIdx = content.utf16.index(content.utf16.startIndex, offsetBy: min(charEnd, content.utf16.count))
            let slice = String(content.utf16[startIdx ..< endIdx]) ?? String(content[content.index(content.startIndex, offsetBy: min(charStart, content.count)) ..< content.index(content.startIndex, offsetBy: min(charEnd, content.count))])
            return (slice, charStart)
        }

        /// Apply windowed attributed text to `textView` for the given scroll offset.
        private func applyWindowedText(at scrollOffsetY: CGFloat) {
            guard !contentLines.isEmpty else {
                textView.attributedText = highlightMap.apply(to: content, with: theme)
                return
            }

            let lineH = CodeViewConfiguration.lineHeight(for: theme)
            guard lineH > 0 else {
                textView.attributedText = highlightMap.apply(to: content, with: theme)
                return
            }

            // Determine which lines are visible + overscan.
            let viewportHeight = scrollView.bounds.height > 0 ? scrollView.bounds.height : CodeViewConfiguration.maxCodeViewHeight
            let overscan = CodeViewConfiguration.overscanLines
            let visibleTopLine = max(0, Int(scrollOffsetY / lineH) - overscan)
            let linesVisible = Int(ceil(viewportHeight / lineH)) + overscan * 2
            let visibleBottomLine = min(contentLines.count, visibleTopLine + linesVisible)

            let (slice, charOffset) = contentSlice(lineStart: visibleTopLine, lineEnd: visibleBottomLine)
            currentWindowCharOffset = charOffset

            // Apply highlight map to the slice only.
            let attrText: NSAttributedString
            if highlightMap.isEmpty {
                attrText = CodeHighlighter.HighlightMap().apply(toSlice: slice, charOffset: charOffset, with: theme)
            } else {
                attrText = highlightMap.apply(toSlice: slice, charOffset: charOffset, with: theme)
            }
            textView.attributedText = attrText
        }

        /// Called from scrollViewDidScroll; only re-windows if scrolled past hysteresis threshold.
        private func updateWindowIfNeeded(scrollY: CGFloat) {
            let delta = abs(scrollY - lastWindowUpdateScrollY)
            guard delta >= CodeViewConfiguration.windowingHysteresis else { return }
            lastWindowUpdateScrollY = scrollY
            applyWindowedText(at: scrollY)
            // Reposition textView to align with the windowed content.
            repositionTextView()
        }

        /// Moves `textView.frame.origin.y` so the windowed slice is positioned
        /// at the correct vertical offset within the scrollView's content area.
        private func repositionTextView() {
            guard !contentLines.isEmpty else { return }
            let charOffset = currentWindowCharOffset
            // Count how many newlines are before charOffset to get the start line index.
            let lineH = CodeViewConfiguration.lineHeight(for: theme)
            // Find line index by searching lineCharOffsets
            let startLineIndex = lineCharOffsets.lastIndex(where: { $0 <= charOffset }) ?? 0
            let topY = CGFloat(startLineIndex) * lineH + CodeViewConfiguration.codePadding
            var frame = textView.frame
            frame.origin.y = topY
            textView.frame = frame
        }

        // MARK: CONTENT -

        /// Tracks the current async highlight task so we can cancel stale ones
        private var highlightTask: Task<Void, Never>?

        private func triggerAsyncHighlight() {
            // Never start a highlight task while streaming — prevents flicker.
            // The isStreaming didSet calls us again when the stream ends.
            guard !isStreaming else { return }
            highlightTask?.cancel()
            let capturedContent = content
            let capturedLanguage = language
            let capturedTheme = theme
            highlightTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }

                let map = await CodeHighlighter.current.highlightAsync(
                    content: capturedContent,
                    language: capturedLanguage,
                    theme: capturedTheme
                )
                guard !Task.isCancelled, let self,
                      self.content == capturedContent else { return }
                await MainActor.run {
                    // Setting highlightMap triggers a re-render of the current window via didSet.
                    self.highlightMap = map
                }
            }
        }

        var previewAction: ((String?, NSAttributedString) -> Void)? {
            didSet {
                setNeedsLayout()
            }
        }

        private let callerIdentifier = UUID()
        private var currentTaskIdentifier: UUID?

        lazy var barView: UIView = .init()
        lazy var scrollView: UIScrollView = .init()
        lazy var languageLabel: UILabel = .init()
        lazy var textView: LTXLabel = .init()
        lazy var copyButton: UIButton = .init()
        lazy var previewButton: UIButton = .init()
        lazy var lineNumberView: LineNumberView = .init()

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureSubviews()
            updateLineNumberView()
            scrollView.delegate = self
            addSubview(scrollFAB)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        static func intrinsicHeight(for content: String, theme: MarkdownTheme = .default) -> CGFloat {
            CodeViewConfiguration.intrinsicHeight(for: content, theme: theme)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            performLayout()
            updateLineNumberView()
            // Keep FAB pinned to bottom-right corner of the code block.
            let fabSize: CGFloat = 26
            let margin: CGFloat = 8
            scrollFAB.frame = CGRect(
                x: bounds.width - fabSize - margin,
                y: bounds.height - fabSize - margin,
                width: fabSize,
                height: fabSize
            )
            bringSubviewToFront(scrollFAB)
            updateScrollFABVisibility()
            // Consume the deferred scroll-to-bottom flag set during streaming.
            // Doing it here (after contentSize is up-to-date) guarantees we scroll
            // to the real bottom, and only once per layout pass.
            if needsScrollToBottomOnLayout && autoScrollEnabled && !userScrolledAway {
                needsScrollToBottomOnLayout = false
                scrollToBottom(animated: false)
            } else {
                needsScrollToBottomOnLayout = false
            }
        }

        override var intrinsicContentSize: CGSize {
            let labelSize = languageLabel.intrinsicContentSize
            let computedBarHeight = labelSize.height + CodeViewConfiguration.barPadding * 2
            let barHeight: CGFloat = barHidden ? 0 : computedBarHeight
            // Use full content height estimate for layout (NOT textView frame height,
            // which is now only the windowed slice).
            let fullContentHeight = fullCodeContentHeight()
            let lineNumberWidth = lineNumberView.intrinsicContentSize.width

            let naturalHeight = barHeight + fullContentHeight + CodeViewConfiguration.codePadding * 2
            // Cap total height to prevent massive CALayer backing stores.
            let cappedHeight = min(naturalHeight, CodeViewConfiguration.maxCodeViewHeight)
            return CGSize(
                width: max(
                    labelSize.width + CodeViewConfiguration.barPadding * 2,
                    lineNumberWidth + textView.intrinsicContentSize.width + CodeViewConfiguration.codePadding * 2
                ),
                height: cappedHeight
            )
        }

        /// Estimated height of all code content (used for scrollView.contentSize).
        /// Internal (not private) so the CodeView extension in CodeViewConfiguration.swift can call it.
        func fullCodeContentHeight() -> CGFloat {
            guard !contentLines.isEmpty else {
                return textView.intrinsicContentSize.height
            }
            return CGFloat(contentLines.count) * CodeViewConfiguration.lineHeight(for: theme)
        }

        @objc func handleCopy(_: UIButton) {
            UIPasteboard.general.string = content
            #if !os(visionOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }

        @objc func handlePreview(_: UIButton) {
            #if !os(visionOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            // Pass full content (not truncated) for fullscreen preview
            let fullAttr = highlightMap.apply(to: content, with: theme)
            previewAction?(language, fullAttr)
        }

        func updateLineNumberView() {
            let font = theme.fonts.code
            lineNumberView.textColor = theme.colors.body.withAlphaComponent(0.5)

            let lineCount = max(contentLines.isEmpty ? content.components(separatedBy: .newlines).count : contentLines.count, 1)
            let fullHeight = fullCodeContentHeight()

            lineNumberView.configure(
                lineCount: lineCount,
                contentHeight: fullHeight,
                font: font,
                textColor: .secondaryLabel
            )

            lineNumberView.padding = UIEdgeInsets(
                top: CodeViewConfiguration.codePadding,
                left: CodeViewConfiguration.lineNumberPadding,
                bottom: CodeViewConfiguration.codePadding,
                right: CodeViewConfiguration.lineNumberPadding
            )
        }
    }

    // Private shorthand so we can reference CodeViewConfiguration as CGViewConfiguration
    // within the windowing methods (avoids line-length issues).
    private typealias CGViewConfiguration = CodeViewConfiguration

    extension CodeView: LTXAttributeStringRepresentable {
        func attributedStringRepresentation() -> NSAttributedString {
            // Return the full highlighted content (not just the window) for copy/share.
            highlightMap.apply(to: content, with: theme)
        }
    }

    extension CodeView: UIScrollViewDelegate {
        func scrollViewWillBeginDragging(_: UIScrollView) {
            // Cancel any queued scroll-to-bottom before it can fire.
            pendingScrollWorkItem?.cancel()
            pendingScrollWorkItem = nil
            // Mark that the user is taking manual control.
            userScrolledAway = true
            autoScrollEnabled = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateScrollFABVisibility()
            // Keep the line number view vertically aligned with the scrolled content.
            let offsetY = scrollView.contentOffset.y
            lineNumberView.contentOffsetY = offsetY
            // Update the virtual text window (respects hysteresis).
            updateWindowIfNeeded(scrollY: offsetY)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                checkIfScrolledToBottomAndResumeAutoScroll(scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            checkIfScrolledToBottomAndResumeAutoScroll(scrollView)
        }

        /// Re-enables auto-scroll if we are streaming and the user has scrolled back to
        /// (or near) the bottom of the code block.
        private func checkIfScrolledToBottomAndResumeAutoScroll(_ scrollView: UIScrollView) {
            guard isStreaming, userScrolledAway else { return }
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            guard maxOffset > 0 else { return }
            // Consider "at the bottom" within 20pt to account for rubber-banding.
            let isAtBottom = (scrollView.contentOffset.y >= maxOffset - 20)
            if isAtBottom {
                userScrolledAway = false
                autoScrollEnabled = true
                // Immediately continue auto-scrolling with the next new content.
                needsScrollToBottomOnLayout = true
                setNeedsLayout()
            }
        }
    }

#elseif canImport(AppKit)
    import AppKit

    final class CodeView: NSView {
        var theme: MarkdownTheme = .default {
            didSet {
                languageLabel.font = theme.fonts.code
                textView.selectionBackgroundColor = theme.colors.selectionBackground
                updateLineNumberView()
            }
        }

        var language: String = "" {
            didSet {
                languageLabel.stringValue = language.isEmpty ? "</>" : language
            }
        }

        var highlightMap: CodeHighlighter.HighlightMap = .init()

        var content: String = "" {
            didSet {
                guard oldValue != content else { return }
                textView.attributedText = highlightMap.apply(to: content, with: theme)
                lineNumberView.updateForContent(content)
                updateLineNumberView()
            }
        }

        var previewAction: ((String?, NSAttributedString) -> Void)? {
            didSet {
                needsLayout = true
            }
        }

        private let callerIdentifier = UUID()
        private var currentTaskIdentifier: UUID?

        lazy var barView: NSView = .init()
        lazy var scrollView: NSScrollView = {
            let sv = NSScrollView()
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.drawsBackground = false
            return sv
        }()

        lazy var languageLabel: NSTextField = {
            let label = NSTextField(labelWithString: "")
            label.isEditable = false
            label.isBordered = false
            label.backgroundColor = .clear
            return label
        }()

        lazy var textView: LTXLabel = .init()
        lazy var copyButton: NSButton = .init(title: "", target: nil, action: nil)
        lazy var previewButton: NSButton = .init(title: "", target: nil, action: nil)
        lazy var lineNumberView: LineNumberView = .init()

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureSubviews()
            updateLineNumberView()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool {
            true
        }

        static func intrinsicHeight(for content: String, theme: MarkdownTheme = .default) -> CGFloat {
            CodeViewConfiguration.intrinsicHeight(for: content, theme: theme)
        }

        override func layout() {
            super.layout()
            performLayout()
            updateLineNumberView()
        }

        override var intrinsicContentSize: CGSize {
            let labelSize = languageLabel.intrinsicContentSize
            let barHeight = labelSize.height + CodeViewConfiguration.barPadding * 2
            let textSize = textView.intrinsicContentSize
            let supposedHeight = Self.intrinsicHeight(for: content, theme: theme)

            let lineNumberWidth = lineNumberView.intrinsicContentSize.width

            return CGSize(
                width: max(
                    labelSize.width + CodeViewConfiguration.barPadding * 2,
                    lineNumberWidth + textSize.width + CodeViewConfiguration.codePadding * 2
                ),
                height: max(
                    barHeight + textSize.height + CodeViewConfiguration.codePadding * 2,
                    supposedHeight
                )
            )
        }

        @objc func handleCopy(_: Any?) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
        }

        @objc func handlePreview(_: Any?) {
            previewAction?(language, textView.attributedText)
        }

        func updateLineNumberView() {
            let font = theme.fonts.code
            lineNumberView.textColor = theme.colors.body.withAlphaComponent(0.5)

            let lineCount = max(content.components(separatedBy: .newlines).count, 1)
            let textViewContentHeight = textView.intrinsicContentSize.height

            lineNumberView.configure(
                lineCount: lineCount,
                contentHeight: textViewContentHeight,
                font: font,
                textColor: .secondaryLabelColor
            )

            lineNumberView.padding = NSEdgeInsets(
                top: CodeViewConfiguration.codePadding,
                left: CodeViewConfiguration.lineNumberPadding,
                bottom: CodeViewConfiguration.codePadding,
                right: CodeViewConfiguration.lineNumberPadding
            )
        }
    }

    extension CodeView: LTXAttributeStringRepresentable {
        func attributedStringRepresentation() -> NSAttributedString {
            textView.attributedText
        }
    }
#endif
