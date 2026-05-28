//
//  MarkdownView+View.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2026/2/1.
//

import MarkdownParser
import Foundation
import SwiftUI

public struct MarkdownView: View {
    public typealias PreprocessedContent = MarkdownTextView.PreprocessedContent

    enum ContentSource {
        case text(String)
        case preprocessed(PreprocessedContent)
    }

    let contentSource: ContentSource
    public var theme: MarkdownTheme
    /// When true, all code blocks inside this MarkdownView auto-scroll to their bottom.
    /// Set true during streaming, false when streaming ends.
    public var codeBlockAutoScroll: Bool = false
    /// When true, the built-in header bar of every code block is hidden.
    /// Use this when a parent view provides its own header (e.g. PythonCodeBlockView).
    public var codeBlockBarHidden: Bool = false

    @State private var measuredHeight: CGFloat = 0
    @State private var citationIconRefreshToken = 0

    public init(_ text: String, theme: MarkdownTheme = .default) {
        contentSource = .text(text)
        self.theme = theme
    }

    public init(_ preprocessedContent: PreprocessedContent, theme: MarkdownTheme = .default) {
        contentSource = .preprocessed(preprocessedContent)
        self.theme = theme
    }

    /// Fluent setter for codeBlockAutoScroll.
    public func codeAutoScroll(_ enabled: Bool) -> MarkdownView {
        var copy = self
        copy.codeBlockAutoScroll = enabled
        return copy
    }

    /// Fluent setter for codeBlockBarHidden.
    /// When `hidden` is true, the built-in language/copy/preview bar inside every
    /// code block is suppressed so a container view can render its own header.
    public func codeBarHidden(_ hidden: Bool) -> MarkdownView {
        var copy = self
        copy.codeBlockBarHidden = hidden
        return copy
    }

    public var body: some View {
        GeometryReader { proxy in
            let effectiveHeight = currentLayoutHeight(for: proxy.size.width)
            ZStack(alignment: .topLeading) {
                MarkdownViewRepresentable(
                    contentSource: contentSource,
                    theme: theme,
                    codeBlockAutoScroll: codeBlockAutoScroll,
                    codeBlockBarHidden: codeBlockBarHidden,
                    citationIconRefreshToken: citationIconRefreshToken,
                    width: proxy.size.width,
                    measuredHeight: $measuredHeight
                )
                .frame(
                    width: proxy.size.width,
                    height: effectiveHeight,
                    alignment: .topLeading
                )
            }
        }
        .frame(height: currentLayoutHeight())
        .onReceive(NotificationCenter.default.publisher(for: .markdownCitationIconDidUpdate)) { _ in
            guard !codeBlockAutoScroll, containsCitationLink else { return }
            citationIconRefreshToken &+= 1
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func currentLayoutHeight(for width: CGFloat? = nil) -> CGFloat {
        if measuredHeight > 1 {
            return measuredHeight
        }
        return estimatedInitialHeight(for: width)
    }

    private func estimatedInitialHeight(for width: CGFloat?) -> CGFloat {
        let text: String
        switch contentSource {
        case .text(let value):
            text = value
        case .preprocessed:
            return 28
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1 }

        let availableWidth = max(width ?? 260, 120)
        let estimatedCharsPerLine = max(Int(availableWidth / 13), 8)
        let visualLineCount = trimmed.components(separatedBy: .newlines).reduce(0) { total, line in
            let count = line.trimmingCharacters(in: .whitespaces).count
            return total + max(1, Int(ceil(Double(max(count, 1)) / Double(estimatedCharsPerLine))))
        }
        return min(max(CGFloat(visualLineCount) * 24 + 8, 28), 900)
    }

    private var containsCitationLink: Bool {
        switch contentSource {
        case .text(let text):
            return text.contains("#cite")
        case .preprocessed:
            return true
        }
    }
}
