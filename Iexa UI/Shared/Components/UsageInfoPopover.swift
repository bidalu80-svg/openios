import Charts
import SwiftUI

// MARK: - Usage Info Popover

/// A compact, native-feel popover showing token usage statistics.
///
/// Uses `.ultraThinMaterial` for a frosted-glass iOS 18 look and
/// presents as a true popover bubble (never a full-screen sheet)
/// via `.presentationCompactAdaptation(.popover)` at the call site.
struct UsageInfoPopover: View {
    let usage: [String: Any]

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rowsContent
        }
        .frame(minWidth: 260, maxWidth: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "chart.bar.xaxis.ascending.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.brandPrimary)
            }
            Text("Token 使用量")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Rows

    private var rowsContent: some View {
        let rows = flattenUsage(usage, indent: 0)
        return VStack(alignment: .leading, spacing: 0) {
            // Thin separator under header
            Divider()
                .padding(.horizontal, 0)
                .opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        if row.isHeader {
                            sectionHeaderRow(row)
                        } else {
                            valueRow(row, isLast: idx == rows.count - 1)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 320)
            .scrollIndicators(.hidden)
        }
    }

    /// Section header row (e.g. "Completion Tokens Details")
    private func sectionHeaderRow(_ row: UsageRow) -> some View {
        Text(row.label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.textTertiary)
            .kerning(0.5)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    /// A single key / value row
    private func valueRow(_ row: UsageRow, isLast: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if row.indent > 0 {
                // Indent accent bar for nested rows
                Capsule()
                    .fill(theme.brandPrimary.opacity(0.25))
                    .frame(width: 2.5, height: 14)
                    .padding(.leading, 16)
            }

            Text(row.label)
                .font(.system(size: row.indent == 0 ? 13.5 : 12.5))
                .foregroundStyle(row.indent == 0 ? theme.textSecondary : theme.textTertiary)
                .lineLimit(1)
                .padding(.leading, row.indent == 0 ? 16 : 5)

            Spacer(minLength: 4)

            Text(row.formattedValue)
                .font(.system(size: row.indent == 0 ? 13.5 : 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(row.indent == 0 ? theme.textPrimary : theme.textSecondary)
                .padding(.trailing, 16)
        }
        .frame(minHeight: row.indent == 0 ? 36 : 30)
        .background(
            row.indent > 0
            ? (colorScheme == .dark
               ? Color.white.opacity(0.04)
               : Color.black.opacity(0.025))
            : Color.clear
        )
        .overlay(alignment: .bottom) {
            // Hair-line divider between rows (not after last)
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, row.indent > 0 ? 32 : 16)
            }
        }
    }

    // MARK: - Data Flattening

    private func flattenUsage(_ dict: [String: Any], indent: Int) -> [UsageRow] {
        // Scalars first (sorted by key), nested dicts at the end
        let sortedKeys = dict.keys.sorted { a, b in
            let aIsNested = dict[a] is [String: Any]
            let bIsNested = dict[b] is [String: Any]
            if aIsNested != bIsNested { return !aIsNested }
            return a < b
        }

        var rows: [UsageRow] = []
        for key in sortedKeys {
            guard let value = dict[key] else { continue }
            if let nested = value as? [String: Any], !nested.isEmpty {
                rows.append(UsageRow(label: humanize(key), formattedValue: "", indent: indent, isHeader: true))
                rows += flattenUsage(nested, indent: indent + 1)
            } else {
                if isNullOrZero(value) { continue }
                rows.append(UsageRow(label: humanize(key), formattedValue: formatValue(value), indent: indent, isHeader: false))
            }
        }
        return rows
    }

    private func isNullOrZero(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let i = value as? Int, i == 0 { return true }
        return false
    }

    private func formatValue(_ value: Any) -> String {
        switch value {
        case let i as Int:
            return formatNumber(i)
        case let d as Double:
            return d == d.rounded() && abs(d) < 1_000_000
                ? formatNumber(Int(d))
                : String(format: "%.2f", d)
        case let f as Float:
            return f == f.rounded() && abs(f) < 1_000_000
                ? formatNumber(Int(f))
                : String(format: "%.2f", f)
        case let b as Bool:
            return b ? "Yes" : "No"
        case let s as String:
            return s
        default:
            return "\(value)"
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func humanize(_ key: String) -> String {
        let normalizedKey = key
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1_$2", options: .regularExpression)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        if let localized = localizedUsageLabels[normalizedKey] {
            return localized
        }
        return normalizedKey.replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: " ")
            .map { word in
                word.isEmpty ? word : (word.prefix(1).uppercased() + word.dropFirst())
            }
            .joined(separator: " ")
    }

    private var localizedUsageLabels: [String: String] {
        [
            "prompt_tokens": "输入 Token",
            "completion_tokens": "输出 Token",
            "total_tokens": "总 Token",
            "input_tokens": "输入 Token",
            "output_tokens": "输出 Token",
            "prompt_token_count": "输入 Token",
            "candidates_token_count": "输出 Token",
            "total_token_count": "总 Token",
            "thoughts_token_count": "思考 Token",
            "reasoning_tokens": "推理 Token",
            "cached_tokens": "缓存 Token",
            "audio_tokens": "音频 Token",
            "image_tokens": "图片 Token",
            "video_tokens": "视频 Token",
            "tool_tokens": "工具 Token",
            "web_search_tokens": "联网搜索 Token",
            "accepted_prediction_tokens": "接受预测 Token",
            "rejected_prediction_tokens": "拒绝预测 Token",
            "cache_read_input_tokens": "缓存读取 Token",
            "cache_creation_input_tokens": "缓存写入 Token",
            "input_cached_tokens": "输入缓存 Token",
            "prompt_cache_hit_tokens": "缓存命中 Token",
            "prompt_cache_miss_tokens": "缓存未命中 Token",
            "completion_tokens_details": "输出 Token 详情",
            "prompt_tokens_details": "输入 Token 详情",
            "input_tokens_details": "输入 Token 详情",
            "output_tokens_details": "输出 Token 详情",
            "usage": "Token 使用量",
            "cost": "费用",
            "model": "模型",
            "service_tier": "服务层级",
            "num_model_requests": "模型请求次数",
            "tokens_per_second": "每秒 Token"
        ]
    }
}

// MARK: - Usage Row Model

private struct UsageRow {
    let label: String
    let formattedValue: String
    let indent: Int
    let isHeader: Bool
}

// MARK: - Token Usage History

struct TokenUsageRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let mediaTokens: Int
    let totalTokens: Int
    let imageCount: Int
    let videoCount: Int
    let isExact: Bool

    var dayKey: String {
        Self.dayKey(for: date)
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct TokenUsageDailySummary: Identifiable, Sendable {
    let day: String
    let date: Date
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let mediaTokens: Int
    let totalTokens: Int
    let requestCount: Int

    var id: String { day }
}

struct TokenUsageModelSummary: Identifiable, Sendable {
    let provider: String
    let model: String
    let totalTokens: Int
    let requestCount: Int

    var id: String { "\(provider)/\(model)" }
    var displayName: String { model.isEmpty ? provider : model }
}

@MainActor
@Observable
final class TokenUsageHistoryStore {
    static let shared = TokenUsageHistoryStore()

    private(set) var records: [TokenUsageRecord] = []

    private let fileURL: URL
    private let retentionDays = 90

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = appSupport.appendingPathComponent("IexaUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("token-usage.json")
        load()
        pruneOldRecords()
    }

    var todaySummaryText: String {
        let today = Self.dayKey(for: Date())
        let todayRecords = records.filter { $0.dayKey == today }
        guard !todayRecords.isEmpty else { return "暂无今日数据" }
        let total = todayRecords.reduce(0) { $0 + $1.totalTokens }
        return "今日 \(Self.compactTokenCount(total)) · \(todayRecords.count) 次"
    }

    func record(
        provider: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int,
        mediaTokens: Int,
        imageCount: Int,
        videoCount: Int,
        isExact: Bool,
        usage: [String: Any]?
    ) {
        let explicitTotal = Self.firstIntValue(in: usage, keys: [
            "total_tokens", "totalTokens", "total_token_count", "totalTokenCount"
        ])
        let computedTotal = max(0, inputTokens) + max(0, outputTokens) + max(0, mediaTokens)
        let total = max(explicitTotal ?? 0, computedTotal)
        guard total > 0 else { return }

        let record = TokenUsageRecord(
            id: UUID(),
            date: Date(),
            provider: provider.isEmpty ? "unknown" : provider,
            model: model.isEmpty ? "unknown" : model,
            inputTokens: max(0, inputTokens),
            outputTokens: max(0, outputTokens),
            cachedTokens: max(0, cachedTokens),
            mediaTokens: max(0, mediaTokens),
            totalTokens: total,
            imageCount: max(0, imageCount),
            videoCount: max(0, videoCount),
            isExact: isExact
        )
        records.append(record)
        pruneOldRecords()
        save()
    }

    func clearAll() {
        records = []
        save()
    }

    func dailySummaries(days: Int) -> [TokenUsageDailySummary] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days + 1, to: Calendar.current.startOfDay(for: Date()))
            ?? Date()
        let filtered = records.filter { $0.date >= cutoff }
        let grouped = Dictionary(grouping: filtered, by: \.dayKey)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        return grouped.map { day, dayRecords in
            TokenUsageDailySummary(
                day: day,
                date: formatter.date(from: day) ?? Date(),
                inputTokens: dayRecords.reduce(0) { $0 + $1.inputTokens },
                outputTokens: dayRecords.reduce(0) { $0 + $1.outputTokens },
                cachedTokens: dayRecords.reduce(0) { $0 + $1.cachedTokens },
                mediaTokens: dayRecords.reduce(0) { $0 + $1.mediaTokens },
                totalTokens: dayRecords.reduce(0) { $0 + $1.totalTokens },
                requestCount: dayRecords.count
            )
        }
        .sorted { $0.day < $1.day }
    }

    func modelSummaries(days: Int) -> [TokenUsageModelSummary] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days + 1, to: Calendar.current.startOfDay(for: Date()))
            ?? Date()
        let filtered = records.filter { $0.date >= cutoff }
        let grouped = Dictionary(grouping: filtered) { "\($0.provider)/\($0.model)" }
        return grouped.map { _, records in
            let first = records[0]
            return TokenUsageModelSummary(
                provider: first.provider,
                model: first.model,
                totalTokens: records.reduce(0) { $0 + $1.totalTokens },
                requestCount: records.count
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([TokenUsageRecord].self, from: data) {
            records = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func pruneOldRecords() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let originalCount = records.count
        records.removeAll { $0.date < cutoff }
        if records.count != originalCount {
            save()
        }
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func compactTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private static func firstIntValue(in usage: [String: Any]?, keys: [String]) -> Int? {
        guard let usage else { return nil }
        for key in keys {
            if let value = usage[key] {
                if let intValue = value as? Int { return intValue }
                if let doubleValue = value as? Double { return Int(doubleValue) }
                if let stringValue = value as? String, let intValue = Int(stringValue) { return intValue }
                if let numberValue = value as? NSNumber { return numberValue.intValue }
            }
        }
        return nil
    }
}

private enum TokenUsageRange: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return "7 天"
        case .twoWeeks: return "14 天"
        case .month: return "30 天"
        }
    }
}

struct TokenUsageStatisticsView: View {
    @Environment(\.theme) private var theme
    @State private var store = TokenUsageHistoryStore.shared
    @State private var selectedRange: TokenUsageRange = .week
    @State private var showClearConfirmation = false

    private var summaries: [TokenUsageDailySummary] {
        store.dailySummaries(days: selectedRange.rawValue)
    }

    private var recordsInRange: [TokenUsageRecord] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -selectedRange.rawValue + 1,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
        return store.records.filter { $0.date >= cutoff }
    }

    private var totalTokens: Int {
        recordsInRange.reduce(0) { $0 + $1.totalTokens }
    }

    private var totalRequests: Int {
        recordsInRange.count
    }

    private var exactRatioText: String {
        guard totalRequests > 0 else { return "0%" }
        let exactCount = recordsInRange.filter(\.isExact).count
        return "\(Int((Double(exactCount) / Double(totalRequests) * 100).rounded()))%"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryGrid
                rangePicker
                dailyChart
                modelBreakdown
                recentRequests
                clearButton
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.md)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("用量统计")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除用量统计？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                store.clearAll()
            }
        } message: {
            Text("这只会清除本机保存的统计记录，不会删除任何聊天。")
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            metricCard(
                title: "总 Token",
                value: TokenUsageHistoryStore.compactTokenCount(totalTokens),
                icon: "number.circle.fill",
                tint: theme.brandPrimary
            )
            metricCard(
                title: "请求",
                value: "\(totalRequests)",
                icon: "arrow.up.arrow.down.circle.fill",
                tint: .cyan
            )
            metricCard(
                title: "精确记录",
                value: exactRatioText,
                icon: "checkmark.seal.fill",
                tint: theme.success
            )
        }
    }

    private var rangePicker: some View {
        Picker("范围", selection: $selectedRange) {
            ForEach(TokenUsageRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("每日 Token", icon: "chart.bar.xaxis")

            if summaries.isEmpty {
                emptyState("暂无用量数据", icon: "chart.bar.xaxis")
                    .frame(height: 220)
            } else {
                Chart {
                    ForEach(summaries) { summary in
                        BarMark(
                            x: .value("日期", summary.date, unit: .day),
                            y: .value("输入", summary.inputTokens)
                        )
                        .foregroundStyle(theme.brandPrimary.gradient)

                        BarMark(
                            x: .value("日期", summary.date, unit: .day),
                            y: .value("输出", summary.outputTokens)
                        )
                        .foregroundStyle(Color.cyan.gradient)

                        if summary.mediaTokens > 0 {
                            BarMark(
                                x: .value("日期", summary.date, unit: .day),
                                y: .value("媒体", summary.mediaTokens)
                            )
                            .foregroundStyle(Color.purple.gradient)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(theme.divider.opacity(0.5))
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text(TokenUsageHistoryStore.compactTokenCount(intValue))
                                    .scaledFont(size: 10)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 220)
            }
        }
        .usagePanel(theme: theme)
    }

    private var modelBreakdown: some View {
        let models = store.modelSummaries(days: selectedRange.rawValue)
        let maxTokens = max(models.first?.totalTokens ?? 1, 1)

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("模型占比", icon: "cpu")

            if models.isEmpty {
                emptyState("还没有模型记录", icon: "cpu")
            } else {
                ForEach(models.prefix(8)) { model in
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(for: model))
                                .frame(width: 8, height: 8)
                            Text(model.displayName)
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(TokenUsageHistoryStore.compactTokenCount(model.totalTokens))
                                .scaledFont(size: 12, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(theme.textSecondary)
                            Text("\(model.requestCount) 次")
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }

                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color(for: model).opacity(0.32))
                                .frame(width: proxy.size.width * CGFloat(model.totalTokens) / CGFloat(maxTokens))
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .usagePanel(theme: theme)
    }

    private var recentRequests: some View {
        let recent = Array(store.records.suffix(10).reversed())

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("最近请求", icon: "clock.arrow.circlepath")

            if recent.isEmpty {
                emptyState("完成一次对话后会显示在这里", icon: "bubble.left.and.text.bubble.right")
            } else {
                ForEach(recent) { record in
                    HStack(spacing: 10) {
                        Image(systemName: record.isExact ? "checkmark.circle.fill" : "questionmark.circle.fill")
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(record.isExact ? theme.success : theme.warning)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.model)
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(TokenUsageHistoryStore.compactTokenCount(record.totalTokens))
                                .scaledFont(size: 13, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(theme.textPrimary)
                            Text(record.provider)
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }

                    if record.id != recent.last?.id {
                        Divider().overlay(theme.divider.opacity(0.5))
                    }
                }
            }
        }
        .usagePanel(theme: theme)
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            showClearConfirmation = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("清除本机统计")
            }
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(theme.error)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(theme.error.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.records.isEmpty)
        .opacity(store.records.isEmpty ? 0.45 : 1)
    }

    private func metricCard(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(tint)
            Text(value)
                .scaledFont(size: 17, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Spacer()
        }
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 28, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            Text(title)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func color(for model: TokenUsageModelSummary) -> Color {
        let palette: [Color] = [theme.brandPrimary, .cyan, theme.success, .purple, .pink, .orange, .mint, .indigo]
        let index = abs(model.id.hashValue) % palette.count
        return palette[index]
    }
}

private extension View {
    func usagePanel(theme: AppTheme) -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - Preview

#Preview {
    let sampleUsage: [String: Any] = [
        "completion_tokens": 72,
        "prompt_tokens": 3107,
        "total_tokens": 3179,
        "completion_tokens_details": [
            "reasoning_tokens": 46
        ],
        "prompt_tokens_details": [
            "cached_tokens": 2048,
        ],
    ]

    VStack(spacing: 20) {
        UsageInfoPopover(usage: sampleUsage)
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 6)
    }
    .padding(40)
    .background(Color(.systemGroupedBackground))
    .themed()
}
