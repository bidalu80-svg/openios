//
//  InlineNode+Render.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2025/1/3.
//

import Foundation
import Litext
import MarkdownParser
import SwiftMath
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

extension [MarkdownInlineNode] {
    func render(theme: MarkdownTheme, context: MarkdownTextView.PreprocessedContent, viewProvider: ReusableViewProvider) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for node in self {
            result.append(node.render(theme: theme, context: context, viewProvider: viewProvider))
        }
        return result
    }
}

extension MarkdownInlineNode {
    func render(theme: MarkdownTheme, context: MarkdownTextView.PreprocessedContent, viewProvider: ReusableViewProvider) -> NSAttributedString {
        assert(Thread.isMainThread)
        switch self {
        case let .text(string):
            return NSMutableAttributedString(
                string: string,
                attributes: [
                    .font: theme.fonts.body,
                    .foregroundColor: theme.colors.body,
                ]
            )
        case .softBreak:
            // Use Unicode Line Separator (U+2028) — NOT paragraph separator (\n).
            // In CoreText, \n triggers paragraphSpacing (big gap) while \u{2028}
            // only triggers lineSpacing (small gap). This gives us:
            //   - Lines within a stanza: tight spacing (lineSpacing ~4pt)
            //   - Between stanzas (\n\n = separate paragraph blocks): big gap (paragraphSpacing 16pt)
            // This matches Iexa / ChatGPT rendering of poems and structured content.
            return NSAttributedString(string: "\u{2028}", attributes: [
                .font: theme.fonts.body,
                .foregroundColor: theme.colors.body,
            ])
        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: [
                .font: theme.fonts.body,
                .foregroundColor: theme.colors.body,
            ])
        case let .code(string), let .html(string):
            let controlAttributes: [NSAttributedString.Key: Any] = [
                .font: theme.fonts.codeInline,
                .backgroundColor: theme.colors.codeBackground.withAlphaComponent(0.05),
            ]
            let text = NSMutableAttributedString(string: string, attributes: [.foregroundColor: theme.colors.code])
            text.addAttributes(controlAttributes, range: .init(location: 0, length: text.length))
            return text
        case let .emphasis(children):
            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }
            ans.addAttributes(
                [.font: theme.fonts.italic],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .strong(children):
            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }
            ans.addAttributes(
                [.font: theme.fonts.bold],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .strikethrough(children):
            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }
            ans.addAttributes(
                [.strikethroughStyle: NSUnderlineStyle.thick.rawValue],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .link(destination, children):
            // Inline citations: links ending with #cite render as a favicon badge.
            let isCitation = destination.hasSuffix("#cite")
            let cleanDestination = isCitation ? String(destination.dropLast(5)) : destination

            if isCitation {
                return renderCitationIcon(destination: cleanDestination, theme: theme)
            }

            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }

            ans.addAttributes(
                [
                    .link: cleanDestination,
                    .foregroundColor: theme.colors.highlight,
                ],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .image(source, _): // children => alternative text can be ignored?
            return NSAttributedString(
                string: source,
                attributes: [
                    .link: source,
                    .font: theme.fonts.body,
                    .foregroundColor: theme.colors.body,
                ]
            )
        case let .math(content, replacementIdentifier):
            // Get LaTeX content from rendered context or fallback to raw content
            let latexContent = context.rendered[replacementIdentifier]?.text ?? content

            if let item = context.rendered[replacementIdentifier], let image = item.image {
                var imageSize = image.size

                let drawingCallback = LTXLineDrawingAction { context, line, lineOrigin in
                    let glyphRuns = CTLineGetGlyphRuns(line) as NSArray
                    var runOffsetX: CGFloat = 0
                    for i in 0 ..< glyphRuns.count {
                        let run = glyphRuns[i] as! CTRun
                        let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                        if attributes[.contextIdentifier] as? String == replacementIdentifier {
                            break
                        }
                        runOffsetX += CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
                    }

                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                    if imageSize.height > ascent { // we only draw above the line
                        let newWidth = imageSize.width * (ascent / imageSize.height)
                        imageSize = CGSize(width: newWidth, height: ascent)
                    }

                    let rect = CGRect(
                        x: lineOrigin.x + runOffsetX,
                        y: lineOrigin.y,
                        width: imageSize.width,
                        height: imageSize.height
                    )

                    context.saveGState()

                    #if canImport(UIKit)
                        context.translateBy(x: 0, y: rect.origin.y + rect.size.height)
                        context.scaleBy(x: 1, y: -1)
                        context.translateBy(x: 0, y: -rect.origin.y)
                        image.draw(in: rect)
                    #else
                        assert(image.isTemplate)
                        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            // Resolve label color at draw time for dynamic appearance updates
                            let labelColor = NSColor.labelColor.cgColor
                            context.clip(to: rect, mask: cgImage)
                            context.setFillColor(labelColor)
                            context.fill(rect)
                        } else {
                            assertionFailure()
                        }
                    #endif

                    context.restoreGState()
                }
                let attachment = LTXAttachment.hold(attrString: .init(string: latexContent))
                attachment.size = imageSize

                let attributes: [NSAttributedString.Key: Any] = [
                    LTXAttachmentAttributeName: attachment,
                    LTXLineDrawingCallbackName: drawingCallback,
                    kCTRunDelegateAttributeName as NSAttributedString.Key: attachment.runDelegate,
                    .contextIdentifier: replacementIdentifier,
                    .mathLatexContent: latexContent, // Store LaTeX content for on-demand rendering
                ]

                return NSAttributedString(
                    string: LTXReplacementText,
                    attributes: attributes
                )
            } else {
                // Fallback: render failed, show original LaTeX as inline code
                return NSAttributedString(
                    string: latexContent,
                    attributes: [
                        .font: theme.fonts.codeInline,
                        .foregroundColor: theme.colors.code,
                        .backgroundColor: theme.colors.codeBackground.withAlphaComponent(0.05),
                    ]
                )
            }
        }
    }

    private func renderCitationIcon(destination: String, theme: MarkdownTheme) -> NSAttributedString {
        let iconSide = max(13, min(18, theme.fonts.body.pointSize * 0.84))
        let attachmentSize = CGSize(width: iconSide, height: iconSide)
        let identifier = "citation-icon-\(destination)-\(UUID().uuidString)"
        let sourceURL = URL(string: destination)

        let drawingCallback = LTXLineDrawingAction { context, line, lineOrigin in
            let glyphRuns = CTLineGetGlyphRuns(line) as NSArray
            var runOffsetX: CGFloat = 0
            for i in 0 ..< glyphRuns.count {
                let run = glyphRuns[i] as! CTRun
                let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                if attributes[.contextIdentifier] as? String == identifier {
                    break
                }
                runOffsetX += CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
            }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let lineHeight = ascent + descent
            let rect = CGRect(
                x: lineOrigin.x + runOffsetX,
                y: lineOrigin.y - descent + (lineHeight - attachmentSize.height) / 2,
                width: attachmentSize.width,
                height: attachmentSize.height
            )

            let image = sourceURL.flatMap {
                MarkdownCitationIconProvider.shared.icon(for: $0, pointSize: iconSide)
            }
            Self.drawCitationIcon(
                image: image,
                fallbackColor: theme.colors.highlight,
                in: rect,
                context: context
            )
        }

        let attachment = LTXAttachment.hold(attrString: .init(string: ""))
        attachment.size = attachmentSize

        let attributes: [NSAttributedString.Key: Any] = [
            LTXAttachmentAttributeName: attachment,
            LTXLineDrawingCallbackName: drawingCallback,
            kCTRunDelegateAttributeName as NSAttributedString.Key: attachment.runDelegate,
            .contextIdentifier: identifier,
            .link: destination,
        ]

        return NSAttributedString(string: LTXReplacementText, attributes: attributes)
    }

    private static func drawCitationIcon(
        image: PlatformImage?,
        fallbackColor: PlatformColor,
        in rect: CGRect,
        context: CGContext
    ) {
        #if canImport(UIKit)
            context.saveGState()
            context.translateBy(x: 0, y: rect.origin.y + rect.size.height)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.origin.y)
            if let image {
                image.draw(in: rect)
            } else if let globe = UIImage(
                systemName: "globe",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
            )?.withTintColor(fallbackColor, renderingMode: .alwaysOriginal) {
                globe.draw(in: rect)
            }
            context.restoreGState()
        #elseif canImport(AppKit)
            if let image {
                image.draw(in: rect)
            } else if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) {
                NSGraphicsContext.saveGraphicsState()
                fallbackColor.set()
                globe.draw(in: rect, from: .zero, operation: .sourceAtop, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
        #endif
    }
}
