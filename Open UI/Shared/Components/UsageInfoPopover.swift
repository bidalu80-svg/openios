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
