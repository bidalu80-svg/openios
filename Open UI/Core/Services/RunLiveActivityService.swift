import ActivityKit
import Foundation

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

@MainActor
final class RunLiveActivityService {
    static let shared = RunLiveActivityService()

    private var activity: Activity<IexaRunActivityAttributes>?
    private var activeRunId: String?
    private var startedAt = Date()
    private var lastUpdateAt = Date.distantPast
    private var lastState: IexaRunActivityAttributes.ContentState?

    private init() {}

    func start(
        id: String,
        kind: String,
        model: String,
        title: String,
        detail: String,
        phase: String = "准备",
        progress: Double = 0.08,
        isIndeterminate: Bool = true
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let activity, activeRunId != id {
            let endingState = lastState ?? makeState(
                title: "Iexa",
                detail: "已切换到新任务",
                phase: "结束",
                progress: 0.98,
                isIndeterminate: false
            )
            await activity.end(
                ActivityContent(state: endingState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            self.activity = nil
        }

        activeRunId = id
        startedAt = Date()
        lastUpdateAt = .distantPast

        let state = makeState(
            title: title,
            detail: detail,
            phase: phase,
            progress: progress,
            isIndeterminate: isIndeterminate
        )
        lastState = state

        do {
            let attributes = IexaRunActivityAttributes(
                runId: id,
                kind: kind,
                model: model
            )
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)),
                pushType: nil
            )
        } catch {
            activity = nil
            activeRunId = nil
        }
    }

    func update(
        id: String,
        title: String? = nil,
        detail: String? = nil,
        phase: String? = nil,
        progress: Double? = nil,
        isIndeterminate: Bool? = nil,
        force: Bool = false
    ) async {
        guard activeRunId == id, let activity else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastUpdateAt) < 1.2 { return }
        lastUpdateAt = now

        let previous = lastState ?? makeState(
            title: "Iexa 正在运行",
            detail: "任务进行中",
            phase: "运行中",
            progress: 0.2,
            isIndeterminate: true
        )
        let state = IexaRunActivityAttributes.ContentState(
            title: trimmed(title ?? previous.title, max: 24),
            detail: trimmed(detail ?? previous.detail, max: 46),
            phase: trimmed(phase ?? previous.phase, max: 12),
            progress: clamped(progress ?? previous.progress),
            isIndeterminate: isIndeterminate ?? previous.isIndeterminate,
            startedAt: startedAt
        )
        lastState = state
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)))
    }

    func finish(id: String, success: Bool, detail: String) async {
        guard activeRunId == id else { return }
        await finishCurrent(success: success, detail: detail)
    }

    func finishCurrent(success: Bool, detail: String) async {
        guard let activity else { return }
        let previous = lastState ?? makeState(
            title: "Iexa",
            detail: detail,
            phase: success ? "完成" : "结束",
            progress: success ? 1 : 0.98,
            isIndeterminate: false
        )
        let state = IexaRunActivityAttributes.ContentState(
            title: previous.title,
            detail: trimmed(detail, max: 46),
            phase: success ? "完成" : "结束",
            progress: success ? 1 : 0.98,
            isIndeterminate: false,
            startedAt: startedAt
        )

        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(8))
        )
        self.activity = nil
        activeRunId = nil
        lastState = nil
    }

    private func makeState(
        title: String,
        detail: String,
        phase: String,
        progress: Double,
        isIndeterminate: Bool
    ) -> IexaRunActivityAttributes.ContentState {
        IexaRunActivityAttributes.ContentState(
            title: trimmed(title, max: 24),
            detail: trimmed(detail, max: 46),
            phase: trimmed(phase, max: 12),
            progress: clamped(progress),
            isIndeterminate: isIndeterminate,
            startedAt: startedAt
        )
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func trimmed(_ value: String, max limit: Int) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "任务进行中" }
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit - 1)) + "…"
    }
}
