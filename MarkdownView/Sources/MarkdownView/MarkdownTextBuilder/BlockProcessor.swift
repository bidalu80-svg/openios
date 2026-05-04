//
//  Created by ktiays on 2025/1/20.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import CoreText
import Litext
import MarkdownParser
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - BlockProcessor

final class BlockProcessor {
    private let theme: MarkdownTheme
    private let viewProvider: ReusableViewProvider
    private let context: MarkdownTextView.PreprocessedContent
    private let thematicBreakDrawing: TextBuilder.DrawingCallback?
    private let codeDrawing: TextBuilder.DrawingCallback?
    private let tableDrawing: TextBuilder.DrawingCallback?
    private let blockquoteMarking: TextBuilder.BlockquoteMarkingCallback?
    private let blockquoteDrawing: TextBuilder.BlockquoteDrawingCallback?

    init(
        theme: MarkdownTheme,
        viewProvider: ReusableViewProvider,
        context: MarkdownTextView.PreprocessedContent,
        thematicBreakDrawing: TextBuilder.DrawingCallback?,
        codeDrawing: TextBuilder.DrawingCallback?,
        tableDrawing: TextBuilder.DrawingCallback?,
        blockquoteMarking: TextBuilder.BlockquoteMarkingCallback?,
        blockquoteDrawing: TextBuilder.BlockquoteDrawingCallback?
    ) {
        self.theme = theme
        self.viewProvider = viewProvider
        self.context = context
        self.thematicBreakDrawing = thematicBreakDrawing
        self.codeDrawing = codeDrawing
        self.tableDrawing = tableDrawing
        self.blockquoteMarking = blockquoteMarking
        self.blockquoteDrawing = blockquoteDrawing
    }

    func processHeading(level _: Int, contents: [MarkdownInlineNode]) -> NSAttributedString {
        let font: PlatformFont = theme.fonts.title

        return buildWithParagraphSync { paragraph in
            paragraph.paragraphSpacing = theme.spacings.headingSpacing
            paragraph.paragraphSpacingBefore = theme.spacings.headingSpacing
        } content: {
            let string = contents.render(theme: theme, context: context, viewProvider: viewProvider)
            string.addAttributes(
                [.font: font],
                range: NSRange(location: 0, length: string.length)
            )
            return string
        }
    }

    func processParagraph(contents: [MarkdownInlineNode]) -> NSAttributedString {
        buildWithParagraphSync { paragraph in
            paragraph.paragraphSpacing = theme.spacings.paragraphSpacing
            paragraph.lineSpacing = theme.spacings.lineSpacing
        } content: {
            let rendered = contents.render(theme: theme, context: context, viewProvider: viewProvider)
            if rendered.length == 0 {
                return NSMutableAttributedString(string: " ", attributes: [.font: theme.fonts.body])
            }
            return rendered
        }
    }

    func processThematicBreak() -> NSAttributedString {
        buildWithParagraphSync { paragraph in
            // Compact spacing for thematic breaks — the line itself provides
            // visual separation, so we don't need large paragraph gaps on top.
            paragraph.paragraphSpacing = 0
            paragraph.paragraphSpacingBefore = 0
        } content: {
            let drawingCallback = self.thematicBreakDrawing
            return .init(string: LTXReplacementText, attributes: [
                .font: theme.fonts.body,
                .ltxAttachment: LTXAttachment.hold(attrString: .init(string: "\n")),
                .ltxLineDrawingCallback: LTXLineDrawingAction(action: { context, line, lineOrigin in
                    drawingCallback?(context, line, lineOrigin)
                }),
            ])
        }
    }

    func processCodeBlock(
        language: String?,
        content: String,
        highlightMap: CodeHighlighter.HighlightMap
    ) -> (NSAttributedString, CodeView) {
        let content = content.deletingSuffix(of: .whitespacesAndNewlines)
        let codeView = viewProvider.acquireCodeView()
        codeView.theme = theme
        codeView.language = language ?? ""
        if !highlightMap.isEmpty { codeView.highlightMap = highlightMap }
        codeView.content = content
        let drawer = codeDrawing!
        let text = buildWithParagraphSync { paragraph in
            // Use the actual rendered CodeView height — not the formula estimate.
            // The formula (lineHeight × rows) overestimates, leaving dead space.
            let height = codeView.intrinsicContentSize.height
            paragraph.minimumLineHeight = height
        } content: {
            .init(string: LTXReplacementText, attributes: [
                .font: theme.fonts.body,
                .ltxAttachment: LTXAttachment.hold(attrString: .init(string: content + "\n")),
                .ltxLineDrawingCallback: LTXLineDrawingAction { drawer($0, $1, $2) },
                .contextView: codeView,
            ])
        }
        return (text, codeView)
    }

    func processBlockquote(_ children: [MarkdownBlockNode]) -> NSAttributedString {
        guard !children.isEmpty else { return NSAttributedString() }

        let result = NSMutableAttributedString()

        let baseParagraphStyle = NSMutableParagraphStyle()
        baseParagraphStyle.firstLineHeadIndent = theme.spacings.blockquoteIndent
        baseParagraphStyle.headIndent = theme.spacings.blockquoteIndent
        baseParagraphStyle.tailIndent = -4
        baseParagraphStyle.paragraphSpacing = theme.spacings.blockquoteSpacing
        baseParagraphStyle.lineSpacing = theme.spacings.lineSpacing

        for child in children {
            guard case let .paragraph(content) = child else {
                assertionFailure("Blockquote should only contain paragraphs after flattening")
                continue
            }
            let paragraphContent = content.render(theme: theme, context: context, viewProvider: viewProvider)
            result.append(paragraphContent)
        }

        while result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        guard result.length > 0 else { return result }
//        result.append(.init(string: "\n"))

        result.addAttribute(
            .paragraphStyle,
            value: baseParagraphStyle, range: NSRange(location: 0, length: result.length)
        )

        let marker = blockquoteMarking!
        let drawer = blockquoteDrawing!

        result.insert(buildWithParagraphSync(withNewLine: false) { paragraph in
            paragraph = baseParagraphStyle
        } content: {
            .init(string: LTXReplacementText, attributes: [
                .font: theme.fonts.body,
                .paragraphStyle: baseParagraphStyle,
                .ltxLineDrawingCallback: LTXLineDrawingAction { marker($0, $1, $2) },
            ])
        }, at: 0)
        result.append(buildWithParagraphSync(withNewLine: true) {
            .init(string: LTXReplacementText, attributes: [
                .font: theme.fonts.body,
                .ltxLineDrawingCallback: LTXLineDrawingAction { drawer($0, $1, $2) },
            ])
        })

        return result
    }

    func processTable(rows: [RawTableRow]) -> (NSAttributedString, TableView) {
        let tableView = viewProvider.acquireTableView()
        let contents = rows.map {
            $0.cells.map { rawCell in
                rawCell.content.render(theme: theme, context: context, viewProvider: viewProvider)
            }
        }
        let allContent = contents
            .map { $0.map(\.string).joined(separator: "\t") }
            .joined(separator: "\n")
        let representedText = NSAttributedString(string: allContent + "\n")
        tableView.setContents(contents)
        let drawer = tableDrawing!

        let text = buildWithParagraphSync { paragraph in
            paragraph.minimumLineHeight = tableView.intrinsicContentHeight
        } content: {
            .init(string: LTXReplacementText, attributes: [
                .font: theme.fonts.body,
                .ltxAttachment: LTXAttachment.hold(attrString: representedText),
                .ltxLineDrawingCallback: LTXLineDrawingAction { drawer($0, $1, $2) },
                .contextView: tableView,
            ])
        }
        return (text, tableView)
    }
}

// MARK: - Paragraph Helper

extension BlockProcessor {
    private func buildWithParagraphSync(
        withNewLine: Bool = true,
        modifier: (inout NSMutableParagraphStyle) -> Void = { _ in },
        content: () -> NSMutableAttributedString
    ) -> NSMutableAttributedString {
        var paragraphStyle: NSMutableParagraphStyle = .init()
        paragraphStyle.paragraphSpacing = theme.spacings.paragraphSpacing
        paragraphStyle.lineSpacing = theme.spacings.lineSpacing
        modifier(&paragraphStyle)

        let string = content()
        string.addAttributes(
            [.paragraphStyle: paragraphStyle],
            range: .init(location: 0, length: string.length)
        )
        if withNewLine, !string.string.hasSuffix("\n") {
            string.append(.init(string: "\n"))
        }
        return string
    }

    private func removeLeadingSpacing(from attributedString: NSAttributedString) -> NSAttributedString {
        let mutableString = attributedString.mutableCopy() as! NSMutableAttributedString
        mutableString.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: mutableString.length), options: []) { value, range, _ in
            if let style = value as? NSParagraphStyle {
                let mutableStyle = style.mutableCopy() as! NSMutableParagraphStyle
                mutableStyle.paragraphSpacingBefore = 0
                mutableString.addAttribute(.paragraphStyle, value: mutableStyle, range: range)
            }
        }
        return mutableString
    }
}
