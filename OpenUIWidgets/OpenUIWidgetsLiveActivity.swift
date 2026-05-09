import ActivityKit
import SwiftUI
import WidgetKit

struct IexaRunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var phase: String
        var progress: Double
        var isIndeterminate: Bool
        var startedAt: Date
    }

    var runId: String
    var kind: String
    var model: String
}

struct IexaRunLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IexaRunActivityAttributes.self) { context in
            IexaRunLockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IexaRunIslandIcon(kind: context.attributes.kind)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.phase)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.title)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IexaRunProgressBar(progress: context.state.progress, isIndeterminate: context.state.isIndeterminate)
                        .frame(height: 5)
                        .padding(.top, 2)
                }
            } compactLeading: {
                IexaRunIslandIcon(kind: context.attributes.kind, size: 18)
            } compactTrailing: {
                Text(compactProgressText(context.state.progress, isIndeterminate: context.state.isIndeterminate))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
            } minimal: {
                IexaRunIslandIcon(kind: context.attributes.kind, size: 16)
            }
        }
    }

    private func compactProgressText(_ progress: Double, isIndeterminate: Bool) -> String {
        if isIndeterminate { return "运行" }
        return "\(Int((max(0, min(progress, 1)) * 100).rounded()))%"
    }
}

private struct IexaRunLockScreenView: View {
    let context: ActivityViewContext<IexaRunActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            IexaRunIslandIcon(kind: context.attributes.kind, size: 34)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(context.state.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(context.state.phase)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }

                Text(context.state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                IexaRunProgressBar(progress: context.state.progress, isIndeterminate: context.state.isIndeterminate)
                    .frame(height: 6)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct IexaRunIslandIcon: View {
    let kind: String
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(.primary.opacity(0.08))
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .padding(size * 0.18)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: symbolName)
                .font(.system(size: max(7, size * 0.32), weight: .bold))
                .foregroundStyle(.primary)
                .padding(2)
                .background(Color(.systemBackground), in: Circle())
                .offset(x: size * 0.08, y: size * 0.08)
        }
    }

    private var symbolName: String {
        switch kind {
        case "image": return "sparkles"
        case "video": return "video.fill"
        case "terminal", "install": return "terminal.fill"
        default: return "text.bubble.fill"
        }
    }
}

private struct IexaRunProgressBar: View {
    let progress: Double
    let isIndeterminate: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.primary.opacity(0.92), .primary.opacity(0.42), .primary.opacity(0.82)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width(in: geometry.size.width))
            }
        }
    }

    private func width(in total: CGFloat) -> CGFloat {
        if isIndeterminate { return max(total * 0.42, 36) }
        return max(total * CGFloat(max(0.04, min(progress, 1))), 12)
    }
}
