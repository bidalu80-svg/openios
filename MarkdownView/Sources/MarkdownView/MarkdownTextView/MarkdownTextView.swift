//
//  Created by ktiays on 2025/1/20.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Combine
import CoreText
import Litext
import MarkdownParser

#if canImport(UIKit)
    import UIKit

    public final class MarkdownTextView: UIView {
        public var linkHandler: ((LinkPayload, NSRange, CGPoint) -> Void)?
        public var codePreviewHandler: ((String?, NSAttributedString) -> Void)?

        public internal(set) var document: PreprocessedContent = .init()
        public let textView: LTXLabel = .init()
        public var theme: MarkdownTheme = .default {
            didSet {
                textView.selectionBackgroundColor = theme.colors.selectionBackground
                // Theme change invalidates all cached block renders since fonts/colors differ.
                cachedBlockSegments.removeAll()
                setMarkdown(document)
            }
        }

        public internal(set) weak var trackedScrollView: UIScrollView? // for selection updating

        // Block-level render cache: stores rendered output per MarkdownBlockNode so
        // unchanged blocks can be reused on the next streaming update without re-rendering.
        struct CachedBlockSegment {
            let node: MarkdownBlockNode
            let attributedString: NSAttributedString
            let subviews: [UIView]
        }
        var cachedBlockSegments: [CachedBlockSegment] = []

        // Persistent mutable attributed string for the entire document.
        // We mutate only the dirty tail in-place instead of rebuilding from scratch
        // on every streaming update — converts O(n_total) concat to O(n_dirty).
        var cachedAttributedString: NSMutableAttributedString = .init()

        var contextViews: [UIView] = []
        var cancellables = Set<AnyCancellable>()
        let contentSubject = CurrentValueSubject<PreprocessedContent, Never>(.init())
        public var throttleInterval: TimeInterval? = nil { // nil = instant per-token updates
            didSet { setupCombine() }
        }

        let viewProvider: ReusableViewProvider

        public init(viewProvider: ReusableViewProvider = .init()) {
            self.viewProvider = viewProvider
            super.init(frame: .zero)
            textView.isSelectable = true
            textView.backgroundColor = .clear
            textView.selectionBackgroundColor = theme.colors.selectionBackground
            textView.delegate = self
            textView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            setupCombine()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            textView.preferredMaxLayoutWidth = bounds.width
        }

        override public var intrinsicContentSize: CGSize {
            textView.intrinsicContentSize
        }

        public func boundingSize(for width: CGFloat) -> CGSize {
            textView.preferredMaxLayoutWidth = width
            return textView.intrinsicContentSize
        }

        public func setMarkdownManually(_ content: PreprocessedContent) {
            assert(Thread.isMainThread)
            resetCombine()
            use(content)
        }

        public func setMarkdown(_ content: PreprocessedContent) {
            contentSubject.send(content)
        }

        public func reset() {
            assert(Thread.isMainThread)
            use(.init())
            setupCombine()
        }

        public func bindContentOffset(from scrollView: UIScrollView?) {
            trackedScrollView = scrollView
        }

        /// Enables or disables auto-scroll-to-bottom on all CodeView subviews.
        /// Call with `true` during streaming, `false` when streaming ends.
        public func setCodeBlockAutoScroll(_ enabled: Bool) {
            for view in contextViews {
                if let codeView = view as? CodeView {
                    codeView.isStreaming = enabled
                }
            }
        }

        /// Shows or hides the built-in header bar on all CodeView subviews.
        /// Call with `true` when a container view supplies its own header.
        public func setCodeBlockBarHidden(_ hidden: Bool) {
            for view in contextViews {
                if let codeView = view as? CodeView {
                    codeView.barHidden = hidden
                }
            }
        }
    }

#elseif canImport(AppKit)
    import AppKit

    public final class MarkdownTextView: NSView {
        public var linkHandler: ((LinkPayload, NSRange, CGPoint) -> Void)?
        public var codePreviewHandler: ((String?, NSAttributedString) -> Void)?

        public internal(set) var document: PreprocessedContent = .init()
        public let textView: LTXLabel = .init()
        public var theme: MarkdownTheme = .default {
            didSet {
                textView.selectionBackgroundColor = theme.colors.selectionBackground
                // Theme change invalidates all cached block renders since fonts/colors differ.
                cachedBlockSegments.removeAll()
                setMarkdown(document)
            }
        }

        public internal(set) weak var trackedScrollView: NSScrollView? // for selection updating

        // Block-level render cache: stores rendered output per MarkdownBlockNode so
        // unchanged blocks can be reused on the next streaming update without re-rendering.
        struct CachedBlockSegment {
            let node: MarkdownBlockNode
            let attributedString: NSAttributedString
            let subviews: [NSView]
        }
        var cachedBlockSegments: [CachedBlockSegment] = []

        // Persistent mutable attributed string for the entire document.
        // We mutate only the dirty tail in-place instead of rebuilding from scratch
        // on every streaming update — converts O(n_total) concat to O(n_dirty).
        var cachedAttributedString: NSMutableAttributedString = .init()

        var contextViews: [NSView] = []
        var cancellables = Set<AnyCancellable>()
        let contentSubject = CurrentValueSubject<PreprocessedContent, Never>(.init())
        public var throttleInterval: TimeInterval? = nil { // nil = instant per-token updates
            didSet { setupCombine() }
        }

        let viewProvider: ReusableViewProvider

        public init(viewProvider: ReusableViewProvider = .init()) {
            self.viewProvider = viewProvider
            super.init(frame: .zero)
            textView.isSelectable = true
            textView.selectionBackgroundColor = theme.colors.selectionBackground
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            textView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            setupCombine()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public var isFlipped: Bool {
            true
        }

        override public func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            setMarkdown(document)
        }

        override public func layout() {
            super.layout()
            textView.preferredMaxLayoutWidth = bounds.width
        }

        override public var intrinsicContentSize: CGSize {
            textView.intrinsicContentSize
        }

        public func boundingSize(for width: CGFloat) -> CGSize {
            textView.preferredMaxLayoutWidth = width
            return textView.intrinsicContentSize
        }

        public func setMarkdownManually(_ content: PreprocessedContent) {
            assert(Thread.isMainThread)
            resetCombine()
            use(content)
        }

        public func setMarkdown(_ content: PreprocessedContent) {
            contentSubject.send(content)
        }

        public func reset() {
            assert(Thread.isMainThread)
            use(.init())
            setupCombine()
        }

        public func bindContentOffset(from scrollView: NSScrollView?) {
            trackedScrollView = scrollView
        }
    }
#endif
