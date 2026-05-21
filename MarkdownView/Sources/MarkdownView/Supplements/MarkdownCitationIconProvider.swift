//
//  MarkdownCitationIconProvider.swift
//  MarkdownView
//

import Foundation

/// Host applications can provide cached website icons for inline citations.
public final class MarkdownCitationIconProvider {
    public static let shared = MarkdownCitationIconProvider()

    private let lock = NSLock()
    private var provider: ((URL, CGFloat) -> PlatformImage?)?

    private init() {}

    public func setProvider(_ provider: ((URL, CGFloat) -> PlatformImage?)?) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    func icon(for sourceURL: URL, pointSize: CGFloat) -> PlatformImage? {
        lock.lock()
        let provider = provider
        lock.unlock()
        return provider?(sourceURL, pointSize)
    }
}
