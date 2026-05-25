import Foundation

struct LocalSkill: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    var content: String
    var isEnabled: Bool
    var isBuiltin: Bool
    var updatedAt: Date
}

@MainActor
@Observable
final class LocalSkillsService {
    static let shared = LocalSkillsService()

    private let storageKey = "iexa.local.skills.v1"

    private(set) var skills: [LocalSkill] = []

    private init() {
        load()
    }

    var enabledSkills: [LocalSkill] {
        skills.filter(\.isEnabled)
    }

    func load() {
        var decoded: [LocalSkill] = []
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([LocalSkill].self, from: data) {
            decoded = stored
        }
        skills = Self.mergeBuiltinSkills(into: decoded)
        save()
    }

    func toggle(_ skill: LocalSkill) {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[index].isEnabled.toggle()
        skills[index].updatedAt = Date()
        save()
    }

    func upsert(_ skill: LocalSkill) {
        var next = skill
        next.updatedAt = Date()
        if let index = skills.firstIndex(where: { $0.id == next.id }) {
            let isBuiltin = skills[index].isBuiltin
            next.isBuiltin = isBuiltin
            skills[index] = next
        } else {
            next.isBuiltin = false
            skills.append(next)
        }
        save()
    }

    func delete(_ skill: LocalSkill) {
        guard !skill.isBuiltin else { return }
        skills.removeAll { $0.id == skill.id }
        save()
    }

    func resetBuiltin(_ skill: LocalSkill) {
        guard skill.isBuiltin,
              let builtin = Self.builtinSkills.first(where: { $0.id == skill.id }),
              let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        let wasEnabled = skills[index].isEnabled
        var next = builtin
        next.isEnabled = wasEnabled
        next.updatedAt = Date()
        skills[index] = next
        save()
    }

    func contextPrompt() -> String? {
        let enabled = enabledSkills
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(6)
        guard !enabled.isEmpty else { return nil }
        let blocks = enabled.map { skill in
            """
            ## \((skill.name))
            \((skill.content.trimmingCharacters(in: .whitespacesAndNewlines)))
            """
        }
        return """

        [本地技能]
        以下技能由用户在 Iexa 设置里本地启用。它们是本轮可用的额外工作指南；当用户请求和某个技能相关时，请按该技能执行。不要声称需要服务器技能接口。

        \(blocks.joined(separator: "\n\n"))
        [/本地技能]
        """
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func mergeBuiltinSkills(into stored: [LocalSkill]) -> [LocalSkill] {
        var result = stored
        for builtin in builtinSkills where !result.contains(where: { $0.id == builtin.id }) {
            result.insert(builtin, at: 0)
        }
        return result
    }

    private static let builtinSkills: [LocalSkill] = [
        LocalSkill(
            id: "skill-creator",
            name: "skill-creator",
            description: "创建或更新可复用本地技能的指南。",
            content: """
            # Skill Creator

            当用户想创建或更新技能时使用本技能。

            技能应该是简短、可复用、可触发的工作指南，适合保存某类任务的固定流程、注意事项、工具用法或项目规则。

            创建技能时请包含：
            - 名称：短、稳定、可搜索。
            - 描述：说明什么时候应该使用这个技能。
            - 内容：只写真正影响执行质量的步骤、约束和检查方式。

            编写原则：
            - 保持简洁，避免把常识塞进技能。
            - 对容易出错的流程给明确步骤。
            - 对可变任务保留判断空间。
            - 如果技能会让模型写代码，必须要求验证和错误修复。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        )
    ]
}
