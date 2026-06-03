import Foundation
import os.log

struct DiagnosticLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let level: DiagnosticLogLevel
    let category: String
    let message: String
}

enum DiagnosticLogLevel: String, CaseIterable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var label: String {
        switch self {
        case .debug: return "调试"
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    var shortLabel: String {
        switch self {
        case .debug: return "D"
        case .info: return "I"
        case .warning: return "W"
        case .error: return "E"
        }
    }
}

struct DiagnosticLogFile: Identifiable, Sendable {
    let id: String
    let url: URL
    let size: Int64
    let date: Date
    let isSegment: Bool
    let sessionLabel: String

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date) + (isSegment ? " 续" : "")
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

final class DiagnosticLogManager: @unchecked Sendable {
    static let shared = DiagnosticLogManager()

    private let logger = Logger(subsystem: "com.openui", category: "Diagnostic")
    private let storage = DiagnosticLogStorage()

    private init() {}

    var totalLogSize: Int64 { storage.totalLogSize }
    var logFileCount: Int { storage.logFileCount }
    var currentSessionPrefix: String { storage.currentSessionPrefix }
    var summaryText: String {
        let count = storage.logFileCount
        guard count > 0 else { return "暂无日志" }
        let size = ByteCountFormatter.string(fromByteCount: storage.totalLogSize, countStyle: .file)
        return "\(count) 个文件，\(size)"
    }

    func debug(_ message: String, category: String = "General") {
        storage.append(level: .debug, category: category, message: message)
        logger.debug("\(message)")
    }

    func info(_ message: String, category: String = "General") {
        storage.append(level: .info, category: category, message: message)
        logger.info("\(message)")
    }

    func warning(_ message: String, category: String = "General") {
        storage.append(level: .warning, category: category, message: message)
        logger.warning("\(message)")
    }

    func error(_ message: String, category: String = "General") {
        storage.append(level: .error, category: category, message: message)
        logger.error("\(message)")
    }

    func logFiles() -> [DiagnosticLogFile] {
        storage.logFiles()
    }

    func entries(for file: DiagnosticLogFile) -> [DiagnosticLogEntry] {
        storage.entries(for: file)
    }

    func exportAllURL() -> URL? {
        storage.exportAllURL()
    }

    func exportSingleFileURL(_ file: DiagnosticLogFile) -> URL? {
        storage.exportSingleFileURL(file)
    }

    func deleteFile(_ file: DiagnosticLogFile) {
        storage.deleteFile(file)
    }

    func clear() {
        storage.clear()
    }
}

private final class DiagnosticLogStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openui.diagnostic-log", qos: .utility)
    private let fileManager = FileManager.default
    private var buffer: [String] = []
    private var currentFileKey: String
    private var currentFileStart: Date
    private var segmentIndex = 0
    private var flushTimer: DispatchSourceTimer?
    private let launchPrefix: String

    private static let retentionDays = 7
    private static let maxSegmentSeconds: TimeInterval = 3600
    private static let maxMessageLength = 4000

    var currentSessionPrefix: String { launchPrefix }

    init() {
        let now = Date()
        let fileKey = Self.fileKey(for: now, segment: 0)
        currentFileKey = fileKey
        currentFileStart = now
        launchPrefix = String(fileKey.prefix(max(0, fileKey.count - 2)))
        ensureDirectoryExists()
        cleanupOldLogs()
        startFlushTimer()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        buffer.append("== Iexa Diagnostic Log ==")
        buffer.append("App version: \(version) (\(build))")
        buffer.append("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        buffer.append("Launch: \(Self.timestampFormatter().string(from: now))")
    }

    deinit {
        flushTimer?.cancel()
        flush()
    }

    var totalLogSize: Int64 {
        flush()
        return logFileURLs().reduce(Int64(0)) { total, url in
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    var logFileCount: Int {
        flush()
        return logFileURLs().count
    }

    func append(level: DiagnosticLogLevel, category: String, message: String) {
        let now = Date()
        let formatter = Self.timestampFormatter()
        let line = "[\(formatter.string(from: now))] [\(level.rawValue)] [\(sanitize(category, limit: 80))] \(sanitize(message, limit: Self.maxMessageLength))"

        queue.sync {
            if now.timeIntervalSince(currentFileStart) >= Self.maxSegmentSeconds {
                flushBufferUnsafe()
                segmentIndex += 1
                currentFileKey = "\(launchPrefix)_\(Self.segmentSuffix(for: segmentIndex))"
                currentFileStart = now
                buffer.append("== Segment \(segmentIndex + 1): \(formatter.string(from: now)) ==")
            }

            buffer.append(line)
            if buffer.count >= 100 {
                flushBufferUnsafe()
            }
        }
    }

    func logFiles() -> [DiagnosticLogFile] {
        flush()
        let urls = logFileURLs()
        let prefixes = Set(urls.map { url -> String in
            let name = url.deletingPathExtension().lastPathComponent
            return String(name.prefix(max(0, name.count - 2)))
        }).sorted()
        let previousPrefix: String? = {
            guard let index = prefixes.firstIndex(of: launchPrefix), index > 0 else { return nil }
            return prefixes[index - 1]
        }()

        return urls.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let date = Self.parseFileDate(name) ?? .distantPast
            let prefix = String(name.prefix(max(0, name.count - 2)))
            let label: String
            if prefix == launchPrefix {
                label = "当前会话"
            } else if prefix == previousPrefix {
                label = "上次会话"
            } else {
                label = ""
            }

            return DiagnosticLogFile(
                id: name,
                url: url,
                size: size,
                date: date,
                isSegment: !name.hasSuffix("_a"),
                sessionLabel: label
            )
        }
    }

    func entries(for file: DiagnosticLogFile) -> [DiagnosticLogEntry] {
        flush()
        let formatter = Self.timestampFormatter()
        guard let content = try? String(contentsOf: file.url, encoding: .utf8) else { return [] }
        return parseLogFile(content, formatter: formatter)
    }

    func exportAllURL() -> URL? {
        flush()
        let urls = logFileURLs()
        guard !urls.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let exportURL = fileManager.temporaryDirectory.appendingPathComponent("iexa_diagnostic_logs_\(formatter.string(from: Date())).txt")

        var lines: [String] = [
            "Iexa Diagnostic Logs",
            "Exported: \(Self.timestampFormatter().string(from: Date()))",
            "System: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Files: \(urls.count)",
            String(repeating: "-", count: 60)
        ]

        for url in urls {
            lines.append("")
            lines.append("== \(url.lastPathComponent) ==")
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                lines.append(content)
            }
        }

        do {
            try lines.joined(separator: "\n").write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            return nil
        }
    }

    func exportSingleFileURL(_ file: DiagnosticLogFile) -> URL? {
        flush()
        let destination = fileManager.temporaryDirectory.appendingPathComponent(file.url.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: file.url, to: destination)
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }

    func deleteFile(_ file: DiagnosticLogFile) {
        try? fileManager.removeItem(at: file.url)
    }

    func clear() {
        queue.sync {
            buffer.removeAll()
        }
        for url in logFileURLs() {
            try? fileManager.removeItem(at: url)
        }
    }

    private var logDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("IexaDiagnosticLogs", isDirectory: true)
    }

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    private func flush() {
        queue.sync {
            flushBufferUnsafe()
        }
    }

    private func flushBufferUnsafe() {
        guard !buffer.isEmpty else { return }
        ensureDirectoryExists()

        let text = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll()

        let url = fileURL(for: currentFileKey)
        if fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.flushBufferUnsafe()
        }
        timer.resume()
        flushTimer = timer
    }

    private func cleanupOldLogs() {
        queue.async { [weak self] in
            guard let self else { return }
            let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()
            let cutoffKey = Self.fileKey(for: cutoff, segment: 0)
            for url in self.logFileURLs() {
                let name = url.deletingPathExtension().lastPathComponent
                if name < cutoffKey {
                    try? self.fileManager.removeItem(at: url)
                }
            }
        }
    }

    private func logFileURLs() -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileURL(for key: String) -> URL {
        logDirectory.appendingPathComponent("\(key).log")
    }

    private func parseLogFile(_ content: String, formatter: DateFormatter) -> [DiagnosticLogEntry] {
        content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0), formatter: formatter) }
    }

    private func parseLine(_ line: String, formatter: DateFormatter) -> DiagnosticLogEntry? {
        guard line.hasPrefix("[") else { return nil }
        var scanner = line[line.startIndex...]

        guard let dateEnd = scanner.range(of: "] [") else { return nil }
        let dateString = String(scanner[scanner.index(after: scanner.startIndex)..<dateEnd.lowerBound])
        scanner = scanner[dateEnd.upperBound...]

        guard let levelEnd = scanner.range(of: "] [") else { return nil }
        let levelString = String(scanner[scanner.startIndex..<levelEnd.lowerBound])
        scanner = scanner[levelEnd.upperBound...]

        guard let categoryEnd = scanner.range(of: "] ") else { return nil }
        let category = String(scanner[scanner.startIndex..<categoryEnd.lowerBound])
        let message = String(scanner[categoryEnd.upperBound...])

        return DiagnosticLogEntry(
            date: formatter.date(from: dateString) ?? Date(),
            level: DiagnosticLogLevel(rawValue: levelString) ?? .info,
            category: category,
            message: message
        )
    }

    private static func fileKey(for date: Date, segment: Int) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d_%02d%02d%02d_%@",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            segmentSuffix(for: segment)
        )
    }

    private static func segmentSuffix(for segment: Int) -> String {
        if segment < 26, let scalar = UnicodeScalar(UInt32(97 + segment)) {
            return String(scalar)
        }
        return "\(segment)"
    }

    private static func parseFileDate(_ name: String) -> Date? {
        guard name.count >= 17 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(name.prefix(17)))
    }

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private func sanitize(_ value: String, limit: Int) -> String {
        var sanitized = value
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "]", with: ")")

        let replacements: [(String, String)] = [
            (#"(?i)bearer\s+[A-Za-z0-9._\-]+"#, "Bearer [redacted]"),
            (#"(?i)(authorization|cookie):\s*[^\\n]+"#, "$1: [redacted]"),
            (#"(?i)(api[_-]?key|access[_-]?token|auth[_-]?token|token|key)=([^\\s&]+)"#, "$1=[redacted]")
        ]

        for replacement in replacements {
            sanitized = sanitized.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }

        if sanitized.count > limit {
            sanitized = String(sanitized.prefix(limit)) + "…"
        }
        return sanitized
    }
}
