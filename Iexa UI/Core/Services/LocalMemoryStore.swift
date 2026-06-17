import Foundation
import os.log

/// Persists local memories for direct API providers.
actor LocalMemoryStore {
    static let shared = LocalMemoryStore()

    private let logger = Logger(subsystem: "com.openui", category: "LocalMemoryStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func list(serverURL: String) async -> [LocalMemory] {
        await loadAll(serverURL: serverURL)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func listUpdatedSince(_ date: Date, serverURL: String) async -> [LocalMemory] {
        await loadAll(serverURL: serverURL)
            .filter { memory in
                memory.updatedAt >= date || memory.createdAt >= date
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func add(content: String, serverURL: String) async -> LocalMemory {
        var memories = await loadAll(serverURL: serverURL)
        let memory = LocalMemory(content: content)
        memories.insert(memory, at: 0)
        await saveAll(memories, serverURL: serverURL)
        return memory
    }

    @discardableResult
    func addIfAbsent(content: String, serverURL: String) async -> LocalMemory {
        let normalizedContent = Self.normalized(content)
        var memories = await loadAll(serverURL: serverURL)
        if let existing = memories.first(where: { Self.normalized($0.content) == normalizedContent }) {
            return existing
        }
        let memory = LocalMemory(content: content)
        memories.insert(memory, at: 0)
        await saveAll(memories, serverURL: serverURL)
        return memory
    }

    func update(id: String, content: String, serverURL: String) async -> LocalMemory? {
        var memories = await loadAll(serverURL: serverURL)
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return nil }
        memories[index].content = content
        memories[index].updatedAt = .now
        await saveAll(memories, serverURL: serverURL)
        return memories[index]
    }

    func delete(id: String, serverURL: String) async {
        var memories = await loadAll(serverURL: serverURL)
        memories.removeAll { $0.id == id }
        await saveAll(memories, serverURL: serverURL)
    }

    func deleteAll(serverURL: String) async {
        await saveAll([], serverURL: serverURL)
    }

    func isEnabled(serverURL: String) async -> Bool {
        let key = enabledKey(for: serverURL)
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    func setEnabled(_ enabled: Bool, serverURL: String) async {
        UserDefaults.standard.set(enabled, forKey: enabledKey(for: serverURL))
    }

    private func loadAll(serverURL: String) async -> [LocalMemory] {
        let url = storeURL(for: serverURL)
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try decoder.decode([LocalMemory].self, from: data)
        } catch {
            logger.error("Failed to decode local memories: \(error.localizedDescription)")
            return []
        }
    }

    private func saveAll(_ memories: [LocalMemory], serverURL: String) async {
        let url = storeURL(for: serverURL)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(memories.sorted { $0.updatedAt > $1.updatedAt })
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save local memories: \(error.localizedDescription)")
        }
    }

    private func storeURL(for serverURL: String) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("Iexa/LocalMemories", isDirectory: true)
        return directory.appendingPathComponent(safeFilename(for: serverURL) + ".json")
    }

    private func enabledKey(for serverURL: String) -> String {
        "local.memory.enabled.\(safeFilename(for: serverURL))"
    }

    private func safeFilename(for value: String) -> String {
        let data = Data(value.utf8)
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func normalized(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
}
