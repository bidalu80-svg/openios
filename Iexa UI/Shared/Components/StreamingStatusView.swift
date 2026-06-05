import SwiftUI
import UIKit
import MarkdownView

// MARK: - Streaming Status View

struct StreamingStatusView: View {
    let statusHistory: [ChatStatusUpdate]
    var isStreaming: Bool = true

    @Environment(\.theme) private var theme
    @State private var isExpanded: Bool
    @State private var localAlpineNow = Date()

    init(statusHistory: [ChatStatusUpdate], isStreaming: Bool = true) {
        self.statusHistory = statusHistory
        self.isStreaming = isStreaming
        // Always start collapsed
        _isExpanded = State(initialValue: false)
    }

    /// Visible (non-hidden) status items.
    private var visibleStatuses: [ChatStatusUpdate] {
        statusHistory.filter { $0.hidden != true }
    }

    /// The most recent status update.
    private var latestStatus: ChatStatusUpdate? {
        visibleStatuses.last
    }

    /// The latest web-search/readable status in this batch. Some providers send
    /// `get_readable` after `web_search`; the UI should still stay on the compact
    /// sources row instead of turning into a generic tool capsule.
    private var latestWebSearchStatus: ChatStatusUpdate? {
        let webStatuses = visibleStatuses.filter { status in
            guard let action = status.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }
            return Self.isWebSearchAction(action)
        }
        return webStatuses.last { status in
            !status.items.isEmpty
                || !status.urls.isEmpty
                || (status.count ?? 0) > 0
        } ?? webStatuses.last
    }

    /// Whether all status updates are marked done.
    private var allDone: Bool {
        visibleStatuses.allSatisfy { $0.done == true }
    }

    var body: some View {
        if visibleStatuses.isEmpty {
            EmptyView()
        } else if isLocalAlpineStatus {
            localAlpineActivityRow
        } else if isLocalAlpineAgentStatus || isLocalAlpineToolStatus {
            localAlpineAgentActivityRow
        } else if isWebSearchStatus {
            webSearchCard
        } else {
            defaultStatusBody
        }
    }

    private var defaultStatusBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Header row with latest status
            statusHeader

            // Expanded list of all statuses
            if isExpanded && visibleStatuses.count > 1 {
                statusList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Search queries section (shown for the latest status if it has queries)
            if let latest = latestStatus, !latest.queries.isEmpty {
                queriesSection(latest)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.xs)
        .animation(MicroAnimation.snappy, value: isExpanded)
        .animation(MicroAnimation.gentle, value: visibleStatuses.count)
        .onAppear {
            // Collapse immediately if already done when first rendered
            if allDone && !isStreaming {
                isExpanded = false
            }
        }
        .onChange(of: allDone) { _, done in
            if done && !isStreaming {
                withAnimation(MicroAnimation.snappy) {
                    isExpanded = false
                }
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming && allDone {
                withAnimation(MicroAnimation.snappy) {
                    isExpanded = false
                }
            }
        }
    }

    private var isLocalAlpineStatus: Bool {
        latestStatus?.action?.lowercased() == "local_alpine"
    }

    private var isLocalAlpineAgentStatus: Bool {
        latestStatus?.action?.lowercased() == "local_alpine_agent"
    }

    private var isLocalAlpineToolStatus: Bool {
        latestStatus?.action?.lowercased() == "local_alpine_tool"
    }

    private var isWebSearchStatus: Bool {
        guard let action = latestStatus?.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return Self.isWebSearchAction(action)
    }

    private static func isWebSearchAction(_ action: String) -> Bool {
        action == "web_search"
            || action == "websearch"
            || action == "web search"
            || action == "local_alpine_web_search"
            || action == "browser_web_search"
            || action == "get_readable"
            || action.contains("readable")
    }

    private func isLocalAlpineWebSearch(_ status: ChatStatusUpdate?) -> Bool {
        status?.action?.lowercased() == "local_alpine_web_search"
    }

    private func isBrowserWebSearch(_ status: ChatStatusUpdate?) -> Bool {
        status?.action?.lowercased() == "browser_web_search"
    }

    private var webSearchCard: some View {
        let latest = latestWebSearchStatus ?? latestStatus
        let isDone = latest?.done == true
        let title = webSearchTitle(for: latest)
        let subtitle = webSearchSubtitle(for: latest)
        let queries = webSearchQueries(for: latest)
        let items = webSearchItems(for: latest)
        let visibleSourceCount = max(max(items.count, latest?.urls.count ?? 0), latest?.count ?? 0)

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(MicroAnimation.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill((isDone ? theme.success : theme.brandPrimary).opacity(theme.isDark ? 0.16 : 0.10))
                            .frame(width: 30, height: 30)

                        if isDone {
                            Image(systemName: "checkmark")
                                .scaledFont(size: 13, weight: .bold)
                                .foregroundStyle(theme.success)
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(theme.brandPrimary)
                        }
                    }

                    HStack(spacing: 9) {
                        webSearchSourceCluster(items)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(sourceLabel(count: visibleSourceCount, fallback: title))
                                .scaledFont(size: 14, weight: .semibold)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)

                            if !isDone {
                                Text(subtitle)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    if !queries.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(queries.enumerated()), id: \.offset) { _, query in
                                webSearchQueryChip(query)
                            }
                        }
                    }

                    if !items.isEmpty {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            webSearchSourceRow(index: index + 1, item: item)
                        }
                    } else if let latest, !latest.urls.isEmpty {
                        ForEach(Array(latest.urls.enumerated()), id: \.offset) { index, url in
                            webSearchSourceRow(index: index + 1, item: ChatStatusItem(title: hostLabel(from: url) ?? url, link: url))
                        }
                    }
                }
                .padding(.leading, 40)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.82 : 0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.5 : 0.75), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.2 : 0.06), radius: 12, x: 0, y: 6)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.xs)
        .animation(MicroAnimation.snappy, value: isExpanded)
        .onAppear {
            if !isDone && isStreaming {
                isExpanded = true
            }
        }
        .onChange(of: latestStatus?.done == true) { _, done in
            if done {
                withAnimation(MicroAnimation.snappy) {
                    isExpanded = false
                }
            }
        }
    }

    private func webSearchTitle(for status: ChatStatusUpdate?) -> String {
        guard let status else { return "正在联网搜索" }
        let localAlpine = isLocalAlpineWebSearch(status)
        let browser = isBrowserWebSearch(status)
        if status.done == true {
            if let count = status.count, count > 0 {
                if browser { return "内置浏览器已读取 \(count) 个网页" }
                return localAlpine ? "本地已读取 \(count) 个网页" : "已搜索 \(count) 个网页"
            }
            if !status.items.isEmpty {
                if browser { return "内置浏览器已搜索 \(status.items.count) 个来源" }
                return localAlpine ? "本地已搜索 \(status.items.count) 个来源" : "已搜索 \(status.items.count) 个来源"
            }
            return status.description ?? (browser ? "内置浏览器搜索完成" : (localAlpine ? "本地搜索完成" : "已完成联网搜索"))
        }
        if let query = status.query, !query.isEmpty {
            return browser ? "内置浏览器搜索中" : (localAlpine ? "本地搜索中" : "正在搜索")
        }
        return status.description ?? (browser ? "内置浏览器搜索中" : (localAlpine ? "本地搜索中" : "正在联网搜索"))
    }

    private func webSearchSubtitle(for status: ChatStatusUpdate?) -> String {
        guard let status else { return "准备搜索" }
        let localAlpine = isLocalAlpineWebSearch(status)
        let browser = isBrowserWebSearch(status)
        if status.done == true {
            let sourceCount = max(status.items.count, status.urls.count)
            if sourceCount > 0 {
                return browser ? "浏览器读取 \(sourceCount) 个来源" : (localAlpine ? "本地读取 \(sourceCount) 个来源" : "获取了 \(sourceCount) 个来源")
            }
            return browser ? "浏览器搜索完成" : (localAlpine ? "本地搜索完成" : "搜索完成")
        }
        if let query = status.query, !query.isEmpty {
            return query
        }
        return status.queries.first ?? "正在获取网页"
    }

    private func webSearchQueries(for status: ChatStatusUpdate?) -> [String] {
        guard let status else { return [] }
        var result = status.queries
        if let query = status.query, !query.isEmpty, !result.contains(query) {
            result.insert(query, at: 0)
        }
        return Array(result.prefix(3))
    }

    private func webSearchItems(for status: ChatStatusUpdate?) -> [ChatStatusItem] {
        guard let status else { return [] }
        if !status.items.isEmpty { return Array(status.items.prefix(6)) }
        return status.urls.prefix(6).map { url in
            ChatStatusItem(title: hostLabel(from: url) ?? url, link: url)
        }
    }

    private func sourceLabel(count: Int, fallback: String) -> String {
        guard count > 0 else { return fallback }
        return "\(count) 个来源"
    }

    private func webSearchSourceCluster(_ items: [ChatStatusItem]) -> some View {
        let visible = Array(items.prefix(3))
        return HStack(spacing: -7) {
            if visible.isEmpty {
                Image(systemName: "globe")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.surfaceContainerHighest))
                    .overlay(Circle().strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.8))
            } else {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                    let label = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = item.link?.trimmingCharacters(in: .whitespacesAndNewlines)
                    webSearchFavicon(
                        for: url,
                        title: label?.isEmpty == false ? label! : (url.flatMap(hostLabel(from:)) ?? "来源"),
                        size: 30
                    )
                    .background(Circle().fill(theme.background))
                }
            }
        }
        .frame(width: visible.count <= 1 ? 30 : CGFloat(30 + max(0, visible.count - 1) * 23), height: 30, alignment: .leading)
    }

    private func webSearchQueryChip(_ query: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
            Text(query)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.62 : 0.86))
        )
    }

    private func webSearchSourceRow(index: Int, item: ChatStatusItem) -> some View {
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = item.link?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title?.isEmpty == false ? title! : (urlString.flatMap(hostLabel(from:)) ?? "来源 \(index)")

        return Group {
            if let urlString, let url = URL(string: urlString) {
                Button {
                    NotificationCenter.default.post(
                        name: .markdownLinkTapped,
                        object: nil,
                        userInfo: ["url": url]
                    )
                } label: {
                    webSearchSourceRowContent(
                        index: index,
                        title: label,
                        url: urlString,
                        snippet: item.snippet,
                        thumbnailURL: item.thumbnailURL,
                        hasLink: true
                    )
                }
                .buttonStyle(.plain)
            } else {
                webSearchSourceRowContent(
                    index: index,
                    title: label,
                    url: urlString,
                    snippet: item.snippet,
                    thumbnailURL: item.thumbnailURL,
                    hasLink: false
                )
            }
        }
    }

    private func webSearchSourceRowContent(
        index: Int,
        title: String,
        url: String?,
        snippet: String?,
        thumbnailURL: String?,
        hasLink: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.55 : 0.8)))

            if let thumbnailURL, !thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                webSearchThumbnail(thumbnailURL, fallbackURL: url, title: title)
            } else {
                webSearchFavicon(for: url, title: title, size: 20)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                if let snippet = snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                    Text(snippet)
                        .scaledFont(size: 11, weight: .regular)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                }
                if let url, let host = hostLabel(from: url) {
                    Text(host)
                        .scaledFont(size: 11, weight: .regular)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if hasLink {
                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary.opacity(0.75))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.72))
        )
    }

    @ViewBuilder
    private func webSearchThumbnail(_ reference: String, fallbackURL: String?, title: String) -> some View {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let image = webSearchLocalImage(from: trimmed) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
                )
        } else if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            FallbackCachedAsyncImage(urls: [url], targetPixelSize: 180) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                thumbnailPlaceholder(fallbackURL: fallbackURL, title: title)
            }
            .frame(width: 72, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
            )
        } else {
            thumbnailPlaceholder(fallbackURL: fallbackURL, title: title)
        }
    }

    private func webSearchLocalImage(from reference: String) -> UIImage? {
        if reference.hasPrefix("file://"),
           let url = URL(string: reference),
           url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }
        if reference.hasPrefix("data:image/"),
           let comma = reference.firstIndex(of: ",") {
            let encoded = String(reference[reference.index(after: comma)...])
            if let data = Data(base64Encoded: encoded) {
                return UIImage(data: data)
            }
        }
        return nil
    }

    private func thumbnailPlaceholder(fallbackURL: String?, title: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceContainerHighest.opacity(theme.isDark ? 0.55 : 0.82))
            webSearchFavicon(for: fallbackURL, title: title, size: 24)
        }
        .frame(width: 72, height: 46)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.45), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func webSearchFavicon(for urlString: String?, title: String, size: CGFloat) -> some View {
        let targetPixelSize = Int(size * UIScreen.main.scale)
        let faviconURLs = urlString
            .map { WebsiteFaviconResolver.candidateURLs(for: $0, size: max(64, targetPixelSize)) }
            ?? []
        FallbackCachedAsyncImage(urls: faviconURLs, targetPixelSize: targetPixelSize) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Image(systemName: "globe")
                .scaledFont(size: max(10, size * 0.48), weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .frame(width: size, height: size)
                .background(theme.surfaceContainerHighest)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(theme.cardBorder.opacity(0.45), lineWidth: 0.5))
    }

    private func hostLabel(from urlString: String) -> String? {
        guard let url = URL(string: urlString), var host = url.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private var localAlpineCard: some View {
        let latest = latestStatus
        let title = localAlpineTitle(for: latest)
        let subtitle = latest.flatMap { resolveStatusDescription(for: $0) } ?? "正在执行本地命令..."
        let isDone = latest?.done == true
        let activeStage = localAlpineActiveStage(for: subtitle, isDone: isDone)
        let stages = localAlpineStageTitles(for: subtitle)
        let progress = localAlpineProgress(activeStage: activeStage, total: stages.count, isDone: isDone)
        let percentText = "\(Int((progress * 100).rounded()))%"
        let elapsedText = localAlpineElapsedText(for: latest, now: localAlpineNow)
        let didFail = localAlpineDidFail(subtitle)
        let statusColor = didFail ? Color.orange : (isDone ? theme.success : theme.brandPrimary)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.brandPrimary.opacity(theme.isDark ? 0.16 : 0.10))
                        .frame(width: 34, height: 34)

                    Image(systemName: "terminal.fill")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Text(subtitle)
                        .scaledFont(size: 12, weight: .regular)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 5) {
                    localAlpineStatePill(isDone: isDone, didFail: didFail, percentText: percentText)
                    if let elapsedText {
                        Text(elapsedText)
                            .scaledFont(size: 10, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(statusColor)

                if !isDone, localAlpineLooksLongRunning(subtitle) {
                    Text("安装依赖或首次启动可能较慢，卡片会持续刷新耗时。")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 6) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    localAlpineStageChip(
                        title: stage,
                        isActive: index == activeStage && !isDone,
                        isDone: isDone || index < activeStage,
                        didFail: didFail
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.78 : 0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(theme.isDark ? 0.55 : 0.75), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.18 : 0.06), radius: 12, x: 0, y: 6)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.xs)
        .task(id: isDone) {
            guard !isDone else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                localAlpineNow = .now
            }
        }
    }

    @ViewBuilder
    private func localAlpineStatePill(isDone: Bool, didFail: Bool, percentText: String) -> some View {
        let color: Color = didFail ? .orange : (isDone ? theme.success : theme.brandPrimary)
        HStack(spacing: 5) {
            if isDone {
                Image(systemName: didFail ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .scaledFont(size: 11, weight: .semibold)
                Text(didFail ? "已结束" : "完成")
                    .scaledFont(size: 11, weight: .semibold)
            } else {
                PulsingDot(color: theme.brandPrimary)
                Text(percentText)
                    .scaledFont(size: 11, weight: .semibold)
                Text("运行中")
                    .scaledFont(size: 11, weight: .semibold)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(theme.isDark ? 0.14 : 0.10))
        )
    }

    @ViewBuilder
    private func localAlpineStageChip(title: String, isActive: Bool, isDone: Bool, didFail: Bool) -> some View {
        let doneColor: Color = didFail ? .orange : theme.success
        HStack(spacing: 4) {
            Image(systemName: isDone ? (didFail ? "exclamationmark" : "checkmark") : "circle.fill")
                .scaledFont(size: isDone ? 9 : 6, weight: .bold)
            Text(title)
                .scaledFont(size: 10, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(isDone ? doneColor : (isActive ? theme.brandPrimary : theme.textTertiary))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isDone
                    ? doneColor.opacity(theme.isDark ? 0.12 : 0.09)
                    : (isActive ? theme.brandPrimary.opacity(theme.isDark ? 0.14 : 0.10) : theme.surfaceContainerHighest.opacity(theme.isDark ? 0.35 : 0.55))
                )
        )
    }

    private func localAlpineTitle(for status: ChatStatusUpdate?) -> String {
        if status?.done == true { return "本地任务已完成" }
        let description = status?.description ?? ""
        if description.contains("依赖") && description.contains("执行") { return "正在执行命令" }
        if description.contains("依赖") { return "正在检查依赖" }
        if description.contains("软件包") || description.contains("软件源") { return "正在安装软件包" }
        return "正在执行本地任务"
    }

    private func localAlpineStageTitles(for description: String) -> [String] {
        if description.contains("软件包") || description.contains("软件源") {
            return ["准备", "检查", "安装", "执行"]
        }
        if description.contains("依赖") {
            return ["准备", "检查", "执行", "完成"]
        }
        return ["准备", "启动", "执行", "完成"]
    }

    private func localAlpineActiveStage(for description: String, isDone: Bool) -> Int {
        if isDone { return 3 }
        if description.contains("软件包") || description.contains("软件源") {
            return 2
        }
        if description.contains("依赖") && description.contains("执行") {
            return 2
        }
        if description.contains("依赖") {
            return 1
        }
        if description.contains("执行") {
            return 2
        }
        return 1
    }

    private func localAlpineProgress(activeStage: Int, total: Int, isDone: Bool) -> Double {
        if isDone { return 1 }
        guard total > 1 else { return 0.3 }
        let stageProgress = (Double(activeStage) + 0.45) / Double(total)
        let elapsedBonus: Double = {
            guard let startedAt = visibleStatuses.first(where: { $0.action?.lowercased() == "local_alpine" })?.occurredAt else {
                return 0
            }
            return min(0.12, max(0, localAlpineNow.timeIntervalSince(startedAt) / 600))
        }()
        return min(0.92, max(0.18, stageProgress + elapsedBonus))
    }

    private func localAlpineElapsedText(for status: ChatStatusUpdate?, now: Date) -> String? {
        guard let startedAt = visibleStatuses.first(where: { $0.action?.lowercased() == "local_alpine" })?.occurredAt
            ?? status?.occurredAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        if seconds < 60 { return "已运行 \(seconds) 秒" }
        return "已运行 \(seconds / 60)分\(seconds % 60)秒"
    }

    private func localAlpineLooksLongRunning(_ description: String) -> Bool {
        description.contains("依赖")
            || description.contains("安装")
            || description.contains("软件包")
            || description.contains("首次")
            || description.localizedCaseInsensitiveContains("install")
            || description.localizedCaseInsensitiveContains("package")
    }

    private func localAlpineDidFail(_ description: String) -> Bool {
        description.contains("错误")
            || description.contains("失败")
            || description.contains("取消")
            || description.contains("退出码")
            || description.localizedCaseInsensitiveContains("error")
            || description.localizedCaseInsensitiveContains("failed")
    }

    private var localAlpineActivityRow: some View {
        let latest = latestStatus
        let isDone = latest?.done == true
        let title = latest.map(resolveStatusDescription(for:))
            ?? "正在执行本地命令..."
        let didFail = localAlpineDidFail(title)
        let color: Color = didFail ? .orange : (isDone ? theme.textTertiary : theme.brandPrimary)

        return HStack(spacing: 7) {
            Image(systemName: isDone ? (didFail ? "exclamationmark.circle" : "checkmark.circle") : "terminal")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(color)

            if isDone {
                Text(title)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(didFail ? .orange : theme.textTertiary)
                    .lineLimit(1)
            } else {
                ShimmerText(text: title, theme: theme)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localAlpineAgentActivityRow: some View {
        let latest = latestStatus
        let isDone = latest?.done == true
        let title = latest.map(resolveStatusDescription(for:))
            ?? "正在整理本地结果"
        let failed = localAlpineDidFail(title)
        let color: Color = failed ? .orange : (isDone ? theme.success : theme.brandPrimary)

        return HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(color.opacity(theme.isDark ? 0.18 : 0.11))
                    .frame(width: 26, height: 26)
                Image(systemName: isDone ? (failed ? "exclamationmark" : "checkmark") : "terminal.fill")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(color)
            }

            if !isDone {
                ShimmerText(text: title, theme: theme)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(failed ? .orange : theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var statusHeader: some View {
        Button {
            withAnimation(MicroAnimation.snappy) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                // Spinning indicator or checkmark
                statusIndicator(for: latestStatus)

                // Status text
                VStack(alignment: .leading, spacing: 2) {
                    if let latest = latestStatus {
                        let title = resolveStatusDescription(for: latest)
                        if latest.done == true {
                            Text(title)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        } else {
                            ShimmerText(text: title, theme: theme)
                        }

                        // Show count if available (e.g., "Retrieved 17 sources")
                        if let count = latest.count, count > 0, latest.done == true {
                            Text("获取了 \(count) 个来源")
                                .scaledFont(size: 11, weight: .regular)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if visibleStatuses.count > 1 {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status List

    private var statusList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(visibleStatuses.enumerated()), id: \.offset) { index, status in
                if index < visibleStatuses.count - 1 {
                    statusRow(status)
                }
            }
        }
        .padding(.leading, Spacing.lg)
    }

    private func statusRow(_ status: ChatStatusUpdate) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                statusIndicator(for: status)
                    .scaleEffect(0.8)

                VStack(alignment: .leading, spacing: 0) {
                    let title = resolveStatusDescription(for: status)
                    if status.done == true {
                        Text(title)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .strikethrough(true)
                    } else {
                        ShimmerText(text: title, theme: theme)
                    }

                    // Show URLs if present
                    if !status.urls.isEmpty {
                        ForEach(status.urls, id: \.self) { url in
                            Text(url)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            // Show rich items if present (e.g. location results with title + link)
            if !status.items.isEmpty {
                itemsSection(status.items)
            }
        }
    }

    // MARK: - Items Section

    @ViewBuilder
    private func itemsSection(_ items: [ChatStatusItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let title = item.title {
                    if let urlString = item.link, let url = URL(string: urlString) {
                        Button {
                            NotificationCenter.default.post(
                                name: .markdownLinkTapped,
                                object: nil,
                                userInfo: ["url": url]
                            )
                        } label: {
                            itemRow(title: title, hasLink: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        itemRow(title: title, hasLink: false)
                    }
                }
            }
        }
        .padding(.leading, Spacing.sm)
    }

    private func itemRow(title: String, hasLink: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.circle.fill")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(theme.brandPrimary.opacity(0.8))

            Text(title)
                .scaledFont(size: 12, weight: .regular)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasLink {
                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary.opacity(0.7))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.4 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Queries Section

    @ViewBuilder
    private func queriesSection(_ status: ChatStatusUpdate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(status.queries.enumerated()), id: \.offset) { _, query in
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                    Text(query)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
                )
            }
        }
        .padding(.leading, Spacing.lg)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private func statusIndicator(for status: ChatStatusUpdate?) -> some View {
        if let status, status.done == true {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 14)
                .foregroundStyle(theme.success)
                .transition(.scale.combined(with: .opacity))
        } else if isStreaming {
            PulsingDot(color: theme.brandPrimary)
        } else {
            // Streaming ended but status not marked done — show static dot
            Circle()
                .fill(theme.textTertiary)
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - Status Resolution

    private func resolveStatusDescription(for status: ChatStatusUpdate) -> String {
        let action = status.action ?? ""
        let desc = status.description
        let isDone = status.done == true

        switch action.lowercased() {
        case "web_search", "websearch", "web search", "local_alpine_web_search", "browser_web_search":
            let localAlpine = action.lowercased() == "local_alpine_web_search"
            let browser = action.lowercased() == "browser_web_search"
            if isDone {
                if let count = status.count, count > 0 {
                    if browser { return "内置浏览器已读取 \(count) 个网页" }
                    return localAlpine ? "本地已读取 \(count) 个网页" : "已搜索 \(count) 个网页"
                }
                return desc ?? (browser ? "内置浏览器搜索完成" : (localAlpine ? "本地搜索完成" : "已完成联网搜索"))
            }
            if let query = status.query, !query.isEmpty {
                return browser ? "内置浏览器搜索：\(query)" : (localAlpine ? "本地搜索：\(query)" : "正在搜索：\(query)")
            }
            if !status.queries.isEmpty {
                return browser ? "内置浏览器搜索中" : (localAlpine ? "本地搜索中" : "正在搜索")
            }
            return desc ?? (browser ? "内置浏览器搜索中" : (localAlpine ? "本地搜索中" : "正在联网搜索"))

        case "generate_image", "image_generation", "generateimage":
            if isDone { return desc ?? "Image generated" }
            return desc ?? "Generating image…"

        case "code_interpreter", "codeinterpreter", "code interpreter":
            if isDone { return desc ?? "Code executed" }
            return desc ?? "Running code…"

        case "tool_call", "execute_tool":
            return desc ?? (isDone ? "Tool completed" : "Executing tool…")

        case "local_alpine_agent":
            if isDone { return desc ?? "已整理本地结果" }
            return desc ?? "正在检查结果并决定下一步..."

        case "memory", "memory_search":
            if isDone { return desc ?? "Memory retrieved" }
            return desc ?? "Searching memory…"

        case "knowledge", "knowledge_search", "rag":
            if isDone {
                if let count = status.count, count > 0 {
                    return "获取了 \(count) 个来源"
                }
                return desc ?? "已查询知识库"
            }
            return desc ?? "正在查询知识库..."

        case "reconnecting":
            return desc ?? "Reconnecting…"

        default:
            // Fall back to server description or formatted action name
            if let desc, !desc.isEmpty { return desc }
            if !action.isEmpty { return formatActionName(action) }
            return "Processing…"
        }
    }

    private func formatActionName(_ action: String) -> String {
        // Convert snake_case or camelCase to readable format
        let cleaned = action
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "([a-z])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )

        // Capitalize first letter
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    let color: Color
    @State private var opacity: Double = 0.3

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true)
                ) {
                    opacity = 1.0
                }
            }
    }
}

// MARK: - Shimmer Text

private struct ShimmerText: View {
    let text: String
    let theme: AppTheme
    @State private var shimmerPhase: CGFloat = -1.0

    var body: some View {
        Text(text)
            .scaledFont(size: 12, weight: .medium)
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            .clear,
                            theme.brandPrimary.opacity(0.35),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: shimmerPhase * geo.size.width)
                    .blendMode(.sourceAtop)
                }
                .mask {
                    Text(text)
                        .scaledFont(size: 12, weight: .medium)
                        .lineLimit(1)
                }
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 1.8)
                    .repeatForever(autoreverses: false)
                ) {
                    shimmerPhase = 1.2
                }
            }
    }
}

// MARK: - Tool Call Status Badge

/// A compact badge showing that a tool is being called during streaming.
///
/// Displayed inline within the message content to show real-time tool usage.
struct ToolCallBadge: View {
    let action: String
    let isDone: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.success)
            } else {
                PulsingDot(color: theme.brandPrimary)
            }

            Text(action)
                .scaledFont(size: 12, weight: .medium)
                .fontWeight(.medium)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
        )
    }
}

// MARK: - Preview

#Preview("Streaming Status") {
    VStack(spacing: Spacing.md) {
        StreamingStatusView(
            statusHistory: [
                ChatStatusUpdate(
                    action: "web_search",
                    description: "Searching for 'SwiftUI tools menu'",
                    done: true,
                    urls: ["https://developer.apple.com"]
                ),
                ChatStatusUpdate(
                    action: "code_interpreter",
                    description: "Running code snippet",
                    done: false
                ),
            ],
            isStreaming: true
        )

        Divider()

        ToolCallBadge(action: "Web Search", isDone: false)
        ToolCallBadge(action: "Code Interpreter", isDone: true)
    }
    .padding()
    .themed()
}
