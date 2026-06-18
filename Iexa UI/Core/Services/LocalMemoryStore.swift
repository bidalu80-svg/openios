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
        let memories = await loadAll(serverURL: serverURL)
            .sorted { $0.updatedAt > $1.updatedAt }
        exportFilesystemMirror(memories: memories)
        return memories
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

    func exportToLocalAlpineFileSystem(serverURL: String) async {
        let memories = await loadAll(serverURL: serverURL)
            .sorted { $0.updatedAt > $1.updatedAt }
        exportFilesystemMirror(memories: memories)
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
            exportFilesystemMirror(memories: memories)
        } catch {
            logger.error("Failed to save local memories: \(error.localizedDescription)")
        }
    }

    private func exportFilesystemMirror(memories: [LocalMemory]) {
        do {
            let directory = try Self.localAlpineMemoryDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try ensureGlobalMemoryDocument(in: directory)
            try writeDailyMemoryDocuments(memories: memories, in: directory)
        } catch {
            logger.error("Failed to mirror local memories into Local Alpine files: \(error.localizedDescription)")
        }
    }

    private func ensureGlobalMemoryDocument(in directory: URL) throws {
        let globalURL = directory.appendingPathComponent("GLOBAL.md")
        guard !fileManager.fileExists(atPath: globalURL.path) else { return }
        try """
        # Global Memory

        User-maintained persistent memory for Local Alpine. The app does not overwrite this file during memory sync.
        """.write(to: globalURL, atomically: true, encoding: .utf8)
    }

    private func writeDailyMemoryDocuments(memories: [LocalMemory], in directory: URL) throws {
        let generatedPrefix = "20"
        let existing = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in existing ?? [] where url.lastPathComponent.hasPrefix(generatedPrefix) && url.pathExtension == "md" {
            try? fileManager.removeItem(at: url)
        }

        let grouped = Dictionary(grouping: memories) { memory in
            Self.dayString(from: memory.updatedAt)
        }
        for day in grouped.keys.sorted() {
            let entries = grouped[day, default: []].sorted { $0.updatedAt > $1.updatedAt }
            try dailyMemoryDocument(day: day, memories: entries).write(
                to: directory.appendingPathComponent("\(day).md"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func dailyMemoryDocument(day: String, memories: [LocalMemory]) -> String {
        let body = memories.map { memory in
            """
            - [\(Self.iso8601String(from: memory.updatedAt))] \(memory.content.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }.joined(separator: "\n")
        return """
        # Memory \(day)

        \(body.isEmpty ? "_No memories._" : body)
        """
    }

    private func storeURL(for serverURL: String) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("Iexa/LocalMemories", isDirectory: true)
        return directory.appendingPathComponent(safeFilename(for: serverURL) + ".json")
    }

    private static func localAlpineMemoryDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return documents
            .appendingPathComponent("Iexa Alpine", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
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

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
