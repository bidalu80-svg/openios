import Foundation

struct LocalAlpineEnvironmentVariable: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let key: String
    var note: String
    let createdAt: Date
}

enum LocalAlpineEnvironmentStoreError: LocalizedError {
    case invalidKey
    case duplicateKey
    case secureStorageFailed

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            "名称必须以字母开头，只能使用字母、数字、下划线。"
        case .duplicateKey:
            "同名变量已存在。"
        case .secureStorageFailed:
            "无法安全保存环境变量值。"
        }
    }
}

final class LocalAlpineEnvironmentStore: @unchecked Sendable {
    static let shared = LocalAlpineEnvironmentStore()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let metadataDefaultsKey = "local_alpine_environment_variables"
    private let privacyDefaultsKey = "local_alpine_environment_privacy_mode"
    private let keychainAccountPrefix = "local-alpine-environment-variable:"
    private var storedVariables: [LocalAlpineEnvironmentVariable]
    private var storedPrivacyMode: Bool

    private init() {
        if let data = defaults.data(forKey: metadataDefaultsKey),
           let decoded = try? JSONDecoder().decode([LocalAlpineEnvironmentVariable].self, from: data) {
            storedVariables = decoded.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        } else {
            storedVariables = []
        }
        if defaults.object(forKey: privacyDefaultsKey) == nil {
            storedPrivacyMode = true
            defaults.set(true, forKey: privacyDefaultsKey)
        } else {
            storedPrivacyMode = defaults.bool(forKey: privacyDefaultsKey)
        }
    }

    var variables: [LocalAlpineEnvironmentVariable] {
        lock.lock()
        defer { lock.unlock() }
        return storedVariables
    }

    var privacyMode: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPrivacyMode
        }
        set {
            lock.lock()
            storedPrivacyMode = newValue
            defaults.set(newValue, forKey: privacyDefaultsKey)
            lock.unlock()
        }
    }

    func value(for variable: LocalAlpineEnvironmentVariable) -> String? {
        KeychainService.shared.secret(forAccount: keychainAccount(for: variable.id))
    }

    func save(
        id: String? = nil,
        key rawKey: String,
        value: String,
        note rawNote: String
    ) throws {
        let key = try normalizedKey(rawKey)
        let note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let variableId = id ?? UUID().uuidString

        lock.lock()
        let hasDuplicate = storedVariables.contains { variable in
            variable.id != variableId && variable.key.caseInsensitiveCompare(key) == .orderedSame
        }
        lock.unlock()
        guard !hasDuplicate else { throw LocalAlpineEnvironmentStoreError.duplicateKey }
        guard KeychainService.shared.saveSecret(value, account: keychainAccount(for: variableId)) else {
            throw LocalAlpineEnvironmentStoreError.secureStorageFailed
        }

        lock.lock()
        if let index = storedVariables.firstIndex(where: { $0.id == variableId }) {
            let original = storedVariables[index]
            storedVariables[index] = LocalAlpineEnvironmentVariable(
                id: variableId,
                key: key,
                note: note,
                createdAt: original.createdAt
            )
        } else {
            storedVariables.append(
                LocalAlpineEnvironmentVariable(id: variableId, key: key, note: note, createdAt: .now)
            )
        }
        storedVariables.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        persistMetadataLocked()
        lock.unlock()
    }

    func delete(_ variable: LocalAlpineEnvironmentVariable) {
        _ = KeychainService.shared.deleteSecret(forAccount: keychainAccount(for: variable.id))
        lock.lock()
        storedVariables.removeAll { $0.id == variable.id }
        persistMetadataLocked()
        lock.unlock()
    }

    func shellExportScript() -> String {
        let snapshot = variables
        let lines = snapshot.compactMap { variable -> String? in
            guard let value = value(for: variable) else { return nil }
            return "export \(variable.key)='\(shellSingleQuoted(value))'"
        }
        return lines.joined(separator: "\n")
    }

    func redactedForModel(_ text: String) -> String {
        guard privacyMode, !text.isEmpty else { return text }
        let values = variables.compactMap { variable -> String? in
            guard let value = value(for: variable), !value.isEmpty else { return nil }
            return value
        }
        let uniqueValues = Set(values).sorted { $0.count > $1.count }
        return uniqueValues.reduce(text) { result, value in
            result.replacingOccurrences(of: value, with: masked(value))
        }
    }

    func modelVisibleSummary() -> String {
        let snapshot = variables
        guard !snapshot.isEmpty else {
            return "未配置用户环境变量。"
        }
        return snapshot.map { variable in
            let note = variable.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? "- \(variable.key)" : "- \(variable.key)：\(note)"
        }.joined(separator: "\n")
    }

    static func normalizedKey(_ rawKey: String) throws -> String {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard key.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil else {
            throw LocalAlpineEnvironmentStoreError.invalidKey
        }
        return key
    }

    private func keychainAccount(for id: String) -> String {
        "\(keychainAccountPrefix)\(id)"
    }

    private func persistMetadataLocked() {
        guard let data = try? JSONEncoder().encode(storedVariables) else { return }
        defaults.set(data, forKey: metadataDefaultsKey)
    }

    private func shellSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\\\''")
    }

    private func masked(_ value: String) -> String {
        guard value.count >= 8 else {
            return String(repeating: "*", count: max(1, value.count))
        }
        let leading = String(value.prefix(4))
        let trailing = String(value.suffix(4))
        return leading + String(repeating: "*", count: max(1, value.count - 8)) + trailing
    }
}
