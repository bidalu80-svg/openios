//
//  MarkdownTextView+LTXDelegate.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import Litext
import Foundation

#if canImport(UIKit)
    import UIKit

    extension MarkdownTextView: LTXLabelDelegate {
        public func ltxLabelSelectionDidChange(_ label: Litext.LTXLabel, selection: NSRange?) {
            guard let selection, selection.length > 0 else {
                hideSelectionLoupe()
                lastSelectionRangeForLoupe = selection
                lastSelectionTouchLocationForLoupe = nil
                return
            }
            showSelectionLoupe(for: label, selection: selection)
            lastSelectionRangeForLoupe = selection
        }

        public func ltxLabelDetectedUserEventMovingAtLocation(_ label: Litext.LTXLabel, location: CGPoint) {
            lastSelectionTouchLocationForLoupe = label.convert(location, to: self)
            lastSelectionTouchTimestamp = ProcessInfo.processInfo.systemUptime
            showSelectionLoupe(for: label, location: location)

            guard let scrollView = trackedScrollView else { return }
            guard scrollView.contentSize.height > scrollView.bounds.height else { return }

            let edgeDetection = CGFloat(16)
            let scrollViewVisibleRect = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
                .insetBy(dx: -10000, dy: edgeDetection)
            let locationInScrollView = label.convert(location, to: scrollView)
            guard !scrollViewVisibleRect.contains(locationInScrollView) else {
                return
            }

            var currentOffset = scrollView.contentOffset
            if locationInScrollView.y < scrollViewVisibleRect.minY {
                currentOffset.y -= abs(scrollViewVisibleRect.minY - locationInScrollView.y)
            } else {
                currentOffset.y += abs(locationInScrollView.y - scrollViewVisibleRect.maxY)
            }
            currentOffset.y = max(0, currentOffset.y)
            currentOffset.y = min(
                currentOffset.y,
                scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.contentInset.top + scrollView.contentInset.bottom
            )
            scrollView.setContentOffset(currentOffset, animated: false)
        }

        public func ltxLabelDidTapOnHighlightContent(_: LTXLabel, region: LTXHighlightRegion?, location: CGPoint) {
            guard let highlightRegion = region else {
                return
            }

            if let latexContent = highlightRegion.attributes[.mathLatexContent] as? String {
                presentMathPreview(for: latexContent, theme: theme)
                return
            }

            let link = highlightRegion.attributes[NSAttributedString.Key.link]
            let range = highlightRegion.stringRange
            if let url = link as? URL {
                linkHandler?(.url(url), range, location)
            } else if let string = link as? String {
                linkHandler?(.string(string), range, location)
            }
        }
    }

    private extension MarkdownTextView {
        func showSelectionLoupe(for label: LTXLabel, selection: NSRange) {
            if let touchLocation = currentSelectionTouchLocation(in: label) {
                showSelectionLoupe(for: label, location: touchLocation)
                return
            }
            guard let location = selectionLoupeLocation(in: label, selection: selection) else { return }
            showSelectionLoupe(for: label, location: location)
        }

        func showSelectionLoupe(for label: LTXLabel, location: CGPoint) {
            guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
            guard let image = selectionLoupeImage(from: label, around: location) else { return }

            let loupe: MarkdownSelectionLoupeView
            if let existing = selectionLoupeView as? MarkdownSelectionLoupeView {
                loupe = existing
            } else {
                loupe = MarkdownSelectionLoupeView()
                selectionLoupeView = loupe
                addSubview(loupe)
            }

            let anchor = label.convert(location, to: self)
            let size = CGSize(width: 132, height: 58)
            let horizontalPadding: CGFloat = 8
            var originX = anchor.x - size.width / 2
            originX = min(max(horizontalPadding, originX), max(horizontalPadding, bounds.width - size.width - horizontalPadding))

            var originY = anchor.y - size.height - 28
            if originY < 8 {
                originY = anchor.y + 28
            }

            loupe.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: size)
            loupe.update(image: image)
            loupe.alpha = 1

            selectionLoupeHideWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak loupe] in
                UIView.animate(withDuration: 0.16) {
                    loupe?.alpha = 0
                } completion: { _ in
                    guard self?.selectionLoupeView === loupe else { return }
                    loupe?.removeFromSuperview()
                    self?.selectionLoupeView = nil
                }
            }
            selectionLoupeHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
        }

        func hideSelectionLoupe() {
            selectionLoupeHideWorkItem?.cancel()
            selectionLoupeHideWorkItem = nil
            selectionLoupeView?.removeFromSuperview()
            selectionLoupeView = nil
            lastSelectionTouchLocationForLoupe = nil
        }

        func currentSelectionTouchLocation(in label: LTXLabel) -> CGPoint? {
            guard ProcessInfo.processInfo.systemUptime - lastSelectionTouchTimestamp < 0.35,
                  let markdownLocation = lastSelectionTouchLocationForLoupe else {
                return nil
            }
            guard bounds.insetBy(dx: -40, dy: -80).contains(markdownLocation) else {
                return nil
            }
            return convert(markdownLocation, to: label)
        }

        func selectionLoupeLocation(in label: LTXLabel, selection: NSRange) -> CGPoint? {
            let handles = label.subviews.compactMap { $0 as? LTXSelectionHandle }.filter { !$0.isHidden }
            let currentEnd = selection.location + selection.length
            let wantsStartHandle: Bool = {
                guard let previous = lastSelectionRangeForLoupe else { return false }
                return selection.location != previous.location
                    && currentEnd == previous.location + previous.length
            }()

            if let handle = handles.first(where: { wantsStartHandle ? $0.type == .start : $0.type == .end }) {
                let handlePoint = CGPoint(
                    x: handle.type == .start ? handle.bounds.maxX + 2 : handle.bounds.minX - 2,
                    y: handle.bounds.midY
                )
                return handle.convert(handlePoint, to: label)
            }

            if let handle = handles.last {
                return handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: label)
            }
            return nil
        }

        func selectionLoupeImage(from label: LTXLabel, around location: CGPoint) -> UIImage? {
            let sourceSize = CGSize(width: 86, height: 42)
            var crop = CGRect(
                x: location.x - sourceSize.width / 2,
                y: location.y - sourceSize.height / 2,
                width: min(sourceSize.width, max(1, label.bounds.width)),
                height: min(sourceSize.height, max(1, label.bounds.height))
            )
            crop.origin.x = min(max(0, crop.origin.x), max(0, label.bounds.width - crop.width))
            crop.origin.y = min(max(0, crop.origin.y), max(0, label.bounds.height - crop.height))
            guard crop.width > 1, crop.height > 1 else { return nil }

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = UIScreen.main.scale
            return UIGraphicsImageRenderer(size: crop.size, format: format).image { context in
                context.cgContext.translateBy(x: -crop.origin.x, y: -crop.origin.y)
                label.layer.render(in: context.cgContext)
            }
        }
    }

    private final class MarkdownSelectionLoupeView: UIView {
        private let imageView = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            clipsToBounds = false

            backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
            layer.cornerRadius = 16
            layer.cornerCurve = .continuous
            layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
            layer.borderWidth = 1
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 4)
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 12

            imageView.clipsToBounds = true
            imageView.contentMode = .scaleAspectFill
            imageView.layer.cornerRadius = 13
            imageView.layer.cornerCurve = .continuous
            addSubview(imageView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds.insetBy(dx: 5, dy: 5)
        }

        func update(image: UIImage) {
            imageView.image = image
        }
    }

#elseif canImport(AppKit)
    import AppKit

    extension MarkdownTextView: LTXLabelDelegate {
        public func ltxLabelSelectionDidChange(_: Litext.LTXLabel, selection _: NSRange?) {
            // reserved for future use
        }

        public func ltxLabelDetectedUserEventMovingAtLocation(_ label: Litext.LTXLabel, location: CGPoint) {
            guard let scrollView = trackedScrollView else { return }
            guard let documentView = scrollView.documentView else { return }
            guard documentView.bounds.height > scrollView.bounds.height else { return }

            let edgeDetection = CGFloat(16)
            let visibleRect = scrollView.documentVisibleRect.insetBy(dx: -10000, dy: edgeDetection)
            let locationInScrollView = label.convert(location, to: documentView)

            guard !visibleRect.contains(locationInScrollView) else {
                return
            }

            var newOrigin = scrollView.documentVisibleRect.origin
            if locationInScrollView.y < visibleRect.minY {
                newOrigin.y -= abs(visibleRect.minY - locationInScrollView.y)
            } else {
                newOrigin.y += abs(locationInScrollView.y - visibleRect.maxY)
            }
            newOrigin.y = max(0, newOrigin.y)
            newOrigin.y = min(newOrigin.y, documentView.bounds.height - scrollView.bounds.height)
            documentView.scroll(newOrigin)
        }

        public func ltxLabelDidTapOnHighlightContent(_: LTXLabel, region: LTXHighlightRegion?, location: CGPoint) {
            guard let highlightRegion = region else {
                return
            }

            if let latexContent = highlightRegion.attributes[.mathLatexContent] as? String {
                presentMathPreview(for: latexContent, theme: theme)
                return
            }

            let link = highlightRegion.attributes[NSAttributedString.Key.link]
            let range = highlightRegion.stringRange
            if let url = link as? URL {
                linkHandler?(.url(url), range, location)
            } else if let string = link as? String {
                linkHandler?(.string(string), range, location)
            }
        }
    }
#endif
