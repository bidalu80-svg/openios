//
//  NotificationNames.swift
//  MarkdownView
//

import Foundation

public extension Notification.Name {
    /// Posted when the user taps the "eye" (preview) button on a code block.
    /// `userInfo` contains:
    /// - `"code"`: `String` — the full code content
    /// - `"language"`: `String` — the language tag (e.g., "python", "swift")
    static let markdownCodePreview = Notification.Name("markdownCodePreview")

    /// Posted when the user taps a link inside rendered markdown content.
    /// `userInfo` contains:
    /// - `"url"`: `URL` — the tapped link URL
    ///
    /// The host app should observe this notification and decide whether to
    /// handle the URL internally (e.g. authenticated file download) or open
    /// it externally in Safari.
    static let markdownLinkTapped = Notification.Name("markdownLinkTapped")
}
