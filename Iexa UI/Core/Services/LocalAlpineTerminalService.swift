import Foundation
import os.log
import UIKit

struct LocalAlpineStatus: Sendable {
    let isRuntimeLinked: Bool
    let isRootFSBundled: Bool
    let rootArchiveName: String
    let workspacePath: String
}

struct LocalAlpineCommandResult: Sendable {
    let command: String
    let output: String
    let exitCode: Int?
    let interactiveRequest: LocalAlpineInteractiveRequest?
    let openRequests: [LocalAlpineOpenRequest]

    init(
        command: String,
        output: String,
        exitCode: Int?,
        interactiveRequest: LocalAlpineInteractiveRequest?,
        openRequests: [LocalAlpineOpenRequest] = []
    ) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.interactiveRequest = interactiveRequest
        self.openRequests = openRequests
    }
}

struct LocalAlpineFileSample: Sendable {
    let data: Data
    let fullSize: Int64?

    var isTruncated: Bool {
        guard let fullSize else { return false }
        return Int64(data.count) < fullSize
    }
}

struct LocalAlpineInteractiveRequest: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case command
        case agentBlocks
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let placeholder: String
    let defaultValue: String
    let command: String
    let cwd: String
}

struct LocalAlpineRootFSResetResult: Sendable {
    let resetImmediately: Bool
    let message: String
}

struct LocalAlpineSessionStartResult: Sendable {
    let sessionID: Int?
    let message: String?
}

struct LocalAlpineOpenRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    let target: String

    var webURL: URL? {
        guard let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme) else {
            return nil
        }
        if (url.host ?? "").caseInsensitiveCompare("iexa.preview") == .orderedSame {
            return nil
        }
        return url
    }
}

enum LocalAlpineOpenMarkerParser {
    private static let escape = Character("\u{001B}")
    private static let bell = Character("\u{0007}")
    private static let stTerminator = "\u{001B}\\"
    private static let oscPrefix = "]1337;"
    private static let keys = ["IexaOpenURL="]

    static func extract(from text: String) -> (cleaned: String, requests: [LocalAlpineOpenRequest]) {
        guard text.contains("\u{001B}]1337;") || text.contains("]1337;IexaOpenURL=") else {
            return (text, [])
        }

        var cleaned = ""
        var requests: [LocalAlpineOpenRequest] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let escapeIndex = text[cursor...].firstIndex(of: escape) else {
                cleaned.append(contentsOf: text[cursor...])
                break
            }

            cleaned.append(contentsOf: text[cursor..<escapeIndex])
            let afterEscape = text.index(after: escapeIndex)
            guard afterEscape < text.endIndex, text[afterEscape] == "]" else {
                cleaned.append(text[escapeIndex])
                cursor = afterEscape
                continue
            }

            guard text[afterEscape...].hasPrefix(oscPrefix),
                  let terminatorRange = oscTerminatorRange(in: text, from: afterEscape) else {
                cleaned.append(text[escapeIndex])
                cursor = afterEscape
                continue
            }

            let payloadStart = text.index(afterEscape, offsetBy: oscPrefix.count)
            let payload = String(text[payloadStart..<terminatorRange.lowerBound])
            if let target = openTarget(from: payload) {
                requests.append(LocalAlpineOpenRequest(target: target))
            } else {
                cleaned.append(contentsOf: text[escapeIndex..<terminatorRange.upperBound])
            }
            cursor = terminatorRange.upperBound
        }

        return (cleaned, requests)
    }

    private static func oscTerminatorRange(in text: String, from start: String.Index) -> Range<String.Index>? {
        var candidates: [Range<String.Index>] = []
        if let bellIndex = text[start...].firstIndex(of: bell) {
            candidates.append(bellIndex..<text.index(after: bellIndex))
        }
        if let stRange = text[start...].range(of: stTerminator) {
            candidates.append(stRange)
        }
        return candidates.min { $0.lowerBound < $1.lowerBound }
    }

    private static func openTarget(from payload: String) -> String? {
        for key in keys where payload.hasPrefix(key) {
            let target = String(payload.dropFirst(key.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? nil : target
        }
        return nil
    }
}

@MainActor
enum LocalAlpineBackgroundExecution {
    private static var taskId: UIBackgroundTaskIdentifier = .invalid
    private static var depth = 0

    static func begin(reason: String) {
        depth += 1
        guard taskId == .invalid else { return }

        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskName = trimmedReason.isEmpty ? "Local Alpine" : "Local Alpine \(trimmedReason)"
        taskId = UIApplication.shared.beginBackgroundTask(withName: taskName) {
            Task { @MainActor in
                expire()
            }
        }
    }

    static func finish() {
        guard depth > 0 else {
            endLocked()
            return
        }

        depth -= 1
        if depth == 0 {
            endLocked()
        }
    }

    private static func expire() {
        let interrupted = LocalAlpineTerminalService.shared.interruptRunningCommand()
        let interruptedText = interrupted ? "true" : "false"
        Logger(subsystem: "com.openui", category: "LocalAlpine")
            .warning("Local Alpine background execution expired; interrupt sent: \(interruptedText, privacy: .public)")
        depth = 0
        endLocked()
    }

    private static func endLocked() {
        guard taskId != .invalid else {
            depth = 0
            return
        }

        let id = taskId
        taskId = .invalid
        depth = 0
        UIApplication.shared.endBackgroundTask(id)
    }
}

actor LocalAlpineTerminalService {
    static let shared = LocalAlpineTerminalService()

    private let logger = Logger(subsystem: "com.openui", category: "LocalAlpine")
    private let fileManager = FileManager.default
    private let rootArchiveName = "iexa-alpine-rootfs.fakefs"
    private let bundledRootFSVersion = "3.19.9-lite.1"
    private let rootVersionFileName = ".iexa-rootfs-version"
    private let rootResetMarkerFileName = ".iexa-rootfs-reset-pending"
    private let workspaceFolderName = "Iexa Alpine"
    private let sharedFolderName = "shared"
    private let maximumInlineRuntimeCommandBytes = 3_072
    private var nativeRuntimeStarted = false
    private var prewarmTask: Task<Void, Never>?
    private var lastPrewarmAttemptAt: Date?

    static let environmentDiagnosticCommand = """
    printf '== Local Alpine ==\\n'
    printf 'runtime: iSH x86 usermode\\n'
    printf 'rootfs:  '
    cat /etc/alpine-release 2>/dev/null || printf 'unknown\\n'
    printf 'kernel:  '
    uname -a 2>/dev/null || true
    printf 'user:    '
    id 2>/dev/null || true
    printf 'pwd:     '
    pwd
    printf '\\n== PATH ==\\n%s\\n' "$PATH"
    printf '\\n== DNS ==\\n'
    cat /etc/resolv.conf 2>/dev/null || true
    printf '\\n== workspace /mnt/iexa ==\\n'
    ls -la /mnt/iexa 2>/dev/null || true
    printf '\\n== core tools ==\\n'
    for x in sh ash busybox apk wget curl python3 pip3 node npm gcc g++ make git tar unzip zip sqlite3; do
      printf '%-8s ' "$x"
      command -v "$x" 2>/dev/null || printf 'missing\\n'
    done
    printf '\\n== package db ==\\n'
    apk --version 2>/dev/null || true
    """

    private init() {}

    func prewarmIfNeeded(reason: String = "startup", delayNanoseconds: UInt64 = 1_500_000_000) {
        guard nativeRuntimeStarted == false else { return }
        guard prewarmTask == nil else { return }

        let now = Date()
        if let lastPrewarmAttemptAt, now.timeIntervalSince(lastPrewarmAttemptAt) < 30 {
            return
        }
        lastPrewarmAttemptAt = now

        prewarmTask = Task.detached(priority: .utility) {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else {
                await LocalAlpineTerminalService.shared.finishPrewarm(reason: reason, startedAt: Date(), result: nil)
                return
            }
            guard await LocalAlpineTerminalService.shared.shouldContinuePrewarm() else { return }

            let startedAt = Date()
            let result = await LocalAlpineTerminalService.shared.execute(command: ":", cwd: "/mnt/iexa")
            await LocalAlpineTerminalService.shared.finishPrewarm(reason: reason, startedAt: startedAt, result: result)
        }
    }

    private func shouldContinuePrewarm() -> Bool {
        guard nativeRuntimeStarted == false else {
            prewarmTask = nil
            return false
        }
        return true
    }

    private func finishPrewarm(reason: String, startedAt: Date, result: LocalAlpineCommandResult?) {
        prewarmTask = nil
        guard let result else { return }

        if runtimeLikelyStarted(from: result) {
            nativeRuntimeStarted = true
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let elapsedText = String(format: "%.2f", elapsed)
        let exitText = result.exitCode.map(String.init) ?? "nil"
        if result.exitCode == 0 {
            logger.info("Local Alpine prewarm completed reason=\(reason, privacy: .public) elapsed=\(elapsedText, privacy: .public)s")
        } else {
            logger.warning("Local Alpine prewarm finished with exit=\(exitText, privacy: .public) reason=\(reason, privacy: .public) elapsed=\(elapsedText, privacy: .public)s")
        }
    }

    func status() -> LocalAlpineStatus {
        LocalAlpineStatus(
            isRuntimeLinked: LocalAlpineNativeRuntime.shared.isLinked,
            isRootFSBundled: bundledRootFSURL() != nil,
            rootArchiveName: rootArchiveName,
            workspacePath: "Documents/\(workspaceFolderName)/\(sharedFolderName)"
        )
    }

    nonisolated func interruptRunningCommand() -> Bool {
        LocalAlpineNativeRuntime.shared.interrupt()
    }

    nonisolated func writeSessionInput(sessionID: Int, input: String) -> Bool {
        LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: sessionID, input: input)
    }

    nonisolated func readSessionOutput(sessionID: Int) -> String {
        LocalAlpineNativeRuntime.shared.readSessionOutput(sessionID: sessionID)
    }

    nonisolated func interruptSession(sessionID: Int) -> Bool {
        LocalAlpineNativeRuntime.shared.interruptSession(sessionID: sessionID)
    }

    nonisolated func closeSession(sessionID: Int) -> Bool {
        LocalAlpineNativeRuntime.shared.closeSession(sessionID: sessionID)
    }

    nonisolated func resizeSession(sessionID: Int, columns: Int, rows: Int) -> Bool {
        LocalAlpineNativeRuntime.shared.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }

    func startInteractiveSession(cwd: String, cwdIsRuntimePath: Bool = true) async -> LocalAlpineSessionStartResult {
        let status = status()
        guard let rootArchiveURL = bundledRootFSURL() else {
            return LocalAlpineSessionStartResult(
                sessionID: nil,
                message: "Local Alpine rootfs is missing from the app bundle: \(rootArchiveName)"
            )
        }

        let workspaceURL: URL
        do {
            workspaceURL = try ensureWorkspaceDirectory()
            _ = try ensureSharedWorkspaceDirectory()
        } catch {
            return LocalAlpineSessionStartResult(
                sessionID: nil,
                message: "Local Alpine workspace is unavailable: \(error.localizedDescription)"
            )
        }

        guard status.isRuntimeLinked else {
            return LocalAlpineSessionStartResult(
                sessionID: nil,
                message: "Local Alpine runtime is staged but the iSH native core is not linked into this build yet."
            )
        }

        let runtimeRootFSURL: URL
        do {
            runtimeRootFSURL = try ensureRuntimeRootFSURL(from: rootArchiveURL, workspaceURL: workspaceURL)
            try ensureResolverConfiguration(in: runtimeRootFSURL)
            try ensureOpenBridgeConfiguration(in: runtimeRootFSURL)
        } catch {
            return LocalAlpineSessionStartResult(
                sessionID: nil,
                message: "Local Alpine rootfs could not be prepared for writable local execution: \(error.localizedDescription)"
            )
        }

        let runtimeCWD = cwdIsRuntimePath ? normalizedAbsoluteRuntimePath(cwd) : normalizedRuntimePath(cwd)
        let sessionID = await LocalAlpineNativeRuntime.shared.startSession(
            LocalAlpineNativeCommand(
                command: "",
                cwd: runtimeCWD,
                rootArchiveURL: runtimeRootFSURL,
                workspaceURL: workspaceURL
            )
        )
        if sessionID != nil {
            nativeRuntimeStarted = true
        }
        return LocalAlpineSessionStartResult(
            sessionID: sessionID,
            message: sessionID == nil ? "Local Alpine interactive session could not be started." : nil
        )
    }

    func listFiles(path: String, includeHidden: Bool = false) async throws -> [TerminalFileItem] {
        let root = try ensureSharedWorkspaceDirectory()
        let directory = try resolve(path: path, root: root, allowRoot: true)
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: options
        )

        let basePath = normalizedTerminalPath(path)
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let name = url.lastPathComponent
            let fullPath = basePath == "/" ? "/\(name)" : "\(basePath)/\(name)"
            return TerminalFileItem(
                name: name,
                path: fullPath,
                isDirectory: values.isDirectory == true,
                size: values.isDirectory == true ? nil : values.fileSize.map { Int64($0) },
                modified: values.contentModificationDate,
                permissions: nil
            )
        }
    }

    func listRootFSFiles(path: String, includeHidden: Bool = true) async throws -> [TerminalFileItem] {
        let rootPath = try normalizedRootFSPath(path)
        let result = await execute(
            command: rootFSListCommand(path: rootPath, includeHidden: includeHidden),
            cwd: "/mnt/iexa"
        )
        guard result.exitCode == 0 else {
            throw LocalAlpineError.commandFailed(rootFSUserFacingError(from: result.output))
        }
        guard let output = rootFSCommandPayload(
            from: result.output,
            begin: "IEXA_ROOTFS_LIST_BEGIN",
            end: "IEXA_ROOTFS_LIST_END"
        ) else {
            throw LocalAlpineError.commandFailed(rootFSUserFacingError(from: result.output))
        }
        return try parseRootFSListOutput(output, path: rootPath)
    }

    func createFolder(path: String) async throws {
        let root = try ensureSharedWorkspaceDirectory()
        let url = try resolve(path: path, root: root, allowRoot: false)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func deleteItem(path: String, recursive: Bool = true) async throws -> Bool {
        let root = try ensureSharedWorkspaceDirectory()
        let url = try resolve(path: path, root: root, allowRoot: false)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
        if isDirectory && !recursive {
            throw LocalAlpineError.commandFailed("`\(path)` is a directory. Set recursive:true to delete directories.")
        }
        try fileManager.removeItem(at: url)
        return true
    }

    func readFile(path: String) async throws -> Data {
        let root = try ensureSharedWorkspaceDirectory()
        let url = try resolve(path: path, root: root, allowRoot: false)
        return try Data(contentsOf: url)
    }

    func readFileSample(path: String, maxBytes: Int) async throws -> LocalAlpineFileSample {
        let root = try ensureSharedWorkspaceDirectory()
        let url = try resolve(path: path, root: root, allowRoot: false)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: max(1, maxBytes)) ?? Data()
        return LocalAlpineFileSample(
            data: data,
            fullSize: values?.fileSize.map(Int64.init)
        )
    }

    func readRootFSFile(path: String) async throws -> Data {
        let rootPath = try normalizedRootFSPath(path)
        guard rootPath != "/" else {
            throw LocalAlpineError.invalidPath(path)
        }

        let result = await execute(
            command: rootFSReadCommand(path: rootPath),
            cwd: "/mnt/iexa"
        )
        guard result.exitCode == 0 else {
            throw LocalAlpineError.commandFailed(rootFSUserFacingError(from: result.output))
        }

        guard let output = rootFSCommandPayload(
            from: result.output,
            begin: "IEXA_ROOTFS_B64_BEGIN",
            end: "IEXA_ROOTFS_B64_END"
        ) else {
            throw LocalAlpineError.commandFailed(rootFSUserFacingError(from: result.output))
        }

        let encoded = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else {
            throw LocalAlpineError.commandFailed("Unable to decode rootfs file data.")
        }
        return data
    }

    func readRootFSFileSample(path: String, maxBytes: Int) async throws -> LocalAlpineFileSample {
        let rootPath = try normalizedRootFSPath(path)
        guard rootPath != "/" else {
            throw LocalAlpineError.invalidPath(path)
        }

        let result = await execute(
            command: rootFSSampledReadCommand(path: rootPath, maxBytes: maxBytes),
            cwd: "/mnt/iexa"
        )
        guard result.exitCode == 0 else {
            throw LocalAlpineError.commandFailed(rootFSUserFacingError(from: result.output))
        }

        guard let output = rootFSCommandPayload(
            from: result.output,
            begin: "IEXA_ROOTFS_B64_BEGIN",
            end: "IEXA_ROOTFS_B64_END"
        ) else {
            throw LocalAlpineError.commandFailed(rootFSUserFacingError(from: result.output))
        }

        let encoded = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else {
            throw LocalAlpineError.commandFailed("Unable to decode rootfs file preview data.")
        }
        return LocalAlpineFileSample(
            data: data,
            fullSize: rootFSReadSize(from: result.output)
        )
    }

    func materializePreviewURL(for request: LocalAlpineOpenRequest) async throws -> URL {
        let rawTarget = request.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let bridgedPath = openBridgeRuntimePath(from: rawTarget) {
            path = bridgedPath
        } else if let bridgedPath = localPreviewRuntimePath(from: rawTarget) {
            path = bridgedPath
        } else if let fileURL = URL(string: rawTarget),
           fileURL.isFileURL {
            path = fileURL.path
        } else {
            path = rawTarget
        }

        guard !path.isEmpty else {
            throw LocalAlpineError.invalidPath(request.target)
        }

        if isSharedWorkspaceRuntimePath(path) {
            let root = try ensureSharedWorkspaceDirectory()
            return try resolve(path: path, root: root, allowRoot: false)
        }

        let data = try await readRootFSFile(path: path)
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("local_alpine_previews", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileName = try sanitizedFileName(openPreviewFileName(for: path))
        let fileURL = tempDir.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func openBridgeRuntimePath(from rawTarget: String) -> String? {
        guard let url = URL(string: rawTarget),
              let scheme = url.scheme?.lowercased(),
              scheme == "iexa" else {
            return nil
        }

        let host = (url.host ?? "").lowercased()
        let decodedPath = url.path.removingPercentEncoding ?? url.path
        let path = decodedPath.isEmpty ? "/" : decodedPath

        switch host {
        case "", "workspace", "shared", "mnt", "iexa":
            return normalizedRuntimePath(path)
        case "root", "rootfs":
            return path.hasPrefix("/") ? path : "/\(path)"
        default:
            let combined = path == "/" ? "/\(host)" : "/\(host)\(path)"
            return normalizedRuntimePath(combined)
        }
    }

    private func localPreviewRuntimePath(from rawTarget: String) -> String? {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           (url.host ?? "").caseInsensitiveCompare("iexa.preview") == .orderedSame {
            let decodedPath = url.path.removingPercentEncoding ?? url.path
            let withoutLeadingSlash = decodedPath.hasPrefix("/")
                ? String(decodedPath.dropFirst())
                : decodedPath
            if withoutLeadingSlash.lowercased().hasPrefix("file://"),
               let fileURL = URL(string: withoutLeadingSlash),
               fileURL.isFileURL {
                return fileURL.path
            }
            if decodedPath.hasPrefix("/mnt/iexa") {
                return decodedPath
            }
            if decodedPath.hasPrefix("/workspace/") {
                return "/mnt/iexa/" + String(decodedPath.dropFirst("/workspace/".count))
            }
            if decodedPath.hasPrefix("/file/") {
                return "/" + String(decodedPath.dropFirst("/file/".count))
            }
        }

        if trimmed.hasPrefix("/mnt/iexa") || trimmed.hasPrefix("iexa://") {
            return openBridgeRuntimePath(from: trimmed) ?? trimmed
        }
        if let workspacePath = relativeWorkspacePreviewPath(from: trimmed) {
            return workspacePath
        }
        return nil
    }

    private func relativeWorkspacePreviewPath(from rawTarget: String) -> String? {
        let normalized = rawTarget.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"),
              !normalized.hasPrefix("./"),
              !normalized.hasPrefix("../"),
              !normalized.contains("://"),
              normalized.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        let lowercased = normalized.lowercased()
        guard lowercased.hasSuffix(".html")
            || lowercased.hasSuffix(".htm")
            || lowercased.hasSuffix(".svg") else {
            return nil
        }
        return "/mnt/iexa/\(normalized)"
    }

    func writeFile(data: Data, fileName: String, destinationPath: String) async throws {
        let root = try ensureSharedWorkspaceDirectory()
        let directory = try resolve(path: destinationPath, root: root, allowRoot: true)
        let safeName = try sanitizedFileName(fileName)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(safeName), options: .atomic)
    }

    func materializeAttachment(
        data: Data,
        fileName: String,
        messageId: String,
        index: Int
    ) async throws -> String {
        let safeMessageId = sanitizedPathComponent(messageId, fallback: "message")
        let safeName = try sanitizedFileName(fileName)
        let destination = "/.iexa_attachments/\(safeMessageId)"
        let targetName = "\(max(1, index + 1))-\(safeName)"
        try await writeFile(data: data, fileName: targetName, destinationPath: destination)
        return "/mnt/iexa\(destination)/\(targetName)"
    }

    func deleteRootFSItem(path: String) async throws {
        let rootPath = try normalizedRootFSPath(path)
        guard isDeletableRootFSPath(rootPath) else {
            throw LocalAlpineError.protectedPath(rootPath)
        }

        let result = await execute(
            command: rootFSDeleteCommand(path: rootPath),
            cwd: "/mnt/iexa"
        )
        guard result.exitCode == 0 else {
            throw LocalAlpineError.commandFailed(result.output)
        }
    }

    func resetRuntimeRootFS() async throws -> LocalAlpineRootFSResetResult {
        let workspaceURL = try ensureWorkspaceDirectory()
        let markerURL = workspaceURL.appendingPathComponent(rootResetMarkerFileName)

        if nativeRuntimeStarted {
            try "reset on next app launch\n".write(to: markerURL, atomically: true, encoding: .utf8)
            return LocalAlpineRootFSResetResult(
                resetImmediately: false,
                message: "已标记重置本地 Alpine rootfs。当前 iSH runtime 已经启动，为避免破坏正在挂载的文件系统，重置会在下次重启 App 后生效。"
            )
        }

        try resetRuntimeRootFSFiles(in: workspaceURL)
        return LocalAlpineRootFSResetResult(
            resetImmediately: true,
            message: "已重置本地 Alpine rootfs。下次执行命令时会从内置 rootfs 重新初始化。"
        )
    }

    func execute(
        command: String,
        cwd: String,
        stdinInput: String? = nil,
        cwdIsRuntimePath: Bool = false
    ) async -> LocalAlpineCommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LocalAlpineCommandResult(command: command, output: "", exitCode: 0, interactiveRequest: nil)
        }
        if stdinInput == nil, let interactiveWarning = interactiveInputWarning(for: trimmed) {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: interactiveWarning,
                exitCode: 124,
                interactiveRequest: LocalAlpineInteractiveRequest(
                    kind: .command,
                    title: "需要输入",
                    message: "这个命令需要交互式输入。我已经帮你弹出一个小窗口，填完会自动继续跑。",
                    placeholder: "把要输入的内容按顺序粘贴到这里，一行一个也可以",
                    defaultValue: "",
                    command: trimmed,
                    cwd: cwd
                )
            )
        }

        let status = status()
        guard let rootArchiveURL = bundledRootFSURL() else {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine rootfs is missing from the app bundle: \(rootArchiveName)",
                exitCode: 127,
                interactiveRequest: nil
            )
        }

        let workspaceURL: URL
        do {
            workspaceURL = try ensureWorkspaceDirectory()
            _ = try ensureSharedWorkspaceDirectory()
        } catch {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine workspace is unavailable: \(error.localizedDescription)",
                exitCode: 127,
                interactiveRequest: nil
            )
        }

        if !status.isRuntimeLinked {
            let output = """
            Local Alpine runtime is staged but the iSH native core is not linked into this build yet.

            Bundled rootfs: \(rootArchiveURL.lastPathComponent)
            Workspace: \(workspaceURL.path)/\(sharedFolderName)
            Terminal path: /mnt/iexa

            This local slot is isolated from Open Terminal, so existing server terminals continue to work.
            """
            logger.warning("Local Alpine command requested before native runtime is linked: \(trimmed, privacy: .public)")
            return LocalAlpineCommandResult(command: trimmed, output: output, exitCode: 126, interactiveRequest: nil)
        }

        let runtimeRootFSURL: URL
        do {
            runtimeRootFSURL = try ensureRuntimeRootFSURL(from: rootArchiveURL, workspaceURL: workspaceURL)
            try ensureResolverConfiguration(in: runtimeRootFSURL)
            try ensureOpenBridgeConfiguration(in: runtimeRootFSURL)
        } catch {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine rootfs could not be prepared for writable local execution: \(error.localizedDescription)",
                exitCode: 127,
                interactiveRequest: nil
            )
        }

        let runtimeCWD = cwdIsRuntimePath
            ? normalizedAbsoluteRuntimePath(cwd)
            : normalizedRuntimePath(cwd)
        let compatibleCommand = compatibilityCommand(for: trimmed)
        let bootstrappedCommand = bootstrappedShellCommand(for: compatibleCommand)
        let runtimeCommand = stdinInput.map {
            wrappedCommandForInteractiveInput(command: bootstrappedCommand, stdinInput: $0)
        } ?? bootstrappedCommand
        let materialized = await materializedRuntimeCommandIfNeeded(runtimeCommand)
        await LocalAlpineBackgroundExecution.begin(reason: "command")
        let result = await LocalAlpineNativeRuntime.shared.execute(
            LocalAlpineNativeCommand(
                command: materialized.command,
                cwd: runtimeCWD,
                rootArchiveURL: runtimeRootFSURL,
                workspaceURL: workspaceURL
            )
        )
        if let cleanupPath = materialized.cleanupPath {
            try? await deleteItem(path: cleanupPath)
        }
        if runtimeLikelyStarted(from: result) {
            nativeRuntimeStarted = true
        }
        let commandResult = resultByExtractingOpenMarkers(
            LocalAlpineCommandResult(
                command: trimmed,
                output: result.output,
                exitCode: result.exitCode,
                interactiveRequest: nil
            )
        )
        await LocalAlpineBackgroundExecution.finish()
        return commandResult
    }

    func executeStreaming(
        command: String,
        cwd: String,
        cwdIsRuntimePath: Bool = false,
        onSessionStart: (@MainActor @Sendable (Int?) -> Void)? = nil,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async -> LocalAlpineCommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LocalAlpineCommandResult(command: command, output: "", exitCode: 0, interactiveRequest: nil)
        }
        if let interactiveWarning = interactiveInputWarning(for: trimmed) {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: interactiveWarning,
                exitCode: 124,
                interactiveRequest: LocalAlpineInteractiveRequest(
                    kind: .command,
                    title: "需要输入",
                    message: "这个命令需要交互式输入。我已经帮你弹出一个小窗口，填完会自动继续跑。",
                    placeholder: "把要输入的内容按顺序粘贴到这里，一行一个也可以",
                    defaultValue: "",
                    command: trimmed,
                    cwd: cwd
                )
            )
        }

        let status = status()
        guard let rootArchiveURL = bundledRootFSURL() else {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine rootfs is missing from the app bundle: \(rootArchiveName)",
                exitCode: 127,
                interactiveRequest: nil
            )
        }

        let workspaceURL: URL
        do {
            workspaceURL = try ensureWorkspaceDirectory()
            _ = try ensureSharedWorkspaceDirectory()
        } catch {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine workspace is unavailable: \(error.localizedDescription)",
                exitCode: 127,
                interactiveRequest: nil
            )
        }

        guard status.isRuntimeLinked else {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine native runtime is not linked; command was not executed.",
                exitCode: 126,
                interactiveRequest: nil
            )
        }

        let runtimeRootFSURL: URL
        do {
            runtimeRootFSURL = try ensureRuntimeRootFSURL(from: rootArchiveURL, workspaceURL: workspaceURL)
            try ensureResolverConfiguration(in: runtimeRootFSURL)
            try ensureOpenBridgeConfiguration(in: runtimeRootFSURL)
        } catch {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine rootfs could not be prepared for writable local execution: \(error.localizedDescription)",
                exitCode: 127,
                interactiveRequest: nil
            )
        }

        let runtimeCWD = cwdIsRuntimePath
            ? normalizedAbsoluteRuntimePath(cwd)
            : normalizedRuntimePath(cwd)
        let compatibleCommand = compatibilityCommand(for: trimmed)
        let bootstrappedCommand = bootstrappedShellCommand(for: compatibleCommand)
        let materialized = await materializedRuntimeCommandIfNeeded(bootstrappedCommand)

        await LocalAlpineBackgroundExecution.begin(reason: "terminal")
        let streamedResult = await executeMaterializedCommandStreaming(
            originalCommand: trimmed,
            materializedCommand: materialized.command,
            runtimeCWD: runtimeCWD,
            rootArchiveURL: runtimeRootFSURL,
            workspaceURL: workspaceURL,
            onSessionStart: onSessionStart,
            onOutput: onOutput
        )
        await MainActor.run {
            onSessionStart?(nil)
        }
        if let cleanupPath = materialized.cleanupPath {
            try? await deleteItem(path: cleanupPath)
        }
        guard let streamedResult else {
            await LocalAlpineBackgroundExecution.finish()
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine streaming session could not be started; command was not re-run.",
                exitCode: 126,
                interactiveRequest: nil
            )
        }

        if runtimeLikelyStarted(from: streamedResult) {
            nativeRuntimeStarted = true
        }
        await LocalAlpineBackgroundExecution.finish()
        return streamedResult
    }

    private func resultByExtractingOpenMarkers(_ result: LocalAlpineCommandResult) -> LocalAlpineCommandResult {
        let parsed = LocalAlpineOpenMarkerParser.extract(from: result.output)
        guard !parsed.requests.isEmpty || parsed.cleaned != result.output else {
            return result
        }
        return LocalAlpineCommandResult(
            command: result.command,
            output: parsed.cleaned,
            exitCode: result.exitCode,
            interactiveRequest: result.interactiveRequest,
            openRequests: result.openRequests + parsed.requests
        )
    }

    private func bundledRootFSURL() -> URL? {
        Bundle.main.url(forResource: "iexa-alpine-rootfs", withExtension: "fakefs")
            ?? Bundle.main.url(forResource: "iexa-alpine-rootfs.fakefs", withExtension: "tar.gz")
            ?? Bundle.main.url(forResource: "iexa-alpine-rootfs", withExtension: "tar.gz")
            ?? Bundle.main.url(forResource: "iexa-alpine-rootfs.tar", withExtension: "gz")
    }

    private func ensureWorkspaceDirectory() throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw LocalAlpineError.documentsUnavailable
        }
        let root = documents.appendingPathComponent(workspaceFolderName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func ensureSharedWorkspaceDirectory() throws -> URL {
        let root = try ensureWorkspaceDirectory()
        let shared = root.appendingPathComponent(sharedFolderName, isDirectory: true)
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        return shared.standardizedFileURL
    }

    private func ensureRuntimeRootFSURL(from bundledURL: URL, workspaceURL: URL) throws -> URL {
        guard bundledURL.pathExtension == "fakefs" else {
            return bundledURL
        }

        let writableURL = workspaceURL.appendingPathComponent("rootfs.fakefs", isDirectory: true)
        let dataURL = writableURL.appendingPathComponent("data", isDirectory: true)
        let metadataURL = writableURL.appendingPathComponent("meta.db")
        let versionURL = workspaceURL.appendingPathComponent(rootVersionFileName)
        let resetMarkerURL = workspaceURL.appendingPathComponent(rootResetMarkerFileName)
        let hasPendingReset = fileManager.fileExists(atPath: resetMarkerURL.path)
        if fileManager.fileExists(atPath: dataURL.path),
           fileManager.fileExists(atPath: metadataURL.path),
           storedRootFSVersion(at: versionURL) == bundledRootFSVersion,
           !hasPendingReset {
            return writableURL.standardizedFileURL
        }

        if hasPendingReset, nativeRuntimeStarted,
           fileManager.fileExists(atPath: dataURL.path),
           fileManager.fileExists(atPath: metadataURL.path) {
            return writableURL.standardizedFileURL
        }

        let temporaryURL = workspaceURL.appendingPathComponent("rootfs.fakefs.tmp-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: temporaryURL)
        try fileManager.copyItem(at: bundledURL, to: temporaryURL)
        if fileManager.fileExists(atPath: writableURL.path) {
            try fileManager.removeItem(at: writableURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: writableURL)
        try? bundledRootFSVersion.write(to: versionURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: resetMarkerURL)
        return writableURL.standardizedFileURL
    }

    private func resetRuntimeRootFSFiles(in workspaceURL: URL) throws {
        let writableURL = workspaceURL.appendingPathComponent("rootfs.fakefs", isDirectory: true)
        let versionURL = workspaceURL.appendingPathComponent(rootVersionFileName)
        let resetMarkerURL = workspaceURL.appendingPathComponent(rootResetMarkerFileName)
        for url in [writableURL, versionURL, resetMarkerURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func storedRootFSVersion(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureResolverConfiguration(in runtimeRootFSURL: URL) throws {
        guard runtimeRootFSURL.pathExtension == "fakefs" else { return }

        let dataURL = runtimeRootFSURL.appendingPathComponent("data", isDirectory: true)
        let etcURL = dataURL.appendingPathComponent("etc", isDirectory: true)
        let resolvURL = etcURL.appendingPathComponent("resolv.conf")
        let resolver = """
        nameserver 1.1.1.1
        nameserver 8.8.8.8
        options timeout:2 attempts:2

        """

        if let existing = try? String(contentsOf: resolvURL, encoding: .utf8),
           existing.contains("nameserver") {
            return
        }

        try fileManager.createDirectory(at: etcURL, withIntermediateDirectories: true)
        try resolver.write(to: resolvURL, atomically: true, encoding: .utf8)
    }

    private func ensureOpenBridgeConfiguration(in runtimeRootFSURL: URL) throws {
        guard runtimeRootFSURL.pathExtension == "fakefs" else { return }

        let dataURL = runtimeRootFSURL.appendingPathComponent("data", isDirectory: true)
        let binURL = dataURL.appendingPathComponent("usr/local/bin", isDirectory: true)
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)

        let bridgeScript = """
        #!/bin/sh
        ESC=$(printf '\\033')
        BEL=$(printf '\\007')

        emit_open_marker() {
          printf '%s]1337;IexaOpenURL=%s%s\\n' "$ESC" "$1" "$BEL"
        }

        normalize_target() {
          case "$1" in
            http://*|https://*|about:*|file://*|iexa://*|/*)
              printf '%s\\n' "$1"
              ;;
            *)
              resolved=$(readlink -f "$1" 2>/dev/null || true)
              if [ -n "$resolved" ]; then
                printf '%s\\n' "$resolved"
              else
                printf '%s\\n' "$1"
              fi
              ;;
          esac
        }

        if [ "$#" -eq 0 ]; then
          printf 'Usage: iexa-open <url-or-path>\\n' >&2
          exit 1
        fi

        for arg in "$@"; do
          target=$(normalize_target "$arg")
          case "$target" in
            http://*|https://*|about:*|file://*|iexa://*|/*)
              emit_open_marker "$target"
              printf 'Opened in Iexa preview: %s\\n' "$target"
              ;;
            *)
              printf 'iexa-open: not a URL or path: %s\\n' "$arg" >&2
              ;;
          esac
        done

        exit 0
        """
        try writeExecutableText(bridgeScript, to: binURL.appendingPathComponent("iexa-open"))

        let serveScript = """
        #!/bin/sh
        set -u

        ESC=$(printf '\\033')
        BEL=$(printf '\\007')

        emit_open_marker() {
          printf '%s]1337;IexaOpenURL=%s%s\\n' "$ESC" "$1" "$BEL"
        }

        if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
          printf 'Usage: iexa-serve [directory-or-file] [port]\\n' >&2
          exit 0
        fi

        target=${1:-.}
        port=${2:-8080}
        case "$port" in
          ''|*[!0-9]*) port=8080 ;;
        esac

        if [ -f "$target" ]; then
          target=$(dirname "$target")
        fi
        if [ ! -d "$target" ]; then
          resolved=$(readlink -f "$target" 2>/dev/null || true)
          if [ -n "$resolved" ] && [ -f "$resolved" ]; then
            target=$(dirname "$resolved")
          elif [ -n "$resolved" ] && [ -d "$resolved" ]; then
            target="$resolved"
          fi
        fi
        if [ ! -d "$target" ]; then
          printf 'iexa-serve: directory not found: %s\\n' "$target" >&2
          exit 1
        fi

        dir=$(cd "$target" 2>/dev/null && pwd)
        if [ -z "$dir" ]; then
          printf 'iexa-serve: cannot resolve directory: %s\\n' "$target" >&2
          exit 1
        fi

        runtime_dir=/tmp/iexa-serve
        mkdir -p "$runtime_dir"

        print_urls() {
          url="http://localhost:$1/"
          printf 'Preview URL: %s\\n' "$url"
          printf 'Loopback URL: http://127.0.0.1:%s/\\n' "$1"
          printf '访问地址: %s\\n' "$url"
          emit_open_marker "$url"
        }

        pid_alive() {
          [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
        }

        socket_port_in_use() {
          if command -v nc >/dev/null 2>&1; then
            nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
            return 1
          fi
          if [ -r /proc/net/tcp ]; then
            port_hex=$(printf '%04X' "$1" 2>/dev/null || true)
            if [ -n "$port_hex" ]; then
              awk -v p=":$port_hex" 'tolower($2) ~ tolower(p) && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp 2>/dev/null && return 0
              if [ -r /proc/net/tcp6 ]; then
                awk -v p=":$port_hex" 'tolower($2) ~ tolower(p) && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp6 2>/dev/null && return 0
              fi
              return 1
            fi
          fi
          return 2
        }

        existing_server_for_dir() {
          candidate_port="$1"
          candidate_pidfile="$runtime_dir/$candidate_port.pid"
          candidate_dirfile="$runtime_dir/$candidate_port.dir"
          [ -f "$candidate_pidfile" ] || return 1
          candidate_pid=$(cat "$candidate_pidfile" 2>/dev/null || true)
          pid_alive "$candidate_pid" || return 1
          socket_port_in_use "$candidate_port"
          socket_status=$?
          if [ "$socket_status" -eq 1 ]; then
            return 1
          fi
          candidate_dir=$(cat "$candidate_dirfile" 2>/dev/null || true)
          if [ -z "$candidate_dir" ] || [ "$candidate_dir" = "$dir" ]; then
            printf 'Iexa local preview server already running.\\n'
            printf 'Directory: %s\\n' "$dir"
            printf 'PID: %s\\n' "$candidate_pid"
            print_urls "$candidate_port"
            exit 0
          fi
          return 1
        }

        port_in_use() {
          socket_port_in_use "$1"
          socket_status=$?
          if [ "$socket_status" -eq 0 ]; then
            return 0
          elif [ "$socket_status" -eq 1 ]; then
            return 1
          fi
          pidfile="$runtime_dir/$1.pid"
          if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null || true)
            if pid_alive "$pid"; then
              return 0
            fi
          fi
          return 1
        }

        existing_server_for_dir "$port"
        start_port=$port
        while port_in_use "$port"; do
          port=$((port + 1))
          existing_server_for_dir "$port"
          if [ "$port" -gt $((start_port + 50)) ]; then
            printf 'iexa-serve: no free localhost port found near %s\\n' "$start_port" >&2
            exit 1
          fi
        done

        log="$runtime_dir/$port.log"
        pidfile="$runtime_dir/$port.pid"
        dirfile="$runtime_dir/$port.dir"

        if command -v python3 >/dev/null 2>&1; then
          if command -v nohup >/dev/null 2>&1; then
            nohup python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >"$log" 2>&1 &
          else
            python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >"$log" 2>&1 &
          fi
          pid=$!
        elif command -v busybox >/dev/null 2>&1; then
          cd "$dir" || exit 1
          if command -v nohup >/dev/null 2>&1; then
            nohup busybox httpd -f -p "127.0.0.1:$port" -h "$dir" >"$log" 2>&1 &
          else
            busybox httpd -f -p "127.0.0.1:$port" -h "$dir" >"$log" 2>&1 &
          fi
          pid=$!
        else
          printf 'iexa-serve: python3 or busybox httpd is required\\n' >&2
          exit 1
        fi

        printf '%s\\n' "$pid" > "$pidfile"
        printf '%s\\n' "$dir" > "$dirfile"
        sleep 1 2>/dev/null || true
        if ! kill -0 "$pid" 2>/dev/null; then
          printf 'iexa-serve: server failed to start. Log: %s\\n' "$log" >&2
          [ -f "$log" ] && tail -40 "$log" >&2
          rm -f "$pidfile" "$dirfile"
          exit 1
        fi
        socket_port_in_use "$port"
        socket_status=$?
        if [ "$socket_status" -eq 1 ]; then
          printf 'iexa-serve: server did not listen on localhost:%s. Log: %s\\n' "$port" "$log" >&2
          [ -f "$log" ] && tail -40 "$log" >&2
          kill "$pid" 2>/dev/null || true
          rm -f "$pidfile" "$dirfile"
          exit 1
        fi

        printf 'Iexa local preview server started.\\n'
        printf 'Directory: %s\\n' "$dir"
        printf 'PID: %s\\n' "$pid"
        print_urls "$port"
        exit 0
        """
        try writeExecutableText(serveScript, to: binURL.appendingPathComponent("iexa-serve"))

        let wrapperScript = """
        #!/bin/sh
        exec /usr/local/bin/iexa-open "$@"
        """
        for name in ["xdg-open", "sensible-browser", "www-browser", "x-www-browser", "gnome-open", "kde-open", "open"] {
            try writeExecutableText(wrapperScript, to: binURL.appendingPathComponent(name))
        }

        let lsofShim = """
        #!/bin/sh
        printf 'lsof is disabled in Iexa Local Alpine because it is unreliable in the embedded iSH runtime.\\n' >&2
        printf 'For localhost preview checks, use `nc -z 127.0.0.1 <port>` or inspect /proc/net/tcp.\\n' >&2
        exit 127
        """
        try writeExecutableText(lsofShim, to: binURL.appendingPathComponent("lsof"))

        let profileURL = dataURL.appendingPathComponent("etc/profile.d", isDirectory: true)
        try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)
        let profile = """
        export BROWSER=/usr/local/bin/iexa-open
        export PAGER=${PAGER:-less}
        export UV_LINK_MODE=${UV_LINK_MODE:-symlink}

        """
        try profile.write(to: profileURL.appendingPathComponent("iexa-open.sh"), atomically: true, encoding: .utf8)
    }

    private func writeExecutableText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func resolve(path rawPath: String, root: URL, allowRoot: Bool) throws -> URL {
        let normalized = normalizedTerminalPath(rawPath)
        if normalized == "/" {
            guard allowRoot else { throw LocalAlpineError.invalidPath(rawPath) }
            return root
        }

        let relative = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw LocalAlpineError.invalidPath(rawPath)
        }
        return candidate
    }

    private func normalizedTerminalPath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if path.isEmpty || path == "." || path == "/home/user" || path == "~" {
            return "/"
        }
        if path.hasPrefix("/home/user/") {
            path.removeFirst("/home/user".count)
        }
        if path == "/mnt/iexa" {
            return "/"
        }
        if path.hasPrefix("/mnt/iexa/") {
            path.removeFirst("/mnt/iexa".count)
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        return path
    }

    private func normalizedRuntimePath(_ rawPath: String) -> String {
        let hostPath = normalizedTerminalPath(rawPath)
        return hostPath == "/" ? "/mnt/iexa" : "/mnt/iexa\(hostPath)"
    }

    private func normalizedAbsoluteRuntimePath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if path.isEmpty || path == "." {
            path = "/mnt/iexa"
        } else if path == "~" {
            path = "/root"
        } else if path.hasPrefix("~/") {
            path = "/root/" + String(path.dropFirst(2))
        } else if !path.hasPrefix("/") {
            path = "/\(path)"
        }

        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private func isSharedWorkspaceRuntimePath(_ rawPath: String) -> Bool {
        let path = normalizedAbsoluteRuntimePath(rawPath)
        return path == "/mnt/iexa" || path.hasPrefix("/mnt/iexa/")
    }

    private func openPreviewFileName(for rawPath: String) -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let name = URL(fileURLWithPath: path).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "preview" : name
    }

    private func runtimeLikelyStarted(from result: LocalAlpineCommandResult) -> Bool {
        let output = result.output.lowercased()
        let bootFailureMarkers = [
            "local alpine boot failed",
            "mount_root failed",
            "become_first_process failed",
            "bundled local alpine fakefs is missing",
            "fakefs is missing",
            "native runtime was not compiled",
            "no ish core implementation is linked",
            "runtime is staged but the ish native core is not linked"
        ]
        return !bootFailureMarkers.contains { output.contains($0) }
    }

    private func executeMaterializedCommandStreaming(
        originalCommand: String,
        materializedCommand: String,
        runtimeCWD: String,
        rootArchiveURL: URL,
        workspaceURL: URL,
        onSessionStart: (@MainActor @Sendable (Int?) -> Void)?,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async -> LocalAlpineCommandResult? {
        let sessionID = await LocalAlpineNativeRuntime.shared.startSession(
            LocalAlpineNativeCommand(
                command: "",
                cwd: runtimeCWD,
                rootArchiveURL: rootArchiveURL,
                workspaceURL: workspaceURL
            )
        )
        guard let sessionID else { return nil }

        nativeRuntimeStarted = true
        await MainActor.run {
            onSessionStart?(sessionID)
        }
        defer {
            _ = LocalAlpineNativeRuntime.shared.closeSession(sessionID: sessionID)
        }

        _ = LocalAlpineNativeRuntime.shared.resizeSession(sessionID: sessionID, columns: 120, rows: 40)
        try? await Task.sleep(nanoseconds: 80_000_000)
        _ = LocalAlpineNativeRuntime.shared.readSessionOutput(sessionID: sessionID)
        _ = LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: sessionID, input: "stty -echo 2>/dev/null || true\n")
        try? await Task.sleep(nanoseconds: 80_000_000)
        _ = LocalAlpineNativeRuntime.shared.readSessionOutput(sessionID: sessionID)

        let marker = "__IEXA_STREAM_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let markerPrefix = "\(marker):"
        let envelope = """
        /bin/sh -lc \(shellSingleQuoted(materializedCommand))
        __iexa_stream_status=$?
        printf '\\n\(markerPrefix)%s\\n' "$__iexa_stream_status"
        exit
        """
        guard LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: sessionID, input: envelope + "\n") else {
            return nil
        }

        var rawOutput = ""
        var lastVisibleOutput = ""
        var emptyPollsAfterExit = 0
        var openTargets = Set<String>()
        var openRequests: [LocalAlpineOpenRequest] = []

        func cleanedOutputAndCollectOpenRequests(_ output: String) -> String {
            let parsed = LocalAlpineOpenMarkerParser.extract(from: output)
            for request in parsed.requests where openTargets.insert(request.target).inserted {
                openRequests.append(request)
            }
            return parsed.cleaned.replacingOccurrences(of: "\u{0007}", with: "")
        }

        func commandResult(
            rawOutput: String,
            exitCode: Int?
        ) -> LocalAlpineCommandResult {
            let cleaned = cleanedOutputAndCollectOpenRequests(rawOutput)
            return LocalAlpineCommandResult(
                command: originalCommand,
                output: cleaned,
                exitCode: exitCode,
                interactiveRequest: nil,
                openRequests: openRequests
            )
        }

        while !Task.isCancelled {
            let chunk = LocalAlpineNativeRuntime.shared.readSessionOutput(sessionID: sessionID)
            if !chunk.isEmpty {
                rawOutput += chunk
                emptyPollsAfterExit = 0
                let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
                let visibleOutput = trimTrailingNewlines(cleanedOutputAndCollectOpenRequests(parsed.visibleOutput))
                if visibleOutput != lastVisibleOutput {
                    lastVisibleOutput = visibleOutput
                    await onOutput(visibleOutput)
                }
                if parsed.finished {
                    return commandResult(rawOutput: parsed.rawOutput, exitCode: parsed.exitCode ?? 0)
                }
            } else if !LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: sessionID, input: "") {
                let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
                return commandResult(rawOutput: parsed.rawOutput, exitCode: parsed.exitCode ?? 130)
            } else if rawOutput.contains("[process exited]") {
                emptyPollsAfterExit += 1
                if emptyPollsAfterExit >= 3 {
                    let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
                    return commandResult(rawOutput: parsed.rawOutput, exitCode: parsed.exitCode ?? 130)
                }
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        _ = LocalAlpineNativeRuntime.shared.interruptSession(sessionID: sessionID)
        let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
        return commandResult(rawOutput: parsed.rawOutput, exitCode: parsed.exitCode ?? 130)
    }

    private func parseStreamingCommandOutput(
        _ output: String,
        markerPrefix: String
    ) -> (rawOutput: String, visibleOutput: String, exitCode: Int?, finished: Bool) {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rawLines: [String] = []
        var visibleLines: [String] = []
        var exitCode: Int?
        var finished = false

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = sanitizedTerminalLine(rawLine)
            if line.hasPrefix(markerPrefix) {
                finished = true
                exitCode = Int(String(line.dropFirst(markerPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            if line == "[process exited]" {
                continue
            }
            if line.hasPrefix("__IEXA_SHELL_STATE__") {
                rawLines.append(line)
                continue
            }
            rawLines.append(line)
            visibleLines.append(line)
        }

        return (
            rawOutput: rawLines.joined(separator: "\n"),
            visibleOutput: trimTrailingNewlines(visibleLines.joined(separator: "\n")),
            exitCode: exitCode,
            finished: finished
        )
    }

    private func sanitizedTerminalLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{0008}", with: "")
    }

    private func trimTrailingNewlines(_ text: String) -> String {
        var result = text
        while result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }

    private func normalizedRootFSPath(_ rawPath: String) throws -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LocalAlpineError.invalidPath(rawPath)
        }
        if path.isEmpty || path == "." || path == "~" {
            return "/"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }

        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        let normalized = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        guard !normalized.contains("\u{0}") else {
            throw LocalAlpineError.invalidPath(rawPath)
        }
        return normalized
    }

    private func rootFSListCommand(path: String, includeHidden: Bool) -> String {
        let hiddenGuard = includeHidden ? "" : """
          case "$name" in .*) continue ;; esac
        """
        return """
        requested_target=\(shellSingleQuoted(path))
        target="$requested_target"
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          printf 'IEXA_ROOTFS_ERROR\\tPath does not exist: %s\\n' "$requested_target" >&2
          exit 20
        fi
        if [ ! -d "$target" ]; then
          resolved_target=$(readlink -f "$target" 2>/dev/null || true)
          if [ -n "$resolved_target" ] && [ -d "$resolved_target" ]; then
            target="$resolved_target"
          else
            printf 'IEXA_ROOTFS_ERROR\\tNot a directory: %s\\n' "$requested_target" >&2
            exit 20
          fi
        fi
        printf 'IEXA_ROOTFS_LIST_BEGIN\\n'
        for entry in "$target"/* "$target"/.[!.]* "$target"/..?*; do
          [ -e "$entry" ] || [ -L "$entry" ] || continue
          name=${entry##*/}
          case "$name" in .|..) continue ;; esac
        \(hiddenGuard)
          kind=o
          if [ -d "$entry" ]; then
            kind=d
          elif [ -f "$entry" ]; then
            kind=f
          elif [ -L "$entry" ]; then
            kind=l
          fi
          size=
          if [ "$kind" = f ]; then
            size=$(wc -c < "$entry" 2>/dev/null | tr -d ' ' || true)
          fi
          mtime=$(stat -c '%Y' "$entry" 2>/dev/null || true)
          perms=$(stat -c '%A' "$entry" 2>/dev/null || true)
          printf 'IEXA_ROOTFS_ENTRY\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$kind" "$size" "$mtime" "$perms" "$name"
        done
        printf 'IEXA_ROOTFS_LIST_END\\n'
        """
    }

    private func rootFSReadCommand(path: String) -> String {
        """
        target=\(shellSingleQuoted(path))
        max_bytes=16777216
        if [ ! -f "$target" ]; then
          printf 'Not a regular file: %s\\n' "$target" >&2
          exit 21
        fi
        size=$(wc -c < "$target" 2>/dev/null | tr -d ' ' || echo 0)
        case "$size" in
          ''|*[!0-9]*) size=0 ;;
        esac
        if [ "$size" -gt "$max_bytes" ]; then
          printf 'File is too large to preview: %s bytes (limit %s bytes)\\n' "$size" "$max_bytes" >&2
          exit 22
        fi
        if command -v base64 >/dev/null 2>&1; then
          printf 'IEXA_ROOTFS_B64_BEGIN\\n'
          base64 "$target" | tr -d '\\n'
          printf '\\nIEXA_ROOTFS_B64_END\\n'
        elif command -v python3 >/dev/null 2>&1; then
          python3 -c 'import base64,pathlib,sys; data=pathlib.Path(sys.argv[1]).read_bytes(); print("IEXA_ROOTFS_B64_BEGIN"); print(base64.b64encode(data).decode("ascii")); print("IEXA_ROOTFS_B64_END")' "$target"
        else
          printf 'base64 is unavailable in this rootfs.\\n' >&2
          exit 23
        fi
        """
    }

    private func rootFSSampledReadCommand(path: String, maxBytes: Int) -> String {
        """
        target=\(shellSingleQuoted(path))
        max_bytes=\(max(1, maxBytes))
        if [ ! -f "$target" ]; then
          printf 'Not a regular file: %s\\n' "$target" >&2
          exit 21
        fi
        size=$(wc -c < "$target" 2>/dev/null | tr -d ' ' || echo 0)
        case "$size" in
          ''|*[!0-9]*) size=0 ;;
        esac
        printf 'IEXA_ROOTFS_SIZE\\t%s\\n' "$size"
        if command -v base64 >/dev/null 2>&1; then
          printf 'IEXA_ROOTFS_B64_BEGIN\\n'
          head -c "$max_bytes" "$target" | base64 | tr -d '\\n'
          printf '\\nIEXA_ROOTFS_B64_END\\n'
        elif command -v python3 >/dev/null 2>&1; then
          python3 -c 'import base64,pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(sys.argv[2]); data=p.read_bytes()[:n]; print("IEXA_ROOTFS_B64_BEGIN"); print(base64.b64encode(data).decode("ascii")); print("IEXA_ROOTFS_B64_END")' "$target" "$max_bytes"
        else
          printf 'base64 is unavailable in this rootfs.\\n' >&2
          exit 23
        fi
        """
    }

    private func rootFSReadSize(from output: String) -> Int64? {
        let marker = "IEXA_ROOTFS_SIZE\t"
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix(marker) else { continue }
            return Int64(line.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func rootFSDeleteCommand(path: String) -> String {
        """
        target=\(shellSingleQuoted(path))
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          printf 'missing: %s\\n' "$target"
          exit 0
        fi
        rm -rf -- "$target"
        printf 'deleted: %s\\n' "$target"
        """
    }

    private func parseRootFSListOutput(_ output: String, path: String) throws -> [TerminalFileItem] {
        let marker = "IEXA_ROOTFS_ENTRY\t"
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> TerminalFileItem? in
                let line = String(rawLine)
                guard line.hasPrefix(marker) else { return nil }
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 6 else { return nil }
                let kind = String(parts[1])
                let sizeText = String(parts[2])
                let mtimeText = String(parts[3])
                let permissions = String(parts[4])
                let name = parts.dropFirst(5).map(String.init).joined(separator: "\t")
                guard !name.isEmpty else { return nil }
                let itemPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                let modified = Double(mtimeText).map { Date(timeIntervalSince1970: $0) }
                return TerminalFileItem(
                    name: name,
                    path: itemPath,
                    isDirectory: kind == "d",
                    size: Int64(sizeText),
                    modified: modified,
                    permissions: permissions.isEmpty ? nil : permissions
                )
            }
    }

    private func rootFSCommandPayload(from output: String, begin: String, end: String) -> String? {
        guard let beginRange = output.range(of: begin, options: .backwards),
              let endRange = output.range(of: end, range: beginRange.upperBound..<output.endIndex) else {
            return nil
        }
        return String(output[beginRange.upperBound..<endRange.lowerBound])
    }

    private func rootFSUserFacingError(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap { rootFSReadableErrorLine($0) }
        let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Unable to read rootfs." : cleaned
    }

    private func rootFSReadableErrorLine(_ rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        if line == "IEXA_ROOTFS_LIST_BEGIN"
            || line == "IEXA_ROOTFS_LIST_END"
            || line == "IEXA_ROOTFS_B64_BEGIN"
            || line == "IEXA_ROOTFS_B64_END" {
            return nil
        }
        if line.contains("IEXA_ROOTFS_ENTRY\t")
            || line.contains("IEXA_ROOTFS_ENTRY\\t")
            || line.contains("IEXA_ROOTFS_LIST_BEGIN")
            || line.contains("IEXA_ROOTFS_LIST_END")
            || line.contains("IEXA_ROOTFS_B64_BEGIN")
            || line.contains("IEXA_ROOTFS_B64_END") {
            return nil
        }
        if let range = line.range(of: "IEXA_ROOTFS_ERROR\t") {
            line = String(line[range.upperBound...])
        }
        line = line.replacingOccurrences(of: "IEXA_ROOTFS_ERROR\\t", with: "")
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    private func isDeletableRootFSPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        guard path.hasPrefix("/tmp/") || path.hasPrefix("/root/") || path.hasPrefix("/home/") else {
            return false
        }
        let protectedExact: Set<String> = [
            "/bin", "/dev", "/etc", "/home", "/lib", "/media", "/mnt", "/mnt/iexa",
            "/proc", "/root", "/run", "/sbin", "/sys", "/tmp", "/usr", "/var"
        ]
        return !protectedExact.contains(path)
    }

    private func runtimePath(forSharedPath rawPath: String) -> String {
        let hostPath = normalizedTerminalPath(rawPath)
        return hostPath == "/" ? "/mnt/iexa" : "/mnt/iexa\(hostPath)"
    }

    private func materializedRuntimeCommandIfNeeded(_ command: String) async -> (command: String, cleanupPath: String?) {
        guard command.utf8.count > maximumInlineRuntimeCommandBytes else {
            return (command, nil)
        }

        guard let data = (command + "\n").data(using: .utf8) else {
            let message = "Local Alpine command is too long and could not be encoded as UTF-8."
            return ("printf '%s\\n' \(shellSingleQuoted(message)) >&2\nexit 125", nil)
        }

        let scriptPath = "/.iexa-terminal-scripts/command-\(UUID().uuidString).sh"
        let split = splitFilePath(scriptPath)
        do {
            try await writeFile(data: data, fileName: split.fileName, destinationPath: split.directory)
            logger.info("Materialized long Local Alpine command into temporary script: \(scriptPath, privacy: .public)")
            return ("/bin/sh \(shellSingleQuoted(runtimePath(forSharedPath: scriptPath)))", scriptPath)
        } catch {
            logger.error("Failed to materialize long Local Alpine command: \(error.localizedDescription, privacy: .public)")
            let message = "Local Alpine command is too long and could not be written to a temporary script: \(error.localizedDescription)"
            return ("printf '%s\\n' \(shellSingleQuoted(message)) >&2\nexit 125", nil)
        }
    }

    private func compatibilityCommand(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("curl ") {
            let rest = trimmed.dropFirst("curl ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty,
                  rest.range(of: #"[;&|`$<>(){}]"#, options: .regularExpression) == nil else {
                return command
            }

            let passthroughOptions: Set<String> = ["-s", "-S", "-sS", "-L"]
            let parts = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let canApplyWgetFallback = !parts.dropLast().contains { $0.hasPrefix("-") && !passthroughOptions.contains($0) }
            guard canApplyWgetFallback, let url = parts.last, !url.hasPrefix("-") else { return command }

            let escapedURL = shellSingleQuoted(url)
            return """
            if command -v curl >/dev/null 2>&1; then
              \(command)
            else
              wget -qO- \(escapedURL)
            fi
            """
        }

        return protectSlowNPMVersionChecks(in: rewriteApkNodeAlias(in: command))
    }

    private func bootstrappedShellCommand(for command: String) -> String {
        let script = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return command }
        return """
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/i586-alpine-linux-musl/bin:${PATH:-}"
        export COMPILER_PATH="/usr/i586-alpine-linux-musl/bin:${COMPILER_PATH:-}"
        if [ -f /etc/profile ]; then
          . /etc/profile >/dev/null 2>&1 || true
        fi
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/i586-alpine-linux-musl/bin:${PATH:-}"
        export COMPILER_PATH="/usr/i586-alpine-linux-musl/bin:${COMPILER_PATH:-}"
        iexa_bootstrap_preview_helpers() {
          _iexa_bootstrap_bin=/tmp/iexa-bootstrap-bin
          _iexa_bootstrap_version=2026-06-18.1
          mkdir -p "$_iexa_bootstrap_bin" 2>/dev/null || return 0
          if [ -x "$_iexa_bootstrap_bin/iexa-open" ] && [ -x "$_iexa_bootstrap_bin/iexa-serve" ] && [ -x "$_iexa_bootstrap_bin/lsof" ] && [ "$(cat "$_iexa_bootstrap_bin/.iexa-bootstrap-version" 2>/dev/null)" = "$_iexa_bootstrap_version" ]; then
            export PATH="$_iexa_bootstrap_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/i586-alpine-linux-musl/bin:${PATH:-}"
            export BROWSER=iexa-open
            hash -r 2>/dev/null || true
            return 0
          fi
          cat > "$_iexa_bootstrap_bin/iexa-open" <<'IEXA_OPEN_FALLBACK'
        #!/bin/sh
        ESC=$(printf '\\033')
        BEL=$(printf '\\007')
        emit_open_marker() {
          printf '%s]1337;IexaOpenURL=%s%s\\n' "$ESC" "$1" "$BEL"
        }
        if [ "$#" -eq 0 ]; then
          printf 'Usage: iexa-open <url-or-path>\\n' >&2
          exit 1
        fi
        for target in "$@"; do
          case "$target" in
            http://*|https://*|about:*|file://*|iexa://*|/*)
              emit_open_marker "$target"
              printf 'Opened in Iexa preview: %s\\n' "$target"
              ;;
            *)
              resolved=$(readlink -f "$target" 2>/dev/null || true)
              if [ -n "$resolved" ]; then
                emit_open_marker "$resolved"
                printf 'Opened in Iexa preview: %s\\n' "$resolved"
              else
                printf 'iexa-open: not a URL or path: %s\\n' "$target" >&2
              fi
              ;;
          esac
        done
        IEXA_OPEN_FALLBACK
          cat > "$_iexa_bootstrap_bin/iexa-serve" <<'IEXA_SERVE_FALLBACK'
        #!/bin/sh
        set -u
        ESC=$(printf '\\033')
        BEL=$(printf '\\007')
        emit_open_marker() {
          printf '%s]1337;IexaOpenURL=%s%s\\n' "$ESC" "$1" "$BEL"
        }
        target=${1:-.}
        port=${2:-8080}
        case "$port" in ''|*[!0-9]*) port=8080 ;; esac
        if [ -f "$target" ]; then
          target=$(dirname "$target")
        fi
        if [ ! -d "$target" ]; then
          resolved=$(readlink -f "$target" 2>/dev/null || true)
          if [ -n "$resolved" ] && [ -f "$resolved" ]; then
            target=$(dirname "$resolved")
          elif [ -n "$resolved" ] && [ -d "$resolved" ]; then
            target="$resolved"
          fi
        fi
        if [ ! -d "$target" ]; then
          printf 'iexa-serve: directory not found: %s\\n' "$target" >&2
          exit 1
        fi
        dir=$(cd "$target" 2>/dev/null && pwd)
        if [ -z "$dir" ]; then
          printf 'iexa-serve: cannot resolve directory: %s\\n' "$target" >&2
          exit 1
        fi
        runtime_dir=/tmp/iexa-serve
        mkdir -p "$runtime_dir"
        print_urls() {
          url="http://localhost:$1/"
          printf 'Preview URL: %s\\n' "$url"
          printf 'Loopback URL: http://127.0.0.1:%s/\\n' "$1"
          printf '访问地址: %s\\n' "$url"
          emit_open_marker "$url"
        }
        pid_alive() {
          [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
        }
        socket_port_in_use() {
          if command -v nc >/dev/null 2>&1; then
            nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
            return 1
          fi
          if [ -r /proc/net/tcp ]; then
            port_hex=$(printf '%04X' "$1" 2>/dev/null || true)
            if [ -n "$port_hex" ]; then
              awk -v p=":$port_hex" 'tolower($2) ~ tolower(p) && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp 2>/dev/null && return 0
              [ -r /proc/net/tcp6 ] && awk -v p=":$port_hex" 'tolower($2) ~ tolower(p) && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp6 2>/dev/null && return 0
              return 1
            fi
          fi
          return 2
        }
        existing_server_for_dir() {
          candidate_port="$1"
          candidate_pidfile="$runtime_dir/$candidate_port.pid"
          candidate_dirfile="$runtime_dir/$candidate_port.dir"
          [ -f "$candidate_pidfile" ] || return 1
          candidate_pid=$(cat "$candidate_pidfile" 2>/dev/null || true)
          pid_alive "$candidate_pid" || return 1
          socket_port_in_use "$candidate_port"
          socket_status=$?
          [ "$socket_status" -eq 1 ] && return 1
          candidate_dir=$(cat "$candidate_dirfile" 2>/dev/null || true)
          if [ -z "$candidate_dir" ] || [ "$candidate_dir" = "$dir" ]; then
            printf 'Iexa local preview server already running.\\n'
            printf 'Directory: %s\\n' "$dir"
            printf 'PID: %s\\n' "$candidate_pid"
            print_urls "$candidate_port"
            exit 0
          fi
          return 1
        }
        port_in_use() {
          socket_port_in_use "$1"
          socket_status=$?
          [ "$socket_status" -eq 0 ] && return 0
          [ "$socket_status" -eq 1 ] && return 1
          pidfile="$runtime_dir/$1.pid"
          if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null || true)
            pid_alive "$pid" && return 0
          fi
          return 1
        }
        existing_server_for_dir "$port"
        start_port=$port
        while port_in_use "$port"; do
          port=$((port + 1))
          existing_server_for_dir "$port"
          if [ "$port" -gt $((start_port + 50)) ]; then
            printf 'iexa-serve: no free localhost port found near %s\\n' "$start_port" >&2
            exit 1
          fi
        done
        log="$runtime_dir/$port.log"
        pidfile="$runtime_dir/$port.pid"
        dirfile="$runtime_dir/$port.dir"
        if command -v python3 >/dev/null 2>&1; then
          python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >"$log" 2>&1 &
          pid=$!
        elif command -v busybox >/dev/null 2>&1; then
          busybox httpd -f -p "127.0.0.1:$port" -h "$dir" >"$log" 2>&1 &
          pid=$!
        else
          printf 'iexa-serve: python3 or busybox httpd is required\\n' >&2
          exit 1
        fi
        printf '%s\\n' "$pid" > "$pidfile"
        printf '%s\\n' "$dir" > "$dirfile"
        sleep 1 2>/dev/null || true
        if ! kill -0 "$pid" 2>/dev/null; then
          printf 'iexa-serve: server failed to start. Log: %s\\n' "$log" >&2
          [ -f "$log" ] && tail -40 "$log" >&2
          rm -f "$pidfile" "$dirfile"
          exit 1
        fi
        socket_port_in_use "$port"
        socket_status=$?
        if [ "$socket_status" -eq 1 ]; then
          printf 'iexa-serve: server did not listen on localhost:%s. Log: %s\\n' "$port" "$log" >&2
          [ -f "$log" ] && tail -40 "$log" >&2
          kill "$pid" 2>/dev/null || true
          rm -f "$pidfile" "$dirfile"
          exit 1
        fi
        printf 'Iexa local preview server started.\\n'
        printf 'Directory: %s\\n' "$dir"
        printf 'PID: %s\\n' "$pid"
        print_urls "$port"
        IEXA_SERVE_FALLBACK
          cat > "$_iexa_bootstrap_bin/lsof" <<'IEXA_LSOF_FALLBACK'
        #!/bin/sh
        printf 'lsof is disabled in Iexa Local Alpine because it is unreliable in the embedded iSH runtime.\\n' >&2
        printf 'For localhost preview checks, use `nc -z 127.0.0.1 <port>` or inspect /proc/net/tcp.\\n' >&2
        exit 127
        IEXA_LSOF_FALLBACK
          chmod +x "$_iexa_bootstrap_bin/iexa-open" "$_iexa_bootstrap_bin/iexa-serve" "$_iexa_bootstrap_bin/lsof" 2>/dev/null || true
          printf '%s\\n' "$_iexa_bootstrap_version" > "$_iexa_bootstrap_bin/.iexa-bootstrap-version" 2>/dev/null || true
          export PATH="$_iexa_bootstrap_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/i586-alpine-linux-musl/bin:${PATH:-}"
          export BROWSER=iexa-open
          hash -r 2>/dev/null || true
        }
        iexa_bootstrap_preview_helpers
        iexa_find_executable() {
          _iexa_name="$1"
          _iexa_old_ifs="$IFS"
          IFS=:
          for _iexa_dir in $PATH; do
            [ -n "$_iexa_dir" ] || _iexa_dir=.
            if [ -x "$_iexa_dir/$_iexa_name" ]; then
              IFS="$_iexa_old_ifs"
              printf '%s\n' "$_iexa_dir/$_iexa_name"
              return 0
            fi
          done
          IFS="$_iexa_old_ifs"
          return 1
        }
        lua() {
          if _iexa_lua="$(iexa_find_executable lua)"; then
            "$_iexa_lua" "$@"
          elif _iexa_lua="$(iexa_find_executable lua5.4)"; then
            "$_iexa_lua" "$@"
          elif _iexa_lua="$(iexa_find_executable lua5.3)"; then
            "$_iexa_lua" "$@"
          elif _iexa_lua="$(iexa_find_executable lua5.2)"; then
            "$_iexa_lua" "$@"
          elif _iexa_lua="$(iexa_find_executable lua5.1)"; then
            "$_iexa_lua" "$@"
          else
            printf '/bin/sh: lua: not found\n' >&2
            return 127
          fi
        }
        python() {
          if _iexa_python="$(iexa_find_executable python)"; then
            "$_iexa_python" "$@"
          elif _iexa_python="$(iexa_find_executable python3)"; then
            "$_iexa_python" "$@"
          else
            printf '/bin/sh: python: not found\n' >&2
            return 127
          fi
        }
        pip() {
          if _iexa_pip="$(iexa_find_executable pip)"; then
            "$_iexa_pip" "$@"
          elif _iexa_pip="$(iexa_find_executable pip3)"; then
            "$_iexa_pip" "$@"
          else
            printf '/bin/sh: pip: not found\n' >&2
            return 127
          fi
        }
        iexa_refresh_dns() {
          cat > /etc/resolv.conf <<'EOF'
        nameserver 1.1.1.1
        nameserver 8.8.8.8
        nameserver 223.5.5.5
        options timeout:2 attempts:3
        EOF
        }
        iexa_repair_toolchain_links() {
          arch_bin=""
          for candidate in /usr/i586-alpine-linux-musl/bin /usr/i686-alpine-linux-musl/bin /usr/x86_64-alpine-linux-musl/bin; do
            if [ -d "$candidate" ]; then
              arch_bin="$candidate"
              break
            fi
          done
          [ -n "$arch_bin" ] || return 0
          for tool in as ld ar ranlib strip objcopy objdump readelf nm size strings; do
            if [ ! -e "/usr/bin/$tool" ] && [ -x "$arch_bin/$tool" ]; then
              ln -sf "$arch_bin/$tool" "/usr/bin/$tool" 2>/dev/null || true
            fi
          done
          hash -r 2>/dev/null || true
        }
        iexa_real_apk() {
          if [ -x /sbin/apk ]; then
            /sbin/apk "$@"
          elif [ -x /usr/sbin/apk ]; then
            /usr/sbin/apk "$@"
          else
            command apk "$@"
          fi
        }
        iexa_run_apk() {
          apk_bin=""
          if [ -x /sbin/apk ]; then
            apk_bin="/sbin/apk"
          elif [ -x /usr/sbin/apk ]; then
            apk_bin="/usr/sbin/apk"
          fi
          if [ -n "$apk_bin" ] && command -v timeout >/dev/null 2>&1; then
            timeout 120 "$apk_bin" "$@"
            status=$?
          else
            iexa_real_apk "$@"
            status=$?
          fi
          case "$status" in
            124|137|143)
              printf '\\nIEXA_ALPINE_INSTALL_TIMEOUT: apk command exceeded 120 seconds.\\n' >&2
              printf 'The package mirror or network may be slow. Try a smaller package set, retry later, or switch the Alpine repository mirror.\\n' >&2
              ;;
          esac
          return "$status"
        }
        apk() {
          case "${1:-}" in
            add|fix|upgrade|update)
              attempts=0
              while :; do
                iexa_refresh_dns
                if iexa_run_apk "$@"; then
                  status=0
                else
                  status=$?
                fi
                if [ "$status" -eq 0 ] || [ "$attempts" -ge 2 ]; then
                  break
                fi
                attempts=$((attempts + 1))
                sleep "$attempts"
              done
              ;;
            *)
              if iexa_real_apk "$@"; then
                status=0
              else
                status=$?
              fi
              ;;
          esac
          case "${1:-}" in
            add|fix|upgrade)
              hash -r 2>/dev/null || true
              export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/i586-alpine-linux-musl/bin:${PATH:-}"
              export COMPILER_PATH="/usr/i586-alpine-linux-musl/bin:${COMPILER_PATH:-}"
              iexa_repair_toolchain_links
              ;;
          esac
          return "$status"
        }
        iexa_repair_toolchain_links
        hash -r 2>/dev/null || true
        \(script)
        iexa_command_status=$?
        iexa_verify_toolchain_after_apk() {
          case "$*" in
            *"apk add"*build-base*|*"apk add"*g++*|*"apk add"*gcc*)
              missing=""
              for x in gcc g++ make; do
                command -v "$x" >/dev/null 2>&1 || missing="$missing $x"
              done
              if [ -n "$missing" ]; then
                printf '\\nIEXA_ALPINE_TOOLCHAIN_MISSING:%s\\n' "$missing" >&2
                printf 'The Alpine package database may be out of sync with the rootfs. Install a build with the bundled build tools rootfs, or reset Local Alpine rootfs.\\n' >&2
              fi
              ;;
          esac
        }
        iexa_verify_toolchain_after_apk \(shellSingleQuoted(script))
        exit "$iexa_command_status"
        """
    }

    private func interactiveInputWarning(for command: String) -> String? {
        let lowercased = command.lowercased()
        let markers = [
            "input(",
            "raw_input(",
            "read -p",
            "read -r",
            "scanf(",
            "cin >>",
            "readline(",
            "readline.readline",
            "prompt("
        ]
        let hasShellRead = lowercased.range(
            of: #"(?m)(^|[;&|]\s*)read(\s|$)"#,
            options: .regularExpression
        ) != nil
        guard hasShellRead || markers.contains(where: { lowercased.contains($0) }) else { return nil }
        guard !hasExplicitStdinFeed(in: lowercased) else { return nil }
        return """
        检测到交互式输入（input/read/scanf 等）。

        本次执行已暂停等待输入。请在弹出的小窗口里填写 stdin 内容；确认后会用管道继续执行，取消则结束本次命令。

        注意：这是给程序 stdin 的输入，不是模型回复文本。多个 input()/read 请一行填一个；管道输入不会像真实键盘那样自动回显，只有程序 print/echo 出来的内容才会显示在结果里。

        也可以把输入值改成命令行参数、环境变量、默认值，或把测试输入提前用管道传入，例如：
        printf 'value\\n' | python3 script.py
        """
    }

    private func hasExplicitStdinFeed(in command: String) -> Bool {
        let patterns = [
            #"(?:printf|echo|cat|yes)\b[\s\S]{0,240}\|\s*(?:/bin/)?(?:sh|bash|python3?|node|ruby|perl|php|lua|deno|java)\b"#,
            #"\|\s*(?:/bin/)?(?:sh|bash|python3?|node|ruby|perl|php|lua|deno|java)\b"#
        ]
        return patterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func wrappedCommandForInteractiveInput(command: String, stdinInput: String) -> String {
        let input = shellSingleQuoted(stdinInput)
        let script = shellSingleQuoted(command)
        return "printf '%s\\n' \(input) | /bin/sh -lc \(script)"
    }

    private func rewriteApkNodeAlias(in command: String) -> String {
        let rewrittenLines = command.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            rewriteApkNodeAliasLine(String(line))
        }
        let rewritten = rewrittenLines.joined(separator: "\n")
        return rewritten == command ? command : rewritten
    }

    private func protectSlowNPMVersionChecks(in command: String) -> String {
        var rewritten = command
        let replacements = [
            (#"(?<![\w./-])npm\s+--version(?![\w-])"#, "iexa_npm_version"),
            (#"(?<![\w./-])npm\s+-v(?![\w-])"#, "iexa_npm_version")
        ]
        for (pattern, replacement) in replacements {
            rewritten = rewritten.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        guard rewritten != command else { return command }
        return """
        iexa_npm_version() {
          npm_path="$(command -v npm 2>/dev/null || true)"
          if [ -z "$npm_path" ]; then
            echo missing
            return 0
          fi
          tmp="/tmp/iexa-npm-version-$$.out"
          (npm --version >"$tmp" 2>&1) &
          pid=$!
          i=0
          while kill -0 "$pid" >/dev/null 2>&1; do
            if [ "$i" -ge 5 ]; then
              kill "$pid" >/dev/null 2>&1 || true
              wait "$pid" >/dev/null 2>&1 || true
              rm -f "$tmp"
              echo "present: $npm_path (npm --version timed out after 5 seconds)"
              return 0
            fi
            sleep 1
            i=$((i + 1))
          done
          wait "$pid"
          status=$?
          cat "$tmp" 2>/dev/null || true
          rm -f "$tmp"
          return "$status"
        }
        \(rewritten)
        """
    }

    private func rewriteApkNodeAliasLine(_ line: String) -> String {
        let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
        let command = line.dropFirst(leadingWhitespace.count)
        let lowercased = command.lowercased()
        guard lowercased.hasPrefix("apk add ") else { return line }

        let commandBody = String(command)
        let tokens = commandBody.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 3, tokens[0] == "apk", tokens[1] == "add" else { return line }

        var rewritten: [String] = [tokens[0], tokens[1]]
        var changed = false
        for token in tokens.dropFirst(2) {
            if token == "node" {
                rewritten.append("nodejs")
                rewritten.append("npm")
                changed = true
            } else {
                rewritten.append(token)
            }
        }

        return changed ? String(leadingWhitespace) + rewritten.joined(separator: " ") : line
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func splitFilePath(_ rawPath: String) -> (directory: String, fileName: String) {
        let normalized = normalizedTerminalPath(rawPath)
        let nsPath = normalized as NSString
        let directory = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent
        return (directory.isEmpty ? "/" : directory, fileName)
    }

    private func sanitizedFileName(_ rawName: String) throws -> String {
        let name = URL(fileURLWithPath: rawName).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else {
            throw LocalAlpineError.invalidPath(rawName)
        }
        return name
    }

    private func sanitizedPathComponent(_ rawValue: String, fallback: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard !sanitized.isEmpty else { return fallback }
        return String(sanitized.prefix(80))
    }
}

enum LocalAlpineError: LocalizedError {
    case documentsUnavailable
    case invalidPath(String)
    case protectedPath(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "Documents directory is unavailable."
        case .invalidPath(let path):
            return "Invalid local path: \(path)"
        case .protectedPath(let path):
            return "Protected rootfs path cannot be deleted: \(path)"
        case .commandFailed(let output):
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Local Alpine command failed." : message
        }
    }
}
