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
        decoded = Self.mergedFileSystemSkills(into: decoded)
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

    func exportToLocalAlpineFileSystem() {
        exportSkillsToLocalAlpineFileSystem()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        exportSkillsToLocalAlpineFileSystem()
    }

    private func exportSkillsToLocalAlpineFileSystem() {
        do {
            let directory = try Self.localAlpineSkillsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try removeStaleGeneratedSkillDirectories(in: directory)

            for skill in skills {
                let folderName = Self.safePathComponent(skill.id, fallback: "skill")
                let folderURL = directory.appendingPathComponent(folderName, isDirectory: true)
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                try markdownDocument(for: skill).write(
                    to: folderURL.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                try markerDocument(for: skill).write(
                    to: folderURL.appendingPathComponent(".iexa-skill.json"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            // The runtime can still use UserDefaults-backed skills if the file mirror fails.
        }
    }

    private func removeStaleGeneratedSkillDirectories(in directory: URL) throws {
        let activeFolderNames = Set(skills.map { Self.safePathComponent($0.id, fallback: "skill") })
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            guard !activeFolderNames.contains(child.lastPathComponent),
                  FileManager.default.fileExists(
                    atPath: child.appendingPathComponent(".iexa-skill.json").path
                  ) else {
                continue
            }
            try FileManager.default.removeItem(at: child)
        }
    }

    private func markdownDocument(for skill: LocalSkill) -> String {
        let content = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        id: \(Self.yamlScalar(skill.id))
        name: \(Self.yamlScalar(skill.name))
        description: \(Self.yamlScalar(skill.description))
        enabled: \(skill.isEnabled ? "true" : "false")
        builtin: \(skill.isBuiltin ? "true" : "false")
        updated_at: \(Self.iso8601String(from: skill.updatedAt))
        ---

        \(content)
        """
    }

    private func markerDocument(for skill: LocalSkill) -> String {
        """
        {"id":"\(Self.jsonEscaped(skill.id))","generated_by":"iexa","file":"SKILL.md"}
        """
    }

    private static func localAlpineSkillsDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return documents
            .appendingPathComponent("Iexa Alpine", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private static func mergedFileSystemSkills(into stored: [LocalSkill]) -> [LocalSkill] {
        guard let directory = try? localAlpineSkillsDirectory(),
              let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return stored
        }

        var merged = stored
        for folderURL in children {
            guard isDirectory(folderURL) else {
                continue
            }
            let skillURL = folderURL.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skillURL, encoding: .utf8),
                  let imported = localSkill(fromMarkdown: text, fallbackId: folderURL.lastPathComponent) else {
                continue
            }
            if let index = merged.firstIndex(where: { $0.id == imported.id }) {
                guard !merged[index].isBuiltin,
                      imported.updatedAt > merged[index].updatedAt else {
                    continue
                }
                merged[index] = imported
            } else {
                merged.append(imported)
            }
        }
        return merged
    }

    private static func localSkill(fromMarkdown text: String, fallbackId: String) -> LocalSkill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let (metadata, body) = splitFrontmatter(from: normalized)
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        let rawId = metadata["id"] ?? fallbackId
        let id = safePathComponent(rawId, fallback: "skill")
        let name = (metadata["name"] ?? firstMarkdownHeading(in: content) ?? id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty else { return nil }

        let metadataDate = dateValue(metadata["updated_at"])
        let modifiedDate = fileModificationDate(for: fallbackId)
        let updatedAt = [metadataDate, modifiedDate].compactMap { $0 }.max() ?? Date()

        return LocalSkill(
            id: id,
            name: name,
            description: (metadata["description"] ?? firstPlainParagraph(in: content) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            content: content,
            isEnabled: boolValue(metadata["enabled"]) ?? true,
            isBuiltin: false,
            updatedAt: updatedAt
        )
    }

    private static func splitFrontmatter(from text: String) -> ([String: String], String) {
        guard text.hasPrefix("---\n"),
              let endRange = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return ([:], text)
        }
        let frontmatter = String(text[text.index(text.startIndex, offsetBy: 4)..<endRange.lowerBound])
        let bodyStart = text.index(endRange.upperBound, offsetBy: text[endRange.upperBound...].hasPrefix("\n") ? 1 : 0)
        var metadata: [String: String] = [:]
        for line in frontmatter.components(separatedBy: "\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                metadata[key] = unquotedScalar(value)
            }
        }
        return (metadata, String(text[bodyStart...]))
    }

    private static func unquotedScalar(_ value: String) -> String {
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\"" else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func firstMarkdownHeading(in text: String) -> String? {
        text.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { return nil }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }.first { !$0.isEmpty }
    }

    private static func firstPlainParagraph(in text: String) -> String? {
        for paragraph in text.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return trimmed.count > 160 ? String(trimmed.prefix(160)) : trimmed
        }
        return nil
    }

    private static func boolValue(_ value: String?) -> Bool? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1", "enabled": return true
        case "false", "no", "0", "disabled": return false
        default: return nil
        }
    }

    private static func dateValue(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func fileModificationDate(for folderName: String) -> Date? {
        guard let directory = try? localAlpineSkillsDirectory() else { return nil }
        let url = directory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return false
        }
        return values.isDirectory == true
    }

    private static func safePathComponent(_ value: String, fallback: String) -> String {
        var result = ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.append(Character(scalar))
            } else if result.last != "-" {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(80))
    }

    private static func yamlScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
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
        ),
        LocalSkill(
            id: "translator",
            name: "翻译助手",
            description: "自然、地道地翻译中英文或其他语言文本。",
            content: """
            # 翻译助手

            当用户要求翻译、改写成另一种语言、解释外语含义时使用本技能。

            执行方式：
            - 自动判断源语言；如果用户没有指定目标语言，默认在中文和英文之间互译。
            - 保留原文语气、格式、专有名词和技术术语。
            - 优先给自然地道的译文，不做生硬逐词翻译。
            - 如果原文有歧义，先给最可能译法，再用一句话说明其他可能含义。
            - 用户只要译文时，只输出译文。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        ),
        LocalSkill(
            id: "summarizer",
            name: "总结提炼",
            description: "把长文本、网页内容或对话整理成清晰要点。",
            content: """
            # 总结提炼

            当用户要求总结、TLDR、提炼重点、整理长文本或网页内容时使用本技能。

            执行方式：
            - 先判断用户要的是短摘要、结构化要点、行动项还是详细梳理。
            - 保留关键数字、人名、日期、结论和限制条件。
            - 默认输出：一句话概览 + 3 到 7 条要点。
            - 内容很长时按主题分组，避免机械复述。
            - 如果用户提供链接且当前聊天已启用联网或网页能力，先获取网页内容再总结；无法访问时说明限制。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        ),
        LocalSkill(
            id: "writing-coach",
            name: "写作润色",
            description: "润色、校对、改写和调整文本语气。",
            content: """
            # 写作润色

            当用户要求润色、改写、校对、扩写、缩写、调整语气或让文字更专业时使用本技能。

            执行方式：
            - 先识别目标：纠错、润色、改写、压缩、扩写或改语气。
            - 保留原意，不擅自新增事实。
            - 根据场景调整语气：正式、自然、口语、商务、学术或社媒。
            - 默认直接给修改后的版本；必要时再用简短说明列出关键改动。
            - 中文文本避免翻译腔，英文文本注意清晰、自然和节奏。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        ),
        LocalSkill(
            id: "code-helper",
            name: "代码助手",
            description: "解释代码、定位问题、生成实现和给出验证步骤。",
            content: """
            # 代码助手

            当用户询问编程、调试、代码解释、实现方案、报错排查时使用本技能。

            执行方式：
            - 先明确语言、框架、运行环境和用户真正要解决的问题。
            - 修 bug 时说明原因、影响范围和最小修改方案。
            - 写代码时贴近现有风格，避免无关重构。
            - 能验证时给出具体测试或运行命令；无法验证时说明原因。
            - 回答保持聚焦，不把显而易见的代码逐行复述。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        ),
        LocalSkill(
            id: "math-solver",
            name: "数学求解",
            description: "分步骤解决计算、代数、几何和应用题。",
            content: """
            # 数学求解

            当用户要求计算、解题、推导公式、检查答案或解释数学概念时使用本技能。

            执行方式：
            - 先写出已知条件和要求解的量。
            - 分步骤推导，每一步说明为什么这样做。
            - 对复杂计算使用清晰公式，并在最后代入数值。
            - 给出最终答案和单位；必要时说明近似误差。
            - 如果题目条件不足，指出缺失条件并给出可继续的假设。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        ),
        LocalSkill(
            id: "research-assistant",
            name: "研究助手",
            description: "围绕一个问题搜索、比较、整理和引用信息。",
            content: """
            # 研究助手

            当用户要求研究某个主题、查资料、比较方案、找最新信息或做背景调查时使用本技能。

            执行方式：
            - 先拆出研究问题、范围、时间敏感性和判断标准。
            - 如果问题需要最新信息，明确需要联网搜索；可以使用当前聊天可用的联网搜索能力。
            - 交叉比较多个来源，不把单一来源当成结论。
            - 区分事实、推断和观点；不确定处标注不确定。
            - 输出结构化结论，并在可用时附来源链接。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        ),
        LocalSkill(
            id: "travel-planner",
            name: "旅行规划",
            description: "规划行程、预算、路线、天气和本地建议。",
            content: """
            # 旅行规划

            当用户要求旅行计划、路线安排、景点推荐、预算建议或出行清单时使用本技能。

            执行方式：
            - 先确认目的地、日期、人数、预算、兴趣和节奏；信息不足时用合理假设并说明。
            - 按天组织行程，给出交通、时间估计和备选方案。
            - 涉及天气、营业时间、签证、交通管制等易变信息时提醒需要实时确认。
            - 给出实用清单：住宿区域、交通方式、餐饮、避坑和应急安排。
            - 不堆砌景点，优先让路线顺、体验舒服。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        ),
        LocalSkill(
            id: "chat-summarizer",
            name: "对话总结",
            description: "把当前聊天整理成可分享的 Markdown 摘要。",
            content: """
            # 对话总结

            当用户要求总结本次聊天、回顾讨论、生成会议纪要或整理成文章时使用本技能。

            执行方式：
            - 只基于当前对话中已经出现的信息，不编造缺失事实。
            - 默认使用 Markdown 输出：标题、概览、关键主题、已完成事项、待办事项。
            - 重要代码、命令、日期、文件名和决策要保留。
            - 和用户使用同一种语言。
            - 如果用户要求可分享版本，减少闲聊痕迹，整理成清晰文章或纪要。
            """,
            isEnabled: true,
            isBuiltin: true,
            updatedAt: Date()
        )
    ]
}
