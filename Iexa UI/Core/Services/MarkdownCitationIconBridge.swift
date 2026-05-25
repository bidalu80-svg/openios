import Foundation
import UIKit
import MarkdownView

final class MarkdownCitationIconBridge: @unchecked Sendable {
    static let shared = MarkdownCitationIconBridge()

    private let lock = NSLock()
    private var activeLoads = Set<String>()
    private var failedLoads = Set<String>()

    private init() {}

    func icon(for sourceURL: URL, pointSize: CGFloat) -> UIImage? {
        let targetPixelSize = max(32, Int(ceil(pointSize * UIScreen.main.scale)))
        let candidates = WebsiteFaviconResolver.candidateURLs(
            for: sourceURL.absoluteString,
            size: max(64, targetPixelSize)
        )

        for candidate in candidates {
            if let cached = ImageCacheService.shared.cachedImageSync(for: candidate) {
                return cached
            }
        }

        loadIconIfNeeded(
            sourceKey: sourceKey(for: sourceURL),
            candidates: Array(candidates.prefix(6)),
            targetPixelSize: targetPixelSize
        )
        return nil
    }

    private func loadIconIfNeeded(sourceKey: String, candidates: [URL], targetPixelSize: Int) {
        guard !candidates.isEmpty else { return }

        lock.lock()
        if activeLoads.contains(sourceKey) || failedLoads.contains(sourceKey) {
            lock.unlock()
            return
        }
        activeLoads.insert(sourceKey)
        lock.unlock()

        Task {
            var didLoad = false
            for candidate in candidates {
                if Task.isCancelled { break }
                if await ImageCacheService.shared.loadImage(from: candidate, targetPixelSize: targetPixelSize) != nil {
                    didLoad = true
                    break
                }
            }

            lock.lock()
            activeLoads.remove(sourceKey)
            if !didLoad {
                failedLoads.insert(sourceKey)
            }
            lock.unlock()

            if didLoad {
                await MainActor.run {
                    NotificationCenter.default.post(name: .markdownCitationIconDidUpdate, object: nil)
                }
            }
        }
    }

    private func sourceKey(for url: URL) -> String {
        if let host = url.host?.lowercased(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }
}
