//
//  MarkdownTextView+Private.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import Combine
import Foundation
import Litext

extension MarkdownTextView {
    func resetCombine() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func setupCombine() {
        resetCombine()
        if let throttleInterval {
            contentSubject
                .throttle(for: .seconds(throttleInterval), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] content in self?.use(content) }
                .store(in: &cancellables)
        } else {
            contentSubject
                .sink { [weak self] content in self?.use(content) }
                .store(in: &cancellables)
        }
    }

    func use(_ content: PreprocessedContent) {
        assert(Thread.isMainThread)

        // When content is empty (reset case), clear the block-level cache AND the
        // persistent attributed string so the next real document starts clean.
        if content.blocks.isEmpty {
            cachedBlockSegments.removeAll()
            cachedAttributedString = .init()
        }

        document = content
        // due to a bug in model gemini-flash
        // there might be a large of unknown empty whitespace inside the table
        // thus we hereby call the autoreleasepool to avoid large memory consumption
        autoreleasepool { updateTextExecute() }

        // MEMORY FIX: After updateTextExecute() bakes the AST and math images
        // into the NSAttributedString, the PreprocessedContent's heavyweight data
        // (MarkdownBlockNode tree, rendered math UIImages, highlight maps) is no
        // longer needed. Replace with an empty instance to free that memory.
        // For a message with code blocks + math, this saves ~2-10MB per message.
        // The coordinator's lastText/lastPreprocessedContent handles diffing,
        // so clearing `document` here is safe.
        // NOTE: We do NOT clear cachedBlockSegments here — the cache holds its
        // own copies of MarkdownBlockNode and NSAttributedString, and must persist
        // across streaming updates to enable incremental rendering.
        document = PreprocessedContent()

        // Do NOT call layoutIfNeeded() here.
        // updateTextExecute() already called setNeedsLayout() / needsLayout = true,
        // which schedules layout for the next run-loop pass. Calling layoutIfNeeded()
        // synchronously would force a full O(n) layout of the entire growing attributed
        // string on EVERY streaming token — the main cause of the smoothness drop.
        // The run-loop will batch and coalesce layout passes automatically.
    }
}
